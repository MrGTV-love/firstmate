#!/usr/bin/env bash
# mkproject.sh <scratch-dir> : scratch origin + project primary, local main left stale behind origin.
set -eu
S=$1
mkdir -p "$S"
git init -q -b main "$S/seed"
printf 'base\n' > "$S/seed/README.md"
git -C "$S/seed" add README.md
git -C "$S/seed" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial
git clone -q --bare "$S/seed" "$S/origin.git"
git clone -q "file://$S/origin.git" "$S/project"
git clone -q "file://$S/origin.git" "$S/publisher"
