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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding an unpushed submodule commit"
  assert_contains "$out" "refusing to discard uncommitted work" \
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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding work inside a submodule"
  assert_contains "$out" "refusing to discard uncommitted work" \
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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin and work inside it"
  assert_contains "$out" "refusing to discard uncommitted work" \
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

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin beside an untracked file"
  assert_contains "$out" "refusing to discard uncommitted work" \
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
          [ "$(git -C "$pool" rev-parse HEAD)" = "$before" ] || fail 'early governed refusal lost original checkout'
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
    [ "$(git -C "$pool" branch --show-current)" = previous-owner ] || fail 'refusal did not restore the previous checkout'
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
  out=$(run_spawn "$id" "${args[@]}" 2>&1) || rc=$?
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
    printf 'preserve pre-existing assigned work\n' > "$POOL_DIR/README.md"
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
    printf 'operator scratch\n' > "$POOL_DIR/scratch.txt"
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

# --- Reset guard (S0-S7): fm-spawn proves a pooled slot holds no unique work
# before its destroying reset. Every case runs on scratch repositories.
#
# S7: guard_snapshot records HEAD, every ref, the index, the status and a
# path-sorted sha256 of every file outside .git (tracked, untracked and ignored).
# A refusal must leave all of it equal; equal status is not equal work.
guard_snapshot() { # <slot> <out>
  local slot=$1 out=$2
  {
    printf 'HEAD %s\n' "$(git -C "$slot" rev-parse HEAD)"
    printf 'SYMREF %s\n' "$(git -C "$slot" symbolic-ref -q HEAD || echo detached)"
    printf '%s\n' '--- show-ref'
    # A snapshot taken by the seam while the spawn runs also sees the spawn's own private
    # refs/fm/spawn-base/* ref, which the spawn deletes at exit; the before/after snapshots
    # show it absent, so only that ref family is left out here.
    git -C "$slot" show-ref | grep -v ' refs/fm/spawn-base/'
    printf '%s\n' '--- index'
    git -C "$slot" ls-files -s --debug
    printf '%s\n' '--- status'
    git -C "$slot" status --porcelain=v1 --untracked-files=all --ignored
    printf '%s\n' '--- files'
    (
      cd "$slot" || exit 1
      find . -name .git -prune -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
        if [ -L "$f" ]; then
          printf 'L %s -> %s\n' "$f" "$(readlink "$f")"
        else
          printf '%s  %s\n' "$(shasum -a 256 <"$f" | cut -d' ' -f1)" "$f"
        fi
      done
    )
  } >"$out" 2>&1
}
export -f guard_snapshot

# The S7 witness: one dirty file changes its bytes while HEAD, refs and porcelain
# status stay equal. The comparison must see it.
test_reset_guard_snapshot_witness() {
  local rec id before after
  id='guard-witness-s7'
  rec=$(make_case guard-witness "$id")
  read_case_record "$rec"
  printf 'AAAA\n' >"$POOL_DIR/dirty.txt"
  guard_snapshot "$POOL_DIR" "$CASE_DIR/before.snap"
  printf 'BBBB\n' >"$POOL_DIR/dirty.txt"
  guard_snapshot "$POOL_DIR" "$CASE_DIR/after.snap"
  cmp -s "$CASE_DIR/before.snap" "$CASE_DIR/after.snap" \
    && fail 'the snapshot comparison could not see a changed dirty file with equal status'
  [ "$(sed -n '/--- status/,/--- files/p' "$CASE_DIR/before.snap")" = "$(sed -n '/--- status/,/--- files/p' "$CASE_DIR/after.snap")" ] \
    || fail 'the witness changed the porcelain status'
  [ "$(sed -n '1,/--- index/p' "$CASE_DIR/before.snap")" = "$(sed -n '1,/--- index/p' "$CASE_DIR/after.snap")" ] \
    || fail 'the witness changed HEAD or refs'
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'EVIDENCE S7 witness: status equal, HEAD equal, refs equal, file digest differs; diff=%s\n' \
      "$(diff "$CASE_DIR/before.snap" "$CASE_DIR/after.snap" | tr '\n' '|')"
  fi
  pass 'the S7 snapshot comparison detects changed bytes under equal status'
}

# Run one blocking case: spawn, then require a non-zero exit, no launch, the
# named reason and the slot path in the message, and an identical snapshot.
# $1 = fact, $2 = case label, $3 = reason code, $4 = task id, $5.. = spawn args.
# Sets GUARD_OUT. The caller has already set CASE_DIR, HOME_DIR and POOL_DIR.
guard_expect_refusal() {
  local fact=$1 label=$2 code=$3 id=$4 status=0 reference
  shift 4
  guard_snapshot "$POOL_DIR" "$CASE_DIR/before.snap"
  GUARD_OUT=$(run_spawn "$id" "$@") || status=$?
  guard_snapshot "$POOL_DIR" "$CASE_DIR/after.snap"
  [ "$status" -ne 0 ] || fail "$fact $label: the spawn launched on a slot that should refuse"$'\n'"$GUARD_OUT"
  assert_contains "$GUARD_OUT" "$code" "$fact $label: the refusal did not name $code"$'\n'"$GUARD_OUT"
  assert_contains "$GUARD_OUT" "$POOL_DIR" "$fact $label: the refusal did not name the slot path"
  if [ ! -s "$CASE_DIR/launch.log" ] && [ -e "$HOME_DIR/state/$id.meta" ] &&
    ! grep -q '^recovery=slot-provision-refused' "$HOME_DIR/state/$id.meta"; then
    fail "$fact $label: a worker record was published"
  fi
  # A transition case changes the slot itself after the first observation; the
  # refusal must then leave exactly that state (the seam records it as post-seam.snap).
  reference="$CASE_DIR/before.snap"
  [ ! -f "$CASE_DIR/post-seam.snap" ] || reference="$CASE_DIR/post-seam.snap"
  if ! cmp -s "$reference" "$CASE_DIR/after.snap"; then
    diff "$reference" "$CASE_DIR/after.snap" >&2 || true
    fail "$fact $label: the refusal changed the slot (HEAD, refs, index or file bytes)"
  fi
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'EVIDENCE %s | %s | exit=%s | reason=%s | slot=%s | HEAD+refs+index+files equal=yes (%s sha256 of before.snap)\n' \
      "$fact" "$label" "$status" "$code" "$POOL_DIR" "$(shasum -a 256 <"$CASE_DIR/before.snap" | cut -c1-16)"
    printf 'EVIDENCE   message: %s\n' "$(printf '%s\n' "$GUARD_OUT" | grep -F 'reset refused' | head -n 1 | cut -c1-300)"
  fi
}

# A pass case: the spawn launches and the slot reaches the origin tip.
guard_expect_launch() {
  local fact=$1 label=$2 id=$3 status=0
  shift 3
  GUARD_OUT=$(run_spawn "$id" "$@") || status=$?
  expect_code 0 "$status" "$fact $label: a slot with clear evidence should launch"$'\n'"$GUARD_OUT"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'EVIDENCE %s | %s | exit=0 | launched, slot HEAD now %s\n' "$fact" "$label" "$(git -C "$POOL_DIR" rev-parse --short HEAD)"
  fi
}

# A governed spawn anchors a detached HEAD (refs/fm/anchor/<task>-<sha>, a ref that only
# preserves the commit) before the late refusals of S5b; nothing else may differ from the
# state before the spawn.
guard_assert_only_anchor_added() { # <label>
  local extra
  extra=$(diff "$CASE_DIR/before.snap" "$CASE_DIR/after.snap" | grep '^[<>]' | grep -v ' refs/fm/anchor/' || true)
  [ -z "$extra" ] || fail "$1: the refusal changed more than the preservation anchor: $extra"
}

guard_prefetch() { git -C "$PROJECT_DIR" fetch --quiet origin; }

guard_commit() { # <repo> <message>
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m "$2"
}

# A fake git that fails when FM_TEST_GIT_FAIL appears among the arguments.
guard_install_git_shim() { # <fakebin>
  local real
  real=$(command -v git)
  cat >"$1/git" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_TEST_GIT_FAIL:-}" ]; then
  case " \$* " in
    *" \${FM_TEST_GIT_FAIL} "*) echo "fixture: injected git failure" >&2; exit 128 ;;
  esac
fi
exec "$real" "\$@"
SH
  chmod +x "$1/git"
}

# A PATH identical to the current one except that the tool is gone: every other
# executable of the directory that held it is linked into a private directory.
guard_path_without() { # <tool> <dir>
  local tool=$1 dir=$2 holder entry new_path='' part found
  mkdir -p "$dir"
  while IFS= read -r part; do
    found=0
    if [ -x "$part/$tool" ]; then
      found=1
      for entry in "$part"/*; do
        [ -x "$entry" ] && [ "${entry##*/}" != "$tool" ] || continue
        [ -e "$dir/${entry##*/}" ] || ln -s "$entry" "$dir/${entry##*/}"
      done
      holder=$dir
    fi
    if [ "$found" = 1 ]; then part=$holder; fi
    case ":$new_path:" in *":$part:"*) ;; *) new_path="${new_path:+$new_path:}$part" ;; esac
  done < <(printf '%s' "$PATH" | tr ':' '\n')
  printf '%s' "$new_path"
}

# A governed project: a provisioner stub makes the project governed, so its
# lifecycle manifest, lease store and contention log count.
make_guard_governed_case() { # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin initial
  fm_git_identity
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home" project="$case_dir/project" origin="$case_dir/origin.git"
  pool="$case_dir/pool" publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" codex)
  fm_test_fake_no_mistakes "$fakebin"
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  fm_test_spawn_home "$home" codex
  printf 'manual\n' >"$home/config/backlog-backend"
  fm_test_spawn_brief "$home" "$id"
  fm_git_init_commit "$project"
  write_passing_slot_owner "$project"
  git -C "$project" add scripts
  git -C "$project" commit -qm 'governed copy'
  fm_git_add_origin "$project" "$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  initial=$(git -C "$pool" rev-parse HEAD)
  git clone --quiet "file://$origin" "$publisher"
  printf 'advanced\n' >"$publisher/advanced.txt"
  git -C "$publisher" add .
  git -C "$publisher" commit -qm 'advance origin'
  git -C "$publisher" push --quiet origin main
  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|main"
}

run_governed_spawn() { # <id> [<arg>...]
  local id=$1
  shift
  FM_TEST_PROVISION_CALLED="$CASE_DIR/provisioner.called" FM_TEST_SLOT_RECORD="$CASE_DIR/slot-record.json" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --backend tmux --scout --owned-path scripts "$@"
}

# Place the slot's lifecycle manifest where the governed project keeps it.
GUARD_MANIFEST_FILE=
guard_write_manifest() { # <branch-or--> <base-sha> [<raw-bytes>]
  local common real name
  common=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-common-dir)
  real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$POOL_DIR")
  name="$(printf '%s' "$real" | shasum -a 256 | cut -c1-16).json"
  mkdir -p "$common/vernant-worktree-lifecycle"
  GUARD_MANIFEST_FILE="$common/vernant-worktree-lifecycle/$name"
  if [ "$#" -ge 3 ]; then
    printf '%s' "$3" >"$GUARD_MANIFEST_FILE"
  else
    python3 - "$GUARD_MANIFEST_FILE" "$1" "$2" "$real" <<'PY'
import json, sys
path, branch, base, real = sys.argv[1:5]
json.dump({"schema_version": "1.1.0", "lifecycle_state": "worktree_active", "worktree_path": real,
           "branch": None if branch == "-" else branch, "base_sha": base, "owner_id": "previous"},
          open(path, "w"))
PY
  fi
}

guard_iso_ago() { # <hours>
  python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).isoformat())' "$1"
}

# ---- S1: HEAD contained -------------------------------------------------------
test_reset_guard_s1_detached_extra_commit() {
  local rec id extra
  id='guard-s1-extra-commit'
  rec=$(make_case guard-s1 "$id")
  read_case_record "$rec"
  guard_commit "$POOL_DIR" 'unique work on a detached HEAD'
  extra=$(git -C "$POOL_DIR" rev-parse HEAD)
  guard_expect_refusal S1 'detached HEAD with one extra commit' 'reset refused (head_not_contained)' "$id" --scout
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$extra" ] || fail 'the extra commit is no longer the slot HEAD'
  pass 'S1: a detached HEAD with an uncontained commit is refused and keeps its commit'
}

# ---- S2: owner branch tip contained ---------------------------------------------
test_reset_guard_s2_attached_branch() {
  local rec id tip
  id='guard-s2-attached'
  rec=$(make_case guard-s2a "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -b owner-topic
  guard_commit "$POOL_DIR" 'unique work on the owner branch'
  tip=$(git -C "$POOL_DIR" rev-parse refs/heads/owner-topic)
  guard_expect_refusal S2 'slot attached to a branch with one uncontained commit' 'reset refused (owner_branch_not_contained)' "$id" --scout
  [ "$(git -C "$POOL_DIR" rev-parse refs/heads/owner-topic)" = "$tip" ] || fail 'the owner branch ref moved'
  # Paired pass: the same attached branch, fully contained.
  id='guard-s2-attached-contained'
  rec=$(make_case guard-s2b "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -b owner-topic
  tip=$(git -C "$POOL_DIR" rev-parse HEAD)
  guard_expect_launch S2 'the same attached branch fully contained' "$id" --scout
  git -C "$POOL_DIR" merge-base --is-ancestor "$tip" refs/heads/owner-topic || fail 'the contained branch lost its old tip'
  pass 'S2: an attached owner branch is refused with an uncontained commit and passes when contained'
}

test_reset_guard_s2_manifest_branch() {
  local rec id tip
  id='guard-s2-manifest'
  rec=$(make_guard_governed_case guard-s2m "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" checkout --quiet -b previous-owner
  guard_commit "$POOL_DIR" 'unique work on the manifest branch'
  tip=$(git -C "$POOL_DIR" rev-parse HEAD)
  git -C "$POOL_DIR" checkout --quiet --detach "$INITIAL_SHA"
  guard_write_manifest previous-owner "$INITIAL_SHA"
  guard_expect_refusal S2 'detached slot whose manifest branch has one uncontained commit' 'reset refused (owner_branch_not_contained)' "$id" --scout --owned-path scripts
  [ "$(git -C "$POOL_DIR" rev-parse refs/heads/previous-owner)" = "$tip" ] || fail 'the manifest branch ref moved'
  # Paired pass: the same branch name, fully contained.
  id='guard-s2-manifest-contained'
  rec=$(make_guard_governed_case guard-s2n "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" branch previous-owner "$INITIAL_SHA"
  guard_write_manifest previous-owner "$INITIAL_SHA"
  GUARD_OUT=$(run_governed_spawn "$id") || fail "S2: the contained manifest branch refused: $GUARD_OUT"
  pass 'S2: a manifest owner branch is refused with an uncontained commit and passes when contained'
}

# The recorded base is an anchor: HEAD contained only in the manifest's base_sha passes.
test_reset_guard_s1_manifest_base_anchor() {
  local rec id
  id='guard-s1-base-anchor'
  rec=$(make_guard_governed_case guard-s1b "$id")
  read_case_record "$rec"
  guard_commit "$POOL_DIR" 'work contained only in the recorded base'
  git -C "$POOL_DIR" branch recorded-base HEAD
  guard_write_manifest - "$(git -C "$POOL_DIR" rev-parse HEAD)"
  GUARD_OUT=$(run_governed_spawn "$id") || fail "S1: HEAD contained in the recorded base refused: $GUARD_OUT"
  # Without that manifest the same HEAD is uncontained.
  id='guard-s1-no-base-anchor'
  rec=$(make_guard_governed_case guard-s1c "$id")
  read_case_record "$rec"
  guard_commit "$POOL_DIR" 'work contained nowhere'
  guard_expect_refusal S1 'governed slot, HEAD in neither origin nor a recorded base' 'reset refused (head_not_contained)' "$id" --scout --owned-path scripts
  pass 'S1: the manifest base_sha is an anchor, and without it uncontained HEAD still refuses'
}

# ---- S3: clean tree -----------------------------------------------------------------
test_reset_guard_s3_dirty_kinds() {
  local rec id kind
  for kind in modified staged untracked-in-new-dir; do
    id="guard-s3-$kind"
    rec=$(make_case "guard-s3-$kind" "$id")
    read_case_record "$rec"
    case "$kind" in
      modified) printf 'edit\n' >>"$POOL_DIR/README.md" ;;
      staged) printf 'staged\n' >"$POOL_DIR/staged.txt"; git -C "$POOL_DIR" add staged.txt ;;
      untracked-in-new-dir) mkdir -p "$POOL_DIR/new/dir"; printf 'untracked\n' >"$POOL_DIR/new/dir/file.txt" ;;
    esac
    guard_expect_refusal S3 "$kind" 'is not clean' "$id" --scout
    assert_contains "$GUARD_OUT" 'reset refused: tree_not_clean' "S3 $kind: the refusal did not name tree_not_clean"
  done
  pass 'S3: a modified, staged or untracked-in-new-directory slot is refused untouched'
}

# ---- S3b: ignored work at a path the reset target tracks -------------------------------
guard_publish_tracked() { # <path> <content>   publish a file the reset target will track
  mkdir -p "$(dirname "$CASE_DIR/publisher/$1")"
  printf '%s' "$2" >"$CASE_DIR/publisher/$1"
  git -C "$CASE_DIR/publisher" add "$1"
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "track $1"
  git -C "$CASE_DIR/publisher" push --quiet origin main
}

guard_ignore() { # <pattern>   ignore it in every worktree of the project
  printf '%s\n' "$1" >>"$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path info/exclude)"
}

test_reset_guard_s3b_same_path() {
  local rec id
  id='guard-s3b-same-path'
  rec=$(make_case guard-s3b-i "$id")
  read_case_record "$rec"
  guard_ignore notes.local
  printf 'private notes the target tracks something else at\n' >"$POOL_DIR/notes.local"
  guard_publish_tracked notes.local $'tracked content\n'
  guard_expect_refusal S3b '(i) same path, ignored, tracked by the target, unarchived' 'reset refused (ignored_collision)' "$id" --scout
  assert_grep 'private notes' "$POOL_DIR/notes.local" 'the ignored file bytes changed'
  pass 'S3b (i): an ignored file at a path the target tracks is refused and keeps its bytes'
}

test_reset_guard_s3b_ancestor_path() {
  local rec id
  id='guard-s3b-ancestor'
  rec=$(make_case guard-s3b-ib "$id")
  read_case_record "$rec"
  guard_ignore notes.local
  printf 'a regular ignored file the target needs as a directory\n' >"$POOL_DIR/notes.local"
  guard_publish_tracked notes.local/entry.txt $'entry\n'
  guard_expect_refusal S3b '(i-b) ignored regular file is an ancestor of a tracked target path' 'reset refused (ignored_collision)' "$id" --scout
  [ -f "$POOL_DIR/notes.local" ] || fail 'the ignored file was replaced by a directory'
  assert_grep 'regular ignored file' "$POOL_DIR/notes.local" 'the ignored file bytes changed'
  pass 'S3b (i-b): an ignored file that is an ancestor of a tracked target path is refused and keeps its bytes'
}

test_reset_guard_s3b_inside_tracked_file() {
  local rec id
  id='guard-s3b-inside'
  rec=$(make_case guard-s3b-ic "$id")
  read_case_record "$rec"
  guard_ignore cache.d
  mkdir -p "$POOL_DIR/cache.d"
  printf 'ignored content inside a directory the target tracks as a file\n' >"$POOL_DIR/cache.d/entry.txt"
  guard_publish_tracked cache.d $'tracked file\n'
  guard_expect_refusal S3b '(i-c) ignored entry lies inside a path the target tracks as a file' 'reset refused (ignored_collision)' "$id" --scout
  assert_grep 'ignored content inside' "$POOL_DIR/cache.d/entry.txt" 'the ignored file bytes changed'
  pass 'S3b (i-c): an ignored entry inside a tracked target path is refused and keeps its bytes'
}

test_reset_guard_s3b_control_no_collision() {
  local rec id
  id='guard-s3b-control'
  rec=$(make_case guard-s3b-ii "$id")
  read_case_record "$rec"
  guard_ignore local-only.note
  printf 'untouched ignored bytes\n' >"$POOL_DIR/local-only.note"
  guard_expect_launch S3b '(ii) control: an ignored file at a path the target does not track' "$id" --scout
  assert_grep 'untouched ignored bytes' "$POOL_DIR/local-only.note" 'the non-colliding ignored file changed bytes after the reset'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/main)" ] || fail 'the control did not reset to origin'
  pass 'S3b (ii): an ignored file the target does not track passes and keeps its bytes after the reset'
}

test_reset_guard_s3b_scratch_and_archive() {
  local rec id sums
  # A colliding entry the existing classifier calls scratch does not refuse.
  id='guard-s3b-scratch'
  rec=$(make_case guard-s3b-scratch "$id")
  read_case_record "$rec"
  guard_ignore .DS_Store
  printf 'scratch\n' >"$POOL_DIR/.DS_Store"
  guard_publish_tracked .DS_Store $'tracked\n'
  guard_expect_launch S3b 'a colliding ignored entry the classifier calls scratch' "$id" --scout
  # A verified archive holding the exact bytes lets a colliding entry pass; other bytes do not.
  id='guard-s3b-archived'
  rec=$(make_case guard-s3b-archived "$id")
  read_case_record "$rec"
  guard_ignore notes.local
  printf 'archived notes\n' >"$POOL_DIR/notes.local"
  guard_publish_tracked notes.local $'tracked\n'
  mkdir -p "$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag"
  cp "$POOL_DIR/notes.local" "$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag/notes.local"
  sums="$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag/SHA256SUMS"
  (cd "$POOL_DIR" && shasum -a 256 -- notes.local) >"$sums"
  guard_expect_launch S3b 'a colliding ignored entry held by a verified archive' "$id" --scout
  id='guard-s3b-archive-mismatch'
  rec=$(make_case guard-s3b-mismatch "$id")
  read_case_record "$rec"
  guard_ignore notes.local
  printf 'newer notes\n' >"$POOL_DIR/notes.local"
  guard_publish_tracked notes.local $'tracked\n'
  mkdir -p "$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag"
  printf 'older notes\n' >"$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag/notes.local"
  (cd "$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag" && shasum -a 256 -- notes.local) \
    | sed 's|notes.local|notes.local|' >"$HOME_DIR/data/earlier-task/merge-prune-preserved/20261101/tag/SHA256SUMS"
  guard_expect_refusal S3b 'an archive that does not hold the current bytes' 'reset refused (ignored_collision)' "$id" --scout
  pass 'S3b: classifier-scratch and a verified matching archive pass; a mismatching archive refuses'
}

test_reset_guard_s3b_inventory_failure() {
  local rec id
  id='guard-s3b-inventory'
  rec=$(make_case guard-s3b-iii "$id")
  read_case_record "$rec"
  guard_install_git_shim "$FAKEBIN_DIR"
  guard_prefetch
  FM_TEST_GIT_FAIL='ls-files -o -i' guard_expect_refusal S3b '(iii) the ignored-entry inventory fails' 'reset refused (unknown_ignored_inventory)' "$id" --scout
  pass 'S3b (iii): an unreadable ignored-entry inventory refuses untouched'
}

# ---- S4: no live holder -----------------------------------------------------------------
test_reset_guard_s4_cwd_holder() {
  local rec id holder
  id='guard-s4-cwd'
  rec=$(make_case guard-s4i "$id")
  read_case_record "$rec"
  (cd "$POOL_DIR" && exec sleep 600) &
  holder=$!
  guard_expect_refusal S4 '(i) an unrelated process has its cwd in the slot' 'reset refused (holder_cwd)' "$id" --scout
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  guard_expect_launch S4 '(i) paired pass: the holder has exited' "$id" --scout
  pass 'S4 (i): a foreign process with its cwd in the slot refuses, and passes once it exits'
}

test_reset_guard_s4_worktree_lock() {
  local rec id
  id='guard-s4-lock'
  rec=$(make_case guard-s4ii "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" worktree lock --reason 'held by a foreign holder' "$POOL_DIR"
  guard_expect_refusal S4 '(ii) a git worktree lock is on the slot' 'reset refused (holder_worktree_lock)' "$id" --scout
  git -C "$PROJECT_DIR" worktree unlock "$POOL_DIR"
  guard_expect_launch S4 '(ii) paired pass: the lock is released' "$id" --scout
  pass 'S4 (ii): a git worktree lock refuses, and passes once released'
}

test_reset_guard_s4_foreign_lease() {
  local rec id state
  id='guard-s4-lease'
  rec=$(make_case guard-s4iii "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  state="$CASE_DIR/slots/treehouse-state.json"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"another-task"}]}\n' "$POOL_DIR" >"$state"
  guard_expect_refusal S4 '(iii) a durable lease held by another holder' 'reset refused (holder_lease)' "$id" --scout
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$POOL_DIR" >"$state"
  guard_expect_launch S4 '(iii) paired pass: the lease is released' "$id" --scout
  pass 'S4 (iii): a foreign durable lease refuses, and passes once released'
}

# A process lease is this spawn's own only by the identity recorded when it took the slot
# (the pool entry's owner_pid at claim time), never by process ancestry.
guard_set_lease_owner() { # <state-file> <pid>
  jq --argjson pid "$2" '.worktrees[0].owner_pid = $pid' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

test_reset_guard_s4_process_lease_recorded_identity() {
  local rec id state own other shell child
  # The entry's owner at claim time is the spawn's own acquisition: it passes though that
  # process is alive and in no lineage of the spawn.
  id='guard-s4-lease-recorded'
  rec=$(make_case guard-s4lrec "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  state="$CASE_DIR/slots/treehouse-state.json"
  (cd / && exec sleep 600) >/dev/null 2>&1 </dev/null &
  own=$!
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' "$POOL_DIR" "$own" >"$state"
  guard_expect_launch S4 '(iii-b) the live process lease recorded as this spawn'"'"'s own acquisition' "$id" --scout
  # The owner changes after the claim to another live process: refused.
  id='guard-s4-lease-swapped'
  rec=$(make_case guard-s4lsw "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  state="$CASE_DIR/slots/treehouse-state.json"
  (cd / && exec sleep 600) >/dev/null 2>&1 </dev/null &
  other=$!
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' "$POOL_DIR" "$own" >"$state"
  FM_SLOT_RESET_GUARD_SEAM="jq --argjson pid $other '.worktrees[0].owner_pid = \$pid' '$state' >'$state.tmp' && mv '$state.tmp' '$state'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S4 '(iii-b) the lease owner changes after the claim to another live process' 'reset refused (holder_lease)' "$id" --scout
  # The owner changes to a process inside the acquired pane's tree: ancestry does not exempt it.
  id='guard-s4-lease-pane-tree'
  rec=$(make_case guard-s4lpt "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  state="$CASE_DIR/slots/treehouse-state.json"
  shell=$(guard_start_pane_shell "$POOL_DIR" "$CASE_DIR/pane.ready")
  printf '%s' "$shell" >"$CASE_DIR/pane.pid"
  guard_wrap_tmux_pane_pid "$FAKEBIN_DIR" "$CASE_DIR/pane.pid"
  child=$(pgrep -P "$shell" | head -n 1)
  [ -n "$child" ] || fail 'the pane shell has no child to hold the lease'
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' "$POOL_DIR" "$own" >"$state"
  FM_SLOT_RESET_GUARD_SEAM="jq --argjson pid $child '.worktrees[0].owner_pid = \$pid' '$state' >'$state.tmp' && mv '$state.tmp' '$state'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S4 '(iii-b) the lease owner is a live process inside the pane tree that is not the recorded acquisition' 'reset refused (holder_lease)' "$id" --scout
  pkill -P "$shell" 2>/dev/null || true
  kill "$shell" 2>/dev/null || true
  # The owner changes to a process that is gone: nothing holds the lease any more.
  id='guard-s4-lease-dead'
  rec=$(make_case guard-s4ld "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  state="$CASE_DIR/slots/treehouse-state.json"
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":%s}]}\n' "$POOL_DIR" "$own" >"$state"
  FM_SLOT_RESET_GUARD_SEAM="jq --argjson pid 2147483000 '.worktrees[0].owner_pid = \$pid' '$state' >'$state.tmp' && mv '$state.tmp' '$state'" \
    guard_expect_launch S4 '(iii-b) paired pass: the changed owner is a process that is gone' "$id" --scout
  kill "$own" "$other" 2>/dev/null || true
  pass 'S4 (iii-b): a process lease is this spawn'"'"'s only by its recorded identity, never by ancestry'
}

test_reset_guard_s4_vernant_lease_and_contention() {
  local rec id holder common real name
  id='guard-s4-store-lease'
  rec=$(make_guard_governed_case guard-s4store "$id")
  read_case_record "$rec"
  common=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-common-dir)
  real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$POOL_DIR")
  name="lease-$(printf 'worktree:%s' "$real" | shasum -a 256 | cut -c1-16).json"
  mkdir -p "$common/vernant-worktree-leases"
  sleep 600 &
  holder=$!
  printf '{"status":"active","owner_id":"session-x","owner_pid":%s,"expires_at_iso":"2099-01-01T00:00:00Z"}\n' "$holder" \
    >"$common/vernant-worktree-leases/$name"
  guard_expect_refusal S4 '(iii-c) the project lease store holds a live lease' 'reset refused (holder_lease)' "$id" --scout --owned-path scripts
  printf '{"status":"released","owner_id":"session-x","owner_pid":%s}\n' "$holder" >"$common/vernant-worktree-leases/$name"
  GUARD_OUT=$(run_governed_spawn "$id") || fail "S4: the released store lease still refused: $GUARD_OUT"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  id='guard-s4-contention'
  rec=$(make_guard_governed_case guard-s4iv "$id")
  read_case_record "$rec"
  common=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-common-dir)
  real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$POOL_DIR")
  mkdir -p "$common/vernant-worktree-leases"
  printf '{"worktree_id":"%s","ts_iso":"%s","session_id":"co-tenant"}\n' "$real" "$(guard_iso_ago 1)" \
    >"$common/vernant-worktree-leases/contention.jsonl"
  guard_expect_refusal S4 '(iv) a contention row one hour old' 'reset refused (holder_contention)' "$id" --scout --owned-path scripts
  printf '{"worktree_id":"%s","ts_iso":"%s","session_id":"co-tenant"}\n' "$real" "$(guard_iso_ago 30)" \
    >"$common/vernant-worktree-leases/contention.jsonl"
  GUARD_OUT=$(run_governed_spawn "$id") || fail "S4: a contention row older than 24 hours still refused: $GUARD_OUT"
  [ "${FM_TEST_EVIDENCE:-0}" != 1 ] || printf 'EVIDENCE S4 | (iv) paired control | exit=0 | row 30h old (outside the 24h window) passes\n'
  pass 'S4 (iii-c, iv): a live store lease and recent contention refuse, and pass once released or aged out'
}

# ---- S4: the acquired pane's own shell is not a foreign holder ---------------------------------
# A real shell holds the slot as its cwd, as the pane's `treehouse get` subshell does, with a
# real child that does too. The pane pid comes from the vendor (tmux `#{pane_pid}`), so the
# fake tmux here answers it with the pid of that real shell.
guard_start_pane_shell() { # <slot> <ready-file>  -> prints the shell's pid
  bash -c 'cd "$1" && touch "$2" && { sleep 600 & wait; }' _ "$1" "$2" >/dev/null 2>&1 </dev/null &
  printf '%s' "$!"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$2" ] && break
    command sleep 0.2
  done
  [ -e "$2" ] || fail 'the pane shell never reached the slot'
}

guard_wrap_tmux_pane_pid() { # <fakebin> <file-holding-the-pid>
  mv "$1/tmux" "$1/tmux.real"
  cat >"$1/tmux" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"#{pane_pid}"*) cat "$2"; exit 0 ;;
esac
exec "$1/tmux.real" "\$@"
SH
  chmod +x "$1/tmux"
}

test_reset_guard_s4_pane_pid_exemption() {
  local rec id shell foreign bystander
  # Healthy control: the pane shell and its child hold the slot cwd; the endpoint reports the shell's pid.
  id='guard-s4-pane-pid'
  rec=$(make_case guard-s4pane "$id")
  read_case_record "$rec"
  shell=$(guard_start_pane_shell "$POOL_DIR" "$CASE_DIR/pane.ready")
  printf '%s' "$shell" >"$CASE_DIR/pane.pid"
  guard_wrap_tmux_pane_pid "$FAKEBIN_DIR" "$CASE_DIR/pane.pid"
  guard_expect_launch S4 'the acquired pane shell and its child hold the slot cwd and are excluded by the endpoint pane pid' "$id" --scout
  pkill -P "$shell" 2>/dev/null || true
  kill "$shell" 2>/dev/null || true
  # Paired refusal: the same holders, but the endpoint reports some other pid.
  id='guard-s4-pane-pid-mismatch'
  rec=$(make_case guard-s4panemis "$id")
  read_case_record "$rec"
  shell=$(guard_start_pane_shell "$POOL_DIR" "$CASE_DIR/pane.ready")
  (cd / && exec sleep 600) >/dev/null 2>&1 </dev/null &
  bystander=$!
  printf '%s' "$bystander" >"$CASE_DIR/pane.pid"
  guard_wrap_tmux_pane_pid "$FAKEBIN_DIR" "$CASE_DIR/pane.pid"
  guard_expect_refusal S4 'the same holders, with the endpoint reporting an unrelated pid' 'reset refused (holder_cwd)' "$id" --scout
  pkill -P "$shell" 2>/dev/null || true
  kill "$shell" "$bystander" 2>/dev/null || true
  # A foreign holder beside the excluded pane shell still refuses.
  id='guard-s4-pane-pid-foreign'
  rec=$(make_case guard-s4panefor "$id")
  read_case_record "$rec"
  shell=$(guard_start_pane_shell "$POOL_DIR" "$CASE_DIR/pane.ready")
  printf '%s' "$shell" >"$CASE_DIR/pane.pid"
  guard_wrap_tmux_pane_pid "$FAKEBIN_DIR" "$CASE_DIR/pane.pid"
  (cd "$POOL_DIR" && exec sleep 600) &
  foreign=$!
  guard_expect_refusal S4 'a foreign holder beside the excluded pane shell' 'reset refused (holder_cwd)' "$id" --scout
  pkill -P "$shell" 2>/dev/null || true
  kill "$foreign" "$shell" 2>/dev/null || true
  pass 'S4: the pane shell is excluded by the endpoint pane pid, a mismatching pid or a foreign holder still refuses'
}

# A backend that reports no pane pid (zellij, cmux, orca): the pane is a real shell that runs the
# lines it is sent, as a pane does. The probe runs inside it, so the shell is a true ancestor.
guard_start_pane_emulator() { # <slot> <dir> -> prints the emulator's pid
  mkdir -p "$2"
  cat >"$2/pane.sh" <<'SH'
#!/usr/bin/env bash
cd "$1" || exit 1
: >"$2/ready"
while :; do
  if [ -s "$2/cmd" ]; then
    line=$(cat "$2/cmd")
    : >"$2/cmd"
    bash -c "$line" </dev/null >/dev/null 2>&1
    : >"$2/done"
  else
    command sleep 0.1
  fi
done
SH
  bash "$2/pane.sh" "$1" "$2" >/dev/null 2>&1 </dev/null &
  printf '%s' "$!"
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$2/ready" ] && break
    command sleep 0.2
  done
  [ -e "$2/ready" ] || fail 'the pane emulator never reached the slot'
}

guard_wrap_tmux_into_pane() { # <fakebin> <emulator-dir>
  mv "$1/tmux" "$1/tmux.real"
  cat >"$1/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then
  for a in "\$@"; do
    case "\$a" in
      "bash -- '"*".slot-provision."*)
        rm -f "$2/done"
        printf '%s\n' "\$a" >"$2/cmd"
        for i in \$(seq 1 300); do [ -e "$2/done" ] && exit 0; command sleep 0.1; done
        exit 1
        ;;
    esac
  done
fi
exec "$1/tmux.real" "\$@"
SH
  chmod +x "$1/tmux"
}

test_reset_guard_s4_in_pane_probe_without_pane_pid() {
  local rec id pane foreign
  id='guard-s4-in-pane'
  rec=$(make_case guard-s4inpane "$id")
  read_case_record "$rec"
  pane=$(guard_start_pane_emulator "$POOL_DIR" "$CASE_DIR/emulator")
  guard_wrap_tmux_into_pane "$FAKEBIN_DIR" "$CASE_DIR/emulator"
  guard_expect_launch S4 'no pane pid is reported; the pane shell holds the slot cwd and is excluded by running the probe inside it' "$id" --scout
  kill "$pane" 2>/dev/null || true
  id='guard-s4-in-pane-foreign'
  rec=$(make_case guard-s4inpanef "$id")
  read_case_record "$rec"
  pane=$(guard_start_pane_emulator "$POOL_DIR" "$CASE_DIR/emulator")
  guard_wrap_tmux_into_pane "$FAKEBIN_DIR" "$CASE_DIR/emulator"
  (cd "$POOL_DIR" && exec sleep 600) &
  foreign=$!
  guard_expect_refusal S4 'no pane pid is reported; a foreign holder beside the pane shell' 'reset refused (holder_cwd)' "$id" --scout
  kill "$foreign" "$pane" 2>/dev/null || true
  pass 'S4: with no pane pid the probe runs inside the pane, excluding its shell and still refusing a foreign holder'
}

# ---- S5: unknown refuses --------------------------------------------------------------------
test_reset_guard_s5_unknown_classes() {
  local rec id common farm
  # A failed git read.
  id='guard-s5-git-read'
  rec=$(make_case guard-s5git "$id")
  read_case_record "$rec"
  guard_install_git_shim "$FAKEBIN_DIR"
  guard_prefetch
  FM_TEST_GIT_FAIL='merge-base --is-ancestor' guard_expect_refusal S5 'a failed git read (containment)' 'reset refused (unknown_git_read)' "$id" --scout
  # A failed fetch of the origin default branch.
  id='guard-s5-fetch'
  rec=$(make_case guard-s5fetch "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  git -C "$PROJECT_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  guard_expect_refusal S5 'a failed fetch of the origin default branch' 'could not fetch' "$id" --mode no-mistakes --yolo off
  # An unreadable lifecycle manifest.
  id='guard-s5-manifest'
  rec=$(make_guard_governed_case guard-s5man "$id")
  read_case_record "$rec"
  guard_write_manifest - - $'{ this is not json'
  guard_expect_refusal S5 'an unparsable lifecycle manifest' 'reset refused (unknown_manifest)' "$id" --scout --owned-path scripts
  # lsof made unavailable through PATH.
  id='guard-s5-lsof'
  rec=$(make_case guard-s5lsof "$id")
  read_case_record "$rec"
  farm=$(guard_path_without lsof "$CASE_DIR/no-lsof")
  PATH="$farm" guard_expect_refusal S5 'lsof unavailable through PATH' 'reset refused (unknown_holder_probe)' "$id" --scout
  # An unreadable worktree list (the lock source).
  id='guard-s5-lock'
  rec=$(make_case guard-s5lock "$id")
  read_case_record "$rec"
  guard_install_git_shim "$FAKEBIN_DIR"
  FM_TEST_GIT_FAIL='worktree list --porcelain' guard_expect_refusal S5 'an unreadable worktree list (lock source)' 'reset refused (unknown_lock)' "$id" --scout
  # An unreadable lease state (the pool's treehouse-state.json).
  id='guard-s5-lease'
  rec=$(make_case guard-s5lease "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  printf '{ not json' >"$CASE_DIR/slots/treehouse-state.json"
  guard_expect_refusal S5 'an unreadable pool lease state' 'reset refused (unknown_lease)' "$id" --scout
  # An unreadable project lease record and contention log.
  id='guard-s5-store'
  rec=$(make_guard_governed_case guard-s5store "$id")
  read_case_record "$rec"
  common=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-common-dir)
  mkdir -p "$common/vernant-worktree-leases"
  printf '{"worktree_id":"x","ts_iso":"2026-01-01T00:00:00Z"}\n' >"$common/vernant-worktree-leases/contention.jsonl"
  chmod 000 "$common/vernant-worktree-leases/contention.jsonl"
  guard_expect_refusal S5 'an unreadable contention log' 'reset refused (unknown_contention)' "$id" --scout --owned-path scripts
  chmod 644 "$common/vernant-worktree-leases/contention.jsonl"
  pass 'S5: every unknown class (git read, fetch, manifest, lsof, lock, lease, contention) refuses untouched with its name'
}

# ---- S5b: the final pre-reset revalidation ----------------------------------------------------
test_reset_guard_s5b_transitions() {
  local rec id
  # (i) a tracked edit appears after the first clean observation.
  id='guard-s5b-edit'
  rec=$(make_case guard-s5b-i "$id")
  read_case_record "$rec"
  guard_prefetch
  FM_SLOT_RESET_GUARD_SEAM="printf 'late edit\\n' >>'$POOL_DIR/README.md'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S5b '(i) a tracked edit appears after the first observation' 'is not clean' "$id" --scout
  cmp -s "$CASE_DIR/post-seam.snap" "$CASE_DIR/after.snap" || fail 'S5b (i): the late edit was not byte-preserved'
  assert_grep 'late edit' "$POOL_DIR/README.md" 'S5b (i): the late edit was lost'
  # (ii) a new commit lands on HEAD.
  id='guard-s5b-commit'
  rec=$(make_case guard-s5b-ii "$id")
  read_case_record "$rec"
  guard_prefetch
  FM_SLOT_RESET_GUARD_SEAM="git -C '$POOL_DIR' -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m late; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S5b '(ii) a new commit lands on HEAD after the first observation' 'reset refused (head_not_contained)' "$id" --scout
  cmp -s "$CASE_DIR/post-seam.snap" "$CASE_DIR/after.snap" || fail 'S5b (ii): the late commit was not byte-preserved'
  # (iii) the lifecycle manifest is rewritten with unparsable bytes.
  id='guard-s5b-manifest'
  rec=$(make_guard_governed_case guard-s5b-iii "$id")
  read_case_record "$rec"
  guard_prefetch
  guard_write_manifest - "$INITIAL_SHA"
  FM_SLOT_RESET_GUARD_SEAM="printf '{ garbage' >'$GUARD_MANIFEST_FILE'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S5b '(iii) the manifest is rewritten with unparsable bytes' 'reset refused (unknown_manifest)' "$id" --scout --owned-path scripts
  cmp -s "$CASE_DIR/post-seam.snap" "$CASE_DIR/after.snap" || fail 'S5b (iii): the slot changed after the manifest rewrite'
  guard_assert_only_anchor_added 'S5b (iii)'
  # (iii-b) the manifest names another base, with the bytes still parsable.
  id='guard-s5b-manifest-base'
  rec=$(make_guard_governed_case guard-s5b-iiib "$id")
  read_case_record "$rec"
  guard_prefetch
  guard_write_manifest - "$INITIAL_SHA"
  FM_SLOT_RESET_GUARD_SEAM="python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d[\"owner_id\"]=\"someone-else\"; json.dump(d,open(sys.argv[1],\"w\"))' '$GUARD_MANIFEST_FILE'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S5b '(iii-b) the manifest bytes change though still parsable' 'reset refused (changed_since_first_read)' "$id" --scout --owned-path scripts
  guard_assert_only_anchor_added 'S5b (iii-b)'
  # (iv) a contention row appears after the first observation.
  id='guard-s5b-contention'
  rec=$(make_guard_governed_case guard-s5b-iv "$id")
  read_case_record "$rec"
  guard_prefetch
  local common real
  common=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-common-dir)
  real=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$POOL_DIR")
  mkdir -p "$common/vernant-worktree-leases"
  FM_SLOT_RESET_GUARD_SEAM="printf '{\"worktree_id\":\"%s\",\"ts_iso\":\"%s\",\"session_id\":\"co\"}\\n' '$real' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" >'$common/vernant-worktree-leases/contention.jsonl'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S5b '(iv) a co-tenant contention row appears after the first observation' 'reset refused (holder_contention)' "$id" --scout --owned-path scripts
  guard_assert_only_anchor_added 'S5b (iv)'
  # (v) a new ignored file appears at a path the target tracks.
  id='guard-s5b-ignored'
  rec=$(make_case guard-s5b-v "$id")
  read_case_record "$rec"
  guard_ignore notes.local
  guard_publish_tracked notes.local $'tracked\n'
  guard_prefetch
  FM_SLOT_RESET_GUARD_SEAM="printf 'late ignored notes\\n' >'$POOL_DIR/notes.local'; guard_snapshot '$POOL_DIR' '$CASE_DIR/post-seam.snap'" \
    guard_expect_refusal S5b '(v) an ignored collision appears after the first observation' 'reset refused (ignored_collision)' "$id" --scout
  cmp -s "$CASE_DIR/post-seam.snap" "$CASE_DIR/after.snap" || fail 'S5b (v): the late ignored file was not byte-preserved'
  # Control: stable evidence resets successfully, with the seam firing a harmless command.
  id='guard-s5b-control'
  rec=$(make_case guard-s5b-ctl "$id")
  read_case_record "$rec"
  guard_prefetch
  FM_SLOT_RESET_GUARD_SEAM=true guard_expect_launch S5b 'control: stable evidence resets and launches' "$id" --scout
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/main)" ] || fail 'S5b control: the slot did not reach origin'
  pass 'S5b: a change after the first observation refuses with the work preserved, and stable evidence resets'
}

# Explicit selection keeps focused regressions independently runnable by name.
if [ "$#" -gt 0 ]; then
  for selected_test in "$@"; do
    case "$selected_test" in
      test_*)
        declare -F "$selected_test" >/dev/null 2>&1 || fail "unknown selected test: $selected_test"
        "$selected_test"
        ;;
      *) fail "unknown selected test: $selected_test" ;;
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

test_reset_guard_snapshot_witness
test_reset_guard_s1_detached_extra_commit
test_reset_guard_s1_manifest_base_anchor
test_reset_guard_s2_attached_branch
test_reset_guard_s2_manifest_branch
test_reset_guard_s3_dirty_kinds
test_reset_guard_s3b_same_path
test_reset_guard_s3b_ancestor_path
test_reset_guard_s3b_inside_tracked_file
test_reset_guard_s3b_control_no_collision
test_reset_guard_s3b_scratch_and_archive
test_reset_guard_s3b_inventory_failure
test_reset_guard_s4_cwd_holder
test_reset_guard_s4_worktree_lock
test_reset_guard_s4_foreign_lease
test_reset_guard_s4_process_lease_recorded_identity
test_reset_guard_s4_vernant_lease_and_contention
test_reset_guard_s4_pane_pid_exemption
test_reset_guard_s4_in_pane_probe_without_pane_pid
test_reset_guard_s5_unknown_classes
test_reset_guard_s5b_transitions

echo "# all fm-spawn-pool-base-freshen tests passed"
