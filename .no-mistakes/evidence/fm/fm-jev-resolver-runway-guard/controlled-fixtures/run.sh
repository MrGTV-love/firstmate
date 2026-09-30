#!/usr/bin/env bash
set -u
LAB=/tmp/fm-resolve-ctl.qeAejy; WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M3SM79EHZ5WH772ET5STB864
BRIEF=/Users/charlesabrooker/firstmate/data/fm-jev-resolver-runway-guard/brief.md
OUT=$LAB/controlled-runs.txt; : > $OUT
KEY=<read from firstmate .env; value not recorded>
POOL='.rules[6].use'
CODEX='(.providers[] | select(.provider=="codex") | .quotaSemantics.effectiveAvailability[])'
pass=0; fail=0
run() { # id title rules_jq quota_jq version expect_status must must_not [expect_exit]
  local id=$1 title=$2 rjq=$3 qjq=$4 ver=$5 est=$6 must=$7 mustnot=$8 eexit=${9:-0}
  jq "$rjq" $LAB/home/config/crew-dispatch.json.base > $LAB/home/config/crew-dispatch.json
  jq "$qjq" $LAB/live-snapshot.json > $LAB/fixtures/$id.json
  { echo "### $id: $title  ($(date -u +%FT%TZ))"
    echo "# evidence class: CONTROLLED CLI (fixture quota via stand-in quota-axi; lab FM_HOME rules copy; real Jev API call). Not a live provider reading."
    echo "# rules transform: $rjq"
    echo "# quota fixture transform (on live snapshot generatedAt $(jq -r .generatedAt $LAB/live-snapshot.json)): $qjq"
    echo "# quota-axi --version -> $ver"
    echo "\$ bin/fm-dispatch-resolve.sh $BRIEF --project firstmate"; } >> $OUT
  local res rc
  res=$(cd $WT && env TYPESAFE_API_KEY="$KEY" FM_HOME=$LAB/home CTL_QUOTA_VERSION=$ver CTL_QUOTA_FIXTURE=$LAB/fixtures/$id.json PATH="$LAB/bin:$PATH" bin/fm-dispatch-resolve.sh $BRIEF --project firstmate 2>&1); rc=$?
  printf '%s\nexit=%s\n' "$res" "$rc" >> $OUT
  local ok=1
  [ "$rc" = "$eexit" ] || ok=0
  [ -n "$est" ] && { printf '%s\n' "$res" | grep -q "status: $est" || ok=0; }
  [ -n "$must" ] && { printf '%s\n' "$res" | grep -qF -- "$must" || ok=0; }
  [ -n "$mustnot" ] && { printf '%s\n' "$res" | grep -qF -- "$mustnot" && ok=0; }
  if [ $ok = 1 ]; then echo "# check: PASS (exit=$eexit status=$est must='$must' must_not='$mustnot')" >> $OUT; pass=$((pass+1)); echo "PASS $id"; else echo "# check: FAIL" >> $OUT; fail=$((fail+1)); echo "FAIL $id"; printf '%s\nexit=%s\n' "$res" "$rc"; fi
  echo >> $OUT
}
EST='.runway.status="projected_exhaustion" | .runway.projectionConfidence="established"'
run K "report case: codex 6% remaining, established exhaustion in 1800s" . "$CODEX |= (.effectivePercentRemaining=6 | $EST | .runway.usableRunwaySeconds=1800)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run A "established 3600s < 240-min horizon" . "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run B "early 3600s projection is warning only" . "$CODEX |= (.runway.status=\"projected_exhaustion\" | .runway.projectionConfidence=\"early\" | .runway.usableRunwaySeconds=3600)" 0.1.55 clear "projectionConfidence=early)]" ""
run C "absent confidence and seconds is warning only" . "$CODEX |= (.runway.status=\"projected_exhaustion\" | del(.runway.projectionConfidence) | del(.runway.usableRunwaySeconds))" 0.1.55 clear "projectionConfidence=unknown)]" ""
run D "established exactly 14400s clears without warning" . "$CODEX |= ($EST | .runway.usableRunwaySeconds=14400)" 0.1.55 clear "profile: --harness 'omp'" "[warning:"
run E1 "task_horizon_minutes=30 lets established 3600s clear" '. + {task_horizon_minutes: 30}' "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 clear "profile: --harness 'omp'" "[warning:"
run E2 "task_horizon_minutes=120 escalates established 3600s" '. + {task_horizon_minutes: 120}' "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 escalate "shorter than the 120-minute task horizon" "profile:"
run E3 "task_horizon_minutes=0 is a config error" '. + {task_horizon_minutes: 0}' "$CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 "" "task_horizon_minutes must be a positive number" "profile:" 2
run F "exhausted_now on pool visible account: eligible unranked with warning, not vetoed" . "$CODEX |= (.runway.status=\"exhausted_now\" | .effectivePercentRemaining=0 | .runway.usableRunwaySeconds=0)" 0.1.55 escalate "eligible, unranked: omp Codex account pool" "not eligible"
run F-nonpool "exhausted_now on single codex harness (outside pool) remains a veto" "$POOL = {harness: \"codex\", model: \"gpt-6.1-sol\", effort: \"high\"}" "$CODEX |= (.runway.status=\"exhausted_now\" | .effectivePercentRemaining=0 | .runway.usableRunwaySeconds=0)" 0.1.55 escalate "not eligible" "profile:"
CURSOR='(.providers[] | select(.provider=="cursor") | .quotaSemantics) = {status: "known", effectiveAvailability: [{scope: "all_models", status: "known", effectivePercentRemaining: 95, runway: {status: "through_reset"}, selection: {spendPriority: -9.5}}]}'
run H "short pool winner escalates; lower-ranked cursor not used" "$POOL = [$POOL, {harness: \"cursor\", model: \"cursor-grok-4.6-medium\"}]" "$CURSOR | $CODEX |= ($EST | .runway.usableRunwaySeconds=3600)" 0.1.55 escalate "shorter than the 240-minute task horizon" "profile:"
run H-control "healthy pool + cursor clears on the pool" "$POOL = [$POOL, {harness: \"cursor\", model: \"cursor-grok-4.6-medium\"}]" "$CURSOR | $CODEX |= ($EST | .runway.usableRunwaySeconds=79737)" 0.1.55 clear "profile: --harness 'omp'" "--harness 'cursor'"
run J "quota-axi 0.1.50 is below minimum" . . 0.1.50 error "quota-axi requires >= 0.1.51" "profile:"
echo "pass=$pass fail=$fail" | tee -a $OUT
