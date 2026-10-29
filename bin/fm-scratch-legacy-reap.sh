#!/usr/bin/env bash
# fm-scratch-legacy-reap.sh - one-time removal of scratch entries that commands made before bin/fm-scratch-lib.sh.
#
# Usage:
#   fm-scratch-legacy-reap.sh [--tmpdir DIR] [--min-age-days N] [--apply]
#   fm-scratch-legacy-reap.sh --help
#
# Before the scratch library, these commands made `<prefix>.XXXXXX` directly in
# the shared temp dir and nothing ever removed an entry whose command was killed:
# fm-timeout-status, fm-bash-timeout-command, fm-fleet-tasks, fm-gh-rest,
# fm-remote-reply-ingest, fm-contributions, fm-session-start-stage,
# fm-lavish-poll and fm-test-reap. Those entries name no owner, so ownership
# cannot prove them dead. This script proves it differently: an entry goes only
# when ALL of these hold.
#   1. its name is exactly <one of the prefixes above>.<6 letters or digits>
#      (so a fm-fleet-tasks directory that carries an owner token, a scratch
#      container, and every other fm-* entry are never candidates);
#   2. it is not a symlink and this user owns it;
#   3. nothing under it was modified for --min-age-days days (default 2; the
#      longest bounded command is 6 hours), judged by the newest file in it;
#   4. no process has it open or as its working directory, read from lsof.
# lsof must run and answer for every batch; if it cannot, nothing is removed.
#
# Without --apply it only prints the entries it would remove. With --apply it
# removes them and prints one `removed` line each. It never touches anything
# outside DIR (default: $TMPDIR, else /tmp) and never recurses into a candidate
# that is a symlink.
#
# Regression coverage: tests/fm-scratch-legacy-reap.test.sh.
set -u

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

TMPDIR_ARG=${TMPDIR:-/tmp}
MIN_AGE_DAYS=2
APPLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tmpdir) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; TMPDIR_ARG=$2; shift ;;
    --min-age-days) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MIN_AGE_DAYS=$2; shift ;;
    --apply) APPLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
case "$MIN_AGE_DAYS" in ''|*[!0-9]*) echo "fm-scratch-legacy-reap: --min-age-days needs a whole number" >&2; exit 2 ;; esac
[ -d "$TMPDIR_ARG" ] || { echo "fm-scratch-legacy-reap: no such directory: $TMPDIR_ARG" >&2; exit 2; }
DIR=$(CDPATH='' cd -P -- "$TMPDIR_ARG" && pwd -P) || exit 2
command -v lsof >/dev/null 2>&1 || { echo "fm-scratch-legacy-reap: lsof is required to prove an entry is not in use" >&2; exit 1; }

PREFIXES="fm-timeout-status fm-bash-timeout-command fm-fleet-tasks fm-gh-rest fm-remote-reply-ingest fm-contributions fm-session-start-stage fm-lavish-poll fm-test-reap"

candidates=()
for prefix in $PREFIXES; do
  for entry in "$DIR/$prefix".??????; do
    [ -e "$entry" ] && [ ! -L "$entry" ] && [ -O "$entry" ] || continue
    suffix=${entry##*/}
    suffix=${suffix#"$prefix".}
    case "$suffix" in *[!A-Za-z0-9]*) continue ;; esac
    candidates+=("$entry")
  done
done
[ "${#candidates[@]}" -gt 0 ] || exit 0

# Old enough: no file at or under the entry is newer than the cutoff. One find
# over all candidates, so the cost is the entries' own size.
aged=()
while IFS= read -r -d '' entry; do
  aged+=("$entry")
done < <(
  for entry in "${candidates[@]}"; do
    if [ -z "$(find "$entry" -mtime -"$MIN_AGE_DAYS" -print -quit 2>/dev/null)" ]; then
      printf '%s\0' "$entry"
    fi
  done
)
[ "${#aged[@]}" -gt 0 ] || exit 0

# Not in use: ask lsof about each batch of entries. lsof exits 1 with no output
# when nothing has them open; any other failure means we cannot tell.
in_use=$'\n'
batch=()
flush_batch() {
  local out status line
  [ "${#batch[@]}" -gt 0 ] || return 0
  out=$(lsof -F n -- "${batch[@]}" 2>/dev/null)
  status=$?
  case "$status" in
    0|1) ;;
    *) echo "fm-scratch-legacy-reap: lsof failed (status $status); removing nothing" >&2; exit 1 ;;
  esac
  while IFS= read -r line; do
    case "$line" in n*) in_use+="${line#n}"$'\n' ;; esac
  done <<EOF
$out
EOF
  batch=()
}
for entry in "${aged[@]}"; do
  batch+=("$entry")
  [ "${#batch[@]}" -lt 100 ] || flush_batch
done
flush_batch

for entry in "${aged[@]}"; do
  case "$in_use" in *$'\n'"$entry"$'\n'*) continue ;; esac
  if [ "$APPLY" -eq 1 ]; then
    rm -rf -- "$entry" && printf 'removed %s\n' "$entry"
  else
    printf 'would remove %s\n' "$entry"
  fi
done
