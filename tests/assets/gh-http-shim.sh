#!/usr/bin/env bash
# Test double for `gh api -i`: wraps a body-only fixture `gh-backend` (a sibling of this file) in the HTTP
# response gh prints, including ETag, conditional 304 and X-RateLimit-* headers.
#
# Every call is logged to $GH_SHIM_LOG as `counted <argv>` (GitHub spends a rate-limit point) or
# `not-modified <argv>` (a 304, which GitHub does not count). Calls without `-i` pass to the backend
# unchanged and are logged as counted. GH_SHIM_REMAINING/LIMIT/RESET set the reported bucket and
# GH_SHIM_NO_ETAG=1 withholds the ETag.
set -u
here=$(cd "$(dirname "$0")" && pwd)
backend="$here/gh-backend"
note() { [ -z "${GH_SHIM_LOG:-}" ] || printf '%s %s\n' "$1" "${ARGV}" >> "$GH_SHIM_LOG"; }
ARGV="$*"
case " $* " in
  *" -i "*) ;;
  *) note counted; exec "$backend" "$@" ;;
esac
[ "${1:-}" = api ] || { note counted; exec "$backend" "$@"; }
shift
rest=()
conditional=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i) ;;
    -H)
      case "$2" in [Ii]f-[Nn]one-[Mm]atch:*) conditional=${2#*: } ;; esac
      shift
      ;;
    *) rest+=("$1") ;;
  esac
  shift
done
if ! body=$("$backend" api "${rest[@]}" 2> "${TMPDIR:-/tmp}/gh-shim-err.$$"); then
  code=$?
  note counted
  cat "${TMPDIR:-/tmp}/gh-shim-err.$$" >&2
  rm -f "${TMPDIR:-/tmp}/gh-shim-err.$$"
  exit "$code"
fi
rm -f "${TMPDIR:-/tmp}/gh-shim-err.$$"
etag=
[ -n "${GH_SHIM_NO_ETAG:-}" ] || etag="\"$(printf '%s' "$body" | shasum | cut -c1-16)\""
rate=$(printf 'X-Ratelimit-Limit: %s\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Reset: %s\r\nX-Ratelimit-Resource: core\r\n' \
  "${GH_SHIM_LIMIT:-5000}" "${GH_SHIM_REMAINING:-4000}" "${GH_SHIM_RESET:-$(( $(date +%s) + 3600 ))}")
if [ -n "$etag" ] && [ "$conditional" = "$etag" ]; then
  note not-modified
  printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n%s\r\n\r\n' "$etag" "$rate"
  printf 'gh: HTTP 304\n' >&2
  exit 1
fi
note counted
printf 'HTTP/2.0 200 OK\r\n'
[ -z "$etag" ] || printf 'Etag: %s\r\n' "$etag"
printf '%s\r\n\r\n%s\n' "$rate" "$body"
