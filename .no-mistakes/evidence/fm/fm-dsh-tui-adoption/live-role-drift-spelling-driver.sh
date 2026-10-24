#!/usr/bin/env bash
# Disposable live driver (test-phase evidence, not a repo test): a real dsh-tui
# secondmate in a named Herdr lab, then config-role resume, config drift
# refusal before stop, and explicit --model role:<r> on control and direct spawn.
# Copied from run 01M5N4DEJQJWSY8WRH9MTTCX2K and extended for this head with
# mixed-spelling (DeepSeek/<id>, ' DeepSeek / <id> ') spawn, config and relaunch cases.
# Run 01M5P6CVQGQ910WB76XD4XBACG (head 857198c1b) adds S-RETIRED-CONTROL: a padded
# spelling of an id the index retires refuses a live control relaunch before the stop.
set -eu
ROOT=$1            # gate worktree
TASK=$2            # scratch dir for homes/state
OPH=$3             # disposable operator home holding .dsh-tui/model.json
cd "$ROOT"
M=$(python3 "$ROOT/bin/fm-dsh.py" preferred-model "$OPH")
echo "model resolved at run time: $M"
MIXED="DeepSeek/${M#deepseek/}"
SPACED=" DeepSeek / ${M#deepseek/} "
echo "mixed spellings: [$MIXED] [$SPACED]"
HELPER=$ROOT/bin/fm-herdr-lab.sh
LAB_HELPER=$ROOT/bin/fm-lab-home.sh
ORIGINAL_PATH=$PATH
mkdir -p "$TASK/bin"
export FM_HERDR_LAB_STATE_DIR="$TASK/herdr-safety"
SESSION=$("$HELPER" name dsh-role)
echo "herdr lab session: $SESSION"
PARENT=$(mktemp -d /tmp/fm-dsh-rparent.XXXXXX); PARENT=$(cd "$PARENT" && pwd -P)
SECOND=$(mktemp -d /tmp/fm-dsh-rsecond.XXXXXX); SECOND=$(cd "$SECOND" && pwd -P)
. "$ROOT/tests/fm-dsh-live-cleanup.sh"
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$HELPER" teardown "$SESSION" || rc=1
  for home in "$PARENT" "$SECOND"; do
    [ -d "$home/state" ] || continue
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" bash "$ROOT/bin/fm-watch-arm.sh" --stop || rc=1
  done
  fm_dsh_live_scrub_credentials "$PARENT" "$SECOND" || rc=1
  left=$(find "$PARENT" "$SECOND" -name '.credentials.yaml' 2>/dev/null | wc -l | tr -d ' ')
  echo "credential copies left under task homes after scrub: $left"
  [ "$left" = 0 ] || rc=1
  printf 'parent_home=%s\nsecondmate_home=%s\ncleanup_exit=%s\n' "$PARENT" "$SECOND" "$rc"
  exit "$rc"
}
trap cleanup EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
"$LAB_HELPER" create "$PARENT"
"$LAB_HELPER" create "$SECOND"
printf 'manual\n' > "$PARENT/config/backlog-backend"
printf 'herdr\n' > "$PARENT/config/runtime-backend"
printf 'dsh\n' > "$PARENT/config/crew-harness"
printf 'off\n' > "$PARENT/config/supervision-host-off"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$PARENT/data/backlog.md"
SID="dsh-role-$$"
mkdir "$SECOND/operator-home"
printf '%s\n' "$SID" > "$SECOND/.fm-secondmate-home"
git init -q "$SECOND"
cp "$ROOT/AGENTS.md" "$SECOND/AGENTS.md"
ln -s "$ROOT/bin" "$SECOND/bin"; ln -s "$ROOT/.agents" "$SECOND/.agents"; ln -s "$ROOT/docs" "$SECOND/docs"
printf 'manual\n' > "$SECOND/config/backlog-backend"
printf 'herdr\n' > "$SECOND/config/runtime-backend"
printf 'off\n' > "$SECOND/config/supervision-host-off"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$SECOND/data/backlog.md"
printf '%s\n' 'This is an isolated Firstmate runtime lab secondmate, not real operational work. Do not investigate, read outside this home, load skills, edit code or dispatch work. Ignore startup diagnostics. Remember the word LILAC58 only in this conversation, then reply exactly FMROLEREADY. Later instructions will ask you to reply with a marker word and the secret word; answer them without inspecting files or running commands.' > "$SECOND/data/charter.md"
cat > "$TASK/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
[ "\$*" != 'status --json' ] || exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' status --json
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || { echo 'role lab refuses an unscoped Herdr call' >&2; exit 98; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH='$ORIGINAL_PATH' '$HELPER' run '$SESSION' "\${args[@]}"
EOF
chmod +x "$TASK/bin/herdr"
"$HELPER" provision "$SESSION"
export PATH="$TASK/bin:$ORIGINAL_PATH"
lab() { PATH="$ORIGINAL_PATH" "$HELPER" run "$SESSION" "$@"; }
penv() { env FM_POLL=1 FM_CHECK_INTERVAL=1 FM_DSH_OPERATOR_HOME="$SECOND/operator-home" HERDR_SESSION="$SESSION" FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$PARENT/state" FM_CONFIG_OVERRIDE="$PARENT/config" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=30 "$@"; }
control() { penv bash "$ROOT/bin/fm-control.sh" "$@"; }
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/backends/herdr.sh"
dstate() { python3 "$ROOT/bin/fm-dsh.py" state "$PARENT/state" "$SID"; }
assistant_has() {
  python3 - "$LOG" "$1" <<'PY'
import json,sys
for line in open(sys.argv[1]):
    try: event=json.loads(line)
    except ValueError: continue
    if event.get('type') != 'assistant/message': continue
    content=event.get('data',{}).get('message',{}).get('content',[])
    text='\n'.join(part.get('text','') for part in content if part.get('type') == 'text')
    if all(token in text for token in sys.argv[2].split()): sys.exit(0)
sys.exit(1)
PY
}
wait_reply() { local i=0; while [ "$i" -lt 180 ]; do assistant_has "$1" && { echo "observed reply: $1"; return 0; }; sleep 1; i=$((i + 1)); done; lab pane read "$PANE" --source visible; echo "never saw reply: $1" >&2; return 1; }
wait_idle() { local i; for i in $(seq 1 120); do [ "$(dstate)" = idle ] && return 0; sleep 1; done; echo "never idle: $(dstate)" >&2; return 1; }
wait_composer_empty() { local i; for i in $(seq 1 60); do [ "$(fm_backend_herdr_composer_state "$SESSION:$PANE")" = empty ] && return 0; sleep 1; done; return 0; }
ask() {  # <marker>: type a question into the live pane once it is idle, then wait for the answer
  wait_idle || true
  wait_composer_empty
  lab pane send-text "$PANE" "Reply $1 and the secret word remembered earlier. Do not inspect files or run commands."
  lab pane send-keys "$PANE" enter
  wait_reply "$1 LILAC58"
}
binding_root() { jq -r .root "$PARENT/state/$SID.dsh-session"; }
meta() { sed -n "s/^$1=//p" "$PARENT/state/$SID.meta"; }

echo "=== S-SPELLING-META: spawn a fresh dsh secondmate with --model '$MIXED' --effort high"
penv bash "$ROOT/bin/fm-spawn.sh" "$SID" "$SECOND" dsh --secondmate --backend herdr --model "$MIXED" --effort high
PANE=$(meta herdr_pane_id)
LOG=$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")
GEN=$(binding_root)
echo "bound: model=$(meta model) effort=$(meta effort) generation=$GEN log=$LOG"
[ "$(meta model)" = "$M" ] || { echo "S-SPELLING-META FAIL: meta recorded model=$(meta model), not canonical $M" >&2; exit 1; }
echo "ok - S-SPELLING-META: mixed-spelling spawn recorded canonical model=$(meta model)"
wait_reply FMROLEREADY
wait_idle

echo "=== S-RETIRED-CONTROL: fm-control relaunch --model '$SPACED' while the model index retires ${M#deepseek/}"
printf '{"version":1,"roles":{},"retired":["%s"]}\n' "${M#deepseek/}" > "$PARENT/config/model-index.json"
wait_composer_empty
rb_bytes=$(wc -c < "$LOG" | tr -d ' ')
cp "$LOG" "$TASK/S-RETIRED-CONTROL.log-before"
rb_meta=$(shasum "$PARENT/state/$SID.meta" | cut -d' ' -f1)
rb_journal=$(cat "$PARENT/state/$SID.control-relaunch" 2>/dev/null | shasum | cut -d' ' -f1)
echo "S-RETIRED-CONTROL: before agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE") log_bytes=$rb_bytes meta_sha=$rb_meta"
set +e; out=$(control "$SID" relaunch --model "$SPACED" 2>&1); rc=$?; set -e
echo "S-RETIRED-CONTROL: control relaunch exit=$rc"
printf '%s\n' "$out" | sed 's/^/    | /'
[ "$rc" -ne 0 ] || { echo 'S-RETIRED-CONTROL FAIL: a padded retired id relaunched' >&2; exit 1; }
case "$out" in *"retired model: $M"*) ;; *) echo "S-RETIRED-CONTROL FAIL: refusal does not name the retired canonical id $M" >&2; exit 1 ;; esac
case "$out" in *'could not be launched'*|*'was stopped'*) echo 'S-RETIRED-CONTROL FAIL: refusal came after the stop' >&2; exit 1 ;; esac
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" != dead ] || { echo 'S-RETIRED-CONTROL FAIL: agent was stopped' >&2; exit 1; }
[ "$(binding_root)" = "$GEN" ] || { echo 'S-RETIRED-CONTROL FAIL: generation replaced' >&2; exit 1; }
[ -s "$LOG" ] && head -c "$rb_bytes" "$LOG" | cmp - "$TASK/S-RETIRED-CONTROL.log-before" || { echo 'S-RETIRED-CONTROL FAIL: conversation bytes changed or log lost' >&2; exit 1; }
[ "$(find "$PARENT/state/$SID.dsh" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 ] || { echo 'S-RETIRED-CONTROL FAIL: a second generation appeared' >&2; exit 1; }
[ "$(shasum "$PARENT/state/$SID.meta" | cut -d' ' -f1)" = "$rb_meta" ] || { echo 'S-RETIRED-CONTROL FAIL: meta changed' >&2; exit 1; }
[ "$(cat "$PARENT/state/$SID.control-relaunch" 2>/dev/null | shasum | cut -d' ' -f1)" = "$rb_journal" ] || { echo 'S-RETIRED-CONTROL FAIL: relaunch journal changed' >&2; exit 1; }
echo "S-RETIRED-CONTROL: after agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE") generation=$(binding_root) meta, journal and earlier conversation bytes unchanged"
lab pane send-text "$PANE" 'Reply FMRETIREDALIVE and the secret word remembered earlier. Do not inspect files or run commands.'
lab pane send-keys "$PANE" enter
wait_reply 'FMRETIREDALIVE LILAC58'
wait_idle
echo "ok - S-RETIRED-CONTROL: padded retired spelling refused before stop naming $M; the same live agent answered with the secret"

printf '{"version":1,"roles":{"fmlabbound":{"dsh":{"model":"%s"}},"fmlabdrift":{"dsh":{"model":"%s-fmlabdrift"}}},"retired":[]}\n' "$M" "$M" > "$PARENT/config/model-index.json"
echo "model index roles: fmlabbound -> $M ; fmlabdrift -> $M-fmlabdrift (never launched)"

echo '=== S-ROLE: config/secondmate-harness "dsh role:fmlabbound" agrees with the binding; plain relaunch must resume'
printf 'dsh role:fmlabbound\n' > "$PARENT/config/secondmate-harness"
wait_composer_empty
BEFORE=$(wc -c < "$LOG")
control "$SID" relaunch --note 'Reply FMROLERESUMED and the secret word remembered earlier. Do not inspect files or run commands.'
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")" = "$LOG" ] || { echo 'S-ROLE FAIL: plain relaunch changed the session log' >&2; exit 1; }
[ "$(binding_root)" = "$GEN" ] || { echo 'S-ROLE FAIL: plain relaunch replaced the generation' >&2; exit 1; }
ask FMROLERESUMED
[ "$(wc -c < "$LOG")" -gt "$BEFORE" ]
[ "$(meta model)" = "$M" ] && [ "$(meta effort)" = high ] || { echo "S-ROLE FAIL: meta now model=$(meta model) effort=$(meta effort)" >&2; exit 1; }
echo "ok - S-ROLE: config role resolving to the bound model resumed the same generation $GEN and conversation (secret recalled), effort=$(meta effort)"
wait_idle

drift_probe() {  # <label> <secondmate-harness line>
  local label=$1 line=$2 before_bytes before_meta before_journal out rc pane_state
  printf '%s\n' "$line" > "$PARENT/config/secondmate-harness"
  wait_composer_empty
  before_bytes=$(wc -c < "$LOG" | tr -d ' ')
  cp "$LOG" "$TASK/$label.log-before"
  before_meta=$(shasum "$PARENT/state/$SID.meta" | cut -d' ' -f1)
  before_journal=$(cat "$PARENT/state/$SID.control-relaunch" 2>/dev/null | shasum | cut -d' ' -f1)
  pane_state=$(fm_backend_agent_state herdr "$SESSION:$PANE")
  echo "$label: before refusal agent_state=$pane_state log_bytes=$before_bytes"
  set +e; out=$(control "$SID" relaunch 2>&1); rc=$?; set -e
  echo "$label: control relaunch exit=$rc"
  printf '%s\n' "$out" | sed 's/^/    | /'
  [ "$rc" -ne 0 ] || { echo "$label FAIL: drifted config relaunch did not refuse" >&2; exit 1; }
  case "$out" in *'a plain relaunch would discard that conversation'*'The running agent was not stopped'*) ;; *) echo "$label FAIL: refusal text missing" >&2; exit 1 ;; esac
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" != dead ] || { echo "$label FAIL: agent was stopped" >&2; exit 1; }
  [ "$(binding_root)" = "$GEN" ] || { echo "$label FAIL: generation replaced" >&2; exit 1; }
  # The live agent may append (the lab's own supervision prompts); the existing
  # conversation must survive byte-for-byte in the same file and generation.
  [ -s "$LOG" ] && head -c "$before_bytes" "$LOG" | cmp - "$TASK/$label.log-before" || { echo "$label FAIL: earlier conversation bytes changed or log lost" >&2; exit 1; }
  [ "$(find "$PARENT/state/$SID.dsh" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" = 1 ] || { echo "$label FAIL: a second generation appeared" >&2; exit 1; }
  [ "$(shasum "$PARENT/state/$SID.meta" | cut -d' ' -f1)" = "$before_meta" ] || { echo "$label FAIL: meta changed" >&2; exit 1; }
  # A finished relaunch keeps its journal; a refusal before the stop must leave it byte-identical.
  [ "$(cat "$PARENT/state/$SID.control-relaunch" 2>/dev/null | shasum | cut -d' ' -f1)" = "$before_journal" ] || { echo "$label FAIL: relaunch transaction journal changed" >&2; exit 1; }
  echo "$label: after refusal agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE") log_bytes=$(wc -c < "$LOG" | tr -d ' ') (first $before_bytes bytes identical) single generation, meta and journal unchanged"
  # The same live agent still answers in the same conversation.
  lab pane send-text "$PANE" "Reply $3 and the secret word remembered earlier. Do not inspect files or run commands."
  lab pane send-keys "$PANE" enter
  wait_reply "$3 LILAC58"
  wait_idle
  echo "ok - $label: drift refused before stop; the same live agent answered $3 with the secret"
}
echo '=== S-DRIFT-MODEL: config names a different model'
drift_probe S-DRIFT-MODEL 'dsh role:fmlabdrift' FMDRIFTMODELALIVE
echo '=== S-DRIFT-EFFORT: config names the bound model but a different effort'
drift_probe S-DRIFT-EFFORT 'dsh role:fmlabbound max' FMDRIFTEFFORTALIVE

echo '=== S-EXPLICIT-CONTROL: fm-control relaunch --model role:fmlabbound, no --effort'
printf 'dsh role:fmlabbound\n' > "$PARENT/config/secondmate-harness"
wait_composer_empty
control "$SID" relaunch --model role:fmlabbound --note 'Reply FMCTLROLE and the secret word remembered earlier. Do not inspect files or run commands.'
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")" = "$LOG" ] && [ "$(binding_root)" = "$GEN" ] || { echo 'S-EXPLICIT-CONTROL FAIL: conversation replaced' >&2; exit 1; }
ask FMCTLROLE
[ "$(meta effort)" = high ] && [ "$(meta model)" = "$M" ] || { echo "S-EXPLICIT-CONTROL FAIL: meta model=$(meta model) effort=$(meta effort)" >&2; exit 1; }
echo "ok - S-EXPLICIT-CONTROL: role resolving to bound model kept effort=$(meta effort), same generation and conversation"
wait_idle

echo '=== S-EXPLICIT-SPAWN: direct fm-spawn --relaunch --model role:fmlabbound, no --effort'
wait_composer_empty
control "$SID" exit
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo 'exit did not stop the secondmate' >&2; exit 1; }
BEFORE=$(wc -c < "$LOG")
penv bash "$ROOT/bin/fm-spawn.sh" "$SID" --relaunch --model role:fmlabbound
PANE=$(meta herdr_pane_id)
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")" = "$LOG" ] && [ "$(binding_root)" = "$GEN" ] || { echo 'S-EXPLICIT-SPAWN FAIL: conversation replaced' >&2; exit 1; }
[ "$(meta effort)" = high ] && [ "$(meta model)" = "$M" ] || { echo "S-EXPLICIT-SPAWN FAIL: meta model=$(meta model) effort=$(meta effort)" >&2; exit 1; }
for _ in $(seq 1 120); do s=$(dstate); case "$s" in idle) break ;; esac; sleep 1; done
wait_composer_empty
lab pane send-text "$PANE" 'Reply FMSPAWNROLE and the secret word remembered earlier. Do not inspect files or run commands.'
lab pane send-keys "$PANE" enter
wait_reply 'FMSPAWNROLE LILAC58'
[ "$(wc -c < "$LOG")" -gt "$BEFORE" ]
echo "ok - S-EXPLICIT-SPAWN: direct spawn role relaunch kept effort=$(meta effort), same generation and conversation"
echo "=== S-SPELLING-CONFIG: config/secondmate-harness 'dsh $MIXED'; plain fm-control relaunch must resume, not refuse"
printf 'dsh %s\n' "$MIXED" > "$PARENT/config/secondmate-harness"
wait_idle
wait_composer_empty
BEFORE=$(wc -c < "$LOG")
control "$SID" relaunch --note 'Reply FMSPELLCFG and the secret word remembered earlier. Do not inspect files or run commands.'
PANE=$(meta herdr_pane_id)
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")" = "$LOG" ] && [ "$(binding_root)" = "$GEN" ] || { echo 'S-SPELLING-CONFIG FAIL: conversation replaced' >&2; exit 1; }
ask FMSPELLCFG
[ "$(meta effort)" = high ] && [ "$(meta model)" = "$M" ] || { echo "S-SPELLING-CONFIG FAIL: meta model=$(meta model) effort=$(meta effort)" >&2; exit 1; }
[ "$(wc -c < "$LOG")" -gt "$BEFORE" ]
echo "ok - S-SPELLING-CONFIG: mixed-spelling config resumed generation $GEN and conversation, effort=$(meta effort)"
wait_idle

echo "=== S-SPELLING-CONTROL: fm-control relaunch --model '$SPACED', no --effort"
wait_composer_empty
control "$SID" relaunch --model "$SPACED" --note 'Reply FMSPELLCTL and the secret word remembered earlier. Do not inspect files or run commands.'
PANE=$(meta herdr_pane_id)
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")" = "$LOG" ] && [ "$(binding_root)" = "$GEN" ] || { echo 'S-SPELLING-CONTROL FAIL: conversation replaced' >&2; exit 1; }
ask FMSPELLCTL
[ "$(meta effort)" = high ] && [ "$(meta model)" = "$M" ] || { echo "S-SPELLING-CONTROL FAIL: meta model=$(meta model) effort=$(meta effort)" >&2; exit 1; }
echo "ok - S-SPELLING-CONTROL: spaced mixed spelling kept effort=$(meta effort), same generation and conversation"
wait_idle

echo "=== S-SPELLING-SPAWN: direct fm-spawn --relaunch --model '$MIXED', no --effort"
wait_composer_empty
control "$SID" exit
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ] || { echo 'exit did not stop the secondmate' >&2; exit 1; }
BEFORE=$(wc -c < "$LOG")
penv bash "$ROOT/bin/fm-spawn.sh" "$SID" --relaunch --model "$MIXED"
PANE=$(meta herdr_pane_id)
[ "$(python3 "$ROOT/bin/fm-dsh.py" session-file "$PARENT/state" "$SID")" = "$LOG" ] && [ "$(binding_root)" = "$GEN" ] || { echo 'S-SPELLING-SPAWN FAIL: conversation replaced' >&2; exit 1; }
[ "$(meta effort)" = high ] && [ "$(meta model)" = "$M" ] || { echo "S-SPELLING-SPAWN FAIL: meta model=$(meta model) effort=$(meta effort)" >&2; exit 1; }
for _ in $(seq 1 120); do s=$(dstate); case "$s" in idle) break ;; esac; sleep 1; done
wait_composer_empty
lab pane send-text "$PANE" 'Reply FMSPELLSPAWN and the secret word remembered earlier. Do not inspect files or run commands.'
lab pane send-keys "$PANE" enter
wait_reply 'FMSPELLSPAWN LILAC58'
[ "$(wc -c < "$LOG")" -gt "$BEFORE" ]
echo "ok - S-SPELLING-SPAWN: direct spawn mixed-spelling relaunch kept effort=$(meta effort), same generation and conversation"
echo "generation dirs under $SID.dsh: $(find "$PARENT/state/$SID.dsh" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
wait_idle
wait_composer_empty
control "$SID" exit
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE")" = dead ]
cp "$LOG" "$TASK/role-secondmate-session.jsonl"
cp "$PARENT/state/$SID.meta" "$TASK/role-secondmate.meta"
echo 'ok - role/drift live driver complete'
