#!/bin/bash
# Time the real bin/fm-fleet-snapshot.sh on a 200,002-line status log in a
# disposable lab FM_HOME, with and without an explicit pr= in the task record.
# Usage: drive-snapshot-200k.sh <repo-root>
set -u
cd "$1"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
trap 'bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME"' EXIT
S=$FM_HOME/state
printf 'kind=ship\nremote_host=example.invalid\n' > "$S/large.meta"
{ printf 'working: opened https://github.com/example/repo/pull/14\n'
  for ((i=0;i<200000;i++)); do printf 'working: routine progress\n'; done
  printf 'done: https://github.com/example/repo/pull/15\n'; } > "$S/large.status"
echo "status log lines: $(wc -l < "$S/large.status")"
( . bin/fm-classify-lib.sh; status_open_decisions_incremental "$S/large.status" >/dev/null ) &&
  echo "open-decision fold checkpointed (as production drains do)"
now() { perl -MTime::HiRes=time -e 'printf "%.2f",time'; }
run() {
  local t0 t1
  t0=$(now)
  FM_HOME="$FM_HOME" /bin/bash bin/fm-fleet-snapshot.sh --json |
    jq -c '.tasks[]|select(.id=="large")|{id,pr:.pr.url,source:.pr.source}'
  t1=$(now)
  echo "  wall: $(echo "$t1 - $t0" | bc)s"
}
echo "## with pr= in record (baseline, no log search)"
printf 'pr=https://github.com/example/repo/pull/16\n' >> "$S/large.meta"; run; run
echo "## without pr= (log search)"
printf 'kind=ship\nremote_host=example.invalid\n' > "$S/large.meta"; run; run
echo "## host load: $(uptime | sed 's/.*load/load/')"
