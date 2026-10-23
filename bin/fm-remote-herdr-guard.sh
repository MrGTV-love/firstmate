#!/usr/bin/env bash
# launchd exec target for the Firstmate-owned dev.firstmate.herdr.fm-remote
# launch agent: make the Aqua login session own the fm-remote Herdr server.
#
# Usage:
#   fm-remote-herdr-guard.sh <herdr-path> <session>
#
# bin/fm-remote-doctor.sh renders the launch agent as the account's login
# shell running `exec <this script> <herdr> fm-remote` with
# LimitLoadToSessionType=Aqua, RunAtLoad, KeepAlive={SuccessfulExit=false},
# and ThrottleInterval=10, then bootstraps it into gui/<uid>. That domain, not
# the login shell, is what gives this process and every server it execs the
# Aqua audit session and login-keychain access; the login shell only gives the
# server the account's own environment.
# `herdr server` stays in the foreground under launchd, as verified in
# docs/verification/runtime-backends.md under "fm-remote server birth and login-keychain access", so the final exec provides the complete supervision lifecycle.
#
# Decision, made once per launch (exit codes matter under SuccessfulExit=false:
# 0 tells launchd the job is done until something restarts it, non-zero asks
# for a retry after the throttle interval):
#   ownership reader unavailable (python3 missing from, or not running on,
#   the launch agent PATH)             -> exit 1 before server start or takeover
#   no server owns the session socket  -> exec `herdr server --session <s>`
#                                          (foreground, launchd-supervised)
#   a failed or unparseable status, or a stopped status whose server process
#   and socket absence bin/backends/herdr-server-start.py --prove-absent
#   cannot prove                       -> log why, wait, and re-check; never
#                                          start a second server beside one
#                                          that may still be alive
#   the owner was born in the Aqua session (launchd or the Aqua remote-job
#   worker)                            -> exit 0, leave it alone
#   the owner was born anywhere else (an SSH remote attach, a shell over
#   ssh/mosh, or a birth it cannot prove) -> `herdr server stop`, wait until
#                                          absence is proven the same way, then exec
#                                          `herdr server --session <s>` at once
#                                          so the socket is rebound before a
#                                          reconnecting SSH attach can start
#                                          another foreign server
#   the foreign server does not release the socket in time -> exit 1
# Each exec first asks herdr-server-start.py --hold-for-exec for permission.
# That helper takes the session's Firstmate start lock, the same lock every
# other Firstmate starter holds, re-proves absence under it, and keeps holding
# it in its own process until the exec'd server reports running or exits, so
# this guard and an adapter start can never both launch. A server that came up
# under the lock is not started again; the guard re-checks instead.
# A takeover closes every pane in that session; the parent firstmate's
# secondmate liveness sweep relaunches its mates into the Aqua-born server.
# bin/fm-remote-herdr-owner-lib.sh owns the owner discovery and the birth
# markers; FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS (default 50) bounds the
# release wait in tenths of a second.
# Every socket-owner decision prints one line to stdout, which launchd routes
# to the agent's log; prerequisite refusals print to stderr.
set -u

SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$SCRIPT_DIR/fm-remote-herdr-owner-lib.sh"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ "$#" -eq 2 ] || usage
HERDR_BIN=$1
SESSION=$2
[ -n "$HERDR_BIN" ] && [ -x "$HERDR_BIN" ] || { printf 'fm-remote-herdr-guard: herdr is not executable: %s\n' "$HERDR_BIN" >&2; exit 1; }
[ -n "$SESSION" ] || usage
command -v jq >/dev/null 2>&1 || { printf 'fm-remote-herdr-guard: jq does not resolve on the launch agent PATH\n' >&2; exit 1; }
fm_remote_herdr_owner_reader_available || { printf 'fm-remote-herdr-guard: python3 prerequisite does not run on the launch agent PATH; refusing server start or takeover\n' >&2; exit 1; }
STOP_WAIT_TENTHS=${FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS:-50}

log() { printf 'fm-remote-herdr-guard: %s\n' "$*"; }

herdr_status() { # prints the session's status JSON; fails when herdr fails
  HERDR_SESSION="$SESSION" "$HERDR_BIN" status --json --session "$SESSION" 2>/dev/null
}

# read_state: sets STATUS and STATE to running, absent (a successful stopped
# status plus proven server process and socket absence), or the reason neither
# is proven.
read_state() {
  if ! STATUS=$(herdr_status); then
    STATE='herdr status failed'
    return 0
  fi
  case "$(printf '%s' "$STATUS" | jq -r '.server.running | if type == "boolean" then tostring else "unknown" end' 2>/dev/null)" in
    true) STATE=running ;;
    false)
      if printf '%s' "$STATUS" | python3 "$SCRIPT_DIR/backends/herdr-server-start.py" \
        --prove-absent "$SESSION" "$HERDR_BIN" >/dev/null 2>&1; then
        STATE=absent
      else
        STATE='status says stopped but server process and socket absence is unproven'
      fi
      ;;
    *) STATE='herdr status is unreadable' ;;
  esac
}

WAIT_REASON=
wait_note() { # <reason>
  [ "$1" = "$WAIT_REASON" ] || log "session $SESSION: $1; waiting and re-checking rather than starting a second server"
  WAIT_REASON=$1
}

start_server() {
  local verdict=
  exec 3< <(printf '%s' "$STATUS" | python3 "$SCRIPT_DIR/backends/herdr-server-start.py" \
    --hold-for-exec "$SESSION" "$HERDR_BIN" "$$")
  IFS= read -r verdict <&3 || verdict=
  exec 3<&-
  case "$verdict" in
    go)
      log "starting the herdr server for session $SESSION inside this launch agent (pid $$)"
      exec "$HERDR_BIN" server --session "$SESSION"
      ;;
    running) log "session $SESSION came up under the start lock; not starting a second server" ;;
    *) log "the start lock refused to start session $SESSION; re-checking" ;;
  esac
}

while :; do
  read_state
  case "$STATE" in
    running) break ;;
    absent)
      log "no server owns session $SESSION"
      start_server
      sleep 1
      continue
      ;;
  esac
  wait_note "$STATE"
  sleep 1
done

SOCKET=$(printf '%s' "$STATUS" | jq -r '.server.socket // empty' 2>/dev/null)
OWNER=$(fm_remote_herdr_socket_owner "$SOCKET"); OWNER_RC=$?
if [ "$OWNER_RC" -eq 2 ]; then
  log "session $SESSION is running but lsof does not resolve, so its server's birth cannot be proven"
  BIRTH=unknown
elif [ -z "$OWNER" ]; then
  log "session $SESSION is running but no herdr process could be proven to own ${SOCKET:-its socket}"
  BIRTH=unknown
else
  BIRTH=$(fm_remote_herdr_owner_birth "$OWNER")
fi

if fm_remote_herdr_birth_is_aqua "$BIRTH"; then
  log "session $SESSION is served by pid $OWNER born in the Aqua login session ($BIRTH); nothing to do"
  exit 0
fi

log "session $SESSION is served by ${OWNER:+pid }${OWNER:-an unproven process} born outside the Aqua login session ($BIRTH); its panes cannot reach the login keychain, taking the session over"
HERDR_SESSION="$SESSION" "$HERDR_BIN" server stop --session "$SESSION" >/dev/null 2>&1 \
  || log "herdr server stop for session $SESSION did not succeed; waiting for the socket anyway"
i=0
while [ "$i" -lt "$STOP_WAIT_TENTHS" ]; do
  read_state
  case "$STATE" in
    absent)
      log "session $SESSION released its socket after $i tenths of a second"
      start_server
      ;;
    running) ;;
    *) wait_note "$STATE" ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
log "the foreign server for session $SESSION did not release its socket within $STOP_WAIT_TENTHS tenths of a second; exiting 1 so launchd retries"
exit 1
