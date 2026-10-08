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
  # shellcheck disable=SC2016 # the child shell script is intentionally single-quoted.
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

# resolve_openrouter <home> [env-key]: prints the resolved fallback key, or "absent".
resolve_openrouter() {
  # shellcheck disable=SC2016 # the child shell script is intentionally single-quoted.
  env -u OPENROUTER_API_KEY ${2:+OPENROUTER_API_KEY=$2} bash -c '
    . "$1/bin/fm-typesafe-lib.sh"
    if fm_openrouter_key "$2"; then printf %s "$OPENROUTER_API_KEY_PRIVATE"; else printf absent; fi
  ' _ "$ROOT" "$1"
}

printf 'TYPESAFE_API_KEY=primary-key\nOPENROUTER_API_KEY=primary-or\n' > "$PRIMARY/.env"
[ "$(resolve_openrouter "$CREW_HOME")" = primary-or ] || fail "nested home without .env did not resolve the primary OpenRouter key"
printf 'OPENROUTER_API_KEY=lane-or\n' > "$LANE/.env"
[ "$(resolve_openrouter "$LANE")" = lane-or ] || fail "own .env did not win for the OpenRouter key"
rm -f "$LANE/.env"
[ "$(resolve_openrouter "$REMOTE" env-or)" = absent ] || fail "the OpenRouter key must not come from the process environment or a remote binding"
printf 'TYPESAFE_API_KEY=primary-key\n' > "$PRIMARY/.env"
pass "the OpenRouter fallback key resolves from own, then primary .env, never the environment"

# The jev-guard hook is a separate process; it must reach the primary key too.
cat > "$TMP_ROOT/fake-jev.mjs" <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
const server = createServer((req, res) => {
  let body = '';
  req.on('data', chunk => { body += chunk; });
  req.on('end', () => {
    appendFileSync(log, `${req.headers.authorization}\n`);
    const answers = {};
    for (const [id, q] of Object.entries(JSON.parse(body).questions)) {
      const keys = Object.keys(q.criteria ?? {});
      const pick = keys.includes('irreversible') ? 'irreversible' : keys[0];
      answers[id] = q.type === 'noul' ? { type: 'noul', noul: 0.05 }
        : { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])) };
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1 } }));
  });
});
server.listen(0, '127.0.0.1', () => writeFileSync(portFile, String(server.address().port)));
JS
: > "$TMP_ROOT/transport"
node "$TMP_ROOT/fake-jev.mjs" "$TMP_ROOT/transport" "$TMP_ROOT/jev-port" &
FAKE_JEV_PID=$!
trap 'kill "$FAKE_JEV_PID" 2>/dev/null; fm_test_cleanup' EXIT
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/jev-port" ] && break; sleep 0.05; done
[ -s "$TMP_ROOT/jev-port" ] || fail "fake Jev endpoint did not start"

guard_decision() {
  local home=$1 out err="$TMP_ROOT/hook.err" status
  mkdir -p "$home/state" "$home/config" "$home/data/t1" "$TMP_ROOT/wt"
  : > "$TMP_ROOT/transport"
  out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf ./sandbox"}}' \
    | env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE -u OPENROUTER_API_KEY FM_TEST_SEAM=1 \
        FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$TMP_ROOT/jev-port")/v1/systemone" \
        "$ROOT/bin/fm-jev-guard-hook.sh" "$home" "$home/config" "$home/state" t1 "$TMP_ROOT/wt" "$home/data/t1" firstmate 2>"$err")
  status=$?
  [ "$status" -eq 0 ] || fail "hook exited $status for $home"
  [ ! -s "$err" ] || fail "hook wrote stderr for $home: $(cat "$err")"
  if [ -z "$out" ]; then
    decision=allow
  else
    decision=$(jq -er .hookSpecificOutput.permissionDecision <<<"$out") || fail "hook returned no permission decision for $home"
  fi
}

guard_decision "$LANE"
[ "$decision" = deny ] || fail "jev-guard in a home without .env must reach the primary key"
grep -qx 'Bearer primary-key' "$TMP_ROOT/transport" || fail "jev-guard did not send the primary key"
guard_decision "$REMOTE"
[ "$decision" = allow ] || fail "jev-guard in a remote-bound home must stay off"
[ ! -s "$TMP_ROOT/transport" ] || fail "jev-guard in a remote-bound home must make no request"
kill "$FAKE_JEV_PID" 2>/dev/null
wait "$FAKE_JEV_PID" 2>/dev/null
pass "the jev-guard resolves the primary key and stays off without one"

# The jev-belay Stop-hook wrapper delivers the key to one process only.
BELAY_ROOT="$PRIMARY/data/vendor/jev-belay"
mkdir -p "$BELAY_ROOT"
cat > "$BELAY_ROOT/belay.mjs" <<'JS'
import { readFileSync, writeFileSync } from 'node:fs';
const stdin = readFileSync(0, 'utf8');
const seen = {
  key: process.env.TYPESAFE_API_KEY ?? null,
  privateKey: process.env.TYPESAFE_API_KEY_PRIVATE ?? null,
  base: process.env.JEV_BASE_URL ?? null,
  model: process.env.JEV_MODEL ?? null,
  alt: process.env.JEV_API_KEY ?? null,
  option: process.env.CLAUDE_PLUGIN_OPTION_TYPESAFE_API_KEY ?? null,
  argvHasKey: process.argv.some(arg => /primary-key|public-key|private-key/.test(arg)),
  stdin,
};
writeFileSync(process.env.FM_TEST_BELAY_SEEN, JSON.stringify(seen));
const request = process.env.FM_TEST_BELAY_REQUEST
  ? JSON.parse(process.env.FM_TEST_BELAY_REQUEST)
  : { model: 'jev-1.13.0', state: { task: 'ordinary task', final_message: 'ordinary result', run: { file_changes: 1, checks_run: ['ordinary check'] } }, questions: {} };
for (let attempt = 0; attempt < 2; attempt++) {
  try {
    const body = attempt === 1 && process.env.FM_TEST_BELAY_RETRY_REQUEST
      ? JSON.parse(process.env.FM_TEST_BELAY_RETRY_REQUEST) : request;
    const response = await fetch('https://api.typesafe.ai/v1/systemone', {
      method: 'POST',
      headers: { Authorization: `Bearer ${seen.key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    await response.json();
  } catch (error) {
    console.error(JSON.stringify({ event: 'fetch-error', attempt, name: error.name, message: error.message }));
    // Like upstream belay, withholding fails open, but never hide its cause.
    process.exit(0);
  }
}
process.exit(Number(process.env.FM_TEST_BELAY_EXIT || 0));
JS
SEEN="$TMP_ROOT/belay-seen.json"
REQUESTS="$TMP_ROOT/belay-requests.jsonl"
LEAKS="$TMP_ROOT/belay-leaks"
COMMANDS="$TMP_ROOT/belay-commands"
TRANSPORT_MODULE="$TMP_ROOT/belay-transport.mjs"
DIAGNOSTICS="$TMP_ROOT/belay-diagnostics.jsonl"
trap 'if [ "$?" -ne 0 ] && [ -f "$DIAGNOSTICS" ]; then cat "$DIAGNOSTICS" "$COMMANDS" >&2; fi; fm_test_cleanup' EXIT
cat > "$TRANSPORT_MODULE" <<'JS'
import { appendFileSync } from 'node:fs';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
const spawnSync = childProcess.spawnSync;
childProcess.spawnSync = (...args) => {
  const env = args[2]?.env ?? process.env;
  if ('TYPESAFE_API_KEY' in env || 'TYPESAFE_API_KEY_PRIVATE' in env) {
    appendFileSync(process.env.FM_TEST_BELAY_LEAKS, 'policy-child\n');
  }
  // Wrapper commands remain instrumented, but the already-observed credential-
  // free policy child uses real utilities without per-command Bash shims.
  args[2] = { ...args[2], env: { ...env, PATH: process.env.FM_TEST_BELAY_POLICY_PATH } };
  const started = performance.now();
  const result = spawnSync(...args);
  appendFileSync(process.env.FM_TEST_BELAY_DIAGNOSTICS, JSON.stringify({
    event: 'policy-child', elapsedMs: Math.round(performance.now() - started),
    status: result.status, signal: result.signal, error: result.error?.code ?? null,
  }) + '\n');
  return result;
};
syncBuiltinESMExports();
globalThis.fetch = async (url, init) => {
  appendFileSync(process.env.FM_TEST_BELAY_REQUESTS, JSON.stringify({
    url: String(url), body: JSON.parse(init.body), authorization: init.headers.Authorization,
  }) + '\n');
  appendFileSync(process.env.FM_TEST_BELAY_DIAGNOSTICS, '{"event":"transport"}\n');
  return { ok: true, status: 200, json: async () => ({ allowed: true }) };
};
JS
SHIMBIN="$TMP_ROOT/belay-shims"
mkdir -p "$SHIMBIN"
# The policy child is observed at spawn; only preflight commands need shims.
for command in dirname git; do
  real_command=$(command -v "$command") || fail "missing fixture command: $command"
  # shellcheck disable=SC2016 # Variables expand when the generated shim runs.
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "$FM_TEST_BELAY_COMMANDS"\nif [ "${TYPESAFE_API_KEY+x}" = x ] || [ "${TYPESAFE_API_KEY_PRIVATE+x}" = x ]; then printf "%%s\\n" "%s" >> "$FM_TEST_BELAY_LEAKS"; fi\nexec "%s" "$@"\n' \
    "$command" "$command" "$real_command" > "$SHIMBIN/$command"
  chmod +x "$SHIMBIN/$command"
done
run_belay() {  # <home> [KEY=VALUE...]; stdin payload fixed
  local home=$1 blob
  shift
  blob=$(git hash-object "$BELAY_ROOT/belay.mjs" 2>/dev/null || true)
  rm -f "$SEEN"
  : > "$REQUESTS"
  : > "$LEAKS"
  : > "$COMMANDS"
  : > "$DIAGNOSTICS"
  printf 'payload' | env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE FM_HOME="$home" \
    FM_CONFIG_OVERRIDE='' FM_JEV_BELAY_BLOB="$blob" FM_TEST_BELAY_SEEN="$SEEN" \
    FM_TEST_BELAY_REQUESTS="$REQUESTS" FM_TEST_BELAY_LEAKS="$LEAKS" FM_TEST_BELAY_COMMANDS="$COMMANDS" \
    FM_TEST_BELAY_DIAGNOSTICS="$DIAGNOSTICS" \
    FM_TEST_BELAY_POLICY_PATH="$PATH" \
    NODE_OPTIONS="--import=$TRANSPORT_MODULE" PATH="$SHIMBIN:$PATH" "$@" \
    "$ROOT/bin/fm-jev-belay-hook.sh"
}

run_belay "$LANE" JEV_BASE_URL=https://evil.invalid JEV_MODEL=other JEV_API_KEY=alt \
  CLAUDE_PLUGIN_OPTION_TYPESAFE_API_KEY=option || fail "wrapper failed for a lane home with the primary key"
[ "$(jq -r .key "$SEEN")" = primary-key ] || fail "belay did not receive the primary key"
[ "$(jq -r .stdin "$SEEN")" = payload ] || fail "belay did not receive the Stop payload"
[ "$(jq -c '[.base,.model,.alt,.option,.argvHasKey]' "$SEEN")" = '[null,null,null,null,false]' ] \
  || fail "belay saw a redirecting variable or the key on argv"
pass "the wrapper hands the primary key to belay only, with redirecting variables cleared"
[ ! -s "$LEAKS" ] || fail "primary key leaked to a wrapper child"
[ "$(jq -s length "$REQUESTS")" = 2 ] || fail "absent policy must allow both actual fetch requests"
jq -se 'all(.[]; .authorization == "Bearer primary-key")' "$REQUESTS" >/dev/null \
  || fail "transport did not receive the resolved key"

mkdir -p "$LANE/config"
POLICY="$LANE/config/dispatch-never-send"
printf 'classified phrase\n' > "$POLICY"
for keys in public private both; do
  case "$keys" in
    public) run_belay "$LANE" TYPESAFE_API_KEY=public-key; expected=public-key ;;
    private) run_belay "$LANE" TYPESAFE_API_KEY_PRIVATE=private-key; expected=private-key ;;
    both) run_belay "$LANE" TYPESAFE_API_KEY=public-key TYPESAFE_API_KEY_PRIVATE=private-key; expected=private-key ;;
  esac
  [ "$(jq -r .key "$SEEN")" = "$expected" ] || fail "$keys exported key precedence was lost"
  [ "$(jq -r .privateKey "$SEEN")" = null ] || fail "private key variable reached vendor"
  [ ! -s "$LEAKS" ] || fail "$keys exported key leaked to an external command"
  [ "$(jq -s length "$REQUESTS")" = 2 ] || fail "allowed policy must permit every fetch attempt"
  jq -se --arg auth "Bearer $expected" 'all(.[]; .authorization == $auth)' "$REQUESTS" >/dev/null \
    || fail "$keys exported key did not reach transport"
  for command in dirname git; do
    grep -qx "$command" "$COMMANDS" || fail "$command leakage shim was not exercised"
  done
done
pass "exported keys retain private/public precedence and never reach wrapper or policy children"

for field in task final_message checks_run; do
  request=$(jq -cn --arg field "$field" \
    '{model:"jev-1.13.0",state:{task:"ordinary task",final_message:"ordinary result",run:{file_changes:1,checks_run:["ordinary check"]}},questions:{}} |
     if $field == "checks_run" then .state.run.checks_run = ["CLASSIFIED \n\t PHRASE"]
     else .state[$field] = "CLASSIFIED \n\t PHRASE" end')
  run_belay "$LANE" TYPESAFE_API_KEY=public-key TYPESAFE_API_KEY_PRIVATE=private-key \
    FM_TEST_BELAY_REQUEST="$request" || fail "$field withholding must allow stop"
  [ -f "$SEEN" ] || fail "$field policy fixture did not run vendor"
  [ ! -s "$REQUESTS" ] || fail "$field confidential text reached transport"
  [ ! -s "$LEAKS" ] || fail "$field policy checker leaked exported credentials"
done
pass "actual task, final_message and checks_run JSON is gated with case and whitespace normalization"
run_belay "$LANE" FM_TEST_BELAY_RETRY_REQUEST='{"model":"jev-1.13.0","state":{"task":"classified phrase","final_message":"ordinary","run":{"file_changes":1,"checks_run":[]}},"questions":{}}' \
  || fail "retry withholding must allow stop"
[ "$(jq -s length "$REQUESTS")" = 1 ] || fail "confidential retry request reached transport"
pass "each fetch attempt is checked against its own request body"

OVERRIDE="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE"
printf 'override phrase\n' > "$OVERRIDE/dispatch-never-send"
run_belay "$LANE" FM_CONFIG_OVERRIDE="$OVERRIDE" \
  FM_TEST_BELAY_REQUEST='{"model":"jev-1.13.0","state":{"task":"OVERRIDE phrase","final_message":"ordinary","run":{"file_changes":1,"checks_run":[]}},"questions":{}}' \
  || fail "override policy withholding must allow stop"
[ ! -s "$REQUESTS" ] || fail "config override policy was ignored"
run_belay "$LANE" FM_CONFIG_OVERRIDE="$OVERRIDE" \
  FM_TEST_BELAY_REQUEST='{"model":"jev-1.13.0","state":{"task":"classified phrase","final_message":"ordinary","run":{"file_changes":1,"checks_run":[]}},"questions":{}}' \
  || fail "override allowed request failed"
[ "$(jq -s length "$REQUESTS")" = 2 ] || fail "home policy incorrectly overrode config override"
pass "config override selects the effective policy"

STALLBIN="$TMP_ROOT/belay-stall"
mkdir -p "$STALLBIN"
cat > "$STALLBIN/jq" <<'SH'
#!/bin/bash
printf '%s' "$$" > "$FM_TEST_POLICY_PID"
exec sleep 60
SH
chmod +x "$STALLBIN/jq"
started=$SECONDS
run_belay "$LANE" FM_TEST_BELAY_POLICY_PATH="$STALLBIN:$PATH" FM_TEST_POLICY_PID="$TMP_ROOT/policy-pid" \
  JEV_BELAY_TIMEOUT_MS=60000 || fail "stalled policy must fail open"
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 10 ] || fail "synchronous policy work was not bounded"
[ -f "$SEEN" ] && [ ! -s "$REQUESTS" ] || fail "timed-out policy reached transport"
[ -s "$TMP_ROOT/policy-pid" ] || fail "stalled policy fixture did not run"
policy_pid=$(cat "$TMP_ROOT/policy-pid")
for _ in 1 2 3 4 5; do
  kill -0 "$policy_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$policy_pid" 2>/dev/null; then
  kill -KILL "$policy_pid" 2>/dev/null || true
  fail "timed-out policy left its checker running"
fi
pass "stalled policy work is bounded, reaped, and withheld without blocking Stop"

printf '# dispatch-never-send malformed directive\n' > "$POLICY"
run_belay "$LANE" || fail "invalid policy must allow stop"
[ -f "$SEEN" ] && [ ! -s "$REQUESTS" ] || fail "invalid policy reached transport"
printf 'classified phrase\n' > "$POLICY"
chmod 000 "$POLICY"
run_belay "$LANE" || fail "unreadable policy must allow stop"
chmod 600 "$POLICY"
[ -f "$SEEN" ] && [ ! -s "$REQUESTS" ] || fail "unreadable policy reached transport"
rm -f "$POLICY"
pass "invalid and unreadable policy refuse before transport"

run_belay "$LANE" FM_TEST_BELAY_EXIT=2 && fail "belay exit status must pass through"
[ -f "$SEEN" ] || fail "belay did not run for the exit-status case"
pass "belay's own exit status reaches Claude"

printf 'tampered\n' >> "$BELAY_ROOT/belay.mjs"
run_belay "$LANE" FM_JEV_BELAY_BLOB=0000000000000000000000000000000000000000 || fail "pin mismatch must exit 0"
[ ! -e "$SEEN" ] || fail "a belay.mjs that does not match the pin must not run"
mv "$BELAY_ROOT" "$BELAY_ROOT.off"
run_belay "$LANE" || fail "missing clone must exit 0"
[ ! -e "$SEEN" ] || fail "missing clone must not run belay"
mv "$BELAY_ROOT.off" "$BELAY_ROOT"
mv "$PRIMARY/.env" "$PRIMARY/.env.off"
run_belay "$LANE" || fail "missing key must exit 0"
[ ! -e "$SEEN" ] || fail "belay must not run without a key"
mv "$PRIMARY/.env.off" "$PRIMARY/.env"
pass "pin mismatch, missing clone and missing key exit 0 without running belay"
