# Serial shard packing budget: unmet constraint

Superseded: Main decision 020 authorized the serial hint refresh in `../hint-refresh/`, where `--check-coverage` passes. This file records the state before that refresh.

Branch: fm/fm-control-reattribute-endpoints-after-reboot. Review fix round on top of 3a8869ff3. Date: 2026-10-24.

## Result

`bin/fm-test-run.sh --check-coverage` still refuses. See `check-coverage.txt`.
No rebalance or split across the existing 20 serial shards can pass. No honest hint makes it pass either.

## Why: arithmetic

- Serial lane: 304 scripts. The hint sum is 24016125 ms (`totals.txt`).
- The 20 shards together allow 20 x 1200000 = 24000000 ms.
- The sum is 16125 ms over that total, so the average shard is 1200806 ms.
- Some shard always holds at least the average. So every packing has a shard over 1200000 ms.
- Splitting a file does not change the sum. A split only moves work between shards.
- Today all 20 shards pack between 1200626 and 1200951 ms (`per-shard-packing.tsv`). The members of each shard are in `per-shard-members.tsv`.

## Base and adoption share

- Base main (cced61811), before the adopt tests: the hint sum was 23959723 ms. The per-shard average was 1197986 ms. The modeled largest shard was 1198148 ms (docs/fm-test-portable-shards.md).
- So main already sat at about 99.8 percent of capacity.
- The backends hint is now 537402 ms. Before the adopt tests it was 481058 ms (CI measured, run 40063531528). The adopt tests add 56344 ms.
- To pass at zero margin, the adopt tests can add at most 40277 ms. That is 24000000 - 23959723.

## How the new hint was derived (local estimates, not CI)

- Earlier local macOS run of the whole group: 639 s. The adoption case alone was 63 s in that run.
- This round, local macOS run of the adoption case alone: `adoption-case-timed-run.txt`. The run took 58.5 s in total, less 4.1 s of file startup (measured with a refused selector), so 54.4 s. The new reused-PID test took 3.6 s of that (50.4 s to 54.0 s).
- Scale: 63 s x 54.4 / 50.8 = 67.46 s.
- Hint: 481058 x (576 + 67.46) / 576 = 537402 ms.

## Main CI shows the hints are not high

Backends group without the adopt tests, measured on green main CI (`fm-test-timing-aggregate`):

| Run | Head | Backends ms |
|---|---|---|
| 40121540044 | cced61811 | 399970 |
| 40121241146 | f6b1ab9c9 | 514105 |
| 40106598762 | 30f233bc9 | 504740 |
| 40105819475 | cf931ca54 | 524782 |
| 40105677523 | e321ebd65 | 516318 |

The slowest is 524782 ms, which is above the 481058 ms hint. A refresh from CI would raise the sum. It would not lower it.

## Options that need a decision (all outside the given constraints)

1. Cut adoption test work to at most about 40 s of CI time, with less for any margin. That means removing test coverage.
2. Move the adopt cases to a proven-isolated portable-parallel file. The parallel lane modeled 941660 ms against its 1200000 ms budget. It needs a new isolation proof run.
3. Add shard 21 or raise the 1200000 ms target. The user forbade both.
