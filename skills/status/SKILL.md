---
name: status
description: Show the Mac's actual sleep state - pmset settings, power assertions, whether a mac-awake session is active, and whether closed-lid operation has been verified. Use when asked about sleep settings or lid-closed awake status.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh status)
---

Run the status report and relay it faithfully:

```!
${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh status
```

Summarize for the user in a few lines: macOS version/build, key sleep settings, whether a mac-awake session is active (or stale / restore pending), and the "Closed-lid operation" verdict.

Rules:
- Report only what the output says. An active `caffeinate` process or `SleepDisabled 1` is **not** proof that a closed lid will not sleep. Never imply otherwise.
- If the verdict is UNVERIFIED, say so plainly and mention `/mac-awake:diagnose` and the lid-test procedure in the README.
- If RESTORE PENDING or STALE appears, give the exact recovery command shown.
