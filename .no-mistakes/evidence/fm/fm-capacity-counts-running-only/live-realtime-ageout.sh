#!/usr/bin/env bash
# Real-time (no clock edits) 10-minute age-out driver. Based on live-driver.sh.
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
say "T real 10-minute age-out: draft PR refused, then ready at the SAME head; no clock or mtime edits anywhere"
new_ship ship-g no-mistakes ship 107
: > "$FORGE/draft-107"
t_start=$(date +%s)
start_watcher
wait_for 60 test -e "$STATE/.pr-ready-reconcile/ship-g.refused" && ok "refusal marker written at +$(( $(date +%s) - t_start ))s" || bad "no refusal marker"
t_ref=$(date +%s)
grep -h 'ship-g: registration refused' "$LAB/watch.out" | cut -c1-140
rm "$FORGE/draft-107"          # worker marks the PR ready; the copy HEAD does not move
calls_at_ref=$(grep -c 'pull/107' "$FORGE/gh.calls")
echo "forge calls for PR 107 at refusal: $calls_at_ref"
registered_at=
while :; do
  now=$(date +%s); el=$((now - t_ref))
  if has_pr ship-g; then registered_at=$el; break; fi
  [ "$el" -lt 1500 ] || break
  # supervisor re-arm: the watcher exits on wakes by design
  kill -0 "$WATCH_PID" 2>/dev/null || start_watcher
  if [ $((el % 60)) -lt 2 ]; then printf 't+%03ds forge calls for 107: %s registered: no\n' "$el" "$(grep -c 'pull/107' "$FORGE/gh.calls")"; sleep 2; fi
  sleep 1
done
stop_watcher
echo "registered after ${registered_at:-never}s from the refusal"
c_total=$(grep -c 'pull/107' "$FORGE/gh.calls")
echo "forge calls for PR 107 in total: $c_total (refusal pass made $calls_at_ref)"
[ -n "$registered_at" ] && [ "$registered_at" -ge 600 ] && [ "$registered_at" -lt 660 ] && ok "registered at +${registered_at}s: not before 600s, within one tick of the interval" || bad "registration time ${registered_at:-never}s outside [600,660)"
[ "$((c_total - calls_at_ref))" -le 2 ] && ok "no forge call during the 10 minutes; only the retry's own 2 calls (draft read + head read) after age-out" || bad "forge reached inside interval"
[ "$(meta_get ship-g pr)" = "$(pr 107)" ] && ok "pr= recorded" || bad "pr= missing"
[ "$(git -C "$LAB/wt/ship-g" rev-parse HEAD)" = "$HEAD" ] && ok "worker copy HEAD never moved" || bad "head moved"
say "RESULT: $FAILS failure(s)"
exit "$FAILS"
