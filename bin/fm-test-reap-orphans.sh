#!/usr/bin/env bash
# fm-test-reap-orphans.sh - stop processes that an ended test run left behind.
#
# Usage:
#   fm-test-reap-orphans.sh [--dry-run] [--tmpdir DIR]...
#   fm-test-reap-orphans.sh [--dry-run] --owner-pid PID --root DIR...
#   fm-test-reap-orphans.sh --help
#
# Why it exists: a test fixture's stubs (a lock holder, a polling fake, a
# watcher armed against a temporary home) do not stop when the test that made
# them dies hard. Removing the fixture directory cannot stop them either, so they
# kept running for hours at ten to a hundred forks a second each (observed
# 2026-10-08: seven CPU-minutes in one lock-holder stub alone).
#
# Ownership proof. tests/lib.sh stamps every fixture root it creates with a
# `.fm-test-fixture` marker naming the owning shell's pid and birth identity.
# A process is reaped only when ALL of these hold:
#   1. its command line names a fixture root (the root, or a path below it);
#   2. that root's marker proves the owner: either the owner is dead (its pid is
#      gone or now has a different birth identity) in the default scan, or the
#      owner is the caller (--owner-pid names this process or an ancestor of it
#      and the marker names the same pid) in the owner-exit sweep;
#   3. it has no live parent that could still want it: it is the child of init
#      or a subreaper, or, in the owner-exit sweep, a descendant of the owner.
# Its descendants go with it. A command line that merely mentions a path, such as
# a person's `tail -f` in another terminal, has a live shell parent and is never
# touched. A fixture whose marker is gone (already removed) proves nothing and is
# left alone; the sweep therefore runs BEFORE the root is removed.
#
# Matching never uses a process name, an environment tag, or file descriptors.
# Environment tags were rejected because macOS hides the environment of Apple
# signed binaries such as /bin/bash and /bin/sleep (measured 2026-10-08: a tag on
# /bin/bash and /bin/sleep was unreadable, on python3 it was readable), and bash
# stubs are exactly what leaks.
#
# This process and every ancestor are never signalled. Before each signal the
# target's birth identity is rechecked, so a recycled pid is skipped. TERM goes
# first; a survivor of the 2 second grace gets KILL.
#
# Options:
#   --dry-run       print what would be reaped and signal nothing.
#   --tmpdir DIR    directory holding fixture roots to scan (repeatable). The
#                   default scan covers $TMPDIR (when set) and /tmp.
#   --owner-pid PID with --root, the caller's own pid: reap what this owner left
#                   under its own roots. Refused unless PID is this process or
#                   one of its ancestors.
#   --root DIR      a fixture root the owner made (repeatable, needs --owner-pid).
#
# Prints one `reaped` (or `would reap`) line per process and nothing otherwise.
# Exits 0 unless it was misused or the process list could not be read, so a
# caller can sweep without risking its own outcome.
set -u

SCRIPT_DIR=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
GRACE_TICKS=20

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

DRY_RUN=0
OWNER_PID=
TMPDIRS=()
ROOTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
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

# marker_owner_dead <marker>: 0 when the marker's owner no longer exists.
marker_owner_dead() {
  local marker=$1 owner_pid owner_identity current
  owner_pid=$(sed -n '1p' "$marker" 2>/dev/null) || return 1
  owner_identity=$(sed -n '2,$p' "$marker" 2>/dev/null) || return 1
  case "$owner_pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$owner_identity" ] || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 0
  identity_ready
  current=$(fm_pid_identity "$owner_pid" 2>/dev/null) || return 1
  [ "$current" != "$owner_identity" ]
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
    [ "$(sed -n '1p' "$root/.fm-test-fixture" 2>/dev/null)" = "$OWNER_PID" ] || continue
    add_root "$root"
  done
else
  for dir in "${TMPDIRS[@]}"; do
    dir=$(physical_dir "$dir") || continue
    for marker in "$dir"/fm-*/.fm-test-fixture; do
      [ -f "$marker" ] || continue
      marker_owner_dead "$marker" || continue
      add_root "$(dirname "$marker")"
    done
  done
fi
[ -s "$WORK/roots" ] || exit 0

COLUMNS=10000 LC_ALL=C ps -U "$(id -u)" -ww -o pid= -o ppid= -o lstart= -o command= > "$WORK/ps" 2>/dev/null \
  || { echo "fm-test-reap-orphans: cannot read the process list" >&2; exit 1; }

# One pass over the snapshot picks the targets: processes naming a proven root
# that have no live parent, plus everything below them, minus this process and
# its ancestors. The first output line lists those ancestors.
awk -v self="$SELF" -v owner="${OWNER_PID:-}" -v rootsfile="$WORK/roots" '
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
      if (!names(cmd[pid], variant[r])) continue
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
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'would reap pid=%s root=%s cmd=%s\n' "${PIDS[$i]}" "${ROOTS_OF[$i]}" "$short"
  else
    printf 'reaped pid=%s root=%s cmd=%s\n' "${PIDS[$i]}" "${ROOTS_OF[$i]}" "$short"
  fi
  i=$((i + 1))
done
[ "$DRY_RUN" -eq 0 ] || exit 0

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
