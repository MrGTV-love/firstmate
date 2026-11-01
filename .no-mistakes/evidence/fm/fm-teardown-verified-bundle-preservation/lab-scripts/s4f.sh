foreign_case() {  # <id> <shape>
  local id=$1
  new_task "$id" || return 1
  FC="$COPY/.claude/worktrees/fc-one"; mkdir -p "${FC%/*}"
  git -C "$PROJ" worktree add -q -b "fc/$id" "$FC" main
  echo 'unpublished foreign bytes' > "$FC/work.txt"; git -C "$FC" add work.txt; git -C "$FC" commit -qm 'unpublished foreign work'
  FHEAD=$(git -C "$FC" rev-parse HEAD)
  SRC=$SCR/$id.bundle; mkdir -p "$FM_HOME/data/$id"
  git -C "$PROJ" bundle create "$SRC" --all 2>/dev/null
  printf '%s\t%s\t%s\n' "$SRC" "$(shasum -a 256 "$SRC" | awk '{print $1}')" "$(git bundle list-heads "$SRC" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)" > "$FM_HOME/data/$id/preservation-bundles.tsv"
  hold_call "$id" "$SRC" "$(cut -f3 "$FM_HOME/data/$id/preservation-bundles.tsv")" >/dev/null
  PID=
  case "$2" in
    dirty) echo unsaved >> "$FC/work.txt" ;;
    ignored-blocked|ignored)
      printf 'unique.dat\n' >> "$(git -C "$FC" rev-parse --path-format=absolute --git-path info/exclude)"
      echo 'only copy' > "$FC/unique.dat"
      [ "$2" = ignored ] || : > "$FM_HOME/data/$id/nested-copy-preserved" ;;
    process) ( cd "$FC" && exec sleep 600 ) & PID=$!; sleep 1 ;;
  esac
}
for shape in clean dirty ignored ignored-blocked process; do
  id=t-s4f-$shape
  echo; echo "=== S4f foreign nested copy (not named in the task record), valid bundle + call, shape=$shape ==="
  foreign_case $id $shape
  echo "foreign copy: $FC  HEAD $FHEAD"
  td $id
  present "$FC/.git"; present "$FM_HOME/state/$id.meta"
  [ -e "$FC/unique.dat" ] && echo "unique.dat in copy: $(cat "$FC/unique.dat")"
  find "$FM_HOME/data/$id" -path '*nested-copy-preserved*' -type f | sed "s|$FM_HOME/||"
  [ -f "$FM_HOME/data/held-foreign-copies.log" ] && grep -F "$FC" "$FM_HOME/data/held-foreign-copies.log" | cut -c1-300
  if [ -n "$PID" ]; then kill -0 $PID 2>/dev/null && echo "process $PID still alive (not signalled)" || echo "process $PID is GONE"; kill $PID 2>/dev/null; wait $PID 2>/dev/null; fi
done
echo; echo "=== S4g: process in the task's OWN copy, commits landed (merged), BASE vs NEW code ==="
for CODE in base new; do
  [ "$CODE" = base ] && TDBIN=$SCR/base/bin/fm-teardown.sh || TDBIN=$WT/bin/fm-teardown.sh
  id=t-s4g-$CODE; new_task $id; git -C "$PROJ" merge -q --ff-only "fm/$id" && git -C "$PROJ" push -q origin main
  ( cd "$COPY" && exec sleep 600 ) & PID=$!; sleep 1
  echo "--- $CODE: process $PID in own copy ---"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$TDBIN" $id 2>&1 | grep -e 'reaping' -e REFUSED -e 'complete ('; echo "[exit ${PIPESTATUS[0]}]"
  kill -0 $PID 2>/dev/null && echo "process $PID still alive" || echo "process $PID reaped"; kill $PID 2>/dev/null; wait $PID 2>/dev/null
done
