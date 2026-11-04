echo; echo "## post check"
echo "core.ignorecase in slot: $(git -C "$1" config core.ignorecase)"
echo "Notes.local bytes after spawn: $(cat "$1/Notes.local")"
echo "target tree tracks: $(git -C "$1" ls-tree -r --name-only origin/main | tr '\n' ' ')"
