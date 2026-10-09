---
name: validation-supervision
description: Load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, when a failed or aborted run's branch needs custody returned (status offers `recover_custody` or `inspect_and_reconcile_manually`), and before deciding or answering any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
`bin/fm-dod-lib.sh` owns the worker-side `--intent` contract.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery when its code is `recover_custody`, take the diverged-head route below when it is `inspect_and_reconcile_manually`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the resolved state line from [`bin/fm-crew-state.sh`](../../../bin/fm-crew-state.sh), whose header owns outcome mappings and CI-monitor/daemon exceptions, never by shell liveness, the last status event, or a raw run record.
Workers parked at approval or fix-review must follow the active gate help.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## Custody return when the pipeline head diverged

A run that ended failed or aborted with pipeline commits the worker copy does not hold reports `branch_sync.state` `pipeline_owned` and `branch_sync.next_action.code` `inspect_and_reconcile_manually`, and `axi sync --check` is blocked.
The copy sits clean at the submitted head S and the gate holds a different pipeline head P.
`axi sync --recover` is not offered until an archive of P is bound, so this state is the route below and not a reason to wait for a ruling.
Firstmate sends this route to the worker that owns the run, with the run id, S and P, as authorization for exactly these steps.
Stop at the first refusal, conflict, or mismatch and report the exact output.
Never force, waive, edit no-mistakes records or gate refs, delete a ref or bundle, or start a second run while the failed or aborted run still owns the branch.
Run every git command directly, never inside a script, alias, subshell, or other wrapper, because getting a guarded command past a project guard that way is a guard escape.

1. Confirm `axi status` still shows the run failed or aborted, the tree is clean, `HEAD` is S, and P resolves in the run's gate repository.
2. Create `git branch archive/<task>-submitted-<S8> <S>`, then fetch the recovery object without an archive destination: `git fetch --no-tags <gate repo> refs/no-mistakes/recover/<run>`.
   Verify `FETCH_HEAD` resolves to P, then create `git branch archive/<task>-pipeline-<P8> <P>`.
   Both branch creations must refuse an existing name; verify each archive resolves to its expected commit.
3. Run `no-mistakes axi sync --bind-archive-ref refs/heads/archive/<task>-pipeline-<P8>` and read `axi status`.
   Then run only the recovery it now offers, `no-mistakes axi sync --recover --keep-local`, and confirm `branch_sync.state` is `custody_returned` on a clean tree.
   Bind while the run still owns P and before anything moves the branch: `blocked_recover_archive_not_applicable` means custody already returned or the branch moved, and the step stops there.
   If the captain invalidated this work, custody recovery is complete: return to the supersession workflow above, replace the obsolete work from the correct pre-invalidation base, and validate once with the replacement intent. Do not adopt P or perform steps 4–6.
4. Run `git reset --keep refs/heads/archive/<task>-pipeline-<P8>` to adopt P.
   Then `git range-diff` the submitted commits against the new head and report any submitted commit that is missing.
5. A fresh run refuses at the private-mirror guard until S is an ancestor of the head, because the gate's mirror branch still holds S.
   Do not record this with `git merge -s ours`: a project can forbid that merge with no allowed form.
   Replay instead, before adding any commit or merging main, so the range holds no merge commit.
   Let B be the pipeline's rebased copy of the submitted commits, the commit just below the first pipeline fix commit.
   Prove both of these first: `git cherry -v <B> <S>` prints no `+` line, and `git diff --quiet <S> <B> -- <files>` passes for every file that `<B>..HEAD` changes.
   If either proof fails, stop and report the output.
   Run `git reset --keep refs/heads/archive/<task>-submitted-<S8>` and cherry-pick every commit of `git rev-list --reverse <B>..refs/heads/archive/<task>-pipeline-<P8>` in that order.
   A merge commit in the range cannot be picked without a mainline: stop and report it rather than choose one.
6. Prove `git merge-base --is-ancestor <S> HEAD` exits 0, `git range-diff <B>..refs/heads/archive/<task>-pipeline-<P8> <S>..HEAD` shows every commit as `=`, and `no-mistakes axi sync --check` offers `run_pipeline`.
   Then start exactly one fresh run with the original intent; its rebase step restores a newer main base.
