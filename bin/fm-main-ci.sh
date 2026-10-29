#!/usr/bin/env bash
# Judge one commit on a branch by the newest completed CI run that contains it.
#
# CI coalesces pushes to a branch: one run executes and one waits, and a newer
# waiting run replaces an older one (.github/workflows/ci.yml "concurrency").
# A commit that was replaced therefore has no run of its own. It is covered by
# the newest completed run on a later commit, never red or missing for that
# reason, so read main CI through this script and not by the commit's own SHA.
#
# Usage: fm-main-ci.sh --repo <owner/repo> [--branch <name>] [--workflow <file>] <sha>
#   --branch defaults to main and --workflow to ci.yml.
#   Prints one line: state=<green|red|pending> run=<id|none> head=<sha|none>
#     green    the newest completed run containing <sha> succeeded.
#     red      that run failed, timed out, failed to start, or needs action.
#     pending  no completed run contains <sha> yet: its run, or a later one,
#              is queued or running, or every later run was cancelled.
#   run and head name the deciding run and the commit it ran, which may be later
#   than <sha>. A run cancelled or skipped is never a verdict; it is passed over.
#   A run contains <sha> when its head is <sha> or a descendant, read from the
#   compare API. Runs are read newest first and the scan stops at the first run
#   whose head is an ancestor of <sha>, because every older run is an ancestor too.
#   Exit 0 when a state was decided, 1 when GitHub could not be read, 2 on usage.
set -u

usage() {
  sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-main-ci: %s\n' "$1" >&2
  exit "${2:-2}"
}

REPO=
BRANCH=main
WORKFLOW=ci.yml
SHA=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) [ "$#" -ge 2 ] || die "--repo needs a value"; REPO=$2; shift 2 ;;
    --branch) [ "$#" -ge 2 ] || die "--branch needs a value"; BRANCH=$2; shift 2 ;;
    --workflow) [ "$#" -ge 2 ] || die "--workflow needs a value"; WORKFLOW=$2; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$SHA" ] || die "usage: fm-main-ci.sh --repo <owner/repo> [--branch <name>] [--workflow <file>] <sha>"; SHA=$1; shift ;;
  esac
done
case "$REPO" in */*) ;; *) die "usage: fm-main-ci.sh --repo <owner/repo> [--branch <name>] [--workflow <file>] <sha>" ;; esac
case "$SHA" in ''|*[!0-9a-fA-F]*) die "<sha> must be a full hexadecimal commit id" ;; esac
[ "${#SHA}" -eq 40 ] || die "<sha> must be a full 40-character commit id"
command -v gh >/dev/null 2>&1 || die "gh is required" 1
command -v jq >/dev/null 2>&1 || die "jq is required" 1

runs=$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?branch=$BRANCH&event=push&per_page=100" 2>/dev/null) \
  || die "could not read $WORKFLOW runs for $REPO $BRANCH" 1
rows=$(printf '%s' "$runs" | jq -r '
  if (.workflow_runs | type) == "array" then
    .workflow_runs[] | [(.id | tostring), .head_sha, .status, (.conclusion // "")] | @tsv
  else error("not a workflow run list") end') \
  || die "unreadable $WORKFLOW run list for $REPO $BRANCH" 1

# Does the run's head contain SHA: prints contains, behind, or other.
relation() { # head
  local head=$1 compare status
  [ "$head" != "$SHA" ] || { printf 'contains\n'; return 0; }
  compare=$(gh api "repos/$REPO/compare/$SHA...$head" 2>/dev/null) || return 1
  status=$(printf '%s' "$compare" | jq -er '.status') || return 1
  case "$status" in
    ahead|identical) printf 'contains\n' ;;
    behind) printf 'behind\n' ;;
    *) printf 'other\n' ;;
  esac
}

while IFS=$'\t' read -r id head status conclusion; do
  [ -n "$id" ] || continue
  rel=$(relation "$head") || die "could not compare $SHA with run $id head $head" 1
  case "$rel" in
    behind) break ;;
    contains) ;;
    *) continue ;;
  esac
  [ "$status" = completed ] || continue
  case "$conclusion" in
    success) printf 'state=green run=%s head=%s\n' "$id" "$head"; exit 0 ;;
    failure|timed_out|startup_failure|action_required) printf 'state=red run=%s head=%s\n' "$id" "$head"; exit 0 ;;
    *) ;;
  esac
done <<EOF
$rows
EOF
printf 'state=pending run=none head=none\n'
