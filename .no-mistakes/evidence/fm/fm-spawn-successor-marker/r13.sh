# r13 <task-id>: carry labpred1's exact commits onto the task branch, then run
# Vernant's real R-13 hook (scripts/hooks/pre_push_base_ref_staleness.py at
# 06a185533) with the pre-push stdin for pushing that branch.
r13() {
  local id=$1 wt sha rc
  wt=$(grep '^worktree=' "$FM_HOME/state/$id.meta" | cut -d= -f2)
  echo "=== R-13 for $id ($wt)"
  git -C "$wt" merge -q --ff-only fm/labpred1 && echo "carried: $(git -C "$wt" log --oneline -1)"
  sha=$(git -C "$wt" rev-parse HEAD)
  echo "\$ printf 'refs/heads/fm/$id $sha refs/heads/fm/$id 0000…' | python3 scripts/hooks/pre_push_base_ref_staleness.py origin <lab origin>"
  (cd "$wt" && printf 'refs/heads/fm/%s %s refs/heads/fm/%s %s\n' "$id" "$sha" "$id" 0000000000000000000000000000000000000000 |
    PATH="$P/.venv/bin:$PATH" python3 scripts/hooks/pre_push_base_ref_staleness.py origin "$(git remote get-url origin)" 2>&1)
  rc=$?
  echo "R-13 exit=$rc ($( [ $rc -eq 0 ] && echo accepts || echo blocks ))"
}
