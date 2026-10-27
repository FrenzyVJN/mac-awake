# mac-awake

A Claude Code plugin for investigating, managing and **testing** macOS sleep behavior, in particular whether a MacBook can stay awake with the lid closed.

> **Read this first.** Preventing *idle sleep* is easy and supported (`caffeinate`). Keeping a MacBook awake with the **lid closed** and no external display is a different problem, and macOS does not offer a documented, supported software-only way to do it. This plugin will try the known experiments, but it **never claims the lid-close behavior is overridden unless a recorded lid test on your machine shows it.** Until then the answer is reported as `UNVERIFIED`.

## What it does

| Skill | Purpose |
| --- | --- |
| `/mac-awake:start` | Shows a plan, asks for approval, then holds `caffeinate` assertions. Optional `--disablesleep` experiment. |
| `/mac-awake:stop` | Stops only this plugin's processes and restores only what it changed. |
| `/mac-awake:status` | Real system state: macOS version/build, `pmset` sleep settings, assertions, session state, lid-test evidence. |
| `/mac-awake:diagnose` | Read-only research: official behavior, `pmset`/`caffeinate` limits, logs, and what each approach requires. |

Everything is implemented in plain Bash (`scripts/mac-awake.sh`, `scripts/lib.sh`, compatible with macOS's stock bash 3.2) and can also be used without Claude.

## Install and load locally

Requires macOS and Claude Code (tested with 2.1.310).

```bash
git clone https://github.com/FrenzyVJN/mac-awake.git
claude plugin validate ./mac-awake        # manifest + skills check
claude --plugin-dir ./mac-awake           # load for one session
```

Then in the session:

```text
/mac-awake:status
/mac-awake:diagnose
/mac-awake:start --duration 2h
/mac-awake:start --duration 2h --disablesleep    # adds the undocumented experiment
/mac-awake:stop
```

Using the script directly:

```bash
scripts/mac-awake.sh start --dry-run          # show the plan only
scripts/mac-awake.sh start --yes --duration 2h
scripts/mac-awake.sh status
scripts/mac-awake.sh stop
```

## Permissions

* **No privileges** are needed for `status`, `diagnose`, or a plain `start` (it only runs `caffeinate`).
* `--disablesleep` uses `sudo -n pmset -a disablesleep 1`. `-n` means it never prompts and never reads a password. If sudo is not already authorized the step is skipped and the exact command is printed for you to run yourself in a terminal.
* The plugin never runs `sudo` without your approval, never asks for or stores a password, and never touches SIP, firmware, kernel components or hardware registers.
* State is stored in `~/Library/Application Support/mac-awake/` (mode `700`, files `600`).

## Safety model

* Prior `pmset` output is snapshotted before anything changes (`snapshots/`, last 10 kept).
* `disablesleep` is restored **only if it was `0` before the session**. If it was already `1`, it is left alone. If the original value is unknown, it is left alone.
* A detached supervisor owns `caffeinate`. `SIGTERM`/`SIGINT`/`SIGQUIT` and `caffeinate` exiting (including the duration timer, default 4h) trigger cleanup. `SIGHUP` (terminal closed) is ignored so the session survives; `stop` still works later and the timer bounds it.
* Cleanup is idempotent: the state file is claimed atomically, so concurrent or repeated cleanups are no-ops.
* Processes are identified by pid **and** start time **and** command, so a recycled pid or someone else's `caffeinate` is never killed.
* Stale state (supervisor gone) is detected and cleaned up by `start`, `stop` and reported by `status`. Concurrent invocations are serialized with a lock that is broken if its holder died.
* If a restore needs sudo and can't get it, a `restore-pending` marker is kept, `status` shows it, and the next `stop` retries.

## Restoring normal sleep settings (manual recovery)

Try these in order:

```bash
scripts/mac-awake.sh stop                 # normal path
sudo pmset -a disablesleep 0              # manual restore of the experiment
pmset -g | grep -i SleepDisabled          # expect 0 (or not listed)
pkill -x caffeinate                       # LAST RESORT: stops ALL caffeinate processes, including other apps'
```

A snapshot of your original settings is in `~/Library/Application Support/mac-awake/snapshots/`. **If `SleepDisabled` was `1` before you ever used this plugin, leave it** (your machine was already configured that way). If a stuck setting survives the commands above, restart the Mac; `pmset` changes made with `-a` persist across reboots, so run the `disablesleep 0` command again after restarting if needed.

## Lid-close experiment (how to actually test it)

The plugin includes a heartbeat recorder that decides the outcome from data, not from assumptions.

1. Save your work and **connect power**. Place the Mac on a **hard, ventilated surface**, never a bag, bed or sofa. A closed, running MacBook can overheat.
2. Optional: start a session (`start --yes`, with or without `--disablesleep`) so you test that configuration.
3. `scripts/mac-awake.sh lid-test start` (starts a heartbeat that logs a timestamp and the lid state from `ioreg` every 2 s). For a stronger test also run a background task or an SSH heartbeat from another machine.
4. Close the lid for 30-60 s, then reopen it.
5. `scripts/mac-awake.sh lid-test report`.
   * `SLEPT`: the heartbeat has a gap, so the Mac slept.
   * `CONTINUED`: no gap while the lid was observed closed for at least 3 samples.
   * `INCONCLUSIVE`: no gap but the lid was never seen closed long enough; repeat.
6. Repeat several times and under each configuration. Results append to `lid-tests.log` and `status` summarizes them per macOS build. One trial is not proof.

Do not rely on video playback alone as a test: playback holds its own power assertions and can mask the result.

## Troubleshooting

* **Skills don't appear:** run `claude plugin validate ./mac-awake`, start with `--plugin-dir`, and `/reload-plugins` after edits.
* **`start` exits 3:** a required command is missing or you're not on macOS (the message names it).
* **`start` exits 4:** a session is already active; run `status` or `stop`.
* **`status` says STALE:** the supervisor died; run `stop` to clean up.
* **`status` says RESTORE PENDING:** run the printed `sudo pmset ...` command yourself, then `stop`.
* **Mac still sleeps on lid close:** expected unless `lid-test` says otherwise. `caffeinate -s` also only works on AC power. See `/mac-awake:diagnose`.
* **Something else keeps the Mac awake:** `pmset -g assertions` lists holders (apps like Claude, browsers playing audio, etc.), which can also make "it stayed awake" tests misleading.

## Tests

```bash
brew install shellcheck
shellcheck -x scripts/*.sh tests/helpers.sh tests/unit/run.sh tests/ondevice/run.sh
/bin/bash tests/unit/run.sh              # mocked; cannot change real power settings
MAC_AWAKE_ONDEVICE=1 /bin/bash tests/ondevice/run.sh   # opt-in; real caffeinate, no sudo, no lid
```

Unit tests run every command inside a sandbox whose `PATH` contains only mock `pmset`, `caffeinate`, `sudo`, `sw_vers`, `ioreg`, and `uname` plus a fixed set of harmless utilities, with a temp state dir. They cover argument parsing/help, status with missing settings, start/stop, SIGINT/SIGTERM/SIGHUP, restore of previous values (0 and 1), denied sudo (at start and at restore), stale state and PID reuse, foreign `caffeinate` safety, concurrent starts, stale locks, missing commands, non-macOS, permission denied, lid-test verdicts and duration expiry.

## Tested results

| Item | macOS | Result |
| --- | --- | --- |
| Plugin manifest and 4 skills validate (`claude plugin validate`) | n/a (Claude Code 2.1.310) | Passed |
| Unit tests (mocked) | 26.6.2 (25G83), bash 3.2, shellcheck clean | 23 tests, all passing, repeated 3x with no flakes |
| On-device: real `caffeinate` assertion appears in `pmset -g assertions` and is released on `stop`; `SleepDisabled` unchanged | 26.6.2 (25G83), MacBook Pro M2 Pro | Passed |
| `pmset disablesleep` documented in this Mac's `pmset` man page | 26.6.2 (25G83) | **No**: undocumented |
| `--disablesleep` apply/restore with real sudo | 26.6.2 (25G83) | **Unverified** (only tested against mocks) |
| **Closed-lid operation, with caffeinate** | 26.6.2 (25G83) | **Unverified: no lid trial has been run** |
| **Closed-lid operation, with `disablesleep`** | 26.6.2 (25G83) | **Unverified: no lid trial has been run** |

Please open an issue or PR with your own `lid-tests.log` lines (and Mac model / macOS build) to extend this table.

## Known limitations

* No software here can spoof or override the physical lid sensor, and the plugin does not try to.
* `caffeinate` assertions prevent idle/system sleep; they are not documented to prevent lid-close sleep.
* `pmset disablesleep` is undocumented; behavior may vary by macOS version, chip, power source, and may be removed.
* On battery with the lid closed, a hot or low-battery Mac may still sleep or shut down for protection.
* `lid-test` can only observe sleeping via heartbeat gaps; it is evidence for the conditions of that run only.
* Documented alternatives that do work: clamshell mode (AC power + external display + input device), keeping the lid open with the display dimmed, or running the job on an always-on machine.

## Safety warnings

Never put a closed, running MacBook in a bag or on a surface that blocks ventilation. Keep it plugged in and on a hard surface during any lid-closed test.

## License

MIT
