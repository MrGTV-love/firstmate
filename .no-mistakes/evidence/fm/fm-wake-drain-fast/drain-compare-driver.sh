#!/bin/bash
# drain-compare-driver.sh <base-root> <target-root> <evidence-dir>
# Runs the REAL bin/fm-wake-drain.sh from each code root against identical,
# disposable, marked lab homes holding 25 cold status logs (60 keyed resolved/
# working pairs each = 1500 keyed resolutions, plus a few open decisions).
# Measures: wall time (3 cold reps), subshell entries (DEBUG-trap, same method
# as tests/fm-wake-drain-unread-status.test.sh), and external execs (PATH shims).
# Compares stdout and open-decision cursor bytes between base and target.
set -u
BASE=$1 TARGET=$2 EV=$3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-drain-cmp.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
TASKS=${TASKS:-25} PAIRS=${PAIRS:-60} REPS=${REPS:-3}

# Shim dir: one shim per executable name on PATH; counts every exec by name.
SHIM="$WORK/shim"; mkdir -p "$SHIM"
IFS=: read -r -a dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n=${f##*/}
    [ -x "$f" ] && [ ! -d "$f" ] || continue
    [ -e "$SHIM/$n" ] && continue
    printf '#!/bin/sh\nprintf "%%s\\n" %q >> "$FM_EXEC_LOG"\nexec %q "$@"\n' "$n" "$f" > "$SHIM/$n"
    chmod +x "$SHIM/$n"
  done
done

build_fleet() {  # <state>
  local state=$1 t i
  for ((t = 0; t < TASKS; t++)); do
    {
      printf 'working: starting task %s\n' "$t"
      for ((i = 0; i < PAIRS; i++)); do
        printf 'resolved [key=side-%s]: routine close %s\n' "$i" "$i"
        printf 'working: step %s\n' "$i"
      done
      if [ $((t % 5)) -eq 0 ]; then
        printf 'needs-decision [key=pick-%s]: choose option for task %s\n' "$t" "$t"
        printf 'blocked [key=wall-%s]: blocked on input %s\n' "$t" "$t"
        printf 'note: informational note for task %s\n' "$t"
      fi
    } > "$state/task$t.status"
  done
}

new_lab() {  # prints a fresh marked lab home with the fleet
  local lab
  lab=$(mktemp -d "$WORK/fm-lab.XXXXXX")
  rmdir "$lab"
  "$TARGET/bin/fm-lab-home.sh" create "$lab" >/dev/null || { echo "lab create failed" >&2; exit 1; }
  mkdir -p "$lab/tmux"
  build_fleet "$lab/state"
  printf '%s\n' "$lab"
}

run_drain() {  # <root> <lab> <mode> <out-prefix>
  local root=$1 lab=$2 mode=$3 out=$4
  local cleanenv=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE
    FM_HOME="$lab" TMUX_TMPDIR="$lab/tmux")
  case $mode in
    plain)
      "${cleanenv[@]}" /bin/bash "$root/bin/fm-wake-drain.sh" > "$out.stdout" 2> "$out.stderr" ;;
    subshell)
      : > "$out.subshells"
      "${cleanenv[@]}" SUBSHELL_ENTRY_COUNT="$out.subshells" SUBSHELL_ENTRY_DRAIN="$root/bin/fm-wake-drain.sh" /bin/bash -c '
        set -T
        seen_depth=0
        trap '\''if [ "$BASH_SUBSHELL" != "$seen_depth" ]; then seen_depth=$BASH_SUBSHELL; printf x >> "$SUBSHELL_ENTRY_COUNT"; fi'\'' DEBUG
        . "$SUBSHELL_ENTRY_DRAIN"
      ' > "$out.stdout" 2> "$out.stderr" ;;
    exec)
      : > "$out.execs"
      "${cleanenv[@]}" FM_EXEC_LOG="$out.execs" PATH="$SHIM:$PATH" /bin/bash "$root/bin/fm-wake-drain.sh" > "$out.stdout" 2> "$out.stderr" ;;
  esac
}

now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

{
echo "host: $(uname -srm); bash under test: $(/bin/bash --version | head -1)"
echo "fleet: $TASKS cold status logs x $PAIRS keyed resolved/working pairs (+needs-decision/blocked/note on every 5th task)"
echo "load at start: $(sysctl -n vm.loadavg)"
for side in base target; do
  root=$BASE; [ "$side" = target ] && root=$TARGET
  echo
  echo "=== $side ($root) ==="
  for ((r = 1; r <= REPS; r++)); do
    lab=$(new_lab)
    s=$(now); run_drain "$root" "$lab" plain "$EV/drain-$side-rep$r"; rc=$?; e=$(now)
    echo "cold drain rep $r: exit=$rc wall=$(echo "$e - $s" | bc)s load=$(sysctl -n vm.loadavg)"
    if [ "$r" = 1 ]; then
      ( cd "$lab/state" && for f in .*open-decisions* ; do [ -e "$f" ] && { printf '%s\t' "$f"; grep -v "^ident=" "$f" | /usr/bin/shasum | cut -c1-16; }; done ) > "$EV/drain-$side-cursors.txt"
      ( cd "$lab/state" && ls -A ) > "$EV/drain-$side-state-files.txt"
      cp "$lab/state/.task0.open-decisions-cursor" "$EV/drain-$side-task0-open-decisions-cursor.bytes" 2>/dev/null || true
    fi
    rm -rf "$lab"
  done
  lab=$(new_lab); run_drain "$root" "$lab" subshell "$EV/drain-$side-instr"; rc=$?
  echo "subshell entries (cold drain, DEBUG trap): $(wc -c < "$EV/drain-$side-instr.subshells" | tr -d ' ') exit=$rc"
  rm -rf "$lab"
  lab=$(new_lab); run_drain "$root" "$lab" exec "$EV/drain-$side-instr"; rc=$?
  echo "external execs (cold drain, PATH shims): $(wc -l < "$EV/drain-$side-instr.execs" | tr -d ' ') exit=$rc"
  echo "  by command: $(sort "$EV/drain-$side-instr.execs" | uniq -c | sort -rn | awk '{printf "%s=%s ", $2, $1}')"
  # warm second drain on the same home: steady state after presentation
  s=$(now); run_drain "$root" "$lab" plain "$EV/drain-$side-warm"; rc=$?; e=$(now)
  echo "warm second drain: exit=$rc wall=$(echo "$e - $s" | bc)s"
  rm -rf "$lab"
done
echo
echo "load at end: $(sysctl -n vm.loadavg)"
echo
echo "=== base vs target cold-drain stdout diff (rep1) ==="
diff "$EV/drain-base-rep1.stdout" "$EV/drain-target-rep1.stdout" && echo "IDENTICAL stdout"
echo "=== base vs target open-decision cursor digests (ident= device:inode:mtime line excluded) ==="
diff "$EV/drain-base-cursors.txt" "$EV/drain-target-cursors.txt" && echo "IDENTICAL cursor bytes ($(wc -l < "$EV/drain-target-cursors.txt" | tr -d ' ') files)"
echo "=== target cold drain stdout (rep1) ==="
cat "$EV/drain-target-rep1.stdout"
echo "=== target cold drain stderr (rep1) ==="
cat "$EV/drain-target-rep1.stderr"
} 2>&1 | tee "$EV/drain-compare-transcript.txt"
