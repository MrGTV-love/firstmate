#!/usr/bin/env bash
# publish.sh <scratch-dir> <path> <content> [force-add] : advance origin/main with a tracked file.
set -eu
S=$1 p=$2 c=$3
mkdir -p "$(dirname "$S/publisher/$p")"
printf '%s\n' "$c" > "$S/publisher/$p"
git -C "$S/publisher" add ${4:+-f} -- "$p"
git -C "$S/publisher" -c user.name=lab -c user.email=lab@example.invalid commit -qm "publish $p"
git -C "$S/publisher" push -q origin main
