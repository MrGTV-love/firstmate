# fm-dispatch-resolve runway guard — live validation (2026-09-30)

Target commit 70d27be (branch fm/fm-jev-resolver-runway-guard). Resolver run from the gate worktree.

## live-four-briefs.txt — fully live
Real Jev API (jev-1.13.0), real `quota-axi --json` (0.1.55), real rules file
/Users/charlesabrooker/firstmate/config/crew-dispatch.json (read only), four real briefs.
Live Codex row at run time: 57% remaining, projected_exhaustion, usableRunwaySeconds 82213,
projectionConfidence established (snapshot in quota-live-snapshot.json).
Result: 4/4 clear on `--harness omp --model openai-codex/gpt-6.1-sol --effort high`, no warning
(82213 s > 240-min horizon).

## adversarial-runs.txt — real resolver + real Jev call, lab config / injected quota
Lab FM_HOME with a copy of the live rules file; a PATH wrapper forwards to the real quota-axi
and applies the jq transform printed on each run's `# quota transform:` line.
A  established 3600 s          -> escalate, no profile
K  6% / established 1800 s      -> escalate, no profile (report case)
B  early 3600 s                 -> clear + warning
C  no confidence / no seconds   -> clear + warning
D  established exactly 14400 s  -> clear, no warning
E1 horizon 30 min, 3600 s       -> clear
E2 horizon 120 min, 3600 s      -> escalate naming 120-minute horizon
E3 horizon 0                    -> exit 2 config error
F  exhausted_now on pool        -> eligible, unranked (not vetoed); lone candidate -> escalate
G  profile floor 90% (real quota) -> not eligible
H  short pool + lower cursor    -> escalate; cursor profile NOT emitted
H-control healthy pool + cursor -> clear on pool
I  omp OpenRouter (real quota)  -> eligible, unranked; clear with "1 eligible candidate(s) unranked (openrouter)"
J  quota-axi reports 0.1.50     -> error "quota-axi requires >= 0.1.51"

## controlled-cli-runs.txt — CONTROLLED CLI evidence (not live provider readings)
Re-run 2026-09-30 on head 70d27be to close the eight scenarios the live pass marked untested.
Method: the real `bin/fm-dispatch-resolve.sh` from this worktree, a real Jev API call, a lab
FM_HOME holding a copy of the live rules file, and a stand-in `quota-axi` first on PATH that
serves a fixed fixture (controlled-fixtures/<id>.json). Every fixture is a jq transform of one
real snapshot taken at 2026-09-30T20:40:33Z (controlled-fixtures/base-live-snapshot.json).
The stand-in never reads live accounts. No shared settings or live accounts were changed.
Each run carries an automatic check line; 13/13 PASS.
K  6% / established 1800 s        -> escalate, no profile (report case)
A  established 3600 s             -> escalate, no profile (240-minute horizon named)
B  early 3600 s                   -> clear + [warning: ... projectionConfidence=early]
C  absent confidence/seconds      -> clear + [warning: ... unknown]
D  established exactly 14400 s    -> clear, no warning
E1 task_horizon_minutes=30        -> clear, no warning
E2 task_horizon_minutes=120       -> escalate naming 120-minute horizon, no profile
E3 task_horizon_minutes=0         -> exit 2 config error
F  exhausted_now, omp pool        -> eligible, unranked + [warning: exhausted_now]; not vetoed
F-nonpool exhausted_now, codex    -> not eligible (veto kept outside the pool)
H  short pool + lower cursor      -> escalate, no profile; cursor not used as fallback
H-control healthy pool + cursor   -> clear on the omp pool
J  quota-axi --version 0.1.50     -> status error naming ">= 0.1.51", no ranking
offline-regression-rerun.log: `bash tests/fm-dispatch-resolve.test.sh` on the same head.
