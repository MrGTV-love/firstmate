#!/usr/bin/env bash
# Published-contribution behavior through Bearings and the authenticated checks.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-contributions)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  chmod +x "$home/fakebin/"*
  printf '%s\n' "$home"
}

bearings() {
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    FM_BEARINGS_NOW="$NOW" "$ROOT/bin/fm-bearings-snapshot.sh" --json
}

record() { # home id number forge-state mergeability [hold]
  local home=$1 id=$2 number=$3 state=$4 mergeable=$5 hold=${6:-}
  mkdir -p "$home/data/$id"
  printf -- '- [ ] %s - Contribution %s https://github.com/o/r/pull/%s (repo: sample) (kind: ship) %s\n' \
    "$id" "$id" "$number" "$hold" >> "$home/data/backlog.md"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$number" \
    --arg head "$HEAD_A" --arg at "$NOW" --arg state "$state" --arg mergeable "$mergeable" '
    {schema:"fm-contributions.v1",task:$task,records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:$state,draft:false,mergeable:$mergeable,
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/$id/contributions.json"
}

mutate_record() {
  jq "$3" "$1/data/$2/contributions.json" > "$1/update.json" || fail 'fixture mutation failed'
  mv "$1/update.json" "$1/data/$2/contributions.json"
}

test_actor_coverage() {
  local home out
  home=$(new_home actors)
  record "$home" own 1 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" repair 2 open conflicting
  record "$home" external 3 open mergeable
  record "$home" landed 4 merged mergeable
  out=$(bearings "$home") || fail 'Bearings could not read contribution fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 4 and .contributions.checked == 4
    and .contributions.counts == {captain:1,fleet:1,maintainer:1,nobody:1}
    and (.contributions.captain | length) == 1
    and .contributions.captain[0].url == "https://github.com/o/r/pull/1"
    and .contributions.complete == true and .contributions.proven_clear == false' >/dev/null \
    || fail "published deliveries must report actors and measured coverage: $out"
  pass 'only required-captain contributions are rows; other actors are counted'
}

test_stale_verdict() {
  local home out
  home=$(new_home stale)
  record "$home" changed 5 open mergeable
  mutate_record "$home" changed ".records[0].verdict = {head:\"$HEAD_B\",actor:\"captain\",source:\"https://github.com/o/r/pull/5#issuecomment-8\",summary:\"choose contract\"}"
  out=$(bearings "$home") || fail 'Bearings could not read stale verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.stale_verdicts == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail "a verdict on a replaced head must be STALE, not current captain work: $out"
  pass 'replaced-head verdict is stale and cannot create a captain requirement'
}

test_unchecked_is_not_silence() {
  local home out
  home=$(new_home unchecked)
  printf -- '- [ ] unseen - Unchecked https://github.com/o/r/pull/6 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(bearings "$home") || fail 'Bearings could not read unchecked fixture'
  printf '%s' "$out" | jq -e '
    .contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail "no observation must not become a proven empty actionable set: $out"
  pass 'unchecked ownership is disclosed and cannot prove silence'
}

test_newest_check_has_no_verdict() {
  local home out
  home=$(new_home no-verdict)
  record "$home" missing 7 open mergeable
  mutate_record "$home" missing '.records[0].observation.checks += [{name:"test",id:2,status:"completed",conclusion:null,started_at:"2026-09-16T08:00:01Z"}]'
  out=$(bearings "$home") || fail 'Bearings could not read missing verdict fixture'
  printf '%s' "$out" | jq -e '
    .contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1
    and .contributions.counts.maintainer == 0' >/dev/null \
    || fail "newest distinct check must not inherit an earlier success: $out"
  pass 'newest check with no verdict is distinct from passing and pending'
}


forge_home() {
  local home=$1
  mkdir -p "$home/forge" "$home/root/bin" "$home/wt"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  record "$home" delivery 8 open mergeable
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  printf '[]\n' > "$home/forge/labels.json"
  printf '[]\n' > "$home/forge/events.json"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
[ ! -e "$FORGE/snapshot-refuse" ] || exit 1
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8'|'api repos/o/r/pulls/9'|'api repos/o/r/pulls/10')
    [ ! -e "$FORGE/pull-fail" ] || exit 1
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" \
      --arg base "$(cat "$FORGE/base" 2>/dev/null || true)" --arg ref "$(cat "$FORGE/base-ref" 2>/dev/null || true)" '
      {base:{sha:$base,ref:$ref},state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:false,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -c . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -c . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -c . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -c . "$FORGE/inline.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    if [ -f "$FORGE/checks.json" ]; then cat "$FORGE/checks.json"; exit 0; fi
    printf '{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[]\n' ;;
  'api repos/o/r/compare/'*)
    [ ! -e "$FORGE/compare-fail" ] || exit 1
    if [ -e "$FORGE/compare-silent" ]; then printf '%s\n' "$$" > "$FORGE/hung-pid"; sleep 90; fi
    if [ -e "$FORGE/compare-corrupt" ]; then printf '{}\n'; exit 0; fi
    expected=$(jq -rn --rawfile ref "$FORGE/base-ref" '$ref | rtrimstr("\n") | @uri')
    [ "$*" = "api repos/o/r/compare/$expected...$(cat "$FORGE/head")?per_page=1" ] || exit 1
    jq -n --arg base "$(cat "$FORGE/base-tip" 2>/dev/null || cat "$FORGE/base")" \
      --arg built "$(cat "$FORGE/base")" --argjson behind "$(cat "$FORGE/behind")" \
      '{base_commit:{sha:$base},merge_base_commit:{sha:$built},behind_by:$behind}' ;;
  'api repos/o/r') jq -n --argjson push "$(cat "$FORGE/push" 2>/dev/null || printf false)" '{permissions:{push:$push}}' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
  fm_gh_http_shim "$home/fakebin"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" HEAD_A="$HEAD_A" GH_SHIM_LOG="$home/forge/shim.log" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    NM_HOME="$home/nm-home" FM_SNAPSHOT_NOW="${FM_SNAPSHOT_NOW:-$NOW}" FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

registered_checks() {
  local home=$1 check
  for check in "$home/state/"*.check.sh; do
    [ -f "$check" ] || continue
    with_home "$home" bash "$check" || fail 'registered check failed'
  done
}

test_incoming_signal() { # comment|review|inline
  local type=$1 home out count fixture wake_count
  case "$type" in comment) fixture=comments ;; review) fixture=reviews ;; *) fixture=inline ;; esac
  home=$(new_home "incoming-$type")
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" --arg type "$type" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}
    + (if $type == "comment" then {} else {commit_id:$head,state:"CHANGES_REQUESTED"} end)]' \
    > "$home/forge/$fixture.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail "new maintainer $type must survive as a pending outward signal"
  [ -s "$home/state/.wake-queue" ] || fail "new maintainer $type must enqueue an ordinary durable wake"
  count=$(wc -l < "$home/state/.wake-queue")
  wake_count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$wake_count" = 1 ] || fail "new maintainer $type must enqueue exactly one ordinary durable wake"
  registered_checks "$home" >/dev/null
  [ "$(wc -l < "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued event'
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$wake_count" ] || fail 're-poll duplicated an already enqueued event'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending)
  printf '%s' "$out" | jq -e 'length == 1 and .[0].author == "maintainer"' >/dev/null \
    || fail 'supervisor cannot retrieve captured signal'
  pass "new maintainer $type wakes once and stays pending until acknowledged"
}

test_ready_issue_wake() {
  local home count
  home=$(new_home ready)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery'
  registered_checks "$home" >/dev/null
  printf '[{"name":"ready-for-pr"}]\n' > "$home/forge/labels.json"
  registered_checks "$home" >/dev/null
  if [ ! -f "$home/data/filed/contributions.json" ] \
    || ! jq -e 'any(.records[].pending[]; .type == "ready-for-pr")' "$home/data/filed/contributions.json" >/dev/null; then
    fail 'ready-for-pr on an explicitly filed issue must become a planning wake'
  fi
  [ -s "$home/state/.wake-queue" ] || fail 'ready-for-pr signal never reached the durable wake path'
  count=$(awk 'END { print NR }' "$home/state/.wake-queue")
  [ "$count" = 1 ] || fail 'ready-for-pr signal must enqueue exactly one durable wake'
  registered_checks "$home" >/dev/null
  [ "$(awk 'END { print NR }' "$home/state/.wake-queue")" = "$count" ] || fail 're-poll duplicated an already enqueued ready-for-pr wake'
  pass 'ready-for-pr on a filed issue becomes a planning wake'
}

test_fresh_issue_requires_maintainer() {
  local home
  home=$(new_home fresh-issue)
  forge_home "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'could not observe filed issue'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 2
    and .contributions.counts.maintainer == 2 and .contributions.counts.fleet == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a fresh open issue did not remain measured maintainer triage'
  pass 'a fresh open issue remains measured maintainer triage'
}

test_comment_wake() { test_incoming_signal comment; }
test_review_wake() { test_incoming_signal review; }
test_inline_wake() { test_incoming_signal inline; }

test_missing_lane_remains_missing() {
  local home
  home=$(new_home absent-lane)
  forge_home "$home"
  mutate_record "$home" delivery '.records[0].observation.checks += [{name:"required-extra",id:2,status:"completed",conclusion:"success",started_at:"2026-09-16T07:59:00Z"}]'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'first poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'second poll failed'
  bearings "$home" | jq -e '.contributions.missing_verdicts == 1 and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'repeated polling erased the absent lane from measured readiness'
  pass 'an absent check lane remains missing across repeated observations'
}

test_partial_freshness_keeps_measured_rows() {
  local home
  home=$(new_home mixed-age)
  record "$home" current 10 open mergeable '(hold: choose scope) (hold-kind: captain)'
  record "$home" expired 11 open mergeable
  mutate_record "$home" expired '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.counts.captain == 1 and (.contributions.captain | length) == 1
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'one expired observation erased the independently measured captain row'
  pass 'mixed freshness retains measured captain work and discloses the gap'
}

test_malformed_record_cannot_prove_silence() {
  local home
  home=$(new_home malformed)
  record "$home" invalid 12 open mergeable
  mutate_record "$home" invalid '.records[0].observation.state="not-a-forge-state"'
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'malformed durable evidence was counted as checked'
  pass 'malformed durable evidence cannot prove silence'
}

test_issue_timeline_and_exact_ack() {
  local home token
  home=$(new_home issue-timeline)
  forge_home "$home"
  printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial poll failed'
  printf '[{"event":"labeled","id":88,"label":{"name":"ready-for-pr"}}]\n' > "$home/forge/events.json"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'timeline poll failed'
  token=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[] | select(.type=="ready-for-pr") | .token') \
    || fail 'add/remove between polls lost ready-for-pr transition'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack filed https://github.com/o/r/issues/9 "$token" || fail 'exact ack failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'post-ack poll failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null || fail 'acknowledged timeline event replayed'
  pass 'a transient ready-for-pr label wakes and its exact acknowledgement survives replay'
}

test_verdict_retains_judged_head() {
  local home
  home=$(new_home verdict-roundtrip)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 maintainer 'awaiting maintainer' || fail 'could not record judged head'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  printf 'pr=https://github.com/o/r/pull/8\npr_head=%s\n' "$HEAD_B" >> "$home/state/delivery.meta"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  bearings "$home" | jq -e '.contributions.stale_verdicts == 1 and .contributions.checked == 0' >/dev/null \
    || fail 'changed published head reused a current verdict'
  jq -e --arg head "$HEAD_A" '.records[0].verdict.head==$head' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'projection rewrote the judged head'
  pass 'recorded judgment keeps its exact head and is stale immediately on a published replacement'
}

test_verdict_actor_values_are_discoverable() {
  local home help out actor
  home=$(new_home verdict-actors)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before judging its head'
  help=$("$ROOT/bin/fm-contributions.sh" --help) || fail 'verdict help did not print'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
    https://github.com/o/r/pull/8#issuecomment-99 bogus 'no such actor' 2>&1) \
    && fail 'an unknown actor was accepted'
  [ "$(printf '%s\n' "$help" | sed -n '/^  fm-contributions.sh verdict /p')" = \
    '  fm-contributions.sh verdict <task> <url> <judged-head> <source-url> <captain|fleet|maintainer|nobody> <summary>' ] \
    || fail "help usage does not name exactly the accepted actors: $help"
  [ "$(printf '%s\n' "$help" | sed -n '/^actor is exactly one of /p')" = \
    'actor is exactly one of captain, fleet, maintainer or nobody; any other value' ] \
    || fail "help explanation does not name exactly the accepted actors: $help"
  [ "$out" = "fm-contributions: invalid required actor 'bogus'; expected one of: captain, fleet, maintainer, nobody" ] \
    || fail "refusal does not name exactly the accepted actors: $out"
  for actor in captain fleet maintainer nobody; do
    with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_A" \
      https://github.com/o/r/pull/8#issuecomment-99 "$actor" 'documented actor' >/dev/null \
      || fail "documented actor $actor was refused"
  done
  pass 'verdict help and refusal name exactly the actors the command accepts'
}

test_observed_replacement_refreshes_verdict() {
  local home
  home=$(new_home observed-replacement)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery before replacement'
  registered_checks "$home" >/dev/null
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  with_home "$home" "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 "$HEAD_B" \
    https://github.com/o/r/pull/8#issuecomment-100 maintainer 'awaiting maintainer' \
    || fail 'could not record verdict on the observed replacement'
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.stale_verdicts == 0
    and .contributions.counts.maintainer == 1 and .contributions.counts.fleet == 0' >/dev/null \
    || fail 'a current forge observation did not refresh a verdict on its observed head'
  pass 'a current forge observation refreshes a verdict after a replacement'
}

test_unobserved_head_leaves_verdict_unknown() {
  local home out
  home=$(new_home unobserved-head)
  record "$home" delivery 17 open mergeable
  mutate_record "$home" delivery ".records[0].error=\"forge unavailable\" | .records[0].verdict={head:\"$HEAD_B\",actor:\"maintainer\",source:\"https://github.com/o/r/pull/17#issuecomment-101\",summary:\"awaiting maintainer\"}"
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input without a forge read'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project unavailable forge observation'
  printf '%s' "$out" | jq -e '.stale_verdicts == 0 and .checked == 0
    and .rows[0].verdict.freshness == "unverified"' >/dev/null \
    || fail 'an unavailable current head became a fresh or stale verdict'
  pass 'an unavailable current head leaves verdict freshness unknown'
}

test_away_yolo_is_fleet_work() {
  local home out
  home=$(new_home away-yolo)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register away delivery'
  printf 'yolo=on\n' >> "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter away posture'
  mutate_record "$home" delivery '.records[0].observation.can_merge=true'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not collect contribution input for away posture'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) \
    || fail 'could not project away delivery'
  printf '%s' "$out" | jq -e '.checked == 1 and .counts.captain == 0 and .counts.fleet == 1' >/dev/null \
    || fail 'away yolo delivery requiring a merge remained captain work'
  pass 'away yolo delivery is fleet work without granting merge authority'
}

test_away_yolo_cross_home_is_fleet_work() {
  local home child
  home=$(new_home away-yolo-parent)
  child=$(new_home away-yolo-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  forge_home "$child"
  with_home "$child" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register child away delivery'
  printf 'yolo=on\n' >> "$child/state/delivery.meta"
  with_home "$child" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter child away posture'
  mutate_record "$child" delivery '.records[0].observation.can_merge=true'
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child contribution summary'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 1' >/dev/null \
    || fail 'cross-home away yolo delivery requiring a merge remained captain work'
  pass 'cross-home away yolo delivery is fleet work'
}

test_retired_and_unsupported_coverage() {
  local home
  home=$(new_home retained)
  record "$home" retained 14 open mergeable
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true and .contributions.counts.maintainer == 1' >/dev/null \
    || fail 'endpoint retirement lost published ownership or proved nothing'
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 2 and .contributions.checked == 1
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'unsupported forge silently disappeared from coverage'
  pass 'retired ownership persists and unsupported forge remains visibly unmeasured'
}

test_unsupported_forge_is_not_fleet_work() {
  local home
  home=$(new_home unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.fleet == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unsupported forge was classified as fleet work instead of unmeasured coverage'
  pass 'unsupported forge coverage is disclosed without inventing fleet work'
}

test_held_unsupported_forge_is_not_captain_work() {
  local home
  home=$(new_home held-unsupported-forge)
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship) (hold: choose scope) (hold-kind: captain)\n' >> "$home/data/backlog.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and (.contributions.captain | length) == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'a held unsupported forge was classified as captain or fleet work'
  pass 'held unsupported forge coverage remains unmeasured'
}

test_shared_contribution_signal_wakes_once() {
  local home token pending wakes
  home=$(new_home shared-contribution-signal)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register shared contribution owner'
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 1 ] || fail "one shared contribution signal created $wakes durable wakes"
  pending=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending) || fail 'shared contribution pending view failed'
  printf '%s' "$pending" | jq -e 'length == 2 and ([.[].task] | sort) == ["delivery","duplicate"]' >/dev/null \
    || fail 'shared contribution owners did not retain their separate acknowledgements'
  token=$(printf '%s' "$pending" | jq -er '.[0].token') || fail 'shared contribution signal had no acknowledgement token'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the first shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" ack duplicate https://github.com/o/r/pull/8 "$token" >/dev/null \
    || fail 'could not acknowledge the second shared contribution owner'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'shared contribution acknowledgements did not remain independent'
  pass 'shared contribution signal wakes once while retaining both acknowledgements'
}

test_watcher_keeps_diagnostics_separate_from_contribution_wakes() {
  local home out rc wakes diagnostic
  home=$(new_home watcher-diagnostics)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for diagnostic watcher wake'
  registered_checks "$home" >/dev/null
  mkdir -p "$home/data/unreadable"
  printf 'incomplete JSON\n' > "$home/data/unreadable/contributions.json"
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher-diagnostics.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$out" 2> "$home/watcher-diagnostics.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface contribution diagnostics: $(cat "$home/watcher-diagnostics.err")"
  diagnostic=$(awk -F '\t' -v key="$home/state/contributions.check.sh" '$3 == "check" && $4 == key { print $5 }' "$home/state/.wake-queue")
  [ "$diagnostic" = "check: $home/state/contributions.check.sh: contributions: 1 unreadable durable record(s)" ] \
    || fail "watcher wrapped a durable contribution wake into diagnostics: $diagnostic"
  wakes=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$wakes" = 2 ] || fail "signal plus observer failure created $wakes durable wakes"
  pass 'watcher keeps observer diagnostics separate from contribution wakes'
}

test_expired_child_unsupported_forge_stays_unmeasured() {
  local home child
  home=$(new_home expired-unsupported-parent)
  child=$(new_home expired-unsupported-child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$child/data/backlog.md"
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'could not collect child unsupported-forge coverage'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.unmeasured == 1 and .contributions.counts.captain == 0
    and .contributions.counts.fleet == 0 and .contributions.complete == false
    and .contributions.proven_clear == false' >/dev/null \
    || fail 'expired child unsupported-forge coverage became fleet work'
  pass 'expired child unsupported-forge coverage remains unmeasured'
}

test_watcher_surfaces_new_contribution_once() {
  local home out rc rows
  home=$(new_home watcher-contribution)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register delivery for watcher wake'
  registered_checks "$home" >/dev/null
  jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  out="$home/watcher.out"
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "watcher did not surface the new contribution signal: $(cat "$home/watcher.err")"
  grep -E '^check: contributions delivery [0-9a-f]{64}$' "$out" >/dev/null \
    || fail "watcher did not surface the durable contribution wake: $(cat "$out")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "one contribution signal created $rows durable check wakes"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$home/watcher-repeat.out" 2> "$home/watcher-repeat.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "an undrained contribution signal did not ring again: $(cat "$home/watcher-repeat.err")"
  rows=$(awk -F '\t' 'NF >= 5 && $3 == "check" { count++ } END { print count + 0 }' "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "repeat contribution observation created $rows durable check wakes"
  : > "$home/state/.wake-queue"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$home/watcher-drained.out" 2> "$home/watcher-drained.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "a drained contribution signal re-rang the watcher: $(cat "$home/watcher-drained.out")"
  pass 'watcher surfaces one durable contribution signal, rings again while it is undrained, and stops once drained'
}

test_home_summary_coverage() {
  local home child
  home=$(new_home parent)
  child=$(new_home child)
  mkdir -p "$child/bin"
  printf '# Fixture\n' > "$child/AGENTS.md"
  printf 'child\n' > "$child/.fm-secondmate-home"
  record "$child" child-work 15 open mergeable
  FM_SNAPSHOT_NOW="$NOW" with_home "$child" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$child/state/home-summary.json" \
    || fail 'child summary failed'
  printf -- '- child - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-16)\n' "$child" > "$home/data/secondmates.md"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 1
    and .contributions.proven_clear == true' >/dev/null || fail 'measured child coverage did not reach parent'
  jq '.contributions.valid_until=0' "$child/state/home-summary.json" > "$child/update.json"
  mv "$child/update.json" "$child/state/home-summary.json"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.proven_clear == false' >/dev/null || fail 'expired child evidence proved parent silence'
  pass 'parent consumes measured child coverage and refuses expired child silence'
}

test_unreadable_pending_is_not_empty() {
  local home
  home=$(new_home unreadable-pending)
  record "$home" invalid 16 open mergeable
  printf 'incomplete JSON\n' > "$home/data/invalid/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > "$home/pending.json" 2> "$home/pending.err"; then
    fail 'an unreadable signal record was presented as an empty inbox'
  fi
  pass 'unreadable pending signals refuse an empty-inbox claim'
}

# Each record's durable task identity is the directory the snapshot loop finds
# it in, exactly as `basename "$(dirname "$file")"` named it, however the data
# root is spelled and whatever bytes the directory name carries.
test_record_task_identity_matches_dirname_basename() {
  local home data name file want n=0 names=() tasks=() expected actual
  home=$(new_home task-identity)
  names=(plain dot.ted 'two words' -dash $'caf\xc3\xa9' $'nl\n' '*')
  for data in "$home/data" "$home/data/" "$home/data//"; do
    for name in "${names[@]}"; do
      n=$((n + 1))
      mkdir -p "$home/data/$name"
      file="$data/$name/contributions.json"
      want=$(basename "$(dirname "$file")")
      jq -n --arg task "$want" --arg url "https://github.com/o/r/pull/$n" --arg token "t$n" \
        '{schema:"fm-contributions.v1",task:$task,records:[{url:$url,kind:"pr",checked_at:null,error:null,
          pending:[{token:$token}],seen:[],verdict:null,observation:null}]}' > "$file"
      tasks+=("$want")
    done
    expected=$(printf '%s\0' "${tasks[@]}" | jq -Rs 'split("\u0000")[:-1] | sort')
    actual=$(with_home "$home" env FM_DATA_OVERRIDE="$data" "$ROOT/bin/fm-contributions.sh" pending | jq '[.[].task] | sort') \
      || fail "records under data root '$data' were refused"
    [ "$actual" = "$expected" ] || fail "data root '$data' named tasks $actual, expected $expected"
    rm -rf "${home:?}/data/"*/
    tasks=()
  done
  mkdir -p "$home/data/named"
  jq -n '{schema:"fm-contributions.v1",task:"other",records:[]}' > "$home/data/named/contributions.json"
  if with_home "$home" "$ROOT/bin/fm-contributions.sh" pending > /dev/null 2>&1; then
    fail 'a record naming another task was accepted'
  fi
  pass 'record task identity is the directory dirname/basename named'
}

# snapshot and pending are read-only: reading saved records never creates the
# state directory or anything else, even in a home that has none.
test_read_only_views_create_no_state() {
  local home before after
  home=$(new_home read-only-views)
  record "$home" delivery 8 open mergeable
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$TMP_ROOT/read-only-input.json" \
    || fail 'could not collect contribution input'
  rm -rf "${home:?}/state"
  before=$(find "$home" | sort)
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$TMP_ROOT/read-only-input.json" --all \
    | jq -e '.checked == 1' >/dev/null || fail 'snapshot did not read the saved record without a state directory'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -e 'length == 0' >/dev/null \
    || fail 'pending did not read the saved record without a state directory'
  after=$(find "$home" | sort)
  [ ! -e "$home/state" ] || fail 'a read-only contribution view created the state directory'
  [ "$after" = "$before" ] || fail "a read-only contribution view created files: $(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  pass 'snapshot and pending create nothing in a home without state'
}

wrap_forge() { # home: log gh calls and apply per-call faults from $FORGE/fault
  local home=$1
  mv "$home/fakebin/gh" "$home/fakebin/gh-fixture"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
# The HTTP-faithful gh receives `api -i [-H If-None-Match: ...] <endpoint>`; the faults and the call log
# below speak the plain `api <endpoint>` form.
plain=$(printf '%s' "$*" | sed -E 's/^api -i /api /; s/ -H If-None-Match: [^ ]+//')
printf '%s\n' "$plain" >> "$FORGE/calls"
fault=$(cat "$FORGE/fault" 2>/dev/null || true)
case "$fault" in latency) sleep "${FORGE_LATENCY:-2}" ;; esac
# Concurrent forge callers each advance one shared clock. Truncating it in
# place races with the other callers and the fake date: an interleaved write
# can publish a half-written value (or the 6 an emptied read computes), and a
# caller could see torn arithmetic. Publish every new value by rename so each
# reader always sees one complete old-or-new clock.
clock_bump() {
  local tmp
  tmp=$(mktemp "$FORGE/clock.XXXXXX")
  printf '%s\n' "$(( $(cat "$FORGE/clock") + $1 ))" > "$tmp"
  mv -f "$tmp" "$FORGE/clock"
}
case "$fault:$plain" in
  # Advance once before the parallel read wave; its readers share this clock.
  quota-wave:'api repos/o/r/pulls/8'|quota-deadline:'api repos/o/r/pulls/8') clock_bump 6 ;;
  quota-wave:'api '*|quota-deadline:'api '*|quota-issue:'api '*comments\?*|quota-issue:'api '*events\?*)
    peers=6
    [ "$fault" != quota-issue ] || peers=2
    : > "$FORGE/ready.$(printf '%s' "$plain" | shasum | cut -c1-16)"
    for ((n=0; n<200; n++)); do
      [ "$(find "$FORGE" -name 'ready.*' | wc -l | tr -d ' ')" -lt "$peers" ] || break
      sleep 0.01
    done
    [ "$n" -lt 200 ] || exit 1
    export GH_SHIM_REMAINING=500
    if [ "$fault:$plain" = 'quota-deadline:api repos/o/r' ]; then clock_bump 100; fi
    ;;
  reserve:'api repos/o/r/issues/9') clock_bump 6 ;;
  quota-issue:'api repos/o/r/issues/9') clock_bump 6 ;;
  exhaust:'api repos/o/r/issues/8/comments?'*) clock_bump 100 ;;
  fail-late:'api repos/o/r/pulls/8/reviews?'*) clock_bump 100; printf 'HTTP 502\n' >&2; exit 1 ;;
  fail:'api repos/o/r/pulls/8/reviews?'*) printf 'HTTP 502\n' >&2; exit 1 ;;
  down:*) printf 'HTTP 502\n' >&2; exit 1 ;;
  not-found:'api repos/o/r/'*) printf 'HTTP 404\n' >&2; exit 1 ;;
  silent:*) printf '%s\n' "$$" > "$FORGE/hung-pid"; sleep 90 ;;
  silent-9:'api repos/o/r/pulls/9') printf '%s\n' "$$" > "$FORGE/hung-pid"; sleep 90 ;;
  # The second core read keeps burning CPU, so only its owner can stop it.
  spin-second:'api repos/o/r/pulls/8'|spin-second:'api repos/o/r/pulls/9')
    if [ -e "$FORGE/first-core" ]; then printf '%s\n' "$$" > "$FORGE/hung-pid"; while :; do :; done; fi
    : > "$FORGE/first-core" ;;
  progress:*)
    # The REST helper buffers gh output. Exercise real descendant CPU progress
    # as well, so this is observable work rather than an opaque sleeping read.
    for ((step=0; step<12; step++)); do
      python3 -c 'import time; end=time.process_time()+0.2
while time.process_time() < end: pass'
      printf 'working\n' >&2
      sleep "$FORGE_PROGRESS_DELAY"
    done ;;
  head:'pr view '*) printf '{"headRefOid":"%s","reviewDecision":"APPROVED"}\n' "$(printf 'b%.0s' $(seq 40))"; exit 0 ;;
esac
exec "$(dirname "$0")/gh-fixture" "$@"
SH
  # A controllable clock proves wall-time changes do not refuse healthy reads.
  cat > "$home/fakebin/date" <<'SH'
#!/bin/sh
if [ "$*" = +%s ] && [ -f "$FORGE/clock" ]; then cat "$FORGE/clock"; else exec /bin/date "$@"; fi
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/date"
}

test_clock_jump_does_not_refuse_a_read() {
  local home out
  home=$(new_home progress-exhaust)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'exhaust\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed after a clock leap'
  [ -z "$out" ] || fail "a clock leap printed a failure: $out"
  grep -F 'api repos/o/r/pulls/8' "$home/forge/calls" >/dev/null \
    || fail 'poll never started the observation'
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'wall-clock jump refused a healthy observation'
  [ ! -s "$home/state/.wake-queue" ] || fail 'routine progress handling enqueued a wake'
  pass 'a wall-clock jump does not refuse a healthy observation'
}

test_genuine_failure_after_clock_jump_is_unavailable() {
  local home out
  home=$(new_home genuine-failure)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
  /bin/date +%s > "$home/forge/clock"
  printf 'fail-late\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed on a genuine forge failure'
  [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
    || fail "a genuine forge failure after a clock jump was swallowed: $out"
  jq -e --arg now "$NOW" '.records[0].checked_at == $now
    and .records[0].error == "forge observation unavailable or changed during read"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'a genuine forge failure left no error evidence'
  pass 'a genuine forge failure still records the error and wakes after a clock jump'
}

test_shared_url_observed_once() {
  local mode home out calls expected
  for mode in ok fail head; do
    home=$(new_home "shared-once-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
    printf '%s\n' "$mode" > "$home/forge/fault"
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "shared-owner poll failed ($mode)"
    calls=$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")
    [ "$calls" = 1 ] || fail "a URL owned by two tasks was observed $calls times in one poll ($mode)"
    if [ "$mode" = ok ]; then
      expected=null
      [ -z "$out" ] || fail "a healthy shared observation printed: $out"
    else
      expected='"forge observation unavailable or changed during read"'
      [ "$out" = 'contributions: observation unavailable for https://github.com/o/r/pull/8' ] \
        || fail "a shared unavailable observation did not wake exactly once ($mode): $out"
    fi
    for task in delivery duplicate; do
      jq -e --arg now "$NOW" --argjson error "$expected" '.records[0].checked_at == $now and .records[0].error == $error' \
        "$home/data/$task/contributions.json" >/dev/null || fail "owner $task did not receive the shared result ($mode)"
    done
  done
  pass 'a URL owned by two tasks is observed once and every owner receives the result'
}

test_terminal_contribution_settles() {
  local mode home out later=2026-09-17T08:00:00Z
  for mode in merged closed; do
    home=$(new_home "terminal-$mode")
    forge_home "$home"
    wrap_forge "$home"
    printf '%s\n' "$mode" > "$home/forge/state"
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail "terminal observation poll failed ($mode)"
    [ -z "$out" ] || fail "a $mode observation printed: $out"
    jq -e --arg now "$NOW" --arg mode "$mode" '.records[0] | .checked_at == $now and .error == null and .observation.state == $mode' \
      "$home/data/delivery/contributions.json" >/dev/null || fail "a $mode observation was not recorded once without error"
    cp "$home/data/delivery/contributions.json" "$home/prior.json"
    : > "$home/forge/calls"
    printf 'down\n' > "$home/forge/fault"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "poll after a $mode observation failed"
    [ -z "$out" ] || fail "a $mode contribution woke again when a later read would fail: $out"
    [ ! -s "$home/forge/calls" ] || fail "a $mode contribution was re-read: $(cat "$home/forge/calls")"
    cmp -s "$home/prior.json" "$home/data/delivery/contributions.json" \
      || fail "a $mode contribution record changed after it settled: $(cat "$home/data/delivery/contributions.json")"
    [ ! -s "$home/state/.wake-queue" ] || fail "a $mode contribution enqueued a wake"
    NOW=$later bearings "$home" | jq -e '.contributions.checked == 1 and .contributions.counts.nobody == 1
      and .contributions.complete == true' >/dev/null \
      || fail "a settled $mode contribution expired into fleet work"
  done
  home=$(new_home terminal-legacy-error)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation.state="merged" | .records[0].error="forge observation unavailable or changed during read"'
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'poll of an error-stamped merged record failed'
  [ -z "$out" ] || fail "an error-stamped merged record woke again: $out"
  [ ! -s "$home/forge/calls" ] || fail 'an error-stamped merged record was re-read'
  jq -e --arg at "$NOW" '.records[0] | .error == null and .checked_at == $at and .observation.state == "merged"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an error-stamped merged record did not settle'
  pass 'a merged or closed contribution settles once, is not re-read, and never wakes again'
}

test_late_owner_inherits_terminal_observation() {
  local home out later=2026-09-17T08:00:00Z
  home=$(new_home terminal-late-owner)
  forge_home "$home"
  wrap_forge "$home"
  printf 'merged\n' > "$home/forge/state"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial terminal observation poll failed'
  cp "$home/data/delivery/contributions.json" "$home/final.json"
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  : > "$home/forge/calls"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'late-owner terminal poll failed'
  [ -z "$out" ] || fail "a late owner reactivated a terminal contribution: $out"
  [ ! -s "$home/forge/calls" ] || fail 'a late owner triggered a terminal forge read'
  jq -e --slurpfile final "$home/final.json" '
    .records[0] as $late | $final[0].records[0] as $terminal
    | $late.error == null and $late.pending == [] and $late.notified == []
    and $late.checked_at == $terminal.checked_at and $late.observation == $terminal.observation' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail 'a late owner did not inherit the settled terminal observation'
  [ ! -s "$home/state/.wake-queue" ] || fail 'a late owner terminal record enqueued a wake'
  pass 'a late owner inherits a terminal observation without a forge read or wake'
}

test_interrupted_multi_owner_poll_settles_every_owner() {
  local home later=2026-09-17T08:00:00Z
  home=$(new_home multi-owner-open)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" duplicate 8 open mergeable
  mutate_record "$home" duplicate '.records[0].pending=[{token:"evt-1"}] | .records[0].notified=["evt-0"]
    | .records[0].checked_at="2026-09-15T08:00:00Z"'
  mutate_record "$home" delivery ".records[0].observation.state=\"merged\" | .records[0].observation.head=\"$HEAD_B\""
  printf 'down\n' > "$home/forge/fault"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'interrupted multi-owner poll failed'
  [ ! -s "$home/forge/calls" ] || fail 'a known terminal URL triggered a forge read'
  jq -e --slurpfile terminal "$home/data/delivery/contributions.json" '.records[0] | .observation.state == "merged"
    and .observation == $terminal[0].records[0].observation
    and .error == null and .checked_at == $terminal[0].records[0].checked_at
    and .pending == [{token:"evt-1"}] and .notified == ["evt-0"]' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail "an owner whose saved row stayed open did not converge on the known terminal observation: $(cat "$home/data/duplicate/contributions.json")"

  home=$(new_home multi-owner-errored)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" duplicate 8 open mergeable
  mutate_record "$home" duplicate '.records[0].error="forge observation unavailable or changed during read"'
  mutate_record "$home" delivery ".records[0].observation.state=\"merged\" | .records[0].observation.head=\"$HEAD_B\""
  printf 'down\n' > "$home/forge/fault"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'interrupted multi-owner poll (errored owner) failed'
  [ ! -s "$home/forge/calls" ] || fail 'a known terminal URL triggered a forge read (errored owner)'
  jq -e --slurpfile terminal "$home/data/delivery/contributions.json" '.records[0] | .observation.state == "merged"
    and .observation == $terminal[0].records[0].observation and .error == null' \
    "$home/data/duplicate/contributions.json" >/dev/null \
    || fail "an errored owner did not converge on the known terminal observation: $(cat "$home/data/duplicate/contributions.json")"
  pass 'a retry converges every owner whose saved row is not terminal, keeping its own acknowledgement state'
}

test_done_task_open_pr_still_observed() {
  local home later=2026-09-17T08:00:00Z
  home=$(new_home done-open)
  forge_home "$home"
  wrap_forge "$home"
  rm "$home/data/delivery/contributions.json"
  printf '# Backlog\n\n## Queued\n\n## Done\n- [x] delivery - Shipped https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    > "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'poll of a done task failed'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  with_home "$home" env FM_CONTRIBUTIONS_NOW="$later" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'second poll of a done task failed'
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 2 ] \
    || fail 'an open PR linked from a done task was not observed on every poll'
  jq -e --arg head "$HEAD_B" --arg at "$later" '.records[0] | .checked_at == $at and .error == null
    and .observation.state == "open" and .observation.head == $head' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'an open PR on a done task did not track its current head'
  pass 'an open PR linked from a done task keeps being observed'
}

test_all_urls_are_attempted_without_reservation() {
  local home out task
  home=$(new_home no-reservation)
  forge_home "$home"
  wrap_forge "$home"
  printf -- '- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  /bin/date +%s > "$home/forge/clock"
  printf 'reserve\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed'
  [ -z "$out" ] || fail "healthy reads printed unavailable: $out"
  for task in filed delivery; do
    jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
      "$home/data/$task/contributions.json" >/dev/null || fail "remaining wall time deferred $task"
  done
  pass 'all live URLs are attempted without a derived observation reserve'
}

test_three_second_pr_reads_complete_fresh_in_one_cycle() {
  local home out
  home=$(new_home three-second-pr)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z" | .records[0].error="forge observation unavailable or changed during read"'
  printf 'latency\n' > "$home/forge/fault"
  out=$(with_home "$home" env FORGE_LATENCY=3 "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'a 3-second-read PR observation failed'
  [ -z "$out" ] || fail "a fresh 3-second-read PR observation woke: $out"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a 3-second-read PR observation was not fresh within one cycle'
  pass 'eight 3-second PR reads complete as one coherent observation'
}

test_progressing_reads_survive_fivefold_slowdown() {
  local home out factor
  for factor in 1 5; do
    home=$(new_home "slow-progress-$factor")
    forge_home "$home"
    wrap_forge "$home"
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    printf 'progress\n' > "$home/forge/fault"
    out=$(with_home "$home" env FORGE_PROGRESS_DELAY="0.$factor" \
      "$ROOT/bin/fm-contributions.sh" poll) || fail 'slow progressing read failed'
    [ -z "$out" ] || fail "slow progressing read printed unavailable: $out"
    jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
      "$home/data/delivery/contributions.json" >/dev/null || fail "${factor}x read was not observed"
  done
  pass 'forge reads complete at 1x and 5x with real descendant CPU progress'
}

test_first_unknown_read_defers_the_rest_of_the_pass() {
  local home out task pass child
  home=$(new_home unknown-defers)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" second 9 open mergeable
  record "$home" third 10 open mergeable
  for task in delivery second third; do
    cp "$home/data/$task/contributions.json" "$home/prior-$task.json"
  done
  printf 'silent\n' > "$home/forge/fault"
  for pass in 1 2; do
    out=$(with_home "$home" env FM_DURATION_FILE="$home/empty-durations.jsonl" "$ROOT/bin/fm-contributions.sh" poll) \
      || fail "pass $pass failed"
    [ -z "$out" ] || fail "an unknown pass printed unavailable: $out"
    [ "$(wc -l < "$home/forge/calls" | tr -d '[:space:]')" = "$pass" ] \
      || fail "pass $pass did not make exactly one dial: $(cat "$home/forge/calls")"
    IFS= read -r child < "$home/forge/hung-pid"
    ! kill -0 "$child" 2>/dev/null || fail 'the silent forge read survived its read stop'
    for task in delivery second third; do
      cmp -s "$home/prior-$task.json" "$home/data/$task/contributions.json" \
        || fail "pass $pass changed the $task row it never observed"
    done
  done
  [ ! -s "$home/state/.wake-queue" ] || fail 'an unknown pass enqueued a failure wake'
  pass 'after the first unknown read a pass dials nothing more, keeps every row, and the next pass dials again'
}

test_always_silent_url_does_not_starve_the_others() {
  local home out task pass now child
  home=$(new_home silent-one)
  forge_home "$home"
  wrap_forge "$home"
  record "$home" second 9 open mergeable
  record "$home" third 10 open mergeable
  printf 'silent-9\n' > "$home/forge/fault"
  for pass in 1 2 3; do
    now=$(jq -nr --arg now "$NOW" --argjson shift "$(( (pass - 1) * 300 ))" '$now | fromdateiso8601 + $shift | todateiso8601')
    for task in delivery third; do
      mutate_record "$home" "$task" '.records[0].checked_at="2026-09-15T08:00:00Z"'
    done
    cp "$home/data/second/contributions.json" "$home/prior-second.json"
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$now" FM_DURATION_FILE="$home/empty-durations.jsonl" \
      "$ROOT/bin/fm-contributions.sh" poll) || fail "pass $pass failed"
    [ -z "$out" ] || fail "pass $pass printed unavailable: $out"
    cmp -s "$home/prior-second.json" "$home/data/second/contributions.json" \
      || fail "pass $pass rewrote the always-silent URL's row"
    [ "$pass" -gt 1 ] || continue
    for task in delivery third; do
      jq -e --arg now "$now" '.records[0] | .checked_at == $now and .error == null' \
        "$home/data/$task/contributions.json" >/dev/null || fail "pass $pass starved $task behind the always-silent URL"
    done
    IFS= read -r child < "$home/forge/hung-pid"
    ! kill -0 "$child" 2>/dev/null || fail 'the silent forge read survived its read stop'
  done
  [ ! -s "$home/state/.wake-queue" ] || fail 'an unknown read enqueued a failure wake'
  pass 'one always-silent URL stays unknown while every other URL is refreshed on every later pass'
}

test_stop_while_writing_the_order_leaves_no_temporary() {
  local home real_cut pid i
  home=$(new_home order-stop)
  forge_home "$home"
  real_cut=$(command -v cut)
  # Pause the poll inside its order write, after the temporary exists.
  cat > "$home/fakebin/cut" <<SH
#!/usr/bin/env bash
case "\$*" in "-f1 "*live.tsv) : > '$home/in-order-write'; sleep 3 ;; esac
exec '$real_cut' "\$@"
SH
  chmod +x "$home/fakebin/cut"
  # shellcheck disable=SC2016 # The child shell expands its own PID and arguments.
  with_home "$home" bash -c 'printf "%s\n" "$$" > "$1"; exec "$2" poll' _ "$home/poll.pid" "$ROOT/bin/fm-contributions.sh" \
    > "$home/poll.out" 2> "$home/poll.err" &
  for ((i = 0; i < 600; i++)); do
    [ ! -e "$home/in-order-write" ] || break
    sleep 0.1
  done
  [ -e "$home/in-order-write" ] || fail "the poll never reached its order write: $(cat "$home/poll.err")"
  IFS= read -r pid < "$home/poll.pid"
  kill -TERM "$pid" 2>/dev/null || true
  wait || true
  ! compgen -G "$home/state/.contributions-deferred.*" >/dev/null \
    || fail "a stopped poll left its order temporary: $(ls "$home/state")"
  pass 'a poll stopped while writing its order leaves no temporary file in state'
}

test_retired_pr_poll_starts_a_new_stop_episode() {
  local home
  home=$(new_home pr-poll-episode)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not arm the PR poll'
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$home/silent.sh"
  # shellcheck disable=SC2016 # The child watcher shell expands its own arguments.
  with_home "$home" bash -c '
      . "$1"
      WATCHER_PID=$$
      trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
      watcher_beat force
      CHECK_TIMEOUT=1
      run_check_capture delivery "$2" || exit 21
      [ -n "$FM_CHECK_STOP_NOTICE" ] || exit 22
      fm_pr_poll_snapshot_capture "$STATE" delivery "$SCRIPT_DIR/fm-pr-poll.sh" || exit 29
      fm_pr_poll_retirement_publish "$STATE" delivery "$SCRIPT_DIR/fm-pr-poll.sh" merged || exit 27
      fm_pr_poll_retirement_recover_one "$STATE" delivery "$SCRIPT_DIR/fm-pr-poll.sh" || exit 28
      [ ! -e "$STATE/delivery.check.sh" ] || exit 23
      "$3" delivery https://github.com/o/r/pull/8 >/dev/null || exit 24
      run_check_capture delivery "$2" || exit 25
      [ -n "$FM_CHECK_STOP_NOTICE" ] || exit 26
    ' _ "$ROOT/bin/fm-watch.sh" "$home/silent.sh" "$ROOT/bin/fm-pr-check.sh" > "$home/watch.out" 2> "$home/watch.err" \
    || fail "a PR poll retired and re-armed before any sweep did not start a new stop episode: $(cat "$home/watch.err")"
  pass 'a PR poll retired and re-armed before any sweep starts a new stop episode'
}

# Every disarm or retirement path must end a check's stop episode, so the check's
# first stop after a re-arm still reaches firstmate. A new disarm or retirement
# path must be added to this table.
test_every_disarm_path_starts_a_new_stop_episode() {
  local row home failed=
  write_disarm_runner() {  # <path>
    cat > "$1" <<'SH'
#!/usr/bin/env bash
# <watcher> <repo-root> <row> <silent-check> <home> <base-path>
. "$1"
ROOT=$2 ROW=$3 SILENT=$4 HOME_DIR=$5 BASE_PATH=$6
WATCHER_PID=$$
trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
watcher_beat force
CHECK_TIMEOUT=1
x_mode() {  # on|off
  grep -v '^FMX_PAIRING_TOKEN=' "$HOME_DIR/.env" > "$HOME_DIR/.env.next" || true
  [ "$1" = off ] || printf 'FMX_PAIRING_TOKEN=tok-episode\n' >> "$HOME_DIR/.env.next"
  mv -f -- "$HOME_DIR/.env.next" "$HOME_DIR/.env"
  env -u FM_ROOT_OVERRIDE PATH="$BASE_PATH" "$ROOT/bin/fm-bootstrap.sh"
}
row_arm() {
  case "$ROW" in
    copy-sweep) "$ROOT/bin/fm-copy-sweep.sh" arm ;;
    startup-growth) "$ROOT/bin/fm-startup-growth-check.sh" arm ;;
    mail) "$ROOT/bin/fm-mail-check.sh" arm ;;
    tool-updates) "$ROOT/bin/fm-tool-update-check.sh" arm ;;
    contributions) "$ROOT/bin/fm-contributions.sh" arm ;;
    custom)
      printf '#!/usr/bin/env bash\nexit 0\n' > "$STATE/custom.check.sh" && chmod 0700 "$STATE/custom.check.sh" \
        && "$ROOT/bin/fm-check-register.sh" custom ;;
    delivery) "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 ;;
    x-watch) x_mode on && [ -e "$STATE/x-watch.check.sh" ] ;;
    task-x1)
      printf '#!/usr/bin/env bash\nexit 0\n' > "$STATE/task-x1.check.sh" && chmod 0700 "$STATE/task-x1.check.sh" \
        && "$ROOT/bin/fm-check-register.sh" task-x1 ;;
  esac > /dev/null 2>&1
}
row_disarm() {
  case "$ROW" in
    copy-sweep) "$ROOT/bin/fm-copy-sweep.sh" disarm ;;
    startup-growth) "$ROOT/bin/fm-startup-growth-check.sh" disarm ;;
    mail) "$ROOT/bin/fm-mail-check.sh" disarm ;;
    tool-updates) "$ROOT/bin/fm-tool-update-check.sh" disarm ;;
    contributions|custom) "$ROOT/bin/fm-check-unregister.sh" "$ROW" ;;
    delivery)
      fm_pr_poll_snapshot_capture "$STATE" delivery "$SCRIPT_DIR/fm-pr-poll.sh" \
        && fm_pr_poll_retirement_publish "$STATE" delivery "$SCRIPT_DIR/fm-pr-poll.sh" merged \
        && fm_pr_poll_retirement_recover_one "$STATE" delivery "$SCRIPT_DIR/fm-pr-poll.sh" ;;
    x-watch) x_mode off && [ ! -e "$STATE/x-watch.check.sh" ] ;;
    task-x1) "$ROOT/bin/fm-teardown.sh" task-x1 ;;
  esac > /dev/null 2>&1
}
row_arm || exit 20
run_check_capture "$ROW" "$SILENT" || exit 21
[ -n "$FM_CHECK_STOP_NOTICE" ] || exit 22
row_disarm || exit 23
row_arm || exit 24
run_check_capture "$ROW" "$SILENT" || exit 25
[ -n "$FM_CHECK_STOP_NOTICE" ] || exit 26
SH
  }
  for row in copy-sweep startup-growth mail tool-updates contributions custom delivery x-watch teardown; do
    if [ "$row" = teardown ]; then
      # Teardown retires a whole task, so this row uses the teardown suite's task fixture.
      (
        base_path=$PATH
        # shellcheck source=/dev/null
        . "$ROOT/tests/fm-teardown-helpers.sh"
        case_dir=$(make_case disarm-path-teardown)
        write_meta "$case_dir" no-mistakes ship
        printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
        seed_backlog_in_flight "$case_dir"
        printf '#!/usr/bin/env bash\nsleep 30\n' > "$case_dir/silent.sh"
        write_disarm_runner "$case_dir/disarm-path.sh"
        FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
          FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" NM_HOME="$case_dir/nm" \
          PATH="$case_dir/fakebin:$base_path" \
          bash "$case_dir/disarm-path.sh" "$ROOT/bin/fm-watch.sh" "$ROOT" task-x1 "$case_dir/silent.sh" "$case_dir" "$base_path" \
          > "$case_dir/disarm-path.out" 2> "$case_dir/disarm-path.err"
      ) || failed="$failed $row(rc=$?)"
      continue
    fi
    home=$(new_home "disarm-path-$row")
    forge_home "$home"
    printf '%s\n' 'FM_MAIL_USER=test@example.invalid' 'FM_MAIL_PASS=test-pass' \
      'FM_IMAP_HOST=imap.test.invalid' 'FM_SMTP_HOST=smtp.test.invalid' > "$home/.env"
    printf '{"tools":[{"name":"herdr","command":"herdr"}]}\n' > "$home/config/watched-tools.json"
    printf '#!/usr/bin/env bash\nsleep 30\n' > "$home/silent.sh"
    write_disarm_runner "$home/disarm-path.sh"
    with_home "$home" bash "$home/disarm-path.sh" "$ROOT/bin/fm-watch.sh" "$ROOT" "$row" "$home/silent.sh" "$home" "$PATH" \
      > "$home/disarm-path.out" 2> "$home/disarm-path.err" || failed="$failed $row(rc=$?)"
  done
  [ -z "$failed" ] || fail "these disarm or retirement paths kept the old stop episode or failed:$failed"
  pass 'every disarm or retirement path starts a new stop episode after a re-arm before any sweep'
}

test_unsupported_url_first_does_not_abort_the_pass() {
  local home pass now
  home=$(new_home unsupported-first)
  forge_home "$home"
  printf -- '- [ ] unsupported - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  # Two neighbouring five-minute buckets put each URL first once.
  for pass in 1 2; do
    now=$(jq -nr --arg now "$NOW" --argjson shift "$(( (pass - 1) * 300 ))" '$now | fromdateiso8601 + $shift | todateiso8601')
    mutate_record "$home" delivery '.records[0].checked_at="2026-09-15T08:00:00Z"'
    with_home "$home" env FM_CONTRIBUTIONS_NOW="$now" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
      || fail "pass $pass aborted with an unsupported URL in the rotation"
    jq -e --arg now "$now" '.records[0] | .checked_at == $now and .error == null' \
      "$home/data/delivery/contributions.json" >/dev/null || fail "pass $pass skipped the GitHub URL beside an unsupported one"
  done
  pass 'an unsupported URL in either rotation position leaves the pass and its GitHub URL intact'
}

test_quota_reason_is_the_refusal_line() {
  local home f out
  home=$(new_home quota-reason)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  # A copy of bin whose REST helper writes another diagnostic line first, as the
  # shared progress runner can on the same stream.
  mkdir -p "$home/bin-copy"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$home/bin-copy/${f##*/}"; done
  rm "$home/bin-copy/fm-gh-rest.sh"
  # shellcheck disable=SC2016 # The wrapper expands its own arguments.
  printf '#!/usr/bin/env bash\nprintf "cpu_telemetry_unavailable: fixture diagnostic\\n" >&2\nexec %q "$@"\n' \
    "$ROOT/bin/fm-gh-rest.sh" > "$home/bin-copy/fm-gh-rest.sh"
  chmod +x "$home/bin-copy/fm-gh-rest.sh"
  out=$(GH_SHIM_REMAINING=500 with_home "$home" "$home/bin-copy/fm-contributions.sh" poll) || fail 'low-quota poll failed'
  assert_contains "$out" 'quota low (500 of 5000' 'the quota episode did not name the refusal'
  jq -e '.records[0].error | contains("quota low (") and (contains("cpu_telemetry") | not)' \
    "$home/data/delivery/contributions.json" >/dev/null \
    || fail "the stale reason was not the refusal line: $(jq -c '.records[0].error' "$home/data/delivery/contributions.json")"
  pass 'the quota reason is the refusal line, not another diagnostic on the same stream'
}

test_reads_record_their_samples_when_the_poll_ends() {
  local home
  home=$(new_home read-samples)
  forge_home "$home"
  with_home "$home" env FM_DURATION_FILE="$home/durations.jsonl" "$ROOT/bin/fm-contributions.sh" poll >/dev/null \
    || fail 'poll failed'
  jq -se '[.[] | select((.key // "") | startswith("contributions.read."))] | length > 0
    and all(.[]; .exit == 0)' "$home/durations.jsonl" >/dev/null \
    || fail "the poll recorded no read samples: $(cat "$home/durations.jsonl" 2>/dev/null)"
  pass 'a poll records the samples of its forge reads'
}

test_reads_are_independent_of_watcher_interval() {
  local home out
  home=$(new_home independent-read)
  forge_home "$home"
  wrap_forge "$home"
  printf 'latency\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CHECK_TIMEOUT=1 FORGE_LATENCY=2 "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll failed'
  [ -z "$out" ] || fail "poll printed unavailable: $out"
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'watcher interval cut an independent read'
  pass 'read supervision is not a sub-budget of the watcher interval'
}

test_watcher_stopped_check_rings_queued_row_next_pass() {
  local home child key result
  home=$(new_home watcher-stop-ring)
  forge_home "$home"
  record "$home" second 9 open mergeable
  with_home "$home" "$ROOT/bin/fm-contributions.sh" arm >/dev/null || fail 'arm failed'
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",
    updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  wrap_forge "$home"
  printf 'spin-second\n' > "$home/forge/fault"
  for result in stopped rings; do
    # FM_DURATION_ABSOLUTE_SECS is fm-duration.py's own seam for its absolute extreme.
    # shellcheck disable=SC2016 # The child watcher shell expands its own arguments.
    with_home "$home" env FM_DURATION_ABSOLUTE_SECS="$([ "$result" = stopped ] && echo 20 || echo 21600)" bash -c '
        . "$1"
        WATCHER_PID=$$
        trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
        watcher_beat force
        run_check_capture contributions "$STATE/contributions.check.sh" || exit 21
        printf "%s\n" "$FM_CHECK_RESULT" > "$STATE/../result-$2.txt"
        if [ "$2" = stopped ]; then
          [ "$FM_CHECK_STATUS" = 124 ] && [ -z "$FM_CHECK_RESULT" ] || exit 22
        else
          [ "$FM_CHECK_STATUS" = 0 ] || exit 23
        fi
      ' _ "$ROOT/bin/fm-watch.sh" "$result" > "$home/watch-$result.out" 2> "$home/watch-$result.err" \
      || fail "$result pass failed: $(cat "$home/watch-$result.err")"
    if [ "$result" = stopped ]; then
      IFS= read -r child < "$home/forge/hung-pid"
      ! kill -0 "$child" 2>/dev/null || fail 'the spinning forge read survived the stopped check'
      key=$(awk -F '\t' '$3 == "check" && $4 ~ /^contribution-/ { print substr($4, 14); exit }' "$home/state/.wake-queue")
      [ -n "$key" ] || fail 'the stopped pass queued no contribution row before it was stopped'
      : > "$home/forge/fault"
    fi
  done
  grep -E "^contribution-wake: check: contributions [a-z]+ $key\$" "$home/result-rings.txt" >/dev/null \
    || fail "the next pass did not ring the row a stopped pass queued: $(cat "$home/result-rings.txt")"
  pass 'a contribution row queued by a pass the watcher stopped still rings on the next pass'
}

test_unavailable_forge_records_error_and_wakes_once_per_episode() { # genuine outage, two consecutive cycles
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8'
  local error='"forge observation unavailable or changed during read"'
  home=$(new_home failure-episode)
  forge_home "$home"
  wrap_forge "$home"
  printf 'down\n' > "$home/forge/fault"
  poll_at() { with_home "$home" env FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll || fail "poll at $1 failed"; }
  out=$(poll_at 2026-09-16T09:00:00Z)
  [ "$out" = "$line" ] || fail "the first failure of an episode did not wake: $out"
  out=$(poll_at 2026-09-16T10:00:00Z)
  [ -z "$out" ] || fail "an unchanged read failure woke again on the next cycle: $out"
  jq -e --argjson error "$error" '.records[0] | .checked_at == "2026-09-16T10:00:00Z" and .error == $error' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'a repeated read failure stopped recording its error'
  [ "$(grep -cFx 'api repos/o/r/pulls/8' "$home/forge/calls")" = 2 ] || fail 'a failing open PR stopped being observed'
  : > "$home/forge/fault"
  out=$(poll_at 2026-09-16T11:00:00Z)
  [ -z "$out" ] || fail "a successful read printed: $out"
  jq -e '.records[0].error == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a successful read did not end the failure episode'
  printf 'down\n' > "$home/forge/fault"
  out=$(poll_at 2026-09-16T12:00:00Z)
  [ "$out" = "$line" ] || fail "a new failure after a successful read did not wake: $out"
  pass 'a genuinely unavailable forge records an error and wakes once per failure episode'
}

test_late_owner_keeps_failure_episode_suppressed() {
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8'
  local error='forge observation unavailable or changed during read' task
  home=$(new_home late-owner-failure-episode)
  forge_home "$home"
  wrap_forge "$home"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'initial failing poll failed'
  [ "$out" = "$line" ] || fail "the initial failure did not wake: $out"
  printf -- '- [ ] duplicate - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T10:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'late-owner failing poll failed'
  [ -z "$out" ] || fail "a late owner restarted an unchanged failure episode: $out"
  for task in delivery duplicate; do
    jq -e --arg error "$error" '.records[0].error == $error' "$home/data/$task/contributions.json" >/dev/null \
      || fail "owner $task did not retain the shared failure evidence"
  done
  : > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T11:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'successful shared poll failed'
  [ -z "$out" ] || fail "a successful shared poll printed: $out"
  for task in delivery duplicate; do
    jq -e '.records[0].error == null' "$home/data/$task/contributions.json" >/dev/null \
      || fail "owner $task did not end the shared failure episode"
  done
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T12:00:00Z "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'new shared failing poll failed'
  [ "$out" = "$line" ] || fail "a failure after shared recovery did not wake: $out"
  pass 'a late owner does not restart a shared forge failure episode'
}

test_retire_ends_observation_of_a_gone_contribution() {
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8' url=https://github.com/o/r/pull/8
  home=$(new_home retire-gone)
  forge_home "$home"
  wrap_forge "$home"
  printf 'not-found\n' > "$home/forge/fault"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll) || fail 'failing poll failed'
  [ "$out" = "$line" ] || fail "a gone repository did not raise the unavailable check: $out"
  bearings "$home" | jq -e '.contributions.known == 1 and .contributions.checked == 0
    and .contributions.complete == false and .contributions.proven_clear == false' >/dev/null \
    || fail 'an unreadable contribution did not hold coverage incomplete before retirement'
  with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z "$ROOT/bin/fm-contributions.sh" retire delivery "$url" captain 'repository deleted' \
    || fail 'retire of an owned unreadable contribution failed'
  jq -e '.records[0].retired == {actor:"captain",reason:"repository deleted",at:"2026-09-16T09:30:00Z"}' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'retire did not record its provenance'
  : > "$home/forge/calls"
  for at in 2026-09-16T10:00:00Z 2026-09-16T10:05:00Z; do
    out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW="$at" "$ROOT/bin/fm-contributions.sh" poll) || fail "poll after retire failed at $at"
    [ -z "$out" ] || fail "a retired contribution still raised a check: $out"
  done
  [ ! -s "$home/forge/calls" ] || fail "a retired contribution stayed in rotation: $(cat "$home/forge/calls")"
  bearings "$home" | jq -e '.contributions.known == 0 and .contributions.checked == 0
    and .contributions.complete == true and .contributions.proven_clear == true' >/dev/null \
    || fail 'a retired contribution still counted against coverage despite its backlog link'
  pass 'retire stops the unavailable check, leaves rotation and restores complete coverage'
}

test_late_owner_of_a_retired_final_contribution_is_not_retired() {
  local home out
  home=$(new_home retire-late-owner)
  forge_home "$home"
  wrap_forge "$home"
  mutate_record "$home" delivery '.records[0].observation.state="merged"
    | .records[0].retired={actor:"captain",reason:"repository deleted",at:"2026-09-16T09:30:00Z"}'
  record "$home" duplicate 8 merged mergeable
  mutate_record "$home" duplicate '.records[0].error="forge observation unavailable or changed during read"'
  printf -- '- [ ] late - Filed https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_NOW=2026-09-17T08:00:00Z "$ROOT/bin/fm-contributions.sh" poll) || fail 'late-owner poll failed'
  [ -z "$out" ] || fail "a late owner of a retired final contribution printed: $out"
  [ ! -s "$home/forge/calls" ] || fail 'a known final contribution triggered a forge read'
  jq -e '.records[0] | .retired == null and .observation.state == "merged" and .error == null' \
    "$home/data/late/contributions.json" >/dev/null || fail 'a late owner inherited another task'"'"'s retirement'
  jq -e '.records[0].retired.reason == "repository deleted"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'settling a late owner changed the retired record'
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || fail 'contribution input failed'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all | jq -e '.rows[0].tasks == ["duplicate","late"]' >/dev/null \
    || fail 'a late owner settled beside a retired final record left known'
  pass 'a late owner settled beside a retired final record stays unretired and known'
}

test_retire_is_idempotent_and_refuses_unknown_pairs() {
  local home url=https://github.com/o/r/pull/8 before err
  home=$(new_home retire-refusals)
  forge_home "$home"
  retire() { with_home "$home" "$ROOT/bin/fm-contributions.sh" retire "$@"; }
  retire delivery "$url" fleet 'repository deleted' >/dev/null 2>&1 && fail 'retire accepted the fleet as its actor'
  jq -e '.records[0].retired == null' "$home/data/delivery/contributions.json" >/dev/null || fail 'a fleet retire changed the record'
  retire delivery "$url" captain 'repository deleted' >/dev/null || fail 'first retire failed'
  before=$(cat "$home/data/delivery/contributions.json")
  retire delivery "$url" captain 'second reason' >/dev/null || fail 'repeating a retire was refused'
  [ "$(cat "$home/data/delivery/contributions.json")" = "$before" ] || fail 'repeating a retire rewrote its first provenance'
  printf -- '- [ ] linked - Linked only https://github.com/o/r/pull/30 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  err=$(retire linked https://github.com/o/r/pull/30 captain gone 2>&1) && fail 'retire created a record for an unobserved pair'
  case "$err" in *'not recorded for this durable task'*) ;; *) fail "unrecorded-pair refusal was unclear: $err" ;; esac
  [ ! -e "$home/data/linked/contributions.json" ] || fail 'a refused retire created a record'
  retire other "$url" captain gone >/dev/null 2>&1 && fail 'retire accepted a task that does not own the URL'
  record "$home" queued 31 open mergeable
  retire queued https://github.com/o/r/pull/31 owner gone >/dev/null 2>&1 && fail 'retire accepted an unknown actor'
  retire queued https://github.com/o/r/pull/31 captain '' >/dev/null 2>&1 && fail 'retire accepted an empty reason'
  retire queued https://github.com/o/r/pull/31 captain ' 	 ' >/dev/null 2>&1 && fail 'retire accepted a whitespace-only reason'
  retire queued https://github.com/o/r/pull/31 captain >/dev/null 2>&1 && fail 'retire accepted a missing reason'
  mutate_record "$home" queued '.records[0].pending=[{token:"comment:1:x",type:"comment"}]'
  retire queued https://github.com/o/r/pull/31 captain gone >/dev/null 2>&1 && fail 'retire dropped an unacknowledged signal'
  jq -e '.records[0].retired == null' "$home/data/queued/contributions.json" >/dev/null || fail 'a refused retire changed the record'
  pass 'retire is idempotent and refuses non-captain, unknown, malformed and signal-bearing pairs'
}

shim_count() { # home kind(counted|not-modified) : REST reads (api -i) the shim logged
  grep -c "^$2 api -i " "$1/forge/shim.log" 2>/dev/null || true
}

test_repeated_poll_reads_unchanged_prs_conditionally() {
  local home first
  home=$(new_home conditional-poll)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  : > "$home/forge/shim.log"
  registered_checks "$home" >/dev/null
  first=$(shim_count "$home" counted)
  [ "$first" -ge 7 ] || fail "the first sweep made only $first counted REST reads"
  : > "$home/forge/shim.log"
  registered_checks "$home" >/dev/null
  [ "$(shim_count "$home" counted)" = 0 ] \
    || fail "an unchanged PR was re-read with $(shim_count "$home" counted) counted REST calls on the second sweep"
  [ "$(shim_count "$home" not-modified)" = "$first" ] \
    || fail "the second sweep answered $(shim_count "$home" not-modified) of $first REST reads with a 304"
  jq -e '.records[0].error == null and .records[0].observation.head == "'"$HEAD_A"'"' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'cached reads did not yield the same observation'
  printf '[{"id":12,"user":{"login":"maintainer"},"author_association":"OWNER","body":"changed","html_url":"https://github.com/o/r/pull/8#issuecomment-12","updated_at":"2026-09-16T08:01:00Z"}]\n' \
    > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null
  jq -e '.records[0].pending | length == 1' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'a changed resource was served from the cache instead of being read'
  pass 'a repeated poll answers unchanged PR reads with 304s and still sees a changed resource'
}

# Record the quota a response reported, in the documented gh-ratelimit.<resource>.json format.
# A read below the floor is refused, so a test cannot lower the record by reading.
set_quota() { # home remaining reset
  jq -n --argjson remaining "$2" --argjson reset "$3" --argjson now "$(date +%s)" \
    '{resource:"core",limit:5000,remaining:$remaining,reset:$reset,observed:$now}' > "$1/state/gh-ratelimit.core.json"
}

test_low_quota_poll_keeps_last_observation_marked_stale() {
  local home out before reset
  home=$(new_home low-quota)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  jq -e '.records[0].error == null' "$home/data/delivery/contributions.json" >/dev/null || fail 'healthy sweep recorded an error'
  # A sweep whose own responses report 500 of 5000 left crosses the floor mid-observation: the reads still to come
  # are refused before any network call, the last observation is kept, and the episode is announced once.
  out=$(GH_SHIM_REMAINING=500 with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'sweep reporting low quota failed'
  reset=$(jq -r .reset "$home/state/gh-ratelimit.core.json")
  assert_contains "$out" 'quota low (500 of 5000' 'the sweep that crossed the floor did not state the remaining quota'
  assert_contains "$out" "$(jq -rn --argjson r "$reset" '$r | todate')" 'the sweep did not state the reset time'
  jq -e --arg head "$HEAD_A" '.records[0].observation.head == $head and (.records[0].error | contains("quota low"))' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'the last observation was not kept and marked stale with the reason'
  set_quota "$home" 400 "$reset"
  before=$(wc -l < "$home/forge/shim.log")
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'repeat low-quota poll failed'
  [ -z "$out" ] || fail "the low-quota episode was announced twice: $out"
  assert_equals "$before" "$(wc -l < "$home/forge/shim.log")" 'a poll below the floor still called the forge'
  jq -e '.records[0].error | contains("400 of 5000")' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the stale reason did not track changed quota within the episode'
  set_quota "$home" 300 "$((reset + 3600))"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'new low-quota window poll failed'
  assert_contains "$out" 'quota low (300 of 5000' 'a new reset window did not announce its low-quota episode'
  before=$(wc -l < "$home/forge/shim.log")
  with_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" \
    || fail 'could not build the contribution input'
  with_home "$home" "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all \
    | jq -e '.complete == false and .checked == 0 and (.rows[0].reason | contains("quota low") and contains("resets at"))' >/dev/null \
    || fail 'the stale row does not carry the quota reason and reset time'
  # The window resets: the next sweep reads again and clears the mark.
  jq --argjson past "$(( $(date +%s) - 5 ))" '.reset = $past' "$home/state/gh-ratelimit.core.json" > "$home/state/rl.tmp" \
    && mv "$home/state/rl.tmp" "$home/state/gh-ratelimit.core.json"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll after the reset failed'
  [ "$(wc -l < "$home/forge/shim.log")" -gt "$before" ] || fail 'the sweep did not resume after the window reset'
  jq -e '.records[0].error == null' "$home/data/delivery/contributions.json" >/dev/null || fail 'the stale mark outlived the reset'
  pass 'below the floor the poll keeps the last observation stale with the reset time, once, and resumes after the reset'
}

test_failure_after_quota_episode_wakes() {
  local home out line='contributions: observation unavailable for https://github.com/o/r/pull/8'
  home=$(new_home failure-after-quota)
  forge_home "$home"
  wrap_forge "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  registered_checks "$home" >/dev/null
  set_quota "$home" 400 "$(( $(date +%s) + 3600 ))"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'low-quota poll failed'
  assert_contains "$out" 'quota low (400 of 5000' 'the quota episode was not announced'
  jq -e '.records[0].error | contains("quota low")' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the quota episode did not mark the record stale'
  # The window resets and the forge then fails for its own reason: that is a new failure episode.
  set_quota "$home" 400 "$(( $(date +%s) - 5 ))"
  printf 'down\n' > "$home/forge/fault"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'poll of a failing forge after the reset failed'
  [ "$out" = "$line" ] || fail "a genuine failure after a quota episode did not wake: $out"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'repeat poll of a failing forge failed'
  [ -z "$out" ] || fail "an unchanged read failure woke again on the next cycle: $out"
  pass 'a genuine forge failure after a quota-stale episode wakes once'
}

test_late_owners_keep_quota_episode_suppressed() {
  local home out before
  home=$(new_home late-quota-owners)
  forge_home "$home"
  GH_SHIM_REMAINING=400 with_home "$home" "$ROOT/bin/fm-gh-rest.sh" get repos/o/r >/dev/null \
    || fail 'could not seed a low-quota window'
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'initial low-quota poll failed'
  assert_contains "$out" 'quota low (400 of 5000' 'the initial quota episode was not announced'
  before=$(wc -l < "$home/forge/shim.log")
  printf -- '- [ ] aaa - Late owner https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  record "$home" tail 9 open mergeable
  cp "$home/data/tail/contributions.json" "$home/tail.prior.json"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll) || fail 'late-owner low-quota poll failed'
  [ -z "$out" ] || fail "late owners restarted the same quota episode: $out"
  assert_equals "$before" "$(wc -l < "$home/forge/shim.log")" 'late-owner handling contacted the forge below the floor'
  jq -e '.records[0] | .checked_at == null and .observation == null and (.error | contains("400 of 5000"))' \
    "$home/data/aaa/contributions.json" >/dev/null || fail 'a late owner was not marked unmeasured'
  jq -e --slurpfile prior "$home/tail.prior.json" '
    .records[0] as $row | $prior[0].records[0] as $old
    | ($row.error | contains("400 of 5000")) and ($row | del(.error)) == ($old | del(.error))' \
    "$home/data/tail/contributions.json" >/dev/null || fail 'a late URL owner lost its observation or quota reason'
  pass 'late owners of the same or another URL inherit quota staleness without restarting its episode'
}

test_low_quota_wave_guards_graphql_and_marks_every_tail_owner() {
  local home out task mode
  NOW=2026-09-16T00:00:00Z
  for mode in quota-wave quota-deadline; do
    home=$(new_home "$mode-tail")
    forge_home "$home"
    wrap_forge "$home"
    record "$home" duplicate 8 open mergeable
    record "$home" tail 9 open mergeable
    record "$home" final 10 merged mergeable
    for task in delivery duplicate tail final; do
      cp "$home/data/$task/contributions.json" "$home/$task.prior.json"
    done
    /bin/date +%s > "$home/forge/clock"
    printf '%s\n' "$mode" > "$home/forge/fault"
    out=$(with_home "$home" env "$ROOT/bin/fm-contributions.sh" poll) \
      || fail 'poll crossing the quota floor after a parallel wave failed'
    assert_contains "$out" 'quota low (500 of 5000' 'the low-quota wave was not announced'
    assert_equals 7 "$(wc -l < "$home/forge/calls" | tr -d ' ')" 'a GraphQL or tail read escaped the quota floor'
    for task in delivery duplicate tail; do
      jq -e --slurpfile prior "$home/$task.prior.json" '
        .records[0] as $row | $prior[0].records[0] as $old
        | ($row.error | contains("quota low")) and ($row | del(.error)) == ($old | del(.error))' \
        "$home/data/$task/contributions.json" >/dev/null || fail "quota refusal changed or failed to mark owner $task"
    done
    cmp -s "$home/final.prior.json" "$home/data/final/contributions.json" || fail 'quota refusal changed a final observation'
  done
  pass 'a successful REST wave below the floor refuses GraphQL and marks every tail owner despite the budget reserve'
}

test_successful_issue_wave_marks_unmeasured_tail_owners() {
  local home out task
  NOW=2026-09-16T00:00:00Z
  home=$(new_home quota-issue-tail)
  forge_home "$home"
  printf -- '- [ ] filed - Issue https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'initial issue poll failed'
  record "$home" duplicate 8 open mergeable
  record "$home" final 10 merged mergeable
  for task in delivery duplicate final; do
    cp "$home/data/$task/contributions.json" "$home/$task.prior.json"
  done
  wrap_forge "$home"
  /bin/date +%s > "$home/forge/clock"
  printf 'quota-issue\n' > "$home/forge/fault"
  NOW=2026-09-16T00:01:00Z
  out=$(with_home "$home" env "$ROOT/bin/fm-contributions.sh" poll) \
    || fail 'issue poll reporting low quota failed'
  assert_contains "$out" 'quota low (500 of 5000' 'a successful final issue wave hid the quota transition'
  assert_equals 3 "$(wc -l < "$home/forge/calls" | tr -d ' ')" 'a tail URL was read below the floor'
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null and .observation.state == "open"' \
    "$home/data/filed/contributions.json" >/dev/null || fail 'the completed issue observation was not saved as measured'
  for task in delivery duplicate; do
    jq -e --slurpfile prior "$home/$task.prior.json" '
      .records[0] as $row | $prior[0].records[0] as $old
      | ($row.error | contains("quota low")) and ($row | del(.error)) == ($old | del(.error))' \
      "$home/data/$task/contributions.json" >/dev/null || fail "the successful issue wave failed to preserve and mark $task"
  done
  cmp -s "$home/final.prior.json" "$home/data/final/contributions.json" || fail 'a successful low-quota wave changed a final row'
  pass 'a completed issue stays measured while all unmeasured tail owners become quota-stale'
}

test_http_shim_preserves_backend_failures() {
  local home mode status
  home=$(new_home shim-failure)
  forge_home "$home"
  for mode in http passthrough nonapi; do
    case "$mode" in
      http) set -- api -i repos/o/r/unexpected ;;
      passthrough) set -- api repos/o/r/unexpected ;;
      nonapi) set -- release -i unexpected ;;
    esac
    : > "$home/forge/shim.log"
    status=0
    with_home "$home" "$home/fakebin/gh" "$@" > "$home/shim.out" 2> "$home/shim.err" || status=$?
    assert_equals 1 "$status" "$mode shim lost the backend's exit status"
    assert_contains "$(cat "$home/shim.err")" 'unexpected gh fixture call:' "$mode shim swallowed the backend's error"
    assert_equals '' "$(cat "$home/shim.out")" "$mode shim emitted a successful response for a backend failure"
    assert_equals "counted $*" "$(cat "$home/forge/shim.log")" "$mode shim did not log the failed call"
  done
  pass 'HTTP and passthrough shims preserve backend failures without a successful response'
}

# Ordinary merge ownership is exercised through poll and the saved-record projection.
merge_snapshot() {
  local home=$1 before after calls_before calls_after full summary refused refused_all file
  mkdir -p "$home/forge"
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || return
  before=$(for file in "$home"/data/*/contributions.json; do [ ! -f "$file" ] || shasum -a 256 "$file"; done)
  calls_before=$(cat "$home/forge/shim.log" "$home/forge/review-calls" 2>/dev/null || true)
  full=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || return
  summary=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json") || return
  : > "$home/forge/snapshot-refuse"
  refused=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json") || return
  refused_all=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || return
  rm "$home/forge/snapshot-refuse"
  after=$(for file in "$home"/data/*/contributions.json; do [ ! -f "$file" ] || shasum -a 256 "$file"; done)
  calls_after=$(cat "$home/forge/shim.log" "$home/forge/review-calls" 2>/dev/null || true)
  assert_equals "$before" "$after" 'snapshot changed saved contribution bytes'
  assert_equals "$calls_before" "$calls_after" 'snapshot called the forge or verifier'
  assert_equals "$summary" "$refused" 'snapshot depended on forge or verifier availability'
  assert_equals "$full" "$refused_all" 'snapshot --all depended on forge or verifier availability'
  printf '%s\n' "$full"
}

assert_current_inert_verdicts() { # home canonical-input baseline-snapshot
  local home=$1 input=$2 baseline=$3 file task judged out
  mkdir -p "$home/verdict-original"
  for file in "$home"/data/*/contributions.json; do
    [ -f "$file" ] || continue
    task=${file%/contributions.json}; task=${task##*/}
    cp "$file" "$home/verdict-original/$task.json"
  done
  for judged in maintainer nobody; do
    for file in "$home"/verdict-original/*.json; do
      [ -f "$file" ] || continue
      task=${file##*/}; task=${task%.json}
      jq --arg actor "$judged" '.records |= map(
        if .kind == "pr" and (.observation.head | type) == "string"
          and (.verdict == null or ((.verdict.actor == "maintainer" or .verdict.actor == "nobody") and .verdict.head == .observation.head))
        then .verdict={head:.observation.head,actor:$actor,source:"review",summary:"inert judgment"} else . end)' "$file" > "$home/data/$task/contributions.json" || fail 'inert verdict mutation failed'
    done
    out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$input" --all) || fail 'inert verdict snapshot failed'
    assert_equals "$(printf '%s' "$baseline" | jq -c '[.rows[] | {url,actor,reason}]')" "$(printf '%s' "$out" | jq -c '[.rows[] | {url,actor,reason}]')" "current $judged verdict changed a verdict-free row"
  done
  for file in "$home"/verdict-original/*.json; do
    [ -f "$file" ] || continue
    task=${file##*/}; task=${task%.json}
    cp "$file" "$home/data/$task/contributions.json"
    rm "$file"
  done
}

expect_merge_action() { # home reason [actor]
  local out
  out=$(merge_snapshot "$1") || fail 'merge snapshot failed'
  printf '%s' "$out" | jq -e --arg reason "$2" --arg actor "${3:-fleet}" '
    .unreadable_records == 0 and .rows[0].actor == $actor and .rows[0].reason == $reason
    and (if $actor == "fleet" then .counts.captain == 0 and .captain == []
      and (if .complete then .proven_clear else (.proven_clear | not) end) else true end)' >/dev/null \
    || fail "unexpected merge action ($2): $out"
  assert_current_inert_verdicts "$1" "$1/input.json" "$out"
}

merge_home() {
  local home=$1
  forge_home "$home"
  fm_git_init_commit "$home/wt"
  git -C "$home/wt" rev-parse HEAD > "$home/forge/base"
  git -C "$home/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m 'ship implementation'
  git -C "$home/wt" rev-parse HEAD > "$home/forge/head"
  printf 'main\n' > "$home/forge/base-ref"
  printf '0\n' > "$home/forge/behind"
  printf 'true\n' > "$home/forge/push"
  printf 'worktree=%s/wt\nkind=ship\nmodel=gpt-5.1\nbranch=fm/fixture\nmode=direct-PR\n' "$home" > "$home/state/delivery.meta"
  fm_test_empty_pipeline_db "$home/nm-home"
  ln -s "$ROOT/bin/fm-review-record.py" "$home/root/bin/fm-review-record.py"
  review_wrapper "$home"
}

merge_review() { # home verdict [reader] [head] [escalation] [covered-group]
  local home=$1 verdict=$2 reader=${3:-sonnet} head=${4:-$(cat "$1/forge/head")} escalation=${5:-no}
  local groups='{"all":["gpt-5.1"]}' covered='["all"]'
  if [ "${6:-all}" = pr-body ]; then groups='{"pr-body":["gpt-5.1"]}'; covered='["pr-body"]'; fi
  printf 'VERDICT: %s head=%s\nIndependent review.\n' "$verdict" "$head" > "$home/report.md"
  with_home "$home" "$ROOT/bin/fm-review-record.py" review --pr "$(cat "$home/forge/url" 2>/dev/null || printf https://github.com/o/r/pull/8)" \
    --head "$head" --verdict "$verdict" --reader-model "$reader" --author-groups "$groups" --covered-groups "$covered" \
    --loosens-deny-allow-list no --widens-guard "$escalation" --customer-data-billing-spend no \
    --report "$home/report.md" >/dev/null || fail 'could not record review'
}

merge_read_calls_are_safe() { # transport argv log
  local line
  while IFS= read -r line; do
    case "$line" in *required_status_checks*|*rulesets*|*rules/branches*) return 1 ;; esac
    line=${line// -X GET / }
    line=${line// --method GET / }
    case " $line " in *' -X '*|*' --method '*|*' -f '*|*' -F '*|*' --field '*|*' --raw-field '*) return 1 ;; esac
    case "$line" in
      'counted api '*|'not-modified api '*|'counted pr view '*) : ;;
      *) return 1 ;;
    esac
  done < "$1"
}

merge_poll() {
  with_home "$1" bash "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail 'merge poll failed'
  merge_read_calls_are_safe "$1/forge/shim.log" || fail 'poll made a mutating or required-check-set forge request'
}

test_ordinary_merge_ownership() {
  local home
  home=$(new_home ordinary-merge)
  merge_home "$home"
  merge_poll "$home"
  expect_merge_action "$home" 'route the independent review'
  # Cache publication shares the quota lock; seed the resources sequentially
  # so a loaded host cannot turn this local-review test into a cache-lock test.
  local endpoint head
  head=$(cat "$home/forge/head")
  for endpoint in repos/o/r/pulls/8 'repos/o/r/issues/8/comments?per_page=100' \
    'repos/o/r/pulls/8/reviews?per_page=100' 'repos/o/r/pulls/8/comments?per_page=100' \
    "repos/o/r/commits/$head/check-runs?filter=all&per_page=100" \
    "repos/o/r/commits/$head/statuses?per_page=100" repos/o/r "repos/o/r/compare/main...$head?per_page=1"; do
    with_home "$home" bash "$ROOT/bin/fm-gh-rest.sh" get "$endpoint" >/dev/null || fail 'cache preparation failed'
  done
  : > "$home/forge/shim.log"
  merge_review "$home" PASS
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  assert_equals 0 "$(shim_count "$home" counted)" 'unchanged REST resources were unexpectedly reread'
  [ "$(shim_count "$home" not-modified)" -ge 8 ] || fail 'the cached observation did not reuse every REST resource'
  merge_review "$home" FAIL
  merge_poll "$home"
  expect_merge_action "$home" 'route the independent review'
  merge_review "$home" PASS sonnet "$HEAD_B"
  merge_poll "$home"
  expect_merge_action "$home" 'route the independent review'
  merge_review "$home" PASS gpt-5.1
  merge_poll "$home"
  jq -e '.records[0].observation.review_verification.answer | .schema == "fm-review-verification.v1" and .ok == false and .error.kind == "not-qualified"' "$home/data/delivery/contributions.json" >/dev/null || fail 'same-family fixture did not produce typed not-qualified'
  printf 'same-family verifier answer: %s\n' "$(jq -c '.records[0].observation.review_verification.answer' "$home/data/delivery/contributions.json")"
  expect_merge_action "$home" 'route the independent review'
  merge_review "$home" PASS sonnet '' yes
  merge_poll "$home"
  expect_merge_action "$home" 'route the independent review'
  rm "$home/state/review-records.jsonl"
  merge_review "$home" PASS sonnet '' no pr-body
  merge_poll "$home"
  expect_merge_action "$home" 'route the independent review'
  printf 'PR-body-only verifier answer: %s\n' "$(jq -c '.records[0].observation.review_verification.answer' "$home/data/delivery/contributions.json")"
  rm "$home/state/review-records.jsonl"
  with_home "$home" "$ROOT/bin/fm-review-record.py" captain-word --pr https://github.com/o/r/pull/8 \
    --head "$(cat "$home/forge/head")" --words 'Merge this head.' >/dev/null || fail 'word fixture failed'
  merge_poll "$home"
  expect_merge_action "$home" 'route the independent review'
  pass 'ordinary green ownership follows the real exact-head review-only verifier'
}

test_observed_merge_check_precedence() {
  local home state reason
  home=$(new_home merge-checks)
  merge_home "$home"
  merge_review "$home" PASS
  while IFS='|' read -r state reason; do
    jq -n --arg state "$state" '{check_runs:[{name:"test",id:1,started_at:"2026-09-16T08:00:00Z",
      status:(if $state == "pending" then "in_progress" else "completed" end),
      conclusion:(if $state == "pending" or $state == "missing" then null else $state end)}]}' > "$home/forge/checks.json"
    merge_poll "$home"
    expect_merge_action "$home" "$reason"
  done <<'CHECKS'
failure|checks failed
pending|checks still running
missing|check lane has no verdict
CHECKS
  rm "$home/forge/checks.json"
  printf 'false\n' > "$home/forge/push"
  merge_poll "$home"
  expect_merge_action "$home" 'delivery awaits the maintainer' maintainer
  pass 'a qualifying PASS cannot bypass observed failed, pending or missing checks or merge permissions'
}

test_merge_base_observation() {
  local home
  home=$(new_home merge-base)
  merge_home "$home"
  merge_review "$home" PASS
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  # A branch tip can advance without any change to the pull resource's base SHA.
  printf '%s\n' "$HEAD_B" > "$home/forge/base-tip"
  printf '1\n' > "$home/forge/behind"
  merge_poll "$home"
  expect_merge_action "$home" 'update the branch; base is stale'
  printf '%s\n' verify --pr https://github.com/o/r/pull/8 --head "$(cat "$home/forge/head")" \
    --task delivery --base "$(cat "$home/forge/base")" --review-only --json > "$home/base-expected-argv"
  cmp -s "$home/base-expected-argv" "$home/forge/review-argv" || fail 'advanced branch tip replaced the pull base in verifier argv'
  jq -e --arg base "$(cat "$home/forge/base")" '.records[0].observation.review_verification | .base == $base and .answer.ok == true' \
    "$home/data/delivery/contributions.json" >/dev/null || fail 'advanced branch tip corrupted the pull-base review fact'
  mutate_record "$home" delivery '.records[0].verdict={head:.records[0].observation.head,actor:"fleet",source:"review",summary:"merge this head now"}'
  merge_poll "$home"
  expect_merge_action "$home" 'update the branch; base is stale'
  printf '0\n' > "$home/forge/behind"
  merge_poll "$home"
  expect_merge_action "$home" 'merge this head now'
  mutate_record "$home" delivery '.records[0].verdict=null'
  printf 'release/1.0\n' > "$home/forge/base-ref"
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  touch "$home/forge/compare-corrupt"
  merge_poll "$home"
  expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
  rm "$home/forge/compare-corrupt"
  touch "$home/forge/compare-fail"
  merge_poll "$home"
  expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
  jq -e '.records[0].observation.base_containment == null' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'failed comparison reused an old fresh fact'
  pass 'live encoded-base comparisons refresh stale and unknown facts before verdicts'
}

review_wrapper() {
  local home=$1
  rm -f "$home/root/bin/fm-review-record.py"
  printf '#!/usr/bin/env bash\nRECORD=%q\n' "$ROOT/bin/fm-review-record.py" > "$home/root/bin/fm-review-record.py"
  cat >> "$home/root/bin/fm-review-record.py" <<'SH'
printf '%s\n' "$@" > "$FORGE/review-argv"
printf 'verify\n' >> "$FORGE/review-calls"
[ ! -e "$FORGE/snapshot-refuse" ] || exit 1
case "$(cat "$FORGE/verifier-mode" 2>/dev/null || true)" in
  fail) exit 1 ;;
  stall) exit 124 ;;
  silent-slow) : > "$FORGE/verifier-started"; sleep 7 ;;
  progress) for ((n=0; n<7; n++)); do printf 'verifying\n' >&2; sleep 1; done ;;
  corrupt) printf 'not JSON\n'; exit 0 ;;
  payload) cat "$FORGE/verifier-payload"; exit "$(cat "$FORGE/verifier-exit")" ;;
esac
exec "$RECORD" "$@"
SH
  chmod +x "$home/root/bin/fm-review-record.py"
}

test_merge_verifier_unknowns() {
  local home mode payload
  home=$(new_home verifier-unknowns)
  merge_home "$home"
  merge_review "$home" PASS
  review_wrapper "$home"
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  printf '%s\n' verify --pr https://github.com/o/r/pull/8 --head "$(cat "$home/forge/head")" \
    --task delivery --base "$(cat "$home/forge/base")" --review-only --json > "$home/expected-argv"
  cmp -s "$home/expected-argv" "$home/forge/review-argv" || fail 'verifier request is not bound to the landing base and head'
  for mode in fail corrupt stall; do
    printf '%s\n' "$mode" > "$home/forge/verifier-mode"
    merge_poll "$home"
    expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  done
  printf 'progress\n' > "$home/forge/verifier-mode"
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  jq '.records[0].observation.review_verification.answer' "$home/data/delivery/contributions.json" > "$home/good-answer.json"
  for payload in '.schema="wrong"' '.basis="captain-word"' '.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' '.pr="https://github.com/o/r/pull/99"'; do
    jq "$payload" "$home/good-answer.json" > "$home/forge/verifier-payload"
    printf 'payload\n' > "$home/forge/verifier-mode"
    printf '0\n' > "$home/forge/verifier-exit"
    merge_poll "$home"
    expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  done
  printf '{"schema":"fm-review-verification.v1","ok":false,"error":{"kind":"unavailable","message":"unreadable"}}\n' > "$home/forge/verifier-payload"
  printf '1\n' > "$home/forge/verifier-exit"
  merge_poll "$home"
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  rm "$home/root/bin/fm-review-record.py"
  merge_poll "$home"
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  ln -s "$ROOT/bin/fm-review-record.py" "$home/root/bin/fm-review-record.py"
  printf 'worktree=%s/missing\nkind=ship\nmodel=gpt-5.1\n' "$home" > "$home/state/delivery.meta"
  merge_poll "$home"
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  pass 'missing, stalled, corrupt, unbound and unavailable review answers remain fleet unknowns; progressing reads succeed'
}

test_merge_verifier_failure_refresh_and_precedence() {
  local home mode phase mutation expected actor out modes
  home=$(new_home verifier-refresh-precedence)
  merge_home "$home"
  merge_review "$home" PASS
  merge_poll "$home"
  jq '.records[0].observation.review_verification.answer' "$home/data/delivery/contributions.json" > "$home/answer.json"
  modes='fail stall corrupt schema basis head pr invalid unavailable absent'
  for mode in $modes; do
    for phase in first after-pass; do
      rm -f "$home/forge/verifier-mode"
      [ -e "$home/root/bin/fm-review-record.py" ] || review_wrapper "$home"
      if [ "$phase" = after-pass ]; then
        merge_poll "$home"
        expect_merge_action "$home" 'merge under the standing merge rule'
      else
        rm "$home/data/delivery/contributions.json"
      fi
      printf '%s\n' "$mode" > "$home/forge/verifier-mode"
      case "$mode" in
        schema|basis|head|pr|invalid|unavailable)
          mutation=.
          case "$mode" in
            schema) mutation='.schema="wrong"' ;;
            basis) mutation='.basis="captain-word"' ;;
            head) mutation='.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' ;;
            pr) mutation='.pr="https://github.com/other/project/pull/44"' ;;
            invalid|unavailable) mutation="{schema:\"fm-review-verification.v1\",ok:false,error:{kind:\"$(if [ "$mode" = invalid ]; then printf invalid-input; else printf unavailable; fi)\"}}" ;;
          esac
          jq "$mutation" "$home/answer.json" > "$home/forge/verifier-payload"
          printf 'payload\n' > "$home/forge/verifier-mode"
          printf '0\n' > "$home/forge/verifier-exit" ;;
        absent) rm "$home/root/bin/fm-review-record.py" ;;
      esac
      merge_poll "$home"
      expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
      printf 'verifier failure %s %s: %s\n' "$mode" "$phase" "$(jq -c '.records[0].observation.review_verification' "$home/data/delivery/contributions.json")"
    done
    cp "$home/data/delivery/contributions.json" "$home/failed.json"
    while IFS='|' read -r expected actor mutation; do
      cp "$home/failed.json" "$home/data/delivery/contributions.json"
      mutate_record "$home" delivery "$mutation"
      expect_merge_action "$home" "$expected" "$actor"
    done <<'HIGHER'
update the branch; base is stale|fleet|.records[0].observation.base_containment.behind_by=1
review required|maintainer|.records[0].observation.review_decision="REVIEW_REQUIRED"
delivery awaits the maintainer|maintainer|.records[0].observation.can_merge=false
merge this head now|fleet|.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"fleet",summary:"merge this head now"}
record the unresolved arbitration as a captain hold|fleet|.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"captain",summary:"choose"}
HIGHER
    cp "$home/failed.json" "$home/data/delivery/contributions.json"
    FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold delivery --reason 'choose verifier contract'
    expect_merge_action "$home" 'choose verifier contract' captain
    printf 'Use the contract.\n' > "$home/decision.txt"
    contribution_hold "$home" answer delivery --decision-file "$home/decision.txt" --release
    with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.raw.json" || fail 'away verifier input failed'
    jq '.tasks += [{id:"delivery",kind:"ship",merge_authority:"away",pr:{url:"https://github.com/o/r/pull/8",head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' "$home/input.raw.json" > "$home/input.json"
    out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'away verifier snapshot failed'
    printf '%s' "$out" | jq -e '.rows[0].actor == "fleet" and .rows[0].reason == "checks green; merge is authorized by delivery posture"' >/dev/null || fail "failed verifier changed away row: $out"
    cp "$home/failed.json" "$home/data/delivery/contributions.json"
    NOW=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601 + 1 | todateiso8601')
  done
  pass 'first and attempted-refresh verifier failures replace old PASS facts without changing higher-priority rows'
}

test_merge_refresh_and_read_call_audit() {
  local home mode out
  home=$(new_home merge-refresh-read-audit)
  merge_home "$home"
  merge_review "$home" PASS
  for mode in pull compare verifier quota; do
    merge_poll "$home"
    expect_merge_action "$home" 'merge under the standing merge rule'
    case "$mode" in
      pull) touch "$home/forge/pull-fail" ;;
      compare) touch "$home/forge/compare-corrupt" ;;
      verifier) printf 'fail\n' > "$home/forge/verifier-mode" ;;
      quota) set_quota "$home" 400 "$(( $(date +%s) + 3600 ))" ;;
    esac
    merge_poll "$home"
    case "$mode" in
      pull) expect_merge_action "$home" 'forge observation unavailable or changed during read' ;;
      compare) expect_merge_action "$home" 'base freshness unknown; refresh the base comparison' ;;
      verifier) expect_merge_action "$home" 'PASS fact unknown; recheck the independent review' ;;
      quota)
        out=$(merge_snapshot "$home")
        printf '%s' "$out" | jq -e '.rows[0].actor == "fleet" and (.rows[0].reason | contains("quota low"))' >/dev/null || fail 'quota failure retained merge-ready facts' ;;
    esac
    printf 'failed refresh %s saved: %s\n' "$mode" "$(jq -c '.records[0]' "$home/data/delivery/contributions.json")"
    rm -f "$home/forge/pull-fail" "$home/forge/compare-corrupt" "$home/forge/verifier-mode"
    set_quota "$home" 400 "$(( $(date +%s) - 5 ))"
    merge_poll "$home"
    expect_merge_action "$home" 'merge under the standing merge rule'
  done
  printf 'read-only forge argv log:\n'; cat "$home/forge/shim.log"
  cp "$home/forge/shim.log" "$home/safe-calls"
  with_home "$home" bash "$ROOT/bin/fm-gh-rest.sh" get repos/o/r/branches/main/protection/required_status_checks >/dev/null 2>&1 || true
  if merge_read_calls_are_safe "$home/forge/shim.log"; then fail 'call audit accepted a controlled added required-check-set read'; fi
  cp "$home/safe-calls" "$home/forge/shim.log"
  # The record() fixture retains the BASE tests' pre-fact shape.
  record "$home" delivery 8 open mergeable
  mutate_record "$home" delivery '.records[0].observation.can_merge=true'
  expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
  mutate_record "$home" delivery '.records[0].verdict={head:.records[0].observation.head,actor:"fleet",source:"review",summary:"keep legacy verdict"}'
  expect_merge_action "$home" 'keep legacy verdict'
  if [ -n "${FM_TEST_BASE_ROOT:-}" ]; then
    out=$(with_home "$home" bash "$FM_TEST_BASE_ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'BASE legacy verdict snapshot failed'
    printf '%s' "$out" | jq -e '.rows[0].actor == "fleet" and .rows[0].reason == "keep legacy verdict"' >/dev/null || fail 'legacy verdict differs from BASE'
  fi
  pass 'attempted refresh failures invalidate readiness, recover, and every forge operation is read-only with no required-check-set read'
}

test_merge_stalled_compare_publishes_unknown_base() {
  local home child url=https://github.com/o/r/pull/8
  home=$(new_home stalled-compare)
  merge_home "$home"
  merge_review "$home" PASS
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  : > "$home/forge/compare-silent"
  NOW=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601 + 300 | todateiso8601')
  merge_poll "$home"
  IFS= read -r child < "$home/forge/hung-pid"
  ! kill -0 "$child" 2>/dev/null || fail 'the silent base comparison survived its read stop'
  jq -e --arg now "$NOW" '.records[0] | .checked_at == $now and .error == null
    and .observation.base_containment == null
    and .observation.review_verification.answer.ok == true' "$home/data/delivery/contributions.json" >/dev/null \
    || fail "stalled comparison did not publish the head-checked observation: $(jq -c '.records[0]' "$home/data/delivery/contributions.json")"
  grep -Fxq "$url" "$home/state/.contributions-deferred" || fail 'stalled comparison did not defer its URL'
  expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
  rm "$home/forge/compare-silent"
  NOW=$(jq -nr --arg now "$NOW" '$now | fromdateiso8601 + 300 | todateiso8601')
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  ! grep -Fxq "$url" "$home/state/.contributions-deferred" || fail 'a complete read left its URL deferred'
  pass 'a stalled base comparison after a qualifying PASS publishes base unknown and defers the URL'
}

test_merge_silent_verifier_waits() {
  local home pid rc=0
  home=$(new_home verifier-silent-wait)
  merge_home "$home"
  merge_review "$home" PASS
  review_wrapper "$home"
  printf 'silent-slow\n' > "$home/forge/verifier-mode"
  with_home "$home" bash "$ROOT/bin/fm-contributions.sh" poll > "$home/poll.out" 2> "$home/poll.err" &
  pid=$!
  while [ ! -e "$home/forge/verifier-started" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" || true; fail 'poll exited before the verifier started'; }
    sleep 0.1
  done
  sleep 6
  kill -0 "$pid" 2>/dev/null || rc=1
  wait "$pid" || fail 'silent verifier poll failed'
  [ "$rc" = 0 ] || fail 'poll stopped waiting while its verifier was silently sleeping'
  expect_merge_action "$home" 'merge under the standing merge rule'
  pass 'poll waits beyond five silent CPU-idle seconds and uses the verifier answer'
}

test_merge_saved_facts_and_freshness() {
  local home initial
  home=$(new_home saved-merge-facts)
  merge_home "$home"
  merge_review "$home" PASS
  merge_poll "$home"
  cp "$home/data/delivery/contributions.json" "$home/good.json"
  mutate_record "$home" delivery '.records[0].observation.review_verification.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"'
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  cp "$home/good.json" "$home/data/delivery/contributions.json"
  mutate_record "$home" delivery '.records[0].observation.review_verification.task="another-task"'
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  cp "$home/good.json" "$home/data/delivery/contributions.json"
  mutate_record "$home" delivery '.records[0].observation.review_verification.base="cccccccccccccccccccccccccccccccccccccccc"'
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  mutate_record "$home" delivery '.records[0].observation.review_verification={}'
  expect_merge_action "$home" 'PASS fact unknown; recheck the independent review'
  mutate_record "$home" delivery 'del(.records[0].observation.base_containment,.records[0].observation.base_sha,.records[0].observation.review_verification)'
  expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
  cp "$home/good.json" "$home/data/delivery/contributions.json"
  initial=$NOW
  NOW=2026-09-16T08:15:00Z
  expect_merge_action "$home" 'merge under the standing merge rule'
  NOW=2026-09-16T08:15:01Z
  expect_merge_action "$home" 'contribution not recently checked'
  FM_CONTRIBUTIONS_MAX_AGE=1800 expect_merge_action "$home" 'merge under the standing merge rule'
  NOW=2026-09-16T08:30:01Z
  FM_CONTRIBUTIONS_MAX_AGE=1800 expect_merge_action "$home" 'contribution not recently checked'
  merge_poll "$home"
  expect_merge_action "$home" 'merge under the standing merge rule'
  mutate_record "$home" delivery '.records[0].observation.review_verification="malformed"'
  merge_snapshot "$home" | jq -e '.unreadable_records == 1 and .counts.captain == 0 and .counts.fleet == 1' >/dev/null \
    || fail 'malformed new facts bypassed strict saved-record degradation'
  cp "$home/good.json" "$home/data/delivery/contributions.json"
  NOW=$initial
  set_quota "$home" 400 "$(( $(date +%s) + 3600 ))"
  merge_poll "$home"
  merge_snapshot "$home" | jq -e '.rows[0].actor == "fleet" and (.rows[0].reason | contains("quota low"))' >/dev/null \
    || fail 'quota refusal kept old facts merge-ready'
  pass 'saved fact binding, pre-fact compatibility, quota degradation and configured freshness boundaries fail safe and recover'
}

expect_hold_bucket() { # home bucket-or-none
  local out
  out=$(with_home "$1" bash "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail 'canonical hold snapshot failed'
  printf '%s' "$out" | jq -e --arg bucket "$2" '
    [.backlog.records[] | select(.id == "delivery")][0]
    | (.hold_bucket // "none") == $bucket' >/dev/null || fail "unexpected canonical hold bucket $2: $out"
  printf 'canonical hold bucket: %s\n' "$2"
  if [ -n "${FM_TEST_BASE_ROOT:-}" ]; then
    printf '%s\n' "$out" > "$1/lifecycle-input.json"
    out=$(with_home "$1" bash "$FM_TEST_BASE_ROOT/bin/fm-contributions.sh" snapshot "$1/lifecycle-input.json" --all) || fail 'BASE lifecycle snapshot failed'
    if [ "$2" = live ]; then
      printf '%s' "$out" | jq -e '.rows[0].actor == "captain" and .rows[0].hold == "delivery"' >/dev/null || fail 'BASE lost live hold'
    else
      printf '%s' "$out" | jq -e '.rows[0].actor == "captain" and .rows[0].reason == "checks green; merge approval needed"' >/dev/null || fail "BASE lifecycle contrast changed: $out"
    fi
    printf 'BASE lifecycle %s: %s\n' "$2" "$(printf '%s' "$out" | jq -c '.rows[0] | {actor,reason,hold}')"
  fi
}

test_merge_hold_lifecycle() {
  local home variant at out initial=$NOW
  for variant in live answered dated aged blocked paused; do
    NOW=$initial
    home=$(new_home "merge-hold-$variant")
    merge_home "$home"
    if [ "$variant" = live ]; then merge_review "$home" PASS; fi
    merge_poll "$home"
    at=$NOW
    if [ "$variant" = dated ]; then
      FM_CAPTAIN_HOLD_NOW="$at" with_home "$home" bash "$ROOT/bin/fm-captain-hold.sh" hold delivery --reason 'choose contract' --until 2099-01-01 >/dev/null || fail 'dated hold failed'
    elif [ "$variant" != paused ]; then
      FM_CAPTAIN_HOLD_NOW="$at" with_home "$home" bash "$ROOT/bin/fm-captain-hold.sh" hold delivery --reason 'choose contract' >/dev/null || fail 'real hold failed'
    fi
    case "$variant" in
      live)
        expect_hold_bucket "$home" live
        expect_merge_action "$home" 'choose contract' captain
        out=$(merge_snapshot "$home")
        printf '%s' "$out" | jq -e '.rows[0].hold == "delivery" and .counts.captain == 1 and (.proven_clear | not)' >/dev/null || fail 'live hold identity missing'
        ;;
      answered)
        printf 'Use the accepted contract.\n' > "$home/decision.txt"
        with_home "$home" bash "$ROOT/bin/fm-captain-hold.sh" answer delivery --decision-file "$home/decision.txt" --release >/dev/null || fail 'answer failed'
        expect_hold_bucket "$home" none
        expect_merge_action "$home" 'route the independent review'
        mutate_record "$home" delivery '.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"captain",summary:"choose"}'
        expect_merge_action "$home" 'record the unresolved arbitration as a captain hold'
        FM_CAPTAIN_HOLD_NOW=2026-09-16T08:00:01Z with_home "$home" bash "$ROOT/bin/fm-captain-hold.sh" hold delivery --reason 'new choice' >/dev/null || fail 're-hold failed'
        FM_SNAPSHOT_NOW=2026-09-16T08:01:00Z expect_hold_bucket "$home" live
        FM_SNAPSHOT_NOW=2026-09-16T08:01:00Z expect_merge_action "$home" 'new choice' captain ;;
      aged)
        NOW=2026-10-16T08:00:00Z
        merge_poll "$home"
        expect_hold_bucket "$home" aged
        expect_merge_action "$home" 'route the independent review'
        FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=100 expect_hold_bucket "$home" live
        FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=100 expect_merge_action "$home" 'choose contract' captain ;;
      blocked)
        with_home "$home" bash "$ROOT/bin/fm-tasks-axi.sh" add dependency 'Unfinished dependency' --kind ship --repo sample >/dev/null || fail 'add blocker failed'
        with_home "$home" bash "$ROOT/bin/fm-tasks-axi.sh" block delivery --by dependency >/dev/null || fail 'block failed'
        expect_hold_bucket "$home" blocked
        expect_merge_action "$home" 'route the independent review' ;;
      paused)
        printf 'paused: waiting for external CI\n' > "$home/state/delivery.status"
        expect_hold_bucket "$home" none
        expect_merge_action "$home" 'route the independent review' ;;
      dated)
        expect_hold_bucket "$home" dated
        expect_merge_action "$home" 'route the independent review'
        mutate_record "$home" delivery '.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"captain",summary:"choose"}'
        expect_merge_action "$home" 'record the unresolved arbitration as a captain hold' ;;
      *) expect_merge_action "$home" 'route the independent review' ;;
    esac
    printf 'hold variant: %s\n' "$variant"
  done
  NOW=$initial
  # A live hold on either owner wins without creating duplicate contribution rows.
  record "$home" duplicate 8 open mergeable
  jq '.task="duplicate" | .records[].observation.review_verification.task="duplicate"' \
    "$home/data/delivery/contributions.json" > "$home/data/duplicate/contributions.json"
  expect_merge_action "$home" 'route the independent review'
  FM_CAPTAIN_HOLD_NOW="$NOW" with_home "$home" bash "$ROOT/bin/fm-captain-hold.sh" hold duplicate --reason 'shared choice' >/dev/null || fail 'shared hold failed'
  expect_merge_action "$home" 'shared choice' captain
  merge_snapshot "$home" | jq -e '.known == 1 and .rows[0].tasks == ["delivery","duplicate"]' >/dev/null || fail 'shared URL produced duplicate rows'
  pass 'real live holds alone reach the owner; answered, dated, blocked, aged and paused work stays fleet'
}

test_away_merge_action() {
  local home
  home=$(new_home away-merge)
  merge_home "$home"
  printf 'pr=https://github.com/o/r/pull/8\npr_head=%s\nyolo=on\n' "$(cat "$home/forge/head")" >> "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
    || fail 'could not enter away posture'
  merge_poll "$home"
  expect_merge_action "$home" 'checks green; merge is authorized by delivery posture'
  printf '1\n' > "$home/forge/behind"
  merge_poll "$home"
  expect_merge_action "$home" 'checks green; merge is authorized by delivery posture'
  mutate_record "$home" delivery '.records[0].verdict={head:.records[0].observation.head,actor:"fleet",source:"review",summary:"merge this head now"}'
  merge_poll "$home"
  expect_merge_action "$home" 'merge this head now'
  mutate_record "$home" delivery '.records[0].verdict=null'
  printf '0\n' > "$home/forge/behind"
  merge_review "$home" PASS
  merge_poll "$home"
  expect_merge_action "$home" 'checks green; merge is authorized by delivery posture'
  touch "$home/forge/compare-fail"
  merge_poll "$home"
  expect_merge_action "$home" 'checks green; merge is authorized by delivery posture'
  pass 'away rows preserve their posture reason regardless of base and PASS facts, and keep recorded fleet verdicts'
}

shared_mutation() { # home other jq-mutation
  mutate_record "$1" delivery "$3"
  mutate_record "$1" "$2" "$3"
}

shared_restore() { # home other
  cp "$1/delivery.json" "$1/data/delivery/contributions.json"
  cp "$1/other.json" "$1/data/$2/contributions.json"
}

contribution_hold() { # home hold-arguments...
  local home=$1
  shift
  with_home "$home" bash "$ROOT/bin/fm-captain-hold.sh" "$@" >/dev/null || fail "captain hold command failed: $*"
}

test_captain_verdict_requires_live_hold() {
  local home
  home=$(new_home captain-verdict-hold)
  merge_home "$home"
  merge_poll "$home"
  with_home "$home" bash "$ROOT/bin/fm-contributions.sh" verdict delivery https://github.com/o/r/pull/8 \
    "$(cat "$home/forge/head")" https://github.com/o/r/pull/8#issuecomment-1 captain 'choose X' >/dev/null \
    || fail 'could not record captain verdict'
  expect_merge_action "$home" 'record the unresolved arbitration as a captain hold'
  mutate_record "$home" delivery '.records[0].observation.base_containment.behind_by=1'
  expect_merge_action "$home" 'update the branch; base is stale'
  FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold delivery --reason 'choose contract'
  expect_merge_action "$home" 'choose contract' captain
  printf 'Use the accepted contract.\n' > "$home/decision.txt"
  contribution_hold "$home" answer delivery --decision-file "$home/decision.txt" --release
  expect_merge_action "$home" 'update the branch; base is stale'
  printf 'paused: waiting for external CI\n' > "$home/state/delivery.status"
  expect_merge_action "$home" 'update the branch; base is stale'
  pass 'recorded captain verdicts stay fleet before and after an actual hold answer; only the live hold reaches the owner'
}

test_shared_url_live_hold_outranks_verdict() {
  local other home url=https://github.com/o/r/pull/8
  for other in a-verdict z-verdict; do
    home=$(new_home "shared-hold-$other")
    forge_home "$home"
    record "$home" "$other" 8 open mergeable
    sed "s|$url||" "$home/data/backlog.md" > "$home/backlog.new" && mv "$home/backlog.new" "$home/data/backlog.md"
    printf 'pr=%s\npr_head=%s\n' "$url" "$HEAD_A" >> "$home/state/delivery.meta"
    printf 'kind=ship\npr=%s\npr_head=%s\n' "$url" "$HEAD_A" > "$home/state/$other.meta"
    FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold delivery --reason 'zzz hold reason'
    mutate_record "$home" "$other" '.records[0].verdict={head:.records[0].observation.head,actor:"captain",source:"review",summary:"aaa verdict"}'
    expect_merge_action "$home" 'zzz hold reason' captain
    merge_snapshot "$home" | jq -e '.known == 1 and .rows[0].hold == "delivery" and .captain[0].hold == "delivery"' >/dev/null \
      || fail "a captain verdict beside $other hid the live hold"
  done
  pass 'a live hold keeps its id ahead of a captain verdict in either task-name order'
}

test_shared_url_label_follows_facts() {
  local other home actor
  for other in a-landing z-landing; do
    home=$(new_home "shared-label-$other")
    merge_home "$home"
    merge_review "$home" PASS
    record "$home" "$other" 8 open mergeable
    merge_poll "$home"
    expect_merge_action "$home" 'merge under the standing merge rule'
    merge_snapshot "$home" | jq -e --arg other "$other" '.known == 1 and .rows[0].task == "delivery"
      and .rows[0].tasks == ([$other,"delivery"] | sort) and (.rows[0] | has("label_rank") | not)' >/dev/null \
      || fail "shared URL lost the qualifying owner beside $other"
    jq -e '.records[0].observation.review_verification.answer.ok == false' "$home/data/$other/contributions.json" >/dev/null \
      || fail "fixture owner $other unexpectedly qualified"
    mutate_record "$home" "$other" '.records[0].verdict={head:.records[0].observation.head,actor:"maintainer",source:"review",summary:"awaiting maintainer"}'
    expect_merge_action "$home" 'merge under the standing merge rule'
    mutate_record "$home" "$other" '.records[0].verdict=null
      | .records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}}'
    expect_merge_action "$home" 'merge under the standing merge rule'
    cp "$home/data/delivery/contributions.json" "$home/delivery.json"
    cp "$home/data/$other/contributions.json" "$home/other.json"
    shared_mutation "$home" "$other" '.records[0].observation.can_merge=false'
    expect_merge_action "$home" 'delivery awaits the maintainer' maintainer
    shared_restore "$home" "$other"
    shared_mutation "$home" "$other" '.records[0].observation.review_decision="REVIEW_REQUIRED"'
    expect_merge_action "$home" 'review required' maintainer
    shared_restore "$home" "$other"
    for actor in maintainer nobody; do
      mutate_record "$home" "$other" ".records[0].verdict={head:.records[0].observation.head,actor:\"$actor\",source:\"review\",summary:\"kept judgment\"}"
      cp "$home/data/$other/contributions.json" "$home/other.json"
      shared_mutation "$home" "$other" '.records[0].observation.base_containment.behind_by=1'
      expect_merge_action "$home" 'update the branch; base is stale'
      shared_restore "$home" "$other"
      shared_mutation "$home" "$other" 'del(.records[0].observation.base_containment)'
      expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
      shared_restore "$home" "$other"
    done
    printf 'pr=https://github.com/o/r/pull/8\npr_head=%s\nyolo=on\n' "$(cat "$home/forge/head")" >> "$home/state/delivery.meta"
    with_home "$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null \
      || fail 'could not enter away posture'
    for actor in maintainer nobody; do
      mutate_record "$home" "$other" ".records[0].verdict={head:.records[0].observation.head,actor:\"$actor\",source:\"review\",summary:\"kept judgment\"}"
      expect_merge_action "$home" 'checks green; merge is authorized by delivery posture'
    done
    mutate_record "$home" "$other" '.records[0].verdict=null'
    expect_merge_action "$home" 'checks green; merge is authorized by delivery posture'
  done
  pass 'a shared URL row follows the owners facts in either task-name order'
}

test_preserved_base_rows() {
  local home state judged id actor reason mutation number=600 out base_out
  home=$(new_home preserved-base-rows)
  : > "$home/expected.tsv"
  for state in review-required cannot-merge away failed cannot-merge-unknown; do
    for judged in none fleet captain maintainer nobody; do
      id="$state-$judged"
      record "$home" "$id" "$number" open mergeable
      number=$((number + 1))
      mutate_record "$home" "$id" '.records[0].observation += {can_merge:true,base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base_containment:{behind_by:1}}'
      case "$state" in
        review-required) actor=maintainer; reason='review required'; mutation='.records[0].observation.review_decision="REVIEW_REQUIRED"' ;;
        cannot-merge) actor=maintainer; reason='delivery awaits the maintainer'; mutation='.records[0].observation.can_merge=false' ;;
        away) actor=fleet; reason='checks green; merge is authorized by delivery posture'; mutation='.' ;;
        failed) actor=fleet; reason='checks failed'; mutation='.records[0].observation.checks[0].conclusion="failure"' ;;
        cannot-merge-unknown) actor=maintainer; reason='delivery awaits the maintainer'; mutation='.records[0].observation.can_merge=false | del(.records[0].observation.base_containment)' ;;
      esac
      mutate_record "$home" "$id" "$mutation"
      if [ "$judged" != none ]; then
        mutate_record "$home" "$id" ".records[0].verdict={head:.records[0].observation.head,actor:\"$judged\",source:\"review\",summary:\"merge this head now\"}"
        if [ "$state" != failed ]; then
          case "$judged" in
            fleet) actor=fleet; reason='merge this head now' ;;
            captain) actor=fleet; reason='record the unresolved arbitration as a captain hold' ;;
          esac
        fi
      fi
      printf '%s\t%s\t%s\n' "$id" "$actor" "$reason" >> "$home/expected.tsv"
    done
  done
  for judged in fleet maintainer nobody; do
    id="stale-head-$judged"
    record "$home" "$id" "$number" open mergeable
    number=$((number + 1))
    mutate_record "$home" "$id" ".records[0].verdict={head:\"$HEAD_B\",actor:\"$judged\",source:\"review\",summary:\"old judgment\"}"
    printf '%s\tfleet\tSTALE maintainer verdict; reassess the current head\n' "$id" >> "$home/expected.tsv"
  done
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.raw.json" || fail 'preserved input failed'
  jq '.tasks += [.backlog.records[] | select(.id | startswith("away-")) | {id:.id,kind:"ship",merge_authority:"away",pr:{url:.links[0],head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' "$home/input.raw.json" > "$home/input.json"
  out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'preserved snapshot failed'
  while IFS="$(printf '\t')" read -r id actor reason; do
    printf '%s' "$out" | jq -e --arg id "$id" --arg actor "$actor" --arg reason "$reason" '[.rows[] | select(.task == $id) | [.actor,.reason]] == [[$actor,$reason]]' >/dev/null || fail "preserved $id changed: $out"
  done < "$home/expected.tsv"
  if [ -n "${FM_TEST_BASE_ROOT:-}" ]; then
    base_out=$(with_home "$home" bash "$FM_TEST_BASE_ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'BASE preserved snapshot failed'
    assert_equals "$(printf '%s' "$base_out" | jq -c '[.rows[] | {url,actor,reason}]')" "$(printf '%s' "$out" | jq -c '[.rows[] | {url,actor,reason}]')" 'preserved rows differ from BASE'
  fi
  printf '%s' "$out" | jq -r '.rows[] | [.task,.actor,.reason] | @tsv'
  pass 'excluded stale-base records with every verdict actor retain their BASE actor and reason'
}

test_live_hold_branch_preservation() {
  local home id mutation reason number=700 out base_out
  home=$(new_home held-branches)
  : > "$home/expected.tsv"
  while IFS='|' read -r id reason mutation; do
    record "$home" "$id" "$number" open mergeable
    number=$((number + 1))
    mutate_record "$home" "$id" "$mutation"
    FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold "$id" --reason 'choose held branch'
    printf '%s\t%s\n' "$id" "$reason" >> "$home/expected.tsv"
  done <<'BRANCHES'
stale-observation|contribution not recently checked|.records[0].checked_at="2026-09-15T08:00:00Z"
stale-verdict|STALE maintainer verdict; reassess the current head|.records[0].verdict={head:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",actor:"fleet",source:"review",summary:"old"}
pending-signal|incoming maintainer signal needs triage|.records[0].pending=[{token:"comment:1"}]
issue|awaiting issue triage|.records[0].kind="issue" | .records[0].observation.ready=false
draft|draft delivery|.records[0].observation.draft=true
conflicting|mergeability conflicting|.records[0].observation.mergeable="conflicting"
unknown|mergeability unknown|.records[0].observation.mergeable="unknown"
failed|checks failed|.records[0].observation.checks[0].conclusion="failure"
no-verdict|check lane has no verdict|.records[0].observation.checks[0].conclusion=null
no-checks|no reported checks; readiness unconfirmed|.records[0].observation.checks=[]
pending-check|checks still running|.records[0].observation.checks[0].status="in_progress"
changes|forge requests changes|.records[0].observation.review_decision="CHANGES_REQUESTED"
review-required|review required|.records[0].observation.review_decision="REVIEW_REQUIRED"
cannot-merge|delivery awaits the maintainer|.
fleet-verdict|merge this head now|.records[0].verdict={head:.records[0].observation.head,actor:"fleet",source:"review",summary:"merge this head now"}
captain-verdict|record the unresolved arbitration as a captain hold|.records[0].verdict={head:.records[0].observation.head,actor:"captain",source:"review",summary:"choose"}
away|checks green; merge is authorized by delivery posture|.records[0].observation.can_merge=true
merged|forge reports merged|.records[0].observation.state="merged"
closed|forge reports closed|.records[0].observation.state="closed"
merged-error|terminal observation needs refresh|.records[0].observation.state="merged" | .records[0].error="saved transport failure"
BRANCHES
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.raw.json" || fail 'held input failed'
  jq '.tasks += [.backlog.records[] | select(.id == "away") | {id:.id,kind:"ship",merge_authority:"away",pr:{url:.links[0],head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' "$home/input.raw.json" > "$home/held.json"
  jq '.backlog.records |= map(del(.hold_bucket,.hold_reason))' "$home/held.json" > "$home/free.json"
  for mutation in held free; do
    out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/$mutation.json" --all) || fail 'hold branch snapshot failed'
    if [ -n "${FM_TEST_BASE_ROOT:-}" ]; then
      base_out=$(with_home "$home" bash "$FM_TEST_BASE_ROOT/bin/fm-contributions.sh" snapshot "$home/$mutation.json" --all) || fail 'BASE hold branch snapshot failed'
      assert_equals "$(printf '%s' "$base_out" | jq -c '[.rows[] | {url,actor,reason,hold}]')" "$(printf '%s' "$out" | jq -c '[.rows[] | {url,actor,reason,hold}]')" 'live hold branch priority differs from BASE'
    fi
    while IFS="$(printf '\t')" read -r id reason; do
      if [ "$mutation" = held ]; then
        case "$id" in merged|closed|merged-error) : ;; *) reason='choose held branch' ;; esac
      fi
      printf '%s' "$out" | jq -e --arg id "$id" --arg reason "$reason" --arg mode "$mutation" '
        [.rows[] | select(.task == $id)][0] | .reason == $reason
        and (if $mode == "held" and ($id != "merged" and $id != "closed" and $id != "merged-error") then .actor == "captain" and .hold == $id else .actor != "captain" end)' >/dev/null || fail "hold branch $mutation $id changed: $out"
    done < "$home/expected.tsv"
    printf 'hold branch %s rows: %s\n' "$mutation" "$(printf '%s' "$out" | jq -c '[.rows[] | {task,actor,reason,hold}]')"
  done
  home=$(new_home legacy-held-branch)
  record "$home" delivery 8 open mergeable
  mutate_record "$home" delivery '.records[0].observation.can_merge=true'
  FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold delivery --reason 'choose legacy contract'
  expect_merge_action "$home" 'choose legacy contract' captain
  if [ -n "${FM_TEST_BASE_ROOT:-}" ]; then
    base_out=$(with_home "$home" bash "$FM_TEST_BASE_ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'BASE legacy hold snapshot failed'
    printf '%s' "$base_out" | jq -e '.rows[0].actor == "captain" and .rows[0].hold == "delivery" and .rows[0].reason == "choose legacy contract"' >/dev/null || fail 'BASE lost legacy hold'
  fi
  for id in maintainer nobody; do
    mutate_record "$home" delivery ".records[0].verdict={head:.records[0].observation.head,actor:\"$id\",source:\"review\",summary:\"inert judgment\"}"
    expect_merge_action "$home" 'choose legacy contract' captain
    if [ -n "${FM_TEST_BASE_ROOT:-}" ]; then
      base_out=$(with_home "$home" bash "$FM_TEST_BASE_ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'BASE inert held verdict failed'
      printf '%s' "$base_out" | jq -e '.rows[0].actor == "captain" and .rows[0].hold == "delivery" and .rows[0].reason == "choose legacy contract"' >/dev/null || fail 'BASE inert verdict changed a live hold'
    fi
  done
  printf 'Use the legacy contract.\n' > "$home/decision.txt"
  contribution_hold "$home" answer delivery --decision-file "$home/decision.txt" --release
  expect_merge_action "$home" 'base freshness unknown; refresh the base comparison'
  pass 'real live holds outrank every later branch and preserve terminal priority at BASE; legacy facts and inert verdicts do not hide holds'
}

test_merge_arbitrary_url_and_task() {
  local home mode head expected task=arbitrary-ship url=https://github.com/another-owner/another-project/pull/47
  home=$(new_home arbitrary-owner)
  merge_home "$home"
  mv "$home/data/delivery" "$home/data/$task"
  mv "$home/state/delivery.meta" "$home/state/$task.meta"
  jq --arg task "$task" --arg url "$url" '.task=$task | .records[].url=$url' "$home/data/$task/contributions.json" > "$home/new-record.json"
  mv "$home/new-record.json" "$home/data/$task/contributions.json"
  printf '# Backlog\n\n## Queued\n- [ ] %s - Contribution %s (repo: sample) (kind: ship)\n' "$task" "$url" > "$home/data/backlog.md"
  printf '%s\n' "$url" > "$home/forge/url"
  # The same fake responses serve a second arbitrary resource namespace.
  mv "$home/fakebin/gh" "$home/fakebin/gh-original"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
args=()
for arg in "$@"; do
  arg=${arg//repos\/another-owner\/another-project/repos\/o\/r}
  arg=${arg//\/pulls\/47/\/pulls\/8}
  arg=${arg//\/issues\/47/\/issues\/8}
  arg=${arg//https:\/\/github.com\/another-owner\/another-project\/pull\/47/https:\/\/github.com\/o\/r\/pull\/8}
  args+=("$arg")
done
exec "${BASH_SOURCE[0]%/*}/gh-original" "${args[@]}"
SH
  chmod +x "$home/fakebin/gh"
  for mode in absent qualified fail different-head same-family escalation pr-body owner-word stale; do
    rm -f "$home/state/review-records.jsonl"
    head=$(cat "$home/forge/head")
    case "$mode" in
      absent) expected='route the independent review' ;;
      qualified|stale) merge_review "$home" PASS; expected='merge under the standing merge rule' ;;
      fail) merge_review "$home" FAIL; expected='route the independent review' ;;
      different-head) merge_review "$home" PASS sonnet "$HEAD_B"; expected='route the independent review' ;;
      same-family) merge_review "$home" PASS gpt-5.1; expected='route the independent review' ;;
      escalation) merge_review "$home" PASS sonnet '' yes; expected='route the independent review' ;;
      pr-body) merge_review "$home" PASS sonnet '' no pr-body; expected='route the independent review' ;;
      owner-word) with_home "$home" "$ROOT/bin/fm-review-record.py" captain-word --pr "$url" --head "$head" --words 'Merge this head.' >/dev/null || fail 'arbitrary owner word failed'; expected='route the independent review' ;;
    esac
    if [ "$mode" = stale ]; then
      printf '1\n' > "$home/forge/behind"
      mutate_record "$home" "$task" '.records[0].verdict={head:.records[0].observation.head,actor:"fleet",source:"review",summary:"merge this head now"}'
      expected='update the branch; base is stale'
    fi
    merge_poll "$home"
    expect_merge_action "$home" "$expected"
    printf 'arbitrary owner %s %s: %s\n' "$task" "$mode" "$expected"
  done
  printf '0\n' > "$home/forge/behind"
  mutate_record "$home" "$task" '.records[0].verdict=null'
  mkdir -p "$home/data/arbitrary-peer"
  jq '.task="arbitrary-peer" | .records[].observation.review_verification.task="arbitrary-peer"' \
    "$home/data/$task/contributions.json" > "$home/data/arbitrary-peer/contributions.json"
  printf -- '- [ ] arbitrary-peer - Shared %s (repo: sample) (kind: ship)\n' "$url" >> "$home/data/backlog.md"
  for mode in qualified-not-qualified qualified-unavailable neither neither-unavailable; do
    printf 'worktree=%s/wt\nkind=ship\nmodel=sonnet\nmode=direct-PR\n' "$home" > "$home/state/arbitrary-peer.meta"
    case "$mode" in
      qualified-*) merge_review "$home" PASS; expected='merge under the standing merge rule' ;;
      neither) rm -f "$home/state/review-records.jsonl"; expected='route the independent review' ;;
      neither-unavailable) merge_review "$home" PASS gpt-5.1; expected='PASS fact unknown; recheck the independent review' ;;
    esac
    case "$mode" in *unavailable) printf 'worktree=%s/missing\nkind=ship\nmodel=sonnet\nmode=direct-PR\n' "$home" > "$home/state/arbitrary-peer.meta" ;; esac
    merge_poll "$home"
    expect_merge_action "$home" "$expected"
    merge_snapshot "$home" | jq -e '.known == 1 and .rows[0].tasks == ["arbitrary-peer","arbitrary-ship"]' >/dev/null || fail 'arbitrary shared row lost ownership'
    printf 'arbitrary shared %s: %s\n' "$mode" "$expected"
  done
  pass 'ordinary and shared review and stale-base ownership do not depend on URL or task identity'
}

test_shared_owner_real_reviews() {
  local home other mode expected owner
  for other in a-review z-review; do
    home=$(new_home "shared-real-$other")
    merge_home "$home"
    record "$home" "$other" 8 open mergeable
    for mode in qualified-not-qualified qualified-unavailable neither neither-unavailable; do
      printf 'worktree=%s/wt\nkind=ship\nmodel=sonnet\nmode=direct-PR\n' "$home" > "$home/state/$other.meta"
      case "$mode" in
        qualified-*) merge_review "$home" PASS; expected='merge under the standing merge rule' ;;
        neither) rm -f "$home/state/review-records.jsonl"; expected='route the independent review' ;;
        neither-unavailable) merge_review "$home" PASS gpt-5.1; expected='PASS fact unknown; recheck the independent review' ;;
      esac
      case "$mode" in
        *unavailable) printf 'worktree=%s/missing\nkind=ship\nmodel=sonnet\nmode=direct-PR\n' "$home" > "$home/state/$other.meta" ;;
      esac
      merge_poll "$home"
      expect_merge_action "$home" "$expected"
      merge_snapshot "$home" | jq -e '.known == 1 and (.rows[0].tasks | length) == 2' >/dev/null || fail 'real shared reviews duplicated the URL'
      printf 'real shared review %s %s: %s\n' "$other" "$mode" "$expected"
      for owner in delivery "$other"; do
        printf 'real shared verifier %s: %s\n' "$owner" "$(jq -c '.records[0].observation.review_verification.answer' "$home/data/$owner/contributions.json")"
      done
    done
  done
  pass 'real shared-owner verification combines qualified, not-qualified and unavailable answers in either owner order'
}

# Shared-owner precedence is a consumer-visible choice, not an ordering of tasks.
shared_fact() { # home task fact
  local home=$1 task=$2 fact=$3
  case "$fact" in
    hold) FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold "$task" --reason 'choose shared contract' ;;
    hold-missing|hold-old|hold-error)
      shared_fact "$home" "$task" hold
      shared_fact "$home" "$task" "${fact#hold-}" ;;
    fleet-other) mutate_record "$home" "$task" '.records[0].verdict={head:.records[0].observation.head,actor:"fleet",source:"review",summary:"another fleet action"}' ;;
    missing) rm "$home/data/$task/contributions.json" ;;
    old) mutate_record "$home" "$task" '.records[0].checked_at="2026-09-15T08:00:00Z"' ;;
    error) mutate_record "$home" "$task" '.records[0].error="saved transport failure"' ;;
    stale) mutate_record "$home" "$task" '.records[0].observation.base_containment.behind_by=1' ;;
    fleet|captain) mutate_record "$home" "$task" ".records[0].verdict={head:.records[0].observation.head,actor:\"$fact\",source:\"review\",summary:\"merge this head now\"}" ;;
    unknown-base) mutate_record "$home" "$task" 'del(.records[0].observation.base_containment)' ;;
    pass) mutate_record "$home" "$task" '.records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:true,basis:"independent-review",pr:.records[0].url,head:.records[0].observation.head}' ;;
    unknown-pass) mutate_record "$home" "$task" '.records[0].observation.review_verification=null' ;;
    none) : ;;
    *) fail "unknown shared fact: $fact" ;;
  esac
}

test_shared_owner_rule_pairs() {
  local home id left right expected number=300 swap task fact out actor reason pair hold_id actual_reason fleet_choice='' late_choice=''
  home=$(new_home shared-rule-pairs)
  : > "$home/expected.tsv"
  # Each pair puts only its two deciding facts on different owners.
  while IFS='|' read -r id left right expected; do
    for swap in 0 1; do
      pair="$id-$swap"
      hold_id=
      for task in a z; do
        record "$home" "$pair-$task" "$number" open mergeable
        mutate_record "$home" "$pair-$task" '.records[0].observation += {can_merge:true,base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base_containment:{behind_by:0}}
          | .records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified"}}}'
        if { [ "$swap" = 0 ] && [ "$task" = a ]; } || { [ "$swap" = 1 ] && [ "$task" = z ]; }; then fact=$left; else fact=$right; fi
        shared_fact "$home" "$pair-$task" "$fact"
        case "$fact" in hold*) hold_id="$pair-$task" ;; esac
      done
      case "$expected" in
        hold) actor=captain; reason='choose shared contract' ;;
        missing|old) actor=fleet; reason='contribution not recently checked' ;;
        error) actor=fleet; reason='saved transport failure' ;;
        stale) actor=fleet; reason='update the branch; base is stale' ;;
        fleet) actor=fleet; reason='merge this head now' ;;
        captain) actor=fleet; reason='record the unresolved arbitration as a captain hold' ;;
        fleet-other) actor=fleet; reason='another fleet action' ;;
        unknown-base) actor=fleet; reason='base freshness unknown; refresh the base comparison' ;;
        pass) actor=fleet; reason='merge under the standing merge rule' ;;
        unknown-pass) actor=fleet; reason='PASS fact unknown; recheck the independent review' ;;
        none) actor=fleet; reason='route the independent review' ;;
      esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$number" "$pair" "$actor" "$reason" "$hold_id" >> "$home/expected.tsv"
      number=$((number + 1))
    done
  done <<'PAIRS'
hold-late|hold|missing|hold
hold-stale|hold|stale|hold
hold-verdict|hold|fleet|hold
hold-base|hold|unknown-base|hold
hold-pass|hold|pass|hold
hold-unknown|hold|unknown-pass|hold
late-stale|missing|stale|missing
late-verdict|old|fleet|old
late-base|error|unknown-base|error
late-pass|missing|pass|missing
late-unknown|missing|unknown-pass|missing
stale-verdict|stale|fleet|stale
stale-base|stale|unknown-base|stale
stale-pass|stale|pass|stale
stale-unknown|stale|unknown-pass|stale
verdict-base|fleet|unknown-base|fleet
verdict-pass|fleet|pass|fleet
verdict-unknown|fleet|unknown-pass|fleet
base-pass|unknown-base|pass|unknown-base
base-unknown|unknown-base|unknown-pass|unknown-base
pass-unknown|pass|unknown-pass|pass
unknown-none|unknown-pass|none|unknown-pass
pass-none|pass|none|pass
none-none|none|none|none
captain-pass|captain|pass|captain
fleet-captain|fleet|captain|captain
stale-captain|stale|captain|stale
old-pass|old|pass|old
error-pass|error|pass|error
hold-old|hold|old|hold
hold-error|hold|error|hold
hold-own-missing|hold-missing|pass|hold
hold-own-old|hold-old|pass|hold
hold-own-error|hold-error|pass|hold
two-fleet|fleet|fleet-other|fleet-other
two-late|missing|error|missing
PAIRS
  out=$(merge_snapshot "$home") || fail 'shared rule-pair snapshot failed'
  while IFS="$(printf '\t')" read -r number id actor reason hold_id; do
    actual_reason=$(printf '%s' "$out" | jq -r --arg url "https://github.com/o/r/pull/$number" '.rows[] | select(.url == $url) | .reason')
    case "$id" in
      two-fleet-*)
        case "$actual_reason" in 'merge this head now'|'another fleet action') : ;; *) fail 'two fleet verdicts produced neither input summary' ;; esac
        [ -n "$fleet_choice" ] || fleet_choice=$actual_reason
        reason=$fleet_choice ;;
      two-late-*)
        case "$actual_reason" in 'contribution not recently checked'|'saved transport failure') : ;; *) fail 'two late owners produced neither input row' ;; esac
        [ -n "$late_choice" ] || late_choice=$actual_reason
        reason=$late_choice ;;
    esac
    printf '%s' "$out" | jq -e --arg url "https://github.com/o/r/pull/$number" --arg actor "$actor" --arg reason "$reason" --arg hold "$hold_id" '
      [.rows[] | select(.url == $url)] | length == 1 and .[0].actor == $actor and .[0].reason == $reason
      and (.[0].tasks | length) == 2 and (if $actor == "captain" then .[0].hold == $hold else true end)' >/dev/null \
      || fail "shared $id precedence differs: $(printf '%s' "$out" | jq -c --arg url "https://github.com/o/r/pull/$number" '.rows[] | select(.url == $url)')"
    printf 'shared pair %s: %s/%s\n' "$id" "$actor" "$reason"
  done < "$home/expected.tsv"
  # Current maintainer/nobody verdicts are inert over every verdict-free pair.
  local file baseline judged
  for file in "$home"/data/*/contributions.json; do
    jq 'del(.records[].verdict)' "$file" > "$home/rewrite.json" && mv "$home/rewrite.json" "$file"
  done
  baseline=$(merge_snapshot "$home" | jq -c '[.rows[] | {url,actor,reason}]') || fail 'verdict-free pair snapshot failed'
  for judged in maintainer nobody; do
    for file in "$home"/data/*/contributions.json; do
      jq --arg actor "$judged" '.records[].verdict={head:.records[0].observation.head,actor:$actor,source:"review",summary:"inert judgment"}' "$file" > "$home/rewrite.json" && mv "$home/rewrite.json" "$file"
    done
    out=$(merge_snapshot "$home" | jq -c '[.rows[] | {url,actor,reason}]') || fail 'inert verdict pair snapshot failed'
    assert_equals "$baseline" "$out" "current $judged verdict changed a shared verdict-free row"
  done
  pass 'every shared-owner rule pair is independent of owner task order; maintainer and nobody verdicts are inert'
}

test_merge_preserved_cross_factors() {
  local home lane fact id number=100 actor reason mutation out expected=
  home=$(new_home merge-cross-factors)
  for lane in review-required cannot-merge away; do
    case "$lane" in
      review-required) actor=maintainer; reason='review required'; mutation='.records[0].observation.review_decision="REVIEW_REQUIRED"' ;;
      cannot-merge) actor=maintainer; reason='delivery awaits the maintainer'; mutation='.records[0].observation.can_merge=false' ;;
      away) actor=fleet; reason='checks green; merge is authorized by delivery posture'; mutation='.' ;;
    esac
    for fact in stale unknown no-pass pass pass-unknown; do
      id="$lane-$fact"
      record "$home" "$id" "$number" open mergeable
      number=$((number + 1))
      mutate_record "$home" "$id" '.records[0].observation += {can_merge:true,base_containment:{behind_by:0},base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
        | .records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:true,basis:"independent-review",pr:.records[0].url,head:.records[0].observation.head}}'
      mutate_record "$home" "$id" "$mutation"
      case "$fact" in
        stale) mutate_record "$home" "$id" '.records[0].observation.base_containment.behind_by=1' ;;
        unknown) mutate_record "$home" "$id" 'del(.records[0].observation.base_containment)' ;;
        no-pass) mutate_record "$home" "$id" '.records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified"}}' ;;
        pass-unknown) mutate_record "$home" "$id" '.records[0].observation.review_verification=null' ;;
      esac
      expected="${expected}${id}|${actor}|${reason}
"
    done
  done
  while IFS='|' read -r id reason mutation; do
    record "$home" "$id" "$number" open mergeable
    number=$((number + 1))
    mutate_record "$home" "$id" '.records[0].observation += {can_merge:true,base_containment:{behind_by:1}}
      | .records[0].verdict={head:.records[0].observation.head,actor:"captain",source:"review",summary:"choose"}'
    mutate_record "$home" "$id" "$mutation"
    expected="${expected}${id}|fleet|${reason}
"
  done <<'CAPTAIN'
captain-failed|checks failed|.records[0].observation.checks[0].conclusion="failure"
captain-changes|forge requests changes|.records[0].observation.review_decision="CHANGES_REQUESTED"
captain-signal|incoming maintainer signal needs triage|.records[0].pending=[{token:"comment:1"}]
captain-draft|draft delivery|.records[0].observation.draft=true
captain-conflict|mergeability conflicting|.records[0].observation.mergeable="conflicting"
captain-stale-base|update the branch; base is stale|.
captain-old-observation|contribution not recently checked|.records[0].checked_at="2026-09-15T08:00:00Z"
captain-old-head|STALE maintainer verdict; reassess the current head|.records[0].verdict.head="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CAPTAIN
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.raw.json" || fail 'cross-factor input failed'
  jq '.tasks += [.backlog.records[] | select(.id | startswith("away-")) | {id:.id,kind:"ship",merge_authority:"away",pr:{url:.links[0],head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' \
    "$home/input.raw.json" > "$home/input.json" || fail 'away input fixture failed'
  out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'cross-factor snapshot failed'
  while IFS='|' read -r id actor reason; do
    [ -n "$id" ] || continue
    printf '%s' "$out" | jq -e --arg id "$id" --arg actor "$actor" --arg reason "$reason" '
      [.rows[] | select(.task == $id) | [.actor,.reason]] == [[$actor,$reason]]' >/dev/null \
      || fail "cross-factor precedence changed for $id: $out"
  done <<EXPECTED
$expected
EXPECTED
  printf '%s' "$out" | jq -e '.counts.captain == 0 and .captain == [] and (.proven_clear | not)' >/dev/null \
    || fail 'a non-hold cross-factor row became an owner call'
  printf '%s' "$out" | jq -r '.rows[] | [.task,.actor,.reason] | @tsv'
  pass 'excluded rows preserve prior actors and reasons across base and PASS facts; captain verdicts never mask checks or forge decisions'
}

test_recorded_verdict_cross_factors() {
  local home judged state id number=200 actor reason out expected=
  home=$(new_home recorded-verdict-cross)
  for judged in maintainer nobody; do
    for state in fresh stale unknown review-required cannot-merge away; do
      id="$judged-$state"
      record "$home" "$id" "$number" open mergeable
      number=$((number + 1))
      mutate_record "$home" "$id" '.records[0].observation += {can_merge:true,base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base_containment:{behind_by:0}}
        | .records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified"}}}'
      mutate_record "$home" "$id" ".records[0].verdict={head:.records[0].observation.head,actor:\"$judged\",source:\"review\",summary:\"recorded judgment\"}"
      actor=fleet
      case "$state" in
        fresh) reason='route the independent review' ;;
        stale) reason='update the branch; base is stale'; mutate_record "$home" "$id" '.records[0].observation.base_containment.behind_by=1' ;;
        unknown) reason='base freshness unknown; refresh the base comparison'; mutate_record "$home" "$id" 'del(.records[0].observation.base_containment)' ;;
        review-required) actor=maintainer; reason='review required'; mutate_record "$home" "$id" '.records[0].observation.review_decision="REVIEW_REQUIRED"' ;;
        cannot-merge) actor=maintainer; reason='delivery awaits the maintainer'; mutate_record "$home" "$id" '.records[0].observation.can_merge=false' ;;
        away) reason='checks green; merge is authorized by delivery posture' ;;
      esac
      expected="${expected}${id}|${actor}|${reason}
"
    done
  done
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.raw.json" || fail 'verdict input failed'
  jq '.tasks += [.backlog.records[] | select(.id | endswith("-away")) | {id:.id,kind:"ship",merge_authority:"away",pr:{url:.links[0],head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}]' \
    "$home/input.raw.json" > "$home/input.json" || fail 'away verdict fixture failed'
  out=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || fail 'verdict cross-factor snapshot failed'
  while IFS='|' read -r id actor reason; do
    [ -n "$id" ] || continue
    printf '%s' "$out" | jq -e --arg id "$id" --arg actor "$actor" --arg reason "$reason" '
      [.rows[] | select(.task == $id) | [.actor,.reason]] == [[$actor,$reason]]' >/dev/null \
      || fail "recorded $id verdict overrode its observed row: $out"
  done <<EXPECTED
$expected
EXPECTED
  printf '%s' "$out" | jq -r '.rows[] | [.task,.actor,.reason] | @tsv'
  pass 'maintainer and nobody verdicts do not override fresh, stale, unknown, review-required, cannot-merge or away rows'
}

# Regression coverage, not a counted K7 run against Main's sealed input table.
test_merge_precedence_matrix() {
  local home id number=20 actor reason mutation out expected
  home=$(new_home merge-matrix)
  : > "$home/expected.tsv"
  while IFS='|' read -r id actor reason mutation; do
    record "$home" "$id" "$number" open mergeable
    mutate_record "$home" "$id" '.records[0].observation += {can_merge:true,base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base_containment:{behind_by:0}}'
    mutate_record "$home" "$id" '.records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:true,basis:"independent-review",pr:.records[0].url,head:.records[0].observation.head,at:1,reader_model:"sonnet",reader_family:"anthropic",author_groups:{ship:[{model:"gpt-5.1",family:"openai"}]}}}'
    mutate_record "$home" "$id" "$mutation"
    printf '%s\t%s\t%s\n' "$id" "$actor" "$reason" >> "$home/expected.tsv"
    number=$((number + 1))
  done <<'CASES'
no-review|fleet|route the independent review|.records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}}}
base-unknown|fleet|base freshness unknown; refresh the base comparison|del(.records[0].observation.base_containment)
base-stale|fleet|update the branch; base is stale|.records[0].observation.base_containment.behind_by=1 | .records[0].observation.review_verification=null
base-stale-pass|fleet|update the branch; base is stale|.records[0].observation.base_containment.behind_by=1
qualified|fleet|merge under the standing merge rule|.
pass-unknown|fleet|PASS fact unknown; recheck the independent review|.records[0].observation.review_verification=null
verdict-stale-base|fleet|update the branch; base is stale|.records[0].observation.base_containment.behind_by=1 | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"fleet",summary:"merge this head now"}
verdict-fresh-base|fleet|merge this head now|.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"fleet",summary:"merge this head now"}
verdict-unknown-base|fleet|merge this head now|del(.records[0].observation.base_containment) | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"fleet",summary:"merge this head now"}
verdict-captain|fleet|record the unresolved arbitration as a captain hold|.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"captain",summary:"choose"}
verdict-captain-stale|fleet|update the branch; base is stale|.records[0].observation.base_containment.behind_by=1 | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"captain",summary:"choose"}
verdict-maintainer|fleet|merge under the standing merge rule|.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"maintainer",summary:"awaiting maintainer"}
verdict-maintainer-no-pass|fleet|route the independent review|.records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}} | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"maintainer",summary:"awaiting maintainer"}
verdict-maintainer-stale-base|fleet|update the branch; base is stale|.records[0].observation.base_containment.behind_by=1 | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"maintainer",summary:"awaiting maintainer"}
verdict-nobody|fleet|merge under the standing merge rule|.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"nobody",summary:"no action"}
verdict-nobody-no-pass|fleet|route the independent review|.records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}} | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"nobody",summary:"no action"}
verdict-nobody-stale-base|fleet|update the branch; base is stale|.records[0].observation.base_containment.behind_by=1 | .records[0].verdict={head:.records[0].observation.head,source:"review",actor:"nobody",summary:"no action"}
review-required-stale-base|maintainer|review required|.records[0].observation.review_decision="REVIEW_REQUIRED" | .records[0].observation.base_containment.behind_by=1
review-required-no-pass|maintainer|review required|.records[0].observation.review_decision="REVIEW_REQUIRED" | .records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}}
review-required-pass|maintainer|review required|.records[0].observation.review_decision="REVIEW_REQUIRED"
review-required-unknown|maintainer|review required|.records[0].observation.review_decision="REVIEW_REQUIRED" | .records[0].observation.review_verification=null
cannot-merge-stale-base|maintainer|delivery awaits the maintainer|.records[0].observation.can_merge=false | .records[0].observation.base_containment.behind_by=1
cannot-merge-no-pass|maintainer|delivery awaits the maintainer|.records[0].observation.can_merge=false | .records[0].observation.review_verification.answer={schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}}
cannot-merge-pass|maintainer|delivery awaits the maintainer|.records[0].observation.can_merge=false
cannot-merge-unknown|maintainer|delivery awaits the maintainer|.records[0].observation.can_merge=false | .records[0].observation.review_verification=null
changes|fleet|forge requests changes|.records[0].observation.review_decision="CHANGES_REQUESTED"
failed|fleet|checks failed|.records[0].observation.checks[0].conclusion="failure"
missing|fleet|check lane has no verdict|.records[0].observation.checks[0].conclusion=null
pending|fleet|checks still running|.records[0].observation.checks[0].status="in_progress"
no-checks|fleet|no reported checks; readiness unconfirmed|.records[0].observation.checks=[]
draft|fleet|draft delivery|.records[0].observation.draft=true
conflict|fleet|mergeability conflicting|.records[0].observation.mergeable="conflicting"
merged|nobody|forge reports merged|.records[0].observation.state="merged"
closed|nobody|forge reports closed|.records[0].observation.state="closed"
stale-observation|fleet|contribution not recently checked|.records[0].checked_at="2026-09-15T08:00:00Z"
stale-verdict|fleet|STALE maintainer verdict; reassess the current head|.records[0].verdict={head:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",source:"review",actor:"fleet",summary:"old"}
signal|fleet|incoming maintainer signal needs triage|.records[0].pending=[{token:"comment:1"}]
issue|maintainer|awaiting issue triage|.records[0].kind="issue" | .records[0].observation.ready=false
CASES
  record "$home" live-hold "$number" open mergeable
  FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$home" hold live-hold --reason 'choose scope'
  printf 'live-hold\tcaptain\tchoose scope\n' >> "$home/expected.tsv"
  out=$(merge_snapshot "$home") || fail 'precedence snapshot failed'
  assert_current_inert_verdicts "$home" "$home/input.json" "$out"
  while IFS="$(printf '\t')" read -r id actor reason; do
    printf '%s' "$out" | jq -e --arg task "$id" --arg actor "$actor" --arg reason "$reason" '
      .rows[] | select(.task == $task) | .actor == $actor and .reason == $reason' >/dev/null \
      || fail "precedence changed for $id: $out"
  done < "$home/expected.tsv"
  printf '%s' "$out" | jq -r '.rows[] | [.task,.actor,.reason] | @tsv'
  expected=$(jq -Rs 'split("\n") | map(select(length > 0) | split("\t") | {task:.[0],actor:.[1]})
    | {known:length,counts:{captain:(map(select(.actor == "captain")) | length),
        fleet:(map(select(.actor == "fleet")) | length),maintainer:(map(select(.actor == "maintainer")) | length),
        nobody:(map(select(.actor == "nobody")) | length)},captain:(map(select(.actor == "captain") | .task) | sort)}' "$home/expected.tsv")
  printf '%s' "$out" | jq -e --argjson expected "$expected" '
    .known == $expected.known and .counts == $expected.counts
    and ([.captain[].task] | sort) == $expected.captain
    and all(.rows[]; if .actor == "captain" then .hold != null else true end)' >/dev/null \
    || fail "snapshot counts differ from the fixture table: $out"
  bearings "$home" | jq -e --argjson expected "$expected" '
    .contributions | .known == $expected.known and .counts == $expected.counts
    and ([.captain[].task] | sort) == $expected.captain
    and all(.captain[]; .hold != null)' >/dev/null \
    || fail 'Bearings counts or captain list differ from the live-hold fixture table'
  printf 'fixture summary: %s\n' "$expected"
  pass 'classifier branch precedence keeps ordinary actions distinct; only live holds are owner calls'
}

K7_BASE40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
K7_GREEN='.records[0].observation += {can_merge:true,base_sha:"'$K7_BASE40'",base_containment:{behind_by:0}}'
K7_PASSQ='.records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:true,basis:"independent-review",pr:.records[0].url,head:.records[0].observation.head,at:1,reader_model:"sonnet",reader_family:"anthropic",author_groups:{ship:[{model:"gpt-5.1",family:"openai"}]}}}'
K7_NOTQ='.records[0].observation.review_verification={pr:.records[0].url,head:.records[0].observation.head,task:.task,base:.records[0].observation.base_sha,answer:{schema:"fm-review-verification.v1",ok:false,error:{kind:"not-qualified",message:"absent"}}}'

k7_note_input() { # inputs-file case key value: the recorded input value a case expects as its reason
  jq --arg c "$2" --arg k "$3" --arg v "$4" '.[$c] = ((.[$c] // {}) + {($k):$v})' "$1" > "$1.new" && mv "$1.new" "$1"
}

k7_green_base() { # home id number [extra jq mutation after the green fresh-base, no-PASS base]
  record "$1" "$2" "$3" open mergeable
  mutate_record "$1" "$2" "$K7_GREEN"
  mutate_record "$1" "$2" "$K7_NOTQ"
  [ -z "${4:-}" ] || mutate_record "$1" "$2" "$4"
}

k7_hold() { # home id reason: a real live hold through the real hold command
  FM_CAPTAIN_HOLD_NOW="$NOW" contribution_hold "$1" hold "$2" --reason "$3"
}

k7_verdict() { # actor summary
  printf '.records[0].verdict={head:.records[0].observation.head,source:"review",actor:"%s",summary:"%s"}' "$1" "$2"
}
k7_build_section_a() { # home inputs-file
  local home=$1 inputs=$2 n=100
  # A01 unsupported forge
  printf -- '- [ ] a01 - Filed https://gitlab.com/o/r/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  n=$((n+1)); record "$home" a02 $n merged mergeable
  n=$((n+1)); record "$home" a03 $n closed mergeable
  n=$((n+1)); record "$home" a04 $n merged mergeable
  mutate_record "$home" a04 '.records[0].error="K7 recorded error A04"'
  n=$((n+1)); k7_green_base "$home" a05 $n; k7_hold "$home" a05 'K7 hold reason A05'; k7_note_input "$inputs" A05 reason 'K7 hold reason A05'; k7_note_input "$inputs" A05 hold_id a05
  n=$((n+1)); k7_green_base "$home" a06 $n '.records[0].error="K7 recorded error A06"'; k7_note_input "$inputs" A06 reason 'K7 recorded error A06'
  n=$((n+1)); k7_green_base "$home" a07 $n '.records[0].checked_at="2026-09-15T08:00:00Z"'
  n=$((n+1)); k7_green_base "$home" a08 $n '.records[0].verdict={head:"'"$K7_BASE40"'",source:"review",actor:"fleet",summary:"old verdict"}'
  n=$((n+1)); k7_green_base "$home" a09 $n '.records[0].pending=[{token:"comment:1"}]'
  n=$((n+1)); k7_green_base "$home" a10 $n '.records[0].kind="issue" | .records[0].observation.ready=true'
  n=$((n+1)); k7_green_base "$home" a11 $n '.records[0].kind="issue" | .records[0].observation.ready=false'
  n=$((n+1)); k7_green_base "$home" a12 $n '.records[0].observation.draft=true'
  n=$((n+1)); k7_green_base "$home" a13 $n '.records[0].observation.mergeable="conflicting"'
  n=$((n+1)); k7_green_base "$home" a14 $n '.records[0].observation.mergeable="unknown"'
  n=$((n+1)); k7_green_base "$home" a15 $n '.records[0].observation.checks[0].conclusion="failure"'
  n=$((n+1)); k7_green_base "$home" a16 $n '.records[0].observation.checks[0].conclusion=null'
  n=$((n+1)); k7_green_base "$home" a17 $n '.records[0].observation.absent_checks=["required-extra"]'
  n=$((n+1)); k7_green_base "$home" a18 $n '.records[0].observation.checks=[]'
  n=$((n+1)); k7_green_base "$home" a19 $n '.records[0].observation.checks[0].status="in_progress"'
  n=$((n+1)); k7_green_base "$home" a20 $n '.records[0].observation.review_decision="CHANGES_REQUESTED"'
  n=$((n+1)); k7_green_base "$home" a21 $n "$(k7_verdict fleet 'K7 merge this head now A21')"; k7_note_input "$inputs" A21 reason 'K7 merge this head now A21'
  n=$((n+1)); k7_green_base "$home" a22 $n "$(k7_verdict captain 'K7 choose A22')"
  n=$((n+1)); k7_green_base "$home" a23 $n "$(k7_verdict maintainer 'K7 awaiting maintainer A23')"
  n=$((n+1)); k7_green_base "$home" a24 $n "$(k7_verdict nobody 'K7 no action A24')"
  n=$((n+1)); k7_green_base "$home" a25 $n '.records[0].observation.review_decision="REVIEW_REQUIRED"'
  n=$((n+1)); k7_green_base "$home" a26 $n
  printf 'kind=ship\npr=https://github.com/o/r/pull/%s\npr_head=%s\n' "$n" "$HEAD_A" > "$home/state/a26.meta"; chmod 600 "$home/state/a26.meta"
  n=$((n+1)); k7_green_base "$home" a27 $n '.records[0].observation.can_merge=false'
  n=$((n+1)); k7_green_base "$home" a28 $n "$K7_PASSQ"
  n=$((n+1)); k7_green_base "$home" a29 $n
  n=$((n+1)); k7_green_base "$home" a30 $n '.records[0].observation.base_containment.behind_by=1'
  n=$((n+1)); k7_green_base "$home" a31 $n 'del(.records[0].observation.base_containment)'
  n=$((n+1)); k7_green_base "$home" a32 $n '.records[0].observation.review_verification=null'
  n=$((n+1)); k7_green_base "$home" a33 $n "$K7_PASSQ"; k7_hold "$home" a33 'K7 hold reason A33'; k7_note_input "$inputs" A33 reason 'K7 hold reason A33'; k7_note_input "$inputs" A33 hold_id a33
  n=$((n+1)); record "$home" a34 $n merged mergeable; k7_hold "$home" a34 'K7 hold reason A34'
  n=$((n+1)); record "$home" a35 $n open mergeable; printf 'incomplete JSON' > "$home/data/a35/contributions.json"
  n=$((n+1)); record "$home" a36 $n open mergeable; printf '{"schema":"fm-contributions.v1","task":"a36","records":[{"url":"not-a-url","kind":"pr"}]}\n' > "$home/data/a36/contributions.json"
  mkdir -p "$home/data/a37"; printf 'incomplete JSON' > "$home/data/a37/contributions.json"
}


# Second fixture. Rows: 1 draft PR, 2 merged PR, 3 REVIEW_REQUIRED PR (variants alter row 3 or add a hold).
k7_build_b() { # home inputs-file variant(base|i|ii|iii|iv|v)
  local home=$1 inputs=$2 v=$3
  record "$home" b1 201 open mergeable; mutate_record "$home" b1 "$K7_GREEN"; mutate_record "$home" b1 "$K7_NOTQ"; mutate_record "$home" b1 '.records[0].observation.draft=true'
  record "$home" b2 202 merged mergeable
  case "$v" in
    base|i|ii)
      record "$home" b3 203 open mergeable; mutate_record "$home" b3 "$K7_GREEN"; mutate_record "$home" b3 "$K7_NOTQ"
      mutate_record "$home" b3 '.records[0].observation.review_decision="REVIEW_REQUIRED"'
      [ "$v" != i ] || { k7_hold "$home" b3 'K7 hold reason B(i)'; k7_note_input "$inputs" Bi-3 reason 'K7 hold reason B(i)'; }
      [ "$v" != ii ] || k7_hold "$home" b2 'K7 hold reason B(ii)' ;;
    iii)
      record "$home" b3 203 open mergeable; mutate_record "$home" b3 "$K7_GREEN"; mutate_record "$home" b3 "$K7_NOTQ"
      mutate_record "$home" b3 '.records[0].checked_at="2026-09-15T08:00:00Z"' ;;
    iv) printf -- '- [ ] b3 - Filed https://gitlab.com/o/r/-/merge_requests/3 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md" ;;
    v)
      mkdir -p "$home/data/b3"; printf 'incomplete JSON' > "$home/data/b3/contributions.json"
      printf 'kind=ship\npr=https://github.com/o/r/pull/203\n' > "$home/state/b3.meta"; chmod 600 "$home/state/b3.meta" ;;
  esac
}

k7_snapshot() { # home
  local home=$1 before after full summary file calls_before calls_after
  mkdir -p "$home/forge"
  with_home "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" || return 1
  if [ -n "${K7_AWAY_TASK:-}" ]; then
    jq --arg t "$K7_AWAY_TASK" '.tasks = ((.tasks // []) | map(if .id == $t then . + {merge_authority:"away"} else . end))' "$home/input.json" > "$home/input.patched.json" && mv "$home/input.patched.json" "$home/input.json"
    printf 'canonical input tasks[] entries for %s: %s\n' "$K7_AWAY_TASK" "$(jq --arg t "$K7_AWAY_TASK" '[.tasks[]? | select(.id == $t)] | length' "$home/input.json")" >> "$K7_OUT/notes.txt"
  fi
  before=$(for file in "$home"/data/*/contributions.json; do [ ! -f "$file" ] || shasum -a 256 "$file"; done)
  calls_before=$(cat "$home/forge/shim.log" "$home/forge/review-calls" 2>/dev/null || true)
  full=$(with_home "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all) || return 1
  after=$(for file in "$home"/data/*/contributions.json; do [ ! -f "$file" ] || shasum -a 256 "$file"; done)
  calls_after=$(cat "$home/forge/shim.log" "$home/forge/review-calls" 2>/dev/null || true)
  [ "$before" = "$after" ] || { echo 'snapshot changed saved bytes' >&2; return 1; }
  [ "$calls_before" = "$calls_after" ] || { echo 'snapshot made forge or verifier calls' >&2; return 1; }
  printf '%s\n' "$full"
}

k7_observe() { # name home
  local name=$1 home=$2 all bear
  all=$(k7_snapshot "$home") || fail "K7 snapshot failed: $name"
  bear=$(bearings "$home") || fail "K7 bearings failed: $name"
  jq -n --argjson all "$all" --argjson bear "$bear" '{all:$all,bearings:$bear.contributions}' > "$K7_OUT/observed-$name.json"
}

k7_observe_a26_real() {
  local home
  home=$(new_home k7-a26-real)
  forge_home "$home"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null || fail 'K7 away home setup failed'
  printf 'yolo=on\n' >> "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-afk-contract.sh" enter --words 'merge the delivery PR when green' >/dev/null || fail 'K7 away posture failed'
  mutate_record "$home" delivery "$K7_GREEN"
  mutate_record "$home" delivery "$K7_NOTQ"
  # bin/fm-bearings-snapshot.sh refuses ordinary reads while away mode is active, so only the contribution snapshot is read.
  k7_snapshot "$home" | jq '{all:.,bearings:null}' > "$K7_OUT/observed-A26real.json"
}

# K7: the fixtures of the contract's Verify (5) and (7) (section A and the second fixture with its five variants),
# each in its own disposable home through the real hold command, canonical input, snapshot --all and Bearings.
# The comparison table is Main-owned and independent of this change: when FM_K7_EXPECTED_TABLE and FM_K7_R1_TABLE
# name its read-only copies, every observed row and summary value must equal the table; this test never writes it.
# Without them only the table-independent invariants run, and the output says so.
test_k7_fixture_table() {
  local home variant rows
  K7_OUT=${FM_K7_OUT:-$TMP_ROOT/k7-out}
  rm -rf "$K7_OUT"; mkdir -p "$K7_OUT"
  printf '{}\n' > "$K7_OUT/recorded-inputs.json"
  for variant in base i ii iii iv v; do
    home=$(new_home "k7-b-$variant"); k7_build_b "$home" "$K7_OUT/recorded-inputs.json" "$variant"
    k7_observe "B$variant" "$home"
  done
  home=$(new_home k7-a); k7_build_section_a "$home" "$K7_OUT/recorded-inputs.json"
  K7_AWAY_TASK=a26 k7_observe A "$home"
  k7_observe_a26_real
  # Table-independent invariants: a live hold is the only owner call, nothing carries the former reason, coverage adds up.
  jq -e '.all as $a | .all.rows | all(.[]; .reason != "checks green; merge approval needed")
    and ($a.known == 36 and $a.unreadable_records == 3 and ($a.counts | add) + $a.unmeasured == $a.known)
    and ([$a.captain[].task] | sort) == ["a05","a33"]' "$K7_OUT/observed-A.json" >/dev/null \
    || fail 'K7 section A coverage or owner calls are wrong'
  for variant in base ii iii iv v; do
    jq -e '.all.known == 3 and .all.counts.captain == 0 and .all.captain == []' "$K7_OUT/observed-B$variant.json" >/dev/null \
      || fail "K7 second fixture variant $variant produced an owner call or a wrong row count"
  done
  jq -e '.all.known == 3 and ([.all.captain[].task] == ["b3"]) and (.all.proven_clear | not)' "$K7_OUT/observed-Bi.json" >/dev/null \
    || fail 'K7 variant (i): the live hold on the REVIEW_REQUIRED row must be the only owner call'
  if [ -n "${FM_K7_EXPECTED_TABLE:-}" ] && [ -n "${FM_K7_R1_TABLE:-}" ]; then
    printf 'K7 table sha256: %s\nR1 table sha256: %s\n' "$(shasum -a 256 "$FM_K7_EXPECTED_TABLE" | cut -d' ' -f1)" "$(shasum -a 256 "$FM_K7_R1_TABLE" | cut -d' ' -f1)"
    python3 - "$FM_K7_EXPECTED_TABLE" "$FM_K7_R1_TABLE" "$K7_OUT" <<'PY' || fail 'K7 rows differ from the Main-owned table'
"""Compare K7 observed rows with the Main-owned expected table (read-only input).

Usage: EXPECTED_TABLE R1_TABLE OUT_DIR
Reads OUT_DIR/observed-{A,A26real,Bbase,Bi,Bii,Biii,Biv,Bv}.json and OUT_DIR/recorded-inputs.json.
The expected table is only read; nothing is derived from observed output.
"""
import hashlib, json, re, sys
from pathlib import Path

table_path, r1_path, out = sys.argv[1], sys.argv[2], Path(sys.argv[3])
table = Path(table_path).read_text()
r1 = Path(r1_path).read_text()
inputs = json.loads((out / 'recorded-inputs.json').read_text())

# R1 reason strings by outcome name.
r1_map = {}
for line in r1.splitlines():
    cells = [c.strip() for c in line.strip().strip('|').split('|')]
    if len(cells) == 3 and cells[1] == 'fleet':
        r1_map[cells[0]] = cells[2]
outcome_names = {
    'route-review': 'No qualifying PASS', 'update-branch': 'Base stale', 'merge': 'Qualifying PASS',
    'PASS-unknown': 'PASS fact unknown', 'base-unknown': 'Base freshness unknown'}

def rows_of(prefix_re):
    rows = []
    for line in table.splitlines():
        if re.match(r'^\|\s*' + prefix_re + r'\s*\|', line):
            cells = [c.strip() for c in line.strip().strip('|').split(' | ')]
            rows.append(cells)
    return rows

def expected_reason(case, cell):
    m = re.match(r'^outcome ([A-Za-z-]+): (.*)$', cell)
    if m:
        name, text = m.group(1), m.group(2)
        assert r1_map[outcome_names[name]] == text, f'{case}: table string differs from the R1 table for {name}'
        return text
    if cell.startswith('arbitrary input') or cell.startswith('conditional'):
        return ('INPUT', case)
    return cell

failures = []
report = []

def check_group(name, expect_rows, observed, task_of, input_reason=None, special=None):
    """expect_rows: list of (case, actor, reason cell, checked cell)."""
    by_task = {r['task']: r for r in observed['all']['rows']}
    for case, actor, reason_cell, checked in expect_rows:
        task = task_of(case)
        if actor == 'no row' or task is None:
            ok = task not in by_task
            report.append((name, case, 'no row', '' if ok else 'ROW PRESENT', 'PASS' if ok else 'FAIL'))
            if not ok: failures.append(f'{name} {case}: expected no row')
            continue
        row = by_task.get(task)
        if row is None:
            failures.append(f'{name} {case}: row missing'); report.append((name, case, '-', '-', 'FAIL')); continue
        exp = expected_reason(case, reason_cell)
        if isinstance(exp, tuple):
            exp = inputs.get(case, {}).get('reason')
            if exp is None and special is not None:
                exp = special(case)
        ok = row['actor'] == actor and row['reason'] == exp and bool(row['checked']) == (checked == 'yes')
        report.append((name, case, f"{row['actor']}/{row['reason']} checked={row['checked']}",
                       f'expected {actor}/{exp} checked={checked}', 'PASS' if ok else 'FAIL'))
        if not ok: failures.append(f'{name} {case}: observed {row["actor"]}/{row["reason"]}/{row["checked"]} expected {actor}/{exp}/{checked}')

def summarize(rows):
    """CONTEXT 26 summary from table rows: (case, actor, checked, adds_row, unreadable)."""
    counts = {'captain': 0, 'fleet': 0, 'maintainer': 0, 'nobody': 0}
    known = checked = unmeasured = unreadable = 0
    captain_cases = []
    for case, actor, chk, adds, unread in rows:
        unreadable += int(unread)
        if adds == '1':
            known += 1
            if actor == 'unmeasured': unmeasured += 1
            else: counts[actor] += 1
            if chk == 'yes': checked += 1
            if actor == 'captain': captain_cases.append(case)
    complete = unreadable == 0 and checked == known
    return dict(known=known, counts=counts, unmeasured=unmeasured, checked=checked, unreadable=unreadable,
                complete=complete, proven_clear=complete and not counts['captain'], captain_cases=captain_cases)

def block(label):
    m = re.search(r'```' + label + r'\n(.*?)```', table, re.S)
    return [l.split('|') for l in m.group(1).strip().splitlines()]

def compare_summary(name, exp, observed, task_of):
    a, b = observed['all'], observed['bearings']
    cap_tasks = sorted(task_of(c) for c in exp['captain_cases'])
    pairs = [
        ('all.known', a['known'], exp['known']), ('all.checked', a['checked'], exp['checked']),
        ('all.counts', a['counts'], exp['counts']), ('all.unmeasured', a['unmeasured'], exp['unmeasured']),
        ('all.unreadable_records', a['unreadable_records'], exp['unreadable']),
        ('all.complete', a['complete'], exp['complete']), ('all.proven_clear', a['proven_clear'], exp['proven_clear']),
        ('all.captain list', sorted(r['task'] for r in a['captain']), cap_tasks),
        ('bearings.known', b['known'], exp['known']), ('bearings.checked', b['checked'], exp['checked']),
        ('bearings.counts', b['counts'], exp['counts']), ('bearings.unmeasured', b['unmeasured'], exp['unmeasured']),
        ('bearings.unreadable_records', b.get('unreadable_records'), exp['unreadable']),
        ('bearings.complete', b['complete'], exp['complete']), ('bearings.proven_clear', b['proven_clear'], exp['proven_clear']),
        ('bearings.captain list', sorted(r['task'] for r in b['captain']), cap_tasks)]
    for label, got, want in pairs:
        ok = got == want
        report.append((name, 'summary ' + label, json.dumps(got), json.dumps(want), 'PASS' if ok else 'FAIL'))
        if not ok: failures.append(f'{name} summary {label}: observed {got} expected {want}')

# ---- Section A
task_a = lambda case: 'a' + case[1:].lower() if False else case.lower()
a_rows = [(c[0], c[2], c[3], c[4]) for c in rows_of(r'A\d\d')]
a_obs = json.loads((out / 'observed-A.json').read_text())
check_group('A', a_rows, a_obs, lambda c: c.lower())
a_block = [[x.strip() for x in l] for l in block('rows-A')]
exp_a = summarize([(r[0], r[1], r[2], r[3], r[4]) for r in a_block])
# the stated literal values of the table must equal what CONTEXT 26 computes from its rows
stated = {m.group(1): int(m.group(2)) for m in re.finditer(r'^- (counts\.captain|counts\.fleet|counts\.maintainer|counts\.nobody|unmeasured|unreadable count) = (\d+)', table, re.M)}
for key, want in (('counts.captain', exp_a['counts']['captain']), ('counts.fleet', exp_a['counts']['fleet']),
                  ('counts.maintainer', exp_a['counts']['maintainer']), ('counts.nobody', exp_a['counts']['nobody']),
                  ('unmeasured', exp_a['unmeasured']), ('unreadable count', exp_a['unreadable'])):
    if stated.get(key) != want:
        failures.append(f'table stated {key}={stated.get(key)} but its rows give {want}')
compare_summary('A', exp_a, a_obs, lambda c: c.lower())

# the real away record for A26
real = json.loads((out / 'observed-A26real.json').read_text())
row = real['all']['rows'][0]
ok = row['actor'] == 'fleet' and row['reason'] == 'checks green; merge is authorized by delivery posture'
report.append(('A26real', 'A26 on a real away record', f"{row['actor']}/{row['reason']}", 'fleet/checks green; merge is authorized by delivery posture', 'PASS' if ok else 'FAIL'))
if not ok: failures.append('A26 real away row differs')

# ---- Section B
b_names = {'base': ('B0', 'rows-B0'), 'i': ('Bi', 'rows-Bi'), 'ii': ('Bii', 'rows-Bii'), 'iii': ('Biii', 'rows-Biii'), 'iv': ('Biv', 'rows-Biv'), 'v': ('Bv', 'rows-Bv')}
for variant, (pfx, blk) in b_names.items():
    obs = json.loads((out / f'observed-B{variant}.json').read_text())
    exp_rows = [(c[0], c[2], c[3], c[4]) for c in rows_of(re.escape(pfx) + r'-\d')]
    def task_of(case): return 'b' + case.split('-')[1]
    def special(case):
        # B(iii) row 3: the fixture records no error, so the table's conditional reason is the not-recently-checked text
        return 'contribution not recently checked'
    check_group('B' + variant, exp_rows, obs, task_of, special=special)
    brows = [[x.strip() for x in l] for l in block(blk)]
    exp = summarize([(r[0], r[1], r[2], r[3], r[4]) for r in brows])
    # stated Summary line of the table for this variant
    m = re.search(r'###\s+B(?:\(' + re.escape(variant) + r'\)|0 base fixture)[^\n]*\n.*?Summary: ([^\n]+)', table, re.S)
    compare_summary('B' + variant, exp, obs, task_of)

report_lines = ['| group | case | observed | expected | verdict |', '| --- | --- | --- | --- | --- |']
for g, c, o, e, v in report:
    report_lines.append(f'| {g} | {c} | {o} | {e} | {v} |')
(out / 'k7-comparison.md').write_text('\n'.join(report_lines) + '\n')
(out / 'k7-comparison.json').write_text(json.dumps({'failures': failures, 'rows': len(report)}, indent=2) + '\n')
print(f'{len(report)} comparisons, {len(failures)} failures')
for f in failures: print('FAIL:', f)
sys.exit(1 if failures else 0)
PY
    pass 'K7 observed rows and summaries equal every row of the Main-owned table'
  else
    printf 'K7 table comparison not run: FM_K7_EXPECTED_TABLE and FM_K7_R1_TABLE are unset\n'
    pass 'K7 fixtures hold the table-independent invariants (live holds alone are owner calls, coverage adds up)'
  fi
}

fm_test_only
failures=0
for test_name in test_k7_fixture_table test_merge_refresh_and_read_call_audit test_preserved_base_rows test_live_hold_branch_preservation test_merge_arbitrary_url_and_task test_merge_verifier_failure_refresh_and_precedence test_shared_owner_real_reviews test_merge_silent_verifier_waits test_merge_stalled_compare_publishes_unknown_base test_shared_owner_rule_pairs test_ordinary_merge_ownership test_observed_merge_check_precedence test_merge_base_observation test_merge_verifier_unknowns test_merge_saved_facts_and_freshness test_merge_hold_lifecycle test_away_merge_action test_captain_verdict_requires_live_hold test_shared_url_live_hold_outranks_verdict test_shared_url_label_follows_facts test_merge_preserved_cross_factors test_recorded_verdict_cross_factors test_merge_precedence_matrix test_actor_coverage test_stale_verdict test_unchecked_is_not_silence test_newest_check_has_no_verdict test_comment_wake test_review_wake test_inline_wake test_ready_issue_wake test_fresh_issue_requires_maintainer test_missing_lane_remains_missing test_partial_freshness_keeps_measured_rows test_malformed_record_cannot_prove_silence test_issue_timeline_and_exact_ack test_verdict_retains_judged_head test_verdict_actor_values_are_discoverable test_observed_replacement_refreshes_verdict test_unobserved_head_leaves_verdict_unknown test_away_yolo_is_fleet_work test_away_yolo_cross_home_is_fleet_work test_retired_and_unsupported_coverage test_unsupported_forge_is_not_fleet_work test_held_unsupported_forge_is_not_captain_work test_shared_contribution_signal_wakes_once test_watcher_keeps_diagnostics_separate_from_contribution_wakes test_expired_child_unsupported_forge_stays_unmeasured test_watcher_surfaces_new_contribution_once test_home_summary_coverage test_unreadable_pending_is_not_empty test_record_task_identity_matches_dirname_basename test_read_only_views_create_no_state test_clock_jump_does_not_refuse_a_read test_genuine_failure_after_clock_jump_is_unavailable test_shared_url_observed_once test_terminal_contribution_settles test_late_owner_inherits_terminal_observation test_interrupted_multi_owner_poll_settles_every_owner test_done_task_open_pr_still_observed test_all_urls_are_attempted_without_reservation test_three_second_pr_reads_complete_fresh_in_one_cycle test_progressing_reads_survive_fivefold_slowdown test_unsupported_url_first_does_not_abort_the_pass test_quota_reason_is_the_refusal_line test_reads_record_their_samples_when_the_poll_ends test_first_unknown_read_defers_the_rest_of_the_pass test_always_silent_url_does_not_starve_the_others test_stop_while_writing_the_order_leaves_no_temporary test_retired_pr_poll_starts_a_new_stop_episode test_every_disarm_path_starts_a_new_stop_episode test_reads_are_independent_of_watcher_interval test_watcher_stopped_check_rings_queued_row_next_pass test_unavailable_forge_records_error_and_wakes_once_per_episode test_late_owner_keeps_failure_episode_suppressed test_retire_ends_observation_of_a_gone_contribution test_late_owner_of_a_retired_final_contribution_is_not_retired test_retire_is_idempotent_and_refuses_unknown_pairs test_repeated_poll_reads_unchanged_prs_conditionally test_low_quota_poll_keeps_last_observation_marked_stale test_failure_after_quota_episode_wakes test_late_owners_keep_quota_episode_suppressed test_low_quota_wave_guards_graphql_and_marks_every_tail_owner test_successful_issue_wave_marks_unmeasured_tail_owners test_http_shim_preserves_backend_failures; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures contribution regressions"
