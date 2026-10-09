#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# Usage: bash tests/fm-teardown.test.sh [test_function_name ...]
# With no names, run every registered case in order. Named cases run in that
# same order; unknown names are rejected before any test case runs.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or its content
# is already in the up-to-date default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + real work pushed to origin, PR not merged -> REFUSE (pushed is not landed)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q2) no-mistakes + squash-merged, local followed pipeline rebase -> ALLOW
#   (q3) no-mistakes + squash-merged, same file, different content   -> REFUSE
#   (q4) no-mistakes + squash-merged rebased local plus extra commit -> REFUSE
#   (q5) gh down + squash-merged stale local, content not in default -> REFUSE
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
# Each fixture chooses its own home, never the invoking session's live home.
unset FM_HOME

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
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
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

# Write a meta file for the task. Args: case_dir mode kind
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
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

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
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

test_local_only_fork_remote_allows() {
  local case_dir rc leftover
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'fm-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"
  printf 'gen=g1\n' > "$case_dir/state/task-x1.control-exit"
  printf '%s\tattempt\n' "$(date +%s)" > "$case_dir/state/.session-end-relaunch-task-x1"
  printf 'g1\t1\trelaunched\n' > "$case_dir/state/.session-end-handled-task-x1"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  for leftover in task-x1.control-exit .session-end-relaunch-task-x1 .session-end-handled-task-x1; do
    [ ! -e "$case_dir/state/$leftover" ] \
      || fail "fork-allow: teardown left the task's $leftover behind"
  done
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/fm-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  fm_test_wait_until 60 jq -e --arg id task-x1 "
    .schema == \"fm-secondmate-home-summary.v1\"
    and all(.endpoints[]; .id != \$id)
  " "$case_dir/state/home-summary.json" \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

# A successful teardown publishes the home summary only as a side effect, so it
# must not wait for a refresh already in flight. Hold the refresh lock with a
# 20-second deadline: a blocking trigger would wait that deadline out and record
# a failure; a detached one records nothing and leaves its marker.
test_teardown_does_not_wait_for_the_home_summary_refresh() {
  local case_dir rc holder marker
  case_dir=$(make_case summary-detach)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  marker="$case_dir/state/.test-summary-lock-held"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$2/state/.home-summary-refresh.lock"
    : > "$3"
    sleep 120
  ' _ "$ROOT" "$case_dir" "$marker" &
  holder=$!
  fm_test_wait_until 20 test -e "$marker" || { kill "$holder" 2>/dev/null; fail "could not hold the refresh lock"; }
  set +e
  FM_HOME_SUMMARY_TIMEOUT=20 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "teardown should succeed with a refresh in flight"
  fm_test_wait_until 60 test -e "$case_dir/state/.home-summary-refresh.pending" \
    || { kill "$holder" 2>/dev/null; fail "the teardown trigger left no marker for the refresh in flight"; }
  sleep 2
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ ! -s "$case_dir/state/.home-summary-refresh.log" ] \
    || fail "teardown waited out a refresh and recorded a failure: $(cat "$case_dir/state/.home-summary-refresh.log")"
  pass "teardown does not wait for the home summary refresh"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case tasks-axi-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/fm-tasks-axi.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run tasks-axi done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note() {
  local case_dir out real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  case_dir=$(make_case tasks-axi-close-gerrit)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gerrit_url" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed Gerrit task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed Gerrit task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"Gerrit change $gerrit_url\"" >/dev/null \
    || fail "closed Gerrit backlog item did not record its change URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed Gerrit close left its pending-close record behind"

  case_dir=$(make_case tasks-axi-close-github-under-refusal)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  cp "$TMP_ROOT/tasks-axi-close-gerrit/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitHub task failed: $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
    | grep -F 'links: "pr:https://github.com/example/repo/pull/7"' >/dev/null \
    || fail "a GitHub pull request no longer closed as the item's pr link"
  pass "teardown closes a landed Gerrit task with its change URL as a note and a GitHub task with --pr"
}

test_teardown_manual_backend_leaves_the_backlog_to_the_operator() {
  local case_dir out backlog_path
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "manual backlog backend was mutated by teardown anyway"
  backlog_path=$(cd "$case_dir/data" && pwd -P)/backlog.md
  printf '%s\n' "$out" | grep -F "Update $backlog_path - move task-x1 to Done" >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  pass "teardown honors config/backlog-backend=manual and still finishes cleanly"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc variant wt_head
  for variant in unpushed pushed offline no-remote; do
    case_dir=$(make_case "merged-main-$variant")
    write_meta "$case_dir" local-only ship
    wt_commit_file "$case_dir" feature.txt landed "merged work"
    wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
    if [ "$variant" = pushed ]; then
      git -C "$case_dir/wt" push -q origin fm/task-x1
    elif [ "$variant" = no-remote ]; then
      git -C "$case_dir/wt" remote remove origin
    elif [ "$variant" = offline ]; then
      git -C "$case_dir/wt" remote set-url origin "$case_dir/nonexistent-origin"
    fi
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "merged-main-$variant: local landing refused: $(cat "$case_dir/stderr")"
    ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main-$variant: teardown printed a refusal"
  done
  pass "local main landing succeeds independently of pushed and remote availability"
}

test_no_mistakes_pushed_branch_without_merge_refuses() {
  local case_dir rc words
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt hello "shippable work"
  # The branch reached origin, but no PR merged it and main lacks its content: recoverable, not delivered.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "nm-origin: a pushed but unmerged ship must refuse"
  grep -q "a pushed branch alone is not completion" "$case_dir/stderr" || fail "nm-origin: the refusal did not say pushed is not landed"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "nm-origin: the refusal removed the task record"

  # Without the captain's words, --force is refused too, and nothing is discarded.
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "nm-origin: --force without the captain's words must refuse"
  grep -q "requires --drop-file" "$case_dir/stderr" || fail "nm-origin: the refusal did not ask for the captain's words"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "nm-origin: a refused --force removed the task record"

  # With the words, the discard proceeds: the words are kept, and the row records a drop.
  words="$case_dir/words.txt"
  printf 'Drop it; the premise is gone.\n' > "$words"
  rc=0
  run_teardown "$case_dir" --force --drop-file "$words" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "nm-origin: a drop with the captain's words must complete: $(cat "$case_dir/stderr")"
  cmp -s "$words" "$case_dir/data/task-x1/captain-drop.md" || fail "nm-origin: the captain's exact words were not retained"
  grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null || fail "nm-origin: the dropped row was not closed"
  grep -E '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" >/dev/null || fail "nm-origin: the row does not record the fixed drop note"
  pass "a pushed but unmerged ship refuses, and only the captain's own words discard it"
}

test_drop_file_without_force_is_a_usage_error() {
  local case_dir rc
  case_dir=$(make_case drop-no-force)
  write_meta "$case_dir" no-mistakes ship
  rc=0
  run_teardown "$case_dir" --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 2 "$rc" "drop-no-force: --drop-file alone must be a usage error"
  rc=0
  run_teardown "$case_dir" --force --drop-file "$case_dir/empty.txt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "drop-no-force: an unreadable words file must refuse"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "drop-no-force: a refusal removed the task record"
  pass "--drop-file needs --force and a readable words file"
}

test_forced_dirty_landed_deliverables_retain_captain_words() {
  local case_dir kind delivery mode rc words
  for delivery in ship scout local-only; do
    case_dir=$(make_case "forced-dirty-landed-$delivery")
    kind=$delivery
    mode=no-mistakes
    if [ "$delivery" = local-only ]; then kind=ship; mode=local-only; fi
    write_meta "$case_dir" "$mode" "$kind"
    seed_backlog_in_flight "$case_dir" "$kind"
    if [ "$kind" = ship ]; then
      wt_commit_file "$case_dir" feature.txt landed "landed feature"
      if [ "$delivery" = local-only ]; then
        git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
        git -C "$case_dir/wt" remote set-url origin "$case_dir/nonexistent-origin"
      else
        append_pr_meta_for_current_head "$case_dir"
        add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
      fi
    else
      mkdir -p "$case_dir/data/task-x1"
      printf 'Delivered investigation report.\n' > "$case_dir/data/task-x1/report.md"
    fi
    printf 'uncommitted scratch\n' > "$case_dir/wt/scratch.txt"
    words="$case_dir/words.txt"
    printf 'Discard the remaining scratch; keep the delivered result.\n' > "$words"
    rc=0
    run_teardown "$case_dir" --force --drop-file "$words" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "forced-dirty-$kind: authorized cleanup refused: $(cat "$case_dir/stderr")"
    cmp -s "$words" "$case_dir/data/task-x1/captain-drop.md" || fail "forced-dirty-$kind: exact captain words were lost"
    [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "forced-dirty-$kind: backlog was not closed"
    if [ "$kind" = ship ]; then
      grep -Eq '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" || fail "forced-dirty-$delivery: ship did not record the fixed drop note"
      assert_no_grep 'local main' "$case_dir/data/backlog.md" "forced-dirty-$delivery: ship retained a landing label instead of dropped"
      assert_no_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" "forced-dirty-$delivery: ship retained a landing label instead of dropped"
    else
      ! grep -Eq '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" || fail "forced-dirty-scout: delivered report was mislabeled dropped"
      assert_grep 'task-x1/report.md' "$case_dir/data/backlog.md" "forced-dirty-scout: report completion was lost"
      assert_present "$case_dir/data/task-x1/report.md" "forced-dirty-scout: delivered report was removed"
    fi
  done
  pass "forced dirty ships record dropped and scouts retain delivered reports, with exact captain words retained for both"
}

test_scout_report_must_be_a_regular_nonempty_file() {
  local case_dir rc
  case_dir=$(make_case scout-report-file)
  write_meta "$case_dir" no-mistakes scout
  mkdir -p "$case_dir/data/task-x1/report.md"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "scout-report-file: a directory named report.md is not a report"
  rmdir "$case_dir/data/task-x1/report.md"
  : > "$case_dir/data/task-x1/report.md"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "scout-report-file: an empty report is not a report"
  grep -q "has no report" "$case_dir/stderr" || fail "scout-report-file: the refusal did not name the missing report"
  pass "a scout completes only with a regular non-empty report"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$case_dir/code-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

# A task recording base_branch= landed when its content reached that branch, not
# the default branch: a squash merge into the base branch is the landing.
test_content_fallback_uses_recorded_base_branch() {
  local case_dir rc landed tmp
  for landed in base default; do
    case_dir=$(make_case "content-base-$landed")
    write_meta "$case_dir" direct-PR ship
    printf 'base_branch=feature/hub\n' >> "$case_dir/state/task-x1.meta"
    tmp="$case_dir/_hub"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" push -q origin HEAD:refs/heads/feature/hub
    rm -rf "$tmp"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    if [ "$landed" = base ]; then
      tmp="$case_dir/_land"
      git clone -q "$case_dir/origin.git" "$tmp"
      git -C "$tmp" checkout -q feature/hub
      printf 'hello\n' > "$tmp/feature.txt"
      git -C "$tmp" add feature.txt
      git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash feature.txt"
      git -C "$tmp" push -q origin HEAD:feature/hub
      rm -rf "$tmp"
    else
      land_on_origin_main "$case_dir" feature.txt hello
    fi
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    if [ "$landed" = base ]; then
      expect_code 0 "$rc" "content-base: content squashed into the recorded base branch should count as landed"
      assert_absent "$case_dir/state/task-x1.meta" "content-base: teardown kept the record of landed work"
    else
      [ "$rc" -ne 0 ] || fail "content-base: content only on the default branch passed for a task based on feature/hub"
      assert_present "$case_dir/state/task-x1.meta" "content-base: a refused teardown removed the task record"
    fi
  done
  pass "the content-landed fallback checks a task's recorded base branch, not the default branch"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
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
    touch "$case_dir/wt/.claude/settings.local.json" "$case_dir/wt/.fm-grok-turnend"
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
    ! grep -q '10-scratch.txt\|11-scratch.txt\|\.claude/\|\.fm-grok-turnend' "$case_dir/stderr" \
      || fail "$kind/$mode: path list exceeded its bound or included exempt files"
    grep -Fq 'additional untracked paths omitted' "$case_dir/stderr" || fail "$kind/$mode: no truncation notice"
  else
    ! grep -q 'untracked paths' "$case_dir/stderr" || fail "$kind/$mode: invented untracked paths"
  fi
  [ -f "$case_dir/state/task-x1.meta" ] || fail "$kind/$mode: task metadata removed"
  [ "$before" = "$(git -C "$case_dir/wt" status --porcelain)" ] || fail "$kind/$mode: worktree changed"
  pass "$kind/$mode: dirty refusal classifies leftovers and preserves work"
}

test_untracked_only_refusal_diagnostic() {
  assert_dirty_diagnostic untracked no-mistakes
  assert_dirty_diagnostic untracked local-only
}

test_tracked_edit_refusal_diagnostic() {
  assert_dirty_diagnostic tracked no-mistakes
  assert_dirty_diagnostic tracked local-only
}

test_mixed_refusal_diagnostic() {
  assert_dirty_diagnostic mixed no-mistakes
  assert_dirty_diagnostic mixed local-only
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
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

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
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

test_windowless_legacy_record_with_gone_worktree_refuses() {
  local case_dir out rc
  case_dir=$(make_case windowless-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  rc=0
  out=$(run_teardown "$case_dir" 2>&1) || rc=$?
  expect_code 1 "$rc" "windowless-gone: missing copy without delivery proof must refuse"
  printf '%s\n' "$out" | grep -Fq 'completion requires a recorded GitHub PR confirmed merged' \
    || fail "windowless-gone: missing completion-proof refusal: $out"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-gone: refusal closed the backlog item"
  assert_present "$case_dir/state/task-x1.meta" \
    "windowless-gone: refusal removed the task record"
  pass "a windowless leftover with a missing worktree refuses without delivery proof"
}

test_windowless_legacy_record_with_gone_worktree_refuses_with_legacy_flag() {
  local case_dir out rc
  case_dir=$(make_case windowless-flag)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  rc=0
  out=$(run_teardown "$case_dir" --legacy-record 2>&1) || rc=$?
  expect_code 1 "$rc" "windowless-flag: --legacy-record must not waive completion proof"
  printf '%s\n' "$out" | grep -Fq 'completion requires a recorded GitHub PR confirmed merged' \
    || fail "windowless-flag: missing completion-proof refusal: $out"
  assert_present "$case_dir/state/task-x1.meta" \
    "windowless-flag: refusal removed the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-flag: refusal closed the backlog item"
  pass "--legacy-record does not waive a missing copy's delivery proof"
}

test_ship_without_git_copy_completes_with_recorded_merged_pr() {
  local case_dir copy mode out head
  for copy in absent non-git; do
    for mode in no-mistakes local-only; do
      case_dir=$(make_case "recorded-merged-$copy-$mode")
      [ "$copy" != non-git ] || mkdir "$case_dir/missing-wt"
      write_windowless_legacy_meta "$case_dir" "$mode" ship "$case_dir/missing-wt"
      append_pr_meta_url "$case_dir"
      seed_backlog_in_flight "$case_dir"
      head=$(git -C "$case_dir/wt" rev-parse HEAD)
      add_gh_pr_merged_for_head "$case_dir" "$head"

      out=$(run_teardown "$case_dir" 2>&1) \
        || fail "recorded-merged-$copy-$mode: merged recorded PR refused: $out"
      assert_absent "$case_dir/state/task-x1.meta" \
        "recorded-merged-$copy-$mode: successful completion retained metadata"
      [ "$(backlog_row_state "$case_dir")" = "done" ] \
        || fail "recorded-merged-$copy-$mode: successful completion kept backlog open"
      assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
        "recorded-merged-$copy-$mode: completion did not retain the PR"
      assert_no_grep 'local main' "$case_dir/data/backlog.md" \
        "recorded-merged-$copy-$mode: completion invented a local merge"
    done
  done
  pass "absent and non-Git ship copies complete only with their recorded merged PR"
}

test_ship_without_git_copy_refuses_unconfirmed_pr() {
  local case_dir copy proof out rc head state
  for copy in absent non-git; do
    for proof in open closed error unrecorded unsupported; do
      case_dir=$(make_case "unconfirmed-$copy-$proof")
      [ "$copy" != non-git ] || mkdir "$case_dir/missing-wt"
      write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
      seed_backlog_in_flight "$case_dir"
      head=$(git -C "$case_dir/wt" rev-parse HEAD)
      add_gh_pr_merged_for_head "$case_dir" "$head"
      case "$proof" in
        unrecorded) ;;
        unsupported)
          printf '%s\n' 'pr=https://example.invalid/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
          ;;
        *)
          append_pr_meta_url "$case_dir"
          if [ "$proof" = error ]; then
            add_gh_axi_error "$case_dir"
            printf '#!/usr/bin/env bash\nprintf "MERGED\\n"\nexit 1\n' > "$case_dir/fakebin/gh"
          else
            state=OPEN
            [ "$proof" != closed ] || state=CLOSED
            printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$state" > "$case_dir/fakebin/gh"
          fi
          ;;
      esac

      rc=0
      out=$(run_teardown "$case_dir" 2>&1) || rc=$?
      expect_code 1 "$rc" "unconfirmed-$copy-$proof: absent delivery proof must refuse: $out"
      assert_present "$case_dir/state/task-x1.meta" \
        "unconfirmed-$copy-$proof: refusal removed metadata"
      [ "$(backlog_row_state "$case_dir")" = in_flight ] \
        || fail "unconfirmed-$copy-$proof: refusal closed the backlog"
    done
  done
  pass "ships without Git copies refuse open, closed, unreachable, unrecorded, and unsupported PR proof"
}

test_ship_without_git_copy_requires_captain_words_to_drop() {
  local case_dir copy out rc words
  for copy in absent non-git; do
    case_dir=$(make_case "missing-copy-drop-$copy")
    [ "$copy" != non-git ] || mkdir "$case_dir/missing-wt"
    write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
    seed_backlog_in_flight "$case_dir"
    rc=0
    out=$(run_teardown "$case_dir" --force 2>&1) || rc=$?
    expect_code 1 "$rc" "missing-copy-drop-$copy: force without words must refuse: $out"
    assert_present "$case_dir/state/task-x1.meta" \
      "missing-copy-drop-$copy: unauthorized force removed metadata"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "missing-copy-drop-$copy: unauthorized force closed backlog"

    words="$case_dir/drop-words"
    printf '%s\n' "Discard this missing copy's unfinished work." > "$words"
    out=$(run_teardown "$case_dir" --force --drop-file "$words" 2>&1) \
      || fail "missing-copy-drop-$copy: authorized drop refused: $out"
    cmp -s "$words" "$case_dir/data/task-x1/captain-drop.md" \
      || fail "missing-copy-drop-$copy: captain words were not retained exactly"
    [ "$(backlog_row_state "$case_dir")" = "done" ] \
      || fail "missing-copy-drop-$copy: authorized drop kept backlog open"
    grep -Eq '^[[:space:]]+dropped$' "$case_dir/data/backlog.md" \
      || fail "missing-copy-drop-$copy: authorized drop lacked drop classification"
    assert_absent "$case_dir/state/task-x1.meta" \
      "missing-copy-drop-$copy: authorized drop retained metadata"
  done
  pass "ships without Git copies require retained captain words for forced drops"
}

test_windowless_legacy_record_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-windowless-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "windowless-unlanded: a still-present unlanded worktree must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-unlanded: no REFUSED line for unlanded windowless work"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "a windowless leftover still refuses while its worktree holds unlanded work"
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

test_windowless_record_outside_the_leftover_class_still_refuses() {
  local case_dir
  case_dir=$(make_case windowless-spawn-gen)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-spawn-gen "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-orca)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=orca' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-orca "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-no-backlog)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  assert_windowless_record_refuses "$case_dir" windowless-no-backlog "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-dup-project)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' "project=$case_dir/other-project" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-dup-project "no spawn_gen that identifies one exact incarnation"
  case_dir=$(make_case windowless-foreign-binding)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'endpoint_task_id=task-other' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-foreign-binding "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-terminal)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-terminal "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-herdr-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=tmux' 'herdr_session=s1' 'herdr_pane_id=p1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-herdr-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-cmux-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'cmux_surface_id=surface-1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-cmux-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-control-char)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing"$'\t'"wt"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-control-char "no spawn_gen that identifies one exact incarnation"
  pass "a windowless record with a spawn_gen, a non-tmux backend or endpoint identity, no backlog validation, or ambiguous, foreign, or malformed identity still refuses"
}

test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag() {
  local case_dir rc out
  case_dir=$(make_case windowless-retry)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  add_failing_truncate_perl "$case_dir"
  add_failing_close_publication_mv "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "windowless-retry: an unrecordable close must fail the first attempt"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "windowless-retry: the failed attempt did not leave its legacy stamp on the record"

  rm -f "$case_dir/fakebin/perl" "$case_dir/fakebin/mv"
  out=$(run_teardown "$case_dir") \
    || fail "windowless-retry: the flag-less retry refused the retained legacy stamp"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-retry: the retry did not accept the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-retry: the retry left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-retry: the retry returned success with its backlog item still open"
  pass "a windowless leftover retries its retained legacy stamp without --legacy-record"
}

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}

test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}

test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}

test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_close_publication_mv "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
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

test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"
  add_failing_close_publication_mv "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  # The mtime fault is injected by a fake stat on PATH; on Darwin the lock
  # helper now calls /usr/bin/stat directly, so the fake can never fire there.
  # Skip the Darwin run of this case.
  if [ "$(uname)" = Darwin ]; then
    pass "index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat"
    return
  fi
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"

  set +e
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
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

# Registering a PR inside a secondmate home publishes the child's ready line
# with the canonical URL on the parent channel from fm-pr-check itself, once;
# a main home publishes nothing.
test_secondmate_pr_registration_publishes_ready_line() {
  local case_dir pr_head channel url
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready: poll was not armed"
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready: the ready line did not reach the parent channel"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: registration reported a channel problem: $(cat "$case_dir/pr-check.err")"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>&1 \
    || fail "mate-pr-ready: re-registration failed"
  [ "$(grep -c 'child-pr-task-x1' "$channel")" -eq 1 ] \
    || fail "mate-pr-ready: re-registration duplicated the ready line"

  case_dir=$(make_case main-pr-ready)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  FM_ROOT_OVERRIDE="$case_dir/code-root" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2> "$case_dir/pr-check.err" \
    || fail "main-pr-ready: fm-pr-check failed"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "main-pr-ready: a main home reported a channel problem"
  [ ! -e "$case_dir/state/parent-replies.status" ] || fail "main-pr-ready: a main home wrote a parent reply"
  pass "fm-pr-check publishes the PR-ready line on a secondmate's parent channel once"
}

# Tearing a child down inside a secondmate home delivers the child's final
# ledger line to the parent before the record goes, and refuses (retaining
# every record) while the parent channel cannot be written; a rerun after the
# repair delivers and completes.
test_secondmate_home_teardown_delivers_final_line_or_refuses() {
  local case_dir rc channel wt_head err seq generation

  case_dir=$(make_case mate-teardown-delivers)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'working: shipping\ndone: PR https://github.com/example/repo/pull/9 checks green\n' \
    > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-delivers: teardown should succeed: $(cat "$case_dir/stderr")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green pr=https://github.com/example/repo/pull/9 mode=local-only$' \
    || fail "mate-teardown-delivers: the final ledger line did not reach the parent: $(cat "$channel" 2>/dev/null)"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-delivers: teardown left the task record"

  case_dir=$(make_case mate-teardown-refuses)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  # The channel path is occupied by a directory, so no line can be appended.
  mkdir -p "$case_dir/parent/state/mate-x.status"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/tasktmp"
  printf '!\n' > "$case_dir/state/task-x1.grok-turnend-token"
  printf '!\n' > "$case_dir/state/task-x1.kimi-turnend-token"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mate-teardown-refuses: teardown proceeded with an undelivered final line"
  grep -q 'has not reached the parent channel' "$case_dir/stderr" \
    || fail "mate-teardown-refuses: refusal did not name the parent channel: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-refuses: refusal did not retain the task records"
  [ -f "$case_dir/state/task-x1.grok-turnend-token" ] \
    && [ -f "$case_dir/state/task-x1.kimi-turnend-token" ] \
    && [ -d "$case_dir/tasktmp" ] \
    || fail "mate-teardown-refuses: refusal removed endpoint records before parent delivery"
  rmdir "$channel"
  err=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -z "$seq" ] || FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a secondmate home's teardown delivers the child's final line or refuses until it can"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
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

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
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

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
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

test_herdr_teardown_presentation_lock_namespace_is_per_account() {
  local fake_uid own_ns legacy legacy_before legacy_after own_before case_dir rc lock linux_arms=0
  fake_uid=$(herdr_lock_ns_fake_uid)
  [ "$fake_uid" != "$(id -u)" ] || fail "herdr-lock-ns: fixture account uid collides with the running account"
  own_ns="/tmp/firstmate-herdr-presentation-$fake_uid"
  legacy=/tmp/firstmate-herdr-presentation
  [ ! -e "$own_ns" ] && [ ! -L "$own_ns" ] \
    || fail "herdr-lock-ns: fixture namespace $own_ns already exists; refusing to reuse it"
  printf '%s\n' "$own_ns" >> "$FM_TEST_CLEANUP_REGISTRY"
  mkdir -m 700 "$own_ns" || fail "herdr-lock-ns: could not stage $own_ns"
  legacy_before=$(herdr_lock_ns_path_state "$legacy")

  # This account's own name, really owned by another uid, is still refused and
  # is left exactly as it was.
  own_before=$(herdr_lock_ns_path_state "$own_ns")
  case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-foreign-owner)
  rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-lock-ns-foreign-owner: teardown adopted a namespace another uid owns"
  assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-foreign-owner
  [ "$(herdr_lock_ns_path_state "$own_ns")" = "$own_before" ] \
    || fail "herdr-lock-ns-foreign-owner: refusal changed the foreign-owned namespace: $(herdr_lock_ns_path_state "$own_ns")"

  if [ "$(uname -s)" != Darwin ]; then
    linux_arms=1
    # The old shared name is owned by another uid whenever it exists here, as
    # on a host where a second account created it first; this account's
    # teardown no longer consults it and completes in its own namespace.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-other-account)
    run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:700" \
      || fail "herdr-lock-ns-other-account: teardown was blocked: $(cat "$case_dir/stderr")"
    [ -e "$case_dir/closed" ] || fail "herdr-lock-ns-other-account: the pane was not closed under the lock"
    [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-lock-ns-other-account: teardown left the metadata behind"
    grep -q "teardown task-x1 complete" "$case_dir/stdout" \
      || fail "herdr-lock-ns-other-account: teardown did not report completion"
    lock=$(FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$own_ns:$fake_uid:700" \
      FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
      PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
      || fail "herdr-lock-ns-other-account: could not resolve the fixture account's lock path"
    case "$lock" in
      "$own_ns"/order-*.lock) ;;
      *) fail "herdr-lock-ns-other-account: the lock is not in this account's namespace: $lock" ;;
    esac

    # This account's own name with the right owner but the wrong mode is refused.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-wrong-mode)
    rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:755" || rc=$?
    [ "$rc" -ne 0 ] || fail "herdr-lock-ns-wrong-mode: teardown adopted a namespace that is not mode 700"
    assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-wrong-mode
    [ -d "$own_ns" ] || fail "herdr-lock-ns-wrong-mode: refusal removed the namespace"
  fi

  legacy_after=$(herdr_lock_ns_path_state "$legacy")
  [ "$legacy_after" = "$legacy_before" ] \
    || fail "herdr-lock-ns: teardown changed the old shared namespace: $legacy_before -> $legacy_after"
  rm -rf "$own_ns"
  if [ "$linux_arms" = 1 ]; then
    pass "herdr teardown takes its lock in a per-account namespace another account cannot block, and still refuses a foreign-owned or wrong-mode one"
  else
    pass "herdr teardown refuses a foreign-owned per-account namespace (owner-shim arms need the non-Darwin stat branch; skipped on Darwin)"
  fi
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

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
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

test_forced_secondmate_teardown_holds_descendant_lifecycle_locks() {
  local case_dir home lock ready release holder_pid rc waited=0 child
  case_dir=$(make_case descendant-locks)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  : > "$case_dir/kill.log"
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/kill.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  lock="$home/state/.control-child-b.lock"
  ready="$case_dir/lock-ready"
  release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" \
    HOME_STATE="$home/state" OWNER_PID="$$" bash -c '
    export FM_STATE_OVERRIDE="$HOME_STATE"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ] && kill -0 "$OWNER_PID" 2>/dev/null; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "descendant-locks: the contending lifecycle action never acquired its lock"

  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "descendant-locks: forced teardown ignored a descendant lifecycle lock"
  fi
  assert_grep "descendant task child-b has a lifecycle action in flight" "$case_dir/stderr" \
    "descendant-locks: refusal did not name the contended descendant"
  [ ! -e "$home/state/.control-child-a.lock" ] \
    && [ ! -e "$home/state/.meta-child-a.lock" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal leaked earlier descendant locks"; }
  [ ! -s "$case_dir/kill.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal killed an endpoint"; }
  [ ! -s "$case_dir/treehouse.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal returned a worktree"; }
  [ -e "$case_dir/state/task-x1.meta" ] && [ -d "$home" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed parent state"; }
  for child in child-a child-b; do
    [ -e "$home/state/$child.meta" ] && [ -d "$case_dir/$child-wt" ] \
      || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed $child state or worktree"; }
  done

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  rc=0
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "descendant-locks: uncontended retry should complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] && [ ! -d "$home" ] \
    || fail "descendant-locks: uncontended retry retained retired task state"
  [ -s "$case_dir/kill.log" ] && [ -s "$case_dir/treehouse.log" ] \
    || fail "descendant-locks: uncontended retry did not perform endpoint and worktree cleanup"
  pass "forced secondmate teardown holds every descendant lifecycle and metadata lock"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
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
    "worktree=$case_dir/wt" \
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

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
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

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-restore-failure)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_RESTORE_FAIL=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-restore-failure: a confirmed close with a failed focus restore blocked teardown"
  [ -e "$closed" ] \
    || fail "herdr-projection-restore-failure: regression did not exercise the exact projected-pane close"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "herdr-projection-restore-failure: confirmed closure did not retire the presentation journal"
  assert_grep "exact-tab restoration failed" "$case_dir/stderr" \
    "herdr-projection-restore-failure: teardown swallowed the focus helper's restore warning"
  pass "herdr projection teardown surfaces failed focus restoration without turning confirmed cleanup into a hard failure"
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

test_teardown_retires_task_watcher_markers_and_orphan_journal() {
  local case_dir log closed restored marker
  case_dir=$(make_case retire-watcher-markers)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  # The projected workspace is already gone before teardown runs, so the close
  # path cannot match the journal to a live workspace and leaves it behind.
  : > "$closed"
  seed_watcher_markers "$case_dir" task-x1
  seed_watcher_markers "$case_dir" task-y2
  seed_watcher_markers "$case_dir" task-x1_extra
  printf '%s\n' 'version=1' 'task_id=task-y2' 'projection_id=ZyXwVuTsRqPoNmLkJiHgFe' \
    > "$case_dir/state/task-y2.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-watcher-markers: teardown failed: $(cat "$case_dir/stderr")"
  for marker in .seen-task-x1_status .seen-task-x1_turn-ended .hb-surfaced-task-x1 task-x1.herdr-presentation; do
    assert_absent "$case_dir/state/$marker" "teardown left the torn-down task's $marker behind"
  done
  for marker in .seen-task-y2_status .seen-task-y2_turn-ended .hb-surfaced-task-y2 task-y2.herdr-presentation \
    .seen-task-x1_extra_status .seen-task-x1_extra_turn-ended .hb-surfaced-task-x1_extra; do
    assert_present "$case_dir/state/$marker" "teardown removed another task's $marker"
  done
  pass "teardown retires the task's own watcher markers and orphaned presentation journal, leaving other tasks' markers alone"
}

test_teardown_retains_journal_bound_to_another_pane() {
  local case_dir log closed restored
  case_dir=$(make_case retain-drifted-journal)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  : > "$closed"
  # A version 2 binding that advanced to a replacement pane the metadata never
  # recorded may still name a live quarantined space; only the sweep may judge it.
  printf '%s\n' 'version=2' 'task_id=task-x1' 'projection_id=AbCdEfGhIjKlMnOpQrStUv' \
    "home=$case_dir" 'session=fmtest' 'workspace_id=w1' 'tab_id=w1:t2' 'pane_id=w1:p9' \
    'parent_workspace_id=w0' 'parent_label=firstmate' \
    'workspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' 'task_label=fm-task-x1' \
    > "$case_dir/state/task-x1.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-drifted-journal: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "teardown retired a journal bound to a pane it never proved gone"
  assert_absent "$case_dir/state/task-x1.meta" "retain-drifted-journal: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown kept the drifted journal without saying why"
  pass "teardown retains a presentation journal bound to a pane other than the closed endpoint"
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

test_teardown_retires_v1_journal_when_projected_workspace_gone() {
  local case_dir log closed
  case_dir=$(make_case retire-v1-journal-workspace-gone)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_COLLAPSED=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-v1-journal-workspace-gone: teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is confirmed gone was not retired"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retire-v1-journal-workspace-gone: teardown did not complete"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retire-v1-journal-workspace-gone: teardown must never call workspace close"
  pass "teardown retires a v1 presentation journal once its token workspace is confirmed gone"
}

test_teardown_retains_v1_journal_when_projected_workspace_present() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-present)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-present: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is still present was wrongly retired, stranding the workspace"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-present: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-present: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal while its token workspace is still present"
}

test_teardown_retains_v1_journal_when_workspace_query_ambiguous() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-ambiguous)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  # A malformed workspace-list entry makes the token query ambiguous: teardown
  # cannot prove the token workspace gone, so it must keep the journal.
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_MALFORMED=1 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-ambiguous: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal was retired even though the workspace query was ambiguous"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-ambiguous: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-ambiguous: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal when the workspace query is ambiguous"
}

# --- Fix 1: conclude/abort the task's own parked no-mistakes run before the
# worker is removed, and Fix 2: reap leaked descendant processes rooted under
# the task's own worktree/tasktmp - both exercised through the real teardown
# path (bin/fm-teardown.sh), never by matching its source text. ------------

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

# Cleanup keeps the task's no-mistakes pipeline spend in this home's records
# (bin/fm-pipeline-spend.sh) while the task branch that attributes its runs and
# the task record still exist, then removes both as before.
test_teardown_records_the_task_pipeline_spend() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend)
  write_meta "$case_dir" no-mistakes ship
  : > "$case_dir/config/pipeline-spend"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/nm"
  python3 - "$case_dir/nm/state.sqlite" "$case_dir/project" "$(date +%s)" <<'PY'
import sqlite3
import sys

database, project, created = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE agent_invocations (id TEXT, run_id TEXT, purpose TEXT, session_mode TEXT,
        started_at INTEGER, exit_status TEXT, duration_ms INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
        delta_input_tokens INTEGER, delta_output_tokens INTEGER, delta_cache_read_tokens INTEGER);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES ('01RUN', 'r1', 'fm/task-x1', 'completed', ?)", (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i1', '01RUN', 'review', 'cold', ?, 'ok', 100, 7, 8, 9, 10, 7, 8, 9)",
           (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i2', '01RUN', 'review', 'cold', ?, 'cancelled', 50, "
           "NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (created + 1,))
db.commit()
PY
  (
    export NM_HOME="$case_dir/nm" FM_FAKE_AXI_OVERVIEW="repo: $case_dir/project"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  ) || rc=$?

  expect_code 0 "$rc" "pipeline-spend: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend: teardown left no pipeline spend record"
  jq -e '
    .task == "task-x1" and .spawn_gen == "teardown-test-task-x1"
    and .source == "no-mistakes-state" and .branch == "fm/task-x1"
    and [.runs[].id] == ["01RUN"]
    and .total.invocations == 2 and .total.exit == {"ok": 1, "cancelled": 1}
    and .total.input_tokens == {"total": 7, "unknown": 1}
  ' "$ledger" >/dev/null || fail "pipeline-spend: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend: teardown kept the task record"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "pipeline-spend: teardown kept the task branch"
  pass "teardown records the task's pipeline spend before removing its branch and record"
}

test_teardown_skips_pipeline_spend_when_disabled() {
  local case_dir rc=0
  case_dir=$(make_case pipeline-spend-disabled)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-disabled: teardown should succeed"
  assert_absent "$case_dir/data/pipeline-spend.jsonl" \
    "pipeline-spend-disabled: teardown created a spend ledger without opt-in"
  assert_absent "$case_dir/state/task-x1.meta" \
    "pipeline-spend-disabled: teardown kept the task record"
  pass 'teardown skips all pipeline-spend recording when the home has not opted in'
}

# An owned ship task whose local copy is already gone and recorded PR is merged
# still leaves an unavailable-source account before its record goes.
test_teardown_records_unavailable_spend_for_a_gone_worktree() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  : > "$case_dir/config/pipeline-spend"
  seed_backlog_in_flight "$case_dir"
  append_pr_meta_url "$case_dir"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-gone: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend-gone: teardown left no pipeline spend record"
  jq -e '.task == "task-x1" and .source == "unavailable" and .total == null
    and (.reason | contains("is gone"))' "$ledger" >/dev/null \
    || fail "pipeline-spend-gone: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend-gone: teardown kept the task record"
  pass "teardown records unavailable pipeline spend for an owned ship task whose copy is gone"
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# An abort can race a concurrent gate response: the run finishes with a
# passing-but-not-clean outcome (an explicitly approved Test/CI exception)
# instead of landing on `cancelled`. That is still a terminal, finished run,
# so teardown must conclude cleanly rather than refuse as still-parked.
test_parked_own_run_concludes_on_passed_with_override_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-override)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-override: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-override: a passing override outcome must not be reported as still parked"
  pass "a run that lands on passed-with-override after abort is still recognized as terminal"
}

# The same race, landing on the other automatic passing-but-not-clean outcome:
# publication or CI verification was skipped instead of an explicit override.
# That is still a terminal, finished run.
test_parked_own_run_concludes_on_passed_with_skips_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-skips)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-skips: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-skips: a passing skips outcome must not be reported as still parked"
  pass "a run that lands on passed-with-skips after abort is still recognized as terminal"
}

# The pipeline advanced the parked run past the submitted head in its own
# repo, so the run head object does not exist in the task copy at all and the
# strict object-local identity rule cannot bind the run. The daemon's own
# runs ledger is what still proves the run is this task's continuation: its
# newest fm/task-x1 row is active at the unfetched head, anchored by the
# immediately older fm/task-x1 row ending exactly at this worktree's HEAD.
# Teardown must conclude the run instead of orphaning a parked gate wait that
# would otherwise hold a fleet slot forever (observed 2026-09-03). Foreign
# branches' rows interleaved in the ledger must not matter.
test_parked_run_advanced_past_unfetched_head_is_still_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-pipeline-advanced-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-pipeline-advanced-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-pipeline-advanced-unfetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-pipeline-advanced-unfetched: teardown did not abort the parked run the ledger proves is this task's continuation"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-pipeline-advanced-unfetched: teardown did not report aborting the parked run"
  pass "a parked run the pipeline advanced past the task copy is still concluded from the runs ledger, not orphaned"
}

test_parked_run_with_mismatched_ledger_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-mismatched-ledger-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-mismatched-ledger-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 deadbee 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-mismatched-ledger-head: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-mismatched-ledger-head: teardown aborted a ledger run with a different head"
  pass "a ledger row for a different head never authorizes a parked-run abort"
}

test_parked_run_with_malformed_ledger_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-malformed-ledger-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-malformed-ledger-row"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
running fm/task-x1 $advanced_short
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-malformed-ledger-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-malformed-ledger-row: teardown aborted from a malformed ledger row"
  pass "a malformed ledger row never authorizes a parked-run abort"
}

test_parked_run_with_impossible_ledger_date_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-impossible-ledger-date)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-impossible-ledger-date"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-02-31 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-02-28 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-impossible-ledger-date: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-impossible-ledger-date: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-impossible-ledger-date: teardown aborted from an impossible ledger date"
  pass "an impossible ledger date never authorizes a parked-run abort"
}

test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback() {
  local case_dir rc advanced_short anchor_short terminal_status
  case_dir=$(make_case parked-run-terminal-status-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-status-gate"
  terminal_status=$(parked_axi_status_toon fm/task-x1 "$advanced_short")
  terminal_status=${terminal_status/status: awaiting_approval/status: completed}

  rc=0
  FM_FAKE_AXI_STATUS="$terminal_status" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-status-gate: teardown should still succeed"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-terminal-status-gate: terminal status queried the ledger fallback"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-status-gate: terminal status with a stale gate aborted"
  pass "a terminal status with a stale gate never reaches ledger cleanup"
}

# Counterfactual twin of the unfetched defect above: the SAME parked-run shape
# with the pipeline's advanced fix head FETCHED into the task copy (objects
# only - no ref moves) resolves through the strict object-local rule alone,
# because a fix round's commits descend from this worktree's submitted HEAD.
# With an EMPTY ledger, teardown must still abort - and must never query the
# ledger at all - proving the fallback stays dormant whenever the run head's
# object is present locally (no ledger dependency on the strict-rule path).
test_parked_run_advanced_head_locally_fetched_is_still_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-fetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  # The one changed condition vs the defect case: fetch the fix commits into
  # the project clone's object store (shared with the task worktree) without
  # moving any ref, so fm_nm_resolve_commit sees the head again.
  git -C "$case_dir/project" fetch -q "$case_dir/pipeline-clone" fm/task-x1
  [ -n "$(git -C "$case_dir/wt" rev-parse --verify --quiet "${advanced_short}^{commit}" 2>/dev/null)" ] \
    || fail "parked-run-advanced-fetched: fixture broke - the pipeline head never reached the task copy"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-fetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-advanced-fetched: teardown did not abort the parked run the strict object-local rule binds"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-advanced-fetched: the ledger fallback fired even though the advanced head resolves locally"
  pass "an advanced head present locally aborts through the strict rule alone - the ledger fallback stays dormant"
}

# No anchor: the unresolvable active row is the branch's ONLY row, so nothing
# proves the run ever touched this worktree's head - a branch-name coincidence
# or an arbitrary daemon-side run must not be concluded.
test_parked_advanced_run_without_anchor_is_never_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-no-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-no-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-no-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-no-anchor: teardown aborted an unanchored run it cannot prove is its own"
  pass "an unresolvable active row with no same-branch anchor is never concluded (conservative refusal)"
}

# The anchor row resolves but to an OLDER commit: the worktree advanced past
# it since the run was submitted, so exact-equality fails and the run is not
# provably this worktree's submission. Ancestor-only anchors must never bind.
test_parked_advanced_run_ancestor_anchor_is_never_aborted() {
  local case_dir rc advanced_short parent_short
  case_dir=$(make_case parked-run-advanced-ancestor-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  parent_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD~1)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ancestor-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$parent_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ancestor-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ancestor-anchor: teardown aborted on an ancestor-only anchor"
  pass "an ancestor-only anchor never binds an advanced parked run to this task"
}

# The branch's newest same-branch row is TERMINAL at an unfetched head: a
# finished run is history, never the branch's current run, and the anchored
# older row never answers for it. Teardown must not conclude a run from a
# stale terminal row.
test_parked_terminal_unfetched_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 08:20)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-unfetched: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-unfetched: teardown concluded a run from a terminal unfetched row"
  pass "a terminal unfetched-head row is stale history and never concludes a run"
}

# The crafted d15 boundary, tightened deliberately: the axi-reported head is
# unresolvable and the branch's newest ledger row is TERMINAL at exactly this
# worktree's head - a perfectly anchored, already-finished run. A finished run
# is history, so the ledger fallback authorizes cleanup only when its proved
# answer is the explicitly active word (`running`): a terminal newest row,
# even anchored at this head, never authorizes an abort. The runs log proves
# the fallback actually engaged, so the refusal is this tightened boundary
# and not an earlier guard.
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-newest-at-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-newest-at-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-03 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-newest-at-head: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-terminal-newest-at-head: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-newest-at-head: teardown aborted a run whose newest anchored ledger row is terminal"
  pass "a terminal newest row anchored at this worktree's head never authorizes an abort"
}

# The branch's newest row resolves in this copy to a head that DIVERGED from
# this worktree's HEAD (the branch was rewritten or moved on by a newer run
# from another worktree of the same project): not equal, not a descendant,
# so the shared rule answers nothing and every older row - including this
# task's parked run - stays stale history. Neither this task's run nor the
# unrelated newer run may be concluded here.
test_parked_run_behind_diverged_newer_row_is_never_aborted() {
  local case_dir rc advanced_short diverged_short
  case_dir=$(make_case parked-run-behind-newer-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-behind-newer-row"
  # A newer fm/task-x1 head that THIS copy resolves but that diverged from
  # the worktree's HEAD: rewritten from origin/main and pushed over the
  # branch (the fixture origin allows the non-fast-forward rewrite), then
  # fetched into the project clone (shared object store).
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards false
  git clone -q "$case_dir/origin.git" "$case_dir/newer-clone"
  git -C "$case_dir/newer-clone" checkout -q origin/main
  git -C "$case_dir/newer-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "newer run's diverged work"
  git -C "$case_dir/newer-clone" push -q --force origin HEAD:fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  diverged_short=$(git -C "$case_dir/wt" rev-parse --short=7 origin/fm/task-x1)
  git -C "$case_dir/wt" merge-base --is-ancestor HEAD "$diverged_short" \
    && fail "parked-run-behind-newer-row: fixture broke - the newer row is a descendant, not diverged"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$diverged_short" 2026-09-03 09:00)
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 07:55)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-behind-newer-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-behind-newer-row: teardown concluded this task from another run's ledger row"
  pass "a resolvable diverged newer same-branch row makes every older row stale history; no run is concluded"
}

# Two consecutive unresolvable running rows for the branch: the ledger cannot
# prove which row is current or where the submission boundary is. Ambiguity
# must refuse, never guess.
test_parked_advanced_run_ambiguous_rows_are_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-advanced-ambiguous)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir" 2)
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ambiguous"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 08:30)
$(ledger_row failed fm/other-task ccccccc 2026-09-03 08:10)
$(ledger_row running fm/task-x1 ddddddd 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ambiguous: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ambiguous: teardown guessed through ambiguous ledger rows"
  pass "consecutive unresolvable rows are ambiguous and never conclude a run"
}

# The ledger proves the continuation, but the run is NOT parked at a gate -
# it is autonomously running/fixing against the daemon's own clone. Teardown
# must leave that work alone even when the attribution proof would bind it.
test_ledger_proven_continuation_never_aborts_active_run() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-ledger-active)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-ledger-active"

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-ledger-active: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-ledger-active: teardown aborted an actively running run the ledger happened to bind"
  pass "a ledger-proven continuation is still left alone while the run is autonomously active"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  assert_present "$case_dir/state/task-x1.teardown-processes" \
    "leaked-process-reap: teardown removed the durable process identity audit"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_process_identity_is_recorded_before_term_and_kill() {
  local case_dir rc pid journal expected_start expected_cwd epoch signal audit_pid birth command start cwd matched
  case_dir=$(make_case durable-process-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  journal="$case_dir/state/task-x1.teardown-processes"
  teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
    my ($journal, $seen, $ready) = @ARGV;
    $SIG{TERM} = sub {
      open my $in, "<", $journal or die "signal arrived without audit";
      local $/; my $audit = <$in>;
      open my $out, ">", $seen or die "open observation";
      print {$out} $audit; close $out;
    };
    open my $ready_file, ">", $ready or die "ready"; close $ready_file;
    while (1) { sleep 300; }
PERL
  )" "$journal" "$case_dir/term-observed" "$case_dir/ready"
  pid=$TEARDOWN_FIXTURE_PID
  local i=0
  while [ ! -e "$case_dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case_dir/ready" ] || { teardown_fixture_stop "$pid"; fail "durable-process-identity: process not ready"; }
  expected_start=$(LC_ALL=C ps -p "$pid" -o lstart=)
  expected_cwd=$(cd "$case_dir/wt" && pwd -P)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "durable-process-identity: leaked process survived"
  fi
  expect_code 0 "$rc" "durable-process-identity: teardown should succeed"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/term-observed" \
    "durable-process-identity: TERM preceded its durable identity record"
  assert_grep $'\tKILL\t'"$pid"$'\t' "$journal" \
    "durable-process-identity: KILL has no durable identity record"
  IFS=$'\t' read -r epoch signal audit_pid birth command start cwd matched < "$case_dir/term-observed"
  case "$epoch" in ''|*[!0-9]*) fail "durable-process-identity: invalid timestamp" ;; esac
  case "$command" in *perl*) ;; *) fail "durable-process-identity: command line missing" ;; esac
  case "$birth" in lstart=*|starttime=*) ;; *) fail "durable-process-identity: birth identity missing" ;; esac
  [ "$signal" = TERM ] && [ "$audit_pid" = "$pid" ] \
    || fail "durable-process-identity: signal target missing"
  [ "$start" = "$(printf '%q' "$expected_start")" ] \
    || fail "durable-process-identity: process start time missing or incorrect"
  [ "$cwd" = "$(printf '%q' "$expected_cwd")" ] && [ "$matched" = "$cwd" ] \
    || fail "durable-process-identity: cwd or matched open path missing or incorrect"
  pass "a real leaked process observes its durable identity audit before TERM, and KILL is audited too"
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

test_nested_registered_worktree_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped nested-worktree-custody project
  pass "registered nested-lane and unrelated processes and records remain untouched on forced teardown"
}

test_sibling_clone_nested_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped sibling-nested-worktree-custody sibling
  pass "a nested lane registered by a sibling clone of the project is never signalled on forced teardown"
}

test_registered_lane_missing_git_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped missing-git-lane-custody project no-git
  pass "a still-registered nested lane whose .git is missing is never signalled through outer-worktree discovery"
}

test_deleted_registered_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped deleted-lane-custody project deleted
  pass "a process inside a deleted but still-registered nested lane is never signalled"
}

test_sibling_clone_missing_git_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped sibling-missing-git-lane-custody sibling no-git
  pass "a sibling lane without its .git is preserved because its custody is unproven"
}

test_sibling_clone_deleted_lane_process_is_not_reaped() {
  assert_nested_lane_process_is_not_reaped sibling-deleted-lane-custody sibling deleted
  pass "a deleted sibling lane process is preserved because its custody is unproven"
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

test_own_deleted_cwd_process_is_not_reaped() {
  assert_unknown_descendant_process_is_not_reaped own-deleted-cwd-custody wt deleted
  assert_unknown_descendant_process_is_not_reaped tasktmp-deleted-cwd-custody tasktmp deleted
  pass "deleted descendants of worktree and non-Git tasktmp roots survive without a signal audit"
}

test_ordinary_descendant_process_is_not_reaped() {
  assert_unknown_descendant_process_is_not_reaped ordinary-descendant-custody wt none
  assert_unknown_descendant_process_is_not_reaped tasktmp-descendant-custody tasktmp none
  pass "ordinary existing descendants of worktree and non-Git tasktmp roots require proven custody"
}

test_process_refusal_has_no_close_replay_authority() {
  local scenario case_dir root pid other_pid birth other_birth rc path_without_lsof
  local flags=()
  for scenario in descendant foreign missing-lsof audit tasktmp legacy existing-marker; do
    case_dir=$(make_case "refusal-replay-$scenario")
    mkdir -p "$case_dir/home/state"
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" landed.txt "delivered work" "landed process fixture"
    git -C "$case_dir/wt" push -q origin HEAD:main
    git -C "$case_dir/project" fetch -q origin
    seed_backlog_in_flight "$case_dir"
    root="$case_dir/wt"
    flags=(--force --drop-file "$(fm_test_drop_file)")
    case "$scenario" in
      descendant|existing-marker|legacy)
        mkdir "$root/dist"
        root="$root/dist"
        if [ "$scenario" = legacy ]; then
          write_legacy_meta "$case_dir" no-mistakes ship
          flags+=(--legacy-record)
        fi
        ;;
      foreign)
        git clone -q "$case_dir/origin.git" "$case_dir/sibling"
        git -C "$case_dir/sibling" worktree add -q --detach "$root/foreign" main
        git -C "$case_dir/sibling" worktree lock "$root/foreign"
        root="$root/foreign"
        ;;
      missing-lsof)
        path_without_lsof=$(make_path_without_lsof "$case_dir")
        ln -s "$(command -v tasks-axi)" "$path_without_lsof/tasks-axi"
        ln -s "$(command -v node)" "$path_without_lsof/node"
        PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
          && fail "refusal-replay-$scenario: fixture exposes lsof"
        ;;
      audit) mkdir "$case_dir/state/task-x1.teardown-processes" ;;
      tasktmp)
        root="$case_dir/tasktmp"
        mkdir -p "$root/dist"
        mkdir -p "$case_dir/pool/1"
        git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
        ln -s "pool/1/project" "$case_dir/wt"
        printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
          "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
        printf 'task=other-task\nhome=%s\n' "$case_dir/other-home" > "$case_dir/pool/1/.fm-slot-owner"
        cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/slot-owner.before"
        fm_write_meta "$case_dir/state/task-x1.meta" \
          "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
          "worktree=$case_dir/wt" "project=$case_dir/project" "tasktmp=$root" \
          "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
        root="$root/dist"
        ;;
    esac
    mkdir "$case_dir/unrelated"
    fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
    cp "$case_dir/state/task-x1.meta" "$case_dir/task-x1.meta.before"
    cp "$case_dir/state/unrelated.meta" "$case_dir/unrelated.meta.before"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = list-windows ]; then
  echo "can't find session: firstmate" >&2
  exit 1
fi
if [ "\${1:-}" = kill-window ]; then
  printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log"
fi
exit 0
SH
    chmod +x "$case_dir/fakebin/tmux"
    teardown_fixture_start "$root" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    birth=$(teardown_fixture_birth "$pid") || fail "refusal-replay-$scenario: missing process identity"
    teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
    other_pid=$TEARDOWN_FIXTURE_PID
    other_birth=$(teardown_fixture_birth "$other_pid") || fail "refusal-replay-$scenario: missing unrelated identity"
    sleep 0.3
    if [ "$scenario" = existing-marker ]; then
      FM_STATE_OVERRIDE="$case_dir/state" bash -c '
        . "$1/bin/fm-tasks-axi-lib.sh"
        . "$1/bin/fm-backlog-transition-lib.sh"
        fm_backlog_close_marker_stage "$2/state/.prior-close" task-x1 "$2/data" \
          teardown-test-task-x1 "$2/state" 0 &&
        fm_backlog_atomic_transition publish "$2/state/.prior-close" \
          "$2/state/task-x1.backlog-close" "pending-close record" "$2/state"
      ' _ "$ROOT" "$case_dir" > "$case_dir/marker.stdout" 2> "$case_dir/marker.stderr" \
        || fail "refusal-replay-$scenario: cannot seed existing replay authority"
    fi
    rc=0
    if [ "$scenario" = missing-lsof ]; then
      FM_HOME="$case_dir/home" FM_TEARDOWN_TEST_PATH="$path_without_lsof" run_teardown "$case_dir" ${flags[@]+"${flags[@]}"} \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_HOME="$case_dir/home" run_teardown "$case_dir" ${flags[@]+"${flags[@]}"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 1 "$rc" "refusal-replay-$scenario: teardown must refuse"
    case "$scenario" in
      missing-lsof) assert_grep "lsof is unavailable" "$case_dir/stderr" "refusal-replay-$scenario: wrong gate" ;;
      audit) assert_grep "cannot durably record leaked process $pid identity" "$case_dir/stderr" "refusal-replay-$scenario: wrong gate" ;;
      *) assert_grep "REFUSED: process $pid" "$case_dir/stderr" "refusal-replay-$scenario: wrong gate" ;;
    esac
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "refusal-replay-$scenario: refusal changed task metadata"
    assert_absent "$case_dir/state/task-x1.backlog-close" "refusal-replay-$scenario: refusal left replay authority"
    FM_STATE_OVERRIDE="$case_dir/state" bash -c '
      . "$1/bin/fm-tasks-axi-lib.sh"
      . "$1/bin/fm-backlog-transition-lib.sh"
      fm_backlog_close_marker_replay "$2/state" "$2/state/task-x1.backlog-close" "$2/data"
    ' _ "$ROOT" "$case_dir" > "$case_dir/replay.stdout" 2> "$case_dir/replay.stderr" \
      || fail "refusal-replay-$scenario: supported close replay failed"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "refusal-replay-$scenario: replay changed task metadata"
    cmp "$case_dir/unrelated.meta.before" "$case_dir/state/unrelated.meta" \
      || fail "refusal-replay-$scenario: unrelated metadata changed"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "refusal-replay-$scenario: replay closed refused task"
    if [ "$scenario" = tasktmp ]; then
      assert_grep "reassigned" "$case_dir/stderr" "refusal-replay-$scenario: slot ownership gate not reached"
      cmp "$case_dir/slot-owner.before" "$case_dir/pool/1/.fm-slot-owner" \
        || fail "refusal-replay-$scenario: reassigned slot claim changed"
    fi
    assert_present "$case_dir/wt" "refusal-replay-$scenario: worktree removed"
    assert_present "$root" "refusal-replay-$scenario: process root removed"
    assert_absent "$case_dir/endpoint-close.log" "refusal-replay-$scenario: endpoint closed"
    teardown_fixture_live "$pid" "$birth" || fail "refusal-replay-$scenario: refused process identity changed"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "refusal-replay-$scenario: unrelated process identity changed"
    teardown_fixture_stop "$pid"
    teardown_fixture_stop "$other_pid"
  done
  pass "process-gate refusals preserve task metadata, backlog, endpoint and process identities across close replay"
}

test_exempt_retry_clears_prior_close_replay_authority() {
  local scenario case_dir pid birth other_pid other_birth rc real_rm target_alive other_alive
  real_rm=$(command -v rm)
  for scenario in manual missing-backlog; do
    case_dir=$(make_case "exempt-retry-$scenario")
    mkdir -p "$case_dir/home/state" "$case_dir/unrelated"
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    seed_backlog_in_flight "$case_dir"
    fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
    cp "$case_dir/state/task-x1.meta" "$case_dir/task-x1.meta.before"
    cp "$case_dir/state/unrelated.meta" "$case_dir/unrelated.meta.before"
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ -f "$case_dir/state/task-x1.backlog-close" ] || exit 79
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 1
SH
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = kill-window ]; then
  printf '%s\n' "\$*" >> "$case_dir/endpoint-close.log"
fi
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse" "$case_dir/fakebin/tmux"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/initial.stdout" 2> "$case_dir/initial.stderr" || rc=$?
    printf 'initial_rc=%s\n' "$rc" > "$case_dir/initial.observations"
    expect_code 1 "$rc" "exempt-retry-$scenario: initial return must fail"
    assert_present "$case_dir/treehouse.log" "exempt-retry-$scenario: initial teardown did not publish before return"
    assert_present "$case_dir/state/task-x1.backlog-close" "exempt-retry-$scenario: initial failure did not retain close authority"
    cp "$case_dir/state/task-x1.backlog-close" "$case_dir/close.before"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: initial failure changed incarnation metadata"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "exempt-retry-$scenario: initial failure closed backlog"
    rm -f "$case_dir/treehouse.log" "$case_dir/endpoint-close.log"
    case "$scenario" in
      manual) printf '%s\n' manual > "$case_dir/config/backlog-backend" ;;
      missing-backlog) mv "$case_dir/data/backlog.md" "$case_dir/backlog.before" ;;
    esac
    mkdir "$case_dir/wt/dist"
    teardown_fixture_start "$case_dir/wt/dist" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    birth=$(teardown_fixture_birth "$pid") || fail "exempt-retry-$scenario: missing target birth"
    teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
    other_pid=$TEARDOWN_FIXTURE_PID
    other_birth=$(teardown_fixture_birth "$other_pid") || fail "exempt-retry-$scenario: missing unrelated birth"
    cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$case_dir/state/task-x1.backlog-close" ] || exit 1
done
exec "$real_rm" "\$@"
SH
    chmod +x "$case_dir/fakebin/rm"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/clear.stdout" 2> "$case_dir/clear.stderr" || rc=$?
    printf 'clear_rc=%s target_pid=%s target_birth=%s unrelated_pid=%s unrelated_birth=%s\n' \
      "$rc" "$pid" "$birth" "$other_pid" "$other_birth" > "$case_dir/clear.observations"
    expect_code 1 "$rc" "exempt-retry-$scenario: failed invalidation must refuse"
    assert_grep "pending-close record could not be removed" "$case_dir/clear.stderr" \
      "exempt-retry-$scenario: failed invalidation did not reach shared boundary"
    cmp "$case_dir/close.before" "$case_dir/state/task-x1.backlog-close" \
      || fail "exempt-retry-$scenario: failed invalidation changed old marker"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: failed invalidation changed metadata"
    assert_absent "$case_dir/treehouse.log" "exempt-retry-$scenario: failed invalidation returned worktree"
    assert_absent "$case_dir/endpoint-close.log" "exempt-retry-$scenario: failed invalidation closed endpoint"
    assert_absent "$case_dir/state/task-x1.teardown-processes" "exempt-retry-$scenario: failed invalidation audited signal"
    teardown_fixture_live "$pid" "$birth" || fail "exempt-retry-$scenario: failed invalidation changed target"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "exempt-retry-$scenario: failed invalidation changed unrelated process"
    rm -f "$case_dir/fakebin/rm"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "exempt-retry-$scenario: descendant process must refuse"
    assert_grep "REFUSED: process $pid" "$case_dir/stderr" "exempt-retry-$scenario: process gate not reached"
    assert_absent "$case_dir/state/task-x1.backlog-close" "exempt-retry-$scenario: exempt retry retained old authority"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: process refusal changed same-incarnation metadata"
    teardown_fixture_live "$pid" "$birth" || fail "exempt-retry-$scenario: refusal changed target"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "exempt-retry-$scenario: refusal changed unrelated process"
    case "$scenario" in
      manual) rm -f "$case_dir/config/backlog-backend" ;;
      missing-backlog) mv "$case_dir/backlog.before" "$case_dir/data/backlog.md" ;;
    esac
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "exempt-retry-$scenario: refused backlog changed before replay"
    FM_STATE_OVERRIDE="$case_dir/state" bash -c '
      . "$1/bin/fm-tasks-axi-lib.sh"
      . "$1/bin/fm-backlog-transition-lib.sh"
      fm_backlog_close_marker_replay "$2/state" "$2/state/task-x1.backlog-close" "$2/data"
    ' _ "$ROOT" "$case_dir" > "$case_dir/replay.stdout" 2> "$case_dir/replay.stderr" \
      || fail "exempt-retry-$scenario: supported replay failed after restoration"
    cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
      || fail "exempt-retry-$scenario: retry or replay changed same-incarnation metadata"
    cmp "$case_dir/unrelated.meta.before" "$case_dir/state/unrelated.meta" \
      || fail "exempt-retry-$scenario: unrelated metadata changed"
    [ "$(backlog_row_state "$case_dir")" = in_flight ] \
      || fail "exempt-retry-$scenario: replay closed refused task"
    assert_present "$case_dir/wt" "exempt-retry-$scenario: worktree removed"
    assert_present "$case_dir/wt/dist" "exempt-retry-$scenario: descendant root removed"
    assert_absent "$case_dir/treehouse.log" "exempt-retry-$scenario: refusal returned worktree"
    assert_absent "$case_dir/endpoint-close.log" "exempt-retry-$scenario: refusal closed endpoint"
    assert_absent "$case_dir/state/task-x1.teardown-processes" "exempt-retry-$scenario: refusal audited signal"
    teardown_fixture_live "$pid" "$birth" || fail "exempt-retry-$scenario: target PID/birth changed"
    teardown_fixture_live "$other_pid" "$other_birth" || fail "exempt-retry-$scenario: unrelated PID/birth changed"
    target_alive=0
    other_alive=0
    teardown_fixture_live "$pid" "$birth" && target_alive=1
    teardown_fixture_live "$other_pid" "$other_birth" && other_alive=1
    printf 'mode=%s rc=%s target_pid=%s target_birth=%s target_alive=%s unrelated_pid=%s unrelated_birth=%s unrelated_alive=%s term_audit=0 kill_audit=0\n' \
      "$scenario" "$rc" "$pid" "$birth" "$target_alive" "$other_pid" "$other_birth" "$other_alive" \
      > "$case_dir/observations"
    teardown_fixture_stop "$pid"
    teardown_fixture_stop "$other_pid"
  done
  pass "manual and missing-backlog retries revoke old close authority before process refusal and restored replay"
}

test_process_audit_collection_exit_races() {
  local signal field outcome case_dir pid birth other_pid other_birth journal rc i term_audit kill_audit target_alive other_alive
  for signal in TERM KILL; do
    for field in command lstart; do
      for outcome in exit live-failure uncertain-live-failure control; do
        [ "$outcome" != uncertain-live-failure ] || [ "$field" = lstart ] || continue
        [ "$outcome" != control ] || { [ "$signal" = TERM ] && [ "$field" = command ]; } || continue
        case_dir=$(make_case "audit-collection-$signal-$field-$outcome")
        mkdir -p "$case_dir/home/state" "$case_dir/unrelated"
        write_meta "$case_dir" no-mistakes ship
        land_shippable_commit "$case_dir"
        journal="$case_dir/state/task-x1.teardown-processes"
        cp "$case_dir/state/task-x1.meta" "$case_dir/task-x1.meta.before"
        teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
          my ($ready, $exit, $journal, $seen) = @ARGV;
          $SIG{TERM} = sub {
            open my $in, "<", $journal or die "TERM without durable audit";
            local $/; my $audit = <$in>; close $in;
            open my $out, ">", $seen or die "signal observation";
            print {$out} $audit; close $out;
          };
          open my $f, ">", $ready or die "ready"; close $f;
          until (-e $exit) { select undef, undef, undef, 0.01; }
PERL
        )" "$case_dir/ready" "$case_dir/finite-exit" "$journal" "$case_dir/term-observed"
        pid=$TEARDOWN_FIXTURE_PID
        birth=$(teardown_fixture_birth "$pid") || fail "audit-collection: missing target birth"
        i=0
        while [ ! -f "$case_dir/ready" ] && [ "$i" -lt 1000 ]; do sleep 0.01; i=$((i + 1)); done
        [ -f "$case_dir/ready" ] || fail "audit-collection: finite process not ready"
        teardown_fixture_start "$case_dir/unrelated" KILL sleep 300
        other_pid=$TEARDOWN_FIXTURE_PID
        other_birth=$(teardown_fixture_birth "$other_pid") || fail "audit-collection: missing unrelated birth"
        fm_write_meta "$case_dir/state/unrelated.meta" "worktree=$case_dir/unrelated" "kind=ship"
        cp "$case_dir/state/unrelated.meta" "$case_dir/unrelated.meta.before"
        cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
args=" $* "
boundary=0
if [[ "$args" == *" -p $FM_AUDIT_TARGET "* ]]; then
  if [[ "$args" == *" -o lstart= "* ]] && [ -f "$FM_AUDIT_CASE/lstart-failed" ]; then
    exit 1
  fi
  if [[ "$args" == *" -o command= "* ]]; then
    n=0
    [ ! -f "$FM_AUDIT_CASE/command-count" ] || read -r n < "$FM_AUDIT_CASE/command-count"
    n=$((n + 1))
    printf '%s\n' "$n" > "$FM_AUDIT_CASE/command-count"
    round=1
    [ "$FM_AUDIT_SIGNAL" != KILL ] || round=2
    if [ "$n" -eq "$round" ]; then
      if [ "$FM_AUDIT_FIELD" = command ]; then
        boundary=1
      else
        command_output=$(LC_ALL=C "$REAL_PS_FOR_TEST" "$@") || exit 76
        [ -n "$command_output" ] || exit 77
        : > "$FM_AUDIT_CASE/lstart-armed"
        printf '%s\n' "$command_output"
        exit 0
      fi
    fi
  elif [[ "$args" == *" -o lstart= "* ]] && [ -f "$FM_AUDIT_CASE/lstart-armed" ]; then
    rm -f "$FM_AUDIT_CASE/lstart-armed"
    boundary=1
  fi
fi
if [ "$boundary" -eq 1 ]; then
  teardown_fixture_live "$FM_AUDIT_TARGET" "$FM_AUDIT_BIRTH" || exit 78
  printf '%s\t%s\t%s\n' "$FM_AUDIT_SIGNAL" "$FM_AUDIT_FIELD" "$FM_AUDIT_BIRTH" \
    >> "$FM_AUDIT_CASE/boundary.log"
  case "$FM_AUDIT_OUTCOME" in
    live-failure) exit 1 ;;
    uncertain-live-failure) : > "$FM_AUDIT_CASE/lstart-failed"; exit 1 ;;
    exit)
      : > "$FM_AUDIT_CASE/finite-exit"
      for ((i=0; i<1000; i++)); do
        state=$("$REAL_PS_FOR_TEST" -p "$FM_AUDIT_TARGET" -o stat= 2>/dev/null) || break
        [ -n "$state" ] || break
        sleep 0.01
      done
      [ "$i" -lt 1000 ] || exit 79
      printf 'exited\n' >> "$FM_AUDIT_CASE/exit-confirmed"
      ;;
  esac
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
        cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf 'returned\n' >> "$case_dir/treehouse.log"
exit 0
SH
        chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"
        rc=0
        FM_HOME="$case_dir/home" FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
        FM_AUDIT_CASE="$case_dir" FM_AUDIT_TARGET="$pid" FM_AUDIT_BIRTH="$birth" \
        FM_AUDIT_SIGNAL="$signal" FM_AUDIT_FIELD="$field" FM_AUDIT_OUTCOME="$outcome" \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        term_audit=0
        kill_audit=0
        if [ -f "$journal" ]; then
          grep -q $'\tTERM\t'"$pid"$'\t' "$journal" && term_audit=1
          grep -q $'\tKILL\t'"$pid"$'\t' "$journal" && kill_audit=1
        fi
        target_alive=0
        other_alive=0
        teardown_fixture_live "$pid" "$birth" && target_alive=1
        teardown_fixture_live "$other_pid" "$other_birth" && other_alive=1
        printf 'signal=%s field=%s outcome=%s rc=%s target_pid=%s target_birth=%s target_alive=%s unrelated_pid=%s unrelated_birth=%s unrelated_alive=%s term_audit=%s kill_audit=%s\n' \
          "$signal" "$field" "$outcome" "$rc" "$pid" "$birth" "$target_alive" \
          "$other_pid" "$other_birth" "$other_alive" "$term_audit" "$kill_audit" \
          > "$case_dir/observations"
        assert_grep "$signal"$'\t'"$field"$'\t'"$birth" "$case_dir/boundary.log" \
          "audit-collection-$signal-$field-$outcome: collection boundary not reached with original birth"
        case "$outcome" in
          live-failure|uncertain-live-failure)
            expect_code 1 "$rc" "audit-collection-$signal-$field: live collection failure must refuse"
            teardown_fixture_live "$pid" "$birth" || fail "audit-collection-$signal-$field: live failure signalled target"
            cmp "$case_dir/task-x1.meta.before" "$case_dir/state/task-x1.meta" \
              || fail "audit-collection-$signal-$field: live failure changed task metadata"
            assert_present "$case_dir/wt" "audit-collection-$signal-$field: live failure removed worktree"
            assert_absent "$case_dir/treehouse.log" "audit-collection-$signal-$field: live failure returned worktree"
            assert_grep "cannot durably record leaked process $pid identity" "$case_dir/stderr" \
              "audit-collection-$signal-$field: live failure did not name audit refusal"
            ;;
          exit|control)
            expect_code 0 "$rc" "audit-collection-$signal-$field-$outcome: cleanup should complete"
            if teardown_fixture_live "$pid" "$birth"; then
              fail "audit-collection-$signal-$field-$outcome: target survived"
            fi
            assert_absent "$case_dir/state/task-x1.meta" "audit-collection-$signal-$field-$outcome: task metadata retained"
            assert_present "$case_dir/treehouse.log" "audit-collection-$signal-$field-$outcome: worktree return not reached"
            [ "$outcome" != exit ] || assert_present "$case_dir/exit-confirmed" \
              "audit-collection-$signal-$field: wrapper did not synchronize natural exit"
            ;;
        esac
        if [ "$outcome" = control ]; then
          [ "$term_audit" -eq 1 ] && [ "$kill_audit" -eq 1 ] \
            || fail "audit-collection-$signal-$field: control lacks durable TERM/KILL"
        else
          [ "$kill_audit" -eq 0 ] || fail "audit-collection-$signal-$field-$outcome: failed collection audited KILL"
          if [ "$signal" = TERM ]; then
            [ "$term_audit" -eq 0 ] || fail "audit-collection-$signal-$field-$outcome: failed collection audited TERM"
            assert_absent "$case_dir/term-observed" "audit-collection-$signal-$field-$outcome: TERM reached target"
          else
            [ "$term_audit" -eq 1 ] || fail "audit-collection-KILL-$field-$outcome: prior TERM was not audited"
          fi
        fi
        if [ "$term_audit" -eq 1 ]; then
          assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/term-observed" \
            "audit-collection-$signal-$field-$outcome: TERM preceded durable audit"
        fi
        teardown_fixture_live "$other_pid" "$other_birth" \
          || fail "audit-collection-$signal-$field-$outcome: unrelated PID/birth changed"
        cmp "$case_dir/unrelated.meta.before" "$case_dir/state/unrelated.meta" \
          || fail "audit-collection-$signal-$field-$outcome: unrelated metadata changed"
        teardown_fixture_stop "$pid"
        teardown_fixture_stop "$other_pid"
      done
    done
  done
  pass "TERM and KILL audit collection tolerates synchronized real exits, refuses live failures, and preserves unrelated identities"
}

test_process_audit_failure_refuses_before_signal() {
  local case_dir rc pid survived=0
  case_dir=$(make_case process-audit-failure)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir "$case_dir/state/task-x1.teardown-processes"
  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null && survived=1
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "process-audit-failure: teardown must refuse"
  [ "$survived" -eq 1 ] || fail "process-audit-failure: signal sent without durable audit"
  assert_present "$case_dir/state/task-x1.meta" "process-audit-failure: task record removed"
  assert_grep "cannot durably record leaked process $pid identity" "$case_dir/stderr" \
    "process-audit-failure: missing refusal reason"
  pass "an unwritable process audit refuses before signalling a real leaked process"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  teardown_fixture_start "$case_dir/tasktmp" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_refuses_without_signalling() {
  local case_dir rc pid path_without_lsof survived=0
  case_dir=$(make_case lsof-absent-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-refusal: fixture path unexpectedly exposes lsof"

  teardown_fixture_start "$case_dir/wt" KILL perl -e 'setpgrp(0, 0); exec "sleep", "300"'
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-refusal: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null && survived=1
  teardown_fixture_stop "$pid"

  expect_code 1 "$rc" "lsof-absent-refusal: teardown should refuse even with force"
  [ "$survived" -eq 1 ] || fail "lsof-absent-refusal: an unaudited signal reached the pane process group"
  assert_grep "(lsof is unavailable, so no signal target can be audited)" "$case_dir/stderr" \
    "lsof-absent-refusal: teardown did not explain the missing-lsof refusal"
  assert_present "$case_dir/wt" "lsof-absent-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-absent-refusal: teardown removed task metadata"
  assert_absent "$case_dir/state/task-x1.teardown-processes" \
    "lsof-absent-refusal: an unscanned process was recorded as a signal target"
  pass "missing lsof refuses teardown instead of sending unaudited process-group signals"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  teardown_fixture_start "$case_dir" KILL perl -e "$(cat <<'PERL'
$SIG{TERM} = "IGNORE"; sleep 300
PERL
  )"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 4 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  teardown_fixture_stop "$pid"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "reused-pid-identity: the original identity was not sent TERM before the grace period"
  assert_no_grep $'\tKILL\t' "$case_dir/state/task-x1.teardown-processes" \
    "reused-pid-identity: a KILL was audited for a changed identity"
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '$SIG{TERM} = "IGNORE"; sleep 300';
PERL
    )" "$marker" "$done_flag"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    teardown_fixture_stop "$pid"
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  teardown_fixture_start "$case_dir/wt" HUP perl -e "$(cat <<'PERL'
      use POSIX qw(SIG_BLOCK SIG_SETMASK SIGTERM SIGHUP SIGINT SIGQUIT);
      require $ENV{FM_TEARDOWN_FIXTURE_HELPERS};
      my ($file, $ready) = @ARGV;
      my ($child, $leave_child);
      END {
        if (defined $child && $child > 0 && !$leave_child) {
          kill "KILL", $child;
          waitpid($child, 0);
        }
      }
      $SIG{HUP} = sub {
        exit 0;
      };
      $SIG{TERM} = sub {
        return if defined $child;
        my $old = POSIX::SigSet->new;
        my $blocked = POSIX::SigSet->new(SIGTERM, SIGHUP, SIGINT, SIGQUIT);
        POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
        $child = fork();
        die "fork" unless defined $child;
        if (!$child) {
          $SIG{TERM} = $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = "DEFAULT";
          POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
          exec "sleep", "300"; die "exec";
        }
        fixture_track($child);
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh or die "close";
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        $leave_child = 1;
        exit 0;
      };
      open my $fh, ">", $ready or die "ready"; close $fh;
      sleep 300;
PERL
    )" "$child_file" "$case_dir/ready"
  pid=$TEARDOWN_FIXTURE_PID
  local i=0
  while [ ! -e "$case_dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case_dir/ready" ] || fail "grace-spawn-convergence: parent not ready"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    teardown_fixture_stop "$child_pid"
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    teardown_fixture_stop "$pid"
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc spawner i=0
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # A real parent outside the task roots immediately replenishes leaked children.
  # Each killed child has a distinct kernel birth identity and a real cwd.
  teardown_fixture_start "$case_dir" TERM perl -e "$(cat <<'PERL'
    use POSIX qw(SIG_BLOCK SIG_SETMASK SIGTERM SIGINT SIGHUP SIGQUIT WNOHANG);
    require $ENV{FM_TEARDOWN_FIXTURE_HELPERS};
    my ($root, $ready) = @ARGV;
    my ($child, $stopping);
    my $owner = $$;
    my $blocked = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP, SIGQUIT);
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{QUIT} = sub { $stopping = 1; };
    END {
      if ($owner == $$) {
        kill "KILL", $child if defined $child;
        waitpid($child, 0) if defined $child;
        unlink $ready;
      }
    }
    while (!$stopping) {
      my $old = POSIX::SigSet->new;
      POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
      $child = fork(); defined $child or die "fork";
      if (!$child) {
        $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{QUIT} = "DEFAULT";
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        chdir $root or die "chdir";
        my $birth = fixture_track($$);
        open my $fh, ">", "$ready.$$" or die "ready";
        print {$fh} "$$\t$birth\n";
        close $fh or die "close readiness";
        rename "$ready.$$", $ready or die "publish readiness";
        exec "sleep", "300"; die "exec";
      }
      fixture_track($child);
      POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
      while (!$stopping && defined $child) {
        POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
        my $exited = waitpid($child, WNOHANG);
        undef $child if $exited != 0;
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        select undef, undef, undef, 0.01 if defined $child && !$stopping;
      }
      unlink $ready;
    }
PERL
  )" "$case_dir/wt" "$case_dir/child-ready"
  spawner=$TEARDOWN_FIXTURE_PID
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
for ((i=0; i<1000; i++)); do
  if IFS=$'\t' read -r pid birth < "$FM_FAKE_CHILD_READY" 2>/dev/null \
     && teardown_fixture_live "$pid" "$birth"; then
    exec "$REAL_LSOF_FOR_TEST" "$@"
  fi
  sleep 0.01
done
printf 'fixture child never became ready\n' >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
  while [ ! -s "$case_dir/child-ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$case_dir/child-ready" ] || fail "persistent-reap-refusal: child not ready"
  rc=0
  FM_FAKE_CHILD_READY="$case_dir/child-ready" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  teardown_fixture_stop "$spawner"

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  teardown_fixture_stop "$pid"

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
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
  docker_store_add "$store" volume other-data "fm.task=task-x2"
  # A longer sibling task in the same home claims task-x1-v2-pg.
  fm_write_meta "$case_dir/state/task-x1-v2.meta" "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1-v2"
  printf '%s\n' "$case_dir"
}

test_teardown_removes_the_tasks_own_docker_stacks() {
  local case_dir rc
  case_dir=$(make_docker_case docker-own-stacks)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" \
  FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-own-stacks: teardown should succeed: $(cat "$case_dir/stderr")"
  assert_equals "gre1675-throwaway-pg other-compose-1 other-db supabase_db_vernant task-x1-cache task-x1-v2-pg task-x10-pg " \
    "$(docker_store_names "$case_dir/docker-store" container)" \
    "docker-own-stacks: wrong containers remained"
  assert_equals "other_default supabase_network_vernant task-x1_shared " \
    "$(docker_store_names "$case_dir/docker-store" network)" \
    "docker-own-stacks: wrong networks remained"
  assert_equals "other-data task-x1_pgdata " \
    "$(docker_store_names "$case_dir/docker-store" volume)" \
    "docker-own-stacks: wrong volumes remained"
  assert_grep "removing Docker container(s) owned by task-x1" "$case_dir/stderr" \
    "docker-own-stacks: teardown did not say which containers it removed"
  pass "teardown removes the task's labelled, named, compose-project and worktree-compose stacks and leaves every other Docker object"
}

test_docker_removal_failure_keeps_the_task_records_until_a_rerun_succeeds() {
  local case_dir rc
  case_dir=$(make_docker_case docker-rm-fails)
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
echo returned >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_RM_FAIL=task-x1-test-pg \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-rm-fails: an owned container that survives removal must stop teardown"
  assert_grep "task-x1-test-pg" "$case_dir/stderr" "docker-rm-fails: the surviving container was not named"
  assert_present "$case_dir/state/task-x1.meta" "docker-rm-fails: the task record was removed while a container survived"
  assert_absent "$case_dir/treehouse.log" "docker-rm-fails: the worktree was returned while a container survived"
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-rm-fails: the rerun should finish: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "docker-rm-fails: the rerun left the task record"
  assert_equals "other_default supabase_network_vernant task-x1_shared " \
    "$(docker_store_names "$case_dir/docker-store" network)" \
    "docker-rm-fails: partial container removal lost derived network ownership on retry"
  pass "an owned container that cannot be removed stops teardown with the record kept, and a rerun finishes it"
}

test_forced_teardown_retains_records_after_a_docker_removal_failure() {
  local case_dir rc
  case_dir=$(make_docker_case docker-rm-fails-forced)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_RM_FAIL=task-x1-test-pg \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-rm-fails-forced: --force must not bypass Docker cleanup"
  assert_present "$case_dir/state/task-x1.meta" "docker-rm-fails-forced: task identity was retired"
  assert_present "$case_dir/wt" "docker-rm-fails-forced: worktree was removed"
  assert_grep "task-x1-test-pg" "$case_dir/docker-store" "docker-rm-fails-forced: fixture did not retain the failed container"
  pass "--force retains task identity when Docker container removal fails"
}

test_stopped_docker_daemon_blocks_teardown() {
  local case_dir rc
  case_dir=$(make_docker_case docker-daemon-down)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_DOWN=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-daemon-down: unavailable Docker must stop teardown"
  assert_present "$case_dir/state/task-x1.meta" "docker-daemon-down: task identity was retired"
  assert_present "$case_dir/wt" "docker-daemon-down: worktree was removed"
  assert_grep "task-x1-test-pg" "$case_dir/docker-store" "docker-daemon-down: Docker state changed"
  pass "an unavailable Docker daemon refuses teardown and retains task identity"
}

test_teardown_without_a_docker_binary_skips_docker_cleanup() {
  local case_dir rc before
  case_dir=$(make_docker_case docker-absent)
  before=$(cat "$case_dir/docker-store")
  rm -f "$case_dir/fakebin/docker"
  rc=0
  FM_TEARDOWN_TEST_PATH=$(fm_test_base_path_sans "$PATH" docker) \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-absent: teardown without Docker should succeed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "docker-absent: task record was not retired"
  assert_equals "$before" "$(cat "$case_dir/docker-store")" "docker-absent: Docker state changed"
  pass "a host without Docker retires task records without changing Docker state"
}

test_docker_configured_supabase_identity_vetoes_all_heuristics() {
  local case_dir store protected rc
  for protected in runtime-shared task-x1; do
    case_dir=$(make_docker_case "docker-protected-$protected")
    store="$case_dir/docker-store"
    : > "$store"
    mkdir -p "$case_dir/project/supabase"
    printf 'project_id = "%s" # shared stack\n\n[api]\nenabled = true\n' "$protected" \
      > "$case_dir/project/supabase/config.toml"
    docker_store_add "$store" container c-name task-x1-supabase-db "com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-project task-x1-cross-project "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-path shared-path "com.docker.compose.project=$protected;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" container c-primary task-x1-primary "com.docker.compose.project=project;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" container c-marker marked-task "fm.task=task-x1;com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-own own-path "com.docker.compose.project=isolated;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" network n-cross cross-project "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" network n-reverse reverse-project "com.docker.compose.project=$protected;com.supabase.cli.project=task-x1"
    docker_store_add "$store" network n-marker marked-network "fm.task=task-x1;com.supabase.cli.project=$protected"
    rc=0
    FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$protected: teardown failed: $(cat "$case_dir/stderr")"
    assert_equals "shared-path task-x1-cross-project task-x1-supabase-db " \
      "$(docker_store_names "$store" container)" "$protected: protected project was claimed by a heuristic"
    assert_equals "cross-project reverse-project " "$(docker_store_names "$store" network)" \
      "$protected: protected network was claimed or explicit marker was ignored"
  done
  pass "actual configured Supabase identity vetoes names, paths and either project label, but not explicit markers"
}

test_docker_project_labels_require_the_exact_task_id() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-exact-project)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-compose exact-compose "com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-supabase exact-supabase "com.supabase.cli.project=task-x1" ""
  docker_store_add "$store" container c-prefix prefixed-compose "com.docker.compose.project=task-x1-stack" ""
  docker_store_add "$store" container c-prefix2 prefixed-supabase "com.supabase.cli.project=task-x1_stack" ""
  docker_store_add "$store" container c-name task-x1-db "" ""
  docker_store_add "$store" container c-exact-name task-x1 "" ""
  docker_store_add "$store" container c-name2 task-x1_cache "" ""
  docker_store_add "$store" container c-sibling task-x1-v2-db "" ""
  docker_store_add "$store" network n-compose exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supabase exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-prefix prefixed-compose "com.docker.compose.project=task-x1-stack"
  docker_store_add "$store" network n-prefix2 prefixed-supabase "com.supabase.cli.project=task-x1_stack"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "exact-project: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "prefixed-compose prefixed-supabase task-x1-v2-db " "$(docker_store_names "$store" container)" \
    "exact-project: project prefixes or live sibling names were claimed"
  assert_equals "prefixed-compose prefixed-supabase " "$(docker_store_names "$store" network)" \
    "exact-project: project prefix network was claimed"
  pass "project labels match only the exact id while container names retain boundary and live-sibling rules"
}

test_docker_workdirs_canonicalize_and_exclude_foreign_lanes_and_tasktmp() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-canonical-paths)
  store="$case_dir/docker-store"
  : > "$store"
  mkdir -p "$case_dir/wt/own-stack" "$case_dir/tasktmp/stack" "$case_dir/foreign/stack"
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wt/git-lane" main
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wt/registered-lane" main
  git -C "$case_dir/project" worktree lock "$case_dir/wt/registered-lane"
  rm -f "$case_dir/wt/registered-lane/.git"
  ln -s "$case_dir/wt" "$case_dir/wt-alias"
  ln -s "$case_dir/foreign" "$case_dir/wt/foreign-link"
  ln -s "$case_dir/wt/git-lane" "$case_dir/git-alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$case_dir/wt-alias" \
    "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "tasktmp=$case_dir/tasktmp" "spawn_gen=teardown-test-task-x1"
  fm_write_meta "$case_dir/state/foreign-lane.meta" "kind=ship" "worktree=$case_dir/wt/registered-lane"
  docker_store_add "$store" container c-own own-real-path "com.docker.compose.project.working_dir=$case_dir/wt/own-stack" ""
  docker_store_add "$store" container c-alias own-alias-path "com.docker.compose.project.working_dir=$case_dir/wt-alias/own-stack" ""
  docker_store_add "$store" container c-git nested-git-path "com.docker.compose.project.working_dir=$case_dir/git-alias" ""
  docker_store_add "$store" container c-reg nested-record-path "com.docker.compose.project.working_dir=$case_dir/wt-alias/registered-lane" ""
  docker_store_add "$store" container c-foreign symlink-foreign "com.docker.compose.project.working_dir=$case_dir/wt/foreign-link/stack" ""
  docker_store_add "$store" container c-tmp temporary-path "com.docker.compose.project.working_dir=$case_dir/tasktmp/stack" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "canonical-paths: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "nested-git-path nested-record-path symlink-foreign temporary-path " "$(docker_store_names "$store" container)" \
    "canonical-paths: canonical custody or worktree-only boundary was ignored"
  assert_present "$case_dir/state/foreign-lane.meta" "canonical-paths: foreign task record was removed"
  assert_present "$case_dir/wt/git-lane" "canonical-paths: nested Git worktree was removed"
  pass "Docker workdir ownership canonicalizes both sides and excludes nested lanes, foreign symlinks and task temp roots"
}

test_docker_mixed_project_carriers_spare_empty_heuristic_networks() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-mixed-networks)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-task own-exact "fm.task=task-x1;com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-other foreign-exact "fm.task=other;com.supabase.cli.project=task-x1" ""
  docker_store_add "$store" container c-derived own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" container c-foreign foreign-derived "com.supabase.cli.project=derived" ""
  docker_store_add "$store" container c-all own-dual "com.docker.compose.project=all-owned;com.supabase.cli.project=all-owned-supa;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-exact empty-exact "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-exact-supa empty-exact-supa "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-derived empty-derived "com.docker.compose.project=derived"
  docker_store_add "$store" network n-derived-supa empty-derived-supa "com.supabase.cli.project=derived"
  docker_store_add "$store" network n-owned all-owned-net "com.docker.compose.project=all-owned"
  docker_store_add "$store" network n-owned-supa all-owned-supa-net "com.supabase.cli.project=all-owned-supa"
  docker_store_add "$store" network n-explicit explicit-mixed "fm.task=task-x1;com.docker.compose.project=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "mixed-networks: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "foreign-derived foreign-exact " "$(docker_store_names "$store" container)" \
    "mixed-networks: wrong project carriers were removed"
  assert_equals "all-owned-supa-net empty-derived empty-derived-supa empty-exact empty-exact-supa " "$(docker_store_names "$store" network)" \
    "mixed-networks: foreign project label did not veto an empty heuristic network or all-owned propagation failed"
  pass "foreign project carriers veto empty heuristic networks, all-owned projects propagate and explicit markers remain authoritative"
}

test_docker_latest_foreign_carriers_veto_network_removal() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-latest-carriers)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-exact own-exact "fm.task=task-x1;com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-derived own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$case_dir/arriving-containers" container c-foreign arriving-foreign \
    "fm.task=other;com.docker.compose.project=task-x1;com.supabase.cli.project=derived" ""
  docker_store_add "$store" network n-exact exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supa exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-derived derived-compose "com.docker.compose.project=derived"
  docker_store_add "$store" network n-derived-supa derived-supabase "com.supabase.cli.project=derived"
  docker_store_add "$store" network n-marked explicitly-owned "fm.task=task-x1;com.docker.compose.project=derived"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_ADD_AFTER_RM="$case_dir/arriving-containers" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "latest-carriers: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "arriving-foreign " "$(docker_store_names "$store" container)" \
    "latest-carriers: foreign carrier was removed"
  assert_equals "derived-compose derived-supabase exact-compose exact-supabase " "$(docker_store_names "$store" network)" \
    "latest-carriers: latest foreign evidence was ignored or explicit marker was vetoed"
  pass "foreign carriers observed after container removal veto both project-label heuristics but not explicit network markers"
}

test_standalone_secondmate_skips_docker_cleanup() {
  local case_dir posture rc
  for posture in ordinary forced; do
    case_dir=$(make_case "docker-secondmate-$posture")
    write_meta "$case_dir" local-only secondmate
    mkdir -p "$case_dir/secondmate-home/state"
    printf '%s\n' task-x1 > "$case_dir/secondmate-home/.fm-secondmate-home"
    printf 'home=%s\n' "$case_dir/secondmate-home" >> "$case_dir/state/task-x1.meta"
    rc=0
    if [ "$posture" = forced ]; then
      FM_FAKE_DOCKER_DOWN=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_FAKE_DOCKER_DOWN=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 0 "$rc" "$posture secondmate: teardown failed: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$posture secondmate: supervisor record was not retired"
    assert_absent "$case_dir/secondmate-home" "$posture secondmate: supervisor home was not removed"
    assert_absent "$case_dir/docker.log" "$posture secondmate: standalone retirement contacted Docker"
  done
  pass "standalone secondmate retirement skips Docker even when the daemon is unavailable"
}

test_docker_project_record_failure_prevents_container_removal() {
  local case_dir store rc before
  case_dir=$(make_docker_case docker-project-record-failure)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
  before=$(cat "$case_dir/state/task-x1.meta")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$case_dir/fakebin/mv"
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$case_dir/state/task-x1.meta" "$case_dir/wt" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "project-record-failure: cleanup ignored failed record publication"
  assert_equals "$before" "$(cat "$case_dir/state/task-x1.meta")" \
    "project-record-failure: existing task metadata was changed"
  assert_equals "own-derived " "$(docker_store_names "$store" container)" \
    "project-record-failure: container was removed before its project identity was retained"
  assert_equals "derived-network " "$(docker_store_names "$store" network)" \
    "project-record-failure: network was removed after record failure"
  pass "failed project-identity publication preserves the task record and container evidence"
}

test_docker_ambiguous_ids_trust_only_worktree_evidence() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-ambiguous-id)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-name task-x1-db "" ""
  docker_store_add "$store" container c-label marked-only "fm.task=task-x1" ""
  docker_store_add "$store" container c-project exact-project "com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-path own-worktree "com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-label marked-network "fm.task=task-x1"
  docker_store_add "$store" volume marked-volume "fm.task=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 1 "" "$2" "$3"' \
      _ "$ROOT" "$case_dir/state/task-x1.meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ambiguous-id: cleanup failed: $(cat "$case_dir/stderr")"
  assert_equals "exact-project marked-only task-x1-db " "$(docker_store_names "$store" container)" \
    "ambiguous-id: ambiguous identity authorized removal"
  assert_equals "marked-network " "$(docker_store_names "$store" network)" "ambiguous-id: ambiguous network marker was trusted"
  assert_equals "marked-volume " "$(docker_store_names "$store" volume)" "ambiguous-id: ambiguous volume marker was trusted"
  pass "ambiguous task ids authorize only worktree evidence"
}

test_docker_all_failure_channels_retain_forced_tasks_until_retry() {
  local channel case_dir store rc fail_operation ps_fail rm_error network_fail volume_fail
  for channel in initial-ps verify-ps final-ps container-rm container-rm-error network-ls volume-ls network-rm volume-rm; do
    case_dir=$(make_docker_case "docker-failure-$channel")
    store="$case_dir/docker-store"
    : > "$store"
    : > "$case_dir/state/task-x1.status"
    docker_store_add "$store" container c-own owned-container "com.docker.compose.project=derived;com.supabase.cli.project=derived-supa;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" network n-own owned-network "com.docker.compose.project=derived"
    docker_store_add "$store" network n-supa owned-supa-project-network "com.docker.compose.project=derived-supa"
    docker_store_add "$store" volume owned-volume "fm.task=task-x1"
    cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' returned >> "$case_dir/retired"
EOF
    chmod +x "$case_dir/fakebin/treehouse"
    fail_operation= ps_fail= rm_error= network_fail= volume_fail=
    case "$channel" in
      initial-ps) fail_operation=ps ;;
      verify-ps) ps_fail=2 ;;
      final-ps) ps_fail=3 ;;
      container-rm) fail_operation=rm ;;
      container-rm-error) rm_error=1 ;;
      network-ls) fail_operation=network-ls ;;
      volume-ls) fail_operation=volume-ls ;;
      network-rm) network_fail=owned-network ;;
      volume-rm) volume_fail=owned-volume ;;
    esac
    rc=0
    FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_FAIL="$fail_operation" \
      FM_FAKE_DOCKER_PS_FAIL_AT="$ps_fail" FM_FAKE_DOCKER_RM_ERROR_AFTER_REMOVE="$rm_error" \
      FM_FAKE_DOCKER_NETWORK_RM_FAIL="$network_fail" FM_FAKE_DOCKER_VOLUME_RM_FAIL="$volume_fail" \
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$channel: --force bypassed Docker failure"
    assert_present "$case_dir/state/task-x1.meta" "$channel: task metadata was removed"
    assert_present "$case_dir/state/task-x1.status" "$channel: task status was removed"
    assert_present "$case_dir/wt" "$channel: worktree was removed"
    assert_absent "$case_dir/retired" "$channel: worktree return ran before confirmed Docker cleanup"
    assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" "$channel: teardown falsely reported completion"
    if [ "$channel" != initial-ps ]; then
      assert_grep 'docker_projects= derived derived-supa' "$case_dir/state/task-x1.meta" \
        "$channel: retained task record lost its derived project identities"
    fi
    if [ "$channel" = network-rm ]; then
      assert_equals "" "$(docker_store_names "$store" container)" "$channel: regression requires container removal to succeed"
      assert_equals "owned-network owned-supa-project-network " "$(docker_store_names "$store" network)" \
        "$channel: regression requires derived networks to survive the first attempt"
    fi
    rc=0
    FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
    expect_code 0 "$rc" "$channel: retry failed: $(cat "$case_dir/retry.stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$channel: retry did not retire metadata"
    assert_equals "" "$(docker_store_names "$store" container)" "$channel: owned container survived retry"
    assert_equals "" "$(docker_store_names "$store" network)" "$channel: owned network survived retry"
    assert_equals "" "$(docker_store_names "$store" volume)" "$channel: owned volume survived retry"
  done
  pass "every Docker listing, verification and removal failure retains forced task records until a successful retry"
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
  local backend=$1 case_dir home store child rc pid head
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
    mkdir -p "$case_dir/$child-tmp"
    printf 'tasktmp=%s\n' "$case_dir/$child-tmp" >> "$home/state/$child.meta"
    teardown_fixture_start "$case_dir/$child-wt" KILL sleep 300
    printf '%s\n' "$TEARDOWN_FIXTURE_PID" > "$case_dir/$child-worktree.pid"
    teardown_fixture_start "$case_dir/$child-tmp" KILL sleep 300
    printf '%s\n' "$TEARDOWN_FIXTURE_PID" > "$case_dir/$child-tasktmp.pid"
    head=$(git -C "$case_dir/$child-wt" rev-parse HEAD)
    parked_axi_status_toon "fm/$child" "$head" "$child-run" > "$case_dir/$child-pipeline-status"
    if [ "$backend" = orca ]; then
      fm_write_meta "$home/state/$child.meta" \
        "window=fm-$child" "endpoint_task_id=$child" \
        "worktree=$case_dir/$child-wt" "project=$case_dir/project" \
        "kind=ship" "mode=local-only" "backend=orca" \
        "terminal=$child-terminal" "orca_worktree_id=$case_dir/project::$case_dir/$child-wt" \
        "tasktmp=$case_dir/$child-tmp"
    fi
  done
  cp "$case_dir/fakebin/no-mistakes" "$case_dir/fakebin/no-mistakes-default"
  cat > "$case_dir/fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
child=\${PWD##*/}
child=\${child%-wt}
case "\$child" in
  child-a|child-b)
    case "\${1:-} \${2:-}" in
      "axi status")
        if [ -e "$case_dir/\$child-pipeline-aborted" ]; then
          printf 'run:\n  id: "%s-run"\n  outcome: cancelled\n' "\$child"
        else
          cat "$case_dir/\$child-pipeline-status"
        fi
        ;;
      "axi abort") : > "$case_dir/\$child-pipeline-aborted" ;;
    esac
    ;;
  *) exec "$case_dir/fakebin/no-mistakes-default" "\$@" ;;
esac
EOF
  chmod +x "$case_dir/fakebin/no-mistakes"
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
  assert_grep child-a "$case_dir/closed.log" "$backend child: endpoint was not quiesced before Docker failure"
  assert_present "$case_dir/child-a-pipeline-aborted" "$backend child: pipeline remained parked"
  for child in worktree tasktmp; do
    pid=$(cat "$case_dir/child-a-$child.pid")
    if kill -0 "$pid" 2>/dev/null; then
      fail "$backend child: $child process survived Docker cleanup"
    fi
  done
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
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "$backend child: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "$backend child: retry retained secondmate home"
  assert_absent "$case_dir/state/task-x1.meta" "$backend child: retry retained parent"
  assert_equals "foreign-child " "$(docker_store_names "$store" container)" "$backend child: wrong child objects survived"
  assert_equals "" "$(docker_store_names "$store" network)" "$backend child: child network survived"
  assert_equals "" "$(docker_store_names "$store" volume)" "$backend child: child volume survived"
  assert_absent "$case_dir/race-created" "$backend child: a live endpoint created a container during network cleanup"
  assert_present "$case_dir/child-b-pipeline-aborted" "$backend child: child-b pipeline remained parked"
  for child in worktree tasktmp; do
    pid=$(cat "$case_dir/child-b-$child.pid")
    if kill -0 "$pid" 2>/dev/null; then
      fail "$backend child: child-b $child process survived retirement"
    fi
  done
  assert_grep child-a:clean "$case_dir/boundary.log" "$backend child: child-a Docker cleanup was not observed before destruction"
  assert_grep child-b:clean "$case_dir/boundary.log" "$backend child: child-b workdir cleanup was not observed before destruction"
  assert_no_grep dirty "$case_dir/boundary.log" "$backend child: destructive operation ran before its own Docker cleanup"
}

test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries() {
  assert_forced_child_docker_cleanup_and_retry tmux
  pass "forced secondmate quiesces child endpoints, pipelines and processes before Docker cleanup and retains failures for retry"
}

test_forced_orca_children_quiesce_before_docker_and_worktree_removal() {
  assert_forced_child_docker_cleanup_and_retry orca
  pass "forced Orca children quiesce before Docker cleanup and retain identity and worktrees on failure"
}

test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries() {
  local case_dir home nested_home store rc
  case_dir=$(make_case docker-grandchild)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"
  nested_home="$home/nested-home"
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  : > "$case_dir/child-producers/grandchild-herdr.live"
  printf '%s\n' grandchild-herdr > "$case_dir/current-child"
  : > "$store"
  docker_store_add "$store" container c-grandchild owned-grandchild "fm.task=grandchild-herdr" ""
  docker_store_add "$store" container c-path grandchild-path "com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" container c-foreign foreign-grandchild "fm.task=other" ""
  docker_store_add "$store" network n-grandchild grandchild-network "fm.task=grandchild-herdr"
  docker_store_add "$store" volume grandchild-volume "fm.task=grandchild-herdr"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_RM_FAIL=owned-grandchild FM_FAKE_HERDR_CONFIRMED_GONE=1 \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "grandchild: Docker failure must stop recursive retirement"
  assert_present "$case_dir/state/task-x1.meta" "grandchild: parent identity retired"
  assert_present "$home/state/nested-sm.meta" "grandchild: nested secondmate identity retired"
  assert_present "$nested_home/state/grandchild-herdr.meta" "grandchild: grandchild identity retired"
  assert_present "$nested_home/state/grandchild-herdr.status" "grandchild: grandchild status retired"
  assert_present "$nested_home" "grandchild: nested home removed"
  assert_present "$case_dir/closed" "grandchild: endpoint was not quiesced before Docker cleanup"
  assert_equals "foreign-grandchild owned-grandchild " "$(docker_store_names "$store" container)" \
    "grandchild: containers produced before quiescence survived the cleanup attempt"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_HERDR_CONFIRMED_GONE=1 \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "grandchild: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "grandchild: retry retained secondmate homes"
  assert_absent "$case_dir/state/task-x1.meta" "grandchild: retry retained parent record"
  assert_equals "foreign-grandchild " "$(docker_store_names "$store" container)" "grandchild: wrong Docker objects survived"
  assert_equals "" "$(docker_store_names "$store" network)" "grandchild: network survived"
  assert_equals "" "$(docker_store_names "$store" volume)" "grandchild: volume survived"
  pass "recursive forced secondmate cleanup quiesces the grandchild before Docker cleanup and retains failed identity for retry"
}

test_docker_container_arriving_during_resource_cleanup_blocks_retirement() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-late-container)
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  : > "$store"
  docker_store_add "$store" container c-own owned-container "fm.task=task-x1" ""
  docker_store_add "$case_dir/arriving-containers" container c-late arriving-container "fm.task=task-x1" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "late-container: cleanup falsely reported success"
  assert_present "$case_dir/state/task-x1.meta" "late-container: retry identity was retired"
  assert_present "$case_dir/wt" "late-container: worktree was retired"
  assert_equals "arriving-container " "$(docker_store_names "$store" container)" "late-container: arrival was not exercised"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "late-container: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "late-container: retry retained identity"
  assert_equals "" "$(docker_store_names "$store" container)" "late-container: owned arrival survived retry"
  pass "a container arriving during network cleanup blocks retirement until retry removes it"
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

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  cp "$ROOT/bin/fm-nm-run-lib.sh" "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  chmod 000 "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  if [ -r "$case_dir/test-root/bin/fm-nm-run-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-session-lock-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc log closed
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  prepare_teardown_source_copy "$case_dir"
  log="$case_dir/herdr.log"
  closed="$case_dir/closed"
  : > "$log"
  rm -f "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source"
  [ ! -s "$log" ] || fail "missing-child-source: teardown reached the child's runtime with its required source missing"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the secondmate home"
  ln -s "$ROOT/bin/fm-transition-lib.sh" "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_copied_teardown "$case_dir" --force > "$case_dir/restored.stdout" 2> "$case_dir/restored.stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "restored-child-source: teardown ignored the unresolvable child runtime"
  [ -s "$log" ] || fail "restored-child-source: the valid fixture never reached child runtime admission: $(cat "$case_dir/restored.stderr")"
  assert_source_refusal_preserved_state "$case_dir" "restored-child-source"
  [ -e "$home/state/child-herdr.meta" ] || fail "restored-child-source: the refusal erased the child record"
  [ ! -e "$closed" ] || fail "restored-child-source: refusal attempted a child close"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:fm-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/fm-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the secondmate home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced secondmate with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  FM_HOME="${FM_HOME:-$case_dir/primary-home}" \
  FM_ROOT_OVERRIDE="$case_dir/test-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

test_task_teardown_preserves_another_homes_abandoned_worker() {
  local case_dir foreign_root pid rc
  case_dir=$(make_case caller-confined-reaping)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  prepare_teardown_source_copy "$case_dir"
  foreign_root="$case_dir/other-home"
  mkdir -p "$foreign_root/bin"
  cat > "$foreign_root/bin/fm-remote-job-worker.sh" <<'SH'
#!/usr/bin/env bash
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit' TERM
sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
child=$!
printf '%s\n' ready > "$FM_FOREIGN_WORKER_READY"
wait "$child"
SH
  teardown_fixture_start "$case_dir" TERM env FM_FOREIGN_WORKER_READY="$case_dir/foreign-ready" \
    perl -e 'setpgrp(0, 0); exec @ARGV' \
    "$BASH" "$foreign_root/bin/fm-remote-job-worker.sh" --serve
  pid=$TEARDOWN_FIXTURE_PID
  local tries=0
  while [ ! -e "$case_dir/foreign-ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if [ ! -e "$case_dir/foreign-ready" ]; then
    fail "caller-confinement: foreign worker did not start"
  fi
  rm -rf "$foreign_root"

  # Bound the administrative reaper's account scan to our one real fixture
  # process, never any actual account worker. Other ps queries stay native.
  cat > "$case_dir/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ]; then
  exec "$REAL_PS_FOR_TEST" -p "$pid" -o pid=,command=
fi
exec "$REAL_PS_FOR_TEST" "\$@"
SH
  chmod +x "$case_dir/fakebin/ps"
  rc=0
  run_copied_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "caller-confinement: task teardown killed another home's abandoned worker"
  fi
  teardown_fixture_stop "$pid"
  expect_code 0 "$rc" "caller-confinement: ordinary task teardown should complete"
  assert_absent "$case_dir/state/task-x1.meta" \
    "caller-confinement: ordinary task cleanup did not complete"
  pass "task teardown completes without reaping another home's abandoned worker"
}

teardown_test_cases=(
test_task_teardown_preserves_another_homes_abandoned_worker
test_missing_startup_source_refuses_before_cleanup
test_unreadable_startup_source_refuses_before_cleanup
test_missing_adapter_sibling_refuses_before_cleanup
test_forced_child_missing_adapter_sibling_refuses_before_cleanup
test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup
test_retained_sources_still_reach_the_ordinary_refusal
test_process_refusal_has_no_close_replay_authority
test_exempt_retry_clears_prior_close_replay_authority
test_local_only_fork_remote_allows
test_teardown_does_not_wait_for_the_home_summary_refresh
test_teardown_closes_the_backlog_item_itself
test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note
test_teardown_manual_backend_leaves_the_backlog_to_the_operator
test_local_only_truly_unpushed_refuses
test_local_only_merged_to_local_main_allows
test_no_mistakes_pushed_branch_without_merge_refuses
test_drop_file_without_force_is_a_usage_error
test_forced_dirty_landed_deliverables_retain_captain_words
test_scout_report_must_be_a_regular_nonempty_file
test_no_mistakes_truly_unpushed_refuses
test_local_only_force_overrides_unpushed
test_secondmate_pr_registration_publishes_ready_line
test_secondmate_home_teardown_delivers_final_line_or_refuses
test_teardown_missing_busy_sidecar_completes
test_herdr_teardown_clears_escalation_marker
test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes
test_herdr_flat_teardown_refuses_records_on_unparseable_presence
test_herdr_flat_teardown_preflight_refuses_before_changes
test_herdr_teardown_presentation_lock_namespace_is_per_account
test_forced_secondmate_herdr_child_preflight_refuses_before_changes
test_forced_secondmate_teardown_holds_descendant_lifecycle_locks
test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed
test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed
test_herdr_projection_teardown_retires_journal_only_after_confirmed_close
test_herdr_projection_teardown_retains_journal_when_close_unconfirmed
test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup
test_teardown_retires_task_watcher_markers_and_orphan_journal
test_teardown_retains_journal_bound_to_another_pane
test_teardown_retires_v1_journal_when_projected_workspace_gone
test_teardown_retains_v1_journal_when_projected_workspace_present
test_teardown_retains_v1_journal_when_workspace_query_ambiguous
test_squash_merged_branch_deleted_allows
test_squash_merged_pr_allows_when_head_ancestor_of_pr_head
test_no_pr_recorded_discovers_merged_pr_by_branch_allows
test_squash_merged_pr_allows_replayed_unpushed_patch
test_merged_pr_with_later_local_commit_refuses
test_squash_merged_rebased_branch_allows
test_squash_merged_same_file_different_content_refuses
test_squash_merged_rebased_local_with_unlanded_commit_refuses
test_squash_merged_stale_local_refuses_when_forge_unreachable
test_pr_check_does_not_refresh_stale_pr_head
test_pr_check_records_remote_head_when_local_lags
test_content_in_default_fallback_allows
test_content_fallback_uses_recorded_base_branch
test_content_fallback_refreshes_stale_origin_ref
test_dirty_worktree_refuses
test_untracked_only_refusal_diagnostic
test_tracked_edit_refusal_diagnostic
test_mixed_refusal_diagnostic
test_gh_error_and_content_absent_refuses
test_legacy_record_without_the_flag_refuses
test_windowless_legacy_record_with_gone_worktree_refuses
test_windowless_legacy_record_with_gone_worktree_refuses_with_legacy_flag
test_ship_without_git_copy_completes_with_recorded_merged_pr
test_ship_without_git_copy_refuses_unconfirmed_pr
test_ship_without_git_copy_requires_captain_words_to_drop
test_windowless_legacy_record_still_refuses_unlanded_work
test_windowless_record_outside_the_leftover_class_still_refuses
test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag
test_legacy_record_teardown_completes_when_landed_and_endpoint_dead
test_legacy_record_teardown_refuses_unlanded_work
test_legacy_record_teardown_refuses_an_ambiguous_endpoint
test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails
test_retained_legacy_stamp_still_faces_the_endpoint_gate
test_legacy_record_never_accepts_a_corrupt_spawn_gen
test_stale_index_lock_cleared_and_teardown_succeeds
test_live_index_lock_is_never_removed_and_teardown_refuses
test_lsof_error_never_clears_index_lock
test_stale_index_lock_cleanup_rechecks_dirty_worktree
test_non_linked_index_lock_path_is_checked_from_worktree
test_index_lock_mtime_read_failure_refuses
test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds
test_persistent_index_lock_exhausts_retries_and_refuses_loudly
test_empty_retry_wait_uses_default_without_aborting
test_fractional_legacy_retry_wait_refuses_without_arithmetic_error
test_teardown_records_the_task_pipeline_spend
test_teardown_skips_pipeline_spend_when_disabled
test_teardown_records_unavailable_spend_for_a_gone_worktree
test_parked_own_run_is_aborted_before_teardown
test_parked_own_run_concludes_on_passed_with_override_after_abort
test_parked_own_run_concludes_on_passed_with_skips_after_abort
test_parked_run_advanced_past_unfetched_head_is_still_aborted
test_parked_run_with_mismatched_ledger_head_is_never_aborted
test_parked_run_with_malformed_ledger_row_is_never_aborted
test_parked_run_with_impossible_ledger_date_is_never_aborted
test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback
test_parked_run_advanced_head_locally_fetched_is_still_aborted
test_parked_advanced_run_without_anchor_is_never_aborted
test_parked_advanced_run_ancestor_anchor_is_never_aborted
test_parked_terminal_unfetched_row_is_never_aborted
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted
test_parked_run_behind_diverged_newer_row_is_never_aborted
test_parked_advanced_run_ambiguous_rows_are_never_aborted
test_ledger_proven_continuation_never_aborts_active_run
test_parked_own_run_refuses_when_abort_is_unconfirmed
test_mismatched_run_after_abort_refuses_unconfirmed
test_empty_status_after_abort_refuses_unconfirmed
test_not_found_status_after_abort_confirms_completion
test_another_branchs_parked_run_is_never_touched
test_own_autonomous_run_is_left_alone
test_leaked_worktree_process_is_reaped
test_leaked_tasktmp_process_is_reaped
test_process_identity_is_recorded_before_term_and_kill
test_process_audit_collection_exit_races
test_nested_registered_worktree_process_is_not_reaped
test_sibling_clone_nested_lane_process_is_not_reaped
test_registered_lane_missing_git_process_is_not_reaped
test_deleted_registered_lane_process_is_not_reaped
test_sibling_clone_missing_git_lane_process_is_not_reaped
test_sibling_clone_deleted_lane_process_is_not_reaped
test_own_deleted_cwd_process_is_not_reaped
test_ordinary_descendant_process_is_not_reaped
test_process_audit_failure_refuses_before_signal
test_lsof_absent_refuses_without_signalling
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
test_teardown_removes_the_tasks_own_docker_stacks
test_docker_removal_failure_keeps_the_task_records_until_a_rerun_succeeds
test_forced_teardown_retains_records_after_a_docker_removal_failure
test_stopped_docker_daemon_blocks_teardown
test_teardown_without_a_docker_binary_skips_docker_cleanup
test_docker_configured_supabase_identity_vetoes_all_heuristics
test_docker_project_labels_require_the_exact_task_id
test_docker_workdirs_canonicalize_and_exclude_foreign_lanes_and_tasktmp
test_docker_mixed_project_carriers_spare_empty_heuristic_networks
test_docker_latest_foreign_carriers_veto_network_removal
test_standalone_secondmate_skips_docker_cleanup
test_docker_project_record_failure_prevents_container_removal
test_docker_ambiguous_ids_trust_only_worktree_evidence
test_docker_all_failure_channels_retain_forced_tasks_until_retry
test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries
test_forced_orca_children_quiesce_before_docker_and_worktree_removal
test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries
test_docker_container_arriving_during_resource_cleanup_blocks_retirement
)

# Validate the complete selection before running any behavioral case.
for requested_case in "$@"; do
  registered_case=false
  for test_case in "${teardown_test_cases[@]}"; do
    if [ "$requested_case" = "$test_case" ]; then
      registered_case=true
      break
    fi
  done
  if [ "$registered_case" = false ]; then
    printf 'Unknown test case: %s\n' "$requested_case" >&2
    printf 'Usage: bash tests/fm-teardown.test.sh [test_function_name ...]\n' >&2
    exit 2
  fi
done

for test_case in "${teardown_test_cases[@]}"; do
  if [ "$#" -eq 0 ]; then
    "$test_case"
    continue
  fi
  for requested_case in "$@"; do
    if [ "$requested_case" = "$test_case" ]; then
      "$test_case"
      break
    fi
  done
done
