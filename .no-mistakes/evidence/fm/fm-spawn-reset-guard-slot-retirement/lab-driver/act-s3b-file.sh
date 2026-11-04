# S3b: ignored private notes at notes.local in the slot.
printf 'private ignored notes - must survive\n' > "$1/notes.local"
git -C "$1" ls-files -o -i --exclude-standard
