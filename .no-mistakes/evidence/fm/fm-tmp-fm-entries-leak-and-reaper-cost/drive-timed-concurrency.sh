#!/usr/bin/env bash
# Drive fm_run_timed from many parallel shells on one private TMPDIR.
# Every call must run its command (no false 124) and the TMPDIR must end empty.
set -u
WT=$1; WORKERS=${2:-24}; CALLS=${3:-40}
T=$(mktemp -d "${TMPDIR:-/tmp}/nm-drive-timed.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir "$T/tmp" "$T/out"
for w in $(seq "$WORKERS"); do
  env TMPDIR="$T/tmp" bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    ok=0 bad=0
    for i in $(seq "$2"); do
      if out=$(fm_run_timed 20 echo ran); [ "$out" = ran ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "call $i rc/out=[$out]" >&2; fi
      fm_run_bash_timeout 20 "true" >/dev/null 2>&1 || bad=$((bad+1))
    done
    echo "$ok $bad" > "$3"
  ' _ "$WT" "$CALLS" "$T/out/$w" &
done
wait
ok=0 bad=0; for f in "$T"/out/*; do read -r a b < "$f"; ok=$((ok+a)); bad=$((bad+b)); done
echo "workers=$WORKERS calls/worker=$CALLS fm_run_timed ok=$ok failed=$bad (timeout bin: $(command -v timeout))"
echo "entries left in TMPDIR: $(find "$T/tmp" -mindepth 1 | wc -l | tr -d ' ')"; find "$T/tmp" -mindepth 1 | head
