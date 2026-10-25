# T4 tool and egress table: live test evidence

Host: Mac-Studio.local (darwin), omp 18.12.6, Claude Code 2.1.310, node v26.4.0.
Target commit: 94bf4715c2eaab276d43086109aa9b478e4452b8.

No paid model or Jev requests. Every model and Jev endpoint is a private local scripted server.
All outbound proxies point to a dead port (127.0.0.1:9). Env is scrubbed (`env -i`).

| File | What it shows |
|---|---|
| audit-test.log | `bash tests/fm-jev-guard-audit.test.sh`: T4(a)-(d), M4 events, metrics reader; installed omp (19 tools) and installed Claude (24 tools) inventories fully classified, injected unknown tool rejected |
| omp-live-e2e.log | `FM_JEV_GUARD_OMP_LIVE=1 bash tests/fm-jev-guard-omp-live-e2e.test.sh`: real omp under `.omp/fm-worker-overlay.yml` refuses URL read and URL grep ("URL reads are disabled by settings."), keeps ordinary file read |
| fm-spawn-claude-worker-settings.local.json | the real `bin/fm-spawn.sh` output for a Claude ship worker (matcher `^(?!Bash$).*`) |
| claude-live-hook.log | real Claude Code run with that settings file: WebFetch/WebSearch/Agent refused without grant; Bash runs with no guard process; Read allowed; WebFetch admitted under `egress=["web"]`; WebSearch refused under wrong grant; no query/URL text in central events |
| claude-live-mcp.log | real Claude Code with an unlisted MCP tool: refused as "Unclassified host tool" under every grant; tool body never ran |
| omp-live-t4-cases.log | real omp: find refused without grant and admitted with `semantic-search`; web_search refused; eval allowed with `confinement_owner: T5`; write to `xd://report_issue` refused under every grant; unlisted extension tool refused, body never ran |
| guard-audit-closure.log | `bash tests/fm-guard-audit-closure.test.sh`: registry lint in enforce mode is clean, 31 live guards |
| relaunch-egress-grant.log | `bash tests/fm-control-relaunch.test.sh test_relaunch_keeps_a_recorded_pr_parseable_for_monitoring`: relaunch keeps a later `egress=` grant and PR parse |
| *.sh, *.py | the drivers used (gen-settings.sh, claude-cases.sh, claude-mcp-case.sh, omp-cases.sh, omp-cases2.sh, anthropic-mock.py, mcp-probe.py) |

Not run live: Claude `SendFeedback` as a model call (not a model-callable tool in the host; covered by the adapter CLI test in audit-test.log). Claude inventory under claude.ai sign-in (the inventory check uses API-key auth; recorded decision R12-1).
