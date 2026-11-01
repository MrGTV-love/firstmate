echo "=== S3: invalid bundle or record shapes keep the refusal (call filed for the valid bundle) ==="
new_task t-s3 || exit 1
HEAD=$(git -C "$COPY" rev-parse HEAD)
SRC=$SCR/t-s3.bundle; REC=$FM_HOME/data/t-s3/preservation-bundles.tsv
record_bundle t-s3 "$SRC"; cp "$REC" "$SCR/t-s3.good.tsv"; cp "$SRC" "$SCR/t-s3.good.bundle"
GOOD=$(cat "$REC"); P=$(cut -f1 "$REC"); D=$(cut -f2 "$REC"); T=$(cut -f3 "$REC")
hold_call t-s3 "$SRC" "$T" >/dev/null
check() { echo; echo "--- case: $1 ---"; td t-s3; present "$FM_HOME/state/t-s3.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse HEAD)"; cp "$SCR/t-s3.good.tsv" "$REC"; cp "$SCR/t-s3.good.bundle" "$SRC"; rm -rf "$FM_HOME/data/t-s3/preserved-bundles"; }
printf '%s\t%s\t%s\n' "$P" "$(printf 'a%.0s' {1..64})" "$T" > "$REC"; check "recorded sha256 does not match the bundle"
head -c 200 "$SCR/t-s3.good.bundle" > "$SRC"; printf '%s\t%s\t%s\n' "$P" "$(shasum -a 256 "$SRC" | awk '{print $1}')" "$T" > "$REC"; check "truncated bundle (git bundle verify fails), digest re-recorded"
git -C "$COPY" bundle create "$SRC" main 2>/dev/null; printf '%s\t%s\t%s\n' "$P" "$(shasum -a 256 "$SRC" | awk '{print $1}')" "$(git bundle list-heads "$SRC" | awk '{print $1}' | sort -u | paste -sd' ' -)" > "$REC"; check "bundle lacks the copy's unlanded tip (bundle of main only)"
printf '%s\n%s\n' "$GOOD" "$GOOD" > "$REC"; check "record has two lines"
printf '%s\t%s\n' "$P" "$D" > "$REC"; check "malformed record line (two fields)"
: > "$REC"; check "empty record"
printf 'relative.bundle\t%s\t%s\n' "$D" "$T" > "$REC"; check "relative bundle path in record"
rm "$REC"; check "no record under the task's data directory"
mv "$SRC" "$SRC.real"; ln -s "$SRC.real" "$SRC"; check "source bundle is a symlink"; rm -f "$SRC.real"
cp "$SCR/t-s3.good.bundle" "$COPY/inside.bundle"; printf '%s\t%s\t%s\n' "$COPY/inside.bundle" "$D" "$T" > "$REC"; mkdir -p "$FM_HOME/data/t-s3"; check "bundle path inside the copy, call not re-filed for it (copy then dirty)"; rm -f "$COPY/inside.bundle"
echo; echo "--- control: the good record and bundle restored; ordinary teardown ---"
td t-s3; present "$FM_HOME/state/t-s3.meta"
