#!/usr/bin/env bash
# Scenario 3 extra: reproduce the phaseA lab-modelfree step (verification plan from an UNFILLED no-mistakes
# brief, plan exit=1) whose stderr was later overwritten by lab-s3. Disposable marked lab home, model-free.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6KS2CS6GX0GDVNTT34X3QMC
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6KS2CS6GX0GDVNTT34X3QMC; O=$N/scenario3-unfilled-c2be9593; mkdir -p "$O"
cd "$WT" || exit 1; echo "head=$(git rev-parse HEAD)"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>"$O/lab-env.err")" || exit 1; LAB=$FM_HOME; echo "lab=$LAB"
TD=$(grep -o '[^ ]*fm-lab-home.sh teardown .*' "$O/lab-env.err" | head -1)
trap 'echo "== teardown"; eval "$TD"; echo "teardown exit=$? lab-left: $(ls -d "$LAB" 2>/dev/null || echo none) worktree changed paths: $(git -C "$WT" status --short | wc -l | tr -d " ")"' EXIT
seed="$LAB/seed"; mkdir -p "$seed/notes"; printf 'NOTES = []\n' > "$seed/notes/__init__.py"
git -C "$seed" init -q -b main && git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$LAB/o.git"; rm -rf "$seed"; git clone -q "$LAB/o.git" "$LAB/projects/notes"
printf '# Projects\n\n- notes [no-mistakes] - tiny lab notes library\n' > "$LAB/data/projects.md"
bin/fm-brief.sh mfu-nm notes --mode no-mistakes > "$O/scaffold.out" 2>&1; echo "nm brief exit=$?"; cat "$O/scaffold.out"
echo "unfilled placeholders in brief: $(grep -oE '\{(TASK|FIRSTMATE_SPEC|DOD_[A-Z_]+)\}' "$LAB/data/mfu-nm/brief.md" | sort -u | tr '\n' ' ')"
bash bin/fm-dod-lib.sh --verification-plan "$LAB/data/mfu-nm/brief.md" > "$O/plan.md" 2> "$O/plan.err"; echo "plan exit=$?"
echo "plan stdout bytes=$(wc -c < "$O/plan.md" | tr -d ' ') ; plan stderr:"; cat "$O/plan.err"
