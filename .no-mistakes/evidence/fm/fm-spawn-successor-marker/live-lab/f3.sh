. $SB/drv/lib.sh
PRED=$(meta pred worktree)
LIVE=(--mode local-only --yolo off --owned-path README.md --harness "$LAUNCH")
say "F3 setup: admitted successor succ3 --successor-of pred (raw sleep worker)"
brief succ3
TAILN=4 run spawn succ3 "$SB/proj" "${LIVE[@]}" --successor-of pred
note "succ3 successor_of: $(meta succ3 successor_of)"
M=$(ls "$SB"/state/worktree-supersedence/*.json); cp "$M" "$SB/marker.succ3"
"$SB/proj/.venv/bin/python3" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("marker", d["predecessor_branch"], "->", d["superseded_by_branch"])' "$M" | tee -a "$LOG"
say "F3: stop the succ3 worker process, keep its endpoint; detach the predecessor; relaunch succ3 --harness claude"
for p in $(pgrep -f "state/succ3.inbox"); do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
sleep 3
ltmux list-windows -t firstmate -F '#{window_name} #{pane_current_command}' | grep succ3 | tee -a "$LOG"
lg -C "$PRED" checkout -q --detach
TAILN=10 run spawn succ3 --relaunch --harness claude
note "succ3 relaunch exit=$RC; successor_of lines: $(grep -c '^successor_of=pred$' "$FM_HOME/state/succ3.meta"); recovery lines: $(grep -c '^recovery=' "$FM_HOME/state/succ3.meta")"
note "marker byte-identical after relaunch (no --supersedes re-record): $(cmp -s "$M" "$SB/marker.succ3" && echo yes || echo no)"
lg -C "$PRED" checkout -q fm/pred
ltmux kill-window -t firstmate:fm-succ3 2>/dev/null
