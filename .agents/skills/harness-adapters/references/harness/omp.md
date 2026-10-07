# omp (Oh My Pi)

Verified for crew, scout, secondmate, and primary work on Herdr on 2026-09-05 with omp 18.1.11, building on the 2026-09-02 adapter investigation against 18.1.2.
omp is a Pi fork, so `references/harness/pi.md` is the nearest relative; every difference from Pi is stated here.
Cross-harness provider and credential identity is owned by `references/common/model-and-effort.md`.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `omp`, a single Bun-compiled executable resolved from `PATH` by `../../../bin/fm-spawn.sh`; a missing binary refuses the spawn. |
| Launch | [`fm-spawn.sh --help`](../../../bin/fm-spawn.sh) owns launch flags, session posture, worker memory scope, and secondmate extension loading. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `omp-ext`: the crewmate/scout per-task extension marks busy at `agent_start`, and idle at `agent_end` only when `willContinue` is not true; `ctx.isIdle()` is deliberately not consulted because it reads false at a natural TUI `agent_end` (`session_stop` is awaited before settle). Secondmates do not load a parent-task busy adapter. |
| Exit command | `/quit` (`/exit` and `/q` are aliases). |
| Interrupt | Single Escape; the composer is left empty, no clear key. |
| Skill invocation | No separate verified form beyond normal command behavior; use natural language when the exact command is uncertain. |
| Model flag | `--model <provider>/<id>`; omp also accepts fuzzy patterns. Firstmate selection follows the [fleet model-index contract](../../../docs/configuration.md#fleet-model-index-configmodel-indexjson), and native non-entry validation is owned by [`fm-spawn.sh --help`](../../../bin/fm-spawn.sh). |
| Effort flag | `--thinking <off\|minimal\|low\|medium\|high\|xhigh\|max\|auto>`, a superset of the shared vocabulary, so every level including `max` maps straight across. |
| Model discovery | `omp models [--json]` lists built-in and auto-discovered providers only; extension-registered providers such as `claude-bridge` never appear. `omp usage` shows provider windows; `quota-axi` covers the `claude` provider when the bridge is in use. |
| Marker | None of omp's own (verified: `PI_CODING_AGENT` absent from the binary, no `PI_CODING_AGENT_DIR` or `OMP_PROFILE` in the default profile). `FM_OMP_HARNESS=omp` is Firstmate's launch marker; ancestry matches the exact process name `omp`. |
| Composer | See [`fm-spawn.sh --help`](../../../bin/fm-spawn.sh) for the composer posture pin; busy text is `Working…` (U+2026), the only spelling the omp busy regex accepts (the three-dot form its headless `-p` mode writes never reaches a supervised pane), with the status row's braille spinner plus elapsed cell as the second signal; box-shape support and overlay live-reload evidence are recorded in [omp box composer through Herdr](../../../docs/verification/runtime-backends.md#2026-10-06-omp-box-composer-through-herdr). |
| Autonomy | Approval and unattended-session posture are owned by [`fm-spawn.sh --help`](../../../bin/fm-spawn.sh). |
| Trust | No project-trust gate at all; a fresh profile shows a provider-login wizard instead, suppressed by `OMP_SKIP_SETUP=1`. |
| Resume | `-c/--continue` and `-r/--resume` exist but carry no verified pane-resume contract; use deterministic relaunch. |

Keep the instructions as one positional argument; a second positional never surfaced as a submitted message.
The openai-codex models reach an extension-registered tool through omp's `xd://` virtual-file bridge: the model reads `xd://fm_watch_arm_omp` for the description and writes `xd://fm_watch_arm_omp` to invoke it, so a transcript or rpc stream shows a `write` to that path rather than a direct `fm_watch_arm_omp` call; both are the same invocation (verified 18.1.11).
omp cold start is roughly twenty seconds to the first agent turn, paid once per worker.

## Detection

`../../../bin/fm-harness.sh` tests `FM_OMP_HARNESS=omp` before `CLAUDECODE`, like Cursor's markers, and its ancestry walk matches the anchored process name `omp` above the interpreter fallback.
The omp template in `../../../bin/fm-spawn.sh` clears every foreign marker at its own launch boundary, and `FM_OMP_HARNESS=omp` counts only under a real `omp` ancestor, so the marker inherited by any other launch is inert: an omp secondmate's workers keep their own identity and an inherited `CLAUDECODE` cannot outrank a worker that omp launched.
`../../../bin/fm-session-lock-lib.sh` matches the same anchored name for session-lock ownership, and `../../../bin/backends/tmux.sh` classifies it `agent` for liveness.
The optional claude-bridge extension runs a nested executable literally named `claude` as a sibling of tool execution, never an ancestor of it, so omp's own tool calls detect as omp; that subtree is never walked by a Firstmate script.

## Launch posture

[`fm-spawn.sh --help`](../../../bin/fm-spawn.sh) owns session posture, worker-only memory scope, and the invariant that the captain's own configuration is never written.

## Extension loading

omp auto-discovers `<cwd>/.omp/extensions/*.ts` (top level only, cwd only, no ancestor walk, no trust dialog) and the active profile's `agent/extensions/`; `.pi/extensions/` is not a discovery root.
A file that is both auto-discovered and named with `-e` loads twice, so a canonical crewmate/scout launch loads its semantic busy extension explicitly from the parent's `state/`. Ordinary secondmate launches use home-local auto-discovery for their tracked primary extensions, without a parent-task busy adapter or explicit duplicate loading.
There is no `agent_settled` event; `agent_end` plus `willContinue` replaces it.

## Primary integration

The omp primary follows the Pi extension-owned watcher model through `../../../docs/supervision-protocols/omp.md`: `.omp/extensions/fm-primary-omp-watch.ts` arms `bin/fm-watch-arm.sh --restart` through the `fm_watch_arm_omp` tool and owns every successor, and `.omp/extensions/fm-primary-turnend-guard.ts` answers omp's blocking `session_stop` hook by forcing one continuation when `../../../bin/fm-turnend-guard.sh` returns 2, bounded per turn by omp's `stop_hook_active` flag.
The same file ports the `tool_call` seatbelts and delivers the session-start digest through `before_agent_start` on the Run tier; omp's `session_start` carries no reason, so the source is derived (first start `startup` or `resume` from the launch line, later in-process starts `clear`, `session_compact` as `compact`).
omp has no asynchronous Stop-hook equivalent, so the Claude auto-arm model does not apply; `fm_supervision_model` classifies omp as `extension`, and `fm_omp_extension_owns_supervision` in `../../../bin/fm-wake-lib.sh` is the ownership proof that tolerates the extension's own watcher hand-off.
The Pi supervision branch does not run on omp; without the supervision host every actionable wake is delivered to main, and in a home with `config/supervision-host` the watch extension spawns the host instead of the arm, with Claude's print mode as its headless engine ([`supervision-host.md`](../../../docs/supervision-host.md)).
Launch a primary with plain `omp` inside the home (`FM_OMP_HARNESS=omp omp` when starting from a Claude pane); `../../../bin/fm-session-start.sh` prints `OMP_WATCH_EXTENSION: not loaded` when the running session has not loaded both tracked supervision extensions.
omp puts a queued user follow-up back into the composer when a run is interrupted (Esc, including `../../../bin/fm-control.sh <id> interrupt`) or dequeued with Alt+Up, so a watcher wake queued behind a running turn can sit there unsubmitted.
Before recording or sending a wake, the watch extension normalizes CRLF and CR to LF, expands each tab to three spaces, and strips other C0 controls to match omp's editor restoration; consumption and recovery still match the emitted text exactly.
The watch extension reads the real editor after `agent_end` and recovers only a complete unchanged emitted wake segment, bounded by editor edges or omp's blank-line joins. Only the wake's leading invisible transport mark may be present or absent; prepended, appended, or internally edited wake text is left untouched and not submitted. It removes only the wake and one transport blank-line separator before resending through omp's API. Recovery uses a fixed two-second interval, is bounded to three attempts per wake, and preserves the original bytes of an operator draft, including invisible marks and leading/trailing newlines.
A wake restored by Alt+Up while idle without `agent_end` is not resubmitted, and rare credential loss during recovery can reject resubmission after the editable copy is removed; the durable queue and shutdown handoff retain the wake, the existing stalled-loop alarm reports either stall for a human, and consumption-confirmed removal remains follow-up `fm-omp-wake-recovery-rollback`.
The parent never submits held composer text. A stalled omp secondmate queue retains the ordinary parent alarm when composer text cannot be recovered by the extension; omp is excluded from generic parent idle ringing because the shared composer classifier cannot prove operator draft absence. The ordinary non-omp idle ring still requires a live agent, positive semantic idle, and a positively empty composer.
`FM_OMP_WAKE_RESTORE_LIVE=1 ../../../tests/fm-omp-wake-restore-live-e2e.test.sh` is the opt-in live guard for that recovery, the busy-composer reading, and the marker ownership rule.
`FM_OMP_LIVE_E2E=1 ../../../tests/fm-omp-primary-live-e2e.test.sh` is the opt-in live guard; `../../../tests/fm-omp-harness.test.sh` is the portable regression.
A secondmate registered with `remote=1` in `data/secondmates.md`, spawned through the ordinary `../../../bin/fm-spawn.sh <id> <home> --secondmate` path, is refused on omp until a remote host verifies it, as is `../../../bin/fm-remote-secondmate-control.sh launch`; there is no `--remote` flag.
