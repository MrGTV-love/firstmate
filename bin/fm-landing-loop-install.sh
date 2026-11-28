#!/usr/bin/env bash
# fm-landing-loop-install.sh - install, inspect, or remove the macOS launchd user
# agent that runs bin/fm-landing-loop.py step for one Firstmate home.
#
# Usage: fm-landing-loop-install.sh install [--interval <seconds>] [--print]
#        fm-landing-loop-install.sh uninstall
#        fm-landing-loop-install.sh status
#
# install renders docs/examples/fm-landing-loop.plist into ~/Library/LaunchAgents
# and bootstraps gui/<uid>. It runs independently of Main's watcher and survives
# session death and reboot login. FM_HOME defaults to FM_ROOT unless overridden.
# Relative FM_HOME and FM_ROOT_OVERRIDE are resolved against the caller's working
# directory before rendering and label generation; absolute spellings are preserved.
# The label is com.firstmate.landing-loop.<decimal cksum of resolved FM_HOME>.
# Reinstall replaces the agent. --print renders the plist and changes nothing.
# The interval defaults to 120 seconds (FM_LANDING_LOOP_INTERVAL_SECS), minimum 30.
# uninstall boots out the agent and deletes its plist without touching state.
# status reports whether the plist exists and launchd has the agent loaded.
#
# Installing is the captain's decision: nothing in this repository runs this
# command automatically. FM_LANDING_LOOP_AGENT_DIR and FM_LANDING_LOOP_LAUNCHCTL
# replace the agent directory and launchctl binary, honored only when FM_TEST_SEAM=1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_ROOT" in /*) ;; *) FM_ROOT="$PWD/$FM_ROOT" ;; esac
case "$FM_HOME" in /*) ;; *) FM_HOME="$PWD/$FM_HOME" ;; esac
TEMPLATE="$FM_ROOT/docs/examples/fm-landing-loop.plist"
AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCHCTL=launchctl
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  AGENT_DIR=${FM_LANDING_LOOP_AGENT_DIR:-}
  LAUNCHCTL=${FM_LANDING_LOOP_LAUNCHCTL:-}
fi

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }
require_test_seam_overrides() {
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    [ -n "$AGENT_DIR" ] && [ -n "$LAUNCHCTL" ] \
      || die "FM_TEST_SEAM=1 requires both FM_LANDING_LOOP_AGENT_DIR and FM_LANDING_LOOP_LAUNCHCTL"
  fi
}

home_sum=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
LABEL="com.firstmate.landing-loop.$home_sum"
PLIST="$AGENT_DIR/$LABEL.plist"
DOMAIN="gui/$(id -u)"

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

render() {  # <interval>
  local interval=$1 root home path
  [ -f "$TEMPLATE" ] || die "missing template $TEMPLATE"
  root=$(xml_escape "$FM_ROOT")
  home=$(xml_escape "$FM_HOME")
  path=$(xml_escape "${PATH:-/usr/bin:/bin}")
  sed -e "s|@LABEL@|$LABEL|g" \
    -e "s|@INTERVAL@|$interval|g" \
    -e "s|@FM_ROOT@|$(printf '%s' "$root" | sed 's/[|&\\]/\\&/g')|g" \
    -e "s|@FM_HOME@|$(printf '%s' "$home" | sed 's/[|&\\]/\\&/g')|g" \
    -e "s|@PATH@|$(printf '%s' "$path" | sed 's/[|&\\]/\\&/g')|g" \
    "$TEMPLATE"
}

loaded() { "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

bootout_wait() {
  local tries=0
  loaded || return 0
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
  while loaded; do
    [ "$tries" -lt 20 ] || return 1
    sleep 0.25
    tries=$((tries + 1))
  done
}

cmd_install() {
  local interval=${FM_LANDING_LOOP_INTERVAL_SECS:-120} print_only=0 tmp
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) [ "$#" -gt 1 ] || die "--interval needs a value"; interval=$2; shift 2 ;;
      --print) print_only=1; shift ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*) die "interval must be whole seconds" ;; esac
  [ "$interval" -ge 30 ] || die "interval must be at least 30 seconds"
  if [ "$print_only" -eq 1 ]; then
    render "$interval"
    return 0
  fi
  require_test_seam_overrides
  [ "${FM_TEST_SEAM:-}" = 1 ] || [ "$(uname)" = Darwin ] || die "launchd agents exist only on macOS"
  [ -x "$SCRIPT_DIR/fm-landing-loop.py" ] || die "missing $SCRIPT_DIR/fm-landing-loop.py"
  [ -d "$FM_HOME/state" ] || die "no state directory at $FM_HOME/state"
  mkdir -p "$AGENT_DIR" || die "cannot create $AGENT_DIR"
  tmp="$PLIST.tmp.$$"
  render "$interval" > "$tmp" || { rm -f "$tmp"; die "could not render the plist"; }
  if [ "$(uname)" = Darwin ] && command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "the rendered plist failed plutil -lint"
  fi
  bootout_wait || { rm -f "$tmp"; die "launchctl still has $LABEL loaded"; }
  mv -f "$tmp" "$PLIST" || die "cannot write $PLIST"
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed for $PLIST"
  printf 'installed %s (every %ss) for %s\n' "$LABEL" "$interval" "$FM_HOME"
}

cmd_uninstall() {
  require_test_seam_overrides
  bootout_wait || die "launchctl still has $LABEL loaded"
  rm -f "$PLIST"
  printf 'removed %s\n' "$LABEL"
}

cmd_status() {
  require_test_seam_overrides
  local plist=absent state=not-loaded
  [ -f "$PLIST" ] && plist=present
  loaded && state=loaded
  printf '%s plist=%s launchd=%s\n' "$LABEL" "$plist" "$state"
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
