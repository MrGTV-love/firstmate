. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/common.sh
id=lbndl1; SLOT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta"); head=$(git -C "$SLOT" rev-parse HEAD); B="$FM_HOME/scratch-bundles/$id.bundle"
echo "== (c) run the exact hold command teardown printed in step (b)"
cmd=$(grep -o 'bin/fm-captain-hold.sh hold lbndl1 .*' "$EVID/transcripts/s1-main-chain.txt" | head -1)
echo "$cmd"
( cd "$WT" && eval "$cmd" </dev/null ); echo "exit=$?"
tasks-axi show $id --file "$FM_HOME/data/backlog.md" | grep -E "state:|held:|hold_kind:"
echo "== (d) ordinary teardown, no --force"; teardown $id; echo "exit=$?"
test -f "$FM_HOME/state/$id.meta" && echo "META STILL PRESENT" || echo "meta removed"
echo "slot HEAD now: $(git -C "$SLOT" rev-parse HEAD 2>&1) (origin/main=$(git -C "$PROJ" rev-parse origin/main))"
git -C "$SLOT" status --short | head; (cd "$PROJ" && treehouse status 2>&1 | head -5)
tmux list-windows -t firstmate -F '#W' 2>&1
echo "== backlog after:"; tasks-axi show $id --file "$FM_HOME/data/backlog.md" | grep -E "state:|held:|hold_kind:|links:|body:"
grep -n "Recently Landed" -A5 "$FM_HOME/data/backlog.md" || echo "(no Recently Landed section in backlog.md)"
git -C "$PROJ" rev-parse --verify -q "fm/$id" >/dev/null && echo "branch fm/$id still in project" || echo "branch fm/$id gone from project"
echo "== (e) delete source bundle, restore from stored copy"
digest=$(cut -f2 "$FM_HOME/data/$id/preservation-bundles.tsv"); stored="$FM_HOME/data/$id/preserved-bundles/$digest.bundle"
rm -f "$B"; ls -l "$stored"; shasum -a 256 "$stored"
R="$FM_HOME/restore-$id.git"; rm -rf "$R"; git init -q --bare "$R"
git -C "$R" fetch -q "$stored" "$head:refs/heads/recovered" && echo "restored work.txt: $(git -C "$R" show recovered:work.txt)" && echo "restored sha: $(git -C "$R" rev-parse recovered) expected $head"
