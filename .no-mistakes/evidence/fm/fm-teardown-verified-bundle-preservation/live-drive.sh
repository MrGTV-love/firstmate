#!/usr/bin/env bash
# Live drive of the bundle-note retirement on restart. Real bin/fm-tasks-axi.sh,
# real tasks-axi 0.2.6, real bin/fm-fleet-snapshot.sh, in a disposable lab home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5A4VN5CHDW0VF1ZACABHHZK
LAB=$(cat /tmp/fm-lab-path.txt)
cd "$WT" || exit 1

fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" "$WT/bin/fm-tasks-axi.sh" "$@"
}
snap() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" "$WT/bin/fm-fleet-snapshot.sh" --json
}
# Closing uses bare tasks-axi on the home's backlog file, as bin/fm-teardown.sh does.
tdone() { local id=$1; shift; tasks-axi done "$id" "$@" --file "$LAB/data/backlog.md" >/dev/null; }
body() { fm show "$1" --full | sed -n 's/^  body: //p'; }
state() { fm show "$1" --full | sed -n 's/^  state: //p'; }
drop() { snap | jq -c --arg id "$1" '.backlog.records[] | select(.id==$id) | {id,state,captain_drop,pr_url,report_path}'; }

NOTE1="preserved in bundle $LAB/bundles/kept.bundle, not landed"
NOTE2="preserved in bundle $LAB/bundles/second.bundle, not landed"

echo "=== S1: bundle close -> restart -> plain done"
fm add live-a "Live bundle then plain done" --kind ship --repo firstmate >/dev/null
fm start live-a >/dev/null
tdone live-a --note "$NOTE1"
echo "after bundle close: state=$(state live-a) body=$(body live-a)"
echo "snapshot: $(drop live-a)"
fm start live-a >/dev/null
echo "after restart:      state=$(state live-a) body=$(body live-a)"
tdone live-a
echo "after plain done:   state=$(state live-a) body=$(body live-a)"
echo "snapshot: $(drop live-a)"

echo "=== S2: bundle close only (no restart) stays a drop"
fm add live-b "Live bundle only" --kind ship --repo firstmate >/dev/null
fm start live-b >/dev/null
tdone live-b --note "$NOTE1"
echo "snapshot: $(drop live-b)"

echo "=== S4: two bundle cycles"
fm add live-c "Two bundle cycles" --kind ship --repo firstmate >/dev/null
fm start live-c >/dev/null
tdone live-c --note "$NOTE1"
fm start live-c >/dev/null
tdone live-c --note "$NOTE2"
echo "after 2nd bundle close: body=$(body live-c)"
echo "snapshot: $(drop live-c)"
fm start live-c >/dev/null
echo "after 2nd restart:      body=$(body live-c)"
tdone live-c
echo "snapshot after plain done: $(drop live-c)"
