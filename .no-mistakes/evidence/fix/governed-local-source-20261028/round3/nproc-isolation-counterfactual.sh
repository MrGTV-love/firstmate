#!/usr/bin/env bash
# Old vs corrected memory fixture: the RLIMIT_NPROC the nested memory payload sees.
# Invariant: the payload keeps the inherited soft limit (no user-count + 1500 cap).
set -u
ROOT=$1 WRAP="$1/bin/fm-proc-budget.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-nproc-cf.XXXXXX")
mkdir -p "$T/stub-ps"
printf '%s\n' '#!/bin/sh' 'i=0' 'while [ "$i" -lt "${FM_TEST_PS_COUNT:-0}" ]; do echo "$i"; i=$((i + 1)); done' 'exit "${FM_TEST_PS_STATUS:-0}"' >"$T/stub-ps/ps"
chmod +x "$T/stub-ps/ps"
soft=$(ulimit -S -u) hard=$(ulimit -H -u)
echo "start=$(date -u +%FT%TZ) inherited_soft=$soft inherited_hard=$hard user_procs=$(ps -U "$(id -u)" -o pid= | wc -l | tr -d ' ')"
probe='import resource; print("%d %d" % resource.getrlimit(resource.RLIMIT_NPROC))'
old=$("$WRAP" --memory-kib 2097152 -- "$WRAP" --memory-kib 131072 -- python3 -c "$probe"); orc=$?
new=$(PATH="$T/stub-ps:$PATH" FM_TEST_PS_COUNT=$soft "$WRAP" --memory-kib 2097152 -- "$WRAP" --memory-kib 131072 -- python3 -c "$probe"); nrc=$?
for arm in old new; do
  v=${!arm}; rc=$([ $arm = old ] && echo $orc || echo $nrc)
  [ "$v" = "$soft $soft" ] && verdict=holds || verdict=VIOLATED
  echo "arm=$arm exit=$rc payload_nproc_soft_hard='$v' invariant=$verdict"
done
rm -rf "$T"
