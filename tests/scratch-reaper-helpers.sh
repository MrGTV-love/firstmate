#!/usr/bin/env bash
# tests/scratch-reaper-helpers.sh - the ONE way a test runs bin/fm-scratch-reaper.sh.
#
# The reaper deletes directories, and with no config it defaults to the real /private/tmp and
# ~/tmp. A smoke chain once ran --apply through those defaults, so no test may call the script
# directly: every run goes through sr_run, which builds the whole environment itself and
# refuses to start unless a private root, a private config and a private archive folder all
# exist inside the test world. sr_run never runs a script when any check fails, and the guard
# is the same for dry runs, --apply and --scheduled, so a typo cannot reach a real root.
# The one exception is --no-config: it has no config, so no root check runs and the script uses
# its built-in default roots, which are the real temp folders.
#
# Sourced, never executed. The caller sources tests/lib.sh first.

# sr_world_new <tmp-root> <name>: build <tmp-root>/<name> and print its path.
sr_world_new() {
  local world=$1/$2
  mkdir -p "$world/home" "$world/tmp" "$world/fm/state" "$world/fm/data" "$world/fm/config" \
    "$world/root" "$world/fakebin" || return 1
  ( cd -P -- "$world" && pwd -P )
}

# sr_inside <world> <path>: succeed only when the physical path lies inside the world.
sr_inside() {
  local world=$1 path=$2 real
  [ -n "$path" ] || return 1
  real=$(cd -P -- "$(dirname -- "$path")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename -- "$path")") || return 1
  case "$real" in "$world"/*) return 0 ;; esac
  return 1
}

# sr_guard <world> <args...>: the refusal. Prints why and fails when the run is not private.
sr_guard() {
  local world=$1 cfg root line a real pdir
  shift
  case "$world" in /|''|/tmp|/private/tmp|/var/tmp) echo "sr_run: the world '$world' is a real temp folder" >&2; return 1 ;; esac
  cfg=$world/fm/config/scratch-reaper
  if [ "${SR_NO_CONFIG_OK:-0}" = 1 ]; then
    { [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; } || { echo "sr_run: a no-config run found a config at $cfg" >&2; return 1; }
  else
    [ -f "$cfg" ] && [ ! -L "$cfg" ] || { echo "sr_run: no private config at $cfg" >&2; return 1; }
    sr_inside "$world" "$cfg" || { echo "sr_run: config is outside the test world" >&2; return 1; }
  fi
  if ! { [ -d "$world/fm/data" ] && sr_inside "$world" "$world/fm/data/scratch-reaper-archive"; }; then
    echo "sr_run: no private archive folder" >&2; return 1
  fi
  [ "${SR_NO_CONFIG_OK:-0}" != 1 ] || return 0
  grep -qE '^[^#[:space:]]' "$cfg" || { echo "sr_run: the private config names no root" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    read -r a _ <<< "$line"
    [ -n "$a" ] || continue
    [ "$a" != age_hours ] || continue
    root=$a
    case "$root" in /*) ;; *) echo "sr_run: root '$root' is not absolute" >&2; return 1 ;; esac
    case "$root" in /|/tmp|/private/tmp|/var/tmp|/var/folders|"${HOME:-/nonexistent}"|"${HOME:-/nonexistent}/tmp") echo "sr_run: root '$root' is a real root" >&2; return 1 ;; esac
    # Resolve the WHOLE root physically: a symlink root, or a symlink anywhere in its path, is judged
    # where it ends up, never by its own name. A missing root is refused too, unless --missing-root
    # admits one whose parent lies inside the world.
    if [ ! -e "$root" ] && [ ! -L "$root" ] && [ "${SR_MISSING_ROOT_OK:-0}" = 1 ]; then
      pdir=$(cd -P -- "$(dirname -- "$root")" 2>/dev/null && pwd -P) || pdir=
      case "$pdir/" in "$world"/*) continue ;; esac
      echo "sr_run: missing root '$root' lies outside the test world" >&2; return 1
    fi
    [ -d "$root" ] || { echo "sr_run: root '$root' is not an existing directory" >&2; return 1; }
    if [ -L "$root" ] && [ "${SR_SYMLINK_ROOT_OK:-0}" != 1 ]; then echo "sr_run: root '$root' is a symlink" >&2; return 1; fi
    real=$(cd -P -- "$root" 2>/dev/null && pwd -P) || { echo "sr_run: cannot resolve root '$root'" >&2; return 1; }
    case "$real" in "$world"/*) ;; *) echo "sr_run: root '$root' resolves to '$real', outside the test world" >&2; return 1 ;; esac
  done < "$cfg"
  return 0
}

# sr_run <world> [--script <path>] [--fakebin] [--inworld-symlink-root] [--missing-root] [--no-config] -- <reaper args>:
# run the reaper in the private world. --inworld-symlink-root lets a config root be a symlink, and only when its whole
# physical path still lies inside the world (a test of the reaper's own symlink-root refusal). --missing-root lets a
# config root be missing when its parent lies inside the world. --no-config runs with no config file, so the script
# under test must have its built-in default roots rewritten into the world.
# Output and status are the reaper's. Extra environment goes in SR_EXTRA_ENV (name=value words).
sr_run() {
  # shellcheck disable=SC2153  # ROOT is exported by tests/lib.sh
  local world=$1 script="$ROOT/bin/fm-scratch-reaper.sh" use_fakebin=0 link_ok=0 miss_ok=0 noconf=0 path
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --script) script=$2; shift 2 ;;
      --fakebin) use_fakebin=1; shift ;;
      --inworld-symlink-root) link_ok=1; shift ;;
      --missing-root) miss_ok=1; shift ;;
      --no-config) noconf=1; shift ;;
      --) shift; break ;;
      *) echo "sr_run: unknown option $1" >&2; return 1 ;;
    esac
  done
  SR_SYMLINK_ROOT_OK=$link_ok SR_MISSING_ROOT_OK=$miss_ok SR_NO_CONFIG_OK=$noconf sr_guard "$world" "$@" || return 99
  path=$PATH
  [ "$use_fakebin" -eq 0 ] || path="$world/fakebin:$PATH"
  # shellcheck disable=SC2086
  env -i PATH="$path" HOME="$world/home" TMPDIR="$world/tmp" \
    FM_HOME="$world/fm" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$world/fm/state" \
    FM_CONFIG_OVERRIDE="$world/fm/config" FM_DATA_OVERRIDE="$world/fm/data" \
    FM_TEST_SEAM=1 ${SR_EXTRA_ENV:-} \
    bash "$script" "$@"
}

# sr_age_tree <dir>: make every entry in the tree (the tree itself too) old.
sr_age_tree() {
  find "$1" -exec touch -h -t 202501010000 {} + 2>/dev/null || return 1
}

sr_sha() {  # <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
