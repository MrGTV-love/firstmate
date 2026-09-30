#!/usr/bin/env bash
# Normalize the upstream compact-adviser emergency switch once at a launch
# boundary. Truthy values ignore case and surrounding whitespace; the returned
# 0/1 is safe to carry in a remote command payload without forwarding the
# invoking environment. Both fresh and replacement launches use this owner.
fm_compact_adviser_force_off() {
  local value=${COMPACT_ADVISER_DISABLE:-}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
  1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss] | [Oo][Nn]) printf '1\n' ;;
  *) printf '0\n' ;;
  esac
}
