# Test-phase evidence at c1d9f51bf45dcaf3d5315330cf74a0de1832a83f (final head)

Base 012b72f34a60f615d8898b0dd508c4fc115bfa08. Every run drives the real `bin/fm-teardown.sh`
or `bin/fm-captain-hold.sh`. Home, state, data, pool are throwaway. No real copy, home, or backlog was touched.
Files without the `-c1d9f51b` suffix are from the older head 89a6d2ab2 and are history only.

- `teardown-train-transcript-c1d9f51b.txt` (driver `drive.sh`): sandbox scenarios A to H.
  A, B, G2, H accept. C, D, E, F, G1 refuse. E says "unknown, retry".
- `real-forge-transcript-c1d9f51b.txt` (driver `drive-real-forge.sh`): real gh, read-only filter.
  R1 Vernant 3528 accepted via train 3599; row links pull/3599, body "closed by merge train: .../pull/3528".
  R2 3567 refused ("no PR found by the forge lists it"). R3 3444 refused. No gh write was attempted.
- `real-d1b5-replica-transcript-c1d9f51b.txt` (driver `drive-real-d1b5-replica.sh`): lab worktree at the
  real d1 B5 r4 HEAD 5714eb0f. W1 no run record: refused. W2 lab run record: accepted, naming 3599.
  Limit: the real no-mistakes run record for that copy was not read.
- `captain-hold-train-marker-c1d9f51b.txt` (driver `drive-captain-hold-train-marker.sh`): held row closed by
  the captain answer now records pull/9 as the PR link AND the note "closed by merge train: .../pull/7".
  (At 89a6d2ab2 the note was dropped; see `captain-hold-train-marker.txt`.)
- `captain-hold-train-marker-wider-c1d9f51b.txt` (driver `drive-captain-hold-train-marker-wider.sh`): adversarial.
  The note has extra text. The answer exits 1 with "invalid pending-close arguments". The row stays held, in flight.
- `targeted-train-cases-c1d9f51b.txt`: the branch's new test cases, run by name. All ok.
- `held-train-teardown-e2e-c1d9f51b.txt` (driver `drive-held-train-teardown-e2e.sh`): end to end, nothing hand-written.
  A captain-held train member is torn down by the real teardown, then answered by the real captain-hold.
  - treehouse fails: teardown writes `mode=retain` with `--pr .../pull/9 --note "closed by merge train: .../pull/7"`.
    The answer closes the row with the pull/9 link and the member note.
  - treehouse ok: the held row gets the pull/9 link and the note at teardown; the answer keeps both.
  - The member URL (pull/7) is never the PR link. Only the `answer` path was driven, not `withdraw`.
- Not tested: the real d1 B5 r4 copy with its real no-mistakes run record (shared state is off-limits).
