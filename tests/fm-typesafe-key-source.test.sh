#!/usr/bin/env bash
# One TypeSafe key source: a secondmate-shaped home with no .env resolves
# TYPESAFE_API_KEY from the primary home through the existing parent record.
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-typesafe-key-source)

PRIMARY="$TMP_ROOT/primary"
LANE="$TMP_ROOT/lane"
CREW_HOME="$TMP_ROOT/lane-child"
REMOTE="$TMP_ROOT/remote"
mkdir -p "$PRIMARY" "$LANE" "$CREW_HOME" "$REMOTE"

link_home() {  # <home> <parent>
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.fm-secondmate-parent"
}
link_home "$LANE" "$PRIMARY"
link_home "$CREW_HOME" "$LANE"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=synthetic\n' > "$REMOTE/.fm-secondmate-parent"
printf 'TYPESAFE_API_KEY=primary-key\n' > "$PRIMARY/.env"

# resolve <home> [env-key]: prints the resolved key, or "absent".
resolve_key() {
  env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE ${2:+TYPESAFE_API_KEY=$2} bash -c '
    . "$1/bin/fm-typesafe-lib.sh"
    if fm_typesafe_key "$2"; then printf %s "$TYPESAFE_API_KEY_PRIVATE"; else printf absent; fi
    [ -z "${TYPESAFE_API_KEY+x}" ] || printf " LEAK"
  ' _ "$ROOT" "$1"
}

[ "$(resolve_key "$PRIMARY")" = primary-key ] || fail "primary home did not resolve its own key"
[ "$(resolve_key "$LANE")" = primary-key ] || fail "secondmate home without .env did not resolve the primary key"
[ "$(resolve_key "$CREW_HOME")" = primary-key ] || fail "nested home without .env did not resolve the top-most key"
pass "a home without .env resolves the key from the primary home"

printf 'TYPESAFE_API_KEY=lane-key\n' > "$LANE/.env"
[ "$(resolve_key "$LANE")" = lane-key ] || fail "own .env did not win over the primary .env"
[ "$(resolve_key "$LANE" env-key)" = env-key ] || fail "process environment did not win over .env"
rm -f "$LANE/.env"
[ "$(resolve_key "$CREW_HOME" env-key)" = env-key ] || fail "process environment did not win over the primary .env"
pass "precedence is environment, then own .env, then primary .env"

[ "$(resolve_key "$REMOTE")" = absent ] || fail "a remote-bound home must not reach a primary .env"
rm -f "$PRIMARY/.env"
[ "$(resolve_key "$LANE")" = absent ] || fail "absent everywhere must stay off"
printf 'TYPESAFE_API_KEY=primary-key\n' > "$PRIMARY/.env"
printf 'schema=fm-secondmate-parent.v1\nroute=local\n' > "$CREW_HOME/.fm-secondmate-parent"
[ "$(resolve_key "$CREW_HOME")" = absent ] || fail "a malformed parent record must not resolve a key"
link_home "$CREW_HOME" "$LANE"
pass "remote, malformed and absent bindings stay off"

# The guardrail hook is a separate process; it must reach the primary key too.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'JS'
#!/usr/bin/env node
const fs = require('node:fs');
if (process.env.TYPESAFE_API_KEY || process.env.TYPESAFE_API_KEY_PRIVATE) process.exit(9);
fs.appendFileSync(process.env.FM_TEST_TRANSPORT, fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify({ model: 'jev-1.13.0', usage: { input_tokens: 100, output_tokens: 1 }, answers: { risk: { type: 'choice', choice: 'risky', confidence: 0.9, probabilities: { risky: 0.9, routine: 0.05, uncertain: 0.05 } } } }) + '\n200');
JS
chmod +x "$FAKEBIN/curl"

hook_status() {  # <home>
  local home=$1
  mkdir -p "$home/state" "$home/config"
  : > "$TMP_ROOT/transport"
  printf '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./sandbox"}}' \
    | env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE FM_HOME="$home" FM_ROOT_OVERRIDE='' \
        FM_CONFIG_OVERRIDE='' FM_STATE_OVERRIDE='' FM_TEST_TRANSPORT="$TMP_ROOT/transport" PATH="$FAKEBIN:$PATH" \
        node "$ROOT/bin/fm-jev-guardrail.mjs" hook --host claude >/dev/null 2>&1
  tail -n1 "$home/state/jev-guardrail.jsonl" | jq -r .status
}

[ "$(hook_status "$LANE")" = judged ] || fail "guardrail in a home without .env must reach the primary key"
grep -q 'Bearer primary-key' "$TMP_ROOT/transport" || fail "guardrail did not send the primary key"
[ "$(hook_status "$REMOTE")" = missing_key ] || fail "guardrail in a remote-bound home must stay off"
pass "the Jev guardrail resolves the primary key and stays off without one"
