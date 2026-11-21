#!/usr/bin/env bash
# Live lab for fm/fm-restart-unreadable-launch-settings.
# Real Herdr (named fm-lab-* session via bin/fm-herdr-lab.sh), real claude TUI
# processes (scratch CLAUDE_CONFIG_DIR, throwaway API key, nothing submitted),
# real firstmate scripts from the gate worktree (head) and from a git-archive
# export of the base commit. Disposable lab home from bin/fm-lab-home.sh.
set -u
ROOT=${1:?worktree root}
EVID=${2:?evidence dir}
BASE_SHA=${3:?base sha}
HELPER="$ROOT/bin/fm-herdr-lab.sh"
CLAUDE_BIN=/Users/charlesabrooker/.local/bin/claude
NODE_BIN=/Users/charlesabrooker/.nvm/versions/node/v24.4.1/bin/node
REAL_PATH=$PATH
LOG="$EVID/relaunch-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RESULTS="$EVID/relaunch-results.tsv"
printf 'row\tcheck\tresult\tdetail\n' > "$RESULTS"
res() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS"; say "RESULT $1 $2 $3 :: $4"; }

unset HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV TMUX TMUX_PANE FM_SPAWN_GEN \
  FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
eval "$("$ROOT/bin/fm-lab-home.sh" env 2>>"$LOG")" || { say "lab home mint failed"; exit 1; }
[ -f "$FM_HOME/state/.fm-gate-lab" ] || ls -la "$FM_HOME" "$FM_HOME/state" >> "$LOG"
case "$FM_HOME" in */fm-lab.*) ;; *) say "refusing: FM_HOME is not a lab path: $FM_HOME"; exit 1 ;; esac
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-rsa-lab.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
SESSION=$("$HELPER" name rs-attr)
OWNED=0
say "FM_HOME=$FM_HOME"; say "TMP=$TMP"; say "SESSION=$SESSION"

cleanup() {
  local st=$?
  say "--- cleanup"
  if [ "$OWNED" = 1 ]; then PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" >> "$LOG" 2>&1 && say "herdr lab teardown ok" || say "herdr lab teardown FAILED"; fi
  sleep 1
  # Any claude we started lived only in the lab session; report survivors.
  pgrep -fl "$TMP" >> "$LOG" 2>&1 && say "WARNING: processes still reference $TMP" || say "no lab processes remain"
  "$ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" >> "$LOG" 2>&1 && rm -rf "$FM_HOME" && say "lab home removed"
  chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" && say "scratch removed"
  exit "$st"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

"$HELPER" prepare "$SESSION" >> "$LOG" 2>&1 || { say "prepare failed"; exit 1; }
OWNED=1
"$HELPER" provision "$SESSION" >> "$LOG" 2>&1 || { say "provision failed"; exit 1; }
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }

# Every production herdr call is forced through the lab helper and this session.
mkdir -p "$TMP/fakebin" "$TMP/tcbin"
export FM_LAB_REAL_PATH="$REAL_PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION"
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
export PATH="$TMP/fakebin:$PATH" HERDR_SESSION="$SESSION"

# The TeamClaude launcher shape of the recorded d1 lanes:
#   node .../bin/teamclaude run -- --resume <id>   with claude as its direct child.
# A stand-in script named teamclaude (the installed one self-updates on exit).
cat > "$TMP/tcbin/teamclaude" <<'JS'
#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const a = process.argv.slice(2); const i = a.indexOf('--');
const r = spawnSync('claude', i >= 0 ? a.slice(i + 1) : [], { stdio: 'inherit', env: process.env });
process.exit(r.status ?? 1);
JS
chmod +x "$TMP/tcbin/teamclaude"
ln -s "$CLAUDE_BIN" "$TMP/tcbin/claude"

printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
KEY=sk-ant-fm-restart-attr-throwaway
git init -q "$TMP/proj" && git -C "$TMP/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

SID=8a6f3c1e-4b7d-4e21-9c55-2f0d1e9b7a10
# mkrow <row-id> <kind> <launch_proof-line|-> <spawn_gen> -> sets WT PANE META CFG for the row
mkrow() {
  local id=$1 kind=$2 proofline=$3 gen=$4 ws tab
  WT="$TMP/wt-$id"
  git -C "$TMP/proj" worktree add -q "$WT" -b "b-$id" >/dev/null 2>&1
  WT=$(cd "$WT" && pwd -P)
  CFG="$TMP/cfg-$id"; mkdir -p "$CFG"
  jq -n --arg wt "$WT" --arg key "${KEY: -20}" '{hasCompletedOnboarding:true,theme:"dark",numStartups:5,
     customApiKeyResponses:{approved:[$key],rejected:[]},
     projects:{($wt):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true}}}' > "$CFG/.claude.json"
  # A transcript for --resume <SID> under this cwd's project directory.
  local pdir="$CFG/projects/$(printf '%s' "$WT" | sed 's#[^A-Za-z0-9]#-#g')"
  mkdir -p "$pdir"
  python3 - "$pdir/$SID.jsonl" "$WT" "$SID" <<'PY'
import json, sys, uuid, datetime
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z')
u = str(uuid.uuid4())
open(sys.argv[1],'w').write(json.dumps({"parentUuid":None,"isSidechain":False,"userType":"external","cwd":sys.argv[2],
  "sessionId":sys.argv[3],"version":"2.0.0","type":"user","message":{"role":"user","content":"lab fixture: idle"},
  "uuid":u,"timestamp":now})+"\n")
PY
  ws=$(run workspace create --cwd "$WT" --label "fm-$id" | jq -r '.result.workspace.workspace_id')
  PANE=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id')
  tab=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
  META="$FM_HOME/state/$id.meta"
  {
    printf 'window=%s:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=%s\n' \
      "$SESSION" "$PANE" "$id" "$WT" "$TMP/proj" "$kind"
    if [ "$kind" = secondmate ]; then printf 'mode=secondmate\nhome=%s\n' "$WT"; else printf 'mode=no-mistakes\n'; fi
    printf 'spawn_gen=%s\n' "$gen"
    [ "$proofline" = - ] || printf '%s\n' "$proofline"
    printf 'yolo=off\nmodel=opus\neffort=low\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$SESSION" "$ws" "$tab" "$PANE"
  } > "$META"
  if [ "$kind" = secondmate ]; then
    mkdir -p "$WT/state" "$WT/data"; printf '%s\n' "$id" > "$WT/.fm-secondmate-home"
    printf '# lab secondmate\n' > "$WT/AGENTS.md"; printf 'idle lab charter\n' > "$WT/data/charter.md"
  fi
  mkdir -p "$FM_HOME/data/$id"; printf '# Task\nlab fixture brief\n' > "$FM_HOME/data/$id/brief.md"
  eval "PANE_$id=\$PANE WT_$id=\$WT CFG_$id=\$CFG"
}

# launch <pane> <mode> <cfg> [pin]: mode bare|wrapper|noenv|shell
launch() {
  local pane=$1 mode=$2 cfg=$3 pin=${4:-} script="$TMP/launch-$1.sh" pinpart=''
  [ -z "$pin" ] || pinpart="FM_SPAWN_GEN=$pin"
  case "$mode" in
    bare)    printf '#!/bin/bash\nexec env -u FM_SPAWN_GEN -u FM_HOME %s CLAUDE_CONFIG_DIR=%q ANTHROPIC_API_KEY=%q %q --setting-sources project,local --strict-mcp-config --resume %s\n' "$pinpart" "$cfg" "$KEY" "$CLAUDE_BIN" "$SID" > "$script" ;;
    wrapper) printf '#!/bin/bash\nexec env -u FM_SPAWN_GEN -u FM_HOME %s PATH=%q CLAUDE_CONFIG_DIR=%q ANTHROPIC_API_KEY=%q %q %q run -- --strict-mcp-config --resume %s\n' "$pinpart" "$TMP/tcbin:$REAL_PATH" "$cfg" "$KEY" "$NODE_BIN" "$TMP/tcbin/teamclaude" "$SID" > "$script" ;;
    noenv)   printf '#!/bin/bash\nexec env -i TERM=xterm-256color CLAUDE_CONFIG_DIR=%q ANTHROPIC_API_KEY=%q %q --setting-sources project,local --strict-mcp-config --resume %s\n' "$cfg" "$KEY" "$CLAUDE_BIN" "$SID" > "$script" ;;
    shell)   return 0 ;;
  esac
  run pane send-text "$pane" "exec bash $script" >/dev/null
  run pane send-keys "$pane" Enter >/dev/null
}

# Production libs for state reads (through the pinned herdr wrapper).
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr; . "$ROOT/bin/fm-launch-proof-lib.sh"

wait_up() { # <id> <expected-verdict>
  local id=$1 want=$2 meta="$FM_HOME/state/$1.meta" pane v st scr
  eval "pane=\$PANE_$id"
  for _ in $(seq 1 40); do
    v=$(fm_launch_proof_herdr "$meta"); st=$(fm_backend_agent_state herdr "$SESSION:$pane")
    scr=$(run pane read "$pane" --format text 2>/dev/null)
    if [ "$v" = "$want" ] && [ "$st" = alive ] && printf '%s' "$scr" | grep -q 'lab fixture'; then break; fi
    sleep 1
  done
  sleep 3
  v=$(fm_launch_proof_herdr "$meta"); st=$(fm_backend_agent_state herdr "$SESSION:$pane")
  run pane read "$pane" --format text > "$EVID/relaunch-screen-$id-ready.txt" 2>&1
  run pane process-info --pane "$pane" > "$EVID/relaunch-procinfo-$id.json" 2>&1
  say "row $id: verdict=$v agent_state=$st (want $want/alive)"
  [ "$v" = "$want" ] && [ "$st" = alive ]
}

snap() { # <id> <tag>
  local id=$1 pane; eval "pane=\$PANE_$id"
  run pane read "$pane" --format text > "$TMP/scr-$id-$2.txt" 2>&1
  (cd "$FM_HOME" && find state -type f ! -name '.reboot-recovery-cursor' ! -name '*.reboot-notice' ! -name 'guard-events.jsonl' ! -name '.guard-watcher-stale-banner' -print | LC_ALL=C sort | xargs cksum) > "$TMP/st-$2.txt" 2>&1
}
unchanged() { # <id> <tag-before> <tag-after> <label>
  local id=$1 d
  if cmp -s "$TMP/scr-$id-$2.txt" "$TMP/scr-$id-$3.txt"; then res "$id" "$4:screen-unchanged" pass "pane text identical before/after"
  else d=$(diff "$TMP/scr-$id-$2.txt" "$TMP/scr-$id-$3.txt" | head -8 | tr '\n' '|'); res "$id" "$4:screen-unchanged" CHECK "$d"; fi
  if cmp -s "$TMP/st-$2.txt" "$TMP/st-$3.txt"; then res "$id" "$4:state-unchanged" pass "no protected state file created/changed"
  else d=$(diff "$TMP/st-$2.txt" "$TMP/st-$3.txt" | tr '\n' '|'); res "$id" "$4:state-unchanged" FAIL "$d"; fi
}

expect() { # <id> <label> <rc-want: nz|0|any> <must-contain> <must-not-contain|-> <cmd...>
  local id=$1 label=$2 rcw=$3 has=$4 hasnt=$5 out rc; shift 5
  out=$("$@" 2>&1); rc=$?
  { printf '\n$ %s\n' "$*"; printf '%s\n' "$out"; printf '[exit %s]\n' "$rc"; } >> "$EVID/relaunch-output-$id.txt"
  local ok=pass why="rc=$rc"
  case "$rcw" in nz) [ "$rc" != 0 ] || { ok=FAIL; why="expected nonzero, got 0"; } ;; 0) [ "$rc" = 0 ] || { ok=FAIL; why="expected 0, got $rc"; } ;; esac
  case "$out" in *"$has"*) ;; *) ok=FAIL; why="$why; missing '$has'" ;; esac
  [ "$hasnt" = - ] || case "$out" in *"$hasnt"*) ok=FAIL; why="$why; contains forbidden '$hasnt'" ;; esac
  case "$out" in *"fm-gate-refuse: refus"*|*"refusing gate"*) ok=FAIL; why="$why; GATE REFUSAL not attribution" ;; esac
  res "$id" "$label" "$ok" "$why :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
}

BASE="$TMP/base"; mkdir -p "$BASE"
git -C "$ROOT" archive "$BASE_SHA" | tar -x -C "$BASE"

UNPIN='live agent is an unpinned native restore'
UNREAD='live launch settings are unreadable'
ELSE='pinned to another launch generation'

say "=== build rows"
mkrow ua ship 'launch_proof=env-v1' g-ua;   launch "$PANE_ua" wrapper "$CFG_ua"
mkrow ub ship 'launch_proof=env-v1' g-ub;   launch "$PANE_ub" bare "$CFG_ub"
mkrow uc ship 'launch_proof=env-v1' g-uc;   launch "$PANE_uc" noenv "$CFG_uc"
mkrow ud ship 'launch_proof=env-v1' g-ud;   launch "$PANE_ud" bare "$CFG_ud" g-other
wait_up ua unmanaged || res ua setup FAIL x
wait_up ub unmanaged || res ub setup FAIL x
wait_up uc unknown || res uc setup FAIL x
wait_up ud pinned-elsewhere || res ud setup FAIL x
for r in ua ub uc ud; do
  case $r in ua|ub) c=$UNPIN;; uc) c=$UNREAD;; ud) c=$ELSE;; esac
  bad=-; [ "$r" = uc ] || bad=unreadable
  snap "$r" c0
  expect "$r" relaunch-HEAD nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" relaunch --note 'MUST-NOT-ARRIVE'
  snap "$r" c1; unchanged "$r" c0 c1 relaunch-head
  grep -q 'MUST-NOT-ARRIVE' "$TMP/scr-$r-c1.txt" && res "$r" no-input FAIL "marker reached pane" || res "$r" no-input pass "marker absent"
  [ -e "$FM_HOME/state/$r.control-relaunch" ] && res "$r" no-txn FAIL "control-relaunch exists" || res "$r" no-txn pass "no relaunch transaction started"
done
snap ua b0
expect ua relaunch-BASE nz "cannot positively attribute" - bash -c "cd '$BASE' && '$BASE/bin/fm-control.sh' ua relaunch --note MUST-NOT-ARRIVE"
snap ua b1; unchanged ua b0 b1 relaunch-base
say "=== done"
