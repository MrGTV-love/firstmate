#!/usr/bin/env bash
# Usage: fm-inv-check.sh <worktree> <base-commit>
set -u
W=$1 B=$2
cd "$W" || exit 1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-prmerge-inv.XXXXXX")
mkdir -p "$T/base/tests" "$T/new/tests"
git show "$B:tests/lib.sh" > "$T/base/tests/lib.sh"
git show "$B:tests/fm-pr-merge.test.sh" > "$T/base/tests/orig.test.sh"
grep '^test_[a-z0-9_]*$' "$T/base/tests/orig.test.sh" > "$T/base-order.txt"
grep -v '^test_[a-z0-9_]*$' "$T/base/tests/orig.test.sh" > "$T/base/tests/defs.sh"
cat > "$T/base/dump.sh" <<'EOF'
. "$(dirname "$0")/tests/defs.sh"
while read -r f; do declare -f "$f"; done < "$1"
EOF
bash "$T/base/dump.sh" "$T/base-order.txt" > "$T/base-bodies.txt" 2>"$T/base-dump.err"
echo "base dump rc=$?"
cat > "$T/new/tests/fm-pr-merge-helpers.sh" <<EOF
. "$W/tests/fm-pr-merge-helpers.sh"
pr_merge_run() { local t; for t in "\${pr_merge_test_cases[@]}"; do declare -F "\$t" >/dev/null || { echo "UNDEFINED \$t"; continue; }; echo "\$t"; declare -f "\$t" >> "\$FM_DUMP"; done; }
EOF
: > "$T/new-bodies.txt"; : > "$T/new-order.txt"
for g in fm-pr-merge fm-pr-merge-forges fm-pr-merge-checks; do
  cp "tests/$g.test.sh" "$T/new/tests/"
  FM_DUMP="$T/new-bodies.txt" bash "$T/new/tests/$g.test.sh" > "$T/$g.order.txt"
  echo "$g registered=$(wc -l < "$T/$g.order.txt" | tr -d ' ') undefined=$(grep -c UNDEFINED "$T/$g.order.txt")"
  cat "$T/$g.order.txt" >> "$T/new-order.txt"
done
echo "base cases=$(wc -l < "$T/base-order.txt" | tr -d ' ') union cases=$(wc -l < "$T/new-order.txt" | tr -d ' ') duplicates=$(sort "$T/new-order.txt" | uniq -d | wc -l | tr -d ' ')"
if diff "$T/base-order.txt" "$T/new-order.txt" >/dev/null; then echo "ORDER: identical to base"; else echo "ORDER DIFF:"; diff "$T/base-order.txt" "$T/new-order.txt"; fi
if diff "$T/base-bodies.txt" "$T/new-bodies.txt" >/dev/null; then echo "BODIES: identical to base"; else echo "BODY DIFF:"; diff "$T/base-bodies.txt" "$T/new-bodies.txt" | head -60; fi
head -3 "$T/base-dump.err"
rm -rf "$T"
