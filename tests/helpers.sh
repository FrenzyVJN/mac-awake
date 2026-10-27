# shellcheck shell=bash
# shellcheck disable=SC2016  # bash -c snippets are single-quoted on purpose
# Test helpers. Every unit test runs against a sandbox: PATH contains ONLY mock system
# commands plus symlinks to a fixed set of harmless utilities, and the state dir is a
# temp dir. Nothing here can reach the real pmset/caffeinate/sudo.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/mac-awake.sh"
ORIG_PATH="$PATH"
TESTS_RUN=0
TESTS_FAILED=0

# Real utilities the script legitimately needs (no pmset, caffeinate, sudo, sw_vers, ioreg...).
REAL_UTILS="bash env dirname basename cat sed awk grep head tail tr sort cut wc mkdir rm mv chmod
  ls date sleep kill ps id stat mktemp touch printf test cp ln true false col sysctl uname"

new_sandbox() {
  PATH="$ORIG_PATH"
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/mac-awake-test.XXXXXX")" || exit 99
  case "$SANDBOX" in /?*/mac-awake-test.*) ;; *)
    echo "refusing to run: bad sandbox path '$SANDBOX'" >&2
    exit 99
    ;;
  esac
  MOCK_DIR="$SANDBOX/mock"
  BIN="$SANDBOX/bin"
  export MAC_AWAKE_STATE_DIR="$SANDBOX/state"
  export MOCK_DIR
  mkdir -p "$MOCK_DIR" "$BIN"
  local u p
  for u in $REAL_UTILS; do
    p="$(command -v "$u" 2>/dev/null || true)"
    case "$p" in /*) ln -sf "$p" "$BIN/$u" ;; esac
  done
  rm -f "$BIN/uname" # replaced by a mock below
  echo 0 >"$MOCK_DIR/sleepdisabled"
  echo allow >"$MOCK_DIR/sudo_mode"
  install_mocks
  export PATH="$BIN"
  export MAC_AWAKE_HEARTBEAT_INTERVAL=1 MAC_AWAKE_HEARTBEAT_GAP=3
}

# shellcheck disable=SC2016  # mock bodies are intentionally single-quoted
install_mocks() {
  mock uname 'case "${1:-}" in -s) echo "${MOCK_UNAME:-Darwin}";; *) echo "${MOCK_UNAME:-Darwin}";; esac'
  mock sw_vers 'case "$1" in -productVersion) echo 26.6.2;; -buildVersion) echo 25G83;; *) echo "ProductName: macOS";; esac'
  mock ioreg 'echo "  | \"AppleClamshellState\" = ${MOCK_CLAMSHELL:-No}"'
  mock pmset '
sd="$(cat "$MOCK_DIR/sleepdisabled")"
echo "$*" >>"$MOCK_DIR/pmset.calls"
case "$1" in
  -g)
    case "${2:-}" in
      assertions) echo "   pid 1234(caffeinate): [0x1] 00:00:10 PreventUserIdleSystemSleep named: caffeinate" ;;
      batt) echo "Now drawing from '"'"'AC Power'"'"'" ;;
      custom|log) echo "(mock)" ;;
      *)
        [ -e "$MOCK_DIR/pmset_empty" ] && exit 0
        echo "System-wide power settings:"
        [ -e "$MOCK_DIR/no_sleepdisabled_line" ] || echo " SleepDisabled		$sd"
        echo "Currently in use:"
        echo " sleep                1"
        echo " displaysleep         0"
        ;;
    esac ;;
  -a)
    [ "${2:-}" = disablesleep ] && echo "$3" >"$MOCK_DIR/sleepdisabled" ;;
esac'
  mock caffeinate 'echo "$@" >"$MOCK_DIR/caffeinate.args"
trap "exit 0" TERM INT
while :; do sleep 0.2; done'
  mock sudo '
echo "$*" >>"$MOCK_DIR/sudo.calls"
[ "$1" = "-n" ] && shift
if [ "$(cat "$MOCK_DIR/sudo_mode")" = deny ]; then echo "sudo: a password is required" >&2; exit 1; fi
exec "$@"'
}

mock() { # mock NAME BODY
  rm -f "$BIN/$1" # never write through a symlink to a real binary
  printf '#!/bin/bash\n%s\n' "$2" >"$BIN/$1"
  chmod +x "$BIN/$1"
}

cleanup_sandbox() {
  PATH="$ORIG_PATH"
  case "${SANDBOX:-}" in /?*/mac-awake-test.*) ;; *) return 0 ;; esac
  # Kill anything left running from the sandbox (supervisors / mock caffeinate / heartbeat).
  local pid
  for pid in $(ps -axo pid=,command= | awk -v s="$SANDBOX" 'index($0, s) {print $1}'); do
    kill -9 "$pid" 2>/dev/null || true
  done
  chmod -R u+rwx "$SANDBOX" 2>/dev/null || true
  rm -rf "$SANDBOX"
}

# run CMD... : captures combined output in $OUT and exit code in $RC (never aborts the test).
run() {
  OUT="$(/bin/bash "$SCRIPT" "$@" 2>&1)" && RC=0 || RC=$?
}

pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n' "$1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}
check() { # check DESC COMMAND...
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else
    fail "$desc"
    [ -z "${OUT:-}" ] || printf '       output: %s\n' "$(printf '%s' "$OUT" | head -n 6)"
  fi
}
assert_rc() { check "$1 (exit $2)" test "$RC" -eq "$2"; }
assert_out() { check "$1" grep -qiF -- "$2" <<<"$OUT"; }
assert_not_out() { check "$1" bash -c '! grep -qiF -- "$1" <<<"$2"' _ "$2" "$OUT"; }
assert_file() { check "$1" test -e "$2"; }
assert_no_file() { check "$1" test ! -e "$2"; }
assert_dead() { check "$1" bash -c '! kill -0 "$1" 2>/dev/null' _ "$2"; }
assert_alive() { check "$1" kill -0 "$2"; }

# waits for a pid to disappear (max ~5s)
wait_gone() {
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

state_val() { sed -n "s/^$1=//p" "$MAC_AWAKE_STATE_DIR/session.state" | head -n 1; }

run_test() { # run_test FUNCNAME
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '%s\n' "$1"
  new_sandbox
  "$1" || fail "$1 aborted"
  cleanup_sandbox
}
