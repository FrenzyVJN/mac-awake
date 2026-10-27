---
name: diagnose
description: Read-only investigation of macOS power management - pmset, caffeinate limits, power assertions, logs - and whether any supported software-only way exists to keep a MacBook awake with the lid closed.
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh diagnose*)
---

Collect facts from this Mac (read-only, no sudo):

```!
${CLAUDE_PLUGIN_ROOT}/scripts/mac-awake.sh diagnose
```

Then write a short findings report. Ground each claim in either the output above or Apple's / man-page documentation (use WebSearch/WebFetch against support.apple.com and developer.apple.com if you need to confirm something; label anything you could not confirm as **unverified**). Cover:

1. **Official behavior**: MacBooks sleep on lid close. Apple's supported exception is clamshell mode: power adapter + external display (+ input device) connected. Say whether the output shows an external display and AC power.
2. **caffeinate**: `-i` prevents idle sleep, `-s` prevents system sleep only on AC power, `-d` display, `-m` disk, `-u` declares user activity, `-t` timeout. These are *idle/system-sleep* assertions; they are not documented to override the lid-close sleep trigger.
3. **pmset**: which settings are documented (see the man-page check in the output) and their scope (`-a/-b/-c`). Report whether `disablesleep` is documented on this Mac. It is a privileged, undocumented setting; its effect on lid close is not guaranteed and can differ by macOS version and chip.
4. **Assertions and logs**: what is currently holding the system awake, and what the recent sleep/wake/clamshell events show.
5. **Methods and their requirements**: for each approach (external display/HDMI dummy plug, third-party utility, `pmset disablesleep`, privileged helper, remote/SSH-keepalive alternatives), state whether it needs external hardware, third-party software, sudo, or unsupported modification. Do not recommend disabling SIP, firmware changes, kernel patches or hardware register tweaks.
6. **Conclusion for this macOS build**: is there a reliable, supported software-only way? If not (or unproven), say so and give realistic alternatives (clamshell mode with a display; keeping the lid open with the screen dimmed; a desktop/Mac mini as an always-on host; running the job remotely).

Never claim lid-close behavior is overridden. The only evidence the plugin accepts is a recorded `lid-test` result. Offer to guide the user through one (README, "Lid-close experiment").
