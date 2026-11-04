#!/usr/bin/env bash
# Pre-fix reproduction with readable history: fresh git repo built from `git archive 8b64863c`
# (not a clone), fixture constant fmlab renamed to an owned token. Control (no collider) must pass;
# late collider on the shared constant must reproduce the original refusal.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6JWCK13QKYX35VNMKYBVERE; S=$N/scripts
cd "$WT" || exit 1
pre=$(mktemp -d /tmp/fm-nm-prefix.XXXXXX); mkdir "$pre/fm"; git archive 8b64863c4fb49c32ec307603a63ce0540b86a79b | tar -x -C "$pre/fm" || exit 1
tok="fmnmcf$$"; sed -i '' "s/fmlab/$tok/g" "$pre/fm/tests/fm-control-relaunch-helpers.sh" "$pre/fm/tests/fm-control-relaunch-recovery.test.sh"
git -C "$pre/fm" init -q && git -C "$pre/fm" add -A && git -C "$pre/fm" -c user.name=lab -c user.email=lab@example.invalid commit -qm "8b64863c archive, fixture constant renamed to $tok"
bash $S/recovery-counterfactual.sh "$pre/fm" none steady "pre-fix fixture (archive+fresh git), no collider" > $N/recovery-cf-c2-0b-prefix-baseline.log 2>&1
bash $S/recovery-counterfactual.sh "$pre/fm" "$tok" late "pre-fix fixture (archive+fresh git), late collider on its shared constant" > $N/recovery-cf-c2-1b-prefix-late.log 2>&1
rm -rf "$pre"; echo "left: $(ls -d "$pre" 2>/dev/null || echo none)"
cat $N/recovery-cf-c2-0b-prefix-baseline.log $N/recovery-cf-c2-1b-prefix-late.log
