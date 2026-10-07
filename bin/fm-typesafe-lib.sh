# shellcheck shell=bash
# Shared TypeSafe boundary for dispatch and advisory skill selection.
# Usage: source this before launching children, then fm_typesafe_key <home>.
# fm_typesafe_post <request-json> <response-file> [transfer-seconds-file] uses
# the fixed endpoint and five-second deadline, with no retries. Prints only the
# HTTP code (000 on a transport failure), optionally saving curl's transfer time.
# The private key is never exported or placed on argv.
# fm_typesafe_permitted <request-json> <never-send-path> <scratch-file> checks
# every request string against the existing dispatch-never-send policy.
# A refusal sets FM_TYPESAFE_WITHHELD_REASON and returns 1, without echoing text.

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY_PRIVATE:-${TYPESAFE_API_KEY:-}}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

# shellcheck source=bin/fm-env-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-env-lib.sh"

fm_typesafe_key() {
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ]
}

fm_typesafe_post() {
  local request=$1 response=$2 timing=${3:-} result rc=0 http
  result=$(printf '%s' "$request" | curl -q -sS --max-time 5 -o "$response" -w '%{http_code} %{time_total}' \
    -X POST https://api.typesafe.ai/v1/systemone -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || rc=$?
  http=${result%% *}
  [ "$rc" -eq 0 ] || http=000
  if [ -n "$timing" ]; then
    case "$result" in
      *' '*) printf '%s' "${result#* }" > "$timing" ;;
      *) : > "$timing" ;;
    esac
  fi
  printf '%s' "$http"
}

fm_typesafe_policy_inspect() {
  local path=$1 ancestor
  FM_TYPESAFE_WITHHELD_REASON=
  case "$path" in
    */*) ancestor=${path%/*}; [ -n "$ancestor" ] || ancestor=/ ;;
    *) ancestor=. ;;
  esac
  while :; do
    if [ -d "$ancestor" ]; then
      if [ ! -x "$ancestor" ]; then
        FM_TYPESAFE_WITHHELD_REASON="could not inspect $path"
        return 1
      fi
    elif [ -e "$ancestor" ] || [ -L "$ancestor" ]; then
      FM_TYPESAFE_WITHHELD_REASON="could not inspect $path"
      return 1
    fi
    case "$ancestor" in
      /|.) break ;;
      */*) ancestor=${ancestor%/*}; [ -n "$ancestor" ] || ancestor=/ ;;
      *) ancestor=. ;;
    esac
  done
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if ! { [ -f "$path" ] && [ -r "$path" ]; }; then
    FM_TYPESAFE_WITHHELD_REASON="$path is not a readable regular file"
    return 1
  fi
}

# shellcheck disable=SC2034 # FM_TYPESAFE_WITHHELD_REASON is a caller-consumed result.
fm_typesafe_permitted() {
  local request=$1 path=$2 scratch=$3 list value n=0 rc
  fm_typesafe_policy_inspect "$path" || return 1
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if ! jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$request" > "$scratch" 2>/dev/null; then
    FM_TYPESAFE_WITHHELD_REASON="could not extract the request text to check"
    return 1
  fi
  if ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$path" 2>/dev/null); then
    FM_TYPESAFE_WITHHELD_REASON="could not read $path"
    return 1
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'# dispatch-never-send marked-sections') continue ;;
      '#'*)
        case "$(printf '%s' "${value#'#'}" | tr '[:upper:]' '[:lower:]')" in
          dispatch-never-send*|' dispatch-never-send'*)
            FM_TYPESAFE_WITHHELD_REASON="invalid privacy directive in $path line $n"
            return 1 ;;
        esac
        continue ;;
    esac
    grep -qiF -e "$value" "$scratch" 2>/dev/null; rc=$?
    case "$rc" in
      0) FM_TYPESAFE_WITHHELD_REASON="brief text matches $path line $n"; return 1 ;;
      1) ;;
      *) FM_TYPESAFE_WITHHELD_REASON="could not check the request text against $path line $n"; return 1 ;;
    esac
  done <<<"$list"
}
