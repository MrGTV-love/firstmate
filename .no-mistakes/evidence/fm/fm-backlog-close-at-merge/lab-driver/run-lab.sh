#!/usr/bin/env bash
# Live lab for close-at-merge: a marked disposable FM_HOME, the real tasks-axi backlog,
# the real bin/fm-pr-close-items.sh (the step bin/fm-pr-merge.sh runs after a recorded
# merge, and the documented hand retry), and real GitHub read-only merge proof for real
# merged PRs of MrGTV-love/firstmate. Only the PR body text comes from lab files
# ($LAB_BODIES), because no merged PR body carries directive lines yet; scenario C reads
# a real body unchanged. Nothing is written to any forge.
set -u
WT=$1; EV=$2
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$EV/lab-home.stderr")"
LAB=$FM_HOME
trap 'bin/fm-lab-home.sh teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $LAB"; [ ! -e "$LAB" ] && echo "lab gone: yes"' EXIT
export PATH="$EV/lab-driver/fakebin:$PATH"
export LAB_GH_LOG="$EV/lab-gh-calls.log"; : > "$LAB_GH_LOG"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 50
TOML
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tx() { (cd "$LAB" && tasks-axi "$@"); }
add() { tx add "$1" "item $1" --kind "${2:-ship}" >/dev/null || echo "FIXTURE FAIL add $1"; }
st() { tx show "$1" 2>&1 | sed -n 's/^  state: *//p' | head -1; }
deps() { tx show "$1" 2>&1 | sed -n 's/^  deps: *//p' | head -1; }
close() { local rc; echo "\$ bin/fm-pr-close-items.sh $*"; FM_HOME="$LAB" bin/fm-pr-close-items.sh "$@" 2> >(sed "s/^/[stderr] /"); rc=$?; sleep 1; echo "[exit $rc]"; }
show_states() { for i in "$@"; do printf '  %-16s state=%-10s deps=%s\n' "$i" "$(st "$i")" "$(deps "$i")"; done; }
U=https://github.com/MrGTV-love/firstmate/pull

echo "== lab home: $LAB (marker: $(ls -a "$LAB" | tr '\n' ' '))"
for i in lab-merging a-after-tab a-one a-held a-prose a-table a-heading a-link a-fenced a-indented a-oldform a-other d-only d-two; do add "$i"; done
add a-two docs; add 123 ship
tx block d-only --by a-one >/dev/null; tx block d-two --by a-one >/dev/null; tx block d-two --by a-other >/dev/null
tx block 123 --by a-two >/dev/null
tx hold a-held --reason "owner decides" --kind captain >/dev/null
echo; echo "######## Scenario A: merged PR 367 body names items with Closes-backlog-item lines"
echo "-- body:"; sed 1d "$EV/lab-driver/bodies-a/MrGTV-love_firstmate_pull_367"
echo "-- before:"; show_states lab-merging a-after-tab a-one a-two a-held a-prose a-table a-heading a-link a-fenced a-indented a-oldform d-only d-two 123
export LAB_BODIES="$EV/lab-driver/bodies-a"
close lab-merging "$U/367"
echo "-- after:"; show_states lab-merging a-after-tab a-one a-two a-held a-prose a-table a-heading a-link a-fenced a-indented a-oldform d-only d-two 123
echo "-- no-such-item created? $(grep -c 'no-such-item' "$LAB/data/backlog.md") line(s) in backlog"
echo "-- proof lines for 367 in backlog: $(grep -c "$U/367" "$LAB/data/backlog.md")"
echo; echo "######## Scenario A-rerun: same merge again (idempotent)"
close lab-merging "$U/367"
echo "-- proof lines for 367 in backlog: $(grep -c "$U/367" "$LAB/data/backlog.md")"
echo; echo "######## Scenario A-partial: owner releases a-held, rerun closes only the rest"
tx unhold a-held >/dev/null
close lab-merging "$U/367"
show_states a-one a-two a-held
echo "-- proof lines for 367 in backlog: $(grep -c "$U/367" "$LAB/data/backlog.md")"

echo; echo "######## Scenario B: merged train PR 362 with Train-member lines"
for i in b-member-a b-member-x b-member-c b-table-only b-prose-only b-ship-live; do add "$i"; done
add b-meta-docs docs
printf 'kind=docs\nbranch=fm/b-meta-docs\npr=%s\n' "$U/359" > "$LAB/state/b-meta-docs.meta"
printf 'kind=ship\nbranch=fm/b-ship-live\npr=%s\n' "$U/356" > "$LAB/state/b-ship-live.meta"
export LAB_BODIES="$EV/lab-driver/bodies-b"
echo "-- train body:"; sed 1d "$LAB_BODIES/MrGTV-love_firstmate_pull_362"
for n in 360 359 356 352 358; do echo "-- body of $n:"; sed 1d "$LAB_BODIES/MrGTV-love_firstmate_pull_$n"; done
echo "-- meta: b-meta-docs pr=$U/359 (docs, live); b-ship-live pr=$U/356 (ship, live)"
close lab-train "$U/362"
echo "-- after:"; show_states b-member-a b-member-x b-member-c b-meta-docs b-ship-live b-table-only b-prose-only
grep -n "b-member-a\|b-member-c\|b-meta-docs" "$LAB/data/backlog.md" | sed 's/^/  backlog: /'

echo; echo "######## Scenario C: the REAL body of merged train PR 362 (no Train-member line, Component table)"
add fm-merge-train-9; add c-member-339 docs
printf 'kind=docs\nbranch=fm/c-member-339\npr=%s\n' "$U/339" > "$LAB/state/c-member-339.meta"
echo "-- c-member-339 (docs) has live meta pr=$U/339, a row of the real Component table"
unset LAB_BODIES
close lab-real-train "$U/362" 2>&1 | sed -E 's/(.{400}).*/\1 .../'
show_states fm-merge-train-9 c-member-339

echo; echo "######## Scenario D: hand run with an OPEN PR (373)"
add d-open
export LAB_BODIES="$EV/lab-driver/bodies-d"
close lab-open "$U/373"
show_states d-open

echo; echo "######## Scenario E: merge the forge confirmed but could not record (--not-recorded)"
add e-item
mkdir -p "$EV/lab-driver/bodies-e"; printf 'MERGED\nCloses-backlog-item: e-item\n' > "$EV/lab-driver/bodies-e/MrGTV-love_firstmate_pull_366"
export LAB_BODIES="$EV/lab-driver/bodies-e"
close --not-recorded lab-norec "$U/366"
show_states e-item

echo; echo "== backlog file at end:"; cat "$LAB/data/backlog.md"
echo; echo "== gh calls (lab-body = lab body file; real-gh = real GitHub read):"; cat "$LAB_GH_LOG"
echo; echo "== teardown (EXIT trap)"
