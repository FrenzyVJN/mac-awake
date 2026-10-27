# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are consumed by mac-awake.sh
# lib.sh - shared helpers for mac-awake. Sourced by mac-awake.sh; not executable.
# Must stay compatible with macOS's stock bash 3.2.

MAC_AWAKE_VERSION="0.1.0"

readonly EX_OK=0 EX_ERR=1 EX_USAGE=2 EX_PREREQ=3 EX_BUSY=4

: "${MAC_AWAKE_STATE_DIR:=$HOME/Library/Application Support/mac-awake}"
STATE_DIR="$MAC_AWAKE_STATE_DIR"
STATE_FILE="$STATE_DIR/session.state"
LOCK_DIR="$STATE_DIR/lock"
PENDING_FILE="$STATE_DIR/restore-pending"
SNAP_DIR="$STATE_DIR/snapshots"
LID_DIR="$STATE_DIR/lidtest"
LID_LOG="$STATE_DIR/lid-tests.log"

# Heartbeat tuning (overridable so tests do not have to wait).
HEARTBEAT_INTERVAL="${MAC_AWAKE_HEARTBEAT_INTERVAL:-2}"
HEARTBEAT_GAP="${MAC_AWAKE_HEARTBEAT_GAP:-6}"

log_info() { printf '%s\n' "$*"; }
log_warn() { printf 'warning: %s\n' "$*" >&2; }
log_err() { printf 'error: %s\n' "$*" >&2; }
die() {
  local code="$1"
  shift
  log_err "$*"
  exit "$code"
}

is_uint() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- prerequisites ----------

require_macos() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] || die "$EX_PREREQ" "mac-awake only works on macOS (uname reports '$(uname -s 2>/dev/null)')."
}

# require_cmds cmd... : exits EX_PREREQ naming every missing utility.
require_cmds() {
  local missing="" c
  for c in "$@"; do have "$c" || missing="$missing $c"; done
  [ -z "$missing" ] || die "$EX_PREREQ" "required command(s) not found:$missing"
}

# ---------- state directory, locking, state file ----------

ensure_state_dir() {
  (umask 077 && mkdir -p "$STATE_DIR") 2>/dev/null || die "$EX_ERR" "cannot create state directory '$STATE_DIR' (permission denied?)"
  [ -O "$STATE_DIR" ] || die "$EX_ERR" "state directory '$STATE_DIR' is not owned by you; refusing to use it."
  chmod 700 "$STATE_DIR" 2>/dev/null || true
  [ -w "$STATE_DIR" ] || die "$EX_ERR" "state directory '$STATE_DIR' is not writable (permission denied)."
}

acquire_lock() {
  local tries=0 holder
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if ! is_uint "$holder" || ! kill -0 "$holder" 2>/dev/null; then
      # Holder died without releasing (or never wrote its pid): break the lock.
      # A lock dir that is merely brand new gets a short grace period first.
      if is_uint "$holder" || [ "$tries" -ge 3 ]; then
        rm -rf "$LOCK_DIR"
        continue
      fi
    fi
    tries=$((tries + 1))
    [ "$tries" -le 50 ] || die "$EX_BUSY" "another mac-awake command is running (lock held by pid ${holder:-unknown})."
    sleep 0.1
  done
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  LOCK_HELD=1
}

release_lock() {
  if [ "${LOCK_HELD:-0}" = 1 ]; then
    rm -rf "$LOCK_DIR"
    LOCK_HELD=0
  fi
}

# state_get FILE KEY -> value (empty if absent). The file is parsed, never sourced.
state_get() {
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# state_write FILE : reads key=value lines on stdin, replaces FILE atomically (mode 600).
state_write() {
  local tmp="$1.tmp.$$"
  (umask 077 && cat >"$tmp") && mv -f "$tmp" "$1"
}

# ---------- process identity (guards against PID reuse and foreign processes) ----------

proc_alive() { is_uint "${1:-}" && kill -0 "$1" 2>/dev/null; }
proc_lstart() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //;s/ $//'; }
proc_cmd() { ps -o command= -p "$1" 2>/dev/null || true; }

# is_our_proc PID LSTART PATTERN : alive, same start time as recorded, command matches.
is_our_proc() {
  local pid="$1" lstart="$2" pattern="$3"
  proc_alive "$pid" || return 1
  [ -n "$lstart" ] && [ "$(proc_lstart "$pid")" = "$lstart" ] || return 1
  case "$(proc_cmd "$pid")" in *"$pattern"*) return 0 ;; *) return 1 ;; esac
}

# ---------- pmset ----------

# pmset_sleepdisabled -> 0 | 1 | unknown. A successful pmset that does not list
# SleepDisabled means the default (0).
pmset_sleepdisabled() {
  local out
  have pmset || {
    echo unknown
    return 0
  }
  out="$(pmset -g 2>/dev/null)" || {
    echo unknown
    return 0
  }
  [ -n "$out" ] || {
    echo unknown
    return 0
  }
  case "$(printf '%s\n' "$out" | awk '$1 == "SleepDisabled" {print $2; exit}')" in
    1) echo 1 ;;
    *) echo 0 ;;
  esac
}

manual_disablesleep_cmd() { printf 'sudo pmset -a disablesleep %s' "$1"; }

# set_disablesleep VALUE : uses sudo -n only. Never prompts, never touches a password.
set_disablesleep() {
  have sudo || return 1
  sudo -n pmset -a disablesleep "$1" >/dev/null 2>&1
}

save_snapshot() {
  local f
  f="$SNAP_DIR/pmset-$(date +%s)-$$.txt"
  (umask 077 && mkdir -p "$SNAP_DIR") || return 1
  {
    echo "# mac-awake snapshot $(date)"
    echo "## pmset -g"
    pmset -g 2>&1 || true
    echo "## pmset -g custom"
    pmset -g custom 2>&1 || true
    echo "## pmset -g assertions"
    pmset -g assertions 2>&1 || true
  } >"$f" 2>/dev/null
  chmod 600 "$f" 2>/dev/null || true
  # keep the 10 newest
  # shellcheck disable=SC2012
  ls -1t "$SNAP_DIR" 2>/dev/null | tail -n +11 | while IFS= read -r old; do rm -f "$SNAP_DIR/$old"; done
  printf '%s\n' "$f"
}

clamshell_state() {
  local v=""
  have ioreg && v="$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null | awk -F'= ' '/"AppleClamshellState"/ {print $2; exit}')"
  case "$v" in Yes) echo yes ;; No) echo no ;; *) echo unknown ;; esac
}

# ---------- session classification and cleanup ----------

# session_class -> none | active | stale
session_class() {
  [ -f "$STATE_FILE" ] || {
    echo none
    return 0
  }
  if is_our_proc "$(state_get "$STATE_FILE" supervisor_pid)" "$(state_get "$STATE_FILE" supervisor_lstart)" "mac-awake.sh __supervise"; then
    echo active
  else
    echo stale
  fi
}

# restore_disablesleep BEFORE : applies the "only undo what we did" rule.
# Prints a human-readable outcome; sets restore-pending when it cannot finish.
restore_disablesleep() {
  local before="$1" now
  now="$(pmset_sleepdisabled)"
  case "$before" in
    1)
      log_info "SleepDisabled was already 1 before this session: left unchanged."
      return 0
      ;;
    0) ;;
    *)
      log_info "SleepDisabled's original value is unknown: left unchanged (now: $now)."
      return 0
      ;;
  esac
  if [ "$now" = 0 ]; then
    log_info "SleepDisabled is 0 (original value): nothing to restore."
    rm -f "$PENDING_FILE"
    return 0
  fi
  if set_disablesleep 0 && [ "$(pmset_sleepdisabled)" = 0 ]; then
    log_info "Restored SleepDisabled to 0."
    rm -f "$PENDING_FILE"
    return 0
  fi
  printf 'target=0\n' | state_write "$PENDING_FILE"
  log_warn "could not restore SleepDisabled (needs sudo). Run: $(manual_disablesleep_cmd 0)"
  return 1
}

# cleanup_session : idempotent. The first caller atomically claims the state file;
# later callers find nothing to do. Kills only processes proven to be ours.
cleanup_session() {
  local claim="$STATE_FILE.cleaning.$$" cpid clstart before requested
  mv "$STATE_FILE" "$claim" 2>/dev/null || return 0
  cpid="$(state_get "$claim" caffeinate_pid)"
  clstart="$(state_get "$claim" caffeinate_lstart)"
  before="$(state_get "$claim" before_sleepdisabled)"
  requested="$(state_get "$claim" disablesleep_requested)"
  if is_our_proc "$cpid" "$clstart" "caffeinate"; then
    kill "$cpid" 2>/dev/null || true
    log_info "Stopped caffeinate (pid $cpid)."
  fi
  if [ "$requested" = 1 ]; then
    restore_disablesleep "$before" || true
  fi
  rm -f "$claim"
}

retry_pending_restore() {
  [ -f "$PENDING_FILE" ] || return 0
  local target now
  target="$(state_get "$PENDING_FILE" target)"
  [ "$target" = 0 ] || [ "$target" = 1 ] || {
    rm -f "$PENDING_FILE"
    return 0
  }
  now="$(pmset_sleepdisabled)"
  if [ "$now" = "$target" ]; then
    rm -f "$PENDING_FILE"
    return 0
  fi
  if set_disablesleep "$target" && [ "$(pmset_sleepdisabled)" = "$target" ]; then
    log_info "Restored SleepDisabled to $target (pending restore completed)."
    rm -f "$PENDING_FILE"
  else
    log_warn "SleepDisabled restore still pending. Run: $(manual_disablesleep_cmd "$target")"
    return 1
  fi
}
