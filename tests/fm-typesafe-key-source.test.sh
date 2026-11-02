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

# Native omp credentials use its supported private !command interface, not
# saved keys or the worker environment. Exercise the command with fake homes.
NATIVE_OUT=$(env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE LANE="$LANE" ROOT="$ROOT" \
  NODE_NO_WARNINGS=1 node --experimental-strip-types --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const { installTypesafeJudge } = await import(pathToFileURL(`${process.env.ROOT}/bin/fm-omp-jev.ts`));
let provider, config;
const api = { registerProvider(name, value) { provider = name; config = value; } };
installTypesafeJudge(api, { home: process.env.LANE, project: "firstmate" });
assert.equal(provider, "typesafe");
assert.equal(config.baseUrl, "https://api.typesafe.ai");
assert.ok(!config.apiKey.includes("primary-key"), "configuration must store only the lookup command");
assert.equal(execFileSync("/bin/sh", ["-c", config.apiKey.slice(1)], { encoding: "utf8" }), "primary-key");
assert.equal(process.env.TYPESAFE_API_KEY, undefined);
assert.equal(process.env.TYPESAFE_API_KEY_PRIVATE, undefined);
for (const context of [{ project: "firstmate", noHelpers: true }, { project: "vernant" }, { project: "" }, {}]) {
  installTypesafeJudge(api, { home: process.env.LANE, ...context });
  assert.throws(() => execFileSync("/bin/sh", ["-c", config.apiKey.slice(1)], { encoding: "utf8", stdio: "pipe" }),
    `${JSON.stringify(context)} must supply no credential even when the primary has one`);
}
console.log("native-key-ok");
JS
) || fail "native command-key boundary failed: $NATIVE_OUT"
[ "$NATIVE_OUT" = native-key-ok ] || fail "unexpected native key probe: $NATIVE_OUT"
pass "native omp command credentials reach the primary privately for firstmate only and stay unavailable with no helpers"

# The jev-guard service runs in a separate hook process; it must reach the primary key too.
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
      answers[id] = q.type === 'noul' ? { type: 'noul', noul: 0.95 }
        : { type: 'choice', choice: keys[0], confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === keys[0] ? 1 : 0])) };
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

# Write content has no judgment, so the hook resolves no key; the guard
# service it installs still resolves the primary key when it is asked to decide.
guard_service() {  # <home>
  local home=$1 err="$TMP_ROOT/service.err"
  mkdir -p "$home/state" "$home/config" "$home/data/t1" "$TMP_ROOT/wt"
  : > "$TMP_ROOT/transport"
  outcome=$(env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE -u OPENROUTER_API_KEY FM_TEST_SEAM=1 \
      FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$TMP_ROOT/jev-port")/v1/systemone" \
      REPORT="$ROOT/bin/ten-levels/extensions/report.ts" GUARD_HOME="$home" \
      node --experimental-strip-types --no-warnings --input-type=module 2>"$err" <<'JS'
import { pathToFileURL } from 'node:url';
const { createGuardService } = await import(pathToFileURL(process.env.REPORT));
const { noul } = await import(new URL('../src/core/helpers.ts', pathToFileURL(process.env.REPORT)));
const home = process.env.GUARD_HOME;
const service = createGuardService({ home, config: `${home}/config`, state: `${home}/state`, task: 't1', project: 'firstmate' });
try {
  await service.decide({ content: 'fixture' }, { fixture: noul('Is `content` an ordinary fixture?') });
  console.log('answered');
} catch (error) {
  console.log(`${error.errorType}:${error.requestStarted}`);
}
JS
  ) || fail "guard service probe failed for $home: $(cat "$err")"
}

guard_service "$LANE"
[ "$outcome" = answered ] || fail "the jev-guard service in a home without .env must reach the primary key: $outcome"
grep -qx 'Bearer primary-key' "$TMP_ROOT/transport" || fail "the jev-guard service did not send the primary key"
guard_service "$REMOTE"
[ "$outcome" = CredentialUnavailableError:false ] || fail "the jev-guard service without a remote-bound credential must refuse before egress: $outcome"
[ ! -s "$TMP_ROOT/transport" ] || fail "the jev-guard service in a remote-bound home must make no request"
: > "$TMP_ROOT/transport"
out=$(printf '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"sandbox.txt","content":"fixture"}}' \
  | env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE -u OPENROUTER_API_KEY FM_TEST_SEAM=1 \
      FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$TMP_ROOT/jev-port")/v1/systemone" \
      "$ROOT/bin/fm-jev-guard-hook.sh" "$REMOTE" "$REMOTE/config" "$REMOTE/state" t1 "$TMP_ROOT/wt" "$REMOTE/data/t1" firstmate FIRSTMATE_JEV_GUARD_V1 2>"$TMP_ROOT/hook.err") \
  || fail "the jev-guard hook exited nonzero for an in-root write"
[ -z "$out" ] || fail "the jev-guard hook refused an in-root write that needs no key: $out"
[ ! -s "$TMP_ROOT/transport" ] || fail "the jev-guard hook sent write content to the provider"
kill "$FAKE_JEV_PID" 2>/dev/null
wait "$FAKE_JEV_PID" 2>/dev/null
trap fm_test_cleanup EXIT
pass "the jev-guard service resolves the primary key and refuses unavailable remote-bound credentials without egress; the hook admits writes with no key"

