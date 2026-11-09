# Ola S1 Pro Gen 1 — Customization Plan

Exploration of solutions for every known head-unit problem, with phased
approach to fully customizing the scooter. Nothing here is implemented yet —
this is the decision document.

Cross-references:
- `research/reboot-analysis.md` — HOHS watchdog and HVSM silent reboot details
- `research/unlock-mechanism.md` — 0x6BC unlock chain and MCU bridge state-gating
- `research/service-map.md` — full 25-service architecture map
- `research/ola-diagnostics-app-analysis.md` — 0x6A1 discovery, UDS stack

---

## Problem 1: HOHS Watchdog Reboots (can't disable OTA)

HOHS checks every 10 minutes if HCCM and HOTA are running. If either is missing,
it reboots the head unit. This prevents us from disabling OTA updates.

### Option A: Patch HOHS APK — remove the process check

Pull the HOHS APK, decompile with apktool, edit the smali for
`ConnectivityIssueHandlingTimer.checkServiceIsRunningOrNot()` to always return
true (or NOP the `rebootTheDevice()` call), recompile, resign with the platform
key (we have root, so we can extract it or install as system app), push back.

- **Risk:** HOHS also does legitimate health reporting to cloud. If we gut the
  whole thing, Ola cloud might flag the device. But we can surgically remove
  just the reboot path.
- **Complexity:** Medium — smali patching is straightforward, but re-signing
  with the platform key needs testing.

### Option B: Patch HOHS config — empty the process list

The process list is `AppConstants.PROCESS_LIST`. If this is overridable by
pushed config (`ccm_timer_duration` is configurable), maybe the process list is
too. Check `/data/ola/config/som_platform_config.json` and
`som_service_config.json` for any HOHS-related config keys.

If we can write a config file that sets `PROCESS_LIST` to empty, the watchdog
runs but never triggers.

- **Risk:** Low — no binary patching needed.
- **Likelihood:** Uncertain — the list might be hardcoded in smali, not
  config-driven.

### Option C: Stub out OTA — keep it running but neutered (recommended first step)

Instead of disabling HOTA, let it run but block its ability to actually
download/install anything:

- `iptables` rules blocking the FOTA download URLs (Tonyodev Fetch2 downloader)
- Or replace the OTA APK with a stub that starts, stays alive (satisfying
  HOHS), but does nothing
- Or use the root shell to make the firmware staging directory
  `/data/ola/recovery/firmwares/` read-only

- **Risk:** Lowest — HOHS sees both processes alive, never triggers. Cloud sees
  the device as "online" but updates silently fail.
- **This is probably the smartest first move.**

### Option D: Replace HOHS entirely

Write our own health service with the same package name that starts, stays
alive, but doesn't watchdog. Platform-sign it and push to `/system/priv-app/`.

- Most invasive but gives us full control.

### Recommendation

Start with **Option C** (iptables + read-only staging dir). It's reversible, no
APK patching, and HOHS stays happy. If that's not granular enough, move to
**Option A** (smali patch HOHS).

---

## Problem 2: HVSM Silent Overnight Reboots

Separate from HOHS — HVSM does `exec("reboot")` between 00:00-05:00 with a
~19 hour threshold via `trySilentSomReboot()`.

### Option A: Config override

`CONFIG_PERIODIC_REBOOT` defaults to `true` and
`CONFIG_PERIODIC_REBOOT_FREQUENCY` defaults to `1`. Both are in
`HVSM/.../utils/ConfigData` and "can be overridden by pushed config."

Check if `/data/ola/config/` has a config file that sets these. If so, set
`CONFIG_PERIODIC_REBOOT=false`.

### Option B: Smali patch HVSM

Patch `trySilentSomReboot()` to always return early. More invasive than config
but guaranteed.

### Recommendation

**Option A first** — check the config files for the periodic reboot flag.

---

## Problem 3: Unlock Commands Ignored After Standby

The MCU bridge state-gating problem. When the scooter goes to standby/sleep, the
UART-to-CAN bridge stops forwarding 0x6BC frames to the physical bus. The head
unit is still on (gRPC works), but commands are silently dropped.

### Path A: HMI_Wakeup_pass (0x62) — the untested command

This is the last command in the CommandFromHMI enum. Its name literally says
"wakeup." If the MCU bridge handles this command specially (processes it even in
standby to wake the bridge), it solves everything.

The bridge firmware must have some awareness of what it forwards — if 0x62 is a
"pass-through even in standby" marker, sending it before unlock would wake the
bridge.

- **Test:** Send 0x62, wait, then send 0x19 (unlock). If indicators respond
  after, the bridge is awake.
- **Risk:** Low — it's a standard CommandFromHMI value, same format as
  everything else.

### Path B: 0x6A1 (TCU channel) — may bypass the gate entirely

The diagnostics app uses 0x6A1 for lock/unlock instead of 0x6BC. The TCU is a
separate module that handles cloud commands. The VCU might process 0x6A1 even
when the bridge is in standby, because cloud/app unlock *must* work when the
scooter is locked — that's the whole point.

The Ola mobile app unlocks via: Phone -> BLE module -> BCM -> VCU (hardware
path, bypasses head unit entirely). But the diagnostics app uses 0x6A1, which is
the TCU path.

- **Key question:** Can the head unit emit 0x6A1 on vcan0 and have the MCU
  bridge forward it? The bridge might filter by CAN ID — only 0x6BC may be
  whitelisted for head unit -> physical bus. Or it might forward everything.
- **Test:** `cansend vcan0 6A1#0100000000000000` (unlock via TCU channel)
  when the scooter is in standby.
- **Risk:** Moderate — 0x6A1 is a known command format from the diagnostics
  app, but we've never tested it from the head unit side.

### Path C: UART bridge direct manipulation

The bridge is on `/dev/ttyHSL1` at 921600 baud. We have root. If we can
understand the bridge protocol, we might be able to send a wake command directly
to the bridge chip, bypassing the SocketCAN layer entirely.

- **Exploration:** `cat /dev/ttyHSL1` while sending CAN commands to see the raw
  protocol, check for bridge firmware docs, look at what HVDP's
  `libJNIStubTest.so` does during init.
- **Risk:** High complexity — reverse engineering the bridge protocol is a
  separate project.

### Path D: Keep the scooter awake (prevent sleep)

Prevent the MCU bridge from going to standby by sending a periodic heartbeat
CAN frame.

- **Problem:** This drains the battery. The BMS puts the system to sleep for a
  reason (14S NMC pack, self-discharge matters). Not viable long-term.
- Could be viable with a timer — keep awake for 30 min after lock, then let
  it sleep.

### Path E: BLE proximity wake + head unit command

The BLE module is always-on (it's how the Ola app does proximity unlock). If we
could talk to the BLE module from the head unit's Bluetooth or via CAN, we could
trigger a wake.

But the BLE module is separate hardware on the BCM, and the head unit BT is a
different radio (A2DP/HFP, not the vehicle BLE). This path is architecturally
blocked unless we find a CAN command that the BLE module processes.

### Path F: Android app as a wake proxy

Run a persistent Android service on the head unit that listens for commands over
Wi-Fi/4G (not MQTT — our own channel). When a wake+unlock command arrives: first
try 0x62 (HMI_Wakeup_pass), wait, then send 0x19 (unlock) 30x.

If the head unit is still on when the scooter is in standby (it is — gRPC
works), this service can keep trying.

The service itself doesn't solve the bridge problem, but it provides the remote
command channel. The bridge wake is still needed.

- **Combine with Path A or B:** If either 0x62 or 0x6A1 works in standby, this
  service becomes the remote trigger.

### Path G: Hardware wake via BMS

The only guaranteed wake paths are hardware: charger, IMU movement, push button,
RTC timer.

We could set an RTC wake timer from the head unit (if we can write to the BMS
RTC config via UDS), so the scooter wakes at a scheduled time. Or use the IMU —
physically moving the scooter wakes it (tamper detection). Not practical for
remote unlock, but confirms the hardware path works.

### Recommendation

**Test Path A (0x62) first**, then **Path B (0x6A1)**. These are the cheapest
tests. If 0x62 wakes the bridge, combine it with Path F (Android service for
remote commands) and you have remote unlock. If 0x6A1 bypasses the gate
entirely, that's even better — single-frame unlock that works in any state.

---

## Problem 4: CAN Logger / OlaMate Telemetry

CANLOGGER already captures the entire raw CAN bus. We can leverage the same
approach or its output for OlaMate.

### What CANLOGGER does

- Opens its own SocketCAN socket on vcan0
- Captures ALL CAN IDs, no filter
- Batches into protobuf `VcanPacketList { timestamp, repeated VCANPackets }`
- Writes to `/data/ola/sys_logs/zip/` as compressed zips
- Ships to cloud via HCCM MQTT
- Cloud can remotely start/stop/change log level

### Option A: Read CANLOGGER's output directly

Read the protobuf files from `/data/ola/sys_logs/zip/` and
`/data/ola/hf/*.proto`. We already have root — just read the files. No need to
open our own CAN socket. Also read HDA's ring buffer at `/data/ola/hf/*.proto`
— these are already decoded per-subsystem (BMS, BCM, MCU, SOM packets).

- **Downside:** We're reading Ola's protobuf format — need to decode
  `VcanPacketList` proto.

### Option B: Bind HVDP IParserService (decoded telemetry)

Subscribe to decoded callbacks: battery, motor, display, charger, vehicle,
modes, alert, IMU, GPS, versions. Get fully typed data (speed as int, SoC as
float, odometer as long) — no CAN parsing needed.

- **Need:** Platform signing or root injection to bind the AIDL.

### Option C: Use diagnostics_server CanDumpStream (recommended)

We already have gRPC access. `CanDumpStream` gives us a live stream of all CAN
frames. Can filter by ID list using the Register message's `can_ids` field.

This is what we're already using for individual commands — just switch to
streaming mode.

- **Best for OlaMate's telemetry logger** — already works, no auth needed,
  already have the proto.

### Option D: Open our own SocketCAN

From a root shell, run our own `candump vcan0` or open a raw socket. Full
control, no dependency on any Ola service.

### Recommendation

**Option C (CanDumpStream via gRPC)** for OlaMate. We already have the
infrastructure. Stream all frames, decode the ones we care about using our CAN
map, store locally. For decoded higher-level data (range, trip stats, etc.),
consider also binding HVDP's IParserService if we platform-sign OlaMate.

---

## Phased Rollout

### Phase 1: Neutralize the watchdog (safe, reversible)

- iptables block FOTA download URLs
- Make `/data/ola/recovery/firmwares/` read-only
- Set `CONFIG_PERIODIC_REBOOT=false` in config if possible
- **Result:** No more unwanted OTA, no more silent reboots, HOHS stays happy

### Phase 2: Test wake paths (needs live scooter)

- Test 0x62 HMI_Wakeup_pass in standby
- Test 0x6A1 commands in standby
- If either works, we have remote unlock capability

### Phase 3: Build the persistent command service

- Android app on the head unit (or extend OlaMate)
- Listens on Wi-Fi for commands (when on same network)
- Also listens on a custom TCP port over 4G (if HCCM/MQTT is still alive, we
  could even piggyback on MQTT topics, or use our own channel)
- Executes wake + unlock + any 0x6BC command

### Phase 4: OlaMate telemetry via CanDumpStream

- Stream all CAN frames via gRPC
- Decode and log locally
- Optionally bind HVDP for decoded data

### Phase 5: Patch HOHS if needed

- If iptables isn't enough, smali-patch HOHS to remove the reboot path entirely
- Or replace with our own stub
