#!/usr/bin/env bash
# Public resolver behavior against a local HTTP provider, without paid calls.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_MODEL_CATALOG_DIR
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
server=''
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; fm_test_cleanup' EXIT
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/config"
RULES="$HOME_DIR/config/crew-dispatch.json"
BRIEF="$TMP_ROOT/brief.md"
SETTINGS="$TMP_ROOT/settings.json"
CALLS="$TMP_ROOT/calls.jsonl"
QUOTA="$TMP_ROOT/quota.json"
POOL="$TMP_ROOT/pool.json"
export QUOTA_AXI_FIXTURE="$QUOTA" POOL
cat > "$RULES" <<'JSON'
{"rules":[
 {"when":"Only when the captain expressly requires Claude for this task, or executing inside Claude Code is intrinsic.","use":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}},
 {"when":"Ship task in the Vernant project that needs design.","use":{"harness":"claude","model":"opus","effort":"high"}},
 {"when":"Non-Vernant ship task that is well understood.","use":[{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"},{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high","provider":"codex"}]},
 {"when":"Trivial mechanical edit.","use":[{"harness":"claude","model":"claude-haiku-5-5","effort":"max"},{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"low","provider":"codex"},{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}]}
],"default":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}}
JSON
cp "$RULES" "$TMP_ROOT/base-rules.json"
printf '%s\n' '# Task' "## Captain's intent" 'Fix a bounded bug with a known cause.' '## Firstmate spec' 'Use the existing implementation.' > "$BRIEF"
cat > "$QUOTA" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}
JSON
printf '%s\n' '{"reports":[]}' > "$POOL"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in --version) echo 0.1.51 ;; --json) cat "$QUOTA_AXI_FIXTURE" ;; *) exit 2 ;; esac
SH
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  usage) cat "$POOL" ;;
  models) printf '%s\n' '{"models":[{"selector":"anthropic/claude-haiku-5-5"}]}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/omp"
cat > "$TMP_ROOT/provider.mjs" <<'JS'
import http from 'node:http';
import { readFileSync, writeFileSync, appendFileSync } from 'node:fs';
const [settingsPath, callsPath, portPath] = process.argv.slice(2);
const server = http.createServer(async (req, res) => {
  let body = ''; for await (const chunk of req) body += chunk;
  const request = JSON.parse(body), settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  appendFileSync(callsPath, JSON.stringify(request) + '\n');
  if (settings.http) { res.writeHead(settings.http); res.end('private-error-sentinel'); return; }
  const answers = {};
  for (const [id, q] of Object.entries(request.questions)) {
    if (q.type === 'choice') {
      const selected = settings[id] ?? (id === 'rule' ? 'rule_3' : id === 'profile' ? 'fast_agent' : 'fast');
      answers[id] = { type: 'choice', choice: selected, confidence: settings.confidence ?? 0.95,
        probabilities: settings[`${id}_probabilities`] ?? Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === selected ? 1 : 0])) };
    } else if (q.type === 'score') {
      const score = settings[id] ?? 0;
      answers[id] = { type: 'score', score, confidence: 0.95,
        probabilities: Object.fromEntries(q.criteria.map((_, i) => [i, i === Math.round(score) ? 1 : 0])),
        legend: Object.fromEntries(q.criteria.map((s, i) => [i, s])) };
    } else answers[id] = { type: 'noul', noul: settings[id] ?? 0 };
  }
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ model: 'jev-1.13.0', answers, usage: { input_tokens: 100, output_tokens: 20 } }));
});
server.listen(0, '127.0.0.1', () => writeFileSync(portPath, String(server.address().port)));
JS
printf '%s\n' '{}' > "$SETTINGS"
node "$TMP_ROOT/provider.mjs" "$SETTINGS" "$CALLS" "$TMP_ROOT/port" &
server=$!
for _ in {1..100}; do [ ! -f "$TMP_ROOT/port" ] || break; sleep .05; done
[ -f "$TMP_ROOT/port" ] || fail 'local provider did not start'
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$TMP_ROOT/port")"
run() {
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=synthetic-key bash "$ROOT/bin/fm-dispatch-resolve.sh" "$BRIEF" --project "${1:-firstmate}" 2> "$TMP_ROOT/error") || fail "resolver failed: $(cat "$TMP_ROOT/error")"
}
count() { [ ! -f "$CALLS" ] && echo 0 || wc -l < "$CALLS" | tr -d ' '; }

# Reproduce the former default preference: a positive pooled sibling cannot be
# discarded just because Claude exposes a scalar and the pool does not.
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({reports:[{provider:"openai-codex",fetchedAt:Date.now(),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},limits:[{scope:{tier:"chat"},amount:{remainingFraction:.9}}]}]}))' "$POOL"
run
assert_contains "$OUT" "--model 'openai-codex/gpt-6.1-sol' --effort 'high'" 'higher native pool headroom can win over ranked Claude'
assert_contains "$OUT" 'quota_score=0.9' 'pool score is normalized from a usable native account'
assert_contains "$OUT" 'common=["headroom"]' 'unknown pool economics are not scored as zero'
node -e 'const fs=require("fs"),p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));p.reports[0].limits[0].amount.remainingFraction=.8;fs.writeFileSync(process.argv[1],JSON.stringify(p))' "$POOL"
run
assert_contains "$OUT" 'status: escalate' 'equal headroom without comparable economics is a genuine tie'
assert_not_contains "$OUT" '  profile:' 'evidence ties do not pick by array order'
pass 'pool bias is removed by normalized nonadditive evidence, with explicit ties'

# When both candidates have every component, a large economic scalar must be
# normalized before weighting: it cannot erase the headroom component.
cp "$QUOTA" "$TMP_ROOT/base-quota.json"
jq '.rules[2].use=[.rules[2].use[0], {harness:"claude",model:"opus",effort:"high"}]' "$TMP_ROOT/base-rules.json" > "$RULES"
cat > "$QUOTA" <<'JSON'
{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[
 {"scope":"all_models","status":"known","effectivePercentRemaining":100,"runway":{"status":"through_reset"},"selection":{"spendPriority":100}},
 {"scope":"model:claude-sonnet-5-5[1m]","status":"known","effectivePercentRemaining":90,"runway":{"status":"through_reset"},"selection":{"spendPriority":0}},
 {"scope":"model:opus","status":"known","effectivePercentRemaining":60,"runway":{"status":"through_reset"},"selection":{"spendPriority":100}}
]}}]}
JSON
run
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'headroom can outweigh bounded economic urgency within the approved class'
jq '(.providers[0].quotaSemantics.effectiveAvailability[] | select(.scope=="model:opus").effectivePercentRemaining)=80' "$QUOTA" > "$TMP_ROOT/economic.json"
cp "$TMP_ROOT/economic.json" "$QUOTA"
run
assert_contains "$OUT" "--model 'opus' --effort 'high'" 'known economic urgency can outweigh a smaller headroom advantage without weakening the class'
cp "$TMP_ROOT/base-quota.json" "$QUOTA"
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'common headroom, economic urgency, and feasible runway are normalized before weighting'

# Proven exhaustion excludes the pool; the powerful rule remains high even
# when Jev suggests fast and low effort.
printf '%s\n' '{"reports":[{"provider":"openai-codex","fetchedAt":9999999999999,"metadata":{"meterStates":{"chat":{"allowed":false,"limitReached":true}}}}]}' > "$POOL"
run
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'rule reasoning floor survives a low effort score'
pass 'quota veto preserves required reasoning class'

# Captain-required Claude resolves without a model call; mere comparisons do not.
before=$(count)
printf '%s\n' '# Task' "## Captain's intent" 'Use Claude Code for this repair.' > "$BRIEF"
run
assert_contains "$OUT" "--harness 'claude'" 'explicit Claude requirement is honored'
assert_equals "$before" "$(count)" 'explicit requirement never reaches Jev'
printf '%s\n' '# Task' "## Captain's intent" 'Investigate a Claude-specific hook failure.' > "$BRIEF"
run
assert_contains "$OUT" 'rule: rule_1' 'an intrinsic Claude-specific investigation uses its deterministic rule'
assert_equals "$before" "$(count)" 'intrinsic Claude-specific investigation never reaches Jev'
printf '%s\n' '# Task' "## Captain's intent" 'Compare Claude and Sol usage for a bounded change.' > "$BRIEF"
run
assert_equals "$((before + 1))" "$(count)" 'model comparison still requires judgment'
assert_not_contains "$(cat "$CALLS")" '"rule_1"' 'Claude-only rule was pruned before judgment'
pass 'deterministic Claude policy distinguishes execution requirements from mentions'

# Project and session constraints are removed before inference, not after.
printf '%s\n' '{}' > "$SETTINGS"
run
last_request=$(node -e 'const fs=require("fs");const rows=fs.readFileSync(process.argv[1],"utf8").trim().split("\n");console.log(rows.at(-1))' "$CALLS")
assert_not_contains "$last_request" '"rule_2"' 'Vernant rule cannot judge a non-Vernant task'
printf '%s\n' '{"rule":"rule_2"}' > "$SETTINGS"
run vernant
last_request=$(node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").at(-1))' "$CALLS")
assert_not_contains "$last_request" '"rule_3"' 'non-Vernant rule cannot judge Vernant'
printf '%s\n' omp-or-tc > "$HOME_DIR/config/session-launch-policy"
printf '%s\n' '# Task' "## Captain's intent" 'Use Claude Code for this repair.' > "$BRIEF"
before=$(count); run
assert_contains "$OUT" 'status: escalate' 'disallowed required harness cannot be substituted'
assert_equals "$before" "$(count)" 'session refusal never reaches Jev'
rm "$HOME_DIR/config/session-launch-policy"
pass 'project and session launch pre-checks constrain judgment deterministically'

# One paid judgment returns workflow, ambiguity, desktop, tier, and effort.
printf '%s\n' '# Task' "## Captain's intent" 'Make a trivial typo correction.' > "$BRIEF"
printf '%s\n' '{"rule":"rule_4","model":"fast"}' > "$SETTINGS"
before=$(count); run
assert_equals "$((before + 1))" "$(count)" 'independent questions share one request'
assert_contains "$OUT" "--model 'claude-haiku-5-5' --effort 'max'" 'fast task uses approved cheap candidate and Haiku max'
printf '%s\n' '{"rule":"rule_4","model":"powerful","effort":2,"profile":"reasoning_agent"}' > "$SETTINGS"
run
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'powerful response excludes cheap class and maps effort'
pass 'Level 5 tier and effort map to the approved model matrix'

printf '%s\n' '{"ambiguity":1,"needs_desktop":0.5}' > "$SETTINGS"; run
assert_contains "$OUT" 'status: clear' 'the exact ambiguity and desktop thresholds do not escalate'
for settings in '{"ambiguity":1.004}' '{"ambiguity":2}' '{"profile":"human"}' '{"needs_desktop":1}' '{"profile":"browser_agent"}' '{"profile":"deterministic_script"}'; do
  printf '%s\n' "$settings" > "$SETTINGS"; run
  assert_contains "$OUT" 'status: escalate' 'uncertain or capability-dependent handler escalates'
  assert_not_contains "$OUT" '  profile:' 'no permission or handler is invented'
done
printf '%s\n' '{"confidence":0.4}' > "$SETTINGS"; run
assert_not_contains "$OUT" '  profile:' 'low-confidence upstream agent routes to human'
pass 'ambiguity and unsupported handler/capability decisions escalate'

# Privacy refusal happens before either inference or quota selection.
printf '%s\n' 'typo correction' > "$HOME_DIR/config/dispatch-never-send"
before=$(count); run
assert_equals '' "$OUT" 'never-send refusal emits no profile or request diagnostics'
assert_equals "$before" "$(count)" 'private literal never reaches provider'
rm "$HOME_DIR/config/dispatch-never-send"
printf '%s\n' '{"http":400}' > "$SETTINGS"; run
assert_contains "$OUT" 'status: error' 'provider rejection is a structured error'
assert_not_contains "$OUT$(cat "$TMP_ROOT/error")" 'private-error-sentinel' 'raw provider error is withheld'
# A credit or key failure reaches the account-health alert at once; a 200 afterwards raises its recovered note.
rm -rf "$HOME_DIR/state"
assert_absent "$HOME_DIR/state/.typesafe-health" 'an http 400 is not a credit or key failure and records no account-health state'
for code in 402 402 401; do printf '{"http":%s}\n' "$code" > "$SETTINGS"; run; done
assert_contains "$OUT" 'status: error' 'an http 401 stays a structured error outcome'
assert_equals 1 "$(grep -cF $'\ttypesafe-health-credits\t' "$HOME_DIR/state/.wake-queue")" 'repeated 402 raises exactly one account-health wake'
assert_equals 1 "$(grep -cF $'\ttypesafe-health-auth\t' "$HOME_DIR/state/.wake-queue")" 'a 401 raises one account-health wake of its own class'
printf '%s\n' '{}' > "$SETTINGS"; run
assert_equals 1 "$(grep -cF $'\ttypesafe-health-recovered\t' "$HOME_DIR/state/.wake-queue")" 'a successful answer raises one recovered note'
assert_not_contains "$(cat "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/.typesafe-health")" 'synthetic-key' 'the key is in no account-health record'
rm -rf "$HOME_DIR/state"
pass 'privacy boundaries and provider errors preserve safe fallback'

printf '%s\n' '{}' > "$SETTINGS"
jq '.rules[2].approval="captain"' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: escalate' 'captain approval remains independent of weighted quota'
assert_not_contains "$OUT" '  profile:' 'quota cannot override approval'
jq '.rules[2].use[0].floor={scope:"all_models",min_percent:90}' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'profile floor all_models below 90%' 'a declared floor vetoes the candidate'
assert_not_contains "$OUT" '  profile:' 'positive headroom score cannot mask a floor failure'
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'captain approval and declared floors veto before weighted selection'

# Even fixed upstream question strings pass the existing never-send filter.
printf '%s\n' 'least costly' > "$HOME_DIR/config/dispatch-never-send"
before=$(count); run
assert_equals "$before" "$(count)" 'question literals are checked before transport'
rm "$HOME_DIR/config/dispatch-never-send"
cat > "$BRIEF" <<'MD'
# Task
## Captain's intent
Fix the public typo.
<!-- dispatch-never-send:start -->
PRIVATE-REGION-SENTINEL
## Internal heading
<!-- dispatch-never-send:end -->
Keep the public behavior.
## Firstmate spec
No unrelated changes.
# Setup
BOILERPLATE-SENTINEL
MD
printf '%s\n' '# dispatch-never-send marked-sections' > "$HOME_DIR/config/dispatch-never-send"
run
last_request=$(node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").at(-1))' "$CALLS")
assert_not_contains "$last_request" 'PRIVATE-REGION-SENTINEL' 'protected regions remain local'
assert_not_contains "$last_request" 'BOILERPLATE-SENTINEL' 'standard safety boilerplate does not inflate routing difficulty'
assert_contains "$last_request" 'Keep the public behavior.' 'private headings cannot truncate permitted task intent'
rm "$HOME_DIR/config/dispatch-never-send"
pass 'fixed questions, task extraction, and protected regions retain their privacy boundary'
printf '%s\n' '# Task' "## Captain's intent" 'Repair a bounded bug.' > "$BRIEF"
jq '.rules[2].floor={provider:"claude",scope:"all_models",min_percent:90} |
  .default={harness:"claude",model:"claude-haiku-5-5",effort:"max"}' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: escalate' 'a rule-floor failure cannot fall through to a weaker default class'
assert_not_contains "$OUT" '  profile:' 'the quota floor cannot authorize a downgrade'
cp "$TMP_ROOT/base-rules.json" "$RULES"

# A preferred powerful rule below its own probability floor is ambiguous, not
# permission to take a lower-confidence trivial rule with a lower floor.
jq '.rules[2].min_confidence=0.99 | .rules[3].min_confidence=0.1' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule_probabilities":{"rule_3":0.8,"rule_4":0.2,"default":0}}' > "$SETTINGS"
run
assert_contains "$OUT" 'status: ambiguous' 'a selected rule below its own floor cannot substitute a weaker runner-up'
assert_not_contains "$OUT" '  profile:' 'confidence cannot silently weaken the reasoning class'
printf '%s\n' '{}' > "$SETTINGS"
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'rule-specific confidence floors preserve the selected reasoning class'

# A declared launch stand-in must not turn an exhausted powerful rule into an
# unscored weaker clear result outside the rule's approved primary candidates.
cp "$QUOTA" "$TMP_ROOT/pre-exhaustion-quota.json"
jq '(.providers[0].quotaSemantics.effectiveAvailability[0]) |=
  (.effectivePercentRemaining=0 | .runway={status:"exhausted_now"})' "$QUOTA" > "$TMP_ROOT/exhausted-quota.json"
cp "$TMP_ROOT/exhausted-quota.json" "$QUOTA"
jq '.rules[2].fallback=[{harness:"omp",model:"anthropic/claude-haiku-5-5",effort:"low"}]' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: escalate' 'exhaustion cannot bypass the required class through an unweighted stand-in'
assert_not_contains "$OUT" '  profile:' 'no weaker or unscored fallback profile is dispatched'
cp "$TMP_ROOT/pre-exhaustion-quota.json" "$QUOTA"
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'exhaustion cannot bypass class and quota scoring through launch stand-ins'

jq '(.providers[0].quotaSemantics.effectiveAvailability[0].runway) = {"status":"projected_exhaustion","projectionConfidence":"established","usableRunwaySeconds":60}' "$QUOTA" > "$TMP_ROOT/short.json"
cp "$TMP_ROOT/short.json" "$QUOTA"
run
assert_contains "$OUT" 'status: escalate' 'established runway shorter than horizon vetoes dispatch'
assert_not_contains "$OUT" '  profile:' 'short winner is not substituted with a weaker class'
pass 'task-horizon feasibility still vetoes the quota winner'
