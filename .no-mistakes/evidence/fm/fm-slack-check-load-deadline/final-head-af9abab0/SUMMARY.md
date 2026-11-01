# Live test results at af9abab0

All runs use the real `bin/fm-watch-checkpoint.sh` and `bin/fm-watch.sh`, a real lab home, the real check shim, and the real `Slack.call` with real sockets.
Only the Slack address changes. A disposable server on 127.0.0.1 answers from the repo replay transcript. The token is synthetic. Replay: `driver/run-all.sh`.
Lab-only quieting: `config/open-loops.json` raises one age limit, and `state/.memory-health-next` is set far ahead. Both stop unrelated wakes.

| Case | Base tree | This head | File |
| --- | --- | --- | --- |
| Process frozen 22 s by SIGSTOP between requests | wake: request_budget_exhausted | no wake, 4 cards | before-starved-sigstop.txt, after-starved-sigstop.txt |
| Slack answers each request in 1 s or 3 s | not run | no wake, 4 cards | repro-latency1-run1.txt, repro-latency3-run{1,2}.txt |
| Slack answers each request in 6 s | wake: unreachable, socket timeout cut to 0.67 s | **wake: check slack stopped (no progress), 5 of 5 runs**, 4 cards | before-slow-latency.txt, after-slow-latency.txt, repro-latency6-run{1,2,3}.txt, repro-sustained-*.txt |
| Slack answers each request in 9 s, new cards | not run | **wake: check slack stopped (no progress), 3 of 3 runs**, 4 cards | repro-latency9-run{1,2,3}.txt |
| Slack answers each request in 9 s, 4 open threads | wake: unreachable; timeouts cut | **wake once; every pass stopped after 3 requests** | before-steady-state-latency9.txt, repro-steady-state-latency9.txt |
| Request hangs | not run | wake: unreachable once; read ends at 10.0 s; second pass silent; recovery; new episode wakes once | after-hang-once-per-episode.txt, after-hang-before-any-card.txt |
| Reply arrives at 12 s | not run | wake: unreachable once at 10.0 s | after-request-over-timeout.txt |
| Body trickles one byte each 5 s | not run | watcher stops the check after about 40 s; wake once; client process gone | after-trickle-owner-bound.txt |
| Post is saved but its reply is lost | not run | wake once; next pass finds the marker; 4 posts, 0 duplicates | after-lost-post-reply.txt |
| HTTP 500, connection reset | not run | wake once each; recovery clean | after-http500.txt, after-connection-reset.txt |

Bold rows are the open finding. The check's CPU is under the 0.01 s step in `bin/fm-duration.py` for 30 s, so the watcher sees no progress, though requests finish.
