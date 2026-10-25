#!/usr/bin/env bash
# Recovery and relocation for bin/fm-control.sh relaunch: a task whose endpoint
# is gone, a task whose recorded worktree is gone, Herdr reclaim and rebind, and
# the held/dependency/continuation authorization matrix.
# The core relaunch contract lives in tests/fm-control-relaunch.test.sh; the
# backend, TeamClaude, reboot-recovery, and quota surfaces live in
# tests/fm-control-relaunch-backends.test.sh.
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"

# (a) The recorded endpoint is gone while unrelated tmux servers keep running:
# the lsof fixture always lists unrelated processes, and a user's unrelated
# servers can never be shown absent, so none of them may block this task.
test_tmux_gone_endpoint_is_proven_despite_unrelated_servers() {
  local dir shape id out rc wt head_before
  command -v jq >/dev/null 2>&1 || { echo 'skip - configured Herdr reclaim needs jq'; return; }
  for shape in window-absent session-missing server-dead shell-in-worktree; do
    id="rl90${shape//-/}"
    dir=$(new_case "tmux-scoped-$shape" "$id")
    wt="$dir/wt-café\\lane"
    add_ship_task "$dir" "$id" claude fmses "$wt"
    prepare_herdr_reclaim "$dir"
    if [ "$shape" = shell-in-worktree ]; then
      # An idle shell in the copy is the pane's own leftover, not an agent.
      stage_gone "$dir" "$id" window-absent
      stage_holder "$dir" zsh -zsh "$wt/sub"
    else
      stage_gone "$dir" "$id" "$shape"
    fi
    head_before=$(git -C "$wt" rev-parse HEAD)
    printf 'unlanded content\n' > "$wt/dirty.txt"
    printf 'working: preserved history\n' > "$dir/home/state/$id.status"

    mkdir -p "$wt/sub"
    out=$(cd "$wt/sub" && run_control "$dir" "$id" exit); rc=$?
    expect_code 0 "$rc" "a gone recorded endpoint must be proven despite unrelated tmux servers ($shape)"$'\n'"$out"
    assert_contains "$out" endpoint-gone "exit should report proven absence ($shape)"
    rm -f "$dir/fake/list-count"
    out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --note "resume after reboot"); rc=$?
    expect_code 0 "$rc" "relaunch must proceed for a gone recorded endpoint ($shape)"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" backend)" = herdr ] || fail "reclaim did not publish Herdr ($shape)"
    [ "$(meta_field "$dir" "$id" worktree)" = "$wt" ] || fail "reclaim changed the local copy ($shape)"
    [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "reclaim moved the branch head ($shape)"
    [ "$(cat "$wt/dirty.txt")" = "unlanded content" ] || fail "reclaim lost uncommitted work ($shape)"
    assert_contains "$(cat "$dir/home/state/$id.status")" "preserved history" "reclaim truncated status ($shape)"
    assert_absent "$dir/fake/created-windows" "reclaim created a tmux endpoint ($shape)"
    assert_absent "$dir/fake/created-sessions" "reclaim started a tmux server ($shape)"
    assert_present "$dir/fake/herdr-created-tabs" "reclaim did not create the Herdr endpoint ($shape)"
  done
  pass "tmux: a gone recorded endpoint is proven and reclaimed while unrelated tmux servers run"
}

# Keep the real process snapshot: a canned lsof table cannot expose a vanished
# command-substitution shell inheriting the recovery caller's working directory.
test_tmux_worktree_local_recovery_with_real_lsof() {
  local dir id entry location wt out rc head_before
  command -v lsof >/dev/null 2>&1 || { echo 'skip - worktree-local recovery needs lsof'; return; }
  command -v jq >/dev/null 2>&1 || { echo 'skip - configured Herdr reclaim needs jq'; return; }
  for entry in relaunch reconcile-only direct; do
    if [ "$entry" = reconcile-only ] && ! fm_tasks_axi_compatible; then
      echo 'skip - reconciliation-only recovery needs compatible tasks-axi'
      continue
    fi
    for location in root descendant; do
      id="rlprobe-$entry-$location"
      dir=$(new_case "$id" "$id")
      wt="$dir/wt-café\\lane"
      add_ship_task "$dir" "$id" claude fmses "$wt"
      stage_gone "$dir" "$id" window-absent
      prepare_herdr_reclaim "$dir"
      rm "$dir/fakebin/lsof"
      mkdir -p "$wt/sub"
      head_before=$(git -C "$wt" rev-parse HEAD)
      printf 'unlanded content\n' > "$wt/dirty.txt"
      [ "$entry" != reconcile-only ] || seed_backlog "$dir" "$id" in_flight
      [ "$location" != descendant ] || wt="$wt/sub"

      out=$(cd "$wt" && run_control "$dir" "$id" exit); rc=$?
      expect_code 0 "$rc" "real lsof must prove exit from the worktree $location"$'\n'"$out"
      assert_contains "$out" endpoint-gone "exit must prove the recorded endpoint gone"
      case "$entry" in
        relaunch)
          out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --note "resume after reboot"); rc=$?
          ;;
        reconcile-only)
          out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --reconcile-only --note "restore instruction owner"); rc=$?
          ;;
        direct)
          out=$(cd "$wt" && FM_FAKE_SESSION=fmlab run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
          ;;
      esac
      expect_code 0 "$rc" "real lsof must permit $entry from the worktree $location"$'\n'"$out"
      wt=$(meta_field "$dir" "$id" worktree)
      [ "$(meta_field "$dir" "$id" backend)" = herdr ] || fail "$entry did not reclaim on Herdr"
      [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "$entry moved the branch head"
      [ "$(cat "$wt/dirty.txt")" = "unlanded content" ] || fail "$entry lost uncommitted work"
      if [ "$entry" = reconcile-only ]; then
        [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "recovery lost its reconciliation-only scope"
        [ "$(backlog_state "$dir" "$id")" = in_flight ] || fail "recovery changed the backlog state"
      fi
      assert_present "$dir/fake/herdr-created-tabs" "$entry did not create the replacement endpoint"
      assert_absent "$dir/fake/created-windows" "$entry created a tmux endpoint"
    done
  done
  pass "tmux: real lsof permits worktree-local exit, relaunch, reconciliation and direct replacement"
}

# (b) The recorded endpoint may still be live: the window answers, or an agent
# still holds the worktree (its window can sit on a socket this process does
# not address). Either refuses both verbs.
test_tmux_refuses_while_the_recorded_endpoint_may_be_live() {
  local dir shape id wt
  for shape in window-answers-first window-answers-second agent-in-worktree agent-in-subdirectory gemini-agent-in-worktree gemini-spaced-script-in-worktree; do
    id="rl91${shape//-/}"
    dir=$(new_case "tmux-live-$shape-café\\lane" "$id")
    add_ship_task "$dir" "$id"
    stage_gone "$dir" "$id" window-absent
    wt=$(meta_field "$dir" "$id" worktree)
    case "$shape" in
      window-answers-first) printf 'fm-%s\n' "$id" > "$dir/fake/late-window"; printf 1 > "$dir/fake/late-window-after" ;;
      window-answers-second) printf 'fm-%s\n' "$id" > "$dir/fake/late-window"; printf 2 > "$dir/fake/late-window-after" ;;
      agent-in-worktree) stage_holder "$dir" /usr/local/bin/claude 'claude --resume' "$wt" ;;
      agent-in-subdirectory) stage_holder "$dir" claude claude "$wt/src/deep" ;;
      gemini-agent-in-worktree) stage_holder "$dir" MainThread 'node /home/u/.local/bin/gemini -y' "$wt" ;;
      gemini-spaced-script-in-worktree) stage_holder "$dir" MainThread 'node /Users/person/path with spaces/bin/gemini -y' "$wt" ;;
    esac
    assert_tmux_missing_refuses "$dir" "$id" "$shape"
  done
  pass "tmux: an answering window or an agent holding the worktree refuses both verbs"
}

# (c) Evidence that cannot be read is never evidence of absence.
test_tmux_unreadable_evidence_refuses() {
  local dir shape id wt
  for shape in lsof-fails lsof-partial lsof-record-without-cwd lsof-cwd-error lsof-empty-cwd lsof-relative-cwd lsof-blind holder-unreadable holder-unattributed holder-identity-disagrees inventory-unreadable-first inventory-unreadable-second; do
    id="rl92${shape//-/}"
    dir=$(new_case "tmux-unreadable-$shape" "$id")
    add_ship_task "$dir" "$id"
    stage_gone "$dir" "$id" window-absent
    wt=$(meta_field "$dir" "$id" worktree)
    case "$shape" in
      lsof-fails) printf broken > "$dir/fake/lsof-mode" ;;
      lsof-partial) printf partial > "$dir/fake/lsof-mode" ;;
      lsof-record-without-cwd) stage_holder "$dir" claude claude "$wt"; printf nocwd > "$dir/fake/lsof-mode" ;;
      lsof-cwd-error) stage_holder "$dir" claude claude 'cwd|rtd info error: Permission denied' ;;
      lsof-empty-cwd) stage_holder "$dir" claude claude '' ;;
      lsof-relative-cwd) stage_holder "$dir" claude claude 'relative/directory' ;;
      lsof-blind) printf empty > "$dir/fake/lsof-mode" ;;
      holder-unreadable)
        # A live holder (this very shell) whose name and command line cannot be read.
        stage_holder "$dir" '' '' "$wt"
        printf '%s' "$$" > "$dir/fake/holder-pid"
        ;;
      holder-unattributed) stage_holder "$dir" node 'node /Users/person/project/server.js' "$wt" ;;
      holder-identity-disagrees) stage_holder "$dir" bash 'node /Users/person/project/server.js' "$wt/src/deep" ;;
      inventory-unreadable-first) printf 1 > "$dir/fake/broken-after" ;;
      inventory-unreadable-second) printf 2 > "$dir/fake/broken-after" ;;
    esac
    assert_tmux_missing_refuses "$dir" "$id" "$shape"
  done
  pass "tmux: an unreadable process table or tmux answer refuses both verbs"
}

test_tmux_no_server_reclaim_keeps_work_and_task() {
  local dir second out rc head_before mode id wt first_id second_id first_endpoint
  command -v jq >/dev/null 2>&1 || { echo 'skip - configured Herdr reclaim needs jq'; return; }
  for mode in server-dead session-missing; do
    first_id="rl82${mode}a"
    second_id="rl82${mode}b"
    dir=$(new_case "tmux-sequential-reclaim-$mode" "$first_id")
    second=$(new_case "tmux-second-$mode" "$second_id")
    add_ship_task "$dir" "$first_id"
    add_ship_task "$second" "$second_id"
    cp "$second/home/state/$second_id.meta" "$dir/home/state/$second_id.meta"
    mkdir -p "$dir/home/data/$second_id"
    cp "$second/home/data/$second_id/brief.md" "$dir/home/data/$second_id/brief.md"
    make_herdr_stub "$dir"
    : > "$dir/fake/$mode"
    : > "$dir/fake/stale-socket"
    printf '%%none' > "$dir/fake/herdr-pane"
    : > "$dir/fake/herdr-log"
    : > "$dir/fake/herdr-stopped"
    mkdir -p "$dir/home/config"
    printf herdr > "$dir/home/config/backend"
    first_endpoint=
    for id in "$first_id" "$second_id"; do
      wt=$(meta_field "$dir" "$id" worktree)
      head_before=$(git -C "$wt" rev-parse HEAD)
      printf 'unlanded content\n' > "$wt/dirty.txt"
      printf 'working: preserved history\n' > "$dir/home/state/$id.status"
      printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/$id.check.sh"
      chmod 0700 "$dir/home/state/$id.check.sh"
      FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null || fail "cannot arm reclaim check"
      out=$(run_control "$dir" "$id" exit); rc=$?
      expect_code 0 "$rc" "no user tmux server should prove exit for $id"$'\n'"$out"
      assert_contains "$out" endpoint-gone "exit should report proven absence"
      out=$(FM_FAKE_SESSION=fmlab run_control "$dir" "$id" relaunch --note "resume after reboot"); rc=$?
      expect_code 0 "$rc" "no user tmux server should permit Herdr reclaim for $id"$'\n'"$out"
      [ "$(meta_field "$dir" "$id" backend)" = herdr ] || fail "reclaim did not publish Herdr"
      [ "$(meta_field "$dir" "$id" endpoint_task_id)" = "$id" ] || fail "reclaim changed task identity"
      [ "$(meta_field "$dir" "$id" worktree)" = "$wt" ] || fail "reclaim changed the local copy"
      [ "$(git -C "$wt" rev-parse HEAD)" = "$head_before" ] || fail "reclaim moved the branch head"
      [ "$(git -C "$wt" symbolic-ref --short HEAD)" = "task-$id" ] || fail "reclaim switched branches"
      [ "$(cat "$wt/dirty.txt")" = "unlanded content" ] || fail "reclaim lost uncommitted work"
      assert_present "$dir/home/state/$id.check-trust" "reclaim broke armed poll registration"
      assert_contains "$(cat "$dir/home/state/$id.status")" "preserved history" "reclaim truncated status"
      assert_contains "$(cat "$dir/home/data/$id/brief.md")" "resume after reboot" "reclaim omitted note"
      assert_absent "$dir/fake/created-windows" "Herdr reclaim created a tmux endpoint"
      assert_absent "$dir/fake/created-sessions" "Herdr reclaim started a tmux server"
      if [ "$id" = "$first_id" ]; then
        first_endpoint=$(meta_field "$dir" "$id" window)
        [ "$first_endpoint" = 'fmlab:%9' ] || fail "first replacement has the wrong binding"
      else
        [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%10' ] || fail "second replacement has the wrong binding"
      fi
    done
    [ "$(meta_field "$dir" "$first_id" window)" = "$first_endpoint" ] || fail "second reclaim rebound the first task"
    [ "$(wc -l < "$dir/fake/herdr-created-tabs" | tr -d ' ')" = 2 ] || fail "reclaim did not create exactly two tabs"
    for id in "$first_id" "$second_id"; do
      out=$(run_control "$dir" "$id" interrupt); rc=$?
      expect_code 0 "$rc" "both replacement agents must remain reachable and alive"$'\n'"$out"
    done
  done
  pass "tmux: two missing tasks reclaim sequentially onto Herdr, preserving work, note and poll"
}

test_tmux_reclaim_refuses_other_configured_backends() {
  local dir backend out rc before brief_before
  for backend in tmux zellij cmux orca unknown; do
    dir=$(new_case "tmux-reclaim-$backend" "rl84$backend")
    add_ship_task "$dir" "rl84$backend"
    : > "$dir/fake/server-dead"
    mkdir -p "$dir/home/config"
    printf '%s' "$backend" > "$dir/home/config/backend"
    before=$(cat "$dir/home/state/rl84$backend.meta")
    brief_before=$(cat "$dir/home/data/rl84$backend/brief.md")
    out=$(run_spawn "$dir" "rl84$backend" --relaunch); rc=$?
    expect_code 1 "$rc" "direct reclaim must refuse configured $backend"$'\n'"$out"
    out=$(run_control "$dir" "rl84$backend" relaunch --note "resume"); rc=$?
    expect_code 1 "$rc" "control reclaim must refuse configured $backend"$'\n'"$out"
    [ "$(cat "$dir/home/state/rl84$backend.meta")" = "$before" ] || fail "refused reclaim changed binding"
    assert_contains "$(cat "$dir/home/data/rl84$backend/brief.md")" "$brief_before" "refused reclaim lost prior instructions"
    assert_absent "$dir/fake/created-windows" "refused reclaim created a tmux endpoint"
    assert_absent "$dir/fake/created-sessions" "refused reclaim started a tmux server"
    assert_absent "$dir/fake/herdr-created-tabs" "refused reclaim created a Herdr endpoint"
    [ ! -s "$dir/fake/literal" ] || fail "refused reclaim delivered launch input"
  done
  pass "tmux: a proven-gone endpoint refuses every configured backend other than Herdr"
}

test_reclaim_refuses_an_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case gone-unreadable rl63)
  add_ship_task "$dir" rl63 claude
  # The inventory itself fails non-definitively. That is not evidence of
  # absence, and reading it as one is exactly how two agents end up in one
  # endpoint.
  : > "$dir/fake/inventory-broken"

  out=$(run_spawn "$dir" rl63 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an unreadable endpoint must still refuse"
  assert_contains "$out" "positively agent-free endpoint" \
    "only a POSITIVELY proven agent-free endpoint may be relaunched into"
  assert_absent "$dir/fake/created-windows" \
    "a refused relaunch must not create an endpoint"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must launch nothing"
  pass "reclaim: an unclassifiable endpoint is still refused, so two agents cannot share one"
}

test_relocation_rebinds_a_vanished_worktree_to_a_fresh_copy() {
  local dir out rc id=rl100
  dir=$(new_case relocate-valid "$id")
  make_relocation_case "$dir" "$id"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "the old copy vanished"); rc=$?
  expect_code 0 "$rc" "a vanished copy must relocate onto a fresh copy of its branch"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "the record was not rebound to the fresh copy"
  [ "$(meta_field "$dir" "$id" branch)" = "task-$id" ] || fail "relocation changed the recorded branch"
  [ "$(meta_field "$dir" "$id" endpoint_task_id)" = "$id" ] || fail "relocation changed the task identity"
  [ "$(meta_field "$dir" "$id" window)" = "fmses:fm-$id" ] || fail "relocation moved the endpoint"
  [ "$(git -C "$dir/th/1/dest" rev-parse HEAD)" = "$(cat "$dir/committed-head")" ] || fail "the fresh copy lost committed work"
  [ -z "$(git -C "$dir/th/1/dest" status --porcelain)" ] || fail "relocation left the fresh copy dirty"
  assert_present "$dir/th/1/dest/.claude/settings.local.json" "the replacement was not wired in the fresh copy"
  assert_grep "cd -- '$dir/th/1/dest'" "$dir/fake/keys" "the replacement launched outside the fresh copy"
  assert_contains "$(cat "$dir/home/state/$id.status")" "preserved history" "relocation truncated the status log"
  assert_grep "the old copy vanished" "$dir/home/data/$id/brief.md" "relocation dropped the progress note"
  assert_grep "proven absent" "$dir/home/data/$id/brief.md" "the note must tell the worker its copy was replaced"
  [ "$(journal_field "$dir" "$id" phase)" = complete ] || fail "relocation did not complete its journal"
  [ "$(journal_field "$dir" "$id" relocation_from)" = "$dir/wt" ] || fail "the journal lost the vanished path"
  [ "$(journal_field "$dir" "$id" relocation_to)" = "$dir/th/1/dest" ] || fail "the journal lost the fresh copy"
  [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] || fail "the journal lost the recorded head"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = meta-pr_head ] || fail "the journal must name every recorded source it checked"
  [ "$(cat "$dir/fake/cwd")" = "$dir/th/1/dest" ] || fail "the idle shell was not moved from the vanished path"
  pass "relocation: a vanished copy rebinds to a fresh copy of its branch, keeping identity, endpoint, status and note"
}

test_relocation_checks_every_recorded_head_and_requires_evidence() {
  local dir id out rc variant source
  for variant in registered journal pr-head all; do
    id="rl101$variant"
    dir=$(new_case "relocate-evidence-$variant" "$id")
    if [ "$variant" = registered ] || [ "$variant" = all ]; then
      make_relocation_case "$dir" "$id" keep-registration
    else
      make_relocation_case "$dir" "$id"
    fi
    case "$variant" in
      registered) source="registered-worktree,meta-pr_head" ;;
      journal)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" > "$dir/home/state/$id.control-relaunch"
        source=journal-worktree_head,meta-pr_head
        ;;
      pr-head) source="meta-pr_head" ;;
      all)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" > "$dir/home/state/$id.control-relaunch"
        source="registered-worktree,journal-worktree_head,meta-pr_head"
        ;;
    esac
    out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
    expect_code 0 "$rc" "a copy containing the recorded head must relocate ($variant)"$'\n'"$out"
    [ "$(journal_field "$dir" "$id" relocation_head_source)" = "$source" ] \
      || fail "the journal named '$(journal_field "$dir" "$id" relocation_head_source)', not $source ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] \
      || fail "the proof did not record the copy's HEAD ($variant)"
  done

  # A branch moved BACK to an older commit (a reset while recreating the copy)
  # silently drops the task's commits. Every recorded head must catch that.
  for variant in registered journal journal-pr journal-relocation; do
    id="rl102$variant"
    dir=$(new_case "relocate-reset-$variant" "$id")
    if [ "$variant" = registered ]; then
      make_relocation_case "$dir" "$id" keep-registration
    else
      make_relocation_case "$dir" "$id"
    fi
    [ "$variant" = journal-pr ] || set_case_meta_field "$dir" "$id" pr_head "$(cat "$dir/first-head")"
    case "$variant" in
      journal)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/committed-head")" > "$dir/home/state/$id.control-relaunch"
        ;;
      journal-pr)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" > "$dir/home/state/$id.control-relaunch"
        ;;
      journal-relocation)
        printf 'task=%s\nworktree=%s\nworktree_head=%s\nrelocation_to=%s\nrelocation_head=%s\n' \
          "$id" "$dir/wt" "$(cat "$dir/first-head")" "$dir/wt" "$(cat "$dir/committed-head")" > "$dir/home/state/$id.control-relaunch"
        ;;
    esac
    git -C "$dir/th/1/dest" reset -q --hard "$(cat "$dir/first-head")"
    run_relocation_refusal "$dir" "$id" "does not contain" "branch reset behind the recorded head ($variant)"
  done
  id=rl102nohead
  dir=$(new_case relocate-no-head "$id")
  make_relocation_case "$dir" "$id"
  set_case_meta_field "$dir" "$id" pr_head ""
  run_relocation_refusal "$dir" "$id" "no recorded head exists" "no surviving recorded head"
  run_relocation_refusal "$dir" "$id" "run 'treehouse get' (without -b) from" "no-head refusal names the lease allocation"
  run_relocation_refusal "$dir" "$id" "git checkout --ignore-other-worktrees task-$id" "no-head refusal names the checkout past the kept registration"
  run_relocation_refusal "$dir" "$id" "do not run 'git worktree prune' first" "no-head refusal warns against pruning"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
  expect_code 1 "$rc" "relocation must refuse (no-head remedy)"$'\n'"$out"
  assert_contains "$out" "pr_head=<sha>, into the task record" "no-head refusal must name the pr_head= route"
  assert_not_contains "$out" "worktree_head=" "no-head refusal must not name the journal worktree_head= hint"
  id=rl102noheadpr
  dir=$(new_case relocate-no-head-pr "$id")
  make_relocation_case "$dir" "$id"
  set_case_meta_field "$dir" "$id" pr_head ""
  set_case_meta_field "$dir" "$id" pr "https://github.com/example/repo/pull/7"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
  expect_code 1 "$rc" "relocation must refuse (no-head remedy with a recorded PR)"$'\n'"$out"
  assert_contains "$out" "task=$id, worktree=$dir/wt, worktree_head=<sha> into the control journal $dir/home/state/$id.control-relaunch" \
    "no-head refusal for a task with a PR must name the three journal lines"
  assert_not_contains "$out" "pr_head=" "no-head refusal must not tell a task with a PR to hand-write pr_head="
  printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/committed-head")" > "$dir/home/state/$id.control-relaunch"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
  expect_code 0 "$rc" "the named journal lines must let a task with a PR relocate"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = journal-worktree_head ] \
    || fail "the journal remedy was not the checked source ($(journal_field "$dir" "$id" relocation_head_source))"
  pass "relocation: every surviving recorded head must be contained, and no evidence refuses"
}

test_relocation_refuses_unreadable_head_evidence() {
  local dir id variant locked common admin fragment out rc before brief_before journal_before
  local -a args
  [ "$(id -u)" != 0 ] || { echo "skip - unreadable head evidence needs a non-root user"; return; }
  for variant in registration reflog journal journal-ordinary; do
    id="rl110${variant//-/}"
    dir=$(new_case "relocate-unreadable-$variant" "$id")
    locked=
    journal_before=
    if [ "$variant" = journal-ordinary ]; then
      add_ship_task "$dir" "$id"
      printf zsh > "$dir/fake/command"
    else
      make_relocation_case "$dir" "$id" keep-registration
      set_case_meta_field "$dir" "$id" pr_head "$(cat "$dir/first-head")"
      git -C "$dir/th/1/dest" reset -q --hard "$(cat "$dir/first-head")"
    fi
    case "$variant" in
      registration|reflog)
        common=$(git -C "$dir/proj" rev-parse --path-format=absolute --git-common-dir)
        for admin in "$common"/worktrees/*; do
          [ "$(cat "$admin/gitdir")" = "$dir/wt/.git" ] || continue
          if [ "$variant" = registration ]; then
            locked="$admin/gitdir"
            fragment="worktree registration"
          else
            locked="$admin/logs/HEAD"
            fragment="recorded worktree reflog"
          fi
          break
        done
        [ -n "$locked" ] || fail "the vanished worktree registration was not retained"
        ;;
      journal*)
        locked="$dir/home/state/$id.control-relaunch"
        if [ "$variant" = journal ]; then
          printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/committed-head")" > "$locked"
        else
          printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(git -C "$dir/wt" rev-parse HEAD)" > "$locked"
        fi
        journal_before=$(cat "$locked")
        fragment="control journal"
        ;;
    esac
    before=$(cat "$dir/home/state/$id.meta")
    brief_before=$(cat "$dir/home/data/$id/brief.md")
    chmod 000 "$locked"
    args=("$id" relaunch --note "resume")
    [ "$variant" = journal-ordinary ] || args+=(--worktree "$dir/th/1/dest")
    out=$(run_control "$dir" "${args[@]}"); rc=$?
    expect_code 1 "$rc" "control must refuse unreadable historical evidence ($variant)"$'\n'"$out"
    assert_contains "$out" "$fragment" "control refused for the wrong reason ($variant)"
    if [ "$variant" != journal-ordinary ]; then
      out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
      expect_code 1 "$rc" "direct spawn must refuse unreadable historical evidence ($variant)"$'\n'"$out"
      assert_contains "$out" "$fragment" "direct spawn refused for the wrong reason ($variant)"
    fi
    chmod 644 "$locked"
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "unreadable evidence refusal changed the record ($variant)"
    [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] || fail "unreadable evidence refusal changed the instructions ($variant)"
    if [ -n "$journal_before" ]; then
      [ "$(cat "$dir/home/state/$id.control-relaunch")" = "$journal_before" ] || fail "unreadable journal was overwritten ($variant)"
    else
      assert_absent "$dir/home/state/$id.control-relaunch" "unreadable evidence refusal wrote a journal ($variant)"
    fi
    [ ! -s "$dir/fake/literal" ] || fail "unreadable evidence refusal launched a worker ($variant)"
  done
  pass "relocation: unreadable registrations, reflogs and journals refuse without discarding evidence"
}

test_relocation_refuses_every_unsafe_destination() {
  local dir id variant fragment root_uid foreign
  root_uid=$(id -u)
  for variant in present dangling-symlink unreadable-ancestry branch detached head-unrelated head-missing head-malformed \
      owned owned-alias other-repo primary subdir dirty scout secondmate relative missing-dest same-as-recorded; do
    id="rl103${variant//-/}"
    dir=$(new_case "relocate-refuse-$variant" "$id")
    make_relocation_case "$dir" "$id"
    fragment=
    case "$variant" in
      present) mkdir "$dir/wt"; fragment="still exists" ;;
      dangling-symlink) ln -s "$dir/nowhere" "$dir/wt"; fragment="still exists" ;;
      unreadable-ancestry)
        [ "$root_uid" != 0 ] || { echo "skip - unreadable ancestry needs a non-root user"; continue; }
        mkdir -p "$dir/locked"
        set_case_meta_field "$dir" "$id" worktree "$dir/locked/wt"
        chmod 000 "$dir/locked"
        fragment="cannot be proven"
        ;;
      branch) git -C "$dir/th/1/dest" checkout -q -b elsewhere; fragment="does not equal the recorded branch" ;;
      detached) git -C "$dir/th/1/dest" checkout -q --detach; fragment="does not equal the recorded branch" ;;
      head-unrelated)
        foreign=$(printf 'unrelated\n' | git -C "$dir/proj" -c user.name=t -c user.email=t@example.com commit-tree "$(git -C "$dir/proj" rev-parse 'HEAD^{tree}')")
        set_case_meta_field "$dir" "$id" pr_head "$foreign"
        fragment="does not contain"
        ;;
      head-missing)
        set_case_meta_field "$dir" "$id" pr_head 0123456789abcdef0123456789abcdef01234567
        fragment="not in the repository"
        ;;
      head-malformed) set_case_meta_field "$dir" "$id" pr_head not-a-commit; fragment="full commit id" ;;
      owned) printf 'worktree=%s\n' "$dir/th/1/dest" > "$dir/home/state/other.meta"; fragment="recorded by another task" ;;
      owned-alias)
        ln -s "$dir/th/1/dest" "$dir/alias"
        printf 'worktree=%s\n' "$dir/alias" > "$dir/home/state/other.meta"
        fragment="recorded by another task"
        ;;
      other-repo)
        fm_git_worktree "$dir/foreign-proj" "$dir/foreign-wt" "task-$id"
        fragment="same repository"
        ;;
      primary) fragment="isolated worktree" ;;
      subdir) mkdir "$dir/th/1/dest/subdir"; fragment="not a worktree root" ;;
      dirty) printf 'someone else\n' > "$dir/th/1/dest/stray.txt"; fragment="uncommitted changes" ;;
      scout) set_case_meta_field "$dir" "$id" kind scout; fragment="ships only" ;;
      secondmate)
        set_case_meta_field "$dir" "$id" kind secondmate
        mkdir -p "$dir/home/config"
        printf 'claude\n' > "$dir/home/config/secondmate-harness"
        fragment="ships only"
        ;;
      relative) fragment="absolute path" ;;
      missing-dest) fragment="not a readable directory" ;;
      same-as-recorded) fragment="still exists" ;;
    esac
    case "$variant" in
      other-repo) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/foreign-wt" ;;
      primary) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/proj" ;;
      subdir) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/th/1/dest/subdir" ;;
      relative) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "dest" ;;
      missing-dest) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/nope" ;;
      same-as-recorded) mkdir "$dir/wt"; run_relocation_refusal "$dir" "$id" "$fragment" "$variant" "$dir/wt" ;;
      *) run_relocation_refusal "$dir" "$id" "$fragment" "$variant" ;;
    esac
    chmod 755 "$dir/locked" 2>/dev/null || true
  done
  pass "relocation: a present copy, a wrong branch, unaccounted heads, a shared or foreign copy and every other unsafe destination refuse"
}

test_relocation_refuses_a_copy_another_local_home_records() {
  local dir id variant field owned out rc before brief_before journal_before fragment locked
  for variant in worktree worktree-alias home home-alias unavailable own-record unreadable-registry-worktree unreadable-registry-home; do
    id="rl108${variant//-/}"
    dir=$(new_case "relocate-local-home-$variant" "$id")
    make_relocation_case "$dir" "$id"
    locked=
    if [[ "$variant" = unreadable-registry-* ]] && [ "$(id -u)" = 0 ]; then
      echo "skip - unreadable registry needs a non-root user"
      continue
    fi
    printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' \
      "$dir/mate" > "$dir/home/data/secondmates.md"
    printf 'task=%s\nworktree=%s\nworktree_head=%s\n' "$id" "$dir/wt" "$(cat "$dir/first-head")" \
      > "$dir/home/state/$id.control-relaunch"
    if [ "$variant" != unavailable ]; then
      mkdir -p "$dir/mate/state"
    fi
    case "$variant" in
      worktree*|home*)
        field=${variant%%-*}
        owned="$dir/th/1/dest"
        if [[ "$variant" = *-alias ]]; then
          ln -s "$dir/th/1/dest" "$dir/alias"
          owned="$dir/alias"
        fi
        printf '%s=%s\n' "$field" "$owned" > "$dir/mate/state/$id.meta"
        fragment="recorded by another task"
        ;;
      unavailable) fragment="registered local Firstmate home is unavailable" ;;
      unreadable-registry-*)
        mkdir -p "$dir/mate/data" "$dir/hidden/state" "$dir/sibling/state"
        printf -- '- sibling - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' \
          "$dir/sibling" >> "$dir/home/data/secondmates.md"
        locked="$dir/mate/data/secondmates.md"
        printf -- '- hidden - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' \
          "$dir/hidden" > "$locked"
        printf '%s=%s\n' "${variant##*-}" "$dir/th/1/dest" > "$dir/hidden/state/$id.meta"
        chmod 000 "$locked"
        fragment="local Firstmate registry cannot be read"
        ;;
      own-record)
        set_case_meta_field "$dir" "$id" home "$dir/th/1/dest"
        out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
        expect_code 0 "$rc" "the exact own record must be excluded from the local-home scan"$'\n'"$out"
        [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "own-record exclusion did not allow relocation"
        continue
        ;;
    esac
    before=$(cat "$dir/home/state/$id.meta")
    brief_before=$(cat "$dir/home/data/$id/brief.md")
    journal_before=$(cat "$dir/home/state/$id.control-relaunch")
    run_relocation_refusal "$dir" "$id" "$fragment" "$variant"
    out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
    expect_code 1 "$rc" "direct spawn must refuse the local-home ownership hazard ($variant)"$'\n'"$out"
    assert_contains "$out" "$fragment" "direct spawn refused for the wrong reason ($variant)"
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "direct refusal changed the record ($variant)"
    [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] || fail "direct refusal changed the instructions ($variant)"
    [ "$(cat "$dir/home/state/$id.control-relaunch")" = "$journal_before" ] || fail "direct refusal changed the journal ($variant)"
    [ ! -s "$dir/fake/literal" ] || fail "direct refusal launched into another home's copy ($variant)"
    [ -z "$locked" ] || chmod 644 "$locked"
  done
  pass "relocation: every registered local home's records are checked, an unavailable home refuses, and the exact own record is excluded"
}

test_relocation_never_overwrites_or_deletes_a_foreign_harness_file() {
  local dir id rel before out rc n=0
  for rel in .claude/settings.local.json .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
    n=$((n + 1))
    id="rl104$n"
    dir=$(new_case "relocate-wiring-$n" "$id")
    make_relocation_case "$dir" "$id"
    mkdir -p "$(dirname "$dir/th/1/dest/$rel")"
    printf 'the project owns this file: %s\n' "$rel" > "$dir/th/1/dest/$rel"
    # A project commonly ignores these local files, which is exactly when the
    # clean-copy check cannot see them and the harness-file check must.
    printf '%s\n' "$rel" >> "$(git -C "$dir/th/1/dest" rev-parse --path-format=absolute --git-path info/exclude)"
    before=$(cat "$dir/th/1/dest/$rel")
    run_relocation_refusal "$dir" "$id" "harness file" "foreign $rel"
    [ "$(cat "$dir/th/1/dest/$rel")" = "$before" ] || fail "a refused relocation changed $rel"
    rm "$dir/th/1/dest/$rel"
    printf '%s\n' "$before" > "$dir/fake/foreign-wiring"
    printf '%s\n' "$dir/th/1/dest/$rel" > "$dir/fake/foreign-wiring-path"
    out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
    expect_code 1 "$rc" "the launch owner must refuse a foreign $rel"$'\n'"$out"
    assert_contains "$out" "harness file" "the launch owner refused for the wrong reason ($rel)"
    assert_present "$dir/fake/foreign-wiring-created" "the foreign file must arrive after admission ($rel)"
    [ "$(cat "$dir/th/1/dest/$rel")" = "$before" ] || fail "the launch owner changed $rel"
    [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "a refused launch rebound the record ($rel)"
  done
  pass "relocation: a destination's own harness files are never overwritten or deleted"
}

test_relocation_proof_survives_every_failure_journal_rewrite() {
  local dir id variant out rc phase expect_meta
  for variant in launch-refused stop-transport publish-failed complete-journal; do
    id="rl105${variant//-/}"
    dir=$(new_case "relocate-journal-$variant" "$id")
    make_relocation_case "$dir" "$id"
    expect_meta=$(cat "$dir/home/state/$id.meta")
    case "$variant" in
      launch-refused)
        printf '%s' "$dir/proj" > "$dir/fake/cwd"
        : > "$dir/fake/ignore-cd"
        out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
        phase=failed:launching
        ;;
      stop-transport)
        printf claude > "$dir/fake/command"
        out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
          run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
        phase=failed:stopping
        ;;
      publish-failed)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$(command -v mv)" FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/$id.meta" \
          run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "resume"); rc=$?
        phase=failed:launching
        ;;
      complete-journal)
        printf codex > "$dir/fake/becomes"
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV="$(command -v mv)" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
          run_control "$dir" "$id" relaunch --harness codex --worktree "$dir/th/1/dest" --note "resume"); rc=$?
        phase=failed:launching
        ;;
    esac
    expect_code 1 "$rc" "the staged failure must fail closed ($variant)"$'\n'"$out"
    [ "$(journal_field "$dir" "$id" phase)" = "$phase" ] \
      || fail "the journal phase was '$(journal_field "$dir" "$id" phase)', not $phase ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_from)" = "$dir/wt" ] || fail "the failure journal lost relocation_from ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_to)" = "$dir/th/1/dest" ] || fail "the failure journal lost relocation_to ($variant)"
    [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] \
      || fail "the failure journal lost relocation_head ($variant)"
    if [ "$variant" != complete-journal ]; then
      [ "$(cat "$dir/home/state/$id.meta")" = "$expect_meta" ] || fail "an unpublished failure changed the record ($variant)"
    fi
  done

  # The proof is what lets the identical command run again after a failure: the
  # vanished path is still the recorded one, and the journal still vouches for it.
  id=rl105retry
  dir=$(new_case relocate-retry "$id")
  make_relocation_case "$dir" "$id"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  : > "$dir/fake/ignore-cd"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "first attempt"); rc=$?
  expect_code 1 "$rc" "the first attempt must fail after the stop"$'\n'"$out"
  set_case_meta_field "$dir" "$id" pr_head "$(cat "$dir/first-head")"
  git -C "$dir/th/1/dest" reset -q --hard "$(cat "$dir/first-head")"
  printf '%s' "$dir/th/1/dest" > "$dir/fake/cwd"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "second attempt"); rc=$?
  expect_code 1 "$rc" "a copy that lost the journaled head must still be refused on retry"$'\n'"$out"
  assert_contains "$out" "does not contain" "the retry must be judged against the journaled head"
  git -C "$dir/th/1/dest" reset -q --hard "$(cat "$dir/committed-head")"
  rm "$dir/fake/ignore-cd"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/1/dest" --note "third attempt"); rc=$?
  expect_code 0 "$rc" "the identical relocation must succeed once the copy is right"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = journal-relocation_head,journal-worktree_head,meta-pr_head ] \
    || fail "the retry must check both surviving journal heads and the PR head, got '$(journal_field "$dir" "$id" relocation_head_source)'"
  pass "relocation: the vanished path and recorded head survive every failure journal rewrite and judge the retry"
}

test_relocation_proof_survives_later_ordinary_launch_failure() {
  local dir out rc id=rl105ordinary field expected newer
  dir=$(new_case relocate-ordinary-failure "$id")
  make_relocation_case "$dir" "$id"
  printf codex > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" "$id" relaunch --harness codex --worktree "$dir/th/1/dest" --note "relocate"); rc=$?
  expect_code 1 "$rc" "relocation must report a post-publication launch failure"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "published relocation did not retain its destination"
  [ "$(journal_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "failure journal still names the vanished worktree"
  git_commit_file "$dir/th/1/dest" later.txt "committed after relocation"
  newer=$(git -C "$dir/th/1/dest" rev-parse HEAD)
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" "$id" relaunch --note "ordinary retry"); rc=$?
  expect_code 1 "$rc" "ordinary retry must report the staged launch failure"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" phase)" = failed:launching ] || fail "ordinary retry failed before launching"
  for field in from to head head_source; do
    case "$field" in
      from) expected="$dir/wt" ;;
      to) expected="$dir/th/1/dest" ;;
      head) expected=$(cat "$dir/committed-head") ;;
      head_source) expected="meta-pr_head" ;;
    esac
    [ "$(journal_field "$dir" "$id" "relocation_$field")" = "$expected" ] \
      || fail "ordinary launch failure lost relocation_$field"
  done
  [ "$(journal_field "$dir" "$id" worktree_head)" = "$newer" ] || fail "ordinary launch failure lost the newer checkpoint"
  set_case_meta_field "$dir" "$id" pr_head ""
  git -C "$dir/proj" worktree remove --force "$dir/th/1/dest"
  git -C "$dir/proj" branch -f "task-$id" "$(cat "$dir/committed-head")"
  git -C "$dir/proj" worktree add -q "$dir/th/2/next" "task-$id"
  printf zsh > "$dir/fake/command"
  : > "$dir/fake/literal"
  run_relocation_refusal "$dir" "$id" "journal-worktree_head" "newer checkpoint after ordinary launch failure" "$dir/th/2/next"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/2/next"); rc=$?
  expect_code 1 "$rc" "direct spawn must preserve the failed ordinary relaunch checkpoint"$'\n'"$out"
  assert_contains "$out" "journal-worktree_head" "direct spawn missed the failed ordinary checkpoint"
  git -C "$dir/th/2/next" reset -q --hard "$newer"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/2/next" --note "relocate again"); rc=$?
  expect_code 0 "$rc" "a later relocation must recover proof through relocation_to"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" relocation_from)" = "$dir/th/1/dest" ] || fail "new relocation did not replace the prior proof"
  [ "$(journal_field "$dir" "$id" relocation_to)" = "$dir/th/2/next" ] || fail "new relocation did not record its destination"
  [ "$(journal_field "$dir" "$id" relocation_head_source)" = journal-relocation_head,journal-worktree_head ] || fail "later relocation did not use both surviving journal heads"
  pass "relocation: proof survives ordinary launch failures and proves a later destination"
}

test_relocation_requires_a_newer_ordinary_relaunch_checkpoint() {
  local dir out rc newer id=rl109checkpoint
  dir=$(new_case relocate-newer-checkpoint "$id")
  make_relocation_case "$dir" "$id"
  printf codex > "$dir/fake/becomes"
  out=$(run_control "$dir" "$id" relaunch --harness codex --worktree "$dir/th/1/dest" --note "relocate"); rc=$?
  expect_code 0 "$rc" "the first relocation must complete"$'\n'"$out"
  git_commit_file "$dir/th/1/dest" later.txt "committed after relocation"
  newer=$(git -C "$dir/th/1/dest" rev-parse HEAD)
  printf zsh > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "checkpoint newer work"); rc=$?
  expect_code 0 "$rc" "the ordinary relaunch must complete at the newer head"$'\n'"$out"
  [ "$(journal_field "$dir" "$id" worktree_head)" = "$newer" ] || fail "ordinary relaunch did not checkpoint newer work"
  [ "$(journal_field "$dir" "$id" relocation_head)" = "$(cat "$dir/committed-head")" ] || fail "ordinary relaunch lost the earlier relocation proof"
  git -C "$dir/proj" worktree remove --force "$dir/th/1/dest"
  git -C "$dir/proj" branch -f "task-$id" "$(cat "$dir/committed-head")"
  git -C "$dir/proj" worktree add -q "$dir/th/2/next" "task-$id"
  printf zsh > "$dir/fake/command"
  : > "$dir/fake/literal"
  run_relocation_refusal "$dir" "$id" "journal-worktree_head" "newer ordinary checkpoint" "$dir/th/2/next"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/2/next"); rc=$?
  expect_code 1 "$rc" "direct spawn must also preserve the newer checkpoint"$'\n'"$out"
  assert_contains "$out" "journal-worktree_head" "direct spawn missed the newer checkpoint"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "checkpoint refusal rebound the task"
  git -C "$dir/th/2/next" reset -q --hard "$newer"
  out=$(run_control "$dir" "$id" relaunch --worktree "$dir/th/2/next" --note "resume all committed work"); rc=$?
  expect_code 0 "$rc" "a copy containing both journal heads must relocate"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/2/next" ] || fail "the containing copy was not published"
  [ "$(git -C "$dir/th/2/next" rev-parse HEAD)" = "$newer" ] || fail "relocation lost newer committed work"
  pass "relocation: a newer ordinary relaunch checkpoint cannot be hidden by preserved relocation evidence"
}

test_relocation_claims_and_respects_pool_slot_ownership() {
  local dir id pool marker out rc before
  for id in rl106claimed rl106foreignhome rl106emptyhome rl106mine rl106free; do
    dir=$(new_case "relocate-pool-$id" "$id")
    make_relocation_case "$dir" "$id"
    pool="$dir/pool"
    git -C "$dir/proj" worktree remove --force "$dir/th/1/dest"
    mkdir -p "$pool/1"
    write_pool_state "$pool" "$pool/1/repo"
    git -C "$dir/proj" worktree add -q "$pool/1/repo" "task-$id"
    printf '%s' "$pool/1/repo" > "$dir/fake/cwd"
    marker="$pool/1/.fm-slot-owner"
    if [ "$id" = rl106claimed ]; then
      printf 'task=someone-else\nhome=/elsewhere\n' > "$marker"
      run_relocation_refusal "$dir" "$id" "claimed by task someone-else" "slot claimed by another task" "$pool/1/repo"
      [ "$(cat "$marker")" = $'task=someone-else\nhome=/elsewhere' ] || fail "a refused relocation changed another task's claim"
    elif [ "$id" = rl106foreignhome ] || [ "$id" = rl106emptyhome ]; then
      mkdir "$dir/other-home"
      if [ "$id" = rl106foreignhome ]; then
        printf 'task=%s\nhome=%s\n' "$id" "$dir/other-home" > "$marker"
      else
        printf 'task=%s\nhome=\n' "$id" > "$marker"
      fi
      before=$(cat "$marker")
      run_relocation_refusal "$dir" "$id" "not this home" "slot claimed by same id outside this home" "$pool/1/repo"
      out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
      expect_code 1 "$rc" "direct spawn must refuse the foreign home claim"$'\n'"$out"
      assert_contains "$out" "not this home" "direct spawn refused for the wrong reason"
      [ "$(cat "$marker")" = "$before" ] || fail "a refused relocation overwrote a foreign home claim"
    else
      if [ "$id" = rl106mine ]; then
        ln -s "$dir/home" "$dir/home-alias"
        printf 'task=%s\nhome=%s\n' "$id" "$dir/home-alias" > "$marker"
      fi
      out=$(run_control "$dir" "$id" relaunch --worktree "$pool/1/repo" --note "resume"); rc=$?
      expect_code 0 "$rc" "an unclaimed pool slot must relocate"$'\n'"$out"
      assert_grep "task=$id" "$marker" "relocation did not claim the pool slot for its task"
      assert_grep "home=$dir/home" "$marker" "the slot claim must name the owning home"
    fi
  done
  pass "relocation: a pool slot claimed by another task refuses, and an unclaimed one is claimed for the task"
}

test_concurrent_pool_slot_claim_publishes_one_owner() {
  local dir second id=rl111race first_pid out rc first_rc i=0 before first_before holder
  dir=$(new_case relocate-race-first "$id")
  make_relocation_case "$dir" "$id"
  set_case_meta_field "$dir" "$id" harness codex
  printf codex > "$dir/fake/becomes"
  second=$(new_case relocate-race-second "$id")
  mkdir -p "$second/home/data/$id"
  cp "$dir/home/data/$id/brief.md" "$second/home/data/$id/brief.md"
  cp "$dir/home/state/$id.meta" "$second/home/state/$id.meta"
  set_case_meta_field "$second" "$id" worktree "$second/missing"
  printf zsh > "$second/fake/command"
  printf codex > "$second/fake/becomes"
  printf '%s' "$second/missing" > "$second/fake/cwd"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
    "$dir/home" > "$second/home/.fm-secondmate-parent"
  printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' \
    "$second/home" > "$dir/home/data/secondmates.md"
  before=$(cat "$second/home/state/$id.meta")
  # Two homes can both pass the unlocked ownership proof before either claims
  # the slot; the shared project lock alone then stops the second one.
  first_before=$(cat "$dir/home/state/$id.meta")
  # shellcheck disable=SC2016 # expanded by the holder's own shell
  FM_HOME="$dir/home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$2") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    printf "%s\n" "$lock" > "$3.held"
    while [ ! -f "$3.release" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$dir/proj" "$dir/lock-holder" &
  holder=$!
  while [ ! -s "$dir/lock-holder.held" ] && kill -0 "$holder" 2>/dev/null && [ "$i" -lt 1000 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -s "$dir/lock-holder.held" ] || fail "the lock holder never took the shared project lock"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
  : > "$dir/lock-holder.release"
  wait "$holder" || true
  expect_code 1 "$rc" "a relocation published while another actor held the shared project lock: $out"
  assert_contains "$out" "refusing to race relocation ownership" "a relocation did not refuse on the held shared project lock"
  [ "$(cat "$dir/home/state/$id.meta")" = "$first_before" ] || fail "a relocation refused at the shared lock published a record"
  assert_absent "$dir/th/1/.fm-slot-owner" "a relocation refused at the shared lock claimed the pool slot"
  [ ! -s "$dir/fake/literal" ] || fail "a relocation refused at the shared lock launched an agent"
  i=0
  : > "$dir/fake/hold-relocation-cd"
  run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/1/dest" > "$dir/first.out" 2>&1 &
  # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
  first_pid=$!
  while [ ! -f "$dir/fake/relocation-cd-held" ] && kill -0 "$first_pid" 2>/dev/null && [ "$i" -lt 1000 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -f "$dir/fake/relocation-cd-held" ]; then
    : > "$dir/fake/relocation-cd-release"
    wait "$first_pid" || true
    fail "the first relocation never reached cwd handoff: $(cat "$dir/first.out")"
  fi
  out=$(run_spawn "$second" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
  : > "$dir/fake/relocation-cd-release"
  first_rc=0
  wait "$first_pid" || first_rc=$?
  expect_code 0 "$first_rc" "the lock-holding relocation failed: $(cat "$dir/first.out")"
  expect_code 1 "$rc" "the second home published into an acquired copy: $out"
  assert_contains "$out" "is claimed by task" "concurrent relocation did not refuse on the lease claim"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "the first home did not publish its destination"
  [ "$(cat "$second/home/state/$id.meta")" = "$before" ] || fail "the second home published a competing owner"
  [ ! -s "$second/fake/literal" ] || fail "the second home launched into the first home's copy"
  out=$(run_spawn "$second" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
  expect_code 1 "$rc" "a retry ignored the published owner: $out"
  assert_contains "$out" "recorded by another task" "the published owner was not visible to the retry"
  pass "concurrent relocations refuse while the shared project lock is held, and two homes publish and launch exactly one pool owner"
}

test_relocation_refuses_a_non_lease_copy() {
  local dir id variant dest fragment remedy out rc bash_env state lease="run 'git checkout --ignore-other-worktrees"
  for variant in plain unrecorded missing-jq escaped relative; do
    id="rl113${variant//-/}"
    dir=$(new_case "relocate-non-lease-$variant" "$id")
    make_relocation_case "$dir" "$id"
    dest="$dir/th/1/dest"
    state="$dir/th/treehouse-state.json"
    bash_env=
    case "$variant" in
      plain|unrecorded)
        git -C "$dir/proj" worktree remove --force "$dir/th/1/dest"
        if [ "$variant" = plain ]; then
          dest="$dir/plain"; fragment="is not a Treehouse pool slot"
        else
          dest="$dir/th/9/dest"; fragment="has no entry in Treehouse state"
        fi
        remedy="$lease task-$id' in the slot it enters"
        git -C "$dir/proj" worktree add -q "$dest" "task-$id"
        ;;
      missing-jq)
        # jq lives in a system directory on many hosts, so mask it the way the
        # bootstrap case does instead of trimming PATH.
        bash_env="$dir/no-jq.bash"
        cat > "$bash_env" <<'SH'
command() {
  if [ "${1:-}" = -v ] && [ "${2:-}" = jq ]; then
    return 1
  fi
  builtin command "$@"
}
jq() {
  return 127
}
SH
        fragment="needs jq, which is not installed"
        remedy="install jq and retry"
        ;;
      escaped|relative)
        if [ "$variant" = escaped ]; then
          jq '.worktrees += [{name: "3", path: "/elsewhere\\3/next", leased: true}]' "$state" > "$state.tmp"
          fragment="contains an escaped entry path for entry '3'"
        else
          jq '.worktrees += [{name: "3", path: "3/next", leased: true}]' "$state" > "$state.tmp"
          fragment="contains a relative entry path for entry '3'"
        fi
        mv "$state.tmp" "$state"
        remedy="the pool's treehouse-state.json must be inspected, because another entry cannot be compared, then retry; a new lease slot does not clear this refusal"
        ;;
    esac
    # fm-control reads its dispatch rules with jq before it reaches the proof,
    # so only the launch owner meets the missing-jq refusal.
    [ -n "$bash_env" ] || run_relocation_refusal "$dir" "$id" "$fragment" "$variant copy" "$dest"
    out=$(BASH_ENV=$bash_env run_spawn "$dir" "$id" --relaunch --worktree "$dest"); rc=$?
    expect_code 1 "$rc" "the launch owner must refuse a $variant copy"$'\n'"$out"
    assert_contains "$out" "$fragment" "the launch owner refused the $variant copy for the wrong reason"
    assert_contains "$out" "$remedy" "the $variant refusal did not name its own remedy"
    case "$variant" in
      plain|unrecorded) ;;
      *) assert_not_contains "$out" "$lease" "the $variant refusal named the lease procedure, which cannot clear it" ;;
    esac
    [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "a refused $variant relocation changed the record"
  done
  pass "relocation: a hand-made linked worktree refuses, in or out of the pool layout, unless the pool state records it, and an unreadable state names its own remedy"
}

test_unpublished_relocation_releases_only_its_new_pool_claim() {
  local dir id variant pool marker out rc before
  for variant in cwd wiring brief publish existing published; do
    id="rl112$variant"
    dir=$(new_case "relocate-claim-abort-$variant" "$id")
    make_relocation_case "$dir" "$id"
    cp "$dir/home/data/$id/brief.md" "$dir/brief-before"
    pool="$dir/pool"
    git -C "$dir/proj" worktree remove --force "$dir/th/1/dest"
    mkdir -p "$pool/1" "$pool/2"
    write_pool_state "$pool" "$pool/1/repo" "$pool/2/repo"
    git -C "$dir/proj" worktree add -q "$pool/1/repo" "task-$id"
    git -C "$dir/proj" worktree add -q -f "$pool/2/repo" "task-$id"
    marker="$pool/1/.fm-slot-owner"
    before=$(cat "$dir/home/state/$id.meta")
    case "$variant" in
      cwd|existing)
        : > "$dir/fake/ignore-cd"
        if [ "$variant" = existing ]; then
          printf 'task=%s\nhome=%s\n' "$id" "$dir/home" > "$marker"
        fi
        out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
        assert_contains "$out" "not its recorded worktree" "cwd failure did not reach handoff"
        rm "$dir/fake/ignore-cd"
        ;;
      wiring)
        printf 'owned by another tool\n' > "$dir/fake/foreign-wiring"
        printf '%s\n' "$pool/1/repo/.claude/settings.local.json" > "$dir/fake/foreign-wiring-path"
        out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
        assert_present "$dir/fake/foreign-wiring-created" "wiring failure never reached late admission"
        [ "$(cat "$pool/1/repo/.claude/settings.local.json")" = 'owned by another tool' ] || fail "late refusal overwrote foreign wiring"
        ;;
      brief)
        printf '# Task\n' > "$dir/home/data/$id/brief.md"
        out=$(run_spawn "$dir" "$id" --relaunch --worktree "$pool/1/repo"); rc=$?
        assert_contains "$out" "must contain nonempty" "brief failure refused before the intended boundary"
        ;;
      publish)
        make_mv_failure_stub "$dir"
        out=$(FM_REAL_MV=$(command -v mv) FM_FAKE_META_PUBLISH_MV_FAIL="$dir/home/state/$id.meta" \
          run_control "$dir" "$id" relaunch --worktree "$pool/1/repo" --note "resume"); rc=$?
        assert_contains "$out" "replacement task record" "publication failure did not reach the replacement record"
        rm "$dir/fakebin/mv"
        ;;
      published)
        out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
          run_control "$dir" "$id" relaunch --worktree "$pool/1/repo" --note "resume"); rc=$?
        ;;
    esac
    expect_code 1 "$rc" "the staged relocation abort did not fail ($variant): $out"
    if [ "$variant" = published ]; then
      [ "$(meta_field "$dir" "$id" worktree)" = "$pool/1/repo" ] || fail "a published relocation lost its destination"
      [ "$(cat "$marker")" = "$(printf 'task=%s\nhome=%s' "$id" "$dir/home")" ] || fail "post-publication failure removed the owning claim"
      continue
    fi
    [ "$(cat "$dir/home/state/$id.meta")" = "$before" ] || fail "an unpublished abort changed the prior record ($variant)"
    if [ "$variant" = existing ]; then
      [ "$(cat "$marker")" = "$(printf 'task=%s\nhome=%s' "$id" "$dir/home")" ] || fail "abort removed a pre-existing claim"
    else
      assert_absent "$marker" "unpublished abort leaked its new slot claim ($variant)"
    fi
    cp "$dir/brief-before" "$dir/home/data/$id/brief.md"
    out=$(run_control "$dir" "$id" relaunch --worktree "$pool/2/repo" --note "retry elsewhere"); rc=$?
    expect_code 0 "$rc" "a retry onto another copy failed ($variant): $out"
    [ "$(meta_field "$dir" "$id" worktree)" = "$pool/2/repo" ] || fail "retry did not publish the other copy ($variant)"
    assert_grep "home=$dir/home" "$pool/2/.fm-slot-owner" "retry did not claim the second copy"
    [ "$variant" = existing ] || assert_absent "$marker" "retry left the first copy claimed ($variant)"
  done
  pass "unpublished relocation aborts release new claims; pre-existing and published claims survive"
}

test_relocation_flag_is_scoped_to_relaunch() {
  local dir out rc id=rl107
  dir=$(new_case relocate-flags "$id")
  make_relocation_case "$dir" "$id"
  out=$(run_control "$dir" "$id" exit --worktree "$dir/th/1/dest"); rc=$?
  expect_code 1 "$rc" "--worktree must not apply to exit"$'\n'"$out"
  assert_contains "$out" "apply to 'relaunch' only" "the exit refusal must name the verb restriction"
  out=$(run_control "$dir" "$id" relaunch --worktree); rc=$?
  expect_code 1 "$rc" "--worktree needs a value"$'\n'"$out"
  assert_contains "$out" "--worktree requires a value" "the refusal must name the missing value"
  out=$(run_spawn "$dir" "$id" --worktree "$dir/th/1/dest"); rc=$?
  expect_code 1 "$rc" "a fresh spawn must refuse --worktree"$'\n'"$out"
  assert_contains "$out" "applies to --relaunch only" "the spawn refusal must name relaunch"
  out=$(run_spawn "$dir" "$id" --relaunch --worktree "$dir/th/1/dest"); rc=$?
  expect_code 0 "$rc" "the launch owner must accept a validated relocation on its own"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/th/1/dest" ] || fail "the launch owner did not rebind the record"
  pass "relocation: --worktree belongs to relaunch only, and the launch owner repeats the proof itself"
}

test_herdr_relaunch_resumes_only_the_registered_pi_session() {
  local dir id out rc=0 command registered
  for registered in pi claude; do
    recovery_case_or_skip "resume-$registered" "resume-$registered" || {
      echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
      return 0
    }
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
    rm -f "$dir/fake/herdr-stopped"
    sed 's/^harness=claude$/harness=pi/' "$dir/home/state/$id.meta" > "$dir/pi.meta" \
      || fail 'could not prepare Pi relaunch metadata'
    mv "$dir/pi.meta" "$dir/home/state/$id.meta" \
      || fail 'could not publish Pi relaunch metadata'
    # Keep the pane's status authority registered to an existing Pi session,
    # while process-info proves that its previous agent has exited.
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","agent_session":{"kind":"path","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
      "$registered" > "$dir/fake/herdr-agent-registration"
    out=$(run_spawn "$dir" "$id" --relaunch --harness pi) || rc=$?
    expect_code 0 "$rc" "Herdr Pi relaunch should complete ($registered registration)"$'\n'"$out"
    command=$(cat "$dir/fake/launched-command")
    if [ "$registered" = pi ]; then
      assert_contains "$command" "--session '/tmp/pi-bound-session.jsonl'" \
        "the replacement Pi must resume the session that owns Herdr status authority"
    else
      assert_not_contains "$command" "--session" \
        "a Pi replacement must not resume a foreign adapter's conversation"
    fi
    rc=0
  done
  pass "fm-spawn --relaunch: resumes the bound Pi session only for a Pi registration"
}

test_recovery_fixture_claims_only_owned_temp_directories() {
  local dir id path homehash scenario before
  for scenario in task launch; do
    id="rcv-$$-${TMP_ROOT##*.}-ownership-$scenario"
    dir=$(new_case "ownership-$scenario" "$id")
    homehash=$(cd "$dir/home" && pwd -P)
    homehash=$(printf '%s' "$homehash" | shasum -a 256 | cut -d' ' -f1)
    path="/tmp/fm-$id"
    [ "$scenario" != launch ] || path="/tmp/fm-$id+$homehash"
    (umask 077 && mkdir "$path") || fail "could not exclusively own collision fixture"
    TASK_TMPS+=("$path")
    printf 'preserve existing directory\n' > "$path/sentinel"
    before=$(shasum -a 256 "$path/sentinel")
    (
      # shellcheck disable=SC2030 # The child cleanup must track only its own claims, not the parent's.
      TASK_TMPS=()
      # shellcheck disable=SC2030 # The child cleanup must remove only its own root, not the parent's.
      TMP_ROOT="$dir/child-cleanup"
      mkdir "$TMP_ROOT" || exit 1
      trap relaunch_remove_claims EXIT
      if claim_herdr_task_tmps "$dir/home" "$id"; then
        exit 1
      fi
      if [ "$scenario" = launch ]; then
        [ -d "/tmp/fm-$id" ] || exit 1
      fi
    ) || fail "fixture did not refuse a preexisting $scenario directory"
    [ "$before" = "$(shasum -a 256 "$path/sentinel")" ] \
      || fail "fixture cleanup removed or changed a preexisting $scenario directory"
    assert_absent "$dir/child-cleanup" "child fixture cleanup did not run"
    assert_present "$dir/home" "child fixture cleanup removed parent-owned fixture state"
    assert_present "$FM_TEST_CLEANUP_REGISTRY" "child fixture cleanup dropped the parent cleanup registry"
    if [ "$scenario" = launch ]; then
      assert_absent "/tmp/fm-$id" "failed launch claim leaked its newly claimed task directory"
    fi
  done
  pass "recovery fixture cleanup preserves preexisting task/launch directories and removes only its own claims"
}

test_herdr_reclaim_adopts_a_pane_that_outlived_its_server() {
  local dir id out rc=0 log stray
  recovery_case_or_skip gone-herdr rl68 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a pane that outlived its stopped server is adoptable"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "server --session fmlab" \
    "the reclaim must bring the RECORDED session's server back before deciding anything"
  [ "$(grep -c '^server --session fmlab$' <<<"$log")" = 1 ] \
    || fail "a proven stop must launch the recorded session's server exactly once: $log"
  assert_contains "$log" "agent get %7 --session fmlab" \
    "the reclaim must re-read the recorded pane once its server is running"
  assert_not_contains "$log" "workspace create" \
    "adopting a preserved pane must not create a workspace"
  assert_not_contains "$log" "tab create" \
    "adopting a preserved pane must not open a second tab beside it"
  # Every call belongs to the session the record names. A rebind resolves its
  # container from the ambient session instead, which is how the preserved pane
  # ends up orphaned in a workspace nothing points at.
  stray=$(printf '%s\n' "$log" | grep -v -- '--session fmlab$' | grep -v '^status --json$' || true)
  [ -z "$stray" ] || fail "a herdr reclaim touched a session the record does not name: $stray"
  assert_contains "$out" "window=fmlab:%7" "the reclaim should report the adopted endpoint"
  [ "$(meta_field "$dir" "$id" herdr_pane_id)" = '%7' ] \
    || fail "the adopted record's pane id changed, got $(meta_field "$dir" "$id" herdr_pane_id)"
  [ "$(meta_field "$dir" "$id" herdr_tab_id)" = tab1 ] \
    || fail "the adopted record's tab id changed, got $(meta_field "$dir" "$id" herdr_tab_id)"
  [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%7' ] \
    || fail "the adopted record's endpoint moved, got $(meta_field "$dir" "$id" window)"
  assert_contains "$log" "pane send-text %7 " \
    "the replacement's launch brief must be delivered into the adopted pane"
  pass "reclaim: a herdr pane that outlived its stopped server is adopted, never orphaned beside a new tab"
}

# A stopped status alone is not absence: a failed status read, or a session
# socket that still accepts connections, must refuse every recovery entry point
# before any server launch or endpoint creation.
test_herdr_recovery_refuses_an_unproven_server_stop() {
  local mode entry dir id out rc log listener
  for mode in status-fails socket-accepts; do
    for entry in exit spawn; do
      recovery_case_or_skip "unproven-herdr-$mode-$entry" "rl75-$mode-$entry" || {
        echo "skip - herdr recovery needs jq (the herdr adapter parses JSON with it)"
        return 0
      }
      dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID listener=
      if [ "$mode" = status-fails ]; then
        : > "$dir/fake/herdr-status-fails"
      else
        python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8); time.sleep(120)' \
          "$(cat "$dir/fake/herdr-socket-path")" &
        listener=$!
        for _ in $(seq 1 100); do
          [ ! -S "$(cat "$dir/fake/herdr-socket-path")" ] || break
          /bin/sleep 0.05
        done
      fi
      rc=0
      if [ "$entry" = exit ]; then
        out=$(run_control "$dir" "$id" exit) || rc=$?
      else
        out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
      fi
      [ -z "$listener" ] || kill "$listener" 2>/dev/null || true
      log=$(cat "$dir/fake/herdr-log")
      expect_code 1 "$rc" "an unproven herdr stop ($mode) must refuse $entry"$'\n'"$out"$'\n'"$log"
      assert_not_contains "$log" "server --session" "an unproven herdr stop ($mode) must not launch a server through $entry"
      assert_not_contains "$log" "tab create" "an unproven herdr stop ($mode) must not mint a tab through $entry"
      [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%7' ] \
        || fail "an unproven herdr stop ($mode) let $entry rewrite the recorded endpoint"
    done
  done
  pass "herdr recovery: a failed status or an accepting socket refuses exit and relaunch without launching a server"
}

test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server() {
  local dir id out rc=0
  recovery_case_or_skip gone-herdr-exit rl72 || {
    echo "skip - herdr exit needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID

  out=$(run_control "$dir" "$id" exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
}

test_herdr_rebind_stays_in_the_recorded_session() {
  local dir id out rc=0 log
  # The record names session `fmlab`; this seat has no ambient HERDR_SESSION, so
  # the adapter's own default is `default`. The recorded pane does NOT come back
  # with the server, so this reclaim really does rebind - and the rebind must
  # land in `fmlab`, never in `default`.
  recovery_case_or_skip gone-herdr-pin rl73 fmlab '%none' || {
    echo "skip - herdr rebind needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a herdr pane that did not survive its server should be rebound"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "tab create" "a destroyed pane must be replaced by a fresh tab"
  [ -z "$(grep -v -- '--session fmlab$' <<<"$log" | grep -v '^status --json$' || true)" ] \
    || fail "the rebind used a herdr session the record does not name: $log"
  [ "$(meta_field "$dir" "$id" herdr_session)" = fmlab ] \
    || fail "the rebound record left its recorded herdr session, got $(meta_field "$dir" "$id" herdr_session)"
  [ "$(meta_field "$dir" "$id" window)" = 'fmlab:%9' ] \
    || fail "the rebound endpoint should be the new pane in the recorded session, got $(meta_field "$dir" "$id" window)"
  [ "$(meta_field "$dir" "$id" herdr_pane_id)" = '%9' ] \
    || fail "the rebound record should name the pane the reclaim minted, got $(meta_field "$dir" "$id" herdr_pane_id)"
  pass "reclaim: a herdr rebind is created in the session the record names, never the ambient one"
}

test_herdr_reclaim_refuses_an_agent_that_came_back() {
  local dir id out rc log
  recovery_case_or_skip gone-herdr-alive rl74 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  # The server was stopped, so the first read says `missing` - but starting it
  # brings the pane AND its agent back. A rebind here would put a second agent
  # in this task's worktree, which is the whole reason absence is re-proven.
  : > "$dir/fake/herdr-agent-live"

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a returning agent must refuse, never be duplicated"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused reclaim must not mint a second tab"
  assert_not_contains "$log" "workspace create" "a refused reclaim must not create a workspace"
  [ "$(meta_field "$dir" "$id" herdr_pane_id)" = '%7' ] \
    || fail "a refused reclaim rewrote the record's pane id"
  pass "reclaim: a herdr agent that came back with its server refuses, so one worktree keeps one agent"
}

test_herdr_reclaim_keeps_the_task_whole() {
  local dir id out rc=0 head_before
  recovery_case_or_skip gone-herdr-work rl75 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'never committed\n' > "$dir/wt/dirty.txt"

  # A reclaim rebinds the ENDPOINT and nothing else. Everything that identifies
  # the task must come through untouched: a record row the reclaim does not
  # own, the armed watcher check and the private binding that authorizes it,
  # and the status log the supervisor reads.
  printf '%s\n' "pr=https://example.invalid/pr/7" >> "$dir/home/state/$id.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/$id.check.sh"
  chmod 0700 "$dir/home/state/$id.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "could not arm a custom check for the reclaim fixture"
  printf 'working: parked on an approval nobody can answer\n' >> "$dir/home/state/$id.status"

  out=$(run_control "$dir" "$id" relaunch --note "the pane was destroyed; pick the work back up") || rc=$?
  expect_code 0 "$rc" "the owning seat should be able to reclaim a task whose pane is gone"$'\n'"$out"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "a reclaim moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "task-$id" ] \
    || fail "a reclaim changed the worktree's branch"
  assert_contains "$(cat "$dir/wt/dirty.txt")" "never committed" \
    "a reclaim destroyed or rewrote an uncommitted change"
  assert_present "$dir/wt/committed.txt" "a reclaim destroyed committed work"

  [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] \
    || fail "a reclaim must keep the recorded worktree"
  [ "$(meta_field "$dir" "$id" pr)" = "https://example.invalid/pr/7" ] \
    || fail "a reclaim dropped a record row it does not own"
  assert_present "$dir/home/state/$id.check.sh" "a reclaim retired the task's armed check"
  assert_present "$dir/home/state/$id.check-trust" "a reclaim broke the armed check's registration"
  assert_contains "$(cat "$dir/home/state/$id.status")" "parked on an approval nobody can answer" \
    "a reclaim truncated the status log"
  assert_contains "$(cat "$dir/home/data/$id/brief.md")" "the pane was destroyed" \
    "the replacement must inherit the progress note"
  [ "$(journal_field "$dir" "$id" exit_result)" = endpoint-gone ] \
    || fail "the transaction should record that the endpoint was already gone"
  pass "reclaim: a herdr reclaim rebinds the endpoint and leaves the whole rest of the task alone"
}

test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause() {
  local dir id out rc
  # No HERDR_* env at all, which is how an operator reclaims from ssh or cron.
  # The adapter's ambient session then reads `default` while the record names
  # `fmlab`, but the cross-session launcher guard was never consulted - this
  # seat claims no launcher pane, so placement fell back to the recorded
  # session's labeled container and the container failed for its own reason.
  recovery_case_or_skip gone-herdr-plain rl77 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a container that cannot be ensured must refuse"$'\n'"$out"
  assert_contains "$out" "fmlab" "the refusal should name the session the reclaim was targeting"
  assert_not_contains "$out" "this seat is running in herdr session" \
    "a seat with no launcher pane never hit the cross-session guard, so the refusal must not blame one"
  assert_not_contains "$out" "a reclaim never moves a task to another session" \
    "the operator must not be sent to re-run from another seat when that would not help"
  pass "reclaim: a rebind refused from a plain shell reports the real cause, not a fabricated session mismatch"
}

test_herdr_reclaim_of_a_secondmate_names_its_own_owner() {
  local dir id out rc
  recovery_case_or_skip gone-herdr-secondmate rl76 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  printf '%s\n' "kind=secondmate" "home=$dir/wt" >> "$dir/home/state/$id.meta"

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a secondmate reclaim belongs to the secondmate respawn path"
  assert_contains "$out" "--secondmate" "the refusal should name the path that owns this recovery"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "tab create" \
    "the refusal must happen before any endpoint is created"
  pass "reclaim: a herdr secondmate whose endpoint is gone is sent to its own respawn owner"
}

test_held_relaunch_refuses_without_stopping_the_live_owner() {
  local dir out rc=0
  dir=$(new_case held-owner rlheld)
  add_ship_task "$dir" rlheld
  seed_backlog "$dir" rlheld in_flight
  tasks-axi hold rlheld --reason "captain decision pending" --kind captain \
    --file "$dir/home/data/backlog.md" >/dev/null
  cp "$dir/home/state/rlheld.meta" "$dir/meta-before"
  cp "$dir/home/data/rlheld/brief.md" "$dir/brief-before"
  cp "$dir/home/data/backlog.md" "$dir/backlog-before"

  out=$(run_control "$dir" rlheld relaunch --note "fresh context"); rc=$?
  expect_code 1 "$rc" "a held replacement must refuse"
  assert_contains "$out" "not dispatchable" "refusal should identify admission"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a predictable replacement refusal stranded the live owner"
  [ ! -s "$dir/fake/literal" ] || fail "refused admission sent lifecycle input"
  cmp -s "$dir/meta-before" "$dir/home/state/rlheld.meta" || fail "refusal changed metadata"
  cmp -s "$dir/brief-before" "$dir/home/data/rlheld/brief.md" || fail "refusal changed instructions"
  cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "refusal changed the hold"
  pass "held replacement admission refuses before touching the live owner"
}

test_exited_owner_reconciliation_preserves_holds_dependencies_and_work() {
  local dir id restriction out rc head
  for restriction in held dependency both; do
    id="rlrecover-$restriction"
    dir=$(new_case "recover-$restriction" "$id")
    add_ship_task "$dir" "$id"
    seed_backlog "$dir" "$id" in_flight
    if [ "$restriction" != dependency ]; then
      tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
        --file "$dir/home/data/backlog.md" >/dev/null
    fi
    if [ "$restriction" != held ]; then
      tasks-axi add prerequisite "genuine unfinished dependency" --kind ship \
        --file "$dir/home/data/backlog.md" >/dev/null
      tasks-axi block "$id" --by prerequisite --file "$dir/home/data/backlog.md" >/dev/null
    fi
    printf 'retained commit\n' > "$dir/wt/retained.txt"
    git -C "$dir/wt" add retained.txt
    git -C "$dir/wt" commit -qm "fixture retained work"
    head=$(git -C "$dir/wt" rev-parse HEAD)
    printf 'uncommitted work\n' >> "$dir/wt/retained.txt"
    printf 'untracked work\n' > "$dir/wt/untracked.txt"
    mkdir -p "$dir/home/state/$id.inbox/handled"
    printf 'Reconcile factual wait only; no validation permission.\n' > "$dir/home/state/$id.inbox/005.msg"
    cp "$dir/home/state/$id.inbox/005.msg" "$dir/instruction-before"
    cp "$dir/home/data/backlog.md" "$dir/backlog-before"
    printf zsh > "$dir/fake/command"
    break_tasks_axi_start "$dir"

    rc=0
    out=$(run_control "$dir" "$id" relaunch --reconcile-only --note "Read unread instructions; retain the genuine blocker.") || rc=$?
    expect_code 0 "$rc" "$restriction exited-owner recovery should succeed"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "recovery scope was not recorded"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "replacement instruction owner was not launched"
    [ "$(meta_field "$dir" "$id" worktree)" = "$dir/wt" ] || fail "recovery changed the local copy"
    [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "recovery moved the preserved commit"
    assert_contains "$(cat "$dir/wt/retained.txt")" "uncommitted work" "recovery lost dirty files"
    [ "$(cat "$dir/wt/untracked.txt")" = "untracked work" ] || fail "recovery lost untracked files"
    cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "recovery changed hold/dependency state"
    cmp -s "$dir/instruction-before" "$dir/home/state/$id.inbox/005.msg" || fail "recovery consumed unread instructions"
    rc=0
    out=$(run_control "$dir" "$id" relaunch --note "try ordinary continuation") || rc=$?
    expect_code 1 "$rc" "a recovered owner must still fail ordinary blocked dispatch"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused ordinary relaunch stopped the recovered owner"
  done
  pass "exited-owner recovery preserves commits, files, instructions, and real holds/dependencies without continuation authority"
}

test_session_end_replacement_cannot_convert_recovery_to_execution() {
  local dir id=rlrecover-exit out rc=0 gen
  dir=$(new_case recover-session-end "$id")
  add_ship_task "$dir" "$id"
  seed_backlog "$dir" "$id" in_flight
  tasks-axi add prerequisite "genuine unfinished dependency" --kind ship \
    --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi block "$id" --by prerequisite --file "$dir/home/data/backlog.md" >/dev/null
  printf zsh > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --reconcile-only --note "Reconcile only.") || rc=$?
  expect_code 0 "$rc" "dependency-only recovery should succeed"$'\n'"$out"
  # The recovered owner exits before it declares a wait. Completing the real
  # prerequisite permits dispatch structurally, but is not continuation consent.
  printf zsh > "$dir/fake/command"
  gen=$(cat "$dir/home/state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/home/state" "$id" idle --gen "$gen" \
    --source claude-hook --event session-end >/dev/null
  tasks-axi 'done' prerequisite --file "$dir/home/data/backlog.md" >/dev/null
  cp "$dir/home/data/backlog.md" "$dir/backlog-before-auto"
  cat > "$dir/session-end.sh" <<'SH'
#!/usr/bin/env bash
set -eu
. "$1/bin/fm-session-end-relaunch-lib.sh"
fm_session_end_relaunch_scan "$2"
[ "$FM_SESSION_END_WAKE" = "check: $3 auto-relaunched after session-end" ]
SH
  rc=0
  # shellcheck disable=SC2031 # The session-end scan's PATH override is confined to its subshell.
  out=$(env -u HERDR_ENV -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SESSION_END_LAUNCH_WAIT=1 \
    bash "$dir/session-end.sh" "$ROOT" "$dir/home/state" "$id" 2>&1) || rc=$?
  expect_code 0 "$rc" "automatic recovery replacement should stay bounded"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] \
    || fail "automatic replacement removed recovery scope after the dependency completed"
  assert_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "automatic replacement did not inherit the recovery-only instruction contract"
  assert_grep 'not resuming implementation' "$dir/home/data/$id/launch-brief.md" \
    "automatic replacement instructions incorrectly authorize implementation"
  cmp -s "$dir/backlog-before-auto" "$dir/home/data/backlog.md" \
    || fail "automatic replacement changed task/dependency state"
  # Direct launch callers must inherit the same restriction, not only control.
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  expect_code 0 "$rc" "direct replacement of a recovered owner should remain bounded"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] \
    || fail "direct replacement removed recovery scope"
  assert_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "direct replacement did not inherit the recovery-only instruction contract"
  make_continuation_owner_fixture "$dir"
  cp "$dir/home/state/$id.meta" "$dir/meta-before-clearance"
  cp "$dir/home/data/$id/brief.md" "$dir/brief-before-clearance"
  rc=0
  out=$(run_control "$dir" "$id" relaunch --note "no implicit permission from a completed dependency") || rc=$?
  expect_code 1 "$rc" "ordinary live relaunch must still inherit recovery after dependency completion"
  assert_contains "$out" "requires a proven exited owner" "ordinary syntax dropped its inherited reconciliation restriction"
  cmp -s "$dir/meta-before-clearance" "$dir/home/state/$id.meta" || fail "refused inherited recovery changed metadata"
  cmp -s "$dir/brief-before-clearance" "$dir/home/data/$id/brief.md" || fail "refused inherited recovery changed instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "inherited recovery refusal stopped the recovered owner"
  snapshot_continuation_case "$dir"
  rc=0
  out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
  expect_code 0 "$rc" "the actual owner may explicitly clear now-unblocked recovery"$'\n'"$out"
  assert_continuation_snapshot "$dir" "$id" 1
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  expect_code 0 "$rc" "direct replacement after explicit clearance should be ordinary"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "direct replacement restored recovery after explicit clearance"
  assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "direct replacement after clearance retained the obsolete recovery-only role"
  id=rlcleared-auto
  dir=$(new_case recover-cleared-auto "$id")
  add_ship_task "$dir" "$id"
  seed_backlog "$dir" "$id" in_flight
  printf 'recovery=reconcile-only\n' >> "$dir/home/state/$id.meta"
  make_continuation_owner_fixture "$dir"
  snapshot_continuation_case "$dir"
  rc=0
  out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
  expect_code 0 "$rc" "a separately budgeted owner may explicitly clear recovery before its first automatic replacement"$'\n'"$out"
  assert_continuation_snapshot "$dir" "$id" 1
  cp "$dir/home/data/backlog.md" "$dir/backlog-before-auto"
  arm_session_end "$dir" "$id"
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_session_end_scan "$dir") || rc=$?
  expect_code 0 "$rc" "automatic replacement after explicit clearance should be ordinary"$'\n'"$out"
  assert_contains "$out" "$id auto-relaunched after session-end" "cleared automatic replacement did not relaunch"
  [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "automatic replacement restored recovery after explicit clearance"
  assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
    "automatic replacement after clearance retained the obsolete recovery-only role"
  cmp -s "$dir/backlog-before-auto" "$dir/home/data/backlog.md" || fail "clearance and later replacements changed a completed dependency or task state"
  pass "automatic, direct, and ordinary replacement inherit recovery until explicit clearance, then remain ordinary"
}

test_reconciliation_refuses_live_queued_and_unowned_dispatch() {
  local dir out rc
  dir=$(new_case recovery-live rlrecoverylive)
  add_ship_task "$dir" rlrecoverylive
  seed_backlog "$dir" rlrecoverylive in_flight
  rc=0
  out=$(run_control "$dir" rlrecoverylive relaunch --reconcile-only --note "reconcile") || rc=$?
  expect_code 1 "$rc" "reconciliation must not stop a live owner"
  assert_contains "$out" "requires a proven exited owner" "live-owner refusal lost the reason"
  [ ! -s "$dir/fake/literal" ] || fail "recovery sent input to a live owner"
  tasks-axi reopen rlrecoverylive --file "$dir/home/data/backlog.md" >/dev/null
  printf zsh > "$dir/fake/command"
  rc=0
  out=$(run_control "$dir" rlrecoverylive relaunch --reconcile-only --note "reconcile") || rc=$?
  expect_code 1 "$rc" "reconciliation must not start queued work"
  assert_contains "$out" "requires an existing In-flight" "queued refusal lost its reason"
  rc=0
  out=$(run_spawn "$dir" rlrecoverylive --reconcile-only --mode no-mistakes --yolo off) || rc=$?
  expect_code 1 "$rc" "fresh dispatch must not use recovery admission"
  assert_contains "$out" "applies only to --relaunch" "fresh dispatch recovery flag was not refused"
  rm "$dir/home/data/backlog.md"
  rc=0
  out=$(run_control "$dir" rlrecoverylive relaunch --reconcile-only --note "reconcile") || rc=$?
  expect_code 1 "$rc" "reconciliation must not assume a missing backlog has no blocker"
  assert_contains "$out" "requires a readable automatic backlog" "missing backlog refusal lost its reason"
  pass "reconciliation-only admission refuses live owners, queued work, fresh dispatch, and absent backlog authority"
}

test_blocked_relaunch_admission_is_shared_across_supported_harnesses() {
  local dir harness out rc
  for harness in claude codex opencode pi pi-signed grok kimi cursor gemini muse rovo omp agy devin; do
    dir=$(new_case "held-$harness" "rlaxis-$harness")
    add_ship_task "$dir" "rlaxis-$harness" "$harness"
    seed_backlog "$dir" "rlaxis-$harness" in_flight
    tasks-axi hold "rlaxis-$harness" --reason "captain decision pending" --kind captain \
      --file "$dir/home/data/backlog.md" >/dev/null
    rc=0
    out=$(run_control "$dir" "rlaxis-$harness" relaunch --note "fresh context") || rc=$?
    expect_code 1 "$rc" "$harness must refuse held replacement"
    assert_contains "$out" "not dispatchable" "$harness did not use shared structural admission"
    [ ! -s "$dir/fake/literal" ] || fail "$harness received lifecycle input on refusal"
  done
  pass "all supported worker harnesses share pre-stop blocked replacement admission"
}

test_herdr_held_owner_refusal_and_exited_reconciliation() {
  local dir id out rc=0
  recovery_case_or_skip held-herdr rlheldherdr || {
    echo "skip - Herdr admission fixtures need jq"
    return 0
  }
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  rm "$dir/fake/herdr-stopped"
  : > "$dir/fake/herdr-agent-live"
  seed_backlog "$dir" "$id" in_flight
  tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
    --file "$dir/home/data/backlog.md" >/dev/null
  cp "$dir/home/data/backlog.md" "$dir/backlog-before"
  out=$(run_control "$dir" "$id" relaunch --note "fresh context") || rc=$?
  expect_code 1 "$rc" "Herdr held replacement must refuse"
  assert_contains "$out" "not dispatchable" "Herdr admission lost its refusal"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "pane send-" "refused Herdr replacement sent lifecycle input"
  [ -f "$dir/fake/herdr-agent-live" ] || fail "Herdr live owner was stopped"
  rm "$dir/fake/herdr-agent-live"
  rc=0
  out=$(run_control "$dir" "$id" relaunch --reconcile-only --note "Reconcile only.") || rc=$?
  expect_code 0 "$rc" "Herdr exited instruction owner should recover"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" window)" = "fmlab:%7" ] || fail "Herdr recovery changed endpoint"
  [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "Herdr recovery lost scope"
  cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "Herdr recovery changed the hold"
  pass "Herdr shares pre-stop held admission and recovery-only exited-owner preservation"
}

test_continuation_authorization_requires_the_lock_owning_main() {
  local dir id owner out rc foreign_pid
  for owner in missing foreign dead worker branch branch-away; do
    id="rlclear-$owner"
    dir=$(new_case "clear-$owner" "$id")
    seed_continuation_case "$dir" "$id"
    foreign_pid=
    case "$owner" in
      missing) rm "$dir/home/state/.lock" ;;
      foreign)
        /bin/sleep 30 &
        # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
        foreign_pid=$!
        printf '%s\n' "$foreign_pid" > "$dir/fake/foreign-pid"
        printf '%s\n' "$foreign_pid" > "$dir/home/state/.lock"
        ;;
      dead)
        /bin/sleep 0 &
        # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
        foreign_pid=$!
        wait "$foreign_pid"
        printf '%s\n' "$foreign_pid" > "$dir/home/state/.lock"
        foreign_pid=
        ;;
      branch-away)
        FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 3 >/dev/null \
          || fail "could not establish the confirmed away posture"
        FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" validate >/dev/null \
          || fail "the away refusal fixture has no valid authority record"
        ;;
    esac
    printf '\nwindow=wrong-session:wrong-task\n' >> "$dir/home/state/$id.meta"
    snapshot_continuation_case "$dir"
    rc=0
    case "$owner" in
      worker)
        out=$(FM_FAKE_TASK_ID="$id" run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
        ;;
      branch|branch-away)
        out=$(FM_FAKE_ACTOR=branch run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
        ;;
      *)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
        ;;
    esac
    if [ -n "$foreign_pid" ]; then
      kill "$foreign_pid" 2>/dev/null || true
      wait "$foreign_pid" 2>/dev/null || true
    fi
    case "$owner" in
      worker)
        expect_code 1 "$rc" "a marked worker must not authorize continuation even under the owning session"
        assert_contains "$out" "workers cannot authorize continuation" "worker refusal lost its authority boundary"
        ;;
      branch|branch-away)
        expect_code 6 "$rc" "$owner must not inherit continuation authority"
        assert_contains "$out" "the supervision branch never performs this action" "branch refusal lost its role partition"
        ;;
      *)
        expect_code 1 "$rc" "$owner session ownership must refuse continuation authorization"
        assert_contains "$out" "requires the actual lock-owning main Firstmate" "owner refusal lost its authority boundary"
        ;;
    esac
    assert_continuation_snapshot "$dir" "$id"
  done
  pass "continuation authorization refuses missing, foreign, dead, worker, and attended/away branch authority without side effects"
}

test_continuation_authorization_rejects_relaunch_options_and_arbitrary_input() {
  local dir id form out rc expected
  for form in note reconcile text unknown-verb; do
    id="rlclear-options-$form"
    dir=$(new_case "clear-options-$form" "$id")
    seed_continuation_case "$dir" "$id"
    snapshot_continuation_case "$dir"
    rc=0
    expected=1
    case "$form" in
      note)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation --note "not a continuation instruction") || rc=$?
        assert_contains "$out" "apply to 'relaunch' only" "authorization accepted relaunch notes"
        ;;
      reconcile)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation --reconcile-only) || rc=$?
        assert_contains "$out" "apply to 'relaunch' only" "authorization accepted recovery launch options"
        ;;
      text)
        out=$(run_continuation_control "$dir" "$id" authorize-continuation "implement the rest") || rc=$?
        assert_contains "$out" "unexpected argument" "authorization accepted arbitrary instruction text"
        ;;
      unknown-verb)
        expected=2
        out=$(run_continuation_control "$dir" "$id" continue) || rc=$?
        assert_contains "$out" "allowed verbs:" "a non-allowlisted continuation verb did not refuse"
        ;;
    esac
    expect_code "$expected" "$rc" "$form must refuse without mutation or delivery"
    assert_continuation_snapshot "$dir" "$id"
  done
  pass "continuation clearance accepts no relaunch options, arbitrary text, or non-allowlisted verbs"
}

test_continuation_authorization_preserves_blocked_ordinary_admission() {
  local dir id restriction out rc
  for restriction in held dependency both; do
    id="rlclear-block-$restriction"
    dir=$(new_case "clear-block-$restriction" "$id")
    seed_continuation_case "$dir" "$id"
    if [ "$restriction" != dependency ]; then
      tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
        --file "$dir/home/data/backlog.md" >/dev/null
    fi
    if [ "$restriction" != held ]; then
      tasks-axi add prerequisite "genuine unfinished dependency" --kind ship \
        --file "$dir/home/data/backlog.md" >/dev/null
      tasks-axi block "$id" --by prerequisite --file "$dir/home/data/backlog.md" >/dev/null
    fi
    snapshot_continuation_case "$dir"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 1 "$rc" "$restriction must refuse ordinary continuation admission"
    assert_contains "$out" "not dispatchable" "clearance used recovery admission instead of ordinary dispatch admission"
    assert_continuation_snapshot "$dir" "$id"
  done
  pass "held and dependency-blocked continuation authorization refuses ordinary admission and preserves every byte"
}

test_continuation_authorization_requires_current_automatic_backlog_and_recovery() {
  local dir id restriction out rc expected
  for restriction in missing-backlog manual-backlog unreadable-backlog pending-close missing-kind ambiguous-kind missing-recovery ambiguous-recovery remote symlink; do
    id="rlclear-record-$restriction"
    dir=$(new_case "clear-record-$restriction" "$id")
    seed_continuation_case "$dir" "$id"
    expected=
    case "$restriction" in
      missing-backlog)
        rm "$dir/home/data/backlog.md"
        expected="requires a readable automatic backlog"
        ;;
      manual-backlog)
        mkdir -p "$dir/home/config"
        printf 'manual\n' > "$dir/home/config/backlog-backend"
        expected="requires a readable automatic backlog"
        ;;
      unreadable-backlog)
        rm "$dir/home/data/backlog.md"
        mkdir "$dir/home/data/backlog.md"
        expected="requires a readable automatic backlog"
        ;;
      pending-close)
        printf 'id=%s\ndata=%s\nspawn_gen=preserved-incarnation\n' "$id" "$dir/home/data" \
          > "$dir/home/state/$id.backlog-close"
        expected="pending authoritative backlog close"
        ;;
      missing-kind)
        sed '/^kind=/d' "$dir/home/state/$id.meta" > "$dir/restricted.meta"
        mv "$dir/restricted.meta" "$dir/home/state/$id.meta"
        expected="ship or scout"
        ;;
      ambiguous-kind)
        printf '\nkind=scout\n' >> "$dir/home/state/$id.meta"
        expected="unambiguous ship or scout kind"
        ;;
      missing-recovery)
        sed '/^recovery=/d' "$dir/home/state/$id.meta" > "$dir/restricted.meta"
        mv "$dir/restricted.meta" "$dir/home/state/$id.meta"
        expected="unambiguous recovery field"
        ;;
      ambiguous-recovery)
        printf '\nrecovery=reconcile-only\n' >> "$dir/home/state/$id.meta"
        expected="unambiguous recovery field"
        ;;
      remote)
        printf '\nremote_host=other-host\n' >> "$dir/home/state/$id.meta"
        expected="requires a local ship or scout"
        ;;
      symlink)
        mv "$dir/home/state/$id.meta" "$dir/foreign.meta"
        ln -s "$dir/foreign.meta" "$dir/home/state/$id.meta"
        cp "$dir/foreign.meta" "$dir/foreign-before"
        expected="task record resolves outside its authorized directory"
        ;;
    esac
    snapshot_continuation_case "$dir"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 1 "$rc" "$restriction must refuse metadata-only continuation clearance"
    assert_contains "$out" "$expected" "$restriction refusal lost its actual prerequisite"
    assert_continuation_snapshot "$dir" "$id"
    if [ "$restriction" = symlink ]; then
      cmp -s "$dir/foreign-before" "$dir/foreign.meta" || fail "clearance changed a foreign record through a symlink"
    fi
  done
  pass "continuation authorization requires current automatic backlog, local unambiguous recovery records, and no pending close"
}

test_continuation_authorization_only_clears_recovery_before_future_relaunch() {
  local dir id state kind out rc
  for state in live exited; do
    id="rlclear-success-$state"
    dir=$(new_case "clear-success-$state" "$id")
    seed_continuation_case "$dir" "$id"
    kind=ship
    if [ "$state" = exited ]; then
      kind=scout
      perl -pe 's/^kind=ship$/kind=scout/' "$dir/home/state/$id.meta" > "$dir/scout.meta"
      mv "$dir/scout.meta" "$dir/home/state/$id.meta"
      printf zsh > "$dir/fake/command"
    fi
    : > "$dir/fake/inventory-broken"
    snapshot_continuation_case "$dir"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 0 "$rc" "unblocked $kind continuation clearance must not require a readable runtime endpoint"$'\n'"$out"
    assert_contains "$out" "continuation-authorized $id" "clearance should report the exact authorized task"
    assert_continuation_snapshot "$dir" "$id" 1
    [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "clearance left reconciliation-only recovery recorded"
    [ "$(meta_field "$dir" "$id" continuation_required)" = preserve-this-custom-field ] \
      || fail "clearance removed an unrelated metadata field"
    rm "$dir/fake/inventory-broken"
    rc=0
    out=$(run_control "$dir" "$id" relaunch --note "explicitly cleared continuation") || rc=$?
    expect_code 0 "$rc" "future ordinary relaunch of the $state cleared owner should succeed"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "ordinary replacement restored obsolete recovery restriction"
    assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
      "ordinary replacement after clearance retained the recovery-only launch instructions"
    [ "$(cat "$dir/fake/command")" = claude ] || fail "cleared ordinary replacement did not launch"
  done
  pass "unblocked ship/scout clearance changes only recovery, sends no endpoint input, and permits later live/exited ordinary relaunch"
}

test_continuation_authorization_excludes_control_and_direct_replacements() {
  local dir id=rlclear-first ready release auth_pid out rc
  dir=$(new_case clear-first "$id")
  seed_continuation_case "$dir" "$id"
  printf zsh > "$dir/fake/command"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  cp "$dir/home/data/backlog.md" "$dir/backlog-before"
  ready="$dir/admission-ready"
  release="$dir/admission-release"
  pause_continuation_admission "$dir"
  FM_FAKE_ADMISSION_READY="$ready" FM_FAKE_ADMISSION_RELEASE="$release" \
    run_continuation_control "$dir" "$id" authorize-continuation > "$dir/authorize.out" &
  # shellcheck disable=SC2031 # The parent just launched this child; $! is not inherited.
  auth_pid=$!
  await_fixture_ready "$ready" "$auth_pid" "continuation authorization" || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "could not stage continuation authorization under both locks"
  }
  [ -s "$dir/home/state/.control-$id.lock/pid" ] && [ -s "$dir/home/state/.meta-$id.lock/pid" ] || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "continuation admission did not hold lifecycle then metadata locks"
  }
  rc=0
  out=$(run_control "$dir" "$id" relaunch --note "must not interleave") || rc=$?
  if [ "$rc" != 1 ] || [[ "$out" != *"another lifecycle action is already running"* ]]; then
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "control replacement interleaved with continuation clearance: $rc: $out"
  fi
  rc=0
  out=$(run_spawn "$dir" "$id" --relaunch --harness claude) || rc=$?
  if [ "$rc" != 1 ] || [[ "$out" != *"another lifecycle action is already running"* ]]; then
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "direct replacement interleaved with continuation clearance: $rc: $out"
  fi
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "continuation metadata changed before its admission completed"
  }
  [ ! -s "$dir/fake/literal" ] || {
    : > "$release"
    wait "$auth_pid" 2>/dev/null || true
    fail "a replacement delivered launch bytes while continuation authorization held both locks"
  }
  : > "$release"
  wait "$auth_pid"; rc=$?
  expect_code 0 "$rc" "continuation authorization should finish after its deterministic admission release"$'\n'"$(cat "$dir/authorize.out")"
  [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "serialized clearance left recovery recorded"
  cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "serialized clearance changed backlog admission"
  pass "continuation-first lifecycle/meta locking excludes both control and direct replacement through admission and publication"
}

test_control_and_direct_replacements_exclude_continuation_authorization() {
  local dir id entry ready release replacement_pid out rc
  for entry in control direct; do
    id="rlreplacement-first-$entry"
    dir=$(new_case "replacement-first-$entry" "$id")
    seed_continuation_case "$dir" "$id"
    printf zsh > "$dir/fake/command"
    ready="$dir/launch-ready"
    release="$dir/launch-release"
    if [ "$entry" = control ]; then
      FM_FAKE_TRACE_PREPARE="$ready" FM_FAKE_TRACE_RELEASE="$release" \
        run_control "$dir" "$id" relaunch --note "inherit reconciliation" > "$dir/replacement.out" &
    else
      FM_FAKE_TRACE_PREPARE="$ready" FM_FAKE_TRACE_RELEASE="$release" \
        run_spawn "$dir" "$id" --relaunch --harness claude > "$dir/replacement.out" &
    fi
    # shellcheck disable=SC2031 # Both branches launch a child in this parent before reading $!.
    replacement_pid=$!
    await_fixture_ready "$ready" "$replacement_pid" "$entry replacement" || {
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "could not stage $entry replacement during launch preparation"
    }
    [ -s "$dir/home/state/.control-$id.lock/pid" ] && [ -s "$dir/home/state/.meta-$id.lock/pid" ] || {
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "$entry replacement did not hold its lifecycle/meta locks during launch"
    }
    cp "$dir/home/state/$id.meta" "$dir/meta-during-launch"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    if [ "$rc" != 1 ] || [[ "$out" != *"another lifecycle action is already running"* ]]; then
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "continuation authorization interleaved with $entry replacement: $rc: $out"
    fi
    cmp -s "$dir/meta-during-launch" "$dir/home/state/$id.meta" || {
      : > "$release"
      wait "$replacement_pid" 2>/dev/null || true
      fail "contended clearance changed the replacement's metadata"
    }
    : > "$release"
    wait "$replacement_pid"; rc=$?
    expect_code 0 "$rc" "$entry replacement should finish after deterministic launch release"$'\n'"$(cat "$dir/replacement.out")"
    [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "$entry replacement converted recovery into continuation authority"
    rc=0
    out=$(run_continuation_control "$dir" "$id" authorize-continuation) || rc=$?
    expect_code 0 "$rc" "continuation authorization should succeed only after $entry replacement releases both locks"$'\n'"$out"
    [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "post-replacement clearance did not remove recovery"
  done
  pass "control/direct replacement-first lifecycle/meta locking excludes clearance and inherits recovery until explicit later authorization"
}

test_away_branch_replacement_uses_relaunch_not_fresh_dispatch_admission() {
  local dir id mode out rc
  for mode in ordinary recovery held; do
    id="rlaway-replacement-$mode"
    dir=$(new_case "away-replacement-$mode" "$id")
    seed_continuation_case "$dir" "$id"
    if [ "$mode" != recovery ]; then
      sed '/^recovery=/d' "$dir/home/state/$id.meta" > "$dir/ordinary.meta"
      mv "$dir/ordinary.meta" "$dir/home/state/$id.meta"
    else
      printf zsh > "$dir/fake/command"
    fi
    if [ "$mode" != ordinary ]; then
      tasks-axi hold "$id" --reason "captain decision pending" --kind captain \
        --file "$dir/home/data/backlog.md" >/dev/null
    fi
    FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 3 >/dev/null \
      || fail "could not establish the away replacement fixture"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    cp "$dir/home/data/backlog.md" "$dir/backlog-before"
    cp "$dir/home/data/$id/brief.md" "$dir/brief-before"
    rc=0
    out=$(FM_SUPERVISION_ACTOR=branch run_control "$dir" "$id" relaunch --note "replace under away posture without granting continuation") || rc=$?
    if [ "$mode" = held ]; then
      expect_code 1 "$rc" "away branch ordinary replacement must still refuse a held row"
      assert_contains "$out" "not dispatchable" "ordinary replacement admission must precede the away fresh-dispatch gate"
      cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "held away replacement changed metadata"
      cmp -s "$dir/brief-before" "$dir/home/data/$id/brief.md" || fail "held away replacement changed instructions"
      [ ! -s "$dir/fake/literal" ] || fail "held away replacement sent launch bytes"
      [ ! -s "$dir/fake/keys" ] || fail "held away replacement sent preparation keys"
      [ "$(cat "$dir/fake/command")" = claude ] || fail "held away replacement stopped the live instruction owner"
    else
      expect_code 0 "$rc" "away branch $mode replacement of existing In-flight work should not require queued fresh work"$'\n'"$out"
      [ "$(cat "$dir/fake/command")" = claude ] || fail "away branch replacement did not restore the instruction owner"
      if [ "$mode" = recovery ]; then
        [ "$(meta_field "$dir" "$id" recovery)" = reconcile-only ] || fail "away replacement dropped reconciliation-only scope"
        assert_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
          "away replacement did not inherit recovery-only instructions"
      else
        [ "$(meta_field "$dir" "$id" recovery)" = '' ] || fail "ordinary away replacement acquired an unsolicited recovery scope"
        assert_no_grep '# Current reconciliation-only recovery contract' "$dir/home/data/$id/launch-brief.md" \
          "ordinary away replacement acquired recovery-only instructions"
      fi
    fi
    cmp -s "$dir/backlog-before" "$dir/home/data/backlog.md" || fail "away replacement changed an existing In-flight row or hold"
    assert_not_contains "$out" "may dispatch only queued unblocked work" "replacement incorrectly entered the away fresh-dispatch gate"
  done
  pass "away branch replacement applies ordinary/recovery replacement admission without fresh queued-only dispatch"
}

control_relaunch_test_cases=()
if fm_tasks_axi_compatible; then
  control_relaunch_test_cases+=(
    test_held_relaunch_refuses_without_stopping_the_live_owner
    test_exited_owner_reconciliation_preserves_holds_dependencies_and_work
    test_session_end_replacement_cannot_convert_recovery_to_execution
    test_reconciliation_refuses_live_queued_and_unowned_dispatch
    test_blocked_relaunch_admission_is_shared_across_supported_harnesses
    test_herdr_held_owner_refusal_and_exited_reconciliation
    test_continuation_authorization_requires_the_lock_owning_main
    test_continuation_authorization_rejects_relaunch_options_and_arbitrary_input
    test_continuation_authorization_preserves_blocked_ordinary_admission
    test_continuation_authorization_requires_current_automatic_backlog_and_recovery
    test_continuation_authorization_only_clears_recovery_before_future_relaunch
    test_continuation_authorization_excludes_control_and_direct_replacements
    test_control_and_direct_replacements_exclude_continuation_authorization
    test_away_branch_replacement_uses_relaunch_not_fresh_dispatch_admission
  )
else
  echo "skip - recovery admission fixtures require compatible tasks-axi"
fi
control_relaunch_test_cases+=(
  test_tmux_gone_endpoint_is_proven_despite_unrelated_servers
  test_tmux_worktree_local_recovery_with_real_lsof
  test_tmux_refuses_while_the_recorded_endpoint_may_be_live
  test_tmux_unreadable_evidence_refuses
  test_tmux_no_server_reclaim_keeps_work_and_task
  test_tmux_reclaim_refuses_other_configured_backends
  test_reclaim_refuses_an_unreadable_endpoint
  test_relocation_rebinds_a_vanished_worktree_to_a_fresh_copy
  test_relocation_checks_every_recorded_head_and_requires_evidence
  test_relocation_refuses_every_unsafe_destination
  test_relocation_refuses_unreadable_head_evidence
  test_relocation_refuses_a_copy_another_local_home_records
  test_relocation_never_overwrites_or_deletes_a_foreign_harness_file
  test_relocation_proof_survives_every_failure_journal_rewrite
  test_relocation_proof_survives_later_ordinary_launch_failure
  test_relocation_requires_a_newer_ordinary_relaunch_checkpoint
  test_relocation_claims_and_respects_pool_slot_ownership
  test_relocation_refuses_a_non_lease_copy
  test_concurrent_pool_slot_claim_publishes_one_owner
  test_unpublished_relocation_releases_only_its_new_pool_claim
  test_relocation_flag_is_scoped_to_relaunch
  test_herdr_relaunch_resumes_only_the_registered_pi_session
  test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
  test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
  test_herdr_recovery_refuses_an_unproven_server_stop
  test_herdr_rebind_stays_in_the_recorded_session
  test_herdr_reclaim_refuses_an_agent_that_came_back
  test_herdr_reclaim_keeps_the_task_whole
  test_herdr_reclaim_of_a_secondmate_names_its_own_owner
  test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause
  test_recovery_fixture_claims_only_owned_temp_directories
)

control_relaunch_run "$@"
