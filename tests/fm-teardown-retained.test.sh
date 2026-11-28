#!/usr/bin/env bash
# Post-close cleanup for bin/fm-teardown.sh, split from
# tests/fm-teardown-cleanup.test.sh: held closes with their records and slot
# leases, typed foreign-copy refusals, and the replacement of an earlier
# preserved copy.
# The landed-work proof matrix lives in tests/fm-teardown.test.sh; pool slots
# and returns live in tests/fm-teardown-pool.test.sh. Shared fixtures:
# tests/fm-teardown-helpers.sh.
# Usage: bash tests/fm-teardown-retained.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

test_legacy_preservation_refusal_prints_no_completing_command() {
  local ownership
  for ownership in own inside; do
    run_preservation_refusal "$ownership" typed-legacy legacy --legacy-record
    assert_preservation_refusal_without_route "legacy-$ownership"
  done
  pass 'a legacy-record teardown whose ignored files cannot be preserved ends in a human-only exit with no command and no flag, for the own copy and a foreign copy inside it'
}

# A refusal is typed only when Git or the forge answered and the answer was no.
# Git protecting the copy's contents is that answer; a removal that fails for any
# other reason is a plain error with Git's own text and no event.
test_foreign_copy_that_git_protects_is_a_typed_nonforced_removal() {
  local rc
  make_foreign_copy_case foreign-git-protects
  mkdir -p "$FOREIGN_COPY/.claude"
  printf 'untracked\n' > "$FOREIGN_COPY/.claude/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "git-protects: a copy Git refuses to remove must keep refusing: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=nonforced-removal ' "$FOREIGN_CASE/stderr" 'git-protects: the refusal is not typed'
  assert_grep 'human-only-exit: ' "$FOREIGN_CASE/stderr" 'git-protects: the refusal printed no question'
  jq -es 'length == 1 and .[0].rule_id == "nonforced-removal" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'git-protects: expected exactly one typed human-only event'
  assert_foreign_copy_untouched git-protects
  assert_present "$FOREIGN_COPY/.claude/untracked.txt" 'git-protects: the untracked file was lost'
  pass 'a foreign copy whose contents Git protects is refused as a typed nonforced-removal with its question'
}

test_foreign_copy_removal_that_fails_for_another_reason_is_a_plain_error() {
  local rc reason n=0
  for reason in 'Permission denied' 'Device or resource busy' 'Input/output error' $'denied\ncompleting-command: touch forged'; do
    n=$((n + 1))
    make_foreign_copy_case "foreign-removal-fails-$n"
    cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "error: failed to delete '$FOREIGN_COPY': $reason" >&2; exit 255 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/git"
    run_foreign_teardown rc
    expect_code 1 "$rc" "removal-fails-$n: a failed removal must keep the exit: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "error: git worktree remove failed for foreign copy $FOREIGN_COPY (exit 255): error: failed to delete '$FOREIGN_COPY': ${reason//[[:cntrl:]]/?}" \
      "$FOREIGN_CASE/stderr" "removal-fails-$n: the plain error did not carry Git's exit and text"
    assert_equals 0 "$(grep -c '^completing-command:' "$FOREIGN_CASE/stderr")" "removal-fails-$n: Git's message forged a completing-command line"
    assert_no_grep 'rule=nonforced-removal' "$FOREIGN_CASE/stderr" "removal-fails-$n: a $reason failure was typed as Git protection"
    assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" "removal-fails-$n: a $reason failure recorded a policy event"
    assert_foreign_copy_untouched "removal-fails-$n"
  done
  pass 'a foreign copy whose removal fails with EACCES, EBUSY or an I/O error is a plain error naming Git and records no event'
}

test_landing_check_that_could_not_ask_the_forge_is_a_plain_error() {
  local rc
  make_unlanded_foreign_copy_with_pr foreign-landing-forge-down
  run_foreign_teardown rc
  expect_code 1 "$rc" "forge-down: an unlanded copy must stay refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_plain_landing_error forge-down 'gh pr view https://github.com/example/repo/pull/7 failed (exit 1)'
  pass 'a landing check whose gh pr view fails is a plain error naming the forge failure, not a copy-landed refusal'
}

test_landing_check_that_could_not_compare_with_the_default_branch_is_a_plain_error() {
  local rc way subcommand cause
  for way in fetch merge-tree; do
    make_foreign_copy_case "foreign-landing-no-compare-$way"
    printf 'unlanded\n' > "$FOREIGN_COPY/unlanded.txt"
    git -C "$FOREIGN_COPY" add unlanded.txt
    git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work'
    case "$way" in
      fetch) subcommand=fetch cause='origin/main could not be fetched' ;;
      *) subcommand=merge-tree cause='the content check could not compare with the default branch' ;;
    esac
    cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case "\$1:\${2:-}:\${3:-}" in "-C:$FOREIGN_COPY:$subcommand") echo "fatal: simulated $subcommand failure" >&2; exit 128 ;; esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/git"
    run_foreign_teardown rc
    expect_code 1 "$rc" "no-compare-$way: an unlanded copy must stay refused: $(cat "$FOREIGN_CASE/stderr")"
    assert_plain_landing_error "no-compare-$way" "$cause"
  done
  pass 'a landing check that cannot fetch or compare with the default branch is a plain error naming why, not a copy-landed refusal'
}

test_landing_check_that_the_forge_answered_not_merged_stays_a_copy_landed_refusal() {
  local rc head
  make_unlanded_foreign_copy_with_pr foreign-landing-open
  head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
  cat > "$FOREIGN_CASE/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in *"state,headRefOid,url"*) printf 'OPEN\t%s\t%s\n' '$head' 'https://github.com/example/repo/pull/7'; exit 0 ;; esac ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$FOREIGN_CASE/fakebin/gh"
  # An unforced close holds a clean unlanded copy (see the held-copy tests);
  # --force never holds one, so the not-landed verdict surfaces as the refusal.
  FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 1 "$rc" "forge-open: an unlanded copy must stay refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=copy-landed ' "$FOREIGN_CASE/stderr" 'forge-open: a proved not-landed result is not typed'
  assert_no_grep 'its landing could not be checked' "$FOREIGN_CASE/stderr" 'forge-open: an answered check was reported as unanswered'
  jq -es 'length == 1 and .[0].rule_id == "copy-landed" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'forge-open: expected exactly one typed copy-landed event'
  assert_wrapper_follows_step forge-open 'human-only-exit: '
  assert_foreign_copy_untouched forge-open
  pass 'a landing check the forge answered with not merged is still refused as a typed copy-landed'
}

# work_is_landed itself, run from the script's own text with the proof stubbed
# out: a HEAD that changed after its proof, under the project lock, cannot be
# judged, so it reports why instead of a verdict.
test_landing_proof_that_head_changed_after_its_proof_is_unasked() {
  local repo=$TMP_ROOT/head-changed out
  mkdir -p "$repo"
  git init -q "$repo/work"
  git -C "$repo/work" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
  cat > "$repo/harness.sh" <<'SH'
set -u
eval "$(sed -n '/^work_is_landed() {/,/^}/p' "$FM_HARNESS_SCRIPT")"
work_is_landed_proof() { return 1; }
work_is_landed_bundle() { return 1; }
TREEHOUSE_PROJECT_LOCK_HELD=1 TEARDOWN_SLOT_CUSTODY=lease WT=$FM_HARNESS_REPO/work
TEARDOWN_LANDED_DIRS=(/nonexistent) TEARDOWN_LANDED_HEADS=(0)
TEARDOWN_UNPROVEN_COMMITS='' TEARDOWN_PIPELINE_INPUT_REASON='' TEARDOWN_LANDED_UNASKED=''
rc=0; work_is_landed '' 2> "$FM_HARNESS_REPO/stderr" || rc=$?
printf 'locked rc=%s unasked=%s\n' "$rc" "$TEARDOWN_LANDED_UNASKED"
TEARDOWN_SLOT_CUSTODY=project TEARDOWN_LANDED_UNASKED=stale
rc=0; work_is_landed '' 2> "$FM_HARNESS_REPO/stderr2" || rc=$?
printf 'custody rc=%s unasked=%s\n' "$rc" "$TEARDOWN_LANDED_UNASKED"
SH
  out=$(FM_HARNESS_SCRIPT="$ROOT/bin/fm-teardown.sh" FM_HARNESS_REPO="$repo" bash "$repo/harness.sh") \
    || fail "head-changed: the real work_is_landed could not be run: $out"
  case "$(printf '%s\n' "$out" | sed -n 1p)" in
    'locked rc=1 unasked=HEAD changed to '*) ;;
    *) fail "head-changed: a changed HEAD was not reported as unasked: $out" ;;
  esac
  assert_equals 'custody rc=1 unasked=' "$(printf '%s\n' "$out" | sed -n 2p)" \
    'head-changed: a proved miss under project custody was reported as unasked'
  assert_grep 'changed to HEAD' "$repo/stderr" 'head-changed: the existing retry refusal was lost'
  pass 'a HEAD that changed after its landing proof is reported as unasked, and a proved miss is not'
}

# Git's protection is read from the copy, not from Git's words: a translated
# message on a protected copy is still the typed refusal, and Git's English
# protection text on a copy it had no reason to protect is only a failure.
test_nonforced_removal_is_decided_from_the_copy_not_from_gits_message() {
  local rc
  make_foreign_copy_case foreign-removal-translated
  mkdir -p "$FOREIGN_COPY/.claude"
  printf 'untracked\n' > "$FOREIGN_COPY/.claude/untracked.txt"
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "fatal: '$FOREIGN_COPY' contient des fichiers modifies ou non suivis, utilisez --force pour le supprimer" >&2; exit 128 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "translated: a protected copy must keep refusing: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=nonforced-removal ' "$FOREIGN_CASE/stderr" 'translated: a translated protection message was not counted'
  jq -es 'length == 1 and .[0].rule_id == "nonforced-removal"' "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null \
    || fail 'translated: expected exactly one nonforced-removal event'
  assert_foreign_copy_untouched translated

  make_foreign_copy_case foreign-removal-english-clean
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "fatal: '$FOREIGN_COPY' contains modified or untracked files, use --force to delete it" >&2; exit 128 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "english-clean: a failed removal must keep the exit: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "error: git worktree remove failed for foreign copy $FOREIGN_COPY (exit 128)" "$FOREIGN_CASE/stderr" 'english-clean: a clean copy was reported as protected by Git'
  assert_no_grep 'rule=nonforced-removal' "$FOREIGN_CASE/stderr" 'english-clean: Git words alone were typed as a protection refusal'
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'english-clean: Git words alone recorded a policy event'
  assert_foreign_copy_untouched english-clean

  make_foreign_copy_case foreign-removal-protected-but-failed
  mkdir -p "$FOREIGN_COPY/.claude"
  printf 'untracked\n' > "$FOREIGN_COPY/.claude/untracked.txt"
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree remove "*) echo "fatal: '$FOREIGN_COPY' contains modified or untracked files, use --force to delete it" >&2; exit 255 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "protected-but-failed: a failed removal must keep the exit: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "error: git worktree remove failed for foreign copy $FOREIGN_COPY (exit 255)" "$FOREIGN_CASE/stderr" 'protected-but-failed: a status other than Git'"'"'s fatal refusal was reported as protection'
  assert_no_grep 'rule=nonforced-removal' "$FOREIGN_CASE/stderr" 'protected-but-failed: a non-refusal status was typed as a protection refusal'
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'protected-but-failed: a non-refusal status recorded a policy event'
  assert_foreign_copy_untouched protected-but-failed
  pass 'nonforced-removal needs both a protected copy and Git'"'"'s fatal refusal status, and ignores the language or words of Git'"'"'s message'
}

# Git also refuses a worktree whose git directory keeps a modules directory, even
# when its working tree is clean (what a submodule deinit leaves). Real Git
# refuses with its fatal status and teardown counts it as the typed refusal.
test_foreign_copy_with_a_modules_directory_is_a_typed_nonforced_removal() {
  local rc gitdir
  make_foreign_copy_case foreign-modules-dir
  gitdir=$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)
  mkdir "$gitdir/modules"
  [ -z "$(git -C "$FOREIGN_COPY" status --porcelain --ignore-submodules=none)" ] || fail 'modules-dir: the fixture copy is not clean'
  run_foreign_teardown rc
  expect_code 1 "$rc" "modules-dir: a copy Git refuses to remove must keep refusing: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=nonforced-removal ' "$FOREIGN_CASE/stderr" 'modules-dir: the refusal is not typed'
  assert_no_grep 'error: git worktree remove failed' "$FOREIGN_CASE/stderr" 'modules-dir: a Git protection refusal was reported as a plain failure'
  jq -es 'length == 1 and .[0].rule_id == "nonforced-removal" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'modules-dir: expected exactly one typed human-only event'
  assert_foreign_copy_untouched modules-dir
  assert_present "$gitdir/modules" 'modules-dir: the modules directory was removed'
  pass 'a foreign copy whose git directory keeps a modules directory is refused as a typed nonforced-removal'
}

# teardown_copy_git_protects, run from the library against real Git copies:
# clean and uninitialized-submodule copies are removable, so a failure to remove
# them is not Git's protection; untracked files, an initialized submodule and the
# modules directory a submodule deinit leaves behind are.
test_git_protection_is_read_from_the_copy_state() {
  local base=$TMP_ROOT/git-protects out name rc
  mkdir -p "$base"
  (
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
    git init -q -b main "$base/lib"
    git -C "$base/lib" -c user.email=t@t -c user.name=t commit -q --allow-empty -m lib
    git init -q -b main "$base/repo"
    git -C "$base/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git -C "$base/repo" submodule -q add "$base/lib" sub
    git -C "$base/repo" -c user.email=t@t -c user.name=t commit -qm submodule
    git -C "$base/repo" worktree add -q "$base/clean" -b clean
    git -C "$base/repo" worktree add -q "$base/uninitialized" -b uninitialized
    git -C "$base/repo" worktree add -q "$base/untracked" -b untracked
    git -C "$base/repo" worktree add -q "$base/initialized" -b initialized
    git -C "$base/repo" worktree add -q "$base/deinitialized" -b deinitialized
    printf 'x\n' > "$base/untracked/new.txt"
    git -C "$base/initialized" submodule -q update --init
    git -C "$base/deinitialized" submodule -q update --init
    git -C "$base/deinitialized" submodule -q deinit -f sub
  ) > "$base/setup.out" 2>&1 || fail "git-protects: fixture setup failed: $(cat "$base/setup.out")"
  cat > "$base/harness.sh" <<'SH'
set -u
. "$FM_HARNESS_LIB"
for name in clean uninitialized untracked initialized deinitialized missing; do
  if teardown_copy_git_protects "$FM_HARNESS_BASE/$name"; then echo "$name=protected"; else echo "$name=removable"; fi
done
SH
  out=$(FM_HARNESS_LIB="$ROOT/bin/fm-teardown-nested-lib.sh" FM_HARNESS_BASE=$base bash "$base/harness.sh" 2>&1) \
    || fail "git-protects: the library could not be run: $out"
  assert_equals 'clean=removable
uninitialized=removable
untracked=protected
initialized=protected
deinitialized=protected
missing=removable' "$out" 'git-protects: protection was not read from the copy state'
  git -C "$base/repo" worktree remove "$base/uninitialized" || fail 'git-protects: Git refused an uninitialized-submodule copy the check called removable'
  git -C "$base/repo" worktree remove "$base/clean" || fail 'git-protects: Git refused a clean copy the check called removable'
  for name in untracked initialized deinitialized; do
    rc=0
    git -C "$base/repo" worktree remove "$base/$name" > /dev/null 2>&1 || rc=$?
    assert_equals 128 "$rc" "git-protects: Git did not refuse the $name copy the check called protected with its fatal status"
  done
  pass "Git's protection is read from the copy: untracked files, an initialized submodule and a deinitialized submodule's modules directory protect it, a clean or uninitialized copy does not, and Git refuses exactly those with status 128"
}

# One rule asks one question wherever it is refused. The proof refuses a lock
# that is not Vernant's; a lock that turns into one while an earlier copy is
# being released is refused again at release. Both print the same question.
test_creation_lock_owner_asks_the_same_question_at_proof_and_release_time() {
  local rc second proof_question release_question
  dead_launcher_pid
  make_foreign_copy_case foreign-lock-question-proof "$FOREIGN_DEAD_PID"
  git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
  git -C "$FOREIGN_CASE/project" worktree lock --reason 'held by a human' "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "lock-question: a lock that is not Vernant's must be refused at proof time: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: it is locked by something other than Vernant's creation lock" "$FOREIGN_CASE/stderr" \
    'lock-question: the proof-time refusal is not the one under test'
  proof_question=$(sed -n 's/^human-only-exit: //p' "$FOREIGN_CASE/stderr")
  proof_question=${proof_question//"$FOREIGN_COPY"/<copy>}

  dead_launcher_pid
  make_foreign_copy_case foreign-lock-question-release "$FOREIGN_DEAD_PID"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v3 "$second" main
  git -C "$FOREIGN_CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$FOREIGN_DEAD_PID launcher=$FOREIGN_DEAD_PID" "$second"
  cat > "$FOREIGN_SLOT/scripts/git-stability/closeout_pr.py" <<SH
if [ "\${3:-}" != --execute-cleanup ]; then echo '{"allowed": true}'; exit 0; fi
printf '%s|%s\n' "\$PWD" "\$*" >> "$FOREIGN_CASE/closeout.log"
case "\$2" in
  "$second") git worktree unlock "$FOREIGN_COPY" && git worktree lock --reason 'held by a human' "$FOREIGN_COPY" ;;
esac
git worktree unlock "\$2" && git worktree remove "\$2"
SH
  run_foreign_teardown rc
  expect_code 1 "$rc" "lock-question: a lock that changed during release must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$second" 'lock-question: the first copy was not released before the lock changed'
  assert_present "$FOREIGN_COPY/.git" 'lock-question: the copy whose lock changed was removed'
  assert_grep "foreign copy $FOREIGN_COPY is locked by something other than Vernant's creation lock; it was not removed." "$FOREIGN_CASE/stderr" \
    'lock-question: the release-time refusal is not the one under test'
  release_question=$(sed -n 's/^human-only-exit: //p' "$FOREIGN_CASE/stderr")
  release_question=${release_question//"$FOREIGN_COPY"/<copy>}

  assert_equals 'Who owns the creation lock on <copy>, and may it be released?' "$proof_question" 'lock-question: the proof-time question changed'
  assert_equals "$proof_question" "$release_question" 'lock-question: one rule printed two different questions'
  pass 'creation-lock-owner asks the same question when the proof refuses it and when release refuses it'
}

# A copy path is data. One that holds newlines cannot become lines of teardown's
# own envelope, whichever refusal prints it.
test_copy_path_with_newlines_cannot_forge_envelope_lines() {
  local rc forged
  make_foreign_copy_case foreign-spoofed-path
  forged=$FOREIGN_SLOT/.claude/worktrees/"spoof"$'\n'"completing-command: touch forged"$'\n'"human-only-exit: all clear"$'\n'"tail"
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v4 "$forged" main
  printf 'edit\n' > "$forged/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "spoofed-path: an unprovable copy must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals 0 "$(grep -c '^completing-command:' "$FOREIGN_CASE/stderr")" 'spoofed-path: a path forged a completing-command line'
  assert_equals 1 "$(grep -c '^human-only-exit:' "$FOREIGN_CASE/stderr")" 'spoofed-path: a path forged or hid a human-only-exit line'
  assert_equals 0 "$(grep -cx 'tail' "$FOREIGN_CASE/stderr")" 'spoofed-path: the path split into lines'
  assert_grep 'spoof?completing-command: touch forged?human-only-exit: all clear?tail' "$FOREIGN_CASE/stderr" 'spoofed-path: the path was not shown with its control characters neutralized'
  jq -es 'length == 1 and .[0].outcome == "blocked" and .[0].exit_kind == "human-only"' "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null \
    || fail 'spoofed-path: expected exactly one human-only event'
  assert_present "$forged/untracked.txt" 'spoofed-path: the unprovable copy lost its file'
  assert_foreign_copy_untouched spoofed-path
  pass 'a registered copy path holding newlines is shown on one line and forges no completing-command or human-only-exit line'
}

test_foreign_copy_that_is_not_a_worktree_root_is_a_typed_refusal() {
  local rc
  make_foreign_copy_case foreign-typed-not-root
  rm -f "$FOREIGN_COPY/.git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "not-root: a registered remnant without its .git must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_typed_copy_refusal not-root copy-worktree-root
  pass 'a foreign copy that is not a Git worktree root is refused with its rule and a human-only question, once'
}

test_foreign_copy_with_an_unresolvable_head_is_a_typed_refusal() {
  local rc
  make_foreign_copy_case foreign-typed-unborn-head
  git -C "$FOREIGN_COPY" symbolic-ref HEAD refs/heads/fm/unborn-typed
  git -C "$FOREIGN_COPY" read-tree --empty
  find "$FOREIGN_COPY" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  run_foreign_teardown rc
  expect_code 1 "$rc" "unborn-head: a copy whose HEAD cannot be resolved must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_typed_copy_refusal unborn-head copy-head-resolved
  pass 'a foreign copy whose HEAD cannot be resolved is refused with its rule and a human-only question, once'
}

test_foreign_copy_whose_anchor_names_another_commit_is_a_typed_refusal() {
  local rc short other
  make_foreign_copy_case foreign-typed-anchor-commit
  short=$(git -C "$FOREIGN_COPY" rev-parse --short HEAD)
  other=$(git -C "$FOREIGN_CASE/project" commit-tree -m 'another commit' "$(git -C "$FOREIGN_CASE/project" rev-parse 'HEAD^{tree}')")
  git -C "$FOREIGN_CASE/project" update-ref "refs/fm/anchor/task-x1-$short" "$other"
  run_foreign_teardown rc
  expect_code 1 "$rc" "anchor-commit: an anchor naming another commit must refuse the copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_typed_copy_refusal anchor-commit copy-anchor-commit
  assert_equals "$other" "$(git -C "$FOREIGN_CASE/project" rev-parse "refs/fm/anchor/task-x1-$short")" 'anchor-commit: the existing anchor was overwritten'
  pass 'a foreign copy whose preservation anchor names another commit is refused with its rule and a human-only question, once'
}

test_teardown_usage_and_inspection_errors_are_not_policy_events() {
  local rc
  make_foreign_copy_case typed-non-policy
  rc=0
  FM_HOME="$FOREIGN_CASE/home" "$TEARDOWN" > "$FOREIGN_CASE/usage.out" 2> "$FOREIGN_CASE/usage.err" || rc=$?
  expect_code 2 "$rc" 'usage exit changed'
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'usage error recorded a policy event'
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree list "*) exit 128 ;; esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" 'Git inspection failure changed exit'
  assert_foreign_copy_untouched typed-non-policy
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'inspection failure recorded a policy event'
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case "\$1:\${2:-}:\${3:-}" in "-C:$FOREIGN_COPY:status") exit 128 ;; esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  run_foreign_teardown rc
  expect_code 1 "$rc" 'nested-copy status inspection failure changed exit'
  assert_foreign_copy_untouched typed-non-policy
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" 'nested-copy status error recorded a policy event'
  pass 'teardown usage and transient Git inspection errors retain exits without policy events'
}

# An own nested copy Vernant's creation lock holds is released through the
# closeout driver; when its interpreter cannot run, that is known at entry, so
# the teardown refuses before any protected step (the return-pending record,
# the endpoint close, the inbox, status or tasktmp removal), for the plain and
# the prior record shapes. With the interpreter there, the same case closes.
test_own_locked_copy_with_no_closeout_interpreter_refuses_at_entry() {
  local shape rc label
  for shape in plain enclosing; do
    label="own-closeout-$shape"
    dead_launcher_pid
    make_own_locked_copy_case "$label" "$shape" "$FOREIGN_DEAD_PID"
    nested_seed_task_files "$FOREIGN_CASE"
    nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
    run_foreign_teardown rc FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/no-such-python"
    assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "is not available, so it cannot be released"
    assert_absent "$FOREIGN_CASE/closeout.log" "$label: the driver ran"
    run_foreign_teardown rc
    expect_code 0 "$rc" "$label: with the interpreter there the same copy must be released: $(cat "$FOREIGN_CASE/stderr")"
    assert_absent "$FOREIGN_COPY" "$label: the copy survived the release"
    assert_absent "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record survived the release"
  done
  pass "an own Vernant-locked copy whose closeout interpreter cannot run refuses at entry for both record shapes, and closes once it can"
}

# Vernant's closeout driver is asked in plan mode at entry for every locked copy
# the release will hand it: a plan that declines, or answers with no verdict,
# refuses before any protected step, for an own copy of either record shape and
# for a foreign copy; the release itself never runs. An allowing plan lets the
# same case close, and the release asks the driver again.
test_closeout_plan_refusal_refuses_at_entry() {
  local form shape rc label
  for form in refuse garbled; do
    for shape in plain enclosing; do
      label="own-plan-$form-$shape"
      dead_launcher_pid
      make_own_locked_copy_case "$label" "$shape" "$FOREIGN_DEAD_PID"
      nested_seed_task_files "$FOREIGN_CASE"
      nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
      run_foreign_teardown rc FM_STUB_PLAN="$form"
      assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "Vernant's closeout driver would not release it"
      assert_present "$FOREIGN_CASE/closeout-plan.log" "$label: the driver was not asked in plan mode"
      assert_absent "$FOREIGN_CASE/closeout.log" "$label: the release ran after a plan refusal"
    done
  done
  label='foreign-plan-refuse'
  dead_launcher_pid
  make_foreign_copy_case "$label" "$FOREIGN_DEAD_PID"
  run_foreign_teardown rc FM_STUB_PLAN=refuse
  expect_code 1 "$rc" "$label: a declining plan must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "Vernant's closeout driver would not release it" "$FOREIGN_CASE/stderr" "$label: the refusal did not name the plan"
  assert_foreign_copy_untouched "$label"
  assert_absent "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "$label: a return-pending record was written before the refusal"
  label='own-plan-allows'
  dead_launcher_pid
  make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
  run_foreign_teardown rc
  expect_code 0 "$rc" "$label: an allowing plan must let the copy go: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/closeout-plan.log" "$label: the driver was not asked in plan mode"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "$label: the release did not run once after the plan"
  pass "a closeout plan that declines or gives no verdict refuses at entry for own and foreign copies, and an allowing plan lets the release run"
}

# On Linux the removability check reads each entry's and directory's immutable
# and append-only attributes; an entry it cannot open is doubt and refuses,
# while a readable regular file, a symbolic link (judged by its directory) and an
# absent path pass. macOS asks faccessat instead, and root reads everything.
test_linux_removability_refuses_an_entry_it_cannot_open() {
  local dir rc item
  if [ "$(uname -s)" != Linux ] || [ "$(id -u)" = 0 ]; then
    pass "the Linux removability check refuses an unopenable entry (skipped: needs Linux and a non-root user)"
    return 0
  fi
  dir=$(mktemp -d "$TMP_ROOT/linux-removable.XXXXXX")
  printf 'x\n' > "$dir/unreadable"
  chmod 000 "$dir/unreadable"
  printf 'x\n' > "$dir/readable"
  ln -s "$dir/readable" "$dir/link"
  for item in unreadable:1 readable:0 link:0 absent:0; do
    rc=0
    bash -c '. "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_path_deletable "$2"' _ "$ROOT" "$dir/${item%%:*}" || rc=$?
    case "${item#*:}" in
      1) [ "$rc" != 0 ] || fail "linux-removable: an entry whose attributes cannot be read passed (${item%%:*})" ;;
      *) expect_code 0 "$rc" "linux-removable: a removable entry was refused (${item%%:*})" ;;
    esac
  done
  chmod 600 "$dir/unreadable"
  pass "the Linux removability check refuses an entry it cannot open and passes readable files, links and absent paths"
}

# The archive of a copy's ignored files is never removed or overwritten: a
# failed copy keeps the earlier one, an identical one is kept as is, a
# different one is kept beside a new archive, and a preserve parent that cannot
# be written refuses at entry with nothing changed.
test_earlier_preserved_copy_survives_until_its_replacement_is_verified() {
  local shape rc exclude hash dest real_cp root label new
  real_cp=$(command -v cp)
  for shape in failed-copy kept-beside same-content read-only-parent; do
    label="own-backup-$shape"
    dead_launcher_pid
    make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\n' >> "$exclude"
    printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
    hash=$(printf '%s' "$(cd "$FOREIGN_COPY" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
    dest="$root/$hash"
    mkdir -p "$dest/files" "$dest/meta"
    if [ "$shape" = same-content ]; then
      printf 'only here\n' > "$dest/files/unique.dat"
      printf '%s\n' "$(cd "$FOREIGN_COPY" && pwd -P)" > "$dest/meta/copy-path"
      printf '%s  unique.dat\n' "$(shasum -a 256 "$dest/files/unique.dat" | awk '{print $1}')" > "$dest/meta/SHA256SUMS"
    else
      printf 'earlier backup\n' > "$dest/files/unique.dat"
      printf 'earlier manifest\n' > "$dest/meta/SHA256SUMS"
    fi
    case "$shape" in
      failed-copy)
        cat > "$FOREIGN_CASE/fakebin/cp" <<SH
#!/usr/bin/env bash
case " \$* " in
  *nested-copy-preserved*|*/.teardown-run.*/ignored-*) : > "$FOREIGN_CASE/cp-failure-injected"; echo "cp: simulated copy failure" >&2; exit 1 ;;
esac
exec "$real_cp" "\$@"
SH
        chmod +x "$FOREIGN_CASE/fakebin/cp"
        ;;
      read-only-parent)
        nested_seed_task_files "$FOREIGN_CASE"
        chmod 555 "$root"
        nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
        ;;
    esac
    run_foreign_teardown rc
    case "$shape" in
      failed-copy)
        expect_code 1 "$rc" "$label: a failed preserve must refuse: $(cat "$FOREIGN_CASE/stderr")"
        assert_present "$FOREIGN_CASE/cp-failure-injected" "$label: the refusal came before the injected copy failure"
        assert_present "$FOREIGN_COPY/unique.dat" "$label: the own copy's ignored file was lost"
        assert_equals "earlier backup" "$(cat "$dest/files/unique.dat")" "$label: the earlier preserved copy was destroyed by a failed replacement"
        assert_equals "earlier manifest" "$(cat "$dest/meta/SHA256SUMS")" "$label: the earlier manifest was destroyed by a failed replacement"
        ;;
      kept-beside)
        expect_code 0 "$rc" "$label: a verified preserve must release the copy: $(cat "$FOREIGN_CASE/stderr")"
        assert_equals "earlier backup" "$(cat "$dest/files/unique.dat")" "$label: the earlier preserved copy was replaced"
        assert_equals "earlier manifest" "$(cat "$dest/meta/SHA256SUMS")" "$label: the earlier manifest was replaced"
        new=$(find "$root" -mindepth 1 -maxdepth 1 -name "$hash.*" -type d)
        [ "$(printf '%s\n' "$new" | grep -c .)" = 1 ] || fail "$label: no single new preserve was kept beside the earlier one: $new"
        assert_equals "only here" "$(cat "$new/files/unique.dat")" "$label: the new preserve does not hold the copy's bytes"
        assert_grep "$(shasum -a 256 "$new/files/unique.dat" | awk '{print $1}')  unique.dat" "$new/meta/SHA256SUMS" \
          "$label: the new manifest does not describe the preserved bytes"
        ;;
      same-content)
        expect_code 0 "$rc" "$label: an identical earlier preserve must let the copy go: $(cat "$FOREIGN_CASE/stderr")"
        assert_equals "only here" "$(cat "$dest/files/unique.dat")" "$label: the identical preserve changed"
        [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -name "$hash.*")" ] || fail "$label: a duplicate preserve was written beside an identical one"
        assert_absent "$FOREIGN_COPY" "$label: the copy survived"
        ;;
      read-only-parent)
        chmod 755 "$root"
        if [ "$(id -u)" = 0 ]; then
          expect_code 0 "$rc" "$label: root writes any parent, so the copy is released: $(cat "$FOREIGN_CASE/stderr")"
        else
          assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "cannot be written through"
          assert_equals "earlier backup" "$(cat "$dest/files/unique.dat")" "$label: the earlier preserved copy was lost"
          assert_absent "$FOREIGN_CASE/closeout.log" "$label: the driver ran"
        fi
        ;;
    esac
  done
  pass "an earlier preserve of a locked own copy is never removed: a failed copy, an identical one, a different one and an unwritable parent all keep it"
}

# The preserve parent must be a real directory whose physical location is
# outside the copies this teardown removes: a parent that is a link, or a data
# folder that resolves into the copy, refuses at entry with nothing changed. A
# user file named like the metadata never meets it: the bytes sit under files/
# and the manifest under meta/.
test_preserve_parent_and_metadata_boundaries() {
  local shape rc exclude label root preserved name
  for shape in parent-link data-in-copy metadata-names; do
    label="preserve-boundary-$shape"
    dead_launcher_pid
    make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\nSHA256SUMS\ncopy-path\nkept/\n' >> "$exclude"
    printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
    root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
    case "$shape" in
      parent-link)
        mkdir -p "$FOREIGN_COPY/kept" "$FOREIGN_CASE/data/task-x1"
        ln -s "$FOREIGN_COPY/kept" "$root"
        ;;
      data-in-copy)
        mkdir -p "$FOREIGN_COPY/kept"
        rm -rf "$FOREIGN_CASE/data/task-x1"
        ln -s "$FOREIGN_COPY/kept" "$FOREIGN_CASE/data/task-x1"
        ;;
      metadata-names)
        printf 'user manifest\n' > "$FOREIGN_COPY/SHA256SUMS"
        printf 'user path\n' > "$FOREIGN_COPY/copy-path"
        ;;
    esac
    nested_seed_task_files "$FOREIGN_CASE"
    nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
    run_foreign_teardown rc
    case "$shape" in
      parent-link)
        assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "is not a real directory"
        ;;
      data-in-copy)
        assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "which this teardown removes"
        ;;
      metadata-names)
        expect_code 0 "$rc" "$label: the copy must be released: $(cat "$FOREIGN_CASE/stderr")"
        preserved=$(find "$root" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        assert_equals 'user manifest' "$(cat "$preserved/files/SHA256SUMS")" "$label: a user file named SHA256SUMS was not kept as is"
        assert_equals 'user path' "$(cat "$preserved/files/copy-path")" "$label: a user file named copy-path was not kept as is"
        assert_equals 'only here' "$(cat "$preserved/files/unique.dat")" "$label: the other ignored file was not kept"
        for name in SHA256SUMS copy-path unique.dat; do
          assert_grep "$(shasum -a 256 "$preserved/files/$name" | awk '{print $1}')  $name" "$preserved/meta/SHA256SUMS" \
            "$label: the manifest does not hash the user file $name"
        done
        ;;
    esac
  done
  pass "a preserve parent that is a link or resolves into the copy refuses at entry, and user files named like the metadata are kept apart from it"
}

# The same-device check reads the parent each rename really targets: a preserve
# parent on another filesystem refuses at entry when the release will preserve
# into it, though the task's data folder itself shares the run directory's.
test_preserve_parent_on_another_filesystem_refuses_at_entry() {
  local rc exclude label=preserve-parent-xdev root
  dead_launcher_pid
  make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
  root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
  mkdir -p "$root"
  teardown_test_fake_other_device "$FOREIGN_CASE/fakebin" "$root"
  nested_seed_task_files "$FOREIGN_CASE"
  nested_snapshot "$FOREIGN_CASE" "$FOREIGN_CASE/snapshot.before"
  run_foreign_teardown rc
  assert_nested_refused_untouched "$FOREIGN_CASE" "$rc" "$label" "$root are not on one filesystem"
  assert_absent "$FOREIGN_CASE/closeout.log" "$label: the driver ran"
  pass "a preserve parent on another filesystem refuses at entry when a release will preserve into it"
}

test_a_held_copy_keeps_its_unique_ignored_files_and_none_are_preserved() {
  local rc
  make_held_case held-ignored
  held_foreign_unlanded "$FOREIGN_COPY"
  held_ignored_file "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-ignored: a landed task must close beside a copy with unpushed commits and ignored files: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-ignored
  held_assert_untouched held-ignored "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_present "$FOREIGN_COPY/unique.dat" "held-ignored: the held copy's ignored file is gone"
  assert_equals "only here" "$(cat "$FOREIGN_COPY/unique.dat")" "held-ignored: the held copy's ignored file changed"
  assert_absent "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" "held-ignored: a held copy's ignored files were copied as if the copy were removed"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "held-ignored: a close that succeeded printed a refusal"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-ignored: the record is not one line"
  pass "a held copy keeps its unique ignored files in place: nothing of it is copied, moved or removed, and the record has one line"
}

test_task_closes_beside_a_foreign_copy_with_unpushed_commits() {
  local rc
  make_held_case held-unlanded
  held_foreign_unlanded "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-unlanded: a landed task must close beside a foreign copy that holds unpushed commits: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-unlanded
  held_assert_untouched held-unlanded "$FOREIGN_CASE" "$FOREIGN_COPY"
  git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
    || fail "held-unlanded: the foreign copy's branch was deleted"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "held-unlanded: a close that succeeded printed a refusal"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its HEAD " "$FOREIGN_CASE/stdout" \
    "held-unlanded: the output did not list the held copy and its reason"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-unlanded: the record is not one line"
  pass "a task whose own copy landed closes beside a foreign copy with commits on no remote, which stays byte-identical, with the slot still reserved"
}

test_held_copy_record_has_one_exact_line_per_copy() {
  local rc second line record fields copy
  make_held_case held-two
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_foreign_unlanded "$FOREIGN_COPY"
  held_foreign_unlanded "$second"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-two: a landed task must close beside two held copies: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-two
  held_assert_untouched held-two "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  record=$FOREIGN_CASE/data/held-foreign-copies.log
  assert_equals 2 "$(wc -l < "$record" | tr -d ' ')" "held-two: two foreign copies must give two lines"
  while IFS= read -r line; do
    fields=$(printf '%s\n' "$line" | awk -F'\t' '{ print NF }')
    assert_equals 5 "$fields" "held-two: a record line is not five tab-separated fields: $line"
    printf '%s\n' "$line" | awk -F'\t' '$1 !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ { exit 1 }' \
      || fail "held-two: the first field is not a UTC time: $line"
    printf '%s\n' "$line" | awk -F'\t' -v s="$FOREIGN_SLOT" '$2 == "task-x1" && $3 == s { ok = 1 } END { exit !ok }' \
      || fail "held-two: the closing task or slot is wrong: $line"
  done < "$record"
  for copy in "$FOREIGN_COPY" "$second"; do
    awk -F'\t' -v c="$copy" '$4 == c && $5 ~ /^its HEAD [0-9a-f]{12} is not proved landed$/ { ok = 1 } END { exit !ok }' "$record" \
      || fail "held-two: the line of $copy is missing or its reason is not exact: $(cat "$record")"
  done
  pass "each held foreign copy gets one record line with UTC time, closing task, slot, copy and its exact reason"
}

test_a_held_close_removes_only_the_tasks_own_nested_copy() {
  local rc shape locked second pid=
  for shape in enclosing reverse; do
    for locked in plain locked; do
      pid=
      if [ "$locked" = locked ]; then
        dead_launcher_pid
        pid=$FOREIGN_DEAD_PID
      fi
      make_own_locked_copy_case "held-own-nested-$shape-$locked" "$shape" "$pid"
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      second=$FOREIGN_SLOT/.claude/worktrees/fc-two
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
      held_foreign_unlanded "$second"
      held_snapshot "$FOREIGN_CASE" "$second"
      run_foreign_teardown rc
      expect_code 0 "$rc" "held-own-nested-$shape-$locked: a landed task must close beside a held foreign copy: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "held-own-nested-$shape-$locked"
      assert_absent "$FOREIGN_COPY" "held-own-nested-$shape-$locked: the task's own nested copy survived"
      git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
        || fail "held-own-nested-$shape-$locked: the own copy's branch was deleted"
      assert_absent "$FOREIGN_CASE/treehouse.log" "held-own-nested-$shape-$locked: the pool slot was returned"
      cmp -s "$FOREIGN_CASE/treehouse-state.before" "$FOREIGN_CASE/pool/treehouse-state.json" \
        || fail "held-own-nested-$shape-$locked: Treehouse's lease changed"
      cmp -s "$FOREIGN_CASE/slot-owner.before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" \
        || fail "held-own-nested-$shape-$locked: the slot claim changed"
      held_fingerprint "$second" | cmp -s - "$FOREIGN_CASE/held-before.fc-two" \
        || fail "held-own-nested-$shape-$locked: the foreign copy changed"
      assert_present "$second/unlanded.txt" "held-own-nested-$shape-$locked: the foreign copy's unique file is gone"
      if [ "$locked" = locked ]; then
        assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
          "held-own-nested-$shape-$locked: the driver was not run once, for the own copy only"
      else
        assert_absent "$FOREIGN_CASE/closeout.log" "held-own-nested-$shape-$locked: the closeout driver ran for an unlocked copy"
      fi
    done
  done
  pass "a held close removes the task's own nested copy, through the driver when it is locked, and leaves the slot, its lease and claim and the held foreign copy alone"
}

# A held close removes the task's own nested copy with whatever it holds. A
# separate Git repository, or a linked worktree of another project, under that
# copy would lose its commits with no ref left behind, and the registered-copy
# list never sees it. The repository sits under .claude, where the own-copy
# clean proof does not look, as the independent reader's probe placed it.
test_a_held_close_refuses_when_an_own_nested_copy_holds_another_repository() {
  local rc shape locked pid second nested other commits
  for shape in separate-repository other-project-worktree; do
    for locked in plain locked; do
      pid=
      if [ "$locked" = locked ]; then
        dead_launcher_pid
        pid=$FOREIGN_DEAD_PID
      fi
      make_own_locked_copy_case "held-other-repo-$shape-$locked" enclosing "$pid"
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      second=$FOREIGN_SLOT/.claude/worktrees/fc-two
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
      held_foreign_unlanded "$second"
      nested=$FOREIGN_COPY/.claude/cross-project
      mkdir -p "$FOREIGN_COPY/.claude"
      if [ "$shape" = separate-repository ]; then
        git init -q "$nested"
      else
        other=$FOREIGN_CASE/other-project
        git init -q "$other"
        printf 'base\n' > "$other/base.txt"
        git -C "$other" add base.txt
        git -C "$other" -c user.email=t@t -c user.name=t commit -qm 'other project base'
        git -C "$other" worktree add -q -b other-lane "$nested"
      fi
      printf 'one\n' > "$nested/unique.txt"
      git -C "$nested" add unique.txt
      git -C "$nested" -c user.email=t@t -c user.name=t commit -qm 'first unlanded commit'
      printf 'two\n' >> "$nested/unique.txt"
      git -C "$nested" -c user.email=t@t -c user.name=t commit -qam 'second unlanded commit'
      commits=$(git -C "$nested" rev-parse HEAD)
      held_snapshot "$FOREIGN_CASE" "$second"
      run_foreign_teardown rc
      expect_code 1 "$rc" "held-other-repo-$shape-$locked: a held close must not remove an own copy that holds another repository: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "Git repository $nested inside task task-x1's nested copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" \
        "held-other-repo-$shape-$locked: the refusal did not name the repository: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-other-repo-$shape-$locked: the refusal did not say nothing was removed"
      assert_present "$FOREIGN_COPY" "held-other-repo-$shape-$locked: the own nested copy was removed"
      assert_present "$nested/unique.txt" "held-other-repo-$shape-$locked: the other repository's file is gone"
      assert_equals "$commits" "$(git -C "$nested" rev-parse HEAD)" "held-other-repo-$shape-$locked: the other repository's commits changed"
      if [ "$shape" = other-project-worktree ]; then
        git -C "$other" worktree list --porcelain | grep -F "worktree $nested" >/dev/null \
          || fail "held-other-repo-$shape-$locked: the other project's worktree registration was lost"
      fi
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-other-repo-$shape-$locked: the task record was removed"
      [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-other-repo-$shape-$locked: the backlog item was closed by a refused close"
      assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-other-repo-$shape-$locked: a refused close wrote a held-copy record"
      git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
        || fail "held-other-repo-$shape-$locked: the own copy's branch was deleted"
      held_assert_untouched "held-other-repo-$shape-$locked" "$FOREIGN_CASE" "$second"
    done
  done
  pass "a held close refuses, with nothing removed, when an own nested copy holds a separate repository or another project's worktree"
}

# A submodule of the task's own repository is not another repository: its git
# directory lives in the own repository's, so the held close still goes ahead.
test_a_held_close_is_not_stopped_by_a_submodule_of_the_own_repository() {
  local rc second sub
  make_own_locked_copy_case held-submodule enclosing
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  seed_backlog_in_flight "$FOREIGN_CASE"
  sub=$FOREIGN_CASE/sub-source
  git init -q "$sub"
  printf 'sub\n' > "$sub/file.txt"
  git -C "$sub" add file.txt
  git -C "$sub" -c user.email=t@t -c user.name=t commit -qm 'sub'
  git -C "$FOREIGN_COPY" -c protocol.file.allow=always submodule add -q "$sub" vendor/sub
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'add submodule'
  git -C "$FOREIGN_CASE/project" update-ref refs/heads/main "$(git -C "$FOREIGN_COPY" rev-parse HEAD)"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_COPY" rev-parse HEAD)"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_foreign_unlanded "$second"
  held_snapshot "$FOREIGN_CASE" "$second"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-submodule: a submodule of the own repository must not stop a held close: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-submodule
  assert_absent "$FOREIGN_COPY" "held-submodule: the own nested copy survived"
  pass "a submodule of the task's own repository does not stop a held close"
}

test_a_foreign_copy_inside_the_own_nested_copy_is_never_left_to_the_removal() {
  local rc own shape locked pid inner second target label
  local -a watch
  for own in enclosing reverse; do
    for shape in held-inside provable-inside; do
      for locked in plain locked; do
        label="held-inside-$own-$shape-$locked"
        pid=
        if [ "$locked" = locked ]; then
          dead_launcher_pid
          pid=$FOREIGN_DEAD_PID
        fi
        make_own_locked_copy_case "$label" "$own" "$pid"
        printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
        add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
        seed_backlog_in_flight "$FOREIGN_CASE"
        inner=$FOREIGN_COPY/.claude/worktrees/fc-inner
        second=$FOREIGN_SLOT/.claude/worktrees/fc-two
        git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$inner" main
        if [ "$shape" = held-inside ]; then
          held_foreign_unlanded "$inner"
          target=$inner
          watch=("$inner")
        else
          git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
          held_foreign_unlanded "$second"
          target=$second
          watch=("$inner" "$second")
        fi
        held_snapshot "$FOREIGN_CASE" "${watch[@]}"
        run_foreign_teardown rc
        expect_code 1 "$rc" "$label: removing the own copy would take a foreign copy with it, so the close must refuse: $(cat "$FOREIGN_CASE/stderr")"
        assert_grep "contains registered copy $target" "$FOREIGN_CASE/stderr" "$label: the refusal did not name the copy that stays"
        assert_present "$FOREIGN_COPY" "$label: the own nested copy was removed"
        assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
        assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "$label: a refused close wrote a held-copy record"
        git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
          || fail "$label: the own copy's branch was deleted"
        assert_present "$inner/.git" "$label: the foreign copy inside the own copy is gone"
        assert_present "$target/unlanded.txt" "$label: the foreign copy's unique file is gone"
        held_assert_untouched "$label" "$FOREIGN_CASE" "${watch[@]}"
      done
    done
  done
  pass "a foreign copy inside the own nested copy is never held or swept away: the close refuses and every copy, the slot, its lease and claim stay as they were"
}

test_an_ordinary_close_never_turns_into_a_held_close_during_the_project_lock_wait() {
  local rc lock holder actor late i actor_rc
  make_own_locked_copy_case route-flip-wait enclosing
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
  seed_backlog_in_flight "$FOREIGN_CASE"
  lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project") \
    || fail "route-flip-wait: cannot resolve the shared Treehouse project lock"
  late=$FOREIGN_SLOT/.claude/worktrees/fc-late
  cat > "$FOREIGN_CASE/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  kill-window)
    : > "$FOREIGN_CASE/closing"
    i=0
    while [ ! -f "$FOREIGN_CASE/project-held" ]; do
      i=\$((i + 1)); [ "\$i" -lt 2000 ] || exit 1
      sleep 0.05
    done
    ;;
esac
exit 0
SH
  chmod +x "$FOREIGN_CASE/fakebin/tmux"
  (
    run_foreign_teardown actor_rc FM_PROJECT_LOCK_POLL_SECS=0.05
    printf '%s' "$actor_rc" > "$FOREIGN_CASE/actor.rc"
  ) &
  actor=$!
  i=0
  while [ ! -f "$FOREIGN_CASE/closing" ]; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || { kill "$actor" 2>/dev/null || true; fail "route-flip-wait: teardown did not reach the endpoint close: $(cat "$FOREIGN_CASE/stderr")"; }
    sleep 0.05
  done
  hold_project_lock_until_release "$FOREIGN_CASE" "$lock" &
  holder=$!
  i=0
  while [ "$(queued_tickets "$lock")" = 0 ]; do
    if ! kill -0 "$actor" 2>/dev/null; then
      : > "$FOREIGN_CASE/release"; wait "$holder" || true
      fail "route-flip-wait: teardown exited instead of waiting for the project lock: $(cat "$FOREIGN_CASE/stderr")"
    fi
    i=$((i + 1)); [ "$i" -lt 1000 ] || {
      : > "$FOREIGN_CASE/release"; wait "$holder" || true; wait "$actor" || true
      fail "route-flip-wait: teardown never queued for the project lock: $(cat "$FOREIGN_CASE/stderr")"
    }
    sleep 0.05
  done
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/late-lane "$late" main
  held_ignored_file "$late"
  held_snapshot "$FOREIGN_CASE" "$late"
  : > "$FOREIGN_CASE/release"
  wait "$holder" || fail "route-flip-wait: the project lock holder could not release"
  wait "$actor" || true
  rc=$(cat "$FOREIGN_CASE/actor.rc")
  expect_code 1 "$rc" "route-flip-wait: a foreign copy that appeared during the wait must stop the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "a foreign copy in pool slot $FOREIGN_SLOT changed since the slot was proved, so the slot is not returned" "$FOREIGN_CASE/stderr" \
    "route-flip-wait: the refusal did not say the route changed"
  assert_present "$FOREIGN_COPY" "route-flip-wait: the own nested copy was removed before the refusal"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "route-flip-wait: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "route-flip-wait: a refused close wrote a held-copy record"
  git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
    || fail "route-flip-wait: the own copy's branch was deleted"
  held_assert_untouched route-flip-wait "$FOREIGN_CASE" "$late"
  assert_present "$late/unique.dat" "route-flip-wait: the late foreign copy's unique file is gone"
  pass "an ordinary close whose slot gains a copy holding unique ignored files during the project-lock wait refuses with nothing removed"
}

# A foreign copy that appears in the slot while its stale lock blocks the return
# (here on the first failed return, since a retry waits while the lock is there)
# must stop the return at the reproof after the stale-lock cleanup: the route
# changed, so neither an ordinary return nor a held close may follow.
test_a_stale_lock_cleanup_never_turns_an_ordinary_close_into_a_held_close() {
  local case_dir rc lock late
  make_nested_slot_case route-flip-stale-lock enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  late=$NESTED_SLOT/.claude/worktrees/fc-late
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
lock=\$(git -C "\$wt" rev-parse --path-format=absolute --git-path index.lock 2>/dev/null || true)
if [ -n "\$lock" ] && [ -e "\$lock" ]; then
  calls=\$(( \$(cat "$case_dir/return-calls" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "\$calls" > "$case_dir/return-calls"
  if [ "\$calls" = 1 ]; then
    git -C "$case_dir/project" worktree add -q -b fm/late-lane "$late" main
    exclude=\$(git -C "$late" rev-parse --path-format=absolute --git-path info/exclude)
    printf 'unique.dat\n' >> "\$exclude"
    printf 'only here\n' > "$late/unique.dat"
  fi
  echo "fatal: Unable to create '\$lock': File exists." >&2
  exit 128
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  add_lsof_no_holder "$case_dir"
  lock=$(git_index_lock_path "$NESTED_SLOT")
  : > "$lock"
  touch -t 200001010000 "$lock"
  rc=0
  FM_HOME="$case_dir/home" FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "route-flip-stale-lock: a foreign copy that appeared during the return must stop it: $(cat "$case_dir/stderr")"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" "route-flip-stale-lock: the stale lock was not cleaned up, so the probe proves nothing"
  assert_grep "a foreign copy in pool slot $NESTED_SLOT changed since the slot was proved, so the slot is not returned" "$case_dir/stderr" \
    "route-flip-stale-lock: the refusal did not say the route changed"
  assert_absent "$case_dir/treehouse.log" "route-flip-stale-lock: the slot was returned"
  assert_present "$late/unique.dat" "route-flip-stale-lock: the late foreign copy's unique file is gone"
  assert_present "$case_dir/state/task-x1.meta" "route-flip-stale-lock: the task record was removed"
  assert_absent "$case_dir/data/held-foreign-copies.log" "route-flip-stale-lock: a refused close wrote a held-copy record"
  pass "a stale-lock cleanup refuses when the slot gained a copy holding unique ignored files, instead of turning the close into a held close"
}

test_a_held_close_reserves_a_plain_get_slot_durably() {
  local rc shape held
  for shape in slot-root own-nested; do
    if [ "$shape" = slot-root ]; then
      make_held_case "held-plain-get-$shape"
      held=$FOREIGN_COPY
    else
      make_own_locked_copy_case "held-plain-get-$shape" enclosing
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      held=$FOREIGN_SLOT/.claude/worktrees/fc-two
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$held" main
    fi
    held_foreign_unlanded "$held"
    held_plain_get_slot "$FOREIGN_CASE"
    jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-plain-get-$shape: the fixture slot is not a plain-get slot"
    held_snapshot "$FOREIGN_CASE" "$held"
    run_foreign_teardown rc
    expect_code 0 "$rc" "held-plain-get-$shape: a landed task must close beside a held copy in a plain-get slot: $(cat "$FOREIGN_CASE/stderr")"
    held_assert_closed "held-plain-get-$shape"
    jq -e '.worktrees[0].leased == true and .worktrees[0].lease_holder == "task-x1"' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-plain-get-$shape: the slot is not durably leased after the close: $(cat "$FOREIGN_CASE/pool/treehouse-state.json")"
    assert_equals "lease 1 --lease-holder task-x1" "$(cat "$FOREIGN_CASE/lease.log")" \
      "held-plain-get-$shape: the slot was not reserved exactly once"
    if [ "$shape" = slot-root ]; then
      held_assert_copies_untouched "held-plain-get-$shape" "$FOREIGN_CASE" "$held"
    else
      assert_absent "$FOREIGN_COPY" "held-plain-get-$shape: the task's own nested copy survived"
      held_fingerprint "$held" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$held")" \
        || fail "held-plain-get-$shape: the foreign copy changed"
      cmp -s "$FOREIGN_CASE/claim-before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" || fail "held-plain-get-$shape: the slot's claim changed"
      git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $held" >/dev/null \
        || fail "held-plain-get-$shape: the foreign copy is no longer registered"
      assert_absent "$FOREIGN_CASE/treehouse.log" "held-plain-get-$shape: the pool slot was returned"
      assert_absent "$FOREIGN_CASE/closeout.log" "held-plain-get-$shape: the closeout driver ran"
    fi
    assert_present "$held/unlanded.txt" "held-plain-get-$shape: the foreign copy's unique file is gone"
    assert_grep "is reserved under a durable lease and stays claimed" "$FOREIGN_CASE/stdout" \
      "held-plain-get-$shape: the output did not say the slot is reserved"
  done
  pass "a held close reserves a plain-get slot under a durable lease before it removes anything and leaves the held copy byte-identical"
}

test_a_held_close_refuses_when_the_slot_cannot_be_durably_leased() {
  local rc mode held reason
  for mode in lease-fails no-lease-command; do
    make_own_locked_copy_case "held-no-lease-$mode" enclosing
    printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
    add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
    seed_backlog_in_flight "$FOREIGN_CASE"
    held=$FOREIGN_SLOT/.claude/worktrees/fc-two
    git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$held" main
    held_foreign_unlanded "$held"
    held_plain_get_slot "$FOREIGN_CASE"
    : > "$FOREIGN_CASE/$mode"
    held_snapshot "$FOREIGN_CASE" "$held"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-no-lease-$mode: a held close must refuse when the slot cannot be durably leased: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "REFUSED: pool slot $FOREIGN_SLOT could not be durably leased" "$FOREIGN_CASE/stderr" \
      "held-no-lease-$mode: the refusal did not name the slot: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-no-lease-$mode: the refusal did not say nothing was removed"
    case "$mode" in
      lease-fails) reason="Error: the lease could not be recorded" ;;
      no-lease-command) reason="has no lease command to reserve it" ;;
    esac
    assert_grep "$reason" "$FOREIGN_CASE/stderr" "held-no-lease-$mode: the refusal did not say why the lease failed"
    assert_present "$FOREIGN_COPY" "held-no-lease-$mode: the task's own nested copy was removed"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-no-lease-$mode: the task record was removed"
    [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-no-lease-$mode: the backlog item was closed by a refused close"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-no-lease-$mode: a refused close wrote a held-copy record"
    jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-no-lease-$mode: the slot's lease record changed"
    held_assert_untouched "held-no-lease-$mode" "$FOREIGN_CASE" "$held"
  done
  pass "a held close refuses before it removes anything when the slot cannot be durably leased, and says why"
}

# A held close that cannot durably lease its slot is an entry-decidable refusal,
# so it leaves a pending-close record from an earlier failed run, and the return
# record beside it, byte for byte, for a prior and a plain record; the same
# fixture with a slot that leases closes normally and retires both.
held_marker_case() {  # <label> <enclosing|plain>
  make_own_locked_copy_case "$1" "$2"
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
  seed_backlog_in_flight "$FOREIGN_CASE"
  HELD_COPY=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$HELD_COPY" main
  held_foreign_unlanded "$HELD_COPY"
  held_plain_get_slot "$FOREIGN_CASE"
  nested_place_leftovers "$FOREIGN_CASE"
  cp "$FOREIGN_CASE/state/task-x1.backlog-close" "$FOREIGN_CASE/backlog-close.before"
  cp "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "$FOREIGN_CASE/return-pending.before"
}

# The entry checks of a held close, one named test per control and record shape.
# held_entry_case <label> <plain|enclosing> <scenario> runs one teardown of a
# held close whose record, lease or inventory is in the state the scenario
# names. The refusal scenarios must leave a pending-close record and a
# return-pending record placed beforehand byte for byte, take no lease and
# write no held-copy record, before the slot is reserved; the others close.
held_entry_refused() {  # <label> <fragment>
  local label=$1 fragment=$2
  expect_code 1 "$HELD_RC" "$label: the held close must refuse at entry: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "$fragment" "$FOREIGN_CASE/stderr" "$label: the refusal did not name its cause"
  cmp -s "$FOREIGN_CASE/backlog-close.before" "$FOREIGN_CASE/state/task-x1.backlog-close" || fail "$label: the refusal changed the pending-close record"
  cmp -s "$FOREIGN_CASE/return-pending.before" "$FOREIGN_CASE/state/task-x1.teardown-return-pending" || fail "$label: the refusal changed the return-pending record"
  jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null || fail "$label: the refusal took a lease"
  assert_present "$FOREIGN_COPY" "$label: the task's own nested copy was removed"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
  held_assert_untouched "$label" "$FOREIGN_CASE" "$HELD_COPY"
}

held_entry_case() {  # <label> <plain|enclosing> <scenario>
  local label=$1 shape=$2 scenario=$3 data
  held_marker_case "$label" "$shape"
  data=$FOREIGN_CASE/data
  mkdir -p "$data"
  HELD_RC=0
  case "$scenario" in
    lease-no-command) : > "$FOREIGN_CASE/no-lease-command" ;;
    lease-fails) : > "$FOREIGN_CASE/lease-fails" ;;
    record-directory) mkdir "$data/held-foreign-copies.log" ;;
    unrecorded-readonly | symlink-unrecorded-readonly)
      printf '2000-01-01T00:00:00Z\ttask-x1\t/elsewhere\t/elsewhere/copy\tother reason\n' > "$data/real-held-log"
      chmod a-w "$data/real-held-log"
      if [ "$scenario" = unrecorded-readonly ]; then mv "$data/real-held-log" "$data/held-foreign-copies.log"; else ln -s real-held-log "$data/held-foreign-copies.log"; fi
      # A user who can write a read-only file (root) cannot show this refusal.
      if [ -w "$data/held-foreign-copies.log" ]; then HELD_RC=skip; return 0; fi
      ;;
    no-backlog-pending-close-directory)
      # No backlog data applies, so only the clear of the previous pending-close
      # record would refuse this path: it must be refused at entry.
      rm -f "$FOREIGN_CASE/data/backlog.md" "$FOREIGN_CASE/state/task-x1.backlog-close"
      mkdir "$FOREIGN_CASE/state/task-x1.backlog-close"
      ;;
    symlink-dangling) ln -s no-such-target "$data/held-foreign-copies.log" ;;
    symlink-directory) mkdir "$data/real-held-dir"; ln -s real-held-dir "$data/held-foreign-copies.log" ;;
    symlink-writable)
      printf '2000-01-01T00:00:00Z\ttask-x1\t/elsewhere\t/elsewhere/copy\tother reason\n' > "$data/real-held-log"
      ln -s real-held-log "$data/held-foreign-copies.log"
      ;;
    recorded-readonly | recorded-writable)
      stuck_endpoint_tmux "$FOREIGN_CASE"
      : > "$FOREIGN_CASE/endpoint-stuck"
      run_foreign_teardown HELD_RC
      expect_code 1 "$HELD_RC" "$label: a stuck endpoint must refuse the first close: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals 1 "$(wc -l < "$data/held-foreign-copies.log" | tr -d ' ')" "$label: the first close did not record its one held copy"
      cp "$data/held-foreign-copies.log" "$FOREIGN_CASE/record.before"
      [ "$scenario" = recorded-writable ] || chmod a-w "$data/held-foreign-copies.log"
      rm -f "$FOREIGN_CASE/endpoint-stuck"
      ;;
  esac
  held_snapshot "$FOREIGN_CASE" "$HELD_COPY"
  run_foreign_teardown HELD_RC
}

held_entry_scenario() {  # <plain|enclosing> <scenario>
  local shape=$1 scenario=$2 label="held-entry-$2-$1" data
  held_entry_case "$label" "$shape" "$scenario"
  data=$FOREIGN_CASE/data
  [ "$HELD_RC" != skip ] || return 0
  case "$scenario" in
    lease-no-command | lease-fails)
      held_entry_refused "$label" "REFUSED: pool slot $FOREIGN_SLOT could not be durably leased"
      assert_absent "$data/held-foreign-copies.log" "$label: a refused close wrote a held-copy record"
      ;;
    record-directory | unrecorded-readonly | symlink-dangling | symlink-directory | symlink-unrecorded-readonly)
      held_entry_refused "$label" "REFUSED: the held-copy record $data/held-foreign-copies.log could not be written"
      ;;
    no-backlog-pending-close-directory)
      expect_code 1 "$HELD_RC" "$label: the held close must refuse at entry: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "is not a regular file" "$FOREIGN_CASE/stderr" "$label: the refusal did not name its cause"
      [ -d "$FOREIGN_CASE/state/task-x1.backlog-close" ] || fail "$label: the refusal removed the bad pending-close path"
      cmp -s "$FOREIGN_CASE/return-pending.before" "$FOREIGN_CASE/state/task-x1.teardown-return-pending" || fail "$label: the refusal changed the return-pending record"
      jq -e '.worktrees[0].leased == false' "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null || fail "$label: the refusal took a lease"
      assert_absent "$data/held-foreign-copies.log" "$label: a refused close wrote a held-copy record"
      assert_present "$FOREIGN_COPY" "$label: the task's own nested copy was removed"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
      held_assert_untouched "$label" "$FOREIGN_CASE" "$HELD_COPY"
      ;;
    symlink-writable)
      expect_code 0 "$HELD_RC" "$label: a symlink to a writable record must let the close finish: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "$label"
      assert_equals 2 "$(wc -l < "$data/real-held-log" | tr -d ' ')" "$label: the close did not append through the symlink"
      ;;
    recorded-readonly | recorded-writable)
      expect_code 0 "$HELD_RC" "$label: the rerun must close, since every held copy is already recorded: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "$label"
      cmp -s "$FOREIGN_CASE/record.before" "$data/held-foreign-copies.log" || fail "$label: the rerun changed the record"
      ;;
    close)
      expect_code 0 "$HELD_RC" "$label: a held close whose slot leases must finish: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "$label"
      assert_absent "$FOREIGN_CASE/state/task-x1.backlog-close" "$label: the earlier pending-close record survived"
      assert_absent "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "$label: the return-pending record survived"
      assert_no_grep "dropped" "$FOREIGN_CASE/data/backlog.md" "$label: the earlier record's drop note was replayed"
      ;;
  esac
  chmod -R u+w "$data" 2>/dev/null || true
}

test_held_entry_lease_no_command_plain() {
  held_entry_scenario plain lease-no-command
  pass "held close entry check, lease-no-command, plain record"
}

test_held_entry_lease_no_command_enclosing() {
  held_entry_scenario enclosing lease-no-command
  pass "held close entry check, lease-no-command, enclosing record"
}

test_held_entry_lease_fails_plain() {
  held_entry_scenario plain lease-fails
  pass "held close entry check, lease-fails, plain record"
}

test_held_entry_lease_fails_enclosing() {
  held_entry_scenario enclosing lease-fails
  pass "held close entry check, lease-fails, enclosing record"
}

test_held_entry_record_directory_plain() {
  held_entry_scenario plain record-directory
  pass "held close entry check, record-directory, plain record"
}

test_held_entry_record_directory_enclosing() {
  held_entry_scenario enclosing record-directory
  pass "held close entry check, record-directory, enclosing record"
}

test_held_entry_unrecorded_readonly_plain() {
  held_entry_scenario plain unrecorded-readonly
  pass "held close entry check, unrecorded-readonly, plain record"
}

test_held_entry_unrecorded_readonly_enclosing() {
  held_entry_scenario enclosing unrecorded-readonly
  pass "held close entry check, unrecorded-readonly, enclosing record"
}

test_held_entry_symlink_dangling_plain() {
  held_entry_scenario plain symlink-dangling
  pass "held close entry check, symlink-dangling, plain record"
}

test_held_entry_symlink_dangling_enclosing() {
  held_entry_scenario enclosing symlink-dangling
  pass "held close entry check, symlink-dangling, enclosing record"
}

test_held_entry_symlink_directory_plain() {
  held_entry_scenario plain symlink-directory
  pass "held close entry check, symlink-directory, plain record"
}

test_held_entry_symlink_directory_enclosing() {
  held_entry_scenario enclosing symlink-directory
  pass "held close entry check, symlink-directory, enclosing record"
}

test_held_entry_symlink_unrecorded_readonly_plain() {
  held_entry_scenario plain symlink-unrecorded-readonly
  pass "held close entry check, symlink-unrecorded-readonly, plain record"
}

test_held_entry_symlink_unrecorded_readonly_enclosing() {
  held_entry_scenario enclosing symlink-unrecorded-readonly
  pass "held close entry check, symlink-unrecorded-readonly, enclosing record"
}

test_held_entry_symlink_writable_plain() {
  held_entry_scenario plain symlink-writable
  pass "held close entry check, symlink-writable, plain record"
}

test_held_entry_symlink_writable_enclosing() {
  held_entry_scenario enclosing symlink-writable
  pass "held close entry check, symlink-writable, enclosing record"
}

test_held_entry_no_backlog_pending_close_directory_plain() {
  held_entry_scenario plain no-backlog-pending-close-directory
  pass "held close entry check, no-backlog-pending-close-directory, plain record"
}

test_held_entry_no_backlog_pending_close_directory_enclosing() {
  held_entry_scenario enclosing no-backlog-pending-close-directory
  pass "held close entry check, no-backlog-pending-close-directory, enclosing record"
}

test_held_entry_recorded_readonly_plain() {
  held_entry_scenario plain recorded-readonly
  pass "held close entry check, recorded-readonly, plain record"
}

test_held_entry_recorded_readonly_enclosing() {
  held_entry_scenario enclosing recorded-readonly
  pass "held close entry check, recorded-readonly, enclosing record"
}

test_held_entry_recorded_writable_plain() {
  held_entry_scenario plain recorded-writable
  pass "held close entry check, recorded-writable, plain record"
}

test_held_entry_recorded_writable_enclosing() {
  held_entry_scenario enclosing recorded-writable
  pass "held close entry check, recorded-writable, enclosing record"
}

test_held_entry_close_plain() {
  held_entry_scenario plain close
  pass "held close entry check, close, plain record"
}

test_held_entry_close_enclosing() {
  held_entry_scenario enclosing close
  pass "held close entry check, close, enclosing record"
}

# A held close of a copy in a superseded pool folder: the project's current pool
# is another folder that reuses its slot names, so the close leases the slot by
# its exact path in the folder that holds it, never by name, and Treehouse then
# never hands it out over the held copies, even once that folder is current
# again. A lease an earlier teardown took by name on a same-named slot of the
# current pool is released after the reservation and the held-copy record
# checks, so a close those checks refuse takes no lease and releases no such
# lease, and its rerun releases it, whether the rerun is still a held close,
# which first leases its own slot by path, or, once the held copy is gone, an
# ordinary one. Without lease --path
# the close refuses and the copies stay held.
held_superseded_case() {  # <name> <misdirected|plain> [no-lease-path]
  local cur
  make_held_case "$1"
  held_foreign_unlanded "$FOREIGN_COPY"
  held_plain_get_slot "$FOREIGN_CASE"
  [ "${3:-}" = no-lease-path ] || : > "$FOREIGN_CASE/lease-path"
  cur=$FOREIGN_CASE/current-pool/1/project
  mkdir -p "${cur%/*}"
  git -C "$FOREIGN_CASE/project" worktree add -q --detach "$cur" main
  HELD_CURRENT_SLOT=$(cd "$cur" && pwd -P)
  if [ "$2" = misdirected ]; then
    printf '[{"name":"1","path":"%s","lease_holder":"task-x1","processes":[]}]\n' "$HELD_CURRENT_SLOT"
  else
    printf '[{"name":"1","path":"%s","lease_holder":"","processes":[]}]\n' "$HELD_CURRENT_SLOT"
  fi > "$FOREIGN_CASE/status.json"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
}

test_a_held_close_in_a_superseded_pool_folder_leases_the_slot_by_its_path() {
  local rc shape lock
  for shape in plain misdirected; do
    held_superseded_case "held-superseded-$shape" "$shape"
    lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
      bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project")
    mv "$FOREIGN_CASE/fakebin/docker" "$FOREIGN_CASE/fakebin/docker-store"
    cat > "$FOREIGN_CASE/fakebin/docker" <<SH
#!/usr/bin/env bash
if [ -e "$lock" ]; then echo locked; else echo free; fi >> "$FOREIGN_CASE/docker-lock.log"
exec "$FOREIGN_CASE/fakebin/docker-store" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/docker"
    run_foreign_teardown rc
    expect_code 0 "$rc" "held-superseded-$shape: a landed task must close beside a held copy in a superseded pool folder: $(cat "$FOREIGN_CASE/stderr")"
    held_assert_closed "held-superseded-$shape"
    assert_equals "lease --path $FOREIGN_SLOT --lease-holder task-x1" "$(cat "$FOREIGN_CASE/lease.log")" \
      "held-superseded-$shape: the slot was not leased once, by its exact path"
    jq -e --arg slot "$FOREIGN_SLOT" '.worktrees[] | select(.path == $slot) | .leased == true and .lease_holder == "task-x1"' \
      "$FOREIGN_CASE/pool/treehouse-state.json" >/dev/null \
      || fail "held-superseded-$shape: the old folder does not record the slot as leased: $(cat "$FOREIGN_CASE/pool/treehouse-state.json")"
    held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" \
      || fail "held-superseded-$shape: the held copy changed"
    cmp -s "$FOREIGN_CASE/claim-before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" || fail "held-superseded-$shape: the slot's claim changed"
    if [ "$shape" = misdirected ]; then
      assert_equals "return $HELD_CURRENT_SLOT --if-lease-holder task-x1" "$(cat "$FOREIGN_CASE/treehouse.log")" \
        "held-superseded-$shape: the misdirected lease was not released by the conditional return alone"
    else
      assert_absent "$FOREIGN_CASE/treehouse.log" "held-superseded-$shape: a pool slot was returned"
    fi
    assert_grep "is reserved under a durable lease and stays claimed" "$FOREIGN_CASE/stdout" \
      "held-superseded-$shape: the output did not say the slot is reserved"
    assert_present "$FOREIGN_CASE/docker-lock.log" "held-superseded-$shape: the Docker cleanup did not run"
    assert_no_grep locked "$FOREIGN_CASE/docker-lock.log" \
      "held-superseded-$shape: the project lock was still held through Docker cleanup after the slot was leased by its path"
  done
  pass "a held close in a superseded pool folder leases the slot by its exact path and releases only this task's misdirected lease"
}

test_a_held_close_in_a_superseded_pool_folder_refuses_without_lease_path() {
  local rc
  held_superseded_case held-superseded-no-path misdirected no-lease-path
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-superseded-no-path: a held close must refuse when the slot cannot be leased by its path: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "needs treehouse v3.1.7-fm or later (treehouse lease --path)" "$FOREIGN_CASE/stderr" \
    "held-superseded-no-path: the refusal did not name the treehouse build it needs"
  assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-superseded-no-path: the refusal did not say nothing was removed"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-superseded-no-path: the task record was removed"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-no-path: the refusal leased a slot"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-superseded-no-path: a refused close wrote a held-copy record"
  held_assert_untouched "held-superseded-no-path" "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a held close in a superseded pool folder refuses with the treehouse build it needs when lease --path is missing, and changes nothing"
}

test_a_refused_held_close_releases_no_misdirected_lease() {
  local rc
  held_superseded_case held-superseded-refused misdirected
  mkdir -p "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-superseded-refused: a held close must refuse when its record cannot be written: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "could not be written" "$FOREIGN_CASE/stderr" "held-superseded-refused: the refusal did not say why"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-superseded-refused: the task record was removed"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-refused: the refusal took a lease"
  assert_absent "$FOREIGN_CASE/treehouse.log" "held-superseded-refused: the refusal returned or released a slot"
  held_assert_untouched "held-superseded-refused" "$FOREIGN_CASE" "$FOREIGN_COPY"
  rmdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-superseded-refused: the rerun must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "return $HELD_CURRENT_SLOT --if-lease-holder task-x1" "$(cat "$FOREIGN_CASE/treehouse.log")" \
    "held-superseded-refused: the rerun did not release the misdirected lease by the conditional return alone"
  assert_equals "lease --path $FOREIGN_SLOT --lease-holder task-x1" "$(cat "$FOREIGN_CASE/lease.log")" \
    "held-superseded-refused: the rerun did not lease the slot once, by its exact path"
  pass "a held close that refuses releases no misdirected lease, and its rerun, with its own slot leased by path, releases it"
}

test_an_ordinary_rerun_after_a_refused_held_close_releases_the_misdirected_lease() {
  local rc
  held_superseded_case held-superseded-then-ordinary misdirected
  mkdir -p "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-superseded-then-ordinary: a held close must refuse when its record cannot be written: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-then-ordinary: the refused close took a lease"
  assert_absent "$FOREIGN_CASE/treehouse.log" "held-superseded-then-ordinary: the refused close returned or released a slot"
  held_assert_untouched "held-superseded-then-ordinary" "$FOREIGN_CASE" "$FOREIGN_COPY"
  rmdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  git -C "$FOREIGN_CASE/project" worktree remove --force "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-superseded-then-ordinary: the ordinary rerun must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-superseded-then-ordinary: the rerun kept the task record"
  assert_not_contains "$(cat "$FOREIGN_CASE/stdout")" "the slot return is deferred" \
    "held-superseded-then-ordinary: the rerun was still a held close"
  assert_equals 1 "$(grep -c "^return $HELD_CURRENT_SLOT --if-lease-holder task-x1\$" "$FOREIGN_CASE/treehouse.log" || true)" \
    "held-superseded-then-ordinary: the ordinary rerun did not release the misdirected lease by the conditional return: $(cat "$FOREIGN_CASE/treehouse.log" 2>/dev/null)"
  assert_absent "$FOREIGN_CASE/lease.log" "held-superseded-then-ordinary: the rerun leased a slot"
  pass "an ordinary rerun after a refused held close releases the misdirected lease its task still holds"
}

test_the_held_close_notice_promises_no_cleanup_that_does_not_exist() {
  local rc second copy holder copy_q holder_q slot_q proj_q
  make_held_case held-notice
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_foreign_unlanded "$FOREIGN_COPY"
  held_foreign_unlanded "$second"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-notice: a landed task must close beside two held copies: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-notice
  held_assert_untouched held-notice "$FOREIGN_CASE" "$FOREIGN_COPY" "$second"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: " "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not list the first held copy"
  assert_grep "held foreign copy $second stays in pool slot $FOREIGN_SLOT: " "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not list the second held copy"
  assert_grep "pool slot $FOREIGN_SLOT is reserved under a durable lease and stays claimed, and nothing returns it automatically" "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not say the slot is reserved under a durable lease and stays claimed with no automatic return"
  assert_grep "a held copy is removed only on the owner's word naming it; the nested task copy sweep, when it is armed, also removes an unlocked copy held for commits once its HEAD is landed, and may release a copy locked by Vernant's creation lock only through Vernant's closeout driver, only when its launcher is gone and every proof passes, including every commit on a remote; it never removes an unlocked copy held for unique ignored files." "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not say how a copy held for commits is removed"
  holder=$(jq -r '.worktrees[0].lease_holder // empty' "$FOREIGN_CASE/pool/treehouse-state.json")
  [ -n "$holder" ] || fail "held-notice: the fixture slot has no lease holder"
  printf -v holder_q '%q' "$holder"
  printf -v slot_q '%q' "$FOREIGN_SLOT"
  printf -v proj_q '%q' "$FOREIGN_CASE/project"
  for copy in "$FOREIGN_COPY" "$second"; do
    printf -v copy_q '%q' "$copy"
    assert_grep "notice: next step for the owner of $copy: list the commits only it holds with git -C $copy_q log --oneline HEAD --not --remotes, land them, remove the copy with git -C $slot_q worktree remove $copy_q (a copy locked by Vernant's creation lock goes through scripts/git-stability/closeout_pr.py --cleanup-worktree $copy_q --execute-cleanup, run from the slot), and when no copy is left in the slot return it with (cd $proj_q && treehouse return $slot_q --if-lease-holder $holder_q </dev/null)." \
      "$FOREIGN_CASE/stdout" "held-notice: the output did not print the exact next step for the owner of $copy: $(cat "$FOREIGN_CASE/stdout")"
  done
  assert_grep "each held copy is also listed in $FOREIGN_CASE/data/held-foreign-copies.log" "$FOREIGN_CASE/stdout" \
    "held-notice: the output did not name the held-copy record"
  assert_no_grep "reaper" "$FOREIGN_CASE/stdout" "held-notice: the output promises a reaper run"
  assert_no_grep "named drop" "$FOREIGN_CASE/stdout" "held-notice: the output promises a named drop"
  assert_no_grep "reaper" "$FOREIGN_CASE/stderr" "held-notice: the error output promises a reaper run"
  pass "a held close lists every held copy, says the slot is reserved under a durable lease and stays claimed, and promises no cleanup that does not exist"
}

test_a_held_close_that_a_later_step_refuses_leaves_one_record_line_and_a_rerun_adds_none() {
  local rc
  make_held_case held-late-refusal
  held_foreign_unlanded "$FOREIGN_COPY"
  stuck_endpoint_tmux "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/endpoint-stuck"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-late-refusal: a stuck endpoint must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-late-refusal: the task record was removed by a refused close"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-late-refusal: the record is written before anything is removed, so the refused close leaves its one line"
  assert_no_grep "held foreign copy" "$FOREIGN_CASE/stdout" "held-late-refusal: a refused close reported held copies"
  held_assert_untouched held-late-refusal "$FOREIGN_CASE" "$FOREIGN_COPY"
  rm -f "$FOREIGN_CASE/endpoint-stuck"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-late-refusal: the rerun must close once the endpoint closes: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-late-refusal
  held_assert_untouched held-late-refusal "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-late-refusal: the rerun repeated the record line"
  pass "a held close refused by a later step leaves its one record line, and the close that completes does not repeat it"
}

test_a_held_copy_record_that_cannot_be_written_refuses_the_close() {
  local rc
  make_held_case held-unwritable
  held_foreign_unlanded "$FOREIGN_COPY"
  mkdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-unwritable: a close whose inventory cannot be written must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "REFUSED: the held-copy record $FOREIGN_CASE/data/held-foreign-copies.log could not be written" "$FOREIGN_CASE/stderr" \
    "held-unwritable: the refusal did not name the record: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "nothing was removed" "$FOREIGN_CASE/stderr" "held-unwritable: the refusal did not say nothing was removed"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-unwritable: the task record was removed"
  assert_present "$FOREIGN_COPY/unlanded.txt" "held-unwritable: the foreign copy's file is gone"
  [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-unwritable: the backlog item was closed by a refused close"
  assert_no_grep "held foreign copy" "$FOREIGN_CASE/stdout" "held-unwritable: a refused close reported held copies"
  held_assert_untouched held-unwritable "$FOREIGN_CASE" "$FOREIGN_COPY"
  rmdir "$FOREIGN_CASE/data/held-foreign-copies.log"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-unwritable: the rerun must close once the record can be written: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-unwritable
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-unwritable: the rerun did not write one record line"
  pass "a held close whose record cannot be written refuses with nothing removed, and the rerun closes with one line"
}

test_a_legacy_record_held_close_still_names_the_held_copies() {
  local rc
  make_held_case held-legacy
  grep -v '^spawn_gen=' "$FOREIGN_CASE/state/task-x1.meta" > "$FOREIGN_CASE/meta.legacy"
  cp "$FOREIGN_CASE/meta.legacy" "$FOREIGN_CASE/state/task-x1.meta"
  held_foreign_unlanded "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  FOREIGN_TEARDOWN_ARGS=(--legacy-record)
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 0 "$rc" "held-legacy: a landed legacy record must close beside a held copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "legacy record accepted without spawn_gen" "$FOREIGN_CASE/stdout" "held-legacy: the close did not take the legacy completion line"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-legacy: the task record survived"
  held_assert_untouched held-legacy "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_grep "the slot return is deferred" "$FOREIGN_CASE/stdout" "held-legacy: the legacy close did not say the slot return is deferred"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its HEAD " \
    "$FOREIGN_CASE/stdout" "held-legacy: the legacy close did not list the held copy: $(cat "$FOREIGN_CASE/stdout")"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-legacy: the record is not one line"
  pass "a --legacy-record close beside a held foreign copy still lists the held copy and says the slot return is deferred"
}

test_a_foreign_copy_does_not_excuse_an_own_copy_that_is_not_landed() {
  local rc shape
  for shape in dirty unlanded; do
    make_held_case "held-own-$shape"
    held_foreign_unlanded "$FOREIGN_COPY"
    case "$shape" in
      dirty) printf 'edit\n' > "$FOREIGN_SLOT/own-edit.txt" ;;
      unlanded)
        printf 'own\n' > "$FOREIGN_SLOT/own.txt"
        git -C "$FOREIGN_SLOT" add own.txt
        git -C "$FOREIGN_SLOT" -c user.email=t@t -c user.name=t commit -qm 'unlanded own work'
        ;;
    esac
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-own-$shape: an own copy that is not landed must refuse beside a foreign copy: $(cat "$FOREIGN_CASE/stderr")"
    case "$shape" in
      dirty) assert_grep "uncommitted changes" "$FOREIGN_CASE/stderr" "held-own-dirty: the refusal did not name the own copy's changes" ;;
      unlanded) assert_grep "the ship deliverable is not landed" "$FOREIGN_CASE/stderr" "held-own-unlanded: the refusal did not name the own copy's commits: $(cat "$FOREIGN_CASE/stderr")" ;;
    esac
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-own-$shape: the task record was removed"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-own-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-own-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
  done
  pass "a dirty or unlanded own copy still refuses exactly as before when a foreign copy would be held, and nothing changes"
}

test_a_foreign_copy_that_cannot_be_held_still_refuses_the_whole_close() {
  local rc shape pid reason
  for shape in dirty-and-unlanded unlanded-with-record unlanded-with-process; do
    make_held_case "held-mixed-$shape"
    held_foreign_unlanded "$FOREIGN_COPY"
    case "$shape" in
      dirty-and-unlanded)
        printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
        reason="it has uncommitted or untracked-unignored changes"
        ;;
      unlanded-with-record)
        fm_write_meta "$FOREIGN_CASE/state/other.meta" "kind=ship" "worktree=$FOREIGN_COPY"
        reason="task other's active record names it as its worktree"
        ;;
      unlanded-with-process)
        teardown_fixture_start "$FOREIGN_COPY" KILL sleep 300
        pid=$TEARDOWN_FIXTURE_PID
        reason="process $pid is running in it"
        cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) if kill -0 $pid 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $pid '$FOREIGN_COPY'; fi; exit 0 ;;
esac
exit 1
SH
        ;;
    esac
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-mixed-$shape: a copy that is not only held back by unique work must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-mixed-$shape: the refusal changed"
    assert_grep "missing=foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: $reason" "$FOREIGN_CASE/stderr" \
      "held-mixed-$shape: the refusal did not name what really blocks the copy: $(cat "$FOREIGN_CASE/stderr")"
    assert_no_grep "is not proved landed" "$FOREIGN_CASE/stderr" \
      "held-mixed-$shape: the refusal names the unlanded HEAD instead of what really blocks the copy"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-mixed-$shape: the task record was removed"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-mixed-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-mixed-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
  done
  pass "a foreign copy that is also dirty, named by another record, or running a process still refuses the whole close"
}

test_a_copy_held_for_ignored_files_is_typed_and_asked_about_those_files_when_another_copy_blocks() {
  local rc second
  make_held_case held-ignored-question
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  held_ignored_file "$FOREIGN_COPY"
  printf 'edit\n' > "$second/untracked.txt"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-ignored-question: a dirty second copy must refuse the whole close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "rule=copy-ignored-files " "$FOREIGN_CASE/stderr" \
    "held-ignored-question: the ignored-file copy was not typed by what holds it: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "human-only-exit: What owner-approved disposition covers the ignored files only $FOREIGN_COPY holds (it holds ignored files that exist nowhere else: unique.dat)?" "$FOREIGN_CASE/stderr" \
    "held-ignored-question: the question did not ask about the ignored files: $(cat "$FOREIGN_CASE/stderr")"
  assert_no_grep "What verified landing or retained ownership covers $FOREIGN_COPY" "$FOREIGN_CASE/stderr" \
    "held-ignored-question: the question asks about a landing that is not the blocker: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-ignored-question: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-ignored-question: a refused close wrote a held-copy record"
  held_assert_untouched held-ignored-question "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a copy held for ignored files that is listed among refusals is typed copy-ignored-files and asked about those files, not about a landing"
}

# A copy that a process of the closing task runs in, or whose creation-lock
# launcher is the task's own session, is not held: retire would have to signal
# a process inside a copy that stays. The refusal names that process, not the
# HEAD that is not proved landed, and nothing is signalled or removed.
test_a_foreign_copy_not_held_for_a_process_of_this_teardown_names_that_process() {
  local rc shape agent child pidfile i reason
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  local script='my $child = fork(); if (!$child) { chdir $ARGV[1]; exec "sleep", "300"; } $SIG{CHLD} = "IGNORE"; open my $fh, ">", $ARGV[0]; print $fh $child; close $fh; sleep 300;'
  for shape in unlanded-in-copy unlanded-with-launcher; do
    child=
    if [ "$shape" = unlanded-with-launcher ]; then
      start_foreign_session_case "held-own-$shape" agent
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
      add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
      seed_backlog_in_flight "$FOREIGN_CASE"
      held_foreign_unlanded "$FOREIGN_COPY"
      agent=$FOREIGN_AGENT
      reason="process $FOREIGN_LAUNCHER of this teardown runs in it or launched its creation lock"
    else
      make_held_case "held-own-$shape"
      held_foreign_unlanded "$FOREIGN_COPY"
      pidfile=$FOREIGN_CASE/child-pid
      teardown_fixture_start "$FOREIGN_SLOT" KILL perl -e "$script" "$pidfile" "$FOREIGN_COPY"
      agent=$TEARDOWN_FIXTURE_PID
      for i in $(seq 100); do [ -s "$pidfile" ] && break; sleep 0.05; done
      child=$(cat "$pidfile")
      cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*)
    if kill -0 $agent 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $agent '$FOREIGN_SLOT'; fi
    if kill -0 $child 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $child '$FOREIGN_COPY'; fi
    exit 0 ;;
esac
exit 1
SH
      reason="process $child of this teardown runs in it or launched its creation lock"
    fi
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    kill -0 "$agent" 2>/dev/null || fail "held-own-$shape: a refused close ended the task's session"
    [ -z "$child" ] || kill -0 "$child" 2>/dev/null || fail "held-own-$shape: a refused close ended the process inside the copy"
    kill -KILL ${child:+"$child"} "$agent" 2>/dev/null || true
    expect_code 1 "$rc" "held-own-$shape: a copy with a process of this teardown must not be held: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "missing=foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: $reason" "$FOREIGN_CASE/stderr" \
      "held-own-$shape: the refusal did not name the process of this teardown: $(cat "$FOREIGN_CASE/stderr")"
    assert_no_grep "is not proved landed" "$FOREIGN_CASE/stderr" "held-own-$shape: the refusal names the unlanded HEAD instead of the process"
    assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-own-$shape: the refusal changed"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-own-$shape: the task record was removed"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-own-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-own-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
  done
  pass "a copy not held because a process of the closing task runs in it, or launched its lock, is refused naming that process, and nothing is signalled or removed"
}


teardown_test_cases=(
test_a_held_copy_keeps_its_unique_ignored_files_and_none_are_preserved
test_task_closes_beside_a_foreign_copy_with_unpushed_commits
test_held_copy_record_has_one_exact_line_per_copy
test_a_held_close_removes_only_the_tasks_own_nested_copy
test_a_held_close_refuses_when_an_own_nested_copy_holds_another_repository
test_a_held_close_is_not_stopped_by_a_submodule_of_the_own_repository
test_a_foreign_copy_inside_the_own_nested_copy_is_never_left_to_the_removal
test_an_ordinary_close_never_turns_into_a_held_close_during_the_project_lock_wait
test_a_stale_lock_cleanup_never_turns_an_ordinary_close_into_a_held_close
test_a_held_close_reserves_a_plain_get_slot_durably
test_a_held_close_refuses_when_the_slot_cannot_be_durably_leased
test_held_entry_lease_no_command_plain
test_held_entry_lease_no_command_enclosing
test_held_entry_lease_fails_plain
test_held_entry_lease_fails_enclosing
test_held_entry_record_directory_plain
test_held_entry_record_directory_enclosing
test_held_entry_unrecorded_readonly_plain
test_held_entry_unrecorded_readonly_enclosing
test_held_entry_symlink_dangling_plain
test_held_entry_symlink_dangling_enclosing
test_held_entry_symlink_directory_plain
test_held_entry_symlink_directory_enclosing
test_held_entry_symlink_unrecorded_readonly_plain
test_held_entry_symlink_unrecorded_readonly_enclosing
test_held_entry_symlink_writable_plain
test_held_entry_symlink_writable_enclosing
test_held_entry_no_backlog_pending_close_directory_plain
test_held_entry_no_backlog_pending_close_directory_enclosing
test_held_entry_recorded_readonly_plain
test_held_entry_recorded_readonly_enclosing
test_held_entry_recorded_writable_plain
test_held_entry_recorded_writable_enclosing
test_held_entry_close_plain
test_held_entry_close_enclosing
test_a_held_close_in_a_superseded_pool_folder_leases_the_slot_by_its_path
test_a_held_close_in_a_superseded_pool_folder_refuses_without_lease_path
test_a_refused_held_close_releases_no_misdirected_lease
test_an_ordinary_rerun_after_a_refused_held_close_releases_the_misdirected_lease
test_the_held_close_notice_promises_no_cleanup_that_does_not_exist
test_a_held_close_that_a_later_step_refuses_leaves_one_record_line_and_a_rerun_adds_none
test_a_held_copy_record_that_cannot_be_written_refuses_the_close
test_a_legacy_record_held_close_still_names_the_held_copies
test_a_foreign_copy_does_not_excuse_an_own_copy_that_is_not_landed
test_a_foreign_copy_that_cannot_be_held_still_refuses_the_whole_close
test_a_copy_held_for_ignored_files_is_typed_and_asked_about_those_files_when_another_copy_blocks
test_a_foreign_copy_not_held_for_a_process_of_this_teardown_names_that_process
test_legacy_preservation_refusal_prints_no_completing_command
test_foreign_copy_that_git_protects_is_a_typed_nonforced_removal
test_foreign_copy_removal_that_fails_for_another_reason_is_a_plain_error
test_landing_check_that_could_not_ask_the_forge_is_a_plain_error
test_landing_check_that_could_not_compare_with_the_default_branch_is_a_plain_error
test_landing_check_that_the_forge_answered_not_merged_stays_a_copy_landed_refusal
test_landing_proof_that_head_changed_after_its_proof_is_unasked
test_git_protection_is_read_from_the_copy_state
test_nonforced_removal_is_decided_from_the_copy_not_from_gits_message
test_foreign_copy_with_a_modules_directory_is_a_typed_nonforced_removal
test_creation_lock_owner_asks_the_same_question_at_proof_and_release_time
test_copy_path_with_newlines_cannot_forge_envelope_lines
test_foreign_copy_that_is_not_a_worktree_root_is_a_typed_refusal
test_foreign_copy_with_an_unresolvable_head_is_a_typed_refusal
test_foreign_copy_whose_anchor_names_another_commit_is_a_typed_refusal
test_teardown_usage_and_inspection_errors_are_not_policy_events
test_earlier_preserved_copy_survives_until_its_replacement_is_verified
test_own_locked_copy_with_no_closeout_interpreter_refuses_at_entry
test_closeout_plan_refusal_refuses_at_entry
test_linux_removability_refuses_an_entry_it_cannot_open
test_preserve_parent_and_metadata_boundaries
test_preserve_parent_on_another_filesystem_refuses_at_entry
)

# Restore errexit before the first case of this slice to match the original combined run.
errexit_restored=false
fm_test_before_case() {
  if [ "$errexit_restored" = false ] && [ "$1" = test_a_held_copy_keeps_its_unique_ignored_files_and_none_are_preserved ]; then
    set -e
    errexit_restored=true
  fi
}
fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
