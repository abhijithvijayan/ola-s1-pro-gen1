#!/bin/bash
# swap-mfg-keys.sh — Replace the scooter's Manufacturing / Diagnostics QR
# encryption public keys with a locally-generated keypair, so the QRs HHMIC
# shows next can be decrypted with our private key.
#
# Context (see docs/scootermode-and-recovery.md):
#   HHMIC's hidden Manufacturing / Version-History keypad generates a random
#   6-digit OTP, embeds it in "Manufacturing$VIN$OTP$timestamp", encrypts the
#   payload with the public key at
#     /vendor/etc/ola/pub-keys/veh-totp-prod-pub-rsa.pem
#   and shows the ciphertext as a QR for the dealer tool to decrypt. If we
#   swap that public key for one we hold the private half of, we can decrypt
#   the QR ourselves and read the OTP back.
#
# What the script does, in order:
#   1. Pulls the current on-device keys via scripts/backup-stock-keys.sh so
#      there is always a fresh backup before the swap.
#   2. Ensures local/mfg-keys/<ours>.{key,pub} exists; generates a 2048-bit
#      RSA keypair if not. Re-runs reuse the same keypair.
#   3. Pulls the current on-device veh-totp-prod-pub-rsa.pem and mfg-otp-pub.pem
#      to local/mfg-keys/stock-originals/ IF those files aren't there yet.
#      This is the "protect the originals" guarantee: once we have saved the
#      stock key, we never overwrite that saved copy with what's currently on
#      the scooter (which after a run is our key, not the stock one).
#   4. If the on-device key already matches our key, re-swapping is a no-op.
#   5. Otherwise: remounts /vendor rw, writes our public key into both PEM
#      paths (mfg + veh-totp), chmod 644, remounts /vendor ro, force-stops
#      com.olaelectric.hmiclient so the next MFG popup opens with the new key.
#
# Idempotency: run as many times as you like. The stock originals are saved
# once on first run and never overwritten by this script; subsequent runs are
# no-ops or just re-apply our key if something restored it.
#
# Usage:
#   SCOOTER_IP=10.1.1.105 bash scripts/swap-mfg-keys.sh
#
# Side effects on the scooter:
#   - /vendor remounted briefly (rw -> write -> ro)
#   - two public keys under /vendor/etc/ola/pub-keys/ replaced
#   - com.olaelectric.hmiclient force-stopped (it respawns on its own)
#   - cloud / dealer tools can no longer decrypt this scooter's QRs until
#     the stock keys are restored (use revert-mfg-keys.sh)

set -euo pipefail

PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
SCOOTER="${SCOOTER_IP}:50005"
PROTO="wifican.proto"

LOCAL_DIR="$PROTO_DIR/local/mfg-keys"
OUR_KEY="$LOCAL_DIR/mfg.key"
OUR_PUB="$LOCAL_DIR/mfg.pub.pem"
STOCK_DIR="$LOCAL_DIR/stock-originals"

REMOTES=(
  /vendor/etc/ola/pub-keys/veh-totp-prod-pub-rsa.pem
  /vendor/etc/ola/pub-keys/mfg-otp-pub.pem
)

mkdir -p "$STOCK_DIR"

grpc() {
  grpcurl -plaintext -max-time 30 -max-msg-sz 67108864 \
    -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
    -d "{\"cmd_msg\": \"$1\"}" \
    "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('statusMsg',''))"
}

# Download a device file via base64 gzip; prints raw file contents to stdout.
pull_raw() {
  local remote="$1"
  local blob
  blob=$(grpc "sh -c gzip\${IFS}-c\${IFS}$remote|base64\${IFS}-w0")
  python3 -c "
import base64, gzip, sys
sys.stdout.buffer.write(gzip.decompress(base64.b64decode('''$blob''')))
"
}

echo "=== [1/5] Fresh read-only backup of all scooter keys"
SCOOTER_IP="$SCOOTER_IP" bash "$PROTO_DIR/scripts/backup-stock-keys.sh"

echo ""
echo "=== [2/5] Local keypair"
if [ -f "$OUR_KEY" ] && [ -f "$OUR_PUB" ]; then
  echo "Reusing $OUR_KEY (already present)"
else
  openssl genrsa -out "$OUR_KEY" 2048
  openssl rsa -in "$OUR_KEY" -pubout -out "$OUR_PUB"
  chmod 600 "$OUR_KEY"
  echo "Generated $OUR_KEY and $OUR_PUB"
fi
OUR_PUB_MD5=$(openssl rsa -in "$OUR_KEY" -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')

echo ""
echo "=== [3/5] One-time save of stock originals (never overwritten by re-runs)"
for remote in "${REMOTES[@]}"; do
  base="$(basename "$remote")"
  saved="$STOCK_DIR/$base"
  if [ -f "$saved" ]; then
    echo "  keeping $saved (already saved; will not overwrite)"
    continue
  fi
  echo "  pulling $remote -> $saved"
  pull_raw "$remote" > "$saved"
  if ! head -1 "$saved" | grep -q "BEGIN PUBLIC KEY"; then
    echo "  WARNING: $saved does not look like a PEM public key; removing"
    rm -f "$saved"
    exit 1
  fi
  # Sanity: refuse to save a stock copy that is already our key (would mean
  # someone ran us before without saving; we must not treat our key as stock).
  saved_md5=$(openssl rsa -pubin -in "$saved" -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  if [ "$saved_md5" = "$OUR_PUB_MD5" ]; then
    echo "  REFUSING to save: $remote is already our key, not a stock key."
    echo "  Restore the stock key first (or copy the original PEM into $saved manually)."
    rm -f "$saved"
    exit 1
  fi
done

echo ""
echo "=== [4/5] Skip if already swapped"
needs_swap=0
for remote in "${REMOTES[@]}"; do
  cur_md5=$(pull_raw "$remote" 2>/dev/null | openssl rsa -pubin -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  if [ "$cur_md5" = "$OUR_PUB_MD5" ]; then
    echo "  $remote already matches our key"
  else
    echo "  $remote differs; will swap"
    needs_swap=1
  fi
done

if [ "$needs_swap" -eq 0 ]; then
  echo ""
  echo "All target keys are already ours. Nothing to do."
  echo "Our private key: $OUR_KEY"
  exit 0
fi

echo ""
echo "=== [5/5] Swap on /vendor"
PUB_B64=$(base64 < "$OUR_PUB" | tr -d '\n')

grpc "mount -o rw,remount /vendor" >/dev/null

for remote in "${REMOTES[@]}"; do
  echo "  writing $remote"
  # Write via base64 pipe to avoid quoting issues with PEM linebreaks.
  grpc "sh -c echo\${IFS}$PUB_B64|base64\${IFS}-d>$remote" >/dev/null
  grpc "chmod 644 $remote" >/dev/null
  grpc "chown root:root $remote" >/dev/null 2>&1 || true
  cur_md5=$(pull_raw "$remote" | openssl rsa -pubin -pubout 2>/dev/null | openssl md5 | awk '{print $NF}')
  if [ "$cur_md5" != "$OUR_PUB_MD5" ]; then
    echo "  ERROR: verify failed for $remote (md5 $cur_md5 != $OUR_PUB_MD5)"
    grpc "mount -o ro,remount /vendor" >/dev/null || true
    exit 1
  fi
done

grpc "mount -o ro,remount /vendor" >/dev/null

echo "  force-stopping com.olaelectric.hmiclient"
grpc "am force-stop com.olaelectric.hmiclient" >/dev/null

echo ""
echo "Done. HHMIC will now encrypt Manufacturing QRs with the key in"
echo "  $OUR_PUB"
echo "Decrypt a scanned QR with the matching private key:"
echo "  $OUR_KEY"
echo ""
echo "To restore the stock keys, run scripts/revert-mfg-keys.sh."
