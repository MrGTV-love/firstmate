#!/usr/bin/env bash
# Break one product behavior at a time, run the omp section of the changed test, restore the product.
# usage: mutation-driver.sh <name> <perl-edit-file-path> <perl-expr>
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M51W4N6QBPG5MRQQFJ93P17V || exit 2
E=/Users/charlesabrooker/.no-mistakes/evidence/01M51W4N6QBPG5MRQQFJ93P17V
name=$1; file=$2; expr=$3
git diff --quiet -- bin || { echo "bin/ already dirty; refusing"; exit 2; }
head -n 294 tests/fm-remote-secondmate-trace-context.test.sh > tests/zz-mut-omp-only.test.sh
chmod +x tests/zz-mut-omp-only.test.sh
perl -pi "$expr" "$file"
git diff --stat -- bin > "$E/mut-$name.diff-stat.txt"; git diff -- bin > "$E/mut-$name.diff.txt"
[ -s "$E/mut-$name.diff.txt" ] || { echo "mutation $name changed nothing"; rm -f tests/zz-mut-omp-only.test.sh; exit 3; }
bash tests/zz-mut-omp-only.test.sh > "$E/mut-$name.run.txt" 2>&1; rc=$?
echo "rc=$rc" >> "$E/mut-$name.run.txt"
git checkout -- bin
rm -f tests/zz-mut-omp-only.test.sh
echo "$name rc=$rc"
