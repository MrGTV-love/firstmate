#!/usr/bin/env bash
# tests/fm-remote-secondmate-relaunch.test.sh - regression coverage for
# bin/fm-remote-secondmate-relaunch.sh: the parent-side tool an operator runs
# to move a remote secondmate onto a new harness, model, or effort.
#
# Reproduces the observed defect: running
# bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness>
# <model> <effort> relaunches the agent on its host, but that host-local verb
# can only rewrite its own endpoint record. The parent's own state/<id>.meta
# kept naming the runtime the mate used to run. The wrapper drives the same
# host-local relaunch and then republishes this home's own record from the
# identity the host confirmed.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it, rather than exercising a real host.
set -u

TMPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TMPDIR

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
. "$ROOT/bin/fm-secondmate-nudge-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
unset FM_MODEL_CATALOG_DIR

TMP=$(TMPDIR="$ROOT" fm_test_tmproot fm-remote-secondmate-relaunch)
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"
DEST_HOME="$TMP/destination"
mkdir -p "$DEST_HOME/config" "$DEST_HOME/state" "$DEST_HOME/data" "$TMP/tmp" "$TMP/user-home"
export TMPDIR="$TMP/tmp"
NUDGE_MARKER="$HOME_DIR/state/.secondmate-nudge-pending/ios.pending"

printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/ios.meta" \
    "window=remote:ios" \
    "endpoint_task_id=ios" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=pi" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=openai-codex/gpt-5.6-sol" \
    "effort=medium" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(
  perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$4"
)
cmd=${args[0]}
action=${args[1]}
printf '%s %s\n' "$cmd" "$action" >> "$FM_FAKE_SSH_LOG"
if [ "$cmd" = fm-remote-doctor.sh ]; then
  [ "${#args[@]}" -eq 1 ] || exit 95
  exit 0
fi
if [ "$cmd" = fm-remote-inherit.sh ]; then
  [ -f "$FM_FAKE_SOURCE_HOME/state/.secondmate-nudge-pending/ios.pending" ] \
    || { printf 'inheritance reached SSH without reread intent\n' >&2; exit 96; }
  if [ "${FM_FAKE_RELAUNCH_MODE:-}" = partial-inherit ] \
    && [ "$action" = absent ] && [ "${args[2]}" = data/captain-shared.md ]; then
    printf 'error: fixture refused final inheritance item\n' >&2
    exit 1
  fi
  if [ "$action" = check ] && [ "${FM_FAKE_RELAUNCH_MODE:-}" = mutate-source ] \
    && [ ! -e "$FM_FAKE_SOURCE_HOME/mutated" ]; then
    cp "$FM_FAKE_LATER/model-index.json" "$FM_FAKE_SOURCE_HOME/config/model-index.json"
    cp "$FM_FAKE_LATER/crew-dispatch.json" "$FM_FAKE_SOURCE_HOME/config/crew-dispatch.json"
    printf 'mutated\n' > "$FM_FAKE_SOURCE_HOME/mutated"
  fi
  FM_HOME="$FM_FAKE_DEST_HOME" FM_STATE_OVERRIDE="$FM_FAKE_DEST_HOME/state" \
    exec "$FM_FAKE_ROOT/bin/fm-remote-inherit.sh" "${args[@]:1}"
fi
id=${args[2]}
case "$action" in
  state)
    [ "$(cat "$FM_FAKE_SOURCE_HOME/../native/command")" = pi ] || exit 97
    printf 'alive\n'
    exit 0
    ;;
  sync)
    head=$(git -C "$FM_FAKE_DEST_HOME" rev-parse HEAD) || exit 99
    [ "${args[3]}" = "$head" ] || exit 99
    printf 'current: %s\n' "$head"
    exit 0
    ;;
  route)
    printf 'backend=herdr\n'
    exit 0
    ;;
  send)
    printf '%s\n' "$id" >> "$FM_FAKE_SOURCE_HOME/../send-targets"
    if [ "${FM_FAKE_RELAUNCH_MODE:-}" = send-fail ]; then
      printf 'error: fixture inbox write refused\n' >&2
      exit 1
    fi
    [ "$(cat "$FM_FAKE_SOURCE_HOME/../native/command")" = pi ] || exit 98
    printf '%s\n' "${args[3]}" >> "$FM_FAKE_SOURCE_HOME/../notifications"
    exit 0
    ;;
esac
harness=${args[3]}
model=${args[4]}
effort=${args[5]}
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$action" = relaunch ] || exit 94
if [ "${FM_FAKE_RELAUNCH_MODE:-}" = native ] \
  || [ "${FM_FAKE_RELAUNCH_MODE:-}" = mutate-source ]; then
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_ROOT_OVERRIDE="$FM_FAKE_SOURCE_HOME/../control-root" \
    FM_HOME="$FM_FAKE_SOURCE_HOME/../control-root" \
    FM_CONFIG_OVERRIDE="$FM_FAKE_DEST_HOME/config" \
    FM_STATE_OVERRIDE="$FM_FAKE_DEST_HOME/state/parent-route" \
    FM_DATA_OVERRIDE="$FM_FAKE_DEST_HOME/data/.parent-route" \
    FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=1 FM_CONTROL_LAUNCH_WAIT=1 \
    "$FM_FAKE_ROOT/bin/fm-control.sh" "$id" relaunch \
    --harness "$harness" --model "$model" --effort "$effort" || exit $?
  while IFS='=' read -r key value; do
    case "$key" in
      harness) harness=$value ;;
      model) model=$value ;;
      effort) effort=$value ;;
    esac
  done < "$FM_FAKE_DEST_HOME/state/parent-route/$id.meta"
fi
case "$FM_FAKE_RELAUNCH_MODE" in
  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
esac
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
if [ "${FM_FAKE_RELAUNCH_MODE:-}" != missing-schema ]; then
  printf 'schema=fm-remote-secondmate-control.v1\n'
fi
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
if [ "${FM_FAKE_RELAUNCH_MODE:-}" != missing-harness ]; then
  printf 'harness=%s\n' "$harness"
fi
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
SH
chmod +x "$FAKEBIN/fake-ssh"

fixture_env() {
  env -i PATH="$FAKEBIN:$PATH" HOME="$TMP/user-home" TMPDIR="$TMP/tmp" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    FM_GATE_REFUSE_BYPASS=1 FM_TEST_SEAM=1 \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_SEND_SETTLE=0 \
    FM_INHERITABLE_CONFIG='model-index.json crew-dispatch.json crew-harness' \
    FM_PROCEVENT_CLAIM_ROOT="$TMP/claims" \
    FM_FAKE_ROOT="$ROOT" FM_FAKE_SOURCE_HOME="$HOME_DIR" \
    FM_FAKE_DEST_HOME="$DEST_HOME" FM_FAKE_SSH_LOG="$TMP/ssh.log" \
    FM_FAKE_LATER="$TMP/later" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" "$@" 2>&1
}

run_relaunch() {
  fixture_env "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@"
}

run_bootstrap() {
  fixture_env FM_ROOT_OVERRIDE="$TMP/primary" \
    FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=0 \
    FM_BOOTSTRAP_VERBOSE_FACTS=1 "$ROOT/bin/fm-bootstrap.sh"
}

seed_remote_marker() {
  fm_secondmate_nudge_write "$HOME_DIR/state" ios /srv/fm-home "" remote \
    "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1 || fail "could not seed the remote reread marker"
}

assert_remote_marker() {
  assert_present "$NUDGE_MARKER" "unconfirmed replacement lost remote reread intent"
  assert_grep 'id=ios' "$NUDGE_MARKER" "reread marker lost its task identity"
  assert_grep 'selector=fm-ios' "$NUDGE_MARKER" "reread marker lost its selector"
  assert_grep 'home=/srv/fm-home' "$NUDGE_MARKER" "reread marker changed the remote home"
  assert_grep 'remote=1' "$NUDGE_MARKER" "reread marker lost its remote placement"
  assert_grep "message=$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" "$NUDGE_MARKER" \
    "reread marker did not retain the inherited-config message"
}

# --- a successful relaunch republishes the parent's own route record --------
reset_meta
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_contains "$OUT" "relaunched ios harness=claude" \
  "the wrapper should still print the host's own confirmation line"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed model"
assert_grep 'effort=medium' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed effort"
assert_no_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the stale runtime should not still be recorded"
assert_no_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the stale model should not still be recorded"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive the update"
assert_grep 'window=remote:ios' "$HOME_DIR/state/ios.meta" \
  "unrelated identity fields must survive the update"
pass "a successful remote relaunch republishes the parent's harness, model, and effort"

# --- the parent records what the host confirmed, not what it was asked ------
reset_meta
FM_FAKE_RELAUNCH_MODE=confirm-other
OUT=$(run_relaunch ios default default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 0 "$RC" "a relaunch whose host resolves a different identity should succeed"$'\n'"$OUT"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed model"
assert_no_grep 'harness=default' "$HOME_DIR/state/ios.meta" \
  "the parent record must not keep the unresolved request"
pass "a remote relaunch records the identity the host confirmed"

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
pass "a refused remote relaunch leaves the parent's record untouched"

# --- a local (non-remote) secondmate is refused, not silently mishandled ----
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" \
  "worktree=/srv/local1" "project=/srv/local1" "harness=codex" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_relaunch local1 claude - -); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate must not be accepted by the remote relaunch tool"
assert_contains "$OUT" "not a remotely placed secondmate" \
  "the refusal should explain the tool this task needs instead"
pass "a local secondmate is refused by the remote relaunch tool"

# --- a relaunch keeps an already-armed PR poll authenticating ---------------
# fm-pr-check.sh now refuses to arm a poll on a kind=secondmate record, but a
# record armed before that refusal can still carry the block until the
# watcher retires it. fm-pr-check.sh wrote pr= (and, when a forge head was
# readable, pr_head=) as the LAST lines of the record, and
# fm_pr_metadata_identity_parse treats any other key appearing after pr= as
# invalid, so this wrapper must not append its harness=/model=/effort= lines
# after that identity block. The fixture is seeded the way such a record was
# really written: pr= appended last to the meta, then the poll artifacts
# published through the same fm_pr_poll_prepare/fm_pr_poll_publish_prepared
# pair fm-pr-check.sh uses, since the refused entry point cannot arm it.
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/ios.meta" \
  || fail "could not write the pr= identity for the relaunch-ordering test"
fm_pr_poll_prepare "$HOME_DIR/state" ios github \
  https://github.com/example/repo/pull/1 github.com example/repo 1 \
  "$ROOT/bin/fm-pr-poll.sh" \
  || fail "could not prepare the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_publish_prepared \
  || fail "could not publish the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "PR poll fixture did not authenticate before the relaunch"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed with an armed PR poll"$'\n'"$OUT"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "a remote relaunch broke PR poll authentication by writing harness/model/effort after pr="
pass "a remote relaunch keeps an already-armed PR poll authenticating"

mkdir -p "$TMP/native" "$TMP/old" "$TMP/new" "$TMP/later" "$TMP/control-root/state" \
  "$DEST_HOME/state/parent-route" "$DEST_HOME/data/.parent-route" "$DEST_HOME/worker-account" "$DEST_HOME/bin"
ln -s "$ROOT/bin" "$TMP/control-root/bin"
printf '%s\n' '{"version":1,"roles":{"restart":{"pi":{"model":"openai/old","stand_in":"openai/old-standby"}}},"retired":[]}' \
  > "$TMP/old/model-index.json"
printf '%s\n' '{"version":1,"roles":{"restart":{"pi":{"model":"openai/new","stand_in":"openai/new-standby"}}},"retired":[]}' \
  > "$TMP/new/model-index.json"
printf '%s\n' '{"version":1,"roles":{"later":{"pi":{"model":"openai/later"}}},"retired":[]}' \
  > "$TMP/later/model-index.json"
printf '%s\n' '{"default":{"harness":"pi","role":"restart"}}' > "$TMP/old/crew-dispatch.json"
cp "$TMP/old/crew-dispatch.json" "$TMP/new/crew-dispatch.json"
printf '%s\n' '{"default":{"harness":"pi","role":"later"}}' > "$TMP/later/crew-dispatch.json"
printf '%s\n' "$DEST_HOME/worker-account" openai > "$DEST_HOME/config/pi-account"
cp "$DEST_HOME/config/pi-account" "$TMP/pi-account-before"
printf 'tmux\n' > "$DEST_HOME/config/backend"
cp "$ROOT"/bin/fm-remote-*.sh "$DEST_HOME/bin/"
printf 'ios\n' > "$DEST_HOME/.fm-secondmate-home"
printf 'fixture instructions\n' > "$DEST_HOME/AGENTS.md"
printf 'fixture charter\n' > "$DEST_HOME/data/charter.md"
git -C "$DEST_HOME" init -q -b main
git -C "$DEST_HOME" add AGENTS.md bin
git -C "$DEST_HOME" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git clone -q "$DEST_HOME" "$TMP/primary"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ]
SH
chmod +x "$FAKEBIN/gh"
cat > "$FAKEBIN/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = check ]; then
  printf '{"status":"ready"}\n'
  exit
fi
if [ "${1:-}" = --list-models ]; then
  printf '%s\n' "${PI_CODING_AGENT_DIR:-unset}" >> "$FM_FAKE_SOURCE_HOME/native-catalog.log"
  printf 'provider model context output reasoning images\n'
  cat "${PI_CODING_AGENT_DIR:?}/listed"
  exit
fi
printf 'Options: --tui-mode\n'
SH
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D="$FM_FAKE_SOURCE_HOME/../native"
printf '%s\n' "$*" >> "$D/runtime.log"
case "${1:-}" in
  list-windows) printf 'fm-ios\n' ;;
  display-message)
    case "$*" in
      *pane_current_command*) cat "$D/command" ;;
      *pane_current_path*) printf '%s\n' "$FM_FAKE_DEST_HOME" ;;
      *cursor_y*) printf '1\n' ;;
      *pane_tty*) exit 0 ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  show-environment) exit 1 ;;
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
    [ "$literal" = 1 ] || exit 0
    payload=${1:-}
    case "$payload" in
      ". '"*"'")
        staged=${payload#". '"}
        staged=${staged%"'"}
        [ ! -f "$staged" ] || payload=$(cat "$staged")
        ;;
    esac
    printf '%s\n' "$payload" >> "$D/literal"
    case "$payload" in
      /exit|/quit) printf zsh > "$D/command" ;;
      *'encode launch-brief'*|*'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launch"
        printf pi > "$D/command"
        ;;
    esac
    ;;
esac
SH
chmod +x "$FAKEBIN/pi" "$FAKEBIN/tmux"

reset_native() {
  reset_meta
  rm -f "$NUDGE_MARKER" "$HOME_DIR/state/local1.meta" \
    "$HOME_DIR/config/crew-harness" "$DEST_HOME/config/crew-harness"
  cp "$TMP/new/model-index.json" "$HOME_DIR/config/model-index.json"
  cp "$TMP/new/crew-dispatch.json" "$HOME_DIR/config/crew-dispatch.json"
  cp "$TMP/old/model-index.json" "$DEST_HOME/config/model-index.json"
  cp "$TMP/old/crew-dispatch.json" "$DEST_HOME/config/crew-dispatch.json"
  fm_write_meta "$DEST_HOME/state/parent-route/ios.meta" \
    "window=fmses:fm-ios" "endpoint_task_id=ios" \
    "worktree=$DEST_HOME" "project=$DEST_HOME" "home=$DEST_HOME" \
    "harness=pi" "kind=secondmate" "mode=secondmate" "yolo=off" \
    "model=openai/old" "effort=medium" "tasktmp=$TMP/tasktmp" "projects="
  printf pi > "$TMP/native/command"
  : > "$TMP/native/literal"
  : > "$TMP/native/runtime.log"
  : > "$TMP/ssh.log"
  : > "$TMP/notifications"
  : > "$TMP/send-targets"
  : > "$HOME_DIR/native-catalog.log"
  rm -f "$TMP/native/launch" "$HOME_DIR/mutated"
  rm -f "$DEST_HOME/state/parent-route/ios.control-relaunch"*
  printf 'openai old 128K 32K yes no\n' > "$DEST_HOME/worker-account/listed"
  cp "$HOME_DIR/state/ios.meta" "$TMP/parent-before"
  cp "$DEST_HOME/state/parent-route/ios.meta" "$TMP/destination-before"
  FM_FAKE_RELAUNCH_MODE=native
}

assert_survivor_reread() {
  local retry=${1:-} member out rc records head attempts
  head=$(git -C "$DEST_HOME" rev-parse HEAD)
  [ "$head" = "$(git -C "$TMP/primary" rev-parse HEAD)" ] \
    || fail "bootstrap fixture is not already at the primary tracked-file commit"
  cp "$DEST_HOME/AGENTS.md" "$TMP/agents-before-bootstrap"
  cp "$HOME_DIR/state/ios.meta" "$TMP/route-before-bootstrap"
  cp "$DEST_HOME/state/parent-route/ios.meta" "$TMP/worker-before-bootstrap"
  cp "$TMP/native/literal" "$TMP/literal-before-bootstrap"
  for member in model-index.json crew-dispatch.json; do
    cmp -s "$HOME_DIR/config/$member" "$DEST_HOME/config/$member" \
      || fail "bootstrap retry precondition: routing pair is not already inherited"
    cp "$DEST_HOME/config/$member" "$TMP/bootstrap-$member"
  done
  if [ -f "$HOME_DIR/config/crew-harness" ]; then
    cmp -s "$HOME_DIR/config/crew-harness" "$DEST_HOME/config/crew-harness" \
      || fail "bootstrap retry precondition: unrelated config is not already inherited"
  else
    assert_absent "$DEST_HOME/config/crew-harness" "bootstrap retry precondition: unexpected unrelated config"
  fi
  records=$(wc -l < "$TMP/notifications" | tr -d ' ')
  if [ "$retry" = retry-send ]; then
    attempts=$(wc -l < "$TMP/send-targets" | tr -d ' ')
    out=$(FM_FAKE_RELAUNCH_MODE=send-fail run_bootstrap); rc=$?
    expect_code 0 "$rc" "bootstrap should report a failed reread diagnostically: $out"
    [ "$(wc -l < "$TMP/send-targets" | tr -d ' ')" -eq "$((attempts + 1))" ] \
      || fail "bootstrap did not attempt the failed remote send"
    [ "$(wc -l < "$TMP/notifications" | tr -d ' ')" -eq "$records" ] \
      || fail "a refused send was recorded as delivered"
    assert_remote_marker
  fi
  out=$(FM_FAKE_RELAUNCH_MODE='' run_bootstrap); rc=$?
  expect_code 0 "$rc" "bootstrap should deliver pending intent without further config changes: $out"
  assert_contains "$out" 'nudged remote fm-ios after convergence' \
    "bootstrap did not report delivery of the retained reread intent"
  [ "$(wc -l < "$TMP/notifications" | tr -d ' ')" -eq "$((records + 1))" ] \
    || fail "unchanged bootstrap did not notify the surviving worker exactly once"
  assert_grep "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" "$TMP/notifications" \
    "bootstrap delivered a different instruction instead of the remote config reread"
  [ "$(sort -u "$TMP/send-targets")" = ios ] || fail "bootstrap did not target only the surviving secondmate"
  assert_absent "$NUDGE_MARKER" "successful bootstrap delivery retained the remote marker"
  if [ "$retry" = retry-send ]; then
    out=$(FM_FAKE_RELAUNCH_MODE='' run_bootstrap); rc=$?
    expect_code 0 "$rc" "already-delivered bootstrap should remain successful: $out"
    [ "$(wc -l < "$TMP/notifications" | tr -d ' ')" -eq "$((records + 1))" ] \
      || fail "a cleared marker caused a redundant unchanged reread"
  fi
  [ "$(git -C "$DEST_HOME" rev-parse HEAD)" = "$head" ] \
    || fail "bootstrap retry changed the tracked-file commit"
  cmp -s "$TMP/agents-before-bootstrap" "$DEST_HOME/AGENTS.md" \
    || fail "bootstrap retry changed tracked instructions"
  cmp -s "$TMP/route-before-bootstrap" "$HOME_DIR/state/ios.meta" \
    || fail "bootstrap retry changed parent routing"
  cmp -s "$TMP/worker-before-bootstrap" "$DEST_HOME/state/parent-route/ios.meta" \
    || fail "bootstrap retry changed survivor metadata"
  cmp -s "$TMP/literal-before-bootstrap" "$TMP/native/literal" \
    || fail "bootstrap retry stopped or respawned the surviving worker"
  [ "$(cat "$TMP/native/command")" = pi ] || fail "bootstrap did not preserve the surviving worker"
  for member in model-index.json crew-dispatch.json; do
    cmp -s "$TMP/bootstrap-$member" "$DEST_HOME/config/$member" \
      || fail "bootstrap retry changed the already-inherited routing pair"
  done
  if [ -f "$HOME_DIR/config/crew-harness" ]; then
    cmp -s "$HOME_DIR/config/crew-harness" "$DEST_HOME/config/crew-harness" \
      || fail "bootstrap retry changed unrelated inherited config"
  fi
}

assert_native_untouched() {
  cmp -s "$TMP/parent-before" "$HOME_DIR/state/ios.meta" \
    || fail "refusal changed the parent route"
  cmp -s "$TMP/destination-before" "$DEST_HOME/state/parent-route/ios.meta" \
    || fail "refusal changed the running mate's metadata"
  [ "$(cat "$TMP/native/command")" = pi ] || fail "refusal stopped the running mate"
  [ ! -s "$TMP/native/literal" ] || fail "refusal sent lifecycle input to the running mate"
  [ ! -e "$DEST_HOME/state/parent-route/ios.control-relaunch" ] \
    || fail "refusal reached checkpoint publication"
  cmp -s "$TMP/pi-account-before" "$DEST_HOME/config/pi-account" \
    || fail "inheritance rewrote the destination account"
}

for REQUEST in role:restart stand-in:restart openai/new; do
  reset_native
  assert_absent "$NUDGE_MARKER" "catalog refusal fixture unexpectedly has pending intent"
  OUT=$(run_relaunch ios pi "$REQUEST" medium); RC=$?
  [ "$RC" -ne 0 ] || fail "catalog missing the new indexed selector accepted $REQUEST: $OUT"
  SELECTED=openai/new
  [ "$REQUEST" != stand-in:restart ] || SELECTED=openai/new-standby
  assert_contains "$OUT" "id '$SELECTED' absent or retired in pi catalog" \
    "the real destination pre-stop gate must reject the newly inherited entry"
  assert_grep "$DEST_HOME/worker-account" "$HOME_DIR/native-catalog.log" \
    "the real catalog lookup did not use the destination worker account"
  assert_native_untouched
  for MEMBER in model-index.json crew-dispatch.json; do
    cmp -s "$TMP/new/$MEMBER" "$DEST_HOME/config/$MEMBER" \
      || fail "the pre-stop gate did not see the selected parent pair"
  done
  assert_remote_marker
  if [ "$REQUEST" = role:restart ]; then
    assert_survivor_reread retry-send
  else
    assert_survivor_reread
  fi
done
pass "catalog refusals retain reread intent and unchanged bootstrap notifies the survivor, retrying failed delivery"

reset_native
seed_remote_marker
cp "$NUDGE_MARKER" "$TMP/existing-marker"
OUT=$(run_relaunch ios pi role:restart medium); RC=$?
[ "$RC" -ne 0 ] || fail "a preexisting marker made an unsupported restart acceptable: $OUT"
assert_contains "$OUT" "id 'openai/new' absent or retired in pi catalog" \
  "preexisting intent bypassed the real catalog refusal"
assert_native_untouched
assert_remote_marker
cmp -s "$TMP/existing-marker" "$NUDGE_MARKER" \
  || fail "catalog refusal changed the existing remote reread intent"
assert_survivor_reread
pass "a preexisting remote reread marker survives catalog refusal until bootstrap delivers it"

reset_native
assert_absent "$NUDGE_MARKER" "partial-transfer fixture unexpectedly has pending intent"
printf 'pi\n' > "$HOME_DIR/config/crew-harness"
printf 'codex\n' > "$DEST_HOME/config/crew-harness"
FM_FAKE_RELAUNCH_MODE=partial-inherit
OUT=$(run_relaunch ios pi role:restart medium); RC=$?
[ "$RC" -ne 0 ] || fail "partial remote inheritance unexpectedly succeeded: $OUT"
assert_contains "$OUT" 'fixture refused final inheritance item' \
  "partial inheritance did not reach the final failing boundary"
assert_contains "$OUT" 'remote inheritance refused' \
  "partial inheritance lost its relaunch refusal diagnostic"
assert_contains "$OUT" 'pushed: config/crew-harness' \
  "partial inheritance failed before its unrelated write"
cmp -s "$HOME_DIR/config/crew-harness" "$DEST_HOME/config/crew-harness" \
  || fail "partial inheritance did not publish the unrelated config"
for MEMBER in model-index.json crew-dispatch.json; do
  cmp -s "$TMP/new/$MEMBER" "$DEST_HOME/config/$MEMBER" \
    || fail "partial inheritance did not publish its routing pair"
done
assert_no_grep 'fm-remote-secondmate-control.sh relaunch' "$TMP/ssh.log" \
  "partial inheritance failure reached the remote relaunch"
assert_native_untouched
assert_remote_marker
assert_survivor_reread
pass "partial inheritance retains intent after unrelated writes and unchanged bootstrap notifies the survivor"

for CONFIRMATION in missing-schema missing-harness; do
  reset_native
  assert_absent "$NUDGE_MARKER" "missing-confirmation fixture unexpectedly has pending intent"
  FM_FAKE_RELAUNCH_MODE=$CONFIRMATION
  OUT=$(run_relaunch ios pi role:restart medium); RC=$?
  [ "$RC" -ne 0 ] || fail "an incomplete host confirmation was accepted: $OUT"
  case "$CONFIRMATION" in
    missing-schema)
      assert_contains "$OUT" 'reported no route confirmation to record' \
        "missing route schema bypassed the wrapper's confirmation gate"
      ;;
    missing-harness)
      assert_contains "$OUT" 'route confirmation carried no harness to record' \
        "missing confirmed harness bypassed the wrapper's identity gate"
      ;;
  esac
  assert_grep 'fm-remote-secondmate-control.sh relaunch' "$TMP/ssh.log" \
    "the incomplete confirmation fixture did not reach the relaunch boundary"
  assert_native_untouched
  assert_remote_marker
  for MEMBER in model-index.json crew-dispatch.json; do
    cmp -s "$TMP/new/$MEMBER" "$DEST_HOME/config/$MEMBER" \
      || fail "unconfirmed relaunch did not deliver the routing pair"
  done
  assert_survivor_reread
done
pass "missing route schema and missing harness confirmation both retain intent for unchanged bootstrap delivery"

reset_native
rmdir "$HOME_DIR/state/.secondmate-nudge-pending" \
  || fail "marker-publication refusal fixture did not start with an empty marker directory"
mkdir "$TMP/blocked-marker-target"
printf 'retained\n' > "$TMP/blocked-marker-target/sentinel"
ln -s "$TMP/blocked-marker-target" "$HOME_DIR/state/.secondmate-nudge-pending"
OUT=$(run_relaunch ios pi role:restart medium); RC=$?
[ "$RC" -ne 0 ] || fail "unsafe marker publication unexpectedly permitted remote transfer: $OUT"
assert_contains "$OUT" 'cannot record the remote reread marker' \
  "marker publication refusal lost its diagnostic"
[ ! -s "$TMP/ssh.log" ] || fail "marker publication refusal reached a remote command"
assert_native_untouched
for MEMBER in model-index.json crew-dispatch.json; do
  cmp -s "$TMP/old/$MEMBER" "$DEST_HOME/config/$MEMBER" \
    || fail "marker publication refusal changed destination routing"
done
[ "$(cat "$TMP/blocked-marker-target/sentinel")" = retained ] \
  || fail "marker publication wrote through its guarded directory"
assert_absent "$TMP/blocked-marker-target/ios.pending" \
  "marker publication wrote through its directory symlink"
rm "$HOME_DIR/state/.secondmate-nudge-pending"
mkdir "$HOME_DIR/state/.secondmate-nudge-pending"
pass "refused marker publication prevents inheritance and remote relaunch"

for REQUEST in role:restart stand-in:restart openai/new; do
  reset_native
  seed_remote_marker
  printf 'openai new 128K 32K yes no\nopenai new-standby 128K 32K yes no\n' \
    > "$DEST_HOME/worker-account/listed"
  OUT=$(run_relaunch ios pi "$REQUEST" medium); RC=$?
  expect_code 0 "$RC" "a destination supporting the selected parent entry must relaunch: $OUT"
  SELECTED=openai/new
  [ "$REQUEST" != stand-in:restart ] || SELECTED=openai/new-standby
  assert_grep "model=$SELECTED" "$HOME_DIR/state/ios.meta" \
    "the parent did not record the selected entry"
  assert_grep "model=$SELECTED" "$DEST_HOME/state/parent-route/ios.meta" \
    "the real spawn did not record the selected entry"
  assert_contains "$(cat "$TMP/native/launch")" "$SELECTED" \
    "the replacement launch did not consume the selected entry"
  assert_not_contains "$(cat "$TMP/native/launch")" 'role:restart' \
    "an unresolved role reached the worker"
  assert_grep 'phase=complete' "$DEST_HOME/state/parent-route/ios.control-relaunch" \
    "real control did not finish its relaunch transaction"
  while IFS= read -r ACCOUNT; do
    [ "$ACCOUNT" = "$DEST_HOME/worker-account" ] \
      || fail "restart queried a catalog outside the destination account"
  done < "$HOME_DIR/native-catalog.log"
  for MEMBER in model-index.json crew-dispatch.json; do
    cmp -s "$TMP/new/$MEMBER" "$DEST_HOME/config/$MEMBER" \
      || fail "the supported restart did not deliver the selected pair"
  done
  cmp -s "$TMP/pi-account-before" "$DEST_HOME/config/pi-account" \
    || fail "the supported restart changed the destination account"
  assert_absent "$NUDGE_MARKER" "confirmed replacement retained obsolete reread intent"
  [ ! -s "$TMP/notifications" ] || fail "confirmed replacement unnecessarily nudged the prior worker"
done
pass "supported destination catalogs relaunch roles, stand-ins, and indexed literals through real control and spawn"

for MEMBER in model-index.json crew-dispatch.json; do
  reset_native
  mv "$DEST_HOME/config/$MEMBER" "$DEST_HOME/retained-$MEMBER"
  ln -s "$DEST_HOME/retained-$MEMBER" "$DEST_HOME/config/$MEMBER"
  OUT=$(run_relaunch ios pi role:restart medium); RC=$?
  [ "$RC" -ne 0 ] || fail "unsafe destination pair member was accepted: $OUT"
  assert_contains "$OUT" 'remote inheritance refused' \
    "the wrapper must report pair propagation refusal"
  assert_no_grep 'fm-remote-secondmate-control.sh relaunch' "$TMP/ssh.log" \
    "a pair preflight refusal reached remote relaunch"
  assert_native_untouched
  assert_remote_marker
  [ -L "$DEST_HOME/config/$MEMBER" ] || fail "pair preflight replaced the guarded member"
  for RETAINED in model-index.json crew-dispatch.json; do
    cmp -s "$TMP/old/$RETAINED" "$DEST_HOME/config/$RETAINED" \
      || fail "pair preflight changed the retained destination pair"
  done
  [ "$(fixture_env FM_HOME="$DEST_HOME" FM_CONFIG_OVERRIDE="$DEST_HOME/config" \
    FM_STATE_OVERRIDE="$DEST_HOME/state" "$ROOT/bin/fm-model-index.sh" profiles \
    "$DEST_HOME/config/crew-dispatch.json" | jq -r '.default.model')" = openai/old ] \
    || fail "pair preflight left a retained pair that no longer resolves"
  rm "$DEST_HOME/config/$MEMBER"
  mv "$DEST_HOME/retained-$MEMBER" "$DEST_HOME/config/$MEMBER"
done
pass "destination pair preflight refusal preserves both retained members, the working mate, and the parent route"

reset_native
printf 'openai new 128K 32K yes no\nopenai new-standby 128K 32K yes no\n' \
  > "$DEST_HOME/worker-account/listed"
FM_FAKE_RELAUNCH_MODE=mutate-source
OUT=$(run_relaunch ios pi role:restart medium); RC=$?
expect_code 0 "$RC" "source mutation after staging must not change the restart selection: $OUT"
[ -s "$HOME_DIR/mutated" ] || fail "the after-stage mutation hook did not execute"
for MEMBER in model-index.json crew-dispatch.json; do
  cmp -s "$TMP/later/$MEMBER" "$HOME_DIR/config/$MEMBER" \
    || fail "the source mutation fixture did not change $MEMBER"
  cmp -s "$TMP/new/$MEMBER" "$DEST_HOME/config/$MEMBER" \
    || fail "the sender delivered the later source instead of its frozen pair"
done
[ "$(fixture_env FM_HOME="$DEST_HOME" FM_CONFIG_OVERRIDE="$DEST_HOME/config" \
  FM_STATE_OVERRIDE="$DEST_HOME/state" "$ROOT/bin/fm-model-index.sh" profiles \
  "$DEST_HOME/config/crew-dispatch.json" | jq -r '.default.model')" = openai/new ] \
  || fail "the delivered frozen pair does not resolve the staged model"
assert_grep 'model=openai/new' "$HOME_DIR/state/ios.meta" \
  "the parent recorded a model from the mutated source"
assert_grep 'model=openai/new' "$DEST_HOME/state/parent-route/ios.meta" \
  "the replacement spawn used a model from the mutated source"
assert_contains "$(cat "$TMP/native/launch")" 'openai/new' \
  "the replacement launch did not consume the frozen selection"
assert_not_contains "$(cat "$TMP/native/launch")" 'openai/later' \
  "the replacement launch consumed the later selection"
assert_absent "$NUDGE_MARKER" "confirmed frozen-pair replacement retained remote reread intent"
pass "after-stage source mutation leaves resolution, inheritance, destination validation, and spawn on the frozen pair"

echo "ALL TESTS PASSED"
