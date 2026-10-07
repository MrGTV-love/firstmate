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
CASE_SEQ=0
trap cleanup EXIT

make_case() {
  local name=$1 harness=$2
  CASE="$TMP_ROOT/$name"
  HOME_DIR="$CASE/home"
  WT="$CASE/wt"
  CASE_SEQ=$((CASE_SEQ + 1))
  ID="launch-policy-$RUN_TAG-$CASE_SEQ"
  CHILD_HOME=
  CASE_TMPDIR=
  CASE_ROOT=
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
    target=default
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    mkdir -p "$FM_POLICY_CASE/input"
    buffer="$FM_POLICY_CASE/input/$target"
    if [ "$literal" = 1 ]; then
      printf '%s' "$@" >> "$buffer"
    else
      for key in "$@"; do
        [ "$key" = Enter ] || continue
        payload=
        [ ! -f "$buffer" ] || payload=$(cat "$buffer")
        rm -f "$buffer"
        case "$payload" in
          /exit|/quit)
            printf 'stop\n' >> "$FM_POLICY_CASE/effects"
            check_child_policy stop
            printf 'zsh\n' > "$FM_POLICY_CASE/command" ;;
          ". '"*"'")
            staged=${payload#". '"}; staged=${staged%"'"}
            /bin/bash "$staged" ;;
        esac
      done
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
if [ "${0##*/}" = omp ] && [ "${1:-}" = models ] && [ "${2:-}" = --json ]; then
  printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"}]}'
  exit 0
fi
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
    FM_ROOT_OVERRIDE="$CASE_ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
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
  [ ! -e "$HOME_DIR/state/.session-end-relaunch-$ID" ] || fail 'refusal consumed session-end recovery budget'
  [ ! -e "$HOME_DIR/state/.session-end-handled-$ID" ] || fail 'refusal marked the session-end generation handled'
  [ ! -s "$CASE/effects" ] || fail "refusal caused side effects: $(cat "$CASE/effects")"
}

make_secondmate_case() {
  local name=$1 harness=$2 entry=$3
  make_case "$name" "$harness"
  # Keep the logical code root beside the child even when TMPDIR is under ROOT.
  # Only link the source resources; execute the real scripts and keep fixtures local.
  CASE_ROOT="$CASE/project"
  ln -s "$ROOT/bin" "$CASE_ROOT/bin"
  ln -s "$ROOT/.omp" "$CASE_ROOT/.omp"
  CHILD_HOME=$WT
  SKIP_CHILD_SYNC=1
  CASE_TMPDIR="$CASE/tmp"
  INHERIT_REPORT="$CASE/inherit-report"
  mkdir -p "$CHILD_HOME/bin" "$CHILD_HOME/config" "$CHILD_HOME/data" \
    "$CHILD_HOME/state" "$CHILD_HOME/projects" "$CASE_TMPDIR"
  ln -s "$ROOT/bin/"* "$CHILD_HOME/bin/"
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
  shift
  case "$entry" in
    fresh)
      run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CHILD_HOME" --secondmate "$@" ;;
    direct)
      run_cli "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch "$@" ;;
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
        printf "%s\n" "${FM_SM_LIVE_POLICY_REFUSED:-0}" > "$FM_POLICY_CASE/liveness-policy-refused"
        printf "%s\n" "${FM_SM_LIVE_WAKE:-}" > "$FM_POLICY_CASE/liveness-wake"
        printf "%s\n" "$FM_SM_LIVE_REASON" > "$FM_POLICY_CASE/liveness-reason"
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
    gitignore-*) status=error ;;
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

make_case terminal-submission omp
printf 'omp\n' > "$CASE/launch.sh"
run_cli tmux send-keys -t firstmate:worker -l ". '$CASE/launch.sh'"
run_cli tmux send-keys -t firstmate:other -l /exit
[ ! -s "$CASE/effects" ] || fail 'literal input executed without Enter'
[ "$(cat "$CASE/command")" = zsh ] || fail 'literal input changed the foreground command'
run_cli tmux send-keys -t firstmate:other Enter
[ "$(cat "$CASE/effects")" = stop ] || fail 'Enter submitted another target buffer'
run_cli tmux send-keys -t firstmate:worker Enter
[ "$(cat "$CASE/effects")" = "$(printf 'stop\nlaunch:omp')" ] || fail 'Enter did not submit the buffered launch'
[ "$(cat "$CASE/command")" = omp ] || fail 'submitted launch did not become foreground command'
run_cli tmux send-keys -t firstmate:worker Enter
[ "$(grep -Fxc 'launch:omp' "$CASE/effects")" = 1 ] || fail 'Enter resubmitted consumed input'
run_cli tmux send-keys -t firstmate:worker -l /qu
run_cli tmux send-keys -t firstmate:worker -l it
[ "$(cat "$CASE/command")" = omp ] || fail 'literal quit input stopped the agent'
run_cli tmux send-keys -t firstmate:worker Enter
[ "$(cat "$CASE/command")" = zsh ] || fail 'Enter did not submit accumulated quit input'
[ "$(grep -Fxc stop "$CASE/effects")" = 2 ] || fail 'submitted exit and quit did not each stop once'
pass 'terminal fixture buffers each target until Enter and consumes submitted input'

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

session_end_scan() {
  # shellcheck disable=SC2016
  run_cli bash -c '
    . "$1/bin/fm-session-end-relaunch-lib.sh"
    fm_session_end_relaunch_scan "$FM_HOME/state" || exit $?
    printf "%s\n" "$FM_SESSION_END_WAKE" > "$FM_POLICY_CASE/session-end-wake"
    printf "%s\n" "$FM_SESSION_END_ACTION" > "$FM_POLICY_CASE/session-end-action"
    printf "%s\n" "$FM_SESSION_END_WAKE"
  ' _ "$ROOT"
}

assert_refusal_queue() {
  local expected=$1 count=0
  if [ -s "$HOME_DIR/state/.wake-queue" ]; then
    count=$(awk 'END { print NR + 0 }' "$HOME_DIR/state/.wake-queue")
    awk -F '\t' -v id="$ID" 'NF < 5 || $3 != "check" || !index($5, id) || !index($5, "session-launch-policy") { exit 1 }' \
      "$HOME_DIR/state/.wake-queue" || fail 'refusal queue contains an unexpected wake'
  fi
  [ "$count" = "$expected" ] || fail "expected $expected queued policy refusal(s), got $count"
}

ack_refusal_queue() {
  local output sequence generation
  output=$(run_cli "$ROOT/bin/fm-wake-drain.sh") || fail "refusal drain failed: $output"
  sequence=$(printf '%s\n' "$output" | awk '/^WAKE_ACK_REQUIRED:/ { for (i = 1; i < NF; i++) if ($i == "--ack-through") value = $(i + 1) } END { print value }')
  generation=$(printf '%s\n' "$output" | awk '/^WAKE_ACK_REQUIRED:/ { for (i = 1; i < NF; i++) if ($i == "--recovery-generation") value = $(i + 1) } END { print value }')
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "refusal drain omitted acknowledgement: $output"
  output=$(run_cli "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation") \
    || fail "refusal acknowledgement failed: $output"
  assert_refusal_queue 0
}

arm_session_end() {
  local source=$1
  "$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$ID" --state idle --source "$source" --event launch-brief >/dev/null
  gen=$(cat "$HOME_DIR/state/$ID.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$HOME_DIR/state" "$ID" idle --gen "$gen" --source "$source" --event session-end >/dev/null
}

assert_session_end_refusal() {
  local notify=$1 queued=$2 output
  output=$(session_end_scan) || fail "session-end scan failed: $output"
  if [ "$notify" = first ]; then
    assert_contains "$output" 'session-launch-policy' 'new automatic refusal reports the policy'
    [ "$(cat "$CASE/session-end-wake")" = "$output" ] || fail 'new refusal did not set FM_SESSION_END_WAKE'
  else
    [ -z "$output" ] || fail "repeated refusal emitted a scan result: $output"
    [ ! -s "$CASE/session-end-wake" ] || [ -z "$(cat "$CASE/session-end-wake")" ] \
      || fail 'repeated refusal set FM_SESSION_END_WAKE'
  fi
  [ "$(cat "$CASE/session-end-action")" = skip ] || fail 'policy refusal did not skip recovery'
  assert_refusal_queue "$queued"
  assert_preserved
}

exercise_session_end_refusals() {
  local source=$1 prior_gen=$gen
  cp "$HOME_DIR/config/session-launch-policy" "$CASE/refusal-policy-prior"
  assert_session_end_refusal first 1
  assert_session_end_refusal quiet 1
  ack_refusal_queue
  assert_session_end_refusal quiet 0
  printf 'changed-invalid\n' > "$HOME_DIR/config/session-launch-policy"
  assert_session_end_refusal first 1
  assert_session_end_refusal quiet 1
  cp "$CASE/refusal-policy-prior" "$HOME_DIR/config/session-launch-policy"
  assert_session_end_refusal quiet 1
  ack_refusal_queue
  assert_session_end_refusal quiet 0
  arm_session_end "$source"
  [ "$gen" != "$prior_gen" ] || fail 'session-end fixture did not advance the busy generation'
  assert_session_end_refusal first 1
  assert_session_end_refusal quiet 1
}

for harness in codex claude; do
  for kind in ship scout; do
    make_case "recovery-$harness-$kind" omp
    restrict
    seed_task "$harness" "$kind"
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
    arm_session_end fm-recovery
    exercise_session_end_refusals fm-recovery
    pass "manual, direct, and deduplicated automatic $harness $kind recovery preserve work and custody"
  done
done

for kind in ship scout; do
  make_case "recovery-malformed-$kind" omp
  seed_task omp "$kind"
  printf 'unknown\n' > "$HOME_DIR/config/session-launch-policy"
  arm_session_end omp-ext
  exercise_session_end_refusals omp-ext
  restrict
  out=$(session_end_scan) || fail "$out"
  assert_contains "$out" "$ID auto-relaunched after session-end" 'policy repair permits immediate recovery of the same generation'
  grep -Fx 'launch:omp' "$CASE/effects" >/dev/null || fail 'repaired policy did not launch omp'
  awk -F '\t' '$2 == "attempt" { attempts++ } $2 == "relaunched" { relaunched++ } END { exit !(attempts == 1 && relaunched == 1 && NR == 2) }' \
    "$HOME_DIR/state/.session-end-relaunch-$ID" || fail 'policy refusal was counted as an attempt'
  IFS=$'\t' read -r handled_gen _handled_seq handled_outcome < "$HOME_DIR/state/.session-end-handled-$ID"
  [ "$handled_gen" = "$gen" ] && [ "$handled_outcome" = relaunched ] || fail 'recovery did not handle the original generation'
  [ "$(cat "$WT/unpublished")" = 'unpublished work' ] || fail 'recovery lost unpublished work'
  [ "$(cat "$HOME_DIR/state/$ID.validation")" = 'validation custody' ] || fail 'recovery changed validation custody'
  pass "malformed policy preserves $kind recovery budget and allows immediate recovery after repair"
done

make_case replacement omp
restrict
seed_task claude
printf 'claude\n' > "$CASE/command"
out=$(run_cli "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness omp --model openai-codex/gpt-6.1-sol --effort high --note 'explicit replacement') || fail "$out"
assert_contains "$out" 'harness=omp' 'explicit replacement is allowed'
grep -Fx 'stop' "$CASE/effects" >/dev/null || fail 'replacement never stopped old agent'
[ "$(grep -Fxc 'launch:omp' "$CASE/effects")" = 1 ] || fail 'replacement did not run omp exactly once'
[ "$(cat "$WT/unpublished")" = 'unpublished work' ] || fail 'replacement lost work'
pass 'explicit omp replacement allows the openai-codex provider'

make_case fresh-omp omp
restrict
out=$(run_cli "$ROOT/bin/fm-spawn.sh" "$ID" "$CASE/project" --model openai-codex/gpt-6.1-sol --mode no-mistakes --yolo off) || fail "$out"
[ "$(grep -Fxc 'launch:omp' "$CASE/effects")" = 1 ] || fail 'fresh omp did not launch exactly once'
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
mkdir -p "$WT/config" "$WT/bin"
ln -s "$ROOT/bin/"* "$WT/bin/"
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
  for owner in fm-session-launch-policy-lib.sh fm-config-inherit-lib.sh \
    fm-spawn.sh fm-control.sh fm-secondmate-liveness-lib.sh \
    fm-session-end-relaunch-lib.sh fm-remote-secondmate-relaunch.sh \
    fm-remote-secondmate-control.sh; do
    make_secondmate_case "child-$entry-outdated-${owner%.sh}" omp "$entry"
    restrict
    EXPECT_CHILD_POLICY=1
    set_child_policy_case skip-valid
    SKIP_CHILD_SYNC=0
    rm "$CHILD_HOME/bin/$owner"
    cat > "$CHILD_HOME/bin/$owner" <<'SH'
#!/usr/bin/env bash
set -eu
exec codex "$@"
SH
    chmod +x "$CHILD_HOME/bin/$owner"
    cp "$CHILD_HOME/bin/$owner" "$CASE/tooling-prior"
    if [ "$owner" = fm-spawn.sh ]; then
      out=$(run_cli env FM_HOME="$CHILD_HOME" FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= \
        FM_DATA_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PROJECTS_OVERRIDE= \
        "$CHILD_HOME/bin/fm-spawn.sh" descendant --harness codex) \
        || fail "outdated executable fixture did not reach its policy bypass: $out"
      grep -Fx 'launch:codex' "$CASE/effects" >/dev/null || fail 'outdated child fixture did not launch forbidden codex'
      grep -Fx 'launch:enabled' "$CASE/admission" >/dev/null || fail 'outdated child bypass did not run with an enabled policy'
      : > "$CASE/effects"
      : > "$CASE/admission"
      rm "$CASE/child-launch"
    fi
    set_secondmate_endpoint "$entry" omp
    rc=0
    out=$(run_secondmate_entry "$entry") || rc=$?
    [ "$rc" -ne 0 ] || fail "$entry accepted outdated child $owner with enabled policy: $out"
    assert_contains "$out" 'session-launch-policy tooling is not verified' 'outdated child refusal identifies tooling boundary'
    assert_contains "$out" "$CHILD_HOME/bin/$owner" 'outdated child refusal names the incapable policy owner'
    cmp -s "$CASE/tooling-prior" "$CHILD_HOME/bin/$owner" || fail 'tooling admission rewrote preserved child code'
    assert_secondmate_refused "$entry"
    assert_inheritance_refusal skip-valid
    pass "$entry refuses outdated $owner before replacement even with valid skipped inheritance"
  done
done

for entry in fresh direct control auto; do
  make_secondmate_case "child-$entry-missing-tooling" omp "$entry"
  restrict
  EXPECT_CHILD_POLICY=1
  set_child_policy_case valid
  rm "$CHILD_HOME/bin/fm-spawn.sh"
  set_secondmate_endpoint "$entry" omp
  rc=0
  out=$(run_secondmate_entry "$entry") || rc=$?
  [ "$rc" -ne 0 ] || fail "$entry accepted missing child launcher: $out"
  assert_contains "$out" "$CHILD_HOME/bin/fm-spawn.sh" 'missing tooling refusal names the child launcher'
  [ ! -e "$CHILD_HOME/bin/fm-spawn.sh" ] || fail 'tooling admission installed a launcher in the preserved checkout'
  assert_secondmate_refused "$entry"
  pass "$entry refuses missing child tooling without overwriting checkout or consuming recovery"
done

for entry in fresh direct control auto; do
  for scenario in guarded-outdated guarded-capable removed-outdated removed-malformed; do
    make_secondmate_case "child-$entry-absent-primary-$scenario" omp "$entry"
    set_child_policy_case valid
    case "$scenario" in
      guarded-*)
        printf '/config/*\n!/config/session-launch-policy\n/data/\n/state/\n/projects/\n' > "$CHILD_HOME/.gitignore"
        EXPECT_CHILD_POLICY=1 ;;
      removed-malformed)
        printf 'invalid\n' > "$CHILD_HOME/config/session-launch-policy" ;;
    esac
    if [ "$scenario" != guarded-capable ]; then
      rm "$CHILD_HOME/bin/fm-spawn.sh"
      printf 'obsolete launcher\n' > "$CHILD_HOME/bin/fm-spawn.sh"
      cp "$CHILD_HOME/bin/fm-spawn.sh" "$CASE/tooling-prior"
    fi
    set_secondmate_endpoint "$entry" omp
    rc=0
    out=$(run_secondmate_entry "$entry") || rc=$?
    case "$scenario" in
      guarded-outdated)
        [ "$rc" -ne 0 ] || fail "$entry accepted an incompatible retained child policy: $out"
        assert_contains "$out" 'session-launch-policy tooling is not verified' 'retained child refusal identifies tooling boundary'
        assert_contains "$out" "$CHILD_HOME/bin/fm-spawn.sh" 'retained child refusal names the incapable launcher'
        assert_secondmate_refused "$entry" ;;
      guarded-capable)
        [ "$rc" = 0 ] || fail "$entry refused a capable retained child policy: $out"
        assert_secondmate_launched "$entry" omp enabled ;;
      removed-*)
        [ "$rc" = 0 ] || fail "$entry required capable tooling after policy removal: $out"
        assert_secondmate_launched "$entry" omp absent
        [ ! -e "$CHILD_HOME/config/session-launch-policy" ] || fail 'primary absence did not remove the writable child policy' ;;
    esac
    if [ "$scenario" != guarded-capable ]; then
      cmp -s "$CASE/tooling-prior" "$CHILD_HOME/bin/fm-spawn.sh" || fail 'absent-primary admission rewrote child tooling'
    fi
    pass "$entry checks effective child policy with absent primary: $scenario"
  done
done

for entry in fresh direct control auto; do
  make_secondmate_case "child-$entry-absent-primary-guarded-codex" omp "$entry"
  set_child_policy_case valid
  printf '/config/*\n!/config/session-launch-policy\n/data/\n/state/\n/projects/\n' > "$CHILD_HOME/.gitignore"
  EXPECT_CHILD_POLICY=1
  printf 'codex\n' > "$HOME_DIR/config/secondmate-harness"
  set_secondmate_endpoint "$entry" omp
  rc=0
  if [ "$entry" = direct ]; then
    out=$(run_secondmate_entry "$entry" --harness codex) || rc=$?
  else
    out=$(run_secondmate_entry "$entry") || rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "$entry accepted codex under the retained enabled child policy: $out"
  assert_contains "$out" 'session-launch-policy' 'retained child refusal identifies policy'
  assert_secondmate_refused "$entry"
  [ ! -e "$HOME_DIR/config/session-launch-policy" ] || fail 'retained child fixture unexpectedly enabled the parent policy'
  pass "$entry refuses codex under a write-guard-retained enabled child policy with current tooling"
done

for entry in fresh direct; do
  make_secondmate_case "child-$entry-absent-primary-guarded-raw" omp "$entry"
  set_child_policy_case valid
  printf '/config/*\n!/config/session-launch-policy\n/data/\n/state/\n/projects/\n' > "$CHILD_HOME/.gitignore"
  EXPECT_CHILD_POLICY=1
  set_secondmate_endpoint "$entry" omp
  rc=0
  out=$(run_secondmate_entry "$entry" --harness 'omp --model anything') || rc=$?
  [ "$rc" -ne 0 ] || fail "$entry accepted an opaque raw launch under the retained child policy: $out"
  assert_contains "$out" 'session-launch-policy' 'retained child raw refusal identifies policy'
  assert_secondmate_refused "$entry"
  [ ! -e "$HOME_DIR/config/session-launch-policy" ] || fail 'raw child fixture unexpectedly enabled the parent policy'
  pass "$entry refuses opaque raw launch under a write-guard-retained enabled child policy"
done

for entry in fresh direct control auto; do
  make_secondmate_case "child-$entry-absent-primary-removed-codex" codex "$entry"
  set_child_policy_case valid
  set_secondmate_endpoint "$entry" codex
  out=$(run_secondmate_entry "$entry") || fail "$entry refused codex after writable child policy removal: $out"
  assert_secondmate_launched "$entry" codex absent
  [ ! -e "$CHILD_HOME/config/session-launch-policy" ] && [ ! -L "$CHILD_HOME/config/session-launch-policy" ] \
    || fail 'primary absence did not remove the writable enabled child policy'
  [ ! -e "$HOME_DIR/config/session-launch-policy" ] || fail 'removed child fixture unexpectedly enabled the parent policy'
  pass "$entry preserves codex compatibility after successful enabled child policy removal"
done

for entry in fresh direct control auto; do
  make_secondmate_case "child-$entry-preserved-current-tooling" omp "$entry"
  restrict
  EXPECT_CHILD_POLICY=1
  set_child_policy_case valid
  SKIP_CHILD_SYNC=0
  git -C "$CHILD_HOME" checkout -b "preserved-$entry" >/dev/null 2>&1
  printf 'unique descendant commit\n' > "$CHILD_HOME/child-history"
  git -C "$CHILD_HOME" add child-history
  git -C "$CHILD_HOME" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'Preserve unique descendant history'
  git -C "$CHILD_HOME" rev-parse HEAD > "$CASE/head-prior"
  set_secondmate_endpoint "$entry" omp
  out=$(run_secondmate_entry "$entry") || fail "$entry refused capable preserved child: $out"
  assert_secondmate_launched "$entry" omp enabled
  [ "$(git -C "$CHILD_HOME" symbolic-ref --short HEAD)" = "preserved-$entry" ] || fail 'capability admission changed child branch'
  [ "$(cat "$CHILD_HOME/child-history")" = 'unique descendant commit' ] || fail 'capability admission changed unique child history'
  pass "$entry admits current policy owners while preserving dirty wrong-branch divergent child work"
done

make_secondmate_case child-own-tooling-policy omp direct
restrict
EXPECT_CHILD_POLICY=1
set_child_policy_case valid
rc=0
out=$(run_cli env FM_HOME="$CHILD_HOME" FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= \
  FM_DATA_OVERRIDE= FM_CONFIG_OVERRIDE= FM_PROJECTS_OVERRIDE= \
  "$CHILD_HOME/bin/fm-spawn.sh" descendant "$CHILD_HOME/projects/alpha" \
  --harness codex --mode no-mistakes --yolo off) || rc=$?
[ "$rc" -ne 0 ] || fail "capable child's own launcher admitted forbidden descendant codex: $out"
assert_contains "$out" 'session-launch-policy' 'actual child-owned launcher enforces inherited policy'
[ ! -s "$CASE/effects" ] || fail 'actual child-owned policy refusal reached a runtime or terminal'
pass 'capable child-owned executable enforces policy with root and config overrides cleared'

for entry in fresh direct control auto; do
  make_secondmate_case "child-$entry-legacy" codex "$entry"
  set_child_policy_case unwritable-absent
  rm "$CHILD_HOME/bin/fm-spawn.sh" "$CHILD_HOME/bin/fm-session-launch-policy-lib.sh"
  set_secondmate_endpoint "$entry" codex
  out=$(run_secondmate_entry "$entry") || fail "$entry absent-parent compatibility failed: $out"
  assert_secondmate_launched "$entry" codex absent
  [ ! -e "$CHILD_HOME/bin/fm-spawn.sh" ] || fail 'absent parent changed legacy child tooling'
  [ ! -e "$HOME_DIR/config/session-launch-policy" ] || fail 'legacy case unexpectedly enabled the parent policy'
  grep -Fx 'config-write' "$CASE/inherit-failures" >/dev/null || fail 'legacy best-effort write failure fixture never failed'
  pass "$entry absent parent preserves legacy codex secondmate launch despite missing policy tooling and config write failures"
done

assert_secondmate_auto_refusal() {
  local notify=$1 queued=$2 output rc=0
  output=$(run_secondmate_entry auto) || rc=$?
  [ "$rc" = 1 ] || fail "automatic policy denial returned $rc: $output"
  assert_contains "$output" 'session-launch-policy' 'automatic secondmate denial retains diagnostics'
  assert_contains "$(cat "$CASE/liveness-reason")" 'session-launch-policy' 'automatic secondmate denial retains its reason'
  [ "$(cat "$CASE/liveness-policy-refused")" = 1 ] || fail 'automatic denial did not set FM_SM_LIVE_POLICY_REFUSED'
  if [ "$notify" = first ]; then
    assert_contains "$(cat "$CASE/liveness-wake")" 'session-launch-policy' 'new secondmate denial sets FM_SM_LIVE_WAKE'
  else
    [ -z "$(cat "$CASE/liveness-wake")" ] || fail 'repeated secondmate denial set FM_SM_LIVE_WAKE'
  fi
  assert_refusal_queue "$queued"
  assert_secondmate_refused auto
}

for denied in codex claude malformed legacy; do
  make_secondmate_case "child-auto-repeat-$denied" omp auto
  EXPECT_CHILD_POLICY=1
  set_secondmate_endpoint auto omp
  if [ "$denied" = legacy ]; then
    awk '!/^(home|worktree)=/' "$HOME_DIR/state/$ID.meta" > "$CASE/meta-legacy"
    mv "$CASE/meta-legacy" "$HOME_DIR/state/$ID.meta"
  fi
  cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-generation-base"
  case "$denied" in
    codex) generation_key=spawn_gen ;;
    claude) generation_key=busy_gen ;;
    malformed) generation_key=spawn_gen ;;
    legacy) generation_key= ;;
  esac
  if [ -n "$generation_key" ]; then
    printf '%s=policy-generation-1\n' "$generation_key" >> "$HOME_DIR/state/$ID.meta"
  fi
  cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-prior"
  if [ "$denied" = malformed ]; then
    printf 'unknown\n' > "$HOME_DIR/config/session-launch-policy"
  else
    restrict
    case "$denied" in
      legacy) printf 'codex\n' > "$HOME_DIR/config/secondmate-harness" ;;
      *) printf '%s\n' "$denied" > "$HOME_DIR/config/secondmate-harness" ;;
    esac
  fi
  cp "$HOME_DIR/config/session-launch-policy" "$CASE/refusal-policy-prior"
  assert_secondmate_auto_refusal first 1
  assert_secondmate_auto_refusal quiet 1
  ack_refusal_queue
  assert_secondmate_auto_refusal quiet 0
  if [ "$denied" = codex ]; then
    printf 'claude\n' > "$HOME_DIR/config/secondmate-harness"
    assert_secondmate_auto_refusal first 1
    assert_secondmate_auto_refusal quiet 1
    printf 'codex\n' > "$HOME_DIR/config/secondmate-harness"
    assert_secondmate_auto_refusal quiet 1
    ack_refusal_queue
    assert_secondmate_auto_refusal quiet 0
  elif [ "$denied" = legacy ]; then
    printf 'invalid\n' > "$CHILD_HOME/config/session-launch-policy"
    cp "$CHILD_HOME/config/session-launch-policy" "$CASE/child-policy-prior"
    assert_secondmate_auto_refusal first 1
    assert_secondmate_auto_refusal quiet 1
    rm "$CHILD_HOME/config/session-launch-policy" "$CASE/child-policy-prior"
    assert_secondmate_auto_refusal quiet 1
    ack_refusal_queue
    assert_secondmate_auto_refusal quiet 0
  fi
  printf 'changed-invalid\n' > "$HOME_DIR/config/session-launch-policy"
  assert_secondmate_auto_refusal first 1
  assert_secondmate_auto_refusal quiet 1
  cp "$CASE/refusal-policy-prior" "$HOME_DIR/config/session-launch-policy"
  assert_secondmate_auto_refusal quiet 1
  ack_refusal_queue
  assert_secondmate_auto_refusal quiet 0
  if [ -n "$generation_key" ]; then
    cp "$CASE/meta-generation-base" "$HOME_DIR/state/$ID.meta"
    printf '%s=policy-generation-2\n' "$generation_key" >> "$HOME_DIR/state/$ID.meta"
    cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-prior"
  else
    cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-replacement"
    mv "$CASE/meta-replacement" "$HOME_DIR/state/$ID.meta"
    cmp -s "$CASE/meta-prior" "$HOME_DIR/state/$ID.meta" || fail 'legacy replacement changed metadata contents'
  fi
  assert_secondmate_auto_refusal first 1
  assert_secondmate_auto_refusal quiet 1
  restrict
  printf 'omp\n' > "$HOME_DIR/config/secondmate-harness"
  out=$(run_secondmate_entry auto) || fail "policy repair did not allow immediate secondmate recovery: $out"
  [ "$(cat "$CASE/liveness-policy-refused")" = 0 ] || fail 'allowed secondmate launch retained the policy refusal flag'
  [ -z "$(cat "$CASE/liveness-wake")" ] || fail 'allowed secondmate launch retained a refusal wake'
  assert_secondmate_launched auto omp enabled
  [ "$(cat "$HOME_DIR/state/$ID.validation")" = 'validation custody' ] || fail 'secondmate recovery changed parent custody'
  pass "automatic $denied secondmate denial survives acknowledgement, deduplicates policy and generation, and repairs immediately"
done

assert_secondmate_watcher_refusal() {
  local wakes=$1 queued=$2 output
  # shellcheck disable=SC2016
  output=$(run_cli bash -c '
    set -eu
    . "$1/bin/fm-watch.sh"
    SECONDMATE_LIVENESS_SECS=0
    wake() { printf "%s\n" "$1" >> "$FM_POLICY_CASE/watcher-wakes"; }
    rc=0
    secondmate_liveness_tick || rc=$?
    printf "%s\n" "$FM_SM_LIVE_STATE" > "$FM_POLICY_CASE/liveness-state"
    printf "%s\n" "$FM_SM_LIVE_STATUS" > "$FM_POLICY_CASE/liveness-status"
    printf "%s\n" "$FM_SM_LIVE_POLICY_REFUSED" > "$FM_POLICY_CASE/liveness-policy-refused"
    printf "%s\n" "$FM_SM_LIVE_WAKE" > "$FM_POLICY_CASE/liveness-wake"
    exit "$rc"
  ' _ "$ROOT") || fail "watcher treated policy refusal as a recurring failure: $output"
  [ -z "$output" ] || fail "watcher emitted an error during policy refusal: $output"
  [ "$(awk 'END { print NR + 0 }' "$CASE/watcher-wakes")" = "$wakes" ] || fail 'watcher delivered a duplicate policy refusal'
  assert_contains "$(cat "$CASE/watcher-wakes")" 'session-launch-policy' 'watcher delivers the first actionable refusal'
  [ "$(cat "$CASE/liveness-policy-refused")" = 1 ] || fail 'watcher lost the policy refusal verdict'
  [ ! -e "$HOME_DIR/state/.secondmate-relaunch-bound-$ID" ] || fail 'watcher parked a policy-refused secondmate'
  assert_refusal_queue "$queued"
  assert_secondmate_refused auto
}

make_secondmate_case child-auto-watcher-denial omp auto
restrict
printf 'codex\n' > "$HOME_DIR/config/secondmate-harness"
printf 'spawn_gen=watcher-policy-generation\n' >> "$HOME_DIR/state/$ID.meta"
cp "$HOME_DIR/state/$ID.meta" "$CASE/meta-prior"
set_secondmate_endpoint auto omp
: > "$CASE/watcher-wakes"
assert_secondmate_watcher_refusal 1 1
assert_contains "$(cat "$CASE/liveness-wake")" 'session-launch-policy' 'first watcher denial exposes its wake'
assert_secondmate_watcher_refusal 1 1
[ -z "$(cat "$CASE/liveness-wake")" ] || fail 'repeated watcher denial exposed another wake'
ack_refusal_queue
assert_secondmate_watcher_refusal 1 0
[ -z "$(cat "$CASE/liveness-wake")" ] || fail 'acknowledged watcher denial exposed another wake'
pass 'real watcher policy refusal succeeds once, stays quiet across acknowledgement, and preserves recovery custody'

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
