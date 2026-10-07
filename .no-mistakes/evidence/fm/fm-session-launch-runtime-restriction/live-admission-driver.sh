#!/usr/bin/env bash
set -eu
ROOT="$PWD"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
CHILD=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SOCKET=
cleanup() {
  if [ -n "$SOCKET" ]; then TMUX_TMPDIR="$SOCKET" tmux -L fm-lab kill-server 2>/dev/null || true; fi
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" || true
  chmod -R u+w "$LAB" "$CHILD"
  rm -rf "$LAB" "$CHILD"
  [ ! -e "$LAB" ] && [ ! -e "$CHILD" ] && echo 'CLEANUP: owned private tmux server and disposable homes removed'
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$CHILD"
SOCKET=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export FM_HOME="$LAB" TMUX_TMPDIR="$SOCKET" FM_BACKEND=tmux FM_SKIP_SECONDMATE_SYNC=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID
mkdir -p "$CHILD/bin" "$LAB/data/labmate" "$LAB/sentinels"
cp "$ROOT/AGENTS.md" "$CHILD/AGENTS.md"
for owner in "$ROOT"/bin/*; do ln -s "$owner" "$CHILD/bin/"; done
printf '/config/*\n!/config/session-launch-policy\n/data/\n/state/\n/projects/\n/bin/\n/.fm-lab-home\n' > "$CHILD/.gitignore"
printf 'labmate\n' > "$CHILD/.fm-secondmate-home"
printf 'omp-or-tc\n' > "$CHILD/config/session-launch-policy"
printf 'Keep this disposable work unchanged. Do not use any tools or launch any sessions.\n' > "$CHILD/data/charter.md"
printf 'unpublished work\n' > "$CHILD/unpublished"
printf 'child validation custody\n' > "$CHILD/state/descendant.validation"
printf 'window=primary:fm-descendant\nkind=ship\nharness=omp\n' > "$CHILD/state/descendant.meta"
git -C "$CHILD" init -q
git -C "$CHILD" add .gitignore unpublished
git -C "$CHILD" -c user.name='Lab' -c user.email=lab@example.invalid commit -qm 'Disposable lab work'
HEAD_PRIOR=$(git -C "$CHILD" rev-parse HEAD)
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'codex\n' > "$LAB/config/secondmate-harness"
printf 'omp\n' > "$LAB/config/crew-harness"
printf 'tmux\n' > "$LAB/config/backend"
printf -- '- labmate - admission lab (home: %s; scope: policy; projects: alpha; added 2026-10-07)\n' "$CHILD" > "$LAB/data/secondmates.md"
printf 'Continue unchanged lab work.\n' > "$LAB/data/labmate/brief.md"
# A sentinel is only a forbidden-executable tripwire; no vendor session is substituted.
for executable in codex claude; do
  printf '#!/bin/sh\nprintf "FORBIDDEN EXECUTABLE REACHED\\n" >> "%s/forbidden-launch"\nexit 99\n' "$LAB" > "$LAB/sentinels/$executable"
  chmod +x "$LAB/sentinels/$executable"
done
export PATH="$LAB/sentinels:$PATH"
# Start an actual endpoint on the private server, without any model session.
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$ROOT" -e FM_HOME="$LAB"
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),1,0
TARGET=$(tmux -L fm-lab new-window -d -t primary -n fm-labmate -c "$CHILD" -P -F '#{pane_id}')
WINDOW_ID=$(tmux -L fm-lab display-message -p -t "$TARGET" '#{window_id}')
seed_meta() {
cat > "$LAB/state/labmate.meta" <<EOF
window=primary:fm-labmate
endpoint_task_id=labmate
kind=secondmate
harness=omp
home=$CHILD
worktree=$CHILD
project=$CHILD
backend=tmux
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
printf 'validation custody\n' > "$LAB/state/labmate.validation"
printf '1\tattempt\n1\tfailed\n' > "$LAB/state/.secondmate-relaunch-labmate"
}
manifest() {
for file in "$CHILD/config/session-launch-policy" "$CHILD/unpublished" "$CHILD/state/descendant.meta" "$CHILD/state/descendant.validation" "$CHILD/data/charter.md" "$LAB/data/secondmates.md" "$LAB/data/labmate/brief.md" "$LAB/state/labmate.validation" "$LAB/state/.secondmate-relaunch-labmate"; do shasum -a 256 "$file"; done
[ ! -f "$LAB/state/labmate.meta" ] || shasum -a 256 "$LAB/state/labmate.meta"
}
seed_meta
BEFORE=$(manifest)
check_preserved() {
  [ "$(manifest)" = "$BEFORE" ]
  [ "$(git -C "$CHILD" rev-parse HEAD)" = "$HEAD_PRIOR" ]
  [ "$(tmux -L fm-lab display-message -p -t "$TARGET" '#{window_id}')" = "$WINDOW_ID" ]
  [ ! -e "$LAB/forbidden-launch" ]
  [ ! -e "$LAB/state/labmate.control-relaunch" ]
  [ ! -e "$LAB/state/labmate.control-relaunch.meta-prior" ]
  [ ! -e "$LAB/state/labmate.control-relaunch.note" ]
  [ ! -e "$LAB/config/session-launch-policy" ]
  printf 'PRESERVED: parent policy absent; child enabled policy, endpoint %s/%s, recovery ledger, metadata, HEAD, unpublished work, charter and custody unchanged; no forbidden executable reached\n' "$WINDOW_ID" "$TARGET"
}
refuse() {
  label=$1; shift
  echo "SCENARIO: $label"
  rc=0; output=$("$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$output" "$rc"
  [ "$rc" -ne 0 ]
  case "$output" in *session-launch-policy*) ;; *) exit 1;; esac
  if [ "${MODE:-boundaries}" = tooling ]; then
    case "$output" in *'session-launch-policy tooling is not verified'*) ;; *) exit 1;; esac
  fi
  check_preserved
}
if [ "${MODE:-boundaries}" = tooling ]; then
  echo 'TOOLING ADVERSARY: child retains enabled policy but its control owner is obsolete'
  rm "$CHILD/bin/fm-control.sh"
  printf '#!/bin/sh\nexit 99\n' > "$CHILD/bin/fm-control.sh"
fi
if [ "${MODE:-boundaries}" = boundaries ] || [ "${MODE:-boundaries}" = tooling ]; then
refuse 'Direct replacement refuses retained-child Codex' "$ROOT/bin/fm-spawn.sh" labmate --relaunch --harness codex
refuse 'Direct replacement refuses opaque raw Omp command' "$ROOT/bin/fm-spawn.sh" labmate --relaunch --harness 'omp --model anything'
refuse 'Manual relaunch refuses configured Codex before stop' "$ROOT/bin/fm-control.sh" labmate relaunch --note 'continue unchanged work'
echo 'SCENARIO: Automatic dead-endpoint recovery refuses configured Codex before attempts/removal'
rc=0
output=$(bash -c '
set -eu
FM_ROOT=$1
. "$1/bin/fm-secondmate-liveness-lib.sh"
STATE="$FM_HOME/state"
fm_secondmate_liveness_lock labmate
trap "fm_secondmate_liveness_unlock labmate" EXIT
fm_secondmate_liveness_probe "$STATE/labmate.meta" labmate poll
printf "probe_state=%s probe_status=%s\n" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_STATUS"
[ "$FM_SM_LIVE_STATE" = dead ] && [ "$FM_SM_LIVE_STATUS" = relaunchable ]
rc=0
fm_secondmate_liveness_relaunch "$STATE/labmate.meta" labmate || rc=$?
printf "recovery_status=%s policy_refused=%s reason=%s\n%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_POLICY_REFUSED" "$FM_SM_LIVE_REASON" "$FM_SM_LIVE_OUT"
[ "$FM_SM_LIVE_POLICY_REFUSED" = 1 ] && [ "$FM_SM_LIVE_STATUS" = skipped ]
exit "$rc"
' _ "$ROOT" 2>&1) || rc=$?
printf '%s\nexit=%s\n' "$output" "$rc"
[ "$rc" -ne 0 ]
case "$output" in *'probe_state=dead probe_status=relaunchable'*'policy_refused=1'*) ;; *) exit 1;; esac
check_preserved
rm "$LAB/state/labmate.meta"
BEFORE=$(manifest)
refuse 'Fresh secondmate refuses retained-child Codex before allocating endpoint' "$ROOT/bin/fm-spawn.sh" labmate "$CHILD" --secondmate
refuse 'Fresh secondmate refuses retained-child opaque raw command' "$ROOT/bin/fm-spawn.sh" labmate "$CHILD" --secondmate --harness 'omp --model anything'
fi
if [ "${MODE:-boundaries}" = tooling ]; then exit 0; fi
if [ "${MODE:-boundaries}" = native ]; then
  echo 'SCENARIO: Real canonical Omp replacement starts under retained enabled child policy'
  printf 'omp openai-codex/gpt-6.1-sol high\n' > "$LAB/config/secondmate-harness"
  printf 'This is an isolated launch validation, not an operational task. Do not call any tools, do not bootstrap, do not launch agents, do not modify any files. Reply exactly LAB_NATIVE_OMP_READY_71 and then wait for further instructions.\n' > "$CHILD/data/charter.md"
  "$ROOT/bin/fm-spawn.sh" labmate --relaunch
  for tick in $(seq 1 90); do
    CAPTURE=$(tmux -L fm-lab capture-pane -p -t "$TARGET" -S -200)
    case "$CAPTURE" in *LAB_NATIVE_OMP_READY_71*LAB_NATIVE_OMP_READY_71*) break;; esac
    sleep 1
  done
  printf 'ACTUAL NATIVE PANE:\n%s\n' "$CAPTURE"
  case "$CAPTURE" in *LAB_NATIVE_OMP_READY_71*LAB_NATIVE_OMP_READY_71*) ;; *) exit 1;; esac
  printf 'REAL PANE PROCESS: '
  tmux -L fm-lab display-message -p -t "$TARGET" '#{pane_current_command}'
  printf 'codex\n' > "$LAB/config/secondmate-harness"
  BEFORE=$(manifest)
  refuse 'Manual replacement refuses Codex while actual Omp stays running' "$ROOT/bin/fm-control.sh" labmate relaunch --note 'leave native lab session unchanged'
  echo 'POST-REFUSAL ACTUAL OMP STATE:'
  bash -c 'FM_ROOT=$1; . "$1/bin/fm-backend.sh"; state=$(fm_backend_agent_state tmux "$2"); printf "backend_agent_state=%s\n" "$state"; [ "$state" = alive ]' _ "$ROOT" "primary:fm-labmate"
  exit 0
fi
echo 'SCENARIO: Shared effective-child admission permits canonical Omp and successful writable policy removal'
printf 'omp openai-codex/gpt-6.1-sol high\n' > "$LAB/config/secondmate-harness"
bash -c 'set -eu; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-session-launch-policy-lib.sh"; fm_session_launch_policy_converge_child "$FM_HOME/config" "$2" labmate omp; printf "canonical_omp_admitted=true retained_policy="; cat "$2/config/session-launch-policy"' _ "$ROOT" "$CHILD"
printf '/config/\n/data/\n/state/\n/projects/\n/bin/\n/.fm-lab-home\n' > "$CHILD/.gitignore"
bash -c 'set -eu; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-session-launch-policy-lib.sh"; fm_session_launch_policy_converge_child "$FM_HOME/config" "$2" labmate omp; [ ! -e "$2/config/session-launch-policy" ]; printf "writable_child_policy_removed=true canonical_omp_admitted=true\n"' _ "$ROOT" "$CHILD"
echo 'ALL TARGETED BOUNDARY SCENARIOS PASSED'
