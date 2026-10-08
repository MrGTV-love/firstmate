# shellcheck shell=bash
# Shared TypeSafe boundary for Firstmate's dispatch and Jev integrations.
# Usage: source this before launching children, then fm_typesafe_key <home>.
# fm_typesafe_key resolves the key from, in order, the process environment,
# <home>/.env, then the .env of the top-most local home reached through the
# existing .fm-secondmate-parent record (fm_firstmate_root_home), so a
# secondmate home and its crews share the primary home's single key without
# any copy. A remote-seeded home has no local primary and stops at its own .env.
# fm_openrouter_key <home> reads OPENROUTER_API_KEY from <home>/.env alone.
# fm_typesafe_post <request-json> <response-file> [transfer-seconds-file] uses
# the fixed endpoint and five-second deadline, with no retries. Prints only the
# HTTP code (000 on a transport failure), optionally saving curl's transfer time.
# The private key is never exported or placed on argv.
# fm_typesafe_permitted <request-json> <never-send-path> <scratch-file> checks
# every request string against the existing dispatch-never-send policy.
# fm_typesafe_brief_task <brief> <never-send-path> <output-file> [ship|scout]
# writes the permitted brief task text without relaxing existing output-file
# permissions. The optional kind selects current ship instructions for promoted
# briefs or the scout tag; omitting it preserves dispatch extraction.
# docs/configuration.md "What the model receives", "Never-send list", and
# "Worker skill selection" own the extraction and privacy contracts.
# A refusal sets FM_TYPESAFE_WITHHELD_REASON and returns 1, without echoing text.

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY_PRIVATE:-${TYPESAFE_API_KEY:-}}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY OPENROUTER_API_KEY_PRIVATE

# shellcheck source=bin/fm-env-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-env-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-brief-heading-lib.sh"

fm_typesafe_key() {
  local primary
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ] || TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$1/.env")
  if [ -z "$TYPESAFE_API_KEY_PRIVATE" ] && primary=$(fm_firstmate_root_home "$1" 2>/dev/null); then
    TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$primary/.env")
  fi
  [ -n "$TYPESAFE_API_KEY_PRIVATE" ]
}

# The OpenRouter fallback key comes from the same home .env only, never the
# ambient environment, where an unrelated project's OpenRouter key may live.
fm_openrouter_key() {
  OPENROUTER_API_KEY_PRIVATE=$(fmx_env_get OPENROUTER_API_KEY "$1/.env")
  [ -n "$OPENROUTER_API_KEY_PRIVATE" ]
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

# Reads the policy's directives only; literals are checked per request above.
# shellcheck disable=SC2034 # Both results are caller-consumed.
fm_typesafe_policy_marked_sections() {
  local path=$1 list value n=0
  FM_TYPESAFE_MARKED_SECTIONS=0
  fm_typesafe_policy_inspect "$path" || return 1
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if ! list=$(jq -Rr 'gsub("\\s+"; " ")' "$path" 2>/dev/null); then
    FM_TYPESAFE_WITHHELD_REASON="could not read $path"
    return 1
  fi
  while IFS= read -r value; do
    n=$((n + 1))
    value=${value# }
    value=${value% }
    case "$value" in
      '# dispatch-never-send marked-sections') FM_TYPESAFE_MARKED_SECTIONS=1 ;;
      '#'*)
        case "$(printf '%s' "${value#'#'}" | tr '[:upper:]' '[:lower:]')" in
          dispatch-never-send*|' dispatch-never-send'*)
            FM_TYPESAFE_WITHHELD_REASON="invalid privacy directive in $path line $n"
            return 1 ;;
        esac
        ;;
    esac
  done <<<"$list"
}

# shellcheck disable=SC2034 # FM_TYPESAFE_WITHHELD_REASON is a caller-consumed result.
# Markers are interpreted on the original brief, even inside Markdown fences,
# so protected headings cannot change extraction or cause a whole-brief fallback.
# Only the task-specific sections bin/fm-brief.sh scaffolds are sent, plus a
# scout tag from the scout contract line; the rest of a scaffolded brief is
# standard boilerplate whose safety language reads as high stakes on every task.
# Ship delivery mode is deliberately not sent.
fm_typesafe_brief_task() {
  local brief=$1 path=$2 output=$3 kind=${4:-} rc=0 heading sections promoted=0
  if [ "$kind" = ship ] && fm_brief_heading_present "$brief" "# Current ship Firstmate spec"; then
    promoted=1
  fi
  fm_typesafe_policy_marked_sections "$path" || return 1
  grep -qiE -e '<!--[[:space:]]*dispatch-never-send' "$brief" 2>/dev/null || rc=$?
  case "$rc" in
    0)
      if [ "$FM_TYPESAFE_MARKED_SECTIONS" -ne 1 ]; then
        FM_TYPESAFE_WITHHELD_REASON="never-send markers need the marked-sections directive"
        return 1
      fi
      if ! awk '
        {
          marker = $0
          sub(/^[[:space:]]+/, "", marker)
          sub(/[[:space:]]+$/, "", marker)
          if (marker == "<!-- dispatch-never-send:start -->") {
            if (hidden) exit 1
            hidden = 1
            next
          }
          if (marker == "<!-- dispatch-never-send:end -->") {
            if (!hidden) exit 1
            hidden = 0
            next
          }
          if (tolower($0) ~ /<!--[[:space:]]*dispatch-never-send/) exit 1
          if (!hidden) print
        }
        END { if (hidden) exit 1 }
      ' "$brief" > "$output" 2>/dev/null; then
        FM_TYPESAFE_WITHHELD_REASON="invalid never-send markers or unreadable brief"
        return 1
      fi
      ;;
    1)
      if ! cp "$brief" "$output" 2>/dev/null; then
        FM_TYPESAFE_WITHHELD_REASON="could not read the brief"
        return 1
      fi
      ;;
    *)
      FM_TYPESAFE_WITHHELD_REASON="could not read the brief"
      return 1
      ;;
  esac
  sections=$(
    for heading in "## Captain's intent" "## Firstmate spec"; do
      if [ "$promoted" -eq 1 ] && [ "$heading" = "## Firstmate spec" ]; then
        fm_brief_heading_present "$output" "# Current ship Firstmate spec" || continue
        printf '%s\n%s\n\n' '# Current ship Firstmate spec' "$(fm_brief_heading_body "$output" "# Current ship Firstmate spec")"
      elif fm_brief_task_heading_present "$output" "$heading"; then
        printf '%s\n%s\n\n' "$heading" "$(fm_brief_task_heading_body "$output" "$heading")"
      elif [ "$promoted" -eq 1 ] && [ "$heading" = "## Captain's intent" ]; then
        fm_brief_marked_captain_words "$(fm_brief_heading_body "$output" "# Task")"
      fi
    done
  )
  [ -n "$sections" ] || [ "$promoted" -eq 1 ] || return 0
  if [ "$kind" = scout ] || { [ -z "$kind" ] && grep -qxF 'This is a SCOUT task: the deliverable is a written report, not a PR.' "$output"; }; then
    sections=$'Brief kind: scout (report only)\n\n'"$sections"
  fi
  if ! printf '%s\n' "$sections" > "$output"; then
    FM_TYPESAFE_WITHHELD_REASON="could not read the brief"
    return 1
  fi
}
