<h1 align="center">ola-s1-pro-gen1</h1>
<p align="center">Root access, reverse engineering notes and modding tools for the Ola S1 Pro Gen 1 electric scooter head unit</p>
<div align="center">
  <a href="https://github.com/abhijithvijayan/ola-s1-pro-gen1/blob/main/license">
    <img src="https://img.shields.io/github/license/abhijithvijayan/ola-s1-pro-gen1.svg" alt="LICENSE" />
  </a>
  <a href="https://twitter.com/intent/tweet?text=Check%20out%20ola-s1-pro-gen1%21%20by%20%40_abhijithv%0A%0ARoot%20access%20and%20modding%20tools%20for%20the%20Ola%20S1%20Pro%20Gen%201%20scooter%0Ahttps%3A%2F%2Fgithub.com%2Fabhijithvijayan%2Fola-s1-pro-gen1%0A%0A%23OlaS1Pro%20%23EV%20%23ReverseEngineering">
     <img src="https://img.shields.io/twitter/url/http/shields.io.svg?style=social" alt="TWEET" />
  </a>
</div>
<h3 align="center">Made by <a href="https://twitter.com/_abhijithv">@abhijithvijayan</a></h3>
<p align="center">
  Donate:
  <a href="https://www.paypal.me/iamabhijithvijayan" target='_blank'><i><b>PayPal</b></i></a>,
  <a href="https://www.patreon.com/abhijithvijayan" target='_blank'><i><b>Patreon</b></i></a>
</p>
<p align="center">
  <a href='https://www.buymeacoffee.com/abhijithvijayan' target='_blank'>
    <img height='36' style='border:0px;height:36px;' src='https://bmc-cdn.nyc3.digitaloceanspaces.com/BMC-button-images/custom_images/orange_img.png' border='0' alt='Buy Me a Coffee' />
  </a>
</p>
<hr />

> **Looking for battery health & ride telemetry?** Check out [**OlaMate**](https://github.com/abhijithvijayan/olamate) — a real-time telemetry logger and dashboard built from this research. Monitor cell voltages, track rides, and diagnose battery issues from your browser.

## Table of Contents

- [What This Is](#what-this-is)
- [Key Discoveries](#key-discoveries)
- [Hardware](#hardware)
- [How Root Works](#how-root-works)
- [What You Can Do](#what-you-can-do)
- [Prerequisites](#prerequisites)
- [Getting Access](#getting-access)
- [CLI Tool](#cli-tool)
- [Documentation](#documentation)
- [Data Schemas](#data-schemas)
- [Related Projects](#related-projects)
- [Security Notice](#security-notice)
- [Disclaimer](#disclaimer)
- [Issues](#issues)
- [License](#license)

## What This Is

The Ola S1 Pro Gen 1 scooter has an Android 10 tablet as its dashboard. This repo documents how to gain owner-authorized root access to that head unit and what you can do with it: custom dashboards, vehicle diagnostics, CAN bus command injection, app sideloading, and more.

Everything here is for vehicles you own. Read-only first; nothing that flashes partitions or writes firmware.

## Key Discoveries

Findings from static analysis of all 25 head-unit services and the official Ola service-center diagnostics APK:

- **Two separate CAN command channels.** The head unit sends commands on **0x6BC** (HMI→VCU, 99 `CommandFromHMI` values). The Ola diagnostics app and cloud/remote commands use **0x6A1** (TCU→VCU) for lock, unlock, horn, trunk, and lights — a completely separate path. If 0x6A1 bypasses the MCU bridge state-gating that silently drops 0x6BC frames in standby, it could enable remote unlock without the scooter being awake. *Testing needed.*
- **MCU bridge is state-gated.** CAN commands sent via the head unit (`cansend` on `vcan0`) only reach the physical bus when the scooter is awake. In standby, frames are silently dropped even though gRPC returns success. The wake path is hardware-only (BMS: charger, IMU, push button, RTC).
- **HOHS watchdog interlock.** The health service (`com.olaelectric.olahealthservice`) reboots the head unit every ~10 minutes if `cloudconnectivitymanager` or the OTA app is not running. Never `pm disable` either one.
- **Full UDS diagnostic access.** The diagnostics app has a complete UDS (ISO 14229) stack with DID catalogs for BMS (30+ battery config DIDs), VCU, and MCU. Read operations work without security access; writes require a seed-key challenge.
- **Single cloud pipe.** One MQTT connection (`cloudconnectivitymanager`) carries all telemetry, remote commands, config updates, and FOTA. Every other service routes cloud traffic through it.
- **Full service architecture mapped.** All 25 services documented with AIDL interfaces, CAN access patterns, cloud paths, and data flows. See [research/service-map.md](research/service-map.md).

## Hardware

| Component | Gen 1 Spec |
|-----------|------------|
| SoC | Qualcomm SDM450 (Snapdragon 450), 8x Cortex-A53 |
| RAM | ~2.85 GB |
| Screen | 1280x768 touchscreen (landscape) |
| Android | 10 (SDK 29), build `QKQ1.191008.001 test-keys` |
| Storage | ~11 GB free on `/data` |
| Cellular | Dual SIM: Jio 4G (IoT APN) + Airtel (fallback) |
| Wi-Fi | 802.11n, station + SoftAP capable |
| Bluetooth | Full A2DP/AVRCP/HFP stack for music |
| CAN bus | UART bridge to `vcan0` (~970 frames/sec) |
| SELinux | Permissive |
| dm-verity | Enforcing (`/system` read-only) |

## System Services

The head unit runs 24 Ola packages as system services:

| Code | Package | Role |
|------|---------|------|
| **HHMIC** | com.olaelectric.hmiclient | Main dashboard UI (Kanzi scene, 391MB) |
| **HHMIS** | com.android.hmiserverapp | HMI Server — bridge between HVDP and HHMIC (80MB) |
| **HVDP** | com.olaelectric.vehicleparser | CAN bus reader/writer, command sender |
| **HVSM** | com.olaelectric.vehiclestatemanager | Vehicle state machine, lock/unlock flow |
| **HOHS** | com.olaelectric.olahealthservice | Health watchdog, connectivity checks, reboot trigger |
| **HCCM** | com.olaelectric.cloudconnectivitymanager | Cloud connectivity (MQTT, remote commands) |
| **HOTA** | com.olaelectric.ota | OTA firmware updates |
| **HPMS** | com.olaelectric.profilemanagerservice | User profiles, passcode management |
| **HAIRS** | com.olaelectric.airangeservice | AI-based range estimation |
| **HVRS** | com.olaelectric.vehiclerangeservice | Vehicle range calculation |
| **HDA** | com.olaelectric.dataaggregator | Telemetry data collection |
| **HAIP** | com.olaelectric.aiproxy | AI proxy service |
| **HAIATO** | com.olaelectric.autoturnoff | Auto turn-off (IMU-based) |
| **HAIBS** | com.olaelectric.breakswitchmodel | Brake switch model |
| **HVS** | com.olaelectric.enginesound | Engine sound service (109MB, audio assets) |
| **HOM** | com.olaelectric.olaevnavigation | Navigation |
| **HSSS** | com.olaelectric.connectivityservice | Wi-Fi/cellular connectivity |
| **HCS** | com.olaelectric.convoyservice | Convoy/concert mode (multi-scooter sync) |
| **HDUX** | com.olaelectric.duxwebview | WebView-based UI components |
| **HNFS** | com.olaelectric.notificationforegroundservice | Notification foreground service |
| **CANLOGGER** | com.olaelectric.canlogger | CAN bus logger |
| **HMFG** | com.ola.mfgapp | Factory manufacturing/test app |
| **VehicleDataService** | com.olaelectric.vehicledataservice | AIDL shim (40KB) |
| **UdsTestApp** | com.olaelectric.udstestapp | UDS diagnostic test tool |

All APKs live under `/system/priv-app/` except VehicleDataService (`/system/app/`) and UdsTestApp (`/vendor/app/`). The gRPC diagnostics service (`diagnostics_server`, 14MB Go binary) runs from `/vendor/bin/` as an init service on port 50005.

The head unit is a terminal, not the vehicle authority. It draws the UI and shows CAN bus data. Motor control, locking, battery management, and safety all live in separate microcontrollers on the CAN bus. See [docs/architecture.md](docs/architecture.md).

## How Root Works

The head unit runs a Go service (`diagnostics_server`) on **TCP port 50005** that accepts plain gRPC with no authentication and runs commands as **root (uid 0)**.

On Gen 1, port 50005 is open on IPv4 (no firewall). On E2 units, it's blocked on IPv4 and requires IPv6.

```bash
# Install grpcurl
brew install grpcurl

# Verify root (replace <IP> with your scooter's IP)
grpcurl -plaintext \
  -import-path proto -proto wifican.proto \
  -d '{"cmd_msg": "id"}' \
  <IP>:50005 wifican.WifiCanRpc/ExecuteADBCommand
```

The proto definition in this repo was extracted directly from the `diagnostics_server` binary on a Gen 1 head unit. Go embeds a serialized `FileDescriptorProto` in every binary `protoc-gen-go` builds; we decoded that descriptor back to `.proto` source. It is the authoritative definition: 42 RPC methods, 26 messages, 20 enums.

```json
{ "status": "RESP_SUCCESS", "statusMsg": "uid=0(root) gid=0(root)..." }
```

Details: [docs/network-probe-and-root.md](docs/network-probe-and-root.md)

## What You Can Do

### With gRPC root (no setup)

- Run any command as root
- Open Android Settings, Bluetooth, Wi-Fi, technician app
- Take screenshots, read system properties
- Read live CAN bus data (battery, motor, speed, faults)
- **Send CAN commands** — unlock, lock, seat release, lights, hazards, feature toggles, wakeup (70 named commands / 99 CommandFromHMI values via `cansend` on `vcan0`)
- Install APKs, modify system settings

### After ADB key injection (~2 min, reversible)

- `adb shell` — interactive shell
- `adb pull/push` — fast file transfer
- `scrcpy` — mirror the 1280x768 dash to your PC
- `adb install` — standard APK sideloading
- `logcat` — full system logs

### Modding possibilities

| Goal | Feasibility | Path |
|------|-------------|------|
| **Unlock / lock scooter** | **Done** | Unlock: PASSCODE_AUTH (`0x19`) x30 via `cansend`. Lock: Lock_Now (`0x54`) single frame. See [research/unlock-mechanism.md](research/unlock-mechanism.md) and `scripts/scooter_cmd.py` |
| **Seat unlock, lights, hazards** | **Done** | 70 named CLI commands (99 CommandFromHMI values) via `scripts/scooter_cmd.py` — [full command table](research/unlock-mechanism.md#full-0x6bc-command-table-commandfromhmi-enum) |
| Custom dashboard UI | High | Android overlay, launcher replacement, or WebView app — see [research roadmap](docs/research-roadmap.md) |
| Battery health monitor | High | Cell voltages (14S pack) on CAN `0x1A5`–`0x1AA`, SOH, temperatures — see [OlaMate](https://github.com/abhijithvijayan/olamate) |
| **Vehicle diagnostics (UDS)** | **Done** | UDS read commands for BMS/VCU/MCU via `scripts/scooter_cmd.py uds-read` — DID catalog, DTC reading, session control. See [research/ola-diagnostics-app-analysis.md](research/ola-diagnostics-app-analysis.md) |
| Ride data logger | High | CAN data → SQLite, TeslaMate-style analysis — see [OlaMate](https://github.com/abhijithvijayan/olamate) |
| Home Assistant integration | Medium | Bridge app: CAN → MQTT → smart home dashboard |
| Sideload apps | High | Any Android 10 / arm64 / no-GMS APK |
| Custom engine sounds | Easy | Stop/modify `com.olaelectric.enginesound`, RPM on CAN `0x313` |
| Disable OTA | Easy | `scripts/disable-ota.sh` — prevent updates from closing root |
| Screen mirroring | Easy | scrcpy via ADB |
| MoveOS+ feature analysis | Research | Subscription gates may be head-unit-side flags |

### What you can't do

- Control the motor or brakes (ECU firmware)
- Modify the stock Kanzi UI at runtime (compiled binary scene)
- Wake the scooter remotely (BMS hardware trigger only)
- Send CAN commands when the scooter is in standby — the MCU bridge only forwards `vcan0` writes to the physical bus when the scooter is awake (see [unlock-mechanism.md](research/unlock-mechanism.md#mcu-bridge-state-dependency))

## Prerequisites

You need a few tools installed before starting. If you already have these, skip to [Getting Access](#getting-access).

| Tool | What it's for | macOS | Windows | Linux |
|------|--------------|-------|---------|-------|
| **Git** | Clone this repo | `brew install git` | [git-scm.com](https://git-scm.com/download/win) | `sudo apt install git` |
| **Python 3.8+** | CLI tool | `brew install python3` | [python.org](https://www.python.org/downloads/) (check "Add to PATH") | `sudo apt install python3 python3-venv python3-pip` |
| **ADB** | Shell access, file transfer | `brew install android-platform-tools` | [SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) (add to PATH) | `sudo apt install android-tools-adb` |
| **grpcurl** | Root access scripts | `brew install grpcurl` | [grpcurl releases](https://github.com/fullstorydev/grpcurl/releases) (add to PATH) | [grpcurl releases](https://github.com/fullstorydev/grpcurl/releases) |

> Linux commands shown for Debian/Ubuntu. For Fedora, use `dnf` instead of `apt`.

Verify everything is installed:

```bash
git --version
python3 --version    # or `python --version` on Windows
adb version
grpcurl --version
```

Your computer and the scooter must be on the **same Wi-Fi network**. To find the scooter's IP address:

- **Easiest**: Install [Fing](https://www.fing.com/products/fing-app) (free app) on your phone, scan your network — look for a device with "Qualcomm" or an unfamiliar name
- **Router admin**: Open your router's admin page (usually `192.168.1.1` or `192.168.0.1` in a browser) and check the connected devices / DHCP client list
- **Terminal**: Run `arp -a` and look for IPs in your network range, then try each with `ping <ip>`

## Getting Access

### 1. Verify root

```bash
SCOOTER_IP=<your-ip> bash scripts/grpc-cmd.sh "id"
```

### 2. Inject ADB key

```bash
SCOOTER_IP=<your-ip> bash scripts/inject-adb-key.sh
```

### 3. Connect ADB

```bash
adb connect <your-ip>:5555
```

### 4. Disable OTA updates (WIP)

> **Warning:** The health service (HOHS) reboots the head unit every 10 minutes
> if `com.olaelectric.ota` is not running. Do **not** use `pm disable` on the
> OTA app. See [research/reboot-analysis.md](research/reboot-analysis.md) for details.
> A proper fix (patching the HOHS watchdog) is in progress.

### 5. Pull the dashboard APK (optional)

```bash
adb pull /system/priv-app/HHMIC/HHMIC.apk
# 410MB, ~70 seconds over Wi-Fi
```

## CLI Tool

A command-line tool for sending CAN bus commands to the scooter over gRPC. 70 named commands for lock/unlock, lights, indicators, drive modes, safety features, and more.

### Setup

Requires Python 3.8+ and gRPC. Works on **macOS**, **Linux**, and **Windows**.

```bash
# Clone the repo
git clone https://github.com/abhijithvijayan/ola-s1-pro-gen1.git
cd ola-s1-pro-gen1

# Create a virtual environment
python3 -m venv .venv

# Activate it
source .venv/bin/activate          # macOS / Linux
# .venv\Scripts\Activate.ps1       # Windows (PowerShell)
# .venv\Scripts\activate.bat       # Windows (cmd)

# Install dependencies
pip3 install grpcio protobuf

# Generate gRPC stubs from the proto definition
pip3 install grpcio-tools
python3 -m grpc_tools.protoc \
    --proto_path=proto \
    --python_out=scripts \
    --grpc_python_out=scripts \
    proto/wifican.proto
```

### Usage

```bash
# Send a command (scooter must be awake — see note below)
python3 scripts/scooter_cmd.py --ip <your-ip> indicator-left-on

# Dry run — see what would be sent without connecting
python3 scripts/scooter_cmd.py --dry-run indicator-left-on

# Unlock (sends PASSCODE_AUTH 0x19 x30 — scooter must be awake)
python3 scripts/scooter_cmd.py --ip <your-ip> unlock

# Lock
python3 scripts/scooter_cmd.py --ip <your-ip> lock

# Send raw command byte
python3 scripts/scooter_cmd.py --ip <your-ip> raw 0x20

# List all 99 CommandFromHMI values
python3 scripts/scooter_cmd.py list

# UDS diagnostics — read a DID from an ECU
python3 scripts/scooter_cmd.py --ip <your-ip> uds-read vcu --did vin
python3 scripts/scooter_cmd.py --ip <your-ip> uds-read bms --did-hex E400

# UDS — read fault codes from an ECU
python3 scripts/scooter_cmd.py --ip <your-ip> uds-dtc vcu

# UDS — list known ECU CAN IDs and DIDs
python3 scripts/scooter_cmd.py uds-list
```

> **Note:** CAN commands only work when the scooter is awake (screen on, actively used).
> The MCU bridge silently drops commands in standby — gRPC returns success but nothing happens.
> See [research/unlock-mechanism.md](research/unlock-mechanism.md#mcu-bridge-state-dependency).

### Command Reference

| Category | Commands |
|----------|----------|
| **Lock / Unlock** | `unlock`, `lock`, `lock-steering`, `lock-no-steering`, `seat-unlock`, `cta-lock`, `cta-unlock` |
| **Indicators** | `indicator-left-on/off`, `indicator-right-on/off`, `auto-indicator-on/off` |
| **Lights** | `headlight-on/off`, `highbeam-on/off`, `lowbeam-on/off`, `rear-light-on/off`, `drl-on/off`, `tmh-lights-on/off` |
| **Smart headlight** | `smart-light-default/low/high/smart`, `smart-drl-on/off`, `auto-headlight-on/off` |
| **Hazard** | `hazard-on/off`, `hazard-brake-on/off` (hazard on hard brake) |
| **Drive modes** | `eco-accept/reject`, `boost-on/off`, `reverse`, `ride-now` |
| **Regen** | `regen-default`, `regen-city`, `regen-highway` |
| **Hill hold / Motor** | `hill-hold-on/off`, `motor-cutoff-on/off` |
| **Safety** | `accident-detect-on/off`, `tow-tamper-on/off`, `tow-tamper-low/high`, `proximity-on/off` |
| **Alarm** | `alarm-off`, `alarm-unlock` |
| **Drive access** | `drive-revoke-on/off`, `sidestand-disable/enable` |
| **Other** | `vacation-on/off`, `trip-reset`, `stop-charge`, `passcode-ack`, `wakeup` |
| **Raw** | `raw 0x20` — send any command byte |

## Documentation

| Doc | Topic |
|-----|-------|
| [docs/network-probe-and-root.md](docs/network-probe-and-root.md) | gRPC root access, command pattern, shell limitations, `${IFS}` trick |
| [docs/adb-key-injection.md](docs/adb-key-injection.md) | ADB key injection: how Gen 1 key auth works, step-by-step, reverting |
| [docs/hmi-apk-analysis.md](docs/hmi-apk-analysis.md) | 410MB HMI APK breakdown: Kanzi scene, themes, data contexts, native libs |
| [docs/architecture.md](docs/architecture.md) | Hardware architecture, CAN bus, data flow, boot sequence, cloud connectivity |
| [docs/research-roadmap.md](docs/research-roadmap.md) | Research & implementation roadmap: what to explore, build, and learn next |
| [research/unlock-mechanism.md](research/unlock-mechanism.md) | Full unlock mechanism: CAN ID 0x6BC, PASSCODE_AUTH, call chain, command table |
| [research/can-command-reference.md](research/can-command-reference.md) | CAN command reference: full 0x6BC command channel analysis, CLI quick reference |
| [research/reboot-analysis.md](research/reboot-analysis.md) | Head unit reboot paths: HOHS watchdog, silent reboot, MQTT commands |
| [research/service-map.md](research/service-map.md) | Full service architecture map: all 25 head-unit services, AIDL interfaces, data flows, integration points |
| [research/ola-diagnostics-app-analysis.md](research/ola-diagnostics-app-analysis.md) | Ola service-center diagnostics APK: UDS stack, DID catalog, CAN commands, gRPC/REST APIs, firmware paths |

## Data Schemas

The `schemas/` directory contains the XML data context files extracted from the HMI APK. These define every data binding between the Android backend and the Kanzi dashboard UI — effectively the complete API specification for building a replacement dashboard.

| Schema | Contents |
|--------|----------|
| `VehicleDataContext.xml` | Speed, indicators, lights, drive mode, lock state, trunk, regen, hill hold, faults |
| `ChargingDataContext.xml` | Battery %, charge time, hypercharger billing, temperature |
| `BTDataContext.xml` | Bluetooth state, media controls, caller info, concert mode |
| `RidingDataContext.xml` | Feature toggles: APB, fall detect, tow/tamper, regen, headlights |
| `NavigationDataContext.xml` | Navigation state |
| `OTADataContext.xml` | OTA update state |
| `SettingsDataContext.xml` | Settings screen state |
| `WifiDataContext.xml` | Wi-Fi connection state |
| `AboutSettingsContext.xml` | Firmware versions: VSW, MoveOS, VDP, HMI, BCM, BMS, MCU, bootloaders, MAC addresses, VIN |
| `ConcertDataContext.xml` | Concert mode: multi-scooter music sync, scooter list, song selection, light state |
| `ContactDataContext.xml` | Contact details for BT caller display |
| `FencingDataContext.xml` | Geofencing and time-fencing: riding hours, day restrictions, sport/hyper mode locks |
| `ManufactureAppDataContext.xml` | Factory manufacturing QR code and test interface |
| `PartyModeContext.xml` | Party mode: audio level visualizer (6 bands), activation state |
| `SoundSettingsDataContext.xml` | Engine sound customization: Bolt, Vintage, Eclipse presets, volume, reset |
| `TechPackDataContext.xml` | MoveOS+ tech pack: trial status, upgrade popups, feature unlock gates |
| `UserProfileDataContext.xml` | User profiles, passcode, switch user, rider access, driver documents |
| `VoiceDataContext.xml` | Voice assistant state and error handling |
| `WidgetDataContext.xml` | Dashboard widgets: acceleration, range, energy, RPM, power, torque, CO2, trip, weather, money saved |
| `BluetoothListElements.xml` | BT list structures: recent calls, contacts, favorites, paired devices |
| `DynamicWidget.xml` | Widget layout: Kanzi prefab URLs for each theme (Bolt, Vintage, Eclipse, Care) |
| `ola_electric.kzb.txt` | Complete Kanzi scene graph node listing (every UI element in the compiled binary) |

## Project Structure

```
proto/
  wifican.proto              # gRPC service definition (42 methods)
scripts/
  grpc-cmd.sh                # run a root command via gRPC
  inject-adb-key.sh          # append your ADB key to the scooter
  revert-adb-key.sh          # restore original ADB keys
  disable-ota.sh             # disable OTA updates (protect root access)
  enable-ota.sh              # re-enable OTA updates
  scooter_cmd.py             # CAN bus command CLI (70 named commands + UDS diagnostics)
research/
  unlock-mechanism.md        # full unlock mechanism analysis
  can-command-reference.md   # CAN 0x6BC command channel reference
  service-map.md             # full service architecture map (25 services)
  ola-diagnostics-app-analysis.md  # Ola diagnostics APK: UDS, DIDs, CAN commands
  reboot-analysis.md         # head unit reboot paths
docs/
  network-probe-and-root.md
  adb-key-injection.md
  hmi-apk-analysis.md
  architecture.md
schemas/
  VehicleDataContext.xml      # 21 XML data context files extracted from HHMIC.apk
  ChargingDataContext.xml
  WidgetDataContext.xml
  ConcertDataContext.xml
  ...
  ola_electric.kzb.txt        # full Kanzi scene graph node listing
local/                         # gitignored — APK, extracted assets, research notes
```

## Related Projects

- [OlaMate](https://github.com/abhijithvijayan/olamate) — telemetry logger and dashboard built from this research: battery health, ride history, cell voltages

## Security Notice

The Ola S1 Pro Gen 1 head unit runs an unauthenticated gRPC service (`diagnostics_server`) on TCP port 50005. This is a factory diagnostic service shipped by Ola Electric in the stock firmware — this project did not create or modify it.

**This is a vendor-side vulnerability, not something this project introduces.** The service binds on all network interfaces (`0.0.0.0:50005`) with no authentication, no TLS, and no access control. It accepts commands from any device that can reach the port — including root shell execution (`ExecuteADBCommand`), CAN bus writes, firmware flashing, and VIN provisioning. The same service is used by Ola's own manufacturing app (`com.ola.mfgapp`) and service-center diagnostics tools.

**Exposure surface:**
- **Wi-Fi (primary):** Any device on the scooter's Wi-Fi network or the same LAN can reach port 50005. This includes the factory hotspot and any network the scooter joins as a client.
- **4G (carrier-limited):** The service is also bound on the cellular interface. Jio's CGNAT blocks inbound connections from the public internet, but the port is technically listening. Network-level isolation is the only barrier — the service itself does not authenticate.
- **The unlock command is a single CAN frame** (`cansend vcan0 6BC#1900000000000000`) — the same frame the stock dashboard app sends when you enter your passcode. This is documented in multiple community projects and is visible to anyone who runs `candump` on the bus. Removing it from a CLI tool does not change the attack surface.

The CLI tool (`scripts/scooter_cmd.py`) includes safety guards:
- **Blocked commands:** Scooter_Reboot, MCU_Reboot, HU_Reboot, OTA control commands, DELETE_PROFILE, and OTA_MCU_Reset are all refused
- **Forbidden CAN IDs:** Writing to CAN ID 0x6A1 (TCU/cloud command channel) is refused
- **Dry-run default:** All commands require an explicit `--ip` target; without it, the tool only prints what it would send

**Ola Electric should fix this.** The `diagnostics_server` should require authentication, bind only to localhost, or be disabled outside service/manufacturing mode. Until then, the security boundary is network access — and that boundary is thinner than it should be.

If you are a security researcher who has found additional vulnerabilities, please consider responsible disclosure to Ola Electric before publishing.

## Disclaimer

This is an independent interoperability research project conducted on vehicles I personally own. It is not affiliated with, endorsed by, or sponsored by Ola Electric Mobility Limited or any of its subsidiaries. All trademarks, product names, and company names mentioned are the property of their respective owners and are used solely for identification purposes.

**No warranty.** THE SOFTWARE AND DOCUMENTATION ARE PROVIDED "AS IS," WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED. THE AUTHOR MAKES NO REPRESENTATIONS OR WARRANTIES REGARDING THE ACCURACY, COMPLETENESS, SAFETY, OR SUITABILITY OF ANY INFORMATION, TOOL, OR CODE IN THIS REPOSITORY.

**Limitation of liability.** IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR EXEMPLARY DAMAGES — INCLUDING BUT NOT LIMITED TO DAMAGE TO VEHICLES, PERSONAL INJURY, LOSS OF DATA, OR LEGAL CONSEQUENCES — ARISING FROM THE USE OR INABILITY TO USE ANYTHING IN THIS REPOSITORY, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. Sending CAN bus commands to a vehicle can have real-world physical consequences. You assume all risk.

**For owner-authorized use only.** The tools and documentation here are intended exclusively for research, diagnostics, and customization of vehicles you personally own. Using them to access, control, monitor, or tamper with a vehicle you do not own constitutes unauthorized access and may violate applicable laws including but not limited to the Information Technology Act, 2000 (India), the Computer Fraud and Abuse Act (US), the Computer Misuse Act (UK), and equivalent legislation in your jurisdiction. You are solely responsible for ensuring your use complies with all applicable laws.

**Interoperability research.** This project exercises the owner's right to understand and interoperate with software running on hardware they own. The gRPC protocol definitions were extracted from the `diagnostics_server` binary on my own scooter (see [docs/network-probe-and-root.md](docs/network-probe-and-root.md)). The data context schemas were extracted from the stock HMI APK for interoperability research. CAN bus IDs referenced in the documentation were mapped by the community (see Related Projects). No proprietary source code is reproduced.

## Issues

_Looking to contribute? Look for the [Good First Issue](https://github.com/abhijithvijayan/ola-s1-pro-gen1/issues?q=is%3Aissue+is%3Aopen+sort%3Aupdated-desc+label%3A%22good+first+issue%22) label._

### Bugs

Please file an issue [here](https://github.com/abhijithvijayan/ola-s1-pro-gen1/issues/new) for bugs, missing documentation, or unexpected behavior.

[**See Bugs**](https://github.com/abhijithvijayan/ola-s1-pro-gen1/issues?q=is%3Aissue+is%3Aopen+sort%3Aupdated-desc+label%3A%22type%3A+bug%22)

## License

MIT © [Abhijith Vijayan](https://abhijithvijayan.in)
