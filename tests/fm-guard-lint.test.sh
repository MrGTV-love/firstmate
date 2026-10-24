#!/usr/bin/env bash
# Contract tests for bin/fm-guard-lint.sh - the guard-registry lint and its
# ratchet.
#
# Each case builds a throwaway root with a registry, an allowlist, and a
# retirement changelog, then asserts the exact rule fires or does not. The suite
# is deliberately hermetic: it never reads this repository's own registry, so a
# real violation cannot change a fixture's verdict.
#
# Proven here, one case per claim:
#   - a complete registry is clean in enforce mode
#   - every rule R1 through R9 fails its own synthetic guard
#   - a prose-only remedy fails (the audit's Stage 2 gate)
#   - a nonexistent owner, test, or remedy path fails
#   - a stale allowlist entry fails even when every violation is allowlisted
#   - an allowlisted violation passes, and removing the violation makes that
#     same entry stale, so the allowlist can only shrink
#   - report mode exits 0 while still printing the violation
#   - new-or-touched mode ignores an untouched offending guard
#   - a retired guard that is still registered fails
#   - --counts excludes active and retired guards marked beyond_audit
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LINT="$ROOT/bin/fm-guard-lint.sh"
TMP=$(fm_test_tmproot fm-guard-lint)
trap 'fm_test_cleanup' EXIT

# fixture <name> -> echoes a fresh root with a valid single-guard registry and
# the files its owner and test paths name.
fixture() {
  local dir="$TMP/$1"
  mkdir -p "$dir/docs/guards" "$dir/bin" "$dir/tests"
  : >"$dir/bin/gguard.sh"
  : >"$dir/tests/gguard.test.sh"
  printf 'fm_guard_event deny\n' >"$dir/bin/gguard-instrumented.sh"
  cat >"$dir/docs/guards/registry.json" <<'JSON'
{"schema_version":1,"system":"firstmate","audited":1,"excluded":[],
 "guards":[{"id":"gguard","owner":"bin/gguard.sh","invariant":"a fixture invariant",
   "layer":"runtime-block","source":"a fixture source","trigger":"a fixture trigger",
   "decision":"deny","fail_direction":"closed","remedy":"bin/gguard.sh --clear <id>",
   "budget":1,"telemetry":"state/guard-events.jsonl","test":"tests/gguard.test.sh",
   "tier":"C","harm":"reversible","exemptions":[]}]}
JSON
  printf '{"schema_version":1,"allowed":[]}\n' >"$dir/docs/guards/lint-allowlist.json"
  printf '[]\n' >"$dir/docs/guards/retired.json"
  printf '%s\n' "$dir"
}

# mutate <root> <jq-filter> -> rewrites the registry through the filter.
mutate() {
  local dir=$1 filter=$2 tmp
  tmp="$dir/reg.tmp"
  jq "$filter" "$dir/docs/guards/registry.json" >"$tmp" || fail "jq filter failed: $filter"
  mv "$tmp" "$dir/docs/guards/registry.json"
}

run_lint() {  # <root> [extra args...]
  local dir=$1; shift
  "$LINT" --root "$dir" --mode enforce "$@" 2>&1
}

assert_fails_with() {  # <label> <root> <rule>
  local label=$1 dir=$2 rule=$3 out
  out=$(run_lint "$dir") && fail "$label: expected failure"
  printf '%s\n' "$out" | grep -q "^VIOLATION $rule " \
    || fail "$label: expected VIOLATION $rule, got: $out"
  pass "$label"
}

assert_clean() {  # <label> <root>
  local label=$1 dir=$2 out
  out=$(run_lint "$dir") || fail "$label: expected clean exit, got: $out"
  printf '%s\n' "$out" | grep -q '^VIOLATION ' && fail "$label: unexpected violation: $out"
  pass "$label"
}

# --- clean baseline ---------------------------------------------------------
BASE=$(fixture base)
assert_clean "a complete single-guard registry is clean" "$BASE"

# --- R1 duplicate id and duplicate invariant --------------------------------
DUP=$(fixture dup)
mutate "$DUP" '.guards += [.guards[0]]'
assert_fails_with "R1 fails a duplicate id" "$DUP" R1

INV=$(fixture dupinv)
mutate "$INV" '.guards += [(.guards[0] | .id = "gguard2" | .owner = "bin/gguard2.sh" | .test = "tests/gguard2.test.sh")]'
: >"$INV/bin/gguard2.sh"; : >"$INV/tests/gguard2.test.sh"
assert_fails_with "R1 fails a duplicate invariant" "$INV" R1

# --- R2 remedy --------------------------------------------------------------
PROSE=$(fixture prose)
mutate "$PROSE" '.guards[0].remedy = "ask someone who knows the system"'
assert_fails_with "R2 fails a prose-only remedy" "$PROSE" R2

NOPATH=$(fixture nopath)
mutate "$NOPATH" '.guards[0].remedy = "bin/does-not-exist.sh --clear <id>"'
assert_fails_with "R2 fails a remedy naming a missing script" "$NOPATH" R2

EMPTY=$(fixture empty_rem)
mutate "$EMPTY" '.guards[0].remedy = ""'
assert_fails_with "R2 fails an empty remedy" "$EMPTY" R2

# --- R3 proxy source --------------------------------------------------------
PROXY=$(fixture proxy)
mutate "$PROXY" '.guards[0].proxy = true'
assert_fails_with "R3 fails a proxy source with no reason" "$PROXY" R3

PROXYOK=$(fixture proxyok)
mutate "$PROXYOK" '.guards[0].proxy = true | .guards[0].proxy_reason = "the authoritative source is unavailable here"'
assert_clean "R3 accepts a proxy source with a reason" "$PROXYOK"

# --- R4 fail direction ------------------------------------------------------
FAIL=$(fixture faildir)
mutate "$FAIL" '.guards[0].fail_direction = "sometimes"'
assert_fails_with "R4 fails an undeclared fail direction" "$FAIL" R4

# --- R5 budget --------------------------------------------------------------
BUDGET=$(fixture budget)
mutate "$BUDGET" '.guards[0].budget = 9'
assert_fails_with "R5 fails a budget above three with no reason" "$BUDGET" R5

BUDGETOK=$(fixture budgetok)
mutate "$BUDGETOK" '.guards[0].budget = 9 | .guards[0].budget_reason = "a checked exception"'
assert_clean "R5 accepts a declared budget exception" "$BUDGETOK"

# --- R6 post-write guard ----------------------------------------------------
POST=$(fixture posthoc)
mutate "$POST" '.guards[0].layer = "runtime-warn-after-write"'
assert_fails_with "R6 fails a post-write guard with no precheck_gap" "$POST" R6

# --- R7 wiring --------------------------------------------------------------
MISSINGOWNER=$(fixture missingowner)
rm -f "$MISSINGOWNER/bin/gguard.sh"
assert_fails_with "R7 fails a nonexistent owner file" "$MISSINGOWNER" R7

MISSINGTEST=$(fixture missingtest)
rm -f "$MISSINGTEST/tests/gguard.test.sh"
assert_fails_with "R7 fails a nonexistent test file" "$MISSINGTEST" R7

# --- R8 telemetry -----------------------------------------------------------
NOTEL=$(fixture notel)
mutate "$NOTEL" '.guards[0].telemetry = ""'
assert_fails_with "R8 fails a guard with no telemetry target" "$NOTEL" R8

NOEVENT=$(fixture noevent)
mutate "$NOEVENT" '.guards[0].owner = "bin/gguard-instrumented.sh" | .guards[0].instrumented = true'
assert_clean "R8 accepts an instrumented guard that calls the writer" "$NOEVENT"
mutate "$NOEVENT" '.guards[0].owner = "bin/gguard.sh"'
assert_fails_with "R8 fails an instrumented guard that never calls the writer" "$NOEVENT" R8

# --- R9 exemptions ----------------------------------------------------------
EXEMPT=$(fixture exempt)
mutate "$EXEMPT" '.guards[0].exemptions = [{"case":"a carve-out"}]'
assert_fails_with "R9 fails an exemption with no derivation" "$EXEMPT" R9

# --- retired inventory ------------------------------------------------------
RETIRED=$(fixture retired)
mutate "$RETIRED" '.audited = 2'
cat >"$RETIRED/docs/guards/retired.json" <<'JSON'
[{"id":"gone-guard","system":"firstmate","invariant":"a retired invariant","retired":"2026-10-22",
  "why":"it protected a reversible action","replaced_by":"nothing","retirement_test":"tests/gguard.test.sh"}]
JSON
assert_clean "a retired guard with a live retirement test is clean" "$RETIRED"
mutate "$RETIRED" '.guards += [(.guards[0] | .id = "gone-guard" | .invariant = "a retired invariant")]'
assert_fails_with "a retired guard that is still registered fails" "$RETIRED" R1

# --- audited inventory ------------------------------------------------------
COUNTS=$(fixture counts)
mutate "$COUNTS" '.guards += [(.guards[0] | .id = "late-guard" | .invariant = "a post-audit invariant")]'
cat >"$COUNTS/docs/guards/retired.json" <<'JSON'
[{"id":"late-gone","system":"firstmate","invariant":"a post-audit retired invariant","retired":"2026-10-24",
  "why":"it was never in the audit","replaced_by":"nothing","retirement_test":"tests/gguard.test.sh"}]
JSON
out=$(run_lint "$COUNTS" --counts) && fail "unmarked post-audit guards must break the audited inventory"
printf '%s\n' "$out" | grep -q '^VIOLATION R1 inventory' || fail "expected the inventory violation, got: $out"
mutate "$COUNTS" '.guards[1].beyond_audit = true'
jq '.[0].beyond_audit = true' "$COUNTS/docs/guards/retired.json" >"$COUNTS/retired.tmp" && mv "$COUNTS/retired.tmp" "$COUNTS/docs/guards/retired.json"
out=$(run_lint "$COUNTS" --counts) || fail "marked post-audit guards must keep the audited inventory: $out"
printf '%s\n' "$out" | grep -q 'active=2 active_beyond_audit=1 retired=1 beyond_audit=1 excluded=0 unregistered=0 audited=1' \
  || fail "inventory did not exclude post-audit guards: $out"
pass "post-audit active and retired guards marked beyond_audit stay outside the audited inventory"

# --- ratchet ----------------------------------------------------------------
ALLOW=$(fixture allowlist)
mutate "$ALLOW" '.guards[0].remedy = "a pointer with no command"'
out=$(run_lint "$ALLOW") && fail "the unallowlisted prose remedy should fail"
printf '%s\n' "$out" | grep -q '^VIOLATION R2 ' || fail "expected the R2 violation to print"
printf '{"schema_version":1,"allowed":[{"id":"gguard","rule":"R2","reason":"fixture debt"}]}\n' \
  >"$ALLOW/docs/guards/lint-allowlist.json"
run_lint "$ALLOW" >/dev/null 2>&1 || fail "an allowlisted violation must pass in enforce mode"
pass "an allowlisted violation passes"

mutate "$ALLOW" '.guards[0].remedy = "bin/gguard.sh --clear <id>"'
out=$(run_lint "$ALLOW") && fail "a stale allowlist entry must fail"
printf '%s\n' "$out" | grep -q '^STALE R2 gguard' || fail "expected STALE R2 gguard, got: $out"
pass "a stale allowlist entry fails, so the allowlist can only shrink"

# --- report mode ------------------------------------------------------------
REPORT=$(fixture report)
mutate "$REPORT" '.guards[0].remedy = "a pointer with no command"'
out=$("$LINT" --root "$REPORT" --mode report 2>&1) || fail "report mode must exit 0"
printf '%s\n' "$out" | grep -q '^VIOLATION R2 ' || fail "report mode must still print the violation"
pass "report mode prints a violation and exits 0"

# --- new-or-touched ---------------------------------------------------------
NAT=$(fixture newortouched)
git -C "$NAT" init -q
git -C "$NAT" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$NAT" -c user.email=t@example.invalid -c user.name=t commit -qm base
# Land the legacy debt first, so the base commit already carries the offending
# guard; the ratchet must not re-report unchanged debt.
mutate "$NAT" '.guards[0].remedy = "a pointer with no command"'
git -C "$NAT" -c user.email=t@example.invalid -c user.name=t commit -qam legacy
mutate "$NAT" '.guards += [(.guards[0] | .id = "gnew" | .invariant = "a second invariant" | .owner = "bin/gguard2.sh" | .test = "tests/gguard2.test.sh")]
  | (.guards[] | select(.id == "gnew") | .remedy) = "bin/gguard2.sh --clear <id>"'
: >"$NAT/bin/gguard2.sh"; : >"$NAT/tests/gguard2.test.sh"
# The offending guard is unchanged; only gnew was added, and gnew is clean.
"$LINT" --root "$NAT" --mode new-or-touched --base HEAD >/dev/null 2>&1 \
  || fail "new-or-touched must ignore an unchanged offending guard"
pass "new-or-touched ignores an unchanged offending guard"

mutate "$NAT" '(.guards[] | select(.id == "gnew") | .remedy) = "a pointer with no command"'
out=$("$LINT" --root "$NAT" --mode new-or-touched --base HEAD 2>&1) && fail "new-or-touched must fail for a touched guard"
printf '%s\n' "$out" | grep -q 'VIOLATION R2 gnew' || fail "expected the touched guard to fail, got: $out"
pass "new-or-touched fails for a touched guard"

# --- malformed input --------------------------------------------------------
BROKEN=$(fixture broken)
printf 'not json\n' >"$BROKEN/docs/guards/registry.json"
"$LINT" --root "$BROKEN" --mode report >/dev/null 2>&1 && fail "a malformed registry must fail"
pass "a malformed registry fails"

printf 'ok - fm-guard-lint\n'
