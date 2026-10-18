#!/usr/bin/env bash
# Read-only passthrough to the REAL no-mistakes CLI for one stored run. The
# repos in this lab are not registered with no-mistakes (and must not be), so the
# bare `axi` overview and bare `axi status` are answered from the real
# `axi status --run <id>` record. SHIM_SED optionally edits that real record
# (the adversarial cases); SHIM_STRIP_OUTCOME drops the outcome/error lines;
# SHIM_NO_TABLE=1 makes bare `axi` answer with the bare status (no runs table).
REAL=/Users/charlesabrooker/.local/bin/no-mistakes
read_run() {
  local out
  out=$("$REAL" axi status --run "$SHIM_RUN_ID") || return 1
  [ -z "${SHIM_SED:-}" ] || out=$(printf '%s\n' "$out" | sed -E "$SHIM_SED")
  [ "${SHIM_STRIP_OUTCOME:-0}" != 1 ] || out=$(printf '%s\n' "$out" | sed '/^outcome:/d;/^error:/d')
  printf '%s\n' "$out"
}
case "${1:-}" in
  axi)
    shift
    if [ "$#" = 0 ]; then
      out=$(read_run) || exit 1
      if [ "${SHIM_NO_TABLE:-0}" = 1 ]; then printf '%s\n' "$out"; exit 0; fi
      f() { printf '%s\n' "$out" | sed -n "s/^  $1: //p" | head -1; }
      printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  %s,%s,%s,%s,%s\n' \
        "$(f id)" "$(f branch)" "$(f status)" "$(f head)" "$(f pr)"
    elif [ "${1:-}" = status ]; then
      read_run
    else
      exec "$REAL" axi "$@"
    fi ;;
  *) exec "$REAL" "$@" ;;
esac
