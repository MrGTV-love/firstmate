# Watcher continuity

This document explains how Firstmate keeps the watcher re-armed after a wake, how wakes are ordered and acknowledged, and which tests and live evidence cover that contract.
Read it when debugging a supervision gap or changing a harness's re-arm path.

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.
In this document, an arm is one run of `bin/fm-watch-arm.sh`, which starts a watcher cycle or attaches to one and returns the cycle's reason.

| Topic | Section |
| --- | --- |
| Which component re-arms the watcher on each harness | [Ownership](#ownership) |
| What happens between an actionable close and the wake reaching the model | [Actionable wake ordering](#actionable-wake-ordering) |
| How a watcher-downtime episode is announced and retired | [Recovery episode acknowledgement](#recovery-episode-acknowledgement) |
| How each actor consumes the wake queue | [Per-actor acknowledgement](#per-actor-acknowledgement) |
| What `bin/fm-watch-arm.sh` guarantees about each cycle | [Arm-layer cycle contract](#arm-layer-cycle-contract) |
| Which test suites pin these contracts | [Regression coverage](#regression-coverage) |
| What is not guaranteed, and where live evidence lives | [Active limits and verification](#active-limits-and-verification) |

## Ownership

On Pi, omp, OpenCode, Cursor, and Claude primaries, one component owns re-arming the watcher.
Codex and Grok keep their own protocols; see [Manual recovery and other harnesses](#manual-recovery-and-other-harnesses).

| Harness | Re-arm owner |
| --- | --- |
| Pi | `.pi/extensions/fm-primary-pi-watch.ts` |
| omp | `.omp/extensions/fm-primary-omp-watch.ts` |
| OpenCode | `.opencode/plugins/fm-primary-watch-arm.js` |
| Cursor | `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) |
| Claude | `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) |

On a non-Pi primary, a home that runs the supervision host also changes what the owner runs; see [Supervision host](#supervision-host).

### Pi, omp, and OpenCode adapters

Pi's `.pi/extensions/fm-primary-pi-watch.ts`, omp's `.omp/extensions/fm-primary-omp-watch.ts`, and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter:

- Starts the next arm before delivering the wake prompt.
- Checks current session-lock ownership at launch.
- Preserves one child or scheduled retry at a time.
- Applies bounded exponential retry after an unexpected or failed close.

Pi treats an arm child whose process is already gone as an empty slot even while its close event is still pending, so a repair call or a scheduled retry starts a fresh arm instead of answering unchanged.
A failed wake delivery never cancels continuity restoration.

### Pi session replacement

The [Pi extension header](../.pi/extensions/fm-primary-pi-watch.ts) owns replacement activation, predecessor retirement, and the requirement for a live successor runtime.

A state-scoped replacement handoff carries every actionable close whose delivery overlapped `session_shutdown`, including:

- A main follow-up Pi accepted but had not yet consumed.
- Branch handling.
- A retiring child that reports after the successor claim.

A handoff marker never satisfies the extension-ownership tolerance.
So a running Pi process whose replacement did not load this extension is reported as missing, rather than borrowing stale load evidence from its predecessor.

A main follow-up counts as delivered once Pi accepts it, never once the model reads it.
The reason is that a follow-up queued while main is streaming joins the running run without a `before_agent_start`.
The extension header owns how consumption is observed and why it only decides what a replacement replays.

### omp session replacement

The [omp extension header](../.omp/extensions/fm-primary-omp-watch.ts) owns replacement activation, predecessor retirement, and actionable-close replay, including recovery after handoff publication fails.
Watcher handoff publication failures remain visible as separate continuity diagnostics; replaying the watcher mark still requires a current queued row.

### omp idle wake delivery

omp starts no turn for an explicit follow-up that reaches an idle session unless its own auto-continue gate passes, and that gate refuses while the context tail is not an assistant or tool result, such as an advisor note posted after the turn ended.
`.omp/extensions/fm-primary-omp-watch.ts` sends a watcher wake through omp's prompt-starting message API only when the latest extension context returns exactly `true` from `isIdle()`; busy, missing, or unreadable idle state holds the watcher wake pending.
The latest context is retained across shutdown and transferred to a replacement extension factory, so missing-successor recovery can still start an idle wake's turn.
Arm commands and tools refresh that context when supplied; each delivery rechecks live idle state rather than caching an idle verdict across recovery.
The prompt flow never touches the composer, so an operator draft stays unsent, and it also flushes any follow-up already stranded in omp's queue.
`tests/fm-omp-harness.test.sh` covers idle delivery behind an advisor tail with an empty composer and with a draft, plus holding for an unreadable idle state; historical live evidence is recorded in [omp idle wake behind an advisor note](verification/runtime-backends.md#2026-10-08-omp-idle-wake-behind-an-advisor-note).

### Stopped generations and duplicate loads

omp can repair a missing successor automatically or through an explicit arm call; Pi requires a live replacement runtime rather than repair through its invalidated outgoing API.
The extension headers own the detailed [Pi generation contract](../.pi/extensions/fm-primary-pi-watch.ts) and [omp recovery and instance contract](../.omp/extensions/fm-primary-omp-watch.ts), including retirement ordering, terminal-quit handling, and stale callback behavior.
The [instance registry contract](../.pi/extensions/lib/fm-watch-lifecycle.ts) owns predecessor-reference release after factory handoff.

For a lifecycle gap, inspect `state/extensions/pi-primary-watch/lifecycle.log` or `state/extensions/omp-primary-watch/lifecycle.log`.
Pi's `successor-missing` diagnostic calls for reloading the extension in a live session; omp's `self-heal-failed` identifies a recovery failure for later repair.
The shared [lifecycle helper](../.pi/extensions/lib/fm-watch-lifecycle.ts) owns the record format, expiry fields, rotation, and best-effort evidence policy. Expiry waits recheck a monotonic deadline before settling; early timer callbacks wait only the remaining duration. The `actual` field records measured monotonic elapsed milliseconds, not a value clamped to the bound, so wall-clock changes do not distort deadline evidence.
These logs are evidence, not proof of a healthy arm or permission to use a retired runtime.

`tests/fm-pi-watch-extension.test.sh` covers missing-successor expiry without reviving the outgoing API, live successor activation, duplicate-instance handoff, repeated binding predecessor release, and owner-marker publication failures.
`tests/fm-omp-harness.test.sh` covers missing-successor self-heal, shutdown followed by start without a duplicate arm, instance replacement, and wake delivery after recovery.
Both suites use `tests/watch-lifecycle-expiry.mjs` for shutdown child-close, successor readiness (including omp host mode), and unready-arm retirement expiry evidence, plus deterministic early-callback, wall-clock-change, cancellation, and unref coverage for the shared deadline timer.

### omp stale wake gating

omp cannot retract a queued follow-up, so a watcher headline queued behind a running turn can outlive the durable rows that turn drains and acknowledges.
`.omp/extensions/fm-primary-omp-watch.ts` therefore queues no watcher wake behind a running turn.
After the successor restoration attempt, every actionable watcher close marks only **a wake may be due**.
Successful restoration verifies the successor and confirms the handling handoff before that mark reaches delivery.
Closes during a busy turn collapse into one mark, regardless of their headline or whether they carry an identity.

- Busy, missing, or unreadable idle state holds the mark. The extension checks again on a fixed 1000ms timer; it never sends watcher work as a follow-up.
- When idle, one subprocess queries current main-owned rows through the read-only interface owned by the [`fm-wake-drain.sh` header](../bin/fm-wake-drain.sh).
- Pending vendor messages alone do not block an idle queue-read or prompt send: that prompt flushes a stranded advisor-tail queue without submitting the composer. They block editor manipulation and another send while an unconsumed watcher wake remains outstanding.
- With rows, the extension injects one wake naming the oldest owed row's payload and, when applicable, `and N more queued`. With no rows, it clears the mark and sends nothing. A recovery marker alone is not a queued row.
- Session preparation, message start, or turn completion during a query invalidates its snapshot, even if the whole turn finishes before the query returns. The mark remains for a fresh idle query.
- Failed or timed-out queries retain the mark and retry on the timer. After three consecutive failures, the existing failure path surfaces `watcher: FAILED - could not read the wake queue`; retries continue. The subprocess deadline is fixed at 10000ms.

Initial delivery, held flush, replacement handoff, and restored-editor recovery all use this same queue-read/send boundary. There is no per-headline or sequence matching, hold expiry, disable setting, or error-as-empty fallback. Partial acknowledgement leaves remaining rows eligible even within a single watcher close; display differences for decision, merge, multiline, or recovery notifications cannot suppress queued work.
Supervision-host branch-outcome and away-return hand-backs remain operational input: they retain prompt delivery when idle and follow-up delivery when busy, without new durable relay records. They carry only the host's `supervision-host:` lines; a `signal:`, `stale:`, `check:`, or `heartbeat` line from the close is never injected. Main-only checks passed through the host are ordinary watcher closes, not operational hand-backs.
Every other host close that carries a `supervision-host:` line, including a park boundary with no wake line, is an ordinary watcher close: it restores the next park and marks a wake may be due. Its `supervision-host:` lines stay with the mark, followed by the away-posture note while an away record exists, and are appended to the wake built from the queued rows. With no rows, a mark that carries any `supervision-host:` line other than the routine `supervision-host: cycle boundary` line is delivered as the fixed `check: wake may be due` pointer plus its lines; a mark with only the cycle-boundary line, or no host line, is cleared and sends nothing. Replacement handoff and restored-editor recovery follow the same rule through the same queue read.
The existing version-2 replacement handoff stores one `check: wake may be due` message, followed by any `supervision-host:` lines and the away-posture note, plus any operational hand-backs. Old stored watcher messages become the same mark at the read boundary; old operational records retain their hand-back routing and lose their close headlines. A late close republishes the mark even after the bounded shutdown wait.
An unconsumed watcher wake serializes sends until the next `agent_end`, when its pending mark becomes eligible for another queue read.
Preparation that reaches `before_agent_start` but returns idle without user `message_start` also releases the outstanding wake, unless pending vendor messages still accompany that unconsumed watcher; operator edits remain untouched.
[Restored-wake recovery](#omp-restored-wake-recovery) owns consumption and removal of the outstanding token.
`tests/fm-omp-harness.test.sh --watch-queue` exercises the queue-read delivery paths, partial acknowledgement, external recovery, late replacement closes, host routing, token release, editor safety, failed queries, timeouts and slow queries. `tests/fm-wake-queue.test.sh --queued-query` exercises the public read-only queue interface and actor ownership.
The live guard and its evidence are recorded in [omp stale wake gating](verification/runtime-backends.md#2026-10-08-omp-stale-wake-gating).
The Pi and OpenCode extensions still queue every wake as a follow-up and are not covered by this gating.

### omp restored-wake recovery

omp restores queued user follow-ups to the composer when a run is interrupted with Escape or a message is dequeued with Alt+Up, so accepting a wake as a follow-up does not prove a turn consumed it.
Before recording or sending a wake, `.omp/extensions/fm-primary-omp-watch.ts` normalizes CRLF and CR to LF, expands each tab to three spaces, and strips other C0 controls to match omp's editor restoration.
Consumption still matches the emitted text exactly.
An accepted user `message_start` carrying the exact emitted text consumes its pending handoff record and removes its unconsumed token.
With no separately pending watcher work, later turn completion creates no pending mark and runs no queue query.
Busy session state holds any separately pending watcher work until the turn ends.
`before_agent_start` alone does not consume it.
The fixed one-second poll checks stranded text even without `agent_end`. It requires a live generation, a UI editor, positive idle state, and no pending vendor messages.
Only a complete unchanged emitted wake segment, bounded by editor edges or omp's blank-line joins, may be removed; only its leading invisible transport mark may be present or absent. Prefix, suffix, and internal edits stay untouched. Removing a template preserves operator draft bytes, including invisible marks and leading/trailing newlines.
For watcher text, the poll never submits the composer copy: it removes only unchanged template text, releases the outstanding token, and marks that a wake may be due. The same queue-read boundary then builds fresh text from current owed rows, or sends nothing if the queue is empty. Operational hand-backs retain their existing delivery path.
Turn-end release retains unconsumed emitted text until an idle editor check can remove an unchanged template before the next queue-read delivery. Pending vendor messages keep that unconsumed watcher serialized until they clear; a consumed watcher has no token or pending mark to release at turn end.
[Architecture](architecture.md#event-driven-supervision) owns the parent no-draft boundary, secondmate stalled-queue escalation, and idle-ring eligibility.
`tests/fm-omp-harness.test.sh --watch-queue` covers restored-template removal, draft-byte preservation, refusal of edited, busy or queued editor text, and regeneration from a different still-owed payload.
The opt-in live guard and its evidence limits are recorded in [omp injected text through Herdr](verification/runtime-backends.md#2026-10-06-omp-injected-text-through-herdr).

### Cursor stop hook

Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary.
It re-arms by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up.
[`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its Pi-host stand-down, loop bounds, and supersession baton.

### Claude Stop hook

Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
Do not run the hook as a manual arm from a tool turn: a short-lived tool process cannot own its park; its header and help own the invocation contract.
The hook fires on every Stop.
On each Stop, an eligible primary with supervision need admits one home-scoped owner, which foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.

### Claude session-lock ownership

The hook handles the session lock as follows:

- A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes.
- A live owner the session does not own, an absent lock, or a malformed lock keeps the competing hook inert.

Whether the session owns that lock is the shared `fm_session_lock_owned_by_self` verdict in `bin/fm-session-lock-lib.sh`.
That verdict accepts either of two cases:

- A recorded pid inside the current harness ancestry.
- A live lock recorded under this same trusted Claude session id.

With that verdict, a background session keeps arming after its transient helper chain is recycled.
[`turnend-guard.md`](turnend-guard.md#guard-predicates) owns the Claude guard's behavior when that live owner is genuinely another session.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.

### Claude arm failures

With the supervision host disabled, after each non-actionable arm close the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
The beacon is `state/.last-watcher-beat`, which only the watcher process touches.

- A cycle-end failure is benign when that live-watcher predicate is true.
  In that case the hook suppresses the arm output and continues silently.
- Only an exhausted failure with no verified watcher commits one last-resort notice for the continuous failure episode.
- A refused notice commit stays silent for a later retry.
- After a successful notice, later Stop cycles exit 2 without repeating it until the turn-end guard consumes the attended fail-open.

The Claude turn-end guard owns that notice commit contract, the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).

### Supervision host

On a non-Pi primary, a home that runs the supervision host runs `bin/fm-supervision-host.sh` in place of the arm its re-arm owner would start.
The host owns successive watcher cycles through the same arm.
[supervision-host.md](supervision-host.md#failure-direction) owns host-close handling and hand-back downtime restoration; the arm's recovery and acknowledgement contracts below still apply.

## Actionable wake ordering

This section covers what each re-arm owner does between an actionable close and the wake reaching the model.

### Pi, omp, and OpenCode successor start

After an actionable Pi, omp, or OpenCode child close, the adapter:

1. Waits for the predecessor process to close.
2. Starts and verifies one singleton successor.
3. Confirms the handling handoff before scheduling the wake: Pi confirms against the restoration's own recovery token, while omp and OpenCode confirm against the current successor.
4. Delivers the original wake on Pi and OpenCode; omp applies its [queue-read delivery boundary](#omp-stale-wake-gating) instead.

A complete Pi reason line can be observed while the predecessor is still finishing durable cleanup.
That line is retained for replacement handoff, but the adapter never treats that already-ready predecessor as its own successor.

If the handoff confirmation fails, the adapter retries it once: Pi against that same token, omp and OpenCode against the current generation and successor.
A failed confirmation is a restoration failure: the adapter classifies the error and surfaces exactly one typed message.
Pi retires the current successor only when the failed token names its exact watcher pid and generation and that pid is no longer alive, while omp and OpenCode retire the current successor whenever the restoration's watcher pid is no longer alive.
On Pi a generation mismatch means a newer pipeline superseded this delivery mid-restore, so the wake routes like a confirmed delivery, with no failure appendix, and nothing is retired.
An already-acknowledged episode confirms as a no-op when the confirmation names its generation, because the drain acknowledged it after the successor started but before the confirmation ran.
The Pi extension diagnostic log is opt-in and off by default: only a positive FM_WATCH_EXTENSION_LOG_KEEP_LINES value appends restore attempts, readiness timeouts, and confirmation targets and results to state/.watch-extension.log, a bounded record that never changes supervision behavior.
docs/configuration.md owns the knob's default and accepted values.
A failed confirmation is never swallowed.

### Readiness timeout and retry

The adapter waits at most one readiness timeout per attempt.
omp uses FM_OMP_ARM_READY_TIMEOUT_MS for arm readiness, defaulting to 12000ms on non-Windows platforms and 35000ms on Windows; host readiness uses the greater of that arm timeout and 30000ms. Its separate idle queue-read deadline remains fixed at 10000ms.
If the successor is not ready in that time, the adapter sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.

If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and surfaces the typed fallback; omp still holds watcher work until idle and reads current main-owned queued rows before delivery.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, Pi and OpenCode deliver the original wake with a typed continuity-restoration failure, even if every successor arm hung without reporting readiness.
omp surfaces that failure separately from watcher work, which still follows its [queue-read delivery boundary](#omp-stale-wake-gating).

This is deliberate Option B ordering.
Whenever restoration succeeds, the fleet is protected before the model handles the wake.
When restoration does not succeed, the model is never left blind.

### Claude handling successor

Claude's Stop hook also starts one handling successor before notification.
After an actionable foreground close, including an attached peer cycle that ended, the hook:

1. Launches `bin/fm-watch-arm.sh` with the closed arm's pid as `FM_WATCH_PREDECESSOR_ARM_PID`.
2. Waits for that arm's one status line.
3. Only then exits 2 with the wake.

A child of the hook cannot outlive its exit-2 rewake.
So that successor is the one deliberate detached launch in the continuity path:

- It runs under nohup.
- Its stdio is away from the hook's pipes.
- It has its own process group.

This is the shape `bin/fm-startup-network.sh` uses, and [`verification/supervision.md`](verification/supervision.md#detached-session-open-workers-survive-the-hook) verified that it survives the hook.

The next Stop's foreground arm attaches to that live cycle.
A successor that confirms no live watcher adds one line to the rewake banner and never withholds the wake.
The next Stop then re-arms as before.

### Durable queue and turn-end backstop

The durable wake queue preserves actionable events between a watcher close and the next drain.
The bounded turn-end guard enforces recovery at Stop when no watcher is live and no open generation claim is still deciding.
So a finished, hung, or identity-mismatched claim cannot suppress that recovery ([`turnend-guard.md`](turnend-guard.md#harness-integrations) owns that boundary).

The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce.
It enters its poll loop immediately and keeps scanning signals, stale panes, and checks.

### Manual recovery and other harnesses

- The model no longer re-arms after ordinary wakes.
- No PreToolUse hook denies fleet commands based on watcher status.
- A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
- Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
- Codex retains its bounded foreground checkpoint protocol.
- Grok retains its tracked background-task notification protocol.

No adapter starts a replacement with a fire-and-forget shell `&` from a model command.
The Claude hook's detached handling successor is launched by the hook itself, which waits for the successor's status line before it exits.

The turn-end guard remains the final backstop rather than the normal continuity mechanism.
In its `--claude` mode it cooperates with the auto-arm.

## Recovery episode acknowledgement

A recovery episode is one generation of the `state/.watcher-down` marker.
It is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
The away return brief treats a still-open handling episode as a wake in progress, not watcher downtime; an open downtime episode remains a gap.

### Announcement

An unacknowledged downtime generation is announced at most once.
The first recovery marks that generation announced, and later empty-queue arms leave it announced until durable work or interrupted handling makes recovery pending again.
A non-successor watcher start checks the durable queue and recovery marker under their locks.
If an announced-but-unacknowledged episode has an empty queue, the arm leaves that generation announced, making repeated empty-queue arms idempotent while a long-poll source is merely alive.
If a durable row arrived after the announcement, the arm opens a fresh pending downtime generation so buried work still resurfaces once.

### Generation reuse

An ordinary watcher close attempts to publish downtime, and every durable queue append publishes it.
A handling successor closing to resurface recovery preserves the existing marker instead.
If EXIT cleanup cannot acquire the downtime-marker lock within its bound, it retains the stale singleton for the next arm to publish the missing downtime before clearing that lock (see [Grace, beacon, and stop signals](#grace-beacon-and-stop-signals)).
A downtime republication of a pending episode reuses its generation.
A watcher close leaves an announced downtime episode announced, while a successful durable append opens a fresh pending generation so a live watcher can recover the new work.
An announced handling episode becomes pending downtime on the same generation because its handling turn may have been interrupted.
That handling republication gives a successor exactly one recovery presentation without orphaning the acknowledgement already printed for that generation.
A watcher stopped so an arm can take its cycle over (`bin/fm-watch-arm.sh --take-over`) publishes downtime like any close, but the taking arm restores an acknowledged episode that stop reopened only when the taken-over arm's cycle-ledger row for that exact arm and watcher records the watcher ending by the take-over's TERM and no wake was appended in between.
The taking arm waits within a short bound for that row; a missing row or any other signal leaves downtime for the fresh cycle's ordinary recovery wake, while take-over still proceeds.
Any other episode is left for the next cycle's arm check.

### What an acknowledgement retires

An acknowledgement carries two separable facts:

- Queue-row consumption is bound to the monotonic `--ack-through` sequence (further scoped per actor - see "Per-actor acknowledgement" below).
- Only retiring the episode is bound to `--recovery-generation`.

A generation mismatch therefore does not block consumption of rows through that sequence.
It is a non-fatal result that names its own remedy: re-drain, then acknowledge the newer episode.

The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, a watcher close during handling republishes the same generation as pending and forces one recovery turn even when no queue row remains, while the outstanding generation-bound acknowledgement stays valid.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

### Who presents queued wakes between turns

While an auto-arm claim is open ([claim predicate](turnend-guard.md#auto-arm-generation-claim)), the Claude Stop hook is the only deliverer of queued wakes between turns.
Its rewake commit accepts only a downtime marker, so a drain that moves the marker to handling makes the hook drop its wake in silence.
The context re-emit (`bin/fm-session-start.sh --reemit`, sources `clear` and `compact`) delegates this decision to `bin/fm-wake-drain.sh --reemit` at its presentation/mutation boundary.
When the claim is open, the re-emit reports how many records are queued and leaves both the queue and the marker alone.
The drain takes the queue lock before checking the claim under the ownership micro-mutex; ownership-mutex contention also defers presentation without mutation.
Deferred guard checks leave supervision episode state untouched without treating the verified fleet-lock owner as read-only or instructing it to drain from the re-emit; watcher-liveness and worktree-tangle diagnostics still run.
Claim publication waits up to ten seconds for the queue lock before attempting the ownership micro-mutex without waiting, and releases both before arming, so transient queue writers do not abandon delivery and a new claim cannot appear between the drain's check and its queue/marker mutations.
The ownership micro-mutex is never held across a lock wait or output.
The handling turn the hook starts then runs the ordinary presentation drain, which enters handling, and uses the emitted `--ack-through` command only after handling completes.
Once the claim is finished or absent and the ownership micro-mutex is available, the re-emit drains as before; homes without a Claude epoch ledger retain their ordinary drain behavior.
A refused rewake commit (including a non-downtime marker or lost session-lock ownership) exits 0, removes its output file, and best-effort records `outcome=refused` in the epoch ledger; the ownership-checked write cannot overwrite a newer generation.
`tests/fm-session-start.test.sh`, `tests/fm-wake-queue.test.sh`, and `tests/fm-claude-stop-autoarm.test.sh` cover deferral, serialized claim publication, ordinary presentation after a finished claim, and refusal cleanup.

## Per-actor acknowledgement

`bin/fm-wake-drain.sh` consumes the queue per actor, not per whole-queue cutoff.
It uses the `fm_lease_actor` identity owned by `bin/fm-lease-lib.sh`.
The Pi branch extension injects its branch actor into its own bash tool calls.

### Claiming rows

Every presented row is claimed to exactly one actor under the durable queue lock.

- Main records its presented set in `state/.main-eligible-rows`.
- A branch grant is published through `bin/fm-wake-grant.sh` under that same lock in `state/.branch-eligible-rows`.
  The grant is bound to the live branch process and extension generation recorded in `state/.branch-eligible-owner`.
  Publication is refused if main already claimed any requested row.
- A main drain validates that owner evidence under the queue lock and reclaims the grant when its process is gone or its identity no longer matches.
- A main drain claims every currently unclaimed row and excludes an active branch grant from both presentation and acknowledgement.

### Lock deadlines during presentation

An ordinary presentation drain bounds both its initial queue-lock acquire and its later status-presentation-lock acquire at the deadline owned by the script header.

| Lock with a live holder | Drain result |
| --- | --- |
| Initial queue lock | One PID-naming advisory, and the whole drain is skipped before any claim or mutation. |
| Status-presentation lock | One such advisory after raw wake presentation, and status annotations, sections, and cursors are left retriable on the next drain. |

Acknowledgement invocations and every other mutation-critical queue-lock acquire retain blocking semantics while the lock's parent directory exists, so acknowledgement atomicity is unchanged.

### Vanished fixture state

Queue/grant operations and both acknowledgement acquisitions stop before entering the failed acquisition's critical section when fixture state vanishes, even if the directory returns immediately after failure.
[`fm_lock_acquire_wait` in `bin/fm-wake-lib.sh`](../bin/fm-wake-lib.sh) owns the missing-parent grace and caller safety contract; [`tests/fm-orphan-safety.test.sh`](../tests/fm-orphan-safety.test.sh) exercises failure propagation with returning state.

For ended lab/test process cleanup and its regression entry points, see the authoritative [`bin/fm-test-reap-orphans.sh` header](../bin/fm-test-reap-orphans.sh).

### Guard counts for branch-held rows

Because the main drain's exclusion makes branch-granted rows invisible to main, `bin/fm-guard.sh`'s queued-wake warning counts only the rows the calling actor can itself present or retire.
So an actor is never sent to a drain that provably has nothing for it.
`bin/fm-wake-lib.sh` owns that per-actor count (`fm_wake_actor_pending_count`) alongside the grant row-list and owner-record reads that the drain and `bin/fm-wake-grant.sh` share.

A row a live grant reserves is therefore never counted as drainable for main.
Rather than going silent about a visibly non-empty queue, the guard prints a distinct advisory.
That advisory names the live supervision branch as the holder and says not to drain those rows from here.

The branch actor's queued-wake output stays suppressed in every case.
A main drain with nothing of its own left, and a live grant still holding the queue, says so in one bounded line instead of exiting silently.

### Structurally unusable rows

A row that lost the five appended fields or its numeric sequence can never be claimed, presented, or named by an `--ack-through` cutoff.
A main drain retires such a row under the queue lock.
It reports how many it removed, together with those rows verbatim, bounded to the first 20 and a count of the rest, because the queue was their only durable record.
A branch drain never retires them, because a grant can only name sequences that were structurally valid when it was published.

A retirement that cannot be read or written is reported and never fails the drain.
The rows that remain usable are still presented with their acknowledgement command, and the unusable ones stay queued for a later drain to retire.
Failing the whole drain would strand the usable rows too.

### Acknowledgement cutoffs

| Acknowledgement | What it deletes |
| --- | --- |
| Main `--ack-through <SEQ>` | Only claimed main rows at or below the cutoff. |
| Branch | Only claimed branch rows at or below its cutoff. |

A main acknowledgement first claims every unreserved row at or below its cutoff, so none is stranded.
It leaves a row above the cutoff that arrived after presentation unowned, so an away-session grant can still take it rather than handing every later wake back to main.

Every settled branch prompt releases any residual grant.
So an omitted or failed acknowledgement leaves the durable row available to a later main drain.
A successful acknowledgement has already removed it.

An acknowledgement can remove none of the actor's rows while a presented row above the cutoff still waits.
Such an acknowledgement is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row.
The presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.

If a branch offer loses the claim race to main, it rejects its settlement so the watcher retains the actionable close until Pi accepts its main follow-up.

### Branch eligibility and check rows

[`pi-supervision-branch.md`](pi-supervision-branch.md#components-and-their-owners) owns branch eligibility, mixed-queue dispatch, the pre-drain recheck, and heartbeat's all-or-nothing rule.

While attended, a check-kind row is main-owned, including a heartbeat review.
So it is never part of a branch claim and never defers one.
Main is woken for it on that check's own triggering close.
Under the away-posture record the exclusion lifts and a check row is offered to and claimed by the branch like every other actionable row.

`fm-wake-drain.sh` never reclassifies a row itself.
It filters the queue to the current actor's opaque claim before same-key deduplication, then presents and acknowledges only that actor-local view.
A missing or empty branch snapshot is refused loudly rather than read as "nothing eligible", because reaching the drain without the non-empty handoff promised by the extension is a wiring bug.
A branch acknowledgement retires the check-row receipts - inactive-outcome, inactive-reconcile notice, and secondmate stall - of exactly the granted sequences it consumes, so a branch-consumed check is never re-queued by its producer.
Attended, a grant names no check row and each scan finds nothing.

### Per-actor regression tests

`tests/fm-wake-queue.test.sh`'s mixed-queue actor, stale-acknowledgement remedy, and presentation-deadline tests drive the real scripts and check that:

- Branch acknowledgement cannot swallow a main row.
- A concurrent main turn cannot present or acknowledge an active branch grant.
- A no-op stale acknowledgement names the current presented wake's exact command.
- Live-holder presentation contention stays bounded and retriable.
- Acknowledgement locking follows the [lock deadline contract](#lock-deadlines-during-presentation).

The same suite pins the counted-equals-presentable invariant against `bin/fm-guard.sh` and `bin/fm-wake-drain.sh` together:

- A branch-held row raises the held advisory rather than the ordinary queued-wake warning for main.
- That row is presented with its acknowledgement command - with the ordinary warning restored - as soon as the grant clears.
- Structurally unusable rows are retired by main alone while every remaining row stays presentable and acknowledgeable.

Branch acknowledgement retiring the check-row receipts of exactly its granted sequences is pinned by `tests/fm-wake-queue.test.sh` for the secondmate stall receipt and by `tests/fm-inactive-reconcile.test.sh` for the inactive-outcome receipt.

`tests/fm-pi-branch-extension.test.sh` pins extension-side classification, claim publication and release, and the pre-drain recheck.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.

### How an arm resolves a close

| Child return | What the arm does |
| --- | --- |
| Actionable output | Returns that reason normally. |
| Zero/empty | Rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger. |

An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one.
It does this because it holds no handle on the watcher's stdout and cannot read the reason line itself.

### Terminal-delivery ledger

Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero, even after its durable wake was handled and acknowledged.
An unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

### Cycle exit log

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes:

- Arm and watcher PIDs.
- Start and end timestamps.
- Exit code and signal.
- Classified reason.
- Beacon age.
- Lock identity before and after close.
- Successor disposition.

The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

### Grace, beacon, and stop signals

The default 300-second grace is unchanged.
Only the main watcher shell touches `state/.last-watcher-beat`, at cycle boundaries, between poll stages and fleet items, and while actively waiting for a deadline-bounded custom or PR check.
Those intermediate touches are throttled to at most once per `min(15, grace / 3)` seconds, with a one-second floor.
The main shell enforces the check deadline even if the check's timeout controller stops responding.
Home-summary publication runs separately so its inventory-sized work does not delay the main poll.
The [process-event operating contract](configuration.md#process-to-event-sources-stateprocevent) owns background source reconciliation and queued-result delivery.
The [pending-reply library](../bin/fm-pending-reply-lib.sh) owns retained-reply scanning and escalation-close retries.
There is no independent heartbeat timer: a main shell blocked on an unbounded operation, stopped, or dead stops publishing progress and becomes stale.
Subprocesses doing scan or capture work cannot beat for a stopped main shell.
This distinguishes a progressing slow pass from a stuck loop without raising grace; it cannot guarantee freshness when the host does not schedule the main shell for an entire grace window.
An arm whose own script path sits under a disposable no-mistakes validation checkout (`.no-mistakes/worktrees/`) refuses with the typed failure line before touching any state, because a watcher started there outlives the validation step and keeps writing the real home's state from a checkout about to be deleted.
Once per poll the watcher checks that its home, its state directory, and its own code root still exist, and exits with a logged reason when one is gone, scoped to itself alone, so a torn-down temporary home or a discarded checkout never leaves an orphan watcher behind.
The watcher uses bash's native fatal handling for HUP and TERM, including during a blocked check or a blocked `fm_backend_capture` pane read, so both run its EXIT cleanup and stop that read.
`watcher_stop_signals` in `bin/fm-watch.sh` owns the signal-handling rationale.
The EXIT cleanup bounds its wait for `state/.watcher-down.lock` while persisting recovery state with `FM_WATCHER_CLEANUP_LOCK_BOUND` (default 2 seconds).
Only positive decimal integers are accepted, including leading-zero forms such as `08`; empty, non-numeric, and zero values (including `00`) fall back to 2 seconds.
A live foreign holder therefore cannot strand a TERM'd watcher in this marker-lock wait: on timeout the recovery transition fails without releasing the singleton, leaving dead-pid stale evidence for the next arm to republish and clear.

## Regression coverage

### Pi and OpenCode watch extension

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops.
It then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, and:

- Blocks prompt delivery to prove the successor launches first.
- Verifies single-flight behavior.
- Changes the session lock before close to prove ownership is rechecked.
- Hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.

The same suite covers ordinary same-process session replacement for `/new`, `/resume`, `/fork`, and reload, plus:

- Same-instance shutdown-plus-start.
- The predecessor remaining live under a handoff generation until its replacement commits.
- Bounded retry after that replacement kills the predecessor but fails before readiness.
- Automatic re-arm before any model turn.
- A fresh extension-module rebind carrying all in-flight actionable closes exactly once.
- Stale prior-generation callbacks.
- Repeated transitions with exactly one live cycle.
- Disappearance of the shutting-down refusal after a valid replacement activates.
- Terminal quit still refusing late rearm.
- A mid-restore marker advance that delivers the wake with no rejection appendix, offers it to an accepting supervision branch like a confirmed delivery, and records the attempt and the confirm result in the bounded extension log when opted in.
- A failed confirmation for a stale successor that spares a newer arm started by a repair.
- A repair, a scheduled retry, and a deferred close over a dead-but-unclosed arm child that each start a fresh arm instead of stalling.

`FM_PI_WATCH_LOADER_LIVE_E2E=1 FM_PI_PACKAGE_DIR=<installed-pi-package> bin/fm-test-run.sh tests/fm-pi-watch-loader-live.test.sh` exercises the real Pi resource loader and session runtime without provider calls.
It loads the watcher plus a re-exporting entrypoint, checks startup and idempotent arm-tool execution, and reloads with one live successor and no duplicate tool registration.
All homes and agent configuration are disposable; the runner includes this guard in `live-harness-optin`.

The guard and session-start suites prove that active generation evidence tolerates a fresh-beacon handoff.
They also prove that a legacy or handoff-phase watcher marker from an absent replacement extension still raises the outage diagnostic.

### Arm, recovery, triage, and lock suites

`tests/fm-watch-arm.test.sh` covers:

- Durable queue replay.
- Real remote parent-replies ingestion into the authoritative status log.
- Decision-only OPEN DECISIONS recovery.
- Interrupted handling replay.
- Generation-bound acknowledgement.
- A persistent live successor after recovery.
- An idle live Lavish source that stays quiet until its real result is durably queued and closes the arm successfully, without requiring one reason to win the process-event/recovery observation race.
- An append that reopens an announced empty recovery.
- A watcher close inside the handling window that must leave the printed acknowledgement valid.
- A re-arm whose recovery cycle is slowed after confirmation and must still surface rather than read as a watcher that stayed live.
- The self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
- The already-acknowledged confirmation no-op for a matching generation, with its mismatched-generation, dead-pid, and lock-mismatch rejections preserved.
- The manual-restart generation churn that makes a confirmation for the churned generation report a mismatch, which an arm check without a reopen leaves in place.
- A take-over that stays quiet after a confirmed TERM, still surfaces queued work and self-exit downtime, and attaches without stopping a cycle the named arm does not own.
- The disposable-checkout arm refusal.
- The home-gone and state-gone watcher exits.
- The test reaper that stops a watcher armed for a temporary home.

`tests/fm-watch-recovery-loop.test.sh` covers:

- The once-per-generation announcement bound with the real Pi extension against a refused handling handshake.
- A handling successor that must surface a real crew event instead of going blind.

`tests/fm-watch-triage.test.sh` proves an unbounded pane capture stops refreshing the beacon, and TERM stops that watcher while still releasing its lock and recording an acknowledgeable stop.
It also exercises a single TERM with a live foreign downtime-marker lock holder, retained stale singleton and subsequent arm-style recovery, including decimal `08` and zero `00` cleanup bounds.
It checks that a newly appended keyed decision is classified without rereading earlier status bytes, so signal handling can return to the watcher's beacon refresh even when the status history is long.
Completed-cycle waits observe the test-owned terminal poll-wait boundary in the fixture's explicit state directory, not intermediate progress-beacon writes.
Process-event fixtures pass both the home and its matching explicit state directory to every watcher launch, including output-failure launches, so the same completed-cycle boundary covers replay, handling acknowledgement, and the absence of duplicate wakes.
`tests/fm-wake-queue.test.sh` proves TERM likewise stops a watcher blocked in the drain-ring idle check's pane capture.

`tests/fm-watcher-lock.test.sh` covers:

- Verified-successor attach.
- Recovery publication before stale-lock removal.
- The typed self-eviction failure.
- Bounded and successor-linked lifecycle rows.
- A SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
- A single slow, deadline-bounded check keeps the strict watcher predicate healthy beyond grace, while stopping that same main poll makes its beacon stale even with its check child still alive.

### Claude auto-arm and turn-end guard

`tests/fm-claude-stop-autoarm.test.sh` covers:

- The auto-arm's scope.
- Stale and live session owners.
- Unchanged AFK and need boundaries.
- Single-flight.
- Bounded failure retries.
- Benign live-watcher cycle ends.
- One-notice failure episodes.
- Exit-2 translation.
- The handling successor an ended attached cycle starts with the closed arm as its predecessor and that outlives the rewake.
- An unconfirmed successor reported in the banner without withholding the wake.
- Host-timeout HUP/TERM/INT translation into the same durable failure handoff.

It also covers generation-claim single-flight, stuck-claim supersession, superseded-owner silence, notice-marker refusal and retry, ownership-atomic episode reset, and the legacy upgrade shim.
[`turnend-guard.md`](turnend-guard.md) owns those behavior contracts.

`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh`:

1. Starts with the reproduced stale-lock state.
2. Receives session start through the tracked SessionStart hook.
3. Completes two tokenless cycles.
4. Checks the competing-live-owner negative control.

`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including:

- Monotonic failed-epoch progression.
- The integrated bounded fail-open.
- Post-alarm continuation suppression.
- Positive recovery reset.

[`turnend-guard.md`](turnend-guard.md#regression-coverage) lists that suite's full generation and legacy claim coverage.

## Active limits and verification

The goal is continuity without a Pi, omp, or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed, because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.

The other harnesses rely on these mechanisms:

- Claude depends on the Stop `asyncRewake` rewake.
- Cursor depends on its awaited stop-hook park.
- Grok retains native background-completion notifications.
- Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current cross-harness live evidence, the dated Stop-owned Claude auto-arm results, and exact opt-in commands.
