# Live validation, head 857198c1b (run 01M5P6CVQGQ910WB76XD4XBACG)

Model resolved at run time: deepseek/deepseek-v4-flash, via bin/fm-dsh.py preferred-model on a disposable operator home (model-source.txt). All Herdr work ran in named fm-lab-* sessions through bin/fm-herdr-lab.sh; every lab session and temp home was torn down in this run.

| Scenario | Result | Log |
| --- | --- | --- |
| NEW: live dsh secondmate; index retires its bound id; `fm-control.sh relaunch --model ' DeepSeek / <id> '` refuses before stop naming deepseek/<id>; agent alive, generation, meta, journal and conversation bytes unchanged; the same agent then answers with its secret | pass | live-role-drift-spelling.log (S-RETIRED-CONTROL) |
| NEW: same control case fails on HEAD~1 bin/fm-control.sh and passes on HEAD (portable) | pass (not live) | portable-control-retired-before-after.txt, portable-control-retired-before.log, portable-control-retired-after.log |
| Real DeepSeek ship: brief, busy composer, mid-task steer, interrupt, exit, same-conversation resume, final exit | pass | live-fm-dsh-live-e2e.log (attempt 2) |
| Real DeepSeek scout: same lifecycle | pass on attempt 2 | live-fm-dsh-live-e2e.log; attempt 1 refused the scout's first launch on a just-created pane that read 'unreadable' (live-fm-dsh-live-e2e.attempt1.log) |
| DSH primary + fresh dsh secondmate lifecycle, owner-death recovery | pass | live-fm-dsh-primary-live-e2e.log |
| Explicit --harness omp with DeepSeek model refuses before launch | pass | live-ship-retired-switch-gh.log (S-REFUSE) |
| Fresh no-harness scout, padded retired DeepSeek selector refuses before endpoint/binding/meta | pass | live-ship-retired-switch-gh.log (S-RETIRED) |
| omp-recorded ship relaunched --harness dsh --model DeepSeek/<id> runs dsh-tui, canonical meta; worker Bash ran gh-axi pr view 182, exit 0 | pass | live-ship-retired-switch-gh.log (S-SWITCH, S-GH), live-worker-gh-pr-view.txt, live-switch-ship-pane.txt |
| Role / drift / mixed-spelling relaunch on a live secondmate (resume, refuse-before-stop, keep effort) | pass | live-role-drift-spelling.log |
| Credential copies scrubbed from every task home | pass (0 left) | live-credential-scrub-count.txt |
| Portable targeted suites + rebase shard guard | pass (not live) | portable-summary.txt, portable-*.log |
