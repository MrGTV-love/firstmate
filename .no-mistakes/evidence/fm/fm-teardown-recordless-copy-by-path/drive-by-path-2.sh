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

echo; echo "##### A nested clone under ignored .claude -> refused"
A=$(newcopy nestedclone)
mkdir -p "$A/.claude"; G clone -q "$SIDE/origin.git" "$A/.claude/inner" 2>/dev/null
printf 'z\n' > "$A/.claude/inner/f"; G -C "$A/.claude/inner" add f; G -C "$A/.claude/inner" commit -qm 'only here'
echo "  git status --ignored of the copy: $(G -C "$A" status --porcelain --ignored | tr '\n' ' ')"
run "A nested clone in ignored .claude" --copy "$A"
state "$A"

echo; echo "##### B untracked bare repository under ignored .claude -> refused"
B=$(newcopy barecopy)
mkdir -p "$B/.claude"; G init -q --bare "$B/.claude/stash.git"
run "B untracked bare repo in ignored .claude" --copy "$B"
state "$B"

echo; echo "##### C tracked, unmodified bare fixture (landed content) -> allowed and removed"
C=$(newcopy fixture)
echo "  copy holds tracked bare fixture: $(ls -d "$C/fixtures/fx.git")"
run "C tracked bare fixture only" --copy "$C"
state "$C"

echo; echo "##### C2 the same tracked fixture with one untracked ref added -> refused"
C2=$(newcopy fixture2)
G -C "$C2/fixtures/fx.git" update-ref refs/heads/extra "$(G -C "$C" rev-parse HEAD 2>/dev/null || G -C "$CLONE" rev-parse HEAD)" 2>/dev/null \
  || printf '%s\n' "$(G -C "$CLONE" rev-parse HEAD)" > "$C2/fixtures/fx.git/refs/heads/extra"
echo "  git status in copy: $(G -C "$C2" status --porcelain --ignored | tr '\n' ' ')"
run "C2 tracked fixture with an untracked ref" --copy "$C2"
state "$C2"

echo; echo "##### D ignored .claude and .opencode content is preserved whole, then the copy is removed"
D=$(newcopy preserve)
mkdir -p "$D/.claude/sessions" "$D/.opencode"
printf 'session notes only here\n' > "$D/.claude/sessions/notes.md"
printf 'opencode state only here\n' > "$D/.opencode/state.json"
echo "  ignored in copy: $(G -C "$D" status --porcelain --ignored | tr '\n' ' ')"
run "D ignored .claude + .opencode" --copy "$D" --record-id rec-preserve
state "$D"
echo "  preserved files:"; (cd "$LAB/data/rec-preserve" 2>/dev/null && find . -type f | sort | sed 's/^/    | /')
for f in $(find "$LAB/data/rec-preserve" -type f \( -name notes.md -o -name state.json \) 2>/dev/null); do echo "  $f => $(cat "$f")"; done

echo; echo "##### D2 an ignored file outside .claude/.opencode that exists nowhere else -> refused"
D2=$(newcopy uniqueignored)
printf 'secret.dat\n' >> "$("$REALGIT" -C "$CLONE" rev-parse --path-format=absolute --git-path info/exclude)"
printf 'only copy\n' > "$D2/secret.dat"
run "D2 unique ignored file" --copy "$D2"
state "$D2"

echo; echo "##### E by-path exception: bundle-held copy WITH a captain row, but a nested repo planted in .claude -> refused, final text names the exception's own reason"
E=$(newcopy exc)
printf 'w\n' > "$E/work.txt"; G -C "$E" add work.txt; G -C "$E" commit -qm unpublished
ID=rec-exc; mkdir -p "$LAB/data/$ID" "$SIDE/bundles"
G -C "$E" bundle create "$SIDE/bundles/e.bundle" --all 2>/dev/null
dg=$(shasum -a 256 "$SIDE/bundles/e.bundle" | awk '{print $1}')
tips=$("$REALGIT" bundle list-heads "$SIDE/bundles/e.bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
printf '%s\t%s\t%s\n' "$SIDE/bundles/e.bundle" "$dg" "$tips" > "$LAB/data/$ID/preservation-bundles.tsv"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
run "E first run, no captain row" --copy "$E" --record-id "$ID"
cmd=$(sed -n 's/^File the land-or-drop call as its row, then run the same teardown --copy command again: //p' "$SIDE/err")
( env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$FAKE:$PATH" bash -c "$cmd" ) > "$SIDE/hold.out" 2>&1; echo "  hold rc=$? ($(cat "$SIDE/hold.out"))"
# Plant the harm only once the bundle route is being judged: a git shim that clones a repo into
# .claude on the first `bundle verify` (after the early other-repository scan already passed).
mkdir -p "$SIDE/plant"
cat > "$SIDE/plant/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" bundle verify "*)
    if [ ! -e "$SIDE/planted" ]; then : > "$SIDE/planted"; mkdir -p "$E/.claude"; "$REALGIT" clone -q "$SIDE/origin.git" "$E/.claude/planted" 2>/dev/null; fi ;;
  *" worktree remove "*) printf '%s\n' "\$*" >> "$SIDE/git-remove.log" ;;
esac
exec "$REALGIT" "\$@"
SH
chmod +x "$SIDE/plant/git"
EXTRA_PATH=$SIDE/plant run "E captain row filed, harm planted mid-run" --copy "$E" --record-id "$ID"
echo "  final REFUSED line: $(grep '^REFUSED:' "$SIDE/err" | tail -n 1)"
echo "  planted repo present: $([ -e "$E/.claude/planted/.git" ] && echo yes || echo no)"
state "$E"
rm -rf "$E/.claude/planted"
run "E captain row filed, harm gone" --copy "$E" --record-id "$ID"
state "$E"

echo; echo "##### F the ordinary held close shares the scan: covered by tests/fm-teardown-cleanup.test.sh (see held-close-tests.log)"

echo; echo "##### audit log"; sed 's/^/  | /' "$LAB/data/record-less-copy-removals.log" 2>/dev/null
echo "##### provider calls: $(cat "$SIDE/provider-calls.log" 2>/dev/null | wc -l | tr -d ' ')"
echo; echo "##### teardown of the lab"
eval "$TEARDOWN_LINE" && echo "  lab removed: $LAB"
rm -rf "$SIDE" && echo "  side dir removed"
