# Head-Unit Reboot / Shutdown Path Analysis

Static analysis of the decompiled Ola S1 Pro Gen-1 head-unit APKs to enumerate
every code path that reboots or shuts down the Android head unit (SOM), and to
explain the observed random reboots after disabling `com.olaelectric.ota`.

**Scope:** HVDP, HVSM, HHMIC, HOHS, HAIP, VehicleDataService.
**Method:** apktool smali, static only (no live logcat yet — see Verification).

---

## TL;DR — most likely root cause

Disabling the OTA app is almost certainly what started the reboots.

The health service **HOHS** (`com.olaelectric.olahealthservice`) runs a watchdog
every **10 minutes** that checks a hard-coded list of processes. If **any** of
them is not currently running, it immediately triggers a device reboot. The
watched list is:

```
PROCESS_LIST = [ "com.olaelectric.cloudconnectivitymanager",
                 "com.olaelectric.ota" ]
```

You ran `pm disable-user com.olaelectric.ota`, so that process never appears in
the running-process list. Every watchdog tick therefore concludes "service is
not running" and calls `rebootTheDevice()`.

The reboot is **state-gated**: it fires immediately only when the vehicle is in
`SLEEP`; otherwise it sets a deferred flag (`isRebootDevice = true`) that fires
on the **next transition into SLEEP**. That gating explains both of your
symptoms:

- **Parked, pressed the button, it rebooted** — the deferred flag was set
  earlier by a watchdog tick, and the parking/sleep transition cashed it in.
- **Died while sending CAN commands (after 0x1E rear-light-on)** — a 10-minute
  watchdog tick fired during that window. The `0x1E` correlation is almost
  certainly coincidental; nothing in the rear-light path reboots anything.

**Fix to test the hypothesis:** re-enable OTA
(`pm enable com.olaelectric.ota`) and confirm the reboots stop. See Verification.

---

## Reboot/shutdown primitives that actually exist

Only two low-level primitives reboot the SOM. Everything else routes into one of
these. There is **no** `PowerManager.reboot()`, no `sys.powerctl`, no
`svc power`, no `setprop ctl.*` anywhere in these APKs.

| # | Primitive | Location | Effect |
|---|-----------|----------|--------|
| A | `Runtime.getRuntime().exec("reboot")` | HVSM `VehicleStateController.rebootSOM(String)` | Direct Linux userspace reboot of the SOM. Boot reason `reboot`. Sleeps 2000 ms first, saves `lastRebootTimestamp`, emits a "silent reboot" app event. |
| B | CAN `Scooter_Reboot` (0x0E) on 0x6BC | HVSM `VehicleStateController.onScooterReboot()` → `VehicleParserManager.sendCommandToScooter(Scooter_Reboot)` | Sends the reboot command to the VCU over CAN. |

Both are clean, software-initiated reboots, consistent with your observed
`reboot` boot reason (not watchdog/crash).

---

## Path 1 — HOHS health watchdog (PRIMARY SUSPECT)

**APK:** HOHS · **Trigger:** 10-minute timer + missing process · **CAN 0x6BC? indirectly (primitive B)**

### Chain

```
OlaHealthService.onStartCommand
  → ScheduledExecutorService.scheduleAtFixedRate(
        ConnectivityIssueHandlingTimer,           // Runnable
        initialDelay = 0,
        period       = OHS.CCM_Timer_In_Minutes,   // default 0xA = 10 minutes
        TimeUnit.MINUTES)

ConnectivityIssueHandlingTimer.run()
  → getDataFromDataStore()
  → checkServiceIsRunningOrNot()
        processes = ActivityManager.getRunningAppProcesses()
        for name in AppConstants.PROCESS_LIST:          // [ccm, ota]
            if name in processes:  log "service is running"
            else:                  log "service is not running"
                                   rebootTheDevice()     // <-- fires here
```

The loop **breaks and reboots on the first missing process**. With OTA disabled,
`com.olaelectric.ota` is always missing.

### State gating (`rebootTheDevice`)

```
rebootTheDevice():
  if isVSMConnected() && currentVehicleState == SLEEP:
        log "Vehicle is in sleep mode, sending reboot command"
        vehicleStateManager.updateKeyOnAndReboot()      // reboot NOW
  else:
        AppConstants.setRebootDevice(true)              // defer
```

### Deferred trigger (`VehicleParserRepository$vehicleModeCallbacks$1.onVehicleStateChanged`)

```
onVehicleStateChanged(state):
  if state == SLEEP && AppConstants.isRebootDevice():
        setRebootDevice(false)
        log "Vehicle is in sleep mode, sending reboot command"
        vehicleStateManager.updateKeyOnAndReboot()      // deferred reboot fires
```

### How the reboot is actually performed

```
HOHS VehicleStateManager.updateKeyOnAndReboot()
  → updateSomStatus("keyon")
  → sendScooterRebootCommand()
      → AIDL IVsmService.onScooterReboot()          (binder to HVSM)
          → HVSM VehicleStateManagerImpl.onScooterReboot()
              → VehicleStateController.onScooterReboot()
                  → CAN Scooter_Reboot (0x0E) on 0x6BC   (primitive B)
```

### Key identifiers

- `HOHS/.../ConnectivityIssueHandlingTimer.{run,checkServiceIsRunningOrNot,rebootTheDevice}`
- `HOHS/.../utils/AppConstants.PROCESS_LIST` = `[cloudconnectivitymanager, ota]`
- `HOHS/.../utils/AppConstants.CCM_Timer_In_Minutes` = `0xA` (10)
- `HOHS/.../repoImpl/VehicleParserRepository$vehicleModeCallbacks$1.onVehicleStateChanged`
- `HOHS/.../controller/VehicleStateManager.{updateKeyOnAndReboot,sendScooterRebootCommand}`

---

## Path 2 — HVSM periodic "silent" reboot

**APK:** HVSM · **Trigger:** vehicle-info callback, gated to 00:00–05:00 · **Primitive A (`exec reboot`)**

```
VehicleParserManager$vehicleInfoCallbacks$1  → trySilentSomReboot()

trySilentSomReboot():
  if ConfigData.CONFIG_PERIODIC_REBOOT                  // default TRUE
     && isCurrentTimeBetweenMidnightAndFiveAM():
        elapsed = now - SharedPrefManager.getLastRebootTimestamp()
        threshold = (CONFIG_PERIODIC_REBOOT_FREQUENCY*24 - 5) hours
                     // default freq = 1  ->  19 hours
        if elapsed > threshold:
            VehicleStateController.rebootSOM(packageName)   // exec("reboot")
        else:
            log "No silent reboot, skipping today"
```

This is a scheduled maintenance reboot. It **only** runs between midnight and
5 AM and at most roughly once per day. It does **not** explain daytime reboots,
but it is a second independent path to `exec("reboot")` and a genuine reboot
source worth knowing about. Config defaults live in
`HVSM/.../utils/ConfigData` (`CONFIG_PERIODIC_REBOOT = true`,
`CONFIG_PERIODIC_REBOOT_FREQUENCY = 1`); both can be overridden by pushed config.

---

## Path 3 — Remote MQTT reboot commands (cloud push)

**APK:** HOHS · **Trigger:** MQTT message from Ola cloud · **App restart, not full device reboot**

`HSMqttConnectionWorker$doWork$2` matches incoming MQTT command strings:

- `CCM_REBOOT` → `RestartAppUseCase.invoke(...)`
- `DA_REBOOT`  → `RestartAppUseCase.invoke(...)`

These restart an app/component (cloud-connectivity manager / data aggregator),
not the whole device. They require an active cloud/MQTT connection and a
server-side push, so they are not a plausible cause of your offline bench
reboots. Noted for completeness.

---

## Path 4 — Direct AIDL `rebootSOM` exposure

`HVSM VehicleStateManagerImpl.rebootSOM(String)` is exported via the `IVsmService`
AIDL binder and forwards straight to `VehicleStateController.rebootSOM()`
(primitive A, `exec("reboot")`). Any process that binds `IVsmService` and holds
the binder permission can reboot the SOM by calling it with a package-name
string. Within these six APKs the only in-tree caller is the periodic path
(Path 2). This is a capability to be aware of, not an active trigger.

---

## Answers to your specific questions

**1. Explicit reboot calls.** No `PowerManager.reboot`, `sys.powerctl`,
`setprop ctl.*`, or `svc power` anywhere. The only userspace reboot is
`Runtime.exec("reboot")` in `HVSM VehicleStateController.rebootSOM`. The only
`Scooter_Reboot` (0x0E) sender is `HVSM VehicleStateController.onScooterReboot`
(driven by the HOHS watchdog). `MCU_Reboot` (0x12) / `HU_Reboot` (0x13) exist in
the `CommandFromHMI` enum but have **no sender** in any of these APKs.

**2. autoturnoff.** The running `com.olaelectric.autoturnoff` service is **not**
one of these six APKs and is not in the decompiled set, so it could not be
analysed here. It is not referenced by any reboot path above. It is also **not**
in HOHS `PROCESS_LIST`, so the watchdog does not care whether it runs. Pull and
decompile that APK separately if you want its behaviour; based on the name it
most likely blanks/sleeps the display rather than rebooting.

**3. Watchdog / health check.** Yes — Path 1. HOHS reboots when any watched
process is missing. It watches only `cloudconnectivitymanager` and `ota`. It
does **not** check CAN health, OTA *status*, or connectivity reachability for the
reboot decision; it is purely a process-liveness check.

**4. OTA-related reboot / disabling OTA.** This is the core finding. There is no
`update_engine` logic in these APKs, but **disabling `com.olaelectric.ota`
directly causes Path 1 to reboot the head unit**, because OTA is a hard-coded
member of the watchdog's `PROCESS_LIST`. The health service treats a missing OTA
process as "unhealthy" and reboots. This is exactly the mechanism you suspected.

**5. CAN-response reboot.** No. HVDP/HVSM do not reboot in response to receiving
frames on 0x6BC or to any VCU/BCM frame. The reboot flows **outbound** (HU sends
`Scooter_Reboot`), driven by the HOHS watchdog, never inbound. Sending
`Rear_Light_ON` (0x1E) or any other light/indicator command does not touch any
reboot path.

**6. ADB / diagnostics_server / port 50005 security reboot.** No. There is no
detection of ADB state, external connections, or port 50005 in any of these
APKs, and nothing wires such a check to a reboot. The `diagnostics_server`
gRPC service and port 50005 do not appear in the decompiled code. The only
50005 hits were unrelated `R$color` resource IDs.

**7. Sleep/wake behaviour.** The reboots are genuine software reboots
(primitive A or B), not merely cold-boot-from-sleep. However, the SLEEP state is
central: Path 1 defers its reboot until the vehicle enters SLEEP, so a reboot
that lands right as you park is the deferred watchdog decision cashing in, not
normal wake behaviour. A clean wake would not log
`"Vehicle is in sleep mode, sending reboot command"`.

---

## Trigger matrix

| Path | (a) Disabling OTA | (b) CAN cmds on 0x6BC | (c) ADB connected | (d) Waking from parked |
|------|:---:|:---:|:---:|:---:|
| 1 — HOHS watchdog | **YES (direct cause)** | No | No | Fires the deferred reboot on SLEEP entry |
| 2 — HVSM periodic | No | No | No | No (only 00:00–05:00, ~daily) |
| 3 — MQTT CCM/DA_REBOOT | No | No | No | No (needs cloud push; restarts app only) |
| 4 — AIDL rebootSOM | No | No | No | No (no in-tree caller besides Path 2) |

---

## Verification (do this before trusting the conclusion)

Static analysis strongly implicates Path 1, but it has not been confirmed on the
vehicle. Confirm with one of:

1. **Re-enable OTA and observe.** `pm enable com.olaelectric.ota`, then run for a
   few days. If reboots stop, Path 1 is confirmed.
2. **Watch the log.** Before a reboot, tag `ConnectivityIssueHandlingTimer`
   should print `"<pkg> service is not running"` followed by
   `"Vehicle is in sleep mode, sending reboot command"`. Grep logcat for those
   two strings:
   ```
   logcat -b all | grep -E "service is not running|sending reboot command"
   ```
3. **Keep OTA disabled without reboots** by neutralising the watchdog instead:
   disabling or stopping HOHS (`com.olaelectric.olahealthservice`) removes Path 1
   entirely. Note this also disables the legitimate health/telemetry role, and
   HOHS may itself be restarted by another supervisor — verify it stays down.
   Re-enabling OTA is the lower-risk option.

### Caveats

- `CCM_Timer_In_Minutes`, `CONFIG_PERIODIC_REBOOT`, and
  `CONFIG_PERIODIC_REBOOT_FREQUENCY` are all defaults in code and can be
  overridden by server-pushed config, so live values may differ.
- `com.olaelectric.autoturnoff` was not in the decompiled set and is unanalysed.
- `cloudconnectivitymanager` is the **other** watched process. If it ever dies
  (e.g. crash, or you disable it too), Path 1 reboots for the same reason.
