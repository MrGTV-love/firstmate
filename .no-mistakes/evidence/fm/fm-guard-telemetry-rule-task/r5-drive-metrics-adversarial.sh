#!/usr/bin/env bash
set -u
WT=$PWD; S=$(mktemp -d "${TMPDIR:-/tmp}/fm-r5m.XXXXXX"); trap 'rm -rf "$S"' EXIT; L=$S/l; M=$WT/bin/fm-guard-metrics.sh
cat >"$L" <<'J'
{"ts":"2020-01-01T00:00:00Z","guard":"old-guard","rule":"r","task":"t","decision":"allow"}
{"ts":"2026-11-01T00:00:00Z","guard":"cur","rule":"a","task":"t1","session":"s1","decision":"deny"}
{"ts":"2026-11-01T00:00:01Z","guard":"cur","rule":"a","task":"t1","session":"s2","decision":"deny"}
{"ts":"2026-11-01T00:00:02Z","guard":"cur","rule":"b","task":"t1","session":"s3","decision":"deny"}
{"guard":42,"decision":"deny"}
{"ts":7,"guard":"cur","decision":"deny"}
{"ts":"2026-11-01T00:00:03Z","guard":"cur","rule":"a","tas
J
before=$(cksum <"$L")
"$M" --log "$L" --registry /dev/null --days 30 | cut -c1-240; echo "rc=$?"
echo "log unchanged: $([ "$before" = "$(cksum <"$L")" ] && echo yes || echo no)"
echo "-- absent log: "; "$M" --log "$S/none" --registry /dev/null | tail -1
echo "-- bad days: "; "$M" --log "$L" --days 0 2>&1 | tail -1 | cut -c1-120
