#!/usr/bin/env bash
# Real omp bare-native-resume recovery in a named Herdr lab. Submits one short
# readiness prompt, so opt in with FM_OMP_REBOOT_LIVE=1 (or FM_LIVE=1).
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
REAL_PATH=$PATH
cleanup() { PATH="$REAL_PATH" "$HELPER" teardown "$SESSION"; chmod -R u+w "$TMP"; rm -rf "$TMP"; }
trap cleanup EXIT
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
    verdict=$(fm_launch_proof_herdr "$FM_HOME/state/reboot.meta")
    case "$verdict" in
      managed) return 0 ;;
      unmanaged) fail 'replacement has a readable but mismatched launch incarnation' ;;
    esac
    sleep 0.2
  done
  fail 'replacement foreground ancestry remained unreadable'
}
export FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$SESSION"
export FM_SPAWN_NO_GUARD=1
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN
mkdir -p "$FM_HOME/state" "$FM_HOME/data/reboot" "$FM_HOME/config" "$TMP/fakebin"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
fm_git_worktree "$TMP/proj" "$TMP/wt" reboot-lab
WT=$(cd "$TMP/wt" && pwd -P)
printf 'preserve this dirty file\n' > "$WT/unlanded.txt"
BEFORE=$(git -C "$WT" rev-parse HEAD)
BRANCH=$(git -C "$WT" symbolic-ref HEAD)
HASH=$(shasum -a 256 "$WT/unlanded.txt")
cat > "$FM_HOME/data/reboot/brief.md" <<'EOF'
# Task
## Captain's intent
This is an isolated lifecycle verification, not a project implementation.
Reply only 'Recovery lab ready.' then wait without further work.

## Firstmate spec
Do not inspect or modify files, delegate, supervise, or run any tools.
EOF
WS=$(run workspace create --cwd "$WT" --label reboot-lab | jq -r '.result.workspace.workspace_id')
PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
cat > "$FM_HOME/state/reboot.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=reboot
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
  proof=$(fm_launch_proof_herdr "$FM_HOME/state/reboot.meta")
  composer=$(fm_backend_composer_state herdr "$SESSION:$PANE" "fm-reboot")
  live=$(fm_backend_agent_state herdr "$SESSION:$PANE")
  [ "$proof" != unmanaged ] || [ "$composer" != empty ] || [ "$live" != alive ] || break
  sleep 0.2
done
[ "$proof" = unmanaged ] && [ "$composer" = empty ] && [ "$live" = alive ] || fail "omp $(omp --version): bare resume did not reach an attributable live empty composer ($proof/$composer/$live)"
run pane read "$PANE" --format ansi > "$TMP/bare-empty.ansi"
run pane send-text "$PANE" 'preserve draft'
sleep 0.3
DRAFT=$(fm_backend_herdr_composer_content "$SESSION:$PANE")
[ "$DRAFT" = 'preserve draft' ] || fail 'test draft was not captured before recovery'
if out=$("$ROOT/bin/fm-control.sh" reboot relaunch --recover-launch 2>&1); then
  fail "recovery must refuse a pending composer: $out"
fi
[ "$(fm_backend_composer_state herdr "$SESSION:$PANE" fm-reboot)" = pending ] || fail 'pending input was not preserved'
[ "$(fm_backend_herdr_composer_content "$SESSION:$PANE")" = "$DRAFT" ] || fail 'recovery altered the pending draft'
# Only remove our own test draft, never user input.
run pane send-keys "$PANE" ctrl+u
for _ in $(seq 1 30); do
  [ "$(fm_backend_composer_state herdr "$SESSION:$PANE" fm-reboot)" != empty ] || break
  sleep 0.1
done
if ! "$ROOT/bin/fm-reboot-recover.sh" recover; then
  run pane process-info --pane "$PANE"
  printf 'replacement launch proof: %s\n' "$(fm_launch_proof_herdr "$FM_HOME/state/reboot.meta")"
  fail 'recorded bare-resume recovery failed'
fi
await_managed
assert_live_profile
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" window)" = "$SESSION:$PANE" ] || fail 'recovery changed pane'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" worktree)" = "$WT" ] || fail 'recovery changed worktree'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" model)" = openai-codex/gpt-6.1-sol ] || fail 'recovery changed model'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" effort)" = low ] || fail 'recovery changed effort'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] || fail 'recovery changed HEAD'
[ "$(git -C "$WT" symbolic-ref HEAD)" = "$BRANCH" ] || fail 'recovery changed branch'
[ "$(shasum -a 256 "$WT/unlanded.txt")" = "$HASH" ] || fail 'recovery lost dirty work'
GEN=$(fm_meta_get "$FM_HOME/state/reboot.meta" spawn_gen)
"$ROOT/bin/fm-reboot-recover.sh" recover
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" spawn_gen)" = "$GEN" ] || fail 'rescan relaunched an already managed agent'
for _ in $(seq 1 300); do
  frame=$(run pane read "$PANE" --format text)
  printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Recovery lab ready\.[[:space:]]*$' && break
  sleep 0.2
done
printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Recovery lab ready\.[[:space:]]*$' || fail 'replacement did not answer its instructions'
"$ROOT/bin/fm-control.sh" reboot exit
# A later bare native resume in the very same shell must not inherit the old
# incarnation. Exercise the local-secondmate route with a conflicting new pin.
mkdir -p "$WT/bin" "$WT/state" "$WT/data"
printf 'reboot\n' > "$WT/.fm-secondmate-home"
printf '# Isolated lifecycle fixture\n' > "$WT/AGENTS.md"
cat > "$WT/data/charter.md" <<'EOF'
# Task
Do not inspect or modify files, delegate, supervise, or run any tools.
Reply only 'Secondmate lab ready.' then wait without further work.
EOF
printf 'window=child:child-pane\n' > "$WT/state/child.meta"
SM_HASH=$(shasum -a 256 "$WT/data/charter.md" "$WT/state/child.meta" "$WT/unlanded.txt")
printf 'kind=secondmate\nmode=secondmate\nhome=%s\n' "$WT" >> "$FM_HOME/state/reboot.meta"
printf 'claude opus high\n' > "$FM_HOME/config/secondmate-harness"
run pane send-text "$PANE" "OMP_SKIP_SETUP=1 omp --resume='$REF'"
run pane send-keys "$PANE" Enter
for _ in $(seq 1 60); do
  proof=$(fm_launch_proof_herdr "$FM_HOME/state/reboot.meta")
  composer=$(fm_backend_composer_state herdr "$SESSION:$PANE" fm-reboot)
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
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" harness)" = omp ] || fail 'recovery picked up the new secondmate harness pin'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" model)" = openai-codex/gpt-6.1-sol ] || fail 'secondmate recovery changed model'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" effort)" = low ] || fail 'secondmate recovery changed effort'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" window)" = "$SESSION:$PANE" ] || fail 'secondmate recovery changed pane'
[ "$(fm_meta_get "$FM_HOME/state/reboot.meta" worktree)" = "$WT" ] || fail 'secondmate recovery changed worktree'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BEFORE" ] || fail 'secondmate recovery changed HEAD'
[ "$(git -C "$WT" symbolic-ref HEAD)" = "$BRANCH" ] || fail 'secondmate recovery changed branch'
[ "$SM_HASH" = "$(shasum -a 256 "$WT/data/charter.md" "$WT/state/child.meta" "$WT/unlanded.txt")" ] || fail 'secondmate recovery changed charter or child work'
for _ in $(seq 1 300); do
  frame=$(run pane read "$PANE" --format text)
  printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Secondmate lab ready\.[[:space:]]*$' && break
  sleep 0.2
done
printf '%s\n' "$frame" | grep -Eq '^[[:space:]]*Secondmate lab ready\.[[:space:]]*$' || fail 'secondmate did not answer its charter'
"$ROOT/bin/fm-control.sh" reboot exit
printf 'Herdr lab runtime: '
run status --json
pass "omp $(omp --version): task and local secondmate bare resumes recovered with exact profiles, same pane/branch/worktree, preserved dirty and child work, and no inherited launch proof"
