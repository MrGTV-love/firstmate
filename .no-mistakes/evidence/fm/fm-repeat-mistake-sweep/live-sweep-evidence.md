# Repeat-mistake sweep — live product evidence

Three real Claude CLI primaries ran from the assigned worktree in marked disposable FM_HOME fixtures. All lab homes and their private tmux servers/socket caches were torn down. No unit suite, lint, formatter, static analyzer, pipeline, PR or CI phase was run.

## Resolved setup issue
A workspace-contained TMUX_TMPDIR exceeded the Unix socket path limit (`File name too long`). The supported `bin/fm-lab-home.sh tmux-dir` helper provided a disposable short runtime socket cache, torn down through its matching helper contract. Lab data stayed inside the worktree. Each primary had a 140×45 terminal. These were print-mode CLI checks, not a changed visual UI; text transcripts and persisted backlog output are the relevant product evidence.

## manual: actual primary response

I read the trigger index, which pointed to `diagnostic-reasoning` → **Repeat-mistake sweep**. Four mistake classes qualify (each has two or more instances from different tasks). I filed three new guard tasks by hand-editing `data/backlog.md` in the lab, because the backlog backend there is set to `manual`. Nothing was dispatched, and sweep-demo's direct-PR delivery mode is unchanged. No code, AGENTS.md or CLAUDE.md was edited.

| Class | Evidence (all from `data/learnings.md`) | Rung | Instance it would have rejected | Task ID |
|---|---|---|---|---|
| Export implemented a second time, skipping the lock check | alpha 2026-10-01, beta 2026-10-02 | 1. Architecture: one lock-checked export entry point | alpha (backup export) | `export-single-owner-guard` (new) |
| API accepts a misspelled operating mode | gamma 2026-10-03, zeta 2026-10-04 | 2. Types: closed enum of the three modes. Architecture doesn't apply because a single owner already exists. | gamma's misspelled mode | `operating-mode-enum-guard` (new) |
| Stale cache survives rollback | theta 2026-10-01, iota 2026-10-02 | 4. Behavioral test: repair the existing rollback guard, which was disabled or skipped by an opt-in condition. Architecture, types and lint can't express this environment-dependent transition. | theta | `rollback-cache-guard-repair` (new) |
| Archive deletion implemented a second time, skipping the owner check | delta 2026-10-01, epsilon 2026-10-02 | 1. Architecture: one shared deletion entry point | delta | `existing-owner-guard` (already in the backlog, so I didn't file a duplicate) |

**Not qualifying:**
- **solo** (2026-10-04): the disk was full, which is a different cause from the export class, and it's a single instance.
- **one-task** (2026-10-03): the date-format mismatch is one event. Its scout report (`data/one-task/report.md`) and findings snapshot (`data/one-task/nm-review-findings.txt`) are copies of the same event, not more occurrences.
- **`data/memory-archive.md`**: this holds an earlier agent's suggestion to "fix the archive code now and add an AGENTS.md table". It isn't a captain request, so I treated it as evidence only and didn't act on it.
- **Other sources**: there are no `state/*.status` files. As instructed, I didn't query PRs or CI.

SWEEP_DONE

### Persisted lab backlog

```markdown
# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share the owner validation used by other destructive paths (repo: sweep-demo) (kind: ship)
  Recurring class: parallel archive deletion implementation omits owner check. Evidence tasks delta and epsilon. Remedy architecture: one shared deletion entry point.
- [ ] export-single-owner-guard - Route all export paths through the one lock-checked export owner and remove duplicate export entry points (repo: sweep-demo) (kind: ship)
  Recurring class: independent export implementation omits lock validation. Evidence tasks alpha (2026-10-01, backup export) and beta (2026-10-02, batch export). Remedy architecture: one export entry point; would have rejected alpha's independent backup export. No existing guard. Excludes solo (disk full, different cause).
- [ ] operating-mode-enum-guard - Replace the unconstrained operating-mode string with a closed schema enum of the three supported modes (repo: sweep-demo) (kind: ship)
  Recurring class: API accepts misspelled operating mode. Evidence tasks gamma (2026-10-03) and zeta (2026-10-04). Remedy types: closed enum rejects gamma's misspelled mode before execution; architecture does not apply since one shared owner already exists. No existing guard.
- [ ] rollback-cache-guard-repair - Repair the existing rollback behavioral guard so its opt-in condition cannot skip the stale-cache rollback transition (repo: sweep-demo) (kind: ship)
  Recurring class: stale cache survives rollback. Evidence tasks theta (2026-10-01) and iota (2026-10-02). Remedy behavioral test: repair the existing rollback guard, which missed theta and iota because it was disabled/skipped by an opt-in condition; no new test or prose. Architecture, types and lint cannot express the environment-dependent transition.

## Done
```

### Observed state checks

```json
{
  "backend": "manual",
  "finished": true,
  "dimensions": "140x45 /private/tmp/fml.tZAZPD/tmux-501/fm-lab",
  "pane": "PRIMARY_EXIT:0\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n",
  "protected_files_unchanged": true,
  "project_source_unchanged": true
}
```

### Actual tool calls

```json
[
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; ls; find .fm-lab-sweep-09xglwxr -maxdepth 4 | head -100; ls skills 2>/dev/null; find . -path ./.git -prune -o -iname '*trigger*' -print | head",
      "description": "Explore worktree, lab, and skill index"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; ls -R .agents/skills/agent-skill-trigger-index; cat .agents/skills/agent-skill-trigger-index/*.md; ls .agents/skills",
      "description": "Read trigger index"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; ls -R .agents/skills/diagnostic-reasoning; cat .agents/skills/diagnostic-reasoning/*.md",
      "description": "Read diagnostic-reasoning skill"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-sweep-09xglwxr; for f in .fm-lab-home config/* state/.fm-lab-tmux-dir data/*.md data/one-task/* projects/sweep-demo/*; do echo \"=== $f\"; cat \"$f\"; done; ls -la state",
      "description": "Read all lab data"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; grep -n -i -A40 'required-tools-and-manual-mode\\|## Required tools and manual mode' docs/configuration.md | head -120",
      "description": "Read manual backlog backend contract"
    }
  },
  {
    "tool": "Edit",
    "input": {
      "replace_all": false,
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-sweep-09xglwxr/data/backlog.md",
      "old_string": "  Recurring class: parallel archive deletion implementation omits owner check. Evidence tasks delta and epsilon. Remedy architecture: one shared deletion entry point.\n",
      "new_string": "  Recurring class: parallel archive deletion implementation omits owner check. Evidence tasks delta and epsilon. Remedy architecture: one shared deletion entry point.\n- [ ] export-single-owner-guard - Route all export paths through the one lock-checked export owner and remove duplicate export entry points (repo: sweep-demo) (kind: ship)\n  Recurring class: independent export implementation omits lock validation. Evidence tasks alpha (2026-10-01, backup export) and beta (2026-10-02, batch export). Remedy architecture: one export entry point; would have rejected alpha's independent backup export. No existing guard. Excludes solo (disk full, different cause).\n- [ ] operating-mode-enum-guard - Replace the unconstrained operating-mode string with a closed schema enum of the three supported modes (repo: sweep-demo) (kind: ship)\n  Recurring class: API accepts misspelled operating mode. Evidence tasks gamma (2026-10-03) and zeta (2026-10-04). Remedy types: closed enum rejects gamma's misspelled mode before execution; architecture does not apply since one shared owner already exists. No existing guard.\n- [ ] rollback-cache-guard-repair - Repair the existing rollback behavioral guard so its opt-in condition cannot skip the stale-cache rollback transition (repo: sweep-demo) (kind: ship)\n  Recurring class: stale cache survives rollback. Evidence tasks theta (2026-10-01) and iota (2026-10-02). Remedy behavioral test: repair the existing rollback guard, which missed theta and iota because it was disabled/skipped by an opt-in condition; no new test or prose. Architecture, types and lint cannot express the environment-dependent transition.\n"
    }
  }
]
```

## tasks-axi: actual primary response

I ran the `diagnostic-reasoning` sweep procedure. Four classes qualified with two or more instances from different tasks. Three got new tasks and one already had a queued task. Nothing was dispatched, and nothing was written outside the lab.

The only evidence sources were `data/learnings.md` and `data/memory-archive.md`. The lab has no status events, no PRs and no CI runs. The `memory-archive.md` entry is a quoted past recommendation to fix code and edit `AGENTS.md`. It is not a captain request and I did not act on it.

| Class | Evidence (source: `learnings.md`) | Rung | Instance rejected | Existing guard that missed | Task |
|---|---|---|---|---|---|
| Export bypasses the lock check | alpha (2026-10-01), beta (2026-10-02) | Architecture: one lock-checked export entry point | alpha | none | `export-owner-guard` (new) |
| Misspelled API operating mode | gamma (2026-10-03), zeta (2026-10-04) | Types: closed schema enum of the three modes | gamma | none | `mode-enum-guard` (new) |
| Archive deletion skips owner validation | delta (2026-10-01), epsilon (2026-10-02) | Architecture: one shared deletion entry point | delta | none | `existing-owner-guard` (already queued, no duplicate filed) |
| Stale cache survives rollback | theta (2026-10-01), iota (2026-10-02) | Behavioral test: repair the existing guard | theta | the rollback behavioral test, disabled by an opt-in condition and skipped | `rollback-cache-guard-repair` (new) |

The `solo` (disk full) and `one-task` (UI date format) entries did not qualify, since each is a single task. The `one-task` event appears in `learnings.md`, its scout report and its findings snapshot, but all three are the same event.

The new tasks are in Queued in the lab backlog, added through `bin/fm-tasks-axi.sh`. The project's direct-PR delivery mode is unchanged.

SWEEP_DONE

### Persisted lab backlog

```markdown
# Backlog

## In flight

## Queued

- [ ] existing-owner-guard - Make archive deletion share the owner validation used by other destructive paths (repo: sweep-demo) (kind: ship)
  Recurring class: parallel archive deletion implementation omits owner check. Evidence tasks delta and epsilon. Remedy architecture: one shared deletion entry point.

- [ ] export-owner-guard - Route backup and batch export through the single lock-checked export owner (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Recurring class: independent export implementations omit the lock check. Evidence: alpha (2026-10-01, backup export), beta (2026-10-02, batch export). Rung: architecture - one export entry point. Instance rejected: alpha. No existing guard missed. Sweep-filed; do not dispatch without normal intake; direct-PR delivery.
- [ ] mode-enum-guard - Constrain API operating mode to a closed schema enum of the three supported modes (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Recurring class: API accepts misspelled operating mode via unconstrained string. Evidence: gamma (2026-10-03), zeta (2026-10-04). Rung: types - closed schema enum (architecture cannot help: one shared owner already exists). Instance rejected: gamma. No existing guard missed. Sweep-filed; direct-PR delivery.
- [ ] rollback-cache-guard-repair - Repair the rollback behavioral test so it runs unconditionally for the stale-cache transition (repo: sweep-demo) (kind: ship) (since 2026-10-06)
  Recurring class: stale cache survives rollback. Evidence: theta (2026-10-01), iota (2026-10-02). Rung: behavioral test - repair the existing guard, which was disabled by an opt-in condition / skipped and missed both instances. Instance rejected: theta. Sweep-filed; direct-PR delivery.
## Done
```

### Observed state checks

```json
{
  "backend": "tasks-axi",
  "finished": true,
  "dimensions": "140x45 /private/tmp/fml.Ufau1t/tmux-501/fm-lab",
  "pane": "PRIMARY_EXIT:0\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n",
  "protected_files_unchanged": true,
  "project_source_unchanged": true
}
```

### Actual tool calls

```json
[
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; ls; ls -R .fm-lab-sweep-xg3svmt5 | head -100; grep -ril \"trigger\" --include=*.md . 2>/dev/null | grep -i skill | head -20"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; ls skills; grep -rli \"trigger index\" skills AGENTS.md docs | head"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; grep -n -i -B2 -A15 \"trigger index\" AGENTS.md | head -60; find skills | head -50"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; grep -rl \"repeat-mistake\" . --exclude-dir=.git --exclude-dir=.fm-lab-sweep-xg3svmt5 | head; ls -a ~/.claude/skills 2>/dev/null | head"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; grep -n -i \"repeat-mistake\" .agents/skills/agent-skill-trigger-index/SKILL.md; cat .agents/skills/diagnostic-reasoning/SKILL.md; ls .agents/skills/diagnostic-reasoning"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; L=.fm-lab-sweep-xg3svmt5; cat $L/config/*; for f in learnings memory-archive backlog done-archive projects; do echo \"=== $f\"; cat $L/data/$f.md; done; echo ===; cat $L/data/one-task/*; ls -la $L/state $L/data; cat $L/projects/sweep-demo/*; sed -n '/required-tools-and-manual-mode/,+40p' docs/configuration.md | head -80"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; L=.fm-lab-sweep-xg3svmt5; cat $L/data/one-task/*; ls -la $L/state; cat $L/projects/sweep-demo/*; grep -n -A40 \"required-tools-and-manual-mode\\|## Required tools\" docs/configuration.md | head -90; sed -n 1,60p bin/fm-tasks-axi.sh"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; export FM_HOME=$PWD/.fm-lab-sweep-xg3svmt5; bin/fm-tasks-axi.sh add --help 2>&1 | head -40"
    }
  },
  {
    "tool": "Bash",
    "input": {
      "command": "cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P; export FM_HOME=$PWD/.fm-lab-sweep-xg3svmt5; T=bin/fm-tasks-axi.sh\n$T add export-owner-guard \"Route backup and batch export through the single lock-checked export owner\" --kind ship --repo sweep-demo --queue --body \"Recurring class: independent export implementations omit the lock check. Evidence: alpha (2026-10-01, backup export), beta (2026-10-02, batch export). Rung: architecture - one export entry point. Instance rejected: alpha. No existing guard missed. Sweep-filed; do not dispatch without normal intake; direct-PR delivery.\" 2>&1\n$T add mode-enum-guard \"Constrain API operating mode to a closed schema enum of the three supported modes\" --kind ship --repo sweep-demo --queue --body \"Recurring class: API accepts misspelled operating mode via unconstrained string. Evidence: gamma (2026-10-03), zeta (2026-10-04). Rung: types - closed schema enum (architecture cannot help: one shared owner already exists). Instance rejected: gamma. No existing guard missed. Sweep-filed; direct-PR delivery.\" 2>&1\n$T add rollback-cache-guard-repair \"Repair the rollback behavioral test so it runs unconditionally for the stale-cache transition\" --kind ship --repo sweep-demo --queue --body \"Recurring class: stale cache survives rollback. Evidence: theta (2026-10-01), iota (2026-10-02). Rung: behavioral test - repair the existing guard, which was disabled by an opt-in condition / skipped and missed both instances. Instance rejected: theta. Sweep-filed; direct-PR delivery.\" 2>&1\ncat $FM_HOME/data/backlog.md"
    }
  }
]
```

## second-instance: actual primary response

Both repeated mistake classes qualify for a guard, and I filed one backlog task for each. I only read files and edited the lab `data/backlog.md`. The home uses the manual backend, so I added the tasks by hand under `## Queued`. The backlog had no existing item for either class. Nothing was fixed or dispatched, and no tests or pipelines ran. The project's delivery mode is direct-PR.

**1. Raw shell command used instead of the sole approved wrapper**
- **Evidence (2 instances):** lint-a (learnings, 2026-10-01) and lint-b (`data/lint-b/report.md`, 2026-10-06).
- **Chosen guard:** rung 3, lint. Architecture already has a single wrapper owner, and types can't apply to shell text. The rule goes in the repository's existing shell-lint owner. Its error message names the wrapper as the fix.
- **Instance it would have rejected:** the lint-a script.
- **Existing guard that missed it:** none. No lint rule exists yet.
- **Task ID:** `guard-shell-raw-command-lint`

**2. Editorial tradeoff stated as an established causal fact**
- **Evidence (2 instances):** docs-a (learnings, 2026-10-05) and docs-b (`data/docs-b/report.md`, 2026-10-06).
- **Chosen guard:** rung 5, docs. Editorial judgment can't be honestly checked by architecture, types, lint or a behavioral test. The task adds reviewer guidance to the existing contributor docs, placed through the `firstmate-coding-guidelines` knowledge-placement tree. Guidance doesn't guarantee rejection.
- **Instance it addresses:** the docs-a explanation.
- **Existing guard that missed it:** none.
- **Task ID:** `guard-editorial-tradeoff-reviewer-guidance`

SECOND_INSTANCE_DONE

### Persisted lab backlog

```markdown
# Backlog

## In flight

## Queued

- guard-shell-raw-command-lint - Add a rule to the repository's existing shell-lint owner that rejects the forbidden raw command and whose error message names the sole approved wrapper as the fix.
  Class: shell script uses the forbidden raw command instead of the sole wrapper. Instances: lint-a (learnings 2026-10-01), lint-b (data/lint-b/report.md, 2026-10-06). Ladder rung 3 (lint); rungs 1 and 2 cannot apply to shell text, and the wrapper owner already exists. It would have rejected the lint-a script. No existing lint rule covers this, so nothing missed it. Dispatch follows normal intake and the project's delivery mode (direct-PR).
- guard-editorial-tradeoff-reviewer-guidance - Add reviewer guidance to the existing owned contributor docs, placed through the firstmate-coding-guidelines knowledge-placement tree: a subjective editorial tradeoff must not be stated as an established causal fact.
  Class: stakeholder explanation presents editorial judgment as proven cause. Instances: docs-a (learnings 2026-10-05), docs-b (data/docs-b/report.md, 2026-10-06). Ladder rung 5 (docs) because no deterministic guard can validate editorial judgment; guidance is not a guarantee of rejection. It addresses the docs-a explanation. No existing guard missed. Dispatch follows normal intake and the project's delivery mode (direct-PR).

## Done
```

### Observed state checks

```json
{
  "finished": true,
  "pane": "PRIMARY_EXIT:0\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n",
  "protected_files_unchanged": true
}
```

### Actual tool calls

```json
[
  {
    "tool": "Glob",
    "input": {
      "pattern": "**/*",
      "path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk"
    }
  },
  {
    "tool": "Glob",
    "input": {
      "pattern": "**/diagnostic-reasoning/**"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.agents/skills/diagnostic-reasoning/SKILL.md"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/backlog.md"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/learnings.md"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/memory-archive.md"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/lint-b/report.md"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/docs-b/report.md"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/config/backlog-backend"
    }
  },
  {
    "tool": "Read",
    "input": {
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/projects.md"
    }
  },
  {
    "tool": "Grep",
    "input": {
      "pattern": "manual",
      "path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/docs/configuration.md",
      "output_mode": "content",
      "-C": 4
    }
  },
  {
    "tool": "Grep",
    "input": {
      "pattern": "^- \\[|^- [a-z0-9-]+ [-\u2014]|backlog item|Item format|item format",
      "path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/docs/configuration.md",
      "output_mode": "content",
      "head_limit": 15
    }
  },
  {
    "tool": "Grep",
    "input": {
      "pattern": "^## Queued",
      "path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P",
      "glob": "*.md",
      "output_mode": "content",
      "-A": 4,
      "head_limit": 20
    }
  },
  {
    "tool": "Edit",
    "input": {
      "replace_all": false,
      "file_path": "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49Z3B3TFV91CVVRFACHNT5P/.fm-lab-repeat-yn6ovivk/data/backlog.md",
      "old_string": "## Queued\n",
      "new_string": "## Queued\n\n- guard-shell-raw-command-lint - Add a rule to the repository's existing shell-lint owner that rejects the forbidden raw command and whose error message names the sole approved wrapper as the fix.\n  Class: shell script uses the forbidden raw command instead of the sole wrapper. Instances: lint-a (learnings 2026-10-01), lint-b (data/lint-b/report.md, 2026-10-06). Ladder rung 3 (lint); rungs 1 and 2 cannot apply to shell text, and the wrapper owner already exists. It would have rejected the lint-a script. No existing lint rule covers this, so nothing missed it. Dispatch follows normal intake and the project's delivery mode (direct-PR).\n- guard-editorial-tradeoff-reviewer-guidance - Add reviewer guidance to the existing owned contributor docs, placed through the firstmate-coding-guidelines knowledge-placement tree: a subjective editorial tradeoff must not be stated as an established causal fact.\n  Class: stakeholder explanation presents editorial judgment as proven cause. Instances: docs-a (learnings 2026-10-05), docs-b (data/docs-b/report.md, 2026-10-06). Ladder rung 5 (docs) because no deterministic guard can validate editorial judgment; guidance is not a guarantee of rejection. It addresses the docs-a explanation. No existing guard missed. Dispatch follows normal intake and the project's delivery mode (direct-PR).\n"
    }
  }
]
```

## Acceptance mismatch observed
Both captain-requested runs excluded single-instance classes from guard-task filing, but included them in the final user-facing report. The manual response has a **Not qualifying** section reporting `solo` and `one-task`; the tasks-axi response likewise reports those two nonqualifying classes. This conflicts with the recorded R3 decision to limit the final class report to qualifying repeated mistakes. These are observations of emitted model output, not source-string assertions.
