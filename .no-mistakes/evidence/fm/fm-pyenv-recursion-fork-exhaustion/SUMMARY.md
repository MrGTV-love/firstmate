# Live validation: pyenv recursion from the fm-spawn-dispatch-profile fixture

Host: macOS, /bin/bash 3.2.57, python3 = ~/.pyenv/shims/python3 (pyenv 2.6.6, version 3.13.6).
Every run used capped-run.sh: own process group, `ulimit -u` = current user procs + headroom, `timeout -s KILL`, then a group kill and a leftover count.

| Run | Wrapper | Exit | Time | Peak pyenv-prefix/which procs | Left after |
|---|---|---|---|---|---|
| collapse-demo.txt (pure bash) | old vs new | - | - | - | - |
| route-wrapper-none (real shim, fm-dsh.py route) | none | 0, prints dsh | 0.27s | 0 (17 bash starts) | 0 |
| route-wrapper-new | fixed | 0, prints dsh | 0.21s | 0 (17 bash starts) | 0 |
| route-wrapper-old | base | 137 (killed) | 15.4s | 365 (2138 bash starts) | 0 |
| old-wrapper-snapshot (t=4s) | base | killed | 8s | 90 `pyenv-prefix 3.13.6` + 87 `pyenv-which python --skip-advice`, chain depth 189 | 0 |
| fixture-base-before-fix (base test, target fn only) | base | 137 (killed) | 30.3s | 331 | 0 |
| fixture-old-wrapper-new-detector (fixed test, old line restored) | base | 1, "expected exit 0, got 97" | 5.6s | 0 | 0 |
| fixture-after-fix (fixed test, target fn only) | fixed | 0, ok | 10.4s | 0 | 0 |
| suite-fm-spawn-dispatch-profile (bin/fm-test-run.sh, whole file) | fixed | my 560s cap hit | 560s | 0; 90 ok, 0 not ok | 0 |
| suite-tail-4-tests (the 4 tests the cap cut off) | fixed | 0, all ok | 54.5s | 1 | 0 |
