#!/usr/bin/env bash
# Live driver, part 2: fail-closed guards of `bin/fm-teardown.sh --copy`.
# Usage: drive-by-path-guards.sh <worktree> <evidence-dir>
# G1 Vernant creation lock, live launcher, ps refused (exit 126) for that pid -> kept.
# G2 same lock, launcher proved gone by the real ps -> released via the clone's closeout driver.
# G3 preserve of .claude cannot publish -> copy kept; printed completing command finishes it once fixed.
# G4 an unreadable clone in projects/ -> "could not read", for a present copy.
# The ps stub answers only `ps -p <launcher> -o pid=` and passes every other call to the real ps.
# The closeout driver is a stand-in script placed in the clone (the real Vernant driver is another project).
set -u
WT=$1
EV=$2
cd "$WT" || exit 1
eval "$(bin/fm-lab-home.sh env 2>"$EV/guards-lab-env.stderr")"
LAB=$FM_HOME
echo "lab home: $LAB"
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-bpg-fake.XXXXXX")
REAL_GIT=$(command -v git)
REAL_PS=$(command -v ps)
for t in gh gh-axi; do printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/$t"; done
printf '#!/usr/bin/env bash\nexit 126\n' > "$FAKE/herdr"
cat > "$FAKE/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree remove "*) printf '%s\n' "\$*" >> "$FAKE/git-remove.log" ;; esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH" GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@lab GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@lab
git init -q --bare -b main "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$LAB/projects/proj" 2>/dev/null
CLONE=$(cd "$LAB/projects/proj" && pwd -P)
git -C "$CLONE" commit -q --allow-empty -m base; git -C "$CLONE" push -q origin main
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
# closeout driver stand-in (ignored by the clone, so the clone stays clean)
printf 'scripts/\n.claude/\n' >> "$(git -C "$CLONE" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$CLONE/scripts/git-stability"
cat > "$CLONE/scripts/git-stability/closeout_pr.py" <<SH
if [ "\${3:-}" != --execute-cleanup ]; then printf '%s|%s\n' "\$PWD" "\$*" >> "$FAKE/closeout-plan.log"; echo '{"allowed": true}'; exit 0; fi
printf '%s|%s\n' "\$PWD" "\$*" >> "$FAKE/closeout.log"
git worktree unlock "\$2" && git worktree remove "\$2"
SH
printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$FAKE/vernant-python"; chmod +x "$FAKE/vernant-python"

mkcopy() { local p=$CLONE/.claude/worktrees/$1; mkdir -p "${p%/*}"; git -C "$CLONE" worktree add -q -b "fm/$1" "$p" main 2>/dev/null; (cd "$p" && pwd -P); }
registered() { git -C "$CLONE" worktree list --porcelain | grep -Fqx "worktree $1"; }
locked() { git -C "$CLONE" worktree list --porcelain | grep -A4 -Fx "worktree $1" | grep -q '^locked'; }
TD() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" FM_TEARDOWN_VERNANT_PYTHON="$FAKE/vernant-python" bin/fm-teardown.sh "$@"; }
show() { local label=$1 rc; shift; echo; echo "=== $label"; echo "\$ $*"; "$@" > "$FAKE/out" 2> "$FAKE/err"; rc=$?
  sed 's/^/stdout: /' "$FAKE/out"; sed 's/^/stderr: /' "$FAKE/err"; echo "exit=$rc"; return $rc; }
state() { echo "  present=$([ -e "$1" ] && echo yes || echo no) registered=$(registered "$1" && echo yes || echo no) locked=$(locked "$1" && echo yes || echo no) closeout-execute-calls=$(cat "$FAKE/closeout.log" 2>/dev/null | wc -l | tr -d ' ')"; }

echo "##### G1 Vernant-locked copy, launcher alive, ps refused (126) for it"
G1=$(mkcopy vlive)
sleep 300 & LPID=$!
git -C "$CLONE" worktree lock --reason "vernant-session-active owner=launcher:$LPID launcher=$LPID" "$G1"
cat > "$FAKE/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = "-p $LPID -o pid=" ]; then echo 'ps: Operation not permitted' >&2; exit 126; fi
exec "$REAL_PS" "\$@"
SH
chmod +x "$FAKE/ps"
show "G1 teardown --copy, refused ps" TD --copy "$G1"; state "$G1"
kill -0 $LPID 2>/dev/null && echo "  launcher $LPID still alive (never signalled)"
echo; echo "##### G1b same, ps fails with another error (exit 3)"
sed -i '' 's/exit 126/exit 3/' "$FAKE/ps"
show "G1b teardown --copy, failing ps" TD --copy "$G1"; state "$G1"
rm -f "$FAKE/ps"

echo; echo "##### G2 launcher proved gone by the real ps"
kill $LPID; wait $LPID 2>/dev/null
"$REAL_PS" -p $LPID -o pid= >/dev/null 2>&1; echo "  real ps -p $LPID exit=$? (1 = no such process)"
show "G2 teardown --copy, launcher gone" TD --copy "$G1"; state "$G1"
echo "  closeout.log:"; sed 's/^/    /' "$FAKE/closeout.log" 2>/dev/null

echo; echo "##### G3 preserve of .claude cannot publish"
G3=$(mkcopy nopub)
mkdir -p "$G3/.claude"; printf 'unique settings\n' > "$G3/.claude/settings.local.json"
printf '.claude/\n' >> "$(git -C "$G3" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$LAB/data/pres-1"; printf 'a file where a directory must be\n' > "$LAB/data/pres-1/nested-copy-preserved"
: > "$FAKE/git-remove.log"
show "G3 teardown --copy, preserve blocked" TD --copy "$G3" --record-id pres-1; state "$G3"
echo "  .claude/settings.local.json present=$([ -f "$G3/.claude/settings.local.json" ] && echo yes || echo no) remove-calls=$(wc -l < "$FAKE/git-remove.log" | tr -d ' ')"
cmd=$(sed -n 's/^completing-command: //p' "$FAKE/err")
rm -f "$LAB/data/pres-1/nested-copy-preserved"
if [ -n "$cmd" ]; then
  show "G3 run the printed completing command after the obstacle is gone" env -u FM_GATE_REFUSE_BYPASS FM_TEARDOWN_VERNANT_PYTHON="$FAKE/vernant-python" bash -c "$cmd"; state "$G3"
  f=$(find "$LAB/data/pres-1/nested-copy-preserved" -name settings.local.json | head -1); echo "  preserved: $f -> $(cat "$f")"
fi

echo; echo "##### G4 a clone in projects/ whose registration list cannot be read"
G4=$(mkcopy blocked)
git clone -q "$LAB/origin.git" "$LAB/projects/other" 2>/dev/null
mkdir -p "$LAB/projects/other/.git/worktrees"
chmod 000 "$LAB/projects/other/.git"
show "G4 teardown --copy, other clone unreadable" TD --copy "$G4"; state "$G4"
chmod 755 "$LAB/projects/other/.git"

echo; echo "##### teardown"
rm -rf "$FAKE"
line=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/guards-lab-env.stderr"); echo "\$ $line"
eval "$line" && echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
