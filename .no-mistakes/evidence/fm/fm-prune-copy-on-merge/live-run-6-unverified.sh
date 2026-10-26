#!/usr/bin/env bash
# S10: a merge that was never verified (no merge-poll record for the task's PR) never arms a prune.
set -u
. "$(dirname "$0")/live-lab.sh"
export TMUX_TMPDIR; TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
new_task tu 51; C=$COPY
rm -f "$STATE/tu.pr-poll-merge-notified"
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$WT/bin/fm-merge-prune.sh" arm tu --run </dev/null; echo "arm (no verified merge) rc=$?"
sleep 5
echo "record: $([ -e "$STATE/tu.merge-prune" ] && echo present || echo absent); log: $(cat "$DATA/tu/merge-prune.log" 2>/dev/null || echo none)"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n99\n' > "$STATE/tu.pr-poll-merge-notified"; chmod 600 "$STATE/tu.pr-poll-merge-notified"
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$WT/bin/fm-merge-prune.sh" arm tu --run </dev/null; echo "arm (merge record names a different PR #99) rc=$?"
sleep 5
echo "record: $([ -e "$STATE/tu.merge-prune" ] && echo present || echo absent); copy still on $(git -C "$C" symbolic-ref --short HEAD); meta present: $([ -e "$STATE/tu.meta" ] && echo yes || echo no)"
