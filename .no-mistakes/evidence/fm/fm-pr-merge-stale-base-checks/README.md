# fm-pr-merge stale-base live drive (run 01M64X4A5HY6PXPK4BKNFWZ71Y)

drive.sh runs the real bin/fm-pr-merge.sh against a disposable local forge:
a real bare git repo where #287 lands first (main T0 -> T1), and #188 was built on T0.
A whole-tree check ("at most 2 shard files") passes on each PR head alone and on T1,
and fails on T1 + #188 (3/2), like the portable serial shard 1 overflow.
A gh stand-in answers the compare API from that real git history and does the
real squash merge into the forge, so the landed main can be checked afterwards.
Other GitHub reads (PR view, rules, required checks) come from the repo's own
test forge stand-in (tests/fm-pr-merge-helpers.sh). No real GitHub PR is touched.

| file | script | result |
|---|---|---|
| drive-base-stale-head.txt | base e27bbad9b | merges stale #188; main whole-tree check FAILURE (3/2) |
| drive-head-stale-head.txt | head 45d492750 | refuses, names tip T1 and built-on T0; no gh pr merge; main stays green |
| drive-head-fresh-head.txt | head | rebased head contains tip: merges with no extra step; main green |
| drive-head-tip-moves.txt | head | main moves after verify: refused before gh pr merge |
| drive-head-stale-head-waivers.txt | head | --allow-red ci, --allow-missing ci, --admin: all still refused |
| drive-head-compare-5xx.txt | head | compare 502: retried 5x, refused as unreadable, no deny event |
| drive-head-queue.txt | head | --auto into merge queue with required ci: queued, no compare read |
| drive-head-queue-no-required.txt | head | queue with no required checks: containment applies, refused |
| drive-head-queue-rules-5xx-once.txt | head | one 503 on queue rules read: retried, queued, not "update the branch" |
