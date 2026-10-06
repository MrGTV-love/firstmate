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
rc=0
# shellcheck disable=SC2016 # The fixture primary shell owns the lock and CLI call.
out=$(FM_SUPERVISION_HOST_PRIMARY=omp "$TMP_ROOT/primary/omp" -c '
  printf "%s\n" "$$" > "$STATE/.lock"
  "$1/bin/fm-supervision-host.sh" park --restart
  rc=$?
  exit "$rc"
' _ "$ROOT" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "restricted host must return an actionable refusal (exit=$rc): $out"
assert_contains "$out" 'session-launch-policy' 'host refuses policy before activating'
kill -0 "$PREDECESSOR" 2>/dev/null || fail 'restricted host stopped predecessor'
cmp -s "$TMP_ROOT/prior-host" "$STATE/.supervision-host" || fail 'restricted host replaced predecessor record'
[ "$(cat "$STATE/.supervision-host-turn")" = 'previous turn custody' ] || fail 'restricted host retired previous turn'
[ "$(cat "$STATE/.supervision-host-engine")" = 'previous engine conversation' ] || fail 'restricted host retired engine custody'
[ ! -e "$FM_HOME/engine-effects" ] || fail 'host invoked engine'
[ ! -e "$STATE/.watch.lock" ] || fail 'restricted host started monitoring'
pass 'omp-primary host refusal invocations=0 predecessor=alive host-record=identical turn-custody=unchanged'

# Drive the real Claude Stop consumer: a refusal must reach the primary, not
# be mistaken for an ownership transfer. Both predecessor and first-host cases
# use a disposable marked home and a Bash executable with Claude's identity.
ln -s /bin/bash "$TMP_ROOT/primary/claude"
for hook_home in "$FM_HOME" "$TMP_ROOT/first-host"; do
  mkdir -p "$hook_home/state" "$hook_home/config"
  printf 'fixture-policy-home\n' > "$hook_home/.fm-secondmate-home"
  : > "$hook_home/AGENTS.md"
  ln -s "$ROOT/bin" "$hook_home/bin"
  printf 'claude sonnet\n' > "$hook_home/config/supervision-host"
  printf 'omp-or-tc\n' > "$hook_home/config/session-launch-policy"
  : > "$hook_home/state/task.meta"
  rc=0
  # shellcheck disable=SC2016 # Fixture child expands its own home and lock.
  out=$(printf '{"session_id":"fixture-policy","stop_hook_active":false}' \
    | FM_ROOT_OVERRIDE="$hook_home" FM_HOME="$hook_home" "$TMP_ROOT/primary/claude" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
        rc=$?
        exit "$rc"
      ' 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "policy refusal disappeared in Claude Stop (exit=$rc): $out"
  assert_contains "$out" 'supervision-host: launch policy refused:' 'policy refusal reaches Claude main'
  [ ! -e "$hook_home/engine-effects" ] || fail 'Claude Stop invoked the disallowed engine'
  [ ! -e "$hook_home/state/.watch.lock" ] || fail 'Claude Stop activated a host watcher'
  assert_contains "$(cat "$hook_home/state/.claude-autoarm-epoch")" 'outcome=rewake' 'hook committed the policy failure to main'
done
kill -0 "$PREDECESSOR" 2>/dev/null || fail 'policy refusal through Stop killed predecessor'
cmp -s "$TMP_ROOT/prior-host" "$STATE/.supervision-host" || fail 'Stop changed predecessor ownership'
[ "$(cat "$STATE/.supervision-host-turn")" = 'previous turn custody' ] || fail 'Stop retired predecessor turn'
[ "$(cat "$STATE/.supervision-host-engine")" = 'previous engine conversation' ] || fail 'Stop retired predecessor engine'
pass 'Claude Stop delivers policy refusal to main with and without predecessor; invocations=0 predecessor-custody=unchanged'

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

test_primary_consumer_policy_refusal() {  # <omp|opencode> <published|failed> <initial|successor>
  local consumer=$1 publication=$2 phase=$3 case_dir repo home out status
  case_dir="$TMP_ROOT/$consumer-$publication-$phase"
  repo="$case_dir/repo"
  home="$case_dir/home"
  mkdir -p "$repo/bin" "$repo/.omp/extensions" "$repo/.pi/extensions/lib" \
    "$repo/.opencode/plugins/lib" "$repo/node_modules/typebox" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  printf 'claude sonnet\n' > "$home/config/supervision-host"
  printf 'omp-or-tc\n' > "$home/config/session-launch-policy"
  cp "$TMP_ROOT/prior-host" "$home/state/.supervision-host"
  printf 'previous turn custody\n' > "$home/state/.supervision-host-turn"
  printf 'previous engine conversation\n' > "$home/state/.supervision-host-engine"
  printf 'live task\n' > "$home/state/task.meta"
  printf 'live lease\n' > "$home/state/task.lease"
  printf 'durable wake\n' > "$home/state/wakes.jsonl"
  if [ "$publication" = failed ]; then
    mkdir "$home/state/.watcher-down"
  fi
  cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$repo/.opencode/plugins/"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$repo/.opencode/plugins/lib/"
  cp "$ROOT/.opencode/plugins/package.json" "$repo/.opencode/plugins/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' \
    > "$repo/node_modules/typebox/index.js"
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$FM_HOME/state/launches"
if [ "$FM_POLICY_PHASE" = successor ] && [ ! -e "$FM_HOME/state/first-host" ]; then
  : > "$FM_HOME/state/first-host"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  trap 'exit 0' TERM INT
  while [ ! -e "$FM_HOME/state/release-host" ]; do sleep 0.02; done
  printf 'signal: prior host close\n'
  exit 0
fi
exec "$FM_POLICY_ROOT/bin/fm-supervision-host.sh" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  kill -0 "$4" 2>/dev/null || exit 1
  printf 'confirmed=%s watcher=%s\n' "$2" "$4" >> "$FM_HOME/state/launches"
  exit 0
fi
printf 'plain=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$FM_HOME/state/launches"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-%s\n' "$$" "$$"
trap 'exit 0' TERM INT
if [ ! -e "$FM_HOME/state/first-plain" ]; then
  : > "$FM_HOME/state/first-plain"
  while [ ! -e "$FM_HOME/state/release-plain" ]; do sleep 0.02; done
  printf 'signal: ordinary monitoring continues\n'
  exit 0
fi
while :; do sleep 0.02; done
SH
  chmod +x "$repo/bin/"*.sh
  ln -s "$(command -v bun)" "$case_dir/$consumer"
  status=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    FM_POLICY_ROOT="$ROOT" FM_POLICY_CONSUMER="$consumer" FM_POLICY_PUBLICATION="$publication" FM_POLICY_PHASE="$phase" \
    FM_OMP_ARM_READY_TIMEOUT_MS=1000 FM_OPENCODE_ARM_READY_TIMEOUT_MS=1000 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=1 \
    "$case_dir/$consumer" --eval "$(cat <<'JS'
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const state = `${process.env.FM_HOME}/state`;
const root = process.env.FM_ROOT_OVERRIDE;
const consumer = process.env.FM_POLICY_CONSUMER;
const phase = process.env.FM_POLICY_PHASE;
const expectedHosts = phase === "successor" ? 2 : 1;
const records = [".supervision-host", ".supervision-host-turn", ".supervision-host-engine", "task.meta", "task.lease", "wakes.jsonl"];
const before = records.map((name) => readFileSync(`${state}/${name}`, "utf8"));
const rows = () => existsSync(`${state}/launches`) ? readFileSync(`${state}/launches`, "utf8").trim().split("\n") : [];
const hosts = () => rows().filter((row) => row.startsWith("host="));
const plains = () => rows().filter((row) => row.startsWith("plain="));
const sent = [];
const handlers = new Map();
let tool;
let hooks;
const api = {
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool(value) { tool = value; },
  sendUserMessage(message) { record(message); },
};
function record(message) {
  if (!plains().length || !rows().some((row) => row.startsWith("confirmed="))) {
    throw new Error(`wake was delivered before ordinary monitoring and handling handoff: ${rows().join(" | ")}`);
  }
  sent.push(message);
}
const client = { session: { promptAsync: async (request) => record(request.body.parts[0].text) } };
async function until(predicate, label) {
  for (let attempt = 0; attempt < 600; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`${label}: ${JSON.stringify({ sent, launches: rows() })}`);
}
const refusal = (message) => message.includes("supervision-host: launch policy refused:");
const ordinary = (message) => message.includes("signal: ordinary monitoring continues");
async function arm() {
  if (consumer === "omp") return tool.execute();
  return globalThis.__firstmateOpenCodeWatchArm.ensureArmed("fixture-policy", client);
}
async function consume() {
  if (consumer !== "omp") return;
  for (const message of sent) await handlers.get("before_agent_start")({ prompt: message }, {});
}
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
try {
  const modulePath = consumer === "omp"
    ? `${root}/.omp/extensions/fm-primary-omp-watch.ts`
    : `${root}/.opencode/plugins/fm-primary-watch-arm.js`;
  const mod = await import(pathToFileURL(modulePath).href);
  if (consumer === "omp") mod.default(api);
  else hooks = await mod.FmPrimaryWatchArm({ client, directory: root, worktree: root });
  await arm();
  if (phase === "successor") {
    await until(() => hosts().length === 1, "first host did not start");
    writeFileSync(`${state}/release-host`, "release\n");
  }
  await until(() => sent.some(refusal), "refusal was not delivered");
  if (sent.filter(refusal).length !== 1) throw new Error(`refusal was delivered more than once: ${JSON.stringify(sent)}`);
  if (hosts().length !== expectedHosts || plains().length !== 1) throw new Error(`denied host was retried or monitoring was not restored: ${rows().join(" | ")}`);
  const refusalMessage = sent.find(refusal);
  const detail = process.env.FM_POLICY_PUBLICATION === "failed" ? "could not record the hand-back" : "predecessor custody is unchanged";
  if (!refusalMessage.includes(detail) || !refusalMessage.includes("session-launch-policy")) throw new Error(`refusal lost policy or publication detail: ${refusalMessage}`);
  if (refusalMessage.includes("could not restore watcher continuity") || refusalMessage.includes("ready successor")) throw new Error(`ordinary fallback was reported as failed: ${refusalMessage}`);
  if (phase === "successor" && !sent.some((message) => message.includes("signal: prior host close"))) throw new Error(`original close was lost: ${JSON.stringify(sent)}`);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await arm();
    if (hooks) await hooks.event({ event: { type: "session.idle", properties: { sessionID: "fixture-policy" } } });
  }
  await new Promise((resolve) => setTimeout(resolve, 150));
  if (hosts().length !== expectedHosts || sent.filter(refusal).length !== 1) throw new Error(`idle or repair retried the denial: ${JSON.stringify({ sent, launches: rows() })}`);
  writeFileSync(`${state}/release-plain`, "release\n");
  await until(() => sent.some(ordinary) && plains().length === 2, "ordinary close did not continue monitoring");
  if (sent.filter(ordinary).length !== 1 || sent.filter(refusal).length !== 1 || hosts().length !== expectedHosts) throw new Error(`ordinary close repeated denial or delivery: ${JSON.stringify({ sent, launches: rows() })}`);
  if (consumer === "omp") {
    await handlers.get("session_shutdown")({}, {});
    const replacement = await import(`${pathToFileURL(modulePath).href}?replacement=1`);
    replacement.default(api);
    await handlers.get("session_start")({}, {});
    await until(() => sent.filter(refusal).length === 2 && plains().length === 3, "replacement did not replay its pending refusal with ordinary monitoring");
    if (hosts().length !== expectedHosts) throw new Error(`replacement replay launched the denied host: ${rows().join(" | ")}`);
    await consume();
    await handlers.get("session_shutdown")({}, {});
    await handlers.get("session_start")({}, {});
    await until(() => plains().length === 4, "owning replacement did not retain ordinary monitoring");
    await arm();
    if (hosts().length !== expectedHosts || sent.filter(refusal).length !== 2) throw new Error(`consumed replacement retried or redelivered the refusal: ${JSON.stringify({ sent, launches: rows() })}`);
    if (existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("consumed refusal remained in replacement handoff");
  }
  records.forEach((name, index) => {
    if (readFileSync(`${state}/${name}`, "utf8") !== before[index]) throw new Error(`${name} custody changed`);
  });
  if (existsSync(`${process.env.FM_HOME}/engine-effects`)) throw new Error("a denied engine was invoked");
  const predecessor = before[0].split("\t")[1];
  process.kill(Number(predecessor), 0);
} finally {
  if (consumer === "omp" && handlers.has("session_shutdown")) await handlers.get("session_shutdown")({}, {});
  try { unlinkSync(`${state}/.lock`); } catch {}
  for (const row of rows()) {
    const pid = row.match(/^(?:host|plain)=([0-9]+)/)?.[1];
    if (pid) { try { process.kill(Number(pid), "SIGTERM"); } catch {} }
  }
  await new Promise((resolve) => setTimeout(resolve, 80));
}
process.exit(0);
JS
)" 2>&1) || status=$?
  expect_code 0 "$status" "$consumer $publication $phase policy refusal public consumer: $out"
  [ -z "$out" ] || fail "$consumer policy consumer printed output: $out"
  pass "$consumer $publication $phase: one terminal refusal, ordinary monitoring, unchanged custody, no denied restoration"
}

if command -v bun >/dev/null 2>&1; then
  for consumer in omp opencode; do
    for publication in published failed; do
      for phase in initial successor; do
        test_primary_consumer_policy_refusal "$consumer" "$publication" "$phase"
      done
    done
  done
else
  printf 'skip: bun absent (omp/OpenCode public consumer policy checks)\n'
fi
