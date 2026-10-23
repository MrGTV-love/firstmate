#!/usr/bin/env bash
# Print each portable serial shard's hint total and its teardown members, using
# the runner's own --list --lane portable-serial-<k>of<n> selection and the
# runner's own serial hint table. Usage: shard_packing.sh <runner> <n>
set -u
runner=$1 n=$2
hints=$(awk '/^tests\/.*\.test\.sh [0-9]+$/{print $1, $2}' "$runner")
max=0
for k in $(seq 1 "$n"); do
  list=$("$runner" --list --lane "portable-serial-${k}of${n}") || { echo "shard $k: list failed"; exit 1; }
  sum=0 count=0 notes=''
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    count=$((count + 1))
    w=$(printf '%s\n' "$hints" | awk -v s="$s" '$1==s{print $2}')
    if [ -z "$w" ]; then w=0; notes="$notes UNHINTED:$s"; fi
    sum=$((sum + w))
    case $s in *fm-teardown*) notes="$notes ${s#tests/}=$w";; esac
  done <<<"$list"
  [ "$sum" -gt "$max" ] && max=$sum
  printf 'shard %2d  scripts=%3d  hint_ms=%8d%s\n' "$k" "$count" "$sum" "$notes"
done
printf 'worst shard hint_ms=%d\n' "$max"
