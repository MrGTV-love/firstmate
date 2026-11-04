#!/usr/bin/env bash
# Scenario 4 negatives at exact head: disposable fresh-git copies with the worker-role cue in bin/fm-dod-lib.sh
#  D duplicated (printed twice)   R moved after the rendered rubric
# Run the relaunch and reconciliation-only recovery cases in each. Expected: recovery case fails on D and R;
# relaunch case (count-only check) fails on D, passes on R. Head positives come from the full exact-head suites.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
cd "$WT" || exit 1; echo "head=$(git rev-parse HEAD) dirty=$(git status --short | wc -l | tr -d ' ')"
mk() { local d; d=$(mktemp -d /tmp/fm-nm-s4.XXXXXX); git archive HEAD | tar -x -C "$d"; git -C "$d" init -q; git -C "$d" add -A; git -C "$d" -c user.name=lab -c user.email=lab@example.invalid commit -qm copy; echo "$d"; }
mut() { python3 - "$1/bin/fm-dod-lib.sh" "$2" <<'PY'
import sys;p,m=sys.argv[1],sys.argv[2];s=open(p).read()
cue='''  printf '%s\\n' "For work that adds or changes tests, hooks or validators, use the existing Intent-to-test alignment criteria in the shared review rubric below during implementation and verification; it does not change the task's scope or delivery contract."\n'''
cat='''  cat "$root/docs/review-rubric.md"\n'''
assert s.count(cue)==1 and s.count(cat)==1, (s.count(cue), s.count(cat))
s = s.replace(cue, cue+cue) if m=="D" else s.replace(cue,'').replace(cat, cat+cue)
open(p,'w').write(s)
PY
}
cases() { local d=$1
  (cd "$d" && bash tests/fm-control-relaunch-recovery.test.sh test_exited_owner_reconciliation_preserves_holds_dependencies_and_work 2>&1 | grep -E '^(ok|not ok)' ); echo "recovery case exit=${PIPESTATUS[0]}"
  (cd "$d" && bash tests/fm-control-relaunch.test.sh test_relaunch_appends_the_progress_note_to_the_instructions 2>&1 | grep -E '^(ok|not ok)' ); echo "relaunch case exit=${PIPESTATUS[0]}"; }
for m in D R; do d=$(mk); mut "$d" $m; echo "== variant $m: $(cd "$d" && git diff --stat | tail -1)"; cases "$d"; rm -rf "$d"; echo "left: $(ls -d "$d" 2>/dev/null || echo none)"; done
echo "worktree dirty=$(git -C "$WT" status --short | wc -l | tr -d ' ')"
