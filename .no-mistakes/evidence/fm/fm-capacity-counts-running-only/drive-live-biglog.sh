#!/usr/bin/env bash
# Live: real fm-pr-ready-reconcile.sh pass (real gh reads) in a lab home with two
# 200,000-line status logs: ready line at the end registers; ready line only at
# the start (outside the 64 KiB tail) is ignored.
set -u
cd "$1"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bin/fm-lab-home.sh create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
P="$LAB/projects/firstmate"; git init -q "$P"
git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$P" remote add origin https://github.com/MrGTV-love/firstmate.git
S="$LAB/state"
for id in tail-ready head-only; do
  printf 'kind=ship\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=fm/%s\n' "$P" "$P" "$id" > "$S/$id.meta"; chmod 600 "$S/$id.meta"
done
U=https://github.com/MrGTV-love/firstmate/pull/259
{ awk 'BEGIN{for(i=0;i<200000;i++) print "working: step " i " of a very long run with plenty of prose"}'; printf 'done: PR %s checks green\n' "$U"; } > "$S/tail-ready.status"
{ printf 'done: PR %s checks green\n' "$U"; awk 'BEGIN{for(i=0;i<200000;i++) print "continuation prose without any event"}'; } > "$S/head-only.status"
for id in tail-ready head-only; do echo "$id.status: $(wc -l < "$S/$id.status") lines, $(wc -c < "$S/$id.status") bytes"; done
t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
out=$(env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bash bin/fm-pr-ready-reconcile.sh 2>&1)
t1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
echo "pass output: $out"
echo "pass wall time: $(echo "$t1 - $t0" | bc)s (includes real gh reads)"
for id in tail-ready head-only; do echo "$id: $(grep '^pr=' "$S/$id.meta" || echo 'no pr= (not registered)')"; done
