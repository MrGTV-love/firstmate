# Live validation: prune a pool copy right after its PR merges

Transcript: `live-merge-prune-scenarios.txt` (7 scenarios, 48 checks, all PASS).
Harness: `live-harness-world.sh` and `live-harness-run-scenarios.sh`.

## What runs for real

- `bin/fm-merge-prune.sh`, `bin/fm-teardown.sh` and `bin/fm-watch.sh` from the change under test.
- The real `treehouse` v3.1.4 binary, using a throwaway `TREEHOUSE_ROOT` and a throwaway `HOME`.
  The task pane runs the real interactive `treehouse get -b fm/t1`, the same way a crewmate spawn does.
- A real tmux server on the lab home's private socket directory (`bin/fm-lab-home.sh tmux-dir`).
- Real git: a bare origin, a project clone, a squash merge, and `refs/pull/7/head`.
- A marked, disposable firstmate lab home (`bin/fm-lab-home.sh create`).

## What is stubbed (outside services only)

- `gh` and `gh-axi` (GitHub: PR 7 is MERGED at the pushed head), `no-mistakes`, and `docker`.
- `fm-control.sh exit`. A stub stops the agent stand-in (a `sleep` in the treehouse subshell),
  writes `control-exit` and retires the busy record. No real agent CLI runs in the pane.
- Two transparent recorders. They only log the arguments of the real `treehouse` and the output of the real teardown.

## Scenarios

| # | Scenario | Result |
|---|----------|--------|
| S1 | A merged task is armed with `--run`, the same call `fm-pr-merge.sh` makes. Real teardown returns the slot to the real pool. | PASS |
| S2 | The 2026-10-18 case: the project's closeout driver refuses a nested copy with "exact tree not covered". The fallback proves the copy, then real `treehouse destroy <slot> --include-leased --yes` removes it. | PASS |
| S3 | A copy with an unpushed commit is kept. It raises one wake. The pane shell and the agent are not touched. | PASS |
| S4 | The nested copy has an untracked file. `status.showUntrackedFiles=no` hides it. The copy is kept and raises one wake. Teardown refuses first. | PASS |
| S5 | A copy has a follow-up commit that was pushed but is not in the merged PR. The copy is kept before anything is stopped. | PASS |
| S6 | Another actor holds the task lifecycle lock. The prune backs off silently, then reaps the copy on retry. No wake. | PASS |
| S7 | A real `fm-watch.sh` tick starts the real sweep for an armed record. The copy is pruned. | PASS |
