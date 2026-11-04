for t in labsucc0 labsucc1; do w=$(grep "^worktree=" $FM_HOME/state/$t.meta | cut -d= -f2); git -C $w reset -q --hard 06a1855330d36d23d236f4ee2a62710b04ed4bae && echo "reset fm/$t back to base (it carried the same commit in an earlier row)"; done
echo "branches that reach 3f1c0151d: $(git -C $P branch -a --contains 3f1c0151d | tr -s " \n" " ")"
w=$(grep "^worktree=" $FM_HOME/state/labsucc4.meta | cut -d= -f2); sha=$(git -C $w rev-parse HEAD)
echo "=== R-13 for labsucc4 (admitted through the --relaunch retry; marker owner=labsucc4)"
(cd $w && printf "refs/heads/fm/labsucc4 %s refs/heads/fm/labsucc4 %s\n" $sha 0000000000000000000000000000000000000000 | PATH="$P/.venv/bin:$PATH" python3 scripts/hooks/pre_push_base_ref_staleness.py origin "$(git remote get-url origin)" 2>&1); echo "R-13 exit=$?"
