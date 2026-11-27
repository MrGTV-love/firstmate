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

echo; echo "##### T0 ordinary teardown by id at the TARGET commit still refuses a missing record the old way"
run "T0 bin/fm-teardown.sh <id> with no record" no-such-task

echo; echo "##### SL pool-slot shape: slot = a worktree of the clone at \$SIDE/pool/<n>/proj, pool has treehouse-state.json"
mkslot() {  # <n>; copy = <slot>/.claude/worktrees/stray registered in the clone
  mkdir -p "$SIDE/pool/$1"
  G -C "$CLONE" worktree add -q --detach "$SIDE/pool/$1/proj" main
  printf '{"worktrees":[{"name":"%s","path":"%s","leased":false}]}\n' "$1" "$SIDE/pool/$1/proj" > "$SIDE/pool/treehouse-state.json"
  mkdir -p "$SIDE/pool/$1/proj/.claude/worktrees"
  G -C "$CLONE" worktree add -q -b "fm/slot$1" "$SIDE/pool/$1/proj/.claude/worktrees/stray" main
  SLOT=$SIDE/pool/$1/proj; SCOPY=$SLOT/.claude/worktrees/stray
}
mkslot 1
run "SL1 landed copy in a pool slot, no claim" --copy "$SCOPY"
state "$SCOPY"; echo "  slot still registered: $(registered "$SLOT" && echo yes || echo no)"

mkslot 2
printf 'task=other-task\nhome=%s\n' "$LAB" > "$SIDE/pool/2/.fm-slot-owner"
printf '%s\n' window=firstmate:fm-other-task kind=ship spawn_gen=lab > "$LAB/state/other-task.meta"
run "SL2 slot claimed by a live task of this home" --copy "$SCOPY"
state "$SCOPY"
printf 'garbage with no task line\n' > "$SIDE/pool/2/.fm-slot-owner"
run "SL2b slot claim unreadable" --copy "$SCOPY"
state "$SCOPY"
printf 'task=gone-task\nhome=%s\n' "$LAB" > "$SIDE/pool/2/.fm-slot-owner"
run "SL2c stale claim (no live record)" --copy "$SCOPY"
state "$SCOPY"; echo "  claim file kept: $([ -f "$SIDE/pool/2/.fm-slot-owner" ] && echo yes || echo no)"
rm -f "$LAB/state/other-task.meta"

mkslot 3
MATE=$SIDE/mate-home; mkdir -p "$MATE/state" "$MATE/data"
printf -- '- mate-x - lab scope (home: %s; scope: lab; projects: proj; added 2026-11-27)\n' "$MATE" > "$LAB/data/secondmates.md"
printf 'task=shared-id\nhome=%s\n' "$MATE" > "$SIDE/pool/3/.fm-slot-owner"
printf '%s\n' window=firstmate:fm-shared-id kind=ship spawn_gen=lab > "$MATE/state/shared-id.meta"
run "SL3 claim names this run's own --record-id, live in another local home" --copy "$SCOPY" --record-id shared-id
state "$SCOPY"
rm -f "$MATE/state/shared-id.meta"
run "SL3b same claim, no home holds a live record for it" --copy "$SCOPY" --record-id shared-id
state "$SCOPY"

echo; echo "##### OF a process holding an open file (not cwd) in the copy -> refused, not signalled"
OF=$(newcopy openfile)
( exec 3<"$OF/README"; exec sleep 300 ) & H=$!
sleep 1
run "OF open file handle in copy" --copy "$OF"
state "$OF"; kill -0 "$H" 2>/dev/null && echo "  holder $H still alive (not signalled)"
kill "$H"; wait "$H" 2>/dev/null

echo; echo "##### PT a captain row naming the bundle but only ONE recorded tip -> refused"
PTC=$(newcopy partial)
printf 'w\n' > "$PTC/w.txt"; G -C "$PTC" add w.txt; G -C "$PTC" commit -qm unpublished
G -C "$PTC" update-ref refs/heads/fm/second "$(G -C "$PTC" commit-tree 'HEAD^{tree}' -p origin/main -m second)"
mkdir -p "$LAB/data/rec-pt" "$SIDE/bundles"
G -C "$PTC" bundle create "$SIDE/bundles/pt.bundle" --all 2>/dev/null
dg=$(shasum -a 256 "$SIDE/bundles/pt.bundle" | awk '{print $1}')
tips=$("$REALGIT" bundle list-heads "$SIDE/bundles/pt.bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
printf '%s\t%s\t%s\n' "$SIDE/bundles/pt.bundle" "$dg" "$tips" > "$LAB/data/rec-pt/preservation-bundles.tsv"
echo "  recorded tips: $tips"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
( env -u NO_MISTAKES_GATE FM_HOME="$LAB" PATH="$FAKE:$PATH" bin/fm-captain-hold.sh hold partial-call --owner captain --title 'partial call' --repo proj \
  --reason "Land or drop work: preserved in bundle $SIDE/bundles/pt.bundle, recorded tip ${tips%% *}." ) > "$SIDE/h.out" 2>&1; echo "  partial hold rc=$? ($(cat "$SIDE/h.out"))"
run "PT row names only one tip" --copy "$PTC" --record-id rec-pt
state "$PTC"

echo; echo "##### teardown of the lab"
eval "$TEARDOWN_LINE" && echo "  lab removed: $LAB"
rm -rf "$SIDE" && echo "  side dir removed"
