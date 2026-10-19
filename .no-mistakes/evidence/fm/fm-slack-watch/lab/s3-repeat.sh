#!/usr/bin/env bash
# Flake hunt: S3.6 repeated, with every poll's output, exit code and elapsed seconds recorded.
set -uo pipefail
. "$(dirname "$0")/lab.sh"
lab_start || exit 1
trap lab_stop EXIT
for i in 1 2 3 4 5 6; do
  new_home duplicate
  mirror >/dev/null; T=$(thread_ts dup-a)
  reply "$T" "1" "user=$OWNER"
  for p in 1 2 3; do
    s=$SECONDS; o=$(poll 2>&1); rc=$?; e=$((SECONDS-s))
    echo "iter $i poll$p rc=$rc elapsed=${e}s out=[$o] bots=$(bot_count "$T") load=$(uptime | sed 's/.*load averages*: //')"
  done
  echo "iter $i state=$(is_open dup-a) pending=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pending"])' "$FM_STATE_OVERRIDE/slack-watch/state.json")"
done
