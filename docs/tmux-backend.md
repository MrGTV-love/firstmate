# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
Explicit tmux selection via `config/backend` or `--backend tmux` overrides runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Crew tasks become windows in that session.
`tmux display-message -p '#S'` prints its name.
If the primary harness runs outside tmux, Firstmate creates or reuses a detached session named `firstmate`:

```sh
tmux attach -t firstmate
```

Each task window is named `fm-<id>`.

```sh
tmux list-windows -t <session-name>
tmux select-window -t <session-name>:fm-<id>
```

Typing into an attached task window is authoritative direct intervention.
Routine supervision does not require attachment: `bin/fm-peek.sh <id>` captures a bounded tail and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` steers the recorded endpoint.

Verify setup by spawning a small task and confirming its `fm-<id>` window appears in the selected session.

## Current behavior and safety

### Agent liveness probe

A target-existence check proves only that the window exists.
It matches the recorded `session:window` name against the exact session's window inventory, because tmux answers an addressed call for an absent window or session with success while any server runs.
For recorded window-name targets, the shared presence check returns 0 for present, 1 for proven absent, and 2 when the inventory is unreadable. Only a readable inventory omitting the window or a definitive missing-session/server response proves absence; other read failures remain unknown.
Session-start reports those unreadable endpoints as `unknown`, and live busy classification likewise preserves `unknown` rather than reporting `dead`. Send, control, and supervisor actions still require positive presence evidence.
Supported pane selectors and window indices or IDs are checked against the exact session's pane inventory; exact-qualified names are accepted without prefix matching. Remote fleet records are reported as `unknown` without probing any local backend.
The deeper tmux agent-liveness probe first verifies exact session and window membership, then reads process names to distinguish a running harness from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, Muse, Rovo, and AGY process identities as `alive`, common shells as `dead`, a window not found through the addressed server as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
The process-name vocabulary behind those verdicts is owned by `bin/fm-agent-process-lib.sh` and shared with the Herdr adapter, which proves a registered agent against the same names ([herdr-backend.md](herdr-backend.md) "Restart and liveness behavior").
Control-plane recovery follows the [endpoint-absence proof and reclaim policy](agent-control.md#reclaiming-a-task-whose-endpoint-is-gone); a raw `missing` result is not proof that the endpoint is gone.

For positive attribution, the probe combines two independent name sources rather than making either one load-bearing.
`#{pane_current_command}` and the pane tty foreground process group's kernel `comm` values expose different name fields, and which one retains executable identity is platform-dependent.
The foreground probe also reads argv[0] so an exact harness install-path component can carry the verdict when the other fields expose a rewritten process name.
Either source naming a verified harness is enough for `alive`, because a false `dead` is the one verdict that can start a duplicate agent on a live worktree, while a readable foreground process group settles the negative verdicts.

Scoping the second source to the foreground process group rather than to the pane's descendants is deliberate: a harness-named process left running in the background of an otherwise idle pane must not read as an agent.
The same scoping covers multi-process launchers without a special case, so the Pi Launcher path is attributed through its `pi-signed` wrapper and `pi` engine even though its title is the exact foreground command `pi-launcher`.
Direct executable identities `pi`, `pi-signed`, and `Pi` remain accepted exactly, and similar or prefixed process names are not accepted through those exact Pi-family entries.
Muse is likewise anchored to the exact `muse` launcher identity or the installed `muse-bin-<version>` prefix, so unrelated names such as `musescore` and `amuse` remain ambiguous.
omp is anchored to the exact `omp` identity for the same reason, so `ompd` and `comp` remain ambiguous.
AGY and Devin are anchored to the exact `agy` and `devin` identities for the same reason, so unrelated names containing either fragment remain ambiguous.
Cursor is identified from its exact `cursor-agent` identity or versioned install tree in the foreground process path or structured argv[0]; a bare `node` or unrelated `agent` remains ambiguous.

The CI-enforced portable regression and opt-in real-harness drift guard follow the split owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the real-harness guard after any harness upgrade and before trusting refreshed evidence.

### Composer, busy state, and delivery

Agent liveness and composer safety are separate checks.
The tmux reader is a thin adapter over the fleet-wide classifier in `bin/fm-composer-lib.sh`: it contributes one styled full-pane capture, the `#{cursor_y}` cursor row, and foreground-process identity probes, and the supported shape containing the cursor normally decides the verdict.
Real text in an identified shape is pending, while only positively proven emptiness reads empty.
A blank or otherwise unidentified cursor row is `unknown` and every consumer defers, except that a foreground process proven to be Cursor is re-read cursorlessly because Cursor parks its terminal cursor below its footer.
That identity-gated exception preserves the strict container-proof rule for every other pane, so a modal dialog, a dead shell between stale rules, or a mid-redraw pane is never an injection target.
The shared supported shapes, prompt-glyph limits, and plain-capture safety boundary are owned by [Composer and injection safety](herdr-backend.md#composer-and-injection-safety).

Busy state is not read from rendered text on this backend.
A task's busy, idle, unknown, or dead verdict comes from the semantic busy-state contract owned by `bin/fm-busy-lib.sh`; [architecture](architecture.md#busy-state-is-semantic-per-adapter) owns its boundaries.
The isolated rendered-tail busy fallbacks that remain are harness-scoped, so one adapter's output can never classify another's task.
The submit acknowledgement and away-mode supervisor-pane busy guard below still consult rendered output, but only to decide whether input can be delivered, never to decide recorded task state.
The supervisor guard selects only the detected primary harness's signature rather than a global union of vendor patterns.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a positively identified omp foreground process receives the pre-retry refresh: after pending or unproven pending, a fresh empty or unreadable composer receives no further Enter. Identification uses tmux's foreground command and the existing foreground-process-group probe, and remains attached to the submission attempt.
The submit primitive returns `empty` only after composer-clearance proof or one of the delivery-proof exceptions below.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown except that an unconfirmed omp submit or unavailable initial identity returns `pending`.
An ordinary local `fm-send.sh` text steer and every remote text steer no longer ride this verified submit at all: they become durable steering-inbox records plus best-effort constant doorbell lines (`bin/fm-task-inbox-lib.sh`).
The verdicts above are delivery-critical only for the local typed plane - harness-native invocations and explicit backend targets - where `fm-send.sh` still never retypes or assumes a confirmed submit for an unconfirmed verdict; its header owns the distinct delivered-unconfirmed exit status and operator response.

[Watcher continuity](watcher-continuity.md#omp-restored-wake-recovery) owns omp editor recovery and its known limits; [architecture](architecture.md#event-driven-supervision) owns the parent no-draft boundary.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
The legacy non-omp tmux path accepts structurally proven pending text in a busy pane as queued after the normal retry budget; idle panes and ambiguous pending text remain unconfirmed.
It also preserves main's baseline-gated conversion for an unreadable mid-turn composer (including Pi's `pi-launcher`): an idle baseline before typing and a busy footer after Enter confirm delivery, using the same legacy matcher on both sides.
The legacy matcher excludes omp's spinner-only, spinner-box, and Waiting signals; the widened omp matcher remains available to positively identified omp and identityless delivery guards.
All non-omp harnesses retain main's Enter retry behavior without the new refresh.
omp and unavailable initial identity never receive either busy-only conversion: an independent watcher turn cannot prove that Enter consumed the typed payload, so an unreadable composer returns `pending` even when busy. There is no omp busy-baseline confirmation boundary; only a positively empty composer confirms submission.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers, including a dropped Enter followed by an independent omp watcher turn and a cursor/screen redraw race.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-tmux-agent-liveness.test.sh
tests/fm-harness-liveness-drift-live-e2e.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-cursor-harness.test.sh
tests/fm-muse-harness.test.sh
tests/fm-omp-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
