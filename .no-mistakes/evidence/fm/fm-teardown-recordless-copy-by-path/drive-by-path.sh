#!/usr/bin/env bash
# Live driver for `bin/fm-teardown.sh --copy <path>` against a disposable lab home.
# Usage: drive-by-path.sh <worktree> <evidence-dir>
# Builds a marked lab home (bin/fm-lab-home.sh env), one bare origin, one project clone under
# $FM_HOME/projects, and record-less nested worktrees under <clone>/.claude/worktrees/<name>.
# Forge CLIs, herdr and treehouse are shadowed by logging stubs so no external service is reached;
# git is wrapped only to log `worktree remove` calls before running the real git.
set -u
WT=$1
EV=$2
cd "$WT" || exit 1
eval "$(bin/fm-lab-home.sh env 2>"$EV/lab-env.stderr")"
LAB=$FM_HOME
echo "lab home: $LAB"
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-bp-fake.XXXXXX")
REAL_GIT=$(command -v git)
for t in gh gh-axi; do printf '#!/usr/bin/env bash\necho "%s stub: offline" >&2\nexit 1\n' "$t" > "$FAKE/$t"; done
printf '#!/usr/bin/env bash\nexit 126\n' > "$FAKE/herdr"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/treehouse.log"\nexit 0\n' "$FAKE" > "$FAKE/treehouse"
cat > "$FAKE/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree remove "*) printf '%s\n' "\$*" >> "$FAKE/git-remove.log" ;; esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@lab GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@lab

ORIGIN=$LAB/origin.git
git init -q --bare -b main "$ORIGIN"
CLONE=$LAB/projects/proj
git clone -q "$ORIGIN" "$CLONE" 2>/dev/null
git -C "$CLONE" commit -q --allow-empty -m base
git -C "$CLONE" push -q origin main
git -C "$CLONE" remote set-head origin main
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
CLONE=$(cd "$CLONE" && pwd -P)

mkcopy() { # <name> -> prints canonical copy path
  local p=$CLONE/.claude/worktrees/$1
  mkdir -p "${p%/*}"
  git -C "$CLONE" worktree add -q -b "fm/$1" "$p" main 2>/dev/null
  (cd "$p" && pwd -P)
}
registered() { git -C "$CLONE" worktree list --porcelain | grep -Fqx "worktree $1"; }
TD() { # run the product exactly as an operator would, plain FM_HOME, from the worktree
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" bin/fm-teardown.sh "$@"
}
show() { # <label> <cmd...>
  local label=$1 rc; shift
  echo
  echo "=== $label"
  echo "\$ $*"
  "$@" > "$FAKE/out" 2> "$FAKE/err"; rc=$?
  sed 's/^/stdout: /' "$FAKE/out"; sed 's/^/stderr: /' "$FAKE/err"
  echo "exit=$rc"
  return $rc
}
state() { # <copy>
  echo "  present=$([ -e "$1" ] && echo yes || echo no) registered=$(registered "$1" && echo yes || echo no) remove-calls=$(wc -l < "$FAKE/git-remove.log" 2>/dev/null | tr -d ' ' || echo 0) treehouse-calls=$([ -s "$FAKE/treehouse.log" ] && wc -l < "$FAKE/treehouse.log" | tr -d ' ' || echo 0)"
}

echo "##### S1 landed record-less copy is removed"
C1=$(mkcopy landed)
show "S1 base-red: ordinary teardown by id has no record" TD landed
show "S1 teardown --copy landed copy" TD --copy "$C1"; state "$C1"
echo "  clone .git present=$([ -e "$CLONE/.git" ] && echo yes) main=$(git -C "$CLONE" rev-parse --short main)"
echo "  audit log:"; sed 's/^/    /' "$LAB/data/record-less-copy-removals.log"
echo "  git-remove.log:"; sed 's/^/    /' "$FAKE/git-remove.log"

echo; echo "##### S2 rerun on gone copy converges"
show "S2 rerun teardown --copy on gone copy" TD --copy "$C1"; state "$C1"
echo "  audit lines=$(wc -l < "$LAB/data/record-less-copy-removals.log" | tr -d ' ')"

echo; echo "##### S3 --force / --drop-file / relative path refused"
C3=$(mkcopy forcey)
show "S3 --force" TD --copy "$C3" --force; state "$C3"
show "S3 --drop-file" TD --copy "$C3" --drop-file /tmp/x; state "$C3"
show "S3 relative path" TD --copy "projects/proj/.claude/worktrees/forcey"; state "$C3"

echo; echo "##### S4 unlanded commit, no bundle"
C4=$(mkcopy unlanded)
printf 'work\n' > "$C4/work.txt"; git -C "$C4" add work.txt; git -C "$C4" commit -qm unpublished
show "S4 unlanded no bundle" TD --copy "$C4" --record-id rec-unl; state "$C4"

echo; echo "##### S5 bundle-held copy: refused without captain call, removed after the printed hold"
mkdir -p "$LAB/bundles" "$LAB/data/rec-unl"
git -C "$C4" bundle create "$LAB/bundles/w.bundle" --all 2>/dev/null
git -C "$C4" bundle verify "$LAB/bundles/w.bundle" >/dev/null 2>&1 && echo "  bundle verifies"
dig=$(shasum -a 256 "$LAB/bundles/w.bundle" | awk '{print $1}')
tips=$(git bundle list-heads "$LAB/bundles/w.bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
printf '%s\t%s\t%s\n' "$LAB/bundles/w.bundle" "$dig" "$tips" > "$LAB/data/rec-unl/preservation-bundles.tsv"
show "S5 bundle recorded, no captain call" TD --copy "$C4" --record-id rec-unl; state "$C4"
cmd=$(sed -n 's/^File the land-or-drop call as its row, then run the same teardown --copy command again: //p' "$FAKE/err")
echo "  printed hold command: $cmd"
if [ -n "$cmd" ]; then
  show "S5 run the printed hold command" env FM_HOME="$LAB" bash -c "$cmd"
fi
show "S5 teardown --copy after the call is filed" TD --copy "$C4" --record-id rec-unl; state "$C4"
st="$LAB/data/rec-unl/preserved-bundles/$dig.bundle"
echo "  stored bundle present=$([ -f "$st" ] && echo yes || echo no)"
git -C "$CLONE" fetch -q "$st" "fm/unlanded:refs/heads/recovered" 2>/dev/null && echo "  restored tip from stored bundle: $(git -C "$CLONE" log -1 --format='%h %s' recovered)"

echo; echo "##### S6 dirty tree refused"
C6=$(mkcopy dirty); printf 'x\n' > "$C6/untracked.txt"
show "S6 untracked file" TD --copy "$C6"; state "$C6"

echo; echo "##### S7 process in copy refused, not signalled"
C7=$(mkcopy busy)
(cd "$C7" && exec sleep 300) & pid=$!
sleep 1
show "S7 process cwd in copy" TD --copy "$C7"; state "$C7"
kill -0 $pid 2>/dev/null && echo "  holder pid $pid still alive (not signalled)"
kill $pid; wait $pid 2>/dev/null
show "S7 after holder exits" TD --copy "$C7"; state "$C7"

echo; echo "##### S8 copy a live task record names refused"
C8=$(mkcopy named)
printf 'worktree=%s\nkind=ship\n' "$C8" > "$LAB/state/livetask.meta"
show "S8 live record names copy" TD --copy "$C8"; state "$C8"
rm -f "$LAB/state/livetask.meta"

echo; echo "##### S9 bare repository with unpushed commit under .claude refused"
C9=$(mkcopy barey)
mkdir -p "$C9/.claude"
printf '.claude/\n' >> "$(git -C "$C9" rev-parse --path-format=absolute --git-path info/exclude)"
git init -q --bare "$C9/.claude/hidden.git"
tmpc=$(mktemp -d "${TMPDIR:-/tmp}/fm-bp-src.XXXXXX"); git -C "$tmpc" init -q; git -C "$tmpc" commit -q --allow-empty -m secret
git -C "$tmpc" push -q "$C9/.claude/hidden.git" HEAD:refs/heads/main; rm -rf "$tmpc"
show "S9 bare repo under .claude" TD --copy "$C9"; state "$C9"

echo; echo "##### S10 .claude preserved whole before removal"
C10=$(mkcopy keepclaude)
mkdir -p "$C10/.claude"; printf '.claude/\n' >> "$(git -C "$C10" rev-parse --path-format=absolute --git-path info/exclude)"
printf 'my notes\n' > "$C10/.claude/notes.md"
show "S10 copy with ignored .claude" TD --copy "$C10" --record-id rec-keep; state "$C10"
echo "  preserved tree:"; (cd "$LAB/data/rec-keep" 2>/dev/null && find . -type f | sed 's/^/    /')
f=$(find "$LAB/data/rec-keep" -name notes.md 2>/dev/null | head -1); [ -n "$f" ] && echo "  preserved notes.md content: $(cat "$f")"

echo; echo "##### S11 two simultaneous runs on one copy"
C11=$(mkcopy race)
: > "$FAKE/git-remove.log"
TD --copy "$C11" > "$FAKE/r1.out" 2> "$FAKE/r1.err" & p1=$!
TD --copy "$C11" > "$FAKE/r2.out" 2> "$FAKE/r2.err" & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
echo "run1 exit=$r1"; sed 's/^/  run1: /' "$FAKE/r1.err"
echo "run2 exit=$r2"; sed 's/^/  run2: /' "$FAKE/r2.err"
state "$C11"

echo; echo "##### S12 path that is not a registered nested worktree refused"
mkdir -p "$CLONE/.claude/worktrees/plain"
show "S12 plain directory" TD --copy "$CLONE/.claude/worktrees/plain"
show "S12 the clone itself" TD --copy "$CLONE"; echo "  clone present=$([ -d "$CLONE/.git" ] && echo yes)"

echo; echo "##### final registered worktrees"
git -C "$CLONE" worktree list
echo "treehouse calls: $(cat "$FAKE/treehouse.log" 2>/dev/null | wc -l | tr -d ' ')"

echo; echo "##### teardown"
rm -rf "$FAKE"
teardown_line=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/lab-env.stderr")
echo "\$ $teardown_line"
eval "$teardown_line" && echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
