# Primary helper agents and durable project work

A firstmate primary may use its harness's helper agents and session tools for read-only research, planning, communication, and other work that does not change a project.
There is no tool-name guard or required opt-in for `Agent`, `Monitor`, `TaskCreate`, `ScheduleWakeup`, `SendMessage`, `Workflow`, or other helper tools.
The tracked Claude `PreToolUse` hooks in `.claude/settings.json` apply only to `Bash` commands and retain their separate watcher-arm and directory-change protections.

The boundary is the work, not the tool name.
`AGENTS.md` sections 1 and 7 require project-specific coding, investigation, planning, and audits to be delegated through the fleet; `bin/fm-brief.sh` and `bin/fm-spawn.sh` provide the task's instructions, durable record, isolated project copy, and supervision.
The primary does not write to a project itself outside the concrete captain-approved exceptions in `AGENTS.md` section 1.
A helper agent does not substitute for that project-work process merely because its tool is available.

The prior `bin/fm-subagent-pretool-check.sh` classified tool names by stems rather than by the work requested.
It could block a read-only report consolidation and unrelated session tools while leaving project changes through an unclassified shell command untouched.
Its removal does not change the obligations or records above; it removes a tool-shape restriction that could not reliably enforce the work boundary.
Do not install a home-local Claude `permissions.deny` list for helper and session tools as a replacement: it removes the tools from the model's schema, including uses permitted by the work boundary, and tracked settings would also affect workers.

## Verification

`tests/fm-turnend-guard.test.sh` checks that the remaining tracked Claude hooks run in Claude and not in Grok's compatibility layer.
`tests/fm-arm-pretool-check.test.sh` and `tests/fm-cd-pretool-check.test.sh` cover the separate Bash command protections.
A primary-home Claude session exercising a read-only helper-agent call provides the live check for harness availability; tool availability also depends on any untracked per-home settings outside this repository.
