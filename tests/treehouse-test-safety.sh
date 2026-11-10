#!/usr/bin/env bash
# Real allocator suites opt in after creating their disposable fixture root.
# Configure each project too: terminal servers need not inherit this shell's
# environment. Stop the suite's terminal session before removing its sandbox.
# This helper owns no trap; callers compose it with their existing EXIT cleanup.

fm_test_treehouse_snapshot() {  # <root>
  python3 - "$1" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [root, *root.glob('*'), *root.glob('*/*')] if root.exists() else []
print(json.dumps(sorted((str(p.relative_to(root)), p.lstat().st_mtime_ns)
                        for p in paths), separators=(',', ':')))
PY
}

fm_test_treehouse_init() {  # <existing-fixture-root>
  FM_TEST_TREEHOUSE_ROOT=$(mktemp -d "$1/treehouse.XXXXXX") || return 1
  FM_TEST_TREEHOUSE_ROOT=$(cd "$FM_TEST_TREEHOUSE_ROOT" && pwd -P) || return 1
  FM_TEST_TREEHOUSE_USER_ROOT="$HOME/.treehouse"
  FM_TEST_TREEHOUSE_BEFORE=$(fm_test_treehouse_snapshot "$FM_TEST_TREEHOUSE_USER_ROOT") || return 1
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
