#!/usr/bin/env bash
# fm-scratch-reaper.sh - remove aged scratch directories that nothing uses, after archiving their small logs.
#
# Usage:
#   fm-scratch-reaper.sh              Dry run: print one line per decision and change nothing.
#   fm-scratch-reaper.sh --apply      Archive small logs, then remove each directory that passes every check.
#   fm-scratch-reaper.sh --scheduled  What the watcher runs (bin/fm-watch.sh scratch_reaper_tick); implies --apply.
#   fm-scratch-reaper.sh --help       Print this header.
#
# Harm: killed or keeping test, build and agent runs leak scratch directories into /private/tmp
#   and ~/tmp; nothing removed them, so the data volume filled and tests died with
#   "No space left on device". The harm of the cure is deleting work somebody still
#   uses, so every check below fails closed: any doubt keeps the directory.
#
# Allow-list: config/scratch-reaper (docs/configuration.md "Scratch reaper" owns the file
#   format, the built-in defaults, the age key and the paths). Only a direct child
#   directory of a listed root whose name matches that root's glob is a candidate.
#   Plain files, whatever their name, are never candidates.
#
# Before any check, a directory whose name holds a control character, such as a newline, is
#   kept as `control-character-name`, with each control character printed as `?`.
# A candidate is removed only when ALL of these hold, checked in this order:
#   1. it is not a symlink (a symlink is kept as `symlink` and never followed);
#   2. its realpath is exactly <realpath of its root>/<its name> (else `outside root`);
#   3. it is not protected: not under ~/.treehouse, ~/firstmate, /Volumes, this home, or
#      this home's data or state folder (else `protected`);
#   4. no recorded task owns it (else `task-record`): it equals the `tasktmp=` value of a
#      state/*.meta in this home or in a local secondmate home that data/secondmates.md lists
#      (read-only), or it is named fm-<id> or fm-<id>+... for a state/<id>.meta in one of
#      those homes. A remote secondmate record is not read, because its home is on another
#      host. Another home's own task temp roots are not protected;
#   5. nothing in its whole tree is newer than the age (default 24 hours): the newest
#      mtime of any entry decides, never the folder's own mtime (else `young`);
#   6. no .git entry and no .fm-slot-owner entry exists anywhere in its tree, so a git
#      worktree, a pool slot, a treehouse worktree and a nested repository are all kept
#      (else `git`);
#   7. no process has an open file or a current directory inside it (else `open handle`).
#      ONE lsof snapshot (open file names and process cwds) is taken per run, lazily,
#      when the first candidate reaches this check, then matched by path prefix against
#      the realpath and its aliases (the root as written, and the /private-stripped
#      form macOS lsof prints for /tmp and /var). The snapshot is bounded by
#      FM_SCRATCH_REAPER_LSOF_SECS (default 120). A failed, timed-out or empty
#      snapshot keeps every candidate that needs it as `lsof failed` and the run exits 3.
#      Honest limit: the snapshot is the only handle check. A process that starts after
#      it and opens a file or enters a candidate before that candidate is removed is not
#      seen, because the contract takes one snapshot per run. The window runs from the
#      snapshot to the removal of that one directory, and the directory has been
#      untouched for the whole age first, so only a process that reuses a day-old unused
#      scratch directory inside that window can be hit. A write by such a process is not
#      re-checked either;
#   8. every small log in it was archived (else `archive failed`).
#
# Archive: before removal, each regular file named *.log *.txt *.out *.err *.json *.md of
#   at most 1 MiB is copied, with its relative path, to
#   <data>/scratch-reaper-archive/<UTC date>/<directory name>/ and compared byte for
#   byte. A directory is archived up to 20 MiB; a larger log, or one past that total, is
#   not copied, the directory is still removed when every other check passes, and its
#   decision line says how many logs were skipped. Paths are NUL-delimited from the
#   directory listing to the copy, so a name holding a newline or a leading dash is
#   archived like any other. A file whose size cannot be read, a copy that fails, and
#   a copy that differs from its source are all an archive failure: the directory is
#   kept, even when an earlier file was already copied. The archive finishes before
#   the removal starts, and the removal is reached only when it succeeded. The archive
#   and the log below have no size cap.
#
# Decisions: one line each, printed and (with --apply) appended to <state>/scratch-reaper.log:
#   <UTC time> removed <path> bytes=<n> archived=<n> skipped_logs=<n>
#   <UTC time> kept <path> reason=<reason>[ ...]
#   <UTC time> gone <path>                (it vanished before the check or the removal)
#   <UTC time> would-remove <path> bytes=<n>      (dry run only)
#   A failed or partial removal is `kept ... reason=remove failed`, never `removed`.
#   A dry run prints only: it writes no log line, no archive and no marker.
#
# Removal: the script has exactly four production rm calls, and only the first removes a
#   candidate:
#     1. reap_remove: `rm -rf --` of <realpath root>/<name> for a root in the allow-list,
#        re-checked to be a real directory, not a symlink, and its own realpath, immediately
#        before the call;
#     2. cleanup_work: `rm -rf --` of the reaper's own temp folder, only when its name is
#        <TMPDIR>/.scratch-reaper.XXXXXX and it is not a symlink;
#     3. take_snapshot: `rm -f --` of the lsof snapshot file inside that temp folder;
#     4. scheduled_epilogue: `rm -f --` of <state>/.scratch-reaper-alarmed.
#   Calls 2 to 4 touch the reaper's own work files, never a scratch candidate and never a
#   path under an allow-listed root. No other path is removed. Whether a path is under an
#   allow-listed root is decided on its realpath, never on the name as written.
#
# Roots are refused, and the run exits 2 before touching anything, when a root is not an
#   absolute or ~/ path, is not a directory, or is, contains, or lies under a protected path.
#
# Scheduled run (--scheduled), owned here so the window has one owner:
#   - a secondmate home exits 0 silently (the primary home reaps this machine's scratch);
#   - the window marker <state>/.scratch-reaper-next holds the epoch the next run is
#     allowed; a run inside the window exits 0 without work; the marker is written before
#     the run so a crash cannot loop; the window is FM_SCRATCH_REAPER_WINDOW seconds
#     (default 1800);
#   - one run at a time, single-flight on <state>/.scratch-reaper.lock; a busy lock logs
#     `skipped lock busy` and exits 0;
#   - any failure (nonzero exit, lsof failed) appends `error rc=<n>` to the log and never
#     reaches the caller's cycle: the watcher starts this detached;
#   - after the run, when the free space of the roots' volume is below 20 GiB and the run
#     removed nothing, it appends ONE wake `check: scratch-reaper low-disk ...` (key
#     scratch-reaper-low-disk) and records <state>/.scratch-reaper-alarmed; it raises
#     the wake again only after 6 hours, and clears the marker when space recovers or a
#     run frees bytes.
#
# Exit: 0 ok, 1 an internal failure (no log, no temp folder), 2 usage or invalid config or
#   root, 3 lsof failed (nothing that needed it was removed).
#
# Test seams (need FM_TEST_SEAM=1): FM_SCRATCH_REAPER_NOW=<epoch> replaces the clock.
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, FM_DATA_OVERRIDE as elsewhere;
#   HOME names ~; TMPDIR holds the reaper's temp folder.
# Regression coverage: tests/fm-scratch-reaper.test.sh and tests/fm-watch-scratch-reaper.test.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

APPLY=0
SCHEDULED=0
case "${1:-}" in
  '') [ "$#" -eq 0 ] ;;
  --apply) [ "$#" -eq 1 ] && APPLY=1 ;;
  --scheduled) [ "$#" -eq 1 ] && APPLY=1 && SCHEDULED=1 ;;
  -h|--help) usage; exit 0 ;;
  *) false ;;
esac || { usage >&2; exit 2; }

CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG_FILE="$CONFIG_DIR/scratch-reaper"
LOG_FILE="$STATE_DIR/scratch-reaper.log"
ARCHIVE_ROOT="$DATA_DIR/scratch-reaper-archive"
# measured: value=1800 date=2026-11-19 host=Mac-Studio margin=4.2x (the captain's cadence of one run per 30 minutes; one dry-run pass over 13,840 matching entries took 428 s at load average 75)
WINDOW_SECS="${FM_SCRATCH_REAPER_WINDOW:-1800}"
# measured: value=1800 date=2026-11-19 host=Mac-Studio margin=4.2x (the same cadence as the default above)
case "$WINDOW_SECS" in ''|*[!0-9]*|0) WINDOW_SECS=1800 ;; *) WINDOW_SECS=$((10#$WINDOW_SECS)) ;; esac
# measured: value=120 date=2026-11-19 host=Mac-Studio margin=120x (one lsof -n -P -w -F n snapshot took 1 s; the same call without -n -P took 28 s at load average 75)
LSOF_SECS="${FM_SCRATCH_REAPER_LSOF_SECS:-120}"
# measured: value=120 date=2026-11-19 host=Mac-Studio margin=120x (the same bound as the default above)
case "$LSOF_SECS" in ''|*[!0-9]*|0) LSOF_SECS=120 ;; *) LSOF_SECS=$((10#$LSOF_SECS)) ;; esac
ALARM_FREE_KIB=$((20 * 1024 * 1024))
# measured: value=21600 date=2026-11-19 host=Mac-Studio margin=1x (a repeat interval, not a bound on any command; it matches the open-work ledger resurface in bin/fm-watch.sh)
ALARM_RESURFACE_SECS=21600
LOG_MAX_BYTES=1048576
LOG_DIR_MAX_BYTES=$((20 * 1048576))
AGE_HOURS=24

# The clock seam is armed only by a test suite: a faked future clock would age young work.
now_epoch() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SCRATCH_REAPER_NOW:-}" ]; then
    printf '%s\n' "$FM_SCRATCH_REAPER_NOW"
  else
    date +%s
  fi
}
NOW=$(now_epoch)
case "$NOW" in ''|*[!0-9]*) echo "fm-scratch-reaper: unusable clock '$NOW'" >&2; exit 1 ;; esac

iso_utc() {  # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown'
}
touch_stamp() {  # <epoch> -> YYYYMMDDhhmm.SS in UTC
  date -u -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -u -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null
}

is_secondmate_home() {
  [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ] \
    || [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]
}

real_dir() {  # <dir> -> its physical path; fails when it is not a directory
  ( cd -P -- "$1" 2>/dev/null && pwd -P )
}

# --- protected paths ----------------------------------------------------------
PROTECTED=()
add_protected() {
  local p
  [ -n "$1" ] || return 0
  p=$(real_dir "$1") || p=$1
  PROTECTED+=("${p%/}")
}
add_protected "${HOME:-/nonexistent}/.treehouse"
add_protected "${HOME:-/nonexistent}/firstmate"
add_protected /Volumes
add_protected "$FM_HOME"
add_protected "$FM_ROOT"
add_protected "$DATA_DIR"
add_protected "$STATE_DIR"

# protected_path <path>: true when the path is, lies under, or contains a protected path.
protected_path() {
  local p=${1%/} q
  [ -n "$p" ] || return 0
  for q in "${PROTECTED[@]}"; do
    case "$p/" in "$q"/*) return 0 ;; esac
    case "$q/" in "$p"/*) return 0 ;; esac
  done
  return 1
}

# --- recorded tasks -----------------------------------------------------------
# A parked worker can sit idle for days with no open handle, so scratch that a recorded task
# still owns is kept. The records come from this home's state folder and from each local
# secondmate home that data/secondmates.md lists; they are only read.
TASK_IDS=()    # <id> of each state/<id>.meta read
TASK_TMPS=()   # each absolute tasktmp= value read, resolved to its real path

collect_task_records() {  # <state folder>
  local f id v d
  for f in "$1"/*.meta; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    id=${f##*/}; id=${id%.meta}
    TASK_IDS+=("$id")
    v=$(grep '^tasktmp=' "$f" 2>/dev/null | tail -1 | cut -d= -f2-)
    case "$v" in /*) ;; *) continue ;; esac
    d=$(real_dir "$(dirname -- "$v")") || continue
    TASK_TMPS+=("$d/$(basename -- "$v")")
  done
}

collect_secondmate_records() {
  local reg="$DATA_DIR/secondmates.md" line home n=0
  [ -e "$reg" ] || [ -L "$reg" ] || return 0
  [ -f "$reg" ] && [ ! -L "$reg" ] || { echo "fm-scratch-reaper: $reg is not a regular file" >&2; exit 2; }
  # shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in "- "*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || { echo "fm-scratch-reaper: $reg:$n: malformed secondmate registry entry" >&2; exit 2; }
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
    home=$SECONDMATE_REGISTRY_HOME
    case "$home" in /*) ;; *) echo "fm-scratch-reaper: $reg:$n: secondmate home is not absolute" >&2; exit 2 ;; esac
    if [ -d "$home/state" ]; then collect_task_records "$home/state"; fi
  done < "$reg"
}

task_record_kept() {  # <real dir> <name>: 0 when a recorded task owns the directory
  local real=$1 name=$2 t id
  for t in ${TASK_TMPS[@]+"${TASK_TMPS[@]}"}; do [ "$t" = "$real" ] && return 0; done
  for id in ${TASK_IDS[@]+"${TASK_IDS[@]}"}; do
    case "$name" in "fm-$id"|"fm-$id+"*) return 0 ;; esac
  done
  return 1
}

# --- config -------------------------------------------------------------------
ROOT_REAL=()   # physical root paths
ROOT_ASIS=()   # the root as written after ~ expansion
ROOT_GLOBS=()  # space separated globs per root (globs hold no spaces)

default_config() {
  local g
  for g in 'fm-*' 'omp-*' 'fm-fm-*' 'fm-omp-*' 'fm-joined-generation.*' 'fm-bash-*' \
    'fm-pre-generic.*' 'fm-prekey-matcher.*' 'fm-ttsr-pending.*'; do
    CFG_LINES+=("/private/tmp $g")
  done
  for g in 'backpass-*' 'fm-spawn-tree-*' 'dsh-*' 'nm-e2e-bin*' 'nm-timeout-bin*'; do
    # shellcheck disable=SC2088  # a literal ~/ the config format expands itself
    CFG_LINES+=("~/tmp $g")
  done
}

load_config() {
  local line a b extra n=0 had_roots=0
  CFG_LINES=()
  if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] \
      || { echo "fm-scratch-reaper: $CONFIG_FILE is not a regular file" >&2; return 2; }
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      line=${line%%#*}
      read -r a b extra <<< "$line"
      [ -n "$a" ] || continue
      if [ "$a" = age_hours ]; then
        case "$b" in ''|*[!0-9]*|0) echo "fm-scratch-reaper: $CONFIG_FILE:$n: age_hours needs a positive integer" >&2; return 2 ;; esac
        [ -z "$extra" ] || { echo "fm-scratch-reaper: $CONFIG_FILE:$n: extra text after age_hours" >&2; return 2; }
        AGE_HOURS=$((10#$b))
        continue
      fi
      [ -n "$b" ] && [ -z "$extra" ] || { echo "fm-scratch-reaper: $CONFIG_FILE:$n: want '<root> <glob>'" >&2; return 2; }
      # shellcheck disable=SC2088  # a literal ~/ in the config file
      case "$a" in /*|'~/'*) ;; *) echo "fm-scratch-reaper: $CONFIG_FILE:$n: root '$a' is not absolute or ~/" >&2; return 2 ;; esac
      had_roots=1
      CFG_LINES+=("$a $b")
    done < "$CONFIG_FILE"
  fi
  [ "$had_roots" -eq 1 ] || { CFG_LINES=(); default_config; }
  return 0
}

register_root() {  # <root as written> <glob>
  local asis=$1 glob=$2 real i
  # shellcheck disable=SC2088  # a literal ~/ in the config file
  case "$asis" in '~/'*) asis="${HOME:-/nonexistent}/${asis#\~/}" ;; esac
  asis=${asis%/}
  if [ ! -d "$asis" ] || [ -L "$asis" ]; then
    # A missing default root (no ~/tmp, no /private/tmp on Linux) is simply nothing to do.
    [ ! -e "$asis" ] && [ ! -L "$asis" ] && return 0
    echo "fm-scratch-reaper: root $asis is a symlink or not a directory" >&2
    return 2
  fi
  real=$(real_dir "$asis") || { echo "fm-scratch-reaper: cannot resolve root $asis" >&2; return 2; }
  if [ "$real" = / ] || protected_path "$real"; then
    echo "fm-scratch-reaper: root $asis ($real) is, contains or lies under a protected path" >&2
    return 2
  fi
  i=0
  while [ "$i" -lt "${#ROOT_REAL[@]}" ]; do
    if [ "${ROOT_REAL[$i]}" = "$real" ] && [ "${ROOT_ASIS[$i]}" = "$asis" ]; then
      ROOT_GLOBS[i]="${ROOT_GLOBS[$i]} $glob"
      return 0
    fi
    i=$((i + 1))
  done
  ROOT_REAL+=("$real"); ROOT_ASIS+=("$asis"); ROOT_GLOBS+=("$glob")
}

# --- temp work folder ---------------------------------------------------------
WORK=
make_work() {
  local base=${TMPDIR:-/tmp}
  WORK=$(mktemp -d "${base%/}/.scratch-reaper.XXXXXX") || return 1
}
# shellcheck disable=SC2329  # runs from on_exit, which the EXIT trap names
cleanup_work() {
  case "$WORK" in
    */.scratch-reaper.??????) [ -d "$WORK" ] && [ ! -L "$WORK" ] && rm -rf -- "$WORK" ;;
  esac
  WORK=
}

# --- decision log -------------------------------------------------------------
KEPT=0 REMOVED=0 BYTES=0 LSOF_FAILED=0
decide() {  # <verb> <path> <detail>
  local line
  line="$(iso_utc "$NOW") $1 $2${3:+ $3}"
  printf '%s\n' "$line"
  if [ "$APPLY" -eq 1 ]; then
    printf '%s\n' "$line" >> "$LOG_FILE" || echo "fm-scratch-reaper: cannot append $LOG_FILE" >&2
  fi
}
keep() { KEPT=$((KEPT + 1)); decide kept "$1" "reason=$2"; }  # <path> <reason>

# --- open-handle snapshot -----------------------------------------------------
SNAPSHOT_STATE=untaken   # untaken | ok | failed
BUSY_FILE=
take_snapshot() {
  local raw="$WORK/lsof.raw" alias_map="$WORK/aliases" i real asis stripped rc=0
  BUSY_FILE="$WORK/busy"
  command -v lsof >/dev/null 2>&1 || { SNAPSHOT_STATE=failed; return 1; }
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # -n -P skip name lookups (about 30 times faster); -F n prints one name per line.
  fm_run_timed "$LSOF_SECS" lsof -n -P -w -F n > "$raw" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$raw" ]; then SNAPSHOT_STATE=failed; return 1; fi
  : > "$alias_map"
  i=0
  while [ "$i" -lt "${#ROOT_REAL[@]}" ]; do
    real=${ROOT_REAL[$i]} asis=${ROOT_ASIS[$i]}
    printf '%s\t%s\n' "$real" "$real" >> "$alias_map"
    printf '%s\t%s\n' "$asis" "$real" >> "$alias_map"
    case "$real" in /private/*) stripped=${real#/private}; printf '%s\t%s\n' "$stripped" "$real" >> "$alias_map" ;; esac
    i=$((i + 1))
  done
  # Each lsof name under an alias of a root yields <real root>/<first component>.
  awk -F '\t' '
    NR == FNR { n++; alias[n] = $1; real[n] = $2; next }
    /^n\// {
      p = substr($0, 2)
      for (k = 1; k <= n; k++) {
        a = alias[k]; la = length(a)
        if (substr(p, 1, la + 1) == a "/") {
          rest = substr(p, la + 2)
          c = index(rest, "/")
          child = (c == 0) ? rest : substr(rest, 1, c - 1)
          if (child != "") print real[k] "/" child
        }
      }
    }' "$alias_map" "$raw" | sort -u > "$BUSY_FILE" || { SNAPSHOT_STATE=failed; return 1; }
  rm -f -- "$raw"
  SNAPSHOT_STATE=ok
}

has_open_handle() {  # <real dir>: 0 = busy, 1 = free, 2 = unknown
  if [ "$SNAPSHOT_STATE" = untaken ]; then take_snapshot || true; fi
  [ "$SNAPSHOT_STATE" = ok ] || return 2
  if grep -qxF -- "$1" "$BUSY_FILE"; then return 0; fi
  return 1
}

# --- archive ------------------------------------------------------------------
ARCH_COUNT=0 ARCH_SKIPPED=0
archive_logs() {  # <real dir> <name>: copy the small logs; 0 only when every eligible log is archived and verified
  local dir=$1 name=$2 list="$WORK/loglist" dest f rel reldir total=0 size
  ARCH_COUNT=0 ARCH_SKIPPED=0
  dest="$ARCHIVE_ROOT/$(date -u -r "$NOW" +%Y-%m-%d 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%d)/$name"
  # NUL-delimited end to end: a name may hold a newline, a space or a leading dash.
  find "$dir" -type f \( -name '*.log' -o -name '*.txt' -o -name '*.out' -o -name '*.err' -o -name '*.json' -o -name '*.md' \) \
    -print0 > "$list" 2>/dev/null || return 1
  while IFS= read -r -d '' f; do
    # A size that cannot be read means the file cannot be judged small or large, so it cannot be
    # archived or skipped: fail closed and keep the directory.
    size=$(wc -c < "$f" 2>/dev/null) || return 1
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$size" -gt "$LOG_MAX_BYTES" ] || [ $((total + size)) -gt "$LOG_DIR_MAX_BYTES" ]; then
      ARCH_SKIPPED=$((ARCH_SKIPPED + 1))
      continue
    fi
    rel=${f#"$dir"/}
    case "$rel" in */*) reldir=${rel%/*} ;; *) reldir= ;; esac
    mkdir -p -- "$dest${reldir:+/$reldir}" || return 1
    cp -p -- "$f" "$dest/$rel" || return 1
    cmp -s -- "$f" "$dest/$rel" || return 1
    total=$((total + size))
    ARCH_COUNT=$((ARCH_COUNT + 1))
  done < "$list"
  return 0
}

# --- removal ------------------------------------------------------------------
# reap_remove <real root> <name>: the only place a candidate is removed.
reap_remove() {
  local root=$1 name=$2 target i ok=0
  case "$name" in ''|*/*|.|..) return 1 ;; esac
  target="$root/$name"
  i=0
  while [ "$i" -lt "${#ROOT_REAL[@]}" ]; do [ "${ROOT_REAL[$i]}" = "$root" ] && ok=1; i=$((i + 1)); done
  [ "$ok" -eq 1 ] || return 1
  [ -d "$target" ] && [ ! -L "$target" ] || return 1
  [ "$(real_dir "$target")" = "$target" ] || return 1
  rm -rf -- "$target"
}

dir_kib() {  # <dir>
  local k
  k=$(du -sk -- "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')
  case "$k" in ''|*[!0-9]*) k=0 ;; esac
  printf '%s\n' "$k"
}

# --- one candidate ------------------------------------------------------------
process_candidate() {  # <real root> <as-written root> <name>
  local root=$1 name=$3 path real kib bytes rc
  case "$name" in *[[:cntrl:]]*) keep "$root/${name//[[:cntrl:]]/?}" control-character-name; return 0 ;; esac
  path="$root/$name"
  if [ -L "$path" ]; then keep "$path" symlink; return 0; fi
  [ -d "$path" ] || { [ -e "$path" ] || decide gone "$path"; return 0; }
  real=$(real_dir "$path") || { decide gone "$path"; return 0; }
  if [ "$real" != "$root/$name" ]; then keep "$path" "outside root"; return 0; fi
  if protected_path "$real"; then keep "$path" protected; return 0; fi
  if task_record_kept "$real" "$name"; then keep "$path" task-record; return 0; fi
  if [ -n "$(find "$real" -newer "$REF" -print -quit 2>/dev/null)" ]; then keep "$path" young; return 0; fi
  if [ -n "$(find "$real" \( -name .git -o -name .fm-slot-owner \) -print -quit 2>/dev/null)" ]; then keep "$path" git; return 0; fi
  has_open_handle "$real"; rc=$?
  case "$rc" in
    0) keep "$path" "open handle"; return 0 ;;
    2) LSOF_FAILED=1; keep "$path" "lsof failed"; return 0 ;;
  esac
  kib=$(dir_kib "$real")
  bytes=$((kib * 1024))
  if [ "$APPLY" -eq 0 ]; then
    # The archive is sized here without writing, so the dry run names what apply would do.
    ARCH_COUNT=0 ARCH_SKIPPED=0
    decide would-remove "$path" "bytes=$bytes"
    return 0
  fi
  if ! archive_logs "$real" "$name"; then keep "$path" "archive failed"; return 0; fi
  if reap_remove "$root" "$name"; then
    REMOVED=$((REMOVED + 1)); BYTES=$((BYTES + bytes))
    decide removed "$path" "bytes=$bytes archived=$ARCH_COUNT skipped_logs=$ARCH_SKIPPED"
  elif [ ! -e "$path" ] && [ ! -L "$path" ]; then
    decide gone "$path"
  else
    keep "$path" "remove failed"
  fi
}

run_pass() {
  local i=0 root asis name globs g match entry tmp="$WORK/children"
  while [ "$i" -lt "${#ROOT_REAL[@]}" ]; do
    root=${ROOT_REAL[$i]} asis=${ROOT_ASIS[$i]} globs=${ROOT_GLOBS[$i]}
    i=$((i + 1))
    find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null | sort -z > "$tmp" || continue
    while IFS= read -r -d '' entry; do
      name=${entry##*/}
      match=0
      for g in $globs; do
        # shellcheck disable=SC2254
        case "$name" in $g) match=1; break ;; esac
      done
      [ "$match" -eq 1 ] || continue
      # A plain file is never a candidate; a symlink is reported, never followed.
      if [ ! -L "$entry" ] && [ ! -d "$entry" ]; then continue; fi
      process_candidate "$root" "$asis" "$name"
    done < "$tmp"
  done
}

# --- scheduled-run helpers ----------------------------------------------------
free_kib_min() {  # smallest free space over the roots' volumes, in KiB; empty when unknown
  local i=0 best='' k
  while [ "$i" -lt "${#ROOT_REAL[@]}" ]; do
    k=$(df -Pk "${ROOT_REAL[$i]}" 2>/dev/null | awk 'NR == 2 { print $4 }')
    case "$k" in ''|*[!0-9]*) ;; *) { [ -z "$best" ] || [ "$k" -lt "$best" ]; } && best=$k ;; esac
    i=$((i + 1))
  done
  printf '%s\n' "$best"
}

log_event() {  # <text>: a scheduled-run event line
  printf '%s %s\n' "$(iso_utc "$NOW")" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

raise_low_disk_alarm() {  # <free KiB>
  local marker="$STATE_DIR/.scratch-reaper-alarmed" last='' payload
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then IFS= read -r last < "$marker" || last=''; fi
  case "$last" in ''|*[!0-9]*) last='' ;; esac
  if [ -n "$last" ] && [ $((NOW - last)) -lt "$ALARM_RESURFACE_SECS" ]; then return 0; fi
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  payload="check: scratch-reaper low-disk: only $(( $1 / 1048576 )) GiB free on the data volume and the scheduled reaper removed nothing. Aged scratch is not the cause, so find what else fills the disk (docs/configuration.md \"Scratch reaper\"). Tell the captain in one short note."
  if fm_wake_append check scratch-reaper-low-disk "$payload"; then
    printf '%s\n' "$NOW" > "$marker"
  else
    log_event "error low-disk wake could not be appended"
  fi
}

scheduled_epilogue() {
  local free
  free=$(free_kib_min)
  if [ -n "$free" ] && [ "$free" -lt "$ALARM_FREE_KIB" ] && [ "$REMOVED" -eq 0 ]; then
    raise_low_disk_alarm "$free"
  else
    rm -f -- "$STATE_DIR/.scratch-reaper-alarmed"
  fi
}

# Every exit path of a scheduled run releases the lock and logs a failure; the temp folder goes too.
# shellcheck disable=SC2329  # named by the EXIT trap below
on_exit() {
  local rc=$?
  trap - EXIT
  [ "$SCHEDULED" -eq 0 ] || { [ "$rc" -eq 0 ] || log_event "error rc=$rc"; fm_lock_release "$LOCK"; }
  cleanup_work
  exit "$rc"
}

# --- main ---------------------------------------------------------------------
if [ "$SCHEDULED" -eq 1 ]; then
  is_secondmate_home && exit 0
  mkdir -p -- "$STATE_DIR" || exit 1
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  NEXT_FILE="$STATE_DIR/.scratch-reaper-next"
  next=''
  if [ -f "$NEXT_FILE" ] && [ ! -L "$NEXT_FILE" ]; then IFS= read -r next < "$NEXT_FILE" || next=''; fi
  case "$next" in ''|*[!0-9]*) next='' ;; esac
  if [ -n "$next" ] && [ "$NOW" -lt "$next" ]; then exit 0; fi
  LOCK="$STATE_DIR/.scratch-reaper.lock"
  if ! fm_lock_try_acquire "$LOCK"; then
    log_event "skipped lock busy"
    exit 0
  fi
  printf '%s\n' $((NOW + WINDOW_SECS)) > "$NEXT_FILE" || true
fi
trap on_exit EXIT

load_config || exit 2
if [ "$APPLY" -eq 1 ]; then
  mkdir -p -- "$STATE_DIR" "$DATA_DIR" || { echo "fm-scratch-reaper: cannot create state or data folder" >&2; exit 1; }
  : >> "$LOG_FILE" || { echo "fm-scratch-reaper: cannot write $LOG_FILE" >&2; exit 1; }
fi
for entry in "${CFG_LINES[@]}"; do
  read -r cfg_root cfg_glob <<< "$entry"
  register_root "$cfg_root" "$cfg_glob" || exit 2
done

make_work || { echo "fm-scratch-reaper: cannot create a temp folder under ${TMPDIR:-/tmp}" >&2; exit 1; }
REF="$WORK/age-ref"
: > "$REF"
cutoff=$((NOW - AGE_HOURS * 3600))
stamp=$(touch_stamp "$cutoff") || { echo "fm-scratch-reaper: cannot format the age cutoff" >&2; exit 1; }
TZ=UTC touch -t "$stamp" "$REF" || { echo "fm-scratch-reaper: cannot set the age reference" >&2; exit 1; }

collect_task_records "$STATE_DIR"
collect_secondmate_records

run_pass

rc=0
[ "$LSOF_FAILED" -eq 0 ] || rc=3
printf 'summary: mode=%s removed=%s freed_bytes=%s kept=%s\n' "$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run)" "$REMOVED" "$BYTES" "$KEPT"
[ "$SCHEDULED" -eq 0 ] || scheduled_epilogue
exit "$rc"
