#!/usr/bin/env bash
# tests/git-config-helpers.sh - fixture Git isolation from the host's global and
# system configuration and from an inherited repository location.
#
# Source this before a fixture's first Git operation:
#   # shellcheck source=tests/git-config-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/git-config-helpers.sh"
#
# Fixture Git processes must not inherit host signing, hooks, or other global and
# system preferences: with commit.gpgsign=true set globally and no secret key for
# the fixture identities, every fixture commit fails before its assertion.
# Isolation is limited to those two layers on purpose, so repository-local config,
# inline `git -c`, GIT_CONFIG_COUNT, and a GIT_CONFIG_GLOBAL the caller supplies
# after sourcing all stay authoritative - the Git-config suites assert on them.
# The one inherited GIT_CONFIG_COUNT entry dropped is core.hooksPath, below.
# The export reaches only the sourcing shell and its children, so the developer's
# own config files are never written and real project commits made outside the
# fixtures keep their configuration and signing.
#
# The repository-location variables are cleared too: an absolute GIT_DIR (as a
# linked-worktree hook exports) overrides the discovery `git -C <fixture>`
# implies, so fixture refs, commits, and worktree registrations would land in
# the caller's repository instead. A suite that wants one sets it after sourcing.
#
# tests/lib.sh and tests/herdr-test-safety.sh source this for every suite that
# uses them, bin/fm-test-run.sh sources it per suite in run_script_bounded, and a
# suite reaching none of those sources it directly so a hand-run invocation is
# isolated too. tests/fm-test-fixtures.test.sh is the regression - it drives the
# shared helpers, the runner, and the standalone entry points that run without a
# live vendor - and the changed-file map selects it for a change to this file.

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# A launcher can also inject a hooks directory through GIT_CONFIG_COUNT (a task
# worker does, to run its commit checks), and that layer outranks repository-local
# config, so every fixture commit would run the host's hooks against fixture
# content. Drop only the inherited core.hooksPath entries and renumber the rest,
# so a launcher's other entries and any the caller sets after sourcing still win.
__fm_git_env_i=0 __fm_git_env_n=0 __fm_git_env_keys=() __fm_git_env_values=()
while [ "$__fm_git_env_i" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  __fm_git_env_k=GIT_CONFIG_KEY_$__fm_git_env_i
  __fm_git_env_v=GIT_CONFIG_VALUE_$__fm_git_env_i
  case "$(printf '%s' "${!__fm_git_env_k-}" | tr '[:upper:]' '[:lower:]')" in
    core.hookspath) ;;
    *)
      __fm_git_env_keys[__fm_git_env_n]=${!__fm_git_env_k-}
      __fm_git_env_values[__fm_git_env_n]=${!__fm_git_env_v-}
      __fm_git_env_n=$((__fm_git_env_n + 1))
      ;;
  esac
  unset "$__fm_git_env_k" "$__fm_git_env_v"
  __fm_git_env_i=$((__fm_git_env_i + 1))
done
if [ "$__fm_git_env_n" -gt 0 ]; then
  export GIT_CONFIG_COUNT=$__fm_git_env_n
  __fm_git_env_i=0
  while [ "$__fm_git_env_i" -lt "$__fm_git_env_n" ]; do
    export "GIT_CONFIG_KEY_$__fm_git_env_i=${__fm_git_env_keys[$__fm_git_env_i]}"
    export "GIT_CONFIG_VALUE_$__fm_git_env_i=${__fm_git_env_values[$__fm_git_env_i]}"
    __fm_git_env_i=$((__fm_git_env_i + 1))
  done
else
  unset GIT_CONFIG_COUNT
fi
unset __fm_git_env_i __fm_git_env_n __fm_git_env_keys __fm_git_env_values __fm_git_env_k __fm_git_env_v
