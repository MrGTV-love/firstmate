#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh + real treehouse + real git/jq/tmux,
# against a disposable TREEHOUSE_ROOT, a disposable project with two local bare
# origins, and a marked lab FM_HOME. Only no-mistakes/gh/gh-axi are hermetic
# stubs (so the teardown never reaches the operator's real runs or forge).
#
# Usage: live-superseded-pool.sh <bin-dir> <scenario> <work-dir>
#   scenarios: free other-held own-wrong-lease unlanded-commit dirty
#              incident-replay (needs BASE_BIN in env)
set -u
BIN=$1 SCEN=$2 W=$3
ID=live-old-task
mkdir -p "$W"
W=$(cd "$W" && pwd -P)
export TREEHOUSE_ROOT=$W/th
STUBS=$W/stubs; mkdir -p "$STUBS"
cat > "$STUBS/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$STUBS/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cp "$STUBS/gh-axi" "$STUBS/gh"
chmod +x "$STUBS"/*

say() { printf '\n### %s\n' "$*"; }

# --- the project, first on origin A ---
git init -q --bare "$W/origin-a.git"; git init -q --bare "$W/origin-b.git"
git init -q -b main "$W/project"
P=$W/project
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$P" remote add origin "$W/origin-a.git"
git -C "$P" push -q origin main
git -C "$P" fetch -q origin

# --- spawn-like plain treehouse get whose process lease then lapses ---
printf '#!/bin/sh\nexec sleep 300\n' > "$W/sleepsh"; chmod +x "$W/sleepsh"
(cd "$P" && SHELL=$W/sleepsh treehouse get -b fm/$ID </dev/null >"$W/get.log" 2>&1 &)
for _ in $(seq 1 40); do grep -q 'Entered worktree' "$W/get.log" 2>/dev/null && break; sleep 0.25; done
OLD_POOL=$(cd "$P" && treehouse pool-dir)
SLOT=$OLD_POOL/1/project
pkill -9 -f "$W/sleepsh" 2>/dev/null; pkill -9 -f "^sleep 300$" 2>/dev/null
for pid in $(pgrep -f "treehouse get -b fm/$ID"); do kill -9 "$pid" 2>/dev/null; done
sleep 1

# --- the task's work, landed on main (local-only ship) ---
git -C "$SLOT" checkout -q "fm/$ID" 2>/dev/null || git -C "$SLOT" checkout -q --ignore-other-worktrees "fm/$ID"
printf 'work\n' > "$SLOT/work.txt"
git -C "$SLOT" add work.txt
git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q -m 'task work'
case "$SCEN" in
  unlanded-commit) ;;
  *) git -C "$P" merge -q --ff-only "fm/$ID" ;;
esac
[ "$SCEN" != dirty ] || printf 'unfinished\n' > "$SLOT/unfinished.txt"
case "$SCEN" in
  held|held-misdirected)
    # A foreign nested copy (no task record names it) holding unlanded commits.
    printf '.claude/\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$SLOT/.claude/worktrees"
    git -C "$P" worktree add -q -b foreign/work "$SLOT/.claude/worktrees/fc-one" main
    printf 'foreign\n' > "$SLOT/.claude/worktrees/fc-one/foreign.txt"
    git -C "$SLOT/.claude/worktrees/fc-one" add foreign.txt
    git -C "$SLOT/.claude/worktrees/fc-one" -c user.email=t@t -c user.name=t commit -q -m 'foreign unlanded'
    FOREIGN_HEAD_BEFORE=$(git -C "$SLOT/.claude/worktrees/fc-one" rev-parse HEAD)
    ;;
esac

# --- the lab home and the task record, as spawn publishes it ---
printf 'task=%s\nhome=%s\n' "$ID" "$FM_HOME" > "$OLD_POOL/1/.fm-slot-owner"
cat > "$FM_HOME/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
endpoint_task_id=$ID
worktree=$SLOT
project=$P
kind=ship
mode=local-only
spawn_gen=live-$ID
branch=fm/$ID
EOF
printf 'manual\n' > "$FM_HOME/config/backlog-backend"

# --- origin repointed: the project's pool moves to a new folder ---
# (scenario current keeps origin A: the record's copy stays in the current pool)
if [ "$SCEN" != current ]; then
git -C "$P" remote set-url origin "$W/origin-b.git"
git -C "$P" push -q origin main
fi
NEW_POOL=$(cd "$P" && treehouse pool-dir)
if [ "$SCEN" != current ]; then
N1=$(cd "$P" && treehouse get --lease --lease-holder seed </dev/null 2>/dev/null)
N2=$(cd "$P" && treehouse get --lease --lease-holder seed </dev/null 2>/dev/null)
(cd "$P" && treehouse return "$N1" </dev/null >/dev/null 2>&1)
(cd "$P" && treehouse return "$N2" </dev/null >/dev/null 2>&1)
fi
case "$SCEN" in
  other-held) (cd "$P" && treehouse lease 1 --lease-holder other-task </dev/null >/dev/null) ;;
  own-wrong-lease) (cd "$P" && treehouse lease 1 --lease-holder "$ID" </dev/null >/dev/null) ;;
  held-misdirected) (cd "$P" && treehouse lease 1 --lease-holder "$ID" </dev/null >/dev/null) ;;
  own-wrong-lease-busy)
    (cd "$P" && treehouse lease 1 --lease-holder "$ID" </dev/null >/dev/null)
    (cd "$N1" && exec -a fm-live-busy sleep 600 </dev/null >/dev/null 2>&1 &) ;;
esac

say "setup ($SCEN)"
echo "old pool folder (record's copy): $OLD_POOL"
echo "current pool folder (pool-dir):  $NEW_POOL"
echo "record worktree=$SLOT"
echo "-- treehouse status from the project (current pool):"
(cd "$P" && treehouse status)
echo "-- old folder state:"
jq -c '.worktrees[] | {name, path, leased, lease_holder, owner_pid}' "$OLD_POOL/treehouse-state.json"
cp "$NEW_POOL/treehouse-state.json" "$W/current-before.json"

run_td() {  # <bin-dir> <label>
  local rc=0
  say "run $2: $1/fm-teardown.sh $ID"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$FM_HOME" TMUX_TMPDIR="$TMUX_TMPDIR" TREEHOUSE_ROOT="$TREEHOUSE_ROOT" \
    PATH="$STUBS:$PATH" "$1/fm-teardown.sh" "$ID" > "$W/$2.out" 2>&1 || rc=$?
  sed "s#$W#<W>#g" "$W/$2.out" | tail -25
  echo "exit=$rc"
  return 0
}

if [ "$SCEN" = incident-replay ]; then
  run_td "$BASE_BIN" base-first
  echo "-- current pool after base teardown #1:"; (cd "$P" && treehouse status)
  run_td "$BASE_BIN" base-second
  echo "-- current pool after base teardown #2:"; (cd "$P" && treehouse status)
  cp "$NEW_POOL/treehouse-state.json" "$W/current-before.json"
fi
run_td "$BIN" new

pkill -f '^fm-live-busy' 2>/dev/null
say "after ($SCEN)"
echo "-- treehouse status from the project (current pool):"
(cd "$P" && treehouse status)
echo "-- current pool state byte-identical to before the new teardown?"
if cmp -s "$W/current-before.json" "$NEW_POOL/treehouse-state.json"; then echo "IDENTICAL"; else echo "CHANGED:"; diff <(jq -S . "$W/current-before.json") <(jq -S . "$NEW_POOL/treehouse-state.json"); fi
echo "-- old folder state:"
jq -c '.worktrees[] | {name, path, leased, lease_holder, owner_pid}' "$OLD_POOL/treehouse-state.json"
echo "-- task record present? $([ -e "$FM_HOME/state/$ID.meta" ] && echo yes || echo no)"
echo "-- old copy: $(git -C "$SLOT" status --porcelain 2>&1 | tr '\n' ' ') HEAD=$(git -C "$SLOT" rev-parse --abbrev-ref HEAD 2>&1)"
echo "-- old slot claim: $(cat "$OLD_POOL/1/.fm-slot-owner" 2>/dev/null | tr '\n' ' ' || echo absent)"
case "$SCEN" in
  held|held-misdirected)
    echo "-- foreign held copy: $( [ -d "$SLOT/.claude/worktrees/fc-one" ] && echo present || echo GONE ) HEAD unchanged? $( [ "$(git -C "$SLOT/.claude/worktrees/fc-one" rev-parse HEAD 2>/dev/null)" = "$FOREIGN_HEAD_BEFORE" ] && echo yes || echo NO )"
    echo "-- old slot still exists? $([ -d "$SLOT" ] && echo yes || echo no)"
    ;;
esac
