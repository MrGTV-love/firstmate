#!/usr/bin/env bash
# fm-model-picker-daily-install.sh - install, inspect, or remove the two macOS launchd user
# agents that run bin/fm-model-picker-daily.sh for one Firstmate home.
# docs/configuration.md "Daily collection" owns the operator contract.
#
# Usage: fm-model-picker-daily-install.sh install [--print [--agent run|check]]
#        fm-model-picker-daily-install.sh uninstall
#        fm-model-picker-daily-install.sh status
#
# The run agent runs `fm-model-picker-daily.sh run` every 86400 seconds and at load, so it also
# runs at the next login after a reboot; its first run starts when install bootstraps it.
# The check agent runs `fm-model-picker-daily.sh check` every 3600 seconds and not at load, so
# installing does not raise a stale-snapshot wake before the first collection has had a chance
# to finish. It is its own job so that a hung collection, which launchd never starts a second
# instance of, is still noticed. Both render docs/examples/fm-model-picker-daily.plist into
# ~/Library/LaunchAgents and bootstrap gui/<uid>.
# FM_HOME defaults to FM_ROOT (the checkout unless overridden). Relative FM_HOME and
# FM_ROOT_OVERRIDE are resolved against the caller's working directory; absolute spellings
# are preserved. The labels are com.firstmate.model-picker-daily.{run,check}.<decimal cksum of
# resolved FM_HOME>. Reinstall boots each loaded agent out and replaces it, so there are only
# ever two. --print renders one plist (--agent picks it, run by default) and changes nothing.
# FM_MODEL_PICKER_DATA and FM_DATA_OVERRIDE, when set where install runs, are written into both
# agents' environment, because the collector resolves its data root from them and launchd gives
# an agent no other environment.
# uninstall boots out both agents and deletes their plists without touching state or data.
# status reports, for each agent, whether the plist exists and launchd has it loaded.
#
# Installing is the captain's decision: nothing in this repository runs this command.
# FM_MODEL_PICKER_DAILY_AGENT_DIR and FM_MODEL_PICKER_DAILY_LAUNCHCTL replace the agent
# directory and the launchctl binary, honored only when FM_TEST_SEAM=1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_ROOT" in /*) ;; *) FM_ROOT="$PWD/$FM_ROOT" ;; esac
case "$FM_HOME" in /*) ;; *) FM_HOME="$PWD/$FM_HOME" ;; esac
TEMPLATE="$FM_ROOT/docs/examples/fm-model-picker-daily.plist"
AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCHCTL=launchctl
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  AGENT_DIR=${FM_MODEL_PICKER_DAILY_AGENT_DIR:-$AGENT_DIR}
  LAUNCHCTL=${FM_MODEL_PICKER_DAILY_LAUNCHCTL:-$LAUNCHCTL}
fi

usage() { sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

home_sum=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
DOMAIN="gui/$(id -u)"
AGENTS="run check"

label_of() { printf 'com.firstmate.model-picker-daily.%s.%s\n' "$1" "$home_sum"; }
plist_of() { printf '%s/%s.plist\n' "$AGENT_DIR" "$(label_of "$1")"; }
interval_of() { case "$1" in run) echo 86400 ;; check) echo 3600 ;; esac; }
at_load_of() { case "$1" in run) echo true ;; check) echo false ;; esac; }

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

extra_env() {  # the data-root variables set where install runs, as plist lines
  local name value
  for name in FM_MODEL_PICKER_DATA FM_DATA_OVERRIDE; do
    value=${!name:-}
    [ -z "$value" ] || printf '    <key>%s</key>\n    <string>%s</string>\n' "$name" "$(xml_escape "$value")"
  done
}

render() {  # <agent>
  local agent=$1 root home path extra
  [ -f "$TEMPLATE" ] || die "missing template $TEMPLATE"
  root=$(xml_escape "$FM_ROOT")
  home=$(xml_escape "$FM_HOME")
  path=$(xml_escape "${PATH:-/usr/bin:/bin}")
  extra=$(extra_env)
  sed -e "s|@LABEL@|$(label_of "$agent")|g" \
    -e "s|@VERB@|$agent|g" \
    -e "s|@INTERVAL@|$(interval_of "$agent")|g" \
    -e "s|@RUN_AT_LOAD@|$(at_load_of "$agent")|g" \
    -e "s|@FM_ROOT@|$(printf '%s' "$root" | sed 's/[|&\\]/\\&/g')|g" \
    -e "s|@FM_HOME@|$(printf '%s' "$home" | sed 's/[|&\\]/\\&/g')|g" \
    -e "s|@PATH@|$(printf '%s' "$path" | sed 's/[|&\\]/\\&/g')|g" \
    "$TEMPLATE" | EXTRA="$extra" awk '/@EXTRA_ENV@/ { if (ENVIRON["EXTRA"] != "") print ENVIRON["EXTRA"]; next } { print }'
}

loaded() { "$LAUNCHCTL" print "$DOMAIN/$(label_of "$1")" >/dev/null 2>&1; }

install_one() {  # <agent>
  local agent=$1 plist tmp
  plist=$(plist_of "$agent")
  tmp="$plist.tmp.$$"
  render "$agent" > "$tmp" || { rm -f "$tmp"; die "could not render the $agent plist"; }
  if [ "$(uname)" = Darwin ] && command -v plutil >/dev/null 2>&1 && ! plutil -lint "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "the rendered $agent plist failed plutil -lint"
  fi
  loaded "$agent" && "$LAUNCHCTL" bootout "$DOMAIN/$(label_of "$agent")" >/dev/null 2>&1
  mv -f "$tmp" "$plist" || die "cannot write $plist"
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$plist" || die "launchctl bootstrap failed for $plist"
}

cmd_install() {
  local print_only=0 only=run agent
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --print) print_only=1; shift ;;
      --agent) [ "$#" -gt 1 ] || die "--agent needs run or check"; only=$2; shift 2 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  case "$only" in run|check) ;; *) die "--agent takes run or check" ;; esac
  if [ "$print_only" -eq 1 ]; then
    render "$only"
    return 0
  fi
  [ "${FM_TEST_SEAM:-}" = 1 ] || [ "$(uname)" = Darwin ] || die "launchd agents exist only on macOS"
  [ -x "$SCRIPT_DIR/fm-model-picker-daily.sh" ] || die "missing $SCRIPT_DIR/fm-model-picker-daily.sh"
  [ -d "$FM_HOME/state" ] || die "no state directory at $FM_HOME/state"
  mkdir -p "$AGENT_DIR" || die "cannot create $AGENT_DIR"
  for agent in $AGENTS; do
    install_one "$agent"
    printf 'installed %s (every %ss%s) for %s\n' "$(label_of "$agent")" "$(interval_of "$agent")" \
      "$([ "$(at_load_of "$agent")" = true ] && printf ', and at login')" "$FM_HOME"
  done
}

cmd_uninstall() {
  local agent
  for agent in $AGENTS; do
    loaded "$agent" && "$LAUNCHCTL" bootout "$DOMAIN/$(label_of "$agent")" >/dev/null 2>&1
    if loaded "$agent"; then
      die "launchctl still has $(label_of "$agent") loaded"
    fi
    rm -f "$(plist_of "$agent")"
    printf 'removed %s\n' "$(label_of "$agent")"
  done
}

cmd_status() {
  local agent plist state
  for agent in $AGENTS; do
    plist=absent state=not-loaded
    [ -f "$(plist_of "$agent")" ] && plist=present
    loaded "$agent" && state=loaded
    printf '%s plist=%s launchd=%s\n' "$(label_of "$agent")" "$plist" "$state"
  done
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  --help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
