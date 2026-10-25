# Live omp device lab (omp 18.12.6, target 393a41f45)

Real `omp -p` ran in a disposable lab: isolated HOME, PI_CODING_AGENT_DIR, git worktree.
It loaded `bin/fm-jev-guard.ts` from the gate worktree through `-e extension.ts`, plus `--config .omp/fm-worker-overlay.yml`, `PI_EDIT_VARIANT=replace` and `PI_DISABLE_LSPMUX=1`.
The model was a scripted local OpenAI-responses server (`model.py`). It emitted exact tool calls and logged the tool results omp sent back.
A local stdio LSP (`lsp.py`) served `.fmprobe` files through the worktree's `lsp.json`.
The Jev judge seam (`FM_TEST_SEAM=1`, `FM_JEV_GUARD_BASE_URL`) and Auto QA endpoint (`PI_AUTO_QA_PUSH_URL`) pointed to the same local server. A dead HTTP(S) proxy blocked all other egress.

- `A/transcript.md`: 24 guarded calls, the native result for each call, and the audit decision for each call.
- `B/transcript.md`: guarded `xd://report_issue` with Auto QA forced on, plus a local endpoint. Refused. Zero uploads.
- `CONTROL*/transcript.md`: the same harmful calls WITHOUT the guard. `code_actions apply:"true"` created `CODE_ACTION_APPLIED`. The symlink-escape diagnostics read the outside file. `report_issue` uploaded the report to the endpoint.
- `../targeted-jev-guard-tests.log`: `test_omp_permissions` and `test_omp_device_effects` from `tests/fm-jev-guard.test.sh`.
