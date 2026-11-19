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
#   5. Sets persist/service.adb.tcp.port=5555 so adbd listens on TCP
#   6. Restarts adbd with `ctl.restart` (not stop/start, which leaves it in
#      USB mode) and waits for it to listen on 5555
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

# The command's stdout (ExecuteADBCommand returns it in statusMsg), for
# reading device state. The command is sent verbatim; a pipeline must be
# written as `sh -c ...` with ${IFS} in place of spaces, since the daemon
# splits the message on whitespace (see the ${IFS} note above).
grpc_out() {
  grpcurl -plaintext \
    -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
    -d "{\"cmd_msg\": \"$1\"}" \
    "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand 2>/dev/null \
    | sed -n 's/.*"statusMsg": "\(.*\)"/\1/p'
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
# Both: service.* is the live lever adbd reads at (re)start, persist.* keeps
# it across a reboot.
grpc "setprop persist.adb.tcp.port 5555"
grpc "setprop service.adb.tcp.port 5555"

echo "[6/6] Restarting adbd on the TCP port..."
# `stop adbd; start adbd` leaves adbd running in USB mode on this build — it
# comes back without binding TCP, so `adb connect :5555` is refused though
# the port property is set and the firewall accepts 5555. `ctl.restart`
# forces init to re-exec adbd, which then reads service.adb.tcp.port and
# listens on TCP.
grpc "setprop ctl.restart adbd"

echo ""
echo "Waiting for adbd to listen on 5555..."
listening=""
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  # Grep on the device (statusMsg comes back as one escaped-newline line, so
  # host-side line matching does not work): count LISTEN sockets (state 0A)
  # on local port 15B3 (5555), IPv4 or IPv6. A non-zero count means bound.
  # ${IFS} is literal here (single quotes) and is expanded on the device.
  case "$(grpc_out 'sh -c cat${IFS}/proc/net/tcp${IFS}/proc/net/tcp6|grep${IFS}-c${IFS}-iE${IFS}:15B3.*0A')" in
    *[1-9]*) listening="yes"; break ;;
  esac
done

echo ""
if [ -n "$listening" ]; then
  echo "=== Done: adbd is listening on 5555 ==="
else
  echo "=== Done, but adbd is NOT listening on 5555 yet ==="
  echo "Re-run this script, or restart adbd again:"
  echo "  grpcurl ... -d '{\"cmd_msg\":\"setprop ctl.restart adbd\"}' ${SCOOTER} wifican.WifiCanRpc/ExecuteADBCommand"
  echo "If it still refuses, the build may gate Wi-Fi ADB; use USB-C ADB"
  echo "(docs/opening-sealed-scooter.md, scootermode-and-recovery.md)."
fi
echo ""
echo "Connect with:  adb connect ${SCOOTER_IP}:5555"
echo "Verify with:   adb -s ${SCOOTER_IP}:5555 shell id"
echo ""
echo "To revert:     bash scripts/revert-adb-key.sh"
