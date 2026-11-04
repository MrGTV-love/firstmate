#!/usr/bin/env bash
# M3 direct: bin/fm-tasks-axi.sh done with a real merged GitHub PR clears the finished id
# from every blocked-by list; a second, unfinished blocker stays. Raw tasks-axi done does not.
set -u
WT=$1; EV=$2; cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$EV/lab-home-unblock.stderr")"; LAB=$FM_HOME
trap 'bin/fm-lab-home.sh teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 50\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tx() { (cd "$LAB" && tasks-axi "$@"); }
show() { for i in "$@"; do printf '  %-10s state=%-8s deps=%s\n' "$i" "$(tx show "$i" 2>&1 | sed -n 's/^  state: *//p' | head -1)" "$(tx show "$i" 2>&1 | sed -n 's/^  deps: *//p' | head -1)"; done; }
for i in blocker other w-one w-two raw-blocker w-raw; do tx add "$i" "item $i" --kind ship >/dev/null; done
tx block w-one --by blocker >/dev/null; tx block w-two --by blocker >/dev/null; tx block w-two --by other >/dev/null
tx block w-raw --by raw-blocker >/dev/null
echo "-- before:"; show blocker other w-one w-two raw-blocker w-raw
echo "-- ready queue before: $(tx ready 2>/dev/null | grep -o 'w-[a-z]*' | sort -u | tr '\n' ' ')"
echo "\$ bin/fm-tasks-axi.sh done blocker --pr https://github.com/MrGTV-love/firstmate/pull/367"
FM_HOME="$LAB" bin/fm-tasks-axi.sh done blocker --pr https://github.com/MrGTV-love/firstmate/pull/367 2>&1 | grep -v '^ *$' | head -12; echo "[exit ${PIPESTATUS[0]}]"
echo "\$ tasks-axi done raw-blocker   (raw tasks-axi, not the Firstmate route)"
tx done raw-blocker >/dev/null 2>&1; echo "[exit $?]"
echo "-- after:"; show blocker other w-one w-two raw-blocker w-raw
