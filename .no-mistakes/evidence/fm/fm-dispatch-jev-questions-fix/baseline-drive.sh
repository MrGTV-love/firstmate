#!/usr/bin/env bash
# Pre-fix baseline: base commit's resolver with its own (legacy) rules schema,
# a local fake TypeSafe endpoint, and contradictory answers. Shows the removed
# Q7 workflow escalation and the Choice-driven non-Vernant pick.
# Usage: baseline-drive.sh <repo-worktree> <base-commit>
set -u
REPO=$1 BASE=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-t6-base.XXXXXX"); server=''
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/src" "$W/home/config" "$W/fb"
git -C "$REPO" archive "$BASE" | tar -x -C "$W/src"
cat > "$W/fb/quota-axi" <<'Q'
#!/usr/bin/env bash
case "$1" in --version) echo 0.1.51 ;; --json) echo '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}' ;; *) exit 2 ;; esac
Q
printf '#!/usr/bin/env bash\ncase "$1" in usage) echo %s ;; models) echo %s ;; *) exit 2 ;; esac\n' "'{\"reports\":[]}'" "'{\"models\":[]}'" > "$W/fb/omp"
chmod +x "$W/fb/"*
cat > "$W/p.mjs" <<'JS'
import http from 'node:http'; import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const [sp, cp, pp] = process.argv.slice(2);
http.createServer(async (req, res) => { let b = ''; for await (const c of req) b += c;
  const rq = JSON.parse(b), s = JSON.parse(readFileSync(sp, 'utf8')); appendFileSync(cp, JSON.stringify(rq) + '\n'); const a = {};
  for (const [id, q] of Object.entries(rq.questions)) {
    if (q.type === 'choice') { const sel = s[id] ?? 'fast'; a[id] = { type: 'choice', choice: sel, confidence: 0.95, probabilities: Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === sel ? 1 : 0])) }; }
    else if (q.type === 'score') { a[id] = { type: 'score', score: 0, confidence: 0.95, probabilities: Object.fromEntries(q.criteria.map((_, i) => [i, i === 0 ? 1 : 0])), legend: Object.fromEntries(q.criteria.map((t, i) => [i, t])) }; }
    else a[id] = { type: 'noul', noul: 0 }; }
  res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ model: 'jev-1.13.0', answers: a, usage: { input_tokens: 100, output_tokens: 20 } }));
}).listen(0, '127.0.0.1', function () { writeFileSync(pp, String(this.address().port)); });
JS
echo '{}' > "$W/s.json"; : > "$W/calls"
node "$W/p.mjs" "$W/s.json" "$W/calls" "$W/port" & server=$!
for _ in $(seq 100); do [ -s "$W/port" ] && break; sleep .05; done
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$W/port")"
unset FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_MODEL_CATALOG_DIR
printf '%s\n' '{"rules":[{"when":"Vernant ship that needs design.","use":{"harness":"claude","model":"opus","effort":"high"}},{"when":"Non-Vernant bounded ship.","use":{"harness":"claude","model":"claude-haiku-5-5","effort":"low"}}],"default":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}}' > "$W/home/config/crew-dispatch.json"
printf '%s\n' '# Task' "## Captain's intent" 'Repair the Vernant ingest boundary.' '## Firstmate spec' 'Design the new boundary.' > "$W/brief.md"
go() { echo "--- base resolver, --project vernant, answers: $1"; echo "$1" > "$W/s.json"
  PATH="$W/fb:$PATH" FM_HOME="$W/home" TYPESAFE_API_KEY=synthetic-local-key bash "$W/src/bin/fm-dispatch-resolve.sh" "$W/brief.md" --project vernant 2>&1 | grep -E "status:|rule:|reason:|profile:"; }
go '{"rule":"rule_1","profile":"human"}'
go '{"rule":"rule_2","profile":"fast_agent"}'
echo "--- base request: model=$(tail -1 "$W/calls" | jq -r .model) questions=$(tail -1 "$W/calls" | jq -c '.questions|keys')"
