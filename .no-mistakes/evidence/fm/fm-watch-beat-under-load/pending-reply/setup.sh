set -e
. "$1"
export FM_HOME="$2" FM_STATE_OVERRIDE="$2/state" FM_PENDING_REPLY_NOW=10060
mkdir -p "$FM_STATE_OVERRIDE"
s=$FM_STATE_OVERRIDE
archive=$(fm_pending_reply_create "$FM_HOME" "$s" archived 'retained completed answer')
r=$(fm_pending_reply_path "$s" "$archive")
fm_pending_reply_set "$r" phase resolved
closed=$(fm_pending_reply_create "$FM_HOME" "$s" archived 'closed retained answer')
r=$(fm_pending_reply_path "$s" "$closed")
fm_pending_reply_set "$r" phase resolved
fm_pending_reply_set "$r" escalated_epoch 10000
printf 'escalation_closed_epoch=\nescalation_closed_epoch=10001' >> "$r"
open=$(fm_pending_reply_create "$FM_HOME" "$s" live 'reply behind completed archive')
fm_pending_reply_mark_delivered "$s" "$open"
printf 'done [corr=%s]: live answer\n' "$open" > "$s/live.status"
printf '%s\n%s\n%s\n' "$archive" "$closed" "$open"
