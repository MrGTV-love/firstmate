# The guard spec

This is the normative contract for every guard that can block, refuse, warn, or
silently fail an agent in Firstmate.
`data/guard-audit-2026-10-22.md` is the audit that produced it; this file is the
owner of the fields, the rules, the tiers, the event schema, and the retirement
threshold.

A guard that cannot fill these fields does not ship.

## Registry

The machine-readable registry is `docs/guards/registry.json`.
It is checked in, reviewed like code, and validated by `bin/fm-guard-lint.sh`.
The retirement changelog is `docs/guards/retired.json`, owned by the same lint.
The ratchet allowlist is `docs/guards/lint-allowlist.json`; it may only shrink.
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
8. **Every guard emits one event per decision.** An instrumented guard that
   emits no event, or that never fires across 30 real opportunities, enters the
   cut list at the next threshold. A guard is not exempt because it was hard to
   write.
9. **Every exemption is a demotion candidate.** A path or case exemption
   requires a derivation comment and an open demotion id. The lint reports the
   count per guard, because a guard with many exemptions is admitting its
   source is a proxy.

Rules 1, 2, 3, 4, 5, 6, 7, 8 and 9 are mechanically checked. A rule that
cannot be checked mechanically belongs in the reviewer's checklist, not here.

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
`bin/fm-guard-metrics.sh` is the single reader and the retirement-rule owner.
Turns-to-clear and tool-calls-to-clear are the real cost unit because an agent
clears the block; `override` is the strongest false-positive signal available
for free.

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
- `enforce --new-or-touched <base>` fails only for guards added or changed since
  the base, so new work cannot add debt.
- `enforce` fails on every violation not listed in the allowlist, and also fails
  on an allowlisted entry whose violation no longer occurs, because that entry
  is stale.

The allowlist therefore only shrinks, and an empty allowlist is the end state.
