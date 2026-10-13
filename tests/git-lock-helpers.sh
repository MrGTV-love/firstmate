#!/usr/bin/env bash
# Real Git lock owners for fleet-sync and teardown behavior tests.
# Source after tests/lib.sh. One fixture at a time uses fd9 for its stdin FIFO;
# the background Git stays in the test shell's job table for failure cleanup.
# On 2026-10-12 with Git 2.54.0 on a loaded macOS host, complete real-Git
# lifecycle probes (including repo setup, readiness and lsof scans) took 17.97s
# and 16.15s. The existing fm_test_wait_until 20 ceiling permits 200 intervals:
# 20s of nominal polling gives 11% margin over even the slower WHOLE probe,
# not just its readiness wait, and stretches further with subprocess cost.

fm_test_git_lock_start() { # <repo> <fixture-dir> <packed|packed-open|index>
  local repo=$1 fixture=$2 kind=$3
  mkdir -p "$fixture"
  if [ "$kind" = packed ]; then
    git -C "$repo" branch fm-lock-held
    git -C "$repo" pack-refs --all
  fi
  FM_TEST_GIT_LOCK_KIND=$kind
  case "$kind" in
    packed|packed-open) FM_TEST_GIT_LOCK_PATH="$repo/.git/packed-refs.lock" ;;
    index)
      FM_TEST_GIT_LOCK_PATH=$(git -C "$repo" rev-parse --git-path index.lock)
      case "$FM_TEST_GIT_LOCK_PATH" in
        /*) ;;
        *) FM_TEST_GIT_LOCK_PATH="$repo/$FM_TEST_GIT_LOCK_PATH" ;;
      esac
      ;;
    *) fail "unknown Git lock fixture kind: $kind" ;;
  esac
  mkfifo "$fixture/input"
  exec 9<> "$fixture/input"
  (
    cd "$repo" || exit 1
    # Close the writer BEFORE exec's other redirections. Combining 9>&- with
    # exec git can leave Bash's saved fd11 writer inherited, preventing EOF.
    exec < "$fixture/input"
    exec 9>&-
    case "$kind" in
      packed) exec git update-ref --stdin > "$fixture/output" 2> "$fixture/error" ;;
      packed-open)
        exec 8<> "$FM_TEST_GIT_LOCK_PATH"
        exec git hash-object --stdin > "$fixture/output" 2> "$fixture/error"
        ;;
      index) exec git update-index --index-info > "$fixture/output" 2> "$fixture/error" ;;
    esac
  ) &
  FM_TEST_GIT_LOCK_PID=$!
  FM_TEST_GIT_LOCK_FIXTURE=$fixture
  if [ "$kind" = packed ]; then
    printf 'start\ndelete refs/heads/fm-lock-held\nprepare\n' >&9
    fm_test_wait_until 20 grep -q 'prepare: ok' "$fixture/output" \
      || fail "Git ref transaction did not prepare"
  else
    fm_test_wait_until 20 lsof -a -p "$FM_TEST_GIT_LOCK_PID" -- "$FM_TEST_GIT_LOCK_PATH" \
      || fail "Git did not open the fixture lock"
  fi
  touch -t 200001010000 "$FM_TEST_GIT_LOCK_PATH"
}

fm_test_git_lock_finish() {
  if [ "$FM_TEST_GIT_LOCK_KIND" = packed ]; then
    printf 'abort\n' >&9
    fm_test_wait_until 20 grep -q 'abort: ok' "$FM_TEST_GIT_LOCK_FIXTURE/output" \
      || fail "Git ref transaction did not abort"
  fi
  # Terminate our still-live direct child, not any repository-wide process.
  kill "$FM_TEST_GIT_LOCK_PID"
  wait "$FM_TEST_GIT_LOCK_PID" 2>/dev/null || true
  exec 9>&-
}
