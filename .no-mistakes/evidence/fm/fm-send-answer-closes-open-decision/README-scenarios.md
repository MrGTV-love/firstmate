# Live evidence index: fm-send must state its choice on a task with open keyed decisions

Head 6e8547698, base 9c5874baa (base tree from `git archive 9c5874baa`, run side by side).
Each driver mints a marked lab home with `bin/fm-lab-home.sh env`, starts a REAL tmux
server on the lab's private `fm-lab` socket (`cat >/dev/null` panes), runs the real
`bin/fm-send.sh` / `bin/fm-promote.sh` / `bin/fm-wake-drain.sh`, then tears the lab down.
No stub transport is used in these drivers. No real lane, home, or doorbell was touched.

| File | What it shows |
|---|---|
| `fm-send-live-transcript.txt` (driver `drive-fm-send.sh`) | base bare send delivers and leaves k1/k2 open (the defect); head bare send (id and `fm-<id>`) exits 1, lists `[key=k1] needs-decision` and `[key=k2] blocked`, names both flags, writes no inbox, no status line, nothing typed; contradictory pair refused; mistyped key refused with identical text on head and base; `--answers-none` delivers and both keys stay open; `--resolve-key k1` closes k1 only; repeated `--answers-none` accepted; `--key Enter` and explicit backend target not refused; typed plane (`/help`) bare refused, `--answers-none /help` not refused; reserved `pending-reply-*` key: bare refused, none-flag delivered and still open, `--resolve-key` closes with `pending-reply-resolved ... via=operator-resolve-key`. |
| `record-identity.txt` (driver `drive-record-identity.sh`) | No-open-decision task, same text: head and base inbox records are byte-identical except the per-write `at=` stamp (79 vs 79 bytes). Supersedes the `RECORDS BYTE-IDENTICAL: no` line in the first transcript, which differed only in `at=`. |
| `secondmate-live-transcript.txt` (driver `drive-secondmate.sh`) | Local secondmate: bare sends with an open expectation but no open status entry still deliver; once a key is open, a bare send refuses with the pending-reply count (2) and inbox count (2) unchanged; `--answers-none` delivers a marked record and the key stays open. |
| `promote-live-transcript.txt` (driver `drive-promote.sh`) | `fm-promote.sh` prints a flagless `next:` command; run as printed against a scout with open `ship-it`, it exits 1 and names `[key=ship-it] needs-decision`, no inbox written; resend with `--resolve-key ship-it` delivers and the drain lists no open decision. (The `fm_test_dod_item: command not found` line is the fixture helper only; promotion still succeeded.) |
| `long-resolve-timing.txt` (driver `drive-long-resolve-timing.sh`) | A 9 KB `--resolve-key` answer takes ~650 s on head AND base (647 vs 657 s): pre-existing, not caused by this change. |
| `suite-*.log`, `caller-suites-exit.txt` | Targeted existing suites for the answer path and the automatic callers (stub transports). |

Reading notes:
- The explicit-target send and `--answers-none /help` exit 1 with `delivery unconfirmed; verdict=unknown`.
  That is the typed-plane submit read-back on a `cat` pane, which has no harness composer. It is NOT the
  new guard. Claim: not refused by the choice rule; the text reached the pane (the capture shows it).
- `fm-gate-refuse: gate agent lifecycle permitted only against lab home ...` and the watcher-down banner
  are expected lab noise.

Suite notes:
- `tests/fm-secondmate-sync.test.sh` stops at `test_bootstrap_nudge_retry_is_idempotent` on head AND base
  (`suite-fm-secondmate-sync.log`, `suite-fm-secondmate-sync.BASE.log`): fm-bootstrap's billing guard reads
  the host's `~/.omp/agent/config.yml` (openrouter fallback chains). That is a host-config leak in the test, not this change.
  With `PI_CODING_AGENT_DIR` set to an empty scratch dir, head passes all 35 cases, including the three new
  open-keyed-decision caller cases (T8e, R8b, R8c): `suite-fm-secondmate-sync.isolated-omp.log`.
- `tests/fm-open-loops.test.sh` was stopped by the tester after its check-in block (the one this change edits)
  printed PASS. 41 PASS lines, no failures. The rest of that suite does not touch fm-send.
- `tests/fm-task-delivery.test.sh` was not completed (very slow on the loaded host). Its new promote case is
  covered live by `promote-live-transcript.txt`.
