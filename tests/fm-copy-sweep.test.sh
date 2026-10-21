#!/usr/bin/env bash
# Behavioral coverage for bin/fm-copy-sweep.sh: the proof matrix, the report-only
# default, the one-wake byte budget, the load guard and du limits, the lane-home
# view, and the refusal to force anything. Every world is a throwaway directory under a temp root with
# real `git worktree add` copies; no real pool, home, state file or backlog is
# read or written. FM_COPY_SWEEP_BIN points the suite at a mutant of the script
# to prove each assertion can fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copy-sweep)
SWEEP=${FM_COPY_SWEEP_BIN:-$ROOT/bin/fm-copy-sweep.sh}
ORIGINAL_PATH=$PATH
REAL_GIT=$(command -v git)
REAL_RM=$(command -v rm)
GIB=1048576
fm_git_identity

# Sets W, HOMED, TH, SLOT, FAKEBIN for a fresh world: a Firstmate home, a
# Treehouse root with one pool slot whose clone has a local bare origin, and the
# fake tools every case runs against.
make_world() {  # <name>
  W="$TMP_ROOT/$1"
  HOMED="$W/home"
  TH="$W/th"
  SLOT="$TH/pool1/1/repo"
  FAKEBIN="$W/fakebin"
  mkdir -p "$HOMED/state" "$HOMED/config" "$HOMED/data" "$TH/pool1/1" "$FAKEBIN"
  fm_git_init_commit "$SLOT"
  fm_git_add_origin "$SLOT" "$W/origin.git"
  git -C "$SLOT" fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
  : > "$W/du-table"
  install_fakes
}

install_fakes() {
  cat > "$FAKEBIN/lsof" <<'EOF'
#!/usr/bin/env bash
[ -z "${FAKE_LSOF_SLEEP:-}" ] || sleep "$FAKE_LSOF_SLEEP"
[ -n "${FAKE_LSOF_CWD:-}" ] || exit 0
printf 'p4242\nfcwd\nn%s\n' "$FAKE_LSOF_CWD"
EOF
  cat > "$FAKEBIN/uptime" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_UPTIME_STYLE:-mac}" = linux ]; then
  printf ' 10:00:00 up 1 day,  1 user,  load average: %s, 1.00, 1.00\n' "${FAKE_LOAD:-0.50}"
else
  printf '10:00  up 1 day,  1 user,  load averages: %s 1.00 1.00\n' "${FAKE_LOAD:-0.50}"
fi
EOF
  cat > "$FAKEBIN/nice" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_NICE_LOG"
[ "$1" = -n ] && [ "$2" = 20 ] || exit 99
shift 2
exec "$@"
EOF
  cat > "$FAKEBIN/du" <<'EOF'
#!/usr/bin/env bash
path=${*: -1}
mkdir -p "$FAKE_DU_ACTIVE"
: > "$FAKE_DU_ACTIVE/$$"
find "$FAKE_DU_ACTIVE" -type f | wc -l | tr -d ' ' >> "$FAKE_DU_LOG.conc"
sleep "${FAKE_DU_SLEEP:-0.05}"
rm -f "$FAKE_DU_ACTIVE/$$"
printf '%s\n' "$path" >> "$FAKE_DU_LOG"
kib=$(awk -F '\t' -v p="$path" '$1 == p { print $2 }' "$FAKE_DU_TABLE")
printf '%s\t%s\n' "${kib:-100}" "$path"
EOF
  cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
case " $* " in
  *" worktree remove "*)
    if [ -n "${FAKE_GIT_FAIL_REMOVE:-}" ]; then
      echo "fatal: injected failure" >&2
      exit 1
    fi
    ;;
  *" status "*)
    [ -z "${FAKE_GIT_SLEEP_STATUS:-}" ] || sleep "$FAKE_GIT_SLEEP_STATUS"
    ;;
  *" rev-parse --git-dir "*)
    [ -z "${FAKE_GIT_SLEEP_ENUM:-}" ] || sleep "$FAKE_GIT_SLEEP_ENUM"
    ;;
  *" rev-parse --show-toplevel "*)
    [ -z "${FAKE_GIT_SLEEP_HOME:-}" ] || sleep "$FAKE_GIT_SLEEP_HOME"
    ;;
  *" ls-files "*)
    if [ -n "${FAKE_GIT_FAIL_LSFILES:-}" ]; then
      echo "fatal: injected ls-files failure" >&2
      exit 128
    fi
    ;;
esac
exec "$FAKE_REAL_GIT" "$@"
EOF
  cat > "$FAKEBIN/rm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_RM_LOG"
exec "$FAKE_REAL_RM" "$@"
EOF
  cat > "$FAKEBIN/treehouse" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_TREEHOUSE_LOG"
exit 0
EOF
  chmod +x "$FAKEBIN"/*
}

# Runs the sweep in the current world; sets OUT and RC.
run_sweep() {
  RC=0
  OUT=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$FAKEBIN:$ORIGINAL_PATH" FAKE_REAL_GIT="$REAL_GIT" FAKE_REAL_RM="$REAL_RM" \
    FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" \
    FAKE_DU_TABLE="$W/du-table" FAKE_DU_LOG="$W/du.log" FAKE_DU_ACTIVE="$W/du-active" \
    FAKE_NICE_LOG="$W/nice.log" FAKE_GIT_LOG="$W/git.log" FAKE_RM_LOG="$W/rm.log" \
    FAKE_TREEHOUSE_LOG="$W/treehouse.log" \
    "$SWEEP" "$@" 2>&1) || RC=$?
}

# add_copy <name>: a nested copy of the slot on branch fm/<name>, one commit,
# pushed to the origin: clean, on a remote, nobody's.
add_copy() {
  local name=$1 copy="$SLOT/.claude/worktrees/$1"
  git -C "$SLOT" worktree add -q -b "fm/$name" "$copy"
  printf '%s\n' "$name" > "$copy/$name.txt"
  git -C "$copy" add "$name.txt"
  git -C "$copy" commit -qm "$name"
  git -C "$copy" push -q origin "fm/$name"
}

copy_path() { printf '%s\n' "$SLOT/.claude/worktrees/$1"; }

# A file listing and the sha256 of every file, so "byte-identical" is literal.
snap() {  # <dir>
  local dir=$1
  (
    cd "$dir" || exit 1
    find . -print | LC_ALL=C sort
    find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
  )
}

class_of() {  # <name> -> class of nested copy <name> in $OUT
  printf '%s\n' "$OUT" | awk -F '\t' -v p="$(copy_path "$1")" '$3 == p { print $1 }'
}

assert_class() {  # <name> <class>
  local got
  got=$(class_of "$1")
  [ "$got" = "$2" ] || fail "copy $1 should be $2, got '${got:-none}': $OUT"
}

registered() {  # <name> -> 0 when the slot still registers the copy
  git -C "$SLOT" worktree list --porcelain | grep -qxF "worktree $(copy_path "$1")"
}

du_calls() { [ -f "$W/du.log" ] && wc -l < "$W/du.log" | tr -d ' ' || printf '0\n'; }

# The classes the matrix needs, one copy of each.
make_matrix() {  # <name>
  make_world "$1"
  add_copy reap
  add_copy dirty
  printf 'scratch\n' > "$(copy_path dirty)/untracked.txt"
  add_copy unpushed
  git -C "$SLOT" worktree add -q -b fm/unpushed-extra "$SLOT/.claude/worktrees/unpushed2"
  printf 'x\n' > "$SLOT/.claude/worktrees/unpushed2/local.txt"
  git -C "$SLOT/.claude/worktrees/unpushed2" add local.txt
  git -C "$SLOT/.claude/worktrees/unpushed2" commit -qm local-only
  printf 'y\n' > "$(copy_path unpushed)/local.txt"
  git -C "$(copy_path unpushed)" add local.txt
  git -C "$(copy_path unpushed)" commit -qm local-only
  add_copy live
  fm_write_meta "$HOMED/state/live-task.meta" "worktree=$(copy_path live)" "kind=ship"
  add_copy orphan
  printf 'garbage\n' > "$(copy_path orphan)/.git"
  add_copy locked
  git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$(copy_path locked)"
  add_copy proc
}

take_snapshots() {  # <suffix> <names...>
  local suffix=$1 name
  shift
  for name in "$@"; do
    snap "$(copy_path "$name")" > "$W/snap-$name-$suffix"
  done
}

assert_untouched() {  # <names...>: before and after snapshots match
  local name
  for name in "$@"; do
    cmp -s "$W/snap-$name-before" "$W/snap-$name-after" \
      || fail "copy $name is no longer byte-identical: $(diff "$W/snap-$name-before" "$W/snap-$name-after" | head -5)"
    registered "$name" || fail "copy $name is no longer registered with its clone"
  done
}

HELD_NAMES=(dirty unpushed unpushed2 live orphan locked proc)

test_report_lists_every_copy_and_changes_nothing() {
  local first second
  make_matrix report
  take_snapshots before reap "${HELD_NAMES[@]}"
  git -C "$SLOT" worktree list --porcelain > "$W/list-before"
  FAKE_LSOF_CWD="$(copy_path proc)/sub" run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  first=$OUT
  assert_class reap REAPABLE-PROVEN
  assert_class dirty HELD-DIRTY
  assert_class unpushed HELD-UNPUSHED
  assert_class unpushed2 HELD-UNPUSHED
  assert_class live HELD-LIVE-TASK
  assert_class orphan ORPHAN-NO-RECORD
  assert_class locked HELD-LOCKED
  assert_class proc HELD-LIVE-TASK
  assert_contains "$OUT" "task live-task's active record names it as its worktree" "report did not name the live record"
  assert_contains "$OUT" "process 4242 is running inside it" "report did not name the process"
  assert_contains "$OUT" "launcher 999999 is gone" "report did not explain the Vernant lock"
  assert_contains "$OUT" "untracked.txt" "report did not name the untracked file"
  assert_contains "$OUT" "summary: REAPABLE-PROVEN=1" "report summary missing"
  take_snapshots after reap "${HELD_NAMES[@]}"
  assert_untouched reap "${HELD_NAMES[@]}"
  git -C "$SLOT" worktree list --porcelain > "$W/list-after"
  cmp -s "$W/list-before" "$W/list-after" || fail "report changed the worktree registrations"
  assert_absent "$HOMED/data/copy-sweep.log" "report wrote a removal log"
  assert_absent "$HOMED/state/copy-sweep.record" "report wrote a budget record"
  assert_absent "$HOMED/state/copy-sweep.sizes" "report wrote a size cache"
  assert_absent "$HOMED/state/.wake-queue" "report raised a wake"
  FAKE_LSOF_CWD="$(copy_path proc)/sub" run_sweep
  second=$OUT
  [ "$first" = "$second" ] || fail "a second report differs from the first: $(diff <(printf '%s\n' "$first") <(printf '%s\n' "$second") | head -5)"
  pass "report mode lists every copy with class and reason, changes nothing, and repeats exactly"
}

test_apply_removes_only_the_reapable_copy() {
  make_matrix apply
  take_snapshots before "${HELD_NAMES[@]}"
  FAKE_LSOF_CWD="$(copy_path proc)/sub" run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path reap)" "apply did not report the removal"
  assert_class dirty HELD-DIRTY
  assert_class live HELD-LIVE-TASK
  assert_contains "$OUT" "summary: REAPABLE-PROVEN=0" "the post-removal report still counts the removed copy"
  assert_contains "$OUT" "summary: HELD-LIVE-TASK=2" "the post-removal report lost the held copies"
  [ ! -e "$(copy_path reap)" ] || fail "the REAPABLE-PROVEN copy is still on disk"
  ! registered reap || fail "the removed copy is still registered"
  take_snapshots after "${HELD_NAMES[@]}"
  assert_untouched "${HELD_NAMES[@]}"
  [ -f "$HOMED/data/copy-sweep.log" ] || fail "no removal log was written"
  [ "$(wc -l < "$HOMED/data/copy-sweep.log" | tr -d ' ')" = 1 ] || fail "the log should hold exactly one line: $(cat "$HOMED/data/copy-sweep.log")"
  assert_contains "$(cat "$HOMED/data/copy-sweep.log")" "$(copy_path reap)" "the log line does not name the copy"
  assert_contains "$(cat "$HOMED/data/copy-sweep.log")" "branch=fm/reap" "the log line does not name the branch"
  git -C "$SLOT" rev-parse --verify --quiet refs/heads/fm/reap >/dev/null || fail "the removed copy's branch ref was lost"
  FAKE_LSOF_CWD="$(copy_path proc)/sub" run_sweep --apply
  [ "$RC" = 0 ] || fail "second apply failed ($RC): $OUT"
  assert_no_grep "REMOVED" <(printf '%s\n' "$OUT") "a second apply removed something again"
  [ "$(wc -l < "$HOMED/data/copy-sweep.log" | tr -d ' ')" = 1 ] || fail "a second apply appended to the log"
  take_snapshots after "${HELD_NAMES[@]}"
  assert_untouched "${HELD_NAMES[@]}"
  pass "apply removes only the REAPABLE-PROVEN copy; dirty, unpushed, live, orphan, locked and in-use copies stay byte-identical; a rerun is idempotent"
}

test_copy_with_one_untracked_file_and_unpushed_tip_are_kept() {
  make_world edges
  add_copy one
  printf 'u\n' > "$(copy_path one)/just-one-untracked-file"
  add_copy two
  git -C "$(copy_path two)" commit -q --allow-empty -m unpushed
  take_snapshots before one two
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_class one HELD-DIRTY
  assert_class two HELD-UNPUSHED
  take_snapshots after one two
  assert_untouched one two
  pass "a copy with one untracked file and a copy whose tip is on no remote are both kept"
}

test_landed_content_without_a_pushed_tip_is_reaped_by_apply() {
  make_world landed
  git -C "$SLOT" worktree add -q -b fm/landed "$SLOT/.claude/worktrees/landed"
  printf 'same\n' > "$(copy_path landed)/landed.txt"
  git -C "$(copy_path landed)" add landed.txt
  git -C "$(copy_path landed)" commit -qm "copy side"
  printf 'same\n' > "$SLOT/landed.txt"
  git -C "$SLOT" add landed.txt
  git -C "$SLOT" commit -qm "main side"
  git -C "$SLOT" push -q origin main
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_contains "$OUT" "content already in the default branch" "the landed proof was not named"
  [ ! -e "$(copy_path landed)" ] || fail "a copy whose content is already in the default branch was not removed"
  pass "a copy whose tip is on no remote but whose content already landed is removed by the teardown landed rule"
}

test_lane_home_project_clone_is_swept() {
  local proj copy
  make_world lanehome
  proj="$HOMED/projects/proj"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$W/proj-origin.git"
  git -C "$proj" fetch -q origin
  copy="$proj/.claude/worktrees/stale"
  git -C "$proj" worktree add -q -b fm/stale "$copy"
  git -C "$copy" push -q origin fm/stale
  run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_contains "$OUT" "REAPABLE-PROVEN"$'\t'"0.00 GiB"$'\t'"$copy" "the lane home's nested copy was not found"
  assert_contains "$OUT" "budget container $HOMED:" "the home was not budgeted as a container"
  run_sweep --apply
  [ ! -e "$copy" ] || fail "apply did not remove the lane home's stale copy"
  pass "a project clone under a Firstmate home is enumerated, budgeted as a container, and swept"
}

test_failing_remove_leaves_the_copy_and_is_never_forced() {
  make_world failing
  add_copy reap
  take_snapshots before reap
  FAKE_GIT_FAIL_REMOVE=1 run_sweep --apply
  [ "$RC" = 1 ] || fail "a failed removal should exit 1, got $RC: $OUT"
  assert_contains "$OUT" "FAILED"$'\t'"$(copy_path reap)" "the failure was not reported"
  assert_contains "$OUT" "injected failure" "the git refusal was not reported"
  take_snapshots after reap
  assert_untouched reap
  [ "$(grep -c 'worktree remove' "$W/git.log")" = 1 ] || fail "the removal was retried: $(grep 'worktree remove' "$W/git.log")"
  [ ! -f "$HOMED/data/copy-sweep.log" ] || fail "a failed removal was logged as a removal"
  pass "a failing git worktree remove leaves the copy, is reported, exits 1, and is attempted once"
}

test_nothing_is_forced_deleted_cleaned_or_returned() {
  make_matrix noforce
  FAKE_LSOF_CWD="$(copy_path proc)/sub" run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  grep -q 'worktree remove' "$W/git.log" || fail "no worktree remove was recorded, so this test saw nothing"
  grep -E 'worktree remove' "$W/git.log" | grep -qE ' (--force|-f|-ff)( |$)' && fail "a worktree remove was forced"
  grep -E '(^| )(clean|stash|checkout|reset|rm|gc|prune)( |$)' "$W/git.log" && fail "git was asked to clean, stash, reset or prune"
  grep -qE ' (--force|-f|-ff)( |$)' "$W/git.log" && fail "a forced git command was recorded"
  grep -q 'worktree unlock' "$W/git.log" && fail "a lock was released"
  if [ -f "$W/rm.log" ]; then
    grep -qF "$TH" "$W/rm.log" && fail "rm touched a path under the pool: $(grep -F "$TH" "$W/rm.log")"
    grep -qE '(^| )-[a-zA-Z]*[rR]' "$W/rm.log" && fail "rm was run recursively: $(cat "$W/rm.log")"
  fi
  [ ! -f "$W/treehouse.log" ] || fail "treehouse was called: $(cat "$W/treehouse.log")"
  pass "apply never forces, cleans, unlocks, recursively deletes or calls treehouse"
}

test_load_guard_skips_only_the_sizing_and_says_so() {
  make_world load
  add_copy reap
  add_copy keep
  printf 'x\n' > "$(copy_path keep)/untracked.txt"
  printf 'load-limit 40\ninterval 0\n' > "$HOMED/config/copy-budget"
  FAKE_LOAD=40.01 run_sweep
  [ "$RC" = 0 ] || fail "a report above the load limit should still finish, got $RC: $OUT"
  assert_contains "$OUT" "scan skipped: load 40.01 above limit 40" "the skipped sizing was not said"
  assert_class reap REAPABLE-PROVEN
  assert_class keep HELD-DIRTY
  assert_contains "$OUT" "? GiB" "an unsized copy should read ? GiB"
  [ ! -f "$W/du.log" ] || fail "du ran while the load guard held"
  FAKE_UPTIME_STYLE=linux FAKE_LOAD=40.01 run_sweep
  assert_contains "$OUT" "scan skipped: load 40.01 above limit 40" "a Linux-style load line was not read"
  FAKE_LOAD=40.00 run_sweep
  [ "$RC" = 0 ] || fail "a load equal to the limit should scan, got $RC: $OUT"
  assert_not_contains "$OUT" "scan skipped" "a load equal to the limit was skipped"
  [ "$(du_calls)" = 2 ] || fail "a load equal to the limit should size both copies, got $(du_calls) du calls"
  : > "$W/du.log"
  FAKE_LOAD=95 run_sweep --apply
  [ "$RC" = 0 ] || fail "apply above the load limit should finish, got $RC: $OUT"
  assert_contains "$OUT" "scan skipped: load 95 above limit 40" "apply did not say the sizing was skipped"
  [ ! -s "$W/du.log" ] || fail "apply ran du while the load guard held"
  [ ! -e "$(copy_path reap)" ] || fail "apply should still remove a proven copy while sizing is skipped"
  [ -d "$(copy_path keep)" ] || fail "apply removed a held copy"
  assert_present "$HOMED/state/copy-sweep.record" "apply did not record the skipped scan"
  assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "scan skipped: load 95 above limit 40" "the record does not hold the skip line"
  FAKE_LOAD=95 run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "check must not wake on its first skipped run: $RC $OUT"
  if command -v uptime >/dev/null 2>&1; then
    mkdir -p "$W/fakebin-real-uptime"
    cp "$FAKEBIN/lsof" "$FAKEBIN/nice" "$FAKEBIN/du" "$FAKEBIN/git" "$FAKEBIN/rm" "$W/fakebin-real-uptime/"
    printf 'load-limit 100000\n' > "$HOMED/config/copy-budget"
    FAKEBIN="$W/fakebin-real-uptime" run_sweep
    [ "$RC" = 0 ] || fail "report with the host's own uptime failed ($RC): $OUT"
    assert_not_contains "$OUT" "scan skipped" "the host's own uptime output was not understood"
  fi
  pass "a load above the limit skips only the sizing, says so in the report and the record, and listing, classes and apply still run"
}

test_six_skipped_runs_in_a_row_wake_once() {
  local n
  make_world skipwake
  add_copy a
  printf 'load-limit 40\ninterval 0\n' > "$HOMED/config/copy-budget"
  FAKE_LOAD=99 run_sweep check
  [ -z "$OUT" ] || fail "the first skipped run woke: $OUT"
  assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "scan skipped: load 99 above limit 40" "the record does not hold the skip line"
  for n in 2 3 4 5; do
    FAKE_LOAD=99 run_sweep check
    [ -z "$OUT" ] || fail "skipped run $n of a streak woke: $OUT"
  done
  FAKE_LOAD=99 run_sweep check
  [ "$(printf '%s\n' "$OUT" | grep -c '^copy-sweep:')" = 1 ] || fail "6 skipped runs in a row should raise exactly one wake: $OUT"
  assert_contains "$OUT" "scan skipped: load 99 above limit 40 on 6 runs in a row" "the wake did not name the skip and its length"
  FAKE_LOAD=99 run_sweep check
  [ -z "$OUT" ] || fail "the same streak woke twice: $OUT"
  FAKE_LOAD=1 run_sweep check
  [ -z "$OUT" ] || fail "a run that sized again should not wake: $OUT"
  assert_no_grep "skip" "$HOMED/state/copy-sweep.record" "a sized run left the skip streak in the record"
  for n in 1 2 3 4 5; do
    FAKE_LOAD=99 run_sweep check
    [ -z "$OUT" ] || fail "skipped run $n of a new streak woke: $OUT"
  done
  FAKE_LOAD=99 run_sweep check
  assert_contains "$OUT" "on 6 runs in a row" "a new streak of 6 skipped runs did not wake again"
  pass "6 skipped runs in a row raise one wake, none while the streak stands, and again after a sized run breaks it"
}

test_one_du_at_a_time_under_nice() {
  local max mode
  make_world du
  add_copy a
  add_copy b
  add_copy c
  add_copy d
  # A direct run measures without a deadline; check measures under one. Neither
  # path may run du in parallel or without nice -n 20.
  for mode in direct check; do
    : > "$W/du.log"
    : > "$W/nice.log"
    rm -f "$W/du.log.conc"
    if [ "$mode" = direct ]; then run_sweep; else run_sweep check; fi
    [ "$RC" = 0 ] || fail "$mode run failed ($RC): $OUT"
    [ "$(du_calls)" = 4 ] || fail "$mode run: expected one du per copy, got $(du_calls)"
    max=$(sort -n "$W/du.log.conc" | tail -1)
    [ "$max" = 1 ] || fail "$mode run: du ran concurrently, at most $max at once"
    [ "$(wc -l < "$W/nice.log" | tr -d ' ')" = 4 ] || fail "$mode run: every du should run under nice: $(cat "$W/nice.log")"
    [ "$(sed 's/ -- .*//' "$W/nice.log" | sort -u)" = "-n 20 du -sk" ] || fail "$mode run: du did not run as nice -n 20 du -sk: $(sort -u "$W/nice.log")"
  done
  pass "du runs one at a time as nice -n 20 du -sk, with and without a deadline"
}

test_sizes_are_cached_by_path_and_mtime() {
  make_world cache
  add_copy a
  add_copy b
  printf 'interval 0\n' > "$HOMED/config/copy-budget"
  FM_COPY_SWEEP_NOW=1000 run_sweep check
  [ "$(du_calls)" = 2 ] || fail "first scan should measure both copies, got $(du_calls)"
  FM_COPY_SWEEP_NOW=1100 run_sweep check
  [ "$(du_calls)" = 2 ] || fail "an unchanged copy was measured again, got $(du_calls)"
  touch -t 203001010000 "$(copy_path a)"
  FM_COPY_SWEEP_NOW=1200 run_sweep check
  [ "$(du_calls)" = 3 ] || fail "only the copy with a new mtime should be measured again, got $(du_calls)"
  [ "$(tail -1 "$W/du.log")" = "$(copy_path a)" ] || fail "the wrong copy was measured again: $(tail -1 "$W/du.log")"
  FM_COPY_SWEEP_NOW=200000 run_sweep check
  [ "$(du_calls)" = 5 ] || fail "entries older than cache-max-age should be measured again, got $(du_calls)"
  assert_present "$HOMED/state/copy-sweep.sizes" "no size cache was written"
  pass "sizes are cached by copy path and mtime and expire with cache-max-age"
}

test_nested_copy_bytes_are_not_counted_twice() {
  make_world nest
  add_copy outer
  git -C "$(copy_path outer)" worktree add -q -b fm/inner "$(copy_path outer)/inner"
  printf '%s\t%s\n%s\t%s\n' "$(copy_path outer)" $((3 * GIB)) "$(copy_path outer)/inner" $((1 * GIB)) > "$W/du-table"
  run_sweep
  printf '%s\n' "$OUT" | awk -F '\t' -v p="$(copy_path outer)" '$3 == p { print $2 }' | grep -qx '2.00 GiB' \
    || fail "the enclosing copy should show its own 2.00 GiB: $OUT"
  assert_contains "$OUT" "budget container $SLOT: 3.00 GiB" "the container total double-counted the nested copy: $OUT"
  pass "a copy nested in another copy is subtracted from the enclosing one"
}

# Six dirty copies of the stated sizes, so apply leaves them in place.
make_budget_world() {  # <name> <gib-each...>
  local name=$1 i=0 gib
  shift
  make_world "$name"
  : > "$W/du-table"
  for gib in "$@"; do
    i=$((i + 1))
    add_copy "c$i"
    printf 'dirty\n' > "$(copy_path "c$i")/untracked.txt"
    printf '%s\t%s\n' "$(copy_path "c$i")" $((gib * GIB)) >> "$W/du-table"
  done
}

set_sizes() {  # <gib-each...>
  local i=0 gib
  : > "$W/du-table"
  for gib in "$@"; do
    i=$((i + 1))
    printf '%s\t%s\n' "$(copy_path "c$i")" $((gib * GIB)) >> "$W/du-table"
  done
}

test_budget_wake_names_budget_total_and_five_largest_and_fires_once() {
  local lines
  make_budget_world budget 1 2 3 4 5 6 7
  printf 'default-pool off\ncontainer %s 10\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  FM_CHECK_TIMEOUT=300 run_sweep check
  [ "$RC" = 0 ] || fail "check failed ($RC): $OUT"
  lines=$(printf '%s\n' "$OUT" | grep -c '^copy-sweep:')
  [ "$lines" = 1 ] || fail "expected exactly one wake line, got $lines: $OUT"
  assert_contains "$OUT" "container $SLOT is over its budget: 28.00 GiB against 10 GiB" "the wake did not name the budget and total"
  assert_contains "$OUT" "largest copies: $(copy_path c7) 7.00 GiB HELD-DIRTY, $(copy_path c6) 6.00 GiB HELD-DIRTY, $(copy_path c5) 5.00 GiB HELD-DIRTY, $(copy_path c4) 4.00 GiB HELD-DIRTY, $(copy_path c3) 3.00 GiB HELD-DIRTY" "the wake did not name the five largest copies with their class"
  assert_not_contains "$OUT" "$(copy_path c2) " "the wake named a sixth copy"
  WAKE_TEXT=$OUT
  run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "the same standing condition woke again: $OUT"
  run_sweep check
  [ -z "$OUT" ] || fail "the same standing condition woke a third time: $OUT"
  set_sizes 1 1 1 1 1 1 1
  run_sweep check
  [ -z "$OUT" ] || fail "dropping under the budget should not wake: $OUT"
  assert_no_grep "over" "$HOMED/state/copy-sweep.record" "the record kept a budget that is back under"
  set_sizes 2 2 2 2 2 2 2
  run_sweep check
  assert_contains "$OUT" "container $SLOT is over its budget: 14.00 GiB against 10 GiB" "exceeding again did not wake again: $OUT"
  printf 'budget wake text: %s\n' "$WAKE_TEXT" > "$W/wake-text"
  pass "the budget wake names budget, total and the five largest copies with class, fires once, and fires again after a drop and a new overrun"
}

test_pool_budget_and_two_budgets_share_one_wake() {
  make_budget_world poolbudget 5 5 5
  printf 'pool pool1 8\ncontainer %s 8\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  run_sweep check
  [ "$(printf '%s\n' "$OUT" | grep -c '^copy-sweep:')" = 1 ] || fail "two budgets must share one wake line: $OUT"
  assert_contains "$OUT" "pool $TH/pool1 is over its budget: 15.00 GiB against 8 GiB" "the pool budget was not named"
  assert_contains "$OUT" "container $SLOT is over its budget: 15.00 GiB against 8 GiB" "the container budget was not named"
  run_sweep check
  [ -z "$OUT" ] || fail "two standing budgets woke again: $OUT"
  pass "a pool budget and a container budget that go over together raise one wake"
}

test_apply_raises_the_wake_through_the_queue_once() {
  local rows
  make_budget_world queue 4 4 4
  printf 'default-pool off\ncontainer %s 5\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  rows=$(grep -c . "$HOMED/state/.wake-queue")
  [ "$rows" = 1 ] || fail "expected one queued wake, got $rows"
  awk -F '\t' '$3 == "check" && $5 ~ /copy-sweep: container .* is over its budget: 12.00 GiB against 5 GiB/' "$HOMED/state/.wake-queue" | grep -q . \
    || fail "the queued wake is not the budget wake: $(cat "$HOMED/state/.wake-queue")"
  run_sweep --apply
  [ "$(grep -c . "$HOMED/state/.wake-queue")" = 1 ] || fail "a second apply queued another wake"
  pass "apply raises the budget wake once through the wake queue"
}

test_a_cut_scan_wakes_on_what_it_measured_and_never_invents_one() {
  make_budget_world cut 10 10 10
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  # The first du finishes inside the bound; the second is cut by it; the third never starts.
  # The bound is FM_CHECK_TIMEOUT less five seconds, 4, and a du is given it less
  # the whole seconds elapsed, so a 2.4 second du always fits the 3 or 4 seconds
  # left to the first and never the 2 or fewer left to the second, whatever part
  # of a second the run starts in.
  FAKE_DU_SLEEP=2.4 FM_CHECK_TIMEOUT=9 run_sweep check
  [ "$RC" = 0 ] || fail "check failed ($RC): $OUT"
  assert_contains "$OUT" "is over its budget: 10.00 GiB against 5 GiB" "a lower bound already over the budget should wake"
  assert_contains "$OUT" "2 copies unmeasured" "the wake did not disclose the unmeasured copies"
  assert_no_grep "last_scan" "$HOMED/state/copy-sweep.record" "a cut scan was recorded as complete"
  [ "$(du_calls)" = 1 ] || fail "a du that could not finish inside the bound was counted, or one ran past it: $(du_calls) completed"
  make_budget_world cutquiet 1 1 1
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  FAKE_DU_SLEEP=2.4 FM_CHECK_TIMEOUT=9 run_sweep check
  [ -z "$OUT" ] || fail "a cut scan that proved nothing over still woke: $OUT"
  pass "a scan cut at its time bound wakes only on bytes it measured and records no completed scan"
}

test_a_registered_copy_whose_directory_is_gone_does_not_latch_the_record() {
  make_budget_world gone 4 4 4
  add_copy vanished
  rm -rf "$(copy_path vanished)"
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  run_sweep
  assert_class vanished ORPHAN-NO-RECORD
  assert_contains "$OUT" "ORPHAN-NO-RECORD"$'\t'"0.00 GiB"$'\t'"$(copy_path vanished)" "a copy whose directory is gone should read 0.00 GiB"
  assert_not_contains "$OUT" "unmeasured" "a copy whose directory is gone was reported as unmeasured"
  run_sweep check
  assert_contains "$OUT" "container $SLOT is over its budget: 12.00 GiB against 5 GiB" "the first overrun did not wake"
  assert_not_contains "$OUT" "unmeasured" "the wake called a gone copy unmeasured"
  set_sizes 1 1 1
  run_sweep check
  [ -z "$OUT" ] || fail "dropping under the budget should not wake: $OUT"
  assert_no_grep "over" "$HOMED/state/copy-sweep.record" "a gone copy kept a budget that is back under in the record"
  set_sizes 2 2 2
  run_sweep check
  assert_contains "$OUT" "container $SLOT is over its budget: 6.00 GiB against 5 GiB" "exceeding again with a gone copy registered did not wake again"
  pass "a registered copy whose directory is gone counts as 0 KiB, so it never latches a budget record"
}

test_a_slow_classification_cannot_starve_the_wake() {
  local started elapsed
  make_budget_world slowgit 10 10 10
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  started=$(date +%s)
  FAKE_GIT_SLEEP_STATUS=90 FM_CHECK_TIMEOUT=20 run_sweep check
  elapsed=$(( $(date +%s) - started ))
  [ "$RC" = 0 ] || fail "check failed ($RC): $OUT"
  [ "$elapsed" -lt 20 ] || fail "check outlived its FM_CHECK_TIMEOUT of 20 seconds: $elapsed"
  assert_contains "$OUT" "container $SLOT is over its budget: 30.00 GiB against 5 GiB" "the wake was lost to a slow classification"
  assert_contains "$OUT" "$(copy_path c1) 10.00 GiB UNCLASSIFIED" "a copy whose classification was cut should read UNCLASSIFIED"
  assert_not_contains "$OUT" "HELD-" "a cut classification still named a class"
  make_budget_world slowlsof 10 10 10
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  started=$(date +%s)
  FAKE_LSOF_SLEEP=90 FM_CHECK_TIMEOUT=20 run_sweep check
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 20 ] || fail "check outlived its FM_CHECK_TIMEOUT behind a slow lsof: $elapsed"
  assert_contains "$OUT" "container $SLOT is over its budget: 30.00 GiB against 5 GiB" "the wake was lost to a slow process scan"
  assert_not_contains "$OUT" "HELD-" "a cut process scan still named a class"
  pass "a git or lsof call that cannot finish inside check's time leaves the copy UNCLASSIFIED and the wake is still printed in time"
}

# A registered local secondmate home under the world's root home: its parent
# marker, its registry entry, the root home's own secondmate record for it, and
# one project clone with a local bare origin.
make_lane() {  # <id>
  local id=$1 lane="$W/lane-$1" proj="$W/lane-$1/projects/p"
  mkdir -p "$lane/state" "$lane/data" "$lane/config"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOMED" > "$lane/.fm-secondmate-parent"
  printf -- '- %s - %s (home: %s; scope: fixture; projects: p; added 2026-10-18)\n' "$id" "$id" "$lane" >> "$HOMED/data/secondmates.md"
  fm_write_meta "$HOMED/state/$id.meta" "kind=secondmate" "home=$lane"
  fm_git_init_commit "$proj"
  fm_git_add_origin "$proj" "$W/$id-origin.git"
  git -C "$proj" fetch -q origin
}

# lane_copy <id> <name>: a clean copy of the lane's project, pushed to its origin.
lane_copy() {
  local proj="$W/lane-$1/projects/p" copy="$W/lane-$1/projects/p/.claude/worktrees/$2"
  git -C "$proj" worktree add -q -b "fm/$2" "$copy"
  printf '%s\n' "$2" > "$copy/$2.txt"
  git -C "$copy" add "$2.txt"
  git -C "$copy" commit -qm "$2"
  git -C "$copy" push -q origin "fm/$2"
}

lane_class() {  # <id> <name> -> class in $OUT
  printf '%s\n' "$OUT" | awk -F '\t' -v p="$W/lane-$1/projects/p/.claude/worktrees/$2" '$3 == p { print $1 }'
}

assert_lane_class() {  # <id> <name> <class>
  local got
  got=$(lane_class "$1" "$2")
  [ "$got" = "$3" ] || fail "lane $1 copy $2 should be $3, got '${got:-none}': $OUT"
}

test_a_lane_home_is_judged_as_that_home_would_judge_it() {
  local lane
  make_world lanes
  make_lane open
  lane_copy open clean
  lane_copy open held
  fm_write_meta "$W/lane-open/state/lane-task.meta" "worktree=$W/lane-open/projects/p/.claude/worktrees/held" "kind=ship"
  make_lane badmarker
  lane_copy badmarker only
  printf 'garbage\n' > "$W/lane-badmarker/.fm-secondmate-parent"
  make_lane nostate
  lane_copy nostate only
  rm -rf "$W/lane-nostate/state"
  run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_lane_class open clean REAPABLE-PROVEN
  assert_lane_class open held HELD-LIVE-TASK
  assert_contains "$OUT" "task lane-task's active record names it as its worktree" "the lane's own record was not named"
  assert_lane_class badmarker only HELD-LIVE-TASK
  assert_contains "$OUT" "the active task records of $W/lane-badmarker cannot be read" "an unreadable lane was not named in the report"
  assert_lane_class nostate only HELD-LIVE-TASK
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  [ ! -e "$W/lane-open/projects/p/.claude/worktrees/clean" ] || fail "the lane's proven copy was not removed from the root home"
  for lane in "open/held" "badmarker/only" "nostate/only"; do
    [ -d "$W/lane-${lane%%/*}/projects/p/.claude/worktrees/${lane##*/}" ] || fail "apply removed lane copy $lane, which must be held"
  done
  pass "run from the root home, a lane's proven copy is reaped, its own live record holds a copy, and an unreadable lane holds every copy"
}

# The clone ignores .claude/worktrees/, so git status in an outer copy cannot see
# a copy registered inside it and a plain git worktree remove would delete both.
ignore_worktrees_dir() {
  printf '.claude/worktrees/\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
}

add_inner_copy() {  # <outer-name> <inner-name>: a registered copy inside <outer-name>
  git -C "$(copy_path "$1")" worktree add -q -b "fm/$2" "$(copy_path "$1")/.claude/worktrees/$2"
}

inner_path() { printf '%s/.claude/worktrees/%s\n' "$(copy_path "$1")" "$2"; }

test_an_outer_copy_holding_a_dirty_inner_copy_is_kept() {
  local inner
  make_world innerdirty
  ignore_worktrees_dir
  add_copy outer
  add_inner_copy outer inner
  inner=$(inner_path outer inner)
  printf 'unsaved\n' > "$inner/work.txt"
  [ -z "$(git -C "$(copy_path outer)" status --porcelain --untracked-files=all)" ] \
    || fail "the fixture is wrong: git status in the outer copy should not see the inner copy"
  take_snapshots before outer
  run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_class outer HELD-DIRTY
  assert_contains "$OUT" "another registered copy is inside it: $inner" "the report did not name the inner copy"
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  [ -f "$inner/work.txt" ] || fail "apply deleted the inner copy's unsaved file"
  take_snapshots after outer
  assert_untouched outer
  git -C "$SLOT" worktree list --porcelain | grep -qxF "worktree $inner" || fail "the inner copy is no longer registered"
  assert_absent "$HOMED/data/copy-sweep.log" "apply logged a removal it should not have made"
  pass "an outer copy that holds a dirty inner copy is held and apply keeps both, even when git status cannot see the inner copy"
}

test_an_outer_copy_is_reaped_after_its_inner_copy_is_gone() {
  local inner
  make_world innerclean
  ignore_worktrees_dir
  add_copy outer
  add_inner_copy outer inner
  inner=$(inner_path outer inner)
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$inner" "the proven inner copy was not removed first"
  [ -d "$(copy_path outer)" ] || fail "the outer copy was removed in the same run as the inner copy it held"
  run_sweep --apply
  [ "$RC" = 0 ] || fail "second apply failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path outer)" "the outer copy was not removed once its inner copy was gone"
  [ ! -e "$(copy_path outer)" ] || fail "the outer copy is still on disk"
  make_world innergone
  ignore_worktrees_dir
  add_copy outer
  add_inner_copy outer inner
  rm -rf "$(inner_path outer inner)"
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path outer)" "a registration whose directory is gone held its outer copy"
  pass "an outer copy is held while an inner copy exists, reaped by the next run once it is removed, and not held by a registration whose directory is gone"
}

test_a_zero_padded_or_odd_check_timeout_is_normalized() {
  local value
  make_budget_world padded 4 4 4
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  for value in 090 abc; do
    rm -f "$HOMED/state/copy-sweep.record"
    FM_CHECK_TIMEOUT=$value run_sweep check
    [ "$RC" = 0 ] || fail "check with FM_CHECK_TIMEOUT=$value failed ($RC): $OUT"
    assert_contains "$OUT" "container $SLOT is over its budget: 12.00 GiB against 5 GiB" "check with FM_CHECK_TIMEOUT=$value did not scan"
    assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "last_scan" "check with FM_CHECK_TIMEOUT=$value recorded no scan"
  done
  pass "a zero-padded or non-numeric FM_CHECK_TIMEOUT no longer aborts the check"
}

# Ignored entries the teardown library does not call regenerable machinery must
# hold a copy; a listing that fails must hold it too, never read as "none".
test_ignored_files_that_exist_nowhere_else_hold_a_copy() {
  make_world ignored
  printf '.env\nlocal-data/\nnode_modules/\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  add_copy keepenv
  printf 'SECRET=1\n' > "$(copy_path keepenv)/.env"
  add_copy keepdir
  mkdir -p "$(copy_path keepdir)/local-data"
  printf 'rows\n' > "$(copy_path keepdir)/local-data/rows.csv"
  add_copy reapnm
  mkdir -p "$(copy_path reapnm)/node_modules/pkg"
  printf 'x\n' > "$(copy_path reapnm)/node_modules/pkg/index.js"
  run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_class keepenv HELD-DIRTY
  assert_class keepdir HELD-DIRTY
  assert_class reapnm REAPABLE-PROVEN
  assert_contains "$OUT" "it holds ignored files that exist nowhere else: .env" "the report did not name the ignored file"
  assert_not_contains "$OUT" "command not found" "a helper the sweep calls is undefined"
  take_snapshots before keepenv keepdir
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_not_contains "$OUT" "command not found" "a helper the sweep calls is undefined"
  [ -f "$(copy_path keepenv)/.env" ] || fail "apply deleted an ignored file that exists nowhere else"
  [ -f "$(copy_path keepdir)/local-data/rows.csv" ] || fail "apply deleted an ignored directory that exists nowhere else"
  take_snapshots after keepenv keepdir
  assert_untouched keepenv keepdir
  [ ! -e "$(copy_path reapnm)" ] || fail "a copy holding only regenerable ignored machinery was not reaped"
  add_copy again
  FAKE_GIT_FAIL_LSFILES=1 run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_class again ORPHAN-NO-RECORD
  assert_contains "$OUT" "its ignored files cannot be listed" "the report did not say the listing failed"
  [ -d "$(copy_path again)" ] || fail "a copy whose ignored files could not be listed was removed"
  pass "a copy holding an ignored file that exists nowhere else is kept, regenerable machinery is reaped, and a failed listing holds the copy"
}

add_big_dirty_copy() {  # <name>: a dirty 10 GiB copy in the current $SLOT
  add_copy "$1"
  printf 'dirty\n' > "$(copy_path "$1")/untracked.txt"
  printf '%s\t%s\n' "$(copy_path "$1")" $((10 * GIB)) >> "$W/du-table"
}

add_pool_slot() {  # <n>: pool<n> with one slot whose clone holds a dirty 10 GiB copy c<n>
  local saved=$SLOT
  SLOT="$TH/pool$1/1/repo"
  mkdir -p "$TH/pool$1/1"
  fm_git_init_commit "$SLOT"
  fm_git_add_origin "$SLOT" "$W/origin$1.git"
  git -C "$SLOT" fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool$1/treehouse-state.json"
  add_big_dirty_copy "c$1"
  SLOT=$saved
}

slot_of() { printf '%s/pool%s/1/repo\n' "$TH" "$1"; }

test_a_slow_enumeration_still_prints_the_wake_for_the_clones_it_reached() {
  local n examined
  make_world slowenum
  printf 'default-pool off\ndefault-container 5\ninterval 0\ncache-max-age 0\n' > "$HOMED/config/copy-budget"
  add_big_dirty_copy c1
  for n in 2 3 4 5 6 7 8; do add_pool_slot "$n"; done
  FAKE_GIT_SLEEP_ENUM=2 FM_CHECK_TIMEOUT=16 run_sweep check
  [ "$RC" = 0 ] || fail "check failed ($RC): $OUT"
  assert_contains "$OUT" "container $(slot_of 1) is over its budget: 10.00 GiB against 5 GiB" "the wake did not name the first clone it reached"
  assert_not_contains "$OUT" "container $(slot_of 8) is over" "the wake named a clone the cut run never reached"
  assert_no_grep "last_scan" "$HOMED/state/copy-sweep.record" "a run cut during enumeration was recorded as complete"
  examined=$(grep -c 'rev-parse --git-dir' "$W/git.log")
  [ "$examined" -ge 1 ] && [ "$examined" -lt 8 ] || fail "a check cut during enumeration should examine some but not all 8 clones, examined $examined"
  pass "a check whose enumeration is slow stops looking for clones at its time bound and still prints the wake for the clones it reached"
}

test_a_slow_home_project_enumeration_is_cut_at_the_time_bound() {
  local n examined
  make_world slowhome
  for n in 1 2 3 4 5 6; do fm_git_init_commit "$HOMED/projects/p$n"; done
  FAKE_GIT_SLEEP_HOME=2 FM_CHECK_TIMEOUT=11 run_sweep check
  [ "$RC" = 0 ] || fail "check failed ($RC): $OUT"
  examined=$(grep -c 'rev-parse --show-toplevel' "$W/git.log")
  [ "$examined" -ge 1 ] && [ "$examined" -lt 6 ] || fail "a check cut during the home project scan should examine some but not all 6 clones, examined $examined"
  assert_no_grep "last_scan" "$HOMED/state/copy-sweep.record" "a run cut during enumeration was recorded as complete"
  pass "a check stops looking at a home's project clones at its time bound"
}

test_a_cut_check_keeps_the_standing_budgets_it_did_not_reach() {
  local n rows record
  make_world cutrecord
  printf 'default-pool off\ndefault-container 5\ninterval 0\ncache-max-age 0\nload-limit 40\n' > "$HOMED/config/copy-budget"
  add_big_dirty_copy c1
  for n in 2 3 4 5 6; do add_pool_slot "$n"; done
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  [ "$(grep -c . "$HOMED/state/.wake-queue")" = 1 ] || fail "apply should queue one wake for the six budgets"
  FAKE_GIT_SLEEP_ENUM=2 FM_CHECK_TIMEOUT=11 run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "a cut check woke for a standing condition: $RC $OUT"
  record=$(cat "$HOMED/state/copy-sweep.record")
  assert_contains "$record" "over"$'\t'"container:$(slot_of 6)" "a cut check forgot a standing budget it did not reach"
  run_sweep --apply
  [ "$(grep -c . "$HOMED/state/.wake-queue")" = 1 ] || fail "a cut check made the next apply wake again for a standing budget"
  FAKE_LOAD=99 FAKE_GIT_SLEEP_ENUM=2 FM_CHECK_TIMEOUT=11 run_sweep check
  FAKE_LOAD=99 FAKE_GIT_SLEEP_ENUM=2 FM_CHECK_TIMEOUT=11 run_sweep check
  rows=$(grep -c "^skip"$'\t' "$HOMED/state/copy-sweep.record")
  [ "$rows" = 1 ] || fail "the record should hold one skip line: $(cat "$HOMED/state/copy-sweep.record")"
  [ "$(skip_count)" = 2 ] || fail "with an interval of 0 every cut skipped run is an interval apart and counts: $(cat "$HOMED/state/copy-sweep.record")"
  assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "scan skipped: load 99 above limit 40" "the record does not hold the skip line"
  FAKE_LOAD=99 FM_CHECK_TIMEOUT=90 run_sweep check
  [ "$(skip_count)" = 3 ] || fail "a complete skipped run did not count: $(cat "$HOMED/state/copy-sweep.record")"
  pass "a cut check keeps the standing budgets it did not reach and counts toward the streak of skipped runs"
}

skip_count() { awk -F '\t' '$1 == "skip" { print $2 }' "$HOMED/state/copy-sweep.record"; }

# Every poll is cut during enumeration (the second clone is never reached) and
# skipped for load, and the clock is driven by FM_COPY_SWEEP_NOW.
cut_skipped_poll() {  # <now>
  FAKE_LOAD=99 FAKE_GIT_SLEEP_ENUM=4 FM_CHECK_TIMEOUT=8 FM_COPY_SWEEP_NOW=$1 run_sweep check
  [ "$RC" = 0 ] || fail "check at $1 failed ($RC): $OUT"
}

test_a_check_cut_and_skipped_on_every_poll_still_reaches_the_wake() {
  local t0=100000 step
  make_world cutskip
  add_pool_slot 2
  printf 'load-limit 40\ninterval 3600\n' > "$HOMED/config/copy-budget"
  cut_skipped_poll "$t0"
  [ -z "$OUT" ] || fail "the first cut skipped poll woke: $OUT"
  [ "$(skip_count)" = 1 ] || fail "the first cut skipped poll should count once: $(cat "$HOMED/state/copy-sweep.record")"
  assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "skip"$'\t'"1"$'\t'"$t0"$'\t'"scan skipped: load 99 above limit 40" "the record does not keep the time the count last advanced"
  cut_skipped_poll $((t0 + 10))
  [ -z "$OUT" ] || fail "a poll inside one interval woke: $OUT"
  [ "$(skip_count)" = 1 ] || fail "a cut skipped poll inside one interval must not add to the count: $(cat "$HOMED/state/copy-sweep.record")"
  cut_skipped_poll $((t0 + 3599))
  [ "$(skip_count)" = 1 ] || fail "a cut skipped poll one second short of an interval must not add to the count: $(cat "$HOMED/state/copy-sweep.record")"
  for step in 2 3 4 5; do
    cut_skipped_poll $((t0 + (step - 1) * 3600))
    [ -z "$OUT" ] || fail "counted run $step woke early: $OUT"
    [ "$(skip_count)" = "$step" ] || fail "counted run $step should make the count $step: $(cat "$HOMED/state/copy-sweep.record")"
  done
  cut_skipped_poll $((t0 + 5 * 3600))
  [ "$(printf '%s\n' "$OUT" | grep -c '^copy-sweep:')" = 1 ] || fail "the 6th counted run should raise exactly one wake: $OUT"
  assert_contains "$OUT" "scan skipped: load 99 above limit 40 on 6 runs in a row" "the wake did not name the skip and its length"
  cut_skipped_poll $((t0 + 6 * 3600))
  [ -z "$OUT" ] || fail "the same streak woke twice: $OUT"
  assert_no_grep "last_scan" "$HOMED/state/copy-sweep.record" "a poll that was cut was recorded as a complete scan"
  pass "a check that is cut and skipped on every poll counts once per interval and raises exactly one wake on the 6th counted run"
}

# Two slots of one pool: the second slot is never reached, so the pool's partial
# total is under its budget although the pool stays over. The first run warms the
# size cache, so the cut run still knows the first slot's size after the time
# bound has passed and no copy is left unmeasured.
test_a_cut_check_keeps_a_pool_budget_it_reached_only_in_part() {
  local slot2
  make_world poolcut
  printf 'pool pool1 15\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  add_big_dirty_copy c1
  slot2="$TH/pool1/2/repo"
  mkdir -p "$TH/pool1/2"
  fm_git_init_commit "$slot2"
  fm_git_add_origin "$slot2" "$W/origin-slot2.git"
  git -C "$slot2" fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}\n' "$SLOT" "$slot2" > "$TH/pool1/treehouse-state.json"
  git -C "$slot2" worktree add -q -b fm/c2 "$slot2/.claude/worktrees/c2"
  printf 'dirty\n' > "$slot2/.claude/worktrees/c2/untracked.txt"
  printf '%s\t%s\n' "$slot2/.claude/worktrees/c2" $((10 * GIB)) >> "$W/du-table"
  FM_COPY_SWEEP_NOW=1000 FM_CHECK_TIMEOUT=300 run_sweep check
  assert_contains "$OUT" "pool $TH/pool1 is over its budget: 20.00 GiB against 15 GiB" "the complete run did not wake for the pool"
  FM_COPY_SWEEP_NOW=1100 FAKE_GIT_SLEEP_ENUM=5 FM_CHECK_TIMEOUT=9 run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "a cut check woke for a standing pool budget: $RC $OUT"
  assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "over"$'\t'"pool:$TH/pool1" "a cut check forgot a pool budget it reached only in part"
  FM_COPY_SWEEP_NOW=1200 FM_CHECK_TIMEOUT=300 run_sweep check
  [ -z "$OUT" ] || fail "the next complete run woke again for a pool that never stopped being over: $OUT"
  printf '%s\t%s\n%s\t%s\n' "$(copy_path c1)" "$GIB" "$slot2/.claude/worktrees/c2" "$GIB" > "$W/du-table"
  FM_COPY_SWEEP_NOW=100000 FM_CHECK_TIMEOUT=300 run_sweep check
  [ -z "$OUT" ] || fail "dropping under the budget should not wake: $OUT"
  assert_no_grep "pool:" "$HOMED/state/copy-sweep.record" "a complete run did not clear a pool that is back under"
  printf '%s\t%s\n%s\t%s\n' "$(copy_path c1)" $((10 * GIB)) "$slot2/.claude/worktrees/c2" $((10 * GIB)) > "$W/du-table"
  FM_COPY_SWEEP_NOW=200000 FM_CHECK_TIMEOUT=300 run_sweep check
  assert_contains "$OUT" "pool $TH/pool1 is over its budget: 20.00 GiB against 15 GiB" "going over again after a complete run did not wake"
  pass "a cut check keeps a pool budget it reached only in part, and only a complete run clears it"
}

cache_has() { grep -qF "$1"$'\t' "$HOMED/state/copy-sweep.sizes"; }

test_a_cut_check_keeps_the_fresh_cached_sizes_it_did_not_reach() {
  local n
  make_world cachekeep
  printf 'default-pool off\ndefault-container 5\ninterval 0\n' > "$HOMED/config/copy-budget"
  add_big_dirty_copy c1
  for n in 2 3 4 5; do add_pool_slot "$n"; done
  FM_COPY_SWEEP_NOW=1000 FM_CHECK_TIMEOUT=300 run_sweep check
  for n in 1 2 3 4 5; do cache_has "$(slot_of "$n")/.claude/worktrees/c$n" || fail "the complete run did not cache c$n"; done
  FM_COPY_SWEEP_NOW=2000 FAKE_GIT_SLEEP_ENUM=2 FM_CHECK_TIMEOUT=9 run_sweep check
  for n in 1 2 3 4 5; do cache_has "$(slot_of "$n")/.claude/worktrees/c$n" || fail "a cut run threw away the fresh cached size of c$n"; done
  rm -rf "$(slot_of 5)/.claude/worktrees/c5"
  git -C "$(slot_of 5)" worktree prune
  FM_COPY_SWEEP_NOW=3000 FM_CHECK_TIMEOUT=300 run_sweep check
  ! cache_has "$(slot_of 5)/.claude/worktrees/c5" || fail "a complete run kept the cached size of a copy it did not find"
  for n in 1 2 3 4; do cache_has "$(slot_of "$n")/.claude/worktrees/c$n" || fail "the complete run lost the cached size of c$n"; done
  FM_COPY_SWEEP_NOW=100000 FAKE_GIT_SLEEP_ENUM=2 FM_CHECK_TIMEOUT=9 run_sweep check
  ! cache_has "$(slot_of 4)/.claude/worktrees/c4" || fail "a cut run kept a cached size older than cache-max-age"
  pass "a cut check keeps the cached sizes of the copies it did not reach while they are fresh, and a complete run rewrites the cache"
}

test_check_classifies_only_the_copies_it_names() {
  make_budget_world lazy 9 8 1 1 1 1 1
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  FM_CHECK_TIMEOUT=300 run_sweep check
  assert_contains "$OUT" "$(copy_path c1) 9.00 GiB HELD-DIRTY" "the named copy was not classified"
  assert_no_grep "UNCLASSIFIED" <(printf '%s\n' "$OUT") "a named copy was left unclassified with time to spare"
  [ "$(grep -c 'status' "$W/git.log")" = 5 ] || fail "check should classify exactly the five copies it names, ran git status $(grep -c 'status' "$W/git.log") times"
  pass "check classifies exactly the copies its wake names"
}

test_check_respects_its_interval() {
  make_world interval
  add_copy a
  printf 'interval 3600\n' > "$HOMED/config/copy-budget"
  FM_COPY_SWEEP_NOW=1000 run_sweep check
  [ "$(du_calls)" = 1 ] || fail "the first check should scan, du ran $(du_calls) times"
  FM_COPY_SWEEP_NOW=1100 run_sweep check
  [ "$(du_calls)" = 1 ] || fail "a poll inside the interval scanned again"
  grep -q 'worktree list' "$W/git.log" || fail "the first check never enumerated"
  : > "$W/git.log"
  FM_COPY_SWEEP_NOW=1200 run_sweep check
  [ ! -s "$W/git.log" ] || fail "a poll inside the interval ran git: $(cat "$W/git.log")"
  FM_COPY_SWEEP_NOW=5000 run_sweep check
  [ -s "$W/git.log" ] || fail "a due check did not scan"
  pass "check scans at most once per interval and polls inside it do nothing"
}

test_check_never_removes() {
  make_world checkonly
  add_copy reap
  run_sweep check
  [ -d "$(copy_path reap)" ] || fail "check removed a copy"
  pass "check is report-only"
}

test_bad_config_is_refused() {
  make_world badconfig
  add_copy a
  printf 'container relative/path 5\n' > "$HOMED/config/copy-budget"
  run_sweep --apply
  [ "$RC" = 2 ] || fail "a bad config should exit 2, got $RC: $OUT"
  assert_contains "$OUT" "config/copy-budget line 1: container wants an absolute path" "the bad line was not named"
  [ -d "$(copy_path a)" ] || fail "a bad config still changed a copy"
  printf 'pool pool1 lots\n' > "$HOMED/config/copy-budget"
  run_sweep
  [ "$RC" = 2 ] || fail "a non-numeric budget should exit 2, got $RC"
  printf 'default-pool 1\nbogus 3\n' > "$HOMED/config/copy-budget"
  run_sweep check
  assert_contains "$OUT" "unknown key 'bogus'" "check did not report a bad config"
  run_sweep check
  [ -z "$OUT" ] || fail "check repeated the same config error: $OUT"
  pass "a malformed config/copy-budget is refused with its line named and reported once by check"
}

test_real_lsof_sees_a_process_inside_a_copy() {
  local pid
  command -v lsof >/dev/null 2>&1 || { pass "real lsof absent on this host; skipped"; return 0; }
  make_world reallsof
  add_copy busy
  (cd "$(copy_path busy)" && exec sleep 60) &
  pid=$!
  sleep 1
  # The same fakes without the lsof stand-in, so the host's own lsof answers.
  mkdir -p "$W/fakebin-real-lsof"
  cp "$FAKEBIN/uptime" "$FAKEBIN/nice" "$FAKEBIN/du" "$FAKEBIN/git" "$FAKEBIN/rm" "$W/fakebin-real-lsof/"
  FAKEBIN="$W/fakebin-real-lsof" run_sweep
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_class busy HELD-LIVE-TASK
  assert_contains "$OUT" "process $pid is running inside it" "the real lsof did not find the process"
  pass "the host's own lsof finds a process whose working directory is inside a copy"
}

test_arm_and_disarm_bind_the_check() {
  local out
  make_world arm
  add_copy a
  out=$(env FM_HOME="$HOMED" "$SWEEP" arm 2>&1) || fail "arm failed: $out"
  assert_contains "$out" "armed: state/copy-sweep.check.sh" "arm did not report"
  assert_present "$HOMED/state/copy-sweep.check.sh" "arm did not write the shim"
  assert_present "$HOMED/state/copy-sweep.check-trust" "arm did not write the trust binding"
  [ -x "$HOMED/state/copy-sweep.check.sh" ] || fail "the shim is not executable"
  assert_contains "$(cat "$HOMED/state/copy-sweep.check.sh")" "fm-proc-budget.sh" "the shim does not run under the process budget"
  assert_contains "$(cat "$HOMED/state/copy-sweep.check.sh")" "fm-copy-sweep.sh" "the shim does not run the sweep"
  out=$(env -u FM_HOME PATH="$FAKEBIN:$ORIGINAL_PATH" FAKE_REAL_GIT="$REAL_GIT" FAKE_REAL_RM="$REAL_RM" FAKE_DU_TABLE="$W/du-table" \
    FAKE_DU_LOG="$W/du.log" FAKE_DU_ACTIVE="$W/du-active" FAKE_NICE_LOG="$W/nice.log" \
    FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" "$HOMED/state/copy-sweep.check.sh" 2>&1) || fail "the registered shim failed: $out"
  assert_present "$HOMED/state/copy-sweep.record" "the shim did not run the check in its pinned home"
  out=$(env FM_HOME="$HOMED" "$SWEEP" disarm 2>&1) || fail "disarm failed: $out"
  assert_absent "$HOMED/state/copy-sweep.check.sh" "disarm left the shim"
  assert_absent "$HOMED/state/copy-sweep.check-trust" "disarm left the trust binding"
  assert_absent "$HOMED/state/copy-sweep.record" "disarm left the record"
  pass "arm binds the check to the existing watcher cadence and disarm removes it"
}

test_help_and_bad_calls() {
  local out
  out=$("$SWEEP" --help 2>&1) || fail "--help failed"
  assert_contains "$out" "bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh --apply" "--help does not carry the hourly command"
  "$SWEEP" --bogus >/dev/null 2>&1 && fail "an unknown option was accepted"
  "$SWEEP" --apply extra >/dev/null 2>&1 && fail "an extra argument was accepted"
  pass "help carries the hourly command and bad calls are refused"
}

# FM_COPY_SWEEP_CASE=<function> runs one case, which keeps a mutation proof quick.
run_case() {
  [ -z "${FM_COPY_SWEEP_CASE:-}" ] || [ "$FM_COPY_SWEEP_CASE" = "$1" ] || return 0
  "$1"
}

run_case test_report_lists_every_copy_and_changes_nothing
run_case test_apply_removes_only_the_reapable_copy
run_case test_copy_with_one_untracked_file_and_unpushed_tip_are_kept
run_case test_landed_content_without_a_pushed_tip_is_reaped_by_apply
run_case test_lane_home_project_clone_is_swept
run_case test_failing_remove_leaves_the_copy_and_is_never_forced
run_case test_nothing_is_forced_deleted_cleaned_or_returned
run_case test_load_guard_skips_only_the_sizing_and_says_so
run_case test_six_skipped_runs_in_a_row_wake_once
run_case test_one_du_at_a_time_under_nice
run_case test_sizes_are_cached_by_path_and_mtime
run_case test_nested_copy_bytes_are_not_counted_twice
run_case test_budget_wake_names_budget_total_and_five_largest_and_fires_once
run_case test_pool_budget_and_two_budgets_share_one_wake
run_case test_apply_raises_the_wake_through_the_queue_once
run_case test_a_cut_scan_wakes_on_what_it_measured_and_never_invents_one
run_case test_a_registered_copy_whose_directory_is_gone_does_not_latch_the_record
run_case test_a_slow_classification_cannot_starve_the_wake
run_case test_a_lane_home_is_judged_as_that_home_would_judge_it
run_case test_an_outer_copy_holding_a_dirty_inner_copy_is_kept
run_case test_an_outer_copy_is_reaped_after_its_inner_copy_is_gone
run_case test_a_zero_padded_or_odd_check_timeout_is_normalized
run_case test_ignored_files_that_exist_nowhere_else_hold_a_copy
run_case test_a_slow_enumeration_still_prints_the_wake_for_the_clones_it_reached
run_case test_a_slow_home_project_enumeration_is_cut_at_the_time_bound
run_case test_a_cut_check_keeps_the_standing_budgets_it_did_not_reach
run_case test_a_check_cut_and_skipped_on_every_poll_still_reaches_the_wake
run_case test_a_cut_check_keeps_a_pool_budget_it_reached_only_in_part
run_case test_a_cut_check_keeps_the_fresh_cached_sizes_it_did_not_reach
run_case test_check_classifies_only_the_copies_it_names
run_case test_check_respects_its_interval
run_case test_check_never_removes
run_case test_bad_config_is_refused
run_case test_real_lsof_sees_a_process_inside_a_copy
run_case test_arm_and_disarm_bind_the_check
run_case test_help_and_bad_calls
pass "fm-copy-sweep"
