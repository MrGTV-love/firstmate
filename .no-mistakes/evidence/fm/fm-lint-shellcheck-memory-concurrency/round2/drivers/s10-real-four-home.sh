#!/usr/bin/env bash
# Real ShellCheck, four HOME/XDG_CACHE_HOME/FM_HOME values, default host pool, sampled at 0.1 s. Fixtures are unique copies; their history marks are removed afterward.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s10; rm -rf "$S"; mkdir -p "$S"
POOL=/var/tmp/firstmate-lint-$(id -u)/lint-slots
"$WT/bin/fm-mem-guard.sh" admit >/dev/null; echo "host admit exit=$?"; echo "ShellCheck $(shellcheck --version | sed -n 2p); uptime: $(uptime)"
ROOTS=""
for run in 1 2 3 4; do mkdir -p "$S/h$run/.cache" "$S/fm$run" "$S/r$run"; for r in a b c; do cp "$WT/tests/fm-lint-helpers.sh" "$S/r$run/$r.sh"; ROOTS="$ROOTS $S/r$run/$r.sh"; done; done
pass() { # <label>
  local label=$1 pids=() rc=0
  : > "$S/$label.samples"
  ( while :; do "$REALPS" -axo rss=,command= | /usr/bin/awk -v p="$S/r" -v t="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" '$2~/\/shellcheck$/{ if(index($0,p)){s+=$1;n++} else {o+=$1;m++} } END{print t,n+0,s+0,m+0,o+0}' >> "$S/$label.samples"; sleep 0.1; done ) & SP=$!
  t=$SECONDS
  for run in 1 2 3 4; do
    ( cd "$WT" && env -u FM_LINT_SLOT_DIR -u NO_MISTAKES_GATE -u FM_LINT_REQUIRE_BOUNDS CI= GITHUB_ACTIONS= HOME="$S/h$run" XDG_CACHE_HOME="$S/h$run/.cache" FM_HOME="$S/fm$run" FM_LINT_CACHE_DIR=off \
      bin/fm-lint.sh --jobs 2 --telemetry "$S/$label.$run.tsv" "$S/r$run/a.sh" "$S/r$run/b.sh" "$S/r$run/c.sh" ) > "$S/$label.$run.out" 2>&1 & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; echo "$label: run exit=$?"; done
  kill "$SP" 2>/dev/null; wait "$SP" 2>/dev/null
  echo "$label: wall_s=$((SECONDS-t)) $(/usr/bin/awk 'NR>1{g=$1-p;if(g>mg)mg=g;sg+=g}{p=$1;if($2>n)n=$2;if($3>m)m=$3;if($4>on)on=$4;if($3+$5>tot)tot=$3+$5}END{printf "samples=%d gap_mean_s=%.2f gap_max_s=%.2f most_own_shellcheck=%d own_peak_kib=%d most_other_shellcheck=%d own_plus_other_peak_kib=%d", NR, sg/(NR>1?NR-1:1), mg, n, m, on, tot}' "$S/$label.samples")"
  ends=$(cat "$S/$label".*.roots.tsv 2>/dev/null | awk -F '\t' '$1=="end"{c++} END{print c+0}'); echo "$label: roots with an end line in the roots logs: $ends/12"
}
pass cold
n=0; for r in $ROOTS; do [ -s "$POOL/history/$(hkey "full:$r")" ] && n=$((n+1)); done; echo "records in the one host pool after cold: $n/12"
for run in 1 2 3 4; do [ -e "$S/h$run/.cache/firstmate/lint-slots" ] && echo "FAIL: pool under HOME $run"; done; echo "pools under the four HOME values: $(find "$S"/h? -type d -name 'lint-slots' | wc -l | tr -d ' ') (expect 0)"
for r in $ROOTS; do cat "$POOL/history/$(hkey "full:$r")" 2>/dev/null; done | sort -n | sed -n '1p;$p' | tr '\n' ' ' | sed 's/^/lowest and highest record KiB: /'; echo
pass warm
m=0; for r in $ROOTS; do f=$POOL/history/$(hkey "full:$r"); [ -f "$f" ] && { rm -f "$f"; m=$((m+1)); }; done; echo "fixture marks removed from the host pool: $m"
