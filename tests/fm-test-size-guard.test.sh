#!/usr/bin/env bash
# Contract regressions for bin/fm-test-size-guard.sh (1,000-line cap + burn-down ratchet).
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-test-size-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-size-guard)

make_test_file() {  # <path> <line-count>
  local path=$1 n=$2
  mkdir -p "$(dirname "$path")"
  python3 - "$path" "$n" <<'PY'
import sys
with open(sys.argv[1], 'w') as fh:
    fh.write('#!/usr/bin/env bash\n')
    for i in range(int(sys.argv[2]) - 1):
        fh.write(f'# line {i}\n')
PY
}

# 1. Passing pair: new file at exact cap (1000L) and grandfathered file at or below ceiling.
repo="$TMP_ROOT/pass-repo"
make_test_file "$repo/tests/fm-small.test.sh" 1000
make_test_file "$repo/tests/fm-legacy.test.sh" 1450
mkdir -p "$repo/docs/guards"
printf 'tests/fm-legacy.test.sh\t1500\n' > "$repo/docs/guards/test-file-line-budget.tsv"
out=$("$GUARD" --root "$repo" 2>&1) \
  || fail "valid cap and shrinking grandfathered file must pass: $out"
case "$out" in
  *'FM_TEST_SIZE_GUARD ok total=2 max_lines=1000 grandfathered=1'*) ;;
  *) fail "unexpected guard pass output: $out" ;;
esac
pass "exact 1000-line file and shrinking grandfathered file pass"

# 2. Violation: new test file at 1001 lines is refused.
make_test_file "$repo/tests/fm-new-big.test.sh" 1001
rc=0
out=$("$GUARD" --root "$repo" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "new 1001-line test file must be refused"
case "$out" in
  *'tests/fm-new-big.test.sh: 1001 lines exceeds the 1000-line cap'*) ;;
  *) fail "refusal did not explain the new-file cap violation: $out" ;;
esac
rm -f "$repo/tests/fm-new-big.test.sh"
pass "new test file exceeding 1000 lines is refused"

# 3. Violation: grandfathered file growing by 1 line above its ceiling is refused.
make_test_file "$repo/tests/fm-legacy.test.sh" 1501
rc=0
out=$("$GUARD" --root "$repo" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "grandfathered file growing past its ceiling must be refused"
case "$out" in
  *'tests/fm-legacy.test.sh: 1501 lines exceeds grandfathered ceiling 1500'*) ;;
  *) fail "refusal did not name grandfathered ceiling growth: $out" ;;
esac
pass "grandfathered test file growing past its ratchet ceiling is refused"

# 4. Violation: stale budget entry once a file shrinks <= 1000 lines forces ratchet cleanup.
make_test_file "$repo/tests/fm-legacy.test.sh" 950
rc=0
out=$("$GUARD" --root "$repo" 2>&1) || rc=$?
[ "$rc" -ne 0 ] || fail "stale budget entry for file <= 1000 lines must be refused"
case "$out" in
  *'tests/fm-legacy.test.sh: 950 lines is now <= 1000; remove stale entry'*) ;;
  *) fail "refusal did not request removing stale budget entry: $out" ;;
esac
pass "stale budget entry is flagged so the ratchet burns down"

# 5. Live repo passes against its tracked budget.
out=$("$GUARD" --root "$ROOT" 2>&1) \
  || fail "live repo must pass fm-test-size-guard: $out"
pass "live repository satisfies the 1000-line test file ratchet"
