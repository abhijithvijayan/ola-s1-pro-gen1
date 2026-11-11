#!/bin/bash
# revert-mfg-keys.sh — Restore the stock Manufacturing / Diagnostics public
# keys saved by scripts/swap-mfg-keys.sh.
#
# Reads from: local/mfg-keys/stock-originals/<basename>.pem
# Writes to:  /vendor/etc/ola/pub-keys/<basename>.pem (on the scooter)
#
# Idempotent: if the on-device key already matches the saved stock key,
# nothing is written. Fails loudly if a saved original is missing (we will
# not guess; recover it from a prior backup or a fresh unmodified scooter).
#
# Usage:
#   SCOOTER_IP=10.1.1.105 bash scripts/revert-mfg-keys.sh

set -euo pipefail

PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
SCOOTER="${SCOOTER_IP}:50005"
PROTO="wifican.proto"

STOCK_DIR="$PROTO_DIR/local/mfg-keys/stock-originals"
REMOTES=(
  /vendor/etc/ola/pub-keys/veh-totp-prod-pub-rsa.pem
  /vendor/etc/ola/pub-keys/mfg-otp-pub.pem
)

grpc() {
  grpcurl -plaintext -max-time 30 -max-msg-sz 67108864 \
    -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
    -d "{\"cmd_msg\": \"$1\"}" \
    "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('statusMsg',''))"
}

pull_raw() {
  local remote="$1"
  local blob
  blob=$(grpc "sh -c gzip\${IFS}-c\${IFS}$remote|base64\${IFS}-w0")
  python3 -c "
import base64, gzip, sys
sys.stdout.buffer.write(gzip.decompress(base64.b64decode('''$blob''')))
"
}

for remote in "${REMOTES[@]}"; do
  base="$(basename "$remote")"
  saved="$STOCK_DIR/$base"
  if [ ! -f "$saved" ]; then
    echo "ERROR: no saved stock key at $saved"
    echo "Recover it from a prior backup (see scripts/backup-stock-keys.sh output)"
    echo "or from an unmodified scooter before continuing."
    exit 1
  fi
done

needs_write=0
declare -A SAVED_MD5
for remote in "${REMOTES[@]}"; do
  base="$(basename "$remote")"
  saved="$STOCK_DIR/$base"
  saved_md5=$(openssl rsa -pubin -in "$saved" -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  cur_md5=$(pull_raw "$remote" 2>/dev/null | openssl rsa -pubin -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  SAVED_MD5[$remote]=$saved_md5
  if [ "$cur_md5" = "$saved_md5" ]; then
    echo "  $remote already matches the saved stock key"
  else
    echo "  $remote differs; will restore"
    needs_write=1
  fi
done

if [ "$needs_write" -eq 0 ]; then
  echo "Nothing to do."
  exit 0
fi

grpc "mount -o rw,remount /vendor" >/dev/null

for remote in "${REMOTES[@]}"; do
  base="$(basename "$remote")"
  saved="$STOCK_DIR/$base"
  blob=$(base64 < "$saved" | tr -d '\n')
  echo "  restoring $remote"
  grpc "sh -c echo\${IFS}$blob|base64\${IFS}-d>$remote" >/dev/null
  grpc "chmod 644 $remote" >/dev/null
  grpc "chown root:root $remote" >/dev/null 2>&1 || true
  cur_md5=$(pull_raw "$remote" | openssl rsa -pubin -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  if [ "$cur_md5" != "${SAVED_MD5[$remote]}" ]; then
    echo "  ERROR: verify failed for $remote"
    grpc "mount -o ro,remount /vendor" >/dev/null || true
    exit 1
  fi
done

grpc "mount -o ro,remount /vendor" >/dev/null
grpc "am force-stop com.olaelectric.hmiclient" >/dev/null

echo "Done. Stock keys restored."
