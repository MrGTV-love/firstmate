#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Same-harness replacement, harness switches, profiles and model routing, the
# progress note, refusals before the agent is touched, fm-spawn --relaunch's own
# refusals, and failures after it is stopped.  Recovery, relocation, Herdr
# reclaim, and continuation authorization live in
# tests/fm-control-relaunch-recovery.test.sh; secondmate child-work,
# lifecycle-lock participation, TeamClaude, reboot recovery, and the quota routes
# live in tests/fm-control-relaunch-backends.test.sh.
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

test_relaunch_refuses_unsupported_omp_before_stopping() {
  local dir out rc version
  for version in 18.1.11 18.1.19; do
    dir=$(new_case "omp-old-${version##*.}" omp-old)
    add_ship_task "$dir" omp-old claude
    cp "$dir/home/state/omp-old.meta" "$dir/prior.meta"
    cp "$dir/home/data/omp-old/brief.md" "$dir/prior-brief.md"
    cat > "$dir/fakebin/omp" <<SH
#!/bin/sh
if [ "\${1:-}" = --version ]; then
  printf 'omp/$version\n'
  exit 0
fi
printf 'unexpected omp invocation\n' >> '$dir/fake/keys'
exit 1
SH
    chmod +x "$dir/fakebin/omp"
    out=$(run_control "$dir" omp-old relaunch --harness omp --note "preserve current agent"); rc=$?
    expect_code 1 "$rc" "unsupported omp replacement must refuse before stopping: $out"
    assert_contains "$out" "installed omp version 'omp/$version'" "refusal must name installed version"
    assert_contains "$out" "minimum supported version is 18.1.20" "refusal must name minimum"
    assert_contains "$out" "omp update" "refusal must name upgrade step"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "refusal stopped the original agent"
    [ ! -s "$dir/fake/keys" ] && [ ! -s "$dir/fake/literal" ] || fail "refusal sent lifecycle or launch input"
    cmp -s "$dir/prior.meta" "$dir/home/state/omp-old.meta" || fail "refusal changed task metadata"
    cmp -s "$dir/prior-brief.md" "$dir/home/data/omp-old/brief.md" || fail "refusal changed task instructions"
    assert_absent "$dir/home/state/omp-old.control-relaunch" "refusal must precede relaunch transaction"
    printf 'bash' > "$dir/fake/command"
    out=$(run_spawn "$dir" omp-old --relaunch --harness omp); rc=$?
    expect_code 1 "$rc" "direct relaunch must also refuse unsupported omp: $out"
    assert_contains "$out" "installed omp version 'omp/$version'" "direct relaunch must name installed version"
    [ ! -s "$dir/fake/keys" ] && [ ! -s "$dir/fake/literal" ] || fail "direct refusal sent launch input"
    cmp -s "$dir/prior.meta" "$dir/home/state/omp-old.meta" || fail "direct refusal changed task metadata"
  done
  pass "fm-control relaunch: unsupported omp preserves the running agent and task"
}

test_relaunch_refuses_contradictory_dsh_route_before_stopping() {
  local dir out rc case_name expected
  local -a args
  case_name=dsh-without-model
  dir=$(new_case "dsh-route-$case_name" dsh-route)
  add_ship_task "$dir" dsh-route claude
  cat > "$dir/fakebin/dsh-tui" <<'SH'
#!/bin/sh
if [ "${1:-}" = version ]; then
  printf '@deepseek-harness-tui/dsh-tui 99.1.0 (launcher)\nprofile: 99.1.0  fake\n'
  exit 0
fi
exit 1
SH
  cat > "$dir/fakebin/dsh" <<'SH'
#!/bin/sh
printf '99.2.0\n'
SH
  chmod +x "$dir/fakebin/dsh-tui" "$dir/fakebin/dsh"
  cp "$dir/home/state/dsh-route.meta" "$dir/prior.meta"
  args=(--harness dsh)
  expected="dsh requires an explicit DeepSeek model id"
  out=$(run_control "$dir" dsh-route relaunch "${args[@]}" --note "preserve current agent"); rc=$?
  expect_code 1 "$rc" "$case_name must refuse before stopping: $out"
  assert_contains "$out" "$expected" "$case_name refusal must name the contradiction"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "$case_name refusal stopped the original agent"
  [ ! -s "$dir/fake/keys" ] && [ ! -s "$dir/fake/literal" ] || fail "$case_name refusal sent lifecycle or launch input"
  cmp -s "$dir/prior.meta" "$dir/home/state/dsh-route.meta" || fail "$case_name refusal changed task metadata"
  assert_absent "$dir/home/state/dsh-route.control-relaunch" "$case_name refusal must precede the relaunch transaction"
  # A contradictory explicit omp route must refuse before stopping the agent.
  dir=$(new_case dsh-route-stand-in dsh-route)
  add_ship_task "$dir" dsh-route claude
  cat > "$dir/fakebin/omp" <<'SH'
#!/bin/sh
if [ "${1:-}" = --version ]; then
  printf 'omp/18.1.20\n'
  exit 0
fi
if [ "${1:-}" = models ]; then
  printf '{"models":[]}\n'
  exit 0
fi
exit 0
SH
  chmod +x "$dir/fakebin/omp"
  cp "$dir/home/state/dsh-route.meta" "$dir/prior.meta"
  out=$(run_control "$dir" dsh-route relaunch --harness omp --model deepseek/deepseek-v4-flash --note "preserve current agent"); rc=$?
  expect_code 1 "$rc" "DeepSeek through omp must refuse: $out"
  assert_contains "$out" "DeepSeek runs through dsh-tui, not omp" "refusal must name the replacement adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "DeepSeek refusal stopped the original agent"
  [ ! -s "$dir/fake/keys" ] && [ ! -s "$dir/fake/literal" ] || fail "DeepSeek refusal sent lifecycle input"
  cmp -s "$dir/prior.meta" "$dir/home/state/dsh-route.meta" || fail "DeepSeek refusal changed metadata"
  assert_absent "$dir/home/state/dsh-route.control-relaunch" "DeepSeek refusal must precede the transaction"
  pass "fm-control relaunch: missing dsh models and DeepSeek-through-omp refuse before stopping"
}

# A plain relaunch of a secondmate whose configured harness is a bare dsh takes
# the calling DSH session's bound model, as the spawn does, before the stop.
test_secondmate_config_dsh_relaunch_carries_own_session_model() {
  local dir home source primary out rc
  dir=$(new_case smdsh smd)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smd"
  printf 'dsh\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smd/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smd\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smd"
    echo "endpoint_task_id=smd"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smd.meta"
  printf '%s\n' "fm-smd" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  cat > "$dir/fakebin/dsh-tui" <<'SH'
#!/bin/sh
[ "${1:-}" = version ] && exit 0
exit 1
SH
  printf '#!/bin/sh\nprintf "99.2.0\\n"\n' > "$dir/fakebin/dsh"
  chmod +x "$dir/fakebin/dsh-tui" "$dir/fakebin/dsh"
  cp "$home/state/smd.meta" "$dir/prior.meta"
  out=$(DSH_HOME="$dir/unbound/dsh" run_control "$dir" smd relaunch); rc=$?
  expect_code 1 "$rc" "a config dsh secondmate with no live session model must refuse: $out"
  assert_contains "$out" "has no configured model" "the refusal must name the missing model configuration"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the missing-model refusal stopped the running agent"
  cmp -s "$dir/prior.meta" "$home/state/smd.meta" || fail "the missing-model refusal changed task metadata"
  assert_absent "$home/state/smd.control-relaunch" "the missing-model refusal must precede the relaunch transaction"
  source="$dir/operator-dsh"
  mkdir -p "$source/profiles/dsh-tui/node_modules" "$dir/operator-home"
  printf '{}\n' > "$source/profiles/dsh-tui/package.json"
  primary=$(FM_DSH_OPERATOR_HOME="$dir/operator-home" python3 "$ROOT/bin/fm-dsh.py" prepare-primary \
    "$dir/primary-state" dsh-primary g1 "$source" deepseek/deepseek-v4-pro high "$home" "$ROOT") \
    || fail "the DSH primary runtime fixture could not be prepared"
  # Pending composer text stops the transaction at the exit step, after the
  # replacement profile is resolved and journaled but before the agent stops.
  printf 'i' > "$dir/fake/composer"
  out=$(DSH_HOME="$primary/dsh" run_control "$dir" smd relaunch); rc=$?
  expect_code 1 "$rc" "the fixture must stop at the pending composer: $out"
  assert_contains "$out" "composer visibly holds pending text" "the bound model must pass every pre-stop admission"
  assert_equals dsh "$(journal_field "$dir" smd to_harness)" "the configured dsh harness must be the replacement"
  assert_equals deepseek/deepseek-v4-pro "$(journal_field "$dir" smd to_model)" \
    "the replacement must carry the calling DSH session's bound model"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the pending-composer refusal stopped the running agent"
  # A secondmate already on dsh keeps its recorded model and effort, so the
  # replacement resumes its conversation rather than adopting the primary's.
  rm -f "$home/state/smd.control-relaunch"
  sed -e 's/^harness=claude$/harness=dsh/' -e 's|^model=default$|model=deepseek/recorded-model|' -e 's/^effort=default$/effort=max/' \
    "$dir/prior.meta" > "$home/state/smd.meta"
  printf 'dsh' > "$dir/fake/command"
  out=$(DSH_HOME="$primary/dsh" run_control "$dir" smd relaunch); rc=$?
  expect_code 1 "$rc" "the fixture must stop at the pending composer: $out"
  assert_contains "$out" "composer visibly holds pending text" "the recorded profile must pass every pre-stop admission"
  assert_equals deepseek/recorded-model "$(journal_field "$dir" smd to_model)" \
    "a dsh secondmate must keep its recorded model rather than the calling session's"
  assert_equals max "$(journal_field "$dir" smd to_effort)" "a dsh secondmate must keep its recorded effort"
  [ "$(cat "$dir/fake/command")" = dsh ] || fail "the pending-composer refusal stopped the running dsh agent"
  pass "fm-control relaunch: a config dsh secondmate with no model keeps a recorded dsh profile, else carries the DSH session's bound model, and refuses without one before stopping"
}

test_relaunch_omp_billing_admission_preserves_running_agents() {
  local provider path dir id model meta out rc expected
  local -a args
  for provider in openai openrouter OpenAI oPeNrOuTeR openai-codex; do
    for path in explicit recorded role secondmate; do
      id="rl-billing-$provider-$path"
      model="$provider/gpt-6.1-sol"
      dir=$(new_case "$id" "$id")
      add_ship_task "$dir" "$id" omp
      printf omp > "$dir/fake/command"
      printf omp > "$dir/fake/becomes"
      mkdir -p "$dir/home/config"
      meta=$(cat "$dir/home/state/$id.meta")
      meta=${meta/model=default/model=openai-codex\/gpt-6.1-sol}
      args=(--note "preserve subscription routing")
      case "$path" in
        explicit) args+=(--model "$model") ;;
        recorded) meta=${meta/model=openai-codex\/gpt-6.1-sol/model=$model} ;;
        role)
          printf '{"version":1,"roles":{"chosen":{"omp":{"model":"%s"}}},"retired":[]}\n' "$model" \
            > "$dir/home/config/model-index.json"
          args+=(--model role:chosen)
          ;;
        secondmate)
          meta=${meta/kind=ship/kind=secondmate}
          meta=${meta/mode=no-mistakes/mode=secondmate}
          meta="$meta"$'\n'"home=$dir/wt"
          mkdir -p "$dir/wt/state" "$dir/wt/data" "$dir/wt/bin"
          printf '# fixture charter\n' > "$dir/wt/AGENTS.md"
          printf '%s\n' "$id" > "$dir/wt/.fm-secondmate-home"
          printf 'omp %s high\n' "$model" > "$dir/home/config/secondmate-harness"
          args=()
          ;;
      esac
      printf '%s\n' "$meta" > "$dir/home/state/$id.meta"
      cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'omp/18.1.20\n' ;;
  models) printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"}]}' ;;
  usage) printf '{"reports":[]}\n' ;;
  *) exit 0 ;;
esac
SH
      chmod +x "$dir/fakebin/omp"
      cp "$dir/home/state/$id.meta" "$dir/prior.meta"
      cp "$dir/home/data/$id/brief.md" "$dir/prior-brief.md"
      out=$(run_control "$dir" "$id" relaunch ${args[@]+"${args[@]}"}); rc=$?
      expected=1
      [ "$provider" != openai-codex ] || expected=0
      expect_code "$expected" "$rc" "$path relaunch billing admission for $provider: $out"
      assert_equals omp "$(cat "$dir/fake/command")" "billing admission must leave a running agent"
      if [ "$expected" = 1 ]; then
        assert_contains "$out" 'routes use API billing' "relaunch must reject the resolved API route"
        [ ! -s "$dir/fake/keys" ] && [ ! -s "$dir/fake/literal" ] || fail "billing refusal sent lifecycle input"
        cmp -s "$dir/prior.meta" "$dir/home/state/$id.meta" || fail "billing refusal changed task metadata"
        cmp -s "$dir/prior-brief.md" "$dir/home/data/$id/brief.md" || fail "billing refusal changed instructions"
        assert_absent "$dir/home/state/$id.control-relaunch" "billing refusal must precede checkpointing"
      else
        assert_equals complete "$(journal_field "$dir" "$id" phase)" "subscription relaunch must complete"
        assert_equals "$model" "$(meta_field "$dir" "$id" model)" "subscription selection must reach the replacement"
        assert_contains "$(cat "$dir/fake/launch")" "--model '$model'" "subscription model must reach executable launch"
      fi
    done
  done
  pass "omp relaunch billing admission preserves agents before refusal and accepts subscription routes"
}

test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text() {
  local dir out rc
  dir=$(new_case pending-exit rl43)
  add_ship_task "$dir" rl43 claude
  printf 'i' > "$dir/fake/composer"

  out=$(run_control "$dir" rl43 relaunch --note "preserve the pending draft"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command into pending composer text"
  assert_contains "$out" "composer visibly holds pending text" \
    "the refusal should name the pending composer text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pending composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be concatenated onto pending composer text"
  pass "fm-control relaunch: pending composer text refuses before the exit command is typed"
}

test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven() {
  local dir out rc
  dir=$(new_case unproven-exit rl44)
  add_ship_task "$dir" rl44 claude

  out=$(FM_FAKE_COMPOSER_READ_FAIL=1 \
    run_control "$dir" rl44 relaunch --note "preserve on an unreadable composer"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command when the composer state cannot be proven empty"
  assert_contains "$out" "not proven empty" \
    "the refusal should name the unproven composer state, not claim pending text"
  assert_not_contains "$out" "visibly holds pending text" \
    "an unreadable composer is not the same claim as observed pending text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unproven composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed when the composer state is not proven empty"
  pass "fm-control relaunch: an unreadable composer fails safe before the exit command is typed"
}

test_relaunch_from_linked_home_preserves_recorded_worktree() {
  local dir out rc head fetch_head
  dir=$(new_case linked-home rl42)
  add_ship_task "$dir" rl42 claude
  git -C "$dir/proj" worktree add --quiet --detach "$dir/secondmate" HEAD
  sed "s|^project=.*|project=$dir/secondmate|" "$dir/home/state/rl42.meta" > "$dir/linked.meta"
  mv "$dir/linked.meta" "$dir/home/state/rl42.meta"
  printf 'committed task work\n' > "$dir/wt/task.txt"
  git -C "$dir/wt" add task.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-work
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'unfinished task work\n' >> "$dir/wt/task.txt"
  fetch_head=$(git -C "$dir/wt" rev-parse --git-path FETCH_HEAD)

  out=$(run_control "$dir" rl42 relaunch --note "continue from linked home"); rc=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home relaunch\n'
    printf '$ bin/fm-control.sh rl42 relaunch --note "continue from linked home"\n%s\nexit=%s\n' "$out" "$rc"
    printf 'worker HEAD before=%s after=%s\n' "$head" "$(git -C "$dir/wt" rev-parse HEAD)"
    printf 'saved task metadata:\n'; cat "$dir/home/state/rl42.meta"
    printf 'worker status:\n'; git -C "$dir/wt" status --short
    printf 'preserved task.txt:\n'; cat "$dir/wt/task.txt"
    if [ -e "$fetch_head" ]; then
      printf 'worker FETCH_HEAD:\n'; cat "$fetch_head"
    else
      printf 'worker FETCH_HEAD absent\n'
    fi
    printf '# evidence end\n'
  fi
  expect_code 0 "$rc" "a linked spawning home should relaunch its recorded copy"$'\n'"$out"
  [ "$(meta_field "$dir" rl42 worktree)" = "$dir/wt" ] || fail "relaunch replaced the recorded copy"
  [ "$(meta_field "$dir" rl42 project)" = "$dir/secondmate" ] || fail "relaunch replaced the linked spawning home"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "relaunch reset committed task work"
  assert_grep 'unfinished task work' "$dir/wt/task.txt" "relaunch discarded unfinished task work"
  [ ! -e "$fetch_head" ] || fail "relaunch fetched instead of preserving the recorded copy"
  pass "fm-control relaunch: a linked spawning home preserves committed and unfinished work in the recorded copy"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=feature/relaunch'
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
  } >> "$dir/home/state/rl19.meta"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "feature/relaunch" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  pass "fm-control relaunch: durable task metadata survives replacement launch publication"
}

test_relaunch_keeps_a_recorded_pr_parseable_for_monitoring() {
  local dir out rc parsed tracing
  for tracing in off on; do
    dir=$(new_case "pr-parse-$tracing" rl90)
    add_ship_task "$dir" rl90 claude
    printf '%s\n' "$$" > "$dir/home/state/.lock"
    printf '%s %s\n' "$$" "$tracing" > "$dir/home/state/.trace-context-effective"
    {
      printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01'
      printf '%s\n' 'pr=https://github.com/example/repo/pull/90'
      printf '%s\n' 'pr_head=0123456789abcdef0123456789abcdef01234567'
      printf '%s\n' 'x_request=request-90'
    } >> "$dir/home/state/rl90.meta"

    out=$(run_control "$dir" rl90 relaunch --note "keep PR monitoring alive"); rc=$?
    expect_code 0 "$rc" "relaunch of a task with a recorded PR and tracing $tracing should succeed"$'\n'"$out"
    [ -n "$(meta_field "$dir" rl90 control_relaunch_tx)" ] \
      || fail "the published record should still identify its relaunch transaction"
    parsed=$(bash -c '
      . "$1/bin/fm-pr-lib.sh"
      fm_pr_metadata_identity_parse "$2" && printf "%s\n" "$FM_PR_META_URL"
    ' _ "$ROOT" "$dir/home/state/rl90.meta")
    [ "$parsed" = "https://github.com/example/repo/pull/90" ] \
      || fail "PR monitoring must still parse the relaunched task record with tracing $tracing (got: ${parsed:-rejected})"
    if [ "$tracing" = on ]; then
      [ "$(awk -F= '$1 == "traceparent" { count++ } END { print count+0 }' "$dir/home/state/rl90.meta")" = 1 ] \
        || fail "traced relaunch must publish exactly one trace carrier"
      [ "$(meta_field "$dir" rl90 traceparent)" = "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01" ] \
        || fail "traced relaunch must preserve the task's recorded carrier"
    else
      [ -z "$(meta_field "$dir" rl90 traceparent)" ] \
        || fail "untraced relaunch must remove the task's recorded carrier"
    fi
    pass "fm-control relaunch: a recorded PR stays parseable for PR monitoring with tracing $tracing"
  done
}

test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare launch_release waiting ready release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  launch_release="$dir/trace-release"
  waiting="$dir/meta-writer-waiting"
  ready="$dir/meta-writer-ready"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_TRACE_RELEASE="$launch_release" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  # shellcheck disable=SC2031 # A fixture subshell's PATH change does not reach this parent.
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ ! -e "$ready" ] || {
    : > "$launch_release"
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during relaunch delivery"
  }
  : > "$launch_release"
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "durable metadata writer did not resume after relaunch delivery committed"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete before serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  assert_relaunch_worker_trace "$dir" "$traceparent"
  pass "fm-control relaunch: delivery and concurrent task metadata publication serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  assert_relaunch_worker_trace "$dir" unset
  pass "fm-control relaunch: disabling tracing clears metadata and pane context"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief launch_brief first_line role_line task_line
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  cp "$ROOT/AGENTS.md" "$dir/wt/AGENTS.md"
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Exercise relaunch behavior for rl2." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  launch_brief="$dir/home/data/rl2/launch-brief.md"
  first_line=$(sed -n '1p' "$launch_brief")
  [ "$first_line" = '# Current worker role contract' ] ||
    fail "a Firstmate-worktree relaunch did not establish the crewmate identity first"
  role_line=$(grep -n '^# Current worker role contract$' "$launch_brief" | cut -d: -f1)
  task_line=$(grep -n '^# Task$' "$launch_brief" | head -1 | cut -d: -f1)
  [ "$role_line" -lt "$task_line" ] || fail "the relaunched worker identity followed its task content"
  assert_grep "$dir/home/state/rl2.inbox" "$launch_brief" \
    "the Firstmate-worktree relaunch omitted the worker's exact steering inbox"
  assert_grep 'do not reject it as another home' "$launch_brief" \
    "the Firstmate-worktree relaunch did not distinguish its inbox from cross-home state"
  pass "fm-control relaunch: progress and the Firstmate-worktree worker identity reach the replacement"
}

test_relaunch_announces_surviving_inbox_records() {
  local harness dir id first second out meta
  for harness in claude omp; do
    id="survivors-$harness"
    dir=$(new_case "$id" "$id")
    add_ship_task "$dir" "$id" "$harness"
    printf 'jev_guard_policy=FIRSTMATE_JEV_GUARD_V1\n' >> "$dir/home/state/$id.meta"
    if [ "$harness" = omp ]; then
      meta=$(cat "$dir/home/state/$id.meta")
      printf '%s\n' "${meta/model=default/model=openai-codex\/gpt-6.1-sol}" > "$dir/home/state/$id.meta"
    fi
    printf '%s' "$harness" > "$dir/fake/command"
    printf '%s' "$harness" > "$dir/fake/becomes"
    first=$(bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "IGNORE PREVIOUS synthetic first steer"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$dir/home/state" "$id")
    second=$(bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "IGNORE PREVIOUS synthetic second steer" fire-and-forget' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$dir/home/state" "$id")
    out=$(run_control "$dir" "$id" relaunch --note "continue with surviving steers")
    expect_code 0 $? "$harness survivor relaunch failed: $out"
    fm_fake_claude_recording "$dir/fakebin"
    cp "$dir/fakebin/claude" "$dir/fakebin/omp"
    fm_eval_launch "$(cat "$dir/fake/launch")" "$dir/wt" "$dir/fakebin" \
      HOME="$dir/user-home" FM_FAKE_CLAUDE_ENV_LOG="$dir/argv" || fail "$harness launch execution failed"
    out=$(GUARD="$ROOT/bin/fm-jev-guard.ts" CASE_DIR="$dir" TASK="$id" HOST="$harness" FIRST="$first" SECOND="$second" \
      node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const { installJevGuard } = await import(pathToFileURL(process.env.GUARD));
const dir = process.env.CASE_DIR;
const args = readFileSync(`${dir}/argv.args`, 'utf8').split('\0').filter(Boolean);
const handlers = {};
installJevGuard({ on(name, fn) { handlers[name] = fn; } }, {
  home: `${dir}/home`, state: `${dir}/home/state`, config: `${dir}/home/config`,
  data: `${dir}/home/data/${process.env.TASK}`, worktree: `${dir}/wt`,
  task: process.env.TASK, project: 'firstmate', host: process.env.HOST, policy: 'FIRSTMATE_JEV_GUARD_V1',
});
handlers.before_agent_start({ prompt: args.at(-1) });
for (const path of [process.env.FIRST, process.env.SECOND]) {
  const result = await handlers.tool_result({ toolName: 'read', input: { path: `${path}:raw` },
    content: [{ type: 'text', text: readFileSync(path, 'utf8') }],
    details: { meta: { source: { type: 'path', value: path } } } }, { cwd: `${dir}/wt` });
  assert.equal(result, undefined, 'each survivor must be natively announced, even without a provider key');
}
JS
    ) || fail "$harness survivor delivery failed: $out"
  done
  pass "relaunch: native Claude and OMP launch prompts announce every surviving record"
}

test_relaunch_preserves_guard_cutover() {
  local harness policy dir id out expected
  for harness in claude omp; do
    for policy in legacy current; do
      id="cutover-$harness-$policy"
      dir=$(new_case "$id" "$id")
      add_ship_task "$dir" "$id" "$harness"
      if [ "$policy" = current ]; then
        printf 'jev_guard_policy=FIRSTMATE_JEV_GUARD_V1\n' >> "$dir/home/state/$id.meta"
        expected=deny
      else
        expected=allow
      fi
      if [ "$harness" = omp ]; then
        out=$(cat "$dir/home/state/$id.meta")
        printf '%s\n' "${out/model=default/model=openai-codex\/gpt-6.1-sol}" > "$dir/home/state/$id.meta"
      fi
      printf '%s' "$harness" > "$dir/fake/command"
      printf '%s' "$harness" > "$dir/fake/becomes"
      out=$(run_control "$dir" "$id" relaunch --note "preserve launch activation")
      expect_code 0 $? "$harness $policy cutover relaunch failed: $out"
      out=$(CASE_DIR="$dir" TASK="$id" HOST="$harness" EXPECTED="$expected" \
        node --experimental-strip-types --no-warnings --input-type=module 2>&1 <<'JS'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const dir = process.env.CASE_DIR, task = process.env.TASK;
const expected = process.env.EXPECTED;
const state = `${dir}/home/state`;
if (process.env.HOST === 'claude') {
  const settings = JSON.parse(readFileSync(`${dir}/wt/.claude/settings.local.json`, 'utf8'));
  const command = settings.hooks.PreToolUse[0].hooks[0].command;
  const output = execFileSync('bash', ['-c', command], { encoding: 'utf8',
    input: JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Write',
      tool_input: { file_path: '/etc/fm-cutover-synthetic', content: 'fixture' } }) });
  assert.equal(output ? JSON.parse(output).hookSpecificOutput.permissionDecision : 'allow', expected);
} else {
  const { default: install } = await import(pathToFileURL(`${state}/${task}.omp-ext.ts`));
  const handlers = {};
  install({ registerProvider() {}, pi: { AgentRegistry: { global: () => ({ list: () => [] }) } },
    on(name, handler) { (handlers[name] ??= []).push(handler); } });
  let denied = false;
  for (const handler of handlers.tool_call ?? []) {
    const result = await handler({ toolName: 'write', input: { path: '/etc/fm-cutover-synthetic', content: 'fixture' } }, { cwd: `${dir}/wt` });
    denied ||= result?.block === true;
  }
  assert.equal(denied ? 'deny' : 'allow', expected);
}
const meta = readFileSync(`${state}/${task}.meta`, 'utf8').split('\n');
assert.equal(meta.includes('jev_guard_policy=FIRSTMATE_JEV_GUARD_V1'), expected === 'deny');
JS
      ) || fail "$harness $policy generated guard activation failed: $out"
    done
  done
  pass "relaunch: legacy tasks remain unguarded and current tasks retain launch activation on both hosts"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = default ] \
    || fail "an effort chosen for the old harness must not carry to a different one"
  pass "fm-control relaunch: a harness switch resets model and effort unless they are named too"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop() {
  local dir out rc id=rl-ultra
  dir=$(new_case native-ultra "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-6-astra|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  out=$(run_control "$dir" "$id" relaunch --model openai-codex/gpt-6-astra --note "invalid native effort transfer"); rc=$?
  expect_code 1 "$rc" "Ultra transferred to ordinary Pi"
  assert_contains "$out" "ultra effort requires pi or pi-signed" "model-aware relaunch refusal missing"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "invalid Ultra relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "invalid Ultra relaunch sent lifecycle input"
  out=$(run_control "$dir" "$id" relaunch --note "preserve explicit native effort"); rc=$?
  expect_code 0 "$rc" "native Ultra relaunch failed: $out"
  [ "$(meta_field "$dir" "$id" effort)" = ultra ] || fail "relaunch lost Ultra metadata"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "relaunch lost native model"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "relaunch lost native flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "--thinking 'ultra'" "relaunch used an invalid Pi level"
  pass "native Ultra relaunch preserves its profile and rejects an unsupported model before stopping"
}

test_model_index_resolves_and_refuses_before_stop() {
  local dir out rc id=rl-index
  dir=$(new_case model-index "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-old|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  mkdir -p "$dir/home/config" "$dir/catalogs"
  printf '%s\n' '{"version":1,"roles":{"native":{"pi":{"model":"codex-native/gpt-6-astra"}}},"retired":["gpt-old"]}' \
    > "$dir/home/config/model-index.json"
  printf '%s\n' '{"models":[{"id":"codex-native/gpt-6-astra"}]}' > "$dir/catalogs/pi.json"
  out=$(FM_MODEL_CATALOG_DIR="$dir/catalogs" run_control "$dir" "$id" relaunch --note "recorded model since retired"); rc=$?
  expect_code 1 "$rc" "a recorded model the index has retired must refuse"
  assert_contains "$out" "retired model: codex-native/gpt-old" "the refusal should name the retired id"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a retired-model relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a retired-model relaunch sent lifecycle input"
  out=$(FM_MODEL_CATALOG_DIR="$dir/catalogs" run_control "$dir" "$id" relaunch --model role:native --note "move to the indexed role"); rc=$?
  expect_code 0 "$rc" "a role relaunch with native Ultra should resolve before its effort check: $out"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "the relaunch should record the resolved id"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "the resolved native model should keep its Ultra flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "role:native" "a role reference must not reach the harness"
  printf '%s\n' '{"models":[{"id":"codex-native/gpt-7"}]}' > "$dir/catalogs/pi.json"
  cp "$dir/fake/literal" "$dir/literal-before"
  out=$(FM_MODEL_CATALOG_DIR="$dir/catalogs" run_control "$dir" "$id" relaunch --note "vendor dropped the id"); rc=$?
  expect_code 1 "$rc" "an index entry its catalog no longer lists must refuse"
  assert_contains "$out" "id 'codex-native/gpt-6-astra' absent or retired in pi catalog" "the refusal should name the absent id"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a catalog-absent relaunch stopped the running agent"
  cmp -s "$dir/literal-before" "$dir/fake/literal" || fail "a catalog-absent relaunch sent lifecycle input"
  pass "fm-control relaunch: roles resolve, and retired or catalog-absent ids refuse through the model index before the stop"
}

test_model_index_generation_survives_account_checks_and_replacement() {
  local dir out rc id request verdict selected
  for request in role:chosen stand-in:chosen openai/selected; do
    id="rl-generation-${request//[:\/]/-}"
    dir=$(new_case model-generation "$id")
    add_ship_task "$dir" "$id" pi
    printf pi > "$dir/fake/command"
    printf pi > "$dir/fake/becomes"
    mkdir -p "$dir/home/config" "$dir/account"
    printf '%s\nopenai\n' "$dir/account" > "$dir/home/config/pi-account"
    printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/selected","stand_in":"openai/standby"}}},"retired":[]}' \
      > "$dir/original-index.json"
    selected=openai/selected
    [ "$request" != stand-in:chosen ] || selected=openai/standby
    cat > "$dir/fakebin/pi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  auth)
    cp '$dir/later.json' '$dir/home/config/model-index.json'
    printf '%s\n' "\$PI_CODING_AGENT_DIR" >> '$dir/auth-roots'
    printf '{"status":"ready"}\n'
    ;;
  --list-models)
    printf '%s\n' "\$PI_CODING_AGENT_DIR" >> '$dir/catalog-roots'
    printf 'provider model context\n'
    cat "\$PI_CODING_AGENT_DIR/listed"
    ;;
  *) printf 'Options: --tui-mode\n' ;;
esac
SH
    chmod +x "$dir/fakebin/pi"
    for verdict in absent available; do
      cp "$dir/original-index.json" "$dir/home/config/model-index.json"
      : > "$dir/auth-roots"
      : > "$dir/catalog-roots"
      : > "$dir/fake/literal"
      : > "$dir/fake/keys"
      if [ "$verdict" = available ]; then
        printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/later","stand_in":"openai/later-standby"}}},"retired":["selected","standby"]}' > "$dir/later.json"
        printf 'openai selected 272K 32K yes no\nopenai standby 272K 32K yes no\n' > "$dir/account/listed"
      else
        printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/later","stand_in":"openai/later-standby"}}},"retired":[]}' > "$dir/later.json"
        printf 'openai later 272K 32K yes no\n' > "$dir/account/listed"
      fi
      cp "$dir/home/state/$id.meta" "$dir/meta-before"
      out=$(run_control "$dir" "$id" relaunch --model "$request" --note "preserve selected routing generation"); rc=$?
      cmp -s "$dir/later.json" "$dir/home/config/model-index.json" || fail "account check did not mutate the source generation"
      [ "$(cat "$dir/catalog-roots" | sort -u)" = "$dir/account" ] || fail "generation check changed the worker account"
      if [ "$verdict" = absent ]; then
        expect_code 1 "$rc" "an absent originally selected entry must refuse before stopping: $out"
        assert_contains "$out" "id '$selected' absent or retired in pi catalog" "the frozen entry must remain catalog-gated"
        cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "generation refusal changed the running task record"
        [ "$(cat "$dir/fake/command")" = pi ] || fail "generation refusal stopped the working agent"
        [ ! -s "$dir/fake/literal" ] || fail "generation refusal sent lifecycle input"
      else
        expect_code 0 "$rc" "the selected available generation must survive auth mutation and replacement: $out"
        [ "$(meta_field "$dir" "$id" model)" = "$selected" ] || fail "replacement switched model generations"
        assert_contains "$(cat "$dir/fake/literal")" "--model '$selected'" "replacement lost the frozen model"
        [ "$(wc -l < "$dir/catalog-roots" | tr -d ' ')" = 2 ] || fail "both pre-stop and replacement must check the selected entry"
      fi
    done
  done
  pass "relaunch freezes role, stand-in, and literal membership across authentication and replacement"
}

test_unpinned_indexed_relaunch_does_not_query_the_supervisor_account() {
  local dir out rc id=rl-context model
  dir=$(new_case model-context "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  mkdir -p "$dir/home/config" "$dir/supervisor" "$dir/pane"
  : > "$dir/home/config/launch-env-allowlist"
  printf 'openai  supervisor-only  272K  32K  yes  no\n' > "$dir/supervisor/listed"
  printf 'openai  pane-only  272K  32K  yes  no\n' > "$dir/pane/listed"
  cat > "$dir/fakebin/pi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --list-models ]; then
  printf '%s\n' "\${PI_CODING_AGENT_DIR-unset}" >> '$dir/catalog-calls'
  printf 'provider model context\n'
  cat "\$PI_CODING_AGENT_DIR/listed"
  exit
fi
printf 'Options: --tui-mode\n'
SH
  chmod +x "$dir/fakebin/pi"
  for model in pane-only supervisor-only; do
    printf '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/%s"}}},"retired":[]}\n' "$model" > "$dir/home/config/model-index.json"
    out=$(PI_CODING_AGENT_DIR="$dir/supervisor" run_control "$dir" "$id" relaunch \
      --model role:chosen --note "replace without supervisor catalog evidence"); rc=$?
    expect_code 0 "$rc" "an unknown replacement context must not refuse from the supervisor catalog: $out"
    assert_contains "$out" "effective worker account context is not established" "pre-stop and spawn checks must disclose unknown context"
    assert_absent "$dir/catalog-calls" "neither pre-stop nor replacement spawn may query the supervisor Pi catalog"
    [ "$(meta_field "$dir" "$id" model)" = "openai/$model" ] || fail "the replacement must retain its chosen model"
  done
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  cp "$dir/fake/literal" "$dir/literal-before"
  printf '%s\n' '{"version":1,"roles":{"chosen":{"pi":{"model":"openai/supervisor-only"}}},"retired":["supervisor-only"]}' > "$dir/home/config/model-index.json"
  out=$(PI_CODING_AGENT_DIR="$dir/supervisor" run_control "$dir" "$id" relaunch --note "retired selector"); rc=$?
  expect_code 1 "$rc" "unknown context must still refuse offline retirement before stopping"
  assert_contains "$out" "retired model" "retirement must remain authoritative"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "an offline refusal must preserve metadata"
  cmp -s "$dir/literal-before" "$dir/fake/literal" || fail "an offline refusal must not send lifecycle input"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an offline refusal must leave the running agent alone"
  pass "unpinned indexed relaunch discloses unknown context before stopping without supervisor catalog evidence"
}

test_signed_out_worker_account_pin_refuses_before_stop() {
  local dir out rc id=rl-acct-out
  dir=$(new_case acct-out "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_control "$dir" "$id" relaunch --note "account signed out"); rc=$?
  expect_code 1 "$rc" "a relaunch under a signed-out account pin must refuse"
  assert_contains "$out" "config/claude-account pins Claude workers to $dir/work, which is not signed in" \
    "the refusal should name the pin and the signed-out root"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a signed-out pin must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a signed-out pin must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"
  pass "fm-control relaunch: a signed-out worker account pin refuses before the old agent stops"
}

test_worker_account_pin_follows_the_relaunch() {
  local dir out rc id=rl-acct
  dir=$(new_case acct "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(run_control "$dir" "$id" relaunch --note "pinned account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a signed-in account pin should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/work" ] || fail "the relaunched record should carry the pinned account"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/work'" \
    "the replacement should launch under the pinned root"
  rm "$dir/home/config/claude-account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "pin removed"); rc=$?
  expect_code 0 "$rc" "a relaunch after the pin is removed should succeed"$'\n'"$out"
  assert_no_grep "account=" "$dir/home/state/$id.meta" "a relaunch without a pin must drop the previous account from the record"
  assert_not_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR=" \
    "an unpinned replacement must launch exactly as before"
  pass "fm-control relaunch: the replacement follows the home's current worker account pin"
}

test_recorded_api_key_opt_in_follows_the_relaunch() {
  local dir out rc id=rl-apikey
  dir=$(new_case apikey "$id")
  add_ship_task "$dir" "$id" claude
  printf 'api_key=allow\n' >> "$dir/home/state/$id.meta"
  out=$(ANTHROPIC_API_KEY=sk-ant-relaunch-test \
    run_control "$dir" "$id" relaunch --note "deliberate API billing"); rc=$?
  expect_code 0 "$rc" "a relaunch of a task that opted in to API billing should carry the opt-in"$'\n'"$out"
  assert_not_contains "$out" "would reach the claude worker" \
    "the recorded opt-in must keep the guard from refusing the replacement"
  [ "$(grep -c '^api_key=' "$dir/home/state/$id.meta")" = 1 ] \
    || fail "the relaunched record must carry exactly one api_key line"$'\n'"$(cat "$dir/home/state/$id.meta")"
  [ "$(meta_field "$dir" "$id" api_key)" = allow ] \
    || fail "the relaunched record must keep api_key=allow"
  assert_contains "$(cat "$dir/fake/literal")" "Firstmate operational input waiting: read" \
    "the replacement agent should have been launched"
  pass "fm-control relaunch: a recorded api_key=allow opt-in is carried to the replacement launch"
}

test_api_key_guard_refuses_before_stop() {
  local dir out rc id=rl-key-refuse
  dir=$(new_case key-refuse "$id")
  add_ship_task "$dir" "$id" claude
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-test-token run_control "$dir" "$id" relaunch --note "guarded"); rc=$?
  expect_code 1 "$rc" "a key must refuse the replacement before stopping the worker"
  assert_contains "$out" "ANTHROPIC_AUTH_TOKEN" "the refusal names the credential variable"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a guard refusal must leave the original worker running"
  [ ! -s "$dir/fake/literal" ] || fail "a guard refusal must not send lifecycle input"
  pass "fm-control relaunch refuses a credential before stopping the original worker"
}

test_api_key_guard_uses_replacement_profile() {
  local dir out rc id=rl-key-profile
  dir=$(new_case key-profile "$id")
  add_ship_task "$dir" "$id" claude
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key run_control "$dir" "$id" relaunch --harness codex --note "switch runner"); rc=$?
  expect_code 0 "$rc" "a non-Claude replacement must not be refused for a Claude credential"$'\n'"$out"
  pass "fm-control checks the replacement harness rather than the previous harness"

  dir=$(new_case key-pin rl-key-pin)
  add_ship_task "$dir" rl-key-pin claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(ANTHROPIC_API_KEY=sk-ant-test-key run_control "$dir" rl-key-pin relaunch --note "pinned"); rc=$?
  expect_code 0 "$rc" "a pin that sheds the key must permit relaunch"$'\n'"$out"
  pass "fm-control honors the replacement account pin's credential shed"

  dir=$(new_case key-allowlist rl-key-allowlist)
  add_ship_task "$dir" rl-key-allowlist claude
  mkdir -p "$dir/home/config"
  printf '%s\n' HOME PATH > "$dir/home/config/launch-env-allowlist"
  out=$(ANTHROPIC_AUTH_TOKEN=sk-ant-test-token run_control "$dir" rl-key-allowlist relaunch --note "filtered"); rc=$?
  expect_code 0 "$rc" "an allowlist that filters the token must permit relaunch"$'\n'"$out"
  pass "fm-control honors the replacement launch allowlist"
}

test_api_key_guard_refuses_tmux_key_before_stop() {
  local dir out rc id=rl-key-tmux
  dir=$(new_case key-tmux "$id")
  add_ship_task "$dir" "$id" claude
  out=$(FM_FAKE_TMUX_GLOBAL_ENV_ANTHROPIC_API_KEY=sk-ant-server-key \
    run_control "$dir" "$id" relaunch --note "guarded"); rc=$?
  expect_code 1 "$rc" "a tmux-only key must refuse before stopping the worker"
  assert_contains "$out" "ANTHROPIC_API_KEY is set in the tmux global environment" \
    "the refusal must identify the tmux scope"
  [ ! -s "$dir/fake/literal" ] || fail "a tmux key refusal must not send lifecycle input"
  pass "fm-control checks tmux environment before stopping the original worker"
}

test_spawn_relaunch_without_the_opt_in_drops_the_recorded_api_key() {
  local dir out rc id=rl-apikey-drop
  dir=$(new_case apikey-drop "$id")
  add_ship_task "$dir" "$id" claude
  printf 'api_key=allow\n' >> "$dir/home/state/$id.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; run_spawn "$dir" "$id" --relaunch); rc=$?
  expect_code 0 "$rc" "a relaunch without the opt-in and without a key should succeed"$'\n'"$out"
  assert_no_grep "^api_key=" "$dir/home/state/$id.meta" \
    "a relaunch that does not opt in must not inherit the previous api_key=allow line"
  pass "fm-spawn --relaunch: a replacement that does not opt in drops the recorded api_key line"
}

test_pi_exclude_tools_follow_the_relaunch() {
  local dir out rc id=rl-pi-excl
  dir=$(new_case pi-exclude "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' '# hide writes' 'mcp__srv__writeTool' 'mcp__srv__adminTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "keep exclusions"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch with exclusions should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/literal")" "--exclude-tools 'mcp__srv__writeTool,mcp__srv__adminTool'" \
    "the relaunched Pi worker must keep the home's tool exclusions"
  rm "$dir/home/config/crew-exclude-tools"
  : > "$dir/fake/literal"
  printf pi > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "exclusions removed"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch after the file is removed should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/literal")" "--exclude-tools" \
    "a relaunch without the file must launch with no exclusions"
  pass "fm-control relaunch: a Pi replacement keeps the home's tool exclusions"
}

test_exclude_tools_refusals_happen_before_the_agent_stops() {
  local dir out rc id=rl-excl-refuse
  dir=$(new_case excl-refuse "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' 'two words' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "bad list"); rc=$?
  expect_code 1 "$rc" "a malformed exclusion list must refuse the relaunch"
  assert_contains "$out" "config/crew-exclude-tools has a malformed entry" "refusal must name the entry"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a malformed exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  printf '%s\n' 'mcp__srv__writeTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --harness codex --note "switch runtime"); rc=$?
  expect_code 1 "$rc" "relaunching onto a runtime that cannot hide tools must refuse"
  assert_contains "$out" "config/crew-exclude-tools" "refusal must name the config file"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an unhonorable exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  pass "fm-control relaunch: exclusion-list refusals happen before the running agent stops"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

# The launch owner refuses a stale replacement model only after the old agent
# has stopped, so the control plane asks the same model freshness verdict first.
# Without a captain pin the running agent stays up and the record is unchanged;
# with the pin naming that model the relaunch swaps to it.
test_stale_replacement_model_refuses_before_stop_unless_pinned() {
  local dir out rc before id=rl-stale
  dir=$(new_case stale-model "$id")
  add_ship_task "$dir" "$id" claude
  sed 's/^model=default$/model=claude-sonnet-5-5/' "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  mkdir -p "$dir/catalogs"
  printf '%s\n' '{"models":[{"id":"claude-sonnet-5"},{"id":"claude-sonnet-5-5"}]}' > "$dir/catalogs/claude.json"
  before=$(cat "$dir/home/state/$id.meta")
  out=$(FM_MODEL_FRESHNESS=1 FM_MODEL_CATALOG_DIR="$dir/catalogs" \
    run_control "$dir" "$id" relaunch --model claude-sonnet-5 --note "move to the older model"); rc=$?
  expect_code 1 "$rc" "a stale replacement model without a captain pin must refuse"$'\n'"$out"
  assert_contains "$out" "refusing to relaunch $id onto a stale model - claude-sonnet-5 on claude is older than claude-sonnet-5-5" \
    "the refusal should name the stale model and the newer one"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused stale relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused stale relaunch sent lifecycle input"
  [ "$before" = "$(cat "$dir/home/state/$id.meta")" ] || fail "a refused stale relaunch must leave the record byte-identical"
  out=$(FM_MODEL_FRESHNESS=1 FM_MODEL_CATALOG_DIR="$dir/catalogs" \
    run_control "$dir" "$id" relaunch --model claude-sonnet-5 --captain-model-pin claude-sonnet-5 \
      --note "the captain asked for the older model"); rc=$?
  expect_code 0 "$rc" "a captain pin naming the stale replacement model must admit the relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" model)" = claude-sonnet-5 ] || fail "the pinned relaunch should record the stale model"
  assert_contains "$(meta_field "$dir" "$id" model_stale)" "claude-sonnet-5 on claude is older than claude-sonnet-5-5 in the claude catalog (admitted by captain pin)" \
    "the pinned relaunch should record the finding as captain-authorized"
  pass "fm-control relaunch: a stale replacement model refuses before the stop unless the captain pins it"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_no_helper_task_refuses_a_harness_switch_before_stopping() {
  local dir out rc id path
  for path in explicit stand-in; do
    id=rl-nohelp
    dir=$(new_case "nohelp-$path" "$id")
    add_ship_task "$dir" "$id" omp
    printf omp > "$dir/fake/command"
    printf omp > "$dir/fake/becomes"
    if [ "$path" = stand-in ]; then
      sed -i.bak -e 's/^model=default$/model=openai-codex\/gpt-6-luna/' -e 's/^effort=default$/effort=high/' "$dir/home/state/$id.meta"
      rm -f "$dir/home/state/$id.meta.bak"
      echo "dispatch_rule=rule_1" >> "$dir/home/state/$id.meta"
      mkdir -p "$dir/home/config"
      printf 'teamclaude\n' > "$dir/home/config/claude-launcher"
      fm_test_fake_teamclaude "$dir/fakebin"
      jq -n '{rules:[{when:"assigned work",use:{harness:"omp",model:"openai-codex/gpt-6-luna",effort:"high"},
        fallback:[{harness:"claude",model:"claude-opus-5-5[1m]",effort:"high",requires:"teamclaude"}]}]}' \
        > "$dir/home/config/crew-dispatch.json"
      jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),
        metadata:{meterStates:{chat:{allowed:false,limitReached:true}}}}]}' > "$dir/usage.json"
      cat > "$dir/fakebin/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'omp/18.1.20\n' ;;
  usage) cat "$FM_FAKE_DIR/../usage.json" ;;
  *) exit 0 ;;
esac
SH
      chmod +x "$dir/fakebin/omp"
    fi
    echo "omp_no_helpers=on" >> "$dir/home/state/$id.meta"
    cp "$dir/home/state/$id.meta" "$dir/prior.meta"
    if [ "$path" = explicit ]; then
      out=$(run_control "$dir" "$id" relaunch --harness codex --note "switch runtime"); rc=$?
    else
      out=$(run_control "$dir" "$id" relaunch --note "quota stand-in"); rc=$?
    fi
    expect_code 1 "$rc" "a no-helper task must refuse a $path harness switch: $out"
    assert_contains "$out" "omp_no_helpers=on" "the $path refusal must name the recorded posture"
    assert_equals omp "$(cat "$dir/fake/command")" "a $path refusal must keep the running omp agent alive"
    [ ! -s "$dir/fake/keys" ] && [ ! -s "$dir/fake/literal" ] || fail "a $path refusal sent lifecycle or launch input"
    cmp -s "$dir/prior.meta" "$dir/home/state/$id.meta" || fail "a $path refusal changed task metadata"
    assert_absent "$dir/home/state/$id.control-relaunch" "a $path refusal must precede the relaunch transaction"
  done
  pass "fm-control relaunch: a no-helper task refuses explicit and stand-in harness switches before the agent stops"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "Firstmate operational input waiting: read" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

test_secondmate_claude_relaunch_keeps_local_settings() {
  local dir home prior settings out rc
  dir=$(new_case smlocal sml)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml"
  printf 'codex\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-local-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$dir/smhome/.claude"
  printf 'sml\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  prior='{"permissions":{"allow":["Bash(echo hi)"]}}'
  printf '%s\n' "$prior" > "$dir/smhome/.claude/settings.local.json"
  printf '%s\n' '{"feedbackDrafts":"on"}' > "$home/state/sml.claude-settings.json"
  printf 'gen=retired\n' > "$dir/smhome/.fm-busy-stop"
  {
    echo "window=fmses:fm-sml"
    echo "endpoint_task_id=sml"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml.meta"
  printf '%s\n' "fm-sml" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml relaunch); rc=$?
  expect_code 0 "$rc" "a claude secondmate relaunch should retire wiring without touching local settings"$'\n'"$out"
  settings="$dir/smhome/.claude/settings.local.json"
  [ "$(cat "$settings")" = "$prior" ] \
    || fail "relaunch rewrote the mate home's settings.local.json"
  [ ! -e "$home/state/sml.claude-settings.json" ] \
    || fail "relaunch left the retired claude settings file in place"
  [ ! -e "$dir/smhome/.fm-busy-stop" ] \
    || fail "relaunch left the retired Stop pointer in the mate home"
  pass "fm-control relaunch: a claude secondmate keeps settings.local.json and retires the state settings file and the Stop pointer"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# A promoted scout records kind=ship and a custom ship branch in its meta, but
# its brief is the scout scaffold: it never gained a Ship branch line, and a
# relaunch cannot regenerate the brief (--branch-prefix is refused there). The
# recorded branch is authoritative, so the relaunch must proceed on it.
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch() {
  local dir out
  dir=$(new_case promotebranch rl42)
  add_ship_task "$dir" rl42 claude
  printf 'branch=fix/rl42\n' >> "$dir/home/state/rl42.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl42 --relaunch)
  assert_contains "$out" "spawned rl42" "the relaunch should complete on the recorded branch"
  assert_contains "$out" "records no ship branch" "the brief gap should be reported, not silent"
  assert_contains "$out" "recorded branch fix/rl42" "the relaunch should name the branch it adopted"
  [ "$(meta_field "$dir" rl42 branch)" = "fix/rl42" ] \
    || fail "the recorded branch must survive the relaunch"
  pass "fm-spawn --relaunch: a promoted scout with a recorded custom branch relaunches on it instead of being refused"
}

test_promoted_scout_relaunch_receives_the_current_delivery_contract() {
  local dir home id brief launch out mode rule
  for mode in no-mistakes direct-PR local-only; do
    id="rl-promoted-${mode}"
    dir=$(new_case "promoted-scout-$mode" "$id")
    home="$dir/home"
    fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
    FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null \
      || fail "$mode: could not scaffold the scout brief"
    brief="$home/data/$id/brief.md"
    sed 's/{TASK}/Fix the promotion relaunch contract./; s/{FIRSTMATE_SPEC}/Preserve the current delivery mode./' \
      "$brief" > "$brief.filled"
    mv "$brief.filled" "$brief"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$dir/wt"
      echo "project=$dir/proj"
      echo "harness=claude"
      echo "kind=scout"
      echo "tasktmp=/tmp/fm-$id"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"

    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: scout promotion should succeed: $out"
    assert_grep 'This is a SCOUT task' "$brief" \
      "$mode: the reproduction fixture lost the original scout delivery text"
    assert_grep 'Never push to any remote and never open a PR' "$brief" \
      "$mode: the reproduction fixture lost the stale scout prohibition"

    printf 'zsh' > "$dir/fake/command"
    out=$(run_spawn "$dir" "$id" --relaunch) \
      || fail "$mode: promoted scout relaunch should succeed: $out"
    launch="$home/data/$id/launch-brief.md"
    assert_grep "This task is now kind=ship with mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the promoted task identity"
    assert_grep 'Any earlier "Never push" or scout-only delivery language in this file is superseded' "$launch" \
      "$mode: the replacement launch left the stale scout prohibition readable at face value"
    case "$mode" in
      direct-PR)
        rule="1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR." ;;
      local-only)
        rule="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`." ;;
      *)
        rule='1. Never push to the default branch. Never merge a PR.' ;;
    esac
    assert_grep "$rule" "$launch" \
      "$mode: the replacement launch did not receive the current ship push and merge safety rule"
    assert_grep "git checkout -b fm/$id" "$launch" \
      "$mode: the replacement launch did not receive its promoted branch name"
    assert_grep 'Inventory this worktree' "$launch" \
      "$mode: the replacement launch did not receive the scratch-state inventory step"
    assert_grep 'Carry over only the intended fix changes' "$launch" \
      "$mode: the replacement launch did not receive the carry-over boundary"
    assert_grep "Delivery contract: mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the actual ship delivery mode"
  done
  pass "fm-promote/fm-spawn --relaunch: the current ship contract supersedes stale scout delivery text"
}

# The task Definition of Done check belongs to a fresh spawn. A relaunch of a
# scaffolded brief whose placeholders are still there, whose DoD file has moved,
# or that predates the section is neither refused nor warned about. A preserved
# pointer-only intent is also exempt from the fresh concrete-ask minimum.
test_relaunch_never_runs_the_task_definition_of_done_check() {
  local variant dir id home brief out
  for variant in placeholders moved-file legacy pointer-only; do
    id="rl-dod-$variant"
    dir=$(new_case "dodrelaunch-$variant" "$id")
    home="$dir/home"
    case "$variant" in
      legacy)
        add_ship_task "$dir" "$id" claude ;;
      *)
        fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
        FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null \
          || fail "$variant: could not scaffold the scout brief"
        brief="$home/data/$id/brief.md"
        sed 's/{TASK}/Exercise the relaunch./; s/{FIRSTMATE_SPEC}/Keep the task whole./' \
          "$brief" > "$brief.filled"
        mv "$brief.filled" "$brief"
        if [ "$variant" = pointer-only ]; then
          cat > "$brief" <<'EOF'
# Task
## Captain's intent
See report.md.
## Firstmate spec
Preserve the already-dispatched task.
EOF
        fi
        if [ "$variant" = moved-file ]; then
          awk -v line="DoD file: $dir/moved-away.md" '{ print } $0 == "## Definition Of Done (task)" { print line }' \
            "$brief" > "$brief.filled"
          mv "$brief.filled" "$brief"
        fi
        {
          echo "window=fmses:fm-$id"
          echo "endpoint_task_id=$id"
          echo "worktree=$dir/wt"
          echo "project=$dir/proj"
          echo "harness=claude"
          echo "kind=scout"
          echo "tasktmp=/tmp/fm-$id"
          echo "model=default"
          echo "effort=default"
        } > "$home/state/$id.meta"
        printf '%s\n' "fm-$id" > "$dir/fake/windows"
        printf '%s' "$dir/wt" > "$dir/fake/cwd"
        TASK_TMPS+=("/tmp/fm-$id") ;;
    esac
    printf 'zsh' > "$dir/fake/command"
    out=$(run_spawn "$dir" "$id" --relaunch) \
      || fail "$variant: the relaunch should succeed: $out"
    assert_contains "$out" "spawned $id" "$variant: the relaunch did not complete"
    assert_not_contains "$out" "Definition Of Done" "$variant: the relaunch ran the task Definition of Done check"
    assert_not_contains "$out" 'has no concrete ask' "$variant: the relaunch re-judged existing intent"
  done
  pass "fm-spawn --relaunch: the task Definition of Done check and its missing-section warning belong to a fresh spawn only"
}

test_relaunch_refuses_scaffold_spec_placeholder() {
  local dir id=rl-spec-placeholder brief out rc
  dir=$(new_case spec-placeholder "$id")
  add_ship_task "$dir" "$id" claude
  brief="$dir/home/data/$id/brief.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
See report.md.
## Firstmate spec
{FIRSTMATE_SPEC}
### Out of scope
- Keep the renderer.
EOF
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" "$id" --relaunch); rc=$?
  expect_code 1 "$rc" 'relaunch must refuse a scaffold spec placeholder'
  assert_contains "$out" '## Firstmate spec still holds {FIRSTMATE_SPEC}' 'relaunch lost the shared placeholder verdict'
  assert_not_contains "$out" 'has no concrete ask' 'relaunch re-judged preserved intent'
  [ "$(cat "$dir/fake/command")" = zsh ] || fail 'unfinished spec launched a replacement'
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
See report.md.
## Firstmate spec
Preserve the already-dispatched task.
### Out of scope
- Keep the renderer.
EOF
  out=$(run_spawn "$dir" "$id" --relaunch) || fail "finished relaunch failed: $out"
  assert_contains "$out" "spawned $id" 'finished relaunch did not launch'
  assert_not_contains "$out" 'has no concrete ask' 'finished relaunch re-judged preserved intent'
  pass 'relaunch rejects a standalone spec placeholder beside scaffold headings without re-judging its ask'
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a task launched
# from a raw command records that command's basename rather than the exact
# adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree, so the launch owner
  # refuses AFTER the previous agent has already been stopped.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "no agent is running" "the failure should say no agent is running"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  [ "$(journal_field "$dir" rl13 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase, got '$(journal_field "$dir" rl13 phase)'"
  [ "$(journal_field "$dir" rl13 rollback)" = "prior-record-kept" ] \
    || fail "the journal should record what the rollback did"
  assert_grep "carry this forward" "$dir/home/data/rl13/brief.md" \
    "the progress note must survive so a later recovery still has it"
  pass "fm-control relaunch: a launch failure after the stop keeps the prior record and reports the real state"
}

test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_pid link_out rc control_rc deadline
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  make_spawn_return_barrier_stub "$dir"
  FM_FAKE_SPAWN_RETURN_READY="$dir/spawn-return-ready" \
    FM_FAKE_SPAWN_RETURN_RELEASE="$dir/spawn-return-release" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  deadline=$((SECONDS + FM_TEST_STUB_MAX_BLOCK_SECONDS))
  while [ ! -s "$dir/spawn-return-ready" ] && [ "$SECONDS" -lt "$deadline" ] && kill -0 "$control_pid" 2>/dev/null; do
    /bin/sleep 0.05
  done
  [ -s "$dir/spawn-return-ready" ] || {
    : > "$dir/spawn-return-release"
    wait_fixture_process "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its post-spawn rollback barrier: $(cat "$dir/control.out")"
  }
  if [ "$(cat "$dir/spawn-return-ready")" != 1 ] \
     || [ -e "$dir/home/state/.meta-rl30.lock" ] \
     || [ "$(journal_field "$dir" rl30 phase)" != launching ]; then
    : > "$dir/spawn-return-release"
    wait_fixture_process "$control_pid" 2>/dev/null || true
    fail "spawn did not fail and release its metadata lock before rollback: $(cat "$dir/control.out")"
  fi
  # shellcheck disable=SC2031 # A fixture subshell's PATH change does not reach this parent.
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  wait_fixture_process "$link_pid"; rc=$?
  link_out=$(cat "$dir/link.out")
  : > "$dir/spawn-return-release"
  wait_fixture_process "$control_pid"; control_rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  expect_code 1 "$control_rc" "the staged pre-publication launch failure should fail closed"
  assert_absent "$dir/spawn-return-ready.expired" \
    "rollback must wait for publication by release, not by fixture timeout"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(journal_field "$dir" rl30 rollback)" = prior-record-kept ] \
    || fail "pre-publication rollback should leave the live record untouched"
  pass "fm-control relaunch: unpublished rollback keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  dir=$(new_case symlink-meta rl37)
  add_ship_task "$dir" rl37 claude
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$dir/relaunch-endpoint-inspected"
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  assert_absent "$dir/relaunch-endpoint-inspected" \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_keeps_its_early_meta_lock_continuous() {
  local dir lock out rc
  dir=$(new_case continuous-meta-lock rl38)
  add_ship_task "$dir" rl38 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.meta-rl38.lock"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -d "$lock" ]; then
  if [ ! -e "$dir/lock-observation-started" ]; then
    : > "$dir/lock-observation-started"
    : > "$lock/continuity-sentinel"
  elif [ ! -e "$lock/continuity-sentinel" ]; then
    : > "$dir/meta-lock-was-recreated"
  fi
fi
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with one continuous meta lock should succeed"$'\n'"$out"
  assert_present "$dir/lock-observation-started" \
    "test did not observe the relaunch-held meta lock"
  assert_absent "$dir/meta-lock-was-recreated" \
    "relaunch released or recreated its already-held meta lock"
  pass "fm-spawn --relaunch: keeps its early meta lock continuous"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  dir=$(new_case pending-close rl36)
  add_ship_task "$dir" rl36 claude
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  mkdir -p "$dir/wt/.claude"
  printf 'prior wiring\n' > "$dir/wt/.claude/settings.local.json"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl36 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/wt/.claude/settings.local.json" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  [ ! -s "$dir/fake/keys" ] || fail "a refused tmux relaunch must send nothing to the pane"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding its work"
}

test_spawn_relaunch_moves_a_pane_left_in_a_prior_copy() {
  local dir out rc
  dir=$(new_case priorcwd rl18b)
  add_ship_task "$dir" rl18b claude
  mkdir -p "$dir/prior"
  printf 'prior_worktree=%s\n' "$dir/prior" >> "$dir/home/state/rl18b.meta"
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/prior" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18b --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a pane left in the task's own prior copy should be moved into the recorded worktree"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  [ "$(meta_field "$dir" rl18b worktree)" = "$dir/wt" ] || fail "the recorded worktree must survive the relaunch"
  pass "fm-spawn --relaunch: a pane left in the task's prior copy is moved into the recorded copy before the replacement starts"
}

test_spawn_relaunch_moves_a_pane_left_in_a_released_copy() {
  local dir out rc
  dir=$(new_case releasedcwd rl18c)
  add_ship_task "$dir" rl18c claude
  mkdir -p "$dir/released"
  printf 'released_worktree=%s\n' "$dir/released" >> "$dir/home/state/rl18c.meta"
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/released" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18c --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "a pane left in the copy whose pool slot the move released should be moved into the recorded worktree"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  pass "fm-spawn --relaunch: a pane left in a released copy is moved into the recorded copy before the replacement starts"
}

test_spawn_relaunch_still_refuses_a_pane_in_an_unrecorded_copy() {
  local dir out rc
  dir=$(new_case strangecwd rl18d)
  add_ship_task "$dir" rl18d claude
  mkdir -p "$dir/released" "$dir/stranger"
  printf 'released_worktree=%s\n' "$dir/released" >> "$dir/home/state/rl18d.meta"
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/stranger" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18d --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane in a path the record never named must still be refused"
  assert_contains "$out" "not its recorded worktree" "the refusal must name the drift"
  pass "fm-spawn --relaunch: a pane in an unrecorded path is still refused"
}

if [ "${1:-}" = --jev-guard ]; then
  test_relaunch_appends_the_progress_note_to_the_instructions
  test_relaunch_announces_surviving_inbox_records
  test_relaunch_preserves_guard_cutover
  exit 0
fi

control_relaunch_test_cases=(
test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_relaunch_refuses_unsupported_omp_before_stopping
test_relaunch_refuses_contradictory_dsh_route_before_stopping
test_secondmate_config_dsh_relaunch_carries_own_session_model
test_relaunch_omp_billing_admission_preserves_running_agents
test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text
test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_relaunch_keeps_a_recorded_pr_parseable_for_monitoring
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop
test_model_index_resolves_and_refuses_before_stop
test_model_index_generation_survives_account_checks_and_replacement
test_unpinned_indexed_relaunch_does_not_query_the_supervisor_account
test_signed_out_worker_account_pin_refuses_before_stop
test_worker_account_pin_follows_the_relaunch
test_recorded_api_key_opt_in_follows_the_relaunch
test_api_key_guard_refuses_before_stop
test_api_key_guard_uses_replacement_profile
test_api_key_guard_refuses_tmux_key_before_stop
test_spawn_relaunch_without_the_opt_in_drops_the_recorded_api_key
test_pi_exclude_tools_follow_the_relaunch
test_exclude_tools_refusals_happen_before_the_agent_stops
test_explicit_model_wins_over_the_recorded_one
test_stale_replacement_model_refuses_before_stop_unless_pinned
test_relaunch_onto_an_unverified_harness_is_refused
test_no_helper_task_refuses_a_harness_switch_before_stopping
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_claude_relaunch_keeps_local_settings
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch
test_promoted_scout_relaunch_receives_the_current_delivery_contract
test_relaunch_never_runs_the_task_definition_of_done_check
test_relaunch_refuses_scaffold_spec_placeholder
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_missing_worktree_refuses_before_stopping_anything
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_journal_records_the_checkpoint_it_proved
test_spawn_relaunch_refuses_a_live_agent
test_relaunch_announces_surviving_inbox_records
test_relaunch_preserves_guard_cutover
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_keeps_its_early_meta_lock_continuous
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_spawn_relaunch_moves_a_pane_left_in_a_prior_copy
test_spawn_relaunch_moves_a_pane_left_in_a_released_copy
test_spawn_relaunch_still_refuses_a_pane_in_an_unrecorded_copy
)

control_relaunch_run "$@"
