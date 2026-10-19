#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh through disposable labs, one per scenario.
# Usage: live-driver.sh   (writes PASS/FAIL lines and transcripts to stdout)
set -u
export WT_ROOT=${WT_ROOT:-/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M59XQK2HPSW2PNZ9N2PEKW85}
export EVID=${EVID:-/Users/charlesabrooker/.no-mistakes/evidence/01M59XQK2HPSW2PNZ9N2PEKW85}
BASE_SHA=df6448846813245550010ba6c593a7a7b07389d7
cd "$WT_ROOT" || exit 1
. "$EVID/live-lib.sh"

FAILS=0
ck() {  # <label> <command...>: PASS when the command succeeds
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then echo "  PASS  $label"; else echo "  FAIL  $label"; FAILS=$((FAILS + 1)); fi
}
has() { grep -Fq -- "$2" "$1"; }          # has <file> <text>
hasnt() { ! grep -Fq -- "$2" "$1"; }
eq() { [ "$1" = "$2" ]; }
held_close_clean() {                       # a full successful held close left everything alone
  ck "exit code is 0" eq "$LAB_RC" 0
  ck "task record removed" test ! -e "$LAB/state/task-x1.meta"
  ck "backlog item is done" eq "$(lab_backlog_state)" done
  ck "no REFUSED line on stderr" hasnt "$LAB/out.stderr" REFUSED
  ck "foreign copy $(basename "$FOREIGN") is byte-identical" lab_unchanged "$FOREIGN"
  ck "foreign copy still registered" has <(git -C "$PROJECT" worktree list --porcelain) "worktree $FOREIGN"
  ck "slot claim unchanged" cmp -s "$LAB/claim-before" "$(dirname "$SLOT")/.fm-slot-owner"
  ck "slot is durably leased in real treehouse state" eq "$(lab_leased)" true
}

# ---------------------------------------------------------------- S0: before
echo "=== S0  BEFORE the change (base $BASE_SHA): same lab, the close is refused ==="
lab_new s0 || exit 1
BASECODE=$LAB/basecode
mkdir -p "$BASECODE"
git archive "$BASE_SHA" bin | tar -x -C "$BASECODE"
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded ignored
lab_snapshot "$FOREIGN"
lab_teardown "$BASECODE/bin"
lab_show "base code teardown"
ck "base code exits 1" eq "$LAB_RC" 1
ck "base code refuses, naming the foreign copy and 'not proved landed'" has "$LAB/out.stderr" "REFUSED: foreign copy $FOREIGN stays in pool slot $SLOT: its HEAD"
ck "base code prints the 'pool slot contains registered copy' custody refusal too" has "$LAB/out.stderr" "contains registered copy $FOREIGN that is not one of task task-x1's proven copies"
ck "base code left the task record in place (task stuck)" test -e "$LAB/state/task-x1.meta"
ck "base code left the backlog item in flight" eq "$(lab_backlog_state)" in_flight
lab_destroy

echo; echo "=== S0b BEFORE the change (base): foreign copy with ONLY unique ignored files (HEAD landed) ==="
lab_new s0b || exit 1
BASECODE=$LAB/basecode
mkdir -p "$BASECODE"
git archive "$BASE_SHA" bin | tar -x -C "$BASECODE"
lab_slot leased && lab_task_work && lab_record && lab_foreign x "" ignored
lab_teardown "$BASECODE/bin"
lab_show "base code teardown (landed copy with ignored file)"
echo "  (informational: base behaviour for this class, to show what the change did and did not alter)"
lab_destroy

# --------------------------------------------------- S1: headline held close
echo; echo "=== S1  AFTER: landed task closes beside a foreign copy that holds commits on no remote AND ignored files that exist nowhere else ==="
lab_new s1 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded ignored
lab_snapshot "$FOREIGN"
git -C "$PROJECT" rev-parse "refs/heads/fm/other-x" > "$LAB/foreign-branch-before"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown"
held_close_clean
ck "foreign copy's unique ignored file is still there" eq "$(cat "$FOREIGN/unique.dat")" "only here"
ck "foreign copy's unlanded commit is still there" has <(git -C "$FOREIGN" log --oneline -1) "unlanded foreign work"
ck "foreign branch ref did not move" eq "$(git -C "$PROJECT" rev-parse refs/heads/fm/other-x)" "$(cat "$LAB/foreign-branch-before")"
ck "nothing of the held copy was preserved/copied away" test ! -e "$LAB/data/task-x1/nested-copy-preserved"
ck "stdout names the held copy and the deferred slot return" has "$LAB/out.stdout" "held foreign copy $FOREIGN stays in pool slot"
ck "stdout says the slot return is deferred" has "$LAB/out.stdout" "the slot return is deferred"
ck "held record has exactly one line" eq "$(wc -l < "$LAB/data/held-foreign-copies.log" | tr -d ' ')" 1
ck "held record line has 5 tab fields: UTC time, task, slot, copy, reason" \
  awk -F'\t' -v s="$SLOT" -v c="$FOREIGN" 'NF==5 && $1 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$/ && $2=="task-x1" && $3==s && $4==c && $5 ~ /not proved landed$/ {ok=1} END{exit !ok}' "$LAB/data/held-foreign-copies.log"
echo "  -- real treehouse status after the held close:"
(cd "$PROJECT" && TREEHOUSE_ROOT=$POOL treehouse status 2>&1 | sed 's/^/     /')
# Adversarial: a later real `treehouse get` must not hand the held slot out.
NEWSLOT=$(cd "$PROJECT" && TREEHOUSE_ROOT=$POOL treehouse get --lease --lease-holder task-next 2>/dev/null)
echo "  -- a later real 'treehouse get --lease' handed out: $NEWSLOT"
ck "a later treehouse get hands out a DIFFERENT slot, never the held one" test "$(cd "$NEWSLOT" && pwd -P)" != "$SLOT"
ck "held copy still byte-identical after the later treehouse get" lab_unchanged "$FOREIGN"
lab_destroy

# ------------------------------------- S2: plain-get slot gets a durable lease
echo; echo "=== S2  AFTER: slot taken by plain 'treehouse get' (lapsed process lease) is reserved durably by the held close ==="
lab_new s2 || exit 1
lab_slot plain && lab_task_work && lab_record && lab_foreign x unlanded
echo "  -- before: leased=$(lab_leased)"
ck "before the close the slot holds only a process lease (leased is not true)" test "$(lab_leased)" != true
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (plain-get slot)"
held_close_clean
ck "stdout says the slot is reserved under a durable lease" has "$LAB/out.stdout" "is reserved under a durable lease"
NEWSLOT=$(cd "$PROJECT" && TREEHOUSE_ROOT=$POOL treehouse get --lease --lease-holder task-next 2>/dev/null)
echo "  -- a later real 'treehouse get --lease' handed out: $NEWSLOT"
ck "a later treehouse get hands out a DIFFERENT slot" test "$(cd "$NEWSLOT" && pwd -P)" != "$SLOT"
lab_destroy

# ------------------------------------------------ S3: foreign copy is dirty
echo; echo "=== S3  ADVERSARIAL: foreign copy has uncommitted edits -> still refuses, nothing changes; cleaning it lets a rerun close ==="
lab_new s3 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded
printf 'dirty edit\n' >> "$FOREIGN/unlanded.txt"
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (dirty foreign copy)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the foreign copy" has "$LAB/out.stderr" "REFUSED: foreign copy $FOREIGN"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "backlog item still in flight" eq "$(lab_backlog_state)" in_flight
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
ck "slot not returned (still leased)" eq "$(lab_leased)" true
git -C "$FOREIGN" checkout -q -- unlanded.txt
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "rerun after the foreign copy was cleaned"
held_close_clean
lab_destroy

# ---------------------------------- S4: foreign copy owned by another record
echo; echo "=== S4  ADVERSARIAL: another task's record owns the foreign copy -> refuses and names that record ==="
lab_new s4 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded
printf '%s\n' "window=firstmate:fm-task-y1" "endpoint_task_id=task-y1" "worktree=$FOREIGN" \
  "branch=fm/other-x" "project=$PROJECT" "kind=ship" "mode=no-mistakes" "spawn_gen=live-lab-task-y1" > "$LAB/state/task-y1.meta"
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (copy owned by task-y1)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the owning record task-y1" has "$LAB/out.stderr" "task-y1"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "other task's record untouched" test -e "$LAB/state/task-y1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
lab_destroy

# ---------------------------------------- S5: a real process runs in the copy
echo; echo "=== S5  ADVERSARIAL: a live process runs inside the foreign copy -> refuses, process is NOT signalled ==="
lab_new s5 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded
( cd "$FOREIGN" && exec sleep 600 ) &
SLEEPER=$!
sleep 0.5
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (process in the copy, sleeper pid $SLEEPER)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the foreign copy" has "$LAB/out.stderr" "REFUSED: foreign copy $FOREIGN"
ck "the process in the copy is still alive (never signalled)" kill -0 "$SLEEPER"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
lab_destroy

# ------------------------------------------- S6: the task's own work unlanded
echo; echo "=== S6  ADVERSARIAL: the closing task's OWN work is NOT landed -> refuses even though a foreign copy would be held ==="
lab_new s6 || exit 1
lab_slot leased
git -C "$SLOT" switch -q -c fm/task-x1
printf 'task work\n' > "$SLOT/task-work.txt"
git -C "$SLOT" add task-work.txt
git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q -m "task-x1 work (never pushed)"
lab_record && lab_foreign x unlanded ignored
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (own work unlanded)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "backlog item still in flight" eq "$(lab_backlog_state)" in_flight
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
ck "the task's own commit is still in the slot" has <(git -C "$SLOT" log --oneline -1) "never pushed"
lab_destroy

# -------------------------------------------------------------- S7: --force
echo; echo "=== S7  ADVERSARIAL: --force never holds a foreign copy ==="
lab_new s7 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded ignored
lab_snapshot "$FOREIGN"
printf 'Lab fixture words standing in for the captain: discard task-x1 own work if needed.\n' > "$LAB/drop.txt"
lab_teardown "$WT_ROOT/bin" --force --drop-file "$LAB/drop.txt"
lab_show "head teardown --force"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the foreign copy" has "$LAB/out.stderr" "REFUSED: foreign copy $FOREIGN"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
lab_destroy

# ------------------------------ S8: landing check cannot run (origin unreachable)
echo; echo "=== S8  ADVERSARIAL: origin fetch fails -> the copy is NOT held (retryable); after origin returns, a rerun holds it ==="
lab_new s8 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded
lab_snapshot "$FOREIGN"
ORIGIN_REAL=$(git -C "$PROJECT" remote get-url origin)
git -C "$PROJECT" remote set-url origin "$LAB/does-not-exist.git"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (origin unreachable)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal says the landing could not be checked" has "$LAB/out.stderr" "its landing could not be checked because fetching the default branch from origin failed"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
git -C "$PROJECT" remote set-url origin "$ORIGIN_REAL"
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "rerun after origin is reachable again"
held_close_clean
lab_destroy

# -------------------- S9: one holdable copy + one dirty copy -> whole close refuses
echo; echo "=== S9  ADVERSARIAL: two foreign copies, one holdable and one dirty -> the whole close refuses, nothing partial ==="
lab_new s9 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded && HELD=$FOREIGN && lab_foreign y unlanded && DIRTY=$FOREIGN
printf 'dirty edit\n' >> "$DIRTY/unlanded.txt"
lab_snapshot "$HELD" "$DIRTY"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (one holdable, one dirty)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the dirty copy" has "$LAB/out.stderr" "REFUSED: foreign copy $DIRTY"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "holdable copy byte-identical" lab_unchanged "$HELD"
ck "dirty copy byte-identical" lab_unchanged "$DIRTY"
lab_destroy

# ----------------- S10: control: a LANDED foreign copy is still released as before
echo; echo "=== S10 CONTROL: a landed, clean foreign copy is still released and the slot returned (ordinary path unchanged) ==="
lab_new s10 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (landed foreign copy)"
ck "exit code is 0" eq "$LAB_RC" 0
ck "task record removed" test ! -e "$LAB/state/task-x1.meta"
ck "backlog item is done" eq "$(lab_backlog_state)" done
ck "landed foreign copy was removed" test ! -e "$FOREIGN"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "output does not claim a deferred slot return" hasnt "$LAB/out.stdout" "the slot return is deferred"
ck "slot claim released" test ! -e "$(dirname "$SLOT")/.fm-slot-owner"
echo "  -- real treehouse status after the ordinary return:"
(cd "$PROJECT" && TREEHOUSE_ROOT=$POOL treehouse status 2>&1 | sed 's/^/     /')
ck "slot is no longer leased" test "$(lab_leased)" != true
lab_destroy

# --- S11: control: landed foreign copy with unique ignored files -> preserved with hash, then released
echo; echo "=== S11 CONTROL: landed foreign copy with unique ignored files -> ignored files preserved with SHA-256, copy released (standing pool-cleanup authority) ==="
lab_new s11 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x "" ignored
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (landed copy with ignored file)"
ck "exit code is 0" eq "$LAB_RC" 0
ck "landed foreign copy was removed" test ! -e "$FOREIGN"
PRES=$(find "$LAB/data/task-x1" -name unique.dat 2>/dev/null | head -1)
ck "unique.dat preserved under the task data dir" test -n "$PRES"
ck "preserved bytes are identical" eq "$(cat "$PRES" 2>/dev/null)" "only here"
ck "a SHA-256 manifest sits beside it" test -s "$(dirname "$PRES")/SHA256SUMS"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
lab_destroy

# -------- S12: unreadable ignored file next to unlanded commits
echo; echo "=== S12 ADVERSARIAL: foreign copy has unlanded commits AND an ignored file teardown cannot read/hash -> must not discard it ==="
lab_new s12 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded ignored
chmod 000 "$FOREIGN/unique.dat"
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (unreadable ignored file)"
chmod 600 "$FOREIGN/unique.dat" 2>/dev/null
echo "  (informational: exit $LAB_RC; either a refusal or a held close is safe so long as nothing of the copy changed)"
ck "foreign copy's ignored file still exists with its bytes" eq "$(cat "$FOREIGN/unique.dat")" "only here"
ck "foreign copy's unlanded commit still there" has <(git -C "$FOREIGN" log --oneline -1) "unlanded foreign work"
ck "foreign copy still registered" has <(git -C "$PROJECT" worktree list --porcelain) "worktree $FOREIGN"
ck "slot not returned (still leased)" eq "$(lab_leased)" true
lab_destroy

# -------- S13: a hand lock on the foreign copy
echo; echo "=== S13 ADVERSARIAL: foreign copy locked by hand (not Vernant's creation lock) -> refuses ==="
lab_new s13 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded
git -C "$PROJECT" worktree lock --reason "owner is mid-work, do not touch" "$FOREIGN"
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (hand-locked foreign copy)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the foreign copy" has "$LAB/out.stderr" "REFUSED: foreign copy $FOREIGN"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical (lock intact)" lab_unchanged "$FOREIGN"
ck "the hand lock is still in place" has <(git -C "$PROJECT" worktree list --porcelain) "locked owner is mid-work"
lab_destroy

# -------- S14: Vernant creation lock with a LIVE launcher
echo; echo "=== S14 ADVERSARIAL: foreign copy under a Vernant creation lock whose launcher is ALIVE -> refuses, launcher not signalled ==="
lab_new s14 || exit 1
lab_slot leased && lab_task_work && lab_record && lab_foreign x unlanded
sleep 600 &
LAUNCHER=$!
git -C "$PROJECT" worktree lock --reason "vernant-session-active owner=launcher:$LAUNCHER launcher=$LAUNCHER" "$FOREIGN"
lab_snapshot "$FOREIGN"
lab_teardown "$WT_ROOT/bin"
lab_show "head teardown (live launcher $LAUNCHER)"
ck "exit code is 1" eq "$LAB_RC" 1
ck "refusal names the foreign copy" has "$LAB/out.stderr" "REFUSED: foreign copy $FOREIGN"
ck "the live launcher was never signalled" kill -0 "$LAUNCHER"
ck "task record kept" test -e "$LAB/state/task-x1.meta"
ck "no held record written" test ! -e "$LAB/data/held-foreign-copies.log"
ck "foreign copy byte-identical" lab_unchanged "$FOREIGN"
kill "$LAUNCHER" 2>/dev/null; wait "$LAUNCHER" 2>/dev/null
lab_destroy

. "$EVID/live-s15.sh"

lab_sweep
echo
echo "TOTAL FAILS: $FAILS"
exit "$FAILS"
