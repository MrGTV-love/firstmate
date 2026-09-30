# Test-phase re-run on head 70d27be (2026-09-30T20:59Z-21:01Z)

`run.sh` drives the real `bin/fm-dispatch-resolve.sh` from the gate worktree, with a real Jev API
call on every run, and a throwaway lab FM_HOME that holds a copy of
/Users/charlesabrooker/firstmate/config/crew-dispatch.json (read only). The lab was removed at the end.

Evidence classes (each block in runs.txt names its class):
- LIVE: real `quota-axi --json` 0.1.55. Runs L-* (four real intakes), G (profile floor), I (OpenRouter).
- CONTROLLED CLI: a stand-in `quota-axi` first on PATH serves fixtures/<id>.json. Each fixture is a
  printed jq transform of one real snapshot (fixtures/base-live-snapshot.json, generatedAt
  2026-09-30T20:59:06.970Z: codex all_models 55%, projected_exhaustion, 81098 s, established).
  These are NOT live provider readings.

Result: 21/21 PASS. offline-regression.log: `bash tests/fm-dispatch-resolve.test.sh`, all pass.
