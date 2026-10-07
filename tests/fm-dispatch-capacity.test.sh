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
      out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model "openai-codex/$model" --json)
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
      out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model "openai-codex/$model" --json)
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
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model "openai-codex/$model" --json)
    assert_equals "$paid_status" "$(jq -r .status <<<"$out")" "$plan entitlement is respected for $model"
    if [ "$paid_status" = exhausted ]; then
      assert_equals ineligible "$(jq -r '.accounts[0].status' <<<"$out")" "a known free account is excluded rather than unmeasured"
    fi
  done
  for model in gpt-5.3-codex-spark GPT-5.3-CODEX-SPARK; do
    out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model "openai-codex/$model" --json)
    assert_equals "$spark_status" "$(jq -r .status <<<"$out")" "$plan entitlement is respected for Pro-only $model"
  done
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
for source in ratelimit-headers usage-endpoint; do
  for warning_window in primary secondary; do
    for remaining in 0 10; do
      for negative in exhausted zero; do
        jq -n --argjson at "$(date +%s)" --arg source "$source" --arg window "$warning_window" \
          --argjson remaining "$remaining" --arg negative "$negative" '
          {reports:[{provider:"openai-codex",fetchedAt:($at*1000),
            metadata:{source:$source,headersUpdatedAt:($at*1000)},
            limits:[
              {id:("openai-codex:"+$window),status:"warning",amount:{unit:"percent",remaining:$remaining}},
              {id:("openai-codex:"+(if $window=="primary" then "secondary" else "primary" end)),
                status:(if $negative=="exhausted" then "exhausted" else "ok" end),
                amount:{unit:"percent",remaining:0}}]}]}' > "$TMP_ROOT/partial-headers.json"
        out=$(fm_omp_codex_capacity openai-codex/gpt-6.1-sol "$(cat "$TMP_ROOT/partial-headers.json")")
        assert_equals unknown "$(jq -r .status <<<"$out")" "merged $source $warning_window warning cannot order a sibling $negative verdict"
        assert_equals unknown "$(jq -r '.accounts[0].status' <<<"$out")" "conflicting account evidence must remain unknown"
        out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 \
          '{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}' '[]' "$out")
        assert_equals false "$(jq -r .switched <<<"$out")" "unordered conflicting evidence cannot authorize fallback"
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

write_pool 0
export OMP_AUTH_EXHAUSTED_FIXTURE="$TMP_ROOT/auth-exhausted.json"
cp "$OMP_USAGE_FIXTURE" "$OMP_AUTH_EXHAUSTED_FIXTURE"
write_pool 98
for selector in HOME PI_CODING_AGENT_DIR PI_CONFIG_DIR OMP_PROFILE PI_PROFILE XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME OMP_AUTH_BROKER_URL OMP_AUTH_BROKER_TOKEN; do
  export OMP_AUTH_SELECTOR="$selector" OMP_AUTH_EXHAUSTED_VALUE="$TMP_ROOT/exhausted-scope"
  case "$selector" in OMP_PROFILE|PI_PROFILE) export OMP_AUTH_EXHAUSTED_VALUE=exhausted-profile ;; esac
  printf '%s\n' "$OMP_AUTH_SELECTOR" > "$FAKEBIN/auth-selector"
  printf '%s\n' "$OMP_AUTH_EXHAUSTED_VALUE" > "$FAKEBIN/auth-value"
  out=$(env "$selector=$OMP_AUTH_EXHAUSTED_VALUE" "$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
  assert_equals usable "$(jq -r .status <<<"$out")" "caller-only $selector must not select the worker's authentication"
  printf '%s=%s\n' "$selector" "$OMP_AUTH_EXHAUSTED_VALUE" > "$TMP_ROOT/tmux-global-env"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' '' "$TMP_ROOT")
  assert_equals true "$(jq -r .switched <<<"$out")" "destination $selector exhaustion must authorize declared fallback"
  printf -- '-%s\n' "$selector" > "$TMP_ROOT/tmux-session-env"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' '' "$TMP_ROOT")
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
printf 'PI_CODING_AGENT_DIR\n' > "$FAKEBIN/auth-selector"
printf '%s\n' "$TMP_ROOT/exhausted-scope" > "$FAKEBIN/auth-value"
for pattern in PI_CODING_AGENT_DIR 'PI_CODING_*' 'PI_?ODING_AGENT_DIR' 'PI_[A-Z]*'; do
  for direction in imported-exhausted imported-usable removed empty; do
    case "$direction" in
      imported-exhausted)
        global_store="$TMP_ROOT/usable-scope"; caller_store="$TMP_ROOT/exhausted-scope"; expected=exhausted; switched=true ;;
      imported-usable)
        global_store="$TMP_ROOT/exhausted-scope"; caller_store="$TMP_ROOT/usable-scope"; expected=usable; switched=false ;;
      removed|empty)
        [ "$pattern" = PI_CODING_AGENT_DIR ] || continue
        global_store="$TMP_ROOT/exhausted-scope"; caller_store=; expected=usable; switched=false ;;
    esac
    printf 'PI_CODING_AGENT_DIR=%s\n' "$global_store" > "$TMP_ROOT/tmux-global-env"
    # Each command substitution deliberately exports its own isolated caller environment.
    # shellcheck disable=SC2030
    out=$(unset PI_CODING_AGENT_DIR
      [ "$direction" = removed ] || export PI_CODING_AGENT_DIR="$caller_store"
      FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$pattern" \
        "$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
    assert_equals "$expected" "$(jq -r .status <<<"$out")" "prospective $pattern $direction must measure the effective store rather than the global store"
    # This separate command substitution deliberately recreates the caller environment.
    # shellcheck disable=SC2031
    out=$(unset PI_CODING_AGENT_DIR
      [ "$direction" = removed ] || export PI_CODING_AGENT_DIR="$caller_store"
      FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$pattern" \
        fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' '' "$TMP_ROOT")
    assert_equals "$switched" "$(jq -r .switched <<<"$out")" "prospective $pattern $direction must use effective-store exhaustion for fallback"
  done
done
out=$(PI_CODING_AGENT_DIR="$TMP_ROOT/usable-scope" \
  FM_TEST_TMUX_UPDATE_ENVIRONMENT=PI_CODING_AGENT_DIR \
  "$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
assert_equals exhausted "$(jq -r .status <<<"$out")" "existing firstmate must retain its global exhausted store despite update-environment"
printf 'PI_CODING_AGENT_DIR=%s\n' "$TMP_ROOT/usable-scope" > "$TMP_ROOT/tmux-global-env"
out=$(PI_CODING_AGENT_DIR="$TMP_ROOT/exhausted-scope" \
  FM_TEST_TMUX_UPDATE_ENVIRONMENT=PI_CODING_AGENT_DIR \
  "$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
assert_equals usable "$(jq -r .status <<<"$out")" "existing firstmate must not import the caller's exhausted store"
rm "$TMP_ROOT/tmux-global-env"
pass "prospective OMP capacity resolves imported, absent, and empty stores before fallback while existing sessions stay isolated"
export OMP_AUTH_SELECTOR=OMP_PROFILE OMP_AUTH_EXHAUSTED_VALUE=exhausted-profile
printf '%s\n' "$OMP_AUTH_SELECTOR" > "$FAKEBIN/auth-selector"
printf '%s\n' "$OMP_AUTH_EXHAUSTED_VALUE" > "$FAKEBIN/auth-value"
printf 'PI_PROFILE=exhausted-profile\n' > "$TMP_ROOT/tmux-global-env"
printf 'OMP_PROFILE=\n' > "$TMP_ROOT/tmux-session-env"
out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config")
assert_equals usable "$(jq -r .status <<<"$out")" "explicit empty OMP_PROFILE must override the legacy PI_PROFILE"
printf -- '-OMP_PROFILE\n' > "$TMP_ROOT/tmux-session-env"
out=$(fm_dispatch_capacity omp openai-codex/gpt-6.1-sol "$TMP_ROOT/config")
assert_equals exhausted "$(jq -r .status <<<"$out")" "removed OMP_PROFILE must allow destination PI_PROFILE selection"
rm "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/tmux-session-env"
unset OMP_AUTH_SELECTOR OMP_AUTH_EXHAUSTED_VALUE OMP_AUTH_EXHAUSTED_FIXTURE
rm "$FAKEBIN/auth-selector" "$FAKEBIN/auth-value"
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

write_pool 0
: > "$FAKEBIN/catalog-key"
ordered='[{"harness":"omp","model":"openrouter/z-ai/glm-5.3-flash","effort":"high"},{"harness":"omp","model":"openrouter/deepseek/deepseek-v4-flash","effort":"high"}]'
for policy in inherited retained filtered removed empty; do
  printf 'OPENROUTER_API_KEY=destination\n' > "$TMP_ROOT/tmux-global-env"
  case "$policy" in
    inherited) ;;
    retained) printf 'OPENROUTER_API_KEY\n' > "$TMP_ROOT/config/launch-env-allowlist" ;;
    filtered) : > "$TMP_ROOT/config/launch-env-allowlist" ;;
    removed) printf -- '-OPENROUTER_API_KEY\n' > "$TMP_ROOT/tmux-session-env" ;;
    empty) printf 'OPENROUTER_API_KEY=\n' > "$TMP_ROOT/tmux-session-env" ;;
  esac
  out=$(OPENROUTER_API_KEY=caller fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$ordered" '' '' "$TMP_ROOT")
  case "$policy" in inherited|retained) expected=openrouter/z-ai/glm-5.3-flash ;; *) expected=openrouter/deepseek/deepseek-v4-flash ;; esac
  assert_equals "$expected" "$(jq -r .profile.model <<<"$out")" "$policy catalog must retain only destination provider auth"
  rm -f "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/config/launch-env-allowlist"
done
mkdir -p "$TMP_ROOT/caller disabled/.omp" "$TMP_ROOT/destination enabled/.omp" \
  "$TMP_ROOT/caller enabled/.omp" "$TMP_ROOT/destination disabled/.omp"
cat > "$TMP_ROOT/caller disabled/.omp/config.yml" <<'JSON'
{"disabledProviders":["openrouter"]}
JSON
cat > "$TMP_ROOT/destination disabled/.omp/config.yml" <<'JSON'
{"disabledProviders":["openrouter"]}
JSON
cat > "$TMP_ROOT/caller enabled/.omp/config.yml" <<'JSON'
{"disabledProviders":[]}
JSON
cat > "$TMP_ROOT/destination enabled/.omp/config.yml" <<'JSON'
{"disabledProviders":[]}
JSON
printf 'OPENROUTER_API_KEY=destination\n' > "$TMP_ROOT/tmux-global-env"
(
  cd "$TMP_ROOT/caller disabled" || exit 1
  out=$(OPENROUTER_API_KEY=caller fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' '' "$TMP_ROOT/destination enabled") ||
    fail "enabled destination must permit fallback despite disabled caller project"
  assert_equals true "$(jq -r .switched <<<"$out")" "destination project enables the declared fallback"
  assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r .profile.model <<<"$out")" "destination catalog selects its supported fallback"
  destination=$(cd "$TMP_ROOT/destination enabled" && pwd -P)
  assert_equals "$destination" "$(cat "$TMP_ROOT/catalog-process-cwd")" "models process must run in the explicit destination"
  assert_equals "$destination" "$(cat "$TMP_ROOT/usage-process-cwd")" "primary usage must run in the explicit destination"
  write_pool 98
  : > "$FAKEBIN/catalog-codex"
  candidate='[{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"}]'
  rm "$TMP_ROOT/usage-process-cwd"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$candidate" '{"status":"exhausted"}' '' "$TMP_ROOT/destination enabled") ||
    fail "permitted Codex candidate must use destination-scoped capacity"
  assert_equals openai-codex/gpt-6.1-sol "$(jq -r .profile.model <<<"$out")" "supported Codex candidate must be selected"
  assert_equals usable "$(jq -r .capacity.status <<<"$out")" "candidate quota must come from its measured pool"
  assert_equals "$destination" "$(cat "$TMP_ROOT/usage-process-cwd")" "candidate usage must run in the explicit destination"
  rm "$FAKEBIN/catalog-codex"
  write_pool 0
) || fail "disabled caller must not override enabled destination catalog"
(
  cd "$TMP_ROOT/caller enabled" || exit 1
  if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" '' '' "$TMP_ROOT/destination disabled" \
    > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "enabled caller must not approve fallback disabled in destination"
  fi
  destination=$(cd "$TMP_ROOT/destination disabled" && pwd -P)
  assert_equals "$destination" "$(cat "$TMP_ROOT/catalog-process-cwd")" "disabled catalog must be queried in the destination"
  assert_equals "$destination" "$(cat "$TMP_ROOT/usage-process-cwd")" "disabled destination must still scope primary usage"
  rm "$TMP_ROOT/catalog-process-cwd"
  if fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$allowed" \
    > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "missing explicit project cwd must not approve a fallback from caller catalog"
  fi
  resolved=$(type -P omp)
  if fm_dispatch_omp_query "$TMP_ROOT/config" '' '' "$resolved" models --json \
    > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "models query without explicit project cwd must fail closed"
  fi
  [ ! -e "$TMP_ROOT/catalog-process-cwd" ] ||
    fail "missing project cwd must not invoke models in caller directory"
) || fail "catalog project scope must fail closed without a supported destination"
rm "$TMP_ROOT/tmux-global-env"
pass "OMP fallback approval uses explicit destination project configuration"
(
  ln -s "$(type -P bash)" "$FAKEBIN/bash"
  cd "$(dirname "$FAKEBIN")" || exit 1
  PATH="$(basename "$FAKEBIN"):$PATH"
  export PATH OPENROUTER_API_KEY=caller
  destination=$(cd "$TMP_ROOT/destination enabled" && pwd -P)
  printf 'OPENROUTER_API_KEY=destination\n' > "$TMP_ROOT/tmux-global-env"
  printf 'OPENROUTER_API_KEY\n' > "$TMP_ROOT/config/launch-env-allowlist"
  write_pool 98
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
  assert_equals usable "$(jq -r .status <<<"$out")" "relative PATH executables must measure healthy pooled capacity"
  write_pool 0
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness omp --model openai-codex/gpt-6.1-sol --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "relative PATH executables must measure whole-pool exhaustion"
  resolved="$(cd "$(dirname "$(type -P omp)")" && pwd -P)/$(basename "$(type -P omp)")"
  catalog=$(fm_dispatch_omp_query "$TMP_ROOT/config" '' 'destination enabled' "$resolved" models --json)
  assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r '.models[0].selector' <<<"$catalog")" "explicit launch-resolved executable must query the destination catalog"
  assert_equals "$destination" "$(cat "$TMP_ROOT/catalog-process-cwd")" "relative project cwd must normalize before catalog process cd"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$ordered" '' '' 'destination enabled')
  assert_equals true "$(jq -r .switched <<<"$out")" "relative PATH exhaustion must authorize declared selection"
  assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r .profile.model <<<"$out")" "relative PATH catalog must accept the destination selector"
  assert_equals "$destination" "$(cat "$TMP_ROOT/catalog-process-cwd")" "relative PATH selection must query models in the destination"
  assert_equals "$destination" "$(cat "$TMP_ROOT/usage-process-cwd")" "relative PATH selection must query usage in the destination"
  : > "$TMP_ROOT/config/launch-env-allowlist"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$ordered" '' '' 'destination enabled')
  assert_equals openrouter/deepseek/deepseek-v4-flash "$(jq -r .profile.model <<<"$out")" "relative PATH normalization must preserve catalog authentication filtering"
  assert_equals "$destination" "$(cat "$TMP_ROOT/catalog-process-cwd")" "auth-filtered catalog process must retain destination cwd"
  assert_equals "$destination" "$(cat "$TMP_ROOT/usage-process-cwd")" "auth-filtered usage must retain destination cwd"
  rm "$FAKEBIN/bash" "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/config/launch-env-allowlist"
) || fail "relative PATH queries must match executable launch normalization"
for scope in adopted unreadable daemon relative; do
  case "$scope" in
    adopted) session=recorded:fm-existing.0 ;;
    *) session= ;;
  esac
  if [ "$scope" = relative ]; then printf 'XDG_DATA_HOME=relative-root\n' > "$TMP_ROOT/tmux-global-env"; fi
  if OPENROUTER_API_KEY=destination \
    BACKEND=$([ "$scope" != daemon ] && printf tmux || printf herdr) \
    FM_FAKE_TMUX_UNREADABLE=$([ "$scope" != unreadable ] && printf 0 || printf 1) \
    fm_dispatch_select "$TMP_ROOT/config" rule_1 "$primary" "$ordered" '{"status":"exhausted"}' "$session" "$TMP_ROOT" \
      > "$TMP_ROOT/result" 2> "$TMP_ROOT/error"; then
    fail "$scope catalog acquisition must not authorize fallback from caller credentials"
  fi
  rm -f "$TMP_ROOT/tmux-global-env"
done
rm "$FAKEBIN/catalog-key"
pass "OMP fallback catalogs retain destination provider auth without borrowing caller credentials"

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
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
assert_equals true "$(jq -r .switched <<<"$out")" "native default exhaustion authorizes a permitted fallback"
for credential in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR; do
  for direction in imported removed empty; do
    : > "$TMP_ROOT/tmux-global-env"
    [ "$direction" = imported ] || printf '%s=global-alternate-auth\n' "$credential" > "$TMP_ROOT/tmux-global-env"
    out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR
      if [ "$direction" = imported ]; then
        export "$credential=caller-alternate-auth"
      elif [ "$direction" = empty ]; then
        export "$credential="
      fi
      FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$credential" \
        "$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
    if [ "$direction" = imported ]; then expected=unknown; switched=false
    else expected=exhausted; switched=true; fi
    assert_equals "$expected" "$(jq -r .status <<<"$out")" "prospective $direction $credential must bind native quota to effective authentication"
    out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CONFIG_DIR
      if [ "$direction" = imported ]; then
        export "$credential=caller-alternate-auth"
      elif [ "$direction" = empty ]; then
        export "$credential="
      fi
      FM_TEST_TMUX_SERVER=existing-no-firstmate FM_TEST_TMUX_UPDATE_ENVIRONMENT="$credential" \
        fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
    if [ "$switched" = true ]; then
      assert_equals openrouter/z-ai/glm-5.3-flash "$(jq -r .profile.model <<<"$out")" "bound exhaustion must select the permitted stand-in"
    else
      assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "unbound prospective authentication must disclose unknown capacity"
      assert_equals claude-sonnet-5-5 "$(jq -r .profile.model <<<"$out")" "unbound prospective authentication must retain the primary"
    fi
    assert_equals "$switched" "$(jq -r .switched <<<"$out")" "only bound native exhaustion may authorize prospective $direction $credential fallback"
  done
  rm "$TMP_ROOT/tmux-global-env"
  out=$(export "$credential=caller-alternate-auth"
    FM_TEST_TMUX_UPDATE_ENVIRONMENT="$credential" \
      "$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  if [ "$credential" = CLAUDE_CONFIG_DIR ]; then expected=unknown; else expected=exhausted; fi
  assert_equals "$expected" "$(jq -r .status <<<"$out")" "existing firstmate must isolate caller credentials while retaining the explicit CLAUDE_CONFIG_DIR launch override"
done
pass "prospective native Claude alternate authentication stays unknown while removal and emptiness restore mapped subscription quota"
for remaining in 0 70; do
  jq --argjson remaining "$remaining" \
    '(.providers[] | select(.accountKey=="default").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)=$remaining' \
    "$QUOTA_FIXTURE" > "$TMP_ROOT/home-quota.json"
  mv "$TMP_ROOT/home-quota.json" "$QUOTA_FIXTURE"
  for scope in different removed empty relative absent; do
    case "$scope" in
      different) printf 'HOME=%s\n' "$TMP_ROOT/other-home" > "$TMP_ROOT/tmux-session-env" ;;
      removed) printf -- '-HOME\n' > "$TMP_ROOT/tmux-session-env" ;;
      empty) printf 'HOME=\n' > "$TMP_ROOT/tmux-session-env" ;;
      relative) printf 'HOME=relative-home\n' > "$TMP_ROOT/tmux-session-env" ;;
      absent) rm "$TMP_ROOT/tmux-session-env"; export FM_FAKE_TMUX_HOME= ;;
    esac
    for filtering in absent active; do
      if [ "$filtering" = active ]; then
        printf '# HOME floor is retained\n' > "$TMP_ROOT/config/launch-env-allowlist"
      fi
      out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
      assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "$scope destination HOME cannot borrow caller quota $remaining with $filtering filtering"
      assert_equals false "$(jq -r .switched <<<"$out")" "unbound default-store identity cannot authorize a model switch"
    done
    rm "$TMP_ROOT/config/launch-env-allowlist"
  done
  export FM_FAKE_TMUX_HOME="$HOME"
  printf 'HOME=%s\n' "$HOME" > "$TMP_ROOT/tmux-recorded-env"
  printf 'HOME=%s\n' "$TMP_ROOT/other-home" > "$TMP_ROOT/tmux-session-env"
  out=$(fm_dispatch_capacity claude claude-sonnet-5-5 "$TMP_ROOT/config" recorded)
  if [ "$remaining" = 0 ]; then expected=exhausted; else expected=usable; fi
  assert_equals "$expected" "$(jq -r .status <<<"$out")" "matching HOME in the recorded destination binds native quota"
  rm "$TMP_ROOT/tmux-recorded-env" "$TMP_ROOT/tmux-session-env"
done
jq '(.providers[] | select(.accountKey=="default").quotaSemantics.effectiveAvailability[0].effectivePercentRemaining)=0' \
  "$QUOTA_FIXTURE" > "$TMP_ROOT/native-claude-zero.json"
mv "$TMP_ROOT/native-claude-zero.json" "$QUOTA_FIXTURE"
pass "native Claude quota requires established matching destination default-store identity"
export CLAUDE_CONFIG_DIR="$TMP_ROOT/alternate-claude"
out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
assert_equals unknown "$(jq -r .status <<<"$out")" "ambient alternate authentication must not inherit default exhaustion"
out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
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
    out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
    assert_equals false "$(jq -r .switched <<<"$out")" "$forwarding $credential must retain the original route"
    assert_equals "$native_primary" "$(jq -c .profile <<<"$out")" "$forwarding $credential must not substitute a model"
  done
  printf '# no alternate API authentication\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$("$ROOT/bin/fm-dispatch-capacity.sh" --harness claude --model claude-sonnet-5-5 --json)
  assert_equals exhausted "$(jq -r .status <<<"$out")" "filtered $credential must not conceal real subscription exhaustion"
  out=$(fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
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
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
  assert_equals false "$(jq -r .switched <<<"$out")" "destination global $credential must not inherit subscription exhaustion"
  printf '%s=session-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
  assert_equals unknown "$(jq -r .capacity.status <<<"$out")" "destination session $credential is alternate authentication"
  printf -- '-%s\n' "$credential" > "$TMP_ROOT/tmux-recorded-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" "" recorded "$TMP_ROOT")
  assert_equals true "$(jq -r .switched <<<"$out")" "the explicit recorded session must override the current session's $credential"
  rm "$TMP_ROOT/tmux-recorded-env"
  printf -- '-%s\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
  assert_equals true "$(jq -r .switched <<<"$out")" "session removal of $credential must suppress the global credential"
  printf '%s=\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
  assert_equals true "$(jq -r .switched <<<"$out")" "empty session $credential must override the global credential"
  printf '%s=session-routing-fixture\n' "$credential" > "$TMP_ROOT/tmux-session-env"
  printf '# filter destination credentials\n' > "$TMP_ROOT/config/launch-env-allowlist"
  out=$(BACKEND=tmux fm_dispatch_select "$TMP_ROOT/config" rule_1 "$native_primary" "$allowed" '' '' "$TMP_ROOT")
  assert_equals true "$(jq -r .switched <<<"$out")" "the allowlist must strip destination $credential"
  rm "$TMP_ROOT/tmux-session-env" "$TMP_ROOT/tmux-global-env" "$TMP_ROOT/config/launch-env-allowlist"
done
for credential in $FM_WORKER_ACCOUNT_CLAUDE_SHED CLAUDE_CONFIG_DIR; do
  value='destination-auth'
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
