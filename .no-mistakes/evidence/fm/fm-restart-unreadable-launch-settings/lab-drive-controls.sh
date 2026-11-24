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
LOG="$EV/lab-controls-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
sec() { say ""; say "=================== $* ==================="; }

eval "$(bin/fm-lab-home.sh env 2>"$EV/.labhome.err")" || { cat "$EV/.labhome.err"; exit 1; }
TEARDOWN_LINE=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/.labhome.err"); rm -f "$EV/.labhome.err"
LAB=$FM_HOME
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-e1-aux.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
HELPER="$WTREE/bin/fm-herdr-lab.sh"
SESSION=$("$HELPER" name e1ctl)
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

# ---------- fixtures (controls only) ----------
WT_P=$(new_wt e1-pinned); read -r WS_P P_P TAB_P <<<"$(new_pane "$WT_P" fm-e1-pinned)"
write_meta e1-pinned "$WS_P" "$P_P" "$TAB_P" "$WT_P" ship launch_proof=env-v1
WT_L=$(new_wt e1-legacy); read -r WS_L P_L TAB_L <<<"$(new_pane "$WT_L" fm-e1-legacy)"
write_meta e1-legacy "$WS_L" "$P_L" "$TAB_L" "$WT_L" ship -
cmdrun() { local tree=$1 label=$2 out rc; shift 2; out=$(cd "$WTREE" && "$tree/bin/$@" 2>&1 </dev/null); rc=$?; say "--- [$label] \$ bin/$* (exit $rc)"; printf '%s\n' "$out" | sed 's/^/    /' | tee -a "$LOG"; }
st() { fm_backend_agent_state herdr "$SESSION:$1"; }
launch "$P_L" env -u FM_SPAWN_GEN -u FM_HOME claude
pinned() { launch "$P_P" env -u FM_HOME FM_SPAWN_GEN=gen-e1-pinned claude; sleep 10; fm_launch_proof_herdr_pid "$LAB/state/e1-pinned.meta" >> "$TMP/pids"; echo >> "$TMP/pids"; say "pinned claude started by hand in its pane: state=$(st "$P_P") verdict=$(fm_launch_proof_herdr "$LAB/state/e1-pinned.meta") pid=$(fm_launch_proof_herdr_pid "$LAB/state/e1-pinned.meta")"; }
peer() { printf 'window=%s:p_absent\nworktree=%s\nharness=claude\nkind=ship\nbackend=herdr\n' "$SESSION" "$WT_P" > "$LAB/state/e1-peer.meta"; }
pinned
fm_launch_proof_herdr_pid "$LAB/state/e1-legacy.meta" >> "$TMP/pids"; echo >> "$TMP/pids"
sec "positive control (k) + adversarial (peer record names same worktree) via interrupt"
say "Note: claude shows its folder-trust screen; Escape (the interrupt key) ends claude there, so a delivered interrupt shows as the pinned agent stopping."
peer; say "verdict with peer (head lib): $(fm_launch_proof_herdr "$LAB/state/e1-pinned.meta")"
run pane read "$P_P" --format text > "$TMP/a"; p0=$(fm_launch_proof_herdr_pid "$LAB/state/e1-pinned.meta")
cmdrun "$WTREE" "head with peer" fm-control.sh e1-pinned interrupt
sleep 3; run pane read "$P_P" --format text > "$TMP/b"
say "after head with-peer interrupt: state=$(st "$P_P") pid=$(fm_launch_proof_herdr_pid "$LAB/state/e1-pinned.meta") (was $p0); screen $(cmp -s "$TMP/a" "$TMP/b" && echo unchanged || echo CHANGED)"
cmdrun "$WTREE" "head with peer" fm-control.sh e1-pinned exit
sleep 3; say "after head with-peer exit: state=$(st "$P_P") pid=$(fm_launch_proof_herdr_pid "$LAB/state/e1-pinned.meta")"
rm -f "$LAB/state/e1-peer.meta"
say "verdict without peer (head lib): $(fm_launch_proof_herdr "$LAB/state/e1-pinned.meta")"
cmdrun "$BASE" "base no peer" fm-control.sh e1-pinned interrupt
sleep 3; say "after base interrupt: state=$(st "$P_P")"
[ "$(st "$P_P")" = alive ] || pinned
cmdrun "$WTREE" "head no peer" fm-control.sh e1-pinned interrupt
sleep 3; say "after head interrupt: state=$(st "$P_P")"
sec "legacy control (j): record with no launch_proof line, live unpinned claude, exit on base and head"
say "legacy verdict: $(fm_launch_proof_herdr "$LAB/state/e1-legacy.meta") state=$(st "$P_L")"
cmdrun "$BASE" base fm-control.sh e1-legacy exit
sleep 3; say "legacy state after base exit: $(st "$P_L")"
cmdrun "$WTREE" head fm-control.sh e1-legacy exit
sleep 3; say "legacy state after head exit: $(st "$P_L")"
say DONE
