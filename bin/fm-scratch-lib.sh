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
#       removal. Only entries this user owns and that are not symlinks go, and
#       only from a container that is a directory this user owns, never a
#       symlink. When another user holds the container path, fm_scratch_new
#       makes <prefix>.XXXXXX directly in the temp dir instead.
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

fm_scratch_owned() {  # <container>: a real directory of this user, not a symlink
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
}

fm_scratch_reap() {  # <prefix>
  local container entry name pid
  container=$(fm_scratch_container "$1")
  fm_scratch_owned "$container" || return 0
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
  local kind=$1 container path dir='' base=${TMPDIR:-/tmp}
  [ "$kind" != d ] || dir=1
  container=$(fm_scratch_container "$2")
  fm_scratch_reap "$2"
  # A concurrent release removes the container once it is empty, which can fall
  # between mkdir and mktemp; only a container that vanished is worth a retry.
  while :; do
    if ! (umask 077; mkdir -p -- "$container") 2>/dev/null && [ ! -e "$container" ] && [ ! -L "$container" ]; then
      return 1
    fi
    if [ -L "$container" ] || { [ -e "$container" ] && ! fm_scratch_owned "$container"; }; then
      (umask 077; mktemp ${dir:+"-d"} "${base%/}/$2.XXXXXX")
      return
    fi
    if path=$(umask 077; mktemp ${dir:+"-d"} "$container/$$.XXXXXX" 2>/dev/null); then
      printf '%s\n' "$path"
      return 0
    fi
    [ ! -d "$container" ] || return 1
  done
}

fm_scratch_release() {  # <path>
  [ -n "${1:-}" ] || return 0
  rm -rf -- "$1"
  case "${1%/*}" in *.scratch) rmdir -- "${1%/*}" 2>/dev/null || true ;; esac
}
