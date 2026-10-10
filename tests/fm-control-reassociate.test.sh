#!/usr/bin/env bash
# fm-control.sh reassociate: re-point a task record at the replacement copy its
# work moved to, without touching anything else.
#
# These tests pin, hermetically over real throwaway git repositories:
#   1. The happy path re-points worktree=, a ship's branch=, and the brief's
#      Ship branch line, records the copy it left as prior_worktree=, writes
#      the note into the brief, and touches no endpoint.
#   2. The old copy is preserved byte for byte and its committed work is
#      anchored in the primary clone. A pool slot the task leaves is released:
#      its claim is dropped, the record names it only as released_worktree=, and
#      a new spawn may take it; a slot that still holds the task's nested copy
#      stays claimed and refuses allocation.
#   3. bin/fm-crew-state.sh reads the replacement copy's real run after the
#      re-point, where before it could only fall back to the status log.
#   4. Moving the task back undoes a hop instead of growing the history.
#   5. A replacement pool slot with no claim is claimed for the task.
#   6. Every refusal - a copy that is not an isolated worktree of the same
#      project, a copy another record names, a pool slot claimed by another task
#      or carrying an unreadable claim, a detached ship copy, a recorded PR, a
#      worker, the supervision branch, a session that does not own the home,
#      and malformed arguments - changes nothing at all.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-control-reassociate)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
reassociate_cleanup() {
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap reassociate_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid

# A fake ps that reports this test shell as an omp harness, so the shell owns
# the case home's session lock exactly as a main Firstmate session would, and a
# fake tmux that records every call so a test can prove no endpoint was touched
# while still answering the reads fm-crew-state makes for an idle pane. A fake
# no-mistakes serves FM_FAKE_AXI_STATUS for the run lookup.
make_fakebin() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
primary=$(cat "$FM_FAKE_DIR/primary-pid")
case "$*" in
  "-o comm= -p $primary"|"-o args= -p $primary") printf 'omp\n'; exit 0 ;;
esac
exec /bin/ps "$@"
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/endpoint-calls"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "axi ") printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" ;;
  "axi status")
    if [ "${3:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"; else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
  "daemon status") printf 'daemon running (pid 4242)\n' ;;
esac
exit 0
SH
  fm_fake_exit0 "$fb" treehouse
  chmod +x "$fb/ps" "$fb/tmux" "$fb/no-mistakes"
}

# new_case <name> <id>: a home whose session lock this shell owns, a project
# with an origin, and the task's current copy as a linked worktree on fm/<id>
# carrying one extra commit.
new_case() {  # <name> <id>
  local dir="$TMP_ROOT/$1" id=$2
  mkdir -p "$dir/home/state" "$dir/home/data/$id" "$dir/fake"
  make_fakebin "$dir"
  printf '%s\n' "$$" > "$dir/fake/primary-pid"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  : > "$dir/fake/endpoint-calls"
  fm_git_worktree "$dir/proj" "$dir/old" "fm/$id"
  printf 'committed work\n' > "$dir/old/work.txt"
  git -C "$dir/old" add work.txt
  git -C "$dir/old" commit -q -m "old copy work"
  cat > "$dir/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise copy reassociation for $id.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/$id
EOF
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/old" \
    "project=$dir/proj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "branch=fm/$id" \
    "tasktmp=/tmp/fm-$id" \
    "model=default" \
    "effort=default" \
    "spawn_gen=s1.1.1"
  printf '%s\n' "$dir"
}

# add_copy <case-dir> <path> <branch>: a replacement copy, a linked worktree of
# the case project on its own branch.
add_copy() {  # <case-dir> <path> <branch>
  git -C "$1/proj" worktree add --quiet -b "$3" "$2"
}

# add_pool_slot <case-dir> <slot-name> <branch> -> slot path: a linked worktree
# in the fixed Treehouse <pool>/<slot>/<repo> layout, next to a pool state file.
add_pool_slot() {  # <case-dir> <slot-name> <branch>
  local pool="$1/pool"
  mkdir -p "$pool/$2"
  [ -f "$pool/treehouse-state.json" ] || printf '{"worktrees":[]}\n' > "$pool/treehouse-state.json"
  add_copy "$1" "$pool/$2/repo" "$3"
  (cd "$pool/$2/repo" && pwd -P)
}

run_control() {  # <case-dir> <args...>
  local dir=$1
  shift
  (
    unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    [ -z "${FM_FAKE_TASK_ID:-}" ] || export FM_TASK_ID="$FM_FAKE_TASK_ID"
    [ -z "${FM_FAKE_ACTOR:-}" ] || export FM_SUPERVISION_ACTOR="$FM_FAKE_ACTOR"
    HOME="$dir/user-home" PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
      "$CONTROL" "$@" 2>&1
  )
}

run_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" \
    FM_FAKE_DIR="$1/fake" FM_CREW_STATE_NO_FORGE=1 "$CREW_STATE" "$2"
}

# assert_line / assert_no_line <exact-line> <file> <msg>: a whole-line match.
assert_line() {
  grep -Fxq -- "$1" "$2" || fail "$3"
}
assert_no_line() {
  ! grep -Fxq -- "$1" "$2" || fail "$3"
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# A content fingerprint of a copy: head, branch, porcelain status, and every
# file's bytes outside .git, so any change to the copy shows.
copy_fingerprint() {  # <path>
  local path=$1
  git -C "$path" rev-parse HEAD
  git -C "$path" symbolic-ref --quiet HEAD || printf 'detached\n'
  git -C "$path" status --porcelain --untracked-files=all
  (cd "$path" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"
    cksum < "$f"
  done)
}

snapshot_case() {  # <case-dir>
  local dir=$1
  rm -rf "$dir/before"
  mkdir -p "$dir/before"
  cp -R "$dir/home/state" "$dir/before/state"
  cp -R "$dir/home/data" "$dir/before/data"
  copy_fingerprint "$dir/old" > "$dir/before/old.fp"
  : > "$dir/fake/endpoint-calls"
}

assert_case_unchanged() {  # <case-dir> <message>
  local dir=$1 msg=$2
  diff -r "$dir/before/state" "$dir/home/state" >/dev/null \
    || fail "$msg: the task record or other state changed"
  diff -r "$dir/before/data" "$dir/home/data" >/dev/null \
    || fail "$msg: the instructions changed"
  copy_fingerprint "$dir/old" | cmp -s - "$dir/before/old.fp" \
    || fail "$msg: the current copy changed"
  [ ! -s "$dir/fake/endpoint-calls" ] || fail "$msg: an endpoint was touched"
}

run_running() {  # <branch> <head>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "$2"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

test_happy_path_repoints_record_and_preserves_old_copy() {
  local id=reassoc-happy dir new out rc=0 new_real
  dir=$(new_case happy "$id")
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"
  new_real=$(cd "$new" && pwd -P)
  snapshot_case "$dir"
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note "Cut a fresh copy with only the owned paths.") || rc=$?
  expect_code 0 "$rc" "reassociate should succeed for an isolated replacement copy"$'\n'"$out"
  assert_contains "$out" "reassociated $id worktree=$new_real branch=fm/$id-v2 prior=$dir/old slot=none" \
    "reassociate did not report the re-point"
  assert_equals "$new_real" "$(meta_field "$dir" "$id" worktree)" "worktree= did not follow the replacement copy"
  assert_equals 1 "$(grep -c '^worktree=' "$dir/home/state/$id.meta")" "the record must keep exactly one worktree= line"
  assert_equals "fm/$id-v2" "$(meta_field "$dir" "$id" branch)" "branch= did not follow the replacement copy"
  assert_equals "$dir/old" "$(meta_field "$dir" "$id" prior_worktree)" "the copy left behind was not recorded"
  # Every other field is byte-identical.
  grep -v -e '^worktree=' -e '^branch=' -e '^prior_worktree=' "$dir/home/state/$id.meta" > "$dir/after.rest"
  grep -v -e '^worktree=' -e '^branch=' "$dir/before/state/$id.meta" > "$dir/before.rest"
  cmp -s "$dir/before.rest" "$dir/after.rest" || fail "reassociate changed fields it does not own"
  assert_line "Ship branch: fm/$id-v2" "$dir/home/data/$id/brief.md" "the brief's Ship branch line did not follow the record"
  assert_no_line "Ship branch: fm/$id" "$dir/home/data/$id/brief.md" "the brief still names the old branch"
  assert_grep "## Copy reassociation (" "$dir/home/data/$id/brief.md" "the brief did not record the reassociation"
  assert_grep "Work only in $new_real, on branch fm/$id-v2." "$dir/home/data/$id/brief.md" "the brief did not name the replacement copy"
  assert_grep "Cut a fresh copy with only the owned paths." "$dir/home/data/$id/brief.md" "the note did not reach the brief"
  [ ! -e "$dir/home/data/$id/reassociations.log" ] || fail "reassociation created a separate audit log"
  copy_fingerprint "$dir/old" | cmp -s - "$dir/before/old.fp" || fail "the old copy changed"
  [ -f "$dir/old/work.txt" ] || fail "the old copy's committed work was lost"
  [ ! -s "$dir/fake/endpoint-calls" ] || fail "reassociate touched the endpoint: $(cat "$dir/fake/endpoint-calls")"
  [ -z "$(find "$dir/home/state" "$dir/home/data" -name '.*reassociate*' -o -name '.brief.prior.*' -o -name '.slot-owner.prior.*')" ] \
    || fail "reassociate left staging files behind"
  pass "reassociate re-points worktree, branch, and brief, records the old copy and note, and touches nothing else"
}

test_crew_state_reads_the_replacement_run() {
  local id=reassoc-crew dir new out
  dir=$(new_case crew "$id")
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"
  printf 'working: carried the work to a fresh copy\n' > "$dir/home/state/$id.status"
  FM_FAKE_AXI_STATUS=$(run_running "fm/$id-v2" "$(git -C "$new" rev-parse HEAD)")
  export FM_FAKE_AXI_STATUS
  out=$(run_crew_state "$dir" "$id")
  assert_not_contains "$out" "source: run-step" "before the re-point, crew state must not attribute the replacement copy's run to the old copy"
  run_control "$dir" "$id" reassociate --worktree "$new" --note "moved" >/dev/null \
    || fail "reassociate failed in the crew-state case"
  out=$(run_crew_state "$dir" "$id")
  assert_contains "$out" "state: working" "after the re-point, crew state should read the replacement copy's live run"
  assert_contains "$out" "source: run-step" "after the re-point, crew state should answer from the run, not a status-log guess"
  unset FM_FAKE_AXI_STATUS
  pass "fm-crew-state reads the replacement copy's real run after reassociation"
}

test_moving_back_undoes_the_hop() {
  local id=reassoc-undo dir new out rc=0 old_real
  dir=$(new_case undo "$id")
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"
  old_real=$(cd "$dir/old" && pwd -P)
  run_control "$dir" "$id" reassociate --worktree "$new" --note "forward" >/dev/null || fail "forward reassociation failed"
  out=$(run_control "$dir" "$id" reassociate --worktree "$dir/old" --note "that copy was wrong; move back") || rc=$?
  expect_code 0 "$rc" "moving the task back should succeed"$'\n'"$out"
  assert_equals "$old_real" "$(meta_field "$dir" "$id" worktree)" "worktree= did not move back"
  assert_equals "fm/$id" "$(meta_field "$dir" "$id" branch)" "branch= did not move back"
  assert_equals 1 "$(grep -c '^prior_worktree=' "$dir/home/state/$id.meta")" "moving back should leave exactly one prior copy"
  assert_equals "$(cd "$new" && pwd -P)" "$(meta_field "$dir" "$id" prior_worktree)" "the copy moved away from should become the prior copy"
  assert_line "Ship branch: fm/$id" "$dir/home/data/$id/brief.md" "the brief's Ship branch line did not move back"
  assert_grep "that copy was wrong; move back" "$dir/home/data/$id/brief.md" "the brief did not record the return note"
  pass "moving a task back to a prior copy undoes that hop"
}

test_pool_slot_replacement_is_claimed() {
  local id=reassoc-pool dir slot out rc=0
  dir=$(new_case pool "$id")
  slot=$(add_pool_slot "$dir" 3 "fm/$id-v2")
  out=$(run_control "$dir" "$id" reassociate --worktree "$slot" --note "fresh pool slot") || rc=$?
  expect_code 0 "$rc" "a replacement pool slot with no claim should be accepted"$'\n'"$out"
  assert_contains "$out" "slot=claimed" "the replacement slot was not claimed"
  assert_line "task=$id" "$dir/pool/3/.fm-slot-owner" "the replacement slot's claim does not name the task"
  pass "a replacement pool slot with no owner claim is claimed for the task"
}

test_disjoint_pool_slot_is_released_and_reclaimable() {
  local id=reassoc-pool-roundtrip dir slot out
  dir=$(new_case pool-roundtrip "$id")
  slot=$(add_pool_slot "$dir" 1 "fm/$id-slot")
  run_control "$dir" "$id" reassociate --worktree "$slot" --note "move into pool" >/dev/null || fail "pool association failed"
  out=$(run_control "$dir" "$id" reassociate --worktree "$dir/old" --note "move away") || fail "pool reassociation failed: $out"
  assert_contains "$out" "released_slot=$slot" "moving away did not report the released slot"
  [ ! -e "$dir/pool/1/.fm-slot-owner" ] || fail "moving away left the task's claim on the slot it left"
  assert_line "released_worktree=$slot" "$dir/home/state/$id.meta" "the left slot was not recorded as released"
  assert_no_line "prior_worktree=$slot" "$dir/home/state/$id.meta" "the released slot stayed preserved custody"
  assert_grep "whose pool slot was released for reuse" "$dir/home/data/$id/brief.md" "the brief did not say the slot was released"
  run_control "$dir" "$id" reassociate --worktree "$slot" --note "move back" >/dev/null || fail "pool return failed"
  assert_line "task=$id" "$dir/pool/1/.fm-slot-owner" "returning to the released slot did not claim it"
  pass "a disjoint pool slot the task leaves is released, recorded as history, and reclaimable"
}

test_existing_reassociation_log_is_untouched() {
  local id=reassoc-existing-log dir new
  dir=$(new_case existing-log "$id")
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"
  printf 'historical reassociation bytes\n' > "$dir/home/data/$id/reassociations.log"
  cp "$dir/home/data/$id/reassociations.log" "$dir/log-before"
  run_control "$dir" "$id" reassociate --worktree "$new" --note "note lives in brief" >/dev/null || fail "reassociation failed with historical log present"
  cmp -s "$dir/log-before" "$dir/home/data/$id/reassociations.log" || fail "reassociation changed the historical separate log"
  assert_grep 'note lives in brief' "$dir/home/data/$id/brief.md" "reassociation note did not reach brief"
  pass "reassociation leaves a historical separate log untouched and records its note only in the brief"
}

test_old_pool_slot_claim_is_retained() {
  local id dir slot new out rc nested shape
  for shape in claude plain; do
  id="reassoc-oldpool-$shape"
  rc=0
  dir=$(new_case "oldpool-$shape" "$id")
  slot=$(add_pool_slot "$dir" 1 "fm/$id-slot")
  printf 'slot work\n' > "$slot/scratch.txt"
  git -C "$slot" add scratch.txt
  git -C "$slot" commit -qm "slot work"
  printf 'task=%s\nhome=%s\n' "$id" "$dir/home" > "$dir/pool/1/.fm-slot-owner"
  sed -i.bak "s|^worktree=.*|worktree=$slot|" "$dir/home/state/$id.meta"
  sed -i.bak "s|^branch=.*|branch=fm/$id-slot|" "$dir/home/state/$id.meta"
  sed -i.bak "s|^Ship branch: .*|Ship branch: fm/$id-slot|" "$dir/home/data/$id/brief.md"
  rm -f "$dir/home/state/$id.meta.bak" "$dir/home/data/$id/brief.md.bak"
  if [ "$shape" = claude ]; then nested=".claude/worktrees/fm-$id-v2"; else nested="nested-v2"; fi
  new="$slot/$nested"
  mkdir -p "$(dirname "$new")"
  add_copy "$dir" "$new" "fm/$id-v2"
  copy_fingerprint "$slot" > "$dir/slot-before"
  printf 'stray untracked bytes\n' > "$slot/stray.txt"
  expect_refusal "$dir" "an untracked file beside the $shape nested replacement" "stray.txt" 1 \
    "$id" reassociate --worktree "$new" --note "nested replacement copy"
  rm "$slot/stray.txt"
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note "nested replacement copy") || rc=$?
  expect_code 0 "$rc" "a $shape nested replacement copy inside the task's own claimed slot should be accepted"$'\n'"$out"
  assert_line "task=$id" "$dir/pool/1/.fm-slot-owner" "the old slot lost its task claim"
  assert_line "home=$dir/home" "$dir/pool/1/.fm-slot-owner" "the old slot lost its home claim"
  copy_fingerprint "$slot" | cmp -s - "$dir/slot-before" || fail "the old slot copy changed"
  assert_equals "$slot" "$(meta_field "$dir" "$id" prior_worktree)" "the old slot was not recorded as the prior copy"
  out=$(run_control "$dir" "$id" reassociate --worktree "$slot" --note "return to enclosing copy") || rc=$?
  expect_code 0 "$rc" "moving from nested copy back to the task's enclosing pool slot should succeed"$'\n'"$out"
  assert_equals "$slot" "$(meta_field "$dir" "$id" worktree)" "the enclosing pool slot was not restored as current"
  assert_line "task=$id" "$dir/pool/1/.fm-slot-owner" "the enclosing slot lost its task claim on return"
  assert_equals "$new" "$(meta_field "$dir" "$id" prior_worktree)" "the nested copy was not kept as the prior copy"
  copy_fingerprint "$slot" | cmp -s - "$dir/slot-before" || fail "moving back changed the old slot copy"
  done
  pass "own enclosing-to-nested and nested-to-enclosing reassociation keep the slot claimed and exempt only the replacement's own path"
}

test_scout_reassociation_keeps_branch_fields() {
  local id=reassoc-scout dir new out rc=0
  dir=$(new_case scout "$id")
  sed -i.bak -e 's/^kind=ship$/kind=scout/' -e '/^branch=/d' "$dir/home/state/$id.meta"
  rm -f "$dir/home/state/$id.meta.bak"
  new="$dir/new"
  add_copy "$dir" "$new" "scout-copy"
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note "scout moved") || rc=$?
  expect_code 0 "$rc" "a scout's record should reassociate"$'\n'"$out"
  assert_equals "" "$(meta_field "$dir" "$id" branch)" "a scout must not gain a branch= field"
  assert_line "Ship branch: fm/$id" "$dir/home/data/$id/brief.md" "a scout's brief Ship branch line must stay as it was"
  pass "a scout reassociates without gaining delivery-branch fields"
}

# expect_refusal <case-dir> <message> <expected-substring> <expected-code> <args...>
expect_refusal() {
  local dir=$1 msg=$2 want=$3 code=$4 out rc=0
  shift 4
  snapshot_case "$dir"
  out=$(run_control "$dir" "$@") || rc=$?
  expect_code "$code" "$rc" "$msg"$'\n'"$out"
  assert_contains "$out" "$want" "$msg: the refusal lost its reason"
  assert_case_unchanged "$dir" "$msg"
}

test_record_containment_refusals_preserve_both_copies() {
  local id dir new target other_path copy relation field name
  for copy in current replacement; do
    for relation in enclosing nested; do
      for field in worktree home prior_worktree; do
        name="record-$copy-$relation-$field"
        id="reassoc-$name"
        dir=$(new_case "$name" "$id")
        new="$dir/new"
        add_copy "$dir" "$new" "fm/$id-v2"
        if [ "$copy" = current ]; then target="$dir/old"; else target=$new; fi
        if [ "$relation" = enclosing ]; then
          other_path=$dir
        else
          other_path="$target/other-custody"
          mkdir -p "$other_path"
          printf 'other task bytes\n' > "$other_path/owned.txt"
        fi
        ln -s "$other_path" "$dir/other-alias"
        fm_write_meta "$dir/home/state/other.meta" "window=fmses:fm-other" "$field=$dir/other-alias" "project=$dir/proj" "kind=scout"
        copy_fingerprint "$new" > "$dir/new-before"
        expect_refusal "$dir" "$copy overlaps another task's $relation $field" "also task other's recorded $field" 1 \
          "$id" reassociate --worktree "$new" --note overlap
        copy_fingerprint "$new" | cmp -s - "$dir/new-before" || fail "record containment refusal changed the replacement copy"
      done
    done
  done
  pass "both copies reject enclosing and nested cross-task custody through physical aliases"
}

test_slot_claim_containment_refusals_preserve_both_copies() {
  local id dir new target slot copy relation name
  for copy in current replacement; do
    for relation in enclosing nested; do
      name="slot-$copy-$relation"
      id="reassoc-$name"
      dir=$(new_case "$name" "$id")
      new="$dir/new"
      if [ "$relation" = enclosing ]; then
        slot=$(add_pool_slot "$dir" 1 "fm/$id-pool")
        target="$slot/.claude/worktrees/nested"
        mkdir -p "$slot/.claude/worktrees"
        add_copy "$dir" "$target" "fm/$id-nested"
        if [ "$copy" = current ]; then
          sed -i.bak "s|^worktree=.*|worktree=$target|" "$dir/home/state/$id.meta"
          sed -i.bak "s|^branch=.*|branch=fm/$id-nested|" "$dir/home/state/$id.meta"
          sed -i.bak "s|^Ship branch: .*|Ship branch: fm/$id-nested|" "$dir/home/data/$id/brief.md"
          rm -f "$dir/home/state/$id.meta.bak" "$dir/home/data/$id/brief.md.bak"
          add_copy "$dir" "$new" "fm/$id-v2"
        else
          new=$target
        fi
      else
        add_copy "$dir" "$new" "fm/$id-v2"
        if [ "$copy" = current ]; then target="$dir/old"; else target=$new; fi
        slot="$target/managed-pool/1/repo"
        mkdir -p "$target/managed-pool/1"
        printf '{"worktrees":[]}\n' > "$target/managed-pool/treehouse-state.json"
        add_copy "$dir" "$slot" "fm/$id-pool"
      fi
      printf 'task=someone-else\nhome=%s\n' "$dir/home" > "$(dirname "$slot")/.fm-slot-owner"
      copy_fingerprint "$target" > "$dir/target-before"
      copy_fingerprint "$new" > "$dir/new-before"
      cp "$(dirname "$slot")/.fm-slot-owner" "$dir/claim-before"
      expect_refusal "$dir" "$copy overlaps another task's $relation pool slot" "claimed by task someone-else" 1 \
        "$id" reassociate --worktree "$new" --note overlap
      copy_fingerprint "$target" | cmp -s - "$dir/target-before" || fail "slot containment refusal changed the current custody"
      copy_fingerprint "$new" | cmp -s - "$dir/new-before" || fail "slot containment refusal changed the replacement copy"
      cmp -s "$dir/claim-before" "$(dirname "$slot")/.fm-slot-owner" || fail "slot containment refusal changed the owner claim"
    done
  done
  pass "both copies reject foreign enclosing and nested managed pool slot claims"
}

test_refusals_change_nothing() {
  local id=reassoc-refuse dir new slot
  dir=$(new_case refuse "$id")
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"

  mkdir -p "$dir/plain"
  expect_refusal "$dir" "a plain directory" "not inside a git worktree" 1 \
    "$id" reassociate --worktree "$dir/plain" --note n
  mkdir -p "$new/sub"
  expect_refusal "$dir" "a subdirectory of a worktree" "not a worktree root" 1 \
    "$id" reassociate --worktree "$new/sub" --note n
  expect_refusal "$dir" "the project checkout" "the project checkout itself" 1 \
    "$id" reassociate --worktree "$dir/proj" --note n
  fm_git_worktree "$dir/otherproj" "$dir/othercopy" other-branch
  expect_refusal "$dir" "another repository's worktree" "not a checkout of task $id's project repository" 1 \
    "$id" reassociate --worktree "$dir/othercopy" --note n
  expect_refusal "$dir" "the copy already recorded" "nothing to reassociate" 1 \
    "$id" reassociate --worktree "$dir/old" --note n
  expect_refusal "$dir" "a missing path" "is not an existing directory" 1 \
    "$id" reassociate --worktree "$dir/nowhere" --note n

  fm_write_meta "$dir/home/state/other.meta" "window=fmses:fm-other" "worktree=$new" "project=$dir/proj" "kind=ship"
  expect_refusal "$dir" "a replacement another record names" "also task other's recorded worktree" 1 \
    "$id" reassociate --worktree "$new" --note n
  fm_write_meta "$dir/home/state/other.meta" "window=fmses:fm-other" "worktree=$dir/elsewhere" "project=$dir/proj" "kind=ship" "prior_worktree=$dir/old"
  expect_refusal "$dir" "a current copy another record preserves" "also task other's recorded prior_worktree" 1 \
    "$id" reassociate --worktree "$new" --note n
  rm -f "$dir/home/state/other.meta"

  slot=$(add_pool_slot "$dir" 7 "fm/$id-slot")
  printf 'task=someone-else\nhome=%s\n' "$dir/home" > "$dir/pool/7/.fm-slot-owner"
  expect_refusal "$dir" "a pool slot claimed by another task" "claimed by task someone-else" 1 \
    "$id" reassociate --worktree "$slot" --note n
  rm -f "$dir/pool/7/.fm-slot-owner"
  mkdir "$dir/pool/7/.fm-slot-owner"
  expect_refusal "$dir" "a pool slot with an unreadable claim" "cannot be read" 1 \
    "$id" reassociate --worktree "$slot" --note n
  rmdir "$dir/pool/7/.fm-slot-owner"

  git -C "$new" checkout --quiet --detach
  expect_refusal "$dir" "a detached ship copy" "has a detached HEAD" 1 \
    "$id" reassociate --worktree "$new" --note n
  git -C "$new" checkout --quiet "fm/$id-v2"

  printf 'pr=https://github.com/o/r/pull/9\n' >> "$dir/home/state/$id.meta"
  expect_refusal "$dir" "a task with a recorded PR" "already records PR" 1 \
    "$id" reassociate --worktree "$new" --note n
  sed -i.bak '/^pr=/d' "$dir/home/state/$id.meta"
  rm -f "$dir/home/state/$id.meta.bak"

  printf 'Ship branch: fm/unrelated\n' >> "$dir/home/data/$id/brief.md"
  expect_refusal "$dir" "a brief whose Ship branch disagrees" "name a Ship branch other than" 1 \
    "$id" reassociate --worktree "$new" --note n
  sed -i.bak '/^Ship branch: fm\/unrelated$/d' "$dir/home/data/$id/brief.md"
  rm -f "$dir/home/data/$id/brief.md.bak"

  FM_FAKE_TASK_ID=$id expect_refusal "$dir" "a worker" "workers cannot reassociate" 1 \
    "$id" reassociate --worktree "$new" --note n
  FM_FAKE_ACTOR=branch expect_refusal "$dir" "the supervision branch" "the supervision branch never performs this action" 6 \
    "$id" reassociate --worktree "$new" --note n
  printf '1\n' > "$dir/home/state/.lock"
  expect_refusal "$dir" "a session that does not own the home" "requires the actual lock-owning main Firstmate" 1 \
    "$id" reassociate --worktree "$new" --note n
  printf '%s\n' "$$" > "$dir/home/state/.lock"

  expect_refusal "$dir" "no --worktree" "requires --worktree" 1 "$id" reassociate --note n
  expect_refusal "$dir" "no --note" "requires --note" 1 "$id" reassociate --worktree "$new"
  expect_refusal "$dir" "a relaunch option" "apply to 'relaunch' only" 1 \
    "$id" reassociate --worktree "$new" --note n --harness codex
  expect_refusal "$dir" "--worktree on another verb" "apply to 'relaunch' only" 1 \
    "$id" authorize-continuation --worktree "$new"

  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/home/state/$id.meta"
  rm -f "$dir/home/state/$id.meta.bak"
  expect_refusal "$dir" "a secondmate" "applies to a ship or scout" 1 \
    "$id" reassociate --worktree "$new" --note n
  pass "every reassociation refusal leaves the record, instructions, copy, and endpoint untouched"
}

test_failed_publication_keeps_brief_recovery_until_restored() {
  local restore id dir new out rc real_mv backup count
  real_mv=$(command -v mv)
  for restore in success failure; do
    id="reassoc-rollback-$restore"
    dir=$(new_case "rollback-$restore" "$id")
    new="$dir/new"
    add_copy "$dir" "$new" "fm/$id-v2"
    snapshot_case "$dir"
    cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */.$id.meta.reassociate.*) exit 1 ;;
    */.brief.prior.*) [ '$restore' != failure ] || exit 1 ;;
  esac
done
exec "$real_mv" "\$@"
SH
    chmod +x "$dir/fakebin/mv"
    rc=0
    out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note moved) || rc=$?
    expect_code 1 "$rc" "failed metadata publication must refuse"
    cmp -s "$dir/before/state/$id.meta" "$dir/home/state/$id.meta" \
      || fail "failed publication changed the task record"
    copy_fingerprint "$dir/old" | cmp -s - "$dir/before/old.fp" \
      || fail "failed publication changed the original copy"
    count=0
    for backup in "$dir/home/data/$id"/.brief.prior.*; do
      [ -f "$backup" ] || continue
      count=$((count + 1))
      cmp -s "$backup" "$dir/before/data/$id/brief.md" \
        || fail "brief recovery does not contain the original instructions"
      assert_contains "$out" "$backup" "failed restoration must report its retained recovery file"
    done
    if [ "$restore" = failure ]; then
      assert_equals 1 "$count" "failed restoration discarded its recovery copy"
      assert_contains "$(cat "$dir/home/data/$id/brief.md")" "$new" "fixture did not publish the replacement brief"
    else
      assert_equals 0 "$count" "successful restoration kept a spent backup"
      cmp -s "$dir/before/data/$id/brief.md" "$dir/home/data/$id/brief.md" \
        || fail "successful restoration did not restore the original instructions"
    fi
    [ ! -s "$dir/fake/endpoint-calls" ] || fail "failed reassociation touched an endpoint"
  done
  pass "failed publication retains the original brief until restoration succeeds"
}

test_unchanged_ship_branch_requires_consistent_brief() {
  local id=reassoc-same-branch dir new
  dir=$(new_case same-branch "$id")
  new="$dir/new"
  git -C "$dir/old" checkout --quiet --detach
  git -C "$dir/proj" worktree add --quiet "$new" "fm/$id"
  cp "$dir/home/data/$id/brief.md" "$dir/consistent-brief"
  printf 'Ship branch: fm/unrelated\n' >> "$dir/home/data/$id/brief.md"
  expect_refusal "$dir" "an unchanged branch with inconsistent instructions" \
    "name a Ship branch other than" 1 "$id" reassociate --worktree "$new" --note moved
  cp "$dir/consistent-brief" "$dir/home/data/$id/brief.md"
  run_control "$dir" "$id" reassociate --worktree "$new" --note moved >/dev/null \
    || fail "consistent unchanged-branch reassociation refused"
  assert_equals "fm/$id" "$(meta_field "$dir" "$id" branch)" "unchanged branch was rewritten"
  assert_equals "$new" "$(meta_field "$dir" "$id" worktree)" "unchanged-branch copy was not published"
  assert_line "Ship branch: fm/$id" "$dir/home/data/$id/brief.md" "matching branch instructions changed"
  pass "unchanged-branch reassociation validates the brief and preserves matching branch declarations"
}

test_dirty_current_copy_refuses_without_publication() {
  local kind change dir id new path
  for kind in ship scout; do
    for change in staged unstaged untracked; do
      id="reassoc-dirty-$kind-$change"
      dir=$(new_case "dirty-$kind-$change" "$id")
      new="$dir/new"
      add_copy "$dir" "$new" "fm/$id-v2"
      if [ "$kind" = scout ]; then
        fm_write_meta "$dir/home/state/$id.meta" "window=fmses:fm-$id" \
          "endpoint_task_id=$id" "worktree=$dir/old" "project=$dir/proj" "kind=scout"
      fi
      path=work.txt
      case "$change" in
        staged)
          printf 'staged work\n' >> "$dir/old/$path"
          git -C "$dir/old" add "$path"
          ;;
        unstaged) printf 'unstaged work\n' >> "$dir/old/$path" ;;
        untracked)
          path="scratch file.txt"
          printf 'untracked work\n' > "$dir/old/$path"
          ;;
      esac
      expect_refusal "$dir" "$kind $change bytes cannot be left to provider reset" \
        "$path" 1 "$id" reassociate --worktree "$new" --note moved
      [ -z "$(git -C "$dir/proj" for-each-ref --format='%(refname)' refs/fm/anchor/)" ] \
        || fail "dirty refusal published an anchor"
    done
  done
  pass "ships and scouts refuse staged, unstaged, and unignored untracked bytes by name"
}

test_firstmate_hook_artifacts_do_not_block_reassociation() {
  local id=reassoc-hooks dir new out rc=0
  dir=$(new_case hooks "$id")
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"
  mkdir -p "$dir/old/.claude"
  printf '{}\n' > "$dir/old/.claude/settings.local.json"
  printf 'grok hook\n' > "$dir/old/.fm-grok-turnend"
  printf 'kimi hook\n' > "$dir/old/.fm-kimi-turnend"
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note moved) || rc=$?
  expect_code 0 "$rc" "Firstmate's own hook artifacts must not block reassociation"$'\n'"$out"
  assert_equals "$(cd "$new" && pwd -P)" "$(meta_field "$dir" "$id" worktree)" "the record did not follow the replacement copy"
  pass "the old copy's dirty check exempts exactly the hook artifacts teardown exempts"
}

test_provider_reset_preserves_spawned_copy_commits_via_anchor() {
  local id=reassoc-release dir slot new fb out rc=0 first head short anchor branch
  dir=$(new_case provider-release "$id")
  slot=$(add_pool_slot "$dir" 1 "slot-$id")
  fb=$(make_spawn_fakebin "$dir/spawn")
  fm_test_fake_sleep_noop "$fb"
  fm_test_spawn_home "$dir/home" codex
  fm_test_spawn_brief "$dir/home" "$id"
  rm -f "$dir/home/state/$id.meta"
  out=$(fm_test_run_spawn "$dir/home" "$slot" "$fb" "$id" "$dir/proj" --scout) || rc=$?
  expect_code 0 "$rc" "pool spawn should succeed"$'\n'"$out"
  assert_equals "$slot" "$(meta_field "$dir" "$id" worktree)" "spawn did not record copy A"
  printf 'first unlanded bytes\n' > "$slot/first.txt"
  git -C "$slot" add first.txt
  git -C "$slot" commit -qm first-unlanded
  first=$(git -C "$slot" rev-parse HEAD)
  printf 'second unlanded bytes\n' > "$slot/second.txt"
  git -C "$slot" add second.txt
  git -C "$slot" commit -qm second-unlanded
  head=$(git -C "$slot" rev-parse HEAD)
  short=$(git -C "$slot" rev-parse --short HEAD)
  branch=$(git -C "$slot" symbolic-ref --short HEAD)
  anchor="refs/fm/anchor/$id-$short"
  new="$dir/new"
  add_copy "$dir" "$new" "fm/$id-v2"
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note moved) \
    || fail "spawned copy reassociation failed: $out"
  assert_equals "$head" "$(git -C "$dir/proj" rev-parse "$anchor")" "anchor did not resolve to copy A's old HEAD"
  [ ! -e "$dir/pool/1/.fm-slot-owner" ] || fail "the slot the task left kept its claim"
  assert_line "released_worktree=$slot" "$dir/home/state/$id.meta" "the left slot was not recorded as released"
  git -C "$slot" checkout --quiet --detach main
  git -C "$slot" reset --hard --quiet main
  git -C "$slot" clean -fdq
  git -C "$dir/proj" branch -D "$branch" >/dev/null
  git -C "$dir/proj" reflog expire --expire=now --all
  git -C "$dir/proj" gc --prune=now --quiet
  [ ! -e "$slot/first.txt" ] && [ ! -e "$slot/second.txt" ] \
    || fail "provider reset simulation did not remove copy A's files"
  assert_equals "$head" "$(git -C "$dir/proj" rev-parse "$anchor")" "provider reset lost the durable anchor"
  git -C "$dir/proj" merge-base --is-ancestor "$first" "$anchor" \
    || fail "anchor did not preserve the earlier unlanded commit"
  assert_equals "first unlanded bytes" "$(git -C "$dir/proj" show "$anchor:first.txt")" "anchor lost first commit bytes"
  assert_equals "second unlanded bytes" "$(git -C "$dir/proj" show "$anchor:second.txt")" "anchor lost old HEAD bytes"
  assert_equals "$new" "$(meta_field "$dir" "$id" worktree)" "provider reset changed replacement custody"
  fm_test_spawn_brief "$dir/home" "$id-next"
  rc=0
  out=$(fm_test_run_spawn "$dir/home" "$slot" "$fb" "$id-next" "$dir/proj" --scout) || rc=$?
  expect_code 0 "$rc" "a new spawn must be able to take the slot the task left"$'\n'"$out"
  assert_line "task=$id-next" "$dir/pool/1/.fm-slot-owner" "the new spawn did not claim the left slot"
  assert_equals "$slot" "$(meta_field "$dir" "$id-next" worktree)" "the new spawn did not record the left slot"
  pass "spawned copy commits survive provider reset through the anchor, and the slot the task left is reusable"
}

test_nested_replacement_blocks_slot_allocation() {
  local id=reassoc-nested-spawn dir slot fb new out rc=0
  dir=$(new_case nested-spawn "$id")
  slot=$(add_pool_slot "$dir" 1 "slot-$id")
  fb=$(make_spawn_fakebin "$dir/spawn")
  fm_test_fake_sleep_noop "$fb"
  fm_test_spawn_home "$dir/home" codex
  fm_test_spawn_brief "$dir/home" "$id"
  rm -f "$dir/home/state/$id.meta"
  out=$(fm_test_run_spawn "$dir/home" "$slot" "$fb" "$id" "$dir/proj" --scout) || rc=$?
  expect_code 0 "$rc" "pool spawn should succeed"$'\n'"$out"
  new="$slot/.claude/worktrees/replacement"
  mkdir -p "$slot/.claude/worktrees"
  add_copy "$dir" "$new" "fm/$id-v2"
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note "nested S5 copy") \
    || fail "nested reassociation failed: $out"
  assert_line "task=$id" "$dir/pool/1/.fm-slot-owner" "the slot holding the nested copy lost its claim"
  fm_test_spawn_brief "$dir/home" "$id-next"
  rc=0
  out=$(fm_test_run_spawn "$dir/home" "$slot" "$fb" "$id-next" "$dir/proj" --scout) || rc=$?
  expect_code 1 "$rc" "a slot holding a live nested copy must not be allocated"$'\n'"$out"
  assert_contains "$out" "contains task $id's current copy" "the refusal did not name the nested copy's task"
  assert_line "task=$id" "$dir/pool/1/.fm-slot-owner" "the refused spawn changed the slot claim"
  [ ! -e "$dir/home/state/$id-next.meta" ] || fail "the refused spawn published a record"
  pass "a slot holding a reassociated task's nested copy refuses a new allocation"
}

test_anchor_failure_refuses_record_publication() {
  local phase id dir new real_git out rc
  real_git=$(command -v git)
  for phase in write verify; do
    id="reassoc-anchor-$phase"
    dir=$(new_case "anchor-$phase" "$id")
    new="$dir/new"
    add_copy "$dir" "$new" "fm/$id-v2"
    cat > "$dir/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ "\${3:-}" = update-ref ]; then
  [ '$phase' != write ] || exit 1
  '$real_git' "\$@" || exit
  touch '$dir/anchor-written'
  exit 0
fi
if [ '$phase' = verify ] && [ -e '$dir/anchor-written' ]; then
  case "\${3:-} \${4:-} \${5:-}" in
    'rev-parse --verify refs/fm/anchor/'*) exit 1 ;;
  esac
fi
exec '$real_git' "\$@"
EOF
    chmod +x "$dir/fakebin/git"
    snapshot_case "$dir"
    rc=0
    out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note moved) || rc=$?
    expect_code 1 "$rc" "failed anchor $phase must refuse"$'\n'"$out"
    assert_contains "$out" "could not" "anchor failure was not reported"
    assert_case_unchanged "$dir" "failed anchor $phase"
  done
  pass "anchor write and verification failures leave the copy, record, brief, and endpoint untouched"
}

test_non_pool_reassociation_serializes_copy_ownership() {
  local shape dir id other new alias real_git pid i first_rc second_rc retry_rc out
  real_git=$(command -v git)
  for shape in direct alias; do
    id="reassoc-owner-$shape"
    other="reassoc-contender-$shape"
    dir=$(new_case "ownership-$shape" "$id")
    new="$dir/new"
    add_copy "$dir" "$new" "fm/$id-v2"
    add_copy "$dir" "$dir/other" "fm/$other"
    mkdir -p "$dir/home/data/$other"
    printf '# Contender instructions\n' > "$dir/home/data/$other/brief.md"
    fm_write_meta "$dir/home/state/$other.meta" \
      "window=fmses:fm-$other" "endpoint_task_id=$other" \
      "worktree=$dir/other" "project=$dir/proj" "kind=scout"
    cp "$dir/home/state/$other.meta" "$dir/other.before"
    alias=$new
    if [ "$shape" = alias ]; then
      ln -s "$new" "$dir/alias"
      alias="$dir/alias"
    fi
    cat > "$dir/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ "\${3:-}" = update-ref ]; then
  case "\${4:-}" in
    refs/fm/anchor/$id-*)
      : > "$dir/scanned"
      for ((i=0; i < 1000; i++)); do
        [ ! -e "$dir/release" ] || break
        sleep 0.01
      done
      [ -e "$dir/release" ] || exit 1
      ;;
  esac
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$dir/fakebin/git"
    run_control "$dir" "$id" reassociate --worktree "$new" --note moved > "$dir/first.out" &
    pid=$!
    for ((i=0; i < 1000; i++)); do
      [ ! -e "$dir/scanned" ] || break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.01
    done
    second_rc=0
    out=$(run_control "$dir" "$other" reassociate --worktree "$alias" --note moved) || second_rc=$?
    : > "$dir/release"
    first_rc=0
    wait "$pid" || first_rc=$?
    [ -e "$dir/scanned" ] || fail "first reassociation did not finish its ownership scans"
    expect_code 0 "$first_rc" "first reassociation failed: $(cat "$dir/first.out")"
    expect_code 1 "$second_rc" "concurrent non-pool reassociation must refuse: $out"
    assert_contains "$out" "refusing to race it" "concurrent reassociation did not refuse project contention"
    cmp -s "$dir/other.before" "$dir/home/state/$other.meta" || fail "contender published a second owner"
    assert_equals "$new" "$(meta_field "$dir" "$id" worktree)" "first owner was not published"
    retry_rc=0
    out=$(run_control "$dir" "$other" reassociate --worktree "$alias" --note moved) || retry_rc=$?
    expect_code 1 "$retry_rc" "retry must refuse the now-owned copy: $out"
    assert_contains "$out" "recorded worktree" "retry did not recognize the physical copy's owner"
    cmp -s "$dir/other.before" "$dir/home/state/$other.meta" || fail "retry changed the contender"
  done
  pass "non-pool reassociation serializes ownership scans through publication for physical aliases"
}

test_subordinate_reassociation_preserves_ancestor_priors() {
  local id=reassoc-subordinate dir root supervisor home project old new owner owner_id owner_home copy out rc
  dir=$(new_case subordinate "$id")
  root="$dir/root"
  supervisor="$dir/supervisor"
  home="$supervisor/mate"
  mkdir -p "$root/state" "$root/data" "$supervisor/state" "$supervisor/data"
  mv "$dir/home" "$home"
  ln -s "$home" "$dir/home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$supervisor" > "$home/.fm-secondmate-parent"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$supervisor/.fm-secondmate-parent"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  printf 'supervisor\n' > "$supervisor/.fm-secondmate-home"
  printf -- '- supervisor - supervisor (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' "$supervisor" > "$root/data/secondmates.md"
  printf -- '- mate - mate (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' "$home" > "$supervisor/data/secondmates.md"
  fm_write_meta "$root/state/supervisor.meta" "kind=secondmate" "home=$supervisor" "worktree=$supervisor"
  fm_write_meta "$supervisor/state/mate.meta" "kind=secondmate" "home=$home" "worktree=$home"
  project="$home/projects/P"
  mkdir -p "$home/projects"
  git clone --quiet "$dir/proj" "$project"
  old="$project/.claude/worktrees/A"
  new="$project/.claude/worktrees/B"
  git -C "$project" worktree add --quiet -b "fm/$id" "$old" "origin/fm/$id"
  git -C "$project" worktree add --quiet -b "fm/$id-v2" "$new" main
  fm_write_meta "$home/state/$id.meta" "window=fmses:fm-$id" "endpoint_task_id=$id" \
    "kind=ship" "worktree=$old" "project=$project" "branch=fm/$id"
  for owner in "$root/state/supervisor.meta" "$supervisor/state/mate.meta"; do
    owner_id=${owner##*/}
    owner_id=${owner_id%.meta}
    if [ "$owner_id" = supervisor ]; then owner_home=$supervisor; else owner_home=$home; fi
    for copy in "$old" "$new"; do
      printf 'prior_worktree=%s\n' "$copy" >> "$owner"
      expect_refusal "$dir" "ancestor prior copy stays protected" "task $owner_id's recorded prior_worktree" 1 \
        "$id" reassociate --worktree "$new" --note moved
      fm_write_meta "$owner" "kind=secondmate" "home=$owner_home" "worktree=$owner_home"
    done
  done
  fm_write_meta "$root/state/impostor.meta" "kind=secondmate" "home=$home" "worktree=$home"
  expect_refusal "$dir" "unvalidated enclosing record stays protected" "task impostor's recorded worktree" 1 \
    "$id" reassociate --worktree "$new" --note moved
  rm "$root/state/impostor.meta"
  rc=0
  out=$(run_control "$dir" "$id" reassociate --worktree "$new" --note moved) || rc=$?
  expect_code 0 "$rc" "validated ancestors should permit nested S5 reassociation: $out"
  assert_equals "$new" "$(meta_field "$dir" "$id" worktree)" "subordinate record did not follow B"
  assert_equals "$old" "$(meta_field "$dir" "$id" prior_worktree)" "subordinate record lost A custody"
  assert_equals "committed work" "$(cat "$old/work.txt")" "subordinate reassociation changed A bytes"
  [ ! -s "$dir/fake/endpoint-calls" ] || fail "subordinate reassociation touched an endpoint"
  pass "nested S5 reassociation admits validated owning ancestors through aliases but preserves every ancestor prior"
}

test_same_origin_different_ref_store_refuses_without_changes() {
  local copy checkout id dir old new foreign project branch
  for copy in current replacement; do
    for checkout in linked primary; do
      id="reassoc-ref-store-$copy-$checkout"
      dir=$(new_case "ref-store-$copy-$checkout" "$id")
      git clone --quiet "$(git -C "$dir/proj" remote get-url origin)" "$dir/sibling"
      assert_equals "$(git -C "$dir/proj" remote get-url origin)" \
        "$(git -C "$dir/sibling" remote get-url origin)" "the clones must share an origin"
      [ "$(git -C "$dir/proj" rev-parse --path-format=absolute --git-common-dir)" != \
        "$(git -C "$dir/sibling" rev-parse --path-format=absolute --git-common-dir)" ] \
        || fail "the clones must use different ref stores"
      mkdir -p "$dir/pool/1" "$dir/foreign-pool/1"
      printf '{"worktrees":[]}\n' > "$dir/pool/treehouse-state.json"
      printf '{"worktrees":[]}\n' > "$dir/foreign-pool/treehouse-state.json"
      git -C "$dir/proj" worktree move "$dir/old" "$dir/pool/1/repo"
      ln -s "$dir/pool/1/repo" "$dir/old"
      old="$dir/pool/1/repo"
      new=$(add_pool_slot "$dir" 2 "fm/$id-v2")
      foreign="$dir/sibling"
      if [ "$checkout" = linked ]; then
        foreign="$dir/foreign-pool/1/sibling"
        git -C "$dir/sibling" worktree add --quiet -b "fm/$id-foreign" "$foreign"
      fi
      if [ "$copy" = current ]; then old=$foreign; else new=$foreign; fi
      branch=$(git -C "$old" symbolic-ref --quiet --short HEAD)
      fm_write_meta "$dir/home/state/$id.meta" "window=fmses:fm-$id" \
        "endpoint_task_id=$id" "kind=ship" "worktree=$old" \
        "project=$dir/proj" "branch=$branch"
      printf 'Ship branch: %s\n' "$branch" > "$dir/home/data/$id/brief.md"
      printf 'task=%s\nhome=%s\n' "$id" "$dir/home" > "$dir/pool/1/.fm-slot-owner"
      cp "$dir/pool/1/.fm-slot-owner" "$dir/claim-before"
      copy_fingerprint "$old" > "$dir/current-before"
      copy_fingerprint "$new" > "$dir/new-before"
      for project in "$dir/proj" "$dir/sibling"; do
        git -C "$project" for-each-ref --format='%(refname) %(objectname)' refs/fm/anchor/ > "$project.anchors-before"
      done
      expect_refusal "$dir" "same-origin $copy $checkout copy must be refused" \
        'different repository/ref store, even if it has the same origin' 1 \
        "$id" reassociate --worktree "$new" --note moved
      copy_fingerprint "$old" | cmp -s - "$dir/current-before" || fail "ref-store refusal changed the current copy"
      copy_fingerprint "$new" | cmp -s - "$dir/new-before" || fail "ref-store refusal changed the replacement copy"
      for project in "$dir/proj" "$dir/sibling"; do
        git -C "$project" for-each-ref --format='%(refname) %(objectname)' refs/fm/anchor/ | cmp -s - "$project.anchors-before" \
          || fail "ref-store refusal changed preservation anchors"
      done
      cmp -s "$dir/claim-before" "$dir/pool/1/.fm-slot-owner" || fail "ref-store refusal changed the existing slot claim"
      [ ! -e "$dir/pool/2/.fm-slot-owner" ] && [ ! -L "$dir/pool/2/.fm-slot-owner" ] && \
        [ ! -e "$dir/foreign-pool/1/.fm-slot-owner" ] && [ ! -L "$dir/foreign-pool/1/.fm-slot-owner" ] \
        || fail "ref-store refusal published a slot claim"
    done
  done
  pass "same-origin copies in another ref store are refused in both roles without changing records, briefs, anchors, claims, or copies"
}

test_happy_path_repoints_record_and_preserves_old_copy
test_crew_state_reads_the_replacement_run
test_moving_back_undoes_the_hop
test_pool_slot_replacement_is_claimed
test_old_pool_slot_claim_is_retained
test_disjoint_pool_slot_is_released_and_reclaimable
test_existing_reassociation_log_is_untouched
test_scout_reassociation_keeps_branch_fields
test_record_containment_refusals_preserve_both_copies
test_slot_claim_containment_refusals_preserve_both_copies
test_refusals_change_nothing
test_failed_publication_keeps_brief_recovery_until_restored
test_unchanged_ship_branch_requires_consistent_brief
test_dirty_current_copy_refuses_without_publication
test_provider_reset_preserves_spawned_copy_commits_via_anchor
test_nested_replacement_blocks_slot_allocation
test_firstmate_hook_artifacts_do_not_block_reassociation
test_anchor_failure_refuses_record_publication
test_non_pool_reassociation_serializes_copy_ownership
test_subordinate_reassociation_preserves_ancestor_priors
test_same_origin_different_ref_store_refuses_without_changes
