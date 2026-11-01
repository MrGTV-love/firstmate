echo "=== S1: one unpushed commit; verified bundle in a temporary scratch location ==="
new_task t-s1 || exit 1
SRC=$SCR/t-s1.bundle; HEAD=$(git -C "$COPY" rev-parse HEAD)
echo "copy: $COPY (treehouse pool slot)"; echo "copy HEAD: $HEAD"
echo "--- BEFORE any bundle: ordinary teardown ---"; td t-s1; present "$COPY"
show record_bundle t-s1 "$SRC"
echo "record:"; cat "$FM_HOME/data/t-s1/preservation-bundles.tsv"
DIG=$(cut -f2 "$FM_HOME/data/t-s1/preservation-bundles.tsv"); TIPS=$(cut -f3 "$FM_HOME/data/t-s1/preservation-bundles.tsv")
echo "--- bundle recorded, captain's call NOT filed: ordinary teardown ---"; td t-s1; present "$COPY"
echo "backlog row held? $(tasks-axi show t-s1 --file "$FM_HOME/data/backlog.md" | sed -n 's/^  held: //p')"
echo "--- file the captain's call (header recipe) ---"; show hold_call t-s1 "$SRC" "$TIPS"
echo "--- ordinary teardown, no --force ---"; td t-s1
present "$COPY"; present "$FM_HOME/state/t-s1.meta"
STORED=$FM_HOME/data/t-s1/preserved-bundles/$DIG.bundle; present "$STORED"
echo "stored sha256: $(shasum -a 256 "$STORED" | awk '{print $1}')  record sha256: $DIG"
echo "treehouse pool status:"; (cd "$PROJ" && treehouse status 2>&1)
echo "--- delete the original source bundle; restore with the documented command ---"
rm -v "$SRC"
R=$SCR/restore-s1; rm -rf "$R"; git init -q "$R"
show git -C "$R" fetch "$STORED" "$HEAD:refs/heads/recovered"
show git -C "$R" show recovered:work.txt
show git -C "$R" fsck --strict
