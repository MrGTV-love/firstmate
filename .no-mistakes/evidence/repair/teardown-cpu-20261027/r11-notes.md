# Round 11 test-phase revalidation (HEAD 609f8093, no source change)
Wake-queue: consumed the r10 one-run reproduction (r10-full/: run.meta, suite.log, notes.md, temp-observation.diff).
No second full wake-queue run (one-run bound). r10: exit=0 after ordinary cleanup, 83 ok / 0 not ok, load ~12/18 CPUs,
timeout branch never fired, so no failure boundary was captured. Verdict for this concern: INCONCLUSIVE, not fixed, not waived.
r8 failure at the same HEAD (load ~58, watcher 70260 live at 40 polls) and earlier presentation failures stay unresolved.
Temp observation restored: worktree clean, no R10-TEMP lines in tests/ or bin/.
Re-driven live this round: r11-live-guard-lab.{sh,log} (disposable marked lab home, torn down rc=0),
and the targeted suites listed in r11-test-exits.txt (all exit 0, logs r11-fm-*.log).
Linux Bash 5 opted-in row path: not drivable on this Darwin Bash 3.2 host; hosted CI only.
