#!/usr/bin/env bash
# Tests for bin/fm-landing-loop.py and bin/fm-landing-loop-install.sh.
# Exercises hermetic stale-base serial admission, conflict wake escalation,
# direct-PR server-side update-branch, failed update backoff, the reconcile
# phase, train batches, and launchd installer seams against local bare git
# repositories and fake gh/no-mistakes/launchctl shims.
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
if len(args) >= 2 and args[0] == "api" and args[1] == "graphql":
    kv = {}
    for i, tok in enumerate(args):
        if tok in ("-F", "-f") and i + 1 < len(args) and "=" in args[i + 1]:
            k, v = args[i + 1].split("=", 1)
            kv[k] = v
    url = f"https://github.com/{kv.get('owner','')}/{kv.get('repo','')}/pull/{kv.get('number','')}"
    entry = data["prs"].get(url)
    if not entry:
        sys.exit(1)
    v = entry["view"]
    cmp_tip = (data.get("compares", {}).get(v.get("headRefOid", "")) or {}).get("base_commit", {}).get("sha") or v.get("baseRefOid", "")
    print(json.dumps({"data": {"repository": {"pullRequest": {
        "state": v["state"],
        "isDraft": v["isDraft"],
        "baseRefName": v["baseRefName"],
        "headRefOid": v["headRefOid"],
        "baseRef": {"target": {"oid": cmp_tip}},
    }}}}))
    sys.exit(0)
if len(args) >= 4 and args[0] == "api" and args[1] == "-X" and args[2] == "PUT" and args[3].endswith("/update-branch"):
    log_path = data.get("update_log")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(" ".join(args) + "\n")
    advance = data.get("update_advance_head")
    if advance:
        for entry in data.get("prs", {}).values():
            entry["view"]["headRefOid"] = advance
        with open("$data", "w", encoding="utf-8") as fh:
            json.dump(data, fh)
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
  printf 'status: completed\nbranch: %s\n' "\$(git rev-parse --abbrev-ref HEAD)"
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
  "update_advance_head": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/direct-a", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  PATH="$shim:$PATH" FM_LANDING_LOOP_UPDATE_POLL_SECS=3 FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "direct-PR step must exit 0"
  PATH="$shim:$PATH" FM_LANDING_LOOP_UPDATE_POLL_SECS=3 wait_for_inflight_done "$home" || fail "direct-PR update must finish"
  grep -Fq "api -X PUT repos/example/repo/pulls/104/update-branch -f expected_head_sha=$head" "$dir/update.log" \
    || fail "direct-PR must call GitHub server-side update-branch bound to expected_head_sha=$head"
  assert_equals "$local_head" "$(git -C "$wt" rev-parse HEAD)" "direct-PR server-side update must never mutate local worktree HEAD"
  assert_equals "local ignored value" "$(cat "$wt/ignored-secret")" "direct-PR update must never overwrite ignored local files"
  assert_equals "$head" "$(git --git-dir="$dir/repo/origin.git" rev-parse refs/heads/fm/direct-a)" "unpushed local commit must never be pushed to origin"
  # Also verify that if update-branch returns 202 but the forge head never advances, the worker fails into backoff and wakes Main once.
  local dir2="$TMP_ROOT/direct-stall" home2="$TMP_ROOT/direct-stall/home" shim2="$TMP_ROOT/direct-stall/shim"
  mkdir -p "$home2/state" "$home2/config" "$home2/data"
  local url2="https://github.com/example/repo/pull/109"
  fm_write_meta "$home2/state/direct-stall.meta" "kind=ship" "mode=direct-PR" "branch=fm/direct-a" "worktree=$wt" "pr=$url2"
  cat > "$dir2/gh.json" <<JSON
{
  "update_log": "$dir2/update.log",
  "prs": {
    "$url2": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/direct-a", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$tip"}, "behind_by": 1}
  }
}
JSON
  write_fake_gh "$shim2" "$dir2/gh.json"
  PATH="$shim2:$PATH" FM_LANDING_LOOP_UPDATE_POLL_SECS=1 FM_HOME="$home2" python3 "$LOOP" step --no-reconcile || fail "stalled direct-PR step must exit 0"
  PATH="$shim2:$PATH" FM_LANDING_LOOP_UPDATE_POLL_SECS=1 wait_for_inflight_done "$home2" || fail "stalled direct-PR update must finish"
  PATH="$shim2:$PATH" FM_LANDING_LOOP_UPDATE_POLL_SECS=1 FM_HOME="$home2" python3 "$LOOP" step --no-reconcile || fail "post-stall step must exit 0"
  "$JQ_BIN" -e '.tasks["direct-stall"].action == "backoff"' "$home2/state/.landing-loop/state.json" >/dev/null \
    || fail "direct-PR update whose head never advances must enter backoff"
  local stall_wakes
  stall_wakes=$(grep -c "landing-loop direct-stall:" "$home2/state/.wake-queue" 2>/dev/null || echo 0)
  assert_equals "1" "$stall_wakes" "stalled direct-PR update must wake Main once"
  pass "direct-PR proves merge-tree, updates server-side via expected_head_sha, waits for head advance, and fails into backoff + wake if stalled"
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
  local fake_lc="$dir/launchctl" loaded_flag="$dir/loaded" pending="$dir/unload-pending" stuck="$dir/bootout-stuck"
  # Like launchd, bootout returns before the service is gone (two more print calls), and
  # bootstrap refuses while the old instance is still loaded.
  cat > "$fake_lc" <<SH
#!/usr/bin/env bash
case "\$1" in
  print)
    [ -f "$loaded_flag" ] || exit 1
    if [ -f "$pending" ]; then
      n=\$(cat "$pending")
      if [ "\$n" -le 0 ]; then rm -f "$loaded_flag" "$pending"; exit 1; fi
      printf '%s\n' \$((n - 1)) > "$pending"
    fi
    exit 0 ;;
  bootstrap) [ ! -f "$loaded_flag" ] || exit 5; touch "$loaded_flag" ;;
  bootout) [ -f "$stuck" ] || printf '2\n' > "$pending" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fake_lc"
  seam_install() {
    FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_LANDING_LOOP_AGENT_DIR="$agents" FM_LANDING_LOOP_LAUNCHCTL="$fake_lc" "$INSTALL" "$@"
  }
  plist_meaning() {  # <plist file or -> <interval>
    python3 -c '
import plistlib, sys
src, interval, root, home = sys.argv[1:]
data = plistlib.loads(sys.stdin.buffer.read() if src == "-" else open(src, "rb").read())
ok = (
    data.get("StartInterval") == int(interval)
    and data.get("ProgramArguments", [])[-2:] == [root + "/bin/fm-landing-loop.py", "step"]
    and data.get("EnvironmentVariables", {}).get("FM_HOME") == home
)
sys.exit(0 if ok else 1)
' "$1" "$2" "$ROOT" "$home"
  }
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$INSTALL" install --interval 90 --print | plist_meaning - 90 \
    || fail "--print must render a plist running <root>/bin/fm-landing-loop.py step every 90s for this home"
  seam_install install --interval 60 >/dev/null || fail "install failed"
  local plist
  plist=$(printf '%s\n' "$agents"/*.plist)
  plist_meaning "$plist" 60 || fail "installed plist must run step every 60s for this home"
  seam_install install --interval 75 >/dev/null || fail "reinstall must wait for the asynchronous bootout before bootstrap"
  plist_meaning "$plist" 75 || fail "reinstall must replace the agent plist"
  local st
  st=$(seam_install status)
  case "$st" in *"plist=present launchd=loaded") ;; *) fail "expected installed status, got: $st" ;; esac
  touch "$stuck"
  if seam_install install --interval 45 >/dev/null 2>&1; then
    fail "reinstall must refuse when the old agent stays loaded after bootout"
  fi
  plist_meaning "$plist" 75 || fail "a refused reinstall must leave the existing plist in place"
  local leftover
  for leftover in "$agents"/*.tmp.*; do
    [ ! -e "$leftover" ] || fail "a refused reinstall must remove its rendered temporary plist: $leftover"
  done
  rm -f "$stuck"
  seam_install uninstall >/dev/null || fail "uninstall must wait for the asynchronous bootout"
  st=$(seam_install status)
  case "$st" in *"plist=absent launchd=not-loaded") ;; *) fail "expected uninstalled status, got: $st" ;; esac
  # FM_TEST_SEAM=1 without explicit overrides must fail closed and never touch ~/Library/LaunchAgents.
  if FM_TEST_SEAM=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_LANDING_LOOP_AGENT_DIR="" FM_LANDING_LOOP_LAUNCHCTL="" \
    "$INSTALL" status >/dev/null 2>&1; then
    fail "FM_TEST_SEAM=1 without agent-dir and launchctl overrides must refuse"
  fi
  pass "launchd installer renders the agent, waits out asynchronous bootout on reinstall and uninstall, refuses a stuck reinstall without touching the plist, and enforces test-seam overrides"
}

test_conflict_then_failed_update_wakes_for_each_kind() {
  local dir="$TMP_ROOT/conflict-then-fail" home="$TMP_ROOT/conflict-then-fail/home" shim="$TMP_ROOT/conflict-then-fail/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head tip
  info=$(make_git_pair "$dir/repo" "fm/task-k" "shared.txt" "unused.txt" 1)
  read -r wt head tip <<< "$info"
  local url="https://github.com/example/repo/pull/110"
  fm_write_meta "$home/state/task-k.meta" "kind=ship" "mode=no-mistakes" "branch=fm/task-k" "worktree=$wt" "pr=$url"
  write_gh_data() {  # <tip>
    cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head", "headRefName": "fm/task-k", "baseRefName": "main", "baseRefOid": "$1", "statusCheckRollup": [{"__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-27T00:00:00Z"}]}}
  },
  "compares": {
    "$head": {"base_commit": {"sha": "$1"}, "behind_by": 1}
  }
}
JSON
  }
  write_gh_data "$tip"
  write_fake_gh "$shim" "$dir/gh.json"
  write_fake_nm "$shim" "$dir/nm.log" 1
  PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" step --no-reconcile || fail "conflict step must exit 0"
  "$JQ_BIN" -e '.tasks["task-k"].action == "conflict"' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "conflicting head must classify as conflict first"
  # The base drops the conflicting change, so the same head now merges cleanly and its update fails.
  git -C "$wt" checkout -q main
  git -C "$wt" revert --no-edit HEAD >/dev/null
  git -C "$wt" push -q origin main
  local new_tip
  new_tip=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q fm/task-k
  write_gh_data "$new_tip"
  PATH="$shim:$PATH" FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" FM_HOME="$home" python3 "$LOOP" step --no-reconcile \
    || fail "update step must exit 0"
  PATH="$shim:$PATH" FM_LANDING_LOOP_DURATION_BIN="$shim/fake-duration.py" wait_for_inflight_done "$home" \
    || fail "failing update worker must finish"
  grep -q "$wt rerun" "$dir/nm.log" || fail "clean head must launch the failing rerun"
  grep -q "landing-loop task-k: .*has merge conflicts" "$home/state/.wake-queue" \
    || fail "conflict must wake Main"
  grep -q "landing-loop task-k: base update for .* failed" "$home/state/.wake-queue" \
    || fail "a failed update on a head that already raised a conflict wake must still wake Main"
  pass "conflict and failed-update wakes for the same head are deduplicated per kind, so neither hides the other"
}

test_dirty_no_mistakes_worktree_held_without_wake() {
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
  if grep -q "landing-loop dirty-a:" "$home/state/.wake-queue" 2>/dev/null; then
    fail "a held dirty checkout is neither a conflict nor a failed update and must not wake Main"
  fi
  pass "dirty no-mistakes worktree is held without launching rerun or waking Main"
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
    "https://github.com/example/repo/pull/204": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h204", "headRefName": "fm/pr204", "baseRefName": "release", "baseRefOid": "$tip", "statusCheckRollup": []}},
    "https://github.com/example/repo/pull/205": {"view": {"state": "OPEN", "isDraft": true, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h202", "headRefName": "fm/pr205", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}},
    "https://github.com/example/repo/pull/207": {"view": {"state": "CLOSED", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$h202", "headRefName": "fm/pr207", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}}
  },
  "compares": {
    "$h201": {"base_commit": {"sha": "$tip"}, "behind_by": 0}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  local out
  out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" train --repo example/repo --prs 201,202,203,204,205,206,207 --worktree "$wt" --branch fm/train-batch-1 --build --json) \
    || fail "train --build failed"
  "$JQ_BIN" -e '(.selected | map(.number)) == [201, 202] and (.excluded | length) == 5' <<<"$out" >/dev/null \
    || fail "train must select 201+202 and exclude conflicting 203, wrong-base 204, draft 205, unreadable 206, closed 207: $out"
  "$JQ_BIN" -e 'any(.excluded[]; .pr == "https://github.com/example/repo/pull/205" and .reason == "PR is a draft")
    and any(.excluded[]; .pr == "https://github.com/example/repo/pull/206" and .reason == "could not read PR from forge")
    and any(.excluded[]; .pr == "https://github.com/example/repo/pull/207" and .reason == "PR state is CLOSED")' <<<"$out" >/dev/null \
    || fail "train must report every requested PR it drops, with the reason: $out"
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
  pass "train command proves cumulative conflict-free batch, reports every excluded requested PR, protects existing branches, builds under merge.ff=only, and emits canonical Train-member closes block"
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
  # outcome: passed without status:, alongside this branch's status: running, or a run whose
  # branch is unreadable, must stay busy.
  for payload in $'outcome: passed\n' $'status: running\nbranch: fm/status-fail\noutcome: passed\n' $'status: running\n'; do
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
      || fail "status answer without this branch's terminal status must fail closed as busy: $payload"
  done
  [ ! -e "$dir/nm.log" ] || fail "must not launch rerun when status is missing or running"
  # A sibling crew's running pipeline answered for the shared repository is not this task's run.
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf 'status: running\nbranch: fm/sibling-crew\n'
  exit 0
fi
exit 0
SH
  chmod +x "$shim/no-mistakes"
  local sibling_out
  sibling_out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" plan --json)
  "$JQ_BIN" -e '.tasks[0].action == "update"' <<<"$sibling_out" >/dev/null \
    || fail "another branch's running pipeline must not hold this task busy, got: $sibling_out"
  # Terminal status ci_monitor_interrupted must be recognized as idle (eligible for update).
  cat > "$shim/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1" = axi ] && [ "\$2" = status ]; then
  printf 'run:\n  status: ci_monitor_interrupted\n  branch: fm/status-fail\n'
  exit 0
fi
exit 0
SH
  chmod +x "$shim/no-mistakes"
  local plan_out
  plan_out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" plan --json)
  "$JQ_BIN" -e '.tasks[0].action == "update"' <<<"$plan_out" >/dev/null \
    || fail "ci_monitor_interrupted must be treated as terminal/eligible, got: $plan_out"
  pass "no-mistakes axi status fails closed on exit error, statusless or branchless answers, and this branch's live run; ignores a sibling branch's run; treats ci_monitor_interrupted as terminal"
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
  printf 'status: completed\nbranch: %s\n' "\$(git rev-parse --abbrev-ref HEAD)"
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

test_train_without_prs_stays_in_one_repository() {
  local dir="$TMP_ROOT/train-repos" home="$TMP_ROOT/train-repos/home" shim="$TMP_ROOT/train-repos/shim"
  mkdir -p "$home/state" "$home/config" "$home/data"
  local info wt head1 tip
  info=$(make_git_pair "$dir/repo" "fm/one" "one.txt" "main-one.txt" 0)
  read -r wt head1 tip <<< "$info"
  git -C "$wt" checkout -q -b fm/two main
  printf 'two\n' > "$wt/two.txt"
  git -C "$wt" add two.txt
  git -C "$wt" commit -q -m 'fork pr'
  local head2
  head2=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q fm/one
  local url1="https://github.com/example/repo/pull/301" url2="https://github.com/forked/repo/pull/302"
  fm_write_meta "$home/state/one.meta" "kind=ship" "mode=direct-PR" "branch=fm/one" "worktree=$wt" "pr=$url1"
  fm_write_meta "$home/state/two.meta" "kind=ship" "mode=direct-PR" "branch=fm/two" "worktree=$wt" "pr=$url2"
  cat > "$dir/gh.json" <<JSON
{
  "prs": {
    "$url1": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head1", "headRefName": "fm/one", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}},
    "$url2": {"view": {"state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE", "mergeStateStatus": "CLEAN", "headRefOid": "$head2", "headRefName": "fm/two", "baseRefName": "main", "baseRefOid": "$tip", "statusCheckRollup": []}}
  },
  "compares": {
    "$head1": {"base_commit": {"sha": "$tip"}, "behind_by": 0},
    "$head2": {"base_commit": {"sha": "$tip"}, "behind_by": 0}
  }
}
JSON
  write_fake_gh "$shim" "$dir/gh.json"
  local out
  out=$(PATH="$shim:$PATH" FM_HOME="$home" python3 "$LOOP" train --worktree "$wt" --json) || fail "train plan failed"
  "$JQ_BIN" -e \
    "(.selected | map(.pr)) == [\"$url1\"] and any(.excluded[]; .pr == \"$url2\" and (.reason | contains(\"not train repository example/repo\")))" \
    <<<"$out" >/dev/null || fail "a train must hold members of one repository only: $out"
  pass "train without --prs keeps members in the first candidate's repository and reports the others as excluded"
}

test_step_runs_reconcile_under_stall_rule() {
  local dir="$TMP_ROOT/reconcile" home="$TMP_ROOT/reconcile/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$dir"
  cat > "$dir/reconcile.sh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$FM_HOME" "\$FM_PR_READY_RECONCILE_TIMEOUT" > "$dir/ran"
SH
  chmod +x "$dir/reconcile.sh"
  FM_LANDING_LOOP_RECONCILE_BIN="$dir/reconcile.sh" FM_HOME="$home" python3 "$LOOP" step || fail "step must exit 0"
  assert_equals "$home 120" "$(cat "$dir/ran" 2>/dev/null)" "step must run the reconcile helper for this home with the watcher's stall interval"
  "$JQ_BIN" -e '.last_reconcile.rc == 0' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "step must record the reconcile exit status"
  # A silent pass is stopped by the stall rule and its whole process tree dies.
  cat > "$dir/reconcile.sh" <<SH
#!/usr/bin/env bash
sleep 60 &
printf '%s\n' "\$!" > "$dir/child.pid"
wait
SH
  FM_PR_READY_RECONCILE_TIMEOUT=1 FM_LANDING_LOOP_RECONCILE_BIN="$dir/reconcile.sh" FM_HOME="$home" python3 "$LOOP" step \
    || fail "step with a silent reconcile must exit 0"
  "$JQ_BIN" -e '.last_reconcile.rc == 124' "$home/state/.landing-loop/state.json" >/dev/null \
    || fail "a silent reconcile must be recorded as stopped for inactivity: $(cat "$home/state/.landing-loop/state.json")"
  local cpid
  cpid=$(cat "$dir/child.pid" 2>/dev/null || true)
  [ -n "$cpid" ] || fail "silent reconcile must have started its child"
  if kill -0 "$cpid" 2>/dev/null; then
    kill -9 "$cpid" 2>/dev/null || true
    fail "reconcile child $cpid survived the stall stop"
  fi
  if env -u FM_TEST_SEAM FM_HOME="$home" python3 "$LOOP" step --no-reconcile >/dev/null 2>&1; then
    fail "step --no-reconcile must be refused without FM_TEST_SEAM=1"
  fi
  pass "step runs the reconcile helper under the stall rule, records its status, stops a silent pass with its tree, and refuses --no-reconcile outside the test seam"
}

fm_test_run_cases \
  test_serial_admission_updates_one_clean_stale_pr_at_a_time \
  test_conflict_holds_and_emits_single_wake \
  test_conflict_then_failed_update_wakes_for_each_kind \
  test_direct_pr_updates_server_side_without_mutating_worktree \
  test_dirty_no_mistakes_worktree_held_without_wake \
  test_unreadable_nm_status_fails_closed \
  test_detached_update_timeout_terminates_nested_child \
  test_failed_update_backs_off_and_wakes_main_once \
  test_train_plans_and_builds_conflict_free_batch_excluding_conflicts \
  test_train_without_prs_stays_in_one_repository \
  test_step_runs_reconcile_under_stall_rule \
  test_launchd_installer_renders_installs_and_uninstalls -- "$@"
