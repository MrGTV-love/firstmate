# Live validation, head ff592853b (run 01M5Q7KGBVXZQ999M5NBJF5W6V, test round 2)

DSH runtime files (bin/fm-dsh.py, fm-spawn.sh, fm-control.sh, fm-dsh-lib.sh, fm-dsh-primary.sh, fm-busy-lib.sh, fm-harness.sh, fm-control-lib.sh, fm-composer-lib.sh, fm-model-index.sh) are byte-identical to the round-1 head 8af2496db. The only branch runtime change since then is the fm-dispatch-resolve.sh refusal text; the rest is the rebase onto main cced61811. Every lifecycle below was re-driven on this head, not reused.

Model resolved at run time: deepseek/deepseek-v4-flash via `bin/fm-dsh.py preferred-model` on a disposable operator home (symlinks to every real HOME entry except .dsh and .dsh-tui, plus its own .dsh-tui/model.json). All Herdr work ran in named fm-lab-* sessions through bin/fm-herdr-lab.sh. No lab session from this round remains. 0 credential copies left. All temp homes from this round were deleted.

| Scenario | Result | Log |
| --- | --- | --- |
| Real DeepSeek ship: brief, busy composer, mid-task steer, interrupt, exit, same-conversation resume, final exit | pass (live) | live-ff592853b-fm-dsh-live-e2e.log |
| Real DeepSeek scout: same lifecycle | pass (live) | live-ff592853b-fm-dsh-live-e2e.log |
| DSH primary + fresh dsh secondmate: startup, watcher, wake, turn-end recovery, interrupt, exit, resume, owner-death recovery | pass (live) | live-ff592853b-fm-dsh-primary-live-e2e.log |
| Explicit --harness omp + DeepSeek model refuses before launch; no agent, no dsh binding, meta unchanged | pass (live) | live-ff592853b-routing.log |
| omp-recorded ship relaunched with only a DeepSeek model refuses with "select --harness dsh" | pass (live) | live-ff592853b-routing.log |
| fm-dispatch-resolve: omp/pi profile with a DeepSeek model, and dsh profile with a non-DeepSeek model, refuse (exit 2) with the specific reason plus the new neutral last line | pass (live CLI) | live-ff592853b-dispatch-resolve.log |
| Routing owner: deepseek/ prefix (any case, padding) and provider deepseek -> dsh; claude* -> claude; others incl. deepseekish/ -> omp; valid dsh profile canonicalized, claude/omp profiles untouched | pass (live CLI) | live-ff592853b-routing-owner.log, live-ff592853b-routing.log |
| Portable: fm-dsh-harness, fm-dsh-spawn, fm-dsh-primary, fm-test-run (157-case control-relaunch partition), --check-coverage (21 shards) | pass (not live) | portable-ff592853b-*.log, portable-ff592853b-summary.txt |

Not re-driven: fresh scout with no --harness on a real treehouse pool (round 1 evidence live-routing-scout.log, head 8af2496db). That path allocates a real pool slot, which this round's plan forbids. Its code is byte-identical to round 1.
