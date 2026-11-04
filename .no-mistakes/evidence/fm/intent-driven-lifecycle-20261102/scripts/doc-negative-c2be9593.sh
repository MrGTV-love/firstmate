#!/usr/bin/env bash
# Scenario 8 negative at exact head: disposable fresh git repo built from `git archive HEAD`,
# rubric heading renamed, then the real doc validator runs there.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6KS2CS6GX0GDVNTT34X3QMC
cd "$WT" || exit 1; echo "head=$(git rev-parse HEAD)"
neg=$(mktemp -d /tmp/fm-nm-docneg.XXXXXX); git archive HEAD | tar -x -C "$neg"
git -C "$neg" init -q && git -C "$neg" add -A && git -C "$neg" -c user.name=lab -c user.email=lab@example.invalid commit -qm copy
echo "== control: unmodified disposable copy"; (cd "$neg" && bin/fm-doc-audience-check.sh); echo "exit=$?"
sed -i '' 's/^## Intent-to-test alignment$/## Intent alignment (renamed)/' "$neg/docs/review-rubric.md"; git -C "$neg" add -A
echo "== negative: rubric heading renamed"; (cd "$neg" && bin/fm-doc-audience-check.sh); echo "exit=$?"
rm -rf "$neg"; echo "left: $(ls -d "$neg" 2>/dev/null || echo none)"
