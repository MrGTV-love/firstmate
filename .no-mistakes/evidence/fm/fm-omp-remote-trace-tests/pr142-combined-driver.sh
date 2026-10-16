#!/usr/bin/env bash
# Apply the three product breaks together, run PR 142's own omp test, restore the product.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M51W4N6QBPG5MRQQFJ93P17V || exit 2
E=/Users/charlesabrooker/.no-mistakes/evidence/01M51W4N6QBPG5MRQQFJ93P17V
git diff --quiet -- bin || { echo "bin/ already dirty; refusing"; exit 2; }
perl -pi "$E/m1b.perl" bin/fm-remote-secondmate-control.sh
perl -pi "$E/m2.perl" bin/fm-spawn.sh
perl -pi "$E/m3b.perl" bin/fm-control.sh
git diff -- bin > "$E/pr142-combined.diff.txt"
bash tests/fm-spawn-compact-adviser-disable-remote.test.sh > "$E/pr142-under-breaks.run.txt" 2>&1; rc=$?
echo "rc=$rc" >> "$E/pr142-under-breaks.run.txt"
git checkout -- bin
echo "pr142-under-breaks rc=$rc"
git status --short
