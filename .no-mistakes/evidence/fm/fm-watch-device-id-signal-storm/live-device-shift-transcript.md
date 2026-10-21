# Live lab: real fm-watch.sh across a genuine volume device-number shift

Setup: lab FM_HOMEs (bin/fm-lab-home.sh create) on a disposable APFS disk image
(hdiutil). Detach + re-attach of the image changes st_dev while inode and birth
stay the same — the same shape as the 2026-10-09 host crash (16777232 -> 16777233).
Each home has 26 status logs; task01-03 are 1,746,207 bytes. Every log holds
historical done:/blocked:/needs-decision lines. Watchers ran in a private lab
tmux socket with FM_POLL=2 FM_SIGNAL_GRACE=1. No FM_STATUS_IDENTITY_READER fake.

## Priming on device 16777277 (both homes, fresh logs)
- HEAD watcher: woke once after 380 s, queued 26 signal rows (one per log).
- base ff899e92a watcher: queued 52 signal rows (two per log).
- Both acked through fm-wake-drain.sh --ack-through; a home-owned resolution line
  was appended to task04 with fm_wake_status_append_self_announced, leaving the
  heartbeat marker lagging (seen=172, hb=114).
- Quiet baseline on device 16777277: both watchers stayed alive 25 s, 0 queue rows.

### Markers before remount
# before remount
labnew task01 dev=16777277 ino=27 size=1746207 seen=1746207@strong:16777277:27:1792618185.008337617 hb=1746207@strong:16777277:27:1792618185.008337617
labnew task04 dev=16777277 ino=30 size=172 seen=172@strong:16777277:30:1792618185.152622804 hb=114@strong:16777277:30:1792618185.152622804
labnew task05 dev=16777277 ino=31 size=114 seen=114@strong:16777277:31:1792618185.152749638 hb=114@strong:16777277:31:1792618185.152749638
labnew task26 dev=16777277 ino=52 size=114 seen=114@strong:16777277:52:1792618185.154308520 hb=114@strong:16777277:52:1792618185.154308520
labbase task01 dev=16777277 ino=59 size=1746207 seen=1746207@strong:16777277:59:1792618185.215246251 hb=1746207@strong:16777277:59:1792618185.215246251
labbase task04 dev=16777277 ino=62 size=172 seen=172@strong:16777277:62:1792618185.359674481 hb=114@strong:16777277:62:1792618185.359674481
labbase task05 dev=16777277 ino=63 size=114 seen=114@strong:16777277:63:1792618185.359807481 hb=114@strong:16777277:63:1792618185.359807481
labbase task26 dev=16777277 ino=84 size=114 seen=114@strong:16777277:84:1792618185.361316238 hb=114@strong:16777277:84:1792618185.361316238

## Remount 1: device 16777277 -> 16777281 (inode/birth unchanged)
### HEAD watcher (FM_HEARTBEAT=4)
- pass 1: printed only "check: rearm-resurface" (watcher-downtime notice), 0 queue rows, exited after 3 s.
- pass 2 (takeover watcher): alive 40 s, 0 queue rows, 3x "absorbed heartbeat (no captain-relevant change)".
- 0 of 52 marker files still name device 16777277; offsets unchanged; task04 heartbeat
  marker advanced 114 -> 172 without a wake (home-owned bytes stay owned).
labnew task01 dev=16777281 ino=27 size=1746207 seen=1746207@strong:16777281:27:1792618185.008337617 hb=1746207@strong:16777281:27:1792618185.008337617
labnew task02 dev=16777281 ino=28 size=1746207 seen=1746207@strong:16777281:28:1792618185.057323378 hb=1746207@strong:16777281:28:1792618185.057323378
labnew task03 dev=16777281 ino=29 size=1746207 seen=1746207@strong:16777281:29:1792618185.104415922 hb=1746207@strong:16777281:29:1792618185.104415922
labnew task04 dev=16777281 ino=30 size=172 seen=172@strong:16777281:30:1792618185.152622804 hb=172@strong:16777281:30:1792618185.152622804
labnew task05 dev=16777281 ino=31 size=114 seen=114@strong:16777281:31:1792618185.152749638 hb=114@strong:16777281:31:1792618185.152749638
labnew task26 dev=16777281 ino=52 size=114 seen=114@strong:16777281:52:1792618185.154308520 hb=114@strong:16777281:52:1792618185.154308520

### base ff899e92a watcher (same remount, same logs)
- pass 1: ran 243 s re-reading every log from byte 0, then exited with
  "signal: task01.status ... task26.status" and 52 signal rows queued
  (see base-commit-after-remount-wake-queue.tsv). This is the incident storm.

## Remount 2: device 16777281 -> 16777285, with changes made during downtime
- task05 grew by "done: appended across reboot" (114 -> 143 bytes).
- task06 was replaced by a copy (inode 32 -> 3005, same bytes).
# before second remount
task05 dev=16777281 ino=31 size=143 seen=114@strong:16777281:31:1792618185.152749638 hb=114@strong:16777281:31:1792618185.152749638
task06 dev=16777281 ino=3005 size=114 seen=114@strong:16777281:32:1792618185.152827555 hb=114@strong:16777281:32:1792618185.152827555
task07 dev=16777281 ino=33 size=114 seen=114@strong:16777281:33:1792618185.152902930 hb=114@strong:16777281:33:1792618185.152902930

HEAD watcher pass 1 output: "signal: task05.status task06.status" after 6 s.
Queue rows: exactly one signal for task05.status and one for task06.status.
Span reads logged (file start length), via a logging reader that runs the same perl read:
- task05.status 114 29   (only the 29 new bytes; old done/blocked lines not re-read)
- task06.status 0 114    (new inode -> full read, as required)
No span read of any other log (no 1.7 MB re-read).
After ack, pass 2 (FM_HEARTBEAT=4): alive 40 s, 0 queue rows, 0 span reads.
