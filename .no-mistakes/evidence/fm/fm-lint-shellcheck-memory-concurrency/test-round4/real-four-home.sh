#!/usr/bin/env bash
# real-four-home.sh <repo> <lab> <out>: real ShellCheck through real bin/fm-lint.sh, four runs, four HOMEs, three roots of about 350 MiB each.
# Each analysis logs its own start, end and maximum resident size. The figure is the largest sum over analyses that overlap, an upper bound of the true aggregate.
set -u
R=$1 T=$2 out=$3; PERL=/usr/bin/perl
agg(){ perl -ane 'push @e,[$F[1],1,$F[3]],[$F[2],-1,$F[3]]; $m=$F[3] if $F[3]>$m;
  END{my($n,$s,$pk,$mx)=(0,0,0,0); for(sort{$a->[0]<=>$b->[0]||$a->[1]<=>$b->[1]}@e){$n+=$_->[1];$s+=$_->[1]*$_->[2];$pk=$s if $s>$pk;$mx=$n if $n>$mx}
  printf "analyses=%d most_at_once=%d largest_overlapping_sum_kib=%d largest_root_kib=%d\n",scalar(@e)/2,$mx,$pk,$m}' "$1"; }
phase(){ name=$1 pool=$2 budget=$3 limit=$4
  pressure=$(sysctl -n kern.memorystatus_vm_pressure_level)
  [ "$pressure" = 1 ] || { echo "$name NOT STARTED pressure=$pressure" >> "$out"; return 1; }
  : > "$T/log"; s=$SECONDS; pids=()
  for run in 1 2 3 4; do mkdir -p "$T/home.$run/.cache" "$T/fm.$run"
    env FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$pool" FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB="$budget" FM_LINT_ROOT_RSS_KIB="$limit" HOME="$T/home.$run" XDG_CACHE_HOME="$T/home.$run/.cache" FM_HOME="$T/fm.$run" PATH="$T/bin:$PATH" \
      "$R/bin/fm-lint.sh" --jobs 2 "$T/fx/a.sh" "$T/fx/b.sh" "$T/fx/c.sh" > "$T/$name.$run.out" 2>&1 & pids+=($!)
  done
  rcs=""; for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
  cp "$T/log" "$out.$name.log"
  echo "$name budget_kib=$budget root_limit_kib=$limit wall=$((SECONDS-s))s exit_codes=$rcs $(agg "$T/log") pressure_after=$(sysctl -n kern.memorystatus_vm_pressure_level) load=$(uptime | sed 's/.*averages: //')" >> "$out"
}
: > "$out"
phase control-nobudget "$T/pool-ctl" 100000000 2097152
rec=$(cat "$T"/pool-ctl/history/* | sort -n | tail -1); echo "largest record from the control: $rec KiB" >> "$out"
budget=$((rec*5/2)); limit=$((rec*2))
phase empty-budgeted "$T/pool-shared" "$budget" "$limit"
phase history-budgeted "$T/pool-shared" "$budget" "$limit"
echo DONE >> "$out"
