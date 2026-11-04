#!/usr/bin/env bash
# Scenario 6 counterfactual at exact head. Each copy is a disposable fresh git repo from `git archive HEAD`
# (its own code root with readable history). TMPDIR is placed INSIDE that checkout, so a fixture project
# directory without its own repo inherits firstmate's lineage. A = head; B = head minus the fixture's
# `git -C "$home/projects/proj" init -q` line. A must pass the promotion case; B must fail it.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
cd "$WT" || exit 1; echo "head=$(git rev-parse HEAD) dirty=$(git status --short | wc -l | tr -d ' ')"
# Only the promotion case is invoked: every other bare top-level case call becomes ':' (definitions untouched),
# so no unrelated fixture that also lacks its own repo can fail first under the in-checkout TMPDIR.
mk() { local d; d=$(mktemp -d /tmp/fm-nm-s6.XXXXXX); git archive HEAD | tar -x -C "$d"; sed -i '' -E '/^test_promotion_carries_the_forge_binding$/!s/^test_[a-z0-9_]+$/:/' "$d/tests/fm-task-delivery.test.sh"; echo "cases still invoked: $(grep -cE '^test_[a-z0-9_]+$' "$d/tests/fm-task-delivery.test.sh")" >&2; git -C "$d" init -q; git -C "$d" add -A; git -C "$d" -c user.name=lab -c user.email=lab@example.invalid commit -qm copy; mkdir "$d/.nm-tmp"; echo '.nm-tmp/' >> "$d/.git/info/exclude"; echo "$d"; }
run() { local d=$1 label=$2; echo "== $label: copy=$d TMPDIR=$d/.nm-tmp start=$(date -u +%FT%TZ)";
  (cd "$d" && env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMPDIR="$d/.nm-tmp" bash tests/fm-task-delivery.test.sh > "$d/.nm-out" 2>&1); r=$?
  echo "suite exit=$r end=$(date -u +%FT%TZ)"; grep -nE "^ok|^not ok|registered forge contract|promotion should take the registered forge|firstmate's own repository|shares firstmate" "$d/.nm-out" | head -8
  echo "fake project inside enclosing checkout? lineage probe: $(git -C "$d/.nm-tmp" rev-parse --show-toplevel 2>&1)"; }
a=$(mk); run "$a" "A head fixture"
b=$(mk); python3 - "$b/tests/fm-task-delivery.test.sh" <<'PY'
import sys;p=sys.argv[1];s=open(p).read()
old="""  git -C "$home/projects/proj" init -q || fail 'could not initialize the promotion project fixture'\n"""
assert s.count(old)==1; open(p,'w').write(s.replace(old,''))
PY
(cd "$b" && git diff --stat); run "$b" "B fixture without its own project repo"
rm -rf "$a" "$b"; echo "left: $(ls -d "$a" "$b" 2>/dev/null || echo none)"; echo "worktree dirty=$(git -C "$WT" status --short | wc -l | tr -d ' ')"
