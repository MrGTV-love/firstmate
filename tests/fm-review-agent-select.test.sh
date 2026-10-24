#!/usr/bin/env bash
# Behavior tests for bin/fm-review-agent-select.sh: the dry-run review-agent selector.
# Drives the public argv interface with a mocked quota-axi, a mocked omp, and a throwaway home.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-agent-select)
trap fm_test_cleanup EXIT
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
NM_DIR="$TMP_ROOT/nm"
CATALOGS="$TMP_ROOT/catalogs"
QUOTA="$TMP_ROOT/quota.json"
POOL="$TMP_ROOT/pool.json"
ERR="$TMP_ROOT/err"
SELECT="$ROOT/bin/fm-review-agent-select.sh"
RULES="$HOME_DIR/config/crew-dispatch.json"
LOG="$HOME_DIR/state/review-agent-select.jsonl"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$NM_DIR" "$CATALOGS"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) printf '%s\n' 0.1.51 ;;
  --json) [ "${FAKE_QUOTA_FAIL:-0}" = 1 ] && exit 1; cat "$QUOTA_AXI_FIXTURE" ;;
  *) exit 2 ;;
esac
SH
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  usage) cat "$POOL" ;;
  models) printf '%s\n' '{"models":[{"selector":"openai-codex/gpt-6.1-sol"},{"selector":"lab/native-model"}]}' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/omp"
export QUOTA_AXI_FIXTURE="$QUOTA" POOL

THROUGH='{"status":"through_reset"}'
EXHAUSTED='{"status":"exhausted_now"}'
SHORT='{"status":"projected_exhaustion","usableRunwaySeconds":600,"projectionConfidence":"established"}'

row() {  # <scope> <percent> <runway-json> <spendPriority>
  jq -cn --arg scope "$1" --argjson pct "$2" --argjson runway "$3" --argjson sp "$4" \
    '{scope: $scope, status: "known", effectivePercentRemaining: $pct, runway: $runway, selection: {spendPriority: $sp}}'
}
write_quota() {  # <claude availability rows as a JSON array>
  jq -n --argjson rows "$1" \
    '{schemaVersion: 5, providers: [{provider: "claude", quotaSemantics: {status: "known", effectiveAvailability: $rows}}]}' > "$QUOTA"
}
write_pool() {  # <remaining percent per account>...; no argument writes an empty report
  jq -n --argjson now "$(date +%s)" '{reports: ($ARGS.positional | map(tonumber) | map(
      {provider: "openai-codex", fetchedAt: ($now * 1000),
       limits: [{scope: {shared: true}, amount: {unit: "percent", remaining: .}}]}))}' --args "$@" > "$POOL"
}
write_rules() {  # <review rule use array> [fallback array]; the review rule is rule_2
  jq -n --argjson use "$1" --argjson fallback "${2:-[]}" '
    {rules: [
      {when: "Trivial mechanical edit.", use: {harness: "claude", model: "claude-haiku-5-5", effort: "max"}},
      ({when: "Isolated independent quality review of a specific pull request, commit, or review delta.", use: $use}
        + (if ($fallback | length) > 0 then {fallback: $fallback} else {} end))
    ], default: {harness: "claude", model: "claude-sonnet-5-5[1m]", effort: "high"}}' > "$RULES"
}
SOL='{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high","provider":"codex"}'
SONNET='{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}'
OPUS='{"harness":"claude","model":"opus","effort":"high"}'
LAB_OMP='{"harness":"omp","model":"lab/native-model","effort":"high"}'
DEEPSEEK='{"harness":"dsh","model":"deepseek/deepseek-v4-flash","effort":"high"}'
DEFAULT_USE="[$SOL,$SONNET]"

CODE=0 OUT=''
select_run() {  # <args...>; sets OUT, CODE; stderr in $ERR
  OUT=$(env -u FM_CONFIG_OVERRIDE -u FM_STATE_OVERRIDE -u FM_MODEL_CATALOG_DIR \
    PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" NO_MISTAKES_HOME="$NM_DIR" "${EXTRA_ENV[@]}" \
    bash "$SELECT" "$@" 2>"$ERR") && CODE=0 || CODE=$?
}
EXTRA_ENV=(FM_SELECT_TEST=1)
select_json() {  # runs with --log and sets OUT to the record that run appended
  rm -f "$LOG"
  select_run --dry-run --log
  OUT=$(tail -n 1 "$LOG" 2>/dev/null)
}
selected_model() { jq -r '.selected.model // "none"' <<<"$OUT"; }

# ---- healthy pool: the highest known spendPriority wins, the pool is disclosed ----
write_rules "$DEFAULT_USE" "[$DEEPSEEK]"
write_quota "[$(row all_models 94 "$THROUGH" 1.5)]"
write_pool 52
cat > "$NM_DIR/config.yaml" <<'YAML'
# no-mistakes global configuration
agent: [claude, acp:omp]   # the live order
agent_path_override:
  claude: /somewhere/claude-wrapper
YAML
before=$(cksum < "$NM_DIR/config.yaml")
select_run --dry-run
expect_code 0 "$CODE" 'a run without --log selects'
assert_contains "$OUT" '  selected: claude:claude-sonnet-5-5[1m] effort=high agent=claude tier=primary' 'text names the choice'
assert_contains "$OUT" '  current: agent=[claude, acp:omp]' 'text names the live agent order'
assert_absent "$LOG" 'no log without --log'
select_json
expect_code 0 "$CODE" 'healthy pool selects'
assert_equals claude-sonnet-5-5\[1m\] "$(selected_model)" 'known spendPriority beats an unranked pool'
assert_equals selected "$(jq -r .status <<<"$OUT")" 'status is selected'
assert_equals rule_2 "$(jq -r .rule <<<"$OUT")" 'the review rule is found by its when text'
assert_equals 1.5 "$(jq -r .selected.spendPriority <<<"$OUT")" 'the winner carries its scalar'
assert_contains "$(jq -r .reason <<<"$OUT")" 'unranked, disclosed: omp:openai-codex/gpt-6.1-sol' 'the unranked pool is disclosed beside the winner'
assert_equals 2 "$(jq '.candidates | length' <<<"$OUT")" 'every use candidate is accounted for'
assert_equals false "$(jq '[.candidates[] | select(.tier == "fallback")] | length > 0' <<<"$OUT")" 'no fallback is evaluated without proven exhaustion'
assert_equals '[claude, acp:omp]' "$(jq -r .current.agent <<<"$OUT")" 'the live agent order is read'
assert_equals "$before" "$(cksum < "$NM_DIR/config.yaml")" 'the no-mistakes config is never written'
pass 'a healthy pool selects the highest known spendPriority and discloses the pool'

# ---- quota-tight pool: a short runway fails the gate, the measured pool is used ----
write_quota "[$(row all_models 5 "$SHORT" 0.1)]"
write_pool 12
select_json
expect_code 0 "$CODE" 'tight pool still selects'
assert_equals openai-codex/gpt-6.1-sol "$(selected_model)" 'a candidate whose runway is shorter than the horizon is not selected'
claude_reason=$(jq -r '.candidates[] | select(.harness == "claude") | .reason' <<<"$OUT")
assert_contains "$claude_reason" 'shorter than the 14400s task horizon' 'the runway refusal names the horizon'
assert_equals false "$(jq '.candidates[] | select(.harness == "claude") | .eligible' <<<"$OUT")" 'the tight candidate is not eligible'
assert_equals false "$(jq '.candidates[] | select(.harness == "claude") | .exhausted' <<<"$OUT")" 'a short runway is not proven exhaustion'
assert_equals acp:omp "$(jq -r .selected.agent <<<"$OUT")" 'the selected pool runs as the omp review agent'
assert_equals 12 "$(jq '.candidates[] | select(.harness == "omp") | .pct' <<<"$OUT")" 'pool headroom is the best usable account'
write_pool 4
select_json
assert_equals openai-codex/gpt-6.1-sol "$(selected_model)" 'a thin but usable pool is still measured headroom'
pass 'a quota-tight pool moves off the candidate whose runway cannot finish the task'

# ---- one account out: the pool stays usable on the surviving account ----------------
write_quota "[$(row all_models 0 "$EXHAUSTED" 0)]"
write_pool 0 35
select_json
expect_code 0 "$CODE" 'one account out still selects'
assert_equals openai-codex/gpt-6.1-sol "$(selected_model)" 'the surviving account serves the pool'
assert_equals true "$(jq '.candidates[] | select(.harness == "claude") | .exhausted' <<<"$OUT")" 'exhausted_now is proven exhaustion'
assert_equals 2 "$(jq '.candidates[] | select(.harness == "omp") | .capacity.accounts | length' <<<"$OUT")" 'both pooled accounts are reported'
assert_equals 35 "$(jq '.candidates[] | select(.harness == "omp") | .pct' <<<"$OUT")" 'headroom is the surviving account, not a sum'
assert_equals false "$(jq '[.candidates[] | select(.tier == "fallback")] | length > 0' <<<"$OUT")" 'a usable account means no fallback'

# ---- every account out: only proven exhaustion of all use candidates opens the fallback ----
write_pool 0 0
select_json
expect_code 1 "$CODE" 'DeepSeek must not remain an omp review-agent fallback'
assert_equals null "$(jq -c .selected <<<"$OUT")" 'no unsupported transport is selected'
assert_equals dsh "$(jq -r '.candidates[] | select(.tier == "fallback") | .harness' <<<"$OUT")" 'DeepSeek retains the dsh identity'
assert_equals false "$(jq -r '.candidates[] | select(.tier == "fallback") | .eligible' <<<"$OUT")" 'an unverified review transport is ineligible'
assert_contains "$(jq -r '.candidates[] | select(.tier == "fallback") | .reason' <<<"$OUT")" 'no verified no-mistakes review-agent transport' 'the missing capability is explicit'
write_rules "$DEFAULT_USE" "[$LAB_OMP]"
select_json
expect_code 0 "$CODE" 'proven exhaustion uses an eligible non-DeepSeek declared fallback'
assert_equals fallback "$(jq -r .selected.tier <<<"$OUT")" 'the tier is reported'
assert_equals "$LAB_OMP" "$(jq -c '.selected | {harness, model, effort}' <<<"$OUT")" 'the declared fallback is selected exactly'
assert_contains "$(jq -r .reason <<<"$OUT")" 'proven exhausted' 'the reason states proven exhaustion'
write_rules "$DEFAULT_USE"
select_json
expect_code 1 "$CODE" 'exhaustion with no declared fallback does not select'
assert_equals escalate "$(jq -r .status <<<"$OUT")" 'no fallback escalates'
assert_contains "$(jq -r .reason <<<"$OUT")" 'the rule declares no fallback' 'the reason names the missing fallback'
assert_equals null "$(jq -c .selected <<<"$OUT")" 'no choice is offered without a selection'
write_rules "$DEFAULT_USE" "[$DEEPSEEK]"
pass 'one account out keeps the pool; every account out opens only the declared fallback'

# ---- a DeepSeek use profile is refused before any candidate is assessed -------------
write_rules "[$DEEPSEEK,$SONNET]"
rm -f "$LOG"
select_run --dry-run --log
expect_code 2 "$CODE" 'a DeepSeek use profile must refuse the review rule'
assert_contains "$(cat "$ERR")" 'harness dsh has no no-mistakes review agent' 'the refusal names the missing review agent'
assert_equals error "$(tail -n 1 "$LOG" | jq -r .status)" 'the refused rule is recorded as an error'
assert_equals null "$(tail -n 1 "$LOG" | jq -c .selected)" 'a refused rule records no selection'
write_rules "$DEFAULT_USE" "[$DEEPSEEK]"
pass 'a DeepSeek use profile is refused loudly and never selected'

# ---- unknown evidence is never read as healthy or as zero ---------------------------
: > "$QUOTA"
jq -n '{schemaVersion: 5, providers: []}' > "$QUOTA"
write_pool 0 0
select_json
expect_code 1 "$CODE" 'unmeasured claude with an exhausted pool escalates'
assert_equals escalate "$(jq -r .status <<<"$OUT")" 'no measured headroom escalates'
assert_equals false "$(jq '[.candidates[] | select(.tier == "fallback")] | length > 0' <<<"$OUT")" 'unknown is not proven exhaustion, so the fallback stays closed'
assert_contains "$(jq -r .reason <<<"$OUT")" 'no candidate has measured headroom' 'the reason names the missing headroom'
pass 'unmeasured quota escalates instead of selecting around'

# ---- ranking among known scalars: limiting row, ties ---------------------------------
write_rules "[$SONNET,$OPUS]"
write_pool 50
write_quota "[$(row all_models 90 "$THROUGH" 1.0),$(row model:opus 90 "$THROUGH" 0.4)]"
select_json
expect_code 0 "$CODE" 'ranked pair selects'
assert_equals claude-sonnet-5-5\[1m\] "$(selected_model)" 'the more constraining row sets each candidate scalar'
assert_equals 0.4 "$(jq '.candidates[] | select(.model == "opus") | .spendPriority' <<<"$OUT")" 'the limiting scalar is reported'
write_quota "[$(row all_models 90 "$THROUGH" 1.0)]"
select_json
expect_code 1 "$CODE" 'a tie does not select'
assert_equals tie "$(jq -r .status <<<"$OUT")" 'equal scalars are a tie'
assert_equals null "$(jq -c .selected <<<"$OUT")" 'a tie names no winner'
assert_contains "$(jq -r .reason <<<"$OUT")" 'claude:opus' 'the tie names every tied candidate'
write_rules "$DEFAULT_USE" "[$DEEPSEEK]"
pass 'known scalars rank by their limiting row and a tie is reported, never broken'

# ---- profile floor and launch policy -------------------------------------------------
write_rules "[$(jq -c '. + {floor: {scope: "all_models", min_percent: 50}}' <<<"$SONNET"),$SOL]"
write_quota "[$(row all_models 40 "$THROUGH" 2.0)]"
write_pool 30
select_json
assert_equals openai-codex/gpt-6.1-sol "$(selected_model)" 'a profile floor below its minimum removes the candidate'
assert_contains "$(jq -r '.candidates[] | select(.harness == "claude") | .reason' <<<"$OUT")" 'profile floor all_models below 50%' 'the floor refusal is named'
SOL_FLOOR=$(jq -c '. + {floor: {scope: "all_models", min_percent: 50}}' <<<"$SOL")
write_rules "[$SOL_FLOOR,$SONNET]"
write_quota "[$(row all_models 94 "$THROUGH" 1.5)]"
write_pool 30
select_json
expect_code 0 "$CODE" 'a floored pool with headroom still selects the ranked candidate'
assert_equals claude-sonnet-5-5\[1m\] "$(selected_model)" 'a floored pool has no scalar and does not outrank a known one'
assert_equals true "$(jq '.candidates[] | select(.harness == "omp") | .eligible' <<<"$OUT")" 'a floor the pool cannot verify keeps a usable pool eligible'
assert_contains "$(jq -r .reason <<<"$OUT")" 'unranked, disclosed: omp:openai-codex/gpt-6.1-sol' 'the floored pool is disclosed beside the winner'
write_pool 0 0
select_json
expect_code 0 "$CODE" 'an exhausted floored pool does not block the ranked candidate'
assert_equals claude-sonnet-5-5\[1m\] "$(selected_model)" 'the ranked candidate is selected'
assert_equals false "$(jq '.candidates[] | select(.harness == "omp") | .eligible' <<<"$OUT")" 'an exhausted pool is not eligible even when its floor is unverifiable'
assert_equals false "$(jq '.candidates[] | select(.harness == "omp") | .exhausted' <<<"$OUT")" 'an unverifiable floor does not prove exhaustion'
assert_not_contains "$(jq -r .reason <<<"$OUT")" 'gpt-6.1-sol' 'an exhausted pool is not disclosed as a candidate'
write_rules "$DEFAULT_USE" "[$DEEPSEEK]"
write_pool 30
printf 'omp-or-tc\n' > "$HOME_DIR/config/session-launch-policy"
write_quota "[$(row all_models 94 "$THROUGH" 1.5)]"
select_json
assert_equals openai-codex/gpt-6.1-sol "$(selected_model)" 'the session launch policy removes a harness it refuses'
assert_contains "$(jq -r '.candidates[] | select(.harness == "claude") | .reason' <<<"$OUT")" 'session launch policy refuses harness claude' 'the policy refusal is named'
rm -f "$HOME_DIR/config/session-launch-policy"
pass 'floors and the launch policy gate eligibility'

# ---- model index: retired id is an error, an absent catalog id removes the candidate ----
write_quota "[$(row all_models 94 "$THROUGH" 1.5)]"
write_pool 50
printf '%s\n' '{"version":1,"roles":{"review":{"claude":{"model":"claude-sonnet-5-5[1m]"},"omp":{"model":"openai-codex/gpt-6.1-sol"}}},"retired":[]}' \
  > "$HOME_DIR/config/model-index.json"
printf '%s\n' '{"models":[{"id":"some-other-model"}]}' > "$CATALOGS/claude.json"
printf '%s\n' '{"models":[{"id":"openai-codex/gpt-6.1-sol"}]}' > "$CATALOGS/omp.json"
EXTRA_ENV=(FM_MODEL_CATALOG_DIR="$CATALOGS")
select_json
expect_code 0 "$CODE" 'catalog refusal still selects another candidate'
assert_equals openai-codex/gpt-6.1-sol "$(selected_model)" 'an id absent from its catalog is not selected'
assert_contains "$(jq -r '.candidates[] | select(.harness == "claude") | .reason' <<<"$OUT")" 'model index refuses claude claude-sonnet-5-5[1m]' 'the catalog refusal is named'
printf '%s\n' '{"models":[{"id":"claude-sonnet-5-5[1m]"}]}' > "$CATALOGS/claude.json"
select_json
assert_equals claude-sonnet-5-5\[1m\] "$(selected_model)" 'a catalog id keeps the candidate'
printf '%s\n' '{"version":1,"roles":{},"retired":["claude-sonnet-5-5"]}' > "$HOME_DIR/config/model-index.json"
select_run --dry-run
expect_code 2 "$CODE" 'a retired id in the rules is a configuration error'
assert_equals '' "$OUT" 'a retired id selects nothing'
assert_contains "$(cat "$ERR")" 'model index/profile resolution failed' 'the retirement error is named'
rm -f "$HOME_DIR/config/model-index.json"
EXTRA_ENV=(FM_SELECT_TEST=1)
pass 'the model index refuses retired and catalog-absent ids'

# ---- malformed configuration: an actionable error, never selected around -------------
assert_error() {  # <label> <stderr needle> <args...>
  local label=$1 needle=$2
  shift 2
  select_run "$@"
  expect_code 2 "$CODE" "$label"
  assert_equals '' "$OUT" "$label prints no selection"
  assert_contains "$(cat "$ERR")" "$needle" "$label names the problem"
}
write_rules "$DEFAULT_USE" "[$DEEPSEEK]"
write_quota "[$(row all_models 94 "$THROUGH" 1.5)]"
write_pool 52
assert_error 'a run without --dry-run' 'pass --dry-run' --log
assert_error 'an unknown flag' 'unknown argument' --dry-run --frobnicate
printf '%s\n' '{"rules": [' > "$RULES"
assert_error 'rules that are not JSON' 'malformed rules file' --dry-run
rm -f "$RULES"
assert_error 'an absent rules file' 'rules file not readable' --dry-run
write_rules "[$(jq -c 'del(.model)' <<<"$SONNET"),$SOL]"
assert_error 'a candidate with no model' 'needs an explicit model' --dry-run
write_rules "[$(jq -c '.effort = "hgih"' <<<"$SONNET"),$SOL]"
assert_error 'a candidate with an unknown effort' 'effort must be one of low, medium, high, xhigh, max' --dry-run
write_rules "[$(jq -c '.effort = ""' <<<"$SONNET"),$SOL]"
assert_error 'a candidate with an empty effort' 'effort must be one of low, medium, high, xhigh, max' --dry-run
write_rules "[{\"harness\":\"codex\",\"model\":\"gpt-6.1-sol\",\"effort\":\"high\"},$SOL]"
assert_error 'a harness with no review agent' 'no no-mistakes review agent' --dry-run
write_rules "[$SOL,$SOL]"
assert_error 'duplicate profiles' 'duplicate harness, model, and effort' --dry-run
write_rules '[]'
assert_error 'an empty use list' 'no use profiles' --dry-run
write_rules "$DEFAULT_USE" '[{"harness":"codex","model":"x","effort":"high"}]'
assert_error 'an invalid fallback' 'fallback must be an array' --dry-run
write_rules "[$(jq -c '. + {floor: {scope: "all_models", min_percent: 500}}' <<<"$SONNET"),$SOL]"
assert_error 'a floor outside 0..100' 'floor needs scope, min_percent 0..100' --dry-run
write_rules "[$(jq -c '. + {provider: "Not A Provider"}' <<<"$SONNET"),$SOL]"
assert_error 'a malformed provider id' 'provider must match' --dry-run
write_rules "[$(jq -c '.harness = "omp" | .model = "xai/grok-9"' <<<"$SONNET"),$SOL]"
assert_error 'an omp candidate with no provider family' 'declare provider' --dry-run
write_rules "$DEFAULT_USE"
jq '.rules += [.rules[1]]' "$RULES" > "$RULES.tmp" && mv "$RULES.tmp" "$RULES"
assert_error 'two matching review rules' 'more than one rule starts with' --dry-run
write_rules "$DEFAULT_USE"
jq '.rules[1].when = "Something else entirely."' "$RULES" > "$RULES.tmp" && mv "$RULES.tmp" "$RULES"
assert_error 'no review rule' 'no rule whose when starts with' --dry-run
write_rules "$DEFAULT_USE"
EXTRA_ENV=(FAKE_QUOTA_FAIL=1)
assert_error 'a quota-axi failure' 'quota-axi --json failed' --dry-run
EXTRA_ENV=(FM_SELECT_TEST=1)
printf '%s\n' '{"schemaVersion":5,"providers":[{"provider":"claude"}]}' > "$QUOTA"
assert_error 'an invalid quota snapshot' 'invalid snapshot' --dry-run
pass 'malformed configuration and evidence report an error and select nothing'

# ---- the evidence log: one line per run, errors included, nothing else written --------
write_quota "[$(row all_models 94 "$THROUGH" 1.5)]"
write_pool 52
rm -f "$LOG"
select_run --dry-run --log
expect_code 0 "$CODE" 'a logged run selects'
select_run --dry-run --log
write_quota "[$(row all_models 5 "$SHORT" 0.1)]"
select_run --dry-run --log
printf '%s\n' '{"rules": [' > "$RULES"
select_run --dry-run --log
expect_code 2 "$CODE" 'a logged configuration error exits 2'
assert_equals 4 "$(wc -l < "$LOG" | tr -d ' ')" 'each logged run appends exactly one line'
assert_equals '' "$(jq -rs 'map(select(.schema != "fm-review-agent-select.v1" or .mode != "dry-run" or (.at | type) != "number")) | .[]' "$LOG")" \
  'every record carries schema, mode, and time'
assert_equals 'selected selected selected error' "$(jq -rs 'map(.status) | join(" ")' "$LOG")" 'statuses are recorded in order'
assert_equals claude-sonnet-5-5\[1m\] "$(jq -rs '.[0].selected.model' "$LOG")" 'the first record holds the choice'
assert_equals openai-codex/gpt-6.1-sol "$(jq -rs '.[2].selected.model' "$LOG")" 'the third record holds the tight-pool choice'
assert_contains "$(jq -rs '.[3].reason' "$LOG")" 'malformed rules file' 'the error record holds its reason'
extra=''
for entry in "$HOME_DIR/state"/* "$HOME_DIR/state"/.[!.]*; do
  [ -e "$entry" ] || continue
  [ "${entry##*/}" = review-agent-select.jsonl ] || extra="$extra ${entry##*/}"
done
assert_equals '' "$extra" 'the log is the only file written to state'
assert_equals "$before" "$(cksum < "$NM_DIR/config.yaml")" 'the no-mistakes config is still untouched'
assert_present "$NM_DIR/config.yaml" 'the live config is still present'
pass 'every logged run appends one record and nothing else is written'

# ---- help -----------------------------------------------------------------------------
select_run --help
expect_code 0 "$CODE" '--help exits 0'
assert_contains "$OUT" 'Usage: fm-review-agent-select.sh --dry-run' '--help prints the usage'
pass '--help prints the header'

printf '# all fm-review-agent-select tests passed\n'
