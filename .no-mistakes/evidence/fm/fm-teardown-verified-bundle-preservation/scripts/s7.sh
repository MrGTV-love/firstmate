. /Users/charlesabrooker/.no-mistakes/evidence/01M6ARTNJJE53FT9ETN002MAA0/scripts/s6lib.sh
for spec in "lnest3 unique removed" "lnest4 clean removed"; do set -- $spec
  echo "######## S7 nested anchored prior, bytes=$2, current copy $3"
  nested_case $1 $2 $3 || { echo setup failed; exit 1; }
  teardown $1 2>&1 | f; echo "exit=${PIPESTATUS[0]}"; report $1
  git -C "$PROJ" rev-parse --verify -q "fm/$1-v2" >/dev/null && echo "branch fm/$1-v2 present" || echo "branch fm/$1-v2 gone"
done
id=lnest4; st="$FM_HOME/data/$id/preserved-bundles/$(cut -f2 "$FM_HOME/data/$id/preservation-bundles.tsv").bundle"; rm -f "$FM_HOME/scratch-bundles/$id.bundle"
R="$FM_HOME/restore-$id.git"; git init -q --bare "$R"; tip=$(git bundle list-heads "$st" | awk '$2=="refs/heads/fm/lnest4-v2"{print $1}')
git -C "$R" fetch -q "$st" "$tip:refs/heads/r" && echo "lnest4 restored from stored bundle after source deletion: $(git -C "$R" show r:work.txt) ($tip)"
