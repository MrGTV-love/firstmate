# Test round 2 evidence (target 8c61c6d9d)

All runs: native macOS (Darwin arm64), ShellCheck 0.11.0, from the run worktree, under `bin/fm-proc-budget.sh`, `FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR=off`. Host load average 16-25 throughout.

| file prefix | scenario | result |
| --- | --- | --- |
| `t1-focused-watch-tests.log` | 12 focused fm-lint-slots cases (watch, reader, retry) | all ok |
| `s1-normal-roots.*` | real lint of `bin/backends/herdr.sh` + `tests/fm-spawn-acquisition-cleanup.test.sh`, default 8 GiB bound | rc=0, reason ok, roots-log col 16 `libproc:19,ps:0` / `libproc:14,ps:0`, no reader-unavailable, no `Broken pipe` on stderr |
| `s2-over-bound-real-roots.*` | same two real roots, `FM_LINT_ROOT_RSS_KIB=1048576` | both ended rc=98, reason memory-fallback, narrower retry passed, lint rc=0 |
| `s3-runaway-repro.*` | copy of the runaway test with its `source=/dev/null` directive removed, `FM_LINT_ROOT_RSS_KIB=3145728` (3 GiB, below the 8 GB hard stop) | source-following ShellCheck crossed 3 GiB in ~25 s, was ended (rc=98), retried narrower and passed; no watch/reader/ShellCheck left |
| `s4-bad-bound.log` | `FM_LINT_ROOT_RSS_KIB` = 0, 08, abc, -5 | each exits 2 with a named error; empty uses the default |
| `s5-require-bounds-macos.out` | `FM_LINT_REQUIRE_BOUNDS=1` on macOS | still refuses to lint uncapped (rc=2), unchanged |
| `s7-interrupted-lint-cleanup.*` | TERM a running lint mid-root | watch, reader (real interpreter `.pyenv/versions/3.13.6/bin/python3`, not the shim) and ShellCheck all gone within 0.61 s |
