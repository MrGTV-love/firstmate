#!/usr/bin/env bash
# fm-dispatch-capacity-lib.sh - pooled OMP capacity and declared fallback selection.
# Sourced by routing, spawn, and recovery; docs/configuration.md owns the matrix
# schema. Never reads stored tokens, changes account pins, redeems saved resets, or
# ranks accounts by a fabricated spendPriority. OMP owns credential rotation.
# fm_omp_codex_capacity <model> [usage-json] prints model-specific pool evidence.
# fm_dispatch_capacity <harness> <model> [config-dir] [tmux-session] prints evidence.
# fm_dispatch_fallbacks <config-dir> <rule|empty> <harness> <model> <effort>
# prints {rule, fallback}; without a rule, identical matching lists are safe,
# but different lists require the explicit rule chosen at intake.
# fm_dispatch_select <config-dir> <rule> <profile-json> <fallback-array> [evidence] [tmux-session]
# prints the original profile unless it is proven exhausted, then the first
# permitted, supported, non-exhausted fallback. Unknown is disclosed, not zero.

FM_DISPATCH_CAPACITY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-worker-account-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-backend.sh"

fm_omp_codex_capacity() {
  local model=$1 usage=${2:-} now
  if [ -z "$usage" ]; then
    usage=$(fm_run_timed 20 omp usage --provider openai-codex --json 2>/dev/null </dev/null) || usage='{}'
  fi
  now=$(date +%s)
  printf '%s\n' "$usage" | jq -sc --arg model "${model#*/}" --argjson now "$now" '
    def percent:
      if (.remainingFraction | type) == "number" then .remainingFraction * 100
      elif .unit == "percent" and (.remaining | type) == "number" then .remaining
      elif (.limit | type) == "number" and .limit > 0 and (.used | type) == "number"
      then (100 * (1 - .used / .limit)) else null end;
    ($model | contains("-spark")) as $spark |
    (if $spark then "spark" else "chat" end) as $tier |
    (if $spark then "pro"
     elif (["gpt-5.6","gpt-5.6-sol","gpt-5.6-sol-pro","gpt-5.6-luna","gpt-5.6-luna-pro"] | index($model)) != null
     then "paid" else "none" end) as $requirement |
    def entitlement:
      (.metadata.planType // "" |
       if type == "string" then
         gsub("^\\s+|\\s+$"; "") | ascii_downcase | gsub("[\\s-]+"; "_") | sub("^chatgpt_"; "")
       else "" end) as $plan |
      ($plan | split("_")) as $tokens |
      (if $plan == "prolite" or $plan == "pro_lite" then "paid"
       elif any($tokens[]; . == "pro") then "pro"
       elif any($tokens[]; . as $token |
         ["plus","business","team","enterprise","edu","education","teacher","teachers","health","gov","government"] | index($token))
       then "paid"
       elif any($tokens[]; . == "free" or . == "go") then "free"
       else "unknown" end) as $class |
      if $requirement == "none" then "eligible"
      elif $class == "unknown" then "unknown"
      elif ($requirement == "pro" and $class != "pro") or
           ($requirement == "paid" and $class == "free") then "ineligible"
      else "eligible" end;
    def scoped:
      if (.id // "" | startswith("openai-codex:")) then
        if .id == "openai-codex:primary" or .id == "openai-codex:secondary" then $tier == "chat"
        else (.id | split(":")[1]) == $tier end
      elif .scope.tier != null then
        .scope.tier == $tier and
          ($tier == "spark" or .scope.modelId == null or .scope.modelId == $model)
      else
        (.scope.modelId == $model) or ($tier == "chat" and .scope.modelId == null)
      end;
    def account:
      entitlement as $entitlement |
      .fetchedAt as $fetched |
      (.limits // [] | map(select(scoped))) as $scoped |
      ($scoped | map(select((.window.resetsAt | type) == "number" and
        ($fetched | type) == "number" and $fetched < .window.resetsAt and
        .window.resetsAt <= ($now * 1000)))) as $expired |
      ($scoped - $expired) as $limits |
      (if ($expired | length) > 0 then {}
       elif $tier == "chat" then (.metadata.meterStates.chat // .metadata // {})
       else (.metadata.meterStates.spark // {}) end) as $meter |
      (if $entitlement == "ineligible" then "ineligible"
       elif $entitlement == "unknown" or
            ($fetched | type) != "number" or $fetched < (($now - 300) * 1000)
       then "unknown"
       elif $meter.allowed == false or $meter.limitReached == true or
            any($limits[]; .status == "exhausted") then "exhausted"
       elif ($expired | length) > 0 then
         (if any($limits[]; (.amount | percent) != null and (.amount | percent) <= 0 and .status != "warning")
          then "exhausted" else "unknown" end)
       elif $meter.allowed == true and $meter.limitReached == false then "usable"
       elif .metadata.source == "ratelimit-headers" and ($limits | length) > 0 and
            all($limits[]; (.amount | percent) != null and
              ((.amount | percent) > 0 or .status == "warning")) then "usable"
       elif ($limits | length) > 0 and all($limits[]; (.amount | percent) != null) then
         (if any($limits[]; (.amount | percent) <= 0) then "exhausted" else "usable" end)
       else "unknown" end) as $state |
      {status: $state,
       remaining: ([$limits[].amount | percent | select(. != null)] | if length > 0 then min else null end),
       savedResets: (.resetCredits.availableCount // 0)};
    (if length == 1 and (.[0] | type) == "object" then .[0] else {} end) |
    if (.reports | type) != "array" then
      {status: "unknown", accounts: [], reason: "omp usage failed or returned an invalid report"}
    else
      [.reports[] | select(.provider == "openai-codex") | account] as $accounts |
      [(.accountsWithoutUsage // [])[] | select(.provider == "openai-codex")] as $missing |
      {status: (if any($accounts[]; .status == "usable") then "usable"
                elif (($accounts | length) == 0 and ($missing | length) == 0) or
                  any($accounts[]; .status == "unknown") or
                  any($missing[]; entitlement != "ineligible")
                then "unknown" else "exhausted" end), accounts: $accounts}
    end
  ' 2>/dev/null || printf '%s\n' '{"status":"unknown","accounts":[],"reason":"invalid omp usage JSON"}'
}

fm_dispatch_claude_quota_unbound() {
  local config=${1:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-"$FM_DISPATCH_CAPACITY_DIR/.."}/config}}
  local name names present value session=${2:-} backend=${BACKEND:-}
  case "$session" in *:*) return 0 ;; esac
  if [ -z "$backend" ]; then
    backend=$(FM_BACKEND_CONFIG_DIR="$config" fm_backend_name) || return 0
  fi
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ] ||
    [ -e "$config/claude-account" ] || [ -L "$config/claude-account" ] ||
    { [ -r "$config/claude-launcher" ] && [ "$(tr -d '[:space:]' < "$config/claude-launcher")" = teamclaude ]; }; then
    return 0
  fi
  present=$(fm_config_source_present "$config/launch-env-allowlist") || return 0
  if [ "$present" = 1 ]; then
    names=$(fm_config_launch_env_names "$config") || return 0
  fi
  [ "$backend" = tmux ] || return 0
  fm_worker_account_tmux_env '' "$session" readable || return 0
  value=$(fm_worker_account_tmux_filtered_env CLAUDE_CONFIG_DIR "$session" "$present" "${names:-}")
  [ -z "$value" ] || return 0
  for name in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do
    value=$(fm_worker_account_tmux_filtered_env "$name" "$session" "$present" "${names:-}")
    case "$name" in
      CLAUDE_CODE_USE_*)
        case "$value" in 1|[tT][rR][uU][eE]|[yY][eE][sS]|[oO][nN]) return 0 ;; esac
        ;;
      ANTHROPIC_FEDERATION_RULE_ID)
        if [ -n "$value" ]; then
          value=$(fm_worker_account_tmux_filtered_env ANTHROPIC_ORGANIZATION_ID "$session" "$present" "${names:-}")
          [ -z "$value" ] || return 0
        fi
        ;;
      *) [ -z "$value" ] || return 0 ;;
    esac
  done
  return 1
}

fm_dispatch_capacity() {
  local harness=$1 model=$2 quota config session=${4:-}
  case "$harness:$model" in
    omp:openai-codex/*) fm_omp_codex_capacity "$model"; return ;;
    claude:*)
      config=${3:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-$(cd "$FM_DISPATCH_CAPACITY_DIR/.." && pwd)}/config}}
      if fm_dispatch_claude_quota_unbound "$config" "$session"; then
        printf '%s\n' '{"status":"unknown","reason":"selected Claude authentication has no established native default-account quota mapping"}'
        return
      fi
      quota=$(fm_run_timed 10 quota-axi --json 2>/dev/null </dev/null) || quota='{}'
      printf '%s\n' "$quota" | jq -ce --arg model "$model" "$FM_QUOTA_ROW_JQ"'
        (quota_row(.; "claude"; "") |
          [.quotaSemantics.effectiveAvailability[]? | select(
            .scope == "all_models" or .scope == "all_products" or .scope == ("model:" + $model))]) as $rows |
        {status: (if any($rows[]; .runway.status == "exhausted_now" or
                       (.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) then "exhausted"
                  elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining > 0) then "usable"
                  else "unknown" end)}
      ' 2>/dev/null && return
      ;;
  esac
  printf '%s\n' '{"status":"unknown","reason":"no measured quota for this route"}'
}

fm_dispatch_fallbacks() {
  local config=$1 rule=$2 harness=$3 model=$4 effort=$5 file result
  file=${6:-"$config/crew-dispatch.json"}
  [ -f "$file" ] || { printf '%s\n' '{"rule":"","fallback":[]}'; return; }
  result=$(jq -ce --arg rule "$rule" --arg h "$harness" --arg m "$model" --arg e "$effort" '
    def profiles: if type == "array" then . else [.] end;
    def default_axis: if . == null or . == "" or . == "default" then "" else . end;
    def matches:
      .harness == $h and (.model | default_axis) == ($m | default_axis) and
      (.effort | default_axis) == ($e | default_axis);
    def valid_fallback:
      type == "array" and all(.[];
        type == "object" and (.harness == "omp" or .harness == "claude") and
        (.model | type) == "string" and (.model | length) > 0 and
        (.effort == "low" or .effort == "medium" or .effort == "high" or .effort == "xhigh" or .effort == "max") and
        (if .harness == "claude" then .requires == "teamclaude" else (has("requires") | not) end));
    if any((.rules // [])[]; has("fallback") and (.fallback | valid_fallback | not)) or
       (has("default_fallback") and (.default_fallback | valid_fallback | not))
    then error("fallback must be an array of explicit OMP profiles or TeamClaude-required Claude profiles") else . end |
    ([((.rules // []) | to_entries[] | {rule: ("rule_" + ((.key + 1) | tostring)), use: .value.use, fallback: (.value.fallback // [])})] +
     [{rule: "default", use: (.default // []), fallback: (.default_fallback // [])}]) as $rules |
    [$rules[] | select($rule == "" or .rule == $rule) |
      select(any((.use | profiles)[]; matches) or any(.fallback[]; matches))] as $matches |
    if ($matches | length) == 0 then
      if $rule != "" then error("dispatch rule does not contain the requested profile")
      else {rule: "", fallback: []} end
    elif ($matches | map(.fallback) | unique | length) > 1 then error("different fallback lists match this profile; pass --dispatch-rule")
    else {rule: (if ($matches | length) == 1 then $matches[0].rule else "" end), fallback: $matches[0].fallback} end
  ' "$file" 2>&1) || { printf 'error: invalid dispatch fallback configuration: %s\n' "$result" >&2; return 1; }
  printf '%s\n' "$result"
}

fm_dispatch_fallback_supported() {
  local config=$1 profile=$2 harness model catalog launcher
  harness=$(jq -r .harness <<<"$profile")
  model=$(jq -r .model <<<"$profile")
  case "$harness" in
    omp)
      catalog=$(fm_run_timed 20 omp models --json 2>/dev/null </dev/null) || return 1
      jq -e --arg m "$model" 'any(.models[]?; .selector == $m)' <<<"$catalog" >/dev/null
      ;;
    claude)
      # This capability belongs to the supported TeamClaude launch owner, not
      # to a bare claude executable, a shell alias, or an inferred proxy env.
      [ -f "$FM_DISPATCH_CAPACITY_DIR/fm-claude-launcher-lib.sh" ] || return 1
      [ -r "$config/claude-launcher" ] || return 1
      [ "$(tr -d '[:space:]' < "$config/claude-launcher")" = teamclaude ] || return 1
      # shellcheck source=/dev/null
      . "$FM_DISPATCH_CAPACITY_DIR/fm-claude-launcher-lib.sh"
      launcher=$(fm_claude_launcher_select "$config") || return 1
      [ "$launcher" != claude ]
      ;;
    *) return 1 ;;
  esac
}

fm_dispatch_select() {
  local config=$1 rule=$2 profile=$3 fallback=$4 evidence=${5:-} session=${6:-} candidate state
  if [ -z "$evidence" ]; then
    evidence=$(fm_dispatch_capacity "$(jq -r .harness <<<"$profile")" "$(jq -r '.model // ""' <<<"$profile")" "$config" "$session")
  fi
  state=$(jq -r .status <<<"$evidence")
  if [ "$state" != exhausted ]; then
    jq -cn --argjson profile "$profile" --argjson capacity "$evidence" --arg rule "$rule" \
      '{profile: $profile, capacity: $capacity, rule: $rule, switched: false}'
    return
  fi
  while IFS= read -r candidate; do
    [ "$candidate" != "$profile" ] || continue
    fm_dispatch_fallback_supported "$config" "$candidate" || continue
    evidence=$(fm_dispatch_capacity "$(jq -r .harness <<<"$candidate")" "$(jq -r .model <<<"$candidate")" "$config" "$session")
    [ "$(jq -r .status <<<"$evidence")" != exhausted ] || continue
    jq -cn --argjson profile "$candidate" --argjson capacity "$evidence" --arg rule "$rule" \
      '{profile: $profile, capacity: $capacity, rule: $rule, switched: true}'
    return
  done < <(jq -c '.[]' <<<"$fallback")
  printf 'error: dispatch %s has exhausted capacity and no supported permitted fallback\n' "${rule:-profile}" >&2
  return 1
}
