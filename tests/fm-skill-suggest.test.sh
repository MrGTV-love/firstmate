#!/usr/bin/env bash
# Public skill-advice behavior: independent fits, no-fit, required names,
# bounded two-stage disclosure, unavailable/malformed output and memoization.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-skill-suggest)
HOME_DIR="$TMP_ROOT/home"
CATALOG="$TMP_ROOT/skills"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
TASK="$TMP_ROOT/task"
BRIEF="$TMP_ROOT/brief"
mkdir -p "$HOME_DIR/config" "$CATALOG" "$LOG"
for id in alpha beta gamma delta safety; do
  mkdir -p "$CATALOG/$id"
  cat > "$CATALOG/$id/SKILL.md" <<MD
---
name: $id
description: >-
  Use for $id work, with
  its complete description retained.
---
# $id
Opening instructions for $id.
MD
done
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -eu
out=
while [ $# -gt 0 ]; do
  case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac
done
cat > "$LOG/request"
cat /dev/fd/3 > "$LOG/header"
printf 'call\n' >> "$LOG/calls"
if [ "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}" != "" ]; then exit 10; fi
case "${MODE:-multiple}" in
  timeout) exit 28 ;;
  malformed) printf '{"answers":{}}' > "$out" ;;
  wrong-model) printf '{"model":"unexpected","answers":{}}' > "$out" ;;
  invalid-number) jq '{model:"jev-1.13.0",usage:{input_tokens:10,output_tokens:3},answers:(.questions | with_entries(.value={type:"noul",noul:2}))}' "$LOG/request" > "$out" ;;
  missing-answer) jq '{model:"jev-1.13.0",usage:{input_tokens:10,output_tokens:3},answers:(.questions | with_entries(.value={type:"noul",noul:0.8}) | del(.need))}' "$LOG/request" > "$out" ;;
  *)
    jq --arg mode "${MODE:-multiple}" '
      . as $request | {model:"jev-1.13.0",usage:{input_tokens:10,output_tokens:3},answers:(.questions | with_entries(.key as $id | .value={type:"noul",noul:
        (if $mode == "none" then 0.05
         elif $mode == "recheck-none" and ($request.state.catalog[0] | has("excerpt")) then 0.05
         elif $id == "need" then 0.8
         elif $id == "skill_alpha" then 0.8
         elif $id == "skill_beta" then 0.7
         elif $id == "skill_gamma" then 0.4
         else 0.05 end)}))}' "$LOG/request" > "$out"
    if [ "${MODE:-}" = recheck-malformed ] && jq -e '.state.catalog[0] | has("excerpt")' "$LOG/request" >/dev/null; then
      printf '{"answers":{}}' > "$out"
    fi
    ;;
esac
if jq -e '.state.catalog[0] | has("excerpt")' "$LOG/request" >/dev/null 2>&1; then
  cp "$LOG/request" "$LOG/recheck"
else
  cp "$LOG/request" "$LOG/rank"
fi
printf 200
SH
chmod +x "$FAKEBIN/curl"
export LOG
TOOL="$ROOT/bin/fm-skill-suggest.sh"
run() { PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="${KEY-}" MODE="${MODE:-multiple}" bash "$TOOL" --catalog "$CATALOG" "$@"; }
reset() { rm -f "$LOG"/* "$HOME_DIR/state/skill-advice.json"; }
printf 'Perform alpha and related work.\n' > "$TASK"
out=$(run --task-file "$TASK")
assert_contains "$out" 'status: off' "missing key uses ordinary selection"
assert_contains "$out" 'required[1]' "explicitly named alpha survives missing key"
assert_absent "$LOG/calls" "missing key makes no call"
pass "missing key preserves named workflows without a network request"

KEY=test-key
printf 'Perform a combined task.\n' > "$TASK"
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'suggestions[2]' "two independent skills coexist"
assert_contains "$out" 'required[1]' "role safety supplied by caller survives"
assert_contains "$out" 'opening-instruction recheck' "ambiguous fits are rechecked"
assert_equals '2' "$(wc -l < "$LOG/calls" | tr -d ' ')" "one bounded batch per stage"
jq -e '.state.catalog | length == 3 and all(.[]; (.excerpt | length) <= 700)' "$LOG/recheck" >/dev/null || fail "recheck must disclose at most three bounded excerpts"
jq -e '.state.catalog | all(.[]; (has("path") or has("body_hash") or has("excerpt")) | not)' "$LOG/rank" >/dev/null || fail "rank must not disclose local paths, hashes or bodies"
jq -e '.state.catalog[] | select(.id == "alpha") | .description == "Use for alpha work, with its complete description retained."' "$LOG/rank" >/dev/null || fail "full folded description must survive"
pass "multiple optional skills, safety requirements and bounded progressive disclosure"

out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'source: cache' "identical result is reused"
assert_equals '2' "$(wc -l < "$LOG/calls" | tr -d ' ')" "memoized intake avoids network"
printf 'Changed task intent.\n' > "$TASK"
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'source: live' "changed intent invalidates"
printf '\nChanged instructions.\n' >> "$CATALOG/alpha/SKILL.md"
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'source: live' "changed catalog invalidates"
printf 'safety\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(run --task-file "$TASK" --required safety)
# Required IDs are local and are not sent, so withholding one is not a remote match.
assert_contains "$out" 'source: live' "privacy policy change invalidates reuse without leaking local-only safety IDs"
printf 'changed task\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'status: off' "new deny rule overrides cached advice"
rm "$HOME_DIR/config/dispatch-never-send"
pass "memoization invalidates on task/catalog changes and respects updated privacy policy"

# A different task may atomically replace the shared entry after validation.
# Swap after the real jq validator returns, not by mocking its verdict.
out=$(run --task-file "$TASK" --required safety)
cp "$HOME_DIR/state/skill-advice.json" "$TMP_ROOT/validated-cache.json"
OTHER_TASK="$TMP_ROOT/other-task"
printf 'Use alpha for a separate task.\n' > "$OTHER_TASK"
out=$(run --task-file "$OTHER_TASK" --required beta)
cp "$HOME_DIR/state/skill-advice.json" "$TMP_ROOT/other-cache.json"
cp "$TMP_ROOT/validated-cache.json" "$HOME_DIR/state/skill-advice.json"
REAL_JQ=$(command -v jq)
export REAL_JQ
export CACHE_REPLACEMENT="$TMP_ROOT/other-cache.json" CACHE_TARGET="$HOME_DIR/state/skill-advice.json"
cat > "$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
set -u
"$REAL_JQ" "$@"
rc=$?
if [ "$rc" -eq 0 ] && [ "${1:-}" = -e ]; then
  case "$*" in
    *'--arg key '*)
      cp "$CACHE_REPLACEMENT" "$CACHE_TARGET.next" && mv "$CACHE_TARGET.next" "$CACHE_TARGET"
      printf 'replaced\n' > "$LOG/cache-replaced"
      ;;
  esac
fi
exit "$rc"
SH
chmod +x "$FAKEBIN/jq"
out=$(run --task-file "$TASK" --required safety)
assert_present "$LOG/cache-replaced" "the other task's atomic replacement must actually occur"
assert_contains "$out" 'source: cache' "validated cache snapshot is reusable"
assert_contains "$out" 'required[1]' "cache replacement cannot substitute another task's required IDs"
assert_contains "$out" "\"safety\",\"$CATALOG/safety/SKILL.md\"" "this task's safety ID survives the replacement"
assert_contains "$out" 'suggestions[2]' "this task's independent optional suggestions survive the replacement"
rm "$FAKEBIN/jq"
unset CACHE_REPLACEMENT CACHE_TARGET REAL_JQ
pass "an atomic replacement after validation cannot substitute another task's advice"

for MODE in none recheck-none timeout malformed recheck-malformed wrong-model invalid-number missing-answer; do
  reset
  out=$(run --task-file "$TASK" --required safety --no-cache)
  assert_contains "$out" 'suggestions[0]' "$MODE never guesses optional skills"
  assert_contains "$out" 'required[1]' "$MODE never suppresses role safety"
  case "$MODE" in none|recheck-none) assert_contains "$out" 'status: none' "$MODE is a valid no-fit" ;; *) assert_contains "$out" 'status: fallback' "$MODE restores ordinary selection" ;; esac
done
MODE=multiple
pass "no-fit at either stage and every transport/schema failure preserve ordinary selection"

reset
cat > "$BRIEF" <<'MD'
# Task
## Captain's intent
SECRET-INTENT never sent.
## Firstmate spec
SECRET-SPEC never sent.
# Skill selection input
Perform a combined task using safety.
# Rules
SECRET-RULES never sent.
MD
out=$(run --brief "$BRIEF" --format brief --no-cache)
assert_contains "$out" 'Required named skill: safety' "named safety preserved in additive advice"
assert_contains "$out" 'Optional suggestion: alpha' "brief has optional advice"
assert_not_contains "$(cat "$LOG/request")" SECRET "only permitted summary is disclosed"
assert_not_contains "$out" SECRET "source instructions never echoed"
assert_contains "$out" 'mandatory explicit/named and safety triggers first' "required trigger authority retained"
pass "supported brief input carries only minimal permitted text and additive advice"

reset
printf '\nSECRET-OPENING\n' >> "$CATALOG/alpha/SKILL.md"
printf 'secret-opening\n' > "$HOME_DIR/config/dispatch-never-send"
out=$(run --task-file "$TASK" --required safety --no-cache)
assert_contains "$out" 'status: off' "opening excerpts are checked before stage two"
assert_contains "$out" 'required[1]' "withheld excerpt never suppresses safety"
assert_equals '1' "$(wc -l < "$LOG/calls" | tr -d ' ')" "withheld opening makes only the permitted first call"
assert_not_contains "$(cat "$LOG/rank")" SECRET-OPENING "whole bodies are not ranked"
rm "$HOME_DIR/config/dispatch-never-send"
pass "a forbidden opening excerpt stops disclosure before the recheck"

cp "$CATALOG/delta/SKILL.md" "$TMP_ROOT/valid-delta.md"
for missing in frontmatter name description; do
  reset
  case "$missing" in
    frontmatter) printf '# Delta\nNo metadata.\n' ;;
    name) printf '%s\n' '---' 'description: Use for delta work.' '---' '# Delta' ;;
    description) printf '%s\n' '---' 'name: delta' '---' '# Delta' ;;
  esac > "$CATALOG/delta/SKILL.md"
  out=$(run --task-file "$TASK" --required safety --format brief --no-cache)
  assert_contains "$out" 'fallback: unsupported skill metadata' "missing $missing cannot silently shrink the catalog"
  assert_contains "$out" 'mandatory explicit/named and safety triggers first' "malformed metadata preserves ordinary required-trigger selection"
  assert_absent "$LOG/calls" "missing $missing stops before any API call"
done
cp "$TMP_ROOT/valid-delta.md" "$CATALOG/delta/SKILL.md"
pass "missing frontmatter, name or description restores ordinary selection without a call"

reset
printf '# Task\nLegacy intent only.\n' > "$BRIEF"
out=$(run --brief "$BRIEF" --no-cache)
assert_contains "$out" 'status: fallback' "unapproved summary never uses legacy task text"
assert_absent "$LOG/calls" "absent minimal summary makes no call"
printf '%5000s' large > "$TASK"
out=$(run --task-file "$TASK" --required safety --no-cache)
assert_contains "$out" 'task exceeds 4 KiB' "oversized task not semantically truncated"
assert_absent "$LOG/calls" "oversized task makes no call"

# A multibyte description can fit a character budget while exceeding the wire
# byte budget. It must be withheld before curl, not shortened or disclosed.
printf 'A permitted task.\n' > "$TASK"
{
  printf '%s\n' '---' 'name: delta' 'description: >-' '  '
  jq -nr '"  " + ("é" * 50000)'
  printf '%s\n' '---' '# Delta'
} > "$CATALOG/delta/SKILL.md"
out=$(run --task-file "$TASK" --required safety --no-cache)
assert_contains "$out" 'request exceeds 96 KiB' "request size is bounded in bytes, not characters"
assert_contains "$out" 'required[1]' "request budget never suppresses required skills"
assert_absent "$LOG/calls" "oversized multibyte request makes no call"
pass "multibyte catalog metadata cannot exceed the request byte budget"
set +e
out=$(run --task-file "$TASK" --requred safety)
code=$?
set -e
assert_equals '2' "$code" "unknown flag is a usage error"
assert_contains "$out" 'unknown argument --requred' "unknown flag explained"
pass "missing/oversized minimal input and unknown flags do not silently run another task"
