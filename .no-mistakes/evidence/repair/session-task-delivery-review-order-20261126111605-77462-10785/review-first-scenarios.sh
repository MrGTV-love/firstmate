#!/usr/bin/env bash
# Usage: review-first-scenarios.sh <worktree-root> <fixture-dir>
set -u
. "$(dirname "$0")/review-first-driver.sh" "$1" "$2"
head_of() { g "$1" rev-parse "$2"; }

echo "=== S1 review-first PASS at R (no pipeline run), then a clean base merge lands at H ==="
mkcase s1; R=$(head_of s1 pr); T=$(head_of s1 trunk)
review s1 "$R" PASS gpt-5.1 '{"ship":["claude-opus-4-5"]}'
verify s1 "$R" "$T"
g s1 merge -q --no-edit trunk; H=$(head_of s1 HEAD)
verify s1 "$H" "$T"

echo; echo "=== S2 pipeline edit to a file after the review-first PASS ==="
mkcase s2; R=$(head_of s2 pr); T=$(head_of s2 trunk)
review s2 "$R" PASS gpt-5.1 '{"ship":["claude-opus-4-5"]}'
printf 'one\ntwo fixed\n' > "$FX/s2/wt/app.txt"; g s2 commit -qam 'no-mistakes(review): fix'
pipeline_run s2 run-s2 claude claude-opus-4-5
H=$(head_of s2 HEAD)
verify s2 "$H" "$T"
plan s2 "$H" "$T"
review s2 "$H" PASS gemini-2.5-pro '{"ship":["claude-opus-4-5"],"no-mistakes:anthropic":["claude-opus-4-5"]}'
verify s2 "$H" "$T"

echo; echo "=== S3 review-first PASS, then a pipeline run with a NEW author family (openai) and no edits ==="
mkcase s3; R=$(head_of s3 pr); T=$(head_of s3 trunk)
review s3 "$R" PASS gpt-5.1 '{"ship":["claude-opus-4-5"]}'
pipeline_run s3 run-s3 codex gpt-5.1
verify s3 "$R" "$T"
plan s3 "$R" "$T"
g s3 merge -q --no-edit trunk; H=$(head_of s3 HEAD)
verify s3 "$H" "$T"
review s3 "$H" PASS gemini-2.5-pro '{"ship":["claude-opus-4-5"],"no-mistakes:openai":["gpt-5.1"]}'
verify s3 "$H" "$T"

echo; echo "=== S3b pipeline run whose family (anthropic) equals the already-covered ship family, no edits ==="
mkcase s3b; R=$(head_of s3b pr); T=$(head_of s3b trunk)
review s3b "$R" PASS gpt-5.1 '{"ship":["claude-opus-4-5"]}'
pipeline_run s3b run-s3b claude claude-opus-4-5
verify s3b "$R" "$T"
plan s3b "$R" "$T"

echo; echo "=== S4 parallel-with-CI review FAILs, fix lands, closure re-review at the fixed head ==="
mkcase s4; R=$(head_of s4 pr); T=$(head_of s4 trunk)
review s4 "$R" FAIL gpt-5.1 '{"ship":["claude-opus-4-5"]}'
g s4 merge -q --no-edit trunk; HM=$(head_of s4 HEAD)
verify s4 "$HM" "$T"
printf 'one\ntwo\nthree\n' > "$FX/s4/wt/app.txt"; g s4 commit -qam 'fix review finding'; H=$(head_of s4 HEAD)
verify s4 "$H" "$T"
review s4 "$H" PASS gpt-5.1 '{"ship":["claude-opus-4-5"]}'
verify s4 "$H" "$T"

echo; echo "=== S5 adversarial: same-family reader PASS at R must not carry ==="
mkcase s5; R=$(head_of s5 pr); T=$(head_of s5 trunk)
review s5 "$R" PASS claude-sonnet-4-5 '{"ship":["claude-opus-4-5"]}'
g s5 merge -q --no-edit trunk; H=$(head_of s5 HEAD)
verify s5 "$H" "$T"
