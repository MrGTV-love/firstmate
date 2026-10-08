#!/usr/bin/env bash
set -u

TEST_WORKTREE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_TMP_BASE=$(mktemp -d "$TEST_WORKTREE/scratchpad-secondmate-busy.XXXXXX") || exit 1
export TMPDIR="$TEST_TMP_BASE"
export HOME="$TEST_TMP_BASE/user-home"
mkdir -p "$HOME"

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-busy-evidence)
trap 'fm_test_cleanup; fm_test_remove_tree "$TEST_TMP_BASE"' EXIT

make_case() {
  local dir="$TMP_ROOT/$1" harness=$2 file tool
  mkdir -p "$dir/code" "$dir/staging" "$dir/fake"
  fm_test_spawn_home "$dir/home" "$harness"
  printf '%s\n' "$harness" > "$dir/home/config/secondmate-harness"
  fm_git_worktree "$dir/repo" "$dir/mate" "mate-$1"
  mkdir -p "$dir/mate/bin" "$dir/mate/state" "$dir/mate/data" "$dir/mate/config" "$dir/mate/projects"
  printf 'sm1\n' > "$dir/mate/.fm-secondmate-home"
  printf '# agents\n' > "$dir/mate/AGENTS.md"
  printf '# charter\n' > "$dir/mate/data/charter.md"
  for file in .claude/settings.json .opencode/plugins/fm-primary-turnend-guard.js \
    .pi/extensions/fm-primary-turnend-guard.ts .pi/extensions/fm-primary-pi-watch.ts \
    .omp/extensions/fm-primary-turnend-guard.ts .omp/extensions/fm-primary-omp-watch.ts; do
    mkdir -p "$dir/mate/$(dirname "$file")" "$dir/original/$(dirname "$file")"
    cp "$ROOT/$file" "$dir/mate/$file"
    cp "$ROOT/$file" "$dir/original/$file"
  done
  cat > "$dir/mate/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'guard invocation\n' >> "$FM_FAKE_DIR/guard-calls"
printf 'guard stdout\n'
printf 'guard stderr\n' >&2
exit "$(cat "$FM_FAKE_DIR/guard-result")"
SH
  chmod +x "$dir/mate/bin/fm-turnend-guard.sh"
  mkdir -p "$dir/original/bin"
  cp "$dir/mate/bin/fm-turnend-guard.sh" "$dir/original/bin/fm-turnend-guard.sh"
  printf '0\n' > "$dir/fake/guard-result"
  : > "$dir/fake/guard-calls"
  ln -s "$ROOT/bin" "$dir/code/bin"
  ln -s "$ROOT/.omp" "$dir/code/.omp"
  ln -s "$ROOT/.agents" "$dir/code/.agents"
  make_spawn_fakebin "$dir" claude opencode pi pi-signed omp codex >/dev/null
  printf 'zsh\n' > "$dir/fake/command"
  case "$harness" in
    pi-signed) printf 'pi\n' ;;
    cursor) printf 'cursor-agent\n' ;;
    *) printf '%s\n' "$harness" ;;
  esac > "$dir/fake/becomes"
  : > "$dir/fake/literal"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_current_path*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
        *pane_current_command*) cat "$D/command"; exit 0 ;;
        *pane_tty*) exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -f "$D/windows" ] || cat "$D/windows"
    exit 0 ;;
  new-window)
    printf 'fm-sm1\n' > "$D/windows"
    printf '@1\n'; exit 0 ;;
  show-environment) exit 1 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] || exit 0
    payload=${1:-}
    case "$payload" in
      ". '"*"'")
        staged=${payload#". '"}
        staged=${staged%"'"}
        (cd "$FM_FAKE_PANE_PATH" && /bin/sh "$staged") || exit $?
        cat "$D/becomes" > "$D/command"
        ;;
      /exit|/quit)
        printf 'zsh\n' > "$D/command"
        ;;
    esac
    printf '%s\n' "$payload" >> "$D/literal"
    exit 0 ;;
esac
exit 0
SH
  cat > "$dir/fakebin/fm-runtime.cjs" <<'JS'
#!/usr/bin/env node
const { writeFileSync, existsSync } = require("node:fs");
const { join } = require("node:path");
const { pathToFileURL } = require("node:url");
(async () => {
  const args = process.argv.slice(2);
  if (args.includes("--help")) {
    process.stdout.write("Start the Cursor Agent\n");
    return;
  }
  const value = (flag) => {
    const index = args.indexOf(flag);
    return index < 0 ? null : args[index + 1];
  };
  const extensions = args.flatMap((arg, index) => arg === "-e" ? [args[index + 1]] : []);
  const configs = args.flatMap((arg, index) => arg === "--config" ? [args[index + 1]] : []);
  const result = { args, extensions, configs, settingSources: value("--setting-sources"), evidencePath: null, handlers: [] };
  const settings = value("--settings");
  if (settings !== null) writeFileSync(join(process.env.FM_FAKE_DIR, "settings.json"), JSON.stringify(JSON.parse(settings)));
  for (const path of extensions) {
    if (!/\.(pi|omp)-ext\.ts$/.test(path)) continue;
    const mod = await import(pathToFileURL(path).href);
    const handlers = {};
    mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on() {} } });
    result.evidencePath = path;
    result.handlers = Object.keys(handlers);
  }
  const plugin = join(process.cwd(), ".opencode/plugins/fm-busy-state.js");
  if (process.env.FM_FAKE_RUNTIME === "opencode" && existsSync(plugin)) {
    const mod = await import(pathToFileURL(plugin).href);
    const hooks = await mod.FmBusyState({});
    if (typeof hooks.event !== "function") throw new Error("OpenCode did not load its generated event consumer");
    result.evidencePath = plugin;
    result.handlers = ["event"];
  }
  writeFileSync(join(process.env.FM_FAKE_DIR, "runtime.json"), JSON.stringify(result));
})().catch((error) => { console.error(error); process.exitCode = 1; });
JS
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/fm-runtime.cjs"
  for tool in claude opencode pi pi-signed omp codex cursor-agent; do
    ln -sf "$dir/fakebin/fm-runtime.cjs" "$dir/fakebin/$tool"
  done
  printf '%s\n' "$dir"
}

in_case() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" HOME="$dir/home/user-home" CLAUDE_CONFIG_DIR= \
    TMPDIR="$TMP_ROOT" FM_TEST_SPAWN_TMP_ROOT="$dir/staging" \
    FM_ROOT_OVERRIDE="$dir/code" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_FAKE_DIR="$dir/fake" FM_FAKE_PANE_PATH="$dir/mate" \
    FM_FAKE_RUNTIME="$(cat "$dir/home/config/secondmate-harness")" \
    FM_BACKEND=tmux TMUX='fake,1,0' FM_SPAWN_NO_GUARD=1 \
    FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_SECONDMATE_PERSIST_POLL=1 FM_CONTROL_POLL=0.01 \
    FM_CONTROL_EXIT_WAIT=0.1 FM_CONTROL_LAUNCH_WAIT=0.1 "$@" 2>&1
}

spawn_case() {
  mkdir -p "$1/home/user-home"
  in_case "$1" "$ROOT/bin/fm-spawn.sh" sm1 "$1/mate" --secondmate
}

classify_case() {
  fm_busy_classify_meta "$1/home/state/sm1.meta" sm1 "$1/home/state"
}

assert_primary_unchanged() {
  local dir=$1 file
  for file in .claude/settings.json .opencode/plugins/fm-primary-turnend-guard.js \
    .pi/extensions/fm-primary-turnend-guard.ts .pi/extensions/fm-primary-pi-watch.ts \
    .omp/extensions/fm-primary-turnend-guard.ts .omp/extensions/fm-primary-omp-watch.ts; do
    cmp -s "$dir/original/$file" "$dir/mate/$file" || fail "spawn/relaunch rewrote the primary adapter $file"
  done
  cmp -s "$dir/original/bin/fm-turnend-guard.sh" "$dir/mate/bin/fm-turnend-guard.sh" \
    || fail "spawn/relaunch changed the home's guard implementation"
  assert_absent "$dir/mate/.claude/settings.local.json" "secondmate observer replaced home-local Claude settings"
  assert_absent "$dir/home/state/sm1.turn-ended" "parent evidence duplicated the home's turn-end wake notification"
}

snapshot_consumer() {
  local dir=$1 harness=$2 dest=$3 loaded
  if [ "$harness" = claude ]; then
    cp "$dir/fake/settings.json" "$dest.json"
    return $?
  fi
  loaded=$(jq -er '.evidencePath' "$dir/fake/runtime.json") || fail "$harness launch did not import a semantic event consumer"
  case "$harness" in
    opencode) cp "$loaded" "$dest.js" ;;
    pi|pi-signed|omp) cp "$loaded" "$dest.ts" ;;
  esac
}

drive_consumer() {
  local harness=$1 path=$2 event=$3 cmd
  if [ "$harness" = claude ]; then
    case "$event" in start) event=UserPromptSubmit ;; close) event=Stop ;; failure) event=StopFailure ;; shutdown) event=SessionEnd ;; esac
    cmd=$(jq -er --arg event "$event" '.hooks[$event][] | .hooks[] | .command | select(contains("fm-busy-event.sh"))' "$path.json") || return 1
    CLAUDE_PROJECT_DIR="$(dirname "$path")/mate" FM_HOME="$(dirname "$path")/mate" \
      FM_FAKE_DIR="$(dirname "$path")/fake" GROK_AGENT= GROK_HOOK_EVENT= sh -c "$cmd"
    return $?
  fi
  HARNESS="$harness" CONSUMER="$path" EVENT="$event" node --input-type=module <<'JS'
import { pathToFileURL } from "node:url";
const harness = process.env.HARNESS;
const mod = await import(pathToFileURL(process.env.CONSUMER + (harness === "opencode" ? ".js" : ".ts")).href);
if (harness === "opencode") {
  const hooks = await mod.FmBusyState({});
  const status = (sessionID, type) => hooks.event({ event: { type: "session.status", properties: { sessionID, status: { type } } } });
  await status("main", "busy");
  if (process.env.EVENT === "continuing") {
    await status("child", "busy");
    await status("child", "idle");
  } else if (process.env.EVENT === "close") {
    await hooks.event({ event: { type: "session.idle", properties: { sessionID: "main" } } });
  }
} else {
  const handlers = {};
  mod.default({ on: (name, fn) => { handlers[name] = fn; }, events: { on() {} } });
  for (const name of ["turn_end", "session_stop", "tool_call"]) {
    if (handlers[name]) throw new Error("parent observer duplicated primary handler " + name);
  }
  if (process.env.EVENT === "start") {
    await handlers.agent_start({});
  } else if (harness === "omp") {
    await handlers.agent_end({ willContinue: process.env.EVENT === "continuing" }, { isIdle: () => false });
  } else {
    await handlers.agent_settled({}, { isIdle: () => process.env.EVENT !== "continuing" });
  }
}
JS
}

answer_request() {
  local dir=$1 corr
  corr=$(in_case "$dir" bash -c '. "$1/bin/fm-secondmate-restart-lib.sh"; fm_secondmate_restart_request_get "$FM_HOME/state/.secondmate-restart-sm1.request" corr' _ "$ROOT")
  [ -n "$corr" ] || fail "production restart did not publish a correlation"
  printf 'done [corr=%s]: open records written down\n' "$corr" >> "$dir/home/state/sm1.status"
}

assert_no_stop() {
  ! grep -Eq '^/(exit|quit)$' "$1/fake/literal" || fail "restart stopped the mate while its generated adapter still reported busy"
}

test_writer_restart_lifecycle() {
  local harness=$1 dir out gen spawn_gen source state rc calls
  dir=$(make_case "writer-$harness" "$harness")
  out=$(spawn_case "$dir") || fail "$harness production spawn failed: $out"
  state="$dir/home/state"
  assert_grep 'kind=secondmate' "$state/sm1.meta" "production spawn did not publish a secondmate record"
  gen=$(cat "$state/sm1.busy-gen") || fail "$harness did not arm its parent-owned generation"
  spawn_gen=$(fm_meta_get "$state/sm1.meta" spawn_gen)
  [ -n "$spawn_gen" ] || fail "production spawn did not publish its incarnation"
  [ "$(classify_case "$dir")" = 'busy fm-spawn' ] || fail "$harness launch did not seed busy semantic evidence"
  snapshot_consumer "$dir" "$harness" "$dir/old"
  case "$harness" in
    claude)
      jq -e '[.hooks.Stop[].hooks[] | select(.command | contains("fm-turnend-guard.sh"))] | length == 1' "$dir/old.json" >/dev/null \
        || fail "secondmate Claude launch duplicated its primary guard"
      jq -e --slurpfile original "$dir/original/.claude/settings.json" '
        .hooks.SessionStart == $original[0].hooks.SessionStart and
        .hooks.PreToolUse == $original[0].hooks.PreToolUse and
        .hooks.Stop[0].hooks[1:] == $original[0].hooks.Stop[0].hooks[1:]
      ' "$dir/old.json" >/dev/null || fail "Claude settings snapshot changed original hooks or autoarm options"
      jq -e '.settingSources == "user,local"' "$dir/fake/runtime.json" >/dev/null \
        || fail "Claude runtime loaded its snapshotted project hooks twice"
      source=claude-hook ;;
    opencode) source=opencode-plugin ;;
    pi|pi-signed)
      jq -e --arg parent "$state/sm1.pi-ext.ts" \
        --arg guard "$dir/mate/.pi/extensions/fm-primary-turnend-guard.ts" \
        --arg watch "$dir/mate/.pi/extensions/fm-primary-pi-watch.ts" '
          .extensions == [$parent, $guard, $watch] and .evidencePath == $parent and
          (.handlers | index("agent_start") != null and index("agent_settled") != null)
        ' "$dir/fake/runtime.json" >/dev/null || fail "Pi runtime did not load parent evidence alongside the home's primary extensions"
      source=pi-ext ;;
    omp)
      jq -e --arg parent "$state/sm1.omp-ext.ts" '
        .extensions == [$parent] and .evidencePath == $parent and
        (.handlers | index("agent_start") != null and index("agent_end") != null) and
        all(.configs[]; endswith("/fm-worker-overlay.yml") | not)
      ' "$dir/fake/runtime.json" >/dev/null || fail "omp runtime did not load parent evidence with secondmate memory posture"
      source=omp-ext ;;
  esac
  assert_primary_unchanged "$dir"
  drive_consumer "$harness" "$dir/old" start || fail "$harness generated start handler failed"
  [ "$(classify_case "$dir")" = "busy $source" ] || fail "$harness start did not publish trusted busy evidence"
  if [ "$harness" != claude ]; then
    drive_consumer "$harness" "$dir/old" continuing || fail "$harness continuing event failed"
    [ "$(classify_case "$dir")" = "busy $source" ] || fail "$harness continuation cleared busy prematurely"
  fi
  out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" sm1) || fail "restart admission failed: $out"
  assert_contains "$out" 'queued: sm1' "restart did not queue the production-spawned busy mate"
  answer_request "$dir"
  out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" --process-requests) || fail "busy request processing failed: $out"
  assert_present "$state/.secondmate-restart-sm1.request" "answered busy mate lost its queued restart"
  assert_no_stop "$dir"
  if [ "$harness" = claude ]; then
    printf '2\n' > "$dir/fake/guard-result"
    calls=$(wc -l < "$dir/fake/guard-calls")
    out=$(drive_consumer "$harness" "$dir/old" close 2>&1); rc=$?
    expect_code 2 "$rc" "rejected primary Stop did not propagate the guard's status"
    assert_contains "$out" 'guard stdout' "primary guard stdout was lost"
    assert_contains "$out" 'guard stderr' "primary guard stderr was lost"
    [ "$(wc -l < "$dir/fake/guard-calls")" -eq "$((calls + 1))" ] || fail "rejected Stop invoked the primary guard more than once"
    [ "$(classify_case "$dir")" = 'busy claude-hook' ] || fail "rejected primary Stop prematurely published parent idle"
    out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" --process-requests) || fail "rejected Stop request processing failed: $out"
    assert_present "$state/.secondmate-restart-sm1.request" "rejected primary Stop released the queued restart"
    assert_no_stop "$dir"
    printf '0\n' > "$dir/fake/guard-result"
  fi
  drive_consumer "$harness" "$dir/old" close || fail "$harness actual turn-close handler failed"
  if [ "$harness" = claude ]; then
    [ "$(wc -l < "$dir/fake/guard-calls")" -eq "$((calls + 2))" ] || fail "accepted Stop did not invoke the primary guard exactly once"
  fi
  [ "$(classify_case "$dir")" = "idle $source" ] || fail "$harness turn-close did not publish affirmative idle"
  assert_primary_unchanged "$dir"
  out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" --process-requests) || fail "released request processing failed: $out"
  assert_grep 'restarted: sm1' "$state/.secondmate-restart-sm1.outcome" "actual adapter close did not release the production restart: $out"
  assert_absent "$state/.secondmate-restart-sm1.request" "released restart remained queued"
  [ "$(cat "$state/sm1.busy-gen")" != "$gen" ] || fail "replacement did not mint a new busy generation"
  [ "$(fm_meta_get "$state/sm1.meta" spawn_gen)" != "$spawn_gen" ] || fail "replacement did not publish a new spawn incarnation"
  [ "$(classify_case "$dir")" = 'busy fm-spawn' ] || fail "replacement did not rearm busy launch evidence"
  drive_consumer "$harness" "$dir/old" close || fail "old $harness consumer broke its host lifecycle"
  [ "$(classify_case "$dir")" = 'busy fm-spawn' ] || fail "old $harness generation cleared the replacement's busy state"
  snapshot_consumer "$dir" "$harness" "$dir/new"
  drive_consumer "$harness" "$dir/new" close || fail "replacement $harness consumer failed"
  [ "$(classify_case "$dir")" = "idle $source" ] || fail "replacement consumer could not close its own generation"
  assert_primary_unchanged "$dir"
  pass "$harness production spawn queues busy restart, adapter close releases it, and replacement rejects stale events"
}

test_cursor_pull_binding() {
  local dir out state project old new
  dir=$(make_case cursor cursor)
  project="$dir/home/user-home/.cursor/projects/opaque-project"
  mkdir -p "$project/agent-transcripts/prior"
  printf '{"workspacePath":"%s"}\n' "$dir/mate" > "$project/.workspace-trusted"
  printf '{"role":"user"}\n{"type":"turn_ended","status":"success"}\n' > "$project/agent-transcripts/prior/prior.jsonl"
  out=$(spawn_case "$dir") || fail "Cursor production spawn failed: $out"
  state="$dir/home/state"
  assert_present "$state/sm1.cursor-session" "Cursor secondmate did not install its pull binding"
  assert_grep 'prior_conversation=prior' "$state/sm1.cursor-session" "Cursor binding did not exclude the prior incarnation"
  assert_absent "$state/sm1.busy-gen" "Cursor pull source seeded an unwritable busy record"
  [ "$(classify_case "$dir")" = 'unknown cursor-transcript' ] || fail "prior Cursor conversation was accepted as current"
  mkdir -p "$project/agent-transcripts/current"
  old="$project/agent-transcripts/current/current.jsonl"
  printf '{"role":"user"}\n' > "$old"
  [ "$(classify_case "$dir")" = 'busy cursor-transcript' ] || fail "current Cursor turn did not classify busy"
  out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" sm1) || fail "Cursor restart admission failed: $out"
  assert_contains "$out" 'queued: sm1' "Cursor busy restart did not queue"
  answer_request "$dir"
  out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" --process-requests) || fail "Cursor busy processing failed: $out"
  assert_present "$state/.secondmate-restart-sm1.request" "busy Cursor restart was not retained"
  assert_no_stop "$dir"
  printf '{"type":"turn_ended","status":"success"}\n' >> "$old"
  out=$(in_case "$dir" "$ROOT/bin/fm-secondmate-restart.sh" --process-requests) || fail "Cursor close processing failed: $out"
  assert_grep 'restarted: sm1' "$state/.secondmate-restart-sm1.outcome" "Cursor transcript close did not release the queued restart"
  assert_grep 'prior_conversation=current' "$state/sm1.cursor-session" "Cursor replacement did not rebind its incarnation"
  printf '{"type":"turn_ended","status":"success"}\n' >> "$old"
  [ "$(classify_case "$dir")" = 'unknown cursor-transcript' ] || fail "retired Cursor transcript settled the replacement"
  mkdir -p "$project/agent-transcripts/replacement"
  new="$project/agent-transcripts/replacement/replacement.jsonl"
  printf '{"role":"user"}\n' > "$new"
  [ "$(classify_case "$dir")" = 'busy cursor-transcript' ] || fail "replacement Cursor conversation did not classify busy"
  printf '{"type":"turn_ended","status":"success"}\n' >> "$new"
  [ "$(classify_case "$dir")" = 'idle cursor-transcript' ] || fail "replacement Cursor conversation did not close"
  assert_primary_unchanged "$dir"
  pass "Cursor production spawn/relaunch binds only its current conversation and releases restart on transcript turn-end"
}

test_unverified_launch_stays_unknown() {
  local dir out
  dir=$(make_case codex codex)
  out=$(spawn_case "$dir") || fail "Codex production spawn failed: $out"
  assert_absent "$dir/home/state/sm1.busy-gen" "unverified Codex secondmate armed semantic evidence"
  [ "$(classify_case "$dir")" = 'unknown codex-unverified' ] || fail "Codex secondmate fabricated turn evidence"
  dir=$(make_case raw-pi pi)
  out=$(in_case "$dir" "$ROOT/bin/fm-spawn.sh" sm1 "$dir/mate" 'pi --unverified-launch' --secondmate) \
    || fail "raw Pi secondmate spawn failed: $out"
  assert_absent "$dir/home/state/sm1.busy-gen" "raw Pi launch armed evidence without a verified loaded adapter"
  [ "$(classify_case "$dir")" = 'unknown missing' ] || fail "raw Pi secondmate fabricated semantic evidence"
  dir=$(make_case unknown-primary claude)
  printf '{"hooks":{"Stop":[]}}\n' > "$dir/mate/.claude/settings.json"
  out=$(spawn_case "$dir") || fail "unknown primary configuration refused an otherwise valid launch: $out"
  assert_absent "$dir/home/state/sm1.busy-gen" "unknown primary guard configuration armed an unsafe Stop observer"
  [ "$(classify_case "$dir")" = 'unknown missing' ] || fail "unknown primary guard configuration fabricated idle evidence"
  pass "unverified adapters, raw launches, and unknown primary guard configuration stay unknown"
}

test_unknown_primary_relaunch_retires_evidence() {
  local dir out
  dir=$(make_case unknown-primary-relaunch claude)
  out=$(spawn_case "$dir") || fail "known Claude production spawn failed: $out"
  snapshot_consumer "$dir" claude "$dir/old"
  printf '{"hooks":{"Stop":[]}}\n' > "$dir/mate/.claude/settings.local.json"
  cp "$dir/mate/.claude/settings.local.json" "$dir/local-settings.json"
  printf 'zsh\n' > "$dir/fake/command"
  out=$(in_case "$dir" "$ROOT/bin/fm-spawn.sh" sm1 --relaunch) || fail "unverified primary relaunch failed: $out"
  cmp -s "$dir/local-settings.json" "$dir/mate/.claude/settings.local.json" \
    || fail "relaunch removed or rewrote the secondmate's local settings"
  assert_absent "$dir/home/state/sm1.busy-gen" "unverified replacement retained its predecessor's generation"
  drive_consumer claude "$dir/old" close || fail "retired Claude consumer broke the primary guard"
  [ "$(classify_case "$dir")" = 'unknown missing' ] || fail "retired Claude consumer settled an unverified replacement"
  pass "unknown primary configuration on production relaunch preserves local settings and retires old evidence"
}

for harness in claude opencode pi pi-signed omp; do
  test_writer_restart_lifecycle "$harness"
done
test_cursor_pull_binding
test_unverified_launch_stays_unknown
test_unknown_primary_relaunch_retires_evidence
