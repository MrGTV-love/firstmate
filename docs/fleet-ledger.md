# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, what their workers reported, when a PR became ready for review, when their work merged, and when they were cleaned up.
It is the stable, documented hook for firstmate status; this page is its contract.
It also holds the records the fleet's own scripts write at the moment they know them: when a backlog item was filed, when a task was closed and on what evidence, and who answered a decision.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the event names below                              |
| `task`  | The firstmate task id the record is about                 |

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.pr_ready`    | `pr`                                           | Firstmate records the task's PR as ready for review. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |
| `task.filed`       | `at`, `repo`, `kind`, `priority`               | `bin/fm-tasks-axi.sh add` or `bin/fm-captain-hold.sh hold` created a backlog item. |
| `task.closed`      | `at`, `evidence`, `pr`                         | A task's backlog item moved to Done on proof of its deliverable, through `bin/fm-teardown.sh`, the next session start's replay of a close teardown recorded, `bin/fm-tasks-axi.sh done`, or `bin/fm-captain-hold.sh` closing a captain-held item that teardown had kept open. |
| `task.answered`    | `at`, `via`, `key`, `answered_by`              | A decision was resolved: `fm-send.sh --resolve-key` closed it, or `fm-captain-hold.sh` recorded an answer or a reconciliation. |

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.pr_ready` members: `pr` is the PR's full URL.
It is written each time firstmate records a PR for the task, so registering a replacement PR, or the same PR again, writes another record; recording the PR again as part of merging it writes none.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

The three lifecycle events `task.filed`, `task.closed`, and `task.answered` are written by the scripts that already know the moment, so no lane, worker, or owner does anything to produce them.
Each also carries `at`, the same instant as `ts` in ISO 8601 UTC, such as `2026-10-18T17:04:05Z`.
An absent value is `null`.

`task.filed` members: `task` is the item id, including an id that `--mint` created; `repo`, `kind`, and `priority` are the values `tasks-axi` stored for the item (`priority` is a number), or `null` when the item has none.
A captain-hold item that `fm-captain-hold.sh hold` creates is recorded with `kind` `captain` and no `priority`.
An `add` of an id that already exists changes nothing, so `tasks-axi` reports it as already present and no record is written.

`task.closed` members: `evidence` is what the close used, one of `merged_pr` (the recorded PR), `local_main` (a local-only landing), `report` (a scout's report), `drop_file` (the captain's recorded drop), or `none`.
`pr` is the merged PR URL when `evidence` is `merged_pr`, and `null` otherwise.
The record is written once, after the backlog item is Done: a close is written once for each task, evidence, and `pr` since the task's latest `task.dispatched`, however many of these paths reach it, so a task that is reopened and dispatched again records its next close.
A refused teardown, a captain-held item that returns to Queued, and a `fm-tasks-axi.sh done` of an item that was already Done write none.
The close of a captain-held item is written by `bin/fm-captain-hold.sh` when its `answer` or `reconcile close` moves the item to Done, or when its `answer` records an item that was closed outside the script, and not by teardown, which only returns that item to Queued.
Its `evidence` and `pr` are the deliverable teardown recorded on the item in its current cycle, named the way teardown names them.
A reopen or a new dispatch of the item retires the deliverables of earlier cycles, so a reused task id records its own cycle's evidence.
An item with no recorded deliverable in its current cycle, such as a captain call that no teardown retained, records `none`.
A repeated answer writes none, and so does the next session start's replay of a kept item's pending record.

`task.answered` members: `via` is `send` when `fm-send.sh --resolve-key` closed a status-log decision, or `hold` when `fm-captain-hold.sh` recorded an answer for a captain-held task; `key` is the decision key (for `hold`, the task id).
`answered_by` is derived by the script and never typed.
For `send`, it is the role of the home that sent it: `main`, `main-afk` while an away record exists (`bin/fm-afk-contract.sh`), or `secondmate`.
A `hold` answered directly with `fm-captain-hold.sh answer --decision-file` takes the role of the home that ran the command, and so does one whose recorded source starts `a firstmate answer sent to `.
A `hold` whose recorded source starts `the captured result ` is `page`.
Anything else, including any other recorded source, a hold closed by `fm-captain-hold.sh reconcile close` (evidence closed it, so nobody answered), and an unreadable home identity, is the literal `unknown`.
The `hold` record is written as the call closes or is released, before the command's later checks, so a retry after an interruption adds none.
A replay of an answer that was already recorded writes none.
`bin/fm-captain-hold.sh` also writes the time and the answerer into the hold's "Resolution recorded" block as `Resolved at: <ISO 8601 UTC>` and `Answered by: <value>` lines, directly after the `Resolution mode:` line and any `Resolves hold set:` line, whether or not the ledger is on.
A replayed answer keeps the first block, so it keeps the first time; a reconciliation block carries the time but no `Answered by:` line, because evidence is not an answer.

Example:

```json
{"v":1,"ts":1790120000,"at":"2026-09-22T23:33:20Z","event":"task.filed","task":"fix-login","repo":"webapp","kind":"ship","priority":2}
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133410,"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133700,"at":"2026-09-23T03:21:40Z","event":"task.answered","task":"fix-login","via":"send","key":"api-shape","answered_by":"main"}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
{"v":1,"ts":1790133961,"at":"2026-09-23T03:26:01Z","event":"task.closed","task":"fix-login","evidence":"merged_pr","pr":"https://github.com/acme/webapp/pull/7"}
```

## Limits

- A worker using the current status command in its instructions records its line immediately after appending it, while the ledger is enabled.
  The supervision monitor's regular poll is the backstop: it records any line the immediate write missed, and does not record again a line that write already recorded.
  These lines still trail the status log by up to one poll interval, or until the monitor next runs when none is running:
  - lines firstmate itself writes to a task's status log, such as a recorded answer, a failed launch, a relayed pending reply, or a second mate's report line;
  - lines from workers whose instructions predate this, or that append without running the instruction's full command;
  - lines a remote second mate reports, which reach this home through firstmate's relay;
  - lines written while the immediate record fails, for example when the ledger file cannot be written.
  Recording `task.pr_ready`, `task.merged`, or `task.cleaned_up` first records that task's pending status lines.
- A write failure never changes the command it rides on: the command keeps its output and exit status, and the failed write costs one `fm-fleet-ledger: could not record ...` line on stderr.
- The lifecycle events are written when the command runs, not reconstructed later, so a command that ran while the flag was absent has no record of it.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in a live task's log are recorded on that task's next capture (which may be a worker status command, PR registration, merge, cleanup, or monitor poll); tasks dispatched or cleaned up while the flag was absent have no record of that.
- There is no sequence number and no gap detection.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- The file is never rotated and grows until truncated.
  To truncate it, stop reading, then empty it with `: > state/fleet-ledger.jsonl`; later records append to the empty file.
- The ledger copies status text verbatim from the home's `state/` directory and adds no scrubbing, so give its readers exactly the trust you give `state/`.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- relaunch events;
- whether a worker is currently working or idle, and when a turn ends; subscribe to the Herdr runtime's own `pane.agent_status_changed` events for that ([Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback));
- sequence numbers and gap detection;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines already contain, and privacy guarantees stronger than those of `state/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.
