#!/usr/bin/env bash
# Observer behavior with labeled quota/process inputs: ancestry, PID reuse,
# payload privacy, unavailable counters, exact retention, and private lifecycle.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 -I "$ROOT/tests/fm-github-accounting.behavior.test.py" || fail "GitHub accounting observer behavior"
pass "GitHub accounting observer behavior"
