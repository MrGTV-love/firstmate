#!/usr/bin/env bash
# tests/fm-omp-wake-restore-live-e2e.test.sh - the live omp injected-text guard
# (live-harness-optin family; task fm-omp-lane-wake-unsubmitted).
#
# Firstmate-injected text sat unsubmitted in an omp lane's box composer.
# These vendor behaviors are modeled by portable suites; the guard drives the
# INSTALLED omp in an isolated Herdr lab:
#   1. omp puts a queued user follow-up back into the composer when the run is
#      interrupted (Esc, as bin/fm-control.sh interrupt sends). A watcher wake
#      queued behind a running turn then sat in the composer, consumed by no
#      turn. The omp watch extension must submit it again on its own and leave
#      an operator draft exactly as typed.
#   2. While a turn runs, omp's box top border carries a spinner and the elapsed
#      time instead of its identity glyph. The shared classifier read that screen
#      as `unknown`, so a doorbell typed into a working lane (fm-send, the
#      restart persistence request) could never be seen as unsubmitted. A busy
#      composer must read empty or pending through the production Herdr adapter,
#      and the adapter's own submit must land the line.
#   3. A descendant omp (an `omp -p` child a turn runs) loads the same extensions
#      from the same directory. It used to overwrite state/.omp-turnend-extension-
#      loaded with its own, soon dead, pid; both markers must keep naming the
#      session that holds the lock.
#   4. omp leaves an explicit follow-up queued with no turn when it arrives at an
#      idle session whose context ends in an advisor note, so a wake reaching an
#      idle lane sat unread until someone pressed Enter. The watch extension must
#      start that wake's own turn and leave an operator draft unsent. This step
#      drives a scripted local model and spends no tokens.
#   5. Wake text an older wiring typed into an idle composer and never submitted
#      sat there until someone pressed Enter, and a lane restart that needs an
#      empty composer was refused. The watch extension must deliver that wake as
#      its own turn, clear only that wake, and leave an operator draft beside it
#      exactly as typed. Same scripted model, no tokens.
# omp's follow-up queue panel is redrawn only when omp itself queues or consumes a
# message, never for a follow-up an extension queued (omp 18.8.1: the panel stays
# empty while the wake is queued). The guard therefore reads two independent
# signals for "the wake is queued behind the running turn" and lets either carry:
# the panel, and omp's own hasPendingMessages() through a lab-only probe extension.
# The same probe records every change of the editor text: a restored wake sits in
# the composer for only a moment, and one rendered read takes seconds on a busy
# host, so the pane alone cannot be relied on to catch it.
# Steps 1-3 submit model prompts, so the guard is opt-in; it fails naming omp
# and `omp --version`. Refresh docs/verification/runtime-backends.md
# ("omp injected text" and "omp idle wake") from its output after any omp upgrade.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_OMP_WAKE_RESTORE_LIVE herdr jq omp python3

[ -x "$LAB_HELPER" ] || fail "FM_OMP_WAKE_RESTORE_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name omp-wake-restore)
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-wake-restore.XXXXXX")
PROJECT="$LAB/project"
CODE_ROOT="$LAB/code-root"
FAKEBIN="$LAB/fakebin"
PARENT="$LAB/parent"
REAL_OMP=$(PATH="$ORIGINAL_PATH" command -v omp)
MODEL=${FM_OMP_WAKE_RESTORE_LIVE_MODEL:-openai-codex/gpt-6-astra}
mkdir -p "$FAKEBIN"

# Every process the lab started (omp, its session-start supervisor, the watcher
# and its arm child) names the lab path on its command line.
reap_lab() {
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" -v me="$$" 'index($0, lab) && $1 != me { print $1 }'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" -v me="$$" 'index($0, lab) && $1 != me { print $1 }'); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local rc=$?
  [ -z "${TERMINAL_CONTROL_PID:-}" ] || kill "$TERMINAL_CONTROL_PID" 2>/dev/null || true
  trap - EXIT
  reap_lab
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
elif [ "\$n" -ne 2 ] || [ "\${args[0]}" != status ] || [ "\${args[1]}" != --json ]; then
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# The adapter does not provide the metadata dispatcher used by start_omp.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
set +e

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(env PATH="$ORIGINAL_PATH" FM_HOME="$PROJECT" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$PROJECT/state" FM_CONFIG_OVERRIDE="$PROJECT/config" FM_DATA_OVERRIDE="$PROJECT/data" omp --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
SUBJECT="omp ($VERSION) on $HERDR_VER"

# The tracked tree plus this working tree's pending edits, so the guard exercises
# the extensions and scripts under review rather than the last commit.
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] && [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
# Lab-only probe: omp's own queued-message and idle answers, and every change of
# the editor text, written where the guard can read them. omp's queue panel is not
# redrawn for an extension's queued follow-up, so the panel alone cannot say
# whether the wake is queued; and a restored wake sits in the composer for only
# a moment while each rendered read through the pane takes seconds on a busy host,
# so the pane alone cannot be relied on to catch it.
mkdir -p "$PROJECT/.omp/extensions"
cat > "$PROJECT/.omp/extensions/fm-lab-queue-probe.ts" <<'TS'
import { appendFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const out = resolve(dirname(fileURLToPath(import.meta.url)), "../../state/.lab-queue-probe");
const editorLog = resolve(dirname(fileURLToPath(import.meta.url)), "../../state/.lab-editor-log");
export default function (pi: { on?: (event: string, handler: (event: any, ctx: any) => unknown) => void }) {
  let ctx: any = null;
  const remember = (_event: unknown, context: unknown) => {
    if (typeof context === "object" && context !== null) ctx = context;
  };
  for (const event of ["session_start", "before_agent_start", "message_start", "agent_end"]) pi.on?.(event, remember);
  let lastEditor = "";
  const timer = setInterval(() => {
    try {
      const editor = String(ctx?.ui?.getEditorText?.() ?? "");
      if (editor !== lastEditor) {
        lastEditor = editor;
        appendFileSync(editorLog, `${Math.floor(Date.now() / 1000)} ${JSON.stringify(editor)}\n`);
      }
    } catch {}
    try {
      writeFileSync(out, `${Math.floor(Date.now() / 1000)} queued=${ctx?.hasPendingMessages?.() === true ? 1 : 0} idle=${ctx?.isIdle?.() === true ? 1 : 0}\n`);
    } catch {}
  }, 100);
  timer.unref();
}
TS
# The launching code root must be distinct from the secondmate home; the
# ordinary spawn interface deliberately refuses its own repository as a home.
cp -R "$PROJECT" "$CODE_ROOT" || fail "could not prepare the isolated launching code root"
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"

# The session overlay with the composer shape every lane that lost its pin shows.
BOX_OVERLAY="$LAB/box-overlay.yml"
sed 's/^  shape: borderless$/  shape: box/' "$ROOT/.omp/fm-session-overlay.yml" > "$BOX_OVERLAY"
cp "$BOX_OVERLAY" "$PROJECT/.omp/fm-session-overlay.yml"
cp "$BOX_OVERLAY" "$CODE_ROOT/.omp/fm-session-overlay.yml"
mkdir -p "$PARENT/state" "$PARENT/config" "$PARENT/data" "$PARENT/projects"
printf 'Live wake recovery lab: arm watcher when asked, perform only requested checks, and otherwise stay idle.\n' > "$PROJECT/data/charter.md"

PANE=
TARGET=
TERMINAL_CONTROL_PID=
WAKE_PROBE=0
WAKE_TASK=

screen() { lab pane read "$PANE" --source visible 2>/dev/null || true; }
send_text() { fm_backend_herdr_send_literal "$TARGET" "$1" >/dev/null; }
send_key() { fm_backend_herdr_send_key "$TARGET" "$1" >/dev/null || fail "$SUBJECT: could not send $1"; }
composer() { fm_backend_herdr_composer_state "$TARGET"; }
queue_rows() { grep -c . "$PROJECT/state/.wake-queue" 2>/dev/null || true; }

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

live_busy_class() {
  [ "$1" = "$TARGET" ] || { printf unknown; return; }
  [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] || { printf unknown; return; }
  # A box spinner is not a standalone rendered busy footer; use Herdr's
  # process-validated native state so a running sleep remains positively busy.
  fm_backend_herdr_busy_state "$TARGET"
}
is_idle() { [ "$(live_busy_class "$TARGET")" = idle ]; }
is_busy() { [ "$(live_busy_class "$TARGET")" = busy ]; }
queue_drained() { [ "$(queue_rows)" -eq 0 ]; }
composer_is() { [ "$(composer)" = "$1" ]; }

busy_composer_is() {
  is_busy || fail "$SUBJECT: the lane was not busy before the $1 composer probe"
  composer_is "$1" || return 1
  is_busy || fail "$SUBJECT: the lane was not busy after the $1 composer probe"
}

# start_omp <label>
start_omp() {
  local label=$1
  rm -f "$PROJECT/state/.wake-queue" "$PROJECT/state/.watch-cycle-exits.log" "$PROJECT/state"/wakelab*.status "$PROJECT/state"/wakelab*.meta "$PARENT/state/wakemate.meta"
  printf 'wakemate\n' > "$PROJECT/.fm-secondmate-home"
  printf '#!/usr/bin/env bash\nexec env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 %q "$@"\n' "$REAL_OMP" > "$FAKEBIN/omp"
  chmod +x "$FAKEBIN/omp"
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$CODE_ROOT" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_DATA_OVERRIDE="$PARENT/data" \
    HERDR_SESSION="$SESSION" "$PROJECT/bin/fm-spawn.sh" wakemate "$PROJECT" omp --secondmate \
    --backend herdr --model "$MODEL" --effort low > "$LAB/spawn-$label.out" 2>&1 \
    || fail "could not launch the ordinary omp secondmate for $label: $(cat "$LAB/spawn-$label.out")"
  TARGET=$(fm_backend_target_of_meta "$PARENT/state/wakemate.meta")
  PANE=${TARGET#*:}
  # Keep the fresh signal filename visible in the queue even when the isolated
  # worktree path is long; omp truncates each queued message to the viewport.
  lab terminal session control "$PANE" --cols 320 --rows 40 > "$LAB/terminal-control.log" 2>&1 &
  TERMINAL_CONTROL_PID=$!
  wait_for 120 is_idle || { screen >&2; fail "$SUBJECT never published settled task evidence for $label"; }
  sleep 2
  send_text 'Call the fm_watch_arm_omp tool exactly once now, then reply with only the word ARMED.'
  sleep 1
  send_key Enter
  wait_for 120 test -f "$PROJECT/state/.watch.lock/pid" || { screen >&2; fail "$SUBJECT never armed the watcher for $label"; }
  wait_for 120 is_idle || fail "$SUBJECT did not return to idle after arming for $label"
}

# busy_turn: start a long tool call so the lane is mid-turn.
busy_turn() {
  wait_for 120 is_idle || fail "the lane was not idle before a busy turn"
  # shellcheck disable=SC2016 # The backticks are literal prompt text for the model.
  send_text 'Run the bash command `sleep 90` and when it finishes reply DONE.'
  sleep 1
  send_key Enter
  wait_for 60 is_busy || { screen >&2; fail "the lane never showed a running turn"; }
  sleep 5
  is_busy || fail "$SUBJECT: the lane stopped running before the busy turn was ready"
}

# queue_wake: write a status line so the watcher wakes main while the turn runs,
# and wait until omp has queued the wake behind it.
queue_wake() {
  rm -f "$PROJECT/state/.watch-cycle-exits.log" "$PROJECT/state"/wakelab*.status "$PROJECT/state"/wakelab*.meta
  WAKE_PROBE=$((WAKE_PROBE + 1))
  WAKE_TASK="wakelab$WAKE_PROBE"
  : > "$PROJECT/state/$WAKE_TASK.meta"
  printf 'done: wake lab signal %s\n' "$WAKE_TASK" > "$PROJECT/state/$WAKE_TASK.status"
  wait_for 60 wake_is_queued \
    || { screen >&2; fail "$SUBJECT: $WAKE_TASK was not submitted into the running turn's follow-up queue (queue rows: $(queue_rows), probe: $(cat "$PROJECT/state/.lab-queue-probe" 2>/dev/null || echo none))"; }
}

wake_row_queued() {
  awk -F '\t' -v key="$WAKE_TASK.status" \
    '$3 == "signal" && $4 == key { found = 1 } END { exit !found }' \
    "$PROJECT/state/.wake-queue" 2>/dev/null
}

# omp's own answer through the lab probe: fresh, and reporting queued messages.
probe_says_queued() {
  local line stamp now
  line=$(cat "$PROJECT/state/.lab-queue-probe" 2>/dev/null) || return 1
  stamp=${line%% *}
  now=$(date +%s)
  case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - stamp)) -le 3 ] || return 1
  case "$line" in *" queued=1 "*) return 0 ;; esac
  return 1
}

# omp's queue panel; it names the wake only once omp has redrawn it.
panel_shows_wake() {
  local queued
  queued=$(screen | awk '
    /After yield.*[1-9][0-9]*/ { in_queue = 1; next }
    in_queue && /to edit/ { printf "%s", rows; exit }
    in_queue { rows = rows $0 }
  ' | tr -d '[:space:]')
  case "$queued" in
    *"FIRSTMATEWATCHERWAKE:"*"$WAKE_TASK.status"*) return 0 ;;
  esac
  return 1
}

# The watcher wrote the wake while the turn ran, and either independent signal
# says omp holds a queued follow-up (this wake, or another watcher wake already
# in line behind the turn).
wake_is_queued() {
  is_busy || return 1
  wake_row_queued || return 1
  probe_says_queued || panel_shows_wake || return 1
  is_busy && wake_row_queued
}

# omp's own record that Escape restored a watcher wake into its editor: the probe
# logs every change of the editor text, so a restoration that lasts a moment cannot
# fall between the pane reads below. Any watcher wake counts, not only this task's
# signal: the lane also receives the secondmate's own outcome checks, one of which
# can already be queued when the signal arrives. Every wake is tracked and
# restored alike. RESTORE_BASE marks the log before Escape, and RESTORE_DRAFT
# (when set) must sit in the same editor text as the wake.
RESTORE_BASE=0
RESTORE_DRAFT=
editor_log_lines() { echo $(( $(wc -l < "$PROJECT/state/.lab-editor-log" 2>/dev/null || echo 0) )); }
editor_log_restored_wake() {
  local entries
  entries=$(tail -n +"$((RESTORE_BASE + 1))" "$PROJECT/state/.lab-editor-log" 2>/dev/null | grep -F 'FIRSTMATE WATCHER WAKE') || return 1
  [ -z "$RESTORE_DRAFT" ] || printf '%s\n' "$entries" | grep -F -- "$RESTORE_DRAFT" >/dev/null
}

wake_is_restored() {
  local content draft
  editor_log_restored_wake && return 0
  composer_is pending || return 1
  content=$(fm_backend_herdr_composer_content "$TARGET" '') || return 1
  content=$(printf '%s' "$content" | tr -d '[:space:]')
  case "$content" in
    *"FIRSTMATEWATCHERWAKE:"*) ;;
    *) return 1 ;;
  esac
  draft=$(printf '%s' "$RESTORE_DRAFT" | tr -d '[:space:]')
  case "$content" in
    *"$draft"*) return 0 ;;
    *) return 1 ;;
  esac
}

interrupt_queued_wake() {
  local draft=${1:-} attempt poll content
  for attempt in 1 2 3; do
    busy_turn
    if [ -n "$draft" ]; then
      send_text "$draft"
      sleep 1
    fi
    queue_wake
    RESTORE_BASE=$(editor_log_lines)
    RESTORE_DRAFT=$draft
    send_key Escape
    for ((poll = 0; poll < 50; poll++)); do
      wake_is_restored && return 0
      sleep 0.1
    done
    [ "$attempt" -lt 3 ] || break
    wait_for 90 queue_drained \
      || { screen >&2; fail "$SUBJECT: unobserved $WAKE_TASK did not drain before a fresh restoration attempt"; }
    wait_for 120 is_idle || fail "$SUBJECT: the lane did not settle before a fresh restoration attempt"
    content=$(fm_backend_herdr_composer_content "$TARGET" '') \
      || fail "$SUBJECT: could not read the composer before a fresh restoration attempt"
    [ "$content" = "$draft" ] \
      || fail "$SUBJECT: unexpected composer text before a fresh restoration attempt: '$content'"
    if [ -n "$draft" ]; then
      send_key C-u
    fi
    wait_for 20 composer_is empty || fail "$SUBJECT: the composer was not empty before a fresh restoration attempt"
  done
  screen >&2
  fail "$SUBJECT: no fresh wake was observed restored into a pending composer after Escape in 3 attempts"
}

# ---------------------------------------------------------------------------
# Session I: a wake that reaches an idle lane behind an advisor note starts its
# own turn. A scripted local model answers every request with "ack", except that
# the advisor gets one `advise` tool call, so the advisor posts its note after
# the turn ends exactly as it did on the stalled lanes. The session uses the
# extension under review with a stand-in arm script that closes on a trigger file.
# ---------------------------------------------------------------------------
IDLE="$LAB/idle"
mkdir -p "$IDLE/agent" "$IDLE/home/.omp/extensions" "$IDLE/home/.pi/extensions/lib" "$IDLE/home/bin" "$IDLE/home/state"
cp "$PROJECT/.omp/extensions/fm-primary-omp-watch.ts" "$IDLE/home/.omp/extensions/"
cp "$PROJECT/.pi/extensions/lib/fm-operational-input.ts" "$IDLE/home/.pi/extensions/lib/"
cp "$PROJECT/bin/fm-operational-input.sh" "$IDLE/home/bin/"
cat > "$IDLE/home/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon 0s) recovery-generation=gen-1\n' "$$"
while :; do
  for f in "$FM_HOME"/state/idle-trigger-*; do
    [ -e "$f" ] || continue
    rm -f "$f"
    printf 'signal: %s\n' "${f##*/}"
    exit 0
  done
  sleep 0.5
done
SH
chmod +x "$IDLE/home/bin/"*.sh
git -C "$IDLE/home" init -q
cat > "$IDLE/model.py" <<'PY'
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
log_path, port_path = sys.argv[1], sys.argv[2]
advised = False
def text(message):
    content = message.get("content")
    if isinstance(content, list):
        return " ".join(part.get("text", "") for part in content if isinstance(part, dict))
    return content if isinstance(content, str) else ""
class Model(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        global advised
        request = json.loads(self.rfile.read(int(self.headers.get("content-length", 0))) or b"{}")
        messages = request.get("messages", [])
        tools = [tool.get("function", {}).get("name") for tool in request.get("tools", [])]
        advise = not advised and "advise" in tools and any("IDLE-LAB-ADVISE" in text(m) for m in messages)
        advised = advised or advise
        with open(log_path, "a") as log:
            log.write(json.dumps({"advise": advise, "text": " ".join(text(m) for m in messages)}) + "\n")
        if advise:
            call = {"index": 0, "id": "call_advise", "type": "function", "function": {"name": "advise", "arguments": json.dumps({"note": "IDLE-LAB-NOTE verify before finishing.", "severity": "concern"})}}
            deltas, finish = [{"role": "assistant", "tool_calls": [call]}], "tool_calls"
        else:
            deltas, finish = [{"role": "assistant", "content": "ack"}], "stop"
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        chunk = {"id": "lab", "object": "chat.completion.chunk", "created": int(time.time()), "model": "m1"}
        for delta in deltas + [{}]:
            body = dict(chunk, choices=[{"index": 0, "delta": delta, "finish_reason": None if delta else finish}])
            self.wfile.write(b"data: " + json.dumps(body).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
server = ThreadingHTTPServer(("127.0.0.1", 0), Model)
with open(port_path, "w") as port_file:
    port_file.write(str(server.server_address[1]))
server.serve_forever()
PY
python3 -I "$IDLE/model.py" "$IDLE/model.log" "$IDLE/model.port" &
wait_for 20 test -s "$IDLE/model.port" || fail "the scripted local model did not start"
cat > "$IDLE/agent/config.yml" <<YML
setupVersion: 2
modelRoles:
  default: lab/m1
  tiny: lab/m1
  advisor: lab/m1
  vision: lab/m1
advisor:
  enabled: true
YML
cat > "$IDLE/agent/models.yml" <<YML
providers:
  lab:
    baseUrl: http://127.0.0.1:$(cat "$IDLE/model.port")/v1
    apiKey: lab-key
    api: openai-completions
    models:
      - id: m1
        contextWindow: 200000
        maxTokens: 4096
YML
IDLE_PANE=$(lab workspace create --cwd "$IDLE/home" --label idle-wake --no-focus | jq -r '.result.root_pane.pane_id // empty')
[ -n "$IDLE_PANE" ] || fail "could not create the idle-wake lab pane"
# The pid written to state/.lock is the omp the shell execs, so the extension
# owns the lock and arms at session_start without a model turn.
lab pane run "$IDLE_PANE" "bash -c 'printf \"%s\\n\" \$\$ > $IDLE/home/state/.lock; exec env FM_HOME=$IDLE/home PI_CODING_AGENT_DIR=$IDLE/agent $REAL_OMP --model lab/m1'" >/dev/null \
  || fail "could not start omp in the idle-wake lab pane"
idle_screen() { lab pane read "$IDLE_PANE" --source visible 2>/dev/null || true; }
model_saw() { grep -F -- "$1" "$IDLE/model.log" >/dev/null 2>&1; }
note_posted() { idle_screen | grep -F 'IDLE-LAB-NOTE' >/dev/null; }
wait_for 60 test -s "$IDLE/home/state/.omp-watch-extension-loaded" \
  || { idle_screen >&2; fail "$SUBJECT: the idle-wake session never loaded the watch extension"; }
sleep 3
lab pane send-text "$IDLE_PANE" 'IDLE-LAB-ADVISE reply ack' >/dev/null
sleep 1
lab pane send-keys "$IDLE_PANE" Enter >/dev/null
wait_for 60 note_posted || { idle_screen >&2; fail "$SUBJECT: the advisor note never posted after the turn"; }
sleep 5
lab pane send-text "$IDLE_PANE" 'operator draft kept' >/dev/null
sleep 2
: > "$IDLE/home/state/idle-trigger-advisor-tail"
wait_for 20 model_saw 'FIRSTMATE WATCHER WAKE: signal: idle-trigger-advisor-tail' \
  || { idle_screen >&2; fail "$SUBJECT: a wake reaching an idle lane behind an advisor note did not start a turn"; }
sleep 3
model_saw 'operator draft kept' && fail "$SUBJECT: the operator draft was submitted with the idle wake"
idle_screen | grep -F 'operator draft kept' >/dev/null \
  || { idle_screen >&2; fail "$SUBJECT: the operator draft did not stay in the composer"; }
pass "live omp idle wake: $SUBJECT started its own turn for a wake that reached an idle lane behind an advisor note and left the operator draft unsent"

# ---------------------------------------------------------------------------
# Session I, second step: wake text an older wiring typed into the idle composer
# and never submitted. It is built from the operational-input owner's legacy wake
# shape and encoder, typed without Enter, beside an operator draft.
# ---------------------------------------------------------------------------
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
OLD_WAKE_MESSAGE='stale: old-wiring-lane wake left in the composer'
fm_operational_input_encode watcher "${FM_LEGACY_WATCHER_PREFIX}${OLD_WAKE_MESSAGE}${FM_LEGACY_WATCHER_SUFFIX}" OLD_WAKE \
  || fail "could not encode the older-wiring wake"
idle_composer() { fm_backend_herdr_composer_content "$SESSION:$IDLE_PANE" ''; }
draft_cleared() {
  local content
  content=$(idle_composer) || return 1
  [ -z "$content" ]
}
lab pane send-keys "$IDLE_PANE" ctrl+u >/dev/null
wait_for 10 draft_cleared \
  || { idle_screen >&2; fail "$SUBJECT: could not clear the idle-wake draft before the stranded-wake step"; }
lab pane send-text "$IDLE_PANE" "${OLD_WAKE}"$'\n\n'"operator draft beside the wake" >/dev/null
wait_for 40 model_saw "$OLD_WAKE_MESSAGE" \
  || { idle_screen >&2; fail "$SUBJECT: wake text left unsent in an idle composer was never delivered"; }
sleep 3
model_saw 'operator draft beside the wake' && fail "$SUBJECT: the operator draft was submitted with the stranded wake"
draft=$(idle_composer) \
  || { idle_screen >&2; fail "$SUBJECT: could not read the full composer after the stranded wake was delivered"; }
[ "$draft" = 'operator draft beside the wake' ] \
  || { idle_screen >&2; fail "$SUBJECT: the stranded wake recovery did not leave exactly the operator draft, composer now holds: '$draft'"; }
pass "live omp stranded wake: $SUBJECT delivered wake text an older wiring left unsent in an idle composer as its own turn, cleared only that wake, and left the operator draft as typed"
lab pane close "$IDLE_PANE" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Session A: the extension recovers a restored wake by itself.
# ---------------------------------------------------------------------------
start_omp wake-ext

interrupt_queued_wake
wait_for 90 queue_drained \
  || { screen >&2; fail "$SUBJECT: a wake restored to the composer by Esc was never submitted again (queue rows: $(queue_rows))"; }
wait_for 60 composer_is empty \
  || fail "$SUBJECT: the composer still holds text after the wake was submitted again: $(composer)"
pass "live omp wake restore: $SUBJECT re-submitted a wake that Esc restored to the composer, and the lane handled it"

# An operator draft typed while the wake was queued survives the recovery.
wait_for 120 is_idle || fail "the lane did not settle after handling the wake"
interrupt_queued_wake 'operator draft kept'
draft_alone() { [ "$(fm_backend_herdr_composer_content "$TARGET" '')" = 'operator draft kept' ]; }
wait_for 60 draft_alone \
  || { screen >&2; fail "$SUBJECT: the wake restored next to an operator draft was never taken out of the composer, which holds: '$(fm_backend_herdr_composer_content "$TARGET" '')'"; }
wait_for 90 queue_drained \
  || { screen >&2; fail "$SUBJECT: the wake restored next to an operator draft was never submitted again"; }
draft=$(fm_backend_herdr_composer_content "$TARGET" '')
[ "$draft" = 'operator draft kept' ] \
  || fail "$SUBJECT: the operator draft was changed by the recovery, composer now holds: '$draft'"
pass "live omp wake restore: $SUBJECT left the operator's draft exactly as typed while it re-submitted the wake"
send_key C-u
wait_for 20 composer_is empty || fail "$SUBJECT: could not clear the draft"

# The descendant omp child must not take over the markers.
wait_for 120 is_idle || fail "the lane did not settle before the child probe"
rm -f "$LAB/child-omp.ok" "$LAB/child-omp.out"
send_text "Run this exact bash command and then reply CHILD_DONE: env FM_HOME='$PROJECT' FM_ROOT_OVERRIDE='$PROJECT' FM_STATE_OVERRIDE='$PROJECT/state' FM_CONFIG_OVERRIDE='$PROJECT/config' FM_DATA_OVERRIDE='$PROJECT/data' omp --print 'reply with the word hi' --no-session --thinking low --model $MODEL > '$LAB/child-omp.out' 2>&1 && read -r lock_pid < '$PROJECT/state/.lock' && [ \"\$(sed -n 2p '$PROJECT/state/.omp-turnend-extension-loaded')\" = \"\$lock_pid\" ] && [ \"\$(sed -n 2p '$PROJECT/state/.omp-watch-extension-loaded')\" = \"\$lock_pid\" ] && printf 'child-omp-pre-parent-repair-owner-ok\n' > '$LAB/child-omp.ok'"
sleep 1
send_key Enter
wait_for 60 is_busy || fail "the lane never showed a running turn for the child probe"
wait_for 180 is_idle || fail "the lane did not settle after the child probe"
[ "$(cat "$LAB/child-omp.ok" 2>/dev/null)" = child-omp-pre-parent-repair-owner-ok ] \
  || { cat "$LAB/child-omp.out" >&2 2>/dev/null; fail "$SUBJECT: the descendant omp did not prove both loaded marker PIDs matched the session lock PID before parent repair"; }
lock_pid=$(sed -n 1p "$PROJECT/state/.lock")
for marker in .omp-turnend-extension-loaded .omp-watch-extension-loaded; do
  [ "$(sed -n 2p "$PROJECT/state/$marker")" = "$lock_pid" ] \
    || fail "$SUBJECT: a descendant omp left $marker naming '$(sed -n 2p "$PROJECT/state/$marker")' instead of the session pid $lock_pid"
done
pass "live omp markers: $SUBJECT kept both loaded markers on the session pid $lock_pid before parent repair and after the parent resumed"

# ---------------------------------------------------------------------------
# A working lane's composer is readable, so injected text is detected and lands.
# ---------------------------------------------------------------------------
wait_for 120 is_idle || fail "the lane did not settle before the busy composer checks"
busy_turn
busy_composer_is empty || fail "$SUBJECT: a working lane's empty box composer read '$(composer)', not empty"
send_text 'unsent line typed while busy'
sleep 1
busy_composer_is pending || { screen >&2; fail "$SUBJECT: a line typed into a working lane's composer read '$(composer)', not pending"; }
send_key C-u
wait_for 20 busy_composer_is empty || fail "$SUBJECT: could not clear the busy draft"
pass "live omp busy composer: $SUBJECT reads empty and pending while a turn runs"

doorbell=": Firstmate operational input waiting: read '$LAB/none.msg' and handle its contents as Firstmate operational input."
is_busy || fail "$SUBJECT: the lane was not busy immediately before the adapter submission"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$doorbell" 3 0.4 0.3)
case "$verdict" in
  empty|unknown) ;;
  *) fail "$SUBJECT: the adapter's submit into a working lane reported '$verdict'" ;;
esac
wait_for 20 busy_composer_is empty \
  || { screen >&2; fail "$SUBJECT: an injected doorbell stayed in a working lane's composer (read '$(composer)')"; }
pass "live omp busy composer: $SUBJECT took an injected doorbell mid-turn and left the composer empty"
