echo "=== S2: copy with two locally-only tips (HEAD + task archive branch) ==="
new_task t-s2 || exit 1
HEAD=$(git -C "$COPY" rev-parse HEAD)
SECOND=$(git -C "$COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'independent unpublished tip')
git -C "$COPY" branch archive/t-s2-submitted-deadbeef "$SECOND"
echo "HEAD tip: $HEAD"; echo "archive tip (archive/t-s2-submitted-deadbeef): $SECOND"
echo "--- bundle lists ONLY the HEAD tip (git bundle create <b> fm/t-s2) ---"
SRC=$SCR/t-s2.bundle
show record_bundle t-s2 "$SRC" fm/t-s2
cat "$FM_HOME/data/t-s2/preservation-bundles.tsv"
show hold_call t-s2 "$SRC" "$(cut -f3 "$FM_HOME/data/t-s2/preservation-bundles.tsv")"
td t-s2; present "$FM_HOME/state/t-s2.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse HEAD)"
echo "--- re-bundle with --all (lists both tips), re-file the call ---"
show record_bundle t-s2 "$SRC" --all
cat "$FM_HOME/data/t-s2/preservation-bundles.tsv"
show hold_call t-s2 "$SRC" "$(cut -f3 "$FM_HOME/data/t-s2/preservation-bundles.tsv")"
td t-s2; present "$FM_HOME/state/t-s2.meta"
echo "slot HEAD now: $(git -C "$COPY" rev-parse HEAD 2>&1) (main is $(git -C "$PROJ" rev-parse main))"
DIG=$(cut -f2 "$FM_HOME/data/t-s2/preservation-bundles.tsv"); STORED=$FM_HOME/data/t-s2/preserved-bundles/$DIG.bundle
R=$SCR/restore-s2; rm -rf "$R"; git init -q "$R"
show git -C "$R" fetch "$STORED" "$HEAD:refs/heads/r1" "$SECOND:refs/heads/r2"
