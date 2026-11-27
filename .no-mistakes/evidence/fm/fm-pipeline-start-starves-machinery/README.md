# Test-phase evidence: fm-pipeline-start-starves-machinery (head 19e016c27, base d25e907c1)

Every scenario below ran the real `bin/fm-cpu-pass.sh`, `bin/fm-duration.py` and `bin/fm-mem-guard.sh` as separate processes.
Each ran against a disposable sandbox: a private `FM_CPU_POOL_DIR`, a fixture run database, a fixture `FM_HOME` and native memory facts.
These were injected at the repository's test-only observation boundary (`tests/fm_cpu_pass_fixture.py`).
Nothing touched the real pool, `~/.no-mistakes/state.sqlite` (only a read-only `mode=ro` SELECT of `worktree_dir` shapes) or the live launcher.

| File | What it shows |
| --- | --- |
| `p1-after.txt` / `p1-base.txt` | P1 (a) the live 11-run case, (b) the 12-run 14:14Z record, (c) the control one page below the fit. Head admits (a) and (b) at the first poll and holds (c). Base holds all three (`need=88723286911`, `need=94918777235`). |
| `p6-after.txt` / `p6-base.txt` | P6 call shapes. On head, every fresh shape queues and is admitted by itself when room returns. Reattach, respond, status and other commands run at once. On base, the fm-mem-guard shapes, PR 366's shape and `rerun` skip the gate. |
| `p4-holds.txt` | P4(a) holds: pressure 2, pressure 4, memory reading error, unreadable process count, process pile-up. Each holds COMMAND and admits it by itself once healthy. The control (all facts healthy) is admitted at once. |
| `p11-launcher-copy.txt` | Launch gate through an isolated copy of the launcher whose final line is `exec <gate> launch-gate -- <stand-in claude> "$@"`. It is called as the daemon calls it (argv, prompt on stdin, run worktree as cwd, own process group). Results: admit, pass-through, unmapped refusal, hold then self-admit, hold-bound refusal, group kill, gate-only SIGKILL, missing agent (127), SIGTERM forwarding. |
| `live-launcher-hash-before.txt` / `-after.txt` | The sha256 of `~/.no-mistakes/bin/claude-teamclaude` was the same before and after the launcher-copy run. |
| `admission-run.txt`, `gate-run.txt`, `attribution-run.txt` | The repository's own end-to-end scenario files for this change, run on head. |

Driver scripts (scratch, not in the repo): `/tmp/fmcp-drive/{p1_drive,p6_drive,p4_drive,gate_drive}.py`, each called as `SCRIPT REPO PARENT PYTHON [LABEL]` with `FIXTURE_DIR=<worktree>/tests`.
Base runs used `git archive d25e907c1 bin tests` exported to `/tmp/fmcp-base`. The new coalition shim was dropped for base, because base has no `fm_proc_info.coalition`.
