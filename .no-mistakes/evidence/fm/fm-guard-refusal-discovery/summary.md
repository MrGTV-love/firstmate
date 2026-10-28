# fm-guard-refusal-discovery: live test summary

Target commit 2364c4ee1. All live runs used a throwaway `git archive HEAD` copy of the real tree (git-initialised, removed after).
Full transcript: live-scenarios.txt.

| DoD item / scenario | Result | Evidence |
|---|---|---|
| 1 Complete discovery: discovered `REFUSED:` marker sites vs independent grep of the default dirs | PASS (199 = 199, 0 differences) | independent-diff.txt, live-discovery.json |
| 2 Both guards found (fm-task-copy-lib.sh:672 allocation guard, fm-teardown.sh:4015 shared-slot guard) | PASS | two-guards.txt |
| 3 New unregistered `REFUSED:` site inside a registered owner file fails new-or-touched and enforce | PASS | live-scenarios.txt S3 |
| 4 Same site mapped with a sites marker passes (mapped 50 -> 51) | PASS | live-scenarios.txt S4 |
| 5a Touching an allowlisted legacy site fails new-or-touched | PASS | S5a |
| 5b Growing the allowlist fails S5 (enforce alone would pass) | PASS | S5b |
| 5c Deleting a legacy site makes its entry STALE | PASS | S5c |
| 6 Typed unregistered=37 fails S4; typed=842 (computed) passes | PASS | S6 |
| S7 `|| exit 2` hook site, `.dsh/` adapter, unquoted stderr heredoc are found | PASS | S7 |
| S8 `$refused` var, `.refused` path, `== "refused"`, `startswith(...)`, argc `exit 2` are not sites | PASS | S8 |
| S10 CI `--base HEAD^1` on a merge commit ignores later main edits; old moving-tip base false-fails | PASS | S10 |
| S9 `fm_refuse` call / guard-event deny on a one-line function definition line | **FAIL**: not found, both lint modes pass | S9, S9c |
| Red-first: new fixture test fails against base-commit lint | PASS (fails as expected) | live-scenarios.txt R |

Gap detail: bin/fm-guard-sites.py:256-257 and :266 skip the C (helper call) and E (guard event) signatures on any line that matches SH_DEF/PY_DEF/JS_DEF.
That keeps the helper's own definition out, but it also drops a real call on a one-line wrapper such as
`probe() { [ -n "$1" ] || fm_refuse spawn probe "no task named"; }`. No such line exists in the tree today (searched), so the allowlist is unaffected.
