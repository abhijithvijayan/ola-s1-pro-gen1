#!/bin/bash
# backup-stock-keys.sh — Pull the stock cryptographic material off the scooter
# into a local backup directory, read-only. Safe to run on any build that lets
# you reach the root gRPC port.
#
# What it pulls:
#   /vendor/etc/ola/pub-keys/veh-totp-prod-pub-rsa.pem   (QR encryption pub key)
#   /vendor/etc/ola/pub-keys/mfg-otp-pub.pem             (MFG OTP pub key)
#   /vendor/etc/ola/pub-keys/OEM_Boot_Key_pub.pem        (bootloader pub key)
#   /vendor/etc/ola/pub-keys/OEM_FOTA_Final_public.pem   (FOTA release pub key)
#   /vendor/etc/ola/pub-keys/OEM_FOTA_pre_public.pem     (FOTA preprod pub key)
#   /data/misc/adb/adb_keys                              (authorised ADB keys)
#   /data/misc/adb/adb_keys.bak                          (stock adb_keys backup, if present)
#   /vendor/etc/adbkey.pub                               (vendor-baked ADB pub)
#   /vendor/etc/adbkeymoveos3_pub_prod.pub               (vendor-baked ADB pub, prod)
#
# Output:
#   backups/scooter-keys-<host>-<timestamp>/
#     vendor/etc/ola/pub-keys/*.pem
#     data/misc/adb/adb_keys{,.bak}
#     vendor/etc/adbkey{,moveos3_pub_prod}.pub
#     MANIFEST.txt        (sha256 + original on-device path for every file)
#
# The backup tree mirrors the on-device layout, so a future restore knows the
# exact destination for each file without a lookup. The MANIFEST pins contents
# by SHA-256; if the stock keys ever change (firmware update), diffing two
# backups surfaces it.
#
# Usage:
#   SCOOTER_IP=10.1.1.105 bash scripts/backup-stock-keys.sh
#   SCOOTER_IP=10.1.1.105 bash scripts/backup-stock-keys.sh custom/output/dir
#
# Nothing is written to the scooter. Safe to re-run; each run makes a new
# timestamped directory.

set -euo pipefail

PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
SCOOTER="${SCOOTER_IP}:50005"
PROTO="wifican.proto"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="${1:-$PROTO_DIR/backups/scooter-keys-${SCOOTER_IP//./_}-$STAMP}"

# Files to pull, as device-paths. The backup tree mirrors this layout under
# $OUT_DIR, so a restore script can read from $OUT_DIR/<device-path> and write
# back to <device-path> directly.
FILES=(
  /vendor/etc/ola/pub-keys/veh-totp-prod-pub-rsa.pem
  /vendor/etc/ola/pub-keys/mfg-otp-pub.pem
  /vendor/etc/ola/pub-keys/OEM_Boot_Key_pub.pem
  /vendor/etc/ola/pub-keys/OEM_FOTA_Final_public.pem
  /vendor/etc/ola/pub-keys/OEM_FOTA_pre_public.pem
  /data/misc/adb/adb_keys
  /data/misc/adb/adb_keys.bak
  /vendor/etc/adbkey.pub
  /vendor/etc/adbkeymoveos3_pub_prod.pub
)

mkdir -p "$OUT_DIR"
MANIFEST="$OUT_DIR/MANIFEST.txt"
: > "$MANIFEST"

# Pull a file over gRPC by base64-gzip of the file contents, then decode
# locally. Keeps binary-safe transport and avoids writing anything to the
# scooter. Missing files are skipped and recorded as such in the manifest.
pull() {
  local remote="$1"
  local local_path="$OUT_DIR${remote}"
  mkdir -p "$(dirname "$local_path")"

  # First check the file exists; stat prints a header-only line on success,
  # the error goes to statusMsg on failure.
  # ls on the device's root shell splits on whitespace; the file paths we care
  # about have none, so an unquoted ls is safe. A missing file produces
  # "ls: <path>: No such file or directory" via statusMsg.
  local stat_resp
  stat_resp=$(
    grpcurl -plaintext -max-time 15 \
      -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
      -d "{\"cmd_msg\": \"ls $remote\"}" \
      "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand 2>/dev/null \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('statusMsg',''))"
  )
  if [[ "$stat_resp" == *"No such file"* ]] || [[ -z "$stat_resp" ]]; then
    printf 'MISSING  %s\n' "$remote" | tee -a "$MANIFEST"
    return 0
  fi

  # Pull. ${IFS} keeps the pipeline as a single whitespace-split token for
  # the on-device shell.
  local blob
  blob=$(
    grpcurl -plaintext -max-time 60 -max-msg-sz 67108864 \
      -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
      -d "{\"cmd_msg\": \"sh -c gzip\${IFS}-c\${IFS}$remote|base64\${IFS}-w0\"}" \
      "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('statusMsg',''))"
  )
  if [ -z "$blob" ]; then
    printf 'MISSING  %s\n' "$remote" | tee -a "$MANIFEST"
    return 0
  fi

  python3 -c "
import base64, gzip, sys
open('$local_path','wb').write(gzip.decompress(base64.b64decode('''$blob''')))
"
  local sha
  sha=$(shasum -a 256 "$local_path" | awk '{print $1}')
  printf 'OK       %s  sha256=%s  size=%s\n' \
    "$remote" "$sha" "$(stat -f%z "$local_path" 2>/dev/null || stat -c%s "$local_path")" \
    | tee -a "$MANIFEST"
}

# Device fingerprint: the backup is only meaningful if you can tell which
# scooter and which build it came from. If any of the PEMs change across a
# MoveOS release, diffing two backups' README + MANIFEST surfaces it.
read_prop() {
  grpcurl -plaintext -max-time 10 \
    -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
    -d "{\"cmd_msg\": \"getprop $1\"}" \
    "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('statusMsg','').strip())"
}

echo "=== Backing up scooter keys from $SCOOTER into $OUT_DIR"
for f in "${FILES[@]}"; do
  pull "$f"
done

README="$OUT_DIR/README.md"
{
  echo "# Scooter key backup"
  echo ""
  echo "- Pulled: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- Scooter IP: $SCOOTER_IP"
  echo "- Script: scripts/backup-stock-keys.sh"
  echo ""
  echo "## Device fingerprint"
  echo ""
  echo "| Property | Value |"
  echo "|---|---|"
  for p in \
    ro.build.display.id \
    ro.build.fingerprint \
    ro.vendor.build.fingerprint \
    ro.product.name \
    ro.product.model \
    ro.product.device \
    ro.build.version.release \
    ro.build.version.sdk \
    ro.build.version.incremental \
    ro.boot.serialno \
    ro.serialno \
    persist.ola.security.scootermode \
    ro.ola.moveos.version
  do
    val=$(read_prop "$p")
    [ -n "$val" ] && printf '| `%s` | `%s` |\n' "$p" "$val"
  done
  echo ""
  echo "## Files"
  echo ""
  echo "See MANIFEST.txt for SHA-256 and sizes. The tree mirrors the on-device"
  echo "layout: a restore writes \`<out>/<device-path>\` back to \`<device-path>\`."
  echo ""
  echo "Note on \`data/misc/adb/\`:"
  echo ""
  echo "- \`adb_keys\` is the currently authorised set. On a stock scooter this"
  echo "  equals \`vendor/etc/adbkey.pub\`."
  echo "- \`adb_keys.bak\` is written by \`inject-adb-key.sh\` before it appends"
  echo "  the laptop key. It is NOT a stock file; it is the previous"
  echo "  \`adb_keys\` snapshot from a prior inject run."
} > "$README"

echo ""
echo "Backup complete:"
echo "  $OUT_DIR"
echo ""
echo "Review README.md + MANIFEST.txt, then move the directory into your"
echo "private store. Nothing was written to the scooter."
