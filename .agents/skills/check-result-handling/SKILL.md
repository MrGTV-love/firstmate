---
name: check-result-handling
description: Load on any `check:` wake before acting on its named result.
user-invocable: false
metadata:
  internal: true
---

# Check result handling

Resolve repository-relative paths and links below from the Firstmate repository root.

3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event source results, open-work ledger rows (follow the change-gated action and periodic captain-digest contract in [`docs/configuration.md`](../../../docs/configuration.md#open-work-ledger-configopen-loopsjson)), and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
   On `check: open-loop-ledger`, act on every row in `OVERDUE` (new, changed, or no longer covered). On `check: open-loop-ledger-resurface`, and only then, send the drain's `WAITING OPEN WORK` list to the captain as one periodic update, keeping every listed row's age, status, and last action; sending it is not proof that any escalation reached the captain, and a row stays `escalated, waiting on the captain` until it changes or its bound captain hold ends, which needs a new action.
   A `check: secondmate <id> auto-relaunched` or `check: <id> auto-relaunched after session-end` wake records a recovery that already completed - reconcile the task's current state rather than relaunching again, and treat a repeat, failed, or paused wake as the signal to investigate why the agent keeps exiting.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.
