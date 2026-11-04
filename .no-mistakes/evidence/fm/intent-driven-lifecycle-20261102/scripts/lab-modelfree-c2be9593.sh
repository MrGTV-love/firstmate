#!/usr/bin/env bash
# Model-free lab for run 01M6KS2CS6GX0GDVNTT34X3QMC: real fm-brief (base vs head), fm-dod-lib
# --verification-plan, and the fm_brief_worker_role generated interface. No agent CLI is started.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6KS2CS6GX0GDVNTT34X3QMC
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6KS2CS6GX0GDVNTT34X3QMC; E=$N/lab-c2be9593
mkdir -p "$E"; cd "$WT" || exit 1
head=$(git rev-parse HEAD); echo "head=$head"; [ "$head" = c2be9593474c6e561bbae42ca343e23fceef7a38 ] || exit 1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>"$E/lab-env.err")" || { cat "$E/lab-env.err"; exit 1; }
LAB=$FM_HOME; echo "lab=$LAB tmux=$TMUX_TMPDIR"
TD=$(grep -o '[^ ]*fm-lab-home.sh teardown .*' "$E/lab-env.err" | head -1)
cleanup() { echo "== teardown: $TD"; eval "$TD"; echo "teardown exit=$?"; echo "lab-left: $(ls -d "$LAB" 2>/dev/null || echo none)"; echo "worktree changed paths: $(git -C "$WT" status --short | wc -l | tr -d ' ')"; }
trap cleanup EXIT
CUE='use the existing Intent-to-test alignment criteria in the shared review rubric below during implementation and verification'
seed="$LAB/seed"; origin="$LAB/notes-origin.git"; mkdir -p "$seed/notes" "$seed/tests"
printf 'NOTES = []\n' > "$seed/notes/__init__.py"; printf '# notes\n' > "$seed/README.md"
git -C "$seed" init -q -b main && git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$origin"; rm -rf "$seed"; git clone -q "$origin" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"

echo "== scenario 2: base-commit fm-brief vs head fm-brief (docs-only task)"
mkdir -p "$LAB/base-root"; git archive 9c5874baa019f4f14450901985fc46476b0dc64b | tar -x -C "$LAB/base-root"
"$LAB/base-root/bin/fm-brief.sh" mfbase-docs notes --mode local-only > "$E/base-docs-brief-scaffold.out" 2>&1; echo "base brief exit=$?"
bin/fm-brief.sh mfhead-docs notes --mode local-only > "$E/head-docs-brief-scaffold.out" 2>&1; echo "head brief exit=$?"
cat "$E/head-docs-brief-scaffold.out"
sed -n 's/.*; replace \(.*\))$/\1/p' "$E/base-docs-brief-scaffold.out" > "$E/placeholders-base.txt"
sed -n 's/.*; replace \(.*\))$/\1/p' "$E/head-docs-brief-scaffold.out" > "$E/placeholders-head.txt"
cmp -s "$E/placeholders-base.txt" "$E/placeholders-head.txt" && echo "placeholders identical (base vs head)" || { echo "PLACEHOLDERS DIFFER"; diff "$E/placeholders-base.txt" "$E/placeholders-head.txt"; }
sed "s#$LAB/base-root#<ROOT>#g; s#mfbase-docs#<ID>#g" "$LAB/data/mfbase-docs/brief.md" > "$E/brief-shape-base.md"
sed "s#$WT#<ROOT>#g; s#mfhead-docs#<ID>#g" "$LAB/data/mfhead-docs/brief.md" > "$E/brief-shape-head.md"
diff -u "$E/brief-shape-base.md" "$E/brief-shape-head.md" > "$E/brief-shape.diff"; echo "docs brief base-vs-head diff exit=$? lines=$(wc -l < "$E/brief-shape.diff" | tr -d ' ')"
echo "head docs brief mentions intent-to-test: $(grep -ci 'intent-to-test' "$LAB/data/mfhead-docs/brief.md")"

echo "== scenario 3: verification plan for a no-mistakes brief"
bin/fm-brief.sh mfhead-nm notes --mode no-mistakes > "$E/head-nm-brief-scaffold.out" 2>&1; echo "nm brief exit=$?"
bash bin/fm-dod-lib.sh --verification-plan "$LAB/data/mfhead-nm/brief.md" > "$E/head-nm-verification-plan.md" 2> "$E/head-nm-verification-plan.err"; echo "plan exit=$?"
P="$E/head-nm-verification-plan.md"
echo "plan: alignment_section=$(grep -c '^## Intent-to-test alignment$' "$P") review_outcomes=$(grep -c '^## Review outcomes$' "$P") unverified_anywhere=$(grep -ci unverified "$P")"
echo "plan grading line present: $(grep -cF 'as pass, fail, or unresolved' "$P"); downstream pending line: $(grep -cF 'is pending, never pass' "$P")"
n=0; while IFS= read -r l; do [ -n "$l" ] || continue; grep -qxF -- "$l" "$P" || { n=$((n+1)); echo "  missing: $l"; }; done < docs/review-rubric.md; echo "rubric lines missing from plan: $n of $(grep -c . docs/review-rubric.md)"

echo "== scenarios 1 and 7: generated worker role (fm_brief_worker_role, the interface fm-spawn.sh embeds in launch-brief.md)"
( source bin/fm-dod-lib.sh; fm_brief_worker_role "$LAB/state" mfhead-test "$WT" ) > "$E/head-worker-role.md" 2>"$E/head-worker-role.err"; echo "role render exit=$?"
R="$E/head-worker-role.md"
awk -v cue="$CUE" '/^# Current worker role contract$/{r=NR} index($0,cue){c++; cl=NR} /^## Intent-to-test alignment$/{s=NR} /^## Review outcomes$/{o=NR} END{printf "order: role=%d cue_line=%d cue_count=%d rubric_section=%d outcomes=%d\n", r,cl,c,s,o; exit !(r>0 && c==1 && r<cl && cl<s && s<o)}' "$R"; echo "order check exit=$?"
echo "unverified in role: $(grep -ci unverified "$R")"
n=0; while IFS= read -r l; do [ -n "$l" ] || continue; grep -qxF -- "$l" "$R" || { n=$((n+1)); echo "  missing: $l"; }; done < docs/review-rubric.md; echo "rubric lines missing from role: $n of $(grep -c . docs/review-rubric.md)"
echo "== scenario 1/7 base comparison: base role has no cue"
( source "$LAB/base-root/bin/fm-dod-lib.sh"; fm_brief_worker_role "$LAB/state" mfbase-test "$LAB/base-root" ) > "$E/base-worker-role.md" 2>/dev/null; echo "base role exit=$? base cue_count=$(grep -cF "$CUE" "$E/base-worker-role.md") base alignment_section=$(grep -c '^## Intent-to-test alignment$' "$E/base-worker-role.md")"
echo "== adversarial: role rendered from a root whose rubric lacks the alignment section"
mkdir -p "$LAB/neg-root/docs"; sed '/^## Intent-to-test alignment$/,/^## Review outcomes$/{/^## Review outcomes$/!d;}' docs/review-rubric.md > "$LAB/neg-root/docs/review-rubric.md"
( source bin/fm-dod-lib.sh; fm_brief_worker_role "$LAB/state" mfneg "$LAB/neg-root" ) > "$E/neg-worker-role.md" 2>&1; echo "neg role exit=$? alignment_section=$(grep -c '^## Intent-to-test alignment$' "$E/neg-worker-role.md") (cue still points at 'below'; shows the cue depends on the rubric owner)"
