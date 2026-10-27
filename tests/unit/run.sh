#!/bin/bash
# Unit tests for mac-awake. All system commands are mocked; no real power settings change.
# Usage: tests/unit/run.sh [test_name ...]
# shellcheck disable=SC2016,SC2009  # mock bodies are single-quoted on purpose
set -u
# shellcheck source=../helpers.sh
. "$(dirname "$0")/../helpers.sh"

start_ok() { run start --yes "$@"; }

t_help_and_args() {
  run help
  assert_rc "help succeeds" 0
  assert_out "help lists start" "start"
  assert_out "help lists lid-test" "lid-test"
  run
  assert_rc "no args prints help" 0
  run bogus
  assert_rc "unknown command" 2
  run start --duration abc
  assert_rc "bad duration" 2
  run start --duration 99d
  assert_rc "bad duration suffix" 2
  run start --duration 999h
  assert_rc "duration over max" 2
  run start --nope
  assert_rc "unknown start option" 2
  run stop extra
  assert_rc "stop rejects arguments" 2
  run start --duration
  assert_rc "missing duration value" 2
  run lid-test
  assert_rc "lid-test needs subcommand" 2
}

t_start_requires_approval() {
  run start
  assert_rc "start without --yes refuses" 2
  assert_out "plan is printed" "Plan:"
  assert_out "plan states lid is unverified" "unless 'lid-test' proves it"
  assert_no_file "no caffeinate launched" "$MOCK_DIR/caffeinate.args"
  run start --dry-run --disablesleep
  assert_rc "dry-run succeeds" 0
  assert_out "dry-run shows experiment" "EXPERIMENT"
  assert_no_file "dry-run starts nothing" "$MOCK_DIR/caffeinate.args"
  assert_no_file "dry-run writes no state" "$MAC_AWAKE_STATE_DIR/session.state"
}

t_status_missing_settings() {
  touch "$MOCK_DIR/pmset_empty"
  run status
  assert_rc "status works with empty pmset" 0
  assert_out "reports macOS version" "26.6.2"
  assert_out "reports build" "25G83"
  assert_out "reports no session" "none"
  assert_out "lid unverified" "UNVERIFIED"
  rm -f "$MOCK_DIR/pmset_empty" "$BIN/pmset"
  run status
  assert_rc "status works without pmset" 0
  assert_out "says pmset unavailable" "pmset unavailable"
  rm -f "$BIN/pmset"
  mock pmset 'echo " sleep 1"'
  run status
  assert_out "SleepDisabled missing -> default noted" "not listed; default 0"
}

t_start_stop() {
  start_ok
  assert_rc "start succeeds" 0
  assert_out "reports lid unverified" "UNVERIFIED"
  assert_file "state file" "$MAC_AWAKE_STATE_DIR/session.state"
  local cpid spid
  cpid="$(state_val caffeinate_pid)"
  spid="$(state_val supervisor_pid)"
  assert_alive "caffeinate running" "$cpid"
  assert_alive "supervisor running" "$spid"
  check "caffeinate gets -ims and -t" grep -q -- '-ims -t 14400' "$MOCK_DIR/caffeinate.args"
  check "state dir is 700" test "$(stat -f %Lp "$MAC_AWAKE_STATE_DIR")" = 700
  check "state file is 600" test "$(stat -f %Lp "$MAC_AWAKE_STATE_DIR/session.state")" = 600
  run status
  assert_out "status shows ACTIVE" "ACTIVE"
  run start --yes
  assert_rc "second start refused" 4
  assert_out "says already active" "already active"
  run stop
  assert_rc "stop succeeds" 0
  wait_gone "$cpid"
  assert_dead "caffeinate gone" "$cpid"
  assert_dead "supervisor gone" "$spid"
  assert_no_file "state removed" "$MAC_AWAKE_STATE_DIR/session.state"
  run stop
  assert_rc "stop is idempotent" 0
  run start --yes --duration 0 --display
  assert_rc "start unlimited with display" 0
  check "no -t and -d flag" grep -qx -- '-imsd' "$MOCK_DIR/caffeinate.args"
  run stop
  assert_rc "stop again" 0
}

signal_cleanup() { # signal
  start_ok
  local cpid spid
  cpid="$(state_val caffeinate_pid)"
  spid="$(state_val supervisor_pid)"
  kill -"$1" "$spid"
  wait_gone "$spid"
  wait_gone "$cpid"
  assert_dead "supervisor exits on $1" "$spid"
  assert_dead "caffeinate stopped on $1" "$cpid"
  assert_no_file "state cleaned on $1" "$MAC_AWAKE_STATE_DIR/session.state"
}
t_sigterm() { signal_cleanup TERM; }
t_sigint() { signal_cleanup INT; }

t_sighup_survives() {
  start_ok
  local spid
  spid="$(state_val supervisor_pid)"
  kill -HUP "$spid"
  sleep 0.5
  assert_alive "terminal-closure HUP does not kill the session" "$spid"
  run stop
  assert_rc "stop still works" 0
}

t_duration_expiry() {
  mock caffeinate 'echo "$@" >"$MOCK_DIR/caffeinate.args"; sleep 1.2'
  start_ok --duration 5
  local spid
  spid="$(state_val supervisor_pid)"
  wait_gone "$spid"
  assert_dead "supervisor exits when caffeinate ends" "$spid"
  assert_no_file "state cleaned after expiry" "$MAC_AWAKE_STATE_DIR/session.state"
}

t_restore_previous_zero() {
  echo 0 >"$MOCK_DIR/sleepdisabled"
  start_ok --disablesleep
  assert_rc "start --disablesleep" 0
  check "SleepDisabled applied" test "$(cat "$MOCK_DIR/sleepdisabled")" = 1
  assert_out "reports applied" "applied"
  run stop
  assert_rc "stop" 0
  check "restored to 0" test "$(cat "$MOCK_DIR/sleepdisabled")" = 0
  assert_out "reports restore" "Restored SleepDisabled to 0"
}

t_restore_previous_one() {
  echo 1 >"$MOCK_DIR/sleepdisabled"
  start_ok --disablesleep
  assert_out "notes already 1" "already 1"
  run stop
  assert_rc "stop" 0
  check "still 1 (not blindly zeroed)" test "$(cat "$MOCK_DIR/sleepdisabled")" = 1
  assert_no_file "sudo never called" "$MOCK_DIR/sudo.calls"
  assert_out "says left unchanged" "left unchanged"
}

t_no_disablesleep_without_flag() {
  start_ok
  run stop
  assert_no_file "pmset never asked to change anything" "$MOCK_DIR/sudo.calls"
  check "no pmset -a calls" bash -c '! grep -q "^-a" "$1" 2>/dev/null' _ "$MOCK_DIR/pmset.calls"
}

t_sudo_denied_at_start() {
  echo deny >"$MOCK_DIR/sudo_mode"
  start_ok --disablesleep
  assert_rc "session still starts" 0
  assert_out "warns not applied" "NOT applied"
  assert_out "prints manual command" "sudo pmset -a disablesleep 1"
  check "setting unchanged" test "$(cat "$MOCK_DIR/sleepdisabled")" = 0
  run stop
  assert_rc "stop ok" 0
}

t_restore_denied_then_retry() {
  start_ok --disablesleep
  check "applied" test "$(cat "$MOCK_DIR/sleepdisabled")" = 1
  echo deny >"$MOCK_DIR/sudo_mode"
  run stop
  assert_rc "stop reports failure" 1
  assert_out "manual restore command" "sudo pmset -a disablesleep 0"
  assert_file "restore-pending recorded" "$MAC_AWAKE_STATE_DIR/restore-pending"
  assert_no_file "session state gone" "$MAC_AWAKE_STATE_DIR/session.state"
  run status
  assert_out "status flags pending restore" "RESTORE PENDING"
  echo allow >"$MOCK_DIR/sudo_mode"
  run stop
  assert_rc "retry succeeds" 0
  check "restored" test "$(cat "$MOCK_DIR/sleepdisabled")" = 0
  assert_no_file "pending cleared" "$MAC_AWAKE_STATE_DIR/restore-pending"
}

t_stale_state() {
  mkdir -p "$MAC_AWAKE_STATE_DIR"
  chmod 700 "$MAC_AWAKE_STATE_DIR"
  printf 'supervisor_pid=999999\nsupervisor_lstart=x\ncaffeinate_pid=999998\ncaffeinate_lstart=x\nbefore_sleepdisabled=0\ndisablesleep_requested=0\n' >"$MAC_AWAKE_STATE_DIR/session.state"
  run status
  assert_out "status flags stale" "STALE"
  run stop
  assert_rc "stop cleans stale" 0
  assert_no_file "stale state removed" "$MAC_AWAKE_STATE_DIR/session.state"
  printf 'supervisor_pid=999999\nsupervisor_lstart=x\ncaffeinate_pid=999998\ncaffeinate_lstart=x\nbefore_sleepdisabled=0\ndisablesleep_requested=0\n' >"$MAC_AWAKE_STATE_DIR/session.state"
  start_ok
  assert_rc "start replaces stale state" 0
  assert_out "warned about stale" "stale"
  run stop
}

t_never_kills_foreign_caffeinate() {
  # An unrelated caffeinate (same name, different start/pid) must survive stop and stale cleanup.
  "$BIN/caffeinate" -u -t 999 &
  local foreign=$!
  mkdir -p "$MAC_AWAKE_STATE_DIR"
  chmod 700 "$MAC_AWAKE_STATE_DIR"
  # State claims the foreign pid, but with a start time that does not match: PID-reuse scenario.
  printf 'supervisor_pid=999999\nsupervisor_lstart=x\ncaffeinate_pid=%s\ncaffeinate_lstart=Thu Jan  1 00:00:00 1970\nbefore_sleepdisabled=0\ndisablesleep_requested=0\n' "$foreign" >"$MAC_AWAKE_STATE_DIR/session.state"
  run stop
  assert_rc "stop on stale state" 0
  assert_alive "foreign caffeinate survives" "$foreign"
  start_ok
  run stop
  assert_alive "foreign caffeinate survives a full start/stop" "$foreign"
  kill "$foreign" 2>/dev/null || true
}

t_concurrent_starts() {
  local a="$SANDBOX/a.out" b="$SANDBOX/b.out" ra rb
  /bin/bash "$SCRIPT" start --yes >"$a" 2>&1 &
  local pa=$!
  /bin/bash "$SCRIPT" start --yes >"$b" 2>&1 &
  local pb=$!
  wait "$pa" && ra=0 || ra=$?
  wait "$pb" && rb=0 || rb=$?
  check "exactly one start succeeds" test "$(((ra == 0) + (rb == 0)))" -eq 1
  check "the loser is refused with exit 4" test "$ra" -eq 4 -o "$rb" -eq 4
  check "single caffeinate process for sandbox" test "$(ps -axo command= | grep -c "$BIN/[c]affeinate")" -eq 1
  run stop
  assert_rc "stop" 0
}

t_stale_lock_is_broken() {
  mkdir -p "$MAC_AWAKE_STATE_DIR/lock"
  chmod 700 "$MAC_AWAKE_STATE_DIR"
  echo 999999 >"$MAC_AWAKE_STATE_DIR/lock/pid"
  start_ok
  assert_rc "dead lock holder is ignored" 0
  assert_no_file "lock released" "$MAC_AWAKE_STATE_DIR/lock"
  run stop
}

t_missing_commands() {
  rm -f "$BIN/caffeinate"
  start_ok
  assert_rc "missing caffeinate" 3
  assert_out "names the command" "caffeinate"
  mock caffeinate 'sleep 1'
  rm -f "$BIN/pmset"
  start_ok
  assert_rc "missing pmset" 3
  mock pmset 'echo'
  start_ok --disablesleep --dry-run
  rm -f "$BIN/sudo"
  run start --yes --disablesleep
  assert_rc "missing sudo with --disablesleep" 3
  mock uname 'echo Linux'
  run start --yes
  assert_rc "non-macOS refused" 3
  assert_out "explains macOS only" "only works on macOS"
}

t_permission_denied() {
  mkdir -p "$SANDBOX/ro"
  chmod 500 "$SANDBOX/ro"
  export MAC_AWAKE_STATE_DIR="$SANDBOX/ro/state"
  start_ok
  assert_rc "cannot create state dir" 1
  assert_out "reports permission problem" "permission denied"
  assert_no_file "nothing launched" "$MOCK_DIR/caffeinate.args"
  chmod 700 "$SANDBOX/ro"
}

t_lid_test_verdicts() {
  mkdir -p "$MAC_AWAKE_STATE_DIR/lidtest"
  local d="$MAC_AWAKE_STATE_DIR/lidtest" now
  now="$(date +%s)"
  chmod 700 "$MAC_AWAKE_STATE_DIR"
  printf 'build=25G83\nsession_active=yes\nsleepdisabled=0\npower=AC\n' >"$d/meta"
  # continued: lid closed for 5 consecutive samples, no gaps
  printf '%s no\n%s yes\n%s yes\n%s yes\n%s yes\n%s yes\n%s no\n' "$now" "$((now + 1))" "$((now + 2))" "$((now + 3))" "$((now + 4))" "$((now + 5))" "$((now + 6))" >"$d/heartbeat.log"
  run lid-test report
  assert_out "continued verdict" "Result: CONTINUED"
  # slept: 30s gap
  printf '%s no\n%s yes\n%s no\n' "$now" "$((now + 1))" "$((now + 31))" >"$d/heartbeat.log"
  printf 'build=25G83\nsession_active=yes\nsleepdisabled=0\npower=AC\n' >"$d/meta"
  run lid-test report
  assert_out "slept verdict" "Result: SLEPT"
  # inconclusive: no gaps, lid never closed
  printf '%s no\n%s no\n%s no\n' "$now" "$((now + 1))" "$((now + 2))" >"$d/heartbeat.log"
  printf 'build=25G83\nsession_active=no\nsleepdisabled=0\npower=AC\n' >"$d/meta"
  run lid-test report
  assert_out "inconclusive verdict" "INCONCLUSIVE"
  run status
  assert_out "status shows mixed evidence" "MIXED"
  assert_out "status never overclaims" "NOT proof"
}

t_lid_test_flow() {
  run lid-test report
  assert_rc "report without data fails" 1
  run lid-test start
  assert_rc "lid-test start" 0
  assert_out "gives safety advice" "ventilated"
  run lid-test start
  assert_rc "double start refused" 4
  sleep 2.5
  run lid-test abort
  assert_rc "abort" 0
  assert_no_file "heartbeat removed" "$MAC_AWAKE_STATE_DIR/lidtest/heartbeat.log"
  check "nothing recorded on abort" test ! -s "$MAC_AWAKE_STATE_DIR/lid-tests.log"
}

t_status_lid_unverified_when_log_only_other_build() {
  mkdir -p "$MAC_AWAKE_STATE_DIR"
  chmod 700 "$MAC_AWAKE_STATE_DIR"
  echo '1|99Z99|CONTINUED|9|0|session=yes|sleepdisabled=1|power=AC' >"$MAC_AWAKE_STATE_DIR/lid-tests.log"
  run status
  assert_out "results from another build do not count" "UNVERIFIED"
}

t_diagnose() {
  mock sysctl 'echo mock'
  mock system_profiler 'echo "  Resolution: 3024 x 1964"'
  run diagnose
  assert_rc "diagnose runs" 0
  assert_out "includes pmset" "pmset -g"
  assert_out "flags disablesleep as undocumented" "disablesleep"
  assert_not_out "does not write anything" "Restored"
  check "no pmset changes made" bash -c '! grep -q "^-a" "$1" 2>/dev/null' _ "$MOCK_DIR/pmset.calls"
}

if [ $# -gt 0 ]; then
  for t in "$@"; do run_test "$t"; done
else
  for t in $(declare -F | awk '$3 ~ /^t_/ {print $3}'); do run_test "$t"; done
fi

echo
echo "tests: $TESTS_RUN, failed assertions: $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
