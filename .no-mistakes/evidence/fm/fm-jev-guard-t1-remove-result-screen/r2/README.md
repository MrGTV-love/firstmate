# T1 live evidence, round 2 (head 4e3f56487, base e590e3eb9)

Host: macOS (Darwin 27.0.0), omp/18.12.6, Claude Code 2.1.310. All model and Jev
endpoints are private scripted local servers (`tests/fm-jev-guard-native-fixture.py`);
no paid provider call was made. The parent directory holds round-1 evidence from an
older pre-rebase head (a124412fa) and omp 18.12.4; this directory supersedes it.

Driver: `drive-live-omp-t1.sh <tree> <label> <evidence-dir>` runs the real `omp -p`
with the guard extension from that tree, `--config <tree>/.omp/fm-worker-overlay.yml`,
`--tools bash,write`. The stub Jev flags (0.99) every result-screen request, so any
surviving result screen would withhold output. Round 2 changes the pre-tool deny case
to the write tool, because T2 (base e590e3eb9) stopped judging bash calls.

| Case | Base e590e3eb9: reached the worker | Head 4e3f56487: reached the worker | Head Jev requests | Head audit rows |
|---|---|---|---|---|
| T1(a) omp `async: true` background notice | `[jev-guard] Tool output requires review (flag) ... withheld` | `Backgrounded as job bg_1 (...) ... wait to be woken.` verbatim | 0 | none |
| T1(b) nm-drive-45.log bounded wait, exit 0 | withheld | all 20 lines incl. `help[3]:` verbatim | 0 | none |
| T1(b) same, exit 1 | withheld | verbatim + omp `Command exited with code 1` | 0 | none |
| 300 KB result (old size path) | withheld | omp native output (omp's own 768-byte line cut), no guard notice | 0 | none |
| Pre-tool write deny still works | denied | denied (`[jev-guard] contains a credential ...`), marker not written | 1 (path+content) | tool_call block / pretool_deny |

Base audit rows for every result case: `{"hook":"tool_result","decision":"flag","enforcement":"omp_replace"}`.

Other files:
- `omp-live-e2e.log`, `claude-live-e2e.log`: T1(c)/(d) for reads. Launch, steering,
  copied and changed records reach the next model turn unchanged on real omp and real
  Claude Code; no result request and no audit row (20 cases each, plus the 31 s omp
  pre-tool write case).
- `publisher-outputs.txt`: the real launch and steering publishers write their record
  and no `*.consistency.json` receipt.
- `retirement-tests.log`: the five `tests/fm-retired-jev-*.test.sh` tests, all exit 0.
- `selector-retirement-selection.txt`: `bin/fm-test-run.sh --list --changed` in a
  scratch clone selects the T1 retirement tests when only `bin/fm-jev-guard.ts`,
  `bin/ten-levels/extensions/report.ts`, `bin/fm-operational-input.sh` or
  `bin/fm-task-inbox-lib.sh` changes.
- `test-*.log`: changed unit suites.
