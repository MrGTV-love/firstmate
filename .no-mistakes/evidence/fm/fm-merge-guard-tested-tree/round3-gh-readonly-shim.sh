#!/usr/bin/env bash
# Round 3 test harness (evidence, not product code): a read-only pass-through
# wrapper around the real gh. Every read goes to real GitHub.
# - Refuses any write: 'pr merge', -X/--method other than GET, REST -f/-F, graphql mutation.
# - Injects ONLY the tested-tree artifact list, holding the record the new
#   ci.yml / no-mistakes-required.yml would upload:
#   fm-tested-tree-$FM_SHIM_TREE-base-$FM_SHIM_BASE-attempt-<real run attempt>
# - FM_SHIM_SOCKET_OTHER_HEAD=1 rewrites only the head_sha of socket-security
#   check runs to a different commit (adversarial case).
# - Logs every call to $FM_SHIM_LOG.
REAL_GH=/opt/homebrew/bin/gh
log() { [ -n "${FM_SHIM_LOG:-}" ] && printf '%s\n' "$*" >> "$FM_SHIM_LOG"; return 0; }
args="$*"
log "$args"
if [ "${1:-}" = pr ] && [ "${2:-}" = merge ]; then log "REFUSED $args"; echo 'shim: write refused' >&2; exit 97; fi
prev=
graphql=0; [ "${2:-}" = graphql ] && graphql=1
for a in "$@"; do
  case "$prev" in -X|--method) [ "$a" = GET ] || { log "REFUSED $args"; exit 97; } ;; esac
  case "$a" in -X*|--method=*) [ "$a" = -XGET ] || [ "$a" = --method=GET ] || { [ "$a" = -X ] || { log "REFUSED $args"; exit 97; }; } ;; esac
  if [ "$graphql" = 0 ] && [ "${1:-}" = api ]; then case "$a" in -f|-F|--field|--raw-field) log "REFUSED $args"; exit 97 ;; esac; fi
  if [ "$graphql" = 1 ]; then case "$a" in *mutation*) log "REFUSED $args"; exit 97 ;; esac; fi
  prev=$a
done
endpoint=
for a in "$@"; do case "$a" in repos/*) endpoint=$a ;; esac; done
if [ -n "${FM_SHIM_TREE:-}" ] && [[ "$endpoint" =~ ^repos/([^/]+/[^/]+)/actions/runs/([0-9]+)/artifacts$ ]]; then
  repo=${BASH_REMATCH[1]}; run=${BASH_REMATCH[2]}
  attempt=$("$REAL_GH" api "repos/$repo/actions/runs/$run" --jq .run_attempt) || exit 1
  head=$("$REAL_GH" api "repos/$repo/actions/runs/$run" --jq .head_sha) || exit 1
  jq -n --arg name "fm-tested-tree-$FM_SHIM_TREE-base-$FM_SHIM_BASE-attempt-$attempt" \
        --argjson run "$run" --arg head "$head" \
    '[{total_count:1, artifacts:[{name:$name, expired:false, workflow_run:{id:$run, head_sha:$head}}]}]'
  log "INJECTED artifact for run $run attempt $attempt"
  exit 0
fi
if [ "${FM_SHIM_SOCKET_OTHER_HEAD:-}" = 1 ] && [[ "$endpoint" =~ /commits/[0-9a-f]{40}/check-runs$ ]]; then
  out=$("$REAL_GH" "$@") || exit 1
  printf '%s' "$out" | jq '[.[] | .check_runs |= map(if .app.slug == "socket-security" then .head_sha = "0000000000000000000000000000000000000000" else . end)]'
  log "REWROTE socket-security head_sha"
  exit 0
fi
exec "$REAL_GH" "$@"
