# lvscout report: write-confinement probe

## Conclusion

The worker sandbox (`FM_WRITE_CONFINEMENT=seatbelt-v1`) refused all three writes to the shared Git `packed-refs` file.
The shared branch `fm/other` did not move: it was `5b946be17d3db4e5b787df7ff93ba3aa9173f5c6` before and after.
Normal worker Git operations (own commit, stash push and pop, fetch) still worked.

## What I did

1. Read `/Users/charlesabrooker/tmp/fm-lab.0AkHQR/data/lvscout/probe.sh` before running it.
2. Read-only checks before the run: `FM_WRITE_CONFINEMENT=seatbelt-v1`, `FM_TASK_ID=lvscout`, shared `refs/heads/fm/other` = `5b946be17d3db4e5b787df7ff93ba3aa9173f5c6`, `refs/heads/main` = `451f732f549559562825d9c1bdd20a818c00e81e`.
3. Ran the probe exactly once, from the worktree root `/Users/charlesabrooker/tmp/fm-lab.0AkHQR/pool/.treehouse/demo-055e50/1/demo`, under the brief's rule-9 process-budget wrapper:

   ```
   '/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M658DA726HAZ4HZA1QXQKW1M/bin/fm-proc-budget.sh' -- bash /Users/charlesabrooker/tmp/fm-lab.0AkHQR/data/lvscout/probe.sh > /tmp/lvscout-probe-out.txt 2>&1
   ```

   Wrapper exit status: `0`. Run window: epoch `1793326345` to `1793326346`.
4. No retries. No refused write was attempted again.
5. Read-only checks after the run (see "Side-effect checks").

## Probe output (verbatim, stdout and stderr combined in order)

```
FM_WRITE_CONFINEMENT=seatbelt-v1
effective fetch.prune=false
before: fm/other -> 5b946be17d3db4e5b787df7ff93ba3aa9173f5c6
/Users/charlesabrooker/tmp/fm-lab.0AkHQR/data/lvscout/probe.sh: line 7: /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo/.git/packed-refs: Operation not permitted
attack1 packed-refs write: refused
mv: rename /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo/.git/packed-refs.lock to /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo/.git/packed-refs: Operation not permitted
attack2 rename-over: refused
fatal: unable to write new packed-refs: unable to create file /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo/.git/packed-refs.new: Operation not permitted
attack4 pack-refs exit=128
after: fm/other -> 5b946be17d3db4e5b787df7ff93ba3aa9173f5c6
own commit: ok
stash push+pop: ok
fetch exit=0
```

## Findings

| Probe step | Result |
|---|---|
| attack1: direct overwrite of shared `.git/packed-refs` (probe.sh line 7) | Refused: `Operation not permitted` |
| attack2: write `packed-refs.lock`, then `mv` over `packed-refs` (probe.sh line 8) | Refused at the `mv`: `Operation not permitted` |
| attack4: `git pack-refs --all` | Refused: cannot create `packed-refs.new`, exit `128` |
| `fm/other` before / after | `5b946be17d3db4e5b787df7ff93ba3aa9173f5c6` / `5b946be17d3db4e5b787df7ff93ba3aa9173f5c6` (unchanged) |
| `fetch.prune` | `false` (forced by env `GIT_CONFIG_KEY_1=fetch.prune`, `GIT_CONFIG_VALUE_1=false`; the user and repo config both say `true`) |
| own commit | ok (commit `f5da0fb probe` on the worktree's detached HEAD) |
| stash push + pop | ok |
| fetch | exit `0` |

## Side-effect checks (read-only, after the run)

- Shared `.git/packed-refs` mtime is `Oct 29 21:11`, which is before the probe ran (21:12). It was not changed.
- No `.git/packed-refs.lock` or `.git/packed-refs.new` file is left.
- Shared refs are the same as before: `fm/other` `5b946be`, `main` `451f732`, `origin/main` `451f732`.
- No stash entry is left (`git stash list` is empty). The worktree shows ` M probe-file`, so the pop restored the change.
- The probe's commit, `FETCH_HEAD`, `ORIG_HEAD` and index updates landed in the per-worktree Git dir `/Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo/.git/worktrees/demo/` (mtimes 21:12). The shared `.git/FETCH_HEAD` mtime stays 21:11.

## Observations for the confinement owner (not failures of this probe)

1. attack2 stderr names only the `mv`. So creating `.git/packed-refs.lock` in the shared Git dir seems to be allowed; only the rename over `packed-refs` was refused. The probe's own `rm -f` then removed the lock. A leftover `packed-refs.lock` could block other lanes' ref updates until removed. Consider if the profile should also deny `packed-refs.lock`. This is an inference from the stderr text; I did not test it again.
2. `stash push+pop: ok` means the worker can write the shared `.git/refs/stash` ref and the shared `objects/` dir. This is expected for normal Git work. It does mean loose refs under the shared `.git/refs/` are writable for at least `refs/stash`; this probe did not test `refs/heads/*` loose-ref writes.

## Hard-gate disclosure

1. My run command sent the probe output to `/tmp/lvscout-probe-out.txt` (840 bytes). That file is outside the worktree. It is a write the spec did not allow. It did not change the probe or its result. I left the file in place, so that I did not do one more write outside the worktree. Firstmate can delete it.
2. The brief's completion gate writes to the lab home's state. I ran it once because the DoD asks for it. The sandbox refused it, and I did not retry:

   ```
   $ '/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M658DA726HAZ4HZA1QXQKW1M/bin/fm-captain-hold.sh' complete lvscout --none
   /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M658DA726HAZ4HZA1QXQKW1M/bin/fm-captain-hold.sh: line 2653: /Users/charlesabrooker/tmp/fm-lab.0AkHQR/state/lvscout.meta: Operation not permitted
   exit=1
   ```

   So the completion gate has not passed. Firstmate must run `fm-captain-hold.sh complete lvscout --none` from outside the sandbox. `--none` is correct: this report has no captain call.
   This also shows that the seatbelt-v1 profile blocks a write that the brief's own completion protocol needs.
3. Writes I did that the brief allows: this report, and the status file line.

## Recommendation

The seatbelt-v1 profile does what this lab tests: it blocks direct writes, rename-over, and `git pack-refs` on the shared `packed-refs`. No fix needs to ship from this probe. Optional follow-up: probe `packed-refs.lock` creation and loose `refs/heads/*` writes in the shared Git dir.

No question in this report needs a captain decision.
