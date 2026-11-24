# Test-phase evidence: fm-lint ShellCheck host-wide memory bound

Head e1ddd07bf, base 87836f79b. ShellCheck 0.11.0 (pinned) on macOS (this host) and in a
disposable Linux container (image fm-ubuntu2604-wp4, aarch64, docker --init; removed after use).

| Scenario | Result | File |
|---|---|---|
| Root-level address-space limit binds a real pinned ShellCheck root (restored test, R4-1) | pass (Linux) | linux-head-fm-lint-report-pinned.txt, linux-head-cli-address-space-limit-transcript.txt |
| Restored test fails when the root limit is removed (mutant: root skips `ulimit -v`) | test fails as intended | linux-mutant-root-unlimited-pinned-test.txt |
| Probe under 8 MiB limit exits 2, names probe and limit, starts no root | pass (Linux) | linux-head-cli-address-space-limit-transcript.txt (part A) |
| 4 runs, 4 HOME/XDG_CACHE_HOME/FM_HOME, stand-in of known RSS: base stacks over the bound, head stays under it | pass (macOS) | macos-four-homes-base.txt, macos-four-homes-head300.txt, macos-four-homes-head.txt, *-samples.tsv, scripts/four-homes.sh |
| Real ShellCheck diagnostics and exit codes identical base vs head (clean, findings of info/warning/style, SC1091 source-follow) | pass (macOS) | macos-real-shellcheck-diagnostics-base-vs-head.txt |
| `--list-files` and `--partition 1of3/2of3/3of3` identical base vs head | pass (macOS) | macos-list-files-base-vs-head.txt |
| Bad settings and unusable slot dirs refuse with exit 2, name the cause, start no analysis; control runs | pass (macOS) | macos-head-refusals-transcript.txt, scripts/refusals.sh |
| Bound tests (homes, kill, slot-file failure, two pools, queue-head read rate, stale record) | pass (Linux 9/9; macOS homes + kill 2/2) | linux-head-fm-lint-slots-selected.txt, macos-head-fm-lint-slots-kill-and-homes.txt |
| tests/fm-lint-report.test.sh, all 17 cases | pass (Linux; 12 in first pass, 5 after adding actionlint in the container) | linux-head-fm-lint-report-full.txt, linux-head-fm-lint-report-remaining-with-actionlint.txt |

Sampler note: the four-homes sampler sleeps 0.25 s between `ps` reads. Under host load the real gap
between samples was up to 2.25 s in the 300 MiB runs (mean 0.48-0.66 s) and up to 7.9 s in the first
500 MiB head run. A short peak between samples can be missed. The in-suite test measures overlap
from each stand-in's own start and end times, not by sampling.

Not driven: a real cold lint of this whole repo (before/after, M2) and a real two-run concurrent lint.
For most of this step another real fleet lint was running on this host, and the plan's host-safety rule
forbids a real cold lint while another lint runs. A full-repo lint is also the lint phase's work, and this
test phase must not run the linter over the repo. All real-ShellCheck runs here used small fixture files.

## Lone-run timing (M5 input, stand-in, macOS, no other lint running at the time)

File: macos-lone-run-timing.txt, spans in macos-lone*-spans.txt, driver scripts/lone.sh.

| Run | Wall | Peak overlap |
|---|---|---|
| 40 tiny roots, new paths: base | 12.5 s | 1 |
| 40 tiny roots, new paths: head | 36.0 s | 1 |
| 10 roots x 2 s, new paths: base | 14.7 s | 2 |
| 10 roots x 2 s, new paths: head (no records, cold) | 45.4 s | 1 |
| 10 roots x 2 s, same paths, head run 1 (cold) | 38.3 s | 1 |
| 10 roots x 2 s, same paths, head run 2 (recorded) | 21.2 s | 2 |
| 10 roots x 2 s, same paths, base | 24.9 s | 2 |

A cold lone run on head runs one root at a time and is about 3x slower. This matches the stated
rule in the bin/fm-lint.sh header ("on a pool with no history it runs one root at a time until its
roots are recorded"). Once the roots are recorded, the lone run keeps both workers and is as fast as base.
