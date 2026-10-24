#!/usr/bin/env bash
# Publish Firstmate's explicit deletion paths for an already-running task.
# Usage: FM_HOME=<home> bin/fm-jev-deletions.sh <task-id> --replace [path...]
# Reads state/<task-id>.meta under the explicit home (honoring FM_STATE_OVERRIDE).
# Paths are literal worktree-relative file names supplied directly by Firstmate.
# Publication replaces, never extends, the list; --replace with no paths revokes
# all allowances. Never reads the worker-writable task brief on this live route.
# Example: FM_HOME=<home> bin/fm-jev-deletions.sh task --replace bin/obsolete.sh
# Example: FM_HOME=<home> bin/fm-jev-deletions.sh task --replace
# The task metadata lock serializes publication with spawn and other writers.
# Source this script to use fm_jev_deletions_runtime while already holding that
# lock: spawn's prepare operation writes the list and returns its digest for
# the initial metadata transaction, without acquiring the same lock twice.
# docs/configuration.md "Jev guard" owns the consistency-only trust contract.

fm_jev_deletions_runtime() {
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 1
  if command -v bun >/dev/null 2>&1; then
    bun "$script_dir/fm-jev-deletions.ts" "$@"
  elif command -v node >/dev/null 2>&1; then
    node --experimental-strip-types --no-warnings "$script_dir/fm-jev-deletions.ts" "$@"
  else
    echo "error: deletion publication requires bun or node with type stripping" >&2
    return 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -eu
  case "${1:-}" in
    -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  esac
  [ "$#" -ge 2 ] && [ "${2:-}" = --replace ] && [ -n "${FM_HOME:-}" ] || {
    echo 'usage: FM_HOME=<home> bin/fm-jev-deletions.sh <task-id> --replace [path...]' >&2
    exit 1
  }
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*|-*) echo 'error: invalid task ID' >&2; exit 1 ;; esac
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  TASK=$1
  shift 2
  [ -f "$STATE/$TASK.meta" ] || { echo 'error: missing task metadata' >&2; exit 1; }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$STATE/$TASK.meta")
  fm_lock_acquire_wait "$lock"
  trap 'fm_lock_release "$lock"' EXIT
  fm_jev_deletions_runtime publish "$STATE" "$TASK" --replace "$@"
fi
