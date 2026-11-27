# Test step evidence: fcf0f4ac8 (alone-rerun docs, rerun roots counted once)

Host: Mac Studio, 18 CPUs, load ~73, memory pressure level 1, `bin/fm-mem-guard.sh admit` rc=0, no other ShellCheck or fm-lint.sh running before the real lint.

## S1 Alone rerun cases at head (real bin/fm-lint.sh, fake reader/ShellCheck)
File: alone-rerun-cases-head.txt. All 5 print `ok`:
- test_a_late_reply_reruns_the_root_alone_and_a_measured_rerun_under_the_cap_passes (now also checks meta rows 2/2/0)
- test_a_rerun_alone_that_is_unmeasured_again_fails_the_root
- test_a_rerun_alone_measured_over_the_cap_fails_the_root
- test_resident_watch_replaces_a_stalled_reader
- test_resident_watch_retries_a_replacement_that_exits

## S2 Meta rows on the parent fm-lint.sh (red before the fix)
File: meta-count-case-on-parent-fm-lint.txt. Same HEAD test, parent (d6f1b61e8) bin/fm-lint.sh:
2 distinct roots, one rerun -> `roots_begun 3`, `roots_completed 3` (wrong). At head the case passes with 2/2/0.

## S3 Telemetry source_followed for a root rerun after a no-source attempt
Scratch driver: fmlint-scratch-nosource.sh (not committed). Root with one `# shellcheck source=lib.sh` line.
Attempt 1 with sources over cap (98) -> narrower retry unmeasured -> rerun-queued with source flag 0 -> alone rerun with sources passes (flag 1).
- head (nosource-rerun-head.txt): roots_begun 1, roots_completed 1, source_followed_directives 1.
- parent (nosource-rerun-parent.txt): roots_begun 2, roots_completed 2, source_followed_directives 0 (wrong).

## S4 Real lint with real ShellCheck 0.11.0
Dir: real-lint/. Command: `FM_LINT_CACHE_DIR=off bin/fm-lint.sh --telemetry <dir>/pass.tsv bin/fm-lint.sh tests/fm-lint-slots.test.sh`, sampled every 1 s (fmlint-sampler.sh).
rc=0, wall 14 s, 2 roots begun and ended ok, meta roots_begun 2 / roots_completed 2 / roots_unfinished 0.
Peak sampled ShellCheck total RSS 1274384 KiB with 2 processes; host budget 3670016 KiB; pressure stayed 1.
