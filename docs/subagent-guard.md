# Primary helper agents and durable project work

A firstmate primary may use its harness's helper agents and session tools for work that is not project-specific, such as consolidating firstmate-private reports, general research, and communication.
There is no tool-name guard or required opt-in for `Agent`, `Monitor`, `TaskCreate`, `ScheduleWakeup`, `SendMessage`, `Workflow`, or other helper tools.
The tracked Claude command protections are owned by [`arm-pretool-check.md`](arm-pretool-check.md) and [`cd-guard.md`](cd-guard.md); [Jev command screening](configuration.md#jev-command-screening-shadow-only) owns the separate advisory hook.

The boundary is the work, not the tool name.
[`AGENTS.md`](../AGENTS.md) sections 1 and 7 own project-work delegation and its captain-approved exceptions, including the fleet requirement for project-specific investigation, planning, bug reproduction, and audits even when read-only.
A harness helper call does not itself create a fleet task record or a supervised worker session, so helper availability is not a substitute for that project-work process.

The prior `bin/fm-subagent-pretool-check.sh` classified tool names by stems rather than by the work requested.
It could block a read-only report consolidation and unrelated session tools while leaving project changes through an unclassified shell command untouched.
Its removal does not change the obligations or records above; it removes a tool-shape restriction that could not reliably enforce the work boundary.
Do not install a home-local Claude `permissions.deny` list for helper and session tools as a replacement: it removes the tools from the model's schema, including uses permitted by the work boundary, and tracked settings would also affect workers.

## Verification

`tests/fm-turnend-guard.test.sh` checks that Claude's tracked hook matchers do not intercept `Agent`, `Monitor`, `TaskCreate`, `ScheduleWakeup`, `SendMessage`, or `Workflow`, and executes both Bash command protections to verify their denials remain authoritative alongside advisory screening.
It also checks native primary applicability, task-context exclusions, and Grok compatibility exclusion through the tracked Claude commands.
`tests/fm-arm-pretool-check.test.sh` and `tests/fm-cd-pretool-check.test.sh` cover the separate Bash command protections.
A primary-home Claude session exercising a read-only helper-agent call provides the live check for harness availability; individual deferred tools still depend on the harness and any untracked per-home settings outside this repository.
