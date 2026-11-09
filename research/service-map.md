# Ola S1 Pro Gen 1 — Head-Unit Service Architecture Map

Static-analysis map of every system service on the Ola S1 Pro Gen 1 head unit
(Qualcomm SDM450, Android 10 / SDK 29, 1280x768, MoveOS 4.x). Produced by
decompiling all 24 Ola APKs with `apktool d --no-assets` and running `strings`
on the `diagnostics_server` Go binary, then tracing AndroidManifest components,
AIDL stubs/proxies, native CAN libraries, and cloud endpoints in smali.

Purpose: interoperability research on a personally owned device — to build
compatible dashboards, diagnostic tools, and the OlaMate telemetry logger
against the existing platform. Everything here is read/observe-oriented static
analysis; nothing flashes firmware.

Builds on and cross-references:
- `docs/architecture.md` — two-computer hardware model, CAN map, wake path
- `docs/hmi-apk-analysis.md` — HHMIC Kanzi internals and data-context XMLs
- `research/can-command-reference.md` — the 99-entry 0x6BC `CommandFromHMI` table
- `research/unlock-mechanism.md` — the passcode/unlock AIDL→CAN chain
- `research/reboot-analysis.md` — the HOHS watchdog reboot paths
- `proto/wifican.proto` — the authoritative 42-RPC diagnostics_server definition

> **Authority boundary.** The head unit is a terminal, not the vehicle
> authority. Motor control, locking, battery management, and safety live in
> separate microcontrollers (VCU, BMS, BCM, MCU, BLE) on the CAN bus. The head
> unit only *observes* most vehicle data and *requests* a fixed command set on
> CAN `0x6BC`. See `docs/architecture.md`.

---

## 1. Service inventory

All APKs are platform-signed and run as `android.uid.system` or are
signature-protected, so a third-party app must be platform-signed (or injected
via the root path) to bind them. `diagnostics_server` runs as root (uid 0) from
`/vendor/bin`.

| Code | Package | CAN | Cloud | Primary exposed AIDL |
|------|---------|-----|-------|----------------------|
| **HHMIC** | com.olaelectric.hmiclient | no | via CCM | — (pure Binder client) |
| **HHMIS** | com.android.hmiserverapp | no | via CCM | `IClientServiceInterface` |
| **HVDP** | com.olaelectric.vehicleparser | **R/W** | via CCM | `IParserService`, `ICommanderService` |
| **HVSM** | com.olaelectric.vehiclestatemanager | via HVDP | via CCM | `IVsmService` + `VSM_AUTHORITY` provider |
| **VehicleDataService** | com.olaelectric.vehicledataservice | **R/W** | no | `IVehicleDataManager` |
| **HOHS** | com.olaelectric.olahealthservice | via HVSM | own REST + CCM | `OlaHealthService` binder |
| **HCCM** | com.olaelectric.cloudconnectivitymanager | no | **MQTT owner** | `ICcmInterface` |
| **HOTA** | com.olaelectric.ota | no | via CCM | `IOTAManagerInterface` |
| **HSSS** | com.olaelectric.connectivityservice | no | Wi-Fi/LTE mgmt | `ISystemSettings` (+ sub-binders) |
| **HAIRS** | com.olaelectric.airangeservice | via HVDP | via CCM | `airangeinterface.IRangeInterface` |
| **HVRS** | com.olaelectric.vehiclerangeservice | via HVDP | via CCM | `IRangeInterface`, `IDataAnalyticsCallbacks` |
| **HAIP** | com.olaelectric.aiproxy | no | via CCM | `IAIProxyAIDL` |
| **HDA** | com.olaelectric.dataaggregator | via engine | via CCM | `IDataAggregatorInterface` |
| **HPMS** | com.olaelectric.profilemanagerservice | via HVDP | via CCM | `IProfileManagerService` + providers |
| **HOM** | com.olaelectric.olaevnavigation | no | maps.olaelectric.com | `INavigationService` |
| **HCS** | com.olaelectric.convoyservice | no | LAN P2P | `ConvoyInterface` |
| **HDUX** | com.olaelectric.duxwebview | no | ola-ev-ui web | `DuxService` (+ JS bridge) |
| **HNFS** | com.olaelectric.notificationforegroundservice | no | via CCM | `INotificationService` |
| **HVS** | com.olaelectric.enginesound | **read** | analytics via CCM | `IEngineSoundAidlInterface` |
| **HAIATO** | com.olaelectric.autoturnoff | via HVDP | no | `AIAutoTurnOffService` binder |
| **HAIBS** | com.olaelectric.breakswitchmodel | via HVDP | via CCM | `breakswitchinterface` |
| **CANLOGGER** | com.olaelectric.canlogger | **read** | via CCM | `ICanLoggerInterface` |
| **HMFG** | com.ola.mfgapp | via gRPC | hotspot | gRPC client of diagnostics_server |
| **UdsTestApp** | com.olaelectric.udstestapp | via HIDL | no | — (HIDL client) |
| **diagnostics_server** | /vendor/bin (Go) | **R/W** | provisioning hosts | gRPC `wifican.WifiCanRpc` :50005 |

"CAN R/W" = opens its own SocketCAN socket on `vcan0`. "via HVDP" = reads
decoded signals / sends commands through HVDP's AIDL, never touching the bus.

---

## 2. Service dependency diagram

Arrows point from consumer to the service it binds (A → B means "A binds B").

```
                        ┌─────────────────────────────────────────────┐
                        │              Ola cloud (4G / Jio)            │
                        │   Kong + mTLS gateways, MQTT broker,         │
                        │   maps, ola-ev-ui, provisioning, FOTA        │
                        └───────────────▲──────────────┬──────────────┘
                                        │ MQTT/REST    │ push
                                        │              ▼
   ┌───────────┐   bind    ┌────────────────────────────────────┐
   │  HHMIC    │──────────▶│  HHMIS (com.android.hmiserverapp)   │   the UI bridge / hub
   │ Kanzi UI  │◀──────────│  IClientServiceInterface bus        │
   └───────────┘  callback └───┬───────┬────────┬────────┬───────┘
      ▲ (also binds many        │       │        │        │
      │  services directly)     ▼       ▼        ▼        ▼
      │                      ┌────┐  ┌─────┐  ┌──────┐  ┌──────────────┐
      │                      │HVDP│  │HVSM │  │ HCCM │  │ HPMS / HVRS /│
      │                      │    │  │     │  │(MQTT)│  │ HSSS / HVS / │
      │                      └─┬──┘  └──┬──┘  └──▲───┘  │ HOTA ...     │
      │                        │        │        │      └──────────────┘
      │             IParser/   │   IVsm │  binds │ ICcmInterface
      │             ICommander │        │        │ (cloud pipe, everyone binds it)
      │                        ▼        ▼        │
      │                   ┌──────────────────┐   │
      │   HVSM, HPMS,     │   vcan0 socket   │   │
      │   HCCM, HAIRS,    │  (SocketCAN)     │   │
      │   HVRS, HAIBS,    └────────┬─────────┘   │
      │   HAIATO, HDA ───▶ HVDP ───┘             │
      │                            │             │
      │   HVS, CANLOGGER,          │ UART bridge │
      │   diagnostics_server ──────┤ (vcan0 ↔    │
      │   open their OWN vcan0     │  physical)  │
      │   socket (not via HVDP)    ▼             │
      │                   ═══════════════════════╪═══ physical CAN bus
      │                     VCU · BMS · BCM · MCU · BLE
      │
      └── Watchdog layer:
          HOHS ──(every 10 min: are HCCM + HOTA alive?)──▶ if not, reboot via HVSM→CAN 0x0E
          HOHS binds HVSM, HCCM, HVDP, HDA
```

Consumer-to-provider bind edges (who binds whom):

```
HHMIC   → HHMIS, HCCM, HPMS, HSSS(SystemSettings), HOM, HAIP, HNFS, HCS, HDUX, HOTA, media-session
HHMIS   → HVDP, HVSM, HCCM, HPMS, HVRS, HSSS, HVS, HOTA
HVSM    → HVDP, HCCM, CANLOGGER, HDA
HOHS    → HVSM, HCCM, HVDP, HDA
HCCM    → HVDP
HOTA    → HCCM, HVSM
HPMS    → HVDP, HVSM, HCCM
HVRS    → HVDP, HCCM, HPMS
HAIRS   → HVDP, HCCM
HAIP    → HAIRS, HAIATO, HCCM, HVDP
HDA     → HCCM, HVSM(provider)
HAIATO  → HVDP
HAIBS   → HVDP, HCCM, HPMS
HVS     → (vcan0 directly), HCCM(analytics)
CANLOGGER → (vcan0 directly), HCCM
HOM     → HCCM, HPMS
HNFS    → HCCM, HPMS
HCS     → HPMS(provider)        [else LAN-local]
HDUX    → HPMS                  [else Ola web]
HMFG    → diagnostics_server (localhost gRPC :50005)
UdsTestApp → ola.hardware.uds@1.0 (HIDL)
```

The four native CAN entry points onto `vcan0` are independent sockets:
`HVDP` and `CANLOGGER` and `HVS` use **libJNIStubTest.so**;
`VehicleDataService` uses **libcan_jni.so**; `diagnostics_server` uses Go
SocketCAN. HVDP is the only one that both decodes to typed AIDL and sends the
`0x6BC` command set.

---

## 3. Boot order and liveness

- **Boot triggers.** CANLOGGER, HOTA (`InstallationVerifier`), and several
  services start on `BOOT_COMPLETED`. HVDP must be up before any consumer gets
  real data; consumers auto-rebind when it dies.
- **Liveness policy (critical).** `HOHS` runs a 10-minute watchdog that reboots
  the head unit if **`com.olaelectric.cloudconnectivitymanager` (HCCM)** or
  **`com.olaelectric.ota` (HOTA)** is not in the running-process list. Never
  `pm disable` either one. See §5 (HOHS) and `research/reboot-analysis.md`.
- **What breaks if X is disabled** is tabulated in §7, Q1.

---

## 4. Core data pipeline

### HVDP — com.olaelectric.vehicleparser  (the CAN parser)

1. **Purpose.** The heart of the read path and the only service that both
   decodes the bus and sends the HMI command set. Opens its own SocketCAN
   socket, decodes ~80 named CAN IDs into typed per-domain callbacks, and owns
   the HMI→vehicle command channel on CAN `0x6BC`.
2. **AIDL.** Service `com.olaelectric.vehicleparser.services.VehicleParserService`
   (exported, action `...VehicleParserService`). `onBind` returns
   **`IVehicleService`** with `getParserServiceBinder()` → **`IParserService`**
   and `getCommanderServiceBinder()` → **`ICommanderService`**.
   - `IParserService` — 14 `subscribe*(String clientId, <callback>)` methods:
     Battery, Motor, Display, Charger, Vehicle, VehicleModes, Alert, IMU,
     HandleBar, Proximity, VehicleCommand, Map, HardwareVersion, Widget. Each
     callback is a fully-decoded typed stream (e.g.
     `IBatteryInfoCallbacks.onOverallSocChanged(float)`,
     `IMotorInfoCallbacks.onMotorRpmChanged(int)/onSpeedChanged(int)`,
     `IDisplayInfoCallbacks.onOdoValueChangedInMeters(long)/onRangeChanged(int)`,
     `IVehicleModeCallbacks.onVehicleStateChanged(VehicleStates)`).
   - `ICommanderService` — `sendCommandToScooter(CommandFromHMI)`,
     `sendCloudCommandToScooter(CommandFromApp)`, `unlockedByPasscode(boolean)`,
     `sendAckPasscodeCmd(int)`, `sendProximityCmd(...)`, `sendSOCLimitToScooter`,
     `setScooterBrightnessLevel`, `getProximityAddress():BleDetails`.
   - **Consumes** `ICcmInterface` (CCM) for profile/token/config.
3. **CAN.** READ: decodes ~80 IDs from `constants/CanIDConstantsKt`. Key IDs:
   `0x120` overall SoC; `0x11c/0x140/0x150/0x160/0x190/0x640` BMS params;
   `0x313/0x113/0x223` motor; `0x352` speed/display SoC; `0x353` tell-tales;
   `0x356` odometer (metres); `0x143` drive mode; `0x144` lock state;
   `0x682` dynamics; `0x683` safety (fall/tow/regen/hill); `0x6f4` range-per-mode;
   `0x689` VIN; `0x6c0` command ACK; `0x66e` VCU faults; `0x61d/0x63d/0x64d` IMU;
   `0x6a4/0x6a5/0x6a6` GPS/maps; `0x62d/0x213/0x508` charger; version IDs.
   WRITE: all 99 `CommandFromHMI` commands on **`0x6BC`** via
   `MasterCommander` → `CanUtils.sendCan0Data` → `CanSocket` (native
   **libJNIStubTest.so**). Unlock = byte0 `0x19` sent 30× at 100 ms.
4. **Network.** NewRelic only (`mobile-collector-nr` / `mobile-crash-nr.olaelectric.com`).
   Cloud goes through the consumed `ICcmInterface`.
5. **Key classes.** `parsers/MasterParser`, `parsers/MasterCommander`,
   `services/ParserServiceImpl` + `CommanderServiceImpl` + `VehicleServiceImpl`,
   `utils/CanSocket` + `utils/CanUtils`.
6. **Timers.** `utils/WatchDogMonitor` (`Handler.postDelayed`, interval const
   `0x9c4`=2500 ms) tracks lock state; unlock loop 30×@100 ms. No reboot here.
7. **Dependencies.** Binds CCM. Bound by HVSM, HHMIS, HPMS, HCCM, HVRS, HAIRS,
   HAIP, HAIATO, HAIBS. Shares the `com.olaelectric.vehicleinterface` AIDL
   package (callback/parcelable defs) with every consumer.
8. **Data flow.** IN: raw `vcan0` frames → decoded per domain → typed callbacks
   to all subscribers. OUT: `ICommanderService` → frame on `0x6BC` → VCU/BCM;
   ACK returns on `0x6C0`.

### HHMIS — com.android.hmiserverapp  (the UI bridge / hub)

1. **Purpose.** 80 MB aggregator that binds *every* backend, normalises it into
   one flat command/update bus, and exposes that single interface to the Kanzi
   client HHMIC. Everything the stock UI shows and every UI action flows through
   it. Despite the `com.android` namespace it is custom Ola code.
2. **AIDL.** Exposed service `com.android.hmiserverapp.VehicleParserService`
   (exported, **bound by component name**, no action) →
   **`IClientServiceInterface`**. 24 methods — a generic typed command bus keyed
   by the **`ClientCmd` enum (71 values)**:
   `on{Void,Boolean,Integer,Float,String}HMICmd(ClientCmd, value)` (UI→server),
   `addCallback(IClientServiceInterfaceCallback)`, `onPasscodeEntered`,
   `updateVolume/updateMotorVolume/updateChimeVolume/updateSystemBrightness`,
   `on{Bolt,Vintage,Eclipse}SoundCustomized`, `sendCommandForPartyMode`,
   `download()/install()/subscribeToUpdateTrigger(IOTAInterface)`,
   `checkGeoFenceForUser()/checkTimeFenceForUser()`.
   Callback **`IClientServiceInterfaceCallback`** delivers server→UI updates
   keyed by the **`ServerCmd` enum (178 values)**:
   `on{Void,Boolean,Integer,Float,String}Update(ServerCmd, value)`, plus
   `onScooterUnlocked`, `onPassCodeVerify(boolean,int)`, `onPopUpCommandReceived`,
   `setRangeKMBasedOnMode(IIII)`, `onWidgetInfo(II)`, `onVDPCallbackMissing()`.
   - **Consumes:** HVDP (`IParserService`+`ICommanderService` via
     `VPServerConnection`), HVSM (`IVsmService`), HCCM, HPMS
     (`IProfileManagerService`), HVRS (`IRangeInterface`), HSSS
     (`ISystemSettings`), HVS (`IEngineSoundAidlInterface`), HOTA
     (`IOTAManagerInterface`).
3. **CAN.** None directly — all data pre-decoded by HVDP; commands via HVDP.
4. **Network.** NewRelic; cloud via CCM/OTA. `usesCleartextTraffic=false`.
5. **Key classes.** `VehicleParserService`, `IClientServiceInterfaceBuilder`,
   `vehicle/VPServerConnection`, `vehicle/VehicleStateManager`,
   `parcelables/ServerCmd` + `parcelables/ClientCmd` (the field dictionary),
   `utils/WatchDogMonitor`.
6. **Timers.** `WatchDogMonitor` with an OTA-pause flag
   (`setOtaWatchDogPauseFlag` suppresses it during OTA). HVDP death surfaces as
   `onVDPCallbackMissing()`; `VPServerConnection` auto-rebinds.
7. **Dependencies.** The central hub (binds 8 services). Bound by HHMIC.
8. **Data flow.** IN: decoded telemetry + feature flags from HVDP/HVSM + range/
   settings/OTA/sound → mapped to a `ServerCmd` → pushed to HHMIC. OUT: HHMIC
   `ClientCmd` actions → translated to the right backend call.

### HVSM — com.olaelectric.vehiclestatemanager  (state orchestrator)

1. **Purpose.** Policy layer above HVDP: verifies passcodes, manages profiles /
   access tokens, tracks lock/park/SOM state, pushes priority telemetry to cloud
   (protobuf via CCM), drives CAN logging and the data aggregator, and performs
   SOM reboot and ECU/DID writes.
2. **AIDL.** Service `services/VehicleStateManagerService` (exported, action
   `com.olaelectric.VehicleStateManager.VehicleStateManagerService.BIND`) →
   **`IVsmService`**: `challengeUnlockByPasscode(UserProfileData,String,boolean):PasscodeStatus`,
   `updatePasscode`, `getProfileData`, `getVehicleDetails`, `getAccessToken`,
   `refreshToken`, `onScooterUnlock`, **`onScooterReboot`**, **`rebootSOM(String)`**,
   `isVehicleInParkMode`, `setRegenState`, `subscribeVehicleDataCalbacks`,
   `subscribeVehicleStateCallbacks`. Signature-protected ContentProvider
   `VSM_AUTHORITY` exposes `VehicleDetails`. Receivers: screen on/off,
   `action.quectel.adbdeviceconnected`, log-level.
   - **Consumes:** HVDP (`VehicleParserManager` → `IParserService` +
     `ICommanderService`), CCM, CanLogger (`ICanLoggerInterface`), DataAggregator.
3. **CAN.** Indirect only — delegates to HVDP. Frames selected state into
   `proto/MqttProto` (`PriorityEventPacketSt` with a `RawCanData` map) for upload.
4. **Network.** NewRelic; cloud via CCM as protobuf.
5. **Key classes.** `services/VehicleStateManagerImpl`,
   `controller/VehicleStateController` (unlock + reboot entry),
   `connectivityManagers/VehicleParserManager`, `utils/SCryptUtil`,
   `proto/MqttProto`, `providers/VSMContentProvider`.
6. **Timers.** `ScheduledExecutor`, WorkManager, IMU sensor listener.
   **Reboot authority:** `exec("reboot")` in `VehicleStateController.rebootSOM`
   (primitive A) and CAN `Scooter_Reboot` 0x0E (primitive B). Periodic "silent"
   SOM reboot 00:00–05:00 (`trySilentSomReboot`, default ~19 h threshold).
7. **Dependencies.** Binds HVDP, CCM, CanLogger, DataAggregator. Bound by HHMIS,
   HOHS, HPMS. Holds FORCE_STOP_PACKAGES, KILL_BACKGROUND_PROCESSES, etc.
8. **Data flow.** IN: HVDP telemetry + passcode entries → verify (scrypt),
   update state. OUT: unlock/command → HVDP → `0x6BC`; priority events →
   `MqttProto` → CCM → cloud; vehicle details → provider.

### VehicleDataService — com.olaelectric.vehicledataservice  (raw CAN shim)

1. **Purpose.** 40 KB generic SocketCAN transport. Pure AIDL shim over
   `libcan_jni.so` for raw-frame pub/sub; no decoding. The cleanest raw-frame
   surface for a custom app.
2. **AIDL.** Service `VehicleDataService` (exported) → **`IVehicleDataManager`**
   (descriptor `com.olaelectric.vehicledatamanager.IVehicleDataManager`):
   `sendCANFrame(CANFrame)`, `subcribeCANFrame/Array/Range(String, ids, ICANFrameListener)`,
   unsubscribes. Callback `ICANFrameListener.onCANFrameReceivedCallback(CANFrame)`.
   `CANFrame` = `{int canId, byte[] canData, int canPayloadLen, boolean isExtended, boolean isRtr}`.
   Valid IDs `0x1`–`0x7ff`.
3. **CAN.** READ+WRITE (generic, client-selected IDs) via `libcan_jni.so` —
   a separate socket/lib from HVDP's libJNIStubTest.
4. **Network.** None.
5. **Key classes.** `VehicleDataService`, `VehicleDataServiceBinder`,
   `CANFrameReceiverThread`, `CANFrameDeliverThread`, `CANFrameListenerMap`.
6. **Timers.** Two long-lived threads; no watchdog.
7. **Dependencies.** None; standalone transport.
8. **Data flow.** `vcan0 → recvcanframe → listener → client`; `client.sendCANFrame → sendcanframe → vcan0`.

---

## 5. Health, cloud, OTA, connectivity

### HOHS — com.olaelectric.olahealthservice  (watchdog)

1. **Purpose.** Health/watchdog service. Reboots the head unit if a watched
   process is missing, reports device health to cloud, maintains the vehicle
   manifest, and relays a few remote MQTT maintenance commands.
2. **AIDL.** Service `OlaHealthService` (exported, action
   `com.olaelectric.olaHealthservice.BIND`). Internal repos for diagnostic
   reports, app-storage clear, app stop, manifest write. Receiver
   `ConfigDataBroadcast` (`com.olaelectric.configUpdated`).
   - **Consumes:** HVSM (`IVsmService` — reboot trigger + state), HCCM
     (`ICcmInterface` — MQTT status + commands), HVDP (`IParserService` — SLEEP
     detection), HDA (`IDataAggregatorInterface`).
3. **CAN.** None directly. Reboot is effected via `IVsmService.onScooterReboot()`
   → HVSM emits CAN `Scooter_Reboot` (0x0E) on `0x6BC`.
4. **Network.** Own health REST to `https://kong-ola-apigateway-oem.olaelectric.com`
   (driven by `OHS_API_TIMER`). MQTT piggybacks on HCCM.
5. **Key classes.** `ConnectivityIssueHandlingTimer` (the watchdog),
   `utils/AppConstants` (`PROCESS_LIST`, deferred-reboot flag),
   `controller/VehicleStateManager`, `HSMqttConnectionWorker`.
6. **Timers & watchdogs (primary finding).**
   - `scheduleAtFixedRate(ConnectivityIssueHandlingTimer, 0, CCM_Timer_In_Minutes, MINUTES)`,
     default **`CCM_Timer_In_Minutes = 0xA` = 10 minutes** (overridable by pushed
     config `ccm_timer_duration`).
   - Each tick scans `getRunningAppProcesses()` for
     `PROCESS_LIST = ["com.olaelectric.cloudconnectivitymanager", "com.olaelectric.ota"]`.
     Reboots on the **first missing process**.
   - `rebootTheDevice()` is **state-gated**: reboot now if vehicle is `SLEEP`,
     else set a deferred flag that fires on the next transition into `SLEEP`.
   - Also `OHS_API_TIMER` (86400 s) and `log_File_Timer_Task` (21600 s / 6 h).
   - MQTT maintenance via `HSMqttConnectionWorker`: `CCM_REBOOT`/`DA_REBOOT` →
     app restart (not device reboot); `*_CLEAR_CACHE` → clear app data.
7. **Dependencies.** HVSM, HCCM, HVDP, HDA. **Critically depends on HCCM + HOTA
   being alive** — if either dies, HOHS reboots the head unit.
8. **Data flow.** tick → read processes → missing CCM or OTA → reboot (now if
   SLEEP else deferred) → `IVsmService.onScooterReboot` → CAN `0x6BC` `0x0E`.
   **This is the documented random-reboot cause after `pm disable com.olaelectric.ota`.**

### HCCM — com.olaelectric.cloudconnectivitymanager  (the cloud pipe)

1. **Purpose.** Owns the device's single MQTT connection (Eclipse Paho),
   authenticates/provisions via mTLS REST, publishes telemetry, receives remote
   commands/config/FOTA, and exposes all of it as `ICcmInterface`.
2. **AIDL.** Service `CloudConnectivityManager` (exported, action
   `com.olaelectric.cloudconnectivitymanager.BIND`) → **`ICcmInterface`**:
   `publishToMqtt(topic, byte[])`, `publishHighPriorityEventDataToMqtt`,
   `SubscribeCommandData/ConfigUpdate/FotaNotify/VehicleData(callback)`,
   `SendCommandStatusData`, `SendOtaStatusStData`, `getAccessToken/refreshToken/getAppToken`,
   `getProfileDetails`, `getTechPackDetails`, `sendVehicleStatsData`,
   `sendSOMAnalyticEvent`, `mqttConnectionStatus`. Also exports Paho
   `MqttService` and config/log receivers.
   - **Consumes:** HVDP (`ICommanderService`/`IParserService`) — how cloud data
     is sourced and how remote commands reach the vehicle layer.
3. **CAN.** None directly. Remote commands go out via HVDP's `ICommanderService`
   (`CommandFromApp`/`CommandFromHMI`) on `0x6BC`. The head unit never emits
   `0x6A1` (that is a TCU→VCU frame).
4. **Network (key finding).**
   - Gateways: `KONG_BASE_URL = https://kong-ola-apigateway-oem.olaelectric.com`;
     `KONG_MTLS_BASE_URL = https://mtls-apigw.olaelectric.com` (client-cert mTLS).
   - REST: `deviceauth/v2/wami`, `deviceauth/access/token/refresh`,
     `v3/oauth2/hmi/token`, `v1/hmi/profiles`, `v1/hmi/locations`,
     `v1/vehicle/oms/drivability`, `thor-stc/v1/vehicle/statistics`,
     `fota/v1/ota/trigger/vehicle`. Headers `X-ACCESS-TOKEN`, `X-REFRESH-TOKEN`.
   - **MQTT broker is provisioned dynamically, not hardcoded.** The device-auth
     API returns `MQTTInfoEntity{mqttHost, mqttPort, tenantId(=VIN/WAMI),
     tenantType, targetClientId}`. Paho `serverURI` = `ssl://<host>:<port>`
     (TLS, typically 8883; `tcp://` non-TLS fallback).
   - **Topics are provisioned and stored in a Room DB** (`MqttTopicData{topic,
     data[], serialNum}`) — no hardcoded topic tree.
5. **Key classes.** `AuthRepositoryImpl` (device auth + `initMqttConnection`),
   `MqttConnectionMaintainer`, `PublishTimerTask` + `OldDataPublisherTask`
   (batched publish + offline backlog), `MtlsDeviceAuthService`.
6. **Timers.** MQTT keep-alive + Paho auto-reconnect; `PublishTimerTask`;
   `OldDataPublisherTask` flushes DB-queued records on reconnect;
   `DBSizeCheckerTask`. No reboot timer (it is instead a HOHS-watched target).
7. **Dependencies.** Binds HVDP. Consumed by HOHS, HOTA, HDA, HMI, and the
   range/notification services. The single cloud pipe for the whole device.
8. **Data flow.** Provision → `MQTTInfoEntity` → Paho `ssl://host:port`,
   subscribe provisioned topics. **Uplink:** HVDP/HDA telemetry → batched →
   `publishToMqtt` (queued to Room when offline). **Downlink:** cloud → topic →
   `messageArrived` → `SubscribeCommandData/ConfigUpdate/FotaNotify` callbacks →
   HVDP (vehicle commands) / HOTA (FOTA) / HOHS (maintenance).

### HOTA — com.olaelectric.ota

1. **Purpose.** OTA/FOTA updater. Receives update notifications from cloud via
   HCCM, downloads payloads, installs head-unit APKs, stages vehicle-ECU/SOM
   firmware, runs install/rollback scripts, reboots, and verifies after boot.
2. **AIDL.** Service `OTAManagerService` (exported, action
   `...OTAManagerService.BIND`) → `IOTAManagerInterface` (+ `IOTACallbacks`).
   Receivers: `InstallationVerifier` (BOOT_COMPLETED post-install verify),
   `NetworkChangeReceiver` (resume downloads), `AppInstallationStatusReceiver`.
   Holds **REBOOT**, REQUEST_INSTALL_PACKAGES, ACCESS_SUPERUSER, INSTALL/DELETE_PACKAGES.
   - **Consumes:** HCCM (`SubscribeFotaNotifyData`, `checkSoftwareUpdate`,
     `SendOtaStatusStData`), HVSM (state + reboot coordination).
3. **CAN.** None directly. ECU firmware staged to `/data/ola/recovery/firmwares/`
   and applied by install scripts; actual CAN/UDS flashing is delegated outside
   this APK.
4. **Network.** No hardcoded host — the **signed download URL is pushed from
   cloud** via HCCM (`fotaTrigger.url`). Downloads use Tonyodev Fetch2.
5. **Key classes.** `controller/OTAController`, `controller/InstallationController`
   (`executeScript`, `%reboot` token, `Runtime.exec`/`sync -f`),
   `controller/RollbackController`, `controller/InstallationVerifier`.
6. **Timers.** Event-driven (cloud push + network change), not a poller.
   `ConfigUpdateController` uses AlarmManager. Reboot during install via
   `%reboot` script directive.
7. **Dependencies.** HCCM (triggers, URL, status, tokens), HVSM (state/reboot).
   **A HOHS-watched target — if HOTA is not running, HOHS reboots.**
8. **Data flow.** Cloud → HCCM MQTT FOTA-notify → HOTA downloads (Fetch2) →
   checksum → PackageInstaller (APKs) / staged firmware + script → reboot →
   `InstallationVerifier` confirms or `RollbackController` reverts → status to cloud.

### HSSS — com.olaelectric.connectivityservice  (system settings)

1. **Purpose.** Unified settings backend for Wi-Fi client management, Bluetooth
   audio + hands-free calling, cellular/LTE status, brightness, volume, and
   persistent system data. Not a SoftAP/tethering or APN manager.
2. **AIDL.** Service `SystemSettings` (exported, action
   `com.olaelectric.settings.SystemSettings`) → **`ISystemSettings`** returning
   sub-binders: `getWifiSettings/getBluetoothSettings/getLteSettings/
   getBrightnessSettings/getVolumeSettings/getPersistentSystemData`.
   `IWifiSettings` (scan/connect/forget/on-off), `IBluetoothSettings`
   (A2DP + full HFP: dial/accept/reject, bonded devices, contacts).
   Also `BTNotificationService` (notification listener).
   - **Consumes:** no Ola service binds observed; uses Android framework
     `WifiManager`, `ConnectivityManager`, `TelephonyManager`,
     `BluetoothHeadsetClient`.
3. **CAN.** None.
4. **Network.** Wi-Fi client only; LTE is **status monitoring only** (operator,
   signal, IMEI, subscription). **No SoftAP/hotspot/tethering and no APN
   editing** — the scooter's own 4G/APN is handled elsewhere (ModemConfigApp).
5. **Key classes.** `SystemSettingsImpl`, `wifi/*`, `bluetooth/*` +
   `contact/ContactManager`, `telephony/TelephonyInfoManager`, `lte/LteConnectivityImpl`.
6. **Timers.** None. Event-driven via framework callbacks; HFP call timers only.
7. **Dependencies.** Effectively standalone. Not in HOHS `PROCESS_LIST`.
8. **Data flow.** HMI binds `ISystemSettings` → sub-binder → proxied to Android
   framework managers; state pushed back via callbacks.

---

## 6. Range, AI, and telemetry aggregation

None of these open `vcan0`; they consume decoded signals via HVDP's
`vehicleinterface` AIDL, and all cloud traffic is delegated to HCCM.

### HDA — com.olaelectric.dataaggregator  (telemetry collector)

1. **Purpose.** The central on-device telemetry collector. Subscribes to parsed
   signals, batches them into protobuf packets per subsystem, persists a
   high-frequency ring buffer to disk, and hands packets to HCCM for MQTT
   upload. Also does on-demand logcat/system-log collection.
2. **AIDL.** Service `services/DataAggregatorService` (exported, action
   `com.olaelectric.DataAggregatorService.BIND`) → **`IDataAggregatorInterface`**:
   `getLocationData():GpsDataModel`, `startDefaultLogCollection(char, IDACallbackCb)`,
   `startOnDemandLogCollection(char, long, IDACallbackCb)`, stop variants.
   Callback `IDACallbackCb` (log ack/complete/fail). Exported log-level receivers.
   - **Consumes:** HCCM (`ICcmInterface` — push packets); reads HVSM via provider
     `content://...vehiclestatemanager.VSM_AUTHORITY/VehicleDetails`; embeds its
     own `dataparserengine` (DBC JSON decoder).
3. **CAN.** No direct `vcan0`. Embedded `dataparserengine` decodes frames from a
   DBC-style config; schema carries raw CAN as `map<uint32,uint64> raw_can_data`.
   Decoded set: `Pack_SOC_00`, `Battery_Current`, `Battery_Pack_Effective_Temp`,
   `Total_Regen_Amhr`, `Vehicle_Odo`, `Remaining_Range`,
   `Vehicle_Range_ECO/Normal/Sport/Hyper`, `Vehicle_Mode_Level_1..4`,
   `Charger_Mode`, `Som_Status`, `Side_Stand/Trunk/ESCL_Status`, IMU (HF).
4. **Network.** No direct sockets — upload via HCCM. HDA builds the **topic
   names** (`BMS/BCM/MCU/SOM/HPA/LPA/CommandStatus/Version PacketTopicName`),
   configured in `/data/ola/config/som_service_config.json`. Payloads protobuf.
5. **Key classes.** `services/DataAggregatorServiceImpl`,
   `managers/CloudConnectivityManager`, `observers/EventChangeListener`,
   `publishers/*` (Bms/Bcm/Mcu/Main/VehicleStats/Hpe/Lpe/Version/...),
   `dataparserengine`, `data.model.HFProtoPersistence`.
6. **Timers.** `PublisherTimerTask` + `HFPublisherTimerTask` (fixed-rate),
   `TowTheftTimerTask`. Send intervals are per-state (On/Off/Charging), config-driven.
7. **Dependencies.** HCCM (upload), HVSM (vehicle details provider), embedded engine.
8. **Data flow.** Signals/raw CAN → `dataparserengine` → per-subsystem protobuf →
   buffered (HF ring buffer at `/data/ola/hf/*.proto`; **flat protobuf files, not
   SQLite**) → `*Publisher` timers → HCCM → MQTT topics. Logs → `/data/ola/sys_logs/`.

### HVRS — com.olaelectric.vehiclerangeservice  (classic range)

1. **Purpose.** Primary range calculator + trip/analytics engine. Computes range
   per mode from a small TensorFlow Lite model plus trip bookkeeping.
2. **AIDL.** Service `VehicleRangeService` (exported, action
   `...vehiclerangeservice.BIND`, guarded by `...PERMISSION`) →
   **`IRangeInterface`**: `addCallback(IRangeCallback)`,
   `subscribeDataAnalyticsInfo(IDataAnalyticsCallbacks)`, `resetTripoMeterA/B`.
   `IRangeCallback.onRangeChanged(int)` is the range value to the HMI.
   `IDataAnalyticsCallbacks` carries trip/day/efficiency/regen/top-speed.
   - **Consumes:** HVDP (battery/motor/display/vehicle/mode), HCCM, HPMS (profile).
3. **CAN.** Via HVDP. Features: `batterySoc` (0x120/0x352), `speed` (0x352),
   `motorTorque` (0x313), `odometer` (0x356), per-mode range (0x6F4).
4. **Network.** Analytics via HCCM. (`/mobile/v3/data`, `/mobile/v4/connect` are
   bundled New Relic strings, not Ola endpoints.)
5. **Key classes.** `domain/dataPrediction/DataService`,
   `domain/dataPrediction/RangePredictionService` (TFLite),
   `domain/dataPrediction/RangePredicted`, asset model `assets/mode21Aug.tflite` (~4.5 KB).
6. **Timers.** Trip/daily-stat accumulators; daily reset on date change; reset-on-OTA.
7. **Dependencies.** HVDP, HCCM, HPMS.
8. **Data flow.** HVDP callbacks → `DataService` caches signals →
   `RangePredictionService` TFLite → per-mode range → `onRangeChanged(int)` to HMI;
   analytics → `IDataAnalyticsCallbacks` + cloud via HCCM.

### HAIRS — com.olaelectric.airangeservice  (AI range)

1. **Purpose.** Newer "AI range". Learns per-mode efficiency from a rolling
   history of (odometer-delta vs SoC/charge-consumed) buckets in a Room DB and
   predicts range statistically. Despite a bundled TFLite lib, `RangePredictor2`
   is a statistical estimator, not a neural net at runtime.
2. **AIDL.** Service `services/AIRangeService` (exported, action
   `...AIRangeService.BIND`) → `airangeinterface.IRangeInterface.addCallback(IRangeCallback)`;
   `IRangeCallback` delivers predicted range (notably to HAIP).
   - **Consumes:** HVDP (battery/display/motor/vehicle/mode), HCCM.
3. **CAN.** Via HVDP. Logs `Odometer(_in_meters)` (0x356), `Pack_SOC_00` (0x120),
   `Discharge_AmpHr_00`, `Total_Regenerative`, `vehicle_mode` (0x6F4/display).
4. **Network.** Config/upload via HCCM bind only.
5. **Key classes.** `services/RangePredictor2`, `db/VehicleDatabase` (Room) +
   `db/DataDto1` entity (`data_dto` table), `connectivityManagers/VehicleParserManager`.
6. **Timers.** Event-driven off odometer deltas.
7. **Dependencies.** HVDP, HCCM. Consumed by HAIP.
8. **Data flow.** HVDP callbacks → per-mode rows in Room `data_dto` →
   `RangePredictor2` bucketed mean efficiency → `predictedRange` +
   `Eco/Normal/Sport/HyperRange` → `IRangeCallback` → HAIP → HMI.

### HAIP — com.olaelectric.aiproxy  (AI facade)

1. **Purpose.** Thin IPC facade in front of the on-device AI services. **No
   remote AI backend** — it binds HAIRS and the auto-turn-off service and
   re-exposes both behind one AIDL so the HMI has a single consumer.
2. **AIDL.** Service `AIProxyService` (exported, action
   `com.olaelectric.aiproxy.RangeService.BIND`) →
   `rangepredictionlibrary.IAIProxyAIDL`: `subscribeRangePredict(AIProxyCB)`,
   `autoIndicatorToggle(boolean)`. `AIProxyCB.notifyDataModel(AIProxyModel)`.
   - **Consumes:** HAIRS, HAIATO, HCCM (config), HVDP.
3. **CAN.** None directly.
4. **Network.** None direct; config via HCCM.
5. **Key classes.** `AIProxyService`, `repositories/AIRangeService`,
   `repositories/AutoTurnOffIndicator`, `repositories/VDPServiceParser`.
6. **Timers.** None (event-forwarding facade).
7. **Dependencies.** HAIRS, HAIATO, HCCM, HVDP. Bound by HHMIC (as
   `rangepredictionlibrary.IAIProxyAIDL`).
8. **Data flow.** HAIRS range + auto-indicator state → `AIProxyModel` →
   `AIProxyCB.notifyDataModel` → HMI; HMI `autoIndicatorToggle` → forwarded to HAIATO.

---

## 7. Profile, navigation, convoy, web, notifications

### HPMS — com.olaelectric.profilemanagerservice  (passcode authority)

1. **Purpose.** Rider profile manager and passcode authority. Stores profiles
   (primary + secondary/multi-rider), verifies the unlock passcode with scrypt,
   and on success drives unlock via HVDP's commander. Owns saved locations,
   geo/time-fence restrictions, ride stats, hypercharge, Ola Maps token.
2. **AIDL.** Service `services/ProfileManagerService` (exported, action
   `com.olaelectric.profilemanagerservice.BIND`) → **`IProfileManagerService`**:
   `challengeUnlockByPasscode(String, boolean):PasscodeStatus` (verify + unlock),
   `checkPasscodeMatchWithAllUsers`, `updatePasscode`, `getPasscodeRemainingAttempts`,
   `getProfileData`, `selectedUser`, location + geo/time-fence + maps/hypercharge
   methods. Exported providers `ProfileManagerContentProvider` and
   `UserContentProvider`.
   - **Consumes:** HVDP `ICommanderService` (binds
     `Intent("com.olaelectric.vehicleparser.VehicleParserService")`), HVSM
     (`IVsmService`), HCCM.
3. **CAN.** Indirect. The verified-passcode call `unlockedByPasscode(true)` makes
   HVDP emit CAN `0x6BC` byte0 `0x19` (PASSCODE_AUTH) 30× at 100 ms.
4. **Network.** okhttp/Retrofit for profile/location/hypercharge sync, but
   transport delegated to HCCM. Holds per-profile `olaMapsToken` for HOM.
5. **Key classes.** `services/ProfileManagerServiceImpl` (`checkPasscodeStatus`),
   `controller/ProfileController` (`sendUnlockByPasscode`), `data/utils/SCryptUtil`,
   `data/repositories/interfacesImpl/VehicleParserManager`, Room entity `UserProfile`.
6. **Timers.** Lockout: `remainingAttempts` default **5**; `AlarmReceiver` +
   `ScheduleTimerUseCase` reset attempts. Geo/time-fence + drive-mode-restriction
   use-cases enforce secondary-rider windows. WorkManager profile sync.
7. **Dependencies.** HVDP (unlock), HVSM (state), HCCM (sync). Supplies HOM
   (maps token), HCS (VIN via provider), HNFS (profile).
8. **Passcode storage & hashing (confirmed).**
   - **Storage:** Android **Room DB** — entity `UserProfile`, column `passcode`
     holds the full scrypt hash string. DBs `ProfileManagerDatabase` /
     `ProfileMove4Database`. One row per rider (`profileType` primary/secondary).
     Not SharedPreferences, not Keystore.
   - **Hash:** lambdaworks/Tarsnap `$s0$<params>$<b64 salt>$<b64 dk>` over the
     native `android.security.Scrypt`. Params **N=1024 (0x400), r=8, p=1,
     salt=16 bytes (SHA1PRNG), dkLen=32**; `params` field `0xA0801`. Factory
     default passcode hashes `"000000"`.
   - **Verify path:**
     ```
     IProfileManagerService.challengeUnlockByPasscode(passcode, bool)   [AIDL, exported]
       → ProfileManagerServiceImpl.checkPasscodeStatus()
           → SCryptUtil.check(passcode, UserProfile.passcode)           // scrypt vs Room hash
       → on success IProfileController.sendUnlockByPasscode()
           → VehicleParserManager → ICommanderService.unlockedByPasscode(true)  [AIDL → HVDP]
       → (inside HVDP) MasterCommander → 30× cansend 6BC#1900000000000000
       on failure → decrementRemainingAttempts()
     ```
     HPMS has its **own** path straight to HVDP, distinct from the
     HHMIC→HVSM path in `research/unlock-mechanism.md`. Both converge on HVDP's
     `ICommanderService.unlockedByPasscode`.

### HOM — com.olaelectric.olaevnavigation

1. **Purpose.** Turn-by-turn navigation app + bound service, built on the Ola
   Maps SDK (`com.ola.maps.*`, a Mapbox-GL fork). Runs as system UID.
2. **AIDL.** Service `com.olaelectric.navigation.service.NavigationService`
   (exported, action `com.olaelectric.NavigationService`). Activities exported.
   - **Consumes:** HCCM (`ICcmInterface` tokens/telemetry), HPMS
     (`olaMapsToken` via `com.olaelectric.profile.READ_PERMISSION`).
3. **CAN.** None (display-only).
4. **Network.** `https://maps.olaelectric.com` (tiles/routing),
   `https://kong-ola-apigateway-oem.olaelectric.com` (auth), `https://api.mapbox.com`
   (underlying SDK), NewRelic. No WebView, no MQTT.
5. **Key classes.** `NavigationApplication`, `navigation.service.NavigationService`,
   `com.ola.maps.navigation.v5.navigation.NavigationService`, `MainActivity`.
6. **Timers.** Foreground service + location polling; token refresh via HPMS/CCM.
7. **Dependencies.** HCCM, HPMS.
8. **Data flow.** `olaMapsToken` (HPMS) + GPS → Ola Maps SDK → routes/tiles from
   `maps.olaelectric.com` → guidance rendered + shared to HMI via the bound service.

### HCS — com.olaelectric.convoyservice  (convoy / concert mode)

1. **Purpose.** Multi-scooter "Concert mode" — one host streams songs to client
   scooters over the local Wi-Fi LAN (no cloud). System UID.
2. **AIDL.** Service `ConvoyService` (exported, action `...ConvoyService.ACTION_START`)
   → `convoyinterface.ConvoyInterface`: `startConcert/endConcert/exitConcert/
   connectToHost(DeviceInfoModel)`, `selectedSongListFromHost(List)`,
   `subscribeConvoyInterface(ConvoyServiceCB)`.
   - **Consumes:** HPMS VIN via `content://...profilemanagerservice.contentprovider/vehicle`.
3. **CAN.** None.
4. **Network (sync mechanism).** Local Wi-Fi P2P — **not MQTT/cloud**:
   - Discovery: Android NSD (mDNS), service type `_http._tcp.`, name prefix
     `NSD_CONCERT_MODE_`, TXT attrs host/scooterName/ipAddress/registrationNumber.
   - Transport: raw TCP — host `ServerSocket`, client sockets. Ports
     `NSD_PORT=4444`, `STATIC_PORT=9898`.
   - Payload: `FILE_DATA` streams MP3s (mp3agic) + `JSON_DATA` control, framed by
     protobuf `ConcertModeProto`. No dedicated light-sync protocol found.
5. **Key classes.** `ConvoyServiceImpl`/`ConvoyInterfaceImpl`, `nsdservice/NsdHelper`,
   `server/SocketServerManager`, `SocketClientManager`, `proto/ConcertModeProto`.
6. **Timers.** `FileSendingTimer` / `ClientFileSendingStatus` track per-client
   transfer progress; socket keep-alive/reconnect loops.
7. **Dependencies.** HPMS (VIN). Otherwise self-contained over the Wi-Fi radio.
8. **Data flow.** `startConcert` → host registers NSD + opens `ServerSocket` →
   clients discover + `connectToHost` → host streams MP3s + JSON control →
   clients play in sync; `ConvoyServiceCB` reports state to HMI.

### HDUX — com.olaelectric.duxwebview

1. **Purpose.** Thin WebView host for Ola web pages (chat support, vacation-mode
   swipeable flow) with a native bridge. `debuggable=true`.
2. **Components.** `MainActivity` (exported LAUNCHER, hosts WebView), service
   `DuxService` (exported, plain bound/started, no custom AIDL stub).
3. **CAN.** None.
4. **Network + JS bridge.**
   - Loads `https://ola-ev-ui.olaelectric.com/api/cAppLogin?redirectUrl=vacationmode-swipeable&postCallTo=feature-dux`.
   - **JS bridge** (`addJavascriptInterface`) named **`OlaChatSupportJSNativeBridge`**
     (class `utils/WebViewInterface`), single method
     `webToNative(String actionName, String callBackMethod, String jsonObject)`
     dispatched on `Dispatchers.IO`. This is the web→native attack surface; the
     loaded origin is `ola-ev-ui.olaelectric.com`.
5. **Key classes.** `MainActivity`, `utils/WebViewInterface`, `DuxService`,
   `repo/network/IDuxWebsiteLoadService` (Retrofit).
6. **Timers.** None notable; `MainActivity` is `noHistory`.
7. **Dependencies.** HPMS (profile context for the web session). Ola cloud web.
8. **Data flow.** `MainActivity` builds the `cAppLogin` URL → WebView loads it →
   page JS calls `OlaChatSupportJSNativeBridge.webToNative(...)` → handled on IO
   coroutine → result posted back to the page.

### HNFS — com.olaelectric.notificationforegroundservice

1. **Purpose.** Foreground notification service: receives cloud push, persists,
   raises Android notifications, and serves the list to the HMI.
2. **AIDL.** Service `service/NotificationService` (exported, action
   `com.olaelectric.notificationmanagerservice.BIND`) → `nfsinterface.INotificationService`:
   `changeReadState(String)`, `subscribeNotificationCallbacks(String, INotificationCallbacks)`.
   - **Consumes:** HCCM (`ICcmInterface` — notification source over MQTT), HPMS
     (`IProfileManagerService` — profile context).
3. **CAN.** None.
4. **Network.** No direct sockets — notifications arrive via HCCM MQTT as
   `CloudNewNotification`. Requests `POST_NOTIFICATIONS`.
5. **Key classes.** `service/NotificationService`, `NotificationManager` (app),
   Room entity `Notifications`, `RefreshNotificationsUseCase`.
6. **Timers.** Foreground service keeps the process alive; store reconciliation.
7. **Dependencies.** HCCM, HPMS. Serves the HMI.
8. **Data flow.** HCCM MQTT → `CloudNewNotification` via `ICcmInterface` → Room
   `notifications` table → Android notification + `INotificationCallbacks` to HMI →
   HMI `changeReadState()` on read.

---

## 8. UI and engine sound

### HHMIC — com.olaelectric.hmiclient  (the Kanzi dashboard)

1. **Purpose.** Renders the entire scooter UI as a single compiled Kanzi 3D
   scene and relays user input back as commands. A pure Binder client — it
   decodes nothing from the bus. v4.6.14, `android.uid.system`, arm64-v8a, 3 dex.
   (Kanzi scene internals in `docs/hmi-apk-analysis.md`.)
2. **AIDL.** Exposes nothing of substance. **Primary consumed contract (the
   HHMIS→HHMIC channel):** binds the explicit component
   `com.android.hmiserverapp/.VehicleParserService` (constant
   `OLA_HMI_SERVER_CLASSNAME`) in `HMIServerConnectionSingle`, gets
   `IClientServiceInterface` via `$Stub.asInterface`, registers
   `IClientServiceInterfaceCallback`. Inbound updates keyed by `ServerCmd`;
   outbound commands keyed by `ClientCmd` (`onIntegerHMICmd` 34×, `onVoidHMICmd`
   19×, etc.). **Also binds ~11 other services directly:** HOTA (`IOTAInterface`),
   HCCM (`ICcmInterface`), HPMS (`IProfileManagerService`), HSSS
   (`ISystemSettings` + BT/Wi-Fi/telephony/volume/brightness sub-binders),
   HOM (`INavigationService`), HAIP (`IAIProxyAIDL`), HNFS (`INotificationService`),
   HCS (`ConvoyInterface`), HDUX (`IDuxService`), media session.
3. **CAN.** None. All bus data arrives pre-decoded from HHMIS as `ServerCmd` callbacks.
4. **Network.** NewRelic only; cloud via the CCM binding. Bundled ExoPlayer for
   BT/media. Perms include `INJECT_EVENTS`, `MEDIA_CONTENT_CONTROL`, contacts/SMS.
5. **Key classes.** `HMIServerConnectionSingle` (binds HHMIS, owns rebind
   watchdog), `IClientServiceInterfaceCallbackBuilder` (routes `ServerCmd` into
   Kanzi), `kanzi/KanziUtils` (the JNI bridge), `ModuleManager` (per-domain
   registry), `WatchDogMonitor`/`ConnectionRecoveryInfoManager`.
6. **Timers.** `WatchDogMonitor` + `HMIServerConnectionSingle` rebind logic
   (`EVT_*_REBIND_START/KILL`) monitors the HHMIS link and re-binds on death.
7. **Dependencies.** HHMIS (primary), plus the ~11 services above. HVS reached
   indirectly (sound customizations go via HHMIS).
8. **Data flow (CAN → pixels).**
   ```
   vcan0 → HHMIS VehicleParserService decodes → IClientServiceInterfaceCallback.on*Update(ServerCmd,value)  [Binder]
     → HHMIC IClientServiceInterfaceCallbackBuilder: switch on ServerCmd
     → KanziUtils.set{Bool,Int,Float,String,Image}DataObjectValue(context,name,value)  [JNI → libkanzi.so]
     → libXML_data_source.so (bound via the *DataContext.xml) writes the Kanzi scene property → render
   ```
   Only `System.loadLibrary("kanzi")` and `("dltolaservice")` load from Java; all
   Kanzi plugin `.so`s load internally via libkanzi. User input flows back:
   Kanzi hit-test → `IKanziMessageListener` → module managers →
   `onIntegerHMICmd`/`onVoidHMICmd`/… on `IClientServiceInterface` → HHMIS → CAN.

### HVS — com.olaelectric.enginesound

1. **Purpose.** Generates the synthetic motor/engine sound (Bolt/Vintage/Eclipse
   moods, chimes) in real time from live vehicle data. Unlike HHMIC, **HVS reads
   CAN directly**; all DSP is native (`libnative-lib.so`).
2. **AIDL.** Exposes `EngineSoundService` (exported, action
   `com.olaelectric.enginesound.EngineSoundService`) → `IEngineSoundAidlInterface`:
   `onMoodChanged(int)`, `onSoundToggleChanged(int)`, `onAudioDuckingLevelChanged(float)`,
   `on{Vintage,Bolt,Eclipse}SoundCustomized(...)`, `onMoodsCustomScreenLaunched(int)`
   (parcelables from `com.android.hmiserverapp.parcelables.*` → caller is HHMIS).
   Receiver `MoodReceiver` for `ACTION_MOOD_CHANGE`.
   - **Consumes:** HCCM (`ICcmInterface`) for analytics only.
3. **CAN (read directly from `vcan0`).** `utils/CanSocket` (JNI SocketCAN via
   **libJNIStubTest.so**) on `vcan0`; a blocking "CANThread" switches on raw ID:
   `0x313` RPM/speed, `0x143` speed, `0x113` throttle+cruise, `0x223` torque,
   `0x15b` drive mode + front/rear brakes, `0x689` VIN. Read-only (no `0x6BC`).
4. **Network.** None direct; analytics forwarded to HCCM. NewRelic.
5. **Key classes.** `EngineSoundService`, `utils/CanSocket`,
   `IEngineSoundAidlInterface`, `CCMInterface`, `MoodReceiver`.
6. **Timers.** No fixed-rate timer — a blocking CAN read loop on a dedicated
   thread; native audio updates per frame. Foreground service keeps it alive.
7. **Dependencies.** HHMIS (mood/customization side channel), HCCM (analytics),
   direct `vcan0`.
8. **Data flow.** `vcan0 → CanSocket.recv (CANThread) → byte unpack → native
   GetValue*/Get_Value_S → DSP synthesises mood sound → AudioFlinger`. Mood/
   customization arrives separately: HHMIC UI → HHMIS → HVS `IEngineSoundAidlInterface`.
   **RPM comes straight off CAN `0x313`, not from HHMIS.**

---

## 9. Auto-off, brake, logger, factory, UDS, and the root gRPC binary

### CANLOGGER — com.olaelectric.canlogger

1. **Purpose.** Captures the live CAN bus to disk as compressed protobuf and
   ships batches to cloud over MQTT; remotely start/stop/level-controllable. The
   direct stock analog of OlaMate's logger.
2. **AIDL.** Exposes `CanLoggerService` (exported, action
   `com.olaelectric.canlogger.CANLoggerService.BIND`) →
   `canloggerservice.ICanLoggerInterface`. Consumes HCCM (`ICcmInterface`
   `onCommandReceived` for cloud start/stop/level) and the shared
   `vehicleparser.utils.CanUtils`. Autostarts on `BOOT_COMPLETED`.
3. **CAN capture.** SocketCAN, **not candump**. `CanUtils.revCan0Data()` →
   `CanSocket$CanFrame` from the `can0`/`vcan0` socket (native libJNIStubTest.so,
   libdltolaservice.so, libdlt.so). Captures **all IDs, no filter**.
4. **Network.** No direct host — upload via HCCM MQTT.
5. **Key classes.** `controller/CanLoggerManager`, `utils/CanSocket`,
   `services/CanLoggerService`, `controller/AdbLogcatManager`,
   `domain/mqtt/javaentities/*` (protobuf).
6. **Format / path / rotation.**
   - Format: protobuf `VcanPacketList { uint64 timestamp; repeated VCANPackets
     vcan_packet_list }` (each packet = canId + CanData), schema v1.0, batched,
     serialized, written into a `.zip`.
   - Path: `/data/ola/sys_logs/zip/` (filenames `CL_log_`/`CAN_` + VIN + SOM ID +
     PID); staging `/data/ola/sys_logs/{,da/}`, `/data/ola/hf/`.
   - Rotation: `deleteOldestZipFile()`.
   - Config: `/data/ola/config/som_platform_config.json`, `som_service_config.json`.
7. **Timers.** Coroutine `canLoggerJob` continuous read/batch/flush; flush gated by packet size.
8. **Data flow.** `vcan0 → CanUtils.revCan0Data() → CanFrame → constructVcanPacket
   → VcanPacketList protobuf → writeTextToZip → /data/ola/sys_logs/zip/*.zip → HCCM
   MQTT → cloud`. Cloud → `ccminterface.onCommandReceived` → start/stop/level.

### HAIATO — com.olaelectric.autoturnoff

1. **Purpose.** AI automatic **turn-indicator (blinker) cancellation** — not
   device power-off. IMU → per-side TFLite models → switch the indicator off
   when a turn completes.
2. **AIDL.** Exposes `AIAutoTurnOffService` (exported, action `...AIAutoTurnOffService.BIND`),
   `android.uid.system`. Consumes HVDP (`IVehicleService` →
   `IParserService.subscribeIMUInfo/subscribeVehicleInfo/subscribeMotorInfo/subscribeDisplayInfo`,
   `ICommanderService.sendCommandToScooter`).
3. **CAN.** No direct IDs. Input = `IMUData` (accel/gyro) + indicator state from
   HVDP; output = an indicator-off command through `ICommanderService` (HVDP does
   the CAN write).
4. **Network.** None.
5. **Key classes.** `services/AIAutoTurnOffImpl`, `model/TFliteModelLeft` +
   `TFliteModelRight`, `connectivity/VehicleServiceManager`.
6. **Sensors/models.** IMU accel+gyro scaled per side (`azScale*`, `gxScale*`);
   two TFLite models `modelL_V2.tflite` + right counterpart via `assetManager.openFd`;
   coroutine-delay debounce. Numeric thresholds live inside the .tflite weights.
7. **Dependencies.** HVDP. No cloud.
8. **Data flow.** HVDP IMU + indicator → per-side scaling → TFLite inference →
   turn-complete → `ICommanderService.sendCommandToScooter(indicator off)` → HVDP → CAN → BCM.

### HAIBS — com.olaelectric.breakswitchmodel

1. **Purpose.** Brake-switch **failure detection**. Monitors front/rear brake
   signals, detects stuck/failed switches (debounced), persists state, reports via
   callback and cloud.
2. **AIDL.** Exposes `BreakswitchService` (exported, action `...BreakswitchModelService.BIND`),
   `breakswitchinterface` with `BreakswitchCallback.onBreakStatusChange()`. Consumes
   HVDP (`IParserService` vehicle/motor/battery/display/modes; can `sendCommandToScooter`),
   HCCM (reporting), HPMS (`com.olaelectric.profile.READ_PERMISSION`).
3. **CAN.** No direct IDs — brake state arrives decoded from HVDP. Tracks
   `frontBrake/rearBrake` applied, derives `frontFailure/rearFailure`.
4. **Network.** Via HCCM.
5. **Key classes.** `services/BreakswitchServiceImpl`, `services/FailureDetection`,
   `services/DataService`, Room (`db/VehicleDatabase`, `BreakswitchData`).
6. **Timers.** `FailureDetection` debounces a sustained failure via coroutine delay.
7. **Dependencies.** HVDP, HCCM, HPMS, Room.
8. **Data flow.** HVDP brake signals → `DataService` → `FailureDetection`
   (debounced) → Room `BreakswitchData` → `onBreakStatusChange()` + cloud via HCCM.

### HMFG — com.ola.mfgapp  (factory / manufacturing)

1. **Purpose.** Technician/factory app. The primary **gRPC client of
   diagnostics_server** — drives device tests, SW flashing, VIN provisioning,
   scooter-mode change, DTC read, and the technician hotspot + QR onboarding.
2. **Components.** `MainActivity` (exported LAUNCHER); bound services
   `com.ola.grpc.GrpcService` (not exported) and `SWUpdateService` (exported).
   Many test activities (DTC, GPS, LCD, Speaker, MIC, MCU, Vin, Provision, SWUpdate).
   `android.uid.system`.
3. **CAN.** Indirect — CAN read/write, DTC read, per-ECU tests all via
   diagnostics_server gRPC (`ReadCanFrame`/`WriteCanFrame`/`RemoteRunTestCmd`).
4. **Network.** gRPC to **`127.0.0.1:50005`** (localhost, plaintext
   `io.grpc.ManagedChannel`) — the local diagnostics_server (7900+ `wifican`
   refs). Brings up a Wi-Fi SoftAP **hotspot** (`turnOnHotspot`, `hotspotSsid`)
   so an external tester laptop can reach it.
5. **Key classes.** `com/ola/grpc/GrpcService`, `SWUpdateService`, `MainActivity`,
   `presentation/DTCActivity` + `DTCReadActivity`, `ProvisionActivity`, `SWUpdateActivity`.
6. **Privileged ops (via gRPC).** SW flashing (`SwUpdateFileTransfer` stream +
   `SwUpdateTriggerUpgrade`), `ProvisionVin`, `ScooterModeChange`, `RemoteRunTestCmd`
   (LCD/GPS/BT/BLE/WiFi/SPKR/MIC/MCU-cal/eSIM/VIN/PROV). Locally `WRITE_SECURE_SETTINGS`,
   hotspot control, QR, reads SOM ID from `/data/ola/config/som_platform_config.json`.
7. **Timers.** `SWUpdateService$startSWUpdateStatus` polls update status.
8. **Data flow.** Technician UI → `GrpcService`/`SWUpdateService` →
   `localhost:50005 WifiCanRpc` → diagnostics_server (root) → ECUs over CAN /
   filesystem / Wi-Fi. The hotspot lets an external laptop drive the same flow.

### UdsTestApp — com.olaelectric.udstestapp  (ISO 14229 diagnostics)

1. **Purpose.** Thin test UI over the native UDS HAL. Runs ECU diagnostics:
   reset, logging control, MCU calibration (with security access), config read/write.
2. **Interfaces.** `MainActivity` (exported LAUNCHER). Does **not** use AOSP AIDL
   or SocketCAN — binds the **HIDL** service `ola.hardware.uds@1.0::IUdsService`
   with 5 notifier callbacks (`IConfigStatus/IConfigReadResponse/IFlashStatus/
   IMCUCalStatus/ILogStatusNotifier`).
3. **CAN / UDS.** No literal `0x7xx` IDs in the APK — per-ECU diagnostic
   request/response CAN IDs live in the native HAL config (`.ecu_type/.can_rx/
   .can_tx`). ECUs: `ECU_BMS, ECU_BCM, ECU_BLE, ECU_MCU, ECU_HU, ECU_ESCL1_4,
   ECU_ESCL1_6, ECU_HBC_L, ECU_HBC_R`. UDS services (inferred from HAL ops):
   ECUReset 0x11, SecurityAccess 0x27 (MCU cal), RoutineControl 0x31 (logging),
   ReadDataByIdentifier 0x22 / WriteDataByIdentifier 0x2E (config).
4. **Network.** None.
5. **Key classes.** `MainActivity`, `ola/hardware/uds/V1_0/IUdsService`,
   `UDSCS_ReadRequest_t`, `UDSCS_FlashState_t`, `ECU_Reset_Type_t`.
6. **Timers.** None; async via HIDL notifier callbacks.
7. **Dependencies.** The `ola.hardware.uds@1.0` HIDL service (native UDS stack).
8. **Data flow.** UI → `IUdsService` HIDL → native stack builds ISO-14229 request
   → CAN `.can_tx` to target ECU → reply on `.can_rx` → HIDL notifier → UI.

### diagnostics_server — /vendor/bin (Go)  (the root gRPC service)

1. **Purpose.** Root (uid 0) gRPC service `wifican.WifiCanRpc` on **TCP 50005**.
   Bridges clients to the CAN bus, a root shell, SW update, provisioning/certs,
   and factory test commands. Build path `/data/workspace/OLA_69/APPS/wifican`.
   On Gen 1 the IPv4 port is reachable from the LAN with **no authentication** —
   this is the root entry point this whole repo is built on.
2. **Interfaces.** gRPC `WifiCanRpc`, 42 RPCs (grouped below); no reflection.
   Listens on `:50005`. Local clients (HMFG) bind over localhost.
3. **CAN.** Direct SocketCAN on `vcan0` (streaming `ReadCanStream`/`WriteCanStream`/
   `CanDumpStream`). Note: `WriteCanFrame` is the ignored path — the active
   command path is `ExecuteADBCommand` + `cansend` (see memory + `research/`).
4. **Network (outbound).** `https://device-auth-provisioner1.olaplant.com/.../cert/provision`;
   `https://outpost.mapmyindia.com/.../oauth/token` and `https://anchor.mapmyindia.com/.../devices`
   (nav registration). Inbound: gRPC 50005.
5. **Key files/paths.** Config `/data/ola/dgs/diagnostics_server_config.yml`; log
   `/data/ola/dgs/dgs.log`; `/data/ola/v-manifest.json`, `/data/ola/sw_update_cache`,
   `/data/ola/config/som_ecu_config.json`, `/data/ola/secure/`;
   `/system/bin/read-ta100-serial-id` (secure element).
6. **Timers.** gRPC keepalive; SW-update state machine
   (UPLOAD→INSTALLING_{SYSTEM,BCM,BMS,BLE,MCU,AOSP}→REBOOTING→SUCCESS/FAILED).
7. **Dependencies.** Kernel SocketCAN; `/data/ola` filesystem; mapmyindia +
   olaplant provisioning hosts; `read-ta100-serial-id`. HMFG is its main client.
8. **gRPC RPC groups (42 RPCs from `proto/wifican.proto`).**
   - **Root shell / files:** `ExecuteADBCommand` (exec as root, no shell),
     `pushFile`, `ClearStorage`.
   - **CAN:** `Init`, `Deinit`, `ReadCanFrame`, `WriteCanFrame`, `ReadCanStream`,
     `WriteCanStream`, `CanDumpStream` (Register carries a `can_ids` filter).
   - **Vehicle mode / identity:** `Get/SetVehicleOperationMode`
     (MFG/CUST/SERVICE/DECOMMISSIONED), `ScooterModeChange`, `GetVehicleIdentifiers`,
     `CheckManifestFile`.
   - **Provisioning / certs / config:** `ProvisionVin`, `ProvisionConfig`,
     `RegisterNavigation`, `GenerateCerts`, `RegisterInstallCerts`, `ValidateCerts`,
     `ConfigUpdate`, `TechPackUpdate`.
   - **Software update:** `SwUpdateFileClearCache`, `SwUpdateFileTransferMeta`,
     `SwUpdateFileTransfer` (stream), `SwUpdateTriggerUpgrade`, `SwUpdateCheckStatus`,
     `SwUpdateTestSetStatus`.
   - **Versions / flags:** `GetSwVersion`, `GetAospVersion`, `SetEcosFlag`,
     `SetDynoFlag`, `GetEcosDynoFlags`.
   - **Wi-Fi / connection:** `RemoveWifiCredentials`, `InitConnection`, `LocalGetConnection`.
   - **Factory test:** `RemoteRunTestCmd`, `RunSystemTestCmd`, `LocalRunTestStream`,
     `LocalGetTestCmd`, `LocalSendTestResp` (LCD/GPS/BT/BLE/WiFi/SPKR/MIC/MCU-cal/VIN/PROV/eSIM).
   - **State-changing (handle with care):** `SwUpdate*`, `ProvisionVin`,
     `ProvisionConfig`, `ScooterModeChange`, `RemoveWifiCredentials`, `GenerateCerts`,
     `RegisterInstallCerts`, `ClearStorage`, `pushFile`, `Deinit`.

---
## 10. Data flows — architecture questions

### Q1. Service dependency graph, boot order, and what breaks

Boot order is roughly: HVDP and VehicleDataService (CAN sockets) → HVSM, HCCM
(state + cloud) → the consumers (HHMIS, HPMS, range, HDA, CANLOGGER, HOTA, HVS)
→ HHMIC (the UI, last). Consumers auto-rebind when HVDP restarts.

What breaks if a service is disabled:

| Disabled service | Effect |
|------------------|--------|
| **HVDP** | No decoded telemetry and no `0x6BC` command path. HHMIS raises `onVDPCallbackMissing()`; UI shows stale/blank vehicle data. Unlock-by-passcode breaks. |
| **HHMIS** | HHMIC loses its entire data feed (it binds HHMIS by component name). Dashboard goes dead even though the vehicle runs. |
| **HHMIC** | Lose the screen only; the vehicle is unaffected (head unit is a terminal). |
| **HVSM** | No passcode challenge, no SOM reboot authority, no state callbacks; HOHS cannot reboot via its normal path. |
| **HCCM** | **HOHS watchdog reboots the head unit** (HCCM is in `PROCESS_LIST`). Also kills all cloud: telemetry, remote commands, FOTA, tokens, notifications, maps auth. |
| **HOTA** | **HOHS watchdog reboots the head unit** (OTA is in `PROCESS_LIST`). This is the documented random-reboot trap. |
| **HOHS** | Removes the watchdog (and the legitimate health role). May be restarted by another supervisor; verify it stays down. |
| **HPMS** | No passcode verification/profiles; convoy/nav lose VIN/token. |
| **HSSS / HOM / HCS / HDUX / HNFS / HVS / range services** | Degrade their own feature only; not watchdog-critical. |

The only hard interlock is HOHS → {HCCM, HOTA}. Everything else degrades
gracefully. See `research/reboot-analysis.md`.

### Q2. CAN data pipeline — from frame to UI element

```
physical CAN bus → UART bridge (/dev/ttyHSL1 @ 921600) → vcan0 (SocketCAN, ~950 fps)
  → HVDP opens vcan0 (libJNIStubTest.so), MasterParser demuxes by CAN ID
      e.g. 0x352 → speed/displaySoC;  0x120 → overall SoC;  0x356 → odometer;  0x683 → safety
  → per-domain parser builds a typed value → IParserService callback
      e.g. IMotorInfoCallbacks.onSpeedChanged(int), IDisplayInfoCallbacks.onRangeChanged(int)
  → HHMIS VPServerConnection receives the callback, maps it to a ServerCmd enum value
  → IClientServiceInterfaceCallback.onIntegerUpdate(ServerCmd.INT_SPEED, value)  [Binder → HHMIC]
  → HHMIC IClientServiceInterfaceCallbackBuilder switches on ServerCmd
  → KanziUtils.setIntDataObjectValue("<DataContext>","<node>", value)  [JNI → libkanzi.so]
  → libXML_data_source.so (bound via schemas/*DataContext.xml) writes the scene property
  → Kanzi renders the speedometer
```

Three services read the bus independently for their own needs: **HVDP** (the
canonical decoder and command sender), **HVS** (engine sound; decodes
RPM/throttle/torque itself from 0x313/0x113/0x223/0x15b), and **CANLOGGER**
(captures everything, unfiltered). `diagnostics_server` and VehicleDataService
provide generic raw access.

### Q3. Cloud connectivity

One pipe: **HCCM** owns the device's single MQTT connection (Eclipse Paho) over
Jio 4G. Provisioning is dynamic: an mTLS REST call to
`https://mtls-apigw.olaelectric.com` / `https://kong-ola-apigateway-oem.olaelectric.com`
(`deviceauth/v2/wami`) returns an `MQTTInfoEntity{mqttHost, mqttPort, tenantId=VIN,
targetClientId}`; Paho then connects `ssl://<host>:<port>` (TLS, ~8883). Topics
are also provisioned and stored in a Room DB — nothing is hardcoded.

- **Uplink (telemetry):** HDA batches parsed signals into per-subsystem protobuf
  packets (BMS/BCM/MCU/SOM/HPA/LPA/Version/VehicleStats) at per-state cadence and
  hands them to HCCM `publishToMqtt`; offline records queue in Room and flush on
  reconnect. HVSM pushes priority events; CANLOGGER ships zipped raw-CAN protobuf;
  HAIBS/range services push their own analytics — all via HCCM.
- **Downlink (commands/config/FOTA):** cloud publishes to command/config/FOTA
  topics → HCCM `messageArrived` → dispatched via `ICcmInterface` callbacks
  (`SubscribeCommandData/ConfigUpdateData/FotaNotifyData`) → HVDP executes vehicle
  commands on `0x6BC`, HOTA handles updates, HOHS handles maintenance
  (`CCM_REBOOT`/`DA_REBOOT`/`*_CLEAR_CACHE`).
- **Other cloud paths (not HCCM/MQTT):** HOM → `maps.olaelectric.com`; HDUX →
  `ola-ev-ui.olaelectric.com` (WebView); diagnostics_server → olaplant (certs) +
  mapmyindia (nav registration); all apps → NewRelic (`*-nr.olaelectric.com`).
- The head unit never emits CAN `0x6A1` (TCU→VCU). Remote commands always land as
  `0x6BC` via HVDP.

### Q4. State management (HVSM)

HVSM is the state authority on the head-unit side. Vehicle state is decoded by
HVDP from CAN (`IVehicleModeCallbacks.onVehicleStateChanged(VehicleStates)`,
lock state from `0x144`/`VehicleLockStateBCM`, park/SLEEP, charging modes) and
surfaced by HVSM to subscribers via `IVsmService.subscribeVehicleStateCallbacks`
(`IVehicleStateCallbacks`) and `subscribeVehicleDataCalbacks`. Notable states
seen in the enums: driving/park/`SLEEP`, lock states (steering/BCM), ECU modes,
charging modes. `SLEEP` is pivotal — it gates the HOHS deferred reboot and the
HVSM silent-reboot window.

State changes propagate three ways: (1) up to the UI as `ServerCmd` booleans via
HHMIS; (2) to cloud as `MqttProto` priority events via HCCM; (3) to listeners
like HOHS (which keys its reboot decision on `onVehicleStateChanged(SLEEP)`).
HVSM also owns the `VSM_AUTHORITY` content provider that HDA and others read for
`VehicleDetails`.

### Q5. Command flow (UI → CAN)

Example: user toggles Hill Hold on the dashboard.

```
HHMIC Kanzi hit-test → IKanziMessageListener → ModuleManager
  → IClientServiceInterface.onBooleanHMICmd(ClientCmd.HILL_HOLD_TOGGLE, true)   [Binder → HHMIS]
  → HHMIS StateController maps ClientCmd → CommandFromHMI.Hill_Hold_Request_Enable_Selected (0x42)
  → ICommanderService.sendCommandToScooter(Hill_Hold_Request_Enable_Selected)   [Binder → HVDP]
  → HVDP MasterCommander.sendScooterCommands(0x42)
      → (feature toggles go via BCMEventHandler.sendEvent queued Runnable)
      → CanUtils.sendCan0Data(CanId(0x6BC), [0x42,0,0,0,0,0,0,0])  → CanSocket (libJNIStubTest.so)
  → vcan0 → UART bridge → VCU/BCM applies → ACK on 0x6C0 → HVDP decodes → ServerCmd update → UI confirms
```

Lights/indicators and PASSCODE_AUTH (`0x19`) take the **direct** CanSocket path;
everything else is queued through `BCMEventHandler`. Both build the same
`0x6BC` frame — the difference is threading, not content. Full 99-command map in
`research/can-command-reference.md`. A remote (cloud) command follows the same
tail: HCCM → `ICommanderService.sendCloudCommandToScooter(CommandFromApp)` → `0x6BC`.

**Caveat:** the MCU bridge only forwards `0x6BC` frames to the physical bus when
the scooter is awake; when locked/standby they are silently dropped even though
gRPC returns success (`research/unlock-mechanism.md`).

### Q6. Feature configuration (regen, hill hold, drive modes)

Features are configured by sending the matching `CommandFromHMI` value on
`0x6BC`; the authoritative state lives on the **vehicle side** (VCU/BCM), and the
head unit reflects it back through decoded telemetry. The schemas under
`schemas/` (notably `RidingDataContext.xml` and `VehicleDataContext.xml`) list
the toggle set the UI exposes. Mapping:

| Feature | Command(s) on 0x6BC |
|---------|---------------------|
| Regen mode | `Regen_Type_Default_SELECTED` 0x29 / `City_Ride` 0x2A / `Highway_Glide` 0x2B |
| Hill hold | `Hill_Hold_Request_Enable_Selected` 0x42 / `Disable` 0x43 |
| Boost mode | `Boost_Mode_Enable_Selected` 0x30 / `Disable` 0x31 |
| Accident detection | 0x32 / 0x33 |
| Tow/tamper | 0x34 / 0x35 (+ low/high sensitivity 0x4D/0x4E) |
| Proximity unlock | 0x36 / 0x37 |
| Hazard lights feature | 0x3C / 0x3D |
| Drive mode (Eco/Normal/Sport/Hyper) | reflected in `IVehicleModeCallbacks.onVehicleModeLevel4Changed(DriveModes)`; selection is a vehicle-side mode the UI requests |

Where the settings are stored:

- **Vehicle-side feature state** is the source of truth (VCU/BCM), read back via HVDP.
- **Per-rider policy** (passcode, geo/time-fence, drive-mode restriction, maps
  token, saved locations) lives in **HPMS Room DBs** and content providers.
- **Device/UI settings** (volume, brightness, Wi-Fi, BT) live in **HSSS**
  (`getPersistentSystemData`, SharedPreferences) behind `ISystemSettings`.
- **Pushed config** (timers, reboot cadence, topic names, feature flags) arrives
  from cloud via `com.olaelectric.configUpdated` broadcasts and JSON under
  `/data/ola/config/` (`som_platform_config.json`, `som_service_config.json`).
- **Sound customization** (Bolt/Vintage/Eclipse presets) flows HHMIC → HHMIS →
  HVS `IEngineSoundAidlInterface`.

---

## 11. Integration points for a custom app (OlaMate)

All targets are platform-signed; a custom app must be platform-signed or run
through the root/gRPC path to bind them.

### AIDL interfaces worth binding

| Goal | Bind | Interface / method |
|------|------|--------------------|
| **Decoded telemetry, lowest effort** | HVDP `com.olaelectric.vehicleparser.services.VehicleParserService` | `getParserServiceBinder()` → `IParserService.subscribe*(clientId, cb)`; implement `IBatteryInfoCallbacks`, `IMotorInfoCallbacks`, `IDisplayInfoCallbacks`, etc. Fully decoded battery/motor/display/charger/mode/alert/IMU/GPS/version. |
| **Raw CAN frames** | VehicleDataService `IVehicleDataManager` | `subcribeCANFrameRange("olamate", 1, 0x7ff, listener)` → `ICANFrameListener.onCANFrameReceivedCallback(CANFrame)`. |
| **Send commands** | HVDP | `getCommanderServiceBinder()` → `ICommanderService.sendCommandToScooter(CommandFromHMI)` / `unlockedByPasscode(boolean)` (the `0x6BC` path). |
| **State / passcode / profile / token** | HVSM `IVsmService` | `challengeUnlockByPasscode`, `getVehicleDetails`, `getAccessToken`, `subscribeVehicleStateCallbacks`. |
| **Everything the stock UI sees, one feed** | HHMIS `com.android.hmiserverapp.VehicleParserService` (by component) | `addCallback(IClientServiceInterfaceCallback)`; decode `ServerCmd` (178 values). Mirrors exactly what HHMIC renders. |
| **Range** | HVRS `IRangeInterface` / HAIP `IAIProxyAIDL` | `onRangeChanged(int)` (classic) or `AIProxyCB.notifyDataModel` (AI). |
| **Settings (Wi-Fi/BT/volume/brightness)** | HSSS `ISystemSettings` | sub-binders `getWifiSettings/getBluetoothSettings/...`. |
| **Notifications** | HNFS `INotificationService` | `subscribeNotificationCallbacks`. |
| **Cloud publish/subscribe** | HCCM `ICcmInterface` | `publishToMqtt`, `SubscribeCommandData/ConfigUpdate/FotaNotify`, token APIs. |

### Non-AIDL data sources

- **Raw root access:** `diagnostics_server` gRPC on `:50005` —
  `ExecuteADBCommand` (root shell, incl. `cansend vcan0 6BC#...`), `CanDumpStream`
  for a raw frame stream. The command path OlaMate already uses.
- **Content providers:** `content://com.olaelectric.vehiclestatemanager.VSM_AUTHORITY/VehicleDetails`
  (VIN/vehicle metadata, signature-protected);
  `content://com.olaelectric.profilemanagerservice.contentprovider/{user,vehicle}`.
- **On-disk telemetry:** HDA protobuf ring buffer under `/data/ola/hf/*.proto`
  and `/data/ola/sys_logs/`; CANLOGGER zips under `/data/ola/sys_logs/zip/`
  (protobuf `VcanPacketList`, all CAN IDs); config JSON under `/data/ola/config/`.
- **UI binding schemas:** `schemas/*DataContext.xml` enumerate every Android→Kanzi
  property binding — the field catalog for a replacement dashboard.
- **CAN map + command table:** `docs/architecture.md` (IDs), `research/can-command-reference.md`
  (0x6BC command bytes), `proto/wifican.proto` (gRPC surface).

### Field dictionaries (the real catalogs)

- HHMIS **`ServerCmd`** (178 values) and **`ClientCmd`** (71 values) — the UI bus.
- HVDP `com.olaelectric.vehicleinterface` callback interfaces — the decoded signal set.
- `CommandFromHMI` (99 values) — the 0x6BC command bytes.

### Recommended approach for OlaMate

For a telemetry logger, emulate **HDA's input side**, not its output: subscribe
to HVDP's `IParserService` callbacks (decoded, no CAN parsing) and/or read raw
frames via VehicleDataService or `diagnostics_server` `CanDumpStream`, and store
locally. Do not route through HCCM's MQTT. Never `pm disable` HCCM or HOTA (HOHS
reboots the head unit). Prefer read-only subscription; only send `0x6BC`
commands when the scooter is awake.

---

## Appendix — decompilation provenance

- Tool: `apktool` 3.0.2, `apktool d --no-assets <apk>` (Kanzi `.kzb`, `.mp4`, and
  audio assets skipped — they are not needed for IPC/data-flow analysis).
- `diagnostics_server` inspected with `strings` only; never executed. The gRPC
  surface is from the repo's `proto/wifican.proto` (decoded FileDescriptorProto).
- Method: static analysis of AndroidManifest components, smali AIDL stubs/proxies,
  native-library loads, and string constants. No live logcat/runtime tracing;
  config defaults in code may be overridden by server-pushed config.
- HHMIC Kanzi scene internals are in `docs/hmi-apk-analysis.md` and `schemas/`.
