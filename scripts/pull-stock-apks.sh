#!/bin/bash
# pull-stock-apks.sh — Copy the scooter's stock APKs to this computer, with a
# list of every stock package and its version. Read-only.
#
# Usage:
#   SCOOTER_IP=<your-ip> bash scripts/pull-stock-apks.sh [out-dir] [--all] [--dry-run]
#
# What it runs on the scooter, and nothing else:
#   pm list packages, pm path <pkg>, dumpsys package <pkg>   (what is installed, where, which version)
#   cat /vendor/etc/SW_version.txt, cat /data/ola/vsw.txt    (MoveOS and vehicle-software versions)
#   getprop ro.build.version.release / .sdk                  (Android version)
#   adb pull <apk>                                           (the copy)
# Nothing is installed, changed, stopped or sent. No serial number, VIN or
# account detail is read.
#
# Needs adb authorised on the scooter (scripts/inject-adb-key.sh).
#
# By default it pulls the packages that define how a dashboard talks to the
# scooter (PACKAGES below). --all pulls every stock package it finds, the
# modem maker's tool and the diagnostics_server binary included. The
# dashboard itself (HHMIC) is 400 to 800 MB and is pulled last.
#
# Output (default local/apks/<date-time>/, which is gitignored):
#   <package>-<version>.apk   one per package pulled
#   versions.txt              every stock package with its version, pulled or not
#   sha256.txt                checksum of each APK pulled
#
# The point: stock builds differ. MoveOS 5 inserted commands into the list the
# dashboard and HHMIS share, which moves every later command number. Comparing
# two builds needs the APKs of both, named by version.
set -euo pipefail

: "${SCOOTER_IP:?Usage: SCOOTER_IP=<your-ip> bash scripts/pull-stock-apks.sh [out-dir] [--all] [--dry-run]}"
OUT=""
ALL=0
DRY=0
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --dry-run) DRY=1 ;;
    --*) echo "unknown option $arg" >&2; exit 2 ;;
    *) OUT="$arg" ;;
  esac
done
DEV="$SCOOTER_IP:5555"
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="${OUT:-$REPO/local/apks/$(date +%Y%m%d-%H%M)}"

PACKAGES=(
  com.android.hmiserverapp                 # HHMIS: commands, events, vehicle states
  com.olaelectric.ota                      # HOTA: firmware updates
  com.olaelectric.profilemanagerservice    # HPMS: profiles, passcode
  com.olaelectric.connectivityservice      # HSSS: Bluetooth, Wi-Fi, volume
  com.olaelectric.vehicleparser            # HVDP: CAN reader/writer
  com.olaelectric.vehiclestatemanager      # HVSM: state machine, lock/unlock
  com.olaelectric.hmiclient                # HHMIC: the dashboard (large)
)

# Git Bash on Windows rewrites arguments that look like /paths into
# C:\... before adb sees them; the scooter's paths must go through as written.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# What counts as the scooter's own software: Ola's packages, the vehicle
# service (which has an Android-looking name), and the modem maker's
# configuration tool. Everything else is plain Android.
STOCK_PATTERN='^(com\.olaelectric\.|com\.ola\.|com\.quectel\.|com\.android\.hmiserverapp$)'

# Not an APK: the Go service behind port 50005. Pulled with --all.
DIAGNOSTICS_SERVER=/vendor/bin/diagnostics_server

sh() { adb -s "$DEV" shell "$@" | tr -d '\r'; }

# sha256sum on Linux and Git Bash, shasum on macOS.
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

echo "=== Connecting ==="
adb connect "$DEV" >/dev/null
adb -s "$DEV" wait-for-device

STOCK="$(sh pm list packages | sed 's/^package://' | sort | grep -E "$STOCK_PATTERN" || true)"
if [[ -z "$STOCK" ]]; then
  echo "no stock package found on $DEV: is this a scooter head unit?" >&2
  exit 1
fi

version_of() { sh dumpsys package "$1" | grep -m1 'versionName=' | sed 's/.*versionName=//'; }

mkdir -p "$OUT"
{
  echo "# Stock software on the scooter, read $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "moveos: $(sh cat /vendor/etc/SW_version.txt 2>/dev/null | head -1)"
  echo "vehicle-software: $( (sh cat /data/ola/vsw.txt 2>/dev/null || true) | head -1)"
  echo "android: $(sh getprop ro.build.version.release) sdk $(sh getprop ro.build.version.sdk)"
  echo
  for pkg in $STOCK; do
    echo "$pkg $(version_of "$pkg")"
  done
} > "$OUT/versions.txt"
echo "=== $(echo "$STOCK" | wc -l | tr -d ' ') stock packages, versions in $OUT/versions.txt ==="

if [[ $ALL == 1 ]]; then
  # The dashboard last: it is the big one.
  WANTED="$(echo "$STOCK" | grep -v '^com\.olaelectric\.hmiclient$' || true) $(echo "$STOCK" | grep '^com\.olaelectric\.hmiclient$' || true)"
else
  WANTED="${PACKAGES[*]}"
fi

missing=0
for pkg in $WANTED; do
  if ! echo "$STOCK" | grep -qx "$pkg"; then
    echo "  not on this scooter: $pkg"
    missing=$((missing + 1))
    continue
  fi
  path="$(sh pm path "$pkg" | sed 's/^package://' | grep -m1 '\.apk$' || true)"
  if [[ -z "$path" ]]; then
    echo "  no APK path for $pkg"
    missing=$((missing + 1))
    continue
  fi
  target="$OUT/$pkg-$(grep -m1 "^$pkg " "$OUT/versions.txt" | cut -d' ' -f2).apk"
  if [[ $DRY == 1 ]]; then
    echo "  would pull $pkg  ($path)"
    continue
  fi
  echo "  pulling $pkg"
  adb -s "$DEV" pull "$path" "$target" >/dev/null
  echo "$(sha256 "$target")  $(basename "$target")" >> "$OUT/sha256.txt"
done

if [[ $ALL == 1 ]]; then
  if [[ $DRY == 1 ]]; then
    echo "  would pull $DIAGNOSTICS_SERVER"
  elif adb -s "$DEV" pull "$DIAGNOSTICS_SERVER" "$OUT/diagnostics_server" >/dev/null 2>&1; then
    echo "  pulled diagnostics_server"
    echo "$(sha256 "$OUT/diagnostics_server")  diagnostics_server" >> "$OUT/sha256.txt"
  else
    echo "  could not pull $DIAGNOSTICS_SERVER"
  fi
fi

echo
if [[ $DRY == 1 ]]; then
  echo "Dry run: nothing pulled. Versions are in $OUT/versions.txt"
else
  echo "Done: $OUT"
  echo "To read one (keep the output out of git):"
  echo "  apktool d -f -o /tmp/hhmis $OUT/com.android.hmiserverapp-*.apk"
fi
[[ $missing == 0 ]] || echo "$missing wanted package(s) were not found; see above."
