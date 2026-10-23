# Live device-remount validation (real APFS disk image, real stat, real bin/fm-watch.sh)

Setup: one 300 MB APFS disk image mounted at a private mount point. Two lab homes on it
(bin/fm-lab-home.sh create): lab-head runs HEAD ef65ce221, lab-base runs base 4d1dc7d5e.
38 status logs per lab, 6 of them ~1.6 MB, each ending with done:/blocked:/needs-decision:.
A "remount" detaches the image, attaches a fresh dummy image to hold the freed number,
and reattaches: the device number changes (e.g. 16777277 -> 16777281) while inode and
birth time stay the same - the 2026-10-09 failure shape.

| Round | What changed | lab-head (HEAD) signal wakes | lab-base (base) signal wakes |
|---|---|---|---|
| Prime (same device) | first sighting of 38 logs | 38 rows (one per log) | 76 rows (each log twice) |
| R1 | device only | 0 over 4 watcher passes; 38/38 seen and 38/38 heartbeat markers name the new device | 33 rows over 2 passes |
| R2a | device + 4 logs grew by routine working: lines (crew working, heartbeat every 3 s) | 4 rows on pass 1 (one per grown log), then quiet; 9 later repeats (6 with a confirmed device change): 0 rows, all absorbed | 79 rows over 6 passes |
| R2b | device + 2 logs grew by a new done: line | 2 rows (task08, task12), once; then quiet | 97 rows over 6 passes |
| R3 | device + task20 replaced (new inode) | 1 row (task20) | not run |
| Daemon classify_signal | device only, then growth | self, self; growth escalates only the new line | escalate, escalate (old line); growth escalates old + new |

The drain's "wake annotation" rows after R2b list task08/task12 history as unread: that is
the declined/deferred fm-presentation-cursor-device-migration follow-up, not this change.
