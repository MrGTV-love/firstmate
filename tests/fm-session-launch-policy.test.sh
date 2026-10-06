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
  CHILD_HOME=
  CASE_TMPDIR=
  INHERIT_REPORT=
  EXPECT_CHILD_POLICY=0
  SKIP_CHILD_INHERIT=0
  SKIP_CHILD_SYNC=0
  INHERIT_FAILURE=
  REAL_MV=$(command -v mv)
  REAL_MKTEMP=$(command -v mktemp)
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
check_child_policy() {
  [ -n "${FM_POLICY_CHILD:-}" ] || return 0
  [ "$FM_POLICY_EXPECT_ENABLED" = 1 ] || return 0
  [ -f "$FM_POLICY_CHILD/config/session-launch-policy" ] \
    && [ ! -L "$FM_POLICY_CHILD/config/session-launch-policy" ] \
    && cmp -s "$FM_POLICY_CASE/expected-policy" "$FM_POLICY_CHILD/config/session-launch-policy" \
    || exit 98
  printf '%s:enabled\n' "$1" >> "$FM_POLICY_CASE/admission"
}
case "$1" in
  display-message)
    case "$*" in
      *pane_current_command*) cat "$FM_POLICY_CASE/command"; exit 0 ;;
      *pane_current_path*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
      *cursor_y*) printf '1\n'; exit 0 ;;
    esac ;;
  list-windows)
    if [ -f "$FM_POLICY_CASE/home/state/$FM_POLICY_ID.meta" ] && [ ! -e "$FM_POLICY_CASE/endpoint-killed" ]; then
      printf 'fm-%s\n' "$FM_POLICY_ID"
    fi
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  new-session|new-window)
    printf '%s\n' "$1" >> "$FM_POLICY_CASE/effects"
    rm -f "$FM_POLICY_CASE/endpoint-killed" ;;
  kill-window)
    printf 'kill-window\n' >> "$FM_POLICY_CASE/effects"
    check_child_policy kill
    : > "$FM_POLICY_CASE/endpoint-killed" ;;
  send-keys)
    [ -z "${FM_POLICY_CHILD:-}" ] || printf 'send-keys\n' >> "$FM_POLICY_CASE/terminal-input"
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
          check_child_policy stop
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
if [ -n "${FM_POLICY_CHILD:-}" ]; then
  printf 'launch-attempt:%s\n' "${0##*/}" >> "$FM_POLICY_CASE/effects"
  [ "$FM_HOME" = "$FM_POLICY_CHILD" ] || exit 97
  [ -z "${FM_ROOT_OVERRIDE:-}${FM_STATE_OVERRIDE:-}${FM_DATA_OVERRIDE:-}${FM_CONFIG_OVERRIDE:-}${FM_PROJECTS_OVERRIDE:-}" ] || exit 96
  if [ "$FM_POLICY_EXPECT_ENABLED" = 1 ]; then
    [ -f "$FM_HOME/config/session-launch-policy" ] \
      && [ ! -L "$FM_HOME/config/session-launch-policy" ] \
      && cmp -s "$FM_POLICY_CASE/expected-policy" "$FM_HOME/config/session-launch-policy" \
      || exit 95
    printf 'launch:enabled\n' >> "$FM_POLICY_CASE/admission"
  else
    [ ! -e "$FM_HOME/config/session-launch-policy" ] && [ ! -L "$FM_HOME/config/session-launch-policy" ] || exit 94
    printf 'launch:absent\n' >> "$FM_POLICY_CASE/admission"
  fi
  printf '%s\n' "$FM_HOME" >> "$FM_POLICY_CASE/child-launch"
fi
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
    FM_POLICY_CHILD="$CHILD_HOME" FM_POLICY_EXPECT_ENABLED="$EXPECT_CHILD_POLICY" \
    FM_SKIP_SECONDMATE_INHERIT="$SKIP_CHILD_INHERIT" FM_SKIP_SECONDMATE_SYNC="$SKIP_CHILD_SYNC" \
    FM_POLICY_INHERIT_FAILURE="$INHERIT_FAILURE" FM_POLICY_REAL_MV="$REAL_MV" \
    FM_POLICY_REAL_MKTEMP="$REAL_MKTEMP" \
    FM_CONFIG_INHERIT_REPORT="$INHERIT_REPORT" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=1 \
    TMPDIR="${CASE_TMPDIR:-${TMPDIR:-/tmp}}" FM_BACKEND=tmux \
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

make_secondmate_case() {
  local name=$1 harness=$2 entry=$3
  make_case "$name" "$harness"
  CHILD_HOME=$WT
  SKIP_CHILD_SYNC=1
  CASE_TMPDIR="$CASE/tmp"
  INHERIT_REPORT="$CASE/inherit-report"
  mkdir -p "$CHILD_HOME/bin" "$CHILD_HOME/config" "$CHILD_HOME/data" \
    "$CHILD_HOME/state" "$CHILD_HOME/projects" "$CASE_TMPDIR"
  printf '# Firstmate\n' > "$CHILD_HOME/AGENTS.md"
  printf '%s\n' "$ID" > "$CHILD_HOME/.fm-secondmate-home"
  printf '/config/\n/data/\n/state/\n/projects/\n' > "$CHILD_HOME/.gitignore"
  printf 'persistent descendant charter\n' > "$CHILD_HOME/data/charter.md"
  printf '%s\n' "$harness" > "$HOME_DIR/config/secondmate-harness"
  printf -- '- %s - descendant policy (home: %s; scope: policy; projects: alpha; added 2026-10-06)\n' \
    "$ID" "$CHILD_HOME" > "$HOME_DIR/data/secondmates.md"
  seed_task "$harness" secondmate
  printf 'home=%s\n' "$CHILD_HOME" >> "$HOME_DIR/state/$ID.meta"
  cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-prior"
  [ "$entry" != fresh ] || rm "$HOME_DIR/state/$ID.meta" "$CASE/meta-prior"
  printf 'window=firstmate:fm-child-task\nkind=ship\nharness=omp\nworktree=%s\n' \
    "$CHILD_HOME/projects/alpha" > "$CHILD_HOME/state/child-task.meta"
  printf 'child validation custody\n' > "$CHILD_HOME/state/child-task.validation"
  printf '1\tattempt\n1\tfailed\n' > "$HOME_DIR/state/.secondmate-relaunch-$ID"
  cp "$HOME_DIR/state/.secondmate-relaunch-$ID" "$CASE/ledger-prior"
  cp "$HOME_DIR/data/secondmates.md" "$CASE/registry-prior"
  cp "$CHILD_HOME/data/charter.md" "$CASE/charter-prior"
  cp "$CHILD_HOME/state/child-task.meta" "$CASE/child-meta-prior"
  cp "$CHILD_HOME/state/child-task.validation" "$CASE/child-validation-prior"
  git -C "$CHILD_HOME" rev-parse HEAD > "$CASE/head-prior"
  printf 'omp-or-tc\n' > "$CASE/expected-policy"
  : > "$CASE/admission"
  : > "$INHERIT_REPORT"
  : > "$CASE/inherit-failures"
  cat > "$FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
set -eu
dest=${!#}
if [ "$FM_POLICY_INHERIT_FAILURE" = publication ] \
   && [ "$dest" = "$FM_POLICY_CHILD/config/session-launch-policy" ]; then
  printf 'policy-publication\n' >> "$FM_POLICY_CASE/inherit-failures"
  exit 73
fi
exec "$FM_POLICY_REAL_MV" "$@"
SH
  cat > "$FAKEBIN/mktemp" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$FM_POLICY_INHERIT_FAILURE" = unwritable ]; then
  case "${1:-}" in
    "$FM_POLICY_CHILD/config/.fm-inherit."*)
      printf 'config-write\n' >> "$FM_POLICY_CASE/inherit-failures"
      exit 73 ;;
  esac
fi
exec "$FM_POLICY_REAL_MKTEMP" "$@"
SH
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'treehouse:%s\n' "$*" >> "$FM_POLICY_CASE/effects"
exit 0
SH
  chmod +x "$FAKEBIN/mv" "$FAKEBIN/mktemp" "$FAKEBIN/treehouse"
}

set_child_policy_case() {
  local scenario=$1
  case "$scenario" in
    publication-absent|publication-malformed) INHERIT_FAILURE=publication ;;
    unwritable-absent) INHERIT_FAILURE=unwritable ;;
    gitignore-absent|gitignore-malformed)
      printf '/config/*\n!/config/session-launch-policy\n/data/\n/state/\n/projects/\n' > "$CHILD_HOME/.gitignore" ;;
    skip-absent|skip-malformed|skip-valid) SKIP_CHILD_INHERIT=1 ;;
    unrelated)
      mkdir "$CHILD_HOME/config/crew-harness" ;;
  esac
  case "$scenario" in
    *-malformed)
      printf 'invalid\n' > "$CHILD_HOME/config/session-launch-policy" ;;
    valid|skip-valid)
      cp "$CASE/expected-policy" "$CHILD_HOME/config/session-launch-policy" ;;
  esac
  if [ -f "$CHILD_HOME/config/session-launch-policy" ]; then
    cp "$CHILD_HOME/config/session-launch-policy" "$CASE/child-policy-prior"
  fi
}

run_secondmate_entry() {
  local entry=$1
  case "$entry" in
    fresh)
      run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CHILD_HOME" --secondmate ;;
    direct)
      run_cli "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch ;;
    control)
      run_cli "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'continue descendant work' ;;
    auto)
      # shellcheck disable=SC2016
      run_cli bash -c '
        set -eu
        . "$1/bin/fm-secondmate-liveness-lib.sh"
        STATE="$FM_HOME/state"
        id=$FM_POLICY_ID
        meta="$STATE/$id.meta"
        fm_secondmate_liveness_lock "$id"
        trap '\''fm_secondmate_liveness_unlock "$id"'\'' EXIT
        fm_secondmate_liveness_probe "$meta" "$id" poll
        printf "%s\n" "$FM_SM_LIVE_STATE" > "$FM_POLICY_CASE/liveness-state"
        [ "$FM_SM_LIVE_STATUS" = relaunchable ] || exit 1
        rc=0
        fm_secondmate_liveness_relaunch "$meta" "$id" || rc=$?
        printf "%s\n" "$FM_SM_LIVE_STATUS" > "$FM_POLICY_CASE/liveness-status"
        printf "%s\n" "$FM_SM_LIVE_OUT"
        exit "$rc"
      ' _ "$ROOT" ;;
  esac
}

set_secondmate_endpoint() {
  case "$1" in
    control) printf '%s\n' "$2" > "$CASE/command" ;;
    *) printf 'zsh\n' > "$CASE/command" ;;
  esac
}

assert_secondmate_work() {
  cmp -s "$CASE/registry-prior" "$HOME_DIR/data/secondmates.md" || fail 'secondmate registry changed'
  cmp -s "$CASE/brief-prior" "$HOME_DIR/data/$ID/brief.md" || fail 'secondmate parent brief changed'
  cmp -s "$CASE/charter-prior" "$CHILD_HOME/data/charter.md" || fail 'secondmate charter changed'
  cmp -s "$CASE/child-meta-prior" "$CHILD_HOME/state/child-task.meta" || fail 'descendant task record changed'
  cmp -s "$CASE/child-validation-prior" "$CHILD_HOME/state/child-task.validation" || fail 'descendant custody changed'
  [ "$(cat "$CHILD_HOME/unpublished")" = 'unpublished work' ] || fail 'secondmate unpublished work changed'
  [ "$(cat "$CASE/head-prior")" = "$(git -C "$CHILD_HOME" rev-parse HEAD)" ] || fail 'secondmate HEAD changed'
}

assert_secondmate_refused() {
  local entry=$1
  assert_secondmate_work
  if [ "$entry" = fresh ]; then
    [ ! -e "$HOME_DIR/state/$ID.meta" ] || fail 'secondmate refusal published a task record'
  else
    assert_preserved
  fi
  [ "$(cat "$HOME_DIR/state/$ID.validation")" = 'validation custody' ] || fail 'parent custody changed on refusal'
  cmp -s "$CASE/ledger-prior" "$HOME_DIR/state/.secondmate-relaunch-$ID" || fail 'refusal consumed a recovery attempt'
  [ ! -e "$HOME_DIR/state/$ID.control-relaunch" ] || fail 'refusal checkpointed the secondmate'
  [ ! -e "$HOME_DIR/state/$ID.control-relaunch.meta-prior" ] || fail 'refusal backed up the replacement record'
  [ ! -e "$HOME_DIR/state/$ID.control-relaunch.note" ] || fail 'refusal recorded a replacement note'
  [ ! -e "$CASE/child-launch" ] || fail 'refusal launched a descendant'
  [ ! -s "$CASE/admission" ] || fail 'refusal reached a destructive admission boundary'
  [ ! -s "$CASE/terminal-input" ] || fail 'refusal sent terminal input'
  [ ! -s "$CASE/effects" ] || fail "secondmate refusal had effects: $(cat "$CASE/effects")"
  [ ! -e "/tmp/fm-$ID" ] || fail 'refusal allocated child task resources'
  if [ -f "$CASE/child-policy-prior" ]; then
    cmp -s "$CASE/child-policy-prior" "$CHILD_HOME/config/session-launch-policy" || fail 'refusal changed unrepaired child policy'
  else
    [ ! -e "$CHILD_HOME/config/session-launch-policy" ] && [ ! -L "$CHILD_HOME/config/session-launch-policy" ] \
      || fail 'failed child policy convergence published a policy'
  fi
  if [ "$entry" = control ]; then
    [ "$(cat "$CASE/command")" = omp ] || fail 'refusal stopped the running secondmate'
  elif [ "$entry" = auto ]; then
    [ "$(cat "$CASE/liveness-state")" = dead ] || fail 'automatic fixture was not recovery-authorizing'
    [ "$(cat "$CASE/liveness-status")" = skipped ] || fail 'automatic refusal was not skipped'
  fi
}

assert_inheritance_refusal() {
  local scenario=$1 status
  case "$scenario" in
    publication-*)
      status=error
      grep -Fx 'policy-publication' "$CASE/inherit-failures" >/dev/null || fail 'publication fixture was not reached' ;;
    unwritable-*)
      status=error
      grep -Fx 'config-write' "$CASE/inherit-failures" >/dev/null || fail 'config-write fixture was not reached' ;;
    gitignore-*) status=skipped ;;
    skip-*)
      [ ! -s "$INHERIT_REPORT" ] || fail 'host-local inheritance skip propagated config'
      return 0 ;;
  esac
  awk -F '\t' -v status="$status" '$1 == "session-launch-policy" && $2 == status { found = 1 } END { exit !found }' \
    "$INHERIT_REPORT" || fail 'policy convergence did not exercise its expected failure boundary'
}

assert_secondmate_launched() {
  local entry=$1 harness=$2 policy=$3
  assert_secondmate_work
  [ "$(cat "$CASE/child-launch")" = "$CHILD_HOME" ] || fail 'launch did not run exactly once in the child home'
  [ "$(grep -Fxc "launch:$harness" "$CASE/effects")" = 1 ] || fail 'expected child executable did not launch exactly once'
  [ "$(grep -Fxc "launch-attempt:$harness" "$CASE/effects")" = 1 ] || fail 'child executable launch was duplicated'
  grep -Fx "launch:$policy" "$CASE/admission" >/dev/null || fail 'child executable did not observe expected policy'
  if [ "$policy" = enabled ]; then
    cmp -s "$CASE/expected-policy" "$CHILD_HOME/config/session-launch-policy" || fail 'successful launch has no valid enabled child policy'
  fi
  case "$entry" in
    fresh)
      grep -Fx 'new-window' "$CASE/effects" >/dev/null || fail 'fresh secondmate did not create an endpoint' ;;
    direct)
      [ "$(cat "$CASE/effects")" = "$(printf 'launch-attempt:%s\nlaunch:%s' "$harness" "$harness")" ] \
        || fail 'direct relaunch changed resources instead of adopting the endpoint' ;;
    control)
      grep -Fx 'stop' "$CASE/effects" >/dev/null || fail 'control did not stop the old secondmate'
      [ "$policy" != enabled ] || grep -Fx 'stop:enabled' "$CASE/admission" >/dev/null \
        || fail 'control stopped before required child policy was present' ;;
    auto)
      grep -Fx 'kill-window' "$CASE/effects" >/dev/null || fail 'automatic recovery did not kill the dead endpoint'
      grep -Fx 'new-window' "$CASE/effects" >/dev/null || fail 'automatic recovery did not create an endpoint'
      [ "$policy" != enabled ] || grep -Fx 'kill:enabled' "$CASE/admission" >/dev/null \
        || fail 'automatic recovery killed before required child policy was present'
      awk -F '\t' '$2 == "attempt" { attempts++ } $2 == "relaunched" { relaunched++ } END { exit !(attempts == 2 && relaunched == 1) }' \
        "$HOME_DIR/state/.secondmate-relaunch-$ID" || fail 'automatic recovery did not record exactly one successful attempt' ;;
  esac
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

for entry in fresh direct control auto; do
  for scenario in publication-absent publication-malformed unwritable-absent \
    gitignore-absent gitignore-malformed skip-absent skip-malformed; do
    make_secondmate_case "child-$entry-$scenario" omp "$entry"
    restrict
    EXPECT_CHILD_POLICY=1
    set_child_policy_case "$scenario"
    set_secondmate_endpoint "$entry" omp
    rc=0
    out=$(run_secondmate_entry "$entry") || rc=$?
    [ "$rc" -ne 0 ] || fail "$entry accepted $scenario descendant policy: $out"
    assert_contains "$out" 'session-launch-policy' "$entry descendant refusal identifies policy"
    assert_secondmate_refused "$entry"
    assert_inheritance_refusal "$scenario"
    pass "$entry refuses unrepaired $scenario descendant policy before stop, launch, resources, or custody"
  done
done

for entry in fresh direct control auto; do
  for scenario in repair-absent repair-malformed valid skip-valid unrelated; do
    make_secondmate_case "child-$entry-$scenario" omp "$entry"
    restrict
    EXPECT_CHILD_POLICY=1
    set_child_policy_case "$scenario"
    set_secondmate_endpoint "$entry" omp
    out=$(run_secondmate_entry "$entry") || fail "$entry $scenario launch failed: $out"
    assert_secondmate_launched "$entry" omp enabled
    case "$scenario" in
      repair-*)
        awk -F '\t' '$1 == "session-launch-policy" && $2 == "pushed" { found = 1 } END { exit !found }' \
          "$INHERIT_REPORT" || fail 'writable child policy was not repaired through convergence' ;;
      skip-valid)
        awk -F '\t' '$1 == "session-launch-policy" { found = 1 } END { exit found }' \
          "$INHERIT_REPORT" || fail 'host-local launch propagated skipped policy' ;;
      unrelated)
        awk -F '\t' '$1 == "crew-harness" && $2 == "error" { found = 1 } END { exit !found }' \
          "$INHERIT_REPORT" || fail 'unrelated best-effort inheritance fixture never failed' ;;
    esac
    pass "$entry $scenario launches omp only with enabled child policy at every destructive boundary"
  done
done

for entry in fresh direct control auto; do
  make_secondmate_case "child-$entry-legacy" codex "$entry"
  set_child_policy_case unwritable-absent
  set_secondmate_endpoint "$entry" codex
  out=$(run_secondmate_entry "$entry") || fail "$entry absent-parent compatibility failed: $out"
  assert_secondmate_launched "$entry" codex absent
  [ ! -e "$HOME_DIR/config/session-launch-policy" ] || fail 'legacy case unexpectedly enabled the parent policy'
  grep -Fx 'config-write' "$CASE/inherit-failures" >/dev/null || fail 'legacy best-effort write failure fixture never failed'
  pass "$entry absent parent preserves codex secondmate launch despite unrelated config write failures"
done

make_secondmate_case child-auto-missing-state omp auto
restrict
EXPECT_CHILD_POLICY=1
set_secondmate_endpoint auto omp
mv "$CHILD_HOME/state" "$CASE/child-state-prior"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
rc=0
out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 10 run_secondmate_entry auto) || rc=$?
[ "$rc" = 1 ] || fail "missing child state did not refuse promptly: rc=$rc; $out"
[ ! -e "$CHILD_HOME/state" ] || fail 'missing-state refusal created child state'
mv "$CASE/child-state-prior" "$CHILD_HOME/state"
assert_secondmate_refused auto
pass 'automatic recovery refuses missing child state before waiting, attempts, or endpoint removal'
