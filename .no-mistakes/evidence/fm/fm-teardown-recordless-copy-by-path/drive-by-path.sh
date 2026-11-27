#!/usr/bin/env bash
# Live drive of `bin/fm-teardown.sh --copy` against a disposable, marked lab home.
# Usage: drive-by-path.sh <worktree> <teardown-script-dir-for-base-red-check>
# Every repository here is real git; the only stand-ins are logging shims for the
# external provider CLIs (treehouse, no-mistakes, gh, gh-axi) so the run cannot reach
# a real pool, daemon or forge, and so a call to them is counted.
set -u
WT=$1
BASE_BIN=$2
cd "$WT" || exit 1
TD="$WT/bin/fm-teardown.sh"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN_LINE=$(sed -n 's/^fm-lab-home: teardown: //p' /tmp/fm-lab-env.$$); rm -f /tmp/fm-lab-env.$$
LAB=$FM_HOME
SIDE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-side.XXXXXX")
SIDE=$(cd "$SIDE" && pwd -P)
echo "# lab FM_HOME=$LAB"
echo "# side dir (origin, shims) = $SIDE"
FAKE=$SIDE/fakebin; mkdir -p "$FAKE"
for t in treehouse no-mistakes gh gh-axi; do
  cat > "$FAKE/$t" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$t" "\$*" >> "$SIDE/provider-calls.log"
exit 0
SH
  chmod +x "$FAKE/$t"
done
# git shim: counts every `worktree remove`, then runs real git.
REALGIT=$(command -v git)
cat > "$FAKE/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree remove "*) printf '%s\n' "\$*" >> "$SIDE/git-remove.log" ;; esac
exec "$REALGIT" "\$@"
SH
chmod +x "$FAKE/git"
G() { "$REALGIT" -c user.email=lab@lab -c user.name=lab "$@"; }

# Real origin + real project clone inside the lab home's projects/.
G init -q --bare "$SIDE/origin.git"; G -C "$SIDE/origin.git" symbolic-ref HEAD refs/heads/main
G clone -q "$SIDE/origin.git" "$SIDE/seed" 2>/dev/null
printf 'landed\n' > "$SIDE/seed/README"; G -C "$SIDE/seed" add README; G -C "$SIDE/seed" commit -qm baseline; G -C "$SIDE/seed" push -q origin main
G clone -q "$SIDE/origin.git" "$LAB/projects/proj"; G -C "$LAB/projects/proj" remote set-head origin main
CLONE=$(cd "$LAB/projects/proj" && pwd -P)
mkdir -p "$CLONE/.claude/worktrees"

newcopy() {  # <name> -> prints canonical copy path
  G -C "$CLONE" worktree add -q -b "fm/$1" "$CLONE/.claude/worktrees/$1" main
  printf '%s\n' "$CLONE/.claude/worktrees/$1"
}
registered() { "$REALGIT" -C "$CLONE" worktree list --porcelain | grep -Fqx "worktree $1"; }
state() {  # <copy>
  local s=present; [ -e "$1" ] || s=gone
  local r=unregistered; registered "$1" && r=registered
  echo "  -> copy: $s, $r; git-worktree-remove calls so far: $(wc -l < "$SIDE/git-remove.log" 2>/dev/null | tr -d ' ' || echo 0); provider calls: $(cat "$SIDE/provider-calls.log" 2>/dev/null | wc -l | tr -d ' ')"
}
run() {  # <label> <args...>
  local label=$1; shift
  echo; echo "=== $label"
  echo "\$ FM_HOME=\$LAB bin/fm-teardown.sh $*"
  local rc=0
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" PATH="$FAKE:$PATH" "$TD" "$@" > "$SIDE/out" 2> "$SIDE/err" || rc=$?
  sed 's/^/  stdout| /' "$SIDE/out"; sed 's/^/  stderr| /' "$SIDE/err"
  echo "  rc=$rc"
  LAST_RC=$rc
}

echo; echo "##### S0 baseline (base commit d25e907): a record-less copy cannot be removed at all"
C0=$(newcopy base-red)
rc=0; env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$FAKE:$PATH" "$BASE_BIN/fm-teardown.sh" --copy "$C0" > "$SIDE/out" 2> "$SIDE/err" || rc=$?
echo "\$ <base>/bin/fm-teardown.sh --copy $C0"; sed 's/^/  stderr| /' "$SIDE/err"; echo "  rc=$rc"
rc=0; env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$FAKE:$PATH" "$BASE_BIN/fm-teardown.sh" base-red > "$SIDE/out" 2> "$SIDE/err" || rc=$?
echo "\$ <base>/bin/fm-teardown.sh base-red"; sed 's/^/  stderr| /' "$SIDE/err"; echo "  rc=$rc"
state "$C0"

echo; echo "##### S1 landed record-less copy is removed"
run "S1 landed copy (head on origin/main), project clone" --copy "$C0"
state "$C0"
echo "  audit log:"; sed 's/^/    | /' "$LAB/data/record-less-copy-removals.log" 2>/dev/null
echo "  git-remove.log:"; sed 's/^/    | /' "$SIDE/git-remove.log" 2>/dev/null
echo "  clone still a repo: $("$REALGIT" -C "$CLONE" rev-parse --is-inside-work-tree)"

echo; echo "##### S1b rerun on the removed copy converges"
run "S1b rerun on already-removed copy" --copy "$C0"
state "$C0"

echo; echo "##### S3 --force and friends refused by name"
C3=$(newcopy forceme)
for f in --force --drop-file --legacy-record; do run "S3 flag $f" --copy "$C3" $f; done
run "S3 relative path" --copy relative/path
state "$C3"

echo; echo "##### S4 unlanded commit, no bundle -> refused"
C4=$(newcopy unlanded); printf 'work\n' > "$C4/work.txt"; G -C "$C4" add work.txt; G -C "$C4" commit -qm unpublished
run "S4 unlanded, no bundle" --copy "$C4"
state "$C4"

echo; echo "##### S2 bundle-held copy: refuse without captain row, then removed after the printed hold command"
ID=rec-bundle
mkdir -p "$LAB/data/$ID" "$SIDE/bundles"
G -C "$C4" bundle create "$SIDE/bundles/work.bundle" --all 2>/dev/null
G -C "$C4" bundle verify "$SIDE/bundles/work.bundle" >/dev/null 2>&1 && echo "  bundle verifies"
dg=$(shasum -a 256 "$SIDE/bundles/work.bundle" | awk '{print $1}')
tips=$("$REALGIT" bundle list-heads "$SIDE/bundles/work.bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
printf '%s\t%s\t%s\n' "$SIDE/bundles/work.bundle" "$dg" "$tips" > "$LAB/data/$ID/preservation-bundles.tsv"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
run "S2 bundle recorded, no captain row" --copy "$C4" --record-id "$ID"
state "$C4"
cmd=$(sed -n 's/^File the land-or-drop call as its row, then run the same teardown --copy command again: //p' "$SIDE/err")
echo "  printed hold command: $cmd"
if [ -n "$cmd" ]; then
  ( env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" PATH="$FAKE:$PATH" bash -c "$cmd" ) > "$SIDE/hold.out" 2>&1; echo "  hold rc=$?"; sed 's/^/  hold| /' "$SIDE/hold.out"
fi
run "S2 bundle recorded, captain row filed" --copy "$C4" --record-id "$ID"
state "$C4"
echo "  stored bundle:"; ls -1 "$LAB/data/$ID/preserved-bundles/" 2>/dev/null | sed 's/^/    | /'
st=$(ls -1 "$LAB/data/$ID/preserved-bundles/"*.bundle 2>/dev/null | head -1)
[ -n "$st" ] && G -C "$CLONE" fetch -q "$st" "fm/unlanded:refs/heads/recovered" 2>/dev/null && echo "  restored from stored bundle: $("$REALGIT" -C "$CLONE" log -1 --format=%s refs/heads/recovered)"

echo; echo "##### S5 dirty tree -> refused"
C5=$(newcopy dirty); printf 'x\n' >> "$C5/README"
run "S5 tracked edit" --copy "$C5"
state "$C5"
printf 'new\n' > "$C5/untracked.txt"; G -C "$C5" checkout -q -- README
run "S5 untracked file" --copy "$C5"
state "$C5"
rm -f "$C5/untracked.txt"

echo; echo "##### S6 a process in the copy -> refused, never signalled"
C6=$(newcopy busy)
( cd "$C6" && exec sleep 300 ) & HOLDER=$!
sleep 1
run "S6 process cwd in copy" --copy "$C6"
state "$C6"
kill -0 "$HOLDER" 2>/dev/null && echo "  holder pid $HOLDER still alive (not signalled)"
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null
run "S6 same copy once idle" --copy "$C6"
state "$C6"

echo; echo "##### S7 a live task record names the copy -> refused"
C7=$(newcopy recorded)
printf '%s\n' window=firstmate:fm-task-live endpoint_task_id=task-live "worktree=$C7" "project=$CLONE" kind=ship mode=no-mistakes spawn_gen=lab > "$LAB/state/task-live.meta"
run "S7 live record names copy" --copy "$C7"
state "$C7"
rm -f "$LAB/state/task-live.meta"

echo; echo "##### S8 not a registered nested worktree -> refused"
mkdir -p "$CLONE/.claude/worktrees/plain-dir"
run "S8 unregistered directory" --copy "$CLONE/.claude/worktrees/plain-dir"
run "S8 the clone itself" --copy "$CLONE"
run "S8 path outside the home" --copy "$SIDE"
G -C "$CLONE" status --porcelain >/dev/null && echo "  clone intact"

echo; echo "##### S9 another Git repository inside the copy (ignored .claude) -> refused"
C9=$(newcopy nested)
printf '.claude/\n' >> "$C9/.git/../.gitignore" 2>/dev/null
G -C "$C9" add .gitignore; G -C "$C9" commit -qm ignore-claude; G -C "$C9" push -q origin "fm/nested:main"
G -C "$CLONE" fetch -q origin
mkdir -p "$C9/.claude"; G init -q "$C9/.claude/inner"; printf 'z\n' > "$C9/.claude/inner/f"; G -C "$C9/.claude/inner" add f; G -C "$C9/.claude/inner" commit -qm inner
run "S9 nested clone under ignored .claude" --copy "$C9"
state "$C9"
rm -rf "$C9/.claude/inner"
G init -q --bare "$C9/.claude/bare.git"
run "S9 untracked bare repository under ignored .claude" --copy "$C9"
state "$C9"
rm -rf "$C9/.claude/bare.git"

echo; echo "##### S10 .claude preserved whole, then copy removed"
mkdir -p "$C9/.claude"; printf 'session notes\n' > "$C9/.claude/notes.md"
run "S10 ignored .claude content" --copy "$C9" --record-id rec-claude
state "$C9"
echo "  preserved tree:"; (cd "$LAB/data/rec-claude" 2>/dev/null && find . -type f | sort | sed 's/^/    | /')
f=$(find "$LAB/data/rec-claude" -name notes.md 2>/dev/null | head -1); [ -n "$f" ] && echo "  preserved notes.md content: $(cat "$f")"

echo; echo "##### S11 Vernant creation lock with a refused ps -> refused (fail closed)"
C11=$(newcopy locked)
sleep 300 & LAUNCHER=$!
G -C "$CLONE" worktree lock --reason "vernant-session-active owner=lab launcher=$LAUNCHER" "$C11"
mkdir -p "$SIDE/ps126"; printf '#!/bin/sh\necho "ps: operation not permitted" >&2\nexit 126\n' > "$SIDE/ps126/ps"; chmod +x "$SIDE/ps126/ps"
echo; echo "=== S11 locked copy, ps refused (126)"
rc=0; env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$SIDE/ps126:$FAKE:$PATH" "$TD" --copy "$C11" > "$SIDE/out" 2> "$SIDE/err" || rc=$?
sed 's/^/  stderr| /' "$SIDE/err"; echo "  rc=$rc"
state "$C11"
kill -0 "$LAUNCHER" 2>/dev/null && echo "  launcher pid $LAUNCHER still alive (not signalled)"
kill "$LAUNCHER"; wait "$LAUNCHER" 2>/dev/null

echo; echo "##### S12 two simultaneous runs on one copy"
C12=$(newcopy race)
cat > "$SIDE/slowgit" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree remove "*) printf '%s\n' "\$*" >> "$SIDE/git-remove.log"; sleep 4 ;; esac
exec "$REALGIT" "\$@"
SH
mkdir -p "$SIDE/slow"; mv "$SIDE/slowgit" "$SIDE/slow/git"; chmod +x "$SIDE/slow/git"
before=$(wc -l < "$SIDE/git-remove.log" | tr -d ' ')
( env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$SIDE/slow:$FAKE:$PATH" "$TD" --copy "$C12" > "$SIDE/r1.out" 2> "$SIDE/r1.err"; echo $? > "$SIDE/r1.rc" ) &
P1=$!
for i in $(seq 1 100); do [ "$(wc -l < "$SIDE/git-remove.log" | tr -d ' ')" -gt "$before" ] && break; sleep 0.1; done
( env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$SIDE/slow:$FAKE:$PATH" "$TD" --copy "$C12" > "$SIDE/r2.out" 2> "$SIDE/r2.err"; echo $? > "$SIDE/r2.rc" )
wait $P1
echo "  run1 rc=$(cat "$SIDE/r1.rc")"; sed 's/^/  run1 stderr| /' "$SIDE/r1.err"
echo "  run2 rc=$(cat "$SIDE/r2.rc")"; sed 's/^/  run2 stderr| /' "$SIDE/r2.err"
echo "  worktree remove calls for race copy: $(grep -c "$C12" "$SIDE/git-remove.log")"
state "$C12"

echo; echo "##### final audit log"
sed 's/^/  | /' "$LAB/data/record-less-copy-removals.log"
echo; echo "##### provider calls (treehouse/no-mistakes/gh/gh-axi): $(cat "$SIDE/provider-calls.log" 2>/dev/null | wc -l | tr -d ' ')"
sed 's/^/  | /' "$SIDE/provider-calls.log" 2>/dev/null

echo; echo "##### teardown of the lab"
G -C "$CLONE" worktree list | sed 's/^/  remaining | /'
eval "$TEARDOWN_LINE" && echo "  lab removed: $LAB"
rm -rf "$SIDE" && echo "  side dir removed"
