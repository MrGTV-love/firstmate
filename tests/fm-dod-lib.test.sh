#!/usr/bin/env bash
# Behavior tests for bin/fm-dod-lib.sh's named-head reachability gate on ship
# done: acceptance (issue 4768). The gate must test the commit the worker names,
# not merely that some remote-tracking branch exists or moved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dod-lib)
fm_git_identity fmtest fmtest@example.invalid

accept_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  fm_dod_accept_ship_done "$@"
}

write_merge_marker() {  # <state> <id> <provider> <host> <path> <number>
  printf '%s\n' fm-pr-poll-merge-notified-v1 "$3" "$4" "$5" "$6" > "$1/$2.pr-poll-merge-notified"
  chmod 600 "$1/$2.pr-poll-merge-notified"
}

test_dod_file_examples_are_not_directives() {
  local brief="$TMP_ROOT/fenced-dod.md" fence out rc
  mkdir -p "$TMP_ROOT"
  for fence in '```' '~~~'; do
    cat > "$brief" <<EOF
## Definition Of Done (task)
Capability in plain words: Deliver the specified behavior.
### Mandatory items
The help text includes this example:
${fence}text
DoD file: $TMP_ROOT/example-only.md
## How You're Graded
${fence}
### Hard gates
Preserve the real criteria.
## How You're Graded
EOF
    out=$(fm_brief_task_dod_problem "$brief"); rc=$?
    [ "$rc" -eq 1 ] && [ -z "$out" ] \
      || fail "a fenced DoD-file example refused actual criteria: $out"
  done
  pass "fenced DoD-file examples do not refuse actual criteria"
}

test_unfenced_dod_file_is_still_honored() {
  local brief="$TMP_ROOT/real-dod.md" criteria="$TMP_ROOT/criteria.md" out rc
  cat > "$brief" <<EOF
## Definition Of Done (task)
\`\`\`text
DoD file: $TMP_ROOT/example-only.md
\`\`\`
DoD file: $criteria
## How You're Graded
EOF
  out=$(fm_brief_task_dod_problem "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail "an unreadable real DoD file must refuse"
  assert_contains "$out" "DoD file $criteria is not a readable file" "the real directive after an example must be honored"
  printf '{DOD_MANDATORY_ITEMS}\n' > "$criteria"
  out=$(fm_brief_task_dod_problem "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail "a real DoD file with placeholders must refuse"
  assert_contains "$out" "DoD file $criteria:" "the real criteria file must be checked"
  printf 'Ship the specified behavior and retain the safety guard.\n' > "$criteria"
  out=$(fm_brief_task_dod_problem "$brief"); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$out" ] || fail "a readable filled real DoD file must pass: $out"
  pass "unfenced DoD-file directives after fenced examples remain authoritative"
}

# Exercise the executable plan interface, including nested criteria and fenced
# examples, rather than asserting the library's implementation text.
test_verification_plan_keeps_criteria_separate_from_intent() {
  local brief="$TMP_ROOT/plan-brief.md" plan out criteria="$TMP_ROOT/plan-criteria.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the stale badge.
## Firstmate spec
Firstmate-only build constraints must not become intent or review criteria.
### Out of scope
- Do not redesign the dashboard.
### Implementation
Keep the existing renderer.
# Definition of done
## Definition Of Done (task)
The badge updates after a refresh.
### Mandatory items
- A failed refresh retains the last known value.
## How You're Graded
This grading prose is not a criterion.
EOF
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") \
    || fail "could not build verification plan"
  assert_contains "$plan" 'The badge updates after a refresh.' 'plan lost task criteria'
  assert_contains "$plan" 'A failed refresh retains the last known value.' 'plan lost nested criteria'
  assert_contains "$plan" 'Do not redesign the dashboard.' 'plan lost the exclusions'
  assert_not_contains "$plan" 'Keep the existing renderer.' 'plan included unrelated build instructions'
  assert_not_contains "$plan" 'Firstmate-only build constraints' 'plan included mixed Firstmate specification'
  assert_not_contains "$plan" 'This grading prose' 'plan included the grading section'
  assert_contains "$plan" 'Every factual claim in a PR body must be backed by a record' 'plan lost the shared claim check'
  assert_contains "$plan" 'Grade every DoD mandatory item pass or fail by its id, with the evidence' 'plan lost per-item grading'
  assert_contains "$plan" 'A failed DoD mandatory item: block.' 'plan lost the failed-item outcome'
  assert_contains "$plan" 'A real defect that breaks the stated intent, even when no DoD item names it: block.' 'plan lost the intent-defect outcome'
  assert_contains "$plan" 'An improvement outside the DoD: a follow-up note, never a block.' 'plan lost the follow-up outcome'
  assert_contains "$plan" 'A change that lets a guard permit more than before, such as an added exception, allow-list entry, trust carve-out, relaxed threshold or widened scope: block with verdict FAIL' 'plan lost the guard-widening FAIL outcome'
  assert_contains "$plan" 'A fix that would add scope beyond the intent: escalate to Main for the owner' 'plan lost the scope-escalation outcome'
  assert_not_contains "$plan" 'scout-time context' 'an unpromoted plan was labeled as scout context'

  printf '# Task\nLegacy task.\n' > "$brief"
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'legacy plan crashed'
  assert_contains "$plan" 'Task Definition Of Done: absent' 'legacy plan concealed absent criteria'
  assert_contains "$plan" 'Out-of-scope list: no recognized' 'legacy plan concealed unrecognized exclusions'
  assert_contains "$plan" 'check the Firstmate spec for inline exclusions' 'legacy plan did not send the reviewer to the spec'

  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the badge refresh.
## Firstmate spec
Keep the existing renderer.
Out of scope: Do not redesign the dashboard.
- Do not change billing.

Other build constraints must not become exclusions.
### Out of scope
# Setup
EOF
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'legacy exclusion paragraph failed'
  assert_contains "$plan" 'Do not redesign the dashboard.' 'legacy scope paragraph was dropped'
  assert_contains "$plan" 'Do not change billing.' 'legacy scope list was dropped'
  assert_not_contains "$plan" 'Other build constraints' 'legacy scope paragraph consumed unrelated build constraints'
  assert_contains "$plan" 'Task Definition Of Done: absent' 'missing DoD with exclusions was concealed'

  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the badge refresh.
## Firstmate spec
Keep the existing renderer.
- Out of scope: Jev skill picking (separate task), any other Jev call site.
EOF
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'inline exclusion list item failed'
  assert_not_contains "$plan" 'Out-of-scope list: absent' 'an inline exclusion list item was reported absent'
  assert_contains "$plan" 'Out-of-scope list: no recognized' 'an unrecognized inline exclusion was not flagged'
  assert_contains "$plan" 'check the Firstmate spec for inline exclusions' 'an unrecognized inline exclusion did not send the reviewer to the spec'

  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the badge refresh.
Out of scope: Do not touch the billing page.
## Firstmate spec
Keep the existing renderer.
Out of scope: Do not rename the badge.
### Out of scope
- Do not redesign the dashboard.
Out of scope: Do not change the dashboard layout.
EOF
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'multi-source exclusions failed'
  assert_contains "$plan" 'Do not touch the billing page.' "exclusions under Captain's intent were reported absent"
  assert_contains "$plan" 'Do not rename the badge.' 'a legacy spec paragraph was dropped beside the subsection'
  assert_contains "$plan" 'Do not redesign the dashboard.' 'the Out of scope subsection was dropped'
  assert_not_contains "$plan" 'Out-of-scope list: no recognized' 'present exclusions were reported unrecognized'
  [ "$(printf '%s\n' "$plan" | grep -c 'Do not change the dashboard layout.')" -eq 1 ] \
    || fail 'a marker line inside the subsection was printed twice'

  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the badge refresh.
### Out of scope
- Captain exclusion A.
## Firstmate spec
Keep the existing renderer.
### Out of scope
- Spec exclusion B.
#### Detail
- Spec exclusion C.
### Implementation
Build notes are not exclusions.
EOF
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'multi-subsection exclusions failed'
  assert_contains "$plan" 'Captain exclusion A.' 'the first Out of scope subsection was dropped'
  assert_contains "$plan" 'Spec exclusion B.' 'a later Out of scope subsection was dropped'
  assert_contains "$plan" 'Spec exclusion C.' 'a nested list inside an Out of scope subsection was dropped'
  assert_not_contains "$plan" 'Build notes are not exclusions.' 'a following subsection leaked into exclusions'
  [ "$(printf '%s\n' "$plan" | grep -c 'exclusion [ABC]\.')" -eq 3 ] \
    || fail 'an Out of scope subsection was printed more than once'
  case "$plan" in
    *'Captain exclusion A.'*'Spec exclusion B.'*) ;;
    *) fail 'Out of scope subsections were not printed in brief order' ;;
  esac
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the badge refresh.
Out of scope: legacy list item one.
#12 legacy list item two.
## Firstmate spec
Keep the existing renderer.
### Out of scope
- Keep A.
#1 priority is B.
- Keep C.
EOF
  out=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'hash-led exclusion lines failed'
  assert_contains "$out" '#12 legacy list item two.' 'a hash-led line ended a legacy exclusion paragraph'
  assert_contains "$out" '#1 priority is B.' 'a hash-led line ended an Out of scope subsection'
  assert_contains "$out" '- Keep C.' 'exclusions after a hash-led line were dropped'
  plan=$(cd "$ROOT/bin" && bash fm-dod-lib.sh --verification-plan "$brief" 2>&1) \
    || fail "a relative builder path could not find the shared rubric: $plan"
  assert_contains "$plan" 'Every factual claim in a PR body must be backed by a record' 'a relative builder path lost the rubric'
  if out=$(fm_dod_block no-mistakes no-brief-task 2>&1); then
    fail 'a no-mistakes contract rendered without its durable brief'
  fi
  assert_contains "$out" 'needs the durable task brief' 'missing-brief refusal was not actionable'

  printf 'A failed refresh retains the last known value.\n' > "$criteria"
  cat > "$brief" <<EOF
## Definition Of Done (task)
\`\`\`text
DoD file: $TMP_ROOT/not-a-directive.md
\`\`\`
DoD file: $criteria
{DOD_MANDATORY_ITEMS}
## How You're Graded
EOF
  plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'external criteria plan failed'
  assert_contains "$plan" "A failed refresh retains the last known value." 'plan passed only a DoD-file pointer'
  assert_not_contains "$plan" '{DOD_MANDATORY_ITEMS}' 'external criteria did not replace scaffold placeholders'
  assert_contains "$plan" 'Out-of-scope list: no recognized' 'a brief with DoD but no exclusions concealed the omission'
  rm "$criteria"
  if plan=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief" 2>&1); then
    fail 'missing external criteria silently emitted a plan'
  fi
  assert_contains "$plan" "$criteria" 'missing criteria error did not name the missing file'
  pass 'verification plans carry actual criteria, exclusions and rubric without broadening intent'
}

test_verification_plan_requires_its_shared_rubric() {
  local isolated="$TMP_ROOT/isolated-code" brief="$TMP_ROOT/legacy-plan.md" out
  mkdir -p "$isolated"
  cp -R "$ROOT/bin" "$isolated/bin"
  printf '# Task\nLegacy task.\n' > "$brief"
  if out=$(bash "$isolated/bin/fm-dod-lib.sh" --verification-plan "$brief" 2>&1); then
    fail 'plan succeeded without the shared rubric'
  fi
  assert_contains "$out" 'shared review rubric is not a readable file' 'missing rubric error was not actionable'
  assert_contains "$out" "$isolated/docs/review-rubric.md" 'missing rubric error did not name its owner'
  pass 'missing shared rubric refuses verification-plan construction'
}

test_verification_plan_preserves_crlf_criteria_and_refuses_nul() {
  local brief="$TMP_ROOT/byte-plan.md" criteria="$TMP_ROOT/byte-criteria.md" out rc
  printf "# Task\r\n## Captain's intent\r\nFix the badge.\r\nOut of scope: Keep billing.\r\n## Firstmate spec\r\nKeep the renderer.\r\n### Out of scope\r\n- Keep layout.\r\n## Definition Of Done (task)\r\n### Mandatory items\r\nM1: Refresh the badge.\r\n## How You're Graded\r\nNot a criterion.\r\n" > "$brief"
  out=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'CRLF plan construction failed'
  assert_contains "$out" 'M1: Refresh the badge.' 'CRLF criteria were lost'
  assert_contains "$out" 'Out of scope: Keep billing.' 'CRLF legacy exclusions were lost'
  assert_contains "$out" '- Keep layout.' 'CRLF subsection exclusions were lost'
  assert_not_contains "$out" 'Not a criterion.' 'CRLF grading boundary was lost'
  assert_not_contains "$out" 'absent' 'CRLF criteria were misreported as absent'
  printf 'M2: Preserve the last value on error.\r\n' > "$criteria"
  printf '## Definition Of Done (task)\r\nDoD file: %s\r\n{DOD_MANDATORY_ITEMS}\r\n## How You'\''re Graded\r\n' "$criteria" > "$brief"
  out=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief") || fail 'CRLF criteria directive failed'
  assert_contains "$out" 'M2: Preserve the last value on error.' 'CRLF external criteria were lost'
  assert_not_contains "$out" '{DOD_MANDATORY_ITEMS}' 'CRLF directive did not replace the scaffold'
  printf '\000' >> "$criteria"
  out=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail 'NUL external criteria silently emitted a plan'
  assert_contains "$out" "malformed input $criteria: NUL bytes" 'criteria refusal did not name malformed input'
  out=$(fm_brief_dispatch_problems "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail 'NUL external criteria passed dispatch validation'
  assert_contains "$out" "malformed input $criteria: NUL bytes" 'dispatch misreported malformed criteria'
  out=$(fm_brief_task_dod_problem "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail 'NUL external criteria passed the single-problem check'
  assert_contains "$out" "malformed input $criteria: NUL bytes" 'single-problem check misreported malformed criteria'
  printf '## Definition Of Done (task)\000\nM3: Keep the criterion.\n' > "$brief"
  out=$(bash "$ROOT/bin/fm-dod-lib.sh" --verification-plan "$brief" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail 'NUL brief silently emitted a plan'
  assert_contains "$out" "malformed input $brief: NUL bytes" 'brief refusal did not name malformed input'
  assert_not_contains "$out" 'absent' 'NUL brief misreported criteria as absent'
  pass 'CRLF criteria and exclusions survive; NUL briefs and external criteria refuse explicitly'
}

test_verification_plan_preserves_crlf_criteria_and_refuses_nul

test_verification_plan_keeps_criteria_separate_from_intent
test_verification_plan_requires_its_shared_rubric

test_scout_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/scout-repo"
  wt="$TMP_ROOT/scout-wt"
  fm_git_worktree "$repo" "$wt" fm/scout
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done scout no-mistakes "$wt" "$repo" 'done: report written' \
    || fail "scout done: must not require named-head reachability outside the copy"
  pass "scout done: is not gated"
}

test_unpushed_ship_done_is_refused() {
  local repo wt sha reason rc
  repo="$TMP_ROOT/unpushed-repo"
  wt="$TMP_ROOT/unpushed-wt"
  fm_git_worktree "$repo" "$wt" fm/unpushed
  git -C "$wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/1 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "unpushed ship done: was accepted (exit $rc)"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy") ;;
    *) fail "unpushed refusal did not name the commit: $reason" ;;
  esac
  pass "unpushed ship done: is refused"
}

test_remote_containing_named_head_is_accepted() {
  local repo wt sha
  repo="$TMP_ROOT/pushed-repo"
  wt="$TMP_ROOT/pushed-wt"
  fm_git_worktree "$repo" "$wt" fm/pushed
  git -C "$wt" commit -q --allow-empty -m 'fix on the branch'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/pushed "$sha"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/2 checks green" \
    || fail "named head on a remote-tracking ref was refused"
  pass "named head on a remote-tracking ref is accepted"
}

test_moved_branch_without_named_head_is_refused() {
  local repo wt main_sha fix_sha reason rc
  repo="$TMP_ROOT/moved-repo"
  wt="$TMP_ROOT/moved-wt"
  fm_git_worktree "$repo" "$wt" fm/moved
  main_sha=$(git -C "$repo" rev-parse main)
  git -C "$wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$wt" rev-parse HEAD)
  # The fork branch exists and moved, but only to a merge of the default
  # branch: reachability of that branch is not reachability of the named head.
  git -C "$wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/3 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "moved remote branch without the named head was accepted"
  case "$reason" in
    *"named head $fix_sha is unreachable outside the worker copy") ;;
    *) fail "moved-branch refusal did not name the fix commit: $reason" ;;
  esac
  pass "a moved remote branch that lacks the named head is refused"
}

test_no_mistakes_prevalidation_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/preval-repo"
  wt="$TMP_ROOT/preval-wt"
  fm_git_worktree "$repo" "$wt" fm/preval
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done ship no-mistakes "$wt" "$repo" 'done: implementation complete' \
    || fail "no-mistakes pre-validation done: must not require named-head reachability"
  pass "no-mistakes pre-validation done: is not gated"
}

test_local_only_linked_branch_is_accepted() {
  local repo wt
  repo="$TMP_ROOT/local-repo"
  wt="$TMP_ROOT/local-wt"
  fm_git_worktree "$repo" "$wt" fm/local
  git -C "$wt" commit -q --allow-empty -m 'local-only work'
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/local" \
    || fail "local-only named branch in a linked worktree was refused"
  pass "local-only linked named branch is reachable from the project clone"
}

test_local_only_detached_head_is_refused() {
  local repo wt sha rc
  repo="$TMP_ROOT/detach-repo"
  wt="$TMP_ROOT/detach-wt"
  fm_git_worktree "$repo" "$wt" fm/detach
  git -C "$wt" commit -q --allow-empty -m 'detached only'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q --detach HEAD
  git -C "$wt" branch -q -D fm/detach
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/detach" >/dev/null \
    && fail "detached local-only head whose branch was deleted was accepted"
  rc=0
  accept_done ship local-only "$wt" "$repo" "done: implementation complete" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "detached local-only HEAD was accepted as done"
  pass "local-only detached HEAD only in the disposable copy is refused"
}

test_standalone_local_only_needs_project_ref() {
  local repo wt sha
  repo="$TMP_ROOT/stand-project"
  wt="$TMP_ROOT/stand-copy"
  fm_git_init_commit "$repo"
  git clone --quiet "$repo" "$wt"
  git -C "$wt" checkout -q -b fm/stand
  git -C "$wt" commit -q --allow-empty -m 'only in the standalone copy'
  sha=$(git -C "$wt" rev-parse HEAD)
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" >/dev/null \
    && fail "standalone local-only copy was accepted without the named head in the project clone"
  git -C "$repo" fetch -q "$wt" "fm/stand:fm/stand"
  [ "$(git -C "$repo" rev-parse fm/stand)" = "$sha" ] \
    || fail "project clone did not gain the named head"
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" \
    || fail "standalone local-only named head present in the project clone was refused"
  pass "standalone local-only done: requires the named head in the project clone"
}

test_free_text_sha_is_not_the_named_head() {
  local repo wt old new reason rc
  repo="$TMP_ROOT/hex-repo"
  wt="$TMP_ROOT/hex-wt"
  fm_git_worktree "$repo" "$wt" fm/hex
  old=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/main "$old"
  git -C "$wt" commit -q --allow-empty -m 'actual fix'
  new=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: reverted $old and fixed the retry")
  rc=$?
  [ "$rc" -eq 1 ] || fail "free-text SHA on origin/main made an unpushed HEAD accept"
  case "$reason" in
    *"named head $new is unreachable outside the worker copy") ;;
    *) fail "free-text SHA scan still selected the old commit: $reason" ;;
  esac
  pass "a 40-hex token in the note is not the named head"
}

test_recorded_merged_pr_is_landed_after_prune() {
  local repo wt meta state
  repo="$TMP_ROOT/merged-repo"
  wt="$TMP_ROOT/merged-wt"
  state="$TMP_ROOT/merged-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/merged
  git -C "$wt" commit -q --allow-empty -m 'fix, squash-merged and branch pruned'
  meta="$state/merged.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" merged github github.com o/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" merged "$meta" \
    || fail "recorded merged PR was refused after its remote-tracking ref was pruned"
  pass "a recorded merged PR satisfies the gate after prune"
}

test_merge_marker_binds_to_the_named_pr() {
  local repo wt meta state reason rc sha
  repo="$TMP_ROOT/bind-repo"
  wt="$TMP_ROOT/bind-wt"
  state="$TMP_ROOT/bind-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/bind
  git -C "$wt" commit -q --allow-empty -m 'second PR head, never pushed'
  sha=$(git -C "$wt" rev-parse HEAD)
  meta="$state/bind.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" bind github github.com o/r 7
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/9" "$state" bind "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "merge of recorded PR 7 accepted an unpushed done naming PR 9"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy") ;;
    *) fail "PR 9 refusal did not name the unpushed head: $reason" ;;
  esac
  write_merge_marker "$state" bind github github.com other/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" bind "$meta" >/dev/null \
    && fail "merge marker for another repository's PR 7 was accepted"
  pass "the merged-PR short-circuit applies only to the recorded PR the done line names"
}

test_forge_recorded_head_is_accepted_without_local_object() {
  local repo wt meta state forge_head
  repo="$TMP_ROOT/forge-repo"
  wt="$TMP_ROOT/forge-wt"
  state="$TMP_ROOT/forge-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/forge
  git -C "$wt" commit -q --allow-empty -m 'worker head, not pushed from this copy'
  # The pipeline's own commit: on the forge and in the gate repo, never
  # fetched into the worker clone.
  forge_head=0123456789abcdef0123456789abcdef01234567
  meta="$state/forge.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$forge_head" > "$meta"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/5 checks green" \
    "$state" forge "$meta" \
    || fail "forge-recorded pr_head the worker clone never fetched was refused"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/6 checks green" \
    "$state" forge "$meta" >/dev/null \
    && fail "pr_head recorded for PR 5 was accepted for a done naming PR 6"
  pass "a forge-recorded head for the named PR is accepted without a local object"
}

# A direct-PR worker pushes from its own copy: a commit made after the PR's
# recorded head, never pushed, is the named head and is refused.
test_direct_pr_recorded_head_does_not_cover_unpushed_commit() {
  local repo wt meta state pushed later reason rc
  repo="$TMP_ROOT/postopen-repo"
  wt="$TMP_ROOT/postopen-wt"
  state="$TMP_ROOT/postopen-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/postopen
  git -C "$wt" commit -q --allow-empty -m 'pushed when the PR opened'
  pushed=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/postopen "$pushed"
  git -C "$wt" commit -q --allow-empty -m 'the fix, only in the worktree'
  later=$(git -C "$wt" rev-parse HEAD)
  meta="$state/postopen.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$pushed" > "$meta"
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/5" "$state" postopen "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "direct-PR recorded pr_head accepted an unpushed later commit"
  case "$reason" in
    *"named head $later is unreachable outside the worker copy") ;;
    *) fail "direct-PR refusal did not name the unpushed commit: $reason" ;;
  esac
  pass "a direct-PR recorded head does not cover a later unpushed commit"
}

test_ci_ready_requires_pr_reference() {
  local note
  for note in \
    'paused: PROD deploy watch, checks green on TEST' \
    'paused: checks green on TEST, PROPERTIES watch' \
    'PR checks green' \
    'PR #12 checks pending' \
    'PR https://review.example.org/c/team/project/+/123 checks pending' \
    'https://review.example.org/c/team/project/+/not-a-number checks green'; do
    if fm_dod_note_reports_ci_ready "$note"; then
      fail "non-CI-ready note accepted: $note"
    fi
  done
  for note in \
    'PR https://github.com/o/r/pull/5 checks green' \
    'checks green: https://github.com/o/r/pull/5' \
    'PR #12 checks green' \
    'checks green: PR#12' \
    'https://gitlab.com/o/r/-/merge_requests/5 checks green' \
    'https://git.example.org/team/repo/pulls/12 checks green' \
    'PR https://review.example.org/c/project/+/123 checks green' \
    'checks green: https://review.example.org/c/team/project/+/456'; do
    fm_dod_note_reports_ci_ready "$note" \
      || fail "CI-ready PR reference rejected: $note"
  done
  pass "CI-ready notes require checks green and an actual PR reference"
}

test_ci_ready_variants_are_gated() {
  local repo wt line rc
  repo="$TMP_ROOT/variant-repo"
  wt="$TMP_ROOT/variant-wt"
  fm_git_worktree "$repo" "$wt" fm/variant
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'done: PR https://github.com/o/r/pull/5 checks green, risk low' \
    'done: PR https://github.com/o/r/pull/5 - checks green' \
    'done: PR https://github.com/o/r/pull/5 checks green.' \
    'done: PR https://github.com/o/r/pull/5 (checks green)'; do
    rc=0
    accept_done ship no-mistakes "$wt" "$repo" "$line" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "no-mistakes CI-ready variant skipped the gate: $line"
  done
  pass "no-mistakes CI-ready done: with extra text is gated"
}

test_keyed_and_spaced_done_lines_are_gated() {
  local repo wt line mode rc
  repo="$TMP_ROOT/keyed-repo"
  wt="$TMP_ROOT/keyed-wt"
  fm_git_worktree "$repo" "$wt" fm/keyed
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'no-mistakes|done [key=fix]: PR https://github.com/o/r/pull/5 checks green' \
    'no-mistakes|done : PR https://github.com/o/r/pull/5 checks green' \
    'direct-PR|done [key=fix]: PR https://github.com/o/r/pull/5' \
    'direct-PR|done: [key=fix] PR https://github.com/o/r/pull/5'; do
    mode=${line%%|*}
    rc=0
    accept_done ship "$mode" "$wt" "$repo" "${line#*|}" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "$mode done line skipped the gate: ${line#*|}"
  done
  pass "keyed and spaced ship done: lines are gated"
}

test_non_done_lines_are_not_gated() {
  local repo wt
  repo="$TMP_ROOT/nongate-repo"
  wt="$TMP_ROOT/nongate-wt"
  fm_git_worktree "$repo" "$wt" fm/nongate
  git -C "$wt" commit -q --allow-empty -m 'unpushed'
  accept_done ship no-mistakes "$wt" "$repo" 'working: still implementing' \
    || fail "working: line was gated"
  accept_done ship no-mistakes "$wt" "$repo" 'blocked: waiting on a credential' \
    || fail "blocked: line was gated"
  pass "non-done lines are not gated"
}

# Issue 3608: a legacy `# Task` body's provenance marker must be read the way
# bin/fm-brief-heading-lib.sh reads headings - outside fenced blocks and never
# from an indented example - or a fenced `Captain:` sample becomes the ship
# contract's intent while the real ask is dropped.
test_fenced_and_indented_captain_lines_are_not_intent() {
  local home id meta out status words
  home="$TMP_ROOT/fenced-home"
  mkdir -p "$home/state" "$home/data"
  words=$(fm_brief_marked_captain_words 'Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
[captain] Neither must this one.
```

~~~
Captain: Nor this tilde-fenced one.
~~~

    Captain: An indented example is not the ask either.
	[captain] Nor a tab-indented one.
Keep this Firstmate constraint out of captain intent.')
  assert_equals "" "$words" "fenced or indented Captain lines were extracted as authorized intent"

  words=$(fm_brief_marked_captain_words '```
Captain: fenced example
```
  [captain] Preserve the real ask after the fence closes.
````
Captain: a longer fence that a shorter closer must not end
```
Captain: still fenced
````')
  assert_equals "Preserve the real ask after the fence closes." "$words" \
    "the marker after a closed fence, or inside a longer fence, was misread"

  id=promote-fenced-captain
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
```

    Captain: An indented example is not the ask either.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion whose only Captain lines are fenced or indented examples should fail"
  assert_contains "$out" "has no provenance-marked Captain's intent" \
    "fenced-example promotion did not refuse like an unmarked legacy brief"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "fenced-example promotion published a fenced sample as captain intent"
  assert_grep 'kind=scout' "$meta" "fenced-example promotion changed the task record"
  pass "fenced and indented Captain lines are not authorized intent"
}

# The draft check the DoD hands a worker must be the gh-axi path that rule 3 of
# every ship brief requires for GitHub operations, never raw gh (issue 5325).
test_pr_based_dod_draft_check_uses_gh_axi() {
  local mode out
  for mode in direct-PR no-mistakes; do
    out="$TMP_ROOT/dod-$mode.md"
    fm_dod_block "$mode" dod-draft-task fm/dod-draft-task none '' '' "$TMP_ROOT/dod-draft-task/brief.md" > "$out"
    assert_no_grep 'gh pr view' "$out" "$mode: DoD must not document a raw gh draft check"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`' "$out" \
      "$mode: DoD must read the draft state through gh-axi"
  done
  pass "PR-based DoD draft check uses gh-axi"
}

# A scout spawned on a named base keeps that base through promotion: the ship
# instructions start from it and the PR targets it; local-only cannot carry it.
# A task owns several PRs only on positive evidence in its own records: a
# recorded pr= or a landed merge that is another PR, or a ready report naming
# another PR of the same project. Anything absent, malformed, or about the same
# PR is a single-PR task, which the merge guard judges on its copy's HEAD.
test_task_owns_several_prs_only_on_positive_evidence() {
  local state meta url=https://github.com/o/r/pull/10 other=https://github.com/o/r/pull/11
  state="$TMP_ROOT/several-prs-state"
  mkdir -p "$state"
  meta="$state/t.meta"
  fm_write_meta "$meta" 'kind=ship' 'mode=direct-PR'

  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    && fail "a task with no other PR on record was read as owning several"
  fm_dod_task_owns_several_prs "$state" t "$state/absent.meta" "$url" \
    && fail "an absent meta was read as owning several"

  fm_write_meta "$meta" 'kind=ship' 'mode=direct-PR' "pr=$url"
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    && fail "a recorded pr= that is the named PR was read as owning several"
  printf 'done [at=1]: PR %s checks green\n' "$url" > "$state/t.status"
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    && fail "a ready report for the named PR alone was read as owning several"

  fm_write_meta "$meta" 'kind=ship' 'mode=direct-PR' "pr=$other"
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    || fail "a recorded pr= that is another PR was not read as owning several"

  fm_write_meta "$meta" 'kind=ship' 'mode=direct-PR' "pr=$url"
  write_merge_marker "$state" t github github.com o/r 11
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    || fail "a landed merge of another PR was not read as owning several"
  write_merge_marker "$state" t github github.com o/r 10
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    && fail "a landed merge of the named PR was read as owning several"
  printf 'not-a-marker\ngithub\ngithub.com\no/r\n11\n' > "$state/t.pr-poll-merge-notified"
  chmod 600 "$state/t.pr-poll-merge-notified"
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    && fail "a malformed merge marker was read as owning several"
  rm -f "$state/t.pr-poll-merge-notified"

  printf 'done [at=2]: PR %s checks green\n' "$other" >> "$state/t.status"
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    || fail "a ready report naming another PR was not read as owning several"

  # Prose that merely mentions a PR, another project's PR, and a non-ready
  # verb are not ready reports for another PR of this project.
  printf 'done [at=1]: PR %s checks green\n' "$url" > "$state/t.status"
  {
    printf 'working [at=2]: PR %s is the sibling to rebase on\n' "$other"
    printf 'done [at=3]: PR https://github.com/o/elsewhere/pull/11 checks green\n'
    printf 'done [at=4]: see https://github.com/o/r/pull/11 for context\n'
  } >> "$state/t.status"
  fm_dod_task_owns_several_prs "$state" t "$meta" "$url" \
    && fail "a mention, another project's PR, or a non-ready line was read as owning several"
  pass "a task owns several PRs only on positive evidence in its own records"
}

test_promotion_keeps_the_recorded_base_branch() {
  local home id meta out status mode
  home="$TMP_ROOT/promote-base-home"
  for mode in direct-PR local-only; do
    id="promote-base-$mode"
    meta="$home/state/$id.meta"
    mkdir -p "$home/state" "$home/data/$id"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nbase_branch=feature/hub\n' "$id" > "$meta"
    cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the hub bug.

## Firstmate spec
Reproduce it first.

# Setup
You are in a disposable git worktree of proj, at a detached HEAD on a clean copy of its base branch.
Base branch: feature/hub
EOF
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode "$mode" --yolo off 2>&1)
    status=$?
    if [ "$mode" = direct-PR ]; then
      expect_code 0 "$status" "promoting a scout with a recorded base should succeed"$'\n'"$out"
      # shellcheck disable=SC2016  # literal backticks in rendered prose must stay unexpanded
      assert_grep 'Return to a clean copy of the base branch `feature/hub`' "$home/data/$id/ship-instructions.md" \
        "promotion did not start the ship from the recorded base"
      # shellcheck disable=SC2016
      assert_grep 'against the base branch `feature/hub`' "$home/data/$id/ship-instructions.md" \
        "promotion did not target the PR at the recorded base"
      assert_grep 'base_branch=feature/hub' "$meta" "promotion dropped the recorded base"
    else
      [ "$status" -ne 0 ] || fail "promoting a based scout to local-only should be refused"
      assert_contains "$out" "mode=local-only" "the local-only promotion refusal did not explain itself"
      assert_grep 'kind=scout' "$meta" "a refused promotion changed the task record"
    fi
  done
  pass "promotion keeps a scout's recorded base branch and refuses local-only for it"
}

# A half-filled brief costs one refusal, not one round trip per placeholder: the
# dispatch verdict prints every leftover Task body and Definition of Done token
# in one pass, in scaffold order, and only where the scaffold puts them.
test_dispatch_verdict_lists_all_problems_in_one_pass() {
  local brief out rc token count
  brief="$TMP_ROOT/dispatch-half-filled.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
{TASK}
### Context

## Firstmate spec
{FIRSTMATE_SPEC}
### Out of scope
- Preserve the existing renderer.

## Definition Of Done (task)
Capability in plain words: {DOD_CAPABILITY}

### Mandatory items
{DOD_MANDATORY_ITEMS}

### Supporting items
Ship the listed behavior.

### Hard gates
Keep the existing safety guard.

### Honesty rule
{DOD_HONESTY_RULE}

## How You're Graded
- A session that did not build this work grades it.
EOF
  out=$(fm_brief_dispatch_problems "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail "a half-filled brief was reported dispatchable"
  for token in '{TASK}' '{FIRSTMATE_SPEC}' '{DOD_CAPABILITY}' '{DOD_MANDATORY_ITEMS}' '{DOD_HONESTY_RULE}'; do
    count=$(printf '%s\n' "$out" | grep -cF -- "$token")
    [ "$count" -ge 1 ] || fail "the dispatch verdict omitted $token: $out"
  done
  for token in '{DOD_SUPPORTING_ITEMS}' '{DOD_HARD_GATES}'; do
    if printf '%s\n' "$out" | grep -qF -- "$token"; then
      fail "the dispatch verdict reported the filled token $token: $out"
    fi
  done
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 5 ] \
    || fail "the dispatch verdict did not print exactly one line per problem: $out"
  pass "the dispatch verdict lists every leftover Task and Definition of Done token in one pass"
}

# A fully filled brief is dispatchable: no output, exit 1.
test_dispatch_verdict_passes_a_filled_brief() {
  local brief out rc
  brief="$TMP_ROOT/dispatch-filled.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the dispatch refusal.

## Firstmate spec
Print one complete list and the repair.

## Definition Of Done (task)
Capability in plain words: A half-filled brief costs one refusal.

### Mandatory items
Source: the dispatch verdict. Expected: one list. Verify: this test. Edge/negative: none. Evidence place: the test output. Authority: the grader.

### Supporting items
None.

### Hard gates
Keep the existing refusals.

### Honesty rule
Report what ran.

## How You're Graded
- A session that did not build this work grades it.
EOF
  out=$(fm_brief_dispatch_problems "$brief"); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$out" ] || fail "a fully filled brief did not pass the dispatch verdict: $out"
  pass "a fully filled brief passes the dispatch verdict with no output"
}

# An empty DoD file is a named problem, with the path the operator must fill.
test_dispatch_verdict_reports_an_empty_dod_file() {
  local brief criteria out rc
  brief="$TMP_ROOT/dispatch-empty-dod.md"
  criteria="$TMP_ROOT/dispatch-empty-criteria.md"
  : > "$criteria"
  cat > "$brief" <<EOF
# Task
## Captain's intent
Fix the dispatch refusal.

## Firstmate spec
Print one complete list and the repair.

## Definition Of Done (task)
DoD file: $criteria

## How You're Graded
- A session that did not build this work grades it.
EOF
  out=$(fm_brief_dispatch_problems "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail "an empty DoD file was reported dispatchable"
  assert_contains "$out" "DoD file $criteria is empty" "the dispatch verdict did not name the empty DoD file"
  pass "the dispatch verdict reports an empty DoD file with its path"
}

# Every token a DoD file still holds is listed, not just the first one.
test_dispatch_verdict_lists_every_token_in_the_dod_file() {
  local brief criteria out rc
  brief="$TMP_ROOT/dispatch-dod-file.md"
  criteria="$TMP_ROOT/dispatch-dod-criteria.md"
  printf '{DOD_CAPABILITY}\n\n{DOD_HARD_GATES}\n' > "$criteria"
  cat > "$brief" <<EOF
# Task
## Captain's intent
Fix the dispatch refusal.

## Firstmate spec
Print one complete list and the repair.

## Definition Of Done (task)
DoD file: $criteria

## How You're Graded
- A session that did not build this work grades it.
EOF
  out=$(fm_brief_dispatch_problems "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail "an unfinished DoD file was reported dispatchable"
  assert_contains "$out" "DoD file $criteria: ## Definition Of Done (task) still holds {DOD_CAPABILITY}" \
    "the dispatch verdict omitted the DoD file's capability token"
  assert_contains "$out" "DoD file $criteria: ### Hard gates still holds {DOD_HARD_GATES}" \
    "the dispatch verdict omitted the DoD file's hard-gates token"
  pass "the dispatch verdict lists every token a DoD file still holds"
}

# A relaunch re-checks only the Task bodies: the Definition of Done was accepted
# at the fresh spawn and is never re-litigated.
test_dispatch_verdict_task_only_skips_the_definition_of_done() {
  local brief out rc
  brief="$TMP_ROOT/dispatch-task-only.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
Fix the dispatch refusal.

## Firstmate spec
Print one complete list and the repair.

## Definition Of Done (task)
Capability in plain words: {DOD_CAPABILITY}

### Mandatory items
{DOD_MANDATORY_ITEMS}

### Supporting items
None.

### Hard gates
Keep the existing refusals.

### Honesty rule
Report what ran.

## How You're Graded
- A session that did not build this work grades it.
EOF
  out=$(fm_brief_dispatch_problems "$brief" task-only); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$out" ] \
    || fail "the task-only dispatch scope re-litigated the Definition of Done: $out"
  out=$(fm_brief_dispatch_problems "$brief"); rc=$?
  [ "$rc" -eq 0 ] || fail "a leftover Definition of Done token was reported dispatchable"
  pass "the task-only dispatch scope skips the Definition of Done and the full scope checks it"
}

# Promotion keeps its existing scope: it lists both leftover Task bodies in one
# refusal, keeps its scout-versus-ship spec sentence, and prints the repair.
test_promotion_refusal_lists_every_task_problem_in_one_pass() {
  local home id meta brief out status token
  home="$TMP_ROOT/promote-refusal-home"
  id="promote-refusal-wp1"
  meta="$home/state/$id.meta"
  mkdir -p "$home/state" "$home/data/$id"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  brief="$home/data/$id/brief.md"
  cat > "$brief" <<'EOF'
# Task
## Captain's intent
{TASK}

## Firstmate spec
{FIRSTMATE_SPEC}
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" \
    "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "an unfilled scout brief must not promote"
  for token in '{TASK}' '{FIRSTMATE_SPEC}'; do
    assert_contains "$out" "still holds $token" "promotion did not list $token"
  done
  assert_contains "$out" "  ## Captain's intent still holds {TASK}" "promotion indented the intent problem differently"
  assert_contains "$out" "  ## Firstmate spec still holds {FIRSTMATE_SPEC}" "promotion indented the spec problem differently"
  assert_contains "$out" "preserve the original ask in ## Captain's intent and fill the scout-time ## Firstmate spec; promotion generates a separate ship-time spec" \
    "promotion lost its scout-versus-ship spec boundary"
  assert_contains "$out" "error: repair: edit $brief and replace {TASK} in ## Captain's intent and {FIRSTMATE_SPEC} in ## Firstmate spec before promotion" \
    "promotion did not print the runnable repair"
  assert_grep 'kind=scout' "$meta" "a refused promotion changed the task record"
  pass "promotion lists every Task placeholder in one refusal with its scout-time boundary and the repair"
}

test_dod_file_examples_are_not_directives
test_unfenced_dod_file_is_still_honored
test_scout_done_is_not_gated
test_unpushed_ship_done_is_refused
test_no_mistakes_prevalidation_done_is_not_gated
test_remote_containing_named_head_is_accepted
test_moved_branch_without_named_head_is_refused
test_free_text_sha_is_not_the_named_head
test_recorded_merged_pr_is_landed_after_prune
test_merge_marker_binds_to_the_named_pr
test_forge_recorded_head_is_accepted_without_local_object
test_direct_pr_recorded_head_does_not_cover_unpushed_commit
test_ci_ready_requires_pr_reference
test_ci_ready_variants_are_gated
test_keyed_and_spaced_done_lines_are_gated
test_local_only_linked_branch_is_accepted
test_local_only_detached_head_is_refused
test_standalone_local_only_needs_project_ref
test_non_done_lines_are_not_gated
test_fenced_and_indented_captain_lines_are_not_intent
test_pr_based_dod_draft_check_uses_gh_axi
test_task_owns_several_prs_only_on_positive_evidence
test_promotion_keeps_the_recorded_base_branch
test_dispatch_verdict_lists_all_problems_in_one_pass
test_dispatch_verdict_passes_a_filled_brief
test_dispatch_verdict_reports_an_empty_dod_file
test_dispatch_verdict_lists_every_token_in_the_dod_file
test_dispatch_verdict_task_only_skips_the_definition_of_done
test_promotion_refusal_lists_every_task_problem_in_one_pass

# The launch role is the generated text a worker receives. It must keep the
# skill name, so a session that registers the skill loads it by name, and must
# name the skill file as the fallback for a session where the name does not
# resolve.
test_worker_role_names_skill_and_fallback_file() {
  local role_file path
  role_file="$TMP_ROOT/worker-role.txt"
  path="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
  [ -f "$path" ] || fail "Firstmate skill file is missing at $path"
  fm_brief_worker_role "$TMP_ROOT/state" upstream-4751 "$ROOT" >"$role_file"
  assert_grep "\`CONTRIBUTING.md\` and \`firstmate-coding-guidelines\` for Firstmate changes" "$role_file" \
    "worker role did not name the skill"
  assert_grep "If the \`firstmate-coding-guidelines\` skill name does not resolve in this session, read \`$path\` instead." "$role_file" \
    "worker role did not name the skill file as the fallback"
  assert_no_grep "Skill tool cannot resolve" "$role_file" \
    "worker role claims the Skill tool never resolves the skill"
  pass "worker role names the skill and its fallback skill file"
}

# This fork never had a forge=external implementation in bin/fm-dod-lib.sh.
# Merges a5f1fa1ef and 9f16517ff imported upstream's external-forge tests
# without their implementation, and revert 992ed7d6d removed only
# docs/external-review-forge.md, so an external forge is refused before
# rendering or publishing instructions.
test_external_forge_direct_pr_is_refused() {
  local rc=0 out="$TMP_ROOT/external-forge.out" err="$TMP_ROOT/external-forge.err"
  fm_forge_valid_for_mode external direct-PR test >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ] || fail "unsupported external forge returned $rc instead of refusal"
  [ ! -s "$out" ] || fail "unsupported external forge emitted a delivery contract"
  [ "$(cat "$err")" = "error: test: unknown forge 'external' (expected none, gerrit, or forgejo)" ] \
    || fail "unsupported external forge did not explain its supported alternatives: $(cat "$err")"
  pass "external-forge direct-PR is refused with the exact supported-forge diagnostic"
}

test_external_forge_brief_is_not_published() {
  local home="$TMP_ROOT/external-brief-home" rc=0
  local out="$TMP_ROOT/external-brief.out" err="$TMP_ROOT/external-brief.err"
  mkdir -p "$home"
  FM_HOME="$home" bash "$ROOT/bin/fm-brief.sh" external-pr fixture --mode direct-PR --forge external \
    >"$out" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ] || fail "external-forge brief returned $rc instead of refusal"
  [ ! -s "$out" ] || fail "refused external-forge brief announced success"
  [ "$(cat "$err")" = "error: fm-brief.sh --forge: unknown forge 'external' (expected none, gerrit, or forgejo)" ] \
    || fail "external-forge brief did not report its exact refusal: $(cat "$err")"
  [ ! -e "$home/data/external-pr/brief.md" ] || fail "refused external forge published worker instructions"
  pass "external-forge direct-PR instructions are refused without publishing a brief"
}

test_external_forge_direct_pr_is_refused
test_external_forge_brief_is_not_published
test_worker_role_names_skill_and_fallback_file

# Independent review readers may not hold a read grant for the rubric owner, so
# the emitted launch role must carry its full text and refuse without it.
test_worker_role_renders_shared_rubric() {
  local role_file line missing="$TMP_ROOT/rubric-less-root"
  role_file="$TMP_ROOT/worker-role-rubric.txt"
  fm_brief_worker_role "$TMP_ROOT/state" upstream-4751 "$ROOT" >"$role_file"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qxF -- "$line" "$role_file" || fail "worker role did not render rubric line: $line"
  done <"$ROOT/docs/review-rubric.md"
  assert_grep "apply the shared review rubric below, rendered from \`$ROOT/docs/review-rubric.md\`" "$role_file" \
    "worker role did not introduce the rendered rubric"
  assert_grep '- A change that lets a guard permit more than before, such as an added exception, allow-list entry, trust carve-out, relaxed threshold or widened scope: block with verdict FAIL, even outside the DoD' "$role_file" \
    "worker role did not carry the guard-widening FAIL outcome"
  assert_grep 'unless the PR cites a recorded reassessment of that guard'"'"'s harm model' "$role_file" \
    "worker role did not carry the guard-widening reassessment exception"
  assert_grep '- Removing a guard rule that such a recorded reassessment recommends: not a block.' "$role_file" \
    "worker role did not carry the reassessed guard-removal outcome"
  mkdir -p "$missing"
  if fm_brief_worker_role "$TMP_ROOT/state" upstream-4751 "$missing" >/dev/null 2>&1; then
    fail "worker role rendered without the shared rubric"
  fi
  pass "worker role renders the shared rubric and refuses without it"
}

test_worker_role_renders_shared_rubric

echo "all fm-dod-lib tests passed"
