# Test-step evidence: fm-teardown-nested-copy-own-slot (head fff7007a2, base 9c5874baa)

- live-gate-409-base-vs-head.txt: the real bin/fm-teardown.sh run by drive-gate-409.sh on a throwaway world shaped like the recorded gate-409 case (plain record, nested copy at <slot>/.claude/worktrees/task-x1-v2, claim = this task, herdr fields, leftover backlog-close and empty-slot teardown-return-pending files, --force --drop-file). Base reproduces the recorded defect (inbox, status, tasktmp removed, pane closed, then "reserved pool slot  lost its durable lease"). Head: landed case exits 0 and returns the slot once; slot-unlanded case refuses naming the slot root HEAD with everything left in place.
- live-claim-states-plain-vs-prior.txt: head, plain vs prior (enclosing) shape for claim other / none / mine with landed, copy-dirty and copy-unlanded fixtures. Every pair has the same result.
- head-pool-targeted.txt, head-bundle-targeted.txt, head-held-entry-targeted.txt, head-held-entry-rerun.txt: targeted new suite cases on head.
- base-plus-tests-pool.txt: the same new pool cases run on base bin/ with head tests/ (each fails).
- drive-gate-409.sh: the driver script.
- live-backlog-clear-fail.txt (drive-backlog-clear-fail.sh): head; the moved pending-close clear fails (marker is a directory). It refuses before any endpoint close or inbox/status/tasktmp removal, leaves a return-pending record that names the slot, and a rerun after the fix completes.
- head-held-copy-existing.txt: 31 older held-copy cases on head, all ok.
- flake-home-summary-refresh-cleanup.txt: an unchanged old completing case on base and head; both leave state/.home-summary-refresh.log after the suite cleanup. This is the same race that made two held-entry suite runs exit 1 on "rm: Directory not empty" after all 22 cases printed ok. It is not caused by this change.
