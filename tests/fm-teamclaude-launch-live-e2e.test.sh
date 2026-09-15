#!/usr/bin/env bash
# Live drift guard for bin/fm-teamclaude-launch.sh against the installed
# TeamClaude CLI: `teamclaude status` must answer and `teamclaude env` must
# export the routing the launcher hands claude. It starts no Claude session and
# spends no model tokens: a recording claude stands in for the real one, so the
# guard runs by default wherever TeamClaude is installed and its proxy runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_TEAMCLAUDE_LAUNCH_LIVE

# The launcher's own lookup order: PATH, then exactly one nvm installation.
requested() {
  [ "${FM_TEAMCLAUDE_LAUNCH_LIVE:-}" = 1 ] || { [ "${FM_TEAMCLAUDE_LAUNCH_LIVE:-}" != 0 ] && [ "${FM_LIVE:-}" = 1 ]; }
}
skip_or_fail() {  # <reason>
  if requested; then
    printf 'not ok - FM_TEAMCLAUDE_LAUNCH_LIVE was requested but %s\n' "$1" >&2
    exit 1
  fi
  printf 'skip: live: %s\n' "$1"
  exit 0
}
TC_BIN=$(type -P teamclaude 2>/dev/null || true)
if [ -z "$TC_BIN" ]; then
  set -- "$HOME"/.nvm/versions/node/*/bin/teamclaude
  [ "$#" -eq 1 ] && [ -x "$1" ] && TC_BIN=$1
fi
[ -n "$TC_BIN" ] || skip_or_fail 'teamclaude absent'
TC_VERSION=$(PATH="$(dirname "$TC_BIN"):$PATH" "$TC_BIN" --version 2>/dev/null | head -1)
PATH="$(dirname "$TC_BIN"):$PATH" "$TC_BIN" status >/dev/null 2>&1 \
  || skip_or_fail "the TeamClaude proxy is not running (teamclaude $TC_VERSION)"

LAB=$(fm_test_tmproot fm-teamclaude-launch-live) || fail "could not create the guard lab"
mkdir -p "$LAB/fakebin"
cat > "$LAB/fakebin/claude" <<'SH'
#!/usr/bin/env bash
env > "$FM_GUARD_CLAUDE_ENV"
SH
chmod +x "$LAB/fakebin/claude"

# A clean environment: nothing but the home and a PATH whose claude records.
out=$(env -i HOME="$HOME" PATH="$LAB/fakebin:$(dirname "$(command -v bash)"):/usr/bin:/bin" \
  FM_GUARD_CLAUDE_ENV="$LAB/claude-env" \
  "$ROOT/bin/fm-teamclaude-launch.sh" --version 2>&1) \
  || fail "teamclaude $TC_VERSION: the launcher refused against a running proxy: $out"
[ -s "$LAB/claude-env" ] || fail "teamclaude $TC_VERSION: the launcher never started claude"

proxy=$(sed -n 's/^HTTPS_PROXY=//p' "$LAB/claude-env" | head -1)
base=$(sed -n 's/^ANTHROPIC_BASE_URL=//p' "$LAB/claude-env" | head -1)
if [ -n "$proxy" ]; then
  ca=$(sed -n 's/^NODE_EXTRA_CA_CERTS=//p' "$LAB/claude-env" | head -1)
  [ -n "$ca" ] && [ -r "$ca" ] \
    || fail "teamclaude $TC_VERSION: forward-proxy mode exported no readable NODE_EXTRA_CA_CERTS"
  pass "teamclaude $TC_VERSION: the launcher hands claude HTTPS_PROXY and a readable TeamClaude CA"
elif [ -n "$base" ]; then
  pass "teamclaude $TC_VERSION: the launcher hands claude TeamClaude's ANTHROPIC_BASE_URL"
else
  fail "teamclaude $TC_VERSION: claude received neither HTTPS_PROXY nor ANTHROPIC_BASE_URL"
fi
