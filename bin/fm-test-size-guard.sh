#!/usr/bin/env bash
# fm-test-size-guard.sh - enforce the 1,000-line single-file cap and burn-down
# ratchet on tests/*.test.sh.
#
# Usage:
#   bin/fm-test-size-guard.sh [--root <dir>]
#
# Policy:
# - Every new tests/*.test.sh file must be at most 1000 lines.
# - Existing grandfathered files listed in docs/guards/test-file-line-budget.tsv
#   ("<path>\t<max_lines>") may stay at or below their recorded ceiling, and may
#   never grow past it.
# - Entries in the budget file whose test file no longer exists or has already
#   shrunk to <= 1000 lines are reported as stale so the ratchet burns down.
#
# Recorded user decisions:
# - A ceiling is a baseline, not a moving limit: a grandfathered file that
#   shrinks but stays above 1000 lines keeps its ceiling, so concurrent PRs do
#   not conflict on the budget file.
# - Files produced by splitting a grandfathered monolith stay grandfathered at
#   their split ceilings, and sourced tests/*-helpers.sh files are not
#   *.test.sh files, so the cap does not apply to them.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
MAX_LINES=1000

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { printf 'fm-test-size-guard: --root requires a path\n' >&2; exit 2; }
      ROOT=$2
      shift 2
      ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'fm-test-size-guard: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

BUDGET_PATH="$ROOT/docs/guards/test-file-line-budget.tsv"

if [ ! -f "$BUDGET_PATH" ]; then
  printf 'fm-test-size-guard: budget file not found: %s\n' "$BUDGET_PATH" >&2
  exit 1
fi

exec python3 - "$ROOT" "$MAX_LINES" "$BUDGET_PATH" <<'PY'
import glob
import os
import sys

root = sys.argv[1]
max_lines = int(sys.argv[2])
budget_path = sys.argv[3]

budget = {}
errors = []
with open(budget_path, encoding='utf-8') as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) != 2 or not parts[1].isdigit():
            errors.append(f'{budget_path}:{lineno}: malformed budget row (expected "<path>\\t<int>")')
            continue
        path, cap = parts[0], int(parts[1])
        if path in budget:
            errors.append(f'{budget_path}:{lineno}: duplicate budget entry for {path}')
            continue
        if cap <= max_lines:
            errors.append(f'{budget_path}:{lineno}: unnecessary budget entry for {path} ({cap} <= {max_lines})')
            continue
        budget[path] = cap

files = sorted(glob.glob(os.path.join(root, 'tests', '*.test.sh')))
seen = set()
grandfathered = 0
for full in files:
    rel = os.path.relpath(full, root).replace(os.sep, '/')
    seen.add(rel)
    with open(full, 'rb') as fh:
        count = sum(1 for _ in fh)
    if rel in budget:
        cap = budget[rel]
        if count > cap:
            errors.append(
                f'{rel}: {count} lines exceeds grandfathered ceiling {cap} '
                f'(split the file instead of growing legacy debt)'
            )
        elif count <= max_lines:
            errors.append(
                f'{rel}: {count} lines is now <= {max_lines}; remove stale entry from {os.path.relpath(budget_path, root)}'
            )
        else:
            grandfathered += 1
    elif count > max_lines:
        errors.append(
            f'{rel}: {count} lines exceeds the {max_lines}-line cap for new test files '
            f'(split into focused suites <= {max_lines} lines)'
        )

for rel in sorted(budget):
    if rel not in seen:
        errors.append(f'{rel}: budget entry refers to a missing test file; remove it from {os.path.relpath(budget_path, root)}')

if errors:
    for e in errors:
        print(f'fm-test-size-guard: {e}', file=sys.stderr)
    sys.exit(1)

print(f'FM_TEST_SIZE_GUARD ok total={len(files)} max_lines={max_lines} grandfathered={grandfathered}')
PY
