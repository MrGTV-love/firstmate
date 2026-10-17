#!/usr/bin/env bash
# fm-typesafe-health.sh - tell the captain once when the TypeSafe (Jev) account
# stops answering for a reason only the captain can fix, and once when it recovers.
#
# Usage:
#   fm-typesafe-health.sh probe                       one tiny request, then classify
#   fm-typesafe-health.sh record <http-code> [source] classify a code a Jev consumer saw
#   fm-typesafe-health.sh status                      print the recorded state
#
# Classes: ok (200), credits (402), auth (401 or 403), unreachable (a transport
#   failure, a timeout, or any other HTTP code). Only credits and auth are the
#   captain's to fix, so only they raise a wake at once. Unreachable stays in
#   state/.typesafe-health until FM_TYPESAFE_HEALTH_UNREACHABLE_PROBES consecutive
#   probes (default 3) have all failed, then raises one wake of its own.
#
# Wakes (kind check, deduplicated by the recorded alerted class, so a repeat of
#   the same failure is silent until a 200 clears it):
#   check: typesafe-health: ... out of credits | key rejected | unreachable
#   check: typesafe-health: recovered ...
#   Each payload names what failed, since when, and the consumers affected
#   (dispatch resolution, worker skill picking, compact-adviser, the Level 6
#   guard, belay), so firstmate can turn it into one plain captain message.
#   The wake row is appended before the state is updated, so an interruption can
#   repeat an alert but never lose one.
#
# Who runs it: the watcher starts `probe` detached every FM_TYPESAFE_HEALTH_INTERVAL
#   seconds (bin/fm-watch.sh typesafe_health_tick; there is no daemon).
#   bin/fm-dispatch-resolve.sh and bin/fm-skill-pick.sh call `record` the moment
#   they see 402, 401, or 403, so the alert does not wait for the next probe.
#   A 200 recorded by a consumer clears an alert; any other code is ignored,
#   except `record 000 jev-guard`: a full guard budget exhausted, not a skipped
#   cooldown call. Three observations within 15 minutes alert through this same
#   health channel; expired history and repeated alerted failures stay silent.
#
# Only the primary home alerts. A home with a .fm-secondmate-parent record or a
#   .fm-secondmate-home marker uses the primary home's key (fm_typesafe_key), so
#   it exits silently and leaves no state; the primary home's wake already
#   reaches the captain. A home with no key (Jev off) also does nothing.
#
# Request and key: one POST through fm_typesafe_post in bin/fm-typesafe-lib.sh
#   (fixed endpoint, five-second deadline, no retries) with a constant two-option
#   Choice question and no brief text, so the never-send policy has nothing to
#   check. fm_typesafe_key resolves the key; it stays in one shell variable,
#   reaches curl as a header read from a file descriptor, and is never exported,
#   placed on argv, or written to any output, state, or wake.
#
# docs/configuration.md "TypeSafe account health" owns the operator contract and
#   the measurement behind the unreachable threshold.
# Regression coverage: tests/fm-typesafe-health.test.sh and
#   tests/fm-watch-typesafe-health.test.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

MODE=${1:-}
case "$MODE" in
  probe|status) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  record)
    [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage >&2; exit 2; }
    case "$2" in
      [0-9][0-9][0-9]) ;;
      *) echo "error: record needs a three-digit HTTP code" >&2; exit 2 ;;
    esac
    ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

is_secondmate_home() {
  [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ] \
    || [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]
}

if is_secondmate_home; then
  [ "$MODE" != status ] || echo "typesafe-health: secondmate home (silent; the primary home alerts)"
  exit 0
fi

# Ordinary dispatches report a 200 or a code the probe owns on every call, so the
# no-op cases leave before the wake library is even loaded.
if [ "$MODE" = record ]; then
  case "$2:${3:-}" in 200:*|402:*|401:*|403:*|000:jev-guard) ;; *) exit 0 ;; esac
  [ "$2" != 200 ] || [ -f "${FM_STATE_OVERRIDE:-$FM_HOME/state}/.typesafe-health" ] || exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-typesafe-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-typesafe-lib.sh"

HEALTH_FILE="$STATE/.typesafe-health"
HEALTH_LOCK="$STATE/.typesafe-health.lock"
UNREACHABLE_PROBES=${FM_TYPESAFE_HEALTH_UNREACHABLE_PROBES:-3}
case "$UNREACHABLE_PROBES" in
  ''|*[!0-9]*|0) UNREACHABLE_PROBES=3 ;;
  *) UNREACHABLE_PROBES=$((10#$UNREACHABLE_PROBES)) ;;
esac
CONSUMERS="worker dispatch resolution, worker skill picking, compact-adviser judgments (no automatic compaction), the Level 6 jev-guard, and the belay Stop hook"

S_STATUS=ok S_SINCE='' S_ALERTED='' S_ALERTED_SINCE='' S_COUNT=0 S_LAST_OK='' S_LAST_PROBE='' S_SOURCE='' S_DETAIL='' S_GUARD_OUTAGES=''

load_state() {
  local key value
  S_STATUS=ok S_SINCE='' S_ALERTED='' S_ALERTED_SINCE='' S_COUNT=0 S_LAST_OK='' S_LAST_PROBE='' S_SOURCE='' S_DETAIL='' S_GUARD_OUTAGES=''
  [ -f "$HEALTH_FILE" ] && [ ! -L "$HEALTH_FILE" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      status) S_STATUS=$value ;;
      since) S_SINCE=$value ;;
      alerted) S_ALERTED=$value ;;
      alerted_since) S_ALERTED_SINCE=$value ;;
      unreachable_count) S_COUNT=$value ;;
      last_ok) S_LAST_OK=$value ;;
      last_probe) S_LAST_PROBE=$value ;;
      last_source) S_SOURCE=$value ;;
      last_detail) S_DETAIL=$value ;;
      guard_outages) S_GUARD_OUTAGES=$value ;;
    esac
  done < "$HEALTH_FILE"
  case "$S_STATUS" in ok|credits|auth|unreachable) ;; *) S_STATUS=ok ;; esac
  case "$S_ALERTED" in ''|credits|auth|unreachable) ;; *) S_ALERTED='' ;; esac
  case "$S_COUNT" in ''|*[!0-9]*) S_COUNT=0 ;; esac
}

write_state() {
  local tmp="$HEALTH_FILE.tmp.$$"
  {
    printf 'status=%s\nsince=%s\nalerted=%s\nalerted_since=%s\nunreachable_count=%s\n' \
      "$S_STATUS" "$S_SINCE" "$S_ALERTED" "$S_ALERTED_SINCE" "$S_COUNT"
    printf 'last_ok=%s\nlast_probe=%s\nlast_source=%s\nlast_detail=%s\n' \
      "$S_LAST_OK" "$S_LAST_PROBE" "$S_SOURCE" "$S_DETAIL"
    printf 'guard_outages=%s\n' "$S_GUARD_OUTAGES"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$HEALTH_FILE" || { rm -f -- "$tmp"; return 1; }
}

iso_utc() {  # <epoch>
  case "$1" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf 'unknown'
}

span() {  # <seconds>
  local s=$1
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -ge 3600 ]; then printf '%dh %dm' $((s / 3600)) $((s % 3600 / 60))
  else printf '%dm' $((s / 60)); fi
}

# Payloads are plain sentences so firstmate can pass the meaning on in one short
# captain message without decoding internals.
alert_payload() {  # <class> <since> <count>
  local class=$1 since=$2 count=$3 seen
  if [ -n "$S_LAST_OK" ]; then seen="last answered normally at $(iso_utc "$S_LAST_OK")"
  else seen="no earlier normal answer was recorded"; fi
  case "$class" in
    credits)
      printf 'check: typesafe-health: the TypeSafe (Jev) account is out of credits (HTTP 402), first seen %s UTC by %s (%s). Until credits are added these fail silently and carry on without Jev: %s. Tell the captain once, in plain words, that the TypeSafe account needs credits; a recovered note follows by itself.' \
        "$(iso_utc "$since")" "$S_SOURCE" "$seen" "$CONSUMERS" ;;
    auth)
      printf 'check: typesafe-health: TypeSafe (Jev) rejected the API key (HTTP %s), first seen %s UTC by %s (%s). Until a working key is in the primary home .env these fail silently and carry on without Jev: %s. Tell the captain once, in plain words, that the TypeSafe key needs replacing or re-authorizing; a recovered note follows by itself.' \
        "${S_DETAIL#http }" "$(iso_utc "$since")" "$S_SOURCE" "$seen" "$CONSUMERS" ;;
    unreachable)
      printf 'check: typesafe-health: the TypeSafe (Jev) API has not answered %s checks in a row (%s), since %s UTC (%s). This is not a credit or key problem. Until it answers these carry on without Jev: %s. Tell the captain once, in plain words, that Jev is unreachable; a recovered note follows by itself.' \
        "$count" "$S_DETAIL" "$(iso_utc "$since")" "$seen" "$CONSUMERS" ;;
  esac
}

# observe <class> <detail> <source> - apply one observation under the state lock.
# class is ok, credits, auth, or unreachable; detail is a fixed phrase or code.
observe() {
  local class=$1 detail=$2 source=$3 now rc=0 payload stamp recent='' guard_count=0
  fm_epoch_seconds_to now
  fm_lock_acquire_wait_max "$HEALTH_LOCK" 10 || return 1
  load_state
  if [ "$source" = jev-guard ] && [ "$class" = unreachable ]; then
    for stamp in $S_GUARD_OUTAGES; do
      case "$stamp" in ''|*[!0-9]*) continue ;; esac
      if [ "$stamp" -ge "$((now - 900))" ]; then recent="${recent:+$recent }$stamp"; guard_count=$((guard_count + 1)); fi
    done
    S_GUARD_OUTAGES="${recent:+$recent }$now"
    guard_count=$((guard_count + 1))
  fi
  case "$class" in
    ok)
      # A consumer's 200 with no recorded history changes nothing, so a healthy
      # home gains no state file from ordinary dispatches.
      if [ ! -f "$HEALTH_FILE" ] && [ "$source" != probe ]; then
        fm_lock_release "$HEALTH_LOCK"
        return 0
      fi
      if [ -n "$S_ALERTED" ]; then
        payload="check: typesafe-health: recovered - the TypeSafe (Jev) API answers again at $(iso_utc "$now") UTC after $(span $((now - ${S_ALERTED_SINCE:-$now}))) ($S_ALERTED since $(iso_utc "$S_ALERTED_SINCE") UTC). Jev consumers work again. Tell the captain in one short note; no action needed."
        fm_wake_append check typesafe-health-recovered "$payload" || rc=1
        [ "$rc" -eq 0 ] || { fm_lock_release "$HEALTH_LOCK"; return 1; }
      fi
      [ "$S_STATUS" = ok ] && [ -n "$S_SINCE" ] || S_SINCE=$now
      S_STATUS=ok S_ALERTED='' S_ALERTED_SINCE='' S_COUNT=0 S_LAST_OK=$now
      ;;
    credits|auth|unreachable)
      if [ "$S_STATUS" != "$class" ] || [ -z "$S_SINCE" ]; then S_SINCE=$now; fi
      S_STATUS=$class
      if [ "$class" = unreachable ]; then S_COUNT=$((S_COUNT + 1)); else S_COUNT=0; fi
      S_DETAIL=$detail S_SOURCE=$source
      payload=''
      case "$class" in
        credits|auth)
          [ "$S_ALERTED" = "$class" ] || payload=$(alert_payload "$class" "$S_SINCE" "$S_COUNT") ;;
        unreachable)
          # A failure the captain was already told about is never replaced by a
          # vaguer one, and an unreachable alert is not repeated.
          if [ "$source" = jev-guard ]; then
            if [ "$guard_count" -ge 3 ] && [ -z "$S_ALERTED" ]; then
              payload="check: typesafe-health: Jev guard exhausted $guard_count judgment budgets in the last 15 minutes. Required shell and write reviews are denied during outages; untrusted flagged or unavailable results are withheld. A 60-second judge cooldown avoids repeated waits. Investigate judge availability; no automatic protection bypass is enabled."
            fi
          elif [ "$S_COUNT" -ge "$UNREACHABLE_PROBES" ] && [ -z "$S_ALERTED" ]; then
            payload=$(alert_payload unreachable "$S_SINCE" "$S_COUNT")
          fi ;;
      esac
      if [ -n "$payload" ]; then
        fm_wake_append check "typesafe-health-$class" "$payload" || { fm_lock_release "$HEALTH_LOCK"; return 1; }
        S_ALERTED=$class S_ALERTED_SINCE=$S_SINCE
      fi
      ;;
  esac
  S_DETAIL=$detail S_SOURCE=$source
  [ "$source" != probe ] || S_LAST_PROBE=$now
  write_state || rc=1
  fm_lock_release "$HEALTH_LOCK"
  return "$rc"
}

classify_http() {  # <http-code> -> sets CLASS and DETAIL
  case "$1" in
    200) CLASS=ok DETAIL="http 200" ;;
    402) CLASS=credits DETAIL="http 402" ;;
    401|403) CLASS=auth DETAIL="http $1" ;;
    *) CLASS=unreachable DETAIL="http $1" ;;
  esac
}

run_probe() {
  local request resp timing exit_file http curl_exit
  fm_typesafe_key "$FM_HOME" || return 0
  command -v curl >/dev/null 2>&1 || return 0
  resp=$(mktemp) || return 1
  timing=$(mktemp) || { rm -f "$resp"; return 1; }
  exit_file=$(mktemp) || { rm -f "$resp" "$timing"; return 1; }
  request='{"model":"jev-latest","state":{"purpose":"account health check"},"questions":{"health":{"type":"choice","instructions":"This is a connectivity check. Pick option_a.","criteria":{"option_a":"The first option.","option_b":"The second option."}}}}'
  http=$(fm_typesafe_post "$request" "$resp" "$timing" "$exit_file")
  curl_exit=$(cat "$exit_file" 2>/dev/null)
  rm -f "$resp" "$timing" "$exit_file"
  classify_http "$http"
  if [ "$http" = 000 ]; then
    if [ "$curl_exit" = 28 ]; then DETAIL="timed out after 5s"; else DETAIL="no connection (curl exit ${curl_exit:-unknown})"; fi
  fi
  observe "$CLASS" "$DETAIL" probe || return 1
  printf 'typesafe-health: %s (%s)\n' "$CLASS" "$DETAIL"
}

run_record() {
  local code=$1 source=${2:-consumer}
  case "$source" in *[!a-z0-9-]*|'') source=consumer ;; esac
  case "$code" in
    200|402|401|403) ;;
    000) [ "$source" = jev-guard ] || return 0 ;;
    *) return 0 ;;
  esac
  classify_http "$code"
  observe "$CLASS" "$DETAIL" "$source"
}

run_status() {
  load_state
  printf 'typesafe-health:\n  status: %s\n  since: %s\n  alerted: %s\n  unreachable_count: %s (alert at %s)\n  last_ok: %s\n  last_probe: %s\n  last_source: %s\n  last_detail: %s\n' \
    "$S_STATUS" "$(iso_utc "$S_SINCE")" "${S_ALERTED:-none}" "$S_COUNT" "$UNREACHABLE_PROBES" \
    "$(iso_utc "$S_LAST_OK")" "$(iso_utc "$S_LAST_PROBE")" "${S_SOURCE:-none}" "${S_DETAIL:-none}"
}

case "$MODE" in
  probe) run_probe; exit 0 ;;
  record) run_record "$2" "${3:-}"; exit 0 ;;
  status) run_status ;;
esac
