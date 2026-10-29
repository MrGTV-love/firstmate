#!/usr/bin/env bash
set -u
id=${1:-}
[ -z "${FM_FAKE_CREW_STATE_LOG:-}" ] || printf '%s\n' "$id" >> "$FM_FAKE_CREW_STATE_LOG"
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
