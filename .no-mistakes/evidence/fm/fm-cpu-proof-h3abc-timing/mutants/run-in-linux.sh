#!/bin/bash
# Usage: run-in-linux.sh SCRIPT CASE...   (SCRIPT is a path inside the container)
# Runs the proof script in the CI-like Ubuntu 24.04 image with the CI job's settings, worktree mounted read-only.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M87QBTBT9VMYRMHAD7DVJD13
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M87QBTBT9VMYRMHAD7DVJD13
script=$1; shift
exec docker run --rm --cpus 4 -v "$WT":/repo:ro -v "$EV/mutants":/mutants:ro -w /repo \
  -e FM_CONC_N=2 -e FM_CONC_LANES=4 -e FM_CONC_ROUNDS=5 -e FM_CONC_WORK=0.15 -e FM_CONC_BURNERS=1 \
  fmci-linux:latest bash -c 'mkdir -p /tmp/fm-conc; echo "linux: $(uname -sm) nproc=$(nproc) load=$(cut -d" " -f1-3 /proc/loadavg)"; s=$1; shift; time python3 "$s" /repo /tmp/fm-conc "$(command -v python3)" "$@"; echo exit=$?' _ "$script" "$@"
