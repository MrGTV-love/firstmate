#!/usr/bin/env bash
# Live lab driver for fm/fm-restart-unreadable-launch-settings.
# Runs real Herdr (named fm-lab-* session via bin/fm-herdr-lab.sh), real
# `claude` agents and the real product scripts at head and base, in a marked
# disposable lab home. Never touches the default Herdr session or real fleet.
# Usage: lab-drive.sh <worktree> <evidence-dir>
set -u
WTREE=$1
EV=$2
cd "$WTREE" || exit 1
unset FM_SPAWN_GEN HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV HERDR_SESSION TMUX TMUX_PANE \
  FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
LOG="$EV/lab-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { say ""; say "=================== $* ==================="; }

eval "$(bin/fm-lab-home.sh env 2>"$EV/.labhome.err")" || { cat "$EV/.labhome.err"; exit 1; }
TEARDOWN_LINE=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/.labhome.err"); rm -f "$EV/.labhome.err"
LAB=$FM_HOME
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-e1-aux.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
HELPER="$WTREE/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name e1claude)
REAL_PATH=$PATH
OWNED=0
cleanup() {
  sec "TEARDOWN"
  if [ "$OWNED" = 1 ]; then PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" 2>&1 | tee -a "$LOG"; fi
  sleep 2
  for p in $(cat "$TMP/pids" 2>/dev/null); do
    if kill -0 "$p" 2>/dev/null; then say "pid $p still alive after teardown"; else say "pid $p gone"; fi
  done
  eval "$TEARDOWN_LINE" && say "lab home removed: $LAB"
  rm -rf "$TMP" && say "aux tree removed: $TMP"
}
trap cleanup EXIT
say "lab home: $LAB"; say "herdr session: $SESSION"; say "head: $(git rev-parse HEAD)"
[ -f "$LAB/.fm-lab-home" ] || ls -a "$LAB" | tee -a "$LOG"

# Base tree (read-only extract of the base commit) for base-vs-head comparison.
BASE="$TMP/base"; mkdir -p "$BASE"
git archive 032c4871b727d48419bfffca6f2654b345fbafd6 | tar -x -C "$BASE"
say "base tree: $BASE (032c4871b)"

"$HELPER" prepare "$SESSION" >>"$LOG" 2>&1 || exit 1
OWNED=1
"$HELPER" provision "$SESSION" >>"$LOG" 2>&1 || exit 1
export HERDR_SESSION=$SESSION FM_LAB_REAL_PATH=$PATH FM_LAB_HELPER=$HELPER FM_LAB_SESSION=$SESSION
mkdir -p "$TMP/fakebin" "$TMP/standin/bin"
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
# Stand-in for the TeamClaude forwarding launcher (NOT the real teamclaude,
# which manages accounts): node script named teamclaude, `run --` form, real
# claude as its direct child in the same process group.
cat > "$TMP/standin/bin/teamclaude" <<'JS'
const { spawn } = require('node:child_process');
const i = process.argv.indexOf('--');
const child = spawn('claude', i >= 0 ? process.argv.slice(i + 1) : [], { stdio: 'inherit' });
child.on('exit', (c) => process.exit(c ?? 0));
JS
export PATH="$TMP/fakebin:$PATH"
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects"
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'off\n' > "$LAB/config/herdr-presentation-spaces"

new_wt() { # <name> -> path
  local p="$LAB/projects/$1"
  mkdir -p "$p" && git -C "$p" init -q && git -C "$p" -c user.email=lab@x -c user.name=lab commit -q --allow-empty -m init
  git -C "$p" worktree add -q "$TMP/wt-$1" -b "fm/$1" >/dev/null 2>&1
  (cd "$TMP/wt-$1" && pwd -P)
}
new_pane() { # <cwd> <label> -> "ws pane tab"
  local ws pane tab
  ws=$(run workspace create --cwd "$1" --label "$2" | jq -r '.result.workspace.workspace_id')
  pane=$(run pane list --workspace "$ws" | jq -r '.result.panes[0].pane_id')
  tab=$(run pane get "$pane" | jq -r '.result.pane.tab_id')
  printf '%s %s %s' "$ws" "$pane" "$tab"
}
write_meta() { # <id> <ws> <pane> <tab> <wt> <kind> <proof-line|-> [home]
  local id=$1 ws=$2 pane=$3 tab=$4 wt=$5 kind=$6 proof=$7 home=${8:-}
  {
    printf 'window=%s:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' "$SESSION" "$pane" "$id" "$wt" "$wt"
    [ -z "$home" ] || printf 'home=%s\n' "$home"
    printf 'harness=claude\nkind=%s\nmode=%s\nspawn_gen=gen-%s\n' "$kind" "$([ "$kind" = secondmate ] && echo secondmate || echo no-mistakes)" "$id"
    [ "$proof" = - ] || printf '%s\n' "$proof"
    printf 'yolo=off\nmodel=opus\neffort=low\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$ws" "$tab" "$pane"
  } > "$LAB/state/$id.meta"
  mkdir -p "$LAB/data/$id"; printf '# Task\nIdle lab fixture.\n' > "$LAB/data/$id/brief.md"
}
launch() { # <pane> <command...>
  local cmd; printf -v cmd '%q ' "$@"
  run pane send-text "$1" "${cmd#* }" >/dev/null; run pane send-keys "$1" Enter >/dev/null
}

. "$WTREE/bin/fm-backend.sh"; fm_backend_source herdr; . "$WTREE/bin/fm-launch-proof-lib.sh"

# ---------- fixtures ----------
WT_U=$(new_wt e1-unpinned); read -r WS_U P_U TAB_U <<<"$(new_pane "$WT_U" fm-e1-unpinned)"
write_meta e1-unpinned "$WS_U" "$P_U" "$TAB_U" "$WT_U" ship launch_proof=env-v1
WT_P=$(new_wt e1-pinned); read -r WS_P P_P TAB_P <<<"$(new_pane "$WT_P" fm-e1-pinned)"
write_meta e1-pinned "$WS_P" "$P_P" "$TAB_P" "$WT_P" ship launch_proof=env-v1
WT_L=$(new_wt e1-legacy); read -r WS_L P_L TAB_L <<<"$(new_pane "$WT_L" fm-e1-legacy)"
write_meta e1-legacy "$WS_L" "$P_L" "$TAB_L" "$WT_L" ship -
WT_R=$(new_wt e1-unread); read -r WS_R P_R TAB_R <<<"$(new_pane "$WT_R" fm-e1-unread)"
write_meta e1-unread "$WS_R" "$P_R" "$TAB_R" "$WT_R" ship launch_proof=env-v1
WT_G=$(new_wt e1-nogen); read -r WS_G P_G TAB_G <<<"$(new_pane "$WT_G" fm-e1-nogen)"
write_meta e1-nogen "$WS_G" "$P_G" "$TAB_G" "$WT_G" ship launch_proof=env-v1
grep -v '^spawn_gen=' "$LAB/state/e1-nogen.meta" > "$TMP/m" && mv "$TMP/m" "$LAB/state/e1-nogen.meta"
WT_S=$(new_wt e1-shell); read -r WS_S P_S TAB_S <<<"$(new_pane "$WT_S" fm-e1-shell)"
write_meta e1-shell "$WS_S" "$P_S" "$TAB_S" "$WT_S" ship launch_proof=env-v1
MH=$(new_wt e1-mate); read -r WS_M P_M TAB_M <<<"$(new_pane "$MH" fm-e1-mate)"
mkdir -p "$MH/state/operational-inbox" "$MH/data"
printf 'e1-mate\n' > "$MH/.fm-secondmate-home"; printf '# lab mate\n' > "$MH/AGENTS.md"; printf 'Idle lab mate.\n' > "$MH/data/charter.md"
write_meta e1-mate "$WS_M" "$P_M" "$TAB_M" "$MH" secondmate launch_proof=env-v1 "$MH"
printf 'claude opus high\n' > "$LAB/config/secondmate-harness"

launch "$P_U" env -u FM_SPAWN_GEN -u FM_HOME claude
launch "$P_P" env -u FM_HOME FM_SPAWN_GEN=gen-e1-pinned claude
launch "$P_L" env -u FM_SPAWN_GEN -u FM_HOME claude
launch "$P_R" env -i TERM=xterm-256color "$(command -v claude)"
launch "$P_G" env -u FM_SPAWN_GEN -u FM_HOME claude
launch "$P_M" env -u FM_SPAWN_GEN -u FM_HOME node "$TMP/standin/bin/teamclaude" run --
sleep 12

sec "PRECONDITIONS (live state per pane)"
for id in e1-unpinned e1-pinned e1-legacy e1-unread e1-nogen e1-shell e1-mate; do
  meta="$LAB/state/$id.meta"; t=$(sed -n 's/^window=//p' "$meta")
  pid=$(fm_launch_proof_herdr_pid "$meta" 2>/dev/null || true)
  envpin='-'; if [ -n "$pid" ]; then e=$(fm_remote_herdr_process_env "$pid" 2>/dev/null) && envpin=$(printf '%s\n' "$e" | grep -Eq '^(PATH|HOME)=' && { printf '%s\n' "$e" | sed -n 's/^FM_SPAWN_GEN=/pin=/p' | grep . || echo readable-no-pin; } || echo no-PATH-HOME) || envpin=env-read-failed; fi
  say "$id: state=$(fm_backend_agent_state herdr "$t") verdict=$(fm_launch_proof_herdr "$meta") pid=${pid:-none} cmd=$( [ -n "$pid" ] && ps -o command= -p "$pid" | cut -c1-80) env=$envpin"
  [ -n "$pid" ] && echo "$pid" >> "$TMP/pids"
done
cpid=$(pgrep -P "$(fm_launch_proof_herdr_pid "$LAB/state/e1-mate.meta")" 2>/dev/null | head -1)
say "e1-mate stand-in launcher child: pid=$cpid cmd=$(ps -o command= -p "$cpid" 2>/dev/null) pgid=$(ps -o pgid= -p "$cpid" 2>/dev/null) cwd=$(lsof -a -p "$cpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
[ -n "$cpid" ] && echo "$cpid" >> "$TMP/pids"
for p in P_U P_P P_L P_R P_G P_M P_S; do run pane read "${!p}" --format text > "$EV/screen-$p-start.txt" 2>&1; done

snap() { # <label>
  { find "$LAB" "$MH" -path '*/.git' -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum; } > "$TMP/snap-$1" 2>/dev/null
}
screens() { local id p; for id in e1-unpinned e1-legacy e1-unread e1-nogen e1-mate; do p=$(sed -n 's/^herdr_pane_id=//p' "$LAB/state/$id.meta"); run pane read "$p" --format text; printf '\n--%s pid %s\n' "$id" "$(fm_launch_proof_herdr_pid "$LAB/state/$id.meta")"; done > "$TMP/screens-$1"; }
diffsnap() { # <a> <b> <title>
  if cmp -s "$TMP/snap-$1" "$TMP/snap-$2"; then say "[$3] lab home + mate home files: unchanged"
  else say "[$3] lab home + mate home file changes:"; diff "$TMP/snap-$1" "$TMP/snap-$2" | sed 's/^/    /' | tee -a "$LOG" >/dev/null; diff "$TMP/snap-$1" "$TMP/snap-$2" | sed 's/^/    /'; fi
  if cmp -s "$TMP/screens-$1" "$TMP/screens-$2"; then say "[$3] refused panes (screen text + attributed pid): unchanged"
  else say "[$3] refused panes CHANGED:"; diff "$TMP/screens-$1" "$TMP/screens-$2" | head -40 | tee -a "$LOG"; fi
}
clear_notices() { rm -f "$LAB/state"/*.reboot-notice "$LAB/state/.reboot-recovery-cursor"; }
cmdrun() { # <tree> <label> <cmd...>
  local tree=$1 label=$2 out rc; shift 2
  out=$(cd "$WTREE" && "$tree/bin/$@" 2>&1 </dev/null); rc=$?
  say "--- [$label] \$ bin/$* (exit $rc)"; printf '%s\n' "$out" | sed 's/^/    /' | tee -a "$LOG"
}

V_U=$(fm_launch_proof_herdr "$LAB/state/e1-unpinned.meta"); V_M=$(fm_launch_proof_herdr "$LAB/state/e1-mate.meta")
REFUSED="e1-unpinned e1-mate"
for id in e1-unread e1-nogen; do
  v=$(fm_launch_proof_herdr "$LAB/state/$id.meta"); st=$(fm_backend_agent_state herdr "$(sed -n 's/^window=//p' "$LAB/state/$id.meta")")
  if [ "$v" = unknown ] && [ "$st" = alive ]; then REFUSED="$REFUSED $id"; else say "GUARD: $id is $st/$v, not alive/unknown; its consumers are skipped"; fi
done
if [ "$V_U" != unmanaged ] || [ "$V_M" != unmanaged ]; then say "GUARD: unpinned fixtures are $V_U/$V_M, not unmanaged; stopping before any consumer"; exit 1; fi
for TREE_NAME in base head; do
  TREE=$([ "$TREE_NAME" = base ] && echo "$BASE" || echo "$WTREE")
  sec "$TREE_NAME: reboot sweep + control verbs on refused panes"
  clear_notices; snap pre-$TREE_NAME; screens pre-$TREE_NAME
  cmdrun "$TREE" "$TREE_NAME" fm-reboot-recover.sh recover
  cmdrun "$TREE" "$TREE_NAME repeat, unbounded" fm-reboot-recover.sh recover
  for id in $REFUSED; do
    cmdrun "$TREE" "$TREE_NAME" fm-control.sh "$id" interrupt
    cmdrun "$TREE" "$TREE_NAME" fm-control.sh "$id" exit
  done
  if [ "$TREE_NAME" = head ]; then
    for id in $REFUSED; do
      cmdrun "$TREE" head fm-control.sh "$id" relaunch --note 'must not reach'
      cmdrun "$TREE" head fm-control.sh "$id" relaunch --recover-launch
    done
    cmdrun "$TREE" head fm-control.sh e1-unpinned adopt
    cmdrun "$TREE" head fm-control.sh e1-mate adopt
    sec "head: secondmate restart on an unpinned wrapper-launched mate"
    FM_SECONDMATE_PERSIST_WAIT=5 FM_SECONDMATE_PERSIST_POLL=1 cmdrun "$TREE" head fm-secondmate-restart.sh e1-mate
    say "mate operational inbox: $(find "$MH/state/operational-inbox" -type f | wc -l | tr -d ' ') file(s)"
    say "pending-reply records in lab state: $(find "$LAB/state" -name '*pending*' | wc -l | tr -d ' ')"
  fi
  snap post-$TREE_NAME; screens post-$TREE_NAME
  diffsnap pre-$TREE_NAME post-$TREE_NAME "$TREE_NAME"
done

sec "head: --one bounded sweep cursor + notice suppression"
clear_notices
for n in 1 2 3 4 5 6 7 8; do cmdrun "$WTREE" "head --one #$n" fm-reboot-recover.sh recover --one; say "    cursor=$(cat "$LAB/state/.reboot-recovery-cursor" 2>/dev/null)"; done
say "notices: $(cd "$LAB/state" && ls *.reboot-notice 2>/dev/null | tr '\n' ' ')"
for f in "$LAB/state"/*.reboot-notice; do say "  ${f##*/}: $(tr '\n' ' ' < "$f")"; done
sec "base: --one bounded sweep for comparison"
clear_notices
for n in 1 2 3 4 5 6 7 8; do cmdrun "$BASE" "base --one #$n" fm-reboot-recover.sh recover --one; say "    cursor=$(cat "$LAB/state/.reboot-recovery-cursor" 2>/dev/null)"; done
for f in "$LAB/state"/*.reboot-notice; do say "  ${f##*/}: $(tr '\n' ' ' < "$f")"; done
clear_notices

sec "stopped control: shell-only pane, exit (base then head)"
cmdrun "$BASE" base fm-control.sh e1-shell exit
cmdrun "$WTREE" head fm-control.sh e1-shell exit

sec "positive control (k): pinned claude; adversarial: peer record names same worktree (reboot sweep)"
peer() { printf 'window=%s:p_absent\nworktree=%s\nharness=claude\nkind=ship\nbackend=herdr\n' "$SESSION" "$WT_P" > "$LAB/state/e1-peer.meta"; }
verdict_in() { bash -c ". '$1/bin/fm-backend.sh'; fm_backend_source herdr; . '$1/bin/fm-launch-proof-lib.sh'; fm_launch_proof_herdr '$LAB/state/e1-pinned.meta'"; }
for TREE_NAME in base head; do
  TREE=$([ "$TREE_NAME" = base ] && echo "$BASE" || echo "$WTREE")
  clear_notices
  say "pinned verdict, no peer ($TREE_NAME lib): $(verdict_in "$TREE")"
  peer; say "pinned verdict, with peer ($TREE_NAME lib): $(verdict_in "$TREE")"
  cmdrun "$TREE" "$TREE_NAME with peer" fm-reboot-recover.sh recover
  rm -f "$LAB/state/e1-peer.meta"
  cmdrun "$TREE" "$TREE_NAME no peer" fm-reboot-recover.sh recover
  say "e1-pinned notice after no-peer sweep: $(cat "$LAB/state/e1-pinned.reboot-notice" 2>/dev/null || echo none)"
done
clear_notices
sec "positive control (k) + adversarial via interrupt (Escape: on Claude's trust screen this ends the pinned claude)"
relaunch_pinned() { launch "$P_P" env -u FM_HOME FM_SPAWN_GEN=gen-e1-pinned claude; sleep 10; fm_launch_proof_herdr_pid "$LAB/state/e1-pinned.meta" >> "$TMP/pids"; echo >> "$TMP/pids"; say "pinned relaunched by hand in pane: state=$(fm_backend_agent_state herdr "$SESSION:$P_P") verdict=$(fm_launch_proof_herdr "$LAB/state/e1-pinned.meta")"; }
peer; cmdrun "$BASE" "base with peer" fm-control.sh e1-pinned interrupt; rm -f "$LAB/state/e1-peer.meta"
sleep 3; say "pinned state after base interrupt: $(fm_backend_agent_state herdr "$SESSION:$P_P")"
[ "$(fm_backend_agent_state herdr "$SESSION:$P_P")" = alive ] || relaunch_pinned
peer; cmdrun "$WTREE" "head with peer" fm-control.sh e1-pinned interrupt; rm -f "$LAB/state/e1-peer.meta"
sleep 3; say "pinned state after head with-peer interrupt: $(fm_backend_agent_state herdr "$SESSION:$P_P")"
[ "$(fm_backend_agent_state herdr "$SESSION:$P_P")" = alive ] || relaunch_pinned
cmdrun "$BASE" "base no peer" fm-control.sh e1-pinned interrupt
sleep 3; say "pinned state after base interrupt: $(fm_backend_agent_state herdr "$SESSION:$P_P")"
[ "$(fm_backend_agent_state herdr "$SESSION:$P_P")" = alive ] || relaunch_pinned
cmdrun "$WTREE" "head no peer" fm-control.sh e1-pinned interrupt
sleep 3; say "pinned state after head interrupt: $(fm_backend_agent_state herdr "$SESSION:$P_P")"
run pane read "$P_P" --format text > "$EV/screen-pinned-after-interrupts.txt" 2>&1
sec "legacy control (j): legacy record (no launch_proof), exit on base and head"
say "legacy state: $(fm_backend_agent_state herdr "$SESSION:$P_L")"
cmdrun "$BASE" base fm-control.sh e1-legacy exit
say "legacy state after base exit: $(fm_backend_agent_state herdr "$SESSION:$P_L")"
cmdrun "$WTREE" head fm-control.sh e1-legacy exit
say "legacy state after head exit: $(fm_backend_agent_state herdr "$SESSION:$P_L")"
for p in P_U P_M P_R P_G; do run pane read "${!p}" --format text > "$EV/screen-$p-end.txt" 2>&1; done
say "DONE"
