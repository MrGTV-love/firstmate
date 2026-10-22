Live validation of e9f58913 (anchor squash-pushed-missing "add a" match).
Product under test: real bin/fm-teardown.sh, driven by tests/fm-teardown.test.sh fixtures.
Real refusal format (bin/fm-teardown.sh:2183,3004): one "<short-id> <subject>" line per unproven commit, at line start.

repro-bin/git + grind_commit.py: fixture-only git wrapper. It passes all calls to /usr/bin/git and
re-times only the copy's "add b" commit so its short ID ends in "add" (the CI flake condition).

Run                                  test file    commit IDs  teardown printed   result
base-normal.transcript.txt           b13c1b1b     normal      eb0ef08 add b      ok
base-steered.transcript.txt          b13c1b1b     steered     0049add add b      NOT OK (flake reproduced)
new-normal.transcript.txt            e9f58913     normal      18ff3c0 add b      ok
new-steered.transcript.txt           e9f58913     steered     ed6dadd add b      ok (fix holds)
mutant-genuine-add-a.transcript.txt  e9f58913 + fixture drops "add a" from PR head
                                                  normal      add b + add a      NOT OK (genuine add a still caught)
committed-file-run.transcript.txt    e9f58913 unmodified, regression + target case   ok, ok
regression-test-before-fix.transcript.txt  regression case with helper reverted to old grep   NOT OK
*.teardown-stderr.txt: the real teardown stderr saved from each run.
