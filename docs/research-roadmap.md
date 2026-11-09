# Research & Implementation Roadmap

What can be explored, built, and learned from the Gen 1 head unit — prioritized by feasibility and value.

---

## Quick Reference: What We Have

| Capability | Access Level |
|-----------|-------------|
| Root shell (gRPC, uid 0) | Always available, no auth, survives reboot |
| ADB shell (uid 2000) | After key injection (lost on reboot) |
| CAN bus read | `candump vcan0` or gRPC `CanDumpStream` — 188 IDs, ~970 frames/s when awake |
| CAN bus write | `cansend` / gRPC `WriteCanFrame` — frames reach the real bus |
| APK sideloading | `adb install` or `pm install` via gRPC |
| Screen capture | `screencap -p` via ADB or gRPC |
| Full logcat | All system logs including CAN parser output |
| File system read | Full read access to `/data`, `/system`, `/vendor` |
| File system write | `/data` writable; `/system`, `/vendor` read-only (dm-verity) |

---

## Research: Things to Investigate

### 1. Untried gRPC Methods (Safe)

We have 42 RPCs but only used a few. These are safe to call (read-only or diagnostic):

| Method | What it probably does | Priority |
|--------|----------------------|----------|
| `GetEcosDynoFlags` | Read ecos/dyno feature flags — might reveal hidden features | High |
| `GetSwVersion` | Software version strings | Medium |
| `GetAospVersion` | Android build version | Medium |
| `GetVehicleIdentifiers` | Returns `manifest_json` (contains VIN — don't publish) | Medium |
| `ValidateCerts` | Check certificate status | Low |
| `GetVehicleOperationMode` | Current mode (mfg/cust/service) | Medium |
| `CheckManifestFile` | Unknown — probably checks manifest integrity | Low |
| `RemoteRunTestCmd` | Factory test commands (LCD, GPS, BT, speaker, mic, eSIM) | High |

**RemoteRunTestCmd is the most interesting.** It takes a `RmtCmdReq` with sub-commands for LCD test, GPS test, BT test, speaker test, mic test, and MCU calibration. These are factory diagnostics that could reveal hardware capabilities.

### 2. CAN Bus Signal Mapping

Proven signals cover battery, motor, speed, and safety. These remain inferred or unmapped:

| Signal Group | CAN IDs | Status |
|-------------|---------|--------|
| Cycle count / lifetime energy | `0x6D8`, `0x6DC`, `0x6E0`, `0x6E2`, `0x6E4` | Inferred, unverified |
| Motor current / torque details | `0x223` | Partially mapped |
| MCU voltage | `0x113` | Partially mapped |
| VCU / SOM temperature | `0x64B` | Partially mapped |
| GPS data | Unknown | Not found on CAN |
| Charger communication | Active during charging | Needs capture |

**Charging session capture** is the highest-value CAN research. Plug in the charger with `candump` running and you'll see IDs that are silent during normal operation — charger negotiation, charge rate limits, thermal throttling decisions.

### 3. Running Services Audit

21+ Ola packages are running. Most are unexplored:

| Package | Likely Purpose | Research Value |
|---------|---------------|---------------|
| `com.olaelectric.vehicleparser` | Decodes CAN frames → data contexts | Very high — the decoder |
| `com.olaelectric.vehicledataservice` | Serves vehicle data to other apps | High |
| `com.olaelectric.vehiclestatemanager` | State machine (locked/unlocked/riding) | High |
| `com.olaelectric.vehiclerangeservice` | Range estimation algorithm | High |
| `com.olaelectric.airangeservice` | AI-based range prediction | Medium |
| `com.olaelectric.canlogger` | CAN bus logging service | High |
| `com.olaelectric.enginesound` | Engine sound playback | High — modifiable |
| `com.olaelectric.cloudconnectivitymanager` | MQTT / cloud telemetry | Medium |
| `com.olaelectric.convoyservice` | Concert mode / multi-scooter sync | Medium |
| `com.olaelectric.aiproxy` | AI/voice assistant proxy | Low |
| `com.olaelectric.dataaggregator` | Telemetry aggregation | Medium |
| `com.olaelectric.olahealthservice` | Vehicle health monitoring | High |
| `com.olaelectric.profilemanagerservice` | User profiles / passcode | Medium |
| `com.olaelectric.connectivityservice` | Network management | Low |
| `com.olaelectric.duxwebview` | WebView host for "Dux" mini-apps | Medium |
| `com.olaelectric.autoturnoff` | Auto turn-off logic | Low |
| `com.olaelectric.breakswitchmodel` | Brake switch monitoring | Low |
| `com.olaelectric.notificationforegroundservice` | Push notifications | Low |
| `com.olaelectric.mfgapp` | Factory manufacturing app | Medium |
| `com.olaelectric.udstestapp` | UDS diagnostics test app | High |

**How to investigate:** `adb shell dumpsys package <name>` for manifest, `logcat -s <tag>` for runtime behavior, `adb pull` the APK and decompile with `jadx`.

The **vehicleparser** is the Rosetta Stone — it contains the complete CAN decode logic. Decompiling it gives you every signal formula without guessing.

The **udstestapp** is interesting because it implies UDS (Unified Diagnostic Services) capability that isn't exposed on the normal CAN bus.

### 4. Cloud Connectivity & Telemetry

The scooter phones home via MQTT. Worth understanding:

- What data is sent (location, battery, riding behavior?)
- MQTT broker address and topics
- Whether telemetry can be redirected or captured
- What `cloudconnectivitymanager` does when the network goes down

**How to investigate:** `logcat -s CloudConnectivity` while the scooter has Wi-Fi, or `tcpdump` on the head unit to see what it connects to.

### 5. Bluetooth Stack Deep-Dive

Full A2DP/AVRCP/HFP stack for music/calls. Worth investigating:

- Can you pair a BT OBD2 adapter and read from it?
- AVRCP metadata (track info, album art) — how it reaches the Kanzi UI
- BLE capabilities (the scooter has BLE for phone key)
- Whether BT audio can be rerouted or enhanced

### 6. DuxWebView — The Mini-App Platform

`com.olaelectric.duxwebview` hosts web content inside the dashboard. If it loads arbitrary HTML, it could be a path to running custom UI without replacing the full dashboard.

**How to investigate:** Check what URLs it loads, whether it can be pointed at a local server, and what JavaScript APIs it exposes.

---

## Implementation: Things to Build

### Tier 1: Easy, High Value

#### Battery Health Monitor (Sideloaded APK)

Read CAN frames via `candump` or logcat and display:
- Individual cell voltages (14S pack via `0x1A5`, `0x1A6`, `0x1A9`, `0x1AA`)
- Cell voltage spread (max - min) — the real health indicator
- Pack temperature (effective, min, max via `0x160`)
- SOH (state of health, `0x150` byte 5)
- Charge/discharge current (`0x140`)
- Historical graphs over time

**Why:** Ola's dashboard shows battery %, but not cell-level data. Cell imbalance is the #1 predictor of battery degradation.

**How:** Android app with `Runtime.exec("candump vcan0")` or read from logcat. No root needed if reading logcat; gRPC for raw CAN. Display on the 1280x768 screen or export data.

#### Ride Data Logger

Log every ride to CSV/SQLite:
- Speed, power, torque, RPM (from CAN)
- Battery SOC, voltage, current (from CAN)
- Regen energy recaptured
- Motor and battery temperatures
- Drive mode (Eco/Normal/Sport/Hyper)
- GPS coordinates (if available from Android location)
- Distance, duration, efficiency (Wh/km)

**Why:** The Ola app shows limited ride stats. A logger gives you Strava-for-scooters data — efficiency trends, battery degradation over months, riding pattern analysis.

**How:** Background service sideloaded as APK. Read CAN data, write to local storage, export via ADB pull or a simple HTTP server on the head unit.

#### Custom Engine Sounds

The `enginesound` package plays synthesized motor sounds. Three presets: Bolt, Vintage, Eclipse. The sound parameters are in `SoundSettingsDataContext.xml`:

- `BoltBiteUpdate`, `BoltAnalogCyberUpdate` — Bolt sound parameters
- `VintageAgeTimeUpdate`, `VintageSizeofMotor` — Vintage parameters
- `EclipseOrbitSizeUpdate`, `EclipseLunarPhase` — Eclipse parameters
- `SoundCustomisationVolumeUpdate` — master volume

**How:** Either modify the parameters in the data context, replace the sound assets, or stop `enginesound` entirely and run your own audio source. The simplest mod is just `pm disable-user com.olaelectric.enginesound` to go silent.

#### Auto ADB Re-injection Script (Laptop-Side)

Since ADB keys are wiped on reboot but gRPC is always available:

```bash
#!/bin/bash
# Watch for scooter on network, auto-inject ADB key
while true; do
  if ping -c1 -W1 $SCOOTER_IP &>/dev/null; then
    if ! adb -s $SCOOTER_IP:5555 shell id &>/dev/null; then
      SCOOTER_IP=$SCOOTER_IP bash scripts/inject-adb-key.sh
    fi
  fi
  sleep 30
done
```

Runs on your laptop. When the scooter connects to home Wi-Fi, it detects it and injects the key automatically.

### Tier 2: Medium Effort, High Value

#### Custom Dashboard

A replacement dashboard shows data the stock UI doesn't — cell voltages, motor temperature, power consumption graph, trip efficiency, regen stats. Targets the native 1280x768 screen, binds the HHMIS vehicle-data service for live state, and registers itself as the Android `HOME` activity.

**Challenge:** The stock HMI (`hmiclient`) is the default `HOME` activity. You either disable it (riskier — HOHS watchdog may react) or just hand HOME over through `cmd package set-home-activity` while keeping stock installed as a fallback. Whichever way, you lose Ola's navigation, Bluetooth UI, and concert mode unless you reimplement them.

#### Diagnostics App with gRPC Client

An Android app with an embedded gRPC client that talks to `localhost:50005`:

- Run root commands from a UI
- Real-time CAN bus viewer with decoded signals
- Battery cell voltage display
- Temperature monitoring with alerts
- Vehicle info (versions, identifiers, operation mode)
- Factory test execution (LCD, speaker, GPS, BT, mic tests)

**Why:** Currently everything requires a laptop + grpcurl. An on-device app makes all diagnostics portable.

**How:** Android app (Kotlin/Java) with `io.grpc:grpc-android`. Use the extracted `wifican.proto` to generate the client stubs. The gRPC server is on localhost, so no network dependency.

#### Sideload Useful Apps

Any Android 10 / arm64 APK without Google Play Services works:

- **Navigation**: OsmAnd, HERE WeGo (offline maps for the 1280x768 screen)
- **Music players**: Lightweight local players (Spotify Lite may work)
- **File managers**: For browsing the filesystem
- **Terminal emulators**: Simple ones work (Termux needs GMS)
- **Custom launchers**: Replace the home screen while keeping Kanzi available

#### Home Assistant / MQTT Integration

Export vehicle telemetry to your home automation:

- Battery level → smart home dashboard
- Charging state → trigger smart plug, log charge sessions
- Location → arrival/departure triggers
- Temperature alerts → push notifications to phone

**How:** A sideloaded bridge app that reads CAN data and publishes to your MQTT broker. Or, capture what `cloudconnectivitymanager` already sends and redirect it.

### Tier 3: Advanced / Exploratory

#### CAN Bus Replay & Simulation

Build a CAN bus simulator that replays captured traffic:
- Record a full ride with `candump -l vcan0`
- Replay with `canplayer -I <logfile> vcan0=vcan0`
- The dashboard should animate as if riding — speed dial, battery, indicators
- Test custom dashboard themes without actually riding

**Caution:** Only replay TO the head unit, never to the real vehicle bus. Use a second `vcan` interface if possible.

#### Firmware Analysis Toolkit

Offline analysis of OTA packages (on your PC, not on the scooter):
- Download and decrypt the firmware package
- Extract and catalog the module images (BCM, BMS, MCU, BLE, AOSP)
- Disassemble with Ghidra (ARM Thumb-2 for BCM/BMS/BLE, C28x for MCU)
- Map firmware update state machine
- Document the OTA delivery chain

**Why:** Understanding the firmware reveals vehicle behavior that isn't visible from CAN or Android. Battery management algorithms, motor control tuning, charge curves — all live in the ECU firmware.

#### MoveOS+ Feature Analysis

The `TechPackDataContext.xml` shows MoveOS+ is a paid feature gate:
- Hill hold, cruise control, hypercharge — locked behind subscription
- `TechPackTrialStatus`, `TechPackUnlockPopup`, `MoveOSUpgradePopup`

**Research question:** Are these features purely software-gated on the head unit, or does the VCU also enforce them? If the head unit just hides UI elements, setting the data context booleans might enable them. If the VCU checks a flag, it's not bypassable from Android.

**How to investigate:** Watch CAN bus while toggling a MoveOS+ feature during a trial. If a CAN frame changes, the VCU is involved. If only data context values change, it's UI-only.

#### Concert/Party Mode Reverse Engineering

`ConcertDataContext.xml` reveals multi-scooter music sync:
- Scooter discovery and list management
- Song selection and playback sync
- Light state coordination

This is one of Ola's most unique features. Understanding the protocol could let you build custom multi-device sync — not just scooter-to-scooter, but scooter-to-Bluetooth-speaker or scooter-to-home-stereo.

---

## What Others Have Built (Inspiration)

### Data Logging & Battery Health

| Project | Vehicle | What it does | Link |
|---------|---------|-------------|------|
| **TeslaMate** | Tesla | Self-hosted Postgres + Grafana. Every drive, charge, degradation trend. MQTT → Home Assistant. The gold standard. | [GitHub](https://github.com/teslamate-org/teslamate) |
| **LeafSpy** | Nissan Leaf | Cell-level voltage monitoring via OBD. The #1 reason used Leaf buyers pay for an app. | Commercial |
| **ScanMyTesla** | Tesla | Real-time CAN decoder — cell voltages, temps, power flow | Commercial |
| **VanAccess BMS Monitor** | Generic BLE BMS | Open-source Android app. Cell voltage bars, delta highlighting, SOH. | [F-Droid](https://f-droid.org/zh_Hans/packages/com.vanaccess.bms/) |
| **OpenVehicles NIU** | NIU scooter | Open-source monitoring, rolling consumption averages | [Docs](https://docs.openvehicles.com/en/latest/components/vehicle_niu_gtevo/docs/index.html) |

### Custom Dashboards

| Project | Vehicle | Tech |
|---------|---------|------|
| **Super VESC Display** | VESC-based EVs | ESP32-S3 touchscreen, CAN bus gauges, trip persistence |
| **openecar_dashboard** | Smart EV | Qt on Raspberry Pi, separate CAN decoder module |
| **Car Launcher Pro / CarWebGuru** | Android head units | Launcher replacements with trip computers |
| **AOSP Instrument Cluster API** | Android Automotive | Official API for custom instrument cluster rendering |

### Scooter & Vehicle Platform Hacking

| Project | What they did |
|---------|-------------|
| **Egret GT Rust Rewrite** | Full e-scooter firmware rewrite in Rust after CAN bus RE |
| **ScooterHacking (SHFW)** | Custom firmware ecosystem for Ninebot/Xiaomi — flashing tools, BMS repo, tuning |
| **openpilot / comma.ai** | Open-source ADAS for 200+ cars. Published DBC files for every supported CAN bus |
| **Open Vehicle Control System** | FOSDEM 2025 — full EV control stack with Vue.js + Elixir/Phoenix |

### Feature Mods

| Mod | Who does it | Ola applicability |
|-----|-----------|-------------------|
| Subscription feature unlock | Tesla (hardware glitching), BMW/VW (OBD coding) | **Investigate** — MoveOS+ gates may be head-unit-side flags |
| Custom engine sounds | RPM-linked synthesis via CAN | **Yes** — RPM on `0x313`, `enginesound` service replaceable |
| Telemetry → Home Assistant | TeslaMate MQTT, Torque Pro REST | **Yes** — bridge app reading CAN → MQTT |
| Cell degradation tracking | LeafSpy, ScanMyTesla | **Yes** — all 14 cell voltages on CAN, zero risk |
| Speed/performance tuning | Ninebot/Xiaomi firmware flash | **No** — motor control is VCU firmware, not head unit |
| Custom boot animation | Replace `bootanimation.zip` | **No** — `/system` is dm-verity protected |

### The Pattern

Every successful vehicle hacking project follows the same path:
1. **Read CAN data** → understand what the vehicle broadcasts
2. **Build a decoder** → map raw bytes to meaningful values
3. **Log everything** → store time-series data persistently
4. **Visualize** → dashboards, graphs, real-time gauges
5. **Alert** → notifications for anomalies (cell imbalance, temperature)
6. **Automate** → react to vehicle state (charging triggers, health reports)

We're at step 1-2. The roadmap above takes us through 3-6.

---

## Recommended Priority Order

| # | Project | Effort | Value | Dependencies |
|---|---------|--------|-------|-------------|
| 1 | Explore safe gRPC methods | 1 hour | High | None — just grpcurl commands |
| 2 | Decompile `vehicleparser` APK | 2 hours | Very high | ADB pull + jadx |
| 3 | Capture a charging session on CAN | 30 min | High | Charger + candump |
| 4 | Auto ADB re-injection script | 30 min | Medium | Laptop on same network |
| 5 | Ride data logger (basic CSV) | 1 day | High | Shell script or simple APK |
| 6 | Battery health monitor APK | 2-3 days | Very high | CAN decode knowledge |
| 7 | Explore `RemoteRunTestCmd` | 1 hour | Medium | None |
| 8 | Custom engine sounds | 1 hour | Fun | ADB access |
| 9 | Diagnostics APK with gRPC | 1 week | Very high | Android dev setup |
| 10 | Custom dashboard | 2 weeks | High | Any UI toolkit that targets Android |
| 11 | Home Assistant integration | 2-3 days | Medium | MQTT broker + sideloaded bridge |
| 12 | MoveOS+ feature gate analysis | 2 hours | Medium | Active trial or friend with MoveOS+ |
| 13 | Firmware analysis | 1 week+ | Research | Ghidra + patience |

---

## Open Questions

### ADB connection prevents head unit sleep

Normally the BMS powers off the head unit ~2 min after the scooter locks on the stand. With an active ADB TCP connection on port 5555, the head unit stayed powered (and the PIN screen stayed lit) for hours until the BMS eventually force-rebooted it.

Likely cause: ADB keepalive traffic prevents the `autoturnoff` service from signaling idle to the BMS. Needs verification:
1. Disconnect ADB, put on stand, confirm normal ~2 min shutdown
2. Reconnect ADB, put on stand, confirm it stays on
3. If confirmed, `adb disconnect` after each session to let the scooter sleep normally

---

## What NOT to Do

- Don't call `SwUpdate*`, `ProvisionVin`, `ProvisionConfig`, `ScooterModeChange`, `Deinit`, `GenerateCerts`, `RegisterInstallCerts`, or `RemoveWifiCredentials`
- Don't write to CAN IDs `0x6BC` or `0x6A1` without understanding the consequences
- Don't flash firmware from the head unit
- Don't modify `/system` or `/vendor` (dm-verity will reject it anyway)
- Don't expose VIN, Wi-Fi credentials, or personal data
- Don't replay captured CAN frames to the real vehicle bus
- Don't disable safety-critical services (`vehiclestatemanager`, `breakswitchmodel`)
