# The guard spec

This is the normative contract for every guard that can block, refuse, warn, or
silently fail an agent in Firstmate.
`data/guard-audit-2026-10-22.md` is the audit that produced it; this file is the
owner of the fields, the rules, the tiers, the event schema, and the retirement
threshold.

A guard that cannot fill these fields does not ship.
This file is also the single owner of the bad-guard policy below.

## Policy statement

A guard exists to stop one named harm, and it must test that harm, not a stand-in for it.
When a guard blocks work the owner wants, the guard is the defect.
Nobody routes around it, nobody adds a bypass flag, and nobody offers "loosen it" as a choice.
First, find and fix the process that keeps producing the blocked situation.
Then change the guard so it tests the real safety property, or remove it when the harm is gone or it costs more than it saves.
Widening a guard is not a fix, because it keeps the wrong test.
Every refusal names the proof it accepts and the step that finishes the work.
Every refusal and every escape is logged, so a bad guard shows in the numbers before anyone has to notice it.

## Bad-guard handling

Here, Main means the supervising firstmate and the owner means the captain, not the implementation file named by the registry's `owner` field.

### When a guard is flagged bad

Any one of these flags a guard for review:

- A bypass, waiver, force or environment escape is used.
- A refusal is cleared by an action that changes nothing real, such as a merge commit whose tree equals its first parent's, or a re-run.
- A widening PR is opened.
- The same task and rule are denied again after a clear.
- A refusal names no completing step.
- A deny-only guard cannot be measured.
- Metrics nominate a cut.
- Someone reports a misfire.

### Who decides

Main triages in the same session: a one-line misfire report to the owner, and a backlog item naming the guard id and rule.
Main decides **Keep**, **Redesign** or **Remove** on the owner's criteria:

- Harm: severity and likelihood.
- Reversibility.
- Who acts on the refusal: a prompt to a headless worker acts as a deny.
- Cost: false blocks, delay and invited workarounds.
- Real catches.
- Overlap, including whether one better check can replace several.

Record the decision in `data/<id>/report.md` and the registry's `retirement_decision`.
The owner decides when a change alters an `AGENTS.md` hard rule or accepts more irreversible risk, such as redefining "landed" for teardown.
Delivery follows the normal PR path; the [shared review rubric](review-rubric.md#review-outcomes) owns the review's widening-without-reassessment failure rule.
A reassessment is not permission to keep the wrong test by widening it; the policy statement governs the redesign.

### Required response

Follow the [policy statement's process-first order](#policy-statement), then redesign the guard to test the real property or remove it through the [cut procedure](#cut-procedure).
Meanwhile the blocked work takes the guard's named remedy or waits.
Never present a loosening as an option before the process fix, and never stack a second guard over a script that already makes the same check.
The [required detection](#required-detection) below makes misfires visible; a flag opens review, not an automatic guard disablement.

## Registry

The machine-readable registry is `docs/guards/registry.json`.
It is checked in, reviewed like code, and validated by `bin/fm-guard-lint.sh`.
The retirement changelog is `docs/guards/retired.json`, owned by the same lint.
The ratchet allowlist is `docs/guards/lint-allowlist.json`; it may only shrink.
`bin/fm-guard-sites.py` is the discovery helper the lint calls for every refusal site in the runtime code; "Refusal sites" below owns what it finds.
Guards registered after the audit are named in the registry's `beyond_audit_active` list, so `--counts` keeps the audited population arithmetic exact.

`bin/fm-guard-refcheck.sh` owns the wiring proof: every hook registration
resolves to a file that exists, every retired guard has zero live references,
and no removed guard is silently resurrected.

## Fields

```
id:            short-slug, unique, stable across renames of the owner
owner:         one host file, or one library the host sources, never "whoever wrote it"
invariant:     one sentence, one behavior, no "and"
layer:         impossible-by-construction | machine-check | runtime-block | runtime-warn | prose
source:        the exact authoritative path or command the decision reads
trigger:       the precise condition, with the values that make it true
decision:      allow | deny | warn, plus the fail direction when the source is unreadable
remedy:        the exact runnable command that clears it, expanded for this home
budget:        max consecutive blocks per turn, and what happens after
telemetry:     one event per decision, guard_id, decision, source_ok, elapsed_ms, cleared_by
test:          the fixture that proves both the block and the pass
```

Registry-only fields carry what the audit scores: `tier`, `harm`,
`exemptions`, `proxy`, `proxy_reason`, `precheck_gap`, `instrumented`, and
`emitters`. `emitters` lists host files that take the guard's decision and emit
its event when the invariant is defined in a library the host calls; the writer
call is then proven in the emitter rather than in the owner.
`sites` maps the guard to its refusal sites; see "Refusal sites".
An active guard added after the audit is named in the registry's
`beyond_audit_active`, and a retirement beyond the audit is listed in its
`beyond_audit_retired`; both stay outside the audited inventory that
`fm-guard-lint.sh --counts` balances against `audited`.

`retirement_decision` records the outcome, date and reason for the [bad-guard decision](#who-decides): `keep`, `redesign` or `cut` (Remove).
It is not limited to metrics nominations; any flag in that policy can require a decision.
For a metrics-nominated guard, recording it retires the nomination; a nominated guard without one is still waiting for judgment.

`remedy` is rendered text, not a pointer. Every remedy contains at least one
executable token: a repository path that exists, a `bin/` invocation, or a shell
command. Placeholders are `<angle-bracketed>` and name what the caller supplies.
A repository path in a remedy must exist when the lint runs. Home-private paths
under `config/`, `state/`, and `projects/` are named but not required to exist,
because the captain or the runtime creates them per home.

## The nine rules the lint enforces

1. **One invariant, one owner.** Two guards may not declare the same invariant.
   The lint compares normalized invariant strings and owner paths.
2. **No block without a remedy.** The remedy must contain an executable token,
   not only prose, and every repository path it names must exist.
3. **Name the source.** A proxy source is legal only with `proxy: true` and a
   `proxy_reason` that explains why the authoritative source is unavailable.
4. **Declare the fail direction.** Unreadable source is either `closed` or
   `open`, stated per guard, never defaulted silently.
5. **Declare a block budget.** One block per turn and at most three per episode
   is the default. After the budget, the guard warns and escalates to a human
   decision rather than looping.
6. **No post-hoc guard where a pre-check exists.** A guard that runs after the
   write carries `precheck_gap` naming why the condition was not knowable
   earlier, or it does not carry `layer: runtime-warn-after-write`.
7. **Wiring is tested.** Every owner path, test path, and hook registration
   resolves to an existing file; `bin/fm-guard-refcheck.sh` fails the build when
   one does not.
8. **Every Firstmate guard decision point emits one event per decision.** An instrumented guard that
   emits no event, or that never fires across 30 real opportunities, enters the
   cut list at the next threshold. A guard is not exempt because it was hard to
   write.
9. **Every exemption is a demotion candidate.** A path or case exemption
   requires a derivation comment and an open demotion id. The lint reports the
   count per guard, because a guard with many exemptions is admitting its
   source is a proxy.

Rules 1, 2, 3, 4, 5, 6, 7, 8 and 9 are mechanically checked. A rule that
cannot be checked mechanically belongs in the reviewer's checklist, not here.

## Refusal sites

A guard that lives only inside a script never got these fields, because nothing noticed it existed.
`bin/fm-guard-sites.py` therefore enumerates the refusal sites of the runtime code, and `bin/fm-guard-lint.sh` requires every one to map to a registry entry.
The scan covers `bin/`, `.claude/`, `.codex/`, `.cursor/`, `.dsh/`, `.grok/`, `.omp/`, `.opencode/` and `.pi/` (skipping test directories), plus every owner file the registry names.
In a git work tree it reads only the files git tracks or would track, so a git-ignored file is never a site.
A site is one code line that matches a signature outside comments, heredoc bodies and docstrings.
A docstring is a triple-quoted string that opens a block, as the first statement after a header line that ends in `:` (such as `def` or `class`) or at the top of a file; a triple-quoted string anywhere else, such as an exception message, is runtime text and is scanned line by line:

- `A` marker: the `REFUSED:` message marker that `bin/fm-refuse-lib.sh` prints.
  The marker is a site even inside a heredoc body or a Python triple-quoted string.
- `B` message: `refuse`, `refuses`, `refused` or `refusing` inside a string literal, as a whole word that is not part of a variable name or path.
  A string compared with `==` or `!=`, passed to `startswith` or `endswith`, or used as a shell `case` pattern, tests a value and is not a message.
- `C` helper call: a call to a function whose definition name has `refuse` as one of its underscore-separated words and does not end in `_text`, or is exactly `deny` or `block_stop`.
  The scan derives these names from the definitions in the code and prints them under `helpers`.
- `D` hook deny: a permission decision of deny, a decision field of deny or block, an object that sets `block: true` with a reason, `exit 2` alone on a line (or after `&&` or `||`) in a hook script outside a usage or argument-count check, or a `throw` in an opencode plugin.
  A hook script is a script a hook registration file names, or one whose file name says hook, pretool, posttool or turnend.
- `E` guard event: a call to `bin/fm-guard-event.sh` (or its `guard_event` wrappers) whose decision is not exactly `allow`.
  The decision is the writer's second argument (`<guard-id> <decision>`), or the first argument of a wrapper that takes the decision first.
  The call is split with shell quoting rules and ends at an unquoted `;`, `&`, `|`, `<`, `>`, parenthesis, lone closing brace, or `#` that starts a word.
  A quoted `}` or `|`, and a `#` inside a word, are literal arguments, so the guard id, a later option and a following command never decide.

A heredoc body is data unless its opener prints to stderr, in which case every body line is a message, or feeds `python`, `node`, `bun`, `deno` or `perl` (or is delimited by `PERL`), in which case the body is scanned as that language (a perl body with the shell rules, like a `.pl` file).
A site that carries none of these is outside the scan: a refusal expressed only as an exit code, or with a message that never uses the vocabulary, is not enumerated, and neither is a refusal inside a heredoc that writes a script to disk.
That limit is deliberate, because every error exit would be a site, and it is why a new guard should use `fm_refuse` or the `REFUSED:` marker.
The scan follows only Python triple-quoted strings across lines, so it does not reliably recognize the inner lines of a shell or JavaScript string that spans lines: some may be reported and others missed.
A refusal message should therefore stay on one line, or carry the `REFUSED:` marker on a line the scan does not read as a comment (one that starts with `#` in shell and Python, or with `//`, `*` or `/*` in JavaScript).

A site maps to a registry entry through the entry's `sites` list.
Each item names a `file` and a `match`, a fixed substring of the site's line, plus an optional `count` that defaults to 1.
The lint requires the item to match exactly `count` sites, so a new site that a marker would silently absorb changes the count and fails until a reviewer updates it.
Two entries may not map the same site, and a marker that matches nothing is stale.

A site's id is `site:<file>:<hash of its normalized line>`, so it survives line moves.
The lint computes the unregistered count as the number of sites that map to nothing.
A registry may carry a typed `unregistered_ids` list only if its length equals the computed count.

Rules 10 to 13 are mechanically checked on top of the nine rules above:

10. **S1** Every refusal site maps to a registry entry.
11. **S2** A `sites` item matches exactly the sites it declares, and no site has two owners.
12. **S4** A typed `unregistered_ids` list has the computed length.
13. **S5** The allowlist does not grow against the base (new-or-touched mode only).

## Tiers

Cost, 0 to 9:

- source quality: authoritative 0, proxy 1, unverifiable 2
- trigger precision: narrow 0, medium 1, broad 2
- remedy: exact actionable command 0, pointer only 1, none 2
- can block more than once in a row: +1
- shares its invariant with another guard: +1
- documented false-positive evidence: +1

Value is expected value, not nominal harm: irreversible 2, reversible 1, style
only 0, negative when the guard silently cannot fire and the gap is undocumented.

- **A, cut or repair**: style-only value; or reversible value at cost 5 or more;
  or unverifiable source at cost 3 or more.
- **B, fix the interface**: value 2 at cost 3 or more; or value 1 at cost 3 to 4.
- **C, keep**: value 2 at cost 2 or less; or value 1 at cost 2 or less.

A reversible action can still be expensive to reverse, such as a wasted worker
launch, so the cut threshold for reversible guards is cost 5, not cost 1.

## Instrumentation

One JSON line per decision, appended to `state/guard-events.jsonl`:

```json
{"ts":"2026-10-22T12:00:00Z","guard":"spawn-worktree-isolation","version":"1","system":"firstmate","session":"abc","decision":"deny","source_ok":true,"elapsed_ms":14,"cleared_by":"retry","repeat":1,"override":false}
```

`bin/fm-guard-event.sh` is the single writer.
`bin/fm-guard-metrics.sh` is the single reader and computes the retirement nominations defined in this file.
Turns-to-clear and tool-calls-to-clear are the real cost unit because an agent
clears the block; `override` is the strongest false-positive signal available
for free.

## Required detection

These are required detection targets, not a claim that all telemetry, detectors, lint or surfacing described here are already implemented.
The instrumentation example above describes the existing event shape; detection changes follow the normal PR path without changing guard permissions as part of this policy documentation.

### Events

`bin/fm-guard-event.sh` must add `rule` and `task` to the event schema.
The session key must be the task id or the home plus the harness session, never `pid-$$`.
Every waiver and force must pass `--override`, including `--allow-red`, `--allow-missing`, `--attended-override`, teardown `--force` and `--allow-api-key`.
Each bypass switch must emit a `bypass` event.
Deny-only emitters must also emit allow decisions so opportunities can be measured.
These requirements expose existing escapes; they do not authorize their use or new bypass flags.

### Metrics

`bin/fm-guard-metrics.sh` must report per rule, with refusal-to-bypass ratio defined as `(overrides + workaround signatures) / denies`.
It must count repeated denies per task across sessions and flag "deny-only" and "zero events in N days".

### Workaround detection

Heartbeat detection must be read-only and flag:

- A merge commit on a PR branch or train whose tree equals its first parent's.
- A PR head changed only by a base merge after a merge refusal.
- A widening PR, identified by the review record's `--widens-guard yes`.

### Lint

The site-level remedy check must require the printed refusal to carry an executable next step.
Shrink the S1 allowlist by registering families in batches.
The refusal-site scanner must detect exit-code-only credential denials; the current scanner limits are described under [Refusal sites](#refusal-sites).

### Surfacing

The session-start digest must surface the bypass ratio and repeat-deny counts above threshold, one line per guard.
Weekly adjudication of `state/friction.jsonl`, including unknown rows, must close the loop.

### Review thresholds

These thresholds are design choices, not measured findings:

- Any override or workaround signature opens a review item at once.
- Two adjudicated false blocks in seven days also open a review item.
- Never auto-disable a guard.

These review triggers do not wait for the opportunity minimum in the existing retirement nomination rule below.

## Retirement rule

A guard enters the cut list when any of these holds across at least 30 real
opportunities of the operation it inspects:

- zero denies and zero warns (it never fired)
- override rate above 20%
- median turns-to-clear greater than 3
- the same incident recurs after a clear

The only exception is irreversible harm, which exempts a guard from the first two
conditions and never from the third.

## Cut procedure

Every deletion ships a retirement test named for the guard id that asserts the
previously blocked action now passes, one changelog line in
`docs/guards/retired.json`, and one commit per guard inside a batched change.
`bin/fm-guard-refcheck.sh` then proves the id has zero live references.

## Ratchet

The lint runs in three modes:

- `report` prints violations and always exits 0.
- `new-or-touched --base <ref>` fails only for guards added or changed since
  the base, for refusal-site violations the allowlist does not hold, for refusal
  sites on a changed line, and for an allowlist that grew, so new work cannot add
  debt.
- `enforce` fails on every violation not listed in the allowlist, and also fails
  on an allowlisted entry whose violation no longer occurs, because that entry
  is stale.

The legacy refusal sites that map to nothing sit in the allowlist as `S1` entries, once, as the burn-down list.
Once the base allowlist is at `schema_version` 2, the lint also fails an entry the base does not hold, so the allowlist cannot grow.
The allowlist therefore only shrinks, and an empty allowlist is the end state.
A site on a changed line must map even when the allowlist holds it, because touching a legacy site is the moment to give it a guard entry.
CI runs `enforce` on every change and `new-or-touched` against the pull request base.
