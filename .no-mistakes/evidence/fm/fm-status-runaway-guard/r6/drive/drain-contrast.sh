#!/usr/bin/env bash
# drain-contrast.sh <repo> <lab>: same 64 MiB lane log, the real wake drain, with and without a queued signal row.
REPO=$1; LAB=$2; ST=$LAB/state; mkdir -p "$LAB/config"; : > "$LAB/config/supervision-host-off"
run() {  # <label> <with-signal: 1|0>
  rm -rf "$ST"; mkdir -p "$ST"
  F=$ST/lane-$1.status
  yes 'working [at=1]: text' | head -c 67108864 > "$F"; printf '\n' >> "$F"
  [ "$2" = 1 ] && FM_STATE_OVERRIDE="$ST" bash -c '. "$1"; fm_wake_append signal "$2" "$3"' _ "$REPO/bin/fm-wake-lib.sh" "lane-$1.status" "signal: $F"
  /usr/bin/time -l env FM_STATE_OVERRIDE="$ST" FM_CONFIG_OVERRIDE="$LAB/config" timeout 100 "$REPO/bin/fm-wake-drain.sh" > "$LAB/d.out" 2> "$LAB/d.err"
  rc=$?
  echo "[$1] log=$(stat -f %z "$F") bytes (limit 34603008) signal_row=$2 drain_rc=$rc real_secs=$(awk '/ real /{print $1}' "$LAB/d.err") peak_rss_bytes=$(awk '/maximum resident/{print $1}' "$LAB/d.err") stdout_lines=$(wc -l < "$LAB/d.out" | tr -d ' ')"
  echo "    refusal line on stderr: $(grep -c 'fm-status: refused' "$LAB/d.err")"
}
run without-signal 0
run with-signal 1
