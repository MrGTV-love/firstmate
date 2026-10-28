# Watcher launch repair - focused read-only review

Commit: `c8bbf86cda4e6994329b914783f268f348e4d66e` (`no-mistakes(lint): Fix lint findings and reserve watcher summary-refresh record before launch`), parent `1e980ec8...`.
Worktree: `/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M60X7EHPFP3WC1T7VVP0W6VM`; HEAD c8bbf86; status clean.

Pinned blobs:

- `bin/fm-watch.sh` `b0ff2cfb00c3d5a1dc47bea04e8c5e1acdbf04fe`
- `bin/fm-home-summary-refresh.sh` `04889b1b206de5854615f858f59736b102b02b87`
- `bin/fm-timeout-lib.sh` `abb82f700e1c645fb8f60f99b7fec8f0ef034995`
- `tests/fm-home-summary-refresh.test.sh` `dc3e1cf730fed6d86361f45bb0abc5f4a8cc34c6`
- `tests/lib.sh` `fb95c22cd7fb87bce66f6c85763b1c0435d2cee7`

## Change

`bin/fm-watch.sh:2831-2847` now, only when `FM_TEST_PROCESS_REGISTRY` is set and `FM_TEST_PROCESS_RECORD` is absent, reserves a unique record, exports it to the child as `FM_TEST_PROCESS_RECORD`, launches the summary, and fills the record with the child PID. Reserve failure returns without launching.

With no registry, `record=` remains empty, `fm_process_fill ""` is a no-op, and the launch is unchanged. With an existing record, the watcher does not reserve a new one; the child inherits the caller's record.

`bin/fm-home-summary-refresh.sh` and `bin/fm-timeout-lib.sh` changes are comments. The other diff changes in tests are lint fixes plus the new watcher-launch case.

## Concrete regression evidence

- The before/after one-case driver is `/tmp/wl/driver.sh`.
- Old watcher: `Failed: "cleanup found no running writer"` per `/Users/charlesabrooker/.no-mistakes/logs/01M60X7EHPFP3WC1T7VVP0W6VM/lint.log:71`.
- Fixed watcher: passed cleanup per line72.
- The held-before-dirname case starts the real watcher, holds the actual summary child at its first `dirname` before self-registration, kills the watcher, removes `state`, requires the bounded wait to fail and name the writer, then releases and requires actual `home-summary.json` publication (`tests/fm-home-summary-refresh.test.sh:1574-1625`).
- It therefore exercises actual launch and drain, not merely a synthetic marker. It does not rely on the PID leader exiting: the child is held and the pre-reserved record keeps it registered.
- The full affected test was reported passing 39 checks in 215s; canonical lint is still running (`lint.log:73-79`). This is reported positive evidence, not independently rerun here, and not a full-suite result.

## Other watcher background jobs

`watcher_cleanup` (`bin/fm-watch.sh:3131-3155`) does not wait on `HOME_SUMMARY_PID` or on the other detached watcher jobs. The fix only records the home-summary child.

For THIS affected summary fixture, no concrete fixture-writing other job was found:

- `tests/lib.sh:529` sets `FM_OPEN_LOOPS_BIN=/usr/bin/true`; the affected test does not override it.
- The other detached watcher jobs (open-loops, review select, idle reap, merge prune, typesafe/lavish, procevent/reconcile) are not shown to write this fixture in the affected test env.
- If a future fixture enables a real open-loops or other writer, the existing termination/drain does not cover it; that remains a conditional gap outside this repair.

The lint log’s disclosure at lines77-79 remains accurate: the fix does not cover other watcher background jobs. I found no load-bearing counterexample in the current affected fixture, only this conditional uncertainty.

## Limits and accepted scope

- Pending-record bounded failure/root retention remains accepted; no failed-terminal state is required.
- Nonwriting watchdog exception remains accepted; numeric-prefix short-write claim remains retracted.
- 21-second bounded-report cause and CPU objective remain unresolved; the solo pass is not a fix.
- No full cleanup suite, other watcher test files, lint completion, tests, process snapshots, signals, gate calls, source edits, or independent validation runs.
- The watcher repair closes the reproduced prelaunch gap in the affected fixture without changing the no-registry default. It does not establish coverage for other watcher background writers or the unresolved timing cause.
