#!/usr/bin/env bash
# Policy enforcement at the host's preactivation boundary and direct engine API.
# Never starts a model or an active host loop: the CLI must refuse before activation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-engine-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-session-launch-policy)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/primary"
PREDECESSOR=
cleanup() {
  [ -z "$PREDECESSOR" ] || kill -TERM "$PREDECESSOR" 2>/dev/null || true
  [ -z "$PREDECESSOR" ] || wait "$PREDECESSOR" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
export FM_HOME="$TMP_ROOT/home" STATE="$TMP_ROOT/home/state" FM_ROOT="$ROOT"
unset FM_CONFIG_OVERRIDE
printf 'claude sonnet\n' > "$FM_HOME/config/supervision-host"
printf 'omp-or-tc\n' > "$FM_HOME/config/session-launch-policy"
printf 'prompt fixture\n' > "$TMP_ROOT/prompt"
printf 'message fixture\n' > "$TMP_ROOT/message"
cat > "$TMP_ROOT/engine" <<'SH'
#!/usr/bin/env bash
printf 'engine invoked\n' >> "$FM_HOME/engine-effects"
printf '{"type":"result","subtype":"success","is_error":false}\n'
SH
chmod +x "$TMP_ROOT/engine"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$TMP_ROOT/engine"
printf 'previous engine custody\n' > "$TMP_ROOT/engine-pid"
printf 'previous engine result\n' > "$TMP_ROOT/result"
rc=0
fm_supervision_engine_turn claude sonnet "$TMP_ROOT/prompt" "$TMP_ROOT/message" fixture resume 5 "$TMP_ROOT/result" "$TMP_ROOT/errors" "$TMP_ROOT/engine-pid" || rc=$?
[ "$rc" -ne 0 ] || fail 'restricted direct engine API invoked Claude'
assert_contains "$(cat "$TMP_ROOT/errors")" 'session-launch-policy' 'direct engine refusal identifies policy'
[ ! -e "$FM_HOME/engine-effects" ] || fail 'restricted engine executable was invoked'
[ "$(cat "$TMP_ROOT/engine-pid")" = 'previous engine custody' ] || fail 'restricted engine replaced process custody'
[ "$(cat "$TMP_ROOT/result")" = 'previous engine result' ] || fail 'restricted engine replaced prior result'
pass "direct resumed engine refusal exit=$rc invocations=0 process-custody=unchanged result=unchanged"

# The previous host is represented by an owned disposable sleeping process.
# The new host runs under a Bash symlink with omp's structural process identity.
/bin/sleep 120 &
PREDECESSOR=$!
identity=$(_fm_engine_identity "$PREDECESSOR")
printf 'host\t%s\t%s\n' "$PREDECESSOR" "$identity" > "$STATE/.supervision-host"
printf 'previous turn custody\n' > "$STATE/.supervision-host-turn"
printf 'previous engine conversation\n' > "$STATE/.supervision-host-engine"
cp "$STATE/.supervision-host" "$TMP_ROOT/prior-host"
ln -s /bin/bash "$TMP_ROOT/primary/omp"
# shellcheck disable=SC2016 # The fixture primary shell owns the lock and CLI call.
out=$(FM_SUPERVISION_HOST_PRIMARY=omp "$TMP_ROOT/primary/omp" -c '
  printf "%s\n" "$$" > "$STATE/.lock"
  "$1/bin/fm-supervision-host.sh" park --restart
  rc=$?
  exit "$rc"
' _ "$ROOT" 2>&1) || fail "restricted host CLI failed unexpectedly: $out"
assert_contains "$out" 'session-launch-policy' 'host refuses policy before activating'
kill -0 "$PREDECESSOR" 2>/dev/null || fail 'restricted host stopped predecessor'
cmp -s "$TMP_ROOT/prior-host" "$STATE/.supervision-host" || fail 'restricted host replaced predecessor record'
[ "$(cat "$STATE/.supervision-host-turn")" = 'previous turn custody' ] || fail 'restricted host retired previous turn'
[ "$(cat "$STATE/.supervision-host-engine")" = 'previous engine conversation' ] || fail 'restricted host retired engine custody'
[ ! -e "$FM_HOME/engine-effects" ] || fail 'host invoked engine'
[ ! -e "$STATE/.watch.lock" ] || fail 'restricted host started monitoring'
pass 'omp-primary host refusal invocations=0 predecessor=alive host-record=identical turn-custody=unchanged'

fm_supervision_host_config "$FM_HOME/config" omp || fail 'configured host unexpectedly disabled'
[ -z "$FM_SUPERVISION_ENGINE" ] || fail 'restricted engine remained available to attended routing'
assert_contains "$FM_SUPERVISION_ENGINE_PROBLEM" 'session-launch-policy' 'configured engine reports policy refusal'
pass 'configured supervision engine remains unavailable under launch restriction'

rm "$FM_HOME/config/session-launch-policy"
fm_supervision_host_config "$FM_HOME/config" omp || fail 'absent policy changed host opt-in'
[ "$FM_SUPERVISION_ENGINE" = claude ] || fail 'absent policy changed explicit engine selection'
rm "$TMP_ROOT/engine-pid"
fm_supervision_engine_turn claude sonnet "$TMP_ROOT/prompt" "$TMP_ROOT/message" fixture new 5 "$TMP_ROOT/result" "$TMP_ROOT/errors" "$TMP_ROOT/engine-pid" || fail 'absent policy changed engine invocation'
[ "$(cat "$FM_HOME/engine-effects")" = 'engine invoked' ] || fail 'absent policy never invoked engine fixture'
pass 'absent policy preserves configured Claude engine and direct turn (fixture executable only)'
