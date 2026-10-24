#!/usr/bin/env bash
# Live drive of the public bin/fm-dispatch-resolve.sh CLI for ship T6.
# Disposable FM_HOME, a local fake TypeSafe endpoint (FM_TEST_SEAM), and fake
# quota-axi/omp. No paid provider call; no real fleet state.
# Usage: live-drive.sh <worktree>
set -u
ROOT=$1
EV=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-t6-live.XXXXXX")
server=''
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$W"' EXIT
H="$W/home"; FB="$W/fakebin"; mkdir -p "$H/config" "$FB"
CALLS="$W/calls.jsonl"; SET="$W/settings.json"; : > "$CALLS"; echo '{}' > "$SET"
PASS=0 FAILN=0
ok() { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf 'FAIL  %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
section() { printf '\n===== %s =====\n' "$1"; }

cat > "$W/quota.json" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}
JSON
cat > "$FB/quota-axi" <<SH
#!/usr/bin/env bash
case "\$1" in --version) echo 0.1.51 ;; --json) cat "$W/quota.json" ;; *) exit 2 ;; esac
SH
cat > "$FB/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in usage) echo '{"reports":[]}' ;; models) echo '{"models":[]}' ;; *) exit 2 ;; esac
SH
chmod +x "$FB/quota-axi" "$FB/omp"

# Fake TypeSafe: answers exactly the questions asked. settings.json maps a
# question id to its noul/score value or model choice; unknown judgment_* nouls get
# settings.noul_default (default 0).
cat > "$W/provider.mjs" <<'JS'
import http from 'node:http';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const [setPath, callsPath, portPath] = process.argv.slice(2);
http.createServer(async (req, res) => {
  let body = ''; for await (const c of req) body += c;
  const rq = JSON.parse(body), s = JSON.parse(readFileSync(setPath, 'utf8'));
  appendFileSync(callsPath, JSON.stringify(rq) + '\n');
  const answers = {};
  for (const [id, q] of Object.entries(rq.questions)) {
    if (q.type === 'choice') {
      const sel = s[id] ?? 'fast';
      answers[id] = { type: 'choice', choice: sel, confidence: 0.95, probabilities: Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === sel ? 1 : 0])) };
    } else if (q.type === 'score') {
      const sc = s[id] ?? 0;
      answers[id] = { type: 'score', score: sc, confidence: 0.95, probabilities: Object.fromEntries(q.criteria.map((_, i) => [i, i === Math.round(sc) ? 1 : 0])), legend: Object.fromEntries(q.criteria.map((t, i) => [i, t])) };
    } else answers[id] = { type: 'noul', noul: s[id] ?? (id.startsWith('judgment_') ? s.noul_default ?? 0 : 0) };
  }
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ model: 'jev-1.13.0', answers, usage: { input_tokens: 100, output_tokens: 20 } }));
}).listen(0, '127.0.0.1', function () { writeFileSync(portPath, String(this.address().port)); });
JS
node "$W/provider.mjs" "$SET" "$CALLS" "$W/port" 2>/dev/null &
server=$!
for _ in $(seq 100); do [ -s "$W/port" ] && break; sleep .05; done
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$W/port")"
unset FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE FM_MODEL_CATALOG_DIR

RULES="$H/config/crew-dispatch.json"
resolve() {  # <brief> [args...]; sets OUT, ERR, RC
  local b=$1; shift
  OUT=$(PATH="$FB:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=synthetic-local-key bash "$ROOT/bin/fm-dispatch-resolve.sh" "$b" "$@" 2> "$W/err"); RC=$?
  ERR=$(cat "$W/err")
  printf -- '--- $ fm-dispatch-resolve.sh %s %s  (exit %s)\n%s\n' "${b##*/}" "$*" "$RC" "$OUT"
  [ -z "$ERR" ] || printf -- '--- stderr:\n%s\n' "$ERR"
}
ncalls() { wc -l < "$CALLS" | tr -d ' '; }
last() { tail -n 1 "$CALLS"; }
sett() { printf '%s\n' "$1" > "$SET"; }

# Production-shaped Vernant/non-Vernant rules, shared semantic judgments.
cat > "$RULES" <<'JSON'
{"judgments":{
  "design_judgment":{"type":"noul","instructions":"Does task require choosing a design not already settled in its specification?","criteria":{"true":"A design choice remains necessary.","false":"The design is already specified."}},
  "bounded":{"type":"noul","instructions":"Does task have a known cause and written acceptance?","criteria":{"true":"Cause and acceptance are stated.","false":"Cause or acceptance is open."}},
  "other_project_only":{"type":"noul","instructions":"Is task about the non-Vernant fleet tooling?","criteria":{"true":"It is fleet tooling work.","false":"It is not."}}
 },
 "rules":[
  {"when":"Vernant ship that needs design.","match":{"project":"vernant","kind":"ship","all":["design_judgment"]},"use":{"harness":"claude","model":"opus","effort":"high"}},
  {"when":"Non-Vernant bounded ship.","match":{"exclude_project":"vernant","kind":"ship","all":["bounded","other_project_only"]},"use":{"harness":"claude","model":"claude-haiku-5-5","effort":"low"}},
  {"when":"Vernant scout report.","match":{"project":"vernant","kind":"scout","all":["bounded"]},"use":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"medium"}}
 ],
 "default":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}}
JSON
cp "$RULES" "$W/base.json"
SHIP="$W/vernant-ship.md"
printf '%s\n' '# Task' "## Captain's intent" 'Repair the Vernant ingest boundary. This is a firstmate fleet tooling task; project=firstmate.' '## Firstmate spec' 'Design the new boundary.' > "$SHIP"
SCOUT="$W/vernant-scout.md"
printf '%s\n' '# Task' "## Captain's intent" 'Report on the Vernant ingest boundary.' '## Firstmate spec' 'Read and report.' '' '# Setup' 'This is a SCOUT task: the deliverable is a written report, not a PR.' > "$SCOUT"
QSCOUT="$W/ship-quoting-scout.md"
printf '%s\n' '# Task' "## Captain's intent" 'Repair the Vernant ingest boundary.' '## Firstmate spec' 'Example text:' '```md' '# Setup' 'This is a SCOUT task: the deliverable is a written report, not a PR.' '```' > "$QSCOUT"

section 'S1 T6(a): Vernant ship can never select a non-Vernant rule (adversarial: provider says every judgment is true)'
sett '{"noul_default":1}'
resolve "$SHIP" --project vernant
check 'Vernant ship clears on the Vernant rule (rule_1)' '[[ "$OUT" == *"status: clear"* && "$OUT" == *"rule: rule_1 "* ]]'
check 'non-Vernant rule_2 is absent from support' '[[ "$OUT" != *"rule_2="* ]]'
check 'non-Vernant-only judgment never reaches the provider' '! last | jq -e ".questions | has(\"judgment_other_project_only\")" >/dev/null'
check 'Vernant judgment is sent' 'last | jq -e ".questions | has(\"judgment_design_judgment\")" >/dev/null'
last | jq '{model, state_keys: (.state|keys), question_keys: (.questions|keys)}' > "$EV/s1-vernant-request-shape.json"
sett '{"noul_default":1,"judgment_design_judgment":0}'
resolve "$SHIP" --project vernant
check 'with Vernant judgment false and non-Vernant judgments true, result is default, never rule_2' '[[ "$OUT" != *"rule: rule_2"* && "$OUT" == *"rule: default"* ]]'
section 'S1b task prose cannot set project; --project firstmate never reaches Vernant rules'
sett '{"noul_default":1}'
resolve "$SHIP" --project firstmate
check 'firstmate project selects the non-Vernant rule_2' '[[ "$OUT" == *"rule: rule_2 "* ]]'
check 'Vernant rules absent from support for firstmate' '[[ "$OUT" != *"rule_1="* && "$OUT" != *"rule_3="* ]]'
check 'request repository is the --project value, not task prose' '[ "$(last | jq -r .state.repository)" = firstmate ]'

section 'S2 missing --project with project-scoped rules escalates and sends nothing'
before=$(ncalls)
resolve "$SHIP"
check 'status escalate naming the missing project' '[[ "$OUT" == *"status: escalate"* && "$OUT" == *"reason: a project-scoped rule needs --project"* ]]'
check 'no profile line' '[[ "$OUT" != *"profile:"* ]]'
check 'zero provider calls' '[ "$before" = "$(ncalls)" ]'
check 'exit 0' '[ "$RC" = 0 ]'

section 'S3 Q7 deleted / S5 current model, no pin / S6 no kind sent'
resolve "$SHIP" --project vernant
check 'request has no categorical rule or profile (workflow) question' '[ "$(last | jq -r "[.questions | has(\"rule\"), has(\"profile\")] | any")" = false ]'
check 'non-judgment questions are exactly ambiguity, effort, model, needs_desktop' '[ "$(last | jq -c "[.questions|keys[]|select(startswith(\"judgment_\")|not)]")" = "[\"ambiguity\",\"effort\",\"model\",\"needs_desktop\"]" ]'
check 'every judgment question is a single-judgment Noul' '[ "$(last | jq -r "[.questions|to_entries[]|select(.key|startswith(\"judgment_\"))|.value.type]|unique|join(\",\")")" = noul ]'
check 'request model is jev-latest (no pinned version)' '[ "$(last | jq -r .model)" = jev-latest ]'
check 'request state holds only task and repository (no kind)' '[ "$(last | jq -c ".state|keys")" = "[\"repository\",\"task\"]" ]'
for label in human browser_agent deterministic_script fast_agent; do
  sett "{\"noul_default\":1,\"profile\":\"$label\",\"rule\":\"rule_2\"}"
  resolve "$SHIP" --project vernant
  check "obsolete workflow label '$label' cannot escalate or redirect" '[[ "$OUT" == *"status: clear"* && "$OUT" == *"rule: rule_1 "* ]]'
done

section 'S4 Q9 desktop question has criteria and keeps its boundary'
resolve "$SHIP" --project vernant
check 'needs_desktop is a noul with true/false criteria' 'last | jq -e ".questions.needs_desktop | .type==\"noul\" and (.criteria.true|length>0) and (.criteria.false|length>0)" >/dev/null'
last | jq '.questions.needs_desktop' > "$EV/s4-needs-desktop-question.json"
sett '{"noul_default":1,"needs_desktop":0.5}'
resolve "$SHIP" --project vernant
check 'needs_desktop 0.5 does not escalate' '[[ "$OUT" == *"status: clear"* ]]'
sett '{"noul_default":1,"needs_desktop":0.9}'
resolve "$SHIP" --project vernant
check 'needs_desktop 0.9 escalates for a capability decision' '[[ "$OUT" == *"status: escalate"* && "$OUT" == *"desktop access requires an explicit capability decision"* ]]'

section 'S7 brief kind decided in code from # Setup; fenced quote does not demote a ship'
sett '{"noul_default":1}'
resolve "$SCOUT" --project vernant
check 'scout brief selects the Vernant scout rule_3' '[[ "$OUT" == *"rule: rule_3 "* && "$OUT" != *"rule_1="* ]]'
check 'scout request state still has no kind field' '[ "$(last | jq -c ".state|keys")" = "[\"repository\",\"task\"]" ]'
resolve "$QSCOUT" --project vernant
check 'ship quoting the scout line in a fence stays ship (rule_1)' '[[ "$OUT" == *"rule: rule_1 "* && "$OUT" != *"rule_3="* ]]'

section 'S8 never-send line matching only a judgment id withholds the request'
printf '%s\n' 'other_project_only' > "$H/config/dispatch-never-send"
before=$(ncalls)
resolve "$SHIP" --project firstmate
check 'stdout empty, exit 0' '[ -z "$OUT" ] && [ "$RC" = 0 ]'
check 'stderr says off and nothing sent' '[[ "$ERR" == *"dispatch-resolve: off ("*"nothing sent)"* ]]'
check 'stderr does not echo the private value' '[[ "$ERR" != *other_project_only* ]]'
check 'zero provider calls' '[ "$before" = "$(ncalls)" ]'
resolve "$SHIP" --project vernant
check 'same list on Vernant (judgment not sent) still resolves' '[[ "$OUT" == *"status: clear"* ]]'
rm -f "$H/config/dispatch-never-send"

section 'S9 legacy unstructured rules fail closed before any network call'
printf '%s\n' '{"rules":[{"when":"Vernant ship that needs design.","use":{"harness":"claude","model":"opus"}}]}' > "$RULES"
before=$(ncalls)
resolve "$SHIP" --project vernant
check 'exit 2 config error naming judgments' '[ "$RC" = 2 ] && [[ "$ERR" == *"malformed rules file"*"judgments"* ]]'
check 'zero provider calls' '[ "$before" = "$(ncalls)" ]'

section 'S10 exact support tie between different outcomes is ambiguous in either rule order'
for order in AB BA; do
  if [ $order = AB ]; then sel='[.a,.b]'; else sel='[.b,.a]'; fi
  jq -n "{judgments:{x:{type:\"noul\",instructions:\"Does task have x?\",criteria:{true:\"x\",false:\"not x\"}},y:{type:\"noul\",instructions:\"Does task have y?\",criteria:{true:\"y\",false:\"not y\"}}}} as \$b |
   {a:{when:\"A\",match:{all:[\"x\"]},min_confidence:0.8,use:{harness:\"claude\",model:\"opus\",effort:\"high\"}},
    b:{when:\"B\",match:{all:[\"x\"],none:[\"y\"]},use:{harness:\"claude\",model:\"claude-sonnet-5-5[1m]\",effort:\"high\"}}} as \$r |
   \$b + {rules: (\$r | $sel), default:{harness:\"claude\",model:\"claude-sonnet-5-5[1m]\",effort:\"high\"}}" > "$RULES"
  sett '{"judgment_x":0.7,"judgment_y":0.2}'
  resolve "$SHIP" --project firstmate
  check "order $order: ambiguous conflicting rule support tie" '[[ "$OUT" == *"status: ambiguous"* && "$OUT" == *"conflicting rule support tie"* ]]'
done

section 'S11 T6(b): live CLI replay of all 136 logged resolve structures, no Q7 escalation'
jq -n '{judgments: ([range(1;8)] | map({key:"r\(.)", value:{type:"noul",instructions:"Does this recorded task have property \(.)?",criteria:{true:"present",false:"absent"}}}) | from_entries),
  rules: [range(1;8) | {when:"Recorded rule \(.)", match:{all:["r\(.)"]}, use:{harness:"claude",model:"claude-sonnet-5-5[1m]",effort:"high"}}],
  default:{harness:"claude",model:"claude-sonnet-5-5[1m]",effort:"high"}}' > "$RULES"
FIX="$ROOT/tests/fixtures/dispatch-resolve-20261024.json"
n=0 esc=0 mism=0 formerQ7=0
: > "$EV/s11-replay.tsv"
while IFS=$'\t' read -r choice reason; do
  n=$((n+1))
  case "$reason" in *"requires an explicit handler or capability decision"*) formerQ7=$((formerQ7+1)) ;; esac
  if [[ "$choice" =~ ^rule_([1-7])$ ]]; then sett "{\"judgment_r${BASH_REMATCH[1]}\":1}"; want=$choice; else sett '{}'; want=default; fi
  o=$(PATH="$FB:$PATH" FM_HOME="$H" TYPESAFE_API_KEY=synthetic-local-key bash "$ROOT/bin/fm-dispatch-resolve.sh" "$SHIP" --project firstmate 2>/dev/null)
  st=$(sed -n 's/^  status: //p' <<<"$o" | head -1); got=$(sed -n 's/^  rule: \([^ ]*\).*/\1/p' <<<"$o" | head -1)
  [ "$st" = escalate ] && esc=$((esc+1))
  [ "$got" = "$want" ] || mism=$((mism+1))
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$choice" "${reason:-}" "$st" "$got" >> "$EV/s11-replay.tsv"
done < <(jq -r '.[] | [(.choice // "null"), (.reason // "")] | @tsv' "$FIX")
printf 'replayed=%s formerly_Q7_escalated=%s now_escalated=%s rule_mismatch=%s\n' "$n" "$formerQ7" "$esc" "$mism"
check 'all 136 logged resolves replayed through the CLI' '[ "$n" = 136 ]'
check 'no replayed resolve escalates' '[ "$esc" = 0 ]'
check 'each replay selects its logged rule (or default)' '[ "$mism" = 0 ]'

printf '\nTOTAL pass=%s fail=%s provider_calls=%s (all to local fake endpoint)\n' "$PASS" "$FAILN" "$(ncalls)"
[ "$FAILN" = 0 ]
