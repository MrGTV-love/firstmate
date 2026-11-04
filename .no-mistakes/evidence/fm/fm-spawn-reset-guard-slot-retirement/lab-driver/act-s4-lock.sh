# S4: a git worktree lock on the slot.
git -C "$1" worktree lock --reason 'lab: another tool holds this slot' "$1"
git -C "$1" worktree list --porcelain | grep -A4 "$1" | grep locked
