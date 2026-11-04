# S1: unique work = one extra commit on the slot's detached HEAD.
printf 'unique detached work\n' > "$1/unique.txt"
git -C "$1" add unique.txt
git -C "$1" -c user.name=lab -c user.email=lab@example.invalid commit -qm 'unique detached commit'
git -C "$1" rev-parse HEAD
