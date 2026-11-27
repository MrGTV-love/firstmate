# Live validation: fm-restart-unreadable-launch-settings (head 48b739d06, base d25e907c1)

Lab: a marked lab FM_HOME (bin/fm-lab-home.sh env) and a guarded Herdr session fm-lab-rattr-* (bin/fm-herdr-lab.sh).
A PATH shim routes every herdr call through `fm-herdr-lab.sh run`. Both labs were torn down, and the tripwire passed.
Recipient: driver/fake-claude.c is a STAND-IN process named `claude`, not Claude. Its process group has one process.
It puts its tty in raw mode and logs every byte it gets to a key log. Two rows use the real `claude` binary,
which sat at its folder-trust screen with no input sent.
Record: harness=claude, launch_proof=env-v1, spawn_gen=g-lab-1, kind=secondmate.
"state_changed" hashes both state dirs, except guard-events.jsonl (the gate's audit log) and the sweep's cursor/notice.
For the restart, the key log does not tell the cases apart: the stand-in logged 0 bytes on every side.
The restart evidence is the records: inbox and pending-reply records exist, or they do not.

| file | what it shows |
|---|---|
| row-unpinned-head-rerun.txt | A readable env with no pin, settled alive. Every consumer names "unpinned native restore" (8 hits, 0 "unreadable"). 0 bytes were sent, no protected record changed, and the meta sha did not change. |
| row-unreadable-head.txt, rows-unreadable-and-suppression-base-vs-head.txt | A pid is attributed and its env has no PATH or HOME. Head says "live launch settings are unreadable" with its own next action. Base restart NUDGED it and wrote inbox and pending-reply records. Head restart left it unreached and wrote none. |
| rows-unreadable-and-suppression-base-vs-head.txt | Sweep `recover --one` x2 then `recover`: the line count, cursor and suppression are the same on base and head. Only the notice label changes (launch-unreadable becomes unmanaged). |
| row-elsewhere-head.txt | A pin for another generation gives the pinned-elsewhere cause everywhere, with 0 bytes sent. |
| row-contested-head.txt | A matching pin plus a rival record on the same home gives the contested cause, with 0 bytes sent. After the rival is removed, the verdict is managed. |
| row-restart-pinned-control-head.txt | A managed lane: the restart passes attribution and writes inbox and pending-reply records (positive control). |
| row-legacy-shell-head.txt, rows-legacy-unreadable-base-vs-head.txt | Legacy record: interrupt delivers ESC (1b) on base and head. Shell-only pane: exit gives already-stopped. |
| row-real-claude-pinned-head.txt | The real claude binary with a matching pin reads managed. |
| row-real-claude-unpinned-head.txt | The real claude binary without a pin: interrupt, restart and sweep refuse with the true cause, and the trust screen did not change. |
| superseded/ | First-pass files with an older hash. In superseded/rows-base.txt, the b-legacy and b-unreadable rows hit a settle-time race, so they are not cited. The b-unpinned row there is cited: its consumers saw a live agent. Base sweep said "live launch settings are unreadable", and base restart NUDGED the unpinned lane and wrote inbox and pending-reply records. The clean base sweep text for an unpinned agent is also in rows-unreadable-and-suppression-base-vs-head.txt (BASE one1). |
| omp-reboot-live-e2e.txt | The unmodified opt-in omp live test FAILS at the relaunch row on head ("inspection or refusal created lifecycle state"). |
| omp-reboot-live-e2e-debug-BASE.txt | A copy of the base test fails the same way at the same row, with the same new omp extension marker files. Cause not established. |
| omp-reboot-live-e2e-reduced-HEAD.txt (+ omp-e2e-copy-reduced.diff) | A MODIFIED copy that ignores those files passes on head, including the new omp wording. |
| fake-herdr-targeted-cases.txt | Non-live support: a lane stopped by hand relaunches and reads managed; the host attribution verb; the wrapper (d1) shape. |
