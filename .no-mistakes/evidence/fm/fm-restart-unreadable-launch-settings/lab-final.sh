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
LOG="$EVID/final-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
RESULTS="$EVID/final-results.tsv"
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
    --session) case "${2:-}" in "$FM_LAB_SESSION"|fm-remote) ;; *) exit 91 ;; esac; shift 2 ;;
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
  local id=$1 kind=$2 proofline=$3 gen=$4 hn=${5:-claude} ws tab
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
    printf 'window=%s:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=%s\nkind=%s\n' \
      "$SESSION" "$PANE" "$id" "$WT" "$TMP/proj" "$hn" "$kind"
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
  run pane read "$pane" --format text > "$EVID/final-screen-$id-ready.txt" 2>&1
  run pane process-info --pane "$pane" > "$EVID/final-procinfo-$id.json" 2>&1
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
  { printf '\n$ %s\n' "$*"; printf '%s\n' "$out"; printf '[exit %s]\n' "$rc"; } >> "$EVID/final-output-$id.txt"
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
mkrow ua ship 'launch_proof=env-v1' g-ua;                launch "$PANE_ua" wrapper "$CFG_ua"        # d1 shape, stand-in teamclaude launcher, no pin
mkrow uc ship 'launch_proof=env-v1' g-uc;                launch "$PANE_uc" noenv "$CFG_uc"          # controlled fault: env -i (no PATH/HOME)
mkrow mk ship 'launch_proof=env-v1' g-mk;                launch "$PANE_mk" wrapper "$CFG_mk" g-mk   # managed
mkrow sm secondmate 'launch_proof=env-v1' g-sm;          launch "$PANE_sm" wrapper "$CFG_sm"        # unpinned restored secondmate
mkrow sk secondmate 'launch_proof=env-v1' g-sk;          launch "$PANE_sk" wrapper "$CFG_sk" g-sk   # managed secondmate (restart positive control)
mkrow rx secondmate 'launch_proof=env-v1' g-rx mytool;   launch "$PANE_rx" bare "$CFG_rx"           # R5-4: raw-command harness, live unpinned agent
mkrow sh ship 'launch_proof=env-v1' g-sh                                                           # shell-only pane
wait_up ua unmanaged || res ua setup FAIL x
wait_up uc unknown || res uc setup FAIL x
wait_up mk managed || res mk setup FAIL x
wait_up sm unmanaged || res sm setup FAIL x
wait_up sk managed || res sk setup FAIL x
wait_up rx unknown || res rx setup FAIL x
say "shell row agent_state=$(fm_backend_agent_state herdr "$SESSION:$PANE_sh")"

pidstart() { local p; p=$(fm_launch_proof_herdr_pid "$FM_HOME/state/$1.meta") || { printf none; return; }; printf '%s@%s' "$p" "$(LC_ALL=C ps -p "$p" -o lstart= 2>/dev/null)"; }
verb() { # <id> <label> <rcw> <has> <hasnt> <cmd...>
  local id=$1 label=$2 p0 p1; shift 2
  snap "$id" "$label-0"; p0=$(pidstart "$id")
  expect "$id" "$label" "$@"
  snap "$id" "$label-1"; p1=$(pidstart "$id")
  unchanged "$id" "$label-0" "$label-1" "$label"
  [ "$p0" = "$p1" ] && res "$id" "$label:same-agent" pass "$p0" || res "$id" "$label:same-agent" FAIL "$p0 -> $p1"
}

say "=== unbounded sweep, base and head"
out_base=$(cd "$BASE" && "$BASE/bin/fm-reboot-recover.sh" recover 2>&1); rc_base=$?
out_head=$("$ROOT/bin/fm-reboot-recover.sh" recover 2>&1); rc_head=$?
{ printf '### BASE %s recover [exit %s]\n%s\n\n### HEAD %s recover [exit %s]\n%s\n' "$BASE_SHA" "$rc_base" "$out_base" "$(git -C "$ROOT" rev-parse HEAD)" "$rc_head" "$out_head"; } > "$EVID/final-sweep-base-vs-head.txt"
for r in ua uc sm; do
  case $r in uc) c=$UNREAD;; *) c=$UNPIN;; esac
  l=$(printf '%s\n' "$out_head" | grep "REBOOT_RECOVERY: $r:"); case "$l" in *"$c"*) res "$r" sweep pass "$l";; *) res "$r" sweep FAIL "${l:-none}";; esac
done
for r in mk sk sh; do printf '%s\n' "$out_head" | grep -q "REBOOT_RECOVERY: $r:" && res "$r" sweep FAIL "line present" || res "$r" sweep pass "no line (managed or stopped)"; done
[ "$rc_base" = "$rc_head" ] && res all sweep-exit pass "base=$rc_base head=$rc_head" || res all sweep-exit FAIL "base=$rc_base head=$rc_head"

say "=== bounded recover --one: two full cycles, head then base"
for side in HEAD BASE; do
  rm -f "$FM_HOME/state/.reboot-recovery-cursor" "$FM_HOME"/state/*.reboot-notice
  : > "$EVID/final-recover-one-$side.txt"
  for n in $(seq 1 14); do
    if [ "$side" = HEAD ]; then o=$("$ROOT/bin/fm-reboot-recover.sh" recover --one 2>&1); rc=$?
    else o=$(cd "$BASE" && "$BASE/bin/fm-reboot-recover.sh" recover --one 2>&1); rc=$?; fi
    printf '#%s cursor=%s rc=%s notices=[%s]\n%s\n' "$n" "$(cat "$FM_HOME/state/.reboot-recovery-cursor" 2>/dev/null)" "$rc" \
      "$(cd "$FM_HOME/state" && ls *.reboot-notice 2>/dev/null | tr '\n' ' ')" "$o" >> "$EVID/final-recover-one-$side.txt"
  done
  cnt=$(grep -c 'REBOOT_RECOVERY:' "$EVID/final-recover-one-$side.txt")
  res all "recover-one-$side" NOTE "report lines over 14 ticks=$cnt; notices=$(cd "$FM_HOME/state" && ls *.reboot-notice 2>/dev/null | tr '\n' ' ')"
done

say "=== control verbs, one snapshot pair each"
for r in ua uc; do
  case $r in ua) c=$UNPIN; bad=unreadable;; uc) c=$UNREAD; bad=-;; esac
  verb "$r" interrupt nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" interrupt
  verb "$r" exit nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" exit
  verb "$r" relaunch nz "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" relaunch --note MUST-NOT-ARRIVE
  verb "$r" recover-launch any "$c" "$bad" "$ROOT/bin/fm-control.sh" "$r" relaunch --recover-launch
  verb "$r" adopt nz "there is no adoption route" - "$ROOT/bin/fm-control.sh" "$r" adopt
done
verb ua recover-launch-BASE any "" - bash -c "cd '$BASE' && '$BASE/bin/fm-control.sh' ua relaunch --recover-launch"

say "=== detector check: a draft in the composer"
run pane send-text "$PANE_ua" "DRAFT-PROBE-ua" >/dev/null; sleep 2
verb ua interrupt-with-draft nz "$UNPIN" unreadable "$ROOT/bin/fm-control.sh" ua interrupt
verb ua exit-with-draft nz "$UNPIN" unreadable "$ROOT/bin/fm-control.sh" ua exit
grep -q 'DRAFT-PROBE-ua' "$TMP/scr-ua-exit-with-draft-1.txt" && res ua draft-kept pass "draft still in composer" || res ua draft-kept FAIL "draft gone"
run pane send-text "$PANE_mk" "DRAFT-PROBE-mk" >/dev/null; sleep 2
snap mk d0; expect mk interrupt-managed 0 "interrupt-delivered" - "$ROOT/bin/fm-control.sh" mk interrupt; sleep 2; snap mk d1
cmp -s "$TMP/scr-mk-d0.txt" "$TMP/scr-mk-d1.txt" && res mk detector NOTE "delivered interrupt left the screen identical" \
  || res mk detector pass "delivered interrupt changed the screen: $(diff "$TMP/scr-mk-d0.txt" "$TMP/scr-mk-d1.txt" | head -6 | tr '\n' '|')"
cp "$TMP/scr-mk-d0.txt" "$EVID/final-mk-before-interrupt.txt"; cp "$TMP/scr-mk-d1.txt" "$EVID/final-mk-after-interrupt.txt"

say "=== restart rows"
rstate() { (find "$FM_HOME/state" "$1/state" -type f ! -name guard-events.jsonl ! -name '.guard-watcher-stale-banner' ! -name '*.lock*' 2>/dev/null | LC_ALL=C sort | xargs cksum 2>/dev/null); }
for r in sm rx sk; do
  eval "w=\$WT_$r"
  snap "$r" rs0; rstate "$w" > "$TMP/rst-$r-0"
  o=$(FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 "$ROOT/bin/fm-secondmate-restart.sh" "$r" 2>&1); rc=$?
  sleep 2; snap "$r" rs1; rstate "$w" > "$TMP/rst-$r-1"
  { printf '$ fm-secondmate-restart.sh %s\n%s\n[exit %s]\n--- state files added/changed:\n' "$r" "$o" "$rc"; diff "$TMP/rst-$r-0" "$TMP/rst-$r-1"; } > "$EVID/final-restart-$r.txt"
  case $r in
    sm) case "$o" in *"unreached: sm:"*"$UNPIN"*) res sm restart pass "$(printf '%s' "$o" | head -1)";; *) res sm restart FAIL "$o";; esac
        cmp -s "$TMP/rst-$r-0" "$TMP/rst-$r-1" && res sm restart-no-records pass "no record created" || res sm restart-no-records FAIL "$(diff "$TMP/rst-$r-0" "$TMP/rst-$r-1" | tr '\n' '|')"
        unchanged sm rs0 rs1 restart ;;
    rx) case "$o" in *"unreached: rx:"*) res rx restart pass "$(printf '%s' "$o" | head -1)";; *) res rx restart FAIL "$o";; esac
        cmp -s "$TMP/rst-$r-0" "$TMP/rst-$r-1" && res rx restart-no-records pass "no record created" || res rx restart-no-records FAIL "$(diff "$TMP/rst-$r-0" "$TMP/rst-$r-1" | tr '\n' '|')"
        unchanged rx rs0 rs1 restart ;;
    sk) case "$o" in *"unreached: sk:"*) res sk restart FAIL "managed mate refused: $o";; *"nudged: sk"*|*"restarted: sk"*) res sk restart pass "$(printf '%s' "$o" | head -1)";; *) res sk restart CHECK "$o";; esac
        cmp -s "$TMP/rst-$r-0" "$TMP/rst-$r-1" && res sk restart-effects FAIL "managed mate got no effect" || res sk restart-effects pass "$(diff "$TMP/rst-$r-0" "$TMP/rst-$r-1" | grep '^>' | tr '\n' '|' | cut -c1-400)"
        cp "$TMP/scr-sk-rs1.txt" "$EVID/final-sk-after-restart.txt" ;;
  esac
done

say "=== host attribution verb (fm-remote mapped to the lab session)"
hostrow() { # <host-id> <source-row> <expect-prefix>
  local hid=$1 src=$2 want=$3 rh="$TMP/rhome-$1" sm o tgt
  mkdir -p "$rh/state/parent-route" "$rh/data/.parent-route" "$rh/bin" "$rh/config"
  printf '%s\n' "$hid" > "$rh/.fm-secondmate-home"; printf '# host home\n' > "$rh/AGENTS.md"
  sed -e "s#^window=$SESSION:#window=fm-remote:#" -e "s#^herdr_session=.*#herdr_session=fm-remote#" \
      -e "s#^endpoint_task_id=.*#endpoint_task_id=$hid#" "$FM_HOME/state/$src.meta" > "$rh/state/parent-route/$hid.meta"
  tgt=$(sed -n 's/^window=//p' "$rh/state/parent-route/$hid.meta")
  o=$(FM_HOME="$rh" "$ROOT/bin/fm-remote-secondmate-control.sh" attribution "$hid" "$tgt" 2>&1); printf '$ attribution %s %s  (source row %s)\n%s\n\n' "$hid" "$tgt" "$src" "$o" >> "$EVID/final-host-attribution.txt"
  case "$o" in "$want"*) res "$hid" host-attribution pass "$o";; *) res "$hid" host-attribution FAIL "$o";; esac
  if [ "$hid" = hu ]; then
    o=$(FM_HOME="$rh" "$ROOT/bin/fm-remote-secondmate-control.sh" attribution "$hid" "fm-remote:w99:p9" 2>&1); printf '$ attribution %s fm-remote:w99:p9 (wrong target)\n%s\n\n' "$hid" "$o" >> "$EVID/final-host-attribution.txt"
    case "$o" in "attribution=refuse:"*) res hu host-wrong-target pass "$o";; *) res hu host-wrong-target FAIL "$o";; esac
  fi
}
: > "$EVID/final-host-attribution.txt"
hostrow hu ua "attribution=refuse: its live Herdr agent cannot be positively attributed to this task: $UNPIN"
hostrow hm mk "attribution=proceed"
hostrow hs sh "attribution=proceed"

say "=== plain fm-send steer (not a lifecycle consumer), head then base"
verb ua fm-send-HEAD any "" - "$ROOT/bin/fm-send.sh" ua "steer probe head"
verb ua fm-send-BASE any "" - bash -c "cd '$BASE' && '$BASE/bin/fm-send.sh' ua 'steer probe base'"
for r in ua uc mk sm sk rx; do run pane read "$(eval "printf %s \$PANE_$r")" --format text > "$EVID/final-screen-$r-end.txt" 2>&1; done
say "=== done"
