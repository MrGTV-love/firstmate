#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh + real treehouse (v3.1.7-fm) against a
# disposable Treehouse root, a disposable HOME, disposable git repos and a
# marked fm lab home. Only gh/gh-axi/no-mistakes/docker are hermetic stubs
# (forge and pipeline are not under test; local-only ships never ask a forge).
# A logging shim on PATH records every treehouse call, then execs the real one.
# Usage: live-driver.sh <code-root> <lab-root> <fixture-name> <shape> [extra]
set -u
CODE=$1 L=$2 NAME=$3 SHAPE=$4
REAL_TH=/Users/charlesabrooker/.local/bin/treehouse
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M65CRDNWG84QKWF84BMPJ8KD
F=$L/$NAME
mkdir -p "$F/home" "$F/bin" "$F/thr"
export HOME=$F/home TREEHOUSE_ROOT=$F/thr
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_NOSYSTEM=1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# --- hermetic stubs and the logging shim -----------------------------------
cat > "$F/bin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$F/treehouse.log"
if [ "\${FM_LIVE_NO_POOL_DIR:-}" = 1 ] && [ "\${1:-}" = pool-dir ]; then
  echo 'Error: unknown command "pool-dir" for "treehouse"' >&2; exit 1
fi
exec $REAL_TH "\$@"
SH
cat > "$F/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
cat > "$F/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: pull request not found" >&2; exit 1
SH
cat > "$F/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$F/bin/"*
bash -c '. "$1/tests/lib.sh" >/dev/null 2>&1; fm_fake_docker "$2"' _ "$W" "$F/bin"
export PATH="$F/bin:$PATH"

# --- lab home ---------------------------------------------------------------
eval "$("$W/bin/fm-lab-home.sh" env 2>/dev/null)"
echo "$FM_HOME" > "$F/fm_home"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
touch "$FM_HOME/state/.last-watcher-beat"

# --- repos: origin A (old pool) and origin B (new pool) ---------------------
git init -q --bare -b main "$F/originA.git"
git clone -q "$F/originA.git" "$F/seed" 2>/dev/null
git -C "$F/seed" commit -q --allow-empty -m baseline
git -C "$F/seed" push -q origin main
rm -rf "$F/seed"
git clone -q --bare "$F/originA.git" "$F/originB.git"
mkdir -p "$F/src"
git clone -q "$F/originA.git" "$F/src/backpass"
P=$F/src/backpass
git -C "$P" remote set-head origin main 2>/dev/null || true

get_slot() { (cd "$P" && treehouse get --lease 2>/dev/null </dev/null); }

ID=task-live
# Old pool folder (origin A): two slots, both returned (unleased, like a dead owner).
POOL_A=$(cd "$P" && treehouse pool-dir)
A1=$(get_slot); A2=$(get_slot)
(cd "$P" && treehouse return "$A1" </dev/null >/dev/null 2>&1; treehouse return "$A2" </dev/null >/dev/null 2>&1)

# The task copy lives in old slot 2, on its own branch.
REC=$A2
case "$SHAPE" in current) REC= ;; esac

# Repoint origin: the project's pool moves to a new folder.
git -C "$P" remote set-url origin "$F/originB.git"
POOL_B=$(cd "$P" && treehouse pool-dir)
B1=$(get_slot); B2=$(get_slot); B3=$(get_slot)
(cd "$P" && for s in "$B1" "$B2" "$B3"; do treehouse return "$s" </dev/null >/dev/null 2>&1; done)
[ -n "$REC" ] || REC=$B2

git -C "$REC" checkout -q -b fm/$ID
echo work > "$REC/work.txt"; git -C "$REC" add work.txt; git -C "$REC" commit -q -m "task work"
case "$SHAPE" in
  unlanded) ;;  # commit stays only on the task branch
  *) git -C "$P" merge -q --ff-only fm/$ID ;;
esac
[ "$SHAPE" != dirty ] || echo unsaved > "$REC/unsaved.txt"
printf 'task=%s\nhome=%s\n' "$ID" "$FM_HOME" > "${REC%/*}/.fm-slot-owner"
{
  echo "window=firstmate:fm-$ID"; echo "endpoint_task_id=$ID"; echo "worktree=$REC"
  echo "project=$P"; echo "kind=ship"; echo "mode=local-only"; echo "spawn_gen=live-$ID"; echo "branch=fm/$ID"
} > "$FM_HOME/state/$ID.meta"

# Current-pool leases: slot 1 held by another task; for "stuck" shapes, slot 2
# carries the misdirected by-name lease an earlier teardown took, and slot 3 is
# another reservation this task holds under a different name.
if [ "$SHAPE" != current ]; then
  (cd "$P" && treehouse lease 1 --lease-holder other-task </dev/null >/dev/null)
fi
case "$SHAPE" in
  stuck|unlanded|dirty|nopooldir)
    (cd "$P" && treehouse lease 2 --lease-holder $ID </dev/null >/dev/null)
    (cd "$P" && treehouse lease 3 --lease-holder $ID </dev/null >/dev/null) ;;
  foreign2)
    (cd "$P" && treehouse lease 2 --lease-holder other-task2 </dev/null >/dev/null) ;;
esac
: > "$F/treehouse.log"
{
  echo "POOL_A=$POOL_A"; echo "POOL_B=$POOL_B"; echo "REC=$REC"
  echo "A1=$A1"; echo "A2=$A2"; echo "B1=$B1"; echo "B2=$B2"; echo "B3=$B3"; echo "P=$P"
} > "$F/paths"
echo "fixture $NAME ($SHAPE) ready"
cat "$F/paths"
{
  printf 'export HOME=%q TREEHOUSE_ROOT=%q PATH=%q FM_HOME=%q TMUX_TMPDIR=%q\n' "$HOME" "$TREEHOUSE_ROOT" "$PATH" "$FM_HOME" "$TMUX_TMPDIR"
  printf 'export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_CONFIG_NOSYSTEM=1\n'
  printf 'unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE\n'
} > "$F/env"
