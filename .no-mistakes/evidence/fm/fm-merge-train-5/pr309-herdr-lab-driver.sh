#!/usr/bin/env bash
# Live PR 309 scenario driver: real fm-spawn.sh, real Herdr lab session, probe harness binaries.
set -u
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M67B19KC3QV9VXC0B1BT52H9
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M67B19KC3QV9VXC0B1BT52H9
SCR=$1
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION FM_HERDR_RUNTIME
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_HERDR_LAB_STATE_DIR=$SCR/herdr-lab-state
mkdir -p "$FM_HERDR_LAB_STATE_DIR" "$SCR/out" "$SCR/fakebin"
eval "$($ROOT/bin/fm-lab-home.sh env 2>"$SCR/labhome.stderr")"
LABHOME=$FM_HOME
SESSION=$("$LAB_HELPER" name pr309)
echo "lab home: $LABHOME"; echo "lab session: $SESSION"
WTS=()
cleanup() {
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  "$LAB_HELPER" teardown "$SESSION"; echo "herdr lab teardown rc=$?"
  line=$(grep -o "[^ ]*fm-lab-home.sh teardown .*" "$SCR/labhome.stderr" | tail -1)
  [ -n "$line" ] && { chmod -R u+rwx "$LABHOME" 2>/dev/null; eval "$line"; echo "lab home teardown rc=$?"; }
}
trap cleanup EXIT
PATH="$SCR/fakebin:$PATH" SHELL=/bin/bash "$LAB_HELPER" provision "$SESSION" || { echo "provision failed"; exit 1; }
export HERDR_SESSION=$SESSION
lab() { "$LAB_HELPER" run "$SESSION" "$@"; }
LAB_SOCKET=$(lab session list --json | jq -r --arg s "$SESSION" '.sessions[]? | select(.name == $s) | .socket_path')

# Probe harness binaries: record an allowlist of keys and backend discovery, then exit (no model call).
for h in claude codex; do
cat > "$SCR/fakebin/$h" <<PROBE
#!/usr/bin/env bash
n=\$(date +%s%N)\$\$
f="$SCR/out/$h.\$n"
{
  echo "argv=\$*"
  echo "probe_path=\$0"
  echo "cwd=\$PWD"
  for k in HERDR_ENV FM_HERDR_RUNTIME HERDR_PANE_ID HERDR_SESSION FM_SPAWN_GEN TMUX FM_WRITE_CONFINEMENT; do
    if [ "\${!k+set}" = set ]; then echo "\$k=\${!k}"; else echo "\$k=<unset>"; fi
  done
  . "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/fm-supervisor-target-lib.sh"
  echo "fm_backend_name=\$(fm_backend_name)"
  fm_backend_detect >/dev/null; echo "detect_signal=\$FM_BACKEND_DETECT_SIGNAL"
  echo "supervisor_backend=\$(discover_supervisor_backend)"
  echo "supervisor_target=\$(discover_supervisor_target)"
} > "\$PWD/.fm-probe.$h.\$n" 2>&1; cp "\$PWD/.fm-probe.$h.\$n" "\$f" 2>/dev/null
PROBE
chmod +x "$SCR/fakebin/$h"
done

PROJ=$SCR/proj
mkdir -p "$PROJ"; git -C "$PROJ" init -q -b main; echo '# scratch' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
printf 'off\n' > "$LABHOME/config/herdr-presentation-spaces"
for id in p309raw p309codex; do
  mkdir -p "$LABHOME/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nProbe the launch environment of %s.\n\n## Firstmate spec\nDo nothing.\n' "$id" > "$LABHOME/data/$id/brief.md"
done

# Safety gate: a fresh lab pane must resolve claude and codex to the probes, so no real CLI starts.
cws=$(lab workspace create --cwd "$SCR" --label pr309-pathcheck --no-focus)
CPANE=$(printf '%s' "$cws" | jq -er '.result.root_pane.pane_id')
lab pane run "$CPANE" "{ command -v claude; command -v codex; } > '$SCR/out/fresh-pane-path'" >/dev/null
for i in $(seq 1 30); do [ -s "$SCR/out/fresh-pane-path" ] && break; sleep 1; done
echo "== fresh lab pane resolves:"; cat "$SCR/out/fresh-pane-path"
[ "$(sed -n 1p "$SCR/out/fresh-pane-path")" = "$SCR/fakebin/claude" ] && [ "$(sed -n 2p "$SCR/out/fresh-pane-path")" = "$SCR/fakebin/codex" ] \
  || echo "(fresh panes run the user's zsh; normal-mode spawns are skipped; probes launch by absolute path only)"
# Launcher pane: a real Herdr pane, standing in for a Firstmate primary running inside Herdr.
ws=$(lab workspace create --cwd "$SCR" --label pr309-launcher --no-focus)
LPANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
echo "launcher pane: $LPANE"
cat > "$SCR/in-pane.sh" <<INP
#!/usr/bin/env bash
{ echo "HERDR_ENV=\${HERDR_ENV-<unset>}"; echo "HERDR_PANE_ID=\${HERDR_PANE_ID-<unset>}"; echo "HERDR_SESSION=\${HERDR_SESSION-<unset>}"; echo "FM_HERDR_RUNTIME=\${FM_HERDR_RUNTIME-<unset>}"; } > "$SCR/out/launcher-pane.env"
mkdir -p "$SCR/claude-config"; [ -f "$SCR/claude-config/.claude.json" ] || echo "{}" > "$SCR/claude-config/.claude.json"
export CLAUDE_CONFIG_DIR="$SCR/claude-config" PATH="$SCR/fakebin:$PATH" FM_HOME="$LABHOME" FM_MODEL_FRESHNESS=0 FM_SPAWN_NO_GUARD=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
echo "claude_resolves_to=\$(command -v claude)" >> "$SCR/out/launcher-pane.env"; echo "codex_resolves_to=\$(command -v codex)" >> "$SCR/out/launcher-pane.env"
for pair in "p309raw $SCR/fakebin/claude --model haiku" "p309codex $SCR/fakebin/codex --model gpt-5"; do
  set -- \$pair; id=\$1; shift
  "$ROOT/bin/fm-spawn.sh" "\$id" "$PROJ" "\$*" --mode no-mistakes --yolo off --backend herdr > "$SCR/out/\$id.spawn.out" 2> "$SCR/out/\$id.spawn.err"
  echo \$? > "$SCR/out/\$id.rc"
done
INP
chmod +x "$SCR/in-pane.sh"
lab pane run "$LPANE" "env PATH='$PATH' bash '$SCR/in-pane.sh'" >/dev/null || echo "pane run failed"
for i in $(seq 1 300); do [ -f "$SCR/out/p309codex.rc" ] && break; sleep 1; done
for id in p309raw p309codex; do
  echo "== $id spawn rc=$(cat "$SCR/out/$id.rc" 2>/dev/null || echo missing)"
  wt=$(grep '^worktree=' "$LABHOME/state/$id.meta" 2>/dev/null | cut -d= -f2-); [ -n "$wt" ] && WTS+=("$wt")
  grep -E '^(window|harness|backend|herdr_session|herdr_pane_id|spawn_gen)=' "$LABHOME/state/$id.meta" 2>/dev/null
done
# Wait for launched probes to run in their worker panes.
for i in $(seq 1 90); do
  n=0; for wt in ${WTS[@]+"${WTS[@]}"}; do ls "$wt"/.fm-probe.* >/dev/null 2>&1 && n=$((n+1)); done
  [ "$n" -ge 2 ] && break; sleep 1
done
for id in p309raw p309codex; do
  wt=$(grep '^worktree=' "$LABHOME/state/$id.meta" 2>/dev/null | cut -d= -f2-)
  for f in "$wt"/.fm-probe.*; do [ -f "$f" ] || continue; echo "== probe record from worker $id ($(basename "$f" | cut -d. -f3))"; cat "$f"; done
done
echo "== launcher pane env (control: what Herdr injects into an ordinary pane)"; cat "$SCR/out/launcher-pane.env"
for id in p309raw p309codex; do echo "== $id spawn stderr (tail)"; tail -5 "$SCR/out/$id.spawn.err" 2>/dev/null; done
echo "== herdr version: $(herdr --version)"
