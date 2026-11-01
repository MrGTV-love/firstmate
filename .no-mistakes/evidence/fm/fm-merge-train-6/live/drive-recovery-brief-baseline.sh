#!/usr/bin/env bash
# Live drive in a lab: (a) relaunch of existing work under pressure is NOT refused, (b) a generated no-mistakes brief routes new runs through the memory guard,
# (c) real baseline command derives from real root probe readings.
set -u
WT=$(pwd)
for v in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ROOT_OVERRIDE FM_MEMORY_FIXTURE_DIR FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE; do unset $v; done
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; L=$FM_HOME; export FM_BACKEND=tmux TREEHOUSE_ROOT=$FM_HOME/pool
echo "lab home: $L"
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$L"; chmod -R u+w "$L"; rm -rf "$L"; [ -e "$L" ] && echo "lab NOT removed" || echo "lab removed"' EXIT
cd "$L"; touch state/.last-watcher-beat
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > .tasks.toml
printf '## In flight\n\n## Queued\n\n## Done\n' > data/backlog.md
P=$L/projects/labproj; mkdir -p "$P"; git -C "$P" init -q -b main; git -C "$P" -c user.email=lab@lab -c user.name=lab commit -q --allow-empty -m init
echo "=== (b) real fm-brief.sh for a no-mistakes ship"
tasks-axi add later "lab queued task" --kind ship --repo labproj >/dev/null
(cd "$WT" && "$WT/bin/fm-brief.sh" nmtask labproj --mode no-mistakes >/dev/null 2>&1); echo "fm-brief rc=$?"; grep -n 'memory pressure\|fm-mem-guard.sh. run\|run -- no-mistakes' data/nmtask/brief.md | sed "s#$L#<lab>#g; s#$WT#<wt>#g" | cut -c1-240
mkdir -p data/later; cat > data/later/brief.md <<B
# Task
## Captain's intent
Lab recovery check. Print the word RUNNING and stop. Change no file.

## Firstmate spec
Print the word RUNNING and stop.

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
echo "=== (a) real spawn on real host reading (pressure=$(sysctl -n kern.memorystatus_vm_pressure_level))"
(cd "$WT" && "$WT/bin/fm-spawn.sh" later "$P" --mode local-only --yolo off --harness claude 2>&1) | grep -a '^spawned\|^error\|^deferred' | sed "s#$L#<lab>#g" | cut -c1-220; echo "exit=${PIPESTATUS[0]}"
awk '/^## /{sec=$0} /later/{print "backlog section: " sec " :: " $0}' data/backlog.md | cut -c1-120
sleep 25; tmux -L fm-lab send-keys -t firstmate:fm-later /exit Enter; sleep 6; echo "worker told to exit; windows: $(tmux -L fm-lab list-windows -t firstmate -F '#W' | tr '\n' ' '); pane fg: $(tmux -L fm-lab display-message -p -t firstmate:fm-later '#{pane_current_command}')"
echo "=== (a) relaunch under native pressure 2 is recovery, not new work"
c0=$(wc -l < state/memory-readings.jsonl); rc=0; out=$(cd "$WT" && FM_MEMORY_FIXTURE_DIR="$N" "$WT/bin/fm-spawn.sh" later --relaunch 2>&1) || rc=$?; printf '%s\n' "$out" | grep -a '^spawned\|^relaunched\|^error\|^deferred\|elaunch' | sed "s#$L#<lab>#g" | cut -c1-260; echo "exit=$rc; admission readings added: $(( $(wc -l < state/memory-readings.jsonl) - c0 )); windows: $(tmux -L fm-lab list-windows -t firstmate -F '#W' | tr '\n' ' ')"
sleep 20; echo "--- relaunched worker pane:"; tmux -L fm-lab capture-pane -p -t firstmate:fm-later 2>/dev/null | grep -v '^$' | grep -a 'RUNNING\|Claude Code v\|bypass' | cut -c1-120; echo "=== (c) real root probes then real baseline"
tmux -L fm-lab kill-window -t firstmate:fm-later 2>/dev/null
rm -f state/.memory-baseline.json
for i in 1 2 3 4; do "$WT/bin/fm-mem-guard.sh" probe | jq -c '{source,pressure_level,non_fleet_max_bytes,calibration:(.calibration//null|tostring|.[0:80]),fixture}'; sleep 3; done
rc=0; "$WT/bin/fm-mem-guard.sh" baseline | jq -c '{source,baseline:(.baseline//null),errors}' | cut -c1-500 || rc=$?; echo "baseline exit=$rc"; ls -la state/.memory-baseline.json 2>&1 | sed "s#$L#<lab>#"; [ -f state/.memory-baseline.json ] && jq -c '{schema,samples,non_fleet_max_bytes,smallest_reading_max_bytes}' state/.memory-baseline.json
