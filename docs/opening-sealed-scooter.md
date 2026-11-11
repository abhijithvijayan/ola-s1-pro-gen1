# Opening a sealed scooter (no diagnostic port, no ADB)

Written for MoveOS builds that boot in `cust` and do **not** have the
`on post-fs-data` reset to `mfg` — i.e. the scooter's gRPC port 50005 and
Wi-Fi ADB port 5555 are firewalled at every boot. On that build nothing in
[adb-key-injection.md](adb-key-injection.md) or
[scootermode-and-recovery.md](scootermode-and-recovery.md) is reachable from
the network, so the usual recovery paths don't apply.

The goal here is to get an APK onto the head unit using only the UI the rider
already has, with no USB-C ADB, no cable, no service visit.

For terminology and the distinction between the `scootermode` Android
property and the `vehicle-op-mode` JSON, see
[scootermode-and-recovery.md](scootermode-and-recovery.md).

## What is pre-installed and reachable

Taken from `pm list packages -f` on a `test-keys` engineering build. A
production MoveOS build should carry the same system packages; the user-space
ones vary.

Launcher-visible (will appear in Settings → Apps → Open, or on any launcher
grid):

| Package | Role in this context |
|---|---|
| `com.android.settings` | Android Settings. The only entry point when no custom launcher is available. |
| `com.android.documentsui` | AOSP Files app (`FilesActivity`). Browses `/sdcard`, opens APKs into the Package Installer. |
| `com.olaelectric.duxwebview` (**HDUX**) | Ola's own WebView app. Loads a fixed Ola URL; a `https://google.com` fallback is wired in via its Hilt DI module. If the primary URL fails, the fallback should hit. Full WebView (JS, DOM storage, file access). |
| `com.ola.mfgapp` (**HMFG**) | Vehicle-mode dialog (`customerMode` / `productionMode` / `serviceMode` / `notDefined`). Writes `persist.ola.security.scootermode`. Only app that can reopen the ports permanently from the UI. |
| `com.olaelectric.udstestapp` | UDS diagnostic harness. No install path. |
| `com.olaelectric.olaevnavigation` (HOM) | Navigation. No install path. |
| `com.olaelectric.hmiclient` (HHMIC) | Stock dashboard. Hidden Manufacturing App behind the `560095` keypad; useful only on non-CUST (see `scootermode-and-recovery.md`). |
| `com.android.gallery3d`, `com.android.music`, `com.caf.fmradio` | Media apps. No install path. |

Not launcher-visible but present system-wide (fire when a matching intent is
emitted):

| Package | Role |
|---|---|
| `com.android.packageinstaller` | Handles every `.apk` open. Always available. |
| `com.android.captiveportallogin` | **"Sign in to Wi-Fi network" WebView**, launched automatically when Android's connectivity probe fails. Has `INTERNET`. The classic console-mod primitive. |
| `com.android.htmlviewer` | WebView wrapper. Only accepts `content://` URIs — doesn't take `https://`. Not useful on its own. |
| `com.android.webview` + `org.chromium.webview_shell` | System WebView + a webview shell. Only `webview_shell` registers a `VIEW https://` handler; it has no launcher icon. |
| `com.android.providers.downloads(.ui)` | Downloads UI. Opens APK downloads into the Package Installer. |

## Routes to install an APK without ADB

### Route A — Captive-portal WebView (the console-mod trick)

`com.android.captiveportallogin` is a system WebView granted `INTERNET` that
Android launches automatically whenever its connectivity probe fails or is
redirected. It renders whatever HTML is at the captive-portal URL and follows
links on that page. On user builds there is no URL bar, but outbound links
work.

The modding recipe:

1. Host two URLs somewhere the scooter can reach:
   - a landing page with a single link to the APK;
   - the APK itself as a direct download (`Content-Type: application/vnd.android.package-archive`).
2. Put a laptop or a phone into hotspot mode, configured to **intercept**
   Android's connectivity-check request and serve the landing page in its
   place. Android 10 probes at least:
   - `http://connectivitycheck.gstatic.com/generate_204`
   - `http://clients3.google.com/generate_204`
   - `http://www.google.com/generate_204`
   Any one failing to return 204 fires the portal flow. Easiest setup is a
   Linux hotspot with `dnsmasq` + `nginx` redirecting those hosts to your
   landing page; several Android tethering apps (PdaNet+, NetShare) do this
   natively. iPhone Personal Hotspot does not.
3. On the scooter: **Settings → Network & Internet → Wi-Fi → pick that
   hotspot**. Android shows "Sign in to Wi-Fi network" → tap → captive-portal
   WebView opens on your landing page.
4. Tap the APK link → WebView downloads it → **Package Installer** opens on
   tap of the download notification, or via **Files** at `Downloads/`.
5. Before tapping the install: **Settings → Apps → CaptivePortalLogin (or
   Files) → Install unknown apps → Allow** for the source app that will hand
   the APK to the installer.

### Route B — HDUX fallback

`com.olaelectric.duxwebview` is launchable and is a full WebView.

- Primary URL (from `DataField.smali`):
  `https://ola-ev-ui.olaelectric.com/api/cAppLogin?redirectUrl=vacationmode-swipeable&postCallTo=feature-dux`
- Fallback (`di/MainModule.smali`): `https://google.com`

If the primary URL fails (no SIM, airplane mode, expired token, Ola endpoint
unreachable), the fallback should load. From a full Google page the user can
search for or type the direct APK URL, download it and install via the same
Package Installer path as Route A.

Works without any special hotspot configuration, as long as the primary URL
is reachable but does something the app considers a failure (or is itself
unreachable). Try airplane mode or a hotspot that has no internet.

### Route C — USB-C OTG stick + Files

If the scooter's USB-C port is wired for OTG host mode (not just charging),
a USB stick carrying the APK, plus the pre-installed **Files** app, is
sufficient. Not verified on Gen 1; worth a try before setting up the hotspot
trick. Launch Files → navigate to the mounted USB → tap the APK → install
with "Install unknown apps" allowed for Files.

## After the first install: can we make it permanent?

Routes A–C install an APK. They don't by themselves reopen the diagnostic
port or disable the stock dashboard. Two further questions:

### 1. Can an APK itself flip `scootermode` back to `mfg` / `serv`?

If a third-party APK can write `persist.ola.security.scootermode` to `serv`,
the init handler fires `open_port` → iptables ACCEPT on 50005 and 5555, and
the diagnostic ports reopen across every subsequent reboot. That turns the
one-time captive-portal install into a permanent unlock.

Whether this works depends on two gates:

- **SELinux.** `persist.ola.security.scootermode` almost certainly has its
  own property context (something like `ola_security_prop`) with a tight
  `set_prop` TE rule allowing only specific OEM domains (HMFG, init). A
  third-party app's domain (`untrusted_app`) will **not** have `set_prop` on
  it. In **enforcing** mode the write is blocked. In **permissive** mode
  (what the engineering `test-keys` build on the author's scooter is set to)
  the denial is logged but the write succeeds.
- **init property-service.** Beyond SELinux, init's `property_set` does not
  gate custom `persist.ola.*` namespaces by UID; the only check is SELinux.

The implementation is one line of shell from the APK:

```java
Runtime.getRuntime().exec(new String[]{ "setprop", "persist.ola.security.scootermode", "serv" }).waitFor();
```

(or the `SystemProperties.set` hidden API via reflection; same effect, same
sepolicy gate.)

**Open test to confirm this works for a non-root caller:**

Needs the scooter in front of you, not run by any automated tool.

```
# from a root shell (gRPC or ADB): confirm the property changes and the
# init handler fires iptables correctly
setprop persist.ola.security.scootermode serv
getprop persist.ola.security.scootermode
iptables -L INPUT -n | grep -E "50005|5555"
# then reset
setprop persist.ola.security.scootermode mfg

# then build a trivial APK with the Runtime.exec above and run it from a
# regular user UID. Check whether `getprop` reflects the change.
# Run `getenforce` first — if Enforcing, the test is pointless on that build.
# Tail logcat for `type=1400 avc: denied { set } ... property_service` to
# see what SELinux refused.
```

If the APK-from-user-uid write succeeds, the full recipe for a sealed MoveOS
scooter becomes:

1. Captive-portal install (Route A) of a tiny "unlock" APK.
2. Run the APK. It writes `persist.ola.security.scootermode=serv`.
3. Next boot (or immediately, via init's property handler) the ports open.
4. From then on, the regular `inject-adb-key.sh` and `backup-stock-keys.sh`
   from this repo work as they do on the author's scooter.

If the write is blocked (SELinux enforcing, or init refuses), the APK is
limited to things any userland app can do. It can still install OpenDash and
set it as HOME, but the diagnostic port stays closed on 4.0.1.

### 2. Can an APK flip it to `serv` via HMFG instead of directly?

HMFG (`com.ola.mfgapp`) writes the property as a system-privileged app, so
its write is always permitted. If HMFG exposes an exported receiver / service
that accepts a "set mode" intent from another app, a third-party APK can
trigger the write indirectly without needing the sepolicy grant itself.

Not yet audited. Worth grepping HMFG's manifest for exported receivers and
its smali for an IPC entry point that calls its `setMode()` path.

### 3. What a user-uid APK can always do

Independent of the property write:

- Install OpenDash and set it as HOME via the AOSP "Choose a launcher" picker
  that fires on the next HOME intent.
- Force-stop other apps (via its own UI only; no `pm` commands).
- Do everything a normal app does.

The property-write question is the one that decides whether 4.0.1 scooters
can be self-recovered without a dealer / HMFG UI / USB cable.

## Checklist for the friend on MoveOS 4.0.1

1. `Settings → Apps → See all apps`. Confirm these are present:
   - `com.olaelectric.duxwebview` (HDUX)
   - `com.android.documentsui` (Files)
   - `com.android.captiveportallogin`
   - `com.ola.mfgapp` (HMFG)
2. `Settings → About phone → Build number` × 7 → Developer options → USB
   debugging. Try route not in this doc: USB-C ADB from a laptop. Easiest
   win if the port supports data.
3. If USB-C ADB fails, set up the Route A captive portal and install
   OpenDash.
4. If HMFG opens straight into the mode dialog, pick `serviceMode`.
   Otherwise stop there and open an issue describing what HMFG actually
   shows at launch.
