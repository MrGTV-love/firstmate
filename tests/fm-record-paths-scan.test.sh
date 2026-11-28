#!/usr/bin/env bash
# The per-record scans that read a task record's paths: bin/fm-teardown.sh's copy-clearance scan,
# fm_task_copy_other_record in bin/fm-task-copy-lib.sh, bin/fm-control.sh's reassociate_group_check and
# bin/fm-copy-sweep.sh's read_live_task_copies.
#
# Bash 3.2 keeps the pipe fd of every `done < <(cmd)` open until the enclosing function returns, and its next
# fork faulted once a pipe reached fd 256: a teardown over 253 or more records stalled in a child that spent
# its time in system calls and ignored SIGTERM, holding the project lock (data/fm-teardown-pure-bash-spin/report.md).
# The scans now read a record's paths into an array with pure bash (fm_task_copy_record_paths_to).
#
# What this pins:
#   1. The new reader returns byte-for-byte what the old fm_task_copy_record_paths printed (an inline copy of
#      the old function is the oracle), for every awkward record shape.
#   2. Each site's open-fd count, read synchronously inside its own per-record loop at every record, stays
#      flat for 10 and for 300 records: teardown's scan (the real teardown, a `git` shim logs the count),
#      fm_task_copy_other_record, reassociate_group_check for groups of 2 and 3 records (one read per
#      ordered pair), and fm-copy-sweep.sh check (a `date` shim logs the count).
#   3. Four mutants, one per site, each restoring the process substitution in an isolated copy of bin/,
#      fail that site's flatness case.
#   4. One refusal per record field (worktree=, home=, prior_worktree=) with the record after the 256th of an
#      N=300 fixture gives the same refusal text and exit status as the same record in a small fixture.
#   5. A teardown over 300 records ends like one over 10, with the same exit status and end state.
#   6. (2026-11-26, from a second live spinner) A teardown whose table cannot hold more than 64 open files ends like one
#      with room, and the mutant of case 3 cannot finish: one dead child does not cure a full table, the next fork meets it.
#   7. (2026-11-27) fm_task_copy_other_record takes its time limit from its caller (FM_TASK_COPY_SCAN_LIMIT_SECS): none or 0 is unbounded,
#      a limit stops the walk with status 3 once the clock has passed it, checked before each record, with nothing waited for.
# Usage: bash tests/fm-record-paths-scan.test.sh [test_function_name ...]
# The cases source libraries inside subshells on purpose, so a variable they set there is not the suite's own.
# The libraries sourced inside the subshells are named by a variable, so ShellCheck cannot follow them.
# shellcheck disable=SC1090,SC1091,SC2030,SC2031
set -u

# shellcheck source=tests/fm-record-scan-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-record-scan-helpers.sh"
# FM_RECORD_SCAN_BIN names the bin directory the cases drive (default: this checkout's). Pointing it at an older bin/
# shows the cases fail for the leak they pin; FM_RECORD_SCAN_STOP_AFTER=<n> then stops a teardown that leaks a pipe per
# record after n reads, before it reaches the fault (SIGTERM to its own group leader).
SCAN_BIN=${FM_RECORD_SCAN_BIN:-$ROOT/bin}
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$ROOT/bin/fm-task-copy-lib.sh"

# The reader as it was before it became a pure-bash array fill (origin/main 114a9cd55): the oracle for case 1.
old_fm_task_copy_record_paths() {  # <meta>
  local meta=$1 value line
  for value in worktree home; do
    line=$(fm_meta_get "$meta" "$value")
    [ -z "$line" ] || printf '%s %s\n' "$value" "$line"
  done
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      prior_worktree=?*) printf 'prior_worktree %s\n' "${line#prior_worktree=}" ;;
    esac
  done < "$meta" 2>/dev/null || true
}

# --- fd-count logs -----------------------------------------------------------------------------------------

# fd_log_report <log> <what>: sets FD_FIRST FD_LAST FD_MAX FD_MIN FD_CALLS.
fd_log_report() {
  FD_CALLS=$(wc -l < "$1" | tr -d ' ')
  FD_FIRST=$(head -1 "$1")
  FD_LAST=$(tail -1 "$1")
  FD_MAX=$(sort -n "$1" | tail -1)
  FD_MIN=$(sort -n "$1" | head -1)
}

# fd_log_flat <log>: true when the log has lines and every count is the same.
fd_log_flat() {
  [ -s "$1" ] || return 1
  fd_log_report "$1"
  [ "$FD_MAX" = "$FD_MIN" ]
}

assert_fd_flat() {  # <log> <min-calls> <label>
  fd_log_flat "$1" || fail "$3: the open-fd count was not flat: first $FD_FIRST last $FD_LAST min $FD_MIN max $FD_MAX over ${FD_CALLS:-0} reads"
  [ "$FD_CALLS" -ge "$2" ] || fail "$3: only $FD_CALLS fd reads, expected at least $2 (the loop did not run once per record)"
}

assert_fd_grows() {  # <log> <min-calls> <label>
  [ -s "$1" ] || fail "$3: no fd reads at all"
  fd_log_report "$1"
  [ "$FD_CALLS" -ge "$2" ] || fail "$3: only $FD_CALLS fd reads, expected at least $2"
  [ "$FD_LAST" -gt "$FD_FIRST" ] || fail "$3: the mutant did not grow the fd count (first $FD_FIRST last $FD_LAST); the case cannot see the leak"
}

# Bash 3.2 keeps the pipe fd of every `done < <(cmd)` open until the enclosing
# function returns, which is the leak the mutants reproduce. Newer Bash releases
# (such as Bash 5 on Linux CI) close loop process-substitution pipes per
# iteration, so restoring `< <(...)` cannot grow the fd count there. Probe this
# shell's actual behavior instead of assuming Bash 3.2.
bash_leaks_procsub_fd() {
  local before after i
  local -a fds
  fds=(/dev/fd/*); before=${#fds[@]}
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    while IFS= read -r _; do :; done < <(printf '%s\n' "$i")
  done
  fds=(/dev/fd/*); after=${#fds[@]}
  [ $((after - before)) -ge 8 ]
}

# --- mutants: an isolated copy of bin/ with one site's process substitution restored --------------------------

# make_mutant_bin <dir> <site>: <dir>/bin holds symlinks to every real bin file except the one the mutant edits.
make_mutant_bin() {
  local dir=$1 site=$2 f file
  mkdir -p "$dir/bin"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$dir/bin/${f##*/}"; done
  case "$site" in
    lib) file=fm-task-copy-lib.sh ;;
    teardown) file=fm-teardown.sh ;;
    control) file=fm-control.sh ;;
    sweep) file=fm-copy-sweep.sh ;;
    *) fail "unknown mutant site $site" ;;
  esac
  rm -f "$dir/bin/$file"
  FM_MUTANT_SITE=$site python3 -I - "$ROOT/bin/$file" "$dir/bin/$file" <<'PY' || fail "mutant $site: the head text no longer has the anchors this mutant edits"
import os, sys
src, dst = sys.argv[1], sys.argv[2]
site = os.environ["FM_MUTANT_SITE"]
text = open(src).read()
RECS = '${FM_TASK_COPY_RECORD_PATHS[@]+"${FM_TASK_COPY_RECORD_PATHS[@]}"}'
REC = '${rec_lines[@]+"${rec_lines[@]}"}'
def once(t, a, b):
    if t.count(a) != 1:
        sys.exit(1)
    return t.replace(a, b)
if site == "lib":
    text = once(text, 'fm_task_copy_record_paths_to "$other_meta"\n      rec_lines=(%s)\n      for line in %s; do' % (RECS, REC),
                'while IFS= read -r line || [ -n "$line" ]; do')
    text = once(text, '      done\n    done\n  done\n  return 1\n}', '      done < <(fm_task_copy_record_paths "$other_meta")\n    done\n  done\n  return 1\n}')
elif site == "teardown":
    text = once(text, 'fm_task_copy_record_paths_to "$other_meta"\n      rec_lines=(%s)\n      for line in %s; do' % (RECS, REC),
                'while IFS= read -r line || [ -n "$line" ]; do')
    text = once(text, '      done\n    done\n  done\n  return 0\n}', '      done < <(fm_task_copy_record_paths "$other_meta")\n    done\n  done\n  return 0\n}')
    # A foreground command reaps the substitution's child and closes its pipe, so the foreground read of Git's answer
    # alone would keep the count flat: the mutant restores the whole old read, command substitution included.
    text = once(text, '        git -C "$copy_real" rev-parse --path-format=absolute --git-common-dir > "$TEARDOWN_SCAN_TMP" 2>/dev/null \\\n          && IFS= read -r copy_common < "$TEARDOWN_SCAN_TMP" || copy_common=\n',
                '        copy_common=$(git -C "$copy_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || copy_common=\n')
elif site == "control":
    text = once(text, 'fm_task_copy_record_paths_to "${RA_METAS[j]}"\n      rec_lines=(%s)\n      for line in %s; do' % (RECS, REC),
                'while IFS= read -r line; do')
    text = once(text, '      done\n    done\n  done\n}\n\n# One proof pass', '      done < <(fm_task_copy_record_paths "${RA_METAS[j]}")\n    done\n  done\n}\n\n# One proof pass')
elif site == "sweep":
    text = once(text, 'fm_task_copy_record_paths_to "$meta"\n      rec_lines=(%s)\n      for line in %s; do' % (RECS, REC),
                'while IFS= read -r line; do')
    text = once(text, '      done\n    done\n  done\n}\n\nenumerate_clones', '      done < <(fm_task_copy_record_paths "$meta")\n    done\n  done\n}\n\nenumerate_clones')
open(dst, "w").write(text)
os.chmod(dst, 0o755)
PY
  /bin/bash -n "$dir/bin/$file" || fail "mutant $site does not parse"
}

# --- case 1: the reader ----------------------------------------------------------------------------------

# write_record <file> <printf-format-with-\n>...: the bytes exactly as given (no trailing newline added).
test_record_reader_matches_the_old_reader_byte_for_byte() {
  local dir="$TMP_ROOT/reader" name f want got want_err got_err
  mkdir -p "$dir"
  printf 'worktree=/a/b\nhome=/h\nprior_worktree=/p1\nprior_worktree=/p2' > "$dir/no-trailing-newline.meta"
  printf 'worktree=\nhome=/h\nprior_worktree=\n' > "$dir/empty-values.meta"
  printf 'worktree=/first\nhome=/h1\nworktree=/second\nhome=/h2\nprior_worktree=/p\n' > "$dir/repeated-last-wins.meta"
  printf 'worktree=/a b/c d\nprior_worktree=/with space/and  two\nprior_worktree=/tab\there\n' > "$dir/spaces.meta"
  printf 'prior_worktree=\nprior_worktree=/x\n' > "$dir/empty-prior.meta"
  printf 'worktree=/back\\slash\\n/x\nprior_worktree=/p\\q\n' > "$dir/backslash.meta"
  printf 'kind=ship\nproject=/p\n' > "$dir/none.meta"
  printf 'worktree=/a=b=c\nprior_worktree=/x=y\nworktreeX=/no\nprior_worktreeX=/no\n' > "$dir/equals.meta"
  : > "$dir/empty-file.meta"
  printf 'worktree=/unreadable\nprior_worktree=/p\n' > "$dir/unreadable.meta"
  chmod 000 "$dir/unreadable.meta"
  for name in no-trailing-newline empty-values repeated-last-wins spaces empty-prior backslash none equals empty-file unreadable missing; do
    f="$dir/$name.meta"
    old_fm_task_copy_record_paths "$f" > "$dir/want" 2> "$dir/want.err"
    fm_task_copy_record_paths "$f" > "$dir/got" 2> "$dir/got.err"
    cmp -s "$dir/want" "$dir/got" || fail "reader $name: output differs from the old reader: old [$(cat "$dir/want")] new [$(cat "$dir/got")]"
    # Only the script and line a shell names in front of an error differ (the new loop is another line).
    want_err=$(sed -E -e "s#$dir#DIR#g" -e 's#^[^ ]*: (line [0-9]+: )?##' "$dir/want.err")
    got_err=$(sed -E -e "s#$dir#DIR#g" -e 's#^[^ ]*: (line [0-9]+: )?##' "$dir/got.err")
    [ "$want_err" = "$got_err" ] || fail "reader $name: stderr differs from the old reader: old [$want_err] new [$got_err]"
    # The array form holds the same entries.
    fm_task_copy_record_paths_to "$f" 2>/dev/null
    got=$(printf '%s\n' ${FM_TASK_COPY_RECORD_PATHS[@]+"${FM_TASK_COPY_RECORD_PATHS[@]}"})
    if [ -s "$dir/want" ]; then
      [ "$got" = "$(cat "$dir/want")" ] || fail "reader $name: array entries differ from the old lines"
    else
      [ "${#FM_TASK_COPY_RECORD_PATHS[@]}" = 0 ] || fail "reader $name: array not empty for an empty record"
    fi
  done
  chmod 600 "$dir/unreadable.meta"
  pass "the pure-bash record reader returns exactly what the old reader printed"
}

test_canonical_dir_without_a_fork_matches_the_forking_one_and_keeps_the_directory() {
  local dir="$TMP_ROOT/canon" want got saved_pwd t rc_a rc_b name
  mkdir -p "$dir/real/sub" "$dir/with space" "$dir/noexec"
  ln -s "$dir/real" "$dir/link"
  ln -s "$dir/real/sub" "$dir/real/sublink"
  : > "$dir/file"
  chmod 000 "$dir/noexec"
  cd "$dir/real" || fail "cannot enter the fixture"
  saved_pwd=$PWD
  OLDPWD=/marker-oldpwd
  for name in "$dir/real" "$dir/link" "$dir/real/sublink" "$dir/with space" "$dir/real/../real/sub" "$dir/real/" "$dir/file" "$dir/missing" "$dir/noexec" "" "sub" "./sub" ".."; do
    want=$(fm_task_copy_canonical_dir "$name" 2>/dev/null); rc_a=$?
    got=; fm_task_copy_canonical_dir_to got "$name" 2>/dev/null; rc_b=$?
    [ "$rc_a" = "$rc_b" ] || fail "canonical_dir_to [$name]: status $rc_b, the forking reader gave $rc_a"
    [ "$want" = "$got" ] || fail "canonical_dir_to [$name]: [$got] vs the forking reader's [$want]"
    [ "$PWD" = "$saved_pwd" ] || fail "canonical_dir_to [$name]: the working directory moved to $PWD"
    [ "$OLDPWD" = /marker-oldpwd ] || fail "canonical_dir_to [$name]: OLDPWD changed to $OLDPWD"
  done
  chmod 755 "$dir/noexec"
  # A caller whose own directory is gone is put in / rather than left in the target.
  mkdir "$dir/gone" && cd "$dir/gone" && rmdir "$dir/gone"
  t=; fm_task_copy_canonical_dir_to t "$dir/real" 2>/dev/null
  [ "$t" = "$dir/real" ] || fail "canonical_dir_to from a removed directory gave [$t]"
  [ "$PWD" = / ] || fail "canonical_dir_to left a caller whose directory is gone in $PWD, not /"
  cd "$ROOT" || true
  pass "the fork-free canonical path equals the forking one for every awkward path and puts the directory back"
}

# --- case 2: fm_task_copy_other_record ------------------------------------------------------------------------

# make_records_state <dir> <n>: <dir>/state holds n records, each naming its own existing directory.
make_records_state() {
  local dir=$1 n=$2 i
  mkdir -p "$dir/state" "$dir/dirs" "$dir/target"
  i=1
  while [ "$i" -le "$n" ]; do
    mkdir -p "$dir/dirs/d$i" "$dir/dirs/h$i"
    printf 'worktree=%s\nhome=%s\nkind=ship\nproject=%s\n' "$dir/dirs/d$i" "$dir/dirs/h$i" "$dir/dirs" \
      > "$dir/state/t$(printf '%04d' "$i").meta"
    i=$((i + 1))
  done
  printf 'worktree=%s\n' "$dir/target" > "$dir/state/self.meta"
}

# other_record_fd_log <bin-dir> <dir> <log>: runs fm_task_copy_other_record in a subshell that sources the
# libraries from <bin-dir> and logs the open-fd count at every per-record canonical-path read.
other_record_fd_log() {
  local bindir=$1 dir=$2 log=$3
  : > "$log"
  (
    export FM_FD_LOG=$log
    export FM_HOME="$dir/home"
    mkdir -p "$FM_HOME/state" "$FM_HOME/data"
    # shellcheck disable=SC1090,SC1091
    . "$bindir/fm-backend.sh"; . "$bindir/fm-wake-lib.sh"; . "$bindir/fm-secondmate-registry-lib.sh"; . "$bindir/fm-task-copy-lib.sh"
    # shellcheck disable=SC2329 # called by the library code under test
    fm_task_copy_canonical_dir() {
      local t=$1 fds
      [ -n "$t" ] && [ -d "$t" ] || return 1
      fds=(/dev/fd/*)
      echo "${#fds[@]}" >> "$FM_FD_LOG"
      ( cd "$t" && pwd -P )
    }
    fm_task_copy_other_record "$dir/state/self.meta" "$dir/state" "$dir/target" >/dev/null 2>&1
    echo "$?" > "$log.rc"
  )
}

test_other_record_scan_keeps_the_fd_count_flat() {
  local n dir
  for n in 10 300; do
    dir="$TMP_ROOT/other-$n"
    make_records_state "$dir" "$n"
    other_record_fd_log "$SCAN_BIN" "$dir" "$dir/fd.log"
    [ "$(cat "$dir/fd.log.rc")" = 1 ] || fail "other_record N=$n: expected 'no other record names it' (1), got $(cat "$dir/fd.log.rc")"
    assert_fd_flat "$dir/fd.log" "$((n * 2))" "other_record N=$n"
  done
  pass "fm_task_copy_other_record holds no pipe fd past a record for 10 and 300 records"
}

test_mutant_other_record_with_a_process_substitution_grows_the_fd_count() {
  local dir="$TMP_ROOT/other-mutant"
  make_mutant_bin "$dir/m" lib
  if ! bash_leaks_procsub_fd; then
    pass "fm_task_copy_other_record mutant built and parsed ($BASH_VERSION closes loop process-substitution pipes without the Bash 3.2 leak)"
    return 0
  fi
  make_records_state "$dir" 40
  other_record_fd_log "$dir/m/bin" "$dir" "$dir/fd.log"
  assert_fd_grows "$dir/fd.log" 40 "other_record mutant"
  pass "restoring the process substitution in fm_task_copy_other_record makes its fd case fail"
}

# --- case 3: reassociate_group_check -----------------------------------------------------------------------------

# group_fd_log <bin-dir> <dir> <group-size> <log>: reassociate_group_check lifted out of <bin-dir>/fm-control.sh,
# run over a group of <group-size> records; one record read per ordered pair.
group_fd_log() {
  local bindir=$1 dir=$2 size=$3 log=$4 fn i
  mkdir -p "$dir"
  : > "$log"
  fn=$(awk '/^reassociate_group_check\(\) \{/,/^}/' "$bindir/fm-control.sh")
  [ -n "$fn" ] || fail "reassociate_group_check not found in $bindir/fm-control.sh"
  mkdir -p "$dir/g"
  i=0
  while [ "$i" -lt "$size" ]; do
    mkdir -p "$dir/g/new$i" "$dir/g/old$i" "$dir/g/home$i" "$dir/g/prior$i"
    printf 'worktree=%s\nhome=%s\nprior_worktree=%s\n' "$dir/g/old$i" "$dir/g/home$i" "$dir/g/prior$i" > "$dir/g/m$i.meta"
    i=$((i + 1))
  done
  (
    export FM_FD_LOG=$log FM_GROUP_DIR="$dir/g" FM_GROUP_SIZE=$size
    # shellcheck disable=SC1090,SC1091
    . "$bindir/fm-backend.sh"; . "$bindir/fm-wake-lib.sh"; . "$bindir/fm-secondmate-registry-lib.sh"; . "$bindir/fm-task-copy-lib.sh"
    # shellcheck disable=SC2329 # called by the library code under test
    fm_task_copy_canonical_dir() {
      local t=$1 fds
      [ -n "$t" ] && [ -d "$t" ] || return 1
      fds=(/dev/fd/*)
      echo "${#fds[@]}" >> "$FM_FD_LOG"
      ( cd "$t" && pwd -P )
    }
    # shellcheck disable=SC2329 # called by the extracted function
    die() { echo "die: $*" > "$FM_FD_LOG.die"; exit 9; }
    # shellcheck disable=SC2329 # called by the extracted function
    reassociate_select() { :; }
    RA_IDS=(); RA_METAS=(); RA_NEWWT=(); RA_OLDREAL=()
    k=0
    while [ "$k" -lt "$FM_GROUP_SIZE" ]; do
      RA_IDS+=("t$k"); RA_METAS+=("$FM_GROUP_DIR/m$k.meta"); RA_NEWWT+=("$FM_GROUP_DIR/new$k"); RA_OLDREAL+=("$FM_GROUP_DIR/old$k")
      k=$((k + 1))
    done
    eval "$fn"
    reassociate_group_check
    echo "$?" > "$FM_FD_LOG.rc"
  )
}

test_reassociate_group_check_keeps_the_fd_count_flat() {
  local size dir
  for size in 2 3; do
    dir="$TMP_ROOT/group-$size"
    group_fd_log "$SCAN_BIN" "$dir" "$size" "$dir/fd.log"
    [ ! -e "$dir/fd.log.die" ] || fail "group of $size: unexpected die: $(cat "$dir/fd.log.die")"
    [ "$(cat "$dir/fd.log.rc")" = 0 ] || fail "group of $size: reassociate_group_check returned $(cat "$dir/fd.log.rc")"
    # One read per ordered pair, three paths each.
    assert_fd_flat "$dir/fd.log" "$((size * (size - 1) * 3))" "reassociate_group_check group of $size"
  done
  pass "reassociate_group_check holds no pipe fd past an ordered pair for groups of 2 and 3"
}

test_mutant_group_check_with_a_process_substitution_grows_the_fd_count() {
  local dir="$TMP_ROOT/group-mutant"
  make_mutant_bin "$dir/m" control
  if ! bash_leaks_procsub_fd; then
    pass "reassociate_group_check mutant built and parsed ($BASH_VERSION closes loop process-substitution pipes without the Bash 3.2 leak)"
    return 0
  fi
  group_fd_log "$dir/m/bin" "$dir" 3 "$dir/fd.log"
  assert_fd_grows "$dir/fd.log" 18 "reassociate_group_check mutant"
  pass "restoring the process substitution in reassociate_group_check makes its fd case fail"
}

# --- case 4: fm-copy-sweep.sh check ------------------------------------------------------------------------------

# sweep_fd_log <bin-dir> <dir> <n> <log>: the real `fm-copy-sweep.sh check` over n records; a `date` shim, which
# the check runs once per record while it reads them, logs its own open-fd count. FM_CHECK_TIMEOUT is raised so a loaded
# host cannot cut the scan short (check keeps clear of the watcher's timeout), which would hide records from the count.
sweep_fd_log() {
  local bindir=$1 dir=$2 n=$3 log=$4 i
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/bin" "$dir/treehouse" "$dir/hhome" "$dir/dirs"
  i=1
  while [ "$i" -le "$n" ]; do
    mkdir -p "$dir/dirs/d$i"
    printf 'worktree=%s\nkind=ship\nproject=%s\n' "$dir/dirs/d$i" "$dir/dirs" > "$dir/home/state/t$(printf '%04d' "$i").meta"
    i=$((i + 1))
  done
  cat > "$dir/bin/date" <<'SH'
#!/usr/bin/env bash
fds=(/dev/fd/*)
echo "${#fds[@]}" >> "$FM_FD_LOG"
exec /bin/date "$@"
SH
  chmod +x "$dir/bin/date"
  : > "$log"
  env HOME="$dir/hhome" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_DATA_OVERRIDE="$dir/home/data" FM_CONFIG_OVERRIDE="$dir/home/config" FM_COPY_SWEEP_TREEHOUSE_ROOT="$dir/treehouse" \
    FM_FD_LOG="$log" PATH="$dir/bin:$PATH" FM_CHECK_TIMEOUT=3600 \
    /bin/bash "$bindir/fm-copy-sweep.sh" check > "$dir/out.txt" 2>&1 < /dev/null
  echo "$?" > "$log.rc"
}

test_copy_sweep_check_keeps_the_fd_count_flat() {
  local n dir
  for n in 10 300; do
    dir="$TMP_ROOT/sweep-$n"
    sweep_fd_log "$SCAN_BIN" "$dir" "$n" "$dir/fd.log"
    [ "$(cat "$dir/fd.log.rc")" = 0 ] || fail "copy-sweep check N=$n: exit $(cat "$dir/fd.log.rc"): $(tail -3 "$dir/out.txt")"
    assert_fd_flat "$dir/fd.log" "$n" "copy-sweep check N=$n"
  done
  pass "fm-copy-sweep.sh check holds no pipe fd past a record for 10 and 300 records"
}

test_mutant_copy_sweep_with_a_process_substitution_grows_the_fd_count() {
  local dir="$TMP_ROOT/sweep-mutant"
  make_mutant_bin "$dir/m" sweep
  if ! bash_leaks_procsub_fd; then
    pass "fm-copy-sweep.sh mutant built and parsed ($BASH_VERSION closes loop process-substitution pipes without the Bash 3.2 leak)"
    return 0
  fi
  sweep_fd_log "$dir/m/bin" "$dir" 40 "$dir/fd.log"
  assert_fd_grows "$dir/fd.log" 40 "copy-sweep mutant"
  pass "restoring the process substitution in fm-copy-sweep.sh makes its fd case fail"
}

# --- teardown cases ---------------------------------------------------------------------------------------------------

test_teardown_scan_keeps_the_fd_count_flat_for_10_records() {
  local case_dir
  case_dir=$(make_scan_case scan-10 10)
  add_fd_git_shim "$case_dir"
  run_scan_teardown "$case_dir" "$SCAN_BIN" ${FM_RECORD_SCAN_STOP_AFTER:+FM_FDCASE_STOP_AFTER=$FM_RECORD_SCAN_STOP_AFTER}
  expect_code 0 "$(cat "$case_dir/rc")" "teardown N=10: $(tail -3 "$case_dir/out")"
  assert_fd_flat "$case_dir/fd.log" 9 "teardown scan N=10"
  assert_absent "$case_dir/state/task-x1.meta" "teardown N=10 left the task record"
  pass "the teardown copy-clearance scan holds no pipe fd past a record for 10 records"
}

test_teardown_scan_keeps_the_fd_count_flat_for_300_records_and_ends_like_10() {
  local c10 c300 rc300
  c10=$(make_scan_case scan-end-10 10)
  c300=$(make_scan_case scan-end-300 300)
  add_fd_git_shim "$c10"
  add_fd_git_shim "$c300"
  run_scan_teardown "$c10" "$SCAN_BIN"
  run_scan_teardown "$c300" "$SCAN_BIN" ${FM_RECORD_SCAN_STOP_AFTER:+FM_FDCASE_STOP_AFTER=$FM_RECORD_SCAN_STOP_AFTER}
  rc300=$(cat "$c300/rc")
  assert_fd_flat "$c300/fd.log" 299 "teardown scan N=300"
  expect_code 0 "$rc300" "teardown N=300: $(tail -3 "$c300/out")"
  [ "$(cat "$c10/rc")" = "$rc300" ] || fail "N=10 and N=300 ended with different statuses"
  assert_absent "$c300/state/task-x1.meta" "teardown N=300 left the task record"
  assert_absent "$c10/state/task-x1.meta" "teardown N=10 left the task record"
  [ "$(normalize_out "$c10" "$c10/out" | sort | uniq)" = "$(normalize_out "$c300" "$c300/out" | sort | uniq)" ] \
    || fail "N=300 printed something N=10 did not: $(diff <(normalize_out "$c10" "$c10/out" | sort -u) <(normalize_out "$c300" "$c300/out" | sort -u) | head -5)"
  pass "a teardown over 300 records ends like one over 10 and its scan holds no pipe fd past a record"
}

test_mutant_teardown_with_the_old_per_record_reads_grows_the_fd_count() {
  local case_dir
  case_dir=$(make_scan_case scan-mutant 40)
  add_fd_git_shim "$case_dir"
  make_mutant_bin "$case_dir/m" teardown
  if ! bash_leaks_procsub_fd; then
    pass "teardown scan mutant built and parsed ($BASH_VERSION closes loop process-substitution pipes without the Bash 3.2 leak)"
    return 0
  fi
  run_scan_teardown "$case_dir" "$case_dir/m/bin"
  assert_fd_grows "$case_dir/fd.log" 39 "teardown mutant"
  pass "restoring the old per-record reads (process substitution and command substitution) in the teardown scan makes its fd case fail"
}

# --- case 5: a refusal by a record after the 256th ----------------------------------------------------------------------

# add_claimant <case-dir> <field>: a last record (after every filler) whose <field> names the task's own pool slot, as
# the three kinds of custody the scan refuses: another home's worktree=, home=, prior_worktree=.
add_claimant() {
  local case_dir=$1 field=$2 wt
  wt=$(sed -n 's/^worktree=//p' "$case_dir/state/task-x1.meta")
  case "$field" in
    worktree) printf 'window=x:y\nendpoint_task_id=zz-claimant\nkind=secondmate\nmode=local-only\nproject=%s\nworktree=%s\n' "$case_dir/project" "$wt" ;;
    home) printf 'window=x:y\nendpoint_task_id=zz-claimant\nkind=ship\nmode=no-mistakes\nproject=%s\nhome=%s\n' "$case_dir/project" "$wt" ;;
    prior_worktree) printf 'window=x:y\nendpoint_task_id=zz-claimant\nkind=ship\nmode=no-mistakes\nproject=%s\nprior_worktree=%s\n' "$case_dir/project" "$wt" ;;
  esac > "$case_dir/h3/state/zz-claimant.meta"
}

test_a_refusing_record_after_the_256th_refuses_like_one_in_a_small_fixture() {
  local field small big
  for field in worktree home prior_worktree; do
    small=$(make_scan_case "refuse-small-$field" 12)
    big=$(make_scan_case "refuse-big-$field" 300)
    add_claimant "$small" "$field"
    add_claimant "$big" "$field"
    run_scan_teardown "$small" "$SCAN_BIN"
    run_scan_teardown "$big" "$SCAN_BIN"
    expect_code 1 "$(cat "$small/rc")" "refusal $field small fixture"
    expect_code 1 "$(cat "$big/rc")" "refusal $field N=300 fixture"
    assert_grep "REFUSED: task task-x1's cleanup target " "$big/out" "refusal $field N=300 gave no REFUSED line"
    assert_grep "is also task zz-claimant's recorded $field " "$big/out" "refusal $field N=300 named the wrong record or field"
    [ "$(normalize_out "$small" "$small/out" | grep -a '^REFUSED')" = "$(normalize_out "$big" "$big/out" | grep -a '^REFUSED')" ] \
      || fail "refusal $field: the N=300 REFUSED text differs from the small fixture's"
    assert_present "$small/state/task-x1.meta" "refusal $field changed the small fixture"
    assert_present "$big/state/task-x1.meta" "refusal $field removed the N=300 task record"
  done
  pass "a record after the 256th that names the slot refuses, with the small fixture's text and status, for worktree=, home= and prior_worktree="
}

# --- case 6: the next fork after a full table -------------------------------------------------------------------------
#
# Live record (data/fm-landing-firstmate-pr408/teardown-spin-2, read only): a teardown of the old code held 252 leaked
# pipes; the child it forked spun (pid 64050); a SIGKILL ended that child, and within two minutes the parent forked
# the next child, which spun the same way (pid 21987). One dead child does not cure the parent: its table stays full,
# so every later fork meets the wall. The scan body of the old code forked at many statements per record, so there was
# always a next site. The fix leaves nothing in the table, so no later fork can meet a wall.
# These cases run the real teardown with a soft limit of 64 open files (FM_SCAN_NOFILE), a table that fills at once
# after 60 or so records. At the real wall (fd 256) the old code faults in a fork and spins, which no case may leave
# running; at the limit of 64 the same full table breaks its pipe, redirect and read calls, and the old code loops in
# the scan. Both are the same cause: a table the scan filled. run_scan_teardown_guarded stops a run that fills the table
# and then does not finish, 30 seconds after the fill, with SIGTERM to the run's own process group.

test_teardown_with_a_full_file_table_ends_like_one_with_room() {
  local roomy tight
  roomy=$(make_scan_case nofile-roomy 80)
  tight=$(make_scan_case nofile-tight 80)
  add_fd_git_shim "$roomy"
  add_fd_git_shim "$tight"
  run_scan_teardown "$roomy" "$SCAN_BIN"
  run_scan_teardown_guarded "$tight" "$SCAN_BIN" 64
  assert_fd_flat "$tight/fd.log" 79 "teardown with 64 open files, N=80"
  expect_code 0 "$(cat "$roomy/rc")" "teardown N=80 with room: $(tail -3 "$roomy/out")"
  expect_code 0 "$(cat "$tight/rc")" "teardown N=80 with 64 open files: $(tail -3 "$tight/out")"
  assert_absent "$tight/state/task-x1.meta" "teardown with 64 open files left the task record"
  [ "$(normalize_out "$roomy" "$roomy/out" | sort -u)" = "$(normalize_out "$tight" "$tight/out" | sort -u)" ] \
    || fail "a full file table changed what the teardown printed: $(diff <(normalize_out "$roomy" "$roomy/out" | sort -u) <(normalize_out "$tight" "$tight/out" | sort -u) | head -5)"
  pass "a teardown with only 64 open files over 80 records ends like one with room: same status, same output, record removed"
}

test_mutant_teardown_with_the_old_per_record_reads_cannot_finish_with_a_full_file_table() {
  local case_dir
  case_dir=$(make_scan_case nofile-mutant 80)
  add_fd_git_shim "$case_dir"
  make_mutant_bin "$case_dir/m" teardown
  if ! bash_leaks_procsub_fd; then
    pass "teardown full-table mutant built and parsed ($BASH_VERSION closes loop process-substitution pipes without the Bash 3.2 leak)"
    return 0
  fi
  run_scan_teardown_guarded "$case_dir" "$case_dir/m/bin" 64
  fd_log_report "$case_dir/fd.log"
  [ "$FD_MAX" -ge 60 ] || fail "the mutant never filled the table (max $FD_MAX of 64): the case cannot see the leak"
  assert_present "$case_dir/guard-fired" "the mutant finished with a full file table (the guard never had to stop it); the case cannot see the leak"
  [ "$(cat "$case_dir/rc")" != 0 ] || fail "the mutant finished with a full file table; the case cannot see the leak"
  assert_present "$case_dir/state/task-x1.meta" "the mutant removed the record while its table was full"
  pass "restoring the old per-record reads makes the full-table case fail: the table fills (max $FD_MAX) and the teardown is still running 30 seconds later (stopped by the harness)"
}

# other_record_rc_with_limit <bin-dir> <dir> <limit|default>: the status of fm_task_copy_other_record over <dir>'s six records when
# reading each record takes 20 s on the clock the walk reads (the record reader is wrapped to advance SECONDS; nothing waits).
# <limit> is what the caller hands the library in FM_TASK_COPY_SCAN_LIMIT_SECS; "default" leaves it as the library sets it.
other_record_rc_with_limit() {
  local bindir=$1 dir=$2 limit=$3
  (
    export FM_HOME="$dir/home"
    mkdir -p "$FM_HOME/state" "$FM_HOME/data"
    . "$bindir/fm-backend.sh"; . "$bindir/fm-wake-lib.sh"; . "$bindir/fm-secondmate-registry-lib.sh"; . "$bindir/fm-task-copy-lib.sh"
    eval "orig_$(declare -f fm_task_copy_record_paths_to)"
    # shellcheck disable=SC2329 # called by the library code under test
    fm_task_copy_record_paths_to() { SECONDS=$((SECONDS + 20)); orig_fm_task_copy_record_paths_to "$@"; }
    [ "$limit" = default ] || FM_TASK_COPY_SCAN_LIMIT_SECS=$limit
    rc=0
    fm_task_copy_other_record "$dir/state/self.meta" "$dir/state" "$dir/target" >/dev/null 2>&1 || rc=$?
    echo "$rc"
  )
}

# The caller, not the library, says a lock is held: a walk the caller hands no limit (a caller without the lock) stays unbounded,
# and one it hands a limit stops with status 3 before the record it is on when the clock has passed it.
test_other_record_walk_takes_its_limit_from_the_caller() {
  local dir="$TMP_ROOT/other-limit" want limit
  make_records_state "$dir" 6
  for limit in default 0 abc 3600; do
    [ "$(other_record_rc_with_limit "$SCAN_BIN" "$dir" "$limit")" = 1 ] || fail "other_record limit '$limit': the walk without a usable limit must run to its end (1)"
  done
  for limit in 2 08; do
    want=$(other_record_rc_with_limit "$SCAN_BIN" "$dir" "$limit")
    [ "$want" = 3 ] || fail "other_record limit '$limit': a walk past its limit must stop with status 3, got $want"
  done
  pass "fm_task_copy_other_record is unbounded unless its caller hands it a limit, and stops with status 3 past one (08 is read as decimal)"
}

CASES=(
  test_record_reader_matches_the_old_reader_byte_for_byte
  test_canonical_dir_without_a_fork_matches_the_forking_one_and_keeps_the_directory
  test_other_record_scan_keeps_the_fd_count_flat
  test_mutant_other_record_with_a_process_substitution_grows_the_fd_count
  test_reassociate_group_check_keeps_the_fd_count_flat
  test_mutant_group_check_with_a_process_substitution_grows_the_fd_count
  test_copy_sweep_check_keeps_the_fd_count_flat
  test_mutant_copy_sweep_with_a_process_substitution_grows_the_fd_count
  test_teardown_scan_keeps_the_fd_count_flat_for_10_records
  test_mutant_teardown_with_the_old_per_record_reads_grows_the_fd_count
  test_a_refusing_record_after_the_256th_refuses_like_one_in_a_small_fixture
  test_teardown_scan_keeps_the_fd_count_flat_for_300_records_and_ends_like_10
  test_teardown_with_a_full_file_table_ends_like_one_with_room
  test_mutant_teardown_with_the_old_per_record_reads_cannot_finish_with_a_full_file_table
  test_other_record_walk_takes_its_limit_from_the_caller
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-record-paths-scan tests passed"
