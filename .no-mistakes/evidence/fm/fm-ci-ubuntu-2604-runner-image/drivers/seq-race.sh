#!/usr/bin/env bash
# Live drive: 20 concurrent allocators per trial against real fm_remote_job_next_seq,
# plus the raw packaged-mkdir counterfactual on the same host.
set -u
ROOT=$1 TRIALS=${2:-25}
echo "host: $(. /etc/os-release 2>/dev/null; echo ${PRETTY_NAME:-$(uname -sr)}) mkdir=$(readlink -f "$(command -v mkdir)")"
raw_multi=0
for t in $(seq 1 "$TRIALS"); do
  d=$(mktemp -d); pids=()
  for i in $(seq 1 20); do ( (umask 077; mkdir "$d/claim") 2>/dev/null && echo ok ) > "$d/r$i" & pids+=($!); done
  wait "${pids[@]}"
  n=$(cat "$d"/r* | grep -c ok); [ "$n" -gt 1 ] && raw_multi=$((raw_multi+1))
  printf 'raw-mkdir trial %2d: %d successful owners\n' "$t" "$n"
  rm -rf "$d"
done
echo "raw-mkdir: trials with >1 owner: $raw_multi/$TRIALS"
bad=0
for t in $(seq 1 "$TRIALS"); do
  w=$(cd "$(mktemp -d)" && pwd -P)
  ( export FM_REMOTE_JOB_STATE_ROOT="$w/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
    . "$ROOT/bin/fm-remote-job-lib.sh"
    mkdir -p "$w/acct"; chmod 700 "$w/acct"
    fm_remote_job_prepare_state "$w/acct" || { echo "prepare failed: $FM_REMOTE_JOB_ERROR"; exit 1; }
    rm -f -- "$FM_REMOTE_JOB_STATE_ROOT/seq"
    pids=()
    for i in $(seq 1 20); do fm_remote_job_next_seq > "$w/seq-$i" & pids+=($!); done
    rc=0; for p in "${pids[@]}"; do wait "$p" || rc=1; done
    got=$(cat "$w"/seq-* | sort -n | tr '\n' ' ')
    exp=$(seq 1 20 | tr '\n' ' ')
    if [ "$rc" = 0 ] && [ "$got" = "$exp" ]; then echo "next_seq trial $t: unique 1..20"; else echo "next_seq trial $t: BAD rc=$rc got=$got"; exit 1; fi
  ) || bad=$((bad+1))
  rm -rf "$w"
done
echo "next_seq: bad trials: $bad/$TRIALS"
[ "$bad" = 0 ]
