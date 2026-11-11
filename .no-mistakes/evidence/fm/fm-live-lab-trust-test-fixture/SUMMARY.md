# Test-phase evidence: fm-live-lab rival trust fixture (head 6691f9da, base 30914c32)

Scratch trees: `git archive` of base and head into /tmp/fmll.QNRO1f (removed after the run).
Focused files hold the suite setup, the up-source block, and the rival trust case only (scratch-mkfocus.sh).
Base focused files and both seeded head reruns pre-create `$HOME/.claude.json` as `{}`, which the full suite leaves in place.

| Log | Tree | What it shows | Exit |
|---|---|---|---|
| full-suite-head.log | head | whole tests/fm-live-lab.test.sh passes; no "rival trust case up output" noise | 0 |
| head-focus-run1..5 | head | case passes 5/5 at the shipped 0.5 s delay | 0 |
| head-delay25-run1..5, head-delay25-seeded-run1 | head | case passes 6/6 with rival delay 2.5 s | 0 |
| head-delay6-run1 | head | case passes with rival delay 6 s | 0 |
| head-full-delay25.log | head | whole file passes with rival delay 2.5 s | 0 |
| head-saw-run1, head-saw-seeded-run1 | head | rival saw the primary entry PRESENT before it deleted | 0 |
| base-saw-run1 | base | inverted wait: rival saw entry ABSENT, deleted nothing (TypeError), still wrote "dropped", case passed vacuously | 0 |
| base-delay25-run1/2, base-delay-2.0, base-delay-3.0 | base | case fails at 2.0-3.0 s rival delay: wall-clock dependent (marker 'absent') | 1 |
| base-full-delay25.log | base | whole file with 2.5 s delay fails at the same case (marker 'absent', not '') | 1 |
| base-refuse-tmux | base | pre-launch refusal ("cannot start the lab tmux server") masquerades as the exact `expected 'present', got ''` failure, refusal text hidden | 1 |
| head-refuse-tmux | head | same refusal now fails as "up refused before primary launch" and prints up output with "cannot start the lab tmux server" | 1 |
| head-refuse-trust | head | fail-closed launcher refusal "trust keeps disappearing" (rival keeps deleting) fails as "up refused before primary launch" with the refusal text | 1 |
| head-mut-no-trust-recheck | head + scratch launcher mutation | launcher launches without its trust re-check: case fails as a trust failure (marker 'absent') and prints up output incl. "fail trust" | 1 |
| LL4-scope.txt | git | diff touches tests/fm-live-lab.test.sh only; bin/fm-live-lab.sh, bin/fm-claude-trust.sh, bin/fm-lab-home.sh blob-identical | - |
