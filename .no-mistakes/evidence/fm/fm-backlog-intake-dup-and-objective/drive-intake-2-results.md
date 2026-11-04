# Live re-drive results (drive-intake-2*.log), head 685bbddcf
window: 17 ok / 0 failed (Done-window overlap active + archived, older-than-50 not counted).
close: 34 ok / 3 failed. All 3 failures are driver-check errors, not product defects:
  - "row closed with the proof note" (d1) and "closed row records the proof" (m1): the proof note
    ("duplicate of k1", "moved to sm-b as dest-open") is stored on the body line under the row; the
    check grepped only the row line. The final backlog dump in the log shows both notes.
  - "kept item holds no fm-add token": the token in k1 is k1's own token (kept by ruling); d1's token
    b9a150... is absent from the copied text, as the ruling requires.
rest: 34 ok / 2 failed. Both failures are a driver design error in step 9e: archived hand-1 also
  overlaps lab.kd's title, so the filer correctly raised it. 9e re-driven alone in a clean lab
  (drive-intake-2-9e.log): two keys filed two fm-timeout- items, both O7.
Not driven: --moved-to through a real remote home over ssh (loopback ssh refused: Host key
  verification failed; a remote home needs bin/fm-remote-entrypoint.sh and its worker on the ssh
  account, outside the worktree boundary). The unreachable-real-ssh-host refusal was driven live.
