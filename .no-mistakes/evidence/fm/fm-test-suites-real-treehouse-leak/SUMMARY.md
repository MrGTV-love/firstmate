# Test-phase evidence at 351b105d67c45e9631083ebae187e9f0e0958a0e

Every run used `env -i` with PATH, a private HOME (`$LAB/home`), and a private TMPDIR that is a symlink (`$LAB/tmp-link -> $LAB/tmp-real`, and `/tmp` is itself a symlink to `/private/tmp`).
`snap.sh` takes a read-only snapshot of the real `~/.treehouse` (names and mtimes, two levels) before and after each run, using the helper's own snapshot rule.

| Run | Result | Real ~/.treehouse | Leftover in lab |
| --- | --- | --- | --- |
| s1 tests/treehouse-test-safety.test.sh | exit 0; positive confinement + lease cleanup; both negative controls reject | unchanged | none |
| s2 presentation --sandbox-only (symlinked TMPDIR) | exit 0; lease under the physical private pool; trust in private store | unchanged | none |
| s3 autodetect smoke | exit 1 at Herdr tripwire (expected, no default session in private HOME) | unchanged | no fixture root, no private-HOME .treehouse |
| s4 launcher e2e | exit 1 at Herdr tripwire (expected) | unchanged | same |
| s5 per-home e2e | exit 1 at Herdr tripwire (expected) | unchanged | same |
| s6 cmux live | skip (opt-in gate) | unchanged | none |
| s7 SIGINT after lease appears | exit 0, suite finished, pool removed | unchanged | none |
| s7 SIGTERM after lease appears | killed (-15); EXIT trap still removed pool and lease | unchanged | none |

Only empty `fm-herdr-lab-501/` and `fm-test-owners/.legacy-discovery` state dirs remained in TMPDIR (Herdr lab/test-owner state, not Treehouse). The lab was removed after the runs.
Full Herdr e2e and live cmux runs were NOT driven, per recorded decision; they stay UNVERIFIED.
