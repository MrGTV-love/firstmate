#!/bin/bash
# capped-run.sh <label> <headroom> <seconds> <cmd...>
# Runs cmd in its own process group under a hard per-user process cap
# (current user process count + headroom) and a KILL timeout. Samples the
# group every 0.1s for pyenv-prefix/pyenv-which processes, then kills the whole
# group and proves nothing from it is left running.
label=$1 headroom=$2 secs=$3; shift 3
uid=$(id -u)
before=$(ps -U "$uid" -o pid= | wc -l | tr -d ' ')
cap=$((before + headroom))
out="$label.stdout"; err="$label.stderr"
start=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
perl -e 'setpgrp(0,0); exec @ARGV or die' -- /bin/bash -c 'ulimit -u "$1"; shift; exec timeout -s KILL "$@"' _ "$cap" "$secs" "$@" >"$out" 2>"$err" &
pg=$!
maxpy=0 maxgrp=0
while kill -0 "$pg" 2>/dev/null; do
  snap=$(ps -A -o pgid=,command= | awk -v g="$pg" '$1==g')
  n=$(printf '%s\n' "$snap" | grep -c 'pyenv-\(prefix\|which\)')
  m=$(printf '%s\n' "$snap" | grep -c .)
  [ "$n" -gt "$maxpy" ] && maxpy=$n
  [ "$m" -gt "$maxgrp" ] && maxgrp=$m
  sleep 0.1
done
wait "$pg"; code=$?
end=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
kill -KILL -- "-$pg" 2>/dev/null
sleep 1
left=$(ps -A -o pgid= | awk -v g="$pg" '$1==g' | wc -l | tr -d ' ')
after=$(ps -U "$uid" -o pid= | wc -l | tr -d ' ')
forkfail=$(grep -ci 'fork\|resource temporarily unavailable' "$err")
{
  echo "== $label"
  echo "command: $*"
  echo "user procs before=$before cap(ulimit -u)=$cap timeout=${secs}s"
  echo "exit=$code elapsed=$(echo "$end - $start" | bc)s"
  echo "peak pyenv-prefix/pyenv-which procs in group=$maxpy peak group size=$maxgrp"
  echo "fork-failure lines in stderr=$forkfail"
  echo "group procs left after teardown=$left user procs after=$after"
  echo "stdout (first 3 lines):"; head -3 "$out" | sed 's/^/  /'
  echo "stderr (first 3 lines, $(wc -l <"$err" | tr -d ' ') total):"; head -3 "$err" | cut -c1-200 | sed 's/^/  /'
}
