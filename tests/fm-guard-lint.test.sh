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
#   - --counts excludes active guards named in beyond_audit_active and beyond_audit_retired points
#   - every refusal-site signature (marker, message, helper call, hook deny, guard event) is found
#     in the default discovery paths, and comments, heredocs, docstrings and tests are not
#   - an unmapped `|| exit 2` in a hook script fails S1, and the same site mapped passes
#   - an unquoted refusal in a stderr heredoc, a refusal in a perl heredoc and a refusal under .dsh/
#     are sites, while a variable,
#     a path, a compared value and an argument-count exit 2 are not
#   - an unmapped site fails S1, the same site mapped by a sites marker passes, and a site added
#     inside an already-mapped owner file still needs its own mapping
#   - a marker that matches nothing, the wrong number of sites, or a site another entry owns fails
#     S2, and a marker absorbing a new site fails new-or-touched mode
#   - a typed unregistered_ids list whose length differs from the computed count fails S4
#   - an allowlisted site passes, deleting the site makes its entry stale, a touched site fails
#     in new-or-touched mode even when allowlisted, and the sealed allowlist cannot grow (S5)
#   - in a git root, a file under a git-ignored directory is not a site, while an untracked new file is
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
  printf 'fm_guard_event() { :; }\n' >"$dir/bin/gguard-instrumented.sh"
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

# --- post-audit inventory ---------------------------------------------------
LATER=$(fixture later)
mutate "$LATER" '.guards += [(.guards[0] | .id = "later-guard" | .invariant = "a later invariant")]'
out=$(run_lint "$LATER" --counts) && fail "an unaccounted post-audit guard balanced the inventory: $out"
mutate "$LATER" '.beyond_audit_active = ["missing-guard"]'
out=$(run_lint "$LATER" --counts) && fail "an unregistered post-audit id balanced the inventory: $out"
mutate "$LATER" '.beyond_audit_active = ["later-guard"]'
out=$(run_lint "$LATER" --counts) || fail "a registered post-audit guard did not balance the inventory: $out"
pass "a guard registered after the audit balances the inventory only when it is named"

# --- audited inventory ------------------------------------------------------
COUNTS=$(fixture counts)
mutate "$COUNTS" '.guards += [(.guards[0] | .id = "late-guard" | .invariant = "a post-audit invariant")]'
cat >"$COUNTS/docs/guards/retired.json" <<'JSON'
[{"id":"late-gone","system":"firstmate","invariant":"a post-audit retired invariant","retired":"2026-10-24",
  "why":"it was never in the audit","replaced_by":"nothing","retirement_test":"tests/gguard.test.sh"}]
JSON
out=$(run_lint "$COUNTS" --counts) && fail "unmarked post-audit guards must break the audited inventory"
printf '%s\n' "$out" | grep -q '^VIOLATION R1 inventory' || fail "expected the inventory violation, got: $out"
mutate "$COUNTS" '.beyond_audit_active = [.guards[1].id] | .beyond_audit_retired = [{"point":"late-gone","evidence":"fixture","reason":"never in the audit"}]'
out=$(run_lint "$COUNTS" --counts) || fail "marked post-audit guards must keep the audited inventory: $out"
printf '%s\n' "$out" | grep -q 'active=2 retired=1 beyond_audit=1 excluded=0 unregistered=0 audited=1 beyond_audit_active=1' \
  || fail "inventory did not exclude post-audit guards: $out"
pass "post-audit active guards named in beyond_audit_active and beyond_audit_retired points stay outside the audited inventory"

# --- post-audit active guards ------------------------------------------------
POSTAUDIT=$(fixture postaudit)
mutate "$POSTAUDIT" '.guards += [(.guards[0] | .id = "new-guard" | .invariant = "a post-audit invariant")]'
out=$(run_lint "$POSTAUDIT" --counts) && fail "an unaccounted post-audit guard must fail the count"
printf '%s\n' "$out" | grep -q '^VIOLATION R1 inventory' || fail "expected the inventory violation, got: $out"
pass "a guard added after the audit fails the count until it is accounted for"
mutate "$POSTAUDIT" '.beyond_audit_active = ["new-guard"]'
out=$(run_lint "$POSTAUDIT" --counts) || fail "an accounted post-audit guard must keep the count clean: $out"
printf '%s\n' "$out" | grep -q 'active=2 retired=0 beyond_audit=0 excluded=0 unregistered=0 audited=1 beyond_audit_active=1' \
  || fail "the post-audit guard must be counted outside the audit: $out"
pass "a post-audit guard in beyond_audit_active keeps the audited size unchanged"
mutate "$POSTAUDIT" '.beyond_audit_active += ["unknown-guard"] | .audited = 0'
out=$(run_lint "$POSTAUDIT" --counts) && fail "a post-audit entry with no registered guard must fail"
printf '%s\n' "$out" | grep -q '^VIOLATION R1 unknown-guard' || fail "expected the unknown-guard violation, got: $out"
pass "a post-audit entry must name a registered guard"

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

# --- refusal sites: signatures ----------------------------------------------
site_ids() {  # <root> -> the S1 site ids a report-mode run prints
  "$LINT" --root "$1" --mode report 2>&1 | awk '$1 == "VIOLATION" && $2 == "S1" {sub(/:$/, "", $3); print $3}'
}

site_owners() {  # <root> -> "<line> <entry>" for every site the scan discovers
  python3 "$ROOT/bin/fm-guard-sites.py" --root "$1" | jq -r '.sites[] | "\(.line) \(.entry)"'
}

assert_mapped() {  # <label> <root> <mapped-count>: clean, and the scan counts that many mapped sites
  local label=$1 dir=$2 want=$3 out
  out=$(run_lint "$dir" --counts) || fail "$label: expected clean exit, got: $out"
  printf '%s\n' "$out" | grep -q '^VIOLATION ' && fail "$label: unexpected violation: $out"
  printf '%s\n' "$out" | grep -q " mapped=$want\$" || fail "$label: expected mapped=$want, got: $out"
  pass "$label"
}

assert_site() {  # <label> <root> <signature-regex>
  local label=$1 dir=$2 sig=$3 out
  out=$(run_lint "$dir") && fail "$label: an unmapped site must fail"
  printf '%s\n' "$out" | grep -Eq "^VIOLATION S1 site:.* \[$sig\] " \
    || fail "$label: expected an S1 site with signature $sig, got: $out"
  pass "$label"
}

SIG=$(fixture sig_marker)
printf 'printf "REFUSED: guard=x rule=y\\n" >&2\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a REFUSED: marker site" "$SIG" 'A,B'

SIG=$(fixture sig_message)
printf 'echo "error: refusing to launch the worker" >&2\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a refusing message site" "$SIG" 'B'

SIG=$(fixture sig_split)
printf 'echo "error: could not proceed" \\\n  "so refusing the request" >&2\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a message split across lines" "$SIG" 'B'

SIG=$(fixture sig_variable)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'msg="refused: the lease is gone"\necho "$msg" >&2\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a message built in a variable" "$SIG" 'B'

SIG=$(fixture sig_helper)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'refuse() { echo "$*" >&2; exit 1; }\n[ -n "$1" ] || refuse "no task named"\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a call to a refuse helper whose message has no refusal word" "$SIG" 'C'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "the helper definition must not count as a site: $(site_ids "$SIG")"
pass "a helper definition is not a site, only its call"

SIG=$(fixture sig_oneline_wrapper)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'refuse() { echo "$*" >&2; exit 1; }\nprobe() { [ -n "$1" ] || refuse "no task named"; }\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a refuse helper call inside a one-line function definition" "$SIG" 'C'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "only the wrapper's call must count as a site: $(site_ids "$SIG")"
pass "a one-line wrapper's helper call is a site, the helper's own definition is not"

SIG=$(fixture sig_case_arm)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'refuse() { echo "$*" >&2; exit 1; }\ncase "$1" in\n  ""|*[!a-z]*) refuse "no task named" ;;\nesac\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a refuse helper call after a case-arm pattern" "$SIG" 'C'

SIG=$(fixture sig_runtime_multiline)
printf 'def go(x):\n    raise RuntimeError("""\nrefusing to continue\n""")\n' >"$SIG/bin/example.py"
assert_site "S1 finds a refusal inside a runtime multiline string" "$SIG" 'B'
mutate "$SIG" '.guards[0].sites = [{"file":"bin/example.py","match":"refusing to continue"}]'
assert_mapped "a runtime multiline refusal passes once a registered entry maps it" "$SIG" 1

SIG=$(fixture sig_docstring_multiline)
printf 'def go(x):\n    """\n    This function refuses nothing.\n    """\n    return x\n\nclass Thing:\n    """\n    Thing refuses nothing either.\n    """\n\nraise RuntimeError("""\nrefusing the one real thing\n""")\n' >"$SIG/bin/example.py"
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "only the runtime string may be a site, not the function and class docstrings: $(site_ids "$SIG")"
pass "multiline docstrings are not sites while the runtime multiline string beside them is"

SIG=$(fixture sig_docstring_forms)
printf 'def a(x):\n    r"""\n    a refuses nothing.\n    """\n    return x\n\ndef b(x):  # noqa\n    """\n    b refuses nothing.\n    """\n    return x\n\ndef c(x):  # noqa\n    u"""c refuses nothing."""\n    return x\n\ndef d(x):  # don'"'"'t touch\n    """\n    d refuses nothing.\n    """\n    return x\n\ndef e(x="#"):  # don'"'"'t touch\n    """e refuses nothing."""\n    return x\n' >"$SIG/bin/example.py"
[ -z "$(site_ids "$SIG")" ] || fail "prefixed docstrings and docstrings after a commented header must not be sites: $(site_ids "$SIG")"
pass "prefixed docstrings and docstrings after a commented header are not sites"

SIG=$(fixture sig_event_id_allow)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" deployment-allow-check deny --source-ok true\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a deny event whose guard id contains the word allow" "$SIG" 'E'
mutate "$SIG" '.guards[0].sites = [{"file":"bin/a.sh","match":"deployment-allow-check deny"}]'
assert_mapped "a deny event with allow in its guard id passes once a registered entry maps it" "$SIG" 1

SIG=$(fixture sig_event_comment_allow)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" some-guard deny --source-ok true # not allow\n"$DIR/fm-guard-event.sh" other-guard allow --cleared-by retry # deny\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a deny event whose trailing comment says allow" "$SIG" 'E'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "the allow event with a deny comment must not count as a site: $(site_ids "$SIG")"
pass "the event's own decision argument decides, not the words around it"

SIG=$(fixture sig_event_id_is_allow)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" allow deny --source-ok true\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a deny event whose guard id is the word allow" "$SIG" 'E'
mutate "$SIG" '.guards[0].sites = [{"file":"bin/a.sh","match":"allow deny --source-ok"}]'
assert_mapped "a deny event whose guard id is allow passes once a registered entry maps it" "$SIG" 1

SIG=$(fixture sig_event_allow_punctuation)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'probe() { "$DIR/fm-guard-event.sh" some-guard allow; }\nprobe2() { "$DIR/fm-guard-event.sh" some-guard allow || true; }\nprobe3() { "$DIR/fm-guard-event.sh" other-guard deny; }\n' >"$SIG/bin/a.sh"
assert_site "S1 finds the deny event among allow events that end in shell punctuation" "$SIG" 'E'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "only the deny event may be a site; allow; and allow || true are allow events: $(site_ids "$SIG")"
pass "a shell separator after the decision does not turn an allow event into a deny"

SIG=$(fixture sig_event_wrapper)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'guard_event allow --source-ok true --cleared-by continue\nguard_event deny --source-ok true --repeat 1\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a deny wrapper call beside an allow wrapper call" "$SIG" 'E'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "only the deny wrapper call may be a site: $(site_ids "$SIG")"
pass "a wrapper that takes the decision first is judged by that decision"

# Shell syntax is judged with quote provenance: a # inside a word and a quoted } or | are literal
# arguments of the event, so each allow line below is an allow event and only the control line denies.
SIG=$(fixture sig_event_hash_in_id)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" deployment#1 allow\n"$DIR/fm-guard-event.sh" control-guard deny\n' >"$SIG/bin/a.sh"
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "a # inside a word is not a comment, so deployment#1 allow is an allow event: $(site_ids "$SIG")"
pass "a hash inside a guard id does not start a comment"

SIG=$(fixture sig_event_quoted_brace)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" "}" allow\n"$DIR/fm-guard-event.sh" control-guard deny\n' >"$SIG/bin/a.sh"
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "a quoted } is a literal guard id, so it is an allow event: $(site_ids "$SIG")"
pass "a quoted closing brace is an argument, not a command boundary"

SIG=$(fixture sig_event_quoted_pipe)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" "|" allow\n"$DIR/fm-guard-event.sh" control-guard deny\n' >"$SIG/bin/a.sh"
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "a quoted | is a literal guard id, so it is an allow event: $(site_ids "$SIG")"
pass "a quoted pipe is an argument, not an operator"

SIG=$(fixture sig_oneline_event)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'probe() { "$DIR/fm-guard-event.sh" some-guard deny --source-ok true; }\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a guard event deny inside a one-line function definition" "$SIG" 'E'

SIG=$(fixture sig_python_event)
cat >"$SIG/bin/a.py" <<'PY'
import os
import subprocess
EVENT_WRITER = os.path.join('/synthetic', 'fm-guard-event.sh')

def record(guard, decision):
    subprocess.run([EVENT_WRITER, guard, decision])

record('credential-fixture', 'deny' if blocked else 'allow')
record('allowed-fixture', 'allow')
record('allowed-branches', 'allow' if blocked else 'allow')
record(guard='keyword-fixture', decision='deny')
subprocess.run([
    EVENT_WRITER, 'direct-fixture', 'deny',
])
subprocess.run([EVENT_WRITER, 'allowed-direct', 'allow'])
subprocess.run(['other-command', 'not-an-event', 'deny'])
# record('comment', 'deny')
example = "record('string', 'deny')"

def emit():
    record('function-fixture', 'deny')

def ordinary(record):
    record('parameter-data', 'deny')
    def nested():
        record('closure-data', 'deny')
    return nested

def locally_bound():
    record = lambda *args: None
    record('local-data', 'deny')

def locally_imported():
    from unrelated import record
    record('imported-data', 'deny')

shadowed_lambda = lambda record: record('lambda-data', 'deny')
shadowed_comprehension = [record('comprehension-data', 'deny') for record in callbacks]

def comprehensions(denied):
    [record(guard, 'deny') for guard in denied]
    {record(guard, 'deny') for guard in denied}
    {guard: record(guard, 'deny') for guard in denied}
    list(record(guard, 'deny') for guard in denied)
    [guard for record in record('iterable-fixture', 'deny') for guard in record]

def shadowed_comprehensions(callbacks):
    [record('list-data', 'deny') for record in callbacks]
    {record('set-data', 'deny') for record in callbacks}
    {record: record('dict-data', 'deny') for record in callbacks}
    list(record('generator-data', 'deny') for record in callbacks)
    [record('nested-data', 'deny') for group in callbacks for record in group]
PY
assert_site "S1 finds the Python conditional credential event decision" "$SIG" 'E'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 9 ] \
  || fail "only conditional, keyword, direct and unshadowed function and comprehension deny calls may be sites: $(site_ids "$SIG")"
mutate "$SIG" '.guards[0].sites = [
  {"file":"bin/a.py","match":"record('\''credential-fixture'\''"},
  {"file":"bin/a.py","match":"record(guard="},
  {"file":"bin/a.py","match":"subprocess.run(["},
  {"file":"bin/a.py","match":"record('\''function-fixture'\''"},
  {"file":"bin/a.py","match":"record(guard, '\''deny'\'')","count":4},
  {"file":"bin/a.py","match":"record('\''iterable-fixture'\''"}]'
assert_mapped "Python event sites exclude allow calls and same-module lexical shadowing" "$SIG" 9

SIG=$(fixture sig_python_unbound_record)
cat >"$SIG/bin/a.py" <<'PY'
import subprocess

def record(guard, decision):
    subprocess.run(['unrelated-program', guard, decision])

record('ordinary-data', 'deny')
PY
[ -z "$(site_ids "$SIG")" ] || fail "an unrelated record function must not become a guard event"
pass "an arbitrary Python record function is not a guard event"

SIG=$(fixture sig_python_helper)
printf 'def refuse(reason):\n    raise SystemExit(reason)\n\nrefuse("no task named")\n' >"$SIG/bin/a.py"
assert_site "S1 finds a call to a Python refuse helper" "$SIG" 'C'

SIG=$(fixture sig_hook)
printf '#!/usr/bin/env bash\nprintf %s "{\\"hookSpecificOutput\\":{\\"permissionDecision\\":\\"deny\\"}}"\n' "'%s\\n'" >"$SIG/bin/fm-x-pretool-check.sh"
assert_site "S1 finds a hook permission deny" "$SIG" 'D'

SIG=$(fixture sig_hook_exit)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '#!/usr/bin/env bash\ncase "$1" in\n  -h) usage >&2\n    exit 2 ;;\nesac\nexit 2\n' >"$SIG/bin/fm-x-pretool-check.sh"
assert_site "S1 finds the bare exit 2 of a hook script" "$SIG" 'D'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "the usage exit 2 must not count as a deny: $(site_ids "$SIG")"
pass "a usage exit 2 in a hook script is not a deny"

SIG=$(fixture sig_hook_or_exit)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '#!/usr/bin/env bash\n[ "$#" -eq 0 ] || exit 2\nif [ "$#" -gt 1 ]; then\n  exit 2\nfi\nreset_episode "$STATE" || exit 2\n' >"$SIG/bin/fm-x-turnend-check.sh"
assert_site "S1 fails an unmapped || exit 2 of a hook script" "$SIG" 'D'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "the argument-count exit 2 must not count as a deny: $(site_ids "$SIG")"
pass "an argument-count exit 2 in a hook script is not a deny"
# shellcheck disable=SC2016 # the jq filter matches literal shell source
mutate "$SIG" '.guards[0].sites = [{"file":"bin/fm-x-turnend-check.sh","match":"reset_episode \"$STATE\" || exit 2"}]'
assert_mapped "a || exit 2 hook site passes once a registered entry maps it" "$SIG" 1

SIG=$(fixture sig_heredoc_stderr)
printf 'cat >&2 <<EOF\nerror: refusing to retire the slot\nEOF\n' >"$SIG/bin/a.sh"
assert_site "S1 finds an unquoted refusal in a heredoc printed to stderr" "$SIG" 'B'

SIG=$(fixture sig_heredoc_perl)
printf 'IFS= read -r -d '"''"' PROG <<'"'"'PERL'"'"' || :\nprint STDERR "x: refused: the log stayed locked\\n";\nPERL\nperl <<'"'"'EOF'"'"'\nprint STDERR "x: refused: the log is full\\n";\nEOF\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a refusal in a perl heredoc" "$SIG" 'B'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 2 ] || fail "both perl heredoc refusals must be sites: $(site_ids "$SIG")"
pass "a heredoc delimited by PERL or fed to perl is scanned as code"

SIG=$(fixture sig_dsh)
mkdir -p "$SIG/.dsh"
printf 'console.error("REFUSED: the adapter cannot relay");\n' >"$SIG/.dsh/p.mjs"
assert_site "S1 finds a refusal in the .dsh adapter" "$SIG" 'A,B'

SIG=$(fixture sig_plugin)
mkdir -p "$SIG/.opencode/plugins"
printf 'export default { before() { throw new Error(reason); } };\n' >"$SIG/.opencode/plugins/p.js"
assert_site "S1 finds an opencode plugin throw" "$SIG" 'D'

SIG=$(fixture sig_event)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf '"$DIR/fm-guard-event.sh" some-guard deny --source-ok true\n"$DIR/fm-guard-event.sh" some-guard allow --cleared-by retry\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a guard event deny" "$SIG" 'E'
[ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] || fail "an allow event must not count as a site: $(site_ids "$SIG")"
pass "a guard event allow is not a site"

SIG=$(fixture sig_quiet)
printf '# refusing here is only a comment: REFUSED: nothing\ncat <<'"'"'DOC'"'"'\nthe script refuses when it is told to\nDOC\necho "ok"\n' >"$SIG/bin/a.sh"
printf '"""This module refuses nothing."""\nx = 1  # refused\nif state == "refused":\n    x = 2\n' >"$SIG/bin/b.py"
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'if [ "$refused" = 1 ]; then\n  rm -f -- "$DIR/$id.refused" "${refused}"\nfi\n' >"$SIG/bin/e.sh"
printf 'if (device.effect === "refused") { done(); }\nif (line.startsWith("refused: ")) { done(); }\n' >"$SIG/bin/f.js"
printf 'seen = any(row.startswith(("skipped: ", "refused: ")) for row in rows)\n' >"$SIG/bin/g.py"
mkdir -p "$SIG/bin/tests"
printf 'echo "REFUSED: a fixture"\n' >"$SIG/bin/tests/c.sh"
printf 'echo "REFUSED: the one genuine site" >&2\n' >"$SIG/bin/d.sh"
[ "$(site_ids "$SIG")" = "$(site_ids "$SIG" | grep 'bin/d.sh')" ] && [ "$(site_ids "$SIG" | wc -l | tr -d ' ')" = 1 ] \
  || fail "only the genuine site may be found among comments, heredoc bodies, docstrings and tests: $(site_ids "$SIG")"
pass "comments, heredoc bodies, docstrings, test directories, variables, paths and compared values are not sites"

# --- refusal sites: mapping --------------------------------------------------
MAPPED=$(fixture site_mapped)
printf 'echo "REFUSED: the fixture cannot proceed" >&2\n' >"$MAPPED/bin/gnew.sh"
assert_fails_with "S1 fails a refusal site that maps to no registry entry" "$MAPPED" S1
mutate "$MAPPED" '.guards[0].sites = [{"file":"bin/gnew.sh","match":"the fixture cannot proceed"}]'
assert_mapped "a refusal site passes once a registered entry maps it with a sites marker" "$MAPPED" 1

OWNER=$(fixture site_owner)
printf 'echo "REFUSED: the first refusal" >&2\n' >"$OWNER/bin/gguard.sh"
mutate "$OWNER" '.guards[0].sites = [{"file":"bin/gguard.sh","match":"the first refusal"}]'
assert_mapped "a site inside the owner file passes when its marker names it" "$OWNER" 1
printf 'echo "REFUSED: a second refusal added later" >&2\n' >>"$OWNER/bin/gguard.sh"
assert_fails_with "S1 fails a new site added inside an already-mapped owner file" "$OWNER" S1

STALEMARK=$(fixture site_stale_marker)
mutate "$STALEMARK" '.guards[0].sites = [{"file":"bin/gguard.sh","match":"a refusal that was deleted"}]'
assert_fails_with "S2 fails a sites marker that matches no site" "$STALEMARK" S2

COUNT=$(fixture site_count)
printf 'echo "REFUSED: one shared refusal" >&2\necho "REFUSED: one shared refusal again" >&2\n' >"$COUNT/bin/gnew.sh"
mutate "$COUNT" '.guards[0].sites = [{"file":"bin/gnew.sh","match":"one shared refusal"}]'
assert_fails_with "S2 fails a marker that matches more sites than its count declares" "$COUNT" S2
mutate "$COUNT" '.guards[0].sites[0].count = 2'
assert_mapped "a group entry with a counted marker passes" "$COUNT" 2

TWICE=$(fixture site_twice)
printf 'echo "REFUSED: contested refusal" >&2\n' >"$TWICE/bin/gnew.sh"
mutate "$TWICE" '.guards[0].sites = [{"file":"bin/gnew.sh","match":"contested refusal"}]
  | .guards += [(.guards[0] | .id = "gother" | .invariant = "another invariant" | .owner = "bin/gother.sh" | .test = "tests/gother.test.sh")]'
: >"$TWICE/bin/gother.sh"; : >"$TWICE/tests/gother.test.sh"
assert_fails_with "S2 fails a site that two entries map" "$TWICE" S2

KEYED=$(fixture site_keyed)
cat >"$KEYED/bin/a.sh" <<'SH'
if [ -n "$first" ]; then
  echo "REFUSED: repeated line" >&2
fi
if [ -n "$second" ]; then
  echo "REFUSED: repeated line" >&2
fi
SH
KEY=$(site_ids "$KEYED" | sed 's/~[0-9]*$//' | sort -u)
mutate "$KEYED" ".guards[0].sites = [{\"file\":\"bin/a.sh\",\"match\":\"REFUSED: repeated line\",\"key\":\"$KEY\",\"within\":\"\$first\"}]
  | .guards += [(.guards[0] | .id = \"gother\" | .invariant = \"another invariant\" | .sites[0].within = \"\$second\")]
  | .beyond_audit_active = [\"gother\"]"
assert_mapped "a block context distinguishes identical lines enforcing different invariants" "$KEYED" 2
[ "$(site_owners "$KEYED")" = "$(printf '2 gguard\n5 gother')" ] \
  || fail "each identical line must map to the guard its block names: $(site_owners "$KEYED")"
cat >"$KEYED/bin/a.sh" <<'SH'
if [ -n "$second" ]; then
  echo "REFUSED: repeated line" >&2
fi
if [ -n "$first" ]; then
  echo "REFUSED: repeated line" >&2
fi
SH
assert_mapped "moving identical refusal blocks keeps every site mapped" "$KEYED" 2
[ "$(site_owners "$KEYED")" = "$(printf '2 gother\n5 gguard')" ] \
  || fail "a moved identical line must keep its owner: $(site_owners "$KEYED")"
{ printf 'if [ -n "$third" ]; then\n  echo "REFUSED: repeated line" >&2\nfi\n'; cat "$KEYED/bin/a.sh"; } >"$KEYED/a.tmp"
mv "$KEYED/a.tmp" "$KEYED/bin/a.sh"
assert_fails_with "a new identical refusal in another block is S1" "$KEYED" S1
[ "$(site_owners "$KEYED")" = "$(printf '2 null\n5 gother\n8 gguard')" ] \
  || fail "a new identical line above mapped ones must stay unmapped while they keep their owners: $(site_owners "$KEYED")"
printf 'if [ -n "$first" ]; then\n  echo "REFUSED: repeated line" >&2\n  echo "REFUSED: repeated line" >&2\nfi\n' >"$KEYED/bin/a.sh"
assert_fails_with "a new identical refusal in a mapped block changes its marker count" "$KEYED" S2
printf 'if [ -n "$first" ]; then\n  echo "REFUSED: repeated line" >&2\nfi\nif [ -n "$second" ]; then\n  echo "REFUSED: repeated line" >&2\nfi\n' >"$KEYED/bin/a.sh"
mutate "$KEYED" '.guards[1].sites[0].within = "$first"'
assert_fails_with "a block context still cannot give a site two owners" "$KEYED" S2
mutate "$KEYED" '.guards[1].sites[0].within = "$second" | .guards[1].sites[0].match = "missing text"'
assert_fails_with "a valid key and context do not bypass marker text" "$KEYED" S2
mutate "$KEYED" '.guards[1].sites[0].match = "REFUSED: repeated line" | .guards[1].sites[0].key = "site:missing"'
assert_fails_with "a missing site key is stale" "$KEYED" S2
mutate "$KEYED" ".guards[1].sites[0].key = \"$KEY~2\""
assert_fails_with "an occurrence-ordered key never selects a site" "$KEYED" S2
mutate "$KEYED" '.guards[1].sites[0].key = 1'
assert_fails_with "a non-string site key is invalid" "$KEYED" S2
mutate "$KEYED" ".guards[1].sites[0].key = \"$KEY\" | .guards[1].sites[0].within = 1"
assert_fails_with "a non-string block context is invalid" "$KEYED" S2
mutate "$KEYED" '.guards[1].sites[0].within = "$second"'
assert_mapped "the restored block contexts map both identical lines" "$KEYED" 2

# --- computed unregistered count ---------------------------------------------
TYPED=$(fixture typed_unregistered)
printf 'echo "REFUSED: an unmapped refusal" >&2\n' >"$TYPED/bin/gnew.sh"
mutate "$TYPED" '.unregistered_ids = []'
out=$(run_lint "$TYPED") && fail "a typed unregistered_ids list shorter than the computed count must fail: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S4 inventory' || fail "expected S4, got: $out"
pass "S4 fails a typed unregistered_ids list that disagrees with the scan"
mutate "$TYPED" '.unregistered_ids = ["site:bin/gnew.sh"]'
out=$(run_lint "$TYPED") && fail "the unmapped site itself must still fail: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S4 ' && fail "a typed list of the computed length must not fail S4: $out"
pass "a typed unregistered_ids list of the computed length raises no S4"
out=$(run_lint "$TYPED" --counts) && fail "the unmapped site must fail the counts run: $out"
printf '%s\n' "$out" | grep -q 'unregistered=1 ' || fail "counts must print the computed unregistered=1, got: $out"
pass "--counts prints the computed unregistered count"

# --- allowlist ratchet over sites --------------------------------------------
SEAL=$(fixture site_allowlist)
printf 'echo "REFUSED: a legacy refusal" >&2\n' >"$SEAL/bin/gnew.sh"
SITE_ID=$(site_ids "$SEAL")
[ -n "$SITE_ID" ] || fail "the legacy site produced no id"
printf '{"schema_version":2,"allowed":[{"id":"%s","rule":"S1"}]}\n' "$SITE_ID" >"$SEAL/docs/guards/lint-allowlist.json"
assert_mapped "an allowlisted legacy site passes enforce" "$SEAL" 0
printf '%s\n' "$(run_lint "$SEAL" --counts)" | grep -q 'unregistered=1 ' || fail "the allowlisted site must still count as unregistered"
pass "an allowlisted legacy site still counts as unregistered"
rm -f "$SEAL/bin/gnew.sh"
out=$(run_lint "$SEAL") && fail "deleting the site must make its allowlist entry stale: $out"
printf '%s\n' "$out" | grep -q "^STALE S1 $SITE_ID" || fail "expected STALE S1 $SITE_ID, got: $out"
pass "deleting a site makes its allowlist entry stale, so the burn-down list only shrinks"
printf 'echo "REFUSED: a legacy refusal" >&2\n' >"$SEAL/bin/gnew.sh"
printf 'echo "REFUSED: a legacy refusal" >&2\n' >>"$SEAL/bin/gnew.sh"
out=$(run_lint "$SEAL") && fail "a second identical site has its own id and must not ride the first entry: $out"
printf '%s\n' "$out" | grep -Eq "^VIOLATION S1 ${SITE_ID}~2:" || fail "expected the duplicate to fail as ${SITE_ID}~2, got: $out"
pass "a duplicate of an allowlisted line is a new site"

NATS=$(fixture site_touched)
mkdir -p "$NATS/bin"
printf 'legacy() {\n  echo "REFUSED: a legacy refusal" >&2\n  return 1\n}\n' >"$NATS/bin/gnew.sh"
NATS_ID=$(site_ids "$NATS")
printf '{"schema_version":2,"allowed":[{"id":"%s","rule":"S1"}]}\n' "$NATS_ID" >"$NATS/docs/guards/lint-allowlist.json"
git -C "$NATS" init -q
git -C "$NATS" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$NATS" -c user.email=t@example.invalid -c user.name=t commit -qm base
printf '# a comment above\nlegacy() {\n  echo "REFUSED: a legacy refusal" >&2\n  return 1\n}\n' >"$NATS/bin/gnew.sh"
"$LINT" --root "$NATS" --mode new-or-touched --base HEAD >/dev/null 2>&1 \
  || fail "a legacy site on an unchanged line must pass new-or-touched even when lines moved"
"$LINT" --root "$NATS" --mode new-or-touched --base HEAD --counts 2>&1 | grep -q ' sites=1 mapped=0$' \
  || fail "the legacy site must be discovered and unmapped while new-or-touched passes"
pass "new-or-touched ignores a legacy site on an unchanged line"
printf 'legacy() {\n    echo "REFUSED: a legacy refusal" >&2\n  return 1\n}\n' >"$NATS/bin/gnew.sh"
out=$("$LINT" --root "$NATS" --mode new-or-touched --base HEAD 2>&1) && fail "a touched legacy site that is still unmapped must fail: $out"
printf '%s\n' "$out" | grep -q "^VIOLATION S1 $NATS_ID" || fail "expected the touched legacy site to fail, got: $out"
pass "new-or-touched fails a touched legacy site that is still unmapped"
git -C "$NATS" config diff.noprefix true
out=$("$LINT" --root "$NATS" --mode new-or-touched --base HEAD 2>&1) && fail "diff.noprefix must not hide a touched legacy site: $out"
printf '%s\n' "$out" | grep -q "^VIOLATION S1 $NATS_ID" || fail "expected the touched legacy site to fail under diff.noprefix, got: $out"
git -C "$NATS" config --unset diff.noprefix
pass "new-or-touched fails a touched legacy site under diff.noprefix"
mutate "$NATS" '.guards[0].sites = [{"file":"bin/gnew.sh","match":"a legacy refusal"}]'
printf '{"schema_version":2,"allowed":[]}\n' >"$NATS/docs/guards/lint-allowlist.json"
"$LINT" --root "$NATS" --mode new-or-touched --base HEAD >/dev/null 2>&1 \
  || fail "a touched legacy site must pass once it maps and leaves the allowlist"
"$LINT" --root "$NATS" --mode new-or-touched --base HEAD --counts 2>&1 | grep -q ' mapped=1$' \
  || fail "the mapped touched site must count as mapped"
pass "new-or-touched passes a touched legacy site once it is mapped"

NEWSITE=$(fixture site_new)
git -C "$NEWSITE" init -q
git -C "$NEWSITE" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$NEWSITE" -c user.email=t@example.invalid -c user.name=t commit -qm base
printf 'echo "REFUSED: a brand new refusal" >&2\n' >"$NEWSITE/bin/gnew.sh"
out=$("$LINT" --root "$NEWSITE" --mode new-or-touched --base HEAD 2>&1) && fail "a new unmapped site must fail new-or-touched: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S1 site:bin/gnew.sh' || fail "expected S1 for the new site, got: $out"
pass "new-or-touched fails a new refusal site that maps to nothing"
mutate "$NEWSITE" '.guards[0].sites = [{"file":"bin/gnew.sh","match":"a brand new refusal"}]'
"$LINT" --root "$NEWSITE" --mode new-or-touched --base HEAD >/dev/null 2>&1 \
  || fail "a new site mapped with full spec fields must pass new-or-touched"
"$LINT" --root "$NEWSITE" --mode new-or-touched --base HEAD --counts 2>&1 | grep -q ' mapped=1$' \
  || fail "the mapped new site must count as mapped"
pass "new-or-touched passes a new refusal site once its guard entry maps it"

IGN=$(fixture site_ignored)
printf '.claude/worktrees/\n' >"$IGN/.gitignore"
git -C "$IGN" init -q
git -C "$IGN" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$IGN" -c user.email=t@example.invalid -c user.name=t commit -qm base
mkdir -p "$IGN/.claude/worktrees/w1/bin"
printf 'echo "REFUSED: a copy in an ignored worktree" >&2\n' >"$IGN/.claude/worktrees/w1/bin/a.sh"
printf 'echo "REFUSED: an untracked new refusal" >&2\n' >"$IGN/bin/gnew.sh"
IGN_IDS=$(site_ids "$IGN")
printf '%s\n' "$IGN_IDS" | grep -q '^site:bin/gnew.sh:' || fail "an untracked file that git does not ignore must still be a site: $IGN_IDS"
printf '%s\n' "$IGN_IDS" | grep -q '\.claude/worktrees/' && fail "a file under a git-ignored directory must not be a site: $IGN_IDS"
pass "a git-ignored file is not a site while an untracked new file still is"

ABSORB=$(fixture site_absorbed)
printf 'echo "REFUSED: lease gone" >&2\n' >"$ABSORB/bin/gguard.sh"
mutate "$ABSORB" '.guards[0].sites = [{"file":"bin/gguard.sh","match":"REFUSED: lease"}]'
git -C "$ABSORB" init -q
git -C "$ABSORB" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$ABSORB" -c user.email=t@example.invalid -c user.name=t commit -qm base
printf 'echo "REFUSED: lease stolen by another task" >&2\n' >>"$ABSORB/bin/gguard.sh"
out=$("$LINT" --root "$ABSORB" --mode new-or-touched --base HEAD 2>&1) && fail "a new site an existing marker absorbs must fail new-or-touched: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S2 gguard' || fail "expected S2 for the absorbing marker, got: $out"
pass "new-or-touched fails a new site that an existing marker absorbs"

GROW=$(fixture site_growth)
printf 'echo "REFUSED: legacy one" >&2\n' >"$GROW/bin/gold.sh"
GROW_ID=$(site_ids "$GROW")
printf '{"schema_version":2,"allowed":[{"id":"%s","rule":"S1"}]}\n' "$GROW_ID" >"$GROW/docs/guards/lint-allowlist.json"
git -C "$GROW" init -q
git -C "$GROW" -c user.email=t@example.invalid -c user.name=t add -A
git -C "$GROW" -c user.email=t@example.invalid -c user.name=t commit -qm base
printf 'echo "REFUSED: new debt" >&2\n' >"$GROW/bin/gnew.sh"
GROW_NEW=$(site_ids "$GROW" | grep gnew)
printf '{"schema_version":2,"allowed":[{"id":"%s","rule":"S1"},{"id":"%s","rule":"S1"}]}\n' "$GROW_ID" "$GROW_NEW" >"$GROW/docs/guards/lint-allowlist.json"
out=$("$LINT" --root "$GROW" --mode new-or-touched --base HEAD 2>&1) && fail "an allowlist that grew must fail new-or-touched: $out"
printf '%s\n' "$out" | grep -q "^VIOLATION S5 $GROW_NEW" || fail "expected S5 for the added entry, got: $out"
pass "S5 fails an allowlist that grew against the base"
printf '{"schema_version":1,"allowed":[]}\n' >"$GROW/docs/guards/lint-allowlist.json"
out=$("$LINT" --root "$GROW" --mode new-or-touched --base HEAD 2>&1) && fail "dropping the schema must not unseal the allowlist: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S5 allowlist' || fail "expected S5 for the schema drop, got: $out"
pass "S5 fails an allowlist that drops back below the sealed schema"

printf 'ok - fm-guard-lint\n'
