#!/usr/bin/env bash
# fm-guard-metrics.sh - the single reader of guard decision events and the owner
# of the retirement rule.
#
# docs/guard-spec.md defines the numbers. This script computes them from
# state/guard-events.jsonl so a cut is decided by measurement, not by a static
# cost estimate, and so the operator can see which guards are quiet.
#
# Usage:
#   fm-guard-metrics.sh [--log <path>] [--registry <path>] [--min-opportunities <n>]
#                       [--json] [--undecided] [--guards <id,id,...>] [-h|--help]
#
# Numbers per guard:
#   opportunities         every decision recorded for this guard (deny, warn,
#                         allow, error), the retirement denominator
#   denies, warns         fires by decision
#   override_rate         overrides / fires, the strongest false-positive signal
#   median_clear_attempts median count of consecutive denies in one session
#                         before an allow, the units an agent spends clearing
#   recurrences           denies that follow a cleared deny in the same session
#   verdict               cut | keep | unmeasured, per the threshold below
#
# Retirement threshold, from docs/guard-spec.md: a guard enters the cut list when
# any holds across at least --min-opportunities (default 30) decisions:
#   - zero denies and zero warns
#   - override rate above 20%
#   - median clear attempts greater than 3
#   - a recurrence after a clear
# Irreversible harm exempts a guard from the first two conditions and never from
# the third or fourth. The registry supplies each guard's harm.
#
# Output: one line per guard, sorted by id:
#   METRIC <id> opportunities=<n> denies=<n> warns=<n> override_rate=<f>
#          median_clear_attempts=<f> recurrences=<n> verdict=<v>
# followed by METRICS_SUMMARY guards=<n> measured=<n> cut=<n> unmeasured=<n>.
# With --json, one object carries the same fields.
# With --undecided, print only the ids whose verdict is `cut` and whose registry
# entry carries no `retirement_decision`, one per line: a nomination nobody has
# judged yet. It is the question a session start asks, so the pass cannot sit
# unread in a log forever.
#
# Exit: 0 on success, 2 on usage error or an unreadable log path. A missing log
# is not an error: every guard is simply unmeasured, because no evidence is not
# evidence of a defect.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG=''
REGISTRY="$ROOT/docs/guards/registry.json"
MIN_OPPS=30
JSON=0
UNDECIDED=0
ONLY=''

usage() { sed -n '3,44p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --log) [ $# -ge 2 ] || die "--log needs a value"; LOG=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; REGISTRY=$2; shift 2 ;;
    --min-opportunities) [ $# -ge 2 ] || die "--min-opportunities needs a value"; MIN_OPPS=$2; shift 2 ;;
    --guards) [ $# -ge 2 ] || die "--guards needs a value"; ONLY=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --undecided) UNDECIDED=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

case "$MIN_OPPS" in ''|*[!0-9]*|0) die "--min-opportunities must be a positive integer" ;; esac
command -v jq >/dev/null 2>&1 || die "jq is required"

[ -n "$LOG" ] || LOG="${FM_GUARD_EVENT_LOG:-${FM_HOME:-${FM_ROOT:-$ROOT}}/state/guard-events.jsonl}"

# Harm per guard, so the irreversible exemption is data rather than judgment at
# read time. A guard absent from the registry is treated as irreversible: an
# unknown guard must never be cut by a metrics pass that cannot see what it
# protects.
harm_of() {
  local id=$1 h
  h=$(jq -r --arg id "$id" '.guards[]? | select(.id == $id) | (.harm // "")' "$REGISTRY" 2>/dev/null)
  case "$h" in
    irreversible) printf 'irreversible' ;;
    reversible) printf 'reversible' ;;
    style) printf 'style' ;;
    *) printf 'unknown' ;;
  esac
}

emit() {  # <id> <opps> <denies> <warns> <override_rate> <median> <recurrences> <verdict> <harm>
  local id=$1 opps=$2 denies=$3 warns=$4 rate=$5 median=$6 recur=$7 verdict=$8 harm=$9
  if [ "$JSON" -eq 1 ]; then
    jq -n --arg id "$id" --argjson opps "$opps" --argjson denies "$denies" --argjson warns "$warns" \
      --argjson rate "$rate" --argjson median "$median" --argjson recur "$recur" \
      --arg verdict "$verdict" --arg harm "$harm" \
      '{id:$id, opportunities:$opps, denies:$denies, warns:$warns, override_rate:$rate,
        median_clear_attempts:$median, recurrences:$recur, verdict:$verdict, harm:$harm}'
  else
    printf 'METRIC %s opportunities=%s denies=%s warns=%s override_rate=%s median_clear_attempts=%s recurrences=%s verdict=%s\n' \
      "$id" "$opps" "$denies" "$warns" "$rate" "$median" "$recur" "$verdict"
  fi
}

if [ ! -f "$LOG" ]; then
  [ "$UNDECIDED" -eq 1 ] && exit 0
  if [ "$JSON" -eq 1 ]; then
    printf '{"guards":[],"summary":{"guards":0,"measured":0,"cut":0,"unmeasured":0},"log":"%s","present":false}\n' "$LOG"
  else
    printf 'METRICS_SUMMARY guards=0 measured=0 cut=0 unmeasured=0 log_absent=true\n'
  fi
  exit 0
fi

# One pass over the log, grouped by guard. The retirement rule needs every
# guard's rows, and the previous shape rescanned the file once per guard, which
# made a live 700 KB log cost seconds on the session-start path. `fromjson?`
# drops a torn final line instead of failing the whole read.
groups=$(jq -c -R 'fromjson? | objects | select((.guard // "") != "")' "$LOG" 2>/dev/null \
  | jq -c -s --arg only "$ONLY" '
      group_by(.guard)[]
      | {id: .[0].guard, rows: .}
      | . as $group
      | select($only == "" or ($only | split(",") | index($group.id)))
    ' 2>/dev/null || true)

# The registry's recorded retirement decision, when the pass already judged this
# guard. A nomination without one is what a session start must surface.
decision_of() {  # <id>
  jq -r --arg id "$1" '.guards[]? | select(.id == $id) | (.retirement_decision // "")' "$REGISTRY" 2>/dev/null
}

guards_n=0; measured=0; cut=0; unmeasured=0; undecided=''
if [ "$JSON" -eq 1 ]; then : >"${TMPDIR:-/tmp}/fm-guard-metrics.$$.jsonl" || die "cannot write temp"; fi
while IFS= read -r group; do
  [ -n "$group" ] || continue
  id=$(printf '%s' "$group" | jq -r '.id')
  rows=$(printf '%s' "$group" | jq -c '.rows')
  guards_n=$((guards_n + 1))
  opps=$(printf '%s' "$rows" | jq 'length')
  denies=$(printf '%s' "$rows" | jq '[.[] | select(.decision == "deny")] | length')
  warns=$(printf '%s' "$rows" | jq '[.[] | select(.decision == "warn")] | length')
  overrides=$(printf '%s' "$rows" | jq '[.[] | select(.override == true)] | length')
  fires=$((denies + warns))
  if [ "$fires" -gt 0 ]; then
    rate=$(jq -n --argjson o "$overrides" --argjson f "$fires" '$o / $f | . * 1000 | round | . / 1000')
  else
    rate=0
  fi
  # Median clear attempts: consecutive denies in one session before an allow.
  attempts=$(printf '%s' "$rows" | jq -r '
    sort_by(.ts) | group_by(.session)[]
    | reduce .[] as $e ({runs: [], cur: 0};
        if $e.decision == "deny" then .cur += 1
        elif $e.decision == "allow" then (if .cur > 0 then .runs += [.cur] else . end) | .cur = 0
        else . end)
    | .runs[]' 2>/dev/null | sort -n || true)
  if [ -n "$attempts" ]; then
    median=$(printf '%s\n' "$attempts" | awk '{a[NR]=$1} END {if (NR % 2) print a[(NR+1)/2]; else print (a[NR/2] + a[NR/2+1]) / 2}')
  else
    median=0
  fi
  recur=$(printf '%s' "$rows" | jq -r '
    sort_by(.ts) | group_by(.session)
    | map(reduce .[] as $e ({cleared: false, n: 0};
        if $e.decision == "deny" and .cleared then .n += 1
        elif $e.decision == "allow" then .cleared = true
        else . end) | .n)
    | add // 0' 2>/dev/null || echo 0)
  harm=$(harm_of "$id")
  if [ "$opps" -lt "$MIN_OPPS" ]; then
    verdict="unmeasured"
    unmeasured=$((unmeasured + 1))
  else
    measured=$((measured + 1))
    verdict="keep"
    # Irreversible harm, and an unknown guard, are exempt from the zero-fire and
    # override conditions and never from the recurrence conditions below.
    case "$harm" in
      reversible|style)
        if [ "$fires" -eq 0 ]; then verdict="cut"; fi
        if awk -v r="$rate" 'BEGIN {exit !(r > 0.2)}'; then verdict="cut"; fi
        ;;
    esac
    if awk -v m="$median" 'BEGIN {exit !(m > 3)}'; then verdict="cut"; fi
    if [ "$recur" -gt 0 ]; then verdict="cut"; fi
    if [ "$verdict" = cut ]; then
      cut=$((cut + 1))
      [ -n "$(decision_of "$id")" ] || undecided="$undecided$id
"
    fi
  fi
  [ "$UNDECIDED" -eq 1 ] && continue
  if [ "$JSON" -eq 1 ]; then
    emit "$id" "$opps" "$denies" "$warns" "$rate" "$median" "$recur" "$verdict" "$harm" >>"${TMPDIR:-/tmp}/fm-guard-metrics.$$.jsonl"
  else
    emit "$id" "$opps" "$denies" "$warns" "$rate" "$median" "$recur" "$verdict" "$harm"
  fi
done < <(printf '%s\n' "$groups")

if [ "$UNDECIDED" -eq 1 ]; then
  printf '%s' "$undecided"
  exit 0
fi

if [ "$JSON" -eq 1 ]; then
  jq -s --argjson g "$guards_n" --argjson m "$measured" --argjson c "$cut" --argjson u "$unmeasured" --arg log "$LOG" \
    '{log:$log, present:true, guards: ., summary:{guards:$g, measured:$m, cut:$c, unmeasured:$u}}' \
    "${TMPDIR:-/tmp}/fm-guard-metrics.$$.jsonl"
  rm -f "${TMPDIR:-/tmp}/fm-guard-metrics.$$.jsonl"
else
  printf 'METRICS_SUMMARY guards=%s measured=%s cut=%s unmeasured=%s\n' "$guards_n" "$measured" "$cut" "$unmeasured"
fi
exit 0
