#!/usr/bin/env bash
# Live drive: real fm-watch.sh in a disposable lab home registers a ready ship
# against a real GitHub PR (read-only gh reads with the machine's login), and
# fm-spawn.sh's capacity admission flips from deferred to admitted.
# Usage: drive-live-watcher.sh <worktree> <pr-number> [capacity]
set -u
WT=$1 PRN=$2 CAP=${3:-1}
URL="https://github.com/MrGTV-love/firstmate/pull/$PRN"
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
TMUXD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() {
  [ -z "${WPID:-}" ] || { kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
  TMUX_TMPDIR="$TMUXD" tmux kill-server 2>/dev/null || true
  bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
labenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$TMUXD" FM_HOME="$LAB" "$@"
}
P="$LAB/projects/firstmate"
git init -q "$P"
git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$P" remote add origin https://github.com/MrGTV-love/firstmate.git
printf "firstmate %s\n" "$CAP" > "$LAB/config/project-capacity"
S="$LAB/state"
meta() {  # <id> <kind> <mode>
  printf 'kind=%s\nmode=%s\nproject=%s\nworktree=%s\nbranch=fm/%s\n' "$2" "$3" "$P" "$P" "$1" > "$S/$1.meta"
  chmod 600 "$S/$1.meta"
}
meta ready-ship ship no-mistakes
printf 'working: implementing\ndone [at=%s]: PR %s checks green\n' "$(date +%s)" "$URL" > "$S/ready-ship.status"
# Records that must be skipped even though their status says ready.
meta scout-task scout ''
meta local-ship ship local-only
meta mate secondmate ''
meta still-working ship no-mistakes
for id in scout-task local-ship mate; do printf 'done: PR %s checks green\n' "$URL" > "$S/$id.status"; done
printf 'working: PR %s checks green is the eventual outcome\n' "$URL" > "$S/still-working.status"
for id in scout-task local-ship mate still-working; do shasum -a 256 "$S/$id.meta"; done > "$LAB/skipped.before"

echo "== lab: FM_HOME=<lab> config/project-capacity: $(cat "$LAB/config/project-capacity")"
echo "== ready-ship.meta before:"; sed 's|'"$LAB"'|<lab>|g' "$S/ready-ship.meta"
echo "== ready-ship.status:"; cat "$S/ready-ship.status"
echo
echo "== STEP 1: fm-spawn.sh for a new firstmate ship BEFORE the watcher runs"
labenv bin/fm-spawn.sh new-item "$P" --mode no-mistakes --yolo off 2>&1 | sed 's|'"$LAB"'|<lab>|g'
echo "fm-spawn exit=${PIPESTATUS[0]}"
echo
echo "== STEP 2: start the real watcher (bin/fm-watch.sh) on the lab home; no supervisor command"
start=$(date +%s)
labenv FM_BACKEND=tmux FM_POLL=2 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
  bash bin/fm-watch.sh > "$LAB/watch.out" 2>&1 &
WPID=$!
for _ in $(seq 1 120); do
  grep -q '^pr=' "$S/ready-ship.meta" && [ -f "$S/ready-ship.check.sh" ] \
    && [ ! -d "$S/.pr-ready-reconcile/lock" ] && break
  sleep 0.5
done
echo "registered after $(( $(date +%s) - start ))s"
kill -TERM "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
echo "== watcher output lines about pr-ready:"; grep 'pr-ready' "$LAB/watch.out" | sed 's|'"$LAB"'|<lab>|g'
echo "== ready-ship.meta after:"; sed 's|'"$LAB"'|<lab>|g' "$S/ready-ship.meta"
echo "== forge headRefOid (read-only gh): $(gh pr view "$URL" --json headRefOid -q .headRefOid)"
echo "== merge poll armed: $(ls -l "$S/ready-ship.check.sh" | awk '{print $1, $NF}' | sed 's|'"$LAB"'|<lab>|g')"
echo "== status log unchanged by the pass:"; cat "$S/ready-ship.status"
echo
echo "== STEP 3: fm-spawn.sh for the same new ship AFTER the watcher (no brief exists, so it must stop after admission)"
labenv bin/fm-spawn.sh new-item "$P" --mode no-mistakes --yolo off 2>&1 | sed 's|'"$LAB"'|<lab>|g'
echo "fm-spawn exit=${PIPESTATUS[0]}"
echo
echo "== STEP 4: skipped records (scout, local-only, secondmate, still working) are unchanged and unregistered"
for id in scout-task local-ship mate still-working; do shasum -a 256 "$S/$id.meta"; done > "$LAB/skipped.after"
if cmp -s "$LAB/skipped.before" "$LAB/skipped.after"; then echo "skipped metas: byte-identical"; else echo "skipped metas: CHANGED"; fi
grep -l '^pr=' "$S"/*.meta | sed 's|'"$LAB"'|<lab>|g'
ls "$S"/*.check.sh | sed 's|'"$LAB"'|<lab>|g'
echo
echo "== STEP 5: a second direct pass changes nothing on the registered record"
h1=$(shasum -a 256 "$S/ready-ship.meta" "$S/ready-ship.check.sh")
out=$(labenv bash bin/fm-pr-ready-reconcile.sh 2>&1)
h2=$(shasum -a 256 "$S/ready-ship.meta" "$S/ready-ship.check.sh")
echo "second pass output: '${out}'"
[ "$h1" = "$h2" ] && echo "registered record and poll: byte-identical" || echo "registered record CHANGED"
