---
name: start
description: Start mac-awake - hold caffeinate power assertions to prevent idle/system sleep, optionally trying the undocumented pmset disablesleep experiment. Records prior settings first and asks for approval.
argument-hint: "[--duration 4h] [--display] [--disablesleep]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh start --dry-run*)
---

The user wants to start sleep-prevention mode. Arguments: `$ARGUMENTS`

Follow these steps in order:

1. **Show the plan (no changes yet).** Run `${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh start --dry-run $ARGUMENTS` and show the plan. Explain in plain words:
   - `caffeinate` holds assertions that stop *idle* (and, on AC, system) sleep. It does **not** override closing the lid.
   - Prior `pmset` state is snapshotted first. The session auto-stops after the duration (default 4h; `--duration 0` means no limit).
   - If `--disablesleep` was requested: it runs `sudo -n pmset -a disablesleep 1`, an **undocumented** setting that may not affect lid-close sleep. It never prompts for a password: if sudo is not already authorized it is skipped and the exact command is printed for the user to run themselves. On stop it is restored only if it was 0 before; if it was already 1 it is left alone.
   - Safety: do not put a closed, running MacBook in a bag or on a surface that blocks ventilation.
2. **Ask for approval** with AskUserQuestion (proceed / cancel). Do nothing further without a yes. Never run `sudo` yourself, and never ask for a password.
3. **Start.** On approval run `${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh start --yes $ARGUMENTS` (this launches only `caffeinate` and a supervisor).
4. **Report exactly what was applied**, copied from the output: caffeinate flags, whether disablesleep was applied / skipped / already set, snapshot path.
5. End with: lid-close behavior is **UNVERIFIED**; offer the lid-test (`${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh lid-test start`) and point to the README for the manual recovery command (`/mac-awake:stop`).

Never state or imply that the lid-close behavior is overridden unless `/mac-awake:status` shows a recorded lid-test result saying so.
