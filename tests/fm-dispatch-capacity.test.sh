#!/usr/bin/env bash
# Pooled capacity, uncertainty, explicit fallback permission, and account pins.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dispatch-capacity-lib.sh
. "$ROOT/bin/fm-dispatch-capacity-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-capacity)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$TMP_ROOT/config"
export FM_HOME="$TMP_ROOT" FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
export OMP_USAGE_FIXTURE="$TMP_ROOT/usage.json" QUOTA_FIXTURE="$TMP_ROOT/quota.json"
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN BACKEND TMUX
export FM_BACKEND=tmux
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  usage)
    if [ -n "${OMP_AUTH_SELECTOR:-}" ]; then
      value=${!OMP_AUTH_SELECTOR:-}
      [ "$OMP_AUTH_SELECTOR" != OMP_PROFILE ] || value=${OMP_PROFILE-${PI_PROFILE:-}}
      if [ "$value" = "$OMP_AUTH_EXHAUSTED_VALUE" ]; then
        cat "$OMP_AUTH_EXHAUSTED_FIXTURE"
        exit
      fi
    fi
    cat "$OMP_USAGE_FIXTURE" ;;
  models) printf '%s\n' '{"models":[{"selector":"openrouter/z-ai/glm-5.3-flash"},{"selector":"openrouter/deepseek/deepseek-v4-flash"}]}' ;;
  *) exit 2 ;;
esac
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN/omp" "$FAKEBIN/quota-axi"
export PATH="$FAKEBIN:$PATH"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  show-environment)
    [ "${FM_FAKE_TMUX_UNREADABLE:-0}" != 1 ] || exit 1
    if { [ "$2" = -g ] && [ "$#" = 2 ]; } || { [ "$2" = -t ] && [ "$#" = 3 ]; }; then exit 0; fi
    if [ "$2" = -t ]; then
      file="$FM_HOME/tmux-session-env"
      [ "$3" != recorded ] || file="$FM_HOME/tmux-recorded-env"
    else
      file="$FM_HOME/tmux-global-env"
    fi
    [ -f "$file" ] || exit 1
    name=${!#}
    while IFS= read -r entry; do
      case "$entry" in "$name="*|"-$name") printf '%s\n' "$entry"; exit 0 ;; esac
    done < "$file"
    exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"
write_pool() {
  jq -n --argjson at "$(date +%s)" --argjson remaining "$1" '
    {reports: [
      {provider:"openai-codex", fetchedAt:($at*1000),
       metadata:{meterStates:{chat:{allowed:false,limitReached:true}}},
       limits:[{scope:{shared:true},amount:{unit:"percent",remaining:0}}], resetCredits:{availableCount:1}},
      {provider:"openai-codex", fetchedAt:($at*1000),
       limits:[{scope:{shared:true},amount:{unit:"percent",remaining:$remaining}}]}
    ]}' > "$OMP_USAGE_FIXTURE"
}
write_pool 98
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
assert_equals usable "$(jq -r .status <<<"$out")" "an exhausted account must not exhaust the pool"
assert_equals 1 "$(jq -r '.accounts[0].savedResets' <<<"$out")" "saved resets remain reported rather than redeemed"
assert_not_contains "$out" '@' "public evidence must not expose account identities"
write_pool 0
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol)
assert_equals exhausted "$(jq -r .status <<<"$out")" "a saved reset is not current headroom"
jq '.accountsWithoutUsage=[{provider:"openai-codex"}]' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/missing.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/missing.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "an unmeasured sibling prevents whole-pool exhaustion"
jq '.reports[1].fetchedAt=0' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/stale.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/stale.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "stale quota is not an exhaustion verdict"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol '{')
assert_equals unknown "$(jq -r .status <<<"$out")" "invalid vendor JSON does not authorize fallback"
jq '.reports[1].metadata={meterStates:{chat:{allowed:true,limitReached:false}}}' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/serving.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/serving.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "a serving verdict remains authoritative even with zero percentage"
pass "pool capacity preserves serving, missing-account, freshness, and saved-reset semantics"

write_model_pool() {
  jq -n --argjson at "$(date +%s)" --argjson chat "$1" --argjson spark "$2" --arg plan "$3" '
    {reports:[{provider:"openai-codex",fetchedAt:($at*1000),
      metadata:{planType:$plan,meterStates:{
        chat:{allowed:($chat>0),limitReached:($chat<=0)},
        spark:{allowed:($spark>0),limitReached:($spark<=0)}}},
      limits:[
        {id:"openai-codex:primary",scope:{shared:true},amount:{unit:"percent",remaining:$chat}},
        {id:"openai-codex:secondary",scope:{shared:true},amount:{unit:"percent",remaining:$chat}},
        {id:"openai-codex:spark:primary",scope:{tier:"spark",modelId:"GPT-5.3-Codex-Spark"},
         amount:{unit:"percent",remaining:$spark}},
        {id:"openai-codex:review:primary",scope:{tier:"review",modelId:"gpt-6.1-sol"},
         status:"exhausted",amount:{unit:"percent",remaining:0}}]}]}' > "$OMP_USAGE_FIXTURE"
}
for chat in 0 80; do
  if [ "$chat" = 0 ]; then spark=80; chat_status=exhausted; spark_status=usable
  else spark=0; chat_status=usable; spark_status=exhausted; fi
  write_model_pool "$chat" "$spark" pro
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
  assert_equals "$chat_status" "$(jq -r .status <<<"$out")" "chat only consumes its native primary and secondary meters"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-5.3-codex-spark --json)
  assert_equals "$spark_status" "$(jq -r .status <<<"$out")" "Spark uses native display-name windows rather than chat"
  jq '(.reports[].limits[]) |= del(.id)' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/scoped.json"
  out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$TMP_ROOT/scoped.json")")
  assert_equals "$spark_status" "$(jq -r .status <<<"$out")" "explicit Spark tier scopes display-name limits without native IDs"
done
write_model_pool 80 80 pro
jq '.reports[0].metadata |= del(.meterStates.spark) |
  .reports[0].limits |= map(select(.scope.tier != "spark"))' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/no-spark.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$TMP_ROOT/no-spark.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "missing Spark evidence never borrows the healthy chat meter"
jq '.reports[0].metadata={planType:"pro",allowed:false,limitReached:true}' "$TMP_ROOT/no-spark.json" > "$TMP_ROOT/chat-negative.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$TMP_ROOT/chat-negative.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "missing Spark evidence never borrows exhausted broad chat metadata"
pass "model-scoped native and explicit-tier meters stay independent"

for plan in pro ' ChatGPT-Pro ' CHATGPT_PRO plus business team enterprise edu education teacher teachers health gov government prolite pro_lite 'ChatGPT Pro-Lite' free go mystery ''; do
  case "$plan" in
    pro|' ChatGPT-Pro '|CHATGPT_PRO) paid_status=usable; spark_status=usable ;;
    free|go) paid_status=exhausted; spark_status=exhausted ;;
    mystery|'') paid_status=unknown; spark_status=unknown ;;
    *) paid_status=usable; spark_status=exhausted ;;
  esac
  write_model_pool 80 80 "$plan"
  for model in gpt-5.6 gpt-5.6-sol gpt-5.6-sol-pro gpt-5.6-luna gpt-5.6-luna-pro; do
    out=$(fm_omp_codex_capacity "openai-codex/$model")
    assert_equals "$paid_status" "$(jq -r .status <<<"$out")" "$plan entitlement is respected for $model"
    if [ "$paid_status" = exhausted ]; then
      assert_equals ineligible "$(jq -r '.accounts[0].status' <<<"$out")" "a known free account is excluded rather than unmeasured"
    fi
  done
  out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark)
  assert_equals "$spark_status" "$(jq -r .status <<<"$out")" "$plan entitlement is respected for Pro-only Spark"
  for model in gpt-6.1-sol gpt-5.6-terra gpt-5.6-sol-fast; do
    out=$(fm_omp_codex_capacity "openai-codex/$model")
    assert_equals usable "$(jq -r .status <<<"$out")" "$model must not inherit an unlisted plan requirement"
  done
done
write_model_pool 0 80 pro
jq '.reports += [(.reports[0] | .metadata.planType="plus" |
  .metadata.meterStates.spark={allowed:true,limitReached:false})]' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/ineligible-sibling.json"
jq '.reports[0].metadata.meterStates.spark={allowed:false,limitReached:true} |
  (.reports[0].limits[] | select(.scope.tier=="spark").amount.remaining)=0' "$TMP_ROOT/ineligible-sibling.json" > "$TMP_ROOT/entitled-pool.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$TMP_ROOT/entitled-pool.json")")
assert_equals exhausted "$(jq -r .status <<<"$out")" "a usable but ineligible paid sibling cannot revive the Spark pool"
jq '.reports[1].metadata.planType="mystery"' "$TMP_ROOT/entitled-pool.json" > "$TMP_ROOT/unknown-plan.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$TMP_ROOT/unknown-plan.json")")
assert_equals unknown "$(jq -r .status <<<"$out")" "unknown entitlement cannot prove whole-pool exhaustion"
for plan in plus mystery pro; do
  jq --arg plan "$plan" '.reports |= [.[0]] |
    .accountsWithoutUsage=[{provider:"openai-codex",metadata:{planType:$plan}}]' "$TMP_ROOT/entitled-pool.json" > "$TMP_ROOT/missing-plan.json"
  out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$TMP_ROOT/missing-plan.json")")
  if [ "$plan" = plus ]; then expected=exhausted; else expected=unknown; fi
  assert_equals "$expected" "$(jq -r .status <<<"$out")" "$plan unmeasured sibling respects entitlement exclusion"
done
pass "native plan requirements exclude known ineligible accounts and preserve unknown eligibility"

for tier in chat spark; do
  for current in absent positive exhausted zero warning; do
    jq -n --argjson at "$(date +%s)" --arg tier "$tier" --arg current "$current" '
      {reports:[{provider:"openai-codex",fetchedAt:(($at-10)*1000),
        metadata:{planType:"pro",meterStates:{($tier):{allowed:false,limitReached:true}}},
        limits:([{id:("openai-codex:"+(if $tier=="spark" then "spark:" else "" end)+"primary"),
          scope:{tier:$tier},window:{resetsAt:(($at-1)*1000)},
          status:"exhausted",amount:{unit:"percent",remaining:0}}] +
          if $current=="absent" then [] else
            [{id:("openai-codex:"+(if $tier=="spark" then "spark:" else "" end)+"secondary"),
              scope:{tier:$tier},window:{resetsAt:(($at+1000)*1000)},
              status:(if $current=="exhausted" then "exhausted" elif $current=="warning" then "warning" else "ok" end),
              amount:{unit:"percent",remaining:(if $current=="positive" then 80 else 0 end)}}] end)}]}' > "$OMP_USAGE_FIXTURE"
    if [ "$tier" = spark ]; then model=gpt-5.3-codex-spark; else model=gpt-6.1-sol; fi
    if [ "$current" = exhausted ] || [ "$current" = zero ]; then expected=exhausted; else expected=unknown; fi
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model "openai-codex/$model" --json)
    assert_equals "$expected" "$(jq -r .status <<<"$out")" "$tier expired exhaustion with $current current bound must not invent renewed capacity"
    if [ "$current" = absent ]; then
      assert_equals null "$(jq -r '.accounts[0].remaining' <<<"$out")" "obsolete exhaustion is removed from remaining evidence"
    elif [ "$current" = positive ]; then
      assert_equals 80 "$(jq -r '.accounts[0].remaining' <<<"$out")" "remaining evidence omits the obsolete zero window"
    fi
  done
  jq '.reports[0].fetchedAt=.reports[0].limits[0].window.resetsAt' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/post-reset.json"
  out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$TMP_ROOT/post-reset.json")")
  assert_equals exhausted "$(jq -r .status <<<"$out")" "$tier a snapshot fetched at reset retains its fresh rejection"
  jq --argjson at "$(date +%s)" '.reports[0].limits[0].window.resetsAt=(($at+1000)*1000)' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/future-reset.json"
  out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$TMP_ROOT/future-reset.json")")
  assert_equals exhausted "$(jq -r .status <<<"$out")" "$tier a future reset retains measured exhaustion"
done
pass "reset-crossed snapshots invalidate meter verdicts without inferring replenished quota"

for source in ratelimit-headers usage-endpoint; do
  for current in warning positive exhausted; do
    jq -n --argjson at "$(date +%s)" --arg source "$source" --arg current "$current" '
      {reports:[{provider:"openai-codex",fetchedAt:($at*1000),
        metadata:{planType:"pro",source:$source,headersUpdatedAt:($at*1000),
          meterStates:{chat:{allowed:false,limitReached:true},spark:{allowed:false,limitReached:true}}},
        limits:[
          {id:"openai-codex:primary",status:(if $current=="warning" then "warning" elif $current=="positive" then "ok" else "exhausted" end),
            window:{resetsAt:(($at+1000)*1000)},
            amount:{unit:"percent",remaining:(if $current=="positive" then 80 else 0 end)}},
          {id:"openai-codex:spark:primary",scope:{tier:"spark"},status:"exhausted",
            window:{resetsAt:(($at-1)*1000)},amount:{unit:"percent",remaining:0}}]}]}' > "$OMP_USAGE_FIXTURE"
    if [ "$current" = exhausted ]; then expected=exhausted; else expected=usable; fi
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
    assert_equals "$expected" "$(jq -r .status <<<"$out")" "merged $source chat $current supersedes retained meter verdicts"
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-5.3-codex-spark --json)
    assert_equals unknown "$(jq -r .status <<<"$out")" "chat ingestion cannot re-date retained Spark exhaustion"
    assert_equals null "$(jq -r '.accounts[0].remaining' <<<"$out")" "retained Spark limits have no current measurement provenance"
  done
done
jq '.reports[0].limits[0].status="warning" |
  .reports[0].limits += [{id:"openai-codex:secondary",status:"exhausted",amount:{unit:"percent",remaining:0}}]' \
  "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/partial-headers.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/partial-headers.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "a current successful zero-percent header supersedes an untouched exhausted chat window"
pass "merged native reports preserve current chat serving evidence without refreshing Spark provenance"

primary='{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high"}'
allowed='[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"}]'
jq -n --argjson use "$primary" --argjson fallback "$allowed" '{rules:[{when:"easy work",use:$use,fallback:$fallback}],default:$use,default_fallback:$fallback}' > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high)
write_pool 98
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$(jq -c .fallback <<<"$set")")
assert_equals openai-codex/gpt-6-luna "$(jq -r .profile.model <<<"$out")" "native pooled capacity precedes paid model fallback"
write_pool 0
jq '.reports[1].metadata={source:"ratelimit-headers"} |
  .reports[1].limits[0].status="warning"' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/headers.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/headers.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "native successful-response warnings do not authorize paid model fallback from zero percent"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed")
assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r .profile.model <<<"$out")" "whole-pool exhaustion selects the permitted Luna stand-in"
assert_equals true "$(jq -r .switched <<<"$out")" "selection reports a model switch"
assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "unknown fallback quota is disclosed, never invented"
if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" '[]' > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "a route with no permitted stand-in must stop"
fi
strong='{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}'
team='[{"harness":"claude","model":"claude-opus-5-5[1m]","effort":"high","requires":"teamclaude"}]'
# A bare Claude executable is not the required configured TeamClaude route,
# whether or not the separate launch-owner library has landed.
if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$strong" "$team" > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "bare Claude must not impersonate the supported TeamClaude route"
fi
write_pool 98
jq '.rules[0].fallback=[]' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/conflicting.json"
mv "$TMP_ROOT/conflicting.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" '' omp openai-codex/gpt-6-luna high > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "different lists require an explicit rule rather than an arbitrary match"
fi
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high)
assert_equals '[]' "$(jq -c .fallback <<<"$set")" "an explicit rule retains its own no-fallback policy"
jq '.rules[0].fallback=[{harness:"claude",model:"opus",effort:"high"}]' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/bad.json"
mv "$TMP_ROOT/bad.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "Claude fallback without a supported TeamClaude requirement must refuse"
fi
pass "matrix fallback retains per-rule permission and strongest-model boundaries"

write_pool 0
export OMP_AUTH_EXHAUSTED_FIXTURE="$TMP_ROOT/auth-exhausted.json"
cp "$OMP_USAGE_FIXTURE" "$OMP_AUTH_EXHAUSTED_FIXTURE"
write_pool 98
for selector in HOME PI_CODING_AGENT_DIR PI_CONFIG_DIR OMP_PROFILE PI_PROFILE XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME; do
  export OMP_AUTH_SELECTOR="$selector" OMP_AUTH_EXHAUSTED_VALUE="$TMP_ROOT/exhausted-scope"
  case "$selector" in OMP_PROFILE|PI_PROFILE) export OMP_AUTH_EXHAUSTED_VALUE=exhausted-profile ;; esac
  out=$(env "$selector=$OMP_AUTH_EXHAUSTED_VALUE" "$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
  assert_equals usable "$(jq -r .status <<<"$out")" "caller-only $selector must not select the worker's authentication"
  printf '%s=%s\n' "$selector" "$OMP_AUTH_EXHAUSTED_VALUE" > "$TMP_ROOT/tmux-global-env"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "destination $selector exhaustion must authorize declared fallback"
  printf -- '-%s\n' "$selector" > "$TMP_ROOT/tmux-session-env"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed")
  assert_equals false "$(jq -r .switched <<<"$out")" "session removal must override global $selector"
  printf '%s=%s\n' "$selector" "$OMP_AUTH_EXHAUSTED_VALUE" > "$TMP_ROOT/tmux-session-env"
  printf '# filtered selectors\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config")
  if [ "$selector" = HOME ]; then expected=exhausted; else expected=usable; fi
  assert_equals "$expected" "$(jq -r .status <<<"$out")" "$selector must follow launch filtering and the HOME floor"
  printf '%s\n' "$selector" > "$TMP_ROOT/config/launch-env-allowlist"
  out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config")
  assert_equals exhausted "$(jq -r .status <<<"$out")" "retained destination $selector must measure its own pool"
  rm "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/config/launch-env-allowlist"
done
export OMP_AUTH_SELECTOR=OMP_PROFILE OMP_AUTH_EXHAUSTED_VALUE=exhausted-profile
printf 'PI_PROFILE=exhausted-profile\n' > "$TMP_ROOT/tmux-global-env"
printf 'OMP_PROFILE=\n' > "$TMP_ROOT/tmux-session-env"
out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config")
assert_equals usable "$(jq -r .status <<<"$out")" "explicit empty OMP_PROFILE must override the legacy PI_PROFILE"
printf -- '-OMP_PROFILE\n' > "$TMP_ROOT/tmux-session-env"
out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config")
assert_equals exhausted "$(jq -r .status <<<"$out")" "removed OMP_PROFILE must allow destination PI_PROFILE selection"
rm "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/tmux-session-env"
unset OMP_AUTH_SELECTOR OMP_AUTH_EXHAUSTED_VALUE OMP_AUTH_EXHAUSTED_FIXTURE
for scope in adopted unreadable daemon; do
  case "$scope" in
    adopted) out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config" recorded:fm-existing.0) ;;
    unreadable) out=$(FM_FAKE_TMUX_UNREADABLE=1 fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config") ;;
    daemon) out=$(BACKEND=herdr fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config") ;;
  esac
  assert_equals unknown "$(jq -r .status <<<"$out")" "$scope authentication must not borrow caller capacity"
  assert_contains "$(jq -r .reason <<<"$out")" 'authentication scope' "unknown capacity must disclose its binding limitation"
done
pass "OMP pooled measurements bind destination selectors, profile emptiness, and launch filtering"

for container in scalar array; do
  for use in '{"harness":"claude"}' '{"harness":"claude","model":"","effort":""}' '{"harness":"claude","model":"default","effort":"default"}'; do
    jq -n --argjson use "$use" --arg container "$container" --argjson fallback "$allowed" '
      (if $container == "array" then [$use] else $use end) as $profiles |
      {rules:[{when:"default axes",use:$profiles,fallback:$fallback}],
       default:$profiles,default_fallback:$fallback}' > "$TMP_ROOT/config/crew-dispatch.json"
    for rule in rule_1 default; do
      for model in '' default; do
        for effort in '' default; do
          set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" "$rule" claude "$model" "$effort") ||
            fail "default axes must match $rule $container use"
          assert_equals "$rule" "$(jq -r .rule <<<"$set")" "default matching retains explicit rule identity"
          assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "default matching retains declared fallback"
          profile=$(jq -cn --arg model "$model" --arg effort "$effort" '{harness:"claude",model:$model,effort:$effort}')
          out=$(fm_dispatch_select "$TMP_ROOT/config" "$rule" "$profile" "$(jq -c .fallback <<<"$set")" '{"status":"unknown"}') ||
            fail "a matched default profile with unknown capacity must remain launchable"
          assert_equals false "$(jq -r .switched <<<"$out")" "unknown capacity must retain default profile"
          assert_equals "$profile" "$(jq -c .profile <<<"$out")" "matching must not rewrite launch profile"
        done
      done
    done
    set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" '' claude default '') ||
      fail "identical fallback lists must match normalized implicit defaults"
    assert_equals '' "$(jq -r .rule <<<"$set")" "identical rule/default lists do not invent a rule"
  done
done
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 claude sonnet default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "a nondefault model must not match an omitted model"
fi
assert_contains "$(cat "$TMP_ROOT/error")" 'dispatch rule does not contain the requested profile' "unmatched profile remains a rule-membership failure"
jq -n --argjson fallback "$allowed" '
  {rules:[{use:{harness:"claude"},fallback:$fallback}],default:{harness:"claude"},default_fallback:[]}' > "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" '' claude default default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "normalization must not conceal conflicting fallback permissions"
fi
assert_contains "$(cat "$TMP_ROOT/error")" 'different fallback lists match this profile' "normalized implicit ambiguity still requires a rule"
jq -n '{rules:[{use:{harness:"omp",model:"openai-codex/gpt-6-luna",effort:"high"},
  fallback:[{harness:"omp",model:"default",effort:"high"}]}]}' > "$TMP_ROOT/config/crew-dispatch.json"
for model in '' default; do
  set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp "$model" high) ||
    fail "fallback comparisons must normalize default model representations"
  assert_equals rule_1 "$(jq -r .rule <<<"$set")" "a default fallback remains a member of its rule"
done
jq '.rules[0].fallback[0].effort="default"' "$TMP_ROOT/config/crew-dispatch.json" > "$TMP_ROOT/bad-default.json"
mv "$TMP_ROOT/bad-default.json" "$TMP_ROOT/config/crew-dispatch.json"
if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp default default > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "normalization must not turn invalid fallback effort into a valid profile"
fi
assert_contains "$(cat "$TMP_ROOT/error")" 'fallback must be an array of explicit OMP profiles' "invalid fallback differs from an unmatched valid profile"
pass "shared matching normalizes default axes without weakening fallback validation"

cat > "$QUOTA_FIXTURE" <<'JSON'
{"schemaVersion":6,"providers":[
 {"provider":"claude","accountKey":"other","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0}]}},
 {"provider":"claude","accountKey":"default","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70}]}}
]}
JSON
out=$(fm_dispatch_capacity claude claude-sonnet-5-5)
assert_equals usable "$(jq -r .status <<<"$out")" "another Claude account must not veto the selected default"
printf 'pinned-account\n' > "$TMP_ROOT/config/claude-account"
out=$(fm_dispatch_capacity claude claude-sonnet-5-5)
assert_equals unknown "$(jq -r .status <<<"$out")" "a pin without established quota mapping is not inferred"
rm "$TMP_ROOT/config/claude-account"
jq '(.providers[] | select(.accountKey=="default").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)=0' "$QUOTA_FIXTURE" > "$TMP_ROOT/native-claude-zero.json"
mv "$TMP_ROOT/native-claude-zero.json" "$QUOTA_FIXTURE"
native_primary='{"harness":"claude","model":"claude-sonnet-5-5","effort":"high"}'
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "native default exhaustion remains measured without alternate auth"
out=$(FM_FAKE_TMUX_UNREADABLE=1 "$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals unknown "$(jq -r .status <<<"$out")" "unavailable tmux destination does not establish native authentication"
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "readable empty destination restores measured native exhaustion"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
assert_equals true "$(jq -r .switched <<<"$out")" "native default exhaustion authorizes a permitted fallback"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/alternate-claude"
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals unknown "$(jq -r .status <<<"$out")" "ambient alternate authentication must not inherit default exhaustion"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
assert_equals false "$(jq -r .switched <<<"$out")" "ambient alternate authentication must not switch on unrelated default exhaustion"
assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "alternate-auth uncertainty retains the original profile"
export CLAUDE_CONFIG_DIR=''
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "an empty forwarded auth directory is still native default authentication"
unset CLAUDE_CONFIG_DIR
for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  export "$credential=retained-routing-fixture"
  printf '%s=retained-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  for forwarding in ambient allowlisted; do
    if [ "$forwarding" = allowlisted ]; then
      printf '%s\n' "$credential" > "$TMP_ROOT/config/launch-env-allowlist"
    fi
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
    assert_equals unknown "$(jq -r .status <<<"$out")" "$forwarding $credential must not inherit subscription exhaustion"
    out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
    assert_equals false "$(jq -r .switched <<<"$out")" "$forwarding $credential must retain the original route"
    assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "$forwarding $credential must not substitute a model"
  done
  printf '# no alternate API authentication\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "filtered $credential must not conceal real subscription exhaustion"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "filtered $credential permits the declared exhaustion fallback"
  printf '%s\n' "$credential" > "$TMP_ROOT/config/launch-env-allowlist"
  export "$credential="
  printf '%s=\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "an empty $credential is not alternate authentication"
  unset "$credential"
  rm "$TMP_ROOT/config/launch-env-allowlist"
  rm "$TMP_ROOT/tmux-session-env"
done
pass "capacity and selection bind API authentication only when actually retained"

for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; do
  printf '%s=global-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-global-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals false "$(jq -r .switched <<<"$out")" "destination global $credential must not inherit subscription exhaustion"
  printf '%s=session-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "destination session $credential is alternate authentication"
  printf -- '-%s\n' "$credential" > "$TMP_ROOT/tmux-recorded-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" "" recorded)
  assert_equals true "$(jq -r .switched <<<"$out")" "the explicit recorded session must override the current session's $credential"
  rm "$TMP_ROOT/tmux-recorded-env"
  printf -- '-%s\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "session removal of $credential must suppress the global credential"
  printf '%s=\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "empty session $credential must override the global credential"
  printf '%s=session-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  printf '# filter destination credentials\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed")
  assert_equals true "$(jq -r .switched <<<"$out")" "the allowlist must strip destination $credential"
  rm "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/config/launch-env-allowlist"
done
for credential in $FM_WORKER_ACCOUNT_CLAUDE_SHED CLAUDE_CONFIG_DIR; do
  value=destination-auth
  case "$credential" in CLAUDE_CODE_USE_*) value=1 ;; esac
  printf '%s=%s\n' "$credential" "$value" > "$TMP_ROOT/tmux-session-env"
  if [ "$credential" = ANTHROPIC_FEDERATION_RULE_ID ]; then
    printf 'ANTHROPIC_ORGANIZATION_ID=destination-org\n' >> "$TMP_ROOT/tmux-session-env"
  fi
  for backend_source in env config default; do
    unset FM_BACKEND BACKEND
    case "$backend_source" in
      env) export FM_BACKEND=tmux ;;
      config) printf 'tmux\n' > "$TMP_ROOT/config/backend" ;;
      default) rm -f "$TMP_ROOT/config/backend" ;;
    esac
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
    assert_equals unknown "$(jq -r .status <<<"$out")" "$backend_source backend retains destination $credential"
  done
  printf '%s\n' "$credential" ANTHROPIC_ORGANIZATION_ID > "$TMP_ROOT/config/launch-env-allowlist"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals unknown "$(jq -r .status <<<"$out")" "allowlist retains destination $credential"
  printf '# filtered\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "filter removes destination $credential"
  rm "$TMP_ROOT/config/launch-env-allowlist"
  case "$credential" in
    CLAUDE_CODE_USE_*)
      for value in 1 true yes on TrUe YeS ON; do
        printf '%s=%s\n' "$credential" "$value" > "$TMP_ROOT/tmux-session-env"
        out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
        assert_equals unknown "$(jq -r .status <<<"$out")" "enabled $credential=$value selects alternate auth"
      done
      for value in '' 0 false no off FALSE; do
        printf '%s=%s\n' "$credential" "$value" > "$TMP_ROOT/tmux-session-env"
        out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
        assert_equals exhausted "$(jq -r .status <<<"$out")" "disabled $credential=$value keeps native quota"
      done ;;
    ANTHROPIC_FEDERATION_RULE_ID)
      printf '%s=destination-rule\n' "$credential" > "$TMP_ROOT/tmux-session-env"
      out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
      assert_equals exhausted "$(jq -r .status <<<"$out")" "federation rule without organization does not select federation"
      ;;
  esac
  rm "$TMP_ROOT/tmux-session-env"
done
export ANTHROPIC_API_KEY=caller-only
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "caller-only key cannot reach tmux worker"
unset ANTHROPIC_API_KEY
printf '# filtered\n' > "$TMP_ROOT/config/launch-env-allowlist"
out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/explicit-root" "$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals unknown "$(jq -r .status <<<"$out")" "explicit caller root survives allowlist"
rm "$TMP_ROOT/config/launch-env-allowlist"
out=$(FM_BACKEND=herdr "$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals unknown "$(jq -r .status <<<"$out")" "unreadable daemon destination does not prove default auth"
pass "destination tmux credential layering respects removal, emptiness, and filtering"
for credential in absent present; do
  if [ "$credential" = present ]; then
    printf 'ANTHROPIC_API_KEY=new-session-key\n' > "$TMP_ROOT/tmux-recorded-env"
  fi
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" "" recorded:fm-existing.0)
  assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "an adopted shell cannot establish authentication from $credential session credentials"
  assert_equals false "$(jq -r .switched <<<"$out")" "session credential changes cannot authorize an adopted shell model switch"
  assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "unverifiable adopted authentication retains the route"
done
rm "$TMP_ROOT/tmux-recorded-env"
pass "adopted shell authentication remains uncertain across tmux environment changes"
printf 'teamclaude\n' > "$TMP_ROOT/config/claude-launcher"
out=$(fm_dispatch_capacity claude claude-opus-5-5)
assert_equals unknown "$(jq -r .status <<<"$out")" "native Claude's exhausted account is not the TeamClaude proxy's quota"
pass "capacity does not conflate default and pinned Claude accounts"
printf '# all fm-dispatch-capacity tests passed\n'
