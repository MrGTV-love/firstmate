#!/usr/bin/env bash
# Conditional GitHub REST reads and the shared quota floor.
#
# Usage:
#   fm-gh-rest.sh get <endpoint> [--paginate] [--slurp]
#   fm-gh-rest.sh guard
#
# get makes one REST GET per page through `gh api -i` and prints the JSON body (one document per page;
# --slurp prints a single array of page bodies; --paginate follows Link rel="next"). get checks the quota floor
# before every page. A forge error exits 1 with its message on stderr; error responses are not cached.
# The per-URL cache is <state>/gh-rest-cache/, with JSON entries {etag,body,next}; body is JSON text stored
# as a string and next is the next endpoint or null. Quota records are <state>/gh-ratelimit.<resource>.json
# with {resource,limit,remaining,reset,observed}; reset and observed are Unix epoch seconds.
# guard checks the recorded core bucket locally: quota refusal exits 75 with its reason on stdout;
# otherwise it exits 0 silently. A get below the floor exits 75 with its reason on stderr and no partial
# JSON output.
# The floor is 15 percent of the limit. An expired window or missing quota record does not refuse a read.
#
# <state> is FM_STATE_OVERRIDE, else $FM_HOME/state, else $FM_ROOT_OVERRIDE/state, else the code root's
# state/. docs/configuration.md "GitHub REST reads and the quota floor" owns conditional-cache behavior,
# quota-recording invariants, and sweep degradation; this header owns the helper's interface.
#
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}/state}
CACHE="$STATE/gh-rest-cache"
EX_TEMPFAIL=75
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
  jq -er '15 as $floor
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

record_rate() (
  local limit=$1 remaining=$2 reset=$3 resource=$4 file previous prev_reset prev_remaining
  case "$limit$remaining$reset" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$limit" ] && [ -n "$remaining" ] && [ -n "$reset" ] || return 0
  file="$STATE/gh-ratelimit.$resource.json"
  if [ -f "$file" ]; then
    previous=$(jq -r 'select((.reset | type) == "number" and (.remaining | type) == "number") | "\(.reset) \(.remaining)"' "$file" 2>/dev/null || true)
    if [ -n "$previous" ]; then
      prev_reset=${previous% *}; prev_remaining=${previous#* }
      [ "$prev_reset" -le "$reset" ] || return 0
      if [ "$prev_reset" = "$reset" ] && [ "$prev_remaining" -lt "$remaining" ]; then remaining=$prev_remaining; fi
    fi
  fi
  local staged
  staged=$(mktemp "$STATE/.gh-ratelimit.XXXXXX") || return 0
  printf '{"resource":"%s","limit":%s,"remaining":%s,"reset":%s,"observed":%s}\n' \
    "$resource" "$limit" "$remaining" "$reset" "$(date +%s)" > "$staged"
  mv -f -- "$staged" "$file" || rm -f -- "$staged"
)

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

record_response() (
  local headers=$1 staged=${2:-} entry=${3:-} snapshot=${4:-}
  local lock="$STATE/gh-ratelimit.core.json.lock"
  local limit='' remaining='' reset='' resource=core name value
  while IFS='=' read -r name value; do
    case "$name" in
      x-ratelimit-limit) limit=$value ;;
      x-ratelimit-remaining) remaining=$value ;;
      x-ratelimit-reset) reset=$value ;;
      x-ratelimit-resource) resource=$(printf '%s' "$value" | tr -c 'A-Za-z0-9_-' '_') ;;
    esac
  done < <(header_pairs "$headers")
  mkdir -p "$STATE" 2>/dev/null || return 0
  [ -w "$STATE" ] || return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait_max "$lock" 2 2>/dev/null || return 0
  trap 'fm_lock_release "$lock"' EXIT
  record_rate "$limit" "$remaining" "$reset" "$resource"
  [ -n "$staged" ] || return 0
  [ -z "$snapshot" ] || cmp -s "$snapshot" "$entry" || return 0
  mv -f -- "$staged" "$entry"
)

# Succeeds when the cached body is a list holding exactly per_page items (GitHub's default is 30).
full_page() { # endpoint snapshot
  local per_page
  per_page=$(printf '%s' "$1" | sed -n 's/.*[?&]per_page=\([0-9][0-9]*\).*/\1/p')
  jq -e --argjson per_page "${per_page:-30}" '.body | fromjson | type == "array" and length == $per_page' "$2" >/dev/null 2>&1
}

# fetch_page <endpoint> <body-out> [paginate|unconditional] : prints the next endpoint (or nothing) on stdout;
# returns 1 on a forge error. unconditional sends no If-None-Match.
fetch_page() {
  local endpoint=$1 body_out=$2 mode=${3:-} entry snapshot etag='' raw hdr err status next staged=''
  entry=$(cache_path "$endpoint")
  raw="$work/raw.$RANDOM$RANDOM"
  hdr="$raw.hdr"; err="$raw.err"; snapshot="$raw.cache"
  if [ "$mode" != unconditional ] && cat "$entry" > "$snapshot" 2>/dev/null && jq -e '(.etag | type == "string" and length > 0) and (.body | type == "string") and (.body | fromjson | true)' \
    "$snapshot" >/dev/null 2>&1; then
    etag=$(jq -r .etag "$snapshot")
  fi
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
  local name value response_etag='' link='' has_link=0
  while IFS='=' read -r name value; do
    case "$name" in etag) response_etag=$value ;; link) link=$value; has_link=1 ;; esac
  done < <(header_pairs "$hdr")
  next=$(printf '%s' "$link" | tr ',' '\n' | sed -n 's/^[[:space:]]*<\([^>]*\)>[[:space:]]*;[[:space:]]*rel="next".*/\1/p' | head -1 | sed -E 's#^https?://[^/]+/##')
  if [ "$status" = 304 ] && [ -n "$etag" ]; then
    jq -r .body "$snapshot" > "$body_out"
    if [ "$has_link" -eq 0 ]; then
      next=$(jq -r '.next // empty' "$snapshot")
      if [ -z "$next" ] && [ "$mode" = paginate ] && full_page "$endpoint" "$snapshot"; then
        record_response "$hdr" || true
        rm -f -- "$raw" "$hdr" "$err"
        fetch_page "$endpoint" "$body_out" unconditional
        return
      fi
    fi
    if staged=$(mktemp "$CACHE/.entry.XXXXXX" 2>/dev/null); then
      if ! { jq --arg next "$next" '.next = (if $next == "" then null else $next end)' "$snapshot" > "$staged" \
        && chmod 600 "$staged"; }; then
        rm -f -- "$staged"
        staged=''
      fi
    fi
    record_response "$hdr" "$staged" "$entry" "$snapshot" || true
    [ -z "$staged" ] || rm -f -- "$staged"
    rm -f -- "$raw" "$hdr" "$err"
    printf '%s' "$next"
    return 0
  fi
  case "$status" in
    2??)
      if [ "$rc" -eq 0 ] && jq -e . "$body_out" >/dev/null 2>&1; then
        etag=$response_etag
        if [ -n "$etag" ] && mkdir -p "$CACHE" 2>/dev/null && staged=$(mktemp "$CACHE/.entry.XXXXXX" 2>/dev/null); then
          if ! { jq -n --arg etag "$etag" --rawfile body "$body_out" --arg next "$next" \
            '{etag:$etag,body:$body,next:(if $next == "" then null else $next end)}' > "$staged" \
            && chmod 600 "$staged"; }; then
            rm -f -- "$staged"
            staged=''
          fi
        fi
        record_response "$hdr" "$staged" "$entry" || true
        [ -z "$staged" ] || rm -f -- "$staged"
        rm -f -- "$raw" "$hdr" "$err"
        printf '%s' "$next"
        return 0
      fi
      ;;
  esac
  record_response "$hdr" || true
  { head -c 300 "$err"; [ -s "$err" ] || head -c 300 "$body_out"; } | tr '\n' ' ' | sed 's/ *$//' > "$raw.msg"
  [ -s "$raw.msg" ] || printf 'gh api failed' > "$raw.msg"
  cat "$raw.msg" >&2; printf '\n' >&2
  rm -f -- "$raw" "$hdr" "$err" "$raw.msg"
  return 1
}

cmd_get() {
  local endpoint='' paginate=0 slurp=0 reason i=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --paginate) paginate=1 ;;
      --slurp) slurp=1 ;;
      -*) die "unknown option: $1" ;;
      *) [ -z "$endpoint" ] || die 'one endpoint only'; endpoint=$1 ;;
    esac
    shift
  done
  [ -n "$endpoint" ] || die 'an endpoint is required'
  command -v gh >/dev/null 2>&1 || die 'gh is required'
  endpoint=${endpoint#/}
  local pages=()
  work=$(mktemp -d "${TMPDIR:-/tmp}/fm-gh-rest.XXXXXX") || die 'cannot create a temporary directory'
  trap '[ -z "$work" ] || rm -rf -- "$work"' EXIT
  while [ -n "$endpoint" ]; do
    if reason=$(quota_low core); then
      printf '%s\n' "$reason" >&2
      exit "$EX_TEMPFAIL"
    fi
    i=$((i + 1))
    if [ "$paginate" -eq 1 ]; then
      endpoint=$(fetch_page "$endpoint" "$work/page.$i" paginate) || exit 1
    else
      fetch_page "$endpoint" "$work/page.$i" >/dev/null || exit 1
      endpoint=''
    fi
    pages+=("$work/page.$i")
  done
  if [ "$slurp" -eq 1 ]; then
    jq -sc . "${pages[@]}"
  else
    jq -c . "${pages[@]}"
  fi
  prune_cache # off the critical path: after the answer is out
}

cmd_guard() {
  local reason
  if reason=$(quota_low core); then
    printf '%s\n' "$reason"
    exit "$EX_TEMPFAIL"
  fi
}

case "${1:-}" in
  get) shift; cmd_get "$@" ;;
  guard) shift; cmd_guard "$@" ;;
  *) usage >&2; exit 2 ;;
esac
