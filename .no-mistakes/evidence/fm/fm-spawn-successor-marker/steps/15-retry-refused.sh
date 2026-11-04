mkbrief labsucc4
PRED=$(grep "^worktree=" $FM_HOME/state/labpred1.meta | cut -d= -f2)
mv $WORK/hookstate $WORK/hookstate.aside && : > $WORK/hookstate && echo "made \$CODEX_HOOK_STATE_DIR a regular file"
spawn labsucc4 --successor-of labpred1 | grep -v "^  \|^{\|^}\|^notice\|^local-only"
grep -E "^(recovery|successor_of)=" $FM_HOME/state/labsucc4.meta; cp $FM_HOME/state/labsucc4.meta $WORK/labsucc4.meta.refused
echo "windows: $(windows | tr "\n" " ")"
