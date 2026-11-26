# Test-step evidence: fm-adopt-omp-promax-bun-runtime at 40c3578be

Base for red legs: 7db75b5ab (its `bin/` extracted with `git archive` into scratch).
Host: macOS, omp-promax launcher `~/.local/share/omp-promax-fix/omp-promax` (omp 18.15.0, Bun runtime), herdr 0.9.5.
The host load average was 75-190 during these runs because of other sessions' tests.

| File | What it shows | What is real |
|---|---|---|
| `herdr-lab-bun-omp-adopt.run3.log` (script `herdr-lab-bun-omp-adopt.v2.sh`) | Restored Bun omp in a Herdr lab pane. Before adopt: `interrupt` refuses with "cannot positively attribute its live Herdr agent". Base `adopt`: "process proof needs ... a readable omp process". Head `adopt`: `adopted`, record gets the live pid and start time. Verdict `managed`, `interrupt-delivered`. A second adopt refuses (same PID). A foreign Bun script and the installed runtime on another `src/cli.ts` both refuse at the process proof, and their records do not change. | Real: Herdr lab session, Herdr process-info, the installed Bun omp (resumed, no prompt), `fm-control.sh` base and head, marked lab FM_HOME. Stand-ins: (1) the Herdr `agent get` answer gets the task session path added, because Herdr 0.9.5 kept no session path for this Bun pane in the lab; (2) `/rename lab-title` is typed into the lab omp so that it opens its session file (an idle resumed omp holds none). |
| `herdr-lab-bun-omp-adopt.run2.log` | The same run without stand-in 1: head passes the process proof and refuses at the session proof. The record does not change. | Same as above, no registration stand-in. |
| `herdr-lab-bun-omp-adopt.run1.log` | The first run: base vs head identity on the live PID, and head adopt refuses at the session proof. | Same. |
| `herdr-lab-descendant-walk.run1.log`, `.run3.log` | The pane shell is in front and the real Bun omp is a live background descendant: base walk `shell` (agent-free), head `other` (occupied). An empty shell is `shell` on both. Other hand-made job cases were noisy under load (jobs exited or had not started) and prove nothing. | Real Herdr, real ps, real installed omp. |
| `herdr-walk-case-isolated.log` | `test_missing_registration_requires_process_evidence` run alone (the definitions of tests/fm-backend-herdr.test.sh, without the unrelated server-start python suite that timed out under load). Passes. It includes the bun-then-agent order (R7-3). | Automated test, stubbed ps. |
| `herdr-walk-test_missing_registration_requires_process_evidence.log` | The whole-file run: the unrelated python suite `test_guard_and_adapter_starts_race_to_one_server` timed out after 30 s under load, before any case ran. | Not caused by this change: the server-start code is not in the diff. |
| `live-role-shapes.log` (script `live-role-shapes.py`) | Live roles on real processes: interactive pty is admitted; `--mode rpc` and `--mode=rpc` are refused; a single argument value that contains `--mode rpc` is admitted; piped stdin is refused; a foreign executable that shows the installed paths as argv is refused; `bun run dev` is unrelated (writer exit 1); relative `bun src/cli.ts` is unresolved (may own); the installed runtime on a scratch `src/cli.ts` is refused. | Real installed launcher and runtime, real `~/.bun/bin/bun`. |
| `live-guard-installed-omp-promax.log` | `tests/fm-omp-identity-live-e2e.test.sh` with `FM_OMP_IDENTITY_LIVE=1 FM_OMP_IDENTITY_LIVE_LAUNCHER=<omp-promax>`: 6 invariants pass on the installed omp. | Real installed omp. |
| `omp-identity-test.log` | `tests/fm-omp-identity.test.sh` (real stand-in processes). | Automated. |
| `adopt-backends-test_omp_adoption.log` | `tests/fm-control-relaunch-backends.test.sh test_omp_adoption` (real fm-control.sh, fake Herdr CLI, compiled bun stand-in, real `.omp` extension). | Automated. |
| `*.attempt1-killed-at-30min.log` | The first attempts of the two automated runs. They were stopped at the 30-minute background limit under load, with no failure. | - |

No real worker, no real FM_HOME and no default Herdr session was touched. Every lab was torn down in the same run.
The 11 restored workers were not assessed. No live Bun omp worker existed on the host at test time (a `ps` check found none), and probing or adopting real workers is out of scope for this step.
