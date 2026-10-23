#!/usr/bin/env bash
# Ad-hoc live routing probe: a real fm-spawn.sh in a named Herdr lab, on a home
# whose crew default is omp. (1) --harness omp + DeepSeek model must refuse and
# start nothing. (2) No harness + DeepSeek model must launch real dsh-tui.
set -eu
ROOT=$1 PROJECT=$2 COPY=$3 TASK=$4
HELPER=$ROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$TASK/herdr-safety"
mkdir -p "$TASK/bin"
SESSION=$("$HELPER" name dsh-route)
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  [ -z "${HOME_ROOT:-}" ] || { "$ROOT/bin/fm-lab-home.sh" teardown "$HOME_ROOT" || rc=1; chmod -R u+w "$HOME_ROOT" 2>/dev/null; rm -rf "$HOME_ROOT"; }
  echo "cleanup_exit=$rc"
  exit "$rc"
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
PROJECT=$(cd "$PROJECT" && pwd -P); COPY=$(cd "$COPY" && pwd -P)
HOME_ROOT=$(mktemp -d /tmp/fm-lab.XXXXXX)
"$ROOT/bin/fm-lab-home.sh" create "$HOME_ROOT"
echo "lab_home=$HOME_ROOT"
printf 'manual\n' > "$HOME_ROOT/config/backlog-backend"
printf 'herdr\n' > "$HOME_ROOT/config/runtime-backend"
printf 'omp\n' > "$HOME_ROOT/config/crew-harness"
printf '| Project | Path | Mode | Yolo |\n| --- | --- | --- | --- |\n| dsh-route | %s | local-only | off |\n' "$5" > "$HOME_ROOT/data/projects.md"
cat > "$TASK/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
# The spawn's client-version preflight names no session; answer it from the lab.
[ "\$*" != 'status --json' ] || exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' status --json
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'lab guard refuses unsessioned or foreign Herdr call' >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$TASK/bin/herdr"
"$HELPER" provision "$SESSION"
export PATH="$TASK/bin:$ORIGINAL_PATH"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/backends/herdr.sh"
ID="dsh-route-scout-$$"
mkdir -p "$HOME_ROOT/data/$ID"
cat > "$HOME_ROOT/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Prove DeepSeek routing picks dsh-tui without changing files.
## Firstmate spec
Reply exactly FMDSHROUTED and nothing else. Do not run tools or edit any file.
EOF
FRESH_PROJECT=$5
echo '== adversarial: --harness omp --model deepseek/deepseek-v4-flash'
set +e
out=$(HERDR_SESSION="$SESSION" FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$ID" "$FRESH_PROJECT" --scout --backend herdr --harness omp --model deepseek/deepseek-v4-flash --effort high 2>&1)
rc=$?
set -e
printf '%s\nexit=%s\n' "$out" "$rc"
[ "$rc" -ne 0 ] || { echo 'FAIL: DeepSeek on omp was admitted' >&2; exit 1; }
case "$out" in *"DeepSeek runs through dsh-tui, not omp"*) ;; *) echo 'FAIL: refusal did not name dsh-tui' >&2; exit 1 ;; esac
[ ! -e "$HOME_ROOT/state/$ID.meta" ] || { echo 'FAIL: refused route published a task meta' >&2; exit 1; }
[ ! -e "$HOME_ROOT/state/$ID.dsh-session" ] || { echo 'FAIL: refused route bound a dsh launch' >&2; exit 1; }
echo "lab workspaces after refusal: $(lab workspace list 2>/dev/null | jq -c '[.result.workspaces[]?.label]' 2>/dev/null || echo unknown)"
echo 'ok - DeepSeek forced onto omp refused before launch; no task meta; no launch bound'
echo '== implicit: no harness, --model deepseek/deepseek-v4-flash, crew default omp'
HERDR_SESSION="$SESSION" FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$ID" "$FRESH_PROJECT" --scout --backend herdr --model deepseek/deepseek-v4-flash --effort high
PANE=$(sed -n 's/^herdr_pane_id=//p' "$HOME_ROOT/state/$ID.meta")
cp "$HOME_ROOT/state/$ID.meta" "$TASK/meta.after"
grep -E '^(harness|model|kind|backend|herdr_session)=' "$HOME_ROOT/state/$ID.meta"
grep -qx 'harness=dsh' "$HOME_ROOT/state/$ID.meta" || { echo 'FAIL: meta did not record dsh' >&2; exit 1; }
for _ in $(seq 1 120); do
  screen=$(lab pane read "$PANE" --source recent --lines 250 2>/dev/null || true)
  case "$screen" in *FMDSHROUTED*) break ;; esac
  sleep 1
done
lab pane read "$PANE" --source visible > "$TASK/pane-visible.txt" || true
case "$screen" in *FMDSHROUTED*) ;; *) cat "$TASK/pane-visible.txt"; echo 'FAIL: dsh-tui never answered' >&2; exit 1 ;; esac
session=$(python3 "$ROOT/bin/fm-dsh.py" session-file "$HOME_ROOT/state" "$ID")
echo "dsh session log: $session"
grep -q FMDSHROUTED "$session" || { echo 'FAIL: reply not in the dsh session log' >&2; exit 1; }
echo "dsh state: $(python3 "$ROOT/bin/fm-dsh.py" state "$HOME_ROOT/state" "$ID")"
echo "detected harness: $(FM_HOME="$HOME_ROOT" bash "$ROOT/bin/fm-harness.sh" 2>/dev/null | head -1 || true)"
for _ in $(seq 1 60); do [ "$(fm_backend_herdr_composer_state "$SESSION:$PANE")" = empty ] && break; sleep 1; done
FM_HOME="$HOME_ROOT" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 bash "$ROOT/bin/fm-control.sh" "$ID" exit
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo 'FAIL: exit did not stop the worker' >&2; exit 1; }
echo 'ok - DeepSeek model with no harness launched real dsh-tui (crew default omp ignored), answered, exited'
