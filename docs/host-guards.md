# Host guard framework

A host guard is a bounded, read-only local diagnostic that turns one class of resource or state pressure into a machine-readable audit record and a one-line verdict.
Guards exist so a supervision loop can distinguish a genuinely wedged worker from a host condition that merely looks like one, without granting any guard the power to change the system it measures.
This document owns the framework contract every guard family follows; each family's own script header owns its measured signals and thresholds.

## Shape

Each family ships as a pair plus its tests.
`bin/fm-<name>-guard.sh` is a thin wrapper that resolves its own directory and `exec`s the family engine with `python3`.
`bin/fm-<name>-guard.py` is the engine: it measures, classifies, and prints.
`tests/fm-<name>-guard.test.sh` drives the engine through its public CLI and asserts observable output, never engine source text.

The memory family is `fm-mem-guard`; its engine header owns Linux/macOS sources, metric interpretation, and command budget.
It makes no Jev, model, or network call, so its former `fm-jev-mem-guard` name has been removed rather than kept as an alias.

The process family is `fm-proc-guard`; its engine header owns the count semantics, thresholds, and census document.
Only its `check` command follows the one-shot verdict contract below.
Its `census` command writes a diagnostic artifact, while `watch` is the long-running, fork-free sampling mode.
The [adapter header](../bin/fm-procevent-proc.sh) owns bootstrap arming, shared episode placement, and the interrupted-capture handoff caveat; [process-event configuration](configuration.md#process-to-event-sources-stateprocevent) owns standing-source lifetime.
Behavioral coverage in `tests/fm-proc-guard.behavior.test.py`, `tests/fm-procevent-proc.test.sh`, and the bootstrap arming case in `tests/fm-bootstrap.test.sh` exercise real-UID accounting, privacy, fixed threshold boundaries, watcher-free lifetime, durable capture/wake delivery, cross-home episode suppression, and override-only home routing.

## Engine contract

- Read-only diagnostics: a guard never changes the system it measures and never mutates agent, session, or repository state except for diagnostic artifacts expressly owned by its engine header.
- Fail-open verdicts: permission errors, missing pseudo-files, and virtualized-environment gaps degrade to a graceful `UNKNOWN` verdict with a reason, never a false alarm.
- One-shot verdict reads: a check does not enter a polling loop; each family's engine header owns its source budgets.
- Structured verdict output: `--json` on a verdict read prints one JSON object with `name`, `checked_at`, `status`, `recommendation`, and the family's own measured fields; human output is a short list of the same facts.
- Deterministic verdict classification: `status` is one of `OK`, `WARNING`, `CRITICAL`, or `UNKNOWN` - the last only when fail-open withholds the verdict; thresholds live in the engine and are named in its header so a reader can audit the verdict.

## Verdict semantics

- `OK` means the measured condition is healthy and the caller should continue unchanged.
- `WARNING` means the condition is degraded but explained; the caller records it and continues.
- `CRITICAL` means the condition explains worker silence; the caller should not escalate a wedge while it holds.
- A guard never recommends a destructive action; `recommendation` is diagnostic text for the operator, not a command.

## Adding a family

Copy the smallest existing pair, keep the wrapper under ten lines, and keep every threshold in the engine with a comment naming the resource it bounds.
Add the family's behavioral test alongside it and run it through `bin/fm-test-run.sh`.
A family that needs a host-specific source (a fleet registry, a pool manager, a quota service, or a product's hook store) belongs to the operator's own layer, not this framework.
