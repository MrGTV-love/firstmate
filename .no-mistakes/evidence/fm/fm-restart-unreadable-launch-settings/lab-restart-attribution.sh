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
LOG="$EVID/lab-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RESULTS="$EVID/lab-results.tsv"
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
  run pane read "$pane" --format text > "$EVID/screen-$id-ready.txt" 2>&1
  run pane process-info --pane "$pane" > "$EVID/procinfo-$id.json" 2>&1
  say "row $id: verdict=$v agent_state=$st (want $want/alive)"
  [ "$v" = "$want" ] && [ "$st" = alive ]
}

snap() { # <id> <tag>
  local id=$1 pane; eval "pane=\$PANE_$id"
  run pane read "$pane" --format text > "$TMP/scr-$id-$2.txt" 2>&1
  (cd "$FM_HOME" && find state -type f ! -name '.reboot-recovery-cursor' ! -name '*.reboot-notice' -print | LC_ALL=C sort | xargs cksum) > "$TMP/st-$2.txt" 2>&1
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
  { printf '\n$ %s\n' "$*"; printf '%s\n' "$out"; printf '[exit %s]\n' "$rc"; } >> "$EVID/consumer-output-$id.txt"
  local ok=pass why="rc=$rc"
  case "$rcw" in nz) [ "$rc" != 0 ] || { ok=FAIL; why="expected nonzero, got 0"; } ;; 0) [ "$rc" = 0 ] || { ok=FAIL; why="expected 0, got $rc"; } ;; esac
  case "$out" in *"$has"*) ;; *) ok=FAIL; why="$why; missing '$has'" ;; esac
  [ "$hasnt" = - ] || case "$out" in *"$hasnt"*) ok=FAIL; why="$why; contains forbidden '$hasnt'" ;; esac
  case "$out" in *"gate"*refus*|*"no-mistakes gate"*) ok=FAIL; why="$why; GATE REFUSAL not attribution" ;; esac
  res "$id" "$label" "$ok" "$why :: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
}

BASE="$TMP/base"; mkdir -p "$BASE"
git -C "$ROOT" archive "$BASE_SHA" | tar -x -C "$BASE"

UNPIN='live agent is an unpinned native restore'
UNREAD='live launch settings are unreadable'
ELSE='pinned to another launch generation'

say "=== build rows"
mkrow ua ship 'launch_proof=env-v1' g-ua;   launch "$PANE_ua" wrapper "$CFG_ua"            # d1 shape: TeamClaude wrapper, no pin
mkrow ub ship 'launch_proof=env-v1' g-ub;   launch "$PANE_ub" bare "$CFG_ub"               # bare personal claude, same pane/dir, no pin
mkrow uc ship 'launch_proof=env-v1' g-uc;   launch "$PANE_uc" noenv "$CFG_uc"              # environment without PATH/HOME (unreadable)
mkrow ud ship 'launch_proof=env-v1' g-ud;   launch "$PANE_ud" bare "$CFG_ud" g-other       # pinned to another generation
mkrow mk ship 'launch_proof=env-v1' g-mk;   launch "$PANE_mk" wrapper "$CFG_mk" g-mk       # managed: matching pin
mkrow lg ship - g-lg;                       launch "$PANE_lg" bare "$CFG_lg"               # legacy: no launch_proof line
mkrow sh ship 'launch_proof=env-v1' g-sh                                                  # shell-only pane (stopped)
mkrow sm secondmate 'launch_proof=env-v1' g-sm; launch "$PANE_sm" wrapper "$CFG_sm"        # unpinned restored secondmate

wait_up ua unmanaged || res ua setup FAIL "row did not reach unmanaged/alive"
wait_up ub unmanaged || res ub setup FAIL "row did not reach unmanaged/alive"
wait_up uc unknown   || res uc setup FAIL "row did not reach unknown/alive"
wait_up ud pinned-elsewhere || res ud setup FAIL "row did not reach pinned-elsewhere/alive"
wait_up mk managed   || res mk setup FAIL "row did not reach managed/alive"
wait_up lg unmanaged || res lg setup NOTE "legacy row verdict differs (legacy is judged by record, not verdict)"
wait_up sm unmanaged || res sm setup FAIL "row did not reach unmanaged/alive"
say "shell row agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_sh")"
ps -o pid,ppid,pgid,command -p "$(jq -r '[.result.process_info.foreground_processes[].pid]|join(",")' "$EVID/procinfo-ua.json")" >> "$LOG" 2>&1

say "=== reboot sweep: base vs head (all rows present)"
for r in ua ub uc ud mk lg sm; do snap "$r" pre-sweep; done
out_base=$(cd "$BASE" && "$BASE/bin/fm-reboot-recover.sh" recover 2>&1); rc_base=$?
out_head=$("$ROOT/bin/fm-reboot-recover.sh" recover 2>&1); rc_head=$?
{ printf '### BASE %s  fm-reboot-recover.sh recover  [exit %s]\n%s\n\n### HEAD %s  fm-reboot-recover.sh recover  [exit %s]\n%s\n' \
  "$BASE_SHA" "$rc_base" "$out_base" "$(git -C "$ROOT" rev-parse HEAD)" "$rc_head" "$out_head"; } > "$EVID/reboot-sweep-base-vs-head.txt"
cat "$EVID/reboot-sweep-base-vs-head.txt" >> "$LOG"
line() { printf '%s\n' "$1" | grep "REBOOT_RECOVERY: $2:" | head -1; }
l=$(line "$out_head" ua); case "$l" in *"$UNPIN"*) case "$l" in *unreadable*) res ua sweep FAIL "$l";; *) res ua sweep pass "$l";; esac;; *) res ua sweep FAIL "${l:-no line}";; esac
l=$(line "$out_base" ua); case "$l" in *unreadable*) res ua sweep-base pass "base defect reproduced: $l";; *) res ua sweep-base NOTE "${l:-no line}";; esac
l=$(line "$out_head" ub); case "$l" in *"$UNPIN"*) res ub sweep pass "$l";; *) res ub sweep FAIL "${l:-no line}";; esac
l=$(line "$out_head" uc); case "$l" in *"$UNREAD"*) res uc sweep pass "$l";; *) res uc sweep FAIL "${l:-no line}";; esac
l=$(line "$out_head" ud); case "$l" in *"$ELSE"*|*"pinned elsewhere"*) res ud sweep pass "$l";; *) res ud sweep FAIL "${l:-no line}";; esac
l=$(line "$out_head" mk); [ -z "$l" ] && res mk sweep pass "managed agent: no sweep line" || res mk sweep FAIL "$l"
l=$(line "$out_head" sm); case "$l" in *"$UNPIN"*) res sm sweep pass "$l";; *) res sm sweep FAIL "${l:-no line}";; esac
lb=$(line "$out_base" lg); lh=$(line "$out_head" lg); [ "$lb" = "$lh" ] && res lg sweep-base-eq-head pass "${lh:-no line on either}" || res lg sweep-base-eq-head CHECK "base='$lb' head='$lh'"
for r in ua ub uc ud mk sm; do snap "$r" post-sweep; unchanged "$r" pre-sweep post-sweep sweep; done

say "=== control-plane consumers on unproven live agents"
for r in ua ub uc ud; do
  case $r in ua|ub) c=$UNPIN;; uc) c=$UNREAD;; ud) c=$ELSE;; esac
  bad=-; [ "$r" = uc ] || bad=unreadable
  snap "$r" c0
  expect "$r" interrupt nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" interrupt
  expect "$r" exit nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" exit
  expect "$r" relaunch nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" relaunch --note 'MUST-NOT-ARRIVE'
  expect "$r" recover-launch any "launch=" "$bad" "$ROOT/bin/fm-control.sh" "$r" relaunch --recover-launch
  expect "$r" adopt nz "adopt" - "$ROOT/bin/fm-control.sh" "$r" adopt
  expect "$r" fm-send nz "" - "$ROOT/bin/fm-send.sh" "$r" "MUST-NOT-ARRIVE send"
  snap "$r" c1; unchanged "$r" c0 c1 consumers
  grep -q 'MUST-NOT-ARRIVE' "$TMP/scr-$r-c1.txt" && res "$r" no-input FAIL "marker text reached pane" || res "$r" no-input pass "marker text absent from pane"
done

say "=== base comparison of control refusal for the d1 shape"
snap ua b0
expect ua interrupt-BASE nz "cannot positively attribute" - bash -c "cd '$BASE' && '$BASE/bin/fm-control.sh' ua interrupt"
snap ua b1; unchanged ua b0 b1 base-interrupt

say "=== restart on an unpinned restored secondmate"
snap sm r0
rs_out=$(FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 "$ROOT/bin/fm-secondmate-restart.sh" sm 2>&1); rs_rc=$?
printf '$ fm-secondmate-restart.sh sm\n%s\n[exit %s]\n' "$rs_out" "$rs_rc" > "$EVID/restart-sm.txt"
cat "$EVID/restart-sm.txt" >> "$LOG"
case "$rs_out" in *"unreached: sm:"*"$UNPIN"*) [ "$rs_rc" = 3 ] && res sm restart pass "$(printf '%s' "$rs_out" | grep unreached)" || res sm restart FAIL "rc=$rs_rc";; *) res sm restart FAIL "$rs_out";; esac
snap sm r1; unchanged sm r0 r1 restart
ls -laR "$FM_HOME/state" "$WT_sm/state" > "$EVID/restart-sm-state-after.txt" 2>&1
n=$(find "$FM_HOME/state" "$WT_sm/state" \( -name '*.msg' -o -name '*pending*' -o -name '*reply*' \) | wc -l | tr -d ' ')
[ "$n" = 0 ] && res sm restart-no-records pass "no inbox/pending-reply records" || res sm restart-no-records FAIL "$n records"
rb_out=$(cd "$BASE" && FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 "$BASE/bin/fm-secondmate-restart.sh" sm 2>&1); rb_rc=$?
printf '### BASE restart (for comparison)\n%s\n[exit %s]\n' "$rb_out" "$rb_rc" >> "$EVID/restart-sm.txt"
snap sm r2; res sm restart-BASE NOTE "base rc=$rb_rc :: $(printf '%s' "$rb_out" | tr '\n' ' ' | cut -c1-300)"

say "=== positive controls"
# managed: interrupt is authorized and lands (base and head same)
expect mk interrupt-HEAD 0 "" - "$ROOT/bin/fm-control.sh" mk interrupt
expect mk interrupt-BASE 0 "" - bash -c "cd '$BASE' && '$BASE/bin/fm-control.sh' mk interrupt"
# legacy record: interrupt keeps its pre-proof outcome on both
expect lg interrupt-HEAD 0 "" - "$ROOT/bin/fm-control.sh" lg interrupt
expect lg interrupt-BASE 0 "" - bash -c "cd '$BASE' && '$BASE/bin/fm-control.sh' lg interrupt"
# shell-only pane: exit reports already stopped on both
expect sh exit-HEAD any "" - "$ROOT/bin/fm-control.sh" sh exit
expect sh exit-BASE any "" - bash -c "cd '$BASE' && '$BASE/bin/fm-control.sh' sh exit"
grep -h '' "$EVID/consumer-output-sh.txt" >> "$LOG"
for r in ua ub uc ud mk lg sm; do run pane read "$(eval "printf %s \$PANE_$r")" --format text > "$EVID/screen-$r-final.txt" 2>&1; done
say "=== done"
