#!/usr/bin/env bash
# Same inputs through the base tree and the head tree. Real ShellCheck. Compares output and exit code.
LAB=$1 out=$2; : > "$out"
run(){ tree=$1 name=$2; shift 2; (cd "$LAB/$tree" && env FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$LAB/m4/pool-$tree" bin/fm-lint.sh "$@") > "$LAB/m4/$tree.$name.txt" 2>&1; echo "$tree $name rc=$?" >> "$out"; }
for tree in base headtree; do
  run $tree list --list-files
  for n in 1 2 3; do run $tree list.${n}of3 --list-files --partition ${n}of3; done
  run $tree clean "$LAB/m4/fx/clean.sh"
  run $tree findings "$LAB/m4/fx/findings.sh"
  run $tree findings-fast --fast "$LAB/m4/fx/findings.sh"
done
for n in list list.1of3 list.2of3 list.3of3 clean findings findings-fast; do
  if cmp -s "$LAB/m4/base.$n.txt" "$LAB/m4/headtree.$n.txt"; then echo "same $n ($(wc -l < "$LAB/m4/base.$n.txt") lines)" >> "$out"; else echo "DIFF $n" >> "$out"; diff "$LAB/m4/base.$n.txt" "$LAB/m4/headtree.$n.txt" | head -20 >> "$out"; fi
done
cp "$LAB/m4/headtree.findings.txt" "${out%.txt}-head-findings-output.txt"
echo DONE >> "$out"
