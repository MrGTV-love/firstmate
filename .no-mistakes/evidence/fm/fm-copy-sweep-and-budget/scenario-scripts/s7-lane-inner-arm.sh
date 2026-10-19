#!/usr/bin/env bash
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1
new_world "$LAB"
make_slot vernant 1
S=$SLOT; W=$S/.claude/worktrees
echo "##### A) outer copy holding a DIRTY inner copy that git status cannot see (.claude/worktrees/ ignored): apply keeps both #####"
printf '.claude/worktrees/\n' >> "$(git -C "$S" rev-parse --path-format=absolute --git-path info/exclude)"
add_copy "$S" outer 1
git -C "$W/outer" worktree add -q -b fm/inner "$W/outer/.claude/worktrees/inner"
echo "unsaved work" > "$W/outer/.claude/worktrees/inner/work.txt"
echo "git status in outer sees: '$(git -C "$W/outer" status --porcelain --untracked-files=all)' (empty => invisible)"
snap "$W/outer" > "$LAB/o-before"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" --apply | grep -E 'outer|inner|REMOVED|FAILED'
snap "$W/outer" > "$LAB/o-after"
cmp -s "$LAB/o-before" "$LAB/o-after" && echo "outer + inner byte-identical after apply" || echo "CHANGED"
echo "unsaved file: $(cat "$W/outer/.claude/worktrees/inner/work.txt")"
echo "removal log exists: $([ -e "$LAB/data/copy-sweep.log" ] && echo yes || echo no)"

echo
echo "##### B) lane (secondmate) home, run from the root home #####"
new_world "$LAB"
make_slot vernant 1
mklane() {
  local id=$1 lane="$LAB/lane-$1" proj="$LAB/lane-$1/projects/p"
  mkdir -p "$lane/state" "$lane/data" "$lane/config"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$lane/.fm-secondmate-parent"
  printf -- '- %s - %s (home: %s; scope: fixture; projects: p; added 2026-10-18)\n' "$id" "$id" "$lane" >> "$LAB/data/secondmates.md"
  printf 'kind=secondmate\nhome=%s\n' "$lane" > "$LAB/state/$id.meta"
  mkdir -p "$proj"; git -C "$proj" init -q -b main; echo p > "$proj/README.md"; git -C "$proj" add README.md; git -C "$proj" commit -qm init
  git clone -q --bare "$proj" "$LAB/$id-origin.git"; git -C "$proj" remote add origin "file://$LAB/$id-origin.git"; git -C "$proj" fetch -q origin
}
lcopy() { local proj="$LAB/lane-$1/projects/p" c="$LAB/lane-$1/projects/p/.claude/worktrees/$2"; git -C "$proj" worktree add -q -b "fm/$2" "$c"; echo "$2" > "$c/$2.txt"; git -C "$c" add "$2.txt"; git -C "$c" commit -qm "$2"; git -C "$c" push -q origin "fm/$2"; }
mklane open; lcopy open clean; lcopy open held
printf 'worktree=%s\nkind=ship\n' "$LAB/lane-open/projects/p/.claude/worktrees/held" > "$LAB/lane-open/state/lane-task.meta"
mklane nostate; lcopy nostate only; rm -rf "$LAB/lane-nostate/state"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" | sed "s#$LAB/##g" | grep -E '^(REAP|HELD|ORPH)|container'
echo "--- apply ---"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" --apply | sed "s#$LAB/##g" | grep -E '^(REMOVED|SKIPPED|FAILED)'
for x in open/clean open/held nostate/only; do [ -d "$LAB/lane-${x%%/*}/projects/p/.claude/worktrees/${x##*/}" ] && echo "KEPT    lane-$x" || echo "REMOVED lane-$x"; done

echo
echo "##### C) arm binds the check, the registered shim runs it under the process budget, disarm unbinds #####"
new_world "$LAB"
make_slot vernant 1; add_copy "$SLOT" a 2; add_copy "$SLOT" b 2
printf 'pool vernant 0.001\ninterval 0\n' > "$LAB/config/copy-budget"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-copy-sweep.sh" arm
ls -l "$LAB/state" | grep -E 'copy-sweep'
echo "--- shim body ---"; sed "s#$LAB#<LAB>#g; s#$WT#<WT>#g" "$LAB/state/copy-sweep.check.sh"
echo "--- run the registered shim exactly as the watcher would (no FM_HOME in env) ---"
env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" "$LAB/state/copy-sweep.check.sh" | cut -c1-200 | sed "s#$LAB#<LAB>#g"
ls "$LAB/state" | grep copy-sweep
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-copy-sweep.sh" disarm
echo "after disarm:"; ls "$LAB/state" | grep copy-sweep || echo "(only the size cache remains or nothing)"
