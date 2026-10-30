#!/usr/bin/env bash
# A packed remote-tracking ref whose branch the gate deleted, fetched by a
# confined worker with and without the fm-spawn.sh fetch.prune=false prefix.
set -u
ROOT=$(mktemp -d /tmp/fmlv/prune.XXXX); ROOT=$(cd "$ROOT" && pwd -P)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=Demo -c user.email=demo@example.invalid "$@"; }
H=$ROOT/home P=$H/projects/project W=$ROOT/pool/task GATE=$ROOT/gate.git
mkdir -p "$H/config" "$H/data/task" "$H/state" "$ROOT/pool"; touch "$H/state/task.meta"
g init -q -b main "$P"; g -C "$P" commit -q --allow-empty -m init; g -C "$P" branch fm/gone
g init -q --bare "$GATE"; g -C "$P" remote add no-mistakes "$GATE"; g -C "$P" push -q no-mistakes main fm/gone
g -C "$P" fetch -q no-mistakes; g -C "$P" pack-refs --all        # Main's gc packs refs/remotes/no-mistakes/fm/gone
g -C "$P" worktree add -q -b fm/task "$W" >/dev/null
g -C "$P" config fetch.prune true
git --git-dir "$GATE" update-ref -d refs/heads/fm/gone              # gate deletes the branch
python3 "$1" --worktree "$W" --home "$H" --config "$H/config" --projects "$H/projects" --data "$H/data/task" \
  --state "$H/state" --task task --branch fm/task --harness claude --claude-session 11111111-2222-4333-8444-555555555555 --profile "$ROOT/p.sb" || exit 1
echo "packed-refs has fm/gone: $(grep -c 'refs/remotes/no-mistakes/fm/gone' "$P/.git/packed-refs")"
PREFIX='fm_n=${GIT_CONFIG_COUNT:-0}; export "GIT_CONFIG_KEY_$fm_n=fetch.prune" "GIT_CONFIG_VALUE_$fm_n=false" GIT_CONFIG_COUNT=$((fm_n + 1)); unset fm_n; '
echo "-- confined fetch WITHOUT launch prefix (repo fetch.prune=true)"
/usr/bin/sandbox-exec -f "$ROOT/p.sb" bash -c "cd '$W'; git fetch no-mistakes; echo fetch-exit=\$?" 2>&1 | sed 's/^/   /'
echo "-- confined fetch WITH the fm-spawn.sh launch prefix"
/usr/bin/sandbox-exec -f "$ROOT/p.sb" bash -c "$PREFIX cd '$W'; echo effective-fetch.prune=\$(git config --get fetch.prune); git fetch no-mistakes; echo fetch-exit=\$?" 2>&1 | sed 's/^/   /'
echo "remote-tracking fm/gone still resolves: $(git -C "$P" rev-parse --verify -q refs/remotes/no-mistakes/fm/gone >/dev/null && echo yes || echo no)"
rm -rf "$ROOT"
