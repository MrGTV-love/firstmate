#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/Users/charlesabrooker/.no-mistakes/evidence/01M49EFWAFD5KHQ0BH54TSPC8T
LAB=$ROOT/.live-validation/reply-home
export FM_HOME=$LAB FM_STATE_OVERRIDE=$LAB/state TMPDIR=$ROOT/.live-validation/tmp
unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
holder=
cleanup() { touch "$LAB/release"; [ -z "$holder" ] || wait "$holder" || true; rm -rf "$LAB"; }
bash bin/fm-lab-home.sh create "$LAB"
trap cleanup EXIT
. "$ROOT/bin/fm-pending-reply-lib.sh"
. "$ROOT/bin/fm-wake-lib.sh"
corr=$(fm_pending_reply_create "$LAB" "$LAB/state" archived 'retained completed reply')
rec=$(fm_pending_reply_path "$LAB/state" "$corr")
fm_pending_reply_set "$rec" phase resolved
pending=$(fm_pending_reply_create "$LAB" "$LAB/state" live 'answer behind retained archive')
fm_pending_reply_mark_delivered "$LAB/state" "$pending"
printf 'done [corr=%s]: live answer after archive\n' "$pending" > "$LAB/state/live.status"
lock=$LAB/state/.pending-reply-$corr.lock
( fm_lock_acquire_wait "$lock"; trap 'fm_lock_release "$lock"' EXIT; touch "$LAB/ready"; while [ ! -e "$LAB/release" ]; do sleep .1; done ) &
holder=$!
for ((i=0;i<100;i++)); do [ ! -e "$LAB/ready" ] || break; sleep .1; done
[ -e "$LAB/ready" ]
printf 'archive correlation=%s; lock held by pid=%s\n' "$corr" "$(cat "$lock/pid")"
rc=0
# The native deadline is intentionally separate from historical driver cancellations.
timeout 4 bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$ROOT/.live-validation/base-bin/fm-pending-reply-lib.sh" "$LAB/state" || rc=$?
printf 'pre-change held-archive tick native exit=%s (deadline 4s)\n' "$rc"
[ "$rc" -eq 124 ]
start=$SECONDS
bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$LAB/state"
printf 'target held-archive tick native exit=0 elapsed=%ss\n' "$((SECONDS-start))"
pending_rec=$(fm_pending_reply_path "$LAB/state" "$pending")
[ "$(fm_pending_reply_get "$pending_rec" phase)" = resolved ]
printf 'pending reply phase=%s; archive retained=%s; lock still held=%s\n' "$(fm_pending_reply_get "$pending_rec" phase)" "$(test -f "$rec" && echo yes)" "$(test -f "$lock/pid" && echo yes)"
cat "$LAB/state/live.status"
touch "$LAB/release"; wait "$holder"; holder=
# Exercise already-closed terminal records including last-value precedence and no final newline.
fm_pending_reply_set "$rec" escalated_epoch 10000
printf 'escalation_closed_epoch=\nescalation_closed_epoch=10001' >> "$rec"
cp "$rec" "$LAB/completed.snapshot"
bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$LAB/state"
cmp "$rec" "$LAB/completed.snapshot"
printf 'already-closed retained reply unchanged with unterminated last-value field\n'
# A resolved correlation with an interrupted close must still close exactly once.
owed=$(fm_pending_reply_create "$LAB" "$LAB/state" owed 'interrupted escalation close')
owed_rec=$(fm_pending_reply_path "$LAB/state" "$owed")
fm_pending_reply_mark_delivered "$LAB/state" "$owed"
fm_pending_reply_set "$owed_rec" escalated_epoch 10000
fm_pending_reply_set "$owed_rec" phase resolved
fm_pending_reply_set "$owed_rec" resolved_via status
printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=owed pending-reply-id=%s request=interrupted escalation close\nblocked [key=release]: unrelated captain decision\n' "$owed" "$owed" > "$LAB/state/owed.status"
bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$LAB/state" & first=$!
bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$LAB/state" & second=$!
wait "$first"; wait "$second"
fm_pending_reply_tick "$LAB/state"
python3 - "$LAB/state/owed.status" "$owed" <<'PY'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text()
assert s.count('pending-reply-resolved: task=owed pending-reply-id='+sys.argv[2])==1
print(s)
PY
printf 'open decisions after concurrent retry:\n'
status_open_decisions "$LAB/state/owed.status"
[ -n "$(fm_pending_reply_get "$owed_rec" escalation_closed_epoch)" ]
[ "$(status_open_decisions "$LAB/state/owed.status" | cut -f1)" = release ]
printf 'owed close durably recorded; unrelated decision preserved\n'
