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
#   - a missing log reports every guard unmeasured and exits 0
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EVENT="$ROOT/bin/fm-guard-event.sh"
METRICS="$ROOT/bin/fm-guard-metrics.sh"
TMP=$(fm_test_tmproot fm-guard-telemetry)
trap 'fm_test_cleanup' EXIT
LOG="$TMP/events.jsonl"

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
jq '.guards[0].retirement_decision = "keep 2026-10-26: recorded by the test"' \
  "$TMP/undecided.json" > "$TMP/decided.json"
got=$("$METRICS" --log "$ZERO" --registry "$TMP/decided.json" --min-opportunities 30 --undecided)
[ -z "$got" ] || fail "a recorded decision must retire the nomination, got '$got'"
got=$("$METRICS" --log "$ZERO" --registry "$TMP/decided.json" --min-opportunities 30)
printf '%s\n' "$got" | grep -q '^METRIC gquiet .*verdict=cut' \
  || fail "--undecided must not change the measured verdict: $got"
pass "an undecided nomination is reported and a recorded decision retires it"

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

printf 'ok - fm-guard-telemetry\n'
