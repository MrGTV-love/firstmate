# Round 2 live validation at head 597680ef9 (base d25e907c1)

Only change since round 1: `bin/fm-dispatch-capacity-lib.sh` runs `omp usage ... --no-extensions`.

| file | what it shows |
|---|---|
| omp-reboot-live-e2e-HEAD-r2.txt | The UNMODIFIED opt-in test `FM_OMP_REBOOT_LIVE=1 tests/fm-omp-reboot-live-e2e.test.sh` now PASSES at head (rc=0). Round 1 failed at the relaunch row on stray omp extension markers. The guarded lab was torn down. |
| rows-r2-head-597680ef9.txt | `driver/run-r2.sh` in one marked lab home plus one fm-lab-rattr-* Herdr session, at head. r1: an unpinned env is readable (PATH and HOME present, no FM_SPAWN_GEN). Every consumer names "unpinned native restore" (8 hits, 0 "unreadable"), 0 bytes are sent, no state changes, and the meta sha does not change. r2: the env has no PATH or HOME. Every consumer says "live launch settings are unreadable" (0 "unpinned"), 0 bytes are sent, and nothing changes. r3: the pin is for another generation, so the cause is pinned-elsewhere and 0 bytes are sent. r4: a rival record makes the lane contested, so the restart is unreached and writes no records. r5: with the rival removed, the lane reads managed, and the restart writes inbox and pending-reply records (positive control). r6: on the legacy record, interrupt delivers ESC. r7: on a shell-only pane, exit gives already-stopped. Teardown codes are both 0. |
| dispatch-capacity-test-r2.txt | `tests/fm-dispatch-capacity.test.sh` passes with the new probe flag. |
| codex-probe-no-extensions-r2.txt (driver/codex-probe-r2.sh) | Real `omp` in a marked lab home, run from the worktree. The head `fm_omp_codex_capacity` returns an object (accounts, bestAccountHeadroom, status) and writes 0 marker files. The raw `--no-extensions` JSON has the same key shape as a no-flag run (57 path shapes, 3639 bytes). RED control: the base form (no flag) from the same cwd writes `.omp-watch-extension-loaded`, `.omp-turnend-extension-loaded` and `extensions/omp-primary-watch/lifecycle.log`. These are exactly the round-1 stray files. |
| rows-r2b-real-claude-and-suppression-head.txt (driver/run-r2b.sh) | Real `~/.local/bin/claude` 2.1.332 at its folder-trust screen, with no pin. interrupt, exit, relaunch and restart all refuse with the unpinned cause. The screen and the meta are unchanged. Sweep `--one`, `--one`, full gives 1, 0, 1 lines: the second tick is suppressed, and the unbounded sweep still reports. Real claude with a matching pin reads managed, and the full sweep is silent. |
| rows-r2c-managed-notice-base-vs-head.txt (driver/run-r2c.sh) | Base and head match. An unpinned `--one` writes a notice. Then a managed agent's bounded `--one` tick clears it, and the cursor stays the same. |

Note: on the "host attribution verb" row, the verb refused for a session-name reason (the lab session is not `fm-remote`). It is not verdict evidence for the remote path.
`git diff --stat 48b739d06 HEAD` shows only `bin/fm-dispatch-capacity-lib.sh` (+3 -1).
