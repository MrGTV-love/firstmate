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
#      overlay, --auto-approve, --cwd, and (for a crewmate) one -e pointing at
#      state/<id>.omp-ext.ts; a secondmate launch names that same busy -e and
#      nothing else, leaving its primary extensions to auto-discovery.
#   4. A <provider>/<id> model is validated only when `omp models --json` lists
#      that provider; an unlisted provider passes through with a notice.
#   5. Busy state: agent_start is busy, agent_end with willContinue stays busy,
#      a plain agent_end is idle, turn_end is a notification only.
#   6. The turn-end guard extension compels one continuation on exit 2 and
#      stands down when the payload already carries stop_hook_active.
#   7. The watch extension arms through fm_watch_arm_omp and delivers an
#      actionable close as one follow-up.
set -u
# shellcheck disable=SC2034

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-status-event-lib.sh
. "$ROOT/bin/fm-status-event-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$ROOT/bin/fm-session-lock-lib.sh"

# shellcheck disable=SC2034
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
  # Keep the real process-name proof, but bound ancestry to the named fixture
  # shell: this suite itself can legitimately run under an OMP ancestor.
  cat > "$dir/ps" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-o ppid= -p ${FM_ANCESTRY_FIXTURE_PID:-}" ]; then
  printf '1\n'
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$dir/ps"
  printf '%s' "$dir"
}

# --- 2. Launch ---------------------------------------------------------------

# A fake omp that answers `models --json` with a two-provider catalog and exits
# 0 for everything else (the launch itself is only recorded by the fake tmux).
make_fake_omp() {  # <fakebin>
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
[ ! -f "${0%/*}/.fm-fake-config" ] || . "${0%/*}/.fm-fake-config"
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
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"openai-codex","id":"gpt-6-luna","selector":"openai-codex/gpt-6-luna"},{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"},{"provider":"lab","id":"native-model","selector":"lab/native-model"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
  usage)
    if [ -n "${OMP_USAGE_FIXTURE:-}" ]; then cat "$OMP_USAGE_FIXTURE"; else printf '{}\n'; fi
    ;;
  *)
    if [ "${FM_FAKE_OMP_REPORT_ATTEMPT_PATH:-0}" = 1 ]; then
      printf 'attempt-journal=%s\n' "${FM_OMP_CODEX_ATTEMPT_JOURNAL-<unset>}"
    fi
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

# The emitted launch, the generated fallback overlay and the task record are
# the consumer-visible contract of --omp-no-helpers: a regression in any of them
# silently returns secondary-model routes to a worker meant to have none.
assert_no_helper_launch() {  # <label> <launch-log> <fallback-yml> <meta>
  local label=$1 launch fallback=$3 meta=$4 flag
  launch=$(cat "$2")
  assert_launch_contains "$launch" "--config '$ROOT/.omp/fm-no-helpers-overlay.yml'" "$label launch lost the no-helper overlay"
  for flag in --no-title --no-extensions --no-skills --no-rules; do
    assert_launch_contains "$launch" " $flag" "$label launch lost $flag"
  done
  assert_launch_contains "$launch" " --tools read,bash,edit,write,grep,glob,todo,ask " "$label launch lost the restricted tool list"
  assert_launch_contains "$launch" "--thinking 'high'" "$label launch must pin non-auto thinking"
  assert_equals '[]' "$(jq -c .retry.fallbackChains.default "$fallback")" "$label launch must keep no default fallback chain"
  assert_equals '[]' "$(jq -c '[.retry.fallbackChains | to_entries[] | select(.key != "default") | .value[]]' "$fallback")" \
    "$label launch must keep no stand-in fallback entry"
  assert_grep 'omp_no_helpers=on' "$meta" "$label record lost omp_no_helpers=on"
  assert_equals '[false,false,false]' "$(jq -c '[has("modelRoles"), has("disabledProviders"), has("skillful")]' "$fallback")" \
    "$label task overlay must leave helper policy to the no-helper overlay"
  if [ "${OMP_NO_HELPERS_SKILLFUL_CHECKED:-0}" = 0 ]; then
    assert_equals false "$(ruby -ryaml -rjson -e 'print JSON.generate(YAML.safe_load(File.read(ARGV[0]))["skillful"])' "$ROOT/.omp/fm-no-helpers-overlay.yml")" \
      "the no-helper overlay must keep automatic skill listing off"
    OMP_NO_HELPERS_SKILLFUL_CHECKED=1
  fi
}

# Run a same-harness relaunch of a published task against the fake tmux stub.
run_omp_relaunch() {  # <home> <wt> <fakebin> <launch-log> <id> [spawn-args...]
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5
  local bin
  shift 5
  : > "$launchlog"
  # The recorded window is listed and its pane runs an idle shell, which is
  # the positively agent-free endpoint a relaunch requires.
  bin="$fakebin/relaunch-shell"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pane_current_command*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$fakebin/tmux" "\$@"
SH
  chmod +x "$bin/tmux"
  FM_FAKE_DUPLICATE_WINDOW="$(sed -n 's/^window=[^:]*://p' "$home/state/$id.meta")" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$bin:$fakebin" "$id" --relaunch "$@"
}

# Titles and the smol and tiny helper roles (skill-description compression
# among them) can select a credentialed OpenRouter model. An ordinary worker
# keeps automatic skill listing, so its task overlay must point those roles at
# its own model with scalar values only, never an array that would replace the
# operator's disabledProviders, on launch and relaunch, in Firstmate and in
# other projects.
assert_worker_helper_policy() {  # <label> <overlay> <role>
  assert_equals "[\"$3\",\"$3\"]" "$(jq -c '[.modelRoles.smol, .modelRoles.tiny]' "$2")" "$1 must assign smol and tiny to the worker's own model"
  assert_equals '[false,false]' "$(jq -c '[has("skillful"), has("disabledProviders")]' "$2")" \
    "$1 must keep automatic skill listing and leave the operator's disabledProviders alone"
}

test_spawn_fixed_family_contract() {
  local posture rec id out status overlay expected
  for posture in default fixed; do
    id="omp-family-$posture"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    printf '%s\n' '{"rules":[{"when":"review","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"fallback":[{"harness":"omp","model":"lab/native-model","effort":"high"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
    jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
      metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}]}' > "$CASE_DIR/usage.json"
    local -a args=()
    [ "$posture" != fixed ] || args+=(--fixed-family)
    out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1 ${args[@]+"${args[@]}"})
    status=$?
    expect_code 0 "$status" "$posture family scout launch: $out"
    overlay="$HOME_DIR/state/$id.omp-fallback.yml"
    if [ "$posture" = default ]; then
      expected="$CASE_DIR/prechange-overlay.json"
      jq -n '{modelRoles:{smol:"openai-codex/gpt-6.1-sol",tiny:"openai-codex/gpt-6.1-sol"},
        find:{enabled:"off"},retry:{modelFallback:true,fallbackChains:{default:[],
          "openai-codex/gpt-6.1-sol":["lab/native-model:high"],
          "openai-codex/gpt-6.1-sol:high":["lab/native-model:high"],
          "lab/native-model":[],"lab/native-model:high":[]}}}' > "$expected"
      cmp -s "$expected" "$overlay" || fail "default fallback overlay differs from pre-change bytes: $(cat "$overlay")"
      assert_no_grep 'fixed_family=' "$HOME_DIR/state/$id.meta" "ordinary scouts must not acquire fixed-family posture"
      pass "default fallback overlay matches pre-change bytes"
    else
      assert_equals '{"default":[],"openai-codex/gpt-6.1-sol":[],"openai-codex/gpt-6.1-sol:high":[]}' \
        "$(jq -c .retry.fallbackChains "$overlay")" "fixed-family must empty default, model and effort chains"
      assert_grep 'fixed_family=on' "$HOME_DIR/state/$id.meta" "fixed-family posture must be durable"
      out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" \
        --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1)
      expect_code 0 $? "fixed-family relaunch should inherit the posture: $out"
      assert_equals '{"default":[],"openai-codex/gpt-6.1-sol":[],"openai-codex/gpt-6.1-sol:high":[]}' \
        "$(jq -c .retry.fallbackChains "$overlay")" "relaunch must retain empty model and effort chains"
      assert_grep 'fixed_family=on' "$HOME_DIR/state/$id.meta" "relaunch must retain fixed-family posture"
      out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
        FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
        "$ROOT/bin/fm-promote.sh" "$id" --mode local-only --yolo off 2>&1)
      expect_code 0 $? "promoting a fixed-family scout should succeed: $out"
      assert_grep 'kind=ship' "$HOME_DIR/state/$id.meta" "promotion must make the task a ship"
      assert_no_grep 'fixed_family=' "$HOME_DIR/state/$id.meta" "a ship must not keep the scout-only fixed-family posture"
      out=$(OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" \
        --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1)
      expect_code 0 $? "a promoted fixed-family scout must stay relaunchable: $out"
      assert_equals '["lab/native-model:high"]' \
        "$(jq -c '.retry.fallbackChains["openai-codex/gpt-6.1-sol:high"]' "$overlay")" "a promoted ship relaunches with ordinary chains"
    fi
  done
  pass "fixed-family empties native chains, survives relaunch, and is dropped on promotion"
}

test_spawn_fixed_family_scope() {
  local kind rec id out status
  for kind in ship secondmate; do
    id="omp-family-$kind"
    rec=$(make_spawn_case "$id" omp "$id")
    read_case_record "$rec"
    local -a args=()
    if [ "$kind" = ship ]; then args+=(--mode no-mistakes --yolo off); else args+=(--secondmate); fi
    out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --harness omp --fixed-family "${args[@]}" 2>&1)
    status=$?
    expect_code 1 "$status" "fixed-family must refuse $kind: $out"
    assert_contains "$out" '--fixed-family applies only to scout tasks' "refusal must explain the task-kind boundary"
    assert_absent "$HOME_DIR/state/$id.meta" "refused task must not publish metadata"
    assert_absent "$HOME_DIR/state/$id.omp-fallback.yml" "refused task must not emit an overlay"
    [ ! -s "$LAUNCH_LOG" ] || fail "fixed-family $kind reached launch"
  done
  id="family-claude"
  rec=$(make_spawn_case "$id" claude "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness claude --fixed-family 2>&1)
  expect_code 0 $? "other harnesses must accept fixed-family as a no-op: $out"
  assert_contains "$out" '--fixed-family has no effect on harness' "other harnesses need a plain no-op note"
  assert_absent "$HOME_DIR/state/$id.omp-fallback.yml" "other harnesses must not receive an omp overlay"
  id="family-raw"
  rec=$(make_spawn_case "$id" omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" 'omp --auto-approve' --fixed-family 2>&1)
  expect_code 1 $? "a raw launch must not claim a fixed family: $out"
  assert_contains "$out" '--fixed-family requires a canonical omp launch' "raw launches need a plain refusal reason"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused raw launch must publish no record"
  assert_absent "$HOME_DIR/state/$id.omp-fallback.yml" "a refused raw launch must emit no overlay"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused raw fixed-family launch reached launch"
  pass "fixed-family refuses non-scouts and raw launches before launch and notes non-omp no-op"
}

test_spawn_launch_model_history() {
  local rec id out history prefix first second tab
  tab=$(printf '\t')
  id='omp-author-history'
  rec=$(make_spawn_case "$id" omp "$id")
  read_case_record "$rec"
  out=$(run_scout_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6.1-sol --effort high)
  expect_code 0 $? "initial author-history launch: $out"
  history="$HOME_DIR/state/$id.launch-models"
  first=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$first" ] || fail "initial launch recorded no spawn_gen"
  assert_equals "$first$tab${tab}openai-codex/gpt-6.1-sol" "$(cat "$history")" "initial launch binds its author to its incarnation"
  prefix=$(cat "$history")
  out=$(run_omp_relaunch "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" \
    --model anthropic/claude-opus-5-5 --effort high)
  expect_code 0 $? "cross-family author-history relaunch: $out"
  second=$(sed -n 's/^spawn_gen=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$second" ] && [ "$second" != "$first" ] || fail "relaunch did not record a new spawn_gen"
  assert_equals "$prefix
$second$tab$first${tab}openai-codex/gpt-6.1-sol
$second$tab$first${tab}anthropic/claude-opus-5-5" "$(cat "$history")" "relaunch appends linked to the prior incarnation without erasing the old author"
  assert_grep 'model=anthropic/claude-opus-5-5' "$HOME_DIR/state/$id.meta" "current model changes while history retains both authors"
  pass "launch-model history preserves both families across relaunch"
}

test_spawn_ship_native_fallback_authors() {
  local rec id out base head url rc reader groups
  id='omp-ship-fallback-authors'
  rec=$(make_spawn_case "$id" omp "$id")
  read_case_record "$rec"
  printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"},{"provider":"anthropic","id":"claude-opus-5-5","selector":"anthropic/claude-opus-5-5"}]}' \
    > "$(dirname "$GLOBAL_CONFIG")/catalog.json"
  printf '%s\n' '{"rules":[{"when":"work","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"fallback":[{"harness":"omp","model":"anthropic/claude-opus-5-5","effort":"high"}]}]}' > "$HOME_DIR/config/crew-dispatch.json"
  jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
    metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}]}' > "$CASE_DIR/usage.json"
  out=$(PI_CODING_AGENT_DIR="$(dirname "$GLOBAL_CONFIG")" OMP_USAGE_FIXTURE="$CASE_DIR/usage.json" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" --harness omp --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1 --mode local-only --yolo off 2>&1)
  expect_code 0 $? "cross-family native fallback ship launch: $out"
  assert_equals '["anthropic/claude-opus-5-5:high"]' \
    "$(jq -c '.retry.fallbackChains["openai-codex/gpt-6.1-sol:high"]' "$HOME_DIR/state/$id.omp-fallback.yml")" "the ship session may switch to the Claude stand-in"
  base=$(git -C "$WT_DIR" rev-parse HEAD)
  git -C "$WT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q --allow-empty -m 'ship implementation'
  head=$(git -C "$WT_DIR" rev-parse HEAD)
  url=https://github.com/example/repo/pull/9
  printf 'VERDICT: PASS head=%s\n' "$head" > "$CASE_DIR/review.md"
  for reader in claude-opus-5-5:openai-codex/gpt-6.1-sol claude-opus-5-5:both openai-codex/gpt-6.1-sol:both; do
    groups='{"ship":["openai-codex/gpt-6.1-sol","anthropic/claude-opus-5-5"]}'
    [ "${reader#*:}" = both ] || groups="{\"ship\":[\"${reader#*:}\"]}"
    out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-review-record.py" review --pr "$url" --head "$head" \
      --verdict PASS --reader-model "${reader%%:*}" --author-groups "$groups" \
      --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report "$CASE_DIR/review.md" 2>&1)
    expect_code 0 $? "record the $reader read: $out"
    rc=0
    out=$(NM_HOME="$CASE_DIR/no-mistakes" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-review-record.py" verify --pr "$url" --head "$head" \
      --task "$id" --base "$base" 2>&1) || rc=$?
    case "$reader" in
      claude-opus-5-5:openai-codex/gpt-6.1-sol)
        expect_code 1 "$rc" "one Claude PASS of the launch model must not verify a ship that may fall back to Claude: $out"
        assert_contains "$out" 'uncovered commit group ship, family anthropic,openai;' "the derived ship group names the launch and fallback families" ;;
      claude-opus-5-5:both)
        expect_code 1 "$rc" "one Claude PASS must not cover the Claude fallback author: $out"
        assert_contains "$out" 'uncovered commit group ship, family anthropic;' "the Claude fallback family needs a different-family read" ;;
      *) expect_code 0 "$rc" "reads from both families must verify the launch and fallback authors: $out" ;;
    esac
  done
  pass "omp ship native fallback stand-ins are ship author evidence"
}

# --- 3. Busy state -------------------------------------------------------------

drive_omp_ext() {  # <ext-path> <mode>
  EXT_PATH="$1" MODE="$2" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
// omp calls every handler registered for an event, so the fake does too: the
// busy-state writer and the live-model publisher both listen to agent_start and
// agent_end.
const registered = {};
const handlers = {};
// The extension API exposes the host SDK; the session proof only reads the
// live registry from it inside its own handlers, which these modes never fire.
mod.default({ registerProvider() {}, on: (name, fn) => {
  (registered[name] ||= []).push(fn);
  handlers[name] = async (...args) => { for (const h of registered[name]) await h(...args); };
}, pi: { AgentRegistry: { global: () => ({}) } } });
// ctx.isIdle() reads false at a natural TUI agent_end on omp; the extension
// must go idle on a plain agent_end regardless of it.
const ctx = { isIdle: () => false };
switch (process.env.MODE) {
  case "handlers": console.log(Object.keys(handlers).sort().join(" ")); break;
  case "agent-start": await handlers["agent_start"]({ type: "agent_start" }, ctx); break;
  case "end-continuing": await handlers["agent_end"]({ type: "agent_end", willContinue: true }, ctx); break;
  case "end-final": await handlers["agent_end"]({ type: "agent_end" }, ctx); break;
  case "turn-end": await handlers["turn_end"]({ type: "turn_end", turnIndex: 0 }, ctx); break;
  // omp hands every handler the live model on ctx.model (verified on omp 18.8.7
  // by tests/fm-omp-fallback-chain-live-e2e.test.sh).
  case "fallback": await handlers["retry_fallback_applied"]({ type: "retry_fallback_applied", from: "openai-codex/gpt-6.1-sol", to: "deepseek/deepseek-v4-pro" }, { ...ctx, model: { provider: "deepseek", id: "deepseek-v4-pro" } }); break;
  case "end-error": await handlers["agent_end"]({ type: "agent_end", messages: [{ role: "assistant", stopReason: "error", errorMessage: "402 This request would exceed your available credits." }] }, { ...ctx, model: { provider: "deepseek", id: "deepseek-v4-pro" } }); break;
  case "restore": await handlers["agent_start"]({ type: "agent_start" }, { ...ctx, model: { provider: "openai-codex", id: "gpt-6.1-sol" } }); break;
  case "quota-error":
    await handlers["agent_end"]({messages:[{role:"assistant",stopReason:"error",errorMessage:"usage_limit_reached"}]}, ctx); break;
  case "fallback-served":
    await handlers["retry_fallback_succeeded"]({model:"deepseek/deepseek-v4-flash:high"}, ctx); break;
  default: throw new Error("unknown mode " + process.env.MODE);
}
if (process.env.MODE === "turn-end") {
  await new Promise((resolve) => setTimeout(resolve, 200));
}
EOF
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

# --- 6. The tracked primary extensions over a fake omp API ----------------------

install_omp_extension_fixture() {  # <repo>
  local repo=$1
  mkdir -p "$repo/.omp/extensions" "$repo/.pi/extensions/lib" "$repo/bin" "$repo/node_modules/typebox"
  mkdir -p "$repo/.omp/extensions/lib"
  cp "$ROOT/.omp/extensions/lib/fm-task-session.ts" "$ROOT/.omp/extensions/lib/fm-task-worker.ts" "$repo/.omp/extensions/lib/"
  cp "$ROOT/bin/fm-parent-channel-lib.sh" "$ROOT/bin/fm-secondmate-parent-lib.sh" "$ROOT/bin/fm-status-record-lib.sh" "$repo/bin/"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" \
    "$ROOT/.pi/extensions/lib/fm-watch-lifecycle.ts" "$repo/.pi/extensions/lib/"
  cp -R "$ROOT/bin/." "$repo/bin/"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' > "$repo/node_modules/typebox/index.js"
}

# A ship or scout worker whose task copy is a checkout of this repository loads
# the tracked primary extensions (omp auto-discovers <cwd>/.omp/extensions) with
# no FM_HOME, so the copy itself reads as the home. Run both extensions the way
# a session does, from a copy with no FM_HOME: with FM_TASK_ID (the worker
# marker bin/fm-spawn.sh exports) the copy must stay clean, and without it (a
# primary or secondmate home) the four home paths are still written. Both keep
# the watcher-arm seatbelt: a backgrounded arm is denied either way.
run_omp_primary_extensions() {  # <repo> [FM_TASK_ID value]
  local repo=$1 task=${2:-}
  (
    cd "$repo" || exit 1
    unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_TASK_ID
    [ -z "$task" ] || export FM_TASK_ID="$task"
    FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
      REPO="$repo" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const handlers = new Map();
const pi = {
  on(e, h) { const list = handlers.get(e) ?? []; list.push(h); handlers.set(e, list); },
  registerCommand() {}, registerTool() {}, sendMessage() {}, sendUserMessage() {},
};
for (const file of ["fm-primary-omp-watch.ts", "fm-primary-turnend-guard.ts"]) {
  const mod = await import(pathToFileURL(`${process.env.REPO}/.omp/extensions/${file}`).href);
  mod.default(pi);
}
const ctx = { sessionManager: { getSessionId: () => "s1" }, model: { provider: "deepseek", id: "deepseek-v4-pro" }, isIdle: () => true };
for (const name of ["session_start", "before_agent_start", "agent_start", "session_stop", "agent_end"]) {
  for (const handler of handlers.get(name) ?? []) await handler({ type: name }, ctx);
}
const seatbelt = await Promise.all((handlers.get("tool_call") ?? []).map((handler) =>
  handler({ type: "tool_call", toolName: "bash", input: { command: "bin/fm-watch-arm.sh &" } }, {})));
if (!seatbelt.some((result) => result?.block === true)) console.log(`the watcher-arm seatbelt did not deny a backgrounded arm: ${JSON.stringify(seatbelt)}`);
for (const handler of handlers.get("session_shutdown") ?? []) await handler({}, ctx);
process.exit(0);
EOF
  )
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
  # Use production readiness bounds: a slow login shell is not a lost wake.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_WATCH_ARM_RETIRE_TIMEOUT_MS=50 FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    SCENARIO="$scenario" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module >"$home/scenario.out" 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { writeFileSync, mkdirSync, readFileSync, existsSync, unlinkSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
const scenario = process.env.SCENARIO;
// The one-second flush check and the three-second composer poll are fixed in
// production. stuck-* scenarios run the flush check faster, or one check at a
// time for stuck-episodes; stranded-* scenarios run the composer poll faster.
const realSetTimeout = globalThis.setTimeout, realClearTimeout = globalThis.clearTimeout, realSetInterval = globalThis.setInterval;
const manual = scenario === "stuck-episodes";
const flushChecks = new Set();
let pollCheck = null;
globalThis.setTimeout = (callback, delay, ...args) => {
  if (manual && delay === 1000) {
    const timer = { run: () => callback(...args), unref() {} };
    flushChecks.add(timer);
    return timer;
  }
  return realSetTimeout(callback, delay === 1000 && scenario.startsWith("stuck-") ? (scenario === "stuck-restored-failures" ? 60 : 20) : delay, ...args);
};
globalThis.clearTimeout = (timer) => { if (!flushChecks.delete(timer)) realClearTimeout(timer); };
globalThis.setInterval = (callback, delay, ...args) => {
  if ((manual || scenario === "stranded-two") && delay === 3000) { pollCheck = () => callback(...args); return { unref() {} }; }
  return realSetInterval(callback, delay === 3000 && scenario.startsWith("stranded-") ? 100 : delay, ...args);
};
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = []; const notices = []; const refused = []; let tool = null;
let idle = false, queued = false, editor = "", sets = 0, flushes = false, refusals = 0;
const ctx = { hasUI: true, isIdle: () => { if (scenario === "unreadable" && idle) throw new Error("stale context"); return idle; }, hasPendingMessages: () => queued,
  ui: { getEditorText: () => editor, setEditorText: (value) => { editor = value; sets += 1; }, notify: (m, level) => { notices.push({ m, level }); } } };
const pi = { on(name, handler) { handlers.set(name, handler); }, registerCommand() {}, registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    if (refusals > 0 && !o?.deliverAs) {
      refusals -= 1;
      refused.push(m);
      throw new Error("omp refused the prompt");
    }
    sent.push({ m, o });
    if (flushes && !o?.deliverAs) {
      // omp's prompt flow starts a turn and flushes whatever sat in its queue.
      queued = false; idle = false;
      handlers.get("before_agent_start")({ prompt: m }, ctx);
      handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
    }
  } };
const sleep = (ms) => new Promise((resolve) => realSetTimeout(resolve, ms));
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
    } else if (scenario === "stuck-episodes") {
      // omp is idle with the wake in a queue it will not run, and a prompt send
      // starts no turn. Each episode waits thirty flush checks before it acts.
      const check = async () => {
        await until(() => flushChecks.size === 1, "no single flush check was pending");
        const timer = flushChecks.values().next().value;
        flushChecks.delete(timer);
        timer.run();
        await until(() => flushChecks.size === 1, "the flush check did not settle");
      };
      const waits = async (label, checks = 30) => {
        const before = sent.length, warned = notices.length;
        for (let i = 0; i < checks; i += 1) {
          await check();
          if (sent.length !== before || notices.length !== warned) throw new Error(`${label}: recovery acted before thirty checks`);
        }
      };
      const warns = async (label) => {
        const before = sent.length, warned = notices.length;
        await check();
        const notice = notices.at(-1);
        if (sent.length !== before || notices.length !== warned + 1 || notice.level !== "warning" || !notice.m.includes("wake not delivered")) throw new Error(`${label}: exhausted episode did not warn once`);
        await check();
        if (sent.length !== before || notices.length !== warned + 1) throw new Error(`${label}: recovery or warning repeated`);
      };
      editor = "operator draft";
      queued = true;
      await waits("first episode");
      for (let i = 2; i <= 4; i += 1) {
        await check();
        await until(() => wakes().length === i, "stuck queue did not get a fresh prompt send");
        expectWake(i - 1, "check: trigger-1");
        if (notices.length) throw new Error("a resubmission with attempts left was reported");
      }
      await warns("first episode");
      await handlers.get("message_start")({ message: { role: "user", content: "continue work" } }, ctx);
      await waits("accepted user message");
      await warns("accepted user message");
      queued = false;
      await check();
      queued = true;
      await waits("queue drain seen by the flush check");
      await warns("queue drain seen by the flush check");
      queued = false;
      pollCheck();
      queued = true;
      await waits("queue drain seen by the composer poll");
      await warns("queue drain seen by the composer poll");
      idle = false;
      pollCheck();
      idle = true;
      await waits("running turn seen by the composer poll");
      await warns("running turn seen by the composer poll");
      // The turn-end handler runs one check of its own.
      await handlers.get("agent_end")({}, ctx);
      await waits("turn completion", 29);
      await warns("turn completion");
      if (wakes().length !== 4 || sent.length !== 4) throw new Error("an exhausted wake was sent again in a later episode");
      if (editor !== "operator draft" || sets) throw new Error("stuck-queue recovery disturbed the composer");
      // A replacement session replays the mark and starts with a fresh episode.
      await handlers.get("session_shutdown")({}, ctx);
      await handlers.get("session_start")({}, ctx);
      await until(() => wakes().length === 5, "replacement did not read the queue for its mark");
      expectWake(4, "check: trigger-1");
      await waits("replacement session");
      await warns("replacement session");
    } else if (scenario.startsWith("stuck-")) {
      // omp is idle with messages queued that it will not run; a prompt send
      // starts a turn and flushes them.
      const draft = "\noperator\u2063 draft\n\n";
      if (["stuck-failure", "stuck-restored-failure", "stuck-restored-failures", "stuck-restored-failures-turn", "stuck-restored-failure-held", "stuck-restored-failure-no-turn", "stuck-restored-failure-refused"].includes(scenario)) {
        // A failure notice names no queued row, so it is resent as emitted.
        await accept(wake);
        const dir = `${state}/extensions/omp-primary-watch`;
        mkdirSync(dir, { recursive: true });
        const records = scenario.startsWith("stuck-restored-failures") ? ["invalid", "broken"] : ["invalid"];
        for (const record of records) {
          writeFileSync(handoff, record);
          await tool.execute();
          unlinkSync(handoff);
        }
        const failed = () => sent.filter(({ m }) => m.includes("watcher: FAILED"));
        const prompts = () => failed().filter(({ o }) => o?.deliverAs === undefined);
        if (failed().length !== records.length || failed().some(({ o }) => o?.deliverAs !== "followUp") || new Set(failed().map(({ m }) => m)).size !== records.length) throw new Error(`expected distinct queued failure notices: ${JSON.stringify(sent)}`);
        if (scenario === "stuck-restored-failures") {
          // Escape returns both queued notices. omp still reads idle after the
          // prompt send and starts no turn: one turn end sends one notice, and
          // the second copy waits for the bounded in-flight wait, not forever.
          const [first, second] = failed().map(({ m }) => m);
          editor = `${first}\n\n${second}\n\n${draft}`;
          await end();
          if (prompts().length !== 1 || prompts()[0].m !== first || editor !== `${second}\n\n${draft}`) throw new Error(`one turn end sent more than one restored notice: ${JSON.stringify(sent)}`);
          await sleep(300);
          if (prompts().length !== 1 || editor !== `${second}\n\n${draft}`) throw new Error("a flush check sent a second restored notice while the first was in flight");
          await until(() => prompts().length === 2, "the second restored notice was never sent after the bounded wait");
          if (prompts()[1].m !== second || editor !== draft) throw new Error(`the second restored notice was not sent as emitted: ${JSON.stringify(sent)}`);
          await sleep(300);
          if (prompts().length !== 2) throw new Error("a restored notice was sent again after both were out");
        } else if (scenario === "stuck-restored-failures-turn") {
          // Escape returns both queued notices; the first prompt starts a turn.
          const [first, second] = failed().map(({ m }) => m);
          editor = `${first}\n\n${second}\n\n${draft}`;
          flushes = true;
          await end();
          if (prompts().length !== 1 || prompts()[0].m !== first || editor !== `${second}\n\n${draft}`) throw new Error(`one turn end sent more than one restored notice: ${JSON.stringify(sent)}`);
          await sleep(1200);
          if (prompts().length !== 1) throw new Error("a restored notice was sent while the first one's turn ran");
          await end();
          if (prompts().length !== 2 || prompts()[1].m !== second || editor !== draft) throw new Error(`the next turn end did not send the second restored notice: ${JSON.stringify(sent)}`);
        } else if (scenario === "stuck-restored-failure-held") {
          // A held watcher close waits for the turn the restored notice starts.
          await fire("trigger-2");
          editor = `${failed()[0].m}\n\n${draft}`;
          flushes = true;
          await end();
          if (prompts().length !== 1 || prompts()[0].m !== failed()[0].m || editor !== draft || wakes().length !== 1) throw new Error(`the restored notice was not sent alone: ${JSON.stringify(sent)}`);
          await sleep(1200);
          if (prompts().length !== 1 || wakes().length !== 1) throw new Error(`a held watcher wake was sent during the restored notice's turn: ${JSON.stringify(sent)}`);
          await end();
          await until(() => wakes().length === 2, "the held watcher wake was never sent after the restored notice's turn");
          expectWake(1, "check: trigger-1");
          if (prompts().length !== 1) throw new Error("the restored notice was sent again");
        } else if (scenario === "stuck-restored-failure-no-turn") {
          // The restored prompt is accepted but omp starts no turn for it and
          // keeps it queued. A held watcher close still reaches the idle lane,
          // and the bounded retry and the single warning still run.
          await fire("trigger-2");
          editor = `${failed()[0].m}\n\n${draft}`;
          await end();
          queued = true;
          if (prompts().length !== 1 || editor !== draft) throw new Error(`the restored notice was not sent once: ${JSON.stringify(sent)}`);
          await until(() => wakes().length >= 2, "a held watcher wake never reached the idle lane after a restored prompt started no turn");
          expectWake(1, "check: trigger-1");
          await until(() => notices.some(({ m }) => m.includes("wake not delivered")), "the bounded retry never ended in the operator warning", 20);
          const resends = prompts().length;
          if (resends < 3 || resends > 4) throw new Error(`the restored notice was not retried within its bound: ${resends}`);
          const sentCount = sent.length;
          await sleep(600);
          if (sent.length !== sentCount || notices.filter(({ m }) => m.includes("wake not delivered")).length !== 1) throw new Error(`recovery sent again or warned again after the bound: ${JSON.stringify(notices)}`);
        } else if (scenario === "stuck-restored-failure-refused") {
          // omp throws on the restored prompt send: the notice stays in the
          // composer, each refused send counts, and the third ends in one warning.
          const original = `${failed()[0].m}\n\n${draft}`;
          editor = original;
          refusals = 3;
          await end();
          if (refused.length !== 1 || editor !== original) throw new Error(`a refused restored send lost the notice from the composer: ${JSON.stringify(editor)}`);
          await until(() => refused.length === 3 && notices.some(({ m }) => m.includes("wake not delivered")), "refused restored sends did not end in the operator warning");
          await sleep(600);
          await end();
          await sleep(300);
          if (refused.length !== 3 || prompts().length !== 0 || editor !== original || notices.filter(({ m }) => m.includes("wake not delivered")).length !== 1) throw new Error(`refused restored sends were not bounded to three attempts and one warning: ${JSON.stringify({ refused: refused.length, notices })}`);
        } else if (scenario === "stuck-restored-failure") {
          // Escape returns the queued notice to the composer beside a draft.
          editor = `${failed()[0].m}\n\n${draft}`;
          flushes = true;
          await end();
          await until(() => failed().length === 2, "a failure notice restored to the composer was never sent again");
          if (failed()[1].m !== failed()[0].m || failed()[1].o?.deliverAs !== undefined || editor !== draft || notices.length) throw new Error("the restored failure notice was not resent as emitted");
        } else {
          idle = true; queued = true; flushes = true;
          await until(() => failed().length === 2, "a failure notice stuck in omp's idle queue was never sent through the prompt flow");
          if (failed()[1].m !== failed()[0].m || failed()[1].o?.deliverAs !== undefined || queued || notices.length || sets) throw new Error("the stuck failure notice was not resent as emitted");
        }
        if (!["stuck-restored-failure-no-turn", "stuck-restored-failure-refused"].includes(scenario)) {
          await end();
          await sleep(600);
          if (failed().length !== 2 * records.length || wakes().length !== (scenario === "stuck-restored-failure-held" ? 2 : 1)) throw new Error("a delivered failure notice was sent again");
        }
      } else {
        if (scenario === "stuck-restored") editor = `${wake.m}\n\n${draft}`;
        if (["stuck-new-row", "stuck-drained"].includes(scenario)) acknowledge(drain());
        if (scenario === "stuck-new-row") append("B", "check: new queued payload");
        queued = true; flushes = true;
        if (scenario === "stuck-drained") {
          await until(() => queries() > count, "stuck wake was not released for a queue read");
          await sleep(600);
          if (sent.length !== 1 || notices.length || sets) throw new Error("a stuck wake whose rows were drained was injected again or reported");
        } else {
          await until(() => wakes().length === 2, "a wake behind omp's stuck idle queue was never sent through the prompt flow");
          expectWake(1, scenario === "stuck-new-row" ? "check: new queued payload" : "check: trigger-1");
          if (scenario === "stuck-new-row" && wakes()[1].m.includes("check: trigger-1")) throw new Error("stuck-queue recovery replayed an acknowledged headline");
          if (queued || notices.length) throw new Error("the stuck queue was not flushed, or a delivered wake was reported");
          if (scenario === "stuck-restored" ? editor !== draft : sets !== 0) throw new Error("stuck-queue recovery changed operator draft bytes");
          await end();
          await sleep(600);
          if (sent.length !== 2) throw new Error("a delivered wake was sent again");
        }
      }
    } else if (scenario.startsWith("stranded-")) {
      // Wake text other wiring left unsubmitted in an idle composer. It is
      // removed and never submitted as found; the queue read decides what is sent.
      const stale = (message) => wake.m.replace("check: trigger-1", message);
      const bare = (text) => text.startsWith("\u2063") ? text.slice(1) : text;
      const draft = "\noperator\u2063 draft\n\n";
      const settle = async () => { await accept(wake); await end(); };
      const fresh = (index) => {
        expectWake(index, "check: trigger-1");
        if (wakes()[index].m.includes("old headline")) throw new Error("stranded composer text was submitted as found");
      };
      switch (scenario) {
        case "stranded-owed":
        case "stranded-unmarked":
        case "stranded-draft-after":
        case "stranded-draft-before": {
          await settle();
          const typed = stale("check: old headline");
          editor = { "stranded-owed": typed, "stranded-unmarked": bare(typed), "stranded-draft-after": `${typed}\n\n${draft}`, "stranded-draft-before": `${draft}\n\n${bare(typed)}` }[scenario];
          const remainder = scenario.startsWith("stranded-draft-") ? draft : "";
          await until(() => editor === remainder, "wake text left in an idle composer was never removed");
          await until(() => wakes().length === 2, "the still-owed row was not delivered after the stranded text was removed");
          fresh(1);
          if (sets !== 1) throw new Error("the composer was changed more than once");
          break;
        }
        case "stranded-drained": {
          await settle();
          acknowledge(drain());
          editor = stale("check: old headline");
          await until(() => editor === "", "stale wake text was never removed from the idle composer");
          await until(() => queries() > count, "the removed text did not mark a queue read");
          await sleep(600);
          if (sent.length !== 1) throw new Error(`stale composer text with no queued row was injected: ${JSON.stringify(sent)}`);
          break;
        }
        case "stranded-two": {
          await settle();
          // One stable poll removes one block. Do not let a later poll race
          // the assertion while the first asynchronous queue read is in flight.
          writeFileSync(`${state}/query-slow`, "");
          const first = stale("check: old headline one"), second = stale("check: old headline two");
          editor = `${first}\n\n${second}`;
          pollCheck(); pollCheck();
          await until(() => wakes().length === 2, "the first stranded wake was never handled");
          fresh(1);
          if (editor !== second) throw new Error(`the first stranded wake was not removed alone: ${JSON.stringify(editor)}`);
          await accept(wakes()[1]);
          await end();
          pollCheck(); pollCheck();
          await until(() => wakes().length === 3, "the second stranded wake was never handled");
          fresh(2);
          if (editor !== "") throw new Error("the second stranded wake was not removed");
          break;
        }
        case "stranded-human": {
          await settle();
          const refusals = [
            "FIRSTMATE_OP: v1 watcher: typed by a person",
            `Please explain this: ${wake.m}`,
            `${wake.m} and then do this`,
            `${wake.m}\n`,
            wake.m.replace("Watcher continuity", "Watcher edited"),
            wake.m.slice(0, -12),
            "bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.",
            "an unrelated operator draft",
          ];
          for (const text of refusals) {
            editor = text;
            await sleep(600);
            if (sent.length !== 1 || sets || editor !== text) throw new Error(`text that is not a whole wake was submitted or changed: ${JSON.stringify(text)}`);
          }
          break;
        }
        case "stranded-busy": {
          await accept(wake);
          const typed = stale("check: old headline");
          editor = typed;
          await sleep(600);
          if (sent.length !== 1 || sets || editor !== typed) throw new Error("a running turn was disturbed");
          await end();
          await until(() => wakes().length === 2, "the stranded wake was not handled once the turn ended");
          fresh(1);
          if (editor !== "") throw new Error("the stranded wake was not removed after the turn ended");
          break;
        }
        case "stranded-settling": {
          await settle();
          for (let i = 0; i < 8; i += 1) {
            editor = stale(`check: old headline ${i}`);
            await sleep(40);
          }
          if (sent.length !== 1 || sets) throw new Error("wake text still changing was removed");
          await until(() => wakes().length === 2, "settled wake text was never handled");
          fresh(1);
          break;
        }
        case "stranded-bounded": {
          // Text that keeps coming back must not turn removal into a loop.
          await settle();
          acknowledge(drain());
          const typed = stale("check: old headline");
          for (let i = 0; i < 6; i += 1) {
            editor = typed;
            await sleep(500);
          }
          if (sets !== 3 || editor !== typed) throw new Error(`removal was not bounded to three attempts: ${sets}`);
          editor = `${bare(typed)}\n\n${stale("check: old headline later")}`;
          await until(() => editor === bare(typed), "an exhausted stranded wake blocked a later one");
          if (sent.length !== 1) throw new Error("stale composer text with no queued row was injected");
          break;
        }
        case "stranded-tracked": {
          // The emitted wake is still unconsumed and not in the composer, so
          // template matching must wait for its ownership to resolve.
          const older = stale("check: old headline");
          editor = older;
          await sleep(600);
          if (sent.length !== 1 || sets || editor !== older) throw new Error("an unaccounted tracked wake allowed template matching");
          await settle();
          await until(() => wakes().length === 2, "resolved ownership did not release the stranded wake");
          fresh(1);
          if (editor !== "") throw new Error("the stranded wake was not removed");
          break;
        }
        default:
          throw new Error(`unknown stranded scenario ${scenario}`);
      }
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

