# Scootermode (`persist.ola.security.scootermode`) and recovering a stuck stock dashboard

## Terminology

Two independent values share the word "mode". This document uses distinct names for each; they are not linked in code.

| Name used in this document | Android property / file | Values | Written by | Effect |
|---|---|---|---|---|
| **scootermode** | `persist.ola.security.scootermode` (Android system property, read by init) | `mfg`, `cust`, `serv` | HMFG app; init `on post-fs-data` hook; `setprop` from a root shell | iptables on ports 50005 and 5555 (ADB over Wi-Fi and diagnostics gRPC). `cust` drops the packets; `mfg` and `serv` accept them. |
| **vehicle-op-mode** | `/data/ola/v-op-mode.json`, field `current_op_mode` (file on disk, read by HHMIC at startup) | `0` NONE, `1` MFG, `2` CUST | HHMIC `ManufacturingManager` | Branch taken by `ManufacturingManager.checkForPassword` for the dashboard keypad: `2` (CUST) validates input as an OTP via QR; any other value accepts the static `560095`. |

`ManufacturingManager` does not call `SystemProperties.set` on `persist.ola.security.scootermode`, and the init property-change handlers do not read the JSON. A change to one has no effect on the other:

- Editing the vehicle-op-mode JSON does not alter iptables and does not open or close the diagnostics ports.
- Setting the scootermode property to `cust` closes the ports immediately for the rest of the boot. On builds that include the `on post-fs-data` reset, the next boot restores `mfg` and reopens them.

## Background

Findings from the 2026-11-09 device session. The scooter had been running normally, a third-party dashboard app was uninstalled, then after a reboot the stock dashboard came up with a white screen. This doc captures what we learned about `scootermode`, the init-time behaviour that controls ADB/gRPC access, and a safe recovery path for the "white screen after Doze" failure mode.

## The property

`persist.ola.security.scootermode` is a **persistent Android system property** read on every boot. It gates what the init system does with the diagnostics ports.

Known values (from `research/service-map.md` and the stock HHMIS enum `VehicleOperationMode`):

| Value | Meaning | Diagnostic ports |
|---|---|---|
| `mfg`  | Manufacturing | **open** (iptables ACCEPT on 50005, 5555) |
| `cust` | Customer (normal rider) | **closed** (iptables DROP on 50005, 5555) |
| `serv` | Service / dealer | **open** |
| (also referenced in some HHMIS enums: `MFG`, `CUST`, `SERVICE`, `DECOMMISSIONED` in uppercase — the init property uses lowercase) |

## The init hook (`/vendor/etc/ola_e2.rc`)

```
on property:persist.ola.security.scootermode="cust"
   start close_port
   stop adbd
   start adbd

on property:persist.ola.security.scootermode="mfg"
   start open_port
   stop adbd
   start adbd

on property:persist.ola.security.scootermode="serv"
   start open_port
   stop adbd
   start adbd

on post-fs-data
   chmod 0777 /vendor/etc/adbkey.pub
   chmod 0777 /vendor/etc/adbkeymoveos3_pub_prod.pub
   setprop persist.ola.security.scootermode "mfg"
   start key_copy
   stop adbd
   start adbd
```

And the port services:

```
service close_port /system/bin/iptables -I INPUT -p tcp --match multiport \
        --destination-port 50005,5555 -j DROP
service open_port  /system/bin/iptables -I INPUT -p tcp --match multiport \
        --destination-port 50005,5555 -j ACCEPT
```

## Two things this tells us

### 1. The scooter is ALWAYS in `mfg` on boot (on this build)

The `on post-fs-data` trigger runs unconditionally at every boot. It sets the property to `"mfg"`, which cascades to `start open_port` → iptables ACCEPT on 50005 and 5555. That is why `scripts/inject-adb-key.sh` and gRPC ever worked in the first place. It is not a custom state anyone enabled.

### 2. Setting `cust` firewalls off the scooter — but only until the next reboot

`cust` triggers `close_port` → iptables DROP on ports 50005 and 5555. **While the scooter is in `cust`, you have no network access**: no ADB over Wi-Fi, no gRPC, no way to inject a key or run any of these scripts from a laptop. The gRPC service itself is still running on the device (so an app on-device can reach `localhost:50005`), but nothing external gets through.

**The reboot heals it, though.** Two reasons:

1. iptables rules are kernel runtime state, not persistent. Every boot comes up with no custom INPUT rules.
2. The `on post-fs-data` hook above runs very early on boot and unconditionally does `setprop persist.ola.security.scootermode "mfg"`. The property change from `cust → mfg` fires the `open_port` handler, which adds the explicit ACCEPT rule.

So a scooter in `cust` is network-inaccessible for the rest of that boot, and comes back in `mfg` the next time it powers up. Key-cycle the scooter and you're back in.

Practical implications:
- Don't set `cust` mid-ride if you still need network recovery in this session — you've locked yourself out until the scooter is rebooted.
- Don't set `cust` if you're about to do something that might wedge the scooter in a state where it can't reboot cleanly (bad OTA mid-flight, for example).
- Otherwise, `cust` is not catastrophic — it's the stock-shipping default behaviour conceptually, just undone on every boot by the post-fs-data hook.

Our scripts don't expose a setter for this property because we never need it — the device is already in `mfg` by design.

If you want to test stock-like network behaviour without reboot access, use `serv` instead (same `open_port` side effects, clearer intent in the log).

### 3. The boot-time reset is not on every MoveOS build

The `on post-fs-data` hook that unconditionally writes `mfg` is what keeps the diagnostics ports open on this scooter. On **MoveOS 4.0.1** another owner reports the ports are firewalled at boot, which means that hook has been removed or made conditional on the shipping build. `cust` is the factory default, so without the reset the scooter stays in `cust` across reboots and nothing on the network can reach 50005 or 5555.

From a `cust`-at-boot scooter you cannot:

- reach gRPC on 50005, so `scripts/inject-adb-key.sh` and every `grpcurl` call fail;
- reach ADB over Wi-Fi on 5555;
- flip the scootermode from HHMIC. HHMIC's **560095** manufacturing PIN only opens its own Manufacturing App screen (QR / hardware info / OTP, in `ManufacturingManager.launchMfgApplication`); it never calls `SystemProperties.set` on `persist.ola.security.scootermode`. The only app that writes `mfg` / `serv` into that property is **HMFG** (`com.ola.mfgapp`), from its `VehicleModeDialogBinding` (`customerMode` / `productionMode` / `serviceMode` / `notDefined` radio buttons). Reaching HMFG from a laptop still needs a working transport.

Ways in when the network is firewalled:

- **USB ADB.** Some units expose ADB over USB-C even when Wi-Fi ADB is blocked by iptables (the DROP is on INPUT, not on `adbd` itself). Try this first; it bypasses the port rules entirely.
- **Dealer / service-centre tool.** Their rig talks to HMFG and can set `serviceMode`, which has the same open-ports effect as `mfg`. Once set, it persists across reboots on builds without the post-fs-data override.
- **Reflashing / unlocked boot.** Out of scope here and risky.

Without one of those, the scooter is sealed at the network level and this doc's recovery steps don't apply.

## The HHMIC Manufacturing App passcode (`560095`)

Not a scootermode switch, but relevant because it keeps getting confused with one.

Stock HHMIC has a hidden "Manufacturing App" screen gated by a six-digit PIN. Decompiled from HHMIC on this scooter:

- `com/olaelectric/hmiclient/manufacturingApp/ManufacturingManager.smali`:
  ```
  .field private static final DEFAULT_PASSCODE:Ljava/lang/String; = "560095"
  .field private static final JSON_FILE_PATH:Ljava/lang/String; = "/data/ola/v-op-mode.json"
  ```
- `HPMS/.../data/constants/ConstantsKt.smali` repeats it as `DEFAULT_PASSWORD_2 = "560095"` (with `DEFAULT_PASSWORD_3 = "123456"`).
- Kanzi UI: popup `Screens/.../PopupContainer/MFG_Passcode_PopUp` with its keypad under `Prefabs/Passcode_ManufactureApp/.../Invisible_Button/Grid Layout 2D/Button_1..9`.

How it is reached: the Kanzi UI emits an action string (`ACTION_LAUNCH_MANUFACTURINGAPP` or `ACTION_SHOW_SW_VERSION_HISTORY`) into `ManufacturingManager.handleMessage`, which calls `launchMfgAppPasscode()` to show the popup. The hidden tap target that emits the action lives in the Kanzi binary graph (one of the `Invisible_Button` nodes on an About / Settings / Splash screen); the kzb text dump shows the popup and keypad but not the button bindings, so the exact tap sequence can only be read with a Kanzi tool. The dispatch in `checkForPassword` is **mode-sensitive**:

```
if (currentVehicleMode == VEHICLE_OP_STATE_CUST) {
    ok = rsaEncryptor.validateOtp(input);     // on a customer scooter
} else {
    ok = input.equals("560095");               // only in MFG / NONE
}
if (ok) launchMfgApplication()    // or toggleVersionInfoScreen(true)
```

`currentVehicleMode` is read at startup from the **vehicle-op-mode JSON** at `/data/ola/v-op-mode.json` (`current_op_mode`: `"2"` → CUST, anything else → not CUST). **So 560095 only works when the vehicle-op-mode JSON says the scooter is not CUST.** A production scooter in the owner's hands is CUST, which is why the static PIN is rejected and the keypad entry is validated as an OTP instead.

### The QR code and the OTP (CUST path)

When the popup opens on a CUST scooter, `setQRCode()` calls `rsaEncryptor.Encrypt(0, vinNumber)` and shows the result as a QR. The plaintext before encryption is built by `generateEncoderData`:

```
mode 0:  "Manufacturing$" + vin + "$" + otp + "$" + systemTimeMs
mode 1:  "Diagnostics$"   + vin + "$" + otp + "$" + systemTimeMs
```

- `otp` is a random six-digit number (`random.nextInt(999_999)`, `%06d`).
- Encryption uses a PEM public key loaded from disk (`RSAEncryptor.loadPublicKeyFile`, `-----BEGIN PUBLIC KEY-----`).
- The QR is a base64 string of the RSA-encrypted bytes (480 base64 chars ≈ 360 bytes ≈ a few RSA-2048 blocks).
- A fresh QR (and a fresh OTP) is generated every `QR_VALIDITY_TIME = 300` seconds.

The flow at a service centre: tech scans the QR with their internal app → the app RSA-decrypts the payload with the matching **private** key → extracts the 6-digit OTP → the user types that OTP into the dashboard keypad → `validateOtp` compares it to the one the dashboard generated → unlock. The private key is not on the scooter and not in HHMIC.

The same mechanism gates the Version History screen (`launchVersionInfoPasscode` / `ACTION_SHOW_SW_VERSION_HISTORY`). Owners have reported reaching it by tapping the regen details on the battery screen multiple times.

### Can you bypass it without the private key?

Changing the stored vehicle-op-mode to any value other than CUST (`2`) makes `checkForPassword` take the static-password branch, which accepts `560095`. This has no effect on the scootermode property and does not alter diagnostic port access. HHMIC reads the JSON at startup, so the process must be restarted for the change to take effect:

```
echo '{"current_op_mode":0,"modified_ts":0,"modified_ts_str":"","modified_by":""}' > /data/ola/v-op-mode.json
am force-stop com.olaelectric.hmiclient
```

The change persists until HHMIC overwrites the file. `ManufacturingManager.clearInitValues` resets `current_op_mode` to `0` (NONE) on close, and the join-fleet flow writes it back to `2` (CUST) after a valid OTP. Cloud services and the OTA pipeline expect CUST, so features that depend on either may stop working.

What `560095` **does not** do:

- It does not change `persist.ola.security.scootermode`. HHMIC never calls `SystemProperties.set` on that key. It only reads `/data/ola/v-op-mode.json` to display the current mode.
- Its enum has only `VEHICLE_OP_STATE_NONE`, `VEHICLE_OP_STATE_MFG`, `VEHICLE_OP_STATE_CUST`. There is no `SERVICE` state in HHMIC.
- So entering `560095` on a `cust`-at-boot scooter will not open the gRPC or ADB ports.

What it **does** do: shows the Manufacturing App (QR-code setup, hardware info / version history, OTP entry via `RSAEncryptor.validateOtp`). Useful for reading VINs and software versions from the dashboard; not useful for recovering network access.

## Switching scootermode: the HMFG app (`com.ola.mfgapp`)

The separate on-head-unit APK `HMFG` is the only client that writes `persist.ola.security.scootermode`.

- `com/ola/mfgapp/databinding/VehicleModeDialogBinding.smali`: four radio buttons — `customerMode`, `productionMode`, `serviceMode`, `notDefined`.
- `com/ola/mfgapp/MainActivity.smali` writes the raw strings:
  ```
  const-string v1, "mfg"
  const-string v1, "serv"
  ```
- `PreferenceHelper.PREF_SERVICE_VALUE = "Service_mode"`.
- Local IPC uses `CONNECTED_APP_TO_MFG` / `EVT_CONNECTION_APP_TO_MFG` and talks to the diagnostics gRPC service on port 50005.

Practical consequence: setting `serviceMode` from HMFG has the same `open_port` effect as `mfg` (see the init hook above) and **persists across reboots on builds without the `on post-fs-data` override**. That is why a dealer-tool pass can unlock the ports on a MoveOS 4.0.1 scooter that boots sealed.

On this scooter HMFG is reachable because the ports are open at boot; from the diagnostics shell:

```
run "setprop persist.ola.security.scootermode serv"
```

has the same effect without opening the HMFG UI. The property change triggers the `open_port` service directly.

## The "white screen after Doze" failure mode (2026-11-09)

### Symptom

After a reboot or after the display sleeps and wakes, the stock dashboard shows a white screen. HHMIC's process is up, its activity is resumed, but logcat shows:

```
KanziView: KanziActivity::surfaceDestroyed
Kanzi : haltApplication: requested.
Kanzi : kzaMain: application exited in sleeping state.
Kanzi : kzaMain: waiting for state change to running.
E libEGL : call to OpenGL ES API with no current context
```

Kanzi (the 3D renderer stock uses) has halted its render thread because the Surface was destroyed and the EGL context was lost. `mCurrentFocus=null` on `dumpsys window`.

### Root cause

Display went into Doze (`mWakefulness=Dozing`, `Display Power: state=OFF`). On wake, Android sometimes doesn't drive Kanzi through a clean surface recreation — the thread stays halted. A physical button press on the scooter also may not reliably wake it from this state.

### Recovery

Three things in order:

1. `input keyevent KEYCODE_WAKEUP` — kicks Dozing back to Awake and brings display ON
2. `am force-stop com.olaelectric.hmiclient` — kills the halted-Kanzi process
3. `am start -a android.intent.action.MAIN -c android.intent.category.HOME` — Android relaunches HHMIC via the HOME intent, which gets a fresh surface

A reboot fixes it too but is heavier. `scripts/fix-stock-screen.sh` wraps the three-step recovery into one gRPC-driven command.

### Prevention

The display timeout and screensaver settings reset to defaults on every boot. If a scooter is left idle with stock as HOME, Doze will fire. Mitigate with:

```
settings put secure screensaver_enabled 0
settings put system screen_off_timeout 2147483647
```

These do not persist across reboot. Any deploy script for a replacement dashboard can run them as part of install; on a stock-only scooter, `scripts/fix-stock-screen.sh` includes them.

## Related: ADB key handoff after uninstall

Also seen 2026-11-09: when a third-party dashboard was uninstalled, the stock dashboard briefly showed battery "0". HHMIC had to rebind HHMIS and pull fresh data. Clears on its own within a few seconds. No action needed. Documented here so we don't chase it if it recurs.
