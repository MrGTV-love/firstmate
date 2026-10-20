#!/usr/bin/env bash
# Live scenarios for the held-copy teardown change. See live-lab.sh for the lab.
# Usage: live-scenarios.sh <scenario>...   (or "all")
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/live-lab.sh"

held_log() { cat "$LAB/data/held-foreign-copies.log" 2>/dev/null; }
held_lines() { wc -l < "$LAB/data/held-foreign-copies.log" 2>/dev/null | tr -d ' ' ; }
rec_present() { [ -e "$LAB/state/task-x1.meta" ]; }
slot_present() { [ -d "$SLOT/.git" ] || [ -f "$SLOT/.git" ]; }

# ---------------------------------------------------------------------------
sc_ignored_held() {
  say "S1 landed task closes beside a clean foreign copy whose only blocker is a unique ignored file (plain-get slot)"
  mk_lab ignored-held; take_slot plain; land_own; write_meta
  add_foreign fc-one; ignored_file "$FC" unique.dat
  fingerprint "$FC" > "$LAB/fp.before"
  echo "pool before: $(pool_state)"
  run_td; show
  echo "pool after : $(pool_state)"
  chk "exit 0"                                   [ "$RC" = 0 ]
  chk "no REFUSED line"                           lacks "$ERR" "REFUSED"
  chk "task record removed"                       bash -c '! [ -e "$0" ]' "$LAB/state/task-x1.meta"
  chk "backlog item is done"                      [ "$(backlog_state)" = done ]
  chk "foreign copy byte-identical"               bash -c 'fp=$(cat "$0"); [ -n "$fp" ]' "$LAB/fp.before"
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy fingerprint unchanged" [ $? = 0 ]
  chk "ignored file still there with same bytes"  [ "$(cat "$FC/unique.dat")" = "only here" ]
  chk "no preserved copy made"                    bash -c '! [ -e "$0" ]' "$LAB/data/task-x1/nested-copy-preserved"
  chk "foreign copy still registered"             bash -c 'git -C "$0" worktree list --porcelain | grep -Fq "worktree $1"' "$PROJ" "$FC"
  chk "slot not returned (dir present)"           [ -d "$SLOT" ]
  chk "slot durably leased now"                   bash -c '[ "$(jq -r ".worktrees[0].leased" "$0")" = true ]' "$(pool_state_file)"
  chk "output says slot return is deferred"       has "$OUT" "the slot return is deferred"
  chk "output names the held copy"                has "$OUT" "held foreign copy $FC stays in pool slot"
  chk "output gives no removal command for ignored copy" lacks "$OUT" "worktree remove"
  chk "record has exactly one line"               [ "$(held_lines)" = 1 ]
  echo "--- held-foreign-copies.log:"; held_log | cat -vet | head -5
  say "S1b rerun after the close: no task record, foreign copy untouched"
  run_td; show
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy still unchanged after rerun" [ $? = 0 ]
  chk "record unchanged after rerun"              [ "$(held_lines)" = 1 ]
  echo "--- real treehouse status:"; (cd "$PROJ" && treehouse status 2>&1 | head -5)
  cleanup
}

sc_unlanded_held() {
  say "S2 landed task closes beside a foreign copy holding commits on no remote (durably leased slot)"
  mk_lab unlanded-held; take_slot lease; land_own; write_meta
  add_foreign fc-one; unlanded_commit "$FC"
  fingerprint "$FC" > "$LAB/fp.before"
  pool_state_before=$(pool_state)
  run_td; show
  chk "exit 0"                                   [ "$RC" = 0 ]
  chk "no REFUSED line"                           lacks "$ERR" "REFUSED"
  chk "task record removed"                       bash -c '! [ -e "$0" ]' "$LAB/state/task-x1.meta"
  chk "backlog item is done"                      [ "$(backlog_state)" = done ]
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy fingerprint unchanged" [ $? = 0 ]
  chk "foreign branch still exists"               git -C "$PROJ" rev-parse --verify --quiet refs/heads/fm/other-fc-one
  chk "foreign commit still only in the copy"     bash -c '[ -n "$(git -C "$0" log --oneline HEAD --not --remotes)" ]' "$FC"
  chk "lease unchanged (already durable)"         [ "$(pool_state)" = "$pool_state_before" ]
  chk "output names HEAD-not-landed reason"       has "$OUT" "is not proved landed"
  chk "output tells owner how to list the commits" has "$OUT" "log --oneline HEAD --not --remotes"
  chk "record has exactly one line"               [ "$(held_lines)" = 1 ]
  echo "--- held-foreign-copies.log:"; held_log | cat -vet | head -5
  cleanup
}

sc_both_held() {
  say "S3 two foreign copies of both hold classes: both stay, both listed"
  mk_lab both-held; take_slot lease; land_own; write_meta
  add_foreign fc-ign; ignored_file "$FC" unique.dat; IGN=$FC
  add_foreign fc-unl; unlanded_commit "$FC"; UNL=$FC
  fingerprint "$IGN" > "$LAB/fp.ign"; fingerprint "$UNL" > "$LAB/fp.unl"
  run_td; show
  chk "exit 0"                                   [ "$RC" = 0 ]
  fingerprint "$IGN" | cmp -s - "$LAB/fp.ign"; chk "ignored-class copy unchanged"  [ $? = 0 ]
  fingerprint "$UNL" | cmp -s - "$LAB/fp.unl"; chk "commits-class copy unchanged"  [ $? = 0 ]
  chk "record has two lines"                      [ "$(held_lines)" = 2 ]
  chk "five tab fields per line"                  bash -c 'awk -F"\t" "NF!=5{bad=1} END{exit bad}" "$0"' "$LAB/data/held-foreign-copies.log"
  chk "backlog item is done"                      [ "$(backlog_state)" = done ]
  echo "--- held-foreign-copies.log:"; held_log | cat -vet
  cleanup
}

sc_own_not_landed() {
  say "S4 ADVERSARIAL: the task's own work is NOT landed; a held-class foreign copy must not excuse it"
  mk_lab own-not-landed; take_slot lease
  printf 'task work\n' > "$SLOT/feature.txt"; git -C "$SLOT" add feature.txt
  git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q -m 'unlanded task work'
  write_meta
  add_foreign fc-one; ignored_file "$FC" unique.dat
  fingerprint "$FC" > "$LAB/fp.before"
  run_td; show
  chk "close refused (non-zero)"                  [ "$RC" != 0 ]
  chk "task record still present"                 rec_present
  chk "backlog still in flight"                   [ "$(backlog_state)" != done ]
  chk "slot still present"                        [ -d "$SLOT" ]
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  chk "no held record written"                    bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  chk "own unlanded commit still in slot"         git -C "$SLOT" cat-file -e HEAD:feature.txt
  cleanup
}

sc_dirty_foreign() {
  say "S5 ADVERSARIAL: a foreign copy with an untracked (unsaved) file is not holdable; whole close refuses"
  mk_lab dirty-foreign; take_slot lease; land_own; write_meta
  add_foreign fc-one; ignored_file "$FC" unique.dat; printf 'edit\n' > "$FC/untracked.txt"
  fingerprint "$FC" > "$LAB/fp.before"
  run_td; show
  chk "close refused (non-zero)"                  [ "$RC" != 0 ]
  chk "task record still present"                 rec_present
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  chk "untracked file still there"                [ -f "$FC/untracked.txt" ]
  chk "no held record written"                    bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  cleanup
}

sc_foreign_process() {
  say "S6 ADVERSARIAL: a process outside the teardown runs inside the foreign copy; it is not held and not signalled"
  mk_lab foreign-process; take_slot lease; land_own; write_meta
  add_foreign fc-one; ignored_file "$FC" unique.dat
  (cd "$FC" && exec sleep 600) </dev/null >/dev/null 2>&1 &
  PROCPID=$!
  sleep 1
  fingerprint "$FC" > "$LAB/fp.before"
  run_td; show
  chk "close refused (non-zero)"                  [ "$RC" != 0 ]
  chk "task record still present"                 rec_present
  chk "refusal names the running process pid ($PROCPID)" bash -c 'grep -Fq "process $1 is running in it" "$0"' "$ERR" "$PROCPID"
  chk "outside process was not signalled (alive)" kill -0 "$PROCPID"
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  chk "no held record written"                    bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  kill "$PROCPID" 2>/dev/null; wait "$PROCPID" 2>/dev/null
  cleanup
}

sc_force_never_holds_unlanded() {
  say "S7 ADVERSARIAL: --force never holds a foreign copy with commits on no remote"
  mk_lab force-unlanded; take_slot lease; land_own; write_meta
  add_foreign fc-one; unlanded_commit "$FC"
  fingerprint "$FC" > "$LAB/fp.before"
  printf "live lab: captain words naming task-x1 as droppable\n" > "$LAB/drop.txt"
  run_td --force --drop-file "$LAB/drop.txt"; show
  chk "no drop-file refusal (the --force gate was passed)" lacks "$ERR" "requires --drop-file"
  chk "forced close refused (non-zero)"           [ "$RC" != 0 ]
  chk "task record still present"                 rec_present
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  chk "no held record written"                    bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  cleanup
}

sc_force_preserves_ignored() {
  say "S8 --force on a clean landed foreign copy with a unique ignored file: preserved with SHA-256, copy released (main's behaviour, not a hold)"
  mk_lab force-ignored; take_slot lease; land_own; write_meta
  add_foreign fc-one; ignored_file "$FC" unique.dat
  printf "live lab: captain words naming task-x1 as droppable\n" > "$LAB/drop.txt"
  run_td --force --drop-file "$LAB/drop.txt"; show
  chk "exit 0"                                    [ "$RC" = 0 ]
  chk "foreign copy removed"                      bash -c '! [ -e "$0" ]' "$FC"
  chk "preserved copy exists"                     bash -c 'find "$0" -name unique.dat | grep -q .' "$LAB/data/task-x1/nested-copy-preserved"
  chk "SHA256SUMS written"                        bash -c 'find "$0" -name SHA256SUMS | grep -q .' "$LAB/data/task-x1/nested-copy-preserved"
  chk "preserved bytes match"                     bash -c '[ "$(cat "$(find "$0" -name unique.dat | head -1)")" = "only here" ]' "$LAB/data/task-x1/nested-copy-preserved"
  chk "no held record"                            bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  chk "no deferred-return notice"                 lacks "$OUT" "the slot return is deferred"
  echo "--- preserved tree:"; find "$LAB/data/task-x1/nested-copy-preserved" -type f | sed "s#$LAB/##"
  cleanup
}

sc_no_foreign() {
  say "S9 regression: a slot with no foreign copy closes and the real treehouse takes the slot back"
  mk_lab no-foreign; take_slot lease; land_own; write_meta
  run_td; show
  chk "exit 0"                                    [ "$RC" = 0 ]
  chk "task record removed"                       bash -c '! [ -e "$0" ]' "$LAB/state/task-x1.meta"
  chk "backlog item is done"                      [ "$(backlog_state)" = done ]
  chk "no held record"                            bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  chk "no deferred-return notice"                 lacks "$OUT" "the slot return is deferred"
  chk "slot no longer leased by the task"         bash -c '[ "$(jq -r ".worktrees[0].leased // false" "$0")" != true ]' "$(pool_state_file)"
  echo "pool after: $(pool_state)"; (cd "$PROJ" && treehouse status 2>&1 | head -5)
  cleanup
}

sc_fetch_fails() {
  say "S10 ADVERSARIAL: the default branch cannot be fetched, so a foreign copy's landing cannot be checked: refuse, never hold"
  mk_lab fetch-fails; take_slot lease; land_own; write_meta
  add_foreign fc-one; unlanded_commit "$FC"
  fingerprint "$FC" > "$LAB/fp.before"
  git -C "$PROJ" remote set-url origin "$LAB/work/does-not-exist.git"
  run_td; show
  chk "close refused (non-zero)"                  [ "$RC" != 0 ]
  chk "task record still present"                 rec_present
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  chk "no held record written"                    bash -c '! [ -e "$0" ]' "$LAB/data/held-foreign-copies.log"
  git -C "$PROJ" remote set-url origin "$ORIGIN"
  say "S10b origin restored: the rerun now holds the copy and closes"
  run_td; show
  chk "rerun exit 0"                              [ "$RC" = 0 ]
  chk "record has one line"                       [ "$(held_lines)" = 1 ]
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged after rerun" [ $? = 0 ]
  cleanup
}

sc_control_chars() {
  say "S11 a held copy whose ignored file name holds ESC and CR, in a copy dir named with an apostrophe: notices and record show ? and the command is quoted"
  mk_lab ctrl-chars; take_slot lease; land_own; write_meta
  FC="$SLOT/.claude/worktrees/it's"
  mkdir -p "$SLOT/.claude/worktrees"
  git -C "$PROJ" worktree add -q -b fm/other-quote "$FC" main
  ex=$(git -C "$FC" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' 'esc*name.dat' >> "$ex"
  printf 'only here\n' > "$FC/"$'esc\033[31mred\rname.dat'
  fingerprint "$FC" > "$LAB/fp.before"
  run_td; show | cat -vet | sed 's/^/  | /' > "$LAB/show.vet"; show
  chk "exit 0"                                    [ "$RC" = 0 ]
  chk "no control byte in stdout"                 bash -c '! LC_ALL=C grep -q "[[:cntrl:]]" "$0"' "$OUT"
  chk "no control byte in the record (tabs aside)" bash -c '! LC_ALL=C tr -d "\t\n" < "$0" | LC_ALL=C grep -q "[[:cntrl:]]"' "$LAB/data/held-foreign-copies.log"
  chk "cleaned file name shown in the notice"     has "$OUT" 'esc?[31mred?name.dat'
  chk "cleaned file name shown in the record"     has "$LAB/data/held-foreign-copies.log" 'esc?[31mred?name.dat'
  chk "printed command quotes the copy path with printf %q" has "$OUT" "git -C $(printf '%q' "$FC") status --ignored"
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  cleanup
}

sc_own_nested() {
  say "S12 the task's own copy is nested in the slot beside a foreign copy: only the own nested copy is removed"
  mk_lab own-nested; take_slot lease
  # the task works in a nested copy; the slot root is its prior_worktree
  OWN=$SLOT/.claude/worktrees/own-copy
  mkdir -p "$SLOT/.claude/worktrees"
  git -C "$PROJ" worktree add -q -b fm/task-x1-v2 "$OWN" main
  printf 'task work\n' > "$OWN/feature.txt"; git -C "$OWN" add feature.txt
  git -C "$OWN" -c user.email=t@t -c user.name=t commit -q -m 'task work'
  git -C "$OWN" push -q origin HEAD:refs/heads/fm/task-x1-v2
  git -C "$OWN" push -q origin HEAD:main
  git -C "$PROJ" fetch -q origin
  mkdir -p "$LAB/state" "$LAB/data"
  { echo "window=firstmate:fm-task-x1"; echo "endpoint_task_id=task-x1"; echo "worktree=$OWN"
    echo "branch=fm/task-x1-v2"; echo "project=$PROJ"; echo "kind=ship"; echo "mode=local-only"
    echo "spawn_gen=live-lab-task-x1"; echo "prior_worktree=$SLOT"; } > "$LAB/state/task-x1.meta"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  tasks-axi add task-x1 "live lab task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null
  add_foreign fc-one; unlanded_commit "$FC"
  fingerprint "$FC" > "$LAB/fp.before"
  run_td; show
  chk "exit 0"                                    [ "$RC" = 0 ]
  chk "own nested copy removed"                   bash -c '! [ -e "$0" ]' "$OWN"
  chk "own branch kept"                           git -C "$PROJ" rev-parse --verify --quiet refs/heads/fm/task-x1-v2
  fingerprint "$FC" | cmp -s - "$LAB/fp.before"; chk "foreign copy unchanged" [ $? = 0 ]
  chk "slot root still there"                     [ -d "$SLOT" ]
  chk "backlog item is done"                      [ "$(backlog_state)" = done ]
  chk "record has one line"                       [ "$(held_lines)" = 1 ]
  cleanup
}

main() {
  local all="ignored_held unlanded_held both_held own_not_landed dirty_foreign foreign_process force_never_holds_unlanded force_preserves_ignored no_foreign fetch_fails control_chars own_nested"
  local s
  [ "$#" -gt 0 ] || set -- all
  [ "$1" != all ] || set -- $all
  for s in "$@"; do
    "sc_$s"
  done
  printf '\nTOTAL CHECK FAILURES: %s\n' "$FAILS"
  [ "$FAILS" = 0 ]
}
main "$@"
