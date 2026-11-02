#!/usr/bin/env bash
# fm-guard-metrics.sh --undecided (the session-start GUARD PASS reader) on a writer-built log.
set -u
E=$PWD/bin/fm-guard-event.sh; M=$PWD/bin/fm-guard-metrics.sh
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-r6u.XXXXXX"); trap 'rm -rf "$S"' EXIT; L=$S/g.jsonl; unset FM_TASK_ID
for i in $(seq 1 30); do $E gcut deny --rule r --task "t$i" --log "$L"; $E gcut bypass --rule r --task "t$i" --override --log "$L"; $E gkeep allow --rule r --task "t$i" --log "$L"; done
for i in $(seq 1 30); do $E gjudged deny --rule r --task "t$i" --log "$L"; $E gjudged bypass --rule r --task "t$i" --override --log "$L"; done
jq -n --arg d "keep $(date -u +%Y-%m-%d): reviewed" '{guards:[{id:"gcut",harm:"reversible"},{id:"gkeep",harm:"irreversible"},{id:"gjudged",harm:"reversible",retirement_decision:$d}]}' >"$S/reg.json"
echo "== --undecided (nominated, no decision covers the evidence):"; $M --log "$L" --registry "$S/reg.json" --undecided; echo "rc=$?"
echo "== verdicts:"; $M --log "$L" --registry "$S/reg.json" --json | jq -c '.guards[]|{id,opportunities,override_rate,verdict}'
