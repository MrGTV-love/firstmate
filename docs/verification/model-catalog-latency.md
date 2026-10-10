# Model catalog command latency

This record supports the time limits in [`bin/fm-model-catalog-lib.sh`](../../bin/fm-model-catalog-lib.sh).
Each limit is at least four times the slowest catalog read measured under heavy host load.
Repeat the method below when a harness is upgraded, when a limit is changed, or when opencode or cursor is first installed.

## Method

Measured on 2026-10-10 on the fleet's Mac Studio (Darwin 27.0.0, arm64, 18 cores, 128 GB).
Harness versions: claude 2.1.296, omp 18.8.7, agy 1.3.3, pi 1.0.2.
The codex catalog is a read of `~/.codex/models_cache.json`; no codex command runs.
Every run is one wall-clock read of the exact discovery command the library uses, with stdout and stderr discarded and the exit status recorded.
All 75 runs exited 0.

A truly idle host was not available.
The fleet kept the one-minute load average between 58 and 69 (3.2 to 3.8 times the core count) during the "idle" runs, so that column is an ordinary busy host.
The "heavy" runs added 36 `yes` processes (twice the core count) and four loops writing 256 MB files with `dd`, which raised the load average to 109 (6 times the core count).
Both runs went through `bin/fm-proc-budget.sh`.

The measurement script ran each command `N` times in a row:

```bash
t() { # name command...
  s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  "$@" >/dev/null 2>&1 </dev/null; rc=$?
  e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  printf '%s run=%s rc=%s secs=%.3f\n' "$name" "$i" "$rc" "$(perl -e "print $e - $s")"
}
t claude bash -c 'exec claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --setting-sources "" < "$1"' _ initialize.json
t omp env OMP_SKIP_SETUP=1 omp models --json
t agy agy models
t pi pi --list-models
t codex jq '{models: [.models[] | {id: .slug}]}' "$HOME/.codex/models_cache.json"
```

## Results (seconds)

| Harness | Idle runs (n=5) | Heavy runs (n=10) | Limit | Margin over worst heavy run |
| --- | --- | --- | --- | --- |
| claude | 1.454 4.418 2.969 3.521 2.246 | 6.315 5.459 4.941 3.676 5.114 3.527 7.203 4.856 5.965 6.458 | 30 | 4.2x |
| omp | 1.606 0.448 0.470 0.508 0.653 | 4.078 2.817 4.450 2.787 3.926 3.527 5.738 4.944 3.234 3.565 | 25 | 4.4x |
| agy | 0.740 0.760 1.096 1.678 0.736 | 1.426 2.137 0.829 2.110 1.574 1.938 1.533 1.580 2.175 1.177 | 10 | 4.6x |
| pi | 0.352 0.302 0.325 0.293 0.321 | 1.758 1.251 1.930 0.993 0.550 0.638 0.483 1.113 1.170 1.117 | 10 | 5.2x |
| codex (file read) | 0.031 0.018 0.027 0.019 0.021 | 0.035 0.017 0.018 0.021 0.017 0.015 0.021 0.015 0.014 0.017 | 5 | over 100x |

The first omp run of each series was the slowest idle run (1.606 against about 0.5), so a cold start costs about three times a warm one; the limit covers it.
`pi-signed` runs the same listing as `pi` and shares its limit.

## Not measured

opencode and cursor were not installed on the measurement host.
Their limits keep the 30 seconds the code used before this measurement; they are not derived from latency.
The Cursor listing is bounded inside `bin/fm-cursor-lib.sh`, which this record does not cover.
`bin/fm-spawn.sh` bounds its own `agy models` check separately (`FM_AGY_MODELS_TIMEOUT`, 15 seconds); that limit is outside this record.
