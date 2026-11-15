#!/usr/bin/env bash
# Behavioral regressions for bin/fm-contract-review-pack.sh: the allow-list pack builder and
# the transcript read check. Every case runs the script through its command line.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACK_BIN="$ROOT/bin/fm-contract-review-pack.sh"
POLICY="$ROOT/.agents/skills/contract-review/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-contract-review)
export TMPDIR="$TMP_ROOT"
mkdir -p "$TMPDIR"
# The entrypoint and the builder both name the reviewer's work folder from REVIEW_WORK_ROOT:
# <work root>/<pack parent basename>-pack.
export REVIEW_WORK_ROOT="$TMP_ROOT/work"

# The known sections of a fixture contract, each with a marker, in the order the pack keeps them.
write_known_sections() { # <file>
  cat >"$1" <<'EOF'
## REQUEST (verbatim)

ZZ-KEEP-REQUEST-ZZ the owner wants a thing.

## CONTEXT

ZZ-KEEP-CONTEXT-ZZ neutral fact.

```text
### Example inside a fence
```

## Rulings on this contract (Main 2686, corr=4a2b19c0, and Main 2697, verbatim)

ZZ-KEEP-RULINGS-ZZ ruling text.

## Amendment A2

ZZ-KEEP-AMENDMENT-ZZ amendment text.

## Definition Of Done (steer), revision 9

### Mandatory items

- **A1** (mandatory): ZZ-KEEP-DOD-ZZ the thing exists.

### Picker cutover — mandatory

ZZ-KEEP-CRITERION-TITLE-ZZ the picker routes by the declared set.

### Supporting items

- **S1**: ZZ-KEEP-SUPPORT-ZZ a support item.

How You’re Graded
-----------------

ZZ-KEEP-GRADED-ZZ a grader checks A1.

## Assumptions

- A-1 ZZ-KEEP-ASSUMPTION-ZZ neutral assumption.
EOF
}

# A contract: a title, a preamble line, the known sections, and author sections around them.
write_fixture_contract() { # <file>
  {
    printf '# Fixture contract\n\nTask: fixture. ZZ-PREAMBLE-ZZ reviewed: pass.\n\n'
    printf '## Boundary dispositions\n\n- ZZ-RESPONSE-ZZ the author answered the earlier finding.\n\n'
    write_known_sections /dev/stdout
    # shellcheck disable=SC1112 # a curly apostrophe on purpose: the builder must read it as an apostrophe
    printf '## Author’s all-green candidate\n\nZZ-ALLGREEN-ZZ candidate.\n\n'
    printf '## Contract Review history\n\n- Revision 1: ZZ-PRIOR-FINDING-ZZ F1 was raised.\n\n### Definition Of Done\n\nZZ-HISTORY-UNDER-ZZ a known name below an unknown section.\n'
  } >"$1"
}

build_pack() { # <out-var> [builder args...]: prints nothing, sets the named variable to the pack dir
  local __var=$1 __out
  shift
  __out=$("$PACK_BIN" --root "$ROOT" "$@" 2>"$TMP_ROOT/build.err") || return $?
  printf -v "$__var" '%s' "$__out"
}

build_rc() { # <out-root> [builder args...] -> sets BUILD_RC and BUILD_ERR
  BUILD_RC=0
  "$PACK_BIN" --root "$ROOT" "${@:2}" --out-root "$1" >/dev/null 2>"$TMP_ROOT/build-rc.err" || BUILD_RC=$?
  BUILD_ERR=$(cat "$TMP_ROOT/build-rc.err")
}

policy_block() { # <policy> <out>
  awk '$0 == "<!-- reviewer-block:begin -->" { on = 1 } on { print } $0 == "<!-- reviewer-block:end -->" { on = 0 }' "$1" >"$2"
}

# --- the allow-list builder ---------------------------------------------------

test_known_sections_pass_byte_identical() {
  local src="$TMP_ROOT/k.md" pack manifest m
  write_fixture_contract "$src"
  write_known_sections "$TMP_ROOT/k.expected"
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  cmp -s "$TMP_ROOT/k.expected" "$pack/target.md" || fail "target.md is not exactly the known sections: $(diff "$TMP_ROOT/k.expected" "$pack/target.md")"
  manifest="$(dirname "$pack").excluded-paths"
  for m in "title: Fixture contract" "text outside a known section (1 line(s) before \"Boundary dispositions\")" \
    "Boundary dispositions" "Author’s all-green candidate" "Contract Review history"; do
    grep -qxF "$(printf 'dropped\t%s' "$m")" "$manifest" || fail "the excluded record does not list: $m"
  done
  pass "target.md is exactly the known sections, byte for byte, and every drop is listed by heading"
}

test_every_round_finding_section_is_dropped() {
  local src="$TMP_ROOT/drop.md" pack heading
  # Each author section the two outside rounds named, and each prefixed or qualified form an
  # allow-list must not admit, with author text below it, at the top level.
  for heading in "Author's all-green candidate" 'Contract Review' 'Contract review notes' 'Boundary dispositions notes' \
    'Revision history notes' 'Register notes' 'Suggested attack notes' 'Responses' 'Notes from the author' \
    'Context and earlier findings' 'REQUEST (author notes)' 'Earlier findings and how I answered them' 'Owner background'; do
    { write_known_sections /dev/stdout; printf '\n## %s\n\nZZ-AUTHOR-ZZ F1 answered: fixed, passes.\n' "$heading"; } >"$src"
    pack=''
    build_pack pack --contract "$src" || fail "build with '## $heading' failed: $(cat "$TMP_ROOT/build.err")"
    assert_no_grep "ZZ-AUTHOR-ZZ" "$pack/target.md" "the text under '## $heading' reached the pack"
    grep -qxF "$(printf 'dropped\t%s' "$heading")" "$(dirname "$pack").excluded-paths" || fail "'## $heading' is not listed as dropped"
  done
  pass "every section the outside rounds named, and every unlisted name, is dropped and listed"
}

test_unknown_heading_inside_a_known_section_refused() {
  local src="$TMP_ROOT/in.md" heading n=0
  # Round 1 F1, round 2 F2 and F3: an unknown sub-heading inside a known section could hide
  # author text or carry part of a criterion, so the build stops and names it.
  for heading in '### Earlier findings and how I answered them' "#### Author's all-green candidate" '**Contract Review**' \
    '### Responses' '### Responses for client errors' '### Example'; do
    n=$((n + 1))
    printf '## Definition Of Done\n\n- **A1** (mandatory): return 204 on success.\n\n%s\n\n- **A2** (mandatory): ZZ-UNDER-ZZ fixed, passes.\n' "$heading" >"$src"
    build_rc "$TMP_ROOT/in-out-$n" --contract "$src"
    assert_equals 3 "$BUILD_RC" "'$heading' inside the Definition Of Done was not refused: $BUILD_ERR"
    assert_contains "$BUILD_ERR" "unknown heading inside a known section" "the refusal of '$heading' does not say why"
    assert_absent "$TMP_ROOT/in-out-$n" "a refused build left an output directory"
  done
  pass "an unknown sub-heading inside a known section stops the build and names it"
}

test_fenced_heading_is_text() {
  local src="$TMP_ROOT/fence.md" pack
  # Round 2 F3: a heading-shaped line inside a code fence is text of its section.
  # shellcheck disable=SC2016 # literal backticks: a Markdown code fence
  printf '## Definition Of Done\n\n```text\n### Example\n```\n\n- **A1** (mandatory): ZZ-A1-ZZ return 204 on success.\n' >"$src"
  build_pack pack --contract "$src" || fail "a fenced heading-shaped line was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-A1-ZZ" "$pack/target.md" "the criterion after a fenced heading-shaped line was dropped"
  assert_grep "### Example" "$pack/target.md" "the fenced line was dropped"
  pass "a heading-shaped line in a code fence is text of its section"
}

test_qualifiers_are_allow_listed_words_only() {
  local src="$TMP_ROOT/q.md" pack heading
  for heading in 'REQUEST (verbatim, from Main)' 'Definition Of Done (steer), revision 19' 'CONTEXT (neutral facts, with sources)' \
    'Rulings on this contract (Main 2686, 2697, 2708 (withdrawn) and 2715)' 'Known limits (disclosed, not criteria)' 'Hard gates (execution constraints)'; do
    printf '## Definition Of Done\n\n- **A1** (mandatory): x.\n\n## %s\n\nZZ-QUAL-ZZ\n' "$heading" >"$src"
    pack=''
    build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
    assert_grep "ZZ-QUAL-ZZ" "$pack/target.md" "the known heading '$heading' was dropped"
  done
  for heading in 'Context and earlier findings' 'Assumptions (author self-check)' 'Definition Of Done: author notes'; do
    printf '## Definition Of Done\n\n- **A1** (mandatory): x.\n\n## %s\n\nZZ-QUAL-ZZ\n' "$heading" >"$src"
    pack=''
    build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
    assert_no_grep "ZZ-QUAL-ZZ" "$pack/target.md" "the qualified heading '$heading' was admitted"
  done
  pass "a qualifier is admitted only when every word in it is on the allow-list"
}

test_title_and_text_outside_a_section() {
  local src="$TMP_ROOT/t.md" pack
  # A first level 1 heading that is exactly a known name is that section, not a title.
  printf '# Definition Of Done\n\n- **A1** (mandatory): ZZ-TITLE-DOD-ZZ x.\n' >"$src"
  build_pack pack --contract "$src" || fail "a Definition Of Done title was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-TITLE-DOD-ZZ" "$pack/target.md" "the exact-name title section was dropped"
  # Text after the title and before the first known section is dropped and listed.
  printf '# Some contract\n\nZZ-OUTSIDE-ZZ an all-green self-check.\n\n## Definition Of Done\n\n- **A1** (mandatory): x.\n' >"$src"
  pack=''
  build_pack pack --contract "$src" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  assert_no_grep "ZZ-OUTSIDE-ZZ" "$pack/target.md" "text outside a known section reached the pack"
  assert_grep "text outside a known section" "$(dirname "$pack").excluded-paths" "the dropped text is not listed"
  pass "a title is dropped unless it is exactly a known name, and text outside a known section is dropped and listed"
}

test_unclosed_fence_refused() {
  local src="$TMP_ROOT/uf.md"
  # shellcheck disable=SC2016 # literal backticks: a Markdown code fence
  printf '## Definition Of Done\n\n- **A1** (mandatory): x.\n\n```text\nnever closed\n' >"$src"
  build_rc "$TMP_ROOT/uf-out" --contract "$src"
  assert_equals 3 "$BUILD_RC" "an unclosed fence was accepted: $BUILD_ERR"
  assert_contains "$BUILD_ERR" "never closes" "the refusal does not name the fence"
  assert_absent "$TMP_ROOT/uf-out" "a refused build left an output directory"
  pass "a code fence that never closes stops the build"
}

test_request_and_context_admitted_whole_by_role() {
  local src="$TMP_ROOT/rc.md" req="$TMP_ROOT/rc-request.md" ctx="$TMP_ROOT/rc-context.md" pack manifest f here
  write_fixture_contract "$src"
  printf 'The owner asked for the thing.\n' >"$req"
  printf '# Owner context\n\n## Main2632 — exact routed amendment\n\nZZ-OWNER-ZZ ruling.\n\n**Contract review scope**\n\nscope.\n' >"$ctx"
  build_pack pack --contract "$src" --request "$req" --context "$ctx" || fail "build failed: $(cat "$TMP_ROOT/build.err")"
  cmp -s "$req" "$pack/request.md" || fail "the request was not copied whole"
  cmp -s "$ctx" "$pack/context-rc-context.md" || fail "the context file was not copied whole"
  manifest="$(dirname "$pack").excluded-paths"
  here=$(cd "$TMP_ROOT" && pwd -P)
  for f in "request	$here/rc-request.md" "context	$here/rc-context.md"; do
    grep -qxF "$(printf 'admitted-whole-by-role\t%s' "$f")" "$manifest" || fail "the excluded record does not list: $f"
  done
  pass "a request or context file is copied whole and recorded as admitted whole by role"
}

test_single_source_policy_block() {
  local src="$TMP_ROOT/s.md" pack pack2 policy2="$TMP_ROOT/policy2.md"
  write_fixture_contract "$src"
  build_pack pack --contract "$src" || fail "build failed"
  policy_block "$POLICY" "$TMP_ROOT/block.expected"
  policy_block "$pack/contract.md" "$TMP_ROOT/block.actual"
  cmp -s "$TMP_ROOT/block.expected" "$TMP_ROOT/block.actual" || fail "the pack's reviewer block is not the policy block byte for byte"
  awk '{ print } $0 == "<!-- reviewer-block:begin -->" { print "Probe line that only this copy holds." }' "$POLICY" >"$policy2"
  build_pack pack2 --contract "$src" --policy "$policy2" || fail "build with the edited policy failed"
  assert_grep "Probe line that only this copy holds." "$pack2/contract.md" "the builder keeps its own copy of the rule text"
  assert_no_grep "Probe line that only this copy holds." "$pack/contract.md" "the unedited pack carries the probe line"
  pass "the builder copies the policy's reviewer block byte for byte and follows an edited policy"
}

test_pack_layout_and_fresh_parent() {
  local src="$TMP_ROOT/l.md" pack parent f
  write_fixture_contract "$src"
  build_pack pack --contract "$src" || fail "build failed"
  for f in contract.md target.md head.txt ci-evidence.md diff.patch; do
    assert_present "$pack/$f" "pack file $f missing"
  done
  [ ! -s "$pack/diff.patch" ] || fail "the diff slot is not empty"
  parent=$(dirname "$pack")
  assert_equals "pack" "$(ls -A "$parent")" "the pack's parent holds more than the pack"
  build_rc "$parent" --contract "$src"
  assert_equals 2 "$BUILD_RC" "a build into a directory that holds a pack must be refused"
  mkdir -p "$TMP_ROOT/l-review"
  printf 'old report\n' >"$TMP_ROOT/l-review/review.md"
  build_rc "$TMP_ROOT/l-review" --contract "$src"
  assert_equals 2 "$BUILD_RC" "a build into a directory that holds a review.md must be refused"
  assert_equals "old report" "$(cat "$TMP_ROOT/l-review/review.md")" "a refused build changed the existing report"
  pass "each pack is built fresh, alone in its parent, and never beside an earlier report"
}

test_fails_safe_on_bad_input() {
  local src="$TMP_ROOT/f.md" rc
  write_fixture_contract "$src"
  build_rc "$TMP_ROOT/f1" --contract "$TMP_ROOT/absent.md"
  assert_equals 2 "$BUILD_RC" "a missing contract must exit 2"
  assert_absent "$TMP_ROOT/f1" "a missing contract left an output directory"
  build_rc "$TMP_ROOT/f2" --contract "$src" --policy "$TMP_ROOT/absent-policy.md"
  assert_equals 2 "$BUILD_RC" "an unreadable policy must exit 2"
  assert_absent "$TMP_ROOT/f2" "an unreadable policy left an output directory"
  printf '# No done here\n\n## REQUEST\n\nA request only.\n' >"$TMP_ROOT/nodod.md"
  build_rc "$TMP_ROOT/f3" --contract "$TMP_ROOT/nodod.md"
  assert_equals 2 "$BUILD_RC" "a contract with no Definition Of Done must exit 2"
  assert_absent "$TMP_ROOT/f3" "a contract with no Definition Of Done left an output directory"
  [ "$(printf '%s\n' "$BUILD_ERR" | wc -l | tr -d ' ')" = 1 ] || fail "the failure cause is not one line: $BUILD_ERR"
  printf 'no markers here\n' >"$TMP_ROOT/badpolicy.md"
  build_rc "$TMP_ROOT/f4" --contract "$src" --policy "$TMP_ROOT/badpolicy.md"
  assert_equals 2 "$BUILD_RC" "a policy with no reviewer block must exit 2"
  assert_absent "$TMP_ROOT/f4" "a policy with no reviewer block left an output directory"
  rc=0
  "$PACK_BIN" build --contract "$src" --out-root "$TMP_ROOT/f5" >/dev/null 2>"$TMP_ROOT/f5.err" || rc=$?
  assert_equals 2 "$rc" "a build with no --root was accepted"
  assert_contains "$(cat "$TMP_ROOT/f5.err")" "--root is required" "the refusal does not name --root"
  assert_absent "$TMP_ROOT/f5" "a build with no --root left an output directory"
  pass "bad input exits 2 with a one-line cause and writes nothing"
}

test_policy_and_arguments_have_one_form() {
  local src="$TMP_ROOT/s-one-way.md" pack policy2="$TMP_ROOT/policy-env.md"
  write_fixture_contract "$src"
  awk '{ print } $0 == "<!-- reviewer-block:begin -->" { print "Probe line that only the environment copy holds." }' "$POLICY" >"$policy2"
  pack=''
  FM_CONTRACT_REVIEW_POLICY="$policy2" build_pack pack --contract "$src" || fail "build with a policy variable set failed: $(cat "$TMP_ROOT/build.err")"
  assert_no_grep "Probe line that only the environment copy holds." "$pack/contract.md" "the builder took the policy from the environment"
  pack=''
  build_pack pack --contract "$src" --policy "$policy2" || fail "build with --policy failed: $(cat "$TMP_ROOT/build.err")"
  assert_grep "Probe line that only the environment copy holds." "$pack/contract.md" "--policy no longer names the policy"
  build_rc "$TMP_ROOT/lab" --contract "$src" --label probe-label
  assert_equals 2 "$BUILD_RC" "--label was accepted"
  assert_contains "$BUILD_ERR" "unknown argument: --label" "--label was refused for another cause"
  pass "--policy is the one way to name the policy, and --label is not an argument"
}

# --- the transcript read check -------------------------------------------------

make_leak_world() { # builds LEAK_* variables
  LEAK_ROOT="$TMP_ROOT/leak-root"
  LEAK_SKILLS="$TMP_ROOT/leak-skills"
  rm -rf "$LEAK_ROOT" "$LEAK_SKILLS" "$TMP_ROOT/work" "$TMP_ROOT/sibling"
  mkdir -p "$LEAK_ROOT/bin" "$LEAK_ROOT/docs" "$LEAK_ROOT/data/case/truth" "$LEAK_ROOT/sources" "$LEAK_ROOT/notes" \
    "$LEAK_SKILLS/assess-done-and-grade" "$LEAK_SKILLS/define-done-and-grading"
  printf '#!/bin/sh\n' >"$LEAK_ROOT/bin/fm-spawn.sh"
  printf 'rubric\n' >"$LEAK_ROOT/docs/review-rubric.md"
  printf 'tracked excluded file\n' >"$LEAK_ROOT/sources/notes.md"
  printf 'a tracked plan\n' >"$LEAK_ROOT/notes/plan.md"
  write_fixture_contract "$LEAK_ROOT/sources/raw-contract.md"
  printf 'data/\nsecret.md\n.env\n' >"$LEAK_ROOT/.gitignore"
  printf 'secret\n' >"$LEAK_ROOT/secret.md"
  printf 'an earlier review report\n' >"$LEAK_ROOT/data/case/truth/r23-review.md"
  printf 'assess\n' >"$LEAK_SKILLS/assess-done-and-grade/SKILL.md"
  printf 'define\n' >"$LEAK_SKILLS/define-done-and-grading/SKILL.md"
  printf 'boundaries\n' >"$LEAK_SKILLS/define-done-and-grading/OPERATIONAL-BOUNDARIES.md"
  fm_git_init_commit "$LEAK_ROOT"
  git -C "$LEAK_ROOT" add bin docs sources notes README.md .gitignore
  git -C "$LEAK_ROOT" -c user.name=t -c user.email=t@example.invalid commit -qm files
  LEAK_PACK=''
  build_pack LEAK_PACK --contract "$LEAK_ROOT/sources/raw-contract.md" --root "$LEAK_ROOT" \
    --exclude "$LEAK_ROOT/sources/notes.md" || fail "leak world build failed: $(cat "$TMP_ROOT/build.err")"
  LEAK_WORK="$TMP_ROOT/work/$(basename "$(dirname "$LEAK_PACK")")-pack"
  mkdir -p "$LEAK_WORK" "$TMP_ROOT/sibling/pack"
  printf 'VERDICT: PASS\n' >"$TMP_ROOT/sibling/pack/review.md"
}

# One tool call of a session transcript: tool_call <name> <key> <value> [<key> <value>]...
# A tasks value, and the words true and false, are JSON.
tool_call() {
  python3 -I -c 'import json, sys
a = sys.argv[2:]
args = {}
for k, v in zip(a[0::2], a[1::2]):
    args[k] = json.loads(v) if k == "tasks" or v in ("true", "false") else v
print(json.dumps({"type": "toolCall", "name": sys.argv[1], "arguments": args}))' "$@"
}

# write_transcript <file> <cwd> <tool-call-json>...: a session transcript, one message per call.
write_transcript() {
  local f=$1 cwd=$2 call
  shift 2
  mkdir -p "$(dirname "$f")"
  python3 -I -c 'import json, sys; print(json.dumps({"type": "session", "version": 3, "id": "t", "cwd": sys.argv[1]}))' "$cwd" >"$f"
  for call in "$@"; do
    printf '{"type":"message","message":{"role":"assistant","content":[%s]}}\n' "$call" >>"$f"
  done
}

run_check() { # <log> [pack] -> sets CHECK_OUT and CHECK_RC
  CHECK_RC=0
  CHECK_OUT=$(REVIEW_SKILLS_DIR="$LEAK_SKILLS" REVIEW_RUBRIC="$LEAK_ROOT/docs/review-rubric.md" REVIEW_FM_ROOT="$LEAK_ROOT" \
    "$PACK_BIN" check --pack "${2:-$LEAK_PACK}" --log "$1" 2>&1) || CHECK_RC=$?
}

test_clean_transcript_is_clean() {
  local log="$TMP_ROOT/clean/s.jsonl" rev
  make_leak_world
  git -C "$LEAK_ROOT" remote add origin https://github.com/owner/repo.git
  rev=$(git -C "$LEAK_ROOT" log -1 --format=%H -- docs/review-rubric.md)
  printf 'scratch\n' >"$LEAK_WORK/probe.txt"
  write_transcript "$log" "$LEAK_WORK" \
    "$(tool_call read path skill://assess-done-and-grade)" "$(tool_call read path skill://define-done-and-grading)" \
    "$(tool_call read path "$LEAK_PACK/contract.md:raw:1-11")" "$(tool_call read path "$LEAK_PACK/target.md:-1")" \
    "$(tool_call read path "$LEAK_PACK/request.md")" "$(tool_call read path probe.txt)" \
    "$(tool_call read path "$LEAK_SKILLS/define-done-and-grading/SKILL.md")" \
    "$(tool_call read path "$LEAK_ROOT/docs/review-rubric.md")" \
    "$(tool_call read path "https://raw.githubusercontent.com/owner/repo/$rev/docs/review-rubric.md")" \
    "$(tool_call read path "$LEAK_ROOT/bin/fm-spawn.sh")" \
    "$(tool_call grep pattern A1 path "$LEAK_PACK" gitignore false)" \
    "$(tool_call grep pattern sh path "$LEAK_ROOT/bin" gitignore true)" \
    "$(tool_call write path "$LEAK_WORK/review.md" content x)"
  run_check "$log"
  assert_equals 0 "$CHECK_RC" "a clean transcript was not clean: $CHECK_OUT"
  assert_contains "$CHECK_OUT" "INPUT CLEAN" "a clean transcript did not say so"
  pass "reads of the pack, the work folder, the two skills, the rubric and tracked files are clean"
}

test_every_round_finding_read_is_a_leak() {
  local log="$TMP_ROOT/leak/s.jsonl" call n=0
  make_leak_world
  printf 'untracked\n' >"$LEAK_ROOT/notes/draft.md"
  printf 'boundaries\n' >"$LEAK_WORK/OPERATIONAL-BOUNDARIES.md"
  # Each read the two outside rounds showed certified clean, or that the boundary forbids.
  local -a calls=(
    "$(tool_call read path "$LEAK_ROOT/data/case/truth/r23-review.md")"
    "$(tool_call read path "$LEAK_ROOT/data/case/truth/r23-review.md:-1")"
    "$(tool_call read path "$TMP_ROOT/sibling/pack/review.md")"
    "$(tool_call read path "$LEAK_ROOT/sources/notes.md")"
    "$(tool_call read path "$LEAK_ROOT/sources/raw-contract.md")"
    "$(tool_call read path "$LEAK_ROOT/secret.md")"
    "$(tool_call grep pattern F1 path "$LEAK_ROOT/notes" gitignore true)"
    "$(tool_call grep pattern F1 path "$LEAK_ROOT" gitignore false)"
    "$(tool_call glob path "$LEAK_ROOT/data/**/*.md")"
    "$(tool_call read path skill://define-done-and-grading/OPERATIONAL-BOUNDARIES.md)"
    "$(tool_call read path skill://diagnostic-reasoning)"
    "$(tool_call read path "$LEAK_SKILLS/define-done-and-grading/OPERATIONAL-BOUNDARIES.md")"
    "$(tool_call read path "$LEAK_WORK/OPERATIONAL-BOUNDARIES.md")"
    "$(tool_call read path https://example.com/anything)"
    "$(tool_call read path pr://owner/repo/380)"
  )
  for call in "${calls[@]}"; do
    n=$((n + 1))
    write_transcript "$log" "$LEAK_WORK" "$(tool_call read path "$LEAK_PACK/target.md")" "$call"
    run_check "$log"
    assert_equals 3 "$CHECK_RC" "leak $n was not a leak: $call -> $CHECK_OUT"
    assert_contains "$CHECK_OUT" "ROUND VOID" "leak $n did not void the round"
  done
  pass "every forbidden read, search, selector, skill child and scheme voids the round"
}

test_unauditable_calls_are_never_clean() {
  local dir="$TMP_ROOT/unv" call n=0
  make_leak_world
  local -a calls=(
    "$(tool_call bash command "cat $LEAK_PACK/target.md")"
    "$(tool_call eval code "open('x')")"
    "$(tool_call web_search query anything)"
    "$(tool_call task context probe tasks '[{"name":"GuardScout"}]')"
  )
  for call in "${calls[@]}"; do
    n=$((n + 1))
    rm -rf "$dir"
    write_transcript "$dir/s.jsonl" "$LEAK_WORK" "$(tool_call read path "$LEAK_PACK/target.md")" "$call"
    run_check "$dir"
    assert_equals 4 "$CHECK_RC" "unauditable call $n was certified: $call -> $CHECK_OUT"
    assert_contains "$CHECK_OUT" "ROUND UNVERIFIED" "unauditable call $n did not leave the round unverified"
    run_check "$dir/s.jsonl"
    assert_equals 4 "$CHECK_RC" "unauditable call $n in a single-file log was certified: $CHECK_OUT"
  done
  # Compliant control: a subagent whose transcript is in the log folder and reads only the pack.
  rm -rf "$dir"
  write_transcript "$dir/s.jsonl" "$LEAK_WORK" "$(tool_call task context probe tasks '[{"name":"GuardScout"}]')"
  write_transcript "$dir/s/GuardScout.jsonl" "$LEAK_WORK" "$(tool_call read path "$LEAK_PACK/target.md")"
  run_check "$dir"
  assert_equals 0 "$CHECK_RC" "a subagent with its own clean transcript was not clean: $CHECK_OUT"
  # A subagent that reads a forbidden file is a leak.
  write_transcript "$dir/s/GuardScout.jsonl" "$LEAK_WORK" "$(tool_call read path "$LEAK_ROOT/data/case/truth/r23-review.md")"
  run_check "$dir"
  assert_equals 3 "$CHECK_RC" "a subagent's forbidden read was not a leak: $CHECK_OUT"
  pass "shell, eval, other tools and subagents with no transcript are never clean; a recorded subagent is judged"
}

test_pack_in_a_spaced_or_bracketed_folder_is_clean() {
  local pack log="$TMP_ROOT/sp/s.jsonl" parent
  make_leak_world
  # Round 1 F5 and round 2 F5: an authorized pack path in a spaced or bracketed folder.
  for parent in "parent with spaces" "parent (case)"; do
    pack=''
    build_pack pack --contract "$LEAK_ROOT/sources/raw-contract.md" --root "$LEAK_ROOT" --out-root "$TMP_ROOT/$parent" ||
      fail "build into '$parent' failed: $(cat "$TMP_ROOT/build.err")"
    write_transcript "$log" "$REVIEW_WORK_ROOT/$parent-pack" "$(tool_call read path "$pack/target.md")"
    run_check "$log" "$pack"
    assert_equals 0 "$CHECK_RC" "a read of the pack in '$parent' was not clean: $CHECK_OUT"
  done
  pass "a pack in a folder whose name holds spaces or brackets is read cleanly"
}

test_log_must_be_a_transcript() {
  local rc=0
  make_leak_world
  REVIEW_SKILLS_DIR="$LEAK_SKILLS" "$PACK_BIN" check --pack "$LEAK_PACK" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a check with no --log ran"
  printf 'Working...\nVERDICT: PASS\n' >"$TMP_ROOT/text.log"
  run_check "$TMP_ROOT/text.log"
  assert_equals 2 "$CHECK_RC" "a text log with no tool call was certified: $CHECK_OUT"
  pass "the check needs the session transcript, and refuses a log that records no tool call"
}

test_criterion_title_with_an_author_term_refused() {
  local src="$TMP_ROOT/ct.md" heading n=0 pack
  # Main 1904 F1: a criterion title that names author history is an unknown sub-heading.
  for heading in '### Responses - mandatory' '### Responses — supporting' '### Owner background - mandatory' \
    '### Earlier findings - mandatory' '### Contract Review - mandatory' "### Author's all-green candidate - mandatory" '### Responses'; do
    n=$((n + 1))
    printf '## Definition Of Done\n\n### Mandatory\n\n- **A1** (mandatory): return 204 on success.\n\n%s\n\n- **A2** (mandatory): A1 is fixed, passes. The author confirms all green.\n' "$heading" >"$src"
    build_rc "$TMP_ROOT/ct-out-$n" --contract "$src"
    assert_equals 3 "$BUILD_RC" "'$heading' was not refused: $BUILD_ERR"
    assert_absent "$TMP_ROOT/ct-out-$n" "a refused build left an output directory"
  done
  # Compliant control: a criterion title that names no author term builds.
  printf '## Definition Of Done\n\n### Picker cutover — mandatory\n\n- ZZ-PICKER-ZZ the picker routes by the declared set.\n' >"$src"
  pack=''
  build_pack pack --contract "$src" || fail "a neutral criterion title was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-PICKER-ZZ" "$pack/target.md" "the neutral criterion title's text was dropped"
  pass "a criterion title that names author history is refused; a neutral criterion title builds"
}

test_first_level_one_known_heading_is_a_section() {
  local src="$TMP_ROOT/f1.md" pack
  # Main 1904 F2: a first level 1 heading that is a known section with a qualifier is that section.
  printf '# REQUEST (verbatim)\n\nZZ-REQUEST-BODY-ZZ the owner asks for the thing.\n\n## Definition Of Done\n\n- **A1** (mandatory): ZZ-A1-ZZ it exists.\n' >"$src"
  build_pack pack --contract "$src" || fail "a qualified REQUEST title was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-REQUEST-BODY-ZZ" "$pack/target.md" "the REQUEST body under a qualified level 1 heading was dropped"
  assert_grep "ZZ-A1-ZZ" "$pack/target.md" "the Definition Of Done after a level 1 REQUEST was dropped"
  printf '# Definition Of Done (steer)\n\n- **A1** (mandatory): ZZ-DOD-STEER-ZZ it exists.\n' >"$src"
  pack=''
  build_pack pack --contract "$src" || fail "a qualified Definition Of Done title was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-DOD-STEER-ZZ" "$pack/target.md" "the qualified Definition Of Done body was dropped"
  # Ambiguous: a first heading that starts with a known name but carries a free qualifier.
  printf '# Definition of done: some-task\n\nZZ-AMBIG-ZZ\n\n## Definition Of Done\n\n- **A1** (mandatory): x.\n' >"$src"
  build_rc "$TMP_ROOT/f1-ambig" --contract "$src"
  assert_equals 3 "$BUILD_RC" "an ambiguous first heading was not refused: $BUILD_ERR"
  # Control: a title that names no known section is dropped as the title.
  printf '# Fixture contract\n\n## Definition Of Done\n\n- **A1** (mandatory): ZZ-CTRL-ZZ x.\n' >"$src"
  pack=''
  build_pack pack --contract "$src" || fail "a plain title was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-CTRL-ZZ" "$pack/target.md" "the control contract lost its Definition Of Done"
  assert_no_grep "Fixture contract" "$pack/target.md" "the plain title reached the pack"
  pass "a first level 1 known heading is its section, an ambiguous one is refused, and a plain title is dropped"
}

test_lost_or_empty_criteria_refused() {
  local src="$TMP_ROOT/lc.md" heading n=0 pack
  # Main 1904 F3: a known sub-section name outside the Definition Of Done, and an empty Definition Of Done.
  for heading in '## Mandatory' '## Supporting'; do
    n=$((n + 1))
    printf '## Definition Of Done\n\n%s\n\n- **A1** (mandatory): return 204 on success.\n' "$heading" >"$src"
    build_rc "$TMP_ROOT/lc-out-$n" --contract "$src"
    assert_equals 3 "$BUILD_RC" "'$heading' after the Definition Of Done was not refused: $BUILD_ERR"
    assert_absent "$TMP_ROOT/lc-out-$n" "a refused build left an output directory"
  done
  printf '## REQUEST\n\nr\n\n## Definition Of Done\n\n## How You'"'"'re Graded\n\ng\n' >"$src"
  build_rc "$TMP_ROOT/lc-empty" --contract "$src"
  assert_equals 3 "$BUILD_RC" "an empty Definition Of Done was not refused: $BUILD_ERR"
  # Control: the canonical sub-section keeps its criteria.
  printf '## Definition Of Done\n\n### Mandatory\n\n- **A1** (mandatory): ZZ-A1-KEPT-ZZ return 204.\n' >"$src"
  pack=''
  build_pack pack --contract "$src" || fail "a canonical ### Mandatory was refused: $(cat "$TMP_ROOT/build.err")"
  assert_grep "ZZ-A1-KEPT-ZZ" "$pack/target.md" "the criterion under ### Mandatory was dropped"
  pass "criteria under a known sub-section name outside the Definition Of Done, or an empty Definition Of Done, stop the build"
}

test_internal_record_schemes_are_leaks() {
  local log="$TMP_ROOT/sch/s.jsonl" uri
  make_leak_world
  # Main 1904 F4: no agent, artifact, proc or history record is proven to be this run's.
  for uri in agent://SomeoneElsesAgent agent://all artifact://another-run-output proc://another-job/output history://an-earlier-review-session; do
    write_transcript "$log" "$LEAK_WORK" "$(tool_call read path "$LEAK_PACK/target.md")" "$(tool_call read path "$uri")"
    run_check "$log"
    assert_equals 3 "$CHECK_RC" "a read of $uri was not a leak: $CHECK_OUT"
  done
  # Control: the run's own log stays readable by path.
  write_transcript "$log" "$LEAK_WORK" "$(tool_call read path "$log")"
  run_check "$log"
  assert_equals 0 "$CHECK_RC" "a read of the run's own log by path was flagged: $CHECK_OUT"
  pass "every agent, artifact, proc and history read is a leak; the run's own log stays readable by path"
}

test_session_outside_the_recorded_work_folder_refused() {
  local log="$TMP_ROOT/cwd/s.jsonl" cwd
  make_leak_world
  printf 'not excluded\n' >"$LEAK_ROOT/data/case/truth/not-excluded.md"
  # Main 1904 F5: the work folder comes from the excluded record, never from the transcript.
  grep -qxF "$(printf 'work\t%s' "$(cd "$LEAK_WORK" && pwd -P)")" "$(dirname "$LEAK_PACK").excluded-paths" ||
    fail "the excluded record does not hold the work folder $LEAK_WORK"
  for cwd in / "$LEAK_ROOT"; do
    write_transcript "$log" "$cwd" "$(tool_call read path "$LEAK_PACK/target.md")"
    run_check "$log"
    assert_equals 3 "$CHECK_RC" "a session in $cwd was not refused: $CHECK_OUT"
    write_transcript "$log" "$cwd" "$(tool_call read path "$LEAK_ROOT/data/case/truth/not-excluded.md")"
    run_check "$log"
    assert_equals 3 "$CHECK_RC" "a session in $cwd certified an ignored read: $CHECK_OUT"
  done
  # Control: a session in the recorded work folder.
  write_transcript "$log" "$LEAK_WORK" "$(tool_call read path "$LEAK_PACK/target.md")"
  run_check "$log"
  assert_equals 0 "$CHECK_RC" "a session in the recorded work folder was flagged: $CHECK_OUT"
  pass "a session outside the recorded work folder is refused, and one inside it is judged"
}

test_gitignore_true_search_is_clean() {
  local log="$TMP_ROOT/gi/s.jsonl"
  make_leak_world
  # A tracked folder that also holds an ignored sub-folder.
  mkdir -p "$LEAK_ROOT/docs/build"
  printf 'ignored build output\n' >"$LEAK_ROOT/docs/build/out.md"
  printf 'docs/build/\n' >>"$LEAK_ROOT/.gitignore"
  git -C "$LEAK_ROOT" -c user.name=t -c user.email=t@example.invalid commit -qam "ignore docs/build"
  # Main 1904 F6: a search that passes gitignore true over tracked files and ignored ones is clean.
  write_transcript "$log" "$LEAK_WORK" "$(tool_call grep pattern x path "$LEAK_ROOT/docs" gitignore true)"
  run_check "$log"
  assert_equals 0 "$CHECK_RC" "a gitignore true search over a tracked folder was flagged: $CHECK_OUT"
  # The same search without the setting may read ignored files, so it is not proven clean.
  write_transcript "$log" "$LEAK_WORK" "$(tool_call grep pattern x path "$LEAK_ROOT/docs")"
  run_check "$log"
  assert_equals 3 "$CHECK_RC" "a search with no gitignore setting was certified: $CHECK_OUT"
  pass "a gitignore true search over tracked and ignored files is clean; one without the setting is not"
}

fm_test_run_cases \
  test_known_sections_pass_byte_identical \
  test_every_round_finding_section_is_dropped \
  test_unknown_heading_inside_a_known_section_refused \
  test_fenced_heading_is_text \
  test_qualifiers_are_allow_listed_words_only \
  test_title_and_text_outside_a_section \
  test_unclosed_fence_refused \
  test_request_and_context_admitted_whole_by_role \
  test_single_source_policy_block \
  test_pack_layout_and_fresh_parent \
  test_fails_safe_on_bad_input \
  test_policy_and_arguments_have_one_form \
  test_clean_transcript_is_clean \
  test_every_round_finding_read_is_a_leak \
  test_unauditable_calls_are_never_clean \
  test_pack_in_a_spaced_or_bracketed_folder_is_clean \
  test_log_must_be_a_transcript \
  test_criterion_title_with_an_author_term_refused \
  test_first_level_one_known_heading_is_a_section \
  test_lost_or_empty_criteria_refused \
  test_internal_record_schemes_are_leaks \
  test_session_outside_the_recorded_work_folder_refused \
  test_gitignore_true_search_is_clean \
  -- "$@"
