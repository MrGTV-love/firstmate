#!/usr/bin/env bash

# fm_utc_iso_to_epoch <YYYY-MM-DDTHH:MM[:SS]Z>: the one portable UTC ISO 8601
# reader shared by the declared-wait vocabulary and the away-posture record
# (bin/fm-afk-contract.sh). Prints epoch seconds; returns 1 on any other shape
# so a malformed time is refused rather than read as "now".
fm_utc_iso_to_epoch() {  # <timestamp>
  local ts=$1
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]Z) ts="${ts%Z}:00Z" ;;
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) ;;
    *) return 1 ;;
  esac
  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null \
    || date -u -d "$ts" +%s 2>/dev/null \
    || return 1
}
