# Out-of-session watchdog

The watchdog is a macOS launchd user agent that checks one Firstmate home's supervision from outside the session.
It exists for the failure where the session's own supervision dies with the session.
The watcher and the Claude Stop-hook arm both stop, no rewake ever reaches the idle session, and nothing inside the session can notice.
Only a process that survives session death and reboot can catch that.

The watchdog adds no second supervisor.
It reads the evidence the home already keeps, calls the home-scoped recovery that already exists, and alarms through the existing [wedge alarm](wedge-alarm.md) channels.

## Components

| Component | Owner |
| --- | --- |
| The check, its verdicts, recovery order, and tunables | `bin/fm-watchdog-check.sh` header |
| Installing, inspecting, and removing the agent | `bin/fm-watchdog-install.sh` header |
| The agent definition | [`examples/fm-watchdog.plist`](examples/fm-watchdog.plist) |
| Alert channels | [`wedge-alarm.md`](wedge-alarm.md) |

## What one check does

Each run reads `state/.last-watcher-beat`, the session lock, and the Claude auto-arm ledger `state/.claude-autoarm-epoch` through the helpers in `bin/fm-wake-lib.sh`.
It reaches one verdict: `idle`, `healthy`, `session-missing`, `dead-arm-owner`, or `stale-watcher`.
A launchd job runs outside every harness, so the check derives the supervision model from the ledger: a Claude primary when the ledger exists, a persistent watcher otherwise.
`FM_SUPERVISION_MODEL` pins the model when that guess is wrong.
Pi and omp homes use the extension model and are not covered by the derivation.

Staleness uses `FM_WATCHDOG_STALE_SECS`, 900 seconds by default.
That is longer than the 300-second guard grace so a long handling turn does not read as a lapse.

## Recovery

For any verdict other than `idle` or `healthy`, the check runs these steps in order under the home's watchdog lock:

1. If the watcher lock names a live process, stop that watcher with `bin/fm-watch-arm.sh --stop`.
   This is the home-scoped stop, and it publishes downtime exactly as any watcher close does.
   The check never signals a process itself and never uses `pkill`.
2. Run `config/watchdog-resume`, the command that resumes the main session.
3. Re-read the verdict for up to `FM_WATCHDOG_VERIFY_SECS`.

A recovery that restores a healthy verdict ends the episode silently.
A recovery that does not is a failed attempt.
At most one attempt runs per `FM_WATCHDOG_RETRY_SECS`.
After `FM_WATCHDOG_ALARM_AFTER` consecutive failed attempts the check raises the wedge alarm channels, and repeats at most once per `FM_WATCHDOG_ALARM_INTERVAL_SECS`.
The captain hears about nothing else.

### The resume command

This repository has no supported route that relaunches a dead main session, so the captain's own launch command is that route.
`config/watchdog-resume` is local and gitignored.
Its first non-empty, non-comment line is run through `sh -c` with `FM_HOME`, `FM_ROOT`, and `FM_WATCHDOG_REASON` set to the verdict.
The command must be safe to run when the session is already alive and busy, and must do nothing then.
It must start the session the way the captain starts it and let that session's own start-up reconcile durable state.
An absent file makes the resume step a logged no-op, so the check can then only stop a hung watcher and alarm.

## Install and remove

Installing is the captain's decision, and nothing in this repository installs the agent.

```sh
bin/fm-watchdog-install.sh install --print   # render the plist, change nothing
bin/fm-watchdog-install.sh install           # write and load the agent
bin/fm-watchdog-install.sh status
bin/fm-watchdog-install.sh uninstall
```

The agent label is home-scoped, so two homes never share an agent.
The agent runs every 120 seconds by default and at load, and it logs to `state/.watchdog.launchd.log`.
The check itself logs to `state/.watchdog.log`, and an open episode is recorded in `state/.watchdog-episode`.
The installer bakes the `PATH` of the shell that runs it into the agent, because launchd starts agents with a minimal one.

## Limits

- The check cannot tell a long handling turn from a lapse beyond the stale threshold.
- It reads the session lock's holder, so a live process that holds the lock without being the session reads as a live session.
- It does not cover Pi or omp extension supervision, secondmate homes' own supervision, or the away-mode daemon's injection path.
- The root cause of any particular death is out of scope here.

`tests/fm-watchdog-check.test.sh` covers the fresh, idle, stale-watcher, dead-arm-owner, and missing-session verdicts, the home-scoped stop, the retry interval, the alarm threshold and rate limit, and the installer, all against a temporary home.
