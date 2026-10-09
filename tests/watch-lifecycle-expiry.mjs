import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { performance } from "node:perf_hooks";

async function testMonotonicDeadline(root) {
  const { setLifecycleDeadline } = await import(pathToFileURL(`${root}/.pi/extensions/lib/fm-watch-lifecycle.ts`).href);
  const originalNow = Object.getOwnPropertyDescriptor(performance, "now");
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  const originalDateNow = Date.now;
  const timers = [];
  let now = 1000;
  let wallNow = 1000;
  try {
    Object.defineProperty(performance, "now", { configurable: true, value: () => now });
    Date.now = () => wallNow;
    globalThis.setTimeout = (callback, delay) => {
      const timer = { callback, delay, cancelled: false, unreferenced: false, unref() { this.unreferenced = true; } };
      timers.push(timer);
      return timer;
    };
    globalThis.clearTimeout = (timer) => { timer.cancelled = true; };
    const actual = [];
    const deadline = setLifecycleDeadline(() => actual.push(deadline.elapsedMs()), 60);
    deadline.unref();
    now = 1059.25;
    timers[0].callback();
    assert.deepEqual(actual, [], "an early callback must not expire the wait");
    assert.equal(timers[1].delay, 1, "retry only the remaining deadline, rounded up");
    assert.ok(timers[1].unreferenced, "a rescheduled deadline must retain unref");
    now = 1059.75;
    timers[1].callback();
    assert.deepEqual(actual, [], "a second early callback must still wait");
    now = 1060.1;
    wallNow = -5000;
    timers[2].callback();
    assert.deepEqual(actual, [60], "elapsed evidence must use the monotonic clock");
    now = 1087.9;
    assert.equal(deadline.elapsedMs(), 87, "actual elapsed time must not be clamped to the bound");
    const cancelled = setLifecycleDeadline(() => assert.fail("cancelled deadline expired"), 60);
    now += 59;
    timers[3].callback();
    cancelled.cancel();
    assert.ok(timers[4].cancelled, "cancel must clear the rescheduled timer");
    const ordinary = setLifecycleDeadline(() => assert.fail("ordinary completion expired"), 60);
    ordinary.cancel();
    assert.ok(timers[5].cancelled, "ordinary completion must cancel the original timer");
  } finally {
    if (originalNow) Object.defineProperty(performance, "now", originalNow);
    else delete performance.now;
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
    Date.now = originalDateNow;
  }
}

const [kind, root, scenario] = process.argv.slice(2);
if (!scenario) {
  await testMonotonicDeadline(root);
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
  assert.ok(/^\d+ms$/.test(matches[0].actual) && parseInt(matches[0].actual) >= bound, `expiry must record actual elapsed time for ${kind}/${scenario}/${waitedOn}: ${log}`);
}
process.exit(0);
