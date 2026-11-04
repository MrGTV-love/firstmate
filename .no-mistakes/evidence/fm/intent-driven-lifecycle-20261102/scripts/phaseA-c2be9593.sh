#!/usr/bin/env bash
# Phase A at exact head c2be9593: model-free labs (scenarios 1,2,3,7), doc validator (8),
# and the owned recovery counterfactual (pre-fix reproduction vs fixed). No suite runs here.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
N=/Users/charlesabrooker/.no-mistakes/evidence/01M6JWCK13QKYX35VNMKYBVERE; S=$N/scripts
cd "$WT" || exit 1
[ "$(git rev-parse HEAD)" = c2be9593474c6e561bbae42ca343e23fceef7a38 ] || { echo "wrong head"; exit 1; }
[ -z "$(git status --short)" ] || { echo "dirty tree"; exit 1; }
echo "PHASE_A_START $(date -u +%FT%TZ) load=$(sysctl -n vm.loadavg)"
echo "######## lab-modelfree (scenarios 1,2,7)"; bash $S/lab-modelfree-c2be9593.sh
echo "######## lab-s3 (scenario 3)"; bash $S/lab-s3-c2be9593.sh
echo "######## scenario 8: doc validator at head"; bin/fm-doc-audience-check.sh; echo "fm-doc-audience-check exit=$?"
neg=$(mktemp -d /tmp/fm-nm-docneg.XXXXXX); git archive HEAD | tar -x -C "$neg"
sed -i '' 's/^## Intent-to-test alignment$/## Intent alignment (renamed)/' "$neg/docs/review-rubric.md"
echo "== negative: rubric heading renamed in disposable copy of head"; (cd "$neg" && bin/fm-doc-audience-check.sh); echo "exit=$?"; rm -rf "$neg"
echo "######## recovery counterfactual"
pre=$(mktemp -d /tmp/fm-nm-prefix.XXXXXX); mkdir "$pre/fm"; git archive 8b64863c4fb49c32ec307603a63ce0540b86a79b | tar -x -C "$pre/fm" || exit 1
echo "pre-fix tree: git archive of 8b64863c (no history)"
tok="fmnmcf$$"
# Pre-fix fixture keeps its one shared constant; rename it to an owned token so the probe never touches a real fmlab name.
sed -i '' "s/fmlab/$tok/g" "$pre/fm/tests/fm-control-relaunch-helpers.sh" "$pre/fm/tests/fm-control-relaunch-recovery.test.sh"
bash $S/recovery-counterfactual.sh "$pre/fm" none steady "pre-fix fixture, no collider" > $N/recovery-cf-c2-0-prefix-baseline.log 2>&1
bash $S/recovery-counterfactual.sh "$pre/fm" "$tok" late "pre-fix fixture, late collider on its shared constant" > $N/recovery-cf-c2-1-prefix-late.log 2>&1
rm -rf "$pre"
bash $S/recovery-counterfactual.sh "$WT" none steady "fixed fixture at c2be9593, no collider" > $N/recovery-cf-c2-2-fixed-baseline.log 2>&1
bash $S/recovery-counterfactual.sh "$WT" fmlab-99999-ZzOther-rl68 late "fixed fixture at c2be9593, late collider on another run's same-shape session" > $N/recovery-cf-c2-3-fixed-other-run.log 2>&1
bash $S/recovery-counterfactual.sh "$WT" own late "fixed fixture at c2be9593, late collider on the case's own session (safety refusal)" > $N/recovery-cf-c2-5-fixed-own-session.log 2>&1
for f in $N/recovery-cf-c2-*.log; do echo "== $f"; cat "$f"; done
echo "worktree changed paths: $(git status --short | wc -l | tr -d ' ')"
echo "PHASE_A_END $(date -u +%FT%TZ)"
