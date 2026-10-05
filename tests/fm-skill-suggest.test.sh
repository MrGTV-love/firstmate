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
git init -q "$CATALOG"
git -C "$CATALOG" add -- alpha beta gamma delta safety
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
REAL_DIRNAME=$(command -v dirname)
export REAL_DIRNAME
cat > "$FAKEBIN/dirname" <<'SH'
#!/usr/bin/env bash
if [ "${TYPESAFE_API_KEY+x}${TYPESAFE_API_KEY_PRIVATE+x}" != "" ]; then
  printf 'secret-present\n' >> "$LOG/dirname-env"
else
  printf 'clean\n' >> "$LOG/dirname-env"
fi
exec "$REAL_DIRNAME" "$@"
SH
chmod +x "$FAKEBIN/dirname"
KEY=startup-secret
out=$(run --help)
assert_contains "$out" 'Suggest optional skills' "help remains available"
assert_present "$LOG/dirname-env" "help exercises an early child"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "help scrubs inherited keys before dirname"
out=$(PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY=startup-secret bash -c 'cd "$1"; bash fm-skill-suggest.sh --help' _ "$ROOT/bin")
assert_contains "$out" 'Suggest optional skills' "bare filename source path works"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "bare filename scrubs before child startup"
out=$(PATH="$FAKEBIN:$ROOT/bin:$PATH" TYPESAFE_API_KEY=startup-secret fm-skill-suggest.sh --help)
assert_contains "$out" 'Suggest optional skills' "PATH invocation source path works"
out=$(PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY=startup-secret bash -c 'cd "$1"; bash bin/fm-skill-suggest.sh --help' _ "$ROOT")
assert_contains "$out" 'Suggest optional skills' "relative source path works"
SPACE_BIN="$TMP_ROOT/space containing/bin"
mkdir -p "$SPACE_BIN"
cp "$TOOL" "$ROOT/bin/fm-typesafe-lib.sh" "$ROOT/bin/fm-env-lib.sh" "$SPACE_BIN/"
out=$(PATH="$FAKEBIN:$PATH" TYPESAFE_API_KEY=startup-secret bash "$SPACE_BIN/fm-skill-suggest.sh" --help)
assert_contains "$out" 'Suggest optional skills' "space-containing source path works"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "all help entry paths scrub before children"
pass "picker startup source paths preserve early-child key isolation"
KEY=
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
assert_present "$LOG/dirname-env" "ordinary request exercises early child"
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "ordinary request scrubs keys before dirname"
assert_not_contains "$(cat "$LOG/rank")" safety "caller-required identity stays local"
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
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "withheld task never exposes keys to early children"
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

reset
BASE_CATALOG=$CATALOG
CATALOG="$TMP_ROOT/private-catalog"
mkdir -p "$CATALOG"
for id in alpha beta gamma delta safety; do
  mkdir -p "$CATALOG/$id"
  cp "$BASE_CATALOG/$id/SKILL.md" "$CATALOG/$id/SKILL.md"
done
printf '%s\n' '---' 'name: alpha' 'description: PRIVATE-DESCRIPTION' '---' 'PRIVATE-OPENING' > "$CATALOG/alpha/SKILL.md"
printf '%s\n' '---' 'name: delta' 'description: UNTRACKED-DESCRIPTION' '---' 'UNTRACKED-OPENING' > "$CATALOG/delta/SKILL.md"
git init -q "$CATALOG"
printf 'alpha/\n' >> "$CATALOG/.git/info/exclude"
git -C "$CATALOG" add -- beta gamma safety
git -C "$CATALOG" check-ignore -q alpha/SKILL.md || fail "private fixture must be git-excluded"
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'suggestions[1]' "public beta remains eligible alongside private skills"
assert_contains "$out" "\"beta\",\"$CATALOG/beta/SKILL.md\",0.7" "public skill keeps its ordinary advice path"
assert_equals '2' "$(wc -l < "$LOG/calls" | tr -d ' ')" "privacy regression exercises both outbound stages"
for stage in rank recheck; do
  jq -e '.state.catalog | map(.id) == ["beta","gamma"]' "$LOG/$stage" >/dev/null || fail "$stage may include only public optional entries"
  for private_text in alpha delta PRIVATE-DESCRIPTION PRIVATE-OPENING UNTRACKED-DESCRIPTION UNTRACKED-OPENING; do
    assert_not_contains "$(cat "$LOG/$stage")" "$private_text" "$stage never transmits private skill fields or question keys"
  done
done
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'source: cache' "public advice remains reusable"
assert_equals '2' "$(wc -l < "$LOG/calls" | tr -d ' ')" "cache reuse does not repeat requests"
out=$(run --task-file "$TASK" --required alpha --required safety --format brief --no-cache)
assert_contains "$out" "Required named skill: alpha - read $CATALOG/alpha/SKILL.md." "caller-required private skill stays locally resolvable"
assert_contains "$out" 'Optional suggestion: beta' "private requirement does not disable public advice"
assert_not_contains "$(cat "$LOG/request")" alpha "caller-required private identity is not sent"
git -C "$CATALOG" update-index --force-remove -- beta/SKILL.md
printf 'beta/\n' >> "$CATALOG/.git/info/exclude"
git -C "$CATALOG" check-ignore -q beta/SKILL.md || fail "formerly public skill must now be excluded"
out=$(run --task-file "$TASK" --required safety)
assert_contains "$out" 'source: live' "tracking-status change invalidates advice without changing skill bytes"
assert_contains "$out" 'suggestions[0]' "now-private cached beta is no longer optional remote advice"
for stage in rank recheck; do
  assert_not_contains "$(cat "$LOG/$stage")" beta "$stage omits the newly private skill"
done
cp "$TASK" "$TMP_ROOT/private-task-save"
printf 'Use alpha for this task.\n' > "$TASK"
printf '# Skill selection input\nUse alpha for this task.\n' > "$BRIEF"
for input in --task-file --brief; do
  reset
  if [ "$input" = --task-file ]; then input_path=$TASK; else input_path=$BRIEF; fi
  out=$(run "$input" "$input_path" --required safety --no-cache)
  assert_contains "$out" "\"alpha\",\"$CATALOG/alpha/SKILL.md\"" "task-named private skill remains required"
  assert_contains "$out" 'status: off' "private identity in task text is withheld rather than rewritten"
  assert_absent "$LOG/calls" "private task identity never reaches TypeSafe"
done
cp "$TMP_ROOT/private-task-save" "$TASK"
cp "$CATALOG/gamma/SKILL.md" "$TMP_ROOT/private-gamma.md"
rm "$CATALOG/gamma/SKILL.md"
ln -s "$TMP_ROOT/private-gamma.md" "$CATALOG/gamma/SKILL.md"
git -C "$CATALOG" add -- gamma/SKILL.md
reset
out=$(run --task-file "$TASK" --required safety --no-cache)
assert_contains "$out" "\"safety\",\"$CATALOG/safety/SKILL.md\"" "local requirements survive a symlinked optional entry"
assert_contains "$out" 'no public optional skills' "tracked symlink does not authorize private target disclosure"
assert_absent "$LOG/calls" "all-private optional catalog makes no request"
CATALOG="$TMP_ROOT/non-git-catalog"
mkdir -p "$CATALOG"
cp -R "$BASE_CATALOG/alpha" "$BASE_CATALOG/safety" "$CATALOG/"
out=$(run --task-file "$TASK" --required safety --no-cache)
assert_contains "$out" "\"safety\",\"$CATALOG/safety/SKILL.md\"" "non-Git catalog keeps local requirements"
assert_contains "$out" 'no public optional skills' "unverifiable catalog remains local"
assert_absent "$LOG/calls" "non-Git catalog makes no request"
CATALOG=$BASE_CATALOG
MODE=multiple
pass "private skills remain local across ranking, excerpts, requirements and cache transitions"

for MODE in none recheck-none timeout malformed recheck-malformed wrong-model invalid-number missing-answer; do
  reset
  out=$(run --task-file "$TASK" --required safety --no-cache)
  assert_contains "$out" 'suggestions[0]' "$MODE never guesses optional skills"
  assert_contains "$out" 'required[1]' "$MODE never suppresses role safety"
  case "$MODE" in none|recheck-none) assert_contains "$out" 'status: none' "$MODE is a valid no-fit" ;; *) assert_contains "$out" 'status: fallback' "$MODE restores ordinary selection" ;; esac
done
MODE=multiple
pass "no-fit at either stage and every transport/schema failure preserve ordinary selection"

cp "$TASK" "$TMP_ROOT/line-ending-task"
for id in alpha beta gamma delta safety; do
  cp "$CATALOG/$id/SKILL.md" "$TMP_ROOT/lf-$id.md"
done
printf 'Perform gamma work.\n' > "$TASK"
for endings in lf crlf; do
  if [ "$endings" = crlf ]; then
    for id in alpha beta gamma delta safety; do
      awk '{ printf "%s\r\n", $0 }' "$TMP_ROOT/lf-$id.md" > "$CATALOG/$id/SKILL.md"
    done
  fi
  for format in toon brief; do
    reset
    out=$(run --task-file "$TASK" --required safety --format "$format" --no-cache)
    if [ "$format" = toon ]; then
      assert_contains "$out" 'status: suggested' "$endings catalog supports optional selection"
      assert_contains "$out" "\"gamma\",\"$CATALOG/gamma/SKILL.md\"" "$endings resolves task-named requirement"
      assert_contains "$out" "\"safety\",\"$CATALOG/safety/SKILL.md\"" "$endings resolves supplied requirement"
      for id in alpha beta; do
        assert_contains "$out" "\"$id\",\"$CATALOG/$id/SKILL.md\",0." "$endings resolves optional skill path"
      done
    else
      for id in gamma safety; do
        assert_contains "$out" "Required named skill: $id - read $CATALOG/$id/SKILL.md." "$endings brief resolves requirement"
      done
      for id in alpha beta; do
        assert_contains "$out" "Optional suggestion: $id - read $CATALOG/$id/SKILL.md;" "$endings brief resolves suggestion"
      done
    fi
    jq -e '.state.catalog | map(.id) == ["alpha","beta","delta"] and all(.[]; .description == ("Use for " + .id + " work, with its complete description retained."))' "$LOG/rank" >/dev/null || fail "$endings must preserve folded descriptions and exclude required skills from ranking"
    for stage in rank recheck; do
      if [ "$endings" = lf ]; then
        cp "$LOG/$stage" "$TMP_ROOT/lf-$format-$stage.json"
      else
        jq -e --slurpfile expected "$TMP_ROOT/lf-$format-$stage.json" '.state.catalog == $expected[0].state.catalog' "$LOG/$stage" >/dev/null || fail "CRLF must preserve $stage metadata and excerpts"
      fi
    done
  done
done
for id in alpha beta gamma delta safety; do
  cp "$TMP_ROOT/lf-$id.md" "$CATALOG/$id/SKILL.md"
done
cp "$TMP_ROOT/line-ending-task" "$TASK"
pass "LF and CRLF catalogs preserve required identities, optional paths and wire metadata"

cp "$CATALOG/alpha/SKILL.md" "$TMP_ROOT/paragraph-alpha-save.md"
for indicator in '>' '>-' '|' '|-'; do
  printf '%s\n' '---' 'name: alpha' "description: $indicator" \
    '  Use for the first paragraph.' '' \
    '  Invoke the workflow for deployment.' '  ' \
    '  Retain the final safety guidance.' \
    'metadata:' '  internal: true' '---' '# Alpha' \
    'Opening instructions for alpha.' > "$TMP_ROOT/paragraph-alpha.md"
  case "$indicator" in
    '>'|'>-') expected='Use for the first paragraph.  Invoke the workflow for deployment.  Retain the final safety guidance.' ;;
    *) expected=$(printf 'Use for the first paragraph.\n\nInvoke the workflow for deployment.\n\nRetain the final safety guidance.') ;;
  esac
  for endings in lf crlf; do
    if [ "$endings" = crlf ]; then
      awk '{ printf "%s\r\n", $0 }' "$TMP_ROOT/paragraph-alpha.md" > "$CATALOG/alpha/SKILL.md"
    else
      cp "$TMP_ROOT/paragraph-alpha.md" "$CATALOG/alpha/SKILL.md"
    fi
    reset
    out=$(run --task-file "$TASK" --required safety --no-cache)
    assert_contains "$out" 'suggestions[2]' "$indicator $endings supports ordinary optional selection"
    assert_equals '2' "$(wc -l < "$LOG/calls" | tr -d ' ')" "$indicator $endings exercises rank and recheck"
    for stage in rank recheck; do
      jq -e --arg expected "$expected" '.state.catalog[] | select(.id == "alpha") | .description == $expected' "$LOG/$stage" >/dev/null || fail "$indicator $endings $stage must retain every description paragraph without unrelated metadata"
    done
  done
done
for scalar in 'Use for the first paragraph.' '"Use for the first paragraph."' "'Use for the first paragraph.'"; do
  printf '%s\n' '---' 'name: alpha' "description: $scalar" '' \
    '  Invoke the workflow for deployment.' '---' '# Alpha' > "$TMP_ROOT/paragraph-alpha.md"
  for endings in lf crlf; do
    if [ "$endings" = crlf ]; then
      awk '{ printf "%s\r\n", $0 }' "$TMP_ROOT/paragraph-alpha.md" > "$CATALOG/alpha/SKILL.md"
    else
      cp "$TMP_ROOT/paragraph-alpha.md" "$CATALOG/alpha/SKILL.md"
    fi
    reset
    out=$(run --task-file "$TASK" --required safety --required alpha --no-cache)
    assert_contains "$out" 'unsupported skill metadata' "$endings unsupported scalar continuation cannot be silently shortened"
    assert_contains "$out" "\"alpha\",\"$CATALOG/alpha/SKILL.md\"" "$endings identity-only parsing remains independent of descriptions"
    assert_contains "$out" "\"safety\",\"$CATALOG/safety/SKILL.md\"" "$endings rejected continuation preserves sibling requirements"
    assert_contains "$out" 'suggestions[0]' "$endings rejected continuation withholds optional advice"
    assert_absent "$LOG/calls" "$endings rejected continuation makes no request"
  done
done
cp "$TMP_ROOT/paragraph-alpha-save.md" "$CATALOG/alpha/SKILL.md"
pass "blank-separated description paragraphs survive both stages or fail closed without losing requirements"

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
assert_not_contains "$(cat "$LOG/dirname-env")" secret-present "withheld excerpt never exposes keys to early children"
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
  printf 'Perform gamma work.\n' > "$TASK"
  for format in toon brief; do
    out=$(run --task-file "$TASK" --required safety --format "$format" --no-cache)
    assert_contains "$out" 'unsupported skill metadata' "missing $missing cannot silently shrink the catalog"
    if [ "$format" = toon ]; then
      assert_contains "$out" "\"safety\",\"$CATALOG/safety/SKILL.md\"" "missing $missing retains supplied requirement"
      assert_contains "$out" "\"gamma\",\"$CATALOG/gamma/SKILL.md\"" "missing $missing retains named requirement after bad entry"
      assert_contains "$out" 'suggestions[0]' "invalid catalog withholds optional advice"
    else
      assert_contains "$out" "Required named skill: safety - read $CATALOG/safety/SKILL.md." "brief retains supplied requirement"
      assert_contains "$out" "Required named skill: gamma - read $CATALOG/gamma/SKILL.md." "brief retains named requirement after bad entry"
      assert_contains "$out" 'mandatory explicit/named and safety triggers first' "malformed metadata preserves authority"
      assert_not_contains "$out" 'read null' "brief never directs a null-path read"
    fi
    assert_absent "$LOG/calls" "missing $missing stops before any API call"
  done
done
cp "$TMP_ROOT/valid-delta.md" "$CATALOG/delta/SKILL.md"
pass "missing frontmatter, name or description restores ordinary selection without a call"

printf 'Perform gamma work.\n' > "$TASK"
assert_requirements() {
  local out=$1 format=$2 path=$3
  if [ "$format" = toon ]; then
    assert_contains "$out" "\"safety\",$path" "supplied requirement survives catalog failure"
    assert_contains "$out" "\"gamma\",\"$CATALOG/gamma/SKILL.md\"" "named requirement survives catalog failure"
    assert_contains "$out" 'suggestions[0]' "invalid catalog cannot give optional advice"
  else
    if [ "$path" = null ]; then
      assert_contains "$out" 'Required named skill: safety - path unresolved' "ambiguous requirement has no arbitrary path"
    else
      assert_contains "$out" "Required named skill: safety - read $CATALOG/safety/SKILL.md." "supplied requirement survives in brief"
    fi
    assert_contains "$out" "Required named skill: gamma - read $CATALOG/gamma/SKILL.md." "named requirement survives in brief"
    assert_not_contains "$out" 'read null' "brief never asks to read null"
  fi
}
BASE_CATALOG=$CATALOG
REAL_SHASUM=$(command -v shasum)
export REAL_SHASUM
for boundary in description body hash count duplicate; do
  reset
  CATALOG="$TMP_ROOT/catalog-$boundary"
  mkdir -p "$CATALOG"
  cp -R "$BASE_CATALOG/." "$CATALOG/"
  expected_path="\"$CATALOG/safety/SKILL.md\""
  case "$boundary" in
    description)
      printf '%s\n' '---' 'name: delta' 'description: [unsupported]' '---' '# Delta' > "$CATALOG/delta/SKILL.md"
      reason='unsupported skill metadata' ;;
    body)
      jq -nr '"x" * 524288' >> "$CATALOG/delta/SKILL.md"
      reason='skill body exceeds 512 KiB' ;;
    hash)
      cat > "$FAKEBIN/shasum" <<'SH'
#!/usr/bin/env bash
case "$*" in *'/delta/SKILL.md'*) exit 1 ;; esac
exec "$REAL_SHASUM" "$@"
SH
      chmod +x "$FAKEBIN/shasum"
      reason='catalog hash unavailable' ;;
    count)
      for ((i=1; i<=124; i++)); do
        mkdir -p "$CATALOG/extra-$i"
        printf '%s\n' '---' "name: extra-$i" 'description: Extra work.' '---' '# Extra' > "$CATALOG/extra-$i/SKILL.md"
      done
      reason='catalog exceeds 128 skills' ;;
    duplicate)
      mkdir -p "$CATALOG/duplicate"
      cp "$CATALOG/safety/SKILL.md" "$CATALOG/duplicate/SKILL.md"
      expected_path=null
      reason='duplicate skill IDs' ;;
  esac
  for format in toon brief; do
    out=$(run --task-file "$TASK" --required safety --format "$format" --no-cache)
    assert_contains "$out" "$reason" "$boundary returns the catalog fallback"
    assert_requirements "$out" "$format" "$expected_path"
    assert_absent "$LOG/calls" "$boundary prevents remote optional advice"
  done
  [ "$boundary" != hash ] || rm "$FAKEBIN/shasum"
done
CATALOG=$BASE_CATALOG
pass "catalog body, hash, count, metadata and duplicate failures retain local requirements"

reset
mkdir -p "$CATALOG/alias-directory"
printf '%s\n' '---' 'name: actual-identity' 'description: [unsupported]' '---' '# Skill' > "$CATALOG/alias-directory/SKILL.md"
printf 'Use actual-identity and alias-directory.\n' > "$TASK"
for format in toon brief; do
  out=$(run --task-file "$TASK" --required safety --format "$format" --no-cache)
  assert_contains "$out" actual-identity "frontmatter identity is recognized despite unsupported description"
  assert_not_contains "$out" '"alias-directory",' "directory name is not a required identity"
  assert_not_contains "$out" 'Required named skill: alias-directory' "brief does not treat directory as identity"
done
rm -rf "$CATALOG/alias-directory"
pass "named requirements use frontmatter identity instead of directory names"

reset
for missing_catalog in "$TMP_ROOT/absent-catalog" "$TMP_ROOT/empty-catalog"; do
  [ "$missing_catalog" != "$TMP_ROOT/empty-catalog" ] || mkdir -p "$missing_catalog"
  for format in toon brief; do
    out=$(run --catalog "$missing_catalog" --task-file "$TASK" --required safety --format "$format" --no-cache)
    assert_contains "$out" fallback "unavailable or empty catalog falls back"
    if [ "$format" = toon ]; then
      assert_contains "$out" '"safety",null' "unavailable identity path retains caller ID"
    else
      assert_contains "$out" 'Required named skill: safety - path unresolved' "unavailable identity path is explicit"
      assert_not_contains "$out" 'read null' "unavailable catalog never gives null read instruction"
    fi
    assert_absent "$LOG/calls" "unavailable catalog never calls judge"
  done
done
set +e
out=$(run --task-file "$TASK" --required unknown --no-cache)
code=$?
set -e
assert_equals '2' "$code" "valid complete catalog still rejects unknown required IDs"
assert_contains "$out" 'unknown required skill ID' "unknown requirement remains a usage error"
pass "unavailable catalogs preserve unresolved requirements without changing valid-catalog errors"

NOJQ_BIN="$TMP_ROOT/no-jq-bin"
mkdir -p "$NOJQ_BIN"
ln -s "$(command -v bash)" "$NOJQ_BIN/bash"
ln -s "$REAL_DIRNAME" "$NOJQ_BIN/dirname"
for format in toon brief; do
  out=$(PATH="$NOJQ_BIN" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=startup-secret bash "$TOOL" --task-file "$TASK" --required safety --required unknown --format "$format")
  assert_contains "$out" 'jq unavailable' "missing jq is advisory fallback"
  assert_contains "$out" 'Required named skill: safety - path unresolved' "missing jq preserves caller requirement"
  assert_contains "$out" 'Required named skill: unknown - path unresolved' "missing jq preserves unresolved caller ID"
  assert_contains "$out" 'Required triggers and agent judgment remain authoritative' "missing jq retains authority"
  if [ "$format" = brief ]; then
    assert_contains "$out" '# Skill selection advice' "missing jq respects brief format"
    assert_contains "$out" 'mandatory explicit/named and safety triggers first' "missing jq respects brief authority"
  fi
done
pass "missing jq reports supplied IDs and preserves requested brief authority"

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
