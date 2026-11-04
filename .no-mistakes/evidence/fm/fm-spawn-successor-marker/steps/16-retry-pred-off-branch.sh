PRED=$(grep "^worktree=" $FM_HOME/state/labpred1.meta | cut -d= -f2)
git -C $PRED checkout -q --detach && echo "labpred1 copy detached"
refusal "relaunch retry while the predecessor is not on its recorded branch" relaunch labsucc4
cmp -s $FM_HOME/state/labsucc4.meta $WORK/labsucc4.meta.refused && echo "state/labsucc4.meta byte-identical: the declaration is kept"
git -C $PRED checkout -q fm/labpred1 && echo "labpred1 copy back on fm/labpred1"
