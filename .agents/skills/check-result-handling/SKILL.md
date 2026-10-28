---
name: check-result-handling
description: Load on any `check:` wake before acting on its named result.
user-invocable: false
metadata:
  internal: true
---

# Check result handling

Resolve repository-relative paths and links below from the Firstmate repository root.

3. For `check:`, act on the named poll result, including merges, contribution signals, Relay events, process-to-event source results, open-work ledger rows (route each overdue row in `state/open-loops.json` to its owner; [`docs/configuration.md`](../../../docs/configuration.md#open-work-ledger-configopen-loopsjson) owns the contract), status-log size alarms ([`docs/configuration.md`](../../../docs/configuration.md#status-log-size-bounds-fm_status_cap_bytes)), and captain inbox notes; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
   A `check: secondmate <id> auto-relaunched` or `check: <id> auto-relaunched after session-end` wake records a recovery that already completed - reconcile the task's current state rather than relaunching again, and treat a repeat, failed, or paused wake as the signal to investigate why the agent keeps exiting.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.
