# dsh (DeepSeek Harness)

dsh is the terminal frontend for DeepSeek Harness, launched through `dsh-tui`.
It is verified as a crewmate and scout adapter only; it has no primary supervision protocol, so `../../../bin/fm-spawn.sh` refuses a secondmate on it.
Runtime evidence is owned by [runtime verification](../../../docs/verification/runtime-backends.md#deepseek-harness-dsh-tui); portable regressions are [`tests/fm-dsh-harness.test.sh`](../../../tests/fm-dsh-harness.test.sh) and the live lifecycle guard is [`tests/fm-dsh-live-e2e.test.sh`](../../../tests/fm-dsh-live-e2e.test.sh).

## Operating facts

| Fact | Value |
|---|---|
| Binary | `dsh-tui`, resolved from `PATH` and otherwise from the installed nvm `bin` directory by `../../../bin/fm-dsh-lib.sh`; the launcher and its installed `dsh-tui` profile must both report `0.16.1`, and the `dsh` CLI it spawns must report `0.2.0-rc.2`. A missing or differing runtime refuses the spawn before any endpoint exists. The launch prepends the launcher's own directory to `PATH`, because the launcher finds the CLI through `PATH` and a pane without the installing nvm bin directory otherwise exits with `dsh CLI not found`. |
| Launch | `../../../bin/fm-spawn.sh` owns the exact template: a per-launch `HOME` and `DSH_HOME`, `--patch <launch.yml>`, then `-- <brief>` as the opening prompt. The spawn succeeds only once the session log records a turn that started beyond the log position `bin/fm-dsh.py position` took before launch, so a resumed relaunch cannot pass on the earlier conversation. No operator profile or credential file is mutated. |
| Model and effort | `dsh-tui` exposes no model or effort launch flags, so `bin/fm-dsh.py prepare` writes the exact route into the launch-local patch and the launch-local `~/.dsh-tui/model.json` and `effort.json`. Effort accepts the native `off`, `low`, `medium`, `high`, `xhigh`, and `max` levels. |
| Busy state | `../../../bin/fm-busy-lib.sh` source `dsh-session-log`: `bin/fm-dsh.py state` folds the launch's own plain `session.v4.jsonl` and reports busy on the last durable `turn/start`, idle on `turn/end`, and unknown for a missing, unsupported, or non-monotonic log. The launch configures `session-persistence-jsonl` with `compression: none` and a launch-local `root`, so no plugin is required. |
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

`bin/fm-dsh.py route` is the one owner of the model-family decision: provider `deepseek` or a `deepseek/` model prefix selects dsh, `claude*` selects claude, and everything else selects omp.
`../../../bin/fm-spawn.sh` applies it when no explicit harness was passed, and `bin/fm-dsh.py check` refuses any dispatch profile whose declared harness contradicts its model or provider.
`../../../bin/fm-dispatch-resolve.sh` normalizes a provider-only DeepSeek profile to the canonical `deepseek/<id>` model before it is frozen, so the routing check sees one spelling.

## Launch posture

Each launch stages a private `HOME` and `DSH_HOME` under the task's state directory, copies the installed profile's package tree and credentials into it, and writes the launch patch and model preferences there.
The installed profile's `node_modules` is reproduced inside the launch root rather than linked: Node resolves real paths before DSH's profile interception, so a link escapes the isolated profile and selects the launcher's own incompatible packages.
`bin/fm-dsh.py prepare` publishes `state/<id>.dsh-session`, which is the single binding consumed by busy classification and resume, and retires the generation that binding replaced.
`../../../bin/fm-teardown.sh` removes `state/<id>.dsh` and the binding, so the credentials copy and session logs do not outlive the task.
