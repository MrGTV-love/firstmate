#!/usr/bin/env bash
# stall-driver.sh <label> <repo> <lab-dir> <axww-delay> <p-delay> <table-delay> <timeout-s> [VAR=value...]
# Four real bin/fm-lint.sh runs from four HOMEs, three roots each, stand-in ShellCheck holding 1 s.
# A PATH ps shim adds the named delay, then runs the real /bin/ps. Prints the timeline of root starts.
set -u
label=$1 repo=$2 lab=$3 d_ax=$4 d_p=$5 d_tab=$6 limit=$7; shift 7
t=$lab/$label; mkdir -p "$t/bin"
for r in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$t/$r.sh"; done
cat > "$t/bin/ps" <<PS
#!/bin/sh
case " \$* " in
  *" -axww "*) sleep $d_ax ;;
  *" -p "*) sleep $d_p ;;
  *" -axo "*) sleep $d_tab ;;
esac
exec /bin/ps "\$@"
PS
cat > "$t/bin/shellcheck" <<PL
#!/usr/bin/env perl
use strict; use warnings; use Time::HiRes qw(time);
if ((\$ARGV[0] // '') eq '--version') { print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n"; exit 0; }
my \$block = 'x' x (16 * 1048576);
my \$from = time();
select(undef, undef, undef, 1);
open(my \$s, '>>', '$t/spans') or die; printf {\$s} "%d %.3f %.3f\n", \$\$, \$from, time(); close \$s;
exit(length(\$block) ? 0 : 1);
PL
chmod +x "$t/bin/ps" "$t/bin/shellcheck"; : > "$t/spans"
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
pids=()
for run in 1 2 3 4; do
  mkdir -p "$t/home.$run/.cache" "$t/fm.$run"
  env FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$t/pool" "$@" HOME="$t/home.$run" XDG_CACHE_HOME="$t/home.$run/.cache" FM_HOME="$t/fm.$run" PATH="$t/bin:$PATH" \
    "$repo/bin/fm-lint.sh" --jobs 2 "$t/a.sh" "$t/b.sh" "$t/c.sh" > "$t/run.$run.out" 2>&1 &
  pids+=($!)
done
s=$SECONDS timedout=0
while :; do
  alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done
  [ $alive = 0 ] && break
  if [ $((SECONDS-s)) -ge "$limit" ]; then timedout=1; for p in "${pids[@]}"; do kill -TERM "$p" 2>/dev/null; done; sleep 3; break; fi
  sleep 1
done
wall=$((SECONDS-s)); rcs=""
for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
perl -ane 'BEGIN{$st=shift} push @r,[$F[1]-$st,$F[2]-$st]; push @e,[$F[1],1],[$F[2],-1];
  END{ my($n,$m)=(0,0); for(sort{$a->[0]<=>$b->[0]||$a->[1]<=>$b->[1]}@e){$n+=$_->[1];$m=$n if $n>$m}
  my @s=sort{$a->[0]<=>$b->[0]}@r; print "roots_done=".scalar(@s)." most_at_once=$m\n"; printf "start_offsets_s:".join("",map{sprintf " %.1f",$_->[0]}@s)."\n"; }' "$start" "$t/spans"
echo "label=$label ps_delays(axww=$d_ax,p=$d_p,axo=$d_tab) wall=${wall}s timed_out=$timedout exit_codes=$rcs load=$(uptime | sed 's/.*averages: //') extra=$*"
