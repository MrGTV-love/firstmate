#!/usr/bin/env bash
# S4: unsafe copies are never removed. Each world: squash-merged PR, main moved on with a conflicting edit
# and the forge unreadable, so REAL teardown cannot land the copy and refuses it as 'not landed' (or on its
# own checks), and the fallback's proofs decide. One real treehouse pool slot + tmux pane per case.
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S4-unsafe-copies-are-kept
say "### S4: unsafe copies are kept: exactly one wake, nothing destroyed, nothing forced"
N=200
case_run() {  # <name> <setup-fn> [expected wakes: 1]
  local name=$1 setup=$2 want=${3:-1} id="u$1" i reason
  N=$((N+1))
  say ""; say "=== case $name"
  mkworld "$id" $N || { say "FAIL $name: mkworld"; NFAIL=$((NFAIL+1)); return; }
  main_moves_on "$id"; forge_down $N
  $setup
  prune "$W" arm "$id"
  for i in 1 2 3; do prune "$W" run "$id" --now; done
  reason=$(sed -n 's/^reason=//p' "$STATE/$id.merge-prune" 2>/dev/null | sed "s#$LAB#<LAB>#g")
  say "record state=$(sed -n 's/^state=//p' "$STATE/$id.merge-prune" 2>/dev/null) attempts=$(sed -n 's/^attempts=//p' "$STATE/$id.merge-prune" 2>/dev/null)"
  say "reason: $reason"
  say "teardown said: $(grep -m1 -E '^(REFUSED|error)' "$W/td.log.out" | sed "s#$LAB#<LAB>#g")"
  say "treehouse calls: $(grep -c . "$W/th.log") (destroy: $(destroy_calls "$id")); control calls: $(grep -c . "$W/ctl.log")"
  check "S4/$name copy kept on disk" test -e "$WT"
  check "S4/$name task record kept" test -e "$STATE/$id.meta"
  check "S4/$name treehouse destroy never called" test "$(destroy_calls "$id")" = 0
  check "S4/$name nothing forced" nothing_forced "$id"
  check "S4/$name wakes after three attempts = $want" test "$(wake_count "$id")" = "$want"
  [ "$want" != 1 ] || check "S4/$name the wake names the copy" bash -c "grep -F '$WT' '$STATE/.wake-queue' | grep -q 'merge-prune:$id'"
}
setup_stash()   { printf 'edit\n' >> "$WT/README.md"; git -C "$WT" stash push -q -m "wip of the task"; }
setup_ignored() { printf 'secret\n' > "$WT/notes.local"; }
setup_unpushed(){ printf 'x\n' > "$WT/unpushed.txt"; git -C "$WT" add unpushed.txt; git -C "$WT" commit -q -m "unpushed work"; }
setup_nested()  { git clone -q "$W/origin.git" "$WT/.claude/worktrees/n1" 2>/dev/null; git -C "$WT/.claude/worktrees/n1" config user.name L; git -C "$WT/.claude/worktrees/n1" config user.email l@e.i; printf 'o\n' > "$WT/.claude/worktrees/n1/o.txt"; git -C "$WT/.claude/worktrees/n1" add o.txt; git -C "$WT/.claude/worktrees/n1" commit -q -m "unpushed in nested"; }
setup_clone_side() {  # clean, pushed, on main; an unpushed commit on a side branch and a stash made on it (review round 8)
  local n=$WT/.claude/worktrees/n1
  git clone -q "$W/origin.git" "$n" 2>/dev/null; git -C "$n" config user.name L; git -C "$n" config user.email l@e.i
  git -C "$n" checkout -q -b wip; printf 'side\n' > "$n/side.txt"; git -C "$n" add side.txt; git -C "$n" commit -q -m "unpushed side work"
  printf 'more\n' >> "$n/README.md"; git -C "$n" stash push -q -m "side stash"; git -C "$n" checkout -q main
}
setup_process() { ltmux new-window -d -t firstmate: -n other -c "$WT" "sleep 800"; sleep 1; }
setup_dirty()   { printf 'edit\n' >> "$WT/README.md"; }
setup_hidden()  { git -C "$W/proj" config status.showUntrackedFiles no; printf 'hidden\n' > "$WT/hidden-untracked.txt"; }
setup_unreadable() { mkdir -p "$WT/.claude/locked"; chmod 000 "$WT/.claude/locked"; }
for c in stash ignored unpushed nested clone_side process dirty hidden unreadable; do
  want=1; [ "$c" != unreadable ] || want=any
  case "$c" in
    unreadable) # a failed read may be a retained copy (one wake) or a transient retry (none); either way kept
      c2=$c; id="u$c2"; N=$((N+1)); say ""; say "=== case $c2"
      mkworld "$id" $N; main_moves_on "$id"; forge_down $N; setup_unreadable
      prune "$W" arm "$id"; for i in 1 2 3; do prune "$W" run "$id" --now; done
      say "record: $(tr '\n' '|' < "$STATE/$id.merge-prune" 2>/dev/null | sed "s#$LAB#<LAB>#g")"
      say "teardown said: $(grep -m1 -E '^(REFUSED|error)' "$W/td.log.out" | sed "s#$LAB#<LAB>#g")"
      check "S4/$c2 copy kept on disk" test -e "$WT"
      check "S4/$c2 task record kept" test -e "$STATE/$id.meta"
      check "S4/$c2 treehouse destroy never called" test "$(destroy_calls "$id")" = 0
      check "S4/$c2 nothing forced" nothing_forced "$id"
      check "S4/$c2 at most one wake" test "$(wake_count "$id")" -le 1
      ;;
    *) case_run "$c" "setup_$c" "$want" ;;
  esac
done
finish
