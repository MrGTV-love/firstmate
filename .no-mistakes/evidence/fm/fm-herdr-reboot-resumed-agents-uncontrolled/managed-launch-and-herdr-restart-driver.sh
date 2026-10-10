#!/usr/bin/env bash
# Live gate driver: a Firstmate-managed omp launch in a guarded Herdr lab,
# lifecycle control while managed, then a real Herdr server stop/restart with an
# attached viewer (Herdr native auto-resume), and the post-restore behavior.
# Usage: driver.sh <repo-root> <evidence-dir>
set -u
ROOT=$1
EV=$2
HELPER="$ROOT/bin/fm-herdr-lab.sh"
unset HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
REAL_PATH=$PATH
REAL_OMP=$(command -v omp)
SESSION=$("$HELPER" name mgd-reboot)
P=$(mktemp -d "${TMPDIR:-/tmp}/fm-mgd-reboot.XXXXXX"); P=$(cd "$P" && pwd -P)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
OWNED=0; MODEL_PID=
TID="mgd$$"
log() { printf '%s\n' "$*"; }
step() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }
FAILED=0
cleanup() {
  local pid
  if [ "$OWNED" = 1 ]; then PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" && log "teardown ok: $SESSION"; fi
  [ -z "$MODEL_PID" ] || kill "$MODEL_PID" 2>/dev/null
  for pid in $(ps -axo pid=,command= | awk -v a="$P" -v b="$LAB" -v me="$$" '(index($0,a)||index($0,b)) && $1!=me {print $1}'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  chmod -R u+w "$P" "$LAB" 2>/dev/null; rm -rf "$P" "$LAB"
  log "private trees removed"
  exit "$FAILED"
}
trap cleanup EXIT

# --- isolated omp: private agent dir, scripted local model, no credentials ----
NH="$P/omp-home"; AG="$NH/.omp/agent"
mkdir -p "$AG" "$NH/.config" "$NH/.local/share" "$NH/.local/state" "$NH/.cache" "$P/wrap" "$P/zdot" "$P/fakebin"
cat > "$P/model.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class M(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("content-length", 0)))
        with open(sys.argv[1], "a") as f: f.write("request\n")
        self.send_response(200); self.send_header("content-type", "text/event-stream"); self.end_headers()
        c = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for d, fin in (({"role": "assistant", "content": "ack"}, None), ({}, "stop")):
            self.wfile.write(b"data: " + json.dumps(dict(c, choices=[{"index": 0, "delta": d, "finish_reason": fin}])).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n"); self.wfile.flush()
s = ThreadingHTTPServer(("127.0.0.1", 0), M)
open(sys.argv[2], "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 -I "$P/model.py" "$P/model.log" "$P/model.port" & MODEL_PID=$!
for _ in $(seq 1 50); do [ -s "$P/model.port" ] && break; sleep 0.1; done
cat > "$AG/config.yml" <<YML
setupVersion: 2
modelRoles:
  default: lab/m1
  tiny: lab/m1
  advisor: lab/m1
  vision: lab/m1
YML
cat > "$AG/models.yml" <<YML
providers:
  lab:
    baseUrl: http://127.0.0.1:$(cat "$P/model.port")/v1
    apiKey: lab-key
    api: openai-completions
    models:
      - id: m1
        contextWindow: 200000
        maxTokens: 4096
YML
OMP_ENV=(HOME="$NH" XDG_CONFIG_HOME="$NH/.config" XDG_DATA_HOME="$NH/.local/share"
  XDG_STATE_HOME="$NH/.local/state" XDG_CACHE_HOME="$NH/.cache" PI_CONFIG_DIR=.omp
  PI_CODING_AGENT_DIR="$AG" OMP_PROFILE=default PI_PROFILE=default OMP_SKIP_SETUP=1)
{ printf '#!/bin/sh\nexec env'; printf ' %q' "${OMP_ENV[@]}"; printf ' %q "$@"\n' "$REAL_OMP"; } > "$P/wrap/omp"
chmod +x "$P/wrap/omp"

# --- guarded Herdr lab; pane shells skip user rc so the private omp wins -------
"$HELPER" prepare "$SESSION" || { bad "lab prepare"; exit 1; }
OWNED=1
provision() {
  ZDOTDIR="$P/zdot" PI_CODING_AGENT_DIR="$AG" OMP_SKIP_SETUP=1 PATH="$P/wrap:$REAL_PATH" \
    "$HELPER" provision "$SESSION"
}
provision || { bad "lab provision"; exit 1; }
env "${OMP_ENV[@]}" PI_CODING_AGENT_DIR= PATH="$REAL_PATH" "$HELPER" run "$SESSION" integration install omp || { bad "integration install"; exit 1; }
cat > "$P/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
elif [ "\$n" -eq 2 ] && [ "\$1" = status ] && [ "\$2" = --json ]; then :
else echo "lab wrapper requires --session $SESSION" >&2; exit 98; fi
exec env PATH="$REAL_PATH" "$HELPER" run "$SESSION" "\${args[@]}"
SH
chmod +x "$P/fakebin/herdr"
export PATH="$P/fakebin:$P/wrap:$REAL_PATH" HERDR_SESSION="$SESSION"
lab() { env PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }

# --- disposable marked Firstmate lab home and one ship record ------------------
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { bad "lab home"; exit 1; }
export FM_HOME="$LAB"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'off\n' > "$LAB/config/herdr-presentation-spaces"
PROJ="$P/proj"; WT="$P/wt"
git init -q "$PROJ"; printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b "$TID" "$WT"
WT=$(cd "$WT" && pwd -P)
mkdir -p "$LAB/data/$TID"
cat > "$LAB/data/$TID/brief.md" <<'EOF'
# Task
## Captain's intent
Isolated lifecycle verification; reply ack and stay idle.

## Firstmate spec
Do not run tools or edit files.
EOF
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
. "$ROOT/bin/fm-launch-proof-lib.sh"
C=$(fm_backend_herdr_container_ensure "$WT") || { bad "container_ensure"; exit 1; }
CONT=${C%%$'\t'*}; SEED=${C#*$'\t'}
read -r TAB PANE <<<"$(fm_backend_herdr_create_task "$CONT" "fm-$TID" "$WT" "$SEED")"
META="$LAB/state/$TID.meta"
cat > "$META" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$TID
worktree=$WT
project=$PROJ
harness=omp
kind=ship
mode=no-mistakes
yolo=off
model=lab/m1
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=${CONT#*:}
herdr_tab_id=$TAB
herdr_pane_id=$PANE
spawn_gen=pre-$$
launch_proof=env-v1
EOF
T="$SESSION:$PANE"
proof() { fm_launch_proof_herdr "$META"; }
composer() { fm_backend_composer_state herdr "$T" "fm-$TID"; }
alive() { fm_backend_agent_state herdr "$T"; }
fg_pid() { fm_launch_proof_herdr_pid "$META"; }
screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
wait_managed_idle() {
  local i
  for i in $(seq 1 120); do
    [ "$(proof)" = managed ] && [ "$(composer)" = empty ] && [ "$(alive)" = alive ] && return 0
    sleep 1
  done
  return 1
}
nogate() { grep -v "^fm-gate-refuse: gate agent lifecycle permitted only against lab home"; }
control() { FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 "$ROOT/bin/fm-control.sh" "$@" 2>&1 | nogate; return "${PIPESTATUS[0]}"; }
recover() { "$ROOT/bin/fm-reboot-recover.sh" "$@" 2>&1 | nogate; return "${PIPESTATUS[0]}"; }

step "S4a: Firstmate launches omp through its own launch boundary (fm-spawn --relaunch on the agent-free endpoint)"
out=$(FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" "$TID" --relaunch --harness omp 2>&1); rc=$?
log "fm-spawn rc=$rc"; printf '%s\n' "$out" | tail -5
GEN1=$(fm_meta_get "$META" spawn_gen)
log "meta: launch_proof=$(fm_meta_get "$META" launch_proof) spawn_gen=$GEN1"
if wait_managed_idle; then ok "managed omp launch reads proof=managed composer=empty agent=alive"; else bad "managed launch did not settle: proof=$(proof) composer=$(composer) alive=$(alive)"; screen | tail -15; fi
PID1=$(fg_pid); log "agent pid=$PID1 argv: $(ps -p "$PID1" -o command= | cut -c1-400)"
ENV1=$(fm_remote_herdr_process_env "$PID1")
printf '%s\n' "$ENV1" | grep -Fx "FM_SPAWN_GEN=$GEN1" >/dev/null && ok "agent environment carries FM_SPAWN_GEN=$GEN1" || bad "agent env lacks the spawn pin"
SHELL_PID=$(lab pane process-info --pane "$PANE" | jq -r '.result.process_info.shell_pid // empty')
[ -n "$SHELL_PID" ] || SHELL_PID=$(ps -o ppid= -p "$PID1" | tr -d ' ')
SHENV=$(fm_remote_herdr_process_env "$SHELL_PID" 2>/dev/null || true)
log "pane shell pid=$SHELL_PID ($(ps -p "$SHELL_PID" -o comm= 2>/dev/null))"
if printf '%s\n' "$SHENV" | grep -q '^FM_SPAWN_GEN='; then bad "persistent pane shell carries FM_SPAWN_GEN"; else ok "persistent pane shell does not carry FM_SPAWN_GEN"; fi
log "session proof: $(cat "$LAB/state/$TID.omp-session.json" 2>/dev/null)"
screen > "$EV/s4a-managed-screen.txt"
log "composer screen (tail):"; screen | grep -v '^\s*$' | tail -6

step "S4b: reboot sweep stays quiet for a managed agent"
out=$(recover recover); rc=$?
log "recover rc=$rc output=[$out]"
[ "$rc" = 0 ] && [ -z "$out" ] && ok "sweep reports nothing for the managed agent" || bad "sweep reported for a managed agent"

step "S4c: fm-control relaunch of the managed omp (exit through composer + fresh managed launch)"
out=$(control "$TID" relaunch --note 'Lab relaunch: reply ack and stay idle.'); rc=$?
log "relaunch rc=$rc"; printf '%s\n' "$out" | tail -6
GEN2=$(fm_meta_get "$META" spawn_gen)
if [ "$rc" = 0 ] && [ "$GEN2" != "$GEN1" ] && wait_managed_idle && [ "$(fg_pid)" != "$PID1" ]; then
  ok "relaunch replaced pid $PID1 with $(fg_pid), new spawn_gen=$GEN2, proof=managed"
else bad "relaunch: rc=$rc gen $GEN1->$GEN2 proof=$(proof) composer=$(composer)"; fi
PID2=$(fg_pid)
lab pane send-text "$PANE" 'draft that must survive'
sleep 2
log "composer with draft: $(composer)"
out=$(control "$TID" exit); rc=$?
log "exit-with-draft rc=$rc: $out"
[ "$rc" != 0 ] && [ "$(fg_pid)" = "$PID2" ] && ok "managed exit refuses over a pending draft and keeps the agent" || bad "exit over draft"
lab pane send-keys "$PANE" ctrl+u; sleep 2
log "composer after clearing draft: $(composer)"

step "S5: simulated reboot - stop the lab Herdr server, restart it, attach a viewer (native auto-resume)"
SESSION_FILE=$(jq -r '.current_session_file' "$LAB/state/$TID.omp-session.json")
log "managed current session file: $SESSION_FILE"
PATH="$REAL_PATH" "$HELPER" stop "$SESSION" >/dev/null && log "server stopped"
for _ in $(seq 1 50); do kill -0 "$PID2" 2>/dev/null || break; sleep 0.2; done
kill -0 "$PID2" 2>/dev/null && bad "old omp pid $PID2 survived server stop" || ok "server stop ended the managed omp (pid $PID2)"
provision && log "server restarted"
PATH="$REAL_PATH" "$HELPER" viewer start "$SESSION" && log "viewer attached"
RPID=
for _ in $(seq 1 120); do
  RPID=$(fg_pid 2>/dev/null) && [ -n "$RPID" ] && [ "$(alive)" = alive ] && break
  RPID=; sleep 1
done
if [ -n "$RPID" ]; then
  log "restored pid=$RPID argv: $(ps -p "$RPID" -o command= | cut -c1-400)"
  ok "Herdr natively restored a live agent in the recorded pane"
else
  bad "no restored agent appeared"; screen | tail -20; exit 1
fi
sleep 5
screen > "$EV/s5-restored-screen.txt"
log "restored screen (tail):"; screen | grep -v '^\s*$' | tail -8
RENV=$(fm_remote_herdr_process_env "$RPID" 2>/dev/null || true)
printf '%s\n' "$RENV" | grep -q '^FM_SPAWN_GEN=' && bad "restored agent kept a spawn pin" || ok "restored agent has no FM_SPAWN_GEN pin"
log "restored proof=$(proof) composer=$(composer) agent=$(alive)"
[ "$(proof)" = unmanaged ] && ok "launch proof reads unmanaged after native restore" || bad "restored proof=$(proof)"

step "S6: lifecycle verbs refuse the unmanaged restore and change nothing"
cp "$META" "$P/meta.before"
STATE_BEFORE=$(cd "$LAB/state" && find . -type f | LC_ALL=C sort)
log "pre-existing transaction files: $(ls "$LAB/state" | grep -E "control-(relaunch|exit)" | tr "\n" " ")"
for v in interrupt exit; do
  out=$(control "$TID" "$v"); rc=$?
  log "$v rc=$rc: $out"
  case "$out" in *'cannot positively attribute its live Herdr agent'*) [ "$rc" != 0 ] && ok "$v refused" || bad "$v rc=0" ;; *) bad "$v did not refuse on attribution" ;; esac
done
out=$(control "$TID" relaunch --note 'must not land'); rc=$?
log "relaunch rc=$rc: $out"
case "$out" in *'cannot positively attribute its live Herdr agent'*) [ "$rc" != 0 ] && ok "relaunch refused before checkpoint" || bad "relaunch rc=0" ;; *) bad "relaunch did not refuse on attribution" ;; esac
out=$(control "$TID" relaunch --recover-launch); rc=$?
log "relaunch --recover-launch rc=$rc: $out"
case "$out" in *"recovery-skipped $TID launch=unmanaged"*) ok "direct inspection reports unmanaged no-op" ;; *) bad "direct inspection output" ;; esac
[ "$(fg_pid)" = "$RPID" ] && ok "restored pid unchanged after all verbs" || bad "restored pid changed"
cmp -s "$META" "$P/meta.before" && ok "task record unchanged" || bad "task record changed"
STATE_AFTER=$(cd "$LAB/state" && find . -type f | LC_ALL=C sort)
if [ "$STATE_BEFORE" = "$STATE_AFTER" ]; then ok "no state file created or removed by the refused verbs"; else bad "state files changed"; diff <(printf "%s\n" "$STATE_BEFORE") <(printf "%s\n" "$STATE_AFTER"); fi

step "S7: reboot sweep alerts (unbounded and bounded-once)"
out=$(recover recover); rc=$?
log "recover rc=$rc: $out"
case "$out" in *"REBOOT_RECOVERY: $TID: live launch is unmanaged; no lifecycle action taken"*) ok "unbounded sweep reports the unmanaged restore" ;; *) bad "unbounded sweep output" ;; esac
o1=$(recover recover --one); r1=$?
o2=$(recover recover --one); r2=$?
log "--one #1 rc=$r1: [$o1]"; log "--one #2 rc=$r2: [$o2]"
log "notice file: $(cat "$LAB/state/$TID.reboot-notice" 2>/dev/null)"
case "$o1" in *"live launch is unmanaged"*) [ -z "$o2" ] && ok "bounded sweep notifies once per restored identity" || bad "bounded sweep repeated" ;; *) bad "bounded sweep did not notify" ;; esac

step "S8: session-start deferred bootstrap phase surfaces the alert"
# Bootstrap passes FM_STATE_OVERRIDE to the sweep, which a gate worktree refuses even for a
# lab home; run the same commit from a plain clone outside the gate repository.
git clone -q "$ROOT" "$P/plain-clone"
log "plain clone HEAD=$(git -C "$P/plain-clone" rev-parse HEAD) (gate HEAD=$(git -C "$ROOT" rev-parse HEAD))"
out=$(cd "$P/plain-clone" && env -u NO_MISTAKES_GATE FM_BOOTSTRAP_NETWORK=only ./bin/fm-bootstrap.sh 2>&1); rc=$?
printf '%s\n' "$out" | grep -E 'REBOOT_RECOVERY|refus|error' | head -10
case "$out" in *"REBOOT_RECOVERY: $TID: live launch is unmanaged"*) ok "bootstrap deferred phase reports the unmanaged restore" ;; *) log "bootstrap output (tail):"; printf '%s\n' "$out" | tail -15; bad "bootstrap did not report" ;; esac
[ "$(fg_pid)" = "$RPID" ] && ok "restored pid still unchanged after bootstrap" || bad "bootstrap changed the restored agent"

step "S9: the running watcher repeats the bounded scan and raises a check wake"
# S7 recorded this identity's notice; clear only that record so the watcher sees a fresh restore.
rm -f "$LAB/state/$TID.reboot-notice"
# Pre-restart turn-end signals would otherwise win the first wake; consume them first.
log "consuming pre-restart signals: $(ls "$LAB/state" | grep -E "turn-ended|wake-queue" | tr "\n" " ")"
rm -f "$LAB/state/$TID.turn-ended" "$LAB/state/.wake-queue"
( cd "$P/plain-clone" && exec env -u NO_MISTAKES_GATE FM_POLL=2 ./bin/fm-watch.sh ) > "$P/watch.out" 2>&1 &
WPID=$!
for _ in $(seq 1 90); do kill -0 "$WPID" 2>/dev/null || break; sleep 1; done
if kill -0 "$WPID" 2>/dev/null; then kill -TERM "$WPID" 2>/dev/null; log "watcher still running after 90s; stopped"; fi
wait "$WPID" 2>/dev/null; log "watcher output:"; cat "$P/watch.out"
log "wake queue:"; cat "$LAB/state/.wake-queue" 2>/dev/null
grep -F "check: Herdr reboot launch recovery: REBOOT_RECOVERY: $TID: live launch is unmanaged" "$P/watch.out" >/dev/null \
  && grep -F "reboot-launch-recovery-" "$LAB/state/.wake-queue" >/dev/null \
  && ok "watcher woke with a queued check record for the unmanaged restore" || bad "watcher did not raise the reboot check wake"
[ "$(fg_pid)" = "$RPID" ] && ok "restored pid still unchanged after the watcher" || bad "watcher changed the restored agent"

step "done"; log "FAILED=$FAILED"
