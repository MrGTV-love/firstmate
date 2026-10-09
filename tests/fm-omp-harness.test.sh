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
#      state/<id>.omp-ext.ts; a secondmate launch names no -e at all.
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
case "$1" in
  models)
    printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6-astra","selector":"openai-codex/gpt-6-astra"},{"provider":"ollama","id":"qwen3:8b","selector":"ollama/qwen3:8b"}]}'
    ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
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

test_secondmate_launch_relies_on_discovery() {
  # A seeded secondmate home, launched for real through fm-spawn on omp: the
  # launch must carry the posture overlay and pin --cwd to the home, and must
  # name NO -e, because omp auto-discovers the home's tracked .omp/extensions
  # and a file named both ways loads twice.
  local world home fakebin launchlog out status launch
  world="$TMP_ROOT/secondmate"
  home="$world/sm"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config" "$home/bin" "$home/data"
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
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
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
  pass "fm-spawn: a real omp secondmate launch relies on auto-discovery while crewmates load one -e"
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
    FM_ROOT_OVERRIDE='' FM_HOME="$world/home" \
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
  for handler in agent_start agent_end turn_end; do
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
  pass "omp extension: agent_start busy, willContinue stays busy, plain agent_end idle, turn_end a notification"
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
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$repo/.pi/extensions/lib/"
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
for (let i = 0; i < 300 && sent.length === 0; i += 1) await new Promise((r) => setTimeout(r, 100));
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
const expected = process.env.HAND_BACK_KIND === "away-return" ? "signal: already handled original" : "branch-outcome:";
if (!sent[0].m.includes(expected)) throw new Error(`host hand-back lost its outcome: ${sent[0].m}`);
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
if (sent.length !== 3 || sent.some(({ m }) => m.includes("FAILED") || m.includes("uncorrelated") || m.includes("still queued"))) throw new Error(`legacy migration failed: ${JSON.stringify(sent)}`);
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
const second = sent.filter((item) => item.m.includes("signal: omp-host second"));
if (second.length !== 1) throw new Error(`expected one follow-up for the split close, saw ${second.length}: ${JSON.stringify(sent)}`);
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
  } else if (["failure", "timeout", "slow", "slow-turn", "slow-turn-new-row", "query-close"].includes(scenario)) {
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
    await end();
    await until(() => wakes().length === 1, "owed row was not sent");
    expectWake(0, scenario === "utf8" ? "check: 船😀 café Ελληνικά" : "check: trigger-1");
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
process.exit(0);
EOF
  status=$?
  cat "$home/scenario.out"
  return "$status"
}

test_watch_extension_queue_read_delivery() {
  local scenario out status
  for scenario in drained owed mixed same-close handoff late-handoff external host-drained host-owed outstanding-end dropped removed edited failure timeout slow slow-turn slow-turn-new-row query-close unreadable utf8 restore-alone restore-after restore-before restore-edited restore-queued restore-busy restore-new-row restore-drained restore-end-owed restore-end-drained restore-end-new-row restore-end-queued; do
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
  test_watch_extension_delivers_a_split_host_close_whole
  test_watch_extension_migrates_legacy_handoffs
  test_watch_extension_queue_read_delivery
  exit 0
fi

test_detection_anchored_name_and_marker_precedence
test_lock_identity_and_liveness_classification
test_spawn_launch_line_and_worker_wiring
test_spawn_model_validation_scoped_to_listed_providers
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
test_watch_extension_delivers_a_split_host_close_whole
test_watch_extension_migrates_legacy_handoffs
test_watch_extension_queue_read_delivery
test_primary_extensions_ignore_a_descendant_session
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries
