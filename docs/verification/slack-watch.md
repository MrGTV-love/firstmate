# Slack watch verification

Date: 2026-10-22 (UTC); live read-only probe evidence below remains dated 2026-10-19.
Host: macOS arm64, shared operator host.
Validation tool: no-mistakes v1.86.1-private.f6.startup-deadline.20261008 (bb545cc).
No fixture opened a socket, created a real DM, bound the real source, armed the real poll, or posted to Slack.
Every Slack response came from `--replay` transcripts under `tests/fixtures/slack/`.
Fixture homes were created with `tests/fixtures/slack/make-home.sh <scenario> <tmpdir>`.

## Environment and commands

The canonical suite is `tests/fm-slack-watch.test.sh`, run as a single process under `nice -n 20`.
It invokes the real `fm-captain-hold.sh` intake and `tasks-axi` against each disposable home.
No repository-wide test run is claimed; each section below records the targeted command and observed result for one guarantee.
The 2026-10-22 targeted replay refresh ran `bash /Users/charlesabrooker/firstmate/bin/fm-proc-budget.sh -- python3 /Users/charlesabrooker/firstmate/bin/fm-duration.py run test.tests/fm-slack-watch.test.sh -- nice -n 20 bash bin/fm-test-run.sh tests/fm-slack-watch.test.sh --jobs 1`.
It printed `ok - all Slack watch checks` and `FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=1444534`.
The suite exercised DOD-01 through DOD-10, DOD-12 through DOD-17, S1 through S3, and X1 through X22; DOD-11, S4, and ACT-1 were not run.
The targeted commands below are the DoD's Verify commands with the fixture home exported as `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, and `FM_CONFIG_OVERRIDE`.

## Live read-only probe

Command: `auth.test` and `users.info` with the home token, followed by no other Slack call.

Observed granted scopes: `calls:read, calls:write, channels:history, channels:join, channels:manage, channels:read, channels:write.topic, chat:write, chat:write.public, files:write, groups:read, groups:write, im:history, im:write, reactions:read, reactions:write, users:read`.
`im:history`, `im:write`, `reactions:read`, `reactions:write`, and `users:read` were granted.
Reaction taps can therefore be read in a DM only insofar as these scopes permit; the probe did not create a DM, so actual DM readability was not exercised.
The first `users.info` probe for the configured owner id returned `ok: false` with `error: user_not_found`.
That failure was re-checked on 2026-10-19T01:14Z with the exact request form the client uses: `GET https://slack.com/api/users.info?user=<owner-id>` with `Authorization: Bearer <redacted>`.
The repeated call returned `ok: true`, so the earlier `user_not_found` no longer reproduces.
A read-only `users.list` with `limit=200` returned `ok: true` and `member_present: true` for the owner id, and `auth.test` reported the workspace team id the home is configured for.
The `users:read.email` scope was not granted, so no address was read; the owner id was confirmed by the member lookup and by the read-only `users.list`, which reported the member as the workspace owner.
Arming does not rely on `users.info`: it binds by recording the source and then proves reachability with `conversations.open` to the configured owner id, so no fallback lookup was added.
No token, email, or workspace identifier was printed or stored, and no real member or workspace identifier is committed: the fixtures and tests use synthetic ids.

## DOD-01 - one thread per open call

Command: `fm-slack-mirror.sh --replay tests/fixtures/slack/mirror/transcript.json`, then close `between`, then run it again.

Observed: 4 threads after the first run (`open-a`, `open-b`, `between`, `bad$id`), 4 after the second, one thread for `between`, and none for `already-closed`.
`bad$id` returns exit 2 from the open-state probe and is deliberately shown rather than hidden.
Result: pass.

## DOD-02 - complete card payload

Command: `fm-slack-mirror.sh --replay tests/fixtures/slack/card-payload/transcript.json`.

Observed: three cards, each with `Task:`, `Decision:`, `Recommendation:`, `Evidence:`, a line telling the captain to reply in the thread, a line saying `Messages typed in the main DM window are not read.`, and `If you both tap and type:`.
`with-options` carried `Recommendation: ship`, `Evidence: /tmp/evidence-with-options.md`, and a numbered option block.
`no-options` carried no option block.
`no-recommendation` rendered `Recommendation: none recorded` and `Evidence: none recorded` for its invalid evidence value.
Exactly two `none recorded` occurrences appeared across the three cards.
On 2026-10-22, the strengthened regression first failed before the repair with `not ok - DOD-02 oversized card lost its option block: missing [Options:]`.
After the repair, a fourth task with a 45,000-character body and a 45,000-character held question preserved all six required card parts: task id, decision/question, recommendation, evidence, both numbered options, and the disagreement rule.
Its rendered card stayed within 38,000 characters and omitted the `PRIVATE_TASK_BODY` sentinel from both the card and the resolution notice.
Answering that task closed it; its `Resolved: oversized-card` notice posted without a transport failure and the thread was retired.
A fifth task whose 5,000-character held question fits the budget was posted whole, with no `...` cut.
A staged notice of 45,000 characters was posted cut to the 38,000-character post bound, ending with `Full text remains in the local backlog.`, with no transport failure.
The replay double rejects any post over 40,000 characters, as Slack does.
Result: pass.

## DOD-03 - typed reply through the existing intake

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/typed-reply/transcript.json`.

Observed: one `closed: typed-call` line, no additional close line, and `fm-captain-hold.sh open typed-call` returned 1.
The recorded answer was `line one line with tab`, the intake's flattened single-line form of the multiline reply.
Result: pass.

## DOD-04 - one action answers an option

Commands: `fm-slack-mirror.sh` then `fm-slack-poll.sh` with `reaction-answer`, `single-char-answer`, and `free-nine`.

Observed: `reaction-answer` rendered `Affordance: reaction` and recorded `Answer: wait`, option 2's value, with `Answer as shown to the captain: Wait`, its label.
The unauthorized reaction for option 3, the unbound `heart` reaction, and the reaction on a non-card message were ignored.
`single-char-answer` rendered `Affordance: single-character` and recorded `Answer: wait` with the label `Wait`.
`free-nine` recorded `Answer: 9` as free text against a three-option card.
Result: pass.

## DOD-05 - allowlist is the authority boundary

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/allowlist/transcript.json`.

Observed: exactly one `closed: allow-a`; `allow-b`, `allow-c`, and `allow-d` still returned open.
The refused captures were an unknown user id, a bot-authored message with the allowlisted id, and a display-name match with a different user id.
With `FM_SLACK_ALLOWED_AUTHORS` empty the poll was off and printed nothing; with `oops` it printed `slack: refused: allowlist_unparseable`. Neither closed anything.
Result: pass.

## DOD-06 - intake refusals unchanged

Command: `tests/fm-slack-intake-unchanged.test.sh`.

One-time proof that the intake is unmodified: `git diff df6448846813245550010ba6c593a7a7b07389d7 -- bin/fm-captain-hold.sh` printed nothing and exited 0 (base commit against the working tree).
That diff is a landing-time check, not a permanent test, so a later branch may legitimately edit the intake.
The permanent test asserts behavior only: the reserved `reconcile` value, a task not held for the captain, and an unknown key are each refused or skipped, and the reserved value stays refused when `slack-dm` is bound.
Result: pass.

## DOD-07 - unmatched reply surfaces

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/unmatched/transcript.json`.

Observed: exactly one `check: slack 900.000001 - unmatched reply 900.000002`, zero `closed:` lines, and one outbound message in thread `900.000001`.
Two unmatched replies produced two distinct check lines.
Result: pass.

## DOD-08 - contradiction surfaces

Commands: `fm-slack-poll.sh` with `contradiction` and `contradiction-typed`, each polled again, then answered with a fresh typed reply; `reaction-answer` with a second reaction added and then removed; and `reaction-skipped` polled twice.

Observed: one `check: slack 900.000001 - conflicting signals: Abort vs Wait. Remove the :two: reaction, or type 2.`, zero `closed:` lines, and the call still open.
(a) Two contradictory typed replies produced one check line; the next poll printed nothing and recorded nothing; a fresh typed `3` then recorded `abort`.
(b) A typed reply plus a reaction produced one check line; the next poll printed nothing and posted nothing; a fresh typed `2` then recorded `wait`.
(c) Two different reactions produced one check line and one notice; later polls stayed silent; removing one reaction changed the reaction set and recorded the remaining option.
(d) A reaction the intake refused (`refused: typed-call`, call still open) was not submitted again by the next poll, and no second acknowledgement was posted.
The conflict notice in the thread named the remedy: `Remove the :two: reaction, or type 2.` for a reaction against a typed reply, `Please reply once.` for two typed replies, and `Remove all but one reaction.` for two reactions.
Two conflicting typed replies of 45,000 characters each produced one readable outbound notice under 1,200 characters and one notification no longer than 480 characters, both naming previews of both candidates and retaining `Please reply once.`.
The notice was measured from the outbound log, not from the incoming full-length replies sharing the thread.
No transport failure or answer was recorded.
Result: pass.

## DOD-09 - duplicate and cross-channel answers record once

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/duplicate/transcript.json` twice, then close `dup-c` with `fm-captain-hold.sh answer`, then replay once more.

Observed: `closed: dup-a` and `closed: dup-b` appeared once each in the first run.
The second run printed no `skipped:` line and no close line: a repeat poll reports only what it did, and the intake's replay detection keeps the single record.
Each task body held exactly one `Resolution recorded by fm-captain-hold.` record after all runs.
The third run printed no close line.
Result: pass.

## DOD-10 - resolution posted once

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/resolution/transcript.json` twice after closing `resolve-call` from the terminal.

Observed: one outbound message in thread `900.000001` after the first run and still one after the second.
A call closed by a Slack answer produced its acknowledgement and one resolution, with no duplicate from the terminal path.
Result: pass.

## DOD-11 - re-notification

Not built and not run.
DOD-11 and S4 are deferred to `fm-slack-watch-renotify-digest`; this PR lands step 1 without them.
The current code emits no re-notification and no digest.

## DOD-12 - unconfigured is a hard no-op

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/no-token/transcript.json` with no token configured.

Observed: empty stdout, no answer, no wake queue row, no outbound call, and no `state/slack-watch/` directory.
A whitespace-only token was treated as unconfigured.
Result: pass.

## DOD-13 - transport failure reports once

Commands: `fm-slack-poll.sh` with `unreachable` and `rate-limited` twice each.

Observed: one `slack: transport failure: unreachable` on the first unreachable run and none on the second.
One `slack: transport failure: rate_limited` on the first rate-limited run and none on the second.
Zero check lines and zero close lines from the failing polls.
A terminal answer in the same test run still closed `failure-call`.
Result: pass.

## DOD-14 - missing reaction scope degrades

Commands: `fm-slack-mirror.sh` then `fm-slack-poll.sh` with `missing-scope`.

Observed: `slack: missing reaction scope: reactions:read, users:read` once, `Affordance: single-character` on the card, and a typed `2` reply that still closed `scope-call` with `Answer: wait`.
The poll after the mirror did not repeat the diagnostic, because the missing set had not changed; a poll alone on a fresh home printed it once.
Result: pass.

## DOD-15 - crash recovery loses no answer

Commands: `FM_SLACK_FAULT=after-delivery fm-slack-poll.sh --replay tests/fixtures/slack/crash-a/transcript.json`, then rerun without the variable; the same with `after-answer` and `crash-b`; and `after-delivery` with `crash-release`, whose thread carries the board card's `release` close mode.

`FM_SLACK_FAULT` is read from the process environment only; a stray value in the home's `.env` is ignored (X8).

Observed for all three: the interrupted run exited 75, the rerun closed the call, the final body held exactly one resolution record, and the thread's acknowledgement read `Answer recorded.` with no `not applied` text.
`after-delivery` fires after the intake applied the row and before the journal moved on, so the rerun replays the same row through the intake and the intake reports `closed:` again, for the done mode and for the release mode (the release-mode task is no longer held and is not closed as done).
`after-answer` did not re-run the intake and recorded nothing new.
Result: pass.

## DOD-16 - no credential reaches an artifact

Command: `tests/fm-slack-secret-scan.test.sh`.

Observed: `ok - scan redacted and detected both planted copies`.
The test first ran the plane with a known token (`SLACK_BOT_TOKEN`) through mirror, poll, arm, check, and a transport failure, captured each stdout and stderr under the scanned home's `data/captured/`, and required the plane to have left state, an outbound log, an `armed:` line, and a `transport failure` line.
The scan took its file set from `git ls-files` plus every file under both fixture homes' `state/`, `data/`, and `config/`, looked for the token as a substring anywhere in each file, and printed paths and counts only.
The clean run reported zero matches; the planted state copy (inside a longer line) and the planted tracked copy were each found.
Result: pass.

## DOD-17 - arming is ordered and reversible

Command: `fm-slack-check.sh arm --replay tests/fixtures/slack/arming/arm.json` in an unbound `arming` home.

Observed: `slack: refused: source_not_bound`, nonzero exit, and no `state/slack.check.sh`.
After `fm-captain-hold.sh bind slack-dm`, `fm-slack-check.sh arm` printed `armed: state/slack.check.sh` and created both the shim and its trust file.
The generated shim was then executed itself: with Slack off it exited 0 and printed nothing, and with an empty allowlist it reached the allowlist gate and never printed `unexpected_arguments`.
`fm-slack-check.sh check --replay check.json` printed exactly one line (`closed: resolve-call`).
A transcript that carried an `action` key did not change which action ran: only the word given to `fm-slack-check.sh` selects `arm`, `check`, or `disarm`.
`fm-slack-check.sh disarm` removed both files, and the next `check` printed nothing.
A bound home with `unreachable-dm.json` printed `slack: refused: unreachable`, exited nonzero, and left no shim.
Result: pass.

## S1 - long free text goes through the intake alone

Command: `fm-slack-poll.sh --replay tests/fixtures/slack/long-text/transcript.json` with a 900-character multiline reply.

Observed: the recorded `Answer:` was the intake's flattened, truncated line (at most 512 characters) and began with the reply's first words.
No `full-*` file was written under the home's `state/`, and the recorded label did not point at a copy.
The full text remains only in the Slack thread.
Result: pass.

## S2 - configuration behavior

Command: unset or corrupt each configuration variable in turn and run `fm-slack-check.sh check`, `fm-slack-poll.sh`, and `fm-slack-check.sh arm` against `tests/fixtures/slack/config/unset.json` and `tests/fixtures/slack/arming/arm.json`.

Observed: token unset and allowlist unset were silent and off from `fm-slack-check.sh check` and `fm-slack-poll.sh`.
The same two cases through `fm-slack-check.sh arm`, with stdout and stderr captured apart, wrote `slack: refused: unconfigured` to stderr only, printed nothing to stdout, exited nonzero, and left no check registered.
The periodic `fm-slack-check.sh check` in the same two cases wrote nothing to either stream and exited 0.
Poll cap unset took the default and completed.
The standing check printed nothing for `oops` as the allowlist, a malformed `FM_SLACK_DM_USER`, and a poll cap of `0`, `201`, or `many`.
By hand, the same values printed `slack: refused: allowlist_unparseable`, `slack: refused: missing_or_invalid_FM_SLACK_DM_USER`, and `slack: refused: invalid_FM_SLACK_POLL_MAX_ANSWERS_1_to_200`.
`arm` named the refusal for an unset DM user and for an unparseable allowlist, and left no check registered.
Result: pass.

## S3 - bounded poll work

Command: `FM_SLACK_POLL_MAX_ANSWERS=2 fm-slack-poll.sh --replay tests/fixtures/slack/backlog/transcript.json` three times, then once more.

Observed: 2 closes, then 4 total, then 5 total; the fourth run closed nothing.
No answer was dropped.
Result: pass.

## S4 - digest

Not built and not run.
Deferred with DOD-11 to `fm-slack-watch-renotify-digest`; this PR lands step 1 without it.

## X1..X22 - review-round regressions

Each runs against replay transcripts and the real intake; none opens a socket.

- X1: after a hold was released and set again, a reaction on the older thread and an answer staged before the re-hold (held back by a failing intake wrapper, not by a fault seam) both left the newer hold open; the staged answer surfaced a `replaced hold` check line and its thread was told `Answer not applied`; the older thread was retired. A live hold still took its own thread's answer.
- X2: with `slack-dm` unbound, neither the armed `check` nor `poll` delivered an answer; rebinding let the next `check` answer.
- X3: `disarm` removed the check with the token blank and with an unparseable allowlist, and refused with a nonzero exit, without printing `disarmed:`, when the shim was unsafe to remove.
- X4: a board card was used only when its `generated` time was after the hold's set time (`2026-10-01T00:00:00Z`); boards generated before it or at the same minute produced a text-only card with no options, no tap line, no seed reactions, a verbatim free-text answer, and the default close mode; a newer board produced numbered options, a recommendation, two seed reactions, and the card's `release` close mode, which lifted the hold instead of closing the task.
- X5: changing `FM_SLACK_DM_USER` after the DM existed was refused with `dm_user_changed` and sent nothing.
- X6: after the thread record was lost, mirroring again found the existing card by its message metadata and posted no second card; the replay returns metadata only when `include_all_metadata` is requested, and returns the channel object only when `return_im` is requested.
- X7: a Slack answer and an answer fed through the board adapter (`fm-procevent-lavish.sh answers`) for the same option left the same `Answer:` value and the same label line.
- X8: `FM_SLACK_FAULT=after-delivery` written to the home's `.env` did not crash the poll.
- X9: the armed check printed one line joining both pending conditions, at most 480 characters; a read failure after an earlier condition still printed that earlier line; a notice whose post failed printed no line until the retried post succeeded, then printed it once.

- X10: with the intake wrapper failing before its summary line, the poll exited non-zero with one `answer_intake_failed` line carrying the intake's error text, posted no acknowledgement, kept the reply staged, stayed quiet on the second failing poll, and on recovery closed the call with one record and an `Answer recorded.` acknowledgement; a wrapper that also wrote to its error stream after a successful close had that text passed on as an `intake note` line; a reply that reduces to nothing for the intake (a lone control character) was skipped without a line by the intake, so the poll said `answer not applied` itself and the call stayed open.
- X11: with the call-state probe unreadable, a typed reply was left unread: the poll exited 0 with no output, closed nothing, and posted nothing; once the probe recovered the same reply closed the call.
- X12: a card mirrored while the probe was unreadable recorded identity `uncertain`; once the call read as open under a verified hold, a reaction already standing on that card answered nothing, the verified hold got its own thread, and the uncertain thread was retired with a `Superseded` post.
- X13: with 25 retired thread records in state, a poll probed only the one open thread, and a poll with nothing open probed no call; after 300 more messages in the DM, mirroring one new card read exactly one history page.
- X14: numbered facts in a hold body stayed private and produced no options; explicit `Option N:` fields produced options without exporting nearby task-body facts, a line without a `(value)` recorded its label as the answer, and its hint stayed out of the value.
- X15: a tap by a second allowlisted member was staged with that member as its author; with that member removed from the allowlist, the next poll dropped the staged answer and left the call open.
- X16: `prepare` is no longer a command: the entry point exited 2 with `unknown command`.
- X17: with the bot token in the process environment, every local child the poll and the mirror ran (the call-state probe, the answer intake, the fleet snapshot) saw it unset.
- X18: a typed reply that Slack delivered as `merge 12 &amp; 13, skip CI &lt; 5 min &gt; see <https://example.com/b> and <https://example.com/a|the doc>` closed the call with the answer `merge 12 & 13, skip CI < 5 min > see https://example.com/b and the doc`, and the recorded label matched.
- X19: two conflicts with bounded candidate previews on two threads, plus a later unmatched reply on a third, ran through the armed `check`. The first poll emitted the first conflict's line ending `; +2 queued` within 480 characters; the second conflict's replies and the unmatched reply were not marked seen, their rows stayed pending, and the second conflict's notice was not yet posted. The second poll emitted the second conflict ending `; +1 queued` and posted its notice. The third poll emitted the unmatched reply's line with no marker, and a fourth poll printed nothing. No conflict recorded an answer.
- X20: an owner reply carrying only `subtype: thread_broadcast` closed the call with the typed words as the answer, while replies from the owner's id carrying `bot_id`, `app_id`, or `bot_profile` answered nothing and closed nothing.
- X21: with stdout and stderr captured apart, an explicit `arm` named its failure on stderr, wrote nothing to stdout, and exited nonzero on every run: after `FM_SLACK_DM_USER` changed (`dm_user_changed`, run twice with the failure already recorded by the standing check in between), with a state file of the wrong schema (`invalid_state_schema`), with a symlinked state directory (`unsafe_state_path`), and with a missing transcript (`replay_transcript_unreadable`). The standing `check` was silent on both streams with exit 0 while healthy, reported `dm_user_changed` once on stdout when it changed, and was silent on the repeat.
- X22: with `FM_SLACK_POLL_MAX_ANSWERS=1`, a live thread with an owner reply and a thread whose call was closed in the terminal after the owner replied late: the first poll answered the live thread and did not retire the closed one (no `Resolved:` post, `retired` false); the second poll emitted `unmatched reply` for the late reply; the third poll posted `Resolved:` and retired the thread.

## ACT-1 - live answer

The read-only identity probe above was run; the live answer flow was not.
This is a post-landing activation gate performed by firstmate with the owner.
No real DM was created, no source was bound, no poll was armed, and no message was posted.

## Hard gates

- GATE-1: the diff is confined to `bin/`, `docs/`, and `tests/`; no `projects/` path is written.
- GATE-2: `DOD-06` and the baseline SHA above show `bin/fm-captain-hold.sh` unmodified.
- GATE-3: `DOD-16` and the live probe show no token in stdout, stderr, state, data, config, or committed files.
- GATE-4: every replay outbound log names only `FM_SLACK_DM_USER`.
- GATE-5: `DOD-05` and `DOD-06` refuse tasks not held for the captain.
- GATE-6: this home publishes to its fork only; no upstream push is part of this change.
