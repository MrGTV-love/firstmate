PRED=$(grep "^worktree=" $FM_HOME/state/labpred1.meta | cut -d= -f2)
echo "labsucc4 agent (sleep) was stopped; the window and copy remain"
before=$(cksum $CODEX_HOOK_STATE_DIR/worktree-supersedence/084783094b69b852.json)
git -C $PRED checkout -q --detach && echo "labpred1 copy detached: the predecessor is no longer a live successor source"
echo "=== later relaunch of the ADMITTED successor labsucc4"
relaunch labsucc4 --harness "$AGENT" | grep -v "^  \|^{\|^}\|^notice\|^local-only"
echo "--- state/labsucc4.meta:"; grep -E "^(successor_of|recovery|slot_manifest)=" $FM_HOME/state/labsucc4.meta
after=$(cksum $CODEX_HOOK_STATE_DIR/worktree-supersedence/084783094b69b852.json)
[ "$before" = "$after" ] && echo "labpred1 marker unchanged: the relaunch sent no --supersedes" || echo "labpred1 marker CHANGED"
git -C $PRED checkout -q fm/labpred1 && echo "labpred1 copy back on fm/labpred1"
source $EV/r13.sh; echo; r13 labsucc4
