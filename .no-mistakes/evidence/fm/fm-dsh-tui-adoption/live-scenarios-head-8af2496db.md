# Live validation, head 8af2496db (run 01M5Q7KGBVXZQ999M5NBJF5W6V)

Model resolved at run time: deepseek/deepseek-v4-flash, through `bin/fm-dsh.py preferred-model` on a disposable operator home (symlinks to every real HOME entry except .dsh and .dsh-tui, plus its own .dsh-tui/model.json). The real HOME has no .dsh-tui/model.json.
All Herdr work ran in named fm-lab-* sessions through bin/fm-herdr-lab.sh. Every lab session is gone (`herdr session list` shows 0 of this run's labs). 0 credential copies were left in any task home. All temp homes were deleted.

| Scenario | Result | Log |
| --- | --- | --- |
| Real DeepSeek ship: brief, busy composer, mid-task steer, interrupt, exit, same-conversation resume, final exit | pass | live-fm-dsh-live-e2e.log |
| Real DeepSeek scout: same lifecycle | pass | live-fm-dsh-live-e2e.log |
| DSH primary + fresh dsh secondmate: startup, watcher, wake, turn-end recovery, interrupt, exit, resume, owner-death recovery | pass | live-fm-dsh-primary-live-e2e.log |
| Routing owner CLI: deepseek/ prefix (any case or padding) and provider deepseek -> dsh; claude* -> claude; others, including `deepseekish/`, -> omp | pass | live-routing.log |
| Explicit --harness omp + DeepSeek model refuses before launch; no agent, no dsh binding, meta unchanged | pass | live-routing.log (S-ROUTE-REFUSE) |
| omp-recorded ship relaunched with only a DeepSeek model refuses with "select --harness dsh" (it never runs on omp) | pass | live-routing.log (S-ROUTE-IMPLICIT) |
| Fresh scout, no --harness, crew-harness=omp, DeepSeek model -> spawned harness=dsh, dsh-tui ran the brief | pass | live-routing-scout.log, live-rscout-out-scout.txt |
| NEW (this run): XDG-only operator git identity: worker Bash sees no GIT_CONFIG_GLOBAL, `git config --global user.name` = FmXdgLabUser | pass | live-review-fixes.log, live-fixes-out-xdg.txt |
| NEW: pane that exports GIT_CONFIG_GLOBAL: worker keeps that path and reads FmExplicitLabUser | pass | live-review-fixes.log, live-fixes-out-explicit.txt |
| NEW: committed non-session header in a session log: relaunch refuses with "does not open with a session header"; generation and v4 log byte-identical; no agent | pass | live-review-fixes.log (S-MALFORMED) |
| NEW: partial or empty session.v5.jsonl beside the live v4 log: session-file/position/state read v4; relaunch keeps the same generation and v4 log (no discard) | pass (firstmate side) | live-uncommitted-*.log |
| Same case, end to end: real dsh-tui 0.16.1 itself exits ("dsh-tui exited unexpectedly (code 1). Enter safe mode?") when it finds the foreign v5 file. Firstmate reports "no turn started beyond the launch position" and keeps the work. After the v5 file is removed, the same task resumes the same v4 log and recalls its secret word | observed; recovery pass | live-uncommitted-partial-screen.log, live-uncommitted-empty-screen.log, live-uncommitted-recovery.log, live-unc-*-last-live-pane.txt |
| Portable regressions: fm-dsh-harness, fm-dsh-spawn, fm-dsh-primary | pass (not live) | portable-summary.txt, portable-*.log |

Process note: the fresh-scout routing driver did not unset $TMUX. The product correctly detected the tmux runtime it ran inside, so that one scout opened window `fm-dsh-rscout-36405` in the default tmux session `firstmate` and leased slot 1 of a new treehouse pool `project-8da207` made for the throwaway lab project. The scout was stopped. It was then torn down through bin/fm-teardown.sh against its lab home, which killed that window and returned the slot. The exact disposable worktree was destroyed with `treehouse destroy <path> --yes`, and the empty pool directory was removed. No other window, pane, or pool was touched.
