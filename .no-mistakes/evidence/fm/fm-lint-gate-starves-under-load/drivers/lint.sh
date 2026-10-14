#!/usr/bin/env bash
# Isolated wrapper: private slot pool, cache, XDG and duration store.
exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CI -u GITHUB_ACTIONS   FM_DURATION_FILE=off XDG_CACHE_HOME="/Users/charlesabrooker/tmp/fm-lint-lab.xiz6Z3/xdg" FM_LINT_CACHE_DIR="${LAB_CACHE:-off}" FM_LINT_SLOT_DIR="${LAB_SLOTS:-/Users/charlesabrooker/tmp/fm-lint-lab.xiz6Z3/slots}"   "${LINT_BIN:-/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4XFRRHNM6DGKRMTRZQB0YPJ/bin/fm-lint.sh}" "$@"
