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
# project's Treehouse lock, before any copy is acquired, for every fresh spawn whatever starting branch the task names.
# The main home is not a clone under projects/, so bin/fm-fleet-sync.sh never fetches it; admission is the one step every
# spawn passes through. The origin default is the tip the spawn fetched before it took the lock, never the task's branch.
# The treehouse config decides whether the step applies (fm_pool_base_config_names): treehouse.toml in the main
# checkout, else the user config, read as bin/fm-teardown.sh teardown_return_base_branch reads it. A config that does not
# name fm-pool-base, or no config file at all, makes the step do nothing and print nothing. Where it applies:
#   - an fm-pool-base that is an ancestor of the origin default is moved to it, by `git update-ref` with the old value
#     as the compare-and-set check;
#   - an fm-pool-base already at the origin default is left alone.
# Every other case is refused, names its reason, the fm-pool-base commit (or absent) and the origin default commit (or
# unavailable), returns 1 and leaves every ref unchanged:
#   absent             fm-pool-base does not exist; the repository's owner creates it, this library never does;
#   config_unreadable  the treehouse config cannot be read or parsed, so it is unknown whether the pool uses fm-pool-base;
#   origin_missing     <repo> has no origin remote;
#   origin_unreadable  the origin default could not be fetched or is not a commit;
#   ahead              fm-pool-base holds commits the origin default lacks;
#   diverged           fm-pool-base and the origin default each hold commits the other lacks;
#   checked_out        fm-pool-base is checked out in a worktree, or a worktree checked it out while it moved;
#   ref_unreadable     fm-pool-base or the worktree list cannot be read, or its ancestry cannot be compared;
#   changed            fm-pool-base moved between the read and the compare-and-set.
# A checkout is not blocked by the compare-and-set, so after the update the step looks at every worktree that holds
# fm-pool-base: one whose index is not at the new commit took the old one while it moved, and the branch is put back to the
# old value by a compare-and-set that expects the new one, so no worktree is left with files out of step with its HEAD.
# Nothing is forced and no existing copy is touched.

FM_POOL_BASE_REPO=
FM_POOL_BASE_TIP=

# fm_pool_base_config_names <repo>: 0 when the effective treehouse base_branch is fm-pool-base, 1 when it is not (no
# config file included), 2 when it cannot be established (the repository or the file cannot be read or parsed).
fm_pool_base_config_names() {
  local repo=$1 common main conf value
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 2
  main=$repo
  [ "$(basename "$common")" != .git ] || main=$(dirname "$common")
  conf="$main/treehouse.toml"
  [ -e "$conf" ] || conf="${HOME:-}/.config/treehouse/config.toml"
  [ -e "$conf" ] || return 1
  value=$(python3 -I -c 'import sys, tomllib
v = tomllib.load(open(sys.argv[1], "rb")).get("base_branch", "")
if not isinstance(v, str):
    sys.exit(2)
print(v)' "$conf" 2>/dev/null) || return 2
  [ "$value" = fm-pool-base ]
}

# The worktrees that hold fm-pool-base, one path per line; 1 when the list cannot be read.
fm_pool_base_holders() { # <repo>
  local inventory
  inventory=$(git -C "$1" worktree list --porcelain 2>/dev/null) || return 1
  printf '%s\n' "$inventory" | awk '/^worktree /{p=substr($0,10)} $0=="branch refs/heads/fm-pool-base"{print p}'
}

fm_pool_base_refuse() { # <reason> <detail>
  local old tip=${FM_POOL_BASE_TIP:-unavailable}
  if old=$(git -C "$FM_POOL_BASE_REPO" rev-parse --verify --quiet "refs/heads/fm-pool-base^{commit}" 2>/dev/null); then
    :
  elif git -C "$FM_POOL_BASE_REPO" show-ref --verify --quiet refs/heads/fm-pool-base 2>/dev/null; then
    old=unreadable
  else
    old=absent
  fi
  echo "error: fm-pool-base refused ($1): $2 [fm-pool-base: $old; origin default: $tip]; every ref is as it was" >&2
  return 1
}

fm_pool_base_advance() { # <repo> <origin-default-sha-or-empty> [<why-the-sha-is-empty>]
  local repo=$1 tip=${2:-} why=${3:-} ref=refs/heads/fm-pool-base old resolved rc holders holder bad
  FM_POOL_BASE_REPO=$repo
  FM_POOL_BASE_TIP=
  rc=0
  fm_pool_base_config_names "$repo" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) fm_pool_base_refuse config_unreadable "the treehouse config of $repo cannot be read or parsed, so it is unknown whether the pool uses fm-pool-base"
       return ;;
  esac
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
  FM_POOL_BASE_TIP=$tip
  if ! git -C "$repo" show-ref --verify --quiet "$ref"; then
    fm_pool_base_refuse absent "the treehouse config of $repo names fm-pool-base as the pool base, but the branch does not exist; the repository's owner creates it at the origin default $tip"
    return
  fi
  if ! old=$(git -C "$repo" rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null); then
    fm_pool_base_refuse ref_unreadable "fm-pool-base exists but does not name a commit"
    return
  fi
  [ "$old" != "$tip" ] || return 0
  if ! holders=$(fm_pool_base_holders "$repo"); then
    fm_pool_base_refuse ref_unreadable "the worktree list of $repo cannot be read, so it is unknown whether fm-pool-base is checked out"
    return
  fi
  if [ -n "$holders" ]; then
    fm_pool_base_refuse checked_out "fm-pool-base ($old) is checked out in a worktree, so it is not moved to origin default $tip"
    return
  fi
  rc=0
  git -C "$repo" merge-base --is-ancestor "$old" "$tip" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 1 ]; then
    rc=0
    git -C "$repo" merge-base --is-ancestor "$tip" "$old" >/dev/null 2>&1 || rc=$?
    case "$rc" in
      0) fm_pool_base_refuse ahead "fm-pool-base ($old) holds commits the origin default ($tip) lacks"; return ;;
      1) fm_pool_base_refuse diverged "fm-pool-base ($old) and the origin default ($tip) each hold commits the other lacks"; return ;;
    esac
  fi
  if [ "$rc" -ne 0 ]; then
    fm_pool_base_refuse ref_unreadable "the ancestry of fm-pool-base ($old) and the origin default ($tip) cannot be compared"
    return
  fi
  if ! git -C "$repo" update-ref --no-deref -m "fm-pool-base: fast-forward to the origin default" "$ref" "$tip" "$old" 2>/dev/null; then
    fm_pool_base_refuse changed "fm-pool-base moved from $old while it was being advanced to origin default $tip"
    return
  fi
  # A checkout does not honor the compare-and-set: a worktree may have taken fm-pool-base after the list above and
  # before the update, and would now show its new HEAD over files and an index of the old commit.
  bad=
  if holders=$(fm_pool_base_holders "$repo"); then
    while IFS= read -r holder; do
      [ -n "$holder" ] || continue
      git -C "$holder" diff-index --cached --quiet "$tip" >/dev/null 2>&1 || bad=$holder
    done <<EOF
$holders
EOF
  else
    bad="(worktree list unreadable)"
  fi
  if [ -n "$bad" ]; then
    if ! git -C "$repo" update-ref --no-deref -m "fm-pool-base: restored, a worktree took it during the update" "$ref" "$old" "$tip" 2>/dev/null; then
      fm_pool_base_refuse changed "fm-pool-base moved again while it was being restored to $old after a worktree ($bad) took it during the update"
      return
    fi
    fm_pool_base_refuse checked_out "a worktree ($bad) checked out fm-pool-base while it moved from $old to origin default $tip; it is back at $old"
    return
  fi
  echo "fm-pool-base: advanced $old to origin default $tip" >&2
  return 0
}
