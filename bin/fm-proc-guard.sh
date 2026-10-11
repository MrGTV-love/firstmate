#!/usr/bin/env bash
# fm-proc-guard.sh - Per-user process pile-up detector and census; see engine --help.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/fm-proc-guard.py" "$@"
