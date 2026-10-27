#!/usr/bin/env bash
# Live adversarial drive with the real fm-watch.sh in a disposable lab home.
# A lab-local gh wrapper delegates to the real gh (read-only) but can report a
# draft or hang once, because no real draft PR exists and a real hang cannot be
# provoked on demand.
# Usage: drive-live-adversarial.sh <worktree> <draft|hang>
set -u
WT=$1 CASE=$2
URL="https://github.com/MrGTV-love/firstmate/pull/${PRN:-261}"
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() {
  [ -z "${WPID:-}" ] || { kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
  [ ! -s "$LAB/hung.pid" ] || kill -KILL "$(cat "$LAB/hung.pid")" 2>/dev/null || true
  TMUX_TMPDIR="$TMUXD" tmux kill-server 2>/dev/null || true
  bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
REAL_GH=$(command -v gh)
mkdir -p "$LAB/fakebin"
cat > "$LAB/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s)" "\$*" >> "$LAB/gh.calls"
case "\$*" in
  *'--json isDraft'*)
    if [ -f "$LAB/hang-once" ]; then rm -f "$LAB/hang-once"; printf '%s\n' "\$\$" > "$LAB/hung.pid"; exec sleep 600; fi
    if [ -f "$LAB/draft" ]; then printf '{"isDraft":true}\n'; exit 0; fi ;;
esac
exec "$REAL_GH" "\$@"
SH
chmod +x "$LAB/fakebin/gh"
labenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$TMUXD" FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" "$@"
}
P="$LAB/projects/firstmate"
git init -q "$P"
git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$P" remote add origin https://github.com/MrGTV-love/firstmate.git
S="$LAB/state"
printf 'kind=ship\nmode=no-mistakes\nproject=%s\nworktree=%s\nbranch=fm/ready-ship\n' "$P" "$P" > "$S/ready-ship.meta"
chmod 600 "$S/ready-ship.meta"
printf 'done [at=%s]: PR %s checks green\n' "$(date +%s)" "$URL" > "$S/ready-ship.status"
: > "$LAB/gh.calls"
# Background the env command directly (no shell function), so $! is the real
# watcher pid; stop waits for its singleton lock to clear before returning.
start_watcher() {  # [VAR=value...]
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$TMUXD" FM_HOME="$LAB" PATH="$LAB/fakebin:$PATH" \
    FM_BACKEND=tmux FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 "$@" \
    bash bin/fm-watch.sh >> "$LAB/watch.out" 2>&1 &
  WPID=$!
}
stop_watcher() {
  kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
  for _ in $(seq 1 100); do [ ! -d "$S/.watch.lock" ] && break; sleep 0.1; done
}
isdraft_calls() { grep -c 'isDraft' "$LAB/gh.calls" || true; }
registered() { grep -q '^pr=' "$S/ready-ship.meta" && [ -f "$S/ready-ship.check.sh" ]; }
wait_registered() {
  for _ in $(seq 1 60); do registered && [ ! -d "$S/.pr-ready-reconcile/lock" ] && return 0; sleep 0.5; done
  return 1
}
show_meta() { sed 's|'"$LAB"'|<lab>|g' "$S/ready-ship.meta"; }
MARK="$S/.pr-ready-reconcile/ready-ship.refused"

case "$CASE" in
draft)
  : > "$LAB/draft"
  before=$(shasum -a 256 "$S/ready-ship.meta")
  echo "== STEP 1: forge reports PR as draft; real watcher runs 8 ticks (1s poll)"
  start_watcher; sleep 8; stop_watcher
  echo "pr-ready lines:"; grep 'pr-ready' "$LAB/watch.out" | sed 's|'"$LAB"'|<lab>|g'
  echo "refusal lines printed: $(grep -c 'registration refused' "$LAB/watch.out")"
  echo "isDraft forge reads over 8 ticks: $(isdraft_calls)"
  [ "$before" = "$(shasum -a 256 "$S/ready-ship.meta")" ] && echo "record unchanged: yes" || echo "record unchanged: NO"
  [ -f "$MARK" ] && echo "refusal marker present: yes"
  echo
  echo "== STEP 2: worker marks the PR ready at the same head; marker aged to 540s (inside the 10-minute window)"
  rm -f "$LAB/draft"
  touch -t "$(date -r $(( $(date +%s) - 540 )) +%Y%m%d%H%M.%S)" "$MARK"
  c0=$(isdraft_calls); : > "$LAB/watch.out"
  start_watcher; sleep 5; stop_watcher
  echo "new pr-ready lines: $(grep -c 'pr-ready' "$LAB/watch.out")"
  echo "new isDraft forge reads: $(( $(isdraft_calls) - c0 ))"
  registered && echo "registered: yes (UNEXPECTED)" || echo "registered: no (still inside window)"
  echo
  echo "== STEP 3: marker aged to 660s (past ten minutes); real watcher retries with no supervisor action"
  touch -t "$(date -r $(( $(date +%s) - 660 )) +%Y%m%d%H%M.%S)" "$MARK"
  : > "$LAB/watch.out"
  start_watcher; wait_registered; rc=$?; stop_watcher
  echo "registered: $([ "$rc" = 0 ] && echo yes || echo NO)"
  grep 'pr-ready' "$LAB/watch.out" | sed 's|'"$LAB"'|<lab>|g'
  show_meta
  [ -e "$MARK" ] && echo "refusal marker: still present" || echo "refusal marker: removed"
  ;;
hang)
  : > "$LAB/hang-once"
  echo "== STEP 1: real watcher with FM_PR_READY_RECONCILE_TIMEOUT=5; the first forge isDraft read hangs (sleep 600)"
  t0=$(date +%s)
  start_watcher FM_PR_READY_RECONCILE_TIMEOUT=5
  for _ in $(seq 1 60); do [ -s "$LAB/hung.pid" ] && break; sleep 0.25; done
  HP=$(cat "$LAB/hung.pid"); echo "hung forge call started (pid recorded) at +$(( $(date +%s) - t0 ))s"
  for _ in $(seq 1 120); do kill -0 "$HP" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$HP" 2>/dev/null; then echo "hung forge call: STILL ALIVE after 30s"; else echo "hung forge call: killed at +$(( $(date +%s) - t0 ))s"; fi
  # The watcher exits on the ready wake and the supervisor re-arms it; do the
  # same here whenever it has exited, until the ship registers or 60s pass.
  rearms=0; rc=1
  for _ in $(seq 1 240); do
    if registered && [ ! -d "$S/.pr-ready-reconcile/lock" ]; then rc=0; break; fi
    if ! kill -0 "$WPID" 2>/dev/null; then
      wait "$WPID" 2>/dev/null
      for _ in $(seq 1 100); do [ ! -d "$S/.watch.lock" ] && break; sleep 0.1; done
      start_watcher FM_PR_READY_RECONCILE_TIMEOUT=5; rearms=$((rearms + 1))
    fi
    sleep 0.25
  done
  echo "watcher re-arms after it exited on a wake: $rearms"
  echo "next tick registered the ship: $([ "$rc" = 0 ] && echo yes || echo NO) at +$(( $(date +%s) - t0 ))s"
  stop_watcher
  grep 'pr-ready' "$LAB/watch.out" | sed 's|'"$LAB"'|<lab>|g'
  show_meta
  echo "isDraft forge reads in total: $(isdraft_calls)"
  ;;
esac
