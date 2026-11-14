#!/usr/bin/env bash
# Print the simulator UDID behind a Simlock lease. Pass the device id that
# T3 Code's device_open returned for a device on the "Simlock" host; that id is
# the Simlock lease id.
#
#   scripts/simlock-udid.sh <device-id>
#
# Use the UDID with ios/scripts/reload.sh --simulator-id,
# scripts/mobile-dev-launch.sh --simulator-id and the other simulator scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ios-simlock.sh
source "$SCRIPT_DIR/lib/ios-simlock.sh"

case "${1:-}" in
  ""|-h|--help) sed -n '2,9p' "$0"; [[ -n "${1:-}" ]] && exit 0; exit 2 ;;
esac
command -v simlock >/dev/null 2>&1 || { echo "error: simlock is not installed (npm i -g simlock)" >&2; exit 2; }
cmux_simlock_lease_udid "$1"
