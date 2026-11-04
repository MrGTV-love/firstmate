#!/usr/bin/env bash
# Scenario C rerun: the REAL, unchanged body of merged train PR 362 read through the real gh.
set -u
WT=$1; EV=$2
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$EV/lab-home-c.stderr")"
LAB=$FM_HOME
trap 'bin/fm-lab-home.sh teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $LAB"; [ ! -e "$LAB" ] && echo "lab gone: yes"' EXIT
export PATH="$EV/lab-driver/fakebin:$PATH"
export LAB_GH_LOG="$EV/lab-gh-calls-c.log"; : > "$LAB_GH_LOG"
unset LAB_BODIES FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 50\n' > "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tx() { (cd "$LAB" && tasks-axi "$@"); }
st() { tx show "$1" 2>&1 | sed -n 's/^  state: *//p' | head -1; }
U=https://github.com/MrGTV-love/firstmate/pull
for i in c-member-339 c-member-356; do tx add "$i" "item $i" --kind docs >/dev/null; done
tx add fm-merge-train-9 "the train task" --kind ship >/dev/null
printf 'kind=docs\nbranch=fm/c-member-339\npr=%s\n' "$U/339" > "$LAB/state/c-member-339.meta"
printf 'kind=docs\nbranch=fm/c-member-356\npr=%s\n' "$U/356" > "$LAB/state/c-member-356.meta"
echo "-- c-member-339 and c-member-356 (docs) have live meta pr= rows of the real 362 Component table"
echo "-- directive lines in the real 362 body (column 0):"
gh pr view "$U/362" --json body --jq .body | grep -nE '^(Closes-backlog-item|Train-member|Closes):' || echo "   none"
echo "-- Component table rows in the real body:"
gh pr view "$U/362" --json body --jq .body | grep -n '^| https://github.com/MrGTV-love/firstmate/pull/' | cut -c1-80
echo "\$ bin/fm-pr-close-items.sh fm-merge-train-9 $U/362"
FM_HOME="$LAB" bin/fm-pr-close-items.sh fm-merge-train-9 "$U/362" 2> >(sed 's/^/[stderr] /' | cut -c1-330)
rc=$?; sleep 1; echo "[exit $rc]"
for i in c-member-339 c-member-356 fm-merge-train-9; do printf '  %-16s state=%s\n' "$i" "$(st "$i")"; done
echo "== gh calls:"; grep -v 'pr view .* --json body --jq .body' "$LAB_GH_LOG"
