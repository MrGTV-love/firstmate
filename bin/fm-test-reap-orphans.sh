#!/usr/bin/env bash
# fm-test-reap-orphans.sh - stop processes that an ended lab or test run left behind.
#
# Usage:
#   fm-test-reap-orphans.sh [--tmpdir DIR]...
#   fm-test-reap-orphans.sh --owner-pid PID --root DIR...
#   fm-test-reap-orphans.sh --help
#
# Why it exists: a test fixture's stubs (a lock holder, a polling fake, a
# watcher armed against a temporary home) do not stop when the test that made
# them dies hard. Removing the fixture directory cannot stop them either, so they
# kept running for hours at ten to a hundred forks a second each (observed
# 2026-10-08: seven CPU-minutes in one lock-holder stub alone).
#
# Ownership proof. This header owns ended lab/test process eligibility.
# Test roots carry .fm-test-fixture; scratch lab homes carry .fm-lab-home; live
# labs carry .fm-live-lab. Markers must be regular, non-symlink files owned by
# this user and name the owning process's pid and birth identity. Lab markers
# retain their v1 token and append owner_pid and owner_identity; a token without
# that provenance does not authorize reaping. A live owner's unreadable identity
# leaves its root untouched. Lab roots also require inactive runtime evidence:
# recorded launch identities and private tmux servers retain ownership while
# live, and incomplete records or indeterminate probes do not prove termination.
# A scratch home under a live-lab record also requires that parent lab to end.
# A process is reaped only when ALL of these hold:
#   1. its command line or working directory names a marked root or a path below it;
#   2. that root's marker proves the owner: either the owner is dead (its pid is
#      gone or now has a different birth identity) in the default scan, or the
#      owner is the caller (--owner-pid names this process or an ancestor of it
#      and the marker names the same pid and identity) in the owner-exit sweep;
#   3. its parent is init or a recognized init/subreaper, or, in the owner-exit
#      sweep, it is a descendant of the validated owner.
# Its descendants go with it. A command line that merely mentions a path, such as
# a person's `tail -f` in another terminal, has a live shell parent and is never
# touched. A fixture whose marker is gone (already removed) proves nothing and is
# left alone; the sweep therefore runs BEFORE the root is removed.
#
# Root attribution never uses the target's process name, an environment tag, or
# unrelated open files; parent classification is owned by initlike below.
# Environment tags were rejected because macOS hides the environment of Apple
# signed binaries such as /bin/bash and /bin/sleep (measured 2026-10-08: a tag on
# /bin/bash and /bin/sleep was unreadable, on python3 it was readable), and bash
# stubs are exactly what leaks.
#
# This process and every ancestor are never signalled. Each target's birth
# identity and command, including descendants, come from the ownership process
# snapshot and are rechecked before each signal, so a recycled pid is skipped.
# CONT lets stopped targets act on TERM; a survivor of the 2 second grace gets
# KILL only if its identity still matches.
#
# Options:
#   --tmpdir DIR    directory holding lab/test containers to scan (repeatable).
#                   Defaults to $TMPDIR (when set) and /tmp. Scans discover
#                   .fm-test-fixture and .fm-lab-home at any depth inside
#                   immediate fm-* and fmlab.* directories without following
#                   directory symlinks, including parallel workers' wN/tmp roots;
#                   .fm-live-lab is read at immediate fmlab.* roots only.
#                   An unmarked container or sibling is not ownership evidence.
#   --owner-pid PID with --root, the caller's own pid: reap what this owner left
#                   under its own roots. Refused unless PID is this process or
#                   one of its ancestors.
#   --root DIR      a fixture root the owner made (repeatable, needs --owner-pid).
#
# Prints one `reaped` line per process and nothing otherwise.
# Exits 2 on misuse and 1 if scratch allocation or reading the process list fails;
# otherwise exits 0. Runner and fixture cleanup callers treat it as best-effort.
#
# Regression coverage: tests/fm-test-reap-orphans.test.sh exercises real-process
# eligibility, cwd-attributed Go test binaries, lab runtime lifetimes, nested
# discovery, owner-exit cleanup, and killed-test startup recovery. Its fixture
# checks and cleanup signals use identities captured after exec and before the
# owner exits. tests/fm-orphan-safety.test.sh covers snapshot PID reuse, identity
# changes between signals, and unknown live owners.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
GRACE_TICKS=20

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

OWNER_PID=
TMPDIRS=()
ROOTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tmpdir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TMPDIRS+=("$2"); shift ;;
    --owner-pid) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OWNER_PID=$2; shift ;;
    --root) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; ROOTS+=("$2"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$OWNER_PID" ] || [ "${#ROOTS[@]}" -gt 0 ]; then
  case "$OWNER_PID" in ''|*[!0-9]*) echo "fm-test-reap-orphans: --owner-pid and --root go together" >&2; exit 2 ;; esac
  [ "${#ROOTS[@]}" -gt 0 ] && [ "${#TMPDIRS[@]}" -eq 0 ] \
    || { echo "fm-test-reap-orphans: --owner-pid and --root go together and exclude --tmpdir" >&2; exit 2; }
fi

if [ "${#TMPDIRS[@]}" -eq 0 ]; then
  [ -z "${TMPDIR:-}" ] || TMPDIRS+=("$TMPDIR")
  TMPDIRS+=(/tmp)
fi

identity_ready() {
  command -v fm_pid_identity >/dev/null 2>&1 && return 0
  FM_STATE_OVERRIDE=${TMPDIRS[0]:-/tmp}
  [ -d "$FM_STATE_OVERRIDE" ] || FM_STATE_OVERRIDE=/tmp
  export FM_STATE_OVERRIDE
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

SELF=$$

# owner_is_ancestor: 0 when OWNER_PID is this process or one of its ancestors.
# Only then is a marker the caller made also proof that the caller is reaping.
owner_is_ancestor() {
  local p=$SELF hops=0
  while [ "$hops" -lt 64 ] && [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
    [ "$p" != "$OWNER_PID" ] || return 0
    if [ "$p" = "$SELF" ]; then p=$PPID; else p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); fi
    hops=$((hops + 1))
  done
  return 1
}
if [ -n "$OWNER_PID" ] && ! owner_is_ancestor; then
  echo "fm-test-reap-orphans: --owner-pid $OWNER_PID is not this process or an ancestor" >&2
  exit 2
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-reap.XXXXXX" 2>/dev/null) || WORK=$(mktemp -d /tmp/fm-test-reap.XXXXXX) || exit 1
trap 'rm -rf "$WORK"' EXIT

marker_owner() {
  local marker=$1 token
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || return 1
  case "$marker" in
    */.fm-test-fixture)
      MARKER_PID=$(sed -n '1p' "$marker") || return 1
      MARKER_IDENTITY=$(sed -n '2,$p' "$marker") || return 1
      ;;
    */.fm-lab-home|*/.fm-live-lab)
      token=$(sed -n '1p' "$marker") || return 1
      case "$marker:$token" in
        */.fm-lab-home:"fm-lab-home v1"|*/.fm-live-lab:"fm-live-lab v1") ;;
        *) return 1 ;;
      esac
      MARKER_PID=$(sed -n 's/^owner_pid=//p' "$marker") || return 1
      MARKER_IDENTITY=$(sed -n 's/^owner_identity=//p' "$marker") || return 1
      ;;
    *) return 1 ;;
  esac
  case "$MARKER_PID" in ''|*[!0-9]*|0|1) return 1 ;; esac
  [ -n "$MARKER_IDENTITY" ]
}

marker_owner_dead() {
  local current
  marker_owner "$1" || return 1
  kill -0 "$MARKER_PID" 2>/dev/null || return 0
  identity_ready
  current=$(fm_pid_identity "$MARKER_PID" 2>/dev/null) || return 1
  [ "$current" != "$MARKER_IDENTITY" ]
}

tmux_dir_inactive() {
  local dir=$1 socket probe
  [ -d "$dir" ] || return 1
  for socket in "$dir"/tmux-*/*; do
    [ -e "$socket" ] || [ -L "$socket" ] || continue
    probe=$(tmux -S "$socket" list-sessions 2>&1 >/dev/null) && return 1
    case "$probe" in *"no server running"*) ;; *) return 1 ;; esac
  done
}

lab_inactive() {
  local root=$1 marker=$1/.fm-live-lab line pid= start current dir
  if [ -f "$marker" ]; then
    while IFS= read -r line; do
      case "$line" in
        launch_pid=*) pid=${line#*=} ;;
        launch_start=*)
          start=${line#*=}
          [ -n "$start" ] || return 1
          case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
          if kill -0 "$pid" 2>/dev/null; then
            current=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
            current=$(printf '%s\n' "$current" | awk '{$1=$1; print}')
            [ -n "$current" ] && [ "$current" != "$start" ] || return 1
          fi
          pid=
          ;;
        tmux_dir=*)
          dir=${line#*=}
          [ -n "$dir" ] || return 1
          tmux_dir_inactive "$dir" || return 1
          ;;
      esac
    done < "$marker"
    [ -z "$pid" ] || return 1
  fi
  if [ -f "$root/state/.fm-lab-tmux-dir" ]; then
    dir=$(cat "$root/state/.fm-lab-tmux-dir") || return 1
    [ -n "$dir" ] || return 1
    tmux_dir_inactive "$dir" || return 1
  fi
  if [ -f "$root/../.fm-live-lab" ]; then
    marker_owner_dead "$root/../.fm-live-lab" || return 1
    lab_inactive "$root/.." || return 1
  fi
}

physical_dir() { CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P; }

# Roots proven by their markers. One `variant<TAB>root` line each, because the
# same directory is spelled /tmp/... or /private/tmp/... by different callers.
: > "$WORK/roots"
add_root() {  # <physical-root>
  local root=$1
  printf '%s\t%s\n' "$root" "$root" >> "$WORK/roots"
  case "$root" in
    /private/tmp/*|/private/var/*) printf '%s\t%s\n' "${root#/private}" "$root" >> "$WORK/roots" ;;
    /tmp/*|/var/*) printf '%s\t%s\n' "/private$root" "$root" >> "$WORK/roots" ;;
  esac
}

if [ -n "$OWNER_PID" ]; then
  for root in "${ROOTS[@]}"; do
    root=$(physical_dir "$root") || continue
    for marker in "$root/.fm-test-fixture" "$root/.fm-lab-home" "$root/.fm-live-lab"; do
      marker_owner "$marker" || continue
      [ "$MARKER_PID" = "$OWNER_PID" ] || continue
      identity_ready
      [ "$(fm_pid_identity "$OWNER_PID" 2>/dev/null)" = "$MARKER_IDENTITY" ] || continue
      case "$marker" in */.fm-test-fixture) ;; *) lab_inactive "$root" || continue ;; esac
      add_root "$root"
      break
    done
  done
else
  for dir in "${TMPDIRS[@]}"; do
    dir=$(physical_dir "$dir") || continue
    while IFS= read -r -d '' marker; do
      [ -f "$marker" ] || continue
      marker_owner_dead "$marker" || continue
      root=$(dirname "$marker")
      case "$marker" in */.fm-test-fixture) ;; *) lab_inactive "$root" || continue ;; esac
      add_root "$root"
    done < <(
      printf '%s\0' "$dir"/fmlab.*/.fm-live-lab
      for container in "$dir"/fm-* "$dir"/fmlab.*; do
        [ -d "$container" ] && [ ! -L "$container" ] || continue
        find "$container" -type f \( -name .fm-lab-home -o -name .fm-test-fixture \) -print0 2>/dev/null
      done
    )
  done
fi
[ -s "$WORK/roots" ] || exit 0

COLUMNS=10000 LC_ALL=C ps -U "$(id -u)" -ww -o pid= -o ppid= -o lstart= -o command= > "$WORK/ps" 2>/dev/null \
  || { echo "fm-test-reap-orphans: cannot read the process list" >&2; exit 1; }

: > "$WORK/cwds"
if [ -d /proc/self ]; then
  while read -r pid rest; do
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
    printf '%s\t%s\n' "$pid" "$cwd" >> "$WORK/cwds"
  done < "$WORK/ps"
elif command -v lsof >/dev/null 2>&1; then
  if lsof -a -u "$(id -u)" -d cwd -Fpn > "$WORK/lsof" 2>/dev/null; then
    pid=
    while IFS= read -r line; do
      case "$line" in
        p*) pid=${line#p} ;;
        n*) [ -z "$pid" ] || printf '%s\t%s\n' "$pid" "${line#n}" >> "$WORK/cwds" ;;
      esac
    done < "$WORK/lsof"
  fi
fi

# One pass over the snapshots picks root-attributed processes with no live
# parent, plus everything below them, minus this process and
# its ancestors. The first output line lists those ancestors.
awk -v self="$SELF" -v owner="${OWNER_PID:-}" -v rootsfile="$WORK/roots" -v cwdsfile="$WORK/cwds" '
function names(cmd, v,   off, rest, pos, before, after) {
  off = 0
  rest = cmd
  while ((pos = index(rest, v)) > 0) {
    before = (off + pos > 1) ? substr(cmd, off + pos - 1, 1) : ""
    after = substr(cmd, off + pos + length(v), 1)
    if (before !~ /[A-Za-z0-9._\/-]/ && after !~ /[A-Za-z0-9._-]/) return 1
    off += pos
    rest = substr(cmd, off + 1)
  }
  return 0
}
function initlike(pid,   word, n, parts) {
  if (pid == 1) return 1
  if (!(pid in cmd)) return 0
  word = cmd[pid]
  sub(/ .*/, "", word)
  n = split(word, parts, "/")
  word = parts[n]
  return (word == "launchd" || word == "systemd" || word == "init" || word == "tini" || word == "docker-init" || word == "dumb-init")
}
function descends(pid, anc,   hops) {
  for (hops = 0; hops < 128 && (pid in parent) && pid > 1; hops++) {
    pid = parent[pid]
    if (pid == anc) return 1
  }
  return 0
}
BEGIN {
  nroots = 0
  while ((getline line < rootsfile) > 0) {
    split(line, f, "\t")
    nroots++
    variant[nroots] = f[1]
    canon[nroots] = f[2]
  }
  while ((getline line < cwdsfile) > 0) {
    split(line, f, "\t")
    cwd[f[1]] = f[2]
  }
}
{
  line = $0
  sub(/^ +/, "", line)
  if (match(line, /^[0-9]+ +[0-9]+ +/) == 0) next
  head = substr(line, 1, RLENGTH)
  split(head, h, " ")
  pid = h[1] + 0
  parent[pid] = h[2] + 0
  identity[pid] = substr(line, RLENGTH + 1)
  cmd[pid] = identity[pid]
  if (!sub(/^[^ ]+ +[^ ]+ +[0-9]+ +[0-9:]+ +[0-9]+ +/, "", cmd[pid])) next
  order[++count] = pid
}
END {
  protected[self] = 1
  anc = ""
  p = self
  for (hops = 0; (p in parent) && p > 1 && hops < 128; hops++) {
    p = parent[p]
    protected[p] = 1
    anc = anc " " p
  }
  print "ANCESTORS" anc
  for (i = 1; i <= count; i++) {
    pid = order[i]
    if (pid in protected) continue
    for (r = 1; r <= nroots; r++) {
      if (!names(cmd[pid], variant[r]) && cwd[pid] != variant[r] && index(cwd[pid], variant[r] "/") != 1) continue
      if (initlike(parent[pid]) || (owner != "" && descends(pid, owner + 0))) {
        target[pid] = canon[r]
      }
      break
    }
  }
  do {
    changed = 0
    for (i = 1; i <= count; i++) {
      pid = order[i]
      if ((pid in target) || (pid in protected)) continue
      if (parent[pid] in target) {
        target[pid] = target[parent[pid]]
        changed = 1
      }
    }
  } while (changed)
  for (i = 1; i <= count; i++) {
    pid = order[i]
    if (pid in target) printf "%d\t%s\t%s\t%s\n", pid, target[pid], identity[pid], cmd[pid]
  }
}
' "$WORK/ps" > "$WORK/targets"

target_identity() {
  local out
  out=$(COLUMNS=10000 LC_ALL=C ps -p "$1" -ww -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}
PIDS=()
IDENTITIES=()
ROOTS_OF=()
CMDS=()
while IFS=$'\t' read -r pid root identity command; do
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  current=$(target_identity "$pid") || continue
  [ "$current" = "$identity" ] || continue
  PIDS+=("$pid")
  IDENTITIES+=("$identity")
  ROOTS_OF+=("$root")
  CMDS+=("$command")
done < <(sed '1d' "$WORK/targets")
[ "${#PIDS[@]}" -gt 0 ] || exit 0

still_same() {  # <index>
  local current
  current=$(target_identity "${PIDS[$1]}") || return 1
  [ "$current" = "${IDENTITIES[$1]}" ]
}

i=0
while [ "$i" -lt "${#PIDS[@]}" ]; do
  short=${CMDS[$i]}
  [ "${#short}" -le 100 ] || short="${short:0:100}..."
  printf 'reaped pid=%s root=%s cmd=%s\n' "${PIDS[$i]}" "${ROOTS_OF[$i]}" "$short"
  i=$((i + 1))
done

# A stopped process cannot act on TERM until it continues.
for i in "${!PIDS[@]}"; do
  still_same "$i" || continue
  kill -CONT "${PIDS[$i]}" 2>/dev/null || true
  still_same "$i" || continue
  kill -TERM "${PIDS[$i]}" 2>/dev/null || true
done
tick=0
while [ "$tick" -lt "$GRACE_TICKS" ]; do
  alive=0
  for i in "${!PIDS[@]}"; do
    ! still_same "$i" || alive=1
  done
  [ "$alive" -eq 1 ] || exit 0
  sleep 0.1
  tick=$((tick + 1))
done
for i in "${!PIDS[@]}"; do
  still_same "$i" || continue
  kill -KILL "${PIDS[$i]}" 2>/dev/null || true
done
exit 0
