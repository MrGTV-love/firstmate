#!/usr/bin/env bash
set -u
ROOT=$1; LOG=$2; CORR=0123456789abcdef
. "$ROOT/bin/fm-pending-reply-lib.sh"
. "$ROOT/bin/fm-timing-lib.sh"
t0=$(fm_timing_now_ms)
got=$(fm_pending_reply_find_resolve_line "$LOG" "$CORR")
t1=$(fm_timing_now_ms)
printf 'lines=%s bytes=%s found=%s elapsed_ms=%s\n' "$(wc -l < "$LOG" | tr -d ' ')" "$(wc -c < "$LOG" | tr -d ' ')" "${got:+yes}" "$((t1-t0))"
