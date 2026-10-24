# Live validation, head 869265876 (model resolved at run time: deepseek/deepseek-v4-flash, via bin/fm-dsh.py preferred-model on a disposable operator home seeded from a recorded live binding)

| Scenario | Result | Log |
| --- | --- | --- |
| Real DeepSeek ship: brief, busy composer, mid-task steer, interrupt, exit, same-conversation resume, final exit (named Herdr lab) | pass | live-fm-dsh-live-e2e.log |
| Real DeepSeek scout: same lifecycle | pass | live-fm-dsh-live-e2e.log |
| DSH primary: native startup, one watcher, wake, passive turn-end recovery, interrupt/exit/resume, forced owner death; fresh dsh secondmate spawn and same-conversation relaunch | pass | live-fm-dsh-primary-live-e2e.log |
| Explicit --harness omp with a DeepSeek model refuses before launch, meta unchanged, no binding | pass | live-ship-retired-switch-gh.log (S-REFUSE) |
| Fresh no-harness scout spawn, padded mixed-case selector of a retired DeepSeek id: rerouted to dsh, refused naming canonical id, no Herdr workspace, meta or binding | pass | live-ship-retired-switch-gh.log (S-RETIRED) |
| Retired-spelling regression fails on HEAD~1 fm-spawn.sh (launched) and passes on HEAD | pass | retired-regression-before-after.txt, retired-regression-before-fix.log, retired-regression-after-fix.log |
| omp-recorded ship relaunched --harness dsh --model DeepSeek/<id>: runs dsh-tui, meta records canonical model; worker's own Bash ran gh-axi pr view 182 exit 0 via linked operator CLI state; .dsh/.dsh-tui private | pass | live-ship-retired-switch-gh.log (S-SWITCH, S-GH), live-worker-gh-pr-view.txt |
| Mixed-spelling secondmate spawn records canonical model | pass | live-role-drift-spelling.log (S-SPELLING-META) |
| Config role resolving to bound model: plain relaunch resumes same generation and conversation | pass | live-role-drift-spelling.log (S-ROLE) |
| Config model drift and effort drift refuse before stop; agent alive, log bytes, generation, meta, journal unchanged | pass | live-role-drift-spelling.log (S-DRIFT-MODEL, S-DRIFT-EFFORT) |
| Explicit --model role:<r> naming bound model keeps recorded effort: control and direct spawn | pass | live-role-drift-spelling.log (S-EXPLICIT-CONTROL, S-EXPLICIT-SPAWN) |
| Mixed-spelling config / control --model / direct spawn --model keep effort and conversation | pass | live-role-drift-spelling.log (S-SPELLING-CONFIG/CONTROL/SPAWN) |
| Live guards scrub DSH credential copies from this run's task homes | pass | live-credential-scrub-count.txt, logs' scrub lines |
| Portable regression (fm-dsh-spawn 18 ok, fm-dsh-harness 6, fm-dsh-primary 1, fm-api-key-guard-lib 7, fm-model-picker-shadow 31, fm-control-relaunch 207; 0 not ok) | pass (not live) | head869-portable-*.log, live-summary.txt |

Note: live-ship-retired-reroute-gh.log is a first driver attempt whose premise was wrong (a direct relaunch keeps the recorded omp harness, so a DeepSeek model refuses, as docs/configuration.md documents). The driver was corrected and re-run as live-ship-retired-switch-gh.log.
Note: live-role-drift-spelling.log ends cleanup_exit=1 only because the driver's own watcher-stop cleanup passed FM_ROOT_OVERRIDE=<home>, which the gate lab check refuses; every scenario line passed, 0 credential copies remained, and no watcher process was left.
