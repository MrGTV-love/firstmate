#!/usr/bin/env bash
# snap.sh <slot> : HEAD, refs, index, and a path-sorted sha256 of every file outside .git.
set -u
s=$1
echo "--- HEAD"; git -C "$s" rev-parse HEAD; git -C "$s" symbolic-ref -q HEAD || echo detached
echo "--- show-ref"; git -C "$s" show-ref
echo "--- index"; git -C "$s" ls-files -s --debug | shasum -a 256
echo "--- files"; (cd "$s" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done)
