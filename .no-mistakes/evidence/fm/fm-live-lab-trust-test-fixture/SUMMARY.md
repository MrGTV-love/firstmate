# Rival trust case validation (head 3fe2ac82 vs base 37a733cb)

Drivers: trimmed copies of tests/fm-live-lab.test.sh (header setup + UPSRC setup + rival case),
built by driver-generator-mk.sh. They run the real bin/fm-live-lab.sh `up`/`down` against a
private tmux server and a fake HOME. bin/ is byte-identical at base and head (LL4-scope.txt).
"seeded" runs pre-create $HOME/.claude.json as the earlier suite cases do. The unseeded base runs
(unseeded-store/) hang the old rival on a missing store, so they are a setup artifact, not a verdict.

| Variant | Head | Base |
|---|---|---|
| full tests/fm-live-lab.test.sh | pass (head-full-run-1.log) | not run |
| rival 0.5 s (plain) | 7/7 pass | 2/2 pass |
| rival 2.5 s (slow) | 7/7 pass | 2/3 FAIL: expected 'present', got 'absent' |
| persistent rival -> pre-launch refusal | FAIL "up refused before primary launch (missing: 'primary: claude')" + up output printed | FAIL "expected 'present', got ''" (the CI symptom, no diagnostics) |
| rival deletes after launch -> trust failure | FAIL "expected 'present', got 'absent'" + up output printed | same assertion, no up output |
