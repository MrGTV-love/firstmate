#!/usr/bin/env bash
# Boundary + cut-straddle probes against the real Claude hook on the TARGET tree (loopback TypeSafe stand-in).
set -u
TREE=$1; OUT=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-jev-bound.XXXXXX")
trap 'kill $FAKE 2>/dev/null; rm -rf "$T"' EXIT
HOME_DIR=$T/home; WT=$T/wt; DATA=$HOME_DIR/data/t1
mkdir -p $HOME_DIR/config $HOME_DIR/state $DATA $WT/src
printf 'TYPESAFE_API_KEY=fm-live-fixture-key\n' > $HOME_DIR/.env
cat > $T/fake.mjs <<'JS'
import { createServer } from 'node:http';
import { appendFileSync, writeFileSync } from 'node:fs';
const [log, portFile] = process.argv.slice(2);
createServer((req, res) => {
  let body = '';
  req.on('data', c => { body += c; });
  req.on('end', () => {
    const request = JSON.parse(body);
    const text = JSON.stringify(request.state);
    appendFileSync(log, JSON.stringify({ bytes: Buffer.byteLength(body), content: request.state.content ?? request.state.command ?? '' }) + '\n');
    const risky = /rm -rf|IGNORE PREVIOUS|sk-live/.test(text);
    const answers = {};
    for (const [id, q] of Object.entries(request.questions)) {
      if (q.type === 'noul') { answers[id] = { type: 'noul', noul: risky ? 0.95 : 0.05 }; continue; }
      const keys = Object.keys(q.criteria);
      const pick = risky && keys.includes('irreversible') ? 'irreversible' : keys[0];
      answers[id] = { type: 'choice', choice: pick, confidence: 1, probabilities: Object.fromEntries(keys.map(k => [k, k === pick ? 1 : 0])) };
    }
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ model: 'jev-fake', answers, usage: { input_tokens: 3, output_tokens: 1 } }));
  });
}).listen(0, '127.0.0.1', function () { writeFileSync(portFile, String(this.address().port)); });
JS
: > $T/req.log
node $T/fake.mjs $T/req.log $T/port & FAKE=$!
for _ in $(seq 1 100); do [ -s $T/port ] && break; sleep 0.05; done
export FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL=http://127.0.0.1:$(cat $T/port)/v1/systemone
reqs() { wc -l < $T/req.log | tr -d ' '; }
# write CONTENTFILE -> sets OUTCOME (allow|DENY), N (requests sent), ERR (error_type of last audit row)
write() {
  local b o payload; b=$(reqs)
  payload=$(jq -cn --arg cwd "$WT" --arg p "$WT/src/big.ts" --rawfile c "$1" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:"Write",tool_input:{file_path:$p,content:$c},tool_use_id:"b"}')
  o=$(printf '%s' "$payload" | "$TREE/bin/fm-jev-guard-hook.sh" $HOME_DIR $HOME_DIR/config $HOME_DIR/state t1 $WT $DATA firstmate FIRSTMATE_JEV_GUARD_V1 2>/dev/null)
  OUTCOME=$([ -z "$o" ] && echo allow || echo DENY); N=$(( $(reqs) - b ))
  ERR=$(tail -n 1 $HOME_DIR/state/jev-guard.jsonl | jq -r '.error_type // "-"')
  CHUNKS=$(tail -n 1 $HOME_DIR/state/jev-guard.jsonl | jq -r '.chunks')
}
mk() { head -c "$1" /dev/zero | tr '\0' 'x' > $T/c.txt; }
{
echo "== boundary 1: exact request ceiling (16384 bytes), plain ASCII content"
lo=1; hi=16384
while [ $lo -lt $hi ]; do mid=$(( (lo+hi+1)/2 )); mk $mid; write $T/c.txt; if [ $N -eq 1 ]; then lo=$mid; else hi=$((mid-1)); fi; done
echo "largest content still sent as ONE request: $lo bytes"
mk $lo; b=$(reqs); write $T/c.txt; echo "  at $lo: $OUTCOME requests=$N chunks=$CHUNKS maxbytes=$(tail -n +$((b+1)) $T/req.log | jq -s 'map(.bytes)|max')"
mk $((lo+1)); b=$(reqs); write $T/c.txt; echo "  at $((lo+1)): $OUTCOME requests=$N chunks=$CHUNKS maxbytes=$(tail -n +$((b+1)) $T/req.log | jq -s 'map(.bytes)|max')"

echo; echo "== boundary 2: piece-count limit (16 pieces) on plain ASCII"
lo=$((lo+1)); hi=300000
while [ $lo -lt $hi ]; do mid=$(( (lo+hi+1)/2 )); mk $mid; write $T/c.txt; if [ "$OUTCOME" = allow ]; then lo=$mid; else hi=$((mid-1)); fi; done
echo "largest content screened: $lo bytes"
mk $lo; b=$(reqs); write $T/c.txt; echo "  at $lo: $OUTCOME requests=$N chunks=$CHUNKS err=$ERR maxbytes=$(tail -n +$((b+1)) $T/req.log | jq -s 'map(.bytes)|max')"
mk $((lo+1)); b=$(reqs); write $T/c.txt; echo "  at $((lo+1)): $OUTCOME requests=$N chunks=$CHUNKS err=$ERR (requests sent must be 0)"

echo; echo "== adversarial: 15-byte credential 'sk-live-fixture' slid across the first cut, ASCII + escape-heavy + astral filler"
for kind in ascii quotes astral; do
  case $kind in ascii) unit='a';; quotes) unit='"\\';; astral) unit='😀';; esac
  # discover first cut: filler long enough to need 2 pieces; find where piece 1 ends by sending a marker-free payload
  python3 -I - "$unit" > $T/base.txt <<'PY'
import sys
unit=sys.argv[1].encode().decode('unicode_escape') if sys.argv[1]=='"\\\\' else sys.argv[1]
print(unit*20000,end='')
PY
  fill=$(cat $T/base.txt); total=${#fill}
  b=$(reqs); write $T/base.txt
  first=$(tail -n +$((b+1)) $T/req.log | head -1 | jq -r '.content | length')
  allow_leak=0; tested=0
  for off in $(seq $((first-40)) $((first+40))); do
    { printf '%s' "${fill:0:$off}"; printf 'sk-live-fixture'; printf '%s' "${fill:$off:4000}"; } > $T/c.txt
    write $T/c.txt; tested=$((tested+1))
    [ "$OUTCOME" = allow ] && allow_leak=$((allow_leak+1))
  done
  echo "  $kind filler: first piece = $first chars; token inserted at $tested offsets around the cut; slipped through: $allow_leak"
done
} > $OUT 2>&1
