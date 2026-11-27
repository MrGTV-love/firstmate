# Live by-path teardown evidence (run 01M8EXWJS2BG0SEBJEWKN9J4CX)

Every transcript here is the real `bin/fm-teardown.sh --copy` at the target commit,
run as a process against a marked disposable lab home (`bin/fm-lab-home.sh env`),
with real git repositories (bare origin, project clone under `projects/`, nested
worktrees at `<clone>/.claude/worktrees/<name>`). Only stand-ins: logging shims for
treehouse / no-mistakes / gh / gh-axi (counted; 0 calls in every run), a git shim that
counts `worktree remove` then runs real git, and fault-injection shims named per case
(ps exiting 126, a slow git for the race, a git that plants a repo mid-run).
Each lab was torn down with the printed teardown line at the end of its script.

- drive-by-path.sh -> live-by-path-transcript.txt: base red (d25e907), landed removal,
  rerun, --force/--drop-file/--legacy-record/relative refusals, unlanded refusal,
  bundle route (refuse -> printed hold command -> removed, bundle restorable),
  dirty/untracked, process cwd (not signalled), live record, not-a-registered-worktree,
  nested repos, refused-ps launcher lock, two simultaneous runs.
  NOTE: S9/S10 in this file used a .claude that was *untracked*, not ignored (my
  .gitignore write failed). S10 therefore shows git's own non-forced removal refusing
  untracked .claude content (copy kept). Ignored-.claude cases are in transcript-2.
- drive-by-path-2.sh -> live-by-path-transcript-2.txt: ignored .claude nested clone and
  bare repo refused; .claude + .opencode preserved whole then removed; unique ignored
  file refused; exception refusal names its own reason (harm planted mid-run).
  NOTE: cases C/C2 in this file are INVALID fixtures (the tracked "bare repo" had no
  objects/ or refs/ files, so it was not a repository; the update-ref went to the
  copy's own repo). Superseded by transcript-3.
- drive-by-path-3.sh -> live-by-path-transcript-3.txt: real tracked bare fixture with
  objects and refs: unmodified -> removed; untracked ref -> refused; ignored ref -> refused.
- drive-by-path-4.sh -> live-by-path-transcript-4.txt: preserve cannot publish -> copy
  kept, then removed once writable; unreadable registration list -> "could not be read";
  gone-but-registered -> names `git worktree prune`; gone copy with no audit line refused.
  (Its R2 case with projects/ mode 000 was refused by the gate lab check itself, rc 3;
  redone in transcript-5.)
- drive-by-path-5.sh -> live-by-path-transcript-5.txt: gone copy with an audit line but
  projects/ not listable -> refused, not reported done; exits 0 once readable.
- by-path-tests.log / held-close-tests.log: targeted existing tests (every
  test_by_path_* case in tests/fm-teardown.test.sh and the three held-close
  other-repository cases in tests/fm-teardown-cleanup.test.sh).
- drive-by-path-6.sh -> live-by-path-transcript-6.txt: ordinary `<id>` teardown at target
  still refuses a missing record; pool-slot shape: landed copy removed (slot kept), live
  claim refused, unreadable claim refused, stale claim passes (claim kept), claim naming the
  run's own --record-id live in another local home refused then passes once not live;
  open-file holder refused and not signalled. (Its PT case failed to file the hold row;
  redone in transcript-7.)
- drive-by-path-7.sh -> live-by-path-transcript-7.txt: an open captain row that names the
  bundle and only the HEAD tip (not every recorded tip) does not count; refused.
