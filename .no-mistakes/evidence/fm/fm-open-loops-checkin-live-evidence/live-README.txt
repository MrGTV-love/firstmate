Live driver evidence for fm/fm-open-loops-checkin-live-evidence.
live-driver.py drives the REAL bin/fm-open-loops.sh and bin/fm-wake-drain.sh, once from a git-archive of the base commit
(0185e74c, 'before') and once from a copy of the worktree bin/ (9231320a, 'after'), against disposable homes minted by
bin/fm-lab-home.sh. Substituted edges only: the fleet snapshot's task list (no tmux fleet) and the current-state reader
(FM_CREW_STATE_BIN) used to simulate a live no-mistakes run. s3c uses a real tmux server on the lab-private socket (fm-lab).
Two of the first-run results (s4 captain-hold, s6 captain-held question) failed because of MY fixture: a hold that still
names an unresolved blocked-by ship sits in the documented 'blocked' bucket, which waits on its ships. The fixtures were
corrected to hold with no open blocker and re-run; s11 first failed on a per-task reader file overriding the global one.
Those were fixture errors, not product failures. live-*.txt are the final transcripts.
