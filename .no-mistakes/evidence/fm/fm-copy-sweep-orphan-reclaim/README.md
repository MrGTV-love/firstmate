# Live test evidence, head d36081269c6539bbbce4057afdb42c57f38acf75

Drive script: live-drive.sh. Each scenario mints a marked lab home (bin/fm-lab-home.sh env), runs the real
bin/fm-copy-sweep.sh with real lsof, ps, git, du and cp, and removes the lab in the same run.
FM_COPY_SWEEP_TREEHOUSE_ROOT points at a disposable directory, so no real pool or home is read.
The only stand-in is a python closeout driver at the real path, run by a real python at the real .venv path.
Vernant's real driver is out of scope, so its own verdicts are not proved here.
The sandboxed-failed-helper check uses one injected failing python3, named as a fault in the script.

Logs: live-<scenario>.log. Unchanged suite: m3-existing-suite.log. New suite: orphan-suite.log.
first-pass-fixture-errors/: first runs whose failures were mistakes in the drive script, not product faults
(git revert -q is invalid, bare origin default branch, a wrong expectation about .cache at the root and about
.claude in the locked route, a locked copy reaped before its phase, and a hung late-commit watcher that left no log).
They are kept so that the corrections stay visible.

live-sweep-driver.sh and live-sweep-transcript.log were already in this directory before this round. They come from an earlier
test round of this run and are not part of this round's results at d36081269c65.
