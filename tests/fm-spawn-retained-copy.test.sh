#!/usr/bin/env bash
# fm-spawn.sh's pre-allocation gate for Treehouse pool slots a task left or
# still works inside (bin/fm-task-copy-lib.sh
# fm_task_copy_pool_slots_hold_no_current_copy):
#   1. A slot Treehouse could hand out (not leased in its pool state) that
#      contains a live task record's current copy (the nested replacement-copy
#      case) refuses allocation before treehouse get, names the treehouse lease
#      command that holds the slot in place when the slot has one uniquely
#      named entry, and changes nothing; once that record is retired the gate
#      lets it through.
#   2. A slot whose hold cannot be proved still refuses, without naming a lease
#      as the remedy: a live owner process only, no state entry, an unreadable
#      state file, missing jq, conflicting records (including an unleased or
#      recovered-lease alias of the slot's directory), a relative or
#      TSV-escaped entry path, or Treehouse's recovered-state lease on a slot
#      that is not a Firstmate home while the installed treehouse does not
#      prove persistent recovered leases (`treehouse capabilities --json`).
#      With that proof a surviving recovered lease is as durable an exclusion
#      as an ordinary one (item 3); the probe itself runs no status, lease, or
#      get.
#   3. A slot Treehouse's state durably leases does not block allocation even
#      with a live record's nested copy inside it: treehouse get never hands it
#      out, so the spawn proceeds into another slot and leaves it untouched.
#   4. A registered secondmate home slot, leased ordinarily or by Treehouse's
#      recovered-state lease, holding another project's task copy under its
#      projects/ clone does not block allocation.
#   5. A slot a reassociated task left behind does not block allocation: a new
#      spawn acquires and claims it, whatever its commits.
#   6. A registered local Firstmate home that cannot be read is named in one
#      warning line and skipped: the spawn still proceeds.
set -u

# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-retained-copy)
fm_git_identity fmtest fmtest@example.invalid

make_retained_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  SLOT_DIR="$CASE_DIR/pool/1/project"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "new-$name"
  mkdir -p "$HOME_DIR/user-home"
  fm_git_worktree "$PROJECT_DIR" "$SLOT_DIR" "retained-$name"
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":99999999,"owner_started_at":1}]}\n' "$SLOT_DIR" > "$CASE_DIR/pool/treehouse-state.json"
  PANE_DIR=$SLOT_DIR
  : > "$CASE_DIR/pane-log"
  : > "$CASE_DIR/launch-log"
}

# A second, free slot of the same pool for the spawn's own treehouse get to land
# in, as Treehouse would when slot 1 is leased. <slot1-entry> is slot 1's JSON
# state entry body after its name and path.
add_free_second_slot() {  # <slot1-entry>
  PANE_DIR="$CASE_DIR/pool/2/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$PANE_DIR"
  printf '{"worktrees":[{"name":"1","path":"%s"%s},{"name":"2","path":"%s"}]}\n' \
    "$SLOT_DIR" "$1" "$PANE_DIR" > "$CASE_DIR/pool/treehouse-state.json"
}

# A task record whose current copy is a linked worktree of <repo>, nested in
# <parent>/.claude/worktrees with one unlanded commit. Sets NESTED_COPY.
add_nested_record() {  # <meta> <repo> <parent> <branch>
  local meta=$1 repo=$2 parent=$3 branch=$4
  NESTED_COPY="$parent/.claude/worktrees/$branch"
  mkdir -p "$parent/.claude/worktrees"
  git -C "$repo" worktree add --quiet -b "$branch" "$NESTED_COPY"
  printf 'nested unlanded commit\n' > "$NESTED_COPY/nested-owned.txt"
  git -C "$NESTED_COPY" add nested-owned.txt
  git -C "$NESTED_COPY" commit -qm nested-unlanded
  fm_write_meta "$meta" "window=fmses:fm-$(basename "$meta" .meta)" \
    "worktree=$NESTED_COPY" "project=$repo" "kind=ship"
}

retained_fingerprint() {
  git -C "$SLOT_DIR" rev-parse HEAD
  git -C "$SLOT_DIR" symbolic-ref --quiet HEAD || true
  git -C "$SLOT_DIR" reflog
  git -C "$SLOT_DIR" status --porcelain --untracked-files=all
  (cd "$SLOT_DIR" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s ' "$file"
    cksum < "$file"
  done)
}

run_retained_spawn() {
  FM_FAKE_PANE_LOG="$CASE_DIR/pane-log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch-log" \
    fm_test_run_spawn "$HOME_DIR" "$PANE_DIR" "$FAKEBIN_DIR" \
    "new-$1" "$PROJECT_DIR" --scout
}

assert_retained_refusal() {
  local name=$1 reason=$2 remedy=${3:-} forbidden=${4:-} out rc=0
  retained_fingerprint > "$CASE_DIR/before-copy"
  out=$(run_retained_spawn "$name") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted an unsafe pool slot: $out"
  assert_contains "$out" "$reason" "allocation refusal lost its reason"
  [ -z "$remedy" ] || assert_contains "$out" "$remedy" "allocation refusal did not name the command that clears it"
  [ -z "$forbidden" ] || assert_not_contains "$out" "$forbidden" "allocation refusal named a command that cannot clear it"
  assert_contains "$out" "before treehouse get" "allocation did not refuse at the pre-acquisition boundary"
  ! grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "refused allocation sent treehouse get"
  ! grep -Eq 'reset|treehouse return' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "refused allocation sent a destructive command"
  retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "refused allocation changed the slot"
  [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "refused allocation claimed the slot"
  [ ! -e "$HOME_DIR/state/new-$name.meta" ] || fail "refused allocation published metadata"
}

assert_retained_spawn() {
  local name=$1 msg=$2 out rc=0
  out=$(run_retained_spawn "$name") || rc=$?
  expect_code 0 "$rc" "$msg"$'\n'"$out"
  assert_contains "$out" "spawned new-$name" "$msg: spawn did not launch"
  grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$msg: spawn never acquired a slot"
  assert_grep "task=new-$name" "$CASE_DIR/pool/1/.fm-slot-owner" "$msg: spawn did not claim the slot"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/new-$name.meta" "$msg: spawn did not publish the slot"
}

# A clean leased alias must not mask an entry that cannot be transported or
# resolved safely. Build JSON through jq so the fixture preserves real bytes.
test_unsupported_entry_paths_are_unproved() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local shape dir slot alias path character expected rc failed=0
  command -v jq >/dev/null 2>&1 || fail "the jq regressions require jq"
  for shape in backslash tab newline relative; do
    dir="$TMP_ROOT/unsupported-$shape"
    character=
    expected=escaped
    case "$shape" in
      backslash) character=$'\\' ;;
      tab) character=$'\t' ;;
      newline) character=$'\n' ;;
    esac
    slot="$dir/a${character}b/pool/1/project"
    mkdir -p "$slot" "$dir/unrelated"
    slot=$(cd "$slot" && pwd -P)
    ln -s "${slot%/*/*}" "$dir/clean-pool"
    alias="$dir/clean-pool/1/project"
    path=$slot
    if [ "$shape" = relative ]; then
      path=1/project
      expected=relative
    fi
    jq -n --arg held "$alias" --arg unsafe "$path" \
      '{worktrees: [{name: "1", path: $held, leased: true, lease_holder: "holder"}, {name: "1", path: $unsafe}]}' \
      > "${slot%/*/*}/treehouse-state.json" || fail "$shape: cannot build the pool state fixture"
    FM_TASK_COPY_POOL_STATE_FILE=
    FM_TASK_COPY_POOL_STATE_ENTRIES=
    cd "$dir/unrelated" || fail "cannot enter unrelated working directory"
    rc=0
    fm_task_copy_pool_slot_held "$slot" || rc=$?
    if [ "$rc" != 1 ] || [ "$FM_TASK_COPY_SLOT_STATE" != "$expected" ]; then
      printf 'not ok - %s: unsupported conflicting entry counted as %s (exit %s)\n' \
        "$shape" "$FM_TASK_COPY_SLOT_STATE" "$rc" >&2
      failed=1
    fi
    assert_contains "$FM_TASK_COPY_SLOT_REASON" "$expected entry path" "$shape: unsupported-path refusal lost its reason"
  done
  [ "$failed" = 0 ] || fail "unsupported state paths bypassed the lease proof"
  pass "escaped or relative entry paths cannot prove a slot held beside a clean leased alias"
)

# Conflicting entries must be judged by directory identity, not raw spelling.
# Source before hiding PATH so the missing-jq case exercises the real fallback.
test_unleased_alias_beside_leased_entry_is_not_held() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local mode spelling dir slot alias rc failed=0
  command -v jq >/dev/null 2>&1 || fail "the jq regressions require jq"
  for mode in jq no-jq; do
    for spelling in trailing-slash dot double-slash; do
      dir="$TMP_ROOT/conflicting-$mode-$spelling"
      slot="$dir/pool/1/project"
      mkdir -p "$slot" "$dir/no-tools"
      slot=$(cd "$slot" && pwd -P)
      case "$spelling" in
        trailing-slash) alias="$slot/" ;;
        dot) alias="$slot/./" ;;
        double-slash) alias="${slot%/*}//${slot##*/}" ;;
      esac
      printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder"},{"name":"1","path":"%s"}]}\n' \
        "$slot" "$alias" > "$dir/pool/treehouse-state.json"
      FM_TASK_COPY_POOL_STATE_FILE=
      FM_TASK_COPY_POOL_STATE_ENTRIES=
      rc=0
      if [ "$mode" = no-jq ]; then
        hash -r
        PATH="$dir/no-tools" fm_task_copy_pool_slot_held "$slot" || rc=$?
        expect_code 1 "$rc" "$mode/$spelling: an unproved slot must not count as held"
        [ "$FM_TASK_COPY_SLOT_STATE" = missing-jq ] || fail "$mode/$spelling: missing jq must leave the lease unproved"
        assert_contains "$FM_TASK_COPY_SLOT_REASON" "needs jq" "$mode/$spelling: missing-jq refusal lost its reason"
      else
        fm_task_copy_pool_slot_held "$slot" || rc=$?
        if [ "$rc" != 1 ] || [ "$FM_TASK_COPY_SLOT_STATE" != conflicting ]; then
          printf 'not ok - %s/%s: conflicting unleased alias counted as %s (exit %s)\n' \
            "$mode" "$spelling" "$FM_TASK_COPY_SLOT_STATE" "$rc" >&2
          failed=1
        fi
      fi
    done
  done
  [ "$failed" = 0 ] || fail "noncanonical unleased entries bypassed the lease check"
  pass "jq checks unleased aliases; without jq the check refuses before alias logic"
)

test_prefiltered_leased_alias_still_needs_repair() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local order dir slot alias leased_name rc
  for order in leased-first unleased-first all-unleased leaf-leased-first leaf-unleased-first; do
    dir="$TMP_ROOT/prefiltered-$order"
    slot="$dir/pool/1/project"
    mkdir -p "$slot"
    alias="$slot/"
    leased_name=1
    case "$order" in
      leaf-*)
        alias="$dir/leaf-link"
        leased_name=2
        ln -s "$slot" "$alias"
        ;;
    esac
    jq -n --arg slot "$slot" --arg alias "$alias" --arg leased_name "$leased_name" --arg order "$order" \
      '{worktrees: ([{name: $leased_name, path: $alias, leased: ($order != "all-unleased"), lease_holder: "holder"}, {name: "1", path: $slot}] | if ($order | endswith("unleased-first")) then reverse else . end)}' \
      > "$dir/pool/treehouse-state.json" || fail "cannot build duplicate-name fixture"
    FM_TASK_COPY_POOL_STATE_FILE=
    FM_TASK_COPY_POOL_STATE_ENTRIES=
    rc=0
    fm_task_copy_pool_slot_held "$slot" || rc=$?
    expect_code 1 "$rc" "$order: duplicate-name slot cannot be proved held"
    [ "$FM_TASK_COPY_SLOT_STATE" = conflicting ] || fail "$order: duplicate names must not suggest a first-entry-only lease"
  done
  pass "prefiltered leased aliases and duplicate unleased names require repair, not a lease"
)

test_missing_jq_refusal_names_install() (
  local name=missing-jq tool out rc=0
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  FM_HOME=$HOME_DIR
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  # shellcheck source=bin/fm-secondmate-parent-lib.sh
  . "$ROOT/bin/fm-secondmate-parent-lib.sh"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  mkdir -p "$CASE_DIR/no-jq"
  for tool in basename dirname git cat; do
    ln -s "$(command -v "$tool")" "$CASE_DIR/no-jq/$tool"
  done
  hash -r
  out=$(PATH="$CASE_DIR/no-jq" fm_task_copy_pool_slots_hold_no_current_copy "$PROJECT_DIR" "$HOME_DIR/state" 2>&1) || rc=$?
  expect_code 1 "$rc" "missing jq must refuse before allocation"
  assert_contains "$out" "Install jq" "missing-jq refusal omitted the actual remedy"
  assert_not_contains "$out" "treehouse status" "missing-jq refusal must not substitute pool inspection for installation"
  assert_not_contains "$out" "treehouse lease" "missing-jq refusal must not recommend a lease"
  pass "the shared public allocation guard tells a jq-free caller to install jq"
)

test_unleased_directory_identity_aliases_are_not_held() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local spelling dir slot alias rc
  for spelling in symlink case-variant; do
    dir="$TMP_ROOT/identity-$spelling"
    slot="$dir/pool/1/Project"
    mkdir -p "$slot"
    slot=$(cd "$slot" && pwd -P)
    case "$spelling" in
      symlink)
        alias="$dir/project-link"
        ln -s "$slot" "$alias"
        ;;
      case-variant)
        alias="${slot%/*}/pROJECT"
        if [ ! -d "$alias" ]; then
          printf 'skip: case-variant directory alias requires a case-insensitive filesystem\n'
          continue
        fi
        ;;
    esac
    [ "$alias" -ef "$slot" ] || fail "$spelling: fixture does not name the same directory"
    jq -n --arg held "$slot" --arg unleased "$alias" \
      '{worktrees: [{name: "1", path: $held, leased: true, lease_holder: "holder"}, {name: "1", path: $unleased}]}' \
      > "${slot%/*/*}/treehouse-state.json"
    FM_TASK_COPY_POOL_STATE_FILE=
    FM_TASK_COPY_POOL_STATE_ENTRIES=
    rc=0
    fm_task_copy_pool_slot_held "$slot" || rc=$?
    expect_code 1 "$rc" "$spelling: unleased alias must not count as held"
    [ "$FM_TASK_COPY_SLOT_STATE" = conflicting ] || fail "$spelling: directory identity was not recognized"
    pass "$spelling unleased alias beside a leased entry prevents a held verdict"
  done
)

# A recovered-lease alias beside an ordinary lease is no durable hold either.
test_recovered_alias_beside_leased_entry_is_not_held() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local spelling dir slot alias rc failed=0
  command -v jq >/dev/null 2>&1 || fail "the jq regressions require jq"
  for spelling in trailing-slash dot double-slash; do
    dir="$TMP_ROOT/recovered-alias-$spelling"
    slot="$dir/pool/1/project"
    mkdir -p "$slot"
    slot=$(cd "$slot" && pwd -P)
    case "$spelling" in
      trailing-slash) alias="$slot/" ;;
      dot) alias="$slot/./" ;;
      double-slash) alias="${slot%/*}//${slot##*/}" ;;
    esac
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder"},{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
      "$slot" "$alias" "$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER" > "$dir/pool/treehouse-state.json"
    FM_TASK_COPY_POOL_STATE_FILE=
    FM_TASK_COPY_POOL_STATE_ENTRIES=
    rc=0
    fm_task_copy_pool_slot_held "$slot" || rc=$?
    if [ "$rc" != 1 ] || [ "$FM_TASK_COPY_SLOT_STATE" != recovered ]; then
      printf 'not ok - %s: conflicting recovered-lease alias counted as %s (exit %s)\n' \
        "$spelling" "$FM_TASK_COPY_SLOT_STATE" "$rc" >&2
      failed=1
    fi
    FM_TASK_COPY_POOL_STATE_FILE=
    FM_TASK_COPY_POOL_STATE_ENTRIES=
    rc=0
    fm_task_copy_pool_slot_held "$slot" "$slot" || rc=$?
    if [ "$rc" != 0 ] || [ "$FM_TASK_COPY_SLOT_STATE" != held ]; then
      printf 'not ok - %s: recovered-lease alias on a Firstmate home counted as %s (exit %s)\n' \
        "$spelling" "$FM_TASK_COPY_SLOT_STATE" "$rc" >&2
      failed=1
    fi
  done
  [ "$failed" = 0 ] || fail "noncanonical recovered-lease entries bypassed the lease check"
  pass "all recovered-lease path spellings beside a leased entry remain unsafe off a Firstmate home"
)

test_slot_holding_live_nested_current_copy_refuses() {
  local spelling name nested out
  for spelling in direct alias; do
    name="nested-live-$spelling"
    make_retained_case "$name"
    nested="$SLOT_DIR/.claude/worktrees/replacement"
    mkdir -p "$SLOT_DIR/.claude/worktrees"
    git -C "$PROJECT_DIR" worktree add --quiet -b "nested-$name" "$nested"
    printf 'nested unlanded commit\n' > "$nested/nested-owned.txt"
    git -C "$nested" add nested-owned.txt
    git -C "$nested" commit -qm nested-unlanded
    if [ "$spelling" = alias ]; then
      ln -s "$nested" "$CASE_DIR/nested-alias"
      nested="$CASE_DIR/nested-alias"
    fi
    fm_write_meta "$HOME_DIR/state/holder.meta" "window=fmses:fm-holder" \
      "worktree=$nested" "prior_worktree=$SLOT_DIR" "project=$PROJECT_DIR" "kind=ship"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    assert_retained_refusal "$name" "contains task holder's current copy" \
      "(cd '$PROJECT_DIR' && treehouse lease '1' --lease-holder 'holder')"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "refusal changed the holder's record"
    assert_grep 'nested unlanded commit' "$nested/nested-owned.txt" "refusal lost the nested work"
    rm "$HOME_DIR/state/holder.meta"
    : > "$CASE_DIR/pane-log"
    : > "$CASE_DIR/launch-log"
    out=$(run_retained_spawn "$name") || true
    assert_not_contains "$out" "contains task holder's current copy" "a retired record still blocked allocation"
    grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" \
      || fail "a slot whose nested copy no record names did not reach treehouse get: $out"
  done
  pass "a pool slot holding a live record's nested current copy refuses allocation until that record is retired"
}

test_conflicting_unleased_alias_refuses_before_allocation() {
  local spelling order name alias out rc failed=0
  for order in leased-first unleased-first; do
    for spelling in trailing-slash dot double-slash; do
      name="conflicting-$order-$spelling"
      make_retained_case "$name"
      add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
      case "$spelling" in
        trailing-slash) alias="$SLOT_DIR/" ;;
        dot) alias="$SLOT_DIR/./" ;;
        double-slash) alias="${SLOT_DIR%/*}//${SLOT_DIR##*/}" ;;
      esac
      jq -n --arg slot "$SLOT_DIR" --arg alias "$alias" --arg order "$order" \
        '{worktrees: ([{name: "1", path: $slot, leased: true, lease_holder: "holder"}, {name: "1", path: $alias}] | if $order == "unleased-first" then reverse else . end)}' \
        > "$CASE_DIR/pool/treehouse-state.json" || fail "cannot build conflicting-entry fixture"
      cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
      retained_fingerprint > "$CASE_DIR/before-copy"
      rc=0
      out=$(run_retained_spawn "$name") || rc=$?
      if [ "$rc" = 0 ] || [[ "$out" != *"has conflicting lease records"* ]] || \
        [[ "$out" != *"report the conflicting entries for repair"* ]] || [[ "$out" == *"treehouse lease"* ]] || \
        [[ "$out" != *"(cd '$PROJECT_DIR' && treehouse status)"* ]]; then
        printf 'not ok - %s/%s: mixed-entry refusal must name status/repair, not a lease or an unleased-only verdict: %s\n' "$order" "$spelling" "$out" >&2
        failed=1
      fi
      assert_contains "$out" "before treehouse get" "mixed-entry refusal did not precede acquisition"
      ! grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "mixed-entry refusal allocated a slot"
      retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "mixed-entry refusal changed the copy"
      cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$spelling: refusal changed pool state"
    done
  done
  [ "$failed" = 0 ] || fail "mixed-entry refusal recommends an order-dependent lease remedy"
  pass "mixed leased/unleased aliases refuse with status/repair guidance in both entry orders"
}

test_conflicting_recovered_alias_refuses_before_allocation() {
  local spelling name alias
  local recovered='recovered: state file was corrupt or truncated; verify before reuse'
  for spelling in trailing-slash dot double-slash; do
    name="recovered-conflict-$spelling"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    case "$spelling" in
      trailing-slash) alias="$SLOT_DIR/" ;;
      dot) alias="$SLOT_DIR/./" ;;
      double-slash) alias="${SLOT_DIR%/*}//${SLOT_DIR##*/}" ;;
    esac
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder"},{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
      "$SLOT_DIR" "$alias" "$recovered" > "$CASE_DIR/pool/treehouse-state.json"
    cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
    assert_retained_refusal "$name" "carries Treehouse's recovered-state lease" \
      "(cd '$PROJECT_DIR' && treehouse status)"
    cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$spelling: refusal changed pool state"
  done
  pass "conflicting recovered-lease aliases refuse a spawn before allocation without changing pool state"
}

test_unprovable_entry_path_refusal_names_no_lease() {
  local shape name path display_path
  command -v jq >/dev/null 2>&1 || fail "the jq regressions require jq"
  for shape in escaped relative; do
    name="entry-path-$shape"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    path=1/project
    [ "$shape" != escaped ] || path="$CASE_DIR/pool/9/back\\slash"
    jq -n --arg held "$SLOT_DIR" --arg unsafe "$path" \
      '{worktrees: [{name: "1", path: $held, leased: true, lease_holder: "holder"}, {name: "9", path: $unsafe}]}' \
      > "$CASE_DIR/pool/treehouse-state.json" || fail "$shape: cannot build the pool state fixture"
    cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
    display_path=$(jq -rn --arg path "$path" '[$path] | @tsv') || fail "cannot encode the offending path"
    assert_retained_refusal "$name" "$shape entry path for entry '9': '$display_path'" \
      "remove or rename the offending entry" "treehouse lease"
    cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$shape: refusal changed pool state"
  done
  pass "unsupported entry refusals identify the entry and path, and require removal or renaming, never a lease"
}

test_unprovable_slot_hold_still_refuses() {
  local shape name entry reason remedy forbidden
  local recovered='recovered: state file was corrupt or truncated; verify before reuse'
  for shape in live-owner no-entry unreadable recovered-not-home; do
    name="unproved-$shape"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    remedy=
    forbidden=
    case "$shape" in
      live-owner)
        printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s,"owner_started_at":1}]}\n' \
          "$SLOT_DIR" "$$" > "$CASE_DIR/pool/treehouse-state.json"
        reason="is not leased in Treehouse state"
        remedy="(cd '$PROJECT_DIR' && treehouse lease '1' --lease-holder 'holder')"
        ;;
      no-entry)
        printf '{"worktrees":[{"name":"9","path":"%s/pool/9/project","leased":true,"lease_holder":"other"}]}\n' \
          "$CASE_DIR" > "$CASE_DIR/pool/treehouse-state.json"
        reason="has no entry in Treehouse state"
        remedy="(cd '$PROJECT_DIR' && treehouse status)"
        forbidden="treehouse lease"
        ;;
      unreadable)
        printf '{"worktrees":[{"name":"1","path":"%s","leased":true\n' "$SLOT_DIR" > "$CASE_DIR/pool/treehouse-state.json"
        reason="cannot be read"
        remedy="(cd '$PROJECT_DIR' && treehouse status)"
        forbidden="treehouse lease"
        ;;
      recovered-not-home)
        entry=$(printf ',"leased":true,"lease_holder":"%s"' "$recovered")
        add_free_second_slot "$entry"
        reason="is not a Firstmate home and carries Treehouse's recovered-state lease"
        remedy="treehouse lease refuses a slot that is already leased"
        ;;
    esac
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    assert_retained_refusal "$name" "$reason" "$remedy" "$forbidden"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$shape: refusal changed the holder's record"
    assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$shape: refusal lost the nested work"
  done
  pass "a pool slot whose hold Treehouse's state cannot prove still refuses allocation and names how to inspect or hold it"
}

# A treehouse stub for the capability probe: it answers `capabilities --json`
# per <answer> and records every call in $CASE_DIR/treehouse-calls. Any other
# subcommand the guard might use as a diagnostic (status, lease, get, return)
# marks $CASE_DIR/treehouse-forbidden and fails, so the case can prove the probe
# is the only thing the guard ever runs.
install_capability_treehouse() {  # <answer: proven|false|malformed|none|failing|unknown|wrong-schema>
  local answer=$1
  : > "$CASE_DIR/treehouse-calls"
  rm -f "$CASE_DIR/treehouse-forbidden"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/treehouse-calls"
if [ "\${1:-}" = capabilities ]; then
  case "$answer" in
    proven) printf '%s\n' '{"schema_version":1,"version":"v-fake","persistent_recovered_leases":true}' ;;
    wrong-schema) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true}' ;;
    false) printf '%s\n' '{"schema_version":1,"version":"v-fake","persistent_recovered_leases":false}' ;;
    malformed) printf '%s\n' 'not json' ;;
    none) ;;
    failing) exit 3 ;;
    unknown) printf '%s\n' 'unknown command "capabilities" for "treehouse"' >&2; exit 1 ;;
  esac
  exit 0
fi
case "\${1:-}" in
  status|lease|get|return|list|prune|destroy)
    : > "$CASE_DIR/treehouse-forbidden"
    exit 99
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# Every treehouse call the guard made was the capability probe, and nothing else.
assert_only_capability_probes() {  # <label>
  [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$1: the guard ran a pool command: $(cat "$CASE_DIR/treehouse-calls")"
  ! grep -Fvx 'capabilities --json' "$CASE_DIR/treehouse-calls" | grep -q . \
    || fail "$1: the guard ran a treehouse command other than the capability probe: $(cat "$CASE_DIR/treehouse-calls")"
}

# The capability-negative half of the recovered-slot case: a Firstmate-home-less
# recovered lease keeps today's refusal on every provider that did not prove
# persistent recovered leases, names the provider upgrade, and runs no status,
# lease, or get as a diagnostic.
test_recovered_slot_refuses_without_proven_capability() {
  local answer name entry
  local recovered='recovered: state file was corrupt or truncated; verify before reuse'
  for answer in unknown none malformed false failing wrong-schema; do
    name="recovered-unproven-$answer"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    entry=$(printf ',"leased":true,"lease_holder":"%s"' "$recovered")
    add_free_second_slot "$entry"
    install_capability_treehouse "$answer"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
    assert_retained_refusal "$name" "is not a Firstmate home and carries Treehouse's recovered-state lease" \
      "Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true" \
      "treehouse lease '"
    assert_only_capability_probes "$answer"
    grep -Fxq 'capabilities --json' "$CASE_DIR/treehouse-calls" || fail "$answer: the guard never probed the capability"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$answer: refusal changed the holder's record"
    cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$answer: refusal changed the pool state"
  done
  pass "a recovered lease keeps refusing allocation on a treehouse that does not prove persistent recovered leases, names the upgrade, and runs no pool command"
}

# The capability-positive half: with the proof, a recovered slot holding a
# task's current copy is a durable exclusion, so the spawn takes the free slot
# and leaves the recovered one, its lease entry, and its claim exactly as they
# were. Every state order and every kind of dirt in the recovered slot's root
# gives the same answer, because nothing about the root changes whether
# Treehouse keeps the lease.
test_recovered_slot_allows_allocation_with_proven_capability() {
  local order dirt name entry out rc
  local recovered='recovered: state file was corrupt or truncated; verify before reuse'
  for order in recovered-first free-first; do
    for dirt in clean ignored tracked-dirty unlanded; do
      name="recovered-proven-$order-$dirt"
      make_retained_case "$name"
      add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
      case "$dirt" in
        ignored) printf '.claude/\n' >> "$(git -C "$SLOT_DIR" rev-parse --git-path info/exclude)" ;;
        tracked-dirty)
          ls "$SLOT_DIR" >/dev/null
          printf 'dirt\n' >> "$SLOT_DIR/$(git -C "$SLOT_DIR" ls-files | head -1)"
          ;;
        unlanded)
          printf 'root work\n' > "$SLOT_DIR/root-owned.txt"
          git -C "$SLOT_DIR" add root-owned.txt
          git -C "$SLOT_DIR" commit -qm root-unlanded
          ;;
      esac
      entry=$(printf ',"leased":true,"lease_holder":"%s"' "$recovered")
      add_free_second_slot "$entry"
      if [ "$order" = free-first ]; then
        printf '{"worktrees":[{"name":"2","path":"%s"},{"name":"1","path":"%s"%s}]}\n' \
          "$PANE_DIR" "$SLOT_DIR" "$entry" > "$CASE_DIR/pool/treehouse-state.json"
      fi
      install_capability_treehouse proven
      retained_fingerprint > "$CASE_DIR/before-copy"
      cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
      cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
      rc=0
      out=$(run_retained_spawn "$name") || rc=$?
      expect_code 0 "$rc" "$order/$dirt: a proven recovered lease stopped the spawn"$'\n'"$out"
      assert_not_contains "$out" "refusing allocation" "$order/$dirt: a proven recovered lease still blocked allocation"
      assert_contains "$out" "spawned new-$name" "$order/$dirt: spawn did not launch"
      grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$order/$dirt: spawn never acquired a slot"
      assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "$order/$dirt: spawn did not claim the free slot"
      [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "$order/$dirt: spawn claimed the recovered slot"
      assert_only_capability_probes "$order/$dirt"
      retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$order/$dirt: spawn changed the recovered slot"
      cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$order/$dirt: spawn changed the holder's record"
      cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" \
        || fail "$order/$dirt: spawn wrote the pool state (a lease or reassociation for the recovered slot)"
      assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$order/$dirt: spawn lost the nested work"
    done
  done
  pass "with a proven persistent-recovered-lease capability a recovered slot holding a current copy stays untouched while the spawn takes the free slot, whatever its root's state or state order"
}

# The relaxation covers only the recovered-not-home distinction: every other
# unproved candidate still refuses before treehouse get, even on a proven
# provider, and the capability is probed at most once for the process.
test_proven_capability_does_not_relax_other_refusals() {
  local shape name
  for shape in unleased no-entry unreadable; do
    name="proven-other-$shape"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    case "$shape" in
      unleased) printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT_DIR" > "$CASE_DIR/pool/treehouse-state.json" ;;
      no-entry) printf '{"worktrees":[{"name":"9","path":"%s/pool/9/project","leased":true,"lease_holder":"other"}]}\n' "$CASE_DIR" > "$CASE_DIR/pool/treehouse-state.json" ;;
      unreadable) printf '{"worktrees":[{"name":"1","path":"%s","leased":true\n' "$SLOT_DIR" > "$CASE_DIR/pool/treehouse-state.json" ;;
    esac
    install_capability_treehouse proven
    assert_retained_refusal "$name" "contains task holder's current copy"
    # An unleased slot's own currency check may read pool-dir or status; the
    # other two shapes never reach a pool command.
    [ "$shape" = unleased ] || [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$shape: the guard ran a pool command"
  done
  pass "a proven capability relaxes only the recovered lease: unleased, missing, and unreadable entries still refuse"
}

# The real-provider half of the capability-positive case. Needs the treehouse
# named by FM_TEST_TREEHOUSE_PROVIDER, a build that proves persistent recovered
# leases (never installed; linked into this case's own fakebin). Pools, HOME,
# XDG configuration and TREEHOUSE_ROOT are the case's own. Slot A is a recovered
# quarantine holding a task's nested current copy, slot B is free; the spawn must
# take B and leave A, its pool entry, its copy and the whole state file as they
# were, and the real `treehouse get` that follows must hand out B. Without the
# variable the case prints a loud named skip and checks nothing.
test_real_provider_recovered_slot_allows_free_slot_allocation() {
  local name=real-provider order out rc a b entry state pool
  local recovered='recovered: state file was corrupt or truncated; verify before reuse'
  if [ -z "${FM_TEST_TREEHOUSE_PROVIDER:-}" ] || [ ! -x "$FM_TEST_TREEHOUSE_PROVIDER" ]; then
    printf 'skip - real-provider recovered-slot allocation: FM_TEST_TREEHOUSE_PROVIDER names no executable treehouse; the case did NOT run\n'
    return 0
  fi
  (
  for order in recovered-first free-first; do
    name="real-provider-$order"
    CASE_DIR="$TMP_ROOT/$name"
    HOME_DIR="$CASE_DIR/home"
    PROJECT_DIR="$CASE_DIR/project"
    FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    fm_test_spawn_home "$HOME_DIR" codex
    fm_test_spawn_brief "$HOME_DIR" "new-$name"
    mkdir -p "$HOME_DIR/user-home" "$CASE_DIR/real-home" "$CASE_DIR/real-xdg"
    fm_git_init_commit "$PROJECT_DIR"
    fm_git_add_origin "$PROJECT_DIR" "$CASE_DIR/origin.git"
    git -C "$PROJECT_DIR" remote set-head origin main 2>/dev/null || true
    ln -sf "$FM_TEST_TREEHOUSE_PROVIDER" "$FAKEBIN_DIR/treehouse"
    export HOME="$CASE_DIR/real-home" XDG_CONFIG_HOME="$CASE_DIR/real-xdg" TREEHOUSE_NO_UPDATE_CHECK=1 \
      TREEHOUSE_ROOT="$CASE_DIR/real-root" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    a=$(cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" get --no-fetch --lease --lease-holder holder </dev/null 2>/dev/null) || fail "$order: cannot lease slot A"
    b=$(cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" get --no-fetch --lease --lease-holder spare </dev/null 2>/dev/null) || fail "$order: cannot lease slot B"
    a=$(cd "$a" && pwd -P)
    b=$(cd "$b" && pwd -P)
    (cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" return "$b" --if-lease-holder spare </dev/null >/dev/null 2>&1) || fail "$order: cannot free slot B"
    pool=${a%/*/*}
    state=$pool/treehouse-state.json
    jq --arg r "$recovered" --arg a "$a" '.worktrees |= map(if .path == $a then (.lease_holder = $r | del(.lease_id)) else . end)' \
      "$state" > "$state.tmp" || fail "$order: cannot make slot A recovered"
    mv "$state.tmp" "$state"
    if [ "$order" = free-first ]; then
      jq '.worktrees |= reverse' "$state" > "$state.tmp" || fail "$order: cannot reorder the state"
      mv "$state.tmp" "$state"
    fi
    SLOT_DIR=$a
    PANE_DIR=$b
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$a" "nested-$name"
    : > "$CASE_DIR/pane-log"
    : > "$CASE_DIR/launch-log"
    retained_fingerprint > "$CASE_DIR/before-copy"
    cp "$state" "$CASE_DIR/before-state"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    rc=0
    out=$(run_retained_spawn "$name") || rc=$?
    expect_code 0 "$rc" "$order: the spawn beside a real recovered quarantine failed"$'\n'"$out"
    assert_not_contains "$out" "refusing allocation" "$order: the recovered quarantine still blocked allocation"
    assert_contains "$out" "spawned new-$name" "$order: spawn did not launch"
    grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$order: spawn never acquired a slot"
    assert_grep "task=new-$name" "$b/../.fm-slot-owner" "$order: spawn did not claim the free slot"
    [ ! -e "$a/../.fm-slot-owner" ] || fail "$order: spawn claimed the recovered slot"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$order: spawn changed the recovered slot"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$order: spawn changed the holder's record"
    cmp -s "$CASE_DIR/before-state" "$state" || fail "$order: spawn wrote the pool state (a lease or reassociation for the recovered slot)"
    ! compgen -G "$pool/../treehouse-recovered-backup-*" >/dev/null || fail "$order: a recovered backup appeared"
    # The allocation the spawn sends, run for real: it hands out B, never A.
    entry=$(cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" get --no-fetch --lease --lease-holder next </dev/null 2>/dev/null) || fail "$order: the real get failed"
    [ "$(cd "$entry" && pwd -P)" = "$b" ] || fail "$order: the real get handed out $entry, not the free slot $b"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$order: the real get changed the recovered slot"
    jq -e --arg a "$a" '.worktrees[] | select(.path == $a) | .lease_holder == "'"$recovered"'" and (.lease_id // "") == ""' "$state" >/dev/null \
      || fail "$order: the recovered entry changed after the real get"
    ! compgen -G "$pool/../treehouse-recovered-backup-*" >/dev/null || fail "$order: the real get left a recovered backup"
  done
  ) || exit 1
  pass "against the real provider a recovered quarantine holding a current copy stays untouched while the spawn and the following get take the free slot, in both state orders"
}

test_nested_copy_in_leased_slot_allows_allocation() {
  local spelling name out rc
  for spelling in direct alias; do
    name="leased-$spelling"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    add_free_second_slot ',"leased":true,"lease_holder":"holder"'
    if [ "$spelling" = alias ]; then
      # Treehouse state spelling the leased slot through a symlinked pool still
      # names that slot.
      ln -s "$CASE_DIR/pool" "$CASE_DIR/pool-alias"
      printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder"},{"name":"2","path":"%s"}]}\n' \
        "$CASE_DIR/pool-alias/1/project" "$PANE_DIR" > "$CASE_DIR/pool/treehouse-state.json"
    fi
    retained_fingerprint > "$CASE_DIR/before-copy"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    rc=0
    out=$(run_retained_spawn "$name") || rc=$?
    expect_code 0 "$rc" "$spelling: a nested copy in a leased slot stopped the spawn"$'\n'"$out"
    assert_not_contains "$out" "refusing allocation" "$spelling: a leased slot still blocked allocation"
    assert_contains "$out" "spawned new-$name" "$spelling: spawn did not launch"
    grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$spelling: spawn never acquired a slot"
    assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "$spelling: spawn did not claim the slot it acquired"
    [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "$spelling: spawn claimed the leased slot"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$spelling: spawn changed the leased slot"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$spelling: spawn changed the holder's record"
    assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$spelling: spawn lost the nested work"
  done
  pass "a nested current copy inside a slot Treehouse's state leases does not stop an unrelated spawn"
}

# The allocation guard's harm is a start receiving a slot that holds a live
# record's nested current copy. treehouse get allocates from the current pool
# folder only, so an unleased slot in a superseded pool folder that holds such a
# copy does not stop a spawn, and the spawn never receives that slot: it lands
# in the current pool. The guard asks Treehouse at each start, through
# treehouse pool-dir or, without it, the status listing: once Treehouse names
# the old folder as current again, the same slot refuses with its lease remedy
# before treehouse get, so the harm is still caught.
test_nested_copy_in_superseded_slot_allows_allocation() {
  local mode name out rc current old
  for mode in status pool-dir; do
    name="superseded-nested-$mode"
    rc=0
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    current="$CASE_DIR/current-pool/1/project"
    mkdir -p "${current%/*}"
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$current"
    current=$(cd "$current" && pwd -P)
    old=${SLOT_DIR%/*/*}
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$current" > "$CASE_DIR/current-pool/treehouse-state.json"
    PANE_DIR=$current
    cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  pool-dir) [ ! -f "$CASE_DIR/pool-dir" ] || cat "$CASE_DIR/pool-dir" ;;
  status) printf 'status\n' >> "$CASE_DIR/status-calls"; [ ! -f "$CASE_DIR/status.json" ] || cat "$CASE_DIR/status.json" ;;
esac
exit 0
SH
    chmod +x "$FAKEBIN_DIR/treehouse"
    if [ "$mode" = status ]; then
      printf '[{"name":"1","path":"%s"}]\n' "$current" > "$CASE_DIR/status.json"
    else
      printf '%s\n' "${current%/*/*}" > "$CASE_DIR/pool-dir"
    fi
    retained_fingerprint > "$CASE_DIR/before-copy"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    out=$(run_retained_spawn "$name") || rc=$?
    expect_code 0 "$rc" "$mode: a nested copy in a superseded pool folder stopped the spawn"$'\n'"$out"
    assert_not_contains "$out" "refusing allocation" "$mode: a superseded slot still blocked allocation"
    assert_contains "$out" "spawned new-$name" "$mode: spawn did not launch"
    assert_grep "task=new-$name" "$CASE_DIR/current-pool/1/.fm-slot-owner" "$mode: spawn did not claim the current-pool slot it acquired"
    assert_grep "worktree=$current" "$HOME_DIR/state/new-$name.meta" "$mode: spawn did not record the current-pool slot"
    [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "$mode: spawn claimed the superseded slot"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$mode: spawn changed the superseded slot"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$mode: spawn changed the holder's record"
    [ "$mode" = status ] || [ ! -e "$CASE_DIR/status-calls" ] || fail "$mode: the guard read a status listing although pool-dir answered"

    if [ "$mode" = status ]; then
      printf '[{"name":"1","path":"%s"}]\n' "$SLOT_DIR" > "$CASE_DIR/status.json"
    else
      printf '%s\n' "$old" > "$CASE_DIR/pool-dir"
    fi
    fm_test_spawn_brief "$HOME_DIR" "new-$name-again"
    PANE_DIR=$SLOT_DIR
    : > "$CASE_DIR/pane-log"
    : > "$CASE_DIR/launch-log"
    assert_retained_refusal "$name-again" "contains task holder's current copy" \
      "(cd '$PROJECT_DIR' && treehouse lease '1' --lease-holder 'holder')"
    assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$mode: refusal lost the nested work"
  done
  pass "a spawn never receives a superseded slot holding a nested copy, and refuses before treehouse get once Treehouse names that folder current"
}

test_secondmate_home_slot_with_other_project_copy_allows_allocation() {
  local lease name sm_home other out rc entry
  local recovered='recovered: state file was corrupt or truncated; verify before reuse'
  for lease in ordinary recovered; do
    name="home-$lease"
    make_retained_case "$name"
    sm_home=$SLOT_DIR
    mkdir -p "$sm_home/state" "$sm_home/data" "$sm_home/projects"
    printf -- '- sm - sm (home: %s; scope: fixture; projects: other; added 2026-10-11)\n' \
      "$sm_home" > "$HOME_DIR/data/secondmates.md"
    other="$sm_home/projects/other"
    fm_git_init_commit "$other"
    add_nested_record "$sm_home/state/foreign.meta" "$other" "$other" "foreign-$name"
    if [ "$lease" = ordinary ]; then
      entry=',"leased":true,"lease_holder":"sm"'
    else
      entry=$(printf ',"leased":true,"lease_holder":"%s"' "$recovered")
    fi
    add_free_second_slot "$entry"
    cp "$sm_home/state/foreign.meta" "$CASE_DIR/before-meta"
    git -C "$NESTED_COPY" rev-parse HEAD > "$CASE_DIR/before-head"
    rc=0
    out=$(run_retained_spawn "$name") || rc=$?
    expect_code 0 "$rc" "$lease: a secondmate home slot holding another project's copy stopped the spawn"$'\n'"$out"
    assert_not_contains "$out" "refusing allocation" "$lease: a leased secondmate home slot still blocked allocation"
    assert_contains "$out" "spawned new-$name" "$lease: spawn did not launch"
    assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "$lease: spawn did not claim the slot it acquired"
    [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "$lease: spawn claimed the secondmate home slot"
    cmp -s "$CASE_DIR/before-meta" "$sm_home/state/foreign.meta" || fail "$lease: spawn changed the foreign record"
    git -C "$NESTED_COPY" rev-parse HEAD | cmp -s - "$CASE_DIR/before-head" || fail "$lease: spawn moved the foreign copy"
    assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$lease: spawn lost the foreign copy's work"
  done
  pass "a leased secondmate home slot holding another project's task copy does not stop a spawn"
}

test_slot_left_by_reassociated_task_is_allocatable() {
  local name=left-behind
  make_retained_case "$name"
  printf 'anchored unlanded commit\n' > "$SLOT_DIR/owned.txt"
  git -C "$SLOT_DIR" add owned.txt
  git -C "$SLOT_DIR" commit -qm unlanded
  git -C "$PROJECT_DIR" update-ref "refs/fm/anchor/mover-$(git -C "$SLOT_DIR" rev-parse --short HEAD)" \
    "$(git -C "$SLOT_DIR" rev-parse HEAD)"
  git -C "$PROJECT_DIR" worktree add --quiet -b mover-v2 "$CASE_DIR/replacement"
  fm_write_meta "$HOME_DIR/state/mover.meta" "window=fmses:fm-mover" \
    "worktree=$CASE_DIR/replacement" "released_worktree=$SLOT_DIR" "project=$PROJECT_DIR" "kind=ship"
  assert_retained_spawn "$name" "a slot a reassociated task left must not block allocation"
  pass "a pool slot a reassociated task left is acquired and claimed by a new task"
}

test_unreadable_local_home_warns_and_proceeds() {
  local name=unreadable-home out warnings
  make_retained_case "$name"
  printf -- '- ghost - ghost (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' \
    "$CASE_DIR/missing-home" > "$HOME_DIR/data/secondmates.md"
  out=$(run_retained_spawn "$name") || fail "an unavailable registered local home stopped the spawn: $out"
  warnings=$(printf '%s\n' "$out" | grep -c "^warning: registered local Firstmate home is unavailable: $CASE_DIR/missing-home" || true)
  [ "$warnings" = 1 ] || fail "expected one warning line naming the unavailable home, got $warnings: $out"
  assert_contains "$out" "spawned new-$name" "the spawn did not launch past the unavailable home"
  assert_grep "task=new-$name" "$CASE_DIR/pool/1/.fm-slot-owner" "the spawn did not claim the slot"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/new-$name.meta" "the spawn did not publish the slot"
  pass "an unavailable registered local home is named in one warning and the spawn proceeds"
}

test_conflicting_unleased_alias_refuses_before_allocation || exit 1
test_unsupported_entry_paths_are_unproved || exit 1
test_unleased_alias_beside_leased_entry_is_not_held || exit 1
test_prefiltered_leased_alias_still_needs_repair || exit 1
test_missing_jq_refusal_names_install || exit 1
test_unleased_directory_identity_aliases_are_not_held || exit 1
test_recovered_alias_beside_leased_entry_is_not_held || exit 1
test_slot_holding_live_nested_current_copy_refuses
test_conflicting_recovered_alias_refuses_before_allocation
test_unprovable_entry_path_refusal_names_no_lease
test_unprovable_slot_hold_still_refuses
test_recovered_slot_refuses_without_proven_capability
test_recovered_slot_allows_allocation_with_proven_capability
test_proven_capability_does_not_relax_other_refusals
test_real_provider_recovered_slot_allows_free_slot_allocation
test_nested_copy_in_leased_slot_allows_allocation
test_nested_copy_in_superseded_slot_allows_allocation
test_secondmate_home_slot_with_other_project_copy_allows_allocation
test_slot_left_by_reassociated_task_is_allocatable
test_unreadable_local_home_warns_and_proceeds
