#!/usr/bin/env bash
# Live driver: real writer + real readers (new = run worktree, old = base 7f3a198b copy).
# All logs and registries live in this disposable temp dir.
set -u
LIVE=/tmp/fm-guard-live.vTE8te
WT=<WORKTREE>
EVENT="$WT/bin/fm-guard-event.sh"
NEW="$WT/bin/fm-guard-metrics.sh"
OLD="$LIVE/old/bin/fm-guard-metrics.sh"
cd "$LIVE" || exit 1
mkdir -p "$LIVE/cases"

reg() {  # <path> <id> <harm> [decision]
  if [ -n "${4:-}" ]; then
    printf '{"schema_version":1,"guards":[{"id":"%s","harm":"%s","retirement_decision":"%s"}]}\n' "$2" "$3" "$4" >"$1"
  else
    printf '{"schema_version":1,"guards":[{"id":"%s","harm":"%s"}]}\n' "$2" "$3" >"$1"
  fi
}

row() {  # <label> <reader> <log> <registry> [guard-filter]
  local out und
  out=$("$2" --log "$3" --registry "$4" --json 2>&1) || out="READER_EXIT_NONZERO $out"
  und=$("$2" --log "$3" --registry "$4" --undecided 2>&1) || und="UNDECIDED_EXIT_NONZERO"
  printf '  %-4s guards: %s\n' "$1" "$(printf '%s' "$out" | jq -c '[.guards[] | {id, opportunities, denies, warns, verdict, recurrences}]' 2>/dev/null || printf '%s' "$out")"
  printf '  %-4s undecided-nominations: [%s]\n' "$1" "$(printf '%s' "$und" | tr '\n' ' ' | sed 's/ *$//')"
  printf '  %-4s summary: %s\n' "$1" "$(printf '%s' "$out" | jq -c '.summary' 2>/dev/null)"
}

both() {  # <case-title> <log> <registry>
  echo "== $1"
  row old "$OLD" "$2" "$3"
  row new "$NEW" "$2" "$3"
}

# ---------- registries ----------
reg "$LIVE/rev.json" gquiet reversible
reg "$LIVE/irr.json" gquiet irreversible
reg "$LIVE/push.json" git-push-credential-shapes irreversible
reg "$LIVE/rev-keep.json" gquiet reversible "keep 2026-02-01: judged the January window"

# ---------- S1: error-only cutoff (30 source-failed checks, no real decision) ----------
L="$LIVE/cases/s1-errors.jsonl"; : >"$L"
for i in $(seq 1 30); do "$EVENT" gquiet error --log "$L" --session "e$i" --source-ok false; done
both "S1 30 source-failed errors only, reversible" "$L" "$LIVE/rev.json"

# ---------- S2: 29 real allows vs 30 real allows ----------
L="$LIVE/cases/s2-29allow.jsonl"; : >"$L"
for i in $(seq 1 29); do "$EVENT" gquiet allow --log "$L" --session "q$i"; done
both "S2a 29 real allows, reversible" "$L" "$LIVE/rev.json"
"$EVENT" gquiet allow --log "$L" --session q30
both "S2b 30 real allows, reversible" "$L" "$LIVE/rev.json"
both "S2c 30 real allows, irreversible" "$L" "$LIVE/irr.json"

# ---------- S3: errors + bypass + extra rule row do not add opportunities ----------
L="$LIVE/cases/s3-noise.jsonl"; : >"$L"
for i in $(seq 1 29); do "$EVENT" gquiet allow --log "$L" --session "q$i"; done
"$EVENT" gquiet error --log "$L" --session gap --source-ok false
"$EVENT" gquiet bypass --log "$L" --session skip
"$EVENT" gquiet allow --log "$L" --session q28 --rule extra --no-opportunity
both "S3 29 real allows + 1 error + 1 bypass + 1 extra rule row (no-opportunity)" "$L" "$LIVE/rev.json"

# ---------- S4: bypass-only log ----------
L="$LIVE/cases/s4-bypass.jsonl"; : >"$L"
for i in $(seq 1 30); do "$EVENT" gquiet bypass --log "$L" --session "b$i"; done
both "S4 30 bypass events only, reversible" "$L" "$LIVE/rev.json"

# ---------- S5: real fire kept (deny + 30 real allows) ----------
L="$LIVE/cases/s5-real-deny.jsonl"; : >"$L"
"$EVENT" gquiet deny --log "$L" --session denied
for i in $(seq 1 30); do "$EVENT" gquiet allow --log "$L" --session "q$i"; done
both "S5 1 real deny + 30 real allows, reversible" "$L" "$LIVE/rev.json"

# ---------- S6 (adversarial, intent: failed checks are not opportunities) ----------
# Task T: real deny, allow clears it, then a source-failed deny (check could not read its source).
# Plus 27 more allows => 30 opportunities on an irreversible guard.
L="$LIVE/cases/s6-failed-check-recurrence.jsonl"; : >"$L"
"$EVENT" git-push-credential-shapes deny --log "$L" --session tsk
"$EVENT" git-push-credential-shapes allow --log "$L" --session tsk
"$EVENT" git-push-credential-shapes deny --log "$L" --session tsk --source-ok false
for i in $(seq 1 27); do "$EVENT" git-push-credential-shapes allow --log "$L" --session "p$i"; done
both "S6a source-failed deny creates a recurrence (irreversible push guard, 30 ops)" "$L" "$LIVE/push.json"

# Control: identical sequence, but the second deny is a real (source-ok) deny.
L="$LIVE/cases/s6-control-real-recurrence.jsonl"; : >"$L"
"$EVENT" git-push-credential-shapes deny --log "$L" --session tsk
"$EVENT" git-push-credential-shapes allow --log "$L" --session tsk
"$EVENT" git-push-credential-shapes deny --log "$L" --session tsk
for i in $(seq 1 27); do "$EVENT" git-push-credential-shapes allow --log "$L" --session "p$i"; done
both "S6b control: same sequence with a real second deny" "$L" "$LIVE/push.json"

# ---------- S7: historical error inside judged window (decision keep 2026-02-01) ----------
# Same fixture shape as tests/fm-guard-telemetry.test.sh judged-window case.
dated() {  # <log> <day> <count> [decision]
  local n=0 d=${4:-allow}
  while [ "$n" -lt "$3" ]; do
    printf '{"ts":"%sT12:00:%02dZ","guard":"gquiet","session":"w%s-%s-%s","decision":"%s","override":false}\n' \
      "$2" "$((n % 60))" "$2" "$d" "$n" "$d" >>"$1"; n=$((n + 1))
  done
}
L="$LIVE/cases/s7-judged-window.jsonl"; : >"$L"
for k in deny allow deny; do printf '{"ts":"2026-01-09T12:00:00Z","guard":"gquiet","session":"jan-recur","decision":"%s","override":false}\n' "$k" >>"$L"; done
dated "$L" 2026-01-10 29
dated "$L" 2026-03-10 30
both "S7a real fire at edge of judged window (keep 2026-02-01), no error" "$L" "$LIVE/rev-keep.json"
dated "$L" 2026-01-11 1 error
both "S7b same + historical error dated 2026-01-11 inside window" "$L" "$LIVE/rev-keep.json"

# ---------- S8: later error reopens review ----------
L="$LIVE/cases/s8-later-error.jsonl"; : >"$L"
dated "$L" 2026-01-10 30
both "S8a 30 Jan allows, decision keep 2026-02-01 (judged, expect no nomination)" "$L" "$LIVE/rev-keep.json"
printf '{"ts":"2026-03-10T12:00:00Z","guard":"gquiet","session":"late-err","decision":"error","override":false,"source_ok":false}\n' >>"$L"
both "S8b plus later error dated 2026-03-10 (expect re-nomination)" "$L" "$LIVE/rev-keep.json"

# ---------- S9: missing log ----------
both "S9 log file absent" "$LIVE/cases/does-not-exist.jsonl" "$LIVE/rev.json"
echo "  exit codes: old=$( "$OLD" --log "$LIVE/cases/nope.jsonl" --registry "$LIVE/rev.json" >/dev/null 2>&1; echo $?) new=$( "$NEW" --log "$LIVE/cases/nope.jsonl" --registry "$LIVE/rev.json" >/dev/null 2>&1; echo $?)"

# ---------- S10: valid verdicts unchanged (no error rows) ----------
L="$LIVE/cases/s10-control.jsonl"; : >"$L"
for i in $(seq 1 10); do "$EVENT" gquiet allow --log "$L" --session "a$i"; done
for i in 1 2 3; do "$EVENT" gquiet deny --log "$L" --session "d$i"; "$EVENT" gquiet allow --log "$L" --session "d$i"; done
"$EVENT" gquiet deny --log "$L" --session ov
"$EVENT" gquiet deny --log "$L" --session ov --override
"$EVENT" gquiet warn --log "$L" --session w1
"$EVENT" gquiet warn --log "$L" --session w2
"$EVENT" gquiet bypass --log "$L" --session by
"$EVENT" gquiet allow --log "$L" --session ex --rule extra --no-opportunity
"$EVENT" gquiet deny --log "$L" --session src --source-ok false
echo "== S10 valid controls (allow/deny/warn/override/bypass/extra row/source-false), reversible: JSON diff old vs new"
"$OLD" --log "$L" --registry "$LIVE/rev.json" --json >"$LIVE/cases/s10-old.json"
"$NEW" --log "$L" --registry "$LIVE/rev.json" --json >"$LIVE/cases/s10-new.json"
if diff -q "$LIVE/cases/s10-old.json" "$LIVE/cases/s10-new.json" >/dev/null; then
  echo "  IDENTICAL JSON (old == new)"
else
  echo "  DIFFERS:"; diff "$LIVE/cases/s10-old.json" "$LIVE/cases/s10-new.json" | head -20
fi
jq -c '.guards[0] | {opportunities, denies, warns, bypasses, overrides, verdict, recurrences, median_clear_attempts}' "$LIVE/cases/s10-new.json"
echo "  -- same S10 log plus 1 error row: JSON diff old vs new"
printf '' >/dev/null
"$EVENT" gquiet error --log "$L" --session err1 --source-ok false
"$OLD" --log "$L" --registry "$LIVE/rev.json" --json >"$LIVE/cases/s10e-old.json"
"$NEW" --log "$L" --registry "$LIVE/rev.json" --json >"$LIVE/cases/s10e-new.json"
echo "  old: $(jq -c '.guards[0] | {opportunities, verdict}' "$LIVE/cases/s10e-old.json")"
echo "  new: $(jq -c '.guards[0] | {opportunities, verdict}' "$LIVE/cases/s10e-new.json")"
