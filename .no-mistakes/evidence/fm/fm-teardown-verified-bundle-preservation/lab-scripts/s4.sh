bundle_ready() {  # <id>: recipe bundle + record + call for the copy as it is now
  local id=$1 src=$SCR/$1.bundle
  record_bundle "$id" "$src" >/dev/null && hold_call "$id" "$src" "$(cut -f3 "$FM_HOME/data/$id/preservation-bundles.tsv")" >/dev/null && echo "valid bundle recorded and call filed for $id"
}
echo "=== S4a: valid bundle, copy has an uncommitted tracked change ==="
new_task t-s4a || exit 1; bundle_ready t-s4a
echo 'unsaved edit' >> "$COPY/work.txt"
td t-s4a; present "$FM_HOME/state/t-s4a.meta"; echo "copy work.txt now:"; cat "$COPY/work.txt"
echo; echo "=== S4b: valid bundle, a live process has its cwd inside the copy ==="
new_task t-s4b || exit 1; bundle_ready t-s4b
( cd "$COPY" && exec sleep 600 ) & PID=$!; sleep 1
echo "live process pid $PID cwd: $(lsof -a -p $PID -d cwd -Fn | sed -n 's/^n//p')"
td t-s4b; present "$FM_HOME/state/t-s4b.meta"
kill -0 $PID 2>/dev/null && echo "process $PID still alive (not signalled)" || echo "process $PID is gone"
kill $PID 2>/dev/null; wait $PID 2>/dev/null
echo; echo "=== S4c: valid bundle on a nested prior copy that holds a unique ignored file ==="
new_task t-s4c || exit 1
NEST="$COPY/.claude/worktrees/side"; mkdir -p "${NEST%/*}"
git -C "$PROJ" worktree add -q -b fm/t-s4c-side "$NEST" main
echo side > "$NEST/side.txt"; git -C "$NEST" add side.txt; git -C "$NEST" commit -qm 'unpublished side work'
printf 'unique.dat\n' >> "$(git -C "$NEST" rev-parse --path-format=absolute --git-path info/exclude)"
echo 'only copy of these bytes' > "$NEST/unique.dat"
echo "prior_worktree=$NEST" >> "$FM_HOME/state/t-s4c.meta"
# The task's single record must cover both copies' tips: bundle --all from the project.
SRC=$SCR/t-s4c.bundle; mkdir -p "$FM_HOME/data/t-s4c"
git -C "$PROJ" bundle create "$SRC" --all 2>/dev/null; git -C "$PROJ" bundle verify "$SRC" >/dev/null 2>&1 && echo "bundle verifies"
printf '%s\t%s\t%s\n' "$SRC" "$(shasum -a 256 "$SRC" | awk '{print $1}')" "$(git bundle list-heads "$SRC" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)" > "$FM_HOME/data/t-s4c/preservation-bundles.tsv"
hold_call t-s4c "$SRC" "$(cut -f3 "$FM_HOME/data/t-s4c/preservation-bundles.tsv")" >/dev/null
echo "--- S4c-1: ignored-file preservation blocked (a plain file sits where data/t-s4c/nested-copy-preserved must be a directory) ---"
: > "$FM_HOME/data/t-s4c/nested-copy-preserved"
td t-s4c; present "$NEST/.git"; echo "unique.dat: $(cat "$NEST/unique.dat" 2>&1)"; present "$FM_HOME/state/t-s4c.meta"
[ -f "$FM_HOME/data/held-foreign-copies.log" ] && { echo "held-foreign-copies.log:"; cat "$FM_HOME/data/held-foreign-copies.log"; }
