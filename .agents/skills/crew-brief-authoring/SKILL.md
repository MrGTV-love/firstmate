---
name: crew-brief-authoring
description: Load before creating or changing a ship, scout, or secondmate brief, and before spawning or promoting work from one.
user-invocable: false
metadata:
  internal: true
---

# Crew brief authoring

Resolve the project's registered ship-branch prefix the same way, via `bin/fm-project-mode.sh --branch-prefix <project>`, and pass it explicitly to the brief, ship spawn, and scout promotion as `--branch-prefix` (default `fm/` needs no flag).
When the work must start from and target a branch other than the project's default, such as a named feature or release branch, pass it to the ship or scout brief and spawn as `--base-branch <branch>`; any promotion reads it from task meta.

`bin/fm-brief.sh` and its help own scaffold syntax, generated variants, status protocol, delivery-mode definitions of done, and exact safety mechanics.
Use its scaffold as the contract, then fill `## Captain's intent` (`{TASK}`) with the captain's own ask and any boundary the captain stated, plus the context needed to read it, including the substance of any report, decision, or PR the ask refers to; never widen the ask there into a general goal or an enumerated coverage list, because the reviewer treats that subsection as acceptance criteria.
Fill `## Firstmate spec` (`{FIRSTMATE_SPEC}`) with only the build instructions that ask requires, naming what stays out of scope when the ask is narrow; a generalization, consistency sweep, or extra hardening the captain did not ask for is follow-up work to note, not scope to add.
Resolve the scaffold's `Egress needs` from the task's stated needs before dispatch, following [Tool coverage and outbound calls](../../../docs/configuration.md#tool-coverage-and-outbound-calls).
List any excluded work in the nested `### Out of scope` list, because independent review reads the list as the task's stated boundary.
`bin/fm-dod-lib.sh` owns intent authoring without added speaker labels or direct address, its provenance markers, what a no-mistakes worker may pass as `--intent`, and the string's self-sufficiency rule.
Keep additions task-specific rather than repeating lifecycle instructions, and alter generated sections only when the task genuinely differs from the standard shape.
For work that adds or changes tests, hooks or validators, use the [existing intent-to-test criteria](../../../docs/review-rubric.md#intent-to-test-alignment) to shape the relevant Firstmate specification and verification, not to expand the captain's intent.

Load `secondmate-provisioning` before creating or using a charter brief and preserve its idle-by-default and marked-return-channel contracts.
Status appends are sparse supervisor-actionable events, not routine progress; `bin/fm-status-decision-lib.sh` owns keyed open and resolved semantics.
The scaffold is a safety contract, not a suggestion.
If a ship task touches firstmate's shared tracked material, explicitly require `firstmate-coding-guidelines` before editing.
If a ship task adds or changes a guard, a hook, or workflow machinery that can block, mutate or recover shared operations, its harm is Strict tier in guard-design's table (data loss, a privilege boundary, consequential external effects, or an untrusted actor), and it is not P12 work (a change delivered for Vernant P12, or a dependency P12's owner requested for it) unless P12's owner opts in, require in the Firstmate spec: state the tier and the harm record that sets it (path and line); load `guard-design`, or read `~/.agents/skills/guard-design/SKILL.md` when it does not load by name; before the first code change, save `case-plan.md` and `case-plan.sha256` in the task's data folder, with rows from guard-design Step 3's row sources (contract criteria; file names only from guard-design's two bounded `rg -l -uu` searches of the live home (code outside `data/`, run from the home, and `data/` to depth 3), credential files excluded, and `graft callers`; environment states checked by command; named environment variables and the effective configuration; one hostile case per new decision point; inputs that will move, each also run against its newest release and a new input form in a disposable copy); before its first `done:` report, and so before the first independent review, have a separate subagent run guard-design Step 4's hostile pass and save `hostile-pass.md`.
Also require that a worker who can read neither copy of `guard-design` appends `blocked:` and stops before the first code change.
Label any route, caller or state list the brief gives as known so far.
If a task will drive Herdr lifecycle behavior, scaffold with `--herdr-lab`; if that need appears after an unguarded scaffold, stop and regenerate rather than adding commands by hand.
The generated Herdr contract must use a named non-`default` isolated lab and its guarded helper for every lifecycle action.

## Intake classification and delivery contract

Classify the deliverable:

- **Ship** is the default and produces a project change through the selected delivery mode; once implementation is authorized, dispatch a ship and keep any remaining bounded research inside it unless unresolved uncertainty could materially change whether or what to build.
- **Scout** produces knowledge in `data/<id>/report.md`, never a PR, and is appropriate for investigation, diagnosis, planning, reproduction, or audit work when the captain explicitly requests a separate knowledge or design deliverable or unresolved uncertainty could materially change whether or what to build.

- If established evidence already answers an informational question, relay it without a design-only scout; when implementation intent is unclear, answer and ask one concise implementation question when useful rather than dispatching speculative design work.
- Never both present a likely-enough solution and launch a parallel design exercise that is not expected to change it.

Pass the mode explicitly to the brief, and pass both values explicitly to the spawn and any scout promotion; each command refuses to guess the values it consumes.
For a ship task whose project is this firstmate repository, pass the project directory to the brief as `--project` and record any captain-approved one-task contribution consent as `--upstream-consent <host>/<owner>/<repo>` on the brief, spawn, and promotion; `bin/fm-spawn.sh` refuses a publishing contract this home's role does not authorize.
On a `no-mistakes-prod-only` project, classify the task's surface: internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`; never infer internal-only from file location or project name.
Record the resulting mode, `yolo` merge posture, and the one-line reason for any deviation in the backlog item note.
