#!/usr/bin/env bash
# Read-only pass-through to real gh with optional one-shot fault injection.
REAL=/opt/homebrew/bin/gh
S=${SHIM_DIR:?}
printf '%s\n' "$*" | tr '\n' ' ' | cut -c1-600 >> "$S/calls.log"; echo >> "$S/calls.log"
block() { printf 'SHIM BLOCKED: %s\n' "$*" >> "$S/blocked.log"; echo "shim: blocked non-read gh call" >&2; exit 97; }
count() { local f="$S/count-$1" n; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
all="$*"
case "${1:-}" in
  pr) [ "${2:-}" = view ] || block "$@" ;;
  api)
    if printf '%s\n' "$@" | grep -qx graphql; then
      case "$all" in *mutation*) block "$@" ;; esac
    else
      for a in "$@"; do case "$a" in -X|--method|-f|-F|--field|--raw-field|--input|-X*|--method=*) block "$@" ;; esac; done
    fi ;;
  *) block "$@" ;;
esac
FAULT=${SHIM_FAULT:-none}
case "$all" in
  *'contexts(first:'*)
    n=$(count rollup)
    case "$FAULT" in
      rollup-503-once) [ "$n" -ne 1 ] || { echo 'gh: Service Unavailable (HTTP 503)' >&2; exit 1; } ;;
      rollup-ratelimit-once) [ "$n" -ne 1 ] || { echo 'gh: You have exceeded a secondary rate limit (HTTP 403)' >&2; exit 1; } ;;
      rollup-partial-once|rollup-partial-always)
        if [ "$FAULT" = rollup-partial-always ] || [ "$n" -eq 1 ]; then
          "$REAL" "$@" | jq -c '.data.repository.object.statusCheckRollup.contexts.nodes |= .[0:5]'; exit "${PIPESTATUS[0]}"
        fi ;;
      rollup-empty-once)
        if [ "$n" -eq 1 ]; then
          "$REAL" "$@" | jq -c '.data.repository.object.statusCheckRollup.contexts |= (.nodes = [])'; exit "${PIPESTATUS[0]}"
        fi ;;
      rollup-drop-required-always)
        # Consistent, self-complete read in which one required check truly never reported.
        "$REAL" "$@" | jq -c --arg drop "$SHIM_DROP" '.data.repository.object.statusCheckRollup.contexts |=
          (.nodes |= map(select((.name // .context) != $drop)) | .totalCount = (.nodes | length))'; exit "${PIPESTATUS[0]}" ;;
    esac ;;
  *'/branches/'*)
    case "$all" in *'/rules/branches/'*) ;; *)
      n=$(count branch)
      if [ "$FAULT" = branch-503-once ] && [ "$n" -eq 1 ]; then echo 'gh: Service Unavailable (HTTP 503)' >&2; exit 1; fi ;;
    esac ;;
esac
case "$all" in
  *'contexts(first:'*) "$REAL" "$@" | tee "$S/rollup-real-$n.json"; exit "${PIPESTATUS[0]}" ;;
esac
exec "$REAL" "$@"
