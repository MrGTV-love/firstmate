# Repeat-mistake sweep — current-round live evidence

Three fresh real Claude CLI primaries consumed the current Firstmate skill from this worktree. Two captain-requested sweeps exercised manual/tasks-axi backlogs; a third handled second occurrences and covered lint/docs remedies. Existing normal login was used. All primaries ran on independent private 140x45 tmux sockets. Supported lab-home create/tmux-dir/teardown helpers were used; all homes, servers and socket caches were removed.

Initial inspection: base-to-target git diff, PATH availability and `claude --help`. The prior recorded failure is the baseline; no old-source failure was rerun. No suite, lint, formatter, static analysis, lifecycle, PR, push, pipeline or CI phase was run. No source changes were needed.

The changed surface is agent procedure behavior, not a rendered UI. These real CLI responses, tool traces and persisted backlogs are the relevant product evidence; screenshots are not applicable.

## Observed behavior

- Different symptom wording with the same duplicated export owner qualified across alpha/beta. Same export symptom with disk-full root cause did not receive a task. Multiple artifacts for one date-format event did not become multiple instances.
- Architecture/types/behavioral-test recommendations selected the strongest applicable rung. The second-occurrence trigger selected lint and docs where stronger rungs could not express the judgment.
- The existing queued owner guard was reused exactly once; the skipped rollback behavioral guard was proposed for repair, not replacement with another guard.
- Manual backlog was edited directly; tasks-axi backlog was filed with three real queued wrapper add operations. `add --help` was usage inspection only.
- Final responses in both backlog modes omit all singleton classes, including exclusion notes. Captain prompts requested the procedure results without prescribing singleton exclusion.
- Archived advice to fix code inline and edit project AGENTS.md was not acted on. All tracked worktree files and seeded non-backlog fixture files remained unchanged; direct-PR posture was preserved.

## manual — actual final response

Filed the sweep results to the manual backlog; summarizing now.

## Repeat-mistake sweep (qualifying classes only)

I used the `diagnostic-reasoning` procedure, which the trigger index selects for "what do agents keep getting wrong". The lab's backlog backend is `manual`, so I edited `data/backlog.md` directly. The project's delivery mode is direct-PR, and I left that alone. Nothing was implemented or dispatched.

| Class | Evidence | Rung | Task |
|---|---|---|---|
| Duplicate export path skips lock validation | alpha 2026-10-01, beta 2026-10-02 (`data/learnings.md`) | 1 – Architecture: one export entry point | `export-single-owner-guard` (filed) |
| Archive deletion skips owner validation | delta 2026-10-01, epsilon 2026-10-02 | 1 – Architecture: one shared deletion entry point | `existing-owner-guard` (already queued, so I didn't file a duplicate) |
| API accepts an unconstrained mode string | gamma 2026-10-03, zeta 2026-10-04 | 2 – Types: closed enum or schema | `operating-mode-enum-guard` (filed) |
| Stale cache survives rollback | theta 2026-10-01, iota 2026-10-02 | 4 – Behavioral test | `repair-rollback-cache-test` (filed) |

- **Export:** the guard would have rejected alpha's independent export. No existing guard covers it.
- **Mode string:** the guard would have rejected gamma's misspelled mode. The shared owner is already correct, so the fix is the type constraint, not a restructure.
- **Rollback cache:** an existing rollback behavioral test missed both instances because an opt-in condition disables it. The remedy is repairing that test, not adding a second one. Architecture, types and lint can't express this environmental behavior.

The archived recommendation to fix the code and edit the project's `AGENTS.md` was evidence only. I didn't act on it, and I didn't touch any `AGENTS.md`, `CLAUDE.md` or source file.

SWEEP_DONE

### Actual persisted backlog

```markdown
# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share owner validation (repo: sweep-demo) (kind: ship)
  Class: parallel archive deletion implementation skips owner check; tasks delta 2026-10-01 and epsilon 2026-10-02. Architecture: one shared deletion entry point.

- [ ] export-single-owner-guard - Route all exports through the validated export owner (repo: sweep-demo) (kind: ship)
  Class: duplicated export implementation skips lock validation; tasks alpha 2026-10-01 (learnings.md) and beta 2026-10-02 (learnings.md). Architecture: one export entry point, remove independent export paths (e.g. export.sh); would have rejected alpha. No existing guard.

- [ ] operating-mode-enum-guard - Constrain API operating mode to a closed enum/schema (repo: sweep-demo) (kind: ship)
  Class: shared API owner accepts unconstrained mode string; tasks gamma 2026-10-03 and zeta 2026-10-04 (learnings.md). Types: enum/schema of the three fixed modes; would have rejected gamma's misspelling. Owner architecture already correct; no existing guard.

- [ ] repair-rollback-cache-test - Repair skipped rollback behavioral test so stale cache after rollback fails (repo: sweep-demo) (kind: ship)
  Class: stale cache survives rollback; tasks theta 2026-10-01 and iota 2026-10-02 (learnings.md). Behavioral test: existing rollback test is disabled by an opt-in condition and missed both; repair it (make it run unconditionally) and cover the recorded transition. Architecture/types/lint cannot express it.

## Done
```

### Observed state and teardown

```json
{
  "name": "manual",
  "backend": "manual",
  "lab": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-retest-lgnoekwz",
  "protected_files_unchanged": true,
  "completed": true,
  "dimensions": "140x45 /private/tmp/fml.gIlfJs/tmux-501/fm-lab",
  "wait_stderr": "",
  "result_subtype": "success",
  "response_marker": true,
  "project_source_unchanged": true,
  "private_server_stop_status": 0,
  "socket_teardown_status": 0,
  "socket_teardown_stderr": "",
  "lab_removed": true
}
```

Full evidence: [retest-manual-primary.jsonl](retest-manual-primary.jsonl), [retest-manual-actions.json](retest-manual-actions.json), [retest-manual-launch.txt](retest-manual-launch.txt), [retest-manual-prompt.txt](retest-manual-prompt.txt).

## tasks-axi — actual final response

I ran the repeat-mistake sweep from `diagnostic-reasoning`, which the skill trigger index selects for this question. Four mistake classes qualified, each with two instances from different tasks. I filed three new guard tasks and reused one that was already queued. Nothing was fixed or dispatched, and I didn't touch the project's `AGENTS.md` or `CLAUDE.md`. The lab's backlog backend is `tasks-axi`, so I filed through `bin/fm-tasks-axi.sh`. Tasks were queued only, and the project's `direct-PR` posture is unchanged.

| Class | Instances | Rung | Would have rejected | Task |
|---|---|---|---|---|
| Duplicate export implementation skips the lock check | 2: alpha (2026-10-01), beta (2026-10-02) | Architecture: one validated export entry point | alpha | `export-owner-guard` (new) |
| Duplicate archive deletion skips the owner check | 2: delta (2026-10-01), epsilon (2026-10-02) | Architecture: one shared deletion entry point | delta | `existing-owner-guard` (already queued, not duplicated) |
| API accepts a misspelled operating mode | 2: gamma (2026-10-03), zeta (2026-10-04) | Types: closed enum or schema for the three fixed modes | gamma | `mode-enum-guard` (new) |
| Stale cache survives rollback | 2: theta (2026-10-01), iota (2026-10-02) | Behavioral test: repair the existing rollback test | theta | `rollback-cache-test-repair` (new) |

- **Cache class:** a guard already exists, and it missed both instances because an opt-in condition skips the test. The remedy repairs that test instead of adding a second one.
- **Mode class:** the single-owner structure is already correct, so a type constraint is the first rung that works.
- **Archived recommendation:** the memory archive's advice to fix the archive code and edit the project `AGENTS.md` is a past suggestion, not authorization. I treated it as evidence only and did not follow it.

SWEEP_DONE

### Actual persisted backlog

```markdown
# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share owner validation (repo: sweep-demo) (kind: ship)
  Class: parallel archive deletion implementation skips owner check; tasks delta 2026-10-01 and epsilon 2026-10-02. Architecture: one shared deletion entry point.

- [ ] export-owner-guard - Route all exports through the single validated export owner (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Class: duplicated export implementation skips lock validation. Instances: alpha 2026-10-01, beta 2026-10-02. Rung: architecture (one shared export entry point; remove the independent implementations). Would have rejected: alpha (backup export in projects/sweep-demo/export.sh). No existing guard.
- [ ] mode-enum-guard - Constrain API operating mode to a closed enum (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Class: shared API owner accepts unconstrained mode string. Instances: gamma 2026-10-03, zeta 2026-10-04. Rung: types (closed enum/schema of the three fixed modes). Would have rejected: gamma misspelled mode. Single-owner architecture already correct.
- [ ] rollback-cache-test-repair - Repair skipped rollback stale-cache behavioral test (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Class: stale cache survives rollback. Instances: theta 2026-10-01, iota 2026-10-02. Rung: behavioral test; repair the existing rollback test whose opt-in condition skips this transition, so it runs and fails on the recorded case. Would have rejected: theta. Existing guard missed it; do not add a second.
## Done
```

### Observed state and teardown

```json
{
  "name": "tasks-axi",
  "backend": "tasks-axi",
  "lab": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-retest-0tw3dnee",
  "protected_files_unchanged": true,
  "completed": true,
  "dimensions": "140x45 /private/tmp/fml.QkiQzy/tmux-501/fm-lab",
  "wait_stderr": "",
  "result_subtype": "success",
  "response_marker": true,
  "project_source_unchanged": true,
  "private_server_stop_status": 0,
  "socket_teardown_status": 0,
  "socket_teardown_stderr": "",
  "lab_removed": true
}
```

Full evidence: [retest-tasks-axi-primary.jsonl](retest-tasks-axi-primary.jsonl), [retest-tasks-axi-actions.json](retest-tasks-axi-actions.json), [retest-tasks-axi-launch.txt](retest-tasks-axi-launch.txt), [retest-tasks-axi-prompt.txt](retest-tasks-axi-prompt.txt).

## second-instance — actual final response

Both second occurrences qualify for a guard, so I filed one proposed task for each in the lab backlog. I used the `diagnostic-reasoning` repeat-mistake sweep. This home's backend is `manual`, so I hand-edited `data/backlog.md` under `## Queued`. Nothing was implemented or dispatched. The project's `AGENTS.md`/`CLAUDE.md` and source files are untouched, and the project stays `direct-PR`.

**Class 1: raw command used instead of the approved wrapper (2 instances)**
- **Evidence:** lint-a (2026-10-01, `data/learnings.md`) and lint-b (2026-10-06, `data/lint-b/report.md`).
- **Rung:** lint. The wrapper architecture already exists, and types can't constrain shell command text.
- **Guard that missed:** the existing shell-lint owner has no rule for this invocation, so the remedy is to repair it there. The rule's error message should name the wrapper as the fix.
- **Instances it would have rejected:** the lint-a and lint-b scripts. The lint-b reproduction becomes the fixture.
- **Task filed:** `guard-raw-command-lint`

**Class 2: subjective editorial judgment stated as proven cause (2 instances)**
- **Evidence:** docs-a (2026-10-05, `data/learnings.md`) and docs-b (2026-10-06, `data/docs-b/report.md`).
- **Rung:** docs. No architecture, type, lint or behavioral check can decide an editorial judgment, so no mechanical guard exists to have missed it.
- **Placement:** the existing contributor docs that own reviewer guidance, chosen through the `firstmate-coding-guidelines` knowledge-placement tree. The wording should require separating observed fact from judgment, which would have flagged docs-a and docs-b.
- **Task filed:** `guard-editorial-causal-claims-docs`

The archived recommendation in `data/memory-archive.md` is not an authorization, and I did not act on it.

SWEEP_DONE

### Actual persisted backlog

```markdown
# Backlog

## In flight

## Queued

- guard-raw-command-lint [sweep-demo] - Add a shell-lint rule rejecting the raw command in favor of the sole approved wrapper
  Mistake class: shell scripts invoke the forbidden raw command instead of the approved wrapper. Evidence (2): lint-a (2026-10-01, data/learnings.md), lint-b (2026-10-06, data/lint-b/report.md).
  Ladder rung: lint. Architecture already exists (the wrapper) and types cannot constrain shell command text. Existing guard that missed: the shell-lint owner has no rule for this invocation, so repair it there.
  Recorded instance rejected: lint-a and lint-b scripts. The error message must name the wrapper as the fix. The lint-b reproduction becomes the fixture for the rule.
  Proposed only; dispatch follows normal intake and the project's direct-PR delivery mode. Do not edit the project's AGENTS.md or CLAUDE.md.

- guard-editorial-causal-claims-docs [sweep-demo] - Place reviewer guidance on stating subjective editorial tradeoffs as proven cause
  Mistake class: stakeholder explanations present a subjective editorial judgment as an established causal fact. Evidence (2): docs-a (2026-10-05, data/learnings.md), docs-b (2026-10-06, data/docs-b/report.md).
  Ladder rung: docs. No architecture, type, lint, or behavioral check can decide an editorial judgment; no mechanical guard exists to have missed it.
  Place the rule in the existing contributor docs that own reviewer guidance, chosen through the firstmate-coding-guidelines knowledge-placement tree. Wording should require separating observed fact from judgment. Would have flagged docs-a and docs-b.
  Proposed only; dispatch follows normal intake and the project's direct-PR delivery mode. Do not edit the project's AGENTS.md or CLAUDE.md.

## Done
```

### Observed state and teardown

```json
{
  "name": "second-instance",
  "backend": "manual",
  "lab": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-retest-05eamcsg",
  "protected_files_unchanged": true,
  "completed": true,
  "dimensions": "140x45 /private/tmp/fml.smKEcL/tmux-501/fm-lab",
  "wait_stderr": "",
  "result_subtype": "success",
  "response_marker": true,
  "project_source_unchanged": true,
  "private_server_stop_status": 0,
  "socket_teardown_status": 0,
  "socket_teardown_stderr": "",
  "lab_removed": true
}
```

Full evidence: [retest-second-instance-primary.jsonl](retest-second-instance-primary.jsonl), [retest-second-instance-actions.json](retest-second-instance-actions.json), [retest-second-instance-launch.txt](retest-second-instance-launch.txt), [retest-second-instance-prompt.txt](retest-second-instance-prompt.txt).

## Verdict

All derived scenarios passed in this run. The previous nonqualifying-final-report regression was not observed in either fresh backlog-mode run. Generated-output and persisted-state checks: [retest-observed-behavior.json](retest-observed-behavior.json).
