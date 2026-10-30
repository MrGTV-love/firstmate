# Live ledger run (lab FM_HOME, real fm-watch.sh / fm-wake-drain.sh / fm-open-loops.sh)

Fixture: 30 captain-held "fleet paused" lanes, 8 captain-held decision lanes each with a firstmate
needs-decision question, 3 loose firstmate questions. The real collector published 49 overdue
unanswered_question rows (38 captain-owned, 11 firstmate-owned). Host load average was about 20.

| Step | File | Result |
| --- | --- | --- |
| New rows, no actions | live-03-first-gate.txt | 49 rows in OVERDUE; ack refused |
| One batch of 49 actions | live-05-batch-ack.txt | batch about 1.2 s; ack accepted in 2 s |
| Next turn, nothing changed | live-06-unchanged-turn.txt | 0 rows in OVERDUE; ack accepted, no new action |
| Watcher change wake | live-07-watcher-change-wake.txt | real watcher queued open-loop-ledger; drain gated 0 rows |
| Lane resumes / captain answers a bound hold | live-08/09 | only decide-3:scope returned; ack refused until 1 action, then accepted |
| Re-asked question becomes overdue | live-10-changed-row-overdue.txt | 1 of 48 rows gated; ack refused, then accepted after 1 action |
| Periodic list | live-11-resurface*.txt | real watcher queued open-loop-ledger-resurface; WAITING OPEN WORK lists 48 rows with age, status, last action |
| Change + periodic due together, +7 h | live-12-coincide*.txt | both wakes queued; OVERDUE 4 (1 changed, 3 lapsed deferrals), STANDING 44, WAITING 44 |
| Adversarial | live-13-adversarial.txt | 2nd deferral refused; --hold on captain row refused; --hold on unheld task refused; hold id in evidence text did not bind (listed "no proof") |
| Away daemon ack | live-15-away-ack.txt, live-16-after-away.txt | env alone does not bypass; with state/.afk ack passes, no action written; firstmate's next drain still gates the row |
| G1 | live-17-g1.txt | 48 overdue = 0 gate + 48 digest; 0 missing |
| Baseline 28bb500b2 | baseline-unchanged-turn.txt | after 4 h, base re-gates unchanged escalated firstmate rows and refuses ack |
