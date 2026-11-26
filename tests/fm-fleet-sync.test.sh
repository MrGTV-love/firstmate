#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
#
# It also pins the clone-root guard: a plain directory under projects/ resolves,
# through git's upward repository discovery, to the ENCLOSING repository - in a
# firstmate home, the firstmate checkout itself - so it must be skipped by name
# with the enclosing repo left untouched, in both the whole-fleet and
# single-project forms, while a symlinked clone dir still syncs.
#
# It also pins the orphaned .git/packed-refs.lock recovery in the fetch step
# (fetch_with_packed_refs_lock_guard, backed by bin/fm-lock-lib.sh's shared
# staleness proof): a provably-stale lock is retried then removed and the clone
# syncs (with a "recovered:" summary on stdout so a session-start refresh, which
# discards stderr, still surfaces it); a live lock is never removed and the sync
# fails loudly; real Git lock-fd and prepared-ref-transaction owners both block
# removal, including a transaction running in a linked worktree of the clone,
# while real idle non-Git cwd holders in the clone or a linked worktree do not; a failed,
# partial, or empty worktree inventory keeps the lock; incomplete directory
# evidence and Git helpers still veto removal; a transient lock that self-clears
# is retried without a force-remove; and any
# non-packed-refs.lock fetch failure keeps today's behavior with no retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/git-lock-helpers.sh
. "$ROOT/tests/git-lock-helpers.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  # mktemp, not a counter: a counter incremented inside $(new_home) never reaches the caller,
  # so every call would hand back the same directory and the whole-fleet form would see the
  # clones of every earlier test.
  local h
  h=$(mktemp -d "$TMP_ROOT/home.XXXXXX")
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

# build_enclosing_home <name>: an FM_HOME that is itself nested inside another git
# repository - firstmate's own layout, where projects/ sits inside the firstmate
# checkout. The enclosing repo is a clean clone of a bare origin that is one commit
# ahead, so a sync that walked git discovery UP out of projects/<dir> would find a
# fast-forward available and visibly take it. Echoes the enclosing repo, which is
# also the home. Its work tree is left pristine so the only thing under projects/
# is what the test puts there.
build_enclosing_home() {
  local name=$1 root work remote enclosing remote_abs
  root="$TMP_ROOT/enclosing-$name"
  work="$root/work"
  remote="$root/remote.git"
  enclosing="$root/enclosing"
  mkdir -p "$root"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  printf '/projects/\n' > "$work/.gitignore"
  git -C "$work" add .gitignore
  commit_file "$work" AGENTS.md v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$enclosing"
  commit_file "$work" AGENTS.md v1 C1
  git -C "$work" push -q origin main

  mkdir -p "$enclosing/projects"
  printf '%s\n' "$enclosing"
}

# --- packed-refs.lock fixtures ----------------------------------------------

# build_packed_prunable <home> <name>: like build_pair, but the clone has PACKED
# refs plus a local `feature` branch tracking a since-deleted origin/feature, so a
# fetch --prune must rewrite packed-refs - which an orphaned .git/packed-refs.lock
# blocks with Git's "Unable to create '...packed-refs.lock': File exists". origin/main
# is advanced by one commit so a successful sync fast-forwards. Echoes the clone path.
build_packed_prunable() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main
  git -C "$work" push -q origin main:refs/heads/feature

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" branch -q feature origin/feature
  commit_file "$work" file.txt v1 C1
  git -C "$work" push -q origin main
  git -C "$work" push -q origin --delete feature
  git -C "$clone" pack-refs --all
  printf '%s\n' "$clone"
}

plant_packed_refs_lock() { : > "$1/.git/packed-refs.lock"; }

# lsof shims mirror tests/fm-teardown-helpers.sh: no-holder (provably free), a live
# holder, and an lsof error. Written into a per-home fakebin/ prepended to PATH.
lsof_no_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$1/lsof"
}
lsof_live_holder() {
  cat > "$1/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/lsof"
}

# git shim: fail the FIRST `fetch` with the packed-refs.lock signature and drop
# the lock (simulating the dying ref-rewrite finishing), then delegate every
# later call - including the retried fetch - to the real git so the sync completes.
git_transient_packed_refs_lock() {
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=; is_fetch=0
for a in "$@"; do [ "$a" = fetch ] && is_fetch=1; done
prev=
for a in "$@"; do [ "$prev" = -C ] && dir=$a; prev=$a; done
if [ "$is_fetch" = 1 ]; then
  n=$(cat "${GIT_FETCH_COUNTER:?}" 2>/dev/null || echo 0); n=$(( n + 1 ))
  printf '%s\n' "$n" > "$GIT_FETCH_COUNTER"
  if [ "$n" -eq 1 ]; then
    lock="$dir/.git/packed-refs.lock"
    echo "error: could not delete reference refs/remotes/origin/feature: Unable to create '$lock': File exists." >&2
    rm -f "$lock"
    exit 1
  fi
fi
exec "$real" "$@"
SH
  chmod +x "$1/git"
}

# run_sync_guarded <home> <fakebin> <outfile> <errfile> [args...]: run fleet-sync
# with the fakebin on PATH and stdout/stderr captured separately. Per-test knobs
# (FM_FLEET_SYNC_PACKED_REFS_LOCK_*, GIT_FETCH_COUNTER) are read from the caller's
# exported environment.
run_sync_guarded() {
  local home=$1 fakebin=$2 outf=$3 errf=$4 realgit
  shift 4
  realgit=$(command -v git)
  PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$realgit" \
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-fleet-sync.sh" "$@" >"$outf" 2>"$errf"
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main, synced" "detached-clean-ancestor reports recovered"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

test_local_only_skipped() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" iota)
  advance_origin "$home" iota C1
  mkdir -p "$home/data"
  printf -- '- iota [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "iota: skipped: local-only project" "local-only clone is skipped as before"
  assert_not_contains "$out" "STUCK" "local-only skip is not escalated to STUCK"
  pass "local-only clone is skipped (benign), not flagged STUCK"
}

# A registry entry the parser refuses resolves to no posture at all, so sync must
# skip the clone rather than fall back to the default posture: reading a refusal
# as "no-mistakes" is how a local-only clone would be fetched and fast-forwarded.
test_unresolvable_registry_posture_skipped() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" omicron)
  advance_origin "$home" omicron C1
  before=$(head_sha "$clone")
  mkdir -p "$home/data"
  printf -- '- omicron [local-only forge=githb] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "omicron: skipped: registry entry does not resolve to a delivery posture" \
    "a refused registry entry was not reported as a skip"
  assert_not_contains "$out" "STUCK" "a refused registry entry was escalated to STUCK"
  [ "$(head_sha "$clone")" = "$before" ] || fail "a clone whose registry entry was refused was still fast-forwarded"
  pass "a clone whose registry entry the parser refuses is skipped, never synced on the default posture"
}

test_single_project_by_bare_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1

  out=$(run_sync "$home" "kappa")

  assert_contains "$out" "kappa: synced" "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_single_project_by_bare_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" mu >/dev/null
  advance_origin "$home" mu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/mu"

  out=$(cd "$cwd" && run_sync "$home" "mu")

  assert_contains "$out" "mu: synced" "bare project name prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "bare project name ignores a cwd shadow directory"
  pass "single-project bare name resolution is not cwd-sensitive"
}

test_single_project_by_projects_relative_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" lambda >/dev/null
  advance_origin "$home" lambda C1

  out=$(run_sync "$home" "projects/lambda")

  assert_contains "$out" "lambda: synced" "projects/<name> form resolves against the home's projects dir"
  pass "single-project form accepts a projects/<name> relative name"
}

test_single_project_by_projects_relative_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" nu >/dev/null
  advance_origin "$home" nu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/projects/nu"

  out=$(cd "$cwd" && run_sync "$home" "projects/nu")

  assert_contains "$out" "nu: synced" "projects/<name> form prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "projects/<name> form ignores a cwd shadow directory"
  pass "single-project projects/<name> resolution is not cwd-sensitive"
}

test_single_project_unresolvable_name_still_skips() {
  local home out
  home=$(new_home)

  out=$(run_sync "$home" "does-not-exist")

  assert_contains "$out" "skipped: not a directory" "an unresolvable name still hits the existing not-a-directory skip"
  pass "single-project form leaves a genuinely bad name unresolved"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under projects/"
}

test_bootstrap_relays_recovered_and_stuck() {
  local home stuck rec out
  home=$(new_home)
  # A clone we will leave STUCK (dirty), and one that self-heals (detached-clean-ancestor).
  stuck=$(build_pair "$home" stuck-clone)
  advance_origin "$home" stuck-clone C1
  printf 'dirty\n' >> "$stuck/file.txt"
  rec=$(build_pair "$home" rec-clone)
  advance_origin "$home" rec-clone C1
  git -C "$rec" checkout --detach --quiet

  # Full bootstrap: no state/ dir -> secondmate sync no-ops; no .env -> X mode off.
  # We only assert the fleet-sync relay lines; other detect lines are irrelevant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: stuck-clone: STUCK:" "bootstrap relays the STUCK outcome"
  assert_contains "$out" "FLEET_SYNC: rec-clone: recovered:" "bootstrap relays the recovered outcome"
  pass "bootstrap relays recovered: and STUCK: fleet-sync outcomes"
}

# --- packed-refs.lock guard tests -------------------------------------------

test_orphaned_stale_packed_refs_lock_recovers() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-lockstale"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockstale)
  plant_packed_refs_lock "$clone"
  lsof_no_holder "$fakebin"           # provably no live holder
  out="$home/out-lockstale"; err="$home/err-lockstale"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockstale
  set -e

  assert_grep "removed provably-stale packed-refs lock" "$err" \
    "stale lock: guard did not force-remove the provably-stale lock"
  assert_grep "fetch succeeded after stale packed-refs lock cleanup" "$err" \
    "stale lock: fetch did not succeed after cleanup"
  assert_contains "$(cat "$out")" "lockstale: synced" "stale lock: clone did not sync after recovery"
  assert_grep "recovered: removed a stale packed-refs lock" "$out" \
    "stale lock: recovery summary not emitted on stdout (bootstrap relays stdout, discards stderr)"
  assert_absent "$clone/.git/packed-refs.lock" "stale lock: lock should be gone after removal"
  [ "$(git -C "$clone" rev-parse HEAD)" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "stale lock: clone HEAD not at origin/main after recovery"
  pass "orphaned provably-stale packed-refs.lock is cleared and the clone syncs"
}

test_live_packed_refs_lock_is_never_removed() {
  local home fakebin clone out err before
  home=$(new_home)
  fakebin="$home/fb-locklive"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locklive)
  plant_packed_refs_lock "$clone"
  lsof_live_holder "$fakebin"         # a live process holds the lock/.git open
  before=$(head_sha "$clone")
  out="$home/out-locklive"; err="$home/err-locklive"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locklive
  set -e

  assert_grep "is not provably stale" "$err" "live lock: guard did not explain the refusal"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "live lock: guard force-removed a live lock"
  assert_contains "$(cat "$out")" "locklive: skipped: fetch failed" "live lock: fleet-sync did not skip"
  assert_present "$clone/.git/packed-refs.lock" "live lock: lock must never be removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "live lock: clone was advanced despite the refusal"
  pass "a live packed-refs.lock is never removed and the sync fails loudly"
}

test_idle_cwd_in_clone_dir_does_not_block_recovery() {
  local home fakebin clone linked out err idle linked_idle
  home=$(new_home)
  fakebin="$home/fb-lockcwd"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" lockcwd)
  linked="$home/lockcwd-slot"
  git -C "$clone" worktree add -q --detach "$linked"
  plant_packed_refs_lock "$clone"
  touch -t 200001010000 "$clone/.git/packed-refs.lock"
  mkfifo "$home/idle-input"
  exec 9<> "$home/idle-input"
  (cd "$clone" && exec bash -c 'read -r _ <&9') &
  idle=$!
  # A pool-slot pane shell sits in a linked worktree of the same clone.
  (cd "$linked" && exec bash -c 'read -r _ <&9') &
  linked_idle=$!
  # Observe the real cwd owners rather than cap how long scheduling takes.
  fm_test_wait_until --while-alive "$idle" -- lsof -a -p "$idle" -d cwd -- "$clone" >/dev/null \
    || fail "idle process did not enter clone cwd"
  fm_test_wait_until --while-alive "$linked_idle" -- lsof -a -p "$linked_idle" -d cwd -- "$linked" >/dev/null \
    || fail "idle process did not enter linked worktree cwd"
  # The real lock has no open descriptor, but the real directory has a holder.
  if lsof -- "$clone/.git/packed-refs.lock" >/dev/null 2>&1; then
    fail "abandoned lock unexpectedly has an open descriptor"
  fi
  out="$home/out-lockcwd"; err="$home/err-lockcwd"

  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" lockcwd

  kill "$idle" "$linked_idle"; wait "$idle" "$linked_idle" 2>/dev/null || true
  exec 9>&-
  assert_grep "fetch succeeded after stale packed-refs lock cleanup" "$err" \
    "idle cwd: fetch did not recover"
  assert_contains "$(cat "$out")" "lockcwd: synced" "idle cwd: clone did not sync"
  assert_absent "$clone/.git/packed-refs.lock" "idle cwd: abandoned lock was kept"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "idle cwd: clone was not advanced to origin/main"
  pass "idle non-git cwd holders in the clone and a linked worktree do not prevent abandoned lock recovery"
}

test_real_git_packed_refs_owners_block_removal() {
  local kind home clone fakebin out err before
  for kind in packed-open packed; do
    home=$(new_home)
    fakebin="$home/fb-real-git-$kind"; mkdir -p "$fakebin"
    clone=$(build_packed_prunable "$home" "git-$kind")
    fm_test_git_lock_start "$clone" "$home/git-owner-$kind" "$kind"
    before=$(head_sha "$clone")
    out="$home/out"; err="$home/err"
    if [ "$kind" = packed ]; then
      # A real prepared ref transaction has closed its lock descriptor, yet
      # still owns the lock until commit/abort. Test that window explicitly.
      if lsof -- "$FM_TEST_GIT_LOCK_PATH" > "$home/lock-lsof" 2>&1; then
        fail "prepared Git transaction still has an open lock descriptor"
      fi
      [ ! -s "$home/lock-lsof" ] || fail "prepared lock lsof query failed"
      lsof -a -p "$FM_TEST_GIT_LOCK_PID" -d cwd -- "$clone" >/dev/null \
        || fail "prepared Git transaction did not keep the clone cwd"
    fi
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 \
      run_sync_guarded "$home" "$fakebin" "$out" "$err" "git-$kind"
    assert_grep "is not provably stale" "$err" "real Git $kind: guard did not refuse"
    assert_present "$FM_TEST_GIT_LOCK_PATH" "real Git $kind: lock was removed"
    [ "$(head_sha "$clone")" = "$before" ] || fail "real Git $kind: clone advanced"
    fm_test_git_lock_finish
    pass "real Git $kind ownership prevents packed-refs lock removal"
  done
}

test_linked_worktree_git_owner_blocks_removal() {
  local home fakebin clone linked out err before
  home=$(new_home)
  fakebin="$home/fb-linked-git"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" linked-git)
  linked="$home/linked-git-slot"
  git -C "$clone" worktree add -q --detach "$linked"
  fm_test_git_lock_start "$clone" "$home/git-owner-linked" packed "$linked"
  before=$(head_sha "$clone")
  # The prepared transaction closed the common lock's descriptor, and its cwd
  # is the linked worktree, not the clone directory fleet-sync syncs.
  if lsof -- "$FM_TEST_GIT_LOCK_PATH" >/dev/null 2>&1; then
    fail "linked prepared Git transaction still has an open lock descriptor"
  fi
  if lsof -a -p "$FM_TEST_GIT_LOCK_PID" -d cwd -- "$clone" >/dev/null 2>&1; then
    fail "linked prepared Git transaction unexpectedly has the clone cwd"
  fi
  lsof -a -p "$FM_TEST_GIT_LOCK_PID" -d cwd -- "$linked" >/dev/null \
    || fail "linked prepared Git transaction did not keep the linked worktree cwd"
  out="$home/out"; err="$home/err"
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=0 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" linked-git
  assert_grep "is not provably stale" "$err" "linked Git owner: guard did not refuse"
  assert_present "$FM_TEST_GIT_LOCK_PATH" "linked Git owner: lock was removed"
  [ "$(head_sha "$clone")" = "$before" ] || fail "linked Git owner: clone advanced"
  fm_test_git_lock_finish
  pass "a prepared ref transaction in a linked worktree prevents packed-refs lock removal"
}

test_unusable_worktree_inventory_blocks_removal() {
  local kind home clone fakebin out err before
  # partial: the listing names only the clone, then fails. failed: it fails with
  # no output. empty: it succeeds but names no worktree. None is a complete owner
  # inventory, so an otherwise abandoned, unheld lock must stay.
  for kind in partial failed empty; do
    home=$(new_home)
    fakebin="$home/fb-inventory-$kind"; mkdir -p "$fakebin"
    clone=$(build_packed_prunable "$home" "inventory-$kind")
    plant_packed_refs_lock "$clone"
    lsof_no_holder "$fakebin"
    cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
case " $* " in
  *" worktree list "*)
    case "$INVENTORY_TEST_KIND" in
      partial) printf 'worktree %s\n' "${INVENTORY_TEST_CLONE:?}"; exit 1 ;;
      failed) exit 1 ;;
      empty) exit 0 ;;
    esac
    ;;
esac
exec "$real" "$@"
SH
    chmod +x "$fakebin/git"
    before=$(head_sha "$clone")
    out="$home/out"; err="$home/err"
    INVENTORY_TEST_KIND="$kind" INVENTORY_TEST_CLONE="$clone" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
      run_sync_guarded "$home" "$fakebin" "$out" "$err" "inventory-$kind"
    assert_grep "is not provably stale (worktree inventory failed or listed no existing worktree" "$err" \
      "$kind inventory: guard did not refuse with the inventory reason"
    assert_no_grep "removed provably-stale packed-refs lock" "$err" \
      "$kind inventory: guard removed a lock without a complete owner inventory"
    assert_present "$clone/.git/packed-refs.lock" "$kind inventory: lock was removed"
    [ "$(head_sha "$clone")" = "$before" ] || fail "$kind inventory: clone advanced"
    pass "$kind worktree inventory prevents packed-refs lock removal"
  done
}

test_unclassifiable_directory_holders_block_removal() {
  local fields home clone fakebin out err
  for fields in missing-command warning git-helper; do
    home=$(new_home)
    fakebin="$home/fb-fields-$fields"; mkdir -p "$fakebin"
    clone=$(build_packed_prunable "$home" "fields-$fields")
    plant_packed_refs_lock "$clone"
    cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *packed-refs.lock*) exit 1 ;;
esac
case "$LSOF_TEST_FIELDS" in
  missing-command) printf 'p123\nfcwd\n' ;;
  warning) printf 'p123\ncbash\nfcwd\nlsof: simulated incomplete scan\n' ;;
  git-helper) printf 'p123\ncbash\nfcwd\np456\ncgit-remote-https\nfcwd\n' ;;
esac
SH
    chmod +x "$fakebin/lsof"
    out="$home/out"; err="$home/err"
    LSOF_TEST_FIELDS="$fields" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
      run_sync_guarded "$home" "$fakebin" "$out" "$err" "fields-$fields"
    assert_grep "is not provably stale" "$err" "$fields: guard did not refuse"
    assert_present "$clone/.git/packed-refs.lock" "$fields: lock was removed"
    pass "$fields directory evidence prevents packed-refs lock removal"
  done
}

test_transient_packed_refs_lock_self_clears() {
  local home fakebin clone out err counter
  home=$(new_home)
  fakebin="$home/fb-locktrans"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_packed_prunable "$home" locktrans)
  plant_packed_refs_lock "$clone"
  git_transient_packed_refs_lock "$fakebin"   # fail once + drop lock, then real git
  counter="$home/git-fetch-count"; : > "$counter"
  out="$home/out-locktrans"; err="$home/err-locktrans"

  set +e
  GIT_FETCH_COUNTER="$counter" \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locktrans
  set -e

  assert_grep "cleared on its own" "$err" "transient lock: guard did not report the self-clear"
  assert_no_grep "removed provably-stale packed-refs lock" "$err" \
    "transient lock: guard force-removed a lock that only needed patience"
  assert_contains "$(cat "$out")" "locktrans: synced" "transient lock: clone did not sync after self-clear"
  assert_grep "recovered: packed-refs lock cleared on its own" "$out" \
    "transient lock: recovery summary not emitted on stdout"
  assert_absent "$clone/.git/packed-refs.lock" "transient lock: lock should be gone after self-clear"
  pass "a transient packed-refs.lock that self-clears is retried without a force-remove"
}

test_non_clone_dir_never_syncs_the_enclosing_repo() {
  local home before out after
  home=$(build_enclosing_home nonclone)
  # A worktree container, not a clone: the repo is one level BELOW it.
  mkdir -p "$home/projects/not-a-clone/wt"
  before=$(head_sha "$home")

  out=$(run_sync "$home")
  after=$(head_sha "$home")

  assert_contains "$out" "not-a-clone: skipped: not a clone root" \
    "a non-repo directory under projects/ must be skipped by name"
  assert_not_contains "$out" "not-a-clone: synced" \
    "a non-repo directory must never be reported as a synced project"
  [ "$before" = "$after" ] || \
    fail "fleet-sync fast-forwarded the enclosing repo ($before -> $after) under a project's label"
  pass "a non-repo directory under projects/ never fast-forwards the enclosing repo"
}

test_non_clone_dir_named_directly_never_syncs_the_enclosing_repo() {
  local home before out after
  home=$(build_enclosing_home nonclonedirect)
  mkdir -p "$home/projects/not-a-clone"
  before=$(head_sha "$home")

  out=$(run_sync "$home" not-a-clone)
  after=$(head_sha "$home")

  assert_contains "$out" "not-a-clone: skipped: not a clone root" \
    "the single-project form must apply the same clone-root guard"
  [ "$before" = "$after" ] || \
    fail "the single-project form fast-forwarded the enclosing repo ($before -> $after)"
  pass "the single-project form also refuses a directory that is not its own clone root"
}

test_symlinked_clone_still_syncs() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" sigma)
  advance_origin "$home" sigma C1
  # A symlinked clone dir is a real clone root and must not be mistaken for a
  # directory nested in someone else's repo.
  mv "$clone" "$home/real-sigma"
  ln -s "$home/real-sigma" "$clone"

  out=$(run_sync "$home")

  assert_contains "$out" "sigma: synced" "a symlinked clone must still fast-forward"
  pass "the clone-root guard accepts a symlinked clone directory"
}

test_clone_root_named_by_another_spelling_still_syncs() {
  local home clone fakebin alias out
  home=$(new_home)
  clone=$(build_pair "$home" tau)
  advance_origin "$home" tau C1
  fakebin="$home/fb-rootalias"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  # git reports the clone's own root through an alias that is the same directory
  # but a different string, as it does on a case-insensitive volume when the home
  # was recorded with other casing. A symlink stands in for the case difference so
  # the test also holds on a case-sensitive filesystem.
  alias="$home/root-alias"
  ln -s "$clone" "$alias"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
case " $* " in
  *" rev-parse --show-toplevel "*) printf '%s\n' "${ROOT_ALIAS_FOR_TEST:?}"; exit 0 ;;
esac
exec "$real" "$@"
SH
  chmod +x "$fakebin/git"
  out="$home/out"; err="$home/err"

  ROOT_ALIAS_FOR_TEST="$alias" run_sync_guarded "$home" "$fakebin" "$out" "$err" tau || true

  assert_contains "$(cat "$out")" "tau: synced" \
    "a clone root that git names with another spelling must still fast-forward"
  assert_not_contains "$(cat "$out")" "not a clone root" \
    "the guard must compare the directory itself, not the spelling of its path"
  pass "the clone-root guard accepts a root named by a different spelling of the same directory"
}

test_non_signature_fetch_failure_is_not_retried() {
  local home fakebin clone out err
  home=$(new_home)
  fakebin="$home/fb-locknonsig"; rm -rf "$fakebin"; mkdir -p "$fakebin"
  clone=$(build_pair "$home" locknonsig)
  advance_origin "$home" locknonsig C1
  git -C "$clone" remote set-url origin "file://$home/remotes/does-not-exist.git"
  out="$home/out-locknonsig"; err="$home/err-locknonsig"

  set +e
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3 \
  FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    run_sync_guarded "$home" "$fakebin" "$out" "$err" locknonsig
  set -e

  assert_contains "$(cat "$out")" "locknonsig: skipped: fetch failed" "non-signature: fleet-sync did not report the fetch failure"
  assert_no_grep "waiting" "$err" "non-signature: a non-lock failure was wrongly retried"
  assert_no_grep "packed-refs lock" "$err" "non-signature: a non-lock failure entered the lock guard"
  pass "a non-packed-refs.lock fetch failure keeps today's behavior (no retry)"
}

# --- maintenance.pack-refs.enabled key (C2) ---------------------------------

# pack_key <clone>: the clone's own value of the key, empty when unset.
pack_key() { git -C "$1" config --local --get maintenance.pack-refs.enabled 2>/dev/null || true; }
# other_config <clone>: every local config line except the key, in file order.
other_config() { git -C "$1" config --local --list | grep -v '^maintenance.pack-refs.enabled=' || true; }

test_key_is_written_for_every_clone_state() {
  local home out a b c d e f g h i
  home=$(new_home)
  a=$(build_pair "$home" ka); b=$(build_pair "$home" kb); c=$(build_pair "$home" kc)
  d=$(build_pair "$home" kd); e=$(build_pair "$home" ke); f=$(build_pair "$home" kf)
  g=$(build_pair "$home" kg); h=$(build_pair "$home" kh)
  mkdir -p "$home/data"
  printf -- '- kd [local-only] - local project\n- kh [local-only forge=githb] - unresolvable posture\n' > "$home/data/projects.md"
  git -C "$c" config maintenance.pack-refs.enabled true      # kc: a different value
  advance_origin "$home" kb C1
  git -C "$e" remote set-url origin "file://$home/remotes/does-not-exist.git"   # ke: fetch fails
  git -C "$f" remote remove origin                          # kf: no origin
  printf 'edit\n' >> "$g/file.txt"                           # kg: dirty
  git -C "$h" checkout -q -b side                           # kh: off the default branch, registry refused
  i=$(build_pair "$home" ki); git -C "$i" config user.neighbour kept
  for clone in "$a" "$b" "$d" "$e" "$f" "$g" "$h" "$i"; do
    assert_equals "" "$(pack_key "$clone")" "fixture $clone already carries the key before any run"
  done
  assert_equals true "$(pack_key "$c")" "fixture kc does not carry the true value"
  local before_i; before_i=$(other_config "$i")

  out=$(run_sync "$home")

  assert_equals false "$(pack_key "$a")" "existing clone without the key was left without it"
  assert_equals false "$(pack_key "$b")" "a behind clone was left without the key"
  assert_equals false "$(pack_key "$c")" "a key set to true was not replaced by false"
  assert_equals false "$(pack_key "$d")" "a local-only clone was left without the key"
  assert_equals false "$(pack_key "$e")" "a clone whose fetch fails was left without the key"
  assert_equals false "$(pack_key "$f")" "a no-origin clone was left without the key"
  assert_equals false "$(pack_key "$g")" "a dirty clone was left without the key"
  assert_equals false "$(pack_key "$h")" "an off-default clone with a refused registry entry was left without the key"
  assert_contains "$out" "ke: skipped: fetch failed" "the fetch-failure clone no longer reports its skip"
  assert_contains "$out" "kg: STUCK:" "the dirty clone no longer reports STUCK"
  assert_contains "$out" "kd: skipped: local-only project" "the local-only skip changed"
  assert_equals "$before_i" "$(other_config "$i")" "a neighbour config line changed"
  for clone in "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i"; do
    if git -C "$clone" config --get maintenance.auto >/dev/null 2>&1; then fail "maintenance.auto became set in $clone"; fi
    assert_equals "file:.git/config" "$(git -C "$clone" config --show-origin --local --get maintenance.pack-refs.enabled | cut -f1)" \
      "the key is not in the clone's own .git/config"
  done
  pass "the key is written to every clone root - existing, behind, true, local-only, fetch-failing, no-origin, dirty, off-default - whatever its state"
}

test_key_write_is_idempotent_and_touches_only_the_key() {
  local home clone sum_before sum_after
  home=$(new_home)
  clone=$(build_pair "$home" kidem)
  git -C "$clone" config user.neighbour kept
  cp "$clone/.git/config" "$home/config-before"
  run_sync "$home" kidem >/dev/null
  assert_equals false "$(pack_key "$clone")" "first run did not write the key"
  # Every other byte of .git/config is untouched: with the two lines the key adds removed, the file is the one before.
  assert_equals "$(cat "$home/config-before")" "$(grep -vxE '\[maintenance "pack-refs"\]|[[:space:]]enabled = false' "$clone/.git/config")" \
    "the key write changed a byte of .git/config besides its own two lines"
  sum_before=$(cksum < "$clone/.git/config")
  run_sync "$home" kidem >/dev/null
  sum_after=$(cksum < "$clone/.git/config")
  assert_equals "$sum_before" "$sum_after" "a second run changed a byte of .git/config"
  assert_equals 1 "$(git -C "$clone" config --local --get-all maintenance.pack-refs.enabled | wc -l | tr -d ' ')" "the key is present more than once"
  pass "a second run leaves .git/config byte-identical, and only the key is added"
}

test_single_name_form_writes_the_key_and_a_non_root_is_untouched() {
  local home clone encl
  home=$(new_home)
  clone=$(build_pair "$home" ksingle)
  run_sync "$home" projects/ksingle >/dev/null
  assert_equals false "$(pack_key "$clone")" "the single-name form did not write the key"
  encl=$(build_enclosing_home keynonroot)
  mkdir -p "$encl/projects/not-a-clone/wt"
  run_sync "$encl" not-a-clone >/dev/null
  assert_equals "" "$(pack_key "$encl")" "a candidate that is not a clone root got the key written into the enclosing repository"
  pass "the single-name form writes the key, and a candidate that is not a clone root is untouched"
}

test_home_repository_gets_the_key_in_the_whole_fleet_form_only() {
  local encl plain out
  encl=$(build_enclosing_home keyhome)
  assert_equals "" "$(pack_key "$encl")" "the home fixture already carries the key"
  run_sync "$encl" nothing-here >/dev/null
  assert_equals "" "$(pack_key "$encl")" "the single-name form wrote the home repository's key"
  run_sync "$encl" >/dev/null
  assert_equals false "$(pack_key "$encl")" "the whole-fleet form did not write the home repository's key"
  plain=$(new_home)
  out=$(run_sync "$plain")
  assert_not_contains "$out" "maintenance.pack-refs" "a home that is not a git repository was reported on"
  [ ! -e "$plain/.git" ] || fail "a plain FM_HOME gained a .git"
  pass "the home repository gets the key in the whole-fleet form, and a plain home is left alone"
}

test_unwritable_config_warns_and_the_sync_continues() {
  local home clone out rc
  home=$(new_home)
  clone=$(build_pair "$home" klock)
  advance_origin "$home" klock C1
  : > "$clone/.git/config.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" klock 2>/dev/null)
  rc=$?
  assert_equals 0 "$rc" "a failed key write stopped fleet-sync"
  assert_contains "$out" "klock: warning: could not set maintenance.pack-refs.enabled=false: " "the failed write printed no warning on stdout"
  assert_contains "$out" "klock: synced" "the rest of the sync did not continue after the failed write"
  assert_equals "" "$(pack_key "$clone")" "the key appeared although config.lock blocked the write"
  # Bootstrap relays that line, so a session start shows it.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  assert_contains "$out" "FLEET_SYNC: klock: warning: could not set maintenance.pack-refs.enabled=false: " "bootstrap did not relay the warning"
  pass "an unwritable .git/config warns on stdout, the sync continues, and bootstrap relays the warning"
}

test_an_outranking_per_worktree_value_is_reported() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" kworktree)
  git -C "$clone" config extensions.worktreeConfig true
  printf '[maintenance "pack-refs"]\n\tenabled = true\n' > "$clone/.git/config.worktree"
  out=$(run_sync "$home" kworktree)
  assert_equals false "$(pack_key "$clone")" "the repository's own file did not get the key"
  assert_contains "$out" "kworktree: warning: maintenance.pack-refs.enabled is true in effect although .git/config sets false" \
    "a per-worktree value that outranks the key was not reported"
  out=$(run_sync "$home" kworktree)
  assert_contains "$out" "in effect although" "the outranked key was reported only once"
  pass "a per-worktree value that outranks the repository key is reported as a warning, because packing would still run"
}

test_the_whole_fleet_form_writes_every_key_before_the_first_fetch() {
  local home first second fakebin log out
  home=$(new_home)
  first=$(build_pair "$home" kfirst)
  second=$(build_pair "$home" ksecond)
  fakebin="$home/fb-order"; mkdir -p "$fakebin"; log="$home/fetch-order.log"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
# On every fetch, record which clones already carry the key.
for a in "$@"; do
  if [ "$a" = fetch ]; then
    for c in "${FM_FAKE_PROJECTS:?}"/*; do
      printf '%s=%s\n' "$(basename "$c")" "$("${REAL_GIT_FOR_TEST:?}" -C "$c" config --local --get maintenance.pack-refs.enabled 2>/dev/null)" >> "${FM_FAKE_ORDER_LOG:?}"
    done
    printf -- '--\n' >> "$FM_FAKE_ORDER_LOG"
    break
  fi
done
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$(command -v git)" FM_FAKE_PROJECTS="$home/projects" FM_FAKE_ORDER_LOG="$log" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" 2>/dev/null)
  [ -s "$log" ] || fail "the fake git saw no fetch, so the case proves nothing: $out"
  assert_equals "kfirst=false
ksecond=false" "$(sed -n '1,2p' "$log")" "a clone still lacked the key when the first fetch began"
  assert_equals false "$(pack_key "$first")" "first clone lost the key"
  assert_equals false "$(pack_key "$second")" "second clone lost the key"
  pass "the whole-fleet form writes every clone's key before the first fetch, so a slow fetch or a timeout cannot skip a later clone"
}

test_a_failing_git_root_lookup_skips_and_writes_nothing() {
  local home clone fakebin out
  home=$(new_home)
  clone=$(build_pair "$home" knogit)
  fakebin="$home/fb-nogit"; mkdir -p "$fakebin"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = --show-toplevel ] && exit 1; done
exec "${REAL_GIT_FOR_TEST:?}" "$@"
SH
  chmod +x "$fakebin/git"
  out=$(PATH="$fakebin:$PATH" REAL_GIT_FOR_TEST="$(command -v git)" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" knogit 2>/dev/null)
  assert_contains "$out" "knogit: skipped: not a git repo" "a failing root lookup was not skipped"
  assert_equals "" "$(pack_key "$clone")" "a clone whose root could not be computed got the key"
  pass "a failing clone-root lookup skips the candidate and writes nothing"
}

# --- branch-ref folder restore after the prune's last-ref delete (C4) --------

# build_gone_clone <home> <name> <branch...>: a clone that holds each branch as a loose
# local ref tracking an origin branch that origin then deletes, so fleet-sync's fetch
# --prune marks it gone and the prune deletes it. A branch named keep-* stays on origin.
build_gone_clone() {
  local home=$1 name=$2 clone work b
  shift 2
  clone=$(build_pair "$home" "$name")
  work="$home/work-$name"
  for b in "$@"; do
    git -C "$work" push -q origin "main:refs/heads/$b"
    git -C "$clone" fetch -q origin
    git -C "$clone" branch -q "$b" "origin/$b"
  done
  for b in "$@"; do
    case "$b" in */keep*) ;; *) git -C "$work" push -q origin --delete "$b" ;; esac
  done
  printf '%s\n' "$clone"
}

test_prune_restores_the_branch_ref_folder_after_the_last_ref() {
  local home clone out
  home=$(new_home)
  clone=$(build_gone_clone "$home" pruneA fm/gone1)
  [ -f "$clone/.git/logs/refs/heads/fm/gone1" ] || fail "fixture: the reflog of fm/gone1 is missing"
  out=$(run_sync "$home" pruneA)
  assert_contains "$out" "pruneA: pruned fm/gone1" "the prune line changed or the branch was not pruned"
  [ ! -e "$clone/.git/refs/heads/fm/gone1" ] || fail "the gone branch was not deleted"
  [ -d "$clone/.git/refs/heads/fm" ] || fail "refs/heads/fm was not restored after the last loose ref was deleted"
  [ -d "$clone/.git/logs/refs/heads/fm" ] || fail "logs/refs/heads/fm was not restored"
  pass "the prune restores refs/heads/fm and logs/refs/heads/fm after deleting the last loose fm ref"
}

test_prune_changes_nothing_when_other_refs_remain() {
  local home clone out
  home=$(new_home)
  clone=$(build_gone_clone "$home" pruneB fm/gone1 fm/keep1)
  out=$(run_sync "$home" pruneB)
  assert_contains "$out" "pruneB: pruned fm/gone1" "the prune line changed"
  assert_equals "keep1" "$(ls "$clone/.git/refs/heads/fm")" "refs/heads/fm holds something other than the surviving ref"
  assert_equals "keep1" "$(ls "$clone/.git/logs/refs/heads/fm")" "logs/refs/heads/fm holds something other than the surviving reflog"
  pass "a prune that leaves another loose fm ref changes nothing beside the delete"
}

test_prune_restores_the_folder_when_the_deleted_ref_was_only_packed() {
  local home clone out
  home=$(new_home)
  clone=$(build_gone_clone "$home" pruneC fm/gone1)
  git -C "$clone" pack-refs --all --prune
  [ ! -d "$clone/.git/refs/heads/fm" ] || fail "fixture: the folder survived the explicit pack"
  out=$(run_sync "$home" pruneC)
  assert_contains "$out" "pruneC: pruned fm/gone1" "the packed-only branch was not pruned"
  [ -d "$clone/.git/refs/heads/fm" ] || fail "refs/heads/fm was not restored after a packed-only delete"
  pass "a packed-only branch's prune leaves refs/heads/fm in place"
}

test_prune_restores_only_the_registered_prefix() {
  local home clone out
  home=$(new_home)
  mkdir -p "$home/data"
  printf -- '- pruneD [no-mistakes branch=fix/] - prefix fixture\n' > "$home/data/projects.md"
  clone=$(build_gone_clone "$home" pruneD fix/gone1)
  out=$(run_sync "$home" pruneD)
  assert_contains "$out" "pruneD: pruned fix/gone1" "the prune line changed"
  [ -d "$clone/.git/refs/heads/fix" ] || fail "the registered prefix folder fix was not restored"
  [ -d "$clone/.git/logs/refs/heads/fix" ] || fail "the registered prefix reflog folder was not restored"
  [ ! -e "$clone/.git/refs/heads/fm" ] || fail "a folder for the default prefix fm was made although the project registers fix/"
  pass "the restore follows the registered prefix (fix/) and never the hard-coded fm"
}

test_prune_never_follows_a_link_at_the_folder_path() {
  local home clone out outside
  home=$(new_home)
  mkdir -p "$home/data"
  printf -- '- pruneE [no-mistakes branch=team/fm/] - link fixture\n' > "$home/data/projects.md"
  clone=$(build_gone_clone "$home" pruneE team/fm/gone1)
  outside="$home/outside-target"
  mkdir -p "$outside"
  mv "$clone/.git/refs/heads/team" "$outside/team-real"
  ln -s "$outside/team-real" "$clone/.git/refs/heads/team"
  out=$(run_sync "$home" pruneE)
  [ ! -e "$outside/team-real/fm" ] || fail "the restore followed the link and made fm inside its target"
  assert_equals "team-real" "$(ls "$outside")" "the restore created something next to the link target"
  [ -L "$clone/.git/refs/heads/team" ] || fail "the link at refs/heads/team was replaced"
  assert_contains "$out" "pruneE: pruned team/fm/gone1" "the delete's own pruned line changed"
  assert_not_contains "$out" "error" "the link case changed the sync's own output"
  pass "a link at the folder path is never followed or replaced by the restore"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_no_origin_skipped
test_local_only_skipped
test_unresolvable_registry_posture_skipped
test_single_project_by_bare_name_resolves
test_single_project_by_bare_name_ignores_cwd_shadow
test_single_project_by_projects_relative_name_resolves
test_single_project_by_projects_relative_name_ignores_cwd_shadow
test_single_project_unresolvable_name_still_skips
test_whole_fleet_form
test_bootstrap_relays_recovered_and_stuck
test_orphaned_stale_packed_refs_lock_recovers
test_live_packed_refs_lock_is_never_removed
test_idle_cwd_in_clone_dir_does_not_block_recovery
test_real_git_packed_refs_owners_block_removal
test_linked_worktree_git_owner_blocks_removal
test_unusable_worktree_inventory_blocks_removal
test_unclassifiable_directory_holders_block_removal
test_transient_packed_refs_lock_self_clears
test_non_signature_fetch_failure_is_not_retried
test_non_clone_dir_never_syncs_the_enclosing_repo
test_non_clone_dir_named_directly_never_syncs_the_enclosing_repo
test_symlinked_clone_still_syncs
test_clone_root_named_by_another_spelling_still_syncs
test_key_is_written_for_every_clone_state
test_key_write_is_idempotent_and_touches_only_the_key
test_single_name_form_writes_the_key_and_a_non_root_is_untouched
test_home_repository_gets_the_key_in_the_whole_fleet_form_only
test_unwritable_config_warns_and_the_sync_continues
test_an_outranking_per_worktree_value_is_reported
test_the_whole_fleet_form_writes_every_key_before_the_first_fetch
test_a_failing_git_root_lookup_skips_and_writes_nothing
test_prune_restores_the_branch_ref_folder_after_the_last_ref
test_prune_changes_nothing_when_other_refs_remain
test_prune_restores_the_folder_when_the_deleted_ref_was_only_packed
test_prune_restores_only_the_registered_prefix
test_prune_never_follows_a_link_at_the_folder_path
