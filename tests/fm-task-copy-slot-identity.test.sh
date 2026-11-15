#!/usr/bin/env bash
# Helper-level coverage for the shared Treehouse lease scan and slot identity in
# bin/fm-task-copy-lib.sh (Main 1864 R-B, R-C and F3): a failed lease scan is unreadable
# everywhere, lease holders compare as raw values (never as @tsv text), and a path is a
# pool slot only by positive proof. The tests source the library and call its functions
# with a stub treehouse; no spawn, teardown, provider or long-lived process runs, so the
# file is safe under the host test limit. Usage: bash tests/fm-task-copy-slot-identity.test.sh

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-copy-slot-identity)
fm_git_identity fmtest fmtest@example.invalid

# Round 6 (Main 1864): class-level helper tests for the shared lease scan and slot identity.
# They source bin/fm-task-copy-lib.sh and call its functions; no spawn, teardown or provider runs.
r6_lease_state() {  # <dir> <jq-object-array-body>; writes <dir>/pool/treehouse-state.json
  mkdir -p "$1/pool/1/project"
  printf '{"worktrees":[%s]}\n' "$2" > "$1/pool/treehouse-state.json"
}

test_a_failed_lease_scan_is_unreadable_everywhere() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local dir slot name body want_state rc got bad=
  command -v jq >/dev/null 2>&1 || fail "the lease scan checks require jq"
  FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER='recovered: old'
  FM_TASK_COPY_RECOVERED_QUARANTINE_HOLDER='quarantined: p'
  # name|entries|expected state
  while IFS='|' read -r name body want_state; do
    dir="$TMP_ROOT/r6-scan-$name"
    rm -rf "$dir"
    slot="$dir/pool/1/project"
    body=${body//SLOT/$slot}
    r6_lease_state "$dir" "$body"
    rc=0
    fm_task_copy_pool_slot_lease "$slot" || rc=$?
    got="$FM_TASK_COPY_LEASE_STATE|$FM_TASK_COPY_LEASE_HOLDER|$FM_TASK_COPY_LEASE_ID|$FM_TASK_COPY_LEASE_NAME"
    case "$want_state" in
      unreadable)
        [ "$got" = 'unreadable|||' ] || bad="$bad"$'\n'"$name: a failed scan left '$got', expected 'unreadable|||'"
        [ "$rc" != 0 ] || bad="$bad"$'\n'"$name: a failed scan returned success"
        ;;
      ordinary)
        [ "$got" = 'ordinary|h1|i1|1' ] || bad="$bad"$'\n'"$name: the valid control read '$got'"
        [ "$rc" = 0 ] || bad="$bad"$'\n'"$name: the valid control returned $rc"
        ;;
      unleased)
        [ "$FM_TASK_COPY_LEASE_STATE" = unleased ] || bad="$bad"$'\n'"$name: the unleased control read '$got'"
        ;;
    esac
  done <<'CASES'
control-leased|{"name":"1","path":"SLOT","leased":true,"lease_holder":"h1","lease_id":"i1"}|ordinary
control-unleased|{"name":"1","path":"SLOT","leased":false}|unleased
bad-path-after-target|{"name":"1","path":"SLOT","leased":true,"lease_holder":"h1","lease_id":"i1"},{"name":"2","path":"relative/slot","leased":false}|unreadable
bad-path-before-target|{"name":"2","path":"relative/slot","leased":false},{"name":"1","path":"SLOT","leased":true,"lease_holder":"h1","lease_id":"i1"}|unreadable
escaped-path-after-target|{"name":"1","path":"SLOT","leased":true,"lease_holder":"h1","lease_id":"i1"},{"name":"2","path":"/x/a\\b","leased":false}|unreadable
unleased-target-bad-after|{"name":"1","path":"SLOT","leased":false},{"name":"2","path":"relative/slot","leased":true}|unreadable
CASES
  [ -z "$bad" ] || fail "a lease scan that failed left a partial value:$bad"
  pass 'a lease scan that fails anywhere (a relative or escaped path before or after the target entry) ends unreadable with every value cleared and a failing status, and valid leased and unleased scans are unchanged'
)

test_lease_holders_compare_raw_never_tsv_escaped() (
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local dir slot one two tab case_name state_holder cap_holder want got
  command -v jq >/dev/null 2>&1 || fail "the holder checks require jq"
  one=$'a\\b'
  two=$'a\\\\b'
  tab=$'a\tb'
  FM_TASK_COPY_TREEHOUSE_RECOVERED_HOLDER='recovered: old'
  # name|state holder|capability holder|expected state
  for case_name in one-vs-two two-vs-one one-vs-one two-vs-two tab-vs-escaped-text tab-vs-tab; do
    case "$case_name" in
      one-vs-two) state_holder=$one cap_holder=$two want=ordinary ;;
      two-vs-one) state_holder=$two cap_holder=$one want=ordinary ;;
      one-vs-one) state_holder=$one cap_holder=$one want=recovered ;;
      two-vs-two) state_holder=$two cap_holder=$two want=recovered ;;
      tab-vs-escaped-text) state_holder=$tab cap_holder='a\tb' want=ordinary ;;
      tab-vs-tab) state_holder=$tab cap_holder=$tab want=recovered ;;
    esac
    dir="$TMP_ROOT/r6-holder-$case_name"
    rm -rf "$dir"
    slot="$dir/pool/1/project"
    mkdir -p "$slot"
    command jq -cn --arg p "$slot" --arg h "$state_holder" '{worktrees:[{name:"1",path:$p,leased:true,lease_holder:$h,lease_id:"i1"}]}' > "$dir/pool/treehouse-state.json"
    FM_TASK_COPY_RECOVERED_QUARANTINE_HOLDER=$cap_holder
    fm_task_copy_pool_slot_lease "$slot" || true
    got=$FM_TASK_COPY_LEASE_STATE
    [ "$got" = "$want" ] || fail "$case_name: the lease read as '$got', expected '$want' (the holders differ or match as raw values, not as @tsv text)"
    [ "$FM_TASK_COPY_LEASE_HOLDER" = "$state_holder" ] || fail "$case_name: the holder read back as '$FM_TASK_COPY_LEASE_HOLDER', not the raw '$state_holder'"
  done
  pass 'lease holders compare as raw values: one backslash and two backslashes never match through their @tsv text, equal backslash and tab holders match, and the holder read back is the stored value'
)

# A path is a pool slot only by positive proof (Main 1864 R-C). A real git layout: a project,
# a linked worktree as the slot, a linked copy nested in it, and the guard called directly.
r6_slot_case() {  # <name> <layout: custom|home> <pool-dir: fails|self|other>; prints the guard's exit
  local name=$1 layout=$2 pooldir=$3 dir project slot copy statedir home
  dir="$TMP_ROOT/r6-slot-$name"
  rm -rf "$dir"
  mkdir -p "$dir/state"
  if [ "$layout" = home ]; then
    # a Firstmate home that is itself a Treehouse slot, holding a project clone
    home="$dir/.treehouse/9/home"
    mkdir -p "$home/projects"
    git init -q "$home"
    project="$home/projects/proj"
  else
    project="$dir/project"
  fi
  git init -q "$project"
  git -C "$project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  if [ "$layout" = home ]; then
    slot=$project
    copy="$project/nested"
  else
    slot="$dir/custom-pool/1/project"
    mkdir -p "$dir/custom-pool/1"
    git -C "$project" worktree add -q -b slot-branch "$slot"
    copy="$slot/nested"
  fi
  git -C "$project" worktree add -q -b copy-branch "$copy"
  printf 'worktree=%s\n' "$copy" > "$dir/state/task-x1.meta"
  (
    set -u
    # shellcheck source=bin/fm-task-copy-lib.sh
    . "$ROOT/bin/fm-task-copy-lib.sh"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$ROOT/bin/fm-wake-lib.sh"
    # r6* names: the library's own functions declare locals such as dir and project, which a
    # stub would otherwise read in place of the case's values (dynamic scope).
    r6dir=$dir r6pooldir=$pooldir
    statedir="$r6dir/state"
    fm_local_firstmate_state_dirs() { FM_LOCAL_FIRSTMATE_STATES=("$statedir"); FM_LOCAL_FIRSTMATE_SKIPPED=(); }
    fm_meta_get() { sed -n "s/^$2=//p" "$1" | head -1; }
    treehouse() {
      case "${1-}" in
        pool-dir)
          case "$r6pooldir" in
            fails) return 1 ;;
            self) mkdir -p "$r6dir/custom-pool"; printf '%s\n' "$r6dir/custom-pool" ;;
            other) mkdir -p "$r6dir/other-pool"; printf '%s\n' "$r6dir/other-pool" ;;
          esac ;;
        capabilities) return 1 ;;
        *) echo "FORBIDDEN $*" >> "$r6dir/forbidden"; return 1 ;;
      esac
    }
    rc=0
    fm_task_copy_pool_slots_hold_no_current_copy "$project" "$statedir" > "$r6dir/out" 2> "$r6dir/err" || rc=$?
    echo "$rc"
  )
}

test_slot_identity_needs_positive_proof() {
  local rc dir
  # a linked worktree with no state file, `treehouse pool-dir` unable to name a pool (an old
  # provider, a custom root): its slot status cannot be proved, so it refuses
  rc=$(r6_slot_case custom-unproven custom fails)
  [ "$rc" != 0 ] || fail "a linked worktree with a missing state file and no pool-dir proof was admitted (custom root)"
  dir="$TMP_ROOT/r6-slot-custom-unproven"
  assert_not_contains "$(cat "$dir/err")" 'treehouse status' "the refusal for an unproven provider still suggests a treehouse status"
  [ ! -e "$dir/forbidden" ] || fail "the guard ran a treehouse command it must not run: $(cat "$dir/forbidden")"
  # pool-dir names this very pool: a slot, refuses
  rc=$(r6_slot_case custom-named custom self)
  [ "$rc" != 0 ] || fail "a worktree inside the pool pool-dir names was admitted with its state file missing: $(cat "$TMP_ROOT/r6-slot-custom-named/err" "$TMP_ROOT/r6-slot-custom-named/out" 2>&1)"
  # pool-dir names another pool and no .treehouse marks this one: proved not a slot, admits
  rc=$(r6_slot_case custom-elsewhere custom other)
  [ "$rc" = 0 ] || fail "a linked worktree that pool-dir proves is outside the project's pool was refused"
  # a project clone inside a Treehouse-backed home is not a slot, with or without pool-dir
  rc=$(r6_slot_case home-failing home fails)
  [ "$rc" = 0 ] || fail "a project clone inside a Treehouse-backed Firstmate home was refused as a slot (pool-dir failing)"
  rc=$(r6_slot_case home-other home other)
  [ "$rc" = 0 ] || fail "a project clone inside a Treehouse-backed Firstmate home was refused as a slot (pool-dir naming another pool)"
  pass 'a missing-state path is a slot only by positive proof: an unprovable linked worktree (custom root, no pool-dir) refuses without suggesting a status, a worktree pool-dir proves outside the pool admits, and a project clone inside a Treehouse-backed home is never taken for a slot'
}


# The first case to fail ends the file with a nonzero status (fm_test_run_cases), also for
# the cases above that run in a subshell.
fm_test_run_cases \
  test_a_failed_lease_scan_is_unreadable_everywhere \
  test_lease_holders_compare_raw_never_tsv_escaped \
  test_slot_identity_needs_positive_proof \
  -- "$@"

echo '# all fm-task-copy-slot-identity tests passed'
