# S3b case-insensitive: ignored private notes at Notes.local (capital N); the target tracks notes.local.
printf 'Notes.local\n' >> "$(git -C "$1" rev-parse --git-common-dir)/info/exclude"
printf 'private ignored Notes - must survive\n' > "$1/Notes.local"
echo "core.ignorecase=$(git -C "$1" config core.ignorecase)"
git -C "$1" ls-files -o -i --exclude-standard
