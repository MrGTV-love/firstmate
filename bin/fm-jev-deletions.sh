#!/usr/bin/env bash
# Publish the current brief's explicit deletion list for an already-running task.
# Usage: FM_HOME=<home> bin/fm-jev-deletions.sh <task-id>
# Reads data/<task-id>/brief.md and state/<task-id>.meta under the explicit home
# (honoring FM_DATA_OVERRIDE and FM_STATE_OVERRIDE). The brief declares paths in
# one `## Authorized deletions` section containing only a fenced json array of
# literal worktree-relative file names. An absent section publishes an empty
# list, revoking any prior allowance. Publication replaces, never extends, it.
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
  [ "$#" -eq 1 ] && [ -n "${FM_HOME:-}" ] || {
    echo 'usage: FM_HOME=<home> bin/fm-jev-deletions.sh <task-id>' >&2
    exit 1
  }
  case "$1" in ''|*[!A-Za-z0-9._-]*|.*|-*) echo 'error: invalid task ID' >&2; exit 1 ;; esac
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
  DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
  [ -f "$STATE/$1.meta" ] || { echo 'error: missing task metadata' >&2; exit 1; }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  lock=$(fm_meta_lock_path "$STATE/$1.meta")
  fm_lock_acquire_wait "$lock"
  trap 'fm_lock_release "$lock"' EXIT
  fm_jev_deletions_runtime publish "$STATE" "$1" "$DATA/$1/brief.md"
fi
