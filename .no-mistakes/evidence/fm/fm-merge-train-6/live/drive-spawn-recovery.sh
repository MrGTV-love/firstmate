#!/usr/bin/env bash
# Live drive: pressure refusal, then the same task admitted by the REAL host memory reading and launched for real
# (real tmux on the lab socket, real treehouse with its pool inside the lab, real claude CLI on the normal login).
set -u
WT=$(pwd)
for v in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_MEMORY_FIXTURE_DIR FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE; do unset $v; done
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; L=$FM_HOME; export FM_BACKEND=tmux TREEHOUSE_ROOT=$FM_HOME/pool
echo "lab home: $L"
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$L" && rm -rf "$L"; echo "lab removed"' EXIT
cd "$L"; touch state/.last-watcher-beat
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > .tasks.toml
printf '## In flight\n\n## Queued\n\n## Done\n' > data/backlog.md
P=$L/projects/labproj; mkdir -p "$P"; git -C "$P" init -q -b main; git -C "$P" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m init
tasks-axi add later "lab queued task" --kind ship --repo labproj >/dev/null
mkdir -p data/later; cat > data/later/brief.md <<B
# Task
## Captain's intent
Lab admission check. Print the word ADMITTED and stop. Change no file.

## Firstmate spec
Print the word ADMITTED and stop.

### Out of scope
Everything else.

# Definition of done
Delivery contract: mode=local-only
B
N=$L/native; mkdir -p "$N"
printf '137438953472\n2\ntotal = 3072.00M used = 1565.88M free = 1506.12M\n' > "$N/sysctl"
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 1000.\nPages speculative: 100.\nAnonymous pages: 1048576.\nFile-backed pages: 500000.\nPages purgeable: 1000.\nPages occupied by compressor: 32768.\n' > "$N/vm_stat"
printf '[]\n' > "$N/processes.json"
tmux -L fm-lab new-session -d -s firstmate -c "$WT" -e FM_HOME="$L" 'sleep 600'
export TMUX="$(tmux -L fm-lab display-message -p -t firstmate '#{socket_path},#{pid},0')" TMUX_PANE=%0
snap() { echo "backlog: $(grep 'later' data/backlog.md | head -1)  |  meta: $(ls state/later.meta 2>/dev/null | wc -l | tr -d ' ')  |  windows: $(tmux -L fm-lab list-windows -t firstmate -F '#W' | tr '\n' ' ')"; }
echo "=== pressured"; rc=0; (cd "$WT" && FM_MEMORY_FIXTURE_DIR="$N" "$WT/bin/fm-spawn.sh" later "$P" --mode local-only --yolo off --harness claude 2>&1) | cut -c1-300 | tail -3; rc=${PIPESTATUS[0]}; echo "exit=$rc"; snap
echo "=== real host reading: pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)"; (cd "$WT" && "$WT/bin/fm-spawn.sh" later "$P" --mode local-only --yolo off --harness claude 2>&1) | cut -c1-300 | tail -12; rc=${PIPESTATUS[0]}; echo "exit=$rc"; snap
echo "last reading: $(tail -1 state/memory-readings.jsonl | jq -c '{source,pressure_level,admission,fixture}')"
for f in state/later.meta; do [ -f $f ] && grep -E '^(window|worktree|harness|mode)=' $f | sed "s#$L#<lab>#"; done
sleep 25; W=$(tmux -L fm-lab list-windows -t firstmate -F '#W' | grep -v '^sleep' | tail -1); echo "--- worker pane $W:"; tmux -L fm-lab capture-pane -p -t "firstmate:$W" | grep -v '^$' | tail -15 | cut -c1-160
