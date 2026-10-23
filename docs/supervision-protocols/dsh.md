Mode: DSH native Cordis supervision.

For open-loop-ledger wakes and heartbeat row handling, follow [Event-driven supervision](../architecture.md#event-driven-supervision).

Launch the primary with `bin/fm-dsh-primary.sh`; its task-local patch loads `.dsh/fm-primary.mjs` without editing the operator's DSH profile.
A bare `dsh-tui` is detectable, but is not a supervised Firstmate primary unless that plugin is loaded.
The native `agent/created` callback runs the shared session-start entry point, and the first step of a fresh process waits for it, so its ordered digest enters ahead of the opening prompt.
The native `session/event` turn-end callback runs the shared turn-end guard and owns one tracked `bin/fm-watch-arm.sh` child, or the existing supervision host when this home enables it.
Do not arm another watcher, run shell `&`, or substitute a foreground wait.

When this session owns supervision:
1. First cycle: the native plugin arms automatically when the shared supervision-need predicate requires it.
2. Ordinary notification: run `bin/fm-wake-drain.sh` first, handle all presented wakes, open decisions and unread statuses, then run its exact `WAKE_ACK_REQUIRED` acknowledgement.
3. The native plugin re-arms through the existing home-scoped singleton and injects a queue-read notification, never a replay of an old headline.
4. Waiting is silent; no model turn is needed for tokenless watcher waits.
5. Failure only: diagnose the concrete guard feedback and the home-local `.dsh-primary-events.jsonl` record.
   End the recovery turn to recheck supervision; if the native plugin is missing or cannot run, the launching owner must restart with `bin/fm-dsh-primary.sh --resume` rather than claim supervision is healthy.

DSH exposes passive durable turn-end events, not a blocking Stop hook.
The strongest verified equivalent is the shared guard plus at most one native follow-up for a failed supervision episode; it does not claim to prevent the terminal from becoming idle.
A later external user message resets that bounded follow-up budget.
The plugin retires its own tracked process group on unload and never signals another home's watcher.
Its shared owner-bound Perl watchdog also retires that private subtree when the native process dies without running disposal; it imposes no watcher lifetime deadline.
[Turn-end guard](../turnend-guard.md) owns the shared predicate and passive-adapter limit.
