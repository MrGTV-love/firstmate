# Live results: Claude Stop auto-arm wait (`FM_CLAUDE_AUTOARM_SYNC_WAIT_MS`)

Target `fb3d1bd0` (default 12000 ms). Base `b40f9872` (default 800 ms).

## Method

- Each run starts a real Claude Code 2.1.296 session (`claude -p`, normal machine login).
- The session runs in a plain checkout of one commit, in a temp directory.
- The session uses the real tracked `.claude/settings.json` Stop hooks: the guard and the auto-arm.
- `FM_HOME` is a marked disposable lab home made by `bin/fm-lab-home.sh create`.
- The lab home has one task in flight and no watcher.
- To make the claim late, the driver holds the real `state/.wake-queue.lock` with the product lock helpers. A busy home does the same.
- The driver only observes: the process list, the lab state files, and the Claude stream-json transcript.
- Host load during the runs: 1-minute load average 34 to 95 on 18 cores. The incident load was 62.
- Driver: `live-driver.py`. Per run: `<label>.timeline.jsonl` and `<label>.claude-extract.jsonl`.

## Results

| Run | Code | Lock hold | Claim after guard start | Guard run (wall) | Blocks seen by Claude | End state |
| --- | --- | --- | --- | --- | --- | --- |
| s0 | target, 12000 ms | none | 0.36 s | 0.54 s | 0 | watcher healthy |
| s1 | base, 800 ms | until guard exit | 3.04 s | 2.18 s | 1 (`TURN WOULD END BLIND`, `did not claim this home either`) | claim landed after the block, watcher healthy |
| s2 | target, 12000 ms | 3.0 s | 4.00 s | 4.21 s | 0 | no budget file, watcher healthy |
| s3 | target, 12000 ms | 8.5 s | 8.95 s | 9.18 s | 0 | no budget file, watcher healthy |
| s4 | target, 12000 ms | past the 10 s claim bound | no claim on Stop 1 | 16.72 s | 1 | Stop 2 claimed and was allowed, watcher healthy |
| s5a | target, env `800` | until guard exit | 2.64 s | 1.77 s | 1 | claim landed after the block, watcher healthy |
| s5b | target, env `12s` (not a number) | 3.0 s | 3.49 s | 3.68 s | 0 | no budget file, watcher healthy |
| s6 | target, 12000 ms | until teardown (auto-arm can never claim) | never | 9 runs, 16.6 s to 17.2 s each, 152.5 s in total | 9 | Claude ended the turn with its own cap |

## What the runs show

1. s1 reproduces the 2026-10-10 incident on the old code. The guard gave up at 2.2 s. The claim landed at 3.0 s. A watcher came up.
2. s2 uses the same delay on the new code. The guard waited for the claim. Claude saw no block.
3. s3 puts the claim at 8.9 s, near the 10 s claim bound. The guard still waited. Claude saw no block.
4. s4 shows the guard still blocks when no claim comes. The 12 s wait took 16.7 s of wall time, and Claude still delivered the block.
5. s5a shows the operator can still set the wait with the variable.
6. s5b shows a bad value falls back to 12000 ms, not to 800 ms.
7. s6 shows each re-block waits the full wait, and the session still ends.

## One difference from the docs

`docs/turnend-guard.md` says the re-blocks continue to an 8-block override, about 96 seconds of wait.
In s6, Claude Code 2.1.296 ran the guard 9 times before its override.
Its message was: `A hook blocked the turn from ending 9 consecutive times - overriding and ending turn`.
That is 9 waits: 108 seconds nominal, 152.5 seconds of wall time at this load.

## Notes

- The last `INTERRUPTED by TERM` line in each extract is from the driver teardown. The driver stops the session, and the auto-arm reports the signal.
- The guard is inert when it runs from the gate worktree, because a linked worktree is not a primary checkout (exit 0 at once with a task in flight). So each run uses a plain clone in a temp directory.
- All temp directories and processes were removed after each run.
- `guard-test-file.log`: `bash tests/fm-turnend-guard.test.sh` passed, with `default wait covers a claim 2.5s after the wait starts`.
