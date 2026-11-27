#!/usr/bin/env bash
# usage: cachecount.sh <tree> <cachedir> <file>
tree=$1 cache=$2 f=$3
cd "$tree" || exit 1
sc=$(command -v shellcheck)
perl bin/fm-lint-cache.pl check "$cache" "$(pwd -P)" "$sc" --norc --external-sources -- "$f" --execute true 2>/dev/null
out=$(perl bin/fm-lint-cache.pl check "$cache" "$(pwd -P)" "$sc" --norc --external-sources -- "$f" --execute true 2>&1)
case $out in *"cache hit"*) echo "HIT $f" ;; *) echo "MISS $f" ;; esac
