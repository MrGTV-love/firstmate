# Test phase, second pass: head 19e016c27, base d25e907c1 (2026-11-27)

All files with the `run2-` prefix come from this pass. The earlier files without the prefix are left as they were.

Every scenario ran the real `bin/fm-cpu-pass.sh`, `bin/fm-duration.py` and `bin/fm-mem-guard.sh` as separate processes.
Each ran in a disposable sandbox: a private `FM_CPU_POOL_DIR`, a fixture run database, a fixture `FM_HOME` and fixture native memory facts.
The facts were injected at the repository's test-only observation boundary (`tests/fm_cpu_pass_fixture.py`).
Nothing wrote to the real pool, `~/.no-mistakes/state.sqlite` or the live launcher.

| File | Scenario |
| --- | --- |
| `run2-p1-head.txt` / `run2-p1-base.txt` | P1: the live 11-run case and the 12-run record are admitted at the first poll on head. The control one page below the fit waits. Base holds all three. |
| `run2-p4-holds.txt` | P4(a): pressure 2, pressure 4, a memory read error, an unreadable process count and a pile-up each hold COMMAND. Each start is admitted by itself about 1 s after the fact turns healthy. |
| `run2-p6-head.txt` / `run2-p6-base.txt` | P6: on head all 7 fresh shapes queue and are admitted. Reattach, respond, status and other commands run at once. On base, 4 fresh shapes skip the gate. |
| `run2-p6-adversarial.txt` | P6: absolute path, reordered flags and an env wrapper also queue. A no-intent call passes exit 2 through. `machinery` (fm-duration) is admitted before `other` (fm-mem-guard), which queued first. |
| `run2-launch-gate.txt` | P9/P11: the launch gate through a synthesized launcher with the gate line (not a copy of the live launcher), called as the daemon calls it. 9 cases: admit, pass-through, unmapped refusal, hold then self-admit, hold-bound refusal, group kill, gate-only SIGKILL, missing agent 127, SIGTERM forwarding. |
| `run2-p1-head-unactivated.txt` | P1 condition: the same three cases on head with no `gate-activation.json` in the pool. All three wait, as on base. The relief starts only after `fm-cpu-pass.sh activate` (`docs/cpu-pass-pool.md:128`, `:201`). |
| `run2-launch-gate-dispatcher.txt` | The same 9 launch-gate cases, with the agent behind a dispatcher that forks it and waits (the `tc run` -> `teamclaude` shape). All pass. In L9 the agent gets SIGTERM; the gate returns -15 because the dispatcher itself dies by SIGTERM. |
| `run2-p10-simultaneous.txt` | P10(a): the suite's `gate-three` case (`tests/fm-cpu-pass-gate.py:165-188`), room for two full reservations. a and b start, c waits with a durable line, and c starts by itself after a ends. |
| `run2-live-launcher-before.txt` / `-after.txt` | The live launcher sha256 did not change. Its final line is `exec /Users/charlesabrooker/.local/bin/tc run "$@"`. |
| `run2-admission-suite.txt`, `run2-gate-suite.txt`, `run2-attribution-suite.txt` | The repository's own end-to-end scenario files, run on head: exit 0 each. |
| `run2-drivers/` | The scratch driver scripts, each called as `SCRIPT REPO PARENT PYTHON [LABEL]` with `FIXTURE_DIR=<worktree>/tests`. |

Base runs used `git archive d25e907c1 bin tests` in scratch, driven through the head fixture boundary.
