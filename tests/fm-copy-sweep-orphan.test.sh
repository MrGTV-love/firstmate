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
  install_fixture_driver
}

# A quiet process table and a closeout driver that models the release interface.
install_fixture_driver() {
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

# Locks <copy> in Vernant's format with a launcher that really ran and exited.
lock_with_gone_launcher() {  # <copy>
  local launcher
  sleep 0.1 &
  launcher=$!
  wait "$launcher"
  git -C "$CLONE" worktree lock --reason "vernant-session-active owner=launcher:$launcher launcher=$launcher" "$1"
}

# The class of <copy> in the sweep's last output.
class_of() {  # <copy>
  printf '%s\n' "$OUT" | awk -F '\t' -v c="$1" 'NF >= 4 && $3 == c { print $1; exit }'
}

sweep_status() {
  SWEEP_RC=0
  OUT=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$W/bin:$PATH" FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$W/no-pool" \
    FM_TEARDOWN_VERNANT_PYTHON="$W/python" bash "$ROOT/bin/fm-copy-sweep.sh" "$@" 2>&1) || SWEEP_RC=$?
  printf '%s\nexit=%s\n' "$OUT" "$SWEEP_RC"
}

sweep() {
  sweep_status "$@"
  [ "$SWEEP_RC" = 0 ] || fail "sweep failed: $SWEEP_RC"
}

test_squash_orphans() {
  make_squash_world
  sweep
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

make_later_edit_world() {
  local name line
  W="$TMP_ROOT/later-edit"
  HOMED="$W/home"
  CLONE="$HOMED/projects/example"
  mkdir -p "$HOMED/state" "$HOMED/config" "$HOMED/data" "$W/bin" "$W/no-pool"
  fm_git_init_commit "$CLONE"
  printf '.claude/worktrees/\nscripts/\n' > "$CLONE/.gitignore"
  for line in $(seq 1 100); do printf 'line %s\n' "$line"; done > "$CLONE/shared.txt"
  git -C "$CLONE" add .gitignore shared.txt
  git -C "$CLONE" commit -qm 'shared file'
  fm_git_add_origin "$CLONE" "$W/origin.git"
  git -C "$CLONE" fetch -q origin
  FORK=$(git -C "$CLONE" rev-parse HEAD)
  git -C "$CLONE" worktree add -qb fm/squashed "$CLONE/.claude/worktrees/source"
  SOURCE="$CLONE/.claude/worktrees/source"
  sed 's/^line 1$/line 1 delivered/' "$SOURCE/shared.txt" > "$W/edit" && cat "$W/edit" > "$SOURCE/shared.txt"
  git -C "$SOURCE" commit -qam 'delivered change'
  TIP=$(git -C "$SOURCE" rev-parse HEAD)
  git -C "$CLONE" merge --squash fm/squashed >/dev/null
  git -C "$CLONE" commit -qm 'squash delivered change'
  sed 's/^line 50$/line 50 later main edit/' "$CLONE/shared.txt" > "$W/edit" && cat "$W/edit" > "$CLONE/shared.txt"
  git -C "$CLONE" commit -qam 'later edit to the same file'
  git -C "$CLONE" push -q origin main
  git -C "$CLONE" worktree remove "$SOURCE"
  for name in locked unlocked; do
    git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/$name" "$TIP"
  done
  git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/conflict" "$FORK"
  CONFLICT="$CLONE/.claude/worktrees/conflict"
  sed 's/^line 50$/line 50 never delivered/' "$CONFLICT/shared.txt" > "$W/edit" && cat "$W/edit" > "$CONFLICT/shared.txt"
  git -C "$CONFLICT" commit -qam 'conflicting unlanded change'
  git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/unique" "$TIP"
  UNIQUE="$CLONE/.claude/worktrees/unique"
  sed 's/^line 90$/line 90 never delivered/' "$UNIQUE/shared.txt" > "$W/edit" && cat "$W/edit" > "$UNIQUE/shared.txt"
  git -C "$UNIQUE" commit -qam 'clean-merging unlanded change'
  for name in locked conflict unique; do
    lock_with_gone_launcher "$CLONE/.claude/worktrees/$name"
  done
  install_fixture_driver
}

test_report_predicts_apply_after_later_main_edit() {
  local refs_before refs_after heads_before heads_after locked unlocked conflict unique
  make_later_edit_world
  locked="$CLONE/.claude/worktrees/locked"
  unlocked="$CLONE/.claude/worktrees/unlocked"
  conflict="$CLONE/.claude/worktrees/conflict"
  unique="$CLONE/.claude/worktrees/unique"
  refs_before=$(git -C "$CLONE" for-each-ref)
  heads_before=$(git -C "$CLONE" worktree list --porcelain)
  sweep
  refs_after=$(git -C "$CLONE" for-each-ref)
  heads_after=$(git -C "$CLONE" worktree list --porcelain)
  assert_equals "$refs_before" "$refs_after" 'report moved a ref'
  assert_equals "$heads_before" "$heads_after" 'report moved a worktree'
  assert_equals PENDING-DRIVER "$(class_of "$locked")" 'report did not prove the locked squash copy'
  assert_equals REAPABLE-PROVEN "$(class_of "$unlocked")" 'report did not prove the unlocked squash copy'
  assert_equals HELD-UNPUSHED "$(class_of "$conflict")" 'report did not hold the conflicting copy'
  assert_equals HELD-UNPUSHED "$(class_of "$unique")" 'report did not hold the unique commit'
  assert_contains "$OUT" 'content already in the default branch' 'report named no content proof'
  sweep --apply
  assert_absent "$locked" 'apply left the copy the report listed'
  assert_absent "$unlocked" 'apply left the copy the report listed'
  assert_contains "$OUT" "REMOVED"$'\t'"$locked" 'apply did not report the locked removal'
  assert_contains "$OUT" "REMOVED"$'\t'"$unlocked" 'apply did not report the unlocked removal'
  assert_equals HELD-UNPUSHED "$(class_of "$conflict")" 'apply label differs from report for the conflicting copy'
  assert_equals HELD-UNPUSHED "$(class_of "$unique")" 'apply label differs from report for the unique commit'
  assert_present "$conflict/shared.txt" 'conflicting unlanded work was lost'
  assert_present "$unique/shared.txt" 'unique unlanded work was lost'
  pass 'after a later main edit to a squash-merged path, report and apply agree on every copy'
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
  printf '.claude/\n.import_linter_cache/\n.tac/\ngraft/\nunique.dat\n' > "$CLONE/.gitignore"
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm 'ignore fixture payloads'
  fm_git_add_origin "$CLONE" "$W/origin.git"
  git -C "$CLONE" fetch -q origin
  for name in cache scratch log generated unique missing mismatch; do
    git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/$name" origin/main
    case "$name" in
      cache|missing|mismatch) rel=.import_linter_cache/payload ;;
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
  */worktrees/missing/.import_linter_cache) rm -f "$3/payload" ;;
  */worktrees/mismatch/.import_linter_cache) printf 'corrupted fixture preservation\n' > "$3/payload" ;;
esac
COPY
  chmod +x "$W/bin/lsof" "$W/bin/cp"
}

test_preserved_classes() {
  local name rel source_hash key preserved found rc=0
  make_preserved_world
  for name in cache scratch log generated; do
    case "$name" in
      cache) rel=.import_linter_cache/payload ;;
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
      cache) rel=.import_linter_cache/payload ;;
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
  assert_equals 'missing bytes requiring preservation' "$(cat "$CLONE/.claude/worktrees/missing/.import_linter_cache/payload")" 'missing preserve lost original bytes'
  assert_equals 'mismatch bytes requiring preservation' "$(cat "$CLONE/.claude/worktrees/mismatch/.import_linter_cache/payload")" 'mismatched preserve lost original bytes'
  pass 'cache, scratch, log and generated bytes survive by hash; unique, missing and mismatched preservation hold'
}

make_regenerable_world() {  # [<world-name>]
  local name
  W="$TMP_ROOT/${1:-class-world}"
  HOMED="$W/home"
  CLONE="$HOMED/projects/example"
  mkdir -p "$HOMED/state" "$HOMED/config" "$HOMED/data" "$W/bin" "$W/no-pool"
  fm_git_init_commit "$CLONE"
  printf '.claude/\nscripts/\nbuild/\nunique.dat\n' > "$CLONE/.gitignore"
  for name in "${CLASS_NAMES[@]}"; do printf '%s/\n' "$name" >> "$CLONE/.gitignore"; done
  git -C "$CLONE" add .gitignore
  git -C "$CLONE" commit -qm 'ignore fixture payloads'
  fm_git_add_origin "$CLONE" "$W/origin.git"
  git -C "$CLONE" fetch -q origin
  for name in unlocked locked held-cache held-unique; do
    git -C "$CLONE" worktree add -q --detach "$CLONE/.claude/worktrees/$name" origin/main
  done
  install_fixture_driver
}

put_file() {  # <path> <text>
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1"
}

# Exactly the entries under <preserve> that belong to the regenerable class.
class_dirs_in() {  # <preserve>
  local name args=()
  for name in "${CLASS_NAMES[@]}"; do args+=(-o -name "$name"); done
  find "$1" -type d \( "${args[@]:1}" \) -print
}

test_regenerable_class() {
  local name unlocked locked key preserve
  CLASS_NAMES=(node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .cache)
  make_regenerable_world
  unlocked="$CLONE/.claude/worktrees/unlocked"
  locked="$CLONE/.claude/worktrees/locked"

  # Today's skip list names these at the root, so they never held the copy.
  for name in node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next; do
    put_file "$unlocked/$name/payload" "regenerable $name"
  done
  mkdir -p "$unlocked/node_modules/big"
  dd if=/dev/zero of="$unlocked/node_modules/big/blob" bs=1048576 count=11 2>/dev/null
  # Inside an ignored entry every name of the class counts at any depth.
  for name in "${CLASS_NAMES[@]}"; do
    put_file "$unlocked/.claude/deep/er/$name/payload" "nested regenerable $name"
  done
  # A near name, a plain file with a class name and a symlink with one all stay.
  put_file "$unlocked/.claude/deep/er/keep.txt" 'keep me'
  put_file "$unlocked/.claude/deep/er/node_modules2/keep.txt" 'near name'
  put_file "$unlocked/.claude/file/.cache" 'plain file with a class name'
  ln -s /nonexistent/target "$unlocked/.claude/file/venv"

  lock_with_gone_launcher "$locked"
  put_file "$locked/.cache/payload" 'regenerable cache'
  put_file "$locked/.turbo/payload" 'regenerable turbo'
  put_file "$locked/build/node_modules/payload" 'regenerable nested'
  put_file "$locked/build/keep.txt" 'keep build output'
  put_file "$locked/unique.dat" 'keep unique bytes'

  # The class never makes a held copy releasable.
  put_file "$CLONE/.claude/worktrees/held-cache/.cache/payload" 'held cache bytes'
  put_file "$CLONE/.claude/worktrees/held-unique/unique.dat" 'held unique bytes'
  put_file "$CLONE/.claude/worktrees/held-unique/node_modules/payload" 'held regenerable bytes'

  sweep
  assert_equals REAPABLE-PROVEN "$(class_of "$unlocked")" 'unlocked copy was not proven'
  assert_equals PENDING-DRIVER "$(class_of "$locked")" 'locked copy was not a driver candidate'
  assert_equals HELD-DIRTY "$(class_of "$CLONE/.claude/worktrees/held-cache")" 'class released a held copy'
  assert_equals HELD-DIRTY "$(class_of "$CLONE/.claude/worktrees/held-unique")" 'class released a held copy'
  assert_contains "$(printf '%s\n' "$OUT" | grep -F "$unlocked")" 'regenerable 0.01 GiB removed with it, not preserved' 'report row misses regenerable bytes'
  assert_contains "$(printf '%s\n' "$OUT" | grep -F "$locked")" 'regenerable 0.00 GiB removed with it, not preserved' 'report row misses regenerable bytes'
  assert_not_contains "$(printf '%s\n' "$OUT" | grep -F "$CLONE/.claude/worktrees/held-unique")" 'regenerable' 'a held row changed'
  assert_contains "$OUT" 'regenerable: 0.01 GiB in 2 proven copies, 0 proven copies not sized' 'report total misses regenerable bytes'

  sweep --apply
  assert_absent "$unlocked" 'unlocked copy was not removed'
  assert_absent "$locked" 'locked copy was not removed'
  assert_contains "$(printf '%s\n' "$OUT" | grep -F "REMOVED"$'\t'"$unlocked")" 'preserved 0.00 GiB, net freed 0.01 GiB' 'regenerable bytes were not freed'

  key=$(printf '%s' "$unlocked" | shasum -a 256 | cut -d ' ' -f 1)
  preserve=$(printf '%s\n' "$HOMED/data/copy-sweep/"*/nested-copy-preserved/"$key")
  assert_equals 'keep me' "$(cat "$preserve/.claude/deep/er/keep.txt")" 'other ignored bytes were not preserved'
  assert_equals 'near name' "$(cat "$preserve/.claude/deep/er/node_modules2/keep.txt")" 'a near name was treated as the class'
  assert_equals 'plain file with a class name' "$(cat "$preserve/.claude/file/.cache")" 'a plain file was treated as the class'
  [ -L "$preserve/.claude/file/venv" ] || fail 'a symlink was treated as the class'
  assert_equals '' "$(class_dirs_in "$preserve")" 'unlocked preserve holds a regenerable directory'
  assert_contains "$(cat "$preserve/SHA256SUMS")" '.claude/deep/er/keep.txt' 'manifest misses a preserved file'

  key=$(printf '%s' "$locked" | shasum -a 256 | cut -d ' ' -f 1)
  preserve=$(printf '%s\n' "$HOMED/data/copy-sweep/"*/nested-copy-preserved/"$key")
  assert_equals 'keep build output' "$(cat "$preserve/build/keep.txt")" 'locked ignored bytes were not preserved'
  assert_equals 'keep unique bytes' "$(cat "$preserve/unique.dat")" 'locked unique bytes were not preserved'
  assert_equals '' "$(class_dirs_in "$preserve")" 'locked preserve holds a regenerable directory'

  assert_equals 'held cache bytes' "$(cat "$CLONE/.claude/worktrees/held-cache/.cache/payload")" 'held copy changed'
  assert_equals 'held unique bytes' "$(cat "$CLONE/.claude/worktrees/held-unique/unique.dat")" 'held copy changed'
  assert_equals 'held regenerable bytes' "$(cat "$CLONE/.claude/worktrees/held-unique/node_modules/payload")" 'held copy changed'
  pass 'the closed regenerable class goes with a proven copy, other ignored paths survive by hash, and held copies are unchanged'
}

# A write to a regenerable directory is activity: it stops the release that sees
# it, then keeps a locked copy WAITING until a run finds it unchanged.
test_regenerable_write_keeps_waiting() {
  local name locked unlocked real_cp key preserve found
  CLASS_NAMES=(node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .cache)
  real_cp=$(command -v cp)
  for name in .cache node_modules; do
    make_regenerable_world "writer$name"
    locked="$CLONE/.claude/worktrees/locked"
    unlocked="$CLONE/.claude/worktrees/unlocked"
    lock_with_gone_launcher "$locked"
    put_file "$locked/$name/tick" 'v0'
    put_file "$locked/unique.dat" 'keep unique bytes'
    put_file "$unlocked/.claude/sub/$name/tick" 'v0'
    put_file "$unlocked/.claude/keep.txt" 'keep me'
    cat > "$W/bin/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf 'copy process %s\\n' "\$\$" > "$locked/$name/tick"
printf 'copy process %s\\n' "\$\$" > "$unlocked/.claude/sub/$name/tick"
SH
    chmod +x "$W/bin/cp"

    sweep_status --apply
    assert_equals 1 "$SWEEP_RC" "$name: a write during preservation must fail the run"
    assert_contains "$OUT" 'changed after it was preserved' "$name: locked release did not see the write"
    assert_contains "$OUT" "FAILED"$'\t'"$unlocked"$'\t'"ignored payload changed" "$name: unlocked removal did not see the write"
    assert_present "$locked/$name/tick" "$name: a locked copy was released during a write"
    assert_present "$unlocked/.claude/sub/$name/tick" "$name: an unlocked copy was removed during a write"
    rm -f "$W/bin/cp"

    printf 'v2\n' > "$locked/$name/tick"
    sweep_status
    assert_equals WAITING "$(class_of "$locked")" "$name: report did not show the writer as WAITING"
    printf 'v3\n' > "$locked/$name/tick"
    sweep --apply
    assert_equals WAITING "$(class_of "$locked")" "$name: apply did not hold the writer as WAITING"
    assert_contains "$OUT" 'content changing' "$name: WAITING reason missing"
    assert_present "$locked/$name/tick" "$name: a changing copy was released"
    assert_absent "$unlocked" "$name: a quiet unlocked copy was not removed"

    sweep --apply
    assert_contains "$OUT" "REMOVED"$'\t'"$locked" "$name: the first quiet run did not release the copy"
    assert_absent "$locked" "$name: the first quiet run left the copy"
    key=$(printf '%s' "$locked" | shasum -a 256 | cut -d ' ' -f 1)
    found=0
    for preserve in "$HOMED/data/copy-sweep/"*/nested-copy-preserved/"$key"; do
      [ -d "$preserve" ] || continue
      found=$((found + 1))
      assert_equals 'keep unique bytes' "$(cat "$preserve/unique.dat")" "$name: unique bytes were not preserved"
      assert_equals '' "$(class_dirs_in "$preserve")" "$name: a preserve holds a regenerable directory"
    done
    assert_equals 1 "$found" "$name: the release after WAITING needs exactly one concrete preserve"
  done
  pass 'a write inside .cache or node_modules stops a release and keeps a locked copy WAITING until it is quiet'
}

# check fingerprints under its time bound. That route must read the same file
# bytes as report, or a quiet copy reads as still changing in the budget wake.
assert_check_names_pending_driver() {  # <mechanism-label>
  rm -f "$HOMED/state/copy-sweep.record"
  FM_CHECK_TIMEOUT=120 sweep check
  assert_contains "$OUT" 'GiB PENDING-DRIVER' "$1: check did not name the quiet copy PENDING-DRIVER"
  assert_not_contains "$OUT" 'WAITING' "$1: check read a quiet copy as WAITING"
}

test_check_matches_report_for_quiet_waiting_copy() {
  local locked real_cp key
  CLASS_NAMES=(node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .cache)
  real_cp=$(command -v cp)
  make_regenerable_world check-world
  locked="$CLONE/.claude/worktrees/locked"
  lock_with_gone_launcher "$locked"
  put_file "$locked/.cache/tick" 'v0'
  put_file "$locked/unique.dat" 'keep unique bytes'
  cat > "$W/bin/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf 'copy process %s\\n' "\$\$" > "$locked/.cache/tick"
SH
  chmod +x "$W/bin/cp"
  sweep_status --apply
  assert_equals 1 "$SWEEP_RC" 'a write during preservation must fail the run'
  rm -f "$W/bin/cp"
  key=$(printf '%s' "$locked" | shasum -a 256 | cut -d ' ' -f 1)
  assert_present "$HOMED/data/copy-sweep/waiting/$key" 'the fixture needs a waiting record'
  printf 'default-container 0\ndefault-pool off\nload-limit 100000\n' > "$HOMED/config/copy-budget"

  sweep
  assert_equals PENDING-DRIVER "$(class_of "$locked")" 'report did not read the quiet copy as PENDING-DRIVER'
  assert_check_names_pending_driver default
  FM_TIMEOUT_MECHANISM_OVERRIDE=bash assert_check_names_pending_driver bash
  sweep
  assert_equals PENDING-DRIVER "$(class_of "$locked")" 'report changed after check'
  pass 'check and report give a quiet waiting copy with file bytes the same class'
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
  rc=0
  fm_task_copy_ps_observation_state 42 1 '' $'ps: process id too large: 42\n' || rc=$?
  assert_equals 1 "$rc" 'the macOS not-found line for this PID must prove absence'
  local diagnostic
  for diagnostic in \
    $'ps: process id too large: 43\n' \
    $'ps: process id too large: 421\n' \
    'ps: process id too large: 42' \
    $'ps: process id too large: 42\n\n' \
    $'warning\nps: process id too large: 42\n' \
    $'ps: process id too large: 42\nps: failed\n' \
    $'ps: process id too large\n' \
    $'PS: PROCESS ID TOO LARGE: 42\n'; do
    rc=0
    fm_task_copy_ps_observation_state 42 1 '' "$diagnostic" || rc=$?
    assert_equals 2 "$rc" "a diagnostic other than the exact line must remain unknown: $diagnostic"
  done
  rc=0
  fm_task_copy_ps_observation_state 42 1 '42' $'ps: process id too large: 42\n' || rc=$?
  assert_equals 2 "$rc" 'the not-found line with stdout must remain unknown'
  rc=0
  fm_task_copy_ps_observation_state 42 2 '' $'ps: process id too large: 42\n' || rc=$?
  assert_equals 2 "$rc" 'the not-found line on another exit must remain unknown'
  rc=0
  fm_task_copy_launcher_state 999999 || rc=$?
  assert_equals 1 "$rc" 'an impossible PID on this host must be proved absent'
  pass 'only the exact not-found line for this PID joins empty absence; every other diagnostic stays unknown'
}

fm_test_only
test_squash_orphans
test_report_predicts_apply_after_later_main_edit
test_confined_launcher_observation
test_preserved_classes
test_regenerable_class
test_regenerable_write_keeps_waiting
test_check_matches_report_for_quiet_waiting_copy
test_ps_observation_diagnostics
