---
name: worker-steering
description: Load before steering a worker or secondmate, answering a keyed worker decision, retrying an unconfirmed steer, or relaying a changed task request.
user-invocable: false
metadata:
  internal: true
---

# Worker steering

Steer a worker with ordinary text through fail-closed `fm-send`: the message becomes a durable record in the task's steering inbox (multi-line text is legal, local and remote alike) and the worker's terminal receives only a doorbell line, with the watcher re-ringing an unacknowledged local message and escalating a stuck one (`bin/fm-task-inbox-lib.sh`; `bin/fm-send.sh` owns the typed-plane carve-outs).
A remote secondmate steer rides the same durable-inbox model through the remote transport; after an unconfirmed delivery, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe because it preserves the request body for remote enqueue deduplication (`bin/fm-send.sh` header).
When a steer answers an open keyed decision or blocker, pass `fm-send`'s `--resolve-key` so the answer itself closes that decision record at answer time, identically for local and remote workers (contract: `bin/fm-send.sh` header).

For the parent-owned correlation, recovery, and escalation contract on marked secondmate requests, see `bin/fm-pending-reply-lib.sh`.
When the captain adds or changes an ask mid-task, append the captain's words without added speaker labels or direct address to that brief's `## Captain's intent` and relay those words to the worker; Firstmate build constraints stay in `## Firstmate spec` or the steer.
