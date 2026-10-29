#!/usr/bin/env bash
# Adversarial: a symlink is planted at <prefix>.scratch before a bounded call.
# The call must still run, must create nothing inside the symlink target, and the
# dead-owner reap must not delete anything in the symlink target.
set -u
WT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/nm-drive-sym.XXXXXX"); trap 'rm -rf "$T"' EXIT
mkdir "$T/tmp" "$T/victim"
: > "$T/victim/99999999.AAAAAA"      # looks like a dead-owner entry
ln -s "$T/victim" "$T/tmp/fm-timeout-status.scratch"
ln -s "$T/victim" "$T/tmp/fm-gh-rest.scratch"
env TMPDIR="$T/tmp" bash -c '. "$1/bin/fm-timeout-lib.sh"; out=$(fm_run_timed 20 echo ran); echo "fm_run_timed rc=$? out=$out"
  . "$1/bin/fm-scratch-lib.sh"; p=$(fm_scratch_new d fm-gh-rest); echo "fm_scratch_new d gave: ${p#$TMPDIR/}"; fm_scratch_release "$p"' _ "$WT"
echo "victim dir after (must still hold only 99999999.AAAAAA):"; ls -A "$T/victim" | sed 's/^/   /'
echo "TMPDIR after:"; ls -lA "$T/tmp" | sed 1d | awk '{print "   "$1, $9, $10, $11}'
