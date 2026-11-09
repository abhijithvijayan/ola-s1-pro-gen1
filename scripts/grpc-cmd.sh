#!/bin/bash
# grpc-cmd.sh — Run a root command on the Ola S1 Pro Gen 1 head unit via gRPC.
#
# Usage:
#   bash scripts/grpc-cmd.sh "id"
#   bash scripts/grpc-cmd.sh "getprop ro.build.display.id"
#   bash scripts/grpc-cmd.sh "ls /data/ola"
#
# For commands with pipes/redirects, use the ${IFS} trick:
#   bash scripts/grpc-cmd.sh 'sh -c echo${IFS}hello|grep${IFS}hello'
#
# Environment:
#   SCOOTER_IP — head unit IP (default: discover via ARP, or set manually)

set -euo pipefail

PROTO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCOOTER_IP="${SCOOTER_IP:?Set SCOOTER_IP to the scooter IP address}"
SCOOTER="${SCOOTER_IP}:50005"
PROTO="wifican.proto"

if [ $# -eq 0 ]; then
  echo "Usage: $0 \"command\""
  echo ""
  echo "Examples:"
  echo "  $0 \"id\"                              # check uid (should be root)"
  echo "  $0 \"getprop ro.build.display.id\"      # Android build ID"
  echo "  $0 \"cat /proc/cpuinfo\"                # CPU info"
  echo "  $0 \"wm size\"                          # screen resolution"
  echo "  $0 \"pm list packages -s\"              # system packages"
  exit 1
fi

CMD="$1"

grpcurl -plaintext \
  -import-path "$PROTO_DIR/proto" -proto "$PROTO" \
  -d "{\"cmd_msg\": \"$CMD\"}" \
  "$SCOOTER" wifican.WifiCanRpc/ExecuteADBCommand
