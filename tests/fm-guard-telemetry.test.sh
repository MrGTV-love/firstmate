#!/usr/bin/env bash
# Contract tests for the guard decision log: bin/fm-guard-event.sh writes it and
# bin/fm-guard-metrics.sh computes the retirement rule from it.
#
# docs/guard-spec.md's Stage 3 gate is "every instrumented guard emits one row
# per decision, and a parser test replays a sample of 20 rows". This suite
# covers the writer contract, the replay, and each retirement condition, so a
# future cut can cite a failing-or-passing measurement rather than an opinion.
#
# Proven here:
#   - the writer appends exactly one schema-complete row per call
#   - the writer cannot fail its caller, including with an unwritable log
#   - twenty replayed rows parse, and the counts match the fixture
#   - a reversible guard with thirty opportunities and no fire is cut
#   - an irreversible guard with no fire is kept (the documented exemption)
#   - an override rate above 20% cuts a reversible guard
#   - a median above three clear attempts cuts even an irreversible guard
#   - a recurrence after a clear cuts even an irreversible guard
#   - a dated decision stands until the evidence changes, not on its date alone
#   - a missing log reports every guard unmeasured and exits 0
#   - one guarded operation counts as one guard-level opportunity
#   - only an allow from the same actor class clears a deny
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENT="$ROOT/bin/fm-guard-event.sh"
METRICS="$ROOT/bin/fm-guard-metrics.sh"
TMP=$(fm_test_tmproot fm-guard-telemetry)
trap 'fm_test_cleanup' EXIT
LOG="$TMP/events.jsonl"
unset FM_TASK_ID
export FM_GUARD_EVENT_LOG="$LOG"

registry_with_harm() {  # <path> <id> <harm>
  cat >"$1" <<JSON
{"schema_version":1,"system":"firstmate","audited":1,"excluded":[],
 "guards":[{"id":"$2","owner":"bin/x.sh","invariant":"i","layer":"runtime-block",
   "source":"s","trigger":"t","decision":"deny","fail_direction":"closed",
   "remedy":"bin/x.sh --clear <id>","budget":1,"telemetry":"state/guard-events.jsonl",
   "test":"tests/x.test.sh","tier":"C","harm":"$3","exemptions":[]}]}
JSON
}

verdict_of() {  # <log> <registry> <id>
  "$METRICS" --log "$1" --registry "$2" --guards "$3" --min-opportunities 1 2>/dev/null \
    | sed -n "s/^METRIC $3 .*verdict=\([a-z]*\).*/\1/p"
}

test_claude_session_attribution() {
  local named="$TMP/claude" log="$TMP/claude-sessions.jsonl" session
  # Use the existing session-lock suite's real named-process fixture, not a
  # fake ancestry function. The native Claude classifier remains its owner.
  ln -sf /bin/bash "$named"
  for session in claude-one claude-two; do
    # shellcheck disable=SC2016 # The named process expands its own arguments.
    env -u FM_TASK_ID -u FM_SESSION_ID -u CLAUDE_SESSION_ID \
      -u CODEX_THREAD_ID -u PI_SESSION_ID -u OMP_SESSION_ID -u GROK_SESSION_ID \
      FM_HOME="$TMP" "$named" -c '
        export CLAUDE_CODE_SESSION_ID="$1" CLAUDE_PID=$$
        "$2" gclaude deny --task "" --log "$3"
        "$2" gclaude allow --task "" --log "$3"
        "$2" gclaude allow --task task-wins --log "$3"
        :
      ' _ "$session" "$EVENT" "$log" || fail "Claude process fixture failed"
  done
  jq -se --arg home "$TMP" '
    .[0].session == ($home + ":claude-one") and .[1].session == .[0].session
    and .[3].session == ($home + ":claude-two") and .[4].session == .[3].session
    and .[0].session != .[3].session and .[0].task == "" and .[3].task == ""
    and .[2].session == "task-wins" and .[5].session == "task-wins"' "$log" >/dev/null \
    || fail "two trusted Claude sessions must stay distinct and task identity must take precedence"
  env -u FM_TASK_ID -u FM_SESSION_ID -u CODEX_THREAD_ID -u PI_SESSION_ID \
    -u OMP_SESSION_ID -u GROK_SESSION_ID FM_HOME="$TMP" \
    CLAUDE_CODE_SESSION_ID=stale-session CLAUDE_PID=99999999 \
    "$EVENT" gstale allow --task '' --log "$log"
  jq -se --arg home "$TMP" '.[6].session == ($home + ":unattributed")' "$log" >/dev/null \
    || fail "an inherited Claude id without matching process ancestry must be ignored"
  pass "trusted Claude session IDs are stable, distinct, and never borrowed from unrelated ancestry"
}

fm_test_only

# --- writer schema ----------------------------------------------------------
"$EVENT" gschema deny --log "$LOG" --session s1 --elapsed-ms 14 --cleared-by retry --repeat 2 --override
lines=$(wc -l <"$LOG" | tr -d ' ')
[ "$lines" = 1 ] || fail "the writer must append exactly one row per call, got $lines"
row=$(cat "$LOG")
for field in ts guard version system session decision source_ok elapsed_ms cleared_by repeat override; do
  printf '%s' "$row" | jq -e --arg f "$field" 'has($f)' >/dev/null || fail "row is missing $field: $row"
done
[ "$(printf '%s' "$row" | jq -r .elapsed_ms)" = 14 ] || fail "elapsed_ms not recorded"
[ "$(printf '%s' "$row" | jq -r .cleared_by)" = retry ] || fail "cleared_by not recorded"
[ "$(printf '%s' "$row" | jq -r .repeat)" = 2 ] || fail "repeat not recorded"
[ "$(printf '%s' "$row" | jq -r .override)" = true ] || fail "override not recorded"
pass "the writer appends one schema-complete row per decision"

# --- writer never fails the caller -----------------------------------------
mkdir -p "$TMP/readonly"
chmod 500 "$TMP/readonly"
"$EVENT" gschema deny --log "$TMP/readonly/events.jsonl" 2>/dev/null
rc=$?
chmod 700 "$TMP/readonly"
[ "$rc" = 0 ] || fail "an unwritable log must not fail the caller, got exit $rc"
pass "an unwritable log does not fail the caller"

# --- replay twenty rows -----------------------------------------------------
REPLAY="$TMP/replay.jsonl"
: >"$REPLAY"
i=0
while [ $i -lt 20 ]; do
  if [ $((i % 5)) -eq 0 ]; then
    "$EVENT" greplay deny --log "$REPLAY" --session "s$i"
  else
    "$EVENT" greplay allow --log "$REPLAY" --session "s$i" --cleared-by retry
  fi
  i=$((i + 1))
done
[ "$(wc -l <"$REPLAY" | tr -d ' ')" = 20 ] || fail "replay fixture must hold 20 rows"
parsed=$(jq -s 'length' "$REPLAY") || fail "the replay fixture must parse as JSONL"
[ "$parsed" = 20 ] || fail "expected 20 parsed rows, got $parsed"
out=$("$METRICS" --log "$REPLAY" --registry "$ROOT/docs/guards/registry.json" --min-opportunities 20)
printf '%s\n' "$out" | grep -q '^METRIC greplay opportunities=20 denies=4 warns=0 ' \
  || fail "replay counts wrong: $out"
pass "twenty replayed rows parse and count correctly"

# --- zero fires -------------------------------------------------------------
ZERO="$TMP/zero.jsonl"
: >"$ZERO"
i=0
while [ $i -lt 30 ]; do "$EVENT" gquiet allow --log "$ZERO" --session "q$i"; i=$((i + 1)); done
registry_with_harm "$TMP/rev.json" gquiet reversible
[ "$(verdict_of "$ZERO" "$TMP/rev.json" gquiet)" = cut ] \
  || fail "a reversible guard with 30 opportunities and no fire must be cut"
pass "a reversible guard that never fires is cut"

registry_with_harm "$TMP/irr.json" gquiet irreversible
[ "$(verdict_of "$ZERO" "$TMP/irr.json" gquiet)" = keep ] \
  || fail "an irreversible guard with no fire must be kept"
pass "an irreversible guard that never fires is kept"

# --- undecided nominations --------------------------------------------------
# A cut nomination with no recorded decision is the one thing a session start
# must surface; recording the decision is what retires it.
registry_with_harm "$TMP/undecided.json" gquiet reversible
got=$("$METRICS" --log "$ZERO" --registry "$TMP/undecided.json" --min-opportunities 30 --undecided)
[ "$got" = gquiet ] || fail "an undecided cut nomination must be reported, got '$got'"
jq --arg d "keep $(date -u +%Y-%m-%d): recorded by the test" '.guards[0].retirement_decision = $d' \
  "$TMP/undecided.json" > "$TMP/decided.json"
got=$("$METRICS" --log "$ZERO" --registry "$TMP/decided.json" --min-opportunities 30 --undecided)
[ -z "$got" ] || fail "a recorded decision must retire the nomination, got '$got'"
got=$("$METRICS" --log "$ZERO" --registry "$TMP/decided.json" --min-opportunities 30)
printf '%s\n' "$got" | grep -q '^METRIC gquiet .*verdict=cut' \
  || fail "--undecided must not change the measured verdict: $got"
pass "an undecided nomination is reported and a recorded decision retires it"

# A decision judges the evidence through its date and stands until the evidence
# changes. Unchanged zero-fire evidence after it never re-nominates; a new deny,
# override, or a changed fire rate does, so a keep or redesign never hides it.
dated_rows() {  # <log> <day> <count> [decision] [override]
  local n=0
  while [ "$n" -lt "$3" ]; do
    printf '{"ts":"%sT12:00:%02dZ","guard":"gquiet","session":"w%s-%s-%s","decision":"%s","override":%s}\n' \
      "$2" "$((n % 60))" "$2" "${4:-allow}" "$n" "${4:-allow}" "${5:-false}" >>"$1"
    n=$((n + 1))
  done
}
decided_with() {  # <decision> <out>
  jq --arg d "$1" '.guards[0].retirement_decision = $d' "$TMP/undecided.json" > "$2"
}
undecided_for() {  # <log> <registry>
  "$METRICS" --log "$1" --registry "$2" --min-opportunities 30 --undecided
}
for outcome in keep redesign; do
  decided_with "$outcome 2026-02-01: judged the January window" "$TMP/dated-$outcome.json"
done

SAME="$TMP/same.jsonl"
: >"$SAME"
dated_rows "$SAME" 2026-01-10 30
dated_rows "$SAME" 2026-03-10 5
for outcome in keep redesign; do
  got=$(undecided_for "$SAME" "$TMP/dated-$outcome.json")
  [ -z "$got" ] || fail "a dated $outcome must retire a nomination while later events stay below the threshold, got '$got'"
done
dated_rows "$SAME" 2026-03-11 25
for outcome in keep redesign; do
  got=$(undecided_for "$SAME" "$TMP/dated-$outcome.json")
  [ -z "$got" ] || fail "unchanged zero-fire evidence after a dated $outcome must not re-nominate, got '$got'"
done

OVERRIDES="$TMP/new-overrides.jsonl"
: >"$OVERRIDES"
dated_rows "$OVERRIDES" 2026-01-10 30
dated_rows "$OVERRIDES" 2026-03-10 25
dated_rows "$OVERRIDES" 2026-03-11 5 deny true
for outcome in keep redesign; do
  got=$(undecided_for "$OVERRIDES" "$TMP/dated-$outcome.json")
  [ "$got" = gquiet ] || fail "a $outcome must not hide a cut nomination backed by new overrides, got '$got'"
done

RATE="$TMP/changed-rate.jsonl"
: >"$RATE"
for k in deny allow deny allow; do
  printf '{"ts":"2026-01-09T12:00:00Z","guard":"gquiet","session":"jan-recur","decision":"%s","override":false}\n' "$k" >>"$RATE"
done
dated_rows "$RATE" 2026-01-10 26
dated_rows "$RATE" 2026-03-10 30
got=$(undecided_for "$RATE" "$TMP/dated-keep.json")
[ "$got" = gquiet ] || fail "a fire rate that changed to zero after a keep is new evidence, got '$got'"

decided_with "keep 2026-03-20: process fixed, guard is a quiet backstop" "$TMP/rejudged.json"
dated_rows "$RATE" 2026-04-10 30
got=$(undecided_for "$RATE" "$TMP/rejudged.json")
[ -z "$got" ] || fail "a historical deny must not re-nominate a quiet window after a keep that judged a quiet window, got '$got'"
decided_with "keep 2026-04-20: still a quiet backstop" "$TMP/rejudged2.json"
dated_rows "$RATE" 2026-05-10 30
dated_rows "$RATE" 2026-06-10 30
for reg in rejudged rejudged2; do
  got=$(undecided_for "$RATE" "$TMP/$reg.json")
  [ -z "$got" ] || fail "unchanged quiet windows after $reg must not re-nominate, got '$got'"
done
dated_rows "$RATE" 2026-06-11 1 deny
got=$(undecided_for "$RATE" "$TMP/rejudged2.json")
[ "$got" = gquiet ] || fail "a new deny after a keep must re-nominate, got '$got'"
decided_with "keep 2026-06-11: judged the deny of that day" "$TMP/same-day.json"
got=$(undecided_for "$RATE" "$TMP/same-day.json")
[ -z "$got" ] || fail "a deny on the same date as a keep belongs to the judged window, got '$got'"
dated_rows "$RATE" 2026-06-12 1 deny
got=$(undecided_for "$RATE" "$TMP/same-day.json")
[ "$got" = gquiet ] || fail "a deny on a later date than a keep must re-nominate, got '$got'"

ERRWIN="$TMP/error-window.jsonl"
: >"$ERRWIN"
for k in deny allow deny allow; do
  printf '{"ts":"2026-01-09T12:00:00Z","guard":"gquiet","session":"jan-recur","decision":"%s","override":false}\n' "$k" >>"$ERRWIN"
done
dated_rows "$ERRWIN" 2026-01-10 29
dated_rows "$ERRWIN" 2026-01-10 1 error
dated_rows "$ERRWIN" 2026-03-10 30
got=$(undecided_for "$ERRWIN" "$TMP/dated-keep.json")
[ -z "$got" ] || fail "an error in the judged window is not a fire, so a quiet window after it must not re-nominate, got '$got'"

BYPASSWIN="$TMP/bypass-window.jsonl"
: >"$BYPASSWIN"
for k in deny allow deny allow; do
  printf '{"ts":"2026-01-09T12:00:00Z","guard":"gquiet","session":"jan-recur","decision":"%s","override":false}\n' "$k" >>"$BYPASSWIN"
done
dated_rows "$BYPASSWIN" 2026-01-10 26
dated_rows "$BYPASSWIN" 2026-01-11 30 bypass
dated_rows "$BYPASSWIN" 2026-03-10 30
got=$(undecided_for "$BYPASSWIN" "$TMP/dated-keep.json")
[ "$got" = gquiet ] || fail "a bypass is not an opportunity, so it must not push a fire out of the judged window, got '$got'"

decided_with "keep: no date recorded" "$TMP/undated.json"
got=$(undecided_for "$ZERO" "$TMP/undated.json")
[ "$got" = gquiet ] || fail "a decision without an outcome and date must not retire a nomination, got '$got'"
pass "a dated decision stands until the evidence changes and new evidence re-nominates"

# --- override rate ----------------------------------------------------------
OVER="$TMP/override.jsonl"
: >"$OVER"
i=0
while [ $i -lt 10 ]; do
  "$EVENT" gover deny --log "$OVER" --session "o$i"
  "$EVENT" gover allow --log "$OVER" --session "o$i" --cleared-by captain
  i=$((i + 1))
done
for k in 1 2 3; do "$EVENT" gover deny --log "$OVER" --session "ov$k" --override; done
registry_with_harm "$TMP/rev2.json" gover reversible
rate=$("$METRICS" --log "$OVER" --registry "$TMP/rev2.json" --min-opportunities 20 \
  | sed -n 's/^METRIC gover .*override_rate=\([0-9.]*\).*/\1/p')
awk -v r="$rate" 'BEGIN {exit !(r > 0.2)}' || fail "expected an override rate above 20%, got $rate"
[ "$(verdict_of "$OVER" "$TMP/rev2.json" gover)" = cut ] \
  || fail "an override rate above 20% must cut a reversible guard"
pass "an override rate above 20% cuts a reversible guard"

# --- median clear attempts --------------------------------------------------
SLOW="$TMP/slow.jsonl"
: >"$SLOW"
i=0
while [ $i -lt 6 ]; do
  k=0
  while [ $k -lt 4 ]; do "$EVENT" gslow deny --log "$SLOW" --session "d$i"; k=$((k + 1)); done
  "$EVENT" gslow allow --log "$SLOW" --session "d$i" --cleared-by retry
  i=$((i + 1))
done
registry_with_harm "$TMP/irr3.json" gslow irreversible
[ "$(verdict_of "$SLOW" "$TMP/irr3.json" gslow)" = cut ] \
  || fail "a median above three clear attempts must cut even an irreversible guard"
pass "a median above three clear attempts cuts even an irreversible guard"

# --- recurrence after a clear ----------------------------------------------
RECUR="$TMP/recur.jsonl"
: >"$RECUR"
"$EVENT" grecur deny --log "$RECUR" --session r1
"$EVENT" grecur allow --log "$RECUR" --session r1 --cleared-by retry
"$EVENT" grecur deny --log "$RECUR" --session r1
"$EVENT" grecur allow --log "$RECUR" --session r1 --cleared-by retry
registry_with_harm "$TMP/irr4.json" grecur irreversible
[ "$(verdict_of "$RECUR" "$TMP/irr4.json" grecur)" = cut ] \
  || fail "a recurrence after a clear must cut even an irreversible guard"
pass "a recurrence after a clear cuts even an irreversible guard"

# --- missing log ------------------------------------------------------------
absent=$("$METRICS" --log "$TMP/none.jsonl" 2>&1) || fail "a missing log must exit 0"
printf '%s\n' "$absent" | grep -q 'log_absent=true' || fail "a missing log must report itself: $absent"
pass "a missing log reports unmeasured and exits 0"
for mode in --undecided "--undecided --json"; do
  # shellcheck disable=SC2086
  got=$("$METRICS" --log "$TMP/none.jsonl" --registry "$TMP/undecided.json" $mode 2>&1) \
    || fail "$mode on a missing log must exit 0"
  [ -z "$got" ] || fail "$mode on a missing log must print nothing, got '$got'"
done
pass "--undecided on a missing log prints nothing"

test_claude_session_attribution

# Task identity survives a harness restart; unrelated homes cannot collide.
ATTR="$TMP/attributed.jsonl"
"$EVENT" merge-green-head deny --rule base-containment --task task-a --session before --log "$ATTR"
"$EVENT" merge-green-head allow --rule base-containment --task task-a --session after --log "$ATTR"
jq -se 'all(.[]; .task == "task-a" and .rule == "base-containment" and .session == "task-a")' "$ATTR" >/dev/null \
  || fail "task attribution must survive a session change"
FM_HOME="$TMP" FM_SESSION_ID=stable "$EVENT" ghome deny --log "$ATTR"
FM_HOME="$TMP" FM_SESSION_ID=stable "$EVENT" ghome allow --log "$ATTR"
FM_HOME="$TMP/other" FM_SESSION_ID=stable "$EVENT" ghome allow --log "$ATTR"
jq -se '.[2].session == .[3].session and .[3].session != .[4].session and .[2].task == ""' "$ATTR" >/dev/null \
  || fail "harness sessions must be stable and home-scoped"
"$EVENT" gcontrol deny --task $'task\nwith\tcontrols' --log "$ATTR"
jq -se '.[5].task == "task\nwith\tcontrols"' "$ATTR" >/dev/null || fail "JSON control characters were not escaped"
"$EVENT" malformed deny --rule >/dev/null || fail "missing option value failed its caller"
mkfifo "$TMP/events.fifo"
"$EVENT" fifo deny --log "$TMP/events.fifo" || fail "a nonregular log failed its caller"
pass "rule/task attribution, home-scoped sessions, and nonblocking malformed or FIFO logs"

# Different rules and tasks cannot clear each other's refusals. Extra denies
# for the same task remain measurable even when legacy sessions differ.
RULES="$TMP/rules.jsonl"
"$EVENT" grules deny --rule base --task task-a --session one --log "$RULES"
"$EVENT" grules allow --rule checks --task task-a --log "$RULES"
"$EVENT" grules allow --rule base --task task-b --log "$RULES"
"$EVENT" grules deny --rule base --task task-a --session two --log "$RULES"
"$EVENT" grules allow --rule base --task task-a --log "$RULES"
"$EVENT" grules deny --rule base --task task-a --session three --log "$RULES"
"$EVENT" grules bypass --rule base --task task-a --override --log "$RULES"
"$EVENT" grules allow --rule checks --task task-a --override --log "$RULES"
# The detector output may contain duplicate snapshots of the same signature.
printf '%s\n%s\n' \
  '{"guard":"grules","rule":"base","task":"task-a","head":"abc","kind":"tree-equal-merge"}' \
  '{"guard":"grules","rule":"base","task":"task-a","head":"abc","kind":"tree-equal-merge"}' > "$TMP/workarounds.jsonl"
# Historical callers may have recorded a new harness session for each row.
jq -sc 'to_entries[] | .value.session = ("harness-" + (.key | tostring)) | .value' "$RULES" > "$TMP/cross-session.jsonl"
"$METRICS" --log "$TMP/cross-session.jsonl" --workarounds "$TMP/workarounds.jsonl" --json > "$TMP/rules.json"
jq -e '.rules[] | select(.rule == "base") | .opportunities == 5 and .denies == 3 and .bypasses == 1
  and .workarounds == 1 and .refusal_to_bypass_ratio == 0.667 and .recurrences == 1
  and .median_clear_attempts == 2 and .repeat_denies == 2
  and .repeat_denies_per_task == [{task:"task-a",denies:3,repeat_denies:2}]' "$TMP/rules.json" >/dev/null \
  || fail "rule metrics lost task/rule isolation, deduplication, or ratio semantics"
jq -e '.rules[] | select(.rule == "checks") | .denies == 0 and .refusal_to_bypass_ratio == null
  and .recurrences == 0 and .repeat_denies == 0' "$TMP/rules.json" >/dev/null \
  || fail "zero-deny ratio must be undefined, not fabricated"
pass "per-rule metrics count cross-session task repeats and refusal-to-bypass ratios"

# A green merge writes three rule rows for one guarded operation. The guard row
# counts one opportunity; each rule row keeps its own allow and its own clear.
OPS="$TMP/operations.jsonl"
"$EVENT" gops deny --rule checks-green --task task-a --log "$OPS"
"$EVENT" gops allow --rule checks-green --task task-a --log "$OPS"
"$EVENT" gops allow --rule required-reported --no-opportunity --task task-a --log "$OPS"
"$EVENT" gops allow --rule base-containment --no-opportunity --task task-a --log "$OPS"
"$METRICS" --log "$OPS" --json > "$TMP/operations.json"
jq -e '.guards[] | select(.id == "gops") | .opportunities == 2 and .allows == 1 and .denies == 1
  and .median_clear_attempts == 1 and .recurrences == 0' "$TMP/operations.json" >/dev/null \
  || fail "one operation must be one guard-level opportunity, with its clear intact"
jq -e '[.rules[] | select(.id == "gops")] | length == 3 and all(.[]; .allows == 1)
  and (map(select(.rule == "checks-green"))[0].opportunities == 2)
  and (map(select(.rule == "required-reported"))[0].opportunities == 1)' "$TMP/operations.json" >/dev/null \
  || fail "each rule row must keep its own allow"
pass "one guarded operation counts once at guard level and once per rule"

# fixture homes pass the real check as marked labs, and that check records no bypass.
FIXTURE_LAB="$TMP/fixture-lab"
fm_test_lab_home "$FIXTURE_LAB" || fail "the shared lab fixture could not mark an empty directory"
if fm_test_lab_home "$FIXTURE_LAB" 2>/dev/null; then fail "the shared lab fixture marked a populated directory"; fi
(
  cd "$TMP" || exit 111
  for override in "${!FM_@}"; do
    case "$override" in *_OVERRIDE) unset "$override" ;; esac
  done
  # shellcheck disable=SC2030 # This subshell owns its own gate environment.
  export NO_MISTAKES_GATE=1 FM_HOME="$FIXTURE_LAB" FM_GUARD_EVENT_LOG="$TMP/fixture-lab.jsonl" FM_GATE_EVENT_TASK=lab-task
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$ROOT/bin/fm-gate-refuse-lib.sh"
  fm_refuse_if_gate_agent
) 2>/dev/null || fail "the real gate check refused a fixture lab home"
jq -se 'length == 1 and .[0].decision == "allow" and .[0].actor == "gate" and .[0].override == false' "$TMP/fixture-lab.jsonl" >/dev/null \
  || fail "a fixture lab home did not record one real gate allow: $(cat "$TMP/fixture-lab.jsonl")"
[ -z "${FM_GATE_REFUSE_BYPASS+x}" ] || fail "the shared test library left the gate bypass set"
pass "the shared lab fixture passes the real gate check with no bypass"

# A clearing allow comes from the deny's actor class, through the real gate check.
ACTOR_LAB=$("$ROOT/bin/fm-lab-home.sh" create "$TMP/actor-lab") || fail "could not create the actor lab home"
gate_check_as() {  # <log> <gate|main|lab>
  (
    cd "$TMP" || exit 111
    for override in "${!FM_@}"; do
      case "$override" in *_OVERRIDE) unset "$override" ;; esac
    done
    unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE FM_TASK_ID FM_HOME ID
    # shellcheck disable=SC2030,SC2031 # This subshell owns its own gate environment.
    export FM_GUARD_EVENT_LOG="$1" FM_GATE_EVENT_TASK=actor-task
    # shellcheck disable=SC2030,SC2031
    case "$2" in
      gate) export NO_MISTAKES_GATE=1 ;;
      lab) export NO_MISTAKES_GATE=1 FM_HOME="$ACTOR_LAB" ;;
    esac
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$ROOT/bin/fm-gate-refuse-lib.sh"
    fm_refuse_if_gate_agent
  ) >/dev/null 2>&1
}
recurrences_of() {  # <log> <guard>
  "$METRICS" --log "$1" --json | jq -e --arg guard "$2" '.guards[] | select(.id == $guard) | .recurrences'
}
CROSS="$TMP/cross-actor.jsonl"
rc=0; gate_check_as "$CROSS" gate || rc=$?
[ "$rc" = 3 ] || fail "a gate call must be refused, got exit $rc"
gate_check_as "$CROSS" main || fail "a call by Main must be allowed"
rc=0; gate_check_as "$CROSS" gate || rc=$?
[ "$rc" = 3 ] || fail "a repeated gate call must be refused, got exit $rc"
jq -se '[.[].decision] == ["deny","allow","deny"] and [.[].actor] == ["gate","main","gate"]
  and all(.[]; .task == "actor-task")' "$CROSS" >/dev/null || fail "gate decisions lost their actor class: $(cat "$CROSS")"
[ "$(recurrences_of "$CROSS" gate-agent-containment)" = 0 ] \
  || fail "an allow by Main must not clear a gate agent's deny"
SAME="$TMP/same-actor.jsonl"
rc=0; gate_check_as "$SAME" gate || rc=$?
[ "$rc" = 3 ] || fail "a gate call must be refused, got exit $rc"
gate_check_as "$SAME" lab || fail "a gate call against a marked lab home must be allowed"
rc=0; gate_check_as "$SAME" gate || rc=$?
[ "$rc" = 3 ] || fail "a repeated gate call must be refused, got exit $rc"
[ "$(recurrences_of "$SAME" gate-agent-containment)" = 1 ] \
  || fail "an allow by the same actor class must still clear a deny"
WORKER="$TMP/worker-actor.jsonl"
FM_TASK_ID=worker-task "$EVENT" gsend deny --rule explicit-home --task target --log "$WORKER"
"$EVENT" gsend allow --rule explicit-home --task target --log "$WORKER"
FM_TASK_ID=worker-task "$EVENT" gsend deny --rule explicit-home --task target --log "$WORKER"
[ "$(recurrences_of "$WORKER" gsend)" = 0 ] || fail "an allow by Main must not clear a worker's deny"
FM_TASK_ID=worker-task "$EVENT" gsend allow --rule explicit-home --task target --log "$WORKER"
FM_TASK_ID=worker-task "$EVENT" gsend deny --rule explicit-home --task target --log "$WORKER"
[ "$(recurrences_of "$WORKER" gsend)" = 1 ] || fail "an allow by the same worker class must still clear a deny"
pass "only an allow from the same actor class clears a deny"

# Exercise real library entrypoints. No credential contents enter the log.
EMITTERS="$TMP/emitters.jsonl"
(
  # shellcheck disable=SC2031 # Each subshell sets its own log.
  export FM_GUARD_EVENT_LOG="$EMITTERS" FM_TASK_ID=emitter-task
  # shellcheck source=bin/fm-api-key-guard-lib.sh
  . "$ROOT/bin/fm-api-key-guard-lib.sh"
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
  fm_api_key_guard claude 0 '' 0 '' '' || fail "clean billing environment was refused"
  fm_api_key_guard claude 1 '' 0 '' '' || fail "an unused billing option was refused"
  [ "$(jq -s '[.[] | select(.guard == "claude-api-billing" and .override == true)] | length' "$EMITTERS")" = 0 ] \
    || fail "an unused --allow-api-key recorded an escape"
  ANTHROPIC_API_KEY=fixture-not-a-credential fm_api_key_guard claude 1 '' 0 '' '' \
    || fail "existing explicit billing option was refused"
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$ROOT/bin/fm-gate-refuse-lib.sh"
  FM_GATE_REFUSE_BYPASS=1 fm_refuse_if_gate_agent
  # shellcheck source=bin/fm-compact-adviser-lib.sh
  . "$ROOT/bin/fm-compact-adviser-lib.sh"
  [ "$(FM_COMPACT_ADVISER_DISABLE=' True ' fm_compact_adviser_force_off)" = 1 ] || fail "compact disable result changed"
  fm_compact_adviser_bypass_event emitter-task
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  mkdir -p "$TMP/manual-config"
  printf 'manual\n' > "$TMP/manual-config/backlog-backend"
  fm_backlog_transition_applies "$TMP/manual-config" "$TMP" ship
  [ "$?" -eq 1 ] || fail "manual backlog admission result changed"
)
jq -se 'any(.[]; .guard == "claude-api-billing" and .decision == "allow" and .override == false)
  and any(.[]; .guard == "claude-api-billing" and .decision == "allow" and .override == true)
  and any(.[]; .rule == "FM_GATE_REFUSE_BYPASS" and .decision == "bypass" and .override == true)
  and any(.[]; .rule == "FM_COMPACT_ADVISER_DISABLE" and .decision == "bypass")
  and any(.[]; .guard == "backlog-transition" and .decision == "bypass")
  and all(.[]; .task == "emitter-task")' "$EMITTERS" >/dev/null || fail "existing allows and escapes were not attributed"
pass "real billing, containment, compact, and manual-backlog paths emit without changing their results"

# Real Git history, not a stub: a redundant base merge is distinguishable
# from an implementation commit after a refusal, and reads preserve all refs.
REPO="$TMP/workaround-repo"
STATE_DIR="$TMP/workaround-state"
mkdir -p "$REPO" "$STATE_DIR"
git init -q -b main "$REPO"
fm_git_identity fmtest fmtest@example.invalid
git -C "$REPO" commit -q --allow-empty -m seed
git -C "$REPO" checkout -qb feature
printf 'same content\n' > "$REPO/change.txt"
git -C "$REPO" add change.txt
git -C "$REPO" commit -qm feature
refused=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q main
printf 'same content\n' > "$REPO/change.txt"
git -C "$REPO" add change.txt
git -C "$REPO" commit -qm base
git -C "$REPO" checkout -q feature
"$EVENT" merge-green-head deny --task merge-task --rule base-containment --head "$refused" --base main --log "$STATE_DIR/guard-events.jsonl"
git -C "$REPO" merge -q --no-ff main -m 'merge base'
merged=$(git -C "$REPO" rev-parse HEAD)
printf 'kind=ship\nworktree=%s\nbranch=feature\n' "$REPO" > "$STATE_DIR/merge-task.meta"
before_refs=$(git -C "$REPO" show-ref)
before_status=$(git -C "$REPO" status --porcelain)
python3 "$ROOT/bin/fm-guard-workarounds.py" --state "$STATE_DIR" --log "$STATE_DIR/guard-events.jsonl" --json > "$TMP/signatures.jsonl" \
  || fail "read-only workaround scan failed"
jq -se --arg head "$merged" 'length == 2 and all(.[]; .head == $head and .task == "merge-task")
  and any(.[]; .kind == "tree-equal-merge") and any(.[]; .kind == "base-merge-only-after-refusal")' "$TMP/signatures.jsonl" >/dev/null \
  || fail "redundant base merge did not produce both signatures"
[ "$(git -C "$REPO" show-ref)" = "$before_refs" ] && [ "$(git -C "$REPO" status --porcelain)" = "$before_status" ] \
  || fail "workaround detection changed repository state"
printf 'real work\n' > "$REPO/work.txt"
git -C "$REPO" add work.txt
git -C "$REPO" commit -qm implementation
python3 "$ROOT/bin/fm-guard-workarounds.py" --state "$STATE_DIR" --log "$STATE_DIR/guard-events.jsonl" --json > "$TMP/real-work.jsonl"
jq -se 'all(.[]; .kind != "base-merge-only-after-refusal")' "$TMP/real-work.jsonl" >/dev/null \
  || fail "an implementation change was misreported as only a base merge"
# Another task's refusal is not evidence for this branch.
jq -c '.task = "other-task"' "$STATE_DIR/guard-events.jsonl" > "$TMP/other-task.jsonl"
python3 "$ROOT/bin/fm-guard-workarounds.py" --repo "$REPO" --head "$merged" --task merge-task --log "$TMP/other-task.jsonl" --json > "$TMP/other-task-result.jsonl"
jq -se 'length == 1 and .[0].kind == "tree-equal-merge"' "$TMP/other-task-result.jsonl" >/dev/null \
  || fail "a refusal from another task was correlated with this head"
git -C "$REPO" branch -f main "$merged"
python3 "$ROOT/bin/fm-guard-workarounds.py" --state "$STATE_DIR" --log "$STATE_DIR/guard-events.jsonl" --json > "$TMP/inherited-result.jsonl"
jq -se 'length == 0' "$TMP/inherited-result.jsonl" >/dev/null || fail "base history was misreported as a task workaround"
# A pooled copy may hold the base only as a fetched ref, and a local branch may
# be stale. The origin ref wins for the exclusion and for the correlation.
git -C "$REPO" branch -f main "$refused"
git -C "$REPO" update-ref refs/remotes/origin/main "$merged"
python3 "$ROOT/bin/fm-guard-workarounds.py" --state "$STATE_DIR" --log "$STATE_DIR/guard-events.jsonl" --json > "$TMP/origin-first.jsonl"
jq -se 'length == 0' "$TMP/origin-first.jsonl" >/dev/null || fail "a stale local base hid the fetched origin base"
git -C "$REPO" update-ref refs/remotes/origin/release-1 "$merged"
git -C "$REPO" update-ref -d refs/remotes/origin/main
printf 'kind=ship\nworktree=%s\nbranch=feature\nbase_branch=release-1\n' "$REPO" > "$STATE_DIR/merge-task.meta"
python3 "$ROOT/bin/fm-guard-workarounds.py" --state "$STATE_DIR" --log "$STATE_DIR/guard-events.jsonl" --json > "$TMP/origin-only.jsonl"
jq -se 'length == 0' "$TMP/origin-only.jsonl" >/dev/null || fail "a base held only as an origin ref did not exclude its history"
git -C "$REPO" update-ref refs/remotes/origin/main "$(git -C "$REPO" rev-parse "$merged^2")"
python3 "$ROOT/bin/fm-guard-workarounds.py" --repo "$REPO" --head "$merged" --task merge-task --log "$STATE_DIR/guard-events.jsonl" --json > "$TMP/stale-local-correlation.jsonl"
jq -se 'any(.[]; .kind == "base-merge-only-after-refusal")' "$TMP/stale-local-correlation.jsonl" >/dev/null \
  || fail "a stale local base hid a real base-merge-only change"
pass "real tree-equal/base-only merges are detected read-only without blaming actual implementation or inherited base history"

printf 'ok - fm-guard-telemetry\n'
