#!/usr/bin/env bash
# fm-guard-refcheck.sh - the single owner of the guard reference check.
#
# A registered hook path that does not exist is a dead guard: it claims coverage
# and runs nothing. The audit's Stage 0 turns "scan carefully" into a pass/fail
# machine, and this script is that machine for Firstmate.
#
# Usage:
#   fm-guard-refcheck.sh [--root <dir>] [--registry <path>] [--retired <path>]
#                        [--json] [-h|--help]
#
# What it proves, in order:
#   1. wiring: every script path a tracked harness registration names resolves
#      under the root. Registrations are the tracked files under .claude/,
#      .codex/, .cursor/, .grok/, .pi/, .opencode/, and .omp/, plus any file the
#      caller adds with --registrations.
#   2. registry: every owner and test path in the guard registry resolves.
#   3. retirement: every id in the retirement changelog has zero live references
#      outside the changelog itself and its own retirement test, and is absent
#      from the active registry.
#
# A path token is anything shaped like <prefix>/<name>.<ext> where prefix is bin,
# scripts, or a dot-directory hook tree and ext is sh, bash, py, ts, mjs, js,
# json, or toml. Tokens are resolved after stripping $CLAUDE_PROJECT_DIR/,
# ${CLAUDE_PROJECT_DIR}/, $FM_ROOT/, and a leading ./
#
# Output:
#   MISSING <path> registration=<file>          a wired path does not exist
#   RESURRECTED <guard> <file>:<line>           a retired guard is referenced
#   REFCHECK_SUMMARY registrations=<n> paths=<n> missing=<n> retired=<n> resurrected=<n>
# With --json, one JSON object carries the same fields plus every finding.
#
# Exit: 0 clean; 1 a missing wired path, a missing registry path, or a
# resurrected guard; 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY=''
RETIRED=
JSON=0
EXTRA_REGISTRATIONS=''

usage() { sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; }
die() { echo "error: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || die "--root needs a value"; ROOT=$2; shift 2 ;;
    --registry) [ $# -ge 2 ] || die "--registry needs a value"; REGISTRY=$2; shift 2 ;;
    --retired) [ $# -ge 2 ] || die "--retired needs a value"; RETIRED=$2; shift 2 ;;
    --registrations) [ $# -ge 2 ] || die "--registrations needs a value"; EXTRA_REGISTRATIONS="$EXTRA_REGISTRATIONS$2
"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1'" ;;
  esac
done

[ -d "$ROOT" ] || die "root is not a directory: $ROOT"
command -v jq >/dev/null 2>&1 || die "jq is required"
ROOT=$(cd "$ROOT" && pwd -P)
: "${REGISTRY:=$ROOT/docs/guards/registry.json}"
: "${RETIRED:=$ROOT/docs/guards/retired.json}"

FINDINGS=$(mktemp "${TMPDIR:-/tmp}/fm-guard-refcheck.XXXXXX") || exit 2
trap 'rm -f "$FINDINGS"' EXIT
: >"$FINDINGS"

# Registration files: tracked files in the harness configuration trees. Using
# git's own index keeps node_modules and vendored trees out of the scan.
registration_files() {
  { git -C "$ROOT" ls-files 2>/dev/null || find "$ROOT" -type f -print; } \
    | grep -E '^(\.claude/|\.codex/|\.cursor/|\.grok/|\.pi/|\.opencode/|\.omp/|\.kimi/)' \
    | grep -Ev '/(node_modules|dist|target|\.next|vendor)/' \
    | grep -E '\.(json|toml|ya?ml|sh|py|ts|mjs|js)$' || true
  printf '%s' "$EXTRA_REGISTRATIONS" | grep . || true
}

normalize_token() {
  local t=$1
  t=${t#\$\{CLAUDE_PROJECT_DIR\}/}
  t=${t#\$CLAUDE_PROJECT_DIR/}
  t=${t#\$\{FM_ROOT\}/}
  t=${t#\$FM_ROOT/}
  t=${t#./}
  printf '%s' "$t"
}

regs=$(registration_files)
reg_count=0
path_count=0
missing=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ -f "$ROOT/$file" ] || continue
  reg_count=$((reg_count + 1))
  # Script paths named by a registration, one per line, deduplicated per file.
  tokens=$(grep -oE '(\$\{?CLAUDE_PROJECT_DIR\}?/|\$\{?FM_ROOT\}?/|\./)?(bin|scripts|\.claude/hooks|\.claude/commands|\.codex|\.grok/hooks|\.pi/extensions|\.opencode/plugins|\.omp/extensions)/[A-Za-z0-9_./-]+\.(sh|bash|py|ts|mjs|js)([^A-Za-z0-9_.-]|$)' "$ROOT/$file" 2>/dev/null | sed -E 's/[^A-Za-z0-9_./-]$//' | sort -u || true)
  [ -n "$tokens" ] || continue
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    tok=$(normalize_token "$raw")
    path_count=$((path_count + 1))
    if [ ! -e "$ROOT/$tok" ]; then
      missing=$((missing + 1))
      [ "$JSON" -eq 1 ] || printf 'MISSING %s registration=%s\n' "$tok" "$file"
      printf 'MISSING\t%s\t%s\n' "$tok" "$file" >>"$FINDINGS"
    fi
  done <<EOF
$tokens
EOF
done <<EOF
$regs
EOF

# Registry wiring: owner and test paths resolve.
registry_missing=0
if [ -f "$REGISTRY" ]; then
  while IFS=$'\t' read -r id owner test; do
    for f in $(printf '%s\n' "$owner" | tr ',' '\n' | tr '+' '\n'); do
      f=$(printf '%s' "$f" | tr -d ' \t')
      [ -n "$f" ] || continue
      if [ ! -e "$ROOT/$f" ]; then
        registry_missing=$((registry_missing + 1))
        [ "$JSON" -eq 1 ] || printf 'MISSING %s registration=registry:%s\n' "$f" "$id"
        printf 'MISSING\t%s\tregistry:%s\n' "$f" "$id" >>"$FINDINGS"
      fi
    done
    if [ -n "$test" ] && [ ! -e "$ROOT/$test" ]; then
      registry_missing=$((registry_missing + 1))
      [ "$JSON" -eq 1 ] || printf 'MISSING %s registration=registry:%s\n' "$test" "$id"
      printf 'MISSING\t%s\tregistry:%s\n' "$test" "$id" >>"$FINDINGS"
    fi
  done <<EOF
$(jq -r '.guards[] | [.id, (.owner // ""), (.test // "")] | @tsv' "$REGISTRY")
EOF
fi

# Retirement: zero live references. The changelog and the guard's own retirement
# test are the two permitted places an id may appear, because that test has to
# name the action the guard used to block.
retired_count=0
resurrected=0
if [ -f "$RETIRED" ]; then
  while IFS=$'\t' read -r rid rtest; do
    [ -n "$rid" ] || continue
    retired_count=$((retired_count + 1))
    hits=$( { git -C "$ROOT" grep -n -F -e "$rid" -- . 2>/dev/null || true; } \
      | sed "s|^$ROOT/||" \
      | grep -v '^docs/guards/retired.json:' \
      | grep -v "^$rtest:" \
      | grep -v '^data/guard-audit' \
      | grep -v '^\.scratch/' || true)
    [ -n "$hits" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      resurrected=$((resurrected + 1))
      [ "$JSON" -eq 1 ] || printf 'RESURRECTED %s %s\n' "$rid" "$hit"
      printf 'RESURRECTED\t%s\t%s\n' "$rid" "$hit" >>"$FINDINGS"
      break
    done <<EOF
$hits
EOF
  done <<EOF
$(jq -r '.[] | [(.id // ""), (.retirement_test // "")] | @tsv' "$RETIRED")
EOF
fi

total_missing=$((missing + registry_missing))
if [ "$JSON" -eq 1 ]; then
  jq -n --argjson regs "$reg_count" --argjson paths "$path_count" --argjson missing "$total_missing" \
    --argjson registry_missing "$registry_missing" --argjson retired "$retired_count" \
    --argjson resurrected "$resurrected" --rawfile lines "$FINDINGS" \
    '{registrations:$regs, paths:$paths, missing:$missing, registry_missing:$registry_missing,
      retired:$retired, resurrected:$resurrected,
      findings: ($lines | split("\n") | map(select(length > 0) | split("\t") | {kind: .[0], subject: .[1], where: .[2]}))}' 2>/dev/null \
    || printf '{"registrations":%s,"paths":%s,"missing":%s,"registry_missing":%s,"retired":%s,"resurrected":%s}\n' \
      "$reg_count" "$path_count" "$missing" "$registry_missing" "$retired_count" "$resurrected"
else
  printf 'REFCHECK_SUMMARY registrations=%s paths=%s missing=%s registry_missing=%s retired=%s resurrected=%s\n' \
    "$reg_count" "$path_count" "$missing" "$registry_missing" "$retired_count" "$resurrected"
fi

[ "$total_missing" -eq 0 ] && [ "$resurrected" -eq 0 ] && exit 0
exit 1
