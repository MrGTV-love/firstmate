#!/usr/bin/env bash
# tests/fm-omp-jev-pipeline.test.sh - opt-in native omp Jev timing boundaries.
# Exercises public extension handlers; real host evidence is refreshed separately
# in the isolated bake-off, without spending tokens in the portable suite.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
if [ -n "${FM_JEV_ADVISER_DIR:-}" ]; then
  command -v bun >/dev/null 2>&1 || { echo "bun is required to test the adviser's TypeScript package" >&2; exit 1; }
  bun test "$ROOT/tests/assets/omp-jev-pipeline.test.mjs"
  exit 0
fi
command -v node >/dev/null 2>&1 || { skip "node is required for omp Jev behavior regressions"; exit 0; }
node --test "$ROOT/tests/assets/omp-jev-pipeline.test.mjs"
