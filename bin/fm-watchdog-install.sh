#!/usr/bin/env bash
# fm-watchdog-install.sh - install, inspect, or remove the macOS launchd user
# agent that runs bin/fm-watchdog-check.sh for one Firstmate home.
# docs/watchdog.md owns the operator contract.
#
# Usage: fm-watchdog-install.sh install [--interval <seconds>] [--print]
#        fm-watchdog-install.sh uninstall
#        fm-watchdog-install.sh status
#
# install renders docs/examples/fm-watchdog.plist for this checkout and home
# (FM_HOME, default the checkout), writes it to ~/Library/LaunchAgents, and
# loads it with launchctl bootstrap into the gui/<uid> domain, so it survives
# session death and reboot. The label is home-scoped
# (com.firstmate.watchdog.<8-digit checksum of FM_HOME>), so two homes never
# share an agent. Re-running install replaces the agent in place. --print
# renders the plist to stdout and changes nothing. The default interval is 120
# seconds (FM_WATCHDOG_INTERVAL_SECS); the lowest accepted value is 30.
# uninstall boots the agent out and deletes its plist; it never touches state.
# status prints whether the plist exists and whether launchd has it loaded.
#
# Installing is the captain's decision: nothing in this repository runs this
# command. FM_WATCHDOG_AGENT_DIR and FM_WATCHDOG_LAUNCHCTL replace the agent
# directory and the launchctl binary, honored only when FM_TEST_SEAM=1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_ROOT" in /*) ;; *) FM_ROOT="$PWD/$FM_ROOT" ;; esac
case "$FM_HOME" in /*) ;; *) FM_HOME="$PWD/$FM_HOME" ;; esac
TEMPLATE="$FM_ROOT/docs/examples/fm-watchdog.plist"
AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCHCTL=launchctl
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  AGENT_DIR=${FM_WATCHDOG_AGENT_DIR:-$AGENT_DIR}
  LAUNCHCTL=${FM_WATCHDOG_LAUNCHCTL:-$LAUNCHCTL}
fi

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

home_sum=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
LABEL="com.firstmate.watchdog.$home_sum"
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

cmd_install() {
  local interval=${FM_WATCHDOG_INTERVAL_SECS:-120} print_only=0 tmp
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
  [ "${FM_TEST_SEAM:-}" = 1 ] || [ "$(uname)" = Darwin ] || die "launchd agents exist only on macOS"
  [ -x "$SCRIPT_DIR/fm-watchdog-check.sh" ] || die "missing $SCRIPT_DIR/fm-watchdog-check.sh"
  [ -d "$FM_HOME/state" ] || die "no state directory at $FM_HOME/state"
  mkdir -p "$AGENT_DIR" || die "cannot create $AGENT_DIR"
  tmp="$PLIST.tmp.$$"
  render "$interval" > "$tmp" || { rm -f "$tmp"; die "could not render the plist"; }
  if [ "$(uname)" = Darwin ] && command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "the rendered plist failed plutil -lint"
  fi
  loaded && "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
  mv -f "$tmp" "$PLIST" || die "cannot write $PLIST"
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap failed for $PLIST"
  printf 'installed %s (every %ss) for %s\n' "$LABEL" "$interval" "$FM_HOME"
}

cmd_uninstall() {
  loaded && "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
  if loaded; then
    die "launchctl still has $LABEL loaded"
  fi
  rm -f "$PLIST"
  printf 'removed %s\n' "$LABEL"
}

cmd_status() {
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
