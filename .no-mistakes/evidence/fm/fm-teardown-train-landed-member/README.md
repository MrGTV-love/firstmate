# Test-phase evidence: fm-teardown-train-landed-member

Target commit 89a6d2ab2be936c996345118d3df00f809ba74a3. Base 012b72f34a60f615d8898b0dd508c4fc115bfa08.
Every run drives the real `bin/fm-teardown.sh`. The home, state, data and pool are throwaway.
No real copy, real home, or real backlog was torn down or written.

Real forge runs (read-only):
- `real-forge-transcript.txt` (driver `drive-real-forge.sh`): record-only teardown, real `gh`
  behind a filter that passes only `gh pr view` and `gh pr list`. Project = temp blobless Vernant clone.
  - R1 PR 3528 (CLOSED) is accepted via merged train PR 3599. Backlog row: pr link = 3599, body
    "closed by merge train: .../pull/3528".
  - R2 PR 3567 (CLOSED, listed by no PR) is refused.
  - R3 PR 3444 (CLOSED; merged PR 3451 names its URL and sha in prose, not "<url> at <sha>") is refused.
- `real-d1b5-replica-transcript.txt` (driver `drive-real-d1b5-replica.sh`): a fresh lab worktree at the
  real d1 B5 r4 copy HEAD 5714eb0f, task PR 3528, real forge reads.
  - W1 no run record: refused, naming 0bb1ac955 and "not proven present in its head eab72358aa89".
  - W2 a lab run record (input 5714eb0f, pushed 0b2e8a9f): accepted, naming 3599.
  - Limit: the real d1 B5 r4 copy is accepted only if its real no-mistakes run record has these
    values. The real state database was not read.

Sandbox runs (temp git world, fake `gh`, logging `treehouse`):
- `teardown-train-transcript.txt` (driver `drive.sh`): scenarios A to H with full stderr.
  G2 (pipeline-input copy with run record on a verified train) is now accepted; it was refused in round 1.
- `teardown-train-cases.txt`: 24 train cases in `tests/fm-teardown.test.sh`.
- `own-pr-route-controls.txt`: own-PR, pipeline-input and content-proof controls (unchanged routes).
- `pool-train-case.txt`, `backlog-close-shape-case.txt`, `captain-hold-retained-cases.txt`.

`prior-round-0e44fe40/` holds round 1 evidence at the older head. It is kept for history only.

Captain-held train close (sandbox, real `bin/fm-captain-hold.sh` and `bin/fm-teardown.sh`):
- `captain-hold-train-marker.txt` (driver `drive-captain-hold-train-marker.sh`): a held ship's pending
  retain record is set to the merge-train shape (`--pr .../pull/9 --note "closed by merge train: .../pull/7"`).
  The captain answer succeeds. The row records pull/9 as its PR. pull/7 is never recorded as the PR.
  The "closed by merge train" note does not reach the closed row (the answer applies only `--pr`).

Reading notes:
- R1 to R3: "treehouse.log: No such file" means treehouse was never called. That is expected for a
  record-only teardown (no copy to return).
- R1: the "STUCK ... uncommitted changes" line comes from the no-checkout lab clone used as the project.
- W2: "copy present after: yes" is because treehouse is a logging stub; the stub got `return --force`.
- Round 1 files were moved to `prior-round-0e44fe40/`. Nothing else was moved.
