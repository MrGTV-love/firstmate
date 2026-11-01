#!/usr/bin/env bash
# Live drive: real fm-spawn.sh in a marked lab home on a real private tmux server, real tasks-axi.
# Host pressure cannot safely be forced high, so the pressure-2 reading alone comes from FM_MEMORY_FIXTURE_DIR.
set -u
WT=$(pwd); ENVLOG=$(mktemp)
for v in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_MEMORY_FIXTURE_DIR FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE; do unset $v; done
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; L=$FM_HOME; export FM_BACKEND=tmux
echo "lab home: $L; TMUX_TMPDIR=$TMUX_TMPDIR"
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$L" && rm -rf "$L"; echo "lab removed"' EXIT
cd "$L"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > .tasks.toml
printf '## In flight\n\n## Queued\n\n## Done\n' > data/backlog.md
P=$L/projects/labproj; mkdir -p "$P"; git -C "$P" init -q -b main; git -C "$P" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m init
printf 'labproj\t%s\n' "$P" > /dev/null
tasks-axi add later "lab queued task" --kind ship --repo labproj >/dev/null
N=$L/native; mkdir -p "$N"
printf '137438953472\n2\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' > "$N/sysctl"
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: 500000.\nPages purgeable: 1000.\nPages occupied by compressor: 32768.\n' > "$N/vm_stat"
printf '[]\n' > "$N/processes.json"
tmux -L fm-lab new-session -d -s primary -c "$WT" -e FM_HOME="$L" 'sleep 300'
export TMUX="$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')" TMUX_PANE=%0
snap() { echo "backlog: $(grep -n 'later' data/backlog.md | head -1)"; echo "meta: $(ls state/*.meta 2>/dev/null | wc -l | tr -d ' ') brief: $(ls data/later 2>/dev/null | wc -l | tr -d ' ') windows: $(tmux -L fm-lab list-windows -t primary -F '#W' | tr '\n' ' ') worktrees: $(git -C "$P" worktree list | wc -l | tr -d ' ')"; }
echo "--- before"; snap
echo; echo "=== 1. batch under native pressure 2 (no capacity declared)"
rc=0; out=$(cd "$WT" && FM_MEMORY_FIXTURE_DIR="$N" "$WT/bin/fm-spawn.sh" "later=$P" --mode local-only --yolo off 2>&1) || rc=$?; printf '%s\n' "$out" | cut -c1-300; echo "exit=$rc"; snap
echo "last reading: $(tail -1 state/memory-readings.jsonl | jq -c '{source,pressure_level,admission,fixture:(.fixture!=null)}')"
echo; echo "=== 2. batch with the project at its declared capacity, healthy host"
printf 'labproj 1\n' > config/project-capacity
tasks-axi add running "lab running task" --kind ship --repo labproj >/dev/null; tasks-axi start running >/dev/null
printf 'window=firstmate:fm-running\nendpoint_task_id=running\nworktree=%s/absent\nproject=%s\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\nspawn_gen=s-running\n' "$L" "$P" > state/running.meta
rc=0; out=$(cd "$WT" && "$WT/bin/fm-spawn.sh" "later=$P" --mode local-only --yolo off 2>&1) || rc=$?; printf '%s\n' "$out" | cut -c1-300; echo "exit=$rc"; snap
rm -f config/project-capacity state/running.meta
echo; echo "=== 3. single spawn under pressure names memory, same refusal, exit 75"
rc=0; out=$(cd "$WT" && FM_MEMORY_FIXTURE_DIR="$N" "$WT/bin/fm-spawn.sh" later "$P" --mode local-only --yolo off 2>&1) || rc=$?; printf '%s\n' "$out" | cut -c1-300; echo "exit=$rc"; snap
echo; echo "=== 4. fm-mem-guard run under pressure stops a new run, runs it when healthy"
rc=0; FM_MEMORY_FIXTURE_DIR="$N" "$WT/bin/fm-mem-guard.sh" run -- echo RUN-EXECUTED-PRESSURED >/dev/null 2>&1 || rc=$?; echo "pressured exit=$rc"
rc=0; "$WT/bin/fm-mem-guard.sh" run -- echo RUN-EXECUTED-REAL-HOST || rc=$?; echo "real host exit=$rc; real pressure=$(sysctl -n kern.memorystatus_vm_pressure_level); reading: $(tail -1 state/memory-readings.jsonl | jq -c '{source,pressure_level,admission,fixture}')"
echo; echo "=== 5. real host memory admits the same queued task; spawn goes past admission"
export TREEHOUSE_ROOT=$L/pool
rc=0; out=$(cd "$WT" && "$WT/bin/fm-spawn.sh" later "$P" --mode local-only --yolo off --harness "${LAB_HARNESS:-claude}" 2>&1) || rc=$?; printf '%s\n' "$out" | cut -c1-400 | tail -25; echo "exit=$rc"; snap
echo "last reading: $(tail -1 state/memory-readings.jsonl | jq -c '{source,pressure_level,admission,fixture}')"
