#!/usr/bin/env bash
# prune-check.sh <copy>: run the real merge-prune ignored-file proof on a copy.
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M621V9T0NMTW7XG2T3152C8P
FM_MP_LIB_DIR=$W/bin
. $W/bin/fm-teardown-nested-lib.sh
. $W/bin/fm-merge-prune-lib.sh
copy=$(cd "$1" && pwd -P)
if fm_mp_prove_ignored "$copy"; then echo "prove_ignored: PASS (copy is removable by ignored-file rule) preserve=[${FM_MP_PRESERVE[*]-}]"; else echo "prove_ignored: $FM_MP_VERDICT - $FM_MP_REASON"; fi
