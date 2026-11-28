#!/usr/bin/env bash
# The real-Treehouse case of bin/fm-teardown.sh's release of skipped copies: a skipped-copies row naming any holder but
# this task's own is never returned, with the pool and every return run by the installed treehouse binary.
# The case needs jq and `get --lease`, which makes its two slots, and nothing else from Treehouse; without them the first
# output line is the runner's gate skip naming what is missing, and the script exits 0. The other pool-slot cases live in tests/fm-teardown-pool.test.sh.
# Shared fixtures: tests/fm-teardown-helpers.sh.
# Usage: bash tests/fm-teardown-pool-real-treehouse.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"
fm_test_require_real_treehouse get-lease

# A record row naming any holder but this task's own firstmate-skipped:<task> is never returned, even when the real pool
# holds exactly that holder text (here the text a past spawn used as a sentinel). The REAL treehouse makes the pool and
# runs every return; only the return of the task's own non-pool worktree is a no-op. The row with this task's own holder
# is the positive control: it is returned.
test_a_skipped_row_naming_another_holder_is_never_returned_by_the_real_treehouse() {
  local case_dir real th_root log other own state rc=0
  real=$(command -v treehouse 2>/dev/null || true)
  case_dir=$(make_case skipped-foreign-holder)
  write_meta "$case_dir" no-mistakes ship
  mkdir -p "$case_dir/data/task-x1"
  th_root="$case_dir/th-root"
  log="$case_dir/treehouse.log"
  : > "$log"
  other=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$th_root" "$real" get --lease --lease-holder not-leased-by-this-home 2>/dev/null) || fail "foreign-holder: no real slot"
  own=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$th_root" "$real" get --lease --lease-holder firstmate-skipped:task-x1 2>/dev/null) || fail "foreign-holder: no second real slot"
  other=$(cd "$other" && pwd -P)
  own=$(cd "$own" && pwd -P)
  state="$(dirname "$(dirname "$other")")/treehouse-state.json"
  printf '%s\tpassed over\tnot-leased-by-this-home\t1\n%s\tdirty_tree\tfirstmate-skipped:task-x1\t1\n' "$other" "$own" > "$case_dir/data/task-x1/skipped-copies.tsv"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
[ "\${1:-} \${2:-}" != 'return --force' ] || exit 0
TREEHOUSE_ROOT='$th_root' exec '$real' "\$@"
SH
  chmod +x "$case_dir/fakebin/treehouse"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "foreign-holder: teardown should complete"$'\n'"$(cat "$case_dir/stderr")"
  [ "$(jq -r --arg p "$other" '.worktrees[] | select(.path == $p) | .lease_holder' "$state")" = not-leased-by-this-home ] \
    || fail "foreign-holder: the lease of another holder was released: $(jq -c --arg p "$other" '.worktrees[] | select(.path == $p)' "$state")"
  ! grep -Fq "return $other" "$log" || fail "foreign-holder: a return was run for the row naming another holder"$'\n'"$(cat "$log")"
  grep -Fq "return $own --if-lease-holder firstmate-skipped:task-x1" "$log" || fail "foreign-holder: this task's own skipped copy was not returned"$'\n'"$(cat "$log")"
  [ "$(jq -r --arg p "$own" '.worktrees[] | select(.path == $p) | .lease_holder // "none"' "$state")" = none ] \
    || fail "foreign-holder: this task's own lease is still held"
  grep -Fq "$other" "$case_dir/data/task-x1/skipped-copies.tsv" || fail "foreign-holder: the row of the other holder was not left as it was"
  pass "teardown returns a skipped copy only under the exact holder this task leased it with, never a lookalike holder, with the real treehouse"
}

teardown_test_cases=(
test_a_skipped_row_naming_another_holder_is_never_returned_by_the_real_treehouse
)

fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
