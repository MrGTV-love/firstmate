#!/usr/bin/env bash
# shellcheck disable=SC2034 # parsed fields are output globals for sourcing callers.
# Parse the durable parent binding written into a seeded secondmate home, and
# walk it upward (fm_firstmate_root_home) to the top-most local home.
#
# The fm-secondmate-parent.v1 record contains exactly one schema and route.
# A local route contains exactly one absolute parent_home and no parent_host.
# A remote route contains no parent_home; current provisioning includes its SSH
# alias as diagnostic-only parent_host, while legacy-compatible manifests may
# omit that field.
# Unknown fields are reserved for forward-compatible additions.
# Duplicate schema or route fields, a malformed local binding, an unsupported
# route or schema, a NUL-bearing record, and a symlinked record fail closed.
# Writers publish this record before .fm-secondmate-home so that the identity
# marker remains the seed-completion point.

fm_secondmate_parent_record_parse() {
  local file=$1 line schema='' route='' parent_home='' parent_host=''
  local schema_count=0 route_count=0 parent_home_count=0 parent_host_count=0

  FM_SECONDMATE_PARENT_ROUTE=
  FM_SECONDMATE_PARENT_HOME=
  FM_SECONDMATE_PARENT_HOST=

  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  # bash's read drops NUL bytes, and different bash generations disagree on the
  # result (3.2 truncates the value at the NUL, 5.x splices the surrounding
  # bytes together), so a NUL-bearing parent_home can resolve to a home the
  # record's bytes never name contiguously. Reject the whole record as corrupt
  # before any field parsing instead of letting the interpreter pick a home.
  [ "$(wc -c < "$file")" -eq "$(LC_ALL=C tr -d '\0' < "$file" | wc -c)" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      schema=*)
        schema_count=$((schema_count + 1))
        schema=${line#schema=}
        ;;
      route=*)
        route_count=$((route_count + 1))
        route=${line#route=}
        ;;
      parent_home=*)
        parent_home_count=$((parent_home_count + 1))
        parent_home=${line#parent_home=}
        ;;
      parent_host=*)
        parent_host_count=$((parent_host_count + 1))
        parent_host=${line#parent_host=}
        ;;
    esac
  done < "$file"

  [ "$schema_count" -eq 1 ] || return 1
  [ "$route_count" -eq 1 ] || return 1
  [ "$schema" = fm-secondmate-parent.v1 ] || return 1
  case "$route" in
    local)
      [ "$parent_home_count" -eq 1 ] || return 1
      [ "$parent_host_count" -eq 0 ] || return 1
      case "$parent_home" in /*) ;; *) return 1 ;; esac
      FM_SECONDMATE_PARENT_HOME=$parent_home
      ;;
    remote)
      [ "$parent_home_count" -eq 0 ] || return 1
      ;;
    *) return 1 ;;
  esac

  FM_SECONDMATE_PARENT_ROUTE=$route
  FM_SECONDMATE_PARENT_HOST=$parent_host
}

# The top-most firstmate home reachable from this one on THIS machine, used as
# the single anchor every local home agrees on for machine-local shared state.
#
# A local parent binding is followed upward. A remote parent binding terminates
# the walk at the current home, which is the correct answer rather than an
# error: the parent lives on another machine, so its filesystem can neither hold
# nor be observed by a lock taken here, and a remote-seeded home is itself the
# top of the local tree that bin/fm-teardown.sh's collect_local_firstmate_states
# enumerates (that walk already skips remote registry entries for the same
# reason). Refusing a remote binding instead made every operation anchored here
# fail closed inside a remote secondmate home and its local descendants.
#
# Everything else still fails closed: an unreadable or malformed binding, an
# unreachable local parent, a cycle, and a chain deeper than the bound.
fm_firstmate_root_home() {
  local home=${1:-$FM_HOME} marker parent seen="|" depth=0
  home=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) || return 1
  while [ -e "$home/.fm-secondmate-parent" ] || [ -L "$home/.fm-secondmate-parent" ]; do
    marker="$home/.fm-secondmate-parent"
    fm_secondmate_parent_record_parse "$marker" || return 1
    case "$FM_SECONDMATE_PARENT_ROUTE" in
      local) ;;
      remote) break ;;
      *) return 1 ;;
    esac
    parent=$(CDPATH='' cd -- "$FM_SECONDMATE_PARENT_HOME" 2>/dev/null && pwd -P) || return 1
    case "$seen" in *"|$parent|"*) return 1 ;; esac
    seen="$seen$home|"
    home=$parent
    depth=$((depth + 1))
    [ "$depth" -le 64 ] || return 1
  done
  printf '%s\n' "$home"
}
