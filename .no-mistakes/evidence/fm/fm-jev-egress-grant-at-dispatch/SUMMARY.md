# Live lab evidence: jev-egress-grant at dispatch (target e69ba5e12)
Lab: bin/fm-lab-home.sh env home, private tmux socket (-L fm-lab), TREEHOUSE_ROOT inside lab, real bin/fm-spawn.sh,
real treehouse, real omp 18.14.0 workers (machine login), throwaway git project named `firstmate`. Torn down after.

| Scenario | Result | Evidence |
|---|---|---|
| fm-brief.sh scout scaffold carries `Egress needs: []` | pass | scaffold-brief-egress-none.md:12 |
| Empty grant dispatch: meta egress=[], overlay find.enabled off, launch brief "Recorded destination classes: [].", one allow on dispatch-grant + dispatch-find | pass | egress-none/, lab-jev-egress-grant-events.jsonl |
| Live worker without semantic-search lists 15 tools, no `find` | pass | egress-none/report.md, worker-pane.txt |
| Granted `["semantic-search"]` dispatch: egress line, find on, live worker lists `functions.find` (only diff vs empty) | pass | egress-granted/ |
| Unknown class / indented / duplicate / malformed directive: exit 1 before provisioning, exactly one deny (source_ok false), no state files, no window | pass | spawn-egress-{unknown,indented,duplicate,malformed}.log |
| Relaunch via fm-control after editing brief to add semantic-search: record kept egress=[], find off, one allow per key | pass | egress-none-relaunch/ |
| Runtime backstop: granted worker (no web grant) calls web_search: refused, new redispatch wording, one deny `egress-granted:web` | pass | egress-granted/report-after-websearch.md |
| tests/fm-jev-guard-audit.test.sh under fm-proc-budget --own-procs 128 | pass (exit=0) | fm-jev-guard-audit.log |

Notes:
- Relaunch: the replacement worker's launch brief (worker-pane.txt:270) still declares `Recorded destination classes: [].` The worker re-checked its earlier report and did not list its tools again, so the evidence that find is absent after relaunch is the overlay `find.enabled: off` plus the native construction proof in the audit test.
- No refusal loop: the lab event log has no runtime `egress-none:<class>` deny. The single requested web_search produced exactly one deny and no retry.
- Not driven live, but covered by the audit test (`ok -` lines in fm-jev-guard-audit.log): the record-helper and find-helper failure denies, the symlinked-root/node-fallback launch interface, and promotion preserving the grant.
- Both workers' completion gate (`fm-captain-hold.sh complete`) was refused writing state/<id>.meta under seatbelt write confinement. The diff touches no confinement or captain-hold code; this was not compared against base.
