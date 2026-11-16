#!/usr/bin/env bash
# Live lab: real bin/fm-spawn.sh, real tmux (private fm-lab socket), real treehouse (scratch TREEHOUSE_ROOT),
# real git. The fix must skip the copy holding work, lease it in place untouched, take a second copy, move it to
# origin's tip and launch. Before the fix, the spawn's `git reset --hard` destroyed that work.
# Usage: lab-race.sh <spawn-tree-root> <label> <commit|ignored|base|holder>
#   dirty:    an untracked file with unique bytes is written into slot 1 right after the get
#   governed: commit mode on a Vernant-style project (provision_existing_slot.py present, --owned-path scripts)
#   (the ignored mode lost the race against the spawn's origin read in all four tries; the base mode covers that rule)
#   holder:  a foreign process (python sleeping 90 s) starts with its cwd in slot 1 right after the get
# Real treehouse fetches origin and resets a slot on every get, so work is placed by a watcher right after the pane
# enters the slot (the window between treehouse get and the spawn's own move):
#   commit:  a commit on the slot's detached HEAD (unlanded work; a reset to origin's tip orphans it)
#   ignored: origin's tip starts tracking keep.local and the slot holds an ignored keep.local with unique bytes
#   base:    no race. origin/feature = main + a commit that tracks keep.local; the spawn runs with --base-branch feature.
#            treehouse seeds the main checkout's ignored keep.local into slot 1 (.worktreeinclude); the watcher then
#            gives slot 1 unique bytes and removes the main checkout's copy so a second slot is seeded clean.
set -u
SPAWN_TREE=$1 LABEL=$2 MODE=$3
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7HREQ1KNSZTA36CQCSPN00P
E=/Users/charlesabrooker/.no-mistakes/evidence/01M7HREQ1KNSZTA36CQCSPN00P
OUT=$E/lab-$LABEL.txt
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$("$W/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
X=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-world.XXXXXX")
X=$(cd "$X" && pwd -P)
ID=lab-$MODE-$LABEL
G=(-c user.name='Lab' -c user.email='lab@example.invalid')
log() { printf '%s\n' "$*" | tee -a "$OUT"; }
: >"$OUT"
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  "$W/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 && { chmod -R u+w "$LAB"; rm -rf "$LAB"; }
  sleep 1; chmod -R u+w "$X" 2>/dev/null; rm -rf "$X" || { sleep 2; rm -rf "$X"; }
}
trap cleanup EXIT

log "== lab ($LABEL): spawn tree $SPAWN_TREE at $(git -C "$SPAWN_TREE" rev-parse --short HEAD)"
git init -q -b main "$X/src"
printf 'base\n' >"$X/src/README.md"
printf '*.local\n' >"$X/src/.gitignore"
printf '*.local\n' >"$X/src/.worktreeinclude"
git -C "$X/src" add -A && git "${G[@]}" -C "$X/src" commit -qm initial
git clone -q --bare "$X/src" "$X/origin.git"
git clone -q "file://$X/origin.git" "$X/project"
git clone -q "file://$X/origin.git" "$X/publisher"
mkdir -p "$X/user-home" "$X/pool"
export TREEHOUSE_ROOT=$X/pool HOME=$X/user-home

slot_facts() { # <path>
  printf 'HEAD=%s\n' "$(git -C "$1" rev-parse HEAD 2>&1)"
  printf 'log: %s\n' "$(git -C "$1" log --oneline -3 2>&1 | tr '\n' ';')"
  printf 'mine.txt=%s\n' "$(cat "$1/mine.txt" 2>&1)"
  printf 'keep.local sha256=%s content=%s\n' "$(shasum -a 256 "$1/keep.local" 2>&1 | cut -c1-16)" "$(cat "$1/keep.local" 2>&1)"
  printf 'status:\n%s\n' "$(git -C "$1" status --short --ignored 2>&1)"
}
TIP0=$(git -C "$X/publisher" rev-parse HEAD)
log "origin tip at start: $TIP0"

# Lab home: the brief and a watcher beat (nothing from the test fixtures' override env).
mkdir -p "$LAB/data/$ID" "$LAB/state"
cat >"$LAB/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live lab check of the pooled-slot move: keep unique ignored work when origin starts tracking its path.

## Firstmate spec
Exercise the spawn behavior under test.
EOF
[ "$MODE" = base ] && printf '\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: feature\n' >>"$LAB/data/$ID/brief.md"
touch "$LAB/state/.last-watcher-beat"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS tmux -L fm-lab new-session -d -s primary -x 200 -y 50 -c "$SPAWN_TREE" \
  -e FM_HOME="$LAB" -e TREEHOUSE_ROOT="$X/pool" -e HOME="$X/user-home" bash --noprofile --norc
tmux -L fm-lab set-environment -g TREEHOUSE_ROOT "$X/pool"
tmux -L fm-lab set-environment -g HOME "$X/user-home"
tmux -L fm-lab set-environment -g FM_HOME "$LAB"
tmux -L fm-lab send-keys -t primary "cd '$X/project' && treehouse pool-dir > '$X/pooldir.txt'; cd '$SPAWN_TREE'" Enter
sleep 2
log "pane treehouse pool-dir: $(cat "$X/pooldir.txt")"
case "$(cat "$X/pooldir.txt")" in "$X/pool"/*) ;; *) log "ABORT: pane does not use the scratch pool"; exit 3 ;; esac

BASE_ARGS=() MODE_ARGS=(--mode local-only)

if [ "$MODE" = governed ]; then
  # A governed (Vernant-style) project: origin carries scripts/git-stability/provision_existing_slot.py. The real
  # Vernant provisioner is not in this repository; this stand-in records its call and refuses, so any provisioning
  # that is reached is visible. The pooled-copy proof under test runs before it.
  mkdir -p "$X/publisher/scripts/git-stability"
  cat >"$X/publisher/scripts/git-stability/provision_existing_slot.py" <<PY
import json, sys
open("$X/provisioner.called", "a").write(json.dumps(sys.argv[1:]) + "\n")
print(json.dumps({"state": "BLOCKED", "reason": "lab_stand_in_provisioner_refuses"}))
raise SystemExit(2)
PY
  git -C "$X/publisher" add scripts && git "${G[@]}" -C "$X/publisher" commit -qm 'add slot owner'
  git -C "$X/publisher" push -q origin main
  git -C "$X/project" pull -q --ff-only origin main
  BASE_ARGS=(--owned-path scripts)
  MODE_ARGS=(--mode direct-PR)
fi
if [ "$MODE" = base ]; then
  git -C "$X/publisher" checkout -qb feature
  printf 'tracked upstream content\n' >"$X/publisher/keep.local"
  git -C "$X/publisher" add -f keep.local && git "${G[@]}" -C "$X/publisher" commit -qm 'feature tracks keep.local'
  git -C "$X/publisher" push -q origin feature
  printf 'seeded from main checkout\n' >"$X/project/keep.local"
  BASE_ARGS=(--base-branch feature)
  MODE_ARGS=(--mode direct-PR)
fi
if [ "$MODE" = ignored ]; then # the origin commit is made now and only pushed by the watcher (a short race window)
  printf 'tracked upstream content\n' >"$X/publisher/keep.local"
  git -C "$X/publisher" add -f keep.local && git "${G[@]}" -C "$X/publisher" commit -qm 'track keep.local'
fi
# Watcher: as soon as the spawn's window is in a pool slot, place the work there (from outside the slot: no holder).
(
  for _ in $(seq 1 4000); do
    P1=$(tmux -L fm-lab list-panes -a -F '#{window_name} #{pane_current_path}' 2>/dev/null | awk -v w="fm-$ID" '$1==w{print $2}' | grep "^$X/pool/" | head -1)
    [ -n "$P1" ] && break; grep -q '^SPAWN_EXIT=' "$X/spawn.out" 2>/dev/null && break; sleep 0.02
  done
  [ -n "$P1" ] || { echo "watcher: no slot seen" >"$X/watch.txt"; exit 0; }
  if [ "$MODE" = holder ]; then
    # a foreign process with its cwd in slot 1; it ends by itself after 90 s
    (cd "$P1" && exec python3 -c 'import time; time.sleep(90)') </dev/null >/dev/null 2>&1 &
    echo "$!" >"$X/holder.pid"
  elif [ "$MODE" = base ]; then
    rm -f "$X/project/keep.local"
    printf 'UNIQUE local work, exists only in slot 1\n' >"$P1/keep.local"
  elif [ "$MODE" = dirty ]; then
    printf 'UNIQUE uncommitted work\n' >"$P1/mine.txt"
  elif [ "$MODE" = commit ] || [ "$MODE" = governed ]; then
    printf 'UNIQUE unlanded work\n' >"$P1/mine.txt"
    git -C "$P1" add mine.txt && git "${G[@]}" -C "$P1" commit -qm 'unlanded work' --no-verify
  else
    printf 'UNIQUE local work, exists only in slot 1\n' >"$P1/keep.local"
    git -C "$X/publisher" push -q origin main
  fi
  { echo "watcher: slot=$P1"; echo "watcher: HEAD=$(git -C "$P1" rev-parse HEAD)"; echo "watcher: origin=$(git -C "$X/publisher" rev-parse HEAD)"; } >"$X/watch.txt"
  slot_facts "$P1" >"$X/watch-facts.txt"
) &
tmux -L fm-lab send-keys -t primary "bin/fm-spawn.sh $ID '$X/project' ${MODE_ARGS[*]} --yolo off --backend tmux --harness 'sleep 3600' ${BASE_ARGS[*]:-} > '$X/spawn.out' 2>&1; echo SPAWN_EXIT=\$? >> '$X/spawn.out'" Enter
for _ in $(seq 1 240); do grep -q '^SPAWN_EXIT=' "$X/spawn.out" 2>/dev/null && break; sleep 1; done
wait
P1=$(sed -n 's/^watcher: slot=//p' "$X/watch.txt")
log "-- watcher"; cat "$X/watch.txt" | tee -a "$OUT"
log "-- slot 1 right after the watcher wrote"; cat "$X/watch-facts.txt" 2>&1 | tee -a "$OUT"
[ -s "$X/holder.pid" ] && log "holder pid $(cat "$X/holder.pid") cwd: $(lsof -a -p "$(cat "$X/holder.pid")" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
log "-- fm-spawn.sh output"; cat "$X/spawn.out" 2>&1 | tee -a "$OUT"
log "-- slot 1 AFTER spawn"; slot_facts "$P1" | tee -a "$OUT"
log "provisioner calls: $(cat "$X/provisioner.called" 2>/dev/null || echo none)"
log "-- treehouse status AFTER"; (cd "$X/project" && treehouse status 2>&1) | tee -a "$OUT"
log "-- task meta"; grep -E '^(worktree|branch)=' "$LAB/state/$ID.meta" 2>&1 | tee -a "$OUT"
WT=$(sed -n 's/^worktree=//p' "$LAB/state/$ID.meta" 2>/dev/null)
if [ -n "$WT" ]; then log "-- task copy $WT"; slot_facts "$WT" | tee -a "$OUT"; log "origin tip: $(git -C "$X/publisher" rev-parse HEAD)"; fi
log "-- every pool slot"; for d in "$X"/pool/.treehouse/*/*/project; do log "slot $d"; slot_facts "$d" | tee -a "$OUT"; done
if [ "${LAB_TEARDOWN:-0}" = 1 ]; then # optional: tear the task down and show what happens to the skipped copy
  tmux -L fm-lab send-keys -t primary "bin/fm-teardown.sh $ID > '$X/teardown.out' 2>&1; echo TEARDOWN_EXIT=\$? >> '$X/teardown.out'" Enter
  for _ in $(seq 1 240); do grep -q '^TEARDOWN_EXIT=' "$X/teardown.out" 2>/dev/null && break; sleep 1; done
  log "-- fm-teardown.sh output"; cat "$X/teardown.out" 2>&1 | tee -a "$OUT"
  log "-- slot 1 AFTER teardown"; slot_facts "$P1" | tee -a "$OUT"
  log "-- treehouse status AFTER teardown"; (cd "$X/project" && treehouse status 2>&1) | tee -a "$OUT"
fi
log "-- lab windows"; tmux -L fm-lab list-windows -a -F '#{window_name} #{pane_current_command} #{pane_current_path}' 2>&1 | tee -a "$OUT"
