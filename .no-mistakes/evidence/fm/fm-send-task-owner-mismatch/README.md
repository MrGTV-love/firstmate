# Test-phase evidence: fm-send task-owner mismatch (target 598001b7)

Every live drive ran against a marked disposable lab home minted by
`bin/fm-lab-home.sh env`, with real tmux panes on the private `fm-lab` socket,
and was torn down in the same turn with the printed teardown line.
fm-send itself always ran under `env -i` (PATH, LANG, fresh empty HOME/TMPDIR).

| File | What it shows |
|------|---------------|
| `live-misroute-base-vs-head.txt` | 15:57Z replay. Base cb411ea3 accepts the intake fix round sent to secondmate fm-mini (record + reply expectation). Head refuses it, names the owner, and leaves no trace. |
| `live-drive-transcript.txt` | S1-S9: wrong-owner refusals (secondmate, worker, legacy label, with --resolve-key), correct owner, --relay and its limits, non-mentions and the path-embedded known limit, secondmate own child, declared inputs (missing / present / outside boundary / multiple / relay / key), remote route failure not reported as missing, unattended wrapper hold, dependency kept open. |
| `live-drive-recovery-transcript.txt` | An unread relayed cross-task request to a secondmate is reposted by pending-reply recovery (`--relay`), the same correlation is kept, there is no duplicate on a second attempt, and the same text without --relay is refused. |
| `live-claude-C1.txt` | A real Claude Code worker pane. The misroute and a wrong-owner steer to the live pane are refused before typing. |
| `live-claude-C2.txt` | The same work, sent to the owner the refusal named, reaches the real Claude worker. It reads its inbox record, acts (resume-proof.txt = RESUMED), and moves the record to handled/. |
| `live-claude-C3.txt` | Typed plane: `/context` with a missing declared input is refused before typing (exit 4). With the input present, it reaches Claude's parser unchanged and runs. |
| `live-base-vs-head.txt` | Correct-owner and no-task-id steers produce byte-identical durable records at base and head. |
| `so5-ambient.txt`, `so5-loaded.txt` | Timing of the first re-ring in the test_watcher_rerings_idle_pane_quietly setup (60 s window). The first ring came at about 2.3-4.3 s (ambient load about 3) and about 4.6-5.4 s (load 16-17). It came in at iterations 9-23 of the test's 100-iteration wait. The Studio failure was not reproduced here. SO5 stays Unverified (Main's real-case capture). |
| `suites-summary.txt`, `suite-*.log` | The affected Bash suites, run under env -i containment, with OMP_API_BILLING counts. |
| `*.sh` | The exact drivers used, so the runs can be repeated. |
