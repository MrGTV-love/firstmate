#!/usr/bin/env bash
# Behavioral regressions for bin/fm-contract-review-pack.sh: the pack builder and
# the input-leak check. Every case runs the script through its command line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACK_BIN="$ROOT/bin/fm-contract-review-pack.sh"
POLICY="$ROOT/.agents/skills/contract-review/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-contract-review)

# A contract with a planted marker in every section type.
write_fixture_contract() { # <file> [extra-heading]
  cat >"$1" <<EOF
# Fixture contract

Task: fixture. Contract revision: r9 (reviewed: ZZ-HISTORY-ZZ pass)

## REQUEST (verbatim)

ZZ-KEEP-REQUEST-ZZ the owner wants a thing.

## CONTEXT

ZZ-KEEP-CONTEXT-ZZ neutral fact.

## Definition Of Done (fixture), revision 9

- **A1** (mandatory): ZZ-KEEP-DOD-ZZ the thing exists.

### Author self-check

ZZ-ALLGREEN-ZZ the worker ships a thing that looks right.

## How You're Graded

A grader checks A1.

## Assumptions

- A-1 ZZ-KEEP-ASSUMPTION-ZZ neutral assumption.

## Boundary dispositions

- ZZ-RESPONSE-ZZ the author answered the earlier finding.

## Author's all-green candidate

ZZ-ALLGREEN-ZZ candidate.

## Contract Review history

- Revision 1: ZZ-PRIOR-FINDING-ZZ F1 was raised.

## Contract Review

ZZ-HISTORY-ZZ exit stalled.
${2:-}
EOF
}

build_pack() { # <out-var> [builder args...]: prints nothing, sets the named variable to the pack dir
  local __var=$1 __out
  shift
  __out=$("$PACK_BIN" "$@" 2>"$TMP_ROOT/build.err") || return $?
  printf -v "$__var" '%s' "$__out"
}

policy_block() { # <policy> <out>
  awk '$0 == "<!-- reviewer-block:begin -->" { on = 1 } on { print } $0 == "<!-- reviewer-block:end -->" { on = 0 }' "$1" >"$2"
}

pack_block() { # <pack/contract.md> <out>
  policy_block "$1" "$2"
}

test_markers_kept_and_dropped() {
  local src="$TMP_ROOT/m.md" pack found
  write_fixture_contract "$src"
  build_pack pack --contract "$src" || fail "builder refused a recognised contract: $(cat "$TMP_ROOT/build.err")"
  found=$(grep -rho 'ZZ-[A-Z]*-*[A-Z]*-ZZ' "$pack" | sort -u | tr '\n' ' ')
  for m in ZZ-KEEP-REQUEST-ZZ ZZ-KEEP-CONTEXT-ZZ ZZ-KEEP-DOD-ZZ ZZ-KEEP-ASSUMPTION-ZZ; do
    assert_contains "$found" "$m" "kept section marker missing from the pack"
  done
  for m in ZZ-ALLGREEN-ZZ ZZ-PRIOR-FINDING-ZZ ZZ-RESPONSE-ZZ ZZ-HISTORY-ZZ; do
    assert_not_contains "$found" "$m" "dropped section marker reached the pack"
  done
  pass "the pack keeps request, context, definition of done and assumptions and drops the author's sections"
}

test_unrecognised_section_refused() {
  local src="$TMP_ROOT/u.md" out_root="$TMP_ROOT/u-out" rc=0 err
  write_fixture_contract "$src" '
## Notes from the author

ZZ-UNKNOWN-ZZ something the builder has no rule for.'
  "$PACK_BIN" --contract "$src" --out-root "$out_root" >"$TMP_ROOT/u.out" 2>"$TMP_ROOT/u.err" || rc=$?
  assert_equals 3 "$rc" "an unrecognised section must exit 3"
  err=$(cat "$TMP_ROOT/u.err")
  assert_contains "$err" "unrecognised section: Notes from the author" "the unrecognised heading is not named"
  assert_absent "$out_root" "a refused build left an output directory"
  assert_absent "$out_root.excluded-paths" "a refused build left a manifest"
  [ ! -s "$TMP_ROOT/u.out" ] || fail "a refused build printed a pack path"
  pass "an unrecognised section stops the build, names the section and writes no pack"
}

test_single_source_policy_block() {
  local src="$TMP_ROOT/s.md" pack pack2 policy2="$TMP_ROOT/policy2.md"
  write_fixture_contract "$src"
  build_pack pack --contract "$src" || fail "build failed"
  policy_block "$POLICY" "$TMP_ROOT/block.expected"
  pack_block "$pack/contract.md" "$TMP_ROOT/block.actual"
  cmp -s "$TMP_ROOT/block.expected" "$TMP_ROOT/block.actual" || fail "the pack's reviewer block is not the policy block byte for byte"
  # A copy of the policy with one added line: the pack follows the policy.
  awk '{ print } $0 == "<!-- reviewer-block:begin -->" { print "Probe line that only this copy holds." }' "$POLICY" >"$policy2"
  build_pack pack2 --contract "$src" --policy "$policy2" || fail "build with the edited policy failed"
  assert_grep "Probe line that only this copy holds." "$pack2/contract.md" "the builder keeps its own copy of the rule text"
  assert_no_grep "Probe line that only this copy holds." "$pack/contract.md" "the unedited pack carries the probe line"
  pass "the builder copies the policy's reviewer block byte for byte and follows an edited policy"
}

test_pack_layout_and_fresh_parent() {
  local src="$TMP_ROOT/l.md" pack parent rc=0
  write_fixture_contract "$src"
  build_pack pack --contract "$src" || fail "build failed"
  for f in contract.md target.md head.txt ci-evidence.md diff.patch; do
    assert_present "$pack/$f" "pack file $f missing"
  done
  [ ! -s "$pack/diff.patch" ] || fail "the diff slot is not empty"
  parent=$(dirname "$pack")
  assert_equals "pack" "$(ls -A "$parent")" "the pack's parent holds more than the pack"
  "$PACK_BIN" --contract "$src" --out-root "$parent" >/dev/null 2>"$TMP_ROOT/l.err" || rc=$?
  assert_equals 2 "$rc" "a build into a directory that holds a pack must be refused"
  mkdir -p "$TMP_ROOT/l-review"
  printf 'old report\n' >"$TMP_ROOT/l-review/review.md"
  rc=0
  "$PACK_BIN" --contract "$src" --out-root "$TMP_ROOT/l-review" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a build into a directory that holds a review.md must be refused"
  assert_equals "old report" "$(cat "$TMP_ROOT/l-review/review.md")" "a refused build changed the existing report"
  pass "each pack is built fresh, alone in its parent, and never beside an earlier report"
}

test_fails_safe_on_bad_input() {
  local src="$TMP_ROOT/f.md" rc err
  write_fixture_contract "$src"
  rc=0
  "$PACK_BIN" --contract "$TMP_ROOT/absent.md" --out-root "$TMP_ROOT/f1" >/dev/null 2>"$TMP_ROOT/f.err" || rc=$?
  assert_equals 2 "$rc" "a missing contract must exit nonzero"
  assert_absent "$TMP_ROOT/f1" "a missing contract left an output directory"
  rc=0
  "$PACK_BIN" --contract "$src" --policy "$TMP_ROOT/absent-policy.md" --out-root "$TMP_ROOT/f2" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an unreadable policy must exit nonzero"
  assert_absent "$TMP_ROOT/f2" "an unreadable policy left an output directory"
  printf '# No done here\n\n## REQUEST\n\nA request only.\n' >"$TMP_ROOT/nodod.md"
  rc=0
  "$PACK_BIN" --contract "$TMP_ROOT/nodod.md" --out-root "$TMP_ROOT/f3" >/dev/null 2>"$TMP_ROOT/f.err" || rc=$?
  assert_equals 2 "$rc" "a contract with no Definition Of Done must exit nonzero"
  assert_absent "$TMP_ROOT/f3" "a contract with no Definition Of Done left an output directory"
  err=$(cat "$TMP_ROOT/f.err")
  [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] || fail "the failure cause is not one line: $err"
  printf 'no markers here\n' >"$TMP_ROOT/badpolicy.md"
  rc=0
  "$PACK_BIN" --contract "$src" --policy "$TMP_ROOT/badpolicy.md" --out-root "$TMP_ROOT/f4" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a policy with no reviewer block must exit nonzero"
  assert_absent "$TMP_ROOT/f4" "a policy with no reviewer block left an output directory"
  pass "bad input exits nonzero with a one-line cause and writes nothing"
}

test_context_file_with_author_section_refused() {
  local src="$TMP_ROOT/c.md" ctx="$TMP_ROOT/ctx.md" rc=0
  write_fixture_contract "$src"
  printf '# Owner context\n\nA neutral fact.\n\n## Author self-check\n\nZZ-ALLGREEN-ZZ\n' >"$ctx"
  "$PACK_BIN" --contract "$src" --context "$ctx" --out-root "$TMP_ROOT/c-out" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a context file that holds an author section must be refused"
  assert_absent "$TMP_ROOT/c-out" "a refused context file left an output directory"
  printf '# Owner context\n\nZZ-KEEP-CTXFILE-ZZ a neutral fact.\n' >"$ctx"
  build_pack pack --contract "$src" --context "$ctx" --request "$ctx" || fail "build with a clean context failed"
  assert_present "$pack/context-ctx.md" "context file missing from the pack"
  assert_present "$pack/request.md" "request file missing from the pack"
  pass "a context file with an author section is refused and a clean one is copied"
}

# --- the input-leak check ---------------------------------------------------

make_leak_world() { # builds LEAK_* variables
  LEAK_ROOT="$TMP_ROOT/leak-root"
  LEAK_SKILLS="$TMP_ROOT/leak-skills"
  rm -rf "$LEAK_ROOT" "$LEAK_SKILLS"
  mkdir -p "$LEAK_ROOT/bin" "$LEAK_ROOT/docs" "$LEAK_ROOT/data/case/truth" "$LEAK_ROOT/sources" \
    "$LEAK_SKILLS/assess-done-and-grade" "$LEAK_SKILLS/define-done-and-grading"
  printf '#!/bin/sh\n' >"$LEAK_ROOT/bin/fm-spawn.sh"
  printf 'rubric\n' >"$LEAK_ROOT/docs/review-rubric.md"
  printf 'tracked excluded file\n' >"$LEAK_ROOT/sources/notes.md"
  write_fixture_contract "$LEAK_ROOT/sources/raw-contract.md"
  printf 'data/\n' >"$LEAK_ROOT/.gitignore"
  printf 'an earlier review report\n' >"$LEAK_ROOT/data/case/truth/r23-review.md"
  printf 'assess\n' >"$LEAK_SKILLS/assess-done-and-grade/SKILL.md"
  printf 'define\n' >"$LEAK_SKILLS/define-done-and-grading/SKILL.md"
  ln -s "$LEAK_SKILLS" "$TMP_ROOT/leak-skills-link"
  fm_git_init_commit "$LEAK_ROOT"
  git -C "$LEAK_ROOT" add bin docs sources .gitignore
  git -C "$LEAK_ROOT" -c user.name=t -c user.email=t@example.invalid commit -qm files
  LEAK_PACK=''
  build_pack LEAK_PACK --contract "$LEAK_ROOT/sources/raw-contract.md" --root "$LEAK_ROOT" \
    --exclude "$LEAK_ROOT/sources/notes.md" || fail "leak world build failed: $(cat "$TMP_ROOT/build.err")"
  # A sibling pack that holds an earlier report, outside the root.
  mkdir -p "$TMP_ROOT/sibling/pack"
  printf 'VERDICT: PASS\n' >"$TMP_ROOT/sibling/pack/review.md"
}

write_report() { # <file> <path>...: a report whose Inputs read lists the given paths
  local f=$1
  shift
  {
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n'
    # shellcheck disable=SC2016 # literal backticks in generated Markdown
    for p in "$@"; do printf -- '- `%s`\n' "$p"; done
    printf '\n## Findings\n\nF1 something.\n\nEXIT: needs-revision\nVERDICT: FAIL\n'
  } >"$f"
}

run_check() { # <report> -> sets CHECK_OUT and CHECK_RC
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$LEAK_PACK" --report "$1" 2>&1) || CHECK_RC=$?
}

test_leak_check_judges_what_a_path_is() {
  local rep="$TMP_ROOT/report.md"
  make_leak_world
  # 1. Compliant: pack files, both skills (one through a symlinked directory), the rubric, a tracked file.
  write_report "$rep" "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" \
    "$LEAK_SKILLS/assess-done-and-grade/SKILL.md" "$TMP_ROOT/leak-skills-link/define-done-and-grading/SKILL.md" \
    "$LEAK_ROOT/docs/review-rubric.md" "$LEAK_ROOT/bin/fm-spawn.sh"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a compliant report was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "INPUT CLEAN" "a compliant report was not reported clean"
  # 2. A gitignored earlier report under the root.
  write_report "$rep" "$LEAK_PACK/contract.md" "$LEAK_ROOT/data/case/truth/r23-review.md"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a gitignored report under the root was allowed"
  assert_contains "$CHECK_OUT" "INPUT LEAK" "no INPUT LEAK line for a gitignored report"
  assert_contains "$CHECK_OUT" "ROUND VOID" "no void line for a gitignored report"
  # 3. A sibling pack's review.md outside the root.
  write_report "$rep" "$LEAK_PACK/contract.md" "$TMP_ROOT/sibling/pack/review.md"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a sibling pack's report was allowed"
  # 4. A tracked file the caller passed as excluded.
  write_report "$rep" "$LEAK_PACK/contract.md" "$LEAK_ROOT/sources/notes.md"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a tracked file the caller excluded was allowed"
  assert_contains "$CHECK_OUT" "excluded path" "the exclusion is not the stated reason"
  # 5. The tracked raw source the pack was built from, with no exclusion passed by hand.
  write_report "$rep" "$LEAK_PACK/contract.md" "$LEAK_ROOT/sources/raw-contract.md"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "the tracked raw contract source was allowed"
  assert_contains "$CHECK_OUT" "INPUT LEAK" "no INPUT LEAK line for the raw source"
  # 6. No Inputs read list.
  printf 'VERDICT: PASS head=abc\n\nNo list here.\nEXIT: pass\nVERDICT: PASS\n' >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a report with no Inputs read list was accepted"
  assert_contains "$CHECK_OUT" "ROUND VOID" "a missing list did not void the round"
  pass "the leak check authorizes by what a path is and voids the round on a leak or a missing list"
}

test_leak_check_revision_paths_and_excluded_directories() {
  local rep="$TMP_ROOT/report2.md" rev
  make_leak_world
  rev=$(git -C "$LEAK_ROOT" rev-parse --short HEAD)
  write_report "$rep" "$LEAK_PACK/contract.md" "$rev:bin/fm-spawn.sh"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a revision path tracked at that revision was flagged: $CHECK_OUT"
  write_report "$rep" "$LEAK_PACK/contract.md" "$rev:data/case/truth/r23-review.md"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a revision path that is not tracked was allowed"
  # An excluded directory refuses every file below it, even a tracked one.
  local pack2
  build_pack pack2 --contract "$LEAK_ROOT/sources/raw-contract.md" --root "$LEAK_ROOT" \
    --exclude "$LEAK_ROOT/bin" || fail "build failed"
  write_report "$rep" "$pack2/contract.md" "$LEAK_ROOT/bin/fm-spawn.sh"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$pack2" --report "$rep" 2>&1) || CHECK_RC=$?
  assert_equals 3 "$CHECK_RC" "a file below an excluded directory was allowed"
  # A run log that names an excluded path voids the round.
  printf 'I also read %s\n' "$LEAK_ROOT/sources/notes.md" >"$TMP_ROOT/run.log"
  write_report "$rep" "$LEAK_PACK/contract.md"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$LEAK_PACK" --report "$rep" --log "$TMP_ROOT/run.log" 2>&1) || CHECK_RC=$?
  assert_equals 3 "$CHECK_RC" "an excluded path named in the run log was allowed"
  pass "revision paths, excluded directories and the run log are judged by the same rules"
}

fm_test_run_cases \
  test_markers_kept_and_dropped \
  test_unrecognised_section_refused \
  test_single_source_policy_block \
  test_pack_layout_and_fresh_parent \
  test_fails_safe_on_bad_input \
  test_context_file_with_author_section_refused \
  test_leak_check_judges_what_a_path_is \
  test_leak_check_revision_paths_and_excluded_directories \
  -- "$@"
