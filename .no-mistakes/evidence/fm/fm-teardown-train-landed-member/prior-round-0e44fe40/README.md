# Test-phase evidence: fm-teardown-train-landed-member

Target commit 0e44fe40492179cbfc80d5da9218d549552c0298, base 012b72f34a60f615d8898b0dd508c4fc115bfa08.

All runs drive the real `bin/fm-teardown.sh` in throwaway temp git worlds built by
`tests/fm-teardown-helpers.sh`. The forge is a fake `gh`. The pool is a logging `treehouse` stub.
No real copy, real home, or real forge was written or read through teardown.

Files:
- `teardown-train-cases.txt`: 28 targeted `tests/fm-teardown.test.sh` cases (all train cases plus controls). All ok.
- `pool-train-case.txt`: `tests/fm-teardown-pool.test.sh test_reassigned_slot_train_member_retires_only_on_a_verified_train`. ok.
- `backlog-close-shape-case.txt`: `tests/fm-backlog-atomicity.test.sh test_recovery_accepts_only_the_merge_train_close_shape`. ok.
- `captain-hold-retained-cases.txt`: retained-artifact cases for the `bin/fm-captain-hold.sh` change.
- `teardown-train-transcript.txt`: full stderr, exit code, treehouse calls and backlog for scenarios A-H
  (driver: `drive.sh`, copied here).
- `live-d1-b5-copy-readonly.txt`: read-only git analysis of the real d1 B5 r4 copy
  (no fetch, no index refresh, no teardown).

Key result: scenario G (a copy that was the no-mistakes pipeline's input, whose PR the pipeline
rewrote, then closed as landed by a verified merged train) is REFUSED, even with the run record that
makes the own-PR route accept the same copy (scenario H). The real d1 B5 r4 copy at 5714eb0f has this
shape: its original feature commit 0bb1ac955 has no equal patch in member head 0b2e8a9f. So the train
route at this head will still refuse the live d1 B5 r4 copy in work mode. It fails closed (no data loss).
