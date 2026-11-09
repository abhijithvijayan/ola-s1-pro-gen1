#!/bin/bash
# disable-ota.sh — Block OTA firmware updates without disabling the OTA app.
#
# WARNING: Do NOT use `pm disable` on com.olaelectric.ota. The health service
# (HOHS) runs a watchdog every 10 minutes that reboots the head unit if the
# OTA process is not running. See research/reboot-analysis.md.
#
# Instead, this script blocks the OTA download server via iptables so the app
# runs but can never fetch an update. Fully reversible with enable-ota.sh.
#
# Requires: ADB connection to the scooter
#
# Usage:
#   SCOOTER_IP=<your-ip> bash scripts/disable-ota.sh

set -euo pipefail

SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
ADB="adb -s ${SCOOTER_IP}:5555"

# Known OTA-related hostnames (resolved from the OTA app's network traffic).
# Block outbound connections to these so the OTA app can't download updates.
OTA_HOSTS=(
  "ota.olaelectric.com"
  "ota-cdn.olaelectric.com"
)

echo "=== Blocking OTA Updates ==="
echo "Target: ${SCOOTER_IP}:5555"
echo ""
echo "NOTE: The OTA app stays running (HOHS watchdog requires it)."
echo "      We block its server connections via iptables instead."
echo ""

echo "[1/3] Checking current state..."
UE_STATE=$($ADB shell getprop init.svc.update_engine 2>&1)
echo "  update_engine: $UE_STATE"
echo ""

echo "[2/3] Adding iptables rules to block OTA servers..."
for host in "${OTA_HOSTS[@]}"; do
  echo "  Blocking $host"
  $ADB shell iptables -C OUTPUT -d "$host" -j DROP 2>/dev/null \
    && echo "    (rule already exists)" \
    || $ADB shell iptables -A OUTPUT -d "$host" -j DROP 2>&1
done
echo ""

echo "[3/3] Stopping update_engine (will restart on reboot but has nothing to apply)..."
$ADB shell setprop ctl.stop update_engine
sleep 1
echo ""

echo "=== OTA blocked ==="
echo ""
echo "The OTA app is still running (keeps the HOHS watchdog happy) but"
echo "cannot reach Ola's update servers. iptables rules do not persist"
echo "across reboots — re-run this script after each reboot, or add the"
echo "rules to an init script for persistence."
echo ""
echo "To re-enable: bash scripts/enable-ota.sh"
