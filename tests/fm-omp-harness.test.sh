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
  # Keep real process evidence inside this fixture's ancestry. Otherwise an
  # actual omp running this suite makes every decoy inherit an omp ancestor.
  local -x FM_TEST_DETECTION_BOUNDARY=$$ FM_TEST_REAL_PS
  FM_TEST_REAL_PS=$(command -v ps)
  local PATH="$bin:$PATH"
  cat > "$bin/ps" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-o ppid= -p $FM_TEST_DETECTION_BOUNDARY" ]; then
  printf '1\n'
else
  exec "$FM_TEST_REAL_PS" "$@"
fi
SH
  chmod +x "$bin/ps"
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
  --version)
    printf 'omp/%s\n' "${FM_FAKE_OMP_VERSION:-18.1.20}"
    ;;
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

test_spawn_refuses_unsupported_omp_before_launch() {
  local kind version rec id out status
  local -a args
  for kind in ship scout secondmate; do
    for version in 18.1.11 18.1.19; do
      id="omp-old-$kind-${version##*.}"
      rec=$(make_spawn_case "$id" omp "$id")
      read_case_record "$rec"
      case "$kind" in
        ship) args=(--mode local-only --yolo off) ;;
        scout) args=(--scout) ;;
        secondmate) args=(--secondmate) ;;
      esac
      out=$(FM_BACKEND=tmux FM_FAKE_OMP_VERSION="$version" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
        fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --harness omp "${args[@]}")
      status=$?
      expect_code 1 "$status" "unsupported omp must refuse $kind: $out"
      assert_contains "$out" "installed omp version 'omp/$version'" "refusal must name installed version"
      assert_contains "$out" "minimum supported version is 18.1.20" "refusal must name minimum"
      assert_contains "$out" "omp update" "refusal must name upgrade step"
      [ ! -s "$LAUNCH_LOG" ] || fail "unsupported omp reached $kind launch"
      assert_absent "$HOME_DIR/state/$id.meta" "refused launch must not publish task metadata"
      assert_absent "$HOME_DIR/state/$id.omp-ext.ts" "refused launch must not install task extension"
    done
  done
  pass "fm-spawn: unsupported omp refuses ships, scouts, and secondmates before launch"
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
  (await import(pathToFileURL(process.env.EXT_PATH))).default({ on: (name, fn) => { handlers[name] = fn; }, pi: { AgentRegistry: { global: () => ({ list: () => [] }) } } });
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
  id='omp-model-refused-q2'
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-nope)
  status=$?
  expect_code 1 "$status" "a model absent from a listed provider must refuse"
  assert_contains "$out" "is not listed by 'omp models --json' although provider 'openai-codex' is" "refusal did not name the listing evidence"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must publish no record"

  rec=$(make_spawn_case model-bridge omp omp-model-bridge-q3)
  read_case_record "$rec"
  id='omp-model-bridge-q3'
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model claude-bridge/claude-opus-4-8)
  status=$?
  expect_code 0 "$status" "an extension-registered provider must pass through: $out"
  assert_contains "$out" "notice: omp provider 'claude-bridge' is not in 'omp models --json'" "pass-through did not state its reason"
  assert_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id='omp-model-fuzzy-q4'
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
// The extension API exposes the host SDK; the session proof only reads the
// live registry from it inside its own handlers, which these modes never fire.
mod.default({ on: (name, fn) => { handlers[name] = fn; }, pi: { AgentRegistry: { global: () => ({}) } } });
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
  [ "$(fm_control_harness_wiring_paths omp /wt /st id1)" = $'/st/id1.omp-ext.ts\n/st/id1.omp-session.json' ] \
    || fail "omp wiring paths must be the state-resident extension and its current-session record"
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
  mkdir -p "$repo/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-task-session.ts" "$repo/.omp/extensions/lib/"
  cp "$ROOT/bin/fm-parent-channel-lib.sh" "$ROOT/bin/fm-secondmate-parent-lib.sh" "$ROOT/bin/fm-status-record-lib.sh" "$repo/bin/"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$ROOT/.pi/extensions/lib/fm-watch-lifecycle.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/bin/fm-operational-input.sh" "$ROOT/bin/fm-supervision-engine-lib.sh" "$repo/bin/"
  chmod +x "$repo/bin/fm-operational-input.sh"
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
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ]; then
  : > "$FM_HOME/state/.e2e-fired"
  sleep 1
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
if (sent[0].o?.deliverAs !== "followUp") throw new Error("wake must be delivered as a follow-up");
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: sent[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: sent[0].m } }, {});
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
for (const needle of [
  "signal: omp-host done",
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

# A host cycle boundary can close with only a "supervision-host:" line; left
# unconsumed across a session replacement it rides the persisted handoff and
# the successor session loads and replays it.
test_watch_extension_replays_a_host_only_boundary_across_replacement() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-handoff/repo"; home="$TMP_ROOT/watch-host-handoff/home"; log="$TMP_ROOT/watch-host-handoff/arm.log"
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
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ "$(grep -c '^host=' "$FM_ARM_LOG")" -eq 1 ]; then
  sleep 1
  printf 'supervision-host: outcome 1 for demo [captain]: fixture boundary\n'
  exit 0
fi
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
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
await tool.execute();
for (let i = 0; i < 60 && sent.length < 1; i += 1) await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 1) throw new Error(`expected one boundary follow-up, saw ${sent.length}: ${JSON.stringify(sent)}`);
const boundary = "supervision-host: outcome 1 for demo [captain]: fixture boundary";
if (!sent[0].m.includes(boundary)) throw new Error(`the follow-up lacks the boundary line: ${sent[0].m}`);
// The session is replaced before omp consumes the boundary follow-up.
await handlers.get("session_shutdown")({}, {});
const stored = JSON.parse(readFileSync(handoff, "utf8"));
if (stored.pending.length !== 1 || !stored.pending[0].message.includes(boundary)) {
  throw new Error(`the unconsumed boundary did not ride the handoff: ${JSON.stringify(stored)}`);
}
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const replays = sent.slice(1);
if (replays.some((item) => item.m.includes("watcher: FAILED"))) throw new Error(`the successor failed to load the handoff: ${JSON.stringify(replays)}`);
if (replays.length !== 1 || !replays[0].m.includes(boundary)) throw new Error(`the successor did not replay the boundary: ${JSON.stringify(replays)}`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: replays[0].m }, {});
await handlers.get("message_start")({ message: { role: "user", content: replays[0].m } }, {});
await handlers.get("session_shutdown")({}, {});
if (existsSync(handoff)) throw new Error("a consumed replay must not ride the replacement handoff again");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host-only handoff: $out"
  [ -z "$out" ] || fail "omp watch extension host-only handoff test printed output: $out"
  pass ".omp watch extension: a host-only boundary rides the replacement handoff and replays in the successor session"
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
    printf 'signal: omp-host first\n'
    exit 0
    ;;
  2)
    printf '%s\nsignal: omp-host second\n' "$started"
    sleep 1
    printf 'supervision-host: outcome 2 for demo [captain]: fixture split\n'
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
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await tool.execute();
for (let i = 0; i < 80 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const second = sent.filter((item) => item.m.includes("signal: omp-host second"));
if (second.length !== 1) throw new Error(`expected one follow-up for the split close, saw ${second.length}: ${JSON.stringify(sent)}`);
if (!second[0].m.includes("supervision-host: outcome 2 for demo [captain]: fixture split")) {
  throw new Error(`the split close was delivered without its outcome line: ${second[0].m}`);
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

test_task_session_proof_tracks_active_session() {
  local case_dir="$TMP_ROOT/task-session-proof" status
  mkdir -p "$case_dir/extension"
  cp "$ROOT/.omp/extensions/lib/fm-task-session.ts" "$case_dir/extension/"
  FM_PROOF_CASE="$case_dir" EXT="$case_dir/extension/fm-task-session.ts" node --input-type=module <<'EOF'
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync, realpathSync, mkdirSync, symlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const { installTaskSessionProof } = await import(pathToFileURL(process.env.EXT).href);
const state = process.env.FM_PROOF_CASE;
const sessions = `${state}/sessions`, linkedSessions = `${state}/linked-sessions`;
mkdirSync(sessions);
symlinkSync(sessions, linkedSessions, "dir");
const task = `${linkedSessions}/task.jsonl`, personal = `${linkedSessions}/personal.jsonl`;
const canonicalTask = `${realpathSync(sessions)}/task.jsonl`;
writeFileSync(personal, "{}\n");
writeFileSync(`${state}/demo.meta`, "spawn_gen=proof-gen\n");
process.env.FM_SPAWN_GEN = "proof-gen";
const handlers = new Map(), warnings = [];
const pi = { pi: { AgentRegistry: { global() { return { list() { return globalThis.proofRefs; } }; } } }, on(event, handler) { handlers.set(event, handler); } };
installTaskSessionProof(pi, state, "demo");
let file = task;
const ctx = { agent: { kind: "main", id: "Main" }, sessionManager: { getSessionFile() { return file; } }, ui: { notify(message) { warnings.push(message); } } };
let transitionSettled = Promise.resolve();
globalThis.proofSession = { sessionManager: ctx.sessionManager, waitForSessionTransition() { globalThis.proofWaitStarted?.(); return transitionSettled; } };
globalThis.proofRefs = [{ kind: "sub", session: null }, { kind: "sub", session: { sessionManager: {} } }, { kind: "main", session: globalThis.proofSession }];
const flush = () => new Promise(resolve => setImmediate(resolve));
const start = (context = ctx) => handlers.get("session_start")({}, context);
const stop = () => handlers.get("session_shutdown")({}, ctx);
const beforeSwitch = () => handlers.get("session_before_switch")({ targetSessionFile: personal, reason: "resume" }, ctx);
const afterSwitch = () => handlers.get("session_switch")({ previousSessionFile: task, reason: "resume" }, ctx);
const record = () => JSON.parse(readFileSync(`${state}/demo.omp-session.json`, "utf8"));
const begin = (event, context = ctx) => {
  let settle, started;
  transitionSettled = new Promise(resolve => { settle = resolve; });
  const waiting = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`${event} did not await its transition owner`)), 5000);
    started = () => { clearTimeout(timeout); resolve(); };
  });
  globalThis.proofWaitStarted = started;
  handlers.get(event)({}, context);
  return { settle, waiting };
};
assert.equal(existsSync(task), false);
start();
assert.deepEqual(record(), { version: 1, spawn_gen: "proof-gen", pid: process.pid, task_session_file: canonicalTask, current_session_file: canonicalTask });
assert.equal(existsSync(task), false);
writeFileSync(task, "{}\n");
start();
assert.deepEqual(record(), { version: 1, spawn_gen: "proof-gen", pid: process.pid, task_session_file: realpathSync(task), current_session_file: realpathSync(task) });
const parentProof = record();
const events = ["session_start", "session_switch", "session_branch", "session_before_switch", "session_before_branch", "session_shutdown"];
for (const childFile of [personal, undefined]) {
  const manager = { getSessionFile() { return childFile; } };
  const childSession = { sessionManager: manager, waitForSessionTransition() { throw new Error("child transition must not be awaited"); } };
  for (const kind of ["sub", "advisor"]) {
    const ref = { kind, session: childSession };
    globalThis.proofRefs.push(ref);
    for (const childCtx of [{ agent: { kind }, sessionManager: manager, ui: ctx.ui }, { sessionManager: manager, ui: ctx.ui }]) {
      for (const event of events) {
        handlers.get(event)({}, childCtx);
        assert.deepEqual(record(), parentProof, `${event} from ${childFile ? "persisted" : "in-memory"} ${kind} must preserve parent proof`);
      }
    }
    globalThis.proofRefs.pop();
  }
  for (const event of events) {
    handlers.get(event)({}, { agent: { kind: "main" }, sessionManager: manager, ui: ctx.ui });
    assert.deepEqual(record(), parentProof, `${event} from an unregistered manager must preserve parent proof`);
  }
}
for (const context of [ctx, { sessionManager: ctx.sessionManager, ui: ctx.ui }]) {
  for (const event of ["session_before_switch", "session_before_branch"]) {
    for (const outcome of ["cancel", "rollback", "rollback-after-activation"]) {
      for (const predecessor of [task, personal]) {
        file = predecessor; start(context);
        const prior = record();
        const { settle, waiting } = begin(event, context);
        assert.equal(record().current_session_file, "");
        await waiting;
        assert.equal(record().current_session_file, "", `${event} must remain unproven while pending`);
        if (outcome !== "cancel") {
          file = predecessor === task ? personal : task;
          if (outcome === "rollback-after-activation") {
            handlers.get(event === "session_before_switch" ? "session_switch" : "session_branch")({}, context);
            assert.equal(record().current_session_file, realpathSync(file));
          }
          await flush();
          assert.equal(record().current_session_file, outcome === "rollback" ? "" : realpathSync(file));
          file = predecessor;
        }
        settle();
        await flush();
        assert.deepEqual(record(), prior, `${event} ${outcome} must restore only the settled predecessor`);
      }
    }
  }
}
file = task; start();
for (const event of ["session_before_switch", "session_before_branch"]) {
  let transition = begin(event);
  await transition.waiting;
  file = personal;
  transition.settle();
  await flush();
  assert.equal(record().current_session_file, "", `${event} must not restore after an unannounced identity change`);
  file = task; start();
  transition = begin(event);
  await transition.waiting;
  stop();
  transition.settle();
  await flush();
  assert.equal(record().current_session_file, "", `${event} must not restore after shutdown`);
  start();
}
transitionSettled = Promise.resolve();
stop();
assert.equal(record().current_session_file, "");
assert.equal(record().task_session_file, realpathSync(task));
file = task; start();
beforeSwitch();
assert.equal(record().current_session_file, "");
assert.equal(record().task_session_file, realpathSync(task));
file = personal; afterSwitch();
assert.equal(record().current_session_file, realpathSync(personal));
assert.equal(record().task_session_file, realpathSync(task));
// Reloading the extension in the personal session must not rebind the task.
installTaskSessionProof(pi, state, "demo"); start();
assert.equal(record().task_session_file, realpathSync(task));
handlers.get("session_before_branch")({}, ctx);
assert.equal(record().current_session_file, "");
file = task; handlers.get("session_branch")({ previousSessionFile: personal }, ctx);
assert.equal(record().current_session_file, record().task_session_file);
const originalWarn = console.warn; console.warn = () => {};
try {
  await flush();
  const registered = globalThis.proofRefs;
  for (const event of events) {
    for (const refs of [registered.slice(0, 2), [...registered, { kind: "main", session: globalThis.proofSession }]]) {
      start();
      const prior = record();
      globalThis.proofRefs = refs;
      const count = warnings.length;
      handlers.get(event)({}, { sessionManager: ctx.sessionManager, ui: ctx.ui });
      await flush();
      assert.deepEqual(record(), prior, `${event} without a unique registered owner must preserve parent proof`);
      assert.equal(warnings.length, count);
      globalThis.proofRefs = registered;
    }
  }
  for (const event of ["session_before_switch", "session_before_branch"]) {
    start();
    const transition = begin(event, { sessionManager: ctx.sessionManager, ui: ctx.ui });
    await transition.waiting;
    globalThis.proofRefs = registered.slice(0, 2);
    transition.settle();
    await flush();
    assert.equal(record().current_session_file, "", `${event} must not restore after its owner is unregistered`);
    globalThis.proofRefs = registered;
  }
  start();
  beforeSwitch();
  file = `${linkedSessions}/absent.jsonl`;
  afterSwitch();
  assert.equal(record().current_session_file, `${realpathSync(sessions)}/absent.jsonl`);
  assert.equal(record().task_session_file, realpathSync(task));
  assert.notEqual(record().current_session_file, record().task_session_file);
  assert.equal(existsSync(file), false);
  installTaskSessionProof(pi, state, "demo"); start();
  assert.equal(record().task_session_file, realpathSync(task));
  file = task; start();
  assert.equal(record().current_session_file, record().task_session_file);
  beforeSwitch();
  file = `${linkedSessions}/missing-parent/session.jsonl`;
  assert.throws(afterSwitch, { code: "ENOENT" });
  assert.equal(record().current_session_file, "");
  assert.equal(record().task_session_file, realpathSync(task));
  assert.ok(warnings.length);
  file = `${personal}/session.jsonl`;
  assert.throws(start, { code: "ENOTDIR" });
  assert.equal(record().current_session_file, "");
  assert.equal(record().task_session_file, realpathSync(task));
  writeFileSync(`${state}/demo.meta`, "spawn_gen=other-gen\n");
  file = task; assert.throws(start);
  assert.equal(record().current_session_file, "");
  writeFileSync(`${state}/wrong.meta`, "spawn_gen=other-gen\n");
  installTaskSessionProof(pi, state, "wrong");
  assert.throws(start);
  assert.equal(existsSync(`${state}/wrong.omp-session.json`), false);
  writeFileSync(`${state}/corrupt.meta`, "spawn_gen=proof-gen\n");
  writeFileSync(`${state}/corrupt.omp-session.json`, "{bad");
  installTaskSessionProof(pi, state, "corrupt");
  assert.throws(start);
  assert.equal(readFileSync(`${state}/corrupt.omp-session.json`, "utf8"), "{bad");
  // Relaunch replaces the old generation's binding before its JSONL exists.
  const replacement = `${linkedSessions}/replacement.jsonl`;
  const canonicalReplacement = `${realpathSync(sessions)}/replacement.jsonl`;
  writeFileSync(`${state}/demo.meta`, "spawn_gen=replacement-gen\n");
  const child = spawnSync(process.execPath, ["--input-type=module", "-"], {
    encoding: "utf8",
    env: { ...process.env, FM_SPAWN_GEN: "replacement-gen", FM_REPLACEMENT_FILE: replacement },
    input: `
      import assert from "node:assert/strict";
      import { existsSync, readFileSync, writeFileSync, realpathSync } from "node:fs";
      import { pathToFileURL } from "node:url";
      const { installTaskSessionProof } = await import(pathToFileURL(process.env.EXT).href);
      const state = process.env.FM_PROOF_CASE;
      const handlers = new Map();
      const pi = { pi: { AgentRegistry: { global() { return { list() { return globalThis.proofRefs; } }; } } }, on(event, handler) { handlers.set(event, handler); } };
      installTaskSessionProof(pi, state, "demo");
      let file = process.env.FM_REPLACEMENT_FILE;
      const ctx = { sessionManager: { getSessionFile() { return file; } } };
      globalThis.proofRefs = [{ kind: "main", session: { sessionManager: ctx.sessionManager, waitForSessionTransition() { return Promise.resolve(); } } }];
      const start = () => handlers.get("session_start")({}, ctx);
      const record = () => JSON.parse(readFileSync(state + "/demo.omp-session.json", "utf8"));
      const canonical = ${JSON.stringify(canonicalReplacement)};
      assert.equal(existsSync(file), false);
      start();
      const expected = { version: 1, spawn_gen: "replacement-gen", pid: process.pid, task_session_file: canonical, current_session_file: canonical };
      assert.deepEqual(record(), expected);
      assert.equal(existsSync(file), false);
      writeFileSync(file, "{}\\n");
      start();
      assert.deepEqual(record(), expected);
      file = ${JSON.stringify(personal)};
      start();
      assert.deepEqual(record(), { ...expected, current_session_file: realpathSync(file) });
      assert.notEqual(record().current_session_file, record().task_session_file);
      file = ${JSON.stringify(`${linkedSessions}/replacement-personal.jsonl`)};
      start();
      assert.equal(existsSync(file), false);
      assert.deepEqual(record(), { ...expected, current_session_file: ${JSON.stringify(`${realpathSync(sessions)}/replacement-personal.jsonl`)} });
      installTaskSessionProof(pi, state, "demo"); start();
      assert.equal(record().task_session_file, canonical);
      file = process.env.FM_REPLACEMENT_FILE; start();
      assert.deepEqual(record(), expected);
    `,
  });
  assert.equal(child.status, 0, child.stderr || child.error?.message);
  assert.notEqual(child.pid, process.pid);
  assert.deepEqual(record(), { version: 1, spawn_gen: "replacement-gen", pid: child.pid, task_session_file: canonicalReplacement, current_session_file: canonicalReplacement });
  delete process.env.FM_SPAWN_GEN;
  installTaskSessionProof(pi, state, "absent");
  start();
  assert.equal(existsSync(`${state}/absent.omp-session.json`), false);
} finally { console.warn = originalWarn; }
EOF
  status=$?
  expect_code 0 "$status" "omp task-session proof follows activation and fails closed"
  pass ".omp task-session proof: pending canonical binding survives persistence, personal resume, reload, return, and fresh-generation replacement"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  declare -F "$FM_TEST_ONLY" >/dev/null || fail "unknown test: $FM_TEST_ONLY"
  "$FM_TEST_ONLY"
  exit $?
fi

test_task_session_proof_tracks_active_session
test_spawn_refuses_unsupported_omp_before_launch
# omp puts a queued user follow-up back into the composer when a run is
# interrupted (Esc, including fm-control interrupt) or dequeued (Alt+Up), which
# leaves a delivered watcher wake unsubmitted. The watch extension must find that
# wake, remove only its own text, and submit it again, while never touching an
# operator's draft or a wake a run already consumed. The idle-* scenarios pin
# the other stall: a wake arriving at an idle lane whose context ends in an
# advisor note must start its own turn instead of waiting as a follow-up.
# Each scenario runs in its own process because the arm fixture fires exactly
# one actionable close.
run_watch_restore_scenario() {  # <scenario>
  local scenario=$1 repo home
  repo="$TMP_ROOT/watch-restore-$scenario/repo"; home="$TMP_ROOT/watch-restore-$scenario/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
# The extension confirms a handling handoff through this same script; answering
# at once keeps its synchronous call from blocking the whole run.
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
if [[ "${SCENARIO:-}" = idle-recovery-* ]]; then
  while [ ! -e "$FM_HOME/state/.e2e-ready" ]; do sleep 0.05; done
fi
if [ ! -e "${FM_HOME:?}/state/.e2e-fired" ] || { [[ "${SCENARIO:-}" = duplicates* ]] && [ ! -e "$FM_HOME/state/.e2e-fired-again" ]; }; then
  if [ -e "$FM_HOME/state/.e2e-fired" ]; then
    : > "$FM_HOME/state/.e2e-fired-again"
  else
    : > "$FM_HOME/state/.e2e-fired"
  fi
  sleep 1
  case "${SCENARIO:-}" in
    editor-normalized*) printf 'signal: omp-restore ready\tdetail\rcarriage\001control\013vertical\037unit done\n' ;;
    *) printf 'signal: omp-restore done\n' ;;
  esac
  exit 0
fi
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # Output goes to a file, not a pipe: the fixture's long-lived arm child would
  # otherwise hold a command substitution open for its whole sleep.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_OMP_SUCCESSOR_GRACE_MS=100 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    SCENARIO="$scenario" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module >"$home/scenario.out" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, readFileSync, existsSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); const commands = new Map(); let tool = null; const sent = []; const turns = [];
let receiveWake;
const wakeReceived = new Promise((resolve) => { receiveWake = resolve; });
const transcript = [{ role: "assistant" }];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand(name, command) { commands.set(name, command); },
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    sent.push({ m, o });
    receiveWake();
    if (process.env.SCENARIO === "sync-consumed") {
      handlers.get("before_agent_start")({ prompt: m }, ctx);
      handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
    }
    if (process.env.SCENARIO === "failed-send") throw new Error("fixture send rejected");
    // omp's idle auto-continue refuses an explicit follow-up behind an advisor tail.
    if (process.env.SCENARIO === "custom-tail" || process.env.SCENARIO.startsWith("idle-")) {
      if (o?.deliverAs) { queued = true; return undefined; }
      if (idle) {
        turns.push({ prompt: m, tail: transcript.at(-1) });
        transcript.push({ role: "user", content: m });
        idle = false;
        handlers.get("before_agent_start")({ prompt: m }, ctx);
        handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
      } else {
        queued = true;
      }
    }
    return undefined;
  },
};
// The composer omp would show, with the editor calls the extension may use.
let editorText = "";
const composer = {
  get text() { return editorText; },
  set text(t) { editorText = t.replace(/\r\n?/g, "\n").replaceAll("\t", "   ").replace(/[\x00-\x09\x0b-\x1f]/g, ""); },
  sets: [],
};
// Restored-wake scenarios deliver behind a running turn; idle-* scenarios
// deliver to a lane that already went idle.
let idle = process.env.SCENARIO.startsWith("idle-"); let queued = false;
const ctx = {
  hasUI: true,
  isIdle: () => { if (process.env.SCENARIO === "idle-stale-context" || process.env.SCENARIO === "idle-recovery-stale") throw new Error("stale context"); return idle; },
  hasPendingMessages: () => queued,
  ui: { getEditorText: () => composer.text, setEditorText: (t) => { composer.sets.push(t); composer.text = t; } },
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
if (["nonpending", "failed-send"].includes(process.env.SCENARIO)) {
  const dir = `${process.env.FM_HOME}/state/extensions/omp-primary-watch`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/session-replacement-actionable.json`, "invalid");
  writeFileSync(`${process.env.FM_HOME}/state/.e2e-fired`, "");
}
// The vernant-d2-custody shape: the last turn ended, omp's advisor then posted
// its note as the context tail, and the composer is empty or holds a draft.
const advisorTail = { role: "custom", customType: "advisor", content: "advisor note posted after the turn" };
if (process.env.SCENARIO.startsWith("idle-")) transcript.push(advisorTail);
if (process.env.SCENARIO === "idle-draft") composer.text = "my unsent draft";
const editorBefore = composer.text;
const scenario = process.env.SCENARIO;
const recovery = scenario.startsWith("idle-recovery-");
const repairContext = scenario.endsWith("-context");
const initialContext = scenario === "idle-recovery-missing" ? undefined
  : repairContext ? { isIdle() { throw new Error("retired context"); } } : ctx;
await handlers.get("session_start")({ type: "session_start" }, initialContext);
if (recovery) {
  const predecessorTool = tool;
  if (scenario !== "idle-recovery-live-factory") await handlers.get("session_shutdown")({}, undefined);
  if (scenario.includes("factory") || scenario === "idle-recovery-forwarded") mod.default(pi);
  if (scenario.includes("command")) await commands.get("fm-watch-arm-omp").handler("", ctx);
  else if (scenario.includes("tool")) await tool.execute("repair", {}, undefined, undefined, repairContext ? ctx : undefined);
  else if (scenario === "idle-recovery-forwarded") await predecessorTool.execute("repair", {}, undefined, undefined, ctx);
  else {
    const log = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/lifecycle.log`;
    for (let i = 0; i < 60 && !readFileSync(log, "utf8").includes("event=self-heal "); i++) await sleep(50);
    if (!readFileSync(log, "utf8").includes("event=self-heal ")) throw new Error("missing automatic recovery");
  }
  if (scenario === "idle-recovery-busy") idle = false;
  writeFileSync(`${process.env.FM_HOME}/state/.e2e-ready`, "");
} else if (!["nonpending", "failed-send"].includes(scenario)) await tool.execute();
if (["nonpending", "failed-send"].includes(process.env.SCENARIO)) {
  await sleep(50);
  if (sent.length !== 1 || !sent[0].m.includes("could not load a replacement-session actionable wake")) throw new Error("expected nonpending load-failure wake");
  const wake = sent[0].m;
  if (process.env.SCENARIO !== "failed-send") {
    await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: wake }] } }, ctx);
  }
  idle = true;
  composer.text = wake;
  await handlers.get("agent_end")({ type: "agent_end" }, ctx);
  await sleep(2500);
  if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== wake) throw new Error("failed or consumed nonpending wake was recovered");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
const expectedWakes = process.env.SCENARIO.startsWith("duplicates") ? 2 : 1;
if (recovery) await wakeReceived;
else for (let i = 0; i < 600 && sent.length < expectedWakes; i += 1) await sleep(100);
if (sent.length !== expectedWakes) throw new Error(`expected ${expectedWakes} wakes, saw ${sent.length}`);
const wake = sent[0].m;
if (recovery && !wake.includes("signal: omp-restore done")) throw new Error(`recovery did not deliver its actionable close: ${wake}`);
if (["idle-stale-context", "idle-recovery-stale", "idle-recovery-busy", "idle-recovery-missing"].includes(scenario)) {
  if (sent[0].o?.deliverAs !== "followUp" || !queued || turns.length !== 0) throw new Error("delivery without positive idle evidence must remain a follow-up");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
if (process.env.SCENARIO.startsWith("idle-")) {
  if (sent[0].o?.deliverAs !== undefined || queued) throw new Error(`an idle wake was queued as a follow-up: ${JSON.stringify(sent[0].o)}`);
  const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
  if (existsSync(handoff)) throw new Error("a consumed idle wake retained its replacement handoff");
  if (turns.length !== 1 || turns[0].prompt !== wake || turns[0].tail !== advisorTail) throw new Error("an idle wake behind an advisor tail did not start its own turn");
  if (composer.sets.length !== 0 || composer.text !== editorBefore) throw new Error("idle delivery touched the composer");
  idle = true;
  await handlers.get("agent_end")({ type: "agent_end" }, ctx);
  await sleep(2500);
  if (sent.length !== 1 || composer.text !== editorBefore) throw new Error("a consumed idle wake was sent again");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
// The running turn behind which the wake was queued has ended.
idle = true;
if (sent[0].o?.deliverAs !== "followUp") throw new Error("regular delivery must remain queued as a follow-up");
const bare = wake.startsWith("\u2063") ? wake.slice(1) : wake;
if (process.env.SCENARIO === "sync-consumed") {
  composer.text = wake;
  await handlers.get("agent_end")({ type: "agent_end" }, ctx);
  await sleep(2500);
  if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== wake) throw new Error("synchronously consumed wake was recovered");
  await handlers.get("session_shutdown")({}, ctx);
  process.exit(0);
}
const settle = async () => { await handlers.get("agent_end")({ type: "agent_end" }, ctx); await sleep(2500); };
const same = (item) => item.m === wake && item.o?.deliverAs === undefined;

switch (process.env.SCENARIO) {
  case "duplicates":
  case "duplicates-handoff":
  case "duplicates-streaming": {
    if (sent[1].m !== wake || sent[1].o?.deliverAs !== "followUp") throw new Error("expected two identical queued wakes");
    const consumePrompt = async () => {
      await handlers.get("before_agent_start")({ prompt: wake }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: wake }] } }, ctx);
    };
    if (process.env.SCENARIO === "duplicates-streaming") {
      await consumePrompt();
      await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    } else {
      composer.text = `${wake}\n\n${wake}`;
      await settle();
      if (sent.length !== 3 || !same(sent[2]) || composer.text !== wake) throw new Error("first duplicate recovery did not preserve the second wake");
      await consumePrompt();
      if (process.env.SCENARIO === "duplicates-handoff") {
        const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
        await handlers.get("session_shutdown")({}, ctx);
        const stored = JSON.parse(readFileSync(handoff, "utf8"));
        if (stored.pending.length !== 1 || stored.pending[0].delivered || !wake.includes(stored.pending[0].message)) throw new Error("unsubmitted duplicate did not retain its handoff record");
        await handlers.get("session_start")({}, ctx);
        for (let i = 0; i < 60 && sent.length < 4; i += 1) await sleep(100);
        if (sent.length !== 4 || sent[3].m !== wake || sent[3].o?.deliverAs !== undefined) throw new Error("idle replacement did not replay the unsubmitted duplicate as its own turn");
        await consumePrompt();
        await handlers.get("session_shutdown")({}, ctx);
        if (existsSync(handoff)) throw new Error("consumed duplicates retained a handoff record");
        process.exit(0);
      }
      await settle();
      if (sent.length !== 4 || !same(sent[3]) || composer.text !== "") throw new Error("second identical wake was no longer recoverable");
      await consumePrompt();
    }
    composer.text = wake;
    const count = sent.length;
    const sets = composer.sets.length;
    await settle();
    if (sent.length !== count || composer.sets.length !== sets || composer.text !== wake) throw new Error("consumed duplicates were recovered again");
    break;
  }
  case "editor-normalized":
  case "editor-normalized-message":
  case "editor-normalized-edited": {
    composer.text = wake;
    if (composer.text !== wake || !wake.includes("ready   detail\ncarriagecontrolverticalunit done")) throw new Error("emitted wake is not editor-stable");
    if (process.env.SCENARIO === "editor-normalized-edited") {
      composer.text = composer.text.replace("detail", "operator edit");
      const edited = composer.text;
      await settle();
      if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== edited) throw new Error("edited normalized wake was submitted or changed");
      break;
    }
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== "") throw new Error("untouched normalized wake was not resubmitted");
    if (process.env.SCENARIO === "editor-normalized-message") {
      await handlers.get("message_start")({ message: { role: "user", content: [{ type: "text", text: sent[1].m }] } }, ctx);
    } else {
      await handlers.get("before_agent_start")({ prompt: sent[1].m }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: sent[1].m } }, ctx);
    }
    composer.text = wake;
    const sets = composer.sets.length;
    await settle();
    if (sent.length !== 2 || composer.sets.length !== sets || composer.text !== wake) throw new Error("consumed normalized wake was recovered again");
    break;
  }
  case "custom-tail": {
    if (!queued || turns.length !== 0) throw new Error("regular wake did not remain queued");
    queued = false;
    const tail = { role: "custom", customType: "advisor", content: "advisor transcript tail" };
    transcript.push(tail);
    const draft = "\noperator\u2063 draft\n\n";
    composer.text = `${wake}\n\n${draft}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error("idle custom-tail wake was not sent through prompt flow");
    if (turns.length !== 1 || turns[0].prompt !== wake || turns[0].tail !== tail) throw new Error("idle recovery did not start handling after the advisor tail");
    if (composer.text !== draft) throw new Error("custom-tail recovery changed operator draft bytes");
    idle = true;
    await settle();
    if (sent.length !== 2 || turns.length !== 1 || composer.text !== draft) throw new Error("consumed custom-tail wake was recovered again");
    break;
  }
  case "normalized-consumed": {
    const prompt = bare.replace(/\s/g, "").replace(/(.{17})/g, "$1\n \t");
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: prompt } }, ctx);
    composer.text = wake;
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== "") throw new Error("normalized text consumed an exact wake identity");
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: wake }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    composer.text = wake;
    await settle();
    if (sent.length !== 2 || composer.text !== wake) throw new Error("exact wake consumption was not retained");
    break;
  }
  case "preparation-cancelled":
  case "preparation-handoff": {
    const draft = "\noperator\u2063 draft\n\n";
    composer.text = `${wake}\n\n${draft}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== draft) throw new Error("first recovery did not preserve the draft");
    await handlers.get("before_agent_start")({ prompt: wake }, ctx);
    const sets = composer.sets.length;
    await sleep(2500);
    if (sent.length !== 2 || composer.sets.length !== sets || composer.text !== draft) throw new Error("cancelled preparation resubmitted the wake or changed the preserved draft");
    if (process.env.SCENARIO === "preparation-cancelled") {
      composer.text = "";
      idle = false;
      await handlers.get("before_agent_start")({ prompt: draft }, ctx);
      await handlers.get("message_start")({ message: { role: "user", content: draft } }, ctx);
      idle = true;
      await settle();
      if (sent.length !== 2 || composer.sets.length !== sets || composer.text !== "") throw new Error("later completed draft turn recovered a wake absent from the editor");
    }
    const preservedEditor = composer.text;
    const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
    await handlers.get("session_shutdown")({}, ctx);
    const stored = JSON.parse(readFileSync(handoff, "utf8"));
    if (stored.pending.length !== 1 || stored.pending[0].delivered || !wake.includes(stored.pending[0].message)) throw new Error("cancelled preparation retired its pending handoff");
    await handlers.get("session_start")({}, ctx);
    for (let i = 0; i < 60 && sent.length < 3; i += 1) await sleep(100);
    if (sent.length !== 3 || sent[2].m !== wake || sent[2].o?.deliverAs !== undefined) throw new Error("idle replacement lost the preparation-cancelled wake");
    await handlers.get("before_agent_start")({ prompt: wake }, ctx);
    if (JSON.parse(readFileSync(handoff, "utf8")).pending.length !== 1) throw new Error("replacement preparation retired its handoff");
    await handlers.get("message_start")({ message: { role: "assistant", content: wake } }, ctx);
    if (!existsSync(handoff)) throw new Error("assistant message retired the wake");
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    await handlers.get("session_shutdown")({}, ctx);
    if (existsSync(handoff)) throw new Error("accepted replay retained its handoff");
    if (composer.text !== preservedEditor) throw new Error("replacement changed the preserved editor");
    process.exit(0);
  }
  case "consumed": {
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: wake }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    composer.text = wake;
    await settle();
    if (sent.length !== 1) throw new Error(`a consumed wake was sent again: ${sent.length}`);
    if (composer.sets.length !== 0 || composer.text !== wake) throw new Error("a consumed wake changed the composer");
    break;
  }
  case "draft": {
    // omp joins restored messages and the operator's draft with a blank line.
    composer.text = `${wake}\n\nmy unsent draft`;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error(`the restored wake was not submitted again: ${JSON.stringify(sent)}`);
    if (composer.text !== "my unsent draft") throw new Error(`the operator draft was not preserved exactly: ${JSON.stringify(composer.text)}`);
    await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: wake }, ctx);
    await handlers.get("message_start")({ message: { role: "user", content: wake } }, ctx);
    await settle();
    if (sent.length !== 2) throw new Error(`a consumed resubmission was sent a third time: ${sent.length}`);
    if (composer.text !== "my unsent draft") throw new Error("the draft changed after the wake was consumed");
    break;
  }
  case "draft-before": {
    composer.text = `my unsent draft\n\n${bare}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error(`the restored wake was not submitted again: ${JSON.stringify(sent)}`);
    if (composer.text !== "my unsent draft") throw new Error(`the operator draft was not preserved exactly: ${JSON.stringify(composer.text)}`);
    break;
  }
  case "draft-after-bytes":
  case "draft-before-bytes":
  case "draft-both": {
    const before = "\n\nbefore\u2063 draft\n\n";
    const after = "\u2063\n\nafter draft\n\n";
    const scenario = process.env.SCENARIO;
    composer.text = scenario === "draft-after-bytes" ? `${wake}\n\n${after}` : scenario === "draft-before-bytes" ? `${before}\n\n${bare}` : `${before}\n\n${wake}\n\n${after}`;
    const expected = scenario === "draft-after-bytes" ? after : scenario === "draft-before-bytes" ? before : `${before}\n\n${after}`;
    await settle();
    if (sent.length !== 2 || !same(sent[1]) || composer.text !== expected) throw new Error(`draft bytes changed: ${JSON.stringify(composer.text)} expected ${JSON.stringify(expected)}`);
    break;
  }
  case "prepended":
  case "appended":
  case "appended-newline":
  case "prepended-mark":
  case "appended-mark":
  case "internal-mark":
  case "edited": {
    const scenario = process.env.SCENARIO;
    composer.text = scenario === "prepended" ? `Do not run: ${wake}`
      : scenario === "appended" ? `${wake} do not run`
      : scenario === "appended-newline" ? `${wake}\n`
      : scenario === "prepended-mark" ? `\u2063${wake}`
      : scenario === "appended-mark" ? `${wake}\u2063`
      : scenario === "internal-mark" ? wake.replace("signal:", "sig\u2063nal:")
      : wake.replace("signal:", "edited:");
    const original = composer.text;
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0 || composer.text !== original) throw new Error("edited wake was submitted or changed");
    break;
  }
  case "alone":
  case "alone-marked": {
    composer.text = process.env.SCENARIO === "alone" ? bare : wake;
    await settle();
    if (sent.length !== 2 || !same(sent[1])) throw new Error(`the restored wake was not submitted again: ${JSON.stringify(sent)}`);
    if (composer.text !== "") throw new Error(`the composer still holds text after the resubmission: ${JSON.stringify(composer.text)}`);
    break;
  }
  case "busy": {
    composer.text = wake; idle = false;
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0) throw new Error("a running turn was disturbed");
    break;
  }
  case "queued": {
    composer.text = wake; queued = true;
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0) throw new Error("a wake with messages still queued was submitted again");
    break;
  }
  case "elsewhere": {
    composer.text = "an unrelated operator draft";
    await settle();
    if (sent.length !== 1 || composer.sets.length !== 0) throw new Error("a composer without the wake was touched");
    break;
  }
  case "limit": {
    // An operator who keeps interrupting must not turn recovery into a loop.
    for (let i = 0; i < 6; i += 1) { composer.text = wake; await settle(); }
    if (sent.length !== 4) throw new Error(`recovery was not bounded to three resubmissions: ${sent.length}`);
    break;
  }
  default:
    throw new Error(`unknown scenario ${process.env.SCENARIO}`);
}
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
  local status=$?
  cat "$home/scenario.out"
  return "$status"
}

test_watch_extension_resubmits_a_wake_omp_restored_to_the_composer() {
  local scenario out status
  for scenario in duplicates duplicates-handoff duplicates-streaming preparation-cancelled preparation-handoff editor-normalized editor-normalized-message editor-normalized-edited nonpending failed-send sync-consumed consumed normalized-consumed draft custom-tail idle-empty idle-draft idle-stale-context idle-recovery-timer idle-recovery-factory idle-recovery-live-factory idle-recovery-tool idle-recovery-command idle-recovery-forwarded idle-recovery-tool-context idle-recovery-command-context idle-recovery-busy idle-recovery-stale idle-recovery-missing draft-before draft-after-bytes draft-before-bytes draft-both prepended appended appended-newline prepended-mark appended-mark internal-mark edited alone alone-marked busy queued elsewhere limit; do
    out=$(run_watch_restore_scenario "$scenario")
    status=$?
    expect_code 0 "$status" "omp watch restore scenario $scenario: $out"
    [ -z "$out" ] || fail "omp watch restore scenario $scenario printed output: $out"
  done
  pass ".omp watch extension: an idle lane's wake starts its own turn behind an advisor tail; a wake omp restored to the composer is submitted again alone, bounded, and never over a draft or a running turn"
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
await first.handlers.get("session_start")({}, {});
await waitFor(() => first.sent.length === 1 && arms() === 2);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
mkdirSync(handoff);
let owner = first;
if (process.env.REPAIR === "factory") {
  owner = makePi(); mod.default(owner.pi);
} else {
  await first.handlers.get("session_shutdown")({}, {});
}
rmSync(handoff, { recursive: true });
if (process.env.REPAIR === "command") {
  const notifications = [];
  await owner.commands.get("fm-watch-arm-omp").handler("", { ui: { notify(message) { notifications.push(message); } } });
  if (notifications.length !== 1 || !notifications[0].startsWith("watcher: started")) throw new Error("command repair was poisoned by publication failure");
} else {
  const repaired = await owner.box.tool.execute();
  if (!repaired.details.ok || !repaired.details.message.startsWith("watcher: started")) throw new Error("tool repair was poisoned by publication failure");
}
await waitFor(() => owner.sent.some((message) => message.includes("could not persist a replacement-session actionable wake")));
const failures = owner.sent.filter((message) => message.includes("could not persist a replacement-session actionable wake"));
if (failures.length !== 1 || !failures[0].includes("check: publication failure wake")) throw new Error("repair lost the actionable wake or its persistence failure");
await owner.handlers.get("message_start")({ message: { role: "user", content: failures[0] } }, {});
await sleep(900);
if (arms() !== 3) throw new Error("publication failure repair double-armed");
const unchanged = await owner.box.tool.execute();
if (!unchanged.details.ok || !unchanged.details.message.includes("unchanged")) throw new Error("repaired watcher lost ordinary arm ownership");
await owner.handlers.get("session_shutdown")({}, {});
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
test_watch_extension_runs_the_supervision_host
test_watch_extension_runs_the_supervision_host quiet
test_watch_extension_keeps_the_arm_without_the_file_or_with_off
test_watch_extension_replays_a_host_only_boundary_across_replacement
test_watch_extension_delivers_a_split_host_close_whole
test_watch_extension_resubmits_a_wake_omp_restored_to_the_composer
test_primary_extensions_ignore_a_descendant_session
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries
test_watch_extension_heals_a_generation_stopped_without_a_successor
test_watch_extension_is_single_instance_per_home
test_watch_extension_repairs_after_handoff_publication_failure
