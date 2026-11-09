#!/bin/bash
# fix-stock-screen.sh — Recover from a stock-dashboard white screen or Doze stall.
#
# Symptoms this fixes:
#   - Stock dashboard shows white / blank screen after reboot or sleep
#   - Tapping the physical button wakes the display but HHMIC stays blank
#   - logcat shows Kanzi "haltApplication: requested" + "libEGL: no current context"
#
# What it does, all over gRPC to diagnostics_server on port 50005 (no ADB needed):
#   1. Wake the display (KEYCODE_WAKEUP)
#   2. Disable the screensaver and set display timeout to essentially never
#      (both reset on reboot; re-run after each power cycle if desired)
#   3. Force-stop HHMIC and relaunch it via the HOME intent so Android hands
#      it a fresh Surface and Kanzi's render thread can resume
#
# Usage:
#   SCOOTER_IP=10.1.1.105 bash scripts/fix-stock-screen.sh
#
# Environment:
#   SCOOTER_IP — head unit IP (required)
#
# Requires grpcurl; does not require ADB to be authorised. The script does
# not touch persist.ola.security.scootermode and does not change iptables.
# See docs/scootermode-and-recovery.md for the full story.

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

echo "=== Stock dashboard recovery ==="
echo "Target: $SCOOTER"
echo ""

echo "[1/5] Waking display..."
grpc "input keyevent KEYCODE_WAKEUP"

echo "[2/5] Disabling screensaver..."
grpc "settings put secure screensaver_enabled 0"

echo "[3/5] Setting screen-off timeout to effectively never..."
grpc "settings put system screen_off_timeout 2147483647"

echo "[4/5] Force-stopping stock dashboard (HHMIC)..."
grpc "am force-stop com.olaelectric.hmiclient"
sleep 1

echo "[5/5] Relaunching via HOME intent (lets Android create a fresh Surface)..."
grpc "sh -c am\${IFS}start\${IFS}-a\${IFS}android.intent.action.MAIN\${IFS}-c\${IFS}android.intent.category.HOME"

echo ""
echo "=== Done ==="
echo ""
echo "If the screen is still blank after a few seconds, try a full reboot:"
echo "  grpcurl -plaintext -d '{\"cmd_msg\":\"reboot\"}' $SCOOTER wifican.WifiCanRpc/ExecuteADBCommand"
