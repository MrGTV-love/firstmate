echo; echo "=== S3 control (re-run after fixing the lab script's leftover symlink) ==="
SRC=$SCR/t-s3.bundle; REC=$FM_HOME/data/t-s3/preservation-bundles.tsv
rm -f "$SRC"; cp "$SCR/t-s3.good.bundle" "$SRC"; cp "$SCR/t-s3.good.tsv" "$REC"
ls -l "$SRC"; cat "$REC"
echo "--- control: good record and regular bundle; ordinary teardown ---"
td t-s3; present "$FM_HOME/state/t-s3.meta"
