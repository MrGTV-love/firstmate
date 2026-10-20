#!/usr/bin/env bash
# 200,000-line status log through the REAL snapshot, timed. Newest PR is on the LAST line.
# usage: drive-perf.sh <lab-home> <code-root> <checkpoint:yes|no>
set -u
LAB=$1
CODE=$2
CKPT=$3
FB="$LAB/fakebin"
U=https://github.com/example/repo/pull
rm -f "$LAB"/state/*.meta "$LAB"/state/*.status "$LAB"/state/*.json
rm -rf "$LAB/state/status-fold" 2>/dev/null
printf 'kind=ship\nremote_host=example.invalid\n' > "$LAB/state/large.meta"
{ printf 'done: %s/14\n' $U; for ((i=0; i<200000; i++)); do printf 'working: routine progress\n'; done; printf 'done: %s/15\n' $U; } > "$LAB/state/large.status"
if [ "$CKPT" = yes ]; then
  # Production drains checkpoint the independent open-decision fold; seed it through its public reader.
  bash -c '. "$1"; status_open_decisions_incremental "$2" >/dev/null' _ "$CODE/bin/fm-classify-lib.sh" "$LAB/state/large.status" || echo "checkpoint failed"
fi
start=$SECONDS
out=$(PATH="$FB:$PATH" FM_HOME="$LAB" "$CODE/bin/fm-fleet-snapshot.sh" --json)
echo "elapsed=$((SECONDS - start))s lines=$(wc -l < "$LAB/state/large.status") checkpoint=$CKPT"
printf '%s' "$out" | jq -c '.tasks[]|{id,url:.pr.url,source:.pr.source}'
