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
G clone -q "$SIDE/seed/fixtures/fx.git" "$SIDE/fxw" 2>/dev/null; printf f > "$SIDE/fxw/f"; G -C "$SIDE/fxw" add f; G -C "$SIDE/fxw" commit -qm fx; G -C "$SIDE/fxw" push -q origin HEAD:refs/heads/main 2>/dev/null; rm -rf "$SIDE/fxw"
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


echo "# tracked fixture files: $(G -C "$CLONE" ls-files fixtures/fx.git | grep -E '^fixtures/fx.git/(HEAD|objects/|refs/)' | sed 's#fixtures/fx.git/##' | tr '\n' ' ')"

echo; echo "##### C tracked, unmodified bare fixture (landed content) -> allowed and removed"
C=$(newcopy fixture)
echo "  git -C fixtures/fx.git rev-parse --is-bare-repository: $(G -C "$C/fixtures/fx.git" rev-parse --is-bare-repository)"
run "C tracked bare fixture only" --copy "$C"
state "$C"

echo; echo "##### C2 the same tracked fixture with one untracked ref added -> refused"
C2=$(newcopy fixture2)
fx_head=$(G -C "$C2/fixtures/fx.git" rev-parse refs/heads/main)
G -C "$C2/fixtures/fx.git" update-ref refs/heads/extra "$fx_head"
echo "  bare fixture refs now: $(G -C "$C2/fixtures/fx.git" for-each-ref --format='%(refname)' | tr '\n' ' ')"
echo "  copy git status (untracked shown): $(G -C "$C2" status --porcelain --untracked-files=all | tr '\n' ' ')"
run "C2 tracked fixture with an untracked ref" --copy "$C2"
state "$C2"

echo; echo "##### C3 the same tracked fixture with an ignored-only extra object/ref under .claude-style ignore -> refused"
C3=$(newcopy fixture3)
printf 'fixtures/fx.git/refs/heads/hidden\n' >> "$("$REALGIT" -C "$CLONE" rev-parse --path-format=absolute --git-path info/exclude)"
G -C "$C3/fixtures/fx.git" update-ref refs/heads/hidden "$(G -C "$C3/fixtures/fx.git" rev-parse refs/heads/main)"
echo "  copy git status --ignored: $(G -C "$C3" status --porcelain --ignored --untracked-files=all | tr '\n' ' ')"
run "C3 tracked fixture with an ignored ref" --copy "$C3"
state "$C3"

echo; echo "##### teardown of the lab"
eval "$TEARDOWN_LINE" && echo "  lab removed: $LAB"
rm -rf "$SIDE" && echo "  side dir removed"
