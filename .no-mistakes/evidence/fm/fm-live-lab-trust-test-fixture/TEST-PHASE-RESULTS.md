# Test phase results: tests/fm-live-lab.test.sh rival trust fixture (3fe2ac82 vs base 37a733cb)

All runs drive the real bin/fm-live-lab.sh `up`/`down` (unchanged, blob-identical to base) with the test's stand-in claude.
Variant scripts were scratch copies outside the worktree; their exact edits are in variant-diffs.txt.

| Run | Test revision | Variant | Result | Log |
|---|---|---|---|---|
| 1 | head | unmodified, in-tree | exit 0, rival case ok | full-run-head.log |
| 2-5 | head | unmodified | exit 0 x4, rival case ok | head-run2..5.log |
| 6-7 | head | rival delay 0.5 -> 2.5 s | exit 0 x2, rival case ok | head-delay25-run1/2.log |
| 8 | base | rival delay 0.5 -> 2.5 s | exit 1: `primary launched trusted after the rival write (expected 'present', got 'absent')` | base-delay25.log |
| 9 | base | forced pre-launch refusal (tmux new-session blocked) | exit 1: masked as `expected 'present', got ''`; no up output shown | base-refusal.log |
| 10 | head | forced pre-launch refusal | exit 1: `up refused before primary launch (missing: 'primary: claude')`; up output with `fm-live-lab: cannot start the lab tmux server` printed | head-refusal.log |
| 11 | head | stand-in claude always writes `absent` | exit 1 at marker check; trap prints `rival trust case up output:` with full up output | head-untrusted-launch.log |

Passing runs 1-7 contain zero `rival trust case up output` lines.
Note: run 8 failed with 'absent', not the scout's exact empty marker; base timing at 2.5 s is not deterministic on this Mac.
Scope: scope-check.txt (only tests/fm-live-lab.test.sh changed; fm-live-lab.sh, fm-claude-trust.sh, fm-proc-budget.sh blob-identical).
