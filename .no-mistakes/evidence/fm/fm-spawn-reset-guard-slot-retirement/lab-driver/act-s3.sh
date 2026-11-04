# S3: tracked edit + untracked file inside an untracked directory.
printf 'dirty tracked edit\n' >> "$1/README.md"
mkdir -p "$1/newdir/sub"; printf 'untracked work\n' > "$1/newdir/sub/draft.txt"
git -C "$1" status --porcelain --untracked-files=all
