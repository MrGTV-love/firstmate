#!/usr/bin/env bash
# fm-model-picker-jev.sh - one policy-checked System One POST for the shadow model picker.
# Usage: fm-model-picker-jev.sh <request.json> <never-send-path> <response-file> <scratch-file>
#
# Reads the TypeSafe key from file descriptor 3, so the key is never on argv, in the
# environment, or in a file. It runs bin/fm-typesafe-lib.sh's never-send literal filter over
# every request string before sending, then uses the shared fm_typesafe_post transport
# (fixed endpoint, five-second deadline, no retries). The response file holds the provider
# body byte for byte; the picker validates it and retains it unchanged.
#
# Exit codes: 0 HTTP 200 (the code is printed on stdout); 3 the never-send policy withheld
# the request (one coarse reason on stderr, never the matching text); 5 a non-200 HTTP code
# (printed on stdout); 4 a usage or transport failure. This tool is internal to
# bin/fm-model-picker-shadow.sh; docs/configuration.md "Shadow model picker
# (FM_MODEL_PICKER_SHADOW)" owns the privacy boundary.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-typesafe-lib.sh
. "$SCRIPT_DIR/fm-typesafe-lib.sh"

[ "$#" -eq 4 ] || { printf 'error: need request, never-send path, response and scratch files\n' >&2; exit 4; }
REQUEST_FILE=$1 NEVER_SEND=$2 RESPONSE_FILE=$3 SCRATCH=$4
IFS= read -r TYPESAFE_API_KEY_PRIVATE <&3 || { printf 'error: no key on fd 3\n' >&2; exit 4; }
export -n TYPESAFE_API_KEY_PRIVATE
unset TYPESAFE_API_KEY
[ -r "$REQUEST_FILE" ] || { printf 'error: request file not readable\n' >&2; exit 4; }
REQUEST=$(cat "$REQUEST_FILE") || { printf 'error: request file not readable\n' >&2; exit 4; }
if [ -n "$NEVER_SEND" ] && ! fm_typesafe_permitted "$REQUEST" "$NEVER_SEND" "$SCRATCH"; then
  printf '%s\n' "${FM_TYPESAFE_WITHHELD_REASON:-never-send policy refused the request}" >&2
  exit 3
fi
CODE=$(fm_typesafe_post "$REQUEST" "$RESPONSE_FILE")
case "$CODE" in
  200) printf '%s\n' "$CODE"; exit 0 ;;
  [0-9][0-9][0-9]) printf '%s\n' "$CODE"; exit 5 ;;
  *) printf 'error: transport failure\n' >&2; exit 4 ;;
esac
