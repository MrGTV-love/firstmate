#!/usr/bin/env bash
# fm-load-report.sh - Record host load and judge it with pipeline agent durations; see engine --help.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/fm-load-report.py" "$@"
