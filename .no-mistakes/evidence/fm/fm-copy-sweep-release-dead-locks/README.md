# Live validation: fm-copy-sweep releases dead-launcher Vernant-locked copies (target 90118e041)

Lab (disposable, removed after the run): `LAB=$(mktemp -d ~/tmp/fm-lab.XXXXXX)`; `bin/fm-lab-home.sh create $LAB/home`.
- `$LAB/origin.git`: `git clone --bare --shared` of the real Vernant repo (read-only alternates; nothing pushed to the real repo).
- `$LAB/th/vpool/1/vernant`: pool slot clone of that origin; `.venv` symlinked to an existing Vernant slot venv; empty `.env`.
- Real Vernant closeout driver: `$SLOT/scripts/git-stability/closeout_pr.py` (no stub).
- Copies under `$SLOT/.claude/worktrees/`, each locked `vernant-session-active owner=launcher:<pid> launcher=<pid>`:
  landed-a/b/c, landed-ignored (only __pycache__/.pytest_cache), notlanded (empty commit pushed, same tree as main),
  unpushed (local commit), live-launcher (lock names a running `sleep`), later landed-preserve (unique ignored
  .afkx/raw-logs/channel-outbox.jsonl) and refused (real README change pushed to a branch, never merged).
- Sweep command: `FM_HOME=$LAB/home FM_COPY_SWEEP_TREEHOUSE_ROOT=$LAB/th bin/fm-copy-sweep.sh [--apply]`.

Files:
- run0-report.txt, run0-before/after.txt: report mode classifies, calls no driver, writes nothing.
- run1-apply-limit2.txt: FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=2 -> 2 REMOVED, 3 DEFERRED, live and unpushed HELD.
- run2-apply-default-cap.txt: deferred copies released next run; real driver refusals recorded verbatim (HELD-LOCKED).
- run3-apply-after-launcher-died.txt, run3-git-calls.log: after the launcher stops, the copy is released; only the
  driver (python) ran `worktree unlock`/`worktree remove`; the sweep (bash) ran no unlock, lock, remove or force.
- final-copy-sweep.log: append-only removal log with kib and proof per removal.
- cap-tests.txt: four focused stub-driver cap regression tests (partial release, refusal, enumeration failure).
