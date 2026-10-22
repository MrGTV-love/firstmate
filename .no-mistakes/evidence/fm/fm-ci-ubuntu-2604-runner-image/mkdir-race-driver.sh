#!/usr/bin/env bash
# Black-box race: N concurrent callers try to create ONE fresh directory.
# A = unadorned packaged mkdir (the old worker lock / .claim behavior).
# B = fm_remote_job_mkdir_exclusive from the code root given as $1 (the fix).
# Prints, per mode, how many trials had exactly 1 owner and the success counts of the others.
set -u
ROOT=$1; TRIALS=${2:-25}; N=${3:-20}
. "$ROOT/bin/fm-remote-job-lib.sh"
W=$(mktemp -d /tmp/mkdirrace.XXXXXX)
echo "mkdir=$(command -v mkdir) -> $(readlink -f "$(command -v mkdir)") :: $(mkdir --version 2>&1 | head -1)"
run_mode() { # <mode>
  local mode=$1 t i ok pids bad=0 dist=""
  for t in $(seq 1 "$TRIALS"); do
    local d="$W/$mode-$t"; mkdir -p "$d"; pids=()
    for i in $(seq 1 "$N"); do
      if [ "$mode" = bare ]; then
        ( (umask 077; mkdir "$d/claim") 2>/dev/null ) &
      else
        ( fm_remote_job_mkdir_exclusive "$d/claim" 2>/dev/null ) &
      fi
      pids+=("$!")
    done
    ok=0
    for p in "${pids[@]}"; do wait "$p" && ok=$((ok+1)); done
    [ "$ok" -eq 1 ] || bad=$((bad+1))
    dist="$dist $ok"
    # litter check for the fixed helper
    if [ "$mode" = excl ]; then
      lit=$(find "$d" -mindepth 1 -maxdepth 1 ! -name claim | wc -l)
      [ "$lit" -eq 0 ] || echo "  litter in trial $t: $lit"
    fi
  done
  echo "mode=$mode trials=$TRIALS callers=$N trials_with_not_exactly_one_owner=$bad owners_per_trial:$dist"
}
run_mode bare
run_mode excl
rm -rf "$W"
