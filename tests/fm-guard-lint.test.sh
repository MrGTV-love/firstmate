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
#   - an unquoted refusal in a stderr heredoc and a refusal under .dsh/ are sites, while a variable,
#     a path, a compared value and an argument-count exit 2 are not
#   - an unmapped site fails S1, the same site mapped by a sites marker passes, and a site added
#     inside an already-mapped owner file still needs its own mapping
#   - a marker that matches nothing, the wrong number of sites, or a site another entry owns fails
#     S2, and a multi-site entry with no group_reason fails S3
#   - a typed unregistered count that differs from the computed one fails S4
#   - an allowlisted site passes, deleting the site makes its entry stale, a touched site fails
#     in new-or-touched mode even when allowlisted, and the sealed allowlist cannot grow (S5)
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

SIG=$(fixture sig_oneline_event)
# shellcheck disable=SC2016 # fixture text is literal shell source and must not expand
printf 'probe() { "$DIR/fm-guard-event.sh" some-guard deny --source-ok true; }\n' >"$SIG/bin/a.sh"
assert_site "S1 finds a guard event deny inside a one-line function definition" "$SIG" 'E'

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
out=$(run_lint "$COUNT") && fail "a multi-site entry with no group_reason must fail: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S3 gguard' || fail "expected S3 for the multi-site entry, got: $out"
pass "S3 fails an entry that maps several sites without a group_reason"
mutate "$COUNT" '.guards[0].group_reason = "both lines refuse the same fixture request"'
assert_mapped "a group entry with a counted marker and a group_reason passes" "$COUNT" 2

TWICE=$(fixture site_twice)
printf 'echo "REFUSED: contested refusal" >&2\n' >"$TWICE/bin/gnew.sh"
mutate "$TWICE" '.guards[0].sites = [{"file":"bin/gnew.sh","match":"contested refusal"}]
  | .guards += [(.guards[0] | .id = "gother" | .invariant = "another invariant" | .owner = "bin/gother.sh" | .test = "tests/gother.test.sh")]'
: >"$TWICE/bin/gother.sh"; : >"$TWICE/tests/gother.test.sh"
assert_fails_with "S2 fails a site that two entries map" "$TWICE" S2

# --- computed unregistered count ---------------------------------------------
TYPED=$(fixture typed_unregistered)
printf 'echo "REFUSED: an unmapped refusal" >&2\n' >"$TYPED/bin/gnew.sh"
mutate "$TYPED" '.unregistered = 0'
out=$(run_lint "$TYPED") && fail "a typed unregistered count below the computed one must fail: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S4 inventory' || fail "expected S4, got: $out"
pass "S4 fails a typed unregistered count that disagrees with the scan"
mutate "$TYPED" '.unregistered = 1'
out=$(run_lint "$TYPED") && fail "the unmapped site itself must still fail: $out"
printf '%s\n' "$out" | grep -q '^VIOLATION S4 ' && fail "a typed count equal to the computed one must not fail S4: $out"
pass "a typed unregistered count equal to the scan raises no S4"
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
