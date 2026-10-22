#!/usr/bin/env bash
# Live driver, GitLab branch: real bin/fm-pr-merge.sh + bin/fm-review-record.py
# in a disposable marked lab home; glab/gh on PATH are local stubs.
set -u
REPO=$1 EV=$2
fail() { echo "STUB-FAIL: $*" >&2; exit 99; }
. "$EV/forge-stub-lib.sh"; . "$EV/forge-stub-gitlab-lib.sh"
URL=https://gitlab.example/group/subgroup/project/-/merge_requests/7
LABS=(); trap 'for l in "${LABS[@]}"; do rm -rf "$l"; done' EXIT
new_lab() {
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); CASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-forge.XXXXXX"); LABS+=("$LAB" "$CASE")
  "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || fail "lab create"
  mkdir -p "$CASE/fakebin" "$LAB/data" "$LAB/state"
  git -C "$CASE" init -q -b main wt && printf 'x\n' > "$CASE/wt/README.md" && git -C "$CASE/wt" add README.md \
    && git -C "$CASE/wt" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
  git -C "$CASE/wt" update-ref refs/remotes/origin/main "$(git -C "$CASE/wt" rev-parse HEAD)"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  printf '%s\n' window=fm-task-x1 "worktree=$CASE/wt" "project=$CASE/project" kind=ship mode=no-mistakes > "$LAB/state/task-x1.meta"
  add_glab_mock "$CASE"; : > "$CASE/glab.log"
  write_mr_json "$CASE/mr.json"; write_mr_json "$CASE/mr-post.json" state=merged
}
rec() { (cd / && env -u FM_STATE_OVERRIDE FM_HOME="$LAB" python3 "$REPO/bin/fm-review-record.py" "$@"); }
show() { local name=$1 expect=$2 rc=0; shift 2
  echo "=== SCENARIO: $name (expect $expect)"
  echo "--- ledger:"; cat "$LAB/state/review-records.jsonl" 2>/dev/null || echo "(no ledger)"
  echo "\$ FM_HOME=\$LAB bin/fm-pr-merge.sh task-x1 $*"
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$LAB" HOME="$CASE/user-home" PATH="$CASE/fakebin:$PATH" \
    FM_TEST_GLAB_LOG="$CASE/glab.log" FM_TEST_GLAB_JSON="$CASE/mr.json" "$REPO/bin/fm-pr-merge.sh" task-x1 "$@" > "$CASE/out" 2> "$CASE/err" || rc=$?
  echo "--- exit: $rc"; echo "--- stderr:"; grep -v '●' "$CASE/err" | sed 's/^/  /'
  echo "--- forge merge calls:"; grep ' mr merge ' "$CASE/glab.log" | sed 's/^/  /' || echo "  (none)"
  local merged=no; grep -q ' mr merge ' "$CASE/glab.log" && merged=yes
  if { [ "$expect" = merge ] && [ "$rc" = 0 ] && [ $merged = yes ]; } || { [ "$expect" = refuse ] && [ "$rc" != 0 ] && [ $merged = no ]; }; then
    echo "RESULT: PASS ($name)"; else echo "RESULT: FAIL ($name)"; fi; echo
}
new_lab; show "G1 GitLab MR, no review record" refuse "$URL"
new_lab; rec review --pr "$URL" --head "$MR_HEAD" --verdict PASS --reader-model gemini-3-pro --author-groups '{"all":["claude-opus-5-5"]}' \
  --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report /tmp/r.md >/dev/null
show "G2 GitLab MR, google reader PASS at live head over anthropic author" merge "$URL"
