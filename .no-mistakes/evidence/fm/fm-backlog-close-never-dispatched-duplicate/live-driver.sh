#!/usr/bin/env bash
# Live driver: real bin/fm-tasks-axi.sh + real tasks-axi against a disposable lab FM_HOME.
set -u
L=$1
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8CD2Z23PZGAA04HRVY41614
cd "$REPO" || exit 9
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASKS_AXI_REFUSE_OPEN_CALL
export FM_HOME=$L
W=bin/fm-tasks-axi.sh
P=$L/projects/vernant
KEEP=vernant-d3-m1-machine-check-map-v7
PASSES=0; FAILS=0

say() { printf '\n=== %s\n' "$*"; }
ok() { PASSES=$((PASSES+1)); printf 'RESULT: PASS - %s\n' "$*"; }
bad() { FAILS=$((FAILS+1)); printf 'RESULT: FAIL - %s\n' "$*"; }
snap() { cat "$L/data/backlog.md"; (cd "$L" && find state data -print | sort); git -C "$P" for-each-ref; }
note_of() { "$W" show "$1" --full 2>&1 | sed -n 's/^  body: *//p' | head -1; }
state_of() { "$W" show "$1" 2>&1 | sed -n 's/^  state: *//p' | head -1; }
add() { "$W" add "$1" "$2" --kind "${3:-ship}" --repo "${4:-vernant}" >/dev/null || { echo "setup add $1 failed"; exit 9; }; }

# run <label> <want-exit> <want-fragment> <args...>: print the exact command, its exit, its output
refused() {
  local label=$1 want=$2 before after out rc=0; shift 2
  say "$label"
  printf '$ fm-tasks-axi.sh %s\n' "$*"
  before=$(snap)
  out=$("$W" "$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
  after=$(snap)
  if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF -- "$want" && [ "$before" = "$after" ]; then
    ok "$label: refused (exit 2), names '$want', home unchanged"
  else
    bad "$label: rc=$rc, fragment-found=$(printf '%s' "$out" | grep -cF -- "$want"), unchanged=$([ "$before" = "$after" ] && echo yes || echo no)"
  fi
}
closes() {
  local label=$1 id=$2 keep=$3 out rc=0; shift 3
  say "$label"
  printf '$ fm-tasks-axi.sh %s\n' "$*"
  out=$("$W" "$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
  local st nt
  st=$(state_of "$id"); nt=$(note_of "$id")
  printf 'after: state=%s body=%s\n' "$st" "$nt"
  if [ "$rc" -eq 0 ] && [ "$st" = done ] && printf '%s' "$nt" | grep -qF "duplicate of $keep"; then
    ok "$label: exit 0, Done, note 'duplicate of $keep'"
  else
    bad "$label: rc=$rc state=$st body=$nt"
  fi
}

say "SETUP: lab home $L (marker: $(cat "$L/.fm-lab-home" | head -1))"
"$W" list

# S1: the instance shape (note close) stays refused
refused "S1 instance note close stays refused" "completion needs proof of the deliverable" \
  done vernant-d3-m1-v7-follow-up --note "duplicate of $KEEP"

# S2: the instance closes with --duplicate-of
closes "S2 instance closes as duplicate (split form, done)" vernant-d3-m1-v7-follow-up "$KEEP" \
  done vernant-d3-m1-v7-follow-up --duplicate-of "$KEEP"
say "S2 ledger task.closed record"
cat "$L"/state/fleet-ledger* 2>/dev/null || find "$L/state" -name '*ledger*' -exec cat {} \;
say "S2 backlog after close"; cat "$L/data/backlog.md"

# S3: scout row, `task close` spelling, = form
add sc-twin "scout filed twice" scout
closes "S3 scout row closes (task close, = form)" sc-twin "$KEEP" task close sc-twin --duplicate-of="$KEEP"

# S4: each decisive fact flipped refuses with the row unchanged
add f-meta "flip: task record"; printf 'kind=ship\n' > "$L/state/f-meta.meta"
refused "S4a task record exists" "has a task record" done f-meta --duplicate-of "$KEEP"
add f-status "flip: status"; : > "$L/state/f-status.status"
refused "S4b status file exists" "has a dispatch file" done f-status --duplicate-of "$KEEP"
add f-inbox "flip: inbox"; mkdir -p "$L/state/f-inbox.inbox"
refused "S4b inbox dir exists" "has a dispatch file" done f-inbox --duplicate-of "$KEEP"
add f-br "flip: fm branch"; git -C "$P" branch fm/f-br
refused "S4c branch fm/<id>" "has a branch (refs/heads/fm/f-br)" done f-br --duplicate-of "$KEEP"
add f-cx "flip: slashless prefix"; git -C "$P" branch cx-f-cx
refused "S4c branch cx-<id> (slash-less prefix)" "has a branch (refs/heads/cx-f-cx)" done f-cx --duplicate-of "$KEEP"
add f-wt "flip: worktree copy"; git -C "$P" worktree add -q --detach "$L/copies/f-wt"
refused "S4d git worktree copy" "has a copy" done f-wt --duplicate-of "$KEEP"
add f-sk "flip: skipped copies"; mkdir -p "$L/data/f-sk"; : > "$L/data/f-sk/skipped-copies.tsv"
refused "S4d skipped-copies.tsv" "has a recorded copy" done f-sk --duplicate-of "$KEEP"
add f-data "flip: data entry"; mkdir -p "$L/data/f-data"; printf 'brief\n' > "$L/data/f-data/brief.md"; printf 'x\n' > "$L/data/f-data/notes.md"
refused "S4e data/<id> holds more than brief/dod" "only brief.md and dod.md are allowed" done f-data --duplicate-of "$KEEP"
add f-ok-data "allow: brief+dod only"; mkdir -p "$L/data/f-ok-data"; printf 'b\n' > "$L/data/f-ok-data/brief.md"; printf 'd\n' > "$L/data/f-ok-data/dod.md"
closes "S4e-control data/<id> with only brief.md+dod.md closes" f-ok-data "$KEEP" done f-ok-data --duplicate-of "$KEEP"
add f-x "flip: survivor"
refused "S4f survivor does not exist" "is not in the backlog" done f-x --duplicate-of ghost-item
refused "S4g survivor is itself" "cannot be a duplicate of itself" done f-x --duplicate-of f-x
refused "S4h survivor itself closed as duplicate" "itself closed as a duplicate" done f-x --duplicate-of vernant-d3-m1-v7-follow-up
add f-cycle-b "cycle B"
closes "S4h-setup A closes as duplicate of B" f-x f-cycle-b done f-x --duplicate-of f-cycle-b
refused "S4h cycle: B as duplicate of A refused" "itself closed as a duplicate" done f-cycle-b --duplicate-of f-x
add f-fly "flip: in flight"; tasks-axi --version >/dev/null 2>&1; TASKS_AXI_FILE="$L/data/backlog.md" bash -c "cd '$L' && tasks-axi start f-fly" >/dev/null
refused "S4i in-flight row" "is not a plain queued row" done f-fly --duplicate-of "$KEEP"
add f-blk "flip: blocked-by"; TASKS_AXI_FILE="$L/data/backlog.md" bash -c "cd '$L' && tasks-axi block f-blk --by $KEEP" >/dev/null
refused "S4i queued row with a blocked-by edge" "is not a plain queued row" done f-blk --duplicate-of "$KEEP"
add f-dep "flip: dependent"; add waiter "waits on f-dep"; TASKS_AXI_FILE="$L/data/backlog.md" bash -c "cd '$L' && tasks-axi block waiter --by f-dep" >/dev/null
refused "S4l another row waits on it" "waits on f-dep" done f-dep --duplicate-of "$KEEP"
add f-hold "flip: captain hold"; "$W" hold f-hold --reason "captain call" --kind captain >/dev/null 2>&1 \
  || TASKS_AXI_FILE="$L/data/backlog.md" bash -c "cd '$L' && tasks-axi hold f-hold --reason 'captain call' --kind captain" >/dev/null
"$W" show f-hold | grep -E '^  (held|hold_kind):'
refused "S4i held for the captain" "not a plain queued row" done f-hold --duplicate-of "$KEEP"
say "S4m FM_TASKS_AXI_REFUSE_OPEN_CALL=1 with captain hold"
export FM_TASKS_AXI_REFUSE_OPEN_CALL=1
refused "S4m open call opt-in with captain hold" "open owner call" done f-hold --duplicate-of "$KEEP"
unset FM_TASKS_AXI_REFUSE_OPEN_CALL
add f-comb "flip: combined"; printf 'drop it\n' > "$L/words.txt"
refused "S4j combined with --note" "do not combine --duplicate-of" done f-comb --duplicate-of "$KEEP" --note x
refused "S4j combined with --drop-file" "do not combine --duplicate-of" done f-comb --duplicate-of "$KEEP" --drop-file "$L/words.txt"
refused "S4j combined with --pr" "do not combine --duplicate-of" done f-comb --pr https://github.com/o/r/pull/1 --duplicate-of "$KEEP"
add f-norepo "flip: missing project" ship ghostrepo
refused "S4k project path cannot be resolved" "is not at" done f-norepo --duplicate-of "$KEEP"
refused "S4 repeated flag" "only once" done f-comb --duplicate-of "$KEEP" --duplicate-of "$KEEP"
refused "S4 empty value" "requires a value" done f-comb --duplicate-of=

# S5: Done survivors
add sv-pr "survivor landed by PR"; TASKS_AXI_FILE="$L/data/backlog.md" bash -c "cd '$L' && tasks-axi done sv-pr --pr https://github.com/o/r/pull/9" >/dev/null
add twin-pr "twin of sv-pr"
closes "S5 survivor Done by merged PR is accepted" twin-pr sv-pr done twin-pr --duplicate-of sv-pr
add sv-drop "survivor the captain dropped"; "$W" done sv-drop --drop-file "$L/words.txt" >/dev/null 2>&1 || echo "setup drop failed"
add twin-drop "twin of sv-drop"
refused "S5 survivor closed by captain drop refused" "closed by the captain's drop" done twin-drop --duplicate-of sv-drop

# S6: lock race - a task record that appears while the close waits refuses the close
add race "race row"
say "S6 lock race"
bash -c '
  . "$1"; lock="$STATE/.control-race.lock"
  fm_lock_acquire_wait "$lock"; trap "fm_lock_release \"$lock\"" EXIT
  : > "$2/locked"; while [ ! -e "$2/unlock" ]; do sleep 0.05; done
' _ "$REPO/bin/fm-wake-lib.sh" "$L" &
holder=$!
for _ in $(seq 1 200); do [ -e "$L/locked" ] && break; sleep 0.05; done
before=$(cat "$L/data/backlog.md")
"$W" done race --duplicate-of "$KEEP" > "$L/race.out" 2>&1 &
child=$!
sleep 1
if kill -0 "$child" 2>/dev/null; then echo "close is waiting for the lock (pid $child alive)"; fi
printf 'kind=ship\n' > "$L/state/race.meta"; echo "created state/race.meta while the close waited"
: > "$L/unlock"; wait "$holder"; rc=0; wait "$child" || rc=$?
cat "$L/race.out"; echo "exit=$rc"
if [ "$rc" -eq 2 ] && grep -q "has a task record" "$L/race.out" && [ "$before" = "$(cat "$L/data/backlog.md")" ]; then
  ok "S6 close waited on the lock and refused the record that appeared"; else bad "S6 race rc=$rc"; fi
rm -f "$L/state/race.meta" "$L/locked" "$L/unlock"

# S7: existing completion paths unchanged
add plain-ship "no proof"
refused "S7 plain close with no proof still refused" "completion needs proof of the deliverable" done plain-ship
refused "S7 --report on a ship still refused" "a report is not a ship's deliverable" done plain-ship --report data/x.md
closes_drop() { :; }
say "S7 --drop-file still closes with note dropped"
out=$("$W" done plain-ship --drop-file "$L/words.txt" 2>&1); rc=$?; echo "$out"; echo "exit=$rc"; echo "body=$(note_of plain-ship)"
if [ "$rc" -eq 0 ] && note_of plain-ship | grep -q dropped; then ok "S7 drop close unchanged"; else bad "S7 drop close"; fi

say "FINAL BACKLOG"; cat "$L/data/backlog.md"
say "SUMMARY: $PASSES pass, $FAILS fail"
[ "$FAILS" -eq 0 ]
