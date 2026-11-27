#!/usr/bin/env bash
# Tests for bin/fm-landing-loop.py and bin/fm-landing-loop-install.sh.
# Exercises hermetic stale-base serial admission, conflict wake escalation,
# direct-PR clean merge/push, failed update backoff, and launchd installer seams
# against local bare git repositories and fake gh/no-mistakes shims.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOOP="$ROOT/bin/fm-landing-loop.py"
INSTALL="$ROOT/bin/fm-landing-loop-install.sh"
JQ_BIN=$(command -v jq) || fail "test needs jq"
TMP_ROOT=$(fm_test_tmproot fm-landing-loop-tests)

make_git_pair() {  # <dir> <branch> <pr_file> <base_file> [conflict]
  local dir=$1 branch=$2 pr_file=$3 base_file=$4 conflict=${5:-0}
  local bare="$dir/origin.git" wt="$dir/wt"
  mkdir -p "$dir"
  git init -q --bare "$bare"
  git clone -q "$bare" "$wt"
  git -C "$wt" config user.name 'Firstmate Tests'
  git -C "$wt" config user.email 'tests@example.invalid'
  git -C "$wt" checkout -q -b main
  printf 'initial\n' > "$wt/README.md"
  git -C "$wt" add README.md
  git -C "$wt" commit -q -m 'base initial'
  git -C "$wt" push -q -u origin main
  git -C "$wt" checkout -q -b "$branch"
  printf 'pr change\n' > "$wt/$pr_file"
  git -C "$wt" add "$pr_file"
  git -C "$wt" commit -q -m 'pr work'
  git -C "$wt" push -q -u origin "$branch"
  local pr_head
  pr_head=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q main
  if [ "$conflict" = 1 ]; then
    printf 'conflicting main change\n' > "$wt/$pr_file"
    git -C "$wt" add "$pr_file"
  else
    printf 'main advance\n' > "$wt/$base_file"
    git -C "$wt" add "$base_file"
  fi
  git -C "$wt" commit -q -m 'main advance'
  git -C "$wt" push -q origin main
  local base_tip
  base_tip=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q "$branch"
  printf '%s %s %s\n' "$wt" "$pr_head" "$base_tip"
}

write_fake_gh() {  # <shim_dir> <state_json>
  local shim=$1 data=$2
  mkdir -p "$shim"
  cat > "$shim/gh" <<SH
#!/usr/bin/env python3
import json, sys
data = json.load(open("$data"))
args = sys.argv[1:]
if len(args) >= 3 and args[0] == "pr" and args[1] == "view":
    url = args[2]
    entry = data["prs"].get(url)
    if not entry:
        sys.exit(1)
    print(json.dumps(entry["view"]))
    sys.exit(0)
if len(args) >= 2 and args[0] == "api" and "/compare/" in args[1]:
    ep = args[1]
    for k, v in data["compares"].items():
        if k in ep:
            print(json.dumps(v))
            sys.exit(0)
    sys.exit(1)
if len(args) >= 4 and args[0] == "api" and args[1] == "-X" and args[2] == "PUT" and args[3].endswith("/update-branch"):
    log_path = data.get("update_log")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(" ".join(args) + "\n")
    print(json.dumps({"message": "Updating pull request branch."}))
    sys.exit(0)
sys.exit(1)
SH
  chmod +x "$shim/gh"
}

write_fake_nm() {  # <shim_dir> <log_file> <rc>
  local shim=$1 log=$2 rc=${3:-0}
  mkdir -p "$shim"
  cat > "$shim/fake-duration.py" <<PY
#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if "--" not in args:
    sys.exit(2)
sep = args.index("--")
prefix = args[:sep]
cmd = args[sep + 1:]
with open("$log.duration", "a", encoding="utf-8") as fh:
    fh.write(" ".join(prefix) + "\n")
sys.exit(subprocess.run(cmd).returncode)
PY
  chmod +x "$shim/fake-duration.py"
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf 'status: completed\n'
  exit 0
fi
printf '%s %s\n' "\$PWD" "\$*" >> "$log"
if [ "$rc" -ne 0 ]; then
  printf 'simulated rerun failure\n' >&2
  exit "$rc"
fi
exit 0
SH
  chmod +x "$shim/no-mistakes"
}

wait_for_inflight_done() {  # <home>
  local home=$1 i=0
  while [ "$i" -lt 40 ]; do
    FM_HOME="$home" python3 "$LOOP" step --no-reconcile >/dev/null || return 1
    if [ "$("$JQ_BIN" -r '.inflight | length' "$home/state/.landing-loop/state.json" 2>/dev/null || echo 1)" = 0 ]; then
      return 0
    fi
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

test_serial_admission_updates_one_clean_stale_pr_at_a_time() {
  local dir="$TMP_ROOT/serial" home="$TMP_ROOT/serial/home" shim="$TMP_ROOT/serial/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info1 info2 wt1 head1 tip1 wt2 head2 tip2
  info1=$(make_git_pair "$dir/repo1" "fm/task-a" "a.txt" "main1.txt" 0)
  read -r wt1 head1 tip1 <<< "$info1"
  info2=$(make_git_pair "$dir/repo2" "fm/task-b" "b.txt" "main2.txt" 0)
  read -r wt2 head2 tip2 <<< "$info2"
  local url1="https://github.com/example/repo/pull/101"
  local url2="https://github.com/example/repo/pull/102"
  fm_write_meta "$home/state/task-a.meta" "kind=ship" "mode=no-mistakes" "branch=fm/task-a" "worktree=$wt1" "pr=$url1"
  fm_write_meta "$home/state/task-b.meta" "kind=ship" "mode=no-mistakes" "branch=fm/task-b" "worktree=$wt2" "pr=$url2"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url1": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head1", "headRefName": "fm/task-a", "baseRefName": "main", "baseRefOid": "$tip1", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}},
    "$url2": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head2", "headRefName": "fm/task-b", "baseRefName": "main", "baseRefOid": "$tip2", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head1": {"base_commit": {"sha": "$tip1"}, "behind_by": 2},
    "$head2": {"base_commit": {"sha": "$tip2"}, "behind_by": 3}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  write_fake_nm "$shim" "$dir/nm.log" 0
  local plan_out
  plan_out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" plan --json)
  "$JQ_BIN" -e '.tasks | length == 2 and .[0].task == "task-a" and .[0].action == "update" and .[1].action == "update"' <<<"$plan_out" >/dev/null \
    || fail "plan must list both clean behind PRs in PR-number order: $plan_out"
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" FM_HOME="$home" FM_LANDING_LOOP_MAX_INFLIGHT=1 python3 "$LOOP" step --no-reconcile \
    || fail "first step must succeed"
  "$JQ_BIN" -e '.tasks["task-a"].action == "inflight" and .tasks["task-b"].action == "update"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "serial admission must start only task-a while leaving task-b queued"
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" wait_for_inflight_done "$home" || fail "detached update worker must finish"
  grep -q "$wt1 rerun" "$dir/nm.log" || fail "no-mistakes rerun must have run in task-a worktree"
  grep -q -- "--pipeline-priority merge-train fm-landing-update-task-a" "$dir/nm.log.duration" || fail "rerun must pass --pipeline-priority merge-train"
  pass "landing loop admits one clean stale-base PR at a time in PR-number order and reaps completion"
}

test_conflict_holds_and_emits_single_wake() {
  local dir="$TMP_ROOT/conflict" home="$TMP_ROOT/conflict/home" shim="$TMP_ROOT/conflict/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/task-c" "shared.txt" "unused.txt" 1)
  read -r wt head tip <<< "$info"
  local url="https://github.com/example/repo/pull/103"
  fm_write_meta "$home/state/task-c.meta" "kind=ship" "mode=no-mistakes" "branch=fm/task-c" "worktree=$wt" "pr=$url"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/task-c", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  write_fake_nm "$shim" "$dir/nm.log" 0
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "conflict step must exit 0"
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "repeat conflict step must exit 0"
  [ ! -e "$dir/nm.log" ] || fail "conflicting PR must never launch no-mistakes rerun"
  "$JQ_BIN" -e '.tasks["task-c"].action == "conflict"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "local merge-tree conflict must classify task as conflict"
  local wakes
  wakes=$(grep -c "landing-loop task-c:" "$home/state/.wake-queue" 2>/dev/null || echo 0)
  assert_equals "1" "$wakes" "conflict must emit exactly one deduplicated check wake per head"
  pass "conflicting stale-base PR is held without launching a rerun and wakes Main once"
}

test_direct_pr_updates_server_side_without_mutating_worktree() {
  local dir="$TMP_ROOT/direct" home="$TMP_ROOT/direct/home" shim="$TMP_ROOT/direct/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/direct-a" "direct.txt" "main-direct.txt" 0)
  read -r wt head tip <<< "$info"
  # Place both an ignored local file and an unpushed local commit in the task worktree:
  # server-side update-branch bound to expected_head_sha must leave both untouched and never publish the local commit.
  printf 'ignored-secret\n' > "$wt/.gitignore"
  printf 'local ignored value\n' > "$wt/ignored-secret"
  printf 'local unpushed work\n' > "$wt/unpushed.txt"
  git -C "$wt" add .gitignore unpushed.txt
  git -C "$wt" commit -q -m 'local unpushed commit'
  local local_head
  local_head=$(git -C "$wt" rev-parse HEAD)
  local url="https://github.com/example/repo/pull/104"
  fm_write_meta "$home/state/direct-a.meta" "kind=ship" "mode=direct-PR" "branch=fm/direct-a" "worktree=$wt" "pr=$url"
  cat > "$dir/gh.json" <<JSON
{
  "update_log": "$dir/update.log",
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/direct-a", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "direct-PR step must exit 0"
  PATH="$shim:$PATH" wait_for_inflight_done "$home" || fail "direct-PR update must finish"
  grep -Fq "api -X PUT repos/example/repo/pulls/104/update-branch -f expected_head_sha=$head" "$dir/update.log" \
    || fail "direct-PR must call GitHub server-side update-branch bound to expected_head_sha=$head"
  assert_equals "$local_head" "$(git -C "$wt" rev-parse HEAD)" "direct-PR server-side update must never mutate local worktree HEAD"
  assert_equals "local ignored value" "$(cat "$wt/ignored-secret")" "direct-PR update must never overwrite ignored local files"
  assert_equals "$head" "$(git --git-dir="$dir/repo/origin.git" rev-parse refs/heads/fm/direct-a)" "unpushed local commit must never be pushed to origin"
  pass "direct-PR updates server-side via expected_head_sha without mutating worktree, ignored files, or publishing unpushed commits"
}

test_failed_update_backs_off_and_wakes_main_once() {
  local dir="$TMP_ROOT/fail" home="$TMP_ROOT/fail/home" shim="$TMP_ROOT/fail/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/fail-a" "f.txt" "main-f.txt" 0)
  read -r wt head tip <<< "$info"
  local url="https://github.com/example/repo/pull/105"
  fm_write_meta "$home/state/fail-a.meta" "kind=ship" "mode=no-mistakes" "branch=fm/fail-a" "worktree=$wt" "pr=$url"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/fail-a", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  write_fake_nm "$shim" "$dir/nm.log" 1
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "step launching failing rerun must exit 0"
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" wait_for_inflight_done "$home" || fail "failing update worker must finish"
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "post-failure step must exit 0"
  "$JQ_BIN" -e '.tasks["fail-a"].action == "backoff"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "failed update must enter backoff instead of retrying immediately"
  local wakes
  wakes=$(grep -c "landing-loop fail-a:" "$home/state/.wake-queue" 2>/dev/null || echo 0)
  assert_equals "1" "$wakes" "failed update must emit exactly one wake for the failed head"
  pass "failed update records backoff and wakes Main once"
}

test_launchd_installer_renders_installs_and_uninstalls() {
  local dir="$TMP_ROOT/install" home="$TMP_ROOT/install/home" agents="$TMP_ROOT/install/agents"
  mkdir -p "$home/state" "$agents"
  local fake_lc="$dir/launchctl" loaded_flag="$dir/loaded"
  cat > "$fake_lc" <<SH
#!/usr/bin/env bash
case "\$1" in
  print) [ -f "$loaded_flag" ] ;;
  bootstrap) touch "$loaded_flag" ;;
  bootout) rm -f "$loaded_flag" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fake_lc"
  local printed
  printed=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INSTALL" install --interval 90 --print) || fail "install --print failed"
  grep -q "<integer>90</integer>" <<<"$printed" || fail "rendered plist must carry interval 90"
  grep -q "fm-landing-loop.py" <<<"$printed" || fail "rendered plist must invoke fm-landing-loop.py"
  FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANDING_LOOP_AGENT_DIR="$agents" FM_LANDING_LOOP_LAUNCHCTL="$fake_lc" \
    "$INSTALL" install --interval 60 >/dev/null || fail "install failed"
  local st
  st=$(FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANDING_LOOP_AGENT_DIR="$agents" FM_LANDING_LOOP_LAUNCHCTL="$fake_lc" \
    "$INSTALL" status)
  grep -q "plist=present launchd=loaded" <<<"$st" || fail "expected installed status, got: $st"
  FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANDING_LOOP_AGENT_DIR="$agents" FM_LANDING_LOOP_LAUNCHCTL="$fake_lc" \
    "$INSTALL" uninstall >/dev/null || fail "uninstall failed"
  st=$(FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANDING_LOOP_AGENT_DIR="$agents" FM_LANDING_LOOP_LAUNCHCTL="$fake_lc" \
    "$INSTALL" status)
  grep -q "plist=absent launchd=not-loaded" <<<"$st" || fail "expected uninstalled status, got: $st"
  # FM_TEST_SEAM=1 without explicit overrides must fail closed and never touch ~/Library/LaunchAgents.
  if FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANDING_LOOP_AGENT_DIR="" FM_LANDING_LOOP_LAUNCHCTL="" \
    "$INSTALL" status >/dev/null 2>&1; then
    fail "FM_TEST_SEAM=1 without agent-dir and launchctl overrides must refuse"
  fi
  pass "launchd installer renders valid plist, installs, reports status, enforces test-seam overrides, and uninstalls cleanly"
}

test_dirty_no_mistakes_worktree_held_and_wakes_once() {
  local dir="$TMP_ROOT/dirty" home="$TMP_ROOT/dirty/home" shim="$TMP_ROOT/dirty/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/dirty-a" "u.txt" "main-u.txt" 0)
  read -r wt head tip <<< "$info"
  printf 'dirty uncommitted\n' > "$wt/dirty.txt"
  local url="https://github.com/example/repo/pull/106"
  fm_write_meta "$home/state/dirty-a.meta" "kind=ship" "mode=no-mistakes" "branch=fm/dirty-a" "worktree=$wt" "pr=$url"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/dirty-a", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  write_fake_nm "$shim" "$dir/nm.log" 0
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "dirty step must exit 0"
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "repeat dirty step must exit 0"
  "$JQ_BIN" -e '.tasks["dirty-a"].action == "held"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "dirty no-mistakes worktree must be held"
  [ ! -e "$dir/nm.log" ] || fail "dirty worktree must never launch no-mistakes rerun"
  local wakes
  wakes=$(grep -c "landing-loop dirty-a:" "$home/state/.wake-queue" 2>/dev/null || echo 0)
  assert_equals "1" "$wakes" "held dirty checkout must emit exactly one wake"
  pass "dirty no-mistakes worktree is held without launching rerun and wakes Main once"
}

test_train_plans_and_builds_conflict_free_batch_excluding_conflicts() {
  local dir="$TMP_ROOT/train" home="$TMP_ROOT/train/home" shim="$TMP_ROOT/train/shim"
  local bare="$dir/origin.git" wt="$dir/wt"
  mkdir -p "$home/state" "$home/config" "$home/data" "$dir"
  git init -q --bare "$bare"
  git clone -q "$bare" "$wt"
  git -C "$wt" config user.name 'Firstmate Tests'
  git -C "$wt" config user.email 'tests@example.invalid'
  git -C "$wt" checkout -q -b main
  printf 'base\n' > "$wt/README.md"
  git -C "$wt" add README.md
  git -C "$wt" commit -q -m 'base'
  git -C "$wt" push -q -u origin main
  local tip
  tip=$(git -C "$wt" rev-parse HEAD)
  # PR 201 touches a.txt (clean)
  git -C "$wt" checkout -q -b fm/pr201 main
  printf 'from 201\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m 'pr 201'
  git -C "$wt" push -q origin fm/pr201
  local h201
  h201=$(git -C "$wt" rev-parse HEAD)
  # PR 202 touches b.txt (clean with 201)
  git -C "$wt" checkout -q -b fm/pr202 main
  printf 'from 202\n' > "$wt/b.txt"
  git -C "$wt" add b.txt
  git -C "$wt" commit -q -m 'pr 202'
  git -C "$wt" push -q origin fm/pr202
  local h202
  h202=$(git -C "$wt" rev-parse HEAD)
  # PR 203 touches a.txt differently (conflicts with 201)
  git -C "$wt" checkout -q -b fm/pr203 main
  printf 'conflicting 203\n' > "$wt/a.txt"
  git -C "$wt" add a.txt
  git -C "$wt" commit -q -m 'pr 203'
  git -C "$wt" push -q origin fm/pr203
  local h203
  h203=$(git -C "$wt" rev-parse HEAD)
  # PR 204 targets a different base branch (release) and must be excluded from a main train.
  git -C "$wt" checkout -q -b fm/pr204 main
  printf 'from 204\n' > "$wt/d.txt"
  git -C "$wt" add d.txt
  git -C "$wt" commit -q -m 'pr 204'
  git -C "$wt" push -q origin fm/pr204
  local h204
  h204=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q main
  # Force merge.ff=only in worktree config to prove train build overrides it cleanly.
  git -C "$wt" config merge.ff only
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "https://github.com/example/repo/pull/201": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h201", "headRefName": "fm/pr201", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}},
    "https://github.com/example/repo/pull/202": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h202", "headRefName": "fm/pr202", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}},
    "https://github.com/example/repo/pull/203": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h203", "headRefName": "fm/pr203", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}},
    "https://github.com/example/repo/pull/204": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h204", "headRefName": "fm/pr204", "baseRefName": "release", "baseRefOid": "$tip", "statusCheckRollup": []}}
  },
  "compares": {
    "$h201": {"base_commit": {"sha": "$tip"}, "behind_by": 0}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  local out
  out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" train --repo example/repo --prs 201,202,203,204 --worktree "$wt" --branch fm/train-batch-1 --build --json) \
    || fail "train --build failed"
  "$JQ_BIN" -e '(.selected | map(.number)) == [201, 202] and (.excluded | length) == 2' <<<"$out" >/dev/null \
    || fail "train must select 201+202 and exclude wrong-base 204 and conflicting 203: $out"
  "$JQ_BIN" -e 'any(.excluded[]; .pr == "https://github.com/example/repo/pull/204" and (.reason | contains("targets base release")))' <<<"$out" >/dev/null \
    || fail "train must exclude PR targeting release: $out"
  "$JQ_BIN" -e 'any(.excluded[]; .pr == "https://github.com/example/repo/pull/203" and .reason == "conflicts with train batch")' <<<"$out" >/dev/null \
    || fail "train must exclude conflicting PR 203: $out"
  # Re-running --build with an existing branch name must refuse rather than overwriting it.
  if PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" train --repo example/repo --prs 201,202 --worktree "$wt" --branch fm/train-batch-1 --build --json >/dev/null 2>&1; then
    fail "train --build must refuse to overwrite an existing branch"
  fi
  [ "$(cat "$wt/a.txt")" = "from 201" ] && [ "$(cat "$wt/b.txt")" = "from 202" ] \
    || fail "built train worktree must hold both selected PRs"
  "$JQ_BIN" -r '.closes_block' <<<"$out" | grep -qx '<!-- firstmate-backlog-closes:begin -->' \
    || fail "closes block must start with canonical marker"
  "$JQ_BIN" -r '.closes_block' <<<"$out" | grep -qx 'Train-member: https://github.com/example/repo/pull/201' \
    || fail "closes block must list PR 201"
  "$JQ_BIN" -r '.closes_block' <<<"$out" | grep -qx 'Train-member: https://github.com/example/repo/pull/202' \
    || fail "closes block must list PR 202"
  pass "train command proves cumulative conflict-free batch, excludes wrong-base and conflicting PRs, protects existing branches, builds under merge.ff=only, and emits canonical Train-member closes block"
}

test_unreadable_nm_status_fails_closed() {
  local dir="$TMP_ROOT/nm-status-fail" home="$TMP_ROOT/nm-status-fail/home" shim="$TMP_ROOT/nm-status-fail/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/status-fail" "sf.txt" "main-sf.txt" 0)
  read -r wt head tip <<< "$info"
  local url="https://github.com/example/repo/pull/107"
  fm_write_meta "$home/state/status-fail.meta" "kind=ship" "mode=no-mistakes" "branch=fm/status-fail" "worktree=$wt" "pr=$url"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/status-fail", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  exit 127
fi
printf 'unexpected rerun\n' >> "$dir/nm.log"
exit 0
SH
  chmod +x "$shim/no-mistakes"
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "status-fail step must exit 0"
  "$JQ_BIN" -e '.tasks["status-fail"].action == "busy"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "unreadable/timed-out no-mistakes axi status must fail closed as busy"
  [ ! -e "$dir/nm.log" ] || fail "must not launch rerun when no-mistakes axi status fails"
  # Zero-exit error response with no status: field must also fail closed as busy.
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf 'error: daemon unavailable\n'
  exit 0
fi
printf 'unexpected rerun\n' >> "$dir/nm.log"
exit 0
SH
  chmod +x "$shim/no-mistakes"
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "zero-exit error step must exit 0"
  "$JQ_BIN" -e '.tasks["status-fail"].action == "busy"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "zero-exit status response without status: field must fail closed as busy"
  [ ! -e "$dir/nm.log" ] || fail "must not launch rerun on zero-exit error status response"
  # outcome: passed without status:, or alongside status: running, must stay busy.
  for payload in $'outcome: passed\n' $'status: running\noutcome: passed\n'; do
    cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf '%s' "$payload"
  exit 0
fi
printf 'unexpected rerun\n' >> "$dir/nm.log"
exit 0
SH
    chmod +x "$shim/no-mistakes"
    PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "outcome-only step must exit 0"
    "$JQ_BIN" -e '.tasks["status-fail"].action == "busy"' "$home/state/.landing-loop/state.json" >/dev/null \
      || fail "outcome without terminal status must fail closed as busy"
  done
  [ ! -e "$dir/nm.log" ] || fail "must not launch rerun when status is missing or running"
  # Terminal status ci_monitor_interrupted must be recognized as idle (eligible for update).
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf 'run:\n  status: ci_monitor_interrupted\n'
  exit 0
fi
exit 0
SH
  chmod +x "$shim/no-mistakes"
  local plan_out
  plan_out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" plan --json)
  "$JQ_BIN" -e '.tasks[0].action == "update"' <<<"$plan_out" >/dev/null \
    || fail "ci_monitor_interrupted must be treated as terminal/eligible, got: $plan_out"
  pass "no-mistakes axi status fails closed on exit error and statusless zero-exit errors, and treats ci_monitor_interrupted as terminal"
}

test_detached_update_timeout_terminates_nested_child() {
  local dir="$TMP_ROOT/timeout-child" home="$TMP_ROOT/timeout-child/home" shim="$TMP_ROOT/timeout-child/shim"
  mkdir -p "$home/state" "$home/config" "$home/data" "$shim"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/timeout-a" "t.txt" "main-t.txt" 0)
  read -r wt head tip <<< "$info"
  local url="https://github.com/example/repo/pull/108"
  fm_write_meta "$home/state/timeout-a.meta" "kind=ship" "mode=no-mistakes" "branch=fm/timeout-a" "worktree=$wt" "pr=$url"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/timeout-a", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf 'status: completed\n'
  exit 0
fi
printf '%s\n' "\$\$" > "$dir/child.pid"
exec sleep 60
SH
  chmod +x "$shim/no-mistakes"
  cat > "$shim/fake-duration.py" <<PY
#!/usr/bin/env python3
import os, signal, subprocess, sys
args = sys.argv[1:]
cmd = args[args.index("--") + 1:]
child = subprocess.Popen(cmd, start_new_session=True)
def forward(sig, _f):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except OSError:
        pass
signal.signal(signal.SIGTERM, forward)
sys.exit(child.wait())
PY
  chmod +x "$shim/fake-duration.py"
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" \
    FM_LANDING_LOOP_UPDATE_TIMEOUT=1 FM_HOME="$home" python3 "$LOOP" step --no-reconcile \
    || fail "timeout step must exit 0"
  PATH="$shim:$PATH" FM_TEST_SEAM=1 FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" \
    FM_LANDING_LOOP_UPDATE_TIMEOUT=1 wait_for_inflight_done "$home" \
    || fail "timed-out update worker must exit and be reaped"
  local cpid
  cpid=$(cat "$dir/child.pid" 2>/dev/null || true)
  [ -n "$cpid" ] || fail "nested child must have started and written its pid"
  if kill -0 "$cpid" 2>/dev/null; then
    kill -9 "$cpid" 2>/dev/null || true
    fail "nested child pid $cpid survived the update timeout"
  fi
  pass "detached update timeout forwards SIGTERM through wrapper and terminates nested child process group"
}

fm_test_run_cases \
  test_serial_admission_updates_one_clean_stale_pr_at_a_time \
  test_conflict_holds_and_emits_single_wake \
  test_direct_pr_updates_server_side_without_mutating_worktree \
  test_dirty_no_mistakes_worktree_held_and_wakes_once \
  test_unreadable_nm_status_fails_closed \
  test_detached_update_timeout_terminates_nested_child \
  test_failed_update_backs_off_and_wakes_main_once \
  test_train_plans_and_builds_conflict_free_batch_excluding_conflicts \
  test_launchd_installer_renders_installs_and_uninstalls -- "$@"
