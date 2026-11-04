mv $WORK/hookstate $WORK/hookstate.aside && : > $WORK/hookstate && echo "made \$CODEX_HOOK_STATE_DIR a regular file again"
echo "=== relaunch retry while Vernant still refuses"
relaunch labsucc4 --harness "$AGENT" | grep -v "^  \"\(owned\|README\)\|^notice\|^local-only"
echo "--- state/labsucc4.meta:"; grep -E "^(recovery|successor_of)=" $FM_HOME/state/labsucc4.meta
rm $WORK/hookstate && mv $WORK/hookstate.aside $WORK/hookstate && echo "restored \$CODEX_HOOK_STATE_DIR"
echo "=== relaunch retry with a live predecessor and a writable state dir"
relaunch labsucc4 --harness "$AGENT" | grep -v "^  \|^{\|^}\|^notice\|^local-only"
echo "--- state/labsucc4.meta:"; grep -E "^(branch|successor_of|recovery|slot_manifest)=" $FM_HOME/state/labsucc4.meta
echo "--- markers:"; for f in $CODEX_HOOK_STATE_DIR/worktree-supersedence/*.json; do python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sys.argv[1].rsplit(\"/\",1)[1], \"owner=\"+d[\"owner_id\"], d[\"predecessor_branch\"], \"->\", d[\"superseded_by_branch\"], d[\"recorded_at_iso\"])" $f; done
