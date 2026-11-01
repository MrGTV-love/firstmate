#!/usr/bin/env bash
# churn-measure.sh <head-root> <base-commit> <tasks> <reps> <mode>
# Builds one disposable FM_HOME with <tasks> owned scout tasks, then runs the
# real bin/fm-fleet-snapshot.sh <mode> from the base tree and the head tree,
# alternating order each rep. Processes created per run = PID delta across the
# run, counted exactly: FC_DIR holds an ad-hoc re-signed copy of /bin/bash and
# fork-counter-interposer.c built as fc.dylib (DYLD interposer logging every
# fork/posix_spawn and re-routing "#!/usr/bin/env bash" scripts to that bash so
# nested firstmate scripts stay counted). SIP leaf binaries (stat, sed) and
# python scripts are counted when created, not their own children.
# Also checks the two trees print the same JSON (snapshot clock fields dropped).
set -u
HEAD_ROOT=$1 BASE=$2 N=$3 R=$4 MODE=$5
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-churn.XXXXXX")
[ -n "${KEEP:-}" ] || trap 'rm -rf "$WORK"' EXIT; echo "work=$WORK"
mkdir -p "$WORK/base"
git -C "$HEAD_ROOT" archive HEAD | tar -x -C "$WORK/base"
git -C "$HEAD_ROOT" show "$BASE:bin/fm-fleet-snapshot.sh" > "$WORK/base/bin/fm-fleet-snapshot.sh"
chmod +x "$WORK/base/bin/fm-fleet-snapshot.sh"
home=$WORK/home fb=$WORK/fakebin
mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$fb"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target="" prev=""
for arg in "$@"; do [ "$prev" = "-t" ] && target=$arg; prev=$arg; done
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$fb/no-mistakes" "$fb/tmux"
printf '## In flight\n' > "$home/data/backlog.md"
for i in $(seq -w 1 "$N"); do
  id=task$i
  mkdir -p "$home/projects/$id"
  printf -- '- [ ] %s - Task %s (repo: alpha) (kind: scout) (since 2026-10-01)\n' "$id" "$i" >> "$home/data/backlog.md"
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$home/projects/$id" project=alpha harness=claude kind=scout mode=scout spawn_gen=g1 > "$home/state/$id.meta"
  gen=$("$HEAD_ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  "$HEAD_ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" idle --gen "$gen" --source claude-hook --event stop
  {
    printf 'working [at=1791450000]: started %s\n' "$id"
    printf 'needs-decision [key=k%s] [at=1791450001]: question for %s\n' "$i" "$id"
    if [ $((10#$i % 2)) = 0 ]; then printf 'resolved [key=k%s]: answered\n' "$i"; fi
    printf 'working [at=1791450002]: still going %s\n' "$id"
  } > "$home/state/$id.status"
done
FC=${FC_DIR:?}
run() {  # <root> <outfile> -> prints process count
  rm -f "$2.fc"
  PATH="$FC/b:$fb:$PATH" FM_HOME="$home" FC_BASH="$FC/b/bash" FC_LOG="$2.fc" DYLD_INSERT_LIBRARIES="$FC/fc.dylib" \
    "$FC/b/bash" "$1/bin/fm-fleet-snapshot.sh" $MODE > "$2" 2>"$2.err"
  echo "rc=$?" >> "$2.err"
  grep -cE '^(fork|spawn|spawnp) ' "$2.fc"
}
execs() { awk '$1=="exec"{print $3}' "$1" | sed 's#.*/##' | sort | uniq -c | sort -rn | awk '{printf "%s=%s ", $2, $1}'; }
norm() { jq -S 'del(.. | .generated_at?, .generated?, .generated_epoch?, .observed_at?, .snapshot_epoch?, .generated_at_epoch?, .age_seconds?, .last_event_age_seconds?)' "$1"; }
bc=() hc=()
for r in $(seq 1 "$R"); do
  if [ $((r % 2)) = 1 ]; then
    bc+=("$(run "$WORK/base" "$WORK/base.out")"); hc+=("$(run "$HEAD_ROOT" "$WORK/head.out")")
  else
    hc+=("$(run "$HEAD_ROOT" "$WORK/head.out")"); bc+=("$(run "$WORK/base" "$WORK/base.out")")
  fi
done
med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
mn() { printf '%s\n' "$@" | sort -n | head -1; }
echo "host=$(hostname -s) uptime_load=$(uptime | sed 's/.*load averages*: //') mode=$MODE tasks=$N reps=$R base=$BASE head=$(git -C "$HEAD_ROOT" rev-parse HEAD)"
echo "base processes per run: ${bc[*]}"
echo "head processes per run: ${hc[*]}"
echo "base min=$(mn "${bc[@]}") median=$(med "${bc[@]}")"
echo "head min=$(mn "${hc[@]}") median=$(med "${hc[@]}")"
echo "base exec targets (last run): $(execs "$WORK/base.out.fc")"
echo "head exec targets (last run): $(execs "$WORK/head.out.fc")"
echo "base stderr: $(tr '\n' ' ' < "$WORK/base.out.err")"
echo "head stderr: $(tr '\n' ' ' < "$WORK/head.out.err")"
if diff <(norm "$WORK/base.out") <(norm "$WORK/head.out") > "$WORK/diff.txt"; then
  echo "output: base and head JSON identical after dropping clock fields"
else
  echo "output: DIFFERENT"; cat "$WORK/diff.txt"
fi
echo "head output sample:"; jq -c '{valid,state,decisions_open:[.decisions_open[]?.key], active_children:(.active_children|length?)}' "$WORK/head.out" 2>/dev/null || head -c 600 "$WORK/head.out"
