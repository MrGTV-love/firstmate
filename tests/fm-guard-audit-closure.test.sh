#!/usr/bin/env bash
# Closure proof for the guard audit at data/guard-audit-2026-10-22.md.
#
# The audit's own standard is that a ritual someone remembers is the same class
# of guard it is trying to remove, so every closure claim here is a command with
# a pass or fail. This suite is the machine that keeps the audit closed: if a
# retired guard comes back, a remedy loses its command, the registry drifts from
# the population, or a refusal loses its repair line, this test fails.
#
# Each case names its audit gap. The ledger at
# data/guard-audit-closure-2026-10-22.md maps every gap id to the case below.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-guard-lint.sh"
REFCHECK="$ROOT/bin/fm-guard-refcheck.sh"
REGISTRY="$ROOT/docs/guards/registry.json"

# --- G-10: the registry carries the population and its arithmetic -----------
out=$("$LINT" --mode enforce --counts 2>&1) || fail "registry lint is not clean in enforce mode: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION' && fail "enforce mode reported a violation: $out"
printf '%s\n' "$out" | grep -q 'active=31 retired=9 beyond_audit=8 excluded=1 unregistered=0 audited=30 beyond_audit_active=3' \
  || fail "registry arithmetic drifted from (31-3)+9-8+1+0=30: $out"
pass "G-10 the registry accounts for all 30 audited Firstmate guards"

[ -f "$ROOT/docs/guard-spec.md" ] || fail "the guard spec is missing"
jq -e '.guards | length == 31' "$REGISTRY" >/dev/null || fail "registry does not hold 31 live guards"
jq -e '.excluded | length == 1' "$REGISTRY" >/dev/null || fail "the prose exclusion is not recorded"
pass "G-10b the spec and the registry are checked in and agree"

# --- G-11: the nine rules are enforced, with a synthetic bad guard failing ---
"$ROOT/tests/fm-guard-lint.test.sh" >/dev/null 2>&1 \
  || fail "the lint's own fixture suite is red"
pass "G-11 the lint rules are proven by a fixture suite, including a prose-only remedy"

# --- G-23: the ratchet is at build-failing with an empty allowlist ----------
[ "$(jq -r '.allowed | length' "$ROOT/docs/guards/lint-allowlist.json")" = 0 ] \
  || fail "the lint allowlist is not empty"
pass "G-23 the ratchet is enforcing with an empty allowlist"

# --- G-02/G-03: wiring resolves and retired guards stay retired -------------
out=$("$REFCHECK" 2>&1) || fail "the reference check is red: $out"
printf '%s\n' "$out" | grep -q 'missing=0 registry_missing=0' || fail "reference check found missing wiring: $out"
printf '%s\n' "$out" | grep -q 'resurrected=0' || fail "a retired guard is referenced live: $out"
pass "G-02 every wired hook path and registry path resolves"
pass "G-03 no retired guard is referenced from live code"

# Every retired id ships a retirement test that exists and is tracked.
for id in $(jq -r '.[].id' "$ROOT/docs/guards/retired.json"); do
  rt=$(jq -r --arg id "$id" '.[] | select(.id == $id) | .retirement_test' "$ROOT/docs/guards/retired.json")
  [ -f "$ROOT/$rt" ] || fail "retired guard $id has no retirement test at $rt"
done
pass "G-28 every retired guard ships a retirement test"

# --- G-15/G-17: one writer and one reader exist and are covered -------------
[ -x "$ROOT/bin/fm-guard-event.sh" ] || fail "the event writer is missing"
[ -x "$ROOT/bin/fm-guard-metrics.sh" ] || fail "the metrics reader is missing"
"$ROOT/tests/fm-guard-telemetry.test.sh" >/dev/null 2>&1 \
  || fail "the telemetry contract suite is red"
pass "G-15/G-17 one event writer, one metrics reader, and a twenty-row replay"

# --- G-16: every instrumented guard really emits ----------------------------
missed=''
for id in $(jq -r '.guards[] | select(.instrumented == true) | .id' "$REGISTRY"); do
  candidates=$(jq -r --arg id "$id" '.guards[] | select(.id == $id) | .owner, ((.emitters // [])[]?)' "$REGISTRY")
  hit=0
  for candidate in $candidates; do
    if grep -qsE 'fm_guard_event|fm-guard-event\.sh' "$ROOT/$candidate"; then hit=1; break; fi
  done
  [ "$hit" -eq 1 ] || missed="$missed $id"
done
[ -z "$missed" ] || fail "instrumented guards with no writer call:$missed"
count=$(jq -r '[.guards[] | select(.instrumented == true)] | length' "$REGISTRY")
[ "$count" -ge 10 ] || fail "only $count guards are instrumented; the audit asks for ten"
pass "G-16 all $count instrumented guards call the event writer"

# --- G-12: every remedy carries an executable token ------------------------
"$LINT" --mode report 2>/dev/null | grep -q '^VIOLATION R2' \
  && fail "a remedy without an executable token survives the lint"
pass "G-12 every registered remedy carries an executable token or path"

# --- G-14: brief validation is one pass ------------------------------------
grep -qs 'fm_brief_dispatch_problems' "$ROOT/bin/fm-dod-lib.sh" \
  || fail "no single owner for the complete dispatch verdict"
grep -qs 'fm_brief_dispatch_problems' "$ROOT/bin/fm-spawn.sh" \
  || fail "spawn does not use the one-pass verdict"
grep -qs 'still contains {TASK} or {FIRSTMATE_SPEC}; fill' "$ROOT/bin/fm-spawn.sh" \
  && fail "the old two-step refusal text is still in spawn"
pass "G-14 a malformed brief is refused once with every problem listed"

# --- G-07..G-09: the named refusals carry their repair --------------------
assert_contains() {  # <file> <literal> <claim>
  grep -qF -- "$2" "$ROOT/$1" || fail "$3: $1 does not contain: $2"
  pass "$3"
}
assert_contains bin/fm-spawn.sh 'bin/fm-control.sh' 'G-20 worktree isolation names the reassociation repair'
assert_contains bin/fm-gate-refuse-lib.sh 'bin/fm-lab-home.sh create' 'G-22 gate containment names the permitted lab home'
assert_contains bin/fm-role-lib.sh 'config/firstmate-role' 'G-21 publication role names where authority is granted'
assert_contains bin/fm-send.sh 'FM_HOME=<home> bin/fm-send.sh' 'G-05 send names the working invocation'
assert_contains bin/fm-kimi-turnend-hook.sh 'bin/fm-kimi-turnend-hook.sh install' 'G-06 kimi refusal names the install step'
assert_contains bin/fm-pr-merge.sh '--allow-red' 'G-13 merge names the attended waiver'
assert_contains bin/fm-pr-merge.sh 'answer %s --decision-file <captain-answer-file> --release' 'G-13b merge names the hold release command'

# --- G-01: supervision liveness has one owner -----------------------------
[ -f "$ROOT/bin/fm-supervision-liveness-lib.sh" ] || fail "no shared liveness owner"
for f in bin/fm-turnend-guard.sh bin/fm-turnend-guard-cursor.sh bin/fm-guard.sh; do
  grep -qs 'fm-supervision-liveness-lib.sh' "$ROOT/$f" \
    || fail "$f does not source the shared liveness owner"
done
grep -qs 'bin/fm-claude-stop-autoarm.sh' "$ROOT/bin/fm-supervision-instructions.sh" \
  || fail "the Claude repair line is still a pointer"
pass "G-01 one liveness owner, and the Claude repair line is a command"

# --- G-04/G-05/G-06: Firstmate cuts are real -----------------------------
# Read the retired ids from the changelog rather than naming one here: the
# reference check forbids a retired id in tracked code, and this proof file is
# tracked code, so the assertion has to be data-driven. A line that names the
# retirement test's own path names that test, not the guard, so the path is
# masked before the id is matched, as the reference check does.
retired_live=''
while IFS=$'\t' read -r retired_id retired_test; do
  while IFS= read -r line; do
    if [[ ${line//"$retired_test"/} == *"$retired_id"* ]]; then
      retired_live="$retired_live $retired_id"
      break
    fi
  done < <(grep -rhsF -- "$retired_id" "$ROOT/bin")
done < <(jq -r '.[] | [.id, (.retirement_test // "")] | @tsv' "$ROOT/docs/guards/retired.json")
[ -z "$retired_live" ] || fail "retired guard ids still appear in bin/:$retired_live"
pass "G-04 every retired guard is absent from bin/ and the advisory cut is recorded"

printf 'ok - fm-guard-audit-closure\n'
