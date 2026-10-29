#!/usr/bin/env bash
# Time one test shell that sources tests/lib.sh (its per-shell orphan sweep), base vs target,
# with an empty temp dir and with N unrelated fm-* entries (some holding marked-looking trees).
set -u
WT=$1; N=${2:-20000}
W=$(mktemp -d "${TMPDIR:-/tmp}/nm-drive-sweep.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/base"; git -C "$WT" archive e27bbad9baa221fce4a159677c4f1046848b8d44 bin tests/lib.sh | tar -x -C "$W/base"
mkdir "$W/empty" "$W/full"
( cd "$W/full" && for i in $(seq "$N"); do mkdir "fm-timeout-status.$i"; done; for i in $(seq 200); do mkdir -p "fm-drop-words.$i/a/b/c"; done )
t() { local s e; s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); env -u FM_TEST_SWEEP_ALL TMPDIR="$2" bash -c '. "$1/tests/lib.sh"' _ "$1" >/dev/null 2>&1; e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); perl -e "printf '%.2f', $e-$s"; }
for side in base target; do
  R=$W/base; [ $side = target ] && R=$WT
  t "$R" "$W/empty" >/dev/null   # warm
  echo "$side: sourcing shell, empty temp dir: $(t "$R" "$W/empty")s ; with $N unrelated fm-* entries: $(t "$R" "$W/full")s"
done
echo "unrelated entries still present after sweeps: $(ls "$W/full" | wc -l | tr -d ' ') (expect $((N+200)))"
