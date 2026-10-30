#!/usr/bin/env bash
# Live demo: a worker tree inside the real Seatbelt profile tries to forge
# another task's packed branch, then runs the normal git work a worker needs.
# Usage: demo.sh <builder.py> <label>
set -u
BUILDER=$1 LABEL=$2
ROOT=$(mktemp -d /tmp/fmlv/run-$LABEL.XXXX); ROOT=$(cd "$ROOT" && pwd -P)
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=Demo -c user.email=demo@example.invalid "$@"; }
H=$ROOT/home P=$H/projects/project W=$ROOT/pool/task GATE=$ROOT/gate.git
mkdir -p "$H/config" "$H/data/task" "$H/state" "$ROOT/pool" "$ROOT/tmp"
touch "$H/state/task.meta" "$H/state/other.meta"
g init -q -b main "$P"; g -C "$P" commit -q --allow-empty -m init
g -C "$P" branch fm/other
g -C "$P" commit -q --allow-empty -m second            # main moves on
REAL=$(g -C "$P" rev-parse fm/other); FORGED=$(g -C "$P" rev-parse main)
g -C "$P" pack-refs --all                              # fm/other now lives only in packed-refs
g -C "$P" worktree add -q -b fm/task "$W" >/dev/null
g init -q --bare "$GATE"; g -C "$P" push -q "$GATE" main fm/other
g -C "$W" remote add no-mistakes "$GATE"
g -C "$P" config fetch.prune true                      # stands in for a host fetch.prune=true
PROFILE=$ROOT/profile.sb
python3 "$BUILDER" --worktree "$W" --home "$H" --config "$H/config" --projects "$H/projects" \
  --data "$H/data/task" --state "$H/state" --task task --branch fm/task --harness claude --claude-session 11111111-2222-4333-8444-555555555555 --profile "$PROFILE" || { echo "builder failed"; exit 1; }
echo "== $LABEL builder: $BUILDER"
echo "fm/other real=$REAL forged-target=$FORGED"
echo "loose fm/other file present: $([ -e "$P/.git/refs/heads/fm/other" ] && echo yes || echo no)"
C=$P/.git
# The same prefix fm-spawn.sh puts in front of a confined launch.
PREFIX='fm_n=${GIT_CONFIG_COUNT:-0}; export "GIT_CONFIG_KEY_$fm_n=fetch.prune" "GIT_CONFIG_VALUE_$fm_n=false" GIT_CONFIG_COUNT=$((fm_n + 1)); unset fm_n; '
cat > "$ROOT/worker.sh" <<EOF
cd "$W"
g() { git -c user.name=Worker -c user.email=w@example.invalid "\$@"; }
step() { printf -- '-- %s\n' "\$1"; }
step "attack 1: overwrite packed-refs by name"
printf '# pack-refs with: peeled fully-peeled sorted \n$FORGED refs/heads/fm/other\n$FORGED refs/heads/main\n' > "$C/packed-refs" && echo "write exit 0" || echo "write refused"
echo "primary fm/other -> \$(git -C "$P" rev-parse fm/other)"
step "attack 2: write packed-refs.lock then rename it over packed-refs"
{ printf '# pack-refs with: peeled fully-peeled sorted \n$FORGED refs/heads/fm/other\n' > "$C/packed-refs.lock" && mv -f "$C/packed-refs.lock" "$C/packed-refs"; } && echo "rename exit 0" || echo "rename refused"
rm -f "$C/packed-refs.lock"
echo "primary fm/other -> \$(git -C "$P" rev-parse fm/other)"
step "attack 3: git branch -D fm/other"
g branch -D fm/other 2>&1 | sed 's/^/   /'
echo "primary fm/other -> \$(git -C "$P" rev-parse fm/other)"
step "attack 4: write commondir"
echo /tmp > "$C/commondir" && echo "commondir exit 0" || echo "commondir refused"
step "work: commit in own worktree"
echo hi > file; g add file; g commit -q -m work && echo "commit ok"
step "work: create own archive ref"
g branch archive/task-submitted-0123abcd && echo "archive create ok"
step "work: push to gate"
g push -q no-mistakes fm/task 2>&1 && echo "push ok"
step "work: stash push + pop"
echo change > file; g stash push -q -m w && g stash pop -q && echo "stash ok (file=\$(cat file))"
git checkout -q -- file
step "work: gate deletes fm/other, then plain fetch (fetch.prune true in repo config)"
git --git-dir "$GATE" update-ref -d refs/heads/fm/other
echo "effective fetch.prune=\$(git config --get fetch.prune)"
g fetch no-mistakes 2>&1 | sed 's/^/   /'; echo "fetch exit=\${PIPESTATUS[0]}"
EOF
echo "-- running worker inside: sandbox-exec -f profile.sb"
/usr/bin/sandbox-exec -f "$PROFILE" bash -c "$PREFIX bash $ROOT/worker.sh" 2>&1
echo "== after: primary checkout view (unconfined)"
if [ -e "$C/commondir" ]; then echo "commondir file was planted by the worker: $(cat "$C/commondir") (removed now so the primary can be read)"; rm -f "$C/commondir"; else echo "no commondir file planted"; fi
echo "git -C project rev-parse fm/other -> $(git -C "$P" rev-parse fm/other)"
if [ "$(git -C "$P" rev-parse fm/other)" = "$REAL" ]; then echo "RESULT: fm/other kept its real SHA"; else echo "RESULT: fm/other FORGED"; fi
echo "gate fm/task -> $(git --git-dir "$GATE" rev-parse --verify -q refs/heads/fm/task || echo missing)"
echo "own archive -> $(git -C "$P" rev-parse --verify -q refs/heads/archive/task-submitted-0123abcd || echo missing)"
rm -rf "$ROOT"
