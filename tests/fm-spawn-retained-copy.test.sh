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

# The preservation fingerprint of the enclosing slot AND of the nested linked worktree
# a case recorded (NESTED_COPY): its own HEAD, which an enclosing-slot read of HEAD and
# file bytes cannot see (a nested HEAD moved to a commit with the same bytes).
retained_fingerprint() {
  if [ -n "${NESTED_COPY:-}" ] && [ -d "$NESTED_COPY" ]; then
    printf 'nested HEAD '
    git -C "$NESTED_COPY" rev-parse HEAD
  fi
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
  local name=$1 reason=$2 remedy=${3:-} forbidden=${4:-} out rc=0 f
  retained_fingerprint > "$CASE_DIR/before-copy"
  out=$(run_retained_spawn "$name") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted an unsafe pool slot: $out"
  assert_contains "$out" "$reason" "allocation refusal lost its reason"
  [ -z "$remedy" ] || assert_contains "$out" "$remedy" "allocation refusal did not name the command that clears it"
  if [ -n "$forbidden" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] || assert_not_contains "$out" "$f" "allocation refusal named a command that cannot clear it"
    done <<<"$forbidden"
  fi
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
      '{worktrees: [{name: "1", path: $held, leased: true, lease_holder: "holder", lease_id: "0123456789abcdef0123456789abcdef"}, {name: "1", path: $unsafe}]}' \
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
      printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder","lease_id":"0123456789abcdef0123456789abcdef"},{"name":"1","path":"%s"}]}\n' \
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
      '{worktrees: ([{name: $leased_name, path: $alias, leased: ($order != "all-unleased"), lease_holder: "holder", lease_id: "0123456789abcdef0123456789abcdef"}, {name: "1", path: $slot}] | if ($order | endswith("unleased-first")) then reverse else . end)}' \
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
      '{worktrees: [{name: "1", path: $held, leased: true, lease_holder: "holder", lease_id: "0123456789abcdef0123456789abcdef"}, {name: "1", path: $unleased}]}' \
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
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder","lease_id":"0123456789abcdef0123456789abcdef"},{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
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
    # an unproven provider that answers pool-dir, as the installed treehouse does
    install_boundary_treehouse failing pool-dir-answers status-forbidden
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
        '{worktrees: ([{name: "1", path: $slot, leased: true, lease_holder: "holder", lease_id: "0123456789abcdef0123456789abcdef"}, {name: "1", path: $alias}] | if $order == "unleased-first" then reverse else . end)}' \
        > "$CASE_DIR/pool/treehouse-state.json" || fail "cannot build conflicting-entry fixture"
      cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
      retained_fingerprint > "$CASE_DIR/before-copy"
      rc=0
      out=$(run_retained_spawn "$name") || rc=$?
      if [ "$rc" = 0 ] || [[ "$out" != *"has conflicting lease records"* ]] || \
        [[ "$out" != *"report the conflicting entries for repair"* ]] || [[ "$out" == *"treehouse lease"* ]] || \
        [[ "$out" != *"Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true"* ]] || [[ "$out" == *"treehouse status)"* ]]; then
        printf 'not ok - %s/%s: mixed-entry refusal on an unproven provider must name the upgrade and repair, not a lease, an unleased-only verdict or a status read: %s\n' "$order" "$spelling" "$out" >&2
        failed=1
      fi
      assert_contains "$out" "before treehouse get" "mixed-entry refusal did not precede acquisition"
      ! grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "mixed-entry refusal allocated a slot"
      retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "mixed-entry refusal changed the copy"
      cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$spelling: refusal changed pool state"
    done
  done
  [ "$failed" = 0 ] || fail "mixed-entry refusal recommends an order-dependent lease remedy"
  pass "mixed leased/unleased aliases refuse with upgrade and repair guidance, and no status read, in both entry orders on an unproven provider"
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
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder","lease_id":"0123456789abcdef0123456789abcdef"},{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
      "$SLOT_DIR" "$alias" "$recovered" > "$CASE_DIR/pool/treehouse-state.json"
    cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
    assert_retained_refusal "$name" "carries Treehouse's recovered-state lease" \
      "Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true" "treehouse status)"
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
      '{worktrees: [{name: "1", path: $held, leased: true, lease_holder: "holder", lease_id: "0123456789abcdef0123456789abcdef"}, {name: "9", path: $unsafe}]}' \
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
    install_boundary_treehouse failing pool-dir-answers status-forbidden
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
        remedy="Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true"
        forbidden=$'treehouse lease\ntreehouse status)'
        ;;
      unreadable)
        printf '{"worktrees":[{"name":"1","path":"%s","leased":true\n' "$SLOT_DIR" > "$CASE_DIR/pool/treehouse-state.json"
        reason="cannot be read"
        remedy="Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true"
        forbidden=$'treehouse lease\ntreehouse status)'
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

# The old recovered holder an older Treehouse writes and an old session's exit
# sweeps, and the protected holder the fixture provider publishes in its
# capabilities and keeps adopted entries under.
OLD_RECOVERED='recovered: state file was corrupt or truncated; verify before reuse'
PROTECTED_HOLDER='quarantined: persistent recovered lease'

# A treehouse stub for the capability probe: it answers `capabilities --json`
# per <answer> and records every call in $CASE_DIR/treehouse-calls. Any other
# subcommand the guard might use as a diagnostic (status, lease, get, return)
# marks $CASE_DIR/treehouse-forbidden and fails, so the case can prove the probe
# is the only thing the guard ever runs.
install_capability_treehouse() {  # <answer: proven|false|malformed|none|failing|unknown|wrong-schema|no-holder|empty-holder|old-holder|no-version|empty-version|number-version|blank-version|holder-old-newline|holder-newline|holder-tab|holder-trailing-space|holder-leading-space>
  local answer=$1
  : > "$CASE_DIR/treehouse-calls"
  rm -f "$CASE_DIR/treehouse-forbidden"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/treehouse-calls"
if [ "\${1:-}" = capabilities ]; then
  case "$answer" in
    proven) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    wrong-schema) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:3,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    false) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"v-fake",persistent_recovered_leases:false,recovered_quarantine_holder:\$h}' ;;
    no-holder) printf '%s\n' '{"schema_version":1,"version":"v-fake","persistent_recovered_leases":true}' ;;
    empty-holder) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":""}' ;;
    old-holder) jq -cn --arg h "$OLD_RECOVERED" '{schema_version:2,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    no-version) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    empty-version) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    number-version) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:3,persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    blank-version) jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:" \t ",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}' ;;
    holder-old-newline) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":"'"$OLD_RECOVERED"'\n"}' ;;
    holder-newline) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":"\n"}' ;;
    holder-tab) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":"quarantined:\tfixture"}' ;;
    holder-trailing-space) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":"quarantined: fixture "}' ;;
    holder-leading-space) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":" quarantined: fixture"}' ;;
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
  local recovered=$OLD_RECOVERED
  for answer in unknown none malformed false failing wrong-schema no-holder empty-holder old-holder no-version empty-version number-version blank-version holder-old-newline holder-newline holder-tab holder-trailing-space holder-leading-space; do
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

# Which leased entries the allocation guard admits (Main 1702, 1738, 1762: refuse
# when in doubt, act only on positive proof). The consumer learns the protected
# holder text only from a proven probe, so an entry is admitted as an ordinary
# lease only when it has a lease id, a holder that is not recovered-looking, and no
# recovery reason. Everything else (no lease id, a recovery reason, a holder
# beginning "recovered:", no holder, two leased entries for one slot) needs the
# proof, and even with the proof it is admitted only when its holder IS the
# published protected holder; two entries for one slot and an entry that cannot be
# read are never admitted. The probe runs only for such an entry.
assert_unproved_lease_refusal() {  # <name> <label> <proven|unproven>
  local remedy
  if [ "$3" = unproven ]; then
    remedy="Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true"
  else
    remedy="Inspect the entry with: (cd '$PROJECT_DIR' && treehouse status)"
  fi
  assert_retained_refusal "$1" "carries a lease that is not provably an ordinary one" "$remedy" "treehouse lease '"
  assert_only_capability_probes "$2"
  grep -Fxq 'capabilities --json' "$CASE_DIR/treehouse-calls" || fail "$2: the guard never probed the capability"
  cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$2: the refusal changed the pool state"
}

# The stated residual (Main 1790): protected-with-id, an entry on the protected
# holder's text WITH a lease id and no recovery reason, admits on an unproven
# provider too, because on an unproven provider nothing in the entry tells a
# protected holder from an ordinary one (the protected literal is learned only from
# a proven probe). It needs a proven provider's write followed by a downgrade or a
# mixed install; the live pools hold 0 of 74 such entries. Its id-less twin
# (idless-protected) refuses on an unproven provider, and the ordinary control admits.
test_unproven_provider_admits_only_ordinary_leases() {
  local shape provider name entry out rc expect id=0123456789abcdef0123456789abcdef
  for provider in unproven proven; do
    for shape in ordinary protected-with-id idless-protected idless-ordinary-holder reason-with-id reason-protected recovered-prefix-with-id \
        holderless-with-id duplicate-idless duplicate-reason-with-id; do
      name="shape-$provider-$shape"
      make_retained_case "$name"
      add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
      case "$shape" in
        ordinary) entry=$(printf ',"leased":true,"lease_holder":"holder","lease_id":"%s"' "$id") ;;
        protected-with-id) entry=$(printf ',"leased":true,"lease_holder":"%s","lease_id":"%s"' "$PROTECTED_HOLDER" "$id") ;;
        idless-protected|duplicate-idless) entry=$(printf ',"leased":true,"lease_holder":"%s"' "$PROTECTED_HOLDER") ;;
        idless-ordinary-holder) entry=',"leased":true,"lease_holder":"holder"' ;;
        reason-with-id|duplicate-reason-with-id) entry=$(printf ',"leased":true,"lease_holder":"holder","lease_id":"%s","recovery_reason":"state file was corrupt or truncated"' "$id") ;;
        reason-protected) entry=$(printf ',"leased":true,"lease_holder":"%s","lease_id":"%s","recovery_reason":"state file was corrupt or truncated"' "$PROTECTED_HOLDER" "$id") ;;
        recovered-prefix-with-id) entry=$(printf ',"leased":true,"lease_holder":"recovered: another state file reason","lease_id":"%s"' "$id") ;;
        holderless-with-id) entry=$(printf ',"leased":true,"lease_id":"%s"' "$id") ;;
      esac
      add_free_second_slot "$entry"
      case "$shape" in
        duplicate-*)
          jq --arg p "$SLOT_DIR" '.worktrees += [(.worktrees[] | select(.path == $p))]' "$CASE_DIR/pool/treehouse-state.json" > "$CASE_DIR/pool/state.next" \
            && mv "$CASE_DIR/pool/state.next" "$CASE_DIR/pool/treehouse-state.json" ;;
      esac
      if [ "$provider" = proven ]; then install_capability_treehouse proven; else install_capability_treehouse failing; fi
      retained_fingerprint > "$CASE_DIR/before-copy"
      cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
      # What is admitted: an ordinary entry always; on a proven provider an entry on
      # the published protected holder; nothing else.
      expect=refuse
      case "$provider/$shape" in
        */ordinary|*/protected-with-id|proven/idless-protected|proven/reason-protected) expect=admit ;;
      esac
      if [ "$expect" = refuse ]; then
        assert_unproved_lease_refusal "$name" "$provider/$shape" "$provider"
        continue
      fi
      rc=0
      out=$(run_retained_spawn "$name") || rc=$?
      expect_code 0 "$rc" "$provider/$shape: the guard refused a slot it must admit"$'\n'"$out"
      assert_not_contains "$out" "refusing allocation" "$provider/$shape: the guard still blocked allocation"
      assert_contains "$out" "spawned new-$name" "$provider/$shape: spawn did not launch"
      assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "$provider/$shape: spawn did not claim the free slot"
      [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "$provider/$shape: spawn claimed the leased slot"
      assert_only_capability_probes "$provider/$shape"
      retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$provider/$shape: spawn changed the leased slot"
      cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$provider/$shape: spawn wrote the pool state"
      # An ordinary lease is admitted whether or not the guard happens to probe: the
      # capability probe is read-only and harmless, so only a status, lease or get
      # diagnostic call is forbidden, and assert_only_capability_probes (above) fails
      # on exactly those.
    done
  done
  pass "an ordinary lease with a lease id is admitted without the proof; id-less, recovery-reason, recovered-prefix, holderless and duplicate entries refuse, and with the proof only an entry on the published protected holder is admitted"
}

# The same guard, as a function with in-memory pool state and stubs, for the reads
# a fixture pool cannot fail: when the fresh read of the slot's entry fails after
# the scan found it leased, an unproven provider is refused and nothing is
# admitted; and a version of only whitespace does not prove the capability.
test_unproved_fresh_read_and_blank_version_are_refused() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local label rc verdict STATE_JSON FAIL_SECOND=0 ANSWER=failing
  command -v jq >/dev/null 2>&1 || fail "the in-memory guard checks require jq"
  local meta_dir="$TMP_ROOT/in-memory-guard/home/state"
  mkdir -p "$meta_dir"
  : > "$meta_dir/holder.meta"
  # The stub sets the guard's own variables inside this test's subshell on purpose.
  # shellcheck disable=SC2030
  fm_local_firstmate_state_dirs() { FM_LOCAL_FIRSTMATE_STATES=("$meta_dir"); FM_LOCAL_FIRSTMATE_SKIPPED=(); }
  fm_meta_get() { printf '%s\n' /virtual/pool/1/project/nested; }
  fm_task_copy_canonical_dir() { printf '%s\n' "$1"; }
  fm_task_copy_enclosing_pool_slot() { printf '%s\n' /virtual/pool/1/project; }
  jq() {
    local last=${!#} arg
    if [[ $last == */treehouse-state.json ]]; then
      for arg in "$@"; do
        if [[ $FAIL_SECOND == 1 && $arg == *'("I" + '* ]]; then return 1; fi
      done
      local -a args=("$@")
      unset 'args[${#args[@]}-1]'
      command jq "${args[@]}" <<<"$STATE_JSON"
    else
      command jq "$@"
    fi
  }
  treehouse() {
    [[ ${1-} == capabilities && ${2-} == --json ]] || return 91
    case "$ANSWER" in
      failing) return 3 ;;
      valid) printf '%s\n' '{"schema_version":2,"version":"v-fake","persistent_recovered_leases":true,"recovered_quarantine_holder":"quarantined: fixture"}' ;;
      blank) printf '%s\n' '{"schema_version":2,"version":" \t ","persistent_recovered_leases":true,"recovered_quarantine_holder":"quarantined: fixture"}' ;;
    esac
  }
  reset_probe() { FM_TASK_COPY_RECOVERED_CAPABILITY_BIN=; FM_TASK_COPY_RECOVERED_CAPABILITY_VERDICT=; FM_TASK_COPY_RECOVERED_QUARANTINE_HOLDER=; }
  entry() { command jq -cn --arg holder "$1" --arg id "$2" '{name:"1",path:"/virtual/pool/1/project",leased:true,lease_holder:$holder,lease_id:$id}'; }
  run_guard() {  # <label> <entry-objects>
    STATE_JSON="{\"worktrees\":[$2]}"
    reset_probe
    rc=0
    fm_task_copy_pool_slots_hold_no_current_copy /virtual/project "$meta_dir" >/dev/null 2>&1 || rc=$?
  }
  # control: an ordinary entry whose second read works is admitted
  ANSWER=failing FAIL_SECOND=0
  run_guard ordinary "$(entry holder id-1)"
  [ "$rc" = 0 ] || fail "the ordinary control was refused"
  # an id-less recovered-shaped entry whose fresh read then fails is refused
  FAIL_SECOND=1
  run_guard second-read-fails "$(entry 'quarantined: fixture' '')"
  [ "$rc" != 0 ] || fail "an entry whose fresh read failed was admitted on an unproven provider"
  # whitespace-only version: not proven; control: a real version is
  for label in valid blank; do
    ANSWER=$label
    reset_probe
    rc=0
    fm_task_copy_treehouse_persists_recovered_leases || rc=$?
    verdict=$rc
    case "$label:$verdict" in valid:0|blank:1) ;; *) fail "version $label: capability exit $verdict" ;; esac
  done
  pass "a failed fresh read refuses on an unproven provider (an ordinary entry still admits), and a whitespace-only version is not a proof"
)

# A provider that publishes the old recovered holder followed by a newline (or only a
# newline) used to look proven: the raw value differed from the old holder in jq, but
# command substitution stored it stripped, equal to the old holder, so a recorded copy
# on a slot still on the old holder compared equal to the "protected" holder and was
# admitted (Main 1817). The shared guard now refuses: the capability is not proven, the
# stored holder is never the old holder, and a failed adopting status leaves the slot
# refused. Control: a normal distinct protected holder with the same failed status also
# refuses (it needs the adoption), and with an adopting status it is admitted.
test_forged_capability_holder_cannot_collapse_to_the_old_literal() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local case_name rc dir fslot
  command -v jq >/dev/null 2>&1 || fail "the in-memory guard checks require jq"
  dir="$TMP_ROOT/forged-holder"
  fslot="$dir/pool/1/project"
  mkdir -p "$fslot/state" "$dir/project"
  : > "$fslot/state/holder.meta"
  # The stub sets the guard's own variables inside this test's subshell on purpose.
  # shellcheck disable=SC2030
  fm_local_firstmate_state_dirs() { FM_LOCAL_FIRSTMATE_STATES=("$fslot/state"); FM_LOCAL_FIRSTMATE_SKIPPED=(); }
  fm_meta_get() { printf '%s\n' "$fslot/nested"; }
  fm_task_copy_canonical_dir() { printf '%s\n' "$1"; }
  fm_task_copy_enclosing_pool_slot() { printf '%s\n' "$fslot"; }
  jq() {
    local last=${!#}
    if [[ $last == */treehouse-state.json ]]; then
      local -a args=("$@")
      unset 'args[${#args[@]}-1]'
      command jq "${args[@]}" < "$dir/state.json"
    else
      command jq "$@"
    fi
  }
  treehouse() {
    case ${1-} in
      capabilities)
        case $CASE in
          forged-old-newline) command jq -cn --arg h "$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER"$'\n' '{schema_version:2,version:"fixture",persistent_recovered_leases:true,recovered_quarantine_holder:$h}' ;;
          forged-newline-only) command jq -cn '{schema_version:2,version:"fixture",persistent_recovered_leases:true,recovered_quarantine_holder:"\n"}' ;;
          valid-new*) command jq -cn '{schema_version:2,version:"fixture",persistent_recovered_leases:true,recovered_quarantine_holder:"quarantined: fixture"}' ;;
        esac ;;
      status)
        if [[ $CASE == valid-new-adopts ]]; then
          command jq -cn '{worktrees:[{name:"1",path:"'"$fslot"'",leased:true,lease_holder:"quarantined: fixture"}]}' > "$dir/state.json"
          printf '[]\n'
        else
          return 1
        fi ;;
      *) return 1 ;;
    esac
  }
  for case_name in forged-old-newline forged-newline-only valid-new valid-new-adopts; do
    CASE=$case_name
    command jq -cn --arg h "$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER" '{worktrees:[{name:"1",path:"'"$fslot"'",leased:true,lease_holder:$h}]}' > "$dir/state.json"
    FM_TASK_COPY_RECOVERED_CAPABILITY_BIN=
    FM_TASK_COPY_RECOVERED_CAPABILITY_VERDICT=
    FM_TASK_COPY_RECOVERED_QUARANTINE_HOLDER=
    FM_TASK_COPY_POOL_LISTING_PROJECTS=()
    FM_TASK_COPY_POOL_LISTINGS=()
    rc=0
    fm_task_copy_pool_slots_hold_no_current_copy "$dir/project" "$fslot/state" >/dev/null 2>&1 || rc=$?
    case "$case_name" in
      forged-*)
        [ "$rc" != 0 ] || fail "$case_name: a forged capability holder let the old-holder slot through"
        [ "$FM_TASK_COPY_RECOVERED_CAPABILITY_VERDICT" = no ] || fail "$case_name: the forged answer was taken as proof ($FM_TASK_COPY_RECOVERED_CAPABILITY_VERDICT)"
        [ "$FM_TASK_COPY_RECOVERED_QUARANTINE_HOLDER" != "$FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER" ] || fail "$case_name: the stored holder collapsed to the old holder"
        ;;
      valid-new) [ "$rc" != 0 ] || fail "$case_name: an old-holder slot was admitted without an adopting status" ;;
      valid-new-adopts) [ "$rc" = 0 ] || fail "$case_name: a proven provider that adopts the slot was refused" ;;
    esac
  done
  pass "a capability answer whose holder is the old holder plus a newline, or only a newline, is not proof and cannot make an old-holder slot pass; a distinct protected holder still needs its adoption"
)

# A fixture treehouse for the two allocation boundaries of Main 1817: <caps> is the
# capability answer (failing: unproven; proven), <pool-dir> either answers the case's
# own pool folder or fails, and <status> either marks treehouse-forbidden and fails
# (the guard must not run it) or answers a listing of slot 1 (a proven provider may).
# Every call is recorded; any other pool command marks treehouse-forbidden.
install_boundary_treehouse() {  # <failing|proven> <pool-dir-answers|pool-dir-fails> <status-forbidden|status-lists>
  local caps=$1 pooldir=$2 status=$3
  : > "$CASE_DIR/treehouse-calls"
  rm -f "$CASE_DIR/treehouse-forbidden"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/treehouse-calls"
case "\${1:-}" in
  capabilities)
    [ "$caps" = proven ] || exit 3
    jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}'
    exit 0
    ;;
  pool-dir)
    [ "$pooldir" = pool-dir-answers ] || exit 1
    printf '%s\n' "$CASE_DIR/pool"
    exit 0
    ;;
  status)
    if [ "$status" = status-lists ]; then
      printf '%s\n' '[{"name":"1","path":"$SLOT_DIR"}]'
      exit 0
    fi
    : > "$CASE_DIR/treehouse-forbidden"
    exit 1
    ;;
  lease|get|return|list|prune|destroy)
    : > "$CASE_DIR/treehouse-forbidden"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# A control spawn: the allocation guard did not refuse and the spawn launched and sent
# its treehouse get (the pool has no state file in these cases, so no slot claim is
# asserted: only that the guard stayed out of the way).
assert_boundary_control_spawns() {  # <name> <message>
  local out rc=0
  out=$(run_retained_spawn "$1") || rc=$?
  expect_code 0 "$rc" "$2"$'\n'"$out"
  assert_not_contains "$out" "refusing allocation" "$2: the guard refused"
  assert_contains "$out" "spawned new-$1" "$2: spawn did not launch"
  grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$2: spawn never sent its treehouse get"
}

# The two fail-open boundaries (Main 1817), each with a control:
#  - an unproven provider is never asked for `treehouse status` to find out whether an
#    unleased recorded slot is in the current pool (older treehouse answers status
#    with its own recovery): the guard refuses with no status call. Control: a proven
#    provider may use the listing, and does.
#  - a recorded copy inside a Treehouse pool slot whose state file is missing is
#    refused (its hold cannot be read), not skipped, whether the pool is evidenced by
#    `treehouse pool-dir` or by a `.treehouse` path component. Controls: a copy nested
#    under the project's own checkout, with the same state file missing and the same
#    unproven provider, is admitted (Git identity alone never makes a slot), as is a
#    home that uses no Treehouse pool.
test_unproven_allocation_runs_no_status_to_place_a_slot() {
  local name out rc root
  # 1a. unproven: no status, refusal names the upgrade
  name=boundary-no-status-unproven
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  install_boundary_treehouse failing pool-dir-fails status-forbidden
  cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
  rc=0
  out=$(run_retained_spawn "$name") || rc=$?
  # the prohibited behavior first: the unproven guard ran no status, whatever it then said
  [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$name: the unproven guard ran a pool command (status): $(cat "$CASE_DIR/treehouse-calls")"
  ! grep -q '^status' "$CASE_DIR/treehouse-calls" || fail "$name: the unproven guard ran treehouse status: $(cat "$CASE_DIR/treehouse-calls")"
  [ "$rc" -ne 0 ] || fail "$name: the spawn was accepted beside an unplaced unleased slot: $out"
  assert_contains "$out" "is not leased in Treehouse state" "$name: the refusal lost its reason"
  assert_contains "$out" "Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true" "$name: the refusal did not name the upgrade"
  ! grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$name: a refused allocation sent treehouse get"
  cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "$name: the refusal changed the pool state"
  # 1b. control: a proven provider may list, and the listing names the lease remedy
  name=boundary-status-proven
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  install_boundary_treehouse proven pool-dir-fails status-lists
  assert_retained_refusal "$name" "is not leased in Treehouse state" "treehouse lease '1'"
  grep -q '^status' "$CASE_DIR/treehouse-calls" || fail "$name: the proven guard did not use the listing"
  pass "an unproven provider is never asked for status to place an unleased slot (the refusal names the upgrade), while a proven provider may use the listing"
}

test_missing_state_file_in_a_pool_slot_refuses_and_plain_checkouts_spawn() {
  local name out rc
  # 2a. missing state file, pool evidenced by pool-dir
  name=boundary-missing-state-pooldir
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  rm -f "$CASE_DIR/pool/treehouse-state.json"
  install_boundary_treehouse failing pool-dir-answers status-forbidden
  assert_retained_refusal "$name" "cannot be proved leased"
  [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$name: the guard ran a pool command: $(cat "$CASE_DIR/treehouse-calls")"
  # 3a. control: a copy under the project's own checkout, state file missing, unproven provider
  name=boundary-control-primary-checkout
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$PROJECT_DIR" "nested-$name"
  rm -f "$CASE_DIR/pool/treehouse-state.json"
  install_boundary_treehouse failing pool-dir-answers status-forbidden
  assert_boundary_control_spawns "$name" "a copy under the project's own checkout stopped the spawn although it is no pool slot"
  # 3b. control: no record names any copy at all (a home with no Treehouse pool use)
  name=boundary-control-no-record
  make_retained_case "$name"
  rm -f "$CASE_DIR/pool/treehouse-state.json"
  install_boundary_treehouse failing pool-dir-fails status-forbidden
  assert_boundary_control_spawns "$name" "a home with no recorded copy stopped the spawn"
  pass "a recorded copy in a pool slot with no state file refuses (pool-dir evidence), while a copy under the project's own checkout and a home with no pool use still spawn"
}

# The `.treehouse` half of the missing-state boundary, with real directories: a slot
# of the project's repository under a `.treehouse` path whose pool folder has no state
# file, `treehouse pool-dir` failing, an unproven provider. The recorded copy inside it
# refuses (the hold cannot be read), and so does the same copy under a plain path when
# `treehouse pool-dir` cannot say (a linked worktree whose slot status cannot be proved
# is a slot, Main 1864 R-C: a changed case, a custom pool root looks exactly like it).
# Controls: the same copy under a plain path when pool-dir names another folder is
# proved not a slot and is not refused; a pool whose state file exists is judged by it
# as before.
test_missing_state_slot_under_a_dot_treehouse_path_refuses() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local variant root project slot nested_path rc expect
  # variant: where the pool is, what `treehouse pool-dir` answers, and the verdict
  for variant in 'dot-treehouse|dot|fails|refuse' 'pool-dir-evidence|plain|answers-pool|refuse' \
      'plain-path-unproven|plain|fails|refuse' 'pool-dir-elsewhere|plain|answers-other|admit'; do
    IFS='|' read -r variant where pooldir expect <<<"$variant"
    root="$TMP_ROOT/missing-state-$variant"
    [ "$where" != dot ] || root="$root/.treehouse"
    project="$TMP_ROOT/missing-state-$variant-project"
    fm_git_init_commit "$project"
    slot="$root/pool/1/project"
    mkdir -p "$root/pool/1" "$TMP_ROOT/missing-state-$variant-home/state" "$TMP_ROOT/missing-state-$variant-other"
    git -C "$project" worktree add --quiet --detach "$slot"
    slot=$(cd "$slot" && pwd -P)
    git -C "$project" worktree add --quiet -b "nested-$variant" "$slot/.claude/worktrees/nested"
    nested_path=$(cd "$slot/.claude/worktrees/nested" && pwd -P)
    : > "$TMP_ROOT/missing-state-$variant-home/state/holder.meta"
    ( fm_local_firstmate_state_dirs() { FM_LOCAL_FIRSTMATE_STATES=("$TMP_ROOT/missing-state-$variant-home/state"); FM_LOCAL_FIRSTMATE_SKIPPED=(); }
      fm_meta_get() { printf '%s\n' "$nested_path"; }
      treehouse() {
        [ "${1-}" = pool-dir ] || return 1
        case "$pooldir" in
          answers-pool) (cd "$root/pool" && pwd -P) ;;
          answers-other) (cd "$TMP_ROOT/missing-state-$variant-other" && pwd -P) ;;
          *) return 1 ;;
        esac
      }
      rc=0
      fm_task_copy_pool_slots_hold_no_current_copy "$project" "$TMP_ROOT/missing-state-$variant-home/state" >/dev/null 2>&1 || rc=$?
      case "$expect" in
        refuse) [ "$rc" != 0 ] || fail "$variant: a copy in a pool slot with no state file was skipped" ;;
        admit) [ "$rc" = 0 ] || fail "$variant: a copy in a worktree that pool-dir proves is outside the pool was refused" ;;
      esac
    ) || exit 1
  done
  pass "a recorded copy in a linked worktree with no state file refuses when the pool is evidenced by a .treehouse path or by treehouse pool-dir, and when pool-dir cannot say; it is not taken for a pool slot only when pool-dir names another folder"
)

# The capability-positive half: with the proof, a recovered slot on the
# published protected holder holding a task's current copy is a durable
# exclusion, so the spawn takes the free slot and leaves the recovered one, its
# lease entry, and its claim exactly as they were. Every state order and every
# kind of dirt in the recovered slot's root gives the same answer, because
# nothing about the root changes whether Treehouse keeps the lease.
test_recovered_slot_allows_allocation_with_proven_capability() {
  local order dirt name entry out rc
  local recovered=$PROTECTED_HOLDER
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
  pass "with a proven persistent-recovered-lease capability a recovered slot on the protected holder holding a current copy stays untouched while the spawn takes the free slot, whatever its root's state or state order"
}

# A proven fixture provider that also models the first state lock of a status
# read: with <mode> adopting it rewrites every leased entry on the old recovered
# holder to the protected one (lease kept, nothing moved), as the provider's
# interface promises; with stuck it leaves them. capabilities and status are
# recorded in $CASE_DIR/treehouse-calls; lease, get and return stay forbidden.
install_quarantine_treehouse() {  # <adopting|stuck>
  local mode=$1
  : > "$CASE_DIR/treehouse-calls"
  rm -f "$CASE_DIR/treehouse-forbidden"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/treehouse-calls"
state="$CASE_DIR/pool/treehouse-state.json"
case "\${1:-}" in
  capabilities)
    jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}'
    ;;
  status)
    printf '%s\n' "\${TREEHOUSE_NO_UPDATE_CHECK:-unset}" >> "$CASE_DIR/status-update-check"
    if IFS= read -r _; then printf 'stdin had data\n' >> "$CASE_DIR/status-stdin"; fi
    if [ "$mode" = adopting ]; then
      jq --arg old "$OLD_RECOVERED" --arg h "$PROTECTED_HOLDER" \
        '.worktrees |= map(if .leased == true and .lease_holder == \$old then .lease_holder = \$h else . end)' \
        "\$state" > "\$state.tmp" && mv "\$state.tmp" "\$state"
    fi
    printf '[]\n'
    ;;
  lease|get|return|list|prune|destroy)
    : > "$CASE_DIR/treehouse-forbidden"
    exit 99
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# What the exit of an older Treehouse session does to <state>: every entry leased
# by exactly the old recovered holder loses its lease and its nested copies are
# moved into a backup beside the pool. Any other holder, ordinary or protected,
# is left alone.
old_session_exit() {  # <state>
  local state=$1 path n=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    n=$((n + 1))
    if [ -d "$path/.claude/worktrees" ]; then
      mkdir -p "${state%/*}/../old-session-backup-$n"
      mv "$path/.claude/worktrees" "${state%/*}/../old-session-backup-$n/"
    fi
  done < <(jq -r --arg old "$OLD_RECOVERED" '.worktrees[] | select(.leased == true and .lease_holder == $old) | .path' "$state")
  jq --arg old "$OLD_RECOVERED" '.worktrees |= map(if .leased == true and .lease_holder == $old then del(.leased, .lease_holder) else . end)' \
    "$state" > "$state.tmp" && mv "$state.tmp" "$state"
}

# The lease treehouse get would write for the new owner of free slot 2, and a
# file of its work, so a later old-session exit can be shown to leave both.
model_new_owner() {  # <id>
  jq --arg p "$PANE_DIR" --arg id "$1" \
    '.worktrees |= map(if .path == $p then (.leased = true | .lease_holder = $id | .lease_id = "0123456789abcdef0123456789abcdef") else . end)' \
    "$CASE_DIR/pool/treehouse-state.json" > "$CASE_DIR/pool/treehouse-state.json.tmp"
  mv "$CASE_DIR/pool/treehouse-state.json.tmp" "$CASE_DIR/pool/treehouse-state.json"
  printf 'new owner work\n' > "$PANE_DIR/new-owner.txt"
}

assert_quarantine_intact() {  # <label> <new-owner-id or empty>
  jq -e --arg p "$SLOT_DIR" --arg h "$PROTECTED_HOLDER" \
    '[.worktrees[] | select(.path == $p)] | length == 1 and .[0].leased == true and .[0].lease_holder == $h and ((.[0].lease_id // "") == "")' \
    "$CASE_DIR/pool/treehouse-state.json" >/dev/null \
    || fail "$1: the recovered slot is not leased under the protected holder: $(cat "$CASE_DIR/pool/treehouse-state.json")"
  retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$1: the recovered slot changed"
  assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$1: the recovered slot's nested copy was moved or lost"
  ! compgen -G "$CASE_DIR/old-session-backup-*" >/dev/null || fail "$1: an old session's exit moved a copy into a backup"
  [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "$1: the recovered slot was claimed"
  [ -n "${2:-}" ] || return 0
  jq -e --arg p "$PANE_DIR" --arg id "$2" '.worktrees[] | select(.path == $p) | .leased == true and .lease_holder == $id' \
    "$CASE_DIR/pool/treehouse-state.json" >/dev/null || fail "$1: the new owner's lease was cleared"
  assert_grep 'new owner work' "$PANE_DIR/new-owner.txt" "$1: the new owner's copy lost its work"
}

# N1: an older session's exit sweeps only entries on the exact old holder. A
# proven provider's status adopts them under the protected holder, so an exit
# before the allocation or after it leaves the recovered slot's lease and copy
# and the new owner's lease and copy intact.
test_old_holder_is_adopted_and_old_session_exit_cannot_sweep() {
  local timing name out rc
  for timing in before after; do
    name="adopt-$timing"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    add_free_second_slot "$(printf ',"leased":true,"lease_holder":"%s"' "$OLD_RECOVERED")"
    install_quarantine_treehouse adopting
    retained_fingerprint > "$CASE_DIR/before-copy"
    if [ "$timing" = before ]; then
      (cd "$PROJECT_DIR" && PATH="$FAKEBIN_DIR:$PATH" treehouse status </dev/null >/dev/null)
      old_session_exit "$CASE_DIR/pool/treehouse-state.json"
      assert_quarantine_intact "$timing: exit after the adopting status"
      : > "$CASE_DIR/treehouse-calls"
    fi
    rm -f "$CASE_DIR/status-update-check" "$CASE_DIR/status-stdin"
    rc=0
    out=$(unset TREEHOUSE_NO_UPDATE_CHECK; run_retained_spawn "$name") || rc=$?
    expect_code 0 "$rc" "$timing: the spawn beside an adopted recovered slot failed"$'\n'"$out"
    assert_contains "$out" "spawned new-$name" "$timing: spawn did not launch"
    assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "$timing: spawn did not claim the free slot"
    [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$timing: the guard ran a lease, get or return: $(cat "$CASE_DIR/treehouse-calls")"
    if [ "$timing" = after ]; then
      assert_equals 1 "$(grep -c '^status' "$CASE_DIR/treehouse-calls")" "$timing: the guard did not adopt by exactly one status: $(cat "$CASE_DIR/treehouse-calls")"
      assert_equals 1 "$(cat "$CASE_DIR/status-update-check")" "$timing: the adopting status ran with the update check on"
      assert_absent "$CASE_DIR/status-stdin" "$timing: the adopting status did not get EOF stdin"
    else
      ! grep -q '^status' "$CASE_DIR/treehouse-calls" || fail "$timing: the guard ran status for an entry already on the protected holder"
    fi
    model_new_owner "new-$name"
    old_session_exit "$CASE_DIR/pool/treehouse-state.json"
    assert_quarantine_intact "$timing: exit after the allocation" "new-$name"
  done
  pass "an old holder adopted under the protected holder survives an old session's exit before and after the allocation, with the new owner's lease and copy intact"
}

# An entry a proven provider's status did not adopt is refused, never relaxed,
# with a named cause and before any claim or record is published; adoption runs
# once per process however many recovered slots the records name.
test_unadopted_old_holder_refuses_and_adoption_runs_once() {
  local name third out rc
  name=unadopted
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  add_free_second_slot "$(printf ',"leased":true,"lease_holder":"%s"' "$OLD_RECOVERED")"
  install_quarantine_treehouse stuck
  cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
  assert_retained_refusal "$name" "did not rewrite it to the protected holder '$PROTECTED_HOLDER'" \
    "Report this entry for repair" "treehouse lease '"
  [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "unadopted: the guard ran a lease, get or return"
  assert_equals 1 "$(grep -c '^status' "$CASE_DIR/treehouse-calls")" "unadopted: the guard did not try exactly one adopting status"
  cmp -s "$CASE_DIR/before-state" "$CASE_DIR/pool/treehouse-state.json" || fail "unadopted: the refusal changed the pool state"

  name=adopt-once
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  add_free_second_slot ''
  third="$CASE_DIR/pool/3/project"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$third"
  add_nested_record "$HOME_DIR/state/other.meta" "$PROJECT_DIR" "$third" "nested-other-$name"
  jq -n --arg a "$SLOT_DIR" --arg b "$PANE_DIR" --arg c "$third" --arg old "$OLD_RECOVERED" \
    '{worktrees: [{name: "1", path: $a, leased: true, lease_holder: $old}, {name: "2", path: $b},
      {name: "3", path: $c, leased: true, lease_holder: $old}]}' > "$CASE_DIR/pool/treehouse-state.json"
  install_quarantine_treehouse adopting
  rc=0
  out=$(run_retained_spawn "$name") || rc=$?
  expect_code 0 "$rc" "adopt-once: the spawn beside two adopted recovered slots failed"$'\n'"$out"
  assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "adopt-once: spawn did not claim the free slot"
  assert_equals 1 "$(grep -c '^status' "$CASE_DIR/treehouse-calls")" "adopt-once: adoption ran other than once: $(cat "$CASE_DIR/treehouse-calls")"
  pass "an old holder the provider did not adopt refuses before treehouse get with a named cause, and adoption runs once per process"
}

# The home-seed caller's shared guard, run as bin/fm-home-seed.sh runs it before
# its treehouse get --lease: inert and refusing on an unproven provider, refusing
# an unadopted old holder, and passing beside a protected slot.
run_home_seed_guard() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_ROOT_OVERRIDE='' PATH="$FAKEBIN_DIR:$PATH" \
    bash -c '. "$1/fm-wake-lib.sh" && . "$1/fm-backend.sh" && . "$1/fm-task-copy-lib.sh" && fm_task_copy_pool_slots_hold_no_current_copy "$2" "$3"' \
    _ "$ROOT/bin" "$PROJECT_DIR" "$HOME_DIR/state" 2>&1
}

test_home_seed_guard_follows_the_protected_holder() {
  local shape name out rc
  for shape in unproven stuck adopting protected; do
    name="home-seed-$shape"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    if [ "$shape" = protected ]; then
      add_free_second_slot "$(printf ',"leased":true,"lease_holder":"%s"' "$PROTECTED_HOLDER")"
    else
      add_free_second_slot "$(printf ',"leased":true,"lease_holder":"%s"' "$OLD_RECOVERED")"
    fi
    case "$shape" in
      unproven) install_capability_treehouse no-holder ;;
      stuck) install_quarantine_treehouse stuck ;;
      *) install_quarantine_treehouse adopting ;;
    esac
    retained_fingerprint > "$CASE_DIR/before-copy"
    rc=0
    out=$(run_home_seed_guard) || rc=$?
    case "$shape" in
      unproven|stuck)
        [ "$rc" -ne 0 ] || fail "$shape: the home-seed guard allowed an allocation beside an old recovered holder"
        assert_contains "$out" "refusing allocation before treehouse get" "$shape: the home-seed guard did not refuse before get"
        [ "$shape" != unproven ] || assert_only_capability_probes "$shape"
        ;;
      *)
        expect_code 0 "$rc" "$shape: the home-seed guard refused beside a protected slot"$'\n'"$out"
        jq -e --arg p "$SLOT_DIR" --arg h "$PROTECTED_HOLDER" '.worktrees[] | select(.path == $p) | .lease_holder == $h' \
          "$CASE_DIR/pool/treehouse-state.json" >/dev/null || fail "$shape: the recovered slot is not on the protected holder"
        ;;
    esac
    [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$shape: the home-seed guard ran a lease, get or return"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$shape: the home-seed guard changed the recovered slot"
  done
  pass "the shared guard bin/fm-home-seed.sh runs refuses an old recovered holder until the provider adopts it, and passes beside a protected slot"
}

# The rollout in order: the consumer first, inert on the old provider at both
# allocation paths; then the provider install and its adopting status; then an
# old session's exit; then an allocation and another exit. The recovered copy
# and the new owner's copy stay intact at every step.
test_combined_rollout_keeps_recovered_and_new_copies() {
  local name=rollout out rc
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  add_free_second_slot "$(printf ',"leased":true,"lease_holder":"%s"' "$OLD_RECOVERED")"
  install_capability_treehouse unknown
  assert_retained_refusal "$name" "is not a Firstmate home and carries Treehouse's recovered-state lease" \
    "Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true"
  rc=0
  out=$(run_home_seed_guard) || rc=$?
  [ "$rc" -ne 0 ] || fail "rollout: the home-seed guard allowed an allocation on the old provider"
  assert_only_capability_probes "rollout: old provider"
  retained_fingerprint > "$CASE_DIR/before-copy"
  install_quarantine_treehouse adopting
  (cd "$PROJECT_DIR" && PATH="$FAKEBIN_DIR:$PATH" treehouse status </dev/null >/dev/null)
  assert_quarantine_intact "rollout: after the install and its adopting status"
  old_session_exit "$CASE_DIR/pool/treehouse-state.json"
  assert_quarantine_intact "rollout: after an old session's exit"
  rc=0
  out=$(run_retained_spawn "$name") || rc=$?
  expect_code 0 "$rc" "rollout: the allocation after the install failed"$'\n'"$out"
  assert_grep "task=new-$name" "$CASE_DIR/pool/2/.fm-slot-owner" "rollout: the allocation did not take the free slot"
  model_new_owner "new-$name"
  assert_quarantine_intact "rollout: after the allocation" "new-$name"
  old_session_exit "$CASE_DIR/pool/treehouse-state.json"
  assert_quarantine_intact "rollout: after an old session's exit following the allocation" "new-$name"
  pass "the combined rollout keeps the recovered copy and the new owner's copy intact at every step"
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

# A fixture treehouse that implements `get`, for the case that must run the spawn's
# own allocation: capabilities answers a proven provider, `get --root <root>` hands
# out the first slot the state does not lease (mode normal) or deliberately the
# recovered slot (mode chooses-recovered, the defect the case must be able to see),
# and a get without an explicit --root is refused. Every call is recorded; status,
# lease, return, list, prune and destroy mark treehouse-forbidden and fail.
install_getting_treehouse() {  # <normal|chooses-recovered|prints-and-exits|fails>
  local mode=$1
  : > "$CASE_DIR/treehouse-calls"
  rm -f "$CASE_DIR/treehouse-forbidden"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/treehouse-calls"
state="$CASE_DIR/pool/treehouse-state.json"
case "\${1:-}" in
  capabilities)
    jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}'
    exit 0
    ;;
  get)
    shift
    root=
    while [ \$# -gt 0 ]; do
      case "\$1" in --root) root=\${2:-}; shift 2 || exit 2 ;; *) shift ;; esac
    done
    [ -n "\$root" ] || { echo "fake treehouse: get needs an explicit --root" >&2; exit 2; }
    # The interactive get stays alive for the whole session (its subshell owns the
    # allocation): after it prints the slot it beats until the .alive marker goes. Mode
    # prints-and-exits is the defect the case must see: it prints and returns at once.
    hold() {
      [ -n "\${FM_FAKE_GET_BEAT:-}" ] || return 0
      n=0
      while [ -e "\${FM_FAKE_GET_ALIVE:-/nonexistent}" ] && [ "\$n" -lt 600 ]; do
        : > "\$FM_FAKE_GET_BEAT"
        n=\$((n + 1))
        /bin/sleep 0.2
      done
    }
    case "$mode" in
      chooses-recovered) printf '%s\n' "$SLOT_DIR"; hold; exit 0 ;;
      prints-and-exits) jq -r '[.worktrees[] | select((.leased // false) | not)][0].path' "\$state"; exit 0 ;;
      fails) echo "fake treehouse: get failed" >&2; exit 1 ;;
    esac
    jq -r '[.worktrees[] | select((.leased // false) | not)][0].path' "\$state"
    hold
    exit 0
    ;;
  status|lease|return|list|prune|destroy)
    : > "$CASE_DIR/treehouse-forbidden"
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# What the spawn's own allocation did, read from the slot the executed command chose
# (the pane path the fixture tmux reports after it ran the recorded `treehouse get`):
# the command ran once with an explicit root, it chose the free slot and not the
# recovered one, the spawn claimed that slot, and the recovered slot's copy, entry
# and claim are byte-preserved.
assert_spawn_took_the_slot_its_own_get_chose() {  # <name> <free-slot> <label>
  local chosen
  chosen=$(cat "$CASE_DIR/pane-path" 2>/dev/null) || fail "$3: the recorded treehouse get never ran, so no slot was chosen"
  # the fixture kept a live subshell in the chosen slot, as a real pane does: its own
  # recorded working directory is the chosen slot and it was still beating when the
  # spawn finished (it is released by removing the .alive marker, never by a signal)
  [ -e "$CASE_DIR/pane-path.alive" ] || fail "$3: the fixture's live subshell was released before the spawn finished"
  [ -e "$CASE_DIR/pane-path.beat" ] || fail "$3: the fixture's live subshell never beat"
  # the get itself stayed alive after printing its slot, as the interactive get does
  [ -e "$CASE_DIR/pane-path.getbeat" ] || fail "$3: the get returned as soon as it printed its slot, so it never held the allocation"
  [ "$(grep -c '^get ' "$CASE_DIR/treehouse-calls")" = 1 ] || fail "$3: the spawn's get did not run exactly once: $(cat "$CASE_DIR/treehouse-calls")"
  grep -Fxq "get --root $CASE_DIR/real-root" "$CASE_DIR/treehouse-calls" || fail "$3: the get did not carry the explicit fixture root: $(cat "$CASE_DIR/treehouse-calls")"
  [ ! -e "$CASE_DIR/treehouse-forbidden" ] || fail "$3: a pool diagnostic command ran: $(cat "$CASE_DIR/treehouse-calls")"
  [ "$chosen" != "$SLOT_DIR" ] || fail "$3: the get chose the recovered slot $SLOT_DIR"
  [ "$chosen" = "$2" ] || fail "$3: the get chose $chosen, not the free slot $2"
  assert_grep "task=new-$1" "${chosen%/*}/.fm-slot-owner" "$3: the spawn did not claim the slot its get chose"
  [ ! -e "${SLOT_DIR%/*}/.fm-slot-owner" ] || fail "$3: the spawn claimed the recovered slot"
  retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$3: the recovered slot's copy changed"
  jq -c --arg p "$SLOT_DIR" '.worktrees[] | select(.path == $p)' "$CASE_DIR/pool/treehouse-state.json" | cmp -s - "$CASE_DIR/before-entry" \
    || fail "$3: the recovered slot's entry changed"
  cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$3: the holder's record changed"
  assert_grep 'nested unlanded commit' "$NESTED_COPY/nested-owned.txt" "$3: the recovered slot's nested work was lost"
}

# run_retained_spawn with the fixture tmux executing the spawn's own treehouse get.
run_spawn_with_own_get() {  # <name>
  FM_FAKE_TMUX_GET_DIR=$PROJECT_DIR FM_FAKE_TMUX_GET_ROOT="$CASE_DIR/real-root" \
    FM_FAKE_PANE_PATH_FILE="$CASE_DIR/pane-path" FM_FAKE_TMUX_GET_LOG="$CASE_DIR/get-log" \
    run_retained_spawn "$1"
}

# The spawn's allocation is executed, not predetermined: the fixture tmux runs the
# `treehouse get` the spawn typed, against the case's private pool with an explicit
# root, and the test reads the slot that command chose. Mutation control: the same
# check, run against a get that hands out the recovered slot, must fail; so a broken
# interactive allocation can no longer coexist with a passing test.
test_spawn_runs_its_own_get_and_takes_the_slot_that_command_chose() (
  local mode name out rc second mutant
  for mode in normal chooses-recovered prints-and-exits fails; do
    name="own-get-$mode"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    add_free_second_slot "$(printf ',"leased":true,"lease_holder":"%s"' "$PROTECTED_HOLDER")"
    second=$PANE_DIR
    PANE_DIR=$PROJECT_DIR
    install_getting_treehouse "$mode"
    retained_fingerprint > "$CASE_DIR/before-copy"
    jq -c --arg p "$SLOT_DIR" '.worktrees[] | select(.path == $p)' "$CASE_DIR/pool/treehouse-state.json" > "$CASE_DIR/before-entry"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    rm -f "$CASE_DIR/pane-path"
    rc=0
    out=$(FM_FAKE_TMUX_GET_LIVE=beat run_spawn_with_own_get "$name") || rc=$?
    case "$mode" in
      normal)
        expect_code 0 "$rc" "$mode: the spawn beside a recovered quarantine failed"$'\n'"$out"
        assert_contains "$out" "spawned new-$name" "$mode: spawn did not launch"
        assert_spawn_took_the_slot_its_own_get_chose "$name" "$second" "$mode"
        ;;
      chooses-recovered)
        # The mutant must be rejected by the named assertion: the validator saw the
        # recovered slot being chosen, not merely some failure (a missing path file,
        # an unrelated refusal).
        mutant=$( ( assert_spawn_took_the_slot_its_own_get_chose "$name" "$second" "$mode" ) 2>&1 ) \
          && fail "$mode: the validator accepted a get that handed out the recovered slot"
        case "$mutant" in
          *"the get chose the recovered slot $SLOT_DIR"*) ;;
          *) fail "$mode: the validator failed for the wrong reason: $mutant" ;;
        esac
        ;;
      prints-and-exits)
        # a get that prints a slot and returns holds no allocation: the pane never reports
        # a path, the spawn fails, and no path is fabricated for it
        [ "$rc" -ne 0 ] || fail "$mode: the spawn succeeded although its get printed a slot and returned at once"$'\n'"$out"
        [ ! -s "$CASE_DIR/pane-path" ] || fail "$mode: a path was published for a get that did not stay alive"
        [ ! -e "$CASE_DIR/pane-path.getbeat" ] || fail "$mode: the returning get beat"
        ;;
      fails)
        # a get that fails fails the spawn and leaves no path: nothing is faked
        [ "$rc" -ne 0 ] || fail "$mode: the spawn succeeded although its treehouse get failed"$'\n'"$out"
        [ ! -s "$CASE_DIR/pane-path" ] || fail "$mode: a path was fabricated for a failed get"
        ;;
    esac
    rm -f "$CASE_DIR/pane-path.alive"
  done
  pass "the spawn's own treehouse get is executed against the private pool with an explicit root, the test reads the slot that command chose, the recovered slot is byte-preserved, and a get that hands out the recovered slot is detected"
)

# The oracle's own check (Main 1817): moving the nested copy's HEAD to a commit with
# the same bytes changes the fingerprint now; the enclosing-slot-only fingerprint it
# replaces does not, which is why it could pass a moved nested copy.
test_retained_fingerprint_sees_the_nested_copy_head() (
  local name=fp-nested-head before after old_before old_after
  old_fingerprint() {
    git -C "$SLOT_DIR" rev-parse HEAD
    git -C "$SLOT_DIR" symbolic-ref --quiet HEAD || true
    git -C "$SLOT_DIR" reflog
    git -C "$SLOT_DIR" status --porcelain --untracked-files=all
    (cd "$SLOT_DIR" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s ' "$file"
      cksum < "$file"
    done)
  }
  make_retained_case "$name"
  add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
  before=$(retained_fingerprint)
  old_before=$(old_fingerprint)
  git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "same bytes, new HEAD"
  after=$(retained_fingerprint)
  old_after=$(old_fingerprint)
  [ "$old_before" = "$old_after" ] || fail "the control is wrong: the enclosing-slot-only fingerprint saw the nested HEAD move"
  [ "$before" != "$after" ] || fail "the fingerprint did not see the nested copy's HEAD move to a commit with the same bytes"
  pass "the preservation fingerprint reads the nested copy's HEAD: a same-bytes HEAD move changes it, and the old enclosing-slot-only fingerprint did not"
)

# The recovered slot's pool-state entry must be preserved field by field: every field
# of the entry for <path> (leased, lease_holder, lease_id, leased_at, recovery_reason,
# owner fields, anything the provider keeps) equals the earlier read, except the fields
# named (the protected-holder rewrite changes lease_holder only). Other entries are not
# its business: a compliant provider may record changes to the free candidate it hands
# out, so the whole state file is never compared.
assert_lease_entry_preserved() {  # <before-state> <after-state> <path> <label> [except-field...]
  local before=$1 after=$2 path=$3 label=$4 drop
  shift 4
  drop=$(jq -cn '$ARGS.positional' --args -- "$@")
  jq -e --slurpfile b "$before" --arg p "$path" --argjson drop "$drop" '
    def entry($f): [$f.worktrees[]? | select(.path == $p)];
    def strip: map(reduce $drop[] as $k (.; del(.[$k])));
    (entry($b[0]) | length) == 1
    and (entry(.) | length) == 1
    and (entry($b[0]) | strip) == (entry(.) | strip)' "$after" >/dev/null \
    || fail "$label: the recovered slot's pool entry changed in a field it must keep: before $(jq -c --arg p "$path" '[.worktrees[]? | select(.path == $p)]' "$before") after $(jq -c --arg p "$path" '[.worktrees[]? | select(.path == $p)]' "$after")"
}

# The oracle's own check: it accepts a rewrite of only the named field and a change
# elsewhere in the state file, and rejects a change to ANY other field of the slot's
# entry (lease id, lease time, leased flag, a recovery reason, a second entry).
test_lease_entry_oracle_checks_every_field() (
  local dir variant expect rc
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lease-entry.XXXXXX") || fail "cannot create a scratch directory"
  jq -n '{worktrees:[{name:"1",path:"/slot/a",leased:true,lease_holder:"recovered: old",lease_id:"id-1",leased_at:100,recovery_reason:"corrupt",owner_pid:0},{name:"2",path:"/slot/b"}]}' > "$dir/before.json"
  for variant in 'identical|.|none|accept' \
      'holder-rewritten|.worktrees[0].lease_holder = "quarantined: p"|lease_holder|accept' \
      'free-slot-changed|.worktrees[1].leased = true|none|accept' \
      'holder-rewritten-not-allowed|.worktrees[0].lease_holder = "quarantined: p"|none|reject' \
      'lease-id-changed|.worktrees[0].lease_id = "id-2"|lease_holder|reject' \
      'lease-time-changed|.worktrees[0].leased_at = 101|lease_holder|reject' \
      'leased-flag-cleared|.worktrees[0].leased = false|lease_holder|reject' \
      'reason-dropped|del(.worktrees[0].recovery_reason)|lease_holder|reject' \
      'owner-field-added|.worktrees[0].owner_pid = 7|lease_holder|reject' \
      'second-entry|.worktrees += [.worktrees[0]]|lease_holder|reject'; do
    IFS='|' read -r variant filter except expect <<<"$variant"
    jq "$filter" "$dir/before.json" > "$dir/after.json"
    rc=0
    if [ "$except" = none ]; then
      ( assert_lease_entry_preserved "$dir/before.json" "$dir/after.json" /slot/a "$variant" ) >/dev/null 2>&1 || rc=$?
    else
      ( assert_lease_entry_preserved "$dir/before.json" "$dir/after.json" /slot/a "$variant" "$except" ) >/dev/null 2>&1 || rc=$?
    fi
    case "$expect:$rc" in
      accept:0|reject:1) ;;
      *) rm -rf "$dir"; fail "$variant: the lease-entry oracle gave exit $rc, expected to $expect" ;;
    esac
  done
  rm -rf "$dir"
  pass "the lease-entry oracle accepts the named holder rewrite and unrelated slots changing, and rejects a change to the lease id, lease time, leased flag, recovery reason, owner fields or a second entry"
)

# Every allocation a fixture makes with a real provider names its pool root with an
# explicit --root (the contract's fixture hard gate; TREEHOUSE_ROOT in the environment
# is not that argument). The scanner lists the provider `get` calls of a file that carry
# none; the test runs it over both suites that drive a real provider and over a mutant
# file with one root-less get, which it must catch.
provider_gets_without_root() {  # <file>
  # The pattern is literal text to find, never an expansion.
  # shellcheck disable=SC2016
  grep -n -E '("\$bin"|"\$UNC_PROVIDER"|"\$FM_TEST_TREEHOUSE_PROVIDER") get ' "$1" | grep -v -e '--root' || true
}

test_fixture_provider_gets_name_a_root() (
  local file found dir q d
  for file in "$ROOT/tests/fm-teardown-pool.test.sh" "$ROOT/tests/fm-spawn-retained-copy.test.sh"; do
    found=$(provider_gets_without_root "$file")
    [ -z "$found" ] || fail "a real-provider fixture allocation names no --root in ${file##*/}: $found"
  done
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-gets.XXXXXX") || fail "cannot create a scratch directory"
  # the sample lines are assembled from fragments so that this file carries no call
  # the scanner itself would flag
  q='"' d='$'
  printf '%s\n' "a=${q}${d}bin${q} get --root r --no-fetch --lease" > "$dir/good.sh"
  printf '%s\n' "a=${q}${d}bin${q} get --no-fetch --lease" > "$dir/bad.sh"
  printf '%s\n' "x=${q}${d}UNC_PROVIDER${q} get --no-fetch --lease --lease-holder next" > "$dir/bad2.sh"
  [ -z "$(provider_gets_without_root "$dir/good.sh")" ] || { rm -rf "$dir"; fail "the scanner flagged a get that names its root"; }
  [ -n "$(provider_gets_without_root "$dir/bad.sh")" ] || { rm -rf "$dir"; fail "the scanner missed a root-less get (the mutant)"; }
  [ -n "$(provider_gets_without_root "$dir/bad2.sh")" ] || { rm -rf "$dir"; fail "the scanner missed a root-less reuse get (the mutant)"; }
  rm -rf "$dir"
  pass "every real-provider fixture get in the teardown and spawn suites names an explicit --root, and the scanner catches a get that does not"
)

# The real-provider half of the capability-positive case. Needs the treehouse
# named by FM_TEST_TREEHOUSE_PROVIDER, a build that proves persistent recovered
# leases (never installed; linked into this case's own fakebin). Pools, HOME,
# XDG configuration and TREEHOUSE_ROOT are the case's own. Slot A is a recovered
# quarantine holding a task's nested current copy, slot B is free; the spawn must
# take B and leave A, its pool entry, its copy and the whole state file as they
# were, and the real `treehouse get` that follows must hand out B. Without the
# variable the case prints a loud named skip and checks nothing.
test_real_provider_recovered_slot_allows_free_slot_allocation() {
  local recovered
  if [ -z "${FM_TEST_TREEHOUSE_PROVIDER:-}" ] || [ ! -x "$FM_TEST_TREEHOUSE_PROVIDER" ]; then
    printf 'skip - real-provider recovered-slot allocation: FM_TEST_TREEHOUSE_PROVIDER names no executable treehouse; the case did NOT run\n'
    return 0
  fi
  recovered=$(cd / && TREEHOUSE_NO_UPDATE_CHECK=1 "$FM_TEST_TREEHOUSE_PROVIDER" capabilities --json </dev/null 2>/dev/null \
    | jq -r --arg old "$OLD_RECOVERED" 'select(.schema_version == 2 and (.version | type == "string" and length > 0) and .persistent_recovered_leases == true) | .recovered_quarantine_holder // "" | select(. != $old)' 2>/dev/null) || recovered=
  if [ -z "$recovered" ]; then
    printf 'skip - real-provider recovered-slot allocation: %s publishes no recovered_quarantine_holder; the case did NOT run\n' "$FM_TEST_TREEHOUSE_PROVIDER"
    return 0
  fi
  ( real_provider_recovered_slot_cases ) || exit 1
  pass "against the real provider a recovered quarantine holding a current copy stays untouched while the spawn and the following get take the free slot, in both state orders"
}

# The cases of the test above. It runs them in a subshell, so their exports and
# fixture globals stay there.
real_provider_recovered_slot_cases() {
  local name order start out rc a b entry state pool
  for start in protected old; do
  for order in recovered-first free-first; do
    name="real-provider-$start-$order"
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
    a=$(cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" get --root "$CASE_DIR/real-root" --no-fetch --lease --lease-holder holder </dev/null 2>/dev/null) || fail "$order: cannot lease slot A"
    b=$(cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" get --root "$CASE_DIR/real-root" --no-fetch --lease --lease-holder spare </dev/null 2>/dev/null) || fail "$order: cannot lease slot B"
    a=$(cd "$a" && pwd -P)
    b=$(cd "$b" && pwd -P)
    (cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" return "$b" --if-lease-holder spare </dev/null >/dev/null 2>&1) || fail "$order: cannot free slot B"
    pool=${a%/*/*}
    state=$pool/treehouse-state.json
    if [ "$start" = old ]; then
      jq --arg r "$OLD_RECOVERED" --arg a "$a" '.worktrees |= map(if .path == $a then (.lease_holder = $r | del(.lease_id)) else . end)' \
        "$state" > "$state.tmp" || fail "$order: cannot make slot A recovered"
    else
      jq --arg r "$recovered" --arg a "$a" '.worktrees |= map(if .path == $a then (.lease_holder = $r | del(.lease_id)) else . end)' \
        "$state" > "$state.tmp" || fail "$order: cannot make slot A recovered"
    fi
    mv "$state.tmp" "$state"
    if [ "$order" = free-first ]; then
      jq '.worktrees |= reverse' "$state" > "$state.tmp" || fail "$order: cannot reorder the state"
      mv "$state.tmp" "$state"
    fi
    SLOT_DIR=$a
    PANE_DIR=$PROJECT_DIR
    rm -f "$CASE_DIR/pane-path"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$a" "nested-$name"
    : > "$CASE_DIR/pane-log"
    : > "$CASE_DIR/launch-log"
    retained_fingerprint > "$CASE_DIR/before-copy"
    cp "$state" "$CASE_DIR/before-state"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    rc=0
    out=$(run_spawn_with_own_get "$name") || rc=$?
    expect_code 0 "$rc" "$order: the spawn beside a real recovered quarantine failed"$'\n'"$out"
    assert_not_contains "$out" "refusing allocation" "$order: the recovered quarantine still blocked allocation"
    assert_contains "$out" "spawned new-$name" "$order: spawn did not launch"
    grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$order: spawn never acquired a slot"
    # The slot is the one the spawn's own get chose, executed against the real
    # provider by the fixture tmux, never one the fixture preselected.
    [ "$(cat "$CASE_DIR/pane-path" 2>/dev/null)" = "$b" ] || fail "$order: the spawn's own get chose $(cat "$CASE_DIR/pane-path" 2>/dev/null), not the free slot $b"
    assert_grep "task=new-$name" "$b/../.fm-slot-owner" "$order: spawn did not claim the free slot"
    [ ! -e "$a/../.fm-slot-owner" ] || fail "$order: spawn claimed the recovered slot"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$order: spawn changed the recovered slot"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "$order: spawn changed the holder's record"
    # Slot A's entry, field by field: the protected start keeps every field; the old
    # start changes lease_holder only (the adopting rewrite). The free slot's entry and
    # the rest of the state file are the provider's own business.
    if [ "$start" = protected ]; then
      assert_lease_entry_preserved "$CASE_DIR/before-state" "$state" "$a" "$start/$order: after the spawn"
    else
      assert_lease_entry_preserved "$CASE_DIR/before-state" "$state" "$a" "$start/$order: after the spawn" lease_holder
    fi
    cp "$state" "$CASE_DIR/after-spawn-state"
    jq -e --arg a "$a" --arg r "$recovered" '[.worktrees[] | select(.path == $a)] | length == 1 and .[0].leased == true and .[0].lease_holder == $r and ((.[0].lease_id // "") == "")' "$state" >/dev/null \
      || fail "$start/$order: the recovered slot is not leased under the protected holder after the spawn"
    old_session_exit "$state"
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$start/$order: an old session's exit changed the recovered slot"
    ! compgen -G "$pool/../treehouse-recovered-backup-*" >/dev/null || fail "$order: a recovered backup appeared"
    # A further get, run for real as an extra check (not a substitute for the spawn's own get
    # above). The spawn's own get still holds B, so no later get is assumed to return B or any
    # particular slot: it may hand out another slot or fail at capacity, but it never hands out
    # the recovered slot A and never the slot B the live get holds.
    entry=$(cd "$PROJECT_DIR" && "$FM_TEST_TREEHOUSE_PROVIDER" get --root "$CASE_DIR/real-root" --no-fetch --lease --lease-holder next </dev/null 2>/dev/null) || entry=
    if [ -n "$entry" ]; then
      entry=$(cd "$entry" && pwd -P)
      [ "$entry" != "$a" ] || fail "$order: a further get handed out the recovered slot $a"
      [ "$entry" != "$b" ] || fail "$order: a further get handed out the slot $b that the spawn's own get holds"
    fi
    retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "$order: the real get changed the recovered slot"
    jq -e --arg a "$a" --arg r "$recovered" '.worktrees[] | select(.path == $a) | .lease_holder == $r and (.lease_id // "") == ""' "$state" >/dev/null \
      || fail "$order: the recovered entry changed after the real get"
    assert_lease_entry_preserved "$CASE_DIR/after-spawn-state" "$state" "$a" "$start/$order: after the further get"
    ! compgen -G "$pool/../treehouse-recovered-backup-*" >/dev/null || fail "$order: the real get left a recovered backup"
  done
  done
}

test_nested_copy_in_leased_slot_allows_allocation() {
  local spelling name out rc
  for spelling in direct alias; do
    name="leased-$spelling"
    make_retained_case "$name"
    add_nested_record "$HOME_DIR/state/holder.meta" "$PROJECT_DIR" "$SLOT_DIR" "nested-$name"
    add_free_second_slot ',"leased":true,"lease_holder":"holder","lease_id":"0123456789abcdef0123456789abcdef"'
    if [ "$spelling" = alias ]; then
      # Treehouse state spelling the leased slot through a symlinked pool still
      # names that slot.
      ln -s "$CASE_DIR/pool" "$CASE_DIR/pool-alias"
      printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"holder","lease_id":"0123456789abcdef0123456789abcdef"},{"name":"2","path":"%s"}]}\n' \
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
  for mode in status pool-dir status-unproven; do
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
  capabilities)
    [ -e "$CASE_DIR/proven" ] || exit 3
    jq -cn --arg h "$PROTECTED_HOLDER" '{schema_version:2,version:"v-fake",persistent_recovered_leases:true,recovered_quarantine_holder:\$h}'
    ;;
  status) printf 'status\n' >> "$CASE_DIR/status-calls"; [ ! -f "$CASE_DIR/status.json" ] || cat "$CASE_DIR/status.json" ;;
esac
exit 0
SH
    chmod +x "$FAKEBIN_DIR/treehouse"
    # A treehouse without pool-dir is placed through its status listing, a state-lock
    # command an unproven provider answers with its own recovery: only a provider that
    # proved the capability may be asked (status), and an unproven one is refused with
    # no status call (status-unproven).
    [ "$mode" != status ] || : > "$CASE_DIR/proven"
    if [ "$mode" = status-unproven ]; then
      printf '[{"name":"1","path":"%s"}]\n' "$current" > "$CASE_DIR/status.json"
      PANE_DIR=$SLOT_DIR
      : > "$CASE_DIR/pane-log"
      : > "$CASE_DIR/launch-log"
      assert_retained_refusal "$name" "contains task holder's current copy" "Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true"
      [ ! -e "$CASE_DIR/status-calls" ] || fail "$mode: the unproven guard read a status listing"
      continue
    fi
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
      entry=',"leased":true,"lease_holder":"sm","lease_id":"0123456789abcdef0123456789abcdef"'
    else
      entry=$(printf ',"leased":true,"lease_holder":"%s"' "$recovered")
    fi
    add_free_second_slot "$entry"
    cp "$sm_home/state/foreign.meta" "$CASE_DIR/before-meta"
    git -C "$NESTED_COPY" rev-parse HEAD > "$CASE_DIR/before-head"
    if [ "$lease" = recovered ]; then
      # A home slot on the recovered holder gets no exemption from the capability
      # proof (Main 1738): on a provider that did not prove it the guard refuses.
      install_capability_treehouse failing
      cp "$CASE_DIR/pool/treehouse-state.json" "$CASE_DIR/before-state"
      assert_retained_refusal "$name" "carries Treehouse's recovered-state lease" \
        "Upgrade treehouse to a build whose 'treehouse capabilities --json' reports persistent_recovered_leases: true" "treehouse lease '"
      assert_only_capability_probes "$lease"
      cmp -s "$CASE_DIR/before-meta" "$sm_home/state/foreign.meta" || fail "$lease: the refusal changed the foreign record"
      continue
    fi
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
  pass "an ordinary leased secondmate home slot holding another project's task copy does not stop a spawn, and a recovered one gets no exemption on an unproven provider"
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
test_unproven_provider_admits_only_ordinary_leases
test_unproved_fresh_read_and_blank_version_are_refused
test_unproven_allocation_runs_no_status_to_place_a_slot
test_missing_state_file_in_a_pool_slot_refuses_and_plain_checkouts_spawn
test_missing_state_slot_under_a_dot_treehouse_path_refuses
test_retained_fingerprint_sees_the_nested_copy_head
test_lease_entry_oracle_checks_every_field
test_fixture_provider_gets_name_a_root
test_forged_capability_holder_cannot_collapse_to_the_old_literal
test_recovered_slot_allows_allocation_with_proven_capability
test_proven_capability_does_not_relax_other_refusals
test_old_holder_is_adopted_and_old_session_exit_cannot_sweep
test_unadopted_old_holder_refuses_and_adoption_runs_once
test_home_seed_guard_follows_the_protected_holder
test_combined_rollout_keeps_recovered_and_new_copies
test_spawn_runs_its_own_get_and_takes_the_slot_that_command_chose
test_real_provider_recovered_slot_allows_free_slot_allocation
test_nested_copy_in_leased_slot_allows_allocation
test_nested_copy_in_superseded_slot_allows_allocation
test_secondmate_home_slot_with_other_project_copy_allows_allocation
test_slot_left_by_reassociated_task_is_allocatable
test_unreadable_local_home_warns_and_proceeds
