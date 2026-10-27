#!/bin/bash
# On-device smoke test. OPT-IN: runs real caffeinate and reads real pmset.
# It never uses sudo and never changes pmset settings. It does NOT test the lid.
# Usage: MAC_AWAKE_ONDEVICE=1 tests/ondevice/run.sh
set -u
if [ "${MAC_AWAKE_ONDEVICE:-0}" != 1 ]; then
  echo "Skipped: set MAC_AWAKE_ONDEVICE=1 to run real on-device checks (see README)."
  exit 0
fi
SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/scripts/mac-awake.sh"
export MAC_AWAKE_STATE_DIR
MAC_AWAKE_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mac-awake-ondevice.XXXXXX")"
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
before="$(pmset -g | awk '$1=="SleepDisabled"{print $2}')"

expect() { # expect DESC CMD... : ok if CMD succeeds
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
expect_not() { # expect_not DESC CMD... : ok if CMD fails
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi
}
asserted() { pmset -g assertions | grep -q "pid $1(caffeinate)"; }
status_active() { /bin/bash "$SCRIPT" status | grep -q ACTIVE; }

expect "session started" /bin/bash "$SCRIPT" start --yes --duration 120
sleep 1
cpid="$(sed -n 's/^caffeinate_pid=//p' "$MAC_AWAKE_STATE_DIR/session.state")"
expect "caffeinate's real power assertion is visible in pmset -g assertions" asserted "$cpid"
expect "status reports ACTIVE" status_active
expect "stop succeeded" /bin/bash "$SCRIPT" stop
sleep 1
expect_not "caffeinate process gone" kill -0 "$cpid"
expect_not "power assertion released" asserted "$cpid"
after="$(pmset -g | awk '$1=="SleepDisabled"{print $2}')"
if [ "$before" = "$after" ]; then ok "SleepDisabled unchanged (${after:-unset})"; else bad "SleepDisabled changed: $before -> $after"; fi
rm -rf "$MAC_AWAKE_STATE_DIR"
echo "failures: $fails"
[ "$fails" -eq 0 ]
