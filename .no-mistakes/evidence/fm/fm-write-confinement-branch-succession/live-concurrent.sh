#!/usr/bin/env bash
# Two simultaneous `successor` calls on one task in a lab home: they serialize.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M7MYQZDENGWZ8TC0F3BXCXBA
cd "$WT"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME; export FM_GUARD_EVENT_LOG="$LAB/state/guard-events.jsonl"
T=fm-lab-conc-task
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-scott-conc.XXXXXX")
sed "s/^TASK=fm-slack-second-person-scott\$/TASK=$T/" tests/fixtures/fm-scott-task-shape.sh > "$FIX/maker.sh"
mkdir "$FIX/fx"; bash "$FIX/maker.sh" "$FIX/fx" >/dev/null
P=$FIX/fx/project
cp -p "$FIX/fx/home/state/$T.meta" "$LAB/state/"; mkdir -p "$LAB/data/$T"; cp -p "$FIX/fx/home/data/$T/brief.md" "$LAB/data/$T/"
bash bin/fm-lock.sh
TIP=$(git -C "$P" rev-parse "refs/heads/fm/$T-v2")
for round in 1 2 3; do
  cp -p "$FIX/fx/home/state/$T.meta" "$LAB/state/$T.meta"; cp -p "$FIX/fx/home/data/$T/brief.md" "$LAB/data/$T/brief.md"
  bash bin/fm-control.sh "$T" successor --branch "fm/$T-v2" --tip "$TIP" --note "call A" > "$FIX/a.out" 2>&1 & a=$!
  bash bin/fm-control.sh "$T" successor --branch "fm/$T-v2" --tip "$TIP" --note "call B" > "$FIX/b.out" 2>&1 & b=$!
  wait $a; ra=$?; wait $b; rb=$?
  echo "round $round: A exit=$ra: $(grep -v fm-gate-refuse "$FIX/a.out" | head -1 | cut -c1-90)"
  echo "round $round: B exit=$rb: $(grep -v fm-gate-refuse "$FIX/b.out" | head -1 | cut -c1-90)"
  echo "round $round: successor lines in record=$(grep -c '^successor_branch=' "$LAB/state/$T.meta") proved_tip lines=$(grep -c '^successor_proved_tip=' "$LAB/state/$T.meta") brief sections=$(grep -c '^## Successor branch' "$LAB/data/$T/brief.md") leftover temp/lock files=$(ls -a "$LAB/state" "$LAB/data/$T" | grep -c -E 'successor\.|\.prior\.|\.control-.*\.lock$')"
done
bin/fm-lab-home.sh teardown "$LAB" && chmod -R u+w "$LAB" && rm -rf "$LAB"; rm -rf "$FIX"
