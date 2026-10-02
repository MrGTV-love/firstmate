#!/usr/bin/env bash
# Opt-in session launch policy through real spawn, control, and auto-recovery.
# All session executables and terminal side effects are deterministic fixtures.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-launch-policy)
mkdir -p "$TMP_ROOT"
cleanup() {
  chmod -R u+w "$TMP_ROOT"
  rm -rf "$TMP_ROOT"
  for tmp in /tmp/fm-launch-policy-*; do
    case "$tmp" in
      /tmp/fm-launch-policy-"$RUN_TAG"-*) rm -rf "$tmp" ;;
    esac
  done
}
RUN_TAG="$$-$RANDOM"
trap cleanup EXIT

make_case() {
  local name=$1 harness=$2
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  WT="$CASE/wt"
  ID="launch-policy-$RUN_TAG-$name"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/tools")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  fm_git_worktree "$CASE/project" "$WT" "$name"
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  : > "$CASE/effects"
  printf 'zsh\n' > "$CASE/command"
  mv "$FAKEBIN/tmux" "$FAKEBIN/tmux-fixture"
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  display-message)
    case "$*" in
      *pane_current_command*) cat "$FM_POLICY_CASE/command"; exit 0 ;;
      *pane_current_path*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
      *cursor_y*) printf '1\n'; exit 0 ;;
    esac ;;
  list-windows)
    [ ! -f "$FM_POLICY_CASE/home/state/$FM_POLICY_ID.meta" ] || printf 'fm-%s\n' "$FM_POLICY_ID"
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  new-session|new-window|kill-window)
    printf '%s\n' "$1" >> "$FM_POLICY_CASE/effects" ;;
  send-keys)
    shift
    literal=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      payload=${1:-}
      case "$payload" in
        /exit|/quit)
          printf 'stop\n' >> "$FM_POLICY_CASE/effects"
          printf 'zsh\n' > "$FM_POLICY_CASE/command" ;;
        ". '"*"'")
          staged=${payload#". '"}; staged=${staged%"'"}
          /bin/bash "$staged" ;;
      esac
    fi
    exit 0 ;;
esac
exec "$(dirname "$0")/tmux-fixture" "$@"
SH
  chmod +x "$FAKEBIN/tmux"
  for executable in codex claude omp; do
    cat > "$FAKEBIN/$executable" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'launch:%s\n' "${0##*/}" >> "$FM_POLICY_CASE/effects"
printf '%s\n' "${0##*/}" > "$FM_POLICY_CASE/command"
SH
    chmod +x "$FAKEBIN/$executable"
  done
}

run_cli() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    FM_HOME="$HOME_DIR" HOME="$HOME_DIR/user-home" CLAUDE_CONFIG_DIR='' \
    FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$WT" FM_POLICY_CASE="$CASE" FM_POLICY_ID="$ID" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=1 \
    TMUX='fake,1,0' PATH="$FAKEBIN:$PATH" "$@" 2>&1
}

restrict() { printf 'omp-or-tc\n' > "$HOME_DIR/config/session-launch-policy"; }

seed_task() {
  local harness=$1
  cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
endpoint_task_id=$ID
kind=${2:-ship}
harness=$harness
worktree=$WT
project=$CASE/project
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
  printf 'unpublished work\n' > "$WT/unpublished"
  printf 'validation custody\n' > "$HOME_DIR/state/$ID.validation"
  cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-prior"
  cp "$HOME_DIR/data/$ID/brief.md" "$CASE/brief-prior"
}

assert_preserved() {
  cmp -s "$CASE/meta-prior" "$HOME_DIR/state/$ID.meta" || fail 'task metadata changed on refusal'
  cmp -s "$CASE/brief-prior" "$HOME_DIR/data/$ID/brief.md" || fail 'instructions changed on refusal'
  [ "$(cat "$WT/unpublished")" = 'unpublished work' ] || fail 'unpublished work changed'
  [ "$(cat "$HOME_DIR/state/$ID.validation")" = 'validation custody' ] || fail 'validation custody changed'
  [ ! -e "$HOME_DIR/state/$ID.control-relaunch" ] || fail 'refusal checkpointed a replacement'
  [ ! -s "$CASE/effects" ] || fail "refusal caused side effects: $(cat "$CASE/effects")"
}

for harness in codex claude pi 'env codex' 'omp --model anything'; do
  make_case "fresh-$RANDOM" "$harness"
  restrict
  rc=0
  out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --harness "$harness" --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne 0 ] || fail "restricted fresh $harness launch succeeded: $out; $(cat "$CASE/effects")"
  assert_contains "$out" 'session-launch-policy' 'refusal identifies policy'
  [ ! -s "$CASE/effects" ] || fail "fresh refusal allocated or launched: $(cat "$CASE/effects")"
  [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail 'fresh refusal published metadata'
  pass "restricted fresh $harness launch refuses before resources"
done

for kind in ship scout batch; do
  make_case "default-$kind" codex
  restrict
  rc=0
  case "$kind" in
    ship) out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --mode no-mistakes --yolo off) || rc=$? ;;
    scout) out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --scout) || rc=$? ;;
    batch) out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID=$CASE/project" --mode no-mistakes --yolo off) || rc=$? ;;
  esac
  [ "$rc" -ne 0 ] || fail "default $kind bypassed restriction"
  assert_contains "$out" 'session-launch-policy' 'configured default obeys policy'
  [ ! -s "$CASE/effects" ] || fail 'default refusal changed launch resources'
  pass "configured $kind default obeys launch policy"
done

for harness in codex claude; do
  make_case "recovery-$harness" omp
  restrict
  seed_task "$harness"
  printf '%s\n' "$harness" > "$CASE/command"
  rc=0
  out=$(run_cli "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'continue preserved work') || rc=$?
  [ "$rc" -ne 0 ] || fail 'restricted recorded runtime relaunched'
  assert_contains "$out" 'session-launch-policy' 'control refusal identifies policy'
  assert_preserved
  [ "$(cat "$CASE/command")" = "$harness" ] || fail 'existing agent stopped'
  printf 'zsh\n' > "$CASE/command"
  rc=0
  out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch) || rc=$?
  [ "$rc" -ne 0 ] || fail 'direct recorded runtime relaunched'
  assert_contains "$out" 'session-launch-policy' 'direct refusal identifies policy'
  assert_preserved
  "$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$ID" --state idle --source claude-hook --event launch-brief >/dev/null
  gen=$(cat "$HOME_DIR/state/$ID.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$ID" idle --gen "$gen" --source claude-hook --event session-end >/dev/null
  # shellcheck disable=SC2016 # Expand in the isolated child shell, not here.
  out=$(run_cli bash -c '. "$1/bin/fm-session-end-relaunch-lib.sh"; fm_session_end_relaunch_scan "$FM_HOME/state"; printf "%s\n" "$FM_SESSION_END_WAKE"' _ "$ROOT")
  assert_contains "$out" 'session-launch-policy' 'automatic recovery reports policy refusal'
  assert_preserved
  pass "manual, direct, and automatic $harness recovery preserve work and custody"
done

make_case replacement omp
restrict
seed_task claude
printf 'claude\n' > "$CASE/command"
out=$(run_cli "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness omp --model openai-codex/gpt-6.1-sol --effort high --note 'explicit replacement') || fail "$out"
assert_contains "$out" 'harness=omp' 'explicit replacement is allowed'
grep -Fx 'stop' "$CASE/effects" >/dev/null || fail 'replacement never stopped old agent'
grep -Fx 'launch:omp' "$CASE/effects" >/dev/null || fail 'replacement never ran omp executable'
[ "$(cat "$WT/unpublished")" = 'unpublished work' ] || fail 'replacement lost work'
pass 'explicit omp replacement allows the openai-codex provider'

make_case fresh-omp omp
restrict
out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --model openai-codex/gpt-6.1-sol --mode no-mistakes --yolo off) || fail "$out"
grep -Fx 'launch:omp' "$CASE/effects" >/dev/null || fail 'fresh omp never launched'
pass 'fresh omp launch works with Codex provider'

make_case secondmate codex
restrict
rc=0
out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$WT" --secondmate) || rc=$?
[ "$rc" -ne 0 ] || fail 'secondmate launched forbidden runtime'
assert_contains "$out" 'session-launch-policy' 'secondmate refusal identifies policy'
[ ! -s "$CASE/effects" ] || fail 'secondmate refusal allocated resources'
pass 'fresh secondmate obeys restriction'

make_case secondmate-recovery omp
restrict
seed_task omp secondmate
printf 'omp\n' > "$CASE/command"
printf 'codex some-model high\n' > "$HOME_DIR/config/secondmate-harness"
rc=0
out=$(run_cli "$ROOT/bin/fm-control.sh" "$ID" relaunch) || rc=$?
[ "$rc" -ne 0 ] || fail 'configured secondmate pin launched forbidden runtime'
assert_contains "$out" 'session-launch-policy' 'secondmate pin refusal identifies policy'
assert_preserved
[ "$(cat "$CASE/command")" = omp ] || fail 'running secondmate stopped'
pass 'secondmate recovery checks configured replacement before stopping'

make_case malformed omp
for value in '' 'unknown' $'omp-or-tc\n\n' 'omp-or-tc '; do
  printf '%s' "$value" > "$HOME_DIR/config/session-launch-policy"
  rc=0
  out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne 0 ] || fail 'malformed policy disabled restriction'
  assert_contains "$out" 'session-launch-policy' 'malformed policy is actionable'
  [ ! -s "$CASE/effects" ] || fail 'malformed policy changed launch resources'
done
rm "$HOME_DIR/config/session-launch-policy"
ln -s "$CASE/absent" "$HOME_DIR/config/session-launch-policy"
rc=0
out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --mode no-mistakes --yolo off) || rc=$?
[ "$rc" -ne 0 ] || fail 'dangling policy disabled restriction'
assert_contains "$out" 'session-launch-policy' 'dangling policy is actionable'
pass 'malformed or dangling opt-in never disables restriction'

# Native tc run has no verified adapter here. Even a configured proxy launcher
# must not authorize a plain Claude template under the literal policy.
make_case tc-prerequisite claude
restrict
printf 'teamclaude\n' > "$HOME_DIR/config/claude-launcher"
rc=0
out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --mode no-mistakes --yolo off) || rc=$?
[ "$rc" -ne 0 ] || fail 'proxy configuration bypassed literal launch policy'
assert_contains "$out" 'tc run requires a verified native launcher' 'tc prerequisite is explicit'
[ ! -s "$CASE/effects" ] || fail 'tc prerequisite launched plain Claude'
pass 'unlanded tc run prerequisite refuses plain Claude without a fallback'

make_case inheritance codex
restrict
mkdir -p "$WT/config"
printf '/config/\n' > "$WT/.gitignore"
# shellcheck disable=SC2016 # Expand in the isolated child shell, not here.
run_cli bash -c '. "$1/bin/fm-config-inherit-lib.sh"; propagate_inheritable_config "$FM_HOME/config" "$2/config"' _ "$ROOT" "$WT"
cmp -s "$HOME_DIR/config/session-launch-policy" "$WT/config/session-launch-policy" || fail 'restriction did not inherit'
rc=0
out=$(FM_HOME="$WT" HOME_DIR="$WT" run_cli "$ROOT/bin/fm-spawn.sh" inherited "$CASE/project" --harness codex --mode no-mistakes --yolo off) || rc=$?
[ "$rc" -ne 0 ] || fail 'inherited restriction did not refuse'
assert_contains "$out" 'session-launch-policy' 'inherited refusal identifies policy'
[ ! -s "$CASE/effects" ] || fail 'inherited refusal allocated resources'
pass 'inherited policy enforces future descendant launches'

for harness in codex claude; do
  make_case "legacy-$harness" "$harness"
  out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --mode no-mistakes --yolo off) || fail "$out"
  grep -Fx "launch:$harness" "$CASE/effects" >/dev/null || fail 'absent policy changed launch'
  pass "absent policy preserves $harness launch (fixture executable only)"
done
