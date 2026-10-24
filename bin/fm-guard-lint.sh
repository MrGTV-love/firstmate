#!/usr/bin/env bash
# fm-guard-lint.sh - the single owner of the guard-registry lint.
#
# Validates docs/guards/registry.json against the nine rules in docs/guard-spec.md
# and enforces the ratchet: a violation that is not allowlisted fails, and an
# allowlisted violation that no longer occurs also fails, so
# docs/guards/lint-allowlist.json can only shrink.
#
# Usage:
#   fm-guard-lint.sh [--mode report|enforce|new-or-touched] [--base <git-ref>]
#                    [--root <dir>] [--registry <path>] [--allowlist <path>]
#                    [--retired <path>] [--json] [--counts] [-h|--help]
#
# --root points the lint at another checkout or at a fixture tree; every path in
# the registry is resolved against it. The default is this script's repository.
#
# Modes:
#   report          print every violation and exit 0 (the ratchet's first step)
#   enforce         exit 1 on any violation not allowlisted, and on any stale
#                   allowlisted entry whose violation is gone (the default)
#   new-or-touched  enforce only for guards added or edited since --base, so new
#                   work cannot add debt while the legacy population burns down
#
# Rules, each owned by docs/guard-spec.md:
#   R1 unique id, unique normalized invariant, unique owner+invariant pair
#   R2 no block without an executable remedy whose repository paths exist
#   R3 a proxy source carries proxy_reason
#   R4 the fail direction is declared closed or open
#   R5 the block budget is declared, 1 to 3, or carries budget_reason
#   R6 a post-write guard carries precheck_gap
#   R7 every owner file and test file resolves (wiring itself is owned by
#      bin/fm-guard-refcheck.sh)
#   R8 every instrumented guard names its telemetry target and calls the writer
#   R9 every exemption carries a derivation and a demotion candidate
#
# Output:
#   VIOLATION <rule> <id>: <message>          one line per violation
#   INFO <id>: <message>                      non-failing observations
#   LINT_SUMMARY mode=<m> guards=<n> violations=<v> allowlisted=<a> stale=<s> shown=<k>
# With --json, one JSON object is written to stdout instead, carrying the same
# fields plus the complete violation and stale-entry lists.
#
# Exit: 0 clean or report mode; 1 violations, stale entries, or a malformed
# registry; 2 usage error. A missing registry is a violation, not a skip,
# because a guard population with no registry is exactly the state this lint
# exists to make visible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE=enforce
BASE_REF=origin/main
ROOT_OVERRIDE=''
REGISTRY=''
ALLOWLIST=''
RETIRED=
JSON=0
COUNTS=0

usage() { sed -n '3,45p' "$0" | sed 's/^# \{0,1\}//'; }

die_usage() { echo "error: $*" >&2; echo "run with --help" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) [ $# -ge 2 ] || die_usage "--mode needs a value"; MODE=$2; shift 2 ;;
    --root) [ $# -ge 2 ] || die_usage "--root needs a value"; ROOT_OVERRIDE=$2; shift 2 ;;
    --base) [ $# -ge 2 ] || die_usage "--base needs a value"; BASE_REF=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || die_usage "--registry needs a value"; REGISTRY=$2; shift 2 ;;
    --allowlist) [ $# -ge 2 ] || die_usage "--allowlist needs a value"; ALLOWLIST=$2; shift 2 ;;
    --retired) [ $# -ge 2 ] || die_usage "--retired needs a value"; RETIRED=$2; shift 2 ;;
    --json) JSON=1; shift ;;
    --counts) COUNTS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "unknown argument '$1'" ;;
  esac
done

case "$MODE" in report|enforce|new-or-touched) ;; *) die_usage "unknown mode '$MODE'" ;; esac

if [ -n "$ROOT_OVERRIDE" ]; then
  [ -d "$ROOT_OVERRIDE" ] || die_usage "root is not a directory: $ROOT_OVERRIDE"
  ROOT=$(cd "$ROOT_OVERRIDE" && pwd -P)
fi
: "${REGISTRY:=$ROOT/docs/guards/registry.json}"
: "${ALLOWLIST:=$ROOT/docs/guards/lint-allowlist.json}"
: "${RETIRED:=$ROOT/docs/guards/retired.json}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

VIOLATIONS=$(mktemp "${TMPDIR:-/tmp}/fm-guard-lint.XXXXXX") || exit 2
trap 'rm -f "$VIOLATIONS"' EXIT

violation() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$VIOLATIONS"; }
info() { [ "$JSON" -eq 1 ] || printf 'INFO %s: %s\n' "$1" "$2"; }

# Every repository path token in a remedy must exist. Tokens are the prefixes the
# spec names: bin/, tests/, docs/, config/, state/, plus a bare script name.
check_remedy_paths() {  # <id> <remedy>
  local id=$1 remedy=$2 tok
  for tok in $(printf '%s' "$remedy" | tr ' ()`",;' '[\n*]' | grep -E '^(bin|scripts|tests|docs|config|state|\.claude|\.codex|\.github|\.pi|\.grok|\.omp|\.cursor|\.opencode|\.tac)/' || true); do
    tok=${tok%"${tok##*[!.,;:]}"}
    case "$tok" in
      config/*|state/*|projects/*) continue ;;
    esac
    [ -e "$ROOT/$tok" ] || violation R2 "$id" "remedy names '$tok', which does not exist"
  done
}

has_executable_token() {  # <remedy>
  local r=$1
  printf '%s' "$r" | grep -Eq '(^|[[:space:]"(])(bin|scripts|tests|docs|config|state|\.claude|\.codex|\.github|\.tac)/' && return 0
  # shellcheck disable=SC2016 # Match literal Markdown backticks, not command substitution.
  printf '%s' "$r" | grep -Eq '`[^`]+`' && return 0
  printf '%s' "$r" | grep -Eq '(^|[[:space:](])env -u ' && return 0
  printf '%s' "$r" | grep -Eq '(^|[[:space:](])git [a-z]' && return 0
  printf '%s' "$r" | grep -Eq 'FM_[A-Z_]+=' && return 0
  return 1
}

[ -f "$REGISTRY" ] || { echo "error: registry not found: $REGISTRY" >&2; exit 1; }
jq -e '.guards | type == "array"' "$REGISTRY" >/dev/null 2>&1 \
  || { echo "error: registry is not valid JSON with a guards array: $REGISTRY" >&2; exit 1; }

# ---------------------------------------------------------------- R1 uniqueness
dup_ids=$(jq -r '.guards[].id' "$REGISTRY" | sort | uniq -d)
if [ -n "$dup_ids" ]; then
  while IFS= read -r id; do
    [ -n "$id" ] && violation R1 "$id" "duplicate guard id"
  done <<EOF
$dup_ids
EOF
fi

# A shared invariant is one rule owned twice. Normalization strips case and
# punctuation so two spellings of one behavior still collide.
jq -r '.guards
  | group_by(.invariant | ascii_downcase | gsub("[^a-z0-9]+"; " ") | gsub("^ +| +$"; ""))
  | map(select(length > 1))
  | .[]
  | (map(.id) | sort) as $ids
  | [$ids[0], ($ids[1:] | join(","))] | @tsv' "$REGISTRY" 2>/dev/null \
  | while IFS=$'\t' read -r first rest; do
      [ -n "$first" ] || continue
      violation R1 "$first" "invariant shared with: $rest"
    done

# ------------------------------------------------------------- per-guard rules
jq -c '.guards[]' "$REGISTRY" >"${VIOLATIONS}.guards" 2>/dev/null || true
while IFS= read -r entry; do
  id=$(printf '%s' "$entry" | jq -r '.id // ""')
  [ -n "$id" ] || continue
  layer=$(printf '%s' "$entry" | jq -r '.layer // ""')
  owner=$(printf '%s' "$entry" | jq -r '.owner // ""')
  invariant=$(printf '%s' "$entry" | jq -r '.invariant // ""')
  source=$(printf '%s' "$entry" | jq -r '.source // ""')
  trigger=$(printf '%s' "$entry" | jq -r '.trigger // ""')
  remedy=$(printf '%s' "$entry" | jq -r '.remedy // ""')
  fail=$(printf '%s' "$entry" | jq -r '.fail_direction // ""')
  budget=$(printf '%s' "$entry" | jq -r '.budget | if type == "number" then tostring else . end')
  budget_reason=$(printf '%s' "$entry" | jq -r '.budget_reason // ""')
  telemetry=$(printf '%s' "$entry" | jq -r '.telemetry // ""')
  test=$(printf '%s' "$entry" | jq -r '.test // ""')
  decision=$(printf '%s' "$entry" | jq -r '.decision // ""')
  precheck_gap=$(printf '%s' "$entry" | jq -r '.precheck_gap // ""')
  proxy=$(printf '%s' "$entry" | jq -r '.proxy // false')
  proxy_reason=$(printf '%s' "$entry" | jq -r '.proxy_reason // ""')
  instrumented=$(printf '%s' "$entry" | jq -r '.instrumented // false')
  exempt_count=$(printf '%s' "$entry" | jq -r '(.exemptions // []) | length')

  case "$layer" in
    impossible-by-construction|machine-check|runtime-block|runtime-warn|runtime-warn-after-write|prose) ;;
    *) violation R4 "$id" "unknown layer '$layer'" ;;
  esac
  [ -n "$invariant" ] || violation R1 "$id" "invariant is empty"
  [ -n "$source" ] || violation R3 "$id" "source is empty"
  [ -n "$trigger" ] || violation R3 "$id" "trigger is empty"
  case "$decision" in deny|warn|allow) ;; *) violation R4 "$id" "decision '$decision' is not deny, warn, or allow" ;; esac

  if [ -z "$remedy" ]; then
    violation R2 "$id" "remedy is empty"
  else
    has_executable_token "$remedy" \
      || violation R2 "$id" "remedy has no executable token: $remedy"
    check_remedy_paths "$id" "$remedy"
  fi

  [ "$proxy" = true ] && [ -z "$proxy_reason" ] \
    && violation R3 "$id" "proxy source with no proxy_reason"

  case "$fail" in
    closed|open) ;;
    "") violation R4 "$id" "fail_direction is not declared" ;;
    *) violation R4 "$id" "fail_direction '$fail' is not closed or open" ;;
  esac

  case "$budget" in
    ''|null) violation R5 "$id" "budget is not declared" ;;
    *[!0-9]*) violation R5 "$id" "budget '$budget' is not a number" ;;
    *)
      if [ "$budget" -gt 3 ] && [ -z "$budget_reason" ]; then
        violation R5 "$id" "budget $budget exceeds 3 with no budget_reason"
      fi
      [ "$budget" -ge 1 ] || violation R5 "$id" "budget must be at least 1"
      ;;
  esac

  if [ "$layer" = runtime-warn-after-write ] && [ -z "$precheck_gap" ]; then
    violation R6 "$id" "post-write guard with no precheck_gap"
  fi

  if [ -z "$owner" ]; then
    violation R7 "$id" "owner is empty"
  else
    printf '%s\n' "$owner" | tr ',' '\n' | tr '+' '\n' | while IFS= read -r f; do
      f=$(printf '%s' "$f" | tr -d ' \t')
      [ -n "$f" ] || continue
      [ -e "$ROOT/$f" ] || printf 'R7\t%s\tnonexistent owner file %s\n' "$id" "$f" >>"$VIOLATIONS"
    done
  fi
  if [ -z "$test" ]; then
    violation R7 "$id" "test is empty"
  else
    [ -e "$ROOT/$test" ] || violation R7 "$id" "nonexistent test file $test"
  fi

  if [ -z "$telemetry" ]; then
    violation R8 "$id" "telemetry is empty"
  fi
  if [ "$instrumented" = true ]; then
    if [ -z "$owner" ]; then
      violation R8 "$id" "instrumented guard has no owner"
    else
      # The writer call must live in the guard's owner, or in a host file the
      # registry names under emitters when the invariant is decided in a caller.
      emitters=$(printf '%s\n' "$entry" | jq -r '(.emitters // [])[]?' 2>/dev/null)
      found=0
      for candidate in "$owner" $emitters; do
        if grep -qsE 'fm_guard_event|fm-guard-event\.sh' "$ROOT/$candidate"; then
          found=1
          break
        fi
      done
      if [ "$found" -eq 0 ]; then
        violation R8 "$id" "instrumented guard never calls the guard event writer in $owner${emitters:+ or its emitters}"
      fi
    fi
  fi

  if [ "$exempt_count" -gt 0 ]; then
    while IFS=$'\t' read -r case_text derivation demotion; do
      [ -n "$derivation" ] || violation R9 "$id" "exemption '$case_text' has no derivation"
      [ -n "$demotion" ] || violation R9 "$id" "exemption '$case_text' has no demotion candidate"
    done <<EOF
$(printf '%s' "$entry" | jq -r '.exemptions[]? | [(.case // ""), (.derivation // ""), (.demotion // "")] | @tsv')
EOF
    info "$id" "exemptions=$exempt_count"
  fi
done <"${VIOLATIONS}.guards"
rm -f "${VIOLATIONS}.guards"

# ------------------------------------------------- retired and inventory shape
if [ -f "$RETIRED" ]; then
  jq -r '.[].id // empty' "$RETIRED" 2>/dev/null | while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    reason=$(jq -r --arg id "$rid" '.[] | select(.id == $id) | (.why // .reason // "")' "$RETIRED")
    rtest=$(jq -r --arg id "$rid" '.[] | select(.id == $id) | (.retirement_test // "")' "$RETIRED")
    [ -n "$reason" ] || violation R1 "$rid" "retired entry has no reason"
    [ -n "$rtest" ] || violation R1 "$rid" "retired entry has no retirement test"
    [ -e "$ROOT/$rtest" ] || violation R7 "$rid" "retirement test $rtest does not exist"
    jq -e --arg id "$rid" '.guards[]? | select(.id == $id)' "$REGISTRY" >/dev/null 2>&1 \
      && violation R1 "$rid" "retired guard is still registered"
  done
fi

if [ "$COUNTS" -eq 1 ]; then
  audited=$(jq -r '.audited // 0' "$REGISTRY")
  active=$(jq -r '.guards | length' "$REGISTRY")
  retired_n=$(jq -r 'length' "$RETIRED" 2>/dev/null || echo 0)
  excluded_n=$(jq -r '(.excluded // []) | length' "$REGISTRY")
  unregistered_n=$(jq -r '(.unregistered_ids // []) | length' "$REGISTRY")
  beyond_n=$(jq -r '(.beyond_audit_retired // []) | length' "$REGISTRY")
  beyond_active_n=$(jq -r '(.beyond_audit_active // []) | length' "$REGISTRY")
  jq -r '(.guards | map(.id)) as $ids | (.beyond_audit_active // [])[] | select(. as $b | $ids | index($b) | not)' "$REGISTRY" \
    | while IFS= read -r bid; do
        [ -n "$bid" ] && printf 'R1\t%s\tbeyond_audit_active names no registered guard\n' "$bid" >>"$VIOLATIONS"
      done
  total=$((active - beyond_active_n + retired_n - beyond_n + excluded_n + unregistered_n))
  [ "$total" -eq "$audited" ] \
    || violation R1 "inventory" "active($active, $beyond_active_n beyond the audit) + retired($retired_n, $beyond_n beyond the audit) + excluded($excluded_n) + unregistered($unregistered_n) = $total, audited=$audited"
  info inventory "active=$active retired=$retired_n beyond_audit=$beyond_n excluded=$excluded_n unregistered=$unregistered_n audited=$audited beyond_audit_active=$beyond_active_n"
fi

# --------------------------------------------------------------- ratchet gate
ALLOWED_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-guard-allow.XXXXXX") || exit 2
SC=$(mktemp "${TMPDIR:-/tmp}/fm-guard-shown.XXXXXX") || exit 2
trap 'rm -f "$VIOLATIONS" "$ALLOWED_FILE" "$SC"' EXIT
if [ -f "$ALLOWLIST" ]; then
  jq -r '(.allowed // [])[] | [.id, .rule] | @tsv' "$ALLOWLIST" >"$ALLOWED_FILE" 2>/dev/null || : >"$ALLOWED_FILE"
else
  : >"$ALLOWED_FILE"
fi

is_allowed() {  # <id> <rule>
  awk -F'\t' -v id="$1" -v rule="$2" '$1 == id && $2 == rule {found = 1} END {exit !found}' "$ALLOWED_FILE"
}

en=0; st=0; shown=0
while IFS=$'\t' read -r rule id msg; do
  [ -n "$rule" ] || continue
  if is_allowed "$id" "$rule"; then
    en=$((en + 1))
    continue
  fi
  st=$((st + 1))
  shown=$((shown + 1))
  [ "$JSON" -eq 1 ] || printf 'VIOLATION %s %s: %s\n' "$rule" "$id" "$msg"
  printf '%s\t%s\t%s\n' "$rule" "$id" "$msg" >>"$SC"
done <"$VIOLATIONS"

stale=0
while IFS=$'\t' read -r aid arule; do
  [ -n "$aid" ] || continue
  if ! awk -F'\t' -v id="$aid" -v rule="$arule" '$2 == id && $1 == rule {found = 1} END {exit !found}' "$VIOLATIONS"; then
    stale=$((stale + 1))
    [ "$JSON" -eq 1 ] || printf 'STALE %s %s: allowlisted violation no longer occurs; remove the entry\n' "$arule" "$aid"
  fi
done <"$ALLOWED_FILE"

guards_n=$(jq -r '.guards | length' "$REGISTRY")
if [ "$JSON" -eq 1 ]; then
  jq -n --arg mode "$MODE" --argjson guards "$guards_n" --argjson violations "$shown" \
    --argjson allowlisted "$en" --argjson stale "$stale" --argjson total "$(wc -l <"$VIOLATIONS" | tr -d ' ')" \
    --rawfile lines "$SC" \
    '{mode:$mode, guards:$guards, violations:$total, unallowlisted:$violations, allowlisted:$allowlisted, stale:$stale,
      findings: ($lines | split("\n") | map(select(length > 0) | split("\t") | {rule: .[0], id: .[1], message: .[2]}))}'
else
  printf 'LINT_SUMMARY mode=%s guards=%s violations=%s allowlisted=%s stale=%s shown=%s\n' \
    "$MODE" "$guards_n" "$(wc -l <"$VIOLATIONS" | tr -d ' ')" "$en" "$stale" "$shown"
fi

case "$MODE" in
  report) exit 0 ;;
  enforce) [ "$stale" -eq 0 ] && [ "$shown" -eq 0 ] && exit 0; exit 1 ;;
  new-or-touched)
    # Only guards added or edited since the base are in scope. A changed guard is
    # one whose canonical JSON differs between the base registry and this one.
    base_json=$(mktemp "${TMPDIR:-/tmp}/fm-guard-base.XXXXXX") || exit 2
    trap 'rm -f "$VIOLATIONS" "$ALLOWED_FILE" "$SC" "$base_json"' EXIT
    if git -C "$ROOT" rev-parse --verify "$BASE_REF" >/dev/null 2>&1 \
      && git -C "$ROOT" show "$BASE_REF:docs/guards/registry.json" >"$base_json" 2>/dev/null; then
      touched=$(jq -r --slurpfile base "$base_json" '
        (.guards | map({key: .id, value: .}) | from_entries) as $now
        | ($base[0].guards | map({key: .id, value: .}) | from_entries) as $was
        | $now | keys[] | select(($was[.] == null) or ($was[.] != $now[.]))' "$REGISTRY")
      if [ -z "$touched" ]; then
        exit 0
      fi
      out=0
      while IFS= read -r gid; do
        [ -n "$gid" ] || continue
        awk -F'\t' -v id="$gid" '$2 == id {print}' "$SC" | while IFS=$'\t' read -r r i m; do
          [ -n "$r" ] || continue
          printf 'VIOLATION %s %s: %s\n' "$r" "$i" "$m"
        done
        awk -F'\t' -v id="$gid" '$2 == id {found = 1} END {exit !found}' "$SC" && out=1
      done <<EOF
$touched
EOF
      exit "$out"
    fi
    echo "error: cannot resolve base ref '$BASE_REF' for new-or-touched mode" >&2
    exit 2
    ;;
esac
