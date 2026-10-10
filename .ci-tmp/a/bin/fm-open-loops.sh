#!/usr/bin/env bash
# fm-open-loops.sh - reconcile assigned work against live delivery evidence.
# Usage: fm-open-loops.sh [--json] [--heartbeat]
# Default: read-only scan of this home, TOON output. --json prints fm-open-loops.v1.
# --heartbeat also atomically publishes state/open-loops.json. The watcher runs it as a
# detached helper and surfaces overdue rows as a durable check wake; there is no daemon.
# Sources: the fleet snapshot (backlog and ordinary tasks), status logs, task worktrees,
# the no-mistakes run store, and discovered GitHub pull requests.
# docs/configuration.md owns config/open-loops.json, row fields, age limits, coverage
# degradation, and supported proof limits. Use --json for each row's limit_seconds.
# Examples: fm-open-loops.sh; fm-open-loops.sh --json; fm-open-loops.sh --heartbeat
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) [ "$#" -eq 1 ] && { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0; } ;;
esac
command -v python3 >/dev/null 2>&1 || { printf 'error: Python 3 is required to reconcile open work\n'; exit 1; }
exec python3 "$SCRIPT_DIR/fm_open_loops.py" "$@"
