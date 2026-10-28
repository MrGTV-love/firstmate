#!/bin/bash
# Live real bin/fm-home-summary-refresh.sh --detach: registry unset vs set vs missing (adversarial).
# Usage: default-vs-registry.sh <tree>
set -u
TREE=$1
R=$(mktemp -d "$HOME/tmp/nm-r6-default.XXXXXX"); R=$(cd -P "$R" && pwd -P)
echo "tree=$TREE root=<R> bash=$BASH_VERSION"
mkhome() { mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"; }
wait_pub() { local i=0; while [ ! -s "$1/state/home-summary.json" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; }
show() { local h=$1
  if [ -s "$h/state/home-summary.json" ]; then printf 'published: '; head -c 120 "$h/state/home-summary.json" | sed "s#$R#<R>#g"; echo; else echo "published: none"; fi
  ls "$h/state" | sed 's/^/  state: /'
}
echo "== A. registry UNSET (default product path): --detach"
mkhome "$R/unset-home"
t0=$(python3 -c 'import time;print(time.monotonic())')
env -u FM_TEST_PROCESS_REGISTRY FM_HOME="$R/unset-home" "$TREE/bin/fm-home-summary-refresh.sh" --detach; rc=$?
t1=$(python3 -c 'import time;print(time.monotonic())')
echo "exit=$rc return_secs=$(python3 -c "print(round($t1-$t0,3))")"
wait_pub "$R/unset-home"; sleep 2; show "$R/unset-home"
echo "registry-like files in root: $(ls -A "$R" | grep -c registry)"

echo; echo "== B. registry SET to existing file: --detach"
mkhome "$R/reg-home"; : > "$R/registry"
FM_TEST_PROCESS_REGISTRY="$R/registry" FM_HOME="$R/reg-home" "$TREE/bin/fm-home-summary-refresh.sh" --detach; rc=$?
echo "exit=$rc"
echo "registry immediately after return:"; sed "s#$R#<R>#g" "$R/registry"
wait_pub "$R/reg-home"; show "$R/reg-home"
echo "registry entries after publish:"; sed "s#$R#<R>#g" "$R/registry"
for f in "$R"/registry.*; do [ -e "$f" ] && printf '  %s: %s\n' "${f##*/}" "$(cat "$f")"; done
echo "-- fm_test_wait_processes (tests/lib.sh owner) on that registry:"
mkdir -p "$R/libtmp"; ( export TMPDIR=$R/libtmp; . "$TREE/tests/lib.sh" >/dev/null 2>&1; FM_TEST_PROCESS_WAIT_SECONDS=60 fm_test_wait_processes "$R/registry"; echo "  wait rc=$?" ); echo "  lib subshell exit=$?; libtmp entries left: $(ls -A "$R/libtmp" | wc -l | tr -d " ")"; rmdir "$R/libtmp" 2>/dev/null
echo "registry exists after wait: $([ -e "$R/registry" ] && echo yes || echo no); pidfiles left: $(ls "$R" | grep -c '^registry\.')"
for f in "$R"/registry.*; do [ -e "$f" ] || continue; pid=$(cut -f1 "$f"); echo "  leftover $f pid $pid alive=$(kill -0 $pid 2>/dev/null && echo y || echo n)"; done

echo; echo "== C. ADVERSARIAL registry SET to a missing file: --detach"
FM_TEST_PROCESS_REGISTRY="$R/missing-registry" FM_HOME="$R/badreg-home" "$TREE/bin/fm-home-summary-refresh.sh" --detach 2>&1 | sed "s#$R#<R>#g"; echo "exit=${PIPESTATUS[0]}"
sleep 3
echo "state dir created: $([ -e "$R/badreg-home" ] && echo yes || echo no); missing registry created: $([ -e "$R/missing-registry" ] && echo yes || echo no)"
echo "== D. ADVERSARIAL --_worker with missing registry"
mkhome "$R/badworker-home"
FM_TEST_PROCESS_REGISTRY="$R/missing-registry" FM_HOME="$R/badworker-home" "$TREE/bin/fm-home-summary-refresh.sh" --_worker 2>&1 | sed "s#$R#<R>#g"; echo "exit=${PIPESTATUS[0]}"
echo "worker state entries: $(ls -A "$R/badworker-home/state" | wc -l | tr -d ' ')"
echo; echo "remaining in root:"; ls -A "$R"
echo "ROOT_FOR_CLEANUP=$R"
