#!/bin/bash
# enable-ota.sh — Re-enable OTA firmware updates.
#
# Reverses scripts/disable-ota.sh: removes the iptables blocks on OTA servers
# and restarts update_engine. Also re-enables the OTA app if it was disabled
# by the old version of disable-ota.sh.
#
# Requires: ADB connection to the scooter
#
# Usage:
#   SCOOTER_IP=<your-ip> bash scripts/enable-ota.sh

set -euo pipefail

SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
ADB="adb -s ${SCOOTER_IP}:5555"

OTA_HOSTS=(
  "ota.olaelectric.com"
  "ota-cdn.olaelectric.com"
)

echo "=== Re-enabling OTA Updates ==="
echo "Target: ${SCOOTER_IP}:5555"
echo ""

echo "[1/4] Re-enabling com.olaelectric.ota (in case it was disabled)..."
$ADB shell pm enable com.olaelectric.ota
echo ""

echo "[2/4] Removing iptables blocks on OTA servers..."
for host in "${OTA_HOSTS[@]}"; do
  echo "  Unblocking $host"
  $ADB shell iptables -D OUTPUT -d "$host" -j DROP 2>/dev/null \
    && echo "    (removed)" \
    || echo "    (no rule to remove)"
done
echo ""

echo "[3/4] Starting update_engine..."
$ADB shell setprop ctl.start update_engine
sleep 1
echo ""

echo "[4/4] Verifying..."
STATE=$($ADB shell pm dump com.olaelectric.ota 2>&1 | grep "enabled=" | head -1 | grep -oE 'enabled=[0-9]+' || echo "enabled=unknown")
echo "  com.olaelectric.ota: $STATE (0 = default/enabled)"
UE_STATE=$($ADB shell getprop init.svc.update_engine 2>&1)
echo "  update_engine: $UE_STATE"
echo ""

echo "=== OTA re-enabled ==="
