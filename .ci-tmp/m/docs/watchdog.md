# Out-of-session watchdog

The watchdog is a macOS launchd user agent that checks one Firstmate home's supervision from outside the session.
It exists for the failure where the session's own supervision dies with the session.
The watcher and the Claude Stop-hook arm both stop, no rewake ever reaches the idle session, and nothing inside the session can notice.
The installed agent survives Firstmate session death and runs again after the user logs in following a reboot.

The watchdog adds no second supervisor.
It reads the home's existing evidence, optionally runs an operator-owned resume command, and alarms through the existing [wedge alarm](wedge-alarm.md) channels when supervision remains down.

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

The ordinary stale threshold defaults to 900 seconds (`FM_WATCHDOG_STALE_SECS`).
A live session with a rewake ledger bound to its session lock and current recovery generation has a separate fixed limit of 3600 seconds for a legitimate handling turn.
The bound ledger must be at least as new as the beacon and have no exhausted-failure marker.
At or beyond that limit, the watchdog reports `stale-watcher` even when `FM_WATCHDOG_STALE_SECS` is larger or the pull guard's separate mid-turn policy still considers the session healthy.

## Recovery

The singleton records its PID and process start identity before publishing the lock.
A live PID suppresses another check only when `fm_pid_identity` matches the recorded identity; missing or mismatched identity is stale and reclaimed without signalling that PID.

The `bin/fm-watchdog-check.sh` header owns recovery ordering, retry timing, alarm escalation, and episode clearing.

### The resume command

This repository has no supported route that relaunches a dead main session, so the captain's own launch command is that route.
`config/watchdog-resume` is local and gitignored.
Its first non-empty, non-comment line is run through `sh -c` with `FM_HOME` and `FM_ROOT` identifying the home and checkout, and `FM_WATCHDOG_REASON` set to the verdict.
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

The `bin/fm-watchdog-install.sh` header owns agent identity, scheduling, and path resolution.
The agent logs to `state/.watchdog.launchd.log`.
The check itself logs to `state/.watchdog.log`, and an open episode is recorded in `state/.watchdog-episode`.
The installer bakes the `PATH` of the shell that runs it into the agent, because launchd starts agents with a minimal one.

## Limits

- The check cannot tell a long handling turn from a lapse beyond the stale threshold.
- It reads the session lock's holder, so a live process that holds the lock without being the session reads as a live session.
- It does not cover Pi or omp extension supervision, secondmate homes' own supervision, or the away-mode daemon's injection path.
- The root cause of any particular death is out of scope here.

`tests/fm-watchdog-check.test.sh` covers the fresh, idle, stale-watcher, dead-arm-owner, and missing-session verdicts, the home-scoped stop, the retry interval, the alarm threshold and rate limit, and the installer, all against a temporary home.
