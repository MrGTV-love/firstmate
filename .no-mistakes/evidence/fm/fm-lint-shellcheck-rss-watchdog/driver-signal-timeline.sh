#!/usr/bin/env bash
# kill.sh <scratch> <evidence-file> <signal>: lint the runaway file in its own process group,
# send <signal> to that group after 5 s, and log every process of this scratch for 15 s.
S=$(cd "$1" && pwd -P) OUT=$2 SIG=$3
cd "$S" || exit 1
: > "$OUT"
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
snap() {  # pid pgid rss comm of shellcheck (cwd in scratch) and of perl/time whose args name the scratch run
  for p in $(pgrep -f 'shellcheck --norc'); do lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -q "^n$S\$" && ps -o pid=,pgid=,rss=,comm= -p "$p"; done
  ps -A -o pid=,pgid=,rss=,args= | awk -v s="$S" 'index($0, s "/bin/fm-lint-cache.pl") { print $1, $2, $3, $4, $6 }'
}
guard() { while :; do for p in $(pgrep -f 'shellcheck --norc'); do lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -q "^n$S\$" || continue
  r=$(ps -o rss= -p "$p" | tr -d ' '); [ "${r:-0}" -gt 4194304 ] && { echo "SAFETY KILL $p $r" >> "$OUT"; kill -KILL "$p"; }; done; sleep 0.5; done; }
guard & G=$!
perl -MPOSIX -e 'POSIX::setpgid(0,0); exec @ARGV' env FM_LINT_ROOT_RSS_KIB=6291456 FM_LINT_JOBS=1 \
  bin/fm-proc-budget.sh 400 -- bin/fm-lint.sh tests/fm-spawn-acquisition-cleanup.test.sh > "$OUT.lint" 2>&1 &
L=$!
sleep 5
echo "lint process group: $L" >> "$OUT"
echo "t=-0 before SIG$SIG (pid pgid rss_kib cmd):" >> "$OUT"; snap >> "$OUT"
t0=$(now); if [ "${TARGET:-group}" = pid ]; then kill -"$SIG" "$L"; else kill -"$SIG" -- -"$L"; fi
for i in $(seq 1 ${STEPS:-30}); do
  sleep 0.5
  s=$(snap); echo "t=+$(perl -e "printf '%.1f', $(now) - $t0") ($(printf '%s' "$s" | grep -c .) procs):" >> "$OUT"; printf '%s\n' "$s" | sed '/^$/d' >> "$OUT"
  [ -n "$s" ] || break
done
wait "$L"; echo "lint exit status: $?" >> "$OUT"
kill $G; wait $G 2>/dev/null
