# S2: slot attached to a branch with one commit that is in no anchor.
git -C "$1" switch -q -c lab/owner-branch
printf 'owner branch work\n' > "$1/owner.txt"
git -C "$1" add owner.txt
git -C "$1" -c user.name=lab -c user.email=lab@example.invalid commit -qm 'owner branch commit'
git -C "$1" rev-parse lab/owner-branch
