# Live silence-steer scenarios: real fm-open-loops.sh / fm-fleet-snapshot.sh / fm-send.sh in fm-lab homes (tmux -L fm-lab)

Rows: scenario. Columns: observed result per code tree. "presented" = row shown by --present-overdue at delivery+900 s with label "steered, result not observed".
"cadence_ok=True" = row NOT overdue at +899 s, overdue and NOT informational at +900 s, presented, and `--check-in` passed its eligibility test and called fm-send. It does NOT mean the check-in was delivered: in this gate lab the send was refused by bin/fm-gate-refuse-lib.sh because bin/fm_open_loops.py:126-128 always sets FM_DATA_OVERRIDE/FM_PROJECTS_OVERRIDE and the lab allowance accepts only ROOT/STATE/CONFIG overrides (same on base). r2 returns check_in=not_sent (row informational).
Fixtures: clock moved with FM_OPEN_LOOPS_NOW; worker panes ran `sleep` (liveness ambiguous, a degraded coverage row on all trees); the driver wrote status lines, inbox acknowledgements and pending-reply records. Real: fm-open-loops.sh collector, fm-fleet-snapshot.sh, fm-crew-state.sh, tmux backend, fm-send.sh steer delivery.

| scenario | base c89e6a597 | r2 3c3ae152b | head 8778d4d22 |
|---|---|---|---|
| plain-working-after-ack | presented_at_limit=False | presented_at_limit=True | presented_at_limit=True |
| typed-blocked-after-working | presented_at_limit=False | presented_at_limit=False | presented_at_limit=False |
| reply-same-second | presented_at_limit=False | presented_at_limit=True | presented_at_limit=True |
| reply-later-second | presented_at_limit=False | presented_at_limit=False | presented_at_limit=False |
| failed-later-second-ship | presented_at_limit=False | presented_at_limit=False | presented_at_limit=False |
| failed-same-second-ship | presented_at_limit=False | presented_at_limit=False | presented_at_limit=True |
| secondmate-done-later-second | presented_at_limit=False | presented_at_limit=False | presented_at_limit=False |
| secondmate-working-later-second-control | presented_at_limit=False | presented_at_limit=True | presented_at_limit=True |
| cadence-failed-ship | cadence_ok=True | cadence_ok=False | cadence_ok=True |
| cadence-done-secondmate-with-work | cadence_ok=True | cadence_ok=False | cadence_ok=True |
