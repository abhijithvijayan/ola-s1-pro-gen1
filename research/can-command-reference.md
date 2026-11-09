# CAN Command Reference — 0x6BC HMI Command Channel

Analysis of the HMI → vehicle command path from decompiled HVDP
(`com.olaelectric.vehicleparser`) and HVSM (`com.olaelectric.vehiclestatemanager`)
APKs.

## Sending Commands

All 99 `CommandFromHMI` commands use CAN ID **0x6BC** on `vcan0`. Send via
`cansend` over the gRPC `ExecuteADBCommand` RPC:

```bash
# Generic pattern
ExecuteADBCommand("cansend vcan0 6BC#<cmd>00000000000000")

# Example: left indicator on (0x20)
ExecuteADBCommand("cansend vcan0 6BC#2000000000000000")
```

Using the CLI tool:

```bash
cd ~/personal/olamate && PYTHONPATH=. .venv/bin/python \
    ~/personal/ola-s1-pro-gen1/scripts/scooter_cmd.py --ip <IP> indicator-left-on
```

gRPC `WriteCanFrame` returns SUCCESS but the MCU does not bridge those frames
to the physical CAN bus. Use `cansend` via `ExecuteADBCommand` instead.

## Unlock (PASSCODE_AUTH)

| Property | Value |
|----------|-------|
| CAN ID | **0x6BC** (on `vcan0`) |
| Command byte | **0x19** (25 decimal) |
| Repetition | **30 times** (loop guard `0x1e`) |
| Interval | **100 ms** (`TimeUnit.MILLISECONDS.sleep(0x64)`) |
| Frame data | `19 00 00 00 00 00 00 00` |
| Native library | **libJNIStubTest.so** (`System.loadLibrary("JNIStubTest")`) |

```bash
# Unlock command (30x at 100ms via CLI)
scooter_cmd.py --ip <IP> unlock --confirm
```

## 8-byte CAN Data Layout

```
byte 0   : command byte (from CommandFromHMI enum ordinal)
byte 1-7 : 0x00
```

## Call Chain (HVSM → native socket write)

```
VehicleStateController.sendUnlockByPasscode()                        [HVSM]
  → VehicleParserManager.sendUnlockedByPasscode()                    [HVSM]
  → AIDL binder: ICommanderService.unlockedByPasscode(true)
  → CommanderServiceImpl.unlockedByPasscode(boolean)                 [HVDP]
  → MasterCommander.scooterUnlockedByPassCode(boolean)               [HVDP]
       loop while sendUnlockAuthFlag && passcodeTriggerCount < 0x1e:
         sendScooterCommands(0x19)
         passcodeTriggerCount++
         TimeUnit.MILLISECONDS.sleep(0x64)
  → MasterCommander.sendScooterCommands(int)                         [HVDP]
  → CanUtils.sendCan0Data(CanSocket.CanId(0x6BC), byte[8])           [HVDP]
  → CanSocket.send(CanFrame)
  → native _sendFrame(int, int, int, byte[])  in libJNIStubTest.so
  → Linux SocketCAN write on vcan0
```

## Command Routing

`MasterCommander.sendScooterCommands(int)` routes by the command's ordinal.
`No_Command` (0x00) returns immediately. One fixed set is written **directly**
via `CanUtils.sendCan0Data`; every other command is wrapped in a `Runnable` and
queued through `BCMEventHandler.sendEvent(Runnable)`. Both paths build an
identical frame on CAN 0x6BC — the difference is threading/timing, not content.

### Direct CanSocket path (immediate write)

- PASSCODE_AUTH (0x19)
- High_Beam_ON/OFF (0x1A/0x1B)
- Low_Beam_ON/OFF (0x1C/0x1D)
- Rear_Light_ON/OFF (0x1E/0x1F)
- Left_Indicator_ON/OFF (0x20/0x21)
- Right_Indicator_ON/OFF (0x22/0x23)
- Front_DRL_ON/OFF (0x24/0x25)

### BCMEventHandler path (queued via Runnable)

Everything else, including:
- Lock_with_Steering (0x01), Lock_without_Steering (0x02)
- Seat_Unlock_Cmd (0x03)
- CTA_LOCK (0x16), CTA_UNLOCK (0x17), CTA_IGNORE (0x18)
- Hazard_Light_Turn_ON/OFF (0x4A/0x4B)
- All feature toggles (regen, boost, accident detection, hill hold, etc.)

## CommandFromHMI Enum (99 commands)

Extracted from `com/olaelectric/vehicleinterface/CommandFromHMI.smali`.
The enum ordinal is the command byte sent in byte 0 of the 0x6BC frame.

| Hex | Dec | Name | Notes |
|-----|-----|------|-------|
| 0x00 |   0 | No_Command | |
| 0x01 |   1 | Lock_with_Steering | |
| 0x02 |   2 | Lock_without_Steering | |
| 0x03 |   3 | Seat_Unlock_Cmd | |
| 0x04 |   4 | Reverse_mode_activated | |
| 0x05 |   5 | Headlight_Turn_ON_Request | |
| 0x06 |   6 | ECO_Mode_Rejected_by_User | |
| 0x07 |   7 | ECO_Mode_Accepted_by_User | |
| 0x08 |   8 | Vehicle_Shutdown_is_Rejected_by_User | |
| 0x09 |   9 | ALARM_Turn_Off_Request | |
| 0x0A |  10 | Headlight_Turn_OFF_Request | |
| 0x0B |  11 | Accepted_Get_Home_Request | |
| 0x0C |  12 | Rejected_Get_Home_Request | |
| 0x0D |  13 | Stop_Charge | |
| 0x0E |  14 | Scooter_Reboot | **blocked by CLI** |
| 0x0F |  15 | OTA_Installation_Started | **blocked by CLI** |
| 0x10 |  16 | OTA_Installation_in_Progress | **blocked by CLI** |
| 0x11 |  17 | OTA_Installation_Complete | **blocked by CLI** |
| 0x12 |  18 | MCU_Reboot | **blocked by CLI** |
| 0x13 |  19 | HU_Reboot | **blocked by CLI** |
| 0x14 |  20 | Passcode_ACK | |
| 0x15 |  21 | TripoMeter_Reset_Successfull | |
| 0x16 |  22 | CTA_LOCK | |
| 0x17 |  23 | CTA_UNLOCK | |
| 0x18 |  24 | CTA_IGNORE | |
| 0x19 |  25 | PASSCODE_AUTH | unlock command |
| 0x1A |  26 | High_Beam_ON | direct path |
| 0x1B |  27 | High_Beam_OFF | direct path |
| 0x1C |  28 | Low_Beam_ON | direct path |
| 0x1D |  29 | Low_Beam_OFF | direct path |
| 0x1E |  30 | Rear_Light_ON | direct path |
| 0x1F |  31 | Rear_Light_OFF | direct path |
| 0x20 |  32 | Left_Indicator_ON | direct path |
| 0x21 |  33 | Left_Indicator_OFF | direct path |
| 0x22 |  34 | Right_Indicator_ON | direct path |
| 0x23 |  35 | Right_Indicator_OFF | direct path |
| 0x24 |  36 | Front_DRL_ON | direct path |
| 0x25 |  37 | Front_DRL_OFF | direct path |
| 0x26 |  38 | AUTO_HEADLIGHT_SUNRISE_EN | |
| 0x27 |  39 | Auto_HEAD_LIGHT_SUNSET_EN | |
| 0x28 |  40 | Auto_Head_Light_Reserved | |
| 0x29 |  41 | Regen_Type_Default_SELECTED | |
| 0x2A |  42 | Regen_Type_City_Ride_En_Selected | |
| 0x2B |  43 | Regen_Type_Highway_Glide_En_Selected | |
| 0x2C |  44 | Smart_Head_Light_Default_Selected | |
| 0x2D |  45 | Smart_Head_Light_Low_Beam_En_Selected | |
| 0x2E |  46 | Smart_Head_Light_High_Beam_En_Selected | |
| 0x2F |  47 | Smart_Head_Light_Smart_Light_En_Selected | |
| 0x30 |  48 | Boost_Mode_Enable_Selected | |
| 0x31 |  49 | Boost_Mode_Disable_Selected | |
| 0x32 |  50 | Accident_Detection_Enable_Selected | |
| 0x33 |  51 | Accident_Detection_Disable_Selected | |
| 0x34 |  52 | Tow_Tamper_Detection_Enable_Selected | |
| 0x35 |  53 | Tow_Tamper_Detection_Disable_Selected | |
| 0x36 |  54 | Proximity_Lock_Unlock_Enable_Selected | |
| 0x37 |  55 | Proximity_Lock_Unlock_Disable_Selected | |
| 0x38 |  56 | Smart_DRL_Light_Enable_Selected | |
| 0x39 |  57 | Smart_DRL_Light_Disable_Selected | |
| 0x3A |  58 | Auto_Head_Light_Handling_Enable_Selected | |
| 0x3B |  59 | Auto_Head_Light_Handling_Disable_Selected | |
| 0x3C |  60 | Hazard_Light_Feature_Enable_Selected | |
| 0x3D |  61 | Hazard_Light_Feature_Disable_Selected | |
| 0x3E |  62 | Auto_Indicator_Turn_off_Feature_Enable_Selected | |
| 0x3F |  63 | Auto_Indicator_Turn_off_Feature_Disable_Selected | |
| 0x40 |  64 | Motor_Cutoff_Delay_Selected_Enable_Selected | |
| 0x41 |  65 | Motor_Cutoff_Delay_Selected_Disable_Selected | |
| 0x42 |  66 | Hill_Hold_Request_Enable_Selected | |
| 0x43 |  67 | Hill_Hold_Request_Disable_Selected | |
| 0x44 |  68 | VACATION_MODE_ON | |
| 0x45 |  69 | VACATION_MODE_OFF | |
| 0x46 |  70 | NEED_HELP | |
| 0x47 |  71 | I_AM_SAFE | |
| 0x48 |  72 | DELETE_PROFILE | **blocked by CLI** |
| 0x49 |  73 | USER_CALIBRATION_REQUEST | |
| 0x4A |  74 | Hazard_Light_Turn_ON | |
| 0x4B |  75 | Hazard_Light_Turn_OFF | |
| 0x4C |  76 | HMI_Alarm_ignore_True | |
| 0x4D |  77 | Tow_Theft_Low_Sensitivity | |
| 0x4E |  78 | Tow_Theft_High_Sensitivity | |
| 0x4F |  79 | HMI_Alarm_ignore_False | |
| 0x50 |  80 | Exit_Diagnostic_Mode | |
| 0x51 |  81 | Version_Mismatched | |
| 0x52 |  82 | Smart_Head_Light_SMART_LIGHT_EN_Deselected | |
| 0x53 |  83 | Ride_Now | |
| 0x54 |  84 | Lock_Now | |
| 0x55 |  85 | TMH_Lights_Enable | |
| 0x56 |  86 | TMH_Lights_Disabled | |
| 0x57 |  87 | Alarm_unlock_Now | |
| 0x58 |  88 | Drive_acess_revoked_enable | |
| 0x59 |  89 | Drive_acess_revoked_disable | |
| 0x5A |  90 | SIDE_STAND_DISABLE | |
| 0x5B |  91 | SIDE_STAND_ENABLE | |
| 0x5C |  92 | Brake_Switch_Fault_Deactivate | |
| 0x5D |  93 | Brake_Switch_Fault_Activate | |
| 0x5E |  94 | AI_Ind_OFF | |
| 0x5F |  95 | Brk_Snsr_Fail_detect_AI | |
| 0x60 |  96 | Brk_Snsr_Fail_clear_AI | |
| 0x61 |  97 | OTA_MCU_Reset | **blocked by CLI** |
| 0x62 |  98 | HMI_Wakeup_pass | |

## CAN Frame Format

**`cansend` (active path):**

```
cansend vcan0 6BC#<8 data bytes hex>
```

`cansend` takes the logical 11-bit CAN ID directly. DLC is inferred from
the number of data bytes (8).

**gRPC `WriteCanFrame` raw layout (16 bytes, for reference only — not used for sending):**

```
offset  size  field
0       4     CAN ID, big-endian          e.g. 0x6BC → 00 00 06 BC
4       1     DLC                          0x08
5       3     padding                      00 00 00
8       8     data                         byte0=command, rest 0
```

## CLI Quick Reference

```bash
# Toggle left indicator
scooter_cmd.py --ip <IP> indicator-left-on
scooter_cmd.py --ip <IP> indicator-left-off

# High beam
scooter_cmd.py --ip <IP> highbeam-on
scooter_cmd.py --ip <IP> highbeam-off

# Seat unlock
scooter_cmd.py --ip <IP> seat-unlock

# Hazard lights
scooter_cmd.py --ip <IP> hazard-on
scooter_cmd.py --ip <IP> hazard-off

# Unlock (30x at 100ms, requires confirmation)
scooter_cmd.py --ip <IP> unlock --confirm

# Lock
scooter_cmd.py --ip <IP> lock

# Send raw command byte
scooter_cmd.py --ip <IP> raw 0x30   # Boost_Mode_Enable_Selected

# List all commands
scooter_cmd.py --ip <IP> list

# Dry run (shows what would be sent)
scooter_cmd.py --ip <IP> --dry-run unlock --confirm
```

## Safety

- CAN ID 0x6BC is a security-sensitive command channel (HMI → BCM/VCU)
- The CLI blocks dangerous commands: Scooter_Reboot, MCU_Reboot, HU_Reboot, OTA commands, DELETE_PROFILE, OTA_MCU_Reset
- CAN ID 0x6A1 is refused entirely
- `unlock` requires `--confirm` flag
