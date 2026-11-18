#!/usr/bin/env bash
# Keep the `fm-pool-base` branch at the origin default for a repository whose treehouse pool is cut from it.
#
# Why it exists: treehouse cuts every new pool copy, and recycles every returned one, at its base branch, and it
# prefers a local branch that is strictly ahead of origin (treehouse internal/vcs/gitvcs/gitvcs.go branchRef). A home
# whose local default branch carries commits origin lacks therefore cuts every copy ahead of the origin default that
# bin/fm-spawn.sh targets, the spawn precheck skips each one (head_not_target), and the pool fills with unusable copies.
# Such a home sets `base_branch = "fm-pool-base"` in its treehouse.toml (docs/configuration.md "Pool base branch") and
# this library keeps that branch at the origin default.
#
# fm_pool_base_advance <repo> <origin-default-sha-or-empty> [<why-the-sha-is-empty>] is called by bin/fm-spawn.sh under the
# project's Treehouse lock, right after the spawn fetched the origin default and before any copy is acquired. The main
# home is not a clone under projects/, so bin/fm-fleet-sync.sh never fetches it; admission is the one step every spawn
# passes through.
# It does nothing, and prints nothing, unless the treehouse config of <repo> names fm-pool-base as base_branch. Then:
#   - an absent fm-pool-base is created at the origin default;
#   - an fm-pool-base that is an ancestor of the origin default is moved to it, by `git update-ref` with the old value
#     as the compare-and-set check;
#   - an fm-pool-base already at the origin default is left alone.
# Every other case is refused, names its reason and the commits involved, returns 1 and leaves every ref unchanged:
#   origin_missing     <repo> has no origin remote;
#   origin_unreadable  the origin default could not be fetched or is not a commit;
#   ahead              fm-pool-base holds commits the origin default lacks;
#   diverged           fm-pool-base and the origin default each hold commits the other lacks;
#   checked_out        fm-pool-base is checked out in a worktree, which an update would leave inconsistent;
#   ref_unreadable     fm-pool-base or the worktree list cannot be read, or its ancestry cannot be compared;
#   changed            fm-pool-base moved between the read and the compare-and-set.
# Nothing is forced and no existing copy is touched. A treehouse config that cannot be read prints a warning and moves
# nothing, because it is then unknown whether the pool uses fm-pool-base.
# The config is read as bin/fm-teardown.sh teardown_return_base_branch reads it: treehouse.toml in the main checkout,
# else the user config.

fm_pool_base_config_base_branch() { # <repo>: print the configured base_branch (empty when none); 1 when unreadable
  local repo=$1 common main conf
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  main=$repo
  [ "$(basename "$common")" != .git ] || main=$(dirname "$common")
  conf="$main/treehouse.toml"
  [ -e "$conf" ] || conf="${HOME:-}/.config/treehouse/config.toml"
  [ -e "$conf" ] || return 0
  python3 -I -c 'import sys, tomllib
v = tomllib.load(open(sys.argv[1], "rb")).get("base_branch", "")
if not isinstance(v, str):
    sys.exit(2)
print(v)' "$conf" 2>/dev/null
}

fm_pool_base_refuse() { # <reason> <detail>
  echo "error: fm-pool-base refused ($1): $2; fm-pool-base and every other ref are unchanged" >&2
  return 1
}

fm_pool_base_advance() { # <repo> <origin-default-sha-or-empty> [<why-the-sha-is-empty>]
  local repo=$1 tip=${2:-} why=${3:-} base ref=refs/heads/fm-pool-base old zero inventory resolved rc
  if ! base=$(fm_pool_base_config_base_branch "$repo"); then
    echo "warning: fm-pool-base was not checked: the treehouse base_branch setting for $repo cannot be read" >&2
    return 0
  fi
  [ "$base" = fm-pool-base ] || return 0
  if [ -z "$tip" ]; then
    if git -C "$repo" remote get-url origin >/dev/null 2>&1; then
      fm_pool_base_refuse origin_unreadable "the origin default of $repo could not be read${why:+ ($why)}"
    else
      fm_pool_base_refuse origin_missing "$repo has no origin remote, so there is no origin default to follow"
    fi
    return
  fi
  if ! resolved=$(git -C "$repo" rev-parse --verify --quiet "$tip^{commit}" 2>/dev/null); then
    fm_pool_base_refuse origin_unreadable "origin default '$tip' is not a commit in $repo"
    return
  fi
  tip=$resolved
  if ! git -C "$repo" show-ref --verify --quiet "$ref"; then
    zero=$(printf '%*s' "${#tip}" '' | tr ' ' 0)
    if ! git -C "$repo" update-ref --no-deref -m "fm-pool-base: created at the origin default" "$ref" "$tip" "$zero" 2>/dev/null; then
      fm_pool_base_refuse changed "fm-pool-base appeared while it was being created at origin default $tip"
      return
    fi
    echo "fm-pool-base: created at origin default $tip" >&2
    return 0
  fi
  if ! old=$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null); then
    fm_pool_base_refuse ref_unreadable "fm-pool-base exists but does not name a commit (origin default $tip)"
    return
  fi
  [ "$old" != "$tip" ] || return 0
  if ! inventory=$(git -C "$repo" worktree list --porcelain 2>/dev/null); then
    fm_pool_base_refuse ref_unreadable "the worktree list of $repo cannot be read, so it is unknown whether fm-pool-base is checked out"
    return
  fi
  if printf '%s\n' "$inventory" | grep -Fxq "branch $ref"; then
    fm_pool_base_refuse checked_out "fm-pool-base ($old) is checked out in a worktree, so it is not moved to origin default $tip"
    return
  fi
  rc=0
  git -C "$repo" merge-base --is-ancestor "$old" "$tip" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    if ! git -C "$repo" update-ref --no-deref -m "fm-pool-base: fast-forward to the origin default" "$ref" "$tip" "$old" 2>/dev/null; then
      fm_pool_base_refuse changed "fm-pool-base moved from $old while it was being advanced to origin default $tip"
      return
    fi
    echo "fm-pool-base: advanced $old to origin default $tip" >&2
    return 0
  fi
  if [ "$rc" -eq 1 ]; then
    rc=0
    git -C "$repo" merge-base --is-ancestor "$tip" "$old" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) fm_pool_base_refuse ahead "fm-pool-base ($old) holds commits the origin default ($tip) lacks"; return ;;
      1) fm_pool_base_refuse diverged "fm-pool-base ($old) and the origin default ($tip) each hold commits the other lacks"; return ;;
    esac
  fi
  fm_pool_base_refuse ref_unreadable "the ancestry of fm-pool-base ($old) and the origin default ($tip) cannot be compared"
}
