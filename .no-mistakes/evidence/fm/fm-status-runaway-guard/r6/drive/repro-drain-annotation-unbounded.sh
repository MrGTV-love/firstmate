#!/usr/bin/env bash
# repro-drain-annotation-unbounded.sh <repo>
# Small, fast, deterministic reproduction (temp dir, tiny cap, no big files).
# A lane log past the read limit (25000 bytes against a 5000-byte limit: cap 4000 + reserve 1000) plus the ordinary
# `signal:` wake row the watcher queues for any changed status log. The documented contract
# (docs/configuration.md "Reading") is that a reader refuses a log past the limit and reads nothing.
REPO=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-annot-repro.XXXXXX"); ST=$T/state; mkdir -p "$ST" "$T/config"; : > "$T/config/supervision-host-off"
perl -e 'print "text\n" x 5000' > "$ST/b.status"
printf 'working: a healthy lane\n' > "$ST/a.status"
FM_STATE_OVERRIDE="$ST" bash -c '. "$1"; fm_wake_append signal b.status "signal: $2"' _ "$REPO/bin/fm-wake-lib.sh" "$ST/b.status"
out=$(FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000 FM_STATE_OVERRIDE="$ST" FM_CONFIG_OVERRIDE="$T/config" "$REPO/bin/fm-wake-drain.sh" 2>"$T/err")
n=$(printf '%s\n' "$out" | grep -c 'wake annotation:.*b.status')
echo "log size: $(stat -f %z "$ST/b.status") bytes, read limit: 5000 bytes"
echo "annotation lines printed from the over-limit log: $n"
echo "stderr names the refused log: $(grep -c 'b.status' "$T/err")"
rm -rf "$T"
[ "$n" -eq 0 ] && echo "PASS: nothing was read from the over-limit log" || { echo "FAIL: the drain read the whole over-limit log and printed $n annotation lines"; exit 1; }
