#!/usr/bin/env bash
# Claude final-text form backstop. No live Claude run is claimed.
# Native shape: docs/verification/supervision.md live-e2e table,
# bin/fm-host-mirror.sh hook extractor and tests/fm-host-mirror.test.sh.
# Local live-healthy-watcher proof is OMITTED under the task's host-process gate.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-turnend-ask)
GUARD=${FM_TURNEND_ASK_GUARD:-$ROOT/bin/fm-turnend-guard.sh}
CLAUDE_STOP=$(jq -r '.hooks.Stop[].hooks[] | select(.command | contains("fm-turnend-guard.sh")) | .command' "$ROOT/.claude/settings.json")
unset GROK_AGENT GROK_HOOK_EVENT

ask_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/bin" "$home/state" "$home/config"
  : > "$home/AGENTS.md"
  if [ "${2:-secondmate}" = plain ]; then
    git init -q "$home"
  else
    printf 'ask-fixture\n' > "$home/.fm-secondmate-home"
  fi
  printf '%s\n' "$home"
}

stop_payload() { # <text> [true|false]
  jq -cn --arg text "$1" --argjson active "${2:-false}" --arg cwd "$TMP_ROOT" \
    '{hook_event_name:"Stop",session_id:"ask-fixture",transcript_path:($cwd+"/transcript.jsonl"),cwd:$cwd,stop_hook_active:$active,last_assistant_message:$text}'
}

run_stop() { # <fixture home> <raw payload> [registered|default|cursor] [scope root]
  local home=$1 payload=$2 mode=${3:-registered} scope=${4:-$1}
  local -a invocation
  case "$mode" in
    registered) invocation=(bash -c "$CLAUDE_STOP") ;;
    default) invocation=(bash "$GUARD") ;;
    cursor) invocation=(bash "$GUARD" --cursor) ;;
    *) fail "unknown fixture mode $mode" ;;
  esac
  # The existing branch-primary pin avoids a real ancestry probe when the
  # paired control renders its repair line; it changes no guard predicate.
  printf '%s' "$payload" | FM_ROOT_OVERRIDE="$scope" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_GUARD_EVENT_LOG="$home/state/guard-events.jsonl" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS="${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-0}" \
    FM_SUPERVISION_ACTOR=branch FM_SUPERVISION_PRIMARY_HARNESS=claude \
    CLAUDE_PROJECT_DIR="$(dirname "$(dirname "$GUARD")")" "${invocation[@]}" 2>&1
}

expect_unchecked() {
  local home=$1
  [ -s "$home/state/guard-events.jsonl" ] || fail 'skipped text must leave a guard-event record'
  jq -se '[.[] | select(.guard == "turnend-ask-gate")] as $events
    | ($events | length) == 1 and $events[0].rule == "ask-gate-unchecked"
      and $events[0].decision == "warn"
      and all($events[]; .decision != "allow")' "$home/state/guard-events.jsonl" >/dev/null \
    || fail 'a skipped turn must record exactly one unchecked warn, never an allow'
}

expect_no_chat_event() {
  local home=$1
  [ -e "$home/state/guard-events.jsonl" ] || return 0
  jq -se 'all(.[]; .guard != "turnend-ask-gate")' "$home/state/guard-events.jsonl" >/dev/null \
    || fail 'examined text with no failing form must not emit a chat-check result'
}

check_refusal() { # <actual output> <failing line>
  assert_contains "$1" "$2" 'the first failing line must retain its verbatim text'
  assert_contains "$1" 'if no:' 'the rule must name its required action marker'
  assert_contains "$1" 'already published' 'the corrective timing must be explicit'
  assert_contains "$1" 'does not prevent publication' 'do not promise prevention'
  local boundary
  for boundary in credential spend destructive irreversible tool-denial owner-rule-change; do
    assert_contains "$1" "$boundary" 'the rule must name every accepted boundary'
  done
}

test_supervision_control_and_idle_ask() {
  local home line out status
  home=$(ask_home paired-control)
  : > "$home/state/task1.meta"
  out=$(run_stop "$home" "$(stop_payload 'Continuing routine work.' true)"); status=$?
  expect_code 2 "$status" 'paired existing supervision control must block even with the loop flag true'
  assert_contains "$out" 'TURN WOULD END BLIND' 'control must exercise the real supervision block'
  printf 'Paired control: real supervision block observed with stop_hook_active true.\n'
  rm "$home/state/task1.meta"
  line='needs input: May I use the repository git user.name?'
  out=$(run_stop "$home" "$(stop_payload "$line")"); status=$?
  expect_code 2 "$status" 'the same in-scope home must block an idle rubber-stamp ask'
  check_refusal "$out" "$line"
  pass 'real supervision control blocks on base/head; idle rubber-stamp ask requires new enforcement'
}

test_plain_primary_idle_ask_blocks() {
  local home line out status
  home=$(ask_home plain-primary plain)
  line='needs input: A routine question in the main primary?'
  out=$(run_stop "$home" "$(stop_payload "$line")"); status=$?
  expect_code 2 "$status" 'a plain primary with no in-flight work must check the ask'
  check_refusal "$out" "$line"
  pass 'plain primary and marked secondmate primary both check idle asks'
}

test_live_healthy_watcher_ask_blocks() {
  # Named local-only skip; CI and the unconfined pipeline do not set it.
  if [ "${FM_ASK_LOCAL_OMIT_LIVE_WATCHER:-0}" = 1 ]; then
    printf 'OMITTED: test_live_healthy_watcher_ask_blocks; no-host-process local gate, live proof owed to pipeline/CI\n'
    return 0
  fi
  local home pid identity out control_status ask_status
  home=$(ask_home live-watcher)
  : > "$home/state/task1.meta"
  # Use the autoarm suite's parent-bound holder style, not a wall-clock lease
  # that could expire while an unconfined validation host is busy.
  perl -e 'sleep 1 while getppid() == $ARGV[0]' "$$" &
  pid=$!
  identity=$(fm_test_pid_identity "$pid") || {
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail 'could not identify the live watcher-lock holder'
  }
  mkdir "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s/fm-watch.sh\n' "$(dirname "$GUARD")" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
  out=$(run_stop "$home" "$(stop_payload 'Ordinary checked text.')"); control_status=$?
  out=$(run_stop "$home" "$(stop_payload 'needs input: A routine question despite live supervision?')"); ask_status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$control_status" 'the paired control must prove the live watcher is healthy'
  expect_code 2 "$ask_status" 'a healthy watcher must not bypass the ask check'
  check_refusal "$out" 'needs input: A routine question despite live supervision?'
  pass 'a real live watcher-lock holder satisfies supervision but does not bypass the ask check'
}

test_inflight_ask_does_not_touch_supervision_budget() {
  local home line out status budget fake before
  home=$(ask_home inflight)
  fake=$(fm_fakebin "$home/no-wait-bin")
  printf '#!/usr/bin/env bash\nprintf entered > %q\nexit 97\n' "$home/autoarm-wait-entered" > "$fake/sleep"
  chmod +x "$fake/sleep"
  : > "$home/state/task1.meta"
  budget=$'session=preserved\ncount=2\nepoch=4'
  printf '%s\n' "$budget" > "$home/state/.turnend-claude-blocks"
  before=$(cksum < "$home/state/.turnend-claude-blocks")
  line='needs input: Should I use the configured name?'
  out=$(PATH="$fake:$PATH" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 run_stop "$home" "$(stop_payload "$line")"); status=$?
  expect_code 2 "$status" 'in-flight rubber-stamp ask must block'
  [ ! -e "$home/autoarm-wait-entered" ] || fail 'the ask block entered the auto-arm wait'
  check_refusal "$out" "$line"
  [ "$(cksum < "$home/state/.turnend-claude-blocks")" = "$before" ] || fail 'the ask check changed the supervision budget bytes'
  assert_not_contains "$out" 'TURN WOULD END BLIND' 'ask handling must precede supervision recovery'
  pass 'in-flight ask blocks before supervision without charging its budget'
}

test_child_scope_is_not_checked() {
  local home child parent git_dir common out status
  home=$(ask_home child-scope)
  git_dir=$(git -C "$ROOT" rev-parse --git-dir)
  common=$(git -C "$ROOT" rev-parse --git-common-dir)
  if [ "$git_dir" != "$common" ] && [ ! -e "$ROOT/.fm-secondmate-home" ]; then
    child=$ROOT # Reuse the launched disposable child; never administer its pool.
  else
    # Portable CI uses only a new empty fixture repository, not the task pool.
    parent="$TMP_ROOT/fixture-parent"
    mkdir -p "$parent"
    git init -q "$parent"
    git -C "$parent" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q --allow-empty -m fixture
    child="$TMP_ROOT/fixture-child"
    fm_git_worktree "$parent" "$child" fm/ask-fixture
    mkdir -p "$child/bin"
    : > "$child/AGENTS.md"
  fi
  out=$(run_stop "$home" "$(stop_payload 'needs input: A worker question?')" registered "$child"); status=$?
  expect_code 0 "$status" 'a genuine linked child checkout must stay outside primary scope'
  [ -z "$out" ] || fail 'child scope produced a correction'
  expect_no_chat_event "$home"
  pass 'a genuine linked child checkout remains unchecked by the primary guard'
}

test_six_boundary_actions_pass() {
  local home boundary out status
  home=$(ask_home six-boundaries)
  for boundary in credential spend destructive irreversible tool-denial owner-rule-change; do
    out=$(run_stop "$home" "$(stop_payload "needs input: $boundary; if no: retain resource 1")"); status=$?
    expect_code 0 "$status" "$boundary with an action must not block"
    [ -z "$out" ] || fail "a form-compliant $boundary line produced a correction"
  done
  expect_no_chat_event "$home"
  pass 'each single boundary and action satisfies the mechanical form, not ownership judgment'
}

test_boundary_token_normalization() {
  local home boundary out status
  home=$(ask_home tokens)
  for boundary in Credential SPEND Destructive IRREVERSIBLE Tool_Denial 'tool   denial' TOOL-DENIAL 'owner rule change' OWNER_RULE_CHANGE non-destructive spend-cap 'spend spend'; do
    out=$(run_stop "$home" "$(stop_payload "NeEdS InPuT: [${boundary}]; IF NO: retain resource 1")"); status=$?
    expect_code 0 "$status" "normalized whole token must not block: $boundary"
    [ -z "$out" ] || fail 'case/separator/punctuation formatting produced a false block'
  done
  expect_no_chat_event "$home"
  pass 'case, punctuation and compound-name separators normalize without asserting authority'
}

test_invalid_form_variants_block() {
  local home line out status n=0
  for line in 'needs input: routine; if no: wait' 'needs input: spend' \
    'needs input: spend; if no:   ' 'needs input: spend; if no: !!!' \
    'needs input: spending; if no: wait' 'needs input: nondestructive; if no: wait' \
    'needs input: credentials; if no: wait' 'needs input: spend destructive; if no: wait' \
    'needs input: spend; if-no: retain 1' 'needs input: spend; if no - retain 1' \
    'needs input: a decision; if no: spend' 'needs input: spend; if no: !!! if no: retain 1'; do
    n=$((n+1)); home=$(ask_home "invalid-$n")
    out=$(run_stop "$home" "$(stop_payload "$line")"); status=$?
    # The first if-no marker owns all remaining text. A second marker contains
    # letters and therefore satisfies the explicitly mechanical action rule.
    case "$line" in
      *'!!! if no:'*) expect_code 0 "$status" 'all text after the first marker is the action' ;;
      *) expect_code 2 "$status" "invalid form must block: $line"; check_refusal "$out" "$line" ;;
    esac
  done
  pass 'whole-token, single-boundary and alphanumeric-action rules are enforced on the physical line'
}

test_list_emphasis_and_prefixes_are_checked() {
  local home line out status n=0
  for line in '- needs input: Use the configured name?' '**Needs input**: Use the configured name?' \
    '**needs input:** Use the configured name?' '1. needs input: A numbered question?' \
    '1.needs input: No-space list marker?' '    needs input: A four-space question?' \
    $'\tneeds input: A tab-indented question?' \
    'NEEDS-INPUT Use the configured name?' '  + __needs input:__ Use the configured name?' \
    $'\t12. **needs input:** Use the configured name?' '* needs input: Use the configured name?'; do
    n=$((n+1)); home=$(ask_home "prefix-$n")
    out=$(run_stop "$home" "$(stop_payload "$line")"); status=$?
    expect_code 2 "$status" 'required list/emphasis/prefix spelling must be checked'
    check_refusal "$out" "$line"
  done
  pass 'required indentation, list markers, emphasis and prefix spellings cannot bypass the form check'
}

test_first_failing_physical_line_is_named() {
  local home first second text out status
  home=$(ask_home first-failure)
  first='needs input: first failing question?'
  second='needs input: second failing question?'
  text=$(printf 'needs input: spend; if no: retain 1\n%s\n%s' "$first" "$second")
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 2 "$status" 'any failing checked line must block'
  check_refusal "$out" "$first"
  assert_not_contains "$out" "$second" 'the reason must name only the first failing line'
  pass 'the first failing line is named after an earlier form-compliant line'
}

test_next_line_cannot_complete_an_ask() {
  local home text out status
  home=$(ask_home physical-lines)
  text=$'needs input: a question?\nspend; if no: retain 1'
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 2 "$status" 'a boundary and action on the next line do not complete the ask'
  check_refusal "$out" 'needs input: a question?'
  pass 'boundary and action facts must be on the checked physical line'
}

test_lexically_correct_empty_ask_is_not_authority() {
  local home out status
  home=$(ask_home lexical-limit)
  out=$(run_stop "$home" "$(stop_payload 'needs input: spend; if no: x')"); status=$?
  expect_code 0 "$status" 'the necessary form check must not invent a semantic ownership classifier'
  expect_no_chat_event "$home"
  pass 'a lexically correct but substantively empty ask is not blocked or recorded as approval'
}

test_no_ask_records_no_result() {
  local home out status
  home=$(ask_home no-ask)
  out=$(run_stop "$home" "$(stop_payload 'Proceeding with the repository identity.')"); status=$?
  expect_code 0 "$status" 'ordinary text must not block'
  [ -z "$out" ] || fail 'ordinary text produced a correction'
  expect_no_chat_event "$home"
  pass 'examined ordinary text emits no pass, approval or chat result'
}

test_missing_and_wrong_type_text_warn_once() {
  local home payload value out status n=0
  for value in missing null 7 '{}' '""' '"   "'; do
    n=$((n+1)); home=$(ask_home "unchecked-$n")
    payload=$(stop_payload '')
    if [ "$value" = missing ]; then payload=$(printf '%s' "$payload" | jq 'del(.last_assistant_message)')
    else payload=$(printf '%s' "$payload" | jq --argjson value "$value" '.last_assistant_message=$value'); fi
    out=$(run_stop "$home" "$payload"); status=$?
    expect_code 0 "$status" 'missing/empty/non-string text must not block'
    expect_unchecked "$home"
  done
  pass 'missing, null, number, object and empty text each produce one unchecked warn, never allow'
}

test_invalid_payload_stays_silent() {
  local home payload out status n=0
  for payload in '{broken JSON' '' 'null' '{"stop_hook_active":"true","last_assistant_message":"needs input: A routine question?"}'; do
    n=$((n+1)); home=$(ask_home "bad-json-$n")
    out=$(run_stop "$home" "$payload"); status=$?
    expect_code 0 "$status" 'invalid payload keeps the base fail-open behavior'
    [ -z "$out" ] || fail 'invalid payload must remain silent'
    expect_no_chat_event "$home"
  done
  pass 'malformed or absent payload remains silent, without an unchecked event'
}

test_continuation_warns_without_reblocking() {
  local home out status
  home=$(ask_home continuation)
  out=$(run_stop "$home" "$(stop_payload 'needs input: A routine question?' true)"); status=$?
  expect_code 0 "$status" 'a hook continuation must not reblock for this check'
  expect_unchecked "$home"
  home=$(ask_home continuation-missing)
  out=$(run_stop "$home" "$(stop_payload '' true | jq 'del(.last_assistant_message)')"); status=$?
  expect_code 0 "$status" 'a loop flag with missing text must not block'
  expect_unchecked "$home"
  home=$(ask_home continuation-clean)
  out=$(run_stop "$home" "$(stop_payload 'Ordinary text with no ask.' true)"); status=$?
  expect_code 0 "$status" 'clean text on an active hook is still an unchecked turn'
  expect_unchecked "$home"
  pass 'rubber-stamp, missing-text and clean-text continuation skips each record one unchecked warn'
}

test_fences_and_quotes_warn_once() {
  local home text out status
  home=$(ask_home quoted)
  text=$'```text\nneeds input: code example?\n```\n~~~\nNEEDS-INPUT: tilde example?\n~~~\n> needs input: quoted example?\n  > needs input: indented quote?\n> ```\n> needs input: a fence inside a quote?\n> ```'
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 0 "$status" 'quoted examples must not block'
  expect_unchecked "$home"
  text=$(printf '%s\nneeds input: Actual question outside every quote and fence?' "$text")
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 2 "$status" 'an actual ask outside examples must always be checked'
  check_refusal "$out" 'needs input: Actual question outside every quote and fence?'
  pass 'fences and quotes mark unchecked once but do not conceal an outside ask'
}

test_skip_and_checked_line_event_precedence() {
  local home text out status
  home=$(ask_home passing-plus-skipped)
  text=$'needs input: spend; if no: retain 1\n```\nneeds input: quoted example?\n```'
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 0 "$status" 'a checked form-compliant line plus an example must not block'
  expect_unchecked "$home"
  home=$(ask_home failing-plus-skipped)
  text=$'needs input: actual routine question?\n```\nneeds input: quoted example?\n```'
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 2 "$status" 'a skipped example cannot conceal a failing checked line'
  check_refusal "$out" 'needs input: actual routine question?'
  jq -se '[.[] | select(.guard == "turnend-ask-gate")] as $events
    | ($events | length) == 1 and $events[0].decision == "deny"
      and $events[0].rule == "ask-gate-rubber-stamp"' "$home/state/guard-events.jsonl" >/dev/null \
    || fail 'a failing line plus skipped text must record only one deny, no unchecked warn'
  pass 'skipped plus compliant text records unchecked; skipped plus failing text records only deny'
}

test_quoted_fence_opens_nothing() {
  local home text out status
  home=$(ask_home quoted-fence)
  text=$'> ```\nneeds input: A real question after a quoted fence marker?'
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 2 "$status" 'a fence marker inside a quote must not open a fence'
  check_refusal "$out" 'needs input: A real question after a quoted fence marker?'
  pass 'a quoted fence marker cannot hide a subsequent real ask'
}

test_unclosed_fence_is_unchecked_to_end() {
  local home text out status
  home=$(ask_home unclosed)
  text=$'````example\nneeds input: example to end of text?\n```\nneeds input: still inside the longer unclosed fence?'
  out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
  expect_code 0 "$status" 'an unclosed fence runs to end of text'
  expect_unchecked "$home"
  pass 'an unclosed fence marks skipped asks unchecked through the end'
}

test_if_no_marker_spacing() {
  local home marker out status n=0
  for marker in 'IF NO:' 'if  no:' 'if no :'; do
    n=$((n+1)); home=$(ask_home "marker-spacing-$n")
    out=$(run_stop "$home" "$(stop_payload "needs input: spend; $marker retain 1")"); status=$?
    expect_code 0 "$status" 'the specified spaces/case variants of if no: must not block'
    expect_no_chat_event "$home"
  done
  pass 'if-no marker case and specified whitespace variants satisfy the form'
}

test_first_of_two_failing_lines() {
  local home out status
  home=$(ask_home two-failures)
  out=$(run_stop "$home" "$(stop_payload $'needs input: credential\nneeds input: spending if no: x')"); status=$?
  expect_code 2 "$status" 'two failing lines must block'
  check_refusal "$out" 'needs input: credential'
  assert_not_contains "$out" 'needs input: spending if no: x' 'only the FIRST failing line is reported'
  pass 'the first of two failing physical lines is reported'
}

test_fence_delimiter_boundaries() {
  local home text out status n=0
  for text in $'    ```\nneeds input: four-space opener is not a fence?' \
    $'\t```\nneeds input: tab opener is not a fence?' \
    $'   ```\nneeds input: example?\n   ````\nneeds input: actual ask after longer close?'; do
    n=$((n+1)); home=$(ask_home "not-hidden-$n")
    out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
    expect_code 2 "$status" 'invalid opener or a valid longer closer must leave an outside ask checked'
  done
  for text in $'````\n```\nneeds input: shorter closer leaves this fenced?' \
    $'```\n~~~\nneeds input: different marker leaves this fenced?' \
    $'```\n> ```\n> needs input: inside the original fence?\nneeds input: still inside the original fence?'; do
    n=$((n+1)); home=$(ask_home "still-fenced-$n")
    out=$(run_stop "$home" "$(stop_payload "$text")"); status=$?
    expect_code 0 "$status" 'shorter, different-marker and quoted lines must not close the fence'
    expect_unchecked "$home"
  done
  pass 'fence indentation, marker, length and quoted-content boundaries are honored'
}

test_line_cut_is_first_200_bytes() {
  local home line prefix out status
  home=$(ask_home long-line)
  line=$(printf 'needs input: '; printf 'x%.0s' {1..287})
  [ "$(printf '%s' "$line" | jq -Rs length)" = 300 ] || fail 'long-line fixture must contain 300 characters'
  prefix=$(printf '%s' "$line" | jq -Rs '.[0:200]' -r)
  out=$(run_stop "$home" "$(stop_payload "$line")"); status=$?
  expect_code 2 "$status" 'a long unqualified ask must block'
  check_refusal "$out" "$prefix"
  assert_not_contains "$out" "${prefix}x" 'the failing line must be cut at 200 bytes'
  pass 'the reason preserves the first 200 of 300 ASCII bytes verbatim'
}

test_default_cursor_and_foreign_paths_unchanged() {
  local home mode payload out status
  for mode in default cursor; do
    home=$(ask_home "$mode")
    payload=$(stop_payload 'needs input: A routine question?')
    out=$(run_stop "$home" "$payload" "$mode"); status=$?
    expect_code 0 "$status" "$mode must retain the base idle behavior"
    [ -z "$out" ] || fail "$mode emitted a chat correction"
    expect_no_chat_event "$home"
  done
  home=$(ask_home foreign)
  payload=$(stop_payload 'needs input: A routine question?' | jq '.cursor_version="fixture"')
  out=$(run_stop "$home" "$payload"); status=$?
  expect_code 0 "$status" 'foreign compatibility delivery stays excluded'
  expect_no_chat_event "$home"
  pass 'default, --cursor and foreign compatibility deliveries remain outside this check'
}

fm_test_run_cases \
  test_supervision_control_and_idle_ask test_plain_primary_idle_ask_blocks \
  test_live_healthy_watcher_ask_blocks test_inflight_ask_does_not_touch_supervision_budget \
  test_child_scope_is_not_checked test_six_boundary_actions_pass test_boundary_token_normalization \
  test_invalid_form_variants_block test_list_emphasis_and_prefixes_are_checked \
  test_first_failing_physical_line_is_named test_next_line_cannot_complete_an_ask \
  test_lexically_correct_empty_ask_is_not_authority test_no_ask_records_no_result \
  test_missing_and_wrong_type_text_warn_once \
  test_invalid_payload_stays_silent test_continuation_warns_without_reblocking \
  test_fences_and_quotes_warn_once test_skip_and_checked_line_event_precedence \
  test_quoted_fence_opens_nothing test_unclosed_fence_is_unchecked_to_end \
  test_if_no_marker_spacing test_first_of_two_failing_lines test_fence_delimiter_boundaries \
  test_line_cut_is_first_200_bytes test_default_cursor_and_foreign_paths_unchanged -- "$@"
