#!/usr/bin/env bash
# fm-dispatch-capacity.sh - inspect the capacity of a concrete worker route.
# Usage: fm-dispatch-capacity.sh --harness <name> --model <id> [--cwd <path>] [--json]
# Reports usable, exhausted, or unknown; OMP Codex requires a resolvable --cwd.
# This reads quota only. Saved resets are reported, never spent or counted as
# current headroom. Account identities and credentials are not printed.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-dispatch-capacity-lib.sh
. "$SCRIPT_DIR/fm-dispatch-capacity-lib.sh"
harness='' model='' cwd='' json=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness|--model|--cwd)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'error: %s needs a value\n' "$1"; exit 2; }
      case "$1" in --harness) harness=$2 ;; --model) model=$2 ;; --cwd) cwd=$2 ;; esac
      shift 2 ;;
    --json) json=1; shift ;;
    --help|-h) printf 'Usage: fm-dispatch-capacity.sh --harness <name> --model <id> [--cwd <path>] [--json]\n'; exit 0 ;;
    *) printf 'error: unknown argument %s; valid flags: --harness --model --cwd --json --help\n' "$1"; exit 2 ;;
  esac
done
[ -n "$harness" ] && [ -n "$model" ] || { printf 'error: --harness and --model are required\n'; exit 2; }
evidence=$(fm_dispatch_capacity "$harness" "$model" '' '' "$cwd")
if [ "$json" = 1 ]; then printf '%s\n' "$evidence"
else
  jq -r '"capacity: \(.status)",
    (if .accounts then "accounts[\(.accounts | length)]{status,remaining,savedResets}:" else empty end),
    (.accounts[]? | "  \(.status),\(.remaining // "unknown"),\(.savedResets)"),
    (if .reason then "reason: \(.reason)" else empty end)' <<<"$evidence"
fi
