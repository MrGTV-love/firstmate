#!/usr/bin/env bash
# Live lab drive of the PR-ready reconcile: real bin/fm-watch.sh in a marked
# disposable lab home, real gh (read-only PR views, wrapped only to log calls)
# against real open PRs of MrGTV-love/firstmate. The no-mistakes daemon is the
# one external stand-in (a fake axi on the lab PATH) for the crew-state lane.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5ZAE6YBSFRTH8GNJKYKXSX4
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5ZAE6YBSFRTH8GNJKYKXSX4
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2> "$EV/lab-env.stderr")"
LAB=$FM_HOME
echo "lab=$LAB"
REPO=https://github.com/MrGTV-love/firstmate/pull
REAL_GH=$(command -v gh)
FAKEBIN=$LAB/data/fakebin
mkdir -p "$FAKEBIN" "$LAB/projects"
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s)" "\$*" >> "$LAB/data/gh.calls"
exec "$REAL_GH" "\$@"
SH
cat > "$FAKEBIN/no-mistakes" <<SH
#!/usr/bin/env bash
case "\$1 \${2:-}" in
  'axi '|'axi status') cat "$LAB/data/nm-status" ;;
  'axi logs')
    case " \$* " in
      *' --full '*) cat "$LAB/data/nm-ci.log" ;;
      *) tail -n 40 "$LAB/data/nm-ci.log" ;;
    esac ;;
  'daemon '*) printf 'daemon running (pid 4242)\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/no-mistakes"

# Main project: HEAD pushed to its origin. Second project: unpushed HEAD.
P=$LAB/projects/proj
git init -q -b main "$P"; git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git init -q --bare "$LAB/data/origin.git"; git -C "$P" remote add origin "$LAB/data/origin.git"; git -C "$P" push -q origin main
HEAD=$(git -C "$P" rev-parse HEAD)
Q=$LAB/projects/unpushed
git init -q -b main "$Q"; git -C "$Q" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m local-only-commit

S=$LAB/state
meta() {  # id kind mode project [extra]
  { printf 'kind=%s\nmode=%s\nproject=%s\nworktree=%s\nbranch=main\n' "$2" "$3" "$4" "$4"; [ -z "${5:-}" ] || printf '%s\n' "$5"; } > "$S/$1.meta"
  chmod 600 "$S/$1.meta"
}
meta t-ready ship no-mistakes "$P"
printf 'done [at=%s]: PR %s/279 checks green at %s\n' "$(date +%s)" "$REPO" "$HEAD" > "$S/t-ready.status"
meta t-direct ship direct-PR "$P"
printf 'done: PR %s/274\n' "$REPO" > "$S/t-direct.status"
meta t-green ship no-mistakes "$P"
meta t-refused ship direct-PR "$Q"
printf 'done: PR %s/264\n' "$REPO" > "$S/t-refused.status"
meta t-scout scout no-mistakes "$P"
printf 'done: PR %s/263 checks green\n' "$REPO" > "$S/t-scout.status"
meta t-local ship local-only "$P"
printf 'done: PR %s/240 checks green\n' "$REPO" > "$S/t-local.status"
meta t-had ship no-mistakes "$P" "pr=$REPO/212"
printf 'done: PR %s/209 checks green\n' "$REPO" > "$S/t-had.status"
cp "$S/t-had.meta" "$LAB/data/t-had.meta.before"
# t-green: no done line; the run is green 60 base advances ago.
cat > "$LAB/data/nm-status" <<EOF
run:
  id: "01LABRUN"
  branch: main
  status: running
  head: "$HEAD"
  pr: "$REPO/266"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
{ printf 'monitoring CI for PR #266 (timeout: 4h0m0s)...\nall CI checks passed - still monitoring until merged or closed\n'
  for i in $(seq 1 60); do printf 'base branch advanced (%07d..%07d), re-arming CI monitor timeout\n' "$i" "$((i + 1))"; done
} > "$LAB/data/nm-ci.log"

occupancy() {
  ( . bin/fm-backend.sh; . bin/fm-wake-lib.sh; . bin/fm-secondmate-registry-lib.sh; . bin/fm-project-capacity-lib.sh
    lock=$(fm_treehouse_project_lock_path "$P")
    fm_project_capacity_occupants "$lock" "$P" "$S" ignored || { echo "ERR $FM_PROJECT_CAPACITY_ERROR"; exit 0; }
    printf '%s\n' "$FM_PROJECT_CAPACITY_OCCUPANTS" )
}
snap() { for f in "$S"/t-*.meta; do printf '== %s\n' "${f##*/}"; cat "$f"; done; ls -la "$S"/*.check.sh 2>/dev/null; }

echo "--- before"; snap
echo "occupancy(proj) before: $(occupancy)"
for f in "$S"/*.status; do md5 -q "$f"; done > "$LAB/data/status.md5.before"

run_watcher() {  # <seconds> <label>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
    FM_LAVISH_AUTO_RETIRE_INTERVAL=0 PATH="$FAKEBIN:$PATH" \
    bash bin/fm-watch.sh > "$LAB/data/watch-$2.out" 2>&1 &
  local pid=$! t=0
  while [ "$t" -lt "$1" ] && kill -0 "$pid" 2>/dev/null; do sleep 1; t=$((t + 1)); done
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  echo "watcher $2 ran ${t}s"; echo "--- watcher $2 output (stdout+stderr)"; cat "$LAB/data/watch-$2.out"
}
# Pass 1: the watcher may exit on the done wakes; restart it like a re-arm.
start=$(date +%s)
for i in 1 2 3 4; do
  run_watcher 45 "pass1-$i"
  grep -q '^pr=' "$S/t-ready.meta" && grep -q '^pr=' "$S/t-green.meta" && grep -q '^pr=' "$S/t-direct.meta" \
    && [ -e "$S/.pr-ready-reconcile/t-refused.refused" ] && break
done
# Let any detached pass finish.
for _ in $(seq 1 60); do [ -e "$S/.pr-ready-reconcile/lock" ] || break; sleep 1; done
echo "elapsed to registration: $(( $(date +%s) - start ))s"
echo "--- after pass 1"; snap
echo "occupancy(proj) after: $(occupancy)"
echo "--- refusal marker"; ls -la "$S/.pr-ready-reconcile/"; cat "$S/.pr-ready-reconcile/t-refused.refused" 2>/dev/null
echo "--- wake queue"; cat "$S/.wake-queue" 2>/dev/null
echo "--- gh calls pass 1"; cat "$LAB/data/gh.calls"
cp "$LAB/data/gh.calls" "$LAB/data/gh.calls.pass1"

# Pass 2: everything settled; no new forge calls for registered or freshly refused ships.
run_watcher 20 pass2
for _ in $(seq 1 60); do [ -e "$S/.pr-ready-reconcile/lock" ] || break; sleep 1; done
echo "--- gh calls added in pass 2"; diff "$LAB/data/gh.calls.pass1" "$LAB/data/gh.calls" | sed -n 's/^> //p'
echo "--- t-had meta unchanged?"; cmp "$LAB/data/t-had.meta.before" "$S/t-had.meta" && echo "t-had unchanged"
echo "--- status logs unchanged?"; for f in "$S"/*.status; do md5 -q "$f"; done | cmp - "$LAB/data/status.md5.before" && echo "status logs unchanged"
echo "--- refusal wakes for t-refused: $(awk -F '\t' '$4 == "pr-ready-refused:t-refused"' "$S/.wake-queue" 2>/dev/null | wc -l | tr -d ' ')"
echo "occupancy(proj) final: $(occupancy)"

# Teardown.
tmux -L fm-lab kill-server 2>/dev/null || true
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/lab-env.stderr" | head -1)
echo "teardown: $TEARDOWN"; eval "$TEARDOWN"
[ ! -e "$LAB" ] && echo "lab removed: $LAB"
