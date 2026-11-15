#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin tip, launches a clean origin-less
# pool as-is, or stops when a configured origin is unusable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)
# Every spawn in this file runs with its detached home-summary refresh stubbed (tests/fixtures.sh fm_test_spawn_script).
export FM_TEST_STUB_SUMMARY_REFRESH=1

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

# A copy the slot rules skip is left as found and another is requested; this fake world has no other
# copy, so the acquisition wait must reach its no-progress limit. The clock below advances SECONDS
# by a minute per one-second sleep, so that wait ends at once and the refusal is what the case reads.
SKIP_CLOCK="$TMP_ROOT/skip-clock.sh"
cat > "$SKIP_CLOCK" <<'SH'
sleep() {
  if [ "${1:-}" = 1 ] && [ -n "${FM_TEST_TICK_SECONDS:-}" ]; then
    SECONDS=$((SECONDS + FM_TEST_TICK_SECONDS))
  fi
  command sleep "$@"
}
# The spawn creates its task data folder while it records a skipped copy, between two gets. A jump there spends the
# bound after one copy was accepted and before the next get is typed.
mkdir() {
  if [ -n "${FM_TEST_MKDIR_JUMP_PATH:-}" ] && [ "${2:-}" = "$FM_TEST_MKDIR_JUMP_PATH" ]; then
    SECONDS=$((SECONDS + ${FM_TEST_MKDIR_JUMP:-0}))
  fi
  command mkdir "$@"
}
# A clock jump at the moment a copy is about to be accepted: the spawn's own DEBUG hook sets SECONDS to
# <spawn start> + FM_TEST_JUMP_AT_ACCEPT on the second pass over the line that reads the accepted copy's real path
# (the pass that would accept it). Nothing in the spawn is changed to make this possible.
__fm_accept_seen=0
__fm_clock_jump() {
  case "$BASH_COMMAND" in
    'p_real=$(real_path_or_raw "$p")')
      __fm_accept_seen=$((__fm_accept_seen + 1))
      if [ "$__fm_accept_seen" = 2 ] && [ -n "${SPAWN_ACQUIRE_T0:-}" ]; then
        SECONDS=$((SPAWN_ACQUIRE_T0 + FM_TEST_JUMP_AT_ACCEPT))
      fi ;;
  esac
  return 0
}
if [ -n "${FM_TEST_JUMP_AT_ACCEPT:-}" ]; then
  set -T
  trap '__fm_clock_jump' DEBUG
fi
SH

run_spawn_skipping() {
  FM_TEST_TICK_SECONDS=60 BASH_ENV="$SKIP_CLOCK" run_spawn "$@"
}

test_remote_seeded_home_spawns_from_treehouse_pool() {
  local rec id out status lock
  id='pool-remote-seeded-r13'
  rec=$(make_case remote-seeded "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=parent-machine
REC

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" \
    "a remote-seeded secondmate home should allocate and launch from its Treehouse pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" \
    "the remote-seeded spawn did not report success"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the remote-seeded spawn did not publish its allocated pool worktree"
  lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") \
    || fail "the launched remote-seeded home could not resolve its Treehouse project lock"
  case "$lock" in
    "$HOME_DIR/state/"*) ;;
    *) fail "the remote-seeded spawn anchored its lock outside its local root: $lock" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse spawn command\n'
    printf '$ FM_HOME=%s bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' \
      "$HOME_DIR" "$id" "$PROJECT_DIR" "$out" "$status"
    printf 'published worktree=%s\nresolved project lock=%s\n' "$POOL_DIR" "$lock"
  fi
  pass "a remote-seeded secondmate home allocates and launches from its Treehouse pool"
}

test_linked_spawning_home_rejects_primary_before_refresh() {
  local rec id out status returned primary spawning before_reflog clock
  for returned in primary primary-alias spawning scout; do
    id="pool-linked-${returned}-r12"
    rec=$(make_case "linked-$returned" "$id")
    read_case_record "$rec"
    primary=$PROJECT_DIR
    spawning="$CASE_DIR/secondmate"
    git -C "$primary" worktree add --quiet --detach "$spawning" HEAD
    PROJECT_DIR=$spawning
    case "$returned" in
      primary) POOL_DIR=$primary ;;
      primary-alias)
        ln -s "$primary" "$CASE_DIR/primary-alias"
        POOL_DIR="$CASE_DIR/primary-alias"
        ;;
      spawning) POOL_DIR=$spawning ;;
    esac
    before_reflog=$(git -C "$primary" reflog)
    # The assertion concerns identity, not how long an unchanged cwd is polled.
    # The refusal cases must reach the ten-minute no-progress limit, which counts
    # shell seconds, so they advance that clock a minute per poll. The scout case
    # must arrive and keeps the real clock.
    fm_test_fake_sleep_noop "$FAKEBIN_DIR"
    clock=
    if [ "$returned" != scout ]; then
      clock="$TMP_ROOT/clock.sh"
      cat > "$clock" <<'SH'
sleep() {
  if [ "${1:-}" = 1 ]; then SECONDS=$((SECONDS + 60)); fi
  command sleep "$@"
}
SH
    fi

    out=$(BASH_ENV="$clock" run_spawn "$id" --scout)
    status=$?
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: linked-home spawn, returned=%s\n' "$returned"
      printf '$ bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' "$id" "$PROJECT_DIR" "$out" "$status"
      printf 'primary HEAD before=%s after=%s\n' "$INITIAL_SHA" "$(git -C "$primary" rev-parse HEAD)"
      printf 'primary reflog before:\n%s\nprimary reflog after:\n%s\n' "$before_reflog" "$(git -C "$primary" reflog)"
      if [ -e "$primary/.git/FETCH_HEAD" ]; then
        printf 'FETCH_HEAD:\n'; cat "$primary/.git/FETCH_HEAD"
      else
        printf 'FETCH_HEAD absent\n'
      fi
      if [ -e "$HOME_DIR/state/$id.meta" ]; then
        printf 'saved task metadata:\n'; cat "$HOME_DIR/state/$id.meta"
        printf 'worker HEAD=%s origin/main=%s\n' "$(git -C "$POOL_DIR" rev-parse HEAD)" "$(git -C "$POOL_DIR" rev-parse origin/main)"
      else
        printf 'task metadata absent\n'
      fi
      printf '# evidence end\n'
    fi
    if [ "$returned" = scout ]; then
      expect_code 0 "$status" "a genuine scout copy from a linked home should launch"$'\n'"$out"
      assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
        "spawn did not record the genuine scout copy"
      [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
        || fail "spawn did not refresh the genuine scout copy"
    else
      [ "$status" -ne 0 ] || fail "linked spawning home accepted $returned as a disposable copy"
      # None of these is an isolated copy, so the worktree poll never adopts one
      # and the wait runs out instead: the spawning directory fails the poll's
      # own project comparison, and the repository primary (named directly or
      # through a symlink) fails the isolation screen the poll shares with the
      # guard. The refusal names the last path the pane reported.
      assert_contains "$out" "did not enter an isolated worktree" \
        "spawn did not explain its isolation refusal"
      assert_contains "$out" "last seen" "refusal did not name the path the pane reported"
      [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
      [ ! -e "$primary/.git/FETCH_HEAD" ] || fail "refused spawn fetched before proving isolation"
    fi
    [ "$(git -C "$primary" rev-parse HEAD)" = "$INITIAL_SHA" ] \
      || fail "spawn reset the repository primary from a linked home"
    [ "$(git -C "$primary" reflog)" = "$before_reflog" ] \
      || fail "spawn touched the primary reflog from a linked home"
    pass "linked spawning home: $returned preserves the primary before any refresh"
  done
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

make_originless_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|main"
}

test_originless_pool_launches_without_a_freshness_fetch() {
  local rec id out status before
  id='pool-originless-r6'
  rec=$(make_originless_case originless "$id")
  read_case_record "$rec"
  ! git -C "$POOL_DIR" remote get-url origin >/dev/null 2>&1 \
    || fail "fixture unexpectedly configured an origin remote"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch a local-only pooled worktree with no origin"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the origin-less pool"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn attempted a freshness fetch against a nonexistent origin"
  [ ! -e "$POOL_DIR/.git/FETCH_HEAD" ] || fail "spawn fetched against a pooled worktree with no origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD on an origin-less pooled worktree that had nothing to refresh against"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed origin-less launch: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an origin-less pooled worktree launches as-is, skipping the freshness gate"
}

test_originless_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-originless-dirty-r1'
  rec=$(make_originless_case originless-dirty "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty origin-less pooled worktree"
  assert_contains "$out" "is not clean" \
    "spawn did not clearly refuse a dirty origin-less pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty origin-less pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded local work from an origin-less pool"
  pass "a dirty origin-less pooled worktree is refused without discarding its local work"
}

test_origin_config_without_url_refuses_pool() {
  local rec id out status before
  id='pool-origin-without-url-r1'
  rec=$(make_originless_case origin-without-url "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an origin configuration with no URL"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an origin configuration with no URL as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an unusable origin configuration"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an origin configuration without a URL refuses the pooled worktree"
}

test_empty_origin_config_section_refuses_pool() {
  local rec id out status before config
  id='pool-empty-origin-section-r1'
  rec=$(make_originless_case empty-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  printf '\n[remote "origin"]\n' >> "$config"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an empty origin configuration section"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an empty origin configuration section as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an empty origin configuration section"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an empty origin configuration section refuses the pooled worktree"
}

test_empty_only_included_origin_config_section_launches_pool() {
  local rec id out status before config included
  id='pool-empty-only-included-origin-section-r1'
  rec=$(make_originless_case empty-only-included-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/empty-origin.inc
  printf '[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config include.path "$(basename "$included")"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should proceed when an included empty origin section is not enumerable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the undetectable included section"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn treated an undetectable included empty section as a configured origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite treating the included empty section as origin-less"
  pass "an empty-only included origin section documents the accepted detection boundary"
}

test_inactive_conditional_origin_include_launches_pool() {
  local rec id out status before config included
  id='pool-inactive-origin-include-r1'
  rec=$(make_originless_case inactive-origin-include "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/inactive-origin.inc
  printf '[fm-test]\n\tmarker = true\n[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config 'includeIf.gitdir:/never/matches/this/worktree/.path' "$included"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should ignore an inactive conditional origin include"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success with an inactive origin include"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite having no effective origin"
  pass "an inactive conditional origin include leaves the pooled worktree origin-less"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

# A slot left on a stale submodule pin is the field failure this diagnosis exists
# for: a refresh moved the superproject and left the submodule behind, so the
# refusal fires a spawn later, on a slot whose own `git status` looks clean to the
# operator. Nothing here is converged - the gate only has to say why. The fixture
# only builds the repositories; the residue itself is produced by a real spawn, so
# these tests cover the reset that actually strands the submodule.
make_submodule_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin sub subpin1 subpin2 advanced
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  sub="$case_dir/sub-origin"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$sub"
  printf 'pin one\n' > "$sub/lib.txt"
  git -C "$sub" add lib.txt
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sub-one
  subpin1=$(git -C "$sub" rev-parse HEAD)
  printf 'pin two\n' > "$sub/lib.txt"
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam sub-two
  subpin2=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" checkout --quiet "$subpin1"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c protocol.file.allow=always -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    submodule --quiet add "file://$sub" ui
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  git -C "$pool" -c protocol.file.allow=always submodule --quiet update --init

  # Advance origin and move the submodule pin, exactly as the field incident did.
  git clone --quiet "file://$origin" "$publisher"
  git -C "$publisher" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$publisher/ui" checkout --quiet "$subpin2"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam advance-pin
  git -C "$publisher" push --quiet origin main
  advanced=$(git -C "$publisher" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$subpin1|$subpin2|$advanced"
}

read_submodule_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR SUBPIN1 SUBPIN2 ADVANCED_SHA <<EOF
$1
EOF
}

# The first of two consecutive spawns: it succeeds, resets the superproject onto
# the base that moved the pin, and leaves the submodule checkout on the pin the
# old base recorded. That reset is what strands the slot, so every case below
# starts from residue this code path actually produced rather than a hand-built one.
strand_submodule_pin_via_spawn() {  # <seed-id>
  local id=$1 out status
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the spawn that moves the submodule pin should succeed"
  assert_contains "$out" "spawned $id" "the spawn that moves the submodule pin did not report success"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ADVANCED_SHA" ] \
    || fail "the first spawn did not move the pooled base across the moved submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN1" ] \
    || fail "the first spawn did not strand the submodule on the pin the old base recorded"
}

test_stale_submodule_pin_explains_itself() {
  local rec id out status before before_sub
  id='pool-stale-pin-r7'
  rec=$(make_submodule_case stale-pin "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-stale-pin-seed-r7'
  git -C "$POOL_DIR" remote remove origin
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$(git -C "$POOL_DIR/ui" rev-parse HEAD)

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the second spawn launched from a slot carrying a stale submodule pin"
  assert_contains "$out" "stale submodule checkout" \
    "refusal did not name the cause as a stale submodule checkout"
  assert_contains "$out" "submodule 'ui'" "refusal did not name the submodule"
  assert_contains "$out" "$SUBPIN1" "refusal did not report the pin the slot actually has"
  assert_contains "$out" "$SUBPIN2" "refusal did not report the pin the base records"
  # No remedy is printed on purpose: the containment check reads local refs only,
  # so a stale remote-tracking ref can make an unpushed commit look contained, and
  # a checkout command on that judgement could cost the operator a commit.
  assert_not_contains "$out" "submodule update --checkout" \
    "refusal printed a remedy command the containment check cannot stand behind"
  assert_not_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin was misreported as uncommitted work"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a stale submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn converged the submodule; this gate must never touch the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-pin refusal: %s\n' "$(printf '%s\n' "$out" | grep 'submodule' | head -n 1)"
  fi
  pass "an origin-less pool with a stale submodule pin refuses while naming both pins and no remedy"
}

test_unpushed_submodule_commit_is_still_uncommitted_work() {
  local rec id out status unpushed before before_sub
  id='pool-sub-unpushed-r10'
  rec=$(make_submodule_case sub-unpushed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-unpushed-seed-r10'
  # A commit made inside the submodule and never pushed leaves the submodule work
  # tree clean and the pins different - the same two facts a stale pin shows. Any
  # checkout of the recorded pin would move HEAD off this commit and leave it
  # unreferenced, so this case must keep the conservative refusal.
  printf 'unlanded submodule work\n' > "$POOL_DIR/ui/unlanded.txt"
  git -C "$POOL_DIR/ui" add unlanded.txt
  git -C "$POOL_DIR/ui" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm unlanded-submodule-work
  unpushed=$(git -C "$POOL_DIR/ui" rev-parse HEAD)
  [ -z "$(git -C "$POOL_DIR/ui" status --porcelain)" ] \
    || fail "fixture did not leave the submodule work tree clean"
  [ "$unpushed" != "$(git -C "$POOL_DIR" rev-parse "HEAD:ui")" ] \
    || fail "fixture did not leave the recorded pin different from what is checked out"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$unpushed

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding an unpushed submodule commit"
  assert_contains "$out" "holds uncommitted work" \
    "an unpushed submodule commit was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "an unpushed submodule commit was misreported as a stale pin"
  assert_not_contains "$out" "is checked out at" \
    "an unpushed submodule commit still drew the stale-pin diagnosis"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn moved the submodule off its unpushed commit"
  git -C "$POOL_DIR/ui" cat-file -e "$unpushed^{commit}" \
    || fail "the unpushed submodule commit did not survive the refusal"
  assert_grep 'unlanded submodule work' "$POOL_DIR/ui/unlanded.txt" \
    "spawn discarded the unpushed submodule work while refusing the pool"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a slot holding an unpushed submodule commit"
  pass "an unpushed submodule commit keeps the uncommitted-work refusal and survives it"
}

test_work_inside_submodule_is_still_uncommitted_work() {
  local rec id out status
  id='pool-sub-work-r8'
  rec=$(make_submodule_case sub-work "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-work-seed-r8'
  # Put the submodule back on the pin the base records, so the ONLY deviation is
  # real work inside it. This must never be softened into a stale-pin diagnosis.
  git -C "$POOL_DIR/ui" checkout --quiet "$SUBPIN2"
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding work inside a submodule"
  assert_contains "$out" "holds uncommitted work" \
    "work inside a submodule was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "real work inside a submodule was misreported as a stale pin"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "work inside a submodule is still refused as uncommitted work, not called stale"
}

test_stale_pin_carrying_real_work_is_not_called_stale() {
  local rec id out status
  id='pool-sub-both-r9'
  rec=$(make_submodule_case sub-both "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-both-seed-r9'
  # Stale pin AND real work inside it: calling this merely stale would be wrong, so
  # the refusal must stay the conservative one.
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin and work inside it"
  assert_contains "$out" "holds uncommitted work" \
    "a stale pin carrying real work was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a submodule holding real work was reported as merely stale"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "a stale pin carrying real work is refused conservatively, never called stale"
}

test_stale_pin_beside_other_dirt_reports_one_verdict() {
  local rec id out status
  id='pool-sub-mixed-r11'
  rec=$(make_submodule_case sub-mixed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-mixed-seed-r11'
  # Git sorts status paths, so the stale 'ui' entry is scanned before this file.
  # The conservative verdict must not arrive contradicted by a stale-pin line.
  printf 'notes the operator still wants\n' > "$POOL_DIR/zz-notes.txt"

  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin beside an untracked file"
  assert_contains "$out" "holds uncommitted work" \
    "a stale pin beside an untracked file was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a slot carrying more than a stale pin was reported as merely stale"
  assert_not_contains "$out" "is checked out at" \
    "the stale-pin diagnosis was printed alongside the conservative refusal"
  assert_grep 'notes the operator still wants' "$POOL_DIR/zz-notes.txt" \
    "spawn discarded the untracked file while refusing the pool"
  pass "a stale pin beside other dirt yields the conservative refusal alone, with no stale-pin line"
}

# Re-lay a case's pooled worktree as a managed Treehouse slot: <pool>/<slot>/<repo>
# with the pool's state file beside the slot, which is the shape fm-spawn claims
# for its task. Rewrites POOL_DIR to the relocated checkout.
lay_out_as_pool_slot() {
  local slot_root="$CASE_DIR/slots"
  mkdir -p "$slot_root/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$slot_root/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_root/1/project" \
    > "$slot_root/treehouse-state.json"
  POOL_DIR="$slot_root/1/project"
  SLOT_CLAIM="$slot_root/1/.fm-slot-owner"
}

# The spawn side of the slot-owner claim that bin/fm-teardown.sh later reads:
# a launched task's claim names it, a slot that cannot be claimed refuses before
# anything is published, and an abort while the allocation lock is still held
# leaves no claim naming a task with no record.
test_pool_slot_claim_follows_the_spawn_outcome() {
  local rec id out status before

  id='pool-slot-claim-r1'
  rec=$(make_case slot-claim "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn from a Treehouse slot should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not publish the relocated slot as its worktree"
  [ -f "$SLOT_CLAIM" ] || fail "spawn left its Treehouse slot unclaimed: $out"
  grep -Fxq -- "task=$id" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawned task: $(cat "$SLOT_CLAIM")"
  grep -Fxq -- "home=$HOME_DIR" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawning home: $(cat "$SLOT_CLAIM")"

  id='pool-slot-unclaimable-r1'
  rec=$(make_case slot-unclaimable "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mkdir -p "$SLOT_CLAIM"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  out=$(run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker on a slot it could not claim"
  assert_contains "$out" "could not claim Treehouse pool slot" \
    "spawn did not name the unclaimable slot as the reason"
  [ -d "$SLOT_CLAIM" ] || fail "spawn replaced the directory blocking its slot claim"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn published a record for an unclaimable slot"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the slot's HEAD after failing to claim it"

  id='pool-slot-claim-aborted-r1'
  rec=$(make_originless_case slot-claim-aborted "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unusable origin on the slot"
  assert_contains "$out" "could not fetch origin" \
    "the aborted spawn did not refuse on its unusable origin"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the aborted spawn published task metadata"
  [ ! -e "$SLOT_CLAIM" ] && [ ! -L "$SLOT_CLAIM" ] \
    || fail "the aborted spawn left a slot claim naming a task with no record: $(cat "$SLOT_CLAIM")"
  pass "a Treehouse slot claim names the launched task, refuses when unclaimable, and is dropped by a locked abort"
}

publish_feature_branch() { # <branch>
  git -C "$CASE_DIR/publisher" checkout --quiet -b "$1"
  printf 'only on %s\n' "$1" > "$CASE_DIR/publisher/feature-only.txt"
  git -C "$CASE_DIR/publisher" add feature-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature
  git -C "$CASE_DIR/publisher" push --quiet origin "$1"
}

brief_with_base() { # <id> <base> [<intent>]
  fm_test_spawn_brief "$HOME_DIR" "$1" ${3:+"$3"}
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: %s\n' "$2" >> "$HOME_DIR/data/$1/brief.md"
}

test_named_base_branch_starts_from_that_branch() {
  local rec id out status kind
  for kind in ship scout; do
    id="pool-named-base-$kind-r1"
    rec=$(make_case "named-base-$kind" "$id")
    read_case_record "$rec"
    publish_feature_branch feature/hub
    brief_with_base "$id" feature/hub
    if [ "$kind" = ship ]; then
      out=$(run_spawn "$id" --mode direct-PR --yolo off --base-branch feature/hub)
    else
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
    fi
    status=$?
    expect_code 0 "$status" "a $kind spawn with a matching base branch should launch"$'\n'"$out"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/feature/hub)" ] \
      || fail "the $kind copy did not start from origin/feature/hub"
    assert_grep 'only on feature/hub' "$POOL_DIR/feature-only.txt" \
      "the $kind copy is missing the base branch content"
    assert_grep 'base_branch=feature/hub' "$HOME_DIR/state/$id.meta" \
      "the $kind spawn did not record its base branch"
  done

  id='pool-named-base-missing-r1'
  rec=$(make_case named-base-missing "$id")
  read_case_record "$rec"
  brief_with_base "$id" feature/missing
  out=$(run_spawn "$id" --scout --base-branch feature/missing)
  status=$?
  [ "$status" -ne 0 ] || fail "a base branch origin lacks should refuse the spawn"
  assert_contains "$out" "origin/feature/missing" "the refusal did not name the missing base"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused base-branch spawn published task metadata"

  id='pool-named-base-local-only-r1'
  rec=$(make_case named-base-local-only "$id")
  read_case_record "$rec"
  brief_with_base "$id" feature/hub
  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch feature/hub)
  status=$?
  [ "$status" -ne 0 ] || fail "a base branch on a local-only ship should refuse the spawn"
  assert_contains "$out" "mode=local-only" "the local-only refusal did not explain itself"
  pass "--base-branch picks the copy's starting point and is recorded; a missing or local-only base refuses"
}

test_base_branch_must_agree_with_the_brief() {
  local rec id out status case_name
  for case_name in flag-only line-only task-decoy; do
    id="pool-base-agree-$case_name-r1"
    rec=$(make_case "base-agree-$case_name" "$id")
    read_case_record "$rec"
    publish_feature_branch feature/hub
    case "$case_name" in
    flag-only)
      fm_test_spawn_brief "$HOME_DIR" "$id"
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
      ;;
    line-only)
      brief_with_base "$id" feature/hub
      out=$(run_spawn "$id" --scout)
      ;;
    task-decoy)
      brief_with_base "$id" feature/hub $'You are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: decoy'
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
      ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "a $case_name base-branch disagreement should refuse the spawn"
    assert_contains "$out" "Base branch" "the $case_name refusal did not name the Base branch line"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused $case_name spawn published task metadata"
  done
  pass "a spawn refuses when --base-branch and the brief's Base branch lines disagree"
}

# A Base branch line quoted in the captain's intent is prose: it neither blocks
# a spawn nor redirects it.
test_prose_base_branch_line_is_ignored() {
  local rec id out status
  id='pool-base-prose-none-r1'
  rec=$(make_case base-prose-none "$id")
  read_case_record "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" $'Fix the release.\nBase branch: release/1.2'
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a no-base brief quoting a Base branch line should launch"$'\n'"$out"
  assert_no_grep 'base_branch=' "$HOME_DIR/state/$id.meta" "prose recorded a base branch"

  id='pool-base-prose-flag-r1'
  rec=$(make_case base-prose-flag "$id")
  read_case_record "$rec"
  publish_feature_branch feature/hub
  brief_with_base "$id" feature/hub $'Fix the release.\nBase branch: release/1.2'
  out=$(run_spawn "$id" --scout --base-branch feature/hub)
  status=$?
  expect_code 0 "$status" "a flagged spawn whose intent names another branch should launch"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/feature/hub)" ] \
    || fail "the prose branch redirected the copy away from origin/feature/hub"
  assert_grep 'base_branch=feature/hub' "$HOME_DIR/state/$id.meta" "the flag's base was not recorded"
  pass "a Base branch line in the captain's intent neither blocks nor redirects a spawn"
}

# A named base is validated against the project's registered forge for scouts
# too, so a scout that promotion could never ship is refused at spawn.
test_scout_base_branch_refused_on_gerrit_forge() {
  local rec id out status
  id='pool-base-gerrit-scout-r1'
  rec=$(make_case base-gerrit-scout "$id")
  read_case_record "$rec"
  publish_feature_branch feature/hub
  printf '%s\n' '- project [no-mistakes forge=gerrit] - fixture (added 2026-01-01)' > "$HOME_DIR/data/projects.md"
  brief_with_base "$id" feature/hub
  out=$(run_spawn "$id" --scout --base-branch feature/hub)
  status=$?
  [ "$status" -ne 0 ] || fail "a based scout on a forge=gerrit project should refuse the spawn"
  assert_contains "$out" "forge=gerrit" "the gerrit refusal did not explain itself"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused gerrit scout spawn published task metadata"
  pass "a based scout on a forge=gerrit project is refused at spawn"
}

# Exercise the final assigned-copy revision, not just its classification before
# the ordinary freshness reset. Each public-path attempt owns a fresh task ID.
# install_late_dirt_shim <fakebin> <copy> <file> <content>: a git wrapper that writes <content> to <file> the
# first time the proof lists the target's tracked paths in <copy>, which is AFTER the proof has read the copy's
# status and BEFORE the governed preparation looks at it. It models work that appears between the two, the only
# way left to make a governed preparation refuse for dirt, since a copy that is dirty at the proof is skipped.
install_late_dirt_shim() {
  local real_git
  real_git=$(command -v git)
  cat > "$1/git" <<SH
#!/usr/bin/env bash
case "\$*" in *'-C $2 '*'ls-tree -r --name-only -z'*)
  if [ ! -e '$1/late-dirt.done' ]; then : > '$1/late-dirt.done'; printf '%s\\n' '$4' > '$3'; fi ;;
esac
exec '$real_git' "\$@"
SH
  chmod +x "$1/git"
}

write_refusing_slot_owner() { # <repository>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import json
import os
import sys
from pathlib import Path

Path(os.environ["FM_TEST_PROVISION_CALLED"]).write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
print(json.dumps({"state": "BLOCKED", "reason": "fixture_provisioner_must_refuse"}))
raise SystemExit(2)
PY
}

run_freshness_slot_case() { # <introduced|present|absent|missing-scope|removed> <ship|scout>
  local shape=$1 kind=$2 id case_dir home project origin pool publisher fakebin before advanced out status=0 token temp staging
  local args=()
  fm_git_identity
  id="pool-owner-$shape-$kind-$(date +%s)-$$"
  case_dir="$TMP_ROOT/$id"
  [ ! -e "$case_dir" ] && [ ! -L "$case_dir" ] || fail 'governance fixture case already exists'
  home="$case_dir/home" project="$case_dir/project" origin="$case_dir/origin.git"
  pool="$case_dir/pool" publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" codex)
  fm_test_fake_no_mistakes "$fakebin"
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  fm_test_spawn_home "$home" codex
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_test_spawn_brief "$home" "$id"
  fm_git_init_commit "$project"
  if [ "$shape" = present ] || [ "$shape" = removed ]; then
    write_refusing_slot_owner "$project"
    git -C "$project" add scripts
    git -C "$project" commit -qm 'initial governed copy'
  fi
  fm_git_add_origin "$project" "$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  before=$(git -C "$pool" rev-parse HEAD)
  if [ "$shape" = present ] || [ "$shape" = removed ]; then
    git -C "$pool" checkout --quiet -b previous-owner
  fi
  if [ "$shape" = removed ]; then
    # Only the acquired copy initially requires governance; afterward neither does.
    git -C "$project" checkout --quiet --detach HEAD^
  fi
  git clone --quiet "file://$origin" "$publisher"
  case "$shape" in
    introduced|missing-scope) write_refusing_slot_owner "$publisher" ;;
    removed) git -C "$publisher" rm -q scripts/git-stability/provision_existing_slot.py ;;
  esac
  printf 'advanced local origin\n' > "$publisher/advanced.txt"
  git -C "$publisher" add .
  git -C "$publisher" commit -qm 'advance owner fixture'
  git -C "$publisher" push --quiet origin main
  advanced=$(git -C "$publisher" rev-parse HEAD)
  if [ "$kind" = scout ]; then args+=(--scout); else args+=(--mode local-only --yolo off); fi
  [ "$shape" = missing-scope ] || [ "$shape" = absent ] || args+=(--owned-path scripts)
  temp="/tmp/fm-$id"
  token=$(printf '%s' "$home" | shasum -a 256 | awk '{print $1}')
  staging="$temp+$token"
  [ ! -e "$temp" ] && [ ! -L "$temp" ] || fail "task temp already exists: $temp"
  [ ! -e "$staging" ] && [ ! -L "$staging" ] || fail "staging already exists: $staging"
  printf 'case=%s kind=%s task=%s root=%s before=%s advanced=%s temp=%s staging=%s\n' \
    "$shape" "$kind" "$id" "$case_dir" "$before" "$advanced" "$temp" "$staging"
  out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_TEST_PROVISION_CALLED="$case_dir/provisioner.called" \
    fm_test_run_spawn "$home" "$pool" "$fakebin" "$id" "$project" --backend tmux "${args[@]}" 2>&1) || status=$?
  printf '%s\n' "$out" > "$case_dir/spawn.out"
  printf 'spawn_exit=%s after=%s\n%s\n' "$status" "$(git -C "$pool" rev-parse HEAD)" "$out"
  case "$shape" in
    absent)
      expect_code 0 "$status" "genuinely ungoverned copy should launch: $out"
      [ -s "$case_dir/launch.log" ] || fail 'ungoverned launch was not recorded'
      [ ! -e "$case_dir/provisioner.called" ] || fail 'ungoverned copy invoked an owner'
      [ "$(git -C "$pool" rev-parse HEAD)" = "$advanced" ] || fail 'ungoverned copy was not freshened'
      ;;
    *)
      [ "$status" -ne 0 ] || fail "final governed revision admitted a worker: $shape $kind"
      [ ! -s "$case_dir/launch.log" ] || fail 'governed refusal launched a harness'
      assert_grep 'recovery=slot-provision-refused' "$home/state/$id.meta" 'governed refusal lost recovery metadata'
      assert_grep 'jev_guard_policy=FIRSTMATE_JEV_GUARD_V1' "$home/state/$id.meta" 'governed refusal lost guard policy'
      case "$shape" in
        missing-scope)
          assert_contains "$out" 'governed slot provisioning requires --owned-path' 'freshly governed copy did not require explicit scope'
          [ ! -e "$case_dir/provisioner.called" ] || fail 'missing scope invoked the owner'
          assert_no_grep 'slot_owned_path=' "$home/state/$id.meta" 'missing scope was silently widened'
          ;;
        removed)
          assert_contains "$out" 'slot provisioner is missing' 'removed owner silently downgraded governance'
          [ ! -e "$case_dir/provisioner.called" ] || fail 'removed owner was invoked'
          # Main 1829/1842: the move to the target had already succeeded and the refusal runs no file-rewriting checkout, so
          # the copy stays on the target (detached); the previous owner's branch is where it was and nothing is lost.
          [ "$(git -C "$pool" rev-parse HEAD)" = "$advanced" ] || fail 'early governed refusal moved the copy off the target it was moved to'
          ;;
        *)
          [ -f "$case_dir/provisioner.called" ] || fail 'required project owner was not invoked'
          assert_contains "$out" fixture_provisioner_must_refuse 'governed refusal lost owner reason'
          assert_grep 'slot_owned_path=scripts' "$home/state/$id.meta" 'explicit scope was not retained'
          assert_grep "slot_prepared_head=$advanced" "$home/state/$id.meta" 'prepared revision was not retained'
          ;;
      esac
      if [ "$shape" = introduced ] || [ "$shape" = missing-scope ]; then
        [ "$(git -C "$pool" rev-parse HEAD)" = "$advanced" ] || fail 'freshness did not introduce the owner'
        [ -f "$pool/scripts/git-stability/provision_existing_slot.py" ] || fail 'final revision lacks introduced owner'
      fi
      ;;
  esac
  if [ "$shape" = present ] || [ "$shape" = removed ]; then
    [ "$(git -C "$pool" rev-parse refs/heads/previous-owner)" = "$before" ] || fail 'freshness moved the previous owner branch'
    # Main 1829/1842: a refusal after a move that succeeded does not run the checkout that would rewrite the files of the
    # target back to the previous commit. The copy stays on the target, detached; the branch holds the old commit.
    [ -z "$(git -C "$pool" branch --show-current)" ] || fail 'a refusal after a successful move switched the copy onto a branch'
    [ "$(git -C "$pool" rev-parse HEAD)" = "$advanced" ] || fail 'a refusal after a successful move changed the commit the copy was moved to'
    [ -f "$pool/advanced.txt" ] && [ -f "$pool/README.md" ] || fail 'a refusal after a successful move lost a file of the copy'
    assert_contains "$out" "$pool" 'the refusal did not name the copy it left as it was'
    assert_contains "$out" 'would change files' 'the refusal did not say why it left the copy as it was'
  fi
  [ ! -d "$pool/.claude/worktrees" ] || fail 'governance created nested isolation'
  pass "final revision governance: $shape $kind"
}

test_freshness_introduces_slot_owner() { run_freshness_slot_case introduced ship; }
test_freshness_introduces_scout_slot_owner() { run_freshness_slot_case introduced scout; }
test_freshness_slot_owner_requires_scope() { run_freshness_slot_case missing-scope ship; }
test_freshness_present_slot_owner_refuses() { run_freshness_slot_case present ship; }
test_freshness_absent_slot_owner_launches() { run_freshness_slot_case absent ship; }
test_freshness_removed_slot_owner_refuses() { run_freshness_slot_case removed ship; }

# Local-only chooses a qualified descendant of both defaults, not arbitrary HEAD.
# These ungoverned selector controls do not claim project attestation compatibility.
run_local_only_source_case() { # <local|equal|remote|diverged|missing|feature|dirty|publish|scout|no-origin|named>
  local shape=$1 id rec out rc=0 local_sha remote_sha before token real_git moved_sha origin_url origin_gitdir args=()
  id="pool-local-$shape-$(date +%s)-$$"
  rec=$(make_case "$id" "$id")
  read_case_record "$rec"
  fm_test_fake_no_mistakes "$FAKEBIN_DIR"
  fm_test_fake_gh "$FAKEBIN_DIR"
  fm_test_fake_gh_axi "$FAKEBIN_DIR"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  remote_sha=$(git -C "$PROJECT_DIR" rev-parse origin/main)
  case "$shape" in
    local|equal|feature|dirty|publish|scout|no-origin|named|moved|alias|dirty-copy|origin-*)
      git -C "$PROJECT_DIR" merge --ff-only origin/main >/dev/null ;;
  esac
  case "$shape" in
    local|feature|dirty|publish|scout|no-origin|named|diverged|moved|alias|dirty-copy|origin-*)
      printf 'accepted local-only work\n' > "$PROJECT_DIR/accepted-a.txt"
      git -C "$PROJECT_DIR" add accepted-a.txt
      git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'accepted A'
      ;;
  esac
  local_sha=$(git -C "$PROJECT_DIR" rev-parse refs/heads/main)
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  case "$shape" in
    feature)
      git -C "$PROJECT_DIR" checkout --quiet -b unrelated-feature
      printf 'never a baseline\n' > "$PROJECT_DIR/feature-only.txt"
      git -C "$PROJECT_DIR" add feature-only.txt
      git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm feature ;;
    dirty) printf 'uncommitted primary bytes\n' > "$PROJECT_DIR/accepted-a.txt" ;;
    missing) git -C "$PROJECT_DIR" branch -m main not-the-default ;;
    no-origin) git -C "$PROJECT_DIR" remote remove origin ;;
    alias)
      git -C "$PROJECT_DIR" branch alias-default main
      git -C "$PROJECT_DIR" symbolic-ref refs/heads/main refs/heads/alias-default ;;
    dirty-copy) printf 'preserve assigned dirt\n' > "$POOL_DIR/README.md" ;;
    origin-copy-missing|origin-primary-missing)
      origin_url=$(git -C "$PROJECT_DIR" remote get-url origin)
      git -C "$PROJECT_DIR" config --local --remove-section remote.origin
      git config -f "$CASE_DIR/qualified-origin.config" remote.origin.url "$origin_url"
      if [ "$shape" = origin-copy-missing ]; then
        origin_gitdir=$(git -C "$PROJECT_DIR" rev-parse --absolute-git-dir)
      else
        origin_gitdir=$(git -C "$POOL_DIR" rev-parse --absolute-git-dir)
      fi
      git -C "$PROJECT_DIR" config --local "includeIf.gitdir:$origin_gitdir.path" "$CASE_DIR/qualified-origin.config"
      ;;
    origin-early|origin-late|origin-freshness)
      real_git=$(command -v git)
      {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\nproject=%q\nshape=%q\nmarker=%q\n' \
          "$real_git" "$PROJECT_DIR" "$shape" "$CASE_DIR/origin-removed"
        cat <<'SH'
if [ "${1:-}" = -C ] && [ "${2:-}" = "$project" ] && [ ! -e "$marker" ]; then
  mutate=0
  if [ "$shape" = origin-early ] && [ "${3:-}" = rev-parse ] && [ "${*: -1}" = 'refs/heads/main^{commit}' ]; then mutate=1; fi
  if [ "$shape" = origin-late ] && [ "${3:-}" = merge-base ] && [ "${4:-}" = --is-ancestor ]; then mutate=1; fi
  if [ "$shape" = origin-freshness ] && [ "${3:-}" = merge-base ] && [ "${4:-}" = --is-ancestor ]; then
    count=0
    [ ! -f "$marker.count" ] || read -r count < "$marker.count"
    count=$((count + 1))
    printf '%s\n' "$count" > "$marker.count"
    [ "$count" != 3 ] || mutate=1
  fi
  if [ "$mutate" = 1 ]; then
    "$real" "$@" || exit $?
    "$real" -C "$project" config --local --remove-section remote.origin || exit $?
    printf 'removed actual origin config\n' > "$marker"
    exit 0
  fi
fi
exec "$real" "$@"
SH
      } > "$FAKEBIN_DIR/git"
      chmod +x "$FAKEBIN_DIR/git"
      ;;
    moved)
      real_git=$(command -v git)
      moved_sha=$(printf 'concurrent accepted commit\n' | git -C "$PROJECT_DIR" \
        -c user.name=Tests -c user.email=tests@example.invalid commit-tree "main^{tree}" -p main)
      # Move only this fixture's named default immediately after its first read.
      # Genuine Git returns the old snapshot, then custody must reject the move.
      {
        printf '#!/usr/bin/env bash\n'
        printf 'real=%q\nproject=%q\nnew=%q\nold=%q\nmarker=%q\n' \
          "$real_git" "$PROJECT_DIR" "$moved_sha" "$local_sha" "$CASE_DIR/ref-moved"
        cat <<'SH'
if [ "${1:-}" = -C ] && [ "${2:-}" = "$project" ] &&
  [ "${3:-}" = rev-parse ] && [ "${*: -1}" = 'refs/heads/main^{commit}' ] && [ ! -e "$marker" ]; then
  "$real" "$@" || exit $?
  "$real" -C "$project" update-ref refs/heads/main "$new" "$old" || exit $?
  printf 'moved\n' > "$marker"
  exit 0
fi
exec "$real" "$@"
SH
      } > "$FAKEBIN_DIR/git"
      chmod +x "$FAKEBIN_DIR/git"
      ;;
  esac
  args=(--mode local-only --yolo off)
  case "$shape" in
    publish) args=(--mode direct-PR --yolo off) ;;
    scout) args=(--scout) ;;
    named) args+=(--base-branch main) ;;
  esac
  token=$(printf '%s' "$HOME_DIR" | shasum -a 256 | awk '{print $1}')
  [ ! -e "/tmp/fm-$id" ] && [ ! -L "/tmp/fm-$id" ] || fail 'task temp already exists'
  [ ! -e "/tmp/fm-$id+$token" ] && [ ! -L "/tmp/fm-$id+$token" ] || fail 'staging temp already exists'
  if [ "$shape" = dirty-copy ]; then
    out=$(run_spawn_skipping "$id" "${args[@]}" 2>&1) || rc=$?
  else
    out=$(run_spawn "$id" "${args[@]}" 2>&1) || rc=$?
  fi
  case "$shape" in origin-*)
    printf 'origin_control=%s task=%s exit=%s expected_local=%s assigned_before=%s assigned_after=%s\n' \
      "$shape" "$id" "$rc" "$local_sha" "$before" "$(git -C "$POOL_DIR" rev-parse HEAD)"
    if [ -f "$POOL_DIR/accepted-a.txt" ]; then printf 'A_FILE_PRESENT\n'; else printf 'A_FILE_MISSING\n'; fi
    printf '%s\n' "$out"
    ;;
  esac
  case "$shape" in
    diverged|missing|named|alias|moved|dirty-copy|origin-*)
      [ "$rc" -ne 0 ] || fail "$shape local-only source unexpectedly admitted"
      [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] || fail 'refusal changed assigned source'
      [ ! -f "$HOME_DIR/state/$id.meta" ] || fail 'refusal published task metadata'
      [ ! -f "${POOL_DIR%/*}/.fm-slot-owner" ] || fail 'refusal claimed assigned copy'
      case "$shape" in
        diverged) assert_contains "$out" 'defaults diverge' 'divergence reason missing' ;;
        missing|alias) assert_contains "$out" 'missing or ambiguous' 'qualification reason missing' ;;
        moved)
          [ -f "$CASE_DIR/ref-moved" ] || fail 'mutable-ref control did not move the ref'
          [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$moved_sha" ] || fail 'concurrent commit lost'
          assert_contains "$out" 'default changed or is ambiguous' 'stale-plan reason missing' ;;
        dirty-copy)
          cmp "$POOL_DIR/README.md" <(printf 'preserve assigned dirt\n') || fail 'assigned dirt lost'
          assert_contains "$out" 'not clean' 'dirty assigned copy reason missing' ;;
        named) assert_contains "$out" 'local-only' 'named-base refusal reason missing' ;;
        origin-early|origin-late|origin-freshness)
          [ -f "$CASE_DIR/origin-removed" ] || fail 'origin control did not mutate real config'
          assert_contains "$out" 'origin qualification' 'changed-origin refusal reason missing' ;;
        origin-copy-missing|origin-primary-missing)
          assert_contains "$out" 'origin qualification' 'mismatched-origin refusal reason missing' ;;
      esac
      ;;
    *)
      expect_code 0 "$rc" "$shape source selection failed"$'\n'"$out"
      case "$shape" in
        remote|equal|publish|scout) [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$remote_sha" ] || fail 'remote descendant not selected' ;;
        no-origin) [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] || fail 'originless contract changed' ;;
        *) [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$local_sha" ] || fail 'qualified local descendant not selected'
           cmp "$POOL_DIR/accepted-a.txt" <(printf 'accepted local-only work\n') || fail 'local source bytes changed' ;;
      esac
      [ ! -f "$POOL_DIR/feature-only.txt" ] || fail 'arbitrary primary feature HEAD selected'
      ;;
  esac
  if [ "$shape" != no-origin ]; then
    [ "$(git -C "$PROJECT_DIR" rev-parse origin/main)" = "$remote_sha" ] || fail 'local work mislabeled as origin'
    [ "$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/main)" = "$remote_sha" ] || fail 'remote changed'
  fi
  pass "local-only source selection: $shape"
}

test_local_only_origin_early() { run_local_only_source_case origin-early; }
test_local_only_origin_late() { run_local_only_source_case origin-late; }
test_local_only_origin_freshness() { run_local_only_source_case origin-freshness; }
test_local_only_origin_copy_missing() { run_local_only_source_case origin-copy-missing; }
test_local_only_origin_primary_missing() { run_local_only_source_case origin-primary-missing; }

test_local_only_source_selection() {
  local shape
  for shape in local equal remote diverged missing alias moved feature dirty dirty-copy publish scout no-origin named; do
    run_local_only_source_case "$shape"
  done
}

# Verify argument binding through a deliberately refusing project interface.
# This is not a substitute for actual-project acceptance in the governed cycle.
run_local_only_binding_case() { # <prepared|unprepared>
  local shape=$1 id rec selected remote out rc=0 prepared token stoppedbin
  id="pool-local-binding-$shape-$(date +%s)-$$"
  rec=$(make_case "$id" "$id")
  read_case_record "$rec"
  fm_test_fake_no_mistakes "$FAKEBIN_DIR"
  fm_test_fake_gh "$FAKEBIN_DIR"
  fm_test_fake_gh_axi "$FAKEBIN_DIR"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$PROJECT_DIR" merge --ff-only origin/main >/dev/null
  remote=$(git -C "$PROJECT_DIR" rev-parse origin/main)
  write_refusing_slot_owner "$PROJECT_DIR"
  git -C "$PROJECT_DIR" add scripts
  git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'accepted local owner'
  selected=$(git -C "$PROJECT_DIR" rev-parse main)
  token=$(printf '%s' "$HOME_DIR" | shasum -a 256 | awk '{print $1}')
  [ ! -e "/tmp/fm-$id" ] && [ ! -L "/tmp/fm-$id" ] || fail 'binding task temp already exists'
  [ ! -e "/tmp/fm-$id+$token" ] && [ ! -L "/tmp/fm-$id+$token" ] || fail 'binding staging already exists'
  if [ "$shape" = unprepared ]; then
    install_late_dirt_shim "$FAKEBIN_DIR" "$POOL_DIR" "$POOL_DIR/README.md" 'preserve pre-existing assigned work'
  fi
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn "$id" \
    --mode local-only --yolo off --owned-path README.md 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'deliberately refusing project interface admitted a worker'
  if [ "$shape" = prepared ]; then
    assert_contains "$out" 'fixture_provisioner_must_refuse' 'interface refusal not preserved'
    python3 - "$CASE_DIR/provisioner.called" "$selected" <<'PY'
import json, sys
args = json.load(open(sys.argv[1]))
assert args[args.index('--base-source') + 1] == 'local-default'
assert args[args.index('--base-sha') + 1] == sys.argv[2]
assert args[args.index('--owned-path') + 1] == 'README.md'
assert args.count('--owned-path') == 1
PY
  else
    assert_contains "$out" 'dirty_worktree' 'unprepared refusal did not preserve dirt reason'
    [ ! -e "$CASE_DIR/provisioner.called" ] || fail 'dirty copy reached the project owner'
    assert_no_grep 'slot_prepared_head=' "$HOME_DIR/state/$id.meta" 'unprepared attempt gained a prepared identity'
  fi
  assert_grep "slot_source_ref=refs/heads/main" "$HOME_DIR/state/$id.meta" 'refusal lost qualified source'
  assert_grep "slot_base_sha=$selected" "$HOME_DIR/state/$id.meta" 'refusal lost selected base'
  if [ "$shape" = prepared ]; then
    assert_grep "slot_prepared_head=$selected" "$HOME_DIR/state/$id.meta" 'refusal lost prepared branch'
    prepared=$(git -C "$PROJECT_DIR" rev-parse "refs/heads/fm/$id")
    [ "$prepared" = "$selected" ] || fail 'prepared branch is not the selected baseline'
  else
    prepared=$(git -C "$POOL_DIR" rev-parse HEAD)
    printf 'later accepted work\n' > "$PROJECT_DIR/later.txt"
    git -C "$PROJECT_DIR" add later.txt
    git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'advance qualified default'
  fi
  [ "$(git -C "$PROJECT_DIR" rev-parse origin/main)" = "$remote" ] || fail 'binding relabeled local as origin'
  # Model the existing, agent-free retained shell using the established relaunch fixture.
  stoppedbin="$CASE_DIR/stopped"
  mkdir "$stoppedbin"
  {
    cat <<'SH'
#!/usr/bin/env bash
case "$*" in *'#{pane_current_command}'*) printf 'zsh\n'; exit 0 ;; esac
SH
    printf 'exec %q "$@"\n' "$FAKEBIN_DIR/tmux"
  } > "$stoppedbin/tmux"
  chmod +x "$stoppedbin/tmux"
  rc=0
  out=$(FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_TEST_PROVISION_CALLED="$CASE_DIR/relaunch.called" fm_test_run_spawn \
    "$HOME_DIR" "$POOL_DIR" "$stoppedbin:$FAKEBIN_DIR" "$id" --relaunch 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'deliberately refusing project admitted a relaunched worker'
  if [ "$shape" = unprepared ]; then
    assert_contains "$out" 'default changed or is ambiguous' 'unprepared retry did not refuse stale plan'
    [ ! -e "$CASE_DIR/relaunch.called" ] || fail 'unprepared retry fabricated a project declaration'
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$prepared" ] || fail 'unprepared retry reset assigned source'
    cmp "$POOL_DIR/README.md" <(printf 'preserve pre-existing assigned work\n') || fail 'unprepared retry lost valuable work'
    assert_grep "slot_source_ref=refs/heads/main" "$HOME_DIR/state/$id.meta" 'retry lost local source mode'
    assert_grep "slot_base_sha=$selected" "$HOME_DIR/state/$id.meta" 'retry relabeled the pinned base'
    pass 'unprepared refused retry preserves local evidence and work without origin fallback'
    return
  fi
  assert_contains "$out" 'fixture_provisioner_must_refuse' 'relaunch did not reach original declaration'
  python3 - "$CASE_DIR/relaunch.called" "$selected" <<'PY'
import json, sys
args = json.load(open(sys.argv[1]))
assert args[args.index('--base-source') + 1] == 'local-default'
assert args[args.index('--base-sha') + 1] == sys.argv[2]
PY
  [ "$(git -C "$PROJECT_DIR" rev-parse "refs/heads/fm/$id")" = "$prepared" ] || fail 'relaunch reset prepared task branch'
  [ "$(git -C "$PROJECT_DIR" rev-parse origin/main)" = "$remote" ] || fail 'relaunch advanced origin to local work'
  pass 'qualified local source is bound to provisioner arguments, refusal metadata and relaunch'
}

test_local_only_source_binding() { run_local_only_binding_case prepared; }
test_local_only_unprepared_retry() { run_local_only_binding_case unprepared; }

make_stopped_tmux() { # <dir>; an agent-free retained shell for the relaunch fixture
  mkdir "$1"
  {
    cat <<'SH'
#!/usr/bin/env bash
case "$*" in *'#{pane_current_command}'*) printf 'zsh\n'; exit 0 ;; esac
SH
    printf 'exec %q "$@"\n' "$FAKEBIN_DIR/tmux"
  } > "$1/tmux"
  chmod +x "$1/tmux"
}

run_relaunch() { # <id> [<arg>...]
  local id=$1
  shift
  FM_FAKE_DUPLICATE_WINDOW="fm-$id" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$CASE_DIR/stopped:$FAKEBIN_DIR" "$id" --relaunch "$@"
}

preflight_task_temp() { # <id>
  local token
  token=$(printf '%s' "$HOME_DIR" | shasum -a 256 | awk '{print $1}')
  [ ! -e "/tmp/fm-$1" ] && [ ! -L "/tmp/fm-$1" ] || fail "task temp already exists: /tmp/fm-$1"
  [ ! -e "/tmp/fm-$1+$token" ] && [ ! -L "/tmp/fm-$1+$token" ] || fail "staging temp already exists: /tmp/fm-$1+$token"
}

# An origin-equal attempt records no local plan. When its retry finishes first
# admission after accepted local-only A advanced main, it must select A afresh.
run_local_only_equal_retry_case() { # <advanced|adopted-scope|diverged|invalid-ref>
  local shape=$1 id rec remote local_a before out rc=0 publisher scope_args=()
  id="pool-local-equal-$shape-$(date +%s)-$$"
  rec=$(make_case "$id" "$id")
  read_case_record "$rec"
  fm_test_fake_no_mistakes "$FAKEBIN_DIR"
  fm_test_fake_gh "$FAKEBIN_DIR"
  fm_test_fake_gh_axi "$FAKEBIN_DIR"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$PROJECT_DIR" merge --ff-only origin/main >/dev/null
  write_refusing_slot_owner "$PROJECT_DIR"
  git -C "$PROJECT_DIR" add scripts
  git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'published owner'
  git -C "$PROJECT_DIR" push --quiet origin main
  remote=$(git -C "$PROJECT_DIR" rev-parse origin/main)
  [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$remote" ] || fail 'origin-equal setup was not equal'
  preflight_task_temp "$id"
  if [ "$shape" = adopted-scope ]; then
    # The first attempt omits scope; its remedy supplies scope on retry.
    out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn "$id" \
      --mode local-only --yolo off 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'scope-less governed attempt admitted a worker'
    assert_contains "$out" 'governed slot provisioning requires --owned-path' 'scope-less attempt lost its remedy'
    assert_no_grep 'slot_owned_path=' "$HOME_DIR/state/$id.meta" 'scope-less attempt recorded inferred scope'
    scope_args=(--owned-path README.md)
  else
    install_late_dirt_shim "$FAKEBIN_DIR" "$POOL_DIR" "$POOL_DIR/scratch.txt" 'operator scratch'
    out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn "$id" \
      --mode local-only --yolo off --owned-path README.md 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail 'dirty origin-equal attempt admitted a worker'
    assert_contains "$out" dirty_worktree 'origin-equal attempt did not refuse dirt'
    rm "$POOL_DIR/scratch.txt"
  fi
  [ ! -e "$CASE_DIR/provisioner.called" ] || fail 'unprepared copy reached the project owner'
  assert_grep 'recovery=slot-provision-refused' "$HOME_DIR/state/$id.meta" 'first refusal lost recovery'
  assert_no_grep 'slot_source_ref=' "$HOME_DIR/state/$id.meta" 'origin-equal attempt recorded a local plan'
  assert_no_grep 'slot_prepared_head=' "$HOME_DIR/state/$id.meta" 'unprepared attempt gained a prepared identity'
  printf 'accepted local-only work\n' > "$PROJECT_DIR/accepted-a.txt"
  git -C "$PROJECT_DIR" add accepted-a.txt
  git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'accepted A'
  local_a=$(git -C "$PROJECT_DIR" rev-parse main)
  case "$shape" in
    diverged)
      publisher="$CASE_DIR/divergent-publisher"
      git clone --quiet "file://$CASE_DIR/origin.git" "$publisher"
      printf 'unrelated upstream\n' > "$publisher/upstream.txt"
      git -C "$publisher" add upstream.txt
      git -C "$publisher" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'divergent upstream'
      git -C "$publisher" push --quiet origin main
      remote=$(git -C "$publisher" rev-parse HEAD)
      ;;
    invalid-ref)
      printf 'slot_source_ref=refs/remotes/origin/main\nslot_base_sha=%s\n' "$local_a" >> "$HOME_DIR/state/$id.meta"
      ;;
  esac
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  make_stopped_tmux "$CASE_DIR/stopped"
  rc=0
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/relaunch.called" run_relaunch "$id" ${scope_args[@]+"${scope_args[@]}"} 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "deliberately refusing project admitted a relaunched worker: $shape"
  case "$shape" in
    diverged|invalid-ref)
      if [ "$shape" = diverged ]; then
        assert_contains "$out" 'defaults diverge' 'divergent retry did not refuse source selection'
      else
        assert_contains "$out" 'invalid recorded local-default ref' 'tampered source ref was not refused'
      fi
      [ ! -e "$CASE_DIR/relaunch.called" ] || fail 'refused source selection reached the project owner'
      [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] || fail 'refused source selection changed the assigned copy'
      git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/heads/fm/$id" >/dev/null && fail 'refused source selection prepared a task branch'
      assert_no_grep 'slot_prepared_head=' "$HOME_DIR/state/$id.meta" 'refused source selection recorded a prepared identity'
      ;;
    advanced|adopted-scope)
      assert_contains "$out" fixture_provisioner_must_refuse 'retry did not reach the project owner'
      python3 - "$CASE_DIR/relaunch.called" "$local_a" <<'PY'
import json, sys
args = json.load(open(sys.argv[1]))
assert args[args.index('--base-source') + 1] == 'local-default', args
assert args[args.index('--base-sha') + 1] == sys.argv[2], args
assert args[args.index('--owned-path') + 1] == 'README.md', args
PY
      [ "$(git -C "$PROJECT_DIR" rev-parse "refs/heads/fm/$id")" = "$local_a" ] || fail 'retry dropped accepted A for old origin'
      [ "$(git -C "$PROJECT_DIR" show "refs/heads/fm/$id:accepted-a.txt")" = 'accepted local-only work' ] || fail 'prepared branch lost A bytes'
      assert_grep "slot_prepared_head=$local_a" "$HOME_DIR/state/$id.meta" 'retry lost prepared identity'
      assert_grep 'slot_source_ref=refs/heads/main' "$HOME_DIR/state/$id.meta" 'retry lost its selected local source'
      assert_grep "slot_base_sha=$local_a" "$HOME_DIR/state/$id.meta" 'retry lost its selected local baseline'
      [ "$(sed -n 's/^slot_owned_path=//p' "$HOME_DIR/state/$id.meta")" = README.md ] || fail 'refused retry lost its exact scope'
      if [ "$shape" = adopted-scope ]; then
        cp "$HOME_DIR/state/$id.meta" "$CASE_DIR/meta.adopted"
        rc=0
        out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/override.called" run_relaunch "$id" --owned-path scripts 2>&1) || rc=$?
        [ "$rc" -ne 0 ] || fail 'retry replaced adopted scope'
        assert_contains "$out" 'cannot override it' 'adopted-scope override refusal reason missing'
        [ ! -e "$CASE_DIR/override.called" ] || fail 'scope override reached the project owner'
        cmp -s "$HOME_DIR/state/$id.meta" "$CASE_DIR/meta.adopted" || fail 'scope override changed the task record'
      fi
      # The prepared retry resumes that exact local pin rather than an origin merge-base.
      rc=0
      out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/resume.called" run_relaunch "$id" 2>&1) || rc=$?
      [ "$rc" -ne 0 ] || fail 'deliberately refusing project admitted a resumed worker'
      assert_contains "$out" fixture_provisioner_must_refuse 'prepared resume did not reach the project owner'
      python3 - "$CASE_DIR/resume.called" "$local_a" <<'PY'
import json, sys
args = json.load(open(sys.argv[1]))
assert args[args.index('--base-source') + 1] == 'local-default', args
assert args[args.index('--base-sha') + 1] == sys.argv[2], args
assert args[args.index('--owned-path') + 1] == 'README.md' and args.count('--owned-path') == 1, args
PY
      [ "$(sed -n 's/^slot_owned_path=//p' "$HOME_DIR/state/$id.meta")" = README.md ] || fail 'normal retry changed its exact scope'
      ;;
  esac
  [ "$(git -C "$CASE_DIR/origin.git" rev-parse refs/heads/main)" = "$remote" ] || fail 'retry published or relabeled local work'
  [ "$(git -C "$PROJECT_DIR" rev-parse main)" = "$local_a" ] || fail 'retry moved the qualified local default'
  pass "origin-equal refused retry after local advance: $shape"
}

test_local_only_equal_retry_selects_local() { run_local_only_equal_retry_case advanced; }
test_local_only_equal_retry_divergence() { run_local_only_equal_retry_case diverged; }
test_local_only_adopted_scope_retry() { run_local_only_equal_retry_case adopted-scope; }
test_local_only_equal_retry_invalid_ref() { run_local_only_equal_retry_case invalid-ref; }

write_passing_slot_owner() { # <repository>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import argparse
import json
import os
import sys
from pathlib import Path

Path(os.environ["FM_TEST_PROVISION_CALLED"]).write_text(json.dumps(sys.argv[1:]), encoding="utf-8")
if os.environ.get("FM_TEST_SLOT_REFUSE"):
    print(json.dumps({"state": "BLOCKED", "reason": "fixture_owner_refused_legacy_scope"}))
    raise SystemExit(2)
p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
a = p.parse_args()
record = dict(worktree_path=os.path.realpath(a.worktree_path), owner_id=a.owner_id, branch=a.branch,
              base_sha=a.base_sha, owned_paths=a.owned_path, lifecycle_state="worktree_active")
manifest = Path(os.environ["FM_TEST_SLOT_RECORD"])
manifest.write_text(json.dumps(record), encoding="utf-8")
print(json.dumps(dict(state="PASS", manifest_path=str(manifest), **record)))
PY
}

# A task admitted before its project gained an owner records no scope. It is
# recoverable only through explicit relaunch scope, never inferred or overridden.
test_legacy_relaunch_scope_adoption() {
  local id rec out rc=0 meta head
  id="pool-legacy-scope-$(date +%s)-$$"
  rec=$(make_case "$id" "$id")
  read_case_record "$rec"
  fm_test_fake_no_mistakes "$FAKEBIN_DIR"
  fm_test_fake_gh "$FAKEBIN_DIR"
  fm_test_fake_gh_axi "$FAKEBIN_DIR"
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  git -C "$PROJECT_DIR" merge --ff-only origin/main >/dev/null
  preflight_task_temp "$id"
  out=$(run_spawn "$id" --mode local-only --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "ungoverned legacy spawn failed: $out"
  meta="$HOME_DIR/state/$id.meta"
  ! grep -q '^slot_' "$meta" || fail 'ungoverned spawn recorded slot state'
  make_stopped_tmux "$CASE_DIR/stopped"
  cp "$meta" "$CASE_DIR/meta.ungoverned"
  rc=0
  out=$(run_relaunch "$id" --owned-path README.md 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'ungoverned relaunch accepted unused scope'
  assert_contains "$out" 'only to scope a governed task' 'ungoverned scope refusal reason missing'
  cmp -s "$meta" "$CASE_DIR/meta.ungoverned" || fail 'ungoverned scope refusal changed the task record'

  write_passing_slot_owner "$PROJECT_DIR"
  git -C "$PROJECT_DIR" add scripts
  git -C "$PROJECT_DIR" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'project gains owner'
  git -C "$PROJECT_DIR" push --quiet origin main
  git -C "$POOL_DIR" checkout -q -b "fm/$id" main
  rc=0
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/unscoped.called" run_relaunch "$id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'governed legacy relaunch inferred scope'
  assert_contains "$out" 'governed slot provisioning requires --owned-path' 'legacy refusal lost its remedy'
  [ ! -e "$CASE_DIR/unscoped.called" ] || fail 'unscoped legacy relaunch reached the project owner'
  ! grep -q '^slot_' "$meta" || fail 'unscoped legacy refusal recorded slot state'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$PROJECT_DIR" rev-parse main)" ] || fail 'legacy refusal moved the task'

  # The owner refuses the first explicit scope: only that scope is retained.
  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  cp "$meta" "$CASE_DIR/meta.legacy"
  rc=0
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/refused.called" FM_TEST_SLOT_REFUSE=1 \
    run_relaunch "$id" --owned-path README.md 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'refusing project owner admitted the legacy relaunch'
  assert_contains "$out" fixture_owner_refused_legacy_scope 'legacy refusal lost the owner reason'
  [ -f "$CASE_DIR/refused.called" ] || fail 'explicit legacy scope did not reach the project owner'
  [ "$(sed -n 's/^slot_owned_path=//p' "$meta")" = README.md ] || fail 'refused legacy relaunch lost explicit scope'
  diff <(grep -v '^slot_owned_path=' "$meta") "$CASE_DIR/meta.legacy" >/dev/null || fail 'refused legacy relaunch changed other record facts'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] || fail 'refused legacy relaunch moved the task'
  cp "$meta" "$CASE_DIR/meta.retained"
  rc=0
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/drift.called" run_relaunch "$id" --owned-path scripts 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'relaunch replaced owner-refused legacy scope'
  assert_contains "$out" 'cannot override it' 'refused-scope override reason missing'
  [ ! -e "$CASE_DIR/drift.called" ] || fail 'refused-scope override reached the project owner'
  cmp -s "$meta" "$CASE_DIR/meta.retained" || fail 'refused-scope override changed the task record'

  rc=0
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/adopt.called" FM_TEST_SLOT_RECORD="$CASE_DIR/manifest.json" \
    run_relaunch "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "retained legacy scope adoption failed: $out"
  python3 - "$CASE_DIR/adopt.called" "$id" <<'PY'
import json, sys
args = json.load(open(sys.argv[1]))
assert args[args.index('--owner-id') + 1] == sys.argv[2], args
assert args[args.index('--branch') + 1] == 'fm/' + sys.argv[2], args
assert args[args.index('--owned-path') + 1] == 'README.md', args
assert args.count('--owned-path') == 1 and '--base-source' not in args, args
PY
  assert_grep "slot_manifest=$CASE_DIR/manifest.json" "$meta" 'adoption did not record the declaration'
  [ "$(sed -n 's/^slot_owned_path=//p' "$meta")" = README.md ] || fail 'adoption did not record exactly the explicit scope'

  cp "$meta" "$CASE_DIR/meta.scoped"
  rc=0
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/override.called" run_relaunch "$id" --owned-path scripts 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'relaunch replaced recorded scope'
  assert_contains "$out" 'cannot override it' 'recorded-scope override refusal reason missing'
  [ ! -e "$CASE_DIR/override.called" ] || fail 'scope override reached the project owner'
  cmp -s "$meta" "$CASE_DIR/meta.scoped" || fail 'scope override changed the task record'
  pass 'legacy relaunch refuses inferred scope, retains refused explicit scope, adopts it, and never overrides it'
}


# --- a skipped copy: another copy is taken, the skipped one is left exactly as found ----------------

# make_skip_case <name> <id> <slot-count>: make_case plus extra pool slots at the same commit and a
# tmux whose pane enters the next slot each time `treehouse get` is typed into it (an empty answer
# once the slots run out). The treehouse stub records its calls; FM_TEST_LEASE_RC makes `lease` fail.
# Sets SKIP_SLOTS (the slot paths in hand-out order) and SKIP_LOG.
make_skip_case() {
  local name=$1 id=$2 count=$3 rec n slot
  rec=$(make_case "$name" "$id")
  read_case_record "$rec"
  SKIP_SLOTS=("$POOL_DIR")
  for ((n = 2; n <= count; n++)); do
    slot="$CASE_DIR/pool$n"
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$slot" "$INITIAL_SHA"
    SKIP_SLOTS+=("$slot")
  done
  make_skip_transport
}

# make_skip_transport: with SKIP_SLOTS, CASE_DIR and FAKEBIN_DIR set, a tmux whose pane enters the next slot each time
# `treehouse get` is typed into it (staying put once the slots run out), and a treehouse stub that logs its calls.
make_skip_transport() {
  local real_tmux
  printf '%s\n' "${SKIP_SLOTS[@]}" > "$CASE_DIR/slots"
  : > "$CASE_DIR/panepath"
  echo 0 > "$CASE_DIR/get-count"
  SKIP_LOG="$CASE_DIR/treehouse.log"
  : > "$SKIP_LOG"
  real_tmux="$FAKEBIN_DIR/tmux.real"
  mv "$FAKEBIN_DIR/tmux" "$real_tmux"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_path}'*) cat '$CASE_DIR/panepath'; exit 0 ;;
  *send-keys*'treehouse get'*)
    n=\$(( \$(cat '$CASE_DIR/get-count') + 1 ))
    echo "\$n" > '$CASE_DIR/get-count'
    line=\$(sed -n "\${n}p" '$CASE_DIR/slots')
    # Once the slots run out the pane stays where it is, as a real pane does while a get finds no copy.
    [ -z "\$line" ] || printf '%s\\n' "\$line" > '$CASE_DIR/panepath'
    exit 0 ;;
esac
exec '$real_tmux' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$SKIP_LOG'
case "\${1:-}" in lease) eval "\${FM_TEST_LEASE_PROBE:-:}" >>'$SKIP_LOG' 2>&1; exit "\${FM_TEST_LEASE_RC:-0}" ;; esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

# slot_digest <slot>: HEAD, its branch, EVERY ref of the repository (the refs are shared by every copy), the index, and
# every file outside .git (a regular file by sha256, a symlink by its target). It FAILS (nonzero) when any read fails,
# so a failed read can never compare equal to another.
slot_digest() {
  local slot=$1 head sym refs
  (
    set -o pipefail
    head=$(git -C "$slot" rev-parse HEAD) || exit 1
    printf 'HEAD %s\n' "$head"
    sym=$(git -C "$slot" symbolic-ref -q HEAD) || { [ "$?" = 1 ] || exit 1; sym=detached; }
    printf 'SYMBOLIC %s\n' "$sym"
    refs=$(git -C "$slot" for-each-ref --format='%(refname) %(objectname)') || exit 1
    printf 'REFS\n%s\nENDREFS\n' "$refs"
    git -C "$slot" ls-files -s --debug || exit 1
    cd "$slot" || exit 1
    # shellcheck disable=SC2016 # The inner sh expands its own $1.
    find . -path ./.git -prune -o \( -type f -o -type l \) -print0 | LC_ALL=C sort -z |
      xargs -0 -n1 sh -c 'if [ -L "$1" ]; then printf "LINK %s -> %s\n" "$1" "$(readlink "$1")"; else shasum -a 256 -- "$1"; fi' _
  ) 2>&1
}

# The refs a spawn may change while it works in ANOTHER copy: origin's default tracking ref and origin/HEAD (Main 003).
# New refs (the task's own branch, anchors) may appear. Nothing else that existed before may differ or vanish.

# second_copy_refs <id> [governed]: the "<ref>=<sha>" pairs that a spawn which skipped one copy and then MOVED another
# copy of the same repository legitimately writes into the shared ref set: origin's default tracking ref and origin/HEAD
# at origin's tip (recorded after the move succeeded) and, for a governed task, its branch and the preservation anchor
# of the detached copy it started from. The skipped copy's own digest may differ by exactly these and nothing else.
second_copy_refs() {
  local id=$1 tip
  tip=$(git -C "$CASE_DIR/origin.git" rev-parse --verify "refs/heads/$DEFAULT_BRANCH") || fail "origin's tip cannot be read"
  printf '%s\n' "refs/remotes/origin/$DEFAULT_BRANCH=$tip" "refs/remotes/origin/HEAD=$tip"
  if [ "${2:-}" = governed ]; then
    printf '%s\n' "refs/heads/fm/$id=$tip" "refs/fm/anchor/$id-$(git -C "$PROJECT_DIR" rev-parse --short "$INITIAL_SHA")=$INITIAL_SHA"
  fi
}

# assert_digest_unchanged <slot> <before-digest> <message>: the copy reads back as it did, and every ref that existed
# still has the same value, but for the two allowed ones.
# assert_digest_unchanged <slot> <before-digest> <label> [<ref>=<sha>...]: the digest now equals <before-digest> in HEAD,
# the branch, the index and every file, and the SET of refs is identical in both directions (a ref that is new, gone or
# moved fails). The only exception is a ref named as <ref>=<sha>, which may be created or moved, and only to exactly <sha>.
assert_digest_unchanged() {
  local slot=$1 before=$2 label=$3 after b_plain a_plain b_refs a_refs why
  shift 3
  after=$(slot_digest "$slot") || fail "$label (the slot could not be read)"
  b_plain=$(printf '%s\n' "$before" | awk '/^REFS$/{skip=1} !skip{print} /^ENDREFS$/{skip=0}')
  a_plain=$(printf '%s\n' "$after" | awk '/^REFS$/{skip=1} !skip{print} /^ENDREFS$/{skip=0}')
  [ "$b_plain" = "$a_plain" ] || fail "$label"
  b_refs=$(printf '%s\n' "$before" | awk '/^REFS$/{on=1;next} /^ENDREFS$/{on=0} on')
  a_refs=$(printf '%s\n' "$after" | awk '/^REFS$/{on=1;next} /^ENDREFS$/{on=0} on')
  why=$(python3 - "$b_refs" "$a_refs" "$@" <<'PY'
import sys
def parse(text):
    out = {}
    for line in text.splitlines():
        if line.strip():
            name, _, sha = line.rpartition(" ")
            out[name] = sha
    return out
before, after = parse(sys.argv[1]), parse(sys.argv[2])
allowed = dict(spec.split("=", 1) for spec in sys.argv[3:])
bad = []
for name in sorted(set(before) | set(after)):
    if before.get(name) == after.get(name):
        continue
    if name in allowed and after.get(name) == allowed[name]:
        continue
    bad.append("%s: %s -> %s" % (name, before.get(name, "absent"), after.get(name, "absent")))
print("; ".join(bad))
sys.exit(1 if bad else 0)
PY
  ) || fail "$label (the ref set changed: $why)"
}

# assert_no_launch <launch-log>: no harness was launched (the fake launcher logs each launch).
assert_no_launch() {
  [ ! -s "$1" ] || fail "a harness was launched: $(cat "$1")"
}

test_a_skipped_dirty_copy_is_left_as_found_and_another_is_taken() {
  local id out status before sync
  id='pool-skip-dirty-take-next'
  make_skip_case skip-dirty "$id" 2
  printf 'keep this local work\n' > "${SKIP_SLOTS[0]}/uncommitted.txt"
  before=$(slot_digest "${SKIP_SLOTS[0]}") || fail "the slot could not be read before the spawn"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a dirty first copy should be skipped and the second used"$'\n'"$out"
  assert_contains "$out" "skipped: copy ${SKIP_SLOTS[0]}" "the skip was not reported"
  assert_contains "$out" "(dirty_tree)" "the skip did not name its reason"
  assert_grep "worktree=${SKIP_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the second copy"
  # shellcheck disable=SC2046 # one word per "<ref>=<sha>" pair
  assert_digest_unchanged "${SKIP_SLOTS[0]}" "$before" "the skipped copy changed" $(second_copy_refs "$id")
  assert_grep "lease --path ${SKIP_SLOTS[0]}" "$SKIP_LOG" "the skipped copy was not leased durably before it was left"
  [ "$(git -C "${SKIP_SLOTS[1]}" rev-parse HEAD)" = "$(git -C "${SKIP_SLOTS[1]}" rev-parse origin/main)" ] \
    || fail "the second copy was not moved to origin's tip"
  [ "$(cat "$CASE_DIR/get-count")" = 2 ] || fail "treehouse get was not typed exactly twice"
  sync=$(grep -c . "$SKIP_LOG")
  [ "$sync" -ge 1 ] || fail "the treehouse stub saw no call"
  pass "a dirty copy is leased in place, left byte-identical, and a second copy is taken and launched from"
}

test_a_skipped_copy_with_an_unlanded_commit_keeps_it_and_another_is_taken() {
  local id out status before extra
  id='pool-skip-unlanded-take-next'
  make_skip_case skip-unlanded "$id" 2
  printf 'unlanded\n' > "${SKIP_SLOTS[0]}/mine.txt"
  git -C "${SKIP_SLOTS[0]}" add mine.txt
  git -C "${SKIP_SLOTS[0]}" -c user.name=T -c user.email=t@example.invalid commit -qm unlanded
  extra=$(git -C "${SKIP_SLOTS[0]}" rev-parse HEAD)
  before=$(slot_digest "${SKIP_SLOTS[0]}") || fail "the slot could not be read before the spawn"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a copy holding an unlanded commit should be skipped"$'\n'"$out"
  assert_contains "$out" "(not_fast_forward)" "the skip did not name its reason"
  [ "$(git -C "${SKIP_SLOTS[0]}" rev-parse HEAD)" = "$extra" ] || fail "the unlanded commit is no longer HEAD of the skipped copy"
  # shellcheck disable=SC2046 # one word per "<ref>=<sha>" pair
  assert_digest_unchanged "${SKIP_SLOTS[0]}" "$before" "the skipped copy changed" $(second_copy_refs "$id")
  assert_grep "worktree=${SKIP_SLOTS[1]}" "$HOME_DIR/state/$id.meta" "the task was not recorded on the second copy"
  pass "a copy holding an unlanded commit is skipped with the commit kept, and the task runs on another copy"
}

test_no_other_copy_refuses_and_names_the_skipped_one() {
  local id out status before
  id='pool-skip-no-other-copy'
  make_skip_case skip-none "$id" 1
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read before the spawn"

  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched although its only copy was skipped"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_contains "$out" "copies skipped by this spawn: $POOL_DIR" "the refusal did not name the skipped copy"
  assert_contains "$out" "(dirty_tree)" "the refusal did not carry the skip reason"
  [ "$(grep -c '^lease --path' "$SKIP_LOG")" = 1 ] || fail "the skipped copy was taken up again and was leased more than once"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  assert_digest_unchanged "$POOL_DIR" "$before" "the only copy changed"
  pass "with no other copy the spawn refuses, names the skipped copy and its reason, and launches nothing"
}

test_a_skip_that_cannot_lease_the_copy_stops_without_asking_for_another() {
  local id out status before
  id='pool-skip-lease-fails'
  make_skip_case skip-lease-fails "$id" 2
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read before the spawn"

  out=$(FM_TEST_LEASE_RC=1 run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on although the skipped copy could not be leased"
  assert_contains "$out" "could not lease skipped copy $POOL_DIR durably" "the lease failure was not reported"
  assert_contains "$out" "stays open on it, untouched" "the endpoint was not kept open on the copy"
  [ "$(cat "$CASE_DIR/get-count")" = 1 ] || fail "a second copy was requested although the first could not be protected"
  assert_digest_unchanged "$POOL_DIR" "$before" "the copy changed"
  pass "a copy that cannot be leased is not abandoned: no second copy is requested and the copy is untouched"
}


# --- review round 023: findings the first build missed (red first) ---------------------------

# start_slot_holder <slot>: a live process whose working directory is <slot>. Sets HOLDER_PID.
start_slot_holder() {
  (cd "$1" && exec sleep 600) &
  HOLDER_PID=$!
  sleep 0.3
}
stop_slot_holder() { kill "${HOLDER_PID:-0}" 2>/dev/null || true; wait "${HOLDER_PID:-0}" 2>/dev/null || true; }

# make_governed_skip_case <name> <id>: two copies, and a project that carries the slot provisioner (it reaches
# the copies through origin's tip), so a fresh copy is governed. The provisioner refuses, which is fine: the
# cases read the FIRST copy, which must be skipped before any provisioning.
make_governed_skip_case() {
  make_skip_case "$1" "$2" 2
  write_refusing_slot_owner "$CASE_DIR/publisher"
  git -C "$CASE_DIR/publisher" add scripts
  git -C "$CASE_DIR/publisher" -c user.name=T -c user.email=t@example.invalid commit -qm 'add slot owner'
  git -C "$CASE_DIR/publisher" push --quiet origin "$DEFAULT_BRANCH"
  git -C "$PROJECT_DIR" pull --quiet --ff-only origin "$DEFAULT_BRANCH"
}

test_an_originless_copy_with_a_live_holder_is_skipped() {
  local rec id out status
  id='pool-originless-holder-r1'
  rec=$(make_originless_case originless-holder "$id")
  read_case_record "$rec"
  start_slot_holder "$POOL_DIR"
  out=$(run_spawn_skipping "$id" --mode no-mistakes --yolo off)
  status=$?
  stop_slot_holder
  [ "$status" -ne 0 ] || fail "spawn launched on an origin-less copy that a live process holds"$'\n'"$out"
  assert_contains "$out" "(live_holder)" "the skip did not name its reason"
  [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  pass "an origin-less copy with a live process in it is skipped, not launched from"
}

# An unreachable origin is a fact about the project, not about a copy: it refuses before a copy is acquired, so
# no copy is touched and none is leased. (Red at c3bb181b8: one copy was acquired first and then abandoned
# without a lease, where closing its pane would let Treehouse reset it.)
test_an_unreachable_origin_refuses_before_any_copy_is_taken() {
  local id out status
  id='pool-skip-fetch-fails'
  make_skip_case skip-fetch "$id" 2
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on although origin cannot be fetched"
  assert_contains "$out" "could not fetch origin" "the refusal did not name the fetch"
  assert_contains "$out" "no copy was acquired" "the refusal did not say that no copy was taken"
  [ "$(cat "$CASE_DIR/get-count")" = 0 ] || fail "a copy was requested before the origin was known to be usable"
  assert_no_launch "$CASE_DIR/launch.log"
  ! grep -q '^lease ' "$SKIP_LOG" || fail "a lease was taken although no copy was acquired"
  pass "an unreachable origin refuses before any copy is acquired, leasing nothing"
}

# A copy that changes during the move (here a tracked edit appears between the proof and the merge) may hold
# work: the spawn keeps it, leases it where it stands, and launches nothing.
test_a_copy_that_changes_during_the_move_is_leased_where_it_stands() {
  local id out status real_git
  id='pool-skip-changes-during-move'
  make_skip_case skip-changes "$id" 2
  real_git=$(command -v git)
  cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
case "\$*" in *' merge --ff-only'*) printf 'late edit\n' >> '${SKIP_SLOTS[0]}/README.md' ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/git"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched on a copy that changed during the move"$'\n'"$out"
  assert_no_launch "$CASE_DIR/launch.log"
  assert_grep "lease --path ${SKIP_SLOTS[0]}" "$SKIP_LOG" "the changed copy was not leased where it stands"
  grep -q 'late edit' "${SKIP_SLOTS[0]}/README.md" || fail "the late edit is gone"
  [ "$(cat "$CASE_DIR/get-count")" = 1 ] || fail "a second copy was requested although the first one was changed under the move"
  pass "a copy that changes during the move is kept, leased where it stands, and nothing is launched"
}

test_a_nondefault_base_ref_does_not_move_before_a_skip() {
  local id out stale
  id='pool-skip-base-ref'
  make_skip_case skip-base-ref "$id" 2
  publish_feature_branch feature/hub
  git -C "$PROJECT_DIR" fetch --quiet origin
  stale=$INITIAL_SHA
  git -C "$PROJECT_DIR" update-ref refs/remotes/origin/feature/hub "$stale"
  printf 'unlanded\n' > "${SKIP_SLOTS[0]}/mine.txt"
  git -C "${SKIP_SLOTS[0]}" add mine.txt
  git -C "${SKIP_SLOTS[0]}" -c user.name=T -c user.email=t@example.invalid commit -qm unlanded
  brief_with_base "$id" feature/hub
  out=$(FM_TEST_LEASE_PROBE="git -C '$PROJECT_DIR' rev-parse refs/remotes/origin/feature/hub >'$CASE_DIR/probe'" \
    run_spawn "$id" --mode direct-PR --yolo off --base-branch feature/hub) || true
  [ -s "$CASE_DIR/probe" ] || fail "the first copy was never skipped"$'\n'"$out"
  [ "$(cat "$CASE_DIR/probe")" = "$stale" ] || fail "origin/feature/hub moved before the first copy was skipped"
  pass "a skip leaves a selected base's tracking ref as it was"
}

test_a_governed_attached_copy_keeps_its_branch_when_skipped() {
  local id out before
  id='pool-skip-governed-attached'
  make_governed_skip_case skip-governed-attached "$id"
  git -C "${SKIP_SLOTS[0]}" checkout --quiet -b previous-owner
  printf 'unlanded\n' > "${SKIP_SLOTS[0]}/mine.txt"
  git -C "${SKIP_SLOTS[0]}" add mine.txt
  git -C "${SKIP_SLOTS[0]}" -c user.name=T -c user.email=t@example.invalid commit -qm unlanded
  before=$(slot_digest "${SKIP_SLOTS[0]}") || fail "the slot could not be read before the spawn"
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn "$id" --mode no-mistakes --yolo off --owned-path scripts) || true
  [ "$(cat "$CASE_DIR/get-count")" -ge 2 ] || fail "no second copy was requested"$'\n'"$out"
  [ "$(git -C "${SKIP_SLOTS[0]}" symbolic-ref -q HEAD)" = refs/heads/previous-owner ] || fail "the skipped governed copy was left detached"
  # shellcheck disable=SC2046 # one word per "<ref>=<sha>" pair
  assert_digest_unchanged "${SKIP_SLOTS[0]}" "$before" "the skipped governed copy changed" $(second_copy_refs "$id" governed)
  pass "a skipped governed copy keeps its branch and every byte"
}

test_a_dirty_governed_copy_is_skipped_and_another_is_taken() {
  local id out
  id='pool-skip-governed-dirty'
  make_governed_skip_case skip-governed-dirty "$id"
  printf 'keep this local work\n' > "${SKIP_SLOTS[0]}/uncommitted.txt"
  out=$(FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn "$id" --mode no-mistakes --yolo off --owned-path scripts) || true
  assert_grep "lease --path ${SKIP_SLOTS[0]}" "$SKIP_LOG" "the dirty governed copy was not leased"
  [ "$(cat "$CASE_DIR/get-count")" -ge 2 ] || fail "a dirty governed copy refused the spawn instead of being skipped"$'\n'"$out"
  pass "a dirty governed copy is skipped like any other and another copy is requested"
}

test_the_loop_budget_is_one_bound_across_all_gets() {
  local id out
  id='pool-skip-budget'
  make_skip_case skip-budget "$id" 5
  for slot in "${SKIP_SLOTS[@]}"; do printf 'work\n' > "$slot/uncommitted.txt"; done
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_TICK_SECONDS=1000 BASH_ENV="$SKIP_CLOCK" run_spawn "$id" --mode no-mistakes --yolo off) || true
  assert_no_launch "$CASE_DIR/launch.log"
  [ "$(cat "$CASE_DIR/get-count")" -le 2 ] || fail "the loop went on to get $(cat "$CASE_DIR/get-count") copies past the absolute bound"$'\n'"$out"
  assert_contains "$out" "absolute extreme" "the refusal did not name the absolute bound"
  pass "one absolute bound covers every get in the skip loop"
}

# The bound is also read before a get is typed: when the time is spent between two gets (here, while the first
# skipped copy is recorded), no second get is typed at all.
test_no_get_is_typed_once_the_bound_was_spent_between_two_gets() {
  local id out
  id='pool-bound-between-gets'
  make_skip_case skip-bound-between "$id" 3
  printf 'work\n' > "${SKIP_SLOTS[0]}/uncommitted.txt"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_MKDIR_JUMP=2000 FM_TEST_MKDIR_JUMP_PATH="$HOME_DIR/data/$id" BASH_ENV="$SKIP_CLOCK" run_spawn "$id" --mode no-mistakes --yolo off) || true
  assert_no_launch "$CASE_DIR/launch.log"
  [ "$(cat "$CASE_DIR/get-count")" = 1 ] || fail "a get was typed after the absolute bound was spent: $(cat "$CASE_DIR/get-count") gets"$'\n'"$out"
  assert_contains "$out" "absolute extreme" "the refusal did not name the absolute bound"
  pass "no get is typed once the bound was spent between two gets"
}

test_skipped_copies_are_recorded_and_listed() {
  local id out
  id='pool-skip-listed'
  make_skip_case skip-listed "$id" 2
  printf 'keep this local work\n' > "${SKIP_SLOTS[0]}/uncommitted.txt"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  assert_contains "$out" "leased copies" "the spawn output did not list the copies it left leased"
  assert_contains "$out" "${SKIP_SLOTS[0]}" "the listing did not name the skipped copy"
  assert_grep "${SKIP_SLOTS[0]}" "$HOME_DIR/data/$id/skipped-copies.tsv" "the skipped copy was not recorded for its owner"
  assert_grep "firstmate-skipped:$id" "$HOME_DIR/data/$id/skipped-copies.tsv" "the record did not name the lease holder"
  pass "every copy a spawn leases is recorded and listed"
}

# --- finding 10 (validators) -----------------------------------------------------------------

test_slot_digest_sees_another_tasks_branch_move() {
  local id first next before rc=0
  id='pool-digest-foreign-ref'
  make_skip_case digest-foreign-ref "$id" 1
  git -C "$POOL_DIR" fetch --quiet origin
  first=$(git -C "$POOL_DIR" rev-parse HEAD)
  next=$(git -C "$POOL_DIR" rev-parse origin/main)
  git -C "$POOL_DIR" branch -q fm/other "$first"
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read"
  git -C "$POOL_DIR" update-ref refs/heads/fm/other "$next"
  (assert_digest_unchanged "$POOL_DIR" "$before" "foreign branch moved") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a move of another task's fm/ branch was accepted"
  pass "the slot check sees another task's fm/ branch move"
}

# Main 1823 D-B / F8: the digest compares the ref SET in both directions.
test_slot_digest_sees_a_new_foreign_ref() {
  local id first before rc=0
  id='pool-digest-new-ref'
  make_skip_case digest-new-ref "$id" 1
  first=$(git -C "$POOL_DIR" rev-parse HEAD)
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read"
  git -C "$POOL_DIR" update-ref refs/review/foreign "$first"
  (assert_digest_unchanged "$POOL_DIR" "$before" "new foreign ref") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a ref that did not exist before was accepted"
  pass "the slot check sees a ref that is new"
}

test_slot_digest_sees_a_removed_ref() {
  local id first before rc=0
  id='pool-digest-gone-ref'
  make_skip_case digest-gone-ref "$id" 1
  first=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" update-ref refs/review/foreign "$first"
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read"
  git -C "$POOL_DIR" update-ref -d refs/review/foreign
  (assert_digest_unchanged "$POOL_DIR" "$before" "removed ref") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "a ref that was removed was accepted"
  pass "the slot check sees a ref that is gone"
}

# The control for the two tests above: a ref named with its exact new value is the one change that is allowed.
test_slot_digest_accepts_only_the_named_ref_change() {
  local id first next before rc=0
  id='pool-digest-named-ref'
  make_skip_case digest-named-ref "$id" 1
  git -C "$POOL_DIR" fetch --quiet origin
  first=$(git -C "$POOL_DIR" rev-parse HEAD)
  next=$(git -C "$POOL_DIR" rev-parse origin/main)
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read"
  git -C "$POOL_DIR" update-ref refs/review/named "$first"
  (assert_digest_unchanged "$POOL_DIR" "$before" "named ref" "refs/review/named=$first") >/dev/null 2>&1 || fail "the named ref change was refused"
  git -C "$POOL_DIR" update-ref refs/review/named "$next"
  (assert_digest_unchanged "$POOL_DIR" "$before" "named ref, other value" "refs/review/named=$first") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the named ref was accepted at a value other than the one named"
  pass "the slot check accepts a named ref only at its named value"
}

test_slot_digest_sees_a_symlink_retarget() {
  local id before after
  id='pool-digest-symlink'
  make_skip_case digest-symlink "$id" 1
  printf 'equal\n' > "$POOL_DIR/first.txt"; cp "$POOL_DIR/first.txt" "$POOL_DIR/second.txt"
  ln -s first.txt "$POOL_DIR/link.txt"
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read"
  rm "$POOL_DIR/link.txt"; ln -s second.txt "$POOL_DIR/link.txt"
  after=$(slot_digest "$POOL_DIR") || fail "the slot could not be read"
  [ "$before" != "$after" ] || fail "a symlink retarget to a same-content file compared equal"
  pass "the slot digest sees a symlink that now points at another file"
}

test_slot_digest_fails_when_git_cannot_be_read() {
  local id bin out rc=0
  id='pool-digest-failclosed'
  make_skip_case digest-failclosed "$id" 1
  bin="$CASE_DIR/nogit"
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 128\n' > "$bin/git"
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" slot_digest "$POOL_DIR" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "the digest reported success although every git read failed: $out"
  pass "the slot digest fails when its git reads fail"
}

test_the_no_launch_check_fails_when_a_launch_was_logged() {
  local dir rc=0
  declare -F assert_no_launch >/dev/null || fail "assert_no_launch does not exist"
  dir="$TMP_ROOT/no-launch-check"
  mkdir -p "$dir"
  printf 'codex --yolo\n' > "$dir/launch.log"
  (assert_no_launch "$dir/launch.log") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "assert_no_launch accepted a log that records a launch"
  : > "$dir/empty.log"
  (assert_no_launch "$dir/empty.log") >/dev/null 2>&1 || fail "assert_no_launch rejected an empty launch log"
  pass "the no-launch check fails on a recorded launch and passes on none"
}

# --- review of 8c6c20ece (Main 027) -------------------------------------------------------------------------

# 5a. A copy on a stale submodule pin that also holds an unlanded superproject commit is not abandoned after one get:
# it is leased, left as found, and another copy is taken.
test_a_stale_submodule_copy_with_an_unlanded_commit_is_leased_and_another_is_taken() {
  local rec seed id out before slot2
  seed='pool-stale-seed'
  id='pool-stale-skip'
  rec=$(make_submodule_case stale-skip "$seed")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn "$seed"
  printf 'unlanded superproject work\n' > "$POOL_DIR/mine.txt"
  git -C "$POOL_DIR" add mine.txt
  git -C "$POOL_DIR" -c user.name=T -c user.email=t@example.invalid commit -qm unlanded
  slot2="$CASE_DIR/pool2"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$slot2" HEAD
  git -C "$slot2" -c protocol.file.allow=always submodule --quiet update --init
  fm_test_spawn_brief "$HOME_DIR" "$id"
  SKIP_SLOTS=("$POOL_DIR" "$slot2")
  make_skip_transport
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read before the spawn"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn_skipping "$id" --mode no-mistakes --yolo off) || true
  assert_grep "lease --path $POOL_DIR" "$SKIP_LOG" "the stale copy holding an unlanded commit was not leased"$'\n'"$out"
  [ "$(cat "$CASE_DIR/get-count")" -ge 2 ] || fail "a second copy was not requested after the first was set aside"
  assert_digest_unchanged "$POOL_DIR" "$before" "the stale copy changed"
  pass "a stale-submodule copy with an unlanded commit is leased where it stands and another copy is requested"
}

# 5b. The absolute bound is checked before a copy is accepted: a jump of the whole bound between the two agreeing
# reads must stop the spawn, not launch it.
test_the_bound_is_checked_before_a_copy_is_accepted() {
  local rec id out status
  id='pool-bound-before-accept'
  rec=$(make_case bound-before-accept "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_TICK_SECONDS=1800 BASH_ENV="$SKIP_CLOCK" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a copy after the absolute bound was spent"$'\n'"$out"
  assert_contains "$out" "absolute extreme" "the refusal did not name the absolute bound"
  assert_no_launch "$CASE_DIR/launch.log"
  pass "the absolute bound is enforced before a copy is accepted"
}

# Main 1823 D-D / F6: the bound is read again immediately before the copy is accepted. The clock jumps to the very
# second the bound ends (1800 of 1800) at the moment the second agreeing read would accept the copy.
test_the_bound_is_rechecked_just_before_a_copy_is_accepted() {
  local rec id out status
  id='pool-bound-at-accept'
  rec=$(make_case bound-at-accept "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_JUMP_AT_ACCEPT=1800 BASH_ENV="$SKIP_CLOCK" run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a copy at the second the absolute bound ended"$'\n'"$out"
  pass "the absolute bound is enforced at the moment a copy would be accepted"
}

test_the_bound_refusal_at_accept_launches_nothing() {
  local rec id out
  id='pool-bound-at-accept-none'
  rec=$(make_case bound-at-accept-none "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_JUMP_AT_ACCEPT=1800 BASH_ENV="$SKIP_CLOCK" run_spawn "$id" --mode no-mistakes --yolo off) || true
  assert_no_launch "$CASE_DIR/launch.log"
  pass "no harness is launched when the bound ends as a copy would be accepted"
}

# The control: ten seconds inside the bound, the same copy is accepted and launched.
test_a_copy_accepted_inside_the_bound_is_launched() {
  local rec id out
  id='pool-bound-inside'
  rec=$(make_case bound-inside "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_JUMP_AT_ACCEPT=1790 BASH_ENV="$SKIP_CLOCK" run_spawn "$id" --mode no-mistakes --yolo off) || fail "the spawn failed inside the bound"$'\n'"$out"
  [ -s "$CASE_DIR/launch.log" ] || fail "no harness was launched for a copy accepted inside the bound"$'\n'"$out"
  pass "a copy accepted inside the bound is launched"
}

# Main 1823 D-B / F3: git refuses the move. A refused move writes no ref anywhere: the origin tracking refs this spawn
# resolved are recorded only after a move that succeeded.
test_a_refused_move_leaves_every_ref_unchanged() {
  local id real_git before
  id='pool-refused-refs'
  make_skip_case refused-refs "$id" 1
  real_git=$(command -v git)
  cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
case " \$* " in *' merge --ff-only '*) exit 1 ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/git"
  before=$(slot_digest "$POOL_DIR") || fail "the slot could not be read before the spawn"
  FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" run_spawn_skipping "$id" --mode no-mistakes --yolo off >/dev/null 2>&1 || true
  assert_digest_unchanged "$POOL_DIR" "$before" "a refused move changed a ref"
  pass "a refused move leaves every ref as it found it"
}

# 2 (spawn level). A governed copy that git refuses to move after the preparation detached it is not reported as
# untouched: its branch is as found, or the output says it was detached.
# Main 1829: git refuses the move after the preparation detached a governed copy. The detach is undone by ref (no file is
# touched) because the proof holds, so the previous owner's branch is checked out again and is where it was.
refuse_governed_after_preparation() { # <name> <id>; sets GOV_OUT
  local name=$1 id=$2 real_git
  make_governed_skip_case "$name" "$id"
  git -C "${SKIP_SLOTS[0]}" checkout --quiet -b previous-owner
  real_git=$(command -v git)
  cat > "$FAKEBIN_DIR/git" <<SH
#!/usr/bin/env bash
case " \$* " in *' merge --ff-only '*) exit 1 ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/git"
  GOV_OUT=$(FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" run_spawn_skipping "$id" --mode no-mistakes --yolo off --owned-path scripts) || true
}

test_a_governed_refusal_after_preparation_puts_the_branch_back() {
  refuse_governed_after_preparation governed-refused-prep pool-governed-refused-after-prep
  [ "$(git -C "${SKIP_SLOTS[0]}" symbolic-ref -q HEAD)" = refs/heads/previous-owner ] || fail "the previous owner's branch was not put back"$'\n'"$GOV_OUT"
  pass "a governed copy refused after preparation has its branch back"
}

test_a_governed_refusal_after_preparation_keeps_its_branch_where_it_was() {
  local before after
  refuse_governed_after_preparation governed-refused-branch pool-governed-refused-branch
  after=$(git -C "${SKIP_SLOTS[0]}" rev-parse refs/heads/previous-owner)
  [ "$after" = "$INITIAL_SHA" ] || fail "the previous owner's branch moved to $after"$'\n'"$GOV_OUT"
  pass "the branch the preparation detached from is where it was"
}

# Explicit selection keeps focused acquisition regressions independently runnable.
if [ "$#" -gt 0 ]; then
  for selected_test in "$@"; do
    case "$selected_test" in
      test_freshness_introduces_slot_owner|test_freshness_introduces_scout_slot_owner|test_freshness_slot_owner_requires_scope|test_freshness_present_slot_owner_refuses|test_freshness_absent_slot_owner_launches|test_freshness_removed_slot_owner_refuses|test_local_only_source_selection|test_local_only_source_binding|test_local_only_unprepared_retry|test_local_only_origin_early|test_local_only_origin_late|test_local_only_origin_freshness|test_local_only_origin_copy_missing|test_local_only_origin_primary_missing|test_local_only_equal_retry_selects_local|test_local_only_equal_retry_divergence|test_local_only_adopted_scope_retry|test_local_only_equal_retry_invalid_ref|test_legacy_relaunch_scope_adoption) "$selected_test" ;;
      test_*) if declare -F "$selected_test" >/dev/null 2>&1; then "$selected_test"; else fail "unknown selected test: $selected_test"; fi ;;
      *) fail "unknown selected acquisition test: $selected_test" ;;
    esac
  done
  exit 0
fi

test_local_only_source_selection
test_local_only_source_binding
test_local_only_unprepared_retry
test_local_only_equal_retry_selects_local
test_local_only_equal_retry_divergence
test_local_only_adopted_scope_retry
test_local_only_equal_retry_invalid_ref
test_legacy_relaunch_scope_adoption
test_local_only_origin_early
test_local_only_origin_late
test_local_only_origin_freshness
test_local_only_origin_copy_missing
test_local_only_origin_primary_missing
test_freshness_introduces_slot_owner
test_freshness_introduces_scout_slot_owner
test_freshness_slot_owner_requires_scope
test_freshness_present_slot_owner_refuses
test_freshness_absent_slot_owner_launches
test_freshness_removed_slot_owner_refuses
test_remote_seeded_home_spawns_from_treehouse_pool
test_pool_slot_claim_follows_the_spawn_outcome
test_linked_spawning_home_rejects_primary_before_refresh
test_stale_pool_base_refreshes_before_branching
test_named_base_branch_starts_from_that_branch
test_base_branch_must_agree_with_the_brief
test_prose_base_branch_line_is_ignored
test_scout_base_branch_refused_on_gerrit_forge
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_originless_pool_launches_without_a_freshness_fetch
test_originless_dirty_pool_refuses_without_discarding_work
test_origin_config_without_url_refuses_pool
test_empty_origin_config_section_refuses_pool
test_empty_only_included_origin_config_section_launches_pool
test_inactive_conditional_origin_include_launches_pool
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict
test_a_skipped_dirty_copy_is_left_as_found_and_another_is_taken
test_a_skipped_copy_with_an_unlanded_commit_keeps_it_and_another_is_taken
test_no_other_copy_refuses_and_names_the_skipped_one
test_a_skip_that_cannot_lease_the_copy_stops_without_asking_for_another
test_an_originless_copy_with_a_live_holder_is_skipped
test_an_unreachable_origin_refuses_before_any_copy_is_taken
test_a_copy_that_changes_during_the_move_is_leased_where_it_stands
test_a_nondefault_base_ref_does_not_move_before_a_skip
test_a_governed_attached_copy_keeps_its_branch_when_skipped
test_a_dirty_governed_copy_is_skipped_and_another_is_taken
test_the_loop_budget_is_one_bound_across_all_gets
  test_no_get_is_typed_once_the_bound_was_spent_between_two_gets
test_skipped_copies_are_recorded_and_listed
test_slot_digest_sees_another_tasks_branch_move
test_slot_digest_sees_a_new_foreign_ref
test_slot_digest_sees_a_removed_ref
test_slot_digest_accepts_only_the_named_ref_change
test_slot_digest_sees_a_symlink_retarget
test_slot_digest_fails_when_git_cannot_be_read
test_the_no_launch_check_fails_when_a_launch_was_logged
test_a_stale_submodule_copy_with_an_unlanded_commit_is_leased_and_another_is_taken
test_the_bound_is_checked_before_a_copy_is_accepted
test_the_bound_is_rechecked_just_before_a_copy_is_accepted
test_the_bound_refusal_at_accept_launches_nothing
test_a_copy_accepted_inside_the_bound_is_launched
test_a_refused_move_leaves_every_ref_unchanged
test_a_governed_refusal_after_preparation_puts_the_branch_back
test_a_governed_refusal_after_preparation_keeps_its_branch_where_it_was

echo "# all fm-spawn-pool-base-freshen tests passed"
