. "$1"
archived=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" archive "retained completed answer")
rec=$(fm_pending_reply_path "$FM_HOME/state" "$archived")
fm_pending_reply_set "$rec" phase resolved
open=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" live "real watcher pending answer")
fm_pending_reply_mark_delivered "$FM_HOME/state" "$open"
printf 'done [corr=%s]: real watcher answer\n' "$open" > "$FM_HOME/state/live.status"
owed=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" owed "owed escalation close")
rec=$(fm_pending_reply_path "$FM_HOME/state" "$owed")
fm_pending_reply_set "$rec" escalated_epoch "$(date +%s)"
fm_pending_reply_set "$rec" phase resolved
fm_pending_reply_set "$rec" resolved_via status
printf '%s\n' "blocked [key=pending-reply-$owed]: $(fm_pending_reply_escalation_payload "$rec" missed)" 'blocked [key=release]: unrelated operator decision' > "$FM_HOME/state/owed.status"
printf '%s\n%s\n%s\n' "$archived" "$open" "$owed"
