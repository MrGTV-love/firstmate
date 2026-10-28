# Round 7 lifetime source review

Read-only WIP review. No tests, product experiments, signals, AXI, or edits.

Gate HEAD: `c1361cdac93d5cc557393b213da46985e9796416` plus mutable WIP. Current file hashes:

- bin/fm-duration.py `f5cd49b67d0233b2f4e41bd2f07375a16d409e0405b6b5df72d5d448a505d633`
- bin/fm-home-summary-refresh.sh `dd04ae0581322d49008b2008fb6c559be072c7637221e30b15699f1deddca35a`
- bin/fm-nm-run-lib.sh `0c91e04b9ea2ea1f2a967cc6b54ff8727a5440754ea8a3a284aae7b45911dd2d`
- bin/fm-timeout-lib.sh `6c376dbc224fcd29aba4a837d60d2b0a6099ac254c0c1875ef659ff58694cd73`
- tests/lib.sh `4cc9a1eccc9ca8d1fcf604d721df99f8e8759e09b9a516779a74911ff599a6bb`

## Supported improvements

- Unique `mktemp` records replace PID-keyed filenames: no record-path overwrite by PID reuse.
- `fm_process_reserve` runs before `fm_run_progress`, all four `fm_run_timed` mechanisms, direct `fm_nm_bounded` timeout, and `fm_process_exec`; each gets a pending record before launch.
- Nested `log-failure`, `note-failure`, and `release-lock` inherit the registered tree and have launchers reserve records before source; this closes their previous unregistered path.
- Parent interruption after reserve but before child fill leaves a pending record; cleanup waits instead of removing the root. That prevents the earlier early-delete pattern.
- Summary `--detach` reserves before spawn and fills the detached parent PID; defaults without registry/record remain unchanged.

## Remaining gaps

1. No failed publication. `fm_process_fill` only appends a PID and ignores write failure (`bin/fm-timeout-lib.sh:131-133`). A launcher interrupted after reserve but before fill, or an exec/spawn failure, leaves a permanently pending record. `fm_test_wait_processes` treats empty/partial records as pending and waits to its bound (`tests/lib.sh:393-400`). This is fail-safe against early deletion but is not pending-to-live/failed completion, and cleanup cannot establish closure.

2. Wait records are PID-only, not birth-aware. `fm_process_fill` writes only `$pid` (`bin/fm-timeout-lib.sh:131-133`); `fm_test_wait_processes` checks `kill -0 $pid` or `kill -0 -- -$pid` without start identity (`tests/lib.sh:401-405`). A reused PID/group can be attributed to a record, at minimum lengthening the wait; it is not proof of the original owned group. The comment’s “reused pid or group id can only lengthen the wait” does not establish identity.

3. Fill is not atomically published. The record is appended with `printf '%s\n'`, while the reader reads the first line (`tests/lib.sh:395`). A partial numeric write can be read before the full PID; the comment claims one line, but there is no temp-file rename or readback verification. Empty records are pending, but a partial valid-looking numeric prefix is not clearly rejected.

4. Perl watchdog groups remain unrecorded. `fm_run_perl_progress` calls `setpgrp(0,0)` for the watchdog and fills only the child pid (`bin/fm-timeout-lib.sh:223,238-239`); `fm_timeout_perl_bound` similarly creates its own group and records only the child. The source says these watchdogs run no fixture work, so they are not state-writer counterexamples, but the literal “every reachable new-group launch” claim is too broad.

No concrete foreground self-wait path was established: launcher records are for child group leaders or exact root PIDs, and the root self-record is exact-PID. The watchdog exception is the only new-group path outside the recorded child groups.

## Minimal corrections, proposals only

- Fill a full birth-aware record atomically (temp + rename, or verified single-write) containing PID and start identity; wait on both.
- Publish an explicit failed/terminal state on reservation/launch/exec failure, while retaining pending on an unobservable interruption rather than treating it as success.
- Document or record the watchdog-group exception; do not claim all new groups are registered.
- Keep the existing registry and wait helper; no general descendant supervisor.

## Conditional closure

The fix can close the nested-mode, delayed-launch, and PID-filename overwrite counterexamples for successful launches. It does not establish closure for pending/failed interruption, PID-reuse identity, or atomic record publication. CPU measurement should not resume under an unconditional lifetime-closure claim until those invariants are resolved or explicitly disclosed.

Historical PID 45450 remains unattributed.

WIP also contains two `bin/fm-teardown.sh` metadata-getter lines (`BUSY_GEN`, `ORCA_WORKTREE_ID`), SHA256 `6b5f952740fcf5699c3e75bb3d8be99d9c54c18203784659bab4fa79c7af85ed`; these are not lifetime registration and were not counted as closure.

# Final qualifications - supersedes conflicting wording above

This section records the accepted scope and mutable-snapshot limits. It supersedes the earlier demand for a failed-terminal state and the earlier unconditional CPU-pause wording.

## Accepted lifecycle contract

- Pending with bounded failure and root retention is accepted. No failed-terminal state is required.
- Cleanup must not delete a root prematurely. It may fail at its bound and retain the registry/root; success under arbitrary interruption is not required.
- Nonwriting watchdog groups are an explicit limited exception. Registering every new group is not required where the watchdog is not a future fixture-path writer.
- The recorded detach hierarchy has no demonstrated EOF miss. The watcher summary launch is a distinct conditional path: `bin/fm-watch.sh:2834` starts `fm-home-summary-refresh.sh --best-effort ... &` without a recorded launcher, and the child self-registers at `bin/fm-home-summary-refresh.sh:129-132`. If that path is in scope and the watcher exits first, zero-live cleanup can miss the later registration. This is not the current `--detach` path.

## Mutable snapshot limits

Current gate worktree has moved since the initial r7 snapshot:

- HEAD remains `c1361cdac93d5cc557393b213da46985e9796416`.
- `bin/fm-nm-run-lib.sh` current hash `44d8e5b8a29da703ffb32fdd7589fcae389583a406b8f9db8e85b74efb76bde6`; the direct-timeout change was removed as unreachable from the summary state reader, which forces progress. The earlier r7 statement that direct `fm_nm_bounded` timeout is covered is stale for this WIP.
- `bin/fm-duration.py` current hash `eb433cbfcbd5f96c2d1c95f70a72f38f2b3627b73fe106f29a2b9853748b2b9c`; the Python argument was renamed because it shadowed `record()`.
- `bin/fm-timeout-lib.sh` current hash `fc4b2eac307c64c44c421ffa51a56c0ea50da9c2cf4422a0e27ce2294746559a`.
- `bin/fm-home-summary-refresh.sh` current hash `dd04ae0581322d49008b2008fb6c559be072c7637221e30b15699f1deddca35a`.
- `tests/lib.sh` current hash `4cc9a1ec...`.
- `bin/fm-teardown.sh` current hash `6b5f9527...`; only metadata-getter lines.

## Narrow atomic/full-record finding

`fm_process_fill` currently does:

`[ -z "$1" ] || printf '%s\n' "$2" >> "$1" 2>/dev/null || true`

It ignores a failed or short `printf`. If a numeric prefix remains, `fm_test_wait_processes` reads it with:

`if ! IFS= read -r pid < "$record" 2>/dev/null; then pending ...; fi`

Bash `read` accepts a non-empty partial line at EOF. The numeric prefix can then be checked with `kill -0`; if that prefix is a dead PID/group, the record is removed even though the actual launcher PID is live and contained the full number. This is a source-supported failure path, not an observed reproduction and not a filesystem-exhaustion experiment.

The minimal correction is atomic/full-record fill only:

- write the full PID line to a unique temp file, then `mv` it over the pending record;
- if the write or rename fails, leave the pending record untouched;
- do not add a state machine or a failed-terminal requirement.

The wait should continue to treat a missing/empty record as pending and retain the root to its bound. Birth-aware identity and PID reuse remain separate residual questions, not requirements for adding a lifecycle state machine.

# Pin at commit 1e980ec8

Pinned to `1e980ec8cf4d1aefeaf071945399d746528596c3` (`no-mistakes(test): Record summary-tree launches before start; restore metadata reads`). Test PID 22921 was active; no test run was made.

## Atomic/full-record finding, pinned

- `bin/fm-timeout-lib.sh` at commit 1e980: blob `f86a312fc50417450d67bb86eed978a8bfc9d850`, SHA256 `fc4b2eac307c64c44c421ffa51a56c0ea50da9c2cf4422a0e27ce2294746559a`.
- `tests/lib.sh` at commit 1e980: blob `fb95c22cd7fb87bce66f6c85763b1c0435d2cee7`, SHA256 `4cc9a1eccc9ca8d1fcf604d721df99f8e8759e09b9a516779a74911ff599a6bb`.
- Worktree copies equal the commit for both files (`git diff --quiet` rc=0).
- `fm_process_fill` remains at `bin/fm-timeout-lib.sh:128-132`; it appends with `printf '%s\n' ... >> "$1" ... || true` and ignores write failure.
- `fm_test_wait_processes` reads the record with `IFS= read -r pid < "$record"` at `tests/lib.sh:395` and removes a dead numeric record at `:399-406`.

The source-supported fault path remains: a short/failed `printf` can leave a numeric prefix; `read` accepts a non-empty partial line at EOF; if that prefix is a dead PID/group, the record is removed while the full launcher PID is live. Not observed, no exhaustion experiment. Minimal correction remains atomic full-record fill (temp plus rename), leaving pending untouched on failure; no terminal state machine.

## fm-watch reachability

- Full cleanup suite `tests/fm-teardown-cleanup.test.sh`: no actual `fm-watch` invocation. Its committed blob is unchanged from parent c136: `3165fe6b11571fa8809641ad08b7ffc768c4d4ff`, diff rc=0. The 189-case cleanup source is unchanged.
- Affected fixture `tests/fm-home-summary-refresh.test.sh` does start a real `$WATCH` at lines 151-155 and waits for the status-triggered ledger at 167-168.
- `bin/fm-watch.sh:2825-2835` is the reachable launch: it starts `fm-home-summary-refresh.sh --best-effort ... &` without a recorded launcher.
- `tests/lib.sh:313-314` exports `FM_TEST_PROCESS_REGISTRY`; the watcher test does not export `FM_TEST_PROCESS_RECORD`, so the background summary takes the self-register path at `bin/fm-home-summary-refresh.sh:129-132`.

Therefore the watcher concern is **reachable from the affected summary fixture**, not solely a generic external caller. It is **not exercised by the full cleanup suite**. This is a source-reachability finding, not an observed test failure.

## Metadata restoration and suite equality

- At commit 1e980, `bin/fm-teardown.sh:1697` and `:1701` use `BUSY_GEN=$(fm_meta_get "$META" busy_gen)` and `ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)`, the restored capture form. The c136-to-1e980 diff changes these two lines from `fm_meta_get_to`.
- The 189-case cleanup suite blob remains `3165fe6b...`, equal to parent c136; no case-body/order change.

# Correction: short-write numeric-prefix counterexample retracted

This correction supersedes the earlier claim that a short or failed `printf` in `fm_process_fill` can leave a numeric prefix that `fm_test_wait_processes` passes to `kill`/`rm`.

The pinned code is:

```sh
if ! IFS= read -r pid < "$record" 2>/dev/null; then
  live="$live pending:$record ($label)"
  continue
fi
```

`tests/lib.sh:395-398`

Bash `read` without a terminating newline returns nonzero at EOF. The `if ! ...; then ... pending ...; continue; fi` path therefore keeps a partial line pending and never reaches the numeric case or `kill`/`rm`. The earlier inference that the numeric prefix proceeds was wrong. No newline-terminated wrong numeric record has concrete source evidence here.

Consequences:

- The claimed short-write premature-deletion counterexample is **retracted**.
- Empty and no-newline partial records are treated as pending under the actual conditional.
- Atomic/full-record fill remains a **robustness proposal**, not a demonstrated violated invariant.
- The accepted pending bounded-failure/root-retention contract is unchanged; no state machine is required or requested.

The earlier atomic-fill text is preserved above as the original review history; this correction controls. The watcher affected-fixture reachability finding remains separate and supported: the full cleanup suite does not invoke `fm-watch`, while `tests/fm-home-summary-refresh.test.sh` starts a real watcher that can reach `fm-watch.sh:2825-2835`.
