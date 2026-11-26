#!/usr/bin/env bash
# Pick the one project skill a worker should load, for its launch instructions.
# Usage: fm-skill-pick.sh --brief <filled-brief> --catalog <skill-dir>... [--record <file>] [--kind ship|scout]
#                        [--attempt-journal <new-private-file> <spawn-generation>]
# The optional attempt journal is written only if the picker engine runs and
# binds that recording to the generation allocated before selector execution.
# A wrapper no-send result is established by the separate accounting receipt.
# bin/fm-skill-pick.mjs runs the TypeSafe skill-suggestion cookbook recipe on
# the vendored hyper-jev client; its header owns recipe and roster mechanics.
# docs/configuration.md "Worker skill selection" owns provider policy and setup.
# This wrapper supplies what the example cannot: the brief text dispatch
# resolution may send (fm_typesafe_brief_task), the dispatch-never-send check
# over every string a request can carry, and the keys from fm-typesafe-lib.sh,
# passed to Node on stdin.
# Output: the "# Skill selection" launch-instructions section. --record also
# writes status= (picked, none or unavailable), reason=, picked= and accounting= lines.
# accounting is JSON with logical client calls, transport attempts and reported input/output counts.
# Null means unverified; these aggregates are not an individual provider-call census.
# Any failure yields status unavailable with its reason; exit 2 is a usage error.
# A TypeSafe HTTP 402, 401, or 403 in the reason goes to bin/fm-typesafe-health.sh
# record, so a credit or key failure reaches the captain once.
set -u
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[ "$SCRIPT_DIR" != "${BASH_SOURCE[0]}" ] || SCRIPT_DIR=.
# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"
SCRIPT_DIR="$(cd "$SCRIPT_DIR" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
BRIEF='' RECORD='' JOURNAL_ARGS=() KIND=ship CATALOGS=()
usage() { awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
die() { printf 'error: %s\nhelp: Run bin/fm-skill-pick.sh --help\n' "$1" >&2; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --attempt-journal)
      [ $# -ge 3 ] && [ -n "$2" ] && [[ "$3" =~ ^[A-Za-z0-9_.:/-]{1,128}$ ]] && [ "${#JOURNAL_ARGS[@]}" -eq 0 ] \
        || die 'expected one --attempt-journal path and spawn generation'
      JOURNAL_ARGS=("$2" "$3"); shift 3 ;;
    --brief|--catalog|--record|--kind)
      [ $# -ge 2 ] && [ -n "$2" ] || die "$1 requires a value"
      case "$1" in
        --brief) BRIEF=$2 ;;
        --catalog) CATALOGS+=("$2") ;;
        --record) RECORD=$2 ;;
        --kind) KIND=$2 ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -f "$BRIEF" ] && [ -r "$BRIEF" ] || die "--brief must be a readable regular file"
[ "${#CATALOGS[@]}" -gt 0 ] || die "--catalog is required"
case "$KIND" in ship|scout) ;; *) die "--kind must be ship or scout" ;; esac

STATUS=unavailable REASON='' PICKED='' SKILL_PATH='' FIT='' PROVIDER='' MODEL=''
# All wrapper exits before the engine ran are affirmative no-call results.
ACCOUNTING='{"client_calls":0,"transport_attempts":0,"input_tokens":0,"output_tokens":0}'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-skill-pick.XXXXXX") || die "could not allocate temporary files"
trap 'rm -rf "$WORK"' EXIT
umask 077
: > "$WORK/not-judged"

# Pass a TypeSafe HTTP failure the picker saw (its reason names the code, even
# when OpenRouter then answered) to the account-health alert at once, and a
# TypeSafe answer as proof of recovery. The health tool ignores other codes.
record_health() {
  local code
  code=$(printf '%s' "$REASON" | sed -n 's/.*typesafe HTTP \(40[123]\)\..*/\1/p' | head -n 1)
  [ -n "$code" ] || { [ "$PROVIDER" = typesafe ] && code=200; }
  [ -z "$code" ] || FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-typesafe-health.sh" record "$code" skill-pick </dev/null >/dev/null 2>&1 || true
}

finish() {
  record_health
  printf '\n# Skill selection\n\n'
  printf '%s\n' 'Existing mandatory skill triggers in these instructions and your skill index still apply first and unchanged.'
  case "$STATUS" in
    picked)
      printf '%s\n' 'Before starting work, read this skill in full and follow it while you do this task; where it conflicts with these instructions, these instructions win.'
      printf -- '- Picked for this task: %s - read %s\n' "$PICKED" "$SKILL_PATH"
      printf "Picked by %s through %s from this project's skills (fit %s); your skill index still applies for anything else this task needs.\n" "$MODEL" "$PROVIDER" "$FIT"
      ;;
    none) printf 'Skill selection found no fit among the judged project skills (%s); use your skill index as usual.\n' "$REASON" ;;
    *) printf 'Skill selection was unavailable for this task (%s). This does not mean no skill applies: check your skill index for skills that fit this task before starting work.\n' "$REASON" ;;
  esac
  [ ! -s "$WORK/not-judged" ] || printf 'Not judged, so check them yourself if relevant: %s.\n' "$(cat "$WORK/not-judged")"
  [ -z "$RECORD" ] || printf 'status=%s\nreason=%s\npicked=%s\naccounting=%s\n' "$STATUS" "$REASON" "$PICKED" "$ACCOUNTING" > "$RECORD" 2>/dev/null || true
  exit 0
}
unavailable() { REASON=$1; finish; }

# No key means nothing can be asked, so no other work is done.
fm_typesafe_key "$FM_HOME" || :
fm_openrouter_key "$FM_HOME" || :
[ -n "$TYPESAFE_API_KEY_PRIVATE$OPENROUTER_API_KEY_PRIVATE" ] || unavailable "no TypeSafe or OpenRouter key"
command -v node >/dev/null 2>&1 || unavailable "node is not installed"
command -v jq >/dev/null 2>&1 || unavailable "jq is not installed"
node "$SCRIPT_DIR/fm-skill-pick.mjs" check 2> "$WORK/error" ||
  unavailable "$(cat "$WORK/error")"
fm_typesafe_brief_task "$BRIEF" "$CONFIG/dispatch-never-send" "$WORK/task" "$KIND" ||
  unavailable "task text withheld: $FM_TYPESAFE_WITHHELD_REASON"
grep -q '[^[:space:]]' "$WORK/task" || unavailable "the instructions have no task text"
node "$SCRIPT_DIR/fm-skill-pick.mjs" roster "${CATALOGS[@]}" > "$WORK/roster.json" 2> "$WORK/error" ||
  unavailable "$(cat "$WORK/error")"
jq -r '[.not_judged[] | "\(.name) (\(.reason))"] | join(", ") | select(length > 0)' "$WORK/roster.json" > "$WORK/not-judged" 2>/dev/null ||
  : > "$WORK/not-judged"
ACCOUNTING='{"client_calls":null,"transport_attempts":null,"input_tokens":null,"output_tokens":null}'
printf '%s\n%s\n' "$TYPESAFE_API_KEY_PRIVATE" "$OPENROUTER_API_KEY_PRIVATE" |
  node "$SCRIPT_DIR/fm-skill-pick.mjs" pick "$WORK/task" "$WORK/roster.json" "$CONFIG/dispatch-never-send" "$WORK/scan" \
    "${JOURNAL_ARGS[@]+"${JOURNAL_ARGS[@]}"}" > "$WORK/result" 2> "$WORK/error" ||
  unavailable "the skill picker stopped with an error: $(cat "$WORK/error")"
field() { sed -n "s/^$1=//p" "$WORK/result" | head -n 1; }
STATUS=$(field status) REASON=$(field reason) PICKED=$(field picked) SKILL_PATH=$(field path | jq -r '.')
FIT=$(field fit) PROVIDER=$(field provider) MODEL=$(field model)
reported=$(field accounting)
[ -z "$reported" ] || ACCOUNTING=$reported
case "$STATUS" in
  picked|none) ;;
  *) STATUS=unavailable; [ -n "$REASON" ] || REASON="the skill picker gave no result" ;;
esac
finish
