# shellcheck shell=bash
# iOS simulators come from the Simlock pool, never from Xcode's default device
# set. A simulator is leased through T3 Code's `device_open` on the host named
# "Simlock" (`device_list` shows it), and handed back with `device_close`.
# Simlock keeps its simulators in a device set of its own, so plain
# `xcrun simctl <cmd> <udid>` answers "Invalid device": every simctl call for a
# leased simulator goes through `simlock simctl`, which refuses create, erase,
# delete and any option before the subcommand.
#
# GitHub Actions runners have no Simlock. There (GITHUB_ACTIONS=true) the
# callers keep their default-set behavior; everywhere else they require a
# Simlock UDID.

CMUX_SIMLOCK_IOS_SET="${SIMLOCK_IOS_DEVICE_SET:-$HOME/.simlock/devices/ios}"

# cmux_simlock_ci_default_set: true only on a GitHub Actions runner.
cmux_simlock_ci_default_set() {
  [[ "${GITHUB_ACTIONS:-}" == "true" ]]
}

# cmux_simlock_is_udid <udid>: the UDID names a simulator in Simlock's set.
cmux_simlock_is_udid() {
  local udid="${1:-}"
  [[ "$udid" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]] \
    && [[ -d "$CMUX_SIMLOCK_IOS_SET/$udid" ]]
}

# cmux_simlock_is_booted <udid>: read-only check against Simlock's set.
cmux_simlock_is_booted() {
  local udid="${1:?udid is required}"
  xcrun simctl --set "$CMUX_SIMLOCK_IOS_SET" list devices booted -j 2>/dev/null \
    | UDID="$udid" /usr/bin/python3 -c '
import json, os, sys
udid = os.environ["UDID"].upper()
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(1)
for devices in data.get("devices", {}).values():
    for device in devices:
        if device.get("udid", "").upper() == udid and device.get("state") == "Booted":
            raise SystemExit(0)
raise SystemExit(1)
'
}

# cmux_simlock_lease_help [flag]: how to get a Simlock UDID, on stderr.
cmux_simlock_lease_help() {
  local flag="${1:---simulator-id}"
  cat >&2 <<EOF
Lease an iOS simulator from Simlock first:
  1. T3 Code: device_list, then device_open on the "Simlock" host (platform ios).
  2. Turn the T3 device id into the simulator UDID:
       scripts/simlock-udid.sh <device id from device_open>
  3. Pass it: $flag <UDID>
Never create, boot or reuse a simulator from Xcode's default set.
Give the simulator back with device_close when you are done.
EOF
}

# cmux_simlock_require_udid <udid> [flag]: fails unless the UDID is a booted
# Simlock simulator. Prints the lease steps on failure.
cmux_simlock_require_udid() {
  local udid="${1:-}" flag="${2:---simulator-id}"
  if [[ -z "$udid" ]]; then
    echo "error: no Simlock simulator given" >&2
    cmux_simlock_lease_help "$flag"
    return 2
  fi
  if ! command -v simlock >/dev/null 2>&1; then
    echo "error: simlock is not installed (npm i -g simlock)" >&2
    return 2
  fi
  if ! cmux_simlock_is_udid "$udid"; then
    echo "error: $udid is not a Simlock simulator (no $CMUX_SIMLOCK_IOS_SET/$udid)" >&2
    cmux_simlock_lease_help "$flag"
    return 2
  fi
  if ! cmux_simlock_is_booted "$udid"; then
    echo "error: Simlock simulator $udid is not booted. Is the lease still open, or still starting? Retry in a few seconds, or lease again." >&2
    return 1
  fi
}

# cmux_simctl <udid> <subcommand> [args...]: simctl for one simulator. A Simlock
# UDID goes through `simlock simctl`; a default-set UDID is allowed only on CI.
cmux_simctl() {
  local udid="${1:?udid is required}"
  shift
  if cmux_simlock_is_udid "$udid"; then
    simlock simctl "$@"
  elif cmux_simlock_ci_default_set; then
    xcrun simctl "$@"
  else
    echo "error: refusing simctl $1 on $udid: not a Simlock simulator" >&2
    cmux_simlock_lease_help
    return 2
  fi
}

# cmux_simlock_xcodebuild_destination <udid>: fills CMUX_SIMLOCK_DESTINATION_ARGS
# with the xcodebuild arguments that target the leased simulator. Xcode 27 and
# later can address Simlock's set directly; older Xcode builds for a generic
# simulator of this Mac's architecture only (a generic destination otherwise
# builds every simulator architecture), and the caller installs with
# `simlock simctl install`.
cmux_simlock_xcodebuild_destination() {
  local udid="${1:?udid is required}" major
  major="$(xcodebuild -version 2>/dev/null | awk '/^Xcode / { split($2, v, "."); print v[1]; exit }')"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 27 )); then
    CMUX_SIMLOCK_DESTINATION_ARGS=(
      "-DVTSimulatorSetLocation=$CMUX_SIMLOCK_IOS_SET"
      -destination "platform=iOS Simulator,id=$udid"
    )
  else
    CMUX_SIMLOCK_DESTINATION_ARGS=(-destination "generic/platform=iOS Simulator" "ARCHS=$(uname -m)")
  fi
}

# cmux_simlock_lease_udid <t3-device-id>: T3's device id for a Simlock device
# is the lease id. The gateway maps it to Simlock's device, and `simlock list`
# maps that device to its simulator UDID.
cmux_simlock_lease_udid() {
  local lease="${1:?T3 device id is required}" device udid
  device="$({ simlock --gateway status --json 2>/dev/null || true; } | LEASE="$lease" /usr/bin/python3 -c '
import json, os, sys
lease = os.environ["LEASE"]
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
for entry in data.get("leases", []):
    if entry.get("id") == lease:
        print(entry.get("deviceId", ""))
        break
')"
  if [[ -z "$device" ]]; then
    echo "error: no Simlock lease $lease (or the Simlock gateway did not answer). Open the device with T3 device_open first." >&2
    return 1
  fi
  udid="$({ simlock list 2>/dev/null || true; } | DEVICE="$device" /usr/bin/python3 -c '
import json, os, sys
device = os.environ["DEVICE"]
try:
    data = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
for entry in data:
    if entry.get("id") == device:
        print(entry.get("address") or (entry.get("driverData") or {}).get("udid") or entry.get("driverDeviceId") or "")
        break
')"
  if [[ ! "$udid" =~ ^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$ ]]; then
    echo "error: lease $lease has no simulator UDID yet (device $device). Is it still booting? Retry in a few seconds." >&2
    return 1
  fi
  printf '%s\n' "$udid"
}
