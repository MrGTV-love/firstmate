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
export FM_FAKE_TMUX_HOME="$HOME"
cat > "$FAKEBIN/omp" <<'SH'
#!/usr/bin/env bash
OMP_USAGE_FIXTURE="${0%/*}/../usage.json"
[ ! -f "$PWD/.env" ] || . "$PWD/.env"
OMP_AUTH_EXHAUSTED_FIXTURE="${0%/*}/../auth-exhausted.json"
if [ -f "${0%/*}/auth-selector" ]; then
  IFS= read -r OMP_AUTH_SELECTOR < "${0%/*}/auth-selector"
  IFS= read -r OMP_AUTH_EXHAUSTED_VALUE < "${0%/*}/auth-value"
fi
case "$1" in
  usage)
    printf '%s\n' "$PWD" > "${0%/*}/../usage-process-cwd"
    if [ -n "${OMP_AUTH_SELECTOR:-}" ]; then
      value=${!OMP_AUTH_SELECTOR:-}
      [ "$OMP_AUTH_SELECTOR" != OMP_PROFILE ] || value=${OMP_PROFILE-${PI_PROFILE:-}}
      if [ "$value" = "$OMP_AUTH_EXHAUSTED_VALUE" ]; then
        cat "$OMP_AUTH_EXHAUSTED_FIXTURE"
        exit
      fi
    fi
    cat "$OMP_USAGE_FIXTURE" ;;
  models)
    printf '%s\n' "$PWD" > "${0%/*}/../catalog-process-cwd"
    if [ -f "$PWD/.omp/config.yml" ] &&
      jq -e '(.disabledProviders // []) | index("openrouter") != null' "$PWD/.omp/config.yml" >/dev/null; then
      printf '%s\n' '{"models":[]}'
      exit
    fi
    if [ -f "${0%/*}/catalog-codex" ]; then
      printf '%s\n' '{"models":[{"selector":"openai-codex/gpt-6.1-sol"}]}'
      exit
    fi
    if [ -f "${0%/*}/catalog-key" ]; then
      if [ "${OPENROUTER_API_KEY-unset}" = destination ]; then
        printf '%s\n' '{"models":[{"selector":"openrouter/z-ai/glm-5.3-flash"}]}'
      else
        printf '%s\n' '{"models":[{"selector":"openrouter/deepseek/deepseek-v4-flash"}]}'
      fi
    else
      printf '%s\n' '{"models":[{"selector":"openrouter/z-ai/glm-5.3-flash"},{"selector":"openrouter/deepseek/deepseek-v4-flash"}]}'
    fi ;;
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
  has-session)
    [ "${FM_TEST_TMUX_SERVER:-existing}" != existing-no-firstmate ] || [ "${!#}" = recorded ]
    exit $? ;;
  show-options)
    [ "${2:-}" = -gv ] && [ "${3:-}" = update-environment ] || exit 1
    printf '%s\n' "${FM_TEST_TMUX_UPDATE_ENVIRONMENT:-}"
    exit 0 ;;
  show-environment)
    [ "${FM_FAKE_TMUX_UNREADABLE:-0}" != 1 ] || exit 1
    if [ "$2" = -t ]; then
      [ "${FM_TEST_TMUX_SERVER:-existing}" != existing-no-firstmate ] || [ "$3" = recorded ] || exit 1
      file="$FM_HOME/tmux-session-env"
      [ "$3" != recorded ] || file="$FM_HOME/tmux-recorded-env"
    else
      file="$FM_HOME/tmux-global-env"
    fi
    if { [ "$2" = -g ] && [ "$#" = 2 ]; } || { [ "$2" = -t ] && [ "$#" = 3 ]; }; then
      if [ "$2" = -g ]; then
        printf 'HOME=%s\nPATH=%s\n' "$FM_FAKE_TMUX_HOME" "$PATH"
      fi
      [ ! -f "$file" ] || cat "$file"
      exit 0
    fi
    name=${!#}
    if [ -f "$file" ]; then
      while IFS= read -r entry; do
        case "$entry" in "$name="*|"-$name") printf '%s\n' "$entry"; exit 0 ;; esac
      done < "$file"
    fi
    if [ "$2" = -g ] && [ "$name" = PATH ]; then
      printf 'PATH=%s\n' "$PATH"
      exit 0
    fi
    if [ "$2" = -g ] && [ "$name" = HOME ] && [ -n "${FM_FAKE_TMUX_HOME:-}" ]; then
      printf 'HOME=%s\n' "$FM_FAKE_TMUX_HOME"
      exit 0
    fi
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
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$OMP_USAGE_FIXTURE")")
assert_equals usable "$(jq -r .status <<<"$out")" "an exhausted account must not exhaust the pool"
assert_equals 1 "$(jq -r '.accounts[0].savedResets' <<<"$out")" "saved resets remain reported rather than redeemed"
assert_not_contains "$out" '@' "public evidence must not expose account identities"
write_pool 0
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$OMP_USAGE_FIXTURE")")
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
  out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$OMP_USAGE_FIXTURE")")
  assert_equals "$chat_status" "$(jq -r .status <<<"$out")" "chat only consumes its native primary and secondary meters"
  out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$OMP_USAGE_FIXTURE")")
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

for tier in chat spark legacy; do
  for negative in denied reached both; do
    for current in absent healthy exhausted zero warning; do
      jq -n --argjson at "$(date +%s)" --arg tier "$tier" --arg negative "$negative" --arg current "$current" '
        (if $tier=="spark" then "spark" else "chat" end) as $scope |
        (if $negative=="denied" then {allowed:false}
         elif $negative=="reached" then {limitReached:true}
         else {allowed:false,limitReached:true} end) as $meter |
        {reports:[{provider:"openai-codex",fetchedAt:($at*1000),
          metadata:({planType:"pro"} + if $tier=="legacy" then $meter else {meterStates:{($scope):$meter}} end),
          limits:(if $current=="absent" then [] else
            [{scope:{tier:$scope},status:(if $current=="exhausted" then "exhausted" elif $current=="warning" then "warning" else "ok" end),
              amount:{unit:"percent",remaining:(if $current=="healthy" then 80 else 0 end)}}] end)}]}' > "$OMP_USAGE_FIXTURE"
      if [ "$tier" = spark ]; then model=gpt-5.3-codex-spark; else model=gpt-6.1-sol; fi
      case "$current" in absent) expected=unknown ;; exhausted|zero) expected=exhausted ;; *) expected=usable ;; esac
      out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$OMP_USAGE_FIXTURE")")
      assert_equals "$expected" "$(jq -r .status <<<"$out")" "$tier $negative shared flags require current scoped exhaustion with $current bounds"
      if [ "$expected" != exhausted ]; then
        selected=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 \
          "{\"harness\":\"omp\",\"model\":\"openai-codex/$model\",\"effort\":\"high\"}" \
          '[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"}]' "$out")
        assert_equals false "$(jq -r .switched <<<"$selected")" "$tier $negative shared flags with $current bounds cannot authorize a paid stand-in"
      fi
      jq --arg tier "$tier" '.reports += [(.reports[0] | .metadata={planType:"pro"} |
        .limits=[{scope:{tier:(if $tier=="spark" then "spark" else "chat" end)},amount:{unit:"percent",remaining:80}}])]' \
        "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/negative-healthy-sibling.json"
      out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$TMP_ROOT/negative-healthy-sibling.json")")
      assert_equals usable "$(jq -r .status <<<"$out")" "$tier ordinary healthy sibling wins over $negative shared flags and $current bounds"
    done
  done
done
for model in gpt-6.1-sol GPT-6.1-SOL; do
  for scope in gpt-6.1-sol GPT-6.1-SOL; do
    for tier in absent chat; do
      jq -n --argjson at "$(date +%s)" --arg scope "$scope" --arg tier "$tier" '
        {reports:[{provider:"openai-codex",fetchedAt:($at*1000),
          limits:[{scope:({modelId:$scope} + if $tier=="chat" then {tier:"chat"} else {} end),
            status:"exhausted",amount:{unit:"percent",remaining:0}}]}]}' > "$OMP_USAGE_FIXTURE"
      out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$OMP_USAGE_FIXTURE")")
      assert_equals exhausted "$(jq -r .status <<<"$out")" "$model matches explicit $tier scoped model ID $scope case-insensitively"
    done
  done
done
pass "shared negative flags require scoped exhaustion and explicit model scopes ignore ASCII casing"

for plan in pro ' ChatGPT-Pro ' CHATGPT_PRO plus business team enterprise edu education teacher teachers health gov government prolite pro_lite 'ChatGPT Pro-Lite' free go mystery ''; do
  case "$plan" in
    pro|' ChatGPT-Pro '|CHATGPT_PRO) paid_status=usable; spark_status=usable ;;
    free|go) paid_status=exhausted; spark_status=exhausted ;;
    mystery|'') paid_status=unknown; spark_status=unknown ;;
    *) paid_status=usable; spark_status=exhausted ;;
  esac
  write_model_pool 80 80 "$plan"
  for model in gpt-5.6 gpt-5.6-sol gpt-5.6-sol-pro gpt-5.6-luna gpt-5.6-luna-pro GPT-5.6 GPT-5.6-SOL GPT-5.6-SOL-PRO GPT-5.6-LUNA GPT-5.6-LUNA-PRO; do
    out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$OMP_USAGE_FIXTURE")")
    assert_equals "$paid_status" "$(jq -r .status <<<"$out")" "$plan entitlement is respected for $model"
    if [ "$paid_status" = exhausted ]; then
      assert_equals ineligible "$(jq -r '.accounts[0].status' <<<"$out")" "a known free account is excluded rather than unmeasured"
    fi
  done
  for model in gpt-5.3-codex-spark GPT-5.3-CODEX-SPARK; do
    out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$OMP_USAGE_FIXTURE")")
    assert_equals "$spark_status" "$(jq -r .status <<<"$out")" "$plan entitlement is respected for Pro-only $model"
  done
  for model in gpt-6.1-sol gpt-5.6-terra gpt-5.6-sol-fast; do
    out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$OMP_USAGE_FIXTURE")")
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
    out=$(fm_omp_codex_capacity "openai-codex/$model" "$(cat "$OMP_USAGE_FIXTURE")")
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
    out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$OMP_USAGE_FIXTURE")")
    assert_equals "$expected" "$(jq -r .status <<<"$out")" "merged $source chat $current supersedes retained meter verdicts"
    out=$(fm_omp_codex_capacity openai-codex/gpt-5.3-codex-spark "$(cat "$OMP_USAGE_FIXTURE")")
    assert_equals unknown "$(jq -r .status <<<"$out")" "chat ingestion cannot re-date retained Spark exhaustion"
    assert_equals null "$(jq -r '.accounts[0].remaining' <<<"$out")" "retained Spark limits have no current measurement provenance"
  done
done
for source in ratelimit-headers usage-endpoint; do
  for positive_window in primary secondary; do
    for positive in warning-zero warning-positive positive; do
      for negative in exhausted zero; do
        for representation in native scoped; do
          jq -n --argjson at "$(date +%s)" --arg source "$source" --arg window "$positive_window" \
            --arg positive "$positive" --arg negative "$negative" --arg representation "$representation" '
            {reports:[{provider:"openai-codex",fetchedAt:($at*1000),
              metadata:{source:$source,headersUpdatedAt:($at*1000)},
              limits:[
                {id:("openai-codex:"+$window),
                  status:(if $positive=="positive" then "ok" else "warning" end),
                  window:{resetsAt:(($at+1000)*1000)},
                  amount:{unit:"percent",remaining:(if $positive=="warning-zero" then 0 else 80 end)}},
                {id:("openai-codex:"+(if $window=="primary" then "secondary" else "primary" end)),
                  status:(if $negative=="exhausted" then "exhausted" else "ok" end),
                  window:{resetsAt:(($at+1000)*1000)},
                  amount:{unit:"percent",remaining:0}}]},
              {provider:"openai-codex",fetchedAt:($at*1000),
                limits:[{id:"openai-codex:primary",status:"exhausted",
                  window:{resetsAt:(($at+1000)*1000)},amount:{unit:"percent",remaining:0}}]}]} |
            if $representation=="scoped" then
              (.reports[].limits[]) |= (del(.id) | .scope={tier:"chat"})
            else . end' > "$TMP_ROOT/partial-headers.json"
          out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/partial-headers.json")")
          assert_equals unknown "$(jq -r .status <<<"$out")" "merged $source $representation $positive_window $positive cannot order a sibling $negative verdict"
          assert_equals unknown "$(jq -r '.accounts[0].status' <<<"$out")" "conflicting account evidence must remain unknown"
          assert_equals exhausted "$(jq -r '.accounts[1].status' <<<"$out")" "the other exhausted account cannot resolve conflicting provenance"
          out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 \
            '{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}' \
            '[{"harness":"omp","model":"openrouter/deepseek/deepseek-v4-flash","effort":"high"}]' "$out")
          assert_equals false "$(jq -r .switched <<<"$out")" "unordered conflicting evidence cannot authorize fallback"
          assert_equals openai-codex/gpt-6.1-sol "$(jq -r .profile.model <<<"$out")" "uncertain exhaustion must retain the primary model"
          jq 'del(.reports[0].metadata.headersUpdatedAt)' "$TMP_ROOT/partial-headers.json" > "$TMP_ROOT/unmerged-bounds.json"
          out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/unmerged-bounds.json")")
          assert_equals exhausted "$(jq -r .status <<<"$out")" "an unmerged $representation $negative bound remains authoritative beside $positive"
        done
      done
    done
  done
done
jq '.reports += [(.reports[0] | del(.metadata.headersUpdatedAt) |
  .limits=[{id:"openai-codex:primary",amount:{unit:"percent",remaining:80}}])]' \
  "$TMP_ROOT/partial-headers.json" > "$TMP_ROOT/healthy-sibling.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/healthy-sibling.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "a measured usable sibling keeps a conflicting account from parking the pool"
pass "merged native reports preserve uncertainty for conflicting window provenance"

for source in ratelimit-headers usage-endpoint; do
  for expired_window in primary secondary; do
    for fetched in at-reset after-reset; do
      for current in absent positive exhausted zero warning; do
        jq -n --argjson at "$(date +%s)" --arg source "$source" --arg window "$expired_window" \
          --arg fetched "$fetched" --arg current "$current" '
          {reports:[{provider:"openai-codex",
            fetchedAt:(($at - (if $fetched=="at-reset" then 10 else 0 end))*1000),
            metadata:{source:$source,headersUpdatedAt:($at*1000),
              meterStates:{chat:{allowed:false,limitReached:true}}},
            limits:([{id:("openai-codex:"+$window),status:"exhausted",
              window:{resetsAt:(($at-10)*1000)},amount:{unit:"percent",remaining:0}}] +
              if $current=="absent" then [] else
                [{id:("openai-codex:"+(if $window=="primary" then "secondary" else "primary" end)),
                  status:(if $current=="exhausted" then "exhausted" elif $current=="warning" then "warning" else "ok" end),
                  window:{resetsAt:(($at+1000)*1000)},
                  amount:{unit:"percent",remaining:(if $current=="positive" then 80 else 0 end)}}] end)}]}' \
          > "$TMP_ROOT/merged-reset.json"
        if [ "$expired_window" = secondary ]; then
          jq '(.reports[].limits[]) |= (del(.id) | .scope={tier:"chat"})' \
            "$TMP_ROOT/merged-reset.json" > "$TMP_ROOT/scoped-merged-reset.json"
          mv "$TMP_ROOT/scoped-merged-reset.json" "$TMP_ROOT/merged-reset.json"
        fi
        if [ "$current" = exhausted ] || [ "$current" = zero ]; then expected=exhausted; else expected=unknown; fi
        out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/merged-reset.json")")
        assert_equals "$expected" "$(jq -r .status <<<"$out")" "merged $source $fetched cannot re-date elapsed $expired_window with $current sibling"
        if [ "$current" = absent ]; then
          assert_equals null "$(jq -r '.accounts[0].remaining' <<<"$out")" "elapsed merged bounds must not contribute remaining quota"
        elif [ "$current" = positive ]; then
          assert_equals 80 "$(jq -r '.accounts[0].remaining' <<<"$out")" "current positive evidence excludes elapsed merged exhaustion"
          out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 \
            '{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}' '[]' "$out")
          assert_equals false "$(jq -r .switched <<<"$out")" "reset-crossed merged uncertainty cannot authorize fallback"
        fi
      done
    done
  done
done
jq '.reports += [(.reports[0] | .metadata={} |
  .limits=[{id:"openai-codex:primary",amount:{unit:"percent",remaining:80}}])]' \
  "$TMP_ROOT/merged-reset.json" > "$TMP_ROOT/reset-healthy-sibling.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/reset-healthy-sibling.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "a measured healthy account keeps reset-crossed uncertainty from parking the pool"
pass "merged timestamps cannot re-date elapsed bounds or infer replenishment"

# Library-only endpoint: execute the real fixture command after isolated shell
# initialization. This exercises selection, not production spawn authentication.
cat > "$TMP_ROOT/initialized-shell" <<'SH'
export OMP_USAGE_FIXTURE="$FM_HOME/usage.json" QUOTA_FIXTURE="$FM_HOME/quota.json"
SH
fm_dispatch_endpoint_query() {
  local harness=$1 config=$2 session=$3 cwd=$4 executable=$5
  shift 5
  { [ "$harness" = omp ] || [ "$harness" = claude ]; } && [ -z "$session" ] && [ -d "$cwd" ] || return 125
  [ "$harness" != claude ] || executable=true
  # shellcheck disable=SC2016 # Variables expand in the isolated endpoint shell.
  env -i HOME="$HOME" PATH="$PATH" FM_HOME="$TMP_ROOT" \
    bash --noprofile --norc -c '
      cd "$1" || exit 125
      . "$FM_HOME/initialized-shell"
      [ ! -f .env ] || . ./.env
      shift
      exec "$@"
    ' _ "$cwd" "$executable" "$@"
}
claude_primary='{"harness":"claude","model":"sonnet","effort":"high"}'
claude_fallback='[{"harness":"omp","model":"openrouter/deepseek/deepseek-v4-flash","effort":"high"}]'
for schema in 5 6; do
  for bound in model:sonnet product:sonnet product:opus; do
    for state in percent_exhausted runway_exhausted global_exhausted healthy; do
      jq -n --argjson schema "$schema" --arg bound "$bound" --arg state "$state" '
        {schemaVersion:$schema,providers:[{
          provider:"claude",
          quotaSemantics:{
            status:(if $state == "runway_exhausted" then "partial" else "known" end),
            effectiveAvailability:[
              {scope:"all_models",status:"known",
               effectivePercentRemaining:(if $state == "global_exhausted" then 0 else 70 end),
               runway:{status:"through_reset"}},
              ({scope:$bound} +
               if $state == "runway_exhausted" then
                 {status:"unknown",runway:{status:"exhausted_now"}}
               else
                 {status:"known",
                  effectivePercentRemaining:(if $state == "percent_exhausted" then 0 else 70 end),
                  runway:{status:"through_reset"}}
               end)
            ]
          }
        }]} |
        if $schema == 6 then .providers[0].accountKey="default" else . end
      ' > "$QUOTA_FIXTURE"
      fm_quota_json_valid < "$QUOTA_FIXTURE" || fail "Claude bounds must use a supported quota snapshot"
      expected=usable
      if [ "$state" = global_exhausted ] ||
        { [ "$bound" != product:opus ] && [ "$state" != healthy ]; }; then
        expected=exhausted
      fi
      out=$(fm_dispatch_capacity claude sonnet "$TMP_ROOT/config" '' "$TMP_ROOT") ||
        fail "bound Claude capacity must complete"
      assert_equals "$expected" "$(jq -r .status <<<"$out")" "schema $schema $bound $state must classify all applicable bounds"
      out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$claude_primary" "$claude_fallback" '' '' "$TMP_ROOT") ||
        fail "bound Claude selection must complete"
      expected_profile="$claude_primary"
      if [ "$expected" = exhausted ]; then
        expected_profile=$(jq -c '.[0]' <<<"$claude_fallback")
      fi
      assert_equals "$expected_profile" "$(jq -c .profile <<<"$out")" "schema $schema $bound $state must retain healthy Claude or select its permitted stand-in"
    done
  done
done
pass "native Claude model and product bounds constrain fallback selection under both quota schemas"

primary='{"harness":"omp","model":"openai-codex/gpt-6-luna","effort":"high"}'
allowed='[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"}]'
jq -n --argjson use "$primary" --argjson fallback "$allowed" '{rules:[{when:"easy work",use:$use,fallback:$fallback}],default:$use,default_fallback:$fallback}' > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high)
write_pool 98
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$(jq -c .fallback <<<"$set")" '' '' "$TMP_ROOT")
assert_equals openai-codex/gpt-6-luna "$(jq -r .profile.model <<<"$out")" "native pooled capacity precedes paid model fallback"
write_pool 0
jq '.reports[1].metadata={source:"ratelimit-headers"} |
  .reports[1].limits[0].status="warning"' "$OMP_USAGE_FIXTURE" > "$TMP_ROOT/headers.json"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/headers.json")")
assert_equals usable "$(jq -r .status <<<"$out")" "native successful-response warnings do not authorize paid model fallback from zero percent"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' '' "$TMP_ROOT")
assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r .profile.model <<<"$out")" "whole-pool exhaustion selects the permitted Luna stand-in"
assert_equals true "$(jq -r .switched <<<"$out")" "selection reports a model switch"
assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "unknown fallback quota is disclosed, never invented"
if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" '[]' '' '' "$TMP_ROOT" > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "a route with no permitted stand-in must stop"
fi
strong='{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}'
team='[{"harness":"claude","model":"claude-opus-5-5[1m]","effort":"high","requires":"teamclaude"}]'
# A bare Claude executable is not the required configured TeamClaude route,
# whether or not the separate launch-owner library has landed.
if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$strong" "$team" '' '' "$TMP_ROOT" > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
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
for axis in fallback default_fallback; do
  for candidate in "$allowed" "$team"; do
    for floor in null '{"scope":"all_models","min_percent":20}' '{"scope":"model","min_percent":20}'; do
      jq -n --arg axis "$axis" --argjson use "$primary" --argjson candidates "$candidate" --argjson floor "$floor" '
        ($candidates | map(. + {floor:$floor})) as $fallback |
        {rules:[{use:$use,fallback:(if $axis=="fallback" then $fallback else [] end)}],
         default:$use,default_fallback:(if $axis=="default_fallback" then $fallback else [] end)}' \
        > "$TMP_ROOT/config/crew-dispatch.json" || fail "floor rejection fixture must be valid JSON"
      for rule in rule_1 default; do
        if fm_dispatch_fallbacks "$TMP_ROOT/config" "$rule" omp openai-codex/gpt-6-luna high \
          > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
          fail "$axis floor must be rejected for every rule and route"
        fi
      done
    done
  done
done
jq -n --argjson use "$primary" --argjson fallback "$allowed" \
  '{rules:[{use:$use,fallback:$fallback}],default:$use,default_fallback:$fallback}' \
  > "$TMP_ROOT/config/crew-dispatch.json"
set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 omp openai-codex/gpt-6-luna high) ||
  fail "valid floor-free fallback must remain accepted"
assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "floor rejection must preserve supported fallback permission"
pass "shared validation rejects unsupported floors on all fallback declarations"

unset -f fm_dispatch_endpoint_query
write_pool 0
cp "$OMP_USAGE_FIXTURE" "$TMP_ROOT/auth-exhausted.json"
write_pool 98
mkdir -p "$TMP_ROOT/caller pool" "$TMP_ROOT/destination pool"
printf 'OMP_PROFILE\n' > "$FAKEBIN/auth-selector"
printf 'exhausted-profile\n' > "$FAKEBIN/auth-value"
for projected in healthy exhausted; do
  if [ "$projected" = healthy ]; then profile=healthy-profile; else profile=exhausted-profile; fi
  printf 'OMP_PROFILE=%s\n' "$profile" > "$TMP_ROOT/tmux-global-env"
  printf 'OMP_PROFILE=%s\n' "$profile" > "$TMP_ROOT/tmux-session-env"
  printf 'OMP_PROFILE=%s\n' "$profile" > "$TMP_ROOT/tmux-recorded-env"
  printf 'OMP_PROFILE=%s\n' "$profile" > "$TMP_ROOT/destination pool/.env"
  printf 'OMP_PROFILE=opposite-caller\n' > "$TMP_ROOT/caller pool/.env"
  for scope in prospective existing recorded adopted unreadable daemon missing invalid; do
    session=; backend=tmux; server=existing; unreadable=0; cwd="$TMP_ROOT/destination pool"
    case "$scope" in
      prospective) server=existing-no-firstmate ;;
      recorded) session=recorded ;;
      adopted) session=recorded:fm-existing.0 ;;
      unreadable) unreadable=1 ;;
      daemon) backend=herdr ;;
      missing) cwd= ;;
      invalid) cwd="$TMP_ROOT/missing destination" ;;
    esac
    rm -f "$TMP_ROOT/usage-process-cwd" "$TMP_ROOT/catalog-process-cwd"
    (
      cd "$TMP_ROOT/caller pool" || exit 1
      export FM_TEST_TMUX_SERVER="$server" FM_FAKE_TMUX_UNREADABLE="$unreadable" BACKEND="$backend"
      export FM_TEST_TMUX_UPDATE_ENVIRONMENT=OMP_PROFILE OMP_PROFILE=caller
      out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config" "$session" "$cwd")
      assert_equals unknown "$(jq -r .status <<<"$out")" "$scope $projected projection cannot establish OMP capacity"
      out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' "$session" "$cwd")
      assert_equals false "$(jq -r .switched <<<"$out")" "$scope $projected projection cannot authorize fallback"
      assert_equals "$primary" "$(jq -c .profile <<<"$out")" "unowned selection retains the primary"
      for operation in usage models; do
        rc=0
        fm_dispatch_omp_query "$TMP_ROOT/config" "$session" "$cwd" omp "$operation" --json > "$TMP_ROOT/result" || rc=$?
        assert_equals 125 "$rc" "unowned $operation query must fail closed"
      done
      assert_absent "$TMP_ROOT/usage-process-cwd" "unowned probes never invoke usage"
      assert_absent "$TMP_ROOT/catalog-process-cwd" "unowned probes never invoke models"
    ) || fail "unowned capacity must ignore projected authentication"
  done
done
rm "$FAKEBIN/auth-selector" "$FAKEBIN/auth-value" \
  "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/tmux-recorded-env"
out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol)
assert_equals unknown "$(jq -r .status <<<"$out")" "classification without supplied usage never acquires it"
pass "library probes reject tmux projections without an owned initialized endpoint"

if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '{"status":"exhausted"}' '' "$TMP_ROOT" \
  > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
  fail "explicit exhaustion cannot authorize a fallback without owned catalog evidence"
fi
assert_absent "$TMP_ROOT/catalog-process-cwd" "unowned fallback support never invokes models"
pass "supplied exhaustion still requires endpoint-owned fallback catalog evidence"


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

for container in scalar array; do
  for effort_axis in omitted empty default; do
    for policy in omitted empty; do
      jq -n --arg container "$container" --arg axis "$effort_axis" --arg policy "$policy" --argjson fallback "$allowed" '
        ({harness:"claude",model:"sonnet"} +
         (if $axis == "omitted" then {} elif $axis == "empty" then {effort:""} else {effort:"default"} end)) |
        (if $container == "array" then [.] else . end) as $use |
        {rules:[({use:$use} + (if $policy == "empty" then {fallback:[]} else {} end)),
                {use:{harness:"claude",model:"sonnet",effort:"low"},fallback:$fallback}],
         default:$use} + (if $policy == "empty" then {default_fallback:[]} else {} end)
      ' > "$TMP_ROOT/config/crew-dispatch.json"
      for rule in rule_1 default; do
        set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" "$rule" claude sonnet low) ||
          fail "$rule $container $effort_axis effort must allow completion with $policy fallback"
        assert_equals "$rule" "$(jq -r .rule <<<"$set")" "effort completion must preserve explicit rule identity"
        assert_equals '[]' "$(jq -c .fallback <<<"$set")" "effort completion must not borrow a sibling rule's fallback"
      done
      set=$(fm_dispatch_fallbacks "$TMP_ROOT/config" '' claude sonnet low) ||
        fail "implicit matching must still resolve the exact-effort sibling"
      assert_equals rule_2 "$(jq -r .rule <<<"$set")" "effort completion must remain limited to explicit rules"
      assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "exact-effort sibling keeps its declared permission"
    done
  done
done
# $fallback is a jq variable, not a shell expansion.
# shellcheck disable=SC2016
for mutation in '.rules[0].use.model="opus"' '.rules[0].use.harness="omp"' '.rules[0].use.effort="high"' '.rules[0].fallback=$fallback'; do
  jq -n --argjson fallback "$allowed" \
    "{rules:[{use:{harness:\"claude\",model:\"sonnet\"}}]} | $mutation" > "$TMP_ROOT/config/crew-dispatch.json"
  if fm_dispatch_fallbacks "$TMP_ROOT/config" rule_1 claude sonnet low > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "effort completion must not bypass harness, model, explicit effort, or fallback permission"
  fi
  assert_contains "$(cat "$TMP_ROOT/error")" 'dispatch rule does not contain the requested profile' "only unspecified effort on an explicit no-fallback rule can be completed"
done
pass "explicit no-fallback rules permit effort completion without borrowing stand-ins"

mkdir -p "$TMP_ROOT/role-config"
printf '%s\n' '{"version":1,"roles":{"worker":{"omp":{"model":"openai-codex/gpt-6-luna","stand_in":"openai-codex/gpt-6.1-sol"}}},"retired":[]}' \
  > "$TMP_ROOT/role-config/model-index.json"
for container in scalar array; do
  for stand_in in false true; do
    jq -n --arg container "$container" --argjson stand_in "$stand_in" --argjson fallback "$allowed" '
      {harness:"omp",role:"worker",stand_in:$stand_in,effort:"high"} |
      (if $container == "array" then [.] else . end) as $use |
      {rules:[{use:$use,fallback:$fallback}],default:$use,default_fallback:$fallback}' \
      > "$TMP_ROOT/role-config/crew-dispatch.json"
    model=openai-codex/gpt-6-luna
    [ "$stand_in" = false ] || model=openai-codex/gpt-6.1-sol
    for rule in rule_1 default; do
      set=$(fm_dispatch_fallbacks "$TMP_ROOT/role-config" "$rule" omp "$model" high) ||
        fail "$rule $container role profile must match its resolved selector"
      assert_equals "$rule" "$(jq -r .rule <<<"$set")" "role matching preserves selected rule identity"
      assert_equals "$allowed" "$(jq -c .fallback <<<"$set")" "role matching preserves fallback permission"
    done
  done
done
pass "role and stand-in profiles match concrete selectors in scalar and array rules"

cat > "$QUOTA_FIXTURE" <<'JSON'
{"schemaVersion":6,"providers":[
 {"provider":"claude","accountKey":"other","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0}]}},
 {"provider":"claude","accountKey":"default","quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":70}]}}
]}
JSON
native_primary='{"harness":"claude","model":"claude-sonnet-5-5","effort":"high"}'
for remaining in 0 70; do
  jq --argjson remaining "$remaining" \
    '(.providers[] | select(.accountKey=="default").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)=$remaining' \
    "$QUOTA_FIXTURE" > "$TMP_ROOT/home-quota.json"
  mv "$TMP_ROOT/home-quota.json" "$QUOTA_FIXTURE"
  for scope in default recorded adopted alternate empty removed filtered pinned teamclaude daemon unreadable; do
    session=; backend=tmux; unreadable=0
    printf 'HOME=%s\n' "$HOME" > "$TMP_ROOT/tmux-global-env"
    printf 'HOME=%s\n' "$HOME" > "$TMP_ROOT/tmux-recorded-env"
    case "$scope" in
      recorded) session=recorded ;;
      adopted) session=recorded:fm-existing.0 ;;
      alternate) printf 'ANTHROPIC_API_KEY=projected-key\n' > "$TMP_ROOT/tmux-session-env" ;;
      empty) printf 'ANTHROPIC_API_KEY=\n' > "$TMP_ROOT/tmux-session-env" ;;
      removed) printf -- '-ANTHROPIC_API_KEY\n' > "$TMP_ROOT/tmux-session-env" ;;
      filtered)
        printf 'ANTHROPIC_API_KEY=projected-key\n' > "$TMP_ROOT/tmux-session-env"
        printf '# filtered\n' > "$TMP_ROOT/config/launch-env-allowlist" ;;
      pinned) printf 'pinned-account\n' > "$TMP_ROOT/config/claude-account" ;;
      teamclaude) printf 'teamclaude\n' > "$TMP_ROOT/config/claude-launcher" ;;
      daemon) backend=herdr ;;
      unreadable) unreadable=1 ;;
    esac
    out=$(BACKEND="$backend" FM_FAKE_TMUX_UNREADABLE="$unreadable" \
      fm_dispatch_capacity claude claude-sonnet-5-5 "$TMP_ROOT/config" "$session" "$TMP_ROOT")
    assert_equals unknown "$(jq -r .status <<<"$out")" "$scope Claude quota $remaining needs owned endpoint binding"
    out=$(BACKEND="$backend" FM_FAKE_TMUX_UNREADABLE="$unreadable" \
      fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' "$session" "$TMP_ROOT")
    assert_equals false "$(jq -r .switched <<<"$out")" "$scope projected quota cannot switch Claude"
    assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "unbound Claude preserves its original profile"
    rm -f "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/tmux-recorded-env" \
      "$TMP_ROOT/config/launch-env-allowlist" "$TMP_ROOT/config/claude-account" "$TMP_ROOT/config/claude-launcher"
  done
done
pass "healthy and exhausted Claude projections cannot establish default, pinned, or proxy authentication"
printf '# all fm-dispatch-capacity tests passed\n'
