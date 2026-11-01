#!/usr/bin/env bash
# Squash-content orphan boundaries through the actual sweep, without changing
# the existing copy-sweep suite. All repositories and closeout drivers are local
# disposable fixtures; the driver only models the existing release interface.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-copy-sweep-orphan)
fm_git_identity

make_squash_world() {
  W="$TMP_ROOT/squash"
  HOMED="$W/home"
  CLONE="$HOMED/projects/example"
  mkdir -p "$HOMED/state" "$HOMED/config" "$HOMED/data" "$W/bin" "$W/no-pool"
  fm_git_init_commit "$CLONE"
  printf '.claude/worktrees/\nscripts/\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm 'ignore fixture machinery'
  fm_git_add_origin "$CLONE" "$W/origin.git"
  git -C "$CLONE" fetch -q origin
  git -C "$CLONE" worktree add -qb fm/squashed "$CLONE/.claude/worktrees/clean"
  CLEAN="$CLONE/.claude/worktrees/clean"
  printf 'first\n' > "$CLEAN/feature.txt"
  git -C "$CLEAN" add feature.txt
  git -C "$CLEAN" commit -qm 'first local change'
  printf 'second\n' >> "$CLEAN/feature.txt"
  git -C "$CLEAN" commit -qam 'second local change'
  TIP=$(git -C "$CLEAN" rev-parse HEAD)
  git -C "$CLONE" merge --squash fm/squashed >/dev/null
  git -C "$CLONE" commit -qm 'squash delivered changes'
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" merge-base --is-ancestor "$TIP" origin/main && fail 'fixture is not a squash merge'
  for name in unique tracked untracked; do
    git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/$name" "$TIP"
  done
  printf 'not delivered\n' > "$CLONE/.claude/worktrees/unique/unique.txt"
  git -C "$CLONE/.claude/worktrees/unique" add unique.txt
  git -C "$CLONE/.claude/worktrees/unique" commit -qm 'unique unlanded content'
  printf 'dirty\n' >> "$CLONE/.claude/worktrees/tracked/feature.txt"
  printf 'untracked bytes\n' > "$CLONE/.claude/worktrees/untracked/new.txt"
  for name in clean unique tracked untracked; do
    git -C "$CLONE" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$CLONE/.claude/worktrees/$name"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/lsof"
  mkdir -p "$CLONE/scripts/git-stability"
  cat > "$CLONE/scripts/git-stability/closeout_pr.py" <<'DRIVER'
if [ "${3:-}" != --execute-cleanup ]; then
  printf '{"allowed":true}\n'
  exit 0
fi
git worktree unlock "$2" && git worktree remove "$2"
DRIVER
  printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$W/python"
  chmod +x "$W/python" "$W/bin/lsof"
}

sweep() {
  local rc=0
  OUT=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$W/bin:$PATH" FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$W/no-pool" \
    FM_TEARDOWN_VERNANT_PYTHON="$W/python" bash "$ROOT/bin/fm-copy-sweep.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$OUT" "$rc"
  [ "$rc" = 0 ] || fail "sweep failed: $rc"
}

test_squash_orphans() {
  local before after
  make_squash_world
  # A report must not create merge-tree objects in a real repository.
  before=$(find "$CLONE/.git/objects" -type f | LC_ALL=C sort)
  sweep
  after=$(find "$CLONE/.git/objects" -type f | LC_ALL=C sort)
  assert_equals "$before" "$after" 'dry-run content proof wrote repository objects'
  assert_contains "$OUT" "PENDING-DRIVER" 'clean locked squash was not a driver candidate'
  assert_contains "$OUT" 'content already in the default branch' 'squash content proof missing'
  assert_present "$CLEAN" 'report removed a copy'
  sweep --apply
  assert_absent "$CLEAN" 'squash-contained clean orphan was not reaped'
  assert_present "$CLONE/.claude/worktrees/unique/unique.txt" 'unique commit was lost'
  assert_present "$CLONE/.claude/worktrees/tracked" 'tracked modification was lost'
  assert_present "$CLONE/.claude/worktrees/untracked/new.txt" 'untracked bytes were lost'
  assert_contains "$OUT" 'HELD-UNPUSHED' 'unique commit was not held'
  assert_contains "$OUT" 'HELD-DIRTY' 'uncommitted work was not held'
  assert_equals 'second' "$(tail -n 1 "$CLONE/.claude/worktrees/unique/feature.txt")" 'delivered bytes changed'
  pass 'locked squash-contained orphan is reaped; a unique commit, tracked edit and untracked file are held'
}

test_confined_launcher_observation() {
  # The sourceable task-copy API performs no home scan. Test doubles below
  # model unreadable/malformed helper responses, never ps output.
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local live rc=0
  sleep 60 &
  live=$!
  if [ "$(uname -s)" = Darwin ]; then
    fm_task_copy_confined_launcher_state "$live" || rc=$?
  else
    fm_task_copy_launcher_state "$live" || rc=$?
  fi
  # Always retire our fixture, including on an assertion failure.
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  assert_equals 0 "$rc" 'live launcher was not positively observed'
  rc=0
  if [ "$(uname -s)" = Darwin ]; then
    fm_task_copy_confined_launcher_state "$live" || rc=$?
  else
    fm_task_copy_launcher_state "$live" || rc=$?
  fi
  assert_equals 1 "$rc" 'exited launcher was not proved absent'
  (
    python3() { return 1; }
    rc=0
    fm_task_copy_confined_launcher_state "$live" || rc=$?
    assert_equals 2 "$rc" 'failed helper was mistaken for absence'
    python3() { printf '%s\n' ''; }
    rc=0
    fm_task_copy_confined_launcher_state "$live" || rc=$?
    assert_equals 2 "$rc" 'empty observation was mistaken for absence'
    python3() { printf '%s\n' 1 unreadable; }
    rc=0
    fm_task_copy_confined_launcher_state "$live" || rc=$?
    assert_equals 2 "$rc" 'partial malformed observation was mistaken for absence'
  ) || fail 'unknown launcher boundaries failed'
  pass 'live launcher holds, exited launcher is absent, failed or incomplete observations remain unknown'
}

make_preserved_world() {
  W="$TMP_ROOT/preserved"
  HOMED="$W/home"
  CLONE="$HOMED/projects/example"
  mkdir -p "$HOMED/state" "$HOMED/config" "$HOMED/data" "$W/bin" "$W/no-pool"
  fm_git_init_commit "$CLONE"
  printf '.claude/\n.pytest_cache/\n.tac/\ngraft/\nunique.dat\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm 'ignore fixture payloads'
  fm_git_add_origin "$CLONE" "$W/origin.git"
  git -C "$CLONE" fetch -q origin
  for name in cache scratch log generated unique missing mismatch; do
    git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/$name" origin/main
    case "$name" in
      cache|missing|mismatch) rel=.pytest_cache/payload ;;
      scratch) rel=.tac/tmp/payload ;;
      log) rel=.claude/logs/payload ;;
      generated) rel=graft/payload ;;
      unique) rel=unique.dat ;;
    esac
    mkdir -p "$(dirname "$CLONE/.claude/worktrees/$name/$rel")"
    printf '%s bytes requiring preservation\n' "$name" > "$CLONE/.claude/worktrees/$name/$rel"
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/lsof"
  # Inject preservation failures only in the disposable fixture. The ordinary
  # copy command still runs; actual preserved bytes are then absent or changed.
  REAL_CP=$(command -v cp)
  export REAL_CP
  cat > "$W/bin/cp" <<'COPY'
#!/usr/bin/env bash
"$REAL_CP" "$@" || exit $?
case "${2:-}" in
  */worktrees/missing/.pytest_cache) rm -f "$3/payload" ;;
  */worktrees/mismatch/.pytest_cache) printf 'corrupted fixture preservation\n' > "$3/payload" ;;
esac
COPY
  chmod +x "$W/bin/lsof" "$W/bin/cp"
}

test_preserved_classes() {
  local name rel source_hash key preserved found rc=0
  make_preserved_world
  for name in cache scratch log generated; do
    case "$name" in
      cache) rel=.pytest_cache/payload ;;
      scratch) rel=.tac/tmp/payload ;;
      log) rel=.claude/logs/payload ;;
      generated) rel=graft/payload ;;
    esac
    shasum -a 256 "$CLONE/.claude/worktrees/$name/$rel" > "$W/$name.sha256"
  done
  OUT=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$W/bin:$PATH" FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$W/no-pool" \
    bash "$ROOT/bin/fm-copy-sweep.sh" --apply 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$OUT" "$rc"
  assert_equals 1 "$rc" 'failed preservation must fail the apply run'
  for name in cache scratch log generated; do
    case "$name" in
      cache) rel=.pytest_cache/payload ;;
      scratch) rel=.tac/tmp/payload ;;
      log) rel=.claude/logs/payload ;;
      generated) rel=graft/payload ;;
    esac
    source_hash=$(cut -d ' ' -f 1 "$W/$name.sha256")
    key=$(printf '%s' "$CLONE/.claude/worktrees/$name" | shasum -a 256 | cut -d ' ' -f 1)
    found=0
    for preserved in "$HOMED/data/copy-sweep/"*/nested-copy-preserved/"$key"; do
      [ -d "$preserved" ] || continue
      found=$((found + 1))
      assert_equals "$source_hash" "$(shasum -a 256 "$preserved/$rel" | cut -d ' ' -f 1)" "$name preserved bytes differ"
      assert_contains "$(cat "$preserved/SHA256SUMS")" "$source_hash  $rel" "$name manifest misses the actual bytes"
      printf 'class=%s source_sha256=%s preserved=%s preserved_sha256=%s disposition=removed\n' "$name" "$source_hash" "$preserved/$rel" "$source_hash"
    done
    assert_equals 1 "$found" "$name needs exactly one concrete preservation"
    assert_absent "$CLONE/.claude/worktrees/$name" "$name copy was not reclaimed"
  done
  for name in unique missing mismatch; do
    assert_present "$CLONE/.claude/worktrees/$name" "$name must hold"
  done
  assert_equals 'unique bytes requiring preservation' "$(cat "$CLONE/.claude/worktrees/unique/unique.dat")" 'unique non-cache payload changed'
  assert_equals 'missing bytes requiring preservation' "$(cat "$CLONE/.claude/worktrees/missing/.pytest_cache/payload")" 'missing preserve lost original bytes'
  assert_equals 'mismatch bytes requiring preservation' "$(cat "$CLONE/.claude/worktrees/mismatch/.pytest_cache/payload")" 'mismatched preserve lost original bytes'
  pass 'cache, scratch, log and generated bytes survive by hash; unique, missing and mismatched preservation hold'
}

test_ps_observation_diagnostics() {
  # Exercise completed observation data only: no ps shim or unavailable probe.
  # shellcheck source=bin/fm-task-copy-lib.sh
  . "$ROOT/bin/fm-task-copy-lib.sh"
  local rc=0
  fm_task_copy_ps_observation_state 42 1 '' 'ps: failed to read process information' || rc=$?
  printf 'diagnostic_exit1_state=%s expected_unknown=2\n' "$rc"
  assert_equals 2 "$rc" 'diagnostic-bearing failed process read must remain unknown'
  rc=0
  fm_task_copy_ps_observation_state 42 1 '' '' || rc=$?
  assert_equals 1 "$rc" 'successful absence observation changed'
  rc=0
  fm_task_copy_ps_observation_state 42 0 ' 42 ' '' || rc=$?
  assert_equals 0 "$rc" 'matching live PID must hold'
  rc=0
  fm_task_copy_ps_observation_state 42 0 '43' '' || rc=$?
  assert_equals 2 "$rc" 'mismatched PID must remain unknown'
  rc=0
  fm_task_copy_ps_observation_state 42 1 '42' '' || rc=$?
  assert_equals 2 "$rc" 'failed read with partial PID must remain unknown'
  rc=0
  fm_task_copy_ps_observation_state 42 0 '' '' || rc=$?
  assert_equals 2 "$rc" 'missing PID on successful read must remain unknown'
  rc=0
  fm_task_copy_ps_observation_state 42 1 '' $'\n' || rc=$?
  assert_equals 2 "$rc" 'whitespace diagnostic must not disappear into absence'
  rc=0
  fm_task_copy_ps_observation_state 42 2 '' 'unreadable' || rc=$?
  assert_equals 2 "$rc" 'other observation errors must remain unknown'
  pass 'diagnostic-bearing failures stay unknown; empty absence and matching live PID keep their verdicts'
}

fm_test_only
test_squash_orphans
test_confined_launcher_observation
test_preserved_classes
test_ps_observation_diagnostics
