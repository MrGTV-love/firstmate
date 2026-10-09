import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const [kind, root, scenario] = process.argv.slice(2);
if (!scenario) {
  for (const name of ["shutdown", "unready", ...(kind === "omp" ? ["host-unready"] : [])]) {
    const result = spawnSync(process.execPath, [process.argv[1], kind, root, name], { encoding: "utf8" });
    assert.equal(result.status, 0, `${kind}/${name}: ${result.stderr}${result.stdout}`);
  }
  process.exit(0);
}
const home = `${root}/${scenario}-home`;
const state = `${home}/state`;
const config = `${home}/config`;
mkdirSync(state, { recursive: true });
mkdirSync(config, { recursive: true });
const host = scenario === "host-unready";
if (host) writeFileSync(`${config}/supervision-host`, "");
const fakebin = `${root}/expiry-fakebin`;
mkdirSync(fakebin, { recursive: true });
writeFileSync(`${fakebin}/bash`, '#!/bin/bash\nif [ "${1:-}" = -lc ]; then exec /bin/bash -c "$2"; fi\nexec /bin/bash "$@"\n', { mode: 0o755 });
Object.assign(process.env, {
  FM_HOME: home,
  FM_ROOT_OVERRIDE: root,
  FM_STATE_OVERRIDE: state,
  FM_CONFIG_OVERRIDE: config,
  PATH: `${fakebin}:${process.env.PATH}`,
  FM_ARM_LOG: `${home}/arms.log`,
  FM_EXPIRY_SCENARIO: scenario,
  FM_WATCH_ARM_RETIRE_TIMEOUT_MS: "60",
  FM_PI_ARM_READY_TIMEOUT_MS: "2000",
  FM_OMP_ARM_READY_TIMEOUT_MS: "2000",
  FM_PI_SUCCESSOR_GRACE_MS: "400",
  FM_OMP_SUCCESSOR_GRACE_MS: "400",
});
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const childScript = `${root}/expiry-child.sh`;
writeFileSync(childScript, `#!/bin/bash
# Ignore retirement before publishing readiness: expiry tests must exercise an
# unretirable child, not race Node startup against the retirement deadline.
trap '' TERM
first=0
[ -f "$FM_ARM_LOG" ] || first=1
printf '%s\\n' "$$" >> "$FM_ARM_LOG"
if [ "$first" = 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\\n' "$$"
  if [ "$FM_EXPIRY_SCENARIO" != shutdown ]; then
    printf 'signal: expiry regression wake\\n'
    exit 0
  fi
fi
while :; do sleep 1; done
`);
for (const name of ["fm-watch-arm.sh", "fm-supervision-host.sh"]) {
  writeFileSync(`${root}/bin/${name}`, `#!/bin/bash\n[ "\${1:-}" = --handling-delivered ] && exit 0\nexec /bin/bash '${childScript}'\n`, { mode: 0o755 });
}
const rows = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
process.once("exit", () => {
  for (const pid of rows()) {
    try { process.kill(Number(pid), "SIGKILL"); } catch {}
  }
});
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate) => {
  for (let i = 0; i < (host ? 1800 : 500) && !predicate(); i++) await sleep(20);
  assert.ok(predicate(), `${kind}/${scenario} did not reach its expected state`);
};
const handlers = new Map();
const sent = [];
const mod = await import(pathToFileURL(`${root}/.${kind}/extensions/fm-primary-${kind}-watch.ts`).href);
mod.default({
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool() {},
  sendUserMessage(message) { sent.push(message); },
  events: { on() {}, emit() {} },
});
await handlers.get("session_start")({}, {});
if (scenario === "shutdown") {
  await waitFor(() => rows().length === 1);
  await sleep(100);
  await handlers.get("session_shutdown")({ reason: "quit" }, {});
} else {
  await waitFor(() => sent.some((message) => message.includes("unready successor arm did not exit within 60ms")));
  assert.equal(rows().length, 2, "an unretired arm must not overlap another retry");
  assert.ok(sent.some((message) => message.includes("signal: expiry regression wake")), "the original wake must survive failed restoration");
}
const log = readFileSync(`${state}/extensions/${kind}-primary-watch/lifecycle.log`, "utf8");
const records = log.trim().split("\n").map((line) => Object.fromEntries(line.split(" ").slice(1).map((field) => field.split("="))));
const expected = scenario === "shutdown" ? [["shutdown-arm-close", 60]] : [[host ? "supervision-host-readiness" : "arm-readiness", host ? 30000 : 2000], ["unready-arm-close", 60]];
for (const [waitedOn, bound] of expected) {
  const matches = records.filter((record) => record.event === "bound-expired" && record["waited-on"] === waitedOn);
  assert.equal(matches.length, 1, `one expiry record is required for ${waitedOn}: ${log}`);
  assert.equal(matches[0].waiter, `${kind}-watch-extension`);
  assert.equal(matches[0].bound, `${bound}ms`);
  assert.ok(/^\d+ms$/.test(matches[0].actual) && parseInt(matches[0].actual) >= bound, "expiry must record actual elapsed time");
}
process.exit(0);
