#!/usr/bin/env bash
# Behavior tests for bin/fm-confined-git.sh, the git a confined worker runs.
#
# A Git write the write profile refuses under refs/heads/archive/ gains one
# stderr line that names the refused ref and the two archive shapes the profile
# allows, with the task id spelled out, while git's exit status, standard output
# and own standard error stay unchanged. Each case runs the same command with
# and without the wrapper first on PATH and compares the two runs. A fake git
# that reports the real refusal runs everywhere; the sandbox-exec case builds
# the production profile and runs real Git inside it wherever macOS lets this
# process apply one.
set -u
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS GIT_TRACE2_EVENT

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-confined-git.sh"
TMP_ROOT=$(fm_test_tmproot fm-confined-git)
TMP_ROOT=$(cd -P "$TMP_ROOT" && pwd -P)
TASK=vernant-d6-case-deletion-build-r2
REFUSED=archive/$TASK-replay-07526ab01
SUBMITTED_SHAPE="archive/$TASK-submitted-<8 lowercase hex>"
PIPELINE_SHAPE="archive/$TASK-pipeline-<8 lowercase hex>"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
fm_git_identity 'Firstmate Tests' 'tests@example.invalid'

# The project, its linked task worktree and the shared Git directory the
# wrapper's config names; the profile builder creates the archive folder at
# every launch.
REPO="$TMP_ROOT/project"
WT="$TMP_ROOT/task-wt"
fm_git_init_commit "$REPO"
git -C "$REPO" worktree add -q -b "fm/$TASK" "$WT" || fail "could not add the task worktree"
COMMON="$REPO/.git"
mkdir -p "$COMMON/refs/heads/archive" "$TMP_ROOT/tmp"
WRAP_DIR="$TMP_ROOT/home/state/$TASK.git-path"
"$WRAPPER" install "$WRAP_DIR" "$TASK" "$WT" || fail "install refused a linked task worktree"

# A model-free git: prints FAKE_GIT_STDOUT, reports FAKE_GIT_MSG the way Git
# does (a fatal: stderr line plus, when GIT_TRACE2_EVENT names a file, a trace2
# error event), records what it was given in FAKE_GIT_LOG and exits
# FAKE_GIT_STATUS.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/git" <<'SH'
#!/bin/bash
if [ -n "${FAKE_GIT_LOG:-}" ]; then
  {
    printf 'argc=%s\n' "$#"
    for arg in "$@"; do printf 'arg=[%s]\n' "$arg"; done
    printf 'trace2=%s\n' "${GIT_TRACE2_EVENT:+set}"
    [ "${FAKE_GIT_READ_STDIN:-0}" != 1 ] || printf 'stdin=[%s]\n' "$(cat)"
  } > "$FAKE_GIT_LOG"
fi
[ -z "${FAKE_GIT_STDOUT:-}" ] || printf '%s\n' "$FAKE_GIT_STDOUT"
if [ -n "${FAKE_GIT_MSG:-}" ]; then
  printf 'fatal: %s\n' "$FAKE_GIT_MSG" >&2
  [ -z "${GIT_TRACE2_EVENT:-}" ] \
    || printf '{"event":"error","sid":"fake","thread":"main","msg":"%s","fmt":"%%s"}\n' "$FAKE_GIT_MSG" >> "$GIT_TRACE2_EVENT"
fi
exit "${FAKE_GIT_STATUS:-0}"
SH
chmod +x "$FAKEBIN/git"

# refusal_message <name under refs/heads/> <git dir as Git prints it>: the text
# Git reports when the kernel refuses the ref's lock file.
refusal_message() {
  printf "cannot lock ref 'refs/heads/%s': Unable to create '%s/refs/heads/%s.lock': Operation not permitted" "$1" "$2" "$1"
}

# rename_message <name under refs/heads/> <git dir as Git prints it>: the text
# Git reports, without quoting either path, when the kernel refuses the reflog
# move of a branch rename or copy into the name.
rename_message() {
  printf 'unable to move logfile %s/logs/refs/.tmp-renamed-log to %s/logs/refs/heads/%s: Operation not permitted' "$2" "$2" "$1"
}

# run_git <label> <path-lead> <confinement> <git argument...>: one git run with
# <path-lead> first on PATH, its stdout, stderr and status kept under <label>.
# A run that loops is stopped after 20 seconds.
run_git() {
  local label=$1 lead=$2 confinement=$3
  shift 3
  PATH="$lead:$PATH" FM_WRITE_CONFINEMENT=$confinement TMPDIR="$TMP_ROOT/tmp" \
    perl -e 'alarm 20; exec @ARGV or die "exec: $!"' git "$@" \
    >"$TMP_ROOT/$label.out" 2>"$TMP_ROOT/$label.err" </dev/null
  echo "$?" >"$TMP_ROOT/$label.status"
}

# assert_same_run <plain> <wrapped> <extra-lines> <what>: the wrapped run kept
# the plain run's status, stdout and stderr, and added <extra-lines> lines.
assert_same_run() {
  local plain=$1 wrapped=$2 extra=$3 what=$4 plain_lines wrapped_lines
  assert_equals "$(cat "$TMP_ROOT/$plain.status")" "$(cat "$TMP_ROOT/$wrapped.status")" "$what: the wrapper changed git's exit status"
  cmp -s "$TMP_ROOT/$plain.out" "$TMP_ROOT/$wrapped.out" || fail "$what: the wrapper changed git's standard output"
  plain_lines=$(($(wc -l <"$TMP_ROOT/$plain.err")))
  wrapped_lines=$(($(wc -l <"$TMP_ROOT/$wrapped.err")))
  assert_equals "$((plain_lines + extra))" "$wrapped_lines" \
    "$what: expected $extra extra stderr line(s)"$'\n'"--- stderr ---"$'\n'"$(cat "$TMP_ROOT/$wrapped.err")"
  awk -v n="$plain_lines" 'NR <= n' "$TMP_ROOT/$wrapped.err" | cmp -s - "$TMP_ROOT/$plain.err" \
    || fail "$what: the wrapper changed git's own stderr"
}

# assert_names_shapes <label> <refused name>: the wrapped run's last stderr
# line names the refused ref and both allowed archive shapes.
assert_names_shapes() {
  local line
  line=$(tail -n 1 "$TMP_ROOT/$1.err")
  assert_contains "$line" "$2" "the extra line does not name the refused ref"
  assert_contains "$line" "$SUBMITTED_SHAPE" "the extra line does not name the submitted archive shape with the task id"
  assert_contains "$line" "$PIPELINE_SHAPE" "the extra line does not name the pipeline archive shape with the task id"
}

test_refused_archive_name_gets_one_line_naming_it_and_both_shapes() {
  ln -s "$REPO" "$TMP_ROOT/project-alias"
  local gitdir label
  # Git prints the shared Git directory it computed, which need not be the
  # canonical spelling; a symbolic link to the project names the same folder.
  for gitdir in "$COMMON" "$TMP_ROOT/project-alias/.git"; do
    label=refused-${gitdir##*/project}
    label=${label//[^A-Za-z0-9-]/-}
    FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$gitdir") FAKE_GIT_STATUS=128 \
      run_git "$label-plain" "$FAKEBIN" seatbelt-v1 branch "$REFUSED" 07526ab01
    FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$gitdir") FAKE_GIT_STATUS=128 \
      run_git "$label-wrapped" "$WRAP_DIR:$FAKEBIN" seatbelt-v1 branch "$REFUSED" 07526ab01
    assert_same_run "$label-plain" "$label-wrapped" 1 "refused $REFUSED through $gitdir"
    assert_names_shapes "$label-wrapped" "$REFUSED"
    # A rename into the name: Git's refused reflog move names logs/, unquoted.
    FAKE_GIT_MSG=$(rename_message "$REFUSED" "$gitdir") FAKE_GIT_STATUS=128 \
      run_git "$label-rename-plain" "$FAKEBIN" seatbelt-v1 branch -m "fm/$TASK" "$REFUSED"
    FAKE_GIT_MSG=$(rename_message "$REFUSED" "$gitdir") FAKE_GIT_STATUS=128 \
      run_git "$label-rename-wrapped" "$WRAP_DIR:$FAKEBIN" seatbelt-v1 branch -m "fm/$TASK" "$REFUSED"
    assert_same_run "$label-rename-plain" "$label-rename-wrapped" 1 "refused rename into $REFUSED through $gitdir"
    assert_names_shapes "$label-rename-wrapped" "$REFUSED"
  done
  # A delete of the name: Git's refused ref lock follows its own prefix.
  FAKE_GIT_MSG="could not delete reference refs/heads/$REFUSED: $(refusal_message "$REFUSED" "$COMMON")" FAKE_GIT_STATUS=1 \
    run_git delete-plain "$FAKEBIN" seatbelt-v1 branch -D "$REFUSED"
  FAKE_GIT_MSG="could not delete reference refs/heads/$REFUSED: $(refusal_message "$REFUSED" "$COMMON")" FAKE_GIT_STATUS=1 \
    run_git delete-wrapped "$WRAP_DIR:$FAKEBIN" seatbelt-v1 branch -D "$REFUSED"
  assert_same_run delete-plain delete-wrapped 1 "refused delete of $REFUSED"
  assert_names_shapes delete-wrapped "$REFUSED"
  [ -z "$(ls "$TMP_ROOT/tmp")" ] || fail "the wrapper left its trace file behind: $(ls "$TMP_ROOT/tmp")"
  pass "a refused archive name gets one extra stderr line naming it and both allowed shapes, with git's status, stdout and stderr unchanged"
}

test_successful_writes_get_no_line() {
  local name
  # A refusal message from a git that still exits 0 adds nothing.
  FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$COMMON") FAKE_GIT_STATUS=0 FAKE_GIT_STDOUT=created \
    run_git success-message-plain "$FAKEBIN" seatbelt-v1 branch "$REFUSED"
  FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$COMMON") FAKE_GIT_STATUS=0 FAKE_GIT_STDOUT=created \
    run_git success-message-wrapped "$WRAP_DIR:$FAKEBIN" seatbelt-v1 branch "$REFUSED"
  assert_same_run success-message-plain success-message-wrapped 0 "a git that exits 0"
  # Real Git creates both allowed archive names, as an unconfined run allows.
  for name in "archive/$TASK-submitted-0123abcd" "archive/$TASK-pipeline-89abcdef"; do
    run_git "allowed-${name##*-}" "$WRAP_DIR" seatbelt-v1 -C "$WT" branch "$name" HEAD
    expect_code 0 "$(cat "$TMP_ROOT/allowed-${name##*-}.status")" "real git through the wrapper did not create $name"
    [ ! -s "$TMP_ROOT/allowed-${name##*-}.err" ] || fail "an allowed write printed stderr: $(cat "$TMP_ROOT/allowed-${name##*-}.err")"
    git -C "$WT" rev-parse -q --verify "refs/heads/$name" >/dev/null || fail "$name was not created"
    git -C "$WT" branch -q -D "$name" || fail "could not remove $name"
  done
  run_git rev-parse-plain /nonexistent seatbelt-v1 -C "$WT" rev-parse HEAD
  run_git rev-parse-wrapped "$WRAP_DIR" seatbelt-v1 -C "$WT" rev-parse HEAD
  assert_same_run rev-parse-plain rev-parse-wrapped 0 "real git rev-parse"
  pass "a git that exits 0 gets no extra line and real git writes succeed through the wrapper"
}

test_refusals_outside_the_task_archive_get_no_line() {
  local other="$TMP_ROOT/other-project" label
  fm_git_init_commit "$other"
  mkdir -p "$other/.git/refs/heads/archive"
  # The same refusal outside refs/heads/archive/, and under another
  # repository's archive folder.
  for label in outside other-repo rename-outside rename-other-repo; do
    case $label in
      outside) msg=$(refusal_message "fm/$TASK-other" "$COMMON") ;;
      other-repo) msg=$(refusal_message "$REFUSED" "$other/.git") ;;
      rename-outside) msg=$(rename_message "fm/$TASK-other" "$COMMON") ;;
      rename-other-repo) msg=$(rename_message "$REFUSED" "$other/.git") ;;
    esac
    FAKE_GIT_MSG=$msg FAKE_GIT_STATUS=128 run_git "$label-plain" "$FAKEBIN" seatbelt-v1 branch x
    FAKE_GIT_MSG=$msg FAKE_GIT_STATUS=128 run_git "$label-wrapped" "$WRAP_DIR:$FAKEBIN" seatbelt-v1 branch x
    assert_same_run "$label-plain" "$label-wrapped" 0 "a refusal that is not this task's archive ($label)"
  done
  # A trace file a stopped wrapper left at a reused pid adds nothing to a later
  # unrelated failure; exec keeps the pid the wrapper names its file from.
  msg=$(refusal_message "$REFUSED" "$COMMON")
  # shellcheck disable=SC2016 # The inner shell expands its own arguments.
  FAKE_GIT_STATUS=1 PATH="$WRAP_DIR:$FAKEBIN:$PATH" FM_WRITE_CONFINEMENT=seatbelt-v1 TMPDIR="$TMP_ROOT/tmp" \
    /bin/bash -c 'printf "{\"event\":\"error\",\"msg\":\"%s\",\"fmt\":\"%%s\"}\n" "$1" >"$TMPDIR/fm-confined-git.$$"; exec git status' \
    stale "$msg" >"$TMP_ROOT/stale.out" 2>"$TMP_ROOT/stale.err"
  expect_code 1 "$?" "the stale-trace call changed git's exit status"
  [ ! -s "$TMP_ROOT/stale.err" ] || fail "a stale trace file produced a line: $(cat "$TMP_ROOT/stale.err")"
  [ -z "$(ls "$TMP_ROOT/tmp")" ] || fail "the wrapper left a trace file behind: $(ls "$TMP_ROOT/tmp")"
  # Real Git refusing an archive name for another reason.
  git -C "$WT" branch "$REFUSED" HEAD || fail "could not create the existing-name fixture"
  run_git exists-plain /nonexistent seatbelt-v1 -C "$WT" branch "$REFUSED" HEAD
  run_git exists-wrapped "$WRAP_DIR" seatbelt-v1 -C "$WT" branch "$REFUSED" HEAD
  git -C "$WT" branch -q -D "$REFUSED"
  assert_not_equals 0 "$(cat "$TMP_ROOT/exists-plain.status")" "the existing-name fixture did not fail"
  assert_same_run exists-plain exists-wrapped 0 "real git refusing an existing archive name"
  pass "refusals outside this task's refs/heads/archive/ and other failures get no extra line"
}

test_unconfined_or_already_traced_git_passes_through() {
  local trace="$TMP_ROOT/caller-trace.jsonl"
  # Without the confined launch's mark, the wrapper only execs git.
  FAKE_GIT_LOG="$TMP_ROOT/unconfined.log" FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$COMMON") FAKE_GIT_STATUS=128 \
    run_git unconfined-plain "$FAKEBIN" '' branch "$REFUSED"
  FAKE_GIT_LOG="$TMP_ROOT/unconfined.log" FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$COMMON") FAKE_GIT_STATUS=128 \
    run_git unconfined-wrapped "$WRAP_DIR:$FAKEBIN" '' branch "$REFUSED"
  assert_same_run unconfined-plain unconfined-wrapped 0 "an unconfined call"
  assert_grep 'trace2=' "$TMP_ROOT/unconfined.log" "an unconfined call did not reach git"
  assert_no_grep 'trace2=set' "$TMP_ROOT/unconfined.log" "an unconfined call was traced"
  # A caller's own trace2 target stays the caller's.
  : >"$trace"
  GIT_TRACE2_EVENT=$trace FAKE_GIT_MSG=$(refusal_message "$REFUSED" "$COMMON") FAKE_GIT_STATUS=128 \
    run_git traced-wrapped "$WRAP_DIR:$FAKEBIN" seatbelt-v1 branch "$REFUSED"
  assert_equals 1 "$(($(wc -l <"$TMP_ROOT/traced-wrapped.err")))" "a caller-traced call gained a line"
  assert_grep '"event":"error"' "$trace" "the caller's trace2 target lost git's event"
  pass "an unconfined or already-traced call passes through to git unchanged"
}

test_arguments_stdin_and_status_pass_through() {
  local status
  for status in 0 1 3 128 141; do
    FAKE_GIT_LOG="$TMP_ROOT/args-plain.log" FAKE_GIT_READ_STDIN=1 FAKE_GIT_STATUS=$status FAKE_GIT_STDOUT='out *' \
      PATH="$FAKEBIN:$PATH" FM_WRITE_CONFINEMENT=seatbelt-v1 TMPDIR="$TMP_ROOT/tmp" \
      git 'a b' '' '*' $'line\nbreak' -- >"$TMP_ROOT/args-plain.out" 2>"$TMP_ROOT/args-plain.err" <<<'payload'
    echo "$?" >"$TMP_ROOT/args-plain.status"
    FAKE_GIT_LOG="$TMP_ROOT/args-wrapped.log" FAKE_GIT_READ_STDIN=1 FAKE_GIT_STATUS=$status FAKE_GIT_STDOUT='out *' \
      PATH="$WRAP_DIR:$FAKEBIN:$PATH" FM_WRITE_CONFINEMENT=seatbelt-v1 TMPDIR="$TMP_ROOT/tmp" \
      git 'a b' '' '*' $'line\nbreak' -- >"$TMP_ROOT/args-wrapped.out" 2>"$TMP_ROOT/args-wrapped.err" <<<'payload'
    echo "$?" >"$TMP_ROOT/args-wrapped.status"
    assert_same_run args-plain args-wrapped 0 "exit status $status"
    # The trace2 target is the one thing the wrapper adds to git's environment.
    assert_equals "$(grep -v '^trace2=' "$TMP_ROOT/args-plain.log")" "$(grep -v '^trace2=' "$TMP_ROOT/args-wrapped.log")" \
      "the wrapper changed git's arguments or standard input"
    assert_grep 'stdin=[payload]' "$TMP_ROOT/args-wrapped.log" "standard input did not reach git"
  done
  pass "arguments, standard input, standard output and exit status reach the caller unchanged"
}

test_real_git_resolution_never_reaches_a_wrapper() {
  local linkdir="$TMP_ROOT/linkdir" copydir="$TMP_ROOT/copydir" lead
  mkdir -p "$linkdir" "$copydir"
  ln -s "$WRAP_DIR/git" "$linkdir/git"
  cp "$WRAP_DIR/git" "$copydir/git"
  # The wrapper listed twice, a symbolic link to it and a separate copy of it
  # ahead of the real git each resolve to the real git, never to a wrapper.
  for lead in "$WRAP_DIR:$WRAP_DIR:$FAKEBIN" "$linkdir:$WRAP_DIR:$FAKEBIN" "$copydir:$WRAP_DIR:$FAKEBIN" "$WRAP_DIR:$copydir:$FAKEBIN"; do
    rm -f "$TMP_ROOT/resolved.log"
    FAKE_GIT_LOG="$TMP_ROOT/resolved.log" FAKE_GIT_STATUS=7 run_git resolved "$lead" seatbelt-v1 status
    expect_code 7 "$(cat "$TMP_ROOT/resolved.status")" "PATH $lead did not reach the real git"
    assert_grep 'arg=[status]' "$TMP_ROOT/resolved.log" "PATH $lead did not run the real git"
  done
  PATH="$WRAP_DIR" FM_WRITE_CONFINEMENT=seatbelt-v1 /bin/bash -c 'git status' >"$TMP_ROOT/none.out" 2>"$TMP_ROOT/none.err"
  expect_code 127 "$?" "a PATH with no real git must report git as not found"
  assert_equals 'git: command not found' "$(cat "$TMP_ROOT/none.err")" "a missing real git was not reported"
  pass "the wrapper resolves the real git past itself, its links and its copies, and never recurses"
}

test_install_refuses_unsafe_folders_and_reinstalls() {
  local out
  out=$("$WRAPPER" install "$TMP_ROOT/bad-id.git-path" 'bad id' "$WT" 2>&1) && fail "install accepted an invalid task id"
  assert_absent "$TMP_ROOT/bad-id.git-path" "an invalid task id installed a wrapper"
  out=$("$WRAPPER" install relative.git-path "$TASK" "$WT" 2>&1) && fail "install accepted a relative folder"
  mkdir -p "$TMP_ROOT/elsewhere"
  ln -s "$TMP_ROOT/elsewhere" "$TMP_ROOT/link.git-path"
  out=$("$WRAPPER" install "$TMP_ROOT/link.git-path" "$TASK" "$WT" 2>&1) && fail "install wrote through a symbolic link"
  assert_absent "$TMP_ROOT/elsewhere/git" "install wrote a wrapper through a symbolic link"
  "$WRAPPER" install "$WRAP_DIR" "$TASK" "$WT" || fail "a relaunch could not reinstall over its own wrapper: $out"
  cmp -s "$WRAPPER" "$WRAP_DIR/git" || fail "the installed wrapper is not a copy of the tracked script"
  assert_equals "$TASK"$'\n'"$(cd -P "$COMMON" && pwd -P)" "$(cat "$WRAP_DIR/config")" "the config does not name the task and its shared Git directory"
  out=$("$WRAPPER" 2>&1)
  expect_code 2 "$?" "a bare call must print usage"
  pass "install refuses an invalid id, a relative folder and a symbolic link, and reinstalls in place"
}

# fixture_home <base>: a Firstmate home around the task worktree, as
# bin/fm-spawn.sh hands it to the profile builder.
fixture_home() {
  local base=$1
  mkdir -p "$base/state" "$base/config" "$base/projects" "$base/data/$TASK" "$base/claude" "$TMP_ROOT/nm"
  printf 'window=fmtest:fm-%s\nworktree=%s\n' "$TASK" "$WT" >"$base/state/$TASK.meta"
}

build_profile() {  # <home> <profile>
  NM_HOME="$TMP_ROOT/nm" python3 "$ROOT/bin/fm-write-confinement.py" --worktree "$WT" --home "$1" \
    --config "$1/config" --projects "$1/projects" --data "$1/data/$TASK" --state "$1/state" --task "$TASK" \
    --branch "fm/$TASK" --harness claude --agent-dir "$1/claude" \
    --claude-session 11111111-2222-4333-8444-555555555555 --profile "$2"
}

# stable_profile <profile>: the profile without its one line per folder in the
# shared Claude temp root, which other sessions on this host create and remove
# between two builds; every other line comes from the fixture alone.
stable_profile() {
  local claude_tmp
  claude_tmp="$(cd -P /tmp && pwd -P)/claude-$(id -u)"
  grep -v -F "(deny file-write* (literal \"$claude_tmp/" "$1" || true
}

test_installing_the_wrapper_changes_no_profile_byte() {
  local home="$TMP_ROOT/profile-home"
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: test_installing_the_wrapper_changes_no_profile_byte: the write profile is built only for macOS launches\n'
    return 0
  fi
  fixture_home "$home"
  build_profile "$home" "$TMP_ROOT/before.sb" || fail "the profile builder refused the fixture"
  "$WRAPPER" install "$home/state/$TASK.git-path" "$TASK" "$WT" || fail "install refused the fixture home"
  build_profile "$home" "$TMP_ROOT/after.sb" || fail "the profile builder refused the fixture with the wrapper installed"
  stable_profile "$TMP_ROOT/before.sb" >"$TMP_ROOT/before.stable"
  stable_profile "$TMP_ROOT/after.sb" >"$TMP_ROOT/after.stable"
  [ "$(($(wc -l <"$TMP_ROOT/before.stable")))" -gt 20 ] || fail "the fixture profile is too short to compare: $(cat "$TMP_ROOT/before.sb")"
  cmp -s "$TMP_ROOT/before.stable" "$TMP_ROOT/after.stable" \
    || fail "installing the wrapper changed the write profile: $(diff "$TMP_ROOT/before.stable" "$TMP_ROOT/after.stable")"
  pass "the write profile is byte-identical with and without the wrapper installed"
}

# sandbox_git <label> <path-lead> <git argument...>: one real git run inside
# the production profile, with the confined launch's environment.
sandbox_git() {
  local label=$1 lead=$2
  shift 2
  PATH="$lead:$PATH" FM_WRITE_CONFINEMENT=seatbelt-v1 TMPDIR="$TMP_ROOT/tmp" \
    /usr/bin/sandbox-exec -f "$TMP_ROOT/sandbox.sb" git -C "$WT" "$@" \
    >"$TMP_ROOT/$label.out" 2>"$TMP_ROOT/$label.err" </dev/null
  echo "$?" >"$TMP_ROOT/$label.status"
}

test_real_sandbox_refusal_names_the_shapes_the_profile_accepts() {
  local home="$TMP_ROOT/sandbox-home" wrap line name shape
  if [ "$(uname -s)" != Darwin ] || ! /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
    printf 'skip: test_real_sandbox_refusal_names_the_shapes_the_profile_accepts: sandbox-exec cannot apply a profile here (not macOS, or this process is already confined); the fake-git cases above cover the wrapper\n'
    return 0
  fi
  fixture_home "$home"
  wrap="$home/state/$TASK.git-path"
  "$WRAPPER" install "$wrap" "$TASK" "$WT" || fail "install refused the fixture home"
  build_profile "$home" "$TMP_ROOT/sandbox.sb" || fail "the profile builder refused the fixture"
  sandbox_git sandbox-refused-plain /nonexistent branch "$REFUSED" HEAD
  sandbox_git sandbox-refused-wrapped "$wrap" branch "$REFUSED" HEAD
  assert_contains "$(cat "$TMP_ROOT/sandbox-refused-plain.err")" 'Operation not permitted' "the profile did not refuse $REFUSED"
  assert_same_run sandbox-refused-plain sandbox-refused-wrapped 1 "a confined refusal of $REFUSED"
  assert_names_shapes sandbox-refused-wrapped "$REFUSED"
  # A rename into the name, refused at its reflog move.
  sandbox_git sandbox-rename-plain /nonexistent branch -m "fm/$TASK" "$REFUSED"
  sandbox_git sandbox-rename-wrapped "$wrap" branch -m "fm/$TASK" "$REFUSED"
  assert_contains "$(cat "$TMP_ROOT/sandbox-rename-plain.err")" "logs/refs/heads/$REFUSED: Operation not permitted" "the profile did not refuse a rename into $REFUSED"
  assert_same_run sandbox-rename-plain sandbox-rename-wrapped 1 "a confined rename into $REFUSED"
  assert_names_shapes sandbox-rename-wrapped "$REFUSED"
  git -C "$WT" rev-parse -q --verify "refs/heads/fm/$TASK" >/dev/null || fail "the refused rename lost fm/$TASK"
  # A delete of the name, made outside the sandbox.
  git -C "$WT" branch "$REFUSED" HEAD || fail "could not create the delete fixture"
  sandbox_git sandbox-delete-plain /nonexistent branch -D "$REFUSED"
  sandbox_git sandbox-delete-wrapped "$wrap" branch -D "$REFUSED"
  assert_contains "$(cat "$TMP_ROOT/sandbox-delete-plain.err")" 'Operation not permitted' "the profile did not refuse deleting $REFUSED"
  assert_same_run sandbox-delete-plain sandbox-delete-wrapped 1 "a confined delete of $REFUSED"
  assert_names_shapes sandbox-delete-wrapped "$REFUSED"
  git -C "$WT" branch -q -D "$REFUSED" || fail "the refused delete removed $REFUSED"
  # Both names the line offers are names the profile accepts.
  line=$(tail -n 1 "$TMP_ROOT/sandbox-refused-wrapped.err")
  for shape in "$SUBMITTED_SHAPE" "$PIPELINE_SHAPE"; do
    case $line in *"$shape"*) ;; *) fail "the line does not offer $shape" ;; esac
    name=${shape/<8 lowercase hex>/0123abcd}
    sandbox_git sandbox-allowed "$wrap" branch "$name" HEAD
    expect_code 0 "$(cat "$TMP_ROOT/sandbox-allowed.status")" "the profile refused $name, which the line offers: $(cat "$TMP_ROOT/sandbox-allowed.err")"
    [ ! -s "$TMP_ROOT/sandbox-allowed.err" ] || fail "an allowed confined write printed stderr: $(cat "$TMP_ROOT/sandbox-allowed.err")"
    git -C "$WT" branch -q -D "$name" || fail "could not remove $name"
  done
  # A confined refusal outside refs/heads/archive/ adds nothing.
  sandbox_git sandbox-outside-plain /nonexistent branch "fm/$TASK-other" HEAD
  sandbox_git sandbox-outside-wrapped "$wrap" branch "fm/$TASK-other" HEAD
  assert_contains "$(cat "$TMP_ROOT/sandbox-outside-plain.err")" 'Operation not permitted' "the profile did not refuse fm/$TASK-other"
  assert_same_run sandbox-outside-plain sandbox-outside-wrapped 0 "a confined refusal outside refs/heads/archive/"
  git -C "$WT" rev-parse -q --verify "refs/heads/$REFUSED" >/dev/null && fail "the refused archive name was created"
  # The confined worker cannot change, add to or move the wrapper it runs.
  cp "$wrap/git" "$TMP_ROOT/wrapper-before"
  # shellcheck disable=SC2016 # The confined shell expands its own argument.
  PATH="$wrap:$PATH" /usr/bin/sandbox-exec -f "$TMP_ROOT/sandbox.sb" /bin/bash -c '
    { printf x >> "$1/git"; } 2>/dev/null && echo appended-git
    { printf x >> "$1/config"; } 2>/dev/null && echo appended-config
    { : > "$1/extra"; } 2>/dev/null && echo created-extra
    mv "$1" "$1.moved" 2>/dev/null && echo moved-folder
    true' tamper "$wrap" >"$TMP_ROOT/tamper.out" 2>&1
  [ ! -s "$TMP_ROOT/tamper.out" ] || fail "a confined process changed the wrapper folder: $(cat "$TMP_ROOT/tamper.out")"
  cmp -s "$TMP_ROOT/wrapper-before" "$wrap/git" || fail "a confined process changed the wrapper"
  pass "inside the real profile a refused create, rename into or delete of an archive name gets the line, both names it offers are accepted, and the wrapper cannot be changed"
}

fm_test_run_cases \
  test_refused_archive_name_gets_one_line_naming_it_and_both_shapes \
  test_successful_writes_get_no_line \
  test_refusals_outside_the_task_archive_get_no_line \
  test_unconfined_or_already_traced_git_passes_through \
  test_arguments_stdin_and_status_pass_through \
  test_real_git_resolution_never_reaches_a_wrapper \
  test_install_refuses_unsafe_folders_and_reinstalls \
  test_installing_the_wrapper_changes_no_profile_byte \
  test_real_sandbox_refusal_names_the_shapes_the_profile_accepts \
  -- "$@"
echo "# all fm-confined-git tests passed"
