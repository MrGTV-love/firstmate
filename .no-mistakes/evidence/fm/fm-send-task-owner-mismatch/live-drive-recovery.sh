#!/usr/bin/env bash
# Live drive: an unread relayed cross-task request to a secondmate is recovered
# by the pending-reply recovery path (the watcher's repost) without the owner.
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M72J0F8JK5E0YM7A7MKYVDN2
. "$EV/lab-setup.sh"
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN"' EXIT
body() { bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$WT/bin/fm-task-inbox-lib.sh" "$1"; }
export FM_PENDING_REPLY_GRACE_SECS=0
echo "LAB FM_HOME=$FM_HOME"
echo "=== R1 Main relays a cross-task request to secondmate fm-mini"
bin/fm-send.sh fm-mini --relay 'Tell fm-slack-main-window-intake to rebase after PR 370 lands.' 2>&1 | grep -v '^●\|gate agent lifecycle'
echo "exit=${PIPESTATUS[0]}"
ls "$S/fm-mini.inbox"
cp "$S/fm-mini.inbox/001.msg" "$TMPDIR/orig.msg"
CORR=$(bash -c '. bin/fm-pending-reply-lib.sh; fm_pending_reply_extract_corr "$1"' _ "$(body "$S/fm-mini.inbox/001.msg")")
echo "corr=$CORR"
echo "pending record:"; sed 's/^/  /' "$S/pending-replies/$CORR"* 2>/dev/null | grep -E '^  (phase|task_id|request_summary)=' 
echo "=== R2 the mate takes a turn and goes idle without reading or replying (instruction unread)"
bash -c '. bin/fm-pending-reply-lib.sh; fm_pending_reply_observe_busy "$1" "$2" busy; fm_pending_reply_observe_busy "$1" "$2" idle' _ "$S" "$CORR"
echo "=== R3 the watcher's pending-reply tick fires recovery (no owner action)"
bash -c '. bin/fm-pending-reply-lib.sh; fm_pending_reply_send_recovery "$1" "$2"' _ "$S" "$CORR" 2>&1 | grep -v '^●\|gate agent lifecycle'
echo "recovery exit=${PIPESTATUS[0]}"
echo "phase after: $(grep '^phase=' "$S/pending-replies/$CORR"*)"
ls "$S/fm-mini.inbox"
echo "repost 002.msg body:"; body "$S/fm-mini.inbox/002.msg" | sed 's/^/  /'
cmp -s "$TMPDIR/orig.msg" "$S/fm-mini.inbox/001.msg" && echo "original 001.msg unchanged: yes"
echo "expectations: $(ls "$S/pending-replies" | grep -vc '^\.')"
echo "=== R4 a second recovery attempt does not send again (duplicate guard)"
bash -c '. bin/fm-pending-reply-lib.sh; fm_pending_reply_send_recovery "$1" "$2"' _ "$S" "$CORR" >/dev/null 2>&1; echo "second recovery exit=$?"
ls "$S/fm-mini.inbox"
echo "=== R5 negative: the same repost text sent without --relay is refused (why recovery passes --relay)"
bin/fm-send.sh fm-mini "$(body "$S/fm-mini.inbox/002.msg")" 2>&1 | grep '^error'
ls "$S/fm-mini.inbox"
echo "guard events:"; jq -c '{decision,rule,task,override}' "$FM_GUARD_EVENT_LOG" | grep -v '"allow"' | sed 's/^/  /'
