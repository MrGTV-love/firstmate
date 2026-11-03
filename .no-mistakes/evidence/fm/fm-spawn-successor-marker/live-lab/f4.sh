. $SB/drv/lib.sh
PRED=$(meta pred worktree)
LIVE=(--mode local-only --yolo off --owned-path README.md --harness "$LAUNCH")
say "F4: the REAL verb refuses (marker store blocked by a plain file, PR #3604 S4 recipe)"
mv "$SB/state/worktree-supersedence" "$SB/marker-dir-aside"
: > "$SB/state/worktree-supersedence"
brief retry
TAILN=14 run spawn retry "$SB/proj" "${LIVE[@]}" --successor-of pred
grep -E '^(successor_of|recovery|branch|worktree|slot_owned_path)=' "$FM_HOME/state/retry.meta" | sed "s#$SB#\$SB#g" | tee -a "$LOG"
note "durable manifests for retry: $(grep -l '"owner_id": "retry"' "$SB"/durable/*.json 2>/dev/null | wc -l | tr -d ' ')"
ltmux list-windows -t firstmate -F '#{window_name} #{pane_current_command}' | tee -a "$LOG"
say "F4 retry while the predecessor is not live (detached): refuses, record unchanged"
cp "$FM_HOME/state/retry.meta" "$SB/retry.meta.refused"
lg -C "$PRED" checkout -q --detach
TAILN=6 run spawn retry --relaunch
note "record unchanged: $(cmp -s "$FM_HOME/state/retry.meta" "$SB/retry.meta.refused" && echo yes || echo no)"
lg -C "$PRED" checkout -q fm/pred
say "F4 supported retry: clear the blocker, fm-spawn retry --relaunch (no flag)"
rm -f "$SB/state/worktree-supersedence"; mv "$SB/marker-dir-aside" "$SB/state/worktree-supersedence"
TAILN=14 run spawn retry --relaunch
grep -E '^(successor_of|recovery|branch|slot_manifest)=' "$FM_HOME/state/retry.meta" | sed "s#$SB#\$SB#g" | tee -a "$LOG"
"$SB/proj/.venv/bin/python3" - "$SB" <<'PY' | sed "s#$SB#\$SB#g" | tee -a "$LOG"
import glob,json,sys
for f in glob.glob(sys.argv[1]+"/state/worktree-supersedence/*.json"):
    d=json.load(open(f)); print(f.split('/')[-1], d.get("predecessor_branch"), "->", d.get("superseded_by_branch"), d.get("carry_status"))
PY
say "LATER RELAUNCH of the admitted successor succ with the predecessor NOT live: ordinary attestation, no --supersedes"
ltmux kill-window -t firstmate:fm-succ
lg -C "$PRED" checkout -q --detach
TAILN=8 run spawn succ --relaunch
note "successor_of lines in succ.meta: $(grep -c '^successor_of=pred$' "$FM_HOME/state/succ.meta")"
lg -C "$PRED" checkout -q fm/pred
say "Real default Vernant hook store and ~/.treehouse untouched"
ls -la /tmp/vernant-codex-hooks-501/worktree-supersedence 2>/dev/null | shasum -a 256 > "$SB/real-store-after.txt"
note "real store listing unchanged: $(cmp -s "$SB/real-store-before.txt" "$SB/real-store-after.txt" && echo yes || echo no)"
ls -1A "$HOME/.treehouse" | sort > "$SB/treehouse-after.txt"
note "~/.treehouse listing unchanged: $(cmp -s "$SB/treehouse-before.txt" "$SB/treehouse-after.txt" && echo yes || echo no)"
