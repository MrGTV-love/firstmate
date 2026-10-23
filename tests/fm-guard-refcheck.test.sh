#!/usr/bin/env bash
# Contract tests for bin/fm-guard-refcheck.sh - the wiring, registry, and
# retirement reference check.
#
# The audit's Stage 0 claim is that "scan carefully" must become a pass/fail
# machine, because a ritual someone remembers is the same class of guard being
# removed. These cases prove the machine actually fails on each defect it claims
# to catch, using throwaway git repositories so the repository's own wiring can
# never change a fixture's verdict.
#
# Proven here:
#   - a registration naming an existing script is clean
#   - a registration naming a missing script fails, and names both the path and
#     the registration file
#   - a JSON filename is not mistaken for a JavaScript script path
#   - a registry owner or test path that does not resolve fails
#   - a retired guard referenced from tracked code fails
#   - a retired guard named only by its changelog and its own retirement test
#     stays clean, which is the only legal place the id may appear
#   - a missing registry is clean (the lint owns that defect, not this check)
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFCHECK="$ROOT/bin/fm-guard-refcheck.sh"
TMP=$(fm_test_tmproot fm-guard-refcheck)
trap 'fm_test_cleanup' EXIT
GIT="git -C"

# fixture <name> -> echoes a fresh git repo with one wired .claude/settings.json,
# an existing bin script, and an empty retirement changelog.
fixture() {
  local dir="$TMP/$1"
  mkdir -p "$dir/bin" "$dir/tests" "$dir/docs/guards" "$dir/.claude"
  : >"$dir/bin/wired.sh"
  : >"$dir/tests/gguard.test.sh"
  cat >"$dir/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exec \"$CLAUDE_PROJECT_DIR\"/bin/wired.sh"}]}]}}
JSON
  cat >"$dir/docs/guards/registry.json" <<'JSON'
{"schema_version":1,"system":"firstmate","audited":1,"excluded":[],
 "guards":[{"id":"gguard","owner":"bin/wired.sh","invariant":"a fixture invariant",
   "layer":"runtime-block","source":"a fixture source","trigger":"a fixture trigger",
   "decision":"deny","fail_direction":"closed","remedy":"bin/wired.sh --clear <id>",
   "budget":1,"telemetry":"state/guard-events.jsonl","test":"tests/gguard.test.sh",
   "tier":"C","harm":"reversible","exemptions":[]}]}
JSON
  printf '[]\n' >"$dir/docs/guards/retired.json"
  $GIT "$dir" init -q
  $GIT "$dir" -c user.email=t@example.invalid -c user.name=t add -A
  $GIT "$dir" -c user.email=t@example.invalid -c user.name=t commit -qm base
  printf '%s\n' "$dir"
}

run_refcheck() {  # <root>
  "$REFCHECK" --root "$1" 2>&1
}

assert_clean() {  # <label> <root>
  local label=$1 dir=$2 out
  out=$(run_refcheck "$dir") || fail "$label: expected clean exit, got: $out"
  pass "$label"
}

assert_fails_with() {  # <label> <root> <needle>
  local label=$1 dir=$2 needle=$3 out
  out=$(run_refcheck "$dir") && fail "$label: expected failure"
  printf '%s\n' "$out" | grep -qF -- "$needle" \
    || fail "$label: expected '$needle', got: $out"
  pass "$label"
}

# --- clean wiring -----------------------------------------------------------
CLEAN=$(fixture clean)
assert_clean "a registration naming an existing script is clean" "$CLEAN"

# --- dead wiring ------------------------------------------------------------
DEAD=$(fixture dead)
rm -f "$DEAD/bin/wired.sh"
assert_fails_with "a registration naming a missing script fails" "$DEAD" "MISSING bin/wired.sh registration=.claude/settings.json"

# --- extension boundary -----------------------------------------------------
# A settings file that *mentions* a json file must not be read as a js script.
BOUNDARY=$(fixture boundary)
cat >"$BOUNDARY/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"test -f \"$CLAUDE_PROJECT_DIR\"/.claude/settings.json"}]}]}}
JSON
$GIT "$BOUNDARY" add -A
$GIT "$BOUNDARY" -c user.email=t@example.invalid -c user.name=t commit -qm boundary
out=$(run_refcheck "$BOUNDARY") || fail "a json filename must not be read as a script: $out"
printf '%s\n' "$out" | grep -q 'missing=0' || fail "expected missing=0, got: $out"
pass "a json filename is not mistaken for a script path"

# --- registry wiring --------------------------------------------------------
REGOWNER=$(fixture regowner)
rm -f "$REGOWNER/bin/wired.sh"
out=$(run_refcheck "$REGOWNER") && fail "a missing registry owner must fail"
printf '%s\n' "$out" | grep -q 'registration=registry:gguard' \
  || fail "expected a registry-sourced MISSING line, got: $out"
pass "a missing registry owner path fails"

REGTEST=$(fixture regtest)
rm -f "$REGTEST/tests/gguard.test.sh"
assert_fails_with "a missing registry test path fails" "$REGTEST" "registration=registry:gguard"

# --- retirement -------------------------------------------------------------
RESURRECT=$(fixture resurrect)
cat >"$RESURRECT/docs/guards/retired.json" <<'JSON'
[{"id":"gone-guard","system":"firstmate","invariant":"a retired invariant","retired":"2026-10-22",
  "why":"it protected a reversible action","replaced_by":"nothing","retirement_test":"tests/gguard.test.sh"}]
JSON
mkdir -p "$RESURRECT/bin"
printf '#!/usr/bin/env bash\n# re-adds gone-guard by accident\n' >"$RESURRECT/bin/regrown.sh"
$GIT "$RESURRECT" add -A
$GIT "$RESURRECT" -c user.email=t@example.invalid -c user.name=t commit -qm resurrect
assert_fails_with "a retired guard referenced from tracked code fails" "$RESURRECT" "RESURRECTED gone-guard bin/regrown.sh:2"

# The changelog and the guard's own retirement test are the two legal homes.
LEGAL=$(fixture legal)
cat >"$LEGAL/docs/guards/retired.json" <<'JSON'
[{"id":"gone-guard","system":"firstmate","invariant":"a retired invariant","retired":"2026-10-22",
  "why":"it protected a reversible action","replaced_by":"nothing","retirement_test":"tests/gguard.test.sh"}]
JSON
printf '#!/usr/bin/env bash\n# proves the previously blocked action now passes: gone-guard retired\n' >"$LEGAL/tests/gguard.test.sh"
$GIT "$LEGAL" add -A
$GIT "$LEGAL" -c user.email=t@example.invalid -c user.name=t commit -qm legal
assert_clean "a retired id named only by its changelog and retirement test stays clean" "$LEGAL"

# --- no registry ------------------------------------------------------------
NOREG=$(fixture noreg)
rm -rf "$NOREG/docs/guards"
assert_clean "a missing registry is left to the lint" "$NOREG"

printf 'ok - fm-guard-refcheck\n'
