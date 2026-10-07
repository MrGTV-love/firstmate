#!/usr/bin/env bash
# Policy enforcement at the host's preactivation boundary and direct engine API.
# Never starts a model or an active host loop: the CLI must refuse before activation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-engine-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-session-launch-policy)
mkdir -p "$TMP_ROOT/home/state" "$TMP_ROOT/home/config" "$TMP_ROOT/primary"
PREDECESSOR=
cleanup() {
  [ -z "$PREDECESSOR" ] || kill -TERM "$PREDECESSOR" 2>/dev/null || true
  [ -z "$PREDECESSOR" ] || wait "$PREDECESSOR" 2>/dev/null || true
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
export FM_HOME="$TMP_ROOT/home" STATE="$TMP_ROOT/home/state" FM_ROOT="$ROOT"
unset FM_CONFIG_OVERRIDE
printf 'claude sonnet\n' > "$FM_HOME/config/supervision-host"
printf 'omp-or-tc\n' > "$FM_HOME/config/session-launch-policy"
printf 'prompt fixture\n' > "$TMP_ROOT/prompt"
printf 'message fixture\n' > "$TMP_ROOT/message"
cat > "$TMP_ROOT/engine" <<'SH'
#!/usr/bin/env bash
printf 'engine invoked\n' >> "$FM_HOME/engine-effects"
printf '{"type":"result","subtype":"success","is_error":false}\n'
SH
chmod +x "$TMP_ROOT/engine"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$TMP_ROOT/engine"
printf 'previous engine custody\n' > "$TMP_ROOT/engine-pid"
printf 'previous engine result\n' > "$TMP_ROOT/result"
rc=0
fm_supervision_engine_turn claude sonnet "$TMP_ROOT/prompt" "$TMP_ROOT/message" fixture resume 5 "$TMP_ROOT/result" "$TMP_ROOT/errors" "$TMP_ROOT/engine-pid" || rc=$?
[ "$rc" -ne 0 ] || fail 'restricted direct engine API invoked Claude'
assert_contains "$(cat "$TMP_ROOT/errors")" 'session-launch-policy' 'direct engine refusal identifies policy'
[ ! -e "$FM_HOME/engine-effects" ] || fail 'restricted engine executable was invoked'
[ "$(cat "$TMP_ROOT/engine-pid")" = 'previous engine custody' ] || fail 'restricted engine replaced process custody'
[ "$(cat "$TMP_ROOT/result")" = 'previous engine result' ] || fail 'restricted engine replaced prior result'
pass "direct resumed engine refusal exit=$rc invocations=0 process-custody=unchanged result=unchanged"

# The previous host is represented by an owned disposable sleeping process.
# The new host runs under a Bash symlink with omp's structural process identity.
(
  trap 'exit 0' TERM INT
  while :; do /bin/sleep 1; done
) &
PREDECESSOR=$!
identity=$(_fm_engine_identity "$PREDECESSOR")
printf 'host\t%s\t%s\n' "$PREDECESSOR" "$identity" > "$STATE/.supervision-host"
printf 'previous turn custody\n' > "$STATE/.supervision-host-turn"
printf 'previous engine conversation\n' > "$STATE/.supervision-host-engine"
cp "$STATE/.supervision-host" "$TMP_ROOT/prior-host"
ln -s /bin/bash "$TMP_ROOT/primary/omp"
rc=0
# shellcheck disable=SC2016 # The fixture primary shell owns the lock and CLI call.
out=$(FM_SUPERVISION_HOST_PRIMARY=omp "$TMP_ROOT/primary/omp" -c '
  printf "%s\n" "$$" > "$STATE/.lock"
  "$1/bin/fm-supervision-host.sh" park --restart
  rc=$?
  exit "$rc"
' _ "$ROOT" 2>&1) || rc=$?
[ "$rc" -eq 1 ] || fail "restricted host must return an actionable refusal (exit=$rc): $out"
assert_contains "$out" 'session-launch-policy' 'host refuses policy before activating'
kill -0 "$PREDECESSOR" 2>/dev/null || fail 'restricted host stopped predecessor'
cmp -s "$TMP_ROOT/prior-host" "$STATE/.supervision-host" || fail 'restricted host replaced predecessor record'
[ "$(cat "$STATE/.supervision-host-turn")" = 'previous turn custody' ] || fail 'restricted host retired previous turn'
[ "$(cat "$STATE/.supervision-host-engine")" = 'previous engine conversation' ] || fail 'restricted host retired engine custody'
[ ! -e "$FM_HOME/engine-effects" ] || fail 'host invoked engine'
[ ! -e "$STATE/.watch.lock" ] || fail 'restricted host started monitoring'
pass 'omp-primary host refusal invocations=0 predecessor=alive host-record=identical turn-custody=unchanged'

ln -s /bin/bash "$TMP_ROOT/primary/claude"
ln -s /bin/bash "$TMP_ROOT/primary/cursor"
test_shell_stop_policy() {  # <claude|cursor> <denied|invalid|malformed|runtime> <healthy|wake|afk|lost> [published|failed]
  local consumer=$1 policy=$2 close=$3 publication=${4:-published}
  local case_dir repo home script out status expected arms refusals
  case_dir="$TMP_ROOT/stop-$consumer-$policy-$close-$publication"
  repo="$case_dir/repo"
  home="$case_dir/home"
  mkdir -p "$repo/bin" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  cp "$ROOT"/bin/*.sh "$repo/bin/"
  cp "$ROOT"/bin/*.mjs "$repo/bin/"
  printf 'claude sonnet\n' > "$home/config/supervision-host"
  case "$policy" in
    denied) printf 'omp-or-tc\n' > "$home/config/session-launch-policy" ;;
    invalid)
      printf 'omp-or-tc\n' > "$home/config/session-launch-policy"
      printf 'not-an-engine\n' > "$home/config/supervision-host" ;;
    malformed) printf 'omp-or-tc extra\n' > "$home/config/session-launch-policy" ;;
    runtime) : ;;
  esac
  [ "$publication" != failed ] || mkdir "$home/state/.watcher-down"
  printf 'owned task must survive\n' > "$home/state/task.meta"
  cp "$STATE/.supervision-host" "$home/state/.supervision-host"
  cp "$STATE/.supervision-host-turn" "$home/state/.supervision-host-turn"
  cp "$STATE/.supervision-host-engine" "$home/state/.supervision-host-engine"
  mv "$repo/bin/fm-supervision-host.sh" "$repo/bin/fm-supervision-host-real.sh"
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host\n' >> "$FM_HOME/host-launches"
if [ -f "$FM_HOME/repaired" ]; then
  printf 'supervision-host stood down: owned permitted fixture boundary\n'
  exit 0
fi
printf 'omp-or-tc\n' > "$FM_HOME/config/session-launch-policy"
"$(dirname "$0")/fm-supervision-host-real.sh" "$@"
status=$?
case "$FIXTURE_CLOSE" in
  afk) : > "$FM_HOME/state/.afk" ;;
  lost) printf '1\n' > "$FM_HOME/state/.lock" ;;
esac
exit "$status"
SH
  cat > "$repo/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
for ((i=0; i<40; i++)); do sleep 1; done
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$(dirname "$0")/fm-wake-lib.sh"
printf '%s\n' "${FM_WATCH_PREDECESSOR_ARM_PID-unset}" >> "$FM_HOME/ordinary-launches"
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$FIXTURE_WATCH_PID" > "$STATE/.watch.lock/pid"
fm_pid_identity "$FIXTURE_WATCH_PID" > "$STATE/.watch.lock/pid-identity"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$(dirname "$0")/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
: > "$STATE/.last-watcher-beat"
printf 'watcher: started pid=%s\n' "$FIXTURE_WATCH_PID"
if [ "${FM_WATCH_PREDECESSOR_ARM_PID-unset}" = unset ] && [ "$FIXTURE_CLOSE" = wake ]; then
  fm_wake_append signal fixture-ordinary 'signal: owned ordinary wake'
  fm_recovery_marker_publish "$STATE/.watcher-down" downtime
  printf 'signal: owned ordinary wake\n'
fi
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-watch.sh" "$repo/bin/fm-supervision-host.sh"
  case "$consumer" in
    claude) script=fm-claude-stop-autoarm.sh ;;
    cursor) script=fm-turnend-guard-cursor.sh ;;
  esac
  status=0
  # shellcheck disable=SC2016 # Both Stop firings share the fixture primary's pid.
  out=$(FM_ROOT_OVERRIDE="$repo" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_WAKE_QUEUE="$home/state/.wake-queue" \
    FM_WAKE_QUEUE_LOCK="$home/state/.wake-queue.lock" FM_ROOT="$repo" \
    FIXTURE_CLOSE="$close" FIXTURE_POLICY="$policy" FIXTURE_SCRIPT="$script" \
    FM_CLAUDE_AUTOARM_ATTEMPTS=1 FM_CURSOR_PARK_ATTEMPTS=1 FM_CURSOR_PARK_POLL=1 \
    FM_ARM_CONFIRM_TIMEOUT=1 "$TMP_ROOT/primary/$consumer" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_ROOT/bin/fm-watch.sh" &
      export FIXTURE_WATCH_PID=$!
      trap '\''kill -TERM "$FIXTURE_WATCH_PID" 2>/dev/null || true; wait "$FIXTURE_WATCH_PID" 2>/dev/null || true'\'' EXIT
      firings=1
      [ "$FIXTURE_POLICY" = runtime ] || firings=2
      for ((i=1; i<=firings; i++)); do
        rc=0
        printf '\''{"session_id":"owned-policy-session","stop_hook_active":false,"loop_count":0}'\'' \
          | "$FM_ROOT/bin/$FIXTURE_SCRIPT" > "$FM_HOME/stdout-$i" 2> "$FM_HOME/stderr-$i" || rc=$?
        printf "%s\n" "$rc" >> "$FM_HOME/statuses"
      done
      if [ "$FIXTURE_POLICY" != runtime ] && [ "$FIXTURE_CLOSE" = healthy ]; then
        [ ! -e "$FM_HOME/host-launches" ] || exit 91
        rm "$FM_HOME/config/session-launch-policy"
        printf "claude sonnet\n" > "$FM_HOME/config/supervision-host"
        : > "$FM_HOME/repaired"
        rc=0
        printf '\''{"session_id":"owned-policy-session","stop_hook_active":false,"loop_count":0}'\'' \
          | "$FM_ROOT/bin/$FIXTURE_SCRIPT" > "$FM_HOME/stdout-repaired" 2> "$FM_HOME/stderr-repaired" || rc=$?
        printf "%s\n" "$rc" > "$FM_HOME/status-repaired"
      fi
    ' 2>&1) || status=$?
  expect_code 0 "$status" "$consumer fixture primary: $out"
  kill -0 "$PREDECESSOR" 2>/dev/null || fail "$consumer killed predecessor"
  cmp -s "$TMP_ROOT/prior-host" "$home/state/.supervision-host" || fail "$consumer changed host custody"
  cmp -s "$STATE/.supervision-host-turn" "$home/state/.supervision-host-turn" || fail "$consumer changed turn custody"
  cmp -s "$STATE/.supervision-host-engine" "$home/state/.supervision-host-engine" || fail "$consumer changed engine custody"
  [ "$(cat "$home/state/task.meta")" = 'owned task must survive' ] || fail "$consumer discarded task"
  [ ! -e "$home/engine-effects" ] || fail "$consumer launched an engine"
  arms=0
  [ ! -f "$home/ordinary-launches" ] || arms=$(wc -l < "$home/ordinary-launches" | tr -d ' ')
  refusals=0
  if [ -f "$home/state/.wake-queue" ]; then
    refusals=$(grep -c 'session-launch-refused-supervision-host-' "$home/state/.wake-queue" || true)
  fi
  if [ "$policy" != runtime ]; then
    if [ "$close" = healthy ]; then
      [ "$(cat "$home/host-launches")" = host ] || fail "$consumer repaired policy did not reselect host exactly once"
      [ "$(cat "$home/status-repaired")" = 0 ] || fail "$consumer permitted fixture boundary exit"
      [ ! -s "$home/stdout-repaired" ] && [ ! -s "$home/stderr-repaired" ] || fail "$consumer repaired policy repeated refusal"
    else
      [ ! -e "$home/host-launches" ] || fail "$consumer preflight launched host"
    fi
    [ "$refusals" -eq 1 ] || fail "$consumer unchanged same-session policy queued $refusals refusals"
    expected=2
    [ "$close" != wake ] || [ "$consumer" != claude ] || expected=3
    [ "$arms" -eq "$expected" ] || fail "$consumer ordinary launches=$arms expected=$expected"
    if [ "$close" = healthy ]; then
      if [ "$consumer" = claude ]; then
        [ "$(cat "$home/statuses")" = "$(printf '2\n0')" ] || fail 'Claude initial refusal or later healthy Stop status'
        assert_contains "$(cat "$home/stderr-1")" 'supervision-host: launch policy refused:' 'Claude first denial delivered'
        assert_not_contains "$(cat "$home/stderr-1")" 'did not confirm a live watcher' 'Claude preflight successor confirmed'
        [ ! -s "$home/stderr-2" ] || fail 'Claude unchanged denial repeated on later Stop'
      else
        [ "$(cat "$home/statuses")" = "$(printf '0\n0')" ] || fail 'Cursor healthy Stop exit'
        assert_contains "$(cat "$home/stdout-1")" 'supervision-host: launch policy refused:' 'Cursor first healthy Stop delivers new refusal'
        [ ! -s "$home/stdout-2" ] && [ ! -s "$home/stderr-1" ] || fail 'Cursor healthy Stop repeats refusal or emits failure'
      fi
    fi
  else
    [ "$(cat "$home/host-launches")" = host ] || fail "$consumer runtime host launch count"
    if [ "$close" = afk ] || [ "$close" = lost ]; then
      [ "$arms" -eq 0 ] || fail "$consumer restored ordinary after losing ownership"
      [ "$(cat "$home/statuses")" = 0 ] || fail "$consumer losing hook delivered refusal"
      [ ! -s "$home/stdout-1" ] || fail "$consumer losing hook emitted followup"
    elif [ "$consumer" = claude ]; then
      [ "$arms" -eq 1 ] || fail 'Claude runtime refusal lacked ordinary successor'
      [ "$(cat "$home/ordinary-launches")" = '' ] || fail 'Claude runtime successor supplied unrelated predecessor'
      [ "$(cat "$home/statuses")" = 2 ] || fail 'Claude runtime refusal lost exit 2'
      [ ! -s "$home/stdout-1" ] || fail 'Claude refusal was not stderr-only'
      assert_contains "$(cat "$home/stderr-1")" 'supervision-host: launch policy refused:' 'Claude runtime refusal delivered'
      assert_not_contains "$(cat "$home/stderr-1")" 'did not confirm a live watcher' 'Claude ordinary successor confirmed'
      if [ "$publication" = published ]; then
        assert_contains "$(cat "$home/state/.claude-autoarm-epoch")" 'outcome=rewake' 'Claude published refusal retains recovery commit'
      else
        assert_contains "$(cat "$home/state/.claude-autoarm-epoch")" 'outcome=policy-refused' 'Claude failed publication uses marker-independent refusal commit'
      fi
    else
      [ "$arms" -eq 1 ] || fail 'Cursor runtime refusal consumed its ordinary attempt'
      [ "$(cat "$home/statuses")" = 0 ] || fail 'Cursor runtime restoration exit'
      if [ "$close" = wake ]; then
        assert_contains "$(cat "$home/stdout-1")" 'owned ordinary wake' 'Cursor restored ordinary wake delivery'
        assert_contains "$(cat "$home/stdout-1")" 'supervision-host: launch policy refused:' 'Cursor runtime refusal accompanies ordinary wake'
      else
        assert_contains "$(cat "$home/stdout-1")" 'supervision-host: launch policy refused:' 'Cursor healthy restoration delivers retained refusal'
        assert_not_contains "$(cat "$home/stdout-1")" 'TURN WOULD END BLIND' 'Cursor healthy restoration emits no repair nag'
      fi
    fi
    if [ "$publication" = failed ]; then
      [ -d "$home/state/.watcher-down" ] || fail 'failed publication replaced directory'
    else
      [ -f "$home/state/.watcher-down" ] || fail 'runtime refusal did not publish hand-back'
    fi
  fi
  if [ "$close" = wake ] && [ "$policy" != runtime ]; then
    if [ "$consumer" = claude ]; then
      [ "$(cat "$home/statuses")" = "$(printf '2\n2')" ] || fail 'Claude ordinary wakes not delivered'
      assert_contains "$(cat "$home/stderr-2")" 'owned ordinary wake' 'Claude second ordinary wake'
      assert_contains "$(cat "$home/stderr-1")" 'supervision-host: launch policy refused:' 'Claude initial refusal delivered once'
      assert_not_contains "$(cat "$home/stderr-2")" 'supervision-host: launch policy refused:' 'Claude unchanged refusal not redelivered'
    else
      assert_contains "$(cat "$home/stdout-2")" 'owned ordinary wake' 'Cursor second ordinary wake'
      assert_contains "$(cat "$home/stdout-1")" 'supervision-host: launch policy refused:' 'Cursor initial refusal accompanies ordinary wake'
      assert_not_contains "$(cat "$home/stdout-2")" 'supervision-host: launch policy refused:' 'Cursor unchanged refusal not redelivered'
    fi
  fi
  pass "$consumer Stop policy=$policy close=$close publication=$publication ordinary=$arms refusal-checks=$refusals predecessor-custody=unchanged task=preserved"
}
for stop_consumer in claude cursor; do
  for stop_policy in denied invalid malformed; do
    test_shell_stop_policy "$stop_consumer" "$stop_policy" healthy
  done
  test_shell_stop_policy "$stop_consumer" denied wake
  for stop_publication in published failed; do
    test_shell_stop_policy "$stop_consumer" runtime healthy "$stop_publication"
  done
  test_shell_stop_policy "$stop_consumer" runtime afk
  test_shell_stop_policy "$stop_consumer" runtime lost
done
test_shell_stop_policy cursor runtime wake

fm_supervision_host_config "$FM_HOME/config" omp || fail 'configured host unexpectedly disabled'
[ -z "$FM_SUPERVISION_ENGINE" ] || fail 'restricted engine remained available to attended routing'
assert_contains "$FM_SUPERVISION_ENGINE_PROBLEM" 'session-launch-policy' 'configured engine reports policy refusal'
pass 'configured supervision engine remains unavailable under launch restriction'

rm "$FM_HOME/config/session-launch-policy"
fm_supervision_host_config "$FM_HOME/config" omp || fail 'absent policy changed host opt-in'
[ "$FM_SUPERVISION_ENGINE" = claude ] || fail 'absent policy changed explicit engine selection'
rm "$TMP_ROOT/engine-pid"
fm_supervision_engine_turn claude sonnet "$TMP_ROOT/prompt" "$TMP_ROOT/message" fixture new 5 "$TMP_ROOT/result" "$TMP_ROOT/errors" "$TMP_ROOT/engine-pid" || fail 'absent policy changed engine invocation'
[ "$(cat "$FM_HOME/engine-effects")" = 'engine invoked' ] || fail 'absent policy never invoked engine fixture'
pass 'absent policy preserves configured Claude engine and direct turn (fixture executable only)'

test_away_launch_policy_guidance() {
  local harness policy selection command home out status
  for harness in claude cursor opencode omp grok codex; do
    for policy in enabled malformed; do
      for selection in default claude; do
        home="$TMP_ROOT/away-$harness-$policy-$selection"
        mkdir -p "$home/config" "$home/state" "$home/bin"
        if [ "$selection" = default ]; then
          : > "$home/config/supervision-host"
        else
          printf 'claude sonnet\n' > "$home/config/supervision-host"
        fi
        if [ "$policy" = enabled ]; then
          printf 'omp-or-tc\n' > "$home/config/session-launch-policy"
        else
          printf 'omp-or-tc extra\n' > "$home/config/session-launch-policy"
        fi
        cat > "$home/bin/tmux" <<'SH'
#!/usr/bin/env bash
printf "terminal invoked\n" >> "$FM_HOME/terminal-effects"
exit 1
SH
        chmod +x "$home/bin/tmux"
        status=0
        out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_TEST_HARNESS="$harness" FM_AFK_MODE=away \
          "$ROOT/bin/fm-afk-launch.sh" enter --words 'watch the fleet' 2>&1) || status=$?
        expect_code 0 "$status" "$harness $policy $selection public away entry: $out"
        assert_contains "$out" 'Supervision host: no engine runs the away session on this home (' "$harness missing-engine reason reaches main"
        assert_contains "$out" 'so every away wake reaches this conversation' "$harness preserves main wake ownership"
        assert_contains "$out" 'continue main-side supervision until a permitted native engine is verified' "$harness $policy keeps actionable main-side guidance"
        assert_not_contains "$out" 'name a verified engine in config/supervision-host' "$harness $policy recommends no denied engine"
        assert_not_contains "$out" 'for example "claude"' "$harness $policy does not recommend Claude"
        if [ "$selection" = default ] && [ "$harness" != claude ]; then
          assert_contains "$out" "the primary harness '$harness' has no verified supervision engine" "$harness retains missing default-engine reason"
        else
          assert_contains "$out" 'session-launch-policy' "$harness retains policy refusal reason"
        fi
        [ -f "$home/state/.afk-contract" ] || fail "$harness $policy entry lost away posture"
        cp "$home/state/.afk-contract" "$home/prior-posture"
        printf 'prior escalation\n' > "$home/state/.subsuper-escalations"
        for command in start start-native; do
          status=0
          out=$(PATH="$home/bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
            FM_TEST_HARNESS="$harness" FM_AFK_MODE=away FM_SUPERVISOR_TARGET=fixture:captain \
            FM_SUPERVISOR_BACKEND=tmux "$ROOT/bin/fm-afk-launch.sh" "$command" 2>&1) || status=$?
          expect_code 1 "$status" "$harness $policy $command must refuse the daemon: $out"
          assert_not_contains "$out" 'runs the supervision host' "$harness refusal must not claim host activation"
          cmp -s "$home/prior-posture" "$home/state/.afk-contract" || fail "$harness $policy $command changed away posture"
          [ "$(cat "$home/state/.subsuper-escalations")" = 'prior escalation' ] || fail "$harness $policy $command cleared prior state"
          [ ! -e "$home/state/.afk" ] || fail "$harness $policy $command allocated daemon flag"
          [ ! -e "$home/state/.afk-daemon-terminal" ] || fail "$harness $policy $command allocated daemon terminal"
          [ ! -e "$home/state/.supervise-daemon.lock" ] || fail "$harness $policy $command allocated daemon custody"
          [ ! -e "$home/terminal-effects" ] || fail "$harness $policy $command invoked terminal backend"
          [ ! -e "$home/engine-effects" ] || fail "$harness $policy $command invoked engine"
        done
      done
    done
    home="$TMP_ROOT/away-$harness-absent-policy"
    mkdir -p "$home/config" "$home/state"
    printf 'omp\n' > "$home/config/supervision-host"
    status=0
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_TEST_HARNESS="$harness" FM_AFK_MODE=away \
      "$ROOT/bin/fm-afk-launch.sh" enter --words 'watch the fleet' 2>&1) || status=$?
    expect_code 0 "$status" "$harness absent-policy missing-engine entry: $out"
    assert_contains "$out" "config/supervision-host names 'omp', which is not a verified supervision engine" "$harness retains explicit missing-engine reason"
    assert_contains "$out" 'for example "claude"' "$harness absent policy recommends admissible Claude"
    assert_not_contains "$out" 'continue main-side supervision until' "$harness absent policy offers an admissible engine"
    printf 'claude sonnet\n' > "$home/config/supervision-host"
    status=0
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_TEST_HARNESS="$harness" FM_AFK_MODE=away \
      "$ROOT/bin/fm-afk-launch.sh" enter --words 'watch the fleet' 2>&1) || status=$?
    expect_code 0 "$status" "$harness accepted-engine entry: $out"
    assert_not_contains "$out" 'Supervision host:' "$harness accepted engine emits no missing-engine guidance"
    [ -f "$home/state/.afk-contract" ] || fail "$harness accepted-engine entry lost away posture"
    [ ! -e "$home/engine-effects" ] || fail "$harness accepted-engine entry activated engine"
  done
  pass 'public away entry: all host primaries preserve policy-admissible guidance and refuse denied daemon starts without losing posture'
}

test_away_launch_policy_guidance

test_primary_consumer_policy_refusal() {  # <omp|opencode> <published|failed> <initial|successor>
  local consumer=$1 publication=$2 phase=$3 replay_policy=${4:-denied} selection=${5:-claude} case_dir repo home out status
  case_dir="$TMP_ROOT/$consumer-$publication-$phase-$replay_policy-$selection"
  repo="$case_dir/repo"
  home="$case_dir/home"
  mkdir -p "$repo/bin" "$repo/.omp/extensions" "$repo/.pi/extensions/lib" \
    "$repo/.opencode/plugins/lib" "$repo/node_modules/typebox" "$home/state" "$home/config"
  git init -q "$repo"
  : > "$repo/AGENTS.md"
  case "$selection" in
    claude) printf 'claude sonnet\n' ;;
    empty) printf '\n' ;;
    default) printf 'default\n' ;;
    unverified) printf 'omp\n' ;;
    extra) printf 'claude sonnet extra\n' ;;
  esac > "$home/config/supervision-host"
  printf 'omp-or-tc\n' > "$home/config/session-launch-policy"
  cp "$TMP_ROOT/prior-host" "$home/state/.supervision-host"
  printf 'previous turn custody\n' > "$home/state/.supervision-host-turn"
  printf 'previous engine conversation\n' > "$home/state/.supervision-host-engine"
  printf 'live task\n' > "$home/state/task.meta"
  printf 'live lease\n' > "$home/state/task.lease"
  printf 'durable wake\n' > "$home/state/wakes.jsonl"
  if [ "$publication" = failed ]; then
    mkdir "$home/state/.watcher-down"
  fi
  cp "$ROOT/.omp/extensions/fm-primary-omp-watch.ts" "$repo/.omp/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/"
  cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$repo/.opencode/plugins/"
  cp "$ROOT/.opencode/plugins/fm-primary-turnend-guard.js" "$repo/.opencode/plugins/"
  cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$repo/.opencode/plugins/lib/"
  cp "$ROOT/.opencode/plugins/package.json" "$repo/.opencode/plugins/"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$ROOT/bin/fm-session-launch-policy-lib.sh" \
    "$ROOT/bin/fm-config-inherit-lib.sh" "$ROOT/bin/fm-startup-memory-budget-lib.sh" "$repo/bin/"
  printf '{"name":"typebox","type":"module","exports":"./index.js"}\n' > "$repo/node_modules/typebox/package.json"
  printf 'export const Type = { Object(p) { return { type: "object", properties: p }; } };\n' \
    > "$repo/node_modules/typebox/index.js"
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$FM_HOME/state/launches"
if [ ! -e "$FM_HOME/config/session-launch-policy" ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-%s\n' "$$" "$$"
  trap 'exit 0' TERM INT
  while :; do sleep 0.02; done
fi
if [ "$FM_POLICY_PHASE" = successor ] && [ ! -e "$FM_HOME/state/first-host" ]; then
  : > "$FM_HOME/state/first-host"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  trap 'exit 0' TERM INT
  while [ ! -e "$FM_HOME/state/release-host" ]; do sleep 0.02; done
  printf 'signal: prior host close\n'
  exit 0
fi
if [ "$FM_POLICY_CONSUMER" = opencode ] && [ "$FM_POLICY_PHASE" = initial ]; then
  "$FM_POLICY_ROOT/bin/fm-supervision-host.sh" "$@" > "$FM_HOME/state/refusal-output" 2>&1
  status=$?
  cat "$FM_HOME/state/refusal-output"
  while [ ! -e "$FM_HOME/state/release-refusal" ]; do sleep 0.02; done
  exit "$status"
fi
exec "$FM_POLICY_ROOT/bin/fm-supervision-host.sh" "$@"
SH
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  kill -0 "$4" 2>/dev/null || exit 1
  printf 'confirmed=%s watcher=%s\n' "$2" "$4" >> "$FM_HOME/state/launches"
  exit 0
fi
printf 'plain=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$FM_HOME/state/launches"
if [ "$FM_POLICY_CONSUMER" = opencode ] && [ "$FM_POLICY_PHASE" = initial ] && [ ! -e "$FM_HOME/state/first-plain" ]; then
  : > "$FM_HOME/state/restoring-plain"
  while [ ! -e "$FM_HOME/state/release-restoration" ]; do sleep 0.02; done
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=fixture-%s\n' "$$" "$$"
trap 'exit 0' TERM INT
if [ ! -e "$FM_HOME/state/first-plain" ]; then
  : > "$FM_HOME/state/first-plain"
  while [ ! -e "$FM_HOME/state/release-plain" ]; do sleep 0.02; done
  printf 'signal: ordinary monitoring continues\n'
  exit 0
fi
while :; do sleep 0.02; done
SH
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
printf 'generic guard invoked\n' >> "$FM_HOME/state/generic-guard"
printf 'fixture supervision is blind\n' >&2
exit 2
SH
  chmod +x "$repo/bin/"*.sh
  ln -s "$(command -v bun)" "$case_dir/$consumer"
  cat > "$case_dir/consumer.mjs" <<'JS'
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const state = `${process.env.FM_HOME}/state`;
const root = process.env.FM_ROOT_OVERRIDE;
const consumer = process.env.FM_POLICY_CONSUMER;
const phase = process.env.FM_POLICY_PHASE;
const expectedHosts = phase === "successor" ? 2 : 1;
const replayAllowed = process.env.FM_POLICY_REPLAY_POLICY === "removed";
const replaying = process.env.FM_POLICY_REPLAY_STAGE === "replacement";
const records = [".supervision-host", ".supervision-host-turn", ".supervision-host-engine", "task.meta", "task.lease", "wakes.jsonl"];
const before = records.map((name) => readFileSync(`${state}/${name}`, "utf8"));
const rows = () => existsSync(`${state}/launches`) ? readFileSync(`${state}/launches`, "utf8").trim().split("\n") : [];
const hosts = () => rows().filter((row) => row.startsWith("host="));
const plains = () => rows().filter((row) => row.startsWith("plain="));
const sent = [];
const handlers = new Map();
let tool;
let hooks;
let turnend;
const api = {
  on(name, handler) { handlers.set(name, handler); },
  registerCommand() {},
  registerTool(value) { tool = value; },
  sendUserMessage(message) { record(message); },
};
function record(message) {
  if (message.includes("TURN WOULD END BLIND")) throw new Error(`competing blind prompt: ${message}`);
  const selected = existsSync(`${process.env.FM_HOME}/config/session-launch-policy`) ? plains().at(-1) : hosts().at(-1);
  const pid = selected?.match(/^(?:host|plain)=([0-9]+)/)?.[1];
  if (!pid || !rows().some((row) => row.startsWith("confirmed=") && row.endsWith(`watcher=${pid}`))) {
    throw new Error(`wake was delivered before selected monitoring and handling handoff: ${rows().join(" | ")}`);
  }
  sent.push(message);
}
const client = { session: { promptAsync: async (request) => record(request.body.parts[0].text) } };
async function until(predicate, label) {
  for (let attempt = 0; attempt < 600; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`${label}: ${JSON.stringify({ sent, launches: rows() })}`);
}
const refusal = (message) => message.includes("supervision-host: launch policy refused:");
const ordinary = (message) => message.includes("signal: ordinary monitoring continues");
async function arm() {
  if (consumer === "omp") return tool.execute();
  return globalThis.__firstmateOpenCodeWatchArm.ensureArmed("fixture-policy", client);
}
async function consume() {
  if (consumer !== "omp") return;
  for (const message of sent) await handlers.get("before_agent_start")({ prompt: message }, {});
}
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
try {
  const modulePath = consumer === "omp"
    ? `${root}/.omp/extensions/fm-primary-omp-watch.ts`
    : `${root}/.opencode/plugins/fm-primary-watch-arm.js`;
  const mod = await import(pathToFileURL(modulePath).href);
  if (consumer === "omp") mod.default(api);
  else {
    hooks = await mod.FmPrimaryWatchArm({ client, directory: root, worktree: root });
    const guard = await import(pathToFileURL(`${root}/.opencode/plugins/fm-primary-turnend-guard.js`).href);
    turnend = await guard.FmPrimaryTurnendGuard({ client, directory: root, worktree: root });
  }
  if (replaying) {
    await handlers.get("session_start")({}, {});
    await until(() => sent.filter(refusal).length === 1 &&
      (replayAllowed ? hosts().length === expectedHosts + 1 : plains().length === 3),
      "replacement did not replay its pending refusal with currently permitted monitoring");
    if (hosts().length !== expectedHosts + (replayAllowed ? 1 : 0) || plains().length !== (replayAllowed ? 2 : 3)) {
      throw new Error(`replacement replay selected the wrong host or watcher: ${rows().join(" | ")}`);
    }
    await consume();
    await handlers.get("session_shutdown")({}, {});
    await handlers.get("session_start")({}, {});
    await until(() => replayAllowed ? hosts().length === expectedHosts + 2 : plains().length === 4,
      "owning replacement did not retain currently permitted monitoring");
    await arm();
    if (hosts().length !== expectedHosts + (replayAllowed ? 2 : 0) || sent.filter(refusal).length !== 1) {
      throw new Error(`consumed replacement selected wrong monitoring or redelivered refusal: ${JSON.stringify({ sent, launches: rows() })}`);
    }
    if (existsSync(`${state}/extensions/omp-primary-watch/session-replacement-actionable.json`)) throw new Error("consumed refusal remained in replacement handoff");
  } else {
  if (turnend && phase === "initial") {
    const idle = { event: { type: "session.idle", properties: { sessionID: "fixture-policy" } } };
    await turnend.event(idle);
    if (!readFileSync(`${state}/refusal-output`, "utf8").includes("supervision-host: launch policy refused:")) throw new Error("idle did not reach initial policy refusal");
    if (existsSync(`${state}/generic-guard`) || sent.length) throw new Error("initial refusal idle invoked generic guard or delivered a competing prompt");
    writeFileSync(`${state}/release-refusal`, "release\n");
    await until(() => existsSync(`${state}/restoring-plain`), "refusal did not start ordinary restoration");
    const restorationIdle = turnend.event(idle);
    if (existsSync(`${state}/generic-guard`) || sent.length) throw new Error("restoration invoked generic guard or delivered refusal before readiness");
    writeFileSync(`${state}/release-restoration`, "release\n");
    await restorationIdle;
    if (existsSync(`${state}/generic-guard`)) throw new Error("restoration idle invoked generic guard");
  } else {
    await arm();
  }
  if (phase === "successor") {
    await until(() => hosts().length === 1, "first host did not start");
    writeFileSync(`${state}/release-host`, "release\n");
  }
  await until(() => sent.some(refusal), "refusal was not delivered");
  if (sent.filter(refusal).length !== 1) throw new Error(`refusal was delivered more than once: ${JSON.stringify(sent)}`);
  if (hosts().length !== expectedHosts || plains().length !== 1) throw new Error(`denied host was retried or monitoring was not restored: ${rows().join(" | ")}`);
  const refusalMessage = sent.find(refusal);
  const detail = process.env.FM_POLICY_PUBLICATION === "failed" ? "could not record the hand-back" : "predecessor custody is unchanged";
  if (!refusalMessage.includes(detail) || (process.env.FM_POLICY_SELECTION === "claude" && !refusalMessage.includes("session-launch-policy"))) throw new Error(`refusal lost selection or publication detail: ${refusalMessage}`);
  if (refusalMessage.includes("could not restore watcher continuity") || refusalMessage.includes("ready successor")) throw new Error(`ordinary fallback was reported as failed: ${refusalMessage}`);
  if (phase === "successor" && !sent.some((message) => message.includes("signal: prior host close"))) throw new Error(`original close was lost: ${JSON.stringify(sent)}`);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await arm();
    if (hooks) await hooks.event({ event: { type: "session.idle", properties: { sessionID: "fixture-policy" } } });
    if (turnend) await turnend.event({ event: { type: "session.idle", properties: { sessionID: "fixture-policy" } } });
  }
  await new Promise((resolve) => setTimeout(resolve, 150));
  if (hosts().length !== expectedHosts || sent.filter(refusal).length !== 1) throw new Error(`idle or repair retried the denial: ${JSON.stringify({ sent, launches: rows() })}`);
  writeFileSync(`${state}/release-plain`, "release\n");
  await until(() => sent.some(ordinary) && plains().length === 2, "ordinary close did not continue monitoring");
  if (sent.filter(ordinary).length !== 1 || sent.filter(refusal).length !== 1 || hosts().length !== expectedHosts) throw new Error(`ordinary close repeated denial or delivery: ${JSON.stringify({ sent, launches: rows() })}`);
  if (turnend && existsSync(`${state}/generic-guard`)) throw new Error("coordinator-owned refusal or monitoring invoked generic guard");
  if (consumer === "omp") {
    await handlers.get("session_shutdown")({}, {});
    if (replayAllowed) unlinkSync(`${process.env.FM_HOME}/config/session-launch-policy`);
    const replacement = spawnSync(process.env.FM_POLICY_PRIMARY_BIN, [process.argv[1]], {
      env: { ...process.env, FM_POLICY_REPLAY_STAGE: "replacement" },
      encoding: "utf8",
      timeout: 15000,
    });
    if (replacement.status !== 0 || replacement.stdout || replacement.stderr) {
      throw new Error(`fresh owning replacement failed: ${replacement.stdout}${replacement.stderr}`);
    }
  }
  }
  records.forEach((name, index) => {
    if (readFileSync(`${state}/${name}`, "utf8") !== before[index]) throw new Error(`${name} custody changed`);
  });
  if (existsSync(`${process.env.FM_HOME}/engine-effects`)) throw new Error("a denied engine was invoked");
  const predecessor = before[0].split("\t")[1];
  process.kill(Number(predecessor), 0);
} finally {
  if (consumer === "omp" && handlers.has("session_shutdown")) await handlers.get("session_shutdown")({}, {});
  try { unlinkSync(`${state}/.lock`); } catch {}
  for (const row of rows()) {
    const pid = row.match(/^(?:host|plain)=([0-9]+)/)?.[1];
    if (pid) { try { process.kill(Number(pid), "SIGTERM"); } catch {} }
  }
  await new Promise((resolve) => setTimeout(resolve, 80));
}
process.exit(0);
JS
  status=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    FM_POLICY_ROOT="$ROOT" FM_POLICY_CONSUMER="$consumer" FM_POLICY_PUBLICATION="$publication" FM_POLICY_PHASE="$phase" \
    FM_POLICY_REPLAY_POLICY="$replay_policy" FM_POLICY_SELECTION="$selection" FM_POLICY_PRIMARY_BIN="$case_dir/$consumer" \
    FM_OMP_ARM_READY_TIMEOUT_MS=1000 FM_OPENCODE_ARM_READY_TIMEOUT_MS=1000 \
    FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=1 \
    "$case_dir/$consumer" "$case_dir/consumer.mjs" 2>&1) || status=$?
  expect_code 0 "$status" "$consumer $publication $phase $replay_policy $selection policy refusal public consumer: $out"
  [ -z "$out" ] || fail "$consumer policy consumer printed output: $out"
  pass "$consumer $publication $phase $replay_policy $selection: refusal delivered once per owner, current-policy monitoring, unchanged custody"
}

if command -v bun >/dev/null 2>&1; then
  for consumer in omp opencode; do
    for publication in published failed; do
      for phase in initial successor; do
        test_primary_consumer_policy_refusal "$consumer" "$publication" "$phase"
        if [ "$consumer" = omp ]; then
          test_primary_consumer_policy_refusal "$consumer" "$publication" "$phase" removed
        fi
      done
    done
  done
  for selection in empty default unverified extra; do
    for replay_policy in denied removed; do
      test_primary_consumer_policy_refusal omp published initial "$replay_policy" "$selection"
    done
  done
else
  printf 'skip: bun absent (omp/OpenCode public consumer policy checks)\n'
fi
