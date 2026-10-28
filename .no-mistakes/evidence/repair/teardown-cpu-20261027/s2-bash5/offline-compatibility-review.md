# s2-bash5 offline compatibility review

Private evidence review. No source, gate, build, live test, process query, or new profiler action.

## Inputs

- Actual gate evidence: `stdout.log`, `stderr.log`, `inputs.txt` in this directory.
- Private offline files:
  - `../../../../work/fm-repair/.scratch/contrib-diagnosis-20261027/s2-bash5-offline.events.jsonl`
  - `../../../../work/fm-repair/.scratch/contrib-diagnosis-20261027/s2-bash5-offline.result.json`
  - `../../../../work/fm-repair/.scratch/contrib-diagnosis-20261027/s2-bash5-offline.provenance.json`

Hashes:

- stdout.log `dcfc0dbd...`
- stderr.log `e3b0c442...` (empty)
- inputs.txt `ce7b4e34...`
- events.jsonl `1d36a5bd...`
- result.json `fc4676c1...`
- provenance.json `34407d98...`

## Extraction check

The events file contains exactly 438 raw `FM_TEARDOWN_CPU` JSON rows. The actual `stdout.log` contains exactly 438 such rows. Parsed event objects are equal in order and content; no rows were added, dropped, reordered, or rewritten.

Event counts match provenance:

- launch 1
- boundary 5
- phase_scope 2
- phase_boundary 219
- phase_invocation 38
- phase_invocation_closed 38
- helper_return 15
- phase_interval 113
- interval 6
- target_exit 1

There is no synthetic phase invocation or closure in the offline stream.

## Ownership and canonical closure

- 38 invocation ids, all unique.
- 38 closure ids, all unique.
- Every invocation is closed; no closure id is missing or extra.
- Product invocations: 15, ids `3,6,8,11,13,16,18,21,23,26,28,31,33,36,38`.
- Result spans: 45, exactly three valid regions per product.
- No invalid reasons, no diagnostics, no instrumentation errors.
- Actual target exit: returncode 0, boundaries missing false, pipe EOF observed, partial mark bytes 0; stderr empty.

## Source binding

`inputs.txt` binds a820bfbce4ecfe886201403335f202f74e654cbb and the reviewed hashes: product `b1457e94...`, observer `7826b952...`, helper `07fbc312...`, cleanup `62d1340b...`.

This matches the prior a820 source binding receipt: mark contexts preserved, observer ownership unchanged, 191 cleanup cases with original189 as ordered subsequence plus two upstream graft cases. The selected run's two cases are the expected phase-eligible cases.

Capability is explicitly `supported` with the reviewed source string; it is not inferred from raw marks. The result's provenance is consistent with the events; re-deriving from the events with the frozen parser reproduces the 45 spans exactly.

## Conditional acceptance

Conditional compatibility accept for this selected Darwin two-case run:

- no extraction omissions or synthetic wiring;
- closure and ownership counts are complete and exact;
- supported spans are not overclaimed beyond the source-bound data;
- clean target exit and empty stderr.

Limits:

- This is a selected two-case Bash5 Darwin run, not the full 191-case suite and not CI.
- The result contains per-span CPU/wall observations; do not infer suite case count, total CPU, savings, or an optimization from this run.
- The a820 duration/proc-info differences remain in force; do not compare these values to c13, the old baseline, or prior CI.
- No source change, gate command, build, live test, process query, or new profiler was run.

No concrete contradiction found.
