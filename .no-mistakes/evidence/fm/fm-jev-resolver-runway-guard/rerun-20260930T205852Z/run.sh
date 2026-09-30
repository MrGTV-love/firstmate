#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-resolve.sh (head 70d27be) with a real Jev call.
# LIVE runs use the real quota-axi. CONTROLLED runs put a stand-in quota-axi first on PATH
# that serves a jq transform of one real snapshot taken at the start of this run.
set -u
EV=$1
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M3SM79EHZ5WH772ET5STB864
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-resolve-ctl.XXXXXX")
mkdir -p "$LAB/home/config" "$LAB/bin"
cp /Users/charlesabrooker/firstmate/config/crew-dispatch.json "$LAB/home/config/crew-dispatch.json.base"
[ -f /Users/charlesabrooker/firstmate/config/dispatch-never-send ] && cp /Users/charlesabrooker/firstmate/config/dispatch-never-send "$LAB/home/config/"
cp "$EV/quota-axi-standin.sh" "$LAB/bin/quota-axi"
KEY=$(sed -n 's/^TYPESAFE_API_KEY=//p' /Users/charlesabrooker/firstmate/.env | head -1)
quota-axi --json > "$EV/fixtures/base-live-snapshot.json"
D=/Users/charlesabrooker/firstmate/data
BRIEF=$D/fm-jev-resolver-runway-guard/brief.md
OUT=$EV/runs.txt; : > "$OUT"
POOL='.rules[6].use'
CODEX='(.providers[] | select(.provider=="codex") | .quotaSemantics.effectiveAvailability[])'
EST='.runway.status="projected_exhaustion" | .runway.projectionConfidence="established"'
pass=0; fail=0
# run id class title rules_jq quota_jq(or LIVE) version expect_status must must_not [expect_exit] [brief]
run() {
  local id=$1 cls=$2 title=$3 rjq=$4 qjq=$5 ver=$6 est=$7 must=$8 mustnot=$9 eexit=${10:-0} brief=${11:-$BRIEF}
  jq "$rjq" "$LAB/home/config/crew-dispatch.json.base" > "$LAB/home/config/crew-dispatch.json"
  local path=$PATH
  { echo "### $id: $title  ($(date -u +%FT%TZ))"
    if [ "$qjq" = LIVE ]; then
      echo "# evidence class: LIVE (real quota-axi $(quota-axi --version), real Jev API, lab FM_HOME with a copy of the live rules file)"
    else
      jq "$qjq" "$EV/fixtures/base-live-snapshot.json" > "$EV/fixtures/$id.json"
      path="$LAB/bin:$PATH"
      echo "# evidence class: CONTROLLED CLI (stand-in quota-axi serves fixtures/$id.json; real Jev API; lab FM_HOME rules copy). Not a live provider reading."
      echo "# quota fixture transform (on real snapshot generatedAt $(jq -r .generatedAt "$EV/fixtures/base-live-snapshot.json")): $qjq"
      echo "# stand-in quota-axi --version -> $ver"
    fi
    echo "# rules transform: $rjq"
    echo "\$ bin/fm-dispatch-resolve.sh $brief --project firstmate"; } >> "$OUT"
  local res rc
  res=$(cd "$WT" && env -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE TYPESAFE_API_KEY="$KEY" FM_HOME="$LAB/home" CTL_QUOTA_VERSION="$ver" CTL_QUOTA_FIXTURE="$EV/fixtures/$id.json" PATH="$path" bin/fm-dispatch-resolve.sh "$brief" --project firstmate 2>&1); rc=$?
  printf '%s\nexit=%s\n' "$res" "$rc" >> "$OUT"
  local ok=1
  [ "$rc" = "$eexit" ] || ok=0
  [ -z "$est" ] || { printf '%s\n' "$res" | grep -q "status: $est" || ok=0; }
  [ -z "$must" ] || { printf '%s\n' "$res" | grep -qF -- "$must" || ok=0; }
  [ -z "$mustnot" ] || { printf '%s\n' "$res" | grep -qF -- "$mustnot" && ok=0; }
  if [ $ok = 1 ]; then echo "# check: PASS (exit=$eexit status=$est must='$must' must_not='$mustnot')" >> "$OUT"; pass=$((pass+1)); echo "PASS $id"
  else echo "# check: FAIL (expected exit=$eexit status=$est must='$must' must_not='$mustnot')" >> "$OUT"; fail=$((fail+1)); echo "FAIL $id"; printf '%s\nexit=%s\n' "$res" "$rc"; fi
  echo >> "$OUT"
}
# ---- LIVE: four real intakes, real quota
for b in fm-jev-resolver-runway-guard fm-jev-mem-guard-macos fm-jev-never-send-sections fm-jev-resolver-observability; do
  run "L-$b" LIVE "real intake $b on live quota" . LIVE "" "" "status:" "" 0 "$D/$b/brief.md"
done
# ---- LIVE: guard edges that need no quota change
run G LIVE "captain profile floor 90% on the omp pool stays a veto" "$POOL += {floor: {scope: \"all_models\", min_percent: 90}}" LIVE "" escalate "not eligible: profile floor all_models below 90%" "profile:"
run I LIVE "omp OpenRouter candidate is eligible, unranked; pool still clears with unranked note" "$POOL = [$POOL, {harness: \"omp\", model: \"openrouter/moonshotai/kimi-k3\", provider: \"openrouter\"}]" LIVE "" "" "eligible, unranked: provider openrouter" ""
# ---- CONTROLLED
run K CTL "report case: codex 6% remaining, established exhaustion in 1800s" . "$CODEX |= (.effectivePercentRemaining=6 | $EST | .runway.usableRunwaySeconds=1800)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run A CTL "established 3600s < 240-min horizon" . "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run B CTL "early 3600s projection is warning only" . "$CODEX |= (.runway.status=\"projected_exhaustion\" | .runway.projectionConfidence=\"early\" | .runway.usableRunwaySeconds=3600)" 0.1.55 clear "projectionConfidence=early)]" ""
run C CTL "absent confidence and seconds is warning only" . "$CODEX |= (.runway.status=\"projected_exhaustion\" | del(.runway.projectionConfidence) | del(.runway.usableRunwaySeconds))" 0.1.55 clear "projectionConfidence=unknown)]" ""
run D CTL "established exactly 14400s clears without warning" . "$CODEX |= ($EST | .runway.usableRunwaySeconds=14400)" 0.1.55 clear "profile: --harness 'omp'" "[warning:"
run D-1 CTL "established 14399s (one second under) escalates" . "$CODEX |= ($EST | .runway.usableRunwaySeconds=14399)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run E1 CTL "task_horizon_minutes=30 lets established 3600s clear" '. + {task_horizon_minutes: 30}' "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 clear "profile: --harness 'omp'" "[warning:"
run E2 CTL "task_horizon_minutes=120 escalates established 3600s" '. + {task_horizon_minutes: 120}' "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 escalate "shorter than the 120-minute task horizon" "profile:"
run E3 CTL "task_horizon_minutes=0 is a config error" '. + {task_horizon_minutes: 0}' "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 "" "task_horizon_minutes must be a positive number" "profile:" 2
run F CTL "exhausted_now on pool visible account: eligible unranked with warning, not vetoed" . "$CODEX |= (.runway.status=\"exhausted_now\" | .effectivePercentRemaining=0 | .runway.usableRunwaySeconds=0)" 0.1.55 escalate "eligible, unranked: omp Codex account pool" "not eligible"
run F-nonpool CTL "exhausted_now on a single codex account (outside pool) stays a veto" "$POOL = {harness: \"codex\", model: \"gpt-6.1-sol\", effort: \"high\"}" "$CODEX |= (.runway.status=\"exhausted_now\" | .effectivePercentRemaining=0 | .runway.usableRunwaySeconds=0)" 0.1.55 escalate "not eligible: runway exhausted_now" "profile:"
CURSOR='(.providers[] | select(.provider=="cursor") | .quotaSemantics) = {status: "known", effectiveAvailability: [{scope: "all_models", status: "known", effectivePercentRemaining: 95, runway: {status: "through_reset"}, selection: {spendPriority: -9.5}}]}'
run H CTL "short pool winner escalates; lower-ranked cursor not used" "$POOL = [$POOL, {harness: \"cursor\", model: \"cursor-grok-4.6-medium\"}]" "$CURSOR | $CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run H-control CTL "healthy pool + cursor clears on the pool" "$POOL = [$POOL, {harness: \"cursor\", model: \"cursor-grok-4.6-medium\"}]" "$CURSOR | $CODEX |= ($EST | .runway.usableRunwaySeconds=79737)" 0.1.55 clear "profile: --harness 'omp'" "--harness 'cursor'"
run J CTL "quota-axi 0.1.50 is below minimum" . . 0.1.50 error "quota-axi requires >= 0.1.51" "profile:"
run J-min CTL "quota-axi exactly 0.1.51 is accepted" . . 0.1.51 "" "profile:" "quota-axi requires"
echo "pass=$pass fail=$fail" | tee -a "$OUT"
rm -rf "$LAB"
