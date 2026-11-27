#!/usr/bin/env bash
# Live drive, part 2: ignored .claude content, other Git repositories, the tracked bare
# fixture exception, and the by-path exception's own final refusal text.
# Usage: drive-by-path-2.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
TD="$WT/bin/fm-teardown.sh"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN_LINE=$(sed -n 's/^fm-lab-home: teardown: //p' /tmp/fm-lab-env.$$); rm -f /tmp/fm-lab-env.$$
LAB=$FM_HOME
SIDE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-side.XXXXXX"); SIDE=$(cd "$SIDE" && pwd -P)
echo "# lab FM_HOME=$LAB"
FAKE=$SIDE/fakebin; mkdir -p "$FAKE"
for t in treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> %q\nexit 0\n' "$t" "$SIDE/provider-calls.log" > "$FAKE/$t"; chmod +x "$FAKE/$t"
done
REALGIT=$(command -v git)
cat > "$FAKE/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree remove "*) printf '%s\n' "\$*" >> "$SIDE/git-remove.log" ;; esac
exec "$REALGIT" "\$@"
SH
chmod +x "$FAKE/git"; : > "$SIDE/git-remove.log"
G() { "$REALGIT" -c user.email=lab@lab -c user.name=lab "$@"; }

# Origin main ignores .claude/ and tracks a clean bare fixture repository at fixtures/fx.git.
G init -q --bare "$SIDE/origin.git"; G -C "$SIDE/origin.git" symbolic-ref HEAD refs/heads/main
G clone -q "$SIDE/origin.git" "$SIDE/seed" 2>/dev/null
printf '.claude/\n.opencode/\n' > "$SIDE/seed/.gitignore"; printf 'x\n' > "$SIDE/seed/README"
G init -q --bare "$SIDE/seed/fixtures/fx.git"
G -C "$SIDE/seed" add -f .gitignore README fixtures; G -C "$SIDE/seed" commit -qm baseline; G -C "$SIDE/seed" push -q origin main
G clone -q "$SIDE/origin.git" "$LAB/projects/proj"; G -C "$LAB/projects/proj" remote set-head origin main
CLONE=$(cd "$LAB/projects/proj" && pwd -P)
echo "# origin main tracks: $(G -C "$CLONE" ls-files | grep -c 'fixtures/fx.git/') files under fixtures/fx.git, and .gitignore = $(tr '\n' ' ' < "$CLONE/.gitignore")"

newcopy() { G -C "$CLONE" worktree add -q -b "fm/$1" "$CLONE/.claude/worktrees/$1" main; printf '%s\n' "$CLONE/.claude/worktrees/$1"; }
registered() { "$REALGIT" -C "$CLONE" worktree list --porcelain | grep -Fqx "worktree $1"; }
state() {
  local s=present r=unregistered; [ -e "$1" ] || s=gone; registered "$1" && r=registered
  echo "  -> copy: $s, $r; git-worktree-remove calls so far: $(wc -l < "$SIDE/git-remove.log" | tr -d ' '); provider calls: $(cat "$SIDE/provider-calls.log" 2>/dev/null | wc -l | tr -d ' ')"
}
run() {
  local label=$1; shift
  echo; echo "=== $label"; echo "\$ FM_HOME=\$LAB bin/fm-teardown.sh $*"
  local rc=0
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" PATH="${EXTRA_PATH:+$EXTRA_PATH:}$FAKE:$PATH" "$TD" "$@" > "$SIDE/out" 2> "$SIDE/err" || rc=$?
  sed 's/^/  stdout| /' "$SIDE/out"; sed 's/^/  stderr| /' "$SIDE/err"; echo "  rc=$rc"
}


echo; echo "##### P1 .claude preserve cannot publish (data/<id> not writable) -> copy stays"
P=$(newcopy nopublish)
mkdir -p "$P/.claude"; printf 'notes only here\n' > "$P/.claude/notes.md"
mkdir -p "$LAB/data/rec-ro"; chmod 555 "$LAB/data/rec-ro"
run "P1 preserve target read-only" --copy "$P" --record-id rec-ro
state "$P"
echo "  .claude/notes.md still in copy: $(cat "$P/.claude/notes.md" 2>/dev/null)"
chmod 755 "$LAB/data/rec-ro"
run "P1 same copy, preserve target writable again" --copy "$P" --record-id rec-ro
state "$P"

echo; echo "##### R1 registration list unreadable (clone .git/worktrees mode 000) -> 'could not read', copy stays"
R=$(newcopy unreadable)
chmod 000 "$CLONE/.git/worktrees"
run "R1 present copy, registration list unreadable" --copy "$R"
chmod 755 "$CLONE/.git/worktrees"
state "$R"

echo; echo "##### R2 gone copy, projects folder unreadable -> refused, not reported done"
R2=$(newcopy gone2)
G -C "$CLONE" worktree remove "$R2"
chmod 000 "$LAB/projects"
run "R2 gone copy, projects/ unreadable" --copy "$R2"
chmod 755 "$LAB/projects"
run "R2 gone copy, projects/ readable, no audit line names it" --copy "$R2"

echo; echo "##### R3 gone copy that a clone still registers -> refused, names git worktree prune"
R3=$(newcopy stale)
rm -rf "$R3"
run "R3 gone but still registered" --copy "$R3"
echo "  still registered: $(registered "$R3" && echo yes || echo no)"

echo; echo "##### teardown of the lab"
chmod -R u+rwx "$LAB" 2>/dev/null
eval "$TEARDOWN_LINE" && echo "  lab removed: $LAB"
rm -rf "$SIDE" && echo "  side dir removed"
