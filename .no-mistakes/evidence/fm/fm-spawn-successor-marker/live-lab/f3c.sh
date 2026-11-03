. $SB/drv/lib.sh
PRED=$(meta pred worktree)
LIVE=(--mode local-only --yolo off --owned-path README.md --harness "$LAUNCH")
ltmux new-window -d -t firstmate: -n hold3 -c "$(meta succ worktree)"
ltmux new-window -d -t firstmate: -n hold4 -c "$(meta retry worktree)"
say "F3 clean: spawn succ4 --successor-of pred (used slots held so the pool hands out a fresh one)"
brief succ4
TAILN=4 run spawn succ4 "$SB/proj" "${LIVE[@]}" --successor-of pred
note "succ4 worktree: $(meta succ4 worktree | sed "s#$SB#\$SB#"); successor_of=$(meta succ4 successor_of); recovery lines=$(grep -c '^recovery=' "$FM_HOME/state/succ4.meta")"
M=$(ls "$SB"/state/worktree-supersedence/*.json); cp "$M" "$SB/marker.succ4"
"$SB/proj/.venv/bin/python3" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("marker:", d["predecessor_branch"], "->", d["superseded_by_branch"])' "$M" | tee -a "$LOG"
say "F3 clean: stop succ4's worker, keep its window; detach the predecessor; relaunch succ4 --harness claude"
for p in $(pgrep -f "state/succ4.inbox"); do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
sleep 3
lg -C "$PRED" checkout -q --detach
TAILN=10 run spawn succ4 --relaunch --harness claude
note "succ4 relaunch exit=$RC; successor_of lines: $(grep -c '^successor_of=pred$' "$FM_HOME/state/succ4.meta"); recovery lines: $(grep -c '^recovery=' "$FM_HOME/state/succ4.meta")"
note "marker byte-identical after relaunch (no --supersedes re-record): $(cmp -s "$M" "$SB/marker.succ4" && echo yes || echo no)"
lg -C "$PRED" checkout -q fm/pred
