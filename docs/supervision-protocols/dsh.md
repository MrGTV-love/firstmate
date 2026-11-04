Mode: DSH native Cordis supervision.

For open-loop-ledger wakes and heartbeat row handling, follow [Event-driven supervision](../architecture.md#event-driven-supervision).

For a launch-owned TUI primary, `bin/fm-dsh-primary.sh` loads `.dsh/fm-primary.mjs` through its task-local patch without editing the operator's DSH profile.
For an existing native Web conversation, load that same module through the Web profile's native contribution loader with `root` selecting the code root, `home` selecting the operational home, and an explicit `sessionId` selecting the existing or resumed root Agent.
The actual Web host requires that session identity before changing any environment or subscribing to legacy startup; a missing identity is an error, not a request to select the next same-directory Agent.
Attachment requires the exact session id and matching home working directory, excludes delegated Agents, and scopes command environments and native follow-ups to that Agent without changing the shared server's environment.
The canonical session lock must already belong to the exact tagged native session on its nearest DSH server; attachment never takes a live foreign lock or grants authority from the shared PID alone.
Hot attachment inspects and arms existing supervision without replaying session start or replacing the conversation.
A bare DSH frontend is detectable, but is not a supervised Firstmate primary unless the plugin is loaded.
Only launch-owned TUI startup runs the shared session-start entry point from `agent/created`; its first step waits for the ordered digest ahead of the opening prompt.
The native `session/event` turn-end callback runs the shared turn-end guard and owns one tracked `bin/fm-watch-arm.sh` child, or the existing supervision host when this home enables it.
Do not arm another watcher, run shell `&`, or substitute a foreground wait.

When this session owns supervision:
1. First cycle: the native plugin arms automatically when the shared supervision-need predicate requires it.
2. Ordinary notification: run `bin/fm-wake-drain.sh` first, handle all presented wakes, open decisions and unread statuses, then run its exact `WAKE_ACK_REQUIRED` acknowledgement.
3. The native plugin re-arms through the existing home-scoped singleton and injects a queue-read notification, never a replay of an old headline.
4. Waiting is silent; no model turn is needed for tokenless watcher waits.
5. Failure only: diagnose the concrete guard feedback and the home-local `.dsh-primary-events.jsonl` record.
   End the recovery turn to recheck supervision; if the native plugin is missing or cannot run, the owner must restore the explicit Web contribution binding, or use `bin/fm-dsh-primary.sh --resume` for a launch-owned TUI, rather than claim supervision is healthy.

DSH exposes passive durable turn-end events, not a blocking Stop hook.
The strongest verified equivalent is the shared guard plus at most one native follow-up for a failed supervision episode; it does not claim to prevent the terminal from becoming idle.
A later external user message resets that bounded follow-up budget; DSH's own context messages do not.
The plugin retires its own tracked process group on unload and never signals another home's watcher.
Web plugin or HMR teardown does not resign a still-live primary; true Agent termination invokes the canonical exact-owned native lock release after scope disposal and registry detach.
A same-id resumed Agent waits for that release before attaching, and stale termination callbacks cannot release its successor.
Its shared owner-bound Perl watchdog also retires that private subtree when the native process dies without running disposal; it imposes no watcher lifetime deadline.
[Turn-end guard](../turnend-guard.md) owns the shared predicate and passive-adapter limit.
