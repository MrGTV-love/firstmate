#!/usr/bin/env bash
# Live demo: drive the real bin/fm-crew-state.sh in a disposable lab FM_HOME for a
# ship task whose worker logged `done: PR ... checks green`, with a fake
# no-mistakes daemon that is silent, and a fake gh that fails (no network).
# Runs on the change (HEAD) and on base bin/.
# Usage: crew-state-live-demo.sh <worktree> <base-sha>
set -u
WT_REPO=$1 BASE=$2
for v in $(env | sed -n 's/^\(FM_[A-Z_]*_OVERRIDE\)=.*/\1/p'); do unset "$v"; done
unset FM_GATE_REFUSE_BYPASS
eval "$("$WT_REPO/bin/fm-lab-home.sh" env)"
LAB=$FM_HOME
echo "lab home: $LAB"
FAKE="$LAB/fakebin"; mkdir -p "$FAKE" "$LAB/base"
git -C "$WT_REPO" archive "$BASE" bin | tar -x -C "$LAB/base"
cat > "$FAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(date +%s)" "$*" >> "$FM_DEMO_NM_LOG"
case "${1:-} ${2:-}" in
  "axi status") exec sleep 117 ;;
esac
exit 1
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/gh"
chmod +x "$FAKE/no-mistakes" "$FAKE/gh"
export PATH="$FAKE:$PATH" FM_DEMO_NM_LOG="$LAB/nm-calls.log"
echo "no-mistakes resolves to: $(command -v no-mistakes)"
REPO="$LAB/repo"; git init -q -b fm/demo "$REPO"
git -C "$REPO" -c user.email=d@e -c user.name=demo commit -q --allow-empty -m init
mkdir -p "$LAB/state"
ID=demo-ship
printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\nbranch=fm/demo\nwindow=fm:fm-demo-ship\nharness=claude\n' "$REPO" "$REPO" > "$LAB/state/$ID.meta"
printf 'done [at=%s]: PR https://github.com/example/demo/pull/7 checks green\n' "$(date +%s)" > "$LAB/state/$ID.status"

tmux -L fm-lab new-session -d -s fm -n fm-demo-ship -c "$REPO" 'printf "worker finished\\n"; sleep 600'
TMUX="$(tmux -L fm-lab display -p -t fm '#{socket_path}'),$(tmux -L fm-lab display -p -t fm '#{pid}'),0"; export TMUX
gen=$("$WT_REPO/bin/fm-busy-event.sh" arm "$LAB/state" "$ID")
"$WT_REPO/bin/fm-busy-event.sh" apply "$LAB/state" "$ID" idle --gen "$gen" --source claude-hook --event stop
echo "harness idle record written (gen $gen)"
echo "lab tmux: $(tmux list-windows -a -F '#{session_name}:#{window_name}')"
for side in change base; do
  root=$WT_REPO; [ "$side" = base ] && root="$LAB/base"
  echo "=== $side: $root/bin/fm-crew-state.sh $ID (daemon silent; FM_DOD_NM_STALL_SECS=3, FM_CREW_STATE_NM_TIMEOUT=3)"
  start=$(date +%s); rc=0
  FM_DOD_NM_STALL_SECS=3 FM_CREW_STATE_NM_TIMEOUT=3 bash "$root/bin/fm-crew-state.sh" "$ID" > "$LAB/out" 2>"$LAB/err" || rc=$?
  echo "stdout: $(cat "$LAB/out")"
  echo "stderr (last 3): $(tail -3 "$LAB/err")"
  echo "exit=$rc elapsed=$(( $(date +%s) - start ))s"
done
echo "##### daemon calls"; cat "$FM_DEMO_NM_LOG"
pkill -fx "sleep 117" 2>/dev/null
tmux -L fm-lab kill-server
echo "leftover fake daemons: $(pgrep -fx 'sleep 117' | wc -l | tr -d ' ')"
"$WT_REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
