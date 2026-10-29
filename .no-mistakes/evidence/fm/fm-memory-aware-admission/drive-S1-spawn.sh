#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh in the lab home, real fm-mem-guard.sh,
# native facts from a fixture dir that reports pressure level 2.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M5ZXMAD5W9SM4DC85WJ38ZQ5
PB=/Users/charlesabrooker/fleet/fm-mini-home/bin/fm-proc-budget.sh
LAB=$1
export FM_HOME=$LAB
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_MEMORY_GUARD_BIN
W=$LAB/spawn-work; rm -rf "$W"; mkdir -p "$W/native"
git init -q --bare "$W/origin.git"
git init -q -b main "$W/project"; git -C "$W/project" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m init
git -C "$W/project" remote add origin "$W/origin.git"; git -C "$W/project" push -q origin main
mkdir -p "$LAB/data/memtask"
printf '# Task\n## Captain'"'"'s intent\nLab memory admission check.\n\n## Firstmate spec\nNothing.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' > "$LAB/data/memtask/brief.md"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
tasks-axi add memtask "lab memory task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
printf '%s\n' codex > "$LAB/config/crew-harness"
# A running worker that must not be touched by a refusal.
sleep 600 & RUNNING=$!
printf '34359738368\n2\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' > "$W/native/sysctl"
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: 500000.\nPages purgeable: 1000.\nPages occupied by compressor: 32768.\n' > "$W/native/vm_stat"
printf '[{"pid":101,"ppid":1,"comm":"xprotectd","started":"start-101","rss_bytes":1073741824,"fleet":false,"run":null}]\n' > "$W/native/processes.json"
echo "### backlog before"; tasks-axi show memtask --file "$LAB/data/backlog.md" | sed -n 's/^  state: */state: /p'
wt_before=$(git -C "$W/project" worktree list --porcelain)
lines_before=$(wc -l < "$LAB/state/memory-readings.jsonl" 2>/dev/null || echo 0)
echo; echo "### S1: \$ FM_HOME=<lab> FM_MEMORY_FIXTURE_DIR=<pressure-2 fixture> bin/fm-spawn.sh memtask <project> --mode no-mistakes --yolo off"
rc=0; FM_MEMORY_FIXTURE_DIR="$W/native" FM_BACKEND=tmux TMUX="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab,1,0" \
  "$PB" --memory-kib 4194304 -- "$WT/bin/fm-spawn.sh" memtask "$W/project" --mode no-mistakes --yolo off || rc=$?
echo "exit=$rc"
echo; echo "### after: task record?"; ls "$LAB/state/memtask.meta" 2>&1
echo "### after: launch brief?"; ls "$LAB/data/memtask/launch-brief.md" 2>&1
echo "### after: worktrees unchanged?"; [ "$wt_before" = "$(git -C "$W/project" worktree list --porcelain)" ] && echo unchanged || echo CHANGED
echo "### after: backlog item"; tasks-axi show memtask --file "$LAB/data/backlog.md" | sed -n 's/^  state: */state: /p'
echo "### after: running worker PID $RUNNING alive?"; kill -0 "$RUNNING" && echo alive || echo GONE
echo "### after: new reading rows (source/pressure/admission/reasons)"
tail -n +"$((lines_before+1))" "$LAB/state/memory-readings.jsonl" | jq -c '{source,fixture,pressure_level,admission,reasons}'
kill "$RUNNING"
