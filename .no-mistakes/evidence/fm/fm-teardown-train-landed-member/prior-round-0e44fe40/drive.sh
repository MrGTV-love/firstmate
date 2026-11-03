#!/usr/bin/env bash
# Scratch driver: runs the real bin/fm-teardown.sh on sandbox fixtures built by
# tests/fm-teardown-helpers.sh (temp git world, fake gh forge, logging treehouse).
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6G0SSW287C5ENA2421F4C38
. "$WT/tests/fm-teardown-helpers.sh"
show() {  # <case> <label>
  local c=$1 rc=0
  run_teardown "$c" > "$c/stdout" 2> "$c/stderr" || rc=$?
  echo "=== $2"
  echo "exit: $rc"
  echo "--- stderr:"; cat "$c/stderr"
  echo "--- treehouse calls: $(cat "$c/treehouse.log" 2>/dev/null | tr '\n' ';')"
  echo "--- task record present: $([ -e "$c/state/task-x1.meta" ] && echo yes || echo no)"
  [ ! -f "$c/data/backlog.md" ] || { echo "--- backlog:"; cat "$c/data/backlog.md"; }
  echo
}

# A. happy path: member CLOSED, merged train lists it at its head and contains it.
train_case drive-accept none head
seed_backlog_in_flight "$TRAIN_CASE"
show "$TRAIN_CASE" "A. verified merged train lists the closed member at its head: accept"

# B. squash-landed train, pre-rebase copy.
train_case drive-squash-prerebase squash prerebase
show "$TRAIN_CASE" "B. squash-landed train, copy on pre-rebase head with the same patches: accept"

# C. adversarial: a train that only mentions pull/70 (prefix trap) does not count.
train_case drive-prefix none head
train_list "$TRAIN_CASE" 9 MERGED main "$TRAIN_HEAD" "$(train_body https://github.com/example/repo/pull/70 "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "C. train lists pull/70, not pull/7: refuse"

# D. adversarial: copy holds a commit the train never carried.
train_case drive-extra none extra
show "$TRAIN_CASE" "D. copy has an unlanded commit after the listed head: refuse, naming it"

# E. adversarial: forge search fails.
train_case drive-searchfail none head
: > "$TRAIN_CASE/gh-fixture/list.fail"
show "$TRAIN_CASE" "E. forge search fails: refuse as unknown, retry"

# F. adversarial: train OPEN (not merged).
train_case drive-open none head
train_list "$TRAIN_CASE" 9 OPEN main "$TRAIN_HEAD" "$(train_body "$TRAIN_MEMBER_URL" "$TRAIN_MEMBER_HEAD")"
show "$TRAIN_CASE" "F. train PR is OPEN: refuse"

# G. live d1 B5 shape: the copy is the pipeline's INPUT; the pipeline rewrote it
# (a.txt reviewed, extra review commit) and pushed the member head; the member PR
# is CLOSED and a merged train lists that pushed head and contains it.
c=$(make_case drive-pipeline-input-train)
write_meta "$c" no-mistakes ship
pr_head=$(setup_pipeline_rewritten_history "$c" rewritten-input)
printf '%s\n' 'pr=https://github.com/example/repo/pull/7' "pr_head=$pr_head" >> "$c/state/task-x1.meta"
add_gh_train_fake "$c" CLOSED "$pr_head"
tmp="$c/_train"
git clone -q "$c/origin.git" "$tmp"
git -C "$tmp" fetch -q origin refs/pull/7/head
git -C "$tmp" checkout -q -b train origin/main~1
git -C "$tmp" -c user.email=t@t -c user.name=t merge -q --no-ff --no-edit "$pr_head"
printf '%s\n' second > "$tmp/second.txt"; git -C "$tmp" add second.txt
git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "second member"
th=$(git -C "$tmp" rev-parse HEAD); git -C "$tmp" push -q origin HEAD:refs/pull/9/head; rm -rf "$tmp"
git -C "$c/wt" fetch -q origin refs/pull/7/head refs/pull/9/head
train_list "$c" 9 MERGED main "$th" "$(train_body "$TRAIN_MEMBER_URL" "$pr_head")"
add_logging_treehouse "$c"
echo "(G setup: copy HEAD $(git -C "$c/wt" rev-parse --short HEAD), member head ${pr_head:0:8}, train head ${th:0:8}; train contains member head: $(git -C "$c/wt" merge-base --is-ancestor "$pr_head" "$th" && echo yes || echo no))"
show "$c" "G1. pipeline-input copy, member CLOSED, verified train, no run record"
write_nm_run_record "$c" 01RUNINPUT "https://github.com/example/repo/pull/7" "$(git -C "$c/wt" rev-parse HEAD)" "$pr_head"
show "$c" "G2. same, with a no-mistakes run record tying the copy to the pushed member head"

# H. contrast: same pipeline-input copy, member MERGED, with run record (existing own-PR route).
c=$(make_case drive-pipeline-input-merged)
write_meta "$c" no-mistakes ship
pr_head=$(setup_pipeline_rewritten_history "$c" rewritten-input)
printf '%s\n' 'pr=https://github.com/example/repo/pull/7' "pr_head=$pr_head" >> "$c/state/task-x1.meta"
add_gh_pr_merged_for_head "$c" "$pr_head"
write_nm_run_record "$c" 01RUNINPUT "https://github.com/example/repo/pull/7" "$(git -C "$c/wt" rev-parse HEAD)" "$pr_head"
add_logging_treehouse "$c"
show "$c" "H. contrast: same pipeline-input copy when the member PR itself is MERGED"
