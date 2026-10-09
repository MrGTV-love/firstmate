// Opt-in real Pi loader regression; run with FM_PI_PACKAGE_DIR pointing to the installed SDK.
// No model calls or user configuration: all homes and agent state are disposable.
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, cpSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
assert.ok(process.env.FM_PI_PACKAGE_DIR, "FM_PI_PACKAGE_DIR must name an installed Pi SDK");
const lab = mkdtempSync(join(root, ".pi-loader-test-"));
const repo = join(lab, "repo");
const home = join(lab, "home");
const agentDir = join(lab, "agent");
let session;
try {
  mkdirSync(join(repo, ".pi/extensions"), { recursive: true });
  mkdirSync(join(repo, "bin"));
  mkdirSync(join(home, "state"), { recursive: true });
  mkdirSync(agentDir);
  cpSync(join(root, ".pi/extensions/lib"), join(repo, ".pi/extensions/lib"), { recursive: true });
  cpSync(join(root, ".pi/extensions/fm-primary-pi-watch.ts"), join(repo, ".pi/extensions/fm-primary-pi-watch.ts"));
  writeFileSync(join(repo, "duplicate.ts"), 'export { default } from "./.pi/extensions/fm-primary-pi-watch.ts";\n');
  writeFileSync(join(repo, "bin/fm-watch-arm.sh"), `#!/usr/bin/env bash
[ "\${1:-}" = --handling-delivered ] && exit 0
if [ "\${1:-}" = --restart ] && [ -f "$FM_ARM_LOG" ]; then
  while IFS= read -r row; do kill "\${row#arm=}" 2>/dev/null || :; done < "$FM_ARM_LOG"
fi
printf 'arm=%s\\n' "$$" >> "\${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=loader-%s\\n' "$$" "$$"
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
`, { mode: 0o755 });
  Object.assign(process.env, {
    FM_HOME: home, FM_ROOT_OVERRIDE: repo, PI_CODING_AGENT_DIR: agentDir,
    FM_ARM_LOG: join(lab, "arms.log"), FM_PI_ARM_READY_TIMEOUT_MS: "5000",
  });
  writeFileSync(join(home, "state/.lock"), `${process.pid}\n`);
  const { DefaultResourceLoader, SessionManager, SettingsManager, createAgentSession } = await import(
    pathToFileURL(join(process.env.FM_PI_PACKAGE_DIR, "dist/index.js")).href
  );
  const loader = new DefaultResourceLoader({
    cwd: repo, agentDir, settingsManager: SettingsManager.inMemory(),
    additionalExtensionPaths: [join(repo, ".pi/extensions/fm-primary-pi-watch.ts"), join(repo, "duplicate.ts")],
    noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
  });
  await loader.reload();
  assert.deepEqual(loader.getExtensions().errors, [], "both entrypoints must load successfully");
  ({ session } = await createAgentSession({
    cwd: repo, agentDir, resourceLoader: loader, sessionManager: SessionManager.inMemory(repo),
    settingsManager: SettingsManager.inMemory(), tools: ["fm_watch_arm_pi"],
  }));
  // A bound consumer is required for Pi to emit session_start on reload.
  await session.bindExtensions({ onError: error => assert.fail(JSON.stringify(error)) });
  const armCount = () => existsSync(process.env.FM_ARM_LOG)
    ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").length : 0;
  const waitForArm = async (count) => {
    for (let i = 0; i < 200 && armCount() < count; i++) await new Promise(r => setTimeout(r, 50));
    assert.equal(armCount(), count, `exactly one watcher per activation\n${readFileSync(join(home, "state/extensions/pi-primary-watch/lifecycle.log"), "utf8")}`);
  };
  await waitForArm(1);
  assert.equal(session.getAllTools().filter(t => t.name === "fm_watch_arm_pi").length, 1);
  const arm = session.getToolDefinition("fm_watch_arm_pi");
  const result = await arm.execute("loader-arm", {}, undefined, undefined, {});
  assert.equal(result.details.ok, true);
  assert.match(result.details.message, /unchanged/);
  assert.equal(armCount(), 1, "calling the registered tool must not duplicate the watcher");
  await session.reload();
  await waitForArm(2);
  const reloaded = await session.getToolDefinition("fm_watch_arm_pi").execute("reload-arm", {}, undefined, undefined, {});
  assert.equal(reloaded.details.ok, true);
  assert.match(reloaded.details.message, /unchanged/);
  assert.equal(session.getAllTools().filter(t => t.name === "fm_watch_arm_pi").length, 1);
  assert.equal(armCount(), 2, "reload must retain one current arm");
  const pids = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").map(row => Number(row.slice(4)));
  const alive = pid => { try { process.kill(pid, 0); return true; } catch { return false; } };
  for (let i = 0; i < 100 && alive(pids[0]); i++) await new Promise(r => setTimeout(r, 50));
  assert.equal(alive(pids[0]), false, "reload must retire the predecessor watcher");
  assert.equal(alive(pids[1]), true, "reload must retain a live successor watcher");
  console.log("PASS: genuine duplicate Pi loading starts one watcher and reloads successfully");
} finally {
  if (session) {
    await session.extensionRunner?.emit({ type: "session_shutdown", reason: "quit" });
    session.dispose();
  }
  rmSync(lab, { recursive: true, force: true });
}
// The SDK can keep background services referenced after disposing a session.
process.exit(0);
