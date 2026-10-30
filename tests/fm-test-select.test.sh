#!/usr/bin/env bash
# Behavior tests for bin/fm-test-select.py, the selector that decides which
# behavior tests a pull request's diff can affect.
#
# Each case builds a small git repository whose tests are real scripts, changes
# it, and feeds the diff to the selector, so the assertions describe what the
# selector decides, not how it is written. The cases are the contract M2 of the
# change-based selection holds: every test a change can affect is selected
# (including a test that never names the changed file), a message or a comment
# is not a dependency, shared test infrastructure and any doubt select the full
# suite (fail closed), and a regression planted in a file no test names is
# caught by the tests the selector picked.
# The fixture scripts below are written verbatim, so their $ are meant literally.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SELECT="$ROOT/bin/fm-test-select.py"
assert_present "$SELECT" "bin/fm-test-select.py is missing"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

WORK=$(fm_test_tmproot fm-test-select)
fm_git_identity

# put <repo> <path> <content>: write a file, creating its directory.
put() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  case "$2" in *.sh) chmod +x "$1/$2" ;; esac
}

commit_all() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# A fixture repository. Thirty padding tests depend on nothing, so one test is
# a small share of the suite and a change reaching a few is never "widely
# shared".
#   bin/fm-a.sh        sources bin/fm-a-lib.sh and prints what it returns
#   bin/fm-b.sh        prints b
#   bin/fm-c.sh        prints a message that mentions bin/fm-b.sh
#   tests/a|b|c.test.sh  run the script of the same letter and check its output
new_repo() {  # <name> -> echoes the repo path
  local repo="$WORK/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  put "$repo" bin/fm-a-lib.sh 'a_lib_fn() { echo lib; }'
  put "$repo" bin/fm-a.sh '#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/fm-a-lib.sh"
a_lib_fn'
  put "$repo" bin/fm-b.sh '#!/usr/bin/env bash
echo b'
  put "$repo" bin/fm-c.sh '#!/usr/bin/env bash
# This comment mentions "$ROOT/bin/fm-a-lib.sh" and is not a dependency.
echo "run bin/fm-b.sh to see more"'
  local letter expect
  for letter in a b c; do
    case "$letter" in a) expect=lib ;; b) expect=b ;; c) expect='to see more' ;; esac
    put "$repo" "tests/$letter.test.sh" '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out=$("$ROOT/bin/fm-'"$letter"'.sh") || exit 1
case "$out" in *"'"$expect"'") ;; *) exit 1 ;; esac'
  done
  local n
  for n in $(seq 1 30); do
    put "$repo" "tests/pad-$n.test.sh" '#!/usr/bin/env bash
exit 0'
  done
  put "$repo" tests/lib.sh '# shared test library'
  put "$repo" bin/fm-test-run.sh '#!/usr/bin/env bash'
  put "$repo" .github/workflows/ci.yml 'name: CI'
  put "$repo" bin/fm-test-select.py '# selector'
  put "$repo" README.md '# fixture'
  commit_all "$repo" base
  printf '%s\n' "$repo"
}

# decide <repo> <base-rev> [extra selector args]: the selector's decision.
decide() {
  local repo=$1 base=$2
  shift 2
  python3 -I "$SELECT" --repo "$repo" --base "$base" --head HEAD "$@"
}

field() {  # <decision> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1
}

picked() {  # <decision>: the selected tests, one per line
  printf '%s\n' "$1" | sed -n 's/^test=//p'
}

# change <repo> <path> <content>: commit one edit and echo the commit before it.
change() {
  local repo=$1 before
  before=$(git -C "$repo" rev-parse HEAD)
  put "$repo" "$2" "$3"
  commit_all "$repo" "edit $2"
  printf '%s\n' "$before"
}

test_a_sourced_library_selects_the_test_that_runs_its_consumer() {
  local repo base out
  repo=$(new_repo sourced)
  base=$(change "$repo" bin/fm-a-lib.sh 'a_lib_fn() { echo lib; } # touched')
  out=$(decide "$repo" "$base")
  assert_equals selected "$(field "$out" mode)" "a library change is a partial selection"
  assert_equals tests/a.test.sh "$(picked "$out")" "only the test that runs bin/fm-a.sh, which sources the library"
  pass "a change to a sourced library selects the test that never names it"
}

test_a_planted_regression_in_an_unnamed_file_is_caught_by_the_selected_tests() {
  local repo base out test failed=0 caught=0 selected_failures=0
  repo=$(new_repo regression)
  base=$(change "$repo" bin/fm-a-lib.sh 'a_lib_fn() { echo broken; }')
  out=$(decide "$repo" "$base")
  for test in "$repo"/tests/*.test.sh; do
    if ! bash "$test" >/dev/null 2>&1; then
      failed=$((failed + 1))
      if picked "$out" | grep -Fxq "tests/$(basename "$test")"; then
        caught=$((caught + 1))
      fi
    fi
  done
  [ "$failed" -ge 1 ] || fail "the planted regression broke no test, so the case proves nothing"
  [ "$caught" -eq "$failed" ] || fail "$((failed - caught)) failing test(s) were not selected: $(picked "$out" | tr '\n' ' ')"
  selected_failures=$caught
  pass "a regression planted in a file no test names fails $selected_failures selected test(s) and no unselected one"
}

test_a_message_that_mentions_a_script_is_not_a_dependency() {
  local repo base out
  repo=$(new_repo message)
  base=$(change "$repo" bin/fm-b.sh '#!/usr/bin/env bash
echo b # touched')
  out=$(decide "$repo" "$base")
  assert_equals tests/b.test.sh "$(picked "$out")" "bin/fm-c.sh only prints bin/fm-b.sh in a message, so its test is unaffected"
  pass "a message that names a script does not make its test depend on it"
}

test_a_comment_that_mentions_a_file_is_not_a_dependency() {
  local repo base out
  repo=$(new_repo comment)
  base=$(change "$repo" bin/fm-a-lib.sh 'a_lib_fn() { echo lib; } # touched')
  out=$(decide "$repo" "$base")
  picked "$out" | grep -Fxq tests/c.test.sh && fail "bin/fm-c.sh mentions the library only in a comment"
  pass "a comment that names a file is not a dependency"
}

test_a_positional_argument_reaches_a_file_only_where_the_code_runs_it() {
  local repo base out
  repo=$(new_repo positional)
  put "$repo" bin/fm-d.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash -c '"'"'. "$1"; show "$2"'"'"' _ "$ROOT/bin/fm-a-lib.sh" "$ROOT/bin/fm-b.sh"'
  put "$repo" tests/d.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/bin/fm-d.sh"'
  commit_all "$repo" add-d
  base=$(change "$repo" bin/fm-a-lib.sh 'a_lib_fn() { echo lib; } # touched')
  out=$(decide "$repo" "$base")
  picked "$out" | grep -Fxq tests/d.test.sh || fail "bash -c sources \$1, so a change to it must select tests/d.test.sh"
  base=$(change "$repo" bin/fm-b.sh '#!/usr/bin/env bash
echo b # touched')
  out=$(decide "$repo" "$base")
  picked "$out" | grep -Fxq tests/d.test.sh && fail "\$2 is only passed to show, never run, so tests/d.test.sh is unaffected by bin/fm-b.sh"
  pass "a bash -c argument counts as a dependency only where the inline code sources or runs it"
}

test_shared_test_infrastructure_selects_the_full_suite() {
  local repo base out path
  repo=$(new_repo infra)
  for path in tests/lib.sh bin/fm-test-run.sh .github/workflows/ci.yml bin/fm-test-select.py; do
    base=$(change "$repo" "$path" "# edited $path")
    out=$(decide "$repo" "$base")
    assert_equals full "$(field "$out" mode)" "$path must select the full suite"
    assert_contains "$(field "$out" reason)" infrastructure "$path must say why"
  done
  pass "tests/lib.sh, the runner, the selector and the workflows select the full suite"
}

test_an_unknown_path_selects_the_full_suite() {
  local repo out
  repo=$(new_repo unknown)
  out=$(printf 'bin/fm-b.sh\nno/such/file.sh\n' | python3 -I "$SELECT" --repo "$repo" --paths-from -)
  assert_equals full "$(field "$out" mode)" "a path in neither tree must not be treated as unaffecting"
  assert_contains "$(field "$out" reason)" 'no/such/file.sh' "the reason names the path"
  pass "a path the selector does not know selects the full suite"
}

test_a_selector_error_selects_the_full_suite_and_still_exits_zero() {
  local repo out rc
  repo=$(new_repo broken)
  out=$(python3 -I "$SELECT" --repo "$repo" --base no-such-revision --head HEAD)
  rc=$?
  assert_equals 0 "$rc" "a failure to read the diff must not look like a crash"
  assert_equals full "$(field "$out" mode)" "an unreadable base must select the full suite"
  assert_contains "$(field "$out" reason)" 'selector error' "the reason says the selector failed"
  out=$(python3 -I "$SELECT" --repo "$WORK/not-a-repository" --base HEAD)
  assert_equals full "$(field "$out" mode)" "a directory that is not a repository must select the full suite"
  out=$(python3 -I "$SELECT" --repo "$repo")
  assert_equals full "$(field "$out" mode)" "no base and no path list must select the full suite"
  pass "any selector error selects the full suite and exits zero"
}

test_a_forced_full_run_ignores_the_diff() {
  local repo out
  repo=$(new_repo forced)
  out=$(python3 -I "$SELECT" --repo "$repo" --full 'asked for it')
  assert_equals full "$(field "$out" mode)" "--full must select the full suite"
  assert_equals 'asked for it' "$(field "$out" reason)" "--full reports its reason"
  pass "--full selects the full suite whatever the diff"
}

test_a_change_reaching_nearly_every_test_selects_the_full_suite() {
  local repo base out n
  repo=$(new_repo wide)
  put "$repo" bin/fm-shared-lib.sh 'shared() { :; }'
  for n in $(seq 1 30); do
    put "$repo" "tests/pad-$n.test.sh" '#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-shared-lib.sh"
shared'
  done
  commit_all "$repo" share
  base=$(change "$repo" bin/fm-shared-lib.sh 'shared() { :; } # touched')
  out=$(decide "$repo" "$base")
  assert_equals full "$(field "$out" mode)" "thirty of thirty-three tests use the library: effectively the full suite"
  assert_contains "$(field "$out" reason)" 'widely shared' "the reason says so"
  pass "a widely sourced library selects the full suite"
}

test_a_deleted_file_still_selects_the_tests_that_name_it() {
  local repo before out
  repo=$(new_repo deleted)
  before=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" rm -q bin/fm-b.sh
  commit_all "$repo" remove-b
  out=$(decide "$repo" "$before")
  assert_equals selected "$(field "$out" mode)" "a deletion known to the base tree is a known path"
  picked "$out" | grep -Fxq tests/b.test.sh || fail "tests/b.test.sh runs the deleted script and must be selected"
  pass "a deleted file selects the tests that still name it"
}

test_a_walked_or_globbed_directory_selects_the_tests_that_read_it() {
  local repo base out
  repo=$(new_repo directories)
  put "$repo" data/x.txt one
  put "$repo" conf/y.cfg two
  put "$repo" tests/e.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for f in "$ROOT"/data/*.txt; do cat "$f"; done'
  put "$repo" tests/f.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp -R "$ROOT/conf" "$(mktemp -d)"'
  commit_all "$repo" readers
  base=$(change "$repo" data/x.txt changed)
  out=$(decide "$repo" "$base")
  assert_equals tests/e.test.sh "$(picked "$out")" "the glob over data/ names every file there"
  base=$(change "$repo" conf/y.cfg changed)
  out=$(decide "$repo" "$base")
  assert_equals tests/f.test.sh "$(picked "$out")" "cp -R conf names every file under conf/"
  base=$(change "$repo" README.md changed)
  out=$(decide "$repo" "$base")
  assert_equals selected "$(field "$out" mode)" "a file nothing reads is a partial selection"
  assert_equals 0 "$(field "$out" selected)" "and selects no test"
  pass "a globbed or copied directory selects its readers, and an unread file selects nothing"
}

test_a_document_is_a_leaf_and_a_test_that_reads_it_is_selected() {
  local repo base out
  repo=$(new_repo document)
  put "$repo" docs/note.md 'See bin/fm-b.sh for details.'
  put "$repo" tests/g.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
grep -q details "$ROOT/docs/note.md"'
  commit_all "$repo" doc
  base=$(change "$repo" docs/note.md 'See bin/fm-b.sh for the details.')
  out=$(decide "$repo" "$base")
  assert_equals tests/g.test.sh "$(picked "$out")" "the test that reads the document is affected, nothing else"
  base=$(change "$repo" bin/fm-b.sh '#!/usr/bin/env bash
echo b # touched')
  out=$(decide "$repo" "$base")
  picked "$out" | grep -Fxq tests/g.test.sh && fail "a document that mentions a script never runs it"
  pass "a document that names a script does not make its readers depend on the script"
}

test_a_name_built_from_a_directory_selects_the_files_it_could_be() {
  local repo base out
  repo=$(new_repo dynamic)
  put "$repo" bin/backends/one.sh 'one() { :; }'
  put "$repo" bin/backends/two.sh 'two() { :; }'
  put "$repo" bin/fm-dispatch.sh '#!/usr/bin/env bash
name=$1
. "$(dirname "${BASH_SOURCE[0]}")/backends/$name.sh"'
  put "$repo" tests/h.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/bin/fm-dispatch.sh" one'
  commit_all "$repo" dispatch
  base=$(change "$repo" bin/backends/two.sh 'two() { :; } # touched')
  out=$(decide "$repo" "$base")
  assert_equals tests/h.test.sh "$(picked "$out")" "backends/\$name.sh could be backends/two.sh"
  pass "a name with a variable in it selects the tests that could load any file it might mean"
}

# The shared test library's own setup and teardown reach every test. What it
# runs is dependency of all of them, but the scripts that script starts are not
# followed, or one teardown call would tie the whole tree to every test.
test_what_the_shared_library_starts_for_its_teardown_is_not_followed() {
  local repo base out n
  repo=$(new_repo ambient)
  put "$repo" bin/fm-cleanup.sh '#!/usr/bin/env bash
"$(dirname "${BASH_SOURCE[0]}")/fm-deep.sh"'
  put "$repo" bin/fm-deep.sh '#!/usr/bin/env bash
echo deep'
  put "$repo" tests/lib.sh '"$ROOT/bin/fm-cleanup.sh"'
  for n in $(seq 1 30); do
    put "$repo" "tests/pad-$n.test.sh" '#!/usr/bin/env bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"'
  done
  commit_all "$repo" ambient
  base=$(change "$repo" bin/fm-deep.sh '#!/usr/bin/env bash
echo deeper')
  out=$(decide "$repo" "$base")
  assert_equals selected "$(field "$out" mode)" "a script the teardown script starts must not select every test"
  assert_equals 0 "$(field "$out" selected)" "and no test names it"
  base=$(change "$repo" bin/fm-cleanup.sh '#!/usr/bin/env bash
"$(dirname "${BASH_SOURCE[0]}")/fm-deep.sh" # touched')
  out=$(decide "$repo" "$base")
  assert_equals full "$(field "$out" mode)" "the script the library itself runs reaches every test"
  pass "the shared library's own teardown chain is followed one script deep, no further"
}

test_explain_prints_the_chain_from_the_change_to_the_test() {
  local repo base out
  repo=$(new_repo explain)
  base=$(change "$repo" bin/fm-a-lib.sh 'a_lib_fn() { echo lib; } # touched')
  out=$(decide "$repo" "$base" --explain)
  assert_contains "$out" 'why=bin/fm-a-lib.sh <- bin/fm-a.sh <- tests/a.test.sh' "the chain names each hop"
  pass "--explain prints how a change reaches each selected test"
}

test_a_root_level_file_is_named_only_through_the_repository_root() {
  local repo base out
  repo=$(new_repo rootfile)
  put "$repo" AGENTS.md 'contract'
  put "$repo" bin/fm-r1.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat "$ROOT/AGENTS.md"'
  put "$repo" bin/fm-r2.sh '#!/usr/bin/env bash
home=$1
cat "$home/AGENTS.md"'
  put "$repo" tests/r1.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/bin/fm-r1.sh"'
  put "$repo" tests/r2.test.sh '#!/usr/bin/env bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/bin/fm-r2.sh" "$(mktemp -d)"'
  commit_all "$repo" readers
  base=$(change "$repo" AGENTS.md 'new contract')
  out=$(decide "$repo" "$base")
  assert_equals tests/r1.test.sh "$(picked "$out")" "only the script that reads the repository root's AGENTS.md depends on it; \$home/AGENTS.md is another tree's file"
  pass "a root-level file is named through the repository root, and the same file under a fixture variable is not"
}

# The real tree: the selector builds its graph over this repository and picks a
# test that was edited for itself. Slower than the fixtures, so it runs once.
test_the_real_tree_selects_an_edited_test_for_itself() {
  local out
  out=$(printf 'tests/fm-brief.test.sh\n' | python3 -I "$SELECT" --repo "$ROOT" --paths-from -)
  assert_equals selected "$(field "$out" mode)" "a test edited alone is a partial selection of the real suite"
  picked "$out" | grep -Fxq tests/fm-brief.test.sh || fail "the edited test must select itself"
  [ "$(field "$out" total)" -ge 300 ] || fail "the real suite has far more than $(field "$out" total) tests"
  out=$(printf 'tests/lib.sh\n' | python3 -I "$SELECT" --repo "$ROOT" --paths-from -)
  assert_equals full "$(field "$out" mode)" "tests/lib.sh must select the full suite of the real tree"
  pass "the real tree builds a graph, selects an edited test for itself, and treats tests/lib.sh as infrastructure"
}

fm_test_run_cases \
  test_a_sourced_library_selects_the_test_that_runs_its_consumer \
  test_a_planted_regression_in_an_unnamed_file_is_caught_by_the_selected_tests \
  test_a_message_that_mentions_a_script_is_not_a_dependency \
  test_a_comment_that_mentions_a_file_is_not_a_dependency \
  test_a_positional_argument_reaches_a_file_only_where_the_code_runs_it \
  test_shared_test_infrastructure_selects_the_full_suite \
  test_an_unknown_path_selects_the_full_suite \
  test_a_selector_error_selects_the_full_suite_and_still_exits_zero \
  test_a_forced_full_run_ignores_the_diff \
  test_a_change_reaching_nearly_every_test_selects_the_full_suite \
  test_a_deleted_file_still_selects_the_tests_that_name_it \
  test_a_walked_or_globbed_directory_selects_the_tests_that_read_it \
  test_a_document_is_a_leaf_and_a_test_that_reads_it_is_selected \
  test_a_name_built_from_a_directory_selects_the_files_it_could_be \
  test_what_the_shared_library_starts_for_its_teardown_is_not_followed \
  test_a_root_level_file_is_named_only_through_the_repository_root \
  test_explain_prints_the_chain_from_the_change_to_the_test \
  test_the_real_tree_selects_an_edited_test_for_itself \
  -- "$@"
