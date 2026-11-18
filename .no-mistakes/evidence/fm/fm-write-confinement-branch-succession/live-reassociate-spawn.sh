#!/usr/bin/env bash
# Live drive of the reassociate and fresh-spawn rules a recorded successor adds, in a lab home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M7MYQZDENGWZ8TC0F3BXCXBA
cd "$WT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME; export FM_GUARD_EVENT_LOG="$LAB/state/guard-events.jsonl"
T=fm-lab-reassoc-task; Y=fm-lab-other-task
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-scott-reassoc.XXXXXX")
sed "s/^TASK=fm-slack-second-person-scott\$/TASK=$T/" tests/fixtures/fm-scott-task-shape.sh > "$FIX/maker.sh"
mkdir "$FIX/fx"; bash "$FIX/maker.sh" "$FIX/fx" >/dev/null
P=$FIX/fx/project
cp -p "$FIX/fx/home/state/$T.meta" "$LAB/state/"; mkdir -p "$LAB/data/$T"; cp -p "$FIX/fx/home/data/$T/brief.md" "$LAB/data/$T/"
# Safety: no real treehouse or herdr call can happen from this drive.
mkdir -p "$FIX/safebin"; for t in treehouse herdr; do printf '#!/bin/sh\necho "lab: $0 blocked" >&2; exit 1\n' > "$FIX/safebin/$t"; chmod +x "$FIX/safebin/$t"; done
export PATH="$FIX/safebin:$PATH"
# A second task Y with its own copy and branch.
git -C "$P" worktree add -q -b "fm/$Y" "$FIX/copyY" main
{ echo "window=fmlab:fm-$Y"; echo "worktree=$FIX/copyY"; echo "project=$P"; echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "branch=fm/$Y"; } > "$LAB/state/$Y.meta"
mkdir -p "$LAB/data/$Y"; printf '%s\n' "Brief $Y" "Ship branch: fm/$Y" > "$LAB/data/$Y/brief.md"
sed -i '' -e '/^backend=/d' -e '/^herdr_/d' -e '/^launch_proof=/d' -e "s#^window=.*#window=fmlab:fm-$T#" "$LAB/state/$T.meta"
bash bin/fm-lock.sh
TIP=$(git -C "$P" rev-parse "refs/heads/fm/$T-v2")
echo "######## record successor fm/$T-v2 for $T"
bash bin/fm-control.sh "$T" successor --branch "fm/$T-v2" --tip "$TIP" --note "reassoc proof" 2>&1 | grep -v fm-gate-refuse | head -1
# Replacement copies.
git -C "$P" worktree add -q -b "fm/$T-other" "$FIX/copyA" "fm/$T"
git -C "$P" worktree add -q "$FIX/copyB" "fm/$T-v2"
cp -p "$LAB/state/$T.meta" "$FIX/T.meta.0"; cp -p "$LAB/state/$Y.meta" "$FIX/Y.meta.0"
echo; echo "######## 1. reassociate $T onto a copy on a branch other than its recorded successor -> refuse"
bash bin/fm-control.sh "$T" reassociate --worktree "$FIX/copyA" --note "try other" 2>&1 | grep -v fm-gate-refuse; echo "[exit=${PIPESTATUS[0]}]"
cmp "$FIX/T.meta.0" "$LAB/state/$T.meta" && echo "record of $T unchanged"
echo; echo "######## 2. reassociate other task $Y onto a copy on $T's claimed successor -> refuse"
bash bin/fm-control.sh "$Y" reassociate --worktree "$FIX/copyB" --note "take claimed" 2>&1 | grep -v fm-gate-refuse; echo "[exit=${PIPESTATUS[0]}]"
cmp "$FIX/Y.meta.0" "$LAB/state/$Y.meta" && echo "record of $Y unchanged"
echo; echo "######## 3. fresh spawn of a ship whose branch is $T's claimed successor -> refuse before creating anything"
ls "$LAB/state" | sort > "$FIX/state.ls0"
bash bin/fm-spawn.sh "$T-v2" "$P" --mode no-mistakes --yolo off --harness claude 2>&1 | grep -v -e fm-gate-refuse -e '^●' | tail -3; echo "[exit=${PIPESTATUS[0]}]"
ls "$LAB/state" | sort | diff "$FIX/state.ls0" - && echo "no new state files"
echo; echo "######## 4. reassociate $T onto its successor copy -> moves and drops successor lines"
bash bin/fm-control.sh "$T" reassociate --worktree "$FIX/copyB" --note "move onto successor" 2>&1 | grep -v fm-gate-refuse | cut -c1-400; echo "[exit=${PIPESTATUS[0]}]"
echo "-- record after:"; grep -E '^(worktree|branch|successor|prior_worktree)' "$LAB/state/$T.meta"
echo "-- brief Ship branch lines:"; grep '^Ship branch' "$LAB/data/$T/brief.md"
echo; echo "######## guard events"
jq -c 'select(.guard=="successor-branch-admission") | {decision,rule,route,task,successor}' "$FM_GUARD_EVENT_LOG"
echo; echo "== teardown"
bin/fm-lab-home.sh teardown "$LAB" && chmod -R u+w "$LAB" && rm -rf "$LAB"
rm -rf "$FIX"; ls -d "$LAB" "$FIX" 2>&1
