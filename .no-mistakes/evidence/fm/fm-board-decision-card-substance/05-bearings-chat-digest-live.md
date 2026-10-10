# Lab primary: FM_HOME=<disposable lab> claude -p "/bearings" (run from the gate worktree on the fm-lab tmux socket)
# Seeded state: one captain hold 'lab-mac-mini-plan' created with bin/fm-captain-hold.sh hold

Captain, here is the fleet digest from a fresh snapshot.

**Captain's Call**

Decision: what the idle Mac mini does now (firstmate).
- **What and why now:** The Mac Studio now runs the fleet, so the Mac mini has no job. The hold opened on 2026-10-10.
- **Options:**
  1. **Keep it as a cold spare.** It stays off and ready. If the Mac Studio fails, you can move the fleet to it.
  2. **Run self-hosted CI runners on it.** It runs build and test jobs for your repos. You must keep it patched and secure.
  3. **Sell it.** You get cash back. After that, you have no backup machine. You cannot undo this.
- **Recommendation: keep it as a cold spare.** It is the safe choice. You can still pick either of the other options later. Selling it removes that choice. CI runners add upkeep and a security risk.
- **Facts for:**
  - The fleet runs on one machine, the Mac Studio. A spare removes that single point of failure. (Source: the hold record.)
  - The three options in the hold record include only one that you cannot undo: selling it. (Source: the hold record.)
- **Facts against:**
  - An idle spare does no work and returns no money. (Source: the hold record says the mini is "idle".)
  - The record has no data on CI load, CI cost, or resale value. If CI minutes cost you money now, runners may be the better choice. That data is not in the record.

Contributions: nothing needs you (0 of 0 checked, coverage complete).

**Recently Landed**

No recent completions are in the current baseline.

**Underway**

Nothing is underway.

**Charted Next**

Nothing is queued.
