#!/usr/bin/env bash
# Read-only repository drift auditor for a Firstmate home or Git checkout.
# Flags:
#   1. Primary checkout not detached at the base ref or having tracked changes.
#   2. Local branches ahead of the base ref by > --max-ahead commits or older
#      than --max-age-days days without an origin/<branch> ref.
#   3. Prunable worktrees or linked worktrees outside Treehouse pools.
# Usage: fm-drift-check.sh [--repo DIR] [--base REF] [--warn-only] [--max-ahead N] [--max-age-days N]
# Exit: 0 when clean (or with --warn-only); 1 when drift is found; 2 on usage or git error.
set -euo pipefail

usage() {
  sed -n '2,9{s/^# \{0,1\}//;p;}' "$0"
}

warn_only=0
max_ahead=10
max_age_days=7
base_ref="origin/main"
repo_arg=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --repo)
      [ $# -ge 2 ] || { echo "fm-drift-check: error: missing value for --repo" >&2; exit 2; }
      repo_arg=$2
      shift 2
      ;;
    --base)
      [ $# -ge 2 ] || { echo "fm-drift-check: error: missing value for --base" >&2; exit 2; }
      base_ref=$2
      shift 2
      ;;
    --warn-only)
      warn_only=1
      shift
      ;;
    --max-ahead)
      [ $# -ge 2 ] || { echo "fm-drift-check: error: missing value for --max-ahead" >&2; exit 2; }
      max_ahead=$2
      shift 2
      ;;
    --max-age-days)
      [ $# -ge 2 ] || { echo "fm-drift-check: error: missing value for --max-age-days" >&2; exit 2; }
      max_age_days=$2
      shift 2
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$max_ahead" in
  ''|*[!0-9]*)
    echo "fm-drift-check: error: --max-ahead must be a non-negative integer (got '$max_ahead')" >&2
    exit 2
    ;;
esac
case "$max_age_days" in
  ''|*[!0-9]*)
    echo "fm-drift-check: error: --max-age-days must be a non-negative integer (got '$max_age_days')" >&2
    exit 2
    ;;
esac

if [ -n "$repo_arg" ]; then
  if [ ! -d "$repo_arg" ]; then
    echo "fm-drift-check: error: repository directory does not exist: $repo_arg" >&2
    exit 2
  fi
  home=$(cd "$repo_arg" && pwd -P)
else
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  home=$(cd "$here/.." && pwd -P)
fi

git_run() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    git --no-optional-locks -C "$home" "$@"
}

worktrees=$(git_run worktree list --porcelain 2>/dev/null) || {
  echo "fm-drift-check: error: not a git repository: $home" >&2
  exit 2
}
first_block=${worktrees%%$'\n\n'*}
primary=${first_block%%$'\n'*}
primary=${primary#worktree }
primary_bare=0
case $'\n'"$first_block"$'\n' in
  *$'\n'bare$'\n'*) primary_bare=1 ;;
esac
home=$([ -n "$primary" ] && cd "$primary" 2>/dev/null && pwd -P) || {
  echo "fm-drift-check: error: cannot resolve primary worktree '$primary'" >&2
  exit 2
}

base_sha=$(git_run rev-parse --verify "${base_ref}^{commit}" 2>/dev/null) || {
  echo "fm-drift-check: error: cannot resolve base ref '$base_ref' in $home" >&2
  exit 2
}

drift=0

# 1. Primary checkout state
if [ "$primary_bare" -eq 1 ]; then
  echo "NOTE: primary worktree $home is a bare repository; skipping primary checkout checks."
else
  head_sha=$(git_run rev-parse --verify HEAD 2>/dev/null) || {
    echo "fm-drift-check: error: cannot resolve HEAD in $home" >&2
    exit 2
  }
  cur_branch=$(git_run symbolic-ref -q --short HEAD || true)
  if [ -n "$cur_branch" ]; then
    echo "DRIFT: primary checkout is on branch '$cur_branch' (expected detached $base_ref)"
    drift=1
  fi
  if [ "$head_sha" != "$base_sha" ]; then
    counts=$(git_run rev-list --left-right --count "${base_sha}...HEAD")
    echo "DRIFT: primary checkout HEAD (${head_sha:0:9}) != $base_ref (${base_sha:0:9}) [behind/ahead: $counts]"
    drift=1
  fi
  tracked_dirty=$(git_run diff --name-only HEAD)
  if [ -n "$tracked_dirty" ]; then
    echo "DRIFT: primary checkout has modified tracked files:"
    printf '%s\n' "$tracked_dirty" | sed 's/^/  /'
    drift=1
  fi
fi

# 2. Local branches ahead of base ref
now_epoch=$(date +%s)
cutoff=$((now_epoch - max_age_days * 86400))
stale_branches=()
while IFS=$'\t' read -r br ts; do
  [ -n "$br" ] || continue
  ahead=$(git_run rev-list --count "${base_sha}..refs/heads/$br" 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || continue
  has_origin=0
  if git_run show-ref --verify --quiet "refs/remotes/origin/$br"; then
    has_origin=1
  fi
  if [ "$ahead" -gt "$max_ahead" ] || { [ "$has_origin" -eq 0 ] && [ "$ts" -lt "$cutoff" ]; }; then
    age_d=$(((now_epoch - ts) / 86400))
    stale_branches+=("  ${br} (+${ahead} vs ${base_ref}, ${age_d}d old, on_origin=${has_origin})")
  fi
done < <(git_run for-each-ref --format='%(refname:short)	%(committerdate:unix)' refs/heads/)

if [ "${#stale_branches[@]}" -gt 0 ]; then
  echo "DRIFT: ${#stale_branches[@]} local branch(es) exceed >${max_ahead} commits ahead or >${max_age_days}d unpushed:"
  printf '%s\n' "${stale_branches[@]}"
  drift=1
fi

# 3. Worktrees: prunable or outside Treehouse pools
prunable_wts=()
non_pool_wts=()
wt_path=""
wt_prunable=0
wt_index=0

flush_wt() {
  [ -n "$wt_path" ] || return 0
  local wt_phys=$wt_path
  if [ -d "$wt_path" ]; then
    wt_phys=$(cd "$wt_path" && pwd -P)
  fi
  if [ "$wt_index" -gt 0 ]; then
    if [ "$wt_prunable" -eq 1 ]; then
      prunable_wts+=("  $wt_path")
    else
      case "$wt_phys" in
        */.treehouse/*) ;;
        *) non_pool_wts+=("  $wt_path") ;;
      esac
    fi
  fi
  wt_index=$((wt_index + 1))
  wt_path=""
  wt_prunable=0
}

while IFS= read -r line; do
  case "$line" in
    worktree\ *) wt_path=${line#worktree } ;;
    prunable*) wt_prunable=1 ;;
    "") flush_wt ;;
  esac
done < <(printf '%s\n\n' "$worktrees")
flush_wt

if [ "${#prunable_wts[@]}" -gt 0 ]; then
  echo "DRIFT: ${#prunable_wts[@]} prunable worktree(s) (run 'git worktree prune'):"
  printf '%s\n' "${prunable_wts[@]}"
  drift=1
fi
if [ "${#non_pool_wts[@]}" -gt 0 ]; then
  echo "DRIFT: ${#non_pool_wts[@]} non-Treehouse worktree(s):"
  printf '%s\n' "${non_pool_wts[@]}"
  drift=1
fi

if [ "$drift" -eq 0 ]; then
  echo "OK: primary checkout clean at $base_ref (${base_sha:0:9}), no stale branches or stray worktrees."
  exit 0
fi
[ "$warn_only" -eq 1 ] && exit 0
exit 1
