## CONTROL (omp WITHOUT the jev guard extension)
### [0] control-code_actions-apply-string-true
call: write {"path": "xd://lsp", "content": "{\"action\": \"code_actions\", \"file\": \"source.fmprobe\", \"line\": 1, \"apply\": \"true\", \"query\": \"0\"}"}
result: Applied "LAB_PROBE_ACTION create pwned file":
  Workspace edit:
    Created CODE_ACTION_APPLIED

### [1] control-diagnostics-symlink-escape
call: write {"path": "xd://lsp", "content": "{\"action\": \"diagnostics\", \"file\": \"escape.fmprobe\"}"}
result: 1 warning(s):
# escape.fmprobe
  1:1 [warning] [fm-lab-lsp] LAB_PROBE_DIAGNOSTIC value is suspicious

Auto QA endpoint requests: none

## CONTROL-B (omp WITHOUT the jev guard extension)
### [0] report_issue-autoqa-on
call: write {"path": "xd://report_issue", "content": "write: tool misbehaved LAB_REPORT_CANARY"}
result: Noted, thanks!

Auto QA endpoint requests: {"path": "/autoqa", "body": {"agent": {"name": "omp", "version": "18.12.6"}, "installId": "979fb9ec-2d9a-4abc-a698-684346a3a7df", "platform": "darwin", "arch": "arm64", "entries": [{"id": 1, "model": "lab/gpt-6.1-sol", "version": "18.12.6", "tool": "write", "report": "tool misbehaved LAB_REPORT_CANARY"}]}}

