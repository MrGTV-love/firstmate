. $SB/drv/lib.sh
PRED=$(meta pred worktree); R=$(meta retry worktree)
say "F3: later relaunch of the ADMITTED successor retry; endpoint window recreated empty (agent exited); predecessor detached (not live)"
ltmux new-window -d -t firstmate: -n fm-retry -c "$R"
sleep 2
M=$(ls "$SB"/state/worktree-supersedence/*.json); cp "$M" "$SB/marker.before-f3"
"$SB/proj/.venv/bin/python3" -c 'import json,sys; d=json.load(open(sys.argv[1])); print("marker before:", d["predecessor_branch"], "->", d["superseded_by_branch"], d.get("recorded_at") or d.get("created_at") or "")' "$M" | tee -a "$LOG"
note "retry meta before: recovery lines=$(grep -c '^recovery=' "$FM_HOME/state/retry.meta"); successor_of=$(meta retry successor_of)"
lg -C "$PRED" checkout -q --detach
TAILN=14 run spawn retry --relaunch --harness claude
note "retry relaunch exit=$RC; successor_of lines: $(grep -c '^successor_of=pred$' "$FM_HOME/state/retry.meta"); recovery lines: $(grep -c '^recovery=' "$FM_HOME/state/retry.meta")"
note "marker byte-identical after relaunch (provisioner did not re-record with --supersedes): $(cmp -s "$M" "$SB/marker.before-f3" && echo yes || echo no)"
lg -C "$PRED" checkout -q fm/pred
ltmux kill-window -t firstmate:fm-retry 2>/dev/null
