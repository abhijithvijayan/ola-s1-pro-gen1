# ADB Key Injection

## Summary

Append your laptop's ADB public key to the scooter's authorized key store, enabling `adb connect <ip>:5555` for interactive shell, fast file transfer, `scrcpy` screen mirroring, and `logcat`.

## Why ADB?

gRPC `ExecuteADBCommand` gives root but has limitations:
- One command at a time (no interactive shell)
- No file transfer (410MB APK is impractical over base64)
- No screen mirroring
- Complex commands need the `${IFS}` workaround

ADB over TCP (port 5555) solves all of these. Note: ADB shell is uid 2000 (shell), not root — use gRPC for root commands.

## How Gen 1 Key Auth Works

From `/vendor/etc/ola_e2.rc`:

```
on post-fs-data
   chmod 0777 /vendor/etc/adbkey.pub
   chmod 0777 /vendor/etc/adbkeymoveos3_pub_prod.pub
   setprop persist.ola.security.scootermode "mfg"
   start key_copy
   stop adbd
   start adbd
```

1. At boot, `key_copy` (`/system/bin/key_copy`) copies vendor public keys to `/data/misc/adb/adb_keys`
2. `adbd` reads this file when `ro.adb.secure=1`
3. Scooter mode is hardcoded to `mfg`, which opens ports 50005 and 5555

The stock key file contains a single Ola technician key. We append ours alongside it.

## Quick Start

```bash
SCOOTER_IP=<your-scooter-ip> bash scripts/inject-adb-key.sh
```

Then:

```bash
adb connect <your-scooter-ip>:5555
adb shell id  # uid=2000(shell)
```

## Manual Procedure

### Step 1: Backup

```bash
grpcurl -plaintext \
  -import-path proto -proto wifican.proto \
  -d '{"cmd_msg": "cp /data/misc/adb/adb_keys /data/misc/adb/adb_keys.bak"}' \
  <IP>:50005 wifican.WifiCanRpc/ExecuteADBCommand
```

### Step 2: Add newline separator

```bash
grpcurl -plaintext \
  -import-path proto -proto wifican.proto \
  -d '{"cmd_msg": "sh -c echo>>/data/misc/adb/adb_keys"}' \
  <IP>:50005 wifican.WifiCanRpc/ExecuteADBCommand
```

### Step 3: Append your key

```bash
ENCODED=$(base64 < ~/.android/adbkey.pub | tr -d '\n')
CMD="sh -c echo\${IFS}${ENCODED}|base64\${IFS}-d>>/data/misc/adb/adb_keys"

grpcurl -plaintext \
  -import-path proto -proto wifican.proto \
  -d "{\"cmd_msg\": \"$CMD\"}" \
  <IP>:50005 wifican.WifiCanRpc/ExecuteADBCommand
```

### Step 4: Restart adbd

```bash
grpcurl ... -d '{"cmd_msg": "stop adbd"}' ...
sleep 1
grpcurl ... -d '{"cmd_msg": "start adbd"}' ...
```

### Step 5: Connect

```bash
adb connect <IP>:5555
```

## Persistence (Does NOT Survive Reboot)

The injected key is **wiped on every reboot**. At `post-fs-data`, the init script runs `key_copy` which **overwrites** `/data/misc/adb/adb_keys` with the Ola factory key from `/vendor/etc/adbkey.pub`:

```sh
# /system/bin/key_copy (the full script)
#!/system/bin/sh
/system/bin/cp /vendor/etc/adbkey.pub /data/misc/adb/adb_keys
sync
chmod 0644 /data/misc/adb/adb_keys
/system/bin/cp /vendor/etc/adbkeymoveos3_pub_prod.pub /data/misc/adb/adbkeymoveos3_pub_prod
sync
chmod 0644 /data/misc/adb/adbkeymoveos3_pub_prod
```

This can't be changed without modifying read-only partitions (`/system` and `/vendor` are mounted `ro` with dm-verity).

### After every reboot

Re-run the injection from your laptop (takes ~10 seconds):

```bash
SCOOTER_IP=<your-ip> bash scripts/inject-adb-key.sh
```

gRPC root on port 50005 is always available — it's baked into the firmware and requires no auth. Only the ADB key needs re-injection.

### What survives reboot

| Change | Survives? | Why |
|--------|-----------|-----|
| gRPC root (port 50005) | Yes | Built into `diagnostics_server` on `/vendor` |
| ADB key injection | **No** | `key_copy` overwrites `/data/misc/adb/adb_keys` |
| OTA disable (`pm disable-user`) | Yes | Stored in `/data/system/users/0/package-restrictions.xml` |
| Sideloaded APKs | Yes | Installed on `/data` |

### Why automatic on-device re-injection is hard

- `/vendor` and `/system` are read-only (dm-verity) — can't modify `key_copy` or init scripts
- No `init.d` or post-boot script mechanism on `/data`
- No scripting runtime (Python, etc.) on device to call gRPC
- Device `curl` lacks HTTP/2 support (can't call gRPC)
- A boot-complete APK with an embedded gRPC client would work but is heavy to build

## Reverting

```bash
SCOOTER_IP=<your-scooter-ip> bash scripts/revert-adb-key.sh
```

Or manually: restore the backup and restart adbd.

## Related recovery

If the stock dashboard shows a white/blank screen after waking from sleep (Kanzi halt, confirmed 2026-11-09), run:

```bash
SCOOTER_IP=<your-scooter-ip> bash scripts/fix-stock-screen.sh
```

Full write-up: `docs/scootermode-and-recovery.md`.
