#!/usr/bin/env bash
# Live driver: real bin/fm-watch.sh + bin/fm-pr-ready-reconcile.sh + bin/fm-pr-check.sh
# + bin/fm-spawn.sh capacity gate + bin/fm-teardown.sh, in a marked disposable lab home.
# Only the GitHub forge CLI (`gh`) is a stand-in, because a real forge is not reachable
# from a disposable home. Everything else is the shipped code.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5DJJ6GJZAGVVD4816E8MJAX
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5DJJ6GJZAGVVD4816E8MJAX
SCEN=${1:-all}
cd "$WT" || exit 1

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
TMUXDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMUXDIR"
tmux -L fm-lab new-session -d -s primary -x 120 -y 40 'sleep 36000'
WATCH_PID=

cleanup() {
  [ -z "$WATCH_PID" ] || { kill -TERM "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; }
  TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab kill-server 2>/dev/null
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT

STATE=$LAB/state
FORGE=$LAB/forge       # stand-in forge answers, one file per fact
FAKEBIN=$LAB/fakebin
mkdir -p "$FORGE" "$FAKEBIN"
: > "$FORGE/gh.calls"

# ---- real git project with a real origin -------------------------------------
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
PROJ=$LAB/projects/proj
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
echo hi > "$PROJ/README.md"; git -C "$PROJ" add README.md; git -C "$PROJ" commit -qm initial
git clone -q --bare "$PROJ" "$LAB/origin.git"
git -C "$PROJ" remote add origin "file://$LAB/origin.git"
git -C "$PROJ" fetch -q origin
HEAD=$(git -C "$PROJ" rev-parse HEAD)

# ---- stand-in forge CLI -------------------------------------------------------
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FORGE_DIR/gh.calls"
n=$(printf '%s' "$*" | sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p')
case "$*" in
  *'--json isDraft'*)
    if [ -f "$FORGE_DIR/hang-once-$n" ]; then
      rm -f "$FORGE_DIR/hang-once-$n"
      printf '%s\n' "$$" > "$FORGE_DIR/hung.pid"
      exec sleep 600
    fi
    if [ -f "$FORGE_DIR/draft-$n" ]; then printf '{"isDraft":true}\n'; else printf '{"isDraft":false}\n'; fi ;;
  *'--json headRefOid'*) cat "$FORGE_DIR/head" ;;
  *) printf '[]\n' ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/gh-axi"
cp "$FAKEBIN/gh-axi" "$FAKEBIN/no-mistakes"
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi" "$FAKEBIN/no-mistakes"
printf '%s\n' "$HEAD" > "$FORGE/head"

pr() { printf 'https://github.com/example/proj/pull/%s' "$1"; }

# new_ship <id> <mode> <kind> <pr-number-or-"-"> ; creates a real git worktree + meta + status
new_ship() {
  local id=$1 mode=$2 kind=$3 n=$4
  if [ "$kind" = secondmate ]; then
    printf 'kind=secondmate\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=main\n' "$PROJ" "$PROJ" > "$STATE/$id.meta"
  else
    git -C "$PROJ" worktree add -q "$LAB/wt/$id" -b "fm/$id" >/dev/null 2>&1
    printf 'kind=%s\nmode=%s\nproject=%s\nworktree=%s\nbranch=fm/%s\n' "$kind" "$mode" "$PROJ" "$LAB/wt/$id" "$id" > "$STATE/$id.meta"
  fi
  if [ "$n" != - ]; then
    case "$mode" in
      no-mistakes) printf 'done [at=1792479210]: PR %s checks green at %s\n' "$(pr "$n")" "$HEAD" > "$STATE/$id.status" ;;
      *) printf 'done [at=1792479210]: PR %s\n' "$(pr "$n")" > "$STATE/$id.status" ;;
    esac
  else
    printf 'working: implementing\n' > "$STATE/$id.status"
  fi
}

occupants() {
  ( FM_HOME=$LAB
    . "$WT/bin/fm-backend.sh"; . "$WT/bin/fm-wake-lib.sh"; . "$WT/bin/fm-secondmate-registry-lib.sh"; . "$WT/bin/fm-project-capacity-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$PROJ")
    fm_project_capacity_occupants "$lock" "$PROJ" "$STATE" ignored || { echo "occupancy error: $FM_PROJECT_CAPACITY_ERROR"; exit 1; }
    printf '%s (%s)' "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" )
}

# The shipped entrypoints see only FM_HOME, as in the runbook (no *_OVERRIDE, no gate bypass).
fmenv() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" FORGE_DIR="$FORGE" PATH="$FAKEBIN:$PATH" "$@"; }

start_watcher() {  # [VAR=value...]
  ( exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" TMUX_TMPDIR="$TMUXDIR" FORGE_DIR="$FORGE" PATH="$FAKEBIN:$PATH" \
      FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
      FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 "$@" \
      "$WT/bin/fm-watch.sh" ) >> "$LAB/watch.out" 2>&1 &
  WATCH_PID=$!
}
stop_watcher() {
  [ -z "$WATCH_PID" ] || { kill -TERM "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=; }
}

wait_for() {  # <seconds> <cmd...>
  local n=$(( $1 * 10 )) i; shift
  for ((i=0; i<n; i++)); do "$@" && return 0; sleep 0.1; done
  return 1
}
has_pr() { grep -q '^pr=' "$STATE/$1.meta" 2>/dev/null; }
idle_lock() { [ ! -d "$STATE/.pr-ready-reconcile/lock" ]; }
say() { printf '\n== %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS+1)); }
FAILS=0
meta_get() { sed -n "s/^$2=//p" "$STATE/$1.meta"; }

printf 'proj 4\n' > "$LAB/config/project-capacity"

# =============================================================================
say "S1 happy path: real watcher registers ready PRs; capacity frees exactly one per ready ship; skips non-eligible records"
new_ship ship-a no-mistakes ship 101       # ready  -> must register
new_ship ship-b no-mistakes ship -         # still working -> must stay
new_ship ship-c direct-PR ship 103         # direct-PR ready -> must register
new_ship scout-d no-mistakes scout 104     # scout with ready-looking line -> must stay
new_ship local-e local-only ship 105       # local-only with done line -> must stay
new_ship mate-f no-mistakes secondmate -   # secondmate -> not an occupant, must stay
cat "$LAB/config/project-capacity"
echo "occupancy before: $(occupants)"
echo "--- real fm-spawn.sh while the project is full (cap 4, 5 occupants)"
fmenv "$WT/bin/fm-spawn.sh" new-task "$PROJ" --mode no-mistakes --yolo off > "$LAB/spawn1.out" 2>&1; rc=$?
echo "spawn rc=$rc"; grep -h '^deferred:' "$LAB/spawn1.out" | cut -c1-330
before_pr_tasks=0
start_watcher
if wait_for 30 has_pr ship-a && wait_for 30 has_pr ship-c && wait_for 30 idle_lock; then ok "ship-a and ship-c recorded pr= with no supervisor action"; else bad "ready ships not registered by the watcher"; fi
stop_watcher
echo "occupancy after: $(occupants)"
for id in ship-a ship-c; do
  echo "--- $id.meta"; cat "$STATE/$id.meta"
  [ -f "$STATE/$id.check.sh" ] && ok "$id merge poll armed ($id.check.sh)" || bad "$id poll not armed"
  [ "$(meta_get $id pr_head)" = "$HEAD" ] && ok "$id pr_head = forge head" || bad "$id pr_head wrong"
done
for id in ship-b scout-d local-e mate-f; do
  has_pr "$id" && bad "$id was wrongly registered" || ok "$id left alone"
done
case "$(occupants)" in 3*) ok "occupancy fell by exactly the 2 registered ships (5 -> 3)";; *) bad "occupancy not 3: $(occupants)";; esac
echo "--- real fm-spawn.sh after registration (cap 4, 3 occupants): must NOT print deferred"
fmenv "$WT/bin/fm-spawn.sh" new-task "$PROJ" --mode no-mistakes --yolo off > "$LAB/spawn2.out" 2>&1; rc=$?
echo "spawn rc=$rc"; grep -v '^[●━]' "$LAB/spawn2.out" | cut -c1-260 | head -3
grep -q '^deferred:' "$LAB/spawn2.out" && bad "spawn still deferred after registration" || ok "spawn no longer deferred (rc=$rc is its later brief check, not capacity)"
echo "--- watcher output"; cat "$LAB/watch.out" | cut -c1-240 | head -20

# =============================================================================
say "S1b idempotence: repeated passes change nothing and do not call the forge for registered ships"
shasum -a 256 "$STATE/ship-a.meta" "$STATE/ship-a.check.sh" "$STATE/ship-c.meta" > "$LAB/sha.before"
c0=$(wc -l < "$FORGE/gh.calls")
for i in 1 2 3; do fmenv "$WT/bin/fm-pr-ready-reconcile.sh" >> "$LAB/passes.out" 2>&1; done
shasum -a 256 "$STATE/ship-a.meta" "$STATE/ship-a.check.sh" "$STATE/ship-c.meta" > "$LAB/sha.after"
cmp -s "$LAB/sha.before" "$LAB/sha.after" && ok "3 more passes: registrations byte-identical" || bad "registrations changed"
[ "$c0" -eq "$(wc -l < "$FORGE/gh.calls")" ] && ok "3 more passes: zero forge calls" || bad "forge called again"
[ ! -s "$LAB/passes.out" ] && ok "3 more passes: silent" || { bad "passes not silent"; cat "$LAB/passes.out"; }

# =============================================================================
say "S2 refusal: draft PR is refused once, skipped before any forge call inside 10 min, retried after, registers at the SAME head"
new_ship ship-g no-mistakes ship 107
: > "$FORGE/draft-107"
out=$(fmenv "$WT/bin/fm-pr-ready-reconcile.sh" 2>&1)
printf '%s\n' "$out" | cut -c1-260
printf '%s\n' "$out" | grep -q 'ship-g: registration refused' && ok "draft refused with a printed reason" || bad "no refusal for draft"
has_pr ship-g && bad "draft registered" || ok "draft left unregistered (no pr=)"
[ -f "$STATE/.pr-ready-reconcile/ship-g.refused" ] && ok "refusal marker written" || bad "no marker"
rm "$FORGE/draft-107"                              # worker marks ready; copy HEAD is unchanged
c0=$(wc -l < "$FORGE/gh.calls")
touch -t "$(date -v-9M +%Y%m%d%H%M.%S)" "$STATE/.pr-ready-reconcile/ship-g.refused"   # marker is 9 min old
out=$(fmenv "$WT/bin/fm-pr-ready-reconcile.sh" 2>&1)
[ -z "$out" ] && ok "9-minute-old marker: silent pass" || bad "output inside interval: $out"
[ "$c0" -eq "$(wc -l < "$FORGE/gh.calls")" ] && ok "9-minute-old marker: zero forge calls" || bad "forge reached inside interval"
has_pr ship-g && bad "registered inside interval" || ok "9-minute-old marker: still unregistered"
touch -t "$(date -v-11M +%Y%m%d%H%M.%S)" "$STATE/.pr-ready-reconcile/ship-g.refused"  # marker is 11 min old
out=$(fmenv "$WT/bin/fm-pr-ready-reconcile.sh" 2>&1)
printf '%s\n' "$out" | cut -c1-200
has_pr ship-g && ok "11-minute-old marker: retried and registered with no manual step" || bad "not registered after age-out"
[ ! -e "$STATE/.pr-ready-reconcile/ship-g.refused" ] && ok "marker removed after registration" || bad "marker kept"
[ "$(git -C "$LAB/wt/ship-g" rev-parse HEAD)" = "$HEAD" ] && ok "worker copy HEAD never moved (same head throughout)" || bad "head moved"

# =============================================================================
say "S3 strict PR reader: only the PR declared as 'PR <url>' registers"
new_ship ship-h no-mistakes ship -
printf 'done: follows up %s - PR %s checks green\n' "$(pr 180)" "$(pr 195)" > "$STATE/ship-h.status"
c0=$(wc -l < "$FORGE/gh.calls")
out=$(fmenv "$WT/bin/fm-pr-ready-reconcile.sh" 2>&1)
has_pr ship-h && bad "note with a leading unrelated URL registered: $(meta_get ship-h pr)" || ok "leading unrelated PR URL: nothing registered"
[ "$c0" -eq "$(wc -l < "$FORGE/gh.calls")" ] && ok "leading unrelated PR URL: no forge call" || bad "forge reached"
new_ship ship-i no-mistakes ship -
printf 'done: PR %s checks green; follows up %s\n' "$(pr 195)" "$(pr 180)" > "$STATE/ship-i.status"
out=$(fmenv "$WT/bin/fm-pr-ready-reconcile.sh" 2>&1)
[ "$(meta_get ship-i pr)" = "$(pr 195)" ] && ok "declared PR 195 registered, 180 ignored" || bad "wrong pr: $(meta_get ship-i pr)"

# =============================================================================
say "S4 unreadable inputs do not stop other records"
new_ship ship-j no-mistakes ship 110
new_ship ship-k no-mistakes ship 111
new_ship ship-l no-mistakes ship 112
rm "$STATE/ship-j.meta" "$STATE/ship-k.status"; mkdir "$STATE/ship-j.meta" "$STATE/ship-k.status"
out=$(fmenv "$WT/bin/fm-pr-ready-reconcile.sh" 2>&1)
printf '%s\n' "$out" | cut -c1-200
has_pr ship-l && ok "ship-l registered despite unreadable ship-j.meta and ship-k.status" || bad "ship-l blocked"
printf '%s\n' "$out" | grep -q 'ship-j: unreadable task record' && ok "unreadable record reported" || bad "record not reported"
printf '%s\n' "$out" | grep -q 'ship-k: unreadable status log' && ok "unreadable log reported" || bad "log not reported"
rmdir "$STATE/ship-j.meta" "$STATE/ship-k.status"; rm -f "$STATE/ship-j.status" "$STATE/ship-k.meta"

# =============================================================================
say "S5 bounded tail: 200,000-line log, old ready line outside the tail is ignored; fresh ready line registers"
new_ship ship-m no-mistakes ship 113
awk 'BEGIN { for (i=0; i<200000; i++) print "continuation prose without any event" }' >> "$STATE/ship-m.status"
s=$SECONDS
fmenv "$WT/bin/fm-pr-ready-reconcile.sh" >/dev/null 2>&1
has_pr ship-m && bad "ready line outside the bounded tail registered" || ok "old ready line outside the tail ignored ($((SECONDS-s))s pass over 200,000 lines)"
printf 'done [at=1792479210]: PR %s checks green at %s\n' "$(pr 113)" "$HEAD" >> "$STATE/ship-m.status"
s=$SECONDS
fmenv "$WT/bin/fm-pr-ready-reconcile.sh" >/dev/null 2>&1
has_pr ship-m && ok "fresh ready line at the end registers ($((SECONDS-s))s)" || bad "fresh ready line not registered"

# =============================================================================
say "S6 hung forge call: killed at the pass limit, lock released, next tick registers (real watcher, limit 3s)"
new_ship ship-n no-mistakes ship 114
: > "$FORGE/hang-once-114"
rm -f "$FORGE/hung.pid"
start_watcher FM_PR_READY_RECONCILE_TIMEOUT=3
wait_for 20 test -s "$FORGE/hung.pid" && ok "pass reached the hung forge call (pid $(cat "$FORGE/hung.pid"))" || bad "never reached hung call"
hp=$(cat "$FORGE/hung.pid" 2>/dev/null)
t0=$SECONDS
wait_for 20 bash -c "! kill -0 $hp 2>/dev/null" && ok "hung forge call killed after $((SECONDS-t0))s (limit 3s + tick)" || bad "hung forge call outlived the limit"
has_pr ship-n && bad "ship-n registered while its forge call was hung" || ok "ship-n unregistered after the killed pass (nothing half-written)"
echo "--- lock state after the kill: $(ls "$STATE/.pr-ready-reconcile/" | tr '\n' ' ')"
stop_watcher
echo "--- supervisor re-arms the watcher (it exits on a ready wake by design)"
start_watcher FM_PR_READY_RECONCILE_TIMEOUT=3
if wait_for 30 has_pr ship-n; then ok "the next watcher tick registered ship-n after the hung pass"; else
  bad "ship-n never registered after the hang"
  echo "--- diagnostics: watcher alive? $(kill -0 "$WATCH_PID" 2>/dev/null && echo yes || echo no)"
  echo "--- state cache:"; ls -la "$STATE/.pr-ready-reconcile/" 2>&1 | head -20
  echo "--- gh.calls tail:"; tail -6 "$FORGE/gh.calls"
  echo "--- watch.out tail:"; tail -15 "$LAB/watch.out" | cut -c1-240
fi
wait_for 20 idle_lock && ok "single-flight lock released after the registering pass" || bad "lock still held"
stop_watcher

# =============================================================================
say "S7 teardown removes the task's refusal marker (real fm-teardown.sh on a lab task)"
SLOT=$(cd "$PROJ" && treehouse --root "$LAB/pool" get --lease --lease-holder ship-t -b fm/ship-t 2>"$LAB/treehouse.err")
echo "treehouse slot: ${SLOT:-<none>}"; [ -n "$SLOT" ] || cat "$LAB/treehouse.err"
printf 'kind=ship\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=fm/ship-t\n' "$PROJ" "$SLOT" > "$STATE/ship-t.meta"
printf 'working: implementing\n' > "$STATE/ship-t.status"
tmux -L fm-lab new-session -d -s firstmate -n fm-ship-t -x 120 -y 40 'sleep 36000'
printf 'window=firstmate:fm-ship-t\nendpoint_task_id=ship-t\nspawn_gen=lab-ship-t\n' >> "$STATE/ship-t.meta"
mkdir -p "$STATE/.pr-ready-reconcile"
printf 'refused\n' > "$STATE/.pr-ready-reconcile/ship-t.refused"
printf 'refused\n' > "$STATE/.pr-ready-reconcile/ship-other.refused"
fmenv "$WT/bin/fm-teardown.sh" ship-t > "$LAB/teardown.out" 2>&1; rc=$?
echo "teardown rc=$rc"; grep -v '^[●━]' "$LAB/teardown.out" | cut -c1-300 | head -10
[ ! -e "$STATE/ship-t.meta" ] && ok "ship-t record removed by the real teardown" || echo "NOTE: teardown did not remove the ship-t record (see output above)"
[ ! -e "$STATE/.pr-ready-reconcile/ship-t.refused" ] && ok "ship-t refusal marker removed by teardown" || bad "ship-t marker still present"
[ -e "$STATE/.pr-ready-reconcile/ship-other.refused" ] && ok "another task's marker untouched" || bad "other marker removed"

say "RESULT: $FAILS failure(s)"
exit "$FAILS"
