#!/usr/bin/env bash
# drive.sh <scratch> <evidence-prefix> <rss-kib-or-empty> <files...>
S=$1 P=$2 BOUND=$3; shift 3
cd "$S" || exit 1
ME=$$
mine() {  # pid rss comm of shellcheck processes descended from this driver
  ps -A -o pid=,ppid=,rss=,comm= | awk -v me="$ME" '{pp[$1]=$2; rss[$1]=$3; c[$1]=$4}
    END { for (p in c) if (c[p] ~ /shellcheck$/) { q=p; while (q > 1) { if (q == me) { print p, rss[p]; break } q=pp[q] } } }'
}
mon() {
  peak=0
  while :; do
    while read -r pid rss; do
      [ "$rss" -gt "$peak" ] && peak=$rss
      if [ "$rss" -gt "${SAFETY_KIB:-6291456}" ]; then echo "SAFETY KILL $pid $rss" >> "$P.monitor"; kill -KILL "$pid"; fi
    done < <(mine)
    echo "$peak" > "$P.peak"
    sleep 0.5
  done
}
mon & MON=$!
start=$SECONDS
rc=0
env ${BOUND:+FM_LINT_ROOT_RSS_KIB="$BOUND"} FM_LINT_JOBS=1 bin/fm-proc-budget.sh 400 -- bin/fm-lint.sh --telemetry "$P.tsv" "$@" > "$P.out" 2>&1 || rc=$?
echo "lint rc=$rc elapsed=$((SECONDS-start))s bound=${BOUND:-default}" >> "$P.out"
kill $MON; wait $MON 2>/dev/null
echo "max RSS of this run's shellcheck seen by outside monitor (KiB): $(cat "$P.peak")" >> "$P.out"
echo "this run's shellcheck processes left alive: $(mine | wc -l | tr -d ' ')" >> "$P.out"
echo "shellcheck processes with cwd in this scratch: $(for p in $(pgrep -f shellcheck); do lsof -a -p $p -d cwd -Fn 2>/dev/null | grep -c "^n$S"; done | awk '{s+=$1} END {print s+0}')" >> "$P.out"
