# T1 live evidence (omp 18.12.4, Claude Code 2.1.310, macOS, private scripted providers, no paid calls)

Head = a124412fa. Base = 30f233bc9 (extracted with `git archive` to a temp dir).
Stub Jev answers pre-tool calls per scenario and flags (0.99) any result-screen request,
so any surviving result screen would withhold. Driver: real `omp -p ... -e <guard extension> --config .omp/fm-worker-overlay.yml --tools bash`.

| Case | Base: what reached the worker | Head: what reached the worker | Head Jev requests | Head audit rows |
|---|---|---|---|---|
| T1(a) omp `async: true` background notice | `[jev-guard] Tool output requires review (flag) ... withheld` | omp notice `Backgrounded as job bg_1 (...)...wait to be woken.` verbatim | 1 (pre-tool command only) | tool_call allow only |
| T1(b) nm-drive-45.log bounded wait, exit 0 | withheld | all 20 lines incl. `help[3]:` verbatim | 1 pre-tool | tool_call only |
| T1(b) same, exit 1 | withheld | verbatim + omp `Command exited with code 1` | 1 pre-tool | tool_call only |
| 300 KB result (old size path) | withheld | omp native output (omp's own 768-byte line truncation), no guard notice | 1 pre-tool | tool_call only |
| Pre-tool deny still works | denied | denied (`[jev-guard] irreversible ...`), marker not written | 1 pre-tool | tool_call block/pretool_deny |

T1(c)/(d) for reads: `tests/fm-jev-guard-omp-live-e2e.test.sh` (20 cases + 31 s pre-tool) and
`tests/fm-jev-guard-claude-live-e2e.test.sh` (20 cases): launch, steering, copied and changed records
reach the next model turn byte-for-byte; jev.jsonl empty; no tool_result audit row.

Files: head-*.delivered.txt / base-*.delivered.txt (worker context), *.jev-requests.json, *.audit.jsonl, *.omp-stdout.txt.
