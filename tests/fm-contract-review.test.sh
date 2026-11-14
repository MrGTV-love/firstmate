#!/usr/bin/env bash
# Behavioral regressions for bin/fm-contract-review-pack.sh: the pack builder and
# the input-leak check. Every case runs the script through its command line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACK_BIN="$ROOT/bin/fm-contract-review-pack.sh"
POLICY="$ROOT/.agents/skills/contract-review/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-contract-review)
export TMPDIR="$TMP_ROOT"
mkdir -p "$TMPDIR"

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
  __out=$("$PACK_BIN" --root "$ROOT" "$@" 2>"$TMP_ROOT/build.err") || return $?
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
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$out_root" >"$TMP_ROOT/u.out" 2>"$TMP_ROOT/u.err" || rc=$?
  assert_equals 3 "$rc" "an unrecognised section must exit 3"
  err=$(cat "$TMP_ROOT/u.err")
  assert_contains "$err" "unrecognised section: Notes from the author" "the unrecognised heading is not named"
  assert_absent "$out_root" "a refused build left an output directory"
  assert_absent "$out_root.excluded-paths" "a refused build left a manifest"
  [ ! -s "$TMP_ROOT/u.out" ] || fail "a refused build printed a pack path"
  pass "an unrecognised section stops the build, names the section and writes no pack"
}

test_unrecognised_subheadings_stay_and_are_listed() {
  local src="$TMP_ROOT/sub.md" pack manifest target m
  # Neutral unknown sub-headings stay in the pack and are listed (Main 024). Sub-headings that
  # name author history or an author section stop the build instead (Main 050 F1); see
  # test_author_history_subheading_in_contract_refused.
  cat >"$src" <<'EOF'
# Fixture contract

ZZ-PREAMBLE-ZZ a neutral preamble line.

## Definition Of Done

- **A1** (mandatory): ZZ-KEEP-DOD-ZZ the thing exists.

### Worked example

ZZ-SUB-L3-ZZ text under an unknown level 3 heading.

#### Field notes

ZZ-SUB-L4-ZZ text under a level 4 heading.

**Reference values**

ZZ-SUB-BOLD-ZZ text under a bold-only line.

### Author self-check

ZZ-ALLGREEN-ZZ a recognised author section.
EOF
  build_pack pack --contract "$src" || fail "builder refused a contract with unrecognised sub-headings: $(cat "$TMP_ROOT/build.err")"
  target="$pack/target.md"
  manifest="$(dirname "$pack").excluded-paths"
  for m in ZZ-PREAMBLE-ZZ ZZ-SUB-L3-ZZ ZZ-SUB-L4-ZZ ZZ-SUB-BOLD-ZZ; do
    assert_grep "$m" "$target" "text under an unrecognised heading or preamble line was dropped: $m"
  done
  assert_no_grep "ZZ-ALLGREEN-ZZ" "$target" "a recognised author sub-section reached the pack"
  grep -qxF "$(printf 'dropped\tAuthor self-check')" "$manifest" || fail "the dropped sub-section is not listed in the manifest"
  for m in "### Worked example (under: Definition Of Done)" \
    "#### Field notes (under: Definition Of Done)" \
    "**Reference values** (under: Definition Of Done)" \
    "preamble line: ZZ-PREAMBLE-ZZ a neutral preamble line."; do
    grep -qxF "$(printf 'unrecognised\t%s' "$m")" "$manifest" || fail "the manifest does not list as unrecognised: $m"
  done
  assert_not_contains "$(cat "$manifest")" "$(printf 'unrecognised\t- **A1**')" "a criterion line was listed as a heading"
  pass "an unrecognised sub-heading or preamble line stays in the pack and the manifest lists it"
}

test_setext_headings_are_sections() {
  local src="$TMP_ROOT/st.md" pack manifest rc=0
  cat >"$src" <<'EOF'
# Fixture contract

## Definition Of Done

- **A1** (mandatory): ZZ-KEEP-DOD-ZZ the thing exists.

## Contract Review

ZZ-HISTORY-ZZ an earlier round.

How You're Graded
-----------------

ZZ-SETEXT-KEEP-ZZ graded text.

Revision log
============

ZZ-SETEXT-DROP-ZZ an author log.
EOF
  build_pack pack --contract "$src" || fail "a contract with setext sections was refused: $(cat "$TMP_ROOT/build.err")"
  manifest="$(dirname "$pack").excluded-paths"
  assert_grep "ZZ-SETEXT-KEEP-ZZ" "$pack/target.md" "a recognised setext section after a dropped section was dropped"
  assert_grep "How You're Graded" "$pack/target.md" "the setext heading of a kept section is missing"
  assert_no_grep "ZZ-HISTORY-ZZ" "$pack/target.md" "the dropped section before the setext heading reached the pack"
  assert_no_grep "ZZ-SETEXT-DROP-ZZ" "$pack/target.md" "an author setext section reached the pack"
  grep -qxF "$(printf 'dropped\tRevision log')" "$manifest" || fail "the dropped setext section is not listed in the manifest"
  printf '\nOther Title\n===\n\nZZ-SETEXT-H1-ZZ text.\n' >>"$src"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/st-out" >/dev/null 2>"$TMP_ROOT/st.err" || rc=$?
  assert_equals 3 "$rc" "an unrecognised setext section must exit 3"
  assert_contains "$(cat "$TMP_ROOT/st.err")" "unrecognised section: Other Title" "the unrecognised setext heading is not named"
  assert_absent "$TMP_ROOT/st-out" "a refused setext build left an output directory"
  pass "a setext heading is a section, classified like a level 1 or 2 heading"
}

test_code_fences_close_on_their_own_marker() {
  local src="$TMP_ROOT/fc.md" pack rc=0
  write_fixture_contract "$src"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "~~~text"; print "ZZ-KEEP-FENCE-ZZ"; print "```"; print "## Contract Review inside a fence"; print "~~~" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "a contract with a closed fence was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-FENCE-ZZ" "$pack/target.md" "text inside a closed fence was dropped"
  assert_grep "## Contract Review inside a fence" "$pack/target.md" "a heading-shaped line inside a fence was treated as a heading"
  assert_no_grep "ZZ-ALLGREEN-ZZ" "$pack/target.md" "an author section after a closed fence reached the pack"
  write_fixture_contract "$src"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "```text"; print "never closed" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/fc-out" >"$TMP_ROOT/fc.out" 2>"$TMP_ROOT/fc.err" || rc=$?
  assert_equals 3 "$rc" "a contract with an unclosed fence must exit 3"
  assert_contains "$(cat "$TMP_ROOT/fc.err")" "never closes" "the unclosed fence is not named"
  assert_absent "$TMP_ROOT/fc-out" "an unclosed fence left an output directory"
  [ ! -s "$TMP_ROOT/fc.out" ] || fail "an unclosed fence printed a pack path"
  pass "a fence closes only on its own marker, and an unclosed fence stops the build"
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
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$parent" >/dev/null 2>"$TMP_ROOT/l.err" || rc=$?
  assert_equals 2 "$rc" "a build into a directory that holds a pack must be refused"
  mkdir -p "$TMP_ROOT/l-review"
  printf 'old report\n' >"$TMP_ROOT/l-review/review.md"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/l-review" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a build into a directory that holds a review.md must be refused"
  assert_equals "old report" "$(cat "$TMP_ROOT/l-review/review.md")" "a refused build changed the existing report"
  pass "each pack is built fresh, alone in its parent, and never beside an earlier report"
}

test_fails_safe_on_bad_input() {
  local src="$TMP_ROOT/f.md" rc err
  write_fixture_contract "$src"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$TMP_ROOT/absent.md" --out-root "$TMP_ROOT/f1" >/dev/null 2>"$TMP_ROOT/f.err" || rc=$?
  assert_equals 2 "$rc" "a missing contract must exit nonzero"
  assert_absent "$TMP_ROOT/f1" "a missing contract left an output directory"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --policy "$TMP_ROOT/absent-policy.md" --out-root "$TMP_ROOT/f2" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an unreadable policy must exit nonzero"
  assert_absent "$TMP_ROOT/f2" "an unreadable policy left an output directory"
  printf '# No done here\n\n## REQUEST\n\nA request only.\n' >"$TMP_ROOT/nodod.md"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$TMP_ROOT/nodod.md" --out-root "$TMP_ROOT/f3" >/dev/null 2>"$TMP_ROOT/f.err" || rc=$?
  assert_equals 2 "$rc" "a contract with no Definition Of Done must exit nonzero"
  assert_absent "$TMP_ROOT/f3" "a contract with no Definition Of Done left an output directory"
  err=$(cat "$TMP_ROOT/f.err")
  [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] || fail "the failure cause is not one line: $err"
  printf 'no markers here\n' >"$TMP_ROOT/badpolicy.md"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --policy "$TMP_ROOT/badpolicy.md" --out-root "$TMP_ROOT/f4" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a policy with no reviewer block must exit nonzero"
  assert_absent "$TMP_ROOT/f4" "a policy with no reviewer block left an output directory"
  pass "bad input exits nonzero with a one-line cause and writes nothing"
}

test_context_file_with_author_section_refused() {
  local src="$TMP_ROOT/c.md" ctx="$TMP_ROOT/ctx.md" rc=0
  write_fixture_contract "$src"
  printf '# Owner context\n\nA neutral fact.\n\n## Author self-check\n\nZZ-ALLGREEN-ZZ\n' >"$ctx"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --context "$ctx" --out-root "$TMP_ROOT/c-out" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a context file that holds an author section must be refused"
  assert_absent "$TMP_ROOT/c-out" "a refused context file left an output directory"
  printf '# Owner context\n\nZZ-KEEP-CTXFILE-ZZ a neutral fact.\n' >"$ctx"
  build_pack pack --contract "$src" --context "$ctx" --request "$ctx" || fail "build with a clean context failed"
  assert_present "$pack/context-ctx.md" "context file missing from the pack"
  assert_present "$pack/request.md" "request file missing from the pack"
  local bad="$TMP_ROOT/bad-input.md" n=0 body
  for body in '# Request\n\nThe owner wants a thing.\n\n## Author'"'"'s all-green candidate\n\nZZ-ALLGREEN-ZZ\n' \
    'Author'"'"'s all-green self-check: everything passes.\n\nThe owner wants a thing.\n' \
    '# Owner context\n\n## Notes\n\n### Prior findings\n\nZZ-PRIOR-FINDING-ZZ\n'; do
    n=$((n + 1))
    printf '%b' "$body" >"$bad"
    for flag in --request --context; do
      rc=0
      "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$bad" --out-root "$TMP_ROOT/c-bad$n$flag" >/dev/null 2>"$TMP_ROOT/c.err" || rc=$?
      assert_equals 2 "$rc" "$flag file $n with author text was accepted"
      assert_contains "$(cat "$TMP_ROOT/c.err")" "author text" "$flag file $n refusal does not name the cause"
      assert_absent "$TMP_ROOT/c-bad$n$flag" "a refused $flag file left an output directory"
    done
  done
  pass "a request or context file with author text is refused and a clean one is copied"
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
  mkdir -p "$LEAK_ROOT/notes"
  printf 'a tracked plan\n' >"$LEAK_ROOT/notes/plan.md"
  write_fixture_contract "$LEAK_ROOT/sources/raw-contract.md"
  printf 'data/\nsecret.md\n.env\n' >"$LEAK_ROOT/.gitignore"
  printf 'secret\n' >"$LEAK_ROOT/secret.md"
  printf 'TOKEN=x\n' >"$LEAK_ROOT/.env"
  printf 'readme\n' >"$LEAK_ROOT/README.md"
  printf 'an earlier review report\n' >"$LEAK_ROOT/data/case/truth/r23-review.md"
  printf 'assess\n' >"$LEAK_SKILLS/assess-done-and-grade/SKILL.md"
  printf 'define\n' >"$LEAK_SKILLS/define-done-and-grading/SKILL.md"
  printf 'old copy\n' >"$LEAK_SKILLS/define-done-and-grading/SKILL.md.backup-20261101-x"
  printf 'boundaries\n' >"$LEAK_SKILLS/define-done-and-grading/OPERATIONAL-BOUNDARIES.md"
  printf 'notes\n' >"$LEAK_SKILLS/define-done-and-grading/MAINTAINER-NOTES.md"
  printf 'define\n\nApply [Operational boundaries](OPERATIONAL-BOUNDARIES.md).\n' >"$LEAK_SKILLS/define-done-and-grading/SKILL.md"
  ln -s "$LEAK_SKILLS" "$TMP_ROOT/leak-skills-link"
  fm_git_init_commit "$LEAK_ROOT"
  git -C "$LEAK_ROOT" add bin docs sources notes README.md .gitignore
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

# One tool call of a reviewer session transcript, as the entrypoint's harness records it:
# tool_call <name> <key> <value> [<key> <value>]... prints one JSON object.
tool_call() {
  python3 -I -c 'import json, sys
a = sys.argv[2:]
print(json.dumps({"type": "toolCall", "name": sys.argv[1], "arguments": dict(zip(a[0::2], a[1::2]))}))' "$@"
}

# write_transcript <file> <cwd> <tool-call-json>...: a session transcript with one assistant
# message per tool call.
write_transcript() {
  local f=$1 cwd=$2 call
  shift 2
  python3 -I -c 'import json, sys; print(json.dumps({"type": "session", "version": 3, "id": "t", "cwd": sys.argv[1]}))' "$cwd" >"$f"
  for call in "$@"; do
    printf '{"type":"message","message":{"role":"assistant","content":[%s]}}\n' "$call" >>"$f"
  done
}

# The run's own work folder, as the entrypoint names it: <work root>/<pack parent>-<pack>.
work_of() { # <pack>
  printf '%s/work/%s-%s' "$TMP_ROOT" "$(basename "$(dirname "$1")")" "$(basename "$1")"
}

# A clean transcript beside the leak world's pack: the reviewer read only the pack's contract.
clean_transcript() { # <file> [pack]
  write_transcript "$1" "$(work_of "${2:-$LEAK_PACK}")" "$(tool_call read path "${2:-$LEAK_PACK}/contract.md")"
}

run_check() { # <report> [transcript] -> sets CHECK_OUT and CHECK_RC
  local log=${2:-$TMP_ROOT/clean-transcript.jsonl}
  [ -n "${2:-}" ] || clean_transcript "$log"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$LEAK_PACK" --report "$1" --log "$log" 2>&1) || CHECK_RC=$?
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
  # 1b. A backup or note beside the skill is not the skill.
  write_report "$rep" "$LEAK_PACK/contract.md" "$LEAK_SKILLS/define-done-and-grading/SKILL.md.backup-20261101-x"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a backup file in the skill directory was authorized"
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
    "$PACK_BIN" check --pack "$pack2" --report "$rep" --log "$(clean_transcript "$TMP_ROOT/ct2.jsonl" "$pack2" && echo "$TMP_ROOT/ct2.jsonl")" 2>&1) || CHECK_RC=$?
  assert_equals 3 "$CHECK_RC" "a file below an excluded directory was allowed"
  # A run transcript that records a read of an excluded path voids the round.
  write_transcript "$TMP_ROOT/run.jsonl" "$(work_of "$LEAK_PACK")" "$(tool_call read path "$LEAK_ROOT/sources/notes.md")"
  write_report "$rep" "$LEAK_PACK/contract.md"
  run_check "$rep" "$TMP_ROOT/run.jsonl"
  assert_equals 3 "$CHECK_RC" "an excluded path read in the run transcript was allowed"
  pass "revision paths, excluded directories and the run log are judged by the same rules"
}

test_leak_check_reads_common_report_shapes() {
  local rep="$TMP_ROOT/report3.md"
  make_leak_world
  # A numbered heading with a parenthetical, and line references after the paths.
  # shellcheck disable=SC2016 # literal backticks in generated Markdown
  {
    printf 'VERDICT: FAIL head=abc\n\n### 2. Inputs read (3 files)\n\n'
    printf -- '- %s:12\n' "$LEAK_PACK/contract.md"
    printf -- '- `%s`:L10-L40 - the target\n' "$LEAK_PACK/target.md"
    printf -- '* %s#L5\n' "$LEAK_ROOT/bin/fm-spawn.sh"
    printf '\n## Findings\n\nEXIT: needs-revision\nVERDICT: FAIL\n'
  } >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a numbered heading or a line reference was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "3 listed input(s)" "the list under a numbered heading was not read"
  # The same shapes still catch a leak.
  {
    printf 'VERDICT: FAIL head=abc\n\n### 2. Inputs read (2 files)\n\n'
    printf -- '- %s:12\n' "$LEAK_PACK/contract.md"
    printf -- '- %s:7\n' "$LEAK_ROOT/data/case/truth/r23-review.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak behind a line reference was allowed"
  pass "the leak check reads numbered headings and line references without voiding a clean round"
}

test_leak_check_reads_prose_before_the_list_and_refuses_linked_files() {
  local rep="$TMP_ROOT/report4.md"
  make_leak_world
  # Prose between the heading and the first path, blank lines between paths, prose after the list.
  {
    printf 'VERDICT: FAIL head=abc\n\n# Inputs read\n\nEach path is listed separately; none is cited as evidence.\n\n'
    printf '%s\n\n' "$LEAK_PACK/contract.md"
    printf '%s\n' "$LEAK_PACK/target.md"
    printf '%s\n' "$LEAK_SKILLS/define-done-and-grading/SKILL.md"
    printf '\nThat is the whole list.\n\nEXIT: needs-revision\nVERDICT: FAIL\n'
  } >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a list after a prose line was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "3 listed input(s)" "the list after the prose line was not read in full"
  # A file the skill's SKILL.md links is not one of the three named references.
  {
    printf 'VERDICT: FAIL head=abc\n\n# Inputs read\n\nPaths follow.\n\n'
    printf '%s\n' "$LEAK_PACK/contract.md"
    printf '%s\n' "$LEAK_SKILLS/define-done-and-grading/OPERATIONAL-BOUNDARIES.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a file the skill links was authorized"
  assert_contains "$CHECK_OUT" "INPUT LEAK" "no INPUT LEAK line for a file the skill links"
  # A file in the skill folder that its SKILL.md does not link is still a leak.
  {
    printf 'VERDICT: FAIL head=abc\n\n# Inputs read\n\nPaths follow.\n\n'
    printf '%s\n' "$LEAK_PACK/contract.md"
    printf '%s\n' "$LEAK_SKILLS/define-done-and-grading/MAINTAINER-NOTES.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "an unlinked note in the skill folder was authorized"
  # Prose before the list and nothing after it is a missing list, not a clean one.
  printf 'VERDICT: FAIL head=abc\n\n# Inputs read\n\nNone recorded.\n\nEXIT: needs-revision\n' >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a heading with no paths was accepted"
  pass "the leak check reads a list that follows a prose line and authorizes no skill file but SKILL.md"
}

test_leak_check_reads_the_whole_list() {
  local rep="$TMP_ROOT/report6.md"
  make_leak_world
  # Compliant: group labels, a prose bullet and a sub-heading inside the list are skipped, not the end of it.
  {
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\nPack:\n'
    printf -- '- %s\n' "$LEAK_PACK/contract.md"
    printf -- '- the assess skill, read in full\n'
    printf '\n### References\n\n'
    printf -- '- %s\n' "$LEAK_SKILLS/assess-done-and-grade/SKILL.md"
    printf '\nOther:\n'
    printf -- '- %s\n' "$LEAK_ROOT/bin/fm-spawn.sh"
    printf '\n## Findings\n\n- %s is fine.\n\nEXIT: needs-revision\n' "$TMP_ROOT/sibling/pack/review.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a grouped clean list was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "3 listed input(s)" "the grouped list was not read to its end"
  # Noncompliant: a leak after a group label is read.
  {
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\nPack:\n'
    printf -- '- %s\n' "$LEAK_PACK/contract.md"
    printf -- '- the assess skill\n'
    printf 'Other:\n'
    printf -- '- %s\n' "$TMP_ROOT/sibling/pack/review.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak after a group label was allowed"
  assert_contains "$CHECK_OUT" "INPUT LEAK: $TMP_ROOT/sibling/pack/review.md" "the leak after a group label is not named"
  # The inline form has no heading of its own, so it voids the round.
  {
    printf 'VERDICT: FAIL head=abc\n\nInputs read: %s, %s\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md"
    printf -- '- %s\n' "$TMP_ROOT/sibling/pack/review.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak listed after the inline form was allowed"
  assert_contains "$CHECK_OUT" "not under its own heading" "the inline form did not void the round for its missing heading"
  pass "the leak check reads the whole Inputs read list to the next heading"
}

test_leak_check_pins_the_rubric_revision() {
  local rep="$TMP_ROOT/report7.md" rev pack
  make_leak_world
  rev=$(git -C "$LEAK_ROOT" log -1 --format=%H -- docs/review-rubric.md)
  build_pack pack --contract "$LEAK_ROOT/sources/raw-contract.md" || fail "build without a root failed"
  rubric_check() { # <entry>
    write_report "$rep" "$pack/contract.md" "$1"
    CHECK_RC=0
    CHECK_OUT=$(REVIEW_FM_ROOT="$LEAK_ROOT" REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
      "$PACK_BIN" check --pack "$pack" --report "$rep" --log "$(clean_transcript "$TMP_ROOT/ct3.jsonl" "$pack" && echo "$TMP_ROOT/ct3.jsonl")" 2>&1) || CHECK_RC=$?
  }
  rubric_check "$rev:docs/review-rubric.md"
  assert_equals 0 "$CHECK_RC" "the pinned rubric revision was flagged: $CHECK_OUT"
  rubric_check "no-such-rev:docs/review-rubric.md"
  assert_equals 3 "$CHECK_RC" "an unknown revision of the rubric was allowed"
  rubric_check "HEAD:docs/review-rubric.md"
  assert_equals 3 "$CHECK_RC" "a revision name other than the pinned one was allowed"
  pass "a revision path to the rubric is allowed only at the pinned revision"
}

test_pack_names_only_the_request_it_holds() {
  local src="$TMP_ROOT/rq.md" ctx="$TMP_ROOT/rq-request.md" with without none
  write_fixture_contract "$src"
  printf 'The owner wants a thing.\n' >"$ctx"
  build_pack with --contract "$src" --request "$ctx" || fail "build with a request failed"
  build_pack without --contract "$src" || fail "build without a request failed"
  assert_present "$with/request.md" "the request file is missing from the pack"
  assert_absent "$without/request.md" "a request file appeared though none was given"
  # shellcheck disable=SC2016 # literal backticks in generated Markdown
  assert_grep 'The request is `request.md`.' "$with/contract.md" "the pack with a request does not name it"
  # shellcheck disable=SC2016 # literal backticks in generated Markdown
  assert_no_grep 'The request is `request.md`.' "$without/contract.md" "the pack without a request names a file it does not hold"
  # shellcheck disable=SC2016 # literal backticks in generated Markdown
  assert_grep 'the request is the REQUEST section of `target.md`' "$without/contract.md" "the pack without a request does not point at the REQUEST section"
  printf '# Fixture\n\n## Definition Of Done\n\n- A1 (mandatory): x\n' >"$TMP_ROOT/rq-none.md"
  build_pack none --contract "$TMP_ROOT/rq-none.md" || fail "build of a contract with no request section failed"
  assert_no_grep 'The request is' "$none/contract.md" "a contract with no request is said to have one"
  pass "the pack names a request only where the pack or the contract holds one"
}

test_export_root_mode_is_gone() {
  local src="$TMP_ROOT/x.md" rc
  write_fixture_contract "$src"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --export-root "$ROOT" --out-root "$TMP_ROOT/x1" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "--export-root was accepted"
  assert_absent "$TMP_ROOT/x1" "a refused --export-root left an output directory"
  assert_absent "$TMP_ROOT/x1.root" "a refused --export-root left an export directory"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --root "$ROOT" --rev HEAD --out-root "$TMP_ROOT/x2" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "--rev was accepted"
  assert_absent "$TMP_ROOT/x2" "a refused --rev left an output directory"
  pass "the builder takes the repository root only as --root"
}

test_leak_check_pinned_rubric_url_and_own_report() {
  local rep="$TMP_ROOT/report5.md" rev pinned_raw pinned_blob wr
  make_leak_world
  git -C "$LEAK_ROOT" remote add origin https://github.com/owner/repo.git
  rev=$(git -C "$LEAK_ROOT" log -1 --format=%H -- docs/review-rubric.md)
  pinned_raw="https://raw.githubusercontent.com/owner/repo/$rev/docs/review-rubric.md"
  pinned_blob="https://github.com/owner/repo/blob/$rev/docs/review-rubric.md"
  wr="$TMP_ROOT/work/$(basename "$(dirname "$LEAK_PACK")")-$(basename "$LEAK_PACK")"
  mkdir -p "$wr"
  printf 'own report\n' >"$wr/review.md"
  printf 'own log\n' >"$LEAK_PACK/review-run.log"
  mkdir -p "$LEAK_PACK/omp-session"
  clean_transcript "$LEAK_PACK/omp-session/s.jsonl"
  printf 'report\n' >"$LEAK_PACK/review.md"
  # Compliant: the pinned rubric by either URL form, the run's own report and log, and the work-root report.
  write_report "$rep" "$LEAK_PACK/contract.md" "$pinned_raw" "$pinned_blob" "$LEAK_PACK/review.md" "$LEAK_PACK/review-run.log" "$wr/review.md"
  # the report under test is the pack's review.md, so write the list there
  cp "$rep" "$LEAK_PACK/review.md"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_FM_ROOT="$LEAK_ROOT" REVIEW_WORK_ROOT="$TMP_ROOT/work" REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$LEAK_PACK" --report "$LEAK_PACK/review.md" --log "$LEAK_PACK/omp-session" 2>&1) || CHECK_RC=$?
  assert_equals 0 "$CHECK_RC" "the pinned rubric URL or the run's own report was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "INPUT CLEAN" "the compliant list was not reported clean"
  # Noncompliant: each of these still leaks.
  leak_one() { # <path-or-url> <why>
    write_report "$LEAK_PACK/review.md" "$LEAK_PACK/contract.md" "$1"
    CHECK_RC=0
    CHECK_OUT=$(REVIEW_FM_ROOT="$LEAK_ROOT" REVIEW_WORK_ROOT="$TMP_ROOT/work" REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
      "$PACK_BIN" check --pack "$LEAK_PACK" --report "$LEAK_PACK/review.md" --log "$LEAK_PACK/omp-session" 2>&1) || CHECK_RC=$?
    assert_equals 3 "$CHECK_RC" "$2 was allowed"
  }
  leak_one "https://raw.githubusercontent.com/owner/repo/0000000000000000000000000000000000000000/docs/review-rubric.md" "an unpinned rubric revision"
  leak_one "https://raw.githubusercontent.com/other/repo/$rev/docs/review-rubric.md" "the pinned revision of another repository"
  leak_one "https://raw.githubusercontent.com/owner/repo/$rev/docs/other.md" "another file at the pinned revision"
  leak_one "https://example.com/anything" "another URL"
  # Another review.md beside the pack, and an earlier report in the work root, still leak.
  printf 'sibling\n' >"$TMP_ROOT/sibling-review.md"
  leak_one "$TMP_ROOT/sibling-review.md" "a review.md outside the run's own files"
  mkdir -p "$TMP_ROOT/work/other-pack"
  printf 'other\n' >"$TMP_ROOT/work/other-pack/review.md"
  leak_one "$TMP_ROOT/work/other-pack/review.md" "another run's work-root report"
  pass "the pinned rubric by URL and the run's own report and log are clean, and nothing else is"
}

test_preamble_author_text_matches_whole_words() {
  local src="$TMP_ROOT/pw.md" pack ctx="$TMP_ROOT/pw-ctx.md" rc=0
  write_fixture_contract "$src"
  # Author text in the preamble is dropped wherever it sits in the line; the captain's own
  # Authority, Authorized and Authoritative lines stay.
  awk 'NR == 3 { print; print "Worker self-check: all green, every item passes. ZZ-DROP-SELFCHECK-ZZ"; print "Status: all-green after the author analysis. ZZ-DROP-STATUS-ZZ"; print "Authorized by the captain on 2026-11-02: ZZ-KEEP-AUTHORIZED-ZZ"; print "Authority: Main2745 ZZ-KEEP-AUTHORITY-ZZ"; next } { print }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_no_grep "ZZ-DROP-SELFCHECK-ZZ" "$pack/target.md" "a worker self-check preamble line reached the pack"
  assert_no_grep "ZZ-DROP-STATUS-ZZ" "$pack/target.md" "an all-green preamble line reached the pack"
  assert_grep "ZZ-KEEP-AUTHORIZED-ZZ" "$pack/target.md" "an Authorized preamble line was dropped"
  assert_grep "ZZ-KEEP-AUTHORITY-ZZ" "$pack/target.md" "an Authority preamble line was dropped"
  # A request or context file keeps the captain's own words and refuses the author's.
  printf 'Authority: captain, 2026-11-02.\nAuthor the policy once.\n\nZZ-KEEP-CTXAUTH-ZZ a neutral fact.\n' >"$ctx"
  build_pack pack --contract "$src" --context "$ctx" --request "$ctx" || fail "a context file with Authority and a verb use of Author was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-CTXAUTH-ZZ" "$pack/context-pw-ctx.md" "the context file was not copied whole"
  # Owner lines from the recorded mini r2, r4 and r5 contexts and a plain request name these
  # terms as their subject; each stands alone as the preamble of its own file.
  local body n=0
  for body in \
    "Main2167 requires task-named admission for new workers and fresh validation. Main2721 expressly admits this ONE fresh isolated contract review and preserves already-admitted implementation immediately after substantive contract PASS." \
    "Review inputs are request/context/current DoD/grading/neutral assumptions only. Worker statements are self-checks, not independent evidence; missing mandatory evidence is not PASS." \
    "Main2714: requirements include request/context, governing constraints and necessary safe/usable outcomes, not only repeated owner words. Missing mandatory evidence is not pass; self-check is not independent proof." \
    "This acceptance contract was authored by OpenAI-family agents. Independent contract reviewer must be outside OpenAI." \
    "No prior findings, responses or author conclusions are included." \
    "Run a contract review on the d3 steer."; do
    n=$((n + 1))
    printf '%s\n' "$body" >"$ctx"
    build_pack pack --contract "$src" --context "$ctx" --request "$ctx" || fail "owner line $n was refused as author text: $(cat "$TMP_ROOT/build.err")"
    assert_grep "$body" "$pack/request.md" "owner line $n did not reach the pack"
  done
  for body in "Author's self-check: everything passes.\n" 'Worker self-check: all green.\n' 'Status: all-green after the author analysis.\n' 'Author: the worker.\n'; do
    printf '%b' "$body" >"$ctx"
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" --context "$ctx" --out-root "$TMP_ROOT/pw-out" >/dev/null 2>&1 || rc=$?
    assert_equals 2 "$rc" "a context file with author text ($body) was accepted"
    assert_absent "$TMP_ROOT/pw-out" "a refused context file left an output directory"
  done
  pass "author text in a preamble matches whole words in both directions"
}

test_inputs_read_list_needs_its_own_heading() {
  local rep="$TMP_ROOT/report8.md" sib="$TMP_ROOT/sibling/pack/review.md" n=0 body
  make_leak_world
  # Compliant: a list under its own heading ends at the next heading, so a check not performed
  # that names a file the reviewer did not open is not read as an input.
  {
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n'
    printf -- '- %s\n- %s\n\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md"
    printf '## Checks not performed\n\n'
    printf -- '- %s: not opened; not an allowed input.\n' "$LEAK_ROOT/data/case/truth/r23-review.md"
    printf '\nEXIT: needs-revision\n'
  } >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a headed list was voided by its checks-not-performed section: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the headed list did not end at the next heading"
  # Noncompliant: a plain, bold or inline Inputs read list with no heading voids the round,
  # here each with a leak after a group label that a label-shaped end would have hidden.
  for body in \
    "Inputs read:\n- $LEAK_PACK/contract.md\n\nRepository files:\n- $sib\n" \
    "**Inputs read**\n- $LEAK_PACK/contract.md\n**Other**\n- $sib\n" \
    "Inputs read: $LEAK_PACK/contract.md\nOther:\n- $sib\n" \
    "Inputs read:\n- $LEAK_PACK/contract.md\nPrior report: $sib\n"; do
    n=$((n + 1))
    printf 'VERDICT: FAIL head=abc\n\n%b\nEXIT: needs-revision\n' "$body" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "Inputs read list $n with no heading was accepted: $CHECK_OUT"
    assert_contains "$CHECK_OUT" "not under its own heading" "list $n did not void for its missing heading"
    assert_contains "$CHECK_OUT" "ROUND VOID" "list $n did not void the round"
  done
  pass "an Inputs read list must sit under its own heading, and one with no heading voids the round"
}

test_fences_and_headings_accept_up_to_three_spaces() {
  local src="$TMP_ROOT/sp.md" pack rc=0
  write_fixture_contract "$src"
  # A fence closed by an indented marker must not swallow the author section after it.
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "```text"; print "ZZ-KEEP-FENCED-ZZ"; print "  ```"; print ""; print "## Author'"'"'s all-green candidate"; print ""; print "ZZ-ALLGREEN-IND-ZZ"; print ""; print "```bash"; print "echo ok"; print "```" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-FENCED-ZZ" "$pack/target.md" "text inside the fence was dropped"
  assert_no_grep "ZZ-ALLGREEN-IND-ZZ" "$pack/target.md" "an author section after an indented closing fence reached the pack"
  # An indented opening fence hides a heading-shaped line, and an indented heading is a heading.
  write_fixture_contract "$src"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "   ~~~"; print "## Contract Review inside an indented fence"; print "   ~~~"; print ""; print "  ## Boundary dispositions"; print ""; print "ZZ-INDENTED-HEAD-ZZ" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "## Contract Review inside an indented fence" "$pack/target.md" "a heading-shaped line inside an indented fence was treated as a heading"
  assert_no_grep "ZZ-INDENTED-HEAD-ZZ" "$pack/target.md" "an author section under an indented heading reached the pack"
  # Four spaces is code text, not a heading: it stays where it is.
  write_fixture_contract "$src"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "    ## Boundary dispositions"; print "ZZ-CODE-INDENT-ZZ" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-CODE-INDENT-ZZ" "$pack/target.md" "an indented code line was read as a heading"
  # An indented fence that never closes still stops the build.
  write_fixture_contract "$src"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "  ```text"; print "never closed" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/sp-out" >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" "an unclosed indented fence did not stop the build"
  pass "fences and headings accept up to three leading spaces and four spaces is code"
}

test_request_or_context_with_author_history_heading_refused() {
  local src="$TMP_ROOT/hh.md" in="$TMP_ROOT/hh-in.md" pack rc n=0 case flag body
  write_fixture_contract "$src"
  # Compliant: free owner headings from the recorded mini r2 context still build.
  printf '# Current authoritative amendments and neutral context\n\n## Main2632 \342\200\224 exact routed amendment\n\nZZ-KEEP-AMEND-ZZ owner text.\n\n## Current review authority\n\nMain2648 admits one fresh review; priority 0.\n' >"$in"
  build_pack pack --contract "$src" --context "$in" --request "$in" || fail "free owner headings were refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-AMEND-ZZ" "$pack/context-hh-in.md" "the owner context was not copied whole"
  # Noncompliant: an unrecognised heading that names author history, at the top level or as a
  # sub-heading of a kept section, refuses the request or context file.
  for case in 'context:# Owner context\n\n## Context\n\nneutral\n\n## Earlier findings and how I answered them\n\nZZ-PRIOR-CTX-ZZ F1 answered.\n' \
    'request:# Request\n\nThe owner wants a thing.\n\n## My earlier findings\n\nZZ-PRIOR-REQ-ZZ\n' \
    'context:# Owner context\n\n## Context\n\nneutral\n\n### What the reviewer said and my response\n\nZZ-PRIOR-SUB-ZZ\n'; do
    n=$((n + 1))
    flag=--${case%%:*}
    body=${case#*:}
    printf '%b' "$body" >"$in"
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/hh-out$n" >/dev/null 2>"$TMP_ROOT/hh.err" || rc=$?
    assert_equals 3 "$rc" "$flag file $n with an author-history heading was accepted"
    assert_contains "$(cat "$TMP_ROOT/hh.err")" "unrecognised section:" "$flag file $n refusal does not name the section"
    assert_absent "$TMP_ROOT/hh-out$n" "a refused $flag file $n left an output directory"
  done
  pass "a request or context file whose unrecognised heading names author history is refused, and free owner headings build"
}

test_recognised_heading_with_author_history_refused() {
  local src="$TMP_ROOT/rh.md" in="$TMP_ROOT/rh-in.md" pack rc flag
  # Compliant: a kept heading with no author-history term builds in the contract, the request
  # and a context file.
  write_fixture_contract "$src"
  awk '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "## Context (prior art)"; print ""; print "ZZ-KEEP-PRIORART-ZZ earlier tools." }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  printf '# Owner context\n\n## Context (prior art)\n\nZZ-KEEP-CTXART-ZZ earlier tools.\n' >"$in"
  build_pack pack --contract "$src" --request "$in" --context "$in" || fail "a kept heading with no author-history term was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-PRIORART-ZZ" "$pack/target.md" "the prior-art section was dropped from the contract"
  assert_grep "ZZ-KEEP-CTXART-ZZ" "$pack/request.md" "the prior-art request was not copied whole"
  # Noncompliant: a recognised heading that names author history refuses the contract, the
  # request and a context file, and writes no pack.
  write_fixture_contract "$src"
  awk '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "## Context and earlier findings"; print ""; print "ZZ-C-ZZ F1 answered; the all-green check passes." }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/rh-c" >/dev/null 2>"$TMP_ROOT/rh.err" || rc=$?
  assert_equals 3 "$rc" "a contract with a recognised author-history heading was accepted"
  assert_contains "$(cat "$TMP_ROOT/rh.err")" "unrecognised section: Context and earlier findings" "the contract refusal does not name the section"
  assert_absent "$TMP_ROOT/rh-c" "a refused contract left an output directory"
  write_fixture_contract "$src"
  printf '# Owner context\n\n## Context and earlier findings\n\nZZ-C-ZZ F1 answered.\n' >"$in"
  for flag in --request --context; do
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/rh$flag" >/dev/null 2>"$TMP_ROOT/rh.err" || rc=$?
    assert_equals 3 "$rc" "a $flag file with a recognised author-history heading was accepted"
    assert_contains "$(cat "$TMP_ROOT/rh.err")" "unrecognised section: Context and earlier findings" "the $flag refusal does not name the section"
    assert_absent "$TMP_ROOT/rh$flag" "a refused $flag file left an output directory"
  done
  pass "a recognised heading that names author history is refused in a contract, request or context file"
}

test_author_history_in_every_heading_position_refused() {
  local src="$TMP_ROOT/hp.md" in="$TMP_ROOT/hp-in.md" pack rc n=0 case kind body flag
  write_fixture_contract "$src"
  # Compliant: each position with a heading free of author history still builds.
  printf '# Owner context\n\n## Context (prior art)\n\nZZ-KEEP-HP1-ZZ\n' >"$in"
  build_pack pack --contract "$src" --context "$in" || fail "a kept prior-art heading in a context file was refused: $(cat "$TMP_ROOT/build.err")"
  printf '# Owner context\n\n## Owner background\n\n### Context (prior art)\n\nZZ-KEEP-HP2-ZZ\n' >"$in"
  build_pack pack --contract "$src" --context "$in" || fail "a kept level 3 heading under an unrecognised parent was refused: $(cat "$TMP_ROOT/build.err")"
  printf '# Context (prior art)\n\nZZ-KEEP-HP3-ZZ\n' >"$in"
  build_pack pack --contract "$src" --request "$in" || fail "a kept first title in a request file was refused: $(cat "$TMP_ROOT/build.err")"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "### Context (prior art)"; print ""; print "ZZ-KEEP-HP4-ZZ" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "a kept level 3 heading in a contract was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-HP4-ZZ" "$pack/target.md" "the kept level 3 section was dropped"
  # Noncompliant: an unrecognised heading with prior before a history noun, a recognised level 3 heading under
  # a kept or an unrecognised parent, and a recognised first title, each naming author history.
  for case in \
    'context|# Owner context\n\n## My prior round and fixes\n\nZZ-X-ZZ text.\n' \
    'context|# Owner context\n\n## Owner background\n\n### Context and earlier findings\n\nZZ-A-ZZ F1 answered; all-green.\n' \
    'request|# Context and earlier findings\n\nZZ-B-ZZ F1 answered.\n' \
    'contract|' \
    'contract-title|'; do
    n=$((n + 1))
    kind=${case%%|*}
    body=${case#*|}
    rc=0
    case $kind in
      contract)
        write_fixture_contract "$src"
        awk '{ print } /^- \*\*A1\*\*/ { print ""; print "### Context and earlier findings"; print ""; print "ZZ-C3-ZZ F1 answered." }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
        "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/hp-out$n" >/dev/null 2>"$TMP_ROOT/hp.err" || rc=$?
        ;;
      contract-title)
        write_fixture_contract "$src"
        awk 'NR == 1 { print "# Context and earlier findings: answered"; next } { print }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
        "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/hp-out$n" >/dev/null 2>"$TMP_ROOT/hp.err" || rc=$?
        ;;
      *)
        write_fixture_contract "$src"
        flag=--$kind
        printf '%b' "$body" >"$in"
        "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/hp-out$n" >/dev/null 2>"$TMP_ROOT/hp.err" || rc=$?
        ;;
    esac
    assert_equals 3 "$rc" "case $n ($kind) with author history in a heading was accepted"
    assert_contains "$(cat "$TMP_ROOT/hp.err")" "unrecognised section:" "case $n ($kind) refusal does not name the section"
    assert_absent "$TMP_ROOT/hp-out$n" "a refused case $n ($kind) left an output directory"
  done
  pass "author history is refused in every recognised heading position and in an unrecognised heading"
}

test_prior_counts_only_before_a_history_noun() {
  local src="$TMP_ROOT/pr.md" in="$TMP_ROOT/pr-in.md" pack rc flag heading manifest
  write_fixture_contract "$src"
  # Compliant: a prior-art section with a sub-heading and a bold-only line builds in a request
  # and a context file, and in a contract.
  printf '# Owner context\n\n## Context (prior art)\n\n### Current owner ruling\n\n**Owner note**\n\nZZ-KEEP-PRIORART-ZZ neutral.\n' >"$in"
  build_pack pack --contract "$src" --request "$in" --context "$in" || fail "a prior-art section with a sub-heading was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-PRIORART-ZZ" "$pack/request.md" "the prior-art request was not copied whole"
  awk '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "## Context (prior art)"; print ""; print "### Current owner ruling"; print ""; print "ZZ-KEEP-PRIORART-C-ZZ" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "a prior-art contract section with a sub-heading was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-PRIORART-C-ZZ" "$pack/target.md" "the prior-art contract section was dropped"
  # Noncompliant: prior followed by a history noun keeps the section out of every input.
  for heading in 'Prior findings' 'Prior review notes'; do
    write_fixture_contract "$src"
    printf '# Owner context\n\n## %s\n\nZZ-PRIOR-HIST-ZZ F1 answered.\n' "$heading" >"$in"
    for flag in --request --context; do
      rc=0
      "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/pr-out" >/dev/null 2>"$TMP_ROOT/pr.err" || rc=$?
      [ "$rc" != 0 ] || fail "a $flag file with '## $heading' was accepted"
      assert_absent "$TMP_ROOT/pr-out" "a refused $flag file with '## $heading' left an output directory"
    done
    # A contract drops the recognised author section and lists it; under a kept heading it refuses.
    awk -v h="$heading" '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "## " h; print ""; print "ZZ-PRIOR-HIST-ZZ F1 answered." }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
    build_pack pack --contract "$src" || fail "a contract with '## $heading' was refused: $(cat "$TMP_ROOT/build.err")"
    manifest="$(dirname "$pack").excluded-paths"
    assert_no_grep "ZZ-PRIOR-HIST-ZZ" "$pack/target.md" "the '## $heading' section reached the pack"
    grep -qxF "$(printf 'dropped\t%s' "$heading")" "$manifest" || fail "the '## $heading' section is not listed as dropped"
    write_fixture_contract "$src"
    awk -v h="$heading" '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "## Context: " h; print ""; print "ZZ-PRIOR-HIST-ZZ F1 answered." }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/pr-out" >/dev/null 2>"$TMP_ROOT/pr.err" || rc=$?
    assert_equals 3 "$rc" "a contract with '## Context: $heading' was accepted"
    assert_absent "$TMP_ROOT/pr-out" "a refused contract left an output directory"
  done
  pass "prior counts as author history only before a history noun"
}

test_prior_revisions_heading_refused() {
  local src="$TMP_ROOT/rv.md" in="$TMP_ROOT/rv-in.md" pack rc flag
  write_fixture_contract "$src"
  # Compliant: a kept heading that names revisions without "prior" builds.
  printf '# Owner context\n\n## Context: revisions to the schema\n\nZZ-KEEP-RV-ZZ\n' >"$in"
  build_pack pack --contract "$src" --request "$in" --context "$in" || fail "a kept revisions heading was refused: $(cat "$TMP_ROOT/build.err")"
  # Noncompliant: "Context: prior revisions" refuses in a contract, a request and a context file.
  awk '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "## Context: prior revisions"; print ""; print "ZZ-REV-ZZ rev 3 answered F1 by cutting E1." }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/rv-out" >/dev/null 2>"$TMP_ROOT/rv.err" || rc=$?
  assert_equals 3 "$rc" "a contract with 'Context: prior revisions' was accepted"
  assert_absent "$TMP_ROOT/rv-out" "a refused contract left an output directory"
  write_fixture_contract "$src"
  printf '# Owner context\n\n## Context: prior revisions\n\nZZ-REV-ZZ rev 3 answered.\n' >"$in"
  for flag in --request --context; do
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/rv-out" >/dev/null 2>"$TMP_ROOT/rv.err" || rc=$?
    assert_equals 3 "$rc" "a $flag file with 'Context: prior revisions' was accepted"
    assert_absent "$TMP_ROOT/rv-out" "a refused $flag file left an output directory"
  done
  pass "prior revisions is author history in every input"
}

test_author_history_heading_under_unrecognised_parent_or_title_refused() {
  local src="$TMP_ROOT/up.md" in="$TMP_ROOT/up-in.md" pack rc n=0 case flag body
  write_fixture_contract "$src"
  # Compliant: a neutral sub-heading, bold line and title in a free owner file build.
  printf '# Owner context\n\n## Main2632 routed amendment\n\n### Current owner ruling\n\n**Owner note**\n\nZZ-KEEP-UP-ZZ\n' >"$in"
  build_pack pack --contract "$src" --request "$in" --context "$in" || fail "neutral owner headings were refused: $(cat "$TMP_ROOT/build.err")"
  # Noncompliant: author history under an unrecognised parent, or as the file's title.
  for case in \
    'context|# Owner context\n\n## Main2632 routed amendment\n\n### My earlier findings and how I answered them\n\nZZ-A-ZZ F1 answered: fixed.\n' \
    'context|# Owner context\n\n## Background\n\n**Earlier findings and my responses**\n\nZZ-E-ZZ F1 answered.\n' \
    'context|# Earlier findings and how I answered them\n\nZZ-B-ZZ F1 was answered in rev 3.\n' \
    'request|# Earlier findings and how I answered them\n\nZZ-B-ZZ F1 was answered in rev 3.\n'; do
    n=$((n + 1))
    flag=--${case%%|*}
    body=${case#*|}
    printf '%b' "$body" >"$in"
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/up-out$n" >/dev/null 2>"$TMP_ROOT/up.err" || rc=$?
    assert_equals 3 "$rc" "case $n ($flag) with an author-history heading was accepted"
    assert_contains "$(cat "$TMP_ROOT/up.err")" "author history" "case $n ($flag) refusal does not name the cause"
    assert_absent "$TMP_ROOT/up-out$n" "a refused case $n left an output directory"
  done
  pass "author history under an unrecognised parent or in a file's title is refused"
}

test_title_is_not_the_definition_of_done() {
  local src="$TMP_ROOT/td.md" pack rc=0
  # Noncompliant: a title that names the Definition Of Done is not a Definition Of Done section.
  printf '# Definition Of Done: d3 steer\n\n## REQUEST\n\nA request.\n' >"$src"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/td-out" >/dev/null 2>"$TMP_ROOT/td.err" || rc=$?
  assert_equals 2 "$rc" "a contract whose only Definition Of Done is its title was accepted"
  assert_contains "$(cat "$TMP_ROOT/td.err")" "no Definition Of Done section" "the refusal names another cause"
  assert_absent "$TMP_ROOT/td-out" "a refused contract left an output directory"
  # Compliant: the same title over a real Definition Of Done section builds.
  printf '# Definition Of Done: d3 steer\n\n## REQUEST\n\nA request.\n\n## Definition Of Done\n\n- A1 (mandatory): ZZ-KEEP-TD-ZZ\n' >"$src"
  build_pack pack --contract "$src" || fail "a contract with a Definition Of Done section was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-TD-ZZ" "$pack/target.md" "the Definition Of Done text is missing"
  pass "the title is not counted as the Definition Of Done section"
}

test_leak_check_reads_through_fences_and_setext_headings() {
  local rep="$TMP_ROOT/report10.md" sib="$TMP_ROOT/sibling/pack/review.md"
  make_leak_world
  # Compliant: a fence with a # comment inside the list, and a later mention of Inputs read.
  {
    # shellcheck disable=SC2016 # literal backticks in generated Markdown
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n\n```sh\n# from shell\n```\n\n- %s\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md"
    printf '\n## Basis\n\nInputs read: as listed above.\n\nEXIT: needs-revision\n'
  } >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a clean list with a fence or a later mention was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the list was not read past the fence"
  # Noncompliant: a leak after the fenced # comment is still read.
  {
    # shellcheck disable=SC2016 # literal backticks in generated Markdown
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n\n```sh\n# from shell\n```\n\n- %s\n' "$LEAK_PACK/contract.md" "$sib"
    printf '\n## Findings\n\nEXIT: needs-revision\n'
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak after a fenced # comment was allowed"
  assert_contains "$CHECK_OUT" "INPUT LEAK: $sib" "the leak after the fence is not named"
  # Compliant: a setext Inputs read heading is a heading of its own.
  printf 'VERDICT: FAIL head=abc\n\nInputs read\n-----------\n\n- %s\n\nFindings\n--------\n\n- %s is fine.\n' "$LEAK_PACK/contract.md" "$sib" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a list under a setext heading was voided: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "1 listed input(s)" "the setext list did not end at the next setext heading"
  # Noncompliant: a leak under a setext heading is read.
  printf 'VERDICT: FAIL head=abc\n\nInputs read\n===========\n\n- %s\n- %s\n' "$LEAK_PACK/contract.md" "$sib" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak under a setext heading was allowed"
  pass "the leak check reads through fences, accepts a setext heading and ignores a bare mention"
}

test_leak_check_voids_a_second_path_on_a_line() {
  local rep="$TMP_ROOT/report11.md" sib="$TMP_ROOT/sibling/pack/review.md" second
  make_leak_world
  # Compliant: one full path per line, and prose with a slash, are clean.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- %s\n- read and/or compared\n\n## Findings\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "one path per line was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "a path line was not read"
  # Noncompliant: a second path on a line voids for structure, whether or not it is allowed.
  for second in "$LEAK_PACK/target.md" "$sib"; do
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s, %s\n\n## Findings\n' "$LEAK_PACK/contract.md" "$second" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "a second path ($second) on a line was accepted"
    assert_contains "$CHECK_OUT" "REPORT STRUCTURE" "a second path on a line did not void for structure"
  done
  pass "a list line holds one full path, and a second path voids the round"
}

test_leak_check_reads_a_path_above_a_rule_or_hash_line() {
  local rep="$TMP_ROOT/report12.md" sib="$TMP_ROOT/sibling/pack/review.md"
  make_leak_world
  # Compliant: bare paths with a rule under the last one, and a #-note that is not a heading.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n%s\n%s\n---\n\nEXIT: needs-revision\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a clean list with a rule under its last path was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the path above the rule was not read"
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n#1 note\n- %s\n\n## Findings\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a clean list with a #-note was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the list ended at a #-note"
  # Noncompliant: a leak directly above a rule, and a leak after a #-note, are read.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n%s\n%s\n---\n\nEXIT: needs-revision\n' "$LEAK_PACK/contract.md" "$sib" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak directly above a rule was allowed"
  assert_contains "$CHECK_OUT" "INPUT LEAK: $sib" "the leak above the rule is not named"
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n#1 note\n- %s\n\n## Findings\n' "$LEAK_PACK/contract.md" "$sib" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak after a #-note was allowed"
  pass "a path above a rule line, or after a #-note, is still read"
}

test_leak_check_voids_a_path_that_is_not_the_leading_entry() {
  local rep="$TMP_ROOT/report13.md" sib="$TMP_ROOT/sibling/pack/review.md" body n=0
  make_leak_world
  # Compliant: each line leads with one full path (with a line reference or a revision), or holds none.
  {
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- HEAD:bin/fm-spawn.sh\n' "$LEAK_PACK/contract.md"
    printf -- '- bin/fm-spawn.sh\n- notes/plan.md:12\n- read and/or skimmed\n\n## Findings\n'
  } >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "leading full paths were flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "4 listed input(s)" "a leading path was not read"
  # Noncompliant: a path that is not the line's leading entry voids for structure, never clean.
  for body in "- Sibling report: $sib" "- also read $sib for context" "| $sib | read |" \
    "- $LEAK_PACK/contract.md, https://example.com/review.md" "- $LEAK_PACK/contract.md, main:docs/x.md" \
    "- Sibling report: data/case/truth/r23-review.md" "- also read data/case/truth/r23-review.md" \
    "| data/case/truth/r23-review.md | read |" "- Pack: ../tmp.other/pack/review.md" \
    "- also see:$sib" "- ran cat --file=$sib" "- also _${sib}_" "- also {$sib}" \
    "- Findings in target.md:12 were checked against bin/fm-spawn.sh"; do
    n=$((n + 1))
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n%s\n\n## Findings\n' "$LEAK_PACK/target.md" "$body" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "list line $n ($body) was accepted"
    assert_contains "$CHECK_OUT" "REPORT STRUCTURE" "list line $n ($body) did not void for structure"
  done
  pass "a path that is not a line's one leading entry voids the round for structure"
}

test_summary_mention_of_inputs_read_is_not_a_list() {
  local rep="$TMP_ROOT/report14.md"
  make_leak_world
  # Compliant: a summary bullet that mentions Inputs read, then the headed list.
  printf 'VERDICT: FAIL head=abc\n\n## Summary\n\n- Inputs read: see the section below.\n- Identity: Terra\n\n## Inputs read\n\n- %s\n\n## Findings\n' "$LEAK_PACK/contract.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a summary mention of Inputs read voided the round: $CHECK_OUT"
  # Noncompliant: a bold Inputs read label followed by a path is a list with no heading.
  printf 'VERDICT: FAIL head=abc\n\n**Inputs read**\n- %s\n\n## Inputs read\n\n- %s\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/contract.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a bold Inputs read list with no heading was accepted"
  assert_contains "$CHECK_OUT" "not under its own heading" "the headless list did not void for its cause"
  pass "a passing mention of Inputs read is not a list, and a headless list still voids"
}

test_author_section_title_drops() {
  local src="$TMP_ROOT/at.md" pack manifest
  # Noncompliant: a first title that names an author section is dropped with its text.
  printf "# Author's all-green candidate\n\nZZ-ALLGREEN-T-ZZ all pass.\n\n## REQUEST\n\nA request.\n\n## Definition Of Done\n\n- A1 (mandatory): x\n" >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  manifest="$(dirname "$pack").excluded-paths"
  assert_no_grep "ZZ-ALLGREEN-T-ZZ" "$pack/target.md" "an author-section title kept its text"
  grep -qxF "$(printf "dropped\tAuthor's all-green candidate")" "$manifest" || fail "the author-section title is not listed as dropped"
  printf '### Note\n\n# Contract Review\n\nZZ-HIST-T-ZZ r3 F1.\n\n## Definition Of Done\n\n- A1 (mandatory): x\n' >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_no_grep "ZZ-HIST-T-ZZ" "$pack/target.md" "a Contract Review title after a level 3 heading kept its text"
  # Compliant: a free title keeps its preamble.
  printf '# Fixture contract\n\nZZ-KEEP-T-ZZ preamble.\n\n## Definition Of Done\n\n- A1 (mandatory): x\n' >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-T-ZZ" "$pack/target.md" "a free title lost its preamble"
  pass "a first title that names an author section drops with its text"
}

test_author_section_under_any_heading_of_request_or_context_refused() {
  local src="$TMP_ROOT/ah.md" in="$TMP_ROOT/ah-in.md" pack rc heading n=0
  write_fixture_contract "$src"
  # Compliant: a neutral bold label and a prior-art section build.
  printf '# Owner context\n\n## Context (prior art)\n\n**Review scope**\n\nZZ-KEEP-AH-ZZ\n' >"$in"
  build_pack pack --contract "$src" --request "$in" --context "$in" || fail "neutral owner headings were refused: $(cat "$TMP_ROOT/build.err")"
  # Noncompliant: an author section as a level 4 or bold heading, or as the file title.
  for heading in "#### Contract Review" "**Contract Review**" "#### Author's analysis" "**Author's notes**" \
    "#### Revision history" "**Review history**" "#TITLE Contract Review" "#TITLE Author's analysis" \
    "#TITLE Review history" "#TITLE Revision history" "#TITLE Register"; do
    n=$((n + 1))
    case $heading in
      "#TITLE "*) printf '# %s\n\nZZ-CTX-ZZ F1 was closed.\n' "${heading#\#TITLE }" >"$in" ;;
      *) printf '# Owner\n\n## Context\n\n%s\n\nZZ-CTX-ZZ F1 was closed.\n' "$heading" >"$in" ;;
    esac
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" --context "$in" --out-root "$TMP_ROOT/ah-out$n" >/dev/null 2>"$TMP_ROOT/ah.err" || rc=$?
    assert_equals 2 "$rc" "a context file with '$heading' was accepted"
    assert_contains "$(cat "$TMP_ROOT/ah.err")" "author text" "the '$heading' refusal does not name the cause"
    assert_absent "$TMP_ROOT/ah-out$n" "a refused context file left an output directory"
  done
  pass "an author section under any heading of a request or context file is refused"
}

test_exact_section_title_counts_as_a_section() {
  local src="$TMP_ROOT/es.md" pack rc=0
  # Compliant: a title that is exactly a section name counts as that section.
  printf '# Definition Of Done\n\n- A1 (mandatory): ZZ-KEEP-ES-ZZ x\n' >"$src"
  build_pack pack --contract "$src" || fail "a Definition Of Done title was refused: $(cat "$TMP_ROOT/build.err")"
  printf '# REQUEST\n\nThe owner wants a thing.\n\n# Definition Of Done\n\n- A1 (mandatory): x\n' >"$src"
  build_pack pack --contract "$src" || fail "a REQUEST title was refused: $(cat "$TMP_ROOT/build.err")"
  # shellcheck disable=SC2016 # literal backticks in generated Markdown
  assert_grep 'the request is the REQUEST section of `target.md`' "$pack/contract.md" "a REQUEST title was not named as the request"
  # Noncompliant: a prefixed title is not the section.
  printf '# Definition Of Done: d3 steer\n\n## REQUEST\n\nA request.\n' >"$src"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/es-out" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a prefixed Definition Of Done title counted as the section"
  pass "a title counts as a section only when it is exactly the section name"
}

test_exact_section_title_keeps_its_text() {
  local src="$TMP_ROOT/et.md" pack manifest
  # Compliant: criteria and a request under an exact section title stay, whatever words they use.
  printf '# Definition Of Done\n\n- E3 (mandatory): ZZ-KEEP-E3-ZZ a worker self-check is not verification\n- A2 (mandatory): ZZ-KEEP-A2-ZZ the author names the head\n' >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-E3-ZZ" "$pack/target.md" "a criterion under a Definition Of Done title was dropped"
  assert_grep "ZZ-KEEP-A2-ZZ" "$pack/target.md" "a criterion naming the author under a Definition Of Done title was dropped"
  printf '# REQUEST\n\nZZ-KEEP-RQ-ZZ Run a contract review of the steer; the author must not see it.\n\n## Definition Of Done\n\n- A1 (mandatory): x\n' >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-KEEP-RQ-ZZ" "$pack/target.md" "the request under a REQUEST title was dropped"
  # Noncompliant: the same author line under a free title is preamble and is dropped and listed.
  printf '# Fixture contract\n\nZZ-DROP-PRE-ZZ a worker self-check says all pass.\n\n## Definition Of Done\n\n- A1 (mandatory): x\n' >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  manifest="$(dirname "$pack").excluded-paths"
  assert_no_grep "ZZ-DROP-PRE-ZZ" "$pack/target.md" "an author preamble line under a free title reached the pack"
  assert_grep "preamble line: ZZ-DROP-PRE-ZZ" "$manifest" "the dropped preamble line is not listed"
  pass "an exact section title keeps its text, and a free title's preamble is still filtered"
}

test_report_field_under_a_label_voids_as_structure() {
  local rep="$TMP_ROOT/report15.md"
  make_leak_world
  # Compliant: Checks not performed under its own heading names a not-allowed file.
  printf 'VERDICT: INCOMPLETE head=abc\n\n## Inputs read\n\n- %s\n\n## Checks not performed\n\n- A1 needs %s, which is not an allowed input; not opened.\n\nEXIT: needs-revision\n' "$LEAK_PACK/target.md" "$LEAK_ROOT/data/case/truth/r23-review.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a compliant incomplete report was voided: $CHECK_OUT"
  # Noncompliant: the same field under a bold label voids for structure, not as a leak.
  printf 'VERDICT: INCOMPLETE head=abc\n\n## Inputs read\n\n- %s\n\n**Checks not performed**\n- A1 needs %s, which is not an allowed input; not opened.\n\nEXIT: needs-revision\n' "$LEAK_PACK/target.md" "$LEAK_ROOT/data/case/truth/r23-review.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a report field under a bold label was accepted"
  assert_contains "$CHECK_OUT" "report field not under its own heading" "the structure cause is not named"
  assert_not_contains "$CHECK_OUT" "INPUT LEAK" "a structure fault was reported as a leak"
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\nNotes: none.\n' "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a Notes label inside the list was accepted"
  # Noncompliant: any other report field under a bold label right after the list voids for structure.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n**Criterion judgments**\n- A1: unjudged; it needs data/case/truth/r23-review.md, which is not an allowed input.\n\n## Checks not performed\n\nnone\n' "$LEAK_PACK/contract.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a criterion field under a bold label was accepted"
  assert_contains "$CHECK_OUT" "report field not under its own heading" "the criterion field did not void for structure"
  assert_not_contains "$CHECK_OUT" "INPUT LEAK" "the criterion field was reported as a leak"
  # Noncompliant: a real leak under the Inputs read heading is still a leak.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- %s\n\n## Checks not performed\n\nnone\n' "$LEAK_PACK/target.md" "$LEAK_ROOT/data/case/truth/r23-review.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a leak under the Inputs read heading was allowed"
  assert_contains "$CHECK_OUT" "INPUT LEAK" "a leak was not reported as a leak"
  pass "a report field under a label voids for structure, and a listed leak is still a leak"
}

test_exact_title_in_request_or_context_keeps_the_author_check() {
  local src="$TMP_ROOT/xc.md" in="$TMP_ROOT/xc-in.md" pack rc title flag
  write_fixture_contract "$src"
  for title in Context Request; do
    # Compliant: an exact section title over a neutral owner line builds.
    printf '# %s\n\nZZ-KEEP-XC-ZZ the owner wants a thing.\n' "$title" >"$in"
    build_pack pack --contract "$src" --request "$in" --context "$in" || fail "a '# $title' file with an owner line was refused: $(cat "$TMP_ROOT/build.err")"
    # Noncompliant: an author line under the same title is still refused.
    printf "# %s\n\nAuthor's all-green self-check: ZZ-AUTH everything passes.\n" "$title" >"$in"
    for flag in --request --context; do
      rc=0
      "$PACK_BIN" --root "$ROOT" --contract "$src" "$flag" "$in" --out-root "$TMP_ROOT/xc-out" >/dev/null 2>"$TMP_ROOT/xc.err" || rc=$?
      assert_equals 2 "$rc" "a $flag file '# $title' with an author line was accepted"
      assert_absent "$TMP_ROOT/xc-out" "a refused $flag file left an output directory"
    done
  done
  pass "an exact section title in a request or context file keeps the author-line refusal"
}

test_build_requires_a_root() {
  local src="$TMP_ROOT/nr.md" rep="$TMP_ROOT/report16.md" pack rc=0
  make_leak_world
  write_fixture_contract "$src"
  # Noncompliant: a build with no --root is refused by name and writes nothing.
  "$PACK_BIN" build --contract "$src" --out-root "$TMP_ROOT/nr-out" >/dev/null 2>"$TMP_ROOT/nr.err" || rc=$?
  assert_equals 2 "$rc" "a build with no --root was accepted"
  assert_contains "$(cat "$TMP_ROOT/nr.err")" "--root is required" "the refusal does not name --root"
  assert_absent "$TMP_ROOT/nr-out" "a refused build left an output directory"
  # Compliant: with a root, a pack file named relative to the pack is clean.
  build_pack pack --contract "$src" --root "$LEAK_ROOT" || fail "build with a root failed: $(cat "$TMP_ROOT/build.err")"
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- target.md\n- %s\n\n## Findings\n' "$pack/contract.md" >"$rep"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$pack" --report "$rep" --log "$(clean_transcript "$TMP_ROOT/ct4.jsonl" "$pack" && echo "$TMP_ROOT/ct4.jsonl")" 2>&1) || CHECK_RC=$?
  assert_equals 0 "$CHECK_RC" "a relative pack file was flagged: $CHECK_OUT"
  pass "a build needs --root, and a relative pack file is clean"
}

test_leak_check_voids_links_quotes_and_file_urls() {
  local rep="$TMP_ROOT/report17.md" sib="$TMP_ROOT/sibling/pack/review.md" body n=0
  make_leak_world
  # Compliant: plain full paths are clean.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- %s\n\n## Findings\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "plain pack paths were flagged: $CHECK_OUT"
  # Noncompliant: a path behind a link, quotes or file:// voids for structure, never clean.
  # shellcheck disable=SC1111 # literal curly quotes in a report line
  for body in "- [contract.md]($LEAK_PACK/contract.md)" "- Prior report: [review.md]($sib)" "- [sibling report]($sib)" \
    "- also read '$sib'" "- also “${sib}”" "- see file://$sib"; do
    n=$((n + 1))
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n%s\n\n## Findings\n' "$LEAK_PACK/target.md" "$body" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "wrapped path $n ($body) was accepted"
    assert_contains "$CHECK_OUT" "REPORT STRUCTURE" "wrapped path $n did not void for structure"
  done
  pass "a path behind a link, quotes or file:// voids the round for structure"
}

test_longer_field_label_voids_as_structure() {
  local rep="$TMP_ROOT/report18.md" label n=0
  make_leak_world
  # Compliant: the longer field name as a heading of its own is clean.
  printf 'VERDICT: INCOMPLETE head=abc\n\n## Inputs read\n\n- %s\n\n## Checks not performed and limits\n\n- A1 needs %s, not opened.\n' "$LEAK_PACK/target.md" "$LEAK_ROOT/data/case/truth/r23-review.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a longer field heading was voided: $CHECK_OUT"
  # Noncompliant: the longer field name as a bold or plain label voids for structure.
  for label in '**Checks not performed and limits**' '**Notes (not findings)**' 'Checks not performed and limits:'; do
    n=$((n + 1))
    printf 'VERDICT: INCOMPLETE head=abc\n\n## Inputs read\n\n- %s\n%s\n- A1 needs %s, not opened.\n' "$LEAK_PACK/target.md" "$label" "$LEAK_ROOT/data/case/truth/r23-review.md" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "label $n ($label) was accepted"
    assert_contains "$CHECK_OUT" "report field not under its own heading" "label $n did not void for structure"
    assert_not_contains "$CHECK_OUT" "INPUT LEAK" "label $n was reported as a leak"
  done
  pass "a longer report field label voids for structure, not as a leak"
}

test_leak_check_accepts_bare_entrypoint_lines_after_the_list() {
  local rep="$TMP_ROOT/report19.md" tail n=0
  make_leak_world
  # Compliant: every field under its own heading, Inputs read last, then the bare lines the entrypoint asks for.
  for tail in 'VERDICT: FAIL' 'Protected class: no - the contract names no protected class.\nVERDICT: FAIL' \
    'EXIT: needs-revision\n\nBasis: the decisions are identifiable; two criteria reject a correct worker.\n\nVERDICT: FAIL'; do
    n=$((n + 1))
    {
      printf 'VERDICT: FAIL head=abc\n\n## Identity\n\nTerra, session unknown.\n\n## Criteria\n\n- A1: fail.\n\n## Findings\n\nF1 something.\n\n'
      printf '## Inputs read\n\n%s\n%s\n\n' "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md"
      printf '%b\n' "$tail"
    } >"$rep"
    run_check "$rep"
    assert_equals 0 "$CHECK_RC" "report $n ending with bare entrypoint lines was voided: $CHECK_OUT"
    assert_contains "$CHECK_OUT" "2 listed input(s)" "report $n did not read the list"
  done
  # Noncompliant: a path-like line in the list still voids for structure.
  {
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n%s\nAlso skimmed %s for context.\n\nVERDICT: FAIL\n' "$LEAK_PACK/contract.md" "$TMP_ROOT/sibling/pack/review.md"
  } >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a path-like line in the list was accepted"
  assert_contains "$CHECK_OUT" "REPORT STRUCTURE" "the path-like line did not void for structure"
  pass "bare VERDICT, Protected class, EXIT and Basis lines after the list are accepted, and a stray path still voids"
}

test_leak_check_reads_bare_file_names() {
  local rep="$TMP_ROOT/report20.md" line n=0
  make_leak_world
  # Compliant: a revision path to a bare tracked name is read, and prose with a slash is skipped.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- HEAD:README.md\n- N/A\n- Helpers/subagents: none\n\n## Findings\n' "$LEAK_PACK/contract.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a bare revision path or slash prose was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the bare revision path was not read"
  # Noncompliant: a gitignored root file named bare, with a line reference, punctuation or as a dotfile, is a leak.
  # shellcheck disable=SC2016 # literal backticks in a report line
  for line in '- secret.md: read in full' '- secret.md:12' '- secret.md, read' '- .env' '- `.env`'; do
    n=$((n + 1))
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n%s\n\n## Findings\n' "$LEAK_PACK/contract.md" "$line" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "bare name $n ($line) passed"
    assert_contains "$CHECK_OUT" "INPUT LEAK" "bare name $n ($line) was not read as a leak"
  done
  pass "a bare file name, with a revision, line reference or punctuation, is read as a path"
}

test_leak_check_judges_a_slash_path_with_no_extension() {
  local rep="$TMP_ROOT/report21.md" line n=0
  make_leak_world
  printf 'no extension\n' >"$LEAK_ROOT/data/case/truth/r23-review"
  printf 'spaced\n' >"$LEAK_ROOT/data/case/truth/r23 review.md"
  # Compliant: slash prose that names no file is skipped.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- N/A\n- Helpers/subagents: none\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' "$LEAK_PACK/contract.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "slash prose was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "1 listed input(s)" "slash prose was counted as an input"
  # Noncompliant: a list of slash prose alone names no input, so it is no list.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- N/A\n\n## Findings\n' >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a list of slash prose alone was accepted"
  assert_contains "$CHECK_OUT" "no Inputs read list" "a list of slash prose alone voided for another cause"
  # Noncompliant: a real file or folder under the root, named with no extension or with a space, is judged.
  # shellcheck disable=SC2016 # literal backticks in a report line
  for line in '- data/case/truth/r23-review' '- data/case/truth/' '- data/case/truth/r23 review.md' '- `data/case/truth/r23 review.md`' \
    '- data/case/truth/r23 review.md (read in full)' '- data/case/truth/r23 review.md: read in full' \
    '- also read data/case/truth/r23-review' '- also read data/case/truth/' '- searched data/ for reports'; do
    n=$((n + 1))
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n%s\n\n## Findings\n' "$LEAK_PACK/contract.md" "$line" >"$rep"
    run_check "$rep"
    assert_equals 3 "$CHECK_RC" "slash path $n ($line) passed"
    assert_contains "$CHECK_OUT" "INPUT LEAK" "slash path $n ($line) was not judged as a leak"
  done
  pass "a path the root holds is judged whatever its shape: no extension, a folder, a space or mid-line"
}

test_tab_after_heading_hashes_is_a_heading() {
  local src="$TMP_ROOT/tb.md" pack manifest
  write_fixture_contract "$src"
  # Noncompliant: a tab-separated author heading is still dropped and listed.
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "##\tAuthor'"'"'s all-green candidate"; print ""; print "ZZ-TAB-ALLGREEN-ZZ"; print ""; print "###\tSelf-check"; print ""; print "ZZ-TAB-SELF-ZZ" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  manifest="$(dirname "$pack").excluded-paths"
  assert_no_grep "ZZ-TAB-ALLGREEN-ZZ" "$pack/target.md" "a tab-separated author heading reached the pack"
  assert_no_grep "ZZ-TAB-SELF-ZZ" "$pack/target.md" "a tab-separated self-check heading reached the pack"
  grep -qxF "$(printf "dropped\tAuthor's all-green candidate")" "$manifest" || fail "the tab-separated author heading is not listed as dropped"
  # Compliant: a tab-separated kept heading keeps its text.
  write_fixture_contract "$src"
  awk '{ print } /^ZZ-KEEP-CONTEXT-ZZ/ { print ""; print "##\tAssumptions (more)"; print ""; print "ZZ-TAB-KEEP-ZZ" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-TAB-KEEP-ZZ" "$pack/target.md" "a tab-separated kept heading lost its text"
  pass "a tab after the heading hashes makes a heading at every level"
}

test_inline_backticks_do_not_open_a_fence() {
  local src="$TMP_ROOT/ib.md" pack manifest
  write_fixture_contract "$src"
  # Noncompliant: an inline code span of triple backticks is not a fence, so the author
  # section after it is still a heading and is dropped.
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "```npm test``` runs the suite."; print ""; print "## Author'"'"'s all-green candidate"; print ""; print "ZZ-ALLGREEN-INLINE-ZZ"; print ""; print "```bash"; print "echo ok"; print "```" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  manifest="$(dirname "$pack").excluded-paths"
  assert_no_grep "ZZ-ALLGREEN-INLINE-ZZ" "$pack/target.md" "an author section after an inline triple-backtick span reached the pack"
  grep -qxF "$(printf "dropped\tAuthor's all-green candidate")" "$manifest" || fail "the author section after the inline span is not listed as dropped"
  # shellcheck disable=SC2016 # literal backticks in a contract line
  assert_grep '```npm test``` runs the suite.' "$pack/target.md" "the inline code span line was dropped"
  # Compliant: a real backtick fence with an info string still hides a heading-shaped line.
  write_fixture_contract "$src"
  awk '{ print } /^- \*\*A1\*\*/ { print ""; print "```bash"; print "## Contract Review inside a bash fence"; print "```" }' "$src" >"$src.tmp" && mv "$src.tmp" "$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "## Contract Review inside a bash fence" "$pack/target.md" "a heading-shaped line inside a real fence was treated as a heading"
  pass "a triple-backtick code span is not a fence, and a real fence still hides headings"
}

test_definition_of_done_in_every_heading_form() {
  local src="$TMP_ROOT/dd.md" pack rc=0 form
  # Compliant: an indented ATX heading and a setext heading both carry the Definition Of Done,
  # and an indented REQUEST heading is still named as the request.
  for form in ' ## Definition Of Done' 'Definition Of Done
------------------'; do
    printf '# Fixture\n\n   ## REQUEST\n\nThe owner wants a thing.\n\n%s\n\n- A1 (mandatory): ZZ-KEEP-DOD-ZZ x\n' "$form" >"$src"
    build_pack pack --contract "$src" || fail "a Definition Of Done under the heading form '$form' was refused: $(cat "$TMP_ROOT/build.err")"
    assert_grep "ZZ-KEEP-DOD-ZZ" "$pack/target.md" "the Definition Of Done text is missing from the pack"
    # shellcheck disable=SC2016 # literal backticks in generated Markdown
    assert_grep 'the request is the REQUEST section of `target.md`' "$pack/contract.md" "an indented REQUEST heading was not named as the request"
  done
  # Noncompliant: a Definition Of Done heading that sits only inside a code fence is no section.
  # shellcheck disable=SC2016 # literal text in a fixture
  printf '# Fixture\n\n## REQUEST\n\nA request.\n\n```text\n## Definition Of Done\n```\n' >"$src"
  "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/dd-out" >/dev/null 2>"$TMP_ROOT/dd.err" || rc=$?
  assert_equals 2 "$rc" "a contract whose only Definition Of Done heading is fenced was accepted"
  assert_contains "$(cat "$TMP_ROOT/dd.err")" "no Definition Of Done section" "the fenced-only contract was refused for another cause"
  assert_absent "$TMP_ROOT/dd-out" "a refused contract left an output directory"
  pass "the Definition Of Done and REQUEST are found under every heading form the filter reads"
}

test_rubric_revision_is_pinned_with_a_root() {
  local rep="$TMP_ROOT/report9.md" pin old pack
  make_leak_world
  old=$(git -C "$LEAK_ROOT" log -1 --format=%H -- docs/review-rubric.md)
  printf 'rubric, revised\n' >"$LEAK_ROOT/docs/review-rubric.md"
  git -C "$LEAK_ROOT" add docs/review-rubric.md
  git -C "$LEAK_ROOT" -c user.name=t -c user.email=t@example.invalid commit -qm "rubric revised"
  pin=$(git -C "$LEAK_ROOT" log -1 --format=%H -- docs/review-rubric.md)
  build_pack pack --contract "$LEAK_ROOT/sources/raw-contract.md" --root "$LEAK_ROOT" || fail "build with a root failed"
  rubric_check() { # <entry>
    write_report "$rep" "$pack/contract.md" "$1"
    CHECK_RC=0
    CHECK_OUT=$(REVIEW_FM_ROOT="$LEAK_ROOT" REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
      "$PACK_BIN" check --pack "$pack" --report "$rep" --log "$(clean_transcript "$TMP_ROOT/ct5.jsonl" "$pack" && echo "$TMP_ROOT/ct5.jsonl")" 2>&1) || CHECK_RC=$?
  }
  rubric_check "$pin:docs/review-rubric.md"
  assert_equals 0 "$CHECK_RC" "the pinned rubric revision was flagged with a root: $CHECK_OUT"
  rubric_check "$old:docs/review-rubric.md"
  assert_equals 3 "$CHECK_RC" "an older tracked revision of the rubric was allowed with a root"
  rubric_check "no-such-rev:docs/review-rubric.md"
  assert_equals 3 "$CHECK_RC" "an unknown revision of the rubric was allowed with a root"
  rubric_check "HEAD~1:docs/review-rubric.md"
  assert_equals 3 "$CHECK_RC" "a relative revision of the rubric was allowed with a root"
  rubric_check "$old:bin/fm-spawn.sh"
  assert_equals 0 "$CHECK_RC" "an older revision of another tracked file was flagged: $CHECK_OUT"
  pass "with a root, a revision path to the rubric is allowed only at the pinned revision"
}

test_prose_mention_is_judged_but_is_no_list() {
  local rep="$TMP_ROOT/report-z1.md"
  make_leak_world
  # Noncompliant: a prose summary that names a pack file names no input by path, so it is no list.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\nI read only the pack files (target.md and its folder), the two skills and the rubric.\n\n## Findings\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a prose-only Inputs read section was accepted: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "no Inputs read list" "a prose-only Inputs read section voided for another cause"
  # Compliant: a full-path list plus a prose mention of target.md stays clean and counts the list only.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n- %s\n\nBoth are pack files; target.md is the contract under review.\n\n## Findings\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' \
    "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a list with a prose mention was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the prose mention was counted as a listed input"
  pass "a prose mention is judged for leaks but never counts as a listed input"
}

test_label_argument_is_gone() {
  local src="$TMP_ROOT/s-label.md" rc=0 pack
  write_fixture_contract "$src"
  # Noncompliant: --label adds title text no requirement needs, so it is an unknown argument.
  "$PACK_BIN" --root "$ROOT" --contract "$src" --label probe-label --out-root "$TMP_ROOT/l1" >/dev/null 2>"$TMP_ROOT/l.err" || rc=$?
  assert_equals 2 "$rc" "--label was accepted"
  assert_contains "$(cat "$TMP_ROOT/l.err")" "unknown argument: --label" "--label was refused for another cause"
  assert_absent "$TMP_ROOT/l1" "a refused --label left an output directory"
  # Compliant: the same build without it succeeds, and its title names no label.
  pack=''
  build_pack pack --contract "$src" || fail "build without --label failed: $(cat "$TMP_ROOT/build.err")"
  assert_equals "# Review of the definition-of-done contract" "$(head -1 "$pack/contract.md")" "the pack title changed"
  pass "the builder has no --label argument"
}

test_policy_is_named_only_by_the_policy_argument() {
  local src="$TMP_ROOT/s-one-way.md" pack policy2="$TMP_ROOT/policy-env.md"
  write_fixture_contract "$src"
  awk '{ print } $0 == "<!-- reviewer-block:begin -->" { print "Probe line that only the environment copy holds." }' "$POLICY" >"$policy2"
  # Noncompliant: a policy named in the environment is a second way to pick the policy.
  pack=''
  FM_CONTRACT_REVIEW_POLICY="$policy2" build_pack pack --contract "$src" || fail "build with a policy variable set failed: $(cat "$TMP_ROOT/build.err")"
  assert_no_grep "Probe line that only the environment copy holds." "$pack/contract.md" "the builder took the policy from the environment"
  policy_block "$POLICY" "$TMP_ROOT/block.one-way.expected"
  pack_block "$pack/contract.md" "$TMP_ROOT/block.one-way.actual"
  cmp -s "$TMP_ROOT/block.one-way.expected" "$TMP_ROOT/block.one-way.actual" || fail "with no --policy the pack does not hold the default policy block"
  # Compliant: --policy still names it.
  pack=''
  build_pack pack --contract "$src" --policy "$policy2" || fail "build with --policy failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "Probe line that only the environment copy holds." "$pack/contract.md" "--policy no longer names the policy"
  pass "--policy is the one way to name the policy"
}

test_leak_check_splits_candidates_at_any_non_path_character() {
  local rep="$TMP_ROOT/report-z3.md" row want line n=0
  make_leak_world
  printf 'no extension\n' >"$LEAK_ROOT/data/case/truth/r23-review"
  printf 'long name\n' >"$LEAK_ROOT/data/case/truth/a b c d e f g h.md"
  # One row per form: the expected exit, a tab, then the list line. Each line sits beside the
  # pack's contract.md; the files above are gitignored under the root, so naming one is a leak.
  # shellcheck disable=SC2016,SC1111 # literal backticks and curly quotes in report lines
  local rows=(
    "3	- 'data/case/truth/r23-review'"
    "3	- “data/case/truth/r23-review”"
    "3	- [r23](data/case/truth/r23-review)"
    "3	- [data/case/truth/r23-review]"
    "3	- data/case/truth/r23-review:12:3"
    "3	- file:data/case/truth/r23-review"
    "3	- data/case/truth/r23-review;data/x"
    "3	- also read data/case/truth/r23-review."
    "3	- also read {data/case/truth/r23-review}, then stopped"
    "3	- also read data/case/truth/a b c d e f g h.md"
    '3	- `data/case/truth/a b c d e f g h.md`'
    "0	- N/A"
    "0	- Helpers/subagents: none"
    "0	- Checked e.g. the file list; nothing else."
    "0	- 'Helpers/subagents' (none) [n/a]"
  )
  for row in "${rows[@]}"; do
    n=$((n + 1))
    want=${row%%	*}
    line=${row#*	}
    printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n%s\n\n## Findings\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' "$LEAK_PACK/contract.md" "$line" >"$rep"
    run_check "$rep"
    assert_equals "$want" "$CHECK_RC" "row $n ($line) gave exit $CHECK_RC: $CHECK_OUT"
    if [ "$want" = 3 ]; then
      assert_contains "$CHECK_OUT" "INPUT LEAK" "row $n ($line) voided for a cause other than a leak"
    else
      assert_contains "$CHECK_OUT" "1 listed input(s)" "row $n ($line) was counted as an input"
    fi
  done
  pass "a path the root holds is judged whatever wraps it: quotes, brackets, links, line and column, file:, ; or a long spaced name"
}

test_unopened_file_named_under_inputs_read_voids() {
  local rep="$TMP_ROOT/report-z2.md" line
  make_leak_world
  # The recorded g5-R2 reviewer line (evidence/main-grader-replay-f07cd4f8/g5-R2-report.md:139).
  # shellcheck disable=SC2016 # literal backticks in a report line
  line='The named but absent `request.md` was attempted and is not an opened file. No credential or `.env` file was opened.'
  # Noncompliant (the old prompt let a reviewer write this): an unopened file named under
  # Inputs read stays a void, because no text test can tell a mention from a read.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n%s\n\n%s\n%s\n\n## Checks not performed\n\nNone.\n\nEXIT: needs-revision\nVERDICT: FAIL\n' \
    "$line" "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "an unopened .env named under Inputs read passed: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "INPUT LEAK: .env" "the unopened .env did not void as a leak"
  # Compliant (what the new prompt asks for): the same sentence under Checks not performed is clean.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n%s\n%s\n\n## Checks not performed\n\n%s\n\nEXIT: needs-revision\nVERDICT: FAIL\n' \
    "$LEAK_PACK/contract.md" "$LEAK_PACK/target.md" "$line" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "the unopened file under Checks not performed was flagged: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "2 listed input(s)" "the compliant list was not read"
  pass "an unopened file named under Inputs read voids, and the same sentence under Checks not performed is clean"
}

test_every_author_name_with_a_trailing_word_stays_out() {
  local src="$TMP_ROOT/flip-c.md" ctx="$TMP_ROOT/flip-x.md" plain="$TMP_ROOT/flip-t.md" name heading n=0 rc pack form
  printf '# T\n\n## REQUEST\n\nr\n\n## Definition Of Done\n\n- **A1** (mandatory): x.\n' >"$plain"
  # Noncompliant: every author section name, followed by one more word, with author text below,
  # as a contract sub-section and as a context level 4 or bold line, never reaches the pack.
  for name in 'Author self-check' "Author's all-green" 'All-green' "Author's" 'Author notes' 'Boundary dispositions' \
    'Contract review' 'Review history' 'Revision log' 'Revision history' 'Self-check' 'Prior findings' 'Prior review' \
    'Responses' 'Response to' 'Suggested attack' 'Open findings' 'Finding register' 'Register'; do
    n=$((n + 1))
    heading="$name notes"
    printf '# C\n\n## Definition Of Done\n\n- **A1** (mandatory): x.\n\n### %s\n\nZZ-FLIP-ZZ F1 answered: fixed, passes.\n' "$heading" >"$src"
    rc=0
    pack=$("$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/flip-c-$n" 2>/dev/null) || rc=$?
    [ "$rc" != 0 ] || assert_no_grep "ZZ-FLIP-ZZ" "$pack/target.md" "contract sub-section '### $heading' reached the pack"
    for form in "#### $heading" "**$heading**"; do
      printf '# O\n\n## Context\n\n%s\n\nZZ-FLIP-ZZ F1 answered: fixed, passes.\n' "$form" >"$ctx"
      rc=0
      "$PACK_BIN" --root "$ROOT" --contract "$plain" --context "$ctx" --out-root "$TMP_ROOT/flip-x-$n" >/dev/null 2>&1 || rc=$?
      [ "$rc" != 0 ] || fail "context line '$form' with author text built"
      rm -rf "$TMP_ROOT/flip-x-$n" "$TMP_ROOT/flip-x-$n.excluded-paths"
    done
  done
  pass "every author section name with a trailing word stays out of the pack in every position"
}

test_contract_context_author_label_line_stays_out() {
  local src="$TMP_ROOT/ctxline.md" pack manifest
  # Noncompliant: an author self-check line in the contract's own CONTEXT section.
  printf '# C\n\n## REQUEST\n\nZZ-KEEP-REQ-ZZ the owner wants a thing; a reviewer received the author'"'"'s all-green analysis.\n\n## CONTEXT\n\nAuthor'"'"'s all-green self-check: ZZ-SELFCHECK-ZZ F1 is fixed and every mandatory item passes.\n\nZZ-KEEP-CTX-ZZ neutral fact.\n\n## Definition Of Done\n\n- **A1** (mandatory): ZZ-KEEP-DOD-ZZ a worker self-check is context, never verification.\n' >"$src"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  manifest="$(dirname "$pack").excluded-paths"
  assert_no_grep "ZZ-SELFCHECK-ZZ" "$pack/target.md" "the CONTEXT self-check line reached target.md"
  assert_grep "author line: " "$manifest" "the dropped CONTEXT line is not listed in the manifest"
  # Compliant: the request's description of the cause, a neutral context line and a criterion that
  # names a self-check all stay.
  for m in ZZ-KEEP-REQ-ZZ ZZ-KEEP-CTX-ZZ ZZ-KEEP-DOD-ZZ; do
    assert_grep "$m" "$pack/target.md" "contract text $m was dropped"
  done
  pass "an author label line in the contract's CONTEXT is dropped and listed; neutral text naming the subject stays"
}

test_author_history_subheading_in_contract_refused() {
  local src="$TMP_ROOT/f1-contract.md" heading n=0 rc
  # Noncompliant: each author-history or author-section sub-heading under a kept section,
  # followed by real author conclusions, must never reach target.md.
  for heading in '### Earlier findings and how I answered them' "#### Author's all-green candidate" '**Contract Review**'; do
    n=$((n + 1))
    printf '# Fixture contract\n\n## Definition Of Done\n\n- **A1** (mandatory): ZZ-KEEP-DOD-ZZ the thing exists.\n\n%s\n\nZZ-AUTHOR-ZZ F1 answered: fixed; every mandatory item passes.\n' "$heading" >"$src"
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" --out-root "$TMP_ROOT/f1-out-$n" >"$TMP_ROOT/f1.out" 2>"$TMP_ROOT/f1.err" || rc=$?
    assert_equals 3 "$rc" "author sub-heading $n ($heading) was not refused: $(cat "$TMP_ROOT/f1.err")"
    assert_absent "$TMP_ROOT/f1-out-$n" "a refused author sub-heading $n left an output directory"
    assert_contains "$(cat "$TMP_ROOT/f1.err")" "unrecognised section:" "the refusal of sub-heading $n does not name it"
  done
  pass "an author-history or author-section sub-heading in a contract stops the build and reaches no pack"
}

test_author_conclusion_line_in_request_or_context_refused() {
  local src="$TMP_ROOT/f1b-contract.md" ctx="$TMP_ROOT/f1b-context.md" pack kind rc
  write_fixture_contract "$src"
  # Noncompliant: an author conclusion line in the body of a request or context file.
  printf '# Owner context\n\n## Context\n\nAuthor'"'"'s all-green self-check: F1 is fixed and every mandatory item passes.\n' >"$ctx"
  for kind in --context --request; do
    rc=0
    "$PACK_BIN" --root "$ROOT" --contract "$src" "$kind" "$ctx" --out-root "$TMP_ROOT/f1b-out${kind}" >/dev/null 2>"$TMP_ROOT/f1b.err" || rc=$?
    assert_equals 2 "$rc" "an author conclusion line in a $kind file was not refused: $(cat "$TMP_ROOT/f1b.err")"
    assert_absent "$TMP_ROOT/f1b-out${kind}" "a refused $kind file left an output directory"
  done
  # Compliant: the owner's text may name a contract review as its subject.
  printf '# Owner context\n\n## Context\n\nThe owner asked for an independent contract review of the steer.\n' >"$ctx"
  pack=''
  build_pack pack --contract "$src" --context "$ctx" || fail "a neutral context naming a contract review was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "independent contract review of the steer" "$pack/context-f1b-context.md" "the neutral context was not copied"
  pass "an author conclusion line in a request or context file is refused, and neutral owner text builds"
}

test_responses_criterion_and_contract_review_scope_build() {
  local src="$TMP_ROOT/f2-contract.md" ctx="$TMP_ROOT/f2-context.md" pack rc
  # Compliant: a DoD sub-section named Responses that holds a mandatory criterion is contract text.
  printf '# Fixture contract\n\n## Definition Of Done\n\n### Responses\n\n- **A1** (mandatory): ZZ-RESPONSES-A1-ZZ return 204 for a successful request.\n\n### Recovery\n\n- **A2** (mandatory): ZZ-RECOVERY-A2-ZZ retry once.\n' >"$src"
  pack=''
  build_pack pack --contract "$src" || fail "a Responses criterion section was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-RESPONSES-A1-ZZ" "$pack/target.md" "the mandatory criterion under Responses was dropped"
  assert_grep "ZZ-RECOVERY-A2-ZZ" "$pack/target.md" "the criterion under Recovery was dropped"
  # Compliant (Main 034): a neutral Contract review scope label in a context file builds.
  write_fixture_contract "$TMP_ROOT/f2-plain.md"
  printf '# Owner context\n\n## Context\n\n**Contract review scope**\n\nZZ-SCOPE-ZZ review only the G2 contract.\n' >"$ctx"
  pack=''
  build_pack pack --contract "$TMP_ROOT/f2-plain.md" --context "$ctx" || fail "a neutral Contract review scope context was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-SCOPE-ZZ" "$pack/context-f2-context.md" "the scope context was not copied"
  # Noncompliant control: an actual Contract Review author section in a context file is still refused.
  printf '# Owner context\n\n## Context\n\n**Contract Review**\n\nF1 answered: fixed.\n' >"$ctx"
  rc=0
  "$PACK_BIN" --root "$ROOT" --contract "$TMP_ROOT/f2-plain.md" --context "$ctx" --out-root "$TMP_ROOT/f2-out" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an author Contract Review section in a context file was accepted"
  pass "a Responses criterion and a Contract review scope context build; an author Contract Review section does not"
}

test_headingless_list_of_an_extensionless_path_voids() {
  local rep="$TMP_ROOT/report-f3.md"
  make_leak_world
  printf 'no extension\n' >"$LEAK_ROOT/data/case/truth/r23-review"
  # Noncompliant: a heading-less list before the headed one, naming an extensionless ignored file.
  printf 'VERDICT: FAIL head=abc\n\nInputs read:\n- data/case/truth/r23-review\n\n## Inputs read\n\n- %s\n\n## Findings\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 3 "$CHECK_RC" "a heading-less list of an extensionless path was accepted: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "not under its own heading" "the heading-less list did not void for its cause"
  # Compliant control: the headed list alone is clean.
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- %s\n\n## Findings\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' "$LEAK_PACK/target.md" >"$rep"
  run_check "$rep"
  assert_equals 0 "$CHECK_RC" "a headed list alone was flagged: $CHECK_OUT"
  pass "a heading-less Inputs read list voids whatever the shape of its paths"
}

test_transcript_reads_are_audited_and_the_log_is_required() {
  local rep="$TMP_ROOT/report-f4.md" log="$TMP_ROOT/f4-transcript.jsonl" rc
  make_leak_world
  write_report "$rep" "$LEAK_PACK/target.md"
  # Noncompliant: the transcript records a read of an earlier report the list does not name.
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call read path "$LEAK_PACK/target.md")" \
    "$(tool_call read path "$LEAK_ROOT/data/case/truth/r23-review.md:raw:1-20")"
  run_check "$rep" "$log"
  assert_equals 3 "$CHECK_RC" "a transcript read of an earlier report was accepted: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "INPUT LEAK" "the transcript read did not void as a leak"
  # Noncompliant: a search over an ignored folder, and shell text that opens one.
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call grep pattern F1 path "$LEAK_ROOT/data/case" gitignore false)"
  run_check "$rep" "$log"
  assert_equals 3 "$CHECK_RC" "a transcript search of an ignored folder was accepted: $CHECK_OUT"
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call bash command "cat '$LEAK_ROOT/data/case/truth/r23-review.md'")"
  run_check "$rep" "$log"
  assert_equals 3 "$CHECK_RC" "a shell read of an earlier report was accepted: $CHECK_OUT"
  # Compliant: pack files, the two named skills by skill URL and by path, the rubric, a tracked
  # file, a relative read of the work folder's own review, and an absent file the reviewer tried.
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call read path skill://assess-done-and-grade)" \
    "$(tool_call read path "$LEAK_PACK/contract.md:12-40")" "$(tool_call read path "$LEAK_PACK/target.md")" \
    "$(tool_call read path "$LEAK_SKILLS/define-done-and-grading/SKILL.md")" \
    "$(tool_call read path "$LEAK_ROOT/docs/review-rubric.md")" "$(tool_call read path "$LEAK_ROOT/bin/fm-spawn.sh")" \
    "$(tool_call read path "$LEAK_PACK/request.md")" \
    "$(tool_call grep pattern A1 path "$LEAK_PACK" gitignore true)"
  run_check "$rep" "$log"
  assert_equals 0 "$CHECK_RC" "a clean transcript was flagged: $CHECK_OUT"
  # The reviewer's own scratch in its work folder is clean; the entrypoint's copy of
  # OPERATIONAL-BOUNDARIES.md there is not an authorized input (not widened; Main decides).
  mkdir -p "$(work_of "$LEAK_PACK")"
  printf 'probe\n' >"$(work_of "$LEAK_PACK")/probe.txt"
  printf 'boundaries\n' >"$(work_of "$LEAK_PACK")/OPERATIONAL-BOUNDARIES.md"
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call read path probe.txt)"
  run_check "$rep" "$log"
  assert_equals 0 "$CHECK_RC" "a read of the reviewer's own scratch was flagged: $CHECK_OUT"
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call read path OPERATIONAL-BOUNDARIES.md)"
  run_check "$rep" "$log"
  assert_equals 3 "$CHECK_RC" "a read of the entrypoint's OPERATIONAL-BOUNDARIES.md copy was accepted: $CHECK_OUT"
  # A single-file log that starts a subagent hides the subagent's reads, so it is not clean;
  # a relative path in probe code resolves against the call's own folder, not the root.
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call task context probe)"
  run_check "$rep" "$log"
  assert_equals 3 "$CHECK_RC" "a single-file log with a subagent call was certified: $CHECK_OUT"
  write_transcript "$log" "$(work_of "$LEAK_PACK")" "$(tool_call eval code "root = scratch / 'data/case'; (root / 'x').mkdir()")"
  run_check "$rep" "$log"
  assert_equals 0 "$CHECK_RC" "a relative path in probe code was judged against the root: $CHECK_OUT"
  # The log is required, and a text log that records no tool call cannot be audited.
  rc=0
  REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$LEAK_PACK" --report "$rep" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a check with no --log ran"
  printf 'I also read %s\n' "$LEAK_ROOT/data/case/truth/r23-review.md" >"$TMP_ROOT/f4-text.log"
  run_check "$rep" "$TMP_ROOT/f4-text.log"
  assert_equals 2 "$CHECK_RC" "a text log with no tool-call record was certified: $CHECK_OUT"
  pass "the run's transcript is required, and every read, search or shell path it records is judged"
}

test_authorized_spaced_path_is_clean() {
  local rep="$TMP_ROOT/report-f5.md" pack log="$TMP_ROOT/f5-transcript.jsonl"
  make_leak_world
  pack=''
  build_pack pack --contract "$LEAK_ROOT/sources/raw-contract.md" --root "$LEAK_ROOT" --out-root "$TMP_ROOT/parent with spaces" ||
    fail "build into a spaced parent failed: $(cat "$TMP_ROOT/build.err")"
  printf 'spaced\n' >"$LEAK_ROOT/data/case/truth/r23 review.md"
  # Compliant: one backticked full path with spaces to the pack's own file.
  # shellcheck disable=SC2016 # literal backticks in a report line
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- `%s`\n\n## Findings\n\nEXIT: needs-revision\n\nVERDICT: FAIL\n' "$pack/target.md" >"$rep"
  clean_transcript "$log" "$pack"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$pack" --report "$rep" --log "$log" 2>&1) || CHECK_RC=$?
  assert_equals 0 "$CHECK_RC" "an authorized spaced path was voided: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "1 listed input(s)" "the spaced path was not counted"
  # Noncompliant: an unauthorized spaced path still voids.
  # shellcheck disable=SC2016 # literal backticks in a report line
  printf 'VERDICT: FAIL head=abc\n\n## Inputs read\n\n- `%s`\n\n## Findings\n' "$LEAK_ROOT/data/case/truth/r23 review.md" >"$rep"
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" \
    "$PACK_BIN" check --pack "$pack" --report "$rep" --log "$log" 2>&1) || CHECK_RC=$?
  assert_equals 3 "$CHECK_RC" "an unauthorized spaced path passed: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "INPUT LEAK" "the unauthorized spaced path voided for another cause"
  pass "one backticked full path with spaces is judged as a path: clean when authorized, a leak when not"
}

fm_test_run_cases \
  test_markers_kept_and_dropped \
  test_unrecognised_section_refused \
  test_unrecognised_subheadings_stay_and_are_listed \
  test_setext_headings_are_sections \
  test_code_fences_close_on_their_own_marker \
  test_single_source_policy_block \
  test_pack_layout_and_fresh_parent \
  test_fails_safe_on_bad_input \
  test_context_file_with_author_section_refused \
  test_leak_check_judges_what_a_path_is \
  test_leak_check_revision_paths_and_excluded_directories \
  test_leak_check_reads_common_report_shapes \
  test_leak_check_reads_prose_before_the_list_and_refuses_linked_files \
  test_leak_check_reads_the_whole_list \
  test_leak_check_pins_the_rubric_revision \
  test_pack_names_only_the_request_it_holds \
  test_export_root_mode_is_gone \
  test_leak_check_pinned_rubric_url_and_own_report \
  test_preamble_author_text_matches_whole_words \
  test_inputs_read_list_needs_its_own_heading \
  test_request_or_context_with_author_history_heading_refused \
  test_recognised_heading_with_author_history_refused \
  test_author_history_in_every_heading_position_refused \
  test_prior_counts_only_before_a_history_noun \
  test_prior_revisions_heading_refused \
  test_author_history_heading_under_unrecognised_parent_or_title_refused \
  test_title_is_not_the_definition_of_done \
  test_leak_check_reads_through_fences_and_setext_headings \
  test_leak_check_voids_a_second_path_on_a_line \
  test_leak_check_reads_a_path_above_a_rule_or_hash_line \
  test_leak_check_voids_a_path_that_is_not_the_leading_entry \
  test_summary_mention_of_inputs_read_is_not_a_list \
  test_author_section_title_drops \
  test_author_section_under_any_heading_of_request_or_context_refused \
  test_exact_section_title_counts_as_a_section \
  test_exact_section_title_keeps_its_text \
  test_report_field_under_a_label_voids_as_structure \
  test_exact_title_in_request_or_context_keeps_the_author_check \
  test_build_requires_a_root \
  test_leak_check_voids_links_quotes_and_file_urls \
  test_longer_field_label_voids_as_structure \
  test_leak_check_accepts_bare_entrypoint_lines_after_the_list \
  test_leak_check_reads_bare_file_names \
  test_leak_check_judges_a_slash_path_with_no_extension \
  test_tab_after_heading_hashes_is_a_heading \
  test_inline_backticks_do_not_open_a_fence \
  test_definition_of_done_in_every_heading_form \
  test_fences_and_headings_accept_up_to_three_spaces \
  test_rubric_revision_is_pinned_with_a_root \
  test_unopened_file_named_under_inputs_read_voids \
  test_leak_check_splits_candidates_at_any_non_path_character \
  test_policy_is_named_only_by_the_policy_argument \
  test_label_argument_is_gone \
  test_prose_mention_is_judged_but_is_no_list \
  test_author_history_subheading_in_contract_refused \
  test_author_conclusion_line_in_request_or_context_refused \
  test_responses_criterion_and_contract_review_scope_build \
  test_headingless_list_of_an_extensionless_path_voids \
  test_transcript_reads_are_audited_and_the_log_is_required \
  test_authorized_spaced_path_is_clean \
  test_every_author_name_with_a_trailing_word_stays_out \
  test_contract_context_author_label_line_stays_out \
  -- "$@"
