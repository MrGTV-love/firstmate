# Live device-remount validation, HEAD 4efe85770 vs base 1f843933b
Lab: scratch 200 MB APFS disk image (hdiutil), two marked lab homes (fm-lab-home.sh create), real bin/fm-watch.sh and fm-wake-drain.sh, 14 status logs per lab
(head task01 1.05 MB, task02 1.6 MB). FM_WATCHER_STALE_GRACE=6 -> stall bound 18 s. Every script ran under bin/fm-proc-budget.sh. Device changed by detach/re-attach.

| Scenario | HEAD | base | Evidence |
|---|---|---|---|
| R0 prime: first sighting | 14 signal rows, 1 per file; quiet after ack; big reads 16 s + 36 s; beacon max 4 s during reads | 28 rows (2 per file) | live/r0.out |
| R1 device-only remount 16777239 -> 16777277 | 0 signals on 2 passes; 14/14 seen + hb markers moved to new device, offsets kept | 28 rows | live/r1.out |
| R2 two logs grew, then remount | task03 + task04 signalled once; others quiet; drain shows the new lines | 28 rows | live/r2.out |
| R3 replaced inode (task05), birth changed + remount (task06), 1.05 MB replaced + remount (task01) | each signals once; task01 read in full (1056022 @ new inode); beacon max 3 s; rival arm refused 5/5 | 28 rows; beacon stale 12 s; rival saw stale | live/r3.out |
| R4 eight logs changed, task11 again during grace | 8 rows, newest task11 state committed and drained | 16 rows | live/r4.out |
| R6 SIGSTOP on span capture | stopped 18.9 s after no progress; endpoint not committed; next change read 27 s (> 18 s bound) and committed | n/a | live/r6.out |
