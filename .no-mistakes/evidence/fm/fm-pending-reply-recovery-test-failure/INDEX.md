# Test-phase evidence: pending-reply recovery when macOS cannot execute ps
Head ee7ec3bd474e8cd3a3a818772a6026fc8cfbe29f, base cb411ea377a5441cf41af17d1f21db85020bfd79.
Host: macOS 26.7.1 (25G241), /bin/bash 3.2.57. Every run used env -i with explicit PATH and a disposable HOME/TMPDIR under /tmp (removed after).
The exposing condition was reproduced for real with `sandbox-exec` profile `(allow default)(deny process-exec (literal "/bin/ps"))`: ps exits 126 "Operation not permitted".
Each log header records the command, commit, sandbox mode; each footer records exit, duration, OMP_API_BILLING count (0 everywhere).

| Log | What it shows | Exit |
|---|---|---|
| base-sandboxed-full.log | base full suite, ps blocked: `not ok - recovery should send after completed turn + grace` (the reported failure) | 1 |
| base-plain-full.log | base full suite, ps executable: passes (failure needs the ps block) | 0 |
| head-sandboxed-full.log | head full suite via bin/fm-test-run.sh, ps blocked: passes | 0 |
| head-plain-full.log | head full suite, ps executable: passes, incl. `native sender identity matches executable ps` parity | 0 |
| base-newtests-sandboxed-forced126.log | base lib + head tests: forced-126 regression fails at base | 1 |
| base-newtests-sandboxed-relayed.log | base lib + head tests: relayed-repost case fails `phase awaiting_report` | 1 |
| base-newtests-plain-forced126.log | base lib + head tests, ps executable: forced-126 regression still fails at base | 1 |
| head-non126-test.log | head: non-126 refusal test passes | 0 |
| mutant-any-status-non126-test.log | lab mutant (fallback on any ps status): RED on native-log assertion `(ps=1)` | 1 |
| posctl-ps126-fixture_identity.log | lab positive control, same stub, ps=126: native identity read, sends exactly once | 0 |
| posctl-ps126-shadowed-sender_identity.log | same control with pre-review name `sender_identity`: stub empty, refuses (proves the rename mattered) | 1 |
| ci-step-macos-plain.log | exact new CI step command (FM_TEST_ONLY, CI PATH, /bin/bash), ps executable | 0 |
| ci-step-macos-sandboxed.log | same CI step command, ps blocked | 0 |
| drive-head-plain.log | stub-free library driver: recovery sends once, retry refused | 0 |
| drive-head-ps-blocked.log | stub-free driver, ps blocked: native identity, sends once, retry refused | 0 |
| drive-base-ps-blocked.log | stub-free driver at base, ps blocked: empty identity, refuses, attempt unconsumed | 0 |
| drive-head-ps-and-native-blocked.log | stub-free driver at head, ps exec AND fm-proc-info.py read blocked: refuses, nothing sent, attempt unconsumed | 0 |
