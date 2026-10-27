#!/usr/bin/env bash
# mac-awake - investigate and manage macOS sleep behaviour (idle sleep vs. lid-close sleep).
#
# This tool prevents *idle/system* sleep with caffeinate. It does NOT claim to override
# clamshell (lid-close) sleep: that is only reported after `lid-test` observes it.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
. "$(dirname "$SELF")/lib.sh"

DEFAULT_DURATION=14400 # 4 hours
MAX_DURATION=604800    # 7 days

usage() {
  cat <<EOF
mac-awake $MAC_AWAKE_VERSION - macOS sleep investigation and management

Usage: mac-awake.sh <command> [options]

Commands:
  start [--yes] [--dry-run] [--duration N[s|m|h]] [--display] [--disablesleep]
        Hold caffeinate power assertions (idle + system sleep). Prints the plan and
        requires --yes to proceed. Default duration 4h; 0 means no limit.
        --display     also keep the display awake (caffeinate -d)
        --disablesleep  EXPERIMENT: 'pmset -a disablesleep 1' via 'sudo -n' (no prompts)
  stop            Stop this plugin's session and restore what it changed.
  status          Show system sleep state, session state, and lid-test evidence.
  diagnose        Collect read-only facts about power management on this Mac.
  lid-test start|report|abort
        Record a heartbeat across a real lid-close trial and judge the outcome.
  help            Show this help.

Exit codes: 0 ok, 1 error, 2 usage, 3 missing prerequisite, 4 session already active.
State lives in: $STATE_DIR
EOF
}

usage_err() {
  log_err "$*"
  usage >&2
  exit "$EX_USAGE"
}

# parse_duration 90s|15m|4h|3600 -> seconds
parse_duration() {
  local v="$1" n unit mult=1
  case "$v" in
    *[smh]) unit="${v#"${v%?}"}" n="${v%?}" ;;
    *) n="$v" unit=s ;;
  esac
  is_uint "$n" || usage_err "invalid duration '$v' (use e.g. 90, 30m, 4h, or 0 for no limit)"
  case "$unit" in m) mult=60 ;; h) mult=3600 ;; esac
  n=$((10#$n * mult))
  [ "$n" -le "$MAX_DURATION" ] || usage_err "duration '$v' exceeds the 7 day maximum"
  echo "$n"
}

# ---------------------------------------------------------------- start

cmd_start() {
  local yes=0 dry=0 duration="$DEFAULT_DURATION" display=0 dsleep=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes | -y) yes=1 ;;
      --dry-run) dry=1 ;;
      --display) display=1 ;;
      --disablesleep) dsleep=1 ;;
      --duration)
        [ $# -ge 2 ] || usage_err "--duration needs a value"
        duration="$(parse_duration "$2")"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) usage_err "unknown option for start: '$1'" ;;
    esac
    shift
  done

  require_macos
  require_cmds caffeinate pmset ps sw_vers
  [ "$dsleep" = 0 ] || require_cmds sudo

  local flags="-ims"
  [ "$display" = 0 ] || flags="-imsd"
  local before
  before="$(pmset_sleepdisabled)"

  log_info "Plan:"
  log_info "  1. Record current pmset state to a snapshot in $STATE_DIR"
  log_info "  2. Run: caffeinate $flags$([ "$duration" -gt 0 ] && echo " -t $duration")"
  log_info "     (prevents idle sleep; -s only takes effect on AC power)"
  if [ "$dsleep" = 1 ]; then
    log_info "  3. EXPERIMENT: sudo -n pmset -a disablesleep 1  (undocumented; current value: $before)"
    log_info "     Needs passwordless/cached sudo; otherwise it is skipped and the command is printed."
    log_info "     On stop it is restored only if it was 0 before this session."
  fi
  log_info "No change here overrides lid-close sleep unless 'lid-test' proves it on this Mac."
  log_info "Do not put a closed, running MacBook in a bag or on a surface that blocks ventilation."
  [ "$dry" = 0 ] || exit 0
  if [ "$yes" = 0 ]; then
    log_err "approval required: re-run with --yes to proceed."
    exit "$EX_USAGE"
  fi

  ensure_state_dir
  trap release_lock EXIT
  acquire_lock

  case "$(session_class)" in
    active) die "$EX_BUSY" "a mac-awake session is already active (run 'status' or 'stop')." ;;
    stale)
      log_warn "found stale session state; cleaning it up first."
      cleanup_session
      ;;
  esac

  local snap
  snap="$(save_snapshot)" || snap=""
  log_info "Snapshot: ${snap:-<failed>}"
  log_info "SleepDisabled before: $before"

  # Detached supervisor: own process group (job control) so Ctrl-C/terminal HUP on the
  # launching shell cannot hit it; it traps TERM/INT/QUIT itself and ignores HUP.
  : >"$STATE_DIR/supervisor.log"
  chmod 600 "$STATE_DIR/supervisor.log" 2>/dev/null || true
  set -m
  bash "$SELF" __supervise "$flags" "$duration" "$before" "$dsleep" "$snap" >>"$STATE_DIR/supervisor.log" 2>&1 </dev/null &
  local spid=$!
  set +m

  local i=0
  while [ ! -f "$STATE_FILE" ]; do
    if ! proc_alive "$spid" || [ "$i" -ge 50 ]; then
      die "$EX_ERR" "session failed to start (caffeinate did not stay running)."
    fi
    i=$((i + 1))
    sleep 0.1
  done

  log_info "Session active: supervisor pid $(state_get "$STATE_FILE" supervisor_pid), caffeinate pid $(state_get "$STATE_FILE" caffeinate_pid)."

  if [ "$dsleep" = 1 ]; then
    if [ "$before" = 1 ]; then
      log_info "disablesleep: already 1 before start; nothing applied, will be left as found."
    elif set_disablesleep 1 && [ "$(pmset_sleepdisabled)" = 1 ]; then
      log_info "disablesleep: applied (SleepDisabled is now 1). Restored to 0 on stop."
    else
      log_warn "disablesleep NOT applied (sudo needs a password). To try it, run yourself: $(manual_disablesleep_cmd 1)"
      log_warn "'stop' will restore it to 0 if it is 1 at that time."
    fi
  fi
  log_info "Applied: caffeinate assertions only$([ "$dsleep" = 1 ] && echo " (+ disablesleep experiment, see above)")."
  log_info "Lid-close behaviour: UNVERIFIED. Run 'lid-test start' to test it."
}

# Internal: the long-running supervisor. Args: flags duration before requested snapshot
cmd_supervise() {
  local flags="$1" duration="$2" before="$3" requested="$4" snap="$5"
  trap '' HUP
  # shellcheck disable=SC2064
  trap 'cleanup_session; exit 0' TERM INT QUIT

  if [ "$duration" -gt 0 ]; then
    caffeinate "$flags" -t "$duration" &
  else
    caffeinate "$flags" &
  fi
  local cpid=$!
  sleep 0.2
  proc_alive "$cpid" || exit 1

  state_write "$STATE_FILE" <<EOF
version=1
supervisor_pid=$$
supervisor_lstart=$(proc_lstart $$)
caffeinate_pid=$cpid
caffeinate_lstart=$(proc_lstart "$cpid")
started_epoch=$(date +%s)
duration=$duration
flags=$flags
before_sleepdisabled=$before
disablesleep_requested=$requested
snapshot=$snap
EOF
  wait "$cpid" || true
  # caffeinate ended on its own (duration elapsed or killed): tear the session down.
  cleanup_session
}

# ---------------------------------------------------------------- stop

cmd_stop() {
  [ $# -eq 0 ] || usage_err "stop takes no arguments"
  [ -d "$STATE_DIR" ] || {
    log_info "No mac-awake session or state found. Nothing to stop."
    exit 0
  }
  ensure_state_dir
  trap release_lock EXIT
  acquire_lock

  local cls
  cls="$(session_class)"
  case "$cls" in
    none) log_info "No active mac-awake session." ;;
    active)
      local spid slstart i=0
      spid="$(state_get "$STATE_FILE" supervisor_pid)"
      slstart="$(state_get "$STATE_FILE" supervisor_lstart)"
      kill -TERM "$spid" 2>/dev/null || true
      while [ -f "$STATE_FILE" ] && [ "$i" -lt 80 ]; do
        i=$((i + 1))
        sleep 0.1
      done
      # Supervisor wedged? Make sure it is really ours before escalating.
      if [ -f "$STATE_FILE" ] && is_our_proc "$spid" "$slstart" "mac-awake.sh __supervise"; then
        kill -KILL "$spid" 2>/dev/null || true
      fi
      cleanup_session
      ;;
    stale)
      log_info "Found stale session state (supervisor is gone). Cleaning up."
      cleanup_session
      ;;
  esac

  if [ -s "$STATE_DIR/supervisor.log" ]; then
    cat "$STATE_DIR/supervisor.log"
  fi
  rm -f "$STATE_DIR/supervisor.log"
  # The supervisor has no sudo context; finish any restore from here.
  if [ -f "$PENDING_FILE" ]; then
    retry_pending_restore || true
  fi
  if [ -f "$PENDING_FILE" ]; then
    log_warn "SleepDisabled was not fully restored. If it persists after reboot: $(manual_disablesleep_cmd 0)"
    exit "$EX_ERR"
  fi
  log_info "Stopped."
}

# ---------------------------------------------------------------- status

sleep_settings() {
  have pmset || {
    echo "  pmset unavailable"
    return 0
  }
  local out
  out="$(pmset -g 2>/dev/null || true)"
  if [ -z "$out" ]; then
    echo "  (pmset returned nothing)"
    return 0
  fi
  local key found
  for key in sleep displaysleep disksleep standby powernap hibernatemode tcpkeepalive womp lowpowermode SleepDisabled; do
    found="$(printf '%s\n' "$out" | awk -v k="$key" '$1 == k {print; exit}' | sed 's/^ *//')"
    if [ -n "$found" ]; then
      echo "  $found"
    elif [ "$key" = SleepDisabled ]; then
      echo "  SleepDisabled (not listed; default 0)"
    else
      echo "  $key (not listed)"
    fi
  done
}

lid_summary() {
  local build="$1" total=0 cont=0 slept=0 inc=0 line
  if [ -f "$LID_LOG" ]; then
    while IFS='|' read -r _ b verdict _; do
      [ "$b" = "$build" ] || continue
      total=$((total + 1))
      case "$verdict" in
        CONTINUED) cont=$((cont + 1)) ;;
        SLEPT) slept=$((slept + 1)) ;;
        *) inc=$((inc + 1)) ;;
      esac
    done <"$LID_LOG"
  fi
  if [ "$cont" -eq 0 ] && [ "$slept" -eq 0 ]; then
    line="UNVERIFIED (no conclusive lid-close trial recorded for build $build; $inc inconclusive)"
  elif [ "$slept" -eq 0 ]; then
    line="OBSERVED CONTINUING in $cont/$total trial(s) on build $build, under the recorded conditions only"
  elif [ "$cont" -eq 0 ]; then
    line="SLEPT in $slept/$total trial(s) on build $build: lid-close sleep was NOT overridden"
  else
    line="MIXED on build $build: continued $cont, slept $slept, inconclusive $inc: not reliable"
  fi
  echo "  $line"
}

cmd_status() {
  [ $# -eq 0 ] || usage_err "status takes no arguments"
  local ver build
  ver="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  build="$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
  echo "macOS: $ver (build $build)"
  echo "Sleep settings (pmset -g):"
  sleep_settings
  if have pmset; then
    echo "Power source: $(pmset -g batt 2>/dev/null | head -n 1 | sed "s/^Now drawing from //" || true)"
  fi
  echo "Lid state (ioreg AppleClamshellState): $(clamshell_state)"

  echo "Active power assertions (pmset -g assertions, caffeinate/sleep-related):"
  if have pmset; then
    local a
    a="$(pmset -g assertions 2>/dev/null | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep|PreventUserIdleDisplaySleep|NoIdleSleep|pid [0-9]+' | head -n 15 || true)"
    [ -n "$a" ] && printf '%s\n' "$a" | sed 's/^/  /' || echo "  (none reported)"
  else
    echo "  pmset unavailable"
  fi

  echo "mac-awake session:"
  if [ ! -d "$STATE_DIR" ]; then
    echo "  none (no state directory yet)"
  else
    case "$(session_class)" in
      none) echo "  none" ;;
      stale) echo "  STALE state found (supervisor gone). Run 'stop' to clean up." ;;
      active)
        local started dur now
        started="$(state_get "$STATE_FILE" started_epoch)"
        dur="$(state_get "$STATE_FILE" duration)"
        now="$(date +%s)"
        echo "  ACTIVE: supervisor pid $(state_get "$STATE_FILE" supervisor_pid), caffeinate pid $(state_get "$STATE_FILE" caffeinate_pid), flags $(state_get "$STATE_FILE" flags)"
        if is_uint "$started"; then
          echo "  running for $((now - started))s$(is_uint "$dur" && [ "$dur" -gt 0 ] && echo " of ${dur}s")"
        fi
        echo "  SleepDisabled before session: $(state_get "$STATE_FILE" before_sleepdisabled); disablesleep requested: $(state_get "$STATE_FILE" disablesleep_requested)"
        ;;
    esac
    if [ -f "$PENDING_FILE" ]; then
      echo "  RESTORE PENDING: SleepDisabled must be set to $(state_get "$PENDING_FILE" target). Run: $(manual_disablesleep_cmd "$(state_get "$PENDING_FILE" target)")"
    fi
  fi

  echo "Closed-lid operation:"
  lid_summary "$build"
  echo "  Note: an active caffeinate process or SleepDisabled=1 is NOT proof the lid can close without sleep."
}

# ---------------------------------------------------------------- diagnose

section() { printf '\n== %s ==\n' "$1"; }

cmd_diagnose() {
  local deep=0
  case "${1:-}" in
    "") ;;
    --deep) deep=1 ;;
    *) usage_err "unknown option for diagnose: '$1'" ;;
  esac
  require_macos
  section "System"
  echo "macOS $(sw_vers -productVersion 2>/dev/null) build $(sw_vers -buildVersion 2>/dev/null)"
  echo "Model: $(sysctl -n hw.model 2>/dev/null || echo unknown)  Chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
  section "pmset -g (current effective settings)"
  pmset -g 2>&1 || true
  section "pmset -g custom (per power source profiles)"
  pmset -g custom 2>&1 || true
  section "Power source"
  pmset -g batt 2>&1 || true
  section "Lid / clamshell (ioreg)"
  ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -E 'AppleClamshell' || echo "not reported"
  section "Displays (an external display is part of Apple's supported clamshell mode)"
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E 'Display Type|Resolution|Connection Type|Main Display|Mirror' || echo "none reported"
  section "Power assertions (pmset -g assertions)"
  pmset -g assertions 2>&1 | head -n 40 || true
  section "pmset documentation check: is 'disablesleep' documented on this Mac?"
  if man pmset 2>/dev/null | col -b | grep -qi disablesleep; then
    echo "disablesleep IS mentioned in this Mac's pmset man page."
  else
    echo "disablesleep is NOT mentioned in this Mac's pmset man page: treat it as undocumented."
  fi
  section "Recent sleep/wake/clamshell events (pmset -g log, last 25)"
  pmset -g log 2>/dev/null | grep -E 'Clamshell|Entering Sleep|Wake from|Sleep  |Wake  |DarkWake' | tail -n 25 || echo "no events (or log unreadable)"
  section "Third-party / helper tools present"
  local t
  for t in Amphetamine.app Caffeine.app KeepingYouAwake.app Lungo.app; do
    [ -d "/Applications/$t" ] && echo "found: $t"
  done
  echo "(listing complete)"
  if [ "$deep" = 1 ]; then
    section "powerd log, last 30m (log show)"
    log show --last 30m --style compact --predicate 'process == "powerd" AND (eventMessage CONTAINS[c] "clamshell" OR eventMessage CONTAINS[c] "lid")' 2>&1 | tail -n 40 || true
  else
    echo
    echo "Tip: 'diagnose --deep' also queries the unified log (slower)."
  fi
}

# ---------------------------------------------------------------- lid-test

cmd_heartbeat() {
  local file="$1"
  trap 'exit 0' TERM INT
  while :; do
    printf '%s %s\n' "$(date +%s)" "$(clamshell_state)" >>"$file"
    sleep "$HEARTBEAT_INTERVAL"
  done
}

lid_analyze() {
  awk -v gapmax="$HEARTBEAT_GAP" '
    NR > 1 { g = $1 - pt; if (g > maxgap) maxgap = g; if (g > gapmax) gaps++ ; if (pc == "yes" && g > maxclosed) maxclosed = g }
    { if ($2 == "yes") closed++; pt = $1; pc = $2; n++ }
    END { printf "%d %d %d %d %d\n", n, closed, maxgap, maxclosed, gaps }' "$1"
}

cmd_lid_test() {
  local sub="${1:-}"
  [ -n "$sub" ] || usage_err "lid-test needs a subcommand: start | report | abort"
  shift
  case "$sub" in start | report | abort) ;; *) usage_err "unknown lid-test subcommand '$sub'" ;; esac
  [ $# -eq 0 ] || usage_err "lid-test $sub takes no arguments"
  require_macos
  ensure_state_dir
  (umask 077 && mkdir -p "$LID_DIR")
  local hb="$LID_DIR/heartbeat.log" meta="$LID_DIR/meta" pidf="$LID_DIR/pid"
  local hpid hlstart
  hpid="$(state_get "$pidf" pid)"
  hlstart="$(state_get "$pidf" lstart)"

  case "$sub" in
    start)
      if is_our_proc "$hpid" "$hlstart" "mac-awake.sh __heartbeat"; then
        die "$EX_BUSY" "a lid test is already running (use 'lid-test report' or 'abort')."
      fi
      : >"$hb"
      state_write "$meta" <<EOF
build=$(sw_vers -buildVersion 2>/dev/null || echo unknown)
version=$(sw_vers -productVersion 2>/dev/null || echo unknown)
session_active=$([ "$(session_class)" = active ] && echo yes || echo no)
sleepdisabled=$(pmset_sleepdisabled)
power=$(pmset -g batt 2>/dev/null | head -n 1 | sed 's/^Now drawing from //;s/|/ /g' | tr -d "'" || true)
started=$(date +%s)
EOF
      set -m
      bash "$SELF" __heartbeat "$hb" >/dev/null 2>&1 </dev/null &
      local p=$!
      set +m
      sleep 0.3
      state_write "$pidf" <<EOF
pid=$p
lstart=$(proc_lstart "$p")
EOF
      cat <<EOF
Lid test started (heartbeat every ${HEARTBEAT_INTERVAL}s -> $hb).
Safety: save your work, connect power, put the Mac on a hard ventilated surface.
Now close the lid for a short time (e.g. 30-60s), reopen it, then run: mac-awake.sh lid-test report
EOF
      ;;
    abort)
      if is_our_proc "$hpid" "$hlstart" "mac-awake.sh __heartbeat"; then kill "$hpid" 2>/dev/null || true; fi
      rm -f "$pidf" "$hb" "$meta"
      log_info "Lid test aborted; nothing recorded."
      ;;
    report)
      [ -s "$hb" ] || die "$EX_ERR" "no heartbeat data: run 'lid-test start' first."
      if is_our_proc "$hpid" "$hlstart" "mac-awake.sh __heartbeat"; then kill "$hpid" 2>/dev/null || true; fi
      local n closed maxgap maxclosed gaps verdict
      read -r n closed maxgap maxclosed gaps < <(lid_analyze "$hb")
      if [ "$gaps" -gt 0 ]; then
        verdict=SLEPT
      elif [ "$closed" -ge 3 ]; then
        verdict=CONTINUED
      else
        verdict=INCONCLUSIVE
      fi
      local build session sd power
      build="$(state_get "$meta" build)"
      session="$(state_get "$meta" session_active)"
      sd="$(state_get "$meta" sleepdisabled)"
      power="$(state_get "$meta" power)"
      printf '%s|%s|%s|%s|%s|session=%s|sleepdisabled=%s|power=%s\n' "$(date +%s)" "${build:-unknown}" "$verdict" "$closed" "$maxclosed" "${session:-?}" "${sd:-?}" "${power:-?}" >>"$LID_LOG"
      echo "Heartbeat samples: $n, with lid closed: $closed, longest gap: ${maxgap}s (threshold ${HEARTBEAT_GAP}s)"
      case "$verdict" in
        SLEPT) echo "Result: SLEPT - the heartbeat stopped, so the Mac slept. Lid-close sleep was NOT overridden in this trial." ;;
        CONTINUED) echo "Result: CONTINUED - heartbeat ran without gaps while the lid was observed closed ($closed samples)." ;;
        *) echo "Result: INCONCLUSIVE - no gap, but the lid was never observed closed for 3+ samples. Repeat with the lid closed longer." ;;
      esac
      echo "Conditions: session_active=${session:-?} SleepDisabled=${sd:-?} power=${power:-?}"
      echo "Recorded in $LID_LOG. One trial is not proof; repeat several times."
      rm -f "$pidf" "$hb" "$meta"
      ;;
  esac
}

# ---------------------------------------------------------------- dispatch

main() {
  local cmd="${1:-help}"
  [ $# -eq 0 ] || shift
  case "$cmd" in
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    status) cmd_status "$@" ;;
    diagnose) cmd_diagnose "$@" ;;
    lid-test) cmd_lid_test "$@" ;;
    __supervise) cmd_supervise "$@" ;;
    __heartbeat) cmd_heartbeat "$@" ;;
    help | -h | --help) usage ;;
    --version | version) echo "mac-awake $MAC_AWAKE_VERSION" ;;
    *) usage_err "unknown command '$cmd'" ;;
  esac
}

main "$@"
