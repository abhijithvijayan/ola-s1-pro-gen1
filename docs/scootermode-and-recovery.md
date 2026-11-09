# Scootermode (`persist.ola.security.scootermode`) and recovering a stuck stock dashboard

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

### 1. The scooter is ALWAYS in `mfg` on boot

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
