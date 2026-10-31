#!/usr/bin/env bash
# Live driver 2: nested copy (real git worktree remove), one and two unpushed tips, own-copy process.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M68GF830317Z1CY4KG3GZSJ4
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M68GF830317Z1CY4KG3GZSJ4/live
cd "$WT"
. tests/fm-teardown-helpers.sh
T="$EV/transcript-removal.txt"; : > "$T"
say() { printf '\n===== %s =====\n' "$*" | tee -a "$T"; }
result() { printf 'RESULT %s: %s\n' "$1" "$2" | tee -a "$T"; }
mk() {  # <name> <tips: one|two|two-listing-one>
  make_nested_slot_case "$1" enclosing .claude/worktrees/bundled
  printf 'recoverable work\n' > "$NESTED_COPY/work.txt"; git -C "$NESTED_COPY" add work.txt
  git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm 'unpublished work'
  B="$NESTED_CASE/bundles/work.bundle"
  if [ "$2" = two-listing-one ]; then
    git -C "$NESTED_COPY" bundle create "$B.tmp" fm/task-x1-v2 2>/dev/null
  fi
  if [ "$2" != one ]; then
    S=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'second tip'); git -C "$NESTED_COPY" update-ref refs/heads/fm/second "$S"
  fi
  # header recipe
  mkdir -p "${B%/*}" "$NESTED_CASE/data/task-x1"
  if [ "$2" = two-listing-one ]; then git -C "$NESTED_COPY" bundle create "$B" HEAD fm/task-x1-v2 2>/dev/null; else git -C "$NESTED_COPY" bundle create "$B" --all 2>/dev/null; fi
  git -C "$NESTED_COPY" bundle verify "$B" >/dev/null 2>&1 || echo "bundle verify failed" | tee -a "$T"
  digest=$(shasum -a 256 "$B" | awk '{print $1}')
  tips=$(git bundle list-heads "$B" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
  printf '%s\t%s\t%s\n' "$B" "$digest" "$tips" > "$NESTED_CASE/data/task-x1/preservation-bundles.tsv"
  seed_backlog_in_flight "$NESTED_CASE"
  FM_HOME="$NESTED_CASE/home" FM_STATE_OVERRIDE="$NESTED_CASE/state" FM_DATA_OVERRIDE="$NESTED_CASE/data" FM_CONFIG_OVERRIDE="$NESTED_CASE/config" PATH="$NESTED_CASE/fakebin:$PATH" \
    "$WT/bin/fm-captain-hold.sh" hold task-x1 --owner captain --reason "Land or drop the unlanded commits of task-x1: preserved in bundle $B, recorded tips $tips." >/dev/null
}
go() {  # <label>
  local rc=0
  FM_HOME="$NESTED_CASE/home" run_teardown "$NESTED_CASE" > "$NESTED_CASE/out" 2>&1 || rc=$?
  { echo "\$ bin/fm-teardown.sh task-x1 ($1)"; sed "s#$TMP_ROOT#<tmp>#g" "$NESTED_CASE/out"; echo "exit=$rc"; echo "copy dir: $([ -e "$NESTED_COPY" ] && echo PRESENT || echo REMOVED)"; echo "git worktree list:"; git -C "$NESTED_CASE/project" worktree list | sed "s#$TMP_ROOT#<tmp>#g"; } | tee -a "$T"
  LAST_RC=$rc
}
for m in one two; do
  say "nested copy, $m unpushed tip(s), bundle --all, captain call held"
  mk "rm-$m" "$m"; go "$m"
  d=$(shasum -a 256 "$B" | awk '{print $1}')
  ok=1; [ "$LAST_RC" = 0 ] && [ ! -e "$NESTED_COPY" ] && grep -q "$d" "$NESTED_CASE/out" || ok=0
  for t in $tips; do grep -q "$t" "$NESTED_CASE/out" || ok=0; done
  r="$TMP_ROOT/restore-$m"; git init -q "$r"; for t in $tips; do git -C "$r" fetch -q "$B" "$t:refs/heads/r-${t:0:8}" || ok=0; done
  [ "$ok" = 1 ] && result "REMOVE-$m" "pass (exit 0, copy directory removed, path+sha+all tips printed, every tip restored from bundle)" || result "REMOVE-$m" FAIL
done
say "nested copy, two unpushed tips, bundle lists only one"
mk rm-partial two-listing-one; go partial
[ "$LAST_RC" = 1 ] && [ -e "$NESTED_COPY/work.txt" ] && grep -q 'bundle does not list unlanded tip' "$NESTED_CASE/out" && result REMOVE-partial "pass (refused, copy kept)" || result REMOVE-partial FAIL
grep '^RESULT' "$T" > "$EV/results-removal.txt"
