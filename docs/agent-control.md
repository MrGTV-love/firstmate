# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The [`fm-send.sh` header](../bin/fm-send.sh) owns typed-plane delivered-unconfirmed results, pending-reply retention, decision closure, and safe resend guidance; the [inbox ring owner](../bin/fm-task-inbox-lib.sh) owns pre-submit draft-risk deferral.
Do not retype or blindly resend after an unconfirmed submit.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, which have no side effects, so they can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `stay`, `relaunch`, `authorize-continuation`, `reassociate`, `adopt`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
  `bin/fm-send.sh`'s `--key` path reads the composer-clear table from this owner too, rather than keeping a second copy of it.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped.

The [endpoint-absence proof](#reclaiming-a-task-whose-endpoint-is-gone) and its worktree-holder helper perform backend and process reads; the capability tables remain pure, and sourcing the file performs no probes.

A recorded `harness=` is not always an exact adapter name: a task launched from a raw command records that command's basename instead.
`fm_control_harness_family` is the one place that prefix rule is stated, and an unrecognized value resolves to no adapter rather than being guessed into one.

## Verbs

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; cancellation is confirmed only from an adapter-owned acknowledgement and otherwise reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Already-stopped is idempotent success. A `missing` endpoint goes through the shared [absence proof](#reclaiming-a-task-whose-endpoint-is-gone): proven gone reports `endpoint-gone`, a surviving idle pane reports `already-stopped`, and a surviving agent takes the ordinary interrupt-then-exit path. Unproven absence refuses. |
| `stay` | Close Claude's background-task exit picker for a live task and leave the agent running; see [Exit and the background-task picker](#exit-and-the-background-task-picker). | A readable viewport no longer shows the recognised picker and the endpoint still classifies the agent alive. Any other screen, harness, or stopped agent refuses with nothing sent. |
| `relaunch` | Replace the running agent with a new one in the same worktree by default (see the [missing-worktree exception](#relocating-a-task-whose-worktree-is-gone)) - and the same endpoint whenever that endpoint still exists - on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the endpoint the task's record now names, and that record names the harness that is actually running. |
| `adopt` | Repair a live local Herdr omp task's session record without sending input or restarting anything. | The recorded pane, unique foreground PID, unique deepest workspace match, exclusive local pane claim, and unchanged generation are proved before publishing; see [Repairing a restored omp session record](#repairing-a-restored-omp-session-record). |
| `authorize-continuation` | Clear a ship or scout's recorded reconciliation-only restriction without launching or messaging a worker. | Only `recovery=reconcile-only` is removed atomically; unrelated metadata, holds, and dependencies are preserved. |
| `reassociate` | Re-point a ship or scout's record at the replacement copy its work moved to, without stopping, starting, or removing anything. With `--also <task>=<copy>` it re-points several records that share one pool slot root in the same call. | The record names the replacement copy and the copy it left as `prior_worktree=` (or `released_worktree=` for a pool slot it left); the old copy, the endpoint, and any pipeline run are untouched. Every record named in one call is re-pointed or none is. See [Reassociating a task with a replacement copy](#reassociating-a-task-with-a-replacement-copy). |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.
Claude exposes no lifecycle acknowledgement for a manual interrupt, so delivery succeeds with `cancel=unconfirmed` and its adapter-owned busy state remains as observed.
Devin emits no lifecycle hook for cancellation either, so after an armed interrupt the control plane invalidates the interrupted turn's busy record to `unknown` with `cancel=unconfirmed`; that invalidation is a conservative loss of knowledge, never a fabricated idle.
Devin's double Escape also opens its `/revert` picker on an idle agent, where Enter reverts file changes, so its second press is sent only after the first renders a running turn's armed hint and never sooner than the adapter's press gap.
An interrupt whose first press shows no running turn stops there and reports `cancel=not-running`, leaving busy state untouched; a picker a mistimed press opened is closed with one Escape and reported as `revert-picker=dismissed`, and `exit` refuses to type into an open picker.
[`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh) owns the arm signal, press gap, and picker signal.
muse's session log records `terminal=cancelled` for the interrupted run, so the control plane reports `cancel=confirmed` only after observing that exact acknowledgement.

Interrupt delivery does not guarantee an empty composer.
muse's verified adapter follows its interrupt key with Ctrl+U because leaving the cancelled prompt there would concatenate it with the next submitted line, including this plane's own exit command.
The clear is refused before anything is sent when the recorded backend cannot deliver it.
omp sends no clear key; queued follow-ups can return to its composer, with watcher-specific handling owned by [restored-wake recovery](watcher-continuity.md#omp-restored-wake-recovery).

`exit` reads the composer's state before typing the exit command and requires the exact `empty` verdict; a `pending` verdict refuses by naming the pending text, and any other verdict (`unknown`, `unknown-draft`, `pending-unproven`, or an unreadable read) refuses as not proven empty, matching the fail-safe contract every other consumer that can overwrite composer input follows.
The [shared composer classifier and its shape catalogue](../bin/fm-composer-lib.sh) own continuation containment, draft-risk verdicts, extraction, and known limits; lifecycle callers cannot treat a nested prompt or frame as independent empty proof.
The [inbox ring owner](../bin/fm-task-inbox-lib.sh) separately defines the advisory doorbell pre-check.
`exit` also refuses, naming the dialog as `blocked on a prompt`, when the screen shows a recognised dialog that a further Enter would answer, whether the dialog was open before the exit command was typed or the submitting Enter opened it.
A stopped agent whose pane still shows the dialog text is not refused.
[`fm_composer_blocking_dialog`](../bin/fm-composer-lib.sh) owns the recognised set, which today is only Claude's background-task exit picker; [its verification record](verification/runtime-backends.md#claude-background-task-exit-picker) lists the dialogs that are not covered.
The one answer `exit` gives a recognised dialog is the picker's, under the proof in the next section, and it never answers or dismisses a dialog it does not recognise, because any answer to one can write a permanent decline.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
It is not deterministic across the verified adapters: codex, grok, gemini, and devin resume only from a session id printed at exit, opencode continues the most recent session for the cwd, and claude, pi, pi-signed, omp, kimi, and agy have no verified general pane-resume contract.
`relaunch` uses the brief on disk - not a harness-private session - as the durable instruction when the backend can prove the old agent stopped and the composer is empty; Devin on Herdr and agy on tmux currently fail that composer check and refuse.
A relaunch does take one session reference when the endpoint's own runtime recorded it - see [the relaunch transaction](#transactional-relaunch) - but that is a relaunch input, not a caller-facing verb.

### Exit and the background-task picker

Claude opens a "Background work is running" picker when `/exit` meets a running background shell.
Its selected row is "Exit and stop tasks", and its footer reads "Enter to confirm · Esc to cancel".
A worker parked on it holds every later steering message behind it, so two supported answers exist.

- **A finished task is stopped.**
  `exit` chooses "Exit and stop tasks" only for a Claude ship or scout whose own state, read successfully through [`bin/fm-crew-state.sh`](../bin/fm-crew-state.sh), is a terminal `done`, and whose busy record read `idle` before anything was sent.
  An `unknown` busy record is never promoted to idle, so it refuses like a busy one.
  A task whose steering inbox still holds an unhandled record also refuses, because a parked picker blocks the doorbell and stopping the task would leave that steering unread; release it with `stay` first, let it read and acknowledge the steering, then `exit`.
  A `failed` task is not finished: it is usually steered and retried, so its picker is released with `stay`.
  The composer proof is this exit's own: the picker opened after the exit proved the composer `empty` and typed `/exit`, so `/exit` is the only input it holds.
  The endpoint is read again immediately before the confirming Enter and must still classify the agent `alive`, and on Herdr it must still pass the [live task-attribution guard](#live-herdr-task-attribution); an ambiguous, unreadable, or missing read refuses with the picker left as it was.
  The screen is read again immediately before the confirming Enter, and the postcondition is the ordinary agent-gone proof.
  A picker that was already open when `exit` began is first closed with the stay key and the composer is read again, so a draft the picker was hiding still refuses the exit and is preserved.
- **A live task is released with `stay`.**
  `fm-control <task> stay` sends one Escape, only while the recognised picker is the visible screen, and then requires a readable viewport that no longer shows it and an endpoint that still classifies the agent alive.
  Escape is the picker's own cancel key and is bound to the same handler as its Stay row, so the agent keeps running and its composer is usable again.
  A refused `exit` leaves the `state/<id>.control-exit` marker it wrote before typing `/exit`, so a person who answers the picker by hand still ends the session as deliberate.
  Closing the picker with `stay`, or with the stay key `exit` sends to a picker that was already open, cancels that exit, so the close removes the marker when it names the task's current busy generation and leaves a marker from any other generation alone.
  A cancelled exit therefore never suppresses the session-end auto-relaunch of an agent that keeps running.

Every other case keeps the refusal and names how to close the picker: a task whose state is not done, a state that cannot be read, a busy record that does not read idle (busy or unknown), unread steering in its inbox, a secondmate, any other harness, and `relaunch`'s own stop.
The state read happens only while the picker is showing, is bounded by `FM_CONTROL_CREW_STATE_WAIT`, and skips the forge read.
`stay` sends nothing on any screen that is not exactly the recognised picker, on any harness other than Claude, or to a stopped agent.
It never sends Ctrl+C or Ctrl+D, which the picker is configured to treat as an exit request.
The [verification record](verification/runtime-backends.md#claude-background-task-exit-picker) states what is measured and what is read from the vendor's source.

## Transactional relaunch

`relaunch` runs as a transaction with a journal at `state/<id>.control-relaunch`, the prior record preserved beside it, and a ship or scout's prior instructions preserved when a progress note is appended.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins.
   Otherwise a `kind=secondmate` task re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A recorded raw-command basename that differs from its resolved adapter cannot reproduce the command actually running, so relaunch refuses before the checkpoint unless the caller passes an explicit `--harness` to choose the replacement runtime deliberately.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
   `--claude-debug` is off by default, refused unless the resolved replacement harness is claude, and passed through to the launch; the [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) header owns what it turns on, including the diagnostics file that names the signal of the next stop.
   A Claude or Pi replacement must also pass the home's [worker account pin](configuration.md#worker-account-pin-configclaude-account-configpi-account), so a pin that no longer resolves or is signed out refuses before the old agent stops.
   Claude replacements also honor the home's [Claude launcher](configuration.md#claude-launcher-configclaude-launcher) preflight.
   The resolved replacement is also subject to the home's [session launch policy](configuration.md#session-launch-policy-configsession-launch-policy) before checkpointing.
   Model resolution and selected-entry catalog preflight follow the [fleet model-index contract](configuration.md#fleet-model-index-configmodel-indexjson) before the old agent stops.
   A replacement model that a newer model of its own family and tier has passed is refused before the old agent stops, unless it is the model the task already records or `--captain-model-pin <model-id>` names it exactly; the pin is passed through to the launch, and [model freshness](configuration.md#model-freshness) owns the gate.
   Omp replacements must pass the [launch owner's billing-route admission](../bin/fm-spawn.sh) for explicit, recorded, indexed, and secondmate-pinned model selections before checkpointing or stopping the old agent.
   A dsh replacement must pass the executable probes and concrete DeepSeek model admission before the old agent stops, so a replacement with no DeepSeek model id refuses there rather than after the stop; [the dsh adapter reference](../.agents/skills/harness-adapters/references/harness/dsh.md) owns those checks without a version pin.
   A plain relaunch of a secondmate already running dsh never discards its conversation: when config/secondmate-harness names no model and no effort, or names the recorded ones (a role compares by the model it resolves to), the replacement keeps the recorded model and effort and resumes; when it names a different model or effort, the relaunch refuses before the old agent stops, naming both profiles, and an explicit `--model` or `--effort` that differs from the recorded profile starts a fresh conversation instead.
   Otherwise a configured dsh harness that names no model carries the calling DSH session's bound model, read through `bin/fm-dsh.py own-model` exactly as a spawn does, and refuses naming the missing model configuration when no live record supplies one.
   An explicit `--harness dsh` keeps the recorded model of a task already running dsh, and needs `--model` when it moves a task onto dsh; an explicit `--model` equal to the recorded one, or a role resolving to it, without `--effort` keeps the recorded effort, so the same conversation resumes.
   Ship and scout replacements also pass the [worker tool exclusion checks](configuration.md#worker-tool-exclusions-configcrew-exclude-tools) at this step.
2. **Check replacement admission, then checkpoint.**
   The control plane checks the launch owner's read-only backlog admission before appending a note or stopping the old agent, so a predictable held or dependency-blocked replacement refusal leaves that owner intact.
   [`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh) owns the shared rule; both control and direct replacement launch recheck it.
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   A ship whose recorded worktree is gone is the one exception, and only through [Relocating a task whose worktree is gone](#relocating-a-task-whose-worktree-is-gone).
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
3. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
4. **Stop the old agent** through the `exit` verb, with its postcondition.
   Before the stop, a Claude replacement must pass the [Claude API key guard](configuration.md#claude-api-key-guard), so a relaunch whose replacement an Anthropic credential would reach refuses while the old agent and its instructions are untouched.
   The exit verb writes `state/<id>.control-exit` bound to the busy generation before it types the exit command.
   A known non-delivery (`send-failed`) removes that marker before refusing; this includes the [Herdr pre-Enter proof refusals](herdr-backend.md#claude-composer-proof).
   A completed exit retires the busy record, so the session-end tick already skips it; the marker covers an exit whose command was delivered but whose agent did not stop within the exit wait, and `bin/fm-session-end-relaunch-lib.sh` owns how a later tick reads it.
5. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which uses the checkpointed worktree without allocating one, adopts the recorded endpoint when it still exists, clears the previous harness's per-task wiring, and arms a fresh busy generation.
   When the recorded endpoint is proven gone rather than merely idle or unreachable, the launch owner creates one fresh endpoint in that worktree and republishes the binding, subject to the backend policy in [Reclaiming a task whose endpoint is gone](#reclaiming-a-task-whose-endpoint-is-gone).
6. **Preserve runtime-bound status authority where supported.**
   The endpoint's runtime may bind pane status to one session identity; the launch owner preserves it only when that runtime records a reference the replacement adapter can consume, and otherwise launches the ordinary fresh session.
   This reference is a launch input, never authority to send, close, or act on the pane.
   [`docs/herdr-backend.md`](herdr-backend.md#agent-status-authority-and-relaunch) owns the mechanism and measured behavior.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Inspecting a bare native restore

Herdr can resume a live omp harness after reboot without the Firstmate launch command.
That native restore is unmanaged: neither its resume path nor the original launch message proves which conversation the live process currently owns.
Only the explicit [omp session-record repair](#repairing-a-restored-omp-session-record) can later authorize lifecycle control for it.
`bin/fm-reboot-recover.sh` inspects only the current home's recorded Herdr ships, scouts, and local secondmates and reports unmanaged live launches without lifecycle input or task-record mutation.
The script's [header and help](../bin/fm-reboot-recover.sh) own invocation, bounded-scan scheduling, and its durable cursor.
Deferred startup inspection follows the existing bootstrap sweeps, which keep their recovery responsibilities.
The watcher repeats the bounded scan to catch panes restored only after a viewer attaches and emits each sweep's diagnostics as an independently keyed `check` wake.
A bounded scan reports a task's notice once per verdict and restored-agent identity (pane, PID, and start time), so an unchanged unmanaged agent wakes Firstmate once rather than on every scan; `state/<id>.reboot-notice` holds that last notice, and relaunch and teardown remove it.
The unbounded startup sweep always reports.
Remote secondmates, other backends, missing agents, and stopped agents retain their existing recovery owners.
Unreadable endpoint inspection is reported as a task-specific failure without lifecycle action, not silently treated as a missing or stopped agent.
The sweep never discovers other homes' panes or recursively enters a secondmate home.

The [control script's header and help](../bin/fm-control.sh) own its inspection-only relaunch option and argument exclusions.
Under the task's control lock it inspects the live launch and reports unmanaged proof without interrupting, exiting, checkpointing, noting, or replacing the agent.
It leaves managed and stopped agents untouched.
Unknown versioned proof refuses.
A legacy record (empty `launch_proof`) keeps exit and relaunch, so inspection reports an unpinned legacy omp as `legacy record; exit and relaunch are allowed` rather than unmanaged, and other legacy-unproven proof skips.
The bounded sweep reports that legacy notice once per restored-agent identity, like an unmanaged notice.
Drafts, busy state, task instructions, profile axes, charters, child records, and unlanded work remain unchanged.

### Repairing a restored omp session record

Run `FM_HOME=<home> bash bin/fm-control.sh <task-id> adopt` to repair a local Herdr omp session record after a restart.
Only the actual lock-owning main Firstmate may run it: a worker, the supervision branch in any posture, or a session that does not own the home's lock is refused without changing the record, under the same rule as `authorize-continuation` and `reassociate`.
The [control script header](../bin/fm-control.sh) owns the five required proofs, exact fields, locks, conditional publication, and refusal contract; [the launch-proof library](../bin/fm-launch-proof-lib.sh) owns pane and foreground-process attribution.
The command writes only the session record, never unlocks a session, modifies a project, sends keys, or starts or stops an agent.
It preserves the recorded task session file and requires the pane's omp session-file reference to identify that same persisted file; a missing task session field can be initialized from that reference.
A stale registration alone grants no authority.
The resolved foreground process must also classify as an agent process, so a registration that outlives its agent cannot make another program in the worktree a lifecycle target.
Only a record whose process is gone is the repair target.
A record naming any live process is refused unchanged, because the extension of a live process rewrites its record by rename and without the control locks.
That covers a healthy activation for the resolved foreground PID, the extension's own empty unproven mark (written on shutdown, before a switch, or after a failed start), an activation naming another file (a different conversation), and a recorded PID that an unrelated live process has since reused.
Herdr still registering the original task file never overrides that evidence.
Publication is conditional on the record staying as it was proved: the record is set aside, compared with the bytes the proofs were gathered from, and replaced only through a link that never overwrites.
A record the extension publishes meanwhile is kept, and the adoption refuses.
Every refusal names the missing proof, and no refusal lowers the workspace or duplicate-pane requirements.

**This widens what authorizes lifecycle control: a re-stamped record can become managed without the original launch environment pin.**
Lifecycle readers recheck the adoption proofs and the same live PID and session file before using that alternative authorization, so a workspace claimed by another task, a duplicate pane claim, or a changed generation still refuses even after a successful repair.
A repaired record only replaces a readable environment that lacks the pin; an environment pinned to another launch generation belongs to a different launch and is refused at adoption and at every recheck, and an unreadable environment still reads `unknown` and authorizes nothing.
This is an explicit repair, not an automatic restart fix: the omp extension's launch-generation recovery and empty-session classification are unchanged.

**Residual risk:** nothing watches which conversation an adopted process runs.
The omp extension rewrites the record on every conversation switch only for a launch-pinned process, and an adopted process has no pin.
An adopted record therefore relies on Herdr's session registration until the extension records switches without a launch pin.
A switch to a personal conversation that Herdr has not yet registered is not seen, and the record can still read as managed.

### Live Herdr task attribution

`bin/fm-launch-proof-lib.sh` owns launch attribution, and runtime lifecycle paths to a live Herdr agent use one shared positive task-attribution guard before lifecycle input or a relaunch checkpoint, note, or record mutation.
A recorded endpoint or matching cwd alone never proves live task ownership; the explicit [omp repair route](#repairing-a-restored-omp-session-record) combines them with independent process, unique-claim, generation, and session-file proof.
The stopped-agent exception requires process-backed absence even when Herdr has not registered an agent; a live process still requires launch attribution, and unreadable process evidence refuses recovery.
Only managed launches authorize ordinary interrupt, exit, busy-exit, and relaunch of a record with `launch_proof`.
A record published before launch proofs existed (empty `launch_proof`) keeps the earlier rule: its live agent at the validated endpoint is attributed without a pin, and its relaunch publishes a proven launch.
New Herdr launches on every harness record `launch_proof=env-v1` and put the recorded `spawn_gen` into the agent's `FM_SPAWN_GEN` environment, **not** the persistent pane shell.
The staged launch runs in a subshell of the destination pane shell, preserving its raw-command syntax without leaking the incarnation into later bare resumes.
An enabled `config/launch-env-allowlist` still selects the existing cleared-environment POSIX-sh boundary.
`tests/fm-spawn-herdr-launch-shell.test.sh` exercises these shell and environment boundaries through staged launch delivery.
The unique ancestor-most non-shell process in the foreground group supplies the live PID; kernel ancestry excludes launcher shells and helper workers.
A process that Herdr lists but the later process table lacks has already exited and is dropped; a vanished agent, a broken chain, or two agents still read `unknown`.
On the ordinary launch-proof route, the kernel environment read from that PID must contain a nonempty `FM_SPAWN_GEN` exactly matching the recorded `spawn_gen`.
That matching live pin proves the launch incarnation, including interpreter-based harnesses and older records without a launch-proof field.
For omp, the existing worker extension, local-secondmate watcher, or explicit repair must also record the current session file and live PID for that task.
Argv and text embedded in other environment values never supply incarnation evidence.
Without the matching pin, an omp process is unmanaged, including Herdr-native `omp --resume`, unless its repaired session record passes the [full adoption proof](#repairing-a-restored-omp-session-record).
Resume arguments, native session-file headers, original launch briefs, task inbox paths, actual cwd, and current Herdr session registration never substitute for current-session proof on their own.
For a launch-pinned omp process, an in-process switch to a personal conversation is unmanaged even when the PID, argv, environment, and original task session file are unchanged.
An adopted process has no pin, so this switch protection does not cover it; see the [residual risk](#repairing-a-restored-omp-session-record).
Every other recorded harness remains unknown with missing or mismatched pins.
Unreadable environments, ambiguous foreground identity, and unsupported launch-proof versions also remain unknown.
Neither unmanaged nor unknown proof authorizes lifecycle action for a record with `launch_proof`.
Every Herdr replacement must have matching managed-launch proof, including current-session proof for omp, before transaction completion.
The normal failed-launch and published-record reconciliation rules below still apply.

The omp task record binds its initial session pathname once per launch generation and updates the active pathname and PID synchronously on session activation or switch, including before JSONL persistence under an existing canonical session directory; managed authority still requires persisted task and active files identifying the same file.
The shared attribution guard requires that active file to resolve to the recorded task file for the identified live PID and matching launch generation, proved by the live environment pin or by the guarded [adoption route](#repairing-a-restored-omp-session-record); missing, invalid, or personal-session proof refuses lifecycle action.
Session shutdown and pre-switch callbacks invalidate the active proof before replacement; returning to the recorded task session restores attribution, while workers without the extension remain unmanaged unless repaired by `adopt`.
Cancelled or rolled-back switches and branches restore the predecessor proof only after omp's session transition settles and only if no newer transition or shutdown intervened.
Every proof callback requires a unique registered top-level session sharing its context's session manager, and settled restoration rechecks that owner, so delegated or unregistered sessions cannot mutate the parent proof without relying on a context agent field.
The proof installer uses the live registry exposed by omp's extension API rather than importing an on-disk SDK package.
[`tests/fm-omp-harness.test.sh`](../tests/fm-omp-harness.test.sh) covers session transitions and child preservation with both minimum-runtime and newer context shapes; [`tests/fm-omp-task-session-live-e2e.test.sh`](../tests/fm-omp-task-session-live-e2e.test.sh) provides the installed-runtime refresh command without model calls.
This inspection does not change Herdr's session-wide auto-resume setting.
The [Herdr restart guide](herdr-backend.md#restart-and-liveness-behavior) owns that decision and its scope.

### Recovering an exited instruction owner

Restoring an exited owner to reconcile instructions is not permission to advance held or dependency-blocked work.
The [`bin/fm-control.sh`](../bin/fm-control.sh) header owns the reconciliation-only option and its admission limits; [`bin/fm-dod-lib.sh`](../bin/fm-dod-lib.sh) owns the replacement's current instruction contract, which supersedes historical execution instructions.
The task's recorded recovery scope survives ordinary and automatic replacement, including a session-end replacement after a genuine dependency completes.
The actual lock-owning main Firstmate must run `fm-control <task-id> authorize-continuation` after reconciling the real restrictions.
This metadata-only operation holds the lifecycle lock before the metadata lock, revalidates the local regular task record and recovery field, requires readable automatic-backlog ordinary admission, and refuses a pending authoritative close.
Missing, foreign, or dead session ownership, a worker, and the supervision branch in any posture cannot authorize clearance.
It does not start a worker or send conversational text.
After clearance, send a new continuation instruction with `fm-send` to a live owner, or use ordinary `fm-control <task-id> relaunch --note ...` for an exited owner.
An `fm-send` message never clears recovery by its text.

### Reassociating a task with a replacement copy

A worker sometimes moves a task's work into a fresh local copy: it bundles the work, cuts a new copy with the right owned paths, carries the work over, and starts one fresh validation run there.
Until the record follows, `worktree=` still names the old copy, so `bin/fm-crew-state.sh`, the watcher's write probe, and every landing path read the old copy and its old run.
`relaunch` cannot fix that, because it deliberately reuses the recorded copy.

The actual lock-owning main Firstmate runs `fm-control <task-id> reassociate --worktree <replacement-copy> --note <why>`.
It updates metadata and preservation refs only: it never stops or starts an agent, closes an endpoint, aborts a run, or deletes, resets, or returns a copy.
It takes the task's lifecycle lock, then the shared Treehouse project lock, then the record lock, and revalidates the record under them.

It refuses without changing the record, instructions, or copies when:

- the caller is a worker, the supervision branch in any posture, or a session that does not own the home's lock;
- the task is a secondmate, a remotely placed task, or an Orca task, whose recorded `orca_worktree_id=` binds the copy Orca created;
- a recorded GitHub PR has no full recorded `pr_head=` and no readable forge head, either head is missing from Git or not an ancestor of the replacement's HEAD, or a successful forge response is malformed; other forge providers retain the recorded-PR refusal;
  The proof checks both the recorded head and the current forge head when reachable, regardless of whether the PR is open, closed, or merged, and retains the PR identity rather than treating closure as permission to lose its history;
- a pending backlog close or an unfinished relaunch transaction exists;
- the task has no regular `brief.md` to carry the note, the record already names the replacement copy, or the record carries more than one `kind=` line, more than one `branch=` line for a ship, or a `project=` that is not a directory;
- the replacement copy is not an isolated worktree root of the project's own repository, or is the project or primary checkout itself;
- a ship's replacement copy has a detached HEAD, or any brief `Ship branch:` line disagrees with the recorded branch, even when the replacement keeps that branch;
- either copy equals, contains, or is contained by another task record's `worktree=`, `home=`, or `prior_worktree=` in this home or any locally registered home, other than a record named with `--also` in the same call, which the joint route below checks instead; physical paths are compared, including aliases;
- either copy overlaps a managed pool worktree whose owner claim names another task or cannot be read;
- the existing current copy, a pool slot it leaves, or a prior copy inside such a slot is not a Git worktree root, has uncommitted or untracked-unignored changes (the refusal names them), cannot be inspected, or the current copy does not share the project's Git ref store; the dirty check is teardown's, from [`bin/fm-task-copy-lib.sh`](../bin/fm-task-copy-lib.sh)'s `fm_task_copy_preserve`, so only untracked `.claude/` contents, the exact `.fm-grok-turnend` and `.fm-kimi-turnend` files, and the paths of the task's own copies nested inside are exempt;
- any of those HEADs cannot be durably anchored and verified in the project's shared Git ref store.

Two or more live ordinary records can name the same pool slot root while each task's real copy is nested in that root.
No order of single reassociations works for them: whichever record goes first, the other record's `worktree=` is the enclosing root and overlaps the first replacement copy, and the first record's new `prior_worktree=` then overlaps the second replacement copy.
Re-point them together with `fm-control <task> reassociate --worktree <copy> --also <other-task>=<other-copy> [--also ...] --note <why>`.
One call takes each named task's lifecycle lock, then the shared Treehouse project lock, then each record lock, and every named task must be a ship or scout of this home and of one project.
It proves every named record before it writes anything, with the checks listed above run for each task against that task's own copy, head, branch, recorded PR head, and instructions file.
Every refusal names the task it belongs to and the proof that is missing, and a refusal changes no record, no instructions file, no claim, and no copy.
The named tasks may overlap one another only through the root they leave: each task's current copy may be that root and each replacement copy may sit inside it, but replacement copies never overlap one another, and nothing else a named task records may overlap another named task's copies.
Every other record is checked as in a single reassociation, so a third live record on the root refuses, naming itself, until it is named with `--also` as well.
Each head is anchored under that task's own id, and only after every named record's copies have been checked.
A named task whose replacement copy lies inside the root keeps its slot claim, and one whose replacement copy lies outside releases it, as in a single reassociation; a root left without a claim is claimed for the first named task whose replacement copy lies inside it.
The claims, the instructions files, and then the records are published together, and a failed write restores every record, instructions file, and claim already published, so no named task is left half moved; the anchors stay.
A task whose replacement copy is nested in the root ends as an ordinary nested record that names the root as `prior_worktree=`, exactly as a single reassociation leaves it; a task that moved outside the root names it as `released_worktree=`.
Each nested record then names the root as preserved custody, but a record that has left the root for its own copy nested in it no longer owns the root, so ordinary `bin/fm-teardown.sh` of one of them takes the peer-slot route in the nested-copy rule below, which removes only that task's own proven copy.

When finished and parked ordinary tasks both record the same pool slot root, reassociation cannot go first: the other root record overlaps the replacement copy and may still claim the slot.
Before retiring a record that still holds the slot's Firstmate claim, or any record when the slot carries no claim, Treehouse's state must durably lease the slot under the existing [`fm_task_copy_pool_slot_held`](../bin/fm-task-copy-lib.sh) proof.
An absent claim counts as ownership for this protection, as it does for teardown's slot-owner check.
An unleased slot refuses with the command to lease that exact slot in place without changing its contents.
A recovered-state lease has no supported non-forcing replacement on Treehouse 2.3.1-fm; retain the records and copies and report the slot, state file, lease holder, and installed version for operator recovery rather than returning the slot to change its lease.
When exactly one other root record names the slot, the command names it as the lease holder; when several do, it names none, lists every candidate with its last recorded status line, and the operator selects the live one.
This prevents another allocation from resetting the parked copies between cleanup and reassociation, while the remaining record still names only the root.
A finished root record whose slot claim already names another task, such as a slot an ordinary spawn handed on under a process-only lease, no longer owns the slot: it keeps teardown's existing reassigned-slot cleanup, retiring records-only with no lease proof, and leaves the claimant's record, claim, branches, and copy untouched.
Like a shared root record, a ship on that route must have its own recorded PR confirmed merged or its recorded branch proved landed; the claimant's copy, HEAD, and dirt are never judged, and an unproved ship refuses with its records in place.
Then run ordinary `bin/fm-teardown.sh <finished-task>` in that record's owning `FM_HOME` first.
The shared-root route reuses record-only retirement: it closes the finished task's endpoint and records, releases only that task's Firstmate claim beside the slot, and never returns the slot or touches its contents, nested copies, or branches.
Slot-wide run/process cleanup is skipped; when the retiring record names its own nested copy, only that copy's identity-proven parked pipeline run, private launch agents, and leftover processes are concluded after the ordinary per-copy record clearance proves no other record names it, and that copy's ordinary non-forced safety check runs again before the claim or record is released; task-owned temporary resources retain their existing cleanup behavior.
It leaves Treehouse's durable lease intact and skips post-cleanup branch pruning.
A ship whose record names the shared root must have its own recorded PR confirmed merged or its recorded branch proved landed independently of that root's HEAD and dirt.
A scout still needs its regular nonempty report and the ordinary completed decision inventory; it needs no branch.
With three records sharing the slot, retire each finished root record this way, including a finished branch-less scout.
A finished record whose copy is nested in the slot also uses record-only retirement while another ordinary record still names the enclosing slot root; its nested copy is never returned or removed, and a ship's nested copy keeps the ordinary dirty and landed-work proof on that copy itself, so a merged PR does not waive later local commits or tracked edits.
Then reassociate the remaining task to its real nested or external copy with `bin/fm-control.sh <remaining-task> reassociate --worktree <copy> --note <why>`.
The existing component-aware exclusivity proof still requires finished nested scout records to retire first when they overlap the old root, even if their copy is disjoint from the replacement.
Do not retire an unfinished task to clear custody: it keeps its record and claim until its own delivery proof passes.
Before any forced Treehouse return of a Git directory, whether or not it is a pool slot, teardown also checks that directory's Git worktree registrations and refuses a nested copy that is not one of the retiring task's proven copies, naming each such copy, unless the foreign-copy proof below releases it or the held-copy rule below leaves it standing; `--force` does not waive that custody proof.
A child-worktree removal that hits this refusal stops there, with no `rm -rf` fallback, and a path that cannot be canonicalized is refused the same way.
The refusal prints the reassociate command with `FM_HOME=/path/to/owning-home`, because the owning task's record may live in a different home than the one running teardown.
A secondmate home that is a pool slot, and each descendant secondmate home, gets the same check before any endpoint, child, or record is touched.
When an active task record owns that copy's work, including the retiring task itself while its record still names the slot root, reassociate that task to the copy first.
When no active record owns it, such as a finished record's nested copy left after records-only retirement or a worker's own `.claude/worktrees/` copy (Vernant's `start_task_worktree.py` creates and locks one), a teardown of a ship or a scout that returns the pool slot releases it itself once it proves all of these, in [`bin/fm-teardown-nested-lib.sh`](../bin/fm-teardown-nested-lib.sh):
- No other active task record names the copy, even through a symlink alias.
- No process outside this teardown runs in the copy, and no live process outside this teardown is the launcher named in its lock. A process is this teardown's own when it, or an ancestor by parent chain, has a cwd exactly at the task's worktree, the slot, a nested copy of the task, or the task's scratch directory. A launcher pid that started after the lock file was written is a recycled pid and owns nothing.
- Retire sends TERM, recording each signal like the others, to each launcher and each process in the copy that is this teardown's own, whatever its cwd, and waits briefly. One that is still alive keeps the copy, and the refusal names its pid. Retire sends no KILL. A process that is not this teardown's own is never signalled: it refuses the release, and the refusal names its pid.
- It is a clean worktree root, and each ignored file it holds is either regenerable machinery (the allow-list in `teardown_preservable_ignored`) or copied with its SHA-256 into the task's data directory at `data/<task-id>/nested-copy-preserved/` before removal.
  A foreign copy that holds any other ignored file is held instead (see Held copies) wherever the held-copy rule applies, and is preserved and released as just described wherever it does not.
- Its work is landed by the ordinary landed-work test.

A copy locked by Vernant's creation lock is released and removed by Vernant's own driver, `scripts/git-stability/closeout_pr.py --cleanup-worktree <copy> --execute-cleanup`, run from the slot; an unlocked copy is removed with a plain non-forced `git worktree remove`.
A copy whose work is not proved landed stays, and teardown writes the reason.
The task's own nested copy that Vernant's creation lock holds takes the same driver route in place of a forced removal, once it also passes the record, process, launcher and ignored-file proofs above; an own copy that is not locked is removed as before.
Removal deletes the copy's checkout and the allow-listed ignored files in it (symlinks, virtual environments, `node_modules` and tool caches, `.DS_Store`, Firstmate's hook files, regenerable build caches such as `.next`, `*.tsbuildinfo`, `graphify-out`, `.import_linter_cache`, `.tac/tmp` and `.tac/uv-cache`, and anything ignored under its `.claude` and `.opencode` trees).
Every other ignored entry, including durable `.tac` state such as `.tac/loop-state`, is preserved as the proof above requires, just before the copy is removed.
Removal therefore loses no unique content, because it is preserved; no commit, because the work is landed; and no tracked change, because the clean proof refuses one.
The clean proof skips untracked files under `.claude` only; the ignored-file proof skips ignored files under `.claude` and `.opencode`; plain `git worktree remove` still refuses a copy that holds an untracked file.
On the pool-slot route the release runs before the final project-lock wait, so the driver never runs while the lock is held, except when teardown keeps project custody through the return.
A copy it cannot prove, an ignored entry it cannot copy and hash, a lock in any other format, a driver refusal, a half-removed copy, or a copy still registered afterwards refuses exactly as above unless the held-copy rule below applies, and `--force` waives none of it.
A nested copy that no teardown ever reaches, because its slot is never returned, falls to the [nested task copy sweep](configuration.md#nested-task-copy-sweep-configcopy-budget), and the header of [`bin/fm-copy-sweep.sh`](../bin/fm-copy-sweep.sh) owns which copies it removes and which it holds, including the locked copies it may release through Vernant's closeout driver once that copy's launcher is proved gone.
[Friction ledger](configuration.md#friction-ledger) owns the typed `REFUSED:` envelope a policy refusal of a copy prints, with its completing command or human-only question, and the plain `error:` a failure to read state prints instead.

**Held copies.**
A foreign copy that cannot be released does not stop the task that is closing from closing.
This holds when the task's own copy has passed the ordinary landed-work test, and every foreign copy that would stop the slot's return is clean, owned by no record, no process and no live launcher, and held back only by ignored files that exist nowhere else or by a HEAD that is not proved landed.
Teardown then closes the task: it moves the backlog item to Done with the merged evidence, removes the task's own record and runtime state, and removes only the task's own nested copies that the proof covers.
An own nested copy that holds another Git repository or a linked worktree of another project is not removed: the close refuses before it removes anything and names the repository, because no ref would keep that repository's commits.
It does not return the slot, and it does not touch the slot's claim or any foreign copy; it never deletes, moves, rewrites or changes the mode of anything inside one.
Before it removes anything, it reserves the slot under a durable lease in Treehouse state, exactly as an ordinary return does, because a slot taken with a plain `treehouse get` holds only a process lease that lapses when the worker exits and a later `treehouse get` could then reset it over the held copies.
A slot that is already durably leased is not changed.
When the slot cannot be proved durably leased, or the reservation fails, the whole close refuses before it removes anything, and the output says why.
The output lists each foreign copy it left with its reason, says that the slot return is deferred, and says that the slot is reserved under a durable lease and stays claimed.
Nothing returns the slot automatically, and teardown removes no held copy: a held copy goes on the owner's word naming it.
The [nested task copy sweep](configuration.md#nested-task-copy-sweep-configcopy-budget), when its `--apply` job is armed, also removes an unlocked copy held for commits once its HEAD is landed, and may release a copy locked by Vernant's creation lock through Vernant's closeout driver, after preserving its unique ignored files, when that copy passes the proofs the header of [`bin/fm-copy-sweep.sh`](../bin/fm-copy-sweep.sh) owns; it never removes an unlocked copy held for unique ignored files, whether or not its HEAD is landed, so that goes only on the owner's word naming it.
For each held copy the output also prints the next step for that copy's owner, which depends on why the copy is held.
For a copy held for commits on no remote: list the commits only it holds with `git -C <copy> log --oneline HEAD --not --remotes`, land them, then remove the copy and return the slot with the commands the output prints.
For a copy held for unique ignored files: review them with `git -C <copy> status --ignored` and save the ones needed, with any commits only the copy holds, before the copy is removed in any way; the output names no removal command for it, because `git worktree remove` deletes ignored files without asking.
The output shows every copy path, slot path and reason with control characters replaced by `?`, and quotes each path in a printed command with `printf %q`; the record carries the same cleaned text.
Once every proof has passed and before it removes anything, teardown appends each such copy to `data/held-foreign-copies.log`, one line per copy with five tab-separated fields: the UTC time, the closing task id, the slot path, the copy path and the exact reason text.
A line already there for the same task, slot, copy and reason is not written again, and teardown never edits or clears the file.
A record that cannot be written refuses the close with nothing removed, so a close that happened never lacks its inventory.
A refusal by a later step leaves the line, and the rerun adds nothing.
Once the task record and the task's own nested copies are gone, which no rerun can bring back, teardown prints the notices below, before the backlog close and the later steps, so a failure of the backlog close, of the fleet sync, or an idle-reaper timeout after that point still leaves them.
The notices are printed whichever completion line the close later prints, including the line of a `--legacy-record` close.
A foreign copy that lies inside one of the task's own nested copies is never held, because removing the own copy would take it along.
When such a copy cannot be released, or when one that can be released lies there beside a copy that would be held, the whole close refuses as it does without this rule.
A foreign copy that is also dirty, named by another record, running a process, or locked by anything other than a Vernant creation lock whose launcher is gone still refuses the whole close, and so does an own copy that is dirty or unlanded, or any other refusal of the ordinary close.
The refusal names that blocker, such as the owning record or the running process.
A copy whose landing could not be checked, as when fetching the default branch from origin fails, or whose ignored files could not be listed, is never held either: the close refuses, names what could not be read, and a rerun checks again.
A copy held for unique ignored files is held without a landing check, because its HEAD does not change why it stays.
`--force` never holds a foreign copy, and neither does retiring a secondmate home.
A foreign copy that the rule does not apply to for these reasons, or because its path holds a tab or a newline, and that holds unique ignored files, is not refused for them: the foreign-copy proof above copies them with their SHA-256 into the task's data directory and releases the copy once its work is landed.
To handle a refused copy by hand, inspect it with `git -C <copy> status --untracked-files=all` and `git -C <copy> log --oneline HEAD --not --remotes`, confirm nothing there is unlanded, then remove it with a plain `git -C <slot> worktree remove <copy>`, or for a Vernant-locked copy with the closeout command above, and rerun teardown.
The log test lists the commits of a squash-merged branch whose remote branch was deleted as unpushed, so judge those copies by their merged PR and the closeout driver's landing check, not by that list alone.
A plain `git worktree remove` refuses a locked copy, and neither `--force` nor unlocking by hand is the supported route.
A surviving recorded PR follows only under the head-containment proof above.
A durable lease added for this recovery stays on the slot after the remaining task moves to a copy outside it, so no record names the slot and teardown never returns it.
Release it by hand only after inspecting every copy left in the slot with `git -C <slot> status --untracked-files=all` and `git -C <project> worktree list --porcelain`, and only when no record names the slot or a copy inside it and nothing there is unlanded: `(cd <project> && treehouse return <slot-path> --if-lease-holder <remaining-task> </dev/null)`, where the holder is the one passed to `treehouse lease`.
The input redirection prevents the TTY prompt's default-yes answer from cleaning dirt; the noninteractive command refuses instead.
That return is not state-only: it terminates lingering processes in the slot and may clean and reset it, so carry over or land any remaining work first.
`--force` retains its existing collision refusals and is neither needed nor used for this route.
The script headers own the command syntax, and `tests/fm-control-reassociate.test.sh` exercises the complete sequence with unpushed commits, untracked files, and an external locked copy.

Before publishing the replacement, it anchors the HEAD of the existing current copy, of each pool slot it leaves, and of each prior copy inside such a slot at `refs/fm/anchor/<task>-<shortsha>` in the project's shared common Git directory (an anchor already holding that HEAD is reused) and verifies each ref resolves to that exact commit. Every copy is checked before any anchor is written. This preserves every ancestor, including all unlanded commits, even if an existing interactive Treehouse owner later detaches and resets the old slot on shell exit. Commit or carry over all uncommitted and untracked-unignored changes first; reassociation does not stash them or change the provider's release lifecycle. Ignored files are not protected by the commit anchor.

Every reassociation holds the shared project lock through both copies' ownership scans and record publication, whether or not either copy is a pool slot.
Reassociation already holds the task's control lock, so it makes one nonwaiting attempt through [`bin/fm-project-lock-lib.sh`](../bin/fm-project-lock-lib.sh): a concurrent allocation, return, or reassociation, or any operation queued for the lock, makes it refuse rather than race the ownership proof, which runs only under the acquired lock.

It then publishes, in order, so an earlier failure rolls back to the record that was there:

1. pool slot claims: a managed pool slot that overlaps the replacement copy is claimed for the task, keeping an existing claim's home, and one that overlaps only the copy it leaves has the task's claim released, so the pool may hand it out again;
2. the brief, with a ship's `Ship branch:` line moved to the replacement copy's branch and a `## Copy reassociation (<timestamp>)` block carrying the note, so a later relaunch agrees with the record and its worker knows where to work;
3. the record, with `worktree=` and a ship's `branch=` naming the replacement copy and one more `prior_worktree=` line naming the copy it left, or a `released_worktree=` line when that copy lies in a released pool slot (an earlier prior copy inside that slot moves to `released_worktree=` too). A recorded copy that no longer exists but sat in Treehouse's `<pool>/<slot>/<repo>` layout beside its pool state file is recorded as `released_worktree=` as well, and the task's claim beside it is released, so the vanished path never blocks the task Treehouse later hands that slot to.

The brief and record are each read whole and staged with every write checked, so a read or write failure refuses before anything is published.
The brief is the durable reassociation narrative; no separate reassociation audit log is created.
If record publication fails and the original brief cannot be restored, its exact backup is retained at the path reported by the refusal for recovery.
Preservation anchors remain durable even if later publication fails; they are not rolled back or removed automatically.
Moving a task back to one of its prior copies removes that copy from `prior_worktree=`, so a mistaken reassociation is undone by reassociating again.
Own enclosing-to-nested and nested-to-enclosing moves are supported; the enclosing slot stays claimed by the task while it holds the task's current copy.
Teardown retires both shapes: see the nested-copy rule below.

After it, every reader of `worktree=` follows the replacement copy, so `fm-crew-state` reports that copy's real run.
A prior copy stays the task's preserved custody: its bytes are untouched, and [`bin/fm-task-copy-lib.sh`](../bin/fm-task-copy-lib.sh)'s record scan counts enclosing and nested custody as well as exact matches, so another task's cleanup cannot reach it, except for the peer-slot route in the nested-copy rule below.
A released pool slot is not custody: `released_worktree=` records only where the task was, and the slot's commits survive through the preservation anchor.
A reassociation leaves the endpoint's shell in the copy the task left, so a later `relaunch` that finds the shell in one of the task's `prior_worktree=` or `released_worktree=` copies sends it into the recorded copy before it launches; [`bin/fm-spawn.sh`](../bin/fm-spawn.sh)'s `spawn_path_is_prior_copy` owns that test, and a shell found anywhere else is treated as for any other relaunch.
Reassociation, the allocation gate below, and teardown use the same local-home traversal: the current home, the local root, and recursively registered local descendants. Remote entries are excluded; for reassociation and teardown an unsafe registry or unavailable registered local home refuses the scan. The one exception is teardown's custody scan while retiring a secondmate whose own registered home is already gone: that entry alone is skipped, since nothing there can be lost, and every other unavailable registered home still refuses. A validated owning ancestor's enclosing current home/worktree is not competing custody for a subordinate copy; its prior copies and Git common-directory storage remain protected.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh) checks worktrees, tasktmp and launch-namespace roots, secondmate homes, and recursive child cleanup against copy custody before process or endpoint cleanup, including forced cleanup.
Both containment directions count, across this record and all local homes: temporary cleanup roots cannot overlap any current, home, or prior copy, and copy/home removal cannot overlap preserved priors or records outside the admitted cleanup, except for the peer-slot route in the nested-copy rule below.
A destructive pool slot return is the one narrower case: against another ordinary task's current `worktree=` it refuses only on an exact path match, because the return resets that one slot, while `home=`, `prior_worktree=`, and a secondmate's `worktree=` keep the overlap rule.
The finished shared-root recovery route above returns nothing, so it does not require exclusive slot custody.
These checks also protect the shared Git common directory of preserved copies, including their objects and preservation anchors.
Forced child cleanup admits its locked ordinary current records, not preserved prior or reassociated non-pool copies.
For disjoint copies teardown still runs the landed-work test on the current copy, returns it only when it is a pool slot, and otherwise leaves it in place; recursive forced cleanup likewise leaves reassociated non-pool copies and their hooks untouched.
For a child secondmate, both its worktree root and home root use home admission: ordinary current copies of its locked descendants may be inside either root, while all preserved copies, their Git common directories, and records outside the locked cleanup set remain protected.
A reassigned child pool slot outside the retiring homes is left untouched while its stale child record is retired. This records-only exemption applies in both recursive preflight and cleanup; it does not exempt home or removal-root deletion from custody checks.
Recursive retirement validates each child against its owning home's registry and retires that registration under the owning registry lock after successful home removal, before checking later siblings. An unrelated unavailable registered home still refuses cleanup.
It never touches a prior copy outside the slot it returns and names each one it left, to be returned or removed only after its contents are confirmed landed or unwanted.

A task's own prior copies are not competing custody against the cleanup of its own current copy or slot, so a nested reassociation can be retired once the proof below passes.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s `teardown_nested_slot` is the one owner of returning the enclosing slot once the task's own nested copy goes. It works in three phases, and a re-run derives its input from the record's `branch=` and `prior_worktree=`, never from the nested copy still existing:

1. **Proof, with no side effects.** The nested copy passes the ordinary landed-work test. When an earlier teardown already removed it, that test runs on its `branch=` ref read from the project: local-main ancestry for a local-only ship, then a merged PR, then the merge-tree content check, so neither the copy nor a recorded `pr=` URL is needed. When that branch ref is gone too, for example pruned after its PR merged, the forge's word on the recorded `pr=` settles it as for any missing worktree: a merged PR finishes with a plain re-run and is recorded as landed, while no recorded PR, or one the forge does not report merged, refuses. The slot and every own copy nested in it are clean worktree roots whose HEAD is landed by that same rule or held by the task's `refs/fm/anchor/<task>-<sha>` anchor, and the slot's claim is this task's. Otherwise teardown stops before changing anything and names the copy and the reason.
2. **Retire, on every swept root.** Before any destructive step, teardown concludes a parked no-mistakes run, retires a task-private launch agent, and reaps leaked processes on the current copy, the slot and each nested copy, each as its own root.
3. **Execute.** Teardown checks dirt and HEAD again with the project lock held, reusing only landing proofs tied to those same immutable commits; it refuses before removing anything if a new landing proof would be needed.
   Then it removes the nested copy (its branch stays), detaches the slot, returns it, drops the claim and removes the task record before releasing the project lock.
   A nested copy that Vernant's creation lock holds is released by the closeout driver under the release rule above, never by a forced removal; a driver refusal stops teardown with the copy, the slot claim, Treehouse's lease and the task record in place, and names its saved diagnostics under the teardown header's output-retention contract.
   If the return removes a stale `index.lock`, the slot is checked once more before the reset.

The teardown header owns the state-only slot reservation and lock boundaries; process cleanup, endpoint closure, backlog completion and clone synchronization are outside those ordinary pool critical sections.

`--force` skips the landed-work test on the current copy as always and does not waive the slot proof.
The same function covers the reverse shape, where the current copy is the pool slot and a prior copy is nested inside it: that copy is proved and removed before the ordinary return.
A refusal after the nested copy is gone leaves the record and the slot claim in place. A plain re-run, with no `--force` and no captain words, finds the slot through the task's own `prior_worktree=`, proves it again under the same rule, and returns it; a landed ship is recorded as landed, never as dropped.
The stale-lock proof covers the slot only: nested copies teardown already removed are not proved again.
If a later step fails after the slot was returned and its claim released, the re-run still judges the removed copy by its `branch=` ref, so the ship is again recorded as landed. The slot is no longer this task's, so it is neither returned a second time nor named in the prior-copy notice, and the completion line says the copy was already removed.
A nested current copy whose enclosing slot the task does not claim is left in place like any other reassociated non-pool copy, unless the claim names a peer that works in the slot, which takes the peer-slot route below.

When other live ordinary records have each left the same slot root for their own copies nested in it and name the root as `prior_worktree=`, which is the shape a joint reassociation leaves, `teardown_nested_slot` takes the peer-slot route in place of returning the slot.
[`bin/fm-task-copy-lib.sh`](../bin/fm-task-copy-lib.sh)'s `fm_task_copy_prior_root_released` is the one owner of when such a record's prior custody no longer holds the root.
It requires that the retiring task itself names the root as `prior_worktree=`, and that the other record is a ship or scout of the same project, not an Orca task, whose current copy lies inside the root and apart from the retiring task's copy, while no other record still names the root or a directory enclosing it as `worktree=` or `home=`.
Any other overlap keeps the prior-custody refusal.
The route removes only the retiring task's own current copy, under the same proofs as above: the ordinary dirty and landed-work test, the process and launcher proofs, and for a copy that Vernant's creation lock holds the closeout driver run from the root.
It reserves, reaps, scans, detaches and returns nothing slot-wide, leaves Treehouse's lease and every other record and copy untouched, and passes the slot claim to the first remaining peer when it was this task's, so the last task out finds the slot its own.
A claim that already names a peer stays as it is.
The route works the same when a rerun finds the copy already removed, judged by its `branch=` ref as above.
A foreign copy in the root is neither judged nor touched by this route, and it is proved again when the last task out returns the root; a copy held back only by unlanded commits or only by unique ignored files then closes that last task under the held-copy rule above and the root stays.
A peer that has left the root between the proof and the removal refuses with the record in place, and a re-run takes the ordinary route.
`--force` skips only the landed-work test on the task's own copy, as always, and waives none of the other proofs.
`tests/fm-control-reassociate.test.sh` exercises the sequence from the joint reassociation through the last teardown.

Before a fresh spawn sends `treehouse get`, and before secondmate home seeding sends `treehouse get --lease`, each under the shared project lock used for allocation and return, [`bin/fm-task-copy-lib.sh`](../bin/fm-task-copy-lib.sh) checks whether a pool slot of the project strictly contains a task record's current copy (`worktree=`) in this home or any locally registered home.
`treehouse get` resets and hands out only a slot its pool state file records as not leased, so such a slot (the nested replacement-copy case) refuses the allocation unless Treehouse's state durably holds it.
A slot is held only when every state entry naming the same directory by device and inode identity is leased.
An unleased entry spelled with trailing slashes, `/.` components, or repeated slashes still makes the slot unsafe even beside a leased entry.
The same holds for an entry spelled that way that carries Treehouse's recovered-state holder on a slot that is not a local Firstmate home.
The raw path-suffix prefilter skips only entries with an ordinary lease, so it cannot hide a conflicting unleased or recovered-lease alias; skipping an ordinary leased alias can still leave the slot unproved and refuse allocation.
A lease carrying Treehouse's recovered-state holder counts only when the slot is itself a local Firstmate home, because Treehouse 3.1.0 and later release that lease on their own once the slot is idle, clean, and landed.
A live owner process, dirt, or an unmerged HEAD also makes a get skip a slot, but each can change before the get runs, so none of them counts; a slot with no state entry, an unreadable state file, or a host without `jq` to read it refuses as unproved.
The check refuses to prove any slot held when any entry path is relative or escaped by the TSV transport, including paths containing backslashes, tabs, carriage returns, or newlines.
It cannot safely exclude such an entry as unrelated without proving its directory identity, since even a different spelling can alias the requested slot.
The refusal names the offending entry and its path in TSV-escaped notation and asks the pool owner to remove or rename that entry so its recorded path is absolute and contains none of those characters.
This includes a legitimate directory containing a backslash: its state is not corrupt, but the pool remains unsupported while that entry exists, so merely reporting it or adding a lease cannot clear the refusal.
A nested copy inside a slot proved durably held, including another project's task copy under a leased secondmate home's `projects/` clone, does not stop an unrelated start.
For a singly recorded unleased slot with a unique state name, the refusal names `treehouse lease <name> --lease-holder <task>`, run from the project once `treehouse status` there lists that slot, to hold it in place without touching its contents; teardown's `treehouse return` releases that lease with the slot.
When an unleased entry's state name is duplicated or another entry names the same directory, the refusal instead requires `treehouse status` inspection and a repair report.
Treehouse leases only the first entry with the requested name, so a lease cannot reliably clear a duplicate-entry refusal in either entry order, and the refusal does not describe a partly leased slot as unleased.
No other refusal names a lease as its remedy.
A refusal for a recovered-state lease points to `treehouse status` instead, because `treehouse lease` refuses a slot that is already leased.
A missing-`jq` refusal says to install `jq` and retry, including when reached through secondmate home seeding.
A refusal for a slot with no state entry or an unreadable state file points to `treehouse status` for inspection.
This check scans every local home it can read: a registered local home or registry it cannot read is named in one warning line and skipped, so one broken home does not stop every allocation for a project.
A slot is recognized by the rule teardown uses: Treehouse's `<pool>/<slot>/<repo>` layout beside its pool state file, sharing the project's Git common directory.
A slot a task merely left holds no record's current copy, so it never blocks allocation.

After sending `treehouse get`, a fresh spawn polls the pane until two reads agree on an isolated worktree of the project.
The wait ends only after ten minutes without a changed pane path or changed output, or at the absolute thirty-minute extreme.
A live `treehouse get` does not expire at a short wall-clock window, but liveness alone does not reset the no-progress clock.
The same rule applies when the foreground cannot be read, as on zellij and cmux.
A waiting line every minute names the foreground evidence, elapsed time, idle time and last rejected path.
A refusal names the no-progress or absolute limit, the poll count, the last path seen, why it was rejected, and the spawning project.
Existing acquisition cleanup remains responsible for ending only the refused attempt and its process lease.
The [measurement record](verification/runtime-backends.md#treehouse-get-entry-wait) retains the earlier acquisition timings and their limitations; those timings did not justify the former short hard cutoff.
The shared project-lock wait follows observed holder progress rather than total hold age; [`bin/fm-project-lock-lib.sh`](../bin/fm-project-lock-lib.sh) owns its sampling and idle allowance.

Standalone PR registration locks its task-copy snapshot before retirement recovery, guard execution, or any forge request, and refuses publication if the recorded worktree or branch changed while the PR was being checked.

### Reclaiming a task whose endpoint is gone

A terminal can disappear while its task's worktree, branch, commits, and uncommitted changes survive.
Reclaim supports Herdr's session-scoped absence proof and a tmux proof scoped to the recorded session and worktree.

Two endpoint verdicts can permit a relaunch, subject to the backend policy below:

- `dead` - the endpoint exists and confidently holds no agent. It is **adopted**, so the task keeps its exact recorded address.
- gone, **proven** - there is no endpoint and therefore no agent, and it cannot be adopted; when the backend policy below permits reclaim, the launch owner **creates one fresh Herdr endpoint in the recorded worktree** and the republished record rebinds the task to it.

That proof is its own step because an unreachable endpoint can still hold the live agent a rebind would duplicate.
Absence is proven and never inferred from a failed read; whether it is provable at all is a property of the backend:

- **Herdr can prove it.** The shared absence proof is the only recovery step that may ensure the recorded session, through the [safe server-start boundary](herdr-backend.md#named-server-and-session-routing); it then **re-reads the recorded pane**.
  Server startup is a mutation owned by recovery, not by the passive endpoint recheck or crew-state inspection.
  No workspace or tab is created by that server ensure.
  `dead` means the pane survived the restart and can be adopted; `alive` means an agent came back and refuses replacement; `missing` from an answering running server proves the pane itself did not survive.
  Passive classification reads a stopped session as `missing` only after proving that no server process or accepting socket remains, and never starts a server; that `missing` does not license re-creating the endpoint until the recheck reads the pane from a running server.
  `exit` and `relaunch` reach that proof only when the recorded endpoint reads `missing`, so they start a server only when the recorded session's server is proven absent.
  That server start is a real side effect: when the restarted pane holds no agent (`already-stopped`) or did not survive (`endpoint-gone`), `exit` leaves the restarted server running and idle.
- **tmux proves absence for the recorded endpoint only.**
  The record names a session and window but carries no socket identity, so the proof uses what the record does name: the exact recorded session on the server this process addresses, plus the recorded worktree.
  The addressed server must answer definitively, on two reads, that the whole server or the exact session is absent, or list the session without the recorded window.
  A window that answers on either read is never absent.
  Between the reads, one scan of the machine's process working directories must find no harness agent holding the recorded worktree or a directory under it, because a window on a socket this process does not address still leaves its agent running in that worktree.
  Logical and physical worktree roots are compared in `lsof`'s escaped NAME representation, including non-ASCII bytes and literal backslashes.
  The scan runs from `/`, so neither `lsof` nor its transient command-substitution shell becomes a worktree holder when recovery is invoked from the worktree or a descendant.
  Positively identified idle shells do not block the proof; an unattributed worktree holder does.
  Other tmux servers owned by the same uid, and their clients, say nothing about this endpoint and no longer block it; this proof never queries or lists them.
  Every harness counts as an agent here, including node-bundle harnesses such as Gemini, because each holder is classified from its name, its first argument and its full command line.
  A readable identity that cannot be attributed, including an ambiguous flattened script path, is not proof of a non-agent.
  An unreadable process table, a missing `lsof`, a scan that fails part way, a process record with no absolute working-directory path (including a CWD error returned as its NAME), a failed holder identity read, an empty or unattributed identity, or a tmux answer that is not definitive refuses.
  A renamed session or a window moved to another server still refuses while an agent holds the worktree.

Every transient or self-contradicting read stays `unreadable` or `ambiguous` and still refuses, so a momentary backend failure can never be mistaken for absence.

That proof has one owner for the whole control plane (`fm_control_endpoint_absence_verdict` in `bin/fm-control-lib.sh`), so `exit` and `relaunch` cannot reach two different answers about one endpoint.
`exit` reports what the proof established and nothing more - see its row in the verb table above.

What an endpoint-only reclaim is not (a simultaneous worktree change follows the separate [relocation contract](#relocating-a-task-whose-worktree-is-gone)):

- It is **not a teardown**. The worktree is reused exactly as the previous agent left it; nothing unlanded is ever discarded, and the ordinary `--note` requirement still applies.
- It does **not** change the task's identity.
  The task id, worktree, armed poll and registration, and status log are untouched; only the endpoint binding in the record moves.
  Its instructions are the one exception, and only in the way an ordinary relaunch already changes them: a ship or scout reclaim appends the required `--note` under a `## Progress note (<timestamp>)` heading in `data/<id>/brief.md`, so re-read that brief rather than assuming it is byte-identical - a reclaim that failed and was retried leaves one block per attempt.
  A secondmate's standing charter is never rewritten.
- It is **not** a peer seat's operation. `fm-control` resolves an exact task id against **this** home's `state/`, so only the home that owns the task can reclaim it.
- It does **not** cover a secondmate. A secondmate whose endpoint is gone already has one recovery path - `bin/fm-spawn.sh <id> --secondmate`, driven by the session-start sweep or the watcher's liveness tick - so control-plane reclaim refuses and names it rather than becoming a second path to the same outcome.

For a task already recorded on Herdr, the re-created tab is opened in the herdr session the record names, never in whichever session the recovering seat happens to sit in - relocating a task onto another herdr server would be an identity change published as a self-consistent but wrong record.
A seat that *claims* a herdr launcher pane belonging to a different session is refused rather than allowed to place the endpoint somewhere else, so reclaim such a task from a seat in the recorded session.
A seat with no herdr launcher pane at all - a plain ssh or cron shell, which is the ordinary way an operator reclaims - is not refused: placement falls back to the recorded session's labeled container, so the tab still lands in the session the record names.
The reclaim pins the recorded **session** but not the **workspace**: the container follows the reclaiming seat, so a reclaim run from a seat inside the recorded session places the new tab in *that seat's* workspace rather than the recorded `herdr_workspace_id`, even when the recorded workspace still exists and only the pane was destroyed.
The record is republished consistently and no work is lost, but the task's `herdr_workspace_id` moves with it.
The pane id necessarily changes (the pane did not survive), and the record follows it.
A Herdr reclaim deliberately uses the flat container shape rather than presentation projection: projection is a presentation-only layout that is never endpoint or ownership authority, and flat is already the documented fallback for every recovery it cannot bind exactly ([`docs/herdr-backend.md`](herdr-backend.md)).

A proven-gone tmux endpoint is replaced on Herdr **only when the task home's current configured spawn backend is `herdr` and passes spawn validation**.
Every other configured backend, including `tmux`, `zellij`, and `cmux`, retains the relaunch refusal: reclaim never recreates tmux endpoints and never migrates to another backend.
The Herdr replacement uses the home's current Herdr session resolution and the same flat placement path as an ordinary Herdr reclaim.
It never starts a tmux server, so reclaiming one rebooted task does not affect the absence proof for the home's remaining missing tmux tasks.
Herdr-to-Herdr reclaim continues to use its recorded session unchanged.

**Known limitation - a refusal before the record is republished leaves a stray husk pane** (follow-up bead `fm-herdr-rebind-leak-20260913`).
The rebind registers no abort cleanup, so a refusal in the window between the new tab being created and the record being republished leaves that pane behind while the record still names the old, gone one.
The stray pane holds a bare shell - the harness is not delivered until after publication - so the next reclaim cleans up after it: the re-created tab carries the same `fm-<id>` label, `tab create` finds it, classifies it a husk, and closes and replaces it.
That self-heals only when the retry resolves the *same* workspace, which the placement rule above does not guarantee.
The worktree and the task's records are unaffected either way.

### Relocating a task whose worktree is gone

A pool slot can vanish while its task's branch and every commit on it survive in the shared repository.
Plain `relaunch` refuses that task because it cannot checkpoint the missing recorded copy.
`fm-control <id> relaunch --worktree <path> --note ...` is the supported way out for a **ship**: it rebinds the task to a fresh isolated copy of the same branch that the caller has already prepared.
A scout has no branch to match and a secondmate's home is not a task copy, so both refuse.

[`bin/fm-control-worktree-lib.sh`](../bin/fm-control-worktree-lib.sh) owns the proof, and both `fm-control` and `fm-spawn --relaunch --worktree` run it, so the two cannot disagree.
The control-plane preflight checks all of the conditions below before stopping the agent or writing the relaunch journal or progress note.
The launch owner repeats the proof before publication; a later refusal can therefore occur after the control plane has journaled the attempt and stopped the old agent, following [Failure and rollback](#failure-and-rollback).

- **The recorded path is proven absent.**
  Absence is shown from a readable, searchable ancestor.
  A path that exists, a dangling symlink, or an unreadable ancestry is "cannot say", never "gone".
  An unmounted volume looks like a deleted copy, so do not relocate while one is offline.
- **The fresh copy is an isolated worktree root of the same repository** as the recorded project, never the project's own checkout, with no uncommitted changes.
- **It is checked out on the recorded branch**, which defaults to `fm/<id>` as in a fresh spawn.
- **Its HEAD contains every surviving recorded head:** the last head in git's reflog for the vanished copy, both applicable heads (`relocation_head` and `worktree_head`) in this task's prior control journal for that path, and the record's `pr_head`.
  Relocation refuses when none survives, when existing registration, reflog, or journal evidence cannot be read, or when history was rewritten between two recorded heads and the copy cannot contain both.
  A task with no PR and no prior control relaunch has only the reflog, so prepare the copy with `git worktree add -f <path> <branch>` and do not run `git worktree prune` first.
  If the registration was already pruned, give a known commit of the branch as evidence, scoped by task:
  a task with no recorded `pr=` takes one line, `pr_head=<sha>`, in its task record (`state/<id>.meta`);
  a task with a recorded `pr=` takes the three lines `task=<id>`, `worktree=<vanished path>`, and `worktree_head=<sha>` in its control journal (`state/<id>.control-relaunch`), never a hand-written `pr_head=`, because `bin/fm-dod-lib.sh` and `bin/fm-review-diff.sh` read `pr_head` as the head the forge reported.
  The refusal names the remedy that fits the task.
  The journal names all checked sources as `relocation_head_source` and records the copy's proven HEAD as `relocation_head`.
  Recreating the copy with a reset (`checkout -B`) that drops any surviving recorded head is refused.
- **No other task of any local Firstmate home records it** (the root home and every registered local secondmate home, the same walk teardown uses); an unreadable home or registry refuses. Records are checked by path or alias in both `worktree` and `home`, and a Treehouse pool slot is not claimed by another task or by the same task id in another home.
  Every relocation, pool or not, repeats the ownership proof under the existing shared project lock and keeps that lock through atomic task-record publication. A free pool slot is claimed for this task under that lock, as a fresh spawn does; an unpublished abort removes only the claim that attempt newly acquired, before releasing the lock. Pre-existing claims and claims paired with a published replacement record remain intact.
- **It holds none of the harness files the launch overwrites or deletes** (the worktree-resident paths of `fm_control_harness_wiring_paths` in bin/fm-control-lib.sh).
  The control plane checks, and the launch owner checks again at the moment it would write.
  A file somebody else owns is therefore never touched, so there is no original to restore on an abort.

The journal keeps the current worktree checkpoint (`worktree_head`, `worktree_dirty`, and any child count) and `relocation_from`, `relocation_to`, `relocation_head`, and `relocation_head_source` through every rewrite, including failure phases.
Later ordinary relaunches checkpoint the current copy while preserving the prior relocation fields, and a repeated relocation is judged against both applicable head fields.
An existing unreadable journal refuses a control relaunch before it can overwrite recovery evidence.
The record's `worktree=` moves only at the launch owner's single atomic publication, alongside the ordinary relaunch profile updates (including an explicit harness switch).
A surviving endpoint is reused; a proven-gone endpoint follows the normal reclaim rules above.
The task id, status log, and armed poll are preserved.
The `--note` requirement still applies, and the progress note is appended to the existing brief.
Uncommitted changes in the vanished copy are not recoverable, and the progress note says so.

**Why the caller prepares the copy.**
The alternative is for `fm-spawn` to allocate a pool slot and check the branch out itself.
It cannot check the branch out while git still lists the vanished path as that branch's worktree, so it would have to prune that registration or force the checkout, and both change repository administration that every lane's worktrees share.
It would also reuse the fresh-spawn acquisition path, a pane-driven `treehouse get` with a progress-based isolation poll (pane path or output) that has an absolute extreme, and abort cleanup that returns slots, and a pool that hands out another clone's slot refuses it after the fact.
The relocation proof reads the prepared copy and repository administration without allocating a slot, pruning registrations, or forcing a checkout; mutation remains with the existing relaunch transaction and launch owner.
The caller prepares the copy with `git worktree add -f <path> <branch>`, never after `git worktree prune`: the forced add keeps the vanished copy's registration, whose reflog may be the task's only recorded head.
If that registration is already gone and no other head survives, the refusal asks for a known commit as evidence: one `pr_head=<sha>` line in the task record for a task with no recorded `pr=`, or the three control journal lines `task=<id>`, `worktree=<vanished path>`, and `worktree_head=<sha>` for a task with one.
That evidence only gives the proof a head to check; the proof and the launch owner still make every change.
Rebinding the task by hand-editing its `worktree=` has none of those checks, no journal, and no lock against a concurrent launch.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped restores the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.

## Fail-closed boundaries

The runtime lifecycle verbs have the boundaries below; metadata-only authorization follows [the instruction-owner recovery policy](#recovering-an-exited-instruction-owner) without requiring a runtime endpoint read.

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is refused by name.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  Drive that lifecycle on its own host and reconcile it through the secondmate recovery path.
  For `relaunch`, drive the host through [`bin/fm-remote-secondmate-relaunch.sh`](../bin/fm-remote-secondmate-relaunch.sh), which runs `bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch ...` and then republishes this home's route record from the identity the host confirmed; the host-local leg runs this same plane against a record that is ordinary and local there, so every checkpoint, journal, rollback, and postcondition below applies unchanged ([`docs/remote-secondmates.md`](remote-secondmates.md)); `interrupt` and `exit` have no such route.
- An unverified harness is refused rather than guessed at.
- An implicit relaunch from a prefixed raw-command basename is refused before the agent or durable state is touched because its original launch command cannot be reconstructed.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  Muse is a crewmate and scout adapter only, so relaunching a secondmate onto it refuses while its agent is still up rather than leaving that secondmate with no agent when the launch owner refuses.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
  Orca's terminal API exposes only an interrupt and an Enter, so it can deliver neither Escape nor Ctrl+U.
- `exit` and `relaunch` require a backend with a recovery-grade agent-state classifier - tmux and herdr - because without one the "the agent stopped" postcondition cannot be proven.
  zellij, orca, and cmux are refused rather than reported as successful blind.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- A live Herdr agent must pass the shared [live task-attribution guard](#live-herdr-task-attribution) before any lifecycle input or task checkpoint mutation.
- `exit`'s composer-empty check, above, is itself a fail-closed boundary that `relaunch` inherits by stopping the old agent through `exit`; `relaunch` inherits the picker refusal too and never answers it.
- `fm-spawn --relaunch` independently refuses unless the endpoint is positively agent-free - either a surviving `dead` endpoint or one proven gone by the shared absence proof - so a replacement can never join a live agent.
  An `alive`, `ambiguous`, or `unreadable` verdict refuses, as does any endpoint whose absence is unproven.
  It also requires the shell to be in the selected worktree: every backend but Orca (which owns its own task worktree with no current-path probe) gets one explicit `cd` to that path, then a pre-launch path read that refuses before any harness starts unless it confirms the endpoint is sitting in that copy.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| tmux | yes | yes | yes | yes | yes |
| herdr | yes | yes | yes | yes | yes |
| zellij | yes | yes | yes | yes | no |
| cmux | yes | yes | yes | yes | no |
| orca | no | yes | yes | no | no |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified harness by `tests/fm-control.test.sh`, with adapters outside its lane pinning their control mechanics in their own harness suites.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the adapter contract for its verified-harness lane (adapters outside the lane pin their control mechanics in their own harness suites), the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, the exit-picker answers and `stay`, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction, identity preservation, harness switching, progress notes, checkpoint refusals, and rollback.
- `tests/fm-control-relaunch-recovery.test.sh` - Herdr reclaim, sequential tmux-to-Herdr reclaim, tmux absence scoped to the recorded endpoint despite unrelated servers, refusal of other configured backends, conservative process-read refusals, and refusals on a live window, a worktree-holding agent, or unreadable evidence; missing-worktree relocation cases cover recorded-head containment, foreign harness-file preservation, failure-journal recovery, concurrent destination ownership, and unpublished pool-claim cleanup.
- `tests/fm-control-relaunch-backends.test.sh` - positive live Herdr ownership and no-pin refusals across every lifecycle verb, and unmanaged native restore inspection and bounded copied-home diagnostics; omp session-record `adopt` cases cover each named proof refusal, the caller gates, refusal of a record naming a live process, and a publication race against the real extension.
- `tests/fm-launch-proof.test.sh` - versioned and legacy managed incarnation proof across supported harnesses, native restore and same-PID personal-session switches remaining unmanaged, and conservative foreground and process-environment refusals.
- `tests/fm-control-herdr-smoke.test.sh` - the second state-verified backend against the real herdr binary, on an isolated throwaway lab session.
