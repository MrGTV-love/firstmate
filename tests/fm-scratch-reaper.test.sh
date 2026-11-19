#!/usr/bin/env bash
# Behavior of bin/fm-scratch-reaper.sh in private temp worlds with real processes.
# Every run goes through sr_run (tests/scratch-reaper-helpers.sh), which refuses any run whose
# root, config or archive folder is not inside the test world: the reaper deletes directories
# and defaults to the real /private/tmp, so no test calls the script directly.
# The watcher integration lives in tests/fm-watch-scratch-reaper.test.sh.
# shellcheck disable=SC2012,SC2015,SC2016,SC1090  # fixtures chain on purpose; mutant targets are literal source text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/scratch-reaper-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/scratch-reaper-helpers.sh"

command -v lsof >/dev/null 2>&1 || { echo 'ok - skipped: lsof is not installed on this host'; exit 0; }

REAPER="$ROOT/bin/fm-scratch-reaper.sh"
HELPERS="$ROOT/tests/scratch-reaper-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-scratch-reaper-tests)
CASE_N=0
SR_SCRIPT=$REAPER
SLEEPERS=()

new_world() {  # sets SR_WORLD
  CASE_N=$((CASE_N + 1))
  # A mutant runs its case in a subshell that starts from the same counter, so skip a world already taken.
  while [ -e "$TMP_ROOT/w$CASE_N" ]; do CASE_N=$((CASE_N + 1)); done
  SR_WORLD=$(sr_world_new "$TMP_ROOT" "w$CASE_N") || fail 'cannot build a test world'
  printf '%s fm-*\n' "$SR_WORLD/root" > "$SR_WORLD/fm/config/scratch-reaper"
}

reap() {  # <world> <args...>: stdout and status of one guarded run
  local world=$1
  shift
  # shellcheck disable=SC2086  # SR_REAP_FLAGS holds whole option words
  sr_run "$world" --script "$SR_SCRIPT" --fakebin ${SR_REAP_FLAGS:-} -- "$@"
}

state_log() { printf '%s/fm/state/scratch-reaper.log' "$1"; }
archive_dirs() { ls -d "$1"/fm/data/scratch-reaper-archive/*/"$2" 2>/dev/null | head -n 1; }

make_aged() {  # <dir> [file...]: a directory with the files, all old
  local d=$1 f
  shift
  mkdir -p "$d" || return 1
  for f in "$@"; do
    mkdir -p -- "$d/$(dirname -- "$f")" && printf 'content of %s\n' "$f" > "$d/$f" || return 1
  done
  sr_age_tree "$d"
}

start_sleeper() {  # <cwd> [fd-file]: a live sleep process with its cwd (and a file) in place
  local cwd=$1 file=${2:-} pid n=0 ready
  CASE_N=$((CASE_N + 1))
  while [ -e "$TMP_ROOT/ready.$CASE_N" ]; do CASE_N=$((CASE_N + 1)); done
  ready="$TMP_ROOT/ready.$CASE_N"
  # The marker is written after the cwd and the file are held and before exec, which keeps both.
  if [ -n "$file" ]; then
    ( cd "$cwd" && exec 3< "$file" && : > "$ready" && exec sleep 600 ) &
  else
    ( cd "$cwd" && : > "$ready" && exec sleep 600 ) &
  fi
  pid=$!
  SLEEPERS+=("$pid")
  while [ ! -e "$ready" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  [ -e "$ready" ] || fail 'the sleeper never started'
  sleep 0.3
}

stop_sleepers() {
  local pid
  for pid in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  SLEEPERS=()
}

# --- the cases (each takes SR_SCRIPT, so the mutant run reuses it) -----------------

case_aged_removed_and_archived() {
  local world out rc root d day f orig_a orig_b
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-aged" a.log sub/b.txt sub/deep/c.json data.bin || fail 'fixture'
  orig_a=$(sr_sha "$root/fm-aged/a.log"); orig_b=$(sr_sha "$root/fm-aged/sub/b.txt")
  out=$(reap "$world" --apply) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "an aged unused directory must reap cleanly, got $rc: $out"
  [ ! -e "$root/fm-aged" ] || fail 'the aged directory was not removed'
  assert_contains "$out" "removed $root/fm-aged bytes=" 'the removal is not printed'
  assert_contains "$(cat "$(state_log "$world")")" "removed $root/fm-aged bytes=" 'the removal is not in state/scratch-reaper.log'
  d=$(archive_dirs "$world" fm-aged)
  [ -n "$d" ] || fail 'no archive folder for the removed directory'
  day=$(basename "$(dirname "$d")")
  case "$day" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) fail "archive date folder is not a UTC date: $day" ;; esac
  for f in a.log sub/b.txt sub/deep/c.json; do
    [ -f "$d/$f" ] || fail "small log $f was not archived with its relative path"
  done
  [ "$(sr_sha "$d/a.log")" = "$orig_a" ] && [ "$(sr_sha "$d/sub/b.txt")" = "$orig_b" ] \
    || fail 'archived bytes differ from the original (sha256)'
  [ ! -e "$d/data.bin" ] || fail 'a non-log file was archived'
}

case_young_kept() {
  local world out root
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-young" a.log || fail 'fixture'
  printf 'new\n' > "$root/fm-young/fresh.txt"
  # An old directory with ONE new file deep inside is young: the whole tree decides, not the folder.
  make_aged "$root/fm-mixed" sub/deep/old.log || fail 'fixture'
  printf 'new\n' > "$root/fm-mixed/sub/deep/new.log"
  touch -t 202501010000 "$root/fm-mixed/sub/deep" "$root/fm-mixed/sub" "$root/fm-mixed"
  out=$(reap "$world" --apply) || fail "run failed: $out"
  [ -d "$root/fm-young" ] && [ -d "$root/fm-mixed" ] || fail 'a young directory was removed'
  assert_contains "$out" "kept $root/fm-young reason=young" 'young directory not logged as young'
  assert_contains "$out" "kept $root/fm-mixed reason=young" 'a directory with one new file deep inside must be young'
}

case_open_handle_kept() {
  local world out root
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-cwd" a.log || fail 'fixture'
  make_aged "$root/fm-file" held.txt || fail 'fixture'
  make_aged "$root/fm-free" a.log || fail 'fixture'
  start_sleeper "$root/fm-cwd"
  start_sleeper "$world" "$root/fm-file/held.txt"
  out=$(reap "$world" --apply) || { stop_sleepers; fail "run failed: $out"; }
  stop_sleepers
  [ -d "$root/fm-cwd" ] || fail 'a directory holding a process cwd was removed'
  [ -d "$root/fm-file" ] || fail 'a directory holding an open file was removed'
  assert_contains "$out" "kept $root/fm-cwd reason=open handle" 'cwd holder not kept for an open handle'
  assert_contains "$out" "kept $root/fm-file reason=open handle" 'open-file holder not kept for an open handle'
  [ ! -e "$root/fm-free" ] || fail 'the unused aged directory beside them must still be removed'
}

case_git_kept() {
  local world out root r
  new_world; world=$SR_WORLD; root=$world/root
  git init -q "$world/main" && git -C "$world/main" -c user.name=t -c user.email=t@example.test commit -q --allow-empty -m init \
    || fail 'main repo fixture'
  git -C "$world/main" worktree add -q "$root/fm-wt" -b wt || fail 'worktree fixture'
  git init -q "$root/fm-repo" || fail 'repo fixture'
  mkdir -p "$root/fm-nest/deep" && git init -q "$root/fm-nest/deep/inner" || fail 'nested repo fixture'
  mkdir -p "$root/fm-slot" && : > "$root/fm-slot/.fm-slot-owner" || fail 'slot fixture'
  make_aged "$root/fm-plain" a.log || fail 'fixture'
  for r in fm-wt fm-repo fm-nest fm-slot; do sr_age_tree "$root/$r"; done
  out=$(reap "$world" --apply) || fail "run failed: $out"
  for r in fm-wt fm-repo fm-nest fm-slot; do
    [ -d "$root/$r" ] || fail "$r (git or pool directory) was removed"
    assert_contains "$out" "kept $root/$r reason=git" "$r not kept for git"
  done
  git -C "$world/main" worktree list | grep -q "$root/fm-wt" || fail 'the worktree registration was damaged'
  [ ! -e "$root/fm-plain" ] || fail 'the plain aged directory must still be removed'
}

case_symlink_not_followed() {
  local world out root before after rc
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$world/outside/target" keep.log sub/other.txt || fail 'fixture'
  before=$(find "$world/outside" -type f -exec cksum {} + | sort)
  ln -s "$world/outside/target" "$root/fm-link" || fail 'symlink fixture'
  make_aged "$root/fm-inner" a.log || fail 'fixture'
  ln -s "$world/outside/target" "$root/fm-inner/escape" || fail 'inner symlink fixture'
  sr_age_tree "$root/fm-inner"
  out=$(reap "$world" --apply) || fail "run failed: $out"
  [ -L "$root/fm-link" ] || fail 'the symlink child was removed or replaced'
  assert_contains "$out" "kept $root/fm-link reason=symlink" 'the symlink child is not reported'
  [ ! -e "$root/fm-inner" ] || fail 'a real aged directory holding an escaping symlink must be removed'
  after=$(find "$world/outside" -type f -exec cksum {} + | sort)
  [ "$before" = "$after" ] || fail 'the symlink target outside the root was touched'
  # A symlinked root is refused, not followed.
  ln -s "$root" "$world/rootlink" || fail 'root symlink fixture'
  printf '%s fm-*\n' "$world/rootlink" > "$world/fm/config/scratch-reaper"
  make_aged "$root/fm-after" a.log || fail 'fixture'
  out=$(SR_REAP_FLAGS=--inworld-symlink-root reap "$world" --apply 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 2 ] || fail "a symlinked root must be refused with exit 2, got $rc: $out"
  [ -d "$root/fm-after" ] || fail 'a refused symlinked root still removed a directory'
}

case_outside_root_untouched() {
  local world out root
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$world/elsewhere/fm-out" a.log || fail 'fixture'
  make_aged "$world/root2/fm-sibling" a.log || fail 'fixture'
  make_aged "$root/nomatch-old" a.log || fail 'fixture'
  make_aged "$root/fm-in" a.log || fail 'fixture'
  out=$(reap "$world" --apply) || fail "run failed: $out"
  [ -d "$world/elsewhere/fm-out" ] && [ -d "$world/root2/fm-sibling" ] || fail 'a directory outside every allow-listed root was removed'
  [ -d "$root/nomatch-old" ] || fail 'a directory in the root whose name matches no glob was removed'
  [ ! -e "$root/fm-in" ] || fail 'the matching directory must be removed'
  case "$out" in *elsewhere*|*root2*|*nomatch-old*) fail "decisions named a path the allow-list never listed: $out" ;; esac
}

case_dry_run_changes_nothing() {
  local world out before after
  new_world; world=$SR_WORLD
  make_aged "$world/root/fm-aged" a.log sub/b.txt || fail 'fixture'
  make_aged "$world/root/fm-young2" a.log || fail 'fixture'
  printf 'n\n' > "$world/root/fm-young2/new.txt"
  before=$({ find "$world" -print; find "$world" -type f -exec cksum {} +; } | sort)
  out=$(reap "$world") || fail "dry run failed: $out"
  after=$({ find "$world" -print; find "$world" -type f -exec cksum {} +; } | sort)
  [ "$before" = "$after" ] || fail 'a dry run changed the test world'
  assert_contains "$out" "would-remove $world/root/fm-aged" 'the dry run does not say what apply would remove'
  [ ! -e "$(state_log "$world")" ] || fail 'a dry run wrote the log'
  [ -z "$(archive_dirs "$world" fm-aged)" ] || fail 'a dry run wrote an archive'
}

case_lsof_failure_keeps_everything() {
  local world out root rc
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-aged" a.log || fail 'fixture'
  printf '#!/bin/sh\nexit 1\n' > "$world/fakebin/lsof"; chmod +x "$world/fakebin/lsof"
  out=$(reap "$world" --apply) && rc=0 || rc=$?
  [ "$rc" -eq 3 ] || fail "a failing lsof must exit 3, got $rc: $out"
  [ -d "$root/fm-aged" ] || fail 'a directory was removed while lsof failed'
  assert_contains "$out" "kept $root/fm-aged reason=lsof failed" 'lsof failure not named'
  # An lsof that exits 0 with no output is an empty snapshot, which is a failure too.
  printf '#!/bin/sh\nexit 0\n' > "$world/fakebin/lsof"
  out=$(reap "$world" --apply) && rc=0 || rc=$?
  [ "$rc" -eq 3 ] && [ -d "$root/fm-aged" ] || fail "an empty lsof snapshot must keep everything and exit 3, got $rc"
}

case_archive_failure_keeps_directory() {
  local world out root
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-aged" a.log || fail 'fixture'
  printf 'in the way\n' > "$world/fm/data/scratch-reaper-archive"
  out=$(reap "$world" --apply 2>&1) || fail "run failed: $out"
  [ -d "$root/fm-aged" ] || fail 'a directory was removed although its logs were not archived'
  assert_contains "$out" "kept $root/fm-aged reason=archive failed" 'archive failure not named'
}

case_oversize_logs_not_archived() {
  local world out root d i
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-big" small.log || fail 'fixture'
  head -c 1048577 /dev/zero > "$root/fm-big/big.log"
  make_aged "$root/fm-many" || fail 'fixture'
  i=1
  while [ "$i" -le 22 ]; do head -c 1048576 /dev/zero > "$root/fm-many/f$i.log"; i=$((i + 1)); done
  make_aged "$root/fm-bigyoung" a.log || fail 'fixture'
  head -c 1048577 /dev/zero > "$root/fm-bigyoung/big.log"
  sr_age_tree "$root/fm-big"; sr_age_tree "$root/fm-many"
  touch "$root/fm-bigyoung/fresh"
  out=$(reap "$world" --apply) || fail "run failed: $out"
  [ ! -e "$root/fm-big" ] || fail 'an oversize log must not keep an otherwise safe directory'
  assert_contains "$out" "removed $root/fm-big " 'fm-big not removed'
  assert_contains "$out" 'archived=1 skipped_logs=1' 'the line does not say the oversize log was skipped'
  d=$(archive_dirs "$world" fm-big)
  [ -f "$d/small.log" ] && [ ! -e "$d/big.log" ] || fail 'the oversize log was archived or the small one was not'
  assert_contains "$out" "removed $root/fm-many " 'fm-many not removed'
  assert_contains "$out" 'archived=20 skipped_logs=2' 'the 20 MiB per-directory cap did not hold'
  [ -d "$root/fm-bigyoung" ] || fail 'a young directory with an oversize log was removed'
}

# A cp that passes through for the first call and fails (or corrupts) from the second on.
install_cp_fault() {  # <world> fail|corrupt
  cat > "$1/fakebin/cp" <<SH
#!/bin/sh
here=\$(dirname "\$0")
n=\$(cat "\$here/cp.count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "\$here/cp.count"
if [ "\$n" -ge 2 ]; then
  [ "$2" = fail ] && exit 1
  /bin/cp "\$@" || exit 1
  for last in "\$@"; do :; done
  printf 'x' >> "\$last"
  exit 0
fi
exec /bin/cp "\$@"
SH
  chmod +x "$1/fakebin/cp"
}

log_lines_are_single() {  # <world>: every line of the decision log starts with a UTC time
  local stray
  stray=$(grep -vc '^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T' "$(state_log "$1")") || stray=0
  [ "$stray" -eq 0 ] || fail "a name split the decision log into $stray stray lines"
}

case_newline_file_names_archived() {
  local world out root nl=$'\n' d f i=0
  local -a files sums=()
  new_world; world=$SR_WORLD; root=$world/root
  files=("new${nl}line.log" "-dash.txt" "sp ace.md" "sub${nl}dir/in.json" "trail${nl}.err")
  make_aged "$root/fm-log" "${files[@]}" || fail 'fixture'
  for f in "${files[@]}"; do sums+=("$(sr_sha "$root/fm-log/$f")"); done
  out=$(reap "$world" --apply 2>&1) || fail "run failed: $out"
  [ ! -e "$root/fm-log" ] || fail 'the directory with newline and dash file names was not removed'
  d=$(archive_dirs "$world" fm-log)
  [ -n "$d" ] || fail 'no archive folder for the directory with hostile file names'
  for f in "${files[@]}"; do
    [ -f "$d/$f" ] || fail "the small log '$f' was deleted with no archived copy"
    [ "$(sr_sha "$d/$f")" = "${sums[$i]}" ] || fail "the archived copy of '$f' differs from its original (sha256)"
    i=$((i + 1))
  done
  assert_contains "$out" 'archived=5 skipped_logs=0' 'every hostile-named log must be archived and none skipped'
  log_lines_are_single "$world"
}

case_leading_dash_directory() {
  local world out root
  new_world; world=$SR_WORLD; root=$world/root
  printf '%s fm-*\n%s -*\n' "$root" "$root" > "$world/fm/config/scratch-reaper"
  make_aged "$root/-lead" a.log -b.txt || fail 'fixture'
  make_aged "$root/-held" held.log || fail 'fixture'
  start_sleeper "$root/-held"
  out=$(reap "$world" --apply 2>&1) || { stop_sleepers; fail "run failed: $out"; }
  stop_sleepers
  [ ! -e "$root/-lead" ] || fail 'a leading-dash directory was not removed'
  assert_contains "$out" "removed $root/-lead bytes=" 'the leading-dash directory removal is not logged'
  [ -n "$(archive_dirs "$world" -lead)" ] && [ -f "$(archive_dirs "$world" -lead)/-b.txt" ] || fail 'the leading-dash directory logs were not archived'
  [ -d "$root/-held" ] || fail 'a leading-dash directory holding a process cwd was removed'
  assert_contains "$out" "kept $root/-held reason=open handle" 'the leading-dash holder is not kept for an open handle'
}

case_newline_directory_names() {
  local world out root nl=$'\n'
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-nl${nl}dir" a.log || fail 'fixture'
  make_aged "$root/fm-trail${nl}" a.log || fail 'fixture'
  make_aged "$root/fm-young${nl}x" a.log || fail 'fixture'
  printf 'n\n' > "$root/fm-young${nl}x/fresh.txt"
  out=$(reap "$world" --apply 2>&1) || fail "run failed: $out"
  [ ! -e "$root/fm-nl${nl}dir" ] || fail 'a newline-named directory was not removed'
  [ ! -e "$root/fm-trail${nl}" ] || fail 'a directory whose name ends in a newline was not removed'
  assert_contains "$out" "removed $root/"'fm-nl\ndir bytes=' 'a newline in a name must print as \n on one line'
  [ -d "$root/fm-young${nl}x" ] || fail 'a young newline-named directory was removed'
  assert_contains "$out" "kept $root/"'fm-young\nx reason=young' 'the young newline-named directory is not kept as young'
  log_lines_are_single "$world"
}

case_newline_directory_open_handle_kept() {
  local world out root nl=$'\n'
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-hold${nl}x" held.log || fail 'fixture'
  make_aged "$root/fm-file${nl}y" held2.log || fail 'fixture'
  start_sleeper "$root/fm-hold${nl}x"
  start_sleeper "$world" "$root/fm-file${nl}y/held2.log"
  out=$(reap "$world" --apply 2>&1) || { stop_sleepers; fail "run failed: $out"; }
  stop_sleepers
  [ -d "$root/fm-hold${nl}x" ] || fail 'a newline-named directory holding a process cwd was removed'
  [ -d "$root/fm-file${nl}y" ] || fail 'a newline-named directory holding an open file was removed'
  assert_contains "$out" "kept $root/"'fm-hold\nx reason=open handle' 'the newline-named cwd holder is not kept for an open handle'
  assert_contains "$out" "kept $root/"'fm-file\ny reason=open handle' 'the newline-named open-file holder is not kept for an open handle'
  log_lines_are_single "$world"
}

case_archive_read_failure_keeps_directory() {
  local world out root
  [ "$(id -u)" -ne 0 ] || { echo 'ok - skipped the unreadable-log case: running as root reads any file'; return 0; }
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-unreadable" good.log bad.log || fail 'fixture'
  chmod 000 "$root/fm-unreadable/bad.log"
  out=$(reap "$world" --apply 2>&1) || fail "run failed: $out"
  [ -f "$root/fm-unreadable/good.log" ] && [ -e "$root/fm-unreadable/bad.log" ] || fail 'a directory with an unreadable small log was removed'
  assert_contains "$out" "kept $root/fm-unreadable reason=archive failed" 'an unreadable log must keep the directory as archive failed'
  [ "$(grep -c "removed $root/fm-unreadable" "$(state_log "$world")")" -eq 0 ] || fail 'the log says removed for a kept directory'
}

case_archive_before_remove_ordering() {
  local world out root before after d
  new_world; world=$SR_WORLD; root=$world/root
  make_aged "$root/fm-order" a.log b.log c.txt keep.bin || fail 'fixture'
  before=$(find "$root/fm-order" -type f -exec cksum {} + | sort)
  install_cp_fault "$world" fail
  out=$(reap "$world" --apply 2>&1) || fail "run failed: $out"
  [ "$(cat "$world/fakebin/cp.count")" -ge 2 ] || fail 'the fault never reached a second copy, so the ordering is untested'
  after=$(find "$root/fm-order" -type f -exec cksum {} + | sort)
  [ -d "$root/fm-order" ] && [ "$before" = "$after" ] || fail 'a directory was removed or changed although its second log failed to archive'
  assert_contains "$out" "kept $root/fm-order reason=archive failed" 'the failed second copy is not named'
  case "$out" in *"removed $root/fm-order"*) fail 'the run says removed for a kept directory' ;; esac
  d=$(archive_dirs "$world" fm-order)
  [ -n "$d" ] && [ "$(find "$d" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail 'the first copy did not land before the second failed'
  # A copy that differs from its source is a failure too.
  rm -f "$world/fakebin/cp.count"
  rm -rf "$world/fm/data/scratch-reaper-archive"
  install_cp_fault "$world" corrupt
  out=$(reap "$world" --apply 2>&1) || fail "run failed: $out"
  [ -d "$root/fm-order" ] || fail 'a directory was removed although its archived copy differs from the original'
  assert_contains "$out" "kept $root/fm-order reason=archive failed" 'a corrupt copy is not named as archive failed'
}

case_one_snapshot_per_run() {
  local world root real out
  new_world; world=$SR_WORLD; root=$world/root
  real=$(command -v lsof)
  make_aged "$root/fm-one" a.log || fail 'fixture'
  make_aged "$root/fm-two" a.log || fail 'fixture'
  make_aged "$root/fm-three" a.log || fail 'fixture'
  printf '#!/bin/sh\necho x >> "%s/fakebin/lsof.calls"\nexec "%s" "$@"\n' "$world" "$real" > "$world/fakebin/lsof"
  chmod +x "$world/fakebin/lsof"
  out=$(reap "$world" --apply) || fail "run failed: $out"
  [ "$(wc -l < "$world/fakebin/lsof.calls" | tr -d ' ')" -eq 1 ] || fail 'the run must take exactly one lsof snapshot for all candidates'
  [ ! -e "$root/fm-one" ] && [ ! -e "$root/fm-two" ] && [ ! -e "$root/fm-three" ] || fail 'the free candidates were not removed'
}

# --- the schedule (SR3) --------------------------------------------------------

install_df() {  # <world> <available-KiB>
  cat > "$1/fakebin/df" <<SH
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/fake 2000000000 1000000000 $2 50%% /\n'
SH
  chmod +x "$1/fakebin/df"
}

sched() {  # <world> <epoch>
  local world=$1 at=$2
  SR_EXTRA_ENV="FM_SCRATCH_REAPER_NOW=$at" reap "$world" --scheduled
}

wake_rows() {
  local n
  n=$(grep -c 'scratch-reaper-low-disk' "$1/fm/state/.wake-queue" 2>/dev/null) || n=0
  printf '%s\n' "${n:-0}"
}

case_schedule_one_run_per_window() {
  local world root t=1800000000 out
  new_world; world=$SR_WORLD; root=$world/root
  install_df "$world" 104857600
  make_aged "$root/fm-a" a.log || fail 'fixture'
  sched "$world" "$t" >/dev/null || fail 'the first scheduled run failed'
  [ ! -e "$root/fm-a" ] || fail 'the first scheduled run did not reap'
  [ "$(cat "$world/fm/state/.scratch-reaper-next")" = "$((t + 1800))" ] || fail 'the window marker is not now + 1800'
  make_aged "$root/fm-b" a.log || fail 'fixture'
  out=$(sched "$world" "$((t + 100))") || fail 'a run inside the window failed'
  [ -d "$root/fm-b" ] || fail 'a run inside the window reaped'
  [ -z "$out" ] || fail "a run inside the window must be silent, got: $out"
  sched "$world" "$((t + 1799))" >/dev/null || fail 'run failed'
  [ -d "$root/fm-b" ] || fail 'a run one second before the window ended reaped'
  sched "$world" "$((t + 1800))" >/dev/null || fail 'the run at the window end failed'
  [ ! -e "$root/fm-b" ] || fail 'a run at the window end did not reap'
}

case_schedule_alarm_only_when_low_and_nothing_freed() {
  local world t=1800000000 root
  # Low space, nothing to remove: one wake, repeated only after 6 hours.
  new_world; world=$SR_WORLD; root=$world/root
  install_df "$world" 10485760
  sched "$world" "$t" >/dev/null || fail 'run failed'
  [ "$(wake_rows "$world")" = 1 ] || fail 'low space and nothing freed must raise one low-disk wake'
  grep -q 'check' "$world/fm/state/.wake-queue" || fail 'the wake is not a check wake'
  sched "$world" "$((t + 1800))" >/dev/null || fail 'run failed'
  [ "$(wake_rows "$world")" = 1 ] || fail 'the alarm repeated inside 6 hours'
  sched "$world" "$((t + 21600 + 1800))" >/dev/null || fail 'run failed'
  [ "$(wake_rows "$world")" = 2 ] || fail 'the alarm did not resurface after 6 hours'
  # Space recovered: the alarm marker clears and no wake is raised.
  install_df "$world" 104857600
  sched "$world" "$((t + 90000))" >/dev/null || fail 'run failed'
  [ "$(wake_rows "$world")" = 2 ] && [ ! -e "$world/fm/state/.scratch-reaper-alarmed" ] || fail 'recovered space must clear the alarm quietly'
  # Low space but the run freed bytes: no wake.
  new_world; world=$SR_WORLD; root=$world/root
  install_df "$world" 10485760
  make_aged "$root/fm-a" a.log || fail 'fixture'
  sched "$world" "$t" >/dev/null || fail 'run failed'
  [ "$(wake_rows "$world")" = 0 ] || fail 'a run that freed space raised the low-disk alarm'
  # Plenty of space and nothing freed: no wake.
  new_world; world=$SR_WORLD
  install_df "$world" 104857600
  sched "$world" "$t" >/dev/null || fail 'run failed'
  [ "$(wake_rows "$world")" = 0 ] || fail 'plenty of space raised the low-disk alarm'
}

case_schedule_failures_never_propagate() {
  local world root t=1800000000 holder n=0 rc
  # A failing lsof is logged as an error and the aged directory is kept.
  new_world; world=$SR_WORLD; root=$world/root
  install_df "$world" 104857600
  make_aged "$root/fm-a" a.log || fail 'fixture'
  printf '#!/bin/sh\nexit 1\n' > "$world/fakebin/lsof"; chmod +x "$world/fakebin/lsof"
  sched "$world" "$t" >/dev/null && rc=0 || rc=$?
  [ "$rc" -eq 3 ] || fail "a failing scheduled run must report exit 3, got $rc"
  grep -q 'error rc=3' "$(state_log "$world")" || fail 'the failure is not logged'
  [ -d "$root/fm-a" ] || fail 'a failed scheduled run removed something'
  # A busy lock is logged and exits 0.
  new_world; world=$SR_WORLD; root=$world/root
  install_df "$world" 104857600
  make_aged "$root/fm-a" a.log || fail 'fixture'
  env FM_STATE_OVERRIDE="$world/fm/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" && exec sleep 600' _ "$ROOT" "$world/fm/state/.scratch-reaper.lock" &
  holder=$!
  SLEEPERS+=("$holder")
  while [ ! -e "$world/fm/state/.scratch-reaper.lock" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  sched "$world" "$t" >/dev/null && rc=0 || rc=$?
  stop_sleepers
  [ "$rc" -eq 0 ] || fail "a busy lock must not fail the run, got $rc"
  grep -q 'skipped lock busy' "$(state_log "$world")" || fail 'the busy lock is not logged'
  [ -d "$root/fm-a" ] || fail 'a run that lost the lock removed something'
  # A secondmate home never reaps.
  new_world; world=$SR_WORLD; root=$world/root
  : > "$world/fm/.fm-secondmate-home"
  make_aged "$root/fm-a" a.log || fail 'fixture'
  sched "$world" "$t" >/dev/null || fail 'a secondmate run failed'
  [ -d "$root/fm-a" ] || fail 'a secondmate home reaped'
}

# --- the helper's own refusal --------------------------------------------------

case_helper_refuses_real_roots() {
  local world rc root helper=${SR_HELPER:-$HELPERS} margs foreign
  local -a bad
  new_world; world=$SR_WORLD
  foreign=$TMP_ROOT/not-this-world
  mkdir -p "$foreign/sub" "$world/elsewhere" || fail 'fixture'
  # The aliases are plain symlinks: nothing here ever starts the reaper on them.
  ln -s /private/tmp "$world/alias-real-tmp" && ln -s "$foreign" "$world/alias-foreign" \
    && ln -s "$world/root" "$world/alias-inworld" && ln -s "$foreign" "$world/linkdir" || fail 'alias fixture'
  printf '#!/bin/sh\n: > "$FM_HOME/stub-ran"\n' > "$world/stub.sh"
  bad=(/private/tmp /tmp "$foreign" "$world/alias-real-tmp" "$world/alias-foreign" "$world/alias-inworld" \
    "$world/linkdir/sub" "$world/root/../.." "$world/missing-root")
  # Every refusal holds for a dry run, --apply and --scheduled, and no script starts.
  for root in "${bad[@]}"; do
    for margs in '' '--apply' '--scheduled'; do
      printf '%s fm-*\n' "$root" > "$world/fm/config/scratch-reaper"
      rm -f "$world/fm/stub-ran"
      # shellcheck disable=SC2086
      ( . "$helper"; sr_run "$world" --script "$world/stub.sh" -- $margs ) >/dev/null 2>&1 && rc=0 || rc=$?
      [ "$rc" -eq 99 ] || fail "the helper must refuse root '$root' for '${margs:-dry run}' with 99, got $rc"
      [ ! -e "$world/fm/stub-ran" ] || fail "the helper started the script for root '$root' and '${margs:-dry run}'"
    done
  done
  # The in-world symlink flag admits only a link that still ends inside the world.
  for root in "$world/alias-real-tmp" "$world/alias-foreign" "$world/linkdir/sub"; do
    printf '%s fm-*\n' "$root" > "$world/fm/config/scratch-reaper"
    rm -f "$world/fm/stub-ran"
    ( . "$helper"; sr_run "$world" --script "$world/stub.sh" --inworld-symlink-root -- --apply ) >/dev/null 2>&1 && rc=0 || rc=$?
    [ "$rc" -eq 99 ] && [ ! -e "$world/fm/stub-ran" ] || fail "the in-world symlink flag let root '$root' through"
  done
  printf '%s fm-*\n' "$world/alias-inworld" > "$world/fm/config/scratch-reaper"
  ( . "$helper"; sr_run "$world" --script "$world/stub.sh" --inworld-symlink-root -- --apply ) >/dev/null 2>&1 || fail 'the in-world symlink flag refused a link that ends inside the world'
  [ -e "$world/fm/stub-ran" ] || fail 'the helper did not run the script for an in-world symlink root with the flag'
  rm -f "$world/fm/stub-ran" "$world/fm/config/scratch-reaper"
  ( . "$helper"; sr_run "$world" --script "$world/stub.sh" -- --apply ) >/dev/null 2>&1 && rc=0 || rc=$?
  [ "$rc" -eq 99 ] && [ ! -e "$world/fm/stub-ran" ] || fail 'the helper ran with no private config'
  for margs in '' '--apply' '--scheduled'; do
    printf '%s fm-*\n' "$world/root" > "$world/fm/config/scratch-reaper"
    rm -f "$world/fm/stub-ran"
    # shellcheck disable=SC2086
    ( . "$helper"; sr_run "$world" --script "$world/stub.sh" -- $margs ) >/dev/null 2>&1 || fail "the helper refused a private world for '${margs:-dry run}'"
    [ -e "$world/fm/stub-ran" ] || fail "the helper did not run the script for a private root and '${margs:-dry run}'"
  done
}

# --- mutants: each dropped safety check must fail its named case ----------------

mutate() {  # <name> <old> <new> <file>: write a mutant of the script (or helper) and print its path
  local name=$1 old=$2 new=$3 src=$4 out
  out="$TMP_ROOT/mutants/$name.sh"
  mkdir -p "$TMP_ROOT/mutants"
  python3 -I - "$src" "$out" "$old" "$new" "$ROOT" <<'PY' || return 1
import sys
src, out, old, new, root = sys.argv[1:6]
text = open(src).read()
if old not in text:
    sys.exit("mutation target not found: " + old)
text = text.replace(old, new, 1)
marker = 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
if marker in text:
    text = text.replace(marker, 'SCRIPT_DIR="%s/bin"' % root, 1)
open(out, "w").write(text)
PY
  printf '%s\n' "$out"
}

mutant_must_fail() {  # <label> <case-function> <script-or-helper>
  local label=$1 fn=$2 path=$3
  if [ "$fn" = case_helper_refuses_real_roots ]; then
    ( SR_HELPER=$path; $fn ) >/dev/null 2>&1 && fail "mutant $label survived: $fn still passed"
  else
    ( SR_SCRIPT=$path; $fn ) >/dev/null 2>&1 && fail "mutant $label survived: $fn still passed"
  fi
  pass "mutant '$label' fails $fn"
}

test_aged_directory_is_removed_and_its_logs_archived() { case_aged_removed_and_archived; pass 'an aged unused directory is removed and its small logs are archived with matching sha256'; }
test_young_directory_is_kept() { case_young_kept; pass 'a young directory, and a directory with one new file deep inside, are kept'; }
test_open_handle_is_kept() { case_open_handle_kept; pass 'a live process cwd or open file keeps its directory and the reason says open handle'; }
test_git_and_pool_directories_are_kept() { case_git_kept; pass 'a git worktree, a repo, a nested repo and a pool slot are kept'; }
test_symlink_is_never_followed() { case_symlink_not_followed; pass 'a symlink child is kept, an escaping link inside a removed directory leaves its target alone, a symlink root is refused'; }
test_outside_root_is_never_touched() { case_outside_root_untouched; pass 'directories outside every allow-listed root or glob are never touched'; }
test_dry_run_changes_nothing() { case_dry_run_changes_nothing; pass 'a dry run changes nothing and writes no log or archive'; }
test_lsof_failure_keeps_everything() { case_lsof_failure_keeps_everything; pass 'a failing or empty lsof keeps everything and exits 3'; }
test_archive_failure_keeps_the_directory() { case_archive_failure_keeps_directory; pass 'an archive failure keeps the directory'; }
test_oversize_logs_are_not_archived() { case_oversize_logs_not_archived; pass 'oversize logs are skipped, the line says so, and a safe directory is still removed'; }
test_newline_file_names_are_archived() { case_newline_file_names_archived; pass 'small logs whose names hold a newline, a leading dash or a space are archived byte for byte before removal'; }
test_leading_dash_directory() { case_leading_dash_directory; pass 'a leading-dash directory is archived and removed, and kept while a process holds it'; }
test_newline_directory_names() { case_newline_directory_names; pass 'newline-named directories are removed or kept on their merits and logged on one line each'; }
test_newline_directory_open_handle() { case_newline_directory_open_handle_kept; pass 'a newline-named directory with a process cwd or open file is kept as open handle'; }
test_unreadable_log_keeps_the_directory() { case_archive_read_failure_keeps_directory; pass 'a small log that cannot be read keeps the directory as archive failed'; }
test_archive_finishes_before_removal() { case_archive_before_remove_ordering; pass 'a copy that fails on the second file, or differs from its source, keeps the whole directory untouched'; }
test_one_snapshot_per_run() { case_one_snapshot_per_run; pass 'one lsof snapshot serves every candidate of a run'; }
test_schedule_runs_once_per_window() { case_schedule_one_run_per_window; pass 'the scheduled run works once per window and not inside it'; }
test_schedule_alarm_only_when_low_and_nothing_freed() { case_schedule_alarm_only_when_low_and_nothing_freed; pass 'the low-disk alarm rises only with under 20 GiB free and nothing freed, and repeats only after 6 hours'; }
test_schedule_failures_never_propagate() { case_schedule_failures_never_propagate; pass 'a lsof failure, a busy lock and a secondmate home are logged or silent and never fail the cycle'; }
test_helper_refuses_real_roots() { case_helper_refuses_real_roots; pass 'the test helper starts no script for /private/tmp, /tmp, a foreign root, a symlink or ".." alias of one, or no config, in all three modes'; }

test_mutants_each_fail_a_named_case() {
  local m
  m=$(mutate drop-open-handle-check 'has_open_handle "$real"; rc=$?' 'rc=1' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'drop the open-handle check' case_open_handle_kept "$m"
  m=$(mutate drop-age-check '[ -n "$(find "$real" -newer "$REF" -print -quit 2>/dev/null)" ]' 'false' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'drop the age check' case_young_kept "$m"
  m=$(mutate drop-git-check '[ -n "$(find "$real" \( -name .git -o -name .fm-slot-owner \) -print -quit 2>/dev/null)" ]' 'false' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'drop the git check' case_git_kept "$m"
  m=$(mutate drop-archive-step 'archive_logs "$real" "$name"' 'true' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'drop the archive step' case_aged_removed_and_archived "$m"
  m=$(mutate drop-symlink-check 'if [ -L "$path" ]; then keep "$path" symlink; return 0; fi' ':' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'drop the symlink check' case_symlink_not_followed "$m"
  m=$(mutate newline-delimited-archive '-print0 > "$list"' '-print > "$list"' "$REAPER") || fail 'mutant build failed'
  m=$(mutate newline-delimited-archive-read "read -r -d '' f; do" 'read -r f; do' "$m") || fail 'mutant build failed'
  mutant_must_fail 'archive with newline-delimited paths' case_newline_file_names_archived "$m"
  m=$(mutate size-read-failure-skips 'size=$(wc -c < "$f" 2>/dev/null) || return 1' 'size=$(wc -c < "$f" 2>/dev/null) || size=' "$REAPER") || fail 'mutant build failed'
  m=$(mutate size-read-failure-skips-case "case \"\$size\" in ''|*[!0-9]*) return 1 ;; esac" "case \"\$size\" in ''|*[!0-9]*) ARCH_SKIPPED=\$((ARCH_SKIPPED + 1)); continue ;; esac" "$m") || fail 'mutant build failed'
  mutant_must_fail 'treat an unreadable log as skippable' case_archive_read_failure_keeps_directory "$m"
  m=$(mutate ignore-archive-failure 'if ! archive_logs "$real" "$name"; then keep "$path" "archive failed"; return 0; fi' 'archive_logs "$real" "$name" || true' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'remove after a failed archive' case_archive_before_remove_ordering "$m"
  m=$(mutate drop-verify-copy 'cmp -s -- "$f" "$dest/$rel" || return 1' ':' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'drop the byte comparison of the copy' case_archive_before_remove_ordering "$m"
  m=$(mutate snapshot-per-candidate 'if [ "$SNAPSHOT_STATE" = untaken ]; then take_snapshot || true; fi' 'take_snapshot || true' "$REAPER") || fail 'mutant build failed'
  mutant_must_fail 'take one snapshot per candidate' case_one_snapshot_per_run "$m"
  m=$(mutate drop-helper-symlink-root-check 'if [ -L "$root" ] && [ "${SR_SYMLINK_ROOT_OK:-0}" != 1 ]; then echo "sr_run: root '"'"'$root'"'"' is a symlink" >&2; return 1; fi' ':' "$HELPERS") || fail 'mutant build failed'
  mutant_must_fail 'drop the helper refusal of a symlink root' case_helper_refuses_real_roots "$m"
  m=$(mutate drop-helper-outside-world-check 'case "$real" in "$world"/*) ;;' 'case "$real" in *) ;;' "$HELPERS") || fail 'mutant build failed'
  mutant_must_fail 'drop the helper refusal of a root outside the world' case_helper_refuses_real_roots "$m"
  m=$(mutate helper-parent-only-resolve 'real=$(cd -P -- "$root" 2>/dev/null && pwd -P)' 'real=$(cd -P -- "$(dirname -- "$root")" 2>/dev/null && printf '"'%s/%s'"' "$(pwd -P)" "$(basename -- "$root")")' "$HELPERS") || fail 'mutant build failed'
  m=$(mutate helper-parent-only-no-symlink-check 'if [ -L "$root" ] && [ "${SR_SYMLINK_ROOT_OK:-0}" != 1 ]; then echo "sr_run: root '"'"'$root'"'"' is a symlink" >&2; return 1; fi' ':' "$m") || fail 'mutant build failed'
  mutant_must_fail 'resolve only the parent of a helper root (the old helper)' case_helper_refuses_real_roots "$m"
  m=$(mutate drop-helper-real-root-list 'case "$root" in /|/tmp|/private/tmp|/var/tmp|/var/folders|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}/tmp") echo "sr_run: root '"'"'$root'"'"' is a real root" >&2; return 1 ;; esac' ':' "$HELPERS") || fail 'mutant build failed'
  m=$(mutate drop-helper-outside-world-2 'case "$real" in "$world"/*) ;;' 'case "$real" in *) ;;' "$m") || fail 'mutant build failed'
  m=$(mutate drop-helper-symlink-check-2 'if [ -L "$root" ] && [ "${SR_SYMLINK_ROOT_OK:-0}" != 1 ]; then echo "sr_run: root '"'"'$root'"'"' is a symlink" >&2; return 1; fi' ':' "$m") || fail 'mutant build failed'
  mutant_must_fail 'drop every helper refusal of a root' case_helper_refuses_real_roots "$m"
}

trap 'stop_sleepers; fm_test_cleanup' EXIT

test_aged_directory_is_removed_and_its_logs_archived
test_young_directory_is_kept
test_open_handle_is_kept
test_git_and_pool_directories_are_kept
test_symlink_is_never_followed
test_outside_root_is_never_touched
test_dry_run_changes_nothing
test_lsof_failure_keeps_everything
test_archive_failure_keeps_the_directory
test_oversize_logs_are_not_archived
test_newline_file_names_are_archived
test_leading_dash_directory
test_newline_directory_names
test_newline_directory_open_handle
test_unreadable_log_keeps_the_directory
test_archive_finishes_before_removal
test_one_snapshot_per_run
test_schedule_runs_once_per_window
test_schedule_alarm_only_when_low_and_nothing_freed
test_schedule_failures_never_propagate
test_helper_refuses_real_roots
test_mutants_each_fail_a_named_case
