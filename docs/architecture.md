# Ola S1 Pro Gen 1 Architecture

## Two Computers, Not One

The handlebar unit is an Android tablet. It does NOT drive the motor. The scooter has two independent computer systems connected by a CAN bus:

```
+----------------------------------------------------------+
|                    HEAD UNIT (Android)                    |
|                                                          |
|  Qualcomm SDM450 (Snapdragon 450)                       |
|  8x Cortex-A53, ~2.85 GB RAM, 1280x768 touchscreen      |
|  Android 10, MoveOS 4.x                                 |
|                                                          |
|  Jobs:                                                   |
|   - Draw the dashboard UI (Kanzi renderer)               |
|   - Talk to Ola cloud over 4G (MQTT)                     |
|   - Show CAN bus data (speed, battery, etc.)             |
|   - Play Bluetooth music                                 |
|   - Run the diagnostics server (port 50005)              |
|   - Handle OTA firmware updates                          |
|                                                          |
|  Does NOT: control motor, lock/unlock, manage battery    |
+----------------------------+-----------------------------+
                             |
                    UART (/dev/ttyHSL1 @ 921600)
                             |
                    +--------+--------+
                    |  UART-to-CAN    |
                    |  Bridge chip    |
                    +--------+--------+
                             |
              ===============+===========================  CAN Bus
              ||         ||          ||          ||
         +----++----++---++---++----++----++----++----+
         |   VCU   ||  BMS   ||   BCM   ||   BLE   |
         | Vehicle ||Battery || Body    ||Bluetooth|
         |Controller|Management| Control || Module  |
         +---------++---------++---------++---------+
```

The head unit is a terminal, not the authority. If the HMI app dies, the scooter still works — you just lose the screen.

## Physical Components

| Component | Hardware | Role |
|-----------|----------|------|
| Head unit | Qualcomm SDM450, 2.85 GB RAM, 1280x768 touch, Wi-Fi + 4G + BT + GPS | Android tablet: draws UI, talks to cloud |
| VCU | Separate MCU | Motor control, lock/unlock authority, drive modes, safety |
| BMS | Separate MCU | Battery pack management (14S NMC, ~57V), wake/sleep gatekeeper |
| BCM | ARM Cortex-M | Lights, indicators, horn, side stand, trunk |
| MCU | TI C2000 C28x | BLDC motor driver |
| BLE module | ARM Cortex-M | Always-on BLE for Ola app (separate from head unit BT) |

## CAN Bus

The CAN bus is bridged to Android as `vcan0` via UART. Active stats: ~970 frames/sec when awake, ~2 frames/sec asleep, ~188 unique IDs.

### Key CAN IDs

| ID | Source | Contents |
|----|--------|----------|
| `0x120` | BMS | Overall SoC |
| `0x150` | BMS | Pack voltage, SoH |
| `0x1A4`-`0x1AA` | BMS | Cell voltages (14 cells), temp sensors |
| `0x313` | MCU | Motor RPM, temperatures |
| `0x352` | VCU | Speed, display SoC |
| `0x356` | VCU | Odometer (LE32, in metres) |
| `0x683` | VCU | Safety state (fall, tow, regen, hill hold) |
| `0x6F4` | VCU | Range per mode |
| `0x6BC` | Head unit -> VCU | Passcode/unlock commands |
| `0x6C0` | VCU -> Head unit | Command ACK |
| `0x6A1` | TCU -> VCU | Cloud commands (the head unit never sends this) |

### UDS Diagnostic CAN IDs

The ECUs are addressable via UDS (ISO 14229) over CAN:

| ECU | Request ID | Response ID |
|-----|-----------|-------------|
| BMS | `0x078E`  | `0x07B1`    |
| VCU | `0x0786`  | `0x07B0`    |
| MCU | `0x07A6`  | `0x07B4`    |

### Software Version CAN IDs

| Component       | CAN ID   |
|-----------------|----------|
| BMS             | `0x620`  |
| MCU             | `0x623`  |
| Vehicle         | `0x677`  |
| BCM             | `0x679`  |
| BLE             | `0x691` (old) / `0x697` (new) |
| EC200 (modem)   | `0x6EE`  |
| Vehicle Type Ext| `0x7D0`  |

### Additional CAN IDs (from diagnostics app)

| ID | Purpose |
|----|---------|
| `0x0AAA` | Periodic message start/stop (diagnostics) |
| `0x7C1`  | Phase 2 scooter reboot (newer hardware) |

Full CAN map with formulas: see `research/can-command-reference.md`.

## Command Channels

The scooter has two independent CAN command channels:

| Channel | CAN ID | Direction | Used by |
|---------|--------|-----------|---------|
| HMI     | `0x6BC`| Head unit → VCU | HVDP (on-device commands, passcode unlock, feature toggles) |
| TCU     | `0x6A1`| TCU/cloud → VCU | Cloud MQTT commands, diagnostics app (lock/unlock/horn/trunk/light) |

The head unit apps only write to `0x6BC`. The diagnostics app uses `0x6A1` for
remote commands like lock/unlock — the same channel the TCU uses for cloud
commands from the Ola mobile app. VCU ACKs come back on `0x6C0`.

## Two Bluetooths

The scooter has **two separate BT radios**:

| Module | Location | Purpose |
|--------|----------|---------|
| Android BT | Head unit (SDM450) | A2DP music, AVRCP, HFP calls |
| Vehicle BLE | BCM (separate hardware) | Ola app proximity unlock, always-on |

The Ola app connects to the vehicle BLE module, NOT the head unit Bluetooth. The head unit is not part of the app unlock chain.

## Data Flow

**Sensor to screen (read):**
```
Physical sensor -> ECU reads via ADC -> encodes CAN frame -> CAN bus
-> UART bridge -> vcan0 -> VehicleParser decodes -> Kanzi UI renders
```

**Command to vehicle (write):**
```
User enters passcode -> ProfileManagerService verifies (scrypt)
-> VehicleParser sends command on CAN 0x6BC -> UART bridge -> CAN bus
-> VCU receives -> ACKs on 0x6C0 -> UI updates
```

## Boot and Wake

The BMS is the gatekeeper — only it can wake the vehicle:

| Wake reason | Trigger |
|-------------|---------|
| Charger_CAN_Wakeup | Charger plugged in |
| IMU_Wakeup | Movement/tamper detected |
| SoC_Push_Button_Wakeup | Red Start/Stop button |
| RTC_Wakeup | Scheduled timer |

The head unit cannot wake the scooter. No CAN frame substitutes for these hardware triggers.

## Cloud Connectivity

```
Phone (Ola app) -> Ola cloud (HTTPS) -> MQTT push -> Head unit CloudConnectManager
Phone (Ola app) -> Vehicle BLE module -> BCM -> VCU  (lock/unlock, bypasses head unit)
```

MQTT (Eclipse Paho) is always-on over Jio 4G. Carries telemetry, remote commands, config, OTA triggers.

## Head Unit Controls vs. Observes

| Controls | Only observes |
|----------|---------------|
| Screen (Kanzi UI) | Battery, voltage, current, temperature |
| Bluetooth audio | Motor RPM, torque, temperature |
| Wi-Fi, cloud (MQTT) | Speed, odometer, range |
| OTA download | Drive mode, lock state |
| Engine sound | Side stand, trunk, lights |
| Navigation display | Fault codes, GPS |
| Passcode verification | Safety state |

## Installed Ola Apps

All in `/system/priv-app` or `/vendor/app`:

| Package | Purpose |
|---------|---------|
| `com.olaelectric.hmiclient` | Main HMI / launcher (Kanzi, v4.6.14) |
| `com.android.hmiserverapp` | HMI backend server |
| `com.ola.mfgapp` | Technician app (mode switch, hotspot) |
| `com.olaelectric.ota` | OTA firmware updates |
| `com.olaelectric.cloudconnectivitymanager` | Cloud MQTT |
| `com.olaelectric.vehicleparser` | Vehicle data / CAN parser |
| `com.olaelectric.vehiclestatemanager` | Vehicle state |
| `com.olaelectric.profilemanagerservice` | User profiles, passcode |
| `com.olaelectric.enginesound` | Engine sound synthesis |
| `com.olaelectric.canlogger` | CAN bus logger |
| `com.olaelectric.udstestapp` | UDS diagnostics |
| ...and 13 more | Navigation, range, health, AI, connectivity |

Notable Android system apps also present: Settings, Bluetooth, Chromium WebView, FM Radio, Music player, Gallery, Keyboard.
