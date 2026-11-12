#!/usr/bin/env bash
# Real allocator suites opt in after creating their disposable fixture root.
# Configure each project too: terminal servers need not inherit this shell's
# environment. Stop the suite's terminal session before removing its sandbox.
# This helper owns no trap; callers compose it with their existing EXIT cleanup.
# The exit check compares exact names and modification times under the real
# ~/.treehouse. The Herdr e2e suites run with the real HOME, so they need a
# quiet fleet: any concurrent Treehouse activity there fails the check.
# Unverified limitation: the live cmux suite's worker pane inherits the cmux
# app's environment, not TREEHOUSE_NO_UPDATE_CHECK, so its in-pane
# `treehouse get` can still write ~/.treehouse/update-check.json.

fm_test_treehouse_snapshot() {  # <root>
  python3 - "$1" <<'PY'
import json
import os
import sys

root = sys.argv[1]
rows = []


def record(rel, path):
    try:
        rows.append((rel, os.lstat(path).st_mtime_ns))
    except FileNotFoundError:
        pass


def children(path):
    try:
        with os.scandir(path) as entries:
            return [(e.name, e.path, e.is_dir()) for e in entries]
    except (FileNotFoundError, NotADirectoryError):
        return []


if os.path.exists(root):
    record('.', root)
    for name, path, is_dir in children(root):
        record(name, path)
        if is_dir:
            for child, child_path, _ in children(path):
                record(f'{name}/{child}', child_path)
print(json.dumps(sorted(rows), separators=(',', ':')))
PY
}

fm_test_treehouse_init() {  # <existing-fixture-root>
  local root
  FM_TEST_TREEHOUSE_USER_ROOT="$HOME/.treehouse"
  FM_TEST_TREEHOUSE_BEFORE=$(fm_test_treehouse_snapshot "$FM_TEST_TREEHOUSE_USER_ROOT") || return 1
  root=$(mktemp -d "$1/treehouse.XXXXXX") || return 1
  FM_TEST_TREEHOUSE_ROOT=$(cd "$root" && pwd -P) || return 1
  # An inherited template can place worktrees outside even an explicit root.
  unset TREEHOUSE_WORKTREE_PATH
  TREEHOUSE_ROOT=$FM_TEST_TREEHOUSE_ROOT
  # Treehouse's updater otherwise writes ~/.treehouse/update-check.json even
  # when the pool root is explicitly confined. Lab servers inherit this flag.
  export TREEHOUSE_NO_UPDATE_CHECK=1
  export TREEHOUSE_ROOT
}

fm_test_treehouse_project() {  # <scratch-project>
  local root=$FM_TEST_TREEHOUSE_ROOT
  root=${root//\\/\\\\}
  root=${root//\"/\\\"}
  printf 'root = "%s"\nworktree_path = "{pool}/{slot}/{repo}"\n' "$root" > "$1/treehouse.toml"
}

fm_test_treehouse_assert_clean() {
  local after
  after=$(fm_test_treehouse_snapshot "$FM_TEST_TREEHOUSE_USER_ROOT") || return 1
  if [ "$after" != "$FM_TEST_TREEHOUSE_BEFORE" ]; then
    printf 'not ok - real Treehouse root changed: %s\n' "$FM_TEST_TREEHOUSE_USER_ROOT" >&2
    return 1
  fi
  if [ -d "$FM_TEST_TREEHOUSE_ROOT/.treehouse" ] &&
    [ -n "$(find "$FM_TEST_TREEHOUSE_ROOT/.treehouse" -name treehouse-state.json -print)" ]; then
    printf 'not ok - test Treehouse pools or leases remain: %s\n' "$FM_TEST_TREEHOUSE_ROOT" >&2
    return 1
  fi
}

fm_test_treehouse_cleanup() {
  # The directory was freshly allocated by init, not inherited from a caller.
  # Remove the entire private pool, including slots missing from task metadata
  # after an early spawn failure. Never run return/prune against a user's pool.
  [ -n "${FM_TEST_TREEHOUSE_ROOT:-}" ] || return 0
  if [ -d "$FM_TEST_TREEHOUSE_ROOT" ]; then
    find "$FM_TEST_TREEHOUSE_ROOT" -type d -exec chmod u+rwx {} + || return 1
    rm -rf -- "$FM_TEST_TREEHOUSE_ROOT" || return 1
  fi
  fm_test_treehouse_assert_clean
}
