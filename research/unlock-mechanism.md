# Scooter Unlock Mechanism via CAN Bus

## Overview

The Ola S1 Pro Gen 1 scooter unlock (passcode authentication) uses
CAN ID **0x6BC** on `vcan0`. This is the HMI→BCM/VCU command channel
used by the stock HVDP (`com.olaelectric.vehicleparser`) service.

The command path that works is `cansend` via gRPC `ExecuteADBCommand`:

```
cansend vcan0 6BC#1900000000000000
```

gRPC `WriteCanFrame` writes appear on vcan0 but are **not bridged** to the
physical CAN bus by the MCU. Standard SocketCAN writes (`cansend`) are bridged.

## Service Architecture

```
User enters passcode on HMI
  → HHMIC (HMI client app)
  → HVSM (VehicleStateController.sendUnlockByPasscode())
  → AIDL binder IPC: ICommanderService.unlockedByPasscode(true)
  → HVDP (CommanderServiceImpl → MasterCommander.scooterUnlockedByPassCode())
  → Loop 30x at 100ms: sendScooterCommands(0x19)
  → CanUtils.sendCan0Data(CanId(0x6BC), [0x19,0,0,0,0,0,0,0])
  → CanSocket.send() → native _sendFrame() via libJNIStubTest.so
  → Linux SocketCAN write on vcan0
  → MCU bridges to physical CAN bus
  → VCU/BCM processes unlock
```

## CAN Frame Details

| Field  | Value |
|--------|-------|
| CAN ID | 0x6BC |
| DLC    | 8     |
| Byte 0 | 0x19 (25 decimal = PASSCODE_AUTH command) |
| Byte 1-7 | 0x00 |

Sent **30 times** at **100ms intervals** (3 seconds total).

## Key Code Locations (decompiled smali)

- **HVSM**: `VehicleStateController.sendUnlockByPasscode()` — entry point
- **HVSM**: `VehicleParserManager.sendUnlockedByPasscode()` — AIDL call
- **HVDP**: `CommanderServiceImpl.unlockedByPasscode(boolean)` — binder receiver
- **HVDP**: `MasterCommander.scooterUnlockedByPassCode(boolean)` — the 30-iteration loop
- **HVDP**: `MasterCommander.sendScooterCommands(int)` — frame construction and send
- **HVDP**: `CanUtils.sendCan0Data()` → `CanSocket.send()` → native `_sendFrame()`

## Native Library

HVDP uses `libJNIStubTest.so` (loaded via `System.loadLibrary("JNIStubTest")`)
for raw SocketCAN access. This is separate from `libcan_jni.so` used by
VehicleDataService.

## Command Routing in sendScooterCommands

Commands are routed to two paths based on their type:

### Direct 0x6BC path (immediate CanSocket write)
These commands bypass BCMEventHandler and write directly to vcan0:
- All light commands: High_Beam ON/OFF, Low_Beam ON/OFF, Rear_Light ON/OFF,
  Left/Right_Indicator ON/OFF, Front_DRL ON/OFF
- **PASSCODE_AUTH** (0x19) — the unlock command

### BCMEventHandler path (queued via Runnable)
All other commands go through BCMEventHandler.sendEvent(), which wraps the
0x6BC write in a Runnable sent to a handler thread. This includes:
- Lock_with_Steering (0x01), Lock_without_Steering (0x02)
- Seat_Unlock_Cmd (0x03)
- CTA_LOCK (0x16), CTA_UNLOCK (0x17)
- Feature toggles (regen, boost, accident detection, etc.)
- OTA commands, reboot commands, diagnostic commands
- All other commands

Both paths ultimately write the same frame format to 0x6BC — the routing
difference is about timing and thread handling, not frame content.

## Full 0x6BC Command Table (CommandFromHMI enum)

```
0x00: No_Command
0x01: Lock_with_Steering
0x02: Lock_without_Steering
0x03: Seat_Unlock_Cmd
0x04: Reverse_mode_activated
0x05: Headlight_Turn_ON_Request
0x06: ECO_Mode_Rejected_by_User
0x07: ECO_Mode_Accepted_by_User
0x08: Vehicle_Shutdown_is_Rejected_by_User
0x09: ALARM_Turn_Off_Request
0x0A: Headlight_Turn_OFF_Request
0x0B: Accepted_Get_Home_Request
0x0C: Rejected_Get_Home_Request
0x0D: Stop_Charge
0x0E: Scooter_Reboot
0x0F: OTA_Installation_Started
0x10: OTA_Installation_in_Progress
0x11: OTA_Installation_Complete
0x12: MCU_Reboot
0x13: HU_Reboot
0x14: Passcode_ACK
0x15: TripoMeter_Reset_Successfull
0x16: CTA_LOCK
0x17: CTA_UNLOCK
0x18: CTA_IGNORE
0x19: PASSCODE_AUTH
0x1A: High_Beam_ON
0x1B: High_Beam_OFF
0x1C: Low_Beam_ON
0x1D: Low_Beam_OFF
0x1E: Rear_Light_ON
0x1F: Rear_Light_OFF
0x20: Left_Indicator_ON
0x21: Left_Indicator_OFF
0x22: Right_Indicator_ON
0x23: Right_Indicator_OFF
0x24: Front_DRL_ON
0x25: Front_DRL_OFF
0x26: AUTO_HEADLIGHT_SUNRISE_EN
0x27: Auto_HEAD_LIGHT_SUNSET_EN
0x28: Auto_Head_Light_Reserved
0x29: Regen_Type_Default_SELECTED
0x2A: Regen_Type_City_Ride_En_Selected
0x2B: Regen_Type_Highway_Glide_En_Selected
0x2C: Smart_Head_Light_Default_Selected
0x2D: Smart_Head_Light_Low_Beam_En_Selected
0x2E: Smart_Head_Light_High_Beam_En_Selected
0x2F: Smart_Head_Light_Smart_Light_En_Selected
0x30: Boost_Mode_Enable_Selected
0x31: Boost_Mode_Disable_Selected
0x32: Accident_Detection_Enable_Selected
0x33: Accident_Detection_Disable_Selected
0x34: Tow_Tamper_Detection_Enable_Selected
0x35: Tow_Tamper_Detection_Disable_Selected
0x36: Proximity_Lock_Unlock_Enable_Selected
0x37: Proximity_Lock_Unlock_Disable_Selected
0x38: Smart_DRL_Light_Enable_Selected
0x39: Smart_DRL_Light_Disable_Selected
0x3A: Auto_Head_Light_Handling_Enable_Selected
0x3B: Auto_Head_Light_Handling_Disable_Selected
0x3C: Hazard_Light_Feature_Enable_Selected
0x3D: Hazard_Light_Feature_Disable_Selected
0x3E: Auto_Indicator_Turn_off_Feature_Enable_Selected
0x3F: Auto_Indicator_Turn_off_Feature_Disable_Selected
0x40: Motor_Cutoff_Delay_Selected_Enable_Selected
0x41: Motor_Cutoff_Delay_Selected_Disable_Selected
0x42: Hill_Hold_Request_Enable_Selected
0x43: Hill_Hold_Request_Disable_Selected
0x44: VACATION_MODE_ON
0x45: VACATION_MODE_OFF
0x46: NEED_HELP
0x47: I_AM_SAFE
0x48: DELETE_PROFILE
0x49: USER_CALIBRATION_REQUEST
0x4A: Hazard_Light_Turn_ON
0x4B: Hazard_Light_Turn_OFF
0x4C: HMI_Alarm_ignore_True
0x4D: Tow_Theft_Low_Sensitivity
0x4E: Tow_Theft_High_Sensitivity
0x4F: HMI_Alarm_ignore_False
0x50: Exit_Diagnostic_Mode
0x51: Version_Mismatched
0x52: Smart_Head_Light_SMART_LIGHT_EN_Deselected
0x53: Ride_Now
0x54: Lock_Now
0x55: TMH_Lights_Enable
0x56: TMH_Lights_Disabled
0x57: Alarm_unlock_Now
0x58: Drive_acess_revoked_enable
0x59: Drive_acess_revoked_disable
0x5A: SIDE_STAND_DISABLE
0x5B: SIDE_STAND_ENABLE
0x5C: Brake_Switch_Fault_Deactivate
0x5D: Brake_Switch_Fault_Activate
0x5E: AI_Ind_OFF
0x5F: Brk_Snsr_Fail_detect_AI
0x60: Brk_Snsr_Fail_clear_AI
0x61: OTA_MCU_Reset
0x62: HMI_Wakeup_pass
```

## MCU Bridge State Dependency

The MCU that bridges `vcan0` to the physical CAN bus is **state-dependent**.
Commands sent via `cansend` (including through gRPC `ExecuteADBCommand`) are
silently dropped when the scooter is in a locked/standby state, even though the
head unit is still running and responding to gRPC.

| Scooter State | gRPC Reachable | cansend → Physical Bus |
|---------------|----------------|------------------------|
| **Awake** (screen on, actively used) | Yes | Yes |
| **Locked/Standby** (screen off, idle) | Yes | **No** — silently dropped |

**Observed behavior (2026-11-03):**
- Commands worked when the scooter was actively awake (indicators, unlock, lock-now all confirmed)
- After sitting locked for a while, the same commands (indicator, unlock, lock) had no effect
- gRPC still returned `status=1` (RESP_SUCCESS), but the MCU bridge did not forward frames
- Manual unlock (via app/button) woke the scooter through a hardware path, after which CAN commands worked again

This means CAN command injection only works when the scooter is already awake.
Waking the scooter remotely through the head unit alone is not currently possible —
the BMS controls the wake path.

## Safety Notes

- CAN ID 0x6BC is a security-sensitive command channel (HMI → BCM/VCU)
- Writing arbitrary commands to 0x6BC could have unintended effects
- The CLI tool (`scripts/scooter_cmd.py`) blocks dangerous commands:
  Scooter_Reboot, MCU_Reboot, HU_Reboot, OTA commands, DELETE_PROFILE, OTA_MCU_Reset
- CAN ID 0x6A1 is refused entirely
