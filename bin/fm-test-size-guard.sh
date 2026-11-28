#!/usr/bin/env bash
# fm-test-size-guard.sh - enforce the 1,000-line single-file cap and burn-down
# ratchet on tests/*.test.sh.
#
# Usage:
#   bin/fm-test-size-guard.sh [--root <dir>] [--max-lines <n>] [--budget <tsv>] [--write-budget]
#
# Policy:
# - Every new tests/*.test.sh file must be at most --max-lines (default 1000).
# - Existing grandfathered files listed in docs/guards/test-file-line-budget.tsv
#   ("<path>\t<max_lines>") may stay at or below their recorded ceiling, and may
#   never grow past it.
# - Entries in the budget file whose test file no longer exists or has already
#   shrunk to <= --max-lines are reported as stale so the ratchet burns down.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
MAX_LINES=1000
BUDGET_PATH=
WRITE_BUDGET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { printf 'fm-test-size-guard: --root requires a path\n' >&2; exit 2; }
      ROOT=$2
      shift 2
      ;;
    --max-lines)
      [ "$#" -ge 2 ] || { printf 'fm-test-size-guard: --max-lines requires an integer\n' >&2; exit 2; }
      MAX_LINES=$2
      shift 2
      ;;
    --budget)
      [ "$#" -ge 2 ] || { printf 'fm-test-size-guard: --budget requires a path\n' >&2; exit 2; }
      BUDGET_PATH=$2
      shift 2
      ;;
    --write-budget)
      WRITE_BUDGET=1
      shift
      ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'fm-test-size-guard: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

case "$MAX_LINES" in
  ''|0*|*[!0-9]*)
    printf 'fm-test-size-guard: --max-lines must be a positive integer, got %s\n' "$MAX_LINES" >&2
    exit 2
    ;;
esac

if [ -z "$BUDGET_PATH" ]; then
  BUDGET_PATH="$ROOT/docs/guards/test-file-line-budget.tsv"
fi

if [ "$WRITE_BUDGET" -eq 1 ]; then
  mkdir -p "$(dirname "$BUDGET_PATH")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-test-size-budget.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  python3 - "$ROOT" "$MAX_LINES" "$tmp" <<'PY'
import glob, os, sys
root, max_lines, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = []
for full in sorted(glob.glob(os.path.join(root, 'tests', '*.test.sh'))):
    rel = os.path.relpath(full, root).replace(os.sep, '/')
    with open(full, 'rb') as fh:
        count = sum(1 for _ in fh)
    if count > max_lines:
        rows.append((rel, count))
with open(out_path, 'w', encoding='utf-8') as out:
    out.write(f'# Grandfathered test-file line ceilings (>{max_lines} lines). Burn-down ratchet: files may shrink, never grow.\n')
    for rel, count in sorted(rows):
        out.write(f'{rel}\t{count}\n')
PY
  chmod 644 "$tmp"
  mv -f "$tmp" "$BUDGET_PATH"
  printf 'FM_TEST_SIZE_BUDGET written path=%s max_lines=%s\n' "$BUDGET_PATH" "$MAX_LINES"
  exit 0
fi

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
