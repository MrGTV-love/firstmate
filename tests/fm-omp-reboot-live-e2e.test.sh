#!/usr/bin/env bash
# Real omp bare-native-resume recovery in a named Herdr lab. Submits short task
# and secondmate readiness prompts, so opt in with FM_OMP_REBOOT_LIVE=1 (or FM_LIVE=1).
# Proves the pending-input refusal, normal relaunch, exact profile and endpoint
# preservation, dirty-work preservation, managed proof, and idempotent rescan.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OMP_REBOOT_LIVE herdr omp jq python3
HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HELPER" name omp-reboot)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-reboot.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
TASK_ID="reboot-${TMP##*/}"
REAL_PATH=$PATH
OWNED_TASK_TMP=
OWNED_LAUNCH_DIR=
OWNED_SESSION=0
cleanup() {
  local status=$?
  if [ "$OWNED_SESSION" = 1 ] && ! PATH="$REAL_PATH" "$HELPER" teardown "$SESSION"; then
    printf "guarded teardown failed for session '%s'; retained resources for manual cleanup:\n  private tree: %s\n  task namespace: %s\n  launch namespace: %s\n" \
      "$SESSION" "$TMP" "${OWNED_TASK_TMP:-not claimed}" "${OWNED_LAUNCH_DIR:-not claimed}" >&2
    exit 1
  fi
  if [ -n "$OWNED_TASK_TMP" ]; then
    rm -rf -- "$OWNED_TASK_TMP" || status=1
  fi
  if [ -n "$OWNED_LAUNCH_DIR" ]; then
    rm -rf -- "$OWNED_LAUNCH_DIR" || status=1
  fi
  chmod -R u+w "$TMP" || status=1
  rm -rf "$TMP" || status=1
  exit "$status"
}
trap cleanup EXIT
export FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data"
export FM_CONFIG_OVERRIDE="$FM_HOME/config" FM_PROJECTS_OVERRIDE="$FM_HOME/projects"
export FM_SPAWN_NO_GUARD=1
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN
"$HELPER" prepare "$SESSION"
OWNED_SESSION=1
mkdir -p "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE/$TASK_ID" "$FM_CONFIG_OVERRIDE" \
  "$FM_PROJECTS_OVERRIDE" "$TMP/fakebin"
HOME_ROOT=$(cd "$FM_HOME" && pwd -P)
HOME_HASH=$(printf '%s' "$HOME_ROOT" | shasum -a 256)
HOME_HASH=${HOME_HASH%% *}
TASK_TMP="/tmp/fm-$TASK_ID"
if (umask 077 && mkdir "$TASK_TMP") 2>/dev/null; then
  OWNED_TASK_TMP=$TASK_TMP
else
  fail "refusing preexisting or unavailable task temp namespace $TASK_TMP"
fi
LAUNCH_DIR="/tmp/fm-$TASK_ID+$HOME_HASH"
if (umask 077 && mkdir "$LAUNCH_DIR") 2>/dev/null; then
  OWNED_LAUNCH_DIR=$LAUNCH_DIR
else
  fail "refusing preexisting or unavailable launch namespace $LAUNCH_DIR"
fi
META="$FM_STATE_OVERRIDE/$TASK_ID.meta"
"$HELPER" provision "$SESSION"
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }
assert_live_profile() {
  run pane process-info --pane "$PANE" | jq -e --arg cwd "$WT" \
    --arg config "$ROOT/.omp/fm-worker-overlay.yml" '
    .result.process_info.foreground_processes
    | map(select(.argv | index("--model") != null)) | select(length == 1) | .[0]
    | select(.cwd == $cwd)
    | .argv
    | select(index("--auto-approve") != null
        and .[index("--config") + 1] == $config
        and .[index("--model") + 1] == "openai-codex/gpt-6.1-sol"
        and .[index("--thinking") + 1] == "low")
    | true' >/dev/null || fail 'actual omp runtime lost cwd, managed config, approval posture or profile'
}
# Herdr's foreground view and the kernel ancestry snapshot are asynchronous;
# a helper exiting between reads may yield unknown. Never retry a positively
# unmanaged replacement, which is evidence of a broken launch boundary.
await_managed() {
  local verdict
  for _ in $(seq 1 30); do
    verdict=$(fm_launch_proof_herdr "$META")
    case "$verdict" in
      managed) return 0 ;;
      unmanaged) fail 'replacement has a readable but mismatched launch incarnation' ;;
    esac
    sleep 0.2
  done
  fail 'replacement foreground ancestry remained unreadable'
}
printf 'manual\n' > "$FM_CONFIG_OVERRIDE/backlog-backend"
printf 'off\n' > "$FM_CONFIG_OVERRIDE/herdr-presentation-spaces"
fm_git_worktree "$TMP/proj" "$TMP/wt" "$TASK_ID"
WT=$(cd "$TMP/wt" && pwd -P)
printf 'preserve this dirty file\n' > "$WT/unlanded.txt"
BEFORE=$(git -C "$WT" rev-parse HEAD)
BRANCH=$(git -C "$WT" symbolic-ref HEAD)
HASH=$(shasum -a 256 "$WT/unlanded.txt")
cat > "$FM_DATA_OVERRIDE/$TASK_ID/brief.md" <<'EOF'
# Task
## Captain's intent
This is an isolated lifecycle verification, not a project implementation.
Reply only 'Recovery lab ready.' then wait without further work.

## Firstmate spec
Do not inspect or modify files, delegate, supervise, or run any tools.
EOF
WS=$(run workspace create --cwd "$WT" --label "fm-$TASK_ID" | jq -r '.result.workspace.workspace_id')
PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
cat > "$META" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$TASK_ID
worktree=$WT
project=$TMP/proj
harness=omp
kind=ship
mode=no-mistakes
yolo=off
model=openai-codex/gpt-6.1-sol
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
# Every command issued by production adapters is also forced through the lab
# helper. The real binary remains on the helper's original PATH, avoiding a
# recursive wrapper while rejecting any attempt to leave this named session.
export FM_LAB_REAL_PATH="$PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION"
cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || exit 91; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}"
SH
chmod +x "$TMP/fakebin/herdr"
export PATH="$TMP/fakebin:$PATH"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
. "$ROOT/bin/fm-launch-proof-lib.sh"
# A real empty session header lets native --resume launch without fabricating
# the vendor's rendered surface or submitting a model prompt before recovery.
REF="$TMP/empty-session.jsonl"
python3 - "$REF" "$WT" <<'PY'
import datetime, json, sys, uuid
with open(sys.argv[1], 'w') as f:
    f.write(json.dumps({'type':'session','version':3,'id':str(uuid.uuid4()),
                       'timestamp':datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       'cwd':sys.argv[2]}) + '\n')
PY
run pane send-text "$PANE" "OMP_SKIP_SETUP=1 omp --resume='$REF'"
run pane send-keys "$PANE" Enter
for _ in $(seq 1 60); do
  proof=$(fm_launch_proof_herdr "$META")
  composer=$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")
  live=$(fm_backend_agent_state herdr "$SESSION:$PANE")
  [ "$proof" != unmanaged ] || [ "$composer" != empty ] || [ "$live" != alive ] || break
  sleep 0.2
done
[ "$proof" = unmanaged ] && [ "$composer" = empty ] && [ "$live" = alive ] || fail "omp $(omp --version): bare resume did not reach an attributable live empty composer ($proof/$composer/$live)"
run pane read "$PANE" --format ansi > "$TMP/bare-empty.ansi"
RETAINED_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_STATE_OVERRIDE" "$TASK_ID" \
  --state busy --source omp-ext --event agent_start)
printf 'busy_gen=%s\n' "$RETAINED_GEN" >> "$META"
PRESERVED=("$META" "$FM_STATE_OVERRIDE/$TASK_ID.busy-gen" "$FM_STATE_OVERRIDE/$TASK_ID.busy-state"
  "$FM_DATA_OVERRIDE/$TASK_ID/brief.md" "$WT/unlanded.txt")
for DRAFT in 'preserve draft' '!git diff' '$ print(1)'; do
  run pane send-text "$PANE" "$DRAFT"
  sleep 0.3
  [ "$(fm_backend_herdr_composer_content "$SESSION:$PANE")" = "$DRAFT" ] \
    || fail 'test draft was not captured before recovery'
  DRAFT_BEFORE=$(shasum -a 256 "${PRESERVED[@]}")
  for RECOVERY in direct sweep; do
    if [ "$RECOVERY" = direct ]; then
      if out=$("$ROOT/bin/fm-control.sh" "$TASK_ID" relaunch --recover-launch 2>&1); then
        fail "recovery must refuse a pending composer: $out"
      fi
    else
      if out=$("$ROOT/bin/fm-reboot-recover.sh" recover 2>&1); then
        fail "recovery sweep must refuse a pending composer: $out"
      fi
    fi
    [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")" = pending ] \
      || fail 'pending input was not preserved'
    [ "$(fm_backend_herdr_composer_content "$SESSION:$PANE")" = "$DRAFT" ] \
      || fail 'recovery altered the pending draft'
    [ "$(shasum -a 256 "${PRESERVED[@]}")" = "$DRAFT_BEFORE" ] \
      || fail 'pending refusal changed metadata, busy state, instructions or work'
    [ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] \
      && [ "$(git -C "$WT" symbolic-ref HEAD)" = "$BRANCH" ] \
      || fail 'pending refusal changed HEAD or branch'
    [ ! -e "$FM_STATE_OVERRIDE/$TASK_ID.control-relaunch" ] \
      || fail 'pending refusal began a lifecycle transaction'
    [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = alive ] \
      || fail 'pending refusal stopped the restored agent'
  done
  run pane send-keys "$PANE" ctrl+u
  for _ in $(seq 1 30); do
    [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")" != empty ] || break
    sleep 0.1
  done
done
if ! "$ROOT/bin/fm-reboot-recover.sh" recover; then
  run pane process-info --pane "$PANE"
  printf 'replacement launch proof: %s\n' "$(fm_launch_proof_herdr "$META")"
  fail 'recorded bare-resume recovery failed'
fi
await_managed
assert_live_profile
[ "$(fm_meta_get "$META" window)" = "$SESSION:$PANE" ] || fail 'recovery changed pane'
[ "$(fm_meta_get "$META" worktree)" = "$WT" ] || fail 'recovery changed worktree'
[ "$(fm_meta_get "$META" model)" = openai-codex/gpt-6.1-sol ] || fail 'recovery changed model'
[ "$(fm_meta_get "$META" effort)" = low ] || fail 'recovery changed effort'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] || fail 'recovery changed HEAD'
[ "$(git -C "$WT" symbolic-ref HEAD)" = "$BRANCH" ] || fail 'recovery changed branch'
[ "$(shasum -a 256 "$WT/unlanded.txt")" = "$HASH" ] || fail 'recovery lost dirty work'
GEN=$(fm_meta_get "$META" spawn_gen)
"$ROOT/bin/fm-reboot-recover.sh" recover
[ "$(fm_meta_get "$META" spawn_gen)" = "$GEN" ] || fail 'rescan relaunched an already managed agent'
for _ in $(seq 1 300); do
  frame=$(run pane read "$PANE" --format text)
  printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Recovery lab ready\.[[:space:]]*$' && break
  sleep 0.2
done
printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Recovery lab ready\.[[:space:]]*$' || fail 'replacement did not answer its instructions'
"$ROOT/bin/fm-control.sh" "$TASK_ID" exit
# A later bare native resume in the very same shell must not inherit the old
# incarnation. Exercise the local-secondmate route with a conflicting new pin.
mkdir -p "$WT/bin" "$WT/state" "$WT/data"
printf '%s\n' "$TASK_ID" > "$WT/.fm-secondmate-home"
printf '# Isolated lifecycle fixture\n' > "$WT/AGENTS.md"
cat > "$WT/data/charter.md" <<'EOF'
# Task
Do not inspect or modify files, delegate, supervise, or run any tools.
Reply only 'Secondmate lab ready.' then wait without further work.
EOF
printf 'window=child:child-pane\n' > "$WT/state/child.meta"
SM_HASH=$(shasum -a 256 "$WT/data/charter.md" "$WT/state/child.meta" "$WT/unlanded.txt")
printf 'kind=secondmate\nmode=secondmate\nhome=%s\n' "$WT" >> "$META"
printf 'claude opus high\n' > "$FM_CONFIG_OVERRIDE/secondmate-harness"
run pane send-text "$PANE" "OMP_SKIP_SETUP=1 omp --resume='$REF'"
run pane send-keys "$PANE" Enter
for _ in $(seq 1 60); do
  proof=$(fm_launch_proof_herdr "$META")
  composer=$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-$TASK_ID")
  live=$(fm_backend_agent_state herdr "$SESSION:$PANE")
  [ "$proof" != unmanaged ] || [ "$composer" != empty ] || [ "$live" != alive ] || break
  sleep 0.2
done
if [ "$proof" != unmanaged ] || [ "$composer" != empty ] || [ "$live" != alive ]; then
  run agent get "$PANE"
  run pane process-info --pane "$PANE"
  fail "bare resume inherited old launch proof or did not become a live empty composer ($proof/$composer/$live)"
fi
"$ROOT/bin/fm-reboot-recover.sh" recover
await_managed
assert_live_profile
[ "$(fm_meta_get "$META" harness)" = omp ] || fail 'recovery picked up the new secondmate harness pin'
[ "$(fm_meta_get "$META" model)" = openai-codex/gpt-6.1-sol ] || fail 'secondmate recovery changed model'
[ "$(fm_meta_get "$META" effort)" = low ] || fail 'secondmate recovery changed effort'
[ "$(fm_meta_get "$META" window)" = "$SESSION:$PANE" ] || fail 'secondmate recovery changed pane'
[ "$(fm_meta_get "$META" worktree)" = "$WT" ] || fail 'secondmate recovery changed worktree'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] || fail 'secondmate recovery changed HEAD'
[ "$(git -C "$WT" symbolic-ref HEAD)" = "$BRANCH" ] || fail 'secondmate recovery changed branch'
[ "$SM_HASH" = "$(shasum -a 256 "$WT/data/charter.md" "$WT/state/child.meta" "$WT/unlanded.txt")" ] || fail 'secondmate recovery changed charter or child work'
for _ in $(seq 1 300); do
  frame=$(run pane read "$PANE" --format text)
  printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Secondmate lab ready\.[[:space:]]*$' && break
  sleep 0.2
done
printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Secondmate lab ready\.[[:space:]]*$' || fail 'secondmate did not answer its charter'
"$ROOT/bin/fm-control.sh" "$TASK_ID" exit
printf 'Herdr lab runtime: '
run status --json
pass "omp $(omp --version): task and local secondmate bare resumes recovered with exact profiles, same pane/branch/worktree, preserved dirty and child work, and no inherited launch proof"
