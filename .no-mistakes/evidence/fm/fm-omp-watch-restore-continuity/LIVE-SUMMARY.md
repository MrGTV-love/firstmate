# Live omp lab: watcher continuity while a wake delivery is pending

Product: installed omp 18.11.2 (TUI, private tmux socket `fm-lab`), real `bin/fm-watch-arm.sh` / `bin/fm-watch.sh`,
lab FM_HOME minted by `bin/fm-lab-home.sh env` (torn down after each run), fresh empty HOME, isolated
PI_CODING_AGENT_DIR with a scripted local model (`lab-driver-model.py`, 20 s per reply, no tokens, no login).
OMP_API_BILLING=unset. Actionable closes are real watcher closes on `state/tN.status` = `done: ...` signals.
Ledger = the arm's own `state/.watch-cycle-exits.log` (the field the R-home symptom is measured on).

"pending" runs add a LAB-ONLY wrapper extension (`lab-driver-mkcopy.sh`) that forwards every call to the real
extension, but makes `sendUserMessage` for a watcher wake return a promise that settles 30 s later
(the intent's hypothesis: the API promise settles only after the model turn). The real call to omp still happens at once.
The memory-health check was deferred in pending runs (QUIET_MEM=1) so lab-only memory alarms do not close every arm.

## Discriminating result (live-pending-base vs live-pending-fixed)

Base extension 99f53265 (unfixed):
- arm 50091 closed 18:23:15 (actionable-signal). First wake send held 18:23:14 -> 18:23:44.
- Next arm 96525 started only at 18:23:44 = the moment the held promise settled. 29 s with no watcher.

Fixed extension 570d87d8:
- First wake send held 18:24:46 -> 18:25:16 (`wake-delivery-start`..`wake-delivery-settled` predecessor=66591 spans it).
- During that hold, closes of arms 73304, 79755, 86738 each got `actionable-close` + `restore-start` and a successor
  started within ~1 s (`successor=started:` for each). No repair call: no model turn ran `fm_watch_arm_omp`.

## Control runs (no pending wrapper; real omp settles sendUserMessage in < 1 s)
- live-fixed (worktree), live-fixedcopy, live-base: most closes `successor=started`. Real omp 18.11.2 did not hold
  the send promise across the 20 s model turn (wake-delivery-start -> settled 0.1-0.8 s).

## Pre-existing race seen in fixed AND base (not introduced by this change)
A successor that closes within ~1-3 s of starting (before readiness / handling confirmation) can leave its ledger row
`successor=none`, although a later arm keeps supervision running:
- live-base: arm 16392 successor=none.  live-fixed: arm 12920 successor=none (`restore-skipped reason=restoring`, then
  `restore-unchanged reason=owned-child`).  live-pending-fixed: arm 95884 has two ledger rows (actionable-signal
  successor=none, and arm-interrupted exit 143 successor=started:3607) after
  "handling delivery confirmation was rejected (status=3 ...)".

## Session replacement attempt (live-pending-replace-fixed)
`/new` typed into the omp TUI while the first wake send was held. omp printed "New session started", but the extension
logged no session_shutdown/session_start (generation=1 throughout). So omp 18.11.2 `/new` does not reach the
cross-generation claim path; that path (foreign-late / foreign-never) is covered only by the fixture rows.
Continuity still held: 5 of 5 closes `successor=started`, and the queued wake reached the new session once.
