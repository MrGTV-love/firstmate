#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export NODE_NO_WARNINGS=1
BASE=$(fm_test_tmproot fm-guard-regression)
test_opencode_healthy_arm_output_does_not_suppress_guard() {
  local write_mode=${1:-immediate}
  local arm_plugin guard_plugin repo home log guard_log guard_sync out status
  arm_plugin="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
  guard_plugin="$ROOT/.opencode/plugins/fm-primary-turnend-guard.js"
  repo="$TMP_ROOT/opencode-external-healthy-$write_mode-root"
  home="$TMP_ROOT/opencode-external-healthy-$write_mode-home"
  log="$TMP_ROOT/opencode-external-healthy-$write_mode-arm.log"
  guard_log="$TMP_ROOT/opencode-external-healthy-$write_mode-guard.log"
  guard_sync="$TMP_ROOT/opencode-external-healthy-$write_mode-guard.sync"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  mkfifo "$guard_sync"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$repo/bin/fm-supervision-lib.sh"
  : > "$home/state/task.meta"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'args=%s\n' "$*" >> "${FM_ARM_LOG:?}"
printf 'watcher: healthy pid=1 (beacon 0s)\n'
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard\n' >> "${FM_GUARD_LOG:?}"
printf 'guard ran after external healthy watcher\n' >&2
exit 2
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-turnend-guard.sh"
  out=$(FM_WRITE_MODE="$write_mode" FM_GUARD_SYNC="$guard_sync" ARM_PLUGIN="$arm_plugin" GUARD_PLUGIN="$guard_plugin" WORKTREE="$repo" FM_HOME="$home" FM_ARM_LOG="$log" FM_GUARD_LOG="$guard_log" node 2>&1 <<'EOF'
import childProcess from "node:child_process";
import { closeSync, constants, existsSync, openSync, readFileSync, readSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { pathToFileURL } from "node:url";

let delayedWrite = false;
if (process.env.FM_WRITE_MODE === "delayed") {
  const spawn = childProcess.spawn;
  childProcess.spawn = function (command, args, options) {
    if (command !== `${process.env.WORKTREE}/bin/fm-turnend-guard.sh`) {
      return spawn.call(this, command, args, options);
    }
    // Hand the guard the FIFO's write end as fd 3. The parent's own writer
    // lets the blocking reader open at once, whatever the guard does.
    const probe = openSync(process.env.FM_GUARD_SYNC, constants.O_RDONLY | constants.O_NONBLOCK);
    const writer = openSync(process.env.FM_GUARD_SYNC, "w");
    const child = spawn.call(this, command, args, { ...options, stdio: [...options.stdio, writer] });
    const reader = openSync(process.env.FM_GUARD_SYNC, "r");
    closeSync(writer);
    closeSync(probe);
    const end = child.stdin.end.bind(child.stdin);
    child.stdin.end = (...input) => {
      // Block the parent event loop until the guard closes fd 3, so a
      // stdin-ignoring stub has closed stdin before the write, without first
      // letting Node see the exit and mark the stream destroyed.
      readSync(reader, Buffer.alloc(1));
      closeSync(reader);
      delayedWrite = true;
      return end(...input);
    };
    return child;
  };
  syncBuiltinESMExports();
}

const armMod = await import(pathToFileURL(process.env.ARM_PLUGIN).href);
const guardMod = await import(pathToFileURL(process.env.GUARD_PLUGIN).href);
let promptBody = "";
const client = {
  session: {
    promptAsync: async (request) => {
      promptBody = request.body.parts[0].text;
    },
  },
};
await armMod.FmPrimaryWatchArm({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
const guardHooks = await guardMod.FmPrimaryTurnendGuard({
  client,
  directory: process.env.WORKTREE,
  worktree: process.env.WORKTREE,
});
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
await guardHooks.event({ event: { type: "session.idle", properties: { sessionID: "session-test" } } });
for (let i = 0; i < 250 && !existsSync(process.env.FM_GUARD_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 20));
}
if (!existsSync(process.env.FM_ARM_LOG)) {
  console.error("watch arm did not run");
  process.exit(1);
}
if (!readFileSync(process.env.FM_ARM_LOG, "utf8").includes("args=--restart")) {
  console.error("watch arm was not asked to restart into an owned child");
  process.exit(1);
}
if (!existsSync(process.env.FM_GUARD_LOG)) {
  console.error("turn-end guard was suppressed by an external healthy watcher");
  process.exit(1);
}
if (!promptBody.includes("TURN WOULD END BLIND")) {
  console.error(`missing blind-turn prompt: ${promptBody}`);
  process.exit(1);
}
if (process.env.FM_WRITE_MODE === "delayed" && !delayedWrite) {
  throw new Error("guard hook payload write was not delayed");
}
EOF
)
  status=$?
  expect_code 0 "$status" "OpenCode watch plugin must not treat external healthy output as an owned arm ($write_mode hook write): $out"
  [ -z "$out" ] || fail "OpenCode external-healthy test printed output: $out"
  pass "OpenCode healthy arm output does not suppress the turn-end guard ($write_mode hook write)"
}
failures=0
for attempt in $(seq 1 5); do
  TMP_ROOT="$BASE/delayed-$attempt"
  mkdir -p "$TMP_ROOT"
  output=$( (test_opencode_healthy_arm_output_does_not_suppress_guard delayed) 2>&1)
  status=$?
  printf "CASE mode=delayed attempt=%s exit=%s\n%s\n" "$attempt" "$status" "$output"
  if [ "$status" -eq 0 ] || [[ "$output" != *"write EPIPE"* ]] || [[ "$output" != *"Unhandled"* ]]; then failures=$((failures + 1)); fi
done
printf "Unexpected outcomes=%s\n" "$failures"
[ "$failures" -eq 0 ]
