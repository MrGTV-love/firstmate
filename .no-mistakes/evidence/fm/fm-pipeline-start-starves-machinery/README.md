# Test-phase evidence: fm-pipeline-start-starves-machinery (head 80fc5da99, base 012b72f34)

How the live runs were made: `live_driver.py REPO SANDBOX SCENARIO...` runs the real `bin/fm-cpu-pass.sh`, `bin/fm-mem-guard.sh` and `bin/fm-duration.py`.
HOME pointed at a throwaway sandbox, so `~/.no-mistakes/state.sqlite` and `config.yaml` were fixture files.
FM_HOME was a sandbox home holding readings and calibration records shaped like the copied fleet record.
FM_MEMORY_FIXTURE_DIR (the product's own native-facts input) supplied pressure, available memory and per-run RSS.
FM_CPU_POOL_DIR was a private pool.
The product was not monkeypatched.
`no-mistakes` and `claude` were stand-ins, because a real pipeline start or a real agent is prohibited in this phase.
Base runs used `git archive 012b72f34 bin` exported to /tmp.
Every sandbox was deleted after the run.

| File | Shows |
| --- | --- |
| live-p1-head.txt / live-p1-base.txt | PR 365 live case and 14:14Z record: head admits at first poll (exit 3 passed through), base waits with need=88.7e9; control waits naming inputs, then admits by itself |
| live-holds-order-head.txt | pressure 2 and unreadable facts hold, then admit by themselves; class order merge-train, machinery, vernant-build, other (first class-order attempt hit a fixture error: 200 GiB free on a 128 GiB host, which the gate correctly held as inconsistent) |
| live-routes-head.txt / live-routes-base.txt | 7 fresh shapes through fm-mem-guard.sh run queue; reattach/respond/status/other/no-intent exit 2 run at once; PR 366 shape gets a pipeline-start line on head and none on base; nested 2>&1 and reverse nesting with # comment finish with one admission (no deadlock) |
| live-launch-gate-head.txt | launch-gate refusals (unmapped/ambiguous/unreadable, exit 75, wake line), non-CI pass-through (exit 7), CI admit order of timestamps, two simultaneous resumes (second waits on the first's published R, then admitted by itself, with held/admitted wake lines), hold-bound refusal at 5 s (exit 75, no retry phrase), SIGTERM forwarding (143), gate SIGKILL kills agent, missing agent 127 |
| live-launch-gate-head-run1-fixture-errors.txt | first attempt, kept for honesty: two fixture mistakes (room for two runs; one-start minimum applied) |
| live-launch-gate-extra-head.txt | isolated copy of the live launcher (diff of 2 lines, live sha256 unchanged), group kill mid-hold leaves nothing live and the next launch is admitted, dead holder reserves nothing |
| live-sigint-loop.txt | 200 SIGINT cancels under 18-core synthetic load, head and base: 0 hangs |
| suite-*.log | parallel run of the three covering test files (cpu-pass and duration failed under load) and serial re-runs (both exit 0) |
