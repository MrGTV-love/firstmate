#!/usr/bin/env bash
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6KS2CS6GX0GDVNTT34X3QMC
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6KS2CS6GX0GDVNTT34X3QMC; E=$N/lab-c2be9593
cd "$WT" || exit 1; echo "head=$(git rev-parse HEAD)"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>"$E/lab-s3-env.err")" || exit 1; LAB=$FM_HOME; echo "lab=$LAB"
TD=$(grep -o '[^ ]*fm-lab-home.sh teardown .*' "$E/lab-s3-env.err" | head -1)
trap 'echo "== teardown"; eval "$TD"; echo "teardown exit=$? lab-left: $(ls -d "$LAB" 2>/dev/null || echo none) worktree changed paths: $(git -C "$WT" status --short | wc -l | tr -d " ")"' EXIT
seed="$LAB/seed"; mkdir -p "$seed/notes"; printf 'NOTES = []\n' > "$seed/notes/__init__.py"
git -C "$seed" init -q -b main && git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$LAB/o.git"; rm -rf "$seed"; git clone -q "$LAB/o.git" "$LAB/projects/notes"
printf '# Projects\n\n- notes [no-mistakes] - tiny lab notes library\n' > "$LAB/data/projects.md"
bin/fm-brief.sh mfhead-nm notes --mode no-mistakes > "$E/head-nm-brief-scaffold.out" 2>&1; echo "nm brief exit=$?"
MAND="M1 Source: the task text. Expected: add_note('') raises ValueError. Verify: python3 -m unittest discover -s tests passes. Edge/negative: non-empty text is still stored. Evidence place: tests/test_notes.py and the unittest output. Authority: gate"
B="$LAB/data/mfhead-nm/brief.md" MAND="$MAND" python3 - <<'PY'
import os; p=os.environ["B"]; t=open(p).read()
for k,v in {"{TASK}":"Add a validator that rejects empty note text in add_note().","{FIRSTMATE_SPEC}":"Raise ValueError for empty text and add a unit test.","{DOD_CAPABILITY}":"add_note rejects empty text.","{DOD_MANDATORY_ITEMS}":os.environ["MAND"],"{DOD_SUPPORTING_ITEMS}":"None.","{DOD_HARD_GATES}":"Do not change files outside the notes repository.","{DOD_HONESTY_RULE}":"Report an unrun test as unrun."}.items(): t=t.replace(k,v,1)
t=t.replace("\n### Out of scope\n","\n### Out of scope\n- Any change outside the notes package.\n",1); open(p,"w").write(t)
PY
cp "$LAB/data/mfhead-nm/brief.md" "$E/head-nm-brief-filled.md"
bash bin/fm-dod-lib.sh --verification-plan "$LAB/data/mfhead-nm/brief.md" > "$E/head-nm-verification-plan.md" 2> "$E/head-nm-verification-plan.err"; echo "plan exit=$?"; cat "$E/head-nm-verification-plan.err"
P="$E/head-nm-verification-plan.md"
echo "plan: alignment_section=$(grep -c '^## Intent-to-test alignment$' "$P") review_outcomes=$(grep -c '^## Review outcomes$' "$P") unverified_anywhere=$(grep -ci unverified "$P")"
echo "grading line 'pass, fail, or unresolved': $(grep -cF 'as pass, fail, or unresolved' "$P"); 'is pending, never pass': $(grep -cF 'is pending, never pass' "$P")"
awk '/^## Intent-to-test alignment$/{a=NR} /^## Review outcomes$/{o=NR} END{print "alignment before outcomes: " (a>0 && a<o ? "yes" : "NO")}' "$P"
n=0; while IFS= read -r l; do [ -n "$l" ] || continue; grep -qxF -- "$l" "$P" || { n=$((n+1)); echo "  missing: $l"; }; done < docs/review-rubric.md; echo "rubric lines missing from plan: $n of $(grep -c . docs/review-rubric.md)"
