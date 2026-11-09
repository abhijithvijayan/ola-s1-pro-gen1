#!/bin/bash
# revert-adb-key.sh — Restore the original adb_keys from the backup made during injection.
#
# Usage:
#   bash scripts/revert-adb-key.sh
#
# Environment:
#   SCOOTER_IP — head unit IP (required, e.g. 192.168.1.100)

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

echo "=== Reverting ADB Key Injection ==="

echo "[1/3] Restoring backup..."
grpc "cp /data/misc/adb/adb_keys.bak /data/misc/adb/adb_keys"

echo "[2/3] Restarting adbd..."
grpc "stop adbd"
sleep 1
grpc "start adbd"

echo "[3/3] Verifying..."
grpc "wc -c /data/misc/adb/adb_keys"

echo ""
echo "=== Original keys restored. ADB access from your laptop is now revoked. ==="
