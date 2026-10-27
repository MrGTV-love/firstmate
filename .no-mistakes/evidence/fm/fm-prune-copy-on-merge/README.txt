Live validation of fm/fm-prune-copy-on-merge at c3fb4843a.
driver.sh <group> runs each group in a fresh marked lab home (bin/fm-lab-home.sh create),
private tmux socket dir, REAL treehouse v3.1.4 on a throwaway TREEHOUSE_ROOT, real git origin on disk,
real fm-teardown / fm-merge-prune / fm-idle-reap / fm-watch. Only gh/gh-axi/no-mistakes/docker are stubbed.
Each lab is removed at the end ("lab removed: yes" in every transcript).
  live-core.transcript.txt      S1 verified merge -> reaped; S2 transient lock -> retry -> reaped; S3-S5 changed file / unpushed commit / pane job kept with 1 wake
  live-agent.transcript.txt     A exited-before-merge pane (real treehouse get) -> reaped; A0 same case on parent cce119f49 backs off, new code reaps; B relaunched agent + old marker -> not closed; B2 second treehouse get -> kept
  live-fallback.transcript.txt  S6w closeout refusal -> fallback, SHA-256 preserve, real treehouse destroy; S7w unique ignored file kept; S6x exited worker + fallback -> second teardown admitted via pane check; S8a/S8b nested unpushed kept
  live-nested.transcript.txt    S11 clean nested copies pruned; S12 dirty nested clone kept; S7t
  live-more.transcript.txt      S5b subdir process kept; S6/S7 teardown accepted; S8 nested unpushed kept; S10 unverified merge never arms (S9 there is a harness artifact; see live-watch)
  live-watch.transcript.txt     S9 poll-armed record pruned by the real fm-watch.sh tick
  targeted-tests.log            8 targeted cases of tests/fm-merge-prune.test.sh
Note: a real Claude Code launch in the lab opened its session dashboard (not a chat prompt); it was stopped before any input, and the agent was replaced by a native stand-in named claude.
