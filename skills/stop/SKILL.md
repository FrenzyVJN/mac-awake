---
name: stop
description: Stop the mac-awake session and restore any power setting it changed. Only touches processes this plugin started.
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh stop) Bash(${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh status)
---

Stop the mac-awake session and restore settings:

```!
${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh stop
```

Then run `${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh status` and report:
- what was stopped and what was restored (copy the output; do not paraphrase away warnings),
- if the output says a restore is pending or failed, give the user the exact manual command shown (e.g. `sudo pmset -a disablesleep 0`) and tell them to run it themselves in a terminal. Do not run `sudo` yourself and do not ask for a password,
- if SleepDisabled was already 1 before the session, say it was intentionally left as found,
- if a reboot might be needed (settings still not restored after the manual command), say so.

Only processes started by this plugin are ever stopped; unrelated `caffeinate` processes are never touched.
