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
# commands it ran. FM_GIT_HOOK_MODE is never used as evidence.
#
# Sensitivity controls change one decisive fact inside the fixture only: a row
# dropped from the worker's own GIT_CONFIG_PARAMETERS, a fixture git on the pane
# PATH that hides the rows from every command except the probe, and the legacy
# carrier's known gaps. No production bypass exists or is used.
set -u

unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS FM_GIT_HOOK_ROWS FM_GIT_HOOK_MODE

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-git-hook-carrier)
trap fm_test_cleanup EXIT
export FM_GUARD_EVENT_LOG="$TMP_ROOT/guard-events.jsonl"
fm_git_identity 'Carrier Tests' 'carrier@example.invalid'

REAL_GIT=$(command -v git) || fail "git is required"

# Config-based hooks arrived in git 2.54. On an older git every config-carrier
# case is skipped by name and only the fallback and refusal cases run.
CONFIG_GIT=1
mkdir -p "$TMP_ROOT/probe"
"$REAL_GIT" init -q "$TMP_ROOT/probe/r"
if ! (cd "$TMP_ROOT/probe/r" && GIT_CONFIG_PARAMETERS="'hook.p.event'='commit-msg' 'hook.p.command'='true'" \
  "$REAL_GIT" hook list commit-msg 2>/dev/null | grep -qx p); then
  CONFIG_GIT=0
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
  assert_equals refused "$(obs "$dir" "$run" cred_commit)" "$run: credential commit landed"
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
  command -v tmux >/dev/null 2>&1 || { printf 'skip: tmux absent; real-endpoint refusal not exercised\n'; return; }
  real_endpoint_spawn refuse 100
  [ "$REAL_STATUS" -ne 0 ] || fail "spawn reported success although the pane refused the launch: $REAL_OUT"
  assert_contains "$REAL_OUT" "honours neither task Git hook carrier" "spawn did not name the refusal"
  assert_absent "$REAL_HOME/state/$REAL_ID.meta" "a refused launch published a task record"
  assert_absent "$REAL_DIR/harness-started" "the harness started although the launch was refused"
  assert_contains "$(cat "$REAL_HOME/state/$REAL_ID.status" 2>/dev/null)" "refused to start a worker without the task Git hooks" \
    "the refusal was not recorded in the task status"
  # The nearest legitimate launch: the same endpoint with an ordinary git.
  real_endpoint_spawn admit 100
  expect_code 0 "$REAL_STATUS" "spawn failed on a pane whose git honours the carrier: $REAL_OUT"
  assert_present "$REAL_DIR/harness-started" "the harness did not start on a healthy pane"
  # Control: without the wait the same refusal is reported as a spawned worker.
  real_endpoint_spawn ctl 0
  expect_code 0 "$REAL_STATUS" "control: spawn without the verdict wait did not report success: $REAL_OUT"
  assert_absent "$REAL_DIR/harness-started" "control: the harness started although the launch was refused"
  pass "a real endpoint whose git honours neither carrier fails the spawn, names the reason and starts no harness; without the verdict wait it is falsely reported spawned"
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
  # Let a launch that is still running reach the harness before observing it.
  sleep 2
  "$real_tmux" -S "$socket" kill-server 2>/dev/null || :
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"*
  REAL_DIR=$dir REAL_HOME=$home REAL_ID=$id
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
)
fm_test_run_cases "${tests[@]}" -- "$@"

echo "# all fm-spawn-git-hook-carrier tests passed"
