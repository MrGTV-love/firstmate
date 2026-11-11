# Live validation index — head dcd1395d019284228996f9b38ffcdd926c2f1b9d vs base d791189feb232562783dec56150d103bc2aa5e78
Host: macOS 26.7.1 (25G241), /bin/bash 3.2.57. All runs: env -i with explicit PATH, lab HOME/TMPDIR under /tmp/fm-nm-pr-lab.EJDqWa (removed after run), wrapped by bin/fm-proc-budget.sh --memory-kib 2097152.
"sandbox" = sandbox-exec -p '(version 1)(allow default)': macOS refuses setuid /bin/ps there with exit 126 (the real trigger). "open" = unconfined, ps works.
OMP_API_BILLING diagnostic count: 0 in every log (printed at the end of each log).

| Log | Tree | Mode | Result |
|---|---|---|---|
| R1-base-full-suite-sandbox.log | base | sandbox | exit 1, `not ok - recovery should send after completed turn + grace` (reproduced) |
| C1-base-full-suite-unconfined.log | base | open | exit 0 (control: failure needs the ps refusal) |
| S2-head-full-suite-sandbox.log | head | sandbox | exit 0, all pending-reply tests passed |
| S1-head-full-suite-unconfined.log | head | open | exit 0, incl. `native sender identity matches executable ps` |
| R2-base-relayed-isolated-sandbox.log | base lib + head test | sandbox | exit 1, relayed repost `phase awaiting_report` |
| S3-head-relayed-isolated-sandbox.log | head | sandbox | exit 0 |
| R3-base-native-regression-unconfined.log | base lib + head test | open | exit 1 (new regression is red at base) |
| S4-head-ci-step-native-case-unconfined.log | head | open | exit 0 (same command as the new macOS CI step) |
| S5-head-native-case-sandbox.log | head | sandbox | exit 0 |
| M1-mutant-other-ps-failures.log (+ M1-mutant-126-to-star.diff) | mutant | open | exit 1 on native-log assertion (guard test kills the 126->* mutant) |
| S6-head-other-ps-failures.log | head | open | exit 0 |
| S7-head-unreadable-sender.log | head | open | exit 0 |
| D-{base,head}-{open,sandbox}-direct-recovery.log | both | both | direct library driver: base+sandbox refuses (0 deliveries, awaiting_report); head+sandbox sends exactly once (recovery_sent, 1 delivery, second call refused) |
