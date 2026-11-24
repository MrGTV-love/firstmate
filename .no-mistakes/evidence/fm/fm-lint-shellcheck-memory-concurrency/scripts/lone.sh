#!/usr/bin/env bash
# lone.sh <repo> <label> <n_roots> <mib> <hold_s>: one lone bin/fm-lint.sh run (default jobs) of n tiny
# roots against a stand-in shellcheck that logs its own start and end time and holds <mib> MiB for <hold_s>.
set -u
repo=$1 label=$2 n=$3 mib=$4 hold=$5
W=${FIXED_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/lone.XXXXXX")}; rm -f "$W/spans"; mkdir -p "$W/bin" "$W/home/.cache" "$W/fm"
cat > "$W/bin/shellcheck" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then printf 'ShellCheck\nversion: 0.11.0\n'; exit 0; fi
exec perl -MTime::HiRes=time -e 'my \$t0=time; my \$s = "x" x ($mib*1024*1024); select(undef,undef,undef,$hold); open(my \$f, ">>", "$W/spans") or die; printf {\$f} "%.3f %.3f\n", \$t0, time; exit 0'
SH
chmod +x "$W/bin/shellcheck"
roots=(); for i in $(seq 1 "$n"); do printf '#!/usr/bin/env bash\nexit 0\n' > "$W/r$i.sh"; roots+=("$W/r$i.sh"); done
t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
( cd "$repo" && env -u FM_LINT_SLOT_DIR -u FM_LINT_HOST_SLOTS -u FM_LINT_ROOT_RSS_KIB -u FM_LINT_JOBS GITHUB_ACTIONS= CI= \
   HOME="$W/home" XDG_CACHE_HOME="$W/home/.cache" FM_HOME="$W/fm" PATH="$W/bin:$PATH" bin/fm-lint.sh "${roots[@]}" > "$W/out" 2>&1 ); rc=$?
t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
most=$(perl -ane 'push @e, [$F[0], 1], [$F[1], -1]; END { my ($c,$m)=(0,0); for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @e) { $c += $_->[1]; $m = $c if $c > $m } print "$m\n" }' "$W/spans")
echo "$label: roots=$n stand-in=${mib}MiB hold=${hold}s exit=$rc wall_s=$(echo "$t1 - $t0" | bc) completed_roots=$(wc -l < "$W/spans" | tr -d ' ') peak_overlap=$most"
grep -E 'fm-lint(\.sh)?:' "$W/out" | grep -v -E 'watch run' | head -5
cat "$W/spans" > "${SPANS_OUT:-/dev/null}"
[ -n "${FIXED_DIR:-}" ] || rm -rf "$W"
