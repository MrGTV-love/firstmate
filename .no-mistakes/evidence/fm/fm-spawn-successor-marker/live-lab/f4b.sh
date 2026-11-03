. $SB/drv/lib.sh
PRED=$(meta pred worktree)
say "F4 retry (named harness) while the predecessor is not live (detached): refuses naming pred, record unchanged"
cp "$FM_HOME/state/retry.meta" "$SB/retry.meta.refused"
lg -C "$PRED" checkout -q --detach
TAILN=6 run spawn retry --relaunch --harness claude
note "record unchanged: $(cmp -s "$FM_HOME/state/retry.meta" "$SB/retry.meta.refused" && echo yes || echo no)"
lg -C "$PRED" checkout -q fm/pred
say "F4 supported retry: blocker already cleared; fm-spawn retry --relaunch --harness claude (no --successor-of)"
TAILN=20 run spawn retry --relaunch --harness claude
grep -E '^(successor_of|recovery|branch|slot_manifest|harness)=' "$FM_HOME/state/retry.meta" | sed "s#$SB#\$SB#g" | tee -a "$LOG"
note "durable manifests for retry: $(grep -l '"owner_id": "retry"' "$SB"/durable/*.json 2>/dev/null | wc -l | tr -d ' ')"
"$SB/proj/.venv/bin/python3" - "$SB" <<'PY' | sed "s#$SB#\$SB#g" | tee -a "$LOG"
import glob,json,sys
for f in glob.glob(sys.argv[1]+"/state/worktree-supersedence/*.json"):
    d=json.load(open(f)); print("marker", f.split('/')[-1], d.get("predecessor_branch"), "->", d.get("superseded_by_branch"), d.get("carry_status"), d.get("superseded_by_worktree_path"))
PY
ltmux kill-window -t firstmate:fm-retry 2>/dev/null
say "LATER RELAUNCH of admitted succ (named harness) with the predecessor NOT live: ordinary attestation, no --supersedes"
lg -C "$PRED" checkout -q --detach
TAILN=12 run spawn succ --relaunch --harness claude
grep -E '^(successor_of|recovery|slot_manifest|harness)=' "$FM_HOME/state/succ.meta" | sed "s#$SB#\$SB#g" | tee -a "$LOG"
lg -C "$PRED" checkout -q fm/pred
ltmux kill-window -t firstmate:fm-succ 2>/dev/null
