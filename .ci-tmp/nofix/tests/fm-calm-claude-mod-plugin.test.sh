#!/usr/bin/env bash
# The Claude Code Calm mod (.claude/mods/firstmate-calm) under the real installed
# Claude Code: `claude plugin validate --strict` on the physical folder and on the
# `.claude/skills/firstmate-calm` path the project auto-loads it from, then its own
# `claude plugin test` suites (tests/*.test.ts inside the mod), which run the hooks
# module in the engine's own host against a mocked clock, environment, file system,
# and drawing surface. No model turn is submitted and no credential is spent, so the
# guard runs by default wherever `claude` is installed; the portable checks that need
# no Claude Code binary live in tests/fm-calm-claude-mod.test.sh.
#
# The early-access function-hooks surface is default-off; the flag is set on this
# test's own processes only and never written into any settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_CALM_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/firstmate-calm"
AUTOLOAD_PATH="$ROOT/.claude/skills/firstmate-calm"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-calm-claude-mod-plugin)

test_validate_strict() {
  local path report
  for path in "$MOD" "$AUTOLOAD_PATH"; do
    if ! report=$(CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate --strict "$path" 2>&1); then
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION refused the Calm mod at $path under strict validation"
    fi
  done
  pass "Claude Code $CLAUDE_VERSION validates the Calm mod strictly at its folder and its auto-load path"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the Calm mod's plugin test suites"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no Calm mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported Calm mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the Calm mod's plugin test suites clean: persisted toggle, hidden rows, working notes, the clock-driven working ship, and supervision notes"
}

test_validate_strict
test_plugin_suites
