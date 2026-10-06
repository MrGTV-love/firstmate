set -e
. "$1"
export FM_HOME="$2" FM_STATE_OVERRIDE="$2/state" FM_PENDING_REPLY_NOW=10060
mkdir -p "$FM_STATE_OVERRIDE"
s=$FM_STATE_OVERRIDE
corr=$(fm_pending_reply_create "$FM_HOME" "$s" hibit 'owed close after interrupted resolution')
fm_pending_reply_mark_delivered "$s" "$corr"
r=$(fm_pending_reply_path "$s" "$corr")
fm_pending_reply_set "$r" escalated_epoch 10000
fm_pending_reply_set "$r" phase resolved
fm_pending_reply_set "$r" resolved_via status
printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=hibit pending-reply-id=%s request=owed close after interrupted resolution\n' "$corr" "$corr" > "$s/hibit.status"
printf 'blocked [key=release]: unrelated operator decision\n' >> "$s/hibit.status"
pending=$(fm_pending_reply_create "$FM_HOME" "$s" waiting 'not delivered and still unresolved')
printf '%s\n%s\n' "$corr" "$pending"
