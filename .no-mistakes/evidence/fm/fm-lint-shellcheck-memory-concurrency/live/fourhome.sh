#!/usr/bin/env bash
# Live driver: four bin/fm-lint.sh runs from four HOME/XDG_CACHE_HOME/FM_HOME
# values, one shared stand-in pool, each run with 3 roots, a stand-in that
# allocates 64 MiB AFTER admission, sampled every 0.1 s by ps.
set -u
WT=$1 OUT=$2 BUDGET=$3 LABEL=$4
mkdir -p "$OUT/bin"; S=$OUT
for r in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$S/$r.sh"; done
cat > "$S/bin/shellcheck" <<PL
#!/usr/bin/env perl
use Time::HiRes qw(time);
if ((\$ARGV[0] // '') eq '--version') { print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n"; exit 0 }
select(undef,undef,undef,0.5);
my \$b = 'x' x (64*1048576);
my \$t = time();
select(undef,undef,undef,2);
open(my \$f,'>>','$S/spans'); printf {\$f} "%d %.6f %.6f\n", \$\$, \$t, time(); close \$f;
exit 0;
PL
chmod +x "$S/bin/shellcheck"; : > "$S/spans"; : > "$S/samples"
REALPS=$(command -v ps)
cat > "$S/bin/ps" <<SH
#!/bin/sh
[ "\$*" = '-axo pid=,ppid=,rss=,comm=' ] || exec "$REALPS" "\$@"
"$REALPS" "\$@" | /usr/bin/awk '{ name = \$0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", name); sub(/ +\$/, "", name); sub(/.*\//, "", name); if (name != "shellcheck") print }'
SH
chmod +x "$S/bin/ps"
( while :; do ps -axo rss=,command= | awk -v p="$S/bin/shellcheck" -v t="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" '$3==p{s+=$1;n++} END{print t, n+0, s+0}' >> "$S/samples"; sleep 0.1; done ) &
SP=$!
pids=()
for run in 1 2 3 4; do
  mkdir -p "$S/home.$run/.cache" "$S/fm.$run"
  env -u FM_LINT_SLOT_DIR -u NO_MISTAKES_GATE HOME="$S/home.$run" XDG_CACHE_HOME="$S/home.$run/.cache" FM_HOME="$S/fm.$run" \
    FM_LINT_CACHE_DIR=off ${POOLENV-FM_LINT_SLOT_DIR=$S/pool} FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB="$BUDGET" FM_LINT_ROOT_RSS_KIB=262144 \
    PATH="$S/bin:$PATH" "$WT/bin/fm-lint.sh" --jobs 2 "$S/a.sh" "$S/b.sh" "$S/c.sh" > "$S/run.$run.out" 2>&1 &
  pids+=($!)
done
rc=0; for p in "${pids[@]}"; do wait "$p" || rc=$?; done
kill $SP 2>/dev/null; wait $SP 2>/dev/null
[ "$rc" -eq 0 ] || cat "$S"/run.*.out | head -20
most=$(perl -ane 'push @e,[$F[1],1],[$F[2],-1]; END{my($n,$m)=(0,0); for(sort{$a->[0]<=>$b->[0]||$a->[1]<=>$b->[1]}@e){$n+=$_->[1];$m=$n if $n>$m} print "$m\n"}' "$S/spans")
maxs=$(awk 'NR>1{g=$1-p; if(g>mg)mg=g; sg+=g} {p=$1; if($3>m)m=$3; if($2>n)n=$2} END{printf "%d %d gap_mean_s=%.2f gap_max_s=%.2f", n+0, m+0, sg/(NR>1?NR-1:1), mg}' "$S/samples")
echo "$LABEL budget_kib=$BUDGET runs_rc=$rc roots_completed=$(wc -l < "$S/spans" | tr -d ' ')/12 most_at_once_by_spans=$most ps_sampler_max_procs_and_max_rss_kib=$maxs samples=$(wc -l < "$S/samples" | tr -d ' ') history_records=$(ls "$S/pool/history" 2>/dev/null | wc -l | tr -d ' ')"
