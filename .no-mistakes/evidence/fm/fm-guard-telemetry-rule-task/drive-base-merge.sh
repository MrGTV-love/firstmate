#!/usr/bin/env bash
# Live: base-merge-only head change after a merge refusal, then metrics with --workarounds.
set -u
WT=$PWD; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-wa.XXXXXX"); trap 'rm -rf "$T"' EXIT
g() { git -C "$T/repo" -c user.name=t -c user.email=t@example.invalid "$@"; }
git init -q --bare "$T/origin.git"; git init -q -b main "$T/repo"
g remote add origin "$T/origin.git"
echo a >"$T/repo/a"; g add a; g commit -qm base1; g push -q origin main
g checkout -qb feature; echo f >"$T/repo/f"; g add f; g commit -qm feat; HEAD1=$(g rev-parse HEAD)
LOG="$T/events.jsonl"
FM_GUARD_EVENT_LOG="$LOG" "$WT/bin/fm-guard-event.sh" merge-green-head deny --rule base-containment --task wa-1 --head "$HEAD1" --base main
sleep 1
g checkout -q main; echo b >"$T/repo/b"; g add b; g commit -qm base2; g push -q origin main; g fetch -q origin
g checkout -q feature; g merge -q --no-edit origin/main; HEAD2=$(g rev-parse HEAD)
echo "refused head=$HEAD1  new head=$HEAD2 (only change: merge of origin/main)"
echo '$ fm-guard-workarounds.py --repo <repo> --head feature --task wa-1 --log <events>'
python3 "$WT/bin/fm-guard-workarounds.py" --repo "$T/repo" --head feature --task wa-1 --log "$LOG"; echo "rc=$?"
python3 "$WT/bin/fm-guard-workarounds.py" --repo "$T/repo" --head feature --task wa-1 --log "$LOG" --json >"$T/wa.jsonl"; cat "$T/wa.jsonl"
echo '$ adversarial: same history, no recorded refusal -> no base-merge-only signature'
python3 "$WT/bin/fm-guard-workarounds.py" --repo "$T/repo" --head feature --task wa-1 --log /dev/null; echo "rc=$?"
echo '$ fm-guard-metrics.sh --log <events> --workarounds <signatures>  (merge-green-head line)'
"$WT/bin/fm-guard-metrics.sh" --log "$LOG" --workarounds "$T/wa.jsonl" | grep -E '^(METRIC|RULE|REPEAT) merge-green-head'
echo '$ same, without --workarounds'
"$WT/bin/fm-guard-metrics.sh" --log "$LOG" | grep -E '^METRIC merge-green-head'
