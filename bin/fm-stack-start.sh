#!/usr/bin/env bash
# fm-stack-start.sh - start a task's Docker, Compose or Supabase stack only while
# the disk holds the free-disk floor.
# Usage: fm-stack-start.sh [--path <dir>] -- <command...>
#   Asks bin/fm-disk-floor-lib.sh whether the volume holding <dir> (default: the
#   current directory) has at least the floor free. Below it, prints the library's
#   one `deferred:` line, does not run the command, and exits 75 (deferred, never a
#   failure). Otherwise it execs <command...> unchanged, so the command's own exit
#   status is this script's. An unreadable df admits with one warning, as every
#   other start does; a malformed config/disk-free-floor exits 2.
#   It knows nothing about Docker and adds no policy beyond the floor.
#   Only a NEW start goes through it; a relaunch, a teardown and every cleanup
#   never do.
# This is an entry point the generated worker brief names (bin/fm-brief.sh rule
# 10), not an enforcement point: a project's own start script can still bypass it.
# docs/configuration.md "Disk free floor" owns the contract.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
path=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      [ "$#" -ge 2 ] || { echo 'fm-stack-start.sh: --path needs a directory' >&2; exit 64; }
      path=$2
      shift 2
      ;;
    --) shift; break ;;
    -h | --help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0
      ;;
    *) break ;;
  esac
done
[ "$#" -gt 0 ] || { echo 'usage: fm-stack-start.sh [--path <dir>] -- <command...>' >&2; exit 64; }
[ -n "$path" ] || path=$PWD
rc=0
"$SCRIPT_DIR/fm-disk-floor-lib.sh" admit stack "$path" "" "${FM_TASK_ID:-}" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
exec "$@"
