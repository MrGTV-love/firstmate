#!/usr/bin/env bash
# pass-through to the real lsof; counts looks and records elapsed time and whether the target file was listed
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
out=$(/usr/sbin/lsof "$@" 2>/dev/null); rc=$?
e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
printf '%s\t%s\t%s\n' "$s" "$e" "$([ -n "$out" ] && echo hit || echo miss)" >> "$FM_LOOK_LOG"
printf '%s\n' "$out"; exit $rc
