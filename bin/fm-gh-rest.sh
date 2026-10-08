#!/usr/bin/env bash
# Conditional GitHub REST reads and the shared quota floor.
#
# Usage:
#   fm-gh-rest.sh get <endpoint> [--paginate] [--slurp] [--floor] [-f key=value]...
#   fm-gh-rest.sh guard [--resource core]
#   fm-gh-rest.sh status
#
# get makes one REST GET per page through `gh api -i` and prints the JSON body (one document per page;
# --slurp prints a single array of page bodies). It sends If-None-Match from a per-URL ETag cache under
# <state>/gh-rest-cache/ and serves the cached body on a 304, which GitHub does not count against the rate
# limit. A missing, corrupt, or unparsable cache entry is a normal GET; entries unused for a week are
# pruned. -f adds a URL-encoded query parameter. --paginate follows Link rel="next", each page cached on its
# own. A forge error exits 1 with the forge's message on stderr and caches nothing. REST only: GraphQL has no
# conditional request.
# Every response, including a 304 and an error, records its X-RateLimit-Limit/Remaining/Reset/Resource
# headers in <state>/gh-ratelimit.<resource>.json as {resource,limit,remaining,reset,observed}; within one
# window the lowest remaining wins, so parallel readers finishing out of order cannot raise it.
# guard exits 75 and prints the reason when the recorded bucket is below the floor and its window has not
# reset; otherwise it exits 0 silently. get --floor runs the same check before any network call, so a sweep
# that passes --floor stops at the first read. The floor is FM_GH_RATE_FLOOR_PERCENT percent of the limit
# (default 15; values outside 0..100 use 15). Neither reads the network.
# status prints the recorded buckets, one JSON object per line.
#
# <state> is FM_STATE_OVERRIDE, else $FM_HOME/state, else the code root's state/. docs/configuration.md
# owns the contract this header summarizes.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}/state}
CACHE="$STATE/gh-rest-cache"
EX_TEMPFAIL=75
MAX_PAGES=1000
work=

die() { printf 'fm-gh-rest: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || die 'jq is required'

ratelimit_file() { printf '%s/gh-ratelimit.%s.json\n' "$STATE" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"; }

# Print the reason and return 0 when the bucket is below the floor and its window is open.
quota_low() { # resource
  local file
  file=$(ratelimit_file "$1")
  [ -f "$file" ] || return 1
  jq -er --arg raw "${FM_GH_RATE_FLOOR_PERCENT:-}" '
    (try ($raw | tonumber) catch 15 | if . < 0 or . > 100 then 15 else . end) as $floor
    | (now | floor) as $now
    | select((.limit | type) == "number" and (.remaining | type) == "number" and (.reset | type) == "number"
      and .limit > 0 and .reset > $now and (.remaining * 100) < ($floor * .limit))
    | "GitHub \(.resource) quota low (\(.remaining) of \(.limit) left, below the \($floor)% floor); "
      + "network sweep skipped until the window resets at \(.reset | todate)"' "$file" 2>/dev/null
}

# One pass over a header file: prints name=value lines for the headers this script reads.
header_pairs() { # headers-file
  awk -F': *' 'BEGIN { split("x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset x-ratelimit-resource etag link", w, " ")
      for (i in w) want[w[i]] = 1 }
    NR == 1 { next }
    { name = tolower($1); if (name in want) { v = $0; sub(/^[^:]*: */, "", v); print name "=" v } }' "$1"
}

record_rate() { # headers-file
  local limit='' remaining='' reset='' resource=core file previous prev_reset prev_remaining name value
  while IFS='=' read -r name value; do
    case "$name" in
      x-ratelimit-limit) limit=$value ;;
      x-ratelimit-remaining) remaining=$value ;;
      x-ratelimit-reset) reset=$value ;;
      x-ratelimit-resource) resource=$(printf '%s' "$value" | tr -c 'A-Za-z0-9_-' '_') ;;
    esac
  done < <(header_pairs "$1")
  case "$limit$remaining$reset" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$limit" ] && [ -n "$remaining" ] && [ -n "$reset" ] || return 0
  file="$STATE/gh-ratelimit.$resource.json"
  mkdir -p "$STATE" 2>/dev/null || return 0
  if [ -f "$file" ]; then
    previous=$(jq -r 'select((.reset | type) == "number" and (.remaining | type) == "number") | "\(.reset) \(.remaining)"' "$file" 2>/dev/null || true)
    if [ -n "$previous" ]; then
      prev_reset=${previous% *}; prev_remaining=${previous#* }
      if [ "$prev_reset" = "$reset" ] && [ "$prev_remaining" -lt "$remaining" ]; then remaining=$prev_remaining; fi
    fi
  fi
  local staged
  staged=$(mktemp "$STATE/.gh-ratelimit.XXXXXX") || return 0
  printf '{"resource":"%s","limit":%s,"remaining":%s,"reset":%s,"observed":%s}\n' \
    "$resource" "$limit" "$remaining" "$reset" "$(date +%s)" > "$staged"
  mv -f -- "$staged" "$file" || rm -f -- "$staged"
}

cache_path() { # endpoint
  local key
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s\n%s' "${GH_HOST:-github.com}" "${1#/}" | shasum -a 256)
  else
    key=$(printf '%s\n%s' "${GH_HOST:-github.com}" "${1#/}" | sha256sum)
  fi
  key=${key%% *}
  printf '%s/%s.json\n' "$CACHE" "$key"
}

prune_cache() {
  [ -d "$CACHE" ] || return 0
  if [ -z "$(find "$CACHE" -maxdepth 1 -name .pruned -mmin -60 2>/dev/null)" ]; then
    find "$CACHE" -maxdepth 1 -name '*.json' -mtime +7 -delete 2>/dev/null || true
    : > "$CACHE/.pruned" 2>/dev/null || true
  fi
}

# fetch_page <endpoint> <body-out> : prints the next endpoint (or nothing) on stdout; returns 1 on a forge error.
fetch_page() {
  local endpoint=$1 body_out=$2 entry etag='' raw hdr err status next staged
  entry=$(cache_path "$endpoint")
  if [ -f "$entry" ] && jq -e '(.etag | type == "string" and length > 0) and (.body | type == "string") and (.body | fromjson | true)' \
    "$entry" >/dev/null 2>&1; then
    etag=$(jq -r .etag "$entry")
  fi
  raw="$work/raw.$RANDOM$RANDOM"
  hdr="$raw.hdr"; err="$raw.err"
  local -a conditional=()
  [ -z "$etag" ] || conditional=(-H "If-None-Match: $etag")
  env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh api -i ${conditional[@]+"${conditional[@]}"} "$endpoint" \
    < /dev/null > "$raw" 2> "$err"
  local rc=$?
  # Split the response at the first blank line: status and headers, then the body.
  tr -d '\r' < "$raw" | awk -v hdr="$hdr" -v body="$body_out" 'BEGIN { inhead = 1; printf "" > hdr; printf "" > body }
    inhead { if ($0 == "") { inhead = 0 } else { print > hdr } ; next }
    { print > body }'
  status=$(awk 'NR == 1 { print $2 }' "$hdr" 2>/dev/null)
  record_rate "$hdr"
  if [ "$status" = 304 ] && [ -n "$etag" ]; then
    jq -r .body "$entry" > "$body_out"
    next=$(jq -r '.next // empty' "$entry")
    touch "$entry" 2>/dev/null || true
    rm -f -- "$raw" "$hdr" "$err"
    printf '%s' "$next"
    return 0
  fi
  case "$status" in
    2??)
      if [ "$rc" -eq 0 ] && jq -e . "$body_out" >/dev/null 2>&1; then
        local name value link=''
        etag=''
        while IFS='=' read -r name value; do
          case "$name" in etag) etag=$value ;; link) link=$value ;; esac
        done < <(header_pairs "$hdr")
        next=$(printf '%s' "$link" | tr ',' '\n' | sed -n 's/^[[:space:]]*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="next".*/\1/p' | head -1 | sed -E 's#^https?://[^/]+/##')
        if [ -n "$etag" ] && mkdir -p "$CACHE" 2>/dev/null && staged=$(mktemp "$CACHE/.entry.XXXXXX" 2>/dev/null); then
          if jq -n --arg etag "$etag" --rawfile body "$body_out" --arg next "$next" \
            '{etag:$etag,body:$body,next:(if $next == "" then null else $next end)}' > "$staged" \
            && chmod 600 "$staged"; then
            mv -f -- "$staged" "$entry" || rm -f -- "$staged"
          else
            rm -f -- "$staged"
          fi
        fi
        rm -f -- "$raw" "$hdr" "$err"
        printf '%s' "$next"
        return 0
      fi
      ;;
  esac
  { head -c 300 "$err"; [ -s "$err" ] || head -c 300 "$body_out"; } | tr '\n' ' ' | sed 's/ *$//' > "$raw.msg"
  [ -s "$raw.msg" ] || printf 'gh api failed' > "$raw.msg"
  cat "$raw.msg" >&2; printf '\n' >&2
  rm -f -- "$raw" "$hdr" "$err" "$raw.msg"
  return 1
}

urlencode() { jq -rn --arg v "$1" '$v | @uri'; }

cmd_get() {
  local endpoint='' paginate=0 slurp=0 floor=0 query='' key value reason i=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --paginate) paginate=1 ;;
      --slurp) slurp=1 ;;
      --floor) floor=1 ;;
      -f|-F)
        shift
        [ "$#" -gt 0 ] || die 'missing value for -f'
        key=${1%%=*}; value=${1#*=}
        query="$query${query:+&}$(urlencode "$key")=$(urlencode "$value")"
        ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$endpoint" ] || die 'one endpoint only'; endpoint=$1 ;;
    esac
    shift
  done
  [ -n "$endpoint" ] || die 'an endpoint is required'
  command -v gh >/dev/null 2>&1 || die 'gh is required'
  if [ "$floor" -eq 1 ] && reason=$(quota_low core); then
    printf '%s\n' "$reason" >&2
    exit "$EX_TEMPFAIL"
  fi
  if [ -n "$query" ]; then
    case "$endpoint" in *\?*) endpoint="$endpoint&$query" ;; *) endpoint="$endpoint?$query" ;; esac
  fi
  endpoint=${endpoint#/}
  local pages=() next
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-rest.XXXXXX") || die 'cannot create a temporary directory'
  trap '[ -z "$work" ] || rm -rf -- "$work"' EXIT
  while [ -n "$endpoint" ] && [ "$i" -lt "$MAX_PAGES" ]; do
    i=$((i + 1))
    next=$(fetch_page "$endpoint" "$work/page.$i") || exit 1
    pages+=("$work/page.$i")
    if [ "$paginate" -eq 1 ]; then endpoint=$next; else endpoint=''; fi
  done
  if [ "$slurp" -eq 1 ]; then
    jq -sc . "${pages[@]}"
  else
    jq -c . "${pages[@]}"
  fi
  prune_cache # off the critical path: after the answer is out
}

cmd_guard() {
  local resource=core reason
  if [ "${1:-}" = --resource ]; then resource=${2:-core}; fi
  if reason=$(quota_low "$resource"); then
    printf '%s\n' "$reason"
    exit "$EX_TEMPFAIL"
  fi
}

cmd_status() {
  local file
  for file in "$STATE"/gh-ratelimit.*.json; do
    [ -f "$file" ] && jq -c . "$file"
  done
  return 0
}

case "${1:-}" in
  get) shift; cmd_get "$@" ;;
  guard) shift; cmd_guard "$@" ;;
  status) cmd_status ;;
  *) usage >&2; exit 2 ;;
esac
