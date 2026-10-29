#!/usr/bin/env bash
# fm-scratch-lib.sh - the single owner of per-command scratch entries in the shared temp dir.
#
#   fm_scratch_new <f|d> <prefix>
#       Prints the path of a fresh private file (f) or directory (d) named
#       ${TMPDIR:-/tmp}/<prefix>.scratch/<owner-pid>.XXXXXX. The owner is the
#       calling shell ($$, so a caller that captures the path in $(...) still
#       names the long-lived script). Entries of one prefix share a container
#       directory, so no scan of the shared temp dir ever has to read them.
#   fm_scratch_release <path>
#       Removes the entry and then its container when no other entry is left.
#       A command calls it from its EXIT, INT, TERM and HUP traps.
#   fm_scratch_reap <prefix>
#       Removes the entries of <prefix> whose owner pid names no process this
#       user can signal. KILL cannot run any trap, so the next fm_scratch_new
#       of the same prefix reaps what a killed owner left. A live owner is
#       never touched: its pid answers kill -0. A reused pid only delays the
#       removal. Only entries this user owns and that are not symlinks go.
#
# Sourced, never executed. The container name carries <prefix> verbatim, so a
# command keeps its historic prefix (fm-gh-rest, fm-timeout-status, ...).
# Regression coverage: tests/fm-scratch-leaks.test.sh runs every command that
# uses this library with its own empty TMPDIR. bin/fm-scratch-legacy-reap.sh
# removes the unowned entries commands made before this library existed.

fm_scratch_container() {  # <prefix>
  local base=${TMPDIR:-/tmp}
  printf '%s/%s.scratch\n' "${base%/}" "$1"
}

fm_scratch_reap() {  # <prefix>
  local container entry name pid
  container=$(fm_scratch_container "$1")
  for entry in "$container"/[0-9]*.??????; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ ! -L "$entry" ] && [ -O "$entry" ] || continue
    name=${entry##*/}
    pid=${name%%.*}
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    ! kill -0 "$pid" 2>/dev/null || continue
    rm -rf -- "$entry"
  done
  rmdir "$container" 2>/dev/null || true
}

fm_scratch_new() {  # <f|d> <prefix>
  local kind=$1 container path attempt=0
  container=$(fm_scratch_container "$2")
  [ ! -d "$container" ] || fm_scratch_reap "$2"
  # A concurrent release may remove the empty container between mkdir and
  # mktemp; the loop makes that race cost a retry rather than a failure.
  while [ "$attempt" -lt 3 ]; do
    attempt=$((attempt + 1))
    (umask 077; mkdir -p -- "$container") 2>/dev/null || continue
    if [ "$kind" = d ]; then
      path=$(umask 077; mktemp -d "$container/$$.XXXXXX" 2>/dev/null) || continue
    else
      path=$(umask 077; mktemp "$container/$$.XXXXXX" 2>/dev/null) || continue
    fi
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

fm_scratch_release() {  # <path>
  [ -n "${1:-}" ] || return 0
  rm -rf -- "$1"
  case "${1%/*}" in *.scratch) rmdir -- "${1%/*}" 2>/dev/null || true ;; esac
}
