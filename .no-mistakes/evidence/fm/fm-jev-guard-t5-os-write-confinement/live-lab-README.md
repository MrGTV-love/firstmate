# Live lab: T5 OS write confinement driven through real bin/fm-spawn.sh

Host: macOS (Darwin 27.0.0 arm64), /usr/bin/sandbox-exec, tmux on a private fm-lab socket.
Lab home: marked by bin/fm-lab-home.sh create (/private/tmp/fm-lab.gTPwcx); separate disposable HOME (/private/tmp/fm-lab-uh.FX2EML).
Real product pieces: bin/fm-spawn.sh, real treehouse pool (TREEHOUSE_ROOT=.claude/worktrees, so every worktree is nested in the primary checkout),
real tmux windows, real bin/fm-write-confinement.py profile, real sandbox-exec, real bin/fm-teardown.sh.
Stand-in: the harness binary (omp / claude / codex) is a model-free script (live-lab-harness-standin.sh) that runs
live-lab-attack-plan.sh inside the pane's launched process tree, then idles. No model, provider or paid call was made.

Tasks: lab-t5-b (omp, victim), lab-t5-a (omp attacker), lab-t5-c (claude attacker), lab-t5-d (codex control, unmeasured -> unconfined).

| Case | omp A (seatbelt-v1) | claude C (seatbelt-v1) | codex D (unconfined control) |
|---|---|---|---|
| a B3 glob rm of foreign Claude-temp + task-temp fixture | survived | survived | deleted |
| b B15 age sweep of ~/tmp foreign entry | survived (own swept) | survived (own swept) | deleted |
| c eval Path(...).unlink() foreign data / primary / foreign worktree | EPERM, survived (own unlink ok) | EPERM, survived | deleted |
| d write + commit in nested .claude/worktrees root | ok | ok | ok |
| e own status append / foreign status rewrite / own meta rewrite | ok / EPERM / EPERM | ok / EPERM / EPERM | ok / hijacked / hijacked |
| claude own session-env / other session-env / settings.json | - | ok / refused / refused | - |

Raw omp selector refusals (live-lab-raw-omp-selector-refusals.log): --profile, OMP_PROFILE=, PI_CODING_AGENT_DIR=$HOME/..., PI_CONFIG_DIR= each refused rc=1, no meta, no profile.
Teardown of lab-t5-b removed state/lab-t5-b.write-confinement.sb and left the other tasks' profiles.
