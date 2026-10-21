#!/usr/bin/env bash
# fm-review-agent-select.sh - dry-run choice of the no-mistakes review agent.
#
# Usage: fm-review-agent-select.sh --dry-run [--log]
#
# Stage one of dynamic review-agent selection. It answers one question from live
# evidence: which candidate of the review rule would firstmate pick for the next
# no-mistakes run, and how does that differ from the live agent order. It never
# writes the no-mistakes config or any agent_config; there is no write mode, so a
# run without --dry-run is refused. The only file it ever appends to is the
# evidence log below, and only with --log.
#
# Candidates: the single rule in config/crew-dispatch.json whose `when` starts
# with "Isolated independent quality review". Zero or several matching rules is
# an error, never a guess. Roles and retired ids resolve through
# bin/fm-model-index.sh profiles, and each chosen profile is preflighted through
# its check verb under the pinned worker account, exactly as
# bin/fm-dispatch-resolve.sh does for a dispatch.
#
# Procedure: the quota-array-dispatch skill owns it. Three gates, then
# spendPriority:
#   1 eligibility   session launch policy, model-index check (retired or absent
#                   catalog id refuses), applicable quota row, profile floor;
#                   0% or exhausted_now vetoes and counts as proven exhaustion;
#   2 reasoning fit the rule declares its candidates equal in class, so a
#                   weaker declared fallback is used only on proven exhaustion
#                   of every `use` candidate, never to conserve quota;
#   3 runway        established runway shorter than task_horizon_minutes (240
#                   when absent) fails; unknown runway stays eligible, disclosed.
# Among survivors the highest known spendPriority wins. A tie is reported, never
# broken by array order. A candidate whose spendPriority is unknown (an OMP
# pooled Codex route reports capacity but no scalar) is never read as zero or as
# healthy: it is used only when no candidate carries a known scalar and exactly
# one has measured headroom, and is otherwise disclosed beside the winner.
# Headroom comes from one `quota-axi --json` snapshot and, for omp
# openai-codex/ routes, one `omp usage` pooled report; each is read once. The
# fallback tier is the exception: it is entered only when every `use` candidate
# is proven exhausted, and then each declared fallback makes its own omp reads.
#
# Output (stdout, TOON-style block):
#   review-agent-select: dry-run (nothing written)
#     status: selected | escalate | tie
#     rule: <rule_N> (<when>)   horizon_minutes: <N>
#     selected: <harness>:<model> effort=.. agent=.. tier=primary|fallback
#     reason: <why>
#     current: the live no-mistakes agent order, read only
#     candidate: <harness>:<model> provider=.. tier=.. ... -> eligible | not eligible
# Exit status: 0 selected; 1 no selection (escalate or tie); 2 a usage,
# configuration, or evidence error, which is never selected around.
#
# --log appends one JSON line (fm-review-agent-select.v1) to
# state/review-agent-select.jsonl for every run, errors included, so a day of
# heartbeat runs can be compared with real quota and real failures.
# bin/fm-watch.sh runs this from the heartbeat tick; docs/configuration.md
# "Review-agent selection" owns the record fields.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE and FM_CONFIG_OVERRIDE resolve the
# home like the other bin/ scripts; NO_MISTAKES_HOME names the no-mistakes home
# read for `current` (default ~/.no-mistakes). FM_MODEL_CATALOG_DIR supplies
# catalog exports to the model-index check, as fm-model-index.sh documents.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NM_HOME="${NO_MISTAKES_HOME:-${HOME:-}/.no-mistakes}"
RULES_PATH="$CONFIG/crew-dispatch.json"
LOG_FILE="$STATE/review-agent-select.jsonl"
REVIEW_WHEN_PREFIX='Isolated independent quality review'
DEFAULT_HORIZON_MINUTES=240

# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-dispatch-capacity-lib.sh
. "$SCRIPT_DIR/fm-dispatch-capacity-lib.sh"
# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"

usage() {
  awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}"
}

DRY_RUN=0 LOG=0
RUN_AT=$(date +%s)
TMP=''
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
}
trap cleanup EXIT

fail() {  # <reason>; an actionable error that is never selected around
  printf 'error: %s\n' "$1" >&2
  if [ "$LOG" = 1 ] && [ -d "$STATE" ]; then
    jq -cn --argjson at "$RUN_AT" --arg reason "$1" \
      '{schema: "fm-review-agent-select.v1", at: $at, mode: "dry-run", status: "error", reason: $reason}' \
      >> "$LOG_FILE" 2>/dev/null || true
  fi
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --log) LOG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done
[ "$DRY_RUN" = 1 ] || fail 'stage one is dry-run only: pass --dry-run (no write mode exists)'

command -v jq >/dev/null 2>&1 || fail 'jq required'
TMP=$(mktemp -d) || fail 'mktemp failed'

if [ "$LOG" = 1 ]; then
  [ -d "$STATE" ] || fail "state directory not found: $STATE"
fi

# ---- configuration: malformed input is an error, never a candidate to skip -----
[ -f "$RULES_PATH" ] && [ -r "$RULES_PATH" ] || fail "rules file not readable: $RULES_PATH"
jq -se 'length == 1 and (.[0] | type == "object")' "$RULES_PATH" >/dev/null 2>&1 \
  || fail "malformed rules file: $RULES_PATH (not exactly one JSON object)"
RESOLVED=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-model-index.sh" profiles "$RULES_PATH" 2>"$TMP/profiles.err") \
  || fail "model index/profile resolution failed: $(grep -m1 -v '^model-index: warning' "$TMP/profiles.err" 2>/dev/null || true)"
VERIFIED=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')

RULE=$(printf '%s\n' "$RESOLVED" | jq -c --arg prefix "$REVIEW_WHEN_PREFIX" \
  --argjson verified "$VERIFIED" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" \
  --argjson default_horizon "$DEFAULT_HORIZON_MINUTES" "$FM_DISPATCH_VALID_FALLBACK_JQ"'
  def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
  def floor_bad($f):
    ($f | type) != "object" or (($f.scope | type) != "string") or (($f.scope | length) == 0)
    or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
    or ($f | has("provider"));
  def profile_bad($p):
    if ($p | type) != "object" then "profile must be an object"
    elif (($p.harness | type) != "string") or ($p.harness | length) == 0 then "profile needs a harness"
    elif ($verified | index($p.harness)) == null then "harness " + $p.harness + " is not a verified harness"
    elif ($p.harness != "omp" and $p.harness != "claude") then
      "harness " + $p.harness + " has no no-mistakes review agent (only omp and claude)"
    elif (($p.model | type) != "string") or ($p.model | length) == 0 then
      "profile " + $p.harness + " needs an explicit model"
    elif ($p | has("effort")) and ((["low", "medium", "high", "xhigh", "max"] | index($p.effort)) == null) then
      "profile " + $p.model + " effort must be one of low, medium, high, xhigh, max"
    elif ($p | has("provider")) and ((($p.provider | type) != "string") or (($p.provider | test($provider_re)) | not)) then
      "profile " + $p.model + " provider must match " + $provider_re
    elif ($p | has("floor")) and floor_bad($p.floor) then
      "profile " + $p.model + " floor needs scope, min_percent 0..100 and no provider"
    else null end;
  (.rules // []) as $rules |
  [$rules | to_entries[] | select(.value | type == "object" and (.when | type) == "string" and (.when | startswith($prefix)))] as $found |
  if ($found | length) == 0 then
    {error: ("no rule whose when starts with \"" + $prefix + "\"")}
  elif ($found | length) > 1 then
    {error: ("more than one rule starts with \"" + $prefix + "\"")}
  else
    $found[0] as $e | $e.value as $r |
    (profiles($r.use)) as $use |
    ($r.fallback // []) as $fallback |
    if ($use | length) == 0 then {error: "the review rule has no use profiles"}
    elif any($use[]; profile_bad(.) != null) then {error: ("review rule: " + ([$use[] | profile_bad(.) | select(. != null)] | first))}
    elif (($use | map([.harness, .model, (.effort // null)] | @json)) | (length != (unique | length))) then
      {error: "review rule use must not contain duplicate harness, model, and effort profiles"}
    elif ($r | has("fallback")) and (($fallback | valid_fallback) | not) then {error: fallback_error}
    elif (.task_horizon_minutes != null) and (((.task_horizon_minutes | type) != "number") or .task_horizon_minutes <= 0) then
      {error: "task_horizon_minutes must be a positive number when present"}
    else
      {rule: ("rule_" + (($e.key + 1) | tostring)), when: $r.when, use: $use, fallback: $fallback,
       horizon_minutes: (.task_horizon_minutes // $default_horizon)}
    end
  end') || fail "review rule selection failed for $RULES_PATH"
RULE_ERROR=$(jq -r '.error // empty' <<<"$RULE")
[ -z "$RULE_ERROR" ] || fail "$RULE_ERROR"
HORIZON_SECONDS=$(jq -r '.horizon_minutes * 60 | floor' <<<"$RULE")

# ---- evidence: one quota snapshot, one pooled omp report -----------------------
command -v quota-axi >/dev/null 2>&1 || fail 'quota-axi not installed'
# measured: value=10 date=2026-10-15 host=Mac-Studio margin=100x (three quota-axi --version runs, slowest 0.08s)
fm_quota_axi_compatible 10 || fail "quota-axi requires >= $FM_QUOTA_AXI_MIN; installed version is older, unreadable, or unparseable"
QUOTA="$TMP/quota.json"
# measured: value=30 date=2026-10-15 host=Mac-Studio margin=10x (three quota-axi --json runs, slowest 2.89s)
fm_run_timed 30 quota-axi --json > "$QUOTA" 2>/dev/null </dev/null || fail 'quota-axi --json failed'
fm_quota_json_valid < "$QUOTA" || fail 'quota-axi --json returned an invalid snapshot'

OMP_POOLS='{}'
omp_models=$(jq -r '[.use[], .fallback[]] | map(select(.harness == "omp" and (.model | startswith("openai-codex/"))) | .model) | unique[]' <<<"$RULE")
if [ -n "$omp_models" ]; then
  # measured: value=20 date=2026-10-15 host=Mac-Studio margin=100x (three omp usage runs, slowest 0.18s)
  omp_usage=$(fm_run_timed 20 omp usage --provider openai-codex --json 2>/dev/null </dev/null) || omp_usage='{}'
  [ -n "$omp_usage" ] || omp_usage='{}'
  while IFS= read -r omp_model; do
    pool=$(fm_omp_codex_capacity "$omp_model" "$omp_usage")
    OMP_POOLS=$(jq -cn --argjson pools "$OMP_POOLS" --arg m "$omp_model" --argjson p "$pool" '$pools + {($m): $p}')
  done <<<"$omp_models"
fi

# ---- per-candidate evaluation --------------------------------------------------
# One jq program judges quota-side gates for a candidate; shell judges the
# launch policy and the model-index preflight first.
# shellcheck disable=SC2016 # jq program text, not shell expansion.
ASSESS_JQ='
  . as $c |
  def bare($m): ($m | split("/") | last);
  def rows($p; $lane): (quota_row($q; $p; $lane) | .quotaSemantics.effectiveAvailability // []);
  def measured($p; $lane):
    (quota_row($q; $p; $lane)) as $r |
    ($r != null and (["known", "partial"] | index($r.quotaSemantics.status)) != null);
  def applicable($p; $lane; $m):
    [rows($p; $lane)[] | select(
      .scope == "all_models" or .scope == "all_products" or
      ($m != "" and (.scope == ("model:" + bare($m)) or .scope == ("product:" + bare($m)))))];
  def floor_state($f; $p; $lane):
    if $f == null then "none"
    elif ($p == null) or (quota_row($q; $p; $lane) == null) or (measured($p; $lane) | not) then "unknown"
    else [rows($p; $lane)[] | select(.scope == $f.scope)] as $m |
      if ($m | length) == 0 or any($m[]; .status != "known") then "unknown"
      elif any($m[]; .effectivePercentRemaining < $f.min_percent) then "below"
      else "ok" end
    end;
  def runway_class($row):
    ($row.runway.status // "unknown") as $s |
    if $s == "through_reset" then "ok"
    elif $s == "projected_exhaustion" and ($row.runway.projectionConfidence // "") == "established"
      and (($row.runway.usableRunwaySeconds | type) == "number") then
      (if $row.runway.usableRunwaySeconds < $horizon then "short" else "ok" end)
    else "warn" end;
  def runway_note($row):
    ($row.runway.status // "unknown") as $s |
    if $s == "projected_exhaustion"
    then "projected_exhaustion at \($row.scope) (usableRunwaySeconds=\($row.runway.usableRunwaySeconds // "unknown"))"
    else "runway \($s) at \($row.scope)" end;
  def evidence($rows):
    $rows | map({scope, pct: (.effectivePercentRemaining // null), runway: (.runway.status // null),
                 spendPriority: (.selection.spendPriority // null)});
  def base: {profile: $c, provider: $provider, tier: "primary", spendPriority: null, pct: null,
             scope: null, runway: null, exhausted: false, unknown: false, uncertainty: []};
  if $c.harness == "omp" and (($c.model // "") | startswith("openai-codex/")) then
    ($pool // {status: "unknown", accounts: []}) as $p |
    base + {provider: "codex", scope: "omp-pool", pct: ($p.bestAccountHeadroom // null), capacity: $p} +
    (if ($c.floor // null) != null then
       {eligible: ($p.status != "exhausted"), unknown: true, uncertainty: ["profile floor cannot be verified against an OMP pool"],
        reason: "OMP pooled Codex capacity \($p.status); profile floor is unverifiable"}
     elif $p.status == "usable" then
       {eligible: true, reason: "OMP pooled Codex capacity usable; the pool reports no spendPriority"}
     elif $p.status == "exhausted" then
       {eligible: false, exhausted: true, reason: "OMP pooled Codex capacity exhausted"}
     else
       {eligible: true, unknown: true, uncertainty: ["OMP pooled Codex capacity unknown"],
        reason: "OMP pooled Codex capacity unknown"}
     end)
  elif $provider == null then
    base + {eligible: false, reason: "no provider family for harness \($c.harness); declare provider on the profile"}
  elif quota_row($q; $provider; $lane) == null then
    base + {eligible: true, unknown: true,
            uncertainty: ["no quota row for provider \($provider)"],
            reason: (if any($q.providers[]?; .provider == $provider)
                     then "provider \($provider) has no quota row for account \(if $lane == "" then "default" else $lane end)"
                     else "provider \($provider) is not in the quota snapshot" end)}
  else
    (applicable($provider; $lane; ($c.model // ""))) as $rows |
    (evidence($rows)) as $bounds |
    (floor_state($c.floor // null; $provider; $lane)) as $fs |
    base + {bounds: $bounds} +
    (if $fs == "below" then
       {eligible: false, reason: "profile floor \($c.floor.scope) below \($c.floor.min_percent)%"}
     elif any($rows[]; (.runway.status // "") == "exhausted_now") then
       ($rows | map(select((.runway.status // "") == "exhausted_now")) | first) as $b |
       {eligible: false, exhausted: ($fs != "unknown"), scope: $b.scope, pct: ($b.effectivePercentRemaining // null),
        runway: "exhausted_now", reason: "runway exhausted_now at \($b.scope)"}
     elif any($rows[]; .status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0) then
       ($rows | map(select(.status == "known" and (.effectivePercentRemaining | type) == "number" and .effectivePercentRemaining <= 0)) | first) as $b |
       {eligible: false, exhausted: ($fs != "unknown"), scope: $b.scope, pct: $b.effectivePercentRemaining,
        runway: ($b.runway.status // null), reason: "0% remaining at \($b.scope)"}
     elif (measured($provider; $lane) | not) then
       {eligible: true, unknown: true, uncertainty: ["provider \($provider) unmeasured"],
        reason: "provider \($provider) unmeasured (\(quota_row($q; $provider; $lane).quotaSemantics.status))"}
     elif ($rows | length) == 0 then
       {eligible: true, unknown: true, uncertainty: ["no applicable quota row"],
        reason: "no applicable quota row for provider \($provider)"}
     elif $fs == "unknown" then
       {eligible: true, unknown: true, uncertainty: ["profile floor \($c.floor.scope) is unverifiable"],
        reason: "profile floor \($c.floor.scope) is unverifiable"}
     elif any($rows[]; .status != "known") then
       ($rows | map(select(.status != "known")) | first) as $b |
       {eligible: true, unknown: true, scope: $b.scope, uncertainty: ["quota row \($b.scope) unknown"],
        reason: "quota row \($b.scope) unknown"}
     else
       ($rows | map(select(runway_class(.) == "short"))) as $short |
       ($rows | map(select(runway_class(.) == "warn"))) as $warn |
       if ($short | length) > 0 then
         {eligible: false, scope: $short[0].scope, pct: $short[0].effectivePercentRemaining,
          runway: $short[0].runway.status,
          reason: "established runway \($short[0].runway.usableRunwaySeconds)s at \($short[0].scope) is shorter than the \($horizon)s task horizon"}
       elif any($rows[]; (.selection.spendPriority | type) != "number") then
         ($rows | map(select((.selection.spendPriority | type) != "number")) | first) as $b |
         {eligible: true, unknown: true, scope: $b.scope, pct: $b.effectivePercentRemaining, runway: ($b.runway.status // null),
          uncertainty: (["spendPriority missing or non-numeric at \($b.scope)"] + ($warn | map(runway_note(.)))),
          reason: "spendPriority missing or non-numeric at \($b.scope)"}
       else
         ($rows | min_by(.selection.spendPriority)) as $l |
         {eligible: true, scope: $l.scope, pct: $l.effectivePercentRemaining,
          spendPriority: $l.selection.spendPriority, runway: ($l.runway.status // null),
          uncertainty: ($warn | map(runway_note(.))), reason: "ok"}
       end
     end)
  end'

# preflight <harness> <model>; prints a refusal reason and returns 1, or prints
# any notice and returns 0. Mirrors the chosen-profile preflight of the resolver.
preflight() {
  local h=$1 m=$2 account context=selected out rc
  python3 "$SCRIPT_DIR/fm-dsh.py" check "$h" "$m" "${3:-}" 2>&1 || return 1
  if ! fm_session_launch_policy_check "$CONFIG" "$h" >"$TMP/policy.out" 2>&1; then
    printf 'session launch policy refuses harness %s\n' "$h"
    return 1
  fi
  if [ ! -e "$CONFIG/model-index.json" ] && [ ! -L "$CONFIG/model-index.json" ]; then
    printf 'no model index: catalog not checked\n'
    return 0
  fi
  account=$(fm_worker_account_resolve "$h" "$CONFIG" 2>"$TMP/account.err") \
    || { printf 'worker account pin for %s does not resolve\n' "$h"; return 1; }
  if [ "$h" = claude ] && { [ -e "$CONFIG/claude-launcher" ] || [ -L "$CONFIG/claude-launcher" ]; }; then
    context=unavailable
  fi
  rc=0
  out=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" fm_worker_account_check_entry "$account" \
    "$SCRIPT_DIR/fm-model-index.sh" "$h" "$m" "$context" 2>&1 >/dev/null </dev/null) || rc=$?
  out=$(printf '%s\n' "$out" | sed -n '1p')
  if [ "$rc" -ne 0 ]; then
    printf 'model index refuses %s %s: %s\n' "$h" "$m" "${out:-no detail}"
    return 1
  fi
  [ -z "$out" ] || printf '%s\n' "$out"
  return 0
}

CANDIDATES='[]'
while IFS= read -r profile; do
  [ -n "$profile" ] || continue
  h=$(jq -r .harness <<<"$profile")
  m=$(jq -r .model <<<"$profile")
  provider=$(jq -r '.provider // empty' <<<"$profile")
  [ -n "$provider" ] || provider=$(fm_quota_single_provider_for_harness "$h" 2>/dev/null || true)
  if [ -z "$provider" ] && ! { [ "$h" = omp ] && [[ "$m" == openai-codex/* ]]; }; then
    fail "review rule: harness $h has no single provider family; declare provider on the $m profile"
  fi
  lane=$(jq -rn --arg h "$h" --arg m "$m" "$FM_QUOTA_ROW_JQ"'quota_lane($h; $m)')
  pre_rc=0
  pre=$(preflight "$h" "$m" "$provider") || pre_rc=$?
  if [ "$pre_rc" -ne 0 ]; then
    cand=$(jq -cn --argjson c "$profile" --arg provider "$provider" --arg reason "$pre" \
      '{profile: $c, provider: (if $provider == "" then null else $provider end), tier: "primary",
        eligible: false, exhausted: false, unknown: false, spendPriority: null, pct: null, scope: null,
        runway: null, uncertainty: [], reason: $reason}')
  else
    pool=$(jq -c --arg m "$m" '.[$m] // null' <<<"$OMP_POOLS")
    cand=$(jq -c --slurpfile quota "$QUOTA" --arg provider "$provider" --arg lane "$lane" \
      --argjson pool "$pool" --argjson horizon "$HORIZON_SECONDS" \
      "$FM_QUOTA_ROW_JQ"'$quota[0] as $q | ($provider | if . == "" then null else . end) as $provider | '"$ASSESS_JQ" <<<"$profile") \
      || fail "quota evaluation failed for $h:$m"
    if [ -n "$pre" ]; then
      cand=$(jq -c --arg note "$pre" '.uncertainty += [$note]' <<<"$cand")
    fi
  fi
  CANDIDATES=$(jq -c --argjson c "$cand" '. + [$c]' <<<"$CANDIDATES")
done < <(jq -c '.use[]' <<<"$RULE")

# ---- fallback tier: only on proven exhaustion of every primary -----------------
FALLBACKS='[]'
if jq -e 'length > 0 and all(.[]; .exhausted == true)' <<<"$CANDIDATES" >/dev/null; then
  while IFS= read -r profile; do
    [ -n "$profile" ] || continue
    h=$(jq -r .harness <<<"$profile")
    m=$(jq -r .model <<<"$profile")
    if [ "$h" = dsh ]; then
      cand=$(jq -cn --argjson c "$profile" \
        '{profile: $c, provider: "deepseek", tier: "fallback", eligible: false, exhausted: false, unknown: false,
          spendPriority: null, pct: null, scope: null, runway: null, uncertainty: [],
          reason: "DeepSeek requires dsh-tui, which has no verified no-mistakes review-agent transport"}')
    elif fm_dispatch_fallback_supported "$CONFIG" "$profile" "$CONFIG" >/dev/null 2>&1; then
      capacity=$(fm_dispatch_fallback_capacity "$profile")
      state=$(jq -r '.status // "unknown"' <<<"$capacity")
      if [ "$state" = exhausted ]; then
        reason="declared fallback capacity exhausted"
      else
        reason="declared fallback; capacity $state"
      fi
      cand=$(jq -cn --argjson c "$profile" --argjson cap "$capacity" --arg state "$state" --arg reason "$reason" \
        '{profile: $c, provider: null, tier: "fallback", eligible: ($state != "exhausted"),
          exhausted: ($state == "exhausted"), unknown: ($state == "unknown"), spendPriority: null, pct: null,
          scope: null, runway: null, capacity: $cap, reason: $reason,
          uncertainty: (if $state == "unknown" then ["fallback capacity unknown"] else [] end)}')
    else
      cand=$(jq -cn --argjson c "$profile" \
        '{profile: $c, provider: null, tier: "fallback", eligible: false, exhausted: false, unknown: false,
          spendPriority: null, pct: null, scope: null, runway: null, uncertainty: [],
          reason: "declared fallback is not supported on this home"}')
    fi
    FALLBACKS=$(jq -c --argjson c "$cand" '. + [$c]' <<<"$FALLBACKS")
  done < <(jq -c '.fallback[]' <<<"$RULE")
fi

# ---- selection ------------------------------------------------------------------
CURRENT=$(
  f="$NM_HOME/config.yaml"
  if [ -r "$f" ]; then
    awk '/^agent:/ { v = $0; sub(/^agent:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); print v; exit }' "$f" 2>/dev/null \
      | jq -Rsc '{agent: (split("\n") | map(select(length > 0)) | first // null)}'
  else
    printf 'null\n'
  fi
)
[ -n "$CURRENT" ] || CURRENT=null

RESULT=$(jq -cn --argjson primary "$CANDIDATES" --argjson fallback "$FALLBACKS" --argjson rule "$RULE" \
  --argjson current "$CURRENT" --argjson at "$RUN_AT" --arg horizon "$HORIZON_SECONDS" '
  def agent_of($p): if $p.harness == "omp" then "acp:omp" else $p.harness end;
  def cname($c): "\($c.profile.harness):\($c.profile.model)";
  ($primary | to_entries | map(.value + {order: .key})) as $p |
  [$p[] | select(.eligible)] as $elig |
  [$elig[] | select((.spendPriority | type) == "number")] as $ranked |
  [$elig[] | select((.spendPriority | type) != "number" and (.unknown | not))] as $usable_unranked |
  [$elig[] | select((.spendPriority | type) != "number" and .unknown)] as $unknown |
  (if ($ranked | length) > 0 then
     ($ranked | max_by(.spendPriority)) as $top |
     [$ranked[] | select(.spendPriority == $top.spendPriority)] as $ties |
     if ($ties | length) > 1 then
       {status: "tie", reason: "genuine quota evidence tie at spendPriority \($top.spendPriority): \($ties | map(cname(.)) | join(", ")); captain choice",
        chosen: null}
     else
       {status: "selected", chosen: $top, tier: "primary",
        reason: ("highest known spendPriority \($top.spendPriority) among \($ranked | length) ranked candidate(s)"
          + (if ($usable_unranked | length) + ($unknown | length) > 0
             then "; unranked, disclosed: " + ([$usable_unranked[], $unknown[]] | map(cname(.)) | join(", ")) else "" end))}
     end
   elif ($usable_unranked | length) == 1 then
     {status: "selected", chosen: $usable_unranked[0], tier: "primary",
      reason: ("no candidate carries a known spendPriority; " + cname($usable_unranked[0])
        + " is the only one with measured headroom"
        + (if ($unknown | length) > 0 then "; unmeasured, disclosed: " + ($unknown | map(cname(.)) | join(", ")) else "" end))}
   elif ($usable_unranked | length) > 1 then
     {status: "escalate", chosen: null,
      reason: "cannot rank without spendPriority: \($usable_unranked | map(cname(.)) | join(", ")); captain choice"}
   elif ($unknown | length) > 0 then
     {status: "escalate", chosen: null,
      reason: "no candidate has measured headroom: \($unknown | map(cname(.) + " (" + .reason + ")") | join("; "))"}
   elif ($p | length) > 0 and all($p[]; .exhausted) then
     ($fallback | map(select(.eligible)) | first) as $fb |
     if $fb != null then
       {status: "selected", chosen: $fb, tier: "fallback",
        reason: "every use candidate is proven exhausted; declared fallback \(cname($fb)) (\($fb.reason))"}
     else
       {status: "escalate", chosen: null,
        reason: (if ($rule.fallback | length) == 0
                 then "every candidate is proven exhausted and the rule declares no fallback"
                 else "every candidate is proven exhausted and no declared fallback is usable" end)}
     end
   else
     {status: "escalate", chosen: null,
      reason: "no eligible candidate: \($p | map(cname(.) + " (" + .reason + ")") | join("; "))"}
   end) as $sel |
  {schema: "fm-review-agent-select.v1", at: $at, mode: "dry-run", status: $sel.status, reason: $sel.reason,
   rule: $rule.rule, when: ($rule.when | .[0:80]), horizon_minutes: $rule.horizon_minutes,
   selected: (if $sel.chosen == null then null else
     {harness: $sel.chosen.profile.harness, model: $sel.chosen.profile.model, effort: ($sel.chosen.profile.effort // null),
      agent: agent_of($sel.chosen.profile), tier: $sel.tier, spendPriority: $sel.chosen.spendPriority} end),
   current: $current,
   candidates: (($primary + $fallback) | map({harness: .profile.harness, model: .profile.model, effort: (.profile.effort // null),
     provider, tier, eligible, exhausted, unknown, spendPriority, pct, scope, runway, reason, uncertainty,
     bounds: (.bounds // null), capacity: (.capacity // null)}))}')
[ -n "$RESULT" ] || fail 'selection failed'

STATUS=$(jq -r .status <<<"$RESULT")
if [ "$LOG" = 1 ]; then
  jq -c --arg at_iso "$(date -u -r "$RUN_AT" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {at_iso: $at_iso}' <<<"$RESULT" >> "$LOG_FILE" 2>/dev/null \
    || fail "could not append to $LOG_FILE"
fi

jq -r '
  def flat: tostring | gsub("[\t\r\n]"; " ");
  def show($v): ($v // "-") | flat;
  "review-agent-select: dry-run (nothing written)",
  "  status: \(.status | flat)",
  "  rule: \(.rule | flat) (\(.when | flat))   horizon_minutes: \(.horizon_minutes)",
  (if .selected then "  selected: \(.selected.harness | flat):\(.selected.model | flat) effort=\(show(.selected.effort)) agent=\(.selected.agent | flat) tier=\(.selected.tier)" else empty end),
  "  reason: \(.reason | flat)",
  "  current: " + (if .current == null then "no readable no-mistakes config" else "agent=\(show(.current.agent))" end),
  (.candidates[] | "  candidate: \(.harness | flat):\(.model | flat)  provider=\(show(.provider))  tier=\(.tier)"
     + (if .scope then "  scope=\(.scope | flat)  remaining=\(show(.pct))%  spendPriority=\(show(.spendPriority))  runway=\(show(.runway))"
        else "  spendPriority=\(show(.spendPriority))" end)
     + "  -> " + (if .eligible then "eligible" else "not eligible" end) + ": \(.reason | flat)"
     + (if (.uncertainty | length) > 0 then " [uncertain: \(.uncertainty | join("; ") | flat)]" else "" end))' <<<"$RESULT"

[ "$STATUS" = selected ]
