#!/usr/bin/env bash
# Behavioral coverage for bin/fm-copy-sweep.sh: the proof matrix, the report-only
# default, the one-wake byte budget, the load guard and du limits, the lane-home
# view, the release of a creation-locked copy whose launcher is gone through
# Vernant's own closeout driver, and the refusal to force anything.
# Every world is a throwaway directory under a temp root with
# real `git worktree add` copies; no real pool, home, state file or backlog is
# read or written. FM_COPY_SWEEP_BIN points the suite at a mutant of the script
# to prove each assertion can fail.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-supersedence-route-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supersedence-route-helpers.sh"

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
# FAKE_DU_HANG_AFTER=<n>: finish the first n calls at once, then hang past the bound.
if [ -n "${FAKE_DU_HANG_AFTER:-}" ]; then
  finished=0
  [ ! -f "$FAKE_DU_LOG" ] || finished=$(wc -l < "$FAKE_DU_LOG" | tr -d ' ')
  [ "$finished" -lt "$FAKE_DU_HANG_AFTER" ] || sleep 30
else
  sleep 0.05
fi
rm -f "$FAKE_DU_ACTIVE/$$"
printf '%s\n' "$path" >> "$FAKE_DU_LOG"
kib=$(awk -F '\t' -v p="$path" '$1 == p { print $2 }' "$FAKE_DU_TABLE")
case "$path" in */nested-copy-preserved|*/nested-copy-preserved/*) kib=${kib:-${FAKE_DU_PRESERVED_KIB:-}} ;; esac
printf '%s\t%s\n' "${kib:-100}" "$path"
EOF
  cat > "$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${FAKE_DRIVER:-0}" = 1 ]; then
  printf '%s\n' "$*" >> "$FAKE_GIT_LOG.driver"
else
  printf '%s\n' "$*" >> "$FAKE_GIT_LOG"
fi
case " $* " in
  *" worktree list "*)
    [ -z "${FAKE_GIT_FAIL_LIST:-}" ] || exit 128
    if [ -n "${FAKE_GIT_FAIL_LIST_AFTER:-}" ]; then
      count=$(cat "$FAKE_GIT_LOG.list-count" 2>/dev/null || printf 0)
      count=$((count + 1))
      printf '%s\n' "$count" > "$FAKE_GIT_LOG.list-count"
      [ "$count" -le "$FAKE_GIT_FAIL_LIST_AFTER" ] || exit 128
    fi
    if [ -n "${FAKE_GIT_FAIL_LIST_FILE:-}" ] && [ -f "$FAKE_GIT_FAIL_LIST_FILE" ]; then
      exit 128
    fi
    if [ -n "${FAKE_GIT_PARTIAL_LIST_FILE:-}" ] && [ -f "$FAKE_GIT_PARTIAL_LIST_FILE" ]; then
      copy=$(cat "$FAKE_GIT_PARTIAL_LIST_FILE")
      rm -f "$FAKE_GIT_PARTIAL_LIST_FILE"
      printf '%s\n' "$copy" >> "$FAKE_GIT_PARTIAL_LIST_FILE.log"
      printf 'worktree %s\0' "$copy"
      exit 128
    fi
    ;;
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
  *" rev-parse HEAD "*)
    [ -z "${FAKE_GIT_HEAD_HOOK:-}" ] || bash "$FAKE_GIT_HEAD_HOOK" "$@"
    ;;
  *" remote get-url origin "*)
    [ -z "${FAKE_GIT_ORIGIN_URL_HOOK:-}" ] || bash "$FAKE_GIT_ORIGIN_URL_HOOK" "$@"
    ;;
  *" rev-parse --absolute-git-dir "*)
    [ -z "${FAKE_GIT_SLEEP_ABSDIR:-}" ] || sleep "$FAKE_GIT_SLEEP_ABSDIR"
    ;;
  *" merge-base --all "*)
    [ -z "${FAKE_GIT_MERGEBASE_HOOK:-}" ] || bash "$FAKE_GIT_MERGEBASE_HOOK" "$@"
    if [ -n "${FAKE_GIT_FAIL_MERGEBASE:-}" ]; then
      echo "fatal: injected merge-base failure" >&2
      exit 128
    fi
    ;;
  *" diff-tree "*)
    if [ -n "${FAKE_GIT_DIFFTREE_FILE:-}" ]; then cat "$FAKE_GIT_DIFFTREE_FILE"; exit 0; fi
    ;;
  *" ls-tree "*)
    if [ -n "${FAKE_GIT_LSTREE_FILE:-}" ]; then cat "$FAKE_GIT_LSTREE_FILE"; exit 0; fi
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

# Replaces the calling subshell with the sweep in the current world, so $! of a
# backgrounded `( sweep_cmd ... ) &` is the sweep's own pid.
sweep_cmd() {
  exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$FAKEBIN:$ORIGINAL_PATH" FAKE_REAL_GIT="$REAL_GIT" FAKE_REAL_RM="$REAL_RM" \
    FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" \
    FAKE_DU_TABLE="$W/du-table" FAKE_DU_LOG="$W/du.log" FAKE_DU_ACTIVE="$W/du-active" \
    FAKE_NICE_LOG="$W/nice.log" FAKE_GIT_LOG="$W/git.log" FAKE_RM_LOG="$W/rm.log" \
    FAKE_TREEHOUSE_LOG="$W/treehouse.log" \
    "$SWEEP" "$@"
}

# Runs the sweep in the current world; sets OUT and RC.
run_sweep() {
  RC=0
  OUT=$( ( sweep_cmd "$@" ) 2>&1) || RC=$?
  sweep_observe "$@"
}

# With FM_RETAINED_EVIDENCE=<file>, one line per sweep run, written by the run itself:
# the form (report or --apply), exit status, the class the sweep gave the nested copy
# named "locked", whether that copy is still on disk and registered, the closeout
# driver's call count, this home's retention receipts (count and a hash of their
# bytes), other homes' receipts (count and hash), and whether the run listed a
# RECEIPT-CLEARED line. Nothing here changes what a test asserts.
sweep_observe() {
  [ -n "${FM_RETAINED_EVIDENCE:-}" ] || return 0
  local fn test_name=unknown form=report arg calls=0 mine others copy class present registered cleared=no
  for fn in "${FUNCNAME[@]}"; do
    case "$fn" in test_*) test_name=$fn; break ;; esac
  done
  for arg in "$@"; do [ "$arg" != --apply ] || form=apply; done
  copy=$SLOT/.claude/worktrees/locked
  class=$(printf '%s\n' "$OUT" | awk -F '\t' -v p="$copy" '$3 == p { print $1 }' | head -n 1)
  present=gone; [ ! -e "$copy" ] || present=present
  registered=no; git -C "$SLOT" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $copy" && registered=yes
  [ ! -e "$W/closeout.log" ] || calls=$(wc -l < "$W/closeout.log" | tr -d ' ')
  mine="$(find "$HOMED/data/copy-sweep/retained" -type f 2>/dev/null | wc -l | tr -d ' ') sha256=$(find "$HOMED/data/copy-sweep/retained" -type f -exec shasum -a 256 {} + 2>/dev/null | awk '{print $1}' | LC_ALL=C sort | shasum -a 256 | cut -c1-16)"
  others="$(find "$W"/lane-*/data/copy-sweep/retained -type f 2>/dev/null | wc -l | tr -d ' ') sha256=$(find "$W"/lane-*/data/copy-sweep/retained -type f -exec shasum -a 256 {} + 2>/dev/null | awk '{print $1}' | LC_ALL=C sort | shasum -a 256 | cut -c1-16)"
  case "$OUT" in *RECEIPT-CLEARED*) cleared=yes ;; esac
  printf '%s | case=%s | form=%s | exit=%s | class=%s | copy=%s registered=%s | driver-calls=%s | own-receipts=%s | other-home-receipts=%s | receipt-cleared=%s\n' \
    "$test_name" "${W##*/}" "$form" "$RC" "${class:-none}" "$present" "$registered" "$calls" "$mine" "$others" "$cleared" >> "$FM_RETAINED_EVIDENCE"
  return 0
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
    local admin
    admin=$(git -C "$(copy_path "$name")" rev-parse --absolute-git-dir 2>/dev/null) || admin=
    if [ -n "$admin" ] && [ -f "$admin/locked" ]; then
      shasum -a 256 "$admin/locked" >> "$W/snap-$name-$suffix"
    fi
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

test_live_nested_copies_are_named_once_with_age_and_left_untouched() {
  local lock before_lock before_list report_line first
  make_world live-nested
  add_copy locked-live
  add_copy unlocked-live
  fm_write_meta "$HOMED/state/outer-task.meta" "worktree=$SLOT" "kind=ship"
  git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999' "$(copy_path locked-live)"
  lock="$(git -C "$(copy_path locked-live)" rev-parse --absolute-git-dir)/locked"
  TZ=UTC touch -t 202912312300 "$lock"
  TZ=UTC touch -t 202912310000 "$(copy_path unlocked-live)"
  before_lock=$(shasum -a 256 "$lock")
  take_snapshots before locked-live unlocked-live
  printf 'default-pool off\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  FM_COPY_SWEEP_NOW=1893456000 run_sweep
  [ "$RC" = 0 ] || fail "live nested report failed: $OUT"
  report_line=$(printf '%s\n' "$OUT" | grep '^copy-sweep: HELD-LIVE-TASK nested copies=')
  [ "$(printf '%s\n' "$report_line" | wc -l | tr -d ' ')" = 1 ] || fail "live facts were not aggregated: $OUT"
  assert_contains "$report_line" 'nested copies=2:' 'report did not count both live copies'
  assert_contains "$report_line" "$(copy_path locked-live) (task=outer-task age=3600s source=lock)" 'lock age or absolute path missing'
  assert_contains "$report_line" "$(copy_path unlocked-live) (task=outer-task age=86400s source=directory)" 'directory age or absolute path missing'
  assert_absent "$HOMED/state/.wake-queue" 'report raised a wake'
  first=$OUT
  FM_COPY_SWEEP_NOW=1893456000 run_sweep
  assert_equals "$first" "$OUT" 'a second report with the clock pinned differs from the first'
  FM_COPY_SWEEP_NOW=1893456000 run_sweep check
  [ "$RC" = 0 ] || fail "live nested check failed: $OUT"
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "check emitted more than one notification: $OUT"
  assert_contains "$OUT" 'nested copies=2, 2 shown' 'check must count both live copies even with budgets off'
  assert_contains "$OUT" "$(copy_path locked-live) (task=outer-task age=3600s source=lock)" 'check did not name the locked live copy'
  assert_contains "$OUT" "$(copy_path unlocked-live) (task=outer-task age=86400s source=directory)" 'check did not name the unlocked live copy'
  assert_contains "$(cat "$HOMED/state/copy-sweep.record")" "$(copy_path locked-live)" 'record did not keep the notified live copy'
  FM_COPY_SWEEP_NOW=1893456001 run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "the same live set woke again: $OUT"
  add_copy added-live
  before_list=$(git -C "$SLOT" worktree list --porcelain)
  printf 'default-pool 0\ndefault-container 0\ninterval 0\n' > "$HOMED/config/copy-budget"
  FM_COPY_SWEEP_NOW=1893456002 run_sweep check
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "budget and live facts emitted separate notifications: $OUT"
  assert_contains "$OUT" 'over its budget' 'budget facts were lost'
  assert_contains "$OUT" 'nested copies=3, 3 shown' 'the new live copy did not raise one aggregated fact'
  assert_contains "$OUT" "$(copy_path added-live)" 'the new live copy was not named'
  take_snapshots after locked-live unlocked-live
  assert_untouched locked-live unlocked-live
  assert_equals "$before_lock" "$(shasum -a 256 "$lock")" 'check changed the creation lock'
  assert_equals "$before_list" "$(git -C "$SLOT" worktree list --porcelain)" 'check changed registrations'
  assert_absent "$HOMED/data/copy-sweep.log" 'live check wrote a removal log'
  pass 'live nested copies are named once with lock/directory ages, below budget, without changing copies or locks'
}

test_a_lock_probe_cut_by_the_time_bound_reads_unknown_never_directory() {
  make_world live-probe-cut
  add_copy locked-live
  fm_write_meta "$HOMED/state/outer-task.meta" "worktree=$SLOT" "kind=ship"
  git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999' "$(copy_path locked-live)"
  printf 'default-pool off\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  FAKE_GIT_SLEEP_ABSDIR=6 FM_CHECK_TIMEOUT=7 run_sweep check
  [ "$RC" = 0 ] || fail "check with a cut lock probe failed: $OUT"
  assert_contains "$OUT" "$(copy_path locked-live) (task=outer-task age=unknown source=unknown)" 'a copy whose lock probe was cut was not named with an unknown source'
  assert_not_contains "$OUT" 'source=directory' 'a copy whose lock probe was cut was labeled by its directory'
  pass 'a lock probe cut by the time bound names the copy with an unknown source and age, never its directory age'
}

test_a_registered_copy_whose_directory_is_gone_is_not_named_live() {
  make_world live-gone
  add_copy present
  add_copy vanished
  rm -rf "$(copy_path vanished)"
  fm_write_meta "$HOMED/state/outer-task.meta" "worktree=$SLOT" "kind=ship"
  printf 'default-pool off\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  run_sweep check
  assert_contains "$OUT" 'nested copies=1, 1 shown' 'the count included a copy that is not on disk'
  assert_contains "$OUT" "$(copy_path present) (task=outer-task" 'the copy on disk was not named'
  assert_not_contains "$OUT" "$(copy_path vanished)" 'a copy that is not on disk was named as live'
  assert_not_contains "$(cat "$HOMED/state/copy-sweep.record")" "$(copy_path vanished)" 'the record kept a copy that is not on disk'
  pass 'a registered copy whose directory is gone is not named as a live nested copy'
}

test_the_wake_names_the_oldest_five_live_copies_and_points_at_the_report() {
  local i report_line wake_line
  make_world live-bound
  for i in 1 2 3 4 5 6 7; do
    add_copy "n$i"
    TZ=UTC touch -t "$(printf '20291231%02d00' $((i - 1)))" "$(copy_path "n$i")"
  done
  fm_write_meta "$HOMED/state/outer-task.meta" "worktree=$SLOT" "kind=ship"
  printf 'default-pool off\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  FM_COPY_SWEEP_NOW=1893456000 run_sweep
  report_line=$(printf '%s\n' "$OUT" | grep '^copy-sweep: HELD-LIVE-TASK nested copies=')
  assert_contains "$report_line" 'nested copies=7:' 'the report did not count every live copy'
  for i in 1 2 3 4 5 6 7; do
    assert_contains "$report_line" "$(copy_path "n$i") (task=outer-task" "the report left out copy n$i"
  done
  FM_COPY_SWEEP_NOW=1893456000 run_sweep check
  [ "$RC" = 0 ] || fail "check failed: $OUT"
  wake_line=$OUT
  [ "$(printf '%s\n' "$wake_line" | wc -l | tr -d ' ')" = 1 ] || fail "the live copies were not one aggregated line: $wake_line"
  assert_contains "$wake_line" 'nested copies=7, 5 shown (new first, then oldest):' 'the wake did not carry the count and the bound'
  for i in 1 2 3 4 5; do
    assert_contains "$wake_line" "$(copy_path "n$i") (task=outer-task age=" "the wake left out oldest copy n$i"
  done
  assert_not_contains "$wake_line" "$(copy_path n6)" 'the wake named a copy beyond the oldest five'
  assert_not_contains "$wake_line" "$(copy_path n7)" 'the wake named a copy beyond the oldest five'
  assert_contains "$wake_line" 'run bin/fm-copy-sweep.sh with no flag for the full HELD-LIVE-TASK line' 'the wake did not point at the no-flag report'
  pass 'the wake carries the count, the oldest five live copies and a pointer to the report, as one line'
}

test_a_new_youngest_copy_is_named_first_and_the_wake_stays_bounded() {
  local i
  make_world live-new-first
  for i in 1 2 3 4 5 6; do
    add_copy "n$i"
    TZ=UTC touch -t "$(printf '20291231%02d00' $((i - 1)))" "$(copy_path "n$i")"
  done
  fm_write_meta "$HOMED/state/outer-task.meta" "worktree=$SLOT" "kind=ship"
  printf 'default-pool off\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  FM_COPY_SWEEP_NOW=1893456000 run_sweep check
  assert_contains "$OUT" 'nested copies=6, 5 shown (new first, then oldest):' 'the first run did not wake on the backlog'
  add_copy fresh
  TZ=UTC touch -t 202912312359 "$(copy_path fresh)"
  FM_COPY_SWEEP_NOW=1893456000 run_sweep check
  [ "$RC" = 0 ] || fail "check failed: $OUT"
  [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] || fail "the new copy was not one aggregated line: $OUT"
  assert_contains "$OUT" 'nested copies=7, 5 shown (new first, then oldest):' 'the wake did not carry the count and the bound'
  assert_contains "$OUT" "$(copy_path fresh) (task=outer-task age=60s source=directory)" 'the new youngest copy that caused the wake was not named'
  assert_equals 5 "$(printf '%s' "$OUT" | grep -o '(task=outer-task' | wc -l | tr -d ' ')" 'the wake named more or fewer than five copies'
  for i in 1 2 3 4; do
    assert_contains "$OUT" "$(copy_path "n$i") (task=outer-task age=" "the wake left out oldest copy n$i after the new one"
  done
  assert_not_contains "$OUT" "$(copy_path n5)" 'the wake named a copy beyond the new one and the oldest four'
  assert_not_contains "$OUT" "$(copy_path n6)" 'the wake named a copy beyond the new one and the oldest four'
  FM_COPY_SWEEP_NOW=1893456000 run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "a second sweep with no new copy repeated the fact: $OUT"
  pass 'a new youngest copy is named first, the wake names five copies in all, and an unchanged set stays silent'
}

test_closed_task_and_secondmate_home_do_not_raise_live_nested_fact() {
  local proj copy
  make_world closed-nested
  proj="$HOMED/projects/proj"
  fm_git_init_commit "$proj"
  copy="$proj/.claude/worktrees/nested"
  git -C "$proj" worktree add -q -b fm/nested "$copy"
  fm_write_meta "$HOMED/state/owner.meta" "worktree=$proj" 'kind=scout'
  printf 'default-pool off\ndefault-container off\ninterval 0\n' > "$HOMED/config/copy-budget"
  run_sweep check
  assert_contains "$OUT" "$copy (task=owner age=" 'live home-project copy was not named'
  rm "$HOMED/state/owner.meta"
  run_sweep
  assert_not_contains "$OUT" 'HELD-LIVE-TASK nested copies=' 'a closed owner still named a live copy'
  fm_write_meta "$HOMED/state/mate.meta" "worktree=$proj" "home=$HOMED" 'kind=secondmate'
  run_sweep
  assert_not_contains "$OUT" 'HELD-LIVE-TASK nested copies=' 'a secondmate record naming the project was taken for a live task'
  run_sweep check
  [ "$RC" = 0 ] && [ -z "$OUT" ] || fail "closed owner or secondmate home raised a live fact: $OUT"
  [ -d "$copy" ] || fail 'closed copy was removed by the live check'
  git -C "$proj" worktree list --porcelain | grep -qxF "worktree $copy" || fail 'closed copy was unregistered'
  pass 'home-project nested copies are reported while their task is live, but not after closure or for a secondmate home'
}

test_unreadable_registration_is_reported_without_walking_for_copies() {
  make_world unreadable-registration
  add_copy nested
  fm_write_meta "$HOMED/state/owner.meta" "worktree=$SLOT" 'kind=ship'
  FAKE_GIT_FAIL_LIST=1 run_sweep
  assert_contains "$OUT" "clone $SLOT was not read: its registered worktrees cannot be listed" 'enumeration failure was silently treated as no copies'
  assert_not_contains "$OUT" 'HELD-LIVE-TASK nested copies=' 'failed enumeration invented a live copy'
  [ "$(du_calls)" = 0 ] || fail 'failed enumeration walked the directory and measured a copy'
  registered nested || fail 'unreadable enumeration changed a registration'
  pass 'unreadable registered-worktree enumeration reports the gap without a directory-walk fallback'
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

# Vernant's closeout driver and its interpreter, stubbed inside the slot. The
# driver stands where the real one lives and is kept out of the slot's status by
# info/exclude. Without --execute-cleanup it only plans: it says allowed true, or
# allowed false with exit 3 while <log-dir>/refuse-plan exists, or answers with
# whatever <log-dir>/plan-<mode> asks (an empty, malformed, verdictless, false,
# garbage or bare-literal answer, a re-lock of the copy by someone else, or a
# hang that leaves a child running). It
# records its own pid, and a hung plan's child, in <log-dir>/driver.pids. With it, it
# unlocks and plainly removes the copy it is given, or prints two lines and
# exits 3 while <log-dir>/refuse-execute exists. The interpreter runs it as a
# shell script. With <log-dir>/execute-output it prints that file and exits with
# <log-dir>/execute-exit (3 by default), first unlocking the copy while
# <log-dir>/execute-unlock-first exists. Both log what they were asked to do.
install_driver() {  # <slot> <log-dir>
  local slot=$1 log=$2 exclude
  exclude=$(git -C "$slot" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' scripts/ .venv/ >> "$exclude"
  mkdir -p "$slot/scripts/git-stability"
  cat > "$slot/scripts/git-stability/closeout_pr.py" <<SH
export FAKE_DRIVER=1
printf '%s|%s\n' "\$PWD" "\$*" >> "$log/closeout.log"
printf '%s\n' "\$\$" >> "$log/driver.pids"
if [ "\${3:-}" != --execute-cleanup ]; then
  [ ! -f "$log/plan-stderr" ] || cat "$log/plan-stderr" >&2
  if [ -e "$log/plan-output" ]; then
    cat "$log/plan-output"
    exit "\$(cat "$log/plan-exit" 2>/dev/null || printf 0)"
  fi
  if [ -e "$log/plan-hook" ]; then
    bash "$log/plan-hook" "\$2" || exit 4
  fi
  if [ -e "$log/refuse-plan" ]; then
    echo '{"allowed": false, "reason": "pull_request_not_merged"}'
    exit 3
  fi
  if [ -e "$log/plan-empty" ]; then
    exit 0
  fi
  if [ -e "$log/plan-malformed" ]; then
    printf '{"allowed": tr'
    exit 0
  fi
  if [ -e "$log/plan-missing" ]; then
    printf '{"reason": "no verdict"}'
    exit 0
  fi
  if [ -e "$log/plan-false-with-text" ]; then
    printf '{"allowed": false, "reason": "set allowed=true to override"}'
    exit 0
  fi
  if [ -e "$log/plan-garbage-literal" ]; then
    echo 'garbage allowed=true'
    exit 0
  fi
  if [ -e "$log/plan-retain" ]; then
    echo '{"allowed": true, "ignored_payload_disposition": "archive_then_retain_tree", "unique_ignored_paths": ["unique.dat"]}'
    exit 0
  fi
  if [ -e "$log/plan-relock" ]; then
    git worktree unlock "\$2" || exit 4
    git worktree lock --reason 'hand-held by an operator' "\$2" || exit 4
    echo '{"allowed": true}'
    exit 0
  fi
  if [ -e "$log/plan-hang" ]; then
    life=\$(cat "$log/plan-hang" 2>/dev/null)
    sleep "\${life:-30}" &
    printf '%s\n' "\$!" >> "$log/driver.pids"
    wait
    exit 0
  fi
  echo '{"allowed": true}'
  exit 0
fi
[ ! -f "$log/execute-stderr" ] || cat "$log/execute-stderr" >&2
[ ! -f "$log/execute-hook" ] || bash "$log/execute-hook" "\$2" || exit 4
if [ -e "$log/execute-output-\${2##*/}" ]; then
  cat "$log/execute-output-\${2##*/}"
  exit 3
fi
if [ -e "$log/execute-output" ]; then
  if [ -e "$log/execute-unlock-first" ]; then
    git worktree unlock "\$2" || exit 4
  fi
  cat "$log/execute-output"
  exit "\$(cat "$log/execute-exit" 2>/dev/null || printf 3)"
fi
if [ -e "$log/retain-ignored" ]; then
  echo '{"reason":"cleanup_ignored_payload_archived_tree_retained"}'
  exit 3
fi
if [ -e "$log/execute-unlock-only" ]; then
  git worktree unlock "\$2" || exit 4
  exit 0
fi
if [ -e "$log/fail-after-unlock" ]; then
  git worktree unlock "\$2" || exit 4
  echo 'injected removal failure after driver released the lock'
  exit 4
fi
if [ -e "$log/refuse-execute" ]; then
  echo 'refused: pull request is not merged'
  echo 'next: wait for the merge'
  exit 3
fi
git worktree unlock "\$2" || exit 4
git worktree remove "\$2"
SH
  printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$log/vernant-python"
  chmod +x "$log/vernant-python"
  DRIVER_PY="$log/vernant-python"
}

# make_locked_copy_case <name> <lock-mode>: a world with one clean, pushed copy
# locked the way <lock-mode> says. dead = Vernant's format naming a finished pid;
# uuid and ppid = the same with that owner form; recycled = a pid that started long after the lock file was written; live = a
# pid that is still running; foreign = any other lock reason.
LIVE_PID=

make_locked_copy_case() {
  local name=$1 mode=$2 pid='' admin=''
  LIVE_PID=
  make_world "$name"
  add_copy locked
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  case "$mode" in
    dead|uuid|ppid)
      sleep 0.1 & pid=$!
      wait "$pid" 2>/dev/null || true
      if [ "$mode" = uuid ]; then
        git -C "$SLOT" worktree lock --reason "vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=$pid" "$(copy_path locked)"
      elif [ "$mode" = ppid ]; then
        git -C "$SLOT" worktree lock --reason "vernant-session-active owner=ppid:$pid launcher=$pid" "$(copy_path locked)"
      else
        git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$(copy_path locked)"
      fi
      ;;
    recycled|live)
      # Keep the live process in the fixture root so fixture cleanup owns it,
      # even when a regression exits before the case's explicit cleanup.
      (cd "$W" && exec sleep 600) & pid=$!
      disown "$pid" 2>/dev/null || true
      LIVE_PID=$pid
      git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" \
        "$(copy_path locked)"
      [ "$mode" != recycled ] || backdate "$admin/locked"
      ;;
    foreign)
      git -C "$SLOT" worktree lock --reason 'hand-held by an operator' "$(copy_path locked)"
      ;;
  esac
}

# Moves a file's mtime ten seconds into the past, portable between GNU and BSD
# date, so a later-started pid reads as recycled against an older lock file.
backdate() {  # <file>
  local stamp
  if stamp=$(date -v-10S +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$1"
  else
    touch -t "$(date -d '-10 seconds' +%Y%m%d%H%M.%S)" "$1"
  fi
}

# A locked copy with a gone launcher is planned, preserved, released and removed
# by the driver in one --apply run, and the run reports the GiB it freed net of
# the bytes it preserved.
assert_driver_release() {  # <name> <lock-mode>
  local admin preserved sums hash branch head plan execute
  make_locked_copy_case "$1" "$2"
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  printf '%s\t%s\n' "$(copy_path locked)" $((2 * GIB)) >> "$W/du-table"
  branch=$(git -C "$(copy_path locked)" symbolic-ref --short HEAD)
  head=$(git -C "$(copy_path locked)" rev-parse HEAD)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_class locked PENDING-DRIVER
  assert_contains "$OUT" "not yet proven removable" "report overstated an unplanned driver candidate"
  assert_contains "$OUT" "launcher" "the report did not explain the dead launcher"
  [ -e "$(copy_path locked)" ] || fail "report mode removed the copy"
  assert_absent "$W/closeout.log" "report mode ran the closeout driver"
  FAKE_DU_PRESERVED_KIB=$((GIB / 2)) FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "apply did not report the driver removal"
  assert_contains "$OUT" "copy 2.00 GiB, preserved 0.50 GiB, net freed 1.50 GiB" \
    "the removal line did not report the copy, preserved and net GiB"
  assert_equals "copies=1 GiB=2.00 reaped=1 freed=1.50" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "the run did not end with the GiB it freed"
  [ ! -e "$(copy_path locked)" ] || fail "the driver did not remove the copy"
  ! registered locked || fail "the released copy is still registered"
  assert_equals "$head" "$(git -C "$SLOT" rev-parse "refs/heads/$branch")" \
    "the released copy's branch no longer preserves its exact commit"
  assert_equals "$head" "$(git -C "$W/origin.git" rev-parse "refs/heads/$branch")" \
    "the released copy's remote commit changed"
  [ -f "$W/closeout.log" ] || fail "the closeout driver was never run"
  plan="$SLOT|--cleanup-worktree $(copy_path locked)"
  execute="$plan --execute-cleanup"
  assert_equals "$plan"$'\n'"$execute" "$(cat "$W/closeout.log")" \
    "the driver was not asked to plan and then to release the exact copy from the slot"
  preserved=$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name unique.dat -type f 2>/dev/null | head -n 1)
  [ -n "$preserved" ] || fail "the copy's ignored state was not preserved before release"
  assert_contains "$preserved" "$head" "the preserve directory is not keyed by the copy's HEAD"
  assert_equals 'durable state' "$(cat "$preserved")" 'the preserved ignored file changed'
  sums="$(dirname "$(dirname "$preserved")")/meta/SHA256SUMS"
  assert_present "$sums" "no SHA-256 manifest was written for the preserved state"
  hash=$(shasum -a 256 "$preserved" | awk '{print $1}')
  assert_contains "$(cat "$sums")" "$hash  unique.dat" "the manifest does not record the preserved content"
  [ -f "$HOMED/data/copy-sweep.log" ] || fail "the driver removal was not logged"
  assert_contains "$(cat "$HOMED/data/copy-sweep.log")" "proof=clean, no process, no record" \
    "the log line does not carry the proof"
  assert_contains "$(cat "$HOMED/data/copy-sweep.log")" "preserved_kib=$((GIB / 2))" \
    "the log line does not carry the preserved bytes"
  [ ! -e "$admin" ] || fail "the released copy's admin directory is still there"
  if grep -Eq 'worktree (unlock|lock)|(--force|-ff?)( |$)|treehouse destroy' "$W/git.log"; then
    fail "the sweep itself issued a forbidden release operation"
  fi
  if [ -f "$W/rm.log" ]; then
    assert_no_grep "$admin/locked" "$W/rm.log" "the sweep deleted a lock file"
  fi
  assert_absent "$W/treehouse.log" "the sweep called Treehouse"
  if [ -n "$LIVE_PID" ]; then
    kill "$LIVE_PID" 2>/dev/null || true
    wait "$LIVE_PID" 2>/dev/null || true
    LIVE_PID=
  fi
}

test_recycled_launcher_lock_is_held() {
  local admin before
  make_locked_copy_case driver-recycled recycled
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  kill -0 "$LIVE_PID" 2>/dev/null || fail "the recycled-launcher fixture ended before its verdict"
  kill "$LIVE_PID" 2>/dev/null || true
  wait "$LIVE_PID" 2>/dev/null || true
  [ "$RC" = 0 ] || fail "recycled launcher apply failed: $OUT"
  assert_class locked HELD-LOCKED
  assert_contains "$OUT" "launcher $LIVE_PID is alive" "a live recycled pid was not named"
  assert_contains "$OUT" "start age=" "the launcher's age was not reported"
  assert_contains "$OUT" "lock mtime=" "the lock's mtime was not reported"
  assert_absent "$W/closeout.log" "the driver ran for a live recycled pid"
  registered locked || fail "the recycled-pid copy was unregistered"
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "the recycled lock changed"
  pass "a live recycled launcher pid holds its copy and unchanged lock, with age and lock mtime reported"
}

test_dead_launcher_dirty_copy_is_held() {
  local admin before
  make_locked_copy_case locked-dirty dead
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  printf 'untracked work\n' > "$(copy_path locked)/untracked.txt"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "dirty locked copy: apply failed ($RC): $OUT"
  assert_class locked HELD-DIRTY
  registered locked || fail "the dirty locked copy was unregistered"
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "the dirty copy's lock changed"
  assert_equals 'untracked work' "$(cat "$(copy_path locked)/untracked.txt")" "the untracked work changed"
  assert_absent "$W/closeout.log" "the driver ran on a dirty locked copy"
  assert_equals '' "$(find "$HOMED/data/copy-sweep" -mindepth 1 -print 2>/dev/null)" \
    "a dirty locked copy wrote preservation or receipt data"
  pass "a dead-launcher locked copy with untracked work stays registered and locked, without a driver call or sweep data"
}

test_dead_launcher_process_inside_copy_is_held() {
  local admin before
  make_locked_copy_case locked-process dead
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  FAKE_LSOF_CWD="$(copy_path locked)" FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "locked copy with process: apply failed ($RC): $OUT"
  assert_class locked HELD-LIVE-TASK
  registered locked || fail "the locked copy with a process inside was unregistered"
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "the process-owned copy's lock changed"
  assert_absent "$W/closeout.log" "the driver ran on a locked copy with a process inside"
  assert_equals '' "$(find "$HOMED/data/copy-sweep" -mindepth 1 -print 2>/dev/null)" \
    "a locked copy with a process inside wrote preservation or receipt data"
  pass "a dead-launcher locked copy with a process inside stays registered and locked, without a driver call or sweep data"
}

test_dead_launcher_lock_is_released_by_the_driver() {
  assert_driver_release driver-dead dead
  pass "a locked copy whose launcher pid has finished is planned, preserved, released by the driver and removed, one run, with the net GiB freed reported"
}

driver_env_warning() {
  printf 'env_loading: no .env found for %s/scripts/git-stability/reap_core.py; tried in order: %s/.env. Create .env at the clone root (the primary checkout) or in this worktree.\n' "$SLOT" "$SLOT"
}

test_plan_stderr_warning_does_not_block_allowed_stdout() {
  local n
  make_locked_copy_case plan-stderr-warning dead
  install_driver "$SLOT" "$W"
  for n in 2 3; do
    add_copy "locked$n"
    git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$(copy_path "locked$n")"
  done
  driver_env_warning > "$W/plan-stderr"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=2 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "stderr warning blocked an allowed plan: $OUT"
  assert_equals 2 "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" "allowed stdout with stderr warning was not released under the cap"
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -c $'^DEFERRED\t')" "stderr warning changed cap deferral"
  assert_equals 2 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "stderr warning changed the execute count"
  pass "an exact env_loading missing-.env warning on stderr does not veto an allowed stdout plan, and the cap still limits executes"
}

test_execute_stderr_warning_keeps_temporary_refusal_retryable() {
  local reason admin before
  for reason in cleanup_lease_conflict cleanup_skipped_live_or_unknown; do
    make_locked_copy_case "execute-warning-$reason" dead
    install_driver "$SLOT" "$W"
    driver_env_warning > "$W/execute-stderr"
    printf '{"allowed": false, "reason": "%s"}\n' "$reason" > "$W/execute-output"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    before=$(shasum -a 256 "$admin/locked")
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 1 ] || fail "$reason: execute refusal should fail this run: $OUT"
    assert_contains "$OUT" "env_loading: no .env found" "$reason: stderr warning was not retained as display text"
    assert_contains "$OUT" "$reason" "$reason: stdout refusal reason was lost"
    assert_contains "$OUT" "next sweep run plans it again" "$reason: stderr made a temporary refusal permanent"
    registered locked || fail "$reason: temporary refusal unregistered the copy"
    assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "$reason: temporary refusal changed the lock"
    assert_equals '' "$(find "$HOMED/data/copy-sweep/retained" -type f -print 2>/dev/null)" "$reason: temporary refusal left a permanent receipt"
    rm -f "$W/execute-output"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$reason: next run did not retry and release: $OUT"
    assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "$reason: retried copy was not removed"
    assert_equals 2 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "$reason: next run did not execute again"
  done
  pass "missing-.env stderr warnings remain visible but do not turn either temporary stdout refusal into a permanent receipt"
}

test_failed_nested_registration_proof_holds_copy() {
  local admin before
  make_locked_copy_case unreadable-inner-proof dead
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  FAKE_GIT_FAIL_LIST_AFTER=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep
  assert_class locked HELD-DIRTY
  assert_contains "$OUT" "registered nested copies cannot be listed" "unreadable inner-copy proof was not named"
  rm -f "$W/git.log.list-count"
  FAKE_GIT_FAIL_LIST_AFTER=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  assert_not_contains "$OUT" "REMOVED"$'\t' "failed inner-copy proof was reported removed"
  registered locked || fail "failed inner-copy enumeration unregistered the copy"
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "failed inner-copy enumeration changed the lock"
  assert_absent "$W/closeout.log" "driver ran without a readable inner-copy proof"
  pass "a failed nested-registration enumeration holds a clean locked copy before any driver call"
}

test_failed_post_removal_registration_keeps_receipt_unproved() {
  make_locked_copy_case unreadable-post-removal dead
  install_driver "$SLOT" "$W"
  cat > "$W/vernant-python" <<SH
#!/usr/bin/env bash
rc=0
bash "\$@" || rc=\$?
if [ "\${4:-}" = --execute-cleanup ]; then
  : > "$W/post-execute-list-fails"
fi
exit "\$rc"
SH
  chmod +x "$W/vernant-python"
  FAKE_GIT_FAIL_LIST_FILE="$W/post-execute-list-fails" FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "unproved post-removal registration should fail: $OUT"
  assert_contains "$OUT" "registration after removal could not be proved" "failed post-removal proof was not reported"
  assert_not_contains "$OUT" "REMOVED"$'\t' "unknown registration was reported removed"
  assert_absent "$HOMED/data/copy-sweep.log" "unknown registration was logged as removed"
  assert_equals 1 "$(find "$HOMED/data/copy-sweep/retained" -type f | wc -l | tr -d ' ')" "unknown registration cleared the retention receipt"
  [ ! -e "$(copy_path locked)" ] || fail "fixture driver did not remove the directory"
  ! registered locked || fail "fixture driver did not unregister the copy"
  assert_equals 1 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "unknown registration retried execute"
  pass "a failed post-removal registration proof reports unproved, keeps the receipt, and never reports or logs REMOVED"
}

test_locked_release_cap_defers_copies_until_the_next_run() {
  local setting limit total n name admin reason before survivors
  for setting in default 2; do
    if [ "$setting" = default ]; then
      unset FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT
      limit=5
    else
      export FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=$setting
      limit=$setting
    fi
    total=$((limit + 2))
    make_locked_copy_case "driver-cap-$setting" dead
    install_driver "$SLOT" "$W"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    reason=$(cat "$admin/locked")
    before=$(shasum -a 256 "$admin/locked" | awk '{ print $1 }')
    for ((n = 2; n <= total; n++)); do
      add_copy "locked$n"
      git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path "locked$n")"
    done
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$setting cap: first apply failed ($RC): $OUT"
    assert_equals "$limit" "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" \
      "$setting cap: wrong number of locked copies released"
    assert_equals 2 "$(printf '%s\n' "$OUT" | grep -c $'^DEFERRED\t')" \
      "$setting cap: excess copies were not deferred"
    assert_contains "$OUT" "per-run cap: $limit locked release slots used; eligible next run" \
      "$setting cap: deferral did not explain its limit and next-run eligibility"
    assert_contains "$OUT" 'summary: HELD-LOCKED=0' "$setting cap: deferred copies were held"
    assert_equals "$((2 * limit))" "$(wc -l < "$W/closeout.log" | tr -d ' ')" \
      "$setting cap: deferred copies reached the driver"
    survivors=0
    for ((n = 1; n <= total; n++)); do
      name=locked
      [ "$n" = 1 ] || name="locked$n"
      if registered "$name"; then
        survivors=$((survivors + 1))
        assert_class "$name" DEFERRED
        admin=$(git -C "$(copy_path "$name")" rev-parse --absolute-git-dir)
        assert_equals "$before" "$(shasum -a 256 "$admin/locked" | awk '{ print $1 }')" \
          "$setting cap: a deferred copy's lock changed"
        if grep -Fxq "$SLOT|--cleanup-worktree $(copy_path "$name")" "$W/closeout.log"; then
          fail "$setting cap: a deferred copy reached the driver's plan"
        fi
        assert_no_grep "$(copy_path "$name") " "$W/closeout.log" \
          "$setting cap: a deferred copy reached the driver's execute"
      fi
    done
    assert_equals 2 "$survivors" "$setting cap: wrong number of copies stayed registered"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$setting cap: second apply failed ($RC): $OUT"
    assert_equals 2 "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" \
      "$setting cap: next run did not release both deferred copies"
    assert_contains "$OUT" 'summary: DEFERRED=0' "$setting cap: deferral persisted into the next run"
    for ((n = 1; n <= total; n++)); do
      name=locked
      [ "$n" = 1 ] || name="locked$n"
      ! registered "$name" || fail "$setting cap: $name stayed registered after the next run"
    done
  done
  unset FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT
  pass "the default cap releases five of seven locked copies and defers two unchanged until the next run; an explicit cap of two behaves the same way"
}

test_refusals_use_no_release_slot_and_cannot_starve_later_copies() {
  local reason name admin run n line real_cp z3admin
  reason='vernant-session-active owner=launcher:999999 launcher=999999'
  make_world driver-cap-refusals
  install_driver "$SLOT" "$W"
  printf 'unpreservable.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  for name in z1 z2 z3 z4 z5 c1 c2 c3 c4 c5 c6 c7; do
    add_copy "$name"
    git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path "$name")"
  done
  printf 'cannot be copied\n' > "$(copy_path z1)/unpreservable.dat"
  real_cp=$(command -v cp)
  printf '#!/usr/bin/env bash\ncase "$*" in *unpreservable.dat*) exit 1 ;; esac\nexec %q "$@"\n' "$real_cp" > "$FAKEBIN/cp"
  chmod +x "$FAKEBIN/cp"
  printf '{"allowed": false, "reason": "cleanup_skipped_live_or_unknown"}\n' > "$W/execute-output-z2"
  printf '{"allowed": false, "reason": "cleanup_lease_conflict"}\n' > "$W/execute-output-z4"
  z3admin=$(git -C "$(copy_path z3)" rev-parse --absolute-git-dir)
  cat > "$W/plan-hook" <<SH
case "\$1" in
  */z3)
    if grep -q 'owner=launcher:' "$z3admin/locked"; then
      printf 'vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=999999\n' > "$z3admin/locked"
    else
      printf '%s\n' '$reason' > "$z3admin/locked"
    fi
    ;;
  */z5) exit 1 ;;
esac
SH
  for run in 1 2; do
    FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 1 ] || fail "run $run: the refused copies should fail the run, got $RC: $OUT"
    for name in z1 z2 z3 z4 z5; do
      registered "$name" || fail "run $run: refused copy $name was removed"
      assert_equals "$run" "$(grep -cFx "$SLOT|--cleanup-worktree $(copy_path "$name")" "$W/closeout.log")" \
        "run $run: refused copy $name was not planned again"
    done
    for name in z1 z2 z4; do
      admin=$(git -C "$(copy_path "$name")" rev-parse --absolute-git-dir)
      assert_equals "$reason" "$(cat "$admin/locked")" "run $run: refused copy $name lost its lock"
    done
    for name in z1 z3 z5; do
      line=$(printf '%s\n' "$OUT" | grep -F "$(copy_path "$name")") || fail "run $run: refused copy $name was not reported: $OUT"
      assert_not_contains "$line" "DEFERRED" "run $run: refused copy $name was deferred"
    done
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path z1)") || fail "run $run: the failed preservation was not reported: $OUT"
    assert_contains "$line" "could not be preserved" "run $run: z1 did not fail its preservation"
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path z2)") || fail "run $run: the liveness refusal was not reported: $OUT"
    assert_contains "$line" "cleanup_skipped_live_or_unknown" "run $run: z2 did not get the driver's liveness refusal"
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path z3)") || fail "run $run: the failed reproof was not reported: $OUT"
    assert_contains "$line" "changed HEAD or creation-lock bytes" "run $run: z3 did not fail its reproof"
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path z4)") || fail "run $run: the lease refusal was not reported: $OUT"
    assert_contains "$line" "cleanup_lease_conflict" "run $run: z4 did not get the driver's lease refusal"
    assert_class z5 HELD-LOCKED
    for name in z1 z3 z5; do
      assert_no_grep "$(copy_path "$name") --execute-cleanup" "$W/closeout.log" "run $run: $name reached the driver's execute"
    done
    for name in z2 z4; do
      assert_equals "$run" "$(grep -cFx "$SLOT|--cleanup-worktree $(copy_path "$name") --execute-cleanup" "$W/closeout.log")" \
        "run $run: $name did not reach the driver's execute"
    done
    if [ "$run" = 1 ]; then
      assert_equals 5 "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" "run 1: refusals used release slots"
      for name in c3 c4 c5 c6 c7; do
        assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path "$name")" "run 1: clean copy $name was not released"
        ! registered "$name" || fail "run 1: released copy $name is still registered"
      done
      for name in c1 c2; do
        assert_class "$name" DEFERRED
        registered "$name" || fail "run 1: deferred copy $name was removed"
        assert_no_grep "$(copy_path "$name")" "$W/closeout.log" "run 1: deferred copy $name reached the driver"
      done
      assert_contains "$OUT" "per-run cap: 5 locked release slots used; eligible next run" \
        "run 1: deferral did not explain its limit"
      assert_contains "$OUT" 'summary: DEFERRED=2' "run 1: wrong number of deferred copies"
    else
      assert_equals 2 "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" "run 2: wrong number of copies released"
      assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path c1)" "run 2: deferred copy c1 was not released"
      assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path c2)" "run 2: deferred copy c2 was not released"
      assert_contains "$OUT" 'summary: DEFERRED=0' "run 2: a copy was deferred again"
      for ((n = 1; n <= 7; n++)); do
        ! registered "c$n" || fail "run 2: clean copy c$n is still registered"
      done
    fi
  done
  pass "a refused plan, a failed preservation, a failed reproof and temporary driver refusals use no release slot, so five copies that refuse on every run cannot starve the clean copies behind them: one run releases five clean copies and defers two, and the next run releases those two"
}

test_failed_post_execute_enumeration_uses_release_slot() {
  local n name admin before executed=0 deferred=0
  make_world driver-cap-partial-enumeration
  install_driver "$SLOT" "$W"
  for ((n = 1; n <= 7; n++)); do
    add_copy "p$n"
    git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$(copy_path "p$n")"
  done
  printf '{"allowed": false, "reason": "cleanup_lease_conflict"}\n' > "$W/execute-output"
  # Each refused execute leaves the copy untouched but makes the next worktree
  # enumeration print that copy and then fail. No earlier proof is affected.
  cat > "$W/vernant-python" <<SH
#!/usr/bin/env bash
rc=0
bash "\$@" || rc=\$?
if [ "\${4:-}" = --execute-cleanup ]; then
  printf '%s\n' "\$3" > "$W/partial-list"
fi
exit "\$rc"
SH
  chmod +x "$W/vernant-python"
  admin=$(git -C "$(copy_path p1)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked" | awk '{ print $1 }')
  FAKE_GIT_PARTIAL_LIST_FILE="$W/partial-list" FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5 \
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "unknown enumeration should leave execute refusals failed, got $RC: $OUT"
  assert_equals 5 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" \
    "an enumeration that prints the candidate and then fails did not use a release slot"
  assert_equals 5 "$(wc -l < "$W/partial-list.log" | tr -d ' ')" \
    "the partial-output enumerator was not exercised after every execute"
  assert_equals 0 "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" "an unknown enumeration was reported removed"
  for ((n = 1; n <= 7; n++)); do
    name="p$n"
    registered "$name" || fail "unknown enumeration: $name was unregistered"
    admin=$(git -C "$(copy_path "$name")" rev-parse --absolute-git-dir)
    assert_equals "$before" "$(shasum -a 256 "$admin/locked" | awk '{ print $1 }')" \
      "unknown enumeration: $name lost its creation lock"
    if grep -qFx "$SLOT|--cleanup-worktree $(copy_path "$name") --execute-cleanup" "$W/closeout.log"; then
      executed=$((executed + 1))
      assert_contains "$OUT" "FAILED"$'\t'"$(copy_path "$name")" "unknown enumeration: execute refusal was not reported"
    else
      deferred=$((deferred + 1))
      assert_class "$name" DEFERRED
      assert_no_grep "$(copy_path "$name")" "$W/closeout.log" "unknown enumeration: deferred copy reached the driver"
    fi
  done
  assert_equals 5 "$executed" "unknown enumeration: wrong number of executed copies"
  assert_equals 2 "$deferred" "unknown enumeration: wrong number of deferred copies"
  assert_contains "$OUT" "per-run cap: 5 locked release slots used; eligible next run" \
    "unknown enumeration: deferral did not explain its limit"
  pass "a post-execute enumeration that prints the candidate and then fails is unknown, uses a release slot, and limits seven untouched driver refusals to five executes with two deferred"
}

test_partial_releases_use_release_slots() {
  local mode name n executed deferred
  for mode in execute-unlock-only fail-after-unlock; do
    make_world "driver-cap-$mode"
    install_driver "$SLOT" "$W"
    for ((n = 1; n <= 7; n++)); do
      add_copy "p$n"
      git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$(copy_path "p$n")"
    done
    : > "$W/$mode"
    FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 1 ] || fail "$mode: partial releases should fail the run, got $RC: $OUT"
    assert_equals 5 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" \
      "$mode: partial releases did not use release slots"
    assert_equals 0 "$(printf '%s\n' "$OUT" | grep -c $'^REMOVED\t')" "$mode: a partial release was reported removed"
    executed=0
    deferred=0
    for ((n = 1; n <= 7; n++)); do
      name="p$n"
      registered "$name" || fail "$mode: $name was unregistered"
      if grep -qFx "$SLOT|--cleanup-worktree $(copy_path "$name") --execute-cleanup" "$W/closeout.log"; then
        executed=$((executed + 1))
        printf '%s\n' "$OUT" | grep -qF "FAILED"$'\t'"$(copy_path "$name")" \
          || fail "$mode: partial release of $name was not reported FAILED: $OUT"
      else
        deferred=$((deferred + 1))
        assert_class "$name" DEFERRED
        assert_no_grep "$(copy_path "$name")" "$W/closeout.log" "$mode: deferred copy $name reached the driver"
      fi
    done
    assert_equals 5 "$executed" "$mode: wrong number of copies executed"
    assert_equals 2 "$deferred" "$mode: wrong number of copies deferred"
    assert_contains "$OUT" 'summary: DEFERRED=2' "$mode: the summary did not count the deferred copies"
    assert_contains "$OUT" "per-run cap: 5 locked release slots used; eligible next run" \
      "$mode: deferral did not explain its limit"
  done
  pass "a driver execute that reports success but leaves the copy registered, or fails after releasing its lock, uses a release slot, so a systematic partial release reaches at most five copies per run and defers the rest"
}

test_uuid_owner_lock_is_released_by_the_driver() {
  assert_driver_release driver-uuid uuid
  pass "a dead-launcher UUID-owner creation lock uses the same supported driver release"
}

test_ppid_owner_lock_is_released_by_the_driver() {
  assert_driver_release driver-ppid ppid
  pass "a dead-launcher creation lock with an owner=ppid:<pid> owner uses the same driver release, because only its launcher pid and the other proofs decide"
}

test_a_plan_that_reports_the_retain_rule_holds_the_copy_and_copies_nothing() {
  local admin before
  make_locked_copy_case planretain dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  : > "$W/plan-retain"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "a plan that reports the retain rule must not fail the run, got $RC: $OUT"
  assert_class locked HELD-LOCKED
  assert_contains "$OUT" "archive_then_retain_tree" "the driver's retain rule is missing from the report"
  assert_contains "$OUT" "never removes it automatically" "the report did not say the driver keeps the tree"
  assert_contains "$OUT" "summary: HELD-LOCKED=1" "the held copy is not counted as held"
  assert_not_contains "$OUT" "FAILED" "a retain-rule plan was reported as a failure"
  assert_not_contains "$OUT" "KEPT" "a retain-rule plan was reported as an execution result"
  assert_absent "$HOMED/data/copy-sweep" "a retain-rule plan copied ignored entries or wrote a receipt"
  assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
    "the driver was asked for more than its plan"
  [ -e "$(copy_path locked)" ] || fail "a retain-rule copy was removed"
  registered locked || fail "a retain-rule copy is no longer registered"
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "the retain-rule copy's lock changed"
  assert_equals 'durable state' "$(cat "$(copy_path locked)/unique.dat")" "the retain-rule copy's ignored file changed"
  [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "a retain-rule copy was logged as removed"
  pass "a plan that reports the driver's retain rule holds the copy with the driver's words, copies nothing, never executes, and exits 0"
}

test_a_refused_plan_holds_the_copy_copies_nothing_and_exits_zero() {
  local admin
  make_locked_copy_case planrefused dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  : > "$W/refuse-plan"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "a refused plan must not fail the run, got $RC: $OUT"
  assert_class locked HELD-LOCKED
  assert_contains "$OUT" "pull_request_not_merged" "the driver's own reason is missing from the report"
  assert_contains "$OUT" "(exit 3)" "the driver's exit code is missing from the report"
  assert_contains "$OUT" "summary: REAPABLE-DRIVER=0" "a refused copy is still counted as reapable"
  assert_contains "$OUT" "summary: HELD-LOCKED=1" "a refused copy is not counted as held"
  assert_not_contains "$OUT" "FAILED" "a refused plan was reported as a failure"
  assert_absent "$HOMED/data/copy-sweep" "a refused plan copied ignored entries into data"
  assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
    "the driver was asked for more than its plan"
  [ -e "$(copy_path locked)" ] || fail "a refused copy was removed"
  registered locked || fail "a refused copy is no longer registered"
  [ -f "$admin/locked" ] || fail "a refused copy lost its lock"
  assert_equals 'durable state' "$(cat "$(copy_path locked)/unique.dat")" "the refused copy's ignored file changed"
  [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "a refused copy was logged as removed"
  assert_equals "copies=1 GiB=0.00 reaped=0 freed=0.00" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "the run did not end with its total"
  rm -f "$W/refuse-plan" "$W/closeout.log"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the allowed plan failed the run ($RC): $OUT"
  [ ! -e "$(copy_path locked)" ] || fail "a copy whose plan became allowed was not released"
  pass "a copy whose plan the driver refuses is held with the driver's reason, nothing is copied, the run exits 0, and the next run releases it once the plan allows it"
}

test_a_failure_after_an_allowed_plan_leaves_the_copy_and_records_the_drivers_refusal() {
  local admin line
  make_locked_copy_case executerefused dead
  install_driver "$SLOT" "$W"
  : > "$W/refuse-execute"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a failure after an allowed plan should exit 1, got $RC: $OUT"
  line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
    || fail "the refusal was not reported as FAILED: $OUT"
  assert_contains "$line" "(exit 3)" "the driver's exit code was lost"
  assert_contains "$line" "refused: pull request is not merged" "the first line of the driver's refusal was lost"
  assert_contains "$line" "next: wait for the merge" "the last line of the driver's refusal was lost"
  assert_not_contains "$OUT" "REMOVED" "a refused copy was reported removed"
  [ -e "$(copy_path locked)" ] || fail "a refused copy was removed"
  registered locked || fail "a refused copy is no longer registered"
  [ -f "$admin/locked" ] || fail "a refused copy lost its lock"
  [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "a refused copy was logged as removed"
  assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)"$'\n'"$SLOT|--cleanup-worktree $(copy_path locked) --execute-cleanup" \
    "$(cat "$W/closeout.log")" "the driver did not run once to plan and once to release"
  pass "a failure after an allowed plan leaves the copy locked and registered, the run exits 1, and the FAILED line carries the driver's refusal lines and exit code"
}

# Prints every preserved copy of unique.dat under this world's sweep data, one
# per line, so a test can count the preserves a run left.
preserved_unique() {
  find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name unique.dat -type f 2>/dev/null
}

test_a_temporary_execute_refusal_is_planned_and_released_by_the_next_run() {
  local reason admin before line retained run kept real_cp
  for reason in cleanup_lease_conflict cleanup_skipped_live_or_unknown; do
    make_locked_copy_case "temporary-$reason" dead
    install_driver "$SLOT" "$W"
    printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'durable state\n' > "$(copy_path locked)/unique.dat"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    before=$(shasum -a 256 "$admin/locked")
    retained="$HOMED/data/copy-sweep/retained"
    printf '{"allowed": false, "reason": "%s"}\n' "$reason" > "$W/execute-output"
    for run in 1 2; do
      FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
      [ "$RC" = 1 ] || fail "$reason run $run: a refused execute should exit 1, got $RC: $OUT"
      line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
        || fail "$reason run $run: the refusal was not reported as FAILED: $OUT"
      assert_contains "$line" "(exit 3): $reason: {\"allowed\": false" "$reason run $run: the driver's reason was lost"
      assert_contains "$line" "next sweep run plans it again" "$reason run $run: the report did not say the copy is retried"
      [ -e "$(copy_path locked)" ] || fail "$reason run $run: a refused copy was removed"
      registered locked || fail "$reason run $run: a refused copy is no longer registered"
      assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "$reason run $run: the refused copy's lock changed"
      assert_equals 'durable state' "$(cat "$(copy_path locked)/unique.dat")" "$reason run $run: the copy's original ignored file changed"
      [ -z "$(ls -A "$retained" 2>/dev/null)" ] || fail "$reason run $run: a temporary refusal left a retention receipt"
      assert_equals '' "$(preserved_unique)" "$reason run $run: a temporary refusal left this run's preserve behind"
    done
    assert_equals 4 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "$reason: the second run did not plan and execute again"
    rm -f "$W/execute-output"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$reason: the retry failed ($RC): $OUT"
    assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "$reason: the next run did not release the copy"
    [ ! -e "$(copy_path locked)" ] || fail "$reason: the copy is still on disk after the retry"
    ! registered locked || fail "$reason: the copy is still registered after the retry"
    assert_equals 6 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "$reason: the next run did not plan and execute again"
    assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(sed -n 5p "$W/closeout.log")" \
      "$reason: the retry did not ask the driver for a new plan first"
    kept=$(preserved_unique)
    assert_equals 1 "$(printf '%s\n' "$kept" | grep -c .)" "$reason: the release did not leave exactly one preserve"
    assert_equals 'durable state' "$(cat "$kept")" "$reason: the released copy's preserved ignored file changed"
  done
  make_locked_copy_case temporary-after-unlock dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  printf '{"allowed": false, "reason": "cleanup_lease_conflict"}\n' > "$W/execute-output"
  : > "$W/execute-unlock-first"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a temporary refusal after unlock should exit 1, got $RC: $OUT"
  assert_not_contains "$OUT" "plans it again" "a partial release was reported as retryable"
  assert_equals 'durable state' "$(cat "$(preserved_unique)")" "a partial release lost its preserve"
  rm -f "$W/execute-output" "$W/execute-unlock-first"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the held partial release failed on rerun ($RC): $OUT"
  assert_class locked HELD-LOCKED
  registered locked || fail "a partially released copy was removed on the next run"
  assert_equals 2 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "a partial release was retried"
  assert_equals 1 "$(preserved_unique | grep -c .)" "a held partial release was preserved again"
  make_locked_copy_case temporary-after-overwrite dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  real_cp=$(command -v cp)
  cat > "$FAKEBIN/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf 'new owner state\\n' > "$(copy_path locked)/unique.dat"
SH
  chmod +x "$FAKEBIN/cp"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "an overwrite during preservation should exit 1, got $RC: $OUT"
  assert_contains "$OUT" "changed after it was preserved" "an overwrite during preservation was not named"
  assert_contains "$OUT" "plans it again" "an overwrite during preservation was not reported retryable"
  assert_equals 0 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "the driver executed after an original changed during preservation"
  assert_contains "$OUT" "this run's preserve stays" "the report did not say the old content was kept"
  assert_equals 'new owner state' "$(cat "$(copy_path locked)/unique.dat")" "the copy's changed ignored file was touched"
  assert_equals 'durable state' "$(cat "$(preserved_unique)")" "the refusal discarded the only saved original"
  [ -z "$(ls -A "$HOMED/data/copy-sweep/retained" 2>/dev/null)" ] || fail "an overwrite during preservation left a retention receipt"
  registered locked || fail "a copy whose original changed after preservation was removed"
  rm -f "$FAKEBIN/cp"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the retry after an overwrite failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "the next run did not retry and release the overwritten copy"
  ! registered locked || fail "the overwritten copy is still registered after the retry"
  assert_equals 3 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "the retry did not plan and execute again"
  assert_equals 2 "$(preserved_unique | grep -c .)" "the retry did not add exactly one preserve for the changed content"
  assert_equals "durable state"$'\n'"new owner state" "$(preserved_unique | while IFS= read -r kept; do cat "$kept"; done | sort)" \
    "the preserved old content or the new content is missing"
  make_locked_copy_case temporary-after-execute-write dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  printf '{"allowed": false, "reason": "cleanup_lease_conflict"}\n' > "$W/execute-output"
  cat > "$W/execute-hook" <<'SH'
printf 'new owner state\n' > "$1/unique.dat"
SH
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a temporary refusal after an execute-time write should exit 1, got $RC: $OUT"
  line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
    || fail "the temporary refusal after an execute-time write was not reported as FAILED: $OUT"
  assert_contains "$line" "cleanup_lease_conflict" "the driver's temporary refusal was not reported"
  assert_contains "$line" "plans it again" "a temporary refusal after an execute-time write was not reported retryable"
  assert_contains "$line" "this run's preserve stays" "the report did not say the old content was kept"
  assert_equals 1 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "the driver's execute was not reached"
  assert_equals 'new owner state' "$(cat "$(copy_path locked)/unique.dat")" "the copy's changed ignored file was touched"
  assert_equals 'durable state' "$(cat "$(preserved_unique)")" "a temporary refusal discarded the only saved original"
  [ -z "$(ls -A "$HOMED/data/copy-sweep/retained" 2>/dev/null)" ] || fail "a temporary refusal after an execute-time write left a retention receipt"
  registered locked || fail "a copy whose original changed during execute was removed"
  rm -f "$W/execute-hook" "$W/execute-output"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the retry after an execute-time write failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "the next quiet run did not release the copy"
  ! registered locked || fail "the copy is still registered after the retry"
  assert_equals 4 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "the retry did not plan and execute again"
  assert_equals "durable state"$'\n'"new owner state" "$(preserved_unique | while IFS= read -r kept; do cat "$kept"; done | sort)" \
    "the preserved old content or the new content is missing"
  pass "an execute refusal the driver names temporary (lease conflict, live or unknown tenant) that released nothing leaves no receipt and discards its own run's preserve, so repeated refusals add no preserve while the copy keeps its originals, and the next allowed run preserves once and releases the copy; an original that changed in the copy during preservation stops the release before execute, keeps the preserve of the old content and the next run still retries the copy; an original that changed during execute before the same temporary refusal keeps that preserve with no receipt and the next quiet run releases the copy; the same refusal after an unlock stays held with its preserve"
}

test_content_that_keeps_changing_waits_and_the_first_quiet_run_preserves_once_and_releases() {
  local run real_cp kept line
  make_locked_copy_case waiting-content dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'v0\n' > "$(copy_path locked)/unique.dat"
  real_cp=$(command -v cp)
  cat > "$FAKEBIN/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf 'v1\\n' > "$(copy_path locked)/unique.dat"
SH
  chmod +x "$FAKEBIN/cp"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a write during preservation should exit 1, got $RC: $OUT"
  assert_contains "$OUT" "this run's preserve stays" "the first run did not keep its preserve of the old content"
  assert_equals 0 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "the driver executed after a write during preservation"
  rm -f "$FAKEBIN/cp"
  for run in 2 3 4; do
    printf 'v%s\n' "$run" > "$(copy_path locked)/unique.dat"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "run $run: a copy whose content still changes must not fail the run, got $RC: $OUT"
    assert_class locked WAITING
    assert_contains "$OUT" "content changing" "run $run: the WAITING reason is missing"
    assert_contains "$OUT" "summary: WAITING=1" "run $run: the changing copy is not counted as waiting"
    assert_contains "$OUT" "summary: HELD-LOCKED=0" "run $run: a copy whose content still changes was held"
    assert_equals 1 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "run $run: the driver was called for a copy whose content still changes"
    assert_equals 1 "$(preserved_unique | grep -c .)" "run $run: a copy whose content still changes was preserved again"
    assert_equals 'v0' "$(cat "$(preserved_unique)")" "run $run: the preserve of the old content changed"
    registered locked || fail "run $run: a copy whose content still changes was removed"
  done
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the first quiet run failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "the first quiet run did not release the copy"
  ! registered locked || fail "the copy is still registered after the quiet run"
  assert_equals 3 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "the quiet run did not plan and execute exactly once"
  assert_equals 2 "$(preserved_unique | grep -c .)" "the quiet run did not preserve exactly once"
  assert_equals "v0"$'\n'"v4" "$(preserved_unique | while IFS= read -r kept; do cat "$kept"; done | sort)" \
    "the preserve of the old content or of the quiet content is missing"
  [ -z "$(ls -A "$HOMED/data/copy-sweep/waiting" 2>/dev/null)" ] || fail "the release left its waiting record"
  make_locked_copy_case waiting-revert dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'v0\n' > "$(copy_path locked)/unique.dat"
  real_cp=$(command -v cp)
  cat > "$FAKEBIN/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf 'v1\\n' > "$(copy_path locked)/unique.dat"
SH
  chmod +x "$FAKEBIN/cp"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "revert: a write during preservation should exit 1, got $RC: $OUT"
  rm -f "$FAKEBIN/cp"
  printf 'v0\n' > "$(copy_path locked)/unique.dat"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "revert: the run that saw the content change back failed ($RC): $OUT"
  assert_class locked WAITING
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "revert: the quiet run failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "revert: the quiet run did not release the copy"
  line=$(printf '%s\n' "$OUT" | grep -F "REMOVED"$'\t'"$(copy_path locked)")
  assert_contains "$line" "preserved - GiB (preserved in an earlier run), net freed - GiB, unmeasured" \
    "revert: the release counted the bytes its earlier preserve still holds as freed"
  assert_contains "$OUT" "sizes: 0 scanned copies unmeasured, 1 removed copies unmeasured" \
    "revert: the release was not disclosed as unmeasured"
  assert_contains "$(printf '%s\n' "$OUT" | tail -n 1)" "reaped=1 freed=0.00" "revert: the final total counted unmeasured bytes as freed"
  assert_contains "$(tail -n 1 "$HOMED/data/copy-sweep.log")" $'\tpreserved_kib=-\t' "revert: the removal log claimed a measured preserve of the release"
  assert_equals 3 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "revert: the quiet run did not plan and execute exactly once"
  assert_equals 1 "$(preserved_unique | grep -c .)" "revert: content that changed back to its preserved bytes was preserved again"
  assert_equals 'v0' "$(cat "$(preserved_unique)")" "revert: the preserve of the original content changed"
  pass "a copy whose preserved content changed after its preservation reports WAITING, never HELD, with no new preserve and no driver call while its content keeps changing across runs; the first run that sees it unchanged preserves once and releases it through the driver, and no preserve is lost; content that changes back to its latest preserve is released without a duplicate preserve"
}

# The third HEAD read of a locked copy in one --apply run is its second proof's,
# after preservation or its reuse and just before the driver's execute: the hook
# appends to the copy's ignored file there, the way a process outside the copy
# would.
test_ignored_content_changed_after_the_last_proof_is_not_released() {
  local reason line kept name
  reason='vernant-session-active owner=launcher:999999 launcher=999999'
  make_world grow-after-proof
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  for name in zgrow c1 c2; do
    add_copy "$name"
    git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path "$name")"
  done
  printf 'v0\n' > "$(copy_path zgrow)/unique.dat"
  cat > "$W/head-hook" <<SH
[ "\$2" = "$(copy_path zgrow)" ] || exit 0
n=\$(( \$(cat "$W/head-count" 2>/dev/null || printf 0) + 1 ))
printf '%s\\n' "\$n" > "$W/head-count"
[ "\$n" = 3 ] || exit 0
printf 'appended\\n' >> "$(copy_path zgrow)/unique.dat"
: > "$W/head-hook-ran"
SH
  FAKE_GIT_HEAD_HOOK="$W/head-hook" FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ -e "$W/head-hook-ran" ] || fail "built: the hook never ran after the second proof"
  [ "$RC" = 1 ] || fail "built: content changed after preservation should exit 1, got $RC: $OUT"
  line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path zgrow)") \
    || fail "built: the changed content was not reported as FAILED: $OUT"
  assert_contains "$line" "changed after it was preserved" "built: the FAILED line did not name the content change"
  assert_contains "$line" "this run's preserve stays" "built: the report did not say the preserve of the old content was kept"
  assert_no_grep "$(copy_path zgrow) --execute-cleanup" "$W/closeout.log" "built: the driver executed after the content changed"
  registered zgrow || fail "built: the changed copy was removed"
  assert_equals "v0"$'\n'"appended" "$(cat "$(copy_path zgrow)/unique.dat")" "built: the copy's changed ignored file was touched"
  assert_equals 'v0' "$(cat "$(preserved_unique)")" "built: the preserve of the old content was lost"
  [ -z "$(ls -A "$HOMED/data/copy-sweep/retained" 2>/dev/null)" ] || fail "built: a retention receipt was written for an execute that never ran"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path c2)" "built: the refusal used the only release slot"
  assert_class c1 DEFERRED
  rm -f "$W/head-count" "$W/head-hook-ran"
  printf 'v0\n' > "$(copy_path zgrow)/unique.dat"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the run that saw the content change back failed ($RC): $OUT"
  assert_class zgrow WAITING
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path c1)" "the deferred clean copy was not released"
  add_copy c3
  git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path c3)"
  FAKE_GIT_HEAD_HOOK="$W/head-hook" FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ -e "$W/head-hook-ran" ] || fail "reused: the hook never ran after the second proof"
  [ "$RC" = 1 ] || fail "reused: content changed after the last proof should exit 1, got $RC: $OUT"
  line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path zgrow)") \
    || fail "reused: the changed content was not reported as FAILED: $OUT"
  assert_contains "$line" "changed after it was preserved" "reused: the FAILED line did not name the content change"
  assert_no_grep "$(copy_path zgrow) --execute-cleanup" "$W/closeout.log" "reused: the driver executed after the content changed"
  registered zgrow || fail "reused: the changed copy was removed"
  assert_equals 1 "$(preserved_unique | grep -c .)" "reused: a run that reused its earlier preserve preserved again"
  assert_equals 'v0' "$(cat "$(preserved_unique)")" "reused: the earlier preserve changed"
  [ -z "$(ls -A "$HOMED/data/copy-sweep/retained" 2>/dev/null)" ] || fail "reused: a retention receipt was written for an execute that never ran"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path c3)" "reused: the refusal used the only release slot"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the quiet run failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path zgrow)" "the quiet run did not release the copy"
  ! registered zgrow || fail "the released copy is still registered"
  assert_equals 2 "$(preserved_unique | grep -c .)" "the quiet run did not preserve the new content exactly once"
  assert_equals "v0"$'\n'"v0,appended" "$(preserved_unique | while IFS= read -r kept; do paste -sd, - < "$kept"; done | sort)" \
    "the preserve of the old content or of the appended content is missing"
  pass "ignored content that changes after the last proof, after a preserve was built or an earlier preserve was reused, stops the release before the driver's execute, uses no release slot and keeps every preserved byte, and a later quiet run preserves the new content once and releases the copy"
}

# A writer outside the copy adds a new ignored file after preservation, at the
# copy's third HEAD read of the run (its second proof's), when the copy had a
# preservable file (existing) or none (empty).
test_a_new_ignored_file_after_preservation_waits_then_releases_once() {
  local shape reason line kept
  reason='vernant-session-active owner=launcher:999999 launcher=999999'
  for shape in existing empty; do
    make_world "add-after-proof-$shape"
    install_driver "$SLOT" "$W"
    printf 'outbox/\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
    add_copy zadd
    git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path zadd)"
    add_copy c1
    git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path c1)"
    if [ "$shape" = existing ]; then
      mkdir -p "$(copy_path zadd)/outbox"
      printf 'a\n' > "$(copy_path zadd)/outbox/a.msg"
    fi
    cat > "$W/head-hook" <<SH
[ "\$2" = "$(copy_path zadd)" ] || exit 0
n=\$(( \$(cat "$W/head-count" 2>/dev/null || printf 0) + 1 ))
printf '%s\\n' "\$n" > "$W/head-count"
[ "\$n" = 3 ] || exit 0
mkdir -p "$(copy_path zadd)/outbox"
printf 'b\\n' > "$(copy_path zadd)/outbox/b.msg"
: > "$W/head-hook-ran"
SH
    FAKE_GIT_HEAD_HOOK="$W/head-hook" FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ -e "$W/head-hook-ran" ] || fail "$shape: the hook never ran after the second proof"
    [ "$RC" = 1 ] || fail "$shape: a file added after preservation should exit 1, got $RC: $OUT"
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path zadd)") \
      || fail "$shape: the added file was not reported as FAILED: $OUT"
    assert_contains "$line" "changed after it was preserved" "$shape: the FAILED line did not name the content change"
    assert_not_contains "$line" "could not be recorded" "$shape: the content fingerprint was not recorded"
    assert_no_grep "$(copy_path zadd) --execute-cleanup" "$W/closeout.log" "$shape: the driver executed after a file was added"
    assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path c1)" "$shape: the refusal used the only release slot"
    registered zadd || fail "$shape: the copy was removed"
    [ -z "$(ls -A "$HOMED/data/copy-sweep/retained" 2>/dev/null)" ] || fail "$shape: a retention receipt was written for an execute that never ran"
    assert_equals 0 "$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -type f -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')" \
      "$shape: the run kept a preserve although every original is still in the copy"
    assert_equals 'b' "$(cat "$(copy_path zadd)/outbox/b.msg")" "$shape: the added file was touched"
    printf 'c\n' > "$(copy_path zadd)/outbox/c.msg"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$shape: a copy whose content still changes must not fail the run, got $RC: $OUT"
    assert_class zadd WAITING
    assert_contains "$OUT" "content changing" "$shape: the WAITING reason is missing"
    assert_equals 0 "$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -type f -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')" \
      "$shape: a copy whose content still changes was preserved"
    assert_equals 1 "$(grep -cFx "$SLOT|--cleanup-worktree $(copy_path zadd)" "$W/closeout.log")" \
      "$shape: the driver was called for a copy whose content still changes"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$shape: the quiet run failed ($RC): $OUT"
    assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path zadd)" "$shape: the quiet run did not release the copy"
    ! registered zadd || fail "$shape: the released copy is still registered"
    assert_equals 1 "$(grep -c -- "$(copy_path zadd) --execute-cleanup" "$W/closeout.log")" "$shape: the quiet run did not execute exactly once"
    kept=$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -type f -name '*.msg' 2>/dev/null | LC_ALL=C sort)
    if [ "$shape" = existing ]; then
      assert_equals "a b c" "$(printf '%s\n' "$kept" | while IFS= read -r f; do cat "$f"; done | tr '\n' ' ' | sed 's/ $//')" \
        "$shape: the quiet run did not preserve every file exactly once"
    else
      assert_equals "b c" "$(printf '%s\n' "$kept" | while IFS= read -r f; do cat "$f"; done | tr '\n' ' ' | sed 's/ $//')" \
        "$shape: the quiet run did not preserve every file exactly once"
    fi
    [ -z "$(ls -A "$HOMED/data/copy-sweep/waiting" 2>/dev/null)" ] || fail "$shape: the release left its waiting record"
  done
  pass "a new ignored file that appears after preservation, with or without an earlier preservable file, stops the release before execute with no release slot and no lost bytes, records the copy's content, so the next run that still sees it changing reports WAITING with no preserve and no driver call, and the first quiet run preserves once and releases the copy"
}

test_a_fifo_and_a_stale_socket_neither_block_release_nor_accumulate_preserves() {
  local run kept
  make_locked_copy_case special-entries dead
  install_driver "$SLOT" "$W"
  printf 'outbox/\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$(copy_path locked)/outbox"
  printf 'log line\n' > "$(copy_path locked)/outbox/channel.log"
  mkfifo "$(copy_path locked)/outbox/pipe"
  (cd "$(copy_path locked)/outbox" && python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("stale.sock")')
  [ -S "$(copy_path locked)/outbox/stale.sock" ] || fail "the fixture socket was not created"
  printf '{"allowed": false, "reason": "cleanup_lease_conflict"}\n' > "$W/execute-output"
  for run in 1 2; do
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 1 ] || fail "run $run: a temporary refusal should exit 1, got $RC: $OUT"
    assert_not_contains "$OUT" "could not be compared" "run $run: a FIFO or a socket made the content uncomparable"
    assert_equals "$run" "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "run $run: the driver's execute was not reached"
    assert_contains "$OUT" "no preserve from this run is kept" "run $run: the run's preserve was not discarded"
    assert_equals 0 "$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name channel.log 2>/dev/null | wc -l | tr -d ' ')" \
      "run $run: a quiet copy accumulated a preserve"
    [ -z "$(ls -A "$HOMED/data/copy-sweep/waiting" 2>/dev/null)" ] || fail "run $run: a quiet copy got a waiting record"
    registered locked || fail "run $run: a refused copy was removed"
  done
  rm -f "$W/execute-output"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the allowed run failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "the allowed run did not release the copy"
  ! registered locked || fail "the released copy is still registered"
  kept=$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name channel.log -type f 2>/dev/null)
  assert_equals 1 "$(printf '%s\n' "$kept" | grep -c .)" "the release did not leave exactly one preserve"
  assert_equals 'log line' "$(cat "$kept")" "the preserved log changed"
  [ -p "${kept%/*}/pipe" ] || fail "the preserve does not hold the FIFO"
  pass "a preservable ignored directory holding a FIFO and a stale socket is compared as preservation copies it: temporary refusals discard each run's preserve with no waiting record, so preserves never accumulate, and the allowed run preserves once and releases the copy"
}

test_a_receipt_that_cannot_be_written_keeps_no_preserve_and_retries() {
  local run line
  make_locked_copy_case receipt-unwritable dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  mkdir -p "$HOMED/data/copy-sweep"
  : > "$HOMED/data/copy-sweep/retained"
  for run in 1 2; do
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 1 ] || fail "run $run: a receipt that cannot be written should exit 1, got $RC: $OUT"
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
      || fail "run $run: the refusal was not reported as FAILED: $OUT"
    assert_contains "$line" "cannot record the driver release" "run $run: the receipt failure was not named"
    assert_contains "$line" "no preserve from this run is kept" "run $run: the report did not say this run's preserve was discarded"
    assert_contains "$line" "next sweep run plans it again" "run $run: the report did not say the copy is retried"
    assert_equals '' "$(preserved_unique)" "run $run: a refusal before execute left this run's preserve behind"
    assert_equals 0 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "run $run: the driver executed without a receipt"
    assert_equals 'durable state' "$(cat "$(copy_path locked)/unique.dat")" "run $run: the copy's original ignored file changed"
    registered locked || fail "run $run: the copy is no longer registered"
  done
  rm -f "$HOMED/data/copy-sweep/retained"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the run with a writable receipt failed ($RC): $OUT"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "the run with a writable receipt did not release the copy"
  assert_equals 1 "$(preserved_unique | grep -c .)" "the release did not leave exactly one preserve"
  assert_equals 'durable state' "$(cat "$(preserved_unique)")" "the released copy's preserve changed"
  pass "a driver-retention receipt that cannot be written before execute stops the release, discards that run's preserve while the copy still holds its lock and originals, so repeated refusals add no preserve, and the next run that can write it preserves once and releases the copy"
}

# complete_retained_fields <copy>: the key lines bin/fm-teardown.sh writes into a complete
# retained record for <copy> as the copy is now: its HEAD, status and ignored-payload
# fingerprints (read through the nested library's own snapshot, as the record writer does)
# and the identity of its creation-lock file. A complete record is valid only while these
# still describe the copy, so a fixture of a matching record carries the real values.
complete_retained_fields() {  # <copy>
  local copy=$1
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-teardown-nested-lib.sh"
    teardown_retained_snapshot "$copy" || exit 1
    printf 'head=%s\nstatus-sha256=%s\npayload-sha256=%s\n' "$TEARDOWN_RET_HEAD" "$TEARDOWN_RET_STATUS" "$TEARDOWN_RET_PAYLOAD"
  ) || return 1
}

# The record bin/fm-teardown.sh writes when it closes a task around an own copy
# the driver kept is this sweep's receipt in its complete form: the same first
# four lines plus key=value lines. The sweep neither executes, preserves nor
# removes that copy while the record matches, and clears the record once the copy
# is gone.
test_a_teardown_retained_record_protects_the_copy_and_is_cleared_with_it() {
  local copy admin hash record identity lock before line calls
  make_locked_copy_case teardown-record dead
  install_driver "$SLOT" "$W"
  copy=$(copy_path locked)
  admin=$(git -C "$copy" rev-parse --absolute-git-dir)
  lock=$(shasum -a 256 "$admin/locked" | awk '{print $1}')
  if [ "$(uname)" = Darwin ]; then identity=$(/usr/bin/stat -f %i:%B "$copy/.git"); else identity=$(stat -c %i:%W "$copy/.git"); fi
  hash=$(printf '%s' "$copy" | shasum -a 256 | awk '{print $1}')
  record="$HOMED/data/copy-sweep/retained/$hash"
  mkdir -p "${record%/*}"
  {
    printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$lock" "$copy" "$identity"
    printf 'the closeout driver kept this copy (exit 3, cleanup_ignored_payload_archived_tree_retained) for task t\n'
    printf 'task=t\nslot=%s\nreason=cleanup_ignored_payload_archived_tree_retained\nrecorded-at=2026-11-03T00:00:00Z\n' "$SLOT"
    complete_retained_fields "$copy" || fail "the fixture record's fields could not be read"
  } > "$record"
  before=$(shasum -a 256 "$record")
  snap "$copy" > "$W/copy.before"
  for mode in report apply apply; do
    if [ "$mode" = report ]; then run_sweep; else FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply; fi
    [ "$RC" = 0 ] || fail "$mode: the run failed ($RC): $OUT"
    assert_class locked HELD-LOCKED
    line=$(printf '%s\n' "$OUT" | grep -F "$copy" | head -n 1)
    assert_contains "$line" "driver retained this copy: the closeout driver kept this copy (exit 3, cleanup_ignored_payload_archived_tree_retained)" "$mode: the held reason did not show the record's sentence"
    assert_not_contains "$line" "payload-sha256" "$mode: the held reason leaked the record's key lines"
    calls=0
    [ ! -e "$W/closeout.log" ] || calls=$(wc -l < "$W/closeout.log" | tr -d ' ')
    assert_equals 0 "$calls" "$mode: the sweep asked the driver about a copy the record keeps"
    assert_equals "$before" "$(shasum -a 256 "$record")" "$mode: the sweep rewrote the teardown record"
    snap "$copy" | cmp -s - "$W/copy.before" || fail "$mode: the sweep changed the kept copy"
    registered locked || fail "$mode: the kept copy is no longer registered"
  done
  git -C "$SLOT" worktree unlock "$copy"
  git -C "$SLOT" worktree remove --force "$copy"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the run after the copy was removed failed ($RC): $OUT"
  assert_contains "$OUT" "RECEIPT-CLEARED" "a record for a copy that is gone was not cleared"
  [ ! -e "$record" ] || fail "a record for a copy that is gone survived"
  pass "a teardown-written retained record keeps the sweep from executing, preserving or removing the copy, shows one line as the hold reason, and is cleared with the copy"
}

# F7 (round 4): a complete retained record holds the copy only while it still describes
# it: its HEAD, its status, its ignored payload and its creation lock are part of the
# answer. After a changed ignored payload, after a new pushed commit, and after the creation
# lock is replaced by a new file with the same bytes (F5), the report form no longer shows
# the record's hold and writes nothing, and the --apply form assesses the copy afresh (the
# payload and lock cases reach the driver). Controls: the unchanged copy is held by
# both forms with no driver call; a record that cannot be read, and a payload that cannot
# be read, still hold the copy and the driver is not asked.
test_a_teardown_retained_record_keeps_holding_a_changed_copy_until_its_lock_or_copy_changes() {
  local copy hash record calls kind line before admin
  for kind in payload head lock-file unreadable-record unreadable-payload lock-bytes; do
    make_locked_copy_case "teardown-record-changed-$kind" dead
    install_driver "$SLOT" "$W"
    copy=$(copy_path locked)
    printf 'unique.dat\n' >> "$(git -C "$copy" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'first payload\n' > "$copy/unique.dat"
    hash=$(printf '%s' "$copy" | shasum -a 256 | awk '{print $1}')
    record="$HOMED/data/copy-sweep/retained/$hash"
    mkdir -p "${record%/*}"
    {
      printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$(shasum -a 256 "$(git -C "$copy" rev-parse --absolute-git-dir)/locked" | awk '{print $1}')" "$copy" \
        "$(if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %i:%B "$copy/.git"; else stat -c %i:%W "$copy/.git"; fi)"
      printf 'the closeout driver kept this copy (exit 3, cleanup_ignored_payload_archived_tree_retained) for task t\n'
      printf 'task=t\nslot=%s\nreason=cleanup_ignored_payload_archived_tree_retained\nrecorded-at=2026-11-03T00:00:00Z\n' "$SLOT"
      complete_retained_fields "$copy" || fail "$kind: the fixture record's fields could not be read"
    } > "$record"
    for mode in report apply; do
      if [ "$mode" = report ]; then run_sweep; else FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply; fi
      assert_class locked HELD-LOCKED
      assert_contains "$(printf '%s\n' "$OUT" | grep -F "$copy" | head -n 1)" "driver retained this copy" "$kind unchanged $mode: the matching record did not hold the copy"
    done
    case "$kind" in
      payload) printf 'second payload\n' > "$copy/unique.dat" ;;
      head)
        git -C "$copy" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
        git -C "$copy" push -q origin "fm/locked"
        ;;
      lock-file)
        # The creation lock replaced by a new file with the same bytes: the same lock bytes.
        admin=$(git -C "$copy" rev-parse --absolute-git-dir)
        cp -p "$admin/locked" "$admin/locked.new"
        mv -f "$admin/locked.new" "$admin/locked"
        ;;
      unreadable-record) chmod 000 "$record" ;;
      unreadable-payload) chmod 000 "$copy/unique.dat" ;;
      lock-bytes)
        # The control: a different creation lock makes the record stale.
        admin=$(git -C "$copy" rev-parse --absolute-git-dir)
        printf '%s 1\n' "$(cat "$admin/locked")" > "$admin/locked"
        ;;
    esac
    before=$(perl -e 'printf "%o", (lstat $ARGV[0])[2]' "$record")$(cat "$record" 2>/dev/null | shasum -a 256)
    run_sweep
    line=$(printf '%s\n' "$OUT" | grep -F "$copy" | head -n 1)
    assert_equals "$before" "$(perl -e 'printf "%o", (lstat $ARGV[0])[2]' "$record")$(cat "$record" 2>/dev/null | shasum -a 256)" "$kind changed report: the report form wrote or cleared the record"
    case "$kind" in
      lock-bytes)
        assert_not_contains "$line" "driver retained this copy" "$kind changed report: a record of another lock still held the copy: $line"
        FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
        assert_contains "$OUT" "RECEIPT-CLEARED" "$kind changed apply: the stale record was not cleared"
        ;;
      *)
        assert_class locked HELD-LOCKED
        assert_contains "$line" "driver retained this copy" "$kind changed report: the record stopped holding a copy whose lock and identity it still describes: $line"
        FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
        assert_class locked HELD-LOCKED
        [ -e "$record" ] || fail "$kind changed apply: --apply cleared the record of a copy that is still kept"
        calls=0
        [ ! -e "$W/closeout.log" ] || calls=$(wc -l < "$W/closeout.log" | tr -d ' ')
        assert_equals 0 "$calls" "$kind changed: the sweep asked the driver about a copy its record still holds"
        chmod 644 "$record" "$copy/unique.dat" 2>/dev/null || true
        ;;
    esac
  done
  pass "a teardown-written retained record keeps holding its copy after its payload, HEAD or lock file changes and while it or the payload cannot be read (no driver call, never cleared by --apply), and goes stale only once the copy's creation lock bytes differ"
}

# A lane home wrote the retained record (it closed its task around the kept copy in
# the shared pool); a sweep run from another home must not ask the driver for the
# copy again, must not write, clear or claim the lane's record, and holds the copy
# when the lane's records cannot be read.
xhome_record() {  # <copy> <record-path>
  local copy=$1 record=$2 admin lock identity
  admin=$(git -C "$copy" rev-parse --absolute-git-dir)
  lock=$(shasum -a 256 "$admin/locked" | awk '{print $1}')
  if [ "$(uname)" = Darwin ]; then identity=$(/usr/bin/stat -f %i:%B "$copy/.git"); else identity=$(stat -c %i:%W "$copy/.git"); fi
  mkdir -p "${record%/*}"
  {
    printf 'lock-sha256=%s\ncopy=%s\nidentity=%s\n' "$lock" "$copy" "$identity"
    printf 'the closeout driver kept this copy (exit 3, cleanup_ignored_payload_archived_tree_retained) for task t\n'
    printf 'task=t\nslot=%s\nreason=cleanup_ignored_payload_archived_tree_retained\nrecorded-at=2026-11-03T00:00:00Z\n' "$SLOT"
    complete_retained_fields "$copy" || fail "the fixture record's fields could not be read"
  } > "$record"
}

test_a_sweep_from_another_home_does_not_ask_the_driver_for_a_copy_a_lane_record_holds() {
  local copy hash record before mode line calls
  make_locked_copy_case xhome-record dead
  install_driver "$SLOT" "$W"
  make_lane l1
  copy=$(copy_path locked)
  hash=$(printf '%s' "$copy" | shasum -a 256 | awk '{print $1}')
  # Control: with no record anywhere the copy goes to the driver as before.
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep
  [ "$RC" = 0 ] || fail "control report failed ($RC): $OUT"
  assert_class locked PENDING-DRIVER
  record="$W/lane-l1/data/copy-sweep/retained/$hash"
  xhome_record "$copy" "$record"
  before=$(shasum -a 256 "$record")
  snap "$copy" > "$W/copy.before"
  for mode in report apply apply; do
    if [ "$mode" = report ]; then FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep; else FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply; fi
    [ "$RC" = 0 ] || fail "$mode: the run failed ($RC): $OUT"
    assert_class locked HELD-LOCKED
    line=$(printf '%s\n' "$OUT" | grep -F "$copy" | head -n 1)
    assert_contains "$line" "recorded by another local home" "$mode: the hold reason did not name the other home's record"
    calls=0
    [ ! -e "$W/closeout.log" ] || calls=$(wc -l < "$W/closeout.log" | tr -d ' ')
    assert_equals 0 "$calls" "$mode: the sweep asked the driver about a copy another home's record keeps"
    assert_equals "$before" "$(shasum -a 256 "$record")" "$mode: the sweep rewrote the lane's record"
    [ ! -e "$HOMED/data/copy-sweep/retained/$hash" ] || fail "$mode: the sweep wrote a competing record of its own"
    snap "$copy" | cmp -s - "$W/copy.before" || fail "$mode: the sweep changed the kept copy"
  done
  # The lane's record holds by the receipt rules: a new pushed commit does not end the hold
  # (the copy and its lock are the same), and the sweep still never writes, clears or claims
  # the lane's record.
  git -C "$copy" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
  git -C "$copy" push -q origin "fm/locked"
  for mode in report apply; do
    if [ "$mode" = report ]; then FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep; else FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply; fi
    line=$(printf '%s\n' "$OUT" | grep -F "$copy" | head -n 1)
    assert_contains "$line" "recorded by another local home" "changed $mode: the lane's record stopped holding a copy it still describes: $line"
    calls=0
    [ ! -e "$W/closeout.log" ] || calls=$(wc -l < "$W/closeout.log" | tr -d ' ')
    assert_equals 0 "$calls" "changed $mode: the sweep asked the driver about a copy another home's record keeps"
    assert_equals "$before" "$(shasum -a 256 "$record")" "changed $mode: the sweep wrote or cleared the lane's record"
  done
  pass "a sweep run from another home holds a copy a lane's retained record keeps, also after the copy's HEAD moved: no driver call, no write to the lane's record, no competing record"
}

test_a_sweep_holds_a_copy_when_another_homes_records_cannot_be_read() {
  local copy mode calls
  for mode in unreadable-folder unsearchable-data skipped-home searchable-unreadable-retained searchable-unreadable-folder searchable-unreadable-data; do
    make_locked_copy_case "xhome-$mode" dead
    install_driver "$SLOT" "$W"
    make_lane l1
    copy=$(copy_path locked)
    case "$mode" in
      unreadable-folder) mkdir -p "$W/lane-l1/data/copy-sweep/retained"; chmod 000 "$W/lane-l1/data/copy-sweep/retained" ;;
      unsearchable-data) mkdir -p "$W/lane-l1/data/copy-sweep/retained"; chmod 000 "$W/lane-l1/data" ;;
      skipped-home) rm -rf "$W/lane-l1" ;;
      # Searchable but not readable: the directory lists as empty, so its records are unknown.
      searchable-unreadable-retained) mkdir -p "$W/lane-l1/data/copy-sweep/retained"; chmod 111 "$W/lane-l1/data/copy-sweep/retained" ;;
      searchable-unreadable-folder) mkdir -p "$W/lane-l1/data/copy-sweep/retained"; chmod 111 "$W/lane-l1/data/copy-sweep" ;;
      searchable-unreadable-data) mkdir -p "$W/lane-l1/data/copy-sweep/retained"; chmod 111 "$W/lane-l1/data" ;;
    esac
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    chmod 755 "$W/lane-l1/data" 2>/dev/null || true
    chmod 755 "$W/lane-l1/data/copy-sweep" 2>/dev/null || true
    chmod 755 "$W/lane-l1/data/copy-sweep/retained" 2>/dev/null || true
    [ "$RC" = 0 ] || fail "$mode: the run failed ($RC): $OUT"
    assert_class locked HELD-LOCKED
    calls=0
    [ ! -e "$W/closeout.log" ] || calls=$(wc -l < "$W/closeout.log" | tr -d ' ')
    assert_equals 0 "$calls" "$mode: the sweep asked the driver when another home's records were unknown"
    registered locked || fail "$mode: the copy is no longer registered"
  done
  pass "a sweep holds a locked copy and asks the driver nothing when another home's retained records, or the home itself, cannot be read"
}

# A receipt is cleared only when its copy is positively gone (the kernel says it does not
# exist). A copy that cannot be looked up because a directory above it cannot be searched is
# unknown, not gone: its receipt stays, and is still there when the access is restored.
test_a_receipt_survives_while_its_copy_cannot_be_looked_up_and_is_cleared_only_when_it_is_gone() {
  local copy hash record parent
  [ "$(id -u)" != 0 ] || { pass "skipped as root: a directory permission does not stop root"; return 0; }
  make_locked_copy_case receipt-unobservable dead
  install_driver "$SLOT" "$W"
  copy=$(copy_path locked)
  hash=$(printf '%s' "$copy" | shasum -a 256 | awk '{print $1}')
  record="$HOMED/data/copy-sweep/retained/$hash"
  xhome_record "$copy" "$record"
  parent=$(dirname "$copy")
  chmod 000 "$parent"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  chmod 755 "$parent"
  assert_not_contains "$OUT" "RECEIPT-CLEARED" "a receipt was cleared while its copy could not be looked up"
  [ -e "$record" ] || fail "the receipt of a copy that could not be looked up was removed"
  [ -e "$copy" ] || fail "the copy is gone after the access was restored"
  # Control: once the copy really is gone the apply clears the receipt.
  git -C "$SLOT" worktree unlock "$copy"
  git -C "$SLOT" worktree remove --force "$copy"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  assert_contains "$OUT" "RECEIPT-CLEARED" "the receipt of a copy that is gone was not cleared"
  [ ! -e "$record" ] || fail "the receipt of a copy that is gone survived"
  pass "a retained receipt survives while its copy cannot be looked up and is cleared only once the copy is positively gone"
}

test_a_long_sorted_key_refusal_still_shows_the_drivers_reason() {
  local shape reason long line retained
  for shape in kept failed; do
    if [ "$shape" = kept ]; then reason=cleanup_ignored_payload_archived_tree_retained; else reason=cleanup_policy_not_allowed; fi
    make_locked_copy_case "long-reason-$shape" dead
    install_driver "$SLOT" "$W"
    retained="$HOMED/data/copy-sweep/retained"
    long=$(head -c 700 /dev/zero | tr '\0' x)
    printf '{"allowed": false, "cleanup_command": ["%s", "TAIL-MARKER-NOT-SHOWN"], "reason": "%s"}\n' "$long" "$reason" > "$W/plan-output"
    printf '3\n' > "$W/plan-exit"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$shape: a refused long plan failed the run ($RC): $OUT"
    assert_class locked HELD-LOCKED
    assert_contains "$OUT" "$reason: {\"allowed\": false" "$shape: the plan's reason did not come first"
    assert_not_contains "$OUT" "TAIL-MARKER-NOT-SHOWN" "$shape: the plan's text was not capped"
    rm -f "$W/plan-output" "$W/plan-exit"
    printf '{"allowed": false, "cleanup_command": ["%s", "TAIL-MARKER-NOT-SHOWN"], "reason": "%s"}\n' "$long" "$reason" > "$W/execute-output"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    if [ "$shape" = kept ]; then
      [ "$RC" = 0 ] || fail "$shape: a retained refusal failed the run ($RC): $OUT"
      line=$(printf '%s\n' "$OUT" | grep -F "KEPT"$'\t'"$(copy_path locked)") || fail "$shape: the retention was not reported as KEPT: $OUT"
    else
      [ "$RC" = 1 ] || fail "$shape: a refused execute should exit 1, got $RC: $OUT"
      line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") || fail "$shape: the refusal was not reported as FAILED: $OUT"
    fi
    assert_contains "$line" "(exit 3): $reason: {\"allowed\": false" "$shape: the execute reason did not come first"
    assert_not_contains "$line" "TAIL-MARKER-NOT-SHOWN" "$shape: the execute text was not capped"
    grep -rqF "exit 3: $reason: {\"allowed\": false" "$retained" || fail "$shape: the retention receipt lost the driver's reason"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$shape: the held rerun failed ($RC): $OUT"
    assert_class locked HELD-LOCKED
    assert_contains "$OUT" "driver retained this copy: exit 3: $reason: {" "$shape: the held reason lost the driver's reason"
    registered locked || fail "$shape: the refused copy is no longer registered"
  done
  pass "a driver answer whose sorted keys put its reason past 600 characters still shows that reason first in the plan hold, the KEPT or FAILED line, the receipt and the later held reason"
}

test_a_failed_preservation_is_the_sweeps_own_human_only_refusal() {
  local admin line
  make_locked_copy_case preservefailed dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'durable state\n' > "$(copy_path locked)/unique.dat"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/cp"
  chmod +x "$FAKEBIN/cp"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a failed preservation should exit 1, got $RC: $OUT"
  line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
    || fail "the failed preservation was not reported as FAILED: $OUT"
  assert_contains "$line" "could not be preserved" "the FAILED line did not say what failed"
  assert_contains "$line" "human-only-exit: " "the failed preservation did not end in a human-only question"
  assert_contains "$line" "The next sweep run tries again" "the FAILED line did not say what happens next"
  assert_not_contains "$OUT" "completing-command:" "a sweep refusal printed a command"
  assert_not_contains "$OUT" "fm-teardown.sh" "a sweep refusal named a teardown command built from its release id"
  assert_not_contains "$OUT" "FM_FRICTION_OPERATION_ID" "a sweep refusal printed a friction-correlated route"
  assert_not_contains "$OUT" "REMOVED" "a copy whose preservation failed was reported removed"
  assert_absent "$HOMED/state/friction.jsonl" "a sweep refusal wrote a friction event under its synthetic release id"
  [ -e "$(copy_path locked)" ] || fail "a copy whose preservation failed was removed"
  registered locked || fail "a copy whose preservation failed is no longer registered"
  [ -f "$admin/locked" ] || fail "a copy whose preservation failed lost its lock"
  assert_equals 'durable state' "$(cat "$(copy_path locked)/unique.dat")" "the ignored file changed"
  [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "a copy whose preservation failed was logged as removed"
  assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
    "the driver was asked for more than its plan"
  pass "a copy whose ignored files cannot be preserved stays locked and registered, the sweep's own FAILED line ends in a human-only question with no command and no friction event, and the run exits 1"
}

test_a_failed_preservation_leaves_no_staging_directory() {
  local admin n real_cp
  make_locked_copy_case stagefailed dead
  install_driver "$SLOT" "$W"
  printf 'good.dat\nunreadable.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'copied before the failure\n' > "$(copy_path locked)/good.dat"
  printf 'cannot be copied\n' > "$(copy_path locked)/unreadable.dat"
  real_cp=$(command -v cp)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\ncase "$*" in *unreadable.dat*) exit 1 ;; esac\nexec %q "$@"\n' "$W/cp.log" "$real_cp" > "$FAKEBIN/cp"
  chmod +x "$FAKEBIN/cp"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  for n in 1 2; do
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 1 ] || fail "failed preservation $n should exit 1, got $RC: $OUT"
    assert_contains "$OUT" "could not be preserved" "run $n did not report the failed preservation"
    assert_equals "$n" "$(grep -c 'good.dat' "$W/cp.log")" "run $n did not copy the readable file before it failed"
    assert_equals "$n" "$(grep -c 'unreadable.dat' "$W/cp.log")" "run $n did not reach the unreadable file"
    assert_equals 0 "$(find "$HOMED/data/copy-sweep" -name '.staging-*' 2>/dev/null | wc -l | tr -d ' ')" \
      "failed preservation $n left a staging directory behind"
  done
  [ -e "$(copy_path locked)" ] || fail "a copy whose preservation failed was removed"
  registered locked || fail "a copy whose preservation failed is no longer registered"
  [ -f "$admin/locked" ] || fail "a copy whose preservation failed lost its lock"
  assert_equals 'copied before the failure' "$(cat "$(copy_path locked)/good.dat")" "the readable ignored file changed"
  assert_equals 'cannot be copied' "$(cat "$(copy_path locked)/unreadable.dat")" "the unreadable ignored file changed"
  assert_not_contains "$(cat "$W/closeout.log")" "--execute-cleanup" "the driver executed after a failed preservation"
  pass "a failed preservation removes the staging directory it built, so repeated failed sweeps leave no staging bytes behind"
}

test_a_lock_that_stops_being_vernants_after_the_plan_is_not_released() {
  local admin line
  make_locked_copy_case relocked dead
  install_driver "$SLOT" "$W"
  : > "$W/plan-relock"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a lock that changed after its plan should exit 1, got $RC: $OUT"
  line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
    || fail "the changed lock was not reported as FAILED: $OUT"
  assert_contains "$line" "not the supported Vernant creation-lock format" "the FAILED line did not name the changed lock"
  assert_not_contains "$OUT" "completing-command:" "a sweep refusal printed a command"
  assert_not_contains "$OUT" "REMOVED" "a copy whose lock changed was reported removed"
  [ -e "$(copy_path locked)" ] || fail "a copy whose lock changed was removed"
  registered locked || fail "a copy whose lock changed is no longer registered"
  assert_equals 'hand-held by an operator' "$(cat "$admin/locked")" "the sweep touched the lock someone else took"
  assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
    "the driver was asked to release a copy whose lock was no longer Vernant's"
  pass "a copy whose creation lock became someone else's after its plan stays locked, is not released by the driver, and is reported as the sweep's own refusal"
}

test_ownership_or_lock_change_during_preservation_prevents_release() {
  local shape admin before real_cp line
  real_cp=$(command -v cp)
  for shape in owner owner-delete owner-overwrite lock; do
    make_locked_copy_case "preserve-change-$shape" dead
    install_driver "$SLOT" "$W"
    printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'durable state\n' > "$(copy_path locked)/unique.dat"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    if [ "$shape" = lock ]; then
      printf 'printf "vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=999999\\n" > %q\n' "$admin/locked" > "$W/cp-hook"
    else
      printf 'printf "worktree=%%s\\nkind=ship\\n" %q > %q\n' "$(copy_path locked)" "$HOMED/state/late-owner.meta" > "$W/cp-hook"
    fi
    case "$shape" in
      owner-delete) printf 'rm -f %q\n' "$(copy_path locked)/unique.dat" >> "$W/cp-hook" ;;
      owner-overwrite) printf 'printf "new owner state\\n" > %q\n' "$(copy_path locked)/unique.dat" >> "$W/cp-hook" ;;
    esac
    cat > "$FAKEBIN/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
if [ ! -e "$W/cp-hook-ran" ]; then
  : > "$W/cp-hook-ran"
  bash "$W/cp-hook"
fi
SH
    chmod +x "$FAKEBIN/cp"
    before=$(shasum -a 256 "$admin/locked")
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ -e "$W/cp-hook-ran" ] || fail "$shape: preservation never copied, so the proof after it was not exercised"
    [ "$RC" = 1 ] || fail "$shape: a change during preservation should exit 1, got $RC: $OUT"
    line=$(printf '%s\n' "$OUT" | grep -F "FAILED"$'\t'"$(copy_path locked)") \
      || fail "$shape: the change during preservation was not reported as FAILED: $OUT"
    assert_contains "$line" "the copy was left" "$shape: the FAILED line did not say the copy was left"
    if [ "$shape" != lock ]; then
      assert_contains "$line" "late-owner's active record" "the task record that appeared during preservation was not named"
      assert_contains "$line" "no longer proven" "the FAILED line did not say the copy is no longer proven"
      assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "the sweep changed the lock of a copy a task claimed"
    else
      assert_contains "$line" "changed HEAD or creation-lock bytes" "the lock that replaced the original during preservation was not detected"
      assert_equals 'vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=999999' "$(cat "$admin/locked")" \
        "the sweep changed the lock that replaced the original"
    fi
    assert_not_contains "$OUT" "REMOVED" "$shape: a copy that changed during preservation was reported removed"
    registered locked || fail "$shape: a copy that changed during preservation is no longer registered"
    [ -f "$admin/locked" ] || fail "$shape: a copy that changed during preservation lost its lock"
    case "$shape" in
      owner-delete) [ ! -e "$(copy_path locked)/unique.dat" ] || fail "owner-delete: the owner's deletion was undone" ;;
      owner-overwrite) assert_equals 'new owner state' "$(cat "$(copy_path locked)/unique.dat")" "owner-overwrite: the owner's write was undone" ;;
      *) assert_equals 'durable state' "$(cat "$(copy_path locked)/unique.dat")" "$shape: the ignored file changed" ;;
    esac
    assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
      "$shape: the driver was asked for more than its plan"
    assert_equals 0 "$(find "$HOMED/data/copy-sweep/retained" -type f 2>/dev/null | wc -l | tr -d ' ')" \
      "$shape: a retention receipt was written for a release that never ran"
    case "$shape" in
      owner) assert_equals '' "$(preserved_unique)" "owner: a proof that failed while the copy kept its lock and originals left this run's preserve behind" ;;
      lock) assert_equals 'durable state' "$(cat "$(preserved_unique)")" "lock: the preserve of a copy whose lock changed was discarded" ;;
      *) assert_equals 'durable state' "$(cat "$(preserved_unique)")" "$shape: the preserve was discarded although the copy no longer holds the original" ;;
    esac
    [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "$shape: a copy that changed during preservation was logged as removed"
    if [ "$shape" = lock ]; then
      assert_contains "$line" "because the copy's identity or creation-lock bytes changed" "lock: the kept preserve did not name the changed lock as its cause"
      FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
      [ "$RC" = 0 ] || fail "lock: the later quiet run failed ($RC): $OUT"
      assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "lock: the later quiet run did not release the copy"
      assert_equals 1 "$(preserved_unique | grep -c .)" "lock: the later quiet run preserved the bytes its latest preserve already holds"
      assert_equals 1 "$(grep -c -- '--execute-cleanup' "$W/closeout.log")" "lock: the later quiet run did not call the driver's release exactly once"
    fi
  done
  pass "a task record or a different valid lock appearing during preservation stops the release after the copy, with no execute and no receipt; this run's preserve is discarded only while the copy keeps the plan's lock and every preserved original unchanged, and a later quiet run whose content equals that kept preserve releases the copy through the driver without preserving it again"
}

test_retained_ignored_payload_is_kept_once_without_growth() {
  local admin before first n
  make_locked_copy_case retained-ignored dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'unique retained bytes\n' > "$(copy_path locked)/unique.dat"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  : > "$W/retain-ignored"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "a driver-retained ignored payload must not fail the sweep: $OUT"
  assert_contains "$OUT" "KEPT"$'\t'"$(copy_path locked)" "retention was not reported as KEPT"
  assert_contains "$OUT" "cleanup_ignored_payload_archived_tree_retained" "the driver's retention reason was lost"
  first=$(snap "$HOMED/data/copy-sweep")
  for n in 2 3; do
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "retained rerun $n failed: $OUT"
    assert_class locked HELD-LOCKED
    assert_equals "$first" "$(snap "$HOMED/data/copy-sweep")" "rerun $n changed or grew preservation"
    assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "retention changed the lock"
    registered locked || fail "retained copy was unregistered"
  done
  assert_equals 2 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "retained copy was driven again"
  assert_equals 'unique retained bytes' "$(cat "$(copy_path locked)/unique.dat")" "retention lost source bytes"
  pass "exit-3 ignored-payload retention is KEPT, keeps its lock and source, and repeated sweeps neither preserve nor execute again"
}

test_task_record_appearing_during_plan_prevents_release() {
  local admin before
  make_locked_copy_case plan-new-owner dead
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  printf "printf \"worktree=%%s\\\\nkind=ship\\\\n\" \"\$1\" > %q\n" "$HOMED/state/new-owner.meta" > "$W/plan-hook"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a changed proof was not reported: $OUT"
  assert_contains "$OUT" "new-owner's active record" "post-plan owner was not named"
  registered locked || fail "copy newly claimed during planning was removed"
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "new owner's lock changed"
  assert_equals 1 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "execute ran after ownership changed"
  assert_absent "$HOMED/data/copy-sweep" "changed ownership was checked only after preservation"
  pass "a task record appearing during the driver plan prevents preservation and release"
}

test_valid_lock_replacement_during_plan_prevents_release() {
  local admin
  make_locked_copy_case plan-new-lock dead
  install_driver "$SLOT" "$W"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  printf 'printf "vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=999999\\n" > %q\n' "$admin/locked" > "$W/plan-hook"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "a replaced creation lock was not reported: $OUT"
  assert_contains "$OUT" "changed HEAD or creation-lock bytes" "valid replacement was not detected"
  assert_equals 'vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=999999' "$(cat "$admin/locked")" "replacement lock was changed by sweep"
  registered locked || fail "a different valid lock was released"
  assert_equals 1 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "execute ran on a different lock"
  pass "a different but valid Vernant lock appearing during the plan is never released"
}

test_extra_lock_lines_are_held_byte_identical() {
  local reason admin before n=0
  for reason in $'vernant-session-active owner=launcher:999999 launcher=999999\noperator hold' \
      $'vernant-session-active owner=launcher:999999 launcher=999999\n'; do
    n=$((n + 1))
    make_world "malformed-lock-$n"
    add_copy locked
    install_driver "$SLOT" "$W"
    git -C "$SLOT" worktree lock --reason "$reason" "$(copy_path locked)"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    if [[ $reason == *$'\n' ]]; then
      # Git may normalize the reason's terminal newline. Construct an actual
      # extra lock line rather than assuming argv preserved that byte.
      printf '\n' >> "$admin/locked"
      [ "$(wc -l < "$admin/locked")" -ge 2 ] || fail "the multiline-lock fixture has only one line"
    fi
    before=$(shasum -a 256 "$admin/locked")
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "unknown lock failed the run: $OUT"
    assert_class locked HELD-LOCKED
    assert_contains "$OUT" "not the supported Vernant creation-lock format" "unsupported lock format was not explained"
    assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "unsupported lock bytes changed"
    registered locked || fail "an unsupported lock's copy was removed"
    assert_absent "$W/closeout.log" "unsupported lock reached the driver"
  done
  pass "extra lock lines stay byte-identical and never reach the driver"
}

test_binary_creation_lock_is_held_byte_identical() {
  local admin before
  make_world binary-lock
  add_copy locked
  install_driver "$SLOT" "$W"
  git -C "$SLOT" worktree lock --reason \
    'vernant-session-active owner=launcher:999999 launcher=999999' "$(copy_path locked)"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  printf 'vernant-session-active owner=launcher:999999 launcher=999999\000\n' > "$admin/locked"
  before=$(shasum -a 256 "$admin/locked")
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "binary lock failed the run: $OUT"
  assert_class locked HELD-LOCKED
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "binary lock bytes changed"
  registered locked || fail "a binary lock's copy was removed"
  assert_absent "$W/closeout.log" "binary lock reached the driver"
  pass "NUL bytes cannot normalize an unsupported lock into an allowed creation lock"
}

test_failed_driver_removal_cannot_be_retried_as_unlocked() {
  local before
  make_locked_copy_case partial-release dead
  install_driver "$SLOT" "$W"
  : > "$W/fail-after-unlock"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 1 ] || fail "partial driver release did not fail the first run: $OUT"
  assert_contains "$OUT" "injected removal failure after driver released the lock" "driver failure text was lost"
  before=$(snap "$(copy_path locked)")
  rm -f "$W/fail-after-unlock"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "retained partial release failed on rerun: $OUT"
  assert_class locked HELD-LOCKED
  registered locked || fail "partially released copy was removed on the next sweep"
  assert_equals "$before" "$(snap "$(copy_path locked)")" "retained partial copy changed"
  assert_equals 2 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "partial release retried the driver"
  assert_no_grep 'worktree remove' "$W/git.log" "partial release was retried by plain removal"
  pass "a driver that releases its lock but fails removal leaves a durable protection against later plain removal"
}

test_a_stale_retention_receipt_does_not_hold_a_new_copy_at_the_same_path() {
  local shape second head pid retained
  for shape in gone replaced unlocked; do
    make_locked_copy_case "stale-receipt-$shape" dead
    install_driver "$SLOT" "$W"
    printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'old bytes\n' > "$(copy_path locked)/unique.dat"
    head=$(git -C "$(copy_path locked)" rev-parse HEAD)
    retained="$HOMED/data/copy-sweep/retained"
    : > "$W/retain-ignored"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$shape: the retained first run failed ($RC): $OUT"
    assert_contains "$OUT" "KEPT"$'\t'"$(copy_path locked)" "$shape: the driver's retention was not reported"
    assert_equals 1 "$(find "$retained" -type f | wc -l | tr -d ' ')" "$shape: the retained copy has no single receipt"
    rm -f "$W/retain-ignored"
    ln "$(copy_path locked)/.git" "$W/old-dot-git" || fail "$shape: fixture could not keep the old copy's .git inode"
    git -C "$SLOT" worktree unlock "$(copy_path locked)" || fail "$shape: fixture could not unlock the old copy"
    git -C "$SLOT" worktree remove "$(copy_path locked)" || fail "$shape: fixture could not remove the old copy"
    if [ "$shape" != gone ]; then
      second=$(copy_path locked)
      git -C "$SLOT" worktree add -q -b fm/locked-again "$second" "$head"
      if [ "$shape" = replaced ]; then
        sleep 0.1 & pid=$!
        wait "$pid" 2>/dev/null || true
        git -C "$SLOT" worktree lock --reason "vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=$pid" "$second"
      fi
      FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep
      [ "$RC" = 0 ] || fail "$shape: the report failed ($RC): $OUT"
      if [ "$shape" = replaced ]; then assert_class locked PENDING-DRIVER; else assert_class locked REAPABLE-PROVEN; fi
      assert_not_contains "$OUT" "driver retained this copy" "$shape: the old receipt still held the new copy"
    else
      FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep
      [ "$RC" = 0 ] || fail "$shape: the report failed ($RC): $OUT"
    fi
    assert_equals 1 "$(find "$retained" -type f | wc -l | tr -d ' ')" "$shape: report mode changed the receipts"
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$shape: the apply failed ($RC): $OUT"
    assert_contains "$OUT" "RECEIPT-CLEARED"$'\t'"$(copy_path locked)" "$shape: the stale receipt removal was not listed"
    assert_equals 0 "$(find "$retained" -type f | wc -l | tr -d ' ')" "$shape: a stale receipt was left behind"
    if [ "$shape" != gone ]; then
      assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "$shape: the new copy was not judged on its own proofs and removed"
      [ ! -e "$(copy_path locked)" ] || fail "$shape: the new copy is still on disk"
    fi
  done
  pass "a retention receipt whose copy is gone or whose path now holds a different copy, locked or not, is ignored by classification, left by report, and removed and listed by apply, so a new copy at that path is judged on its own proofs"
}

test_report_does_not_claim_unplanned_locks_are_reapable() {
  make_locked_copy_case report-unplanned dead
  install_driver "$SLOT" "$W"
  : > "$W/refuse-plan"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep
  [ "$RC" = 0 ] || fail "report failed: $OUT"
  assert_class locked PENDING-DRIVER
  assert_contains "$OUT" 'summary: REAPABLE-DRIVER=0' "report counted an unplanned copy as reapable"
  assert_contains "$OUT" 'not yet proven removable' "report overstated its local-only proof"
  assert_absent "$W/closeout.log" "report called the driver"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  assert_class locked HELD-LOCKED
  registered locked || fail "refused plan removed the reported candidate"
  pass "report distinguishes a local-proof candidate from a driver-approved removal without executing the driver"
}

test_driver_verdict_types_and_exit_status_are_not_permission() {
  local verdict n=0
  for verdict in '{"allowed":"true"}' '{"allowed":1}' '[{"allowed":true}]' \
      '{"allowed":true} {"allowed":true}' 'allowed=true trailing text'; do
    n=$((n + 1))
    make_locked_copy_case "typed-plan-$n" dead
    install_driver "$SLOT" "$W"
    printf '%s\n' "$verdict" > "$W/plan-output"
    take_snapshots before locked
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "invalid verdict failed the run: $OUT"
    assert_class locked HELD-LOCKED
    take_snapshots after locked
    assert_untouched locked
    assert_equals 1 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "an invalid verdict reached execute"
  done
  make_locked_copy_case nonzero-positive-plan dead
  install_driver "$SLOT" "$W"
  printf '{"allowed":true}\n' > "$W/plan-output"
  printf '3\n' > "$W/plan-exit"
  take_snapshots before locked
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "nonzero positive plan failed the sweep: $OUT"
  assert_class locked HELD-LOCKED
  take_snapshots after locked
  assert_untouched locked
  assert_equals 1 "$(wc -l < "$W/closeout.log" | tr -d ' ')" "nonzero positive verdict reached execute"
  pass "only a boolean positive verdict with exit zero is permission; invalid types, documents, suffixes and nonzero exit keep lock bytes unchanged"
}

driver_pid_count() { [ -f "$W/driver.pids" ] && wc -l < "$W/driver.pids" | tr -d ' ' || printf '0\n'; }

# Fails when any pid the fake driver recorded is still running.
assert_driver_pids_gone() {  # <message>
  local pid tries
  [ -s "$W/driver.pids" ] || fail "$1: the driver recorded no pid"
  while IFS= read -r pid; do
    tries=0
    while kill -0 "$pid" 2>/dev/null && [ "$tries" -lt 30 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
    ! kill -0 "$pid" 2>/dev/null || { kill -s KILL "$pid" 2>/dev/null; fail "$1: driver process $pid is still running"; }
  done < "$W/driver.pids"
}

test_unproved_plan_verdicts_hold_the_copy() {
  local mode admin
  for mode in empty malformed missing false-with-text garbage-literal hang; do
    make_locked_copy_case "plan-$mode" dead
    install_driver "$SLOT" "$W"
    printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
    printf 'durable state\n' > "$(copy_path locked)/unique.dat"
    : > "$W/plan-$mode"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    FM_COPY_SWEEP_PLAN_TIMEOUT=1 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "an unproved plan ($mode) must not fail the run, got $RC: $OUT"
    assert_class locked HELD-LOCKED
    assert_contains "$OUT" "summary: HELD-LOCKED=1" "an unproved plan ($mode) is not counted as held"
    assert_not_contains "$OUT" "FAILED" "an unproved plan ($mode) was reported as a failure"
    assert_absent "$HOMED/data/copy-sweep" "an unproved plan ($mode) copied ignored entries"
    [ -e "$(copy_path locked)" ] || fail "an unproved plan ($mode) removed the copy"
    registered locked || fail "an unproved plan ($mode) left the copy unregistered"
    [ -f "$admin/locked" ] || fail "an unproved plan ($mode) lost the lock"
    [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "an unproved plan ($mode) logged a removal"
    assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
      "an unproved plan ($mode) asked the driver for more than its plan"
    if [ "$mode" = hang ]; then
      assert_contains "$OUT" "did not answer within 1s" "a plan that never answers did not say so"
      [ "$(driver_pid_count)" -ge 2 ] || fail "the hung plan did not leave a child running"
    fi
    assert_driver_pids_gone "a finished plan ($mode)"
  done
  pass "an empty, malformed, missing, false-with-text or garbage-literal plan verdict and a plan that never answers all hold the copy locked, copy nothing, run the driver only in plan mode, leave no driver process running, and exit 0"
}

test_a_bare_allowed_literal_plan_does_not_release_the_copy() {
  local admin before
  make_locked_copy_case planbare dead
  install_driver "$SLOT" "$W"
  printf 'allowed=true\n' > "$W/plan-output"
  admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
  before=$(shasum -a 256 "$admin/locked")
  take_snapshots before locked
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "a bare allowed=true plan failed the run ($RC): $OUT"
  assert_class locked HELD-LOCKED
  assert_not_contains "$OUT" "REMOVED" "a bare allowed=true plan released the copy"
  take_snapshots after locked
  assert_untouched locked
  assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "a bare allowed=true plan changed the lock"
  assert_equals "$SLOT|--cleanup-worktree $(copy_path locked)" "$(cat "$W/closeout.log")" \
    "a bare allowed=true plan reached execute"
  assert_absent "$HOMED/data/copy-sweep" "a bare allowed=true plan copied ignored entries or wrote a receipt"
  pass "a plan whose whole answer is the bare text allowed=true holds the copy and never executes the driver"
}

test_a_zero_padded_plan_timeout_is_read_as_decimal() {
  local padded
  make_locked_copy_case planpadhang dead
  install_driver "$SLOT" "$W"
  : > "$W/plan-hang"
  FM_COPY_SWEEP_PLAN_TIMEOUT=08 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "a zero-padded plan bound failed the run ($RC): $OUT"
  assert_class locked HELD-LOCKED
  assert_contains "$OUT" "did not answer within 8s" "a hung plan under a bound of 08 did not say 8s"
  assert_not_contains "$OUT" "value too great" "a zero-padded plan bound was read as octal"
  assert_driver_pids_gone "a hung plan under a bound of 08"
  for padded in 08 09; do
    make_locked_copy_case "planpadallow$padded" dead
    install_driver "$SLOT" "$W"
    FM_COPY_SWEEP_PLAN_TIMEOUT=$padded FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "an allowed plan under a bound of $padded failed the run ($RC): $OUT"
    assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path locked)" "an allowed plan under a bound of $padded did not release the copy"
    assert_not_contains "$OUT" "value too great" "a bound of $padded was read as octal"
    [ ! -e "$(copy_path locked)" ] || fail "an allowed plan under a bound of $padded left the copy on disk"
  done
  pass "a zero-padded plan bound is decimal: 08 holds a hung plan at 8s and 08 or 09 releases a copy whose plan allows it"
}

test_a_sweep_stopped_during_a_plan_stops_the_hung_driver() {
  local sweep waited=0
  make_locked_copy_case planstopped dead
  install_driver "$SLOT" "$W"
  : > "$W/plan-hang"
  (
    export FM_COPY_SWEEP_PLAN_TIMEOUT=120 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY"
    sweep_cmd --apply > "$W/stopped.out" 2>&1
  ) &
  sweep=$!
  while [ "$(driver_pid_count)" != 2 ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(driver_pid_count)" = 2 ] || { kill "$sweep" 2>/dev/null; fail "the hung plan never started"; }
  kill -s TERM "$sweep"
  wait "$sweep" 2>/dev/null || true
  assert_driver_pids_gone "a sweep stopped during its plan"
  [ -e "$(copy_path locked)" ] || fail "a sweep stopped during its plan removed the copy"
  pass "a sweep stopped while its plan hangs stops the driver and its child too"
}

test_two_sweeps_of_one_path_keep_both_preserved_directories() {
  local second pid kept head
  make_locked_copy_case reusedpath dead
  install_driver "$SLOT" "$W"
  printf 'unique.dat\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'first copy\n' > "$(copy_path locked)/unique.dat"
  head=$(git -C "$(copy_path locked)" rev-parse HEAD)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the first apply failed ($RC): $OUT"
  [ ! -e "$(copy_path locked)" ] || fail "the first copy was not released"
  second=$(copy_path locked)
  git -C "$SLOT" worktree add -q -b fm/locked-again "$second" "$head"
  sleep 0.1 & pid=$!
  wait "$pid" 2>/dev/null || true
  git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$second"
  printf 'second copy\n' > "$second/unique.dat"
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "the second apply failed ($RC): $OUT"
  [ ! -e "$second" ] || fail "the second copy was not released"
  kept=$(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name unique.dat -type f -exec cat {} + | LC_ALL=C sort | tr '\n' '|')
  assert_equals "first copy|second copy|" "$kept" "the second sweep of the same path replaced the first preserved copy"
  pass "new copies at the same path and HEAD retain both versions of their preserved ignored bytes"
}

test_a_removal_with_no_measured_size_says_so() {
  make_world unmeasured
  add_copy reap
  FAKE_LOAD=95 run_sweep --apply
  [ "$RC" = 0 ] || fail "apply above the load limit should finish, got $RC: $OUT"
  [ ! -e "$(copy_path reap)" ] || fail "apply should still remove a proven copy while sizing is skipped"
  assert_contains "$OUT" "copy - GiB, preserved 0.00 GiB, net freed - GiB, unmeasured" \
    "the removal line did not say its size was not measured"
  assert_contains "$OUT" "sizes: 1 scanned copies unmeasured, 1 removed copies unmeasured" \
    "the run did not disclose its unmeasured copy"
  assert_equals "copies=1 GiB=0.00 reaped=1 freed=0.00" "$(printf '%s\n' "$OUT" | tail -n 1)" \
    "the run did not report its measured lower-bound totals"
  pass "a removal whose size was not measured shows - and unmeasured, and the closing total counts it"
}

test_locked_copy_with_an_unpushed_equivalence_is_still_held() {
  make_locked_copy_case locked-unpushed dead
  install_driver "$SLOT" "$W"
  # An empty commit's content is trivially already in the default branch, so the
  # unlocked landed-content fallback alone would call this copy reapable.
  git -C "$(copy_path locked)" commit -q --allow-empty -m 'local only'
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_class locked HELD-UNPUSHED
  assert_contains "$OUT" "a locked copy is released only when every local commit is on a remote" \
    "the report did not say why the locked copy is held"
  [ -e "$(copy_path locked)" ] || fail "a locked copy with an unpushed commit was removed"
  assert_absent "$W/closeout.log" "the driver ran on a locked copy with an unpushed commit"
  [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "a held locked copy was logged as removed"
  kill "$LIVE_PID" 2>/dev/null || true
  wait "$LIVE_PID" 2>/dev/null || true
  pass "a locked copy with an unpushed but content-equivalent commit is held, and the driver never runs"
}

test_live_foreign_or_unreleasable_locks_are_kept() {
  local mode admin before
  for mode in live foreign; do
    make_locked_copy_case "lock-$mode" "$mode"
    install_driver "$SLOT" "$W"
    admin=$(git -C "$(copy_path locked)" rev-parse --absolute-git-dir)
    before=$(shasum -a 256 "$admin/locked")
    FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
    [ "$RC" = 0 ] || fail "$mode: apply failed ($RC): $OUT"
    assert_class locked HELD-LOCKED
    assert_equals "$before" "$(shasum -a 256 "$admin/locked")" "$mode: held lock bytes were written"
    assert_no_grep "REMOVED" <(printf '%s\n' "$OUT") "$mode: a kept copy was removed"
    [ -e "$(copy_path locked)" ] || fail "$mode: the locked copy was removed"
    assert_absent "$W/closeout.log" "$mode: the driver ran on a copy it must not release"
    [ ! -e "$HOMED/data/copy-sweep.log" ] || fail "$mode: a removal was logged"
    if [ "$mode" = live ]; then
      kill "$LIVE_PID" 2>/dev/null || true
      wait "$LIVE_PID" 2>/dev/null || true
    fi
  done
  make_locked_copy_case unreleasable dead
  run_sweep
  [ "$RC" = 0 ] || fail "unreleasable: report failed ($RC): $OUT"
  assert_class locked HELD-LOCKED
  assert_contains "$OUT" "closeout driver or interpreter unavailable" \
    "the report did not say why the copy cannot be released"
  pass "a live launcher, a lock that is not Vernant's, and a missing driver all keep their copy untouched"
}

test_copy_with_one_untracked_file_and_unpushed_tip_are_kept() {
  local bundle digest tips
  make_world edges
  add_copy one
  printf 'u\n' > "$(copy_path one)/just-one-untracked-file"
  add_copy two
  git -C "$(copy_path two)" commit -q --allow-empty -m unpushed
  bundle="$W/bundles/two.bundle"
  mkdir -p "${bundle%/*}" "$HOMED/data/two"
  git -C "$(copy_path two)" bundle create "$bundle" --all 2>/dev/null || fail 'cannot bundle the unpushed tip'
  git -C "$(copy_path two)" bundle verify "$bundle" >/dev/null 2>&1 || fail 'bundle must verify'
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}')
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$HOMED/data/two/preservation-bundles.tsv"
  take_snapshots before one two
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  assert_class one HELD-DIRTY
  assert_class two HELD-UNPUSHED
  take_snapshots after one two
  assert_untouched one two
  assert_present "$bundle" 'sweep deleted the external preservation bundle'
  pass "a dirty copy and an unpushed copy with a verified recorded bundle are both kept"
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
  local measured
  make_budget_world cut 10 10 10
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  # The first du finishes at once; the second hangs past the bound at every
  # sub-second phase of its whole-second deadline; the third never starts.
  FAKE_DU_HANG_AFTER=1 FM_CHECK_TIMEOUT=8 run_sweep check
  [ "$RC" = 0 ] || fail "check failed ($RC): $OUT"
  measured=$(du_calls)
  { [ "$measured" -ge 1 ] && [ "$measured" -le 2 ]; } || fail "a du that could not finish inside the bound was counted, or none finished: $measured completed"
  assert_contains "$OUT" "container $SLOT is over its budget: " "a lower bound already over the budget should wake"
  assert_contains "$OUT" "against 5 GiB" "the wake did not name the container budget"
  assert_no_grep "last_scan" "$HOMED/state/copy-sweep.record" "a cut scan was recorded as complete"
  make_budget_world cutquiet 1 1 1
  printf 'default-pool off\ncontainer %s 5\ninterval 0\ncache-max-age 0\n' "$SLOT" > "$HOMED/config/copy-budget"
  FAKE_DU_HANG_AFTER=1 FM_CHECK_TIMEOUT=8 run_sweep check
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

# graft's generated output (tests/lib.sh fm_test_graft_output) alone holds no
# copy; a custom .ignore or a clone below graft/ beside it still does
# (data/fm-merge-prune-graft-scratch/report.md).
test_graft_output_alone_holds_no_copy() {
  make_world graft
  add_copy graftonly
  fm_test_graft_output "$(copy_path graftonly)"
  add_copy graftignore
  fm_test_graft_output "$(copy_path graftignore)"
  printf 'project-private/\n' >> "$(copy_path graftignore)/.ignore"
  add_copy graftclone
  fm_test_graft_output "$(copy_path graftclone)"
  git init -q "$(copy_path graftclone)/graft/n1"
  run_sweep
  [ "$RC" = 0 ] || fail "report failed ($RC): $OUT"
  assert_class graftonly REAPABLE-PROVEN
  assert_class graftignore HELD-DIRTY
  assert_class graftclone HELD-DIRTY
  assert_contains "$OUT" "it holds ignored files that exist nowhere else: .ignore" "a custom .ignore beside graft output did not hold its copy"
  assert_contains "$OUT" "it holds ignored files that exist nowhere else: graft" "a clone below graft/ did not hold its copy"
  take_snapshots before graftignore graftclone
  run_sweep --apply
  [ "$RC" = 0 ] || fail "apply failed ($RC): $OUT"
  [ ! -e "$(copy_path graftonly)" ] || fail "a copy holding only graft output was not reaped"
  take_snapshots after graftignore graftclone
  assert_untouched graftignore graftclone
  pass "graft output alone is reaped, and a custom .ignore or a clone below graft/ still holds the copy"
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

# --- supersedence route ------------------------------------------------------
# bin/fm-teardown-nested-lib.sh owns the route and its header the record format
# and conditions. The forge is a fake `gh` and the driver a scripted stand-in per
# copy (tests/fm-supersedence-route-helpers.sh); both are reduced evidence, and
# the real driver is never called.

# A world whose clone names a GitHub origin (rewritten to the local bare one),
# with one merge commit on origin/main, a fake forge and the scripted driver.
# ROUTE_MERGE is that merge commit. Make copies after this call.
route_world() {  # <name>
  make_world "$1"
  git -C "$SLOT" config "url.file://$(cd "$W/origin.git" && pwd).insteadOf" "$ROUTE_REMOTE_URL"
  git -C "$SLOT" remote set-url origin "$ROUTE_REMOTE_URL"
  git -C "$SLOT" commit --allow-empty -qm "merge of the superseding pull request"
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" fetch -q origin
  ROUTE_MERGE=$(git -C "$SLOT" rev-parse HEAD)
  route_install_gh "$FAKEBIN" "$W/forge"
  install_driver "$SLOT" "$W"
  route_install_row_driver "$SLOT" "$W"
  mkdir -p "$HOMED/data" "$W/profiles"
}

# Vernant's creation lock naming a launcher that has finished. The pid is one no
# process can hold (above the kernel's pid range), as in the suite's other dead
# launcher locks: a just-finished child's pid can be reused by a new process
# during a long scenario, which the sweep then rightly holds as a live launcher.
route_lock_dead() {  # <name>
  git -C "$SLOT" worktree lock --reason 'vernant-session-active owner=launcher:999999 launcher=999999' "$(copy_path "$1")"
}

route_record() {  # <name> <pr> <tip> <profile>
  printf '%s\t%s\t%s\t%s\n' "$(copy_path "$1")" "$3" "$2" "$4" >> "$HOMED/data/supersedence-records.tsv"
}

route_tip() { git -C "$(copy_path "$1")" rev-parse HEAD; }

# A locked, pushed copy with a valid record, a profile for its tip and scripted
# --pr answers (default: the plan allows and the execute succeeds).
# A copy that sits at the merge commit itself, so the merge commit carries everything
# the copy holds (an empty net change, R2(h)); a copy with changes of its own is
# built by the content cases, which choose what the merge commit carries.
route_bare_copy() {  # <name>
  git -C "$SLOT" worktree add -q -b "fm/$1" "$(copy_path "$1")" "${ROUTE_COPY_AT:-$ROUTE_MERGE}"
  git -C "$(copy_path "$1")" push -q origin "fm/$1"
}

route_copy() {  # <name> <pr> [<plan-kind> [<execute-kind>]]
  local name=$1 pr=${2:-7}
  route_bare_copy "$name"
  route_lock_dead "$name"
  route_write_profile "$W/profiles/$name.json" "$pr" "$(route_tip "$name")"
  route_record "$name" "$pr" "$(route_tip "$name")" "$W/profiles/$name.json"
  route_script_row "$W" "$name" "${3:-allowed}" "${4:-success}" "$pr"
}

route_sweep() { FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep "$@"; }

# The driver's argv lines for one copy, without the "<cwd>|" prefix.
route_calls_for() {  # <name>
  [ -f "$W/closeout.log" ] || return 0
  COPY="--cleanup-worktree $(copy_path "$1")" awk '
    { i = index($0, ENVIRON["COPY"]); if (i == 0) next
      rest = substr($0, i + length(ENVIRON["COPY"]))
      if (rest == "" || substr(rest, 1, 1) == " ") { sub(/^[^|]*\|/, ""); print } }' "$W/closeout.log"
}

# The report line of one copy.
route_line_of() {
  printf '%s\n' "$OUT" | P=$(copy_path "$1") awk -F '\t' '$3 == ENVIRON["P"] || $2 == ENVIRON["P"] { print }'
}

# Exactly one plan and one execute for <name>, run from the slot, each holding
# exactly the route's option bindings.
route_assert_calls() {  # <name> <pr> <label>
  local name=$1 pr=$2 label=$3 lines plan execute
  lines=$(route_calls_for "$name")
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 2 ] || fail "$label: wanted one plan and one execute for $name, got: $lines"
  plan=$(printf '%s\n' "$lines" | sed -n 1p)
  execute=$(printf '%s\n' "$lines" | sed -n 2p)
  # shellcheck disable=SC2086 # the argv words hold no spaces
  route_argv_check plan "$pr" "$W/profiles/$name.json" "$(copy_path "$name")" $plan || fail "$label: the plan's argv is wrong: $ROUTE_ARGV_WHY ($plan)"
  # shellcheck disable=SC2086
  route_argv_check execute "$pr" "$W/profiles/$name.json" "$(copy_path "$name")" $execute || fail "$label: the execute's argv is wrong: $ROUTE_ARGV_WHY ($execute)"
  [ "$(grep -cF "$SLOT|$plan" "$W/closeout.log")" = 1 ] && [ "$(grep -cF "$SLOT|$execute" "$W/closeout.log")" = 1 ] \
    || fail "$label: the driver did not run from the slot clone for $name"
  printf 'argv: %s: plan: %s\nargv: %s: execute: %s\n' "$label" "${plan//$W/<world>}" "$label" "${execute//$W/<world>}"
}

route_assert_released() {  # <name> <label>
  [ ! -e "$(copy_path "$1")" ] || fail "$2: $1 was not removed"
  ! registered "$1" || fail "$2: $1 is still registered"
  assert_contains "$OUT" "REMOVED"$'\t'"$(copy_path "$1")"$'\t' "$2: $1 was not reported removed"
}

route_assert_kept() {  # <name> <label>
  [ -e "$(copy_path "$1")" ] || fail "$2: $1 was removed"
  registered "$1" || fail "$2: $1 is no longer registered"
  assert_not_contains "$OUT" "REMOVED"$'\t'"$(copy_path "$1")"$'\t' "$2: $1 was reported removed"
}

test_the_route_comparator_accepts_both_orders_and_rejects_every_wrong_call() {
  route_argv_selftest
  pass "the argv comparator accepts the canonical and the plain call's prefix order and rejects an added option, a missing or wrong binding and a duplicate"
}

test_a_record_makes_the_sweep_ask_the_driver_by_its_pr_route_and_no_record_changes_nothing() {
  local plain_line
  route_world route-argv
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy twin 7
  add_copy plain
  route_lock_dead plain
  route_sweep --apply
  [ "$RC" = 0 ] || fail "route-argv: the run failed ($RC): $OUT"
  route_assert_released twin route-argv
  route_assert_calls twin 7 route-argv
  assert_equals "--cleanup-worktree $(copy_path plain)" "$(route_calls_for plain)" \
    "route-argv: the copy with no record was not asked exactly as before, once, as a plan"
  route_assert_kept plain route-argv
  plain_line=$(route_line_of plain)
  assert_contains "$plain_line" "verification_stale_or_uncovered_paths" "route-argv: the plain refusal lost the driver's reason"
  assert_not_contains "$plain_line" "supersedence route" "route-argv: a copy with no record reads as a route refusal"
  pass "a record makes the sweep's plan and execute ask the driver with exactly the --pr route's options from the slot clone, and a copy with no record is asked exactly as before"
}

# One world, one run: a good copy and one bad copy per condition. The good copy
# is released and every bad copy stays, with no driver call for it, and the reason
# names what failed. The scripted driver would allow every route call, so only
# Firstmate's own check can keep a bad copy.
test_a_record_that_fails_any_condition_keeps_the_copy_and_never_reaches_the_driver() {
  local row phrase tip other n=0 line expect
  local -a rows=(tip-differs tip-prefix tip-moves pr-not-integer profile-relative profile-missing profile-symlink profile-not-json
    profile-pr-mismatch profile-tip-mismatch profile-tip-absent pr-closed pr-open forge-fails forge-hangs forge-garbage
    no-merge-commit merge-commit-absent merge-commit-off-main short-record conflicting-records other-copy pr-closes-after-plan)
  local -a phrases=() expects=()
  other=$(printf '%040d' 0 | tr 0 b)
  route_world route-conditions
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy ok 7
  for row in "${rows[@]}"; do
    n=$((n + 1))
    route_bare_copy "bad-$row"
    route_lock_dead "bad-$row"
    route_script_row "$W" "bad-$row" allowed success "$((100 + n))"
    tip=$(route_tip "bad-$row")
    route_set_pr "$W/forge" "$((100 + n))" MERGED "$ROUTE_MERGE"
    route_write_profile "$W/profiles/bad-$row.json" "$((100 + n))" "$tip"
    phrase=
    expect=0
    case "$row" in
      tip-differs) route_record "bad-$row" "$((100 + n))" "$other" "$W/profiles/bad-$row.json"; phrase="at tip $other but the copy is at $tip" ;;
      tip-prefix) route_record "bad-$row" "$((100 + n))" "${tip:0:39}" "$W/profiles/bad-$row.json"; phrase="at tip ${tip:0:39} but the copy is at $tip" ;;
      tip-moves)
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"
        # shellcheck disable=SC2016 # the hook expands its own $1 when it runs
        printf '#!/usr/bin/env bash\ngit -C "$1" -c user.name=t -c user.email=t@example.invalid commit --allow-empty -qm moved\n' > "$W/ans/bad-$row/plan.hook"
        # The copy sits at the merge commit, so the empty commit adds no content and the
        # class still allows it; the sweep's own HEAD pin then refuses its execute.
        phrase="changed HEAD or creation-lock bytes after its plan"
        expect=1
        ;;
      pr-not-integer) route_record "bad-$row" 8a "$tip" "$W/profiles/bad-$row.json"; phrase="'8a' is not a decimal integer" ;;
      profile-relative) route_record "bad-$row" "$((100 + n))" "$tip" "profiles/bad-$row.json"; phrase="'profiles/bad-$row.json' is not absolute" ;;
      profile-missing) rm -f "$W/profiles/bad-$row.json"; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="is not a regular file" ;;
      profile-symlink)
        mv "$W/profiles/bad-$row.json" "$W/profiles/bad-$row.real.json"
        ln -s "$W/profiles/bad-$row.real.json" "$W/profiles/bad-$row.json"
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"
        phrase="is not a regular file"
        ;;
      profile-not-json) printf 'name only, not json\n' > "$W/profiles/bad-$row.json"; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="cannot be read as a JSON object" ;;
      profile-pr-mismatch) route_write_profile "$W/profiles/bad-$row.json" 99 "$tip"; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="names PR 99, not PR $((100 + n))" ;;
      profile-tip-mismatch) route_write_profile "$W/profiles/bad-$row.json" "$((100 + n))" "$other"; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="binds superseded_tip_sha $other" ;;
      profile-tip-absent) route_write_profile "$W/profiles/bad-$row.json" "$((100 + n))" -; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="binds superseded_tip_sha none" ;;
      pr-closed) route_set_pr "$W/forge" "$((100 + n))" CLOSED; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="PR $((100 + n)) as CLOSED, not MERGED" ;;
      pr-open) route_set_pr "$W/forge" "$((100 + n))" OPEN; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="PR $((100 + n)) as OPEN, not MERGED" ;;
      forge-fails) route_set_pr "$W/forge" "$((100 + n))" FAIL; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="forge read of PR $((100 + n)) failed" ;;
      forge-hangs) route_set_pr "$W/forge" "$((100 + n))" HANG; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="forge read of PR $((100 + n)) timed out" ;;
      forge-garbage) route_set_pr "$W/forge" "$((100 + n))" GARBAGE; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="forge answer for PR $((100 + n)) cannot be parsed" ;;
      no-merge-commit) route_set_pr "$W/forge" "$((100 + n))" MERGED ""; route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"; phrase="reports no merge commit" ;;
      merge-commit-absent)
        route_set_pr "$W/forge" "$((100 + n))" MERGED "$other"
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"
        phrase="merge commit $other of PR $((100 + n)) is not in the clone"
        ;;
      merge-commit-off-main)
        route_set_pr "$W/forge" "$((100 + n))" MERGED "$(git -C "$SLOT" commit-tree 'HEAD^{tree}' -p HEAD -m side-branch)"
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"
        phrase="is not on origin/main (not landed)"
        ;;
      short-record) printf '%s\t%s\t%s\n' "$(copy_path "bad-$row")" "$tip" "$((100 + n))" >> "$HOMED/data/supersedence-records.tsv"; phrase="has 3 tab-separated fields, not four" ;;
      conflicting-records)
        route_write_profile "$W/profiles/bad-$row.2.json" "$((100 + n))" "$tip"
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.2.json"
        phrase="two records bind this copy at its tip to different PRs or profiles"
        ;;
      pr-closes-after-plan)
        # The record holds at the plan; the forge shows the PR closed by the execute.
        route_record "bad-$row" "$((100 + n))" "$tip" "$W/profiles/bad-$row.json"
        printf '#!/usr/bin/env bash\nprintf "CLOSED\\t\\t%%s\\n" "%s" > "%s"\n' "fm/pr-$((100 + n))-head" "$W/forge/pr-$((100 + n))" > "$W/ans/bad-$row/plan.hook"
        phrase="PR $((100 + n)) as CLOSED, not MERGED"
        expect=1
        ;;
      other-copy)
        # A record for another copy, carrying this copy's tip and profile, binds nothing here.
        # The other copy is a holder of its own: a row of another tip holds the copy it names.
        add_copy holder
        route_lock_dead holder
        route_script_row "$W" holder allowed success 7
        printf '%s\t%s\t%s\t%s\n' "$(copy_path holder)" "$tip" "$((100 + n))" "$W/profiles/bad-$row.json" >> "$HOMED/data/supersedence-records.tsv"
        phrase="verification_stale_or_uncovered_paths"
        expect=1
        ;;
    esac
    phrases+=("$phrase")
    expects+=("$expect")
  done
  FM_TEARDOWN_FORGE_TIMEOUT=2 FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  route_assert_released ok conditions
  route_assert_calls ok 7 conditions
  n=0
  for row in "${rows[@]}"; do
    route_assert_kept "bad-$row" "$row"
    line=$(route_line_of "bad-$row")
    assert_contains "$line" "${phrases[$n]}" "$row: the reason does not name the failed condition"
    assert_equals "${expects[$n]}" "$(route_calls_for "bad-$row" | grep -c .)" "$row: wrong number of driver calls for the bad copy: $(route_calls_for "bad-$row")"
    printf 'condition %s: kept; driver calls for it: %s; reason: %s\n' "$row" "${expects[$n]}" "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 220) }')"
    case "$row" in
      pr-closes-after-plan)
        assert_not_contains "$(route_calls_for "bad-$row")" "--execute-cleanup" "$row: the closed PR reached the driver's execute"
        assert_contains "$line" "was not released: its supersedence record cannot be used" "$row: the stopped execute is not named"
        assert_absent "$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path "bad-$row")" | shasum -a 256 | awk '{print $1}')" "$row: a receipt was kept for an execute that never reached the driver"
        ;;
      tip-moves) assert_not_contains "$(route_calls_for "bad-$row")" "--execute-cleanup" "$row: the moved tip reached the driver's execute" ;;
      other-copy) assert_equals "--cleanup-worktree $(copy_path "bad-$row")" "$(route_calls_for "bad-$row")" "$row: a copy with no record of its own was not asked the plain plan" ;;
    esac
    case "$row" in
      tip-moves | other-copy | pr-closes-after-plan) ;;
      *) assert_not_contains "$(route_calls_for "bad-$row")" "--pr" "$row: the bad copy reached the driver by the route" ;;
    esac
    n=$((n + 1))
  done
  pass "a record that names another tip or a prefix, moves the tip after the plan, has a bad PR field, profile or forge answer, or names a merge commit that is missing or off origin/main keeps the copy, with no driver call, while a valid record in the same run is released (${#rows[@]} conditions)"
}

# A plan is a dry run, and the driver's DONE-state finish switches a primary
# checkout that is on the PR's head branch and writes its closeout-state marker
# before Firstmate reads the answer. The twin's scripted driver does what the real
# one does in that state, so only Firstmate's own check can keep the slot as it was.
# The head branch carries a file main lacks, so that switch would change the slot's
# working tree, and the digest of that tree is compared before and after the run.
test_a_plan_never_asks_the_driver_while_the_slots_checkout_is_on_the_prs_head_branch() {
  local head before line tree
  route_world route-head-branch
  head=fm/pr-7-head
  git -C "$SLOT" checkout -q -b "$head"
  printf 'only on the head branch\n' > "$SLOT/pr-7-head.txt"
  git -C "$SLOT" add pr-7-head.txt
  git -C "$SLOT" commit -qm "a commit main lacks"
  before=$(git -C "$SLOT" rev-parse HEAD)
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE" "$head"
  route_set_pr "$W/forge" 8 MERGED "$ROUTE_MERGE"
  route_copy twin 7
  route_copy control 8
  cat > "$W/ans/twin/plan.hook" <<SH
#!/usr/bin/env bash
[ "\$(git -C "$SLOT" branch --show-current)" = "$head" ] || exit 0
git -C "$SLOT" checkout -q main
: > "$SLOT/.git/closeout-state-marker"
SH
  tree=$(route_checkout_digest "$SLOT")
  route_sweep --apply
  assert_equals "$tree" "$(route_checkout_digest "$SLOT")" "route-head-branch: the plan changed the slot's working tree"
  [ "$RC" = 0 ] || fail "route-head-branch: the run failed ($RC): $OUT"
  assert_equals "$head" "$(git -C "$SLOT" branch --show-current)" "route-head-branch: the plan switched the slot's branch"
  assert_equals "$before" "$(git -C "$SLOT" rev-parse HEAD)" "route-head-branch: the plan moved the slot's HEAD"
  assert_absent "$SLOT/.git/closeout-state-marker" "route-head-branch: the plan wrote the closeout-state marker"
  route_assert_kept twin route-head-branch
  assert_equals "" "$(route_calls_for twin)" "route-head-branch: the copy reached the driver"
  line=$(route_line_of twin)
  assert_contains "$line" "is on PR 7's head branch $head" "route-head-branch: the reason does not name the head branch"
  route_assert_released control route-head-branch
  route_assert_calls control 8 route-head-branch
  route_assert_digest_sees "$SLOT" route-head-branch
  pass "a plan never asks the driver while the slot's checkout is on the PR's head branch, so the slot's branch, HEAD, working tree and marker stay as they were, and a PR with another head branch still routes from that slot; the working-tree digest sees a switch to main, a tracked edit and an untracked file"
}

# A Treehouse slot is a linked worktree of the project. Its own branch, not only the
# project's main worktree, is read against the PR's head branch, so a slot that stays
# on the head branch is a plain hold before the route's window, never a reported
# switch that stops the run; a later eligible copy in the same run is still released.
test_a_linked_worktree_slot_on_the_prs_head_branch_is_a_plain_hold_and_the_run_goes_on() {
  local head project line
  route_world route-linked-slot
  head=fm/pr-7-head
  project=$SLOT
  SLOT="$TH/pool1/2/repo"
  mkdir -p "$TH/pool1/2"
  git -C "$project" worktree add -q -b "$head" "$SLOT" "$ROUTE_MERGE"
  printf '{"worktrees":[{"name":"2","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
  install_driver "$SLOT" "$W"
  route_install_row_driver "$SLOT" "$W"
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE" "$head"
  route_set_pr "$W/forge" 8 MERGED "$ROUTE_MERGE"
  route_copy a-twin 7
  route_copy b-later 8
  route_sweep --apply
  [ "$RC" = 0 ] || fail "route-linked-slot: the run failed ($RC): $OUT"
  assert_equals main "$(git -C "$project" branch --show-current)" "route-linked-slot: the project's main worktree left main"
  assert_equals "$head" "$(git -C "$SLOT" branch --show-current)" "route-linked-slot: the slot left the PR's head branch"
  route_assert_kept a-twin route-linked-slot
  assert_equals "" "$(route_calls_for a-twin)" "route-linked-slot: the copy reached the driver"
  line=$(route_line_of a-twin)
  assert_contains "$line" "own checkout (a linked worktree's HEAD) is on PR 7's head branch $head" "route-linked-slot: the reason does not name the head branch"
  assert_not_contains "$line" "was switched" "route-linked-slot: a slot that stayed on the head branch was reported as a switch"
  assert_not_contains "$OUT" "was switched" "route-linked-slot: a switch was reported" && assert_not_contains "$OUT" "SKIPPED" "route-linked-slot: the run stopped and skipped a pending copy"
  route_assert_released b-later route-linked-slot
  route_assert_calls b-later 8 route-linked-slot
  pass "a linked worktree slot on the PR's head branch, with the project's main worktree on main, holds the copy with no driver call and the head-branch reason, not a switch, and a later eligible copy in the same run is still released"
}

# A row that names this copy at its live tip but leaves the PR or the profile empty,
# gives a PR that is no decimal integer, or disagrees with another such row is not
# the owner's word, so the copy is held with no driver call whatever the order of
# the rows. The scripted driver would allow every route call, so only Firstmate's
# own check can keep a bad copy; a copy with one valid row in the same run routes.
# The first variant in the first order is the reviewer's reproduction (Main 010 F1).
test_a_matching_record_row_that_is_empty_or_conflicts_holds_the_copy_in_either_row_order() {
  local variant order name tip bad phrase count n=0 line path
  local -a variants=(empty-both empty-pr empty-profile non-integer-pr other-pr relative-profile) cases=() phrases=()
  route_world route-matching-rows
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_set_pr "$W/forge" 8 MERGED "$ROUTE_MERGE"
  route_copy ok 7
  for order in invalid-first valid-first; do
    for variant in "${variants[@]}"; do
      name=bad-$variant-$order
      add_copy "$name"
      route_lock_dead "$name"
      route_script_row "$W" "$name" allowed success 7
      tip=$(route_tip "$name")
      path=$(copy_path "$name")
      route_write_profile "$W/profiles/$name.json" 7 "$tip"
      route_write_profile "$W/profiles/$name.8.json" 8 "$tip"
      case "$variant" in
        empty-both) bad=$(printf '%s\t%s\t\t' "$path" "$tip"); phrase="leaves the PR or the profile empty" ;;
        empty-pr) bad=$(printf '%s\t%s\t\t%s' "$path" "$tip" "$W/profiles/$name.json"); phrase="leaves the PR or the profile empty" ;;
        empty-profile) bad=$(printf '%s\t%s\t7\t' "$path" "$tip"); phrase="leaves the PR or the profile empty" ;;
        non-integer-pr) bad=$(printf '%s\t%s\t8a\t%s' "$path" "$tip" "$W/profiles/$name.json"); phrase="'8a' is not a decimal integer" ;;
        other-pr) bad=$(printf '%s\t%s\t8\t%s' "$path" "$tip" "$W/profiles/$name.8.json"); phrase="two records bind this copy at its tip to different PRs or profiles" ;;
        relative-profile) bad=$(printf '%s\t%s\t7\t%s' "$path" "$tip" "profiles/$name.json"); phrase="two records bind this copy at its tip to different PRs or profiles" ;;
      esac
      if [ "$order" = invalid-first ]; then
        printf '%s\n' "$bad" >> "$HOMED/data/supersedence-records.tsv"
        route_record "$name" 7 "$tip" "$W/profiles/$name.json"
      else
        route_record "$name" 7 "$tip" "$W/profiles/$name.json"
        printf '%s\n' "$bad" >> "$HOMED/data/supersedence-records.tsv"
      fi
      cases+=("$name")
      phrases+=("$phrase")
    done
  done
  FM_TEARDOWN_FORGE_TIMEOUT=2 FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  route_assert_released ok matching-rows
  route_assert_calls ok 7 matching-rows
  for name in "${cases[@]}"; do
    line=$(route_line_of "$name")
    count=$(route_calls_for "$name" | grep -c . || true)
    printf 'matching rows %s: %s; driver calls for it: %s; reason: %s\n' "$name" \
      "$([ -e "$(copy_path "$name")" ] && printf kept || printf RELEASED)" "$count" "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 200) }')"
    n=$((n + 1))
  done
  n=0
  for name in "${cases[@]}"; do
    route_assert_kept "$name" "$name"
    assert_equals "" "$(route_calls_for "$name")" "$name: an invalid or conflicting matching row let the copy reach the driver"
    assert_contains "$(route_line_of "$name")" "${phrases[$n]}" "$name: the reason does not name the failed condition"
    n=$((n + 1))
  done
  pass "a row that names the copy at its live tip with an empty PR or profile, a PR that is no decimal integer, or a PR or profile that disagrees with another such row holds the copy with no driver call whether it comes before or after the valid row (${#cases[@]} cases), while a copy with one valid row is released in the same run"
}

# The forge read is bounded by the plan: when the plan's bound passes or the sweep
# is stopped, the read stops with it (Main 010 F2). The fake forge records its pid
# and becomes `sleep`, so the pid it records is the sleeper's own and a read that
# outlives the plan is visible. The control is a forge that answers at once.
test_a_plan_that_times_out_or_is_stopped_leaves_no_forge_read_running() {
  local sweep waited=0 pid
  FORGE_ALIVE=
  route_world route-forge-lifetime
  route_set_pr "$W/forge" 7 HANG
  route_copy slow 7
  FM_COPY_SWEEP_PLAN_TIMEOUT=3 FM_TEARDOWN_FORGE_TIMEOUT=25 route_sweep --apply
  [ "$RC" = 0 ] || fail "forge lifetime: a held plan must not fail the run ($RC): $OUT"
  route_assert_kept slow "forge lifetime"
  assert_contains "$(route_line_of slow)" "did not answer within 3s" "forge lifetime: the plan's bound is not named"
  assert_contains "$(route_line_of slow)" "supersedence route --pr 7" "forge lifetime: a timed-out route plan does not name the route and the PR"
  assert_equals "" "$(route_calls_for slow)" "forge lifetime: the copy reached the driver while the forge read was unfinished"
  [ -s "$W/forge/gh.pids" ] || fail "forge lifetime: the fake forge never ran"
  forge_reads_are_gone "$W/forge" 3 || { for pid in $FORGE_ALIVE; do kill -s KILL "$pid" 2>/dev/null; done; fail "forge lifetime: the forge read outlived the sweep's plan bound (pid$FORGE_ALIVE)"; }
  printf 'forge lifetime: plan bound 3s, forge bound 25s: kept, no driver call, forge pids %s gone within 3s of the sweep returning\n' "$(tr '\n' ' ' < "$W/forge/gh.pids")"
  route_world route-forge-stopped
  route_set_pr "$W/forge" 7 HANG
  route_copy stopped 7
  (
    FM_COPY_SWEEP_PLAN_TIMEOUT=120 FM_TEARDOWN_FORGE_TIMEOUT=120 FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" \
      sweep_cmd --apply > "$W/stopped.out" 2>&1
  ) &
  sweep=$!
  while [ ! -s "$W/forge/gh.pids" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$W/forge/gh.pids" ] || { kill "$sweep" 2>/dev/null; fail "forge lifetime: the forge read never started"; }
  kill -s TERM "$sweep"
  wait "$sweep" 2>/dev/null || true
  forge_reads_are_gone "$W/forge" 3 || { for pid in $FORGE_ALIVE; do kill -s KILL "$pid" 2>/dev/null; done; fail "forge lifetime: the forge read outlived a sweep stopped during the plan (pid$FORGE_ALIVE)"; }
  [ -e "$(copy_path stopped)" ] || fail "forge lifetime: a sweep stopped during the forge read removed the copy"
  assert_equals "" "$(route_calls_for stopped)" "forge lifetime: a stopped sweep reached the driver"
  printf 'forge lifetime: sweep stopped with TERM during the forge read: forge pids %s gone within 3s\n' "$(tr '\n' ' ' < "$W/forge/gh.pids")"
  route_world route-forge-fast
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy fast 7
  FM_COPY_SWEEP_PLAN_TIMEOUT=3 FM_TEARDOWN_FORGE_TIMEOUT=25 route_sweep --apply
  [ "$RC" = 0 ] || fail "forge lifetime control: the run failed ($RC): $OUT"
  route_assert_released fast "forge lifetime control"
  route_assert_calls fast 7 "forge lifetime control"
  pass "a forge read that is still running when the plan's bound passes or the sweep is stopped ends with the plan, the copy is held with no driver call, and a forge that answers at once still routes"
}

# R3: the driver's answer is the only authority and is read in its real shape.
# One world per stage keeps the run short: a control copy that is released and one
# copy per scripted answer.
test_the_routes_answers_are_read_in_their_real_shape_and_fail_closed() {
  local kind phrase line receipt
  local -a plan_kinds=(refuse two 'done' error unbound allowed-doc silent hang retain)
  local -a exec_kinds=(success-done blocked retained lie allowed-doc temporary)
  route_world route-plan-answers
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy ok 7
  for kind in "${plan_kinds[@]}"; do
    route_copy "plan-$kind" 7 "$kind"
  done
  FM_COPY_SWEEP_PLAN_TIMEOUT=2 FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  [ "$RC" = 0 ] || fail "plan answers: a held plan must not fail the run ($RC): $OUT"
  route_assert_released ok "plan answers"
  for kind in "${plan_kinds[@]}"; do
    case "$kind" in
      refuse) phrase="verification_stale_or_uncovered_paths" ;;
      error) phrase="PR state != MERGED" ;;
      unbound) phrase="cleanup_tip_unbound" ;;
      hang) phrase="did not answer within 2s" ;;
      retain) phrase="unique ignored files" ;;
      *) phrase="the plan did not answer with exit 3 and the driver's fifteen-key dry-run envelope" ;;
    esac
    route_assert_kept "plan-$kind" "plan $kind"
    line=$(route_line_of "plan-$kind")
    assert_contains "$line" "$phrase" "plan $kind: the driver's words or the failed shape are missing"
    assert_equals 1 "$(route_calls_for "plan-$kind" | wc -l | tr -d ' ')" "plan $kind: the driver was asked for more than the plan"
    assert_not_contains "$(route_calls_for "plan-$kind")" "--execute-cleanup" "plan $kind: the execute ran after a plan that did not allow"
    receipt="$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path "plan-$kind")" | shasum -a 256 | awk '{print $1}')"
    assert_absent "$receipt" "plan $kind: a receipt was written for a refused plan"
    case "$kind" in
      hang) ;;
      *) assert_contains "$line" "supersedence route (--pr 7)" "plan $kind: the refusal does not say the route was used" ;;
    esac
    printf 'plan answer %s: kept (HELD-LOCKED); driver calls: 1 (the plan); reason: %s\n' "$kind" "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 200) }')"
  done
  printf 'plan answer allowed (the dry-run envelope, exit 3): proceeds; the control copy was released\n'
  route_world route-execute-answers
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  for kind in "${exec_kinds[@]}"; do
    route_copy "x-$kind" 7 allowed "$kind"
  done
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  [ "$RC" = 1 ] || fail "execute answers: a refused execute must exit 1, got $RC: $OUT"
  for kind in "${exec_kinds[@]}"; do
    receipt="$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path "x-$kind")" | shasum -a 256 | awk '{print $1}')"
    assert_equals 2 "$(route_calls_for "x-$kind" | wc -l | tr -d ' ')" "execute $kind: the driver was not asked once to plan and once to execute"
    line=$(route_line_of "x-$kind")
    case "$kind" in
      success-done)
        route_assert_released "x-$kind" "execute $kind"
        assert_absent "$receipt" "execute $kind: a receipt survived a full release"
        ;;
      blocked | allowed-doc | lie)
        route_assert_kept "x-$kind" "execute $kind"
        assert_contains "$line" "FAILED" "execute $kind: not reported FAILED"
        assert_present "$receipt" "execute $kind: no receipt was kept for the copy"
        ;;
      retained)
        route_assert_kept "x-$kind" "execute $kind"
        assert_contains "$line" "KEPT" "execute $kind: a retained tree is KEPT"
        assert_not_contains "$line" "FAILED" "execute $kind: a retained tree is not a failure"
        assert_present "$receipt" "execute $kind: no receipt was kept for the retained tree"
        ;;
      temporary)
        route_assert_kept "x-$kind" "execute $kind"
        assert_contains "$OUT" "names this refusal temporary" "execute $kind: the temporary refusal was not recognised in the route's shape"
        assert_absent "$receipt" "execute $kind: a receipt was kept after a temporary refusal"
        ;;
    esac
    printf 'execute answer %s: %s\n' "$kind" "$(printf '%s' "$line" | awk -F '\t' '{ print $1 ": " substr($NF, 1, 200) }')"
    case "$kind" in
      success-done | lie) ;;
      *) printf '    route words: %s\n' "$(printf '%s' "$line" | grep -o 'supersedence route (--pr [0-9]*): .\{0,140\}' | head -1)" ;;
    esac
    case "$kind" in
      success-done | lie) ;;
      blocked) assert_contains "$line" "cleanup_tip_unbound" "execute $kind: the driver's reason is missing" ;;
      *) assert_contains "$(printf '%s\n' "$OUT" | grep -F "$(copy_path "x-$kind")" | head -n 3)" "supersedence route (--pr 7)" "execute $kind: the refusal does not say the route was used" ;;
    esac
  done
  # A route execute that leaves the copy present uses its release slot, as a plain
  # execute does; a temporary refusal that released nothing does not.
  for kind in lie temporary; do
    route_world "route-slot-$kind"
    route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
    route_copy ok 7
    route_copy "zrow" 7 allowed "$kind"
    FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 route_sweep --apply
    if [ "$kind" = lie ]; then
      assert_contains "$(route_line_of ok)" "DEFERRED" "slot $kind: an execute that left the copy present did not use its release slot"
    else
      route_assert_released ok "slot $kind"
    fi
  done
  pass "a route plan proceeds only on exit 3 with the dry-run envelope and a route execute releases only on exit 0 with the success envelope and a removed copy; every other answer keeps the copy with the driver's words and the route named, with the receipt and release slot as for a plain execute and the retained-tree and temporary-refusal rules unchanged"
}

# A refusal is temporary only in the driver's valid, non-contradictory shape: the
# --pr lane's BLOCKED envelope whose predicates_failed is an array that holds
# cleanup_gate, with worktree_removed false (_compact_envelope in the real driver
# prints a boolean there) and a recovery reason the driver names temporary. Any
# other shape is not proof that nothing was released, so the retention receipt
# stays (Main 010 F3). The first malformed kind is the reviewer's reproduction.
test_a_malformed_or_contradictory_temporary_refusal_keeps_the_retention_receipt() {
  local kind receipt line
  local -a kinds=(temporary-string temporary-string-kept temporary-removed temporary-removed-null temporary-not-requested temporary-branch-delete temporary-branch-reap)
  route_world route-temporary-shapes
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  for kind in "${kinds[@]}" temporary; do
    route_copy "x-$kind" 7 allowed "$kind"
  done
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  [ "$RC" = 1 ] || fail "temporary shapes: a refused execute must exit 1, got $RC: $OUT"
  for kind in "${kinds[@]}" temporary; do
    receipt="$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path "x-$kind")" | shasum -a 256 | awk '{print $1}')"
    line=$(printf '%s\n' "$OUT" | grep -F "$(copy_path "x-$kind")" | head -n 3)
    printf 'temporary shape %s: %s; receipt: %s\n' "$kind" "$(printf '%s' "$line" | head -n 1 | awk -F '\t' '{ print $1 ": " substr($NF, 1, 140) }')" "$([ -e "$receipt" ] && printf kept || printf cleared)"
    assert_equals 2 "$(route_calls_for "x-$kind" | wc -l | tr -d ' ')" "temporary shape $kind: the driver was not asked once to plan and once to execute"
    route_assert_kept "x-$kind" "temporary shape $kind"
    if [ "$kind" = temporary ]; then
      assert_absent "$receipt" "temporary shape $kind: the receipt of a valid temporary refusal was kept"
    else
      assert_present "$receipt" "temporary shape $kind: the retention receipt was cleared for a malformed or contradictory answer"
      assert_contains "$line" "FAILED" "temporary shape $kind: not reported FAILED"
    fi
  done
  # The message is printed once per recognised refusal and names the copy by a
  # shortened path, so it is counted over the whole output: only the control reads.
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -c 'names this refusal temporary')" "temporary shapes: a malformed answer was read as a temporary refusal, or the valid one was not"
  # A contradiction is refused by name: the reason says what the answer contradicts.
  assert_contains "$OUT" "cleanup_requested is false" "temporary shapes: the contradictory cleanup request is not named in the refusal"
  assert_contains "$OUT" "worktree_removed true while the state is BLOCKED" "temporary shapes: the contradictory removal claim is not named in the refusal"
  assert_contains "$OUT" "branch delete or reap decision while the state is BLOCKED" "temporary shapes: the contradictory branch decision is not named in the refusal"
  pass "only the valid temporary refusal (BLOCKED, predicates_failed an array with cleanup_gate, worktree_removed false, a lease conflict) clears the retention receipt; a string predicates_failed, a removal claim or a null worktree_removed keeps the receipt and reports a failure"
}

# A retained-payload signal anywhere in the driver's answer keeps the copy: on the
# --pr route a stderr line that carries cleanup_ignored_payload_archived_tree_retained
# beats a valid temporary envelope on stdout, so the receipt stays, the copy is KEPT
# and no later sweep asks the driver again (Main 011 N1). The control is the valid
# temporary refusal with a quiet stderr: its receipt goes and the next sweep plans it again.
test_a_retained_payload_signal_on_stderr_beats_the_temporary_retry() {
  local line receipt calls
  route_world route-retained-stderr
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy x-stderr 7 allowed temporary-retained-stderr
  route_copy x-control 7 allowed temporary
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  receipt="$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path x-stderr)" | shasum -a 256 | awk '{print $1}')"
  route_assert_kept x-stderr "retained stderr"
  route_assert_kept x-control "retained stderr control"
  assert_present "$receipt" "retained stderr: the receipt was cleared for a copy whose answer shows a retained tree"
  assert_equals 1 "$(printf '%s\n' "$OUT" | grep -c 'names this refusal temporary')" "retained stderr: only the control may read as a temporary refusal"
  line=$(route_line_of x-stderr)
  assert_contains "$line" "KEPT" "retained stderr: a retained tree is KEPT"
  assert_equals 2 "$(route_calls_for x-stderr | wc -l | tr -d ' ')" "retained stderr: wanted one plan and one execute"
  assert_equals 2 "$(route_calls_for x-control | wc -l | tr -d ' ')" "retained stderr control: wanted one plan and one execute"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  calls=$(route_calls_for x-stderr | wc -l | tr -d ' ')
  assert_equals 2 "$calls" "retained stderr: a later sweep asked the driver again (calls $calls)"
  assert_present "$receipt" "retained stderr: the receipt went on the later sweep"
  assert_equals 4 "$(route_calls_for x-control | wc -l | tr -d ' ')" "retained stderr control: the valid temporary refusal was not planned again"
  printf 'retained stderr: KEPT, receipt kept, driver calls %s after two sweeps; control: temporary, planned again, calls %s\n' "$calls" "$(route_calls_for x-control | wc -l | tr -d ' ')"
  pass "a retained-tree signal on stderr only beats a valid temporary envelope on stdout: the copy is KEPT, its receipt stays and no later sweep asks the driver, while the valid temporary refusal is planned again"
}

# A forge read that times out ends with its descendants, not only its direct child
# (Main 011 N3): the fake forge starts a sleeper child and waits, the bound is one
# second, and nothing it started may survive, at the plan and at the execute (the
# second read, after a plan that succeeded). The control reads a fast forge.
test_a_forge_read_that_times_out_leaves_no_descendant_running() {
  local line pid
  route_world route-forge-child-plan
  route_set_pr "$W/forge" 7 HANGCHILD
  route_copy slow 7
  FM_TEARDOWN_FORGE_TIMEOUT=1 FM_COPY_SWEEP_PLAN_TIMEOUT=60 route_sweep --apply
  [ "$RC" = 0 ] || fail "forge child (plan): a held plan must not fail the run ($RC): $OUT"
  route_assert_kept slow "forge child (plan)"
  assert_contains "$(route_line_of slow)" "forge read of PR 7 timed out" "forge child (plan): the timeout is not named"
  assert_equals "" "$(route_calls_for slow)" "forge child (plan): the copy reached the driver"
  assert_equals 2 "$(wc -l < "$W/forge/gh.pids" | tr -d ' ')" "forge child (plan): the fake forge did not record itself and its child"
  forge_reads_are_gone "$W/forge" 3 || { for pid in $FORGE_ALIVE; do kill -s KILL "$pid" 2>/dev/null; done; fail "forge child (plan): the timed-out read left a descendant running (pid$FORGE_ALIVE)"; }
  printf 'forge child (plan): forge bound 1s: kept, no driver call, pids %s all gone\n' "$(tr '\n' ' ' < "$W/forge/gh.pids")"
  route_world route-forge-child-execute
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy late 7
  # shellcheck disable=SC2016 # the hook expands its own variable when it runs
  printf '#!/usr/bin/env bash\nprintf "HANGCHILD\\n" > "%s/pr-7"\n' "$W/forge" > "$W/ans/late/plan.hook"
  FM_TEARDOWN_FORGE_TIMEOUT=1 FM_COPY_SWEEP_PLAN_TIMEOUT=60 route_sweep --apply
  route_assert_kept late "forge child (execute)"
  line=$(route_line_of late)
  assert_contains "$line" "forge read of PR 7 timed out" "forge child (execute): the timeout is not named"
  assert_equals 1 "$(route_calls_for late | grep -c .)" "forge child (execute): wanted the plan only, got: $(route_calls_for late)"
  assert_not_contains "$(route_calls_for late)" "--execute-cleanup" "forge child (execute): the execute ran after a read that timed out"
  assert_equals 2 "$(wc -l < "$W/forge/gh.pids" | tr -d ' ')" "forge child (execute): the fake forge did not record itself and its child"
  forge_reads_are_gone "$W/forge" 3 || { for pid in $FORGE_ALIVE; do kill -s KILL "$pid" 2>/dev/null; done; fail "forge child (execute): the timed-out read left a descendant running (pid$FORGE_ALIVE)"; }
  printf 'forge child (execute): second read timed out after a plan that succeeded: kept, one driver call (the plan), pids %s all gone\n' "$(tr '\n' ' ' < "$W/forge/gh.pids")"
  route_world route-forge-child-control
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy fast 7
  FM_TEARDOWN_FORGE_TIMEOUT=5 route_sweep --apply
  route_assert_released fast "forge child control"
  route_assert_calls fast 7 "forge child control"
  pass "a forge read that times out at the plan or at the execute leaves neither its direct child nor a descendant running, and a fast forge still routes"
}

# A records file that exists but cannot be read says nothing about which copy it
# names, so every locked copy is held, named or not, and the driver is not asked;
# the plain call for a copy with no record needs a file that can be read, or none.
# Control: the held copies route again once the file reads.
test_a_records_file_that_cannot_be_read_holds_every_locked_copy_before_the_driver() {
  local variant name line
  for variant in directory unreadable; do
    if [ "$variant" = unreadable ] && [ "$(id -u)" = 0 ]; then
      printf 'records file %s: skipped (root reads any file)\n' "$variant"
      continue
    fi
    route_world "route-carrier-$variant"
    route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
    route_copy named 7
    add_copy plain
    route_lock_dead plain
    route_script_row "$W" plain allowed success 7
    cp "$HOMED/data/supersedence-records.tsv" "$W/records.saved"
    case "$variant" in
      directory) rm -f "$HOMED/data/supersedence-records.tsv"; mkdir "$HOMED/data/supersedence-records.tsv" ;;
      unreadable) chmod 000 "$HOMED/data/supersedence-records.tsv" ;;
    esac
    route_sweep --apply
    route_assert_kept named "records file $variant"
    route_assert_kept plain "records file $variant"
    for name in named plain; do
      line=$(route_line_of "$name")
      assert_contains "$line" "supersedence records file" "records file $variant: the reason for $name does not name the records file"
      assert_equals "" "$(route_calls_for "$name")" "records file $variant: $name reached the driver: $(route_calls_for "$name")"
    done
    printf 'records file %s: both copies kept, no driver call; reason: %s\n' "$variant" "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 200) }')"
    case "$variant" in
      directory) rmdir "$HOMED/data/supersedence-records.tsv" ;;
      unreadable) chmod 600 "$HOMED/data/supersedence-records.tsv" ;;
    esac
    cp "$W/records.saved" "$HOMED/data/supersedence-records.tsv"
    route_sweep --apply
    route_assert_released named "records file $variant control"
    route_assert_kept plain "records file $variant control"
    assert_equals "--cleanup-worktree $(copy_path plain)" "$(route_calls_for plain)" "records file $variant control: the plain copy was not asked the plain plan once the file read again"
  done
  pass "a records file that is a directory or unreadable holds every locked copy, named or not, with no driver call, and the valid copy releases once the file reads"
}

# A row that names the copy at another tip holds it whether the row sits before or
# after the valid one (R2: a record that names the copy and fails its tip binding
# keeps it). Control: a copy with only its valid row routes.
test_a_row_for_another_tip_holds_the_copy_before_or_after_its_valid_row() {
  local name other tip order line
  other=$(printf '%040d' 0 | tr 0 b)
  route_world route-stale-rows
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy valid-only 7
  for order in stale-first stale-after stale-only; do
    add_copy "$order"
    route_lock_dead "$order"
    tip=$(route_tip "$order")
    route_write_profile "$W/profiles/$order.json" 7 "$tip"
    route_script_row "$W" "$order" allowed success 7
    case "$order" in
      stale-first) route_record "$order" 7 "$other" "$W/profiles/$order.json"; route_record "$order" 7 "$tip" "$W/profiles/$order.json" ;;
      stale-after) route_record "$order" 7 "$tip" "$W/profiles/$order.json"; route_record "$order" 7 "$other" "$W/profiles/$order.json" ;;
      stale-only) route_record "$order" 7 "$other" "$W/profiles/$order.json" ;;
    esac
  done
  route_sweep --apply
  route_assert_released valid-only "stale rows control"
  route_assert_calls valid-only 7 "stale rows control"
  for order in stale-first stale-after stale-only; do
    route_assert_kept "$order" "$order"
    line=$(route_line_of "$order")
    assert_contains "$line" "a row for another tip of the same path holds the copy" "$order: the reason does not name the stale row"
    assert_equals "" "$(route_calls_for "$order")" "$order: the copy reached the driver: $(route_calls_for "$order")"
    printf 'stale rows %s: kept, no driver call; reason: %s\n' "$order" "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 200) }')"
  done
  pass "a row for another tip of the same path holds the copy before or after its valid row, or alone, with no driver call, while a copy with only its valid row routes"
}

# A record that changes while the forge is read holds the copy: the record is read
# again after the read and must bind the same PR, profile and tip. The fake forge
# appends an empty row for the copy on its second read of the PR (the execute's), after
# the plan has proved the record and before the execute asks the driver.
test_a_record_that_changes_while_the_forge_is_read_holds_the_copy() {
  local row line
  route_world route-record-moves
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy steady 7
  route_copy moving 8
  row=$(printf '%s\t%s\t\t' "$(copy_path moving)" "$(route_tip moving)")
  route_set_pr_append "$W/forge" 8 2 "$HOMED/data/supersedence-records.tsv" "$row" "$ROUTE_MERGE"
  route_sweep --apply
  route_assert_released steady "record moves control"
  route_assert_calls steady 7 "record moves control"
  route_assert_kept moving "record moves"
  line=$(route_line_of moving)
  assert_contains "$line" "was not released: its supersedence record cannot be used" "record moves: the stopped execute is not named"
  assert_contains "$line" "leaves the PR or the profile empty" "record moves: the changed record is not named"
  assert_equals 1 "$(route_calls_for moving | grep -c .)" "record moves: wanted the plan only, got: $(route_calls_for moving)"
  assert_not_contains "$(route_calls_for moving)" "--execute-cleanup" "record moves: the execute reached the driver after the record changed"
  printf 'record moves: kept at the execute with one driver call (the plan); reason: %s\n' "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 200) }')"
  pass "a row written for the copy while the execute's forge read ran holds the copy with no execute call, while a record that stays put routes"
}

# R1 and R2 name a decimal integer, not a nine-digit one: a PR number of ten or more
# digits routes like any other, and a zero or a leading zero still does not.
test_a_decimal_pr_number_of_any_length_routes_and_a_zero_or_a_leading_zero_does_not() {
  local name line
  route_world route-pr-digits
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_set_pr "$W/forge" 1000000000 MERGED "$ROUTE_MERGE"
  route_set_pr "$W/forge" 123456789012345 MERGED "$ROUTE_MERGE"
  route_copy pr-seven 7
  route_copy pr-ten 1000000000
  route_copy pr-fifteen 123456789012345
  for name in pr-zero pr-leading-zero; do
    add_copy "$name"
    route_lock_dead "$name"
    route_write_profile "$W/profiles/$name.json" 7 "$(route_tip "$name")"
    route_script_row "$W" "$name" allowed success 7
  done
  route_record pr-zero 0 "$(route_tip pr-zero)" "$W/profiles/pr-zero.json"
  route_record pr-leading-zero 007 "$(route_tip pr-leading-zero)" "$W/profiles/pr-leading-zero.json"
  route_sweep --apply
  route_assert_released pr-seven "pr digits"
  route_assert_released pr-ten "pr digits"
  route_assert_released pr-fifteen "pr digits"
  route_assert_calls pr-ten 1000000000 "pr digits"
  route_assert_calls pr-fifteen 123456789012345 "pr digits"
  for name in pr-zero pr-leading-zero; do
    route_assert_kept "$name" "pr digits"
    line=$(route_line_of "$name")
    assert_contains "$line" "is not a decimal integer" "pr digits: $name is not named as no decimal integer"
    assert_equals "" "$(route_calls_for "$name")" "pr digits: $name reached the driver"
  done
  pass "a merged PR with ten or fifteen digits routes like PR 7, and PR 0 and PR 007 are held with no driver call"
}

# The landing branch is the remote's own default (or the task's recorded base, when
# it agrees), read from the remote itself. The clone's origin/HEAD is a local hint
# that is never trusted: absent or pointing at release, it decides nothing. Each
# world has one copy; the controls route a merge on the remote's default, and the
# hold is a merge that is not on the remote's default release.
test_a_local_origin_head_never_decides_the_landing_branch_and_the_remotes_default_does() {
  local variant line
  for variant in main-control no-origin-head stale-hint-release default-release-on-release default-release-off-release; do
    route_world "route-landing-$variant"
    case "$variant" in
      main-control) ;;
      no-origin-head) git -C "$SLOT" remote set-head origin -d >/dev/null ;;
      stale-hint-release)
        git -C "$SLOT" push -q origin "$ROUTE_MERGE^:refs/heads/release"
        git -C "$SLOT" fetch -q origin
        git -C "$SLOT" remote set-head origin release >/dev/null
        ;;
      default-release-off-release)
        git -C "$SLOT" push -q origin "$ROUTE_MERGE^:refs/heads/release"
        git -C "$SLOT" fetch -q origin
        git -C "$W/origin.git" symbolic-ref HEAD refs/heads/release
        ;;
      default-release-on-release)
        git -C "$SLOT" push -q origin "$ROUTE_MERGE:refs/heads/release"
        git -C "$SLOT" fetch -q origin
        git -C "$W/origin.git" symbolic-ref HEAD refs/heads/release
        ;;
    esac
    route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
    route_copy only 7
    route_sweep --apply
    case "$variant" in
      default-release-off-release)
        route_assert_kept only "landing $variant"
        line=$(route_line_of only)
        assert_equals "" "$(route_calls_for only)" "landing $variant: the copy reached the driver: $(route_calls_for only)"
        assert_contains "$line" "is not on origin/release (not landed)" "landing $variant: the off-default merge is not named"
        printf 'landing %s: kept, no driver call; reason: %s\n' "$variant" "$(printf '%s' "$line" | awk -F '\t' '{ print substr($NF, 1, 200) }')"
        ;;
      *)
        route_assert_released only "landing $variant"
        route_assert_calls only 7 "landing $variant"
        printf 'landing %s: released by the route\n' "$variant"
        ;;
    esac
  done
  pass "a merge commit counts as landed only on the branch the remote itself names as its default: no local origin/HEAD, or one that names release while the remote's default is main, changes nothing and a merge on main routes; a remote default of release routes a merge on release and holds a merge that is not on it, with no driver call"
}

# A forge read whose parent exits at once while a descendant keeps its output open
# ends with the read: nothing it started survives, the read does not wait for the
# descendant, and no answer arrives after the bound. At the plan the bound is short
# against the descendant's life; at the execute the driver's hook checks that the
# descendant is gone and the time between the read and the execute is far short of
# the descendant's life. The fast-forge control is the control of the cases before it.
test_a_forge_read_whose_parent_exits_at_once_leaves_no_descendant_and_does_not_wait_for_one() {
  local t0 t1 pid
  route_world route-early-plan
  route_set_pr "$W/forge" 7 EARLYEXIT "$ROUTE_MERGE"
  route_copy early 7
  ROUTE_EARLYEXIT_LIFE=30 FM_COPY_SWEEP_PLAN_TIMEOUT=12 FM_TEARDOWN_FORGE_TIMEOUT=8 route_sweep --apply
  [ "$RC" = 0 ] || fail "early exit (plan): the run failed ($RC): $OUT"
  [ -s "$W/forge/gh.pids" ] || fail "early exit (plan): the fake forge never started its descendant"
  forge_reads_are_gone "$W/forge" 2 || { for pid in $FORGE_ALIVE; do kill -s KILL "$pid" 2>/dev/null; done; fail "early exit (plan): the read left a descendant running (pid$FORGE_ALIVE)"; }
  route_assert_released early "early exit (plan)"
  route_assert_calls early 7 "early exit (plan)"
  printf 'early exit (plan): plan bound 12s, descendant life 30s: released by the route, descendant pids %s gone\n' "$(tr '\n' ' ' < "$W/forge/gh.pids")"
  route_world route-early-execute
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy late 7
  # shellcheck disable=SC2016 # the hooks expand their own variables when they run
  printf '#!/usr/bin/env bash\nprintf "EARLYEXIT\\nMERGED\\t%%s\\t%%s\\n" "%s" "fm/pr-7-head" > "%s/pr-7"\n' "$ROUTE_MERGE" "$W/forge" > "$W/ans/late/plan.hook"
  cat > "$W/ans/late/exec.hook" <<HOOK
#!/usr/bin/env bash
n=0
while [ "\$n" -lt 20 ]; do
  alive=
  for p in \$(cat "$W/forge/gh.pids" 2>/dev/null); do kill -0 "\$p" 2>/dev/null && alive="\$alive \$p"; done
  [ -z "\$alive" ] && break
  sleep 0.1
  n=\$((n + 1))
done
[ -z "\$alive" ] || { echo "forge descendant alive at the execute:\$alive" >&2; exit 1; }
date +%s > "$W/exec.time"
HOOK
  ROUTE_EARLYEXIT_LIFE=30 FM_TEARDOWN_FORGE_TIMEOUT=8 route_sweep --apply
  [ -s "$W/exec.time" ] || fail "early exit (execute): the execute hook did not run clean (a descendant of the read was alive when the driver ran): $OUT"
  t0=$(sed -n 1p "$W/forge/gh.times")
  t1=$(cat "$W/exec.time")
  [ $((t1 - t0)) -le 18 ] || fail "early exit (execute): the execute began $((t1 - t0))s after the read, so the read waited for its descendant (life 30s)"
  forge_reads_are_gone "$W/forge" 2 || { for pid in $FORGE_ALIVE; do kill -s KILL "$pid" 2>/dev/null; done; fail "early exit (execute): the read left a descendant running (pid$FORGE_ALIVE)"; }
  route_assert_released late "early exit (execute)"
  printf 'early exit (execute): descendant life 30s: the driver ran %ss after the read, no descendant alive at the execute\n' "$((t1 - t0))"
  route_world route-early-control
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy fast 7
  FM_TEARDOWN_FORGE_TIMEOUT=8 route_sweep --apply
  route_assert_released fast "early exit control"
  route_assert_calls fast 7 "early exit control"
  pass "a forge read whose parent exits at once while a descendant holds its output ends with the read at the plan and at the execute: no descendant survives, the execute is not delayed by it, and a fast forge still routes"
}

# R3: a route execute that claims success uses a release slot even when the copy and
# its lock are untouched, so the per-run cap counts it (the claim is that the driver
# removed a locked copy). Cap 1: the first copy's success claim leaves everything in
# place; the second eligible copy must wait for the next run. The control is a
# temporary refusal that released nothing: it uses no slot and the second copy goes.
test_a_route_execute_that_claims_success_and_leaves_the_copy_uses_a_release_slot() {
  local line
  route_world route-intact-slot
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy z-claims 7 allowed intact
  route_copy a-second 7
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 route_sweep --apply
  route_assert_kept z-claims "intact claim"
  assert_contains "$(route_line_of z-claims)" "still present or registered after its removal" "intact claim: the unremoved copy is not reported"
  assert_equals 2 "$(route_calls_for z-claims | wc -l | tr -d ' ')" "intact claim: wanted one plan and one execute"
  route_assert_kept a-second "intact claim"
  line=$(route_line_of a-second)
  assert_contains "$line" "per-run cap: 1 locked release slots used" "intact claim: the second copy was not deferred by the cap"
  assert_equals "" "$(route_calls_for a-second)" "intact claim: the second copy reached the driver after the cap was used: $(route_calls_for a-second)"
  printf 'intact claim: cap 1: the success claim used the slot; second copy deferred with no driver call\n'
  route_world route-temporary-slot
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy z-temp 7 allowed temporary
  route_copy a-second 7
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=1 route_sweep --apply
  route_assert_kept z-temp "temporary control"
  route_assert_released a-second "temporary control"
  route_assert_calls a-second 7 "temporary control"
  printf 'temporary control: cap 1: a refusal that released nothing used no slot; second copy released\n'
  pass "a route execute that claims success uses a release slot even when the copy and its lock are untouched, and a temporary refusal that released nothing uses none"
}

# The two facts the hold matrix needs before it trusts a comparison: the prior
# receipt of the retained-receipt class exists (the setup must have made it), and
# the driver log holds no call of any kind for a held copy. Each returns a reason
# instead of failing so the control below can show it fails (Main 010 F8).
ROUTE_HOLD_WHY=
route_hold_receipt_exists() {  # <copy-name>
  local receipt
  receipt=$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path "$1")" | shasum -a 256 | awk '{print $1}')
  ROUTE_HOLD_WHY=
  [ -f "$receipt" ] && return 0
  ROUTE_HOLD_WHY="the prior receipt $receipt does not exist"
  return 1
}

route_hold_driver_silent() {
  ROUTE_HOLD_WHY=
  [ ! -s "$W/closeout.log" ] && return 0
  ROUTE_HOLD_WHY="the driver was invoked: $(head -n 2 "$W/closeout.log" | tr '\n' ' ')"
  return 1
}

test_the_hold_matrix_checks_fail_without_a_receipt_and_after_any_driver_call() {
  local receipt
  route_world route-hold-checks
  route_copy held 7
  route_hold_receipt_exists held && fail "hold checks: a copy with no receipt passed the receipt check"
  assert_contains "$ROUTE_HOLD_WHY" "does not exist" "hold checks: the missing receipt is not named"
  route_hold_driver_silent || fail "hold checks: a world with no driver call failed the silence check: $ROUTE_HOLD_WHY"
  printf '%s|--cleanup-worktree %s\n' "$SLOT" "$(copy_path held)" > "$W/closeout.log"
  route_hold_driver_silent && fail "hold checks: a plain driver call passed the silence check"
  printf '%s|--cleanup-worktree %s --pr 7\n' "$SLOT" "$(copy_path held)" > "$W/closeout.log"
  route_hold_driver_silent && fail "hold checks: a route driver call passed the silence check"
  : > "$W/closeout.log"
  route_hold_driver_silent || fail "hold checks: an empty driver log failed the silence check: $ROUTE_HOLD_WHY"
  receipt=$HOMED/data/copy-sweep/retained/$(printf '%s' "$(copy_path held)" | shasum -a 256 | awk '{print $1}')
  mkdir -p "$(dirname "$receipt")"
  printf 'x\n' > "$receipt"
  route_hold_receipt_exists held || fail "hold checks: a present receipt failed the receipt check: $ROUTE_HOLD_WHY"
  pass "the hold matrix's receipt check fails for a copy with no receipt, its silence check fails after a plain or a route driver call, and both pass in their good states"
}

# R4: every hold before the driver is asked still holds with a valid record.
test_a_valid_record_releases_no_copy_that_the_sweep_holds_before_the_driver() {
  local class with without state_dir
  for class in dirty unpushed live orphan live-launcher no-interpreter retained-receipt; do
    route_world "route-hold-$class"
    route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
    route_copy held 7
    state_dir=$HOMED/state
    case "$class" in
      dirty) printf 'scratch\n' > "$(copy_path held)/untracked.txt" ;;
      unpushed)
        printf 'y\n' > "$(copy_path held)/local.txt"
        git -C "$(copy_path held)" add local.txt
        git -C "$(copy_path held)" commit -qm local-only
        ;;
      live) fm_write_meta "$state_dir/live-task.meta" "worktree=$(copy_path held)" "kind=ship" ;;
      orphan) printf 'garbage\n' > "$(copy_path held)/.git" ;;
      live-launcher)
        git -C "$SLOT" worktree unlock "$(copy_path held)"
        (cd "$W" && exec sleep 600) &
        LIVE_PID=$!
        disown "$LIVE_PID" 2>/dev/null || true
        git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$LIVE_PID launcher=$LIVE_PID" "$(copy_path held)"
        ;;
      retained-receipt)
        route_script_row "$W" held allowed blocked 7
        route_sweep --apply
        # The receipt is the held class: it must exist before the two runs are
        # compared, or the comparison holds nothing (Main 010 F8).
        route_hold_receipt_exists held || fail "hold $class: $ROUTE_HOLD_WHY"
        rm -f "$W/closeout.log"
        ;;
    esac
    if [ "$class" = no-interpreter ]; then
      FM_TEARDOWN_VERNANT_PYTHON="$W/no-such-python" run_sweep --apply
    else
      route_sweep --apply
    fi
    # A live launcher's reason carries its start age, which ticks between the two
    # runs; the age is the clock, not the hold, so it is masked before comparing.
    with=$(route_line_of held | sed 's/start age=[0-9][0-9]*s/start age=<n>s/')
    mv "$HOMED/data/supersedence-records.tsv" "$HOMED/data/supersedence-records.off"
    if [ "$class" = no-interpreter ]; then
      FM_TEARDOWN_VERNANT_PYTHON="$W/no-such-python" run_sweep --apply
    else
      route_sweep --apply
    fi
    without=$(route_line_of held | sed 's/start age=[0-9][0-9]*s/start age=<n>s/')
    [ -n "$with" ] || fail "hold $class: the copy is missing from the report"
    assert_equals "$without" "$with" "hold $class: a valid record changed how the copy is held"
    printf 'hold %s: with a record: %s\n' "$class" "$(printf '%s' "$with" | awk -F '\t' '{ print $1 ": " substr($NF, 1, 160) }')"
    printf 'hold %s: without a record: %s\n' "$class" "$(printf '%s' "$without" | awk -F '\t' '{ print $1 ": " substr($NF, 1, 160) }')"
    route_assert_kept held "hold $class"
    # A held copy is never asked: no driver call of any kind, plain or route, in
    # either run (the log is empty or absent), not just no --pr.
    route_hold_driver_silent || fail "hold $class: $ROUTE_HOLD_WHY"
    if [ "$class" = retained-receipt ]; then
      route_hold_receipt_exists held || fail "hold $class: the run cleared the receipt it was holding on: $ROUTE_HOLD_WHY"
    fi
    [ -z "${LIVE_PID:-}" ] || { kill "$LIVE_PID" 2>/dev/null || true; LIVE_PID=; }
  done
  pass "a dirty, unpushed, live-task, orphaned, live-launcher, no-interpreter or retained-receipt copy is held exactly as it is with no record, and the route never reaches the driver for it"
}

# R5: the recorded cases. The staged d7 table is private Vernant data and is read
# in place, never copied into this repository, so CI (which does not have it)
# skips the case and says so. Every driver answer here is scripted: reduced
# evidence about Firstmate's routing and pass-through, not about the driver, and
# the sandbox commits are generated, not the original historical ones.
test_the_recorded_cases_are_decided_by_their_records_and_the_drivers_scripted_answers() {
  local cases rows counts num tip cls pr state kind own name line label expect_released=0 expect_never=0 merged_kept=0
  route_staged_cases_gate || return 0
  cases=$FM_SUPERSEDENCE_CASES
  rows=$(route_table_rows "$cases")
  counts=$(route_table_counts "$rows")
  assert_equals "5/4/16/1" "$counts" "table: the staged table's class counts are not 5 twins, 4 ancestors, 16 closed-unmerged and 1 open"
  assert_equals 27 "$(printf '%s\n' "$rows" | grep -c .)" "table: the rows are not the 26 table rows and the PR 3446 twin"
  route_world route-table
  : > "$HOMED/data/supersedence-records.tsv"
  # R2(h) decides the content of every merged row. The copies start from the world's
  # merge commit: an ancestor row stays there (an empty net change), every other row
  # adds its own file, and the final merge commit carries the file of each twin row
  # (identical entry) and lacks the file of every other row.
  local -a twins=() ancestors=()
  local base_commit anc_tip
  base_commit=$ROUTE_MERGE
  # One generated commit per ancestor row, each a real ancestor of the landed tip (Main 1887).
  while IFS=$'\t' read -r num tip cls pr state kind own; do
    [ "$cls" != "other (history)" ] || ancestors+=("row-$num")
  done <<< "$rows"
  route_make_ancestor_commits ${ancestors[@]+"${ancestors[@]}"}
  while IFS=$'\t' read -r num tip cls pr state kind own; do
    name="row-$num"
    if [ "$cls" = "other (history)" ]; then
      anc_tip=$(printf '%s\n' "$ROUTE_ANCESTOR_TIPS" | sed -n "s/^$name=//p")
      git -C "$SLOT" worktree add -q -b "fm/$name" "$(copy_path "$name")" "$anc_tip"
    else
      git -C "$SLOT" worktree add -q -b "fm/$name" "$(copy_path "$name")" "$base_commit"
      printf '%s\n' "$name" > "$(copy_path "$name")/$name.txt"
      git -C "$(copy_path "$name")" add "$name.txt"
      git -C "$(copy_path "$name")" commit -qm "$name"
      [ "$kind" != accept ] || twins+=("$name")
    fi
    git -C "$(copy_path "$name")" push -q origin "fm/$name"
  done <<< "$rows"
  for name in ${twins[@]+"${twins[@]}"}; do
    printf '%s\n' "$name" > "$SLOT/$name.txt"
    git -C "$SLOT" add -- "$name.txt"
  done
  git -C "$SLOT" commit -q --allow-empty -m "the merge commit the twin rows' PRs carry"
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" fetch -q origin
  ROUTE_MERGE=$(git -C "$SLOT" rev-parse HEAD)
  while IFS=$'\t' read -r num tip cls pr state kind own; do
    name="row-$num"
    route_lock_dead "$name"
    route_write_profile "$W/profiles/$name.json" "$pr" "$(route_tip "$name")"
    case "$state" in
      MERGED) route_set_pr "$W/forge" "$pr" MERGED "$ROUTE_MERGE" ;;
      *) route_set_pr "$W/forge" "$pr" "$state" "" ;;
    esac
    if [ "$kind" = accept ]; then
      route_script_row "$W" "$name" allowed success "$pr"
    elif [ "$state" = MERGED ]; then
      # The contract's allowing fake: the merged-nearest reject is kept by the content proof although the driver would allow.
      route_script_row "$W" "$name" allowed success "$pr"
    else
      route_script_row "$W" "$name" allowed success "$pr"
    fi
  done <<< "$rows"
  # (i) with no record: every row is asked as before and refused with the base reason.
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  while IFS=$'\t' read -r num tip cls pr state kind own; do
    name="row-$num"
    label="row $num (tip $tip, class $cls, PR $pr $state, $kind)"
    route_assert_kept "$name" "$label without a record"
    assert_equals "--cleanup-worktree $(copy_path "$name")" "$(route_calls_for "$name")" "$label: the call with no record is not the base call"
    assert_contains "$(route_line_of "$name")" "verification_stale_or_uncovered_paths" "$label: the base reason is missing"
    printf 'table: %s: no record -> kept, plain call, base reason\n' "$label"
  done <<< "$rows"
  # (ii) with a record naming the row's PR.
  rm -f "$W/closeout.log"
  while IFS=$'\t' read -r num tip cls pr state kind own; do
    name="row-$num"
    route_record "$name" "$pr" "$(route_tip "$name")" "$W/profiles/$name.json"
  done <<< "$rows"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  while IFS=$'\t' read -r num tip cls pr state kind own; do
    name="row-$num"
    label="row $num (tip $tip, class $cls, PR $pr $state, $kind)"
    if [ "$kind" = accept ]; then
      route_assert_released "$name" "$label with a record"
      route_assert_calls "$name" "$pr" "$label"
      expect_released=$((expect_released + 1))
      printf 'table: %s: record -> released by the route (scripted allowing envelopes)\n' "$label"
    elif [ "$state" = MERGED ]; then
      route_assert_kept "$name" "$label with a record"
      assert_equals "" "$(route_calls_for "$name")" "$label: a copy whose lines the merge commit lacks reached the driver: $(route_calls_for "$name")"
      assert_contains "$(route_line_of "$name")" "is not proved landed" "$label: the content proof's refusal is not named"
      merged_kept=$((merged_kept + 1))
      if [ "$own" = no ]; then
        printf 'table: %s: record naming the nearest merged PR (misattributed-record negative) -> kept by the content proof, driver never called\n' "$label"
      else
        printf 'table: %s: record -> kept by the content proof, driver never called\n' "$label"
      fi
    else
      route_assert_kept "$name" "$label with a record"
      assert_equals "" "$(route_calls_for "$name")" "$label: a $state PR reached the driver"
      assert_contains "$(route_line_of "$name")" "as $state, not MERGED" "$label: the forge state is not named"
      expect_never=$((expect_never + 1))
      printf 'table: %s: record -> kept by the forge check, driver never called\n' "$label"
    fi
  done <<< "$rows"
  assert_equals 10 "$expect_released" "table: not every twin and ancestor row was released"
  assert_equals 9 "$merged_kept" "table: not every merged-nearest reject row was kept by the content proof"
  assert_equals 8 "$expect_never" "table: not every closed or open reject row was kept before the driver"
  pass "the staged cases: 5 twins, 4 ancestors and the PR 3446 twin are released through the route; 9 merged-nearest reject rows are kept by the content proof and 8 closed or open rows by the forge check, each with or without a record and none reaching the driver by the route (reduced evidence: scripted driver answers, generated sandbox commits)"
}

# --- contract r14 checks of the route (library-level and sweep-level) ---------
# The owner (bin/fm-teardown-nested-lib.sh) is exercised in a bash of its own, with
# the libraries it needs sourced, against throwaway repositories and the scripted
# stand-ins above. FM_ROUTE_LIB_DIR points the cases at another bin/ tree (the base
# tree, to show a case is red there); a sweep case does the same with FM_COPY_SWEEP_BIN.
ROUTE_LIB_DIR=${FM_ROUTE_LIB_DIR:-$ROOT/bin}

# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
route_lib() {  # <snippet>: runs under bash with the route libraries sourced
  local pre='set -u; for f in fm-wake-lib fm-lock-lib fm-project-lock-lib fm-task-copy-lib fm-refuse-lib fm-teardown-nested-lib fm-pr-lib fm-timeout-lib; do . "$ROUTE_LIB_DIR/$f.sh" || exit 90; done;'
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
    PATH="$FAKEBIN:$ORIGINAL_PATH" FAKE_REAL_GIT="$REAL_GIT" FAKE_REAL_RM="$REAL_RM" \
    FAKE_GIT_LOG="${W:-$TMP_ROOT}/git.log" FAKE_RM_LOG="${W:-$TMP_ROOT}/rm.log" \
    FM_HOME="${HOMED:-$TMP_ROOT/nohome}" ROUTE_LIB_DIR="$ROUTE_LIB_DIR" \
    bash -c "$pre
$1"
}

# route_content_fixture <name> <file> <base> <tip> <merge>: one repository with the
# base commit B on main, the copy's tip T on branch tip and the merged result M on
# branch merged, both made from B. Contents are printf %b strings. Sets CR, CT, CM.
route_content_fixture() {
  CR="$TMP_ROOT/content-$1"
  rm -rf "$CR"
  git init -q -b main "$CR"
  [ -z "${ROUTE_FIX_ATTR:-}" ] || printf '%s\n' "$2 merge=liar" > "$CR/.gitattributes"
  printf '%b' "$3" > "$CR/$2"
  git -C "$CR" add -A
  git -C "$CR" commit -qm base
  git -C "$CR" checkout -q -b tip
  printf '%b' "$4" > "$CR/$2"
  git -C "$CR" commit -q --allow-empty -am tip
  CT=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  git -C "$CR" checkout -q -b merged
  printf '%b' "$5" > "$CR/$2"
  git -C "$CR" commit -q --allow-empty -am merged
  CM=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
}

# route_prove <repo> <tip> <merge>: the content proof; sets PROVE_RC and PROVE_WHY.
PROVE_RC=
PROVE_WHY=
PROVE_OUT=
# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
route_prove() {
  local out
  out=$(ROUTE_PROVE_REPO=$1 ROUTE_PROVE_TIP=$2 ROUTE_PROVE_MERGE=$3 route_lib "${ROUTE_TRIP_SNIPPET:-:}"'
rc=0; teardown_route_content_proven "$ROUTE_PROVE_REPO" "$ROUTE_PROVE_TIP" "$ROUTE_PROVE_MERGE" || rc=$?; printf "RC=%s\nWHY=%s\n" "$rc" "$TEARDOWN_CLOSEOUT_ROUTE_WHY"' 2>&1)
  PROVE_OUT=$out
  PROVE_RC=$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | head -n 1)
  PROVE_WHY=$(printf '%s\n' "$out" | sed -n 's/^WHY=//p' | head -n 1)
  [ -n "$PROVE_RC" ] || PROVE_RC="no answer: $out"
}
assert_proved() {  # <label>
  [ "$PROVE_RC" = 0 ] || fail "$1: the content proof refused ($PROVE_RC: $PROVE_WHY)"
}
assert_unproved() {  # <label> [<text the reason must hold>]
  [ "$PROVE_RC" = 1 ] || fail "$1: the content proof did not refuse (got: $PROVE_RC $PROVE_WHY)"
  [ -z "${2:-}" ] || assert_contains "$PROVE_WHY" "$2" "$1: the reason does not name the failed condition"
}

test_the_content_proof_proves_a_twin_a_squash_and_an_ancestor_and_keeps_what_the_merge_commit_lacks() {
  local body
  make_world world-content-proof
  # A twin: the merge commit holds exactly the copy's change.
  route_content_fixture twin f.txt 'a\n' 'a\nadded\n' 'a\nadded\n'
  route_prove "$CR" "$CT" "$CM"; assert_proved "a twin"
  # A squash onto a moved main: the target moved at another path, and holds the copy's file exactly.
  body='1\n2\n3\n4\n5\n6\n7\n8\n9\n'
  route_content_fixture squash f.txt "$body" '1\nX\n2\n3\n4\n5\n6\n7\n8\n9\n' '1\nX\n2\n3\n4\n5\n6\n7\n8\n9\n'
  git -C "$CR" checkout -q merged
  printf 'moved on\n' > "$CR/other.txt"
  git -C "$CR" add other.txt
  git -C "$CR" commit -qm "main moved at another path"
  CM=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  route_prove "$CR" "$CT" "$CM"; assert_proved "a squash onto a main that moved at another path"
  # The target changed the copy's path further (Main 1869): the blob differs, so the copy is kept.
  route_content_fixture squashfurther f.txt "$body" '1\nX\n2\n3\n4\n5\n6\n7\n8\n9\n' '1\nX\n2\n3\n4\n5\n6\n7\n8\n9\n10\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "a target that changed the copy's path further" "f.txt"
  # An ancestor: the copy's tip is inside the merge commit's history.
  route_content_fixture ancestor f.txt 'a\n' 'a\nadded\n' 'a\nadded\n'
  git -C "$CR" checkout -q merged
  git -C "$CR" reset -q --hard "$CT"
  printf 'a\nadded\nmore\n' > "$CR/f.txt"
  git -C "$CR" commit -qam more
  CM=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" merge-base --is-ancestor "$CT" "$CM" || fail "the ancestor fixture is not an ancestor"
  route_prove "$CR" "$CT" "$CM"; assert_proved "an ancestor"
  # An added line the merge commit lacks: kept, and the reason names the path.
  route_content_fixture absent f.txt 'a\n' 'a\nadded\n' 'a\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "an added line the merge commit lacks" "f.txt"
  # A misattributed row: a genuinely merged result that does not carry the copy's lines.
  route_content_fixture misattributed f.txt 'a\n' 'a\nsecurity fix\n' 'a\nsomething else\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "a merged result that does not carry the copy's lines" "f.txt"
  pass "the content proof proves a twin, a squash onto a main that moved at another path and an ancestor, and keeps an added line, a result that the merge commit lacks and a path the target changed further"
}

test_the_content_proof_compares_whole_lines_and_keeps_an_order_or_prefix_that_changes_the_meaning() {
  local comments
  make_world world-content-lines
  route_content_fixture exactline f.txt 'a\n' 'a\nrequire_tls=true\n' 'a\nrequire_tls=true\n'
  route_prove "$CR" "$CT" "$CM"; assert_proved "the exact line"
  route_content_fixture commented f.txt 'a\n' 'a\nrequire_tls=true\n' 'a\n# require_tls=true\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "the line only as a comment" "f.txt"
  route_content_fixture suffixed f.txt 'a\n' 'a\nrequire_tls=true\n' 'a\nrequire_tls=true # note\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "the line with a suffix" "f.txt"
  route_content_fixture adjacent policy.txt 'AUTH_DISABLED=true\n' 'AUTH_DISABLED=false\n' 'AUTH_DISABLED=false\nAUTH_DISABLED=true\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "the adjacent override" "policy.txt"
  route_content_fixture secure policy.txt 'AUTH_DISABLED=true\n' 'AUTH_DISABLED=false\n' 'AUTH_DISABLED=false\n'
  route_prove "$CR" "$CT" "$CM"; assert_proved "the secure result"
  comments='# 1\n# 2\n# 3\n# 4\n# 5\n# 6\n# 7\n# 8\n# end\n'
  route_content_fixture separated policy.txt "AUTH_DISABLED=true\n$comments" "AUTH_DISABLED=false\n$comments" "AUTH_DISABLED=false\n${comments}AUTH_DISABLED=true\n"
  route_prove "$CR" "$CT" "$CM"; assert_unproved "the separated later override (the target changed the path further, so its blob differs from the copy's)" "policy.txt"
  pass "the content proof compares whole files by blob: a commented or suffixed line, an adjacent override and a separated later override keep the copy, and the exact file and the secure result route"
}

test_the_content_proof_judges_mode_and_text_together_and_needs_identical_entries_for_removals_and_binaries() {
  local sha
  make_world world-content-modes
  # Mixed: the copy turns the executable bit on and adds a line; the merge commit holds the text at the old mode.
  route_content_fixture mixed f.txt 'base\n' 'base\nadded\n' 'base\nadded\n'
  git -C "$CR" checkout -q tip
  chmod +x "$CR/f.txt"
  git -C "$CR" commit -qam exec
  CT=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  route_prove "$CR" "$CT" "$CM"; assert_unproved "a mode change with added text, merge commit at the old mode" "f.txt"
  git -C "$CR" checkout -q merged
  chmod +x "$CR/f.txt"
  git -C "$CR" commit -qam exec
  CM=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  route_prove "$CR" "$CT" "$CM"; assert_proved "a mode change with added text, the merge commit holding the copy's entry"
  # A deleted file the merge commit still has, and one it deleted too.
  route_content_fixture deleted f.txt 'a\n' 'a\n' 'a\n'
  printf 'keep\n' > "$CR/gone.txt"
  git -C "$CR" add gone.txt
  git -C "$CR" commit -qm gone
  git -C "$CR" branch -f tip main
  git -C "$CR" branch -f merged main
  git -C "$CR" checkout -q tip
  git -C "$CR" rm -q gone.txt
  git -C "$CR" commit -qm "delete gone"
  CT=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  CM=$(git -C "$CR" rev-parse merged)
  route_prove "$CR" "$CT" "$CM"; assert_unproved "a file the copy deletes and the merge commit still has" "gone.txt"
  git -C "$CR" checkout -q merged
  git -C "$CR" rm -q gone.txt
  git -C "$CR" commit -qm "delete gone"
  CM=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  route_prove "$CR" "$CT" "$CM"; assert_proved "a file both deleted"
  # A binary file: another binary in the merge commit keeps, the copy's own entry routes.
  route_content_fixture binary b.bin 'start\0one\n' 'start\0two\n' 'start\0three\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "a binary change the merge commit holds differently" "b.bin"
  route_content_fixture binarysame b.bin 'start\0one\n' 'start\0two\n' 'start\0two\n'
  route_prove "$CR" "$CT" "$CM"; assert_proved "a binary change the merge commit holds identically"
  # Lines removed only: the entry must be identical.
  route_content_fixture removed f.txt '1\n2\n3\n' '1\n3\n' '1\n2\n3\n4\n'
  route_prove "$CR" "$CT" "$CM"; assert_unproved "a change that only removes lines, the merge commit differing" "f.txt"
  route_content_fixture removedsame f.txt '1\n2\n3\n' '1\n3\n' '1\n3\n'
  sha=$CM
  route_prove "$CR" "$CT" "$sha"; assert_proved "a change that only removes lines, the merge commit identical"
  pass "the content proof judges mode and text together: a mode change, a deleted file, a binary file and a removal need an identical entry, and the copy's own entry routes"
}

test_the_content_proof_keeps_an_empty_change_that_is_not_an_ancestor_and_histories_without_one_merge_base() {
  local x1 y1 m1 m2
  make_world world-content-bases
  # An empty change: proven, and not an ancestor.
  route_content_fixture empty f.txt 'a\n' 'a\n' 'a\nchanged\n'
  git -C "$CR" checkout -q tip
  git -C "$CR" commit -q --allow-empty -m "empty"
  CT=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  route_prove "$CR" "$CT" "$CM"; assert_proved "an empty commit on the merge base's tree"
  ! git -C "$CR" merge-base --is-ancestor "$CT" "$CM" || fail "the empty-change fixture is an ancestor, so it does not discriminate"
  # No merge base: unrelated histories.
  route_content_fixture unrelated f.txt 'a\n' 'a\n' 'a\n'
  git -C "$CR" checkout -q --orphan alien
  git -C "$CR" rm -rfq . 2>/dev/null
  printf 'z\n' > "$CR/z.txt"
  git -C "$CR" add z.txt
  git -C "$CR" commit -qm alien
  CT=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  route_prove "$CR" "$CT" "$CM"; assert_unproved "unrelated histories" "merge base"
  # Two merge bases: a criss-cross.
  route_content_fixture crisscross f.txt 'a\n' 'a\n' 'a\n'
  git -C "$CR" checkout -q -b x1 main
  printf 'x\n' > "$CR/x.txt"; git -C "$CR" add x.txt; git -C "$CR" commit -qm x1
  x1=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q -b y1 main
  printf 'y\n' > "$CR/y.txt"; git -C "$CR" add y.txt; git -C "$CR" commit -qm y1
  y1=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q -b m1 "$x1"
  git -C "$CR" merge -q --no-ff -m m1 "$y1"
  m1=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q -b m2 "$y1"
  git -C "$CR" merge -q --no-ff -m m2 "$x1"
  m2=$(git -C "$CR" rev-parse HEAD)
  git -C "$CR" checkout -q main
  [ "$(git -C "$CR" merge-base --all "$m1" "$m2" | wc -l | tr -d ' ')" = 2 ] || fail "the criss-cross fixture does not have two merge bases"
  route_prove "$CR" "$m1" "$m2"; assert_unproved "a pair with two merge bases" "merge base"
  # A git command that fails proves nothing.
  route_content_fixture failing f.txt 'a\n' 'a\nadded\n' 'a\nadded\n'
  FAKE_GIT_FAIL_MERGEBASE=1 route_prove "$CR" "$CT" "$CM"; assert_unproved "a failing merge-base command" "merge base"
  pass "the content proof proves an empty change without calling it an ancestor and keeps unrelated histories, two merge bases and a failing git"
}

test_the_content_proof_writes_nothing_to_the_clone_and_runs_no_merge() {
  local before after objs_before objs_after
  make_world world-content-readonly
  route_content_fixture readonly f.txt '1\n2\n3\n4\n5\n6\n7\n8\n9\n' '1\nX\n2\n3\n4\n5\n6\n7\n8\n9\n' '1\nX\n2\n3\n4\n5\n6\n7\n8\n9\n'
  before=$(git -C "$CR" for-each-ref | shasum -a 256; git -C "$CR" status --porcelain=v1 --ignored | shasum -a 256)
  objs_before=$(find "$CR/.git/objects" -type f | LC_ALL=C sort | shasum -a 256)
  mkdir -p "$W/proof-tmp"
  : > "$W/git.log"
  TMPDIR="$W/proof-tmp" route_prove "$CR" "$CT" "$CM"; assert_proved "the text twin"
  ! grep -q 'merge-tree' "$W/git.log" || fail "the content proof ran git merge-tree"
  after=$(git -C "$CR" for-each-ref | shasum -a 256; git -C "$CR" status --porcelain=v1 --ignored | shasum -a 256)
  objs_after=$(find "$CR/.git/objects" -type f | LC_ALL=C sort | shasum -a 256)
  [ "$before" = "$after" ] || fail "the proof changed the clone's refs or status"
  [ "$objs_before" = "$objs_after" ] || fail "the proof wrote an object into the clone's object store"
  [ -z "$(ls -A "$W/proof-tmp")" ] || fail "the proof left a temporary directory behind: $(ls -A "$W/proof-tmp")"
  pass "the content proof writes no ref, status or object to the clone, leaves no temporary directory and never runs git merge-tree"
}

test_a_lying_merge_driver_in_any_channel_cannot_make_a_copy_count_as_landed() {
  local channel
  make_world world-content-liar
  for channel in attributes default info; do
    # The reviewer's POLICY case: the copy sets required, the merge commit holds other.
    if [ "$channel" = attributes ]; then ROUTE_FIX_ATTR=1; else ROUTE_FIX_ATTR=; fi
    route_content_fixture "liar-$channel" policy.txt 'POLICY=base\n' 'POLICY=required\n' 'POLICY=other\n'
    ROUTE_FIX_ATTR=
    CMARK="$TMP_ROOT/liar-ran-$channel"
    rm -f "$CMARK"
    git -C "$CR" config merge.liar.name liar
    git -C "$CR" config merge.liar.driver "touch '$CMARK'; true"
    [ "$channel" != default ] || git -C "$CR" config merge.default liar
    [ "$channel" != info ] || printf 'policy.txt merge=liar\n' > "$CR/.git/info/attributes"
    route_prove "$CR" "$CT" "$CM"
    assert_unproved "the POLICY case with a lying driver selected through $channel"
    [ ! -e "$CMARK" ] || fail "the lying driver ran (channel $channel): the proof let a configured merge driver decide"
    # The legitimate text twin under the same configuration: a real merge decides.
    if [ "$channel" = attributes ]; then ROUTE_FIX_ATTR=1; else ROUTE_FIX_ATTR=; fi
    route_content_fixture "liartwin-$channel" policy.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n'
    ROUTE_FIX_ATTR=
    git -C "$CR" config merge.liar.name liar
    git -C "$CR" config merge.liar.driver "touch '$CMARK'; true"
    [ "$channel" != default ] || git -C "$CR" config merge.default liar
    [ "$channel" != info ] || printf 'policy.txt merge=liar\n' > "$CR/.git/info/attributes"
    route_prove "$CR" "$CT" "$CM"
    # The proof runs no merge, so the legitimate twin routes under the same configuration (Main 1869).
    assert_proved "the legitimate text twin under a configured lying driver ($channel)"
    [ ! -e "$CMARK" ] || fail "the lying driver ran on the twin (channel $channel)"
    # The original different-blob twin (the target changed the path further) is kept under the same configuration.
    if [ "$channel" = attributes ]; then ROUTE_FIX_ATTR=1; else ROUTE_FIX_ATTR=; fi
    route_content_fixture "liarfurther-$channel" policy.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=2\n'
    ROUTE_FIX_ATTR=
    git -C "$CR" config merge.liar.name liar
    git -C "$CR" config merge.liar.driver "touch '$CMARK'; true"
    [ "$channel" != default ] || git -C "$CR" config merge.default liar
    [ "$channel" != info ] || printf 'policy.txt merge=liar\n' > "$CR/.git/info/attributes"
    route_prove "$CR" "$CT" "$CM"
    assert_unproved "the different-blob twin under a configured lying driver ($channel)" "policy.txt"
    [ ! -e "$CMARK" ] || fail "the lying driver ran on the different-blob twin (channel $channel)"
  done
  pass "a lying merge driver selected through .gitattributes, merge.default or info/attributes never runs, because the proof runs no merge: the POLICY case is kept and the legitimate text twin routes under the same configuration"
}

# route_closeout <plan|execute> <name> [<before> [<after>]]: teardown_run_closeout in a
# library bash for the copy <name> of the current world. <before> and <after> are
# snippets run in that bash before and after the call. Sets CO_RC, CO_SWITCHED, CO_ROUTE,
# CO_OUT (the owner's output on one line) and CO_ALL (everything it printed).
CO_RC=
CO_SWITCHED=
CO_ROUTE=
CO_OUT=
CO_ALL=
# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
route_closeout() {
  CO_ALL=$(ROUTE_CO_SLOT=$SLOT ROUTE_CO_COPY=$(copy_path "$2") ROUTE_CO_STAGE=$1 ROUTE_CO_BEFORE="${3:-:}" ROUTE_CO_AFTER="${4:-:}" \
    ROUTE_CO_DATA="$HOMED/data" FM_TEARDOWN_VERNANT_PYTHON="${ROUTE_CO_PYTHON:-$DRIVER_PY}" route_lib '
      TEARDOWN_ROUTE_DATA=$ROUTE_CO_DATA
      eval "$ROUTE_CO_BEFORE"
      stage=; [ "$ROUTE_CO_STAGE" != plan ] || stage=plan
      rc=0
      teardown_run_closeout "$ROUTE_CO_SLOT" "$ROUTE_CO_COPY" $stage || rc=$?
      eval "$ROUTE_CO_AFTER"
      printf "RC=%s\nSWITCHED=%s\nROUTE=%s\nOUT=%s\n" "$rc" "${TEARDOWN_CLOSEOUT_SWITCHED:-}" "${TEARDOWN_CLOSEOUT_ROUTE:-}" "$(printf "%s" "${TEARDOWN_CLOSEOUT_OUT:-}" | tr "\n" " ")"
    ' 2>&1)
  CO_RC=$(printf '%s\n' "$CO_ALL" | sed -n 's/^RC=//p' | tail -n 1)
  CO_SWITCHED=$(printf '%s\n' "$CO_ALL" | sed -n 's/^SWITCHED=//p' | tail -n 1)
  CO_ROUTE=$(printf '%s\n' "$CO_ALL" | sed -n 's/^ROUTE=//p' | tail -n 1)
  CO_OUT=$(printf '%s\n' "$CO_ALL" | sed -n 's/^OUT=//p' | tail -n 1)
  [ -n "$CO_RC" ] || fail "route_closeout produced no answer: $CO_ALL"
}

# The number of calls the scripted driver logged for <name>.
route_call_count() {
  route_calls_for "$1" | sed '/^$/d' | wc -l | tr -d ' '
}

# A copy with changes of its own in the current world, built the way a real one is
# (real git, no shim): the base commit on main, the copy's tip on its own branch from
# the base, then the merge commit on main, pushed, with the PR merged at it and a
# locked copy, a profile, a record and scripted driver answers for the copy.
# route_content_copy <name> <pr> <file> <base> <tip> <merge>; contents are printf %b.
route_content_copy() {
  local name=$1 pr=$2 f=$3 base
  printf '%b' "$4" > "$SLOT/$f"
  git -C "$SLOT" add -- "$f"
  [ ! -f "$SLOT/.gitattributes" ] || git -C "$SLOT" add -- .gitattributes
  git -C "$SLOT" commit -qm "base of $name"
  base=$(git -C "$SLOT" rev-parse HEAD)
  git -C "$SLOT" worktree add -q -b "fm/$name" "$(copy_path "$name")" "$base"
  printf '%b' "$5" > "$(copy_path "$name")/$f"
  git -C "$(copy_path "$name")" commit -qam "tip of $name"
  git -C "$(copy_path "$name")" push -q origin "fm/$name"
  printf '%b' "$6" > "$SLOT/$f"
  git -C "$SLOT" commit -qam "merge of $name"
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" fetch -q origin
  ROUTE_MERGE=$(git -C "$SLOT" rev-parse HEAD)
  route_set_pr "$W/forge" "$pr" MERGED "$ROUTE_MERGE"
  route_lock_dead "$name"
  route_write_profile "$W/profiles/$name.json" "$pr" "$(route_tip "$name")"
  route_record "$name" "$pr" "$(route_tip "$name")" "$W/profiles/$name.json"
  route_script_row "$W" "$name" allowed success "$pr"
}

# The whole route on a real repository: a lying merge driver, selected through
# .gitattributes, merge.default or info/attributes, never runs (the marker file stays
# absent), the reviewer's POLICY copy (it sets required, the merge commit holds other)
# is kept with an empty closeout argv, and the legitimate text twin under the same
# configuration routes with the --pr options.
test_a_lying_merge_driver_keeps_the_copy_before_the_driver_through_the_whole_route() {
  local channel marker
  for channel in attributes default info; do
    route_world "route-liar-$channel"
    marker="$W/liar-ran"
    rm -f "$marker"
    [ "$channel" != attributes ] || printf 'policy.txt merge=liar\ntwin.txt merge=liar\n' > "$SLOT/.gitattributes"
    route_content_copy policy 7 policy.txt 'POLICY=base\n' 'POLICY=required\n' 'POLICY=other\n'
    route_content_copy twin 8 twin.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n'
    git -C "$SLOT" config merge.liar.name liar
    git -C "$SLOT" config merge.liar.driver "touch '$marker'; true"
    [ "$channel" != default ] || git -C "$SLOT" config merge.default liar
    [ "$channel" != info ] || printf 'policy.txt merge=liar\ntwin.txt merge=liar\n' > "$SLOT/.git/info/attributes"
    route_closeout plan policy
    [ "$CO_ROUTE" = invalid ] && [ "$CO_RC" != 0 ] || fail "the POLICY copy was not kept before the driver through $channel ($CO_RC $CO_ROUTE): $CO_OUT"
    [ -z "$(route_calls_for policy)" ] || fail "the closeout driver was asked for the POLICY copy through $channel: $(route_calls_for policy)"
    [ ! -e "$marker" ] || fail "the lying driver ran through $channel: the route let a configured merge driver decide"
    route_closeout plan twin
    # The proof runs no merge, so the legitimate twin routes under the same configuration (Main 1869).
    [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "the text twin under a configured lying driver ($channel) did not route ($CO_RC $CO_ROUTE): $CO_OUT"
    [ "$(route_call_count twin)" = 1 ] || fail "the twin was not asked once: $(route_calls_for twin)"
    assert_contains "$(route_calls_for twin)" "--pr 8" "the twin's plan was not asked by the --pr route"
    [ ! -e "$marker" ] || fail "the lying driver ran on the twin through $channel"
    # The original different-blob twin (the target changed the path further) is kept under the same configuration.
    route_content_copy further 9 further.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=2\n'
    route_closeout plan further
    [ "$CO_ROUTE" = invalid ] && [ -z "$(route_calls_for further)" ] || fail "the different-blob twin reached the driver through $channel ($CO_ROUTE): $(route_calls_for further)"
    [ ! -e "$marker" ] || fail "the lying driver ran on the different-blob twin through $channel"
    printf 'liar %s: POLICY copy kept with no driver call, twin routed, marker absent\n' "$channel"
  done
  pass "through the whole route on real git, a lying merge driver selected by .gitattributes, merge.default or info/attributes never runs: the POLICY copy is kept with an empty closeout argv and the text twin under the same configuration routes, because the proof runs no merge"
}

test_the_landing_branch_is_the_remotes_own_default_and_a_stale_origin_head_or_an_unreachable_remote_keeps_the_copy() {
  local topic
  # A stale local origin/HEAD naming origin/topic while the remote's default is main.
  route_world landing-stale
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  git -C "$SLOT" checkout -q -b topic
  git -C "$SLOT" commit -q --allow-empty -m "merge of a pull request into topic"
  git -C "$SLOT" push -q origin topic
  topic=$(git -C "$SLOT" rev-parse HEAD)
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" fetch -q origin
  git -C "$SLOT" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/topic
  route_set_pr "$W/forge" 8 MERGED "$topic"
  route_copy control 7
  ROUTE_COPY_AT=$topic route_copy stale 8
  route_sweep --apply
  route_assert_released control "a merge commit on the remote's default branch, a stale local origin/HEAD naming topic"
  route_assert_kept stale "a merge commit only on origin/topic while the remote's default is main"
  [ -z "$(route_calls_for stale)" ] || fail "the stale-hint copy reached the driver: $(route_calls_for stale)"
  # An unreachable remote.
  route_world landing-offline
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy offline 7
  git -C "$SLOT" config --unset-all "url.file://$(cd "$W/origin.git" && pwd).insteadOf"
  git -C "$SLOT" config "url.file://$W/no-such-remote.git.insteadOf" "$ROUTE_REMOTE_URL"
  route_sweep --apply
  route_assert_kept offline "a remote that cannot be read"
  [ -z "$(route_calls_for offline)" ] || fail "the copy reached the driver although the remote's default branch could not be read"
  # A remote default that names a branch the clone has no origin/<branch> for.
  route_world landing-unfetched
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy unfetched 7
  git -C "$W/origin.git" branch develop main
  git -C "$W/origin.git" symbolic-ref HEAD refs/heads/develop
  route_sweep --apply
  route_assert_kept unfetched "a remote default branch with no origin/<branch> in the clone"
  [ -z "$(route_calls_for unfetched)" ] || fail "the copy reached the driver although the clone has no origin/develop"
  pass "the landing branch is the remote's own default: a stale origin/HEAD naming topic, an unreachable remote and a default the clone has no ref for each keep the copy before the driver, and a merge on the real default routes"
}

test_a_recorded_base_must_agree_with_the_remotes_default_and_its_own_origin_ref_decides_landing() {
  route_world landing-base
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  git -C "$SLOT" branch release "$ROUTE_MERGE"
  git -C "$SLOT" push -q origin release
  git -C "$SLOT" fetch -q origin
  route_copy based 7
  route_closeout plan based 'TEARDOWN_ROUTE_BASE=main'
  [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "a recorded base equal to the remote's default did not route ($CO_RC $CO_ROUTE): $CO_OUT"
  route_closeout plan based 'TEARDOWN_ROUTE_BASE=release'
  [ "$CO_RC" != 0 ] && [ "$CO_ROUTE" = invalid ] || fail "a recorded base that disagrees with the remote's default routed: $CO_RC $CO_ROUTE $CO_OUT"
  assert_contains "$CO_OUT" "disagrees with the remote's default branch" "the refusal does not name the disagreement"
  [ "$(route_call_count based)" = 1 ] || fail "the driver was called for the disagreeing base: $(route_calls_for based)"
  # The remote's default is release too: the base now agrees and its own origin ref decides.
  git -C "$W/origin.git" symbolic-ref HEAD refs/heads/release
  route_closeout plan based 'TEARDOWN_ROUTE_BASE=release'
  [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "a recorded base that agrees with the remote's default did not route ($CO_RC $CO_ROUTE): $CO_OUT"
  pass "a recorded base routes only when it agrees with the remote's own default branch"
}

# The stated envelope, plan and execute: every document outside it keeps the copy.
# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
test_the_routes_answer_must_be_the_stated_fifteen_key_envelope_for_the_plan_and_the_execute() {
  local table keys k stage good rc out pr=7
  make_world envelope-matrix
  table=$W/answers.tsv
  : > "$table"
  add_answer() {  # <stage> <rc> <expect> <label> <document>
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(printf '%s' "$5" | tr '\n' '\001')" >> "$table"
  }
  for stage in plan execute; do
    if [ "$stage" = plan ]; then good=$(route_plan_allowed_envelope "$pr"); rc=3; else good=$(route_execute_success_envelope "$pr"); rc=0; fi
    add_answer "$stage" "$rc" yes "$stage: the stated envelope" "$good"
    keys=$(printf '%s' "$good" | jq -r 'keys[]')
    for k in $keys; do
      add_answer "$stage" "$rc" no "$stage: key $k removed" "$(printf '%s' "$good" | jq -c "del(.$k)")"
    done
    add_answer "$stage" "$rc" no "$stage: a key added" "$(printf '%s' "$good" | jq -c '. + {"extra": 1}')"
    add_answer "$stage" "$rc" no "$stage: not an object (array)" '[]'
    add_answer "$stage" "$rc" no "$stage: not an object (string)" '"x"'
    add_answer "$stage" "$rc" no "$stage: a second document" "$good"$'\n'"$good"
    add_answer "$stage" "$rc" no "$stage: trailing text" "$good"$'\n''trailing words'
    add_answer "$stage" "$rc" no "$stage: allowed document of the no-pr lane" '{"allowed": true}'
    add_answer "$stage" "$rc" no "$stage: the three-field document" '{"state":"DONE_WITH_SUPERSEDENCE","predicates_failed":[],"worktree_removed":true}'
    add_answer "$stage" "$rc" no "$stage: the PR is another" "$(printf '%s' "$good" | jq -c '.pr = 8')"
    add_answer "$stage" "$rc" no "$stage: the PR is a string" "$(printf '%s' "$good" | jq -c '.pr = "7"')"
    add_answer "$stage" "$rc" no "$stage: predicates_failed holds cleanup_gate" "$(printf '%s' "$good" | jq -c '.predicates_failed = ["cleanup_gate"]')"
    add_answer "$stage" "$rc" no "$stage: cleanup_requested false" "$(printf '%s' "$good" | jq -c '.cleanup_requested = false')"
    add_answer "$stage" "$rc" no "$stage: cleanup_requested the string true" "$(printf '%s' "$good" | jq -c '.cleanup_requested = "true"')"
    add_answer "$stage" "$rc" no "$stage: worktree_removed the string" "$(printf '%s' "$good" | jq -c '.worktree_removed = "false"')"
    add_answer "$stage" "$rc" no "$stage: worktree_removed null" "$(printf '%s' "$good" | jq -c '.worktree_removed = null')"
  done
  good=$(route_plan_allowed_envelope "$pr")
  add_answer plan 3 no "plan: state DONE" "$(printf '%s' "$good" | jq -c '.state = "DONE"')"
  add_answer plan 3 no "plan: a second predicate" "$(printf '%s' "$good" | jq -c '.predicates_failed = ["cleanup_not_executed","primary_checkout_repair"]')"
  add_answer plan 3 no "plan: worktree_removed true" "$(printf '%s' "$good" | jq -c '.worktree_removed = true')"
  add_answer plan 0 no "plan: the stated envelope at exit 0" "$good"
  add_answer plan 1 no "plan: the stated envelope at exit 1" "$good"
  good=$(route_execute_success_envelope "$pr")
  add_answer execute 0 yes "execute: DONE" "$(printf '%s' "$good" | jq -c '.state = "DONE"')"
  add_answer execute 0 no "execute: BLOCKED" "$(printf '%s' "$good" | jq -c '.state = "BLOCKED"')"
  add_answer execute 0 no "execute: worktree_removed false" "$(printf '%s' "$good" | jq -c '.worktree_removed = false')"
  add_answer execute 0 no "execute: a recovery reason" "$(printf '%s' "$good" | jq -c '.cleanup_recovery_reason = "cleanup_gate"')"
  add_answer execute 3 no "execute: the stated envelope at exit 3" "$good"
  add_answer execute 2 no "execute: the stated envelope at exit 2" "$good"
  out=$(ROUTE_ANSWERS=$table route_lib '
    bad=0
    while IFS=$(printf "\t") read -r stage rc expect label doc; do
      TEARDOWN_CLOSEOUT_ROUTE_PR=7
      TEARDOWN_CLOSEOUT_STDOUT=$(printf "%s" "$doc" | tr "\001" "\n")
      TEARDOWN_CLOSEOUT_OUT=
      got=no
      teardown_closeout_route_answer "$stage" "$rc" && got=yes
      if [ "$got" = "$expect" ]; then printf "ok   %s\n" "$label"; else printf "WRONG %s (wanted %s, got %s)\n" "$label" "$expect" "$got"; bad=1; fi
    done < "$ROUTE_ANSWERS"
    exit "$bad"
  ' 2>&1) || { printf '%s\n' "$out" | grep -E '^WRONG' | head -20; fail "the route reader judged some documents wrongly"; }
  [ "$(printf '%s\n' "$out" | grep -c '^ok ')" -ge 70 ] || fail "the matrix ran fewer than 70 documents: $(printf '%s\n' "$out" | grep -c '^ok ')"
  printf 'envelope matrix: %s documents judged as wanted\n' "$(printf '%s\n' "$out" | grep -c '^ok ')"
  pass "the plan and the execute are judged on the stated fifteen-key envelope: any missing, added, wrong or wrong-typed field, a second document, trailing text and an exit that disagrees keep the copy, and the stated envelope proceeds or releases"
}

# --- the project lock the route holds (library-level) --------------------------
# A probe the scripted driver runs while the route's call is in progress: is the
# slot's project lock held, and is an actor that tries to take it told busy?
route_install_lock_probe() {  # <name> <stage>
  mkdir -p "$W/ans/$1"
  cat > "$W/ans/$1/$2.hook" <<'SH'
bash -c '
  . "$ROUTE_LIB_DIR/fm-wake-lib.sh"; . "$ROUTE_LIB_DIR/fm-lock-lib.sh"; . "$ROUTE_LIB_DIR/fm-project-lock-lib.sh"
  lock=$(fm_treehouse_project_lock_path "$1"); held=no; [ -d "$lock" ] && held=yes
  rc=0; fm_project_lock_try "$lock" probe >/dev/null 2>&1 || rc=$?
  printf "held=%s try_rc=%s\n" "$held" "$rc" > "$2"
' _ "$PWD" "$ROUTE_PROBE_OUT"
SH
}

# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
test_the_route_takes_and_releases_its_own_project_lock_when_its_caller_holds_none() {
  route_world lock-own
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy owned 7
  route_install_lock_probe owned exec
  ROUTE_PROBE_OUT="$W/probe.out" route_closeout execute owned 'LOCK=$(fm_treehouse_project_lock_path "$ROUTE_CO_SLOT")' 'printf "LOCK_AFTER=%s\n" "$([ -d "$LOCK" ] && echo held || echo gone)"; rc2=0; fm_project_lock_try "$LOCK" later >/dev/null 2>&1 || rc2=$?; printf "LATER_TRY=%s\n" "$rc2"; fm_project_lock_release "$LOCK" || true'
  [ "$CO_RC" = 0 ] || fail "the route did not release the copy while taking its own lock ($CO_RC): $CO_OUT"
  assert_contains "$(cat "$W/probe.out")" "held=yes" "the project lock was not held during the driver call"
  assert_contains "$(cat "$W/probe.out")" "try_rc=75" "an actor that tried the lock during the driver call was not told busy"
  assert_contains "$CO_ALL" "LOCK_AFTER=gone" "the route did not release the lock it took"
  assert_contains "$CO_ALL" "LATER_TRY=0" "a later try of the lock did not succeed after the route"
  pass "a route whose caller holds no project lock takes it for the driver call, an actor that tries it meanwhile is told busy, and the route releases it"
}

# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
test_the_route_borrows_a_hold_its_caller_proves_and_leaves_it_held() {
  route_world lock-borrow
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy borrowed 7
  route_install_lock_probe borrowed exec
  ROUTE_PROBE_OUT="$W/probe.out" route_closeout execute borrowed \
    'LOCK=$(fm_treehouse_project_lock_path "$ROUTE_CO_SLOT"); fm_project_lock_try "$LOCK" outer-hold || exit 91; TEARDOWN_ROUTE_LOCK_HELD=$LOCK; PID_BEFORE=$(cat "$LOCK/pid"); ROLE_BEFORE=$(cat "$LOCK/role")' \
    'printf "HELD_AFTER=%s PID_SAME=%s ROLE_SAME=%s\n" "$([ -d "$LOCK" ] && echo yes || echo no)" "$([ "$(cat "$LOCK/pid" 2>/dev/null)" = "$PID_BEFORE" ] && echo yes || echo no)" "$([ "$(cat "$LOCK/role" 2>/dev/null)" = "$ROLE_BEFORE" ] && echo yes || echo no)"'
  [ "$CO_RC" = 0 ] || fail "the route did not release the copy under the caller's hold ($CO_RC): $CO_OUT"
  assert_contains "$CO_ALL" "HELD_AFTER=yes PID_SAME=yes ROLE_SAME=yes" "the route let go of, retook or relabeled the caller's hold"
  assert_contains "$(cat "$W/probe.out")" "held=yes" "the project lock was not held during the driver call"
  assert_contains "$(cat "$W/probe.out")" "try_rc=75" "an actor that tried the lock during the driver call was not told busy"
  [ "$(route_call_count borrowed)" = 1 ] || fail "the driver was not called exactly once under the borrowed hold: $(route_calls_for borrowed)"
  pass "a route whose caller proves its hold borrows it: the lock is held during the call and the caller's hold is untouched afterwards"
}

# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
test_a_claimed_hold_the_pid_file_does_not_prove_and_a_busy_lock_keep_the_copy_before_the_driver() {
  route_world lock-refuse
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy forged 7
  route_copy busy 7
  # A forged claim: the caller names the lock as held but its pid file names another process.
  route_closeout execute forged \
    'LOCK=$(fm_treehouse_project_lock_path "$ROUTE_CO_SLOT"); mkdir -p "$LOCK"; printf 1 > "$LOCK/pid"; printf outer > "$LOCK/role"; TEARDOWN_ROUTE_LOCK_HELD=$LOCK' \
    'printf "LOCK_PID=%s LOCK_ROLE=%s\n" "$(cat "$LOCK/pid" 2>/dev/null)" "$(cat "$LOCK/role" 2>/dev/null)"'
  [ "$CO_RC" != 0 ] && assert_equals invalid "$CO_ROUTE" "a forged claimed hold did not refuse the route ($CO_RC $CO_ROUTE): $CO_OUT"
  assert_contains "$CO_OUT" "does not name this process" "the refusal does not say the hold is not proved"
  assert_contains "$CO_ALL" "LOCK_PID=1 LOCK_ROLE=outer" "the route touched a lock it did not hold"
  [ "$(route_call_count forged)" = 0 ] || fail "the driver was called under a forged claimed hold: $(route_calls_for forged)"
  # A lock held by another live process, no claim: the route does not wait or take it.
  route_closeout execute busy \
    'LOCK=$(fm_treehouse_project_lock_path "$ROUTE_CO_SLOT"); rm -rf "$LOCK"; sleep 3 & holder=$!; mkdir -p "$LOCK"; printf "%s" "$holder" > "$LOCK/pid"; printf holder > "$LOCK/role"' \
    'printf "LOCK_ROLE=%s\n" "$(cat "$LOCK/role" 2>/dev/null)"'
  [ "$CO_RC" != 0 ] && assert_equals invalid "$CO_ROUTE" "a busy lock did not keep the copy ($CO_RC $CO_ROUTE): $CO_OUT"
  assert_contains "$CO_OUT" "could not be taken" "the refusal does not name the lock"
  assert_contains "$CO_ALL" "LOCK_ROLE=holder" "the route disturbed the other process's lock"
  [ "$(route_call_count busy)" = 0 ] || fail "the driver was called while another process held the lock: $(route_calls_for busy)"
  pass "a claimed hold the pid file does not prove and a lock held by another process each keep the copy before the driver, and neither lock is disturbed"
}

# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
test_the_lock_is_released_after_a_refusal_and_a_disabled_reflog_keeps_the_copy() {
  route_world lock-after-refusal
  route_set_pr "$W/forge" 7 CLOSED "$ROUTE_MERGE"
  route_copy closed 7
  route_closeout plan closed 'LOCK=$(fm_treehouse_project_lock_path "$ROUTE_CO_SLOT")' 'rc2=0; fm_project_lock_try "$LOCK" later >/dev/null 2>&1 || rc2=$?; printf "LATER_TRY=%s\n" "$rc2"; fm_project_lock_release "$LOCK" || true'
  [ "$CO_RC" != 0 ] || fail "a CLOSED PR routed"
  assert_contains "$CO_ALL" "LATER_TRY=0" "the route left the project lock held after a refusal"
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_closeout plan closed 'git -C "$ROUTE_CO_SLOT" config core.logAllRefUpdates false'
  [ "$CO_RC" != 0 ] && assert_equals invalid "$CO_ROUTE" "a clone whose reflog is disabled was not refused ($CO_RC $CO_ROUTE): $CO_OUT"
  assert_contains "$CO_OUT" "reflog" "the refusal does not name the reflog"
  [ "$(route_call_count closed)" = 0 ] || fail "the driver was called on a clone whose reflog is disabled: $(route_calls_for closed)"
  pass "the project lock is released after a refusal and a clone whose HEAD reflog is disabled is refused before the driver"
}

# --- the checkout of the slot across a route call -----------------------------
# The actors below are the harness's stand-ins for an agent's direct git switch or a
# person's: a hook that runs just before the driver's interpreter starts the driver
# (so after the route's read made immediately before entry), and a restore step the
# scripted driver runs before it answers (the named synchronization point: the driver
# stays running until the checkout is back, so the restore lands before the route's
# read after the call).
route_late_world() {  # <name>
  route_world "$1"
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  git -C "$SLOT" branch fm/pr-7-head "$ROUTE_MERGE"
  mkdir -p "$W/late"
  cat > "$W/late/prelaunch.sh" <<SH
#!/usr/bin/env bash
want=\$(cat "$W/late/switch" 2>/dev/null) || exit 0
stage=plan; name=''; prev=''
for a in "\$@"; do
  [ "\$a" != --execute-cleanup ] || stage=execute
  [ "\$prev" != --cleanup-worktree ] || name=\${a##*/}
  prev=\$a
done
[ "\$want" = "\$stage \$name" ] || exit 0
git -C "$SLOT" checkout -q fm/pr-7-head
SH
  printf '#!/usr/bin/env bash\nbash "%s/late/prelaunch.sh" "$@"\nexec bash "$@"\n' "$W" > "$W/late/python"
  chmod +x "$W/late/python"
  LATE_PY="$W/late/python"
}
route_late_restore() {  # <name> <plan|execute>: the restore step the driver runs before it answers
  mkdir -p "$W/ans/$1"
  printf 'git -C "%s" checkout -q main\n: > "%s/late/restored-%s"\n' "$SLOT" "$W" "$2" > "$W/ans/$1/$( [ "$2" = plan ] && echo plan || echo exec ).hook"
}
route_started_on() {  # <name> <stage> -> the branch the driver started on
  awk -F '|' -v n="$1" -v s="$2" '$1 == n && $2 == s { print $3 }' "$W/startup.log" 2>/dev/null | head -n 1
}

test_the_read_made_just_before_the_driver_is_entered_refuses_a_checkout_on_the_prs_head_with_no_driver_call() {
  route_late_world pre-entry
  route_copy zz-a 7
  printf 'git -C "%s" checkout -q fm/pr-7-head\n' "$SLOT" > "$W/late/mb.hook"
  FAKE_GIT_MERGEBASE_HOOK="$W/late/mb.hook" route_closeout plan zz-a
  [ "$CO_RC" != 0 ] || fail "a checkout switched to the PR head after the route's first read still reached the driver"
  assert_equals 1 "$CO_SWITCHED" "the switch was not reported as a switch"
  assert_contains "$CO_OUT" "just before the driver was entered" "the refusal does not name the pre-entry read"
  [ "$(route_call_count zz-a)" = 0 ] || fail "the driver was called with the checkout on the PR head: $(route_calls_for zz-a)"
  pass "a checkout found on the PR's head at the read made just before the driver is entered is refused with an empty driver log"
}

# The stable control of the case above: the same copy, no actor, routes with one driver call.
test_the_stable_control_of_the_pre_entry_read_routes_with_one_driver_call() {
  route_late_world pre-entry-control
  route_copy zz-a 7
  route_closeout plan zz-a
  [ "$CO_RC" = 0 ] && [ "$CO_SWITCHED" != 1 ] || fail "the stable control did not route ($CO_RC $CO_SWITCHED): $CO_OUT"
  [ "$(route_call_count zz-a)" = 1 ] || fail "the stable control did not call the driver once"
  pass "with no actor the same copy routes and the driver is called once"
}

test_a_switch_and_restore_after_the_first_read_is_found_before_or_after_the_driver_call() {
  route_late_world windows
  route_copy zz-a 7
  # Early: after the first read, before the read made just before entry.
  printf 'git -C "%s" checkout -q fm/pr-7-head && git -C "%s" checkout -q main\n' "$SLOT" "$SLOT" > "$W/late/mb.hook"
  FAKE_GIT_MERGEBASE_HOOK="$W/late/mb.hook" route_closeout plan zz-a
  [ "$CO_RC" != 0 ] && assert_equals 1 "$CO_SWITCHED" "an early switch and restore was not found ($CO_RC $CO_SWITCHED): $CO_OUT"
  assert_contains "$CO_OUT" "names the PR's head branch" "the report does not rest on the HEAD reflog"
  # End: the driver switches and restores as its last act, after it printed its answer.
  : > "$W/closeout.log"
  mkdir -p "$W/ans/zz-a"
  printf 'git -C "%s" checkout -q fm/pr-7-head && git -C "%s" checkout -q main\n' "$SLOT" "$SLOT" > "$W/ans/zz-a/plan.after"
  route_closeout plan zz-a
  [ "$CO_RC" != 0 ] && assert_equals 1 "$CO_SWITCHED" "a switch and restore at the end of the call was not found ($CO_RC $CO_SWITCHED): $CO_OUT"
  [ "$(route_call_count zz-a)" = 1 ] || fail "the driver was not called once for the end placement"
  pass "a switch and restore after the first read is found whether it falls before the read made just before entry or at the end of the call, from the HEAD reflog"
}

# The quiet control of the case above: no actor, the call is quiet and routes.
test_a_quiet_call_with_no_actor_routes_and_reports_no_switch() {
  route_late_world windows-control
  route_copy zz-a 7
  route_closeout plan zz-a
  [ "$CO_RC" = 0 ] && [ "$CO_SWITCHED" != 1 ] || fail "the quiet control did not route ($CO_RC $CO_SWITCHED): $CO_OUT"
  pass "a call with no actor routes and reports no switch"
}

test_a_switch_between_the_pre_entry_read_and_the_drivers_start_is_detected_at_a_plan_and_stops_the_run() {
  route_late_world late-plan
  route_copy zz-a 7
  route_copy aa-b 7
  printf 'plan zz-a\n' > "$W/late/switch"
  route_late_restore zz-a plan
  FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep --apply
  [ "$(route_started_on zz-a plan)" = fm/pr-7-head ] || fail "the fake driver did not start on the PR head: $(cat "$W/startup.log" 2>/dev/null)"
  [ -e "$W/late/restored-plan" ] || fail "the restore step did not complete before the driver answered"
  [ "$(route_call_count zz-a)" = 1 ] || fail "the driver was not called exactly once for the late-entry plan: $(route_calls_for zz-a)"
  route_assert_kept zz-a "the copy whose plan saw the switch"
  assert_contains "$OUT" "was switched during the plan of" "the run does not report the switch"
  assert_contains "$OUT" "names the PR's head branch" "the report does not rest on the HEAD reflog"
  [ "$(route_call_count aa-b)" = 0 ] || fail "a further copy reached the driver after the switch was found: $(route_calls_for aa-b)"
  route_assert_kept aa-b "the copy that was still pending"
  assert_contains "$OUT" "this run stopped after" "the pending copy is not reported as not released"
  pass "a switch injected after the pre-entry read and before the driver starts (the fake started on the PR head, was called, then the checkout was restored) is reported at a plan from the reflog and the run releases no further copy"
}

test_a_late_entry_switch_at_an_execute_is_detected_and_a_pending_copy_gets_no_driver_call() {
  route_late_world late-exec
  route_copy zz-a 7
  route_copy aa-b 7
  # B is eligible, releasable and pending: the report-only scan classes both as driver candidates and nothing holds B.
  FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep
  assert_class zz-a PENDING-DRIVER
  assert_class aa-b PENDING-DRIVER
  route_hold_receipt_exists aa-b && fail "a retention receipt holds the pending copy before the run"
  # The late-entry execute: A is processed first (the sweep takes copies in reverse path order).
  printf 'execute zz-a\n' > "$W/late/switch"
  route_late_restore zz-a execute
  FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep --apply
  [ "$(route_started_on zz-a plan)" = main ] || fail "A's plan did not start on main: $(cat "$W/startup.log" 2>/dev/null)"
  [ "$(route_started_on zz-a execute)" = fm/pr-7-head ] || fail "A's execute fake did not start on the PR head: $(cat "$W/startup.log" 2>/dev/null)"
  [ -e "$W/late/restored-execute" ] || fail "the restore step did not complete before A's execute answered"
  [ "$(route_call_count zz-a)" = 2 ] || fail "A did not get one plan and one execute: $(route_calls_for zz-a)"
  assert_contains "$OUT" "was switched during the execute of" "the run does not report the switch"
  assert_contains "$OUT" "names the PR's head branch" "the report does not rest on the HEAD reflog"
  [ ! -e "$(copy_path zz-a)" ] || fail "A's execute succeeded and removed the copy, which the run must not hide"
  [ "$(route_call_count aa-b)" = 0 ] || fail "B reached the driver after the switch was found: $(route_calls_for aa-b)"
  route_assert_kept aa-b "the copy that was pending at the detection"
  assert_contains "$OUT" "this run stopped after" "B is not reported as not released"
  pass "the late-entry execute (A first; B pending with capacity and no hold; A's fake started on the PR head and returned success) is reported from the reflog and B gets no driver call"
}

# The stable control of the case above: the same copies, no switch, release both in path order.
test_the_late_entry_stable_control_releases_both_copies_with_a_before_b() {
  route_late_world late-exec-control
  route_copy zz-a 7
  route_copy aa-b 7
  FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep --apply
  route_assert_released zz-a "the stable control, copy A"
  route_assert_released aa-b "the stable control, copy B (pending, under the cap)"
  [ "$(route_call_count zz-a)" = 2 ] && [ "$(route_call_count aa-b)" = 2 ] || fail "the stable control did not give each copy one plan and one execute"
  [ "$(grep -n -m1 'aa-b' "$W/closeout.log" | cut -d: -f1)" -gt "$(grep -n 'zz-a .*--execute-cleanup' "$W/closeout.log" | tail -n 1 | cut -d: -f1)" ] \
    || fail "A was not processed before B"
  pass "with no switch the same copies are both released, A before B, one plan and one execute each"
}

test_a_detected_switch_stops_the_run_even_when_the_first_executes_answer_is_a_refusal() {
  route_late_world late-refusal
  route_copy zz-a 7 allowed blocked
  route_copy aa-b 7
  printf 'execute zz-a\n' > "$W/late/switch"
  route_late_restore zz-a execute
  FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep --apply
  assert_contains "$OUT" "was switched during the execute of" "the switch is not reported when the execute refuses"
  [ "$(route_call_count aa-b)" = 0 ] || fail "B reached the driver after a refused execute with a switch: $(route_calls_for aa-b)"
  route_assert_kept zz-a "the copy whose execute refused"
  route_assert_kept aa-b "the pending copy"
  pass "a switch found during an execute whose answer is a refusal still stops the run"
}

# The no-switch control of the case above: the same refusal keeps A and the run goes on to B as before.
test_an_ordinary_refusal_without_a_switch_keeps_the_copy_and_the_run_goes_on_to_the_next_copy() {
  route_late_world late-refusal-control
  route_copy zz-a 7 allowed blocked
  route_copy aa-b 7
  FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep --apply
  route_assert_kept zz-a "an ordinary refusal"
  route_assert_released aa-b "the copy after an ordinary refusal"
  pass "the same refusal without a switch keeps A and lets the run go on to the next copy"
}

test_a_switch_and_restore_between_the_plan_and_the_execute_is_found_from_the_plans_first_read() {
  route_late_world between
  route_copy zz-a 7
  route_copy aa-b 7
  # The actor acts once the plan of A is done, during the sweep's own work before A's execute.
  cat > "$W/late/head.hook" <<SH
[ ! -e "$W/late/fired" ] || exit 0
grep -q 'zz-a' "$W/closeout.log" 2>/dev/null || exit 0
grep -q 'zz-a .*--execute-cleanup' "$W/closeout.log" 2>/dev/null && exit 0
: > "$W/late/fired"
git -C "$SLOT" checkout -q fm/pr-7-head && git -C "$SLOT" checkout -q main
SH
  FAKE_GIT_HEAD_HOOK="$W/late/head.hook" FM_TEARDOWN_VERNANT_PYTHON="$LATE_PY" run_sweep --apply
  [ -e "$W/late/fired" ] || fail "the harness actor never acted between the plan and the execute"
  assert_contains "$OUT" "was switched during the" "a switch and restore between the plan and the execute was not found"
  [ "$(route_call_count aa-b)" = 0 ] || fail "a further copy reached the driver after the switch was found: $(route_calls_for aa-b)"
  route_assert_kept aa-b "the copy that was pending"
  pass "a switch and restore between the plan and the execute is found from the first read made at the plan, so the window really runs to the end of the execute"
}

test_a_copy_with_no_record_is_asked_exactly_as_before_at_every_no_record_call() {
  local copy plain_plan plain_exec
  make_locked_copy_case r1d-plain dead
  install_driver "$SLOT" "$W"
  copy=$(copy_path locked)
  FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" run_sweep --apply
  plain_plan=$(sed -n 1p "$W/closeout.log")
  plain_exec=$(sed -n 2p "$W/closeout.log")
  assert_equals "$SLOT|--cleanup-worktree $copy" "$plain_plan" "the no-record plan call differs from the call before this change"
  assert_equals "$SLOT|--cleanup-worktree $copy --execute-cleanup" "$plain_exec" "the no-record execute call differs from the call before this change"
  make_locked_copy_case r1d-lib dead
  install_driver "$SLOT" "$W"
  copy=$(copy_path locked)
  route_closeout plan locked
  route_closeout execute locked
  assert_equals "$(printf '%s\n%s' "$SLOT|--cleanup-worktree $copy" "$SLOT|--cleanup-worktree $copy --execute-cleanup")" "$(head -n 2 "$W/closeout.log")" "the owner's no-record plan and execute calls differ from the call before this change"
  pass "a copy with no record is asked exactly as before: --cleanup-worktree <copy>, plus --execute-cleanup at the execute, and no --no-evidence-files"
}

# --- code round 2 (Main 1841): helper-level cases, libraries only -------------------
# Nothing below starts, signals or kills a process or a process group, reaches
# bin/fm-teardown.sh, runs a sweep in apply mode or reads a forge. Four tripwires stand
# where a forge read, a remote read or a timed run would be: each writes a sentinel
# file and fails, and every case asserts the sentinel is absent. The cases marked
# "through the route" call the route owner with the forge answer stubbed and the
# scripted driver as an ordinary child; they are written but are Unverified locally
# (Main 1850: when unsure, barred) and owed to the pipeline test step and CI.
IFS= read -r -d '' ROUTE_TRIP_SNIPPET <<'EOS' || true
fm_timeout_perl_bound() { : > "$ROUTE_TRIP_FILE"; return 99; }
fm_run_timed() { : > "$ROUTE_TRIP_FILE"; return 99; }
teardown_route_forge_read() { : > "$ROUTE_TRIP_FILE"; return 99; }
teardown_route_remote_default() { : > "$ROUTE_TRIP_FILE"; return 99; }
EOS

route_trip_arm() {
  ROUTE_TRIP_FILE=$TMP_ROOT/trip.$$.$RANDOM
  export ROUTE_TRIP_FILE
  rm -f "$ROUTE_TRIP_FILE"
}
route_trip_check() {  # <label>
  [ ! -e "$ROUTE_TRIP_FILE" ] || fail "$1: a barred path ran (a forge read, a remote read or a timed run)"
}

# The forge answer of the route owner, stubbed: the PR merged at the world's last merge commit.
route_stub_before() {
  printf '%s\nteardown_route_pr_landed() { TEARDOWN_ROUTE_HEADREF=fm/pr-7-head; TEARDOWN_ROUTE_MERGE=%s; return 0; }\n' "$ROUTE_TRIP_SNIPPET" "$ROUTE_MERGE"
}

# F1 (Main 1869): the content proof runs no merge machinery. A copy counts as landed only
# when, at every path it changed against the merge base, the merge commit holds the copy's
# exact entry (a deleted path is absent there). So no merge driver, textconv or external
# diff can run, whatever the repository's configuration: the lying-driver POLICY negative
# holds and the legitimate text twin routes under the same configuration. A merge driver in
# the configuration is only reported (a notice line), never a refusal.
test_a_configured_merge_driver_of_any_name_runs_nothing_and_the_twin_routes_while_the_policy_copy_is_kept() {
  local marker kind want
  make_world world-driver-config
  route_trip_arm
  marker=$TMP_ROOT/driver-ran
  for kind in none shadow-text other-name included-file command-scope; do
    rm -f "$marker"
    case "$kind" in
      none) want= ;;
      other-name) want=merge.mine.driver ;;
      *) want=merge.text.driver ;;
    esac
    config_driver() {  # applies the configuration of <kind> to $CR
      case "$kind" in
        shadow-text) git -C "$CR" config merge.text.driver "touch '$marker'; true" ;;
        other-name) git -C "$CR" config merge.mine.driver "touch '$marker'; true"; git -C "$CR" config merge.default mine ;;
        included-file)
          printf '[merge "text"]\n\tdriver = touch %s; true\n' "'$marker'" > "$CR/.git/extra.cfg"
          git -C "$CR" config include.path "$CR/.git/extra.cfg"
          ;;
      esac
    }
    prove_with_kind() {
      : > "$W/git.log"
      if [ "$kind" = command-scope ]; then
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=merge.text.driver GIT_CONFIG_VALUE_0="touch '$marker'; true" route_prove "$CR" "$CT" "$CM"
      else
        route_prove "$CR" "$CT" "$CM"
      fi
    }
    # The POLICY case: the copy sets required, the merge commit holds other.
    route_content_fixture "cfg-$kind" policy.txt 'POLICY=base\n' 'POLICY=required\n' 'POLICY=other\n'
    config_driver
    prove_with_kind
    assert_unproved "the POLICY case with a merge driver configured ($kind)" "policy.txt"
    [ ! -e "$marker" ] || fail "a configured merge driver ran ($kind): the proof ran machinery that a driver could hijack"
    ! grep -q 'merge-tree' "$W/git.log" || fail "the content proof ran git merge-tree ($kind)"
    # The legitimate twin: the merge commit holds the copy's file exactly. It routes under the same configuration.
    route_content_fixture "cfgtwin-$kind" policy.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n'
    config_driver
    prove_with_kind
    assert_proved "the legitimate text twin with a merge driver configured ($kind)"
    [ ! -e "$marker" ] || fail "a configured merge driver ran on the twin ($kind)"
    ! grep -q 'merge-tree' "$W/git.log" || fail "the content proof ran git merge-tree on the twin ($kind)"
    # The configured driver is a reported fact, not a refusal.
    if [ -n "$want" ]; then
      assert_contains "$PROVE_OUT" "$want" "the configured driver is not reported ($kind)"
    else
      assert_not_contains "$PROVE_OUT" "merge driver" "a notice about a merge driver appeared with none configured"
    fi
    # The original different-blob twin (the target changed the path further) is kept (Main 1887),
    # under the same configuration; the equal-blob twin above is the proved control.
    route_content_fixture "cfgfurther-$kind" policy.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=2\n'
    config_driver
    prove_with_kind
    assert_unproved "the different-blob twin with a merge driver configured ($kind)" "policy.txt"
    [ ! -e "$marker" ] || fail "a configured merge driver ran on the different-blob twin ($kind)"
    printf 'driver config %s: POLICY copy kept, twin proved, marker absent, no merge-tree; notice: %s\n' "$kind" "$(printf '%s' "$PROVE_OUT" | grep -a 'merge driver' | head -n 1 | cut -c1-130)"
  done
  route_trip_check "driver config"
  pass "with a merge driver configured in the repository (named text or any other name, by include file or by command scope) the content proof runs no merge: the POLICY copy is kept, the legitimate twin is proved under the same configuration, the marker stays absent, git merge-tree is never run, and the driver is only reported"
}

# F1 and F5, through the route: with a driver scripted to allow, a copy whose lines the
# merge commit lacks is kept with an empty driver argv. Unverified locally (see above).
test_an_allowing_driver_is_never_asked_for_a_copy_whose_lines_the_merge_commit_lacks() {
  local variant marker
  for variant in no-config shadow-text; do
    route_world "route-allow-$variant"
    marker=$W/driver-ran
    route_content_copy policy 7 policy.txt 'POLICY=base\n' 'POLICY=required\n' 'POLICY=other\n'
    route_content_copy twin 8 twin.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n'
    [ "$variant" != shadow-text ] || git -C "$SLOT" config merge.text.driver "touch '$marker'; true"
    route_trip_arm
    route_closeout plan policy "$(route_stub_before)"
    [ "$CO_ROUTE" = invalid ] && [ "$CO_RC" != 0 ] || fail "the copy whose lines the merge commit lacks was not kept ($variant: $CO_RC $CO_ROUTE): $CO_OUT"
    [ -z "$(route_calls_for policy)" ] || fail "the allowing driver was asked for the copy ($variant): $(route_calls_for policy)"
    [ ! -e "$marker" ] || fail "the configured merge driver ran ($variant)"
    route_closeout plan twin "$(route_stub_before)"
    [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "the legitimate twin did not route ($variant: $CO_RC $CO_ROUTE): $CO_OUT"
    [ "$(route_call_count twin)" = 1 ] || fail "the twin was not asked once: $(route_calls_for twin)"
    route_trip_check "allowing driver $variant"
  done
  pass "with a driver scripted to allow, a copy whose lines the merge commit lacks is kept with an empty driver argv (with no config, and with a configured text driver that never runs), and the legitimate twin routes in both"
}

# F2: the checkout check, on a real repository with the real functions and a git
# wrapper that fails or disturbs the reflog reads of the check, as the reviewer's falsifier does.
IFS= read -r -d '' ROUTE_GITWRAP_SNIPPET <<'EOS' || true
git() {
  case " $* " in
    *" reflog show "*)
      n=$(cat "$RL_COUNT"); n=$((n + 1)); printf '%s' "$n" > "$RL_COUNT"
      if [ "$RL_FAIL_FROM" != - ] && [ "$n" -ge "$RL_FAIL_FROM" ]; then return 128; fi
      if [ "$RL_APPEND_AT" = "$n" ]; then
        command git -C "$RL_REPO" switch -q other && command git -C "$RL_REPO" switch -q main
      fi
      ;;
  esac
  command git "$@"
}
EOS
IFS= read -r -d '' ROUTE_RL_SCRIPT <<'EOS' || true
set +u
TEARDOWN_CKO_OPEN=0
TEARDOWN_CKO_WHY=
teardown_route_checkout_open "$RL_REPO" copy || { printf 'check_rc=open-failed reads=%s reason=%s\n' "$(cat "$RL_COUNT")" "$TEARDOWN_CLOSEOUT_ROUTE_WHY"; exit 0; }
if [ "$RL_SWITCH" = 1 ]; then command git -C "$RL_REPO" switch -q pr-head && command git -C "$RL_REPO" switch -q main; fi
if [ "$RL_SWITCH" = 2 ]; then command git -C "$RL_REPO" switch -q other && command git -C "$RL_REPO" switch -q main; fi
if [ "$RL_REWRITE" = 1 ]; then
  f=$RL_REPO/.git/logs/HEAD
  n=$(wc -l < "$f" | tr -d ' ')
  awk -v n="$n" -v msg='checkout: moving from x to y' 'NR == n { i = index($0, "\t"); $0 = substr($0, 1, i - 1) "\t" msg } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
fi
[ "$RL_CLEAR" != 1 ] || TEARDOWN_CKO_ANCHOR=
rc=0
teardown_route_checkout_check "$RL_REPO" pr-head || rc=$?
printf 'check_rc=%s reads=%s reason=%s\n' "$rc" "$(cat "$RL_COUNT")" "$TEARDOWN_CKO_WHY"
EOS
route_reflog_scenario() {  # <name> <switch> <fail-from|-> <append-at|-> <rewrite> <clear-anchor>
  local name=$1 repo
  repo=$TMP_ROOT/reflog-$name
  rm -rf "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.name t
  git -C "$repo" config user.email t@example.invalid
  printf 'a\n' > "$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -qm base
  git -C "$repo" branch pr-head
  git -C "$repo" branch other
  printf 0 > "$TMP_ROOT/reflog-$name.count"
  ROUTE_RL_OUT=$(RL_REPO=$repo RL_COUNT=$TMP_ROOT/reflog-$name.count RL_SWITCH=$2 RL_FAIL_FROM=$3 RL_APPEND_AT=$4 RL_REWRITE=$5 RL_CLEAR=$6 \
    route_lib "$ROUTE_TRIP_SNIPPET
$ROUTE_GITWRAP_SNIPPET
$ROUTE_RL_SCRIPT" 2>&1)
  ROUTE_RL_RC=$(printf '%s\n' "$ROUTE_RL_OUT" | sed -n 's/^check_rc=\([^ ]*\) .*/\1/p' | tail -n 1)
  printf 'reflog %s: %s\n' "$name" "$(printf '%s' "$ROUTE_RL_OUT" | tail -n 1 | cut -c1-200)"
}
test_the_checkout_check_reads_the_reflog_once_and_stops_on_a_read_error_an_interleaved_entry_or_a_missing_anchor() {
  local switch_out
  make_world world-reflog
  route_trip_arm
  route_reflog_scenario stable 0 - - 0 0
  [ "$ROUTE_RL_RC" = 0 ] || fail "the stable control was refused: $ROUTE_RL_OUT"
  route_reflog_scenario switch 1 - - 0 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a readable switch and restore was accepted: $ROUTE_RL_OUT"
  assert_contains "$ROUTE_RL_OUT" "pr-head" "a readable switch and restore is not named"
  switch_out=$ROUTE_RL_OUT
  # Any checkout change in the window keeps every copy (Main 1887, Main 1900): a switch to an
  # unrelated branch and back counts although the PR's head branch is known and not named.
  route_reflog_scenario unrelated-switch 2 - - 0 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a switch to an unrelated branch and back was accepted: $ROUTE_RL_OUT"
  assert_contains "$ROUTE_RL_OUT" "gained" "an unrelated switch is not named as a change in the window: $ROUTE_RL_OUT"
  # The follow-up read of the check fails (the reviewer's first case). With one read there is no second one to lose.
  route_reflog_scenario failed-second-read 1 3 - 0 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a switch and restore was accepted when the follow-up reflog read failed: $ROUTE_RL_OUT"
  # The read of the check fails: no proof, so the stop flag.
  route_reflog_scenario read-error 1 2 - 0 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a failed reflog read was accepted: $ROUTE_RL_OUT"
  assert_contains "$ROUTE_RL_OUT" "cannot be read" "a reflog read error is not named"
  # Unrelated entries appended between the reads (the reviewer's second case), and before the read.
  route_reflog_scenario interleaved-between 1 - 3 0 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a switch and restore was accepted when unrelated entries were appended between the reads: $ROUTE_RL_OUT"
  route_reflog_scenario interleaved-before 1 - 2 0 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a switch among appended entries was accepted: $ROUTE_RL_OUT"
  assert_contains "$ROUTE_RL_OUT" "pr-head" "a switch among appended entries is not named"
  # The anchor: the newest entry of the first read must still stand where it stood.
  route_reflog_scenario anchor-rewritten 0 - - 1 0
  [ "$ROUTE_RL_RC" = 1 ] || fail "a rewritten newest entry was accepted: $ROUTE_RL_OUT"
  assert_contains "$ROUTE_RL_OUT" "no longer holds" "a rewritten newest entry is not named"
  route_reflog_scenario anchor-empty 0 - - 0 1
  [ "$ROUTE_RL_RC" = 1 ] || fail "an empty anchor was accepted: $ROUTE_RL_OUT"
  assert_contains "$switch_out" "reads=2" "the check did not read the reflog once (one read at the first step, one at the check): $switch_out"
  route_trip_check "checkout check"
  pass "the checkout check reads the HEAD reflog once, finds a switch and restore (to the PR's head branch or to an unrelated one) even when a follow-up read fails or unrelated entries are appended, refuses on a read error, a rewritten newest entry and an empty anchor, and accepts the stable control"
}

# F2 through the route owner: the post-call check sets the stop flag. Unverified locally.
test_a_reflog_read_error_a_masked_interleaving_or_a_rewritten_anchor_sets_the_stop_flag() {
  local variant
  for variant in quiet read-error failed-second-read interleaved anchor-rewritten; do
    route_world "stopflag-$variant"
    git -C "$SLOT" branch fm/pr-7-head "$ROUTE_MERGE"
    route_copy zz-a 7
    route_trip_arm
    printf '0' > "$W/rl.count"
    export RL_REPO=$SLOT RL_COUNT=$W/rl.count RL_FAIL_FROM=- RL_APPEND_AT=-
    mkdir -p "$W/ans/zz-a"
    case "$variant" in
      read-error) RL_FAIL_FROM=3 ;;
      failed-second-read)
        printf 'git -C "%s" checkout -q fm/pr-7-head && git -C "%s" checkout -q main\n' "$SLOT" "$SLOT" > "$W/ans/zz-a/plan.after"
        RL_FAIL_FROM=4
        ;;
      interleaved)
        printf 'git -C "%s" checkout -q fm/pr-7-head && git -C "%s" checkout -q main\n' "$SLOT" "$SLOT" > "$W/ans/zz-a/plan.after"
        RL_APPEND_AT=4
        ;;
      anchor-rewritten)
        # shellcheck disable=SC2016 # the hook expands its own variables when it runs
        printf 'f=%s/.git/logs/HEAD; n=$(wc -l < "$f" | tr -d " "); awk -v n="$n" -v msg="checkout: moving from x to y" %s "$f" > "$f.new" && mv "$f.new" "$f"\n' "$SLOT" "'NR == n { i = index(\$0, \"\\t\"); \$0 = substr(\$0, 1, i - 1) \"\\t\" msg } { print }'" > "$W/ans/zz-a/plan.after"
        ;;
    esac
    route_closeout plan zz-a "$(route_stub_before)
$ROUTE_GITWRAP_SNIPPET"
    route_trip_check "stop flag $variant"
    if [ "$variant" = quiet ]; then
      [ "$CO_RC" = 0 ] && [ "$CO_SWITCHED" != 1 ] || fail "the quiet control did not route without a stop ($CO_RC $CO_SWITCHED): $CO_OUT"
    else
      [ "$CO_SWITCHED" = 1 ] || fail "the stop flag was not set ($variant: rc $CO_RC): $CO_OUT"
      [ "$CO_RC" != 0 ] || fail "the route reported success although the stop flag was set ($variant)"
    fi
  done
  pass "through the route owner, a failed post-call reflog read, a failed or masked follow-up read, unrelated entries landing between reads and a rewritten newest entry each set the stop flag, and the quiet control routes without it"
}

# F3: the temporary-refusal classifier of the sweep, loaded alone from the sweep script
# and run in the library bash. A refusal on the --pr route is temporary only when it is
# the called PR's complete fifteen-key envelope; anything else is permanent.
test_a_refusal_is_temporary_only_when_it_is_the_called_prs_complete_envelope() {
  local fn valid out
  make_world world-temporary-refusal
  fn=$(awk '/^execute_refusal_is_temporary\(\) \{/ { p = 1 } p { print } p && /^}/ { exit }' "$SWEEP")
  [ -n "$fn" ] || fail "the sweep has no execute_refusal_is_temporary function to load"
  # shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
  temp_probe() {  # <label> <expected 0|1> <doc> [<called pr>]
    out=$(CASE_ROUTE=pr CASE_PR=${4:-7} CASE_STDOUT=$3 \
      route_lib "$fn"'
TEARDOWN_CLOSEOUT_ROUTE=$CASE_ROUTE; TEARDOWN_CLOSEOUT_ROUTE_PR=$CASE_PR; TEARDOWN_CLOSEOUT_STDOUT=$CASE_STDOUT; TEARDOWN_CLOSEOUT_OUT=
rc=0; execute_refusal_is_temporary 3 || rc=$?; printf "rc=%s" "$rc"' 2>&1)
    assert_equals "rc=$2" "$out" "$1: the temporary-refusal classifier answered $out, not rc=$2 (rc=0 is temporary)"
    printf 'temporary refusal, %s: %s\n' "$1" "$([ "$out" = rc=0 ] && echo temporary || echo permanent)"
  }
  valid=$(route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' 7)
  temp_probe "the complete envelope for the called PR (the scripted temporary answer)" 0 "$valid"
  temp_probe "a complete envelope with the live-or-unknown reason" 0 "$(route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_skipped_live_or_unknown"' 7)"
  temp_probe "a complete envelope for PR 8 in answer to PR 7" 1 "$(route_envelope BLOCKED '["cleanup_gate"]' false '"cleanup_lease_conflict"' 8)"
  temp_probe "an envelope with evidence_digest missing" 1 "$(printf '%s' "$valid" | jq -c 'del(.evidence_digest)')"
  temp_probe "an envelope with an extra key" 1 "$(printf '%s' "$valid" | jq -c '. + {extra: 1}')"
  temp_probe "an envelope whose pr is the string 7" 1 "$(printf '%s' "$valid" | jq -c '.pr = "7"')"
  temp_probe "an envelope whose pr is null" 1 "$(printf '%s' "$valid" | jq -c '.pr = null')"
  temp_probe "a removal claim" 1 "$(printf '%s' "$valid" | jq -c '.worktree_removed = true')"
  temp_probe "a retained-tree signal" 1 "$(printf '%s' "$valid" | jq -c '.next_command = "archive_then_retain_tree"')"
  # The plain lane is unchanged: its refusal is the {"allowed": false, "reason": ...} document.
  # shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
  out=$(CASE_ROUTE='' CASE_PR='' CASE_STDOUT='{"allowed": false, "reason": "cleanup_lease_conflict"}' \
    route_lib "$fn"'
TEARDOWN_CLOSEOUT_ROUTE=$CASE_ROUTE; TEARDOWN_CLOSEOUT_ROUTE_PR=$CASE_PR; TEARDOWN_CLOSEOUT_STDOUT=$CASE_STDOUT; TEARDOWN_CLOSEOUT_OUT=
rc=0; execute_refusal_is_temporary 3 || rc=$?; printf "rc=%s" "$rc"' 2>&1)
  assert_equals "rc=0" "$out" "the plain lane's temporary refusal is no longer temporary"
  pass "a refusal on the --pr route is temporary only when it is exactly the fifteen-key envelope for the called PR with a cleanup_gate predicate and a temporary reason; another PR, a missing or extra key, a string or null pr, a removal claim and a retained-tree signal are permanent, and the plain lane is unchanged"
}

# F4: the forge timeout override is honoured or refused with its value named, never a
# silent 60. The forge and remote reads are stubbed; only the value they receive is seen.
IFS= read -r -d '' ROUTE_OV_PRE <<'EOS' || true
fm_timeout_perl_bound() { : > "$ROUTE_TRIP_FILE"; return 99; }
fm_run_timed() { : > "$ROUTE_TRIP_FILE"; return 99; }
gh() { return 1; }
teardown_route_forge_read() { PROBE_BOUND=$1; TEARDOWN_ROUTE_FORGE_OUT=$(printf 'MERGED\t%s\tfm/pr-7-head' "$OV_MERGE"); return 0; }
teardown_route_remote_default() { TEARDOWN_ROUTE_REMOTE_DEFAULT=main; return 0; }
PROBE_BOUND=; TEARDOWN_CLOSEOUT_ROUTE_WHY=; TEARDOWN_ROUTE_BASE=
rc=0; teardown_route_pr_landed "$OV_REPO" 7 || rc=$?
printf 'route_rc=%s bound=%s reason=%s\n' "$rc" "$PROBE_BOUND" "$TEARDOWN_CLOSEOUT_ROUTE_WHY"
EOS
test_the_forge_timeout_override_is_honoured_or_refused_and_never_silently_sixty() {
  local repo value out merge
  make_world world-forge-override
  repo=$TMP_ROOT/override-repo
  rm -rf "$repo"
  git init -q -b main "$repo"
  git -C "$repo" config user.name t
  git -C "$repo" config user.email t@example.invalid
  printf 'a\n' > "$repo/f"
  git -C "$repo" add f
  git -C "$repo" commit -qm base
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  git -C "$repo" config remote.origin.url https://github.com/example/demo.git
  merge=$(git -C "$repo" rev-parse HEAD)
  route_trip_arm
  out=$(unset FM_TEARDOWN_FORGE_TIMEOUT; OV_REPO=$repo OV_MERGE=$merge route_lib "$ROUTE_OV_PRE" 2>&1)
  assert_contains "$out" "route_rc=0 bound=60 " "the default bound is not 60: $out"
  for value in 12 10000 999999999; do
    out=$(FM_TEARDOWN_FORGE_TIMEOUT=$value OV_REPO=$repo OV_MERGE=$merge route_lib "$ROUTE_OV_PRE" 2>&1)
    assert_contains "$out" "route_rc=0 bound=$value " "the override $value was not honoured: $out"
    printf 'forge timeout override %s: honoured (%s)\n' "$value" "$(printf '%s' "$out" | cut -c1-60)"
  done
  for value in '' abc 0 -5 1.5 007 1000000000; do
    out=$(FM_TEARDOWN_FORGE_TIMEOUT=$value OV_REPO=$repo OV_MERGE=$merge route_lib "$ROUTE_OV_PRE" 2>&1)
    assert_contains "$out" "route_rc=1 bound= " "the bad override $value did not refuse before a forge read: $out"
    assert_contains "$out" "FM_TEARDOWN_FORGE_TIMEOUT" "the refusal for $value does not name the setting: $out"
    assert_contains "$out" "'$value'" "the refusal for $value does not name the value: $out"
    printf 'forge timeout override %s: refused (%s)\n' "$value" "$(printf '%s' "$out" | sed 's/.*reason=//' | cut -c1-150)"
  done
  route_trip_check "forge timeout override"
  pass "the forge timeout is 60 when the setting is unset, an override of 12, 10000 or 999999999 seconds is honoured, and a value that is empty or not a whole number of seconds from 1 to 999999999 refuses the route with the setting and the value named before any forge read"
}


# Main 1919 F7: FM_SUPERSEDENCE_CASES names a captain-private table that CI never has, so
# an unset variable is one named skip line (never an "ok" line, so never a pass, and never
# a failure, whatever CI is set to); a variable that is set but names a directory or a table
# that cannot be read fails. The grader runs the table with the variable set (R5 Verify).
# shellcheck disable=SC2030,SC2031 # each subshell sets its own CI and FM_SUPERSEDENCE_CASES on purpose
test_the_r5_table_prints_one_named_skip_and_no_pass_when_the_staged_cases_variable_is_unset() {
  local out rc ci req lines
  make_world world-staged-unset
  for ci in unset true; do
    for req in unset 1; do
      rc=0
      out=$( (
        unset FM_SUPERSEDENCE_CASES CI FM_SUPERSEDENCE_CASES_REQUIRED
        [ "$ci" = unset ] || export CI=$ci
        [ "$req" = unset ] || export FM_SUPERSEDENCE_CASES_REQUIRED=$req
        test_the_recorded_cases_are_decided_by_their_records_and_the_drivers_scripted_answers
      ) 2>&1 ) || rc=$?
      [ "$rc" = 0 ] || fail "the R5 table failed with FM_SUPERSEDENCE_CASES unset (CI=$ci, REQUIRED=$req): it is a skip, not a failure: $out"
      lines=$(printf '%s\n' "$out" | grep -c .)
      [ "$lines" = 1 ] || fail "the R5 table printed $lines lines with FM_SUPERSEDENCE_CASES unset (CI=$ci, REQUIRED=$req), not one named skip: $out"
      assert_equals "skip: R5 table owed to the grader: FM_SUPERSEDENCE_CASES unset" "$out" "the skip line is not the named skip (CI=$ci, REQUIRED=$req)"
      case "$out" in 'ok - '*) fail "the skip counted as a pass: $out" ;; esac
    done
  done
  pass "with FM_SUPERSEDENCE_CASES unset the R5 table prints the one named skip line 'R5 table owed to the grader: FM_SUPERSEDENCE_CASES unset', prints no ok line and does not fail, with CI=true or the older required setting changing nothing"
}

# shellcheck disable=SC2030,SC2031 # each subshell sets its own CI and FM_SUPERSEDENCE_CASES on purpose
test_the_r5_table_fails_when_the_staged_cases_variable_names_a_directory_or_table_that_cannot_be_read() {
  local dir rc out label
  make_world world-staged-unreadable
  rm -rf "$TMP_ROOT/staged-case"
  mkdir -p "$TMP_ROOT/staged-case/empty" "$TMP_ROOT/staged-case/only-table" "$TMP_ROOT/staged-case/table-is-dir/d7-supersedence-table.md" "$TMP_ROOT/staged-case/present"
  : > "$TMP_ROOT/staged-case/only-table/d7-supersedence-table.md"
  : > "$TMP_ROOT/staged-case/table-is-dir/d7-closeout-driver-report.md"
  : > "$TMP_ROOT/staged-case/present/d7-supersedence-table.md"
  : > "$TMP_ROOT/staged-case/present/d7-closeout-driver-report.md"
  for label in missing empty only-table table-is-dir empty-string; do
    case "$label" in
      missing) dir=$TMP_ROOT/staged-case/no-such-directory ;;
      empty-string) dir= ;;
      *) dir=$TMP_ROOT/staged-case/$label ;;
    esac
    rc=0
    out=$( (
      unset CI FM_SUPERSEDENCE_CASES_REQUIRED
      export FM_SUPERSEDENCE_CASES=$dir
      test_the_recorded_cases_are_decided_by_their_records_and_the_drivers_scripted_answers
    ) 2>&1 ) || rc=$?
    [ "$rc" != 0 ] || fail "the R5 table passed or skipped with FM_SUPERSEDENCE_CASES set to an unreadable value ($label): $out"
    assert_contains "$out" "FM_SUPERSEDENCE_CASES" "the failure does not name the variable ($label)"
    case "$out" in *'owed to the grader'*) fail "an unreadable value was reported as the unset skip ($label): $out" ;; esac
  done
  # The control: both files present and readable pass the gate, with CI=true too.
  rc=0
  ( export CI=true FM_SUPERSEDENCE_CASES="$TMP_ROOT/staged-case/present"; route_staged_cases_gate ) >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] || fail "the gate refused readable staged cases under CI=true ($rc)"
  pass "with FM_SUPERSEDENCE_CASES set to a missing directory, an empty directory, a directory with one table, a table that is a directory or an empty string the R5 table fails and names the variable, while a readable pair passes the gate"
}

# --- code round 4 (Main 1887): helper-level cases, libraries only -------------------
# Same rules as round 2: nothing below runs a sweep in apply mode, reads a forge, reaches
# bin/fm-teardown.sh, starts a driver or signals a process. The route owner is called
# without its driver, with the forge answer stubbed and the tripwires armed.

# F2 (Main 1887): output of git that cannot be parsed refuses. The fake git replies with a
# canned diff-tree or ls-tree answer (exit 0); a genuine empty change and a real nonempty
# one, replayed, are the controls.
test_the_content_proof_refuses_git_output_it_cannot_parse_and_accepts_a_genuine_empty_change() {
  local base zero sha tmpf
  make_world world-content-malformed
  route_trip_arm
  route_content_fixture mal f.txt 'a\n' 'a\nadded\n' 'a\nadded\n'
  route_prove "$CR" "$CT" "$CM"; assert_proved "the real diff (control)"
  base=$(git -C "$CR" merge-base "$CT" "$CM")
  zero=0000000000000000000000000000000000000000
  sha=$(git -C "$CR" rev-parse "$CT:f.txt")
  tmpf=$W/dt.canned
  : > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_proved "a genuine empty change (control)"
  git -C "$CR" diff-tree -r --no-renames --no-ext-diff --no-textconv -z --raw "$base" "$CT" > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_proved "a real nonempty diff, replayed (control)"
  printf ':100644 100644 %s %s M\0' "$zero" "$sha" > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_unproved "a metadata record with no path" "cannot be parsed"
  printf ':100644 100644 %s %s M' "$zero" "$sha" > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_unproved "an unterminated metadata record" "cannot be parsed"
  printf ':100644 100644 %s %s M\0f.txt' "$zero" "$sha" > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_unproved "an unterminated path" "cannot be parsed"
  printf ':100644 M\0f.txt\0' > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_unproved "metadata with missing fields" "cannot be parsed"
  # The raw shape needs its leading colon (Main 1900): a complete record without it is unparsable.
  printf '100644 100644 %s %s M\0f.txt\0' "$zero" "$sha" > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_unproved "a metadata record without the leading colon" "cannot be parsed"
  printf ':100644 100644 %s %s M\0\0' "$zero" "$sha" > "$tmpf"
  FAKE_GIT_DIFFTREE_FILE=$tmpf route_prove "$CR" "$CT" "$CM"; assert_unproved "an empty path" "cannot be parsed"
  # The deletion branch: the merge commit's entry is read with ls-tree.
  printf ':100644 000000 %s %s D\0gone.txt\0' "$sha" "$zero" > "$tmpf"
  : > "$W/ls.canned"
  FAKE_GIT_DIFFTREE_FILE=$tmpf FAKE_GIT_LSTREE_FILE=$W/ls.canned route_prove "$CR" "$CT" "$CM"; assert_proved "a deletion the merge commit also made, an empty ls-tree answer (control)"
  printf '100644 blob %s\tgone.txt' "$sha" > "$W/ls.canned"
  FAKE_GIT_DIFFTREE_FILE=$tmpf FAKE_GIT_LSTREE_FILE=$W/ls.canned route_prove "$CR" "$CT" "$CM"; assert_unproved "an unterminated ls-tree entry for a deleted path" "cannot be parsed"
  printf '100644 blob %s\tgone.txt\0' "$sha" > "$W/ls.canned"
  FAKE_GIT_DIFFTREE_FILE=$tmpf FAKE_GIT_LSTREE_FILE=$W/ls.canned route_prove "$CR" "$CT" "$CM"; assert_unproved "a deleted path the merge commit still has" "gone.txt"
  route_trip_check "malformed git output"
  pass "metadata with no path, an unterminated record or path, missing fields, no leading colon, an empty path and an unterminated ls-tree entry keep the copy, while a genuine empty change, a replayed real diff and a deletion the merge commit also made are proved"
}

# F3 (Main 1887): the checkout window is published while the route is still proving, and a
# switch during a proof that then refuses is reported. The forge answer is stubbed; the
# route owner runs without its driver.
read -r -d '' ROUTE_PROVING_SCRIPT <<'EOS' || true
set +u
TEARDOWN_ROUTE_DATA=$ROUTE_DATA
TEARDOWN_CLOSEOUT_ROUTE_FILE=$ROUTE_FILE
teardown_route_pr_landed() {
  [ -z "$STUB_ACTOR" ] || { git -C "$ROUTE_SLOT" switch -q fm/pr-7-head && git -C "$ROUTE_SLOT" switch -q main; }
  [ -z "$STUB_SEE" ] || cp "$TEARDOWN_CLOSEOUT_ROUTE_FILE" "$STUB_SEE"
  if [ -n "$STUB_REFUSE" ]; then TEARDOWN_CLOSEOUT_ROUTE_WHY="the forge says no"; return 1; fi
  TEARDOWN_ROUTE_HEADREF=fm/pr-7-head
  TEARDOWN_ROUTE_MERGE=$STUB_MERGE
  return 0
}
TEARDOWN_CLOSEOUT_SWITCHED=0
rc=0
teardown_closeout_route "$ROUTE_SLOT" "$ROUTE_COPY" || rc=$?
teardown_closeout_route_publish
printf 'rc=%s route=%s switched=%s why=%s\n' "$rc" "$TEARDOWN_CLOSEOUT_ROUTE" "$TEARDOWN_CLOSEOUT_SWITCHED" "$TEARDOWN_CLOSEOUT_ROUTE_WHY"
teardown_route_lock_release
teardown_route_checkout_close
EOS
route_proving_run() {  # <actor 0|1> <refuse 0|1> <see-file|-> : sets ROUTE_PROVING_OUT
  ROUTE_PROVING_OUT=$(ROUTE_SLOT=$SLOT ROUTE_COPY=$(copy_path zz-a) ROUTE_DATA=$HOMED/data ROUTE_FILE=$W/routefile STUB_MERGE=$ROUTE_MERGE \
    STUB_ACTOR=$([ "$1" = 1 ] && echo 1 || true) STUB_REFUSE=$([ "$2" = 1 ] && echo 1 || true) STUB_SEE=$([ "$3" = - ] || echo "$3") \
    route_lib "$ROUTE_TRIP_SNIPPET
$ROUTE_PROVING_SCRIPT" 2>&1)
}
test_the_route_publishes_its_checkout_window_while_proving_and_reports_a_switch_when_a_proof_refuses() {
  local variant
  for variant in window refuse-switch refuse-quiet content-switch; do
    route_world "route-proving-$variant"
    git -C "$SLOT" branch fm/pr-7-head "$ROUTE_MERGE"
    route_trip_arm
    case "$variant" in
      window)
        route_copy zz-a 7
        route_proving_run 0 0 "$W/routefile.seen"
        assert_contains "$ROUTE_PROVING_OUT" "rc=0 route=pr switched=0" "the quiet route did not complete: $ROUTE_PROVING_OUT"
        [ "$(sed -n 1p "$W/routefile.seen")" = proving ] || fail "the file seen by the forge step is not in state proving: $(cat "$W/routefile.seen")"
        [ "$(sed -n 4p "$W/routefile.seen")" = "$(copy_path zz-a)" ] || fail "the window's copy is not published while proving: $(cat "$W/routefile.seen")"
        [ -n "$(sed -n 10p "$W/routefile.seen")" ] || fail "the window's anchor is not published while proving: $(cat "$W/routefile.seen")"
        ;;
      refuse-switch)
        route_copy zz-a 7
        route_proving_run 1 1 -
        assert_contains "$ROUTE_PROVING_OUT" "rc=1 route=invalid switched=1" "a switch during a proof that then refused was not reported: $ROUTE_PROVING_OUT"
        [ "$(sed -n 9p "$W/routefile")" = 1 ] || fail "the route file does not carry the switch: $(cat "$W/routefile")"
        ;;
      refuse-quiet)
        route_copy zz-a 7
        route_proving_run 0 1 -
        assert_contains "$ROUTE_PROVING_OUT" "rc=1 route=invalid switched=0" "an ordinary refusal was reported as a switch: $ROUTE_PROVING_OUT"
        ;;
      content-switch)
        route_content_copy zz-a 7 policy.txt 'POLICY=base\n' 'POLICY=required\n' 'POLICY=other\n'
        route_proving_run 1 0 -
        assert_contains "$ROUTE_PROVING_OUT" "rc=1 route=invalid switched=1" "a switch during a proof that the content proof then refused was not reported: $ROUTE_PROVING_OUT"
        ;;
    esac
    route_trip_check "proving window $variant"
    printf 'proving %s: %s\n' "$variant" "$(printf '%s' "$ROUTE_PROVING_OUT" | tail -n 1 | cut -c1-140)"
  done
  pass "the route's checkout window (copy, branch, HEAD, position, anchor) is in the route file while it is still proving, a switch during a proof that then refuses (at the forge step or at the content proof) is reported, and an ordinary refusal is not"
}

# F3, the parent's side: a plan killed while proving leaves a route file in state proving
# with the window in it. The loader reads it whatever the state and the post-timeout check
# stops on any change in the window; with the PR's head branch not known yet, any new
# entry in the HEAD reflog counts.
read -r -d '' ROUTE_KILLED_SCRIPT <<'EOS' || true
set +u
teardown_closeout_route_file_load "$ROUTE_SEEN"
printf 'load: route=%s open=%s copy=%s\n' "$TEARDOWN_CLOSEOUT_ROUTE" "$TEARDOWN_CKO_OPEN" "$TEARDOWN_CKO_COPY"
rc=0; teardown_route_plan_killed_check "$ROUTE_SLOT" || rc=$?
printf 'quiet: rc=%s\n' "$rc"
git -C "$ROUTE_SLOT" switch -q fm/pr-7-head && git -C "$ROUTE_SLOT" switch -q main
teardown_closeout_route_file_load "$ROUTE_SEEN"
rc=0; teardown_route_plan_killed_check "$ROUTE_SLOT" || rc=$?
printf 'switched: rc=%s why=%s\n' "$rc" "$TEARDOWN_CKO_WHY"
EOS
test_a_plan_killed_while_proving_is_read_for_a_checkout_change_by_the_parent() {
  local out
  route_world route-killed-while-proving
  git -C "$SLOT" branch fm/pr-7-head "$ROUTE_MERGE"
  route_copy zz-a 7
  route_trip_arm
  route_proving_run 0 0 "$W/routefile.seen"
  [ -s "$W/routefile.seen" ] || fail "the child left no route file to load"
  out=$(ROUTE_SLOT=$SLOT ROUTE_SEEN=$W/routefile.seen route_lib "$ROUTE_TRIP_SNIPPET
$ROUTE_KILLED_SCRIPT" 2>&1)
  assert_contains "$out" "load: route=proving open=1 copy=$(copy_path zz-a)" "the loader did not open the window of a plan killed while proving: $out"
  assert_contains "$out" "quiet: rc=0" "the post-timeout check refused a checkout that did not change: $out"
  assert_contains "$out" "switched: rc=1" "the post-timeout check missed a switch and restore while proving: $out"
  assert_contains "$out" "not known yet" "the post-timeout refusal does not say why any new reflog entry counts: $out"
  route_trip_check "killed while proving"
  pass "the loader opens the window of a plan killed while proving, and the post-timeout check accepts a quiet checkout and stops on a switch and restore even though the PR's head branch is not known yet"
}

# F1: a plan killed after its first publish and before its window opened leaves the parent
# no window for that copy. The sweep plans copies in reverse path order. Copy A in slot 2 (its
# own clone, on its own branch) is planned through the route and refused, so the parent
# loaded A's window and ran no execute that would close it. Copy B in slot 1 then hangs in the
# route's lock step (its read of the slot's origin), which comes after the first publish and
# before the window opens, and is killed at the plan bound. The parent must not read slot 1
# against A's window of slot 2: no switch, no stopped run, and a later copy is released.
test_a_plan_killed_before_its_window_opened_is_not_read_against_the_previous_copys_window() {
  local project slot2 line
  route_world route-killed-before-window
  project=$SLOT
  slot2="$TH/pool1/2/repo"
  mkdir -p "$TH/pool1/2"
  git clone -q "$W/origin.git" "$slot2"
  git -C "$slot2" config "url.file://$(cd "$W/origin.git" && pwd).insteadOf" "$ROUTE_REMOTE_URL"
  git -C "$slot2" remote set-url origin "$ROUTE_REMOTE_URL"
  git -C "$slot2" fetch -q origin
  git -C "$slot2" checkout -q -b fm/slot-2 "$ROUTE_MERGE"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}\n' "$project" "$slot2" > "$TH/pool1/treehouse-state.json"
  install_driver "$slot2" "$W"
  route_install_row_driver "$slot2" "$W"
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_set_pr "$W/forge" 8 MERGED "$ROUTE_MERGE"
  route_copy z-killed 8
  route_copy c-later 8
  SLOT=$slot2
  route_copy a-refused 7 refuse
  SLOT=$project
  cat > "$W/origin-url-hook" <<EOF
[ "\$2" = "$project" ] || exit 0
[ ! -e "$W/origin-url-hung" ] || exit 0
: > "$W/origin-url-hung"
sleep 30
EOF
  FAKE_GIT_ORIGIN_URL_HOOK=$W/origin-url-hook FM_COPY_SWEEP_PLAN_TIMEOUT=5 FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=100 route_sweep --apply
  [ "$RC" = 0 ] || fail "killed before window: the run failed ($RC): $OUT"
  [ -e "$W/origin-url-hung" ] || fail "killed before window: copy B's plan never reached the route's lock step: $OUT"
  SLOT=$slot2
  route_assert_kept a-refused "killed before window"
  assert_contains "$(route_line_of a-refused)" "verification_stale_or_uncovered_paths" "killed before window: copy A was not held by its refused plan"
  SLOT=$project
  route_assert_kept z-killed "killed before window"
  assert_equals "" "$(route_calls_for z-killed)" "killed before window: copy B reached the driver"
  line=$(route_line_of z-killed)
  assert_contains "$line" "did not answer within 5s" "killed before window: copy B's plan was not killed at the plan bound"
  assert_not_contains "$line" "was switched" "killed before window: copy B was read against copy A's window"
  assert_not_contains "$OUT" "was switched" "killed before window: a switch was reported"
  assert_not_contains "$OUT" "SKIPPED" "killed before window: the run stopped and skipped a pending copy"
  route_assert_released c-later "killed before window"
  route_assert_calls c-later 8 "killed before window"
  pass "a plan killed after its first publish and before its window opened is not read against the previous copy's window: no switch is reported, the run goes on and a later eligible copy is released"
}

# F4 (Main 1887): a claimed outer hold at another path refuses. There is no fall-through to
# the computed lock, which stays free.
read -r -d '' ROUTE_CLAIM_SCRIPT <<'EOS' || true
set +u
lock=$(fm_treehouse_project_lock_path "$ROUTE_SLOT")
TEARDOWN_ROUTE_LOCK_HELD=$ROUTE_ELSEWHERE
rc=0; teardown_route_lock_take "$ROUTE_SLOT" copy || rc=$?
printf 'elsewhere: rc=%s own=%s why=%s\n' "$rc" "$TEARDOWN_ROUTE_LOCK_OWN" "$TEARDOWN_CLOSEOUT_ROUTE_WHY"
teardown_route_lock_release
if fm_project_lock_try "$lock" probe 2>/dev/null; then echo 'computed lock: free'; fm_project_lock_release "$lock"; else echo 'computed lock: taken'; fi
TEARDOWN_ROUTE_LOCK_HELD=
rc=0; teardown_route_lock_take "$ROUTE_SLOT" copy || rc=$?
printf 'no claim: rc=%s own=%s\n' "$rc" "$TEARDOWN_ROUTE_LOCK_OWN"
teardown_route_lock_release
fm_project_lock_try "$lock" outer || { echo 'outer-take-failed'; exit 0; }
TEARDOWN_ROUTE_LOCK_HELD=$lock
rc=0; teardown_route_lock_take "$ROUTE_SLOT" copy || rc=$?
printf 'matching claim: rc=%s own=%s\n' "$rc" "$TEARDOWN_ROUTE_LOCK_OWN"
teardown_route_lock_release
fm_project_lock_release "$lock"
EOS
test_a_claimed_outer_hold_at_another_path_refuses_and_never_falls_through_to_the_computed_lock() {
  local out
  route_world route-claim-elsewhere
  route_trip_arm
  out=$(ROUTE_SLOT=$SLOT ROUTE_ELSEWHERE=$TMP_ROOT/not-the-lock route_lib "$ROUTE_TRIP_SNIPPET
$ROUTE_CLAIM_SCRIPT" 2>&1)
  assert_contains "$out" "elsewhere: rc=1 own=0" "a claimed hold at another path did not refuse without taking a lock: $out"
  assert_contains "$out" "computed lock: free" "the computed lock was taken although the claim named another path: $out"
  assert_contains "$out" "no claim: rc=0 own=1" "the no-claim control did not take its own lock: $out"
  assert_contains "$out" "matching claim: rc=0 own=0" "the matching, proved claim control was not borrowed: $out"
  route_trip_check "claim elsewhere"
  pass "a claimed outer hold at a path other than the computed lock refuses with no lock taken and the computed lock still free, while no claim takes its own lock and a matching proved claim is borrowed"
}

# F5 (Main 1887): after a plan is killed, the parent releases the plan's project lock only
# when the lock's record names the killed plan's pid and that pid is gone; otherwise the lock
# is left for the lock library's own dead-owner recovery and the note says so. A subshell that
# takes the lock and ends stands in for the killed plan: no process is signalled.
read -r -d '' ROUTE_REAP_SCRIPT <<'EOS' || true
set +u
lock=$(fm_treehouse_project_lock_path "$ROUTE_SLOT")
taken() { ( fm_project_lock_try "$lock" plan >/dev/null 2>&1; fm_current_pid p; printf '%s' "$p" ); }
gone() { if [ -e "$lock" ] || [ -L "$lock" ]; then echo present; else echo gone; fi; }
dead=$(taken)
teardown_route_lock_reap_killed "$lock" "$dead"
printf 'dead owner named: %s note=%s\n' "$(gone)" "$TEARDOWN_ROUTE_LOCK_NOTE"
dead=$(taken)
teardown_route_lock_reap_killed "$lock" 999998
printf 'other pid named: %s note=%s\n' "$(gone)" "$TEARDOWN_ROUTE_LOCK_NOTE"
fm_lock_reap_dead_link "$lock" >/dev/null 2>&1 || true
fm_project_lock_try "$lock" live >/dev/null 2>&1 || { echo 'live-take-failed'; exit 0; }
fm_current_pid me
teardown_route_lock_reap_killed "$lock" "$me"
printf 'live owner named: %s note=%s\n' "$(gone)" "$TEARDOWN_ROUTE_LOCK_NOTE"
fm_project_lock_release "$lock"
teardown_route_lock_reap_killed "$lock" "$dead"
printf 'no lock left: %s note=%s\n' "$(gone)" "$TEARDOWN_ROUTE_LOCK_NOTE"
EOS
test_the_parent_releases_a_killed_plans_lock_only_when_its_owner_is_gone_and_the_record_names_it() {
  local out
  route_world route-lock-reap
  route_trip_arm
  out=$(ROUTE_SLOT=$SLOT route_lib "$ROUTE_TRIP_SNIPPET
$ROUTE_REAP_SCRIPT" 2>&1)
  assert_contains "$out" "dead owner named: gone" "a dead owner's lock that its record names was not released: $out"
  assert_contains "$out" "other pid named: present" "a lock whose record names another pid was released: $out"
  assert_contains "$out" "live owner named: present" "a live owner's lock was released: $out"
  assert_contains "$out" "no lock left: gone" "the no-lock control changed something: $out"
  route_trip_check "lock reap"
  pass "the lock of a killed plan is released only when its record names the plan's pid and that pid is gone; another pid in the record and a live owner leave it for dead-owner recovery, and the note says what happened"
}

# Main 1887 inference (ii): the lock is keyed by the slot's registered project on both
# routes. The project comes from the slot's git common directory (a Treehouse slot shares
# its project's); a slot whose own lock key differs from its project's refuses.
# shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variables
test_the_route_keys_its_lock_by_the_slots_registered_project_and_refuses_a_slot_whose_origin_differs() {
  local proj wt clone out lock_proj lock_clone
  route_world route-lock-project
  proj=$TMP_ROOT/lkp-project
  wt=$TMP_ROOT/lkp-slot
  clone=$TMP_ROOT/lkp-clone
  rm -rf "$proj" "$wt" "$clone"
  git init -q -b main "$proj"
  git -C "$proj" config user.name t
  git -C "$proj" config user.email t@example.invalid
  printf 'a\n' > "$proj/f"
  git -C "$proj" add f
  git -C "$proj" commit -qm base
  git -C "$proj" remote add origin https://github.com/example/the-project.git
  git -C "$proj" worktree add -q -b slotbranch "$wt"
  git init -q -b main "$clone"
  git -C "$clone" remote add origin https://github.com/example/another-origin.git
  route_trip_arm
  out=$(ROUTE_PROJ=$proj ROUTE_WT=$wt ROUTE_CLONE=$clone route_lib "$ROUTE_TRIP_SNIPPET"'
set +u
printf "project_of linked slot=%s\n" "$(teardown_route_project_of "$ROUTE_WT")"
printf "project_of clone=%s\n" "$(teardown_route_project_of "$ROUTE_CLONE")"
printf "lock_proj=%s\nlock_clone=%s\n" "$(fm_treehouse_project_lock_path "$ROUTE_PROJ")" "$(fm_treehouse_project_lock_path "$ROUTE_CLONE")"
TEARDOWN_ROUTE_PROJECT=
rc=0; teardown_route_lock_take "$ROUTE_WT" copy || rc=$?
printf "unnamed linked slot: rc=%s path=%s own=%s\n" "$rc" "$TEARDOWN_ROUTE_LOCK_PATH" "$TEARDOWN_ROUTE_LOCK_OWN"
teardown_route_lock_release
TEARDOWN_ROUTE_PROJECT=$ROUTE_PROJ
rc=0; teardown_route_lock_take "$ROUTE_CLONE" copy || rc=$?
printf "slot origin differs: rc=%s own=%s why=%s\n" "$rc" "$TEARDOWN_ROUTE_LOCK_OWN" "$TEARDOWN_CLOSEOUT_ROUTE_WHY"
teardown_route_lock_release
TEARDOWN_ROUTE_PROJECT=
rc=0; teardown_route_lock_take "$ROUTE_CLONE" copy || rc=$?
printf "unnamed standalone clone: rc=%s path=%s\n" "$rc" "$TEARDOWN_ROUTE_LOCK_PATH"
teardown_route_lock_release
' 2>&1)
  lock_proj=$(printf '%s\n' "$out" | sed -n 's/^lock_proj=//p')
  lock_clone=$(printf '%s\n' "$out" | sed -n 's/^lock_clone=//p')
  [ -n "$lock_proj" ] && [ "$lock_proj" != "$lock_clone" ] || fail "the fixture does not discriminate: the project and the other origin share a lock key: $out"
  assert_contains "$out" "project_of linked slot=$(cd "$proj" && pwd -P)" "the project of a linked slot is not its common directory's: $out"
  assert_contains "$out" "project_of clone=$(cd "$clone" && pwd -P)" "the project of a standalone clone is not itself: $out"
  assert_contains "$out" "unnamed linked slot: rc=0 path=$lock_proj own=1" "a linked slot was not keyed by its project: $out"
  assert_contains "$out" "slot origin differs: rc=1 own=0" "a slot whose origin differs from its project's did not refuse: $out"
  assert_contains "$out" "differs" "the refusal does not say the keys differ: $out"
  assert_contains "$out" "unnamed standalone clone: rc=0 path=$lock_clone" "a standalone clone was not keyed by itself: $out"
  route_trip_check "lock project"
  pass "the route derives the project from the slot's git common directory when the caller names none, keys the lock by it through the one owner function, and refuses a slot whose own lock key differs from its project's"
}

# F6 (Main 1887): one generated commit per ancestor copy, each a real ancestor of the landed tip.
route_make_ancestor_commits() {  # <name>...: commits on main in $SLOT; sets ROUTE_ANCESTOR_TIPS (name=sha lines)
  local name
  ROUTE_ANCESTOR_TIPS=
  for name in "$@"; do
    printf '%s\n' "$name" > "$SLOT/$name.txt"
    git -C "$SLOT" add -- "$name.txt"
    git -C "$SLOT" commit -qm "generated ancestor $name"
    ROUTE_ANCESTOR_TIPS="$ROUTE_ANCESTOR_TIPS$name=$(git -C "$SLOT" rev-parse HEAD)"$'\n'
  done
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" fetch -q origin
}
test_each_ancestor_copy_of_the_recorded_table_gets_its_own_generated_tip_that_is_an_ancestor_of_the_landed_tip() {
  local name tip seen landed
  route_world route-ancestor-tips
  route_make_ancestor_commits row-11 row-13 row-14 row-16
  git -C "$SLOT" commit -q --allow-empty -m "the landed tip"
  landed=$(git -C "$SLOT" rev-parse HEAD)
  seen=
  while IFS='=' read -r name tip; do
    [ -n "$name" ] || continue
    case " $seen " in *" $tip "*) fail "$name shares its tip $tip with another ancestor copy" ;; esac
    seen="$seen $tip"
    git -C "$SLOT" merge-base --is-ancestor "$tip" "$landed" || fail "$name's tip is not an ancestor of the landed tip"
    [ "$tip" != "$landed" ] || fail "$name's tip is the landed tip itself"
  done <<< "$ROUTE_ANCESTOR_TIPS"
  [ "$(printf '%s\n' "$ROUTE_ANCESTOR_TIPS" | grep -c .)" = 4 ] || fail "not four ancestor tips: $ROUTE_ANCESTOR_TIPS"
  pass "the four recorded ancestor rows get four distinct generated tips, each a real ancestor of the landed tip"
}


# --- Main 2194 item 10 and Main 2197: the two R4(b) tests the outside review found absent
# (review F7), and the two real-default waits (R2(d), R3(d)) that run only on GitHub CI ---------

# The CI-only gate itself: off GitHub CI it prints one named skip and never a pass; on a runner it is silent.
test_the_ci_only_gate_prints_one_named_skip_off_github_ci_and_lets_the_case_run_on_it() {
  local out rc=0 lines
  out=$(unset GITHUB_ACTIONS; route_ci_only_gate "the probe case") || rc=$?
  [ "$rc" = 1 ] || fail "the CI-only gate let a case run off GitHub CI ($rc): $out"
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" = 1 ] || fail "the CI-only gate printed $lines lines off GitHub CI, not one named skip: $out"
  case "$out" in "skip: the probe case: "*) ;; *) fail "the skip line does not start with 'skip: <case>: ': $out" ;; esac
  assert_not_contains "$out" "ok -" "the skip line reads as a pass: $out"
  rc=0
  out=$(GITHUB_ACTIONS=false route_ci_only_gate "the probe case") || rc=$?
  [ "$rc" = 1 ] || fail "GITHUB_ACTIONS=false let the case run ($rc): $out"
  rc=0
  out=$(GITHUB_ACTIONS=true route_ci_only_gate "the probe case") || rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] || fail "the CI-only gate did not let a case run quietly on GitHub CI ($rc): $out"
  pass "off GitHub CI the gate prints one named skip line and returns 1 (never a pass); with GITHUB_ACTIONS=true it is silent and returns 0"
}

# R4(b), the snapshot of the ignored area (review F7): a plan changes no ignored path of the slot
# clone except the driver's named verification report under .claude/bug-evidence/tree-presence/.
# A sandbox check with a scripted driver that writes that report as the real driver does (the real
# driver's plan-side writes are R6(c)'s trace). The digest has controls that make it fail, and a
# second copy whose scripted driver also writes a file at another ignored path must change it.
test_a_plan_leaves_every_ignored_path_of_the_slot_clone_unchanged_except_the_trees_presence_report() {
  local before before_all tp
  route_world route-ignored
  printf '.claude/bug-evidence/\nignored-area/\n' >> "$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/ignored-area" "$SLOT/.claude/bug-evidence/earlier"
  printf 'kept\n' > "$SLOT/ignored-area/kept.txt"
  printf 'an earlier report\n' > "$SLOT/.claude/bug-evidence/earlier/report.json"
  route_copy twin 7
  route_copy planted 7
  tp=$SLOT/.claude/bug-evidence/tree-presence
  cat > "$W/ans/twin/plan.hook" <<SH
mkdir -p "$tp"
printf 'report for %s\n' "\$1" > "$tp/report.json"
SH
  cat > "$W/ans/planted/plan.hook" <<SH
mkdir -p "$tp"
printf 'report for %s\n' "\$1" > "$tp/report.json"
printf 'a write outside the report directory\n' > "$SLOT/ignored-area/driver-wrote-this.txt"
SH
  route_assert_ignored_digest_sees "$SLOT" route-ignored
  before=$(route_ignored_digest "$SLOT")
  before_all=$(route_ignored_digest "$SLOT" all)
  route_trip_arm
  route_closeout plan twin "$(route_stub_before)"
  [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "route-ignored: the twin's plan did not route ($CO_RC $CO_ROUTE): $CO_OUT"
  [ "$(route_call_count twin)" = 1 ] || fail "route-ignored: the twin was not asked once: $(route_calls_for twin)"
  [ -f "$tp/report.json" ] || fail "route-ignored: the scripted driver did not write its verification report"
  assert_equals "$before" "$(route_ignored_digest "$SLOT")" "route-ignored: the plan changed an ignored path of the slot clone other than the tree-presence report"
  [ "$(route_ignored_digest "$SLOT" all)" != "$before_all" ] || fail "route-ignored: with nothing left out the digest did not see the driver's report, so the leave-out proves nothing"
  before=$(route_ignored_digest "$SLOT")
  route_closeout plan planted "$(route_stub_before)"
  [ "$CO_RC" = 0 ] || fail "route-ignored: the second plan failed ($CO_RC): $CO_OUT"
  [ -f "$SLOT/ignored-area/driver-wrote-this.txt" ] || fail "route-ignored: the planted write did not happen"
  [ "$before" != "$(route_ignored_digest "$SLOT")" ] || fail "route-ignored: the ignored-area check missed a planted write to another ignored path"
  route_trip_check "ignored-area snapshot"
  pass "a plan leaves every ignored path of the slot clone as it was except the driver's tree-presence report (a sandbox check), and the same check fails on a planted write to another ignored path, a new, edited or deleted ignored file"
}

# R4(b), the unlocked path (review F7): a sandbox stand-in for a Firstmate code path that switches a
# slot's primary checkout without the project lock (the K8 inventory's path: remove_firstmate_home's
# teardown_treehouse_return in bin/fm-teardown.sh, Main 1786) acts while the route holds the lock;
# the lock does not stop it, and the route refuses before the driver with an empty argv. The
# refusal is the pre-entry read (second promise).
test_a_firstmate_path_that_takes_no_project_lock_and_switches_the_slot_checkout_is_refused_before_the_driver() {
  local lock
  route_late_world unlocked-path
  route_copy zz-a 7
  # shellcheck disable=SC2016 # the snippet runs in the library bash, which expands its own variable
  lock=$(ROUTE_SLOT=$SLOT route_lib 'fm_treehouse_project_lock_path "$ROUTE_SLOT"')
  [ -n "$lock" ] || fail "no project lock path for the slot"
  cat > "$W/late/mb.hook" <<SH
if [ -e "$lock" ] || [ -L "$lock" ]; then printf 'held\n' > "$W/late/unlocked-actor.state"; else printf 'free\n' > "$W/late/unlocked-actor.state"; fi
git -C "$SLOT" checkout -q fm/pr-7-head
SH
  route_trip_arm
  FAKE_GIT_MERGEBASE_HOOK="$W/late/mb.hook" route_closeout plan zz-a "$(route_stub_before)"
  [ "$CO_RC" != 0 ] || fail "a switch by a path that takes no project lock still reached the driver"
  assert_equals 1 "$CO_SWITCHED" "the switch by the unlocked path was not reported as a switch"
  assert_contains "$CO_OUT" "just before the driver was entered" "the refusal does not name the pre-entry read"
  [ "$(route_call_count zz-a)" = 0 ] || fail "the driver was called after the unlocked path switched the checkout: $(route_calls_for zz-a)"
  assert_equals held "$(cat "$W/late/unlocked-actor.state" 2>/dev/null)" "the route did not hold the project lock when the actor switched, so the actor was not the unlocked path this case stands for"
  git -C "$SLOT" checkout -q main
  FAKE_GIT_MERGEBASE_HOOK='' route_closeout plan zz-a "$(route_stub_before)"
  [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] && [ "$CO_SWITCHED" != 1 ] || fail "the control with no actor did not route ($CO_RC $CO_ROUTE $CO_SWITCHED): $CO_OUT"
  [ "$(route_call_count zz-a)" = 1 ] || fail "the control was not asked once: $(route_calls_for zz-a)"
  route_trip_check "unlocked path"
  pass "a path that takes no project lock cannot be stopped by the lock, but its switch of the slot checkout to the PR's head is refused before the driver with an empty argv log, and the same copy routes with no actor"
}

# R4(c), the retained ignored payload (review of c43fce54, finding 1): a route EXECUTE whose
# scripted answer shows a retained ignored payload (the cleanup_ignored_payload_archived_tree_retained
# refusal in the stdout envelope and again on stderr, with the disposition key) keeps the copy and
# every unique ignored file byte for byte. The unique files are planted in the copy and hashed before
# and after the route, two ways (route_ignored_digest and the planted files read directly). The
# controls: (1) the digest can fail: an edited, a deleted and an added ignored file each change it;
# (2) a scripted driver that retains the tree but rewrites a unique file fails the same decision rule;
# (3) the release path: an eligible copy with no ignored payload and the success envelope is removed
# by the same route code, so the keep above is the driver's answer and not the route's inability to
# release. A sandbox check: the driver is a scripted stand-in and the forge and landing read are
# stubbed (Main 1850, 2197); the sweep's receipt and release-slot rules for a retained copy are the
# sweep's own and are the whole-route cases', owed to the pipeline and CI. On the base the route
# does not exist, so the base's plain call never routes and the case is red there for the route's absence.
test_a_route_execute_that_retains_the_tree_keeps_every_unique_ignored_file_byte_for_byte_and_a_payload_free_copy_is_released() {
  local c m ctl admin lock_before before sums line
  route_world route-retained-bytes
  printf 'unique.dat\nunique-dir/\nunique-link\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  route_copy zz-payload 7 allowed retained-both
  route_copy zz-mutant 7 allowed retained-both
  route_copy aa-control 7
  c=$(copy_path zz-payload)
  m=$(copy_path zz-mutant)
  ctl=$(copy_path aa-control)
  route_plant_unique_ignored "$c"
  route_plant_unique_ignored "$m"
  [ "$(git -C "$c" status --porcelain --untracked-files=all | wc -l | tr -d ' ')" = 0 ] || fail "route-retained: the planted files are not ignored, so the copy is not clean: $(git -C "$c" status --porcelain --untracked-files=all)"
  before=$(route_ignored_digest "$c")
  sums=$(route_unique_sums "$c")
  [ "$(printf '%s\n' "$sums" | grep -c 'unique')" -ge 7 ] || fail "route-retained: the planted files are not all there to be compared: $sums"
  # Control 1: the comparison can fail.
  printf 'x\n' >> "$c/unique.dat"
  route_retained_bytes_ok "$c" "$before" "$sums" && fail "route-retained: the byte check missed an edit of a unique ignored file"
  printf 'unique retained bytes\n' > "$c/unique.dat"
  mv "$c/unique-dir/nested/rows.bin" "$c/unique-dir/nested/rows.bin.away"
  route_retained_bytes_ok "$c" "$before" "$sums" && fail "route-retained: the byte check missed the deletion of a unique ignored file"
  mv "$c/unique-dir/nested/rows.bin.away" "$c/unique-dir/nested/rows.bin"
  printf 'added\n' > "$c/unique-dir/added.txt"
  route_retained_bytes_ok "$c" "$before" "$sums" && fail "route-retained: the byte check missed an added unique ignored file"
  rm -f "$c/unique-dir/added.txt"
  route_retained_bytes_ok "$c" "$before" "$sums" || fail "route-retained: the copy was not put back after the byte-check controls"
  admin=$(git -C "$c" rev-parse --absolute-git-dir)
  [ -f "$admin/locked" ] || fail "route-retained: the payload copy is not locked as a Vernant copy is"
  lock_before=$(shasum -a 256 "$admin/locked" | awk '{print $1}')
  # The route execute on the payload copy.
  route_trip_arm
  route_closeout execute zz-payload "$(route_stub_before)"
  [ "$CO_ROUTE" = pr ] || fail "route-retained: the copy with a record did not take the --pr route ($CO_ROUTE): $CO_OUT"
  assert_equals 3 "$CO_RC" "route-retained: a retained-payload answer must keep the copy as the driver's exit 3 (the route said: $CO_OUT)"
  assert_contains "$CO_OUT" "cleanup_ignored_payload_archived_tree_retained" "route-retained: the retained signal is not in the route's output"
  assert_contains "$CO_OUT" "ignored_payload_disposition=archive_then_retain_tree" "route-retained: the stderr signal is not in the route's output"
  assert_equals 1 "$(route_call_count zz-payload)" "route-retained: the driver was not asked exactly once (the execute): $(route_calls_for zz-payload)"
  line=$(route_calls_for zz-payload | sed -n 1p)
  # shellcheck disable=SC2086 # the argv words hold no spaces
  route_argv_check execute 7 "$W/profiles/zz-payload.json" "$c" $line || fail "route-retained: the execute's argv is wrong: $ROUTE_ARGV_WHY ($line)"
  if [ ! -e "$c" ] || ! registered zz-payload; then fail "route-retained: the copy with a retained ignored payload was removed or unregistered"; fi
  assert_equals "$lock_before" "$(shasum -a 256 "$admin/locked" | awk '{print $1}')" "route-retained: the copy's creation lock changed"
  route_retained_bytes_ok "$c" "$before" "$sums" || fail "route-retained: a unique ignored file of the kept copy changed, went missing or was added: $(route_unique_sums "$c")"
  assert_equals 'unique retained bytes' "$(cat "$c/unique.dat")" "route-retained: the text file's bytes changed"
  # Control 2: a driver that retains the tree but rewrites a unique file fails the same rule.
  cat > "$W/ans/zz-mutant/exec.hook" <<SH
printf 'rewritten by the driver\n' > "$m/unique.dat"
SH
  route_trip_arm
  route_closeout execute zz-mutant "$(route_stub_before)"
  assert_equals 3 "$CO_RC" "route-retained: the rewriting driver's retained answer must still keep the copy ($CO_OUT)"
  [ -e "$m" ] || fail "route-retained: the rewriting driver's copy was removed"
  route_retained_bytes_ok "$m" "$before" "$sums" && fail "route-retained: the byte check passed a copy whose unique file the driver rewrote"
  # Control 3: the release path. The same route code removes a copy with no ignored payload.
  route_trip_arm
  route_closeout execute aa-control "$(route_stub_before)"
  [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "route-retained: the control copy with no payload was not released ($CO_RC $CO_ROUTE): $CO_OUT"
  [ ! -e "$ctl" ] || fail "route-retained: the control copy with no ignored payload is still there after the success envelope"
  ! registered aa-control || fail "route-retained: the control copy is still registered after its release"
  assert_equals 1 "$(route_call_count aa-control)" "route-retained: the control was not asked exactly once: $(route_calls_for aa-control)"
  route_trip_check "retained payload bytes"
  printf 'retained: copy kept; unique.dat, unique-dir/nested/rows.bin, unique-dir/empty.txt and unique-link unchanged (digest and direct sums equal); controls: an edit, a deletion and an added file each fail the check, a rewriting driver fails it, the payload-free copy is removed\n'
  pass "a route execute whose answer shows a retained ignored payload keeps the copy and every unique ignored file byte for byte (digest and direct hashes), the byte check fails on an edited, deleted, added or driver-rewritten file, and the same route removes a copy with no ignored payload"
}

# R2(d): the real 60 s forge-read default, through the real forge-read path and the real
# bounder, on GitHub CI only (Main 2197). A hung read with FM_TEARDOWN_FORGE_TIMEOUT unset ends at
# the 60 s default, the copy is kept with no driver call, and a timely control routes.
test_the_real_60_second_forge_default_keeps_a_copy_whose_read_hangs_and_a_timely_control_routes_on_github_ci() {
  local t0 t1
  route_ci_only_gate "R2(d) the real 60 s forge-read default" || return 0
  route_world route-forge-default
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_set_pr "$W/forge" 8 HANG
  route_copy ok 7
  route_copy hang 8
  unset FM_TEARDOWN_FORGE_TIMEOUT
  t0=$(date +%s)
  ROUTE_HANG_LIFE=130 route_closeout plan hang
  t1=$(date +%s)
  [ "$CO_RC" != 0 ] || fail "a forge read that hangs was treated as merged: $CO_OUT"
  assert_contains "$CO_OUT" "timed out after 60s" "the hung read did not end at the 60 s default: $CO_OUT"
  [ "$(route_call_count hang)" = 0 ] || fail "the copy with a hung forge read reached the driver: $(route_calls_for hang)"
  [ $((t1 - t0)) -ge 58 ] && [ $((t1 - t0)) -le 100 ] || fail "the hung read ended after $((t1 - t0)) s, not at the 60 s default"
  t0=$(date +%s)
  route_closeout plan ok
  t1=$(date +%s)
  [ "$CO_RC" = 0 ] && [ "$CO_ROUTE" = pr ] || fail "the timely control did not route ($CO_RC $CO_ROUTE): $CO_OUT"
  [ "$(route_call_count ok)" = 1 ] || fail "the timely control was not asked once: $(route_calls_for ok)"
  [ $((t1 - t0)) -le 30 ] || fail "the timely control took $((t1 - t0)) s"
  pass "with FM_TEARDOWN_FORGE_TIMEOUT unset a hung forge read ends at 60 s through the real bounder, the copy is kept with no driver call, and a timely read routes"
}

# R3(d): the real 120 s plan default, through the real sweep plan and its process-group kill,
# on GitHub CI only (Main 2197). With FM_COPY_SWEEP_PLAN_TIMEOUT unset, a plan that hangs is
# still alive at 100 s, ends at the 120 s default, the copy is kept and no driver process is left.
test_the_real_120_second_plan_default_holds_a_hung_plan_at_its_boundary_on_github_ci() {
  local sweep waited=0 t0 t1
  route_ci_only_gate "R3(d) the real 120 s plan default" || return 0
  make_locked_copy_case plan120 dead
  install_driver "$SLOT" "$W"
  printf '200\n' > "$W/plan-hang"
  (
    unset FM_COPY_SWEEP_PLAN_TIMEOUT
    rc=0
    ( FM_TEARDOWN_VERNANT_PYTHON="$DRIVER_PY" sweep_cmd --apply ) > "$W/real120.out" 2>&1 || rc=$?
    printf '%s' "$rc" > "$W/real120.rc"
  ) &
  sweep=$!
  while [ "$(driver_pid_count)" != 2 ] && [ "$waited" -lt 200 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(driver_pid_count)" = 2 ] || { kill "$sweep" 2>/dev/null; fail "the hung plan never started"; }
  t0=$(date +%s)
  sleep 100
  [ "$(driver_pid_count)" = 2 ] || fail "the hung plan was stopped before 100 s, before the 120 s default"
  wait "$sweep" || true
  t1=$(date +%s)
  OUT=$(cat "$W/real120.out")
  RC=$(cat "$W/real120.rc")
  [ "$RC" = 0 ] || fail "the run failed ($RC): $OUT"
  [ $((t1 - t0)) -ge 112 ] && [ $((t1 - t0)) -le 150 ] || fail "the hung plan ended $((t1 - t0)) s after it started, not at the 120 s default"
  assert_class locked HELD-LOCKED
  assert_contains "$OUT" "did not answer within 120s" "the hung plan did not end at the 120 s default: $OUT"
  assert_driver_pids_gone "a hung plan under the 120 s default"
  [ -e "$(copy_path locked)" ] || fail "the copy was removed although its plan hung"
  pass "with FM_COPY_SWEEP_PLAN_TIMEOUT unset a hung plan is alive at 100 s, ends at the 120 s default, keeps the copy and leaves no driver process"
}

# FM_TEST_ONLY=<function> runs one case, which keeps a mutation proof quick.
fm_test_only

test_report_lists_every_copy_and_changes_nothing
test_live_nested_copies_are_named_once_with_age_and_left_untouched
test_a_lock_probe_cut_by_the_time_bound_reads_unknown_never_directory
test_a_registered_copy_whose_directory_is_gone_is_not_named_live
test_the_wake_names_the_oldest_five_live_copies_and_points_at_the_report
test_a_new_youngest_copy_is_named_first_and_the_wake_stays_bounded
test_closed_task_and_secondmate_home_do_not_raise_live_nested_fact
test_unreadable_registration_is_reported_without_walking_for_copies
test_apply_removes_only_the_reapable_copy
test_recycled_launcher_lock_is_held
test_dead_launcher_dirty_copy_is_held
test_dead_launcher_process_inside_copy_is_held
test_dead_launcher_lock_is_released_by_the_driver
test_plan_stderr_warning_does_not_block_allowed_stdout
test_execute_stderr_warning_keeps_temporary_refusal_retryable
test_failed_nested_registration_proof_holds_copy
test_failed_post_removal_registration_keeps_receipt_unproved
test_locked_release_cap_defers_copies_until_the_next_run
test_refusals_use_no_release_slot_and_cannot_starve_later_copies
test_failed_post_execute_enumeration_uses_release_slot
test_partial_releases_use_release_slots
test_uuid_owner_lock_is_released_by_the_driver
test_ppid_owner_lock_is_released_by_the_driver
test_retained_ignored_payload_is_kept_once_without_growth
test_task_record_appearing_during_plan_prevents_release
test_valid_lock_replacement_during_plan_prevents_release
test_extra_lock_lines_are_held_byte_identical
test_binary_creation_lock_is_held_byte_identical
test_failed_driver_removal_cannot_be_retried_as_unlocked
test_a_stale_retention_receipt_does_not_hold_a_new_copy_at_the_same_path
test_report_does_not_claim_unplanned_locks_are_reapable
test_driver_verdict_types_and_exit_status_are_not_permission
test_a_refused_plan_holds_the_copy_copies_nothing_and_exits_zero
test_a_plan_that_reports_the_retain_rule_holds_the_copy_and_copies_nothing
test_a_failure_after_an_allowed_plan_leaves_the_copy_and_records_the_drivers_refusal
test_a_temporary_execute_refusal_is_planned_and_released_by_the_next_run
test_content_that_keeps_changing_waits_and_the_first_quiet_run_preserves_once_and_releases
test_ignored_content_changed_after_the_last_proof_is_not_released
test_a_new_ignored_file_after_preservation_waits_then_releases_once
test_a_fifo_and_a_stale_socket_neither_block_release_nor_accumulate_preserves
test_a_receipt_that_cannot_be_written_keeps_no_preserve_and_retries
test_a_long_sorted_key_refusal_still_shows_the_drivers_reason
test_a_teardown_retained_record_protects_the_copy_and_is_cleared_with_it
test_a_teardown_retained_record_keeps_holding_a_changed_copy_until_its_lock_or_copy_changes
test_a_sweep_from_another_home_does_not_ask_the_driver_for_a_copy_a_lane_record_holds
test_a_sweep_holds_a_copy_when_another_homes_records_cannot_be_read
test_a_receipt_survives_while_its_copy_cannot_be_looked_up_and_is_cleared_only_when_it_is_gone
test_a_failed_preservation_is_the_sweeps_own_human_only_refusal
test_a_failed_preservation_leaves_no_staging_directory
test_a_lock_that_stops_being_vernants_after_the_plan_is_not_released
test_ownership_or_lock_change_during_preservation_prevents_release
test_unproved_plan_verdicts_hold_the_copy
test_a_bare_allowed_literal_plan_does_not_release_the_copy
test_a_zero_padded_plan_timeout_is_read_as_decimal
test_a_sweep_stopped_during_a_plan_stops_the_hung_driver
test_two_sweeps_of_one_path_keep_both_preserved_directories
test_a_removal_with_no_measured_size_says_so
test_locked_copy_with_an_unpushed_equivalence_is_still_held
test_live_foreign_or_unreleasable_locks_are_kept
test_copy_with_one_untracked_file_and_unpushed_tip_are_kept
test_landed_content_without_a_pushed_tip_is_reaped_by_apply
test_lane_home_project_clone_is_swept
test_failing_remove_leaves_the_copy_and_is_never_forced
test_nothing_is_forced_deleted_cleaned_or_returned
test_load_guard_skips_only_the_sizing_and_says_so
test_six_skipped_runs_in_a_row_wake_once
test_one_du_at_a_time_under_nice
test_sizes_are_cached_by_path_and_mtime
test_nested_copy_bytes_are_not_counted_twice
test_budget_wake_names_budget_total_and_five_largest_and_fires_once
test_pool_budget_and_two_budgets_share_one_wake
test_apply_raises_the_wake_through_the_queue_once
test_a_cut_scan_wakes_on_what_it_measured_and_never_invents_one
test_a_registered_copy_whose_directory_is_gone_does_not_latch_the_record
test_a_slow_classification_cannot_starve_the_wake
test_a_lane_home_is_judged_as_that_home_would_judge_it
test_an_outer_copy_holding_a_dirty_inner_copy_is_kept
test_an_outer_copy_is_reaped_after_its_inner_copy_is_gone
test_a_zero_padded_or_odd_check_timeout_is_normalized
test_ignored_files_that_exist_nowhere_else_hold_a_copy
test_graft_output_alone_holds_no_copy
test_a_slow_enumeration_still_prints_the_wake_for_the_clones_it_reached
test_a_slow_home_project_enumeration_is_cut_at_the_time_bound
test_a_cut_check_keeps_the_standing_budgets_it_did_not_reach
test_a_check_cut_and_skipped_on_every_poll_still_reaches_the_wake
test_a_cut_check_keeps_a_pool_budget_it_reached_only_in_part
test_a_cut_check_keeps_the_fresh_cached_sizes_it_did_not_reach
test_check_classifies_only_the_copies_it_names
test_check_respects_its_interval
test_check_never_removes
test_bad_config_is_refused
test_real_lsof_sees_a_process_inside_a_copy
test_arm_and_disarm_bind_the_check
test_help_and_bad_calls
test_the_route_comparator_accepts_both_orders_and_rejects_every_wrong_call
test_a_record_makes_the_sweep_ask_the_driver_by_its_pr_route_and_no_record_changes_nothing
test_a_record_that_fails_any_condition_keeps_the_copy_and_never_reaches_the_driver
test_a_matching_record_row_that_is_empty_or_conflicts_holds_the_copy_in_either_row_order
test_a_plan_that_times_out_or_is_stopped_leaves_no_forge_read_running
test_a_plan_never_asks_the_driver_while_the_slots_checkout_is_on_the_prs_head_branch
test_a_linked_worktree_slot_on_the_prs_head_branch_is_a_plain_hold_and_the_run_goes_on
test_the_routes_answers_are_read_in_their_real_shape_and_fail_closed
test_a_malformed_or_contradictory_temporary_refusal_keeps_the_retention_receipt
test_a_retained_payload_signal_on_stderr_beats_the_temporary_retry
test_a_forge_read_that_times_out_leaves_no_descendant_running
test_a_records_file_that_cannot_be_read_holds_every_locked_copy_before_the_driver
test_a_row_for_another_tip_holds_the_copy_before_or_after_its_valid_row
test_a_record_that_changes_while_the_forge_is_read_holds_the_copy
test_a_decimal_pr_number_of_any_length_routes_and_a_zero_or_a_leading_zero_does_not
test_a_local_origin_head_never_decides_the_landing_branch_and_the_remotes_default_does
test_a_forge_read_whose_parent_exits_at_once_leaves_no_descendant_and_does_not_wait_for_one
test_a_route_execute_that_claims_success_and_leaves_the_copy_uses_a_release_slot
test_the_hold_matrix_checks_fail_without_a_receipt_and_after_any_driver_call
test_a_valid_record_releases_no_copy_that_the_sweep_holds_before_the_driver
test_the_recorded_cases_are_decided_by_their_records_and_the_drivers_scripted_answers
test_the_content_proof_proves_a_twin_a_squash_and_an_ancestor_and_keeps_what_the_merge_commit_lacks
test_the_content_proof_compares_whole_lines_and_keeps_an_order_or_prefix_that_changes_the_meaning
test_the_content_proof_judges_mode_and_text_together_and_needs_identical_entries_for_removals_and_binaries
test_the_content_proof_keeps_an_empty_change_that_is_not_an_ancestor_and_histories_without_one_merge_base
test_the_content_proof_writes_nothing_to_the_clone_and_runs_no_merge
test_a_lying_merge_driver_in_any_channel_cannot_make_a_copy_count_as_landed
test_a_lying_merge_driver_keeps_the_copy_before_the_driver_through_the_whole_route
test_the_landing_branch_is_the_remotes_own_default_and_a_stale_origin_head_or_an_unreachable_remote_keeps_the_copy
test_a_recorded_base_must_agree_with_the_remotes_default_and_its_own_origin_ref_decides_landing
test_the_routes_answer_must_be_the_stated_fifteen_key_envelope_for_the_plan_and_the_execute
test_the_route_takes_and_releases_its_own_project_lock_when_its_caller_holds_none
test_the_route_borrows_a_hold_its_caller_proves_and_leaves_it_held
test_a_claimed_hold_the_pid_file_does_not_prove_and_a_busy_lock_keep_the_copy_before_the_driver
test_the_lock_is_released_after_a_refusal_and_a_disabled_reflog_keeps_the_copy
test_the_read_made_just_before_the_driver_is_entered_refuses_a_checkout_on_the_prs_head_with_no_driver_call
test_the_stable_control_of_the_pre_entry_read_routes_with_one_driver_call
test_a_switch_and_restore_after_the_first_read_is_found_before_or_after_the_driver_call
test_a_quiet_call_with_no_actor_routes_and_reports_no_switch
test_a_switch_between_the_pre_entry_read_and_the_drivers_start_is_detected_at_a_plan_and_stops_the_run
test_a_late_entry_switch_at_an_execute_is_detected_and_a_pending_copy_gets_no_driver_call
test_the_late_entry_stable_control_releases_both_copies_with_a_before_b
test_a_detected_switch_stops_the_run_even_when_the_first_executes_answer_is_a_refusal
test_an_ordinary_refusal_without_a_switch_keeps_the_copy_and_the_run_goes_on_to_the_next_copy
test_a_switch_and_restore_between_the_plan_and_the_execute_is_found_from_the_plans_first_read
test_a_copy_with_no_record_is_asked_exactly_as_before_at_every_no_record_call
test_a_configured_merge_driver_of_any_name_runs_nothing_and_the_twin_routes_while_the_policy_copy_is_kept
test_an_allowing_driver_is_never_asked_for_a_copy_whose_lines_the_merge_commit_lacks
test_the_checkout_check_reads_the_reflog_once_and_stops_on_a_read_error_an_interleaved_entry_or_a_missing_anchor
test_a_reflog_read_error_a_masked_interleaving_or_a_rewritten_anchor_sets_the_stop_flag
test_a_refusal_is_temporary_only_when_it_is_the_called_prs_complete_envelope
test_the_forge_timeout_override_is_honoured_or_refused_and_never_silently_sixty
test_the_r5_table_prints_one_named_skip_and_no_pass_when_the_staged_cases_variable_is_unset
test_the_r5_table_fails_when_the_staged_cases_variable_names_a_directory_or_table_that_cannot_be_read
test_the_content_proof_refuses_git_output_it_cannot_parse_and_accepts_a_genuine_empty_change
test_the_route_publishes_its_checkout_window_while_proving_and_reports_a_switch_when_a_proof_refuses
test_a_plan_killed_while_proving_is_read_for_a_checkout_change_by_the_parent
test_a_plan_killed_before_its_window_opened_is_not_read_against_the_previous_copys_window
test_a_claimed_outer_hold_at_another_path_refuses_and_never_falls_through_to_the_computed_lock
test_the_parent_releases_a_killed_plans_lock_only_when_its_owner_is_gone_and_the_record_names_it
test_the_route_keys_its_lock_by_the_slots_registered_project_and_refuses_a_slot_whose_origin_differs
test_each_ancestor_copy_of_the_recorded_table_gets_its_own_generated_tip_that_is_an_ancestor_of_the_landed_tip
test_the_ci_only_gate_prints_one_named_skip_off_github_ci_and_lets_the_case_run_on_it
test_a_plan_leaves_every_ignored_path_of_the_slot_clone_unchanged_except_the_trees_presence_report
test_a_firstmate_path_that_takes_no_project_lock_and_switches_the_slot_checkout_is_refused_before_the_driver
test_a_route_execute_that_retains_the_tree_keeps_every_unique_ignored_file_byte_for_byte_and_a_payload_free_copy_is_released
test_the_real_60_second_forge_default_keeps_a_copy_whose_read_hangs_and_a_timely_control_routes_on_github_ci
test_the_real_120_second_plan_default_holds_a_hung_plan_at_its_boundary_on_github_ci
pass "fm-copy-sweep"
