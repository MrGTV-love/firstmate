#!/usr/bin/env bash
# Public resolver behavior against a local HTTP provider, without paid calls.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_MODEL_CATALOG_DIR
TMP_ROOT=$(fm_test_tmproot fm-dispatch-resolve)
server='' denied=''
trap '[ -z "$denied" ] || chmod 700 "$denied"; [ -z "$server" ] || kill "$server" 2>/dev/null; fm_test_cleanup' EXIT
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/config" "$HOME_DIR/data"
printf '%s\n' '# Projects' '- firstmate [no-mistakes] - Supervisor' '- vernant [no-mistakes] - Vernant' '- pager - Pager' '- orion-private - Synthetic privacy case' > "$HOME_DIR/data/projects.md"
RULES="$HOME_DIR/config/crew-dispatch.json"
BRIEF="$TMP_ROOT/brief.md"
SETTINGS="$TMP_ROOT/settings.json"
CALLS="$TMP_ROOT/calls.jsonl"
QUOTA="$TMP_ROOT/quota.json"
POOL="$TMP_ROOT/pool.json"
HEADERS="$TMP_ROOT/headers.jsonl"
export QUOTA_AXI_FIXTURE="$QUOTA" POOL QUOTA_AXI_CALLS="$TMP_ROOT/quota-calls"
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
# Records each call; FAKE_QUOTA_* knobs simulate versions, delays, and failures.
[ -z "${QUOTA_AXI_CALLS:-}" ] || printf '%s\n' "$*" >> "$QUOTA_AXI_CALLS"
case "$1" in
  --version) [ "${FAKE_QUOTA_VERSION_FAIL:-0}" = 1 ] && exit 1; printf '%s\n' "${FAKE_QUOTA_VERSION:-0.1.51}" ;;
  --json)
    [ "${FAKE_QUOTA_DELAY:-0}" = 0 ] || sleep "$FAKE_QUOTA_DELAY"
    [ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1
    cat "$QUOTA_AXI_FIXTURE" ;;
  *) exit 2 ;;
esac
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
import { readFileSync, writeFileSync, appendFileSync, copyFileSync } from 'node:fs';
const [settingsPath, callsPath, portPath, headersPath] = process.argv.slice(2);
// patch deep-merges into the answer envelope; a null value deletes the key.
const merge = (target, patch) => {
  for (const [k, v] of Object.entries(patch)) {
    if (v === null) delete target[k];
    else if (v && typeof v === 'object' && !Array.isArray(v) && target[k] && typeof target[k] === 'object') merge(target[k], v);
    else target[k] = v;
  }
  return target;
};
const server = http.createServer(async (req, res) => {
  res.on('error', () => {});
  let body = ''; for await (const chunk of req) body += chunk;
  const request = JSON.parse(body), settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  appendFileSync(callsPath, JSON.stringify(request) + '\n');
  appendFileSync(headersPath, JSON.stringify(req.headers) + '\n');
  if (settings.mutate) copyFileSync(settings.mutate[0], settings.mutate[1]);
  if (settings.delay) await new Promise(resolve => setTimeout(resolve, settings.delay));
  if (settings.drop) { req.socket.destroy(); return; }
  if (settings.http && (!settings.http_if || request.questions[settings.http_if])) { res.writeHead(settings.http); res.end(settings.body ?? 'private-error-sentinel'); return; }
  if (settings.raw !== undefined) { res.setHeader('content-type', 'application/json'); res.end(settings.raw); return; }
  const answers = {};
  for (const [id, q] of Object.entries(request.questions)) {
    if (q.type === 'choice') {
      const selected = settings[id] ?? 'fast';
      answers[id] = { type: 'choice', choice: selected, confidence: settings[`${id}_confidence`] ?? settings.confidence ?? 0.95,
        probabilities: settings[`${id}_probabilities`] ?? Object.fromEntries(Object.keys(q.criteria).map(k => [k, k === selected ? 1 : 0])) };
    } else if (q.type === 'score') {
      const score = settings[id] ?? 0;
      answers[id] = { type: 'score', score, confidence: 0.95,
        probabilities: Object.fromEntries(q.criteria.map((_, i) => [i, i === Math.round(score) ? 1 : 0])),
        legend: Object.fromEntries(q.criteria.map((s, i) => [i, s])) };
    } else {
      const rule = /^judgment_r([0-9]+)$/.exec(id);
      const selected = settings.rule ?? 'rule_3';
      answers[id] = { type: 'noul', noul: rule
        ? (settings.rule_probabilities?.[`rule_${rule[1]}`] ?? (`rule_${rule[1]}` === selected ? settings.rule_confidence ?? settings.confidence ?? 1 : 0))
        : settings[id] ?? 0 };
    }
  }
  const response = { model: 'jev-1.13.0', answers, usage: { input_tokens: 100, output_tokens: 20 } };
  if (settings.patch) merge(response, settings.patch);
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify(response));
});
server.listen(0, '127.0.0.1', () => writeFileSync(portPath, String(server.address().port)));
JS
printf '%s\n' '{}' > "$SETTINGS"
node "$TMP_ROOT/provider.mjs" "$SETTINGS" "$CALLS" "$TMP_ROOT/port" "$HEADERS" &
server=$!
for _ in {1..100}; do [ ! -f "$TMP_ROOT/port" ] || break; sleep .05; done
[ -f "$TMP_ROOT/port" ] || fail 'local provider did not start'
FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$TMP_ROOT/port")"
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT
# Build synthetic independent predicates for quota/privacy scenarios; the
# fact-scoped production schema and historical replay run below as CLI tests.
structure_rules() {
  local file=$1
  [ -f "$file" ] || return 0
  jq 'if type == "object" and (.rules | type) == "array" and (.judgments | type) != "object" then
    .judgments = (reduce range(0; (.rules | length)) as $i ({};
      .["r\($i+1)"] = {type:"noul", instructions:"Does task exhibit property \($i+1)?",
        criteria:{"true":"The named property is present.","false":"The named property is absent."}})) |
    .rules |= to_entries | .rules |= map(.value + {match: ({projects:["firstmate","vernant","pager","orion-private"]} + (.value.match // {}) + {all:["r\(.key+1)"]})})
    else . end' "$file" > "$TMP_ROOT/structured.json" 2>/dev/null && cp "$TMP_ROOT/structured.json" "$file"
}
# Attach the scaffold's typed location to a copy, leaving fixture prose intact.
bind_brief() {
  node -e 'const fs=require("fs"); const [source,target,location]=process.argv.slice(1); const text=fs.readFileSync(source,"utf8").split("\n").filter(s=>!s.startsWith("FIRSTMATE_DISPATCH: ")).join("\n"); fs.writeFileSync(target,"FIRSTMATE_DISPATCH: "+JSON.stringify({project_path:location})+"\n"+text)' "$1" "$TMP_ROOT/bound-brief.md" "$2"
}
mkdir -p "$HOME_DIR/projects/vernant" "$HOME_DIR/projects/pager" "$HOME_DIR/projects/orion-private"
run() {
  structure_rules "$RULES"
  local location="$HOME_DIR/projects/${1:-firstmate}"
  [ "${1:-firstmate}" != firstmate ] || location="$HOME_DIR"
  bind_brief "$BRIEF" "$location"
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=synthetic-key bash "$ROOT/bin/fm-dispatch-resolve.sh" "$TMP_ROOT/bound-brief.md" 2> "$TMP_ROOT/error") || fail "resolver failed: $(cat "$TMP_ROOT/error")"
}
count() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }

# B1 / reviewer D and E: there is no caller-typed project input to misspell.
# A recorded location must identify exactly one registered clone.
BINDING_RESOLVER=${FM_DISPATCH_RESOLVER_UNDER_TEST:-$ROOT/bin/fm-dispatch-resolve.sh}
binding_resolve() {
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=synthetic-key bash "$BINDING_RESOLVER" "$1" "${@:2}" 2> "$TMP_ROOT/error")
  CODE=$?
}
cp "$TMP_ROOT/base-rules.json" "$RULES"
structure_rules "$RULES"
for spelling in Vernant ' vernant'; do
  before=$(count)
  binding_resolve "$BRIEF" --project "$spelling"
  expect_code 2 "$CODE" 'the removed free-text project flag is rejected'
  assert_contains "$(cat "$TMP_ROOT/error")" 'unknown flag --project' 'the old input cannot reach routing'
  assert_equals "$before" "$(count)" 'a removed input sends nothing'
done
before=$(count)
binding_resolve "$BRIEF"
assert_contains "$OUT" 'reason: brief is missing FIRSTMATE_DISPATCH project_path' 'a missing typed field fails closed'
assert_equals "$before" "$(count)" 'a missing field sends nothing'
for fence in '```json' ''; do
  { cat "$BRIEF"; printf '\n%s\n' "$fence"; python3 "$ROOT/bin/fm-dispatch-project.py" scaffold "$HOME_DIR" vernant; printf '%s\n' "$fence"; } > "$TMP_ROOT/quoted-binding.md"
  binding_resolve "$TMP_ROOT/quoted-binding.md"
  assert_contains "$OUT" 'reason: brief is missing FIRSTMATE_DISPATCH project_path' 'a task example cannot substitute for the metadata header'
  assert_not_contains "$OUT" '  profile:' 'task prose cannot establish project identity'
  assert_equals "$before" "$(count)" 'a missing header with a quoted record sends nothing'
done
mkdir -p "$TMP_ROOT/outside-clone"
ln -s "$TMP_ROOT/outside-clone" "$TMP_ROOT/vernant-alias"
for location in "$TMP_ROOT/outside-clone" "$TMP_ROOT/vernant-alias"; do
  bind_brief "$BRIEF" "$location"
  binding_resolve "$TMP_ROOT/bound-brief.md"
  assert_contains "$OUT" 'reason: brief project_path must resolve to exactly one registered project clone' 'an unrelated or redirected alias is not project identity'
  assert_not_contains "$OUT" '  profile:' 'an invalid location never clears a profile'
  assert_equals "$before" "$(count)" 'an invalid location sends nothing'
done
printf '%s\n' '- missing-clone - Registered but absent' >> "$HOME_DIR/data/projects.md"
bind_brief "$BRIEF" "$HOME_DIR/projects/missing-clone"
binding_resolve "$TMP_ROOT/bound-brief.md"
assert_contains "$OUT" 'reason: brief project_path has no existing project clone' 'registration cannot substitute for an existing clone'
assert_equals "$before" "$(count)" 'a missing clone sends nothing'
jq '.rules[0].match.projects=["unregistered"]' "$RULES" > "$TMP_ROOT/bad-project.json"
cp "$RULES" "$TMP_ROOT/good-project.json"
cp "$TMP_ROOT/bad-project.json" "$RULES"
bind_brief "$BRIEF" "$HOME_DIR/projects/vernant"
binding_resolve "$TMP_ROOT/bound-brief.md"
expect_code 2 "$CODE" 'config cannot name an unregistered project'
assert_contains "$(cat "$TMP_ROOT/error")" 'match.projects contains an unregistered project id' 'config load names the invalid positive selection'
assert_equals "$before" "$(count)" 'invalid project configuration sends nothing'
cp "$TMP_ROOT/good-project.json" "$RULES"
jq '.rules[1].match.projects=["vernant"] | .rules[2].match.projects=["firstmate","pager","orion-private"]' "$RULES" > "$TMP_ROOT/positive-projects.json"
cp "$TMP_ROOT/positive-projects.json" "$RULES"
printf '%s\n' '{"rule_probabilities":{"rule_2":1,"rule_3":1}}' > "$SETTINGS"
FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-brief.sh" clone-bound vernant --mode direct-PR > "$TMP_ROOT/scaffold.out" \
  || fail 'Vernant scaffold did not record its clone location'
binding_resolve "$HOME_DIR/data/clone-bound/brief.md"
assert_contains "$OUT" 'rule: rule_2' 'a scaffolded Vernant clone reaches only positively applicable rules'
assert_not_contains "$OUT" 'rule_3=' 'a Vernant clone cannot reach the non-Vernant runner-up'
assert_not_contains "$(cat "$CALLS")" 'project_path' 'the clone binding never reaches the provider'
assert_not_contains "$(cat "$CALLS")" "$HOME_DIR" 'the absolute clone path never reaches the provider'
pass 'B1 removes free-text project input and rejects missing, unrelated, redirected and absent clone bindings'
[ "${FM_DISPATCH_BINDING_ONLY:-0}" != 1 ] || exit 0
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{}' > "$SETTINGS"

# Reproduce the former default preference: a positive pooled sibling cannot be
# discarded just because Claude exposes a scalar and the pool does not.
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({reports:[{provider:"openai-codex",fetchedAt:Date.now(),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},limits:[{scope:{tier:"chat"},amount:{remainingFraction:.9}}]}]}))' "$POOL"
run
assert_contains "$OUT" "--model 'openai-codex/gpt-6.1-sol' --effort 'high'" 'higher native pool headroom can win over ranked Claude'
assert_contains "$OUT" 'quota_score=0.9' 'pool score is normalized from a usable native account'
assert_contains "$OUT" 'common=["headroom"]' 'unknown pool economics are not scored as zero'
assert_contains "$OUT" 'weights={"headroom":0.6,"spend":0.3}' 'only headroom and spendPriority carry weight'
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
pass 'common headroom and economic urgency are normalized before weighting'

# Proven exhaustion excludes the pool; the powerful rule remains high even
# when Jev suggests fast and low effort.
printf '%s\n' '{"reports":[{"provider":"openai-codex","fetchedAt":9999999999999,"metadata":{"meterStates":{"chat":{"allowed":false,"limitReached":true}}}}]}' > "$POOL"
run
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'rule reasoning floor survives a low effort score'
pass 'quota veto preserves required reasoning class'

# A usable pool whose accounts publish no measurable headroom stays a disclosed
# uncertainty: it neither blocks a ranked sibling nor loses its sole-route clear.
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({reports:[{provider:"openai-codex",fetchedAt:Date.now(),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},limits:[]}]}))' "$POOL"
run
assert_contains "$OUT" 'status: clear' 'an unmeasured usable pool does not block ranking'
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'the measured sibling clears'
assert_contains "$OUT" 'eligible, unranked: OMP pooled Codex capacity usable' 'the unmeasured pool is disclosed as unranked'
jq '.rules[2].use=[.rules[2].use[1]]' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: clear' 'a sole usable pool clears without measured headroom'
assert_contains "$OUT" "--harness 'omp' --model 'openai-codex/gpt-6.1-sol' --effort 'high'" 'the sole usable pool is chosen'
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{"reports":[{"provider":"openai-codex","fetchedAt":9999999999999,"metadata":{"meterStates":{"chat":{"allowed":false,"limitReached":true}}}}]}' > "$POOL"
pass 'an unmeasured usable pool remains disclosed uncertainty without blocking ranking'

# Without bun on PATH, node runs the same TypeScript adapter.
nobun_path() {
  local out='' d i=0 f
  local -a dirs
  IFS=: read -ra dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    if [ -e "$d/bun" ]; then
      i=$((i + 1))
      mkdir -p "$TMP_ROOT/nobun/$i"
      for f in "$d"/*; do
        case "${f##*/}" in bun|bunx) ;; *) ln -sf "$f" "$TMP_ROOT/nobun/$i/" ;; esac
      done
      d="$TMP_ROOT/nobun/$i"
    fi
    out="$out${out:+:}$d"
  done
  printf '%s' "$out"
}
NOBUN_PATH=$(nobun_path)
structure_rules "$RULES"
OUT=$(PATH="$FAKEBIN:$NOBUN_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=synthetic-key bash -c 'command -v bun >/dev/null && exit 3; exec bash "$0" "$@"' "$ROOT/bin/fm-dispatch-resolve.sh" "$TMP_ROOT/bound-brief.md" 2> "$TMP_ROOT/error") \
  || fail "resolver without bun failed: $(cat "$TMP_ROOT/error")"
assert_contains "$OUT" 'status: clear' 'node resolves when bun is absent'
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'node applies the same policy'
pass 'the resolver runs its adapter with node when bun is absent'

# Executable T6 acceptance, including the 136-record offline structural replay.
node --experimental-strip-types --no-warnings --test "$ROOT/tests/fm-dispatch-level5.test.ts" > "$TMP_ROOT/dispatch-level5.out" 2>&1 \
  || fail "dispatch facts/replay failed: $(cat "$TMP_ROOT/dispatch-level5.out")"
pass 'T6 repository/kind facts, Q7 structural replay and Q9 capability boundaries'

# The vendored upstream Level 5 tests run unchanged.
JEV_BACKEND=mock node --experimental-strip-types --no-warnings --test "$ROOT/bin/ten-levels/tests/level05.test.ts" > "$TMP_ROOT/level05.out" 2>&1 \
  || fail "vendored upstream Level 5 tests failed: $(tail -20 "$TMP_ROOT/level05.out")"
pass 'vendored upstream Level 5 tests pass unchanged'

# The CLI regressions below cover deterministic repository/kind eligibility.
last_request() { node -e 'const fs=require("fs");console.log(fs.readFileSync(process.argv[1],"utf8").trim().split("\n").at(-1))' "$CALLS"; }
# T6(a): contradictory semantic answers cannot override repository facts.
jq '.rules[1].match={projects:["vernant"],kind:"ship"} | .rules[2].match={projects:["firstmate","pager","orion-private"],kind:"ship"}' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule":"rule_3","rule_probabilities":{"rule_2":1,"rule_3":1}}' > "$SETTINGS"
run vernant
assert_contains "$OUT" 'rule: rule_2' 'Vernant ship resolves its eligible rule despite a contradictory non-Vernant answer'
assert_not_contains "$(last_request)" 'judgment_r3' 'ineligible semantic predicates never reach the provider'
assert_not_contains "$OUT" 'rule_3=' 'ineligible rules cannot enter runner-up selection'
before=$(count)
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=synthetic-key bash "$ROOT/bin/fm-dispatch-resolve.sh" "$BRIEF" 2> "$TMP_ROOT/error") \
  || fail "resolver without project metadata failed: $(cat "$TMP_ROOT/error")"
assert_contains "$OUT" 'status: escalate' 'a Vernant ship brief without project metadata escalates'
assert_contains "$OUT" 'reason: brief is missing FIRSTMATE_DISPATCH project_path' 'the escalation names the missing project'
assert_not_contains "$OUT" '  profile:' 'a missing project never clears an unscoped rule or the default'
assert_equals "$before" "$(count)" 'a missing project sends nothing'
cp "$TMP_ROOT/base-rules.json" "$RULES"
for removed in human browser_agent deterministic_script; do
  printf '{"profile":"%s"}\n' "$removed" > "$SETTINGS"
  run
  assert_contains "$OUT" 'status: clear' 'removed workflow labels cannot force escalation'
done
printf '%s\n' '{}' > "$SETTINGS"
pass 'repository facts and removal of the workflow decision hold through the public resolver'

# The session launch policy filters the selected rule after the answer; it
# never removes the rule before judgment, so a weaker rule cannot replace it.
printf '%s\n' omp-or-tc > "$HOME_DIR/config/session-launch-policy"
printf '%s\n' '{"rule":"rule_2"}' > "$SETTINGS"
run
assert_contains "$(last_request)" '"judgment_r2"' 'a prohibited harness does not suppress the rule predicate judgment'
assert_contains "$OUT" 'rule: rule_2' 'the prohibited rule remains the selected rule'
assert_contains "$OUT" 'status: escalate' 'a prohibited selected rule escalates'
assert_contains "$OUT" 'reason: every rule_2 profile was filtered out: session launch policy prohibits this harness' 'the escalation names the session policy filter'
assert_contains "$OUT" "candidate: claude:opus" 'the filtered candidate is listed'
assert_not_contains "$OUT" '  profile:' 'no weaker rule or default profile is substituted'
jq '.rules=[.rules[1]] | .default={harness:"omp",model:"openai-codex/gpt-6-luna",effort:"low",provider:"codex"}' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule":"rule_1"}' > "$SETTINGS"
before=$(count); run
assert_equals "$((before + 1))" "$(count)" 'a sole prohibited rule still reaches judgment instead of a deterministic default'
assert_contains "$OUT" 'status: escalate' 'a prohibited sole rule cannot fall to the default class'
assert_not_contains "$OUT" 'gpt-6-luna' 'the weaker default is never chosen for the prohibited rule'
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{"rule":"rule_4"}' > "$SETTINGS"
cp "$POOL" "$TMP_ROOT/exhausted-pool.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({reports:[{provider:"openai-codex",fetchedAt:Date.now(),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},limits:[{scope:{tier:"chat"},amount:{remainingFraction:.5}}]}]}))' "$POOL"
run
assert_contains "$OUT" "--harness 'omp' --model 'openai-codex/gpt-6-luna'" 'an allowed candidate in the selected rule still resolves'
cp "$TMP_ROOT/exhausted-pool.json" "$POOL"
rm "$HOME_DIR/config/session-launch-policy"
pass 'session launch policy filters the selected rule after judgment and names an emptied rule'

# One paid judgment returns workflow, ambiguity, desktop, tier, and effort.
printf '%s\n' '# Task' "## Captain's intent" 'Make a trivial typo correction.' > "$BRIEF"
printf '%s\n' '{"rule":"rule_4","model":"fast"}' > "$SETTINGS"
before=$(count); run
assert_equals "$((before + 1))" "$(count)" 'independent questions share one request'
assert_contains "$OUT" "--model 'claude-haiku-5-5' --effort 'max'" 'fast task uses approved cheap candidate and Haiku max'
# A fast answer prefers cheap candidates only among those passing the quota
# gates: with Haiku exhausted and the Luna pool exhausted, the same rule's
# approved Sonnet with headroom is ranked, never an escalation or stand-in.
cp "$QUOTA" "$TMP_ROOT/pre-haiku-quota.json"
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:claude-haiku-5-5",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"},selection:{spendPriority:0.8}}]' \
  "$TMP_ROOT/pre-haiku-quota.json" > "$QUOTA"
jq '.rules[3].fallback=[{harness:"omp",model:"anthropic/claude-haiku-5-5",effort:"low"}]' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: clear' 'a vetoed cheap set does not escalate while an approved candidate has headroom'
assert_contains "$OUT" "--harness 'claude' --model 'claude-sonnet-5-5[1m]' --effort 'high'" 'the same rule ranks its other approved candidate'
assert_not_contains "$OUT" 'fallback:' 'no stand-in replaces an approved candidate with headroom'
assert_contains "$(grep 'candidate: claude:claude-haiku-5-5' <<<"$OUT")" 'not eligible: runway exhausted_now at model:claude-haiku-5-5' 'the vetoed cheap candidate stays visible'
# A usable cheap pool with unmeasured limits still passes the gates: it is the
# preferred sole usable candidate, not displaced by measured Sonnet.
cp "$POOL" "$TMP_ROOT/fast-exhausted-pool.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({reports:[{provider:"openai-codex",fetchedAt:Date.now(),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},limits:[]}]}))' "$POOL"
run
assert_contains "$OUT" 'status: clear' 'an unmeasured usable cheap pool clears a fast task'
assert_contains "$OUT" "--harness 'omp' --model 'openai-codex/gpt-6-luna' --effort 'low'" 'the usable cheap pool is preferred over measured Sonnet'
cp "$TMP_ROOT/fast-exhausted-pool.json" "$POOL"
# An established-short cheap candidate leaves the preferred set; the whole rule
# ranks, so the higher-ranked feasible Sonnet clears instead of an escalation.
jq '.providers[0].quotaSemantics.effectiveAvailability += [{scope:"model:claude-haiku-5-5",status:"known",effectivePercentRemaining:50,runway:{status:"projected_exhaustion",projectionConfidence:"established",usableRunwaySeconds:3600},selection:{spendPriority:0.8}}]' \
  "$TMP_ROOT/pre-haiku-quota.json" > "$QUOTA"
run
assert_contains "$OUT" 'status: clear' 'a short cheap candidate does not escalate a fast task while Sonnet has headroom'
assert_contains "$OUT" "--harness 'claude' --model 'claude-sonnet-5-5[1m]' --effort 'high'" 'the whole rule ranks the feasible Sonnet'
assert_contains "$(grep 'candidate: claude:claude-haiku-5-5' <<<"$OUT")" 'projectionConfidence=established' 'the short cheap candidate stays visible with its runway warning'
cp "$TMP_ROOT/pre-haiku-quota.json" "$QUOTA"
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{"rule":"rule_4","model":"powerful","effort":2,"profile":"reasoning_agent"}' > "$SETTINGS"
run
assert_contains "$OUT" "--model 'claude-sonnet-5-5[1m]' --effort 'high'" 'powerful response excludes cheap class and maps effort'
jq '.rules[3].use=[.rules[3].use[0]]' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule":"rule_4","model":"powerful"}' > "$SETTINGS"
run
assert_contains "$OUT" 'status: escalate' 'a cheap-only rule judged powerful escalates'
assert_contains "$OUT" 'reason: every rule_4 profile was filtered out: Level 5 model router chose powerful, which excludes Haiku/Luna' 'the escalation names the class filter'
assert_contains "$OUT" 'candidate: claude:claude-haiku-5-5' 'the class-filtered candidate is listed'
assert_not_contains "$OUT" 'no profiles configured' 'an emptied rule is not reported as unconfigured'
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'Level 5 tier and effort map to the approved model matrix'

printf '%s\n' '{"ambiguity":1,"needs_desktop":0.5}' > "$SETTINGS"; run
assert_contains "$OUT" 'status: clear' 'the exact ambiguity and desktop thresholds do not escalate'
for settings in '{"ambiguity":1.004}' '{"ambiguity":2}' '{"needs_desktop":1}'; do
  printf '%s\n' "$settings" > "$SETTINGS"; run
  assert_contains "$OUT" 'status: escalate' 'uncertain or capability-dependent handler escalates'
  assert_not_contains "$OUT" '  profile:' 'no permission or handler is invented'
done
printf '%s\n' '{"confidence":0.4}' > "$SETTINGS"; run
assert_contains "$OUT" 'status: clear' 'a removed upstream workflow confidence cannot force a human handler'
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
assert_contains "$OUT" 'status: clear' 'a known rule-floor shortfall falls through to default'
assert_contains "$OUT" 'note: rule rule_3 floor all_models below 90%: fall through to default' 'the fall-through is named'
assert_contains "$OUT" "--harness 'claude' --model 'claude-haiku-5-5' --effort 'max'" 'the default array resolves'
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'rule floor: a known shortfall falls through to default'

# Independent predicate support uses each rule's own floor, not Choice confidence.
jq '.rules[2].min_confidence=0.99 | .rules[3].min_confidence=0.1' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule_probabilities":{"rule_1":0,"rule_2":0,"rule_3":0.8,"rule_4":0.2}}' > "$SETTINGS"
run
assert_contains "$OUT" 'status: clear' 'a qualifying predicate runner-up resolves'
assert_contains "$OUT" 'fallback: rule_4' 'the selected rule floor is enforced'
assert_contains "$OUT" "--model 'claude-haiku-5-5'" 'the approved runner-up class resolves'
jq '.rules[2].min_confidence=0.99' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: ambiguous' 'no qualified predicate means no dispatch'
assert_not_contains "$OUT" '  profile:' 'a missed floor cannot pick a weaker profile'
cp "$TMP_ROOT/base-rules.json" "$RULES"
jq '.rules[2].min_confidence=0.99 | .rules[0].min_confidence=0.3 | .rules[1].min_confidence=0.3 | .rules[3].min_confidence=0.3 | .rules[1].use=.rules[0].use' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule_probabilities":{"rule_1":0.4,"rule_2":0.4,"rule_3":0.7,"rule_4":0.4}}' > "$SETTINGS"
run
assert_contains "$OUT" 'status: ambiguous' 'a third conflicting runner-up cannot hide behind two equivalent ties'
assert_contains "$OUT" 'runner-up tie' 'all tied outcomes are checked before dispatch'
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{"rule_probabilities":{"rule_1":0,"rule_2":0.9,"rule_3":0,"rule_4":0.9}}' > "$SETTINGS"
run
assert_contains "$OUT" 'conflicting rule support tie' 'distinct equally supported outcomes remain ambiguous'
printf '%s\n' '{"rule_probabilities":{"rule_1":0.7,"rule_2":0.7,"rule_3":0,"rule_4":0}}' > "$SETTINGS"
for order in '.' '.rules=[.rules[1],.rules[0],.rules[2],.rules[3]]'; do
  jq ".rules[0].min_confidence=0.8 | $order" "$TMP_ROOT/base-rules.json" > "$RULES"
  run
  assert_contains "$OUT" 'status: ambiguous' "a conflicting top-support tie stays ambiguous whatever the rule order: $order"
  assert_contains "$OUT" 'conflicting rule support tie' "a missed floor cannot hand a conflicting tie to the runner-up: $order"
  assert_not_contains "$OUT" 'fallback:' "no runner-up is taken around a conflicting tie: $order"
  assert_not_contains "$OUT" '  profile:' "a conflicting tie emits no profile: $order"
done
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'predicate support floors retain explicit runner-up policy'
printf '%s\n' '{}' > "$SETTINGS"

# Proven exhaustion of every candidate activates the selected rule's declared
# model-matrix stand-in.
cp "$QUOTA" "$TMP_ROOT/pre-exhaustion-quota.json"
jq '(.providers[0].quotaSemantics.effectiveAvailability[0]) |=
  (.effectivePercentRemaining=0 | .runway={status:"exhausted_now"})' "$QUOTA" > "$TMP_ROOT/exhausted-quota.json"
cp "$TMP_ROOT/exhausted-quota.json" "$QUOTA"
jq '.rules[2].fallback=[{harness:"omp",model:"anthropic/claude-haiku-5-5",effort:"low"}]' "$TMP_ROOT/base-rules.json" > "$RULES"
run
assert_contains "$OUT" 'status: clear' 'proven exhaustion takes the declared stand-in'
assert_contains "$OUT" 'fallback: primary capacity exhausted; declared model-matrix fallback' 'the stand-in is named'
assert_contains "$OUT" "--harness 'omp' --model 'anthropic/claude-haiku-5-5' --effort 'max' --dispatch-rule 'rule_3' --dispatch-route 'fast:low'" 'the stand-in carries its rule, route, and the Haiku max effort'
cp "$TMP_ROOT/base-rules.json" "$RULES"
run
assert_contains "$OUT" 'status: escalate' 'exhaustion without a declared stand-in escalates'
assert_contains "$OUT" 'reason: no rankable eligible candidate' 'the exhaustion reason is reported'
cp "$TMP_ROOT/pre-exhaustion-quota.json" "$QUOTA"
pass 'proven exhaustion activates only the declared model-matrix stand-in'

# A powerful verdict also filters declared stand-ins: the router judged the task
# too hard for Haiku/Luna, so exhausted Sonnet escalates instead of clearing Haiku.
cp "$QUOTA" "$TMP_ROOT/pre-powerful-quota.json"
cp "$POOL" "$TMP_ROOT/pre-powerful-pool.json"
cp "$TMP_ROOT/exhausted-quota.json" "$QUOTA"
printf '%s\n' '{"reports":[{"provider":"openai-codex","fetchedAt":9999999999999,"metadata":{"meterStates":{"chat":{"allowed":false,"limitReached":true}}}}]}' > "$POOL"
jq '.rules[3].fallback=[{harness:"omp",model:"anthropic/claude-haiku-5-5",effort:"low"}]' "$TMP_ROOT/base-rules.json" > "$RULES"
printf '%s\n' '{"rule":"rule_4","model":"powerful"}' > "$SETTINGS"
run
assert_contains "$OUT" 'status: escalate' 'a powerful verdict never takes a cheap declared stand-in'
assert_contains "$OUT" 'reason: no rankable eligible candidate' 'the exhaustion reason is kept'
assert_not_contains "$OUT" '  profile:' 'no stand-in profile is dispatched below the powerful class'
assert_not_contains "$OUT" 'fallback: primary capacity exhausted' 'no stand-in is announced'
printf '%s\n' '{"rule":"rule_4","model":"fast","effort":2}' > "$SETTINGS"
run
assert_contains "$OUT" "--harness 'omp' --model 'anthropic/claude-haiku-5-5' --effort 'max' --dispatch-rule 'rule_4' --dispatch-route 'fast:high'" 'a fast verdict takes the stand-in with the route effort and Haiku max'
cp "$TMP_ROOT/pre-powerful-quota.json" "$QUOTA"
cp "$TMP_ROOT/pre-powerful-pool.json" "$POOL"
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{}' > "$SETTINGS"
pass 'a powerful verdict filters declared stand-ins and every stand-in takes the route effort'

jq '(.providers[0].quotaSemantics.effectiveAvailability[0].runway) = {"status":"projected_exhaustion","projectionConfidence":"established","usableRunwaySeconds":60}' "$QUOTA" > "$TMP_ROOT/short.json"
cp "$TMP_ROOT/short.json" "$QUOTA"
run
assert_contains "$OUT" 'status: escalate' 'established runway shorter than horizon vetoes dispatch'
assert_not_contains "$OUT" '  profile:' 'short winner is not substituted with a weaker class'
pass 'task-horizon feasibility still vetoes the quota winner'

# ---- Ported regressions: credentials and privacy first ----------------------
# Shared state returns to the base fixtures; each group restores what it edits.
cp "$TMP_ROOT/base-quota.json" "$QUOTA"
cp "$TMP_ROOT/base-rules.json" "$RULES"
printf '%s\n' '{}' > "$SETTINGS"
printf '%s\n' '# Task' "## Captain's intent" 'Fix the off-by-one in the pager.' > "$BRIEF"
KEY='test-key-9f1c2d3e-never-on-argv'
BASE_PATH=$PATH
RESOLVER_BASH=bash
# resolve [NAME=value...] -- [args...]: CODE, OUT, ERR; no ambient key leaks in.
resolve() {
  local -a envs=()
  local config_file="$RULES" fixture_home="$HOME_DIR" value
  for value in "$@"; do case "$value" in FM_CONFIG_OVERRIDE=*) config_file="${value#*=}/crew-dispatch.json" ;; FM_HOME=*) fixture_home=${value#*=} ;; esac; done
  structure_rules "$config_file"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ $# -eq 0 ] || shift
  if [ $# -gt 0 ] && [ -f "$1" ]; then
    local location="$fixture_home/projects/${FIXTURE_PROJECT:-pager}"
    [ "${FIXTURE_PROJECT:-pager}" != firstmate ] || location="$fixture_home"
    bind_brief "$1" "$location"
    shift
    set -- "$TMP_ROOT/bound-brief.md" "$@"
  fi
  OUT=$(env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    ${envs[@]+"${envs[@]}"} "$RESOLVER_BASH" "$ROOT/bin/fm-dispatch-resolve.sh" "$@" 2> "$TMP_ROOT/error")
  CODE=$?
  ERR=$(cat "$TMP_ROOT/error")
}
keyed() { resolve TYPESAFE_API_KEY="$KEY" "$@"; }
last_auth() { tail -n 1 "$HEADERS" | jq -r '.authorization // "none"'; }
field() {  # <output> <name>: one name=value telemetry field
  awk -v key="$2" '{ for (i = 1; i <= NF; i++) { split($i, pair, "="); if (pair[1] == key) { print pair[2]; exit } } }' <<<"$1"
}
cand() { grep -F "  candidate: $1  " <<<"$OUT" | head -n 1; }  # <harness:model>
settings() { printf '%s\n' "$1" > "$SETTINGS"; }

# Spies record argv and whether the key is in the environment, then exec the
# real tool found before PATH was modified.
printf '%s' "$KEY" > "$TMP_ROOT/key"
SPYLOG="$TMP_ROOT/spylog"
spy() {  # <dir> <name> <real executable>
  mkdir -p "$1"
  cat > "$1/$2" <<SH
#!/bin/bash
{ printf 'argv:'; printf ' [%s]' "\$@"; printf '\n'
  if [ -n "\${TYPESAFE_API_KEY+x}\${TYPESAFE_API_KEY_PRIVATE+x}" ] || env | grep -qF -f '$TMP_ROOT/key'; then
    echo env:secret-present
  else echo env:clean; fi
} >> '$SPYLOG/$2'
exec '$3' "\$@"
SH
  chmod +x "$1/$2"
}
reset_spies() { rm -rf "$SPYLOG"; mkdir -p "$SPYLOG"; rm -f "$QUOTA_AXI_CALLS"; }
SPYBIN="$TMP_ROOT/spybin" SPYNODE="$TMP_ROOT/spynode"
for dir in "$SPYBIN" "$SPYNODE"; do
  spy "$dir" quota-axi "$FAKEBIN/quota-axi"
  spy "$dir" omp "$FAKEBIN/omp"
  spy "$dir" dirname "$(command -v dirname)"
done
RUNTIMES=(node)
if command -v bun >/dev/null 2>&1; then
  spy "$SPYBIN" bun "$(command -v bun)"
  RUNTIMES=(bun node)
fi
spy "$SPYNODE" node "$(command -v node)"

# Absent key: off, silent on stdout, no helper, no network, no quota read.
reset_spies; before=$(count)
resolve PATH="$SPYBIN:$FAKEBIN:$BASE_PATH" -- "$BRIEF"
expect_code 0 "$CODE" 'absent key exits 0'
assert_equals '' "$OUT" 'absent key prints nothing on stdout'
assert_contains "$ERR" 'dispatch-resolve: off (TYPESAFE_API_KEY absent from the environment and' 'absent key explains itself on stderr'
assert_equals 1 "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 'absent key prints exactly one stderr line'
assert_equals "$before" "$(count)" 'absent key makes no request'
assert_absent "$SPYLOG/bun" 'absent key launches no Level 5 helper'
assert_absent "$QUOTA_AXI_CALLS" 'absent key never reads quota-axi'
pass 'absent key is off: one stderr line, exit 0, no network call or quota read'

# Help and bare-filename startup scrub the key before their first child.
reset_spies; before=$(count)
keyed PATH="$SPYBIN:$FAKEBIN:$BASE_PATH" -- --help
expect_code 0 "$CODE" 'help exits 0 with an environment key'
assert_contains "$OUT" 'Usage:' 'help retains the public interface'
assert_contains "$(cat "$SPYLOG/dirname")" env:clean 'startup child environment is observed'
assert_not_contains "$(cat "$SPYLOG/dirname")" secret-present 'help scrubs the key before its first child'
assert_absent "$SPYLOG/bun" 'help launches no Level 5 helper'
assert_equals "$before" "$(count)" 'help makes no request'
reset_spies
OUT=$(cd "$ROOT/bin" && env -u TYPESAFE_API_KEY_PRIVATE PATH="$SPYBIN:$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="$KEY" bash fm-dispatch-resolve.sh --help)
assert_contains "$OUT" 'Usage:' 'a bare script filename resolves its shared library'
assert_contains "$(cat "$SPYLOG/dirname")" env:clean 'bare-filename startup child environment is observed'
assert_not_contains "$(cat "$SPYLOG/dirname")" secret-present 'bare-filename startup scrubs the key before children'
pass 'help and bare-filename startup isolate environment credentials'

# A .env key activates the tool, the environment wins, and config overrides apply.
printf '%s\n' '# local secrets' 'FMX_PAIRING_TOKEN=abc' "export TYPESAFE_API_KEY=\"$KEY\"" > "$HOME_DIR/.env"
resolve -- "$BRIEF"
expect_code 0 "$CODE" '.env key resolves'
assert_contains "$OUT" '  status: clear' '.env key produces a clear result'
assert_equals "Bearer $KEY" "$(last_auth)" '.env key reaches the provider as the bearer header'
resolve TYPESAFE_API_KEY=env-wins -- "$BRIEF"
assert_equals 'Bearer env-wins' "$(last_auth)" 'environment key wins over .env'
rm -f "$HOME_DIR/.env"
OVERRIDE_CONFIG="$TMP_ROOT/override-config"
mkdir -p "$OVERRIDE_CONFIG"
cp "$TMP_ROOT/base-rules.json" "$OVERRIDE_CONFIG/crew-dispatch.json"
structure_rules "$OVERRIDE_CONFIG/crew-dispatch.json"
jq '.judgments.r1.instructions = "Override-only judgment instruction?"' "$OVERRIDE_CONFIG/crew-dispatch.json" > "$TMP_ROOT/override.json"
cp "$TMP_ROOT/override.json" "$OVERRIDE_CONFIG/crew-dispatch.json"
keyed FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'FM_CONFIG_OVERRIDE resolves'
assert_contains "$(last_request)" 'Override-only judgment instruction?' 'FM_CONFIG_OVERRIDE uses its own structured rules'
cp "$TMP_ROOT/base-rules.json" "$OVERRIDE_CONFIG/crew-dispatch.json"
before=$(count)
OUT=$(env -u TYPESAFE_API_KEY_PRIVATE PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$OVERRIDE_CONFIG" \
  TYPESAFE_API_KEY="$KEY" bash "$ROOT/bin/fm-dispatch-resolve.sh" "$BRIEF" 2> "$TMP_ROOT/error")
CODE=$?
expect_code 2 "$CODE" 'a legacy rules file without judgments is a configuration error'
assert_contains "$(cat "$TMP_ROOT/error")" 'malformed rules file:' 'the legacy rules file is named as malformed'
assert_contains "$(cat "$TMP_ROOT/error")" 'judgments must be an object of single-judgment Nouls' 'the diagnostic names the missing judgments object'
assert_equals '' "$OUT" 'a legacy rules file prints no status'
assert_equals "$before" "$(count)" 'a legacy rules file sends nothing'
mkdir -p "$TMP_ROOT/brokenbun"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$TMP_ROOT/brokenbun/bun"
chmod +x "$TMP_ROOT/brokenbun/bun"
before=$(count)
keyed PATH="$TMP_ROOT/brokenbun:$FAKEBIN:$BASE_PATH" -- "$BRIEF"
expect_code 0 "$CODE" 'an adapter runtime failure is a structured result, not a configuration error'
assert_contains "$OUT" '  status: error' 'an adapter that cannot run reports status error'
assert_contains "$OUT" 'reason: Level 5 rules validation could not run' 'the error names the failed validation run'
assert_not_contains "$ERR" 'malformed rules file' 'a valid rules file is never blamed for an adapter runtime failure'
assert_equals "$before" "$(count)" 'an adapter runtime failure sends nothing'
pass 'TYPESAFE_API_KEY= in .env activates the tool; environment and config overrides work; legacy rules and adapter failures fail closed'

# The key reaches only the provider's bearer header: never argv, never a child
# environment, never the request. The request carries the project and task
# text and every rule criterion, never why, use, quota, approvals, or floors.
jq '.rules[2].why = "SECRET-WHY-TEXT strongest model" | .rules[1].approval = "captain" | .rules[3].min_confidence = 0.1' \
  "$TMP_ROOT/base-rules.json" > "$RULES"
[ "${#RUNTIMES[@]}" -eq 2 ] || echo 'skip: bun is not installed; node alone covers key handling'
for runtime in "${RUNTIMES[@]}"; do
  reset_spies
  if [ "$runtime" = bun ]; then
    keyed PATH="$SPYBIN:$FAKEBIN:$BASE_PATH" -- "$BRIEF"
  else
    keyed PATH="$SPYNODE:$FAKEBIN:$NOBUN_PATH" -- "$BRIEF"
  fi
  expect_code 0 "$CODE" "$runtime keyed resolution exits 0"
  assert_contains "$OUT" '  status: clear' "$runtime keyed resolution clears"
  assert_equals "Bearer $KEY" "$(last_auth)" "$runtime: the key arrives as the provider bearer header"
  assert_contains "$(cat "$SPYLOG/$runtime")" env:clean "$runtime helper environment is observed"
  assert_contains "$(cat "$SPYLOG/quota-axi")" env:clean 'quota-axi environment is observed'
  assert_contains "$(cat "$SPYLOG/omp")" env:clean 'omp pool environment is observed'
  spied=$(cat "$SPYLOG"/*)
  assert_not_contains "$spied" "$KEY" "$runtime: the key never appears on any child argv"
  assert_not_contains "$spied" secret-present "$runtime: the key is absent from every child environment"
  assert_not_contains "$OUT$ERR" "$KEY" "$runtime: the key is never printed"
  assert_not_contains "$(last_request)" "$KEY" "$runtime: the key never rides in the request body"
done
body=$(last_request)
assert_equals pager "$(jq -r .state.repository <<<"$body")" 'the authoritative project is explicit'
assert_contains "$(jq -r .state.task <<<"$body")" 'off-by-one in the pager' 'the task-specific state is retained'
assert_equals false "$(jq -r '.state | has("kind")' <<<"$body")" 'the request state holds no kind field'
assert_equals null "$(jq -r '.questions.profile // null' <<<"$body")" 'upstream workflow selection is removed'
assert_equals noul "$(jq -r '.questions.judgment_r4.type' <<<"$body")" 'each open property is an independent Noul'
for private in SECRET-WHY-TEXT spendPriority openai-codex/gpt-6.1-sol claude-haiku-5-5 '"approval"' min_confidence; do
  assert_not_contains "$body" "$private" "the request never carries $private"
done
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'key handling: bearer header only, never argv or child environments; the request carries task, project, and criteria only'

# ---- never-send list: a match or a bad list withholds the request -----------
NEVER_SEND="$HOME_DIR/config/dispatch-never-send"
PRIVATE_BRIEF="$TMP_ROOT/private-brief.md"
printf '%s\n' '# Task' "## Captain's intent" 'Fix the pager for the Acme-Ledger account 4417-2290.' '' '## Firstmate spec' '- Keep the change small.' > "$PRIVATE_BRIEF"
withheld_run() { rm -f "$QUOTA_AXI_CALLS"; WITHHELD_BEFORE=$(count); keyed "$@"; }
expect_withheld() {  # <label> <stderr fragment> [<value that must not print>...]
  local label=$1 fragment=$2 value
  shift 2
  expect_code 0 "$CODE" "$label exits 0"
  assert_equals '' "$OUT" "$label prints nothing on stdout, so firstmate uses its existing intake"
  assert_contains "$ERR" "dispatch-resolve: off ($fragment" "$label names why on stderr"
  assert_contains "$ERR" 'nothing sent)' "$label says nothing was sent"
  assert_equals 1 "$(grep -c '^dispatch-resolve:' <<<"$ERR")" "$label prints one dispatch-resolve line"
  assert_equals "$WITHHELD_BEFORE" "$(count)" "$label never reaches the provider"
  assert_absent "$QUOTA_AXI_CALLS" "$label never reads quota"
  assert_not_contains "$ERR" "$KEY" "$label never prints the API key"
  for value in "$@"; do
    assert_not_contains "$ERR" "$value" "$label never prints the listed value"
  done
}

printf '%s\n' '# private values' '' '   ' 'Unlisted-Value' > "$NEVER_SEND"
keyed -- "$PRIVATE_BRIEF"
assert_contains "$OUT" '  status: clear' 'a list with no match leaves resolution unchanged'
assert_contains "$(jq -r .state.task <<<"$(last_request)")" 'Acme-Ledger' 'a list with no match sends the task text'

printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NEVER_SEND"
withheld_run -- "$PRIVATE_BRIEF"
expect_withheld 'a case-insensitive literal match' "brief text matches $NEVER_SEND line 3" 'acme-ledger' 'Acme-Ledger' '4417-2290'

WRAPPED_BRIEF="$TMP_ROOT/wrapped-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for Example Client\nLtd before\tthe\xc2\xa0release.\n' > "$WRAPPED_BRIEF"
printf '%s\n' 'example  client ltd' > "$NEVER_SEND"
withheld_run -- "$WRAPPED_BRIEF"
expect_withheld 'a literal the brief wraps across lines' "brief text matches $NEVER_SEND line 1" 'example' 'Example'
printf '%s\n' 'before the release' > "$NEVER_SEND"
withheld_run -- "$WRAPPED_BRIEF"
expect_withheld 'a literal the brief spaces with a tab and a no-break space' "brief text matches $NEVER_SEND line 1" 'release'

printf '%s\n' 'orion-private' > "$NEVER_SEND"
FIXTURE_PROJECT=orion-private withheld_run -- "$BRIEF"
expect_withheld 'a project-name match' "brief text matches $NEVER_SEND line 1" 'orion-private'
printf '%s\n' 'Does task exhibit property' > "$NEVER_SEND"
withheld_run -- "$BRIEF"
expect_withheld 'a judgment-criterion match' "brief text matches $NEVER_SEND line 1" 'Does task exhibit property'
cp "$TMP_ROOT/base-rules.json" "$RULES"
structure_rules "$RULES"
jq '.judgments.acme_migration = .judgments.r1 | del(.judgments.r1) | .rules[0].match.all = ["acme_migration"]' "$RULES" > "$TMP_ROOT/judgment-id.json"
cp "$TMP_ROOT/judgment-id.json" "$RULES"
printf '%s\n' 'acme' > "$NEVER_SEND"
withheld_run -- "$BRIEF"
expect_withheld 'a match only in a judgment id' "brief text matches $NEVER_SEND line 1" 'acme'
cp "$TMP_ROOT/base-rules.json" "$RULES"
structure_rules "$RULES"

SECOND_HOME="$TMP_ROOT/secondmate-home"
mkdir -p "$SECOND_HOME/config" "$SECOND_HOME/data" "$SECOND_HOME/projects/pager"
cp "$HOME_DIR/data/projects.md" "$SECOND_HOME/data/projects.md"
printf '%s\n' 'acme-ledger' > "$NEVER_SEND"
# shellcheck disable=SC2016 # Expanded by the child shell
bash -c '. "$1" && propagate_inheritable_config "$2" "$3"' _ \
  "$ROOT/bin/fm-config-inherit-lib.sh" "$HOME_DIR/config" "$SECOND_HOME/config" >/dev/null 2>&1 \
  || fail 'inheritance into the secondmate home failed'
withheld_run FM_HOME="$SECOND_HOME" -- "$PRIVATE_BRIEF"
expect_withheld 'an inherited list in a secondmate home' "brief text matches $SECOND_HOME/config/dispatch-never-send line 1" 'acme-ledger' 'Acme-Ledger' '4417-2290'

rm -f "$NEVER_SEND"
mkdir "$NEVER_SEND"
withheld_run -- "$PRIVATE_BRIEF"
expect_withheld 'a directory at the list path' "$NEVER_SEND is not a readable regular file" 'Acme-Ledger' '4417-2290'
rmdir "$NEVER_SEND"
ln -s "$TMP_ROOT/missing-never-send" "$NEVER_SEND"
withheld_run -- "$PRIVATE_BRIEF"
expect_withheld 'a broken symlink at the list path' "$NEVER_SEND is not a readable regular file" 'Acme-Ledger' '4417-2290'
rm -f "$NEVER_SEND"

POLICY_TARGET_DIR="$TMP_ROOT/policy-target"
mkdir -p "$POLICY_TARGET_DIR"
printf 'Acme-Ledger\n' > "$POLICY_TARGET_DIR/policy"
ln -s "$POLICY_TARGET_DIR/policy" "$NEVER_SEND"
denied=$POLICY_TARGET_DIR
chmod 400 "$denied"
[ ! -x "$denied" ] || fail 'policy target fixture must deny ancestor search'
withheld_run -- "$PRIVATE_BRIEF"
chmod 700 "$denied"
denied=''
expect_withheld 'a policy link with an inaccessible target ancestor' "$NEVER_SEND is not a readable regular file" 'Acme-Ledger' '4417-2290'
withheld_run -- "$PRIVATE_BRIEF"
expect_withheld 'a readable policy link' "brief text matches $NEVER_SEND line 1" 'Acme-Ledger' '4417-2290'
printf 'Unlisted-Value\n' > "$POLICY_TARGET_DIR/policy"
keyed -- "$PRIVATE_BRIEF"
assert_contains "$OUT" '  status: clear' 'a readable nonmatching policy link permits normal dispatch'
assert_contains "$(jq -r .state.task <<<"$(last_request)")" 'Acme-Ledger' 'a readable policy target is checked without changing task text'
rm "$NEVER_SEND"
keyed -- "$PRIVATE_BRIEF"
assert_contains "$OUT" '  status: clear' 'no list resolves exactly as before'
assert_contains "$(jq -r .state.task <<<"$(last_request)")" 'Acme-Ledger' 'no list sends the task text as before'
pass 'never-send list withholds the request on a match or a bad list, and never prints the value'

# ---- opt-in protected brief regions ------------------------------------------
MARKED_BRIEF="$TMP_ROOT/marked-brief.md"
cat > "$MARKED_BRIEF" <<'MD'
# Task
## Captain's intent
Fix the public pager.
<!-- dispatch-never-send:start -->
### Synthetic customer details
SYNTHETIC-CUSTOMER-4417
# Internal heading that must not truncate the public task
<!-- dispatch-never-send:end -->
Keep the public pagination behavior.

## Firstmate spec
<!-- dispatch-never-send:start -->
SYNTHETIC-PROJECT-CONSTRAINT
<!-- dispatch-never-send:end -->
Use the existing pager.

# Setup
Ignore this boilerplate.
MD
withheld_run -- "$MARKED_BRIEF"
expect_withheld 'markers with no never-send list' 'never-send markers need the marked-sections directive' 'SYNTHETIC-CUSTOMER-4417'
printf '%s\n' 'Unrelated literal' > "$NEVER_SEND"
withheld_run -- "$MARKED_BRIEF"
expect_withheld 'markers with a literal-only list' 'never-send markers need the marked-sections directive' 'SYNTHETIC-CUSTOMER-4417'
NEAR_MISS_BRIEF="$TMP_ROOT/near-miss-brief.md"
printf '%s\n' 'Public task' '<!--dispatch-never-send:start-->' 'SYNTHETIC-NEAR-MISS' '<!--dispatch-never-send:end-->' > "$NEAR_MISS_BRIEF"
rm -f "$NEVER_SEND"
withheld_run -- "$NEAR_MISS_BRIEF"
expect_withheld 'unspaced markers with no never-send list' 'never-send markers need the marked-sections directive' 'SYNTHETIC-NEAR-MISS'

printf '%s\n' '# dispatch-never-send marked-sections' 'SYNTHETIC-CUSTOMER-4417' > "$NEVER_SEND"
keyed -- "$MARKED_BRIEF"
assert_contains "$OUT" '  status: clear' 'protected text is removed before literal matching'
body=$(last_request)
sent=$(jq -r .state.task <<<"$body")
assert_contains "$sent" 'Fix the public pager.' 'public intent before a protected region survives'
assert_contains "$sent" 'Keep the public pagination behavior.' 'a protected heading cannot truncate public intent after the region'
assert_contains "$sent" 'Use the existing pager.' 'public spec survives a second protected region'
for private_text in SYNTHETIC-CUSTOMER-4417 SYNTHETIC-PROJECT-CONSTRAINT 'Synthetic customer details' 'Internal heading' dispatch-never-send 'Ignore this boilerplate'; do
  assert_not_contains "$body" "$private_text" "request body excludes $private_text"
done

WHOLE_MARKED_BRIEF="$TMP_ROOT/whole-marked-brief.md"
cat > "$WHOLE_MARKED_BRIEF" <<'MD'
Public task before a protected region.
   <!-- dispatch-never-send:start -->
# Task
## Captain's intent
SYNTHETIC-HIDDEN-TASK
   <!-- dispatch-never-send:end -->
Public task after a protected region.
MD
keyed -- "$WHOLE_MARKED_BRIEF"
sent=$(jq -r .state.task <<<"$(last_request)")
assert_contains "$sent" 'Public task before' 'whole-brief fallback uses sanitized text before the region'
assert_contains "$sent" 'Public task after' 'whole-brief fallback uses sanitized text after the region'
assert_not_contains "$(last_request)" 'SYNTHETIC-HIDDEN-TASK' 'whole-brief fallback never rereads protected text'

FENCED_MARKED_BRIEF="$TMP_ROOT/fenced-marked-brief.md"
printf '%s\n' 'Public fenced example:' '```' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-FENCED-SECRET' '<!-- dispatch-never-send:end -->' 'public code' '```' > "$FENCED_MARKED_BRIEF"
keyed -- "$FENCED_MARKED_BRIEF"
assert_contains "$(jq -r .state.task <<<"$(last_request)")" 'public code' 'public fenced code survives'
assert_not_contains "$(last_request)" 'SYNTHETIC-FENCED-SECRET' 'markers protect text inside code fences'

# A literal outside a removed region still stops the entire request.
printf '%s\n' '# dispatch-never-send marked-sections' 'public pagination' > "$NEVER_SEND"
withheld_run -- "$MARKED_BRIEF"
expect_withheld 'literal protection after section stripping' "brief text matches $NEVER_SEND line 2" 'public pagination'

printf '%s\n' '# dispatch-never-send marked-sections' > "$NEVER_SEND"
BAD_MARKED_BRIEF="$TMP_ROOT/bad-marked-brief.md"
for malformed in unclosed orphan nested inline typo unspaced recased; do
  case "$malformed" in
    unclosed) printf '%s\n' 'Public task' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-BAD-SECRET' > "$BAD_MARKED_BRIEF" ;;
    orphan) printf '%s\n' 'SYNTHETIC-BAD-SECRET' '<!-- dispatch-never-send:end -->' > "$BAD_MARKED_BRIEF" ;;
    nested) printf '%s\n' '<!-- dispatch-never-send:start -->' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-BAD-SECRET' '<!-- dispatch-never-send:end -->' '<!-- dispatch-never-send:end -->' > "$BAD_MARKED_BRIEF" ;;
    inline) printf '%s\n' 'Public task <!-- dispatch-never-send:start --> SYNTHETIC-BAD-SECRET' > "$BAD_MARKED_BRIEF" ;;
    typo) printf '%s\n' '<!-- dispatch-never-send:star -->' 'SYNTHETIC-BAD-SECRET' > "$BAD_MARKED_BRIEF" ;;
    unspaced) printf '%s\n' 'Public task' '<!--dispatch-never-send:start-->' 'SYNTHETIC-BAD-SECRET' '<!--dispatch-never-send:end-->' > "$BAD_MARKED_BRIEF" ;;
    recased) printf '%s\n' 'Public task' '<!-- Dispatch-Never-Send:start -->' 'SYNTHETIC-BAD-SECRET' '<!-- Dispatch-Never-Send:end -->' > "$BAD_MARKED_BRIEF" ;;
  esac
  withheld_run -- "$BAD_MARKED_BRIEF"
  expect_withheld "$malformed markers" 'invalid never-send markers or unreadable brief' 'SYNTHETIC-BAD-SECRET'
done

for directive in '# dispatch-never-send project: pager' '# dispatch-never-send marked-section' '#dispatch-never-send marked-sections' '# Dispatch-Never-Send marked-sections'; do
  printf '%s\n' 'Ordinary comment' "$directive" > "$NEVER_SEND"
  for directive_brief in "$BRIEF" "$MARKED_BRIEF"; do
    withheld_run -- "$directive_brief"
    expect_withheld 'an invalid privacy directive' "invalid privacy directive in $NEVER_SEND line 2" 'SYNTHETIC-CUSTOMER-4417'
  done
done
rm -f "$NEVER_SEND"
pass 'opt-in marked sections protect outgoing bodies and markers never send without the exact opt-in'

# API error bodies may echo an authorization header or private request state.
# They are never diagnostics, even when the resolver keeps intake moving.
jq -n --arg body "$KEY private-brief-marker-4417" '{http: 401, body: $body}' > "$SETTINGS"
rm -f "$QUOTA_AXI_CALLS"
keyed -- "$BRIEF"
expect_code 0 "$CODE" 'sensitive API error exits 0'
assert_contains "$OUT" '  status: error' 'an HTTP rejection is an error outcome'
assert_contains "$OUT" '  reason: Level 5 API request failed' 'the API failure is named'
assert_contains "$ERR" 'TypeSafe HTTP 401' 'the HTTP status remains actionable'
assert_not_contains "$OUT$ERR" "$KEY" 'a raw HTTP error cannot expose the API key'
assert_not_contains "$OUT$ERR" 'private-brief-marker-4417' 'a raw HTTP error body is never echoed'
assert_not_contains "$OUT$ERR" 'off-by-one in the pager' 'an HTTP error never echoes request text'
assert_equals null "$(field "$OUT" api_ms)" 'a failed call has unknown API time'
assert_equals null "$(field "$OUT" quota_ms)" 'unattempted quota is unknown, not zero'
assert_equals null "$(field "$OUT" jev_cost_usd)" 'an unvalidated response has no invented cost'
assert_absent "$QUOTA_AXI_CALLS" 'an HTTP error does not read quota'
settings '{}'
pass 'error diagnostics omit sensitive API bodies without blocking intake'

# ---- telemetry ---------------------------------------------------------------
# API, quota, and local time are separate, at millisecond precision, on stock
# Bash. A claude-only rule set keeps the pool reader (which needs the real
# clock) out of the run, so a fake whole-second `date` proves the coarse
# fallback is not what answered when EPOCHREALTIME is absent.
CLOCKBIN="$TMP_ROOT/clockbin"
mkdir -p "$CLOCKBIN"
printf '%s\n' '#!/bin/bash' "printf '1\\n'" > "$CLOCKBIN/date"
chmod +x "$CLOCKBIN/date"
jq '.rules = [.rules[0]]' "$TMP_ROOT/base-rules.json" > "$RULES"
settings '{"rule":"rule_1","delay":120}'
rm -f "$QUOTA_AXI_CALLS"
RESOLVER_BASH=/bin/bash
keyed PATH="$CLOCKBIN:$FAKEBIN:$BASE_PATH" FAKE_QUOTA_DELAY=0.24 -- "$BRIEF"
RESOLVER_BASH=bash
expect_code 0 "$CODE" 'timed resolver exits 0 under /bin/bash'
assert_contains "$OUT" '  status: clear' 'timed resolver clears'
api_ms=$(field "$OUT" api_ms) quota_ms=$(field "$OUT" quota_ms) local_ms=$(field "$OUT" local_ms) total_ms=$(field "$OUT" total_ms)
case "$api_ms:$quota_ms:$local_ms:$total_ms" in
  *[!0-9:]*|:*|*::*|*:) fail "timings must be integer milliseconds: $OUT" ;;
esac
[ "$api_ms" -ge 120 ] || fail "API delay lost millisecond precision: $api_ms"
[ "$quota_ms" -ge 240 ] || fail "quota delay lost millisecond precision: $quota_ms"
assert_equals "$total_ms" "$(( api_ms + quota_ms + local_ms ))" 'stages account for total time exactly'
assert_contains "$OUT" "latency_ms: $api_ms" 'legacy latency is the API time'
assert_contains "$OUT" '  model: jev-1.13.0' 'the returned model id remains observable'
assert_equals 100 "$(field "$OUT" input_tokens)" 'usage reports input tokens'
assert_equals 20 "$(field "$OUT" output_tokens)" 'usage reports output tokens'
cost=$(field "$OUT" jev_cost_usd)
jq -ne --argjson cost "$cost" '$cost == (100 * 0.042 / 1000000)' >/dev/null || fail "cost must charge input tokens only: $cost"
assert_equals 0.042 "$(field "$OUT" jev_input_usd_per_million)" 'the estimate exposes its catalog rate'
assert_equals jev-1.13.0 "$(field "$OUT" returned_model)" 'usage names the returned Jev version'
assert_not_contains "$OUT$ERR" "$KEY" 'timing and cost output never expose the key'
assert_not_contains "$OUT$ERR" 'off-by-one in the pager' 'timing and cost output never expose brief text'
assert_equals $'--version\n--json' "$(cat "$QUOTA_AXI_CALLS")" 'timing preserves compatibility checking and one quota snapshot'
pass 'stock Bash resolver separates API, quota, local and total timing at millisecond precision, with input-only Jev cost'

# Where a Bash with EPOCHREALTIME is installed, the timer starts no Perl.
FAST_BASH=''
for candidate in $(type -ap bash) /opt/homebrew/bin/bash /usr/local/bin/bash; do
  # shellcheck disable=SC2016 # Expanded by the candidate shell
  if [ -x "$candidate" ] && "$candidate" -c '[ -n "${EPOCHREALTIME:-}" ]' 2>/dev/null; then FAST_BASH=$candidate; break; fi
done
if [ -n "$FAST_BASH" ]; then
  PERLBIN="$TMP_ROOT/perlbin"
  mkdir -p "$PERLBIN"
  # Only the epoch-clock helper is recorded; other Perl uses pass through.
  cat > "$PERLBIN/perl" <<SH
#!/bin/bash
case " \$* " in *Time::HiRes*) printf 'perl\n' >> '$TMP_ROOT/perl.calls'; exit 1 ;; esac
exec '$(command -v perl)' "\$@"
SH
  chmod +x "$PERLBIN/perl"
  settings '{"rule":"rule_1"}'
  RESOLVER_BASH=$FAST_BASH
  keyed PATH="$PERLBIN:$FAKEBIN:$BASE_PATH" -- "$BRIEF"
  RESOLVER_BASH=bash
  assert_contains "$OUT" '  status: clear' 'EPOCHREALTIME resolver clears'
  case "$(field "$OUT" total_ms)" in ''|*[!0-9]*) fail "EPOCHREALTIME total must be integer milliseconds: $OUT" ;; esac
  assert_absent "$TMP_ROOT/perl.calls" 'EPOCHREALTIME timing starts no Perl process'
  pass 'EPOCHREALTIME timing stays on the builtin fast path'
else
  printf 'skip: no bash with EPOCHREALTIME is installed\n'
fi
cp "$TMP_ROOT/base-rules.json" "$RULES"

# Missing usage is an invalid response: unknown, never fabricated as zero.
settings '{"patch":{"usage":null}}'
keyed -- "$BRIEF"
expect_code 0 "$CODE" 'missing usage exits 0'
assert_contains "$OUT" '  reason: Level 5 API request failed' 'missing usage fails response validation'
assert_contains "$ERR" 'invalid provider answer contract' 'missing usage is named as a contract failure'
for name in api_ms input_tokens output_tokens jev_cost_usd returned_model; do
  assert_equals null "$(field "$OUT" "$name")" "missing usage leaves $name unknown"
done
# A quota failure still reports the paid call while marking only the snapshot failed.
settings '{}'
keyed FAKE_QUOTA_FAIL=1 FAKE_QUOTA_DELAY=0.12 -- "$BRIEF"
expect_code 0 "$CODE" 'quota failure with telemetry exits 0'
assert_contains "$OUT" '  reason: quota-axi --json failed' 'quota failure preserves its reason'
assert_equals "$cost" "$(field "$OUT" jev_cost_usd)" 'quota failure retains API cost'
assert_equals jev-1.13.0 "$(field "$OUT" returned_model)" 'quota failure attributes paid usage to the returned Jev version'
case "$(field "$OUT" api_ms)" in ''|null|*[!0-9]*) fail "quota failure lost the API time: $OUT" ;; esac
[ "$(field "$OUT" quota_ms)" -ge 120 ] || fail 'failed quota duration was lost'
pass 'unavailable usage is unknown and a failed quota snapshot retains API cost'

jq -n --arg model "jev-1.13.0"$'\n'"$KEY private-brief-marker-4417" '{patch: {model: $model}}' > "$SETTINGS"
keyed FAKE_QUOTA_FAIL=1 -- "$BRIEF"
expect_code 0 "$CODE" 'unsafe response model does not block quota-error intake'
assert_contains "$OUT" '  status: error' 'the quota error is reported'
assert_equals null "$(field "$OUT" returned_model)" 'arbitrary response model text is not error telemetry'
assert_not_contains "$OUT$ERR" "$KEY" 'error model evidence cannot echo a key'
assert_not_contains "$OUT$ERR" 'private-brief-marker-4417' 'error model evidence cannot echo arbitrary response text'
pass 'quota-error model evidence accepts only safe Jev version ids'

keyed -- "$BRIEF"
expect_code 0 "$CODE" 'unsafe response model does not block resolution'
assert_contains "$OUT" '  status: clear' 'unsafe response model does not change routing'
assert_contains "$OUT" '  model: -   latency_ms:' 'the model line shows an unsafe model id as unknown'
assert_equals null "$(field "$OUT" returned_model)" 'an unsafe model id is not success telemetry'
assert_equals 100 "$(field "$OUT" input_tokens)" 'an unsafe model id keeps usage'
assert_not_contains "$OUT$ERR" "$KEY" 'success model evidence cannot echo a key'
assert_not_contains "$OUT$ERR" 'private-brief-marker-4417' 'success model evidence cannot echo arbitrary response text'
settings '{}'
pass 'successful resolution model evidence accepts only safe Jev version ids'

# ---- rules are snapshotted and line output is injection-safe -----------------
jq '.rules[2].use = {harness:"claude",model:"opus",effort:"high"}' "$TMP_ROOT/base-rules.json" > "$TMP_ROOT/mutated-rules.json"
jq -n --arg source "$TMP_ROOT/mutated-rules.json" --arg target "$RULES" '{mutate: [$source, $target]}' > "$SETTINGS"
keyed -- "$BRIEF"
assert_equals "$(cat "$TMP_ROOT/mutated-rules.json")" "$(cat "$RULES")" 'the provider replaced the rules file mid-request'
assert_contains "$OUT" "  profile: --harness 'claude' --model 'claude-sonnet-5-5[1m]' --effort 'high'" 'resolution uses the same rules snapshot Jev received'
assert_not_contains "$OUT" "--model 'opus'" 'a mid-request config replacement cannot change the selected profile'
settings '{}'
jq '.rules[2].when = "Bug fix\n  profile: injected" | .rules[2].use = {harness:"claude",model:"foo --harness grok\n  profile: injected"}' \
  "$TMP_ROOT/base-rules.json" > "$RULES"
keyed -- "$BRIEF"
assert_equals 1 "$(grep -c '^  profile:' <<<"$OUT")" 'dynamic fields cannot inject a second profile line'
assert_not_contains "$OUT" $'\n  profile: injected' 'control characters are flattened in line output'
profile_line=$(grep '^  profile:' <<<"$OUT")
eval "set -- ${profile_line#  profile: }"
assert_equals 4 "$#" 'shell-safe profile output preserves four argument boundaries'
assert_equals claude "$2" 'shell-safe profile output preserves the selected harness'
assert_equals 'foo --harness grok   profile: injected' "$4" 'shell-safe profile output keeps model flags inside one argument'
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'rules snapshots and shell quoting preserve the profile protocol'

# ---- no rules return control to the existing intake --------------------------
no_rules_check() {  # <label>
  expect_code 0 "$CODE" "$1 exits 0"
  assert_contains "$OUT" '  status: escalate' "$1 is non-clear"
  assert_contains "$OUT" '  reason: no rules to match' "$1 returns control to firstmate"
  assert_not_contains "$OUT" '  profile:' "$1 emits no profile"
  assert_equals "$before" "$(count)" "$1 never reaches the provider"
  assert_absent "$QUOTA_AXI_CALLS" "$1 never reads quota"
}
rm -f "$RULES" "$QUOTA_AXI_CALLS"; before=$(count)
keyed -- "$BRIEF"
no_rules_check 'an absent rules file'
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"}]}' > "$RULES"
keyed -- "$BRIEF"
no_rules_check 'a default-only rules file'
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus"}]}' > "$RULES"
keyed -- "$BRIEF"
no_rules_check 'an empty rules array'
rm -f "$RULES"
ln -s "$TMP_ROOT/missing-rules-target.json" "$RULES"
keyed -- "$BRIEF"
expect_code 2 "$CODE" 'a broken rules symlink exits 2'
assert_contains "$ERR" "rules file not readable: $RULES" 'a broken rules symlink is actionable'
assert_equals "$before" "$(count)" 'a broken rules symlink never reaches the provider'
rm -f "$RULES"

# Agy, Gemini, and the documented example configuration resolve.
WIDE_QUOTA="$TMP_ROOT/wide-quota.json"
cat > "$WIDE_QUOTA" <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":5,"providers":[
 {"provider":"claude","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":79,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.4627}},
  {"scope":"model:fable","status":"known","effectivePercentRemaining":15,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.79}}]}},
 {"provider":"codex","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":31,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.1649}}]}},
 {"provider":"cursor","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.7597}}]}},
 {"provider":"agy","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":64,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.4}}]}},
 {"provider":"google","state":{"status":"fresh"},"quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":72,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.3}}]}},
 {"provider":"kimi","state":{"status":"unknown"},"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}
]}
JSON
cp "$WIDE_QUOTA" "$QUOTA"
settings '{"rule":"rule_1"}'
printf '%s\n' '{"rules":[{"when":"Agy work.","use":{"harness":"agy"}}]}' > "$RULES"
keyed -- "$BRIEF"
assert_contains "$(cand agy:-)" 'provider=agy  scope=all_models  remaining=64%  spendPriority=0.4  runway=through_reset' 'agy uses its resolver-only authoritative quota provider'
assert_contains "$OUT" "  profile: --harness 'agy'" 'a provider-less agy rule resolves'
printf '%s\n' '{"rules":[{"when":"Gemini work.","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google"}}]}' > "$RULES"
keyed -- "$BRIEF"
assert_contains "$(cand gemini:gemini-3.8-flash-high)" 'provider=google  scope=all_models  remaining=72%  spendPriority=0.3  runway=through_reset' 'Gemini resolves through its explicit provider'
assert_contains "$OUT" "  profile: --harness 'gemini' --model 'gemini-3.8-flash-high'" 'Gemini is a typed verified dispatch harness'
cp "$ROOT/docs/examples/crew-dispatch.json" "$RULES"
cp "$ROOT/docs/examples/model-index.json" "$HOME_DIR/config/model-index.json"
mkdir -p "$TMP_ROOT/no-catalogs"
settings '{"rule":"default"}'
keyed FM_MODEL_CATALOG_DIR="$TMP_ROOT/no-catalogs" -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'the documented example passes opted-in resolution'
assert_contains "$(cand pi:anthropic/claude-sonnet-5-5)" 'provider=claude' 'the documented Pi default uses its declared Claude provider'
assert_not_contains "$ERR" 'malformed rules file' 'the documented example reaches resolution'
assert_not_contains "$ERR" 'warning: literal model' 'the documented example names roles, never literal ids'
assert_contains "$ERR" 'catalog unavailable' 'an unavailable chosen-model catalog is a notice, not a refusal'
rm "$HOME_DIR/config/model-index.json"
cp "$TMP_ROOT/base-rules.json" "$RULES"
cp "$TMP_ROOT/base-quota.json" "$QUOTA"
settings '{}'
pass 'no-rule fallback, Agy, Gemini, and documented configurations resolve'

# ---- ambiguous: fixed confidence floor ---------------------------------------
# A wider synthetic rule set with unmeasured, approval-gated, and floored rules.
WIDE_RULES="$TMP_ROOT/wide-rules.json"
cat > "$WIDE_RULES" <<'JSON'
{"rules":[
 {"when":"New feature work on the app.","floor":{"scope":"model:fable","min_percent":20,"provider":"claude"},
  "use":{"harness":"claude","model":"fable","effort":"xhigh"},"why":"SECRET-WHY-TEXT feature work wants the strongest model"},
 {"when":"The task generates images.","use":[{"harness":"pi","model":"openai-codex/gpt-5.6-sol","provider":"codex"},
  {"harness":"codex","model":"gpt-5.6-sol","floor":{"scope":"all_models","min_percent":50}}]},
 {"when":"Genuinely very difficult design or planning work.","approval":"captain","use":{"harness":"claude","model":"fable","effort":"xhigh"}},
 {"when":"A simple bug fix with a stated root cause.","use":[{"harness":"claude","model":"sonnet","effort":"high"},
  {"harness":"cursor","model":"cursor-grok-4.6-medium"},{"harness":"kimi","model":"kimi-code/k3"}]}
],"default":[{"harness":"claude","model":"opus"},{"harness":"cursor","model":"cursor-grok-4.6-high"}]}
JSON
cp "$WIDE_RULES" "$RULES"
cp "$WIDE_QUOTA" "$QUOTA"
settings '{"rule":"rule_4","rule_confidence":0.55}'
keyed -- "$BRIEF"
expect_code 0 "$CODE" 'ambiguous exits 0'
assert_contains "$OUT" '  status: ambiguous' 'below the floor is ambiguous'
assert_contains "$OUT" '  reason: support 0.55 below floor 0.6' 'ambiguous names the floor'
assert_contains "$(cand claude:sonnet)" 'provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627  runway=projected_exhaustion  -> eligible' 'ambiguous preserves matched candidate evidence'
assert_contains "$(cand kimi:kimi-code/k3)" 'provider=kimi  -> eligible, unranked: provider kimi unmeasured (unknown): disclosed uncertainty' 'ambiguous preserves eligible unranked candidate evidence'
assert_not_contains "$OUT" '  profile:' 'ambiguous emits no profile line'
settings '{"rule":"rule_4","rule_confidence":0.6}'
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'confidence exactly at the fixed floor clears'
pass 'ambiguous: confidence below the fixed floor hands the decision back'
settings '{}'

# ---- the model sees only the task-specific brief sections --------------------
SCAFFOLD_BRIEF="$TMP_ROOT/scaffold-brief.md"
cat > "$SCAFFOLD_BRIEF" <<'MD'
# Task
## Captain's intent
Add a flag to the pager.

## Firstmate spec
Touch pager.sh only.
```sh
# Not a heading inside a fence
## Setup
```
### Out of scope
Anything else.

# Setup
BOILERPLATE-SETUP never push to the default branch.

## Captain intent authorized for --intent
BOILERPLATE-DUPLICATE
MD
sent_task() { jq -r .state.task <<<"$(last_request)"; }
keyed -- "$SCAFFOLD_BRIEF"
sent=$(sent_task)
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' "the captain's intent section is sent"
assert_contains "$sent" $'## Firstmate spec\nTouch pager.sh only.' 'the Firstmate spec section is sent'
assert_contains "$sent" $'# Not a heading inside a fence\n## Setup\n```\n### Out of scope\nAnything else.' 'fenced lines and subheadings stay inside the section'
assert_not_contains "$sent" 'BOILERPLATE' 'scaffold boilerplate after the task sections is not sent'
assert_not_contains "$sent" '# Task' 'the enclosing Task heading is not sent'
assert_not_contains "$sent" 'Brief kind:' 'a brief without a scout contract line gets no kind line'
SPEC_ONLY_BRIEF="$TMP_ROOT/spec-only-brief.md"
printf '%s\n' '# Task' '## Firstmate spec' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
keyed -- "$SPEC_ONLY_BRIEF"
assert_equals $'## Firstmate spec\nSpec text.' "$(sent_task)" 'one recognized section is enough'
printf '%s\n' '# Task' '## Firstmate spec   ' 'Spec text.' '## Rules' 'RULES-TEXT' > "$SPEC_ONLY_BRIEF"
keyed -- "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(sent_task)" 'a heading with trailing blanks is not a section, matching spawn validation'
printf '%s\n' 'Preamble.' '## Firstmate spec' 'Spec text.' > "$SPEC_ONLY_BRIEF"
keyed -- "$SPEC_ONLY_BRIEF"
assert_equals "$(cat "$SPEC_ONLY_BRIEF")" "$(sent_task)" 'a section outside the Task heading is not a task section'
KIND_BRIEF="$TMP_ROOT/kind-brief.md"
{ cat "$SCAFFOLD_BRIEF"; printf '%s\n' '# Definition of done' 'Delivery contract: mode=no-mistakes' 'Delivery contract: mode=direct-PR'; } > "$KIND_BRIEF"
keyed -- "$KIND_BRIEF"
sent=$(sent_task)
assert_contains "$sent" $'## Captain\'s intent\nAdd a flag to the pager.' 'a ship brief still sends its task sections'
assert_not_contains "$sent" 'Brief kind:' 'a ship brief gets no kind line'
assert_not_contains "$sent" 'mode=' "a ship brief's delivery mode is not sent"
awk '{ print } /^BOILERPLATE-SETUP/ { print "This is a SCOUT task: the deliverable is a written report, not a PR." }' "$SCAFFOLD_BRIEF" > "$KIND_BRIEF"
keyed -- "$KIND_BRIEF"
sent=$(sent_task)
assert_contains "$sent" $'Brief kind: scout (report only)\n\n## Captain\'s intent' "a scout brief's contract line names its kind"
assert_not_contains "$sent" 'This is a SCOUT task' 'the scout contract line itself is not sent'
# Promotion retains the scout body and appends the authoritative ship spec.
PROMOTED_BRIEF="$TMP_ROOT/promoted-brief.md"
{ cat "$KIND_BRIEF"; printf '\n%s\n%s\n' '# Current ship Firstmate spec' 'PROMOTED-SHIP-SPEC implement the accepted Vernant repair.'; } > "$PROMOTED_BRIEF"
jq '.rules=[.rules[0],.rules[1]] | .rules[0].match={projects:["vernant"],kind:"ship"} | .rules[1].match={projects:["vernant"],kind:"scout"}' "$TMP_ROOT/base-rules.json" > "$RULES"
settings '{"rule_probabilities":{"rule_1":1,"rule_2":1}}'
FIXTURE_PROJECT=vernant keyed -- "$PROMOTED_BRIEF"
assert_contains "$OUT" 'rule: rule_1' 'a promoted Vernant ship cannot select the retained scout rule'
assert_contains "$(sent_task)" 'PROMOTED-SHIP-SPEC implement the accepted Vernant repair.' 'the active ship specification reaches judgment'
assert_not_contains "$(sent_task)" 'Touch pager.sh only.' 'the obsolete scout specification is not sent'
assert_not_contains "$(sent_task)" 'Brief kind: scout' 'a promoted ship is not labeled as a scout'
awk '{ print } /^Touch pager.sh only./ { print "```md"; print "This is a SCOUT task: the deliverable is a written report, not a PR."; print "```" }' "$SCAFFOLD_BRIEF" > "$PROMOTED_BRIEF"
FIXTURE_PROJECT=vernant keyed -- "$PROMOTED_BRIEF"
assert_contains "$OUT" 'rule: rule_1' 'a quoted scout declaration does not demote a ship'
assert_not_contains "$(sent_task)" 'Brief kind: scout' 'a ship quoting the scout declaration is not labeled as a scout'
{ cat "$KIND_BRIEF"; printf '\n%s\n%s\n%s\n%s\n' '```md' '# Current ship Firstmate spec' 'QUOTED-SHIP-SPEC' '```'; } > "$PROMOTED_BRIEF"
FIXTURE_PROJECT=vernant keyed -- "$PROMOTED_BRIEF"
assert_contains "$OUT" 'rule: rule_2' 'a quoted ship heading does not promote a scout'
cp "$TMP_ROOT/base-rules.json" "$RULES"
settings '{}'
WHOLE_BRIEF="$TMP_ROOT/whole-brief.md"
printf '%s\n' '# Task' 'Fix the off-by-one in the pager: root cause is the <= on line 40.' > "$WHOLE_BRIEF"
keyed -- "$WHOLE_BRIEF"
assert_equals "$(cat "$WHOLE_BRIEF")" "$(sent_task)" 'a brief with neither heading is sent whole'
pass "only the brief's task sections and scout tag reach the model, with a whole-brief fallback"

# ---- rule floor: unverifiable evidence escalates -----------------------------
for floor in 'claude model:missing' 'grok all_models' 'codex all_models'; do
  jq --arg p "${floor% *}" --arg s "${floor#* }" '.rules[2].floor = {provider: $p, scope: $s, min_percent: 20}' "$TMP_ROOT/base-rules.json" > "$RULES"
  keyed -- "$BRIEF"
  assert_contains "$OUT" '  status: escalate' "an unverifiable ${floor% *} rule floor escalates"
  assert_contains "$OUT" "  reason: rule rule_3 floor ${floor% *}/${floor#* } is unverifiable" 'the unverifiable rule floor names its provider and scope'
  assert_not_contains "$OUT" '  profile:' 'an unverifiable rule floor never authorizes routing'
  assert_not_contains "$OUT" 'fall through to default' 'an unverifiable rule floor never falls through to default'
done
cp "$TMP_ROOT/base-rules.json" "$RULES"
pass 'rule floor: unavailable evidence, including the OMP pool, escalates rather than falling through'

# ---- declared provider and profile floor -------------------------------------
cp "$WIDE_RULES" "$RULES"
cp "$WIDE_QUOTA" "$QUOTA"
settings '{"rule":"rule_2"}'
keyed -- "$BRIEF"
assert_contains "$(cand pi:openai-codex/gpt-5.6-sol)" 'provider=codex  scope=all_models  remaining=31%' 'declared provider routes a Pi profile to the codex row'
codex_line=$(cand codex:gpt-5.6-sol)
assert_contains "$codex_line" 'provider=codex  scope=all_models  remaining=31%  spendPriority=-  runway=projected_exhaustion' 'a failed profile floor reports its row'
assert_contains "$codex_line" '-> not eligible: profile floor all_models below 50%' 'profile floor makes a candidate ineligible with its reason'
assert_contains "$OUT" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" 'the remaining eligible candidate wins'
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:gpt-5.6-sol","status":"known","effectivePercentRemaining":10,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-0.9}}
]' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
codex_line=$(cand codex:gpt-5.6-sol)
assert_contains "$codex_line" 'bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:10%/projected_exhaustion  -> not eligible: profile floor all_models below 50%' 'a failed profile floor reports its named row while retaining all bounds'
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:gpt-5.6-sol","status":"unknown","runway":{"status":"unknown"}}
])' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
codex_line=$(cand codex:gpt-5.6-sol)
assert_contains "$codex_line" 'bounds=all_models:31%/projected_exhaustion,model:gpt-5.6-sol:-%/unknown  -> not eligible: profile floor all_models below 50%' 'a known profile-floor shortfall wins over unrelated unknown model evidence'
cp "$WIDE_QUOTA" "$QUOTA"
jq '.rules[1].use[1].floor.scope = "model:missing"' "$WIDE_RULES" > "$RULES"
keyed -- "$BRIEF"
codex_line=$(cand codex:gpt-5.6-sol)
assert_contains "$codex_line" 'provider=codex  scope=model:missing  remaining=-%  spendPriority=-  runway=-' 'missing profile floor evidence is reported as unknown'
assert_contains "$codex_line" '-> eligible, unranked: profile floor model:missing is unverifiable: not rankable: disclosed uncertainty' 'a missing profile floor remains eligible but unranked'
assert_not_contains "$OUT" 'profile floor model:missing below' 'missing profile evidence is not described as a shortfall'
assert_contains "$OUT" "  profile: --harness 'pi' --model 'openai-codex/gpt-5.6-sol'" 'another candidate may clear without misrepresenting missing floor evidence'
cp "$WIDE_RULES" "$RULES"
pass 'declared provider and profile floor evidence are applied in code'

# ---- malformed ranking evidence is never ordered -----------------------------
settings '{"rule":"rule_4"}'
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability[0].selection.spendPriority) = "high"' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
cursor_line=$(cand cursor:cursor-grok-4.6-medium)
assert_contains "$cursor_line" 'provider=cursor  scope=all_models  remaining=91%  spendPriority=-  runway=through_reset' 'a nonnumeric spendPriority is not reported as a number'
assert_contains "$cursor_line" 'quota_score=-' 'a nonnumeric spendPriority receives no quota score'
assert_contains "$cursor_line" '-> eligible, unranked: spendPriority missing or non-numeric at all_models: not rankable: disclosed uncertainty' 'a nonnumeric spendPriority remains eligible but unranked'
assert_contains "$OUT" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" 'numeric evidence wins without mixed-type ordering'
pass 'nonnumeric spendPriority evidence is never ranked'

# ---- partial providers retain their known row evidence -----------------------
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.status) = "partial"' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
cursor_line=$(cand cursor:cursor-grok-4.6-medium)
assert_contains "$cursor_line" 'provider=cursor  scope=all_models  remaining=91%  spendPriority=0.7597  runway=through_reset' 'a known row from a partial provider keeps its evidence'
assert_contains "$cursor_line" '-> eligible' 'a known row from a partial provider remains rankable'
assert_not_contains "$cursor_line" 'unranked' 'a known row from a partial provider is ranked'
assert_contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" 'partial provider evidence can win the quota composite'
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
])' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
cursor_line=$(cand cursor:cursor-grok-4.6-medium)
assert_contains "$cursor_line" 'provider=cursor  scope=model:cursor-grok-4.6-medium  remaining=-%  spendPriority=-  runway=-' 'an unknown exact-model row is the reported scope'
assert_contains "$cursor_line" 'bounds=all_models:91%/through_reset,model:cursor-grok-4.6-medium:-%/unknown  -> eligible, unranked: quota row model:cursor-grok-4.6-medium unknown: not rankable: disclosed uncertainty' 'an unknown exact-model row preserves partial known evidence without ranking'
assert_contains "$OUT" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" 'another measured candidate can clear'
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) |= (.status = "partial" | .effectiveAvailability += [
  {"scope":"model:cursor-grok-4.6-medium","status":"unknown","runway":{"status":"unknown"}}
] | .effectiveAvailability[] |= if .scope == "all_models" then .effectivePercentRemaining = 0 | .runway.status = "exhausted_now" else . end)' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
cursor_line=$(cand cursor:cursor-grok-4.6-medium)
assert_contains "$cursor_line" 'provider=cursor  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now' 'the exhausted bound is the reported evidence'
assert_contains "$cursor_line" 'bounds=all_models:0%/exhausted_now,model:cursor-grok-4.6-medium:-%/unknown  -> not eligible: runway exhausted_now at all_models' 'known exhaustion vetoes a candidate despite unknown exact-model evidence'
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics) = {"status":"unknown","effectiveAvailability":[
  {"scope":"all_models","status":"unknown","runway":{"status":"exhausted_now"}}]}' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
cursor_line=$(cand cursor:cursor-grok-4.6-medium)
assert_contains "$cursor_line" 'provider=cursor  scope=all_models  remaining=-%  spendPriority=-  runway=exhausted_now' 'unknown semantics still report the exhausted row'
assert_contains "$cursor_line" '-> not eligible: runway exhausted_now at all_models' 'unknown provider semantics cannot mask concrete exhaustion'
jq '(.providers[] | select(.provider == "cursor") | .quotaSemantics.effectiveAvailability) = [
  {"scope":"model:other","status":"known","effectivePercentRemaining":91,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
cursor_line=$(cand cursor:cursor-grok-4.6-medium)
assert_not_contains "$cursor_line" 'scope=' 'a candidate without an applicable row reports no borrowed scope'
assert_contains "$cursor_line" '-> eligible, unranked: no applicable quota row for provider cursor: disclosed uncertainty' 'a candidate without an applicable row remains eligible but unranked'
assert_contains "$OUT" "  profile: --harness 'claude' --model 'sonnet' --effort 'high'" 'the measured candidate clears beside the unranked one'
pass 'partial and missing quota evidence remain eligible but unranked'

# ---- provider-wide rows remain bounds beside exact model rows ----------------
BOUNDED="$TMP_ROOT/bounded.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability) += [
  {"scope":"model:sonnet","status":"known","effectivePercentRemaining":99,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}
]' "$WIDE_QUOTA" > "$BOUNDED"
cp "$BOUNDED" "$QUOTA"
keyed -- "$BRIEF"
claude_line=$(cand claude:sonnet)
assert_contains "$claude_line" 'provider=claude  scope=all_models  remaining=79%  spendPriority=-0.4627' 'the limiting provider-wide row drives ranking'
assert_contains "$claude_line" 'parts={"headroom":0.79,' 'headroom comes from the minimum applicable bound'
assert_contains "$claude_line" 'bounds=all_models:79%/projected_exhaustion,model:sonnet:99%/through_reset' 'all applicable quota bounds are disclosed'
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[] | select(.scope == "all_models")) |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")' "$BOUNDED" > "$QUOTA"
keyed -- "$BRIEF"
claude_line=$(cand claude:sonnet)
assert_contains "$claude_line" 'provider=claude  scope=all_models  remaining=0%' 'the exhausted account-wide bound is the candidate evidence'
assert_contains "$claude_line" '-> not eligible: runway exhausted_now at all_models' 'a healthy exact row cannot bypass an exhausted account-wide bound'
pass 'provider-wide and exact quota rows combine into one limiting candidate'

# ---- default choice ----------------------------------------------------------
cp "$WIDE_QUOTA" "$QUOTA"
settings '{"rule":"default"}'
keyed -- "$BRIEF"
assert_contains "$OUT" '  rule: default (No listed rule applies to this task.)' 'default names the fixed neutral none option'
assert_contains "$OUT" '  note: no rule matched' 'default is explained'
assert_contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-high'" 'default resolves by the quota composite'
pass 'default: no rule matched resolves among the default profiles'

# ---- genuine tie escalates ---------------------------------------------------
jq '.providers |= map(if .provider == "claude" or .provider == "cursor" then
  .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 91 | .runway.status = "through_reset" | .selection.spendPriority = 0.5) else . end)' \
  "$WIDE_QUOTA" > "$QUOTA"
for order in forward reverse; do
  if [ "$order" = forward ]; then cp "$WIDE_RULES" "$RULES"; else jq '.default |= reverse' "$WIDE_RULES" > "$RULES"; fi
  keyed -- "$BRIEF"
  assert_contains "$OUT" '  status: escalate' "a $order tie escalates"
  assert_contains "$OUT" '  reason: genuine quota evidence tie' "a $order tie is named"
  assert_not_contains "$OUT" '  profile:' "a $order tie never picks by array order"
done
cp "$WIDE_RULES" "$RULES"
pass 'tie: equal quota evidence never breaks by array order'

# ---- nothing rankable escalates ----------------------------------------------
settings '{"rule":"rule_4"}'
jq '.providers |= map(if .provider == "cursor" or .provider == "claude" then .quotaSemantics.effectiveAvailability |= map(.runway.status = "exhausted_now") else . end)' "$WIDE_QUOTA" > "$QUOTA"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: escalate' 'no rankable candidate escalates'
assert_contains "$OUT" '  reason: no rankable eligible candidate' 'the no-candidate reason is named'
assert_contains "$(cand claude:sonnet)" '-> not eligible: runway exhausted_now' 'exhausted candidates keep their reason'
assert_contains "$(cand kimi:kimi-code/k3)" '-> eligible, unranked:' 'an unmeasured candidate is disclosed, not ranked'
assert_not_contains "$OUT" '  profile:' 'nothing rankable emits no profile'
cp "$WIDE_QUOTA" "$QUOTA"
pass 'no rankable candidate: the tool escalates instead of guessing'

# ---- schema 6: rows keyed by provider + accountKey bind per account -----------
# Native Codex and Pi lanes bind to their own account rows, with no row chosen
# by position or summed across accounts.
LANE_RULES="$TMP_ROOT/lane-rules.json"
SCHEMA6="$TMP_ROOT/schema6.json"
SCHEMA5_PAIR="$TMP_ROOT/schema5-pair.json"
printf '%s\n' '{"rules":[{"when":"Codex work.","use":[
  {"harness":"pi","model":"openai-codex-work/gpt-5.6-terra","provider":"codex"},
  {"harness":"pi","model":"openai-codex/gpt-5.6-sol","provider":"codex"},
  {"harness":"codex","model":"gpt-5.6-sol"}]}]}' > "$LANE_RULES"
cat > "$SCHEMA6" <<'JSON'
{"generatedAt":"2030-01-01T00:00:00Z","schemaVersion":6,"providers":[
 {"provider":"claude","accountKey":"default","quotaSemantics":{"status":"unknown","effectiveAvailability":[]}},
 {"provider":"codex","accountKey":"openai-codex","quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"},"selection":{"spendPriority":-1.4788}}]}},
 {"provider":"codex","accountKey":"openai-codex-work","quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":11,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":-5.6819}}]}},
 {"provider":"cursor","accountKey":"default","quotaSemantics":{"status":"known","effectiveAvailability":[
  {"scope":"all_models","status":"known","effectivePercentRemaining":24,"runway":{"status":"projected_exhaustion"},"selection":{"spendPriority":0.3917}}]}}
]}
JSON
cp "$LANE_RULES" "$RULES"
cp "$SCHEMA6" "$QUOTA"
settings '{"rule":"rule_1"}'
rm -f "$QUOTA_AXI_CALLS"
keyed -- "$BRIEF"
expect_code 0 "$CODE" 'a schema 6 snapshot exits 0'
assert_contains "$OUT" '  status: clear' 'a schema 6 snapshot resolves'
assert_contains "$(cand pi:openai-codex-work/gpt-5.6-terra)" 'provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion' 'a Pi lane binds to its own account row'
assert_contains "$(cand pi:openai-codex/gpt-5.6-sol)" 'provider=codex  scope=all_models  remaining=0%  spendPriority=-  runway=exhausted_now' 'the sibling lane reads its own exhausted row'
assert_contains "$(cand pi:openai-codex/gpt-5.6-sol)" '-> not eligible: runway exhausted_now at all_models' 'the exhausted sibling lane is not eligible'
assert_contains "$(cand codex:gpt-5.6-sol)" '-> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' 'native Codex never infers an account from a Pi lane'
assert_contains "$OUT" "  profile: --harness 'pi' --model 'openai-codex-work/gpt-5.6-terra'" 'the lane with headroom is chosen'
assert_equals $'--version\n--json' "$(cat "$QUOTA_AXI_CALLS")" 'schema 6 checks compatibility and reads one snapshot'
SCHEMA6_NATIVE="$TMP_ROOT/schema6-native.json"
jq '
  .providers |= map(if .provider == "codex" then
    .quotaSemantics.effectiveAvailability |= map(.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    else . end) |
  (.providers[] | select(.accountKey == "openai-codex-work")) as $account |
  .providers += [($account | .accountKey = "default"),
    ($account | .accountKey = "codex-home" |
      .quotaSemantics.effectiveAvailability |= map(
        .effectivePercentRemaining = 80 | .runway.status = "through_reset" | .selection.spendPriority = 0.8))]
' "$SCHEMA6" > "$SCHEMA6_NATIVE"
cp "$SCHEMA6_NATIVE" "$QUOTA"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'native Codex headroom resolves despite exhausted Pi and default rows'
assert_contains "$(cand codex:gpt-5.6-sol)" 'provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset' 'native Codex reads codex-home'
assert_contains "$OUT" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" 'native Codex headroom is chosen'
jq '.providers |= reverse' "$SCHEMA6_NATIVE" > "$QUOTA"
keyed -- "$BRIEF"
assert_contains "$OUT" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" 'native Codex selection ignores row order'
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default") |
  if .accountKey == "codex-home" then .accountKey = "default" else . end)' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-default.json"
cp "$TMP_ROOT/schema6-default.json" "$QUOTA"
keyed -- "$BRIEF"
assert_contains "$OUT" "  profile: --harness 'codex' --model 'gpt-5.6-sol'" 'native Codex falls back to the default row when codex-home is absent'
jq '.schemaVersion = 5 | .providers |= map(select(.accountKey != "openai-codex")) | del(.providers[].accountKey)' "$SCHEMA6" > "$SCHEMA5_PAIR"
cp "$SCHEMA5_PAIR" "$QUOTA"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: escalate' 'schema 5 keeps joining by provider alone'
assert_contains "$OUT" '  reason: genuine quota evidence tie' 'every codex profile reads the one schema 5 codex row'
assert_contains "$(cand codex:gpt-5.6-sol)" 'provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion' 'a schema 5 row never needs accountKey'
jq '.providers |= map(select(.provider != "codex" or .accountKey != "default"))' "$SCHEMA6_NATIVE" > "$TMP_ROOT/schema6-pi-native.json"
for harness in pi pi-signed; do
  jq --arg harness "$harness" '.rules[0].use |= map(if .harness == "codex" then
    {harness: $harness, model: "codex-native/gpt-6-astra", provider: "codex", effort: "ultra"} else . end)' "$LANE_RULES" > "$RULES"
  cp "$TMP_ROOT/schema6-pi-native.json" "$QUOTA"
  keyed -- "$BRIEF"
  expect_code 0 "$CODE" "$harness native adapter schema 6 exits 0"
  assert_contains "$OUT" '  status: clear' "$harness native adapter resolves with codex-home and no default row"
  assert_contains "$(cand "$harness:codex-native/gpt-6-astra")" 'provider=codex  scope=all_models  remaining=80%  spendPriority=0.8  runway=through_reset' "$harness native adapter reads codex-home"
  assert_contains "$OUT" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter is chosen over exhausted Pi accounts"
  cp "$TMP_ROOT/schema6-default.json" "$QUOTA"
  keyed -- "$BRIEF"
  assert_contains "$OUT" "  profile: --harness '$harness' --model 'codex-native/gpt-6-astra' --effort 'ultra'" "$harness native adapter falls back to default"
  cp "$SCHEMA6" "$QUOTA"
  keyed -- "$BRIEF"
  assert_contains "$(cand "$harness:codex-native/gpt-6-astra")" '-> eligible, unranked: provider codex has no quota row for account codex-home: disclosed uncertainty' "$harness native adapter never borrows a Pi account"
  cp "$SCHEMA5_PAIR" "$QUOTA"
  keyed -- "$BRIEF"
  assert_contains "$(cand "$harness:codex-native/gpt-6-astra")" 'provider=codex  scope=all_models  remaining=11%  spendPriority=-5.6819  runway=projected_exhaustion' "$harness native adapter still joins schema 5 by provider alone"
done
cp "$LANE_RULES" "$RULES"
jq 'del(.providers[1].accountKey)' "$SCHEMA6" > "$QUOTA"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: error' 'a schema 6 row without accountKey is an error outcome'
assert_contains "$OUT" '  reason: quota-axi --json returned an invalid snapshot' 'a keyless schema 6 row is named as an invalid snapshot'
cp "$WIDE_RULES" "$RULES"
cp "$WIDE_QUOTA" "$QUOTA"
pass 'schema 6: native Codex and Pi lanes bind to their own account rows; schema 5 is unchanged'

# ---- runway is judged against the task horizon, not the reset clock ----------
GUARD_RULES="$TMP_ROOT/guard-rules.json"
GUARD_QUOTA="$TMP_ROOT/guard-quota.json"
jq '.rules = [.rules[3]] | .rules[0].use = [{harness:"codex",model:"gpt-6.1-sol"}]' "$WIDE_RULES" > "$GUARD_RULES"
cp "$GUARD_RULES" "$RULES"
settings '{"rule":"rule_1"}'
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 6 | .selection.spendPriority = 0.9)' "$WIDE_QUOTA" > "$GUARD_QUOTA"
guard_runway() {  # <name> <runway JSON>: write guard-<name>.json with that codex runway
  jq --argjson runway "$2" '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].runway) = $runway' "$GUARD_QUOTA" > "$TMP_ROOT/guard-$1.json"
}
guard_runway short '{"status":"projected_exhaustion","usableRunwaySeconds":3600,"projectionConfidence":"established"}'
guard_runway long '{"status":"projected_exhaustion","usableRunwaySeconds":80796,"projectionConfidence":"established"}'
guard_runway boundary '{"status":"projected_exhaustion","usableRunwaySeconds":14400,"projectionConfidence":"established"}'
guard_runway early-short '{"status":"projected_exhaustion","usableRunwaySeconds":3600,"projectionConfidence":"early"}'
guard_runway early-long '{"status":"projected_exhaustion","usableRunwaySeconds":80796,"projectionConfidence":"early"}'
guard_runway safe '{"status":"through_reset"}'
guard_runway unknown '{"status":"unknown"}'
guard_runway exhausted_now '{"status":"exhausted_now"}'
guard() { keyed QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-$1.json" -- "$BRIEF"; }
guard short
assert_contains "$OUT" '  status: escalate' 'established runway shorter than the default 240-minute horizon does not authorize dispatch'
assert_contains "$OUT" '  reason: highest-ranked candidate codex:gpt-6.1-sol has established runway shorter than the 240-minute task horizon; completion is not proven' 'the escalation names the short winner'
assert_contains "$(cand codex:gpt-6.1-sol)" '-> eligible [warning: projected_exhaustion at all_models (usableRunwaySeconds=3600 projectionConfidence=established)]' 'the candidate names its short runway'
assert_not_contains "$OUT" '  profile:' 'short runway emits no dispatch profile'
for name in long boundary safe; do
  guard "$name"
  assert_contains "$OUT" '  status: clear' "$name runway covering the task horizon clears despite 6% remaining"
  assert_contains "$OUT" "  profile: --harness 'codex' --model 'gpt-6.1-sol'" "$name runway authorizes the profile"
  assert_not_contains "$OUT" '[warning:' "$name runway is not a warning"
done
for name in early-short early-long unknown; do
  guard "$name"
  assert_contains "$OUT" '  status: clear' "$name runway is a disclosed warning, not a veto"
  assert_contains "$OUT" "  profile: --harness 'codex' --model 'gpt-6.1-sol'" "$name runway keeps the profile"
  assert_contains "$(cand codex:gpt-6.1-sol)" '-> eligible [warning: ' "$name runway is disclosed on the candidate"
done
guard early-short
assert_contains "$OUT" '[warning: projected_exhaustion at all_models (usableRunwaySeconds=3600 projectionConfidence=early)]' 'an early projection names its confidence'
keyed QUOTA_AXI_FIXTURE="$GUARD_QUOTA" -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'a projection without confidence is a warning, not a veto'
assert_contains "$OUT" '[warning: projected_exhaustion at all_models (usableRunwaySeconds=unknown projectionConfidence=unknown)]' 'absent projection fields are disclosed as unknown'
guard exhausted_now
assert_contains "$OUT" '  status: escalate' 'exhausted_now always vetoes'
assert_contains "$(cand codex:gpt-6.1-sol)" '-> not eligible: runway exhausted_now at all_models' 'exhausted_now is named'
assert_not_contains "$OUT" '  profile:' 'exhausted_now emits no dispatch profile'
# An exact-model short runway is noticed even when the limiting rank row is safe.
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability) += [
  {scope:"model:gpt-6.1-sol",status:"known",effectivePercentRemaining:50,runway:{status:"projected_exhaustion",usableRunwaySeconds:600,projectionConfidence:"established"},selection:{spendPriority:1}}
]' "$TMP_ROOT/guard-safe.json" > "$TMP_ROOT/guard-bound.json"
guard bound
assert_contains "$OUT" '  status: escalate' 'every applicable bound participates in the horizon check'
assert_contains "$(cand codex:gpt-6.1-sol)" '[warning: projected_exhaustion at model:gpt-6.1-sol (usableRunwaySeconds=600 projectionConfidence=established)]' 'the candidate names the non-limiting short bound'
# The horizon is a declared setting the model never sees.
jq '.task_horizon_minutes = 30' "$GUARD_RULES" > "$RULES"
guard short
assert_contains "$OUT" '  status: clear' 'one hour of runway covers a declared 30-minute horizon'
jq '.task_horizon_minutes = 120' "$GUARD_RULES" > "$RULES"
guard short
assert_contains "$OUT" '  status: escalate' 'a declared 120-minute horizon replaces the default'
assert_contains "$OUT" 'shorter than the 120-minute task horizon' 'the declared horizon names the short winner'
assert_not_contains "$(last_request)" 'task_horizon_minutes' 'the model never sees the task horizon'
# A short winner is not replaced by a lower-ranked candidate in the same rule.
jq '.rules[0].use += [{harness:"cursor",model:"cursor-grok-4.6-medium"}]' "$GUARD_RULES" > "$RULES"
jq '(.providers[] | select(.provider == "codex") | .quotaSemantics.effectiveAvailability[].effectivePercentRemaining) = 95' \
  "$TMP_ROOT/guard-short.json" > "$TMP_ROOT/guard-short-top.json"
guard short-top
assert_contains "$OUT" '  status: escalate' 'a short highest-ranked candidate escalates'
assert_contains "$OUT" 'reason: highest-ranked candidate codex:gpt-6.1-sol has established runway' 'the short winner is named'
assert_contains "$(cand cursor:cursor-grok-4.6-medium)" '-> eligible' 'the lower-ranked candidate stays visible'
assert_not_contains "$OUT" '  profile:' 'no same-rule fallback profile is emitted'
guard short
assert_contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" 'a higher-ranked feasible candidate is not displaced by a short lower-ranked one'
# A short matched rule never falls back to another rule or the default array.
jq '.rules += [{when:"Cheap chores.",use:{harness:"cursor",model:"cursor-grok-4.6-medium"}}]
  | .default = [{harness:"cursor",model:"cursor-grok-4.6-high"}]' "$GUARD_RULES" > "$RULES"
settings '{"rule":"rule_1","rule_probabilities":{"rule_1":0.9,"rule_2":0.08,"default":0.02}}'
guard short
assert_contains "$OUT" '  status: escalate' 'a short matched rule escalates despite runway elsewhere'
assert_not_contains "$OUT" 'candidate: cursor' "no other rule's or default candidate is evaluated"
assert_not_contains "$OUT" '  profile:' 'no cross-rule or weaker-class downgrade is emitted'
settings '{"rule":"rule_1"}'
# OpenRouter absent rows and credit-only rows are uncertainty, not quota runway.
jq '.rules[0].use = [{harness:"omp",model:"openrouter/provider/model",provider:"openrouter"}]' "$GUARD_RULES" > "$RULES"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: escalate' 'an absent OpenRouter row cannot clear'
assert_contains "$(cand omp:openrouter/provider/model)" 'provider=openrouter' 'the OpenRouter candidate is listed'
assert_contains "$(cand omp:openrouter/provider/model)" '-> eligible, unranked: provider openrouter not in the quota snapshot' 'absent OpenRouter coverage is disclosed'
jq '.providers += [{provider:"openrouter",windows:[{id:"credits",remaining:100,unit:"USD"}],quotaSemantics:{status:"unknown",effectiveAvailability:[]}}]' "$WIDE_QUOTA" > "$TMP_ROOT/guard-openrouter.json"
guard openrouter
assert_contains "$OUT" '  status: escalate' 'a positive OpenRouter credit balance does not establish runway'
assert_contains "$OUT" 'eligible, unranked: provider openrouter unmeasured (unknown)' 'credit-only evidence stays eligible but unranked'
assert_not_contains "$OUT" '  profile:' 'credit-only evidence never authorizes dispatch'
# An unreadable or older version is an error before snapshot interpretation.
cp "$GUARD_RULES" "$RULES"
for version in 0.1.50 'quota-axi development build'; do
  rm -f "$QUOTA_AXI_CALLS"
  keyed FAKE_QUOTA_VERSION="$version" -- "$BRIEF"
  expect_code 0 "$CODE" 'an incompatible quota version is a normal error outcome'
  assert_contains "$OUT" '  status: error' 'an incompatible quota version never clears'
  assert_contains "$OUT" 'quota-axi requires >= 0.1.51' 'the error names the required minimum'
  assert_equals '--version' "$(cat "$QUOTA_AXI_CALLS")" 'an incompatible binary never supplies ranking evidence'
  assert_not_contains "$OUT" '  profile:' 'an incompatible version emits no dispatch profile'
done
for version in 0.1.51 0.1.55 0.2.0 1.0.0; do
  keyed FAKE_QUOTA_VERSION="$version" QUOTA_AXI_FIXTURE="$TMP_ROOT/guard-safe.json" -- "$BRIEF"
  assert_contains "$OUT" '  status: clear' "compatible $version is usable"
done
rm -f "$QUOTA_AXI_CALLS"
keyed FAKE_QUOTA_VERSION_FAIL=1 -- "$BRIEF"
assert_contains "$OUT" '  status: error' 'a failed version read never clears'
assert_contains "$OUT" 'quota-axi requires >= 0.1.51' 'the failed version read names the minimum'
assert_equals '--version' "$(cat "$QUOTA_AXI_CALLS")" 'a failed version read never takes a quota snapshot'
cp "$WIDE_RULES" "$RULES"
pass 'task-horizon runway, OpenRouter coverage, and minimum-version guards'

# ---- quota-axi is read exactly once ------------------------------------------
cp "$TMP_ROOT/base-rules.json" "$RULES"
cp "$TMP_ROOT/base-quota.json" "$QUOTA"
settings '{}'
rm -f "$QUOTA_AXI_CALLS"
keyed -- "$BRIEF"
expect_code 0 "$CODE" 'the quota-axi path exits 0'
assert_equals $'--version\n--json' "$(cat "$QUOTA_AXI_CALLS")" 'quota-axi compatibility is checked and --json is called exactly once'
assert_contains "$OUT" "  profile: --harness 'claude' --model 'claude-sonnet-5-5[1m]' --effort 'high'" 'the quota-axi snapshot drives the composite'
keyed FAKE_QUOTA_FAIL=1 -- "$BRIEF"
expect_code 0 "$CODE" 'a quota-axi failure exits 0'
assert_contains "$OUT" '  status: error' 'a quota-axi failure is an error outcome'
assert_contains "$OUT" '  reason: quota-axi --json failed' 'a quota-axi failure is named'
assert_not_contains "$OUT" '  profile:' 'a quota-axi failure emits no profile'
pass 'quota evidence comes from one quota-axi --json read, and its failure is an error outcome'

# ---- API, transport, and response failures are error outcomes, exit 0 --------
api_error() {  # <label> <stderr category>
  expect_code 0 "$CODE" "$1 exits 0"
  assert_contains "$OUT" '  status: error' "$1 is a structured error outcome"
  assert_contains "$OUT" '  reason: Level 5 API request failed' "$1 is named as an API failure"
  assert_contains "$ERR" 'dispatch-resolve: error (Level 5 API request failed)' "$1 is also reported on stderr"
  assert_contains "$ERR" "dispatch-level5: $2" "$1 names its category"
  assert_not_contains "$OUT" '  profile:' "$1 emits no profile"
  assert_absent "$QUOTA_AXI_CALLS" "$1 never reads quota"
}
NO_RUNTIME_PATH=$(fm_test_base_path_sans "$FAKEBIN:$BASE_PATH" bun node)
rm -f "$QUOTA_AXI_CALLS"; before=$(count)
keyed PATH="$NO_RUNTIME_PATH" -- "$BRIEF"
expect_code 0 "$CODE" 'a missing runtime exits 0'
assert_contains "$OUT" '  status: error' 'a missing runtime is a structured error outcome'
assert_contains "$OUT" '  reason: neither bun nor node installed' 'a missing runtime is named in the TOON block'
assert_contains "$ERR" 'dispatch-resolve: error (neither bun nor node installed)' 'a missing runtime is also reported on stderr'
assert_equals "$before" "$(count)" 'a missing runtime makes no request'
assert_absent "$QUOTA_AXI_CALLS" 'a missing runtime never reads quota'
settings '{"http":429}'
before=$(count)
keyed -- "$BRIEF"
api_error 'HTTP 429' 'TypeSafe HTTP 429'
assert_equals "$((before + 3))" "$(count)" 'HTTP 429 is retried within the deadline before failing'
settings '{"http":500}'
before=$(count)
keyed -- "$BRIEF"
api_error 'HTTP 500' 'TypeSafe HTTP 500'
assert_equals "$((before + 1))" "$(count)" 'HTTP 500 is not retried'
settings '{}'
closed_port=$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')
keyed FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$closed_port" -- "$BRIEF"
api_error 'a closed port' 'request or local policy failure'
settings '{"drop":true}'
keyed -- "$BRIEF"
api_error 'a dropped connection' 'request or local policy failure'
settings '{"delay":6000}'
keyed -- "$BRIEF"
api_error 'a response slower than five seconds' 'request deadline exceeded'
settings '{"raw":"{not json"}'
keyed -- "$BRIEF"
api_error 'a malformed response body' 'invalid provider answer contract'
for bad in \
  'an out-of-range predicate|{"patch":{"answers":{"judgment_r3":{"noul":2}}}}' \
  'a nonnumeric predicate|{"patch":{"answers":{"judgment_r3":{"noul":"high"}}}}' \
  'a mismatched score legend|{"patch":{"answers":{"effort":{"legend":{"0":"tampered"}}}}}' \
  'an out-of-range score|{"patch":{"answers":{"effort":{"score":5}}}}' \
  'an out-of-range noul|{"needs_desktop":1.5}' \
  'a missing answer|{"patch":{"answers":{"judgment_r3":null}}}' \
  'malformed usage|{"patch":{"usage":"bad"}}' \
  'a fractional token count|{"patch":{"usage":{"input_tokens":1.5}}}' \
  'a blank model|{"patch":{"model":" "}}'; do
  settings "${bad#*|}"
  rm -f "$QUOTA_AXI_CALLS"
  keyed -- "$BRIEF"
  api_error "${bad%%|*}" 'invalid provider answer contract'
done
settings '{}'
pass 'API, transport, and response failures are error outcomes with exit 0'

# ---- OMP routing consumes the pool, never the single-account Codex row -------
cp "$POOL" "$TMP_ROOT/pre-omp-pool.json"
jq '.rules[3].use = {harness:"omp",model:"openai-codex/gpt-6-luna",effort:"low",provider:"codex"} |
  .rules[3].fallback = [{harness:"omp",model:"anthropic/claude-haiku-5-5",effort:"low"}]' "$TMP_ROOT/base-rules.json" > "$TMP_ROOT/pool-rules.json"
cp "$TMP_ROOT/pool-rules.json" "$RULES"
jq '.providers += [{provider:"codex",quotaSemantics:{status:"known",effectiveAvailability:[
  {scope:"all_models",status:"known",effectivePercentRemaining:0,runway:{status:"exhausted_now"},selection:{spendPriority:-1}}]}}]' \
  "$TMP_ROOT/base-quota.json" > "$QUOTA"
jq -n --argjson now "$(date +%s)" '{reports:[
  {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}},
  {provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}
]}' > "$POOL"
settings '{"rule":"rule_4"}'
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'the pooled sibling clears single-account exhaustion'
assert_not_contains "$(cand omp:openai-codex/gpt-6-luna)" 'remaining=0%' 'the pool never reads the single-account Codex row'
assert_contains "$(cand omp:openai-codex/gpt-6-luna)" 'pool={"status":"usable"' 'the native pool report owns serviceability'
assert_contains "$OUT" "--model 'openai-codex/gpt-6-luna'" 'a usable pool retains Luna'
assert_contains "$OUT" "--dispatch-rule 'rule_4'" 'the launch carries the selected fallback policy'
jq 'del(.rules[3].fallback)' "$TMP_ROOT/pool-rules.json" > "$RULES"
keyed -- "$BRIEF"
assert_contains "$OUT" "--model 'openai-codex/gpt-6-luna'" 'a rule without a fallback policy still resolves'
assert_not_contains "$OUT" '--dispatch-rule' 'a rule without a fallback policy emits no rule identifier'
cp "$TMP_ROOT/pool-rules.json" "$RULES"
jq '.reports[].metadata.meterStates.chat = {allowed:false,limitReached:true}' "$POOL" > "$TMP_ROOT/all-empty.json"
cp "$POOL" "$TMP_ROOT/mixed-pool.json"
cp "$TMP_ROOT/all-empty.json" "$POOL"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: clear' 'whole-pool exhaustion activates the declared stand-in'
assert_contains "$OUT" "--harness 'omp' --model 'anthropic/claude-haiku-5-5'" 'Luna uses only its named stand-in'
for harness in omp codex; do
  jq --arg h "$harness" '.rules[3].use.harness = $h |
    .rules[3].use.model = (if $h == "omp" then "openai-codex/gpt-6-luna" else "gpt-6-luna" end) |
    .rules[3].use.floor = {scope: (if $h == "omp" then "all_models" else "model:missing" end), min_percent: 20}' \
    "$TMP_ROOT/pool-rules.json" > "$RULES"
  keyed -- "$BRIEF"
  assert_contains "$OUT" '  status: escalate' "an unverifiable $harness floor blocks exhaustion fallback"
  assert_not_contains "$OUT" '  profile:' "an unverifiable $harness floor cannot emit a stand-in"
done
cp "$TMP_ROOT/pool-rules.json" "$RULES"
jq '.reports[1].fetchedAt = 0' "$TMP_ROOT/mixed-pool.json" > "$POOL"
keyed -- "$BRIEF"
assert_contains "$OUT" '  status: escalate' 'unknown pooled capacity does not authorize paid fallback'
assert_contains "$(cand omp:openai-codex/gpt-6-luna)" 'eligible, unranked: OMP pooled Codex capacity unknown' 'unknown pooled capacity is disclosed'
assert_not_contains "$OUT" '  profile:' 'an uncertain pool does not silently use the stand-in'
cp "$TMP_ROOT/pre-omp-pool.json" "$POOL"
cp "$TMP_ROOT/base-rules.json" "$RULES"
cp "$TMP_ROOT/base-quota.json" "$QUOTA"
settings '{}'
pass 'typed OMP dispatch preserves pooled headroom, explicit stand-ins, and uncertainty'

# ---- configuration errors exit 2 and select nothing --------------------------
before=$(count)
keyed --
expect_code 2 "$CODE" 'a missing brief exits 2'
assert_contains "$ERR" 'brief file required' 'a missing brief is named'
rm -f "$RULES"
printf '%s\n' '{"rules":[' > "$RULES"
keyed -- "$BRIEF"
expect_code 2 "$CODE" 'non-JSON rules exit 2'
assert_contains "$ERR" 'not JSON' 'non-JSON rules are named'
for bad in \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}|approval must be "captain" when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"select":"mystery"}]}|unknown select: mystery' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":"high"}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"min_confidence":1.5}]}|min_confidence must be a number from 0 through 1 when present' \
  '{"task_horizon_minutes":0,"rules":[{"when":"x","use":{"harness":"claude"}}]}|task_horizon_minutes must be a positive number when present' \
  '{"task_horizon_minutes":"4h","rules":[{"when":"x","use":{"harness":"claude"}}]}|task_horizon_minutes must be a positive number when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude"},"floor":{"scope":"model:fable","min_percent":20,"provider":"CLAUDE"}}]}|rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\z' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":""}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":" claude"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"claude","provider":"claude\n"}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":{"harness":"codex","floor":{"scope":"all_models","min_percent":20,"provider":"claude"}}}]}|each use profile needs harness; model, effort, and floor must be well formed, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\z when present' \
  '{"rules":[{"when":"x","use":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"codex","model":"gpt-5.5","effort":"high"}]}]}|each rule use must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":[{"harness":"claude","model":"opus"},{"harness":"claude","model":"opus"}]}|default must not contain duplicate harness, model, and effort profiles' \
  '{"rules":[{"when":"x","use":{"harness":"spaceship"}}]}|each use profile must name a verified harness' \
  '{"rules":[{"when":"x","use":{"harness":"grok","effort":"max"}}]}|each use profile effort must be supported by its harness and model' \
  '{"rules":[{"when":"x","use":{"harness":"gemini","model":"gemini-3.8-flash-high","provider":"google","effort":"minimal"}}]}|each use profile effort must be supported by its harness and model' \
  '{"judgments":{"q":{"type":"noul","instructions":"Q?"}},"rules":[{"when":"x","match":{"all":["q"]},"use":{"harness":"claude"}}]}|each judgment needs a lowercase id, type noul, non-empty instructions, and non-empty criteria.true and criteria.false' \
  '{"judgments":{},"rules":[{"when":"x","match":{"kind":"review"},"use":{"harness":"claude"}}]}|match requires a non-empty projects array and accepts only projects, kind, all, any, and none; kind must be ship or scout' \
  '{"judgments":{},"rules":[{"when":"x","match":{"projects":["pager"],"any":["q"]},"use":{"harness":"claude"}}]}|match all, any, and none must be non-empty arrays of declared judgment ids' \
  '{"rules":[{"when":"x","use":{"harness":"opencode","model":"anthropic/claude-sonnet-4-5"}}]}|use profiles whose harness lacks one authoritative provider family require provider: opencode' \
  '{"rules":[{"when":"x","use":{"harness":"rovo"}}]}|use profiles whose harness lacks one authoritative provider family require provider: rovo' \
  '{"rules":[{"when":"x","use":{"harness":"codex"}}],"default":{"harness":"pi","model":"anthropic/claude-sonnet-5"}}|default profiles whose harness lacks one authoritative provider family require provider: pi'; do
  printf '%s\n' "${bad%%|*}" > "$RULES"
  keyed -- "$BRIEF"
  expect_code 2 "$CODE" "malformed rules exit 2: ${bad#*|}"
  assert_contains "$ERR" "malformed rules file: $RULES - ${bad#*|}" "malformed rules are named: ${bad#*|}"
done
printf '%s\n' '{"rules":[{"when":"x","use":{"harness":"claude"},"approval":"firstmate"}]}' > "$RULES"
keyed -- "$BRIEF"
expect_code 2 "$CODE" 'a malformed field still exits 2 with the repair path'
assert_contains "$ERR" "resolved against $HOME_DIR/config/model-index.json, then rerun bin/fm-dispatch-resolve.sh <brief>" 'a malformed rules file names the files to fix and the rerun'
printf '%s\n' '{"rules":[{"when":"x","use":[{"harness":"opencode"},{"harness":"rovo"},{"harness":"codex"}]}],"default":[{"harness":"pi"},{"harness":"claude"}]}' > "$RULES"
keyed -- "$BRIEF"
expect_code 2 "$CODE" 'multiple provider-less profiles exit 2'
assert_contains "$ERR" "malformed rules file: $RULES - use profiles whose harness lacks one authoritative provider family require provider: opencode; use profiles whose harness lacks one authoritative provider family require provider: rovo; default profiles whose harness lacks one authoritative provider family require provider: pi" 'all provider-less profiles are reported together across use and default'
assert_equals 1 "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 'provider errors use one diagnostic'
cp "$TMP_ROOT/base-rules.json" "$RULES"
for removed in --json --rules --quota --bogus; do
  keyed -- "$BRIEF" "$removed"
  expect_code 2 "$CODE" "an unknown option is rejected: $removed"
  assert_contains "$ERR" "unknown flag $removed" "an unknown option has no public path: $removed"
done
assert_equals "$before" "$(count)" 'configuration errors never reach the provider'
resolve -- --help
expect_code 0 "$CODE" '--help exits 0'
assert_contains "$OUT" 'Usage:' '--help prints usage'
pass 'configuration errors exit 2 before any network call'

# ---- roles resolve before quota ranking -------------------------------------
cp "$WIDE_QUOTA" "$QUOTA"
settings '{"rule":"rule_4"}'
mkdir -p "$TMP_ROOT/model-catalogs"
printf '%s\n' '{"models":[{"id":"cursor-grok-4.6-medium"}]}' > "$TMP_ROOT/model-catalogs/cursor.json"
printf '%s\n' '{"version":1,"roles":{"routine":{"cursor":{"model":"cursor-grok-4.6-medium"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
jq '.rules[3].use[1] |= (del(.model) | .role = "routine")' "$WIDE_RULES" > "$RULES"
# Withheld intakes must not even try to read live catalog exports.
printf '%s\n' 'Does task exhibit property 1?' > "$NEVER_SEND"
withheld_run FM_MODEL_CATALOG_DIR="$TMP_ROOT/absent-catalogs" -- "$BRIEF"
expect_withheld 'a withheld indexed intake' "brief text matches $NEVER_SEND line 1" 'Does task exhibit'
rm "$NEVER_SEND"
keyed FM_MODEL_CATALOG_DIR="$TMP_ROOT/model-catalogs" -- "$BRIEF"
expect_code 0 "$CODE" 'role-based typed intake resolves'
assert_contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" 'typed intake publishes a concrete id'
assert_contains "$ERR" "literal model 'sonnet' for claude is not an index entry" 'literal profile ids warn while an index exists'
assert_not_contains "$(last_request)" 'routine' 'role names never reach the model'
mkdir -p "$TMP_ROOT/other-catalogs"
printf '%s\n' '{"models":[{"id":"cursor-other"}]}' > "$TMP_ROOT/other-catalogs/cursor.json"
keyed FM_MODEL_CATALOG_DIR="$TMP_ROOT/other-catalogs" -- "$BRIEF"
expect_code 0 "$CODE" 'a chosen id absent from its catalog never blocks intake'
assert_contains "$OUT" '  status: error' 'a chosen id absent from its catalog returns the decision to firstmate'
assert_not_contains "$OUT" '  profile:' 'a chosen id absent from its catalog publishes no profile'
assert_contains "$ERR" "id 'cursor-grok-4.6-medium' absent or retired in cursor catalog" 'the catalog refusal names the chosen id'
# An index edit during the rule request cannot change this intake's resolved id.
cp "$HOME_DIR/config/model-index.json" "$TMP_ROOT/original-index.json"
jq '.roles.routine.cursor.model = "new-model-not-in-catalog"' "$TMP_ROOT/original-index.json" > "$TMP_ROOT/changed-index.json"
jq -n --arg source "$TMP_ROOT/changed-index.json" --arg target "$HOME_DIR/config/model-index.json" '{rule: "rule_4", mutate: [$source, $target]}' > "$SETTINGS"
keyed FM_MODEL_CATALOG_DIR="$TMP_ROOT/model-catalogs" -- "$BRIEF"
expect_code 0 "$CODE" 'an in-flight index edit does not re-resolve the role'
assert_equals "$(cat "$TMP_ROOT/changed-index.json")" "$(cat "$HOME_DIR/config/model-index.json")" 'the provider replaced the index mid-request'
assert_contains "$OUT" "  profile: --harness 'cursor' --model 'cursor-grok-4.6-medium'" 'intake keeps the id resolved from its frozen index'
cp "$TMP_ROOT/original-index.json" "$HOME_DIR/config/model-index.json"
settings '{"rule":"rule_4"}'
# A role and a literal that resolve to the same candidate remain duplicates.
jq '.rules[3].use += [{harness:"cursor",model:"cursor-grok-4.6-medium"}]' "$RULES" > "$TMP_ROOT/duplicate-role.json"
cp "$TMP_ROOT/duplicate-role.json" "$RULES"
before=$(count)
keyed FM_MODEL_CATALOG_DIR="$TMP_ROOT/model-catalogs" -- "$BRIEF"
expect_code 2 "$CODE" 'duplicate concrete role/literal profiles refuse intake'
assert_equals "$before" "$(count)" 'duplicate candidates refuse before the rule request'
rm "$HOME_DIR/config/model-index.json"
cp "$WIDE_RULES" "$RULES"
pass 'typed intake resolves roles before quota ranking and detects concrete duplicates'

# The chosen id is checked against the catalog of the account a pinned worker
# would launch under, not the intake's ambient account.
mkdir -p "$TMP_ROOT/pinned-claude" "$TMP_ROOT/ambient-claude"
printf 'pinned-only\n' > "$TMP_ROOT/pinned-claude/catalog"
printf 'ambient-only\n' > "$TMP_ROOT/ambient-claude/catalog"
cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${CLAUDE_CONFIG_DIR-unset}" >> '$TMP_ROOT/claude-catalog-roots'
jq -Rsc '{type:"control_response",response:{subtype:"success",request_id:"model-index",
  response:{models:[split("\\n")[] | select(length > 0) | {value:., resolvedModel:.}]}}}' "\${CLAUDE_CONFIG_DIR}/catalog"
SH
chmod +x "$FAKEBIN/claude"
printf '%s\n' '{"version":1,"roles":{"routine":{"claude":{"model":"pinned-only"}}},"retired":[]}' > "$HOME_DIR/config/model-index.json"
printf '%s\n' "$TMP_ROOT/pinned-claude" > "$HOME_DIR/config/claude-account"
printf '%s\n' '{"rules":[{"when":"Claude work.","use":{"harness":"claude","role":"routine"}}]}' > "$RULES"
settings '{"rule":"rule_1"}'
keyed CLAUDE_CONFIG_DIR="$TMP_ROOT/ambient-claude" -- "$BRIEF"
expect_code 0 "$CODE" 'pinned-account intake exits 0'
assert_contains "$OUT" "  profile: --harness 'claude' --model 'pinned-only'" "the pinned account's catalog decides the chosen id: $ERR"
assert_equals "$TMP_ROOT/pinned-claude" "$(cat "$TMP_ROOT/claude-catalog-roots")" 'the chosen-id catalog is read from the pinned root only'
rm "$HOME_DIR/config/model-index.json" "$HOME_DIR/config/claude-account" "$FAKEBIN/claude"
cp "$WIDE_RULES" "$RULES"
pass "typed intake checks the chosen id against the pinned worker account's catalog"

mkdir -p "$TMP_ROOT/supervisor-account"
printf '%s\n' '{"models":[{"slug":"supervisor-only"}]}' > "$TMP_ROOT/supervisor-account/models_cache.json"
printf 'openai-codex  supervisor-only  272K  32K  yes  no\n' > "$TMP_ROOT/supervisor-account/listed"
cat > "$FAKEBIN/pi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\${PI_CODING_AGENT_DIR-unset}" >> '$TMP_ROOT/unpinned-catalog-calls'
printf 'provider model context\n'
cat "\$PI_CODING_AGENT_DIR/listed"
SH
chmod +x "$FAKEBIN/pi"
: > "$HOME_DIR/config/launch-env-allowlist"
for context_harness in codex pi; do
  for context_model in pane-only supervisor-only; do
    context_id=$context_model
    [ "$context_harness" != pi ] || context_id="openai-codex/$context_model"
    jq -n --arg h "$context_harness" --arg m "$context_id" \
      '{version:1,roles:{chosen:{($h):{model:$m}}},retired:[]}' > "$HOME_DIR/config/model-index.json"
    jq -n --arg h "$context_harness" \
      '{rules:[{when:"Indexed work.",use:{harness:$h,role:"chosen",provider:"codex"}}]}' > "$RULES"
    keyed CODEX_HOME="$TMP_ROOT/supervisor-account" PI_CODING_AGENT_DIR="$TMP_ROOT/supervisor-account" -- "$BRIEF"
    expect_code 0 "$CODE" 'unknown chosen context keeps intake available'
    assert_contains "$OUT" '  status: clear' "supervisor listing or omission does not decide the chosen entry: $ERR"
    assert_contains "$OUT" "--model '$context_id'" 'the chosen profile retains the indexed model'
    assert_contains "$ERR" 'effective worker account context is not established' 'chosen context uncertainty is precise'
    assert_contains "$ERR" 'not validated' 'a matching supervisor listing does not imply validation'
    assert_absent "$TMP_ROOT/unpinned-catalog-calls" 'chosen Pi does not query the supervisor catalog'
  done
done
mkdir -p "$TMP_ROOT/context-exports"
printf '%s\n' '{"models":[{"id":"openai-codex/supervisor-only","resolved_id":"retired-target"}]}' > "$TMP_ROOT/context-exports/pi.json"
jq '.retired = ["retired-target"]' "$HOME_DIR/config/model-index.json" > "$TMP_ROOT/context-index.json"
cp "$TMP_ROOT/context-index.json" "$HOME_DIR/config/model-index.json"
keyed FM_MODEL_CATALOG_DIR="$TMP_ROOT/context-exports" -- "$BRIEF"
assert_contains "$OUT" '  status: error' 'an authoritative export still refuses an alias resolved to a retired id'
assert_not_contains "$OUT" '  profile:' 'an export-backed retirement publishes no profile'
assert_contains "$ERR" 'absent or retired in pi catalog' 'explicit export evidence remains authoritative despite unknown pane context'
rm "$HOME_DIR/config/model-index.json" "$HOME_DIR/config/launch-env-allowlist" "$FAKEBIN/pi"
cp "$TMP_ROOT/base-rules.json" "$RULES"
cp "$TMP_ROOT/base-quota.json" "$QUOTA"
settings '{}'
pass 'chosen Codex and Pi entries never use supervisor catalogs and retain authoritative export retirement checks'

# ---- independent rule support and result logging ----------------------------
# Independent predicates cannot pool their support just because profiles match.
LOG="$HOME_DIR/data/dispatch-resolve.jsonl"
rm -f "$LOG"
jq '.rules[3].use = .rules[2].use' "$TMP_ROOT/base-rules.json" > "$RULES"
settings '{"rule_probabilities":{"rule_1":0,"rule_2":0,"rule_3":0.51,"rule_4":0.49}}'
keyed -- "$BRIEF"
assert_contains "$OUT" 'status: ambiguous' 'overlapping independent judgments never sum to confidence'
assert_not_contains "$OUT" '  profile:' 'duplicating a rule cannot authorize dispatch'
cp "$TMP_ROOT/base-rules.json" "$RULES"
settings '{"rule":"rule_3"}'
keyed -- "$BRIEF"
assert_contains "$OUT" 'status: clear' 'a supported rule clears'
jq '.rules[2].approval="captain"' "$TMP_ROOT/base-rules.json" > "$RULES"
keyed -- "$BRIEF"
assert_contains "$OUT" 'status: escalate' 'approval remains independent of semantic support'
cp "$TMP_ROOT/base-rules.json" "$RULES"
keyed FAKE_QUOTA_FAIL=1 -- "$BRIEF"
assert_contains "$OUT" 'status: error' 'quota failures remain errors'
rm "$RULES"
keyed -- "$BRIEF"
assert_contains "$OUT" 'reason: no rules to match' 'absent configuration stays non-clear'
assert_equals 'ambiguous clear escalate error escalate' "$(jq -r '.status' "$LOG" | paste -sd' ' -)" 'each finished resolve appends exactly one result'
jq -e -s 'all(.[]; has("ts") and has("choice") and has("profile") and (has("pooled") | not))' "$LOG" >/dev/null || fail 'malformed result records'
for private in "$KEY" 'Fix the off-by-one' 'Does task exhibit'; do
  assert_no_grep "$private" "$LOG" 'result records exclude key, task and questions'
done
cp "$TMP_ROOT/base-rules.json" "$RULES"
settings '{}'
pass 'independent support cannot pool, and private result logging retains every outcome'

# ---- shadow model picker: observe only -----------------------------------------
# With the flag off the resolver is byte-identical and touches no picker data. With it on
# the picker logs what it would have chosen and the resolver's status/profile/exit stay the
# same, including when the picker's own Jev call fails.
SHADOW_DATA="$TMP_ROOT/shadow-data"
mkdir -p "$SHADOW_DATA/projection"
for slug in claude-sonnet-5-5-high claude-opus-5-5-high claude-haiku-5-5 \
            gpt-6-1-sol-high gpt-6-luna-low deepseek-v4-flash; do
  cp "$ROOT/tests/fixtures/model-picker-shadow/projection/$slug.json" "$SHADOW_DATA/projection/"
done
printf '%s\n' '{"verdict":"TRUSTED"}' > "$SHADOW_DATA/verdict.json"
printf '%s\n' '{"work_type":"feature","worker":"candidate_3","validator":"candidate_5"}' > "$SETTINGS"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({reports:[{provider:"openai-codex",fetchedAt:Date.now(),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}},limits:[{scope:{tier:"chat"},amount:{remainingFraction:.9}}]}]}))' "$POOL"
run_shadow() {  # <flag-value>
  structure_rules "$RULES"
  bind_brief "$BRIEF" "$HOME_DIR"
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=synthetic-key \
    FM_MODEL_PICKER_SHADOW="$1" FM_MODEL_PICKER_DATA="$SHADOW_DATA" \
    bash "$ROOT/bin/fm-dispatch-resolve.sh" "$TMP_ROOT/bound-brief.md" 2> "$TMP_ROOT/error") \
    || fail "resolver failed with shadow flag '$1': $(cat "$TMP_ROOT/error")"
}
strip_diag() { printf '%s\n' "$1" | grep -v -e '^  timings:' -e '^  usage:' -e '^  model:'; }
shadow_sql() { python3 -I -c 'import sqlite3,sys; print("\n".join("|".join(str(c) for c in r) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])))' "$SHADOW_DATA/aa.sqlite" "$1" 2>/dev/null || true; }

before_calls=$(count)
run_shadow ''
OFF=$OUT
[ ! -e "$SHADOW_DATA/aa.sqlite" ] || fail 'flag off created the picker store'
strip_diag "$OFF" > "$TMP_ROOT/off1.txt"
run_shadow ''
strip_diag "$OUT" > "$TMP_ROOT/off2.txt"
diff -u "$TMP_ROOT/off1.txt" "$TMP_ROOT/off2.txt" > "$TMP_ROOT/offdiff.txt" \
  || fail "two flag-off resolves differ: $(cat "$TMP_ROOT/offdiff.txt")"
assert_equals 2 "$(( $(count) - before_calls ))" 'two flag-off resolves make only their own rule calls'
assert_equals 0 "$(grep -c '"work_type"' "$CALLS" || true)" 'flag off adds no picker request'
off_calls=$(count)
run_shadow 1
ON=$OUT
strip_diag "$OFF" > "$TMP_ROOT/off.txt"
strip_diag "$ON" > "$TMP_ROOT/on.txt"
diff -u "$TMP_ROOT/off.txt" "$TMP_ROOT/on.txt" > "$TMP_ROOT/diff.txt" \
  || fail "flag-on stdout changed beyond timings: $(cat "$TMP_ROOT/diff.txt")"
[ "$(count)" -gt "$off_calls" ] || fail 'flag on made no picker request'
assert_equals 1 "$(shadow_sql "select count(*) from dispatch_log where mode='shadow'")" 'exactly one shadow row'
[ -e "$SHADOW_DATA/resolver-rows/$(shadow_sql "select task_key from dispatch_log")" ] || fail 'the resolver row leaves the one-shot marker the spawn hook consumes'
[ "$(shadow_sql "select count(*) from outcomes")" = 0 ] || fail 'the shadow path wrote an outcome'
assert_equals 'accepted' "$(shadow_sql "select picker_status from dispatch_log")" 'the picker accepted its pick'
rule_worker=$(sed -n 's/^  profile:.*--harness \([^ ]*\) --model \([^ ]*\).*/\1:\2/p' <<<"$ON" | tr -d "'")
assert_equals "$rule_worker" "$(shadow_sql "select rule_worker from dispatch_log")" 'the row records the route the resolver chose'
[ -n "$(shadow_sql "select chosen_worker from dispatch_log")" ] || fail 'the row records the picker pick'
assert_equals 'omp:openai-codex/gpt-6.1-sol' "$(shadow_sql "select chosen_validator from dispatch_log")" 'the row records the eligible cross-family validator'
[ -n "$(shadow_sql "select jev_raw_payload from dispatch_log")" ] || fail 'the row retains the raw Jev result'

# A picker-only Jev failure must not move the resolver result.
python3 - "$SETTINGS" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc['http'] = 500
doc['http_if'] = 'work_type'
json.dump(doc, open(sys.argv[1], 'w'))
PY
run_shadow 1
strip_diag "$OUT" > "$TMP_ROOT/on500.txt"
diff -u "$TMP_ROOT/off.txt" "$TMP_ROOT/on500.txt" > "$TMP_ROOT/diff500.txt" \
  || fail "a picker 500 changed the resolver result: $(cat "$TMP_ROOT/diff500.txt")"
assert_equals 'picker-error' "$(shadow_sql "select picker_status from dispatch_log order by id desc limit 1")" 'the picker failure is recorded'
printf '%s\n' '{"work_type":"feature","worker":"candidate_3","validator":"candidate_5"}' > "$SETTINGS"

# An UNTRUSTED verdict stops the picker before any benchmark fact is read or sent.
printf '%s\n' '{"verdict":"UNTRUSTED","reason":"matrix rebuilt without chart-diff"}' > "$SHADOW_DATA/verdict.json"
picker_calls_before=$(grep -c '"work_type"' "$CALLS" || true)
run_shadow 1
strip_diag "$OUT" > "$TMP_ROOT/onunt.txt"
diff -u "$TMP_ROOT/off.txt" "$TMP_ROOT/onunt.txt" > "$TMP_ROOT/diffunt.txt" \
  || fail "an untrusted snapshot changed the resolver result: $(cat "$TMP_ROOT/diffunt.txt")"
assert_equals "$picker_calls_before" "$(grep -c '"work_type"' "$CALLS" || true)" 'no picker request was sent for an untrusted snapshot'
assert_equals 'no-trusted-snapshot' "$(shadow_sql "select picker_status from dispatch_log order by id desc limit 1")" 'the refusal is recorded'
printf '%s\n' '{"verdict":"TRUSTED"}' > "$SHADOW_DATA/verdict.json"
pass 'shadow mode: off is identical and inert; on logs both picks without changing the dispatch, even when Jev fails or the snapshot is untrusted'

printf '# all fm-dispatch-resolve tests passed\n'
