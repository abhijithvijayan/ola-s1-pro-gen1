# Ola Diagnostics App Analysis

Static analysis of the official Ola service-center diagnostics APK
(`com.olaelectric.mfg.diagnosticapp`, v205, debug build, SDK target 35).

Source: `app-production-debug-205-1.apk` (58 MB, 30 DEX files).

---

## 1. App Overview

The diagnostics app is used by Ola service centers for vehicle inspection,
firmware updates, fault code management, and configuration changes. It is
**not** the consumer Ola Electric app — it is an internal tool.

Key traits:
- Debug build with full symbol retention (class names, field names preserved)
- 30 DEX files — large codebase with Firebase, MoEngage analytics, ML Kit barcode
- Targets Android 15 (SDK 35)
- Uses `dadb` — an embedded pure-Java ADB client (no `adb` binary needed)
- Connects to the scooter's head unit via Wi-Fi (gRPC on port 50005)
- Authentication through Ola's CIDM (identity) system

### App Screens (from fragment names)

batteryreplacement, bcmFlashing, brakeByWireStatus, cappsetup, connection,
diagnostics, ecuselection, ecutest, ESCLtest, findmyscooter, home,
livesignals, login, motorreplacement, otatrigger, passcode, profilesetup,
replacement, replacementtype, report, reportissue, s1XConnectionSetup,
softwaredownload, update, updateVehicleConfigs, validationversion, webview

---

## 2. Authentication & Login

- **CIDM login** via `ola-ev-ui.olaelectric.com` (WebView-based OAuth flow)
- Endpoints:
  - `/v1/tokens/{sessionId}/userinfo` — get logged-in user info
  - `/v1/tokens/{sessionId}/logout` — session logout
  - `/thor/v1/user/whitelist/phone` — phone whitelist check
  - `/thor/v2/avatar/device/user/id` — device/user ID lookup
- Firebase project: `olaelectric-81415`
- Firebase Remote Config controls API base URLs dynamically

### Backend Service Names

| Config Key               | Purpose                                   |
|--------------------------|-------------------------------------------|
| API_DOKTOR_BASE_URL      | Diagnostics backend ("Doktor")            |
| API_OLA_PLANT_BASE_URL   | Factory/plant operations                  |
| SOFTWARE_UPDATE_API      | Firmware download service                 |

---

## 3. gRPC Interface

Uses `WifiCanRpcGrpc.newBlockingStub()` — the same `wifican.proto` service
as our `diagnostics_server` on port 50005. Connection via
`ManagedChannelBuilder.forAddress(...).usePlaintext()`.

### Methods Called

| Method                    | Purpose                                    |
|---------------------------|--------------------------------------------|
| `canDumpStream`           | Stream raw CAN frames                      |
| `configUpdate`            | Push configuration to head unit            |
| `generateCerts`           | Generate certificates (⚠ dangerous)        |
| `getSwVersion`            | Read software version info                 |
| `getVehicleIdentifiers`   | Read VIN, serial numbers                   |
| `provisionConfig`         | Factory provisioning (⚠ dangerous)         |
| `provisionVin`            | Write VIN to vehicle (⚠ dangerous)         |
| `registerInstallCerts`    | Install generated certs (⚠ dangerous)      |
| `remoteRunTestCmd`        | Execute arbitrary test commands             |
| `requestQR`               | Generate QR code (pairing?)                |
| `scooterModeChange`       | Change vehicle mode (⚠ dangerous)          |
| `sendHandshakeAck`        | Complete handshake with head unit           |
| `sendOTP`                 | Send OTP for auth                          |
| `sendWifiInfo`            | Push Wi-Fi credentials                     |
| `setVehicleOperationMode` | Set operational mode                       |
| `validateCerts`           | Validate installed certificates            |
| `writeCanFrame`           | Write a raw CAN frame                      |

The app does **not** use `ExecuteADBCommand` for CAN writes — it has its own
embedded ADB client (`dadb` library) that connects directly to port 5555.

---

## 4. REST API Endpoints

Extracted from Retrofit annotations:

| Endpoint                                        | Purpose                        |
|-------------------------------------------------|--------------------------------|
| `/v1/adb/grpc/keys`                             | ADB/gRPC key exchange          |
| `/v1/adb/version`                               | ADB version check              |
| `/v1/diagnostic/auth`                            | Diagnostics authentication     |
| `/v1/diagnostic/auth/sign-vehicle-hotspot-data`  | Sign hotspot handshake         |
| `/v1/reports/data`                               | Upload diagnostic reports      |
| `/v1/session`                                    | Session management             |
| `/v1/tokens/{sessionId}/userinfo`                | User info lookup               |
| `/v1/tokens/{sessionId}/logout`                  | Session logout                 |
| `/v1/upgrade/details/image`                      | Firmware image metadata        |
| `/v1/upgrade/details/reports`                     | Upgrade report upload          |
| `/v1/vcu/upgrade/process`                         | VCU upgrade flow               |
| `/thor/api/config/v2/vehicle/status`              | Vehicle status check           |
| `/thor/v1/testride-admin/vehicleEOL/getVehicle`  | End-of-line vehicle lookup     |
| `/thor/v1/user/whitelist/phone`                   | Phone whitelist check          |
| `/thor/v2/avatar/device/user/id`                  | Device/user ID                 |
| `/assetDetails/variant/change`                    | Vehicle variant change         |

---

## 5. UDS Diagnostics

The app implements a full UDS (Unified Diagnostic Services, ISO 14229) stack
over CAN for communicating with the scooter's ECUs.

### 5.1 ECU CAN ID Pairs

| ECU | Request ID | Response ID |
|-----|-----------|-------------|
| BMS | 0x078E    | 0x07B1      |
| VCU | 0x0786    | 0x07B0      |
| MCU | 0x07A6    | 0x07B4      |

These are standard UDS-over-CAN addressing pairs (request → response).

### 5.2 UDS Services Used

| Service | SID  | Sub-functions                                    |
|---------|------|--------------------------------------------------|
| DiagnosticSessionControl | 0x10 | Default (01), Programming (02), Extended (03) |
| ECUReset             | 0x11 | HardReset (01)                                   |
| ClearDTC             | 0x14 | —                                                |
| ReadDTCInformation   | 0x19 | —                                                |
| ReadDataByIdentifier | 0x22 | See DID tables below                             |
| SecurityAccess       | 0x27 | RequestSeed (01), SendKey (02)                   |
| WriteDataByIdentifier| 0x2E | See DID tables below                             |
| RoutineControl       | 0x31 | Start (01), Stop (02), RequestResult (03)        |

### 5.3 Security Access

- Service 0x27: Seed-Key challenge-response
- Seed request sub-function: `6701` (request seed from level 01)
- Key response: `6702` (send computed key)
- Session switch success indicators: `5003` (extended), `5001` (default)
- Security levels: `01`, `02`, `03`
- Key computation: `SeedKeyAlgoHelper` class (algorithm not yet extracted)

### 5.4 Data Identifiers (DIDs)

#### General DIDs

| DID    | Name              | Read | Write | Notes                          |
|--------|-------------------|------|-------|--------------------------------|
| F190   | VIN               | 0x22 | 0x2E  | Vehicle Identification Number  |
| 0100   | Version           | 0x22 | 0x2E  | Software version + variant ID  |
| 0102   | HyperCharge       | 0x22 | 0x2E  | Enable/disable hypercharging   |
| 0103   | Odometer          | 0x22 | 0x2E  | Read/write odometer value      |
| 017E   | CustomerMode      | 0x22 | 0x2E  | Enable (01) / Disable (00)     |

#### Vehicle Variant Identifiers (first byte of DID 0100)

| Byte | Variant          |
|------|------------------|
| 0x01 | S1               |
| 0x02 | S1 Pro           |
| 0x03 | S1 Pro Upgrade   |
| 0x04 | S1 2KW           |
| 0x05 | S1 Air           |
| 0x06 | S1 Pro Gen 2     |
| 0x07 | (unknown)        |

#### BMS Config Parameters (E4xx range)

30+ DIDs for battery management configuration. Selected examples:

| DID  | Description                              |
|------|------------------------------------------|
| E4xx | Cell voltage thresholds                  |
| E4xx | Temperature limits (charge/discharge)    |
| E4xx | Charge current limits                    |
| E4xx | Discharge current limits                 |
| E4xx | Safety cutoff parameters                 |

Full BMS DID enumeration is in `BmsConfigParams.smali`.

#### MCU Config Parameters (B1xx range)

Torque and performance tuning per drive mode:

| DID  | Description                              |
|------|------------------------------------------|
| B131 | Normal mode torque limits                |
| B132 | Sports mode torque limits                |
| B133 | Hyper mode torque limits                 |
| B134 | Limp-home mode torque limits             |
| B136 | Reverse mode torque limits               |
| B1xx | Acceleration/deceleration time constants |

#### VCU Config Parameters

| DID  | Description                              |
|------|------------------------------------------|
| CF6F | Hill Hold enable/disable                 |
| CF37 | Boost Mode enable/disable                |
| CF64 | Proximity Lock/Unlock                    |
| CF68 | Motor Cutoff Delay                       |
| 1D   | Accident Detection                       |
| 3E   | Smart Light                              |
| 3F   | Smart DRL                                |
| 0102 | JTAG Port Disable                        |

#### VCU Temperature Thresholds

| Parameter                | DID  |
|--------------------------|------|
| MCU temp warning         | (VcuConfigParams) |
| MCU temp error           | (VcuConfigParams) |
| Motor temp warning       | (VcuConfigParams) |
| Motor temp error         | (VcuConfigParams) |

### 5.5 UDS Request Types (full enum)

29+ request types including:
- DOD (Data-On-Demand) read/write for all ECUs (BMS, VCU, MCU)
- Config parameter read/write for all ECUs
- Odometer read/write
- Customer mode toggle
- HyperCharge toggle
- Routine control (start/stop/result)
- DTC read and clear
- Hard reset
- VIN read/write
- Version read/write
- Security access (seed/key)

---

## 6. CAN Data Parsing

The `com.olaelectric.dataparserengine.can.domain` package contains the
CAN frame definitions used by the diagnostics app.

### 6.1 VehicleCommand CAN Frames

**CAN ID 0x6A1** — TCU→VCU command channel (cloud/remote commands):

| Command  | Full Frame (hex)                           | Byte 4 Value |
|----------|--------------------------------------------|-------------|
| UNLOCK   | `000006A1 08 00000001 00000000 00000000`   | 0x01        |
| LOCK     | `000006A1 08 00000002 00000000 00000000`   | 0x02        |
| LIGHT    | `000006A1 08 00000003 00000000 00000000`   | 0x03        |
| TRUNK    | `000006A1 08 00000005 00000000 00000000`   | 0x05        |
| HORN     | `000006A1 08 0000000C 00000000 00000000`   | 0x0C        |

This is significant — the diagnostics app uses 0x6A1 (the TCU→VCU channel)
for lock/unlock, **not** 0x6BC (the HMI→VCU channel used by head unit apps).

**CAN ID 0x6BC** — HMI→VCU command channel:

| Command          | Byte 4 Value | Notes                        |
|------------------|-------------|-------------------------------|
| OTA_TRIGGER      | 0x0F        | Trigger OTA update            |
| SCOOTER_REBOOT   | 0x11        | MCU_Reboot (0x11 decimal 17)  |
| REFRESH_OTA      | 0x61        | OTA_MCU_Reset                 |

**CAN ID 0x0AAA** — Periodic message control:

Used for start/stop/ecos periodic messages. Not seen in head unit APKs.

**CAN ID 0x7C1** — Phase 2 scooter reboot:

Used for reboot on newer ("Phase 2") hardware. Not seen in head unit APKs.

### 6.2 Software Version CAN IDs

| Component      | CAN ID |
|----------------|--------|
| BCM            | 0x679  |
| BLE            | 0x691 (old), 0x697 (new) |
| BMS            | 0x620  |
| MCU            | 0x623  |
| Vehicle        | 0x677  |
| EC200 (modem)  | 0x6EE  |
| Vehicle Type Extended | 0x7D0 |

---

## 7. Protobuf Messages

### 7.1 MCU Packet (xavi)

Package: `com.olaelectric.dp.xavi.protobufs` ("xavi" is an internal Ola codename).

`MCUPacketSt` fields:
- **Motor**: motorRpm, motorTemperature, motorTorque, motorCurrent, motorFrequency
- **Vehicle**: vehicleSpeedKmph, distanceCoveredForCurrentTrip
- **MCU electrical**: mCUTemperature, mCUVoltage, mCUDCCurrent, busVoltageMCU,
  aCCurrentMCU, dCCurrentMCU, supply3V3
- **Throttle/Brake**: throttleValue1, throttleValue2, frontBrakeAnalogVoltage,
  rearBrakeAnalogVoltage, mCUADCThrottlePercent
- **Motor control**: rotorAngle, mechAngle, synchronousMotorAngle,
  voltageDirectAxis, voltageQuadratureAxis, idMeasured, idReference,
  iqMeasured, iqReference, positionCounter
- **Features**: mCUHHActivationCounter (hill hold), mCUInverterEnableCmd

`ScooterStateSt` enum: UNKNOWN(0), LOCK(1), UNLOCK(2), CHARGER_CONNECTED(3)

---

## 8. Embedded ADB Module

The app includes `dadb`, a pure-Java ADB implementation that connects directly
to the head unit on port 5555 — no `adb` binary or Android SDK needed.

### ADB Commands Observed

```
cansend vcan0 6BC#0E    # Scooter_Reboot
cansend vcan0 6BC#11    # OTA_Installation_Complete
```

### File Paths Accessed via ADB

| Path                           | Purpose                    |
|--------------------------------|----------------------------|
| `/data/ola/cached_files`       | Cached data                |
| `/data/ola/config`             | Configuration files        |
| `/data/ola/hf`                 | Unknown ("hf" = ?)         |
| `/vendor/etc/firmware`         | ECU firmware binaries      |

### Firmware Files

| Filename                    | Target         |
|-----------------------------|----------------|
| `E2_BMS_APP_FOTA.bin`       | BMS firmware   |
| `E2_MCU_100_APP_FOTA.bin`   | MCU (100A)     |
| `E2_MCU_80_APP_FOTA.bin`    | MCU (80A)      |
| `E2_HU_APP_FOTA.bin`        | Head unit      |

### OTA Packages

Individual component tarballs: `bcm.tar`, `ble.tar`, `bms.tar`, `mcu_100.tar`,
`mcu_80.tar`, `som.tar`.

SOM (System on Module / head unit) OTA uses encrypted+signed packages:
- `ota_command.sh.enc` + `update.zip.enc`
- Verified via OpenSSL with `/vendor/etc/ola/pub-keys/OEM_FOTA_pre_public.pem`

---

## 9. Key Findings for Our Research

### 9.1 Two Command Channels Confirmed

The head unit uses **0x6BC** (HMI→VCU) for all commands. The diagnostics app
uses **0x6A1** (TCU→VCU) for lock/unlock/horn/trunk/light. This confirms
0x6A1 is the cloud/remote command path — the same channel the TCU uses when
commands come from the Ola app via MQTT.

**Implication**: If 0x6A1 bypasses the MCU bridge state-gating that affects
0x6BC, it could enable remote wake/unlock. This needs testing.

### 9.2 UDS Gives Deep ECU Access

The full UDS DID catalog means we can potentially:
- **Read** all BMS cell voltages, temperatures, and safety thresholds
- **Read** MCU torque maps and performance parameters per drive mode
- **Read** VCU feature flags (hill hold, boost, proximity, etc.)
- **Read** fault codes (DTCs) from all three ECUs
- **Read** odometer, VIN, software versions

Write access requires security access (seed-key), so reading is the safe
starting point.

### 9.3 The `SeedKeyAlgoHelper` Is the Gate

All write operations and extended diagnostics require passing the UDS
security access challenge. The `SeedKeyAlgoHelper` class implements the
seed→key computation. Extracting this algorithm would unlock config reads
that require extended session.

### 9.4 New CAN IDs Discovered

| CAN ID | Source         | Purpose                          |
|--------|----------------|----------------------------------|
| 0x0AAA | Diagnostics app| Periodic message start/stop      |
| 0x7C1  | Diagnostics app| Phase 2 scooter reboot           |
| 0x078E | UDS            | BMS request (diagnostic)         |
| 0x07B1 | UDS            | BMS response (diagnostic)        |
| 0x0786 | UDS            | VCU request (diagnostic)         |
| 0x07B0 | UDS            | VCU response (diagnostic)        |
| 0x07A6 | UDS            | MCU request (diagnostic)         |
| 0x07B4 | UDS            | MCU response (diagnostic)        |

### 9.5 Diagnostics App Uses WriteCanFrame

Unlike our `cansend` via `ExecuteADBCommand` approach, the diagnostics app
calls `writeCanFrame` via gRPC **and** has its own embedded ADB client. It
may use the ADB path for CAN writes, which would explain why it works where
`WriteCanFrame` doesn't (the MCU bridge issue).

### 9.6 "Doktor" Backend

The diagnostics backend is called "Doktor" internally (`API_DOKTOR_BASE_URL`).
The app authenticates via CIDM, then talks to Doktor for session management,
report uploads, and firmware image retrieval.

### 9.7 Encrypted SOM OTA

Head unit (SOM) firmware updates use encrypted packages verified against
`OEM_FOTA_pre_public.pem`. This means SOM firmware cannot be modified or
custom-flashed without Ola's private key — the bootloader will reject
unsigned packages.

---

## 10. Comparison with Head Unit Services

| Capability                | Head Unit (HVDP) | Diagnostics App    |
|---------------------------|-------------------|--------------------|
| CAN command channel       | 0x6BC only        | 0x6A1 + 0x6BC      |
| CAN write method          | SocketCAN native  | gRPC + embedded ADB|
| UDS diagnostics           | None              | Full stack          |
| Fault code access         | None              | Read + Clear        |
| Config parameter access   | None              | Read + Write (with security) |
| Firmware update           | HOTA service      | Direct ADB push    |
| Authentication            | None (on-device)  | CIDM + Doktor      |
| Cloud connectivity        | MQTT via HCCM     | REST via Doktor    |

---

## 11. Safe Next Steps

1. **UDS Read-Only Exploration** — Send ReadDataByIdentifier (0x22) to
   BMS/VCU/MCU using the discovered CAN ID pairs. No security access
   needed for basic reads. Start with software versions (DID 0100) and
   VIN (DID F190).

2. **Test 0x6A1 Commands** — Determine if 0x6A1 bypasses MCU bridge
   state-gating. If it does, this is the path for reliable remote commands.

3. **Monitor 0x0AAA** — Capture and decode periodic messages on this
   previously unknown CAN ID during normal scooter operation.

4. **Extract SeedKeyAlgoHelper** — The security access algorithm is the
   key to unlocking extended UDS sessions. This is a smali→pseudocode
   extraction task.

5. **DTC Reading** — Implement ReadDTCInformation (0x19) to pull fault
   codes from all three ECUs. This is read-only and safe.
