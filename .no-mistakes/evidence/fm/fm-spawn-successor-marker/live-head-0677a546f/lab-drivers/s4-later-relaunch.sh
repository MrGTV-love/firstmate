. "$(dirname "$0")/common.sh"
LH=$W/locked/hook-state
echo "=== LATER RELAUNCH of an admitted successor (nmt-succ-gone), after stopping its agent"
echo "(stub agent stopped with Ctrl-C in its pane; the pane is an idle shell; the lab carry commits were reset off the branch so they do not trip the helper scope check; helper state dir = the one holding this task manifest)"
sleep 3
echo "markers before: $(markers $LH)"; m=$(cksum "$LH"/worktree-supersedence/*.json)
relaunch nmt-succ-gone 2>&1 | grep -vE '^\s*("|[]\[{}])' | grep -v -e '^fm-gate' -e '^warning' -e '^waiting' | sed 's/^/  | /'; echo "  relaunch exit=${PIPESTATUS[0]}"
meta nmt-succ-gone | sed 's/^/  /'
echo "markers after: $(markers $LH); marker file unchanged: $([ "$m" = "$(cksum "$LH"/worktree-supersedence/*.json)" ] && echo yes || echo no)"
ls "$L/data/nmt-succ-gone/" | grep slot-provision
