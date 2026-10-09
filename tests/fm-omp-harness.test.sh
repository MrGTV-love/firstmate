#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - the portable regression for the omp (Oh My Pi)
# adapter: detection, session-lock identity, tmux liveness classification, the
# spawn launch line and worker posture overlay, pre-launch model validation, the
# per-task busy-state extension, the extension supervision model and ownership
# proof, and the two tracked primary extensions driven over a fake omp API.
#
# omp's identity, launch, and lifecycle checks are HARNESS-DEPENDENT: their
# verdicts come from what the vendor emits (a process name, a settings schema,
# an extension event). This suite pins the LOGIC with real processes, a fake
# omp binary, and a plain Node host, so CI enforces it with no omp installed;
# FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh is the live guard that
# catches vendor drift against a real omp. Neither replaces the other.
#
# The load-bearing contracts:
#   1. omp publishes no marker; the anchored process name `omp` is the ancestry
#      evidence, and ompd/comp never identify.
#   2. FM_OMP_HARNESS=omp is a precedence override that needs a real omp
#      ancestor: it beats an inherited CLAUDECODE under omp and is inert when it
#      leaks into a worker whose ancestry holds no omp.
#   3. Every omp launch clears foreign markers, carries the tracked posture
#      overlay, --auto-approve, and --cwd.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp and delivers an
#      actionable close as one follow-up.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
export NODE_NO_WARNINGS=1
export PI_CODING_AGENT_DIR=
export OMP_PROFILE='' PI_PROFILE=''

# A process whose kernel-recorded identity is the bare name `omp`: a SYMLINK to
# the system shell, never a copy (a copied platform binary fails macOS code
# signing). macOS reports the symlink name through `ps -o comm=`, which is the
# exact signal under test. Every `-c` body below ends in a no-op so bash does
# not exec-optimize the single command away and replace the named process.
make_named_shells() {  # <dir> -> echoes <bindir>
  local dir=$1 name
  mkdir -p "$dir"
  for name in omp ompd comp; do
    ln -sf /bin/bash "$dir/$name"
  done
  printf '%s' "$dir"
}

# --- 1. Detection --------------------------------------------------------------

test_detection_anchored_name_and_marker_precedence() {
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      "$bin/$decoy" -c '"$1"; :' _ "$HARNESS")
    [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    "$bin/omp" -c '"$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    bash -c '"$1"; :' _ "$HARNESS")
  [ "$out" = claude ] || fail "a leaked FM_OMP_HARNESS without an omp ancestor must not relabel a claude worker, got '$out'"
  pass "fm-harness: omp detects by its anchored name; the marker is a precedence override that needs real omp ancestry"
}

test_lock_identity_and_liveness_classification() {
  fm_harness_process_matches omp '' || fail "session-lock identity must accept the exact omp name"
  fm_harness_process_matches /usr/local/bin/omp 'omp --cwd /x' || fail "session-lock identity must accept an omp path"
  ! fm_harness_process_matches ompd '' || fail "session-lock identity must not accept ompd"
  ! fm_harness_process_matches comp '' || fail "session-lock identity must not accept comp"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  [ "$(fm_agent_process_classify_name omp)" = agent ] || fail "tmux liveness must classify omp as an agent"
  [ "$(fm_agent_process_classify_name /opt/omp/bin/omp)" = agent ] || fail "tmux liveness must classify an omp path as an agent"
  [ "$(fm_agent_process_classify_name ompd)" != agent ] || fail "tmux liveness must not classify ompd as an agent"
  [ "$(fm_agent_process_classify_name comp)" != agent ] || fail "tmux liveness must not classify comp as an agent"
  pass "session lock and tmux liveness: omp is anchored, decoys stay out"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog and exits
# 0 for everything else (the launch itself is only recorded by the fake tmux).
make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_OMP_ENV_LOG:-}" ]; then
  printf '%s:%s\n' "${1:-launch}" "${PI_CODING_AGENT_DIR:-}" >> "$FM_FAKE_OMP_ENV_LOG"
fi
case "$1" in
  models)
    if [ -f "${PI_CODING_AGENT_DIR:-}/catalog.json" ]; then
      cat "$PI_CODING_AGENT_DIR/catalog.json"
      exit 0
    fi
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

make_spawn_case() {  # <name> <harness> <id> [project-name]
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/${4-project}"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  make_fake_omp "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$case_dir/launch.log"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
  GLOBAL_CONFIG="$HOME_DIR/user-home/.omp/agent/config.yml"
  mkdir -p "$(dirname "$GLOBAL_CONFIG")"
}

run_scout_spawn() {  # <home> <wt> <fakebin> <launch-log> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --scout
}

test_spawn_launch_line_and_worker_wiring() {
  local rec id=omp-launch-q1 out status launch state
  rec=$(make_spawn_case launch omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_contains "$launch" "--config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --cwd '$WT_DIR' --config '$ROOT/.omp/fm-worker-overlay.yml'" \
    "omp scout launch did not carry shared posture and worker-only memory overlays"
  assert_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  case "$launch" in
    *"-e '$state/$id.omp-ext.ts' \"\$("*) ;;
    *) fail "omp launch must keep exactly one positional brief after the extension flag: $launch" ;;
  esac
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_worker_replace_mode_environment() {
  local kind rec id out status launch seen
  for kind in ship scout; do
    id="omp-replace-$kind-q1"
    rec=$(make_spawn_case "replace-$kind" omp "$id")
    read_case_record "$rec"
    if [ "$kind" = ship ]; then
      out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        "$id" "$PROJ_DIR" --harness omp --mode no-mistakes --yolo off)
    else
      : > "$HOME_DIR/config/launch-env-allowlist"
      out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
    fi
    status=$?
    expect_code 0 "$status" "omp $kind spawn should succeed: $out"
    cat > "$FAKEBIN_DIR/omp" <<'SH'
#!/bin/sh
printf '%s\n' "${PI_EDIT_VARIANT-unset}"
SH
    launch=$(cat "$LAUNCH_LOG")
    seen=$(env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" PI_EDIT_VARIANT=hashline \
      /bin/sh -c "$launch
printf '%s\n' \"\$PI_EDIT_VARIANT\"") \
      || fail "omp $kind emitted launch failed"
    [ "$seen" = $'replace\nhashline' ] \
      || fail "omp $kind must use replace mode without changing the pane environment, got: $seen"
  done
  pass "omp ship and scout launches select replace edit mode only in the worker process"
}

test_worker_guard_project_scope() {
  local project rec id out
  for project in firstmate vernant; do
    id="omp-scope-$project"
    rec=$(make_spawn_case "scope-$project" omp "$id" "$project")
    read_case_record "$rec"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
    expect_code 0 $? "omp $project spawn should succeed: $out"
    printf 'TYPESAFE_API_KEY=omp-scope-key\nOPENROUTER_API_KEY=omp-fallback-key\n' > "$HOME_DIR/.env"
    out=$(EXT_PATH="$HOME_DIR/state/$id.omp-ext.ts" PROJECT="$project" WT="$WT_DIR" FM_TEST_SEAM=1 \
      node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
const requests = [];
const server = createServer((req, res) => {
  let body = "";
  req.on("data", chunk => { body += chunk; });
  req.on("end", () => {
    requests.push({ path: req.url, state: JSON.parse(body).state });
    if (req.url === "/direct") { res.writeHead(500).end("{}"); return; }
    const answers = {};
    for (const [id, q] of Object.entries(JSON.parse(body).questions)) {
      const keys = Object.keys(q.criteria ?? {});
      const choice = keys.includes("irreversible") ? "irreversible" : keys[0];
      answers[id] = q.type === "noul" ? { type: "noul", noul: 0.95 }
        : { type: "choice", choice, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === choice ? 1 : 0])) };
    }
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ model: "jev-fake", answers, usage: { input_tokens: 3, output_tokens: 1 } }));
  });
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
try {
  const base = `http://127.0.0.1:${server.address().port}`;
  process.env.FM_JEV_GUARD_BASE_URL = `${base}/direct`;
  process.env.FM_JEV_GUARD_OPENROUTER_URL = `${base}/fallback`;
  const handlers = {};
  (await import(pathToFileURL(process.env.EXT_PATH))).default({ on: (name, fn) => { handlers[name] = fn; } });
  const result = await handlers.tool_call({ toolName: "bash", input: { command: "rm -rf customer-record" } }, { cwd: process.env.WT });
  if (process.env.PROJECT === "firstmate") {
    assert.equal(result?.block, true);
    assert.deepEqual(requests.map(row => row.path), ["/direct", "/fallback"]);
    assert.ok(requests.every(row => row.state.command === "rm -rf customer-record"));
  } else {
    assert.equal(result, undefined);
    assert.deepEqual(requests, []);
  }
} finally {
  await new Promise(resolve => server.close(resolve));
}
console.log("scope-ok");
JS
)
    [ "$out" = scope-ok ] || fail "generated omp extension lost $project egress scope: $out"
  done
  pass "real omp spawns authorize firstmate only and carry project scope through the generated extension"
}

test_spawn_model_validation_scoped_to_listed_providers() {
  local rec id out status
  rec=$(make_spawn_case model-refused omp omp-model-refused-q2)
  read_case_record "$rec"
  id=omp-model-refused-q2
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id=omp-model-bridge-q3
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id=omp-model-fuzzy-q4
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

# omp's default role lives in one global file that every interactive omp session
# can rewrite. A launch with no --model reads it, and a missing or unlisted role
# makes omp silently pick the first credentialed model (a free-tier model that
# answers HTTP 429). The launch must refuse with the remedy instead.
test_spawn_refuses_a_missing_or_unlisted_default_role() {
  local rec id out status
  rec=$(make_spawn_case role-missing omp omp-role-missing-q5)
  read_case_record "$rec"
  id=omp-role-missing-q5
  printf 'modelRoles:\n  advisor: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "an omp launch with no model and no default role must refuse: $out"
  assert_contains "$out" "omp modelRoles.default is not set in the shared omp config" "refusal did not name the missing role"
  assert_contains "$out" "pass --model <provider>/<id>" "refusal did not carry the remedy"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must record no launch: $(cat "$LAUNCH_LOG")"

  rec=$(make_spawn_case role-unlisted omp omp-role-unlisted-q6)
  read_case_record "$rec"
  id=omp-role-unlisted-q6
  printf 'modelRoles:\n  default: openai-codex/gpt-gone:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "a default role naming an unlisted id must refuse: $out"
  assert_contains "$out" "omp modelRoles.default 'openai-codex/gpt-gone:high' is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the unresolvable role"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case role-listed omp omp-role-listed-q7)
  read_case_record "$rec"
  id=omp-role-listed-q7
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "a listed default role (thinking suffix included) must launch: $out"

  rec=$(make_spawn_case role-pinned omp omp-role-pinned-q8)
  read_case_record "$rec"
  id=omp-role-pinned-q8
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra)
  status=$?
  expect_code 0 "$status" "a launch that passes --model never reads the default role: $out"

  rec=$(make_spawn_case role-bridge omp omp-role-bridge-q10)
  read_case_record "$rec"
  id=omp-role-bridge-q10
  printf 'modelRoles:\n  default: claude-bridge/claude-opus-4-8:high\n' > "$GLOBAL_CONFIG"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "an unknown default-role provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "default-role pass-through did not state its reason"
  assert_contains "$out" "launching 'claude-bridge/claude-opus-4-8:high' unvalidated" "notice did not identify the default role"
  assert_present "$HOME_DIR/state/$id.meta" "default-role pass-through must publish the task"

  rec=$(make_spawn_case role-unreadable omp omp-role-unreadable-q9)
  read_case_record "$rec"
  id=omp-role-unreadable-q9
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "an unreadable roles config establishes nothing and must launch: $out"
  pass "fm-spawn: an omp launch with no model refuses a missing or unlisted default role and names the remedy"
}

test_spawn_global_config_is_read_only_and_unlayered() {
  local rec id out status agent_dir
  id=omp-role-project-q11
  rec=$(make_spawn_case role-project omp "$id")
  read_case_record "$rec"
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  mkdir -p "$PROJ_DIR/.omp"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$PROJ_DIR/.omp/config.yml"
  out=$(cd "$PROJ_DIR" && run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "a project-layer default must not mask a missing global default: $out"
  assert_contains "$out" "omp modelRoles.default is not set in the shared omp config" "project-layer refusal did not identify the missing global role"
  assert_contains "$out" "pass --model <provider>/<id> (or a dispatch profile) so this launch stops depending on the shared default, or restore the Default role in omp with /model" "project-layer refusal lost the exact remedy"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused project-layer spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused project-layer spawn must record no launch"

  id=omp-role-malformed-q12
  rec=$(make_spawn_case role-malformed omp "$id")
  read_case_record "$rec"
  printf 'modelRoles:\n  default: [unterminated\n' > "$GLOBAL_CONFIG"
  cp "$GLOBAL_CONFIG" "$CASE_DIR/original-config.yml"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "a malformed global config establishes nothing and must pass through: $out"
  cmp -s "$CASE_DIR/original-config.yml" "$GLOBAL_CONFIG" || fail "the malformed global config must remain byte-identical"
  for out in "$GLOBAL_CONFIG".broken-*; do
    assert_absent "$out" "the global config must not be quarantined"
  done
  assert_present "$HOME_DIR/state/$id.meta" "malformed-config pass-through must publish the task"
  assert_contains "$(cat "$LAUNCH_LOG")" "'$FAKEBIN_DIR/omp'" "malformed-config pass-through must reach the launch"

  id=omp-role-agent-dir-q13
  rec=$(make_spawn_case role-agent-dir omp "$id")
  read_case_record "$rec"
  printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
  agent_dir="$CASE_DIR/custom-agent"
  mkdir -p "$agent_dir"
  printf 'modelRoles:\n  default: ollama/qwen3:8b:max\n' > "$agent_dir/config.yml"
  printf 'FM_FAKE_OMP_ENV_LOG\n' > "$HOME_DIR/config/launch-env-allowlist"
  out=$(PI_CODING_AGENT_DIR="$agent_dir" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
    run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 0 "$status" "the selected agent dir must supply the global default, preserving model-id colons: $out"
  assert_present "$HOME_DIR/state/$id.meta" "a listed agent-dir default must publish the task"
  HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$CASE_DIR/pane-agent" \
    PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
    bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
  status=$?
  expect_code 0 "$status" "the canonical launch must execute in a pane with a different agent directory"
  assert_grep "models:$agent_dir" "$CASE_DIR/omp-env.log" "catalog inspection must use the canonical launch directory"
  assert_grep "--config:$agent_dir" "$CASE_DIR/omp-env.log" "the launched omp must receive the checked directory despite pane inheritance and filtering"

  id=omp-role-agent-dir-missing-q14
  rec=$(make_spawn_case role-agent-dir-missing omp "$id")
  read_case_record "$rec"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$GLOBAL_CONFIG"
  agent_dir="$CASE_DIR/custom-agent"
  mkdir -p "$agent_dir"
  printf '{}\n' > "$agent_dir/config.yml"
  out=$(PI_CODING_AGENT_DIR="$agent_dir" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  status=$?
  expect_code 1 "$status" "the HOME default must not mask a missing default in the selected agent dir: $out"
  assert_contains "$out" "omp modelRoles.default is not set" "agent-dir refusal did not identify the missing role"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused agent-dir spawn must publish no record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused agent-dir spawn must record no launch"
  pass "fm-spawn: global role inspection is read-only, unlayered, and honors PI_CODING_AGENT_DIR"
}

test_spawn_raw_omp_guard_uses_the_launch_agent_dir() {
  local rec id out status caller_dir launch_dir mode command
  for mode in missing listed unlisted uncertain stderr stdin append descriptor; do
    id="omp-raw-agent-$mode"
    rec=$(make_spawn_case "raw-agent-$mode" omp "$id")
    read_case_record "$rec"
    caller_dir="$CASE_DIR/caller-agent"
    launch_dir="$CASE_DIR/launch-agent"
    mkdir -p "$caller_dir" "$launch_dir"
    printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$caller_dir/config.yml"
    printf 'modelRoles: {}\n' > "$launch_dir/config.yml"
    case "$mode" in
      listed)
        printf 'modelRoles: {}\n' > "$caller_dir/config.yml"
        printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$launch_dir/config.yml"
        ;;
      unlisted)
        printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$launch_dir/config.yml"
        printf '%s\n' '{"models":[{"provider":"openai-codex","id":"other","selector":"openai-codex/other"}]}' > "$launch_dir/catalog.json"
        ;;
      uncertain)
        printf 'modelRoles: {}\n' > "$caller_dir/config.yml"
        ;;
    esac
    command="PI_CODING_AGENT_DIR='$launch_dir' omp --auto-approve"
    # shellcheck disable=SC2016 # The pane expands this variable when executing the raw command.
    [ "$mode" != uncertain ] || command='PI_CODING_AGENT_DIR="$PANE_AGENT_DIR" omp --auto-approve'
    case "$mode" in
      stderr) command="$command 2>'$CASE_DIR/errors.log'" ;;
      stdin) command="$command <'$launch_dir/config.yml'" ;;
      append) command="$command >>'$CASE_DIR/output.log'" ;;
      descriptor) command="$command 2>&1" ;;
    esac
    out=$(PI_CODING_AGENT_DIR="$caller_dir" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
      run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
    status=$?
    case "$mode" in
      missing | unlisted | stderr | stdin | append | descriptor)
        expect_code 1 "$status" "raw omp must refuse the launch directory's invalid role ($mode): $out"
        assert_absent "$HOME_DIR/state/$id.meta" "a refused raw-directory launch must publish no record"
        [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw-directory launch must record no launch"
        if [ "$mode" != unlisted ]; then
          assert_contains "$out" "omp modelRoles.default is not set" "raw assignment must not read the caller's listed role"
        else
          assert_contains "$out" "is not listed by 'omp models --json'" "raw catalog must use the launch directory"
          assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "raw catalog must receive the launch directory"
        fi
        ;;
      listed | uncertain)
        expect_code 0 "$status" "raw omp must launch with a listed or uncertain directory ($mode): $out"
        HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$caller_dir" PANE_AGENT_DIR="$launch_dir" \
          PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
          bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
        status=$?
        expect_code 0 "$status" "the raw command must execute unchanged"
        assert_grep "--auto-approve:$launch_dir" "$CASE_DIR/omp-env.log" "raw omp must receive its assignment rather than the caller directory"
        if [ "$mode" = listed ]; then
          assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "the role and catalog must inspect the same directory"
        else
          ! grep -q '^models:' "$CASE_DIR/omp-env.log" || fail "uncertain directory must establish no catalog evidence"
        fi
        ;;
    esac
  done
  pass "fm-spawn: raw role and catalog inspection honor the actual launch directory and uncertain evidence passes through"
}

test_spawn_omp_profiles_leave_directory_evidence_unreadable() {
  local rec id out status mode role command first_arg omp_profile pi_profile launch_dir
  local spawn_args=()
  for mode in flag flag-equals assignment-omp assignment-pi env-omp env-pi raw-env-omp raw-env-pi; do
    for role in missing unlisted; do
      id="omp-profile-$mode-$role"
      rec=$(make_spawn_case "profile-$mode-$role" omp "$id")
      read_case_record "$rec"
      launch_dir="$CASE_DIR/launch-agent"
      mkdir -p "$launch_dir"
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$launch_dir/config.yml"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$launch_dir/config.yml"
      fi
      omp_profile='' pi_profile=''
      command="PI_CODING_AGENT_DIR='$launch_dir' omp --auto-approve"
      first_arg=--auto-approve
      case "$mode" in
        flag) command="$command --profile work" ;;
        flag-equals) command="$command --profile=work" ;;
        assignment-omp) command="OMP_PROFILE=work $command" ;;
        assignment-pi) command="PI_PROFILE=work $command" ;;
        env-omp | raw-env-omp) omp_profile=work ;;
        env-pi | raw-env-pi) pi_profile=work ;;
      esac
      spawn_args=("$command")
      case "$mode" in
        env-omp | env-pi)
          spawn_args=(--harness omp)
          first_arg=--config
          ;;
      esac
      out=$(OMP_PROFILE="$omp_profile" PI_PROFILE="$pi_profile" PI_CODING_AGENT_DIR="$launch_dir" \
        FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "${spawn_args[@]}")
      status=$?
      expect_code 0 "$status" "profile selection must pass through an unrelated $role default ($mode): $out"
      assert_present "$HOME_DIR/state/$id.meta" "a profile-selecting launch must publish the task"
      assert_absent "$CASE_DIR/omp-env.log" "profile selection must establish no catalog evidence"
      case "$mode" in
        env-omp | env-pi) ;;
        *) assert_contains "$(cat "$LAUNCH_LOG")" "$command" "the raw profile-selecting command must reach the launch unchanged" ;;
      esac
      HOME="$HOME_DIR/user-home" PI_CODING_AGENT_DIR="$launch_dir" \
        OMP_PROFILE="$omp_profile" PI_PROFILE="$pi_profile" \
        PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
      status=$?
      expect_code 0 "$status" "the profile-selecting launch must execute ($mode)"
      assert_grep "$first_arg:$launch_dir" "$CASE_DIR/omp-env.log" "profile selection must still launch omp ($mode)"
    done
  done
  pass "fm-spawn: omp profile flags, assignments, and invoking environment pass through without default-role catalog probes"
}

test_spawn_raw_omp_expansions_pass_through_unchanged() {
  local rec id out status mode role command launch_dir first_arg
  for mode in profile after-delimiter substitution backticks redirect glob long-glob tilde tilde-redirection tilde-user tilde-assignment process ansi locale braces heredoc punctuation; do
    for role in missing unlisted; do
      id="omp-expansion-$mode-$role"
      rec=$(make_spawn_case "expansion-$mode-$role" omp "$id")
      read_case_record "$rec"
      launch_dir=$(dirname "$GLOBAL_CONFIG")
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$GLOBAL_CONFIG"
      fi
      command="PI_CODING_AGENT_DIR='$launch_dir' omp"
      first_arg=--auto-approve
      case "$mode" in
        profile)
          command="$command \"\$PROFILE_FLAG\" --auto-approve"
          first_arg=--profile=work
          ;;
        after-delimiter) command="$command --auto-approve -- \"\$PROFILE_FLAG\"" ;;
        substitution)
          command="$command \"\$(printf evaluated > '$CASE_DIR/expanded'; printf %s --profile=work)\" --auto-approve"
          first_arg=--profile=work
          ;;
        backticks)
          command="$command \"\`printf evaluated > '$CASE_DIR/expanded'; printf %s --profile=work\`\" --auto-approve"
          first_arg=--profile=work
          ;;
        redirect) command="$command --auto-approve 2>\"\$ERROR_LOG\"" ;;
        glob)
          printf 'input\n' > "$CASE_DIR/input.txt"
          command="$command --auto-approve '$CASE_DIR'/*.txt"
          ;;
        long-glob)
          command="$command --auto-approve /work/vernant/generated/reports/abcdefghijklmnopqrstuvwxyz0123456789/input*.txt"
          {
            printf '#!/usr/bin/env bash\n. %q\n' "$ROOT/bin/fm-timeout-lib.sh"
            printf 'exec 3<&0\nfm_run_timed 3 bash -c '\''exec "$@" <&3'\'' _ %q "$@"\n' "$(command -v node)"
            # shellcheck disable=SC2016 # Capture status in the generated wrapper, not while generating it.
            printf 'status=$?\nprintf "%%s\\n" "$status" > %q\n' "$CASE_DIR/node-status"
            # shellcheck disable=SC2016 # The generated wrapper evaluates its own status.
            printf 'if fm_timed_out "$status"; then printf timeout > %q; fi\nexit "$status"\n' "$CASE_DIR/node-timeout"
          } > "$FAKEBIN_DIR/node"
          chmod +x "$FAKEBIN_DIR/node"
          ;;
        tilde) command="$command --auto-approve ~/input.txt" ;;
        tilde-redirection) command="$command --auto-approve 2>~/omp-errors.log" ;;
        tilde-user) command="$command --auto-approve ~root/input.txt" ;;
        tilde-assignment) command="EXTRA_DIR=~ $command --auto-approve" ;;
        process) command="$command --auto-approve <(printf input)" ;;
        ansi) command="$command --auto-approve \$'input'" ;;
        locale) command="$command --auto-approve \$\"input\"" ;;
        braces) command="$command --auto-approve {a,b}" ;;
        heredoc) command="$command --auto-approve <<'EOF'
input
EOF" ;;
        punctuation) command="$command --auto-approve input!" ;;
      esac
      out=$(FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
      status=$?
      assert_absent "$CASE_DIR/node-timeout" "a long literal prefix ending in a glob must classify within three seconds"
      if [ "$mode" = long-glob ]; then
        expect_code 1 "$(cat "$CASE_DIR/node-status")" "the validator must execute and reject the glob as unreadable evidence"
      fi
      expect_code 0 "$status" "a raw shell expansion must pass through the $role role ($mode): $out"
      assert_present "$HOME_DIR/state/$id.meta" "expanded raw launch must publish the task"
      assert_absent "$CASE_DIR/omp-env.log" "expanded raw launch must establish no catalog evidence"
      assert_absent "$CASE_DIR/expanded" "validation must not evaluate command substitutions"
      assert_absent "$CASE_DIR/errors.log" "validation must not evaluate redirections"
      assert_contains "$(cat "$LAUNCH_LOG")" "$command" "expanded raw command must reach the launch unchanged"
      HOME="$HOME_DIR/user-home" PROFILE_FLAG=--profile=work ERROR_LOG="$CASE_DIR/errors.log" \
        PATH="$FAKEBIN_DIR:$PATH" FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        bash "$LAUNCH_LOG" > "$CASE_DIR/pane-output.log" 2>&1
      status=$?
      expect_code 0 "$status" "expanded raw command must execute in the pane ($mode)"
      assert_grep "$first_arg:$launch_dir" "$CASE_DIR/omp-env.log" "expanded raw command must launch omp in its assigned directory"
      case "$mode" in
        substitution | backticks)
          [ "$(cat "$CASE_DIR/expanded")" = evaluated ] || fail "the pane must evaluate the command substitution"
          ;;
        redirect) assert_present "$CASE_DIR/errors.log" "the pane must evaluate the redirection" ;;
        tilde-redirection) assert_present "$HOME_DIR/user-home/omp-errors.log" "the pane must expand the tilde redirection" ;;
      esac
    done
  done
  pass "fm-spawn: any expanded raw token passes through unchanged without evaluating it or probing the default-role catalog"
}

test_spawn_raw_omp_literal_evidence_still_refuses() {
  local rec id out status quoting role command launch_dir
  for quoting in unquoted single double; do
    for role in missing unlisted; do
      id="omp-literal-$quoting-$role"
      rec=$(make_spawn_case "literal-$quoting-$role" omp "$id")
      read_case_record "$rec"
      launch_dir=$(dirname "$GLOBAL_CONFIG")
      if [ "$role" = missing ]; then
        printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
      else
        printf 'modelRoles:\n  default: openai-codex/gpt-gone\n' > "$GLOBAL_CONFIG"
      fi
      case "$quoting" in
        unquoted) command="PI_CODING_AGENT_DIR=$launch_dir omp --auto-approve 2>$CASE_DIR/errors.log" ;;
        single) command="PI_CODING_AGENT_DIR='$launch_dir' omp '--auto-approve' 'literal ~ \$ value' 2>'$CASE_DIR/errors.log'" ;;
        double) command="PI_CODING_AGENT_DIR=\"$launch_dir\" omp \"--auto-approve\" \"literal ~ value\" 2>\"$CASE_DIR/errors.log\"" ;;
      esac
      out=$(FM_FAKE_OMP_ENV_LOG="$CASE_DIR/omp-env.log" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
      status=$?
      expect_code 1 "$status" "literal-only raw command must refuse the $role role ($quoting): $out"
      assert_contains "$out" "error: omp modelRoles.default" "literal evidence must reach the default-role guard"
      assert_absent "$HOME_DIR/state/$id.meta" "a refused literal launch must publish no record"
      [ ! -s "$LAUNCH_LOG" ] || fail "a refused literal launch must record no command"
      assert_absent "$CASE_DIR/errors.log" "validation must not execute a literal redirection"
      if [ "$role" = unlisted ]; then
        assert_grep "models:$launch_dir" "$CASE_DIR/omp-env.log" "literal evidence must probe the launch directory's catalog"
      else
        assert_absent "$CASE_DIR/omp-env.log" "a missing literal default must refuse without a catalog probe"
      fi
    done
  done
  pass "fm-spawn: unquoted, single-quoted, and double-quoted literal evidence still refuses invalid defaults"
}

test_spawn_raw_omp_guard_uses_the_launch_model() {
  # Inline replacement quotes are removed by Bash 5.2; variable contents stay literal.
  local rec id out status command expected index=0 model_flag="--model 'openai-codex/gpt-6-astra' "
  local model_args=()
  while IFS='|' read -r command expected; do
    index=$((index + 1))
    id="omp-raw-role-$index"
    rec=$(make_spawn_case "raw-role-$index" omp "$id")
    read_case_record "$rec"
    printf 'modelRoles: {}\n' > "$GLOBAL_CONFIG"
    model_args=()
    case "$command" in
      *'__MODELFLAG__'* | 'omp --auto-approve') model_args=(--model openai-codex/gpt-6-astra) ;;
    esac
    command="PI_CODING_AGENT_DIR='$(dirname "$GLOBAL_CONFIG")' $command"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command" ${model_args[@]+"${model_args[@]}"})
    status=$?
    expect_code "$expected" "$status" "raw omp guard must follow the effective model in '$command': $out"
    if [ "$expected" = 0 ]; then
      assert_present "$HOME_DIR/state/$id.meta" "a pinned raw launch must publish the task"
      assert_contains "$(cat "$LAUNCH_LOG")" "${command//__MODELFLAG__/$model_flag}" "raw model selection did not reach the launch"
    else
      assert_contains "$out" "omp modelRoles.default is not set" "an unpinned raw launch must refuse the missing role"
      assert_absent "$HOME_DIR/state/$id.meta" "a refused raw launch must publish no record"
      [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw launch must record no launch"
    fi
  done <<'CASES'
omp --model openai-codex/gpt-6-astra|0
omp --model='openai-codex/gpt-6-astra'|0
omp -m 'openai-codex/gpt-6-astra'|0
omp __MODELFLAG__|0
omp --model default|0
omp --auto-approve|1
omp -- '--model' 'openai-codex/gpt-6-astra'|1
omp '--model openai-codex/gpt-6-astra'|1
CASES
  pass "fm-spawn: raw omp launches validate the default only without an effective model override"
}

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  mkdir -p "$world/user-home/.omp/agent"
  printf 'modelRoles:\n  default: openai-codex/gpt-6-astra:high\n' > "$world/user-home/.omp/agent/config.yml"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  # FM_BACKEND=tmux pins the fake tmux even where the developer shell carries a
  # live Herdr environment; without it auto-detection would spawn a real pane.
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" omp --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "omp secondmate spawn should succeed: $out"
  assert_grep "harness=omp" "$world/home/state/sm.meta" "secondmate meta missing harness=omp"
  launch=$(cat "$launchlog")
  case "$launch" in
    *" -e "*) fail "an omp secondmate launch must name no -e: omp auto-discovers .omp/extensions and a file named both ways loads twice: $launch" ;;
  esac
  assert_contains "$launch" "--config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --cwd '$home'" "secondmate launch lost the posture overlay or the pinned home directory: $launch"
  assert_not_contains "$launch" "fm-worker-overlay.yml" "secondmate launch must preserve the lane's memory settings"
  assert_contains "$launch" "FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$fakebin/omp'" "secondmate launch lost the omp marker or executable"
  assert_contains "$launch" "FM_SUPERVISION_MODEL=extension" "an omp secondmate must run the extension supervision model"
  assert_absent "$world/home/state/sm.omp-ext.ts" "a secondmate must not receive a per-task worker extension"
  pass "fm-spawn: a real omp secondmate launch preserves primary posture and supervision"
}

test_secondmate_config_pinned_model_is_validated() {
  # The same seeded secondmate home, but the harness and model come from the
  # primary's config/secondmate-harness rather than the command line: the
  # durable pin lands on MODEL after the harness case arm, so an unlisted id
  # under a listed provider must still be refused before endpoint creation.
  local world home fakebin launchlog out status
  world="$TMP_ROOT/secondmate-config-model"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
  mkdir -p "$world/user-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  printf 'omp openai-codex/gpt-nope\n' > "$world/home/config/secondmate-harness"
  fakebin=$(make_spawn_fakebin "$world/fake" claude)
  make_fake_omp "$fakebin"
  launchlog="$world/launch.log"
  : > "$launchlog"
  out=$(PATH="$fakebin:$PATH" TMUX='fake,1,0' FM_BACKEND=tmux CLAUDECODE=1 \
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" HOME="$world/user-home" \
    FM_STATE_OVERRIDE="$world/home/state" FM_DATA_OVERRIDE="$world/home/data" \
    FM_PROJECTS_OVERRIDE="$world/home/projects" FM_CONFIG_OVERRIDE="$world/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LAUNCH_LOG="$launchlog" \
    "$ROOT/bin/fm-spawn.sh" sm "$home" --secondmate 2>&1)
  status=$?
  expect_code 1 "$status" "a config-pinned unlisted omp model must refuse the secondmate spawn: $out"
  assert_contains "$out" "omp model 'openai-codex/gpt-nope' is not listed by 'omp models --json' although provider 'openai-codex' is" \
    "the refusal did not name the config-pinned model under its listed provider: $out"
  assert_absent "$world/home/state/sm.meta" "a refused secondmate spawn must publish no sm.meta"
  [ ! -s "$launchlog" ] || fail "a refused secondmate spawn must record no launch: $(cat "$launchlog")"
  pass "fm-spawn: the config/secondmate-harness model pin is validated against the omp catalog before launch"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { handlers[name] = fn; } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
}

test_busy_extension_lifecycle() {
  local rec id=omp-busy-q5 out state ext
  rec=$(make_spawn_case busy omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp)
  expect_code 0 $? "omp spawn should succeed: $out"
  state="$HOME_DIR/state"
  ext="$state/$id.omp-ext.ts"
  assert_present "$ext" "omp spawn did not write the per-task extension"
  out=$(drive_omp_ext "$ext" handlers) || fail "handler listing failed: $out"
  case " $out " in
    *" agent_settled "*) fail "the omp extension must not listen for agent_settled (omp has no such event)" ;;
  esac
  for handler in agent_start agent_end turn_end tool_call tool_result; do
    case " $out " in
      *" $handler "*) ;;
      *) fail "the omp extension must register $handler, got '$out'" ;;
    esac
  done

  rm -f "$state/$id.turn-ended"
  out=$(drive_omp_ext "$ext" turn-end) || fail "turn_end drive failed: $out"
  [ -f "$state/$id.turn-ended" ] || fail "turn_end no longer touches the notification marker"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] || fail "turn_end must stay a notification, not a state edge"

  out=$(drive_omp_ext "$ext" agent-start) || fail "agent_start drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_start must classify 'busy omp-ext'"

  out=$(drive_omp_ext "$ext" end-continuing) || fail "continuing agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy omp-ext" ] || fail "agent_end with willContinue must stay busy (a session_stop continuation is coming)"

  out=$(drive_omp_ext "$ext" end-final) || fail "final agent_end drive failed: $out"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "idle omp-ext" ] || fail "a plain agent_end must classify 'idle omp-ext'"

  # A record from another harness's writer is never trusted for omp.
  fm_busy_source_trusted omp pi-ext && fail "omp must not trust the Pi extension's records"
  fm_busy_source_trusted omp omp-ext || fail "omp must trust its own extension's records"
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification, jev-guard tool hooks installed"
}

# --- 4. Control, composer, supervision model -----------------------------------

test_control_composer_and_model_tables() {
  [ "$(fm_control_exit_command omp)" = /quit ] || fail "omp exit command must be /quit"
  [ "$(fm_control_interrupt_key omp)" = Escape ] || fail "omp interrupt key must be Escape"
  [ "$(fm_control_interrupt_repeat omp)" = 1 ] || fail "omp interrupts on a single press"
  [ -z "$(fm_control_interrupt_clear_key omp)" ] || fail "omp leaves its composer empty and needs no clear key"
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = "/st/id1.omp-ext.ts" ] || fail "omp wiring path must be the state-resident extension"
  printf 'Working…\n' | fm_busy_lines_match omp || fail "omp busy regex must match the TUI ellipsis form"
  printf 'Working...\n' | fm_busy_lines_match omp && fail "omp busy regex must not match the three-dot form no supervised pane renders"
  printf ' ⠧ 11s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the braille spinner plus elapsed cell"
  printf ' ⣾ 3s  · gpt-6-astra\n' | fm_busy_lines_match omp || fail "omp busy regex must match the status-set spinner frames, not only the activity set"
  printf ' 󰵗  · gpt-6-astra · 36.7%%/41K\n' | fm_busy_lines_match omp && fail "an idle omp status row must not read busy"
  printf 'esc to interrupt\n' | fm_busy_lines_match omp && fail "omp must not borrow Claude's footer"
  local bin out
  bin=$(make_named_shells "$TMP_ROOT/named-model")
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u FM_SUPERVISION_MODEL \
    "$bin/omp" -c '. "$1"; fm_supervision_model' _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = extension ] || fail "an omp primary must run the extension supervision model, got '$out'"
  pass "control, composer, and supervision-model tables carry omp's verified values"
}

# --- 5. Ownership proof --------------------------------------------------------

# Stand up the durable evidence a live omp session leaves behind: both tracked
# extensions under the case root and one marker per extension recording that
# build plus the session pid in state/.lock.
record_omp_session() {  # <root> <home> <session-pid> [omit] [drift]
  local root=$1 home=$2 session_pid=$3 omit=${4:-} drift=${5:-} pair source marker version
  mkdir -p "$root/.omp/extensions" "$home/state"
  for pair in \
    "fm-primary-omp-watch.ts:.omp-watch-extension-loaded:watch" \
    "fm-primary-turnend-guard.ts:.omp-turnend-extension-loaded:turnend"; do
    source=${pair%%:*}
    marker=${pair#*:}; marker=${marker%%:*}
    printf '// %s\n' "${pair##*:}" > "$root/.omp/extensions/$source"
    [ "$omit" = "${pair##*:}" ] && continue
    if [ "$drift" = "${pair##*:}" ]; then
      version="sha256:0000000000000000000000000000000000000000000000000000000000000000"
    else
      version=$(bash -c '. "$1"; fm_pi_extension_version "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$root/.omp/extensions/$source") || return 1
    fi
    printf '%s\n%s\n' "$version" "$session_pid" > "$home/state/$marker"
  done
  printf '%s\n' "$session_pid" > "$home/state/.lock"
}

owns() {  # <root> <home>
  bash -c '. "$1"; fm_omp_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$2/state" "$1"
}

test_ownership_proof_is_omp_keyed() {
  local root home pid
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own/root"; home="$TMP_ROOT/own/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the omp session"
  owns "$root" "$home" || fail "a live session that loaded both omp extensions must own supervision"
  bash -c '. "$1"; fm_pi_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    && fail "omp markers must never satisfy the Pi proof"
  bash -c '. "$1"; fm_extension_owns_supervision "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root" \
    || fail "the shared extension proof must accept the omp pair"

  root="$TMP_ROOT/own-drift/root"; home="$TMP_ROOT/own-drift/home"
  record_omp_session "$root" "$home" "$pid" "" watch || fail "could not record the drifted session"
  owns "$root" "$home" && fail "a session that loaded an older watch build must not own supervision"
  root="$TMP_ROOT/own-omit/root"; home="$TMP_ROOT/own-omit/home"
  record_omp_session "$root" "$home" "$pid" turnend || fail "could not record the partial session"
  owns "$root" "$home" && fail "a session missing the turn-end guard extension must not own supervision"
  root="$TMP_ROOT/own-dead/root"; home="$TMP_ROOT/own-dead/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the dead session"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  owns "$root" "$home" && fail "a dead session must not own supervision"

  # The pull-guard verdict tolerates the extension's own hand-off only with the proof.
  sleep 60 &
  pid=$!
  root="$TMP_ROOT/own-verdict/root"; home="$TMP_ROOT/own-verdict/home"
  record_omp_session "$root" "$home" "$pid" || fail "could not record the verdict session"
  touch "$home/state/.last-watcher-beat"
  local verdict
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "${verdict%% *}" = true ] || fail "an unheld lock with a fresh beacon and the omp proof must be healthy, got '$verdict'"
  rm -f "$home/state/.omp-turnend-extension-loaded"
  verdict=$(FM_SUPERVISION_MODEL=extension FM_HOME="$home" bash -c '
    . "$1"; fm_watcher_supervision_verdict "$2" "$3" 999 "$4" "$5"; printf "%s %s" "$FM_WATCHER_VERDICT_OK" "$FM_WATCHER_VERDICT_REASON"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$root/bin/fm-watch.sh" "$home" "$root")
  [ "$verdict" = "false no-watcher" ] || fail "without the proof the same hand-off must alarm as no-watcher, got '$verdict'"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "fm-wake-lib: the omp ownership proof is keyed on its own extensions and gates the hand-off tolerance"
}

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$ROOT/.pi/extensions/lib/fm-watch-lifecycle.ts" "$repo/.pi/extensions/lib/"
  cp -R "$ROOT/bin/." "$repo/bin/"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

test_turnend_guard_extension_compels_one_continuation() {
  local repo home out status
  repo="$TMP_ROOT/guard/repo"; home="$TMP_ROOT/guard/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
payload=$(cat); printf '%s\n' "$payload" >> "${FM_GUARD_LOG:?}"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac
printf 'guard says: repair with fm_watch_arm_omp\n' >&2; exit 2
SH
  cat > "$repo/bin/fm-arm-pretool-check.sh" <<'SH'
#!/usr/bin/env bash
case "$*" in *fm-watch-arm.sh*'&'*) printf 'fm watcher-arm seatbelt: blocked\n' >&2; exit 2 ;; esac; exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/bin/fm-cd-pretool-check.sh"
  # shellcheck disable=SC2016 # $2 expands in the generated script
  printf '#!/usr/bin/env bash\nprintf "OMP DIGEST source=%%s\\n" "$2"\n' > "$repo/bin/fm-sessionstart-run.sh"
  chmod +x "$repo/bin/"*.sh
  out=$(FM_GUARD_LOG="$TMP_ROOT/guard/guard.log" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, existsSync } from "node:fs";
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
for (const name of ["session_start", "before_agent_start", "session_compact", "session_shutdown", "tool_call", "session_stop"]) {
  if (!handlers.has(name)) throw new Error(`${name} handler was not registered`);
}
if (handlers.has("agent_settled")) throw new Error("omp guard must not listen for agent_settled");
const ctx = { sessionManager: { getSessionId: () => "s1" } };
handlers.get("session_start")({ type: "session_start" }, ctx);
const first = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!first?.message?.content?.includes("FIRSTMATE_OP: v1 session-start: OMP DIGEST source=startup")) throw new Error(`first start did not deliver a startup digest: ${JSON.stringify(first)}`);
if (first.message.display !== false || first.message.customType !== "firstmate-sessionstart-nudge") throw new Error("digest message lost its persistent shape");
// A later in-process session_start is a replacement and maps to clear.
handlers.get("session_start")({ type: "session_start" }, ctx);
const second = await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (!second?.message?.content?.includes("source=clear")) throw new Error(`in-process replacement did not map to clear: ${JSON.stringify(second)}`);
const allowed = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "ls" } }, {});
if (allowed.block) throw new Error("an ordinary command was blocked");
const blocked = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {});
if (blocked.block !== true || !blocked.reason.includes("seatbelt")) throw new Error(`backgrounded arm was not blocked: ${JSON.stringify(blocked)}`);
const r1 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: false }, {});
if (r1?.continue !== true) throw new Error(`guard exit 2 did not compel a continuation: ${JSON.stringify(r1)}`);
if (!r1.additionalContext.startsWith("⁣FIRSTMATE_OP: v1 turn-end-guard: ")) throw new Error(`continuation context is not typed operational input: ${r1.additionalContext}`);
if (!r1.additionalContext.includes("TURN WOULD END BLIND") || !r1.additionalContext.includes("repair with fm_watch_arm_omp")) throw new Error("continuation dropped the guard text");
const r2 = await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, {});
if (r2 !== undefined) throw new Error(`the flagged second stop must stand down, got ${JSON.stringify(r2)}`);
const payloads = readFileSync(process.env.FM_GUARD_LOG, "utf8").trim().split("\n");
if (payloads.join("|") !== '{"stop_hook_active":false}|{"stop_hook_active":true}') throw new Error(`guard payloads were ${payloads.join("|")}`);
if (!existsSync(`${process.env.FM_HOME}/state/.omp-turnend-extension-loaded`)) throw new Error("loaded marker was not written");
await handlers.get("session_shutdown")({}, {});
EOF
)
  status=$?
  expect_code 0 "$status" "omp turn-end guard extension contract: $out"
  [ -z "$out" ] || fail "omp guard extension test printed output: $out"
  pass ".omp turn-end guard: digest delivery, seatbelt block, one compelled continuation, flagged stop stands down"
}

test_watch_extension_arms_and_delivers() {
  local repo home out status
  repo="$TMP_ROOT/watch/repo"; home="$TMP_ROOT/watch/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  # The first arm child closes with one actionable reason; every successor
  # stays up, so exactly one wake exists to consume.
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The extension confirms a handling handoff through this same script; answering
# at once keeps its synchronous call from blocking the whole run.
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
  . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
  fm_wake_append signal omp-e2e 'signal: omp-e2e done' || exit 1
  printf 'signal: omp-e2e done\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; let command = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(n, o) { if (n === "fm-watch-arm-omp") command = o.handler; },
  registerTool(t) { tool = t; },
  // omp sendUserMessage returns synchronously, not a promise.
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, { isIdle: () => true });
if (!tool || tool.name !== "fm_watch_arm_omp") throw new Error("fm_watch_arm_omp was not registered");
if (!command) throw new Error("/fm-watch-arm-omp was not registered");
if (tool.parameters?.type !== "object") throw new Error("tool parameters must be an empty object schema");
const result = await tool.execute();
if (!/^watcher: started omp extension arm child 1;/.test(result.content[0].text)) throw new Error(`unexpected arm result: ${result.content[0].text}`);
const marker = readFileSync(`${process.env.FM_HOME}/state/.omp-watch-extension-loaded`, "utf8").split("\n");
if (marker[1] !== String(process.pid)) throw new Error("loaded marker must record the session pid");
const again = await tool.execute();
if (!/^watcher: unchanged - omp extension already owns an arm child/.test(again.content[0].text)) throw new Error(`redundant arm was not an ownership no-op: ${again.content[0].text}`);
// Wait for delivery, bounded at 60 seconds, rather than assuming child-close timing.
for (let i = 0; i < 600 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (!sent[0].m.startsWith("⁣FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: omp-e2e done")) throw new Error(`unexpected wake text: ${sent[0].m}`);
if (sent[0].o?.deliverAs !== undefined) throw new Error("an idle wake must start its own turn");
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
writeFileSync(`${process.env.FM_HOME}/state/.wake-queue`, "");
await handlers.get("agent_end")({}, { isIdle: () => true });
await new Promise((resolve) => setTimeout(resolve, 1200));
await handlers.get("session_shutdown")({}, {});
if (existsSync(`${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("a consumed wake must not ride the replacement handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension contract: $out"
  [ -z "$out" ] || fail "omp watch extension test printed output: $out"
  pass ".omp watch extension: fm_watch_arm_omp arms once, repeats as a no-op, and delivers an actionable close as one follow-up"
}

test_watch_extension_reads_durable_payloads() {
  local kind repo home out status
  for kind in decision merged multiline stale; do
    repo="$TMP_ROOT/watch-identity-$kind/repo"; home="$TMP_ROOT/watch-identity-$kind/home"
    install_omp_extension_fixture "$repo"
    cp -R "$ROOT/bin/." "$repo/bin/"
    mkdir -p "$home/state"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
if [ -e "$FM_HOME/state/.e2e-fired" ]; then exec sleep 30; fi
: > "$FM_HOME/state/.e2e-fired"
sleep 1
. "$FM_ROOT_OVERRIDE/bin/fm-push-transition-lib.sh"
FM_WATCH_DELIVERY_PID=$$
case "$ROW_KIND" in
  decision)
    reason='signal: decision.status'
    fm_wake_append signal decision.status 'needs-decision: decision.status' || exit 1
    ;;
  merged)
    reason='check: poll-file: merged'
    fm_wake_append check merged-demo 'check: merge landed: demo https://example.test/pull/1' || exit 1
    ;;
  multiline)
    reason=$'check: custom: ready\nsecond line'
    fm_wake_append check custom "$reason" || exit 1
    ;;
  stale)
    printf 'signal: already handled\n'
    exit 0
    ;;
esac
wake "$reason"
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(ROW_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = []; const ctx = { isIdle: () => true };
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); } };
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
if (process.env.ROW_KIND === "stale") await new Promise((resolve) => setTimeout(resolve, 3000));
else for (let i = 0; i < 300 && sent.length === 0; i += 1) await new Promise((resolve) => setTimeout(resolve, 100));
if (process.env.ROW_KIND === "stale") {
  if (sent.length !== 0) throw new Error(`an unqueued watcher row was injected: ${JSON.stringify(sent)}`);
} else {
  const payloads = {
    decision: "needs-decision: decision.status",
    merged: "check: merge landed: demo https://example.test/pull/1",
    multiline: "check: custom: ready second line",
  };
  if (sent.length !== 1 || !sent[0].m.includes(`FIRSTMATE WATCHER WAKE: ${payloads[process.env.ROW_KIND]}\n\nRun bin/fm-wake-drain.sh`)) {
    throw new Error(`durable ${process.env.ROW_KIND} row was not delivered intact: ${JSON.stringify(sent)}`);
  }
  if (sent[0].o?.deliverAs !== undefined) throw new Error("durable watcher wake bypassed idle delivery");
  await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, ctx);
  writeFileSync(`${state}/.wake-queue`, "");
  await handlers.get("agent_end")({}, ctx);
  await new Promise((resolve) => setTimeout(resolve, 1200));
}
await handlers.get("session_shutdown")({}, ctx);
if (process.env.ROW_KIND === "stale") {
  await handlers.get("session_start")({}, ctx);
  for (let i = 0; i < 300 && existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`); i += 1) await new Promise((resolve) => setTimeout(resolve, 100));
  if (sent.length !== 0) throw new Error(`replacement replayed an unqueued watcher row: ${JSON.stringify(sent)}`);
  await handlers.get("session_shutdown")({}, ctx);
}
if (existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("completed correlation retained its handoff");
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp durable sequence ($kind): $out"
  done
  pass ".omp watch extension: decision, merge and multiline payloads come from the queue; unqueued closes inject nothing"
}

# An opted-in home spawns the supervision host in the arm's place; its streamed
# status line drives readiness and the handling handoff, and a handed-back
# wake is delivered with every host line and the away note.
test_watch_extension_runs_the_supervision_host() {  # [away|quiet]
  local kind=${1:-away} repo home log out status f
  repo="$TMP_ROOT/watch-host-$kind/repo"; home="$TMP_ROOT/watch-host-$kind/home"; log="$TMP_ROOT/watch-host-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  if [ "$kind" = quiet ]; then
    # Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
    # QUIET): the extension asks the record owner, so the same handback carries
    # no away note.
    for f in fm-afk-contract.sh fm-classify-lib.sh fm-timeout-lib.sh; do cp "$ROOT/bin/$f" "$repo/bin/$f"; done
    FM_HOME="$home" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
      || fail "fixture: could not record quiet mode"
  else
    : > "$home/state/.afk-contract"
  fi
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed generation=%s watcher=%s\n' "$2" "$4" >> "${FM_ARM_LOG:?}"
  exit 0
fi
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s args=%s primary=%s predecessor=%s\n' "$$" "$*" "${FM_SUPERVISION_HOST_PRIMARY:-}" \
  "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "${FM_ARM_LOG:?}"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  sleep 1
  printf 'signal: omp-host done\nsupervision-host: the away session could not take this wake: fixture; this wake is yours\nsupervision-host: outcome 1 for demo [captain]: fixture\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-2\n' "$$"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    RECORD_KIND="$kind" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, { isIdle: () => true });
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.some((row) => row.startsWith("plain-arm="))) throw new Error(`an opted-in home ran the plain arm: ${rows.join(" | ")}`);
const hosts = rows.filter((row) => row.startsWith("host="));
if (hosts.length !== 2) throw new Error(`expected the host and one successor host, got: ${rows.join(" | ")}`);
if (!hosts.every((row) => / args=park --restart primary=omp /.test(row))) throw new Error(`the host must run as 'park --restart' with the omp pin: ${hosts.join(" | ")}`);
if (!/predecessor=[0-9]+$/.test(hosts[1])) throw new Error(`the successor host did not receive the closed host as its predecessor: ${hosts[1]}`);
if (!rows.includes(`confirmed generation=gen-2 watcher=${hosts[1].replace(/^host=([0-9]+).*/, "$1")}`)) {
  throw new Error(`the handling handoff was not confirmed against the successor host's cycle: ${rows.join(" | ")}`);
}
if (sent.length !== 1) throw new Error(`expected one follow-up wake, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (sent[0].m.includes("signal: omp-host done")) throw new Error(`the hand-back injected a close headline with no queued row: ${sent[0].m}`);
for (const needle of [
  "supervision-host: the away session could not take this wake: fixture; this wake is yours",
  "supervision-host: outcome 1 for demo [captain]: fixture",
]) {
  if (!sent[0].m.includes(needle)) throw new Error(`the follow-up lacks '${needle}': ${sent[0].m}`);
}
const awayNote = sent[0].m.includes("not from the captain: it is not a return");
if (process.env.RECORD_KIND === "quiet" ? awayNote : !awayNote) {
  throw new Error(`the away note must appear exactly under an away record (${process.env.RECORD_KIND}): ${sent[0].m}`);
}
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host mode ($kind record): $out"
  [ -z "$out" ] || fail "omp watch extension host test printed output: $out"
  pass ".omp watch extension: an opted-in home runs the supervision host and relays every host line ($kind record)"
}

# The omp owner stays file-gated: a home without config/supervision-host, or
# one opted out by config/supervision-host-off, spawns the plain arm and never the host.
test_watch_extension_keeps_the_arm_without_the_file_or_with_off() {
  local line label repo home log out status
  for line in - off; do
    label=${line#-}; label=${label:-absent}
    repo="$TMP_ROOT/watch-host-gate-$label/repo"; home="$TMP_ROOT/watch-host-gate-$label/home"; log="$TMP_ROOT/watch-host-gate-$label/arm.log"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state" "$home/config"
    [ "$line" = - ] || : > "$home/config/supervision-host-off"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'plain-arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
sleep 30
SH
    chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" \
      EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { existsSync, writeFileSync, readFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage() { return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 60 && !existsSync(process.env.FM_ARM_LOG); i += 1) await new Promise((r) => setTimeout(r, 100));
const rows = existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n") : [];
if (rows.length === 0 || !rows.every((row) => row.startsWith("plain-arm="))) {
  throw new Error(`a home that does not run the host must spawn only the plain arm: ${rows.join(" | ")}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp watch extension gate ($label): $out"
    [ -z "$out" ] || fail "omp watch extension gate test printed output ($label): $out"
  done
  pass ".omp watch extension: a home without config/supervision-host or with an off file keeps the plain arm"
}

test_watch_extension_delivers_host_handbacks() {  # <outcome|away-return|busy>
  local kind=${1:-outcome} repo home log out status
  repo="$TMP_ROOT/watch-host-handoff-$kind/repo"; home="$TMP_ROOT/watch-host-handoff-$kind/home"; log="$TMP_ROOT/watch-host-handoff-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-wake-drain.sh"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  sleep 1
  case "$HAND_BACK_KIND" in
    away-return) printf 'signal: already handled original\nsupervision-host: the captain returned while the away session was handling this wake; relay its visible outcomes\n' ;;
    *) printf 'supervision-host: branch-outcome: the supervision session handled this wake and recorded captain outcomes for you (store rows 1)\n' ;;
  esac
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(HAND_BACK_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
const ctx = { isIdle: () => process.env.HAND_BACK_KIND !== "busy" };
await handlers.get("before_agent_start")({}, ctx);
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1 || !sent[0].m.includes("FIRSTMATE SUPERVISION HOST:")) throw new Error(`host hand-back was not delivered once: ${JSON.stringify(sent)}`);
const expected = process.env.HAND_BACK_KIND === "away-return" ? "the captain returned" : "branch-outcome:";
if (!sent[0].m.includes(expected)) throw new Error(`host hand-back lost its outcome: ${sent[0].m}`);
if (sent[0].m.includes("signal: already handled original")) throw new Error(`host hand-back injected a handled headline: ${sent[0].m}`);
if (process.env.HAND_BACK_KIND === "busy" ? sent[0].o?.deliverAs !== "followUp" : sent[0].o?.deliverAs !== undefined) throw new Error("host hand-back changed its idle/busy delivery routing");
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, ctx);
await handlers.get("session_shutdown")({}, {});
if (existsSync(handoff)) throw new Error("a consumed host hand-back retained its handoff");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host-only handoff: $out"
  [ -z "$out" ] || fail "omp watch extension host-only handoff test printed output: $out"
  pass ".omp watch extension: an unqueued host hand-back is delivered once ($kind)"
}

# A host close that is not an operational hand-back is a queue-read mark: its
# headline comes only from a queued row. With nothing queued, a park boundary
# sends nothing, while a diagnostic line is delivered with the fixed pointer.
# An away record adds the away note to the mark.
test_watch_extension_marks_host_closes_without_headlines() {  # <boundary|note|diagnostic|restore-boundary|restore-diagnostic>
  local kind=${1:-boundary} repo home log out status
  repo="$TMP_ROOT/watch-host-mark-$kind/repo"; home="$TMP_ROOT/watch-host-mark-$kind/home"; log="$TMP_ROOT/watch-host-mark-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  case "$kind" in note|diagnostic) : > "$home/state/.afk-contract" ;; esac
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
count=$(grep -c '^host=' "$FM_ARM_LOG")
boundary='supervision-host: cycle boundary - the park ended with nothing for main'
diagnostic='supervision-host: the away session could not take this wake: fixture; this wake is yours'
case "$HOST_CLOSE_KIND:$count" in
  boundary:[123])
    sleep 1
    printf '%s\n' "$boundary"
    exit 0
    ;;
  diagnostic:1)
    sleep 1
    printf 'signal: close headline\n%s\n' "$diagnostic"
    exit 0
    ;;
  note:1|restore-*:1)
    sleep 1
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
    fm_wake_append signal queued.status 'signal: durable queued row' || exit 1
    case "$HOST_CLOSE_KIND" in
      restore-boundary) printf '%s\n' "$boundary" ;;
      *) printf 'signal: close headline\n%s\n' "$diagnostic" ;;
    esac
    exit 0
    ;;
esac
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(HOST_CLOSE_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
const kind = process.env.HOST_CLOSE_KIND;
const restore = kind.startsWith("restore-");
const diagnostic = "supervision-host: the away session could not take this wake: fixture; this wake is yours";
const pointer = "FIRSTMATE WATCHER WAKE: check: wake may be due";
const away = "not from the captain: it is not a return";
const handlers = new Map(); let tool = null; const sent = []; let editor = "";
const ctx = { hasUI: true, isIdle: () => true, hasPendingMessages: () => false,
  ui: { getEditorText: () => editor, setEditorText: (value) => { editor = value; } } };
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    sent.push({ m, o });
    if (restore && sent.length === 1) return undefined;
    handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
    return undefined;
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, ctx);
await tool.execute();
const hosts = () => (existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8") : "").trim().split("\n").filter((row) => row.startsWith("host="));
const wanted = kind === "boundary" ? 4 : 2;
const expected = { boundary: 0, note: 1, diagnostic: 1, "restore-boundary": 1, "restore-diagnostic": 2 }[kind];
const until = async (predicate) => { for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((r) => setTimeout(r, 100)); };
if (restore) {
  await until(() => sent.length === 1);
  if (sent.length !== 1 || !sent[0].m.includes("FIRSTMATE WATCHER WAKE: signal: durable queued row")) throw new Error(`the queued row was not delivered first: ${JSON.stringify(sent)}`);
  writeFileSync(`${state}/.wake-queue`, "");
  editor = sent[0].m;
  await until(() => editor === "");
  if (editor !== "") throw new Error("the restored wake text was not removed");
}
await until(() => hosts().length >= wanted && sent.length >= expected && !existsSync(handoff));
await new Promise((r) => setTimeout(r, 1500));
if (hosts().length !== wanted) throw new Error(`expected ${wanted} host parks, saw ${hosts().length}: ${JSON.stringify(sent)}`);
if (sent.length !== expected) throw new Error(`expected ${expected} injected wakes for ${kind}, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (sent.some(({ m, o }) => m.includes("signal: close headline") || m.includes("FAILED") || o?.deliverAs !== undefined)) throw new Error(`a close headline, failure, or follow-up was injected: ${JSON.stringify(sent)}`);
if (kind === "note") {
  if (!sent[0].m.includes("FIRSTMATE WATCHER WAKE: signal: durable queued row") || !sent[0].m.includes(diagnostic)) throw new Error(`the queue-read wake lost its row or host explanation: ${sent[0].m}`);
  if (!sent[0].m.includes(away)) throw new Error(`a host mark under an away record lost the away note: ${sent[0].m}`);
}
if (kind === "diagnostic" || kind === "restore-diagnostic") {
  const last = sent[sent.length - 1].m;
  if (!last.includes(pointer) || !last.includes(diagnostic)) throw new Error(`an empty queue dropped the host explanation: ${last}`);
  if (kind === "diagnostic" && !last.includes(away)) throw new Error(`the empty-queue mark lost the away note: ${last}`);
}
if (existsSync(handoff)) throw new Error("a settled host close retained its handoff");
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host close mark ($kind): $out"
  [ -z "$out" ] || fail "omp watch extension host close mark test printed output ($kind): $out"
  pass ".omp watch extension: a non-operational host close is a queue-read mark, never a failure or a headline ($kind)"
}

# The replacement handoff follows the same empty-queue rule: stored marks merge
# into one, a diagnostic line is delivered with the fixed pointer, and a mark
# with only the cycle-boundary line is cleared without a send.
test_watch_extension_replays_host_marks_from_the_handoff() {  # <diagnostic|boundary>
  local kind=${1:-diagnostic} repo home out status
  repo="$TMP_ROOT/watch-host-mark-handoff-$kind/repo"; home="$TMP_ROOT/watch-host-mark-handoff-$kind/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(HOST_CLOSE_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const dir = `${state}/extensions/omp-primary-watch`;
const handoff = `${dir}/session-replacement-actionable.json`;
mkdirSync(dir, { recursive: true });
const boundary = "supervision-host: cycle boundary - the park ended with nothing for main";
const diagnostic = "supervision-host: watcher downtime could not be restored for the main hand-back";
const away = "This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.";
const messages = process.env.HOST_CLOSE_KIND === "boundary"
  ? [`check: wake may be due\n${boundary}`, "check: wake may be due"]
  : [`check: wake may be due\n${boundary}`, `check: wake may be due\n${diagnostic}\n${away}`];
writeFileSync(handoff, JSON.stringify({ version: 2, pending: messages.map((message, i) => ({
  version: 1, token: `1-1-${i + 1}`, message, predecessorArmPid: "",
})) }));
const handlers = new Map(); const sent = [];
const ctx = { isIdle: () => true };
const pi = {
  on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) {
    sent.push({ m, o });
    handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
  },
};
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
for (let i = 0; i < 100 && existsSync(handoff); i += 1) await new Promise((r) => setTimeout(r, 50));
await new Promise((r) => setTimeout(r, 1500));
if (existsSync(handoff)) throw new Error(`the handoff kept a settled mark: ${JSON.stringify(sent)}`);
if (process.env.HOST_CLOSE_KIND === "boundary") {
  if (sent.length !== 0) throw new Error(`a boundary-only handoff mark injected text with an empty queue: ${JSON.stringify(sent)}`);
} else {
  if (sent.length !== 1) throw new Error(`expected one wake for the merged handoff mark: ${JSON.stringify(sent)}`);
  for (const needle of ["FIRSTMATE WATCHER WAKE: check: wake may be due", boundary, diagnostic, away]) {
    if (!sent[0].m.includes(needle)) throw new Error(`the handoff mark lost '${needle}': ${sent[0].m}`);
  }
}
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp host mark handoff ($kind): $out"
  [ -z "$out" ] || fail "omp host mark handoff test printed output ($kind): $out"
  pass ".omp watch extension: a handoff host mark follows the empty-queue rule ($kind)"
}

test_watch_extension_migrates_legacy_handoffs() {
  local repo home out status
  repo="$TMP_ROOT/watch-legacy-handoff/repo"; home="$TMP_ROOT/watch-legacy-handoff/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const dir = `${state}/extensions/omp-primary-watch`;
const handoff = `${dir}/session-replacement-actionable.json`;
mkdirSync(dir, { recursive: true });
writeFileSync(`${state}/.wake-queue`, "1\t1\tcheck\tnew\tcheck: current queued work\n");
const messages = [
  "supervision-host: branch-outcome: captain outcomes (store rows 1)",
  "signal: handled original\nsupervision-host: the captain returned while the away session was handling this wake; relay its visible outcomes",
  "signal: legacy uncorrelated",
  "FIRSTMATE SUPERVISION HOST: check: legacy wrapped uncorrelated",
  "FIRSTMATE SUPERVISION HOST: check: still queued\nwake-seq: 1",
];
writeFileSync(handoff, JSON.stringify({ version: 2, pending: messages.map((message, i) => ({
  version: 1, token: `1-1-${i + 1}`, message, predecessorArmPid: "",
})) }));
const handlers = new Map(); const sent = [];
const ctx = { isIdle: () => true };
const pi = {
  on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) {
    sent.push({ m, o });
    if (m.includes("FIRSTMATE WATCHER WAKE:")) writeFileSync(`${state}/.wake-queue`, "");
    handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
  },
};
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
for (let i = 0; i < 100 && (sent.length < 3 || existsSync(handoff)); i += 1) await new Promise((r) => setTimeout(r, 50));
if (sent.length !== 3 || sent.some(({ m }) => m.includes("FAILED") || m.includes("uncorrelated") || m.includes("still queued") || m.includes("handled original"))) throw new Error(`legacy migration failed: ${JSON.stringify(sent)}`);
for (const expected of ["branch-outcome:", "the captain returned", "check: current queued work"]) {
  if (!sent.some(({ m }) => m.includes(expected))) throw new Error(`migration lost ${expected}`);
}
const watcher = sent.find(({ m }) => m.includes("check: current queued work"));
if (!watcher.m.includes("FIRSTMATE WATCHER WAKE:") || watcher.m.includes("FIRSTMATE SUPERVISION HOST:")) throw new Error("legacy host wrapper retained its watcher exemption");
if (existsSync(handoff)) throw new Error("migration retained consumed or retired records");
await handlers.get("session_shutdown")({}, ctx);
await handlers.get("session_start")({}, ctx);
await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 3) throw new Error("legacy records replayed after migration");
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp legacy handoff migration: $out"
  [ -z "$out" ] || fail "omp legacy handoff migration printed output: $out"
  pass ".omp watch extension: legacy operational handoffs load and watcher records collapse into a queue-read mark"
}

# A host whose exit reaches the extension in separate stream chunks is
# delivered once at its close: a successor host whose status and signal lines
# land while the previous wake is still being delivered, with its outcome lines
# after a pause, reaches main as one follow-up carrying both.
test_watch_extension_delivers_a_split_host_close_whole() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-split/repo"; home="$TMP_ROOT/watch-host-split/home"; log="$TMP_ROOT/watch-host-split/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
started="watcher: started pid=$$ (beacon fresh) recovery-generation=gen-$$"
case "$(grep -c '^host=' "$FM_ARM_LOG")" in
  1)
    printf '%s\n' "$started"
    sleep 1
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
    fm_wake_append signal first 'signal: omp-host first' || exit 1
    printf 'signal: omp-host first\n'
    exit 0
    ;;
  2)
    printf '%s\nsignal: omp-host second\n' "$started"
    sleep 1
    node --input-type=module <<'JS'
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (const [stream, label] of [[process.stdout, "stdout"], [process.stderr, "stderr"]]) {
  const bytes = Buffer.from(`supervision-host: outcome 2 for demo [captain]: fixture split ${label} 船😀\n`);
  const cut = bytes.indexOf(Buffer.from("船")) + 1;
  stream.write(bytes.subarray(0, cut));
  await sleep(100);
  stream.write(bytes.subarray(cut));
}
JS
    exit 0
    ;;
esac
printf '%s\n' "$started"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    sent.push({ m, o });
    handlers.get("message_start")({ message: { role: "user", content: m } }, { isIdle: () => true });
    return undefined;
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, { isIdle: () => true });
await tool.execute();
for (let i = 0; i < 80 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const second = sent.filter((item) => item.m.includes("outcome 2 for demo"));
if (second.length !== 1) throw new Error(`expected one follow-up for the split close, saw ${second.length}: ${JSON.stringify(sent)}`);
if (sent.some((item) => item.m.includes("signal: omp-host second"))) throw new Error(`the split close injected a headline with no queued row: ${JSON.stringify(sent)}`);
if (!second[0].m.includes("supervision-host: outcome 2 for demo [captain]: fixture split")) {
  throw new Error(`the split close was delivered without its outcome line: ${second[0].m}`);
}
for (const stream of ["stdout", "stderr"]) {
  if (!second[0].m.includes(`fixture split ${stream} 船😀`)) throw new Error(`host ${stream} UTF-8 was corrupted: ${second[0].m}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension split host close: $out"
  [ -z "$out" ] || fail "omp watch extension split host close test printed output: $out"
  pass ".omp watch extension: a host close split across stream chunks reaches main as one whole follow-up"
}

run_watch_queue_read_scenario() {
  local scenario=$1 repo home status
  repo="$TMP_ROOT/watch-queue-$scenario/repo"; home="$TMP_ROOT/watch-queue-$scenario/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  cp "$repo/bin/fm-wake-drain.sh" "$repo/bin/fm-wake-drain-real.sh"
  cat > "$repo/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --queued ]; then
  printf 'query\n' >> "$FM_HOME/state/query-log"
  [ ! -e "$FM_HOME/state/query-fail" ] || exit 1
  [ ! -e "$FM_HOME/state/query-hang" ] || sleep 20
  if [ "$SCENARIO" = utf8 ]; then
    exec node --input-type=module <<'JS'
import { spawnSync } from "node:child_process";
const result = spawnSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-wake-drain-real.sh`, "--queued"], { env: process.env });
if (result.status !== 0) process.exit(1);
const cut = result.stdout.indexOf(Buffer.from("船")) + 1;
if (cut < 1) process.exit(1);
process.stdout.write(result.stdout.subarray(0, cut));
await new Promise((resolve) => setTimeout(resolve, 100));
process.stdout.write(result.stdout.subarray(cut));
JS
  fi
  if [ -e "$FM_HOME/state/query-slow" ]; then
    rm -f "$FM_HOME/state/query-slow"
    rows=$(bash "$FM_ROOT_OVERRIDE/bin/fm-wake-drain-real.sh" --queued) || exit $?
    : > "$FM_HOME/state/query-started"
    case "$SCENARIO" in
      slow-turn*) while [ ! -e "$FM_HOME/state/query-release" ]; do sleep 0.1; done ;;
      *) sleep 1 ;;
    esac
    printf '%s\n' "$rows"
    exit 0
  fi
fi
exec bash "$FM_ROOT_OVERRIDE/bin/fm-wake-drain-real.sh" "$@"
SH

  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
while :; do
  for f in "$FM_HOME"/state/trigger-*; do
    [ -e "$f" ] || continue
    name=${f##*/}
    rm -f "$f"
    fm_wake_append check "$name" "check: $name" || exit 1
    if [ "$SCENARIO" = same-close ] && [ "$name" = trigger-1 ]; then
      printf 'check: misleading old headline\n'
      : > "$FM_HOME/state/appended-$name"
      while [ ! -e "$FM_HOME/state/trigger-2" ]; do sleep 0.1; done
      rm -f "$FM_HOME/state/trigger-2"
      fm_wake_append check trigger-2 'check: trigger-2' || exit 1
      : > "$FM_HOME/state/appended-trigger-2"
    fi
    if [ "$SCENARIO" = late-handoff ] && [ "$name" = trigger-1 ]; then
      printf 'check: misleading old headline\n'
      trap 'sleep 2; fm_wake_append check trigger-2 "check: trigger-2"; printf "check: late close\n"; exit 0' TERM
      : > "$FM_HOME/state/appended-$name"
      while :; do sleep 0.1; done
    fi
    printf 'check: rearm-resurface\n'
    : > "$FM_HOME/state/appended-$name"
    exit 0
  done
  sleep 0.1
done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-wake-drain.sh"
  case "$scenario" in host-*) : > "$home/config/supervision-host"; cp "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh" ;; esac
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=50 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    SCENARIO="$scenario" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module >"$home/scenario.out" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { writeFileSync, readFileSync, existsSync, unlinkSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
const scenario = process.env.SCENARIO;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
let idle = false, queued = false, editor = "", sets = 0;
const ctx = { hasUI: true, isIdle: () => { if (scenario === "unreadable" && idle) throw new Error("stale context"); return idle; }, hasPendingMessages: () => queued,
  ui: { getEditorText: () => editor, setEditorText: (value) => { editor = value; sets += 1; } } };
const pi = { on(name, handler) { handlers.set(name, handler); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) { sent.push({ m, o }); } };
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const until = async (predicate, label, seconds = 15) => {
  for (let i = 0; i < seconds * 20; i += 1) { if (predicate()) return; await sleep(50); }
  throw new Error(`${label}: ${JSON.stringify(sent)}`);
};
const queries = () => existsSync(`${state}/query-log`) ? readFileSync(`${state}/query-log`, "utf8").trim().split("\n").length : 0;
const wakes = () => sent.filter(({ m }) => !m.includes("watcher: FAILED"));
const drain = (...args) => {
  const result = spawnSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-wake-drain-real.sh`, ...args], { env: process.env, encoding: "utf8" });
  if (result.status !== 0) throw new Error(`drain failed: ${result.stdout}\n${result.stderr}`);
  return `${result.stdout}\n${result.stderr}`;
};
const append = (key, payload) => {
  const result = spawnSync("bash", ["-c", '. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"; fm_wake_append check "$1" "$2"', "_", key, payload], { env: process.env, encoding: "utf8" });
  if (result.status !== 0) throw new Error(`append failed: ${result.stderr}`);
};
const acknowledge = (presentation) => {
  const match = /WAKE_ACK_REQUIRED: .*--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)/.exec(presentation);
  if (!match) throw new Error(`no ack command: ${presentation}`);
  drain("--ack-through", match[1], "--recovery-generation", match[2]);
};
const fire = async (name) => {
  writeFileSync(`${state}/${name}`, "");
  await until(() => existsSync(`${state}/appended-${name}`), `watcher did not append ${name}`);
};
const end = async () => { idle = true; await handlers.get("agent_end")({}, ctx); };
const accept = async (wake) => {
  idle = false;
  await handlers.get("before_agent_start")({ prompt: wake.m }, ctx);
  await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: wake.m }] } }, ctx);
};
const expectWake = (index, payload) => {
  const wake = wakes()[index];
  if (!wake || wake.o?.deliverAs !== undefined || !wake.m.includes(`FIRSTMATE WATCHER WAKE: ${payload}`) || wake.m.includes("misleading") || wake.m.includes("rearm-resurface")) throw new Error(`wrong queue wake: ${JSON.stringify(sent)}`);
};
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
if (scenario === "external") {
  append("mail", "check: externally queued captain note");
  writeFileSync(`${state}/trigger-1`, "");
  await until(() => !existsSync(`${state}/trigger-1`), "recovery close did not run");
  idle = true;
  await until(() => wakes().length === 1, "external row lost");
  expectWake(0, "check: externally queued captain note");
} else {
  if (scenario === "utf8") append("multilingual", "check: 船😀 café Ελληνικά");
  await fire("trigger-1");
  if (sent.length || queries()) throw new Error("busy close submitted or queried the queue");
  if (scenario === "unreadable") {
    idle = true;
    await sleep(1500);
    if (sent.length || queries()) throw new Error("unreadable idle state authorized a query or delivery");
  } else if (["drained", "host-drained"].includes(scenario)) {
    await fire("trigger-2"); await fire("trigger-3");
    acknowledge(drain());
    await end();
    await until(() => queries() >= 1, "empty queue was not queried");
    await sleep(1200);
    if (sent.length) throw new Error(`empty closes injected work: ${JSON.stringify(sent)}`);
  } else if (["mixed", "same-close", "handoff", "late-handoff"].includes(scenario)) {
    const first = drain();
    if (!first.includes("check: trigger-1")) throw new Error("A not presented");
    if (scenario === "handoff" || scenario === "late-handoff") {
      await handlers.get("session_shutdown")({}, ctx);
      const stored = JSON.parse(readFileSync(handoff, "utf8"));
      if (stored.pending.length !== 1 || stored.pending[0].message !== "check: wake may be due") throw new Error("handoff stored a headline instead of one mark");
      acknowledge(first);
      if (scenario === "handoff") append("trigger-2", "check: trigger-2");
      idle = true;
      await handlers.get("session_start")({}, ctx);
    } else {
      await fire("trigger-2");
      acknowledge(first);
      await end();
    }
    await until(() => wakes().length === 1, "partial acknowledgement lost B", 20);
    expectWake(0, "check: trigger-2");
    if (wakes()[0].m.includes("check: trigger-1")) throw new Error("acknowledged A was replayed");
  } else if (["failure", "timeout", "slow", "slow-pending", "slow-turn", "slow-turn-new-row", "query-close"].includes(scenario)) {
    if (scenario === "query-close") acknowledge(drain());
    writeFileSync(`${state}/query-${scenario === "failure" ? "fail" : scenario === "timeout" ? "hang" : "slow"}`, "");
    await end();
    if (scenario === "failure") {
      await until(() => sent.some(({ m }) => m.includes("watcher: FAILED - could not read the wake queue")), "typed queue failure never surfaced");
      if (queries() < 3 || wakes().length) throw new Error("query failure silently dropped or sent watcher work");
      unlinkSync(`${state}/query-fail`);
    } else if (scenario === "timeout") {
      await until(() => queries() === 1, "timeout query did not start");
      await sleep(10500);
      if (wakes().length) throw new Error("timed out query injected a wake");
      unlinkSync(`${state}/query-hang`);
    } else if (scenario === "query-close") {
      await until(() => existsSync(`${state}/query-started`), "empty slow query did not start");
      await fire("trigger-2");
      await until(() => wakes().length === 1, "close during an empty query lost its mark");
      expectWake(0, "check: trigger-2");
      if (queries() < 2) throw new Error("new close reused the earlier empty snapshot");
    } else if (scenario === "slow-pending") {
      await until(() => existsSync(`${state}/query-started`), "slow query did not start");
      queued = true;
      await until(() => wakes().length === 1, "vendor queue appearing during query blocked owed work");
      expectWake(0, "check: trigger-1");
    } else if (scenario.startsWith("slow-turn")) {
      await until(() => existsSync(`${state}/query-started`), "slow query did not capture A");
      idle = false;
      await handlers.get("before_agent_start")({ prompt: "ordinary turn" }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: "ordinary turn" } }, ctx);
      acknowledge(drain());
      if (scenario === "slow-turn-new-row") append("B", "check: fresh B after A acknowledgement");
      await end();
      writeFileSync(`${state}/query-release`, "");
      await until(() => queries() >= 2, "completed turn lost the mark for a fresh query");
      if (scenario === "slow-turn-new-row") {
        await until(() => wakes().length === 1, "completed turn stranded B");
        expectWake(0, "check: fresh B after A acknowledgement");
        if (wakes()[0].m.includes("check: trigger-1")) throw new Error("intervening turn reused A's snapshot");
      } else {
        await sleep(1200);
        if (sent.length) throw new Error("completed intervening turn injected an acknowledged headline");
      }
    } else {
      await until(() => existsSync(`${state}/query-started`), "slow query did not start");
      idle = false;
      acknowledge(drain());
      await sleep(1200);
      if (sent.length) throw new Error("slow query queued a stale follow-up");
      await end();
      await until(() => queries() >= 2, "slow query mark was lost");
      await sleep(200);
      if (sent.length) throw new Error("slow-query snapshot was reused");
    }
    if (["failure", "timeout"].includes(scenario)) {
      await until(() => wakes().length === 1, "failed query did not retain its mark", 15);
      expectWake(0, "check: trigger-1");
      if (queries() < 2) throw new Error("failed query was not retried");
    }
  } else {
    if (scenario === "owed") { await fire("trigger-2"); await fire("trigger-3"); }
    if (scenario.startsWith("advisor-tail")) {
      queued = true;
      editor = scenario === "advisor-tail-draft" ? "\noperator\u2063 draft\n\n" : "";
    }
    if (scenario === "advisor-tail") idle = true;
    else await end();
    await until(() => wakes().length === 1, "owed row was not sent");
    expectWake(0, scenario === "utf8" ? "check: 船😀 café Ελληνικά" : "check: trigger-1");
    if (scenario.startsWith("advisor-tail") && (editor !== (scenario === "advisor-tail-draft" ? "\noperator\u2063 draft\n\n" : "") || sets)) throw new Error("advisor-tail delivery touched operator draft bytes");
    if (scenario === "owed" && !wakes()[0].m.includes("and 2 more queued")) throw new Error("missing queued-row count");
    const wake = wakes()[0];
    const count = queries();
    if (scenario.startsWith("restore-")) {
      const draft = "\noperator\u2063 draft\n\n";
      const bare = wake.m.startsWith("\u2063") ? wake.m.slice(1) : wake.m;
      const texts = {
        "restore-alone": bare,
        "restore-after": `${wake.m}\n\n${draft}`,
        "restore-before": `${draft}\n\n${bare}`,
        "restore-edited": `${wake.m} do not send`,
        "restore-queued": wake.m,
        "restore-busy": wake.m,
        "restore-drained": `${wake.m}\n\n${draft}`,
        "restore-new-row": `${wake.m}\n\n${draft}`,
        "restore-end-owed": `${wake.m}\n\n${draft}`,
        "restore-end-drained": `${wake.m}\n\n${draft}`,
        "restore-end-new-row": `${wake.m}\n\n${draft}`,
        "restore-end-queued": `${wake.m}\n\n${draft}`,
      };
      editor = texts[scenario];
      const original = editor;
      if (scenario === "restore-queued") queued = true;
      if (scenario === "restore-busy") idle = false;
      if (scenario.startsWith("restore-end-")) {
        idle = false;
        await handlers.get("before_agent_start")({ prompt: wake.m }, ctx);
        if (["restore-end-drained", "restore-end-new-row"].includes(scenario)) acknowledge(drain());
        if (scenario === "restore-end-new-row") append("B", "check: new queued payload");
        if (scenario === "restore-end-queued") queued = true;
        await handlers.get("agent_end")({}, ctx);
        if (editor !== original || sets || wakes().length !== 1) throw new Error("busy turn end touched restored text");
        idle = true;
        if (queued) {
          await sleep(1500);
          if (editor !== original || sets || wakes().length !== 1) throw new Error("release bypassed pending editor work");
          queued = false;
        }
      }
      if (scenario === "restore-new-row") { acknowledge(drain()); append("B", "check: new queued payload"); }
      if (["restore-drained", "restore-end-drained"].includes(scenario)) {
        if (scenario === "restore-drained") acknowledge(drain());
        await until(() => editor === draft, "empty-queue restored template was not removed");
        await sleep(1200);
        if (wakes().length !== 1) throw new Error("empty-queue editor text was resubmitted");
      } else if (["restore-edited", "restore-queued", "restore-busy"].includes(scenario)) {
        await sleep(1500);
        if (wakes().length !== 1 || editor !== original || sets !== 0) throw new Error("poll touched or sent unsupported editor text");
      } else {
        await until(() => wakes().length === 2, "stranded editor did not mark queue work");
        expectWake(1, ["restore-new-row", "restore-end-new-row"].includes(scenario) ? "check: new queued payload" : "check: trigger-1");
        if (editor !== (scenario === "restore-alone" ? "" : draft)) throw new Error("poll changed operator draft bytes");
        if (["restore-new-row", "restore-end-new-row"].includes(scenario) && wakes()[1].m.includes("check: trigger-1")) throw new Error("poll submitted stale composer text");
      }
    } else if (["outstanding-end", "dropped", "removed", "edited"].includes(scenario)) {
      if (scenario === "outstanding-end") await accept(wake);
      else {
        idle = false;
        await handlers.get("before_agent_start")({ prompt: wake.m }, ctx);
      }
      if (scenario === "edited") editor = wake.m.replace("trigger-1", "operator edit");
      const original = editor;
      const first = drain();
      await fire("trigger-2");
      acknowledge(first);
      if (scenario === "dropped") idle = true;
      else {
        await sleep(1100);
        if (queries() !== count || wakes().length !== 1) throw new Error("outstanding wake did not serialize sends");
        await end();
      }
      await until(() => wakes().length === 2, "outstanding token blocked B");
      expectWake(1, "check: trigger-2");
      if (editor !== original || sets) throw new Error("token release changed operator edits");
    } else if (scenario.startsWith("advisor-tail")) {
      queued = true;
      await fire("trigger-2");
      await handlers.get("before_agent_start")({ prompt: wake.m }, ctx);
      await sleep(1500);
      if (queries() !== count || wakes().length !== 1) throw new Error("pending vendor work did not serialize an outstanding watcher");
      queued = false;
      await accept(wake);
      const first = drain();
      await fire("trigger-3");
      acknowledge(first);
      await end();
      await until(() => wakes().length === 2, "outstanding vendor queue release lost owed work");
      expectWake(1, "check: trigger-3");
    } else if (scenario === "release-consume") {
      // A's preparation is cancelled and the busy turn end releases A into the held set,
      // then the operator submits the unchanged restored A, so consuming A must retire its held copy too.
      idle = false;
      await handlers.get("before_agent_start")({ prompt: wake.m }, ctx);
      await handlers.get("agent_end")({}, ctx);
      await accept(wake);
      const first = drain();
      await fire("trigger-2");
      acknowledge(first);
      await end();
      await until(() => wakes().length === 2, "consumed A's held copy retired B");
      expectWake(1, "check: trigger-2");
      // B's preparation is cancelled before message_start; the token must release so a later close still sends.
      idle = false;
      await handlers.get("before_agent_start")({ prompt: wakes()[1].m }, ctx);
      const second = drain();
      await fire("trigger-3");
      acknowledge(second);
      idle = true;
      await until(() => wakes().length === 3, "cancelled B left an outstanding token that blocked C");
      expectWake(2, "check: trigger-3");
    } else if (scenario === "consumed") {
      await accept(wake);
      acknowledge(drain());
      await end();
      await sleep(1200);
      if (queries() !== count) throw new Error("consumed wake triggered an extra queue query");
      append("B", "check: unrelated later row");
      await sleep(1200);
      if (queries() !== count || wakes().length !== 1) throw new Error("consumed wake left a phantom pending mark");
    } else {
      await accept(wake);
      acknowledge(drain());
      await end();
      await sleep(1200);
      if (wakes().length !== 1) throw new Error("drained wake replayed after its turn ended");
    }
  }
}
await handlers.get("session_shutdown")({}, ctx);
if (scenario === "consumed" && existsSync(handoff) && JSON.parse(readFileSync(handoff, "utf8")).pending.length !== 0) throw new Error("consumed wake persisted a new pending handoff");
process.exit(0);
EOF
  status=$?
  cat "$home/scenario.out"
  return "$status"
}

test_watch_extension_queue_read_delivery() {
  local scenario out status
  for scenario in drained owed consumed release-consume mixed same-close handoff late-handoff external host-drained host-owed advisor-tail advisor-tail-draft outstanding-end dropped removed edited failure timeout slow slow-pending slow-turn slow-turn-new-row query-close unreadable utf8 restore-alone restore-after restore-before restore-edited restore-queued restore-busy restore-new-row restore-drained restore-end-owed restore-end-drained restore-end-new-row restore-end-queued; do
    out=$(run_watch_queue_read_scenario "$scenario")
    status=$?
    expect_code 0 "$status" "omp queue-read scenario $scenario: $out"
    [ -z "$out" ] || fail "omp queue-read scenario $scenario printed output: $out"
  done
  pass ".omp watch extension: one idle queue-read boundary covers partial acknowledgements, recovery, replacement, token release, failures and slow queries"
}

# Only the omp process that holds the session lock may record itself as the
# loaded session or arm a watcher. A descendant omp (an `omp -p` child a turn
# runs) auto-discovers the same extensions from the same directory; it used to
# overwrite the marker with its own pid, and its death left the dead pid in the
# marker, so the supervision proof read "not loaded" under a healthy session.
test_primary_extensions_ignore_a_descendant_session() {
  local repo home out status
  repo="$TMP_ROOT/descendant/repo"; home="$TMP_ROOT/descendant/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # The session lock names this shell, an ancestor of the node process below.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    WATCH_EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_SESSIONSTART_OFF=1 node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.ppid}\n`);
const record = "sha256:parent-session-build\n" + process.ppid + "\n";
for (const marker of [".omp-turnend-extension-loaded", ".omp-watch-extension-loaded"]) writeFileSync(`${state}/${marker}`, record);
const load = async (file) => {
  const handlers = new Map(); let tool = null;
  const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage() {}, sendMessage() {} };
  (await import(pathToFileURL(file).href)).default(pi);
  return { handlers, tool };
};
const guard = await load(process.env.GUARD_EXT);
const watch = await load(process.env.WATCH_EXT);
const ctx = { sessionManager: { getSessionId: () => "child" } };
await guard.handlers.get("session_start")({ type: "session_start" }, ctx);
await watch.handlers.get("session_start")({ type: "session_start" }, ctx);
await guard.handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, ctx);
await watch.handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "x" }, ctx);
for (const marker of [".omp-turnend-extension-loaded", ".omp-watch-extension-loaded"]) {
  if (readFileSync(`${state}/${marker}`, "utf8") !== record) throw new Error(`a descendant session overwrote ${marker}: ${readFileSync(`${state}/${marker}`, "utf8")}`);
}
const arm = await watch.tool.execute();
if (!/read-only/.test(arm.content[0].text)) throw new Error(`a descendant session armed a watcher: ${arm.content[0].text}`);
if (existsSync(`${state}/.watch.lock`)) throw new Error("a descendant session took the watcher lock");
await watch.handlers.get("session_shutdown")({}, ctx);
await guard.handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "descendant omp session must not claim the home: $out"
  [ -z "$out" ] || fail "descendant omp session test printed output: $out"
  pass ".omp extensions: a descendant omp session neither records itself as the loaded session nor arms a watcher"
}

# The turn-end guard used to record itself only while the extension loaded,
# before the session-start hook claimed the lock, so a lock that was foreign or
# absent at that moment left a marker naming a dead pid until the next restart.
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries() {
  local repo home out status
  repo="$TMP_ROOT/marker-heal/repo"; home="$TMP_ROOT/marker-heal/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const pidOf = () => readFileSync(marker, "utf8").split("\n")[1];
// A live session that is not this process holds the lock while the extension loads.
const other = spawn("sleep", ["60"], { stdio: "ignore" });
writeFileSync(`${state}/.lock`, `${other.pid}\n`);
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
(await import(pathToFileURL(process.env.GUARD_EXT).href)).default(pi);
const ctx = { sessionManager: { getSessionId: () => "s1" } };
await handlers.get("session_start")({ type: "session_start" }, ctx);
if (existsSync(marker)) throw new Error("a foreign live lock holder must not be recorded as this session's marker");
// The session-start hook then claims the lock for this process.
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (pidOf() !== String(process.pid)) throw new Error(`the marker was not recorded once the lock was claimed: ${readFileSync(marker, "utf8")}`);
// A stale record (a dead build or pid) is repaired at the next turn boundary.
writeFileSync(marker, "sha256:stale\n999999\n");
await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, ctx);
if (pidOf() !== String(process.pid)) throw new Error(`the stale marker was not repaired at the turn boundary: ${readFileSync(marker, "utf8")}`);
other.kill();
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "turn-end marker self-repair: $out"
  [ -z "$out" ] || fail "turn-end marker self-repair test printed output: $out"
  pass ".omp turn-end guard: the loaded marker follows the lock owner at turn boundaries instead of only at load"
}

# A watch-arm stub that records every arm it starts and then stays up as a
# healthy cycle, so the number of arms is the number of rows in the arm log.
install_counting_arm() {  # <repo>
  cat > "$1/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
exec sleep 30
SH
  chmod +x "$1/bin/fm-watch-arm.sh"
}

# A session generation stopped with no successor session_start is not a dead
# end: after the successor grace the extension binds a fresh generation and
# arms exactly once; a real session_start inside the grace arms nothing twice;
# and an arm call on a stopped generation heals at once instead of refusing.
# Every transition, and the expired bound, is in the lifecycle record.
test_watch_extension_heals_a_generation_stopped_without_a_successor() {
  local repo home out status
  repo="$TMP_ROOT/watch-heal/repo"; home="$TMP_ROOT/watch-heal/home"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
trap 'if [ -e "$FM_HOME/state/.delay-stop" ]; then sleep 0.7; fi; exit 0' TERM
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import fs, { writeFileSync, readFileSync, existsSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(message) { sent.push(message); },
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const lifecycle = () => readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 50 && arms() < 1; i += 1) await sleep(50);
if (arms() !== 1) throw new Error(`startup should arm once, saw ${arms()}`);

// 1. Shutdown with no successor: one self-heal arm after the grace, no more.
await handlers.get("session_shutdown")({}, {});
await sleep(150);
if (arms() !== 1) throw new Error(`a heal fired before the successor grace: ${arms()} arms`);
for (let i = 0; i < 60 && arms() < 2; i += 1) await sleep(50);
if (arms() !== 2) throw new Error(`a stopped generation with no successor was not healed: ${arms()} arms`);
await sleep(900);
if (arms() !== 2) throw new Error(`the self-heal armed more than once: ${arms()} arms`);
const healed = await tool.execute();
if (!/^watcher: unchanged/.test(healed.content[0].text)) throw new Error(`the healed generation does not own its arm: ${healed.content[0].text}`);
const record = lifecycle();
for (const needle of ["event=session_shutdown", "event=generation-stop", "event=bound-expired", "waiter=omp-watch-extension", "waited-on=session_start", "bound=400ms", "outcome=self-heal", "event=generation-create", "cause=self-heal", "event=self-heal"]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}

// 2. Shutdown then a real session_start inside the grace: one arm, no heal.
await handlers.get("session_shutdown")({}, {});
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && arms() < 3; i += 1) await sleep(50);
await sleep(900);
if (arms() !== 3) throw new Error(`a successor session_start must arm exactly once with no heal: ${arms()} arms`);
if ((lifecycle().match(/event=self-heal /g) ?? []).length + (lifecycle().match(/event=self-heal$/gm) ?? []).length !== 1) {
  throw new Error(`a heal fired despite a successor session_start:\n${lifecycle()}`);
}

// 3. An arm call on a stopped generation heals at once instead of refusing.
await handlers.get("session_shutdown")({}, {});
const armed = await tool.execute();
if (/shutting down/.test(armed.content[0].text)) throw new Error(`an arm call on a stopped generation was refused: ${armed.content[0].text}`);
if (!/^watcher: started/.test(armed.content[0].text)) throw new Error(`an arm call did not heal and arm: ${armed.content[0].text}`);
await sleep(900);
if (arms() !== 4) throw new Error(`the arm-call heal and the timed heal both armed: ${arms()} arms`);
if (!lifecycle().includes("cause=arm-call")) throw new Error(`the arm-call heal is not recorded:\n${lifecycle()}`);
const rebound = (module) => {
  const handlers = new Map(); const box = {};
  module.default({
    on(e, h) { handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { box.tool = t; },
    sendUserMessage(message) { sent.push(message); },
  });
  return { handlers, box };
};
const waitForArms = async (expected) => {
  for (let i = 0; i < 60 && arms() < expected; i++) await sleep(50);
  await sleep(900);
  if (arms() !== expected) throw new Error(`factory recovery expected ${expected} arms, saw ${arms()}`);
};
const successorModule = await import(`${pathToFileURL(process.env.EXT).href}?rebound`);
writeFileSync(`${home}/state/.delay-stop`, "");
const shutdown = handlers.get("session_shutdown")({}, {});
const successor = rebound(successorModule);
await sleep(500);
if (arms() !== 4) throw new Error("factory recovery raced pending predecessor retirement");
await shutdown;
await waitForArms(5);
const successorArm = await successor.box.tool.execute();
if (!successorArm.details.ok || !successorArm.details.message.includes("unchanged")) throw new Error("factory successor did not own the automatic recovery");
const forwarded = await tool.execute();
if (!forwarded.details.ok || !forwarded.details.message.includes("unchanged")) throw new Error("predecessor tool did not forward to the healed factory");
await successor.handlers.get("session_shutdown")({}, {});
const started = rebound(successorModule);
await started.handlers.get("session_start")({}, {});
await waitForArms(6);
await started.handlers.get("session_shutdown")({}, {});
const repaired = rebound(successorModule);
await repaired.box.tool.execute();
await waitForArms(7);
await repaired.handlers.get("session_shutdown")({}, {});
writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
const foreign = rebound(successorModule);
await sleep(900);
if (arms() !== 7) throw new Error("factory recovery armed under a foreign lock");
const refused = await foreign.box.tool.execute();
if (refused.details.ok || !refused.details.message.includes("read-only")) throw new Error("foreign factory recovery did not preserve lock ownership");
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
await foreign.handlers.get("session_shutdown")({}, {});
const unhandled = [];
process.on("unhandledRejection", (error) => unhandled.push(String(error)));
const originalWrite = fs.writeFileSync;
let injected = 0;
let fault = true;
writeFileSync(`${home}/state/.omp-watch-extension-loaded`, "stale\n");
fs.writeFileSync = function(path, ...args) {
  if (fault && String(path) === `${home}/state/.omp-watch-extension-loaded`) {
    fault = false;
    injected++;
    throw Object.assign(new Error("transient owner write failure"), { code: "EIO" });
  }
  return originalWrite.call(this, path, ...args);
};
syncBuiltinESMExports();
for (let i = 0; i < 100 && !injected; i++) await sleep(20);
await sleep(100);
if (injected !== 1 || arms() !== 7) throw new Error("timed owner failure did not stop activation");
const failures = sent.filter((message) => message.includes("transient owner write failure"));
if (failures.length !== 1) throw new Error("timed activation lost its failure wake");
if (unhandled.length) throw new Error(`unhandled activation rejection: ${unhandled.join("; ")}`);
const beforeRepair = lifecycle().split("\n").filter((line) => line.includes("event=generation-activate") && line.includes("cause=arm-call")).length;
const repair = await foreign.box.tool.execute();
if (!repair.details.ok) throw new Error("timed activation failure poisoned arm repair");
if (lifecycle().split("\n").filter((line) => line.includes("event=generation-activate") && line.includes("cause=arm-call")).length !== beforeRepair + 1) throw new Error("failed activation consumed the recovery obligation");
await waitForArms(8);
fs.writeFileSync = originalWrite;
syncBuiltinESMExports();
const liveReplacement = rebound(successorModule);
await waitForArms(9);
const liveArm = await liveReplacement.box.tool.execute();
if (!liveArm.details.ok || !liveArm.details.message.includes("unchanged")) throw new Error("live factory retirement did not recover without session_start");
await liveReplacement.handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension self-heal: $out"
  [ -z "$out" ] || fail "omp watch extension self-heal test printed output: $out"
  pass ".omp watch extension: a generation stopped without a successor heals once; a real successor or arm call never double-arms"
}

# Loading the extension twice in one process (auto-discovery plus -e) leaves
# exactly one live generation and one arm: the earlier instance retires, its
# events are ignored, and its arm tool forwards to the current instance.
test_watch_extension_is_single_instance_per_home() {
  local repo home out status
  repo="$TMP_ROOT/watch-single/repo"; home="$TMP_ROOT/watch-single/home"
  install_omp_extension_fixture "$repo"
  install_counting_arm "$repo"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const makePi = () => {
  const handlers = new Map(); const box = { tool: null };
  return { handlers, box, pi: {
    on(e, h) { handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { box.tool = t; },
    sendUserMessage() { return undefined; },
  } };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const mod = await import(pathToFileURL(process.env.EXT).href);
const first = makePi(); mod.default(first.pi);
const second = makePi(); mod.default(second.pi);
// Both instances see the same session events, as a double load would.
await first.handlers.get("session_start")({ type: "session_start" }, {});
await second.handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 50 && arms() < 1; i += 1) await sleep(50);
await sleep(600);
if (arms() !== 1) throw new Error(`a double load armed ${arms()} cycles`);
const viaFirst = await first.box.tool.execute();
if (!/^watcher: unchanged/.test(viaFirst.content[0].text)) throw new Error(`the tool of the superseded instance did not reach the live owner: ${viaFirst.content[0].text}`);
const viaSecond = await second.box.tool.execute();
if (!/^watcher: unchanged/.test(viaSecond.content[0].text)) throw new Error(`the current instance lost its arm: ${viaSecond.content[0].text}`);
// A shutdown seen by the superseded instance is ignored: the live cycle keeps running.
await first.handlers.get("session_shutdown")({}, {});
await sleep(900);
if (arms() !== 1) throw new Error(`the superseded instance changed the live cycle: ${arms()} arms`);
const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
for (const needle of ["event=factory-bind", "superseded=1", "event=instance-retired", "event=session_start-ignored", "event=arm-forwarded", "event=session_shutdown-ignored"]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}
const shutdown = second.handlers.get("session_shutdown")({}, {});
const repair = second.box.tool.execute();
const third = makePi(); mod.default(third.pi);
await third.handlers.get("session_start")({}, {});
const repaired = await repair;
await shutdown;
if (!/^watcher: unchanged/.test(repaired.content[0].text)) throw new Error(`stale continuation did not reach successor: ${repaired.content[0].text}`);
for (let i = 0; i < 50 && arms() < 2; i++) await sleep(50);
await sleep(900);
if (arms() !== 2) throw new Error(`arm continuation stole ownership from successor: ${arms()} arms`);
const current = await third.box.tool.execute();
if (!/^watcher: unchanged/.test(current.content[0].text)) throw new Error(`successor lost ordinary arm ownership: ${current.content[0].text}`);
await third.handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension single instance: $out"
  [ -z "$out" ] || fail "omp watch extension single-instance test printed output: $out"
  pass ".omp watch extension: a double load keeps one live generation, one arm, and forwards the superseded tool"
}

test_watch_extension_repairs_after_handoff_publication_failure() {
  local repair repo home out status
  for repair in tool command factory; do
    repo="$TMP_ROOT/watch-persist-$repair/repo"; home="$TMP_ROOT/watch-persist-$repair/home"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ ! -e "$FM_HOME/state/.fired" ]; then
  : > "$FM_HOME/state/.fired"
  . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
  fm_wake_append check publication-failure 'check: publication failure wake' || exit 1
  printf 'check: publication failure wake\n'
  exit 0
fi
exec sleep 30
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
      REPAIR="$repair" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate) => {
  for (let i = 0; i < 60 && !predicate(); i++) await sleep(50);
  if (!predicate()) throw new Error("timed out waiting for publication failure fixture");
};
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const makePi = () => {
  const handlers = new Map(), commands = new Map(), sent = [], box = {};
  return { handlers, commands, sent, box, pi: {
    on(e, h) { handlers.set(e, h); },
    registerCommand(name, command) { commands.set(name, command); },
    registerTool(t) { box.tool = t; },
    sendUserMessage(message) { sent.push(message); },
  } };
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.EXT).href);
const first = makePi(); mod.default(first.pi);
const ctx = { isIdle: () => true };
await first.handlers.get("session_start")({}, ctx);
await waitFor(() => first.sent.length === 1 && arms() === 2);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
mkdirSync(handoff);
let owner = first;
if (process.env.REPAIR === "factory") {
  owner = makePi(); mod.default(owner.pi);
} else {
  await first.handlers.get("session_shutdown")({}, ctx);
}
rmSync(handoff, { recursive: true });
if (process.env.REPAIR === "command") {
  const notifications = [];
  await owner.commands.get("fm-watch-arm-omp").handler("", { ...ctx, ui: { notify(message) { notifications.push(message); } } });
  if (notifications.length !== 1 || !notifications[0].startsWith("watcher: started")) throw new Error("command repair was poisoned by publication failure");
} else {
  const repaired = await owner.box.tool.execute();
  if (!repaired.details.ok || !repaired.details.message.startsWith("watcher: started")) throw new Error("tool repair was poisoned by publication failure");
}
await waitFor(() => owner.sent.some((message) => message.includes("could not persist a replacement-session actionable wake")));
const failures = owner.sent.filter((message) => message.includes("could not persist a replacement-session actionable wake"));
if (failures.length !== 1) throw new Error("repair lost or duplicated its persistence failure");
const queued = spawnSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-wake-drain.sh`, "--queued"], { env: process.env, encoding: "utf8" });
if (queued.status !== 0 || queued.stdout.trim().split("\t").slice(4).join("\t") !== "check: publication failure wake") throw new Error("publication failure repair lost the durable actionable row");
await owner.handlers.get("message_start")({ message: { role: "user", content: failures[0] } }, ctx);
await sleep(900);
if (arms() !== 3) throw new Error("publication failure repair double-armed");
const unchanged = await owner.box.tool.execute();
if (!unchanged.details.ok || !unchanged.details.message.includes("unchanged")) throw new Error("repaired watcher lost ordinary arm ownership");
await owner.handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp publication failure $repair repair: $out"
    [ -z "$out" ] || fail "omp publication failure $repair repair printed output: $out"
  done
  pass ".omp watch extension: publication failure retains the wake and permits tool, command, and factory repair"
}

test_watch_lifecycle_deadline_diagnostics() {
  local repo="$TMP_ROOT/omp-expiry-root" out status
  install_omp_extension_fixture "$repo"
  out=$(node "$ROOT/tests/watch-lifecycle-expiry.mjs" omp "$repo" 2>&1)
  status=$?
  expect_code 0 "$status" "omp lifecycle deadline diagnostics: $out"
  pass "omp shutdown, arm and host readiness, and unready retirement each log one expiry"
}

test_watch_lifecycle_deadline_diagnostics
if [ "${1:-}" = --queue-read-delivery ]; then
  test_watch_extension_queue_read_delivery
  exit 0
fi

if [ "${1:-}" = --watch-queue ]; then
  test_watch_extension_arms_and_delivers
  test_watch_extension_reads_durable_payloads
  test_watch_extension_runs_the_supervision_host
  test_watch_extension_runs_the_supervision_host quiet
  test_watch_extension_delivers_host_handbacks outcome
  test_watch_extension_delivers_host_handbacks away-return
  test_watch_extension_delivers_host_handbacks busy
  test_watch_extension_marks_host_closes_without_headlines boundary
  test_watch_extension_marks_host_closes_without_headlines note
  test_watch_extension_marks_host_closes_without_headlines diagnostic
  test_watch_extension_marks_host_closes_without_headlines restore-boundary
  test_watch_extension_marks_host_closes_without_headlines restore-diagnostic
  test_watch_extension_replays_host_marks_from_the_handoff diagnostic
  test_watch_extension_replays_host_marks_from_the_handoff boundary
  test_watch_extension_delivers_a_split_host_close_whole
  test_watch_extension_migrates_legacy_handoffs
  test_watch_extension_queue_read_delivery
  exit 0
fi
test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_worker_replace_mode_environment
test_worker_guard_project_scope
test_spawn_model_validation_scoped_to_listed_providers
test_spawn_refuses_a_missing_or_unlisted_default_role
test_spawn_global_config_is_read_only_and_unlayered
test_spawn_raw_omp_guard_uses_the_launch_model
test_spawn_raw_omp_guard_uses_the_launch_agent_dir
test_spawn_omp_profiles_leave_directory_evidence_unreadable
test_spawn_raw_omp_expansions_pass_through_unchanged
test_spawn_raw_omp_literal_evidence_still_refuses
test_secondmate_launch_relies_on_discovery
test_secondmate_config_pinned_model_is_validated
test_busy_extension_lifecycle
test_control_composer_and_model_tables
test_ownership_proof_is_omp_keyed
test_turnend_guard_extension_compels_one_continuation
test_watch_extension_arms_and_delivers
test_watch_extension_reads_durable_payloads
test_watch_extension_runs_the_supervision_host
test_watch_extension_runs_the_supervision_host quiet
test_watch_extension_keeps_the_arm_without_the_file_or_with_off
test_watch_extension_delivers_host_handbacks outcome
test_watch_extension_delivers_host_handbacks away-return
test_watch_extension_delivers_host_handbacks busy
test_watch_extension_marks_host_closes_without_headlines boundary
test_watch_extension_marks_host_closes_without_headlines note
test_watch_extension_marks_host_closes_without_headlines diagnostic
test_watch_extension_marks_host_closes_without_headlines restore-boundary
test_watch_extension_marks_host_closes_without_headlines restore-diagnostic
test_watch_extension_replays_host_marks_from_the_handoff diagnostic
test_watch_extension_replays_host_marks_from_the_handoff boundary
test_watch_extension_delivers_a_split_host_close_whole
test_watch_extension_migrates_legacy_handoffs
test_watch_extension_queue_read_delivery
test_primary_extensions_ignore_a_descendant_session
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries
test_watch_extension_heals_a_generation_stopped_without_a_successor
test_watch_extension_is_single_instance_per_home
test_watch_extension_repairs_after_handoff_publication_failure
