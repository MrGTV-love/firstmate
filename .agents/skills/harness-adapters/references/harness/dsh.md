# dsh (DeepSeek Harness)

dsh is the terminal frontend for DeepSeek Harness, launched through `dsh-tui`.
It is verified as a crewmate and scout adapter only; it has no primary supervision protocol, so `../../../bin/fm-spawn.sh` refuses a secondmate on it.
Runtime evidence is owned by [runtime verification](../../../docs/verification/runtime-backends.md#deepseek-harness-dsh-tui); portable regressions are [`tests/fm-dsh-harness.test.sh`](../../../tests/fm-dsh-harness.test.sh) for the adapter helper and [`tests/fm-dsh-spawn.test.sh`](../../../tests/fm-dsh-spawn.test.sh) for detection, the spawn route and launch environment, launch policy, and busy and liveness classification, and the live lifecycle guard is [`tests/fm-dsh-live-e2e.test.sh`](../../../tests/fm-dsh-live-e2e.test.sh).

## Operating facts

| Fact | Value |
|---|---|
| Binary | `dsh-tui`, resolved from `PATH` and otherwise from the installed nvm `bin` directory by `../../../bin/fm-dsh-lib.sh`; the launcher and its installed `dsh-tui` profile must both report `0.16.1`, and the `dsh` CLI it spawns must report `0.2.0-rc.2`. A missing or differing runtime refuses the spawn before any endpoint exists. The launch prepends the launcher's own directory to `PATH`, because the launcher finds the CLI through `PATH` and a pane without the installing nvm bin directory otherwise exits with `dsh CLI not found`; that nvm `bin` directory therefore resolves the worker's `node` and `npm` first, which is intended. |
| Launch | `../../../bin/fm-spawn.sh` owns the exact template: a per-launch `HOME` and `DSH_HOME`, `--patch <launch.yml>`, then `-- <brief>` as the opening prompt. The spawn succeeds only once the session log records a turn that started beyond the log position `bin/fm-dsh.py position` took before launch, so a resumed relaunch cannot pass on the earlier conversation. No operator profile or credential file is mutated. |
| Model and effort | `dsh-tui` exposes no model or effort launch flags, so `bin/fm-dsh.py prepare` writes the exact route into the launch-local patch and the launch-local `~/.dsh-tui/model.json` and `effort.json`. Effort accepts the `low`, `medium`, `high`, `xhigh`, and `max` levels. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `dsh-session-log`: `bin/fm-dsh.py state` folds the launch's own plain `session.v4.jsonl` and reports busy on the last durable `turn/start`, idle on `turn/end`, and unknown for a missing, unsupported, or non-monotonic log. The fold starts at the newest `turn/start`, found by a bounded backward scan, so a turn larger than one chunk of the log still reads busy. The launch configures `session-persistence-jsonl` with `compression: none` and a launch-local `root`, so no plugin is required. |
| Exit command | `/exit` (`/quit` and `/q` are aliases). |
| Interrupt | Escape; the interrupt key table in `../../../bin/fm-control-lib.sh` carries it. |
| Resume | `bin/fm-dsh.py resume` rewrites the task's launch patch with its newest session id in the `dsh-tui` row's `sessionId` field, and DSH continues that conversation in place, appending to the same session log. The overlay is what makes this work: the launch patch replaces the stock profile patch field that reads `DSH_TUI_RESUME_SESSION`, so the env or `--resume` flag alone silently opened a fresh session. Verified by a live probe in which a resumed session recalled a secret word from the earlier turn, and by the live lifecycle guard's same-log growth and earlier-conversation assertions. The durable fold follows the newest depth-zero log. A resume that cannot be proven (a changed model, effort, or working directory, or a missing binding or log) prepares a fresh launch from the new instructions instead. |
| Marker | `FM_DSH_HARNESS=dsh` is Firstmate's launch marker; DSH publishes none of its own. Ancestry matches the anchored process names `dsh` and `dsh-tui`, plus the launcher, adapter host-entry, and `dsh` binary script paths seen in a Node argv. |
| Trust | No folder-trust or permission dialog was observed on a fresh local copy or a fresh git repository running a shell command under the default workspace-write policy. The onboarding guide is dismissed with Escape, and `DSH_TUI_NO_LAUNCHPAD=1` bypasses the launchpad. |
| Composer | A rounded frame whose side rows open with `⌸` and close with `⛶`, holding the `❯` prompt glyph; `../../../bin/fm-composer-lib.sh` proves it as a bordered box, and the rendered busy footer is `esc to interrupt`. |
| Autonomy | `DSH_PERMISSION_MODE=danger-full-access` at the launch boundary selects DSH's own `danger-full-access` sandbox and `never` approval policy. The default `workspace-write` posture is unusable for a worker: a firstmate worker writes its steering inbox and status record outside the workspace, and that write parked a live worker on an `Awaiting approval` panel until the environment was changed. |

## Detection

`../../../bin/fm-harness.sh` accepts `FM_DSH_HARNESS=dsh` only when the ancestry walk reaches a real dsh process or launcher argv, so an inherited marker is inert.
The dsh template clears every foreign marker at its own boundary, and the omp template clears `FM_DSH_HARNESS` for the same reason.
`../../../bin/fm-session-lock-lib.sh` counts the same process names as owning a session lock, and `../../../bin/backends/tmux.sh` classifies both its own launcher argv and `bin/fm-dsh-lib.sh`'s script paths as an agent.

## Routing

`bin/fm-dsh.py route` prints the model-family default: provider `deepseek` or a `deepseek/` model prefix selects dsh, `claude*` selects claude, and everything else selects omp.
`../../../bin/fm-spawn.sh` acts only on the DeepSeek answer, and only for a crewmate or scout with no explicit harness: it then switches to dsh. A secondmate, an explicit harness, and a raw launch are never re-routed.
`bin/fm-dsh.py check` refuses a dsh launch unless the model is a concrete DeepSeek id (an optional `deepseek/` prefix, then a non-empty id with no `/` or whitespace), the shape `prepare` accepts, so a relaunch is refused before the running agent stops. An explicit omp, pi, or claude stand-in on a DeepSeek model stays legal.
`../../../bin/fm-dispatch-resolve.sh` normalizes a provider-only DeepSeek profile to the canonical `deepseek/<id>` model before it is frozen, so the routing check sees one spelling; a profile whose model or provider is not a string is left for the rules validator to report.

## Launch posture

The launch swaps `HOME` for the task's private one, because `dsh-tui` keeps its model and effort preferences under `~/.dsh-tui` and has no flag for them.
Other HOME-relative tool state is therefore absent from the worker on purpose: ssh keys, `gh` configuration and tokens, `~/.npmrc`, toolchain and package caches, and the XDG git configuration are neither copied nor linked.
Exactly two paths are carried as environment variables resolved by the pane shell before `HOME` changes, so they name the operator's real files and nothing is copied: `GIT_CONFIG_GLOBAL` (the exported value, else `~/.gitconfig`) keeps the configured commit author and works beside the `GIT_CONFIG_*` `core.hooksPath` entry, and `NM_HOME` (the exported value, else `~/.no-mistakes`) lets `no-mistakes` reach the shared daemon, which it otherwise looks for under `$HOME/.no-mistakes`.
Run from a swapped `HOME`, `no-mistakes daemon status` reported the same running daemon as the operator's shell with `NM_HOME` carried and `daemon not running` without it; [runtime verification](../../../docs/verification/runtime-backends.md#deepseek-harness-dsh-tui) records the run.

Each launch stages a private `HOME` and `DSH_HOME` under the task's state directory, reproduces the installed profile's package tree inside it, copies the credentials, and writes the launch patch and model preferences there.
The installed profile's `node_modules` is reproduced file by file inside the launch root (hard links where the filesystem allows, copies otherwise) and never linked as a directory: Node resolves real paths before DSH's profile interception, so a directory link escapes the isolated profile and selects the launcher's own incompatible packages.
`bin/fm-dsh.py prepare` publishes `state/<id>.dsh-session`, which is the single binding consumed by busy classification and resume, and retires the generation that binding replaced.
`../../../bin/fm-teardown.sh` removes `state/<id>.dsh` and the binding, so the credentials copy and session logs do not outlive the task.
