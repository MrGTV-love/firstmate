# Test-step evidence: backlog-read progress flake (head 328c136aed690f7e51032ccc0786e441dcc2fa0b)

All numbers below are measured in this test step on 2026-10-24. Base = c0f3176c0d523226c7b8d93ba669fe0e4abe214e.

Hosts:
- macOS 27.0.1 arm64 (Mac Studio, 18 CPUs), Python 3.13.6, system Perl. Host load average is host-wide and includes other user work (1-min range 6 to 101 during these runs).
- Linux: Docker `fm-ubuntu2604-wp4-full:latest`, Ubuntu 26.04.1 LTS aarch64, Linux 7.0.14-linuxkit, Bash 5.3.9, Python 3.14.4, Perl 5.40.1, `--cpus 2 --pids-limit 512`, label `fm.task=fm-backlog-read-progress-flake`, `--rm`. Source = `git archive HEAD`.

## Requested suites (both platforms)

| Suite | macOS | Linux |
| --- | --- | --- |
| tests/fm-backlog-read-bound.test.sh | exit 0, all assertions passed (90295 ms) | exit 0, all assertions passed (77166 ms) |
| tests/fm-work-progress.test.sh | exit 0, failed=0 (217143 ms) | exit 0, failed=0 (173236 ms) |

Logs: `suites-macos.log`, `suites-linux.log`.

## Live runner checks (`live-cli.py`, keep-going / fm_run_progress bound 1 s)

burst = 4 s Python CPU child, reaped, then `sleep 0.5`, then `echo completed` (original flake shape).

| Path | burst | timed poll (sleep 0.05 loop) | sleep 120 | bash `while :; do sleep 0.2; done` (classification) |
| --- | --- | --- | --- | --- |
| macOS native, Python | 0 completed | 124 in 1.4-2.3 s (4/4) | 124 (4/4) | 124 after 2.4-24.9 s (4/4) |
| macOS ps, Perl (no python3) | 0 completed | 124 (4/4) | 124 (4/4) | never stopped in 25 s (4/4) |
| Linux /proc, Python | 0 completed | 124 | 124 | 124 after 4.2 s |
| Linux /proc, Perl | 0 completed | 124 | 124 | 124 after 1.3 s |
| Linux ps, Python | 0 completed | 124 | 124 | 124 after 1.3 s |
| Linux ps, Perl | 0 completed | 124 | 124 | never stopped in 25 s |

## Loaded burst runs, `nice -n 20`, 10 repetitions each (not the 50-run matrix)

| Path | Load | Head (Python + Perl) | Base (Python only) |
| --- | --- | --- | --- |
| Linux /proc | 2 CPU workers in 2-CPU quota | 20/20 pass | 10/10 rc 124 |
| Linux ps | 2 CPU workers in 2-CPU quota | 20/20 pass | 10/10 rc 124 |
| macOS native | 18 CPU workers on 18 CPUs | 20/20 pass | 10/10 rc 124 |

Files: `loaded-*.jsonl`, `live-cli-*.jsonl`, `idle-macos-repeat.jsonl`.
