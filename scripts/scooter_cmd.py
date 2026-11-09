#!/usr/bin/env python3
"""
scooter_cmd.py - CLI for sending CommandFromHMI commands to an Ola S1 Pro Gen 1
head unit over the factory gRPC diagnostics service (wifican.WifiCanRpc on
localhost:50005, reachable on the scooter LAN).

Owner-authorized research tool. Read-only-first philosophy: defaults are safe,
nothing is sent unless you ask for it, and destructive commands are blocked.

All commands are written to CAN ID 0x6BC byte 0, which is the HMI -> BCM/VCU
command channel used by HVDP's MasterCommander.sendScooterCommands(). This
matches the decompiled flow:

    VehicleStateController.sendUnlockByPasscode()            (HVSM)
      -> VehicleParserManager.sendUnlockedByPasscode()
      -> AIDL ICommanderService.unlockedByPasscode(true)
      -> CommanderServiceImpl.unlockedByPasscode()           (HVDP)
      -> MasterCommander.scooterUnlockedByPassCode()
      -> loop 30x @ 100ms: sendScooterCommands(0x19)
      -> CanUtils.sendCan0Data(CanId(0x6BC), [cmd,0,0,0,0,0,0,0])

Command path: `cansend` over the gRPC ExecuteADBCommand RPC, e.g.

    ExecuteADBCommand("cansend vcan0 6BC#1900000000000000")

NOT gRPC WriteCanFrame. WriteCanFrame was confirmed non-functional for this
channel: the MCU that bridges vcan0 to the physical bus ignores gRPC-originated
writes to 0x6BC, while `cansend` on vcan0 (same origin as HVDP's own writes)
works. `cansend` also takes the logical CAN ID directly ("6BC"), so the 16-byte
gRPC frame byte order is irrelevant on this path.

For reference, the gRPC CANPacket.can_frame wire layout (16 bytes), confirmed
against the olamate telemetry read decoder, is: 4B CAN ID big-endian + 1B DLC +
3B pad + 8B data. It is documented in research/can-command-reference.md but not used here.

Usage:
    python scripts/scooter_cmd.py --ip <scooter-ip> indicator-left-on
    python scripts/scooter_cmd.py --dry-run unlock --repeat 1
    python scripts/scooter_cmd.py list

UDS diagnostics (read-only):
    python scripts/scooter_cmd.py --dry-run uds-read vcu --did vin
    python scripts/scooter_cmd.py --dry-run uds-read bms --did-hex E400
    python scripts/scooter_cmd.py --dry-run uds-dtc vcu
    python scripts/scooter_cmd.py uds-list
"""

from __future__ import annotations

import argparse
import sys
import time

# ---------------------------------------------------------------------------
# Constants from decompiled HVDP (com.olaelectric.vehicleparser)
# ---------------------------------------------------------------------------

# CAN ID the HMI command channel writes to. The tool refuses to target anything
# else; 0x6A1 in particular is off-limits per project safety constraints.
COMMAND_CAN_ID = 0x6BC
FORBIDDEN_CAN_IDS = {0x6A1}
CAN_INTERFACE = "vcan0"

# UDS (ISO 14229) CAN ID pairs — request/response for each ECU.
# From the Ola diagnostics app EcuCanId.smali.
UDS_ECU_CAN_IDS = {
    "bms": (0x078E, 0x07B1),
    "vcu": (0x0786, 0x07B0),
    "mcu": (0x07A6, 0x07B4),
}

# UDS Service IDs
UDS_SID_READ = 0x22            # ReadDataByIdentifier
UDS_SID_SESSION_CTRL = 0x10   # DiagnosticSessionControl
UDS_SID_READ_DTC = 0x19       # ReadDTCInformation

# Common UDS DIDs (from diagnostics app analysis)
UDS_DIDS = {
    "vin":           (0xF190, "VIN — Vehicle Identification Number"),
    "version":       (0x0100, "Software version + vehicle variant"),
    "odometer":      (0x0103, "Odometer value"),
    "customer-mode": (0x017E, "Customer mode status"),
    "hypercharge":   (0x0102, "HyperCharge status"),
    "hill-hold":     (0xCF6F, "Hill Hold feature flag (VCU)"),
    "boost-mode":    (0xCF37, "Boost Mode feature flag (VCU)"),
    "proximity":     (0xCF64, "Proximity Lock/Unlock flag (VCU)"),
    "motor-cutoff":  (0xCF68, "Motor Cutoff Delay flag (VCU)"),
}

# The unlock loop in MasterCommander.scooterUnlockedByPassCode():
#   while flag and count < 0x1e (30): sendScooterCommands(0x19); sleep 100ms
UNLOCK_CMD = 0x19          # PASSCODE_AUTH
UNLOCK_REPEAT = 30         # 0x1e
UNLOCK_INTERVAL_MS = 100   # 0x64

# CommandFromHMI enum, extracted verbatim from
# com/olaelectric/vehicleinterface/CommandFromHMI.smali (<clinit> ordinals).
# The ordinal IS the byte written to CAN 0x6BC byte 0.
COMMAND_FROM_HMI = {
    "No_Command": 0x00,
    "Lock_with_Steering": 0x01,
    "Lock_without_Steering": 0x02,
    "Seat_Unlock_Cmd": 0x03,
    "Reverse_mode_activated": 0x04,
    "Headlight_Turn_ON_Request": 0x05,
    "ECO_Mode_Rejected_by_User": 0x06,
    "ECO_Mode_Accepted_by_User": 0x07,
    "Vehicle_Shutdown_is_Rejected_by_User": 0x08,
    "ALARM_Turn_Off_Request": 0x09,
    "Headlight_Turn_OFF_Request": 0x0A,
    "Accepted_Get_Home_Request": 0x0B,
    "Rejected_Get_Home_Request": 0x0C,
    "Stop_Charge": 0x0D,
    "Scooter_Reboot": 0x0E,
    "OTA_Installation_Started": 0x0F,
    "OTA_Installation_in_Progress": 0x10,
    "OTA_Installation_Complete": 0x11,
    "MCU_Reboot": 0x12,
    "HU_Reboot": 0x13,
    "Passcode_ACK": 0x14,
    "TripoMeter_Reset_Successfull": 0x15,
    "CTA_LOCK": 0x16,
    "CTA_UNLOCK": 0x17,
    "CTA_IGNORE": 0x18,
    "PASSCODE_AUTH": 0x19,
    "High_Beam_ON": 0x1A,
    "High_Beam_OFF": 0x1B,
    "Low_Beam_ON": 0x1C,
    "Low_Beam_OFF": 0x1D,
    "Rear_Light_ON": 0x1E,
    "Rear_Light_OFF": 0x1F,
    "Left_Indicator_ON": 0x20,
    "Left_Indicator_OFF": 0x21,
    "Right_Indicator_ON": 0x22,
    "Right_Indicator_OFF": 0x23,
    "Front_DRL_ON": 0x24,
    "Front_DRL_OFF": 0x25,
    "AUTO_HEADLIGHT_SUNRISE_EN": 0x26,
    "Auto_HEAD_LIGHT_SUNSET_EN": 0x27,
    "Auto_Head_Light_Reserved": 0x28,
    "Regen_Type_Default_SELECTED": 0x29,
    "Regen_Type_City_Ride_En_Selected": 0x2A,
    "Regen_Type_Highway_Glide_En_Selected": 0x2B,
    "Smart_Head_Light_Default_Selected": 0x2C,
    "Smart_Head_Light_Low_Beam_En_Selected": 0x2D,
    "Smart_Head_Light_High_Beam_En_Selected": 0x2E,
    "Smart_Head_Light_Smart_Light_En_Selected": 0x2F,
    "Boost_Mode_Enable_Selected": 0x30,
    "Boost_Mode_Disable_Selected": 0x31,
    "Accident_Detection_Enable_Selected": 0x32,
    "Accident_Detection_Disable_Selected": 0x33,
    "Tow_Tamper_Detection_Enable_Selected": 0x34,
    "Tow_Tamper_Detection_Disable_Selected": 0x35,
    "Proximity_Lock_Unlock_Enable_Selected": 0x36,
    "Proximity_Lock_Unlock_Disable_Selected": 0x37,
    "Smart_DRL_Light_Enable_Selected": 0x38,
    "Smart_DRL_Light_Disable_Selected": 0x39,
    "Auto_Head_Light_Handling_Enable_Selected": 0x3A,
    "Auto_Head_Light_Handling_Disable_Selected": 0x3B,
    "Hazard_Light_Feature_Enable_Selected": 0x3C,
    "Hazard_Light_Feature_Disable_Selected": 0x3D,
    "Auto_Indicator_Turn_off_Feature_Enable_Selected": 0x3E,
    "Auto_Indicator_Turn_off_Feature_Disable_Selected": 0x3F,
    "Motor_Cutoff_Delay_Selected_Enable_Selected": 0x40,
    "Motor_Cutoff_Delay_Selected_Disable_Selected": 0x41,
    "Hill_Hold_Request_Enable_Selected": 0x42,
    "Hill_Hold_Request_Disable_Selected": 0x43,
    "VACATION_MODE_ON": 0x44,
    "VACATION_MODE_OFF": 0x45,
    "NEED_HELP": 0x46,
    "I_AM_SAFE": 0x47,
    "DELETE_PROFILE": 0x48,
    "USER_CALIBRATION_REQUEST": 0x49,
    "Hazard_Light_Turn_ON": 0x4A,
    "Hazard_Light_Turn_OFF": 0x4B,
    "HMI_Alarm_ignore_True": 0x4C,
    "Tow_Theft_Low_Sensitivity": 0x4D,
    "Tow_Theft_High_Sensitivity": 0x4E,
    "HMI_Alarm_ignore_False": 0x4F,
    "Exit_Diagnostic_Mode": 0x50,
    "Version_Mismatched": 0x51,
    "Smart_Head_Light_SMART_LIGHT_EN_Deselected": 0x52,
    "Ride_Now": 0x53,
    "Lock_Now": 0x54,
    "TMH_Lights_Enable": 0x55,
    "TMH_Lights_Disabled": 0x56,
    "Alarm_unlock_Now": 0x57,
    "Drive_acess_revoked_enable": 0x58,
    "Drive_acess_revoked_disable": 0x59,
    "SIDE_STAND_DISABLE": 0x5A,
    "SIDE_STAND_ENABLE": 0x5B,
    "Brake_Switch_Fault_Deactivate": 0x5C,
    "Brake_Switch_Fault_Activate": 0x5D,
    "AI_Ind_OFF": 0x5E,
    "Brk_Snsr_Fail_detect_AI": 0x5F,
    "Brk_Snsr_Fail_clear_AI": 0x60,
    "OTA_MCU_Reset": 0x61,
    "HMI_Wakeup_pass": 0x62,
}
VALUE_TO_NAME = {v: k for k, v in COMMAND_FROM_HMI.items()}

# Commands this tool refuses to send. Reboots, OTA control, profile deletion.
BLOCKED_COMMANDS = {
    0x0E: "Scooter_Reboot",
    0x0F: "OTA_Installation_Started",
    0x10: "OTA_Installation_in_Progress",
    0x11: "OTA_Installation_Complete",
    0x12: "MCU_Reboot",
    0x13: "HU_Reboot",
    0x48: "DELETE_PROFILE",
    0x61: "OTA_MCU_Reset",
}


# ---------------------------------------------------------------------------
# cansend frame building
# ---------------------------------------------------------------------------

def build_cansend(can_id: int, command_byte: int) -> str:
    """Build the `cansend` command string for one command byte.

    Mirrors MasterCommander.sendScooterCommands(): data[0] = command, data[1:8]
    = 0. cansend takes the logical CAN ID directly, e.g.
        cansend vcan0 6BC#1900000000000000
    """
    if not 0 <= command_byte <= 0xFF:
        raise ValueError(f"command byte out of range: {command_byte}")
    data_hex = f"{command_byte:02X}" + "00" * 7  # 8 data bytes, DLC inferred as 8
    return f"cansend {CAN_INTERFACE} {can_id:03X}#{data_hex}"


def build_uds_read_frame(ecu: str, did: int) -> str:
    """Build a cansend command for a UDS ReadDataByIdentifier (0x22) request.

    ISO-TP single frame format: [PCI: 0x03] [SID: 0x22] [DID high] [DID low] [pad x4]
    PCI byte 0x03 = single frame with 3 data bytes.
    """
    req_id, _resp_id = UDS_ECU_CAN_IDS[ecu]
    did_hi = (did >> 8) & 0xFF
    did_lo = did & 0xFF
    data_hex = f"03{UDS_SID_READ:02X}{did_hi:02X}{did_lo:02X}00000000"
    return f"cansend {CAN_INTERFACE} {req_id:03X}#{data_hex}"


def build_uds_session_frame(ecu: str, session: int = 0x03) -> str:
    """Build a cansend command for DiagnosticSessionControl (0x10).

    Default session=0x03 (Extended). 0x01=Default, 0x02=Programming.
    """
    req_id, _resp_id = UDS_ECU_CAN_IDS[ecu]
    data_hex = f"02{UDS_SID_SESSION_CTRL:02X}{session:02X}0000000000"
    return f"cansend {CAN_INTERFACE} {req_id:03X}#{data_hex}"


def build_uds_dtc_read_frame(ecu: str) -> str:
    """Build a cansend command for ReadDTCInformation (0x19), sub-function 0x02
    (reportDTCByStatusMask), mask 0xFF (all DTCs)."""
    req_id, _resp_id = UDS_ECU_CAN_IDS[ecu]
    data_hex = f"03{UDS_SID_READ_DTC:02X}02FF00000000"
    return f"cansend {CAN_INTERFACE} {req_id:03X}#{data_hex}"


# ---------------------------------------------------------------------------
# gRPC plumbing
# ---------------------------------------------------------------------------

def _load_stubs(stubs_path: str | None):
    """Import the generated wifican stubs (from ~/personal/olamate/collector)."""
    import importlib
    import os

    errors = []

    # 1. Try importing from the same directory as this script (generated stubs
    #    live alongside scooter_cmd.py after running the setup instructions).
    script_dir = os.path.dirname(os.path.abspath(__file__))
    if script_dir not in sys.path:
        sys.path.insert(0, script_dir)

    # 2. Try all known import paths.
    for modpair in (("wifican_pb2", "wifican_pb2_grpc"),
                    ("collector.wifican_pb2", "collector.wifican_pb2_grpc")):
        try:
            pb2 = importlib.import_module(modpair[0])
            grpc_mod = importlib.import_module(modpair[1])
            return pb2, grpc_mod
        except ImportError as exc:  # noqa: PERF203
            errors.append(f"{modpair[0]}: {exc}")

    # 3. Try explicit paths (--stubs-path flag or olamate fallback).
    candidates = []
    if stubs_path:
        candidates.append(stubs_path)
    candidates.append(os.path.expanduser("~/personal/olamate/collector"))
    for path in candidates:
        if path and os.path.isdir(path):
            sys.path.insert(0, path)
            try:
                import wifican_pb2 as pb2  # type: ignore
                import wifican_pb2_grpc as grpc_mod  # type: ignore
                return pb2, grpc_mod
            except ImportError as exc:
                errors.append(f"{path}: {exc}")

    sys.exit(
        "ERROR: could not import wifican stubs.\n"
        "Run: pip install grpcio protobuf && python -m grpc_tools.protoc "
        "--proto_path=proto --python_out=scripts --grpc_python_out=scripts "
        "proto/wifican.proto\n"
        "Or pass --stubs-path /path/to/directory/with/wifican_pb2.py\n"
        "Tried:\n  " + "\n  ".join(errors)
    )


class Sender:
    """Owns the gRPC channel; runs `cansend` via ExecuteADBCommand, or prints
    the command in dry-run mode without connecting."""

    def __init__(self, ip: str, port: int, dry_run: bool, timeout: float,
                 stubs_path: str | None):
        self.addr = f"{ip}:{port}"
        self.dry_run = dry_run
        self.timeout = timeout
        self._stub = None
        self._channel = None
        self._pb2 = None
        if not dry_run:
            import grpc
            self._pb2, grpc_mod = _load_stubs(stubs_path)
            self._channel = grpc.insecure_channel(self.addr)
            self._stub = grpc_mod.WifiCanRpcStub(self._channel)

    def send_cansend(self, cmd_str: str) -> str:
        if self.dry_run:
            print(f"  [dry-run] {cmd_str}")
            return "DRY_RUN (not sent)"
        req = self._pb2.Command(cmd_msg=cmd_str)
        resp = self._stub.ExecuteADBCommand(req, timeout=self.timeout)
        status_name = getattr(resp, "status", "?")
        msg = getattr(resp, "status_msg", "")
        print(f"  {cmd_str}  ->  status={status_name} msg={msg!r}")
        return f"status={status_name} msg={msg!r}"

    def close(self):
        if self._channel is not None:
            self._channel.close()


# ---------------------------------------------------------------------------
# Command execution
# ---------------------------------------------------------------------------

def resolve_command_byte(args) -> int:
    """Map the chosen subcommand to a command byte, enforcing blocks."""
    name = args.command

    simple = {
        # Lock / unlock
        "unlock": 0x19,
        "lock": 0x54,
        "lock-steering": 0x01,
        "lock-no-steering": 0x02,
        "seat-unlock": 0x03,
        "cta-lock": 0x16,
        "cta-unlock": 0x17,
        # Indicators
        "indicator-left-on": 0x20,
        "indicator-left-off": 0x21,
        "indicator-right-on": 0x22,
        "indicator-right-off": 0x23,
        "auto-indicator-on": 0x3E,
        "auto-indicator-off": 0x3F,
        # Lights
        "highbeam-on": 0x1A,
        "highbeam-off": 0x1B,
        "lowbeam-on": 0x1C,
        "lowbeam-off": 0x1D,
        "rear-light-on": 0x1E,
        "rear-light-off": 0x1F,
        "drl-on": 0x24,
        "drl-off": 0x25,
        "headlight-on": 0x05,
        "headlight-off": 0x0A,
        "tmh-lights-on": 0x55,
        "tmh-lights-off": 0x56,
        # Smart headlight
        "smart-light-default": 0x2C,
        "smart-light-low": 0x2D,
        "smart-light-high": 0x2E,
        "smart-light-smart": 0x2F,
        "smart-drl-on": 0x38,
        "smart-drl-off": 0x39,
        "auto-headlight-on": 0x3A,
        "auto-headlight-off": 0x3B,
        # Hazard
        "hazard-on": 0x4A,
        "hazard-off": 0x4B,
        "hazard-brake-on": 0x3C,
        "hazard-brake-off": 0x3D,
        # Drive modes
        "eco-accept": 0x07,
        "eco-reject": 0x06,
        "boost-on": 0x30,
        "boost-off": 0x31,
        "reverse": 0x04,
        "ride-now": 0x53,
        # Regen
        "regen-default": 0x29,
        "regen-city": 0x2A,
        "regen-highway": 0x2B,
        # Hill hold
        "hill-hold-on": 0x42,
        "hill-hold-off": 0x43,
        # Motor cutoff delay
        "motor-cutoff-on": 0x40,
        "motor-cutoff-off": 0x41,
        # Safety features
        "accident-detect-on": 0x32,
        "accident-detect-off": 0x33,
        "tow-tamper-on": 0x34,
        "tow-tamper-off": 0x35,
        "tow-tamper-low": 0x4D,
        "tow-tamper-high": 0x4E,
        "proximity-on": 0x36,
        "proximity-off": 0x37,
        # Alarm
        "alarm-off": 0x09,
        "alarm-unlock": 0x57,
        # Vacation mode
        "vacation-on": 0x44,
        "vacation-off": 0x45,
        # Drive access
        "drive-revoke-on": 0x58,
        "drive-revoke-off": 0x59,
        # Side stand override
        "sidestand-disable": 0x5A,
        "sidestand-enable": 0x5B,
        # Wakeup
        "wakeup": 0x62,
        # Misc
        "trip-reset": 0x15,
        "stop-charge": 0x0D,
        "passcode-ack": 0x14,
    }
    if name in simple:
        return simple[name]
    if name == "raw":
        return parse_hex_byte(args.hex_byte)
    raise ValueError(f"unknown command: {name}")


def parse_hex_byte(token: str) -> int:
    token = token.strip().lower()
    try:
        value = int(token, 16) if token.startswith("0x") else int(token, 16)
    except ValueError:
        raise SystemExit(f"ERROR: '{token}' is not a hex byte (expected e.g. 0x20 or 20)")
    if not 0 <= value <= 0xFF:
        raise SystemExit(f"ERROR: byte {value:#x} out of range 0x00-0xFF")
    return value


def guard_command(cmd: int):
    """Refuse blocked commands and forbidden target IDs."""
    if cmd in BLOCKED_COMMANDS:
        raise SystemExit(
            f"BLOCKED: 0x{cmd:02X} ({BLOCKED_COMMANDS[cmd]}) is a dangerous "
            "command (reboot / OTA / profile delete) and is not allowed by this tool."
        )
    if COMMAND_CAN_ID in FORBIDDEN_CAN_IDS:
        raise SystemExit(f"BLOCKED: CAN ID 0x{COMMAND_CAN_ID:X} is forbidden.")


def run_send(args):
    cmd = resolve_command_byte(args)
    guard_command(cmd)

    name = VALUE_TO_NAME.get(cmd, "UNKNOWN")

    # Determine repeat/interval. unlock has its own defaults mirroring the
    # MasterCommander loop, overridable by explicit flags.
    if args.command == "unlock":
        repeat = args.repeat if args.repeat is not None else UNLOCK_REPEAT
        interval_ms = args.interval_ms if args.interval_ms is not None else UNLOCK_INTERVAL_MS
    else:
        repeat = args.repeat if args.repeat is not None else 1
        interval_ms = args.interval_ms if args.interval_ms is not None else 0

    if repeat < 1:
        raise SystemExit("ERROR: --repeat must be >= 1")

    cmd_str = build_cansend(COMMAND_CAN_ID, cmd)

    mode = "DRY-RUN" if args.dry_run else "LIVE"
    print(f"[{mode}] {name} (0x{cmd:02X}) -> CAN 0x{COMMAND_CAN_ID:X} on {CAN_INTERFACE}  "
          f"x{repeat} @ {interval_ms}ms")
    if not args.dry_run:
        print(f"         via ExecuteADBCommand to {args.ip}:{args.port}")

    sender = Sender(args.ip, args.port, args.dry_run, args.timeout, args.stubs_path)
    try:
        for i in range(repeat):
            if repeat > 1:
                print(f" [{i + 1}/{repeat}]", end="")
            sender.send_cansend(cmd_str)
            if i < repeat - 1 and interval_ms > 0:
                time.sleep(interval_ms / 1000.0)
    finally:
        sender.close()
    print("done.")


def run_uds_read(args):
    ecu = args.ecu.lower()
    if ecu not in UDS_ECU_CAN_IDS:
        raise SystemExit(f"ERROR: unknown ECU '{ecu}'. Choose from: {', '.join(UDS_ECU_CAN_IDS)}")

    if args.did_name:
        if args.did_name not in UDS_DIDS:
            raise SystemExit(
                f"ERROR: unknown DID name '{args.did_name}'. "
                f"Known DIDs: {', '.join(UDS_DIDS)}\n"
                "Or pass a hex DID directly: uds-read vcu 0xF190"
            )
        did, desc = UDS_DIDS[args.did_name]
    else:
        did = int(args.did_hex, 16)
        desc = f"DID 0x{did:04X}"

    req_id, resp_id = UDS_ECU_CAN_IDS[ecu]
    cmd_str = build_uds_read_frame(ecu, did)

    mode = "DRY-RUN" if args.dry_run else "LIVE"
    print(f"[{mode}] UDS ReadDataByIdentifier: {desc}")
    print(f"         ECU={ecu.upper()} request=0x{req_id:03X} response=0x{resp_id:03X}")
    print(f"         Monitor response: candump {CAN_INTERFACE},{resp_id:03X}:{resp_id:03X}")

    sender = Sender(args.ip, args.port, args.dry_run, args.timeout, args.stubs_path)
    try:
        sender.send_cansend(cmd_str)
    finally:
        sender.close()
    print("done. Watch candump for the response.")


def run_uds_session(args):
    ecu = args.ecu.lower()
    if ecu not in UDS_ECU_CAN_IDS:
        raise SystemExit(f"ERROR: unknown ECU '{ecu}'. Choose from: {', '.join(UDS_ECU_CAN_IDS)}")

    session_map = {"default": 0x01, "programming": 0x02, "extended": 0x03}
    session = session_map.get(args.session, None)
    if session is None:
        raise SystemExit(f"ERROR: unknown session '{args.session}'. Choose: default, programming, extended")

    if args.session == "programming":
        raise SystemExit("BLOCKED: programming session can enable firmware writes. Use extended instead.")

    req_id, resp_id = UDS_ECU_CAN_IDS[ecu]
    cmd_str = build_uds_session_frame(ecu, session)

    mode = "DRY-RUN" if args.dry_run else "LIVE"
    print(f"[{mode}] UDS DiagnosticSessionControl: {args.session} session")
    print(f"         ECU={ecu.upper()} request=0x{req_id:03X} response=0x{resp_id:03X}")

    sender = Sender(args.ip, args.port, args.dry_run, args.timeout, args.stubs_path)
    try:
        sender.send_cansend(cmd_str)
    finally:
        sender.close()
    print("done.")


def run_uds_dtc(args):
    ecu = args.ecu.lower()
    if ecu not in UDS_ECU_CAN_IDS:
        raise SystemExit(f"ERROR: unknown ECU '{ecu}'. Choose from: {', '.join(UDS_ECU_CAN_IDS)}")

    req_id, resp_id = UDS_ECU_CAN_IDS[ecu]
    cmd_str = build_uds_dtc_read_frame(ecu)

    mode = "DRY-RUN" if args.dry_run else "LIVE"
    print(f"[{mode}] UDS ReadDTCInformation (reportDTCByStatusMask, mask=0xFF)")
    print(f"         ECU={ecu.upper()} request=0x{req_id:03X} response=0x{resp_id:03X}")
    print(f"         Monitor response: candump {CAN_INTERFACE},{resp_id:03X}:{resp_id:03X}")

    sender = Sender(args.ip, args.port, args.dry_run, args.timeout, args.stubs_path)
    try:
        sender.send_cansend(cmd_str)
    finally:
        sender.close()
    print("done. Watch candump for the response (may be multi-frame).")


def run_uds_list(_args):
    print("UDS ECU CAN IDs:")
    for name, (req, resp) in sorted(UDS_ECU_CAN_IDS.items()):
        print(f"  {name.upper():4s}  request=0x{req:03X}  response=0x{resp:03X}")
    print("\nKnown DIDs (use with uds-read <ecu> --did <name>):")
    for name, (did, desc) in sorted(UDS_DIDS.items(), key=lambda kv: kv[1][0]):
        print(f"  {name:15s}  0x{did:04X}  {desc}")


def run_list(_args):
    print("CommandFromHMI table (name -> byte). Blocked commands marked [BLOCKED].")
    for name, val in sorted(COMMAND_FROM_HMI.items(), key=lambda kv: kv[1]):
        tag = "  [BLOCKED]" if val in BLOCKED_COMMANDS else ""
        print(f"  0x{val:02X}  {name}{tag}")


# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="scooter_cmd.py",
        description="Send CommandFromHMI commands to the Ola S1 Pro head unit "
                    "over gRPC (CAN 0x6BC). Owner-authorized research tool.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--ip", default="10.1.1.105", help="scooter IP (default 10.1.1.105)")
    p.add_argument("--port", type=int, default=50005, help="gRPC port (default 50005)")
    p.add_argument("--dry-run", action="store_true",
                   help="print the frame(s) that would be sent, connect to nothing")
    p.add_argument("--timeout", type=float, default=5.0, help="gRPC timeout seconds")
    p.add_argument("--stubs-path", default=None,
                   help="path to the directory holding wifican_pb2*.py "
                        "(default ~/personal/olamate/collector)")

    sub = p.add_subparsers(dest="command", required=True)

    # Shared parent for subcommands that send CAN frames — gives every
    # subcommand its own --repeat / --interval-ms so they work after the
    # subcommand name (argparse stops consuming parent args at the subcommand).
    send_parent = argparse.ArgumentParser(add_help=False)
    send_parent.add_argument("--repeat", type=int, default=None,
                             help="send the command N times (unlock defaults to 30)")
    send_parent.add_argument("--interval-ms", type=int, default=None,
                             help="delay between repeats in ms (unlock defaults to 100)")

    unlock_sp = sub.add_parser("unlock", parents=[send_parent],
                               help="PASSCODE_AUTH 0x19 x30 @100ms")
    unlock_sp.set_defaults(func=run_send)

    for name, help_text in [
        # Lock
        ("lock", "Lock_Now (0x54) — verified working"),
        ("lock-steering", "Lock_with_Steering (0x01) — needs scooter awake, state-dependent"),
        ("lock-no-steering", "Lock_without_Steering (0x02)"),
        ("seat-unlock", "Seat_Unlock_Cmd (0x03)"),
        ("cta-lock", "CTA_LOCK (0x16) — cloud-to-app lock path"),
        ("cta-unlock", "CTA_UNLOCK (0x17) — cloud-to-app unlock path"),
        # Indicators
        ("indicator-left-on", "Left_Indicator_ON (0x20) — direct CAN path"),
        ("indicator-left-off", "Left_Indicator_OFF (0x21)"),
        ("indicator-right-on", "Right_Indicator_ON (0x22) — direct CAN path"),
        ("indicator-right-off", "Right_Indicator_OFF (0x23)"),
        ("auto-indicator-on", "Auto_Indicator_Turn_off_Feature_Enable (0x3E)"),
        ("auto-indicator-off", "Auto_Indicator_Turn_off_Feature_Disable (0x3F)"),
        # Lights
        ("highbeam-on", "High_Beam_ON (0x1A) — direct CAN path"),
        ("highbeam-off", "High_Beam_OFF (0x1B)"),
        ("lowbeam-on", "Low_Beam_ON (0x1C) — direct CAN path"),
        ("lowbeam-off", "Low_Beam_OFF (0x1D)"),
        ("rear-light-on", "Rear_Light_ON (0x1E) — direct CAN path"),
        ("rear-light-off", "Rear_Light_OFF (0x1F)"),
        ("drl-on", "Front_DRL_ON (0x24) — direct CAN path"),
        ("drl-off", "Front_DRL_OFF (0x25)"),
        ("headlight-on", "Headlight_Turn_ON_Request (0x05)"),
        ("headlight-off", "Headlight_Turn_OFF_Request (0x0A)"),
        ("tmh-lights-on", "TMH_Lights_Enable (0x55) — Take Me Home lights"),
        ("tmh-lights-off", "TMH_Lights_Disabled (0x56)"),
        # Smart headlight
        ("smart-light-default", "Smart_Head_Light_Default (0x2C)"),
        ("smart-light-low", "Smart_Head_Light_Low_Beam (0x2D)"),
        ("smart-light-high", "Smart_Head_Light_High_Beam (0x2E)"),
        ("smart-light-smart", "Smart_Head_Light_Smart_Light (0x2F)"),
        ("smart-drl-on", "Smart_DRL_Light_Enable (0x38)"),
        ("smart-drl-off", "Smart_DRL_Light_Disable (0x39)"),
        ("auto-headlight-on", "Auto_Head_Light_Handling_Enable (0x3A)"),
        ("auto-headlight-off", "Auto_Head_Light_Handling_Disable (0x3B)"),
        # Hazard
        ("hazard-on", "Hazard_Light_Turn_ON (0x4A)"),
        ("hazard-off", "Hazard_Light_Turn_OFF (0x4B)"),
        ("hazard-brake-on", "Hazard_Light_Feature_Enable (0x3C) — hazard on hard brake"),
        ("hazard-brake-off", "Hazard_Light_Feature_Disable (0x3D)"),
        # Drive modes
        ("eco-accept", "ECO_Mode_Accepted_by_User (0x07)"),
        ("eco-reject", "ECO_Mode_Rejected_by_User (0x06)"),
        ("boost-on", "Boost_Mode_Enable_Selected (0x30)"),
        ("boost-off", "Boost_Mode_Disable_Selected (0x31)"),
        ("reverse", "Reverse_mode_activated (0x04)"),
        ("ride-now", "Ride_Now (0x53)"),
        # Regen
        ("regen-default", "Regen_Type_Default_SELECTED (0x29)"),
        ("regen-city", "Regen_Type_City_Ride_En_Selected (0x2A)"),
        ("regen-highway", "Regen_Type_Highway_Glide_En_Selected (0x2B)"),
        # Hill hold
        ("hill-hold-on", "Hill_Hold_Request_Enable_Selected (0x42)"),
        ("hill-hold-off", "Hill_Hold_Request_Disable_Selected (0x43)"),
        # Motor cutoff delay
        ("motor-cutoff-on", "Motor_Cutoff_Delay_Enable (0x40)"),
        ("motor-cutoff-off", "Motor_Cutoff_Delay_Disable (0x41)"),
        # Safety features
        ("accident-detect-on", "Accident_Detection_Enable_Selected (0x32)"),
        ("accident-detect-off", "Accident_Detection_Disable_Selected (0x33)"),
        ("tow-tamper-on", "Tow_Tamper_Detection_Enable_Selected (0x34)"),
        ("tow-tamper-off", "Tow_Tamper_Detection_Disable_Selected (0x35)"),
        ("tow-tamper-low", "Tow_Theft_Low_Sensitivity (0x4D)"),
        ("tow-tamper-high", "Tow_Theft_High_Sensitivity (0x4E)"),
        ("proximity-on", "Proximity_Lock_Unlock_Enable_Selected (0x36)"),
        ("proximity-off", "Proximity_Lock_Unlock_Disable_Selected (0x37)"),
        # Alarm
        ("alarm-off", "ALARM_Turn_Off_Request (0x09)"),
        ("alarm-unlock", "Alarm_unlock_Now (0x57)"),
        # Vacation mode
        ("vacation-on", "VACATION_MODE_ON (0x44)"),
        ("vacation-off", "VACATION_MODE_OFF (0x45)"),
        # Drive access
        ("drive-revoke-on", "Drive_access_revoked_enable (0x58)"),
        ("drive-revoke-off", "Drive_access_revoked_disable (0x59)"),
        # Side stand override
        ("sidestand-disable", "SIDE_STAND_DISABLE (0x5A)"),
        ("sidestand-enable", "SIDE_STAND_ENABLE (0x5B)"),
        # Wakeup
        ("wakeup", "HMI_Wakeup_pass (0x62) — may wake MCU bridge, test needed"),
        # Misc
        ("trip-reset", "TripoMeter_Reset_Successfull (0x15)"),
        ("stop-charge", "Stop_Charge (0x0D)"),
        ("passcode-ack", "Passcode_ACK (0x14)"),
    ]:
        sp = sub.add_parser(name, parents=[send_parent], help=help_text)
        sp.set_defaults(func=run_send)

    raw = sub.add_parser("raw", parents=[send_parent], help="send an arbitrary command byte, e.g. raw 0x20")
    raw.add_argument("hex_byte", help="command byte in hex (0x20 or 20)")
    raw.set_defaults(func=run_send)

    lst = sub.add_parser("list", help="print the CommandFromHMI table and exit")
    lst.set_defaults(func=run_list)

    # --- UDS subcommands (read-only diagnostics) ---

    uds_read_sp = sub.add_parser(
        "uds-read", help="UDS ReadDataByIdentifier (0x22) — read a DID from an ECU")
    uds_read_sp.add_argument("ecu", choices=["bms", "vcu", "mcu"],
                             help="target ECU")
    uds_read_group = uds_read_sp.add_mutually_exclusive_group(required=True)
    uds_read_group.add_argument("--did", dest="did_name", default=None,
                                help=f"DID by name ({', '.join(UDS_DIDS)})")
    uds_read_group.add_argument("--did-hex", dest="did_hex", default=None,
                                help="DID as hex value (e.g. 0xF190 or F190)")
    uds_read_sp.set_defaults(func=run_uds_read)

    uds_session_sp = sub.add_parser(
        "uds-session", help="UDS DiagnosticSessionControl (0x10) — switch session")
    uds_session_sp.add_argument("ecu", choices=["bms", "vcu", "mcu"],
                                help="target ECU")
    uds_session_sp.add_argument("session", choices=["default", "extended"],
                                help="session type (programming is blocked)")
    uds_session_sp.set_defaults(func=run_uds_session)

    uds_dtc_sp = sub.add_parser(
        "uds-dtc", help="UDS ReadDTCInformation (0x19) — read fault codes from an ECU")
    uds_dtc_sp.add_argument("ecu", choices=["bms", "vcu", "mcu"],
                            help="target ECU")
    uds_dtc_sp.set_defaults(func=run_uds_dtc)

    uds_list_sp = sub.add_parser(
        "uds-list", help="print UDS ECU CAN IDs and known DIDs")
    uds_list_sp.set_defaults(func=run_uds_list)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
