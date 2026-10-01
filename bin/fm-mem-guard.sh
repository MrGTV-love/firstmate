#!/usr/bin/env bash
# fm-mem-guard.sh - Local Linux/macOS memory-pressure diagnostic; see engine --help.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/fm-mem-guard.py" "$@"
