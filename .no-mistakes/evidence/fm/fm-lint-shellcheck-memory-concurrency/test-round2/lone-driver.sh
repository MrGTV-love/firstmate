#!/usr/bin/env bash
set -u
repo=$1; n=$2
tmp=$(mktemp -d /tmp/fmdbg-lone.XXXX)
mkdir -p $tmp/bin $tmp/home/.cache $tmp/fm
for r in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > $tmp/$r.sh; done
source /tmp/fmdbg-driver/writer.sh
fm_lint_write_memory_shellcheck $tmp/bin 64 $tmp/mem.starts
run() {
  : > $tmp/mem.starts; : > $tmp/mem.starts.spans
  env FM_LINT_CACHE_DIR=off FM_TEST_MEM_HOLD=8 FM_LINT_SLOT_DIR=$tmp/shared FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$1 FM_LINT_ROOT_RSS_KIB=262144 HOME=$tmp/home XDG_CACHE_HOME=$tmp/home/.cache FM_HOME=$tmp/fm PATH="$tmp/bin:$PATH" $repo/bin/fm-lint.sh --telemetry $tmp/t.tsv --jobs 2 $tmp/a.sh $tmp/b.sh $tmp/c.sh >$tmp/out 2>&1
  echo "rc=$? most=$(perl -ane 'push @e, [$F[1], 1], [$F[2], -1]; END { my ($n, $m) = (0, 0); for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @e) { $n += $_->[1]; $m = $n if $n > $m } print "$m" }' $tmp/mem.starts.spans)"
  echo "-- spans"; cat $tmp/mem.starts.spans; echo "-- roots"; cat $tmp/t.roots.tsv
}
run 100000000
cat $tmp/shared/history/*
rec=$(cat $tmp/shared/history/* | sort -n | tail -1)
for i in $(seq 1 $n); do run $((rec*5/2)); done
echo budget=$((rec*5/2))
rm -rf $tmp
