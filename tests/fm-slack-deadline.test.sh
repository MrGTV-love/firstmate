#!/usr/bin/env bash
# Slow scheduling must not exhaust a cumulative Slack request budget.
# Fake HTTP responses and a local socketpair exercise the real shell check.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi not found\n'; exit 0; }
python3 "$ROOT/tests/fm_slack_deadline_test.py"
