#!/usr/bin/env bash
# Behavior tests for the task Git hook carrier bin/fm-spawn.sh selects at launch
# (its header owns the contract; bin/fm-git-strip-ai-trailers.sh owns the hook
# scripts and their rows).
#
# Every case runs the real launch text bin/fm-spawn.sh stages for the pane,
# replayed in a fresh pane shell (sh, bash, zsh and ksh where installed), so the
# selector runs in the persistent pane shell and again inside the filtered
# launch shell after env -i, exactly as in a fleet pane. The fake harness is a
# worker stand-in that drives git in the task worktree. Every verdict is read
# from an effect independent of the hooks' own status: the commit HEAD names,
# the bare remote's refs, the commit body, the repository hook log, the bytes
# the repository's pre-push received, and git's own GIT_TRACE of which hook
# commands it ran.
#
# Sensitivity controls change one decisive fact inside the fixture only: a row
# dropped from the worker's own GIT_CONFIG_PARAMETERS, a fixture git on the pane
# PATH that hides the rows from every command except the probe, and the legacy
# carrier's known gaps. No production bypass exists or is used.
set -u

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS FM_GIT_HOOK_ROWS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/git-config-env-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/git-config-env-helpers.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-git-hook-carrier)
# Every spawn here leaves its task temp root and launch directory in /tmp.
carrier_cleanup() {
  rm -rf /tmp/fm-carrier-*-"$$" /tmp/fm-carrier-*-"$$"+* 2>/dev/null || :
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || :
  fm_test_cleanup
}
trap carrier_cleanup EXIT
export FM_GUARD_EVENT_LOG="$TMP_ROOT/guard-events.jsonl"
fm_git_identity 'Carrier Tests' 'carrier@example.invalid'

REAL_GIT=$(command -v git) || fail "git is required"

# Config-based hooks arrived in git 2.54. On an older git every config-carrier
# case is skipped by name and only the fallback and refusal cases run; in CI,
# whose runner images ship a newer git, that is a failure instead of a skip.
CONFIG_GIT=1
mkdir -p "$TMP_ROOT/probe"
"$REAL_GIT" init -q "$TMP_ROOT/probe/r"
if ! (cd "$TMP_ROOT/probe/r" && GIT_CONFIG_PARAMETERS="'hook.p.event'='commit-msg' 'hook.p.command'='true'" \
  "$REAL_GIT" hook list commit-msg 2>/dev/null | grep -qx p); then
  CONFIG_GIT=0
  [ "${CI:-}" != true ] ||
    fail "$("$REAL_GIT" --version) has no config-based hooks; CI must provide git 2.54 or newer so the config carrier cases run"
  printf 'skip: %s has no config-based hooks; config carrier cases not exercised\n' "$("$REAL_GIT" --version)"
fi

cred_shape() { printf 'AKIA%s' ZZZZZZZZZZZZZZZZ; }

# The worker stand-in. It reads its plan from <case>/plan (one word: full or
# short) and its run name from <case>/run, writes key=value observations to
# <case>/obs/<run>/result, and leaves the task worktree as it found it.
write_worker() {  # <path> <case-dir> <version-line>
  local path=$1 dir=$2 version=$3
  cat > "$path" <<SH
#!/bin/sh
case "\${1-}" in --version) printf '%s\n' '$version'; exit 0 ;; esac
dir='$dir'
SH
  cat >> "$path" <<'SH'
run=$(cat "$dir/run")
plan=$(cat "$dir/plan")
obs="$dir/obs/$run"
mkdir -p "$obs"
export FM_GUARD_EVENT_LOG="$obs/guard-events.jsonl" REPO_HOOK_LOG="$obs/repo-hooks.log"
# The launch keeps no identity across env -i; the worker brings its own.
export GIT_AUTHOR_NAME=worker GIT_AUTHOR_EMAIL=worker@example.invalid GIT_COMMITTER_NAME=worker GIT_COMMITTER_EMAIL=worker@example.invalid
: > "$REPO_HOOK_LOG"
cd "$(cat "$dir/wt-path")" || exit 9
origin=$(cat "$dir/origin-path")
cred=$(printf 'AKIA%s' ZZZZZZZZZZZZZZZZ)
# Work on the task's declared branch, the only branch write confinement admits.
branch=$(cat "$dir/branch")
git checkout -q "$branch" 2>/dev/null || git checkout -q -b "$branch" || exit 8
start=$(git rev-parse HEAD)
emit() { printf '%s=%s\n' "$1" "$2" >> "$obs/result"; }
subject() { git log -1 --format=%s; }
landed() { if [ "$(subject)" = "$1" ]; then echo landed; else echo refused; fi; }
remote_has() { if git --git-dir="$origin" rev-parse -q --verify "refs/heads/$run-$1" >/dev/null; then echo yes; else echo no; fi; }
undo() {  # <subject>: drop that commit if it landed, then clean the tree
  [ "$(subject)" != "$1" ] || git reset -q --hard HEAD~1
  git reset -q --hard HEAD; git clean -qfd
}
rows_in_gcp() { printf '%s' "${GIT_CONFIG_PARAMETERS-}" | grep -o "'hook.fm-scan-commit.event'" | wc -l | tr -d ' '; }
numbered_task_hooks() {
  n=0 i=0
  while [ "$i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
    eval "k=\${GIT_CONFIG_KEY_$i-} v=\${GIT_CONFIG_VALUE_$i-}"
    [ "$k" != core.hooksPath ] || [ "$v" != "$(cat "$dir/hooks-path")" ] || n=$((n + 1))
    i=$((i + 1))
  done
  echo "$n"
}
emit started yes
printf '%s' "${GIT_CONFIG_PARAMETERS-}" > "$obs/gcp"
emit hookspath "$(git config --show-scope --get core.hooksPath | tr '\t' ' ')"
emit gcp_rows "$(rows_in_gcp)"
emit numbered "$(numbered_task_hooks)"
emit operator_name "$(git config --get user.name)"
emit confinement "${FM_WRITE_CONFINEMENT-none}"
# N8: process inspection, which Vernant's reference-transaction guard relies on.
if ps -p $$ -o comm= >/dev/null 2>&1; then emit ps_ok yes; else emit ps_ok no; fi

# G4: a staged credential is refused at commit.
cred=$(printf 'AKIA%s' ZZZZZZZZZZZZZZZZ)
printf '%s\n' "$cred" > leak; git add leak
GIT_TRACE="$obs/trace.cred" git commit -q -m leak 2>/dev/null
emit cred_commit "$(landed leak)"; undo leak
# G4: a credential the repository's own pre-commit hook stages is refused too:
# the scan reads the final index Git commits.
printf 'h\n' > h; git add h
STAGE_FROM_HOOK=1 git commit -q -m hookstaged 2>/dev/null
emit hook_staged_commit "$(landed hookstaged)"
emit hook_staged_in_head "$(git ls-tree --name-only HEAD | grep -cx hook-staged)"
undo hookstaged
# G5: an AI trailer on an ordinary commit is removed; repo hooks run.
printf 'w\n' > w; git add w
: > "$REPO_HOOK_LOG"
GIT_TRACE="$obs/trace.clean" git commit -q -m clean -m 'Co-Authored-By: Claude <noreply@anthropic.com>' 2>/dev/null
cp "$REPO_HOOK_LOG" "$obs/repohooks.clean"
emit clean_commit "$(landed clean)"
emit clean_trailer "$(git log -1 --format=%B | grep -ci co-authored-by)"
if [ "$plan" = short ]; then
  git reset -q --hard "$start"; git clean -qfd; emit done yes; exit 0
fi
# G4: a clean push lands and the repository pre-push reads the exact records.
rm -f "$obs"/prepush-stdin.*
: > "$REPO_HOOK_LOG"
GIT_TRACE="$obs/trace.push" git push -q origin "HEAD:refs/heads/$run-clean" 2>/dev/null
cp "$REPO_HOOK_LOG" "$obs/repohooks.push"
cat "$obs"/prepush-stdin.* > "$obs/prepush.clean" 2>/dev/null
emit clean_push "$(remote_has clean)"
emit prepush_expected "HEAD $(git rev-parse HEAD) refs/heads/$run-clean 0000000000000000000000000000000000000000"
# G4: --no-verify then push is refused at push.
printf '%s\n' "$cred" > leak2; git add leak2; git commit -q --no-verify -m leak2
git push -q origin "HEAD:refs/heads/$run-credpush" 2>/dev/null
emit cred_push "$(remote_has credpush)"; undo leak2
# S4: git -c core.hooksPath=/dev/null.
printf '%s\n' "$cred" > leak3; git add leak3
git -c core.hooksPath=/dev/null commit -q -m devnull 2>/dev/null
emit devnull_commit "$(landed devnull)"; undo devnull
# G6: the inline fsmonitor triple on a commit and on a clean push.
printf '%s\n' "$cred" > leak4; git add leak4
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false git commit -q -m triple 2>/dev/null
emit triple_commit "$(landed triple)"; undo triple
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false git push -q origin "HEAD:refs/heads/$run-triple" 2>/dev/null
emit triple_push "$(remote_has triple)"
# G5/B3-b: a merge commit loses its AI trailer. The side commit is reached by
# its id, since confinement admits no second branch.
base=$(git rev-parse HEAD)
printf 's\n' > s; git add s; git commit -q --no-verify -m side; side=$(git rev-parse HEAD); git reset -q --hard "$base"
printf 'm\n' > m; git add m; git commit -q --no-verify -m mainline
GIT_TRACE="$obs/trace.merge" git merge -q --no-ff "$side" -m merge -m 'Co-Authored-By: Codex <noreply@openai.com>' 2>/dev/null
emit merge_parents "$(git log -1 --format=%p | wc -w | tr -d ' ')"
emit merge_trailer "$(git log -1 --format=%B | grep -ci co-authored-by)"
git reset -q --hard "$base"
# N1: a merge whose incoming side carries a credential-shaped line already on
# origin lands, and so does its push.
git fetch -q origin 2>/dev/null
git merge -q --no-ff origin/side-cred -m mergecred 2>/dev/null
emit n1_merge "$(landed mergecred)"
git push -q origin "HEAD:refs/heads/$run-n1" 2>/dev/null
emit n1_push "$(remote_has n1)"
git reset -q --hard "$base"
# S7: git commit -o commits only the named path from a temporary index.
printf '%s\n' "$cred" > A; printf 'ok\n' > B; git add A B
git commit -q -o -m onlyB -- B 2>/dev/null
emit only_b "$(landed onlyB)"
emit only_b_has_a "$(git ls-tree --name-only HEAD | grep -cx A)"
git commit -q -o -m onlyA -- A 2>/dev/null
emit only_a "$(landed onlyA)"
git reset -q --hard "$base"; git clean -qfd
# G9: a missing hook script, a missing python3, and an event without command.
if [ -n "${FM_GIT_HOOK_ROWS-}" ]; then
  printf 'y\n' > y; git add y
  missing=$(printf '%s' "$GIT_CONFIG_PARAMETERS" | sed 's#/fm-scan-commit#/fm-scan-commit-missing#')
  GIT_CONFIG_PARAMETERS=$missing git commit -q -m missing-script 2>/dev/null
  emit missing_script "$(landed missing-script)"; undo missing-script
  printf 'y\n' > y; git add y
  /usr/bin/env PATH="$(cat "$dir/no-python-path")" "$(command -v git)" commit -q -m no-python 2>/dev/null
  emit missing_python "$(landed no-python)"; undo no-python
  printf 'y\n' > y; git add y
  nocmd=$(printf '%s' "$GIT_CONFIG_PARAMETERS" | sed "s#'hook.fm-scan-commit.command'=#'fixture.inert'=#")
  GIT_CONFIG_PARAMETERS=$nocmd git commit -q -m no-command 2>/dev/null
  emit event_without_command "$(landed no-command)"; undo no-command
  # Sensitivity controls: drop one row's event from this command's parameters.
  printf '%s\n' "$cred" > c1; git add c1
  GIT_CONFIG_PARAMETERS=$(printf '%s' "$GIT_CONFIG_PARAMETERS" | sed "s/'hook.fm-scan-commit.event'='commit-msg'/'fixture.inert'='1'/") git commit -q -m ctl-commit 2>/dev/null
  emit ctl_commit "$(landed ctl-commit)"; undo ctl-commit
  printf 'h2\n' > h2; git add h2
  STAGE_FROM_HOOK=1 GIT_CONFIG_PARAMETERS=$(printf '%s' "$GIT_CONFIG_PARAMETERS" | sed "s/'hook.fm-scan-commit.event'='commit-msg'/'fixture.inert'='1'/") git commit -q -m ctl-hookstaged 2>/dev/null
  emit ctl_hook_staged "$(landed ctl-hookstaged)"
  emit ctl_hook_staged_in_head "$(git ls-tree --name-only HEAD | grep -cx hook-staged)"
  undo ctl-hookstaged
  printf '%s\n' "$cred" > c2; git add c2; git commit -q --no-verify -m ctl-push-commit
  GIT_CONFIG_PARAMETERS=$(printf '%s' "$GIT_CONFIG_PARAMETERS" | sed "s/'hook.fm-scan-push.event'='pre-push'/'fixture.inert'='1'/") git push -q origin "HEAD:refs/heads/$run-ctlpush" 2>/dev/null
  emit ctl_push "$(remote_has ctlpush)"; undo ctl-push-commit
  printf 's2\n' > s2; git add s2; git commit -q --no-verify -m side2; side=$(git rev-parse HEAD); git reset -q --hard "$base"
  printf 'm2\n' > m2; git add m2; git commit -q --no-verify -m mainline2
  GIT_CONFIG_PARAMETERS=$(printf '%s' "$GIT_CONFIG_PARAMETERS" | sed "s/'hook.fm-strip.event'='commit-msg'/'fixture.inert'='1'/") git merge -q --no-ff "$side" -m merge2 -m 'Co-Authored-By: Codex <noreply@openai.com>' 2>/dev/null
  emit ctl_merge_trailer "$(git log -1 --format=%B | grep -ci co-authored-by)"
  git reset -q --hard "$base"; git clean -qfd
  # S3: the off-switch spellings stay residuals of the --no-verify class.
  for sw in hook.fm-scan-commit.enabled=false hook.fm-scan-commit.command=true hook.fm-scan-commit.event=; do
    printf '%s\n' "$cred" > s3; git add s3
    git -c "$sw" commit -q -m s3 2>/dev/null
    emit "s3_${sw%%=*}" "$(landed s3)"; undo s3
  done
fi
git reset -q --hard "$start"; git clean -qfd
emit done yes
SH
  chmod +x "$path"
}

# make_case <name> <harness> [keep-trailers]: a spawn home whose project has
# logging repository hooks under core.hooksPath=.githooks, a bare origin holding
# main and side-cred (a credential-shaped line already published), and the
# staged launch text recorded at <case>/launch.
make_case() {
  local name=$1 harness=$2 keep=${3:-0} dir home proj wt fakebin id out status hook
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  id="carrier-$name-$$"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_test_spawn_brief "$home" "$id"
  [ "$keep" = 0 ] || : > "$home/config/keep-ai-trailers"
  [ -z "${CASE_ALLOWLIST:-}" ] || printf '%s\n' "${CASE_ALLOWLIST// /$'\n'}" > "$home/config/launch-env-allowlist"
  fm_git_init_commit "$proj"
  mkdir -p "$proj/.githooks"
  # shellcheck disable=SC2016 # The repository hooks expand these themselves.
  for hook in pre-commit commit-msg pre-push reference-transaction; do
    {
      printf '#!/bin/sh\n'
      case "$hook" in
        # A generator hook: when asked, it writes and stages a file itself.
        pre-commit) printf 'if [ -n "${STAGE_FROM_HOOK-}" ]; then printf "AKIA%%s\\n" ZZZZZZZZZZZZZZZZ > hook-staged; git add hook-staged; fi\n' ;;
        pre-push) printf 'cat > "$(dirname "$REPO_HOOK_LOG")/prepush-stdin.$$"\n' ;;
        reference-transaction) printf 'cat >/dev/null\n' ;;
      esac
      printf 'echo repo:%s >> "${REPO_HOOK_LOG:-/dev/null}"\n' "$hook"
    } > "$proj/.githooks/$hook"
    chmod +x "$proj/.githooks/$hook"
  done
  git -C "$proj" add .githooks
  git -C "$proj" commit -q -m hooks
  git -C "$proj" config core.hooksPath .githooks
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" checkout -q -b side-cred
  cred_shape > "$proj/published.txt"
  git -C "$proj" add published.txt
  git -C "$proj" -c core.hooksPath=/dev/null commit -q -m published
  git -C "$proj" -c core.hooksPath=/dev/null push -q origin side-cred
  git -C "$proj" checkout -q main
  git -C "$proj" worktree add --quiet -b "wt-$name" "$wt"
  case "$harness" in
    omp) write_worker "$fakebin/$harness" "$dir" omp/18.1.20 ;;
    *) write_worker "$fakebin/$harness" "$dir" '2.1.300 (Claude Code)' ;;
  esac
  printf '%s' "$wt" > "$dir/wt-path"
  printf '%s' "$proj.origin.git" > "$dir/origin-path"
  printf '%s' "$home/state/$id.git-hooks" > "$dir/hooks-path"
  printf 'full' > "$dir/plan"
  fm_test_base_path_sans "$PATH" python3 > "$dir/no-python-path" || fail "cannot build a python3-free PATH"
  printf '%s' "$fakebin" > "$dir/fakebin"
  printf '%s' "$id" > "$dir/id"
  : > "$dir/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$dir/launch.log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode no-mistakes --yolo off --harness "$harness")
  status=$?
  expect_code 0 "$status" "$name spawn failed: $out"
  cp "$dir/launch.log" "$dir/launch"
  [ -s "$dir/launch" ] || fail "$name spawn staged no launch text"
  fm_meta_get "$home/state/$id.meta" branch > "$dir/branch"
  [ -s "$dir/branch" ] || fail "$name spawn recorded no task branch"
  printf '%s\n' "$dir"
}

# replay <case-dir> <run> <shell> <pane-path> [extra env assignments...]: run
# the staged launch text in a fresh pane shell from the task worktree. Prints
# the launch's stderr; the result is read from <case>/obs/<run>/result.
replay() {
  local dir=$1 run=$2 shell=$3 pane_path=$4
  shift 4
  printf '%s' "$run" > "$dir/run"
  rm -rf "${dir:?}/obs/$run"
  (cd "$(cat "$dir/wt-path")" && env -i HOME="$dir/home/user-home" PATH="$pane_path" TERM=xterm \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME" GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL" \
    GIT_COMMITTER_NAME="$GIT_COMMITTER_NAME" GIT_COMMITTER_EMAIL="$GIT_COMMITTER_EMAIL" "$@" \
    "$shell" -c "$(cat "$dir/launch")" 3>&1 1>/dev/null 2>&3)
}

obs() {  # <case-dir> <run> <key>
  sed -n "s/^$3=//p" "$1/obs/$2/result" 2>/dev/null | tail -n 1
}

trace_has() {  # <case-dir> <run> <trace> <needle>
  grep -F "run_command:" "$1/obs/$2/trace.$3" 2>/dev/null | grep -qF "$4"
}

# A pane PATH: the fake harness first, then the test's own tools.
pane_path() {
  printf '%s:%s' "$(cat "$1/fakebin")" "$PATH"
}

# A git that ignores GIT_CONFIG_PARAMETERS entirely, standing in for a git that
# predates config-based hooks.
OLD_GIT_DIR="$TMP_ROOT/oldgit"
mkdir -p "$OLD_GIT_DIR"
printf '#!/bin/sh\nunset GIT_CONFIG_PARAMETERS\nexec %s "$@"\n' "$REAL_GIT" > "$OLD_GIT_DIR/git"
chmod +x "$OLD_GIT_DIR/git"
# A git that answers the selector's probe truthfully but hides the rows from
# every other command: the probe-fault sensitivity control.
FOOLED_GIT_DIR="$TMP_ROOT/fooledgit"
mkdir -p "$FOOLED_GIT_DIR"
cat > "$FOOLED_GIT_DIR/git" <<SH
#!/bin/sh
if [ "\${1-}" = hook ] && [ "\${2-}" = list ]; then exec '$REAL_GIT' "\$@"; fi
unset GIT_CONFIG_PARAMETERS
exec '$REAL_GIT' "\$@"
SH
chmod +x "$FOOLED_GIT_DIR/git"

assert_full_protection() {  # <case-dir> <run> <carrier>
  local dir=$1 run=$2 carrier=$3 expected stdin
  assert_equals yes "$(obs "$dir" "$run" "done")" "$run: worker did not finish"
  # The innermost selector, inside the filtered (and on macOS confined) shell,
  # must record its verdict, or every real spawn waits out the verdict bound.
  assert_equals "$carrier" "$(cat /tmp/fm-"$(cat "$dir/id")"/git-hooks-admitted.* 2>/dev/null)" \
    "$run: the launch did not record that it admitted the worker on the $carrier carrier"
  assert_equals refused "$(obs "$dir" "$run" cred_commit)" "$run: credential commit landed"
  assert_equals refused "$(obs "$dir" "$run" hook_staged_commit)" "$run: a credential staged by the repository's pre-commit hook landed"
  assert_equals landed "$(obs "$dir" "$run" clean_commit)" "$run: clean commit was refused"
  assert_equals 0 "$(obs "$dir" "$run" clean_trailer)" "$run: AI trailer reached the commit object"
  assert_equals yes "$(obs "$dir" "$run" clean_push)" "$run: clean push did not land"
  assert_equals no "$(obs "$dir" "$run" cred_push)" "$run: --no-verify credential push landed"
  assert_equals 2 "$(obs "$dir" "$run" merge_parents)" "$run: merge commit was not created"
  assert_equals 0 "$(obs "$dir" "$run" merge_trailer)" "$run: AI trailer reached a merge commit"
  assert_equals landed "$(obs "$dir" "$run" n1_merge)" "$run: a merge of already-published content was refused"
  assert_equals yes "$(obs "$dir" "$run" n1_push)" "$run: the push of that merge was refused"
  assert_equals refused "$(obs "$dir" "$run" only_a)" "$run: commit -o of the credential path landed"
  assert_equals landed "$(obs "$dir" "$run" only_b)" "$run: commit -o of a clean path was refused"
  assert_equals 0 "$(obs "$dir" "$run" only_b_has_a)" "$run: commit -o took the unnamed staged path"
  expected=$(obs "$dir" "$run" prepush_expected)
  stdin=$(cat "$dir/obs/$run/prepush.clean" 2>/dev/null)
  assert_equals "$expected" "$stdin" "$run: repository pre-push did not receive the exact ref-update records"
  # The repository hooks' own log: under the legacy carrier the wrapper execs
  # them, so git's trace names only the wrapper.
  grep -qx repo:pre-commit "$dir/obs/$run/repohooks.clean" || fail "$run: repository pre-commit did not run"
  grep -qx repo:commit-msg "$dir/obs/$run/repohooks.clean" || fail "$run: repository commit-msg did not run"
  grep -qx repo:pre-push "$dir/obs/$run/repohooks.push" || fail "$run: repository pre-push did not run"
  case "$carrier" in
    config)
      assert_equals "local .githooks" "$(obs "$dir" "$run" hookspath)" "$run: config carrier changed core.hooksPath"
      assert_equals 1 "$(obs "$dir" "$run" gcp_rows)" "$run: config carrier did not carry exactly one row set"
      assert_equals 0 "$(obs "$dir" "$run" numbered)" "$run: config carrier also kept the legacy carrier"
      trace_has "$dir" "$run" clean fm-scan-commit || fail "$run: fm-scan-commit did not run at commit"
      trace_has "$dir" "$run" clean fm-strip || fail "$run: fm-strip did not run at commit"
      trace_has "$dir" "$run" push fm-scan-push || fail "$run: fm-scan-push did not run at push"
      trace_has "$dir" "$run" merge fm-scan-commit || fail "$run: the scan did not run on a merge commit"
      grep -qx repo:reference-transaction "$dir/obs/$run/repohooks.clean" || fail "$run: repository reference-transaction did not run"
      assert_equals refused "$(obs "$dir" "$run" devnull_commit)" "$run: -c core.hooksPath=/dev/null skipped the fm scan"
      assert_equals refused "$(obs "$dir" "$run" triple_commit)" "$run: the inline fsmonitor triple displaced the fm scan"
      assert_equals yes "$(obs "$dir" "$run" triple_push)" "$run: a clean push with the triple was refused"
      assert_equals refused "$(obs "$dir" "$run" missing_script)" "$run: a missing hook script let a commit land"
      assert_equals refused "$(obs "$dir" "$run" missing_python)" "$run: a missing python3 let a commit land"
      assert_equals refused "$(obs "$dir" "$run" event_without_command)" "$run: an event row without command let a commit land"
      # Sensitivity controls: each dropped row lets its harmful case through.
      assert_equals landed "$(obs "$dir" "$run" ctl_commit)" "$run: control without the scan-commit event was still refused"
      assert_equals landed "$(obs "$dir" "$run" ctl_hook_staged)" "$run: control without the scan-commit event still refused the hook-staged credential"
      assert_equals 1 "$(obs "$dir" "$run" ctl_hook_staged_in_head)" "$run: control commit landed without the hook-staged file, so the hook-staged case proves nothing"
      assert_equals yes "$(obs "$dir" "$run" ctl_push)" "$run: control without the scan-push event was still refused"
      assert_equals 1 "$(obs "$dir" "$run" ctl_merge_trailer)" "$run: control without the strip event still stripped"
      # S3 residuals, recorded so a change in them is noticed.
      assert_equals landed "$(obs "$dir" "$run" s3_hook.fm-scan-commit.enabled)" "$run: S3 enabled=false spelling changed"
      assert_equals landed "$(obs "$dir" "$run" s3_hook.fm-scan-commit.command)" "$run: S3 command=true spelling changed"
      assert_equals landed "$(obs "$dir" "$run" s3_hook.fm-scan-commit.event)" "$run: S3 event= spelling changed"
      ;;
    legacy)
      assert_equals "command $(cat "$dir/hooks-path")" "$(obs "$dir" "$run" hookspath)" "$run: legacy carrier is not the task hooks dir"
      assert_equals 0 "$(obs "$dir" "$run" gcp_rows)" "$run: legacy carrier also carried config rows"
      assert_equals 1 "$(obs "$dir" "$run" numbered)" "$run: legacy carrier did not carry exactly one task entry"
      # The legacy carrier's known gaps, which the config carrier closes: they
      # are the sensitivity controls for G3, G6 and S4.
      ! grep -qx repo:reference-transaction "$dir/obs/$run/repohooks.clean" || fail "$run: reference-transaction ran under the legacy carrier"
      trace_has "$dir" "$run" clean "$(cat "$dir/hooks-path")/pre-commit" || fail "$run: the legacy pre-commit wrapper did not run"
      assert_equals landed "$(obs "$dir" "$run" devnull_commit)" "$run: legacy -c core.hooksPath=/dev/null no longer lands (S4 baseline changed)"
      assert_equals landed "$(obs "$dir" "$run" triple_commit)" "$run: legacy numbered slot was not displaced by the triple (G6 baseline changed)"
      ;;
  esac
}

test_listed_harness_runs_the_config_carrier() {
  local dir shell err
  [ "$CONFIG_GIT" = 1 ] || { printf 'skip: config carrier on a listed harness\n'; return; }
  dir=$(make_case cfg claude) || exit 1
  err=$(replay "$dir" cfg-bash /bin/bash "$(pane_path "$dir")")
  assert_full_protection "$dir" cfg-bash config
  # The fleet runs Claude workers under write confinement on macOS; the case
  # must have run there. Whether ps works inside is recorded, not asserted: a
  # sandboxed process cannot exec the setuid /bin/ps on macOS, so a repository
  # hook that classifies its caller through ps sees no caller there.
  if [ "$(uname -s)" = Darwin ]; then
    assert_equals seatbelt-v1 "$(obs "$dir" cfg-bash confinement)" "the Claude case did not run under write confinement"
  fi
  printf 'note: ps inside the worker: %s (confinement %s)\n' "$(obs "$dir" cfg-bash ps_ok)" "$(obs "$dir" cfg-bash confinement)"
  for shell in /bin/sh /bin/zsh "$(command -v ksh 2>/dev/null)"; do
    [ -n "$shell" ] && [ -x "$shell" ] || continue
    printf 'short' > "$dir/plan"
    err=$(replay "$dir" "cfg-${shell##*/}" "$shell" "$(pane_path "$dir")")
    assert_equals yes "$(obs "$dir" "cfg-${shell##*/}" "done")" "$shell: worker did not finish: $err"
    assert_equals refused "$(obs "$dir" "cfg-${shell##*/}" cred_commit)" "$shell: credential commit landed"
    assert_equals 0 "$(obs "$dir" "cfg-${shell##*/}" clean_trailer)" "$shell: AI trailer landed"
    assert_equals "local .githooks" "$(obs "$dir" "cfg-${shell##*/}" hookspath)" "$shell: not on the config carrier"
  done
  printf 'full' > "$dir/plan"
  pass "a listed harness runs the config carrier from sh, bash, zsh and ksh panes with every frozen G3-G6, G9 case and control"
}

test_git_without_config_hooks_falls_back_to_legacy() {
  local dir err
  dir=$(make_case old claude) || exit 1
  err=$(replay "$dir" old /bin/bash "$OLD_GIT_DIR:$(pane_path "$dir")")
  [ -n "$(obs "$dir" old "done")" ] || fail "legacy fallback worker did not run: $err"
  assert_full_protection "$dir" old legacy
  pass "a pane git that ignores the rows gets the verified legacy carrier with every protection"
}

test_unlisted_harness_stays_on_legacy() {
  local dir err
  dir=$(make_case unl omp) || exit 1
  err=$(replay "$dir" unl /bin/bash "$(pane_path "$dir")")
  [ -n "$(obs "$dir" unl "done")" ] || fail "unlisted harness worker did not run: $err"
  assert_full_protection "$dir" unl legacy
  pass "an unlisted harness stays on the legacy carrier even when the pane git honours the rows"
}

test_probe_is_load_bearing() {
  local dir err
  [ "$CONFIG_GIT" = 1 ] || { printf 'skip: probe control needs config-based hooks\n'; return; }
  dir=$(make_case fool claude) || exit 1
  printf 'short' > "$dir/plan"
  err=$(replay "$dir" fool /bin/bash "$FOOLED_GIT_DIR:$(pane_path "$dir")")
  assert_equals yes "$(obs "$dir" fool "done")" "fooled-probe worker did not run: $err"
  assert_equals landed "$(obs "$dir" fool cred_commit)" "control: a git that hides the rows after a passing probe still refused the credential"
  assert_equals 1 "$(obs "$dir" fool clean_trailer)" "control: a git that hides the rows after a passing probe still stripped"
  pass "control: a probe that passes on a git hiding the rows lets the credential and trailer land, so the probe is load-bearing"
}

test_launch_refuses_without_a_carrier() {
  local dir shell err nogit
  dir=$(make_case refuse claude) || exit 1
  nogit=$(fm_test_base_path_sans "$(pane_path "$dir")" git) || fail "cannot build a git-free PATH"
  for shell in /bin/sh /bin/bash /bin/zsh; do
    [ -x "$shell" ] || continue
    err=$(replay "$dir" "nogit-${shell##*/}" "$shell" "$nogit")
    assert_absent "$dir/obs/nogit-${shell##*/}/result" "$shell: the worker ran with no git on the pane PATH"
    assert_contains "$err" "git does not resolve" "$shell: no-git refusal gave no reason"
  done
  err=$(replay "$dir" bad-gcp /bin/bash "$(pane_path "$dir")" GIT_CONFIG_PARAMETERS="'hook.x.event'='commit-msg")
  assert_absent "$dir/obs/bad-gcp/result" "the worker ran under a malformed GIT_CONFIG_PARAMETERS"
  assert_contains "$err" "GIT_CONFIG_PARAMETERS is malformed" "malformed parameters refusal gave no reason"
  err=$(replay "$dir" bad-count /bin/bash "$(pane_path "$dir")" GIT_CONFIG_COUNT=two)
  assert_absent "$dir/obs/bad-count/result" "the worker ran under a malformed GIT_CONFIG_COUNT"
  assert_contains "$err" "GIT_CONFIG_COUNT is not a number" "malformed count refusal gave no reason"
  printf 'short' > "$dir/plan"
  err=$(replay "$dir" ok /bin/bash "$(pane_path "$dir")")
  assert_equals yes "$(obs "$dir" ok "done")" "the same launch did not run once the pane was healthy: $err"
  pass "a pane with no git, malformed GIT_CONFIG_PARAMETERS or a malformed GIT_CONFIG_COUNT refuses the launch; a healthy pane runs it"
}

# Same persistent pane shell, three launches: config, then legacy (the pane
# git stops honouring the rows), then config again. Each leaves exactly one
# carrier, and operator parameters survive in order.
test_relaunch_keeps_exactly_one_carrier() {
  local dir launch script good
  [ "$CONFIG_GIT" = 1 ] || { printf 'skip: carrier switch needs config-based hooks\n'; return; }
  dir=$(make_case switch claude) || exit 1
  printf 'short' > "$dir/plan"
  launch=$(cat "$dir/launch")
  good=$(pane_path "$dir")
  rm -rf "$dir/obs"
  # The worker sees its run name from <case>/run; write it between launches.
  script=$(printf '%s\n' \
    "printf a1 > '$dir/run'" "$launch" \
    "printf a2 > '$dir/run'" "$launch" \
    "printf b > '$dir/run'" "PATH='$OLD_GIT_DIR':\$PATH" "$launch" \
    "printf c > '$dir/run'" "PATH='$good'" "$launch" \
    "printf '%s' \"\${GIT_CONFIG_PARAMETERS-}\" > '$dir/pane-gcp'")
  (cd "$(cat "$dir/wt-path")" && env -i HOME="$dir/home/user-home" PATH="$good" TERM=xterm \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_AUTHOR_NAME=a GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=a GIT_COMMITTER_EMAIL=a@x \
    GIT_CONFIG_PARAMETERS="'user.name'='Op Erator'" \
    /bin/bash -c "$script" >/dev/null 2>&1)
  assert_equals 1 "$(obs "$dir" a2 gcp_rows)" "relaunch accumulated or lost config rows"
  assert_equals 0 "$(obs "$dir" a2 numbered)" "config relaunch kept a legacy entry"
  assert_equals 0 "$(obs "$dir" b gcp_rows)" "switch to legacy kept config rows"
  assert_equals 1 "$(obs "$dir" b numbered)" "switch to legacy did not add exactly one task entry"
  assert_equals refused "$(obs "$dir" b cred_commit)" "legacy launch after config let a credential land"
  assert_equals 1 "$(obs "$dir" c gcp_rows)" "switch back to config did not carry exactly one row set"
  assert_equals 0 "$(obs "$dir" c numbered)" "switch back to config kept the legacy entry"
  assert_equals refused "$(obs "$dir" c cred_commit)" "config launch after legacy let a credential land"
  case "$(cat "$dir/pane-gcp")" in
    "'user.name'='Op Erator' "*) ;;
    *) fail "the persistent pane lost or reordered the operator parameter: $(cat "$dir/pane-gcp")" ;;
  esac
  [ "$(grep -o "'hook.fm-strip.event'" "$dir/pane-gcp" | wc -l | tr -d ' ')" = 1 ] ||
    fail "the persistent pane accumulated row sets: $(cat "$dir/pane-gcp")"
  pass "relaunches in one pane switch carriers both ways and always leave exactly one, keeping operator parameters first"
}

# An allowlist that keeps GIT_CONFIG_PARAMETERS brings FM_GIT_HOOK_ROWS with it,
# so the filtered launch shell replaces the rows instead of doubling them, and
# the operator's own row reaches the worker.
test_allowlisted_parameters_keep_one_row_set() {
  local dir err
  [ "$CONFIG_GIT" = 1 ] || { printf 'skip: allowlist pairing needs config-based hooks\n'; return; }
  dir=$(CASE_ALLOWLIST='GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL' make_case alw claude) || exit 1
  printf 'short' > "$dir/plan"
  err=$(replay "$dir" alw /bin/bash "$(pane_path "$dir")" GIT_CONFIG_PARAMETERS="'user.name'='Op Erator'")
  assert_equals yes "$(obs "$dir" alw "done")" "allowlisted worker did not run: $err"
  assert_equals 1 "$(obs "$dir" alw gcp_rows)" "allowlisted GIT_CONFIG_PARAMETERS doubled or lost the rows"
  assert_equals "Op Erator" "$(obs "$dir" alw operator_name)" "allowlisted operator parameter did not reach the worker"
  assert_equals refused "$(obs "$dir" alw cred_commit)" "allowlisted worker let a credential land"
  pass "an allowlisted GIT_CONFIG_PARAMETERS keeps exactly one row set and the operator's own rows"
}

test_keep_ai_trailers_keeps_the_scan() {
  local dir err
  [ "$CONFIG_GIT" = 1 ] || { printf 'skip: keep-ai-trailers config case needs config-based hooks\n'; return; }
  dir=$(make_case keep claude 1) || exit 1
  printf 'short' > "$dir/plan"
  err=$(replay "$dir" keep /bin/bash "$(pane_path "$dir")")
  assert_equals yes "$(obs "$dir" keep "done")" "keep-trailers worker did not run: $err"
  assert_equals 1 "$(obs "$dir" keep clean_trailer)" "keep-ai-trailers still stripped the trailer"
  assert_equals refused "$(obs "$dir" keep cred_commit)" "keep-ai-trailers let a credential land"
  assert_equals "local .githooks" "$(obs "$dir" keep hookspath)" "keep-ai-trailers launch is not on the config carrier"
  pass "keep-ai-trailers keeps the trailer and still refuses a credential on the config carrier"
}

# A real endpoint: the spawn itself must fail, publish no task record, and type
# nothing further, when the pane's git honours neither carrier. The harness
# stand-in records whether it ever started.
test_spawn_fails_when_the_pane_refuses() {
  if ! command -v tmux >/dev/null 2>&1; then
    [ "${CI:-}" != true ] || fail "tmux is absent; CI must provide it so the real-endpoint refusal cases run"
    printf 'skip: tmux absent; real-endpoint refusal not exercised\n'
    return
  fi
  real_endpoint_spawn refuse 100
  [ "$REAL_STATUS" -ne 0 ] || fail "spawn reported success although the pane refused the launch: $REAL_OUT"
  assert_contains "$REAL_OUT" "honours neither task Git hook carrier" "spawn did not name the refusal"
  assert_absent "$REAL_HOME/state/$REAL_ID.meta" "a refused launch published a task record"
  assert_absent "$REAL_DIR/harness-started" "the harness started although the launch was refused"
  # A refused fresh spawn leaves nothing behind: no endpoint, no hooks dir and
  # no status line for the unpublished task.
  case " $REAL_WINDOWS " in
    *" fm-$REAL_ID "*) fail "a refused fresh spawn left its endpoint open (windows: $REAL_WINDOWS)" ;;
  esac
  assert_absent "$REAL_HOME/state/$REAL_ID.git-hooks" "a refused fresh spawn left its hooks dir"
  assert_absent "$REAL_HOME/state/$REAL_ID.status" "a refused fresh spawn left a status line for an unpublished task"
  # The nearest legitimate launch: the same endpoint with an ordinary git.
  # A healthy pane's verdict ends the wait at once; the large bound only keeps
  # a slow pane on a loaded host from failing this leg for the wrong reason.
  real_endpoint_spawn admit 3000
  expect_code 0 "$REAL_STATUS" "spawn failed on a pane whose git honours the carrier: $REAL_OUT"
  assert_present "$REAL_DIR/harness-started" "the harness did not start on a healthy pane"
  case " $REAL_WINDOWS " in
    *" fm-$REAL_ID "*) ;;
    *) fail "the healthy spawn's endpoint was closed (windows: $REAL_WINDOWS), so the refusal checks above prove nothing" ;;
  esac
  assert_present "$REAL_HOME/state/$REAL_ID.git-hooks" "the healthy spawn lost its hooks dir"
  assert_not_contains "$REAL_OUT" "recorded no Git hook carrier verdict" "the healthy launch never recorded its verdict, so spawn waited out the bound"
  # Control: without the wait the same refusal is reported as a spawned worker.
  real_endpoint_spawn ctl 0
  expect_code 0 "$REAL_STATUS" "control: spawn without the verdict wait did not report success: $REAL_OUT"
  assert_absent "$REAL_DIR/harness-started" "control: the harness started although the launch was refused"
  pass "a real endpoint whose git honours neither carrier fails the spawn, names the reason, starts no harness and leaves no endpoint, hooks dir or status line; without the verdict wait it is falsely reported spawned"
}

# real_endpoint_await <command...>: poll for a launch outcome, up to five
# minutes, so a loaded host only slows the case down.
real_endpoint_await() {
  local n
  for n in $(seq 1 3000); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

refusal_recorded() {  # <task-temp-root>
  local f
  for f in "$1"/git-hooks-refused.*; do
    [ -s "$f" ] && return 0
  done
  return 1
}

# real_endpoint_spawn <refuse|admit|ctl> <verdict-polls>: one spawn into a
# private tmux server whose pane git honours neither carrier (refuse, ctl) or
# is the real git (admit). Sets REAL_DIR REAL_HOME REAL_ID REAL_OUT REAL_STATUS.
real_endpoint_spawn() {
  local mode=$1 polls=$2 real_tmux dir home proj wt fakebin socket id
  real_tmux=$(command -v tmux)
  dir="$TMP_ROOT/real-$mode"
  mkdir -p "$dir/gitbin"
  dir=$(cd "$dir" && pwd -P)
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  socket="$dir/tmux.sock"
  id="carrier-real$mode-$$"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" omp
  fm_test_spawn_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "fixture-$mode"
  cat > "$fakebin/tmux" <<SH
#!/bin/sh
exec '$real_tmux' -S '$socket' "\$@"
SH
  cat > "$fakebin/omp" <<SH
#!/bin/sh
if [ "\${1:-}" = --version ]; then printf 'omp/18.1.20\n'; exit 0; fi
: > '$dir/harness-started'
SH
  # The pane's git ignores both carriers: it drops every environment
  # configuration channel before running the real git.
  if [ "$mode" = admit ]; then
    ln -s "$REAL_GIT" "$dir/gitbin/git"
  elif [ "$mode" = relaunch ]; then
    # Healthy for the first launch; once <case>/refuse exists it ignores both
    # carriers, so the relaunch into the same pane is refused.
    printf '#!/bin/sh
if [ -e %s ]; then unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT; fi
exec %s "$@"
' "'$dir/refuse'" "$REAL_GIT" > "$dir/gitbin/git"
  elif [ "$mode" = ctl ]; then
    # The control's pane reaches its refusal slowly (the selector's final
    # core.hooksPath check), so spawn's single immediate look without the wait
    # cannot see it yet.
    printf '#!/bin/sh\n[ "$*" != "config --get core.hooksPath" ] || sleep 3\nunset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT\nexec %s "$@"\n' "$REAL_GIT" > "$dir/gitbin/git"
  else
    printf '#!/bin/sh\nunset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT\nexec %s "$@"\n' "$REAL_GIT" > "$dir/gitbin/git"
  fi
  chmod +x "$fakebin/tmux" "$fakebin/omp" "$dir/gitbin/git" 2>/dev/null || chmod +x "$fakebin/tmux" "$fakebin/omp"
  cat > "$dir/rc" <<SH
export PATH='$dir/gitbin:$fakebin:$PATH'
PS1='fixture> '
SH
  mkdir -p "$dir/launcher"
  cp /bin/bash "$dir/launcher/treehouse" || fail "cannot copy bash for the treehouse launcher"
  [ "$(uname)" != Darwin ] || codesign -f -s - "$dir/launcher/treehouse" >/dev/null 2>&1 || true
  # shellcheck disable=SC2016 # $? and $status expand in the launcher, not here.
  printf 'cd %q || exit 1\n%s\nstatus=$?\nexit "$status"\n' "$wt" "/bin/bash --noprofile --rcfile '$dir/rc' -i" > "$dir/launcher/get.sh"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = get ] || exit 0
exec -a treehouse '$dir/launcher/treehouse' '$dir/launcher/get.sh'
SH
  chmod +x "$fakebin/treehouse"
  env -i HOME="$home/user-home" PATH="$fakebin:$PATH" TERM=xterm \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
    "$real_tmux" -S "$socket" -f /dev/null new-session -d -s firstmate -c "$proj" \
    "/bin/bash --noprofile --rcfile '$dir/rc' -i" || fail "cannot start owned tmux fixture"
  "$real_tmux" -S "$socket" set-option -g default-command "/bin/bash --noprofile --rcfile '$dir/rc' -i"
  REAL_OUT=$(TMUX='' FM_GIT_HOOKS_VERDICT_POLLS=$polls fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode no-mistakes --yolo off --harness omp --backend tmux)
  REAL_STATUS=$?
  # The endpoints still open on the private server, recorded before teardown.
  REAL_WINDOWS=$("$real_tmux" -S "$socket" list-windows -a -F '#{window_name}' 2>/dev/null | tr '\n' ' ')
  # Observe only once the launch itself has finished: the harness started
  # (admit), or the pane recorded its refusal (ctl). A refused spawn has
  # already read that refusal and removed the task temp root holding it.
  case "$mode" in
    admit) real_endpoint_await test -e "$dir/harness-started" || fail "admit: the harness never started" ;;
    relaunch)
      real_endpoint_await test -e "$dir/harness-started" || fail "relaunch: the first launch never started its harness"
      rm -f "$dir/harness-started"
      : > "$dir/refuse"
      REAL_RELAUNCH_OUT=$(TMUX='' FM_GIT_HOOKS_VERDICT_POLLS=3000 fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --relaunch)
      REAL_RELAUNCH_STATUS=$?
      REAL_RELAUNCH_WINDOWS=$("$real_tmux" -S "$socket" list-windows -a -F '#{window_name}' 2>/dev/null | tr '\n' ' ')
      ;;
    ctl) real_endpoint_await refusal_recorded "/tmp/fm-$id" || fail "ctl: the pane never recorded its refusal" ;;
  esac
  "$real_tmux" -S "$socket" kill-server 2>/dev/null || :
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"*
  REAL_DIR=$dir REAL_HOME=$home REAL_ID=$id
}

# Teardown removes the task hooks directory while a process started from the
# pane may still carry the carrier. The legacy carrier's dangling hooksPath then
# runs no hooks; the config rows must do the same rather than fail every commit
# of that process, while a directory that exists but lacks a script still fails
# (G9).
test_removed_hooks_dir_runs_no_hooks() {
  local dir gcp hooks wt
  [ "$CONFIG_GIT" = 1 ] || { printf 'skip: removed hooks dir case needs config-based hooks\n'; return; }
  dir=$(make_case dangle claude) || exit 1
  printf 'short' > "$dir/plan"
  replay "$dir" dangle /bin/bash "$(pane_path "$dir")" >/dev/null
  gcp=$(cat "$dir/obs/dangle/gcp")
  [ -n "$gcp" ] || fail "the worker carried no rows to reuse"
  hooks=$(cat "$dir/hooks-path")
  wt=$(cat "$dir/wt-path")
  git -C "$wt" checkout -q "$(cat "$dir/branch")"
  cred_shape > "$wt/late"
  git -C "$wt" add late
  GIT_CONFIG_PARAMETERS=$gcp git -C "$wt" commit -q -m late-present 2>/dev/null
  assert_not_equals late-present "$(git -C "$wt" log -1 --format=%s)" "the rows did not refuse while the hooks dir existed"
  chmod -R u+w "$hooks"
  rm -rf "$hooks"
  GIT_CONFIG_PARAMETERS=$gcp git -C "$wt" commit -q -m late-removed 2>/dev/null
  assert_equals late-removed "$(git -C "$wt" log -1 --format=%s)" "rows naming a removed hooks dir failed the commit instead of running no hooks"
  git -C "$wt" reset -q --hard HEAD~1
  pass "once teardown removes the hooks dir, a process still carrying the rows runs no fm hooks, as the legacy carrier's dangling hooksPath does"
}

# A refused RELAUNCH keeps the task: its pane, its hooks dir and its record
# stay, and the refusal is written to the task's status.
test_relaunch_refusal_keeps_the_task() {
  if ! command -v tmux >/dev/null 2>&1; then
    [ "${CI:-}" != true ] || fail "tmux is absent; CI must provide it so the real-endpoint refusal cases run"
    printf 'skip: tmux absent; relaunch refusal not exercised\n'
    return
  fi
  real_endpoint_spawn relaunch 3000
  expect_code 0 "$REAL_STATUS" "the first launch of the relaunch case failed: $REAL_OUT"
  [ "$REAL_RELAUNCH_STATUS" -ne 0 ] || fail "a relaunch into a refusing pane reported success: $REAL_RELAUNCH_OUT"
  assert_contains "$REAL_RELAUNCH_OUT" "honours neither task Git hook carrier" "the relaunch refusal gave no reason"
  assert_absent "$REAL_DIR/harness-started" "the harness started although the relaunch was refused"
  case " $REAL_RELAUNCH_WINDOWS " in
    *" fm-$REAL_ID "*) ;;
    *) fail "a refused relaunch closed the task's pane (windows: $REAL_RELAUNCH_WINDOWS)" ;;
  esac
  assert_present "$REAL_HOME/state/$REAL_ID.git-hooks" "a refused relaunch removed the task's hooks dir"
  assert_present "$REAL_HOME/state/$REAL_ID.meta" "a refused relaunch removed the task record"
  assert_contains "$(cat "$REAL_HOME/state/$REAL_ID.status" 2>/dev/null)" "refused to start a worker without the task Git hooks" \
    "a refused relaunch wrote no status line"
  pass "a refused relaunch keeps the task's pane, hooks dir and record and writes the refusal to its status"
}

# herdr_refusal_spawn <name> <seam> <verdict-polls> <delay>: one fresh spawn on
# the herdr backend, through the real herdr adapter against a fake herdr CLI.
# The fake runs the staged launch as the pane shell would, in a pane whose git
# honours neither carrier and takes <delay> seconds over its final check, and
# records every call. <seam> 1 arms FM_TEST_SEAM; anything else unsets it.
# Sets HERDR_DIR HERDR_HOME HERDR_ID HERDR_OUT HERDR_STATUS.
herdr_refusal_spawn() {
  local name=$1 seam=$2 polls=$3 delay=$4 dir home proj wt fakebin id out status
  dir="$TMP_ROOT/herdr-$name"
  mkdir -p "$dir/gitbin"
  dir=$(cd "$dir" && pwd -P)
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  id="carrier-herdr$name-$$"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  printf 'off\n' > "$home/config/herdr-presentation-spaces"
  fm_git_worktree "$proj" "$wt" fixture-herdr
  wt=$(cd "$wt" && pwd -P)
  printf '%s\n' "$wt" > "$dir/cwd"
  printf '#!/bin/sh\n[ "$*" != "config --get core.hooksPath" ] || sleep %s\nunset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT\nexec %s "$@"\n' "$delay" "$REAL_GIT" > "$dir/gitbin/git"
  printf '#!/bin/sh\n: > %s\n' "'$dir/harness-started'" > "$fakebin/codex"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-calls"
case "${1:-} ${2:-}" in
  'status --json') printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n' ;;
  'session list') jq -nc --arg sock "$D/herdr.sock" '{sessions:[{name:"fm-carrier-herdr-test",running:true,default:false,socket_path:$sock}]}' ;;
  'workspace list') printf '{"result":{"workspaces":[]}}\n' ;;
  'workspace create') printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n' ;;
  'tab list') printf '{"result":{"tabs":[]}}\n' ;;
  'tab create') printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n' ;;
  'pane get')
    if [ -e "$D/closed" ]; then printf '{"error":{"code":"pane_not_found"}}\n'; exit 1; fi
    jq -nc --arg pane "${3:-}" --arg cwd "$(cat "$D/cwd")" '{result:{pane:{pane_id:$pane,foreground_cwd:$cwd}}}' ;;
  'pane close') : > "$D/closed" ;;
  'agent get') printf '{"error":{"code":"agent_not_found"}}\n' ;;
  'pane process-info') printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%%9","shell_pid":4242,"foreground_processes":[]}}}\n' ;;
  'pane send-text')
    case "${4:-}" in
      ". '"*"'")
        # The pane shell sources the staged launch from the task copy.
        launch=${4#". '"}; launch=${launch%"'"}
        # A pane runs the launch beside fm-spawn, which reads its verdict.
        { (cd "$(cat "$D/cwd")" && env -i HOME="$D/home/user-home" PATH="$D/gitbin:$(dirname "$0"):/usr/bin:/bin:/usr/sbin:/sbin" \
          TERM=xterm GIT_CONFIG_GLOBAL=/dev/null /bin/bash --noprofile --norc -c ". '$launch'") || :
          : > "$D/launch-done"; } </dev/null >/dev/null 2>&1 & ;;
    esac ;;
  *) : ;;
esac
SH
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
  '-p 4242 -o args=') printf 'bash\n' ;;
  '-p '*'-o lstart= -o command=') printf 'Mon Jan  1 00:00:00 2024 fixture-pid-%s\n' "$2" ;;
  *) exec /bin/ps "$@" ;;
esac
SH
  chmod +x "$fakebin/herdr" "$fakebin/ps" "$fakebin/codex" "$dir/gitbin/git"
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  out=$(FM_FAKE_DIR="$dir" FM_HERDR_PS_BIN="$fakebin/ps" HERDR_SESSION=fm-carrier-herdr-test \
    FM_GIT_HOOKS_VERDICT_POLLS=$polls CARRIER_SEAM=$seam \
    env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID \
    bash -c '. "$1/tests/lib.sh"; . "$1/tests/fixtures.sh"; shift
      if [ "$CARRIER_SEAM" = 1 ]; then export FM_TEST_SEAM=1; else unset FM_TEST_SEAM; fi
      fm_test_run_spawn "$@"' _ "$ROOT" \
    "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --backend herdr --harness codex)
  status=$?
  # Observe only once the pane's launch has finished.
  real_endpoint_await test -e "$dir/launch-done" || fail "herdr $name: the pane's launch never finished"
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"*
  HERDR_DIR=$dir HERDR_HOME=$home HERDR_ID=$id HERDR_OUT=$out HERDR_STATUS=$status
}

# The same fresh-refusal cleanup on the herdr backend: the close of this
# attempt's pane is observed without a live herdr.
test_herdr_fresh_refusal_closes_its_pane() {
  local dir home id out status
  herdr_refusal_spawn refuse 1 3000 0
  dir=$HERDR_DIR home=$HERDR_HOME id=$HERDR_ID out=$HERDR_OUT status=$HERDR_STATUS
  [ "$status" -ne 0 ] || fail "herdr: spawn reported success although the pane refused the launch: $out"
  assert_contains "$out" "honours neither task Git hook carrier" "herdr: spawn did not name the refusal"
  assert_absent "$dir/harness-started" "herdr: the harness started although the launch was refused"
  grep -q '^pane close %9 ' "$dir/herdr-calls" ||
    fail "herdr: a refused fresh spawn did not close its pane: $(cat "$dir/herdr-calls")"
  assert_absent "$home/state/$id.git-hooks" "herdr: a refused fresh spawn left its hooks dir"
  assert_absent "$home/state/$id.status" "herdr: a refused fresh spawn left a status line"
  assert_absent "$home/state/$id.meta" "herdr: a refused fresh spawn kept a task record"
  pass "herdr: a refused fresh spawn closes its pane through the herdr adapter and leaves no hooks dir, status line or record"
}

# FM_GIT_HOOKS_VERDICT_POLLS is a test-only seam. Without FM_TEST_SEAM, or
# with a value that is not a non-negative decimal integer, the wait keeps its
# production bound, so a pane that refuses after three seconds is still reported.
test_verdict_bound_is_a_test_only_seam() {
  local polls
  herdr_refusal_spawn seamctl 1 0 3
  expect_code 0 "$HERDR_STATUS" "control: a seam-armed zero bound still waited for the slow refusal: $HERDR_OUT"
  assert_absent "$HERDR_DIR/harness-started" "control: the harness started although the launch was refused"
  herdr_refusal_spawn noseam '' 0 3
  [ "$HERDR_STATUS" -ne 0 ] || fail "without FM_TEST_SEAM a zero bound hid the refusal: $HERDR_OUT"
  assert_contains "$HERDR_OUT" "honours neither task Git hook carrier" "without FM_TEST_SEAM the refusal was not named"
  assert_absent "$HERDR_HOME/state/$HERDR_ID.meta" "without FM_TEST_SEAM a refused launch published a task record"
  for polls in abc -1; do
    herdr_refusal_spawn "bad$polls" 1 "$polls" 3
    [ "$HERDR_STATUS" -ne 0 ] || fail "the seam value '$polls' hid the refusal: $HERDR_OUT"
    assert_contains "$HERDR_OUT" "honours neither task Git hook carrier" "the seam value '$polls' lost the refusal reason"
    assert_not_contains "$HERDR_OUT" "integer expression expected" "the seam value '$polls' reached an integer test"
  done
  pass "the verdict bound is a test-only seam: unset FM_TEST_SEAM or a non-numeric value keeps the production bound, so a slow refusal is still reported"
}

# --- the maintenance key and the numbered GIT_CONFIG environment of every launch route (C3, C9) ---------------
#
# Git's automatic maintenance packs the loose refs of a clone that holds 16 or more and removes the then-empty
# refs/heads/fm folder, which a confined worker cannot create again. bin/fm-spawn.sh therefore adds one
# maintenance.pack-refs.enabled=false entry to the launch carrier. Every route below replays the real launch text
# bin/fm-spawn.sh staged, records the environment the worker was started with (env -0), and runs one shared
# check on it (git_config_env_problems in tests/git-config-env-helpers.sh): every n below GIT_CONFIG_COUNT has a KEY_n and a VALUE_n,
# nothing sits at or above it, and a plain `git status` in that environment exits 0.
# On macOS a claude or omp launch runs under write confinement (sandbox-exec), whose profile also denies the
# folder creation; the replays of those two routes drop the sandbox-exec wrapper from the staged text in the
# fixture copy only, so the carrier text itself is what runs, and the confined commit is not claimed.

# write_pack_worker <path> <case-dir> <version-line>: records the launched environment, then makes one default-
# config commit in the task worktree under GIT_TRACE2_EVENT and records what happened to refs/heads/fm.
write_pack_worker() {
  local path=$1 dir=$2 version=$3
  cat > "$path" <<SH
#!/bin/sh
case "\${1-}" in --version) printf '%s\n' '$version'; exit 0 ;; esac
dir='$dir'
SH
  cat >> "$path" <<'SH'
run=$(cat "$dir/run")
obs="$dir/obs/$run"
mkdir -p "$obs"
env -0 > "$obs/env0"
export GIT_AUTHOR_NAME=worker GIT_AUTHOR_EMAIL=worker@example.invalid GIT_COMMITTER_NAME=worker GIT_COMMITTER_EMAIL=worker@example.invalid
emit() { printf '%s=%s\n' "$1" "$2" >> "$obs/result"; }
cd "$(cat "$dir/wt-path")" || exit 9
branch=$(cat "$dir/branch")
git checkout -q "$branch" 2>/dev/null || git checkout -q -b "$branch" || exit 8
gd=$(git rev-parse --git-common-dir)
emit loose_before "$(find "$gd/refs/heads/fm" -type f 2>/dev/null | wc -l | tr -d ' ')"
printf 'x\n' > pack-probe
git add pack-probe
: > "$obs/trace2"
GIT_TRACE2_EVENT="$obs/trace2" git commit -q -m pack-probe 2> "$obs/commit.err"
emit commit_rc "$?"
if [ -d "$gd/refs/heads/fm" ]; then emit folder present; else emit folder ABSENT; fi
emit loose_after "$(find "$gd/refs/heads/fm" -type f 2>/dev/null | wc -l | tr -d ' ')"
if grep '"event":"child_start"' "$obs/trace2" | grep -qF '"argv":["git","pack-refs"'; then emit packrefs_child yes; else emit packrefs_child no; fi
if grep '"event":"child_start"' "$obs/trace2" | grep -qF '"argv":["git","maintenance","run"'; then emit maintenance_child yes; else emit maintenance_child no; fi
emit done yes
SH
  chmod +x "$path"
}

# pack_case <name> <harness>: a spawn case whose project holds 20 loose refs/heads/fm/* beside main and the
# other fixture branches (21 or more loose refs), a deterministic (foreground) maintenance run, and the
# recording worker. CASE_ALLOWLIST, as in make_case, selects the allowlist route.
pack_case() {
  local name=$1 harness=$2 dir i
  dir=$(make_case "$name" "$harness") || exit 1
  git -C "$dir/project" config maintenance.autoDetach false
  i=1
  while [ "$i" -le 19 ]; do
    git -C "$dir/project" branch "fm/o$i"
    i=$((i + 1))
  done
  case "$harness" in
    omp) write_pack_worker "$(cat "$dir/fakebin")/$harness" "$dir" omp/18.1.20 ;;
    *) write_pack_worker "$(cat "$dir/fakebin")/$harness" "$dir" '2.1.300 (Claude Code)' ;;
  esac
  printf '%s\n' "$dir"
}

# without_sandbox <case-dir>: the staged launch text with its sandbox-exec wrapper removed (fixture copy only).
without_sandbox() {
  python3 -I - "$1/launch" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text, count = re.subn(r"exec /usr/bin/sandbox-exec -f '[^']*' ", "exec ", text)
sys.stdout.write(text)
sys.stderr.write("sandbox-exec wrappers removed: %d\n" % count)
PY
}

# replay_text <case-dir> <run> <launch-text-file> <pane-path> [extra env]: replay a launch text file the way
# replay does, from the task worktree.
replay_text() {
  local dir=$1 run=$2 text=$3 pane_path=$4
  shift 4
  printf '%s' "$run" > "$dir/run"
  rm -rf "${dir:?}/obs/$run"
  (cd "$(cat "$dir/wt-path")" && env -i HOME="$dir/home/user-home" PATH="$pane_path" TERM=xterm \
    GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" "$@" /bin/bash -c "$(cat "$text")" 3>&1 1>/dev/null 2>&3)
}

# route_entries <case-dir> <run> <key>: the values the launched environment carries for a git config key.
route_entries() { git_config_entries "$1/obs/$2/env0" "$3"; }

# assert_pack_key_route <case-dir> <run> <label> <expect-fetch-prune: yes|no> <expect-hooks: numbered|rows>
assert_pack_key_route() {
  local dir=$1 run=$2 label=$3 prune=$4 hooks=$5 env0 values
  env0="$dir/obs/$run/env0"
  [ -s "$env0" ] || fail "$label: the worker recorded no environment"
  assert_git_config_env "$env0" "$(cat "$dir/wt-path")" "$label"
  assert_equals false "$(route_entries "$dir" "$run" maintenance.pack-refs.enabled)" \
    "$label: the launched environment does not hold exactly one maintenance.pack-refs.enabled=false entry"
  if [ "$prune" = yes ]; then
    assert_equals false "$(route_entries "$dir" "$run" fetch.prune)" "$label: the seatbelt fetch.prune=false entry did not survive"
  else
    assert_equals "" "$(route_entries "$dir" "$run" fetch.prune)" "$label: a fetch.prune entry appeared on a route that adds none"
  fi
  case "$hooks" in
    numbered) assert_equals "$(cat "$dir/hooks-path")" "$(route_entries "$dir" "$run" core.hooksPath)" "$label: the numbered core.hooksPath entry did not survive" ;;
    rows) assert_contains "$(sed -n 's/^GIT_CONFIG_PARAMETERS=//p' <<EOF
$(tr '\0' '\n' < "$env0")
EOF
)" "hook.fm-scan-commit.event" "$label: the config hook rows did not survive" ;;
  esac
}

assert_pack_commit_leaves_folder() {  # <case-dir> <run> <label>
  local dir=$1 run=$2 label=$3
  assert_equals yes "$(obs "$dir" "$run" "done")" "$label: the worker did not finish"
  assert_equals 0 "$(obs "$dir" "$run" commit_rc)" "$label: the commit failed: $(cat "$dir/obs/$run/commit.err" 2>/dev/null)"
  assert_equals yes "$(obs "$dir" "$run" maintenance_child)" "$label: git started no maintenance run, so the case proves nothing"
  assert_equals no "$(obs "$dir" "$run" packrefs_child)" "$label: a git pack-refs child still ran"
  assert_equals present "$(obs "$dir" "$run" folder)" "$label: refs/heads/fm is gone after the commit"
  [ "$(obs "$dir" "$run" loose_after)" -ge 20 ] || fail "$label: the loose fm refs were packed away"
}

test_default_route_carries_the_key_and_a_commit_leaves_the_folder() {
  local dir err
  # A harness that is neither claude nor omp is neither confined nor on the config carrier: the plain
  # default route (/usr/bin/env -i, the legacy numbered carrier).
  dir=$(pack_case pk-default codex) || exit 1
  err=$(replay "$dir" pk-default /bin/bash "$(pane_path "$dir")")
  assert_pack_key_route "$dir" pk-default "default env -i route" no numbered
  assert_pack_commit_leaves_folder "$dir" pk-default "default env -i route"
  # The control: the same worker started without the launch carrier packs and loses the folder.
  printf '%s' pk-control > "$dir/run"
  git -C "$(cat "$dir/wt-path")" reset -q --hard HEAD~1   # the replay's own commit is undone so the worker commits again
  (cd "$(cat "$dir/wt-path")" && env -i HOME="$dir/home/user-home" PATH="$(pane_path "$dir")" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" \
    "$(cat "$dir/fakebin")/codex") >/dev/null 2>&1
  assert_equals yes "$(obs "$dir" pk-control packrefs_child)" "control: no git pack-refs child without the carrier key"
  assert_equals ABSENT "$(obs "$dir" pk-control folder)" "control: the folder survived without the carrier key"
  pass "the default env -i route carries one maintenance.pack-refs.enabled=false entry beside core.hooksPath, and its commit leaves refs/heads/fm (control: it vanishes without)"
}

test_allowlist_route_carries_the_key_and_a_commit_leaves_the_folder() {
  local dir err
  dir=$(CASE_ALLOWLIST='GIT_CONFIG_GLOBAL' pack_case pk-allow codex) || exit 1
  err=$(replay "$dir" pk-allow /bin/bash "$(pane_path "$dir")")
  assert_pack_key_route "$dir" pk-allow "allowlist route" no numbered
  assert_pack_commit_leaves_folder "$dir" pk-allow "allowlist route"
  pass "the allowlist route carries one maintenance.pack-refs.enabled=false entry, and its commit leaves refs/heads/fm"
}

test_seatbelt_routes_carry_the_key_in_the_staged_text() {
  local harness dir text err hooks
  [ "$(uname -s)" = Darwin ] || { printf 'skip: the seatbelt-v1 routes exist on macOS only\n'; return; }
  for harness in claude omp; do
    dir=$(pack_case "pk-sb-$harness" "$harness") || exit 1
    grep -q 'sandbox-exec' "$dir/launch" || fail "seatbelt $harness: the staged text has no sandbox-exec wrapper, so this is not the seatbelt-v1 route"
    text="$dir/launch.nosandbox"
    without_sandbox "$dir" > "$text" 2>"$dir/strip.log"
    assert_contains "$(cat "$dir/strip.log")" "removed: 1" "seatbelt $harness: the fixture could not remove the sandbox-exec wrapper"
    err=$(replay_text "$dir" "pk-sb-$harness" "$text" "$(pane_path "$dir")")
    hooks=numbered
    [ "$harness" != claude ] || hooks=rows
    [ "$harness" != claude ] || [ "$CONFIG_GIT" = 1 ] || hooks=numbered
    assert_pack_key_route "$dir" "pk-sb-$harness" "seatbelt-v1 $harness" yes "$hooks"
  done
  printf 'pending: the confined commit of the seatbelt-v1 routes (no sandbox here): the supervisor runs it (evidence/c5-command.txt)\n'
  pass "the seatbelt-v1 claude and omp launch texts carry one maintenance.pack-refs.enabled=false entry beside fetch.prune=false and the task hooks (the confined commit is pending)"
}

test_relaunch_and_double_selection_leave_exactly_one_key() {
  local dir err values
  dir=$(pack_case pk-twice codex) || exit 1
  # The pane already holds the key with the other value and a stale copy: both selections must leave one false.
  err=$(replay "$dir" pk-twice /bin/bash "$(pane_path "$dir")" \
    GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=maintenance.pack-refs.enabled GIT_CONFIG_VALUE_0=true \
    GIT_CONFIG_KEY_1=maintenance.pack-refs.enabled GIT_CONFIG_VALUE_1=true)
  values=$(route_entries "$dir" pk-twice maintenance.pack-refs.enabled)
  assert_equals false "$values" "pane entries holding the key as true were not replaced by exactly one false"
  assert_git_config_env "$dir/obs/pk-twice/env0" "$(cat "$dir/wt-path")" "double selection"
  pass "a pane that already holds the key leaves exactly one false entry after the outer and the inner selection"
}

# The helper itself: each of four mutations of a good environment must fail it, for its own reason.
test_the_shared_environment_check_rejects_each_mutation() {
  local dir good out
  dir=$(pack_case pk-helper codex) || exit 1
  replay "$dir" pk-helper /bin/bash "$(pane_path "$dir")" >/dev/null 2>&1
  good="$dir/obs/pk-helper/env0"
  git_config_env_problems "$good" "$(cat "$dir/wt-path")" >/dev/null || fail "the helper rejected an environment a real launch produced"
  mutate() {  # <name> <python expression body over env dict>
    python3 -I - "$good" "$dir/mut-$1" "$2" <<'PY'
import sys
src, dst, mode = sys.argv[1:4]
env = {}
for item in open(src, "rb").read().split(b"\0"):
    if item:
        k, _, v = item.decode("utf-8", "surrogateescape").partition("=")
        env[k] = v
if mode == "drop-key0":
    del env["GIT_CONFIG_KEY_0"]
elif mode == "drop-value0":
    del env["GIT_CONFIG_VALUE_0"]
elif mode == "count-high":
    env["GIT_CONFIG_COUNT"] = str(int(env["GIT_CONFIG_COUNT"]) + 1)
elif mode == "count-low":
    env["GIT_CONFIG_COUNT"] = str(int(env["GIT_CONFIG_COUNT"]) - 1)
open(dst, "wb").write(b"".join(("%s=%s" % (k, v)).encode("utf-8", "surrogateescape") + b"\0" for k, v in env.items()))
PY
  }
  mutate drop-key0 drop-key0
  out=$(git_config_env_problems "$dir/mut-drop-key0" "$(cat "$dir/wt-path")") && fail "the helper accepted an environment with GIT_CONFIG_KEY_0 dropped"
  assert_contains "$out" "GIT_CONFIG_KEY_0 is missing" "KEY_0 dropped: the helper failed for another reason"
  mutate drop-value0 drop-value0
  out=$(git_config_env_problems "$dir/mut-drop-value0" "$(cat "$dir/wt-path")") && fail "the helper accepted an environment with GIT_CONFIG_VALUE_0 dropped"
  assert_contains "$out" "GIT_CONFIG_VALUE_0 is missing" "VALUE_0 dropped: the helper failed for another reason"
  mutate count-high count-high
  out=$(git_config_env_problems "$dir/mut-count-high" "$(cat "$dir/wt-path")") && fail "the helper accepted a COUNT one too high"
  assert_contains "$out" "is missing below GIT_CONFIG_COUNT" "COUNT one too high: the helper failed for another reason"
  mutate count-low count-low
  out=$(git_config_env_problems "$dir/mut-count-low" "$(cat "$dir/wt-path")") && fail "the helper accepted a COUNT one too low"
  assert_contains "$out" "sits at or above GIT_CONFIG_COUNT" "COUNT one too low: the helper failed for another reason"
  # The dsh-shaped environment the scout had: COUNT=1, VALUE_0 present, KEY_0 absent.
  printf 'PATH=%s\0HOME=%s\0GIT_CONFIG_COUNT=1\0GIT_CONFIG_VALUE_0=/x\0' "$PATH" "$HOME" > "$dir/dsh-shaped"
  out=$(git_config_env_problems "$dir/dsh-shaped" "$(cat "$dir/wt-path")") && fail "the helper accepted the dsh-shaped environment (COUNT=1, VALUE_0 set, KEY_0 absent)"
  assert_contains "$out" "git status exited" "the dsh-shaped environment did not break git status"
  pass "the shared check fails each of KEY_0 dropped, VALUE_0 dropped, COUNT one too high, COUNT one too low, and the dsh-shaped environment, each for its own reason"
}

tests=(
  test_listed_harness_runs_the_config_carrier
  test_git_without_config_hooks_falls_back_to_legacy
  test_unlisted_harness_stays_on_legacy
  test_probe_is_load_bearing
  test_launch_refuses_without_a_carrier
  test_relaunch_keeps_exactly_one_carrier
  test_allowlisted_parameters_keep_one_row_set
  test_keep_ai_trailers_keeps_the_scan
  test_spawn_fails_when_the_pane_refuses
  test_removed_hooks_dir_runs_no_hooks
  test_relaunch_refusal_keeps_the_task
  test_herdr_fresh_refusal_closes_its_pane
  test_verdict_bound_is_a_test_only_seam
  test_default_route_carries_the_key_and_a_commit_leaves_the_folder
  test_allowlist_route_carries_the_key_and_a_commit_leaves_the_folder
  test_seatbelt_routes_carry_the_key_in_the_staged_text
  test_relaunch_and_double_selection_leave_exactly_one_key
  test_the_shared_environment_check_rejects_each_mutation
)
fm_test_run_cases "${tests[@]}" -- "$@"

echo "# all fm-spawn-git-hook-carrier tests passed"
