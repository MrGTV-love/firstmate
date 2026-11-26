#!/usr/bin/env bash
# Live driver for fm-restart-unreadable-launch-settings (no-mistakes test step).
# Runs the real firstmate scripts of the gate worktree against a disposable
# Herdr lab session (bin/fm-herdr-lab.sh) and a disposable marked lab home
# (bin/fm-lab-home.sh env), with a real `claude` process in the lab pane.
# Every herdr call the product makes goes through a shim that forwards only to
# the named lab session and logs the subcommand, so "no key was sent" is read
# from the shim log, not assumed.
# Usage: BASE_ROOT=<base copy> live-driver.sh <worktree> <evidence-dir> <stage...>
# Run 01M89V50YZE22VPXK79GGMHNHD round 3: head 8db2b5bb5 vs base 2b2bf6a88.
# Round 3 fix: the restart's pending-reply check counts only files this call
# added (before/after delta), not files earlier stages left in the lab home. Adds the
# startup stage (S9c), the orphan stage (S11), and a stricter S9b precondition.
set -u
: "${BASE_ROOT:?BASE_ROOT must name a copy of the base commit}"
ROOT=$1 EVD=$2; shift 2
STAGES=("$@")
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_PATH=$PATH
CLAUDE_BIN=$(command -v claude)
unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV HERDR_SESSION TMUX TMUX_PANE FM_SPAWN_GEN FM_TASK_ID
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$("$ROOT/bin/fm-lab-home.sh" env 2>"$EVD/.labhome.err")" || { cat "$EVD/.labhome.err"; exit 1; }
LAB_TEARDOWN=$(grep -o "[^ ]*fm-lab-home.sh teardown .*" "$EVD/.labhome.err" | tail -1)
rm -f "$EVD/.labhome.err"
SESSION=$("$HELPER" name rstunpin)
TMP=$(mktemp -d "${FM_LAB_FIXTURE_TMP:-${TMPDIR:-/tmp}}/fm-rst-live.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
OWNED=0
PIDS="$TMP/pids"; : > "$PIDS"
LOG="$EVD/transcript.txt"
SHIMLOG="$TMP/herdr-calls.log"; : > "$SHIMLOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RESULTS="$EVD/results.tsv"
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$RESULTS"; say "RESULT $1 $2 :: $3"; }

cleanup() {
  local pid start cur
  if [ "$OWNED" = 1 ]; then
    PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" >>"$LOG" 2>&1 && say "lab session $SESSION torn down" \
      || say "TEARDOWN FAILED for $SESSION; private tree kept: $TMP"
  fi
  while IFS=$'\t' read -r pid start; do
    for _ in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      cur=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || cur=
      [ -z "$cur" ] || [ "$cur" = "$start" ] || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && say "native pid $pid still alive after teardown" || say "native pid $pid exited"
  done < "$PIDS"
  if [ -n "$LAB_TEARDOWN" ]; then eval "$LAB_TEARDOWN" && say "lab home removed: $FM_HOME"; fi
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" && say "private tree removed: $TMP"
}
trap cleanup EXIT

"$HELPER" prepare "$SESSION" >>"$LOG" 2>&1 || { say "prepare failed"; exit 1; }
OWNED=1
"$HELPER" provision "$SESSION" >>"$LOG" 2>&1 || { say "provision failed"; exit 1; }
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }
say "lab session=$SESSION FM_HOME=$FM_HOME"

export FM_LAB_REAL_PATH="$REAL_PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION" FM_LAB_SHIMLOG="$SHIMLOG"
mkdir -p "$TMP/fakebin" "$TMP/launcher/bin"
cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || { echo "shim: foreign session $2" >> "$FM_LAB_SHIMLOG"; exit 91; }; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
printf '%s\n' "${args[*]}" >> "$FM_LAB_SHIMLOG"
# Round 7: the wall time of every call, tagged product or poller.
t0=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
rc=0; PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}" || rc=$?
t1=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
printf '%s\t%s\t%s\t%s\t%s\n' "${FM_LAB_CALLER:-product}" "$t0" "$(/usr/bin/perl -e 'printf "%.3f", $ARGV[1]-$ARGV[0]' "$t0" "$t1")" "$rc" "${args[*]:0:3}" >> "$FM_LAB_SHIMLOG.timing"
exit "$rc"
SH
chmod +x "$TMP/fakebin/herdr"
# A disposable stand-in for the TeamClaude launcher's process shape only:
# `node .../bin/teamclaude run -- <args>` whose direct child is claude in the
# same process group. It touches no account and no proxy.
cat > "$TMP/launcher/bin/teamclaude" <<'JS'
const { spawn } = require('node:child_process');
const i = process.argv.indexOf('--');
const child = spawn(process.env.FM_LAB_CLAUDE_BIN, process.argv.slice(i + 1), { stdio: 'inherit' });
child.on('exit', (c) => process.exit(c ?? 0));
JS
export PATH="$TMP/fakebin:$REAL_PATH"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr
. "$ROOT/bin/fm-launch-proof-lib.sh"
STATE="$FM_HOME/state"
mkdir -p "$STATE" "$FM_HOME/config" "$FM_HOME/data"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
CCFG="$TMP/claude-config"; mkdir -p "$CCFG"

# new_lane <id> : a local claude secondmate record in its own lab pane.
new_lane() {
  local id=$1 sm="$TMP/$1-home" ws pane tab
  git init -q -b main "$TMP/$id-repo" && git -C "$TMP/$id-repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$TMP/$id-repo" worktree add -q -b "sm-$id" "$sm"
  sm=$(cd "$sm" && pwd -P)
  mkdir -p "$sm/state/operational-inbox" "$sm/data" "$FM_HOME/data/$id"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf '# agents\n' > "$sm/AGENTS.md"
  printf '# charter\n' > "$FM_HOME/data/$id/brief.md"
  ws=$(run workspace create --cwd "$sm" --label "fm-$id" | jq -r '.result.workspace.workspace_id')
  pane=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id')
  tab=$(run pane get "$pane" | jq -r '.result.pane.tab_id')
  cat > "$STATE/$id.meta" <<EOF
window=$SESSION:$pane
endpoint_task_id=$id
worktree=$sm
project=$sm
harness=claude
kind=secondmate
mode=secondmate
spawn_gen=gen-$id
launch_proof=env-v1
yolo=off
model=default
effort=default
home=$sm
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$ws
herdr_tab_id=$tab
herdr_pane_id=$pane
EOF
  printf '%s %s %s\n' "$pane" "$sm" "$ws"
}

# start_claude <id> <pane> <shape> <pin-or-empty> [nopathhome]
start_claude() {
  local id=$1 pane=$2 shape=$3 pin=$4 noenv=${5:-} script="$TMP/$1-launch.sh" pid start
  local -a e=(env -u FM_SPAWN_GEN "CLAUDE_CONFIG_DIR=$CCFG" "FM_LAB_CLAUDE_BIN=$CLAUDE_BIN")
  [ -z "$pin" ] || e+=("FM_SPAWN_GEN=$pin")
  [ "$noenv" != noenv ] || e=(env -i "TERM=xterm-256color" "CLAUDE_CONFIG_DIR=$CCFG" "FM_LAB_CLAUDE_BIN=$CLAUDE_BIN")
  if [ "$noenv" = seeded ]; then
    # A pre-onboarded throwaway config with a fake key and an unroutable API
    # base, so the TUI shows a real composer and nothing reaches any service.
    local cc="$TMP/claude-config-seeded-$id" home; home=$(fm_meta_get "$STATE/$id.meta" home)
    mkdir -p "$cc"
    jq -n --arg h "$home" --arg k "00000000000000000000" '{hasCompletedOnboarding:true, theme:"dark", numStartups:5,
      customApiKeyResponses:{approved:[$k],rejected:[]}, bypassPermissionsModeAccepted:true,
      projects:{($h):{hasTrustDialogAccepted:true, hasCompletedProjectOnboarding:true, disabledMcpjsonServers:["graft"], enabledMcpjsonServers:[]}}}' > "$cc/.claude.json"
    e=(env -u FM_SPAWN_GEN "CLAUDE_CONFIG_DIR=$cc" "ANTHROPIC_API_KEY=sk-ant-fmlab-fake-00000000000000000000"
      "ANTHROPIC_BASE_URL=http://127.0.0.1:9" DISABLE_TELEMETRY=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1)
    [ -z "$pin" ] || e+=("FM_SPAWN_GEN=$pin")
  fi
  local line
  if [ "$shape" = wrapper ]; then
    printf -v line '%q ' "${e[@]}" "$(command -v node)" "$TMP/launcher/bin/teamclaude" run -- --resume 00000000-0000-4000-8000-000000000001
  else
    printf -v line '%q ' "${e[@]}" "$CLAUDE_BIN"
  fi
  printf '#!/usr/bin/env bash\n%s\nexec %s\n' "${FM_LAB_PRELUDE:-}" "$line" > "$script"
  run pane wait-output "$pane" --match '%' --timeout 30000 >/dev/null 2>&1
  sleep 1
  run pane run "$pane" "bash $script" >/dev/null
  local deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ "$(fm_backend_agent_state herdr "$SESSION:$pane")" = alive ] && pid=$(fm_launch_proof_herdr_pid "$STATE/$id.meta" 2>/dev/null) && break
    sleep 0.25
  done
  sleep 2
  if [ "$noenv" = seeded ]; then
    # Setup only (before any snapshot): dismiss first-run dialogs so the
    # composer is the visible surface.
    local w3=$((SECONDS + 60)) scr
    while [ "$SECONDS" -lt "$w3" ]; do
      scr=$(run pane read "$pane" --format text 2>/dev/null)
      if printf '%s' "$scr" | grep -q 'New MCP server'; then run pane send-keys "$pane" Enter >/dev/null; sleep 3; continue; fi
      printf '%s' "$scr" | grep -q 'for shortcuts' && break
      sleep 1
    done
    sleep 2
  fi
  local w2=$((SECONDS + 30))
  until pid=$(fm_launch_proof_herdr_pid "$STATE/$id.meta" 2>/dev/null) && [ -n "$pid" ]; do
    [ "$SECONDS" -lt "$w2" ] || { pid=; break; }; sleep 1
  done
  start=$(LC_ALL=C ps -p "${pid:-0}" -o lstart= 2>/dev/null) || start=
  [ -z "$pid" ] || printf '%s\t%s\n' "$pid" "$start" >> "$PIDS"
  # also record any claude child (wrapper)
  for c in $(pgrep -P "${pid:-0}" 2>/dev/null); do printf '%s\t%s\n' "$c" "$(LC_ALL=C ps -p "$c" -o lstart= 2>/dev/null)" >> "$PIDS"; done
  printf '%s' "$pid"
}

precond() { # <id> <pane> <pid>
  local id=$1 pane=$2 pid=$3 envr st
  st=$(fm_backend_agent_state herdr "$SESSION:$pane")
  envr=$(fm_remote_herdr_process_env "$pid" 2>/dev/null)
  say "PRECOND $id: agent_state=$st attributed_pid=$pid comm=$(ps -p "$pid" -o comm= 2>/dev/null) args='$(ps -p "$pid" -o args= 2>/dev/null | cut -c1-160)'"
  say "PRECOND $id: env has PATH/HOME: $(printf '%s\n' "$envr" | grep -Ec '^(PATH|HOME)=') ; FM_SPAWN_GEN: '$(printf '%s\n' "$envr" | sed -n 's/^FM_SPAWN_GEN=//p')'"
  say "PRECOND $id: kernel cwd: $(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  local kids; kids=$(pgrep -P "$pid" 2>/dev/null | tr '\n' ' ')
  [ -z "$kids" ] || say "PRECOND $id: children of attributed pid: $kids ($(for k in $kids; do ps -p "$k" -o comm= ; done | tr '\n' ' '))"
  say "PRECOND $id: fm_launch_proof_herdr verdict: $(fm_launch_proof_herdr "$STATE/$id.meta")"
  [ "$st" = alive ] || { run pane read "$pane" --format text --source recent 2>/dev/null | tail -60 | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*)=.*/\1=<redacted>/' > "$EVD/precond-fail-$id.screen.txt"; cat "$TMP/$id-launch.sh" | sed -E 's/sk-ant-[A-Za-z0-9-]+/<fake-key>/' >> "$EVD/precond-fail-$id.screen.txt"; }
  [ "$st" = alive ]
}

snap() { # <id> <pane> <tag>
  local id=$1 pane=$2 tag=$3 sm
  sm=$(fm_meta_get "$STATE/$id.meta" home)
  run pane read "$pane" --format text > "$TMP/$id.$tag.screen" 2>/dev/null
  { cksum "$STATE/$id.meta"; find "$STATE" "$sm/state" -type f 2>/dev/null | LC_ALL=C sort; } > "$TMP/$id.$tag.state"
}

sendcount() { # <pane>
  grep -cE "^(pane (send-text|send-keys|send-input|close)|agent (send|interrupt)).*$1" "$SHIMLOG" 2>/dev/null || true
}

run_consumer() { # <label> <id> <pane> <cmd...>
  local label=$1 id=$2 pane=$3 out rc before after; shift 3
  snap "$id" "$pane" before; before=$(sendcount "$pane")
  out=$(timeout ${FM_LAB_CONSUMER_TIMEOUT:-180} "$@" 2>&1); rc=$?
  sleep 1
  snap "$id" "$pane" after; after=$(sendcount "$pane")
  say "--- $label ($id) rc=$rc"
  say "\$ ${*/#$ROOT\//}"
  printf '%s\n' "$out" | sed 's/^/  | /' | tee -a "$LOG" >/dev/null
  printf '%s\n' "$out" | sed 's/^/  | /'
  LAST_OUT=$out LAST_RC=$rc
  LAST_SENDS=$((after - before))
  if cmp -s "$TMP/$id.before.screen" "$TMP/$id.after.screen"; then LAST_SCREEN=same; else LAST_SCREEN=changed; fi
  if cmp -s "$TMP/$id.before.state" "$TMP/$id.after.state"; then LAST_STATE=same; else LAST_STATE=changed; diff "$TMP/$id.before.state" "$TMP/$id.after.state" | sed 's/^/  state-diff: /' | tee -a "$LOG"; fi
  say "  keys/inputs sent to $pane by this call: $LAST_SENDS ; screen: $LAST_SCREEN ; protected state: $LAST_STATE"
}

has() { case "$LAST_OUT" in *"$1"*) return 0 ;; esac; return 1; }

expect_refusal() { # <scenario> <label> <cause-substring> [rc]
  local sc=$1 label=$2 cause=$3 wantrc=${4:-nonzero} ok=1
  if [ "$wantrc" = nonzero ]; then [ "$LAST_RC" != 0 ] || ok=0; else [ "$LAST_RC" = "$wantrc" ] || ok=0; fi
  has "$cause" || ok=0
  [ "$cause" = 'live launch settings are unreadable' ] || ! has 'live launch settings are unreadable' || ok=0
  [ "$LAST_SENDS" = 0 ] || ok=0
  [ "$LAST_SCREEN" = same ] || ok=0
  if [ "$ok" = 1 ]; then record "$sc" pass "$label: rc=$LAST_RC, cause present, 0 inputs, screen same, state $LAST_STATE"
  else record "$sc" FAIL "$label: rc=$LAST_RC sends=$LAST_SENDS screen=$LAST_SCREEN state=$LAST_STATE"; fi
}

UNPIN='live agent is an unpinned native restore'

lifecycle_matrix() { # <scenario> <id> <pane> <cause>
  local sc=$1 id=$2 pane=$3 cause=$4
  run_consumer "reboot recover" "$id" "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
  expect_refusal "$sc" recover "$cause"
  run_consumer "reboot recover --one" "$id" "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover --one
  expect_refusal "$sc" "recover --one" "$cause"
  for verb in interrupt exit stay; do
    run_consumer "fm-control $verb" "$id" "$pane" "$ROOT/bin/fm-control.sh" "$id" "$verb"
    expect_refusal "$sc" "$verb" "$cause"
  done
  run_consumer "fm-control relaunch" "$id" "$pane" "$ROOT/bin/fm-control.sh" "$id" relaunch
  expect_refusal "$sc" relaunch "$cause"
  run_consumer "fm-control relaunch --recover-launch" "$id" "$pane" "$ROOT/bin/fm-control.sh" "$id" relaunch --recover-launch
  expect_refusal "$sc" "relaunch --recover-launch" "$cause"
  run_consumer "fm-control adopt" "$id" "$pane" "$ROOT/bin/fm-control.sh" "$id" adopt
  if [ "$LAST_RC" != 0 ] && has 'there is no adoption route' && [ "$LAST_SENDS" = 0 ] && [ "$LAST_STATE" = same ]; then
    record "$sc" pass "adopt refuses, nothing changed"; else record "$sc" FAIL "adopt rc=$LAST_RC state=$LAST_STATE"; fi
  local pend_before; pend_before=$(find "$STATE" "$FM_HOME" -path '*pending*' -type f 2>/dev/null | LC_ALL=C sort -u)
  run_consumer "fm-secondmate-restart" "$id" "$pane" env FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 "$ROOT/bin/fm-secondmate-restart.sh" "$id"
  local ok=1
  [ "$LAST_RC" = 3 ] || ok=0
  has "unreached: $id" || ok=0; has "$cause" || ok=0
  ! has 'live launch settings are unreadable' || [ "$cause" = 'live launch settings are unreadable' ] || ok=0
  [ "$LAST_SENDS" = 0 ] && [ "$LAST_SCREEN" = same ] && [ "$LAST_STATE" = same ] || ok=0
  local sm; sm=$(fm_meta_get "$STATE/$id.meta" home)
  say "  inbox records after restart: $(find "$sm/state/operational-inbox" -name '*.msg' | wc -l | tr -d ' ') ; pending-reply files: $(find "$STATE" "$FM_HOME" -path '*pending*' -type f 2>/dev/null | wc -l | tr -d ' ')"
  [ "$(find "$sm/state/operational-inbox" -name '*.msg' | wc -l | tr -d ' ')" = 0 ] || ok=0
  local pend_after; pend_after=$(find "$STATE" "$FM_HOME" -path '*pending*' -type f 2>/dev/null | LC_ALL=C sort -u)
  local pend_new; pend_new=$(comm -13 <(printf '%s\n' "$pend_before") <(printf '%s\n' "$pend_after") | grep -c . || true)
  say "  pending-reply files added by this restart: $pend_new"
  [ "$pend_new" = 0 ] || ok=0
  if [ "$ok" = 1 ]; then record "$sc" pass "secondmate restart: unreached with cause, rc=3, no request/inbox/pending/keys"
  else record "$sc" FAIL "secondmate restart rc=$LAST_RC sends=$LAST_SENDS state=$LAST_STATE"; fi
}

stop_lane() { # <id> <pane>
  rm -f "$STATE/$1.meta"
  run pane close "$2" >/dev/null 2>&1 || true
}

for stage in "${STAGES[@]}"; do
  say "=================== STAGE $stage"
  case "$stage" in
    probe)
      read -r pane sm ws < <(new_lane probe)
      pid=$(start_claude probe "$pane" plain "")
      precond probe "$pane" "$pid"
      run pane read "$pane" --format text | head -40 | tee "$EVD/probe-screen.txt"
      ;;
    unpinned-plain)
      read -r pane sm ws < <(new_lane d1plain)
      pid=$(start_claude d1plain "$pane" plain "")
      precond d1plain "$pane" "$pid" || record S1 FAIL "precondition: not alive"
      run pane read "$pane" --format text > "$EVD/screen-unpinned-plain.txt"
      lifecycle_matrix S1-unpinned-plain d1plain "$pane" "$UNPIN"
      stop_lane d1plain "$pane"
      ;;
    unpinned-wrapper)
      read -r pane sm ws < <(new_lane d1wrap)
      pid=$(start_claude d1wrap "$pane" wrapper "")
      precond d1wrap "$pane" "$pid" || record S2 FAIL "precondition: not alive"
      run pane read "$pane" --format text > "$EVD/screen-unpinned-wrapper.txt"
      lifecycle_matrix S2-unpinned-wrapper d1wrap "$pane" "$UNPIN"
      stop_lane d1wrap "$pane"
      ;;
    pinned-elsewhere)
      read -r pane sm ws < <(new_lane pinx)
      pid=$(start_claude pinx "$pane" plain "gen-somebody-else")
      precond pinx "$pane" "$pid"
      run_consumer "reboot recover" pinx "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
      expect_refusal S3-pinned-elsewhere recover 'live agent is pinned to another launch generation'
      run_consumer "fm-control exit" pinx "$pane" "$ROOT/bin/fm-control.sh" pinx exit
      expect_refusal S3-pinned-elsewhere exit 'live agent is pinned to another launch generation'
      stop_lane pinx "$pane"
      ;;
    unreadable)
      read -r pane sm ws < <(new_lane unread)
      pid=$(start_claude unread "$pane" plain "" noenv)
      precond unread "$pane" "$pid"
      run_consumer "reboot recover" unread "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
      expect_refusal S4-unreadable recover 'live launch settings are unreadable'
      run_consumer "fm-control exit" unread "$pane" "$ROOT/bin/fm-control.sh" unread exit
      expect_refusal S4-unreadable exit 'live launch settings are unreadable'
      stop_lane unread "$pane"
      ;;
    legacy)
      read -r pane sm ws < <(new_lane legacy)
      sed -i '' '/^launch_proof=/d' "$STATE/legacy.meta"
      pid=$(start_claude legacy "$pane" plain "" seeded)
      precond legacy "$pane" "$pid"
      run_consumer "reboot recover" legacy "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
      if [ "$LAST_RC" = 0 ] && [ "$LAST_SENDS" = 0 ]; then record S6-legacy pass "recover rc=0 (legacy unproven skip), no input"; else record S6-legacy FAIL "recover rc=$LAST_RC sends=$LAST_SENDS"; fi
      run_consumer "BASE reboot recover" legacy "$pane" "$BASE_ROOT/bin/fm-reboot-recover.sh" recover
      record S6-legacy-base info "base recover rc=$LAST_RC sends=$LAST_SENDS"
      run_consumer "BASE fm-control relaunch --recover-launch" legacy "$pane" "$BASE_ROOT/bin/fm-control.sh" legacy relaunch --recover-launch
      record S6-legacy-base info "base recover-launch rc=$LAST_RC: $(printf '%s' "$LAST_OUT" | grep recovery-skipped)"
      run_consumer "fm-control relaunch --recover-launch" legacy "$pane" "$ROOT/bin/fm-control.sh" legacy relaunch --recover-launch
      if [ "$LAST_RC" = 0 ] && has 'launch=legacy'; then record S6-legacy pass "recover-launch reports legacy skip"; else record S6-legacy FAIL "recover-launch rc=$LAST_RC"; fi
      run pane read "$pane" --format text > "$EVD/screen-legacy-before-exit.txt" 2>/dev/null
      run_consumer "fm-control exit (legacy)" legacy "$pane" "$ROOT/bin/fm-control.sh" legacy exit
      if ! has 'cannot positively attribute'; then record S6-legacy pass "legacy exit not refused by attribution (rc=$LAST_RC sends=$LAST_SENDS)"; else record S6-legacy FAIL "legacy exit refused by attribution"; fi
      run pane read "$pane" --format text > "$EVD/screen-legacy-after-exit.txt" 2>/dev/null
      stop_lane legacy "$pane"
      ;;
    base-unpinned)
      # The same unpinned claude lane driven by the BASE scripts (git archive of
      # the base commit), to record the pre-change wording and effects.
      read -r pane sm ws < <(new_lane d1base)
      pid=$(start_claude d1base "$pane" plain "")
      precond d1base "$pane" "$pid"
      for c in "recover" "exit" "relaunch"; do
        case $c in
          recover) run_consumer "BASE reboot recover" d1base "$pane" "$BASE_ROOT/bin/fm-reboot-recover.sh" recover ;;
          *) run_consumer "BASE fm-control $c" d1base "$pane" "$BASE_ROOT/bin/fm-control.sh" d1base "$c" ;;
        esac
        record BASE-unpinned info "$c rc=$LAST_RC sends=$LAST_SENDS unreadable-wording=$(has 'live launch settings are unreadable' && echo yes || echo no)"
      done
      run_consumer "BASE fm-secondmate-restart" d1base "$pane" env FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 "$BASE_ROOT/bin/fm-secondmate-restart.sh" d1base
      record BASE-unpinned info "secondmate-restart rc=$LAST_RC sends=$LAST_SENDS inbox=$(find "$sm/state/operational-inbox" -name '*.msg' | wc -l | tr -d ' ')"
      run pane read "$pane" --format text > "$EVD/screen-base-after-restart.txt" 2>/dev/null
      stop_lane d1base "$pane"
      ;;
    busy-managed)
      read -r pane sm ws < <(new_lane busy)
      pid=$(start_claude busy "$pane" plain "gen-busy" seeded)
      w4=$((SECONDS + 90))
      until [ "$(fm_launch_proof_herdr "$STATE/busy.meta")" = managed ]; do [ "$SECONDS" -lt "$w4" ] || break; sleep 2; done
      precond busy "$pane" "$pid"
      shell_kid() { ps -axo pid=,ppid=,comm= | awk -v p="$pid" '$2 == p && $3 ~ /(zsh|bash|sh)$/ {print $1}' | head -1; }
      busy_shell() { # setup by the test: claude's own "!" shell mode runs a command as a child of the managed agent
        local t
        run pane send-text "$pane" '!sleep 240; true' >/dev/null; sleep 2
        for t in 1 2 3 4 5 6; do
          run pane send-keys "$pane" Enter >/dev/null; sleep 5
          [ -z "$(shell_kid)" ] || break
        done
        say "setup: tool shell child of the agent: $(shell_kid) (Enter attempts: $t)"
      }
      members() { # <tag>
        local g; g=$(ps -o pgid= -p "$pid" | tr -d ' ')
        ps -axo pid=,ppid=,pgid=,comm= | awk -v g="$g" '$3 == g' | while read -r p pp pg c; do
          if e=$(fm_remote_herdr_process_env "$p" 2>/dev/null) && printf '%s\n' "$e" | grep -Eq '^(PATH|HOME)='; then r=readable; else r=UNREADABLE; fi
          say "   [$1] group member pid=$p ppid=$pp comm=$c env=$r exe=$(fm_launch_proof_pid_exe "$p" 2>/dev/null || echo '<read failed>')"
        done
      }
      busy_shell
      run pane read "$pane" --format text > "$EVD/screen-busy-managed-running.txt" 2>/dev/null
      members busy
      nunread=$(g=$(ps -o pgid= -p "$pid" | tr -d ' '); ps -axo pid=,pgid= | awk -v g="$g" -v me="$pid" '$2 == g && $1 != me {print $1}' | while read -r p; do fm_remote_herdr_process_env "$p" 2>/dev/null | grep -Eq '^(PATH|HOME)=' || echo "$p"; done | wc -l | tr -d ' ')
      say "unreadable group members besides the agent: $nunread"
      if [ "$nunread" -ge 1 ]; then record S9-precondition pass "busy managed claude has $nunread unreadable group member(s) (caffeinate / tool shell)"; else record S9-precondition FAIL "no unreadable member; the busy case was not produced"; fi
      hv=$(fm_launch_proof_herdr_judge "$STATE/busy.meta" | tr '\t' '|')
      bv=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; . "$1/bin/fm-launch-proof-lib.sh"; fm_launch_proof_herdr "$2"' _ "$BASE_ROOT" "$STATE/busy.meta")
      say "HEAD verdict with a running shell child: $hv"; say "BASE verdict with a running shell child: $bv"
      if [ "${hv%%|*}" = managed ] && [ "$bv" = managed ]; then record S9-verdict pass "head verdict managed = base verdict managed"; else record S9-verdict FAIL "head=$hv base=$bv"; fi
      run_consumer "HEAD reboot recover (busy managed)" busy "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
      hrc=$LAST_RC; hrep=$(has 'REBOOT_RECOVERY: busy' && echo yes || echo no); hs=$LAST_SENDS
      run_consumer "BASE reboot recover (busy managed)" busy "$pane" "$BASE_ROOT/bin/fm-reboot-recover.sh" recover
      brep=$(has 'REBOOT_RECOVERY: busy' && echo yes || echo no)
      if [ "$hrc" = 0 ] && [ "$hrep" = no ] && [ "$hs" = 0 ] && [ "$LAST_RC" = 0 ] && [ "$brep" = no ]; then record S9-recover pass "head recover rc=0 silent, 0 inputs; base recover rc=$LAST_RC silent"; else record S9-recover FAIL "head rc=$hrc report=$hrep sends=$hs; base rc=$LAST_RC report=$brep"; fi
      for _try in 1 2 3; do
        [ -z "$(shell_kid)" ] || break
        say "setup: no tool shell child before the head interrupt; starting the setup command again (try $_try)"
        busy_shell
      done
      members before-head-interrupt
      sk=$(shell_kid)
      if [ -n "$sk" ] && ! fm_remote_herdr_process_env "$sk" 2>/dev/null | grep -Eq '^(PATH|HOME)='; then
        record S9b-precondition pass "tool shell child pid=$sk comm=$(ps -p "$sk" -o comm= 2>/dev/null) exe=$(fm_launch_proof_pid_exe "$sk" 2>/dev/null) is present and its environment is unreadable just before the head interrupt"
      else
        record S9b-precondition FAIL "no unreadable tool shell child just before the head interrupt (shell_kid='$sk')"
      fi
      run_consumer "HEAD fm-control interrupt (busy managed)" busy "$pane" "$ROOT/bin/fm-control.sh" busy interrupt
      hirc=$LAST_RC; hi=$(printf '%s' "$LAST_OUT" | grep -v fm-gate-refuse | tr '\n' ' ' | cut -c1-200); his=$LAST_SENDS
      run pane read "$pane" --format text > "$EVD/screen-busy-managed-after-head-interrupt.txt" 2>/dev/null
      busy_shell; members before-base-interrupt
      run_consumer "BASE fm-control interrupt (busy managed)" busy "$pane" "$BASE_ROOT/bin/fm-control.sh" busy interrupt
      bi=$(printf '%s' "$LAST_OUT" | grep -v fm-gate-refuse | tr '\n' ' ' | cut -c1-200)
      if [ "$hirc" = 0 ] && [ "$his" -ge 1 ] && case "$hi" in *interrupt-delivered*) true ;; *) false ;; esac && [ "$LAST_RC" = 0 ]; then
        record S9-interrupt pass "head rc=0 sends=$his: $hi | base rc=$LAST_RC sends=$LAST_SENDS: $bi"
      else record S9-interrupt FAIL "head rc=$hirc sends=$his: $hi | base rc=$LAST_RC sends=$LAST_SENDS: $bi"; fi
      run pane read "$pane" --format text > "$EVD/screen-busy-managed-after.txt" 2>/dev/null
      stop_lane busy "$pane"
      ;;
    startup)
      # S9c: a managed (matching pin) claude in startup, while its /bin/sh
      # startup children run. The poller starts before claude launches and
      # samples the head judge plus every group member's env readability and
      # executable path, so a managed verdict and an unreadable /bin/sh
      # descendant are seen in the same sample.
      read -r pane sm ws < <(new_lane boot)
      SAMPLES="$EVD/startup-samples.tsv"
      printf 'wall\tjudge_seconds\tverdict\treason\tattributed\tmembers(pid:ppid:comm:env:exe)\n' > "$SAMPLES"
      ( export FM_LAB_CALLER=poller
        end=$((SECONDS + ${FM_LAB_STARTUP_SECONDS:-150}))
        while [ "$SECONDS" -lt "$end" ]; do
          a=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
          j=$(fm_launch_proof_herdr_judge "$STATE/boot.meta")
          b=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
          ap=$(fm_launch_proof_herdr_pid "$STATE/boot.meta" 2>/dev/null) || ap=
          mem=''
          if [ -n "$ap" ]; then
            g=$(ps -o pgid= -p "$ap" 2>/dev/null | tr -d ' ')
            while read -r p pp c; do
              [ -n "$p" ] && [ "$p" != "$ap" ] || continue
              if fm_remote_herdr_process_env "$p" 2>/dev/null | grep -Eq '^(PATH|HOME)='; then r=R; else r=U; fi
              x=$(fm_launch_proof_pid_exe "$p" 2>/dev/null) || x='?'
              mem+="$p:$pp:$c:$r:$x "
            done < <(ps -axo pid=,ppid=,pgid=,comm= | awk -v g="${g:-x}" '$3 == g {print $1, $2, $4}')
          fi
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$(/usr/bin/perl -e 'printf "%.3f", $ARGV[1]-$ARGV[0]' "$a" "$b")" "${j%%$'\t'*}" "${j#*$'\t'}" "$ap" "$mem" >> "$SAMPLES"
          sleep 0.3
        done ) &
      poller=$!
      pid=$(start_claude boot "$pane" plain "gen-boot" seeded)
      precond boot "$pane" "$pid"
      wait "$poller"
      # A sample counts when the judge attributed claude and some member is an
      # unreadable /bin/sh (or sh) descendant.
      withsh=$(awk -F '\t' 'NR > 1 && $5 != "" && $6 ~ /:(\/bin\/)?sh:U:/' "$SAMPLES")
      nm=$(printf '%s\n' "$withsh" | awk -F '\t' '$3 == "managed"' | grep -c . || true)
      nn=$(printf '%s\n' "$withsh" | awk -F '\t' '$3 != "managed" && $3 != ""' | grep -c . || true)
      say "startup samples: $(($(wc -l < "$SAMPLES") - 1)); with an unreadable sh member: managed=$nm other=$nn"
      say "startup verdicts overall: $(awk -F '\t' 'NR > 1 {print $3}' "$SAMPLES" | sort | uniq -c | tr '\n' ' ')"
      printf '%s\n' "$withsh" | awk -F '\t' '$3 != "managed" && $3 != "" {print "  non-managed with sh: " $3 " | " $4 " | " $6}' | tee -a "$LOG"
      if [ "$nm" -ge 1 ] && [ "$nn" = 0 ]; then
        record S9c-startup-sh pass "$nm sample(s) show verdict managed while an unreadable /bin/sh descendant was in the agent's group; 0 non-managed such samples (startup-samples.tsv)"
      elif [ "$nm" = 0 ] && [ "$nn" = 0 ]; then
        record S9c-startup-sh UNTESTED "no sample caught an unreadable /bin/sh member with claude attributed"
      else
        record S9c-startup-sh FAIL "managed=$nm non-managed=$nn sample(s) with an unreadable /bin/sh member; see startup-samples.tsv"
      fi
      stop_lane boot "$pane"
      ;;
    orphan)
      # S11: an unreadable platform binary in the agent's process group that is
      # NOT its descendant. The launch script starts caffeinate in a subshell
      # that exits at once, so caffeinate is re-parented to launchd (ppid 1)
      # and keeps the agent's process group. It ends by itself.
      read -r pane sm ws < <(new_lane orph)
      # caffeinate -w <holder> lives until the driver's own holder process ends,
      # so the control below ends it by stopping only that holder ($!).
      /bin/sleep 3000 & holder=$!
      printf '%s\t%s\n' "$holder" "$(LC_ALL=C ps -p "$holder" -o lstart= 2>/dev/null)" >> "$PIDS"
      pid=$(FM_LAB_PRELUDE="( /usr/bin/caffeinate -w $holder & echo \$! > $TMP/orph-caffeinate.pid )" start_claude orph "$pane" plain "gen-orph" seeded)
      precond orph "$pane" "$pid"
      g=$(ps -o pgid= -p "$pid" | tr -d ' ')
      cpid=$(cat "$TMP/orph-caffeinate.pid" 2>/dev/null)
      say "setup: launch script recorded caffeinate pid '${cpid}'; its row: $(ps -o pid=,ppid=,pgid=,args= -p "${cpid:-0}" 2>/dev/null)"
      orphan=$(ps -o pid=,ppid=,pgid= -p "${cpid:-0}" 2>/dev/null | awk -v g="$g" '$2 == 1 && $3 == g {print $1}')
      ps -axo pid=,ppid=,pgid=,comm= | awk -v g="$g" '$3 == g' | while read -r p pp pg c; do
        if fm_remote_herdr_process_env "$p" 2>/dev/null | grep -Eq '^(PATH|HOME)='; then r=readable; else r=UNREADABLE; fi
        say "   [orphan] group member pid=$p ppid=$pp comm=$c env=$r exe=$(fm_launch_proof_pid_exe "$p" 2>/dev/null || echo '<read failed>')"
      done
      if [ -n "$orphan" ]; then
        ov=$(fm_launch_proof_herdr_judge "$STATE/orph.meta" | tr '\t' '|'); say "HEAD judge with orphan platform binary in group: $ov"
        bov=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr; . "$1/bin/fm-launch-proof-lib.sh"; fm_launch_proof_herdr "$2"' _ "$BASE_ROOT" "$STATE/orph.meta")
        say "BASE verdict with orphan platform binary in group: $bov"
        run pane read "$pane" --format text > "$EVD/screen-orphan-before.txt" 2>/dev/null
        run_consumer "HEAD fm-control interrupt (orphan platform binary in group)" orph "$pane" "$ROOT/bin/fm-control.sh" orph interrupt
        if [ "${ov%%|*}" != managed ] && [ "$LAST_RC" != 0 ] && [ "$LAST_SENDS" = 0 ] && [ "$LAST_SCREEN" = same ] && has "$orphan"; then
          record S11-orphan-platform pass "judge=$ov; interrupt rc=$LAST_RC names pid $orphan, 0 inputs, screen same, state $LAST_STATE"
        else record S11-orphan-platform FAIL "judge=$ov; interrupt rc=$LAST_RC sends=$LAST_SENDS screen=$LAST_SCREEN"; fi
        run_consumer "HEAD reboot recover (orphan platform binary in group)" orph "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
        if [ "$LAST_RC" != 0 ] && [ "$LAST_SENDS" = 0 ] && has 'REBOOT_RECOVERY: orph'; then
          record S11-orphan-platform pass "recover reports and refuses: rc=$LAST_RC, 0 inputs"
        else record S11-orphan-platform FAIL "recover rc=$LAST_RC sends=$LAST_SENDS"; fi
        # Control: once that caffeinate has ended by itself, the same agent is managed.
        kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
        w5=$((SECONDS + 60)); while kill -0 "$orphan" 2>/dev/null && [ "$SECONDS" -lt "$w5" ]; do sleep 1; done
        say "orphan caffeinate alive after holder ended: $(kill -0 "$orphan" 2>/dev/null && echo yes || echo no)"
        sleep 2
        cv=$(fm_launch_proof_herdr_judge "$STATE/orph.meta" | tr '\t' '|'); say "HEAD judge after the orphan caffeinate ended: $cv"
        run_consumer "HEAD fm-control interrupt (after orphan ended)" orph "$pane" "$ROOT/bin/fm-control.sh" orph interrupt
        if [ "${cv%%|*}" = managed ] && [ "$LAST_RC" = 0 ] && [ "$LAST_SENDS" -ge 1 ]; then
          record S11-control pass "after the orphan ended: judge=$cv; interrupt rc=0 sends=$LAST_SENDS: $(printf '%s' "$LAST_OUT" | grep -v fm-gate-refuse | tr '\n' ' ' | cut -c1-160)"
        else record S11-control FAIL "after the orphan ended: judge=$cv; interrupt rc=$LAST_RC sends=$LAST_SENDS"; fi
      else
        record S11-orphan-platform FAIL "setup: no orphaned caffeinate in the agent's group was produced"
      fi
      kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
      stop_lane orph "$pane"
      ;;
    group-probe)
      read -r pane sm ws < <(new_lane gprobe)
      pid=$(start_claude gprobe "$pane" plain "gen-gprobe" seeded)
      precond gprobe "$pane" "$pid"
      for n in 1 2 3 4 5 6; do
        g=$(ps -o pgid= -p "$pid" | tr -d ' ')
        say "probe $n: claude pid=$pid pgid=$g; verdict=$(fm_launch_proof_herdr "$STATE/gprobe.meta"); judge=$(fm_launch_proof_herdr_judge "$STATE/gprobe.meta" | tr '\t' '|')"
        ps -axo pid=,ppid=,pgid=,comm= | awk -v g="$g" '$3 == g' | while read -r p pp pg c; do
          if e=$(fm_remote_herdr_process_env "$p" 2>/dev/null) && printf '%s\n' "$e" | grep -Eq '^(PATH|HOME)='; then r=readable; else r=UNREADABLE; fi
          say "   member pid=$p ppid=$pp comm=$c env=$r pin=$(printf '%s\n' "$e" | sed -n 's/^FM_SPAWN_GEN=//p')"
        done
        sleep 5
      done
      stop_lane gprobe "$pane"
      ;;
    managed-restart|managed-restart-base)
      R=$ROOT; [ "$stage" = managed-restart ] || R=$BASE_ROOT
      read -r pane sm ws < <(new_lane mgdr)
      pid=$(start_claude mgdr "$pane" plain "gen-mgdr" seeded)
      precond mgdr "$pane" "$pid"
      run pane read "$pane" --format text > "$EVD/screen-$stage-before.txt" 2>/dev/null
      # Round 7: while the restart runs, poll the head judge every 3 s and
      # record its verdict, its reason, its wall time and the agent's group.
      POLLS="$EVD/polls-$stage.tsv"; printf 'wall\tjudge_seconds\tverdict\treason\tgroup\n' > "$POLLS"
      ( export FM_LAB_CALLER=poller
        while :; do
          a=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
          j=$(fm_launch_proof_herdr_judge "$STATE/mgdr.meta")
          b=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
          ap=$(fm_launch_proof_herdr_pid "$STATE/mgdr.meta" 2>/dev/null) || ap=
          g=$(ps -o pgid= -p "${ap:-0}" 2>/dev/null | tr -d ' ')
          grp=''; [ -z "$g" ] || grp=$(ps -axo pid=,pgid=,comm= | awk -v g="$g" '$2 == g {printf "%s:%s ", $1, $3}')
          printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$(/usr/bin/perl -e 'printf "%.3f", $ARGV[1]-$ARGV[0]' "$a" "$b")" "${j%%$'\t'*}" "${j#*$'\t'}" "$grp" >> "$POLLS"
          sleep 3
        done ) &
      poller=$!
      run_consumer "fm-secondmate-restart on managed lane ($stage)" mgdr "$pane" env FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 "$R/bin/fm-secondmate-restart.sh" mgdr
      kill "$poller" 2>/dev/null; wait "$poller" 2>/dev/null
      say "  polls: $(($(wc -l < "$POLLS") - 1)); verdicts: $(awk -F '\t' 'NR > 1 {print $3}' "$POLLS" | sort | uniq -c | tr '\n' ' ')"
      run pane read "$pane" --format text > "$EVD/screen-$stage-after.txt" 2>/dev/null
      say "  inbox records: $(find "$STATE" "$sm/state" -name '*.msg' 2>/dev/null | wc -l | tr -d ' ') ; pending-reply records: $(find "$STATE/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')"
      if has 'unreached: mgdr' || ! { has 'nudged: mgdr' || has 'restarted: mgdr'; }; then record "S8-$stage" FAIL "managed lane outcome rc=$LAST_RC: $(printf '%s' "$LAST_OUT" | grep -E '^(nudged|restarted|unreached|summary)' | tr '\n' ' ')"
      else record "S8-$stage" pass "managed lane not refused by attribution: rc=$LAST_RC sends=$LAST_SENDS; $(printf '%s' "$LAST_OUT" | grep -E '^(nudged|restarted|unreached|summary)' | tr '\n' ' ')"; fi
      stop_lane mgdr "$pane"
      ;;
    stopped)
      # E3 stopped-agent control: the recorded pane holds only its login shell.
      for side in H B; do
        R=$ROOT; [ "$side" = H ] || R=$BASE_ROOT
        read -r pane sm ws < <(new_lane "stop$side")
        run pane wait-output "$pane" --match '%' --timeout 30000 >/dev/null 2>&1; sleep 2
        say "PRECOND stop$side: agent_state=$(fm_backend_agent_state herdr "$SESSION:$pane")"
        run_consumer "$side reboot recover (shell-only pane)" "stop$side" "$pane" "$R/bin/fm-reboot-recover.sh" recover
        record "S10-stopped-$side" info "recover rc=$LAST_RC sends=$LAST_SENDS report=$(has "REBOOT_RECOVERY: stop$side" && echo yes || echo no)"
        run_consumer "$side fm-control exit (shell-only pane)" "stop$side" "$pane" "$R/bin/fm-control.sh" "stop$side" exit
        record "S10-stopped-$side" info "exit rc=$LAST_RC sends=$LAST_SENDS: $(printf '%s' "$LAST_OUT" | grep -v fm-gate-refuse | tr '\n' ' ' | cut -c1-200)"
        stop_lane "stop$side" "$pane"
      done
      ;;
    managed)
      read -r pane sm ws < <(new_lane mgd)
      pid=$(start_claude mgd "$pane" plain "gen-mgd" seeded)
      precond mgd "$pane" "$pid"
      run_consumer "reboot recover" mgd "$pane" "$ROOT/bin/fm-reboot-recover.sh" recover
      if [ "$LAST_RC" = 0 ] && ! has 'REBOOT_RECOVERY: mgd' && [ "$LAST_SENDS" = 0 ]; then record S5-managed pass "recover silent rc=0 for managed lane"; else record S5-managed FAIL "recover rc=$LAST_RC"; fi
      run_consumer "BASE reboot recover" mgd "$pane" "$BASE_ROOT/bin/fm-reboot-recover.sh" recover
      record S5-managed-base info "base recover rc=$LAST_RC sends=$LAST_SENDS"
      run_consumer "fm-control relaunch --recover-launch" mgd "$pane" "$ROOT/bin/fm-control.sh" mgd relaunch --recover-launch
      if [ "$LAST_RC" = 0 ] && has 'launch=managed'; then record S5-managed pass "recover-launch: launch=managed skip"; else record S5-managed FAIL "recover-launch rc=$LAST_RC"; fi
      # contested: a second live record naming the same home
      cp "$STATE/mgd.meta" "$STATE/mgdpeer.meta"
      sed -i '' -e 's/^endpoint_task_id=.*/endpoint_task_id=mgdpeer/' -e 's/^window=.*/window='"$SESSION"':w-peer-none/' -e 's/^herdr_pane_id=.*/herdr_pane_id=w-peer-none/' -e 's/^spawn_gen=.*/spawn_gen=gen-peer/' "$STATE/mgdpeer.meta"
      say "contested probe verdict: $(fm_launch_proof_herdr "$STATE/mgd.meta")"
      run_consumer "fm-control exit (peer shares home)" mgd "$pane" "$ROOT/bin/fm-control.sh" mgd exit
      expect_refusal S7-contested exit 'another task record (mgdpeer.meta) claims this pane'
      rm -f "$STATE/mgdpeer.meta"
      say "verdict after peer removed: $(fm_launch_proof_herdr "$STATE/mgd.meta")"
      run pane read "$pane" --format text > "$EVD/screen-managed-before-exit.txt" 2>/dev/null
      run_consumer "fm-control exit (managed)" mgd "$pane" "$ROOT/bin/fm-control.sh" mgd exit
      if ! has 'cannot positively attribute' && ! has 'refusal check failed' && ! has 'unpinned native restore'; then
        record S5-managed pass "exit is not refused by attribution (rc=$LAST_RC, sends=$LAST_SENDS)"
      else record S5-managed FAIL "exit rc=$LAST_RC sends=$LAST_SENDS"; fi
      run pane read "$pane" --format text > "$EVD/screen-managed-after-exit.txt" 2>/dev/null
      stop_lane mgd "$pane"
      ;;
  esac
done
cp "$SHIMLOG" "$EVD/herdr-shim-calls.log"
[ ! -f "$SHIMLOG.timing" ] || cp "$SHIMLOG.timing" "$EVD/herdr-shim-timing.tsv"
say "done"
