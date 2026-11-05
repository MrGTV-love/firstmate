#!/usr/bin/env bash
# Root inventory and each CI partition, base vs head, from clean exports.
S=/tmp/nm-live-01M6
for side in base head; do cd "$S/$side" || exit 1
  env -u NO_MISTAKES_GATE bin/fm-lint.sh --list-files > "$S/inv.$side.list" 2>/dev/null; echo "$side --list-files rc=$? lines=$(wc -l < "$S/inv.$side.list" | tr -d ' ')"
  for p in 1of3 2of3 3of3; do env -u NO_MISTAKES_GATE bin/fm-lint.sh --list-files --partition "$p" > "$S/inv.$side.$p" 2>/dev/null; echo "$side --partition $p rc=$? lines=$(wc -l < "$S/inv.$side.$p" | tr -d ' ')"; done
done
for n in list 1of3 2of3 3of3; do diff "$S/inv.base.$n" "$S/inv.head.$n" >/dev/null; echo "diff base vs head $n: exit=$?"; done
