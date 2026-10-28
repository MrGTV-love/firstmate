#!/usr/bin/env bash
# Shared definitions and fixture setup for the independently runnable
# fm-teardown suites: tests/fm-teardown.test.sh (the landed-work proof and
# refusal matrix), tests/fm-teardown-pool.test.sh (pool slots, leases, custody,
# and returns), and tests/fm-teardown-cleanup.test.sh (post-close cleanup of
# processes, foreign copies, launch agents, and Docker stacks).
#
# Source this from a group file and register that group's cases there.
# Each sourcing process owns one temporary root, one tracked-fixture process
# registry, and one EXIT cleanup, exactly as the single combined suite did, so a
# group file stays independently runnable beside its siblings.
#
# Every case builds its own sandbox through make_case and never reuses another
# case's directory: sharing one would carry state into later cases and change
# behavior rather than test the product. Fixture processes are tracked by birth
# identity as well as pid, so a recycled pid is never signalled, and
# teardown_fixture_cleanup stops everything this process registered.
# Values assigned here are consumed by the group files that source this module,
# so their use is not visible in this file.
# shellcheck disable=SC2034
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/git-lock-helpers.sh
. "$ROOT/tests/git-lock-helpers.sh"
fm_git_identity fmtest fmtest@example.invalid
# Each fixture chooses its own home, never the invoking session's live home.
unset FM_HOME FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID FM_FRICTION_EPISODE_ID
export FM_FRICTION_EXECUTION_KIND=test

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST

TEARDOWN_FIXTURE_PROCESSES="$TMP_ROOT/fixture-processes"
FM_TEARDOWN_FIXTURE_HELPERS="$TMP_ROOT/fixture-process.pl"
export TEARDOWN_FIXTURE_PROCESSES FM_TEARDOWN_FIXTURE_HELPERS
mkdir "$TEARDOWN_FIXTURE_PROCESSES"

teardown_fixture_birth() {
  local pid=$1 stat_line start
  local -a fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    IFS= read -r stat_line < "/proc/$pid/stat" || return 1
    read -r -a fields <<< "${stat_line##*)}"
    [ "${#fields[@]}" -ge 20 ] || return 1
    [ "${fields[0]}" != Z ] || return 1
    printf 'starttime=%s\n' "${fields[19]}"
  else
    start=$(LC_ALL=C "$REAL_PS_FOR_TEST" -p "$pid" -o lstart=) || return 1
    start=${start#"${start%%[![:space:]]*}"}
    start=${start%"${start##*[![:space:]]}"}
    [ -n "$start" ] || return 1
    printf 'lstart=%s\n' "$start"
  fi
}

teardown_fixture_live() {
  local pid=$1 birth=$2 current state
  current=$(teardown_fixture_birth "$pid") || return 1
  [ "$current" = "$birth" ] || return 1
  state=$("$REAL_PS_FOR_TEST" -p "$pid" -o stat=) || return 1
  case "$state" in *Z*|'') return 1 ;; esac
}

teardown_fixture_track() {
  local pid=$1 signal=${2:-KILL} birth
  birth=$(teardown_fixture_birth "$pid") || fail "cannot register fixture process $pid"
  printf '%s\t%s\n' "$signal" "$birth" > "$TEARDOWN_FIXTURE_PROCESSES/$pid"
}

teardown_fixture_start() {
  local cwd=$1 signal=$2 interrupted=0
  shift 2
  trap 'interrupted=130' INT
  trap 'interrupted=143' TERM
  trap 'interrupted=129' HUP
  trap 'interrupted=131' QUIT
  (cd "$cwd" && exec "$@") &
  TEARDOWN_FIXTURE_PID=$!
  teardown_fixture_track "$TEARDOWN_FIXTURE_PID" "$signal"
  [ "$signal" != KILL ] || disown "$TEARDOWN_FIXTURE_PID"
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'exit 131' QUIT
  [ "$interrupted" -eq 0 ] || exit "$interrupted"
}

teardown_fixture_stop() {
  local pid=$1 signal birth
  [ -f "$TEARDOWN_FIXTURE_PROCESSES/$pid" ] || return 0
  IFS=$'\t' read -r signal birth < "$TEARDOWN_FIXTURE_PROCESSES/$pid" || return 0
  teardown_fixture_live "$pid" "$birth" || return 0
  kill "-$signal" "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  while teardown_fixture_live "$pid" "$birth"; do sleep 0.01; done
}

teardown_fixture_cleanup() {
  local record signal birth
  trap '' INT TERM HUP QUIT
  for record in "$TEARDOWN_FIXTURE_PROCESSES"/*; do
    [ -f "$record" ] || continue
    IFS=$'\t' read -r signal birth < "$record" || continue
    case "$signal" in TERM|HUP) teardown_fixture_stop "${record##*/}" ;; esac
  done
  for record in "$TEARDOWN_FIXTURE_PROCESSES"/*; do
    [ -f "$record" ] && teardown_fixture_stop "${record##*/}"
  done
  fm_test_cleanup
}

trap teardown_fixture_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
export -f teardown_fixture_birth teardown_fixture_live
cat > "$FM_TEARDOWN_FIXTURE_HELPERS" <<'PERL'
sub fixture_birth {
  my ($pid) = @_;
  if (open my $stat, "<", "/proc/$pid/stat") {
    my $line = <$stat>;
    close $stat;
    $line =~ s/.*\)\s*//;
    my @fields = split /\s+/, $line;
    die "missing birth identity" unless @fields >= 20;
    return "starttime=$fields[19]";
  }
  local $ENV{LC_ALL} = "C";
  open my $ps, "-|", $ENV{REAL_PS_FOR_TEST}, "-p", $pid, "-o", "lstart=" or die "ps";
  my $start = <$ps>;
  close $ps or die "ps failed";
  defined $start or die "missing birth identity";
  $start =~ s/^\s+|\s+$//g;
  length $start or die "empty birth identity";
  return "lstart=$start";
}
sub fixture_track {
  my ($pid) = @_;
  my $birth = fixture_birth($pid);
  my $record = "$ENV{TEARDOWN_FIXTURE_PROCESSES}/$pid";
  open my $fh, ">", "$record.$$" or die "register fixture";
  print {$fh} "KILL\t$birth\n";
  close $fh or die "close fixture registration";
  rename "$record.$$", $record or die "publish fixture registration";
  return $birth;
}
1;
PERL

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$case_dir/primary-home" "$fakebin"
  # Keep the runtime code boundary beside task targets, even when TMPDIR is
  # inside the source checkout; commands still come from the real source bin.
  mkdir -p "$case_dir/code-root"
  ln -s "$ROOT/bin" "$case_dir/code-root/bin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set, the top-level `runs` listing answers
  # FM_FAKE_NM_RUNS_LIST verbatim (the real `no-mistakes runs --limit N` is
  # plain text with no run id and no quoting - see the ledger fixtures below),
  # and `runs` appends its own invocation to FM_FAKE_NM_RUNS_LOG when set, so
  # a test can prove whether the ledger fallback ever engaged.
  # The bare `axi` overview answers FM_FAKE_AXI_OVERVIEW verbatim (empty by
  # default, so no repository resolves and the pipeline-spend record is
  # written as unavailable).
  # This keeps every case hermetic - without it, `command -v no-mistakes`
  # would fall through to whatever real binary happens to be on the test
  # runner's own PATH. Tests exercising the run-abort path override
  # FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG/FM_FAKE_NM_RUNS_LIST before
  # run_teardown.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      '')
        printf '%s\n' "${FM_FAKE_AXI_OVERVIEW:-}" ;;
      status)
        shift
        [ "${FM_FAKE_NM_STATUS_FAIL:-0}" != 1 ] || exit 1
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
  daemon)
    if [ "${2:-}" = stop ] && [ -n "${FM_FAKE_NM_SHARED_DAEMON_STATE:-}" ]; then
      printf '%s\n' stopped > "$FM_FAKE_NM_SHARED_DAEMON_STATE"
    fi
    ;;
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
    [ "${FM_FAKE_NM_RUNS_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' "${FM_FAKE_NM_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"
  # Teardown now asks Docker which stacks the task owns. Shadow the host's real
  # Docker with the fixture-store fake (empty by default) so no case reaches it.
  fm_fake_docker "$fakebin"

  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind [worktree]
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head and,
# optionally, the actual merge commit used by archive cleanup.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2 merge=${3:-}
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' 'MERGED' '$head' '$merge' ; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Squash-merged history whose pipeline rebased the branch onto a newer main that
# edited the same shared file. A local copy left behind by that rebase holds
# different content for the shared file, so its per-commit patch ids against the
# PR head differ and merge-tree against main conflicts; teardown refuses it on
# purpose rather than reading a shared path as proof the local content landed.
# local_mode: rebased | stale | rebased-plus-unlanded
# Echoes: <pr_head>
setup_squash_rebased_history() {
  local case_dir=$1 local_mode=$2 tmp local_head pr_head
  tmp="$case_dir/_shared_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "shared base"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  rm -rf "$tmp"

  wt_commit_file "$case_dir" feature.txt hello "add feature"
  printf '%s\n' base feature-edit > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add -- shared.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base main-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main edits shared"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  printf '%s\n' base main-edit feature-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" fetch -q origin "refs/pull/7/head:refs/fm-test/pr-head"
  case "$local_mode" in
    rebased)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      ;;
    stale)
      git -C "$case_dir/wt" reset -q --hard "$local_head"
      ;;
    rebased-plus-unlanded)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      wt_commit_file "$case_dir" later.txt local-only "local follow-up"
      ;;
    *)
      fail "setup_squash_rebased_history: unknown local_mode $local_mode"
      ;;
  esac
  printf '%s\n' "$pr_head"
}

# Squash-merged history whose pipeline rebased the task onto a newer main and
# pushed the rebased copy as the PR head, while the task copy stayed on the
# pre-rebase commits. Those commits were also pushed to a second remote (the
# no-mistakes remote), so none of them counts as unpushed. The task copy holds a
# merge of main. The PR head replays each commit's patch and adds one follow-up
# that edits a.txt, so main's a.txt differs from the task copy's and the content
# check cannot prove the copy landed.
# mode: landed | missing-commit | edited-merge
#   missing-commit: the PR head never replays "add b".
#   edited-merge: the merge of main also carries a hand-written z.txt.
# Echoes: <pr_head>
setup_pushed_prerebase_history() {
  local case_dir=$1 mode=$2 tmp pr_head
  wt_commit_file "$case_dir" a.txt alpha "add a"
  wt_commit_file "$case_dir" b.txt bravo "add b"

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' moved > "$tmp/m.txt"
  git -C "$tmp" add -- m.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main moves"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/wt" fetch -q origin
  if [ "$mode" = edited-merge ]; then
    git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
      merge -q --no-commit --no-ff origin/main
    printf '%s\n' zulu > "$case_dir/wt/z.txt"
    git -C "$case_dir/wt" add -- z.txt
    git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
      commit -q -m "Merge main with a hand-written change"
  else
    git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
      merge -q --no-ff --no-edit origin/main
  fi
  wt_commit_file "$case_dir" c.txt charlie "add c"

  git init -q --bare "$case_dir/no-mistakes.git"
  git -C "$case_dir/wt" remote add no-mistakes "$case_dir/no-mistakes.git"
  git -C "$case_dir/wt" push -q no-mistakes HEAD:refs/heads/fm/task-x1

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' alpha > "$tmp/a.txt"
  git -C "$tmp" add -- a.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add a"
  if [ "$mode" != missing-commit ]; then
    printf '%s\n' bravo > "$tmp/b.txt"
    git -C "$tmp" add -- b.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add b"
  fi
  printf '%s\n' charlie > "$tmp/c.txt"
  git -C "$tmp" add -- c.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add c"
  printf '%s\n' alpha review-edit > "$tmp/a.txt"
  git -C "$tmp" add -- a.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "review: edit a"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' "$pr_head"
}

# Squash-merged history whose pipeline took the task copy as its INPUT, then
# rewrote and added commits on the branch it pushed. The copy's commits are
# neither ancestors of the PR head nor patches the PR head replays unchanged, and
# main's content for a.txt conflicts with the copy's, so only the no-mistakes run
# record proves the copy landed (pipeline_input_is_local_head in
# bin/fm-teardown.sh). Commit subjects repeat on purpose: they prove nothing.
# shape: diverged-iteration | rewritten-input
#   diverged-iteration: the PR head shares no commit with the copy; the pipeline
#     rebuilt the earlier iteration's work as different commits.
#   rewritten-input: main moved and the copy merged it; the pipeline replayed the
#     commits onto the moved main, rewrote "add a", and added a review commit.
# Echoes: <pr_head>
setup_pipeline_rewritten_history() {
  local case_dir=$1 shape=$2 tmp pr_head
  wt_commit_file "$case_dir" a.txt alpha "add a"
  wt_commit_file "$case_dir" b.txt bravo "add b"
  if [ "$shape" = rewritten-input ]; then
    tmp="$case_dir/_main_move"
    git clone -q "$case_dir/origin.git" "$tmp"
    printf '%s\n' moved > "$tmp/m.txt"
    git -C "$tmp" add -- m.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main moves"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    git -C "$case_dir/wt" fetch -q origin
    git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
      merge -q --no-ff --no-edit origin/main
  fi

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' alpha-reviewed > "$tmp/a.txt"
  git -C "$tmp" add -- a.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add a"
  printf '%s\n' bravo > "$tmp/b.txt"
  git -C "$tmp" add -- b.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add b"
  printf '%s\n' reviewed > "$tmp/r.txt"
  git -C "$tmp" add -- r.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "review: add r"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' "$pr_head"
}

# Write one row of the no-mistakes state database teardown reads at
# $case_dir/nm/state.sqlite (run_teardown points NM_HOME there). An empty
# submitted or pushed value is stored as NULL; omit-column leaves that column out
# of the table entirely. Calling it again appends another run row.
# Args: case_dir run_id pr_url submitted pushed [omit-column]
write_nm_run_record() {
  local case_dir=$1 id=$2 pr_url=$3 submitted=$4 pushed=$5 omit=${6:-}
  mkdir -p "$case_dir/nm"
  python3 -I - "$case_dir/nm/state.sqlite" "$id" "$pr_url" "$submitted" "$pushed" "$omit" <<'PY'
import sqlite3
import sys

database, run_id, pr_url, submitted, pushed, omit = sys.argv[1:]
columns = ["id", "branch", "pr_url", "submitted_head_sha", "last_pushed_sha", "created_at"]
values = [run_id, "fm/task-x1", pr_url, submitted or None, pushed or None, 1]
kept = [(name, value) for name, value in zip(columns, values) if name != omit]
db = sqlite3.connect(database)
db.execute("CREATE TABLE IF NOT EXISTS runs (%s)" % ", ".join(name for name, _ in kept))
db.execute(
    "INSERT INTO runs (%s) VALUES (%s)" % (
        ", ".join(name for name, _ in kept), ", ".join("?" for _ in kept)),
    [value for _, value in kept],
)
db.commit()
PY
}

# A refusal must leave every recovery route intact: the isolated copy, its task
# branch still at the unlanded commit, and the durable task record. A completed
# teardown detaches and deletes that branch and removes the record, so these hold
# only while nothing destructive ran before the refusal was reported.
# Args: case_dir label head-before-teardown
assert_refusal_retained_task_state() {
  local case_dir=$1 label=$2 head=$3
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
    || fail "$label: refusal dropped the task branch"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    || fail "$label: refusal moved the task branch off the unlanded commit"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "$label: refusal erased the durable task record"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# Keep real lsof for lock/companion queries, but exclude the independent
# teardown process-reaping scan: this fixture tests preservation of a live owner,
# not termination of task processes. No lock-owner evidence is stubbed.
add_lsof_real_lock_queries() {
  cat > "$1/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -Fpn "*) exit 0 ;; esac
exec "${REAL_LSOF_FOR_TEST:?}" "$@"
SH
  chmod +x "$1/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" ${args[@]+"${args[@]}"}
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  FM_HOME="${FM_HOME:-$case_dir/primary-home}" \
  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  NM_HOME="$case_dir/nm" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close. Uses the real tasks-axi (the fixture's default fakebin has
# no tasks-axi stub, so PATH resolves the installed one).
seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

# The opt-in fleet ledger (docs/fleet-ledger.md): a completed backlog close
# appends one task.closed record naming the evidence the close used.
ledger_closed_rows() {  # <case-dir>
  [ -f "$1/state/fleet-ledger.jsonl" ] || return 0
  jq -c 'select(.event == "task.closed") | [.task, .evidence, .pr, (.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))]' \
    "$1/state/fleet-ledger.jsonl"
}

# Land the fixture's task branch as a real squash commit and supply independent
# forge head/merge evidence. The local task copy remains on the PR head.
land_archive_fixture_pr() {
  local case_dir=$1 head merge
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" merge -q --squash fm/task-x1 >/dev/null
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm "squash task"
  merge=$(git -C "$case_dir/project" rev-parse HEAD)
  git -C "$case_dir/project" push -q origin main
  append_pr_meta_url "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$head" "$merge"
}

assert_archive_ref() {  # <case-dir> <branch> <expected-sha>
  local case_dir=$1 branch=$2 expected=$3 actual
  actual=$(git -C "$case_dir/project" rev-parse --verify "refs/heads/$branch" 2>/dev/null) || actual=
  [ "$actual" = "$expected" ] || fail "$branch: expected ref $expected, got $actual"
}

# Override tea to answer one login for git.example.org and a pull request
# read through "tea api" with the supplied merged flag and head.
add_tea_pull_for_head() {
  local case_dir=$1 merged=$2 head=$3
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tea.log"
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "\${1:-}" = api ] || exit 1
printf '{"state":"closed","merged":%s,"head":{"sha":"%s"}}\n' '$merged' '$head'
SH
  chmod +x "$case_dir/fakebin/tea"
}

# Fixture for the pipeline-input cases: PR 7 is merged, its head is the commit the
# pipeline pushed, and the task copy is the (rewritten) input the pipeline started
# from. The recorded run is each test's own. Echoes: <pr_head>
pipeline_input_case() {
  local name=$1 shape=${2:-rewritten-input} case_dir pr_head
  case_dir=$(make_case "$name")
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_pipeline_rewritten_history "$case_dir" "$shape")
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "$pr_head"
}

# Run teardown on the fixture, keep its output in the case dir, echo the exit code.
run_teardown_status() {
  local case_dir=$1 rc
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

# The copy must refuse, name every given pattern, and keep every recovery route.
# Args: case_dir label local_head pattern...
assert_pipeline_input_refusal() {
  local case_dir=$1 label=$2 local_head=$3 rc pattern
  shift 3
  rc=$(run_teardown_status "$case_dir")
  expect_code 1 "$rc" "$label: teardown should refuse"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "$label: no REFUSED line in stderr"
  for pattern in "$@"; do
    grep -qF -- "$pattern" "$case_dir/stderr" \
      || fail "$label: the refusal does not name '$pattern'"$'\n'"$(cat "$case_dir/stderr")"
  done
  assert_refusal_retained_task_state "$case_dir" "$label" "$local_head"
}

# The copy was the pipeline's input and the pipeline rewrote it before the PR
# merged. Without the run record the copy still refuses, which is the stuck
# cleanup; with a record whose run pushed the merged head and started from this
# copy's HEAD, it is landed.
assert_pipeline_input_copy_allowed_by_record() {
  local case_dir=$1 label=$2 pr_head=$3 local_head rc
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  assert_pipeline_input_refusal "$case_dir" "$label-no-record" "$local_head" \
    "no no-mistakes state database"

  write_nm_run_record "$case_dir" 01RUNINPUT "https://github.com/example/repo/pull/7" "$local_head" "$pr_head"
  rc=$(run_teardown_status "$case_dir")
  expect_code 0 "$rc" "$label: teardown should accept the copy the merged run started from"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "$label: teardown printed a REFUSED line"
}

assert_dirty_diagnostic() {
  local kind=$1 mode=$2 case_dir rc before n
  case_dir=$(make_case "dirty-$kind-$mode")
  write_meta "$case_dir" "$mode" ship
  wt_commit_file "$case_dir" feature.txt hello
  # Exercise both dirty refusal sites: remote-reachable work and local-only
  # work merged into local main but absent from every remote.
  if [ "$mode" = local-only ]; then
    git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  else
    git -C "$case_dir/wt" push -q origin fm/task-x1
  fi
  if [ "$kind" != untracked ]; then
    printf '%s\n' 'uncommitted edit' > "$case_dir/wt/feature.txt"
    # Cover index edits as well as unstaged edits.
    [ "$mode" != local-only ] || git -C "$case_dir/wt" add feature.txt
  fi
  if [ "$kind" != tracked ]; then
    mkdir "$case_dir/wt/00 proof scratch"
    printf '%s\n' 'manual server log' > "$case_dir/wt/00 proof scratch/server.log"
    for n in 01 02 03 04 05 06 07 08 09 10 11; do
      touch "$case_dir/wt/$n-scratch.txt"
    done
    # Preserve the existing exemptions without counting them as leftovers.
    mkdir "$case_dir/wt/.claude"
    touch "$case_dir/wt/.claude/settings.local.json" "$case_dir/wt/.fm-grok-turnend" "$case_dir/wt/.fm-kimi-turnend"
  fi
  before=$(git -C "$case_dir/wt" status --porcelain)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$kind/$mode: dirty teardown must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "$kind/$mode: no refusal"
  if [ "$kind" = untracked ]; then
    grep -Fq 'uncommitted changes present (untracked-only leftovers)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing untracked-only classification"
    ! grep -q 'includes tracked edits' "$case_dir/stderr" || fail "$kind/$mode: misclassified as tracked"
  else
    grep -Fq 'uncommitted changes present (includes tracked edits)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing tracked-edit classification"
    ! grep -q 'untracked-only' "$case_dir/stderr" || fail "$kind/$mode: misclassified as untracked-only"
  fi
  if [ "$kind" != tracked ]; then
    grep -Fq '00 proof scratch/' "$case_dir/stderr" || fail "$kind/$mode: scratch folder not named"
    grep -Fxq '  09-scratch.txt' "$case_dir/stderr" || fail "$kind/$mode: tenth path missing"
    ! grep -q '10-scratch.txt\|11-scratch.txt\|\.claude/\|\.fm-grok-turnend\|\.fm-kimi-turnend' "$case_dir/stderr" \
      || fail "$kind/$mode: path list exceeded its bound or included exempt files"
    grep -Fq 'additional untracked paths omitted' "$case_dir/stderr" || fail "$kind/$mode: no truncation notice"
  else
    ! grep -q 'untracked paths' "$case_dir/stderr" || fail "$kind/$mode: invented untracked paths"
  fi
  [ -f "$case_dir/state/task-x1.meta" ] || fail "$kind/$mode: task metadata removed"
  [ "$before" = "$(git -C "$case_dir/wt" status --porcelain)" ] || fail "$kind/$mode: worktree changed"
  pass "$kind/$mode: dirty refusal classifies leftovers and preserves work"
}

# Treehouse's return runs `git clean -fd` (one -f). A nested repository stays.
add_treehouse_clean_fd() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Return succeeds, then plants a nested repository the pre-return scrub cannot
# have removed. The post-return check must name that residue.
add_treehouse_that_leaves_residue() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
    git init -q "$wt/left-behind-clone"
    git -C "$wt/left-behind-clone" commit -q --allow-empty -m residue
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

prepare_scout_teardown() {
  local case_dir=$1
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'Scout report.' > "$case_dir/data/task-x1/report.md"
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
}

# Clone a nested repository into the copy and add one plain scratch file.
seed_nested_clone_and_scratch() {
  local case_dir=$1 wt=$2
  git init -q "$case_dir/nested-src"
  printf 'payload\n' > "$case_dir/nested-src/payload.txt"
  git -C "$case_dir/nested-src" add payload.txt
  git -C "$case_dir/nested-src" -c user.email=t@t -c user.name=t commit -q -m payload
  git clone -q "$case_dir/nested-src" "$wt/scratch-clone"
  printf 'scratch\n' > "$wt/scratch.txt"
}

# Move the case worktree to pool/<slot>/repo so teardown sees a Treehouse slot.
move_case_to_pool_slot() {
  local case_dir=$1 slot=$2 dest
  dest="$case_dir/pool/$slot/repo"
  mkdir -p "$case_dir/pool/$slot"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$dest"
  # The worker's durable lease, as spawn publishes it: teardown's reservation
  # then proves the slot already held instead of taking a new lease (the
  # lease-protocol cases use make_lease_modeling_pool_case).
  printf '{"worktrees":[{"name":"%s","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' "$slot" "$dest" \
    > "$case_dir/pool/treehouse-state.json"
  printf '%s\n' "$dest"
}

# Return succeeds but leaves no readable worktree behind to verify.
add_treehouse_that_removes_copy() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  for a in "$@"; do wt=$a; done
  rm -f "$wt/.git"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Write a meta that predates the spawn_gen field entirely. Args: case_dir mode kind
write_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

# Count spawn_gen fields in the task's meta, so a refusal can prove it left the
# record byte-equivalent rather than stamped.
legacy_meta_gen_count() {
  local case_dir=$1
  awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' \
    "$case_dir/state/task-x1.meta" 2>/dev/null || printf '0\n'
}

# Override fakebin/tmux so the recovery-grade classifier reads the endpoint as
# unreadable (a session inventory failure it cannot attribute), never dead.
add_unreadable_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "error connecting to fixture: permission denied" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

write_windowless_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3 worktree
  worktree=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

assert_windowless_record_refuses() {  # <case-dir> <description> <refusal>
  local case_dir=$1 description=$2 refusal=$3 rc before
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "$description: a windowless record outside the leftover class must refuse"
  grep -Fq "$refusal" "$case_dir/stderr" \
    || fail "$description: the refusal was not '$refusal': $(cat "$case_dir/stderr")"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "$description: the refusal modified the task record"
}

add_failing_close_publication_mv() {
  local case_dir=$1 real_mv
  real_mv=$(command -v mv)
  cat > "$case_dir/fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  "$case_dir/state/task-x1.backlog-close") exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# Override fakebin/perl so ONLY the stamp rollback's truncate fails; every other
# perl call in the lifecycle still runs the real interpreter, so the abandoned
# attempt leaves its stamp behind for exactly the reason under test.
add_failing_truncate_perl() {
  local case_dir=$1 real
  real=$(command -v perl)
  cat > "$case_dir/fakebin/perl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *truncate*) exit 1 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/perl"
}

# Mark the case's home as a secondmate home bound to a parent: teardown and
# fm-pr-check run with FM_HOME="$case_dir/home" so the parent-channel
# publishers resolve that binding while the task state stays in $case_dir/state.
configure_secondmate_home() {  # <case-dir> <local|remote> [<parent-home>]
  local case_dir=$1 route=$2 parent=${3:-} home="$1/home"
  mkdir -p "$home"
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\nroute=%s\n' "$route"
    [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
  } > "$home/.fm-secondmate-parent"
  if [ "$route" = local ]; then
    # A local parent registers the mate; teardown resolves that registration.
    mkdir -p "$parent/state" "$parent/data"
    fm_write_secondmate_meta "$parent/state/mate-x.meta" "$home"
    printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
      "$home" > "$parent/data/secondmates.md"
  fi
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin code_root
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  code_root="$case_dir/code-root"
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      code_root="$case_dir/test-root"
      ;;
  esac
  rc=0
  FM_HOME="${FM_HOME:-$case_dir/primary-home}" \
    FM_ROOT_OVERRIDE="$code_root" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

# The Herdr presentation-lock namespace is named per OS account. These cases
# act as a fixture account uid (via an `id -u` shim) so they never touch the
# real account's namespace or the old shared /tmp/firstmate-herdr-presentation,
# and every directory the fixture account resolves is really owned by the
# running account, i.e. by another uid from the fixture account's view.
# FM_FAKE_NS_STAT names one path whose owner and mode the `stat` shim reports
# instead; the adapter reads ownership through a PATH `stat` only on its non-
# Darwin branch, so the arms that need it run only there.
herdr_lock_ns_fake_uid() {
  printf '%s' "$((3000000000 + $$ % 1000000))"
}

configure_herdr_lock_ns_shims() {  # <case-dir>
  local case_dir=$1 real_id real_stat
  real_id=$(command -v id); real_stat=$(command -v stat)
  cat > "$case_dir/fakebin/id" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ] && [ "\$#" -eq 1 ] && [ -n "\${FM_FAKE_ACCOUNT_UID:-}" ]; then
  printf '%s\n' "\$FM_FAKE_ACCOUNT_UID"
  exit 0
fi
exec "$real_id" "\$@"
SH
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 3 ] && [ "\$1" = -c ] && [ -n "\${FM_FAKE_NS_STAT:-}" ] \\
  && [ "\$3" = "\${FM_FAKE_NS_STAT%%:*}" ]; then
  rest=\${FM_FAKE_NS_STAT#*:}
  case "\$2" in
    %u) printf '%s\n' "\${rest%%:*}"; exit 0 ;;
    %a) printf '%s\n' "\${rest#*:}"; exit 0 ;;
  esac
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/id" "$case_dir/fakebin/stat"
}

herdr_lock_ns_path_state() {  # <path>
  if [ -e "$1" ] || [ -L "$1" ]; then
    # A fixed, known path: ls is the portable way to read mode and numeric owner.
    # shellcheck disable=SC2012
    ls -ldn "$1" 2>/dev/null | awk '{print $1, $3, $4}'
  else
    printf 'absent'
  fi
}

run_herdr_lock_ns_teardown() {  # <case-dir> <fake-uid> [stat-spec]
  local case_dir=$1 fake_uid=$2 stat_spec=${3:-} rc=0
  FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$stat_spec" \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  return "$rc"
}

new_herdr_lock_ns_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  configure_herdr_lock_ns_shims "$case_dir"
  : > "$case_dir/herdr.log"
  : > "$case_dir/state/task-x1.status"
  printf '%s' "$case_dir"
}

assert_herdr_lock_ns_refused() {  # <case-dir> <label>
  local case_dir=$1 label=$2
  assert_grep "presentation lock could not be resolved" "$case_dir/stderr" \
    "$label: the namespace refusal was not explained visibly"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: refusal erased the durable endpoint metadata"
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ ! -e "$case_dir/closed" ] || fail "$label: refusal attempted a pane close without the lock"
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

configure_secondmate_with_tmux_children() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" child child_wt
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  for child in child-a child-b; do
    child_wt="$case_dir/$child-wt"
    git -C "$case_dir/project" worktree add -q -b "fm/$child" "$child_wt" main
    fm_write_meta "$home/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=local-only"
    : > "$home/state/$child.status"
  done
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  local grandchild_wt=${2:-$case_dir/wt}
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$grandchild_wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_CONFIRMED_GONE:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close")
    if [ -e "$case_dir/child-producers/grandchild-herdr.live" ]; then
      printf 'container\tc-shutdown\tshutdown-grandchild\tfm.task=grandchild-herdr\t\n' >> "\${FM_FAKE_DOCKER_STORE:?}"
      rm "$case_dir/child-producers/grandchild-herdr.live"
      printf '%s\n' grandchild-herdr > "$case_dir/current-child"
    fi
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    if [ "${FM_FAKE_HERDR_RESTORE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

# A task's per-task watcher markers (.seen-<id>_status, .seen-<id>_turn-ended,
# .hb-surfaced-<id>) and an orphaned presentation journal - one whose pane the
# close path proved gone without retiring it - must not outlive teardown, while
# another task's markers and a journal bound to a different pane must.
seed_watcher_markers() {  # <case-dir> <task-id>
  local state="$1/state" id=$2
  printf '0:0\n' > "$state/.seen-${id}_status"
  printf '0:0\n' > "$state/.seen-${id}_turn-ended"
  printf '0\n' > "$state/.hb-surfaced-$id"
}

# A version 1 attempt journal binds no pane, so proving the recorded task pane
# gone does not prove its token-bearing projected workspace gone. When the v2
# bind never landed (RETIRE_CANDIDATE stays 0 because the metadata workspace no
# longer matches the drifted token workspace), teardown may retire the journal
# only after the session's workspace list confirms the token workspace is gone;
# while it is still present the session-start sweep alone owns it.
configure_herdr_v1_orphan_workspace_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w9' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ "${FM_FAKE_HERDR_WS_MALFORMED:-0}" = 1 ]; then
      # A non-object entry before a live token-bearing workspace: the token query
      # is ambiguous, so teardown must treat it as unknown and keep the journal.
      printf '%s\n' '{"result":{"workspaces":[42,{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false}]}}'
    elif [ "${FM_FAKE_HERDR_WS_COLLAPSED:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    fi
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    printf '%s\n' '{"sessions":[{"name":"fmtest","running":true,"socket_path":"/tmp/fmtest.sock"}]}'
    ;;
  "pane close")
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    exit 1
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

# A parked-at-a-gate `axi status` TOON payload for <branch>/<head>, matching
# the shape no-mistakes actually emits (see tests/fm-crew-state.test.sh's
# run_parked fixture, the same shape bin/fm-crew-state.sh's own tests pin).
parked_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$2"
  pr: ""
  findings: none
gate: review
EOF
}

running_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: running
  head: "$2"
  pr: ""
steps[1]{step,status,findings,summary}:
  test,running,0,"agent under way"
EOF
}

# One row of the real `no-mistakes runs` ledger: plain text, newest-first,
# no run id, no quoting - "<status> <branch> <short-sha> <date> <time> [<pr-url>]"
# (the same shape tests/fm-crew-state.test.sh's runs-list fixtures pin).
ledger_row() {  # <status> <branch> <short-sha> <date> <time> [pr-url]
  printf '  %-10s %-24s %-8s  %s %s' "$1" "$2" "$3" "$4" "$5"
  [ -z "${6:-}" ] || printf '  %s' "$6"
  printf '\n'
}

# Commit <n> pipeline fix rounds on top of the task branch in a separate
# clone of origin that the task copy NEVER fetches from, mirroring how the
# no-mistakes daemon commits fix rounds in its own gate-repo clone. Echoes
# the newest short sha, which is genuinely absent from the task worktree's
# object store. Args: case_dir [rounds]
make_unfetched_pipeline_heads() {
  local case_dir=$1 rounds=${2:-1} i
  git clone -q "$case_dir/origin.git" "$case_dir/pipeline-clone"
  git -C "$case_dir/pipeline-clone" checkout -q fm/task-x1
  for i in $(seq 1 "$rounds"); do
    git -C "$case_dir/pipeline-clone" -c user.email=t@t -c user.name=t \
      commit -q --allow-empty -m "pipeline fix round $i"
  done
  git -C "$case_dir/pipeline-clone" rev-parse --short=7 HEAD
}

assert_head_absent_from_worktree() {  # <worktree> <short-sha> <label>
  [ -z "$(git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null)" ] \
    || fail "$3: fixture broke - the pipeline head resolved in the task copy"
}

# Land a shippable commit on the task branch and push it to origin. The commit
# carries no content of its own, so the default branch already holds it: the
# "definitely landed, teardown must ALLOW" shape, which lets these new cases
# exercise the abort/reap steps on a real successful teardown rather than a
# refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

assert_nested_lane_process_is_not_reaped() {  # <case-name> <registrar: project|sibling> [<lane-damage: none|no-git|deleted>]
  local name=$1 registrar=$2 damage=${3:-none} case_dir rc pid other_pid nested lane before identity registry
  case_dir=$(make_case "$name")
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  registry="$case_dir/project"
  if [ "$registrar" = sibling ]; then
    registry="$case_dir/sibling-clone"
    git clone -q "$case_dir/origin.git" "$registry"
  fi
  nested="$case_dir/wt/other-lane"
  git -C "$registry" worktree add -q --detach "$nested" main
  git -C "$registry" worktree lock "$nested"
  lane=$(cd "$nested" && pwd -P)
  fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
  before=$(cat "$case_dir/state/unrelated.meta")
  mkdir -p "$case_dir/unrelated"
  teardown_fixture_start "$nested" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
  other_pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  case "$damage" in
    no-git) rm -f "$nested/.git" ;;
    deleted) rm -rf "$nested" ;;
  esac
  if [ -r "/proc/$pid/stat" ]; then
    identity="starttime=$(sed 's/.*) //' "/proc/$pid/stat" | awk '{print $20}')"
  else
    identity="lstart=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^ *//; s/ *$//')"
  fi
  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  local survived=0 other_survived=0
  kill -0 "$pid" 2>/dev/null && survived=1
  kill -0 "$other_pid" 2>/dev/null && other_survived=1
  teardown_fixture_stop "$pid"
  teardown_fixture_stop "$other_pid"
  expect_code 1 "$rc" "$name: teardown must refuse even with force"
  [ "$survived" -eq 1 ] || fail "$name: other lane process was killed"
  [ "$other_survived" -eq 1 ] || fail "$name: unrelated process was killed"
  [ "$(cat "$case_dir/state/unrelated.meta")" = "$before" ] \
    || fail "$name: unrelated task record changed"
  assert_present "$case_dir/state/task-x1.meta" "$name: task record removed"
  [ "$damage" = deleted ] || assert_present "$nested" "$name: nested lane removed"
  assert_grep "REFUSED: process $pid ($identity) " "$case_dir/stderr" \
    "$name: refusal does not name the pid and its start identity"
  assert_grep "matched path $lane" "$case_dir/stderr" \
    "$name: refusal does not name the matched path"
  if [ "$registrar" = sibling ] && [ "$damage" != none ]; then
    assert_grep "beneath scan root $(cd "$case_dir/wt" && pwd -P), whose ownership by task-x1 is not proven; preserving it and task task-x1 without signalling." "$case_dir/stderr" \
      "$name: refusal does not explain unproven custody"
    assert_not_contains "$(cat "$case_dir/stderr")" " inside registered nested worktree lane " \
      "$name: refusal falsely claims a known lane"
  else
    assert_grep " inside registered nested worktree lane $lane," "$case_dir/stderr" \
      "$name: refusal does not name the lane"
  fi
  assert_absent "$case_dir/state/task-x1.teardown-processes" \
    "$name: other lane recorded as a signal target"
}

assert_unknown_descendant_process_is_not_reaped() {
  local name=$1 location=$2 damage=$3 case_dir rc pid root matched identity survived=0
  case_dir=$(make_case "$name")
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  root="$case_dir/$location"
  if [ "$location" = tasktmp ]; then
    printf '%s\n' "tasktmp=$root" >> "$case_dir/state/task-x1.meta"
  fi
  mkdir -p "$root/dist"
  root=$(cd "$root" && pwd -P)
  matched="$root/dist"
  teardown_fixture_start "$matched" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  [ "$damage" != deleted ] || rm -rf "$matched"
  if [ -r "/proc/$pid/stat" ]; then
    identity="starttime=$(sed 's/.*) //' "/proc/$pid/stat" | awk '{print $20}')"
  else
    identity="lstart=$(LC_ALL=C ps -p "$pid" -o lstart= | sed 's/^ *//; s/ *$//')"
  fi
  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null && survived=1
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "$name: teardown must refuse even with force"
  [ "$survived" -eq 1 ] || fail "$name: unknown descendant process was killed"
  assert_present "$root" "$name: scan root removed"
  assert_present "$case_dir/state/task-x1.meta" "$name: task record removed"
  [ "$damage" = deleted ] || assert_present "$matched" "$name: descendant removed"
  assert_grep "REFUSED: process $pid ($identity) matched path $matched" "$case_dir/stderr" \
    "$name: refusal does not identify the process and matched path"
  assert_grep "beneath scan root $root, whose ownership by task-x1 is not proven; preserving it and task task-x1 without signalling." "$case_dir/stderr" \
    "$name: refusal does not explain unproven custody"
  assert_not_contains "$(cat "$case_dir/stderr")" " inside registered nested worktree lane " \
    "$name: refusal falsely claims a known lane"
  assert_absent "$case_dir/state/task-x1.teardown-processes" \
    "$name: unknown descendant recorded as a signal target"
}

NM_AGENT_PREFIX=com.kunchenguid.no-mistakes.daemon

# Fixture launchctl: `print` succeeds only while a label is loaded; `bootout`
# unloads it and, like launchd, ends the process the agent owns. Every call is
# logged. FAKE_LAUNCHCTL_BOOTOUT_FAILS=1 keeps the agent loaded, as a failed
# unload does.
add_fake_launchctl() {  # <case-dir>
  local case_dir=$1 fake="$1/fakebin/launchctl"
  mkdir -p "$case_dir/launchctl-loaded"
  : > "$case_dir/launchctl-calls"
  cat > "$fake" <<SH
#!/usr/bin/env bash
loaded="$case_dir/launchctl-loaded"
printf '%s\n' "\$*" >> "$case_dir/launchctl-calls"
label=\${2##*/}
case "\$1" in
  print) [ -e "\$loaded/\$label" ] || exit 113 ;;
  bootout)
    [ -e "\$loaded/\$label" ] || exit 113
    [ "\${FAKE_LAUNCHCTL_BOOTOUT_FAILS:-0}" != 1 ] || exit 5
    pid=\$(cat "\$loaded/\$label")
    [ -z "\$pid" ] || kill -KILL "\$pid" 2>/dev/null || true
    [ -z "\${FAKE_LAUNCHCTL_BOOTOUT_WRITES:-}" ] || printf 'late\\n' > "\$FAKE_LAUNCHCTL_BOOTOUT_WRITES"
    rm -f "\$loaded/\$label"
    ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$fake"
}

# Write the plist shape no-mistakes installs. Args: case_dir hash root [pid]
# A pid marks the agent as loaded and owning that process.
add_nm_launch_agent() {
  local case_dir=$1 hash=$2 root=$3 pid=${4:-} label
  label="$NM_AGENT_PREFIX.$hash"
  mkdir -p "$case_dir/launchagents"
  cat > "$case_dir/launchagents/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/no-mistakes</string>
    <string>daemon</string>
    <string>run</string>
    <string>--root</string>
    <string>$root</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$root</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
PLIST
  if [ -n "$pid" ]; then
    printf '%s\n' "$pid" > "$case_dir/launchctl-loaded/$label"
  fi
}

# Task-owned Docker stacks (bin/fm-task-docker-lib.sh owns the ownership rules).
# docker_store_add <store> <kind> <field>...: append one fixture object.
docker_store_add() {
  local store=$1
  shift
  local IFS=$'\t'
  printf '%s\n' "$*" >> "$store"
}

# docker_store_names <store> <kind>: the sorted names still in the store.
docker_store_names() {
  local store=$1 kind=$2 field=3
  [ "$kind" = volume ] && field=2
  awk -F'\t' -v k="$kind" -v f="$field" '$1 == k { print $f }' "$store" | LC_ALL=C sort | tr '\n' ' '
}

# One task-x1 teardown fixture with a store that mixes the task's own stacks
# (one per ownership rule) with every kind of object it must leave alone.
make_docker_case() {
  local name=$1 case_dir store
  case_dir=$(make_case "$name")
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/project/supabase"
  printf '%s\n' 'project_id = "vernant"' > "$case_dir/project/supabase/config.toml"
  store="$case_dir/docker-store"
  : > "$store"
  # The task's own: marker label, name, compose project name, compose working dir.
  docker_store_add "$store" container c-name task-x1-test-pg "" ""
  docker_store_add "$store" container c-label scratch-db "fm.task=task-x1" ""
  docker_store_add "$store" container c-proj1 task-x1-web-1 "com.docker.compose.project=task-x1" task-x1_default
  docker_store_add "$store" container c-proj2 task-x1-db-1 "com.docker.compose.project=task-x1" task-x1_default
  docker_store_add "$store" container c-path firstmate-db-1 "com.docker.compose.project=firstmate;com.docker.compose.project.working_dir=$case_dir/wt" firstmate_default
  # Not the task's: another task's marker, a near-miss name, a longer sibling
  # task's name, the shared Supabase stack, a stack from elsewhere, an unmarked
  # throwaway, and a name this task's id matches but another task's marker beats.
  docker_store_add "$store" container d-other other-db "fm.task=task-x2" task-x1_shared
  docker_store_add "$store" container d-near task-x10-pg "" ""
  docker_store_add "$store" container d-sib task-x1-v2-pg "" ""
  docker_store_add "$store" container d-supa supabase_db_vernant "com.docker.compose.project=vernant;com.supabase.cli.project=vernant" supabase_network_vernant
  docker_store_add "$store" container d-else other-compose-1 "com.docker.compose.project=other;com.docker.compose.project.working_dir=$case_dir/elsewhere" other_default
  docker_store_add "$store" container d-bare gre1675-throwaway-pg "" ""
  docker_store_add "$store" container d-beat task-x1-cache "fm.task=task-x2" ""
  docker_store_add "$store" network n-own task-x1_default "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-path firstmate_default "com.docker.compose.project=firstmate"
  docker_store_add "$store" network n-used task-x1_shared "fm.task=task-x2;com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supa supabase_network_vernant "com.docker.compose.project=vernant;com.supabase.cli.project=vernant"
  docker_store_add "$store" network n-else other_default "com.docker.compose.project=other"
  docker_store_add "$store" volume task-x1-data "fm.task=task-x1"
  docker_store_add "$store" volume task-x1_pgdata "com.docker.compose.project=task-x1"
  docker_store_add "$store" volume supabase_db_task-x1 "com.supabase.cli.project=task-x1"
  docker_store_add "$store" volume other-data "fm.task=task-x2"
  docker_store_add "$store" volume other_pgdata "com.docker.compose.project=other"
  docker_store_add "$store" volume supabase_db_vernant "com.supabase.cli.project=vernant"
  docker_store_add "$store" volume task-x1-unlabelled ""
  docker_store_add "$store" volume task-x1_beaten "fm.task=task-x2;com.docker.compose.project=task-x1"
  # A longer sibling task in the same home claims task-x1-v2-pg.
  fm_write_meta "$case_dir/state/task-x1-v2.meta" "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1-v2"
  printf '%s\n' "$case_dir"
}

configure_child_docker_race() {
  local case_dir=$1
  mkdir -p "$case_dir/child-producers"
  cp "$case_dir/fakebin/docker" "$case_dir/fakebin/docker-store"
  cat > "$case_dir/fakebin/docker" <<EOF
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = "network ls" ]; then
  if [ -f "$case_dir/current-child" ]; then
    child=\$(cat "$case_dir/current-child")
    if [ -e "$case_dir/child-producers/\$child.live" ]; then
      printf 'container\tc-late-%s\tlate-%s\tfm.task=%s\t\n' "\$child" "\$child" "\$child" >> "\${FM_FAKE_DOCKER_STORE:?}"
      printf '%s\n' "\$child" >> "$case_dir/race-created"
    fi
  fi
  if [ -f "$case_dir/arriving-containers" ]; then
    cat "$case_dir/arriving-containers" >> "\${FM_FAKE_DOCKER_STORE:?}"
    rm "$case_dir/arriving-containers"
  fi
fi
exec "$case_dir/fakebin/docker-store" "\$@"
EOF
  chmod +x "$case_dir/fakebin/docker"
}

assert_forced_child_docker_cleanup_and_retry() {
  local backend=$1 case_dir home store child rc
  case_dir=$(make_case "docker-children-$backend")
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  printf '%s\n' child-a > "$case_dir/current-child"
  : > "$store"
  docker_store_add "$store" container c-a owned-child-a "fm.task=child-a;com.docker.compose.project=derived-child-a" ""
  docker_store_add "$store" container c-b owned-child-b "com.docker.compose.project=child-stack;com.docker.compose.project.working_dir=$case_dir/child-b-wt" ""
  docker_store_add "$store" container c-foreign foreign-child "fm.task=somebody-else" ""
  docker_store_add "$store" network n-a child-a-network "com.docker.compose.project=derived-child-a"
  docker_store_add "$store" volume child-b-volume "fm.task=child-b"
  for child in child-a child-b; do
    : > "$case_dir/child-producers/$child.live"
    if [ "$backend" = orca ]; then
      fm_write_meta "$home/state/$child.meta" \
        "window=fm-$child" "endpoint_task_id=$child" \
        "worktree=$case_dir/$child-wt" "project=$case_dir/project" \
        "kind=ship" "mode=local-only" "backend=orca" \
        "terminal=$child-terminal" "orca_worktree_id=$case_dir/project::$case_dir/$child-wt"
    fi
  done
  cat > "$case_dir/fakebin/child-boundary" <<EOF
#!/usr/bin/env bash
for child in child-a child-b; do
  case "\$*" in
    *"\$child"*)
      case "\${1:-} \${2:-}" in
        kill-window*|kill-pane*|"terminal close")
          if [ -e "$case_dir/child-producers/\$child.live" ]; then
            printf 'container\tc-shutdown-%s\tshutdown-%s\tfm.task=%s\t\n' "\$child" "\$child" "\$child" >> "$store"
            rm "$case_dir/child-producers/\$child.live"
          fi
          printf '%s\n' "\$child" > "$case_dir/current-child"
          printf '%s\n' "\$child" >> "$case_dir/closed.log"
          printf '%s\n' '{"ok":true}'
          exit 0
          ;;
      esac
      if grep -Fq "owned-\$child" "$store"; then
        printf '%s\n' "\$child:dirty" >> "$case_dir/boundary.log"
      else
        printf '%s\n' "\$child:clean" >> "$case_dir/boundary.log"
      fi
      ;;
  esac
done
printf '%s\n' "\$*" >> "$case_dir/destructive.log"
printf '%s\n' '{"ok":true}'
EOF
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  kill-window|kill-pane) exec "$case_dir/fakebin/child-boundary" "\$@" ;;
esac
exit 0
EOF
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
exec "$case_dir/fakebin/child-boundary" "\$@"
EOF
  cat > "$case_dir/fakebin/orca" <<EOF
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "terminal close"|"worktree rm") exec "$case_dir/fakebin/child-boundary" "\$@" ;;
esac
printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}'
EOF
  chmod +x "$case_dir/fakebin/child-boundary" "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse" "$case_dir/fakebin/orca"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_RM_FAIL=owned-child-a \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$backend child: failed Docker cleanup must refuse retirement"
  assert_present "$case_dir/state/task-x1.meta" "$backend child: parent metadata retired"
  assert_present "$home/state/child-a.meta" "$backend child: child metadata retired"
  assert_present "$home/state/child-a.status" "$backend child: child status retired"
  assert_present "$case_dir/child-a-wt" "$backend child: child worktree removed"
  assert_grep child-a "$case_dir/closed.log" "$backend child: endpoint was not closed before Docker failure"
  assert_absent "$case_dir/destructive.log" "$backend child: worktree mutation preceded Docker cleanup"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_NETWORK_RM_FAIL=child-a-network \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/network-failure.stdout" 2> "$case_dir/network-failure.stderr" || rc=$?
  expect_code 1 "$rc" "$backend child: failed network removal must refuse retirement"
  assert_equals "foreign-child owned-child-b " "$(docker_store_names "$store" container)" \
    "$backend child: regression requires child-a container removal to succeed"
  assert_equals "child-a-network " "$(docker_store_names "$store" network)" \
    "$backend child: failed derived network did not survive"
  assert_grep 'docker_projects= derived-child-a' "$home/state/child-a.meta" \
    "$backend child: derived network identity was not retained"
  assert_present "$home/state/child-a.status" "$backend child: network failure retired status"
  assert_absent "$case_dir/destructive.log" "$backend child: network failure allowed worktree retirement"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "$backend child: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "$backend child: retry retained secondmate home"
  assert_absent "$case_dir/state/task-x1.meta" "$backend child: retry retained parent"
  assert_equals "foreign-child " "$(docker_store_names "$store" container)" "$backend child: wrong child objects survived"
  assert_equals "" "$(docker_store_names "$store" network)" "$backend child: child network survived"
  assert_equals "" "$(docker_store_names "$store" volume)" "$backend child: child volume survived"
  assert_absent "$case_dir/race-created" "$backend child: a live endpoint created a container during network cleanup"
  assert_grep child-a:clean "$case_dir/boundary.log" "$backend child: child-a Docker cleanup was not observed before destruction"
  assert_grep child-b:clean "$case_dir/boundary.log" "$backend child: child-b workdir cleanup was not observed before destruction"
  assert_no_grep dirty "$case_dir/boundary.log" "$backend child: destructive operation ran before its own Docker cleanup"
}

# Copy the public teardown script tree, then drop or blank one required file.
# Symlinks keep the copy cheap; an unreadable case replaces one link with a
# real mode-000 file so the probe is of the file itself.
prepare_teardown_source_copy() {  # <case-dir>
  local case_dir=$1 f base dest="$1/test-root/bin" s
  mkdir -p "$dest/backends"
  for f in "$ROOT"/bin/*; do
    base=$(basename "$f")
    if [ -d "$f" ]; then
      mkdir -p "$dest/$base"
      for s in "$f"/*; do
        ln -s "$s" "$dest/$base/$(basename "$s")"
      done
    else
      ln -s "$f" "$dest/$base"
    fi
  done
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/state/task-x1.status"
}

run_copied_teardown() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_HOME="${FM_HOME:-$case_dir/primary-home}" \
  FM_ROOT_OVERRIDE="$case_dir/test-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" task-x1 "$@"
}

assert_source_refusal_preserved_state() {  # <case-dir> <label>
  local case_dir=$1 label=$2
  [ "$rc" -ne 0 ] || fail "$label: teardown reported success after a required source disappeared"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: the refusal erased task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "$label: the refusal erased the task status record"
  [ ! -s "$case_dir/treehouse.log" ] || fail "$label: the refusal returned the local copy: $(cat "$case_dir/treehouse.log")"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "$label: the refusal still reported cleanup complete"
  fi
}

# Stop the run at its first unpushed-work inspection: past the early slot
# ownership proof and its project-custody release, before the reservation
# re-check, until the fresh allocator below has published the slot's new claim
# and lease.
add_window_swap_git_shim() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" log --oneline HEAD --not --remotes "*)
    if [ ! -e "$case_dir/in-window" ]; then
      : > "$case_dir/in-window"
      n=0
      while [ ! -e "$case_dir/swap-done" ]; do
        n=\$((n + 1)); [ "\$n" -lt 2000 ] || exit 1
        sleep 0.01
      done
    fi
    ;;
esac
exec "\${REAL_GIT_FOR_TEST:?}" "\$@"
SH
  chmod +x "$case_dir/fakebin/git"
}

# A concurrent fresh allocator for the reservation window: it waits until the
# run is inside the window, takes the project lock as bin/fm-spawn.sh does,
# replaces the lapsed slot claim through the real claim helper, publishes its
# own task record and pool lease, and releases custody. Sets
# WINDOW_ALLOCATOR_PID.
start_window_fresh_allocator() {
  local case_dir=$1 lock=$2 slot=$3
  FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" \
    bash -c '
      case_dir=$1 lock=$2 slot=$3 root=$4
      n=0
      while [ ! -e "$case_dir/in-window" ]; do
        n=$((n + 1)); [ "$n" -lt 3000 ] || exit 2
        sleep 0.05
      done
      . "$root/bin/fm-wake-lib.sh" || exit 3
      . "$root/bin/fm-project-lock-lib.sh" || exit 3
      fm_project_lock_acquire "$lock" "fresh spawn allocate" || exit 4
      wc -l < "$lock.holds" | tr -d " " > "$case_dir/holds-at-swap"
      fm_treehouse_slot_owner_claim "$slot" live-task "$case_dir/primary-home" || exit 5
      cp "$case_dir/live-task.meta.new" "$case_dir/state/live-task.meta" || exit 5
      cp "$case_dir/live-task.status.new" "$case_dir/state/live-task.status" || exit 5
      jq --arg holder live-task \
        "(.worktrees[] | select(.name == \"1\")) |= (.leased = true | .lease_holder = \$holder)" \
        "$case_dir/pool/treehouse-state.json" > "$case_dir/pool/treehouse-state.json.next" || exit 6
      mv "$case_dir/pool/treehouse-state.json.next" "$case_dir/pool/treehouse-state.json" || exit 6
      cp "${slot%/*}/.fm-slot-owner" "$case_dir/claim.after-swap" || exit 6
      cp "$case_dir/state/live-task.meta" "$case_dir/live-meta.before" || exit 6
      cp "$case_dir/state/live-task.status" "$case_dir/live-status.before" || exit 6
      fm_project_lock_release "$lock" || exit 7
      : > "$case_dir/swap-done"
    ' _ "$case_dir" "$lock" "$slot" "$ROOT" &
  WINDOW_ALLOCATOR_PID=$!
}

# Two ownership questions that a slot claim must never answer as one. Who the
# pool slot's claim names decides whether this teardown may administer that
# slot: reserve it, return it, drop its claim. Whether the retiring task's own
# copy is the slot itself or a worktree nested inside it decides whether that
# copy and the runtime inside it are the task's to prove and retire. A copy
# nested in a slot another task claims is still this task's own. Each row is
# one claimant by retiring copy; the landed variant must finish and the
# unlanded variant must refuse with its records and work kept.
make_ownership_table_case() {  # <name> <claimant> <shape> <landing>
  local name=$1 claimant=$2 shape=$3 landing=$4 case_dir slot own holder
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/home/state" "$case_dir/pool/1"
  rm -f "$case_dir/config/backlog-backend"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
  slot=$(cd "$case_dir/pool/1/project" && pwd -P)
  OWN_TABLE_CASE=$case_dir
  OWN_TABLE_SLOT=$slot
  if [ "$shape" = nested ]; then
    own="$slot/.claude/worktrees/x"
    mkdir -p "${own%/*}"
    git -C "$case_dir/project" worktree add -q -b fm/task-x1-v2 "$own" main
    OWN_TABLE_BRANCH=fm/task-x1-v2
  else
    own=$slot
    OWN_TABLE_BRANCH=fm/task-x1
  fi
  OWN_TABLE_COPY=$own
  if [ "$landing" = landed ]; then
    git -C "$own" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'shippable work'
    git -C "$own" push -q origin "$OWN_TABLE_BRANCH"
    git -C "$case_dir/project" fetch -q origin
  else
    printf 'undelivered\n' > "$own/undelivered.txt"
    git -C "$own" add undelivered.txt
    git -C "$own" -c user.email=t@t -c user.name=t commit -q -m 'undelivered task work'
  fi
  case "$claimant" in
    this) holder=task-x1 ;;
    visible) holder=live-task ;;
    unregistered) holder=ghost-task ;;
  esac
  if [ "$claimant" != this ]; then
    git -C "$slot" checkout -q -b fm/live-task main 2>/dev/null \
      || git -C "$slot" checkout -q --detach main
    printf 'claimant untracked work\n' > "$slot/scratch.txt"
  fi
  printf 'task=%s\nhome=%s\n' "$holder" "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' \
    "$slot" "$holder" > "$case_dir/pool/treehouse-state.json"
  if [ "$claimant" = visible ]; then
    fm_write_meta "$case_dir/state/live-task.meta" \
      "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
      "worktree=$slot" "project=$case_dir/project" "kind=ship" "spawn_gen=live"
    printf 'live task\n' > "$case_dir/state/live-task.status"
  fi
  if [ "$shape" = nested ]; then
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$own" "branch=fm/task-x1-v2" "project=$case_dir/project" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1" \
      "prior_worktree=$slot"
  else
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$slot" "branch=fm/task-x1" "project=$case_dir/project" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
  fi
  printf 'unfinished task\n' > "$case_dir/state/task-x1.status"
  seed_backlog_in_flight "$case_dir"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/endpoint.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux"
}

# make_nested_slot_case <name> <shape>: a ship whose copies are a Treehouse
# pool slot S it claims and a clean worktree N nested in S on fm/task-x1-v2,
# both at the landed main. shape=enclosing records worktree=N and
# prior_worktree=S (the task moved into N); shape=reverse records worktree=S and
# prior_worktree=N (the task moved back). Sets NESTED_CASE, NESTED_SLOT and
# NESTED_COPY.
make_nested_slot_case() {  # <name> <shape> <nested-relative-path> [mode]
  local case_dir mode=${4:-no-mistakes}
  case_dir=$(make_case "$1")
  NESTED_CASE=$case_dir
  mkdir -p "$case_dir/home/state" "$case_dir/pool/1"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' \
    "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
  NESTED_SLOT=$(cd "$case_dir/pool/1/project" && pwd -P)
  NESTED_COPY="$NESTED_SLOT/$3"
  mkdir -p "${NESTED_COPY%/*}"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1-v2 "$NESTED_COPY" main
  printf 'task=task-x1\nhome=%s\n' "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  if [ "$2" = enclosing ]; then
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$NESTED_COPY" "branch=fm/task-x1-v2" "project=$case_dir/project" \
      "kind=ship" "mode=$mode" "spawn_gen=teardown-test-task-x1" \
      "prior_worktree=$NESTED_SLOT"
  else
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$NESTED_SLOT" "branch=fm/task-x1" "project=$case_dir/project" \
      "kind=ship" "mode=$mode" "spawn_gen=teardown-test-task-x1" \
      "prior_worktree=$NESTED_COPY"
  fi
}

# stale_lock_late_work_treehouse <case-dir>: a fake treehouse whose return
# fails on the slot's index.lock after writing late.txt into the slot, as a
# process still running there would, and otherwise logs the return.
stale_lock_late_work_treehouse() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
lock=\$(git -C "\$wt" rev-parse --path-format=absolute --git-path index.lock 2>/dev/null || true)
if [ -n "\$lock" ] && [ -e "\$lock" ]; then
  printf 'late slot work\n' > "\$wt/late.txt"
  echo "fatal: Unable to create '\$lock': File exists." >&2
  exit 128
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  add_lsof_no_holder "$case_dir"
}

# nested_pipeline_input_case <name>: make_nested_slot_case's enclosing shape
# whose nested current copy was the input of the pipeline run behind merged
# PR 7. The pipeline rewrote the copy's one commit, so only the no-mistakes run
# record proves the copy landed (pipeline_input_is_local_head in
# bin/fm-teardown.sh).
nested_pipeline_input_case() {  # <name>
  local case_dir tmp pr_head
  make_nested_slot_case "$1" enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  printf '%s\n' alpha > "$NESTED_COPY/a.txt"
  git -C "$NESTED_COPY" add a.txt
  git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm "add a"
  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1-v2
  printf '%s\n' alpha-reviewed > "$tmp/a.txt"
  git -C "$tmp" add -- a.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add a"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  write_nm_run_record "$case_dir" run-1 https://github.com/example/repo/pull/7 \
    "$(git -C "$NESTED_COPY" rev-parse HEAD)" "$pr_head"
}

# A fake tmux whose window cannot be closed while <case-dir>/endpoint-stuck
# exists: kill-window fails and the window inventory still lists it. Without
# the file every call succeeds silently.
stuck_endpoint_tmux() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -e "$case_dir/endpoint-stuck" ]; then
  case "\${1:-}" in
    kill-window) exit 1 ;;
    list-windows) printf '%s\n' fm-task-x1; exit 0 ;;
  esac
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

# A fake treehouse whose return fails with a plain error while
# <case-dir>/fail-return exists, and otherwise logs the return.
fail_switch_treehouse() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
if [ -e "$case_dir/fail-return" ]; then
  echo "treehouse: simulated return failure" >&2
  exit 1
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# make_foreign_copy_case <name> [launcher-pid]: a pool slot the task claims with
# a clean copy nested in it at .claude/worktrees/fc-one that no record of the
# task names, at the landed main on branch fm/task-x1-v2. A launcher pid locks
# the copy as Vernant's start_task_worktree.py does. Sets FOREIGN_CASE,
# FOREIGN_SLOT and FOREIGN_COPY. The slot holds a stub scripts/git-stability/
# closeout_pr.py (kept out of the slot's status through info/exclude) that
# stands in for Vernant's driver: it logs its directory and arguments, and with
# FM_STUB_CLOSEOUT=ok unlocks and plainly removes only a copy under the scratch
# root, as the real driver's cleanup does; any other value refuses with exit 3.
# With FM_STUB_LOCK naming the shared project lock, it also records in
# closeout.lock-state whether that lock is held while it runs.
# vernant-python, the interpreter run_foreign_teardown names, runs it as a shell
# script.
make_foreign_copy_case() {
  local case_dir tmp_real exclude
  make_nested_slot_case "$1" reverse .claude/worktrees/fc-one
  case_dir=$NESTED_CASE
  FOREIGN_CASE=$case_dir
  FOREIGN_SLOT=$NESTED_SLOT
  FOREIGN_COPY=$NESTED_COPY
  mkdir -p "$case_dir/home"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$NESTED_SLOT" "branch=fm/task-x1" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
  [ -z "${2:-}" ] || git -C "$case_dir/project" worktree lock \
    --reason "vernant-session-active owner=launcher:$2 launcher=$2" "$NESTED_COPY"
  add_lsof_no_holder "$case_dir"
  tmp_real=$(cd "$TMP_ROOT" && pwd -P)
  exclude=$(git -C "$NESTED_SLOT" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' scripts/ .venv/ >> "$exclude"
  mkdir -p "$NESTED_SLOT/scripts/git-stability"
  cat > "$NESTED_SLOT/scripts/git-stability/closeout_pr.py" <<SH
printf '%s|%s\n' "\$PWD" "\$*" >> "$case_dir/closeout.log"
if [ -n "\${FM_STUB_LOCK:-}" ]; then
  if [ -d "\$FM_STUB_LOCK" ]; then echo held; else echo free; fi >> "$case_dir/closeout.lock-state"
fi
if [ -n "\${FM_STUB_CLOSEOUT_OUTPUT:-}" ]; then
  cat "\$FM_STUB_CLOSEOUT_OUTPUT" >&2
fi
if [ "\${FM_STUB_CLOSEOUT:-ok}" != ok ]; then
  echo '{"allowed": false, "reason": "stub_refusal"}'
  exit 3
fi
case "\$2" in "$tmp_real"/*) ;; *) echo "stub refuses a path outside the scratch root" >&2; exit 4 ;; esac
git worktree unlock "\$2" && git worktree remove "\$2"
SH
  printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$case_dir/vernant-python"
  chmod +x "$case_dir/vernant-python"
}

# A pid that exited, so a creation lock naming it has no live launcher.
dead_launcher_pid() {
  sleep 0.1 &
  FOREIGN_DEAD_PID=$!
  wait "$FOREIGN_DEAD_PID" 2>/dev/null || true
}

FOREIGN_TEARDOWN_ARGS=()

run_foreign_teardown() {
  local rc_var=$1 case_dir=$FOREIGN_CASE status=0
  shift
  env FM_TEARDOWN_VERNANT_PYTHON="$case_dir/vernant-python" "$@" FM_HOME="$case_dir/home" \
    FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    NM_HOME="$case_dir/nm" PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 ${FOREIGN_TEARDOWN_ARGS[@]+"${FOREIGN_TEARDOWN_ARGS[@]}"} > "$case_dir/stdout" 2> "$case_dir/stderr" || status=$?
  printf -v "$rc_var" '%s' "$status"
}

# Nothing moved: the copy, its branch and the slot are intact and no closeout
# or pool return ran.
assert_foreign_copy_untouched() {  # <label>
  local case_dir=$FOREIGN_CASE
  assert_present "$FOREIGN_COPY/.git" "$1: the foreign copy was removed"
  git -C "$case_dir/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
    || fail "$1: the foreign copy's branch was deleted"
  assert_absent "$case_dir/closeout.log" "$1: the closeout driver ran"
  assert_absent "$case_dir/treehouse.log" "$1: the pool slot was returned"
  assert_present "$case_dir/state/task-x1.meta" "$1: the task record was removed"
}

# assert_foreign_ignored_preserved_and_released <label> <copy>: the task closed,
# the copy is gone with its unique ignored file kept and hashed in the task's data
# directory, and the slot was returned, as the foreign-copy proof has always done.
assert_foreign_ignored_preserved_and_released() {
  local label=$1 copy=$2 preserved sums hash
  assert_absent "$copy" "$label: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "$label: the slot was not returned"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record survived"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "$label: a released copy was written to the held-copy record"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "$label: a close that succeeded printed a refusal"
  preserved=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -name unique.dat -type f 2>/dev/null | head -n 1)
  [ -n "$preserved" ] || fail "$label: the ignored file was not preserved in the task data directory"
  assert_equals "only here" "$(cat "$preserved")" "$label: the preserved file changed"
  sums="$(dirname "$preserved")/SHA256SUMS"
  assert_present "$sums" "$label: no SHA-256 manifest was written"
  hash=$(shasum -a 256 "$preserved" | awk '{print $1}')
  assert_grep "$hash  unique.dat" "$sums" "$label: the manifest does not record the preserved content"
}

# run_printed_route <route> <rc-var>: runs a printed completing command through
# the real teardown with only this fixture's external-tool and home-layout
# environment, leaving its streams in the case.
run_printed_route() {
  local route=$1 rc_var=$2 status=0
  env FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/vernant-python" \
    FM_ROOT_OVERRIDE="$FOREIGN_CASE/code-root" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    FM_DATA_OVERRIDE="$FOREIGN_CASE/data" FM_CONFIG_OVERRIDE="$FOREIGN_CASE/config" \
    NM_HOME="$FOREIGN_CASE/nm" PATH="$FOREIGN_CASE/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    bash -c "$route" > "$FOREIGN_CASE/completed.stdout" 2> "$FOREIGN_CASE/completed.stderr" || status=$?
  printf -v "$rc_var" '%s' "$status"
}

# A forced or legacy-record original run cannot be completed by the printed
# command, which carries neither flag, so its preservation refusal ends in a
# human-only exit with no command and no flag anywhere in the envelope lines.
assert_preservation_refusal_without_route() {  # <label>
  local label=$1 envelope
  assert_grep 'REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=ignored-bytes-preserved ' "$FOREIGN_CASE/stderr" "$label: the refusal is not typed"
  assert_no_grep 'completing-command:' "$FOREIGN_CASE/stderr" "$label: a command that cannot complete this run was printed"
  assert_grep 'human-only-exit: This run was forced or used a legacy record' "$FOREIGN_CASE/stderr" "$label: the run was not named in the human-only exit"
  envelope=$(cat "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr")
  case "$envelope" in
    *--force*|*--drop-file*|*--legacy-record*) fail "$label: the output printed a force or legacy flag: $envelope" ;;
  esac
  jq -es 'length == 1 and .[0].rule_id == "ignored-bytes-preserved" and .[0].outcome == "blocked" and .[0].exit_kind == "human-only" and .[0].exit_printed' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail "$label: expected exactly one human-only event: $(cat "$FOREIGN_CASE/home/state/friction.jsonl")"
  assert_foreign_copy_untouched "$label"
  assert_equals 'unique retained bytes' "$(cat "$FOREIGN_COPY/unique.dat")" "$label: unproven ignored bytes changed"
}

# run_preservation_refusal <ownership> <name> <record> [teardown-flag...]: a
# teardown run with the given flags over a backlog-tracked task whose ignored-file
# preservation fails; a legacy <record> predates spawn_gen.
run_preservation_refusal() {
  local ownership=$1 name=$2 record=$3 rc exclude
  shift 3
  if [ "$ownership" = own ]; then
    dead_launcher_pid
    make_own_locked_copy_case "$name-own" enclosing "$FOREIGN_DEAD_PID"
  elif [ "$ownership" = inside ]; then
    dead_launcher_pid
    make_own_locked_copy_case "$name-inside" enclosing "$FOREIGN_DEAD_PID"
    git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$FOREIGN_COPY/.claude/worktrees/fc-inner" main
    FOREIGN_COPY=$FOREIGN_COPY/.claude/worktrees/fc-inner
  else
    make_foreign_copy_case "$name-foreign"
  fi
  if [ "$record" = legacy ]; then
    grep -v '^spawn_gen=' "$FOREIGN_CASE/state/task-x1.meta" > "$FOREIGN_CASE/state/task-x1.meta.new"
    mv "$FOREIGN_CASE/state/task-x1.meta.new" "$FOREIGN_CASE/state/task-x1.meta"
  fi
  seed_backlog_in_flight "$FOREIGN_CASE"
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'unique retained bytes\n' > "$FOREIGN_COPY/unique.dat"
  cat > "$FOREIGN_CASE/fakebin/cp" <<SH
#!/usr/bin/env bash
case " \$* " in *nested-copy-preserved*) exit 1 ;; esac
exec "$(command -v cp)" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/cp"
  FOREIGN_TEARDOWN_ARGS=("$@")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 1 "$rc" "$name-$ownership: failed preservation must keep refusing with the same exit: $(cat "$FOREIGN_CASE/stderr")"
}

# A proof failure that needs a human decision is a typed refusal with a
# human-only question and one event; it is not a plain error and not a second
# event from the registered-copy custody refusal that repeats it.
# The registered-copy wrapper tells the reader to follow what was printed above
# for each listed copy, so that step line must exist before it.
assert_wrapper_follows_step() {  # <label> <step-line-prefix>
  local label=$1 step_line wrapper_line
  step_line=$(grep -n -m1 -- "^$2" "$FOREIGN_CASE/stderr" | cut -d: -f1)
  wrapper_line=$(grep -n -m1 -F 'Keep each listed copy and its records. For each one,' "$FOREIGN_CASE/stderr" | cut -d: -f1)
  [ -n "$wrapper_line" ] || fail "$label: the registered-copy refusal did not tell the reader to follow the printed step"
  [ -n "$step_line" ] && [ "$step_line" -lt "$wrapper_line" ] || fail "$label: no '$2' line precedes the registered-copy refusal's pointer to it"
}

assert_typed_copy_refusal() {  # <label> <rule>
  local label=$1 rule=$2
  assert_wrapper_follows_step "$label" 'human-only-exit: '
  assert_grep "REFUSED: guard=FM-TEARDOWN-PRESERVATION rule=$rule " "$FOREIGN_CASE/stderr" "$label: the refusal is not typed"
  assert_grep 'human-only-exit: ' "$FOREIGN_CASE/stderr" "$label: the refusal printed no question"
  assert_no_grep "error: foreign copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "$label: a policy refusal was printed as a plain error"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "$label: the custody refusal changed"
  jq -es --arg rule "$rule" 'length == 1 and .[0].rule_id == $rule and .[0].outcome == "blocked" and .[0].exit_kind == "human-only" and .[0].exit_printed' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail "$label: expected exactly one typed human-only event"
  assert_present "$FOREIGN_COPY" "$label: the copy was removed"
  assert_absent "$FOREIGN_CASE/closeout.log" "$label: the closeout driver ran"
  assert_absent "$FOREIGN_CASE/treehouse.log" "$label: the pool slot was returned"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
}

# The landing check is typed copy-landed only when it was answered. Each stub
# makes one probe unable to answer; the control gets a real "open, not merged".
make_unlanded_foreign_copy_with_pr() {  # <name>
  make_foreign_copy_case "$1"
  printf 'pr=https://github.com/example/repo/pull/7\n' >> "$FOREIGN_CASE/state/task-x1.meta"
  printf 'unlanded\n' > "$FOREIGN_COPY/unlanded.txt"
  git -C "$FOREIGN_COPY" add unlanded.txt
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work'
}

assert_plain_landing_error() {  # <label> <cause-fragment>
  assert_grep "error: foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its landing could not be checked (" "$FOREIGN_CASE/stderr" "$1: the plain error did not say the landing could not be checked"
  assert_grep "$2" "$FOREIGN_CASE/stderr" "$1: the plain error did not name its cause"
  assert_no_grep 'rule=copy-landed' "$FOREIGN_CASE/stderr" "$1: an unanswered landing check was typed as not landed"
  assert_absent "$FOREIGN_CASE/home/state/friction.jsonl" "$1: an unanswered landing check recorded a policy event"
  assert_wrapper_follows_step "$1" 'error: '
  assert_foreign_copy_untouched "$1"
}



# held_ignored_file <copy> [name]: a unique ignored file only <copy> holds.
held_ignored_file() {
  local copy=$1 name=${2:-unique.dat} exclude
  exclude=$(git -C "$copy" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' "$name" >> "$exclude"
  printf 'only here\n' > "$copy/$name"
}

# held_foreign_unlanded <copy> [name]: a commit on no remote and not on main.
held_foreign_unlanded() {
  local copy=$1 name=${2:-unlanded.txt}
  printf 'unlanded\n' > "$copy/$name"
  git -C "$copy" add "$name"
  git -C "$copy" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work'
}

# held_fingerprint <copy>: every path under <copy> with its mode, size and
# modification time, the sha256 of every file, and the copy's git admin files, so
# any delete, move, rewrite or chmod of the foreign copy shows.
held_fingerprint() {
  local copy=$1 admin
  admin=$(git -C "$copy" rev-parse --absolute-git-dir)
  (cd "$copy" && LC_ALL=C find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ldn
    LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  (cd "$admin" && for f in HEAD locked gitdir commondir; do
    if [ -e "$f" ]; then printf '%s ' "$f"; shasum -a 256 < "$f"; fi
  done)
}

# held_snapshot <case>: everything a held close must leave as it found it.
held_snapshot() {
  local case_dir=$1 copy
  shift
  for copy in "$@"; do
    held_fingerprint "$copy" > "$case_dir/held-before.$(basename "$copy")"
  done
  cp "$case_dir/pool/treehouse-state.json" "$case_dir/lease-before"
  cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/claim-before"
  git -C "$case_dir/project" worktree list --porcelain > "$case_dir/registrations-before"
}

# held_assert_copies_untouched <label> <case> <copy>...: the copies are
# byte-identical and registered, and the slot is still claimed and unreturned.
# held_assert_untouched adds that Treehouse's lease record is unchanged.
held_assert_untouched() {
  local label=$1 case_dir=$2
  held_assert_copies_untouched "$@"
  cmp -s "$case_dir/lease-before" "$case_dir/pool/treehouse-state.json" || fail "$label: the slot's lease changed"
}

held_assert_copies_untouched() {
  local label=$1 case_dir=$2 copy
  shift 2
  for copy in "$@"; do
    held_fingerprint "$copy" | cmp -s - "$case_dir/held-before.$(basename "$copy")" \
      || fail "$label: the foreign copy $copy changed"
  done
  cmp -s "$case_dir/claim-before" "$case_dir/pool/1/.fm-slot-owner" || fail "$label: the slot's claim changed"
  git -C "$case_dir/project" worktree list --porcelain | cmp -s - "$case_dir/registrations-before" \
    || fail "$label: copy registrations changed"
  assert_absent "$case_dir/treehouse.log" "$label: the pool slot was returned"
  assert_absent "$case_dir/closeout.log" "$label: the closeout driver ran"
}

# held_assert_closed <label>: the task's own closure completed.
held_assert_closed() {
  local label=$1 case_dir=$FOREIGN_CASE
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record survived"
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" "$label: a pending-return marker survived"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "$label: the backlog item is not done: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "$label: the closed backlog item does not carry the merged PR"
  assert_grep "the slot return is deferred" "$case_dir/stdout" "$label: the output did not say the slot return is deferred"
}

make_held_case() {  # <name>
  make_foreign_copy_case "$1"
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$FOREIGN_CASE/state/task-x1.meta"
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
  seed_backlog_in_flight "$FOREIGN_CASE"
}

# held_plain_get_slot <case-dir>: the case's slot holds only the process lease a
# plain treehouse get records (leased=false), with a Treehouse stand-in that
# models lease and return. Its lease command fails while <case-dir>/lease-fails
# exists, and reports no lease command while <case-dir>/no-lease-command exists.
# Its status lists <case-dir>/status.json while that exists, as for a project
# whose current pool is another folder, else the case's own pool.
# Lease calls land in lease.log and returns in treehouse.log.
held_plain_get_slot() {
  local case_dir=$1
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$FOREIGN_SLOT" > "$case_dir/pool/treehouse-state.json"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
state="$case_dir/pool/treehouse-state.json"
if [ "\${1:-}" = lease ] && [ "\${2:-}" = --help ]; then
  [ ! -e "$case_dir/no-lease-command" ] || { echo 'Error: unknown command "lease" for "treehouse"' >&2; exit 1; }
  printf 'Usage:\n  treehouse lease <name> [flags]\n\nFlags:\n      --lease-holder string   Optional label recorded as the lease holder\n'
  exit 0
fi
case "\${1:-}" in
  status)
    if [ -f "$case_dir/status.json" ]; then
      cat "$case_dir/status.json"
    else
      jq -c '[.worktrees[]? | {name, path, lease_holder: (.lease_holder // ""), processes: []}]' "\$state"
    fi
    ;;
  lease)
    printf '%s\n' "\$*" >> "$case_dir/lease.log"
    [ ! -e "$case_dir/lease-fails" ] || { echo "Error: the lease could not be recorded" >&2; exit 1; }
    jq --arg name "\$2" --arg holder "\$4" '(.worktrees[] | select(.name == \$name)) |= (.leased = true | .lease_holder = \$holder)' \\
      "\$state" > "\$state.next" && mv "\$state.next" "\$state"
    ;;
  return) printf '%s\n' "\$*" >> "$case_dir/treehouse.log" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# start_foreign_session_case <name> <shape>: a foreign-copy case whose task
# session runs in the slot and whose creation lock names a launcher. shape agent:
# the launcher is the session itself; child: a descendant of the session whose
# cwd is /; stubborn: that descendant, ignoring TERM; unrelated: a process outside
# the session. The session is not told to take its descendant down. Sets
# FOREIGN_AGENT and FOREIGN_LAUNCHER. The stub lsof reports the session in the
# slot while it lives, as lsof reports a process by its cwd.
start_foreign_session_case() {
  local shape=$2 pidfile i
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  local child_script='my $child = fork(); if (!$child) { $SIG{TERM} = "IGNORE" if $ARGV[1]; chdir "/"; exec "sleep", "300"; } $SIG{CHLD} = "IGNORE"; open my $fh, ">", $ARGV[0]; print $fh $child; close $fh; sleep 300;'
  make_foreign_copy_case "$1"
  pidfile=$FOREIGN_CASE/launcher-pid
  case "$shape" in
    child|stubborn)
      teardown_fixture_start "$FOREIGN_SLOT" KILL perl -e "$child_script" "$pidfile" "$([ "$shape" = stubborn ] && echo 1 || true)"
      FOREIGN_AGENT=$TEARDOWN_FIXTURE_PID
      for i in $(seq 100); do [ -s "$pidfile" ] && break; sleep 0.05; done
      FOREIGN_LAUNCHER=$(cat "$pidfile")
      ;;
    *)
      teardown_fixture_start "$FOREIGN_SLOT" KILL sleep 300
      FOREIGN_AGENT=$TEARDOWN_FIXTURE_PID
      FOREIGN_LAUNCHER=$FOREIGN_AGENT
      if [ "$shape" = unrelated ]; then
        sleep 300 &
        FOREIGN_LAUNCHER=$!
      fi
      ;;
  esac
  sleep 1
  git -C "$FOREIGN_CASE/project" worktree lock \
    --reason "vernant-session-active owner=launcher:$FOREIGN_LAUNCHER launcher=$FOREIGN_LAUNCHER" "$FOREIGN_COPY"
  cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) if kill -0 $FOREIGN_AGENT 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $FOREIGN_AGENT '$FOREIGN_SLOT'; fi; exit 0 ;;
esac
exit 1
SH
}

# make_own_locked_copy_case <name> <enclosing|reverse> [launcher-pid]: the foreign
# copy case with the copy recorded as the task's own. enclosing records the copy as
# worktree= and the slot as prior_worktree=; reverse records the slot as worktree=
# and the copy as prior_worktree=. A launcher pid locks the copy as Vernant's
# start_task_worktree.py does. Sets the FOREIGN_* variables and snapshots Treehouse's
# state and the slot claim.
make_own_locked_copy_case() {
  make_foreign_copy_case "$1" ${3:+"$3"}
  if [ "$2" = enclosing ]; then
    fm_write_meta "$FOREIGN_CASE/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$FOREIGN_COPY" "branch=fm/task-x1-v2" "project=$FOREIGN_CASE/project" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1" \
      "prior_worktree=$FOREIGN_SLOT"
  else
    fm_write_meta "$FOREIGN_CASE/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$FOREIGN_SLOT" "branch=fm/task-x1" "project=$FOREIGN_CASE/project" \
      "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1" \
      "prior_worktree=$FOREIGN_COPY"
  fi
  cp "$FOREIGN_CASE/pool/treehouse-state.json" "$FOREIGN_CASE/treehouse-state.before"
  cp "$FOREIGN_CASE/pool/1/.fm-slot-owner" "$FOREIGN_CASE/slot-owner.before"
}

# A refused teardown of an own copy changed nothing: the copy is still locked and
# registered, its branch, the task record, the slot claim and Treehouse's lease are
# intact, and no pool return ran.
assert_own_locked_copy_untouched() {  # <label>
  local case_dir=$FOREIGN_CASE
  assert_foreign_copy_untouched "$1"
  git -C "$case_dir/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
    || fail "$1: the copy is no longer registered"
  git -C "$case_dir/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked' \
    || fail "$1: the copy is no longer locked"
  cmp -s "$case_dir/treehouse-state.before" "$case_dir/pool/treehouse-state.json" \
    || fail "$1: Treehouse's lease record changed"
  cmp -s "$case_dir/slot-owner.before" "$case_dir/pool/1/.fm-slot-owner" \
    || fail "$1: the slot claim changed"
}

# A pool-slot ship whose only copy is the slot itself, recorded the way spawn
# publishes it, with a Treehouse stand-in that models the installed CLI: lease
# resolves the pool from the working directory's repository and records a
# durable holder; return releases it. With current-folder, the pool folder has
# the name Treehouse gives the project's current pool, <repo>-<first six hex
# digits of the SHA-256 of the origin URL>, and pool/ links to it.
make_lease_modeling_pool_case() {  # <name> <state-json-or-empty> [kind] [current-folder]
  local case_dir slot kind=${3:-ship} hash
  case_dir=$(make_case "$1")
  if [ "${4:-}" = current-folder ]; then
    hash=$(git -C "$case_dir/project" remote get-url origin | tr -d '\n' | shasum -a 256)
    mkdir -p "$case_dir/project-${hash:0:6}"
    ln -s "project-${hash:0:6}" "$case_dir/pool"
  fi
  slot="$case_dir/pool/1/project"
  mkdir -p "${slot%/*}" "$case_dir/primary-home/state"
  git -C "$case_dir/project" worktree add -q -b fm/pool-root "$slot" main
  slot=$(cd "$slot" && pwd -P)
  if [ -n "$2" ]; then
    printf '%s\n' "${2//@SLOT@/$slot}" > "$case_dir/pool/treehouse-state.json"
  else
    printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" \
      > "$case_dir/pool/treehouse-state.json"
  fi
  printf 'task=task-x1\nhome=%s\n' "$case_dir/primary-home" > "${slot%/*}/.fm-slot-owner"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=firstmate:fm-task-x1' 'endpoint_task_id=task-x1' \
    "worktree=$slot" "project=$case_dir/project" "kind=$kind" 'mode=local-only' \
    'spawn_gen=teardown-test-task-x1' 'branch=fm/pool-root'
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = lease ] && [ "${2:-}" = --help ]; then
  # Capability query only: an installed Treehouse that predates the lease
  # command rejects it as an unknown command.
  if [ -n "${FM_POOL_NO_LEASE:-}" ]; then
    echo 'Error: unknown command "lease" for "treehouse"' >&2
    exit 1
  fi
  printf 'Usage:\n  treehouse lease <name> [flags]\n\nFlags:\n      --lease-holder string   Optional label recorded as the lease holder\n'
  exit 0
fi
# The pool a name resolves against is the one the project's origin selects
# today: FM_POOL_CURRENT_STATE names that pool's state file when a case moves
# the project to a new pool folder, else the first pool a registered copy of
# the repository lives in.
current_state() {
  local line wt
  if [ -n "${FM_POOL_CURRENT_STATE:-}" ]; then
    printf '%s\n' "$FM_POOL_CURRENT_STATE"
    return 0
  fi
  while IFS= read -r line; do
    case "$line" in "worktree "*) wt=${line#worktree } ;; *) continue ;; esac
    [ -f "${wt%/*/*}/treehouse-state.json" ] || continue
    printf '%s\n' "${wt%/*/*}/treehouse-state.json"
    return 0
  done < <(git worktree list --porcelain 2>/dev/null)
  return 1
}
printf '%s\n' "$*" >> "$FM_POOL_CASE/treehouse.log"
case "${1:-}" in
  status)
    [ -z "${FM_POOL_STATUS_FAILS:-}" ] || { echo 'Error: cannot read the pool' >&2; exit 1; }
    state=$(current_state) || { printf '[]\n'; exit 0; }
    jq -c --arg busy "${FM_POOL_BUSY_SLOT:-}" '[.worktrees[]? | {name, path, status: (if .leased == true then "leased" else "available" end),
      lease_holder: (.lease_holder // ""), processes: (if .path == $busy then [{pid: 4242}] else [] end)}]' "$state"
    ;;
  lease)
    if [ -n "${FM_POOL_NO_LEASE:-}" ]; then
      echo 'Error: unknown command "lease" for "treehouse"' >&2
      exit 1
    fi
    [ "$#" -eq 4 ] && [ "$3" = --lease-holder ] || exit 2
    state=$(current_state) || { echo "Error: no worktree named \"$2\" in pool" >&2; exit 1; }
    holder=$(jq -r --arg name "$2" '.worktrees[] | select(.name == $name and .leased == true) | .lease_holder' "$state")
    [ -z "$holder" ] || { echo "Error: worktree $2 is already leased (holder: \"$holder\")" >&2; exit 1; }
    jq --arg name "$2" --arg holder "$4" \
      '(.worktrees[] | select(.name == $name)) |= (.leased = true | .lease_holder = $holder)' \
      "$state" > "$state.next" && mv "$state.next" "$state"
    ;;
  return)
    shift
    slot= want_holder=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --force) ;;
        --if-lease-holder) want_holder=$2; shift ;;
        *) slot=$1 ;;
      esac
      shift
    done
    state="${slot%/*/*}/treehouse-state.json"
    if jq -e . "$state" >/dev/null 2>&1; then
      if [ -n "$want_holder" ]; then
        have=$(jq -r --arg slot "$slot" '.worktrees[] | select(.path == $slot) | .lease_holder // ""' "$state")
        [ "$have" = "$want_holder" ] || { echo "Error: lease holder is \"$have\", not \"$want_holder\"" >&2; exit 1; }
      fi
      jq --arg slot "$slot" '(.worktrees[] | select(.path == $slot)) |= (.leased = false | del(.lease_holder))' \
        "$state" > "$state.next" && mv "$state.next" "$state"
    fi
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/treehouse"
  POOL_CASE=$case_dir
  POOL_SLOT=$slot
  POOL_LOCK=$(FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' \
    _ "$ROOT" "$case_dir/project")
}

# assert_no_log_line <extended-regex> <file> <msg>: no line of <file> matches.
assert_no_log_line() {
  ! grep -Eq -- "$1" "$2" || fail "$3"
}

# A pool-slot ship whose copy lives in a superseded pool folder: Treehouse
# derives a pool folder from the project's origin URL, so repointing origin
# leaves the recorded copy in the old folder, where its state reads unleased,
# while the project's current pool is another folder whose slots reuse the old
# slot names. <current-state-json> is that current pool's state, with @SLOT1@
# and @SLOT2@ standing for its two slot paths. Sets SUPER_CASE, SUPER_SLOT (the
# recorded copy), SUPER_NEW1 and SUPER_NEW2 (the current pool's slots) and
# SUPER_NEW_STATE (its state file); runs need FM_POOL_CURRENT_STATE exported
# from SUPER_NEW_STATE so the Treehouse stand-in resolves names there.
make_superseded_pool_case() {  # <name> <current-state-json>
  local pool_json=$2 n
  make_lease_modeling_pool_case "$1" ''
  SUPER_CASE=$POOL_CASE
  SUPER_SLOT=$POOL_SLOT
  SUPER_NEW_STATE=$SUPER_CASE/current-pool/treehouse-state.json
  for n in 1 2; do
    mkdir -p "$SUPER_CASE/current-pool/$n"
    git -C "$SUPER_CASE/project" worktree add -q --detach "$SUPER_CASE/current-pool/$n/project" main
  done
  SUPER_NEW1=$(cd "$SUPER_CASE/current-pool/1/project" && pwd -P)
  SUPER_NEW2=$(cd "$SUPER_CASE/current-pool/2/project" && pwd -P)
  pool_json=${pool_json//@SLOT1@/$SUPER_NEW1}
  pool_json=${pool_json//@SLOT2@/$SUPER_NEW2}
  printf '%s\n' "$pool_json" > "$SUPER_NEW_STATE"
}

# A finished, idle scout in a pool slot that the idle reaper selects, with an
# endpoint whose close waits until the test holds the project lock.
make_idle_reap_pool_case() {  # <name>
  local case_dir old
  make_lease_modeling_pool_case "$1" '' scout
  case_dir=$POOL_CASE
  old=$(( $(date +%s) - 7200 ))
  printf 'harness=claude\n' >> "$case_dir/state/task-x1.meta"
  printf 'done [at=%s]: report written\n' "$old" > "$case_dir/state/task-x1.status"
  printf 'g1.1.1\n' > "$case_dir/state/task-x1.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" \
    > "$case_dir/state/task-x1.busy-state"
  mkdir -p "$case_dir/data/task-x1"
  printf '# report\nfindings\n' > "$case_dir/data/task-x1/report.md"
  fm_touch_epoch "$old" "$case_dir/data/task-x1/report.md"
  FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" "$ROOT/bin/fm-captain-hold.sh" complete task-x1 --none >/dev/null \
    || fail 'could not record the scout captain-call inventory'
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    [ -f "$FM_POOL_CASE/closed" ] || printf '%s\n' fm-task-x1
    ;;
  kill-window)
    : > "$FM_POOL_CASE/closing"
    i=0
    while [ ! -f "$FM_POOL_CASE/project-held" ]; do
      i=$((i + 1)); [ "$i" -lt 2000 ] || exit 1
      sleep 0.05
    done
    : > "$FM_POOL_CASE/closed"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

# The number of live tickets queued for <lock>.
queued_tickets() {  # <lock>
  local ticket n=0
  for ticket in "$1.queue"/ticket-*; do
    [ ! -L "$ticket" ] || n=$((n + 1))
  done
  printf '%s' "$n"
}

# Holds <lock> from another process until <case>/release exists.
hold_project_lock_until_release() {  # <case-dir> <lock>
  FM_HOME="$1/primary-home" FM_STATE_OVERRIDE="$1/state" \
    bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_lock_try_acquire "$2" || exit 1
      trap '\''fm_lock_release "$2"'\'' EXIT
      : > "$3/project-held"
      while [ ! -f "$3/release" ]; do sleep 0.05; done
    ' _ "$ROOT" "$2" "$1"
}

# The return-pending record is the only retry evidence for a reserved slot, so
# a record that cannot be persisted must stop the run before anything closes,
# retires or returns: the reservation is idempotent on a retry, which then
# finishes the slot return exactly once. Each case injects one record failure
# (its rename, its path already occupied, its generation unreadable), checks
# the refusal kept every owner and record through a session start, then
# retries to completion.
assert_unrecorded_return_refusal_state() {  # <case-dir> <slot> <label>
  local case_dir=$1 slot=$2 label=$3
  assert_present "$case_dir/state/task-x1.meta" "$label: the refused teardown retired the task record"
  assert_absent "$case_dir/state/task-x1.backlog-close" "$label: the refused teardown published the backlog close"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "$label: the refused teardown closed the backlog row: $(backlog_row_state "$case_dir")"
  assert_absent "$case_dir/endpoint-closed" "$label: the refused teardown closed the endpoint"
  [ "$(grep -c '^return' "$case_dir/treehouse.log" 2>/dev/null || true)" = 0 ] \
    || fail "$label: the refused teardown returned the pool slot"
  jq -e '.worktrees[0].leased == true and .worktrees[0].lease_holder == "task-x1"' \
    "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail "$label: the refused teardown did not keep its durable lease: $(cat "$case_dir/pool/treehouse-state.json")"
  assert_present "${slot%/*}/.fm-slot-owner" "$label: the refused teardown dropped the slot claim"
}

assert_unrecorded_return_retry_finished() {  # <case-dir> <slot> <label>
  local case_dir=$1 slot=$2 label=$3 returns
  assert_absent "$case_dir/state/task-x1.meta" "$label: the retry kept the task record"
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" "$label: the retry kept the return-pending record"
  assert_present "$case_dir/endpoint-closed" "$label: the retry left its endpoint unclosed"
  returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
  assert_equals 1 "$returns" "$label: the slot must be returned exactly once across the refusal and the retry"
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail "$label: the retry left the returned slot leased"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "$label: the retry did not close the backlog row: $(backlog_row_state "$case_dir")"
}

# A fake tmux that records every endpoint close attempt in
# <case-dir>/endpoint-closed and reports the window live until then, so a
# refusal can prove no close ran.
recording_endpoint_tmux() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    [ -f "$FM_POOL_CASE/endpoint-closed" ] || printf '%s\n' fm-task-x1 ;;
  kill-window)
    : > "$FM_POOL_CASE/endpoint-closed" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

# Fails only the return-pending record's own rename; every other mv in the
# lifecycle still runs the real binary.
add_failing_return_pending_mv() {  # <case-dir>
  local case_dir=$1 real_mv
  real_mv=$(command -v mv)
  cat > "$case_dir/fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  "$case_dir/state/task-x1.teardown-return-pending") exit 1 ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# The record's generation read is the only task-record read between the pool
# reservation and the marker write: the lease reserves the slot and makes the
# record unreadable, and the marker's rename restores readability so a run
# that ignores the failed read behaves exactly like an ordinary run.
add_unreadable_return_pending_gen() {  # <case-dir>
  local case_dir=$1 real_mv
  cp "$case_dir/fakebin/treehouse" "$case_dir/fakebin/treehouse.real"
  chmod +x "$case_dir/fakebin/treehouse.real"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = lease ] && [ -f "$case_dir/inject-unreadable-gen" ]; then
  chmod 000 "$case_dir/state/task-x1.meta"
fi
exec "$case_dir/fakebin/treehouse.real" "\$@"
SH
  chmod +x "$case_dir/fakebin/treehouse"
  real_mv=$(command -v mv)
  cat > "$case_dir/fakebin/mv" <<SH
#!/usr/bin/env bash
case "\${*: -1}" in
  "$case_dir/state/task-x1.teardown-return-pending")
    [ ! -f "$case_dir/inject-unreadable-gen" ] || chmod 644 "$case_dir/state/task-x1.meta" ;;
esac
exec "$real_mv" "\$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

