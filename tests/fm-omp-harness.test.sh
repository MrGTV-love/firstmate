#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - omp harness regressions (detection, launch, no-helpers, and model routing).
set -u

# shellcheck source=tests/fm-omp-harness-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-omp-harness-helpers.sh"

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
    PATH="$bin:$PATH" "$bin/omp" -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "a process named omp must detect as omp, got '$out'"
  for decoy in ompd comp; do
    # shellcheck disable=SC2016 # the quoted body expands inside the named shell
    out=$(env -u CLAUDECODE -u FM_OMP_HARNESS -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      PATH="$bin:$PATH" "$bin/$decoy" -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
    [ "$out" != omp ] || fail "'$decoy' merely contains omp and must not detect as omp"
  done
  # The marker beats an inherited CLAUDECODE only under a real omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    PATH="$bin:$PATH" "$bin/omp" -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
  [ "$out" = omp ] || fail "FM_OMP_HARNESS under an omp ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # ...and is inert when it leaks into a worker with no omp ancestor.
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS CLAUDECODE=1 FM_OMP_HARNESS=omp \
    PATH="$bin:$PATH" bash -c 'export FM_ANCESTRY_FIXTURE_PID=$$; "$1"; :' _ "$HARNESS")
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

test_spawn_refuses_unsupported_omp_before_launch() {
  local kind version rec id out status
  local -a args
  for kind in ship scout secondmate; do
    id="omp-old-$kind"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    for version in 18.1.11 18.1.19; do
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
  mkdir -p "$HOME_DIR/state"
  printf 'model=deepseek/deepseek-v4-pro\nerror=402 old run\n' > "$HOME_DIR/state/$id.live-model"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-astra --effort medium)
  status=$?
  expect_code 0 "$status" "omp scout spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=omp" "spawn did not report the omp harness"
  state="$HOME_DIR/state"
  assert_grep "harness=omp" "$state/$id.meta" "meta missing harness=omp"
  assert_grep "model=openai-codex/gpt-6-astra" "$state/$id.meta" "meta missing the pinned model"
  assert_grep "effort=medium" "$state/$id.meta" "meta missing the pinned effort"
  assert_present "$state/$id.omp-ext.ts" "omp spawn did not write the per-task extension"
  assert_absent "$state/$id.live-model" "a launch must not keep a previous session's live-model record"
  launch=$(cat "$LAUNCH_LOG")
  assert_launch_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u FM_DSH_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1 '$FAKEBIN_DIR/omp'" \
    "omp launch did not clear foreign markers and establish its own at the launch boundary"
  assert_launch_contains "$launch" "--config '$ROOT/.omp/fm-session-overlay.yml' --auto-approve --cwd '$WT_DIR' --config '$ROOT/.omp/fm-worker-overlay.yml'" \
    "omp scout launch did not carry shared posture and worker-only memory overlays"
  assert_launch_contains "$launch" "--model 'openai-codex/gpt-6-astra' --thinking 'medium' -e '$state/$id.omp-ext.ts'" \
    "omp launch did not pass the model, thinking level, and the state-resident worker extension"
  assert_launch_contains "$launch" "encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md'" "omp launch lost the canonical typed launch-brief envelope"
  assert_launch_contains "$launch" "-e '$state/$id.omp-ext.ts' \"\$(" "omp launch must keep exactly one positional brief after the extension flag"
  [ "$(fm_busy_classify tmux fake:w omp "$id" "$state")" = "busy fm-spawn" ] \
    || fail "omp spawn must seed the busy-state contract"
  pass "fm-spawn: the omp launch line clears markers, pins posture, and wires the state-resident extension"
}

test_no_helpers_rejects_nonworker_launches() {
  local rec id out status kind
  for kind in claude secondmate; do
    id="no-helper-invalid-$kind"
    rec=$(make_spawn_case "$id" "$kind" "$id")
    read_case_record "$rec"
    if [ "$kind" = secondmate ]; then
      out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        "$id" "$HOME_DIR" --secondmate --harness omp --omp-no-helpers)
    else
      out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness claude --omp-no-helpers)
    fi
    status=$?
    expect_code 1 "$status" "no-helper posture must refuse $kind: $out"
    assert_contains "$out" "--omp-no-helpers requires a canonical omp ship or scout launch" \
      "the $kind refusal must name the canonical omp ship or scout requirement"
    assert_absent "$HOME_DIR/state/$id.meta" "unsupported no-helper launch must not publish a task"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported no-helper posture launched an agent"
  done
  pass "no-helper posture rejects other runtimes and supervisor sessions before publishing or launching"
}

test_native_attempt_path_isolated_per_launch() {
  local rec id="omp-attempt-$$" out meta gen prior_gen tmp stage capture expected actual
  rec=$(make_spawn_case native-attempt omp "$id")
  read_case_record "$rec"
  meta="$HOME_DIR/state/$id.meta"
  prior_gen=
  for stage in initial replacement disabled; do
    capture=1
    [ "$stage" != disabled ] || capture=0
    if [ "$stage" = initial ]; then
      out=$(FM_OMP_CODEX_ATTEMPT_CAPTURE="$capture" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort low)
    else
      out=$(FM_OMP_CODEX_ATTEMPT_CAPTURE="$capture" run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id")
    fi
    expect_code 0 $? "$stage synthetic preparation must succeed: $out"
    gen=$(sed -n 's/^spawn_gen=//p' "$meta")
    tmp=$(sed -n 's/^tasktmp=//p' "$meta")
    [ -n "$gen" ] && [ "$gen" != "$prior_gen" ] && [ -n "$tmp" ] || fail "$stage did not record a fresh launch"
    expected="$tmp/omp-codex-attempts.$gen.jsonl"
    [ "$stage" != disabled ] || expected='<unset>'
    # Replay the emitted launch verbatim as a fresh shell with a deliberately
    # stale ambient path. Refuse to execute a launch that lost its fake tool.
    assert_launch_contains "$(<"$LAUNCH_LOG")" "'$FAKEBIN_DIR/omp'" "$stage launch must name only the fake OMP binary"
    printf 'FM_FAKE_OMP_REPORT_ATTEMPT_PATH=1\n' > "$FAKEBIN_DIR/.fm-fake-config"
    actual=$(HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" \
      FM_OMP_CODEX_ATTEMPT_JOURNAL="$CASE_DIR/other-launch.jsonl" bash "$LAUNCH_LOG")
    rm -f "$FAKEBIN_DIR/.fm-fake-config"
    expect_code 0 $? "$stage captured launch shell must succeed: $actual"
    assert_equals "attempt-journal=$expected" "$actual" "$stage native capture used the wrong path"
    prior_gen=$gen
  done
  pass 'ordinary OMP launch: opt-in native journal is pinned to a fresh launch and opt-out ignores an ambient destination'
}

test_no_helpers_launch_contract() {
  local rec id out status meta fallback
  id="omp-no-helpers-contract"
  rec=$(make_spawn_case no-helpers-contract omp "$id" firstmate)
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/config"
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"easy work","use":{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low","provider":"codex"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]}]}
JSON
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness omp --model openai-codex/gpt-6-luna --dispatch-rule rule_1 --omp-no-helpers)
  expect_code 0 $? "no-helper spawn should succeed: $out"
  meta="$HOME_DIR/state/$id.meta"
  fallback="$HOME_DIR/state/$id.omp-fallback.yml"
  assert_no_helper_launch "first" "$LAUNCH_LOG" "$fallback" "$meta"

  out=$(run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id")
  expect_code 0 $? "same-harness relaunch of a no-helper task should succeed: $out"
  assert_no_helper_launch "relaunched" "$LAUNCH_LOG" "$fallback" "$meta"

  cp "$meta" "$CASE_DIR/prior.meta"
  sed -i.bak 's/^omp_no_helpers=on$/omp_no_helpers=maybe/' "$meta"
  rm -f "$meta.bak"
  cp "$meta" "$CASE_DIR/invalid.meta"
  out=$(run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id")
  status=$?
  expect_code 1 "$status" "an invalid recorded no-helper posture must be refused: $out"
  assert_contains "$out" "invalid recorded omp_no_helpers posture for $id" "the refusal must name the invalid record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused relaunch launched an agent"
  cmp -s "$CASE_DIR/invalid.meta" "$meta" || fail "a refused relaunch changed the task record"
  pass "no-helper launch, emptied fallback, record, relaunch inheritance and invalid-record refusal hold"
}

test_no_helpers_refuses_ultra_effort() {
  local rec id out status
  id="omp-no-helpers-ultra"
  rec=$(make_spawn_case no-helpers-ultra omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --harness omp --effort ultra --omp-no-helpers)
  status=$?
  expect_code 1 "$status" "omp has no ultra effort, so a no-helper launch must refuse it: $out"
  assert_contains "$out" "ultra effort requires pi or pi-signed" "the refusal must name the ultra requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused ultra launch must not publish a task"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused ultra launch started an agent"
  pass "no-helper omp launch refuses ultra effort before publishing or launching"
}

test_omp_workers_disable_openrouter_prompt_helpers() {
  local scope kind rec id out launch overlay role
  local -a model_args
  for scope in firstmate vernant; do
    for kind in ship scout; do
      id="omp-title-$scope-$kind"
      rec=$(make_spawn_case "title-$scope-$kind" omp "$id" "$scope")
      read_case_record "$rec"
      printf 'modelRoles:\n  default: openai-codex/gpt-6-astra\n' > "$GLOBAL_CONFIG"
      model_args=()
      role=pi/default
      if [ "$kind" = scout ]; then
        model_args=(--model openai-codex/gpt-6-luna)
        role=openai-codex/gpt-6-luna
      fi
      if [ "$kind" = ship ]; then
        out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
          "$id" "$PROJ_DIR" --harness omp --mode no-mistakes --yolo off ${model_args[@]+"${model_args[@]}"})
      else
        out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp ${model_args[@]+"${model_args[@]}"})
      fi
      expect_code 0 $? "omp $scope $kind spawn should succeed: $out"
      overlay="$HOME_DIR/state/$id.omp-fallback.yml"
      launch=$(cat "$LAUNCH_LOG")
      assert_launch_contains "$launch" " --no-title " "an ordinary omp $scope $kind launch must disable title generation"
      assert_worker_helper_policy "an ordinary omp $scope $kind launch" "$overlay" "$role"
      assert_not_contains "$launch" "--no-extensions" "an ordinary omp $scope $kind launch must keep its extension"
      assert_not_contains "$launch" "--no-skills" "an ordinary omp $scope $kind launch must keep skill discovery"
      out=$(run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" ${model_args[@]+"${model_args[@]}"})
      expect_code 0 $? "omp $scope $kind relaunch should succeed: $out"
      assert_contains "$(cat "$LAUNCH_LOG")" " --no-title " "an omp $scope $kind relaunch must disable title generation"
      assert_worker_helper_policy "an omp $scope $kind relaunch" "$overlay" "$role"
    done
  done
  jq '. + {skillful: false}' "$overlay" > "$CASE_DIR/skillful-false.json"
  ! (assert_worker_helper_policy "a planted skillful=false" "$CASE_DIR/skillful-false.json" "$role") 2>/dev/null \
    || fail "the helper-policy check must reject an overlay that turns skill listing off"
  jq '. + {disabledProviders: ["openrouter"]}' "$overlay" > "$CASE_DIR/disabled-array.json"
  ! (assert_worker_helper_policy "a planted disabledProviders" "$CASE_DIR/disabled-array.json" "$role") 2>/dev/null \
    || fail "the helper-policy check must reject an overlay that replaces disabledProviders"
  pass "every canonical omp ship and scout launch and relaunch disables titles and routes smol and tiny to the worker's own model with scalar roles only"
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
  local scope project rec id out expected
  local -a extra
  for scope in firstmate vernant no-helpers; do
    project=$scope
    extra=()
    [ "$scope" != no-helpers ] || { project=firstmate; extra=(--omp-no-helpers); }
    id="omp-scope-$scope"
    rec=$(make_spawn_case "scope-$scope" omp "$id" "$project")
    read_case_record "$rec"
    printf '\nEgress needs: ["semantic-search"]\n' >> "$HOME_DIR/data/$id/brief.md"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp ${extra[@]+"${extra[@]}"})
    expect_code 0 $? "omp $scope spawn should succeed: $out"
    expected=off
    [ "$scope" != firstmate ] || expected=on
    assert_equals "$expected" "$(jq -r .find.enabled "$HOME_DIR/state/$id.omp-fallback.yml")" \
      "the task overlay must admit native find only for a firstmate-project worker"
    printf 'TYPESAFE_API_KEY=omp-scope-key\nOPENROUTER_API_KEY=omp-fallback-key\n' > "$HOME_DIR/.env"
    out=$(EXT_PATH="$HOME_DIR/state/$id.omp-ext.ts" PROJECT="$scope" WT="$WT_DIR" FM_TEST_SEAM=1 \
      node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { pathToFileURL } from "node:url";
const requests = [];
const server = createServer((req, res) => {
  let body = "";
  req.on("data", chunk => { body += chunk; });
  req.on("end", () => {
    requests.push({ path: req.url, body });
    res.statusCode = 500;
    res.end();
  });
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
try {
  const base = `http://127.0.0.1:${server.address().port}`;
  process.env.FM_JEV_GUARD_BASE_URL = `${base}/direct`;
  const handlers = {};
  const providers = [];
  (await import(pathToFileURL(process.env.EXT_PATH))).default({ registerProvider: (name, config) => providers.push({ name, ...config }), on: (name, fn) => { handlers[name] = fn; }, pi: { AgentRegistry: { global: () => ({ list: () => [] }) } } });
  assert.deepEqual(providers.map(row => [row.name, row.baseUrl]), [["typesafe", "https://api.typesafe.ai"]]);
  const credential = () => execFileSync("/bin/sh", ["-c", providers[0].apiKey.slice(1)], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  const result = await handlers.tool_call({ toolName: "write", input: { path: "customer-record.txt", content: "fixture" } }, { cwd: process.env.WT });
  assert.equal(result, undefined, "a worktree write is admitted without a judgment");
  assert.deepEqual(requests, [], "no write sends a guard request");
  if (process.env.PROJECT === "firstmate") assert.equal(credential(), "omp-scope-key");
  else assert.throws(credential, "a non-firstmate worker must have no native judge credential");
} finally {
  await new Promise(resolve => server.close(resolve));
}
console.log("scope-ok");
JS
)
    [ "$out" = scope-ok ] || fail "generated omp extension lost $scope egress scope: $out"
  done
  pass "real omp spawns give firstmate alone, without no-helpers, native find, and a judge credential, and no write sends a guard request"
}

test_spawn_retains_pooled_capacity_and_declared_stand_ins() {
  local rec id=omp-pool-q1 out status
  rec=$(make_spawn_case pool omp "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/config"
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"easy work","use":{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high","provider":"codex"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]}]}
JSON
  jq -n --argjson now "$(date +%s)" '{reports:[
    {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}},
    {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}
  ]}' > "$CASE_DIR/usage.json"
  out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high --dispatch-rule rule_1)
  expect_code 0 $? "a healthy pooled sibling must permit launch: $out"
  assert_grep 'model=openai-codex/gpt-6-luna' "$HOME_DIR/state/$id.meta" "pooled launch must retain Luna"

  rec=$(make_spawn_case fallback omp omp-fallback-q2)
  read_case_record "$rec"
  id='omp-fallback-q2'
  mkdir -p "$HOME_DIR/config"
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"easy work","use":{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high","provider":"codex"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]}]}
JSON
  jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}}]}' > "$CASE_DIR/usage.json"
  out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high --dispatch-rule rule_1)
  status=$?
  expect_code 0 "$status" "whole-pool exhaustion must select the permitted Luna stand-in: $out"
  assert_grep 'model=lab/native-model' "$HOME_DIR/state/$id.meta" "the replacement route must become durable"
  assert_grep 'fallback launched' "$HOME_DIR/state/$id.status" "the changed serving route must be reported"
  pass "launch preserves healthy pooled accounts and uses only the selected rule's stand-in"
}

test_spawn_fixed_family() {
  test_spawn_launch_model_history
  test_spawn_ship_native_fallback_authors
  test_spawn_fixed_family_contract
  test_spawn_fixed_family_scope
}

test_spawn_native_fallback_preserves_destination_order() {
  local rec id out status ordering expected
  for ordering in cross-first native-first restricted; do
    id="omp-order-$ordering"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    mkdir -p "$HOME_DIR/config"
    printf 'teamclaude\n' > "$HOME_DIR/config/claude-launcher"
    fm_test_fake_teamclaude "$FAKEBIN_DIR"
    jq -n --arg order "$ordering" '
      {harness:"omp",model:"lab/native-model",effort:"high"} as $native |
      {harness:"claude",model:"claude-opus-5-5[1m]",effort:"high",requires:"teamclaude"} as $cross |
      {harness:"omp",model:"ollama/qwen3:8b",effort:"high"} as $last |
      {rules:[{when:"work",use:{harness:"omp",model:"openai-codex/gpt-6-luna",effort:"high"},
        fallback:(if $order == "native-first" then [$native,$cross,$last] else [$cross,$native] end)}]}
    ' > "$HOME_DIR/config/crew-dispatch.json"
    if [ "$ordering" = restricted ]; then
      printf 'omp-or-tc\n' > "$HOME_DIR/config/session-launch-policy"
    fi
    jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
      metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}]}' > "$CASE_DIR/usage.json"
    out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high --dispatch-rule rule_1)
    status=$?
    expect_code 0 "$status" "ordered native fallback launch: $out"
    expected='["lab/native-model:high"]'
    [ "$ordering" != cross-first ] || expected='[]'
    assert_equals "$expected" "$(jq -c '.retry.fallbackChains["openai-codex/gpt-6-luna:high"]' "$HOME_DIR/state/$id.omp-fallback.yml")" \
      "native fallback stops at the first supported cross-harness destination"
    if [ "$ordering" = restricted ]; then
      jq '.reports[].metadata.meterStates.chat={allowed:false,limitReached:true}' "$CASE_DIR/usage.json" > "$CASE_DIR/exhausted.json"
      fm_test_spawn_brief "$HOME_DIR" "$id-empty"
      out=$(OMP_USAGE_FIXTURE="$CASE_DIR/exhausted.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id-empty" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high --dispatch-rule rule_1)
      status=$?
      expect_code 0 "$status" "restricted exhaustion must select the allowed native destination: $out"
      assert_grep 'harness=omp' "$HOME_DIR/state/$id-empty.meta" "fallback must not bypass launch policy"
      assert_grep 'model=lab/native-model' "$HOME_DIR/state/$id-empty.meta" "fallback uses the next policy-eligible destination"
    fi
  done
  pass "native chains preserve fallback order and shared launch policy"
}

test_spawn_rejects_retired_fallbacks_before_publication() {
  local rec id out status capacity
  for capacity in usable exhausted; do
    id="omp-retired-$capacity"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    mkdir -p "$HOME_DIR/config"
    printf '%s\n' '{"version":1,"roles":{},"retired":["native-model"]}' > "$HOME_DIR/config/model-index.json"
    printf '%s\n' '{"rules":[{"when":"work","use":{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
    jq -n --arg state "$capacity" --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
      metadata:{meterStates:{chat:{allowed:($state=="usable"),limitReached:($state=="exhausted")}}}}]}' > "$CASE_DIR/usage.json"
    out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high --dispatch-rule rule_1)
    status=$?
    expect_code 1 "$status" "a retired fallback must refuse for $capacity capacity: $out"
    assert_absent "$HOME_DIR/state/$id.meta" "retired fallback refusal must precede task publication"
    assert_absent "$HOME_DIR/state/$id.omp-fallback.yml" "retired fallback refusal must precede native chain emission"
  done
  pass "retired fallback refusal covers launch-time selection and runtime chains"
}

test_spawn_route_class_constrains_stand_ins() {
  local rec id out status case_name
  for case_name in powerful fast manual malformed; do
    id="omp-route-$case_name"
    rec=$(make_spawn_case "route-$case_name" omp "$id")
    read_case_record "$rec"
    mkdir -p "$HOME_DIR/config"
    printf '%s\n' '{"rules":[{"when":"strong work","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high","provider":"codex"},"fallback":[{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
    jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
      metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},
      limits:[{scope:{modelId:"gpt-6.1-sol"},status:"exhausted",amount:{remainingFraction:0}}]}]}' > "$CASE_DIR/usage.json"
    case "$case_name" in
      powerful) route=powerful:high ;;
      fast) route=fast:high ;;
      manual) route= ;;
      malformed) route=cheap:medium ;;
    esac
    out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --harness omp --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1 ${route:+--dispatch-route "$route"})
    status=$?
    case "$case_name" in
      powerful|malformed)
        expect_code 1 "$status" "a $case_name route must not launch the cheap stand-in: $out"
        assert_absent "$HOME_DIR/state/$id.meta" "a refused $case_name stand-in must precede task publication"
        ;;
      fast)
        expect_code 0 "$status" "a fast route may take the declared cheap stand-in: $out"
        assert_grep 'model=openai-codex/gpt-6-luna' "$HOME_DIR/state/$id.meta" "the fast route serves the stand-in"
        assert_grep 'effort=high' "$HOME_DIR/state/$id.meta" "the stand-in effort is clamped to the route level"
        assert_grep 'dispatch_route=fast:high' "$HOME_DIR/state/$id.meta" "the typed route follows recovery"
        ;;
      manual)
        expect_code 0 "$status" "an unrestricted route keeps the declared stand-in: $out"
        assert_grep 'model=openai-codex/gpt-6-luna' "$HOME_DIR/state/$id.meta" "the manual route serves the stand-in"
        assert_grep 'effort=low' "$HOME_DIR/state/$id.meta" "the manual stand-in keeps its declared effort"
        assert_no_grep 'dispatch_route=' "$HOME_DIR/state/$id.meta" "a manual route records no typed route"
        ;;
    esac
  done
  pass "typed route class and effort constrain launch stand-ins while manual routes are unchanged"
}

test_spawn_ignores_stale_unrelated_rules() {
  local rec id=omp-unrelated-stale out status
  rec=$(make_spawn_case "$id" omp "$id")
  read_case_record "$rec"
  mkdir -p "$HOME_DIR/config"
  printf '%s\n' '{"version":1,"roles":{},"retired":["native-model"]}' > "$HOME_DIR/config/model-index.json"
  printf '%s\n' '{"rules":[{"when":"easy work","use":{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high"}},{"when":"unconfigured","use":{"harness":"omp","role":"missing-role"}},{"when":"strong work","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]},{"when":"invalid stand-in","use":{"harness":"omp","model":"openai-codex/gpt-6-astra","effort":"high"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"ultra"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
  jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
    metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}]}' > "$CASE_DIR/usage.json"
  out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high)
  status=$?
  expect_code 0 "$status" "a retired, unconfigured, or invalid unrelated rule must not block the launch: $out"
  assert_grep 'model=openai-codex/gpt-6-luna' "$HOME_DIR/state/$id.meta" "the launch keeps its own route"
  assert_no_grep 'dispatch_rule=' "$HOME_DIR/state/$id.meta" "a rule without a fallback policy records no identifier"
  pass "stale unrelated dispatch rules do not block a launch"
}

test_spawn_exhausted_strongest_route_preserves_unlanded_work() {
  local rec id=omp-strongest-q3 out status
  rec=$(make_spawn_case strongest omp "$id")
  read_case_record "$rec"
  printf 'unlanded work\n' > "$WT_DIR/unfinished.txt"
  jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}},resetCredits:{availableCount:1}}]}' > "$CASE_DIR/usage.json"
  out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6.1-sol --effort high)
  status=$?
  expect_code 1 "$status" "Sol without an available same-class stand-in must refuse: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "refused launch must publish no replacement"
  assert_equals 'unlanded work' "$(cat "$WT_DIR/unfinished.txt")" "quota exhaustion must preserve work"
  pass "strongest-model exhaustion neither spends saved resets nor weakens or discards the task"
}

test_spawn_refuses_api_billed_routes() {
  local provider kind rec id out status index=0
  local -a args
  for provider in openai openrouter OpenAI oPeNrOuTeR; do
    for kind in ship scout secondmate; do
      index=$((index + 1))
      id="omp-api-$index-$kind"
      rec=$(make_spawn_case "$id" omp "$id")
      read_case_record "$rec"
      case "$kind" in
        ship) args=(--mode local-only --yolo off) ;;
        scout) args=(--scout) ;;
        secondmate) args=(--secondmate) ;;
      esac
      out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        "$id" "$PROJ_DIR" --harness omp --model "$provider/gpt-6.1-sol" "${args[@]}" 2>&1)
      status=$?
      expect_code 1 "$status" "API-billed omp route must refuse $kind: $out"
      assert_contains "$out" "openai-codex/" "refusal must name the subscription route"
      [ ! -s "$LAUNCH_LOG" ] || fail "API-billed route reached $kind launch"
      assert_absent "$HOME_DIR/state/$id.meta" "refusal must not publish task metadata"
    done
  done
  for provider in openai openrouter OpenAI oPeNrOuTeR; do
    index=$((index + 1))
    id="omp-api-indexed-$index"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    printf '{"version":1,"roles":{"strong":{"omp":{"model":"%s/gpt-6.1-sol"}}},"retired":[]}\n' "$provider" \
      > "$HOME_DIR/config/model-index.json"
    out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness omp --model role:strong 2>&1)
    expect_code 1 $? "indexed API-billed route must refuse: $out"
    assert_contains "$out" 'openai-codex/' "indexed model must not bypass the billing guard"
    [ ! -s "$LAUNCH_LOG" ] || fail "indexed API-billed route launched"
    assert_absent "$HOME_DIR/state/$id.meta" "indexed refusal must publish no metadata"
  done
  pass "fm-spawn refuses omp openai and openrouter routes before any worker launches"
}

test_spawn_raw_api_billing_admission() {
  local provider form spelling flag value rec id out status command expected index=0 profile
  for provider in openai openrouter OpenAI oPeNrOuTeR openai-codex; do
    for form in long equals short; do
      for spelling in plain escaped ansi; do
        index=$((index + 1))
        id="omp-raw-billing-$index"
        rec=$(make_spawn_case "$id" omp "$id")
        read_case_record "$rec"
        flag=--model
        [ "$form" != short ] || flag=-m
        case "$spelling" in
          plain) value="'$provider/gpt-6.1-sol'" ;;
          escaped)
            flag='--mo\del'
            [ "$form" != short ] || flag='-\m'
            value="$provider/gpt\\-6.1-sol"
            ;;
          ansi)
            flag="\$'--mo\\x64el'"
            [ "$form" != short ] || flag="\$'-\\x6d'"
            value="\$'$provider/gpt\\x2d6.1-sol'"
            ;;
        esac
        if [ "$form" = equals ]; then command="omp $flag=$value"; else command="omp $flag $value"; fi
        out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" "$command")
        status=$?
        expected=1
        [ "$provider" != openai-codex ] || expected=0
        expect_code "$expected" "$status" "raw $form $spelling billing admission for $provider: $out"
        if [ "$expected" = 0 ]; then
          assert_present "$HOME_DIR/state/$id.meta" "subscription raw launch must publish metadata"
          assert_launch_contains "$(cat "$LAUNCH_LOG")" "$command" "subscription argv must reach the launch unchanged"
        else
          assert_contains "$out" 'routes use API billing' "raw rejection must come from the billing guard"
          assert_absent "$HOME_DIR/state/$id.meta" "raw refusal must precede publication"
          [ ! -s "$LAUNCH_LOG" ] || fail "forbidden raw model reached launch"
        fi
      done
    done
  done
  while IFS='|' read -r command profile expected; do
    index=$((index + 1))
    id="omp-raw-billing-$index"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    command=${command//__EVALUATED__/$CASE_DIR/evaluated}
    out=$(OMP_PROFILE="$profile" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" "$command" --model openai-codex/gpt-6.1-sol)
    status=$?
    expect_code "$expected" "$status" "literal raw admission in '$command': $out"
    if [ "$expected" = 0 ]; then
      assert_present "$HOME_DIR/state/$id.meta" "non-model arguments must remain accepted"
      assert_launch_contains "$(cat "$LAUNCH_LOG")" "$command" "non-model arguments must reach the launch unchanged"
    else
      assert_contains "$out" 'routes use API billing' "profile, expansion, or prior pin must not bypass literal admission"
      assert_absent "$HOME_DIR/state/$id.meta" "raw refusal must precede publication"
      [ ! -s "$LAUNCH_LOG" ] || fail "forbidden raw model reached launch"
    fi
    assert_absent "$CASE_DIR/evaluated" "raw validation must not evaluate the shell"
  done <<'CASES'
omp --model openai/gpt-6.1-sol|billing|1
omp --profile billing -m openrouter/gpt-6.1-sol||1
omp --model openai-codex/gpt-6.1-sol --model=openai/gpt-6.1-sol||1
omp __MODELFLAG__ -m openrouter/gpt-6.1-sol||1
omp --model openai/gpt-6.1-sol --prompt "$PROMPT"||1
omp -m openrouter/gpt-6.1-sol --prompt "$(touch __EVALUATED__)"||1
omp --model "$MODEL"||0
omp --model "$(touch __EVALUATED__; printf openai/gpt-6.1-sol)"||0
omp --model=openai/$MODEL||0
omp --model openai-codex/gpt-6.1-sol --append-system-prompt '--model=openai/gpt-6.1-sol'||0
omp --model openai-codex/gpt-6.1-sol --append-system-prompt --model openai/gpt-6.1-sol||0
omp --model openai-codex/gpt-6.1-sol --system-prompt -m openrouter/gpt-6.1-sol||0
omp --append-system-prompt --model --model openai/gpt-6.1-sol||1
omp --system-prompt -m --model=openrouter/gpt-6.1-sol||1
omp --append-system-prompt='--model=openai/gpt-6.1-sol' --model openai-codex/gpt-6.1-sol||0
omp --resume --model openai/gpt-6.1-sol||1
omp -r saved-session --model=openrouter/gpt-6.1-sol||1
omp -e /fixture/plan-mode.ts --plan --model OpenAI/gpt-6.1-sol||1
omp -e /fixture/plan-mode.ts --plan --model=oPeNrOuTeR/gpt-6.1-sol||1
omp -e /fixture/plan-mode.ts --plan -m openai/gpt-6.1-sol||1
omp --plan --model openai-codex/gpt-6.1-sol||0
omp --plan --model=openai-codex/gpt-6.1-sol||0
omp --plan -m openai-codex/gpt-6.1-sol||0
omp --plan saved-plan.md --model OpenAI/gpt-6.1-sol||1
omp --plan saved-plan.md --model openai-codex/gpt-6.1-sol||0
omp --plan=saved-plan.md --model=oPeNrOuTeR/gpt-6.1-sol||1
omp --plan=saved-plan.md --model=openai-codex/gpt-6.1-sol||0
omp -- --model openai/gpt-6.1-sol||0
omp '--model openrouter/gpt-6.1-sol'||0
CASES
  pass "raw omp model flags refuse API billing and preserve subscription and non-model arguments"
}

test_spawn_api_billed_fallback_admission() {
  local provider capacity destination rec id out status expected index=0
  for provider in openai openrouter OpenAI oPeNrOuTeR openai-codex; do
    for capacity in usable exhausted; do
      index=$((index + 1))
      id="omp-fallback-billing-$index"
      rec=$(make_spawn_case "$id" omp "$id")
      read_case_record "$rec"
      destination="$provider/gpt-6.1-sol"
      jq -n --arg destination "$destination" '{models:[
        {provider:"openai-codex",id:"gpt-6-luna",selector:"openai-codex/gpt-6-luna"},
        {provider:($destination|split("/")[0]),id:"gpt-6.1-sol",selector:$destination}
      ]}' > "$(dirname "$GLOBAL_CONFIG")/catalog.json"
      jq -n --arg destination "$destination" '{rules:[{when:"work",
        use:{harness:"omp",model:"openai-codex/gpt-6-luna",effort:"high"},
        fallback:[{harness:"omp",model:$destination,effort:"high"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
      jq -n --arg state "$capacity" --argjson now "$(date +%s)" '{reports:[{
        provider:"openai-codex",fetchedAt:($now*1000),
        limits:[{scope:{modelId:"gpt-6-luna"},status:$state,
          amount:{unit:"percent",remaining:(if $state=="usable" then 90 else 0 end)}}],
        metadata:{source:"ratelimit-headers"}
      }]}' > "$CASE_DIR/usage.json"
      out=$(PI_CODING_AGENT_DIR="$(dirname "$GLOBAL_CONFIG")" OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" \
        run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6-luna --effort high --dispatch-rule rule_1)
      status=$?
      expected=0
      if [ "$capacity" = exhausted ] && [ "$provider" != openai-codex ]; then expected=1; fi
      expect_code "$expected" "$status" "catalog-listed fallback admission for $destination with $capacity primary: $out"
      if [ "$expected" = 1 ]; then
        assert_contains "$out" 'no supported permitted fallback' "forbidden fallback must not rescue an exhausted primary"
        assert_absent "$HOME_DIR/state/$id.meta" "fallback refusal must precede publication"
        assert_absent "$HOME_DIR/state/$id.omp-fallback.yml" "fallback refusal must not emit a native chain"
        [ ! -s "$LAUNCH_LOG" ] || fail "forbidden fallback reached launch"
      elif [ "$capacity" = usable ]; then
        expected='[]'
        [ "$provider" != openai-codex ] || expected='["openai-codex/gpt-6.1-sol:high"]'
        assert_equals "$expected" "$(jq -c '.retry.fallbackChains["openai-codex/gpt-6-luna:high"]' \
          "$HOME_DIR/state/$id.omp-fallback.yml")" "native chain must admit only the subscription destination"
        assert_grep 'model=openai-codex/gpt-6-luna' "$HOME_DIR/state/$id.meta" "usable primary must stay selected"
      else
        assert_grep 'model=openai-codex/gpt-6.1-sol' "$HOME_DIR/state/$id.meta" "subscription fallback must remain selectable"
        assert_launch_contains "$(cat "$LAUNCH_LOG")" "--model 'openai-codex/gpt-6.1-sol'" "subscription fallback must reach launch"
      fi
    done
  done
  pass "fallback admission excludes API-billed destinations from selection and native chains"
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
  assert_launch_contains "$(cat "$LAUNCH_LOG")" "--model 'claude-bridge/claude-opus-4-8'" "pass-through model did not reach the launch line"

  rec=$(make_spawn_case model-fuzzy omp omp-model-fuzzy-q4)
  read_case_record "$rec"
  id='omp-model-fuzzy-q4'
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness omp --model astra)
  status=$?
  expect_code 0 "$status" "a bare fuzzy pattern is omp's own matcher's job: $out"
  pass "fm-spawn: omp model validation is scoped to providers the listing can prove"
}

test_spawn_refuses_unsupported_omp_before_launch
test_spawn_fixed_family
test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_refuses_api_billed_routes
test_spawn_raw_api_billing_admission
test_spawn_api_billed_fallback_admission
test_spawn_launch_line_and_worker_wiring
test_native_attempt_path_isolated_per_launch
test_no_helpers_rejects_nonworker_launches
test_no_helpers_launch_contract
test_no_helpers_refuses_ultra_effort
test_omp_workers_disable_openrouter_prompt_helpers
test_worker_replace_mode_environment
test_worker_guard_project_scope
test_spawn_retains_pooled_capacity_and_declared_stand_ins
test_spawn_native_fallback_preserves_destination_order
test_spawn_rejects_retired_fallbacks_before_publication
test_spawn_route_class_constrains_stand_ins
test_spawn_ignores_stale_unrelated_rules
test_spawn_exhausted_strongest_route_preserves_unlanded_work
test_spawn_model_validation_scoped_to_listed_providers
