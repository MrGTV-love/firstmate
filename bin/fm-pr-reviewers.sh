#!/usr/bin/env bash
# Suggest GitHub reviewers from recent authorship of a pull request's files.
#
# This is a read-only advisory command. It reads the pull request's exact file
# list, then the most recent 100 commits on its base commit for each path. A
# commit is counted once even when it touched multiple changed paths. Candidates
# use GitHub's own commit author.login mapping; names and email addresses are
# never converted or guessed. The pull-request author and Bot accounts are
# excluded. One API read is issued per changed path, so a wide pull request
# costs proportionally more reads and time. Every read is a conditional REST GET
# through fm-gh-rest.sh, so a repeated run over unchanged data is answered from
# the per-URL ETag cache under state/ without counting against the rate limit.
#
# Usage: fm-pr-reviewers.sh <pr-url>
#   Prints candidates in descending unique-commit count as:
#     <github-login><tab><count> recent commit[s]
#   When no mapped author other than the pull-request author appears, prints no
#   candidate and explains that result. Lookup or usage refusal exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-reviewers: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-reviewers.sh <pr-url>"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

rest() { "$SCRIPT_DIR/fm-gh-rest.sh" get "$@"; }

URL=$1
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"
PULL=$(rest "$ENDPOINT") || die "could not read $URL"
CORE=$(printf '%s\n' "$PULL" | jq -r '"author=\(.user.login)", "base=\(.base.sha)"') \
  || die "could not read $URL"
AUTHOR=
BASE=
while IFS= read -r row; do
  case "$row" in
    author=*) AUTHOR=${row#author=} ;;
    base=*) BASE=${row#base=} ;;
  esac
done <<EOF
$CORE
EOF
[ -n "$AUTHOR" ] && [ -n "$BASE" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

FILE_PAGES=$(rest "$ENDPOINT/files?per_page=100" --paginate --slurp) \
  || die "could not read changed files for $URL"
FILES=$(printf '%s\n' "$FILE_PAGES" | jq -r '.[][].filename') \
  || die "could not read changed files for $URL"
[ -n "$FILES" ] || {
  printf 'NO CANDIDATES: pull request changes no files\n'
  exit 0
}

EVIDENCE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-reviewers.XXXXXX") \
  || die "could not create temporary evidence file"
trap 'rm -f "$EVIDENCE"' EXIT INT TERM

while IFS= read -r file; do
  COMMITS=$(rest "/repos/$PATH_PART/commits" -f sha="$BASE" -f path="$file" -f per_page=100) \
    || die "could not read recent commits for $file"
  ROWS=$(printf '%s\n' "$COMMITS" | jq -r '.[] | select(.author.type != "Bot") | [.sha, (.author.login // "")] | @tsv') \
    || die "could not read recent commits for $file"
  [ -z "$ROWS" ] || printf '%s\n' "$ROWS" >> "$EVIDENCE"
done <<EOF
$FILES
EOF

CANDIDATES=$(awk -F '\t' -v author="$AUTHOR" '
  $2 != "" && $2 != author {
    key = $1 SUBSEP $2
    if (!seen[key]++) count[$2]++
  }
  END {
    for (login in count)
      printf "%s\t%d recent commit%s\n", login, count[login], (count[login] == 1 ? "" : "s")
  }
' "$EVIDENCE" | LC_ALL=C sort -t $'\t' -k2,2nr -k1,1)

if [ -z "$CANDIDATES" ]; then
  printf 'NO CANDIDATES: no mapped author other than the PR author\n'
else
  printf '%s\n' "$CANDIDATES"
fi
