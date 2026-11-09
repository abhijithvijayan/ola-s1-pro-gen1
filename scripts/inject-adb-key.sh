#!/bin/bash
# inject-adb-key.sh — Append your local ADB public key to the scooter's authorized keys.
#
# This enables `adb connect <scooter-ip>:5555` for interactive shell, fast file
# transfer, scrcpy screen mirroring, and logcat.
#
# What it does:
#   1. Backs up existing /data/misc/adb/adb_keys
#   2. Adds a trailing newline (existing file may not have one)
#   3. Base64-encodes your ~/.android/adbkey.pub (so it's a single space-free token)
#   4. Sends it over gRPC, decoded and appended on the device
#   5. Sets service.adb.tcp.port=5555 so adbd restarts in TCP mode
#   6. Restarts adbd to pick up the new key and the TCP port
#
# The ${IFS} trick: the gRPC daemon splits arguments on whitespace.
# Replacing spaces with the literal text ${IFS} keeps the whole sh -c
# command as one token through the split; sh on the device then expands
# ${IFS} back to spaces. It must reach the device unexpanded, hence the
# \${IFS} escapes below: expanded locally it is space+tab+newline, which is
# not valid inside a JSON string and grpcurl refuses it.
#
# Usage:
#   bash scripts/inject-adb-key.sh
#
# Environment:
#   SCOOTER_IP — head unit IP (required, e.g. 192.168.1.100)
#
# Note: ADB key does NOT survive reboot. key_copy overwrites
# /data/misc/adb/adb_keys at every boot. Re-run this script after
# each reboot (gRPC root is always available).
#
# After running:
#   adb connect <scooter-ip>:5555

set -euo pipefail

PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
SCOOTER="${SCOOTER_IP}:50005"
PROTO="wifican.proto"

grpc() {
  grpcurl -plaintext \
    -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
    -d "{\"cmd_msg\": \"$1\"}" \
    "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand
}

if [ ! -f ~/.android/adbkey.pub ]; then
  echo "Error: ~/.android/adbkey.pub not found."
  echo "Run 'adb start-server' first to generate your ADB keypair."
  exit 1
fi

echo "=== ADB Key Injection for Ola S1 Pro Gen 1 ==="
echo "Target: $SCOOTER"
echo ""

echo "[1/6] Backing up existing adb_keys (only if no .bak yet)..."
# Idempotent — a repeat run without a reboot must not overwrite .bak with a
# file that already contains our key, or revert-adb-key.sh will no longer
# restore stock.
grpc "sh -c [\${IFS}-f\${IFS}/data/misc/adb/adb_keys.bak\${IFS}]||cp\${IFS}/data/misc/adb/adb_keys\${IFS}/data/misc/adb/adb_keys.bak"

echo "[2/6] Adding newline separator..."
grpc "sh -c echo>>/data/misc/adb/adb_keys"

echo "[3/6] Encoding local ADB key..."
ENCODED=$(base64 < ~/.android/adbkey.pub | tr -d '\n')
# A grep-safe marker from the pubkey body — alphanumerics only, so no `+`
# or `/` to escape through the shell and through grep.
MARKER=$(awk '{print $2}' ~/.android/adbkey.pub | tr -d '+/=' | cut -c20-39)
echo "  Key: ${#ENCODED} chars encoded, marker ${MARKER:0:12}…"

echo "[4/6] Appending key (only if not already present)..."
CMD="sh -c grep\${IFS}-q\${IFS}${MARKER}\${IFS}/data/misc/adb/adb_keys||echo\${IFS}${ENCODED}|base64\${IFS}-d>>/data/misc/adb/adb_keys"
grpc "$CMD"

echo "[5/6] Enabling TCP mode on adbd..."
grpc "setprop service.adb.tcp.port 5555"

echo "[6/6] Restarting adbd..."
grpc "stop adbd"
sleep 1
grpc "start adbd"

echo ""
echo "=== Done ==="
echo ""
echo "Connect with:  adb connect ${SCOOTER_IP}:5555"
echo "Verify with:   adb -s ${SCOOTER_IP}:5555 shell id"
echo ""
echo "To revert:     bash scripts/revert-adb-key.sh"
