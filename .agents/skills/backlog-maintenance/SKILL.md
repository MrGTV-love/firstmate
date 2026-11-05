---
name: backlog-maintenance
description: "Load before filing, holding, updating, archiving, or handing off backlog items or task notes, and on escalated open-work receipts whose output names no captain hold."
user-invocable: false
metadata:
  internal: true
---

# Backlog maintenance

A decision is simply a task held for the captain: create the task with `bin/fm-tasks-axi.sh add` (with `--objective`, below) when needed, then always hold it through `bin/fm-captain-hold.sh hold <id> --reason "<reason>"`, with `--until <date>` when the captain defers it and `--owner captain` in a secondmate home; a call the main firstmate owns is never held (`captain-hold-lifecycle` owns that rule).
When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item and hold it through that wrapper.
Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their completion gate and recorded-answer rules.

An escalated open-work receipt marked `standing: no` because no captain-held task was named has no proof it reached the captain: its unchanged row stays in the periodic waiting list as `escalated, no proof it reached the captain`, never as waiting on the captain.
Name the actual captain-held task with `--hold TASK_ID` rather than treating that receipt as a standing wait.

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it, always through `bin/fm-tasks-axi.sh` so the call reaches this home's backlog from any directory, and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.
Every `bin/fm-tasks-axi.sh add` names the objective it serves with `--objective O1` to `O7`, or `--objective none --objective-reason "<why>"`.
An add whose title overlaps an open or recently closed item is refused with its neighbours; answer with `--dup-of <kept-id>` when the work is the same, or `--not-dup <neighbour-id>` when it is different.
A duplicate or moved item closes with `done <id> --duplicate-of <kept-id>` or `done <id> --moved-to <home> <item-id>` on checked proof, but an item that quotes the captain, an open captain call, or an item with a live task still needs the captain's own words or its owner, and an item that still blocks an open item must have those dependents re-pointed first.
`docs/configuration.md` ("Backlog intake and closing proofs") owns both contracts.

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.

Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge to section 6 rather than scattering it through task notes.

## Backlog ownership and transitions

The configured `tasks-axi` backend is the durable queue; the tracked default is `data/backlog.md`.
It tracks work items only, never agents; persistent secondmates never appear as backlog items.
Work routed to a secondmate is recorded in that secondmate home's own backlog, not the main backlog.
When the automatic transition gate applies, dispatch and completion move the item themselves - `bin/fm-spawn.sh` and `bin/fm-teardown.sh` own those transitions and refuse rather than report success without them - so what remains yours is filing the item before dispatch, recording decisions, and keeping notes current; `docs/configuration.md` owns gate applicability and the manual-backend exception.
Work that lands under another task's pull request or a merge train still closes its item: the pull request body names it with a `Closes: <item-id>` line and `bin/fm-pr-merge.sh` closes it at merge, so do not wait for the owner's words to close such an item; `bin/fm-pr-closes-lib.sh` owns the syntax and `bin/fm-pr-close-items.sh` owns the reasons an item is reported as not closed.
Completing an item through `bin/fm-tasks-axi.sh`, teardown or an answered captain call also clears it from every other item's blocked-by list, so a dependent no longer needs a manual unblock.
