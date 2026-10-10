#!/usr/bin/env bash
# fm-dispatch-capacity-lib.sh - pooled OMP capacity and declared fallback selection.
# Sourced by routing, spawn, and recovery; docs/configuration.md owns the matrix
# schema. Never reads tokens, changes account pins, redeems saved resets, or
# ranks accounts by a fabricated spendPriority. OMP owns credential rotation.
# fm_omp_codex_capacity <model> [usage-json] prints model-specific pool evidence.
# fm_dispatch_capacity <harness> <model> prints usable/exhausted/unknown evidence.
# fm_dispatch_fallbacks <config-dir> <rule|empty> <harness> <model> <effort>
# prints {rule, fallback}; only rules containing the profile must resolve. A
# recorded rule that no longer contains it counts as none, and differing
# unlabeled lists permit no fallback. rule is set only for a fallback policy.
# fm_dispatch_select <config-dir> <rule> <profile-json> <fallback-array>
# prints the original profile unless it is proven exhausted, then the first
# permitted, supported, non-exhausted fallback. Unknown is disclosed, not zero.
# A TeamClaude fallback's proxy quota is unknown, never native Claude's row,
# both as a candidate and once a task already runs on that stand-in.

FM_DISPATCH_CAPACITY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-session-launch-policy-lib.sh
. "$FM_DISPATCH_CAPACITY_DIR/fm-session-launch-policy-lib.sh"

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
    def account:
      (.limits // [] | map(select(
        (.scope.modelId == null and (.scope.tier // "chat") == "chat") or .scope.modelId == $model
      ))) as $limits |
      (.metadata.meterStates.chat // .metadata // {}) as $meter |
      (if (.fetchedAt | type) != "number" or .fetchedAt < (($now - 300) * 1000)
       then "unknown"
       elif $meter.allowed == false or $meter.limitReached == true or
            any($limits[]; .status == "exhausted") then "exhausted"
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
      {status: (if any($accounts[]; .status == "usable") then "usable"
                elif ($accounts | length) == 0 or any($accounts[]; .status == "unknown") or
                  any((.accountsWithoutUsage // [])[]; .provider == "openai-codex")
                then "unknown" else "exhausted" end), accounts: $accounts}
    end
  ' 2>/dev/null || printf '%s\n' '{"status":"unknown","accounts":[],"reason":"invalid omp usage JSON"}'
}

fm_dispatch_capacity() {
  local harness=$1 model=$2 quota
  case "$harness:$model" in
    omp:openai-codex/*) fm_omp_codex_capacity "$model"; return ;;
    claude:*)
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
  local config=$1 rule=$2 harness=$3 model=$4 effort=$5 file entries entry resolved rules='' result
  file=${6:-"$config/crew-dispatch.json"}
  [ -f "$file" ] || { printf '%s\n' '{"rule":"","fallback":[]}'; return; }
  entries=$(jq -sc '
    def valid_fallback:
      type == "array" and all(.[];
        type == "object" and (.harness == "omp" or .harness == "claude") and
        (.model | type) == "string" and (.model | length) > 0 and
        (.effort == "low" or .effort == "medium" or .effort == "high" or .effort == "xhigh" or .effort == "max") and
        (if .harness == "claude" then .requires == "teamclaude" else (has("requires") | not) end));
    if length != 1 or (.[0] | type) != "object" then error("dispatch must contain exactly one JSON object") else .[0] end |
    if any((.rules // [])[]; has("fallback") and (.fallback | valid_fallback | not)) or
       (has("default_fallback") and (.default_fallback | valid_fallback | not))
    then error("fallback must be an array of explicit OMP profiles or TeamClaude-required Claude profiles") else . end |
    ((.rules // []) | to_entries[] | {rule: ("rule_" + ((.key + 1) | tostring)), use: .value.use, fallback: .value.fallback}),
    {rule: "default", use: (.default // []), fallback: .default_fallback}
  ' "$file" 2>&1) || { printf 'error: invalid dispatch fallback configuration: %s\n' "$entries" >&2; return 1; }
  while IFS= read -r entry; do
    if resolved=$(jq -c '{rules: [{use, fallback}]}' <<<"$entry" |
        FM_CONFIG_OVERRIDE="$config" "$FM_DISPATCH_CAPACITY_DIR/fm-model-index.sh" profiles /dev/stdin 2>/dev/null); then
      rules+=$(jq -c --argjson entry "$entry" '.rules[0] + {rule: $entry.rule, resolved: true}' <<<"$resolved")
    else
      rules+=$(jq -c '. + {resolved: false}' <<<"$entry")
    fi
    rules+=$'\n'
  done <<<"$entries"
  result=$(jq -sc --arg rule "$rule" --arg h "$harness" --arg m "$model" --arg e "$effort" '
    def profiles: if type == "array" then . else [.] end;
    def axis: if . == null or . == "default" then "" else . end;
    def same: type == "object" and .harness == $h and (.model | axis) == ($m | axis) and (.effort | axis) == ($e | axis);
    def contains_profile: .resolved as $resolved |
      any((.use | profiles)[]; same and ($resolved or (has("role") | not))) or any((.fallback // [])[]; same);
    . as $rules |
    [$rules[] | select($rule != "" and .rule == $rule and contains_profile)] as $recorded |
    (if ($recorded | length) > 0 then $recorded else [$rules[] | select(contains_profile)] end) as $matches |
    if any($matches[]; .resolved | not) then
      error("dispatch " + ([$matches[] | select(.resolved | not) | .rule] | join(", ")) + " names a retired model or unconfigured role")
    elif ($matches | map(.fallback // []) | unique | length) != 1 then {rule: "", fallback: []}
    else ($matches[0].fallback // []) as $fallback |
      {rule: (if ($matches | length) == 1 and ($fallback | length) > 0 then $matches[0].rule else "" end), fallback: $fallback} end
  ' <<<"$rules" 2>&1) || { printf 'error: invalid dispatch fallback configuration: %s\n' "$result" >&2; return 1; }
  printf '%s\n' "$result"
}

fm_dispatch_fallback_supported() {
  local config=$1 profile=$2 routing_config=${3:-$1} harness model catalog launcher
  harness=$(jq -r .harness <<<"$profile")
  model=$(jq -r .model <<<"$profile")
  fm_session_launch_policy_check "$config" "$harness" 2>/dev/null || return 1
  FM_CONFIG_OVERRIDE="$routing_config" "$FM_DISPATCH_CAPACITY_DIR/fm-model-index.sh" model "$harness" "$model" >/dev/null || return 1
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

fm_dispatch_fallback_capacity() {
  local candidate=$1
  if [ "$(jq -r .harness <<<"$candidate")" = claude ]; then
    printf '%s\n' '{"status":"unknown","reason":"TeamClaude proxy quota is not measured by native Claude account quota"}'
    return
  fi
  fm_dispatch_capacity "$(jq -r .harness <<<"$candidate")" "$(jq -r .model <<<"$candidate")"
}

fm_dispatch_select() {
  local config=$1 rule=$2 profile=$3 fallback=$4 evidence=${5:-} routing_config=${6:-$1} candidate state
  if [ -z "$evidence" ]; then
    if [ -r "$config/claude-launcher" ] && [ "$(tr -d '[:space:]' < "$config/claude-launcher")" = teamclaude ] &&
       jq -e --argjson p "$profile" 'any(.[]; .requires == "teamclaude" and
         .harness == $p.harness and .model == $p.model and .effort == $p.effort)' <<<"$fallback" >/dev/null; then
      evidence=$(fm_dispatch_fallback_capacity "$profile")
    else
      evidence=$(fm_dispatch_capacity "$(jq -r .harness <<<"$profile")" "$(jq -r '.model // ""' <<<"$profile")")
    fi
  fi
  state=$(jq -r .status <<<"$evidence")
  if [ "$state" != exhausted ]; then
    jq -cn --argjson profile "$profile" --argjson capacity "$evidence" --arg rule "$rule" \
      '{profile: $profile, capacity: $capacity, rule: $rule, switched: false}'
    return
  fi
  while IFS= read -r candidate; do
    [ "$candidate" != "$profile" ] || continue
    fm_dispatch_fallback_supported "$config" "$candidate" "$routing_config" || continue
    evidence=$(fm_dispatch_fallback_capacity "$candidate")
    [ "$(jq -r .status <<<"$evidence")" != exhausted ] || continue
    jq -cn --argjson profile "$candidate" --argjson capacity "$evidence" --arg rule "$rule" \
      '{profile: $profile, capacity: $capacity, rule: $rule, switched: true}'
    return
  done < <(jq -c '.[]' <<<"$fallback")
  printf 'error: dispatch %s has exhausted capacity and no supported permitted fallback\n' "${rule:-profile}" >&2
  return 1
}
