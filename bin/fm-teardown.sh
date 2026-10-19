#!/usr/bin/env bash
# Tear down a finished task: return the treehouse worktree, release the Orca
# worktree, or retire a secondmate home; kill the recorded runtime endpoint,
# clear volatile state, and transition this home's backlog item for ship and
# scout tasks before reporting success (a secondmate teardown transitions none,
# since secondmates are not backlog items), then refresh/prune the project's
# clone for PR-based ship tasks.
# An endpoint whose close could not do its job REFUSES before any record naming
# it is removed: those records are the only thing that names what survived, so
# reporting such a close as a completed cleanup strands the endpoint instead of
# merely leaving it behind. endpoint_close_refusal below owns that refusal and
# the one site where --force overrides it, and bin/fm-backend.sh's
# fm_backend_kill owns what each backend can prove about its own close - an
# already-exited endpoint is not a failure and stays silent.
# bin/fm-backlog-transition-lib.sh owns the fused metadata/backlog transition,
# its exemptions, and the pending-close lifecycle in its CRASH RECOVERY header.
# Teardown reports manual follow-up for exempt homes; an automatic transition
# failure is fatal and loud rather than reporting cleanup success.
# The close - and only the close - is replaced by `tasks-axi reopen` with the
# deliverable recorded while the backlog item is still an open captain call
# (bin/fm-captain-hold.sh `open` owns that predicate), because the policy holds
# the very work item a question gates and cleanup must never retire the
# captain's own question.
# NOTE: this uses `open`'s silent default and depends only on its unchanged
# 0/1/2 exit-code contract. The optional `--identity` output that bin/fm-watch.sh
# asks for prints only on an exit 0 and changes nothing read here.
# The same pending-close record carries that intent as
# `mode=retain`, so an interrupted cleanup replays the retention rather than a
# close. "Cannot tell" refuses before any destructive step, --force does not
# lift the deferral (it authorizes discarding unlanded WORK, never the
# captain's question), and bin/fm-captain-hold.sh answer stays the only act
# that closes the call.
# Automatic sweep calls additionally require reap eligibility before cleanup;
# bin/fm-idle-session-reap.sh's header owns that admission contract.
# The captain-call retention path below applies to ordinary teardown admission.
# REFUSES if a ship's deliverable has not LANDED and its locally-only tips
# lack recorded bundle preservation below, because cleanup hard-resets/removes
# the worktree and kills its processes.
# A pushed branch is recoverable work, not a delivered result.
# A ship has landed only when its PR is merged and
# GitHub reports a PR head that contains the current local work, or its content is
# already present in the up-to-date default branch. This recognizes the common
# squash-merge-then-delete-branch flow, where the branch's own commits live nowhere
# on a remote yet the change is fully in main. A task whose meta records
# base_branch= (bin/fm-spawn.sh) runs that content check against origin's copy of
# its base branch instead of the default branch.
# Squash merges collapse the branch's commits, so per-commit patch ids against main
# no longer match, and a pipeline rebase can leave the local worktree diverged from
# the PR head. A diverged copy is not treated as landed: path-set coverage, git
# cherry, and merge-tree containment each fail to prove content landed without also
# accepting unlanded edits to the same paths. Teardown still accepts a merged PR
# whose head contains the current local work (ancestor or equivalent patch ids),
# or a clean content-in-default tree match. A copy left on pre-rebase commits
# (even ones pushed to another remote) is also accepted when every commit the PR
# head and the default branch lack has a patch id among the PR head's own commits
# and each merge commit is exactly what git produces from its parents; a refusal
# then names the commits that are not proven. The pipeline's own review and
# document steps rewrite and add commits, so a copy that was the pipeline's input
# is also accepted when the no-mistakes run record proves it: a run whose pr_url is
# the merged PR pushed exactly the merged PR head (last_pushed_sha), and the copy's
# HEAD is that run's input head (submitted_head_sha). A copy at any other commit,
# a run that pushed another head, or a missing record
# (state database, run row, pushed head, input head) refuses and names the record.
# Recorded bundle preservation is a cleanup alternative, not proof of delivery.
# Its record is $DATA/$ID/preservation-bundles.tsv (normally
# $FM_HOME/data/<task-id>/preservation-bundles.tsv): exactly ONE line of three
# TAB-separated fields: absolute bundle path, lowercase SHA-256 (64 hex), and
# space-separated full commit tips advertised by git bundle list-heads.
# Re-bundling replaces the line; a record of more than one line, or a blank or
# malformed one, refuses. The path cannot contain TAB, CR or newline.
# The record and bundle must be regular nonsymlink files. The bundle's physical
# parent must be outside every registered copy (symlink aliases included), every
# enclosing Treehouse pool (non-copy directories in it included) and every
# scratch root this teardown removes: the task's tasktmp, its launch-home temp
# root, and $STATE/<task-id>.inbox and .git-hooks.
# The recorded bundle must pass git bundle verify in the copy, match its recorded
# SHA-256, advertise and record every maximal tip of git rev-list --children
# <ref> <branches> --not --remotes, and restore on its own: fetching every
# recorded tip from it into a fresh empty repository outside the copy and pool
# must succeed and pass git fsck --connectivity-only.
# <ref> is the copy's HEAD (detached included) or a removed copy's branch tip.
# <branches> are the local branches no live worktree has checked out, so side
# branches count; a branch checked out in another worktree whose directory still
# exists is that task's own, but a branch whose worktree directory is gone or
# prunable counts. A thin bundle, a truncated pack or a missing tip refuses.
# Ancestors need not be separate bundle heads.
# No unlanded tip means this alternative proves nothing: pushed-but-undelivered
# ships still require the existing delivery proof. Every proof reads the record
# and the bundle's digest again and verifies coverage again; only a completed
# isolated restore is remembered in this process, by bundle digest, object
# format and recorded tips, so the final custody rechecks and the nested, prior
# and foreign copy proofs do not repeat it. Nothing is cached on disk.
# Success prints the bundle path, hash and preserved tips, and never waives dirt,
# ignored-file preservation, process, ownership or closeout-driver proofs.
# A ship kept only by its bundle closes its backlog item with the note
# "preserved in bundle <bundle path>, not landed", never a PR or "local main";
# bin/fm-landed-lib.sh keeps such a row out of Recently Landed.
# A Vernant-locked copy still needs its driver's independent landing verdict.
# To create a self-contained bundle and its record (no creator is run by teardown),
# choose an absolute durable bundle path OUTSIDE every copy, pool and scratch root,
# set copy, task and FM_HOME explicitly, then run under bash:
#   bundle=/durable/preservation/task.bundle
#   mkdir -p "${bundle%/*}" "$FM_HOME/data/$task"
#   git -C "$copy" bundle create "$bundle" --all &&
#   git -C "$copy" bundle verify "$bundle" &&
#   digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
#   tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
#   printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$FM_HOME/data/$task/preservation-bundles.tsv"
# Keep the bundle and record until the preserved commits are no longer needed;
# data/<task> survives cleanup. Restore into a new repository with
# git -C <restore-repo> fetch <bundle-path> <tip-sha>:refs/heads/recovered.
# Anything else refuses.
# The PR itself is resolved from the task's recorded pr= when present, or - when
# no pr= was ever recorded (e.g. a yolo-authorized merge on a repo with no PR CI,
# where the usual "checks green" fm-pr-check.sh trigger never fires) - by looking
# up a merged PR whose head branch matches the worktree's branch, fetching its head
# via refs/pull/<n>/head when the branch itself was deleted. So a missing pr= never
# by itself causes a false refusal of landed work.
# A gh lookup error falls back to the content check; if that is also inconclusive,
# teardown refuses rather than risk discarding unlanded work.
# Uncommitted changes are never landed; dirty refusals distinguish untracked-only
# leftovers from tracked edits and list at most ten non-exempt untracked paths.
# local-only projects additionally accept a clean existing copy whose HEAD is
# contained in refs/heads/<default>, regardless of remote reachability.
# An absent recorded copy or one that is not a Git worktree completes only
# when its recorded GitHub PR is confirmed merged by the forge, or through
# captain-authorized forced discard below; otherwise the backlog stays open.
# The one exception is a task's own nested copy that an earlier teardown
# removed: teardown_nested_slot judges it first by its branch= ref.
# After landing and runtime cleanup pass, ship teardown also reaps only local
# archive/<task>-{submitted,pipeline}-<8 lowercase hex> branches whose exact head
# is an ancestor of the merged PR head, or whose non-merge commits all have
# equivalent patches in that head.
# The PR head must match its forge-reported merge commit on every changed path.
# Forced discard, unavailable proof, non-ancestor merge commits, checked-out
# archives, or a concurrently moved ref keep the archive and name it; another
# task's refs and records-only shared/reassigned slots remain untouched.
# Scout tasks (kind=scout in meta) carve out of that check: their worktree is
# declared scratch and the regular, nonsymlink, nonempty report at
# data/<task-id>/report.md is the work product. Non-forced teardown also requires
# the shared unresolved-decision completion gate to verify its captain-held inventory.
# A scratch copy (kind=scout) and a --force run discard untracked content.
# Treehouse's return resets with `git clean -fd`, which never deletes a nested
# git repository, so the pool slot stays dirty and later checkouts skip it.
# Before that return, teardown runs `git clean -ffdq` in the copy, and a forced
# secondmate teardown does the same in each child copy it returns.
# The second -f removes nested repositories, and -x stays off so ignored files remain.
# A ship teardown without --force does not run that clean: it refuses untracked
# entries, except those under the .claude/ allowance, so a nested repository
# there can still survive the return.
# After a return that succeeds, teardown reads `git status --porcelain --untracked-files=all`.
# Any remaining output, a status read that fails, or a copy that is missing or
# no longer a readable worktree is reported at once with the lost pool slot and
# what remains. Teardown then finishes every cleanup step, reports the lost slot
# instead of a clean return, and exits 4. Exit 4 means only "cleaned up, but a
# returned pool slot was lost"; refusals and errors exit 1, and an invalid
# request exits 2. A local retirement of a remote secondmate whose remote run
# exits 4 still completes locally, forwards only the remote lost-slot warning
# to stderr, and then exits 4.
# Before destructive cleanup, teardown validates task check artifacts as
# ordinary single-link files on the state device. It refuses and preserves
# task state when that proof fails; otherwise it removes the task's check,
# trust record, PR sidecar, and publication record with the rest of the
# volatile state.
# That volatile state includes the watcher's per-task .seen-* signature for
# the task's turn-ended file, minted by bin/fm-wake-lib.sh (the .seen-*
# signature for its status file and its .hb-surfaced- heartbeat marker are
# already retired by status_retire_presentation_task) - and, once the
# recorded pane is proven gone, an orphaned Herdr presentation journal: a
# binding of exactly that pane, or a version 1 attempt whose
# token-bearing projected workspace is itself confirmed gone, names nothing the
# session-start sweep could still close, while a journal bound to any other pane
# - or a version 1 attempt whose workspace is still present or unreadable - may
# name a live quarantined space and is retained for that sweep.
# data/<id>/ is deliberately left in place: a successor spawn reads brief.md
# from it.
# Worktree-slot ownership (teardown-slot-collision): a treehouse pool slot is
# reused across tasks, so a stale, duplicated, or drifted worktree= record can
# name a slot a DIFFERENT live task now holds. Cleanup reaps task-owned processes
# and hard-resets the path before returning it, so releasing a slot that is not
# genuinely this task's destroys another worker's live work. Before the first
# cleanup step, teardown verifies record exclusivity: no OTHER task record in
# this home or any locally registered Firstmate home may name the same live path
# in its worktree=, home=, or prior_worktree=. One live path with two task records
# is the reuse collision itself, whichever record is stale. A non-forcing
# cleanup of a finished ship or scout sharing a pool slot with another
# ordinary root record is records-only, even for a nested copy: it skips
# slot-wide cleanup, proves
# delivery from its recorded PR or own branch when its record names the shared
# root (a nested own copy keeps the ordinary dirty and landed-work proof and
# stays in place; a scout still needs its report and completion gate), and
# releases only its own Firstmate claim beside the slot. Before that, while this task still holds the slot's claim or the slot
# carries none, Treehouse's state must durably hold the slot under
# fm_task_copy_pool_slot_held's proof, protecting the interval before the
# remaining record moves; an unleased-slot refusal names the state-only lease
# remedy, while a recovered-state lease has none (docs/agent-control.md). A root
# record whose slot claim names another task is not on this route: the slot
# was reassigned, so it needs no lease proof and keeps the reassigned-slot
# cleanup below, which leaves that claim intact.
# Treehouse's lease and every copy, branch and file under the slot stay
# untouched; slot-wide run/process cleanup and post-cleanup branch pruning
# are skipped, but a retiring task's own nested copy gets the ordinary
# identity-proven run, private launch-agent and process cleanup, then its
# ordinary safety recheck before its claim or record goes. Retire other
# finished shared records the same way, then use
# fm-control reassociate for the remaining record's real copy;
# docs/agent-control.md owns that route.
# A slot whose owner claim (below) names another task likewise touches nothing
# under the slot. Its exclusive return scan, dirty/landed-copy admission and
# post-cleanup clone sync are skipped: that copy and its Git refs belong to the
# claimant, not the stale task whose endpoint and records are being retired.
# Like the shared root, it still proves delivery from its recorded PR or own
# branch, and refuses with its records in place otherwise.
# Forced cleanup keeps its existing overlap refusals; this records-only
# shared-root route never needs --force.
# Two or more live ordinary records can work in their own copies nested in one
# pool slot, each naming the slot as prior_worktree= (the shape
# bin/fm-control.sh reassociate --also leaves). A task's cleanup then removes
# only its own current copy, once the ordinary dirty and landed-work proof and
# the closeout-driver proofs below pass for that copy alone, and leaves the
# slot, Treehouse's lease, every other record and every copy in it untouched:
# it reserves, reaps, scans and returns nothing slot-wide, and passes the slot's
# claim to the first remaining peer when it was this task's. A peer's
# prior_worktree= custody is passed over only while
# bin/fm-task-copy-lib.sh's fm_task_copy_prior_root_released proves that peer
# works in its own copy inside the slot and no other record still names the slot
# or a directory enclosing it as worktree= or home=; any other overlap keeps its
# refusal. The last task out returns the slot by the ordinary route, with its
# foreign-copy proofs (docs/agent-control.md owns the rule).
# That scan alone cannot prove THIS record is the current owner, because the task
# that took the slot next may leave no record it can reach - its own worker may
# have exited and its record been cleaned up, or it may live in a home this
# machine does not register - which is how a released-then-reassigned slot was
# returned out from under a live worker (observed 2026-09-07). So teardown also
# reads the slot's own owner claim, written by bin/fm-spawn.sh at the moment the
# slot is taken and dropped here once it is genuinely returned; bin/fm-wake-lib.sh
# owns the claim, its location, and its states. A claim naming another task is
# proof of reassignment: the slot is no longer this task's, so teardown warns,
# names the claimant, and then finishes only this task's own endpoint and records.
# A claim that cannot be read proves nothing either way and refuses; inspect or
# repair the claim file at the printed path and re-run - never remove it, since
# an absent claim proceeds and would return a slot that may be another task's. An
# absent claim - a slot taken before claims existed, or already returned - keeps
# the record-scan protection, because refusing it would strand every task in
# flight across that change on no evidence at all. Independently, before any
# forced Treehouse return of a Git directory (pool slot or not), its Git
# worktree registrations must contain no nested
# copy outside this task's individually proven copies; otherwise teardown
# refuses, even with --force, and names each such copy. If an active record
# owns that copy's work, reassociate that task to it first. A nested copy that
# no record of this task names is a foreign copy (Vernant's
# start_task_worktree.py creates and locks one at <slot>/.claude/worktrees/<name>),
# and teardown releases it only after it proves all of: no other active task
# record names it; no process outside this teardown runs in it and no live
# process outside this teardown is its lock launcher (a process is teardown's
# own when it, or an ancestor by parent chain, has a cwd exactly at a root retire
# sweeps, and a launcher pid that started after the lock file was written is a
# recycled pid and owns nothing); retire sends TERM to each such launcher and
# each such process running in the copy, waits a bounded time, and sends no KILL,
# and one still alive refuses the release, named by its pid, while a process
# that is not teardown's own is never signalled and refuses at once, named by its
# pid; it is a clean worktree root, and each ignored file it holds is either
# regenerable machinery or copied with its SHA-256 into the task's data
# directory before removal; and its work is landed by the existing landed-work
# rule. A copy whose work is not proved landed stays, with the reason written.
# A copy locked by Vernant's creation lock (vernant-session-active
# owner=launcher:<pid> launcher=<pid>) is released and removed by Vernant's own
# driver, scripts/git-stability/closeout_pr.py --cleanup-worktree <copy>
# --execute-cleanup, run from the slot (FM_TEARDOWN_VERNANT_PYTHON names the
# interpreter); an unlocked copy is removed with a plain non-forced git worktree
# remove. Removal deletes the copy's checkout and the allow-listed ignored files
# in it (symlinks, virtual environments, node_modules and tool caches,
# .DS_Store, Firstmate's hook files, regenerable build caches, and anything
# ignored under its .claude and .opencode trees); any other ignored entry is
# preserved first in data/<task>/nested-copy-preserved with its SHA-256. It loses
# no commit, because the work is landed, and no tracked change, because the clean
# proof refuses one. The clean proof skips
# untracked files under .claude only; the ignored-file proof skips ignored files
# under .claude and .opencode; plain git worktree remove still refuses a copy
# that holds an untracked file. On the pool-slot route the release runs before
# the final project-lock wait, so the driver never runs while the lock is held,
# except when teardown keeps project custody through the return. A lock in any
# other format, a driver refusal, or a copy still registered afterwards refuses.
# The task's own nested copy that Vernant's creation lock holds takes the same
# driver route instead of a forced removal, before the final project-lock wait
# like a foreign copy, after the clean and landed proof and the same ignored-file,
# record, process and launcher proofs; an own copy that is not locked is removed
# as before.
# Every other case, including a half-removed copy, refuses as before; --force
# never waives these proofs. The by-hand route is in docs/agent-control.md.
# Why Treehouse's own state cannot answer this for crewmate slots, and why the
# claim file sits on top of it, is owned by bin/fm-wake-lib.sh's slot-owner
# claim comment.
# The recorded endpoint's exact task identity and the record's spawn incarnation
# are validated separately
# before cleanup. Its current working directory is only incidental process
# state: the same worker remains the owner after changing directory, so cwd can
# never veto teardown of that exact recorded endpoint.
# The ownership scan and pool mutations hold a project-identity lock in the
# local root Firstmate home's state directory, as resolved by
# bin/fm-wake-lib.sh's fm_firstmate_root_home; a home seeded from another
# machine anchors its own lock. Fresh Treehouse spawns hold that same lock
# from allocation through metadata publication, closing the publication gap.
# Ordinary teardown takes it briefly to prove ownership, again after every
# non-destructive refusal check to recheck ownership and reserve its slot with
# Treehouse's state-only durable lease, and finally to recheck, return the slot
# and remove the record that names it. A refusal before that reservation
# leaves no new lease; a failed cleanup after it retains the lease.
# A recheck that finds the slot's claim now names another task reserves and
# returns nothing: the earlier landed-work proof may have read the claimant's
# copy, so teardown releases project custody and re-proves this record's own
# delivery as the reassigned-slot cleanup above does, before its next
# destructive step, refusing with its records in place when that proof fails.
# That holds when the record's copy is the slot itself. A reassociated copy
# nested inside the slot stays this task's own whoever the claim names: only the
# slot steps are dropped, and the copy's runtime is retired and its landing
# proved exactly as for any reassociated copy.
# A slot whose state is neither held nor unleased (recovered, conflicting,
# unreadable, or needing jq), or an unleased slot whose installed treehouse is
# missing or has no lease command (probed once with treehouse lease --help),
# cannot be reserved; teardown logs that state and keeps project custody from
# the reservation point through the return with treehouse return --force, as
# before the narrowing.
# Pipeline conclusion, process reaping, endpoint closure, status retirement,
# backlog completion and clone sync otherwise run outside project custody.
# Successful landing proofs bind to immutable commits; final dirty/HEAD checks
# reuse those proofs without doing forge or fetch work while the narrowed lock
# is held.
# Forced secondmate teardown proves every descendant under its project locks
# just before its first child is touched, durably reserves the owned slots and
# releases project custody before slow cleanup, or keeps every descendant lock
# through cleanup when a slot cannot be reserved. Each actual child return and
# matching record removal otherwise takes only that child's project lock and
# releases it immediately. A refused return of a child whose own slot is
# durably leased, whatever state its siblings' slots are in, keeps that slot,
# the child's record and the pending-return record for a retry; only a child
# whose slot was never leased, and so ran under whole-cleanup custody, falls
# back to the guarded raw removal of its copy.
# Project-lock contention uses bin/fm-project-lock-lib.sh's FIFO wait, which
# refuses only when the holder stalls past the measured allowance, with holder
# progress messages; callers no longer need retry loops for allocation/return
# contention. Before anything is closed, the idle reaper's teardown
# (FM_IDLE_REAP_ADMISSION=1) instead makes nonwaiting ownership and reservation
# attempts, so contention exits FM_PROJECT_LOCK_BUSY_EXIT with nothing closed
# and the next sweep retries. Once processes or endpoints may be gone, the
# reaper's return stage and every forced child return wait in that FIFO queue
# instead, each waited admission follows the progress-based idle allowance and
# 30-minute telemetry-uncertainty extreme owned by bin/fm-project-lock-lib.sh.
# Independently, the reaper's 600s teardown limit ends an overlong teardown,
# which keeps its durable record and is retried by the next sweep without a
# refusal memo.
# As soon as a slot is reserved, or this task's own claim
# beside a slot another task leases awaits release, and before any cleanup
# that can fail and before the pending backlog close is published, teardown
# records state/<id>.teardown-return-pending (bin/fm-wake-lib.sh's
# fm_teardown_return_pending owns the contract; a forced secondmate teardown
# records it for itself, naming the child; an accepted --legacy-record stamp
# rebinds it to the stamped generation, and a rolled-back stamp rebinds it
# back). Any later refusal keeps that
# durable record: the open-work ledger reports it, session-start backlog
# replay leaves the record for the retry, the idle reaper selects the task by
# that record unless its worker reads busy again, and every project
# admission of that retry, including ownership and reservation, waits in the
# FIFO queue. A waited admission that reaches the stall limit exits
# FM_PROJECT_LOCK_BUSY_EXIT, so the next sweep retries it rather than standing
# on a refusal memo; a lock error keeps exit 1 and is recorded as a refusal.
# Project holders never wait for task custody (fresh spawn refuses a held
# task-set lock), so these waits cannot deadlock with the descendant locks
# recursive cleanup holds.
# Recursive cleanup already holds every descendant home's lifecycle locks, so
# its admission makes one nonwaiting attempt per descendant project lock that
# never jumps a queued waiter; it collects and deduplicates those paths and
# tries them in global byte order before slot proofs, so opposite child
# enumeration orders cannot each hold the project the other needs.
# Project waits run after this task's lease-guard, control and metadata locks,
# so a steer or control action on this same task waits for teardown; no other
# task waits on those locks. Project custody never spans a wait for task custody,
# which would stall unrelated allocation behind that task's lifecycle action.
# Other lifecycle lock refusals are unchanged.
# These refusals are not relaxed by --force: --force authorizes discarding THIS
# task's unlanded work, never another task's live work. Nothing of this task's
# own is removed by a refusal; reconcile whichever record is wrong and re-run.
# Orca tasks use the same safety checks, then close the recorded terminal and
# remove the recorded worktree through `orca worktree rm`; teardown never guesses
# an Orca target from ambient CLI state.
# A Herdr presentation journal never authorizes cleanup. Teardown still closes
# only the exact task pane from ordinary endpoint metadata and never calls
# `workspace close`. It retires the non-authoritative journal only when a
# read-only token correlation agrees with that endpoint and pane closure is
# confirmed. Otherwise the journal stays quarantined for manual inspection.
# Projected closes share the presentation-order lock, refuse to close the
# captain's active tab, and restore the exact response-derived pre-close tab
# if Herdr's last-pane cleanup focuses an unrelated neighboring workspace.
# Secondmates (kind=secondmate in meta) are retired explicitly. Normal
# teardown refuses while their home has in-flight crewmate meta files; --force
# is the approved discard path that prevalidates child removal targets, locks each
# descendant home's task set before enumeration, and holds those locks through
# child cleanup. Contention refuses the complete forced teardown before child
# mutation. Local and remote retirement serialize their destructive phase with
# that mate's backlog-handoff lock under the registry lock. Pending handoff wake
# state is retired with the home, and local removal failure restores that state
# before preserving the route for retry. After a successful local or remote
# secondmate retirement, every parent pending-reply record for that id (resolved
# leftovers included) and its delivery confirmation is removed so retired mates
# cannot leave durable reply expectations behind. Non-forced retirement refuses
# while any of those records is still unresolved. Teardown then discards child
# work, kills child runtime endpoints, and removes the retired home. Removing a
# leased home releases its durable treehouse lease so the pool slot is freed,
# never left leased forever. If the treehouse return fails, teardown leaves the
# leased home and state in place instead of hiding a still-held lease.
# Usage: fm-teardown.sh <task-id> [--force [--drop-file <path>]] [--legacy-record]
# Shared slot-root recovery (from the lock-owning main session):
#   (cd /path/to/project && treehouse status)
#   If not already leased and the finished task holds the slot claim (or none
#   exists): (cd /path/to/project && treehouse lease <slot-name> \
#     --lease-holder <remaining-task>)
#   FM_HOME=/path/to/owning-home bin/fm-teardown.sh <finished-task>
#   Repeat for any other finished root record, including a completed scout.
#   FM_HOME=/path/to/owning-home bin/fm-control.sh <remaining-task> reassociate \
#     --worktree /path/to/remaining-copy --note 'Recover the actual task copy'
#   Only if that lease was added and the copy is outside the slot: inspect every
#   copy in the slot, then (cd /path/to/project && treehouse return \
#     /path/to/slot --if-lease-holder <remaining-task> </dev/null);
#   docs/agent-control.md.
#   --force skips ordinary-task dirty and landed-work checks, skips scout report
#   checks, and discards secondmate child work for kind=secondmate. Only use it
#   when the captain has explicitly said to discard the work. Ordinary work
#   additionally requires --drop-file satisfying the words-file contract in
#   bin/fm-tasks-axi.sh's header: the exact words are retained before discard.
#   A forced ship records the fixed note "dropped" without a landing probe.
#   A forced scout with a regular, nonsymlink, nonempty report keeps report
#   completion instead; either retains the captain's exact words.
#   --legacy-record accepts a task record that predates the spawn_gen field:
#   teardown then proceeds only when the recorded endpoint is confirmed dead or
#   agent-less (bin/fm-backend.sh's recovery-grade classifier), and without
#   --force the worktree still passes the ordinary landed-work checks. The
#   accepted legacy incarnation is stamped into the record before its close is
#   recorded and named in the teardown line; the flag never relaxes the
#   unlanded-work refusal, which requires authorized forced discard to bypass. A legacy- stamp
#   an abandoned attempt left behind never counts as a published incarnation:
#   the record still reads as a legacy record, so a recorded endpoint runs the
#   endpoint gate again and the retry still needs --legacy-record. The safe
#   windowless exception below retries its retained stamp without the flag.
#   A tmux record with no window names no live endpoint, so there is nothing
#   for that classifier to inspect and nothing to kill. Combined with a
#   missing spawn_gen, that leftover would otherwise deadlock: automatic
#   teardown refuses for want of spawn_gen, and --legacy-record then refuses
#   for want of a window. When backlog incarnation validation applies, such a
#   leftover (no window, no spawn_gen or only a retained legacy stamp, no
#   backend other than tmux, no Orca terminal= or other backend's <backend>_*
#   endpoint identity, and every other identity field passing the shared
#   endpoint validator as if it named the task's own window) is accepted as a
#   missing-endpoint legacy record with or without --legacy-record; the shared
#   endpoint validator is skipped so it cannot be read as the current window,
#   kill is skipped, and ship completion still faces the ordinary landed-work
#   or missing-copy admission above. Every other windowless record, including one with a
#   spawn_gen, a non-tmux backend, or an ambiguous field, still faces the
#   validator and refuses.
#
# Transient / stale worktree git lock recovery (teardown-lock-race): a crew process
# killed mid-git-operation can leave a .git/worktrees/<wt>/index.lock (or, for a
# non-linked worktree, .git/index.lock) that makes `treehouse return --force` fail
# with Unable to create '...index.lock': File exists. That lock is usually transient
# (the dying process finishes or exits within seconds) and must never be force-deleted
# while a live git process might still own it - the fix is patience, not rm.
#
# On that failure signature only, teardown_treehouse_return:
#   1. Retries up to FM_TREEHOUSE_RETURN_LOCK_RETRIES times (default 3), waiting
#      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS (default 1s; falls back to the older
#      FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS name when the new one is unset) between
#      attempts. Retries key off the error text, not whether the lock file still
#      exists after the failed attempt - a lock that self-clears mid-check still
#      deserves a retry of the return.
#   2. Other treehouse return failures still abort immediately and loudly (no retry).
#   3. If every retry still hits the lock signature and the lock remains, it is removed
#      and the return tried once more ONLY when the lock is provably stale per
#      bin/fm-lock-lib.sh's fm_lock_is_provably_stale, passing the worktree dir as the
#      companion directory and FM_STALE_WORKTREE_LOCK_AGE_SECS (default 30s) as the age
#      threshold. That shared proof owns the exact lsof-holder, mtime-age, and fail-safe
#      rules.
#   4. If retries exhaust and the lock is not provably stale, teardown fails as loudly
#      as a normal return failure and notes that the lock persisted across the retry
#      window. A missing `lsof`, or a lock that fails any stale check, is treated as
#      NOT provably stale (fail safe): the lock is left untouched.
# The same proof is used when non-force safety inspection cannot run because the lock
# is present; teardown clears only a provably stale lock, then re-runs the safety
# checks before any destructive return. Teardown output notes every wait, retry, and
# removal so the operator can see what happened.
#
# Pre-teardown cleanup sequence (runs once every landed/discard-work safety
# refusal above has already passed, and BEFORE any worktree return, branch
# delete, or backend kill below - a still-active run or a leaked process may
# own live work in that worktree):
#   Fix 1 - conclude the task's own no-mistakes run. A ship task's worktree can
#     be torn down while its no-mistakes pipeline run is still PARKED at a gate
#     (awaiting_approval/fix_review/any awaiting_agent field), with no worker
#     left to ever answer it - the run then sits there holding a fleet slot
#     indefinitely (observed 2026-08-03: runs parked 7h39m and parked at a
#     post-CI approval gate after the worker was already cleaned up). A run
#     with an autonomous step still under way (running/fixing/ci) is left
#     alone: no-mistakes drives those against its own gate-repo clone, not the
#     crew's worktree, so they are not orphaned by removing the worktree.
#     conclude_task_no_mistakes_run attributes the active-or-most-recent run to
#     THIS task only when its branch AND code identity (bin/fm-nm-run-lib.sh's
#     strict fm_nm_head_matches_worktree rule) both match this worktree, then
#     runs `no-mistakes axi abort --run <id>` for that verified run instance.
#     When the run head is absent from this copy's object store - the pipeline
#     committed its fix round in its own repo and the task copy never fetched
#     it - attribution falls to the same lib's shared
#     fm_nm_runs_status_for_worktree ledger rule, whose anchored continuation
#     recognition is the only remaining path, which refuses every row shape
#     it cannot prove, and which authorizes the abort only for an explicitly
#     active (`running`) proved continuation - a terminal newest word is
#     finished history, never an abort authorization (observed 2026-09-03: a
#     run parked at a post-CI gate after fix rounds advanced its head past
#     the submitted head stayed parked forever once the task was cleaned up).
#     A run already terminal
#     (an outcome is set) or not parked at a gate is left untouched. Idempotent:
#     an already-aborted run reads back terminal and is skipped on retry.
#   Fix 2 - reap leaked descendant processes. A backgrounded/disowned process
#     started under the worktree (or its per-task tasktmp) does not receive the
#     SIGHUP/SIGTERM that closing the backend pane sends to its own foreground
#     process group, so it survives reparented to init (observed 2026-08-03:
#     two `go test` binaries, deadlines blown past by ~100x, pinning CPU for
#     hours with no live task meta to attribute them to once teardown had
#     already removed it). reap_task_worktree_processes finds every process
#     whose CURRENT WORKING DIRECTORY is this task's own worktree or tasktmp
#     root via `lsof -a -d cwd` (cheap: bounded by process count, not by
#     walking the worktree's file tree) and sends TERM, then KILL after a short
#     grace period to any survivor whose process identity still matches.
#     Nested-lane boundary: a matched cwd inside a linked git worktree that
#     sits beneath either root (registered by any repository, the project or
#     a sibling clone, and including lanes this task's own worker created) is
#     never signalled, because no record proves which task owns that lane.
#     A lane that is itself a scan root - the task's own copy nested in the
#     pool slot it returns - is scanned as its own root instead.
#     Teardown refuses instead, even with --force, naming the pid, its birth
#     identity, the matched path, and the lane. A lane is either a worktree
#     the project, a git-backed scan root, or an available local task project's
#     repository still registers there, even when its directory or .git is
#     missing or prunable, or a linked worktree git discovers from the cwd;
#     outer-worktree discovery never proves custody.
#     Only a cwd exactly equal to a live recorded scan root is
#     eligible for signalling. Every other descendant cwd, existing or deleted,
#     refuses with its pid, birth identity, matched path and scan root, because
#     a damaged sibling lane cannot be distinguished from an own-tree directory.
#     One exception: before this sweep, retire sends TERM to a creation-lock
#     launcher of a foreign nested copy and to a process running in that copy,
#     each only when the ancestry test proved it teardown's own (it is, or
#     descends by parent chain from, a process whose cwd is exactly a scan root),
#     whatever its own cwd. It waits a bounded time and sends no KILL; one still
#     alive refuses, named by its pid, and a process that fails the test is never
#     signalled and refuses.
#     A missing lsof refuses too: without the scan no target can be audited, so
#     no unaudited process or process-group signal is ever sent.
#     Before each signal, state/<id>.teardown-processes records one tab-separated
#     row: epoch, signal, pid, birth identity, command line,
#     start time, cwd, matched open path (cwd descriptor), all shell-escaped
#     with printf %q. For such a process both cwd columns name the cwd of the
#     process it was proved through, the process itself or the ancestor it
#     descends from, not necessarily its own. This audit survives task-record
#     retirement and records signal intent, not proof of delivery: an immediate
#     birth-identity recheck can still skip the signal. Failed command/start collection skips the target
#     only when a changed birth identity or kernel ESRCH proves it replaced or
#     vanished; a live matching target or uncertain result refuses, as do authorization
#     and write failures. Idempotent: nothing left to find is a silent no-op.
#   Fix 3 - retire task-private no-mistakes launch agents (runs after Fix 1 and
#     BEFORE Fix 2, because Fix 2 can neither prove custody of nor durably stop
#     what an agent owns). A private no-mistakes home can install a KeepAlive
#     launchd agent, com.kunchenguid.no-mistakes.daemon.<hash>, that survives
#     reboots and relaunches its daemon after a kill; killing the process alone
#     cannot release the copy durably.
#     retire_task_private_nm_launch_agents reads every such plist in
#     $FM_LAUNCH_AGENTS_DIR (default ~/Library/LaunchAgents) and acts only on
#     one whose Label matches its file name and whose absolute `--root` is the
#     task copy or inside it after resolving symlinks and normalizing path
#     segments and separators; lookalike prefixes such as <copy>-x never match.
#     The Fix 2 nested-lane boundary also applies: a root belonging to a nested
#     lane is skipped, and unreadable registry or lane classification refuses.
#     Registries are checked even when the task copy is already gone, so
#     admitted missing-copy recovery still excludes registered nested lanes.
#     For a loaded service it runs `launchctl bootout gui/<uid>/<label>`, then
#     requires `launchctl print` to report the service gone (exit 113) before
#     moving the plist to data/<id>/launchagent-backup/.
#     An already-unloaded agent's plist is archived without bootout.
#     The shared daemon's agent (root ~/.no-mistakes), another task's agent,
#     symlinked plists, and plists whose root cannot be proven are left as found;
#     teardown never runs `no-mistakes daemon stop`, which targets the shared
#     daemon. Missing launchctl, a service that stays loaded, an unreadable load
#     state, or a failed archive refuses even with --force, preserving the
#     unarchived plist and any remaining copy.
#     tests/fm-teardown.test.sh's private, foreign, nested, and absent-copy
#     launch-agent cases exercise this boundary with a fake launchctl.
#   Fix 4 - remove the task's own Docker stacks. Docker resources survive process
#     exit, so after the process reap teardown calls bin/fm-task-docker-lib.sh,
#     whose header owns object attribution, removal, and retry metadata.
#     Apart from the daemon case below, any Docker listing, verification, or
#     removal failure stops teardown with task identity records and the worktree
#     kept, even under --force; rerun teardown after resolving the failure.
#     A missing Docker CLI is silent. A stopped or unreachable daemon stops
#     teardown only when the task record already retains docker_projects;
#     otherwise teardown warns and continues, on ship, scout, and
#     forced-descendant paths alike.
#     Standalone secondmate retirement skips its own Docker cleanup.
#     Forced cleanup closes each child's endpoint before its Docker snapshot.
#     Ordinary, Orca, and recursive descendants use their own metadata for Docker
#     cleanup. A nested secondmate's own Docker cleanup runs before its recursive
#     descendant retirement and home removal, which owns its process-event sweep.
#     A Docker refusal retains the child's retry records even though its endpoint
#     may have already stopped.
#     A reassigned slot is not used to attribute a Docker workdir; the library's
#     remaining non-path ownership rules still apply.
#     Docker path roots are owned worktrees only, never tasktmp; nested registered
#     Git lanes and linked worktrees are excluded, including through symlinks.
#     A lane scan that fails names its cause and stops teardown; it is skipped
#     when the task has no path root.
#     Only matching metadata basenames AND inodes identify the same task record;
#     differently named hardlinks remain sibling identities.
#     The shared-stack identity comes from the primary project's
#     supabase/config.toml project_id. Reading a present config requires python3's
#     standard-library tomllib parser; unreadable or invalid configuration refuses
#     cleanup before Docker removal.
#     tests/fm-teardown.test.sh covers failure/retry and forced-descendant cleanup.
#     Residual: teardown leaves autonomous pipelines live, and forced-descendant
#     cleanup does not reap a child's processes; a still-live producer can create
#     a stack after the final listing. Snapshot cleanup cannot stop a live producer.
# After Fix 1, Fix 3, and Fix 2, but before Fix 4, when config/pipeline-spend opts this home in, a ship
# task whose local copy this teardown owns has its no-mistakes pipeline spend
# recorded by bin/fm-pipeline-spend.sh, which owns the attribution and the
# ledger. It runs before the task branch it attributes runs by is deleted and
# before state/<id>.meta is removed, and is best effort: a failure warns and
# never blocks cleanup.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
SECONDMATE_REG="$DATA/secondmates.md"
SUB_HOME_MARKER=".fm-secondmate-home"
SUB_HOME_PARENT_MARKER=".fm-secondmate-parent"
# A missing `.` target is not a teardown result. Stock Bash 3.2 can abort it
# into an EXIT trap whose status is 0, and a newer Bash can print the
# diagnostic and continue into cleanup. Refuse by name before sourcing.
teardown_require_source() {  # <path>
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    echo "error: teardown refused: required source $(basename "$1") is missing or unreadable; nothing was changed" >&2
    exit 1
  fi
}

teardown_require_backend_prerequisites() {  # <backend> <task-id>
  local backend=$1 task_id=$2
  if ! fm_backend_source "$backend"; then
    echo "error: teardown refused: required $backend source is missing or unreadable for $task_id; nothing was changed" >&2
    return 1
  fi
}
for _teardown_source in \
  fm-tasks-axi-lib.sh \
  fm-backlog-transition-lib.sh \
  fm-timeout-lib.sh \
  fm-task-docker-lib.sh \
  fm-backend.sh \
  fm-control-lib.sh \
  fm-lock-lib.sh \
  fm-classify-lib.sh \
  fm-status-record-lib.sh \
  fm-status-decision-lib.sh \
  fm-status-event-lib.sh \
  fm-status-wake-lib.sh \
  fm-status-io-lib.sh \
  fm-utc-lib.sh \
  fm-gate-refuse-lib.sh \
  fm-pr-lib.sh \
  fm-public-followup-lib.sh \
  fm-x-lib.sh \
  fm-env-lib.sh \
  fm-secondmate-registry-lib.sh \
  fm-secondmate-parent-lib.sh \
  fm-pending-reply-lib.sh \
  fm-operational-input.sh \
  fm-marker-lib.sh \
  fm-tmux-lib.sh \
  fm-composer-lib.sh \
  fm-cursor-lib.sh \
  fm-nm-run-lib.sh \
  fm-wake-lib.sh \
  fm-project-lock-lib.sh \
  fm-path-lib.sh \
  fm-refuse-lib.sh \
  fm-teardown-nested-lib.sh \
  fm-lease-lib.sh
do
  teardown_require_source "$SCRIPT_DIR/$_teardown_source"
done
unset _teardown_source
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-task-docker-lib.sh
. "$SCRIPT_DIR/fm-task-docker-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
if [ "$#" -lt 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: invalid teardown request" >&2
  exit 2
fi
ID=$1
TEARDOWN_LOST_SLOT_EXIT=4
FORCE=
LEGACY_RECORD_GIVEN=0
DROP_FILE=
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=--force ;;
    --drop-file)
      shift
      DROP_FILE=${1:-}
      [ -n "$DROP_FILE" ] || { echo "error: --drop-file requires a path" >&2; exit 2; }
      ;;
    --legacy-record) LEGACY_RECORD_GIVEN=1 ;;
    *)
      echo "error: invalid teardown request" >&2
      exit 2
      ;;
  esac
  shift
done
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-project-lock-lib.sh
. "$SCRIPT_DIR/fm-project-lock-lib.sh"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$SCRIPT_DIR/fm-task-copy-lib.sh"
# shellcheck source=bin/fm-refuse-lib.sh
. "$SCRIPT_DIR/fm-refuse-lib.sh"
# shellcheck source=bin/fm-teardown-nested-lib.sh
. "$SCRIPT_DIR/fm-teardown-nested-lib.sh"
# Supervision lease guard: post-landing cleanup is overlap territory between
# the two Pi supervision actors; refuse while the OTHER actor holds this
# task's live lease (contract: bin/fm-lease-lib.sh; no-op in homes without
# leases).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# Role partition: forced teardown discards work, and the supervision branch
# never discards anything - only an ordinary landed-work teardown is branch
# territory (contract: bin/fm-lease-lib.sh).
if [ "$FORCE" = --force ] && [ "$(fm_lease_actor)" = branch ]; then
  echo "error: forced teardown refused - the supervision branch cannot discard work" >&2
  exit "$FM_LEASE_REFUSE_EXIT"
fi
fm_lease_guard "$ID" "teardown (fm-teardown)"
teardown_friction_outcome retried

# The pool slot of <project> that encloses a record's current copy without
# being it: the slot that strictly contains the copy or, once the copy is gone,
# the record's own prior_worktree= pool slot that encloses its recorded path -
# what a nested teardown leaves when it stops after removing that copy.
teardown_record_enclosing_slot() {  # <meta> <project> <worktree>
  local meta=$1 project=$2 worktree=$3 copy line prior prior_real
  if copy=$(fm_task_copy_canonical_dir "$worktree"); then
    fm_task_copy_enclosing_pool_slot "$project" "$copy"
    return
  fi
  [ -n "$worktree" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in prior_worktree=?*) ;; *) continue ;; esac
    prior=${line#prior_worktree=}
    prior_real=$(fm_task_copy_canonical_dir "$prior") || continue
    case "$worktree" in "$prior"/*|"$prior_real"/*) ;; *) continue ;; esac
    fm_treehouse_pool_slot "$project" "$prior_real" || continue
    printf '%s\n' "$prior_real"
    return 0
  done < "$meta"
  return 1
}

# True when a record's worktree is a pool slot of its project or a slot
# encloses it: the two shapes whose teardown returns a slot under the project
# lock.
teardown_record_in_pool_slot() {  # <meta> <project> <worktree>
  ! fm_treehouse_pool_slot "$2" "$3" || return 0
  teardown_record_enclosing_slot "$1" "$2" "$3" >/dev/null
}

META="$STATE/$ID.meta"
TREEHOUSE_PROJECT_LOCK=
TREEHOUSE_PROJECT_LOCK_HELD=0
TREEHOUSE_SLOT_LOCK_REQUIRED=0
TEARDOWN_DEFERRED_POOL_CLEANUP=
TEARDOWN_META_REMOVED=0
if [ -f "$META" ] && [ ! -L "$META" ]; then
  TEARDOWN_LOCK_KIND=$(fm_meta_get "$META" kind)
  [ -n "$TEARDOWN_LOCK_KIND" ] || TEARDOWN_LOCK_KIND=ship
  TEARDOWN_LOCK_BACKEND=$(fm_meta_get "$META" backend)
  [ -n "$TEARDOWN_LOCK_BACKEND" ] || TEARDOWN_LOCK_BACKEND=tmux
  TEARDOWN_LOCK_WT=$(fm_meta_get "$META" worktree)
  TEARDOWN_LOCK_PROJECT=$(fm_meta_get "$META" project)
  if [ "$TEARDOWN_LOCK_KIND" != secondmate ] \
     && [ "$TEARDOWN_LOCK_BACKEND" != orca ] \
     && teardown_record_in_pool_slot "$META" "$TEARDOWN_LOCK_PROJECT" "$TEARDOWN_LOCK_WT"; then
    TREEHOUSE_SLOT_LOCK_REQUIRED=1
    TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$TEARDOWN_LOCK_PROJECT") || {
      echo "REFUSED: cannot resolve the shared Treehouse project lock for ${TEARDOWN_LOCK_PROJECT:-<missing>}; nothing was changed" >&2
      exit 1
    }

  fi
fi
# A waited admission that reaches the stall limit is contention, not an error:
# report it as FM_PROJECT_LOCK_BUSY_EXIT and keep 1 for real lock errors.
teardown_project_lock_wait() {  # <lock> <operation>
  fm_project_lock_acquire "$1" "$2" && return 0
  [ -z "$FM_PROJECT_LOCK_ERROR" ] || return 1
  return "$FM_PROJECT_LOCK_BUSY_EXIT"
}

teardown_acquire_project_lock() {  # [wait]
  local rc=0
  [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ] || return 0
  if [ "${FM_IDLE_REAP_ADMISSION:-0}" = 1 ] && [ "${1:-}" != wait ] \
     && ! fm_teardown_return_pending "$STATE" "$ID"; then
    fm_project_lock_try "$TREEHOUSE_PROJECT_LOCK" "teardown $ID" || rc=$?
  else
    teardown_project_lock_wait "$TREEHOUSE_PROJECT_LOCK" "teardown $ID" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "REFUSED: cannot acquire the shared Treehouse project lock for $TEARDOWN_LOCK_PROJECT; the task record and slot are retained" >&2
    return "$rc"
  fi
  TREEHOUSE_PROJECT_LOCK_HELD=1
}

teardown_release_project_lock() {
  [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ] || return 0
  fm_project_lock_release "$TREEHOUSE_PROJECT_LOCK" || return 1
  TREEHOUSE_PROJECT_LOCK_HELD=0
}

# Whether the installed treehouse has the state-only lease command, probed
# once: an older Treehouse reports an unknown command and a missing one
# reports nothing, and neither can reserve a slot.
TEARDOWN_TREEHOUSE_LEASE_SUPPORT=
teardown_treehouse_supports_lease() {
  local help
  if [ -z "$TEARDOWN_TREEHOUSE_LEASE_SUPPORT" ]; then
    TEARDOWN_TREEHOUSE_LEASE_SUPPORT=0
    if help=$(treehouse lease --help 2>&1) \
        && grep -Eq '(^|[^[:alnum:]_-])--lease-holder([^[:alnum:]_-]|$)' <<<"$help"; then
      TEARDOWN_TREEHOUSE_LEASE_SUPPORT=1
    fi
  fi
  [ "$TEARDOWN_TREEHOUSE_LEASE_SUPPORT" = 1 ]
}

# A process lease lapses when the worker exits. Reserve only this slot before
# releasing project custody, so unrelated allocation can proceed during the
# slow process and status phases without ever resetting this copy.
# A failed cleanup deliberately retains this state-only lease for its retry.
# Sets TEARDOWN_SLOT_CUSTODY to lease when the slot is durably held, or to
# project when its state can be neither proved held nor leased: the caller
# then keeps project custody through the return.
TEARDOWN_SLOT_CUSTODY=
teardown_reserve_pool_slot() {  # <slot> [project] [task-id]
  local slot project=${2:-$PROJ} task_id=${3:-$ID} name
  TEARDOWN_SLOT_CUSTODY=
  slot=$(cd "$1" && pwd -P) || return 1
  FM_TASK_COPY_POOL_STATE_FILE=
  FM_TASK_COPY_POOL_STATE_ENTRIES=
  if fm_task_copy_pool_slot_held "$slot"; then
    TEARDOWN_SLOT_CUSTODY=lease
    return 0
  fi
  if [ "$FM_TASK_COPY_SLOT_STATE" != unleased ]; then
    echo "warning: pool slot $slot is in Treehouse state '$FM_TASK_COPY_SLOT_STATE' and $FM_TASK_COPY_SLOT_REASON; keeping project custody through its return instead of reserving it" >&2
    TEARDOWN_SLOT_CUSTODY=project
    return 0
  fi
  if ! teardown_treehouse_supports_lease; then
    echo "warning: pool slot $slot is unleased and the installed treehouse is missing or has no lease command to reserve it; keeping project custody through its return instead" >&2
    TEARDOWN_SLOT_CUSTODY=project
    return 0
  fi
  name=$FM_TASK_COPY_SLOT_NAME
  (cd "$project" && treehouse lease "$name" --lease-holder "$task_id") || return 1
  FM_TASK_COPY_POOL_STATE_FILE=
  FM_TASK_COPY_POOL_STATE_ENTRIES=
  fm_task_copy_pool_slot_held "$slot" || {
    echo "REFUSED: pool slot $slot was not proved durably leased after reservation; retaining its task record and contents" >&2
    return 1
  }
  TEARDOWN_SLOT_CUSTODY=lease
}

# Record, once this task's slot is reserved (or, for a slot shared with another
# task, once this task's claim beside it awaits release) and before any
# cleanup that can fail, that the slot is still held for it
# (bin/fm-wake-lib.sh's fm_teardown_return_pending owns the contract). A
# refusal from here on leaves the record for the retry.
teardown_mark_return_pending() {  # <slot> [child-id]
  local marker="$STATE/$ID.teardown-return-pending" tmp gen
  tmp="$STATE/.$ID.teardown-return-pending.${BASHPID:-$$}"
  if gen=$(fm_teardown_return_pending_gen "$META") \
      && { printf 'spawn_gen=%s\n' "$gen" && printf 'slot=%s\n' "$1" \
           && { [ -z "${2:-}" ] || printf 'child=%s\n' "$2"; }; } > "$tmp" \
      && mv -f "$tmp" "$marker" && [ -f "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  rm -f "$tmp"
  echo "warning: could not record that task $ID's pool slot $1 awaits its return at $marker" >&2
  return 1
}

teardown_refresh_return_pending() {
  local marker="$STATE/$ID.teardown-return-pending" tmp gen line
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  tmp="$STATE/.$ID.teardown-return-pending.refresh.${BASHPID:-$$}"
  if gen=$(fm_teardown_return_pending_gen "$META") \
      && { printf 'spawn_gen=%s\n' "$gen" \
           && while IFS= read -r line || [ -n "$line" ]; do
                case "$line" in spawn_gen=*) ;; *) printf '%s\n' "$line" ;; esac
              done < "$marker"
         } > "$tmp" && touch -r "$marker" "$tmp" && mv -f "$tmp" "$marker" \
      && [ -f "$marker" ] && [ ! -L "$marker" ]; then
    return 0
  fi
  rm -f "$tmp"
  echo "warning: could not rebind task $ID's pool-return record at $marker to its current record generation" >&2
  return 1
}

CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
SM_LIVENESS_LOCK=
META_LOCK=
META_LOCK_HELD=0
BACKLOG_CLOSE_STAGE=
DESCENDANT_LOCK_PATHS=()
DESCENDANT_TASK_STATES=()
DESCENDANT_TASK_IDS=()
DESCENDANT_TASK_KINDS=()
DESCENDANT_TASK_HOMES=()
DESCENDANT_TREEHOUSE_LOCK_PATHS=()
DESCENDANT_LEGACY_CUSTODY=0
DESCENDANT_LEASED_SLOTS=()
teardown_descendant_slot_leased() {  # <slot>
  local slot s
  slot=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  for s in ${DESCENDANT_LEASED_SLOTS[@]+"${DESCENDANT_LEASED_SLOTS[@]}"}; do
    [ "$s" != "$slot" ] || return 0
  done
  return 1
}
teardown_release_locks() {
  local status=$? i
  if [ -n "$BACKLOG_CLOSE_STAGE" ]; then
    fm_backlog_record_remove "$BACKLOG_CLOSE_STAGE" "pending-close staged record" "$STATE" || true
  fi
  if declare -F teardown_release_herdr_locks >/dev/null 2>&1; then
    teardown_release_herdr_locks || true
  fi
  for ((i=${#DESCENDANT_TREEHOUSE_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    fm_project_lock_release "${DESCENDANT_TREEHOUSE_LOCK_PATHS[$i]}" || true
  done
  DESCENDANT_TREEHOUSE_LOCK_PATHS=()
  for ((i=${#DESCENDANT_LOCK_PATHS[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${DESCENDANT_LOCK_PATHS[$i]}" || true
  done
  DESCENDANT_LOCK_PATHS=()
  if [ -n "${HANDOFF_WAKE_RETIRE_LOCK:-}" ]; then
    fm_lock_release "$HANDOFF_WAKE_RETIRE_LOCK" || true
    HANDOFF_WAKE_RETIRE_LOCK=
  fi
  if [ -n "${LOCAL_HANDOFF_LOCK:-}" ]; then
    fm_lock_release "$LOCAL_HANDOFF_LOCK" || true
    LOCAL_HANDOFF_LOCK=
  fi
  if [ -n "${LOCAL_REGISTRY_LOCK:-}" ]; then
    fm_lock_release "$LOCAL_REGISTRY_LOCK" || true
    LOCAL_REGISTRY_LOCK=
  fi
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ -n "${SM_LIVENESS_LOCK:-}" ]; then
    fm_lock_release "$SM_LIVENESS_LOCK" || true
    SM_LIVENESS_LOCK=
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ]; then
    fm_project_lock_release "$TREEHOUSE_PROJECT_LOCK" || true
    TREEHOUSE_PROJECT_LOCK_HELD=0
  fi
  fm_lease_guard_release || true
  return "$status"
}
trap teardown_release_locks EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
# Fail closed before any fleet mutation: a no-mistakes gate agent must never tear
# down a worktree (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
FM_LOCK_LOG_PREFIX=teardown

fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: teardown refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
fm_backlog_record_present "$META" "task record" "$STATE" || {
  echo "error: teardown refused after locking: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
if [ "${FM_IDLE_REAP_ADMISSION:-0}" = 1 ]; then
  if [ -n "$FORCE" ] || ! (
    trap - EXIT
    teardown_require_source "$SCRIPT_DIR/fm-idle-reap-lib.sh"
    # shellcheck source=/dev/null # Analyzed separately as a canonical lint root; this re-source is subshell-only.
    . "$SCRIPT_DIR/fm-idle-reap-lib.sh"
    fm_idle_reap_classify "$FM_HOME" "$STATE" "$DATA" "$ID"
    if [ "$IDLE_REAP_CLASS" != reap ]; then
      printf 'REFUSED: automatic reap ineligible: %s: %s\n' "$IDLE_REAP_CLASS" "$IDLE_REAP_DETAIL" >&2
      exit 1
    fi
  ); then
    exit 1
  fi
fi
TEARDOWN_META_KIND=$(fm_meta_get "$META" kind)
[ -n "$TEARDOWN_META_KIND" ] || TEARDOWN_META_KIND=ship
if [ "$FORCE" = --force ] && { [ "$TEARDOWN_META_KIND" != secondmate ] || [ -n "$DROP_FILE" ]; }; then
  if ! fm_backlog_drop_words_file_valid "$DROP_FILE"; then
    echo "REFUSED: discarding assigned work requires --drop-file with the captain's own words (1..8192 bytes)." >&2
    exit 1
  fi
elif [ -n "$DROP_FILE" ]; then
  echo "error: --drop-file is only valid with --force" >&2
  exit 2
fi
# Retiring a persistent secondmate is main's alone in both postures; the kind
# is read under the metadata lock (role partition: bin/fm-lease-lib.sh).
[ "$TEARDOWN_META_KIND" != secondmate ] || fm_lease_forbid_branch "secondmate retirement (fm-teardown)"
# A secondmate's endpoint-liveness episodes (bin/fm-secondmate-liveness-lib.sh)
# serialize on this lock; retirement holds it to the end so no probe or relaunch
# can act on the route mid-teardown, and its relaunch ledger and park marker are
# removed with the route instead of surviving for a reused id.
if [ "$TEARDOWN_META_KIND" = secondmate ]; then
  fm_lock_try_acquire "$STATE/.secondmate-liveness-$ID.lock" || {
    echo "error: a secondmate liveness check is in progress for $ID; nothing was changed - retry teardown" >&2
    exit 1
  }
  SM_LIVENESS_LOCK="$STATE/.secondmate-liveness-$ID.lock"
fi
TEARDOWN_CLEANUP_RECOVERY=$(fm_meta_get "$META" cleanup_recovery)
TEARDOWN_META_SPAWN_GEN=
TEARDOWN_LEGACY_PENDING=0
TEARDOWN_LEGACY_ACCEPTED=0
TEARDOWN_LEGACY_ENDPOINT=
TEARDOWN_LEGACY_RETAINED_STAMP=
TEARDOWN_LEGACY_PRESTAMP_SIZE=0
TEARDOWN_BACKLOG_APPLIES=0
TEARDOWN_BACKLOG_SKIP_REASON=
TEARDOWN_WINDOWLESS=0
TEARDOWN_WINDOWLESS_SHAPE=0
TEARDOWN_WINDOW_COUNT=$(LC_ALL=C grep -c '^window=' "$META" 2>/dev/null || true)
TEARDOWN_BACKEND_COUNT=$(LC_ALL=C grep -c '^backend=' "$META" 2>/dev/null || true)
case "$TEARDOWN_WINDOW_COUNT:$(fm_meta_get "$META" window)" in
  0:|1:)
    case "$TEARDOWN_BACKEND_COUNT:$(fm_meta_get "$META" backend)" in
      0:|1:tmux)
        TEARDOWN_FOREIGN_ENDPOINT_KEYS='^terminal='
        for TEARDOWN_FOREIGN_BACKEND in $FM_BACKEND_KNOWN; do
          [ "$TEARDOWN_FOREIGN_BACKEND" = tmux ] \
            || TEARDOWN_FOREIGN_ENDPOINT_KEYS="$TEARDOWN_FOREIGN_ENDPOINT_KEYS|^${TEARDOWN_FOREIGN_BACKEND}_"
        done
        if ! LC_ALL=C grep -Eq "$TEARDOWN_FOREIGN_ENDPOINT_KEYS" "$META" 2>/dev/null; then
          TEARDOWN_SHAPE_META=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-teardown-shape.XXXXXX") || exit 1
          { LC_ALL=C grep -v '^window=' "$META" || true; printf 'window=leftover:fm-%s\n' "$ID"; } \
            > "$TEARDOWN_SHAPE_META"
          if fm_backend_validate_task_endpoint "$TEARDOWN_SHAPE_META" "$ID" 2>/dev/null; then
            TEARDOWN_WINDOWLESS_SHAPE=1
          fi
          rm -f "$TEARDOWN_SHAPE_META"
        fi
        ;;
    esac
    ;;
esac
if [ "$TEARDOWN_CLEANUP_RECOVERY" != orca ]; then
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$TEARDOWN_META_KIND"; then
    TEARDOWN_BACKLOG_APPLIES=1
  else
    TEARDOWN_BACKLOG_GATE_STATUS=$?
    if [ "$TEARDOWN_BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: task $ID cannot be torn down because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    TEARDOWN_BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
  fi
fi
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  if ! fm_backlog_meta_spawn_gen "$META" "$STATE"; then
    TEARDOWN_LEGACY_GEN_COUNT=$(LC_ALL=C awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' "$META" 2>/dev/null || printf '0\n')
    if [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ] && [ "$TEARDOWN_WINDOWLESS_SHAPE" = 1 ]; then
      # A tmux record with no window names no live endpoint, so there is no
      # incarnation for spawn_gen to identify and nothing for --legacy-record
      # to classify. Accept it as a missing-endpoint leftover, with or without
      # the flag; a still-present worktree still faces the ordinary landed-work
      # checks below.
      TEARDOWN_WINDOWLESS=1
      TEARDOWN_LEGACY_PENDING=1
    elif [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ] && [ "$LEGACY_RECORD_GIVEN" = 1 ]; then
      # A record that predates the incarnation field: acceptance is gated later,
      # once the recorded endpoint is known, so its state can be confirmed dead
      # or agent-less before any cleanup decision is made.
      TEARDOWN_LEGACY_PENDING=1
    elif [ "$TEARDOWN_LEGACY_GEN_COUNT" = 0 ]; then
      echo "error: task $ID's record has no spawn_gen that identifies one exact incarnation ($FM_BACKLOG_TRANSITION_ERROR); refusing automatic teardown - relaunch the task to publish an unambiguous incarnation, then retry teardown, or pass --legacy-record once its recorded endpoint is confirmed dead or agent-less" >&2
      exit 1
    else
      echo "error: task $ID's record has an unreadable spawn_gen that identifies one exact incarnation ($FM_BACKLOG_TRANSITION_ERROR); refusing automatic teardown - fix the record, then retry teardown" >&2
      exit 1
    fi
  else
    case "$FM_BACKLOG_META_SPAWN_GEN" in
      legacy-*)
        # Only this teardown path mints a legacy- token; a launch publishes
        # s<epoch>.<pid>.<random>. So one still on a retained record is the
        # stamp an abandoned --legacy-record attempt could not roll back, not
        # an incarnation any spawn ever published. The record is still the
        # legacy record it was, and is treated as one: the dead-or-agent-less
        # endpoint gate runs again on the retry instead of being skipped by
        # the abandoned attempt's own stamp.
        if [ "$TEARDOWN_WINDOWLESS_SHAPE" = 1 ]; then
          TEARDOWN_WINDOWLESS=1
        elif [ "$LEGACY_RECORD_GIVEN" != 1 ]; then
          echo "error: task $ID's record carries the legacy incarnation stamp $FM_BACKLOG_META_SPAWN_GEN left by an abandoned --legacy-record teardown, not an incarnation published by a spawn; refusing automatic teardown - relaunch the task to publish an unambiguous incarnation, then retry teardown, or pass --legacy-record once its recorded endpoint is confirmed dead or agent-less" >&2
          exit 1
        fi
        TEARDOWN_LEGACY_PENDING=1
        TEARDOWN_LEGACY_RETAINED_STAMP=$FM_BACKLOG_META_SPAWN_GEN
        ;;
    esac
  fi
  [ "$TEARDOWN_LEGACY_PENDING" = 1 ] || TEARDOWN_META_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN
fi
# Cleanup never closes a captain call (see the header). Asked here, before any
# destructive step, so "cannot tell" can refuse while everything is intact.
TEARDOWN_BACKLOG_TRANSITION=close
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  TEARDOWN_CAPTAIN_OPEN_STATUS=0
  TEARDOWN_CAPTAIN_OPEN_OUT=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" 2>&1) || TEARDOWN_CAPTAIN_OPEN_STATUS=$?
  case "$TEARDOWN_CAPTAIN_OPEN_STATUS" in
    0) TEARDOWN_BACKLOG_TRANSITION=retain ;;
    1) ;;
    *)
      echo "error: task $ID cannot be torn down because whether its backlog item is still held for the captain could not be read; fix that read and retry rather than risk closing a captain call with no recorded answer" >&2
      [ -z "$TEARDOWN_CAPTAIN_OPEN_OUT" ] || printf '%s\n' "$TEARDOWN_CAPTAIN_OPEN_OUT" >&2
      exit 1
      ;;
  esac
fi

REMOTE_HANDOFF_DIR_PRESENT=0
REMOTE_HANDOFF_DIR_REAL=
REMOTE_OUTBOX_PRESENT=0
PENDING_REPLIES_DIR_PRESENT=0
PENDING_REPLIES_DIR_REAL=
REMOTE_HANDOFF_LOCK=
REMOTE_REGISTRY_LOCK=
REMOTE_REPLY_LIFECYCLE_LOCK=
LOCAL_HANDOFF_LOCK=
LOCAL_REGISTRY_LOCK=
HANDOFF_WAKE_RETIRE_MARKER=
HANDOFF_WAKE_RETIRE_VALUE=
HANDOFF_WAKE_RETIRE_CORR=
HANDOFF_WAKE_RETIRE_LOCK=
HANDOFF_WAKE_RETIRE_STAGE=

handoff_wake_retire_validate() {
  local marker="$STATE/.backlog-handoff-$ID.wake-pending" value corr rec confirmation
  HANDOFF_WAKE_RETIRE_MARKER=
  HANDOFF_WAKE_RETIRE_VALUE=
  HANDOFF_WAKE_RETIRE_CORR=
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || {
    echo "REFUSED: receiver wake state for secondmate $ID is unsafe" >&2
    return 1
  }
  value=$(cat "$marker" 2>/dev/null || true)
  case "$value" in
    pending|confirmed) ;;
    prepared:*)
      corr=${value#prepared:}
      corr=${corr%%:*}
      printf '%s' "$value" | grep -Eq '^prepared:[a-f0-9]{16}:[a-f0-9]{16}$' || {
        echo "REFUSED: receiver wake state for secondmate $ID is invalid" >&2
        return 1
      }
      ;;
    pending:*|confirmed:*)
      corr=${value#*:}
      printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || {
        echo "REFUSED: receiver wake state for secondmate $ID is invalid" >&2
        return 1
      }
      ;;
    *)
      echo "REFUSED: receiver wake state for secondmate $ID is invalid" >&2
      return 1
      ;;
  esac
  if [ -n "$corr" ]; then
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    if [ -e "$rec" ] || [ -L "$rec" ]; then
      [ -f "$rec" ] && [ ! -L "$rec" ] \
        && [ "$(fm_pending_reply_get "$rec" task_id)" = "$ID" ] || {
        echo "REFUSED: receiver wake correlation for secondmate $ID is unsafe or belongs to another task" >&2
        return 1
      }
    fi
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
    if [ -e "$confirmation" ] || [ -L "$confirmation" ]; then
      [ -f "$confirmation" ] && [ ! -L "$confirmation" ] || {
        echo "REFUSED: receiver wake delivery state for secondmate $ID is unsafe" >&2
        return 1
      }
    fi
    HANDOFF_WAKE_RETIRE_CORR=$corr
  fi
  HANDOFF_WAKE_RETIRE_MARKER=$marker
  HANDOFF_WAKE_RETIRE_VALUE=$value
}

handoff_wake_retire() {
  local marker=$HANDOFF_WAKE_RETIRE_MARKER corr=$HANDOFF_WAKE_RETIRE_CORR lock rec confirmation rc=0
  [ -n "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] \
    && [ "$(cat "$marker" 2>/dev/null || true)" = "$HANDOFF_WAKE_RETIRE_VALUE" ] || return 1
  if [ -n "$corr" ]; then
    lock="$STATE/.pending-reply-$corr.lock"
    fm_lock_acquire_wait "$lock" || return 1
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
    if { [ ! -e "$rec" ] && [ ! -L "$rec" ]; } \
      || { [ -f "$rec" ] && [ ! -L "$rec" ] \
        && [ "$(fm_pending_reply_get "$rec" task_id)" = "$ID" ]; }; then
      rm -f -- "$confirmation" "$rec" "$marker" || rc=$?
    else
      rc=1
    fi
    fm_lock_release "$lock"
    return "$rc"
  fi
  rm -f -- "$marker"
}

handoff_wake_retire_stage_restore() {
  local stage=$HANDOFF_WAKE_RETIRE_STAGE marker rec confirmation name destination
  [ -n "$stage" ] || return 0
  marker="$STATE/.backlog-handoff-$ID.wake-pending"
  rec=
  confirmation=
  if [ -n "$HANDOFF_WAKE_RETIRE_CORR" ]; then
    rec=$(fm_pending_reply_path "$STATE" "$HANDOFF_WAKE_RETIRE_CORR")
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$HANDOFF_WAKE_RETIRE_CORR")
  fi
  for name in record confirmation marker; do
    [ -e "$stage/$name" ] || continue
    case "$name" in
      record) destination=$rec ;;
      confirmation) destination=$confirmation ;;
      marker) destination=$marker ;;
    esac
    [ -n "$destination" ] && [ ! -e "$destination" ] && [ ! -L "$destination" ] \
      && mv -- "$stage/$name" "$destination" || return 1
  done
  rm -f -- "$stage/corr" || return 1
  rmdir -- "$stage" || return 1
  if [ -n "$HANDOFF_WAKE_RETIRE_LOCK" ]; then
    fm_lock_release "$HANDOFF_WAKE_RETIRE_LOCK" || return 1
    HANDOFF_WAKE_RETIRE_LOCK=
  fi
  HANDOFF_WAKE_RETIRE_STAGE=
}

handoff_wake_retire_stage_commit() {
  local stage=$HANDOFF_WAKE_RETIRE_STAGE retired
  [ -n "$stage" ] || return 0
  retired="$stage.retired.$$"
  [ ! -e "$retired" ] && [ ! -L "$retired" ] || return 1
  mv -- "$stage" "$retired" || return 1
  HANDOFF_WAKE_RETIRE_STAGE=
  if [ -n "$HANDOFF_WAKE_RETIRE_LOCK" ]; then
    fm_lock_release "$HANDOFF_WAKE_RETIRE_LOCK" || return 1
    HANDOFF_WAKE_RETIRE_LOCK=
  fi
  rm -rf -- "$retired" || echo "warning: retired receiver wake state remains at $retired" >&2
}

handoff_wake_retire_stage_recover() {
  local home=$1 stage="$STATE/.backlog-handoff-$ID.wake-retiring" corr
  [ -e "$stage" ] || [ -L "$stage" ] || return 0
  [ -d "$stage" ] && [ ! -L "$stage" ] || {
    echo "REFUSED: receiver wake retirement state for secondmate $ID is unsafe" >&2
    return 1
  }
  if [ ! -e "$stage/corr" ] && [ ! -L "$stage/corr" ]; then
    rmdir -- "$stage" 2>/dev/null && return 0
    echo "REFUSED: receiver wake retirement state for secondmate $ID is incomplete" >&2
    return 1
  fi
  [ -f "$stage/corr" ] && [ ! -L "$stage/corr" ] || {
    echo "REFUSED: receiver wake retirement state for secondmate $ID is unsafe" >&2
    return 1
  }
  corr=$(cat "$stage/corr" 2>/dev/null || true)
  [ -z "$corr" ] || printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || {
    echo "REFUSED: receiver wake retirement correlation for secondmate $ID is invalid" >&2
    return 1
  }
  local staged
  for staged in "$stage/marker" "$stage/record" "$stage/confirmation"; do
    [ ! -e "$staged" ] && [ ! -L "$staged" ] && continue
    [ -f "$staged" ] && [ ! -L "$staged" ] || {
      echo "REFUSED: receiver wake retirement state for secondmate $ID is unsafe" >&2
      return 1
    }
  done
  HANDOFF_WAKE_RETIRE_CORR=$corr
  HANDOFF_WAKE_RETIRE_STAGE=$stage
  if [ -n "$corr" ]; then
    HANDOFF_WAKE_RETIRE_LOCK="$STATE/.pending-reply-$corr.lock"
    fm_lock_acquire_wait "$HANDOFF_WAKE_RETIRE_LOCK" || return 1
  fi
  if [ -e "$home" ] || [ -L "$home" ]; then
    handoff_wake_retire_stage_restore
  else
    handoff_wake_retire_stage_commit
  fi
}

handoff_wake_retire_stage() {
  local stage="$STATE/.backlog-handoff-$ID.wake-retiring" marker=$HANDOFF_WAKE_RETIRE_MARKER
  local corr=$HANDOFF_WAKE_RETIRE_CORR rec confirmation
  [ -n "$marker" ] || return 0
  [ ! -e "$stage" ] && [ ! -L "$stage" ] || return 1
  (umask 077; mkdir -- "$stage") || return 1
  HANDOFF_WAKE_RETIRE_STAGE=$stage
  printf '%s\n' "$corr" > "$stage/corr" || { handoff_wake_retire_stage_restore || true; return 1; }
  if [ -n "$corr" ]; then
    HANDOFF_WAKE_RETIRE_LOCK="$STATE/.pending-reply-$corr.lock"
    fm_lock_acquire_wait "$HANDOFF_WAKE_RETIRE_LOCK" || {
      HANDOFF_WAKE_RETIRE_LOCK=
      handoff_wake_retire_stage_restore || true
      return 1
    }
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    confirmation=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
    if [ -e "$rec" ] && ! mv -- "$rec" "$stage/record"; then
      handoff_wake_retire_stage_restore || true
      return 1
    fi
    if [ -e "$confirmation" ] && ! mv -- "$confirmation" "$stage/confirmation"; then
      handoff_wake_retire_stage_restore || true
      return 1
    fi
  fi
  if ! mv -- "$marker" "$stage/marker"; then
    handoff_wake_retire_stage_restore || true
    return 1
  fi
}

remote_teardown_locks_release() {
  if [ -n "$REMOTE_REPLY_LIFECYCLE_LOCK" ]; then
    fm_lock_release "$REMOTE_REPLY_LIFECYCLE_LOCK"
    REMOTE_REPLY_LIFECYCLE_LOCK=
  fi
  if [ -n "$REMOTE_HANDOFF_LOCK" ]; then
    fm_lock_release "$REMOTE_HANDOFF_LOCK"
    REMOTE_HANDOFF_LOCK=
  fi
  if [ -n "$REMOTE_REGISTRY_LOCK" ]; then
    fm_lock_release "$REMOTE_REGISTRY_LOCK"
    REMOTE_REGISTRY_LOCK=
  fi
}

# Validate $STATE/pending-replies for local and remote secondmate retirement:
# refuse a symlinked directory, any non-regular entry, and any entry whose
# basename is not a 16-hex correlation id or whose corr_id disagrees with that
# basename; pin the realpath so later cleanup cannot follow a swapped link
# target or a crafted confirmation path.
pending_replies_recovery_validate() {
  local mode=${1:-initial} pending_dir real rec base corr
  pending_dir="$STATE/pending-replies"
  if [ -e "$pending_dir" ] || [ -L "$pending_dir" ]; then
    [ -d "$pending_dir" ] && [ ! -L "$pending_dir" ] \
      || { echo "REFUSED: pending-replies recovery directory is unsafe" >&2; return 1; }
    real=$(CDPATH='' cd -- "$pending_dir" 2>/dev/null && pwd -P) || return 1
    if [ "$mode" = initial ]; then
      PENDING_REPLIES_DIR_PRESENT=1
      PENDING_REPLIES_DIR_REAL=$real
    elif [ "$PENDING_REPLIES_DIR_PRESENT" -ne 1 ] || [ "$PENDING_REPLIES_DIR_REAL" != "$real" ]; then
      echo "REFUSED: pending-replies recovery directory changed during retirement" >&2
      return 1
    fi
    for rec in "$pending_dir"/*; do
      [ -e "$rec" ] || [ -L "$rec" ] || continue
      [ -f "$rec" ] && [ ! -L "$rec" ] \
        || { echo "REFUSED: pending-replies contains an unsafe recovery entry" >&2; return 1; }
      base=$(basename "$rec")
      printf '%s' "$base" | grep -Eq '^[a-f0-9]{16}$' \
        || { echo "REFUSED: pending-replies contains an unsafe recovery entry" >&2; return 1; }
      corr=$(fm_meta_get "$rec" corr_id)
      if [ -n "$corr" ]; then
        printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' \
          || { echo "REFUSED: pending-replies contains an unsafe recovery entry" >&2; return 1; }
        [ "$corr" = "$base" ] \
          || { echo "REFUSED: pending-replies contains an unsafe recovery entry" >&2; return 1; }
      fi
    done
  elif [ "$mode" != initial ] && [ "$PENDING_REPLIES_DIR_PRESENT" -ne 0 ]; then
    echo "REFUSED: pending-replies recovery directory changed during retirement" >&2
    return 1
  fi
}

remote_recovery_paths_validate() {
  local mode=${1:-initial} handoff_dir outbox real
  handoff_dir="$DATA/handoff"
  outbox="$handoff_dir/$ID.outbox.md"
  if [ -e "$handoff_dir" ] || [ -L "$handoff_dir" ]; then
    [ -d "$handoff_dir" ] && [ ! -L "$handoff_dir" ] \
      || { echo "REFUSED: remote handoff recovery directory is unsafe" >&2; return 1; }
    real=$(CDPATH='' cd -- "$handoff_dir" 2>/dev/null && pwd -P) || return 1
    if [ "$mode" = initial ]; then
      REMOTE_HANDOFF_DIR_PRESENT=1
      REMOTE_HANDOFF_DIR_REAL=$real
    elif [ "$REMOTE_HANDOFF_DIR_PRESENT" -ne 1 ] || [ "$REMOTE_HANDOFF_DIR_REAL" != "$real" ]; then
      echo "REFUSED: remote handoff recovery directory changed during retirement" >&2
      return 1
    fi
  elif [ "$mode" != initial ] && [ "$REMOTE_HANDOFF_DIR_PRESENT" -ne 0 ]; then
    echo "REFUSED: remote handoff recovery directory changed during retirement" >&2
    return 1
  fi
  if [ -e "$outbox" ] || [ -L "$outbox" ]; then
    [ -f "$outbox" ] && [ ! -L "$outbox" ] \
      || { echo "REFUSED: remote backlog outbox is unsafe" >&2; return 1; }
    if [ "$mode" = initial ]; then
      REMOTE_OUTBOX_PRESENT=1
    elif [ "$REMOTE_OUTBOX_PRESENT" -ne 1 ]; then
      echo "REFUSED: remote backlog outbox changed during retirement" >&2
      return 1
    fi
  elif [ "$mode" != initial ] && [ "$REMOTE_OUTBOX_PRESENT" -ne 0 ]; then
    echo "REFUSED: remote backlog outbox changed during retirement" >&2
    return 1
  fi
  pending_replies_recovery_validate "$mode" || return 1
}

# Remove every parent pending-reply record for $ID, plus its delivery
# confirmation when present. Shared by local and remote secondmate retirement
# after the home/route is safely gone.
pending_replies_cleanup_for_task() {
  local pending_dir=$1 expected_real=${2-} rec base corr task_id
  [ -d "$pending_dir" ] || return 0
  (
    CDPATH='' cd -- "$pending_dir" 2>/dev/null || exit 1
    if [ -n "$expected_real" ]; then
      [ "$(pwd -P)" = "$expected_real" ] || exit 1
    fi
    for rec in ./*; do
      [ -e "$rec" ] || [ -L "$rec" ] || continue
      [ -f "$rec" ] && [ ! -L "$rec" ] || exit 1
      task_id=$(fm_meta_get "$rec" task_id)
      [ "$task_id" = "$ID" ] || continue
      base=${rec#./}
      printf '%s' "$base" | grep -Eq '^[a-f0-9]{16}$' || exit 1
      corr=$(fm_meta_get "$rec" corr_id)
      [ -z "$corr" ] || [ "$corr" = "$base" ] || exit 1
      rm -f -- "./.delivery-confirmed-$base" "$rec" || exit 1
    done
  )
}

remote_pending_replies_cleanup() {
  [ "$PENDING_REPLIES_DIR_PRESENT" -eq 1 ] || return 0
  pending_replies_cleanup_for_task "$STATE/pending-replies" "$PENDING_REPLIES_DIR_REAL"
}

# Refuse non-forced secondmate retirement while any parent pending-reply for
# this id is still unresolved (local and remote share the gate).
secondmate_unresolved_pending_replies_refuse() {
  local rec task_id phase
  [ -d "$STATE/pending-replies" ] || return 0
  for rec in "$STATE/pending-replies"/*; do
    [ -f "$rec" ] || continue
    task_id=$(fm_meta_get "$rec" task_id)
    [ "$task_id" = "$ID" ] || continue
    phase=$(fm_meta_get "$rec" phase)
    [ "$phase" = resolved ] || {
      echo "REFUSED: secondmate $ID still has an unresolved routed reply" >&2
      return 1
    }
  done
  return 0
}

remote_outbox_cleanup() {
  [ "$REMOTE_OUTBOX_PRESENT" -eq 1 ] || return 0
  (
    CDPATH='' cd -- "$DATA/handoff" 2>/dev/null || exit 1
    [ "$(pwd -P)" = "$REMOTE_HANDOFF_DIR_REAL" ] || exit 1
    [ -f "$ID.outbox.md" ] && [ ! -L "$ID.outbox.md" ] || exit 1
    rm -f -- "$ID.outbox.md"
  )
}

remote_secondmate_teardown() {
  local remote_host remote_root remote_home kind route_host route_root route_home out rc tmp
  remote_host=$(fm_meta_get "$META" remote_host)
  [ -n "$remote_host" ] || return 3
  kind=$(fm_meta_get "$META" kind)
  [ "$kind" = secondmate ] || { echo "REFUSED: remote placement metadata is valid only for a secondmate" >&2; return 1; }
  remote_root=$(fm_meta_get "$META" remote_root)
  remote_home=$(fm_meta_get "$META" home)
  [ -n "$remote_root" ] && [ -n "$remote_home" ] || { echo "REFUSED: remote secondmate metadata is incomplete" >&2; return 1; }
  secondmate_registry_line_for_id "$SECONDMATE_REG" "$ID" || { echo "REFUSED: remote secondmate route is missing or ambiguous" >&2; return 1; }
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || { echo "REFUSED: secondmate registry route is not remote" >&2; return 1; }
  route_host=$SECONDMATE_REGISTRY_HOST
  route_root=$SECONDMATE_REGISTRY_ROOT
  route_home=$SECONDMATE_REGISTRY_HOME
  [ "$route_host" = "$remote_host" ] && [ "$route_root" = "$remote_root" ] && [ "$route_home" = "$remote_home" ] \
    || { echo "REFUSED: remote secondmate metadata does not match its registry route" >&2; return 1; }
  handoff_wake_retire_validate || return 1
  remote_recovery_paths_validate initial || return 1
  if [ "$FORCE" != --force ] && [ "$REMOTE_OUTBOX_PRESENT" -eq 1 ]; then
    echo "REFUSED: remote secondmate $ID still has a pending backlog outbox; deliver it or explicitly discard with --force" >&2
    return 1
  fi
  if [ "$FORCE" != --force ]; then
    secondmate_unresolved_pending_replies_refuse || return 1
  fi
  "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-quiesce-locked "$ID" "$FORCE" >/dev/null 2>&1 || {
    echo "REFUSED: remote secondmate $ID still has an unhandled captured reply" >&2
    return 1
  }
  "$FM_ROOT/bin/fm-guard.sh" || true
  if [ "$FORCE" = --force ]; then
    if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" --force < /dev/null 2>&1); then rc=0; else rc=$?; fi
  else
    if out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh retire "$ID" < /dev/null 2>&1); then rc=0; else rc=$?; fi
  fi
  if [ "$rc" -ne 0 ] && [ "$rc" -ne "$TEARDOWN_LOST_SLOT_EXIT" ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    if [ "$rc" -eq 255 ]; then
      echo "error: remote retirement completion is unknown; preserving the route and local records for same-host reconciliation" >&2
    elif ! "$SCRIPT_DIR/fm-procevent-remote-reply.sh" arm-locked "$ID" >/dev/null 2>&1; then
      echo "error: remote retirement failed and the reply source could not be re-armed" >&2
    fi
    return "$rc"
  fi
  if [ "$rc" -eq "$TEARDOWN_LOST_SLOT_EXIT" ]; then
    printf '%s\n' "$out" | grep -E '^(warning: treehouse return left pool slot |  )' >&2 || true
  fi
  remote_recovery_paths_validate recheck || {
    echo "error: remote home retired but local recovery paths changed; preserving the local route for retry" >&2
    return 1
  }
  "$SCRIPT_DIR/fm-procevent-remote-reply.sh" retire-finalize-locked "$ID" "$FORCE" >/dev/null 2>&1 || {
    echo "error: remote home retired but reply-source cleanup is incomplete; preserving the local route for retry" >&2
    return 1
  }
  if [ "$FORCE" = --force ]; then
    remote_outbox_cleanup || { echo "error: remote outbox cleanup failed; preserving the local route for retry" >&2; return 1; }
  fi
  remote_pending_replies_cleanup \
    || { echo "error: remote pending-reply cleanup failed; preserving the local route for retry" >&2; return 1; }
  handoff_wake_retire \
    || { echo "error: remote receiver wake cleanup failed; preserving the local route for retry" >&2; return 1; }
  tmp="$SECONDMATE_REG.tmp.$$"
  grep -vE "^- $ID( |$)" "$SECONDMATE_REG" > "$tmp" || true
  mv -f -- "$tmp" "$SECONDMATE_REG"
  [ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" cleaned_up "$ID" || true
  status_retire_presentation_task "$STATE" "$ID" || return 1
  fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE" || return 1
  rm -f -- "$STATE/$ID.turn-ended" "$STATE/$ID.progress" \
    "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")" \
    "$STATE/.secondmate-relaunch-$ID" "$STATE/.secondmate-relaunch-bound-$ID" \
    "$STATE/$ID.control-exit" "$STATE/.session-end-relaunch-$ID" "$STATE/.session-end-handled-$ID" \
    "$STATE/.session-launch-refused-$ID"
  printf 'teardown %s complete (remote %s:%s)\n' "$ID" "$remote_host" "$remote_home"
  return "$rc"
}

remote_secondmate_teardown_locked() {
  local rc
  [ -n "$(fm_meta_get "$META" remote_host)" ] || return 3
  REMOTE_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$REMOTE_REGISTRY_LOCK" || return 1
  REMOTE_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$REMOTE_HANDOFF_LOCK" || {
    remote_teardown_locks_release
    return 1
  }
  REMOTE_REPLY_LIFECYCLE_LOCK=$(secondmate_reply_lifecycle_lock_path "$STATE" "$ID")
  fm_lock_acquire_wait "$REMOTE_REPLY_LIFECYCLE_LOCK" || {
    remote_teardown_locks_release
    return 1
  }
  if remote_secondmate_teardown; then rc=0; else rc=$?; fi
  remote_teardown_locks_release
  return "$rc"
}

if remote_secondmate_teardown_locked; then
  remote_teardown_rc=0
else
  remote_teardown_rc=$?
fi
if [ "$remote_teardown_rc" -eq 0 ] || [ "$remote_teardown_rc" -eq "$TEARDOWN_LOST_SLOT_EXIT" ]; then
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --detach || true
  exit "$remote_teardown_rc"
fi
[ "$remote_teardown_rc" -eq 3 ] || exit "$remote_teardown_rc"

# This is the first cleanup authorization check. It is metadata-only and must
# complete before fm-guard, a backend command, file removal, branch deletion,
# worktree return, registry change, or process termination can run.
# A windowless record names no endpoint: the shared validator would refuse it
# (and must keep refusing it for control/kill callers), so teardown skips the
# validator rather than probing or closing an ambient current window.
WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
T_ORCA=
if [ "$TEARDOWN_WINDOWLESS" = 1 ]; then
  BACKEND=tmux
  T=
else
  fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
  BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  T=$FM_BACKEND_VALIDATED_TARGET
  [ "$BACKEND" != orca ] || T_ORCA=$T
fi
# The recorded backend, including every sibling its adapter sources, has to
# be readable before the first destructive step. --force does not override
# this. A forced descendant is proved in validate_firstmate_home_children_removal.
teardown_require_backend_prerequisites "$BACKEND" "$ID" || exit 1
if [ "${FM_TEARDOWN_GUARD_DONE:-0}" != 1 ]; then
  "$FM_ROOT/bin/fm-guard.sh" || true
fi
HOME_PATH=$(grep '^home=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
# tasktmp is recorded by fm-spawn for tasks that set up a per-task temp root
# (/tmp/fm-<id>/); absent for tasks spawned before that change, so tolerate empty.
TASK_TMP=$(grep '^tasktmp=' "$META" | cut -d= -f2- || true)
BUSY_GEN=$(fm_meta_get "$META" busy_gen)
if [ -z "$BUSY_GEN" ]; then
  BUSY_GEN=$(cat "$STATE/$ID.busy-gen" 2>/dev/null || true)
fi
ORCA_WORKTREE_ID=$(fm_meta_get "$META" orca_worktree_id)
CLEANUP_RECOVERY=$TEARDOWN_CLEANUP_RECOVERY

KIND=$TEARDOWN_META_KIND
TEARDOWN_POOL_SLOT_LOST=0
EXPECTED_TREEHOUSE_PROJECT_LOCK=
if [ "$KIND" != secondmate ] && [ "$BACKEND" != orca ] \
   && teardown_record_in_pool_slot "$META" "$PROJ" "$WT"; then
  EXPECTED_TREEHOUSE_PROJECT_LOCK=$(fm_treehouse_project_lock_path "$PROJ") || {
    echo "REFUSED: cannot resolve the shared Treehouse project lock for ${PROJ:-<missing>}; nothing was changed" >&2
    exit 1
  }
  if [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" != 1 ] \
     || [ "$TREEHOUSE_PROJECT_LOCK" != "$EXPECTED_TREEHOUSE_PROJECT_LOCK" ]; then
    echo "REFUSED: task $ID's Treehouse project identity changed while teardown acquired its locks; nothing was changed" >&2
    exit 1
  fi
elif [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ]; then
  echo "REFUSED: task $ID stopped naming a live Treehouse slot while teardown acquired its locks; nothing was changed" >&2
  exit 1
fi
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ -n "$MODE" ] || MODE=no-mistakes
BASE_BRANCH=$(grep '^base_branch=' "$META" | cut -d= -f2- || true)

teardown_preserves_reassociated_copy() {
  local meta=$1 kind=$2 backend=$3 project=$4 worktree=$5 line
  [ "$kind" != secondmate ] && [ "$backend" != orca ] || return 1
  ! fm_treehouse_pool_slot "$project" "$worktree" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in prior_worktree=?*|released_worktree=?*) return 0 ;; esac
  done < "$meta"
  return 1
}

# A record that bin/fm-control.sh reassociate re-pointed at a replacement copy
# names every copy the task worked in before in prior_worktree=, or in
# released_worktree= when the copy's pool slot was released. Teardown never
# touches a prior_worktree= copy: it is preserved custody that no landed-work
# test here has inspected. A released slot is already the pool's again, with its
# commits anchored, so it is history only. A current copy that is not a Treehouse pool slot was
# made by the task itself, not allocated by bin/fm-spawn.sh, so no pool return
# applies to it and its branch and hook files are not Firstmate's to remove:
# after the ordinary landed-work test it is left exactly as it is. A current
# copy that is a pool slot takes the ordinary return path below. So does a
# current copy nested inside a pool slot this task still claims: it is removed
# and that slot is returned, since the slot would otherwise stay held by a task
# that no longer exists (teardown_nested_slot).
TEARDOWN_PRIOR_COPIES=()
while IFS= read -r teardown_prior_line || [ -n "$teardown_prior_line" ]; do
  case "$teardown_prior_line" in
    prior_worktree=?*) TEARDOWN_PRIOR_COPIES+=("${teardown_prior_line#prior_worktree=}") ;;
  esac
done < "$META"
TEARDOWN_KEEP_COPY=0
TEARDOWN_ENCLOSING_SLOT=
TEARDOWN_RECORD_SLOT=
if teardown_preserves_reassociated_copy "$META" "$KIND" "$BACKEND" "$PROJ" "$WT"; then
  TEARDOWN_KEEP_COPY=1
  TEARDOWN_RECORD_SLOT=$(teardown_record_enclosing_slot "$META" "$PROJ" "$WT") \
    || TEARDOWN_RECORD_SLOT=
  TEARDOWN_ENCLOSING_SLOT=$TEARDOWN_RECORD_SLOT
fi

# A record accepted as a legacy incarnation (no spawn_gen, and either
# --legacy-record given or the record is windowless) may be torn down only
# when its recorded endpoint is confidently gone or agent-less. Windowless
# leftovers name no endpoint and are treated as missing. For a recorded
# window, only the recovery-grade classifier's dead and missing license
# that, and every ambiguous, unreadable, or unverified endpoint state refuses
# while the record is still intact. Acceptance resolves the incarnation token
# here; the record itself is stamped only once every landed-work refusal has
# passed, immediately before the close marker binds to it, so any refusal
# leaves the record byte-identical.
if [ "$TEARDOWN_LEGACY_PENDING" = 1 ]; then
  if [ "$TEARDOWN_WINDOWLESS" = 1 ]; then
    TEARDOWN_LEGACY_ENDPOINT=missing
  else
    TEARDOWN_LEGACY_ENDPOINT=$(fm_backend_agent_state "$BACKEND" "$T")
    case "$TEARDOWN_LEGACY_ENDPOINT" in
      dead|missing) ;;
      *)
        echo "REFUSED: task $ID's record predates spawn_gen and its recorded endpoint reads '$TEARDOWN_LEGACY_ENDPOINT', not confidently dead or agent-less; --legacy-record teardown is refused while an agent may still be bound to it. Nothing was changed." >&2
        echo "Reconcile the endpoint first (bin/fm-crew-state.sh $ID), or relaunch the task to publish an unambiguous incarnation, then retry teardown." >&2
        exit 1
        ;;
    esac
  fi
  if [ -n "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
    TEARDOWN_META_SPAWN_GEN=$TEARDOWN_LEGACY_RETAINED_STAMP
  else
    TEARDOWN_META_SPAWN_GEN="legacy-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  TEARDOWN_LEGACY_ACCEPTED=1
fi

PUBLIC_FOLLOWUP_HOME=$FM_HOME
PUBLIC_FOLLOWUP_STATE=$STATE
PUBLIC_FOLLOWUP_WORK_HOME=main
PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=0
PUBLIC_FOLLOWUP_RELAY_ACTIVE=0
public_followup_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}
public_followup_resolve_primary_home() {
  local parent=$1 child=$2 id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$id" || return 1
  parent=$(public_followup_canonical_home "$parent") || return 1
  child=$(public_followup_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fm_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fm_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key "$id" "$child" || return 1
  printf '%s\n' "$parent"
}
if [ -f "$FM_HOME/$SUB_HOME_MARKER" ]; then
  SECOND_MATE_ID=$(sed -n '1p' "$FM_HOME/$SUB_HOME_MARKER")
  # The durable parent record (written once at seeding, next to the identity
  # marker) names this home's route to its parent: "local" when they share a
  # filesystem, "remote" when the parent lives on another machine. Absent for
  # a home seeded before this record existed, which preserves today's exact
  # env-var-only behavior for that legacy home rather than guessing its route.
  PARENT_ROUTE_FILE="$FM_HOME/$SUB_HOME_PARENT_MARKER"
  PARENT_ROUTE_RECORD=absent
  PARENT_ROUTE=
  PARENT_ROUTE_HOME=
  if [ -e "$PARENT_ROUTE_FILE" ] || [ -L "$PARENT_ROUTE_FILE" ]; then
    PARENT_ROUTE_RECORD=invalid
    if fm_secondmate_parent_record_parse "$PARENT_ROUTE_FILE"; then
      PARENT_ROUTE=$FM_SECONDMATE_PARENT_ROUTE
      PARENT_ROUTE_HOME=$FM_SECONDMATE_PARENT_HOME
      PARENT_ROUTE_RECORD=valid
    fi
  fi
  if [ "$PARENT_ROUTE_RECORD" = invalid ]; then
    PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
  elif [ "$PARENT_ROUTE" = remote ]; then
    # The entire promised-public-reply subsystem is same-filesystem by
    # construction (bin/fm-public-followup-emit.sh header): a parent recorded
    # on another machine can never hold a delegated promise for this child, so
    # the delegated-parent path is out of scope and never refuses cleanup on
    # its own. A token committed directly to THIS home's own .env is still a
    # real, same-filesystem signal, so it is still checked - but read only
    # from the file, never from the process environment, so an unrelated
    # export in the remote host's own login shell cannot trigger it the way
    # fm_pf_relay_active's environment-wins rule would.
    if [ -f "$FM_HOME/.env" ]; then
      HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$FM_HOME/.env")
      [ -z "$HOME_ENV_TOKEN" ] || PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
    fi
    if [ "$PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE" = 1 ]; then
      PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
    else
      PUBLIC_FOLLOWUP_HOME=
      PUBLIC_FOLLOWUP_STATE=
    fi
  elif [ "$PARENT_ROUTE" = local ]; then
    PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
    PRIMARY_HOME_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PARENT_ROUTE_HOME}
    PARENT_BINDINGS_MATCH=1
    if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      LIVE_PARENT_HOME=$(public_followup_canonical_home \
        "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") || PARENT_BINDINGS_MATCH=0
      DURABLE_PARENT_HOME=$(public_followup_canonical_home \
        "$PARENT_ROUTE_HOME") || PARENT_BINDINGS_MATCH=0
      if [ "$PARENT_BINDINGS_MATCH" = 1 ] \
        && [ "$LIVE_PARENT_HOME" != "$DURABLE_PARENT_HOME" ]; then
        PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PARENT_BINDINGS_MATCH" = 1 ] \
      && fm_pf_home_id_valid "secondmate:$SECOND_MATE_ID"; then
      PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$SECOND_MATE_ID"
      if PUBLIC_FOLLOWUP_HOME=$(public_followup_resolve_primary_home \
          "$PRIMARY_HOME_CANDIDATE" "$FM_HOME" "$SECOND_MATE_ID"); then
        PUBLIC_FOLLOWUP_STATE="$PUBLIC_FOLLOWUP_HOME/state"
        PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
        if [ "$FORCE" != "--force" ] \
          && fm_pf_relay_active "$PUBLIC_FOLLOWUP_HOME"; then
          PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
        fi
      else
        PUBLIC_FOLLOWUP_HOME=
        PUBLIC_FOLLOWUP_STATE=
      fi
    fi
  else
    # A home seeded before the durable record existed retains the legacy
    # launch-time binding behavior unchanged.
    PRIMARY_HOME_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}
    if [ -n "$PRIMARY_HOME_CANDIDATE" ]; then
      if fm_pf_relay_active "$PRIMARY_HOME_CANDIDATE"; then
        PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
      fi
    elif fm_pf_relay_active "$FM_HOME"; then
      PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE=1
    fi
    if [ "$PUBLIC_FOLLOWUP_PARENT_RELAY_ACTIVE" = 1 ]; then
      PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=1
      if fm_pf_home_id_valid "secondmate:$SECOND_MATE_ID"; then
        PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$SECOND_MATE_ID"
        if PUBLIC_FOLLOWUP_HOME=$(public_followup_resolve_primary_home \
            "$PRIMARY_HOME_CANDIDATE" "$FM_HOME" "$SECOND_MATE_ID"); then
          PUBLIC_FOLLOWUP_STATE="$PUBLIC_FOLLOWUP_HOME/state"
          PUBLIC_FOLLOWUP_PARENT_UNRESOLVED=0
          if [ "$FORCE" != "--force" ] \
            && fm_pf_relay_active "$PUBLIC_FOLLOWUP_HOME"; then
            PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
          fi
        else
          PUBLIC_FOLLOWUP_HOME=
          PUBLIC_FOLLOWUP_STATE=
        fi
      fi
    else
      PUBLIC_FOLLOWUP_HOME=
      PUBLIC_FOLLOWUP_STATE=
    fi
  fi
elif [ "$KIND" = secondmate ]; then
  PUBLIC_FOLLOWUP_WORK_HOME="secondmate:$ID"
  if [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
    PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
  fi
elif [ "$FORCE" != "--force" ] && fm_pf_relay_active "$FM_HOME"; then
  PUBLIC_FOLLOWUP_RELAY_ACTIVE=1
fi

meta_value() {
  local meta=$1 key=$2
  fm_meta_get "$meta" "$key"
}

require_orca_worktree_id() {
  local meta=$1 id
  id=$(meta_value "$meta" orca_worktree_id)
  if [ -z "$id" ]; then
    echo "error: missing orca_worktree_id in $meta; cannot remove Orca worktree" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

require_orca_terminal() {
  local meta=$1 terminal
  terminal=$(meta_value "$meta" terminal)
  if [ -z "$terminal" ]; then
    echo "error: missing terminal in $meta; cannot close Orca terminal" >&2
    return 1
  fi
  printf '%s\n' "$terminal"
}

if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  ORCA_WORKTREE_ID=$(require_orca_worktree_id "$META") || exit 1
  T_ORCA=$(meta_value "$META" terminal)
  [ -z "$T_ORCA" ] || T=$T_ORCA
fi

# Where a harness's firstmate-owned global turn-end registry entry lives is
# owned by bin/fm-control-lib.sh, so teardown and the control plane's relaunch
# retire the same artifact rather than each carrying its own copy of the path.
remove_grok_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path grok "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path grok "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

remove_kimi_turnend_auth() {
  local state_dir=$1 id=$2 token_path token='' path
  token_path=$(fm_control_harness_turnend_token_path kimi "$state_dir" "$id") || return 1
  if [ -n "$token_path" ] && [ -f "$token_path" ]; then
    IFS= read -r token < "$token_path" || [ -n "$token" ] || return 1
  fi
  path=$(fm_control_harness_turnend_auth_path kimi "$token") || return 1
  [ -n "$path" ] || return 0
  rm -f -- "$path"
}

retire_busy_state() {
  local state_dir=$1 id=$2 gen=${3:-}
  if [ -n "$gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --gen "$gen"
  elif [ -f "$state_dir/$id.busy-gen" ]; then
    "$SCRIPT_DIR/fm-busy-event.sh" retire "$state_dir" "$id" --current-gen
  fi
}

validate_pr_poll_cleanup() {
  local state_dir=$1 id=$2 state_device artifact has_artifact=0
  fm_task_id_path_safe "$id" || return 0
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    has_artifact=1
  done
  [ "$has_artifact" -eq 1 ] || return 0
  [ -d "$state_dir" ] && [ ! -L "$state_dir" ] || return 1
  state_device=$(fm_pr_file_device "$state_dir") || return 1
  for artifact in "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust"; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    if [ ! -f "$artifact" ] || [ -L "$artifact" ] \
      || [ "$(fm_pr_file_device "$artifact")" != "$state_device" ] \
      || [ "$(fm_pr_file_link_count "$artifact")" != 1 ] \
      || { [ "$artifact" = "$state_dir/$id.merge-authority" ] \
        && [ "$(fm_pr_file_mode "$artifact")" != 600 ]; }; then
      echo "REFUSED: unsafe task PR-check artifact; preserving task state." >&2
      return 1
    fi
  done
  if [ -e "$state_dir/$id.pr-poll-retirement" ] \
    || [ -L "$state_dir/$id.pr-poll-retirement" ]; then
    fm_pr_poll_retirement_state_valid "$state_dir" "$id" || {
      echo "REFUSED: invalid PR-poll retirement receipt; preserving task state." >&2
      return 1
    }
  fi
}

remove_pr_poll_artifacts() {
  local state_dir=$1 id=$2
  validate_pr_poll_cleanup "$state_dir" "$id" || return 1
  fm_pr_poll_retirement_recover_one "$state_dir" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" || return 1
  fm_pr_poll_merge_notified_remove "$state_dir" "$id" || return 1
  rm -f "$state_dir/$id.check.sh" "$state_dir/$id.pr-poll" \
    "$state_dir/$id.pr-poll-registration" "$state_dir/$id.pr-poll-retirement" \
    "$state_dir/$id.merge-authority" "$state_dir/$id.check-trust" || return 1
}

# Resolve the PR number for a worktree branch via gh-axi. Echoes the number on a
# single match and returns 0; returns non-zero on no match or any lookup failure,
# so the caller treats it as "no PR found" (fail-safe).
pr_number_from_branch() {
  local branch=$1 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "${TEARDOWN_LANDED_DIR:-$WT}" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    *"/pulls/"*)  # Forgejo addresses pulls as /pulls/<n> and serves refs/pull/<n>/head.
      n=${target##*/pulls/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# The landed-work helpers below measure a ref in a directory: the task copy's
# HEAD by default, or, through teardown_landed, any other directory and ref.
ensure_commit_object() {
  local target=$1 commit=$2 n dir=${TEARDOWN_LANDED_DIR:-$WT}
  git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(pr_number_from_target "$target") || return 1
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$dir" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null
}

patch_id_for_commit() {
  local commit=$1
  git -C "${TEARDOWN_LANDED_DIR:-$WT}" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

unpushed_patches_are_in_pr_head() {
  local pr_head=$1 current base pr_patch_ids commit patch_id unpushed
  local dir=${TEARDOWN_LANDED_DIR:-$WT} ref=${TEARDOWN_LANDED_REF:-HEAD}
  current=$(git -C "$dir" rev-parse --verify "$ref" 2>/dev/null) || return 1
  base=$(git -C "$dir" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$dir" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$dir" log --format=%H "$ref" --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(patch_id_for_commit "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# The default-branch ref that already-landed history is read from, resolved the
# way fm_task_copy_content_in_default resolves it but without fetching: origin's
# copy when the copy has an origin remote, else the local branch. A stale ref is
# still sound because every commit reachable from it is in the default branch.
landed_default_ref() {
  local name=${BASE_BRANCH:-} ref dir=${TEARDOWN_LANDED_DIR:-$WT}
  [ -n "$name" ] || name=$(fm_task_copy_default_branch "$PROJ") || return 1
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    ref="refs/remotes/origin/$name"
  else
    ref="refs/heads/$name"
  fi
  git -C "$dir" rev-parse --quiet --verify "$ref^{commit}" >/dev/null 2>&1 || return 1
  printf '%s\n' "$ref"
}

# One "<short sha> <subject>" line per commit whose change the merged PR head was
# not proven to carry. The refusal prints it so the next step names the work.
TEARDOWN_UNPROVEN_COMMITS=

# A pipeline rebase leaves the copy on pre-rebase commits that the PR head
# replays as new commits, and the copy's commits may sit on a remote the
# pipeline pushed to, so they are not unpushed. Every commit of the copy that
# neither the PR head nor the default branch contains must be proven present:
# a non-merge commit by a stable patch id found among the PR head's own commits,
# and a merge commit only when its tree is exactly what git produces by merging
# its two parents, because such a merge contributes nothing of its own. A commit
# with no proof, a merge with a hand-written change, a conflicted merge, or an
# octopus merge leaves the copy unproven. A copy whose commits were rewritten
# beyond their patch, as a conflict resolution during the rebase does, stays
# unproven on purpose: only the captain's own words discard it.
rebased_commits_are_in_pr_head() {
  local pr_head=$1 current default_ref base pr_commits pr_patch_ids candidates commit parents
  local patch_id tree merged proven unproven=
  local dir=${TEARDOWN_LANDED_DIR:-$WT} ref=${TEARDOWN_LANDED_REF:-HEAD}
  local -a fields
  TEARDOWN_UNPROVEN_COMMITS=
  current=$(git -C "$dir" rev-parse --verify "$ref" 2>/dev/null) || return 1
  default_ref=$(landed_default_ref) || default_ref=
  if [ -n "$default_ref" ]; then
    pr_commits=$(git -C "$dir" rev-list --no-merges "$pr_head" --not "$default_ref" -- 2>/dev/null) || return 1
  else
    base=$(git -C "$dir" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
    pr_commits=$(git -C "$dir" rev-list --no-merges "$base..$pr_head" -- 2>/dev/null) || return 1
  fi
  pr_patch_ids=$(
    printf '%s\n' "$pr_commits" \
      | while IFS= read -r commit; do
          [ -n "$commit" ] || continue
          patch_id_for_commit "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  candidates=$(git -C "$dir" rev-list "$current" --not "$pr_head" ${default_ref:+"$default_ref"} -- 2>/dev/null) || return 1
  [ -n "$candidates" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    parents=$(git -C "$dir" rev-list --parents -n 1 "$commit" 2>/dev/null) || return 1
    read -r -a fields <<EOF
$parents
EOF
    proven=0
    case ${#fields[@]} in
      1|2)
        patch_id=$(patch_id_for_commit "$commit")
        if [ -n "$patch_id" ] && printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id"; then
          proven=1
        fi
        ;;
      3)
        tree=$(git -C "$dir" rev-parse --verify "$commit^{tree}" 2>/dev/null) || tree=
        if merged=$(git -C "$dir" merge-tree --write-tree "${fields[1]}" "${fields[2]}" 2>/dev/null); then
          merged=$(printf '%s\n' "$merged" | head -1)
          if [ -n "$tree" ] && [ "$merged" = "$tree" ]; then
            proven=1
          fi
        fi
        ;;
    esac
    [ "$proven" = 1 ] || unproven="$unproven$(git -C "$dir" log -1 --format='%h %s' "$commit" 2>/dev/null)"$'\n'
  done <<EOF
$candidates
EOF
  TEARDOWN_UNPROVEN_COMMITS=${unproven%$'\n'}
  [ -z "$unproven" ]
}

# Why the pipeline-input proof below did not hold, one line per reason, so a
# refusal names the missing or mismatched record rather than guessing.
TEARDOWN_PIPELINE_INPUT_REASON=

# The pipeline's own review and document steps rewrite and add commits on the
# branch it pushes, so a copy that was the pipeline's INPUT is neither an
# ancestor of the merged PR head nor made of patches the PR head replays
# unchanged. Such a copy is proven landed from the no-mistakes run record, never
# from commit content: a recorded run for the merged PR pushed exactly the merged
# PR head, that run started from a recorded input head (submitted_head_sha), and
# this copy's HEAD is exactly that input head. The copy is then the input of the
# run whose pushed head merged. A copy at any other commit refuses, as does a run
# that pushed some other head; each missing record is named. Commit subjects and
# times never count.
pipeline_input_is_local_head() {  # <merged pr head> <merged pr url>
  local pr_head=$1 pr_url=$2 current db rows kind id submitted pushed
  local timeout=${NM_TEARDOWN_TIMEOUT:-10} runs=0 tied=0 reasons=
  local dir=${TEARDOWN_LANDED_DIR:-$WT} ref=${TEARDOWN_LANDED_REF:-HEAD}
  TEARDOWN_PIPELINE_INPUT_REASON=
  current=$(git -C "$dir" rev-parse --verify "$ref" 2>/dev/null) || current=
  if [ -z "$current" ]; then
    TEARDOWN_PIPELINE_INPUT_REASON="this copy's HEAD cannot be read"
    return 1
  fi
  if [ -z "$pr_url" ]; then
    TEARDOWN_PIPELINE_INPUT_REASON="the merged PR's URL is not known, so no run record can be tied to it"
    return 1
  fi
  db=$(fm_nm_state_db "$dir")
  if [ ! -f "$db" ]; then
    TEARDOWN_PIPELINE_INPUT_REASON="no no-mistakes state database at $db, so no run record ties this copy to $pr_url"
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    TEARDOWN_PIPELINE_INPUT_REASON="python3 is not available, so the no-mistakes run record for $pr_url cannot be read"
    return 1
  fi
  if ! rows=$(fm_nm_bounded "$dir" "$timeout" python3 -I - "$db" "$pr_url" 2>/dev/null <<'PY'
import re
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

database, pr_url = sys.argv[1:]
needed = ("id", "pr_url", "submitted_head_sha", "last_pushed_sha")
try:
    with closing(sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
        have = {row[1] for row in db.execute("PRAGMA table_info(runs)")}
        missing = [name for name in needed if name not in have]
        if missing:
            print("missing-column|" + ",".join(missing))
        else:
            rows = db.execute(
                "SELECT id, submitted_head_sha, last_pushed_sha FROM runs WHERE pr_url = ? "
                "ORDER BY created_at, id", (pr_url,)
            ).fetchall()
            for row in rows:
                values = ["" if value is None else str(value) for value in row]
                if re.fullmatch(r"[A-Za-z0-9_-]+", values[0]):
                    print("run|" + "|".join(values))
except (OSError, ValueError, sqlite3.Error):
    print("unreadable|")
PY
  ); then
    TEARDOWN_PIPELINE_INPUT_REASON="the no-mistakes run record for $pr_url could not be read from $db"
    return 1
  fi
  while IFS='|' read -r kind id submitted pushed; do
    case "$kind" in
      missing-column)
        TEARDOWN_PIPELINE_INPUT_REASON="the no-mistakes run table in $db is missing column(s) $id, so no run record ties this copy to $pr_url"
        return 1
        ;;
      unreadable)
        TEARDOWN_PIPELINE_INPUT_REASON="the no-mistakes run record for $pr_url could not be read from $db"
        return 1
        ;;
      run) ;;
      *) continue ;;
    esac
    runs=$((runs + 1))
    if [ -z "$pushed" ]; then
      reasons="${reasons}run $id records no pushed head (last_pushed_sha), so it cannot be tied to the merged PR head ${pr_head:0:12}"$'\n'
      continue
    fi
    if [ "$pushed" != "$pr_head" ]; then
      reasons="${reasons}run $id pushed ${pushed:0:12}, not the merged PR head ${pr_head:0:12}"$'\n'
      continue
    fi
    tied=$((tied + 1))
    if ! fm_pr_head_valid "$submitted"; then
      reasons="${reasons}run $id records no input head (submitted_head_sha), so this copy's HEAD cannot be placed in what the run started from"$'\n'
      continue
    fi
    if [ "$submitted" = "$current" ]; then
      return 0
    fi
    reasons="${reasons}run $id started from ${submitted:0:12}; this copy's HEAD ${current:0:12} is not that head, so this copy is not the input the run started from"$'\n'
  done <<EOF
$rows
EOF
  if [ "$runs" -eq 0 ]; then
    reasons="no no-mistakes run record names the merged PR $pr_url"$'\n'
  elif [ "$tied" -eq 0 ]; then
    reasons="${reasons}no recorded run pushed the merged PR head ${pr_head:0:12}"$'\n'
  fi
  TEARDOWN_PIPELINE_INPUT_REASON=${reasons%$'\n'}
  return 1
}

# Is the worktree's PR merged for local work contained in that PR? Resolves the
# PR from the recorded pr= URL first, then from the branch name, and asks the
# forge for both the PR state and head: a recorded Forgejo URL is read through
# tea (fm_pr_forgejo_read_record), and everything else through GitHub. Returns
# non-zero when the PR is not merged, the current work is not contained in the
# PR head, no PR is found, or any forge read error occurs - the caller then
# falls back to the content check.
pr_is_merged() {
  local branch=$1 target view state remainder head resolved_url current landed=0
  local dir=${TEARDOWN_LANDED_DIR:-$WT} ref=${TEARDOWN_LANDED_REF:-HEAD}
  [ -d "$dir" ] || return 1
  if [ -n "$PR_URL" ]; then
    target=$PR_URL
  else
    target=$(pr_number_from_branch "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  if fm_pr_url_parse "$target" && [ "$FM_PR_PROVIDER" = forgejo ]; then
    fm_pr_forgejo_read_record "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" || {
      TEARDOWN_LANDED_UNASKED="the forge record of $target could not be read"
      return 1
    }
    [ "$FM_PR_RECORD_MERGED" = true ] || return 1
    head=$FM_PR_RECORD_HEAD
    fm_pr_head_valid "$head" || return 1
    resolved_url=$FM_PR_URL
  else
    view=$(cd "$dir" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || {
      TEARDOWN_LANDED_UNASKED="gh pr view $target failed (exit $?)"
      return 1
    }
    state=${view%%$'\t'*}
    remainder=${view#*$'\t'}
    [ "$state" != "$view" ] || return 1
    head=${remainder%%$'\t'*}
    resolved_url=${remainder#*$'\t'}
    [ "$head" != "$remainder" ] || return 1
    case "$state" in
      MERGED|merged) ;;
      *) return 1 ;;
    esac
  fi
  [ -n "$head" ] || return 1
  ensure_commit_object "$target" "$head" || {
    TEARDOWN_LANDED_UNASKED="the merged head of $target could not be fetched"
    return 1
  }
  current=$(git -C "$dir" rev-parse --verify "$ref" 2>/dev/null) || return 1
  if git -C "$dir" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif unpushed_patches_are_in_pr_head "$head"; then
    landed=1
  elif rebased_commits_are_in_pr_head "$head"; then
    landed=1
  elif pipeline_input_is_local_head "$head" "$resolved_url"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$PR_URL" ]; then
    [ -n "$resolved_url" ] || return 1
    PR_URL=$resolved_url
  fi
  return 0
}


# A successful landing proof binds to a directory and immutable commit, not
# to a branch name. Reuse it during the final return's dirty/HEAD recheck, so
# forge and fetch calls run outside project custody. A changed HEAD there
# refuses for a fresh proof on retry rather than doing network work under it.
TEARDOWN_LANDED_DIRS=()
TEARDOWN_LANDED_HEADS=()
# Why a failed proof could not ask the question (forge, fetch, HEAD or content
# comparison), empty when it answered "not landed". A reader that types
# refusals must not count an unasked proof as a policy refusal.
TEARDOWN_LANDED_UNASKED=
TEARDOWN_BUNDLE_PROOF=
work_is_landed_bundle() {  # <branch> <dir> <head> [hint]
  teardown_bundle_preserved "$2" "$3" "${4:-}" || return 1
  [ -z "$1" ] || TEARDOWN_BUNDLE_PROOF=$TEARDOWN_BUNDLE_ACCEPTED
}
work_is_landed() {
  local branch=$1 dir=${TEARDOWN_LANDED_DIR:-$WT} ref=${TEARDOWN_LANDED_REF:-HEAD} head i
  TEARDOWN_LANDED_UNASKED=
  head=$(git -C "$dir" rev-parse --verify "$ref^{commit}" 2>/dev/null) || {
    TEARDOWN_LANDED_UNASKED="HEAD of $dir cannot be resolved"
    return 1
  }
  TEARDOWN_UNPROVEN_COMMITS=
  TEARDOWN_PIPELINE_INPUT_REASON=
  for i in "${!TEARDOWN_LANDED_DIRS[@]}"; do
    if [ "${TEARDOWN_LANDED_DIRS[$i]}" = "$dir" ] && [ "${TEARDOWN_LANDED_HEADS[$i]}" = "$head" ]; then
      return 0
    fi
  done
  if [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ] && [ "$TEARDOWN_SLOT_CUSTODY" != project ]; then
    # Bundle proofs are local, so re-read them even under final project custody.
    work_is_landed_bundle "$branch" "$dir" "$head" && return 0
    echo "REFUSED: $dir changed to HEAD $head after its landing proof; retain the lease and task record and retry for a fresh proof" >&2
    TEARDOWN_LANDED_UNASKED="HEAD changed to ${head:0:12} after its landing proof; retry for a fresh proof"
    return 1
  fi
  local TEARDOWN_LANDED_DIR=$dir TEARDOWN_LANDED_REF=$head
  if work_is_landed_proof "$branch"; then
    TEARDOWN_LANDED_DIRS+=("$dir")
    TEARDOWN_LANDED_HEADS+=("$head")
    return 0
  fi
  work_is_landed_bundle "$branch" "$dir" "$head" hint
}

# A pushed branch proves recoverability, not delivery: require the landing
# proofs documented in this script's header even when every commit is pushed.
work_is_landed_proof() {
  local branch=$1
  local dir=${TEARDOWN_LANDED_DIR:-$WT} ref=${TEARDOWN_LANDED_REF:-HEAD}
  # Each call reports on its own directory and ref, never on an earlier call's.
  TEARDOWN_UNPROVEN_COMMITS=
  TEARDOWN_PIPELINE_INPUT_REASON=
  if [ "$MODE" = local-only ]; then
    local name
    name=$(fm_task_copy_default_branch "$PROJ") || name=
    if [ -n "$name" ] && git -C "$dir" merge-base --is-ancestor "$ref" "refs/heads/$name" 2>/dev/null; then
      return 0
    fi
  fi
  pr_is_merged "$branch" && return 0
  fm_task_copy_content_in_default "$dir" "$PROJ" "${BASE_BRANCH:-}" "$ref" && return 0
  [ -z "$FM_TASK_COPY_UNASKED" ] || TEARDOWN_LANDED_UNASKED=${TEARDOWN_LANDED_UNASKED:-$FM_TASK_COPY_UNASKED}
  return 1
}

# Archive cleanup needs its own stricter proof, not the pipeline-input exception:
# the forge's merged PR head must match its merge commit on every path either
# side changed. Keep filenames NUL-delimited and literal, including deletions.
TEARDOWN_ARCHIVE_PR_HEAD=
task_archive_pr_matches_merge() {
  local target=$1 view state head merge parent base paths_file path
  local TEARDOWN_LANDED_DIR=$PROJ
  local -a paths=()
  TEARDOWN_ARCHIVE_PR_HEAD=
  view=$(cd "$PROJ" && gh pr view "$target" --json state,headRefOid,mergeCommit \
    -q '[.state, .headRefOid, (.mergeCommit.oid // "")] | join("\t")' 2>/dev/null) || return 1
  IFS=$'\t' read -r state head merge <<< "$view"
  [ "$state" = MERGED ] || return 1
  fm_pr_head_valid "$head" && fm_pr_head_valid "$merge" || return 1
  ensure_commit_object "$target" "$head" || return 1
  if ! git -C "$PROJ" cat-file -e "$merge^{commit}" 2>/dev/null; then
    git -C "$PROJ" fetch --quiet --no-tags origin "$merge" >/dev/null 2>&1 || return 1
    git -C "$PROJ" cat-file -e "$merge^{commit}" 2>/dev/null || return 1
  fi
  parent=$(git -C "$PROJ" rev-parse --verify "$merge^" 2>/dev/null) || return 1
  base=$(git -C "$PROJ" merge-base "$head" "$parent" 2>/dev/null) || return 1
  paths_file=$(mktemp "$STATE/.$ID.archive-paths.XXXXXX") || return 1
  if ! git -C "$PROJ" diff --no-ext-diff --no-renames --name-only -z "$base" "$head" -- > "$paths_file" \
     || ! git -C "$PROJ" diff --no-ext-diff --no-renames --name-only -z "$parent" "$merge" -- >> "$paths_file"; then
    rm -f -- "$paths_file"
    return 1
  fi
  while IFS= read -r -d '' path; do paths+=("$path"); done < "$paths_file"
  rm -f -- "$paths_file"
  # An empty path set compares the whole tree instead of proving nothing.
  git -C "$PROJ" --literal-pathspecs diff --no-ext-diff --no-textconv --quiet "$head" "$merge" -- \
    "${paths[@]+"${paths[@]}"}" || return 1
  TEARDOWN_ARCHIVE_PR_HEAD=$head
}

reap_task_archive_branches() {
  local refs ref sha branch target head cherry merges checked_out reason
  local hex8='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
  [ "$KIND" = ship ] && teardown_owns_worktree || return 0
  refs=$(git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)' \
    "refs/heads/archive/$ID-submitted-$hex8" "refs/heads/archive/$ID-pipeline-$hex8") || {
    echo "warning: could not enumerate task $ID's archive branches; keeping them" >&2
    return 0
  }
  [ -n "$refs" ] || return 0
  reason=
  head=
  if [ "$FORCE" = --force ]; then
    reason="forced discard is not landing proof"
  else
    target=$PR_URL
    [ -n "$target" ] || target=$(pr_number_from_branch "$(teardown_record_branch)") || target=
    if [ -n "$target" ] && task_archive_pr_matches_merge "$target"; then
      head=$TEARDOWN_ARCHIVE_PR_HEAD
    else
      reason="merged PR head and matching merge content could not be proven"
    fi
  fi
  checked_out=$(git -C "$PROJ" worktree list --porcelain 2>/dev/null) \
    || reason="checked-out branch inventory could not be read"
  while read -r ref sha; do
    [ -n "$ref" ] || continue
    branch=${ref#refs/heads/}
    if [ -n "$reason" ]; then
      echo "notice: keeping $branch ($reason)" >&2
      continue
    fi
    if printf '%s\n' "$checked_out" | grep -qxF "branch $ref"; then
      echo "notice: keeping $branch (checked out in a local copy)" >&2
      continue
    fi
    if ! git -C "$PROJ" merge-base --is-ancestor "$sha" "$head" 2>/dev/null; then
      # git cherry omits merge commits, so it alone cannot prove a merge's edits.
      # Non-ancestor merges stay archived rather than being silently discarded.
      if ! merges=$(git -C "$PROJ" rev-list --merges "$sha" --not "$head" -- 2>/dev/null) \
         || [ -n "$merges" ] \
         || ! cherry=$(git -C "$PROJ" cherry "$head" "$sha" 2>/dev/null); then
        echo "notice: keeping $branch (archive history is not proven carried by the merged PR head)" >&2
        continue
      fi
      case "$cherry" in
        +*|*$'\n+'*)
          echo "notice: keeping $branch (archive patches are not all carried by the merged PR head)" >&2
          continue ;;
      esac
    fi
    # The expected old value prevents a concurrently moved archive from being
    # deleted on proof about its previous head. Never detach another copy.
    if git -C "$PROJ" update-ref -d "$ref" "$sha" 2>/dev/null; then
      echo "teardown: reaped $branch (carried by the merged PR lineage)" >&2
    else
      echo "notice: keeping $branch (archive deletion could not be completed at its proven head)" >&2
    fi
  done <<EOF
$refs
EOF
}

# The one cleanup commit rule (landing or recorded bundle), applied to <ref>
# in <dir>: the task copy's own HEAD,
# the enclosing slot's HEAD, or a removed copy's branch ref read from the
# project. <branch> names the PR lookup, as for work_is_landed.
teardown_landed() {  # <dir> <ref> <branch>
  local TEARDOWN_LANDED_DIR=$1 TEARDOWN_LANDED_REF=$2
  work_is_landed "$3"
}

TEARDOWN_DROPPING=0
teardown_is_dropping() {
  local report="$DATA/$ID/report.md"
  [ -n "$DROP_FILE" ] && [ "$KIND" != secondmate ] || return 1
  if [ "$KIND" = scout ]; then
    [ -f "$report" ] && [ ! -L "$report" ] && [ -s "$report" ] && return 1
    return 0
  fi
  return 0
}

# The completion links this teardown already holds locally. A scout's
# deliverable is its report, a ship whose commits only a recorded bundle holds
# names that bundle and says it is not landed, a local-only ship lands on local
# main, and every other ship carries the PR recorded on its own record.
BACKLOG_DONE_ARGS=()
TEARDOWN_RECORDED_PR_ONLY=0
backlog_done_args() {
  local data_relative
  BACKLOG_DONE_ARGS=()
  if [ "$TEARDOWN_DROPPING" = 1 ]; then
    BACKLOG_DONE_ARGS=(--note dropped)
    return 0
  fi
  case "$KIND" in
    scout)
      data_relative=$(fm_backlog_data_relative "$DATA") || return 1
      BACKLOG_DONE_ARGS=(--report "$data_relative/$ID/report.md")
      ;;
    *)
      if [ -n "$TEARDOWN_BUNDLE_PROOF" ]; then
        BACKLOG_DONE_ARGS=(--note "preserved in bundle $TEARDOWN_BUNDLE_PROOF, not landed")
      elif [ "$MODE" = local-only ] && [ "$TEARDOWN_RECORDED_PR_ONLY" = 0 ]; then
        BACKLOG_DONE_ARGS=(--note "local main")
      elif [ -n "$PR_URL" ]; then
        BACKLOG_DONE_ARGS=(--pr "$PR_URL")
      fi
      ;;
  esac
}

# Closing the backlog item is this script's own last act on the record, not a
# printed instruction for a later turn (bin/fm-backlog-transition-lib.sh owns the
# invariant). This prints what already happened, so the follow-up wording stays
# only where a human still owes the edit.
backlog_refresh_reminder() {
  local backlog_display root backend=markdown
  [ "$KIND" = secondmate ] && return 0
  [ "$CLEANUP_RECOVERY" = orca ] && return 0
  if root=$(fm_backlog_root "$DATA"); then
    backend=$(fm_tasks_axi_backend "$root") || return 2
  fi
  if [ "$backend" != markdown ]; then
    backlog_display="this home's configured tasks-axi backend (data directory $DATA)"
  elif backlog_display=$(fm_backlog_file "$DATA"); then
    :
  else
    backlog_display="${DATA%/}/backlog.md"
  fi
  if [ "$BACKLOG_CLOSED" = 1 ] && [ "$BACKLOG_TRANSITION" = retain ]; then
    printf '%s\n' "Backlog: $ID stays open in $backlog_display, still held for the captain with its deliverable recorded. Relay the question and close it only with bin/fm-captain-hold.sh answer."
  elif [ "$BACKLOG_CLOSED" = 1 ]; then
    printf '%s\n' "Backlog: $ID is closed in $backlog_display. Run bin/fm-tasks-axi.sh ready for dependency-cleared candidates, check date gates, and dispatch only work whose blockers are gone and date is due."
  else
    printf '%s\n' "Backlog: $ID just finished ($BACKLOG_SKIP_REASON). Update $backlog_display - move $ID to Done, keep Done to the 10 most recent, then re-scan Queued and dispatch only work whose blockers are gone and date is due."
  fi
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

removal_target_abs_path() {
  local target=$1
  if [ -d "$target" ]; then
    cd "$target" && pwd -P
  else
    cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$target")"
  fi
}

worktree_registered_for_project() {
  local project=$1 target=$2 abs_target listed line listed_abs
  [ -n "$project" ] || return 1
  [ -d "$project" ] || return 1
  git -C "$project" rev-parse --git-dir >/dev/null 2>&1 || return 1
  abs_target=$(removal_target_abs_path "$target")
  listed=$(git -C "$project" -c core.quotePath=false worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        listed_abs=$(removal_target_abs_path "${line#worktree }" 2>/dev/null || true)
        [ "$listed_abs" = "$abs_target" ] && return 0
        ;;
    esac
  done <<EOF
$listed
EOF
  return 1
}

retry_wait_secs_is_valid() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]
}

STALE_WORKTREE_LOCK_AGE_SECS=${FM_STALE_WORKTREE_LOCK_AGE_SECS:-30}
# Bounded patience window for transient index.lock after killing a crew process.
# New knobs are preferred; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS remains an alias
# for the per-attempt wait so existing tests and operators keep working.
TREEHOUSE_RETURN_LOCK_RETRIES=${FM_TREEHOUSE_RETURN_LOCK_RETRIES:-3}
TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=${FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS:-${FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS:-1}}
if ! retry_wait_secs_is_valid "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"; then
  echo "teardown: invalid treehouse return lock retry wait '$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS'; using 1s" >&2
  TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1
fi
# Compatibility alias used by the safety-check wait path and older call sites.
STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS
TEARDOWN_TREEHOUSE_LOCK_REFUSED=2
TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED=3
TEARDOWN_PROCEVENT_RESTORE_FAILED=4
TEARDOWN_TREEHOUSE_CUSTODY_REFUSED=5

# True when treehouse/git stderr shows the transient index.lock "File exists" race.
# Other return failures must not enter the retry path.
treehouse_return_is_index_lock_error() {
  local text=$1
  printf '%s\n' "$text" | grep -Eq "Unable to create ['\"].*index\\.lock['\"]: File exists"
}

# Absolute path to the git index lock for a worktree/repo dir, or empty when it
# cannot be resolved (dir missing or not a git worktree at all).
worktree_git_lock_path() {
  local dir=$1 lock abs_dir
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  lock=$(git -C "$dir" rev-parse --git-path index.lock 2>/dev/null) || return 1
  [ -n "$lock" ] || return 1
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(fm_task_copy_canonical_dir "$dir") || return 1
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# The lock-staleness proof (lsof holder check, mtime age, fail-safe defaults)
# is owned by bin/fm-lock-lib.sh's fm_lock_is_provably_stale, sourced above.
# Teardown passes the worktree dir as the companion directory and its own
# STALE_WORKTREE_LOCK_AGE_SECS threshold.

worktree_safety_blocked_by_lock() {
  local reason=$1 lock
  lock=$(worktree_git_lock_path "$WT") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  echo "teardown: cannot inspect worktree $WT for $reason while git lock $lock is present; checking whether the lock is stale" >&2
  return 0
}

cleanup_stale_lock_for_safety_check() {
  local dir=$1 lock
  lock=$(worktree_git_lock_path "$dir") || lock=""
  [ -n "$lock" ] && [ -e "$lock" ] || return 0

  echo "teardown: worktree safety check blocked by git lock $lock; waiting ${STALE_WORKTREE_LOCK_RETRY_WAIT_SECS}s and retrying (owning process may be exiting)" >&2
  sleep "$STALE_WORKTREE_LOCK_RETRY_WAIT_SECS"

  if [ ! -e "$lock" ]; then
    echo "teardown: worktree safety check lock cleared on its own; retrying safety checks" >&2
    return 0
  fi

  if fm_lock_is_provably_stale "$lock" "$STALE_WORKTREE_LOCK_AGE_SECS" "$dir"; then
    rm -f "$lock"
    echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying worktree safety checks" >&2
    return 0
  fi

  echo "teardown: worktree safety check blocked by git lock $lock that is not provably stale (may belong to a live process); leaving it in place" >&2
  return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
}

# Record scans cannot see a parked copy whose record still names only the slot
# root. Registered nested copies must be this task's individually proven copies
# before cleanup, and must all be removed before any provider return, even on
# --force. Read the slot's own ref store, including paths containing newlines.
require_registered_slot_copies() {  # <task> <slot> [<proven-copy>...]
  local task=$1 slot=$2 canonical_slot inventory field copy known allowed refused=0
  shift 2
  if ! canonical_slot=$(fm_task_copy_canonical_dir "$slot"); then
    echo "REFUSED: cannot canonicalize pool slot $slot; retain its records and lease and inspect the slot path before retrying." >&2
    return 1
  fi
  slot=$canonical_slot
  inventory=$(mktemp "${TMPDIR:-/tmp}/fm-teardown-worktrees.XXXXXX") || return 1
  if ! git -C "$slot" worktree list --porcelain -z > "$inventory" 2>/dev/null; then
    rm -f "$inventory"
    echo "REFUSED: cannot inspect registered copies in pool slot $slot; retain its records and lease and report the Git inspection failure." >&2
    return 1
  fi
  while IFS= read -r -d '' field; do
    case "$field" in 'worktree '*) copy=${field#worktree } ;; *) continue ;; esac
    copy=$(fm_task_copy_canonical_dir "$copy") || copy=${field#worktree }
    case "$copy" in "$slot"/*) ;; *) continue ;; esac
    known=0
    for allowed in "$@"; do
      [ "$copy" != "$allowed" ] || known=1
    done
    [ "$known" = 0 ] || continue
    refused=1
    known=0
    for allowed in ${TEARDOWN_REFUSED_COPIES[@]+"${TEARDOWN_REFUSED_COPIES[@]}"}; do
      [ "$copy" != "$allowed" ] || known=1
    done
    if [ "$known" = 1 ]; then
      echo "REFUSED: pool slot $slot contains registered copy $(fm_refuse_text "$copy") that is not one of task $task's proven copies; its record and lease must stay in place, even with --force." >&2
    else
      FM_FRICTION_REVISION_FILE="$SCRIPT_DIR/fm-teardown.sh" \
        teardown_refuse_copy registered-copy-proven "pool slot $slot contains registered copy $copy that is not one of task $task's proven copies; its record and lease must stay in place, even with --force." "$copy"
    fi
  done < "$inventory"
  rm -f "$inventory"
  if [ "$refused" = 1 ]; then
    echo "Keep each listed copy and its records. For each one, run the completing-command or answer the human-only-exit question printed with its REFUSED line above, or, where an error: line was printed instead, fix what that line names and re-run; --force does not waive these proofs. Each listed copy may hold unlanded work. If an active task record owns a listed copy's work, reassociate that task to it first with FM_HOME=/path/to/owning-home bin/fm-control.sh <owning-task> reassociate --worktree <copy> --note <why>. If no active record owns a listed copy, inspect it by hand with git -C <copy> status --untracked-files=all and git -C <copy> log --oneline HEAD --not --remotes, confirm nothing there is unlanded, then remove it by hand with git -C $slot worktree remove <copy> (a copy locked by Vernant's creation lock is released by running scripts/git-stability/closeout_pr.py --cleanup-worktree <copy> --execute-cleanup from $slot, never by forcing the removal). Re-run this teardown afterwards." >&2
    return 1
  fi
}

# Return a worktree/home via `treehouse return --force`, tolerating a transient or
# stale git index.lock left by a killed crew process. See the script header.
teardown_treehouse_return() {  # <dir> <cd-dir> <label> <owner-task> [<post-cleanup-check>]
  local dir=$1 cd_dir=$2 label=$3 owner=$4 post_cleanup_check=${5:-}
  local out lock attempt=0 max_retries lock_desc check_custody=0

  # A directory Git cannot open has no worktree registrations to prove; every
  # Git directory, pool slot or not, must pass the custody check before each
  # forced return. Decide once, so a target lost mid-retry is still refused.
  ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || check_custody=1
  # Capture stdout+stderr so non-lock failures stay visible and lock failures can
  # be matched by signature even when the lock file is already gone mid-check.
  [ "$check_custody" = 0 ] || require_registered_slot_copies "$owner" "$dir" \
    || return "$TEARDOWN_TREEHOUSE_CUSTODY_REFUSED"
  if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  [ -n "$out" ] && printf '%s\n' "$out" >&2

  if ! treehouse_return_is_index_lock_error "$out"; then
    return 1
  fi

  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ]; then
    lock_desc=$lock
  else
    lock_desc="index.lock"
  fi

  max_retries=$TREEHOUSE_RETURN_LOCK_RETRIES
  case "$max_retries" in ''|*[!0-9]*) max_retries=3 ;; esac

  while [ "$attempt" -lt "$max_retries" ]; do
    attempt=$(( attempt + 1 ))
    echo "teardown: $label return failed with transient git lock ($lock_desc); waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s and retrying ($attempt/${max_retries})" >&2
    sleep "$TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS"

    [ "$check_custody" = 0 ] || require_registered_slot_copies "$owner" "$dir" \
      || return "$TEARDOWN_TREEHOUSE_CUSTODY_REFUSED"
    if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
      [ -n "$out" ] && printf '%s\n' "$out"
      echo "teardown: $label return succeeded on retry; lock cleared on its own" >&2
      return 0
    fi
    [ -n "$out" ] && printf '%s\n' "$out" >&2

    if ! treehouse_return_is_index_lock_error "$out"; then
      echo "teardown: $label return failed with a non-lock error after retry; aborting" >&2
      return 1
    fi
  done

  # Refresh lock path after the patience window; it may have appeared, moved, or
  # cleared while we waited.
  lock=$(worktree_git_lock_path "$dir") || lock=""
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    lock_desc=$lock
    if fm_lock_is_provably_stale "$lock" "$STALE_WORKTREE_LOCK_AGE_SECS" "$dir"; then
      rm -f "$lock"
      echo "teardown: removed provably-stale git lock $lock (age >= ${STALE_WORKTREE_LOCK_AGE_SECS}s, no live holder) and retrying $label return" >&2
      if [ -n "$post_cleanup_check" ]; then
        if ! "$post_cleanup_check"; then
          echo "teardown: $label return aborted after stale-lock cleanup because safety checks failed" >&2
          return 1
        fi
      fi
      [ "$check_custody" = 0 ] || require_registered_slot_copies "$owner" "$dir" \
        || return "$TEARDOWN_TREEHOUSE_CUSTODY_REFUSED"
      if out=$( ( cd "$cd_dir" && treehouse return --force "$dir" ) 2>&1 ); then
        [ -n "$out" ] && printf '%s\n' "$out"
        echo "teardown: $label return succeeded after stale-lock cleanup" >&2
        return 0
      fi
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      echo "teardown: $label return still failing after stale-lock cleanup" >&2
      return 1
    fi

    echo "teardown: $label return failed: git lock $lock_desc persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) and is not provably stale (may belong to a live process); leaving it in place" >&2
    return "$TEARDOWN_TREEHOUSE_LOCK_REFUSED"
  fi

  echo "teardown: $label return failed: git index.lock signature persisted across ${max_retries} retries (waiting ${TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS}s each) even after the lock file disappeared" >&2
  return 1
}

report_worktree_dirt() {
  # Use the same porcelain snapshot and exemptions as the refusal predicate.
  printf '%s\n' "$1" | awk '
    /^\?\? / { if (++untracked <= 10) paths = paths "  " substr($0, 4) "\n"; next }
    NF { tracked = 1 }
    END {
      if (tracked) print "uncommitted changes present (includes tracked edits)"
      else print "uncommitted changes present (untracked-only leftovers)"
      if (untracked) {
        print "untracked paths (up to 10):"
        printf "%s", paths
        if (untracked > 10) print "  ... additional untracked paths omitted"
      }
    }
  ' >&2
}

teardown_record_branch() {
  local branch
  branch=$(fm_meta_get "$META" branch)
  [ -n "$branch" ] || branch=fm/$ID
  printf '%s\n' "$branch"
}

teardown_refuse_removed_nested_copy() {
  echo "REFUSED: task $ID's nested copy $WT is already removed and its branch is not landed; a pushed branch alone is not completion." >&2
  echo "Land its PR (or merge it to local main for a local-only ship), then re-run teardown, or get the captain's own words to drop it and pass --force --drop-file." >&2
  return 1
}

# Scratch and --force copies are scrubbed before Treehouse return. See the
# script header for why `git clean -fd` is not enough and why a dirty return
# is not reported as clean. The registered-copy custody proof runs before the
# clean, so a refused return never deletes a registered nested worktree
# (tests/fm-teardown.test.sh test_non_pool_returns_recheck_registered_copies).
teardown_scrub_scratch_copy() {  # <wt> <owner-task>
  local wt=$1 owner=$2
  # A non-git path has no nested repository this clean can remove.
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  require_registered_slot_copies "$owner" "$wt" || return "$TEARDOWN_TREEHOUSE_CUSTODY_REFUSED"
  git -C "$wt" clean -ffdq || {
    echo "error: could not clean scratch in worktree $wt before returning it; teardown aborted" >&2
    return 1
  }
}

# Callers run this only for a copy that was a Treehouse pool slot before the
# return; a return removes any other copy, and the pool cannot lose it.
teardown_note_dirty_return() {
  local wt=$1 residue_rc=0 residue slot_dir slot_label
  if git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    residue=$(git -C "$wt" status --porcelain --untracked-files=all) || residue_rc=$?
    [ "$residue_rc" -ne 0 ] || [ -n "$residue" ] || return 0
  else
    residue_rc=1
  fi
  TEARDOWN_POOL_SLOT_LOST=1
  slot_dir=$(canonical_existing_dir "$wt") || slot_dir=$wt
  slot_label=$(basename "$(dirname "$slot_dir")")
  [ "$residue_rc" -eq 0 ] || residue="cannot verify: the copy is missing or not a readable git worktree after return"
  echo "warning: treehouse return left pool slot $slot_label ($wt) dirty or unverified; the pool lost this slot. Remaining paths:" >&2
  printf '%s\n' "$residue" | sed 's/^/  /' >&2
}

validate_worktree_teardown_safety() {
  local dirty_raw dirty unpushed_raw unpushed branch recorded_pr_state wt_real
  TEARDOWN_BUNDLE_PROOF=
  [ "$FORCE" != "--force" ] || return 0
  case "$KIND" in
    secondmate|scout) return 0 ;;
  esac
  wt_real=$(fm_task_copy_canonical_dir "$WT") || wt_real=$WT
  if [ "$TEARDOWN_SLOT_REASSIGNED" = 1 ] \
      && { [ "$TEARDOWN_SLOT_SHARED" != 1 ] || [ "$wt_real" = "$TEARDOWN_SHARED_SLOT" ]; }; then
    # A reassigned slot's or shared root's HEAD and dirt may belong to its
    # claimant or remaining task. Use the retiring record's own delivery
    # evidence, never that copy's contents.
    if [[ "$PR_URL" =~ ^https://github[.]com/([^/]+/[^/]+)/pull/([0-9]+)$ ]] \
        && recorded_pr_state=$(gh pr view "$PR_URL" --json state -q '.state' 2>/dev/null) \
        && [ "$recorded_pr_state" = MERGED ]; then
      TEARDOWN_RECORDED_PR_ONLY=1
      return 0
    fi
    branch=$(teardown_record_branch)
    if git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null \
        && teardown_landed "$PROJ" "refs/heads/$branch" "$branch"; then
      return 0
    fi
    if [ "$TEARDOWN_SLOT_SHARED" = 1 ]; then
      echo "REFUSED: task $ID shares pool slot $TEARDOWN_SHARED_SLOT, but its recorded PR is not confirmed merged and its own branch $branch is not proved landed; its record and slot claim stay in place." >&2
      echo "Land this task's deliverable before re-running bin/fm-teardown.sh $ID; the shared slot will not be returned." >&2
    else
      echo "REFUSED: task $ID's recorded copy $WT was reassigned to task $TEARDOWN_SLOT_REASSIGNED_TO, but its recorded PR is not confirmed merged and its own branch $branch is not proved landed; its records stay in place." >&2
      echo "Land this task's deliverable before re-running bin/fm-teardown.sh $ID; the reassigned slot stays with its claimant." >&2
    fi
    return 1
  fi
  if [ ! -d "$WT" ] || [ "$(git -C "$WT" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
    if teardown_nested_slot landed; then
      return 0
    fi
    if [ -n "$TEARDOWN_RECORD_SLOT" ] && [ ! -d "$WT" ] \
       && git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$(teardown_record_branch)^{commit}" >/dev/null; then
      teardown_refuse_removed_nested_copy
      return 1
    fi
    if [[ "$PR_URL" =~ ^https://github[.]com/([^/]+/[^/]+)/pull/([0-9]+)$ ]] \
        && recorded_pr_state=$(gh pr view "$PR_URL" --json state -q '.state' 2>/dev/null) \
        && [ "$recorded_pr_state" = MERGED ]; then
      TEARDOWN_RECORDED_PR_ONLY=1
      return 0
    fi
    if [ -n "$TEARDOWN_RECORD_SLOT" ] && [ ! -d "$WT" ]; then
      teardown_refuse_removed_nested_copy
      return 1
    fi
    echo "REFUSED: task $ID has no recorded Git worktree; completion requires a recorded GitHub PR confirmed merged by the forge." >&2
    echo "Restore its copy, land its recorded PR, or get the captain's own words to drop it and pass --force --drop-file." >&2
    return 1
  fi

  if ! dirty_raw=$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null); then
    if worktree_safety_blocked_by_lock "uncommitted changes"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for uncommitted changes." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  dirty=$(fm_task_copy_dirty_status "$dirty_raw" "$wt_real" \
    ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"})

  if ! unpushed_raw=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null); then
    if worktree_safety_blocked_by_lock "commits not on a remote"; then
      return "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED"
    fi
    echo "REFUSED: cannot inspect worktree $WT for commits not on a remote." >&2
    echo "Restore the git index state, or get the captain's explicit OK to discard, then --force." >&2
    return 1
  fi
  unpushed=$(printf '%s\n' "$unpushed_raw" | head -5)

  if [ -n "$dirty" ]; then
    echo "REFUSED: worktree $WT has uncommitted changes." >&2
    report_worktree_dirt "$dirty"
    echo "Commit them (or get the captain's explicit OK to discard, then --force)." >&2
    return 1
  else
    branch=${TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY:-}
    if [ -z "$branch" ]; then
      branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      TEARDOWN_WORKTREE_BRANCH_FOR_SAFETY=$branch
    fi
    if ! work_is_landed "$branch"; then
      echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." >&2
      [ -z "$unpushed" ] || printf 'unpushed commits:\n%s\n' "$unpushed" >&2
      [ -z "$TEARDOWN_UNPROVEN_COMMITS" ] || printf 'commits whose change is not proven present in the merged PR head:\n%s\n' "$TEARDOWN_UNPROVEN_COMMITS" >&2
      [ -z "$TEARDOWN_PIPELINE_INPUT_REASON" ] || printf 'this copy is not proven to be the input of the pipeline run that produced the merged PR head:\n%s\n' "$TEARDOWN_PIPELINE_INPUT_REASON" >&2
      if [ "$MODE" = local-only ]; then
        echo "Merge the branch into local $(fm_task_copy_default_branch "$PROJ" 2>/dev/null || echo main) first (bin/fm-merge-local.sh after the captain approves), land its PR, or get the captain's own words to drop it and pass --force --drop-file." >&2
      else
        echo "Land its PR, or get the captain's own words to drop it and pass --force --drop-file." >&2
      fi
      return 1
    fi
  fi
}

# The landed-work test above, with its stale-lock retry, as a refusal: exits on
# failure. --force skips it.
require_worktree_teardown_safety() {
  local safety_rc=0
  [ "$FORCE" != "--force" ] || return 0
  validate_worktree_teardown_safety || safety_rc=$?
  [ "$safety_rc" -ne 0 ] || return 0
  if [ "$safety_rc" -eq "$TEARDOWN_WORKTREE_SAFETY_LOCK_BLOCKED" ]; then
    cleanup_stale_lock_for_safety_check "$WT" || exit 1
    validate_worktree_teardown_safety || exit 1
    return 0
  fi
  exit 1
}

# A slot found reassigned only at a later recheck was admitted by an owned-mode
# proof. Repeat the proof in reassigned mode; when it settles on the recorded
# PR, restage the pending backlog close so a local-only ship does not keep its
# owned-mode local-main note.
teardown_reprove_reassigned_slot() {
  local stage="$STATE/.$ID.backlog-close.${BASHPID:-$$}"
  teardown_release_project_lock || exit 1
  require_worktree_teardown_safety
  [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ] && [ "$TEARDOWN_RECORDED_PR_ONLY" = 1 ] || return 0
  if ! backlog_done_args \
     || ! fm_backlog_record_remove "$stage" "pending-close staged record" "$STATE" \
     || ! fm_backlog_close_marker_stage "$stage" "$ID" "$DATA" "$TEARDOWN_META_SPAWN_GEN" "$STATE" 0 \
       "${BACKLOG_TRANSITION_FLAGS[@]+"${BACKLOG_TRANSITION_FLAGS[@]}"}" \
       "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}" \
     || { [ "$BACKLOG_CLOSED" = 1 ] \
          && ! fm_backlog_atomic_transition publish "$stage" "$BACKLOG_CLOSE_MARKER" "pending-close record" "$STATE"; }; then
    fm_backlog_record_remove "$stage" "pending-close staged record" "$STATE" || true
    echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
    exit 1
  fi
}

# Fix 1 (see script header): does the active-or-most-recent no-mistakes run in
# worktree $1 belong to THIS task, and is it parked at a gate awaiting an agent
# that is about to be removed? Prints nothing; returns 0 only on a genuine
# match so the caller knows it is safe to abort - never a guess. Identity
# binds through the strict object-local head rule, with bin/fm-nm-run-lib.sh's
# shared ledger-anchored continuation rule as the only recognition for a head
# this copy cannot resolve at all.
NM_TEARDOWN_TIMEOUT=${FM_TEARDOWN_NM_TIMEOUT:-10}
case "$NM_TEARDOWN_TIMEOUT" in ''|*[!0-9]*) NM_TEARDOWN_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the parked-run
# continuation proof may scan, mirroring bin/fm-crew-state.sh's limit posture
# (generous: rows of other branches interleave freely in the real ledger).
NM_TEARDOWN_RUNS_LIMIT=${FM_TEARDOWN_NM_RUNS_LIMIT:-200}
case "$NM_TEARDOWN_RUNS_LIMIT" in ''|*[!0-9]*) NM_TEARDOWN_RUNS_LIMIT=200 ;; esac
TASK_RUN_ID=
task_status_is_own_parked_run() {  # <worktree> <axi-status-output>
  local wt=$1 out=$2 branch run_id run_branch run_head status outcome awaiting has_gate ledger
  TASK_RUN_ID=
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  [ -n "$out" ] || return 1
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ -n "$run_id" ] || return 1
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  [ -n "$run_branch" ] && [ "$run_branch" = "$branch" ] || return 1
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  [ -z "$outcome" ] || return 1
  status=$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")
  [ -n "$status" ] || return 1
  case "$status" in
    completed|failed|cancelled|passed|checks-passed|running|fixing|ci) return 1 ;;
  esac
  if ! fm_nm_head_matches_worktree "$wt" "$run_head"; then
    # The strict object-local rule rejected this run head. That rejection is
    # final when the head object resolves in this copy (diverged or rewritten
    # tips are genuine mismatches), but when the object is absent entirely -
    # the pipeline committed its fix round in its own repo and this copy
    # never fetched it - the ONE shared runs-ledger rule in
    # bin/fm-nm-run-lib.sh owns the only remaining recognition, and it prints
    # nothing for any ledger shape it cannot prove, so the run stays
    # untouched unless the ledger proves this exact continuation. Cleanup
    # consumes only an explicitly active (`running`) proved word: a terminal
    # newest row is finished history, never this parked run's abort
    # authorization (the read path classifies the same owner's answer; the
    # abort here must never fire for a run that already ended).
    [ -n "$run_head" ] || return 1
    [ -z "$(fm_nm_resolve_commit "$wt" "$run_head")" ] || return 1
    ledger=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" runs --limit "$NM_TEARDOWN_RUNS_LIMIT")
    [ "$(fm_nm_runs_status_for_worktree "$wt" "$branch" "$ledger" "$run_head")" = running ] || return 1
  fi
  awaiting=$(printf '%s\n' "$out" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
  has_gate=$(printf '%s\n' "$out" | grep -Eq '^[[:space:]]*gate:[[:space:]]*' && echo 1 || echo 0)
  case "$status" in
    awaiting_approval|fix_review) TASK_RUN_ID=$run_id; return 0 ;;
  esac
  if [ -n "$awaiting" ] || [ "$has_gate" = 1 ]; then
    TASK_RUN_ID=$run_id
    return 0
  fi
  return 1
}

task_run_is_own_parked_run() {  # <worktree>
  local wt=$1 out
  # Accepted best-effort residual: query failures stay fail-open because making
  # no-mistakes availability a prerequisite would block ship tasks with no run.
  out=$(fm_nm_run "$wt" "$NM_TEARDOWN_TIMEOUT" axi status)
  task_status_is_own_parked_run "$wt" "$out"
}

task_status_is_terminal_run() {  # <axi-status-output> <run-id>
  local out=$1 expected_id=$2 run_id outcome
  run_id=$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")
  [ "$run_id" = "$expected_id" ] || return 1
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    cancelled|failed|passed|checks-passed|passed-with-override|passed-with-skips) return 0 ;;
  esac
  return 1
}

task_status_is_run_not_found() {  # <status-error> <run-id>
  local actual expected
  actual=$(fm_nm_trim "$1")
  expected=$(printf 'error: "run \\"%s\\" not found"' "$2")
  [ "$actual" = "$expected" ]
}

# Abort THIS task's own parked no-mistakes run before the worker that would
# have answered its gate is removed, so no run is left orphaned holding a
# fleet slot. Only KIND=ship drives a no-mistakes validation of its own
# worktree (scouts and secondmates never do, mirroring bin/fm-crew-state.sh);
# a run not attributed to this exact branch+head is left completely alone.
conclude_task_no_mistakes_run() {  # <worktree>
  local wt=$1 out run_id
  [ "$KIND" = ship ] || return 0
  [ -d "$wt" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  task_run_is_own_parked_run "$wt" || return 0
  run_id=$TASK_RUN_ID
  echo "teardown: no-mistakes run for $ID is parked at a gate; aborting before the worker is removed" >&2
  # Accepted best-effort residual: abort supports run-id targeting but no atomic
  # live-state condition; fully closing the resume race needs upstream compare-and-cancel.
  fm_nm_run_checked "$wt" "$NM_TEARDOWN_TIMEOUT" axi abort --run "$run_id" >/dev/null 2>&1 || true
  if out=$(fm_nm_run_bounded "$wt" "$NM_TEARDOWN_TIMEOUT" axi status --run "$run_id" 2>&1); then
    task_status_is_terminal_run "$out" "$run_id" && return 0
  elif task_status_is_run_not_found "$out" "$run_id"; then
    return 0
  fi
  echo "REFUSED: no-mistakes run for $ID is still parked after axi abort; confirm it stopped (no-mistakes axi status) or abort it manually (no-mistakes axi abort --run <id>) before retrying teardown." >&2
  return 1
}

# Fix 2 (see script header): pid and matched cwd path for every process whose
# CURRENT WORKING DIRECTORY is exactly $1 or under it, from a bounded system-wide
# `lsof -a -d cwd` scan (never the recursive +D file-tree walk). Never $$.
# Empty output when nothing matches; failure means no safe result was established.
pids_with_cwd_under() {  # <dir>
  local dir=$1 out pid path line
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  dir=$(cd "$dir" && pwd -P) || return 1
  out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  pid=
  while IFS= read -r line; do
    case "$line" in
      p*)
        pid=${line#p}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        ;;
      fcwd) [ -n "$pid" ] || return 1 ;;
      n*)
        [ -n "$pid" ] || return 1
        path=${line#n}
        case "$path" in
          "$dir"|"$dir"/*)
            [ -n "$pid" ] && [ "$pid" != "$$" ] && printf '%s\t%s\n' "$pid" "$path"
            ;;
        esac
        ;;
      '') ;;
      *) return 1 ;;
    esac
  done <<EOF
$out
EOF
}

task_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(fm_nm_trim "$value")
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

task_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(task_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

task_pid_list_contains() {  # <pid-list> <pid>
  printf '%s\n' "$1" | grep -Fxq "$2"
}

# Canonical form of <path> even when its tail no longer exists: the nearest
# existing ancestor is resolved and the missing components are kept verbatim.
task_canonical_path() {  # <path>
  local dir=$1 rest=""
  while [ ! -d "$dir" ]; do
    case "$dir" in /?*) ;; *) return 1 ;; esac
    rest=/${dir##*/}$rest
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  dir=$(CDPATH='' cd -- "$dir" && pwd -P) || return 1
  printf '%s%s\n' "${dir%/}" "$rest"
}

# Prints a discovered nested worktree lane beneath <root> that holds <path>.
# A lane in TASK_REGISTERED_LANES wins even when its directory or .git is gone;
# otherwise git classifies the nearest existing directory within <root>.
# A missing root returns empty after the registry check, supporting absent-copy
# recovery. Empty output is not proof of process custody.
# Fails when git cannot classify <path> under a git <root>.
task_nested_lane_for_path() {  # <root> <path>
  local root=$1 path=$2 dir lane top git_dir common_dir
  [ -e "$path" ] || path=${path% (deleted)}
  for lane in ${TASK_REGISTERED_LANES[@]+"${TASK_REGISTERED_LANES[@]}"}; do
    case "$path" in "$lane"|"$lane"/*) printf '%s\n' "$lane"; return 0 ;; esac
  done
  dir=$path
  while [ ! -d "$dir" ]; do
    case "$dir" in "$root"/*) dir=${dir%/*} ;; "$root") return 0 ;; *) return 1 ;; esac
  done
  while :; do
    if ! top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
      git -C "$root" rev-parse --show-toplevel >/dev/null 2>&1 && return 1
      return 0
    fi
    top=$(CDPATH='' cd -- "$top" && pwd -P) || return 1
    case "$top" in "$root"/*) ;; *) return 0 ;; esac
    git_dir=$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    common_dir=$(git -C "$top" rev-parse --git-common-dir 2>/dev/null) || return 1
    case "$common_dir" in /*) ;; *) common_dir=$top/$common_dir ;; esac
    git_dir=$(CDPATH='' cd -- "$git_dir" && pwd -P) || return 1
    common_dir=$(CDPATH='' cd -- "$common_dir" && pwd -P) || return 1
    if [ "$git_dir" != "$common_dir" ]; then
      printf '%s\n' "$top"
      return 0
    fi
    dir=${top%/*}
  done
}

# Adds one candidate registry source to TASK_LANE_SOURCES (read and written by
# task_registered_lanes_under_roots, which resets it) when it is a git work tree.
# Each distinct path is judged and read once: a fleet's task records name the
# same few project clones hundreds of times, and each repeat cost two git
# processes here and one more full registry read below, which made a single
# scan run for over a minute under a loaded fleet.
task_lane_source_add() {  # <path>
  case "$TASK_LANE_SOURCES_SEEN" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  TASK_LANE_SOURCES_SEEN="$TASK_LANE_SOURCES_SEEN$1"$'\n'
  git -C "$1" rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  TASK_LANE_SOURCES+=("$1")
}

# Refresh TASK_REGISTERED_LANES: every worktree, including missing or prunable
# entries, registered strictly beneath a scan root by the git-backed recorded
# project, scan roots, or available task projects in reachable local Firstmate
# states. Project registries remain sources when the scan root is missing; a
# recorded project that is gone or not a git repository has no registry to read.
# Every distinct source registry is read once per call.
task_registered_lanes_under_roots() {  # <canonical-root>...
  local root src registry line lane state_dir meta project
  TASK_REGISTERED_LANES=()
  TASK_LANE_SOURCES=()
  TASK_LANE_SOURCES_SEEN=$'\n'
  for root in "$@"; do
    task_lane_source_add "$root"
  done
  [ -z "$PROJ" ] || task_lane_source_add "$PROJ"
  fm_local_firstmate_state_dirs "$STATE" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; nothing was changed" >&2
    return 1
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state_dir"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      project=$(fm_meta_get "$meta" project)
      [ -n "$project" ] || continue
      task_lane_source_add "$project"
    done
  done
  for src in ${TASK_LANE_SOURCES[@]+"${TASK_LANE_SOURCES[@]}"}; do
    if ! registry=$(git -C "$src" worktree list --porcelain 2>/dev/null); then
      TASK_PIDS_FAILED_DIR=$src
      TASK_PIDS_ERROR="worktree registration could not be read"
      return 1
    fi
    while IFS= read -r line; do
      case "$line" in worktree\ *) ;; *) continue ;; esac
      if ! lane=$(task_canonical_path "${line#worktree }"); then
        TASK_PIDS_FAILED_DIR=${line#worktree }
        TASK_PIDS_ERROR="registered worktree path could not be resolved"
        return 1
      fi
      for root in "$@"; do
        case "$lane" in "$root"/*) TASK_REGISTERED_LANES+=("$lane") ;; esac
      done
    done <<EOF
$registry
EOF
  done
}

task_pids_under_roots() {  # <dir>...
  TASK_PIDS=
  TASK_PIDS_FAILED_DIR=
  TASK_PIDS_ERROR="lsof failed"
  TASK_PID_CWDS=()
  TASK_SCAN_PIDS=()
  local dir dir_matches pid path lane identity root pids=""
  local -a scan_roots
  scan_roots=()
  for dir in "$@"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    if ! path=$(CDPATH='' cd -- "$dir" && pwd -P); then
      TASK_PIDS_FAILED_DIR=$dir
      TASK_PIDS_ERROR="scan root could not be resolved"
      return 1
    fi
    scan_roots+=("$path")
  done
  [ "${#scan_roots[@]}" -gt 0 ] || return 0
  if ! command -v lsof >/dev/null 2>&1; then
    TASK_PIDS_FAILED_DIR=${scan_roots[0]}
    TASK_PIDS_ERROR="lsof is unavailable, so no signal target can be audited"
    return 1
  fi
  task_registered_lanes_under_roots "${scan_roots[@]}" || return 1
  for dir in "${scan_roots[@]}"; do
    if ! dir_matches=$(pids_with_cwd_under "$dir"); then
      TASK_PIDS_FAILED_DIR=$dir
      return 1
    fi
    while IFS=$'\t' read -r pid path; do
      [ -n "$pid" ] || continue
      if ! lane=$(task_nested_lane_for_path "$dir" "$path"); then
        TASK_PIDS_FAILED_DIR=$path
        TASK_PIDS_ERROR="git could not classify the worktree holding process $pid's cwd"
        return 1
      fi
      [ "$lane" != "$dir" ] || lane=
      for root in "${scan_roots[@]}"; do
        [ -z "$lane" ] || [ "$lane" != "$root" ] || continue 2
      done
      if [ -n "$lane" ]; then
        identity=$(task_process_identity "$pid") || identity="identity unavailable"
        echo "REFUSED: process $pid ($identity) matched path $path inside registered nested worktree lane $lane, whose ownership by $ID is not proven; preserving it and task $ID without signalling." >&2
        TASK_PIDS_FAILED_DIR=$lane
        TASK_PIDS_ERROR="registered nested worktree lane holds process $pid"
        return 1
      fi
      if [ "$path" != "$dir" ]; then
        identity=$(task_process_identity "$pid") || identity="identity unavailable"
        echo "REFUSED: process $pid ($identity) matched path $path beneath scan root $dir, whose ownership by $ID is not proven; preserving it and task $ID without signalling." >&2
        TASK_PIDS_FAILED_DIR=$path
        TASK_PIDS_ERROR="descendant cwd holds process $pid without proven task custody"
        return 1
      fi
      TASK_SCAN_PIDS+=("$pid")
      TASK_PID_CWDS+=("$path")
      pids="$pids
$pid"
    done <<EOF
$dir_matches
EOF
  done
  TASK_PIDS=$(printf '%s\n' "$pids" | grep -E '^[0-9]+$' | sort -un || true)
}

task_record_process_signal() {  # <pid> <birth-identity> <signal>
  local pid=$1 identity=$2 signal=$3 command start cwd="" i record epoch current
  record="$STATE/$ID.teardown-processes"
  for i in "${!TASK_SCAN_PIDS[@]}"; do
    [ "${TASK_SCAN_PIDS[$i]}" != "$pid" ] || { cwd=${TASK_PID_CWDS[$i]}; break; }
  done
  [ -n "$cwd" ] || return 1
  if ! command=$(LC_ALL=C ps -ww -p "$pid" -o command= 2>/dev/null) \
     || ! start=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) \
     || [ -z "$command" ] || [ -z "$start" ]; then
    if current=$(task_process_identity "$pid") && [ "$current" != "$identity" ]; then
      return 2
    fi
    if perl -MErrno=ESRCH -e 'exit((kill(0, $ARGV[0]) == 0 && $! == ESRCH) ? 0 : 1)' -- "$pid"; then
      return 2
    fi
    return 1
  fi
  epoch=$(date +%s) || return 1
  fm_backlog_record_parent_authorized "$record" "teardown process audit" "$STATE" || return 1
  if [ -e "$record" ] || [ -L "$record" ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
  fi
  (umask 077; printf '%q\t%q\t%q\t%q\t%q\t%q\t%q\t%q\n' \
    "$epoch" "$signal" "$pid" "$identity" "$command" \
    "$start" "$cwd" "$cwd" >> "$record") || return 1
}

# Fix 2 in the script header owns exact-root custody and pre-signal auditing.
reap_task_worktree_processes() {  # <label> <dir>...
  local label=$1 pids pid identity current_pids i pass=1 max_passes=3
  local -a tracked_pids tracked_identities remaining_pids remaining_identities
  shift
  while [ "$pass" -le "$max_passes" ]; do
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID ($TASK_PIDS_ERROR); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    pids=$TASK_PIDS
    [ -n "$pids" ] || return 0
    tracked_pids=()
    tracked_identities=()
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      if ! identity=$(task_process_identity "$pid"); then
        if ! task_pids_under_roots "$@"; then
          echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID ($TASK_PIDS_ERROR); preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        if task_pid_list_contains "$TASK_PIDS" "$pid"; then
          echo "REFUSED: cannot verify leaked process $pid identity for $ID; preserving the worktree/tasktmp for manual inspection or retry." >&2
          return 1
        fi
        continue
      fi
      tracked_pids+=("$pid")
      tracked_identities+=("$identity")
    done <<EOF
$pids
EOF
    if [ "${#tracked_pids[@]}" -eq 0 ]; then
      pass=$((pass + 1))
      continue
    fi
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID ($TASK_PIDS_ERROR); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    echo "teardown: reaping leaked $label process(es) for $ID: $(printf '%s' "$pids" | tr '\n' ' ')" >&2
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        if task_record_process_signal "$pid" "$identity" TERM; then
          :
        else
          [ "$?" -ne 2 ] || continue
          echo "REFUSED: cannot durably record leaked process $pid identity for $ID; preserving the worktree/tasktmp without signalling it." >&2
          return 1
        fi
        task_process_identity_matches "$pid" "$identity" || continue
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    sleep 1
    if ! task_pids_under_roots "$@"; then
      echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID ($TASK_PIDS_ERROR); preserving the worktree/tasktmp for manual inspection or retry." >&2
      return 1
    fi
    current_pids=$TASK_PIDS
    remaining_pids=()
    remaining_identities=()
    for i in "${!tracked_pids[@]}"; do
      pid=${tracked_pids[$i]}
      identity=${tracked_identities[$i]}
      if task_pid_list_contains "$current_pids" "$pid" \
         && task_process_identity_matches "$pid" "$identity"; then
        remaining_pids+=("$pid")
        remaining_identities+=("$identity")
      fi
    done
    if [ "${#remaining_pids[@]}" -gt 0 ]; then
      echo "teardown: force-killing leaked $label process(es) for $ID: ${remaining_pids[*]}" >&2
      if ! task_pids_under_roots "$@"; then
        echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID ($TASK_PIDS_ERROR); preserving the worktree/tasktmp for manual inspection or retry." >&2
        return 1
      fi
      current_pids=$TASK_PIDS
      for i in "${!remaining_pids[@]}"; do
        pid=${remaining_pids[$i]}
        identity=${remaining_identities[$i]}
        if task_pid_list_contains "$current_pids" "$pid" \
           && task_process_identity_matches "$pid" "$identity"; then
          if task_record_process_signal "$pid" "$identity" KILL; then
            :
          else
            [ "$?" -ne 2 ] || continue
            echo "REFUSED: cannot durably record leaked process $pid identity for $ID; preserving the worktree/tasktmp without force-killing it." >&2
            return 1
          fi
          task_process_identity_matches "$pid" "$identity" || continue
          kill -KILL "$pid" 2>/dev/null || true
        fi
      done
    fi
    pass=$((pass + 1))
  done
  if ! task_pids_under_roots "$@"; then
    echo "REFUSED: cannot determine leaked processes under ${TASK_PIDS_FAILED_DIR:-<missing>} for $ID ($TASK_PIDS_ERROR); preserving the worktree/tasktmp for manual inspection or retry." >&2
    return 1
  fi
  [ -z "$TASK_PIDS" ] && return 0
  echo "REFUSED: leaked $label processes for $ID remain after $max_passes reap attempts; preserving the worktree/tasktmp for manual inspection or retry." >&2
  return 1
}

# A Docker compose working directory inside a nested lane (a linked worktree
# under the task's root) belongs to that lane's task, not to this one. A path
# that cannot be classified is left alone.
fm_task_docker_path_excluded() {  # <root> <path>
  local lane
  [ "$1" != "$2" ] || return 1
  lane=$(task_nested_lane_for_path "$1" "$2") || return 0
  [ -n "$lane" ]
}

# Gathers what bin/fm-task-docker-lib.sh needs from this home and every local
# home - the other live task ids (a longer one claims its own prefixed names,
# the same id elsewhere makes the id ambiguous) and the task's path roots - then
# lets it remove the stacks this task owns.
teardown_docker_stacks() {
  local ID=$1 META=$2 STATE=$3 reassigned=$4 PROJ WT
  local state_dir other other_id siblings="" ambiguous=0 canon protected=""
  local -a roots
  roots=()
  command -v docker >/dev/null 2>&1 || return 0
  WT=$(meta_value "$META" worktree)
  PROJ=$(meta_value "$META" project)
  fm_local_firstmate_state_dirs "$STATE" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; nothing was changed" >&2
    return 1
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other in "$state_dir"/*.meta; do
      [ -f "$other" ] || continue
      [ "${other##*/}" = "${META##*/}" ] && [ "$other" -ef "$META" ] && continue
      other_id=$(basename "$other" .meta)
      [ "$other_id" != "$ID" ] || ambiguous=1
      siblings="$siblings $other_id"
    done
  done
  if [ "$(meta_value "$META" kind)" != secondmate ] && [ "$reassigned" != 1 ] && [ -n "$WT" ]; then
    if canon=$(task_canonical_path "$WT" 2>/dev/null); then
      roots+=("$canon")
    fi
  fi
  if [ "${#roots[@]}" -gt 0 ]; then
    TASK_PIDS_FAILED_DIR=
    TASK_PIDS_ERROR=
    if ! task_registered_lanes_under_roots "${roots[@]}"; then
      echo "error: cannot establish nested worktree lanes for $ID${TASK_PIDS_ERROR:+ ($TASK_PIDS_ERROR: $TASK_PIDS_FAILED_DIR)}; retaining task records" >&2
      return 1
    fi
  fi
  if [ -n "$PROJ" ] && { [ -e "$PROJ/supabase/config.toml" ] || [ -L "$PROJ/supabase/config.toml" ]; }; then
    protected=$(python3 - "$PROJ/supabase/config.toml" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as config:
    project = tomllib.load(config).get("project_id")
if not isinstance(project, str) or not project or any(c.isspace() for c in project):
    raise SystemExit("invalid Supabase project_id")
print(project)
PY
    ) || {
      echo "error: cannot identify the shared Supabase stack for $ID; retaining task records" >&2
      return 1
    }
  fi
  fm_task_docker_cleanup "$ID" "$siblings" "$ambiguous" "$protected" "$META" ${roots[@]+"${roots[@]}"}
}


# Fix 3 (see script header): "label<TAB>root" for a no-mistakes daemon launch
# agent plist, from its Label and the `--root` of its `daemon run` arguments.
# Fails for anything that is not that exact, parsable shape.
nm_launch_agent_fields() {  # <plist>
  perl -e '
    local $/;
    my $x = <STDIN>;
    my ($label) = $x =~ m{<key>Label</key>\s*<string>([^<]*)</string>} or exit 1;
    $x =~ m{<key>ProgramArguments</key>\s*<array>(.*?)</array>}s or exit 1;
    my @a = $1 =~ m{<string>([^<]*)</string>}g;
    my $root;
    for my $i (0 .. $#a - 3) {
      next unless $a[$i] eq "daemon" && $a[$i + 1] eq "run" && $a[$i + 2] eq "--root";
      $root = $a[$i + 3];
      last;
    }
    defined $root && length $root or exit 1;
    my %e = (amp => "&", lt => "<", gt => ">", quot => "\"", apos => "\x27");
    for ($label, $root) { s/&(amp|lt|gt|quot|apos);/$e{$1}/g }
    exit 1 if $label =~ /[^A-Za-z0-9._-]/ || $root =~ /[\t\n\r]/;
    print "$label\t$root\n";
  ' < "$1"
}

# Fix 3: apply the script header's private-agent ownership and retirement
# contract before process reaping.
retire_task_private_nm_launch_agents() {  # <worktree>
  local wt=$1 dir plist label root canon_wt canon_root fields uid backup dest rc attempt lane
  dir=${FM_LAUNCH_AGENTS_DIR:-${HOME:-}/Library/LaunchAgents}
  [ -d "$dir" ] || return 0
  canon_wt=$(task_canonical_path "$wt") || return 0
  if ! task_registered_lanes_under_roots "$canon_wt"; then
    echo "REFUSED: cannot establish nested worktree ownership under $canon_wt; preserving the launch agents and task $ID." >&2
    return 1
  fi
  uid=$(id -u)
  backup="$DATA/$ID/launchagent-backup"
  for plist in "$dir"/com.kunchenguid.no-mistakes.daemon.*.plist; do
    [ -f "$plist" ] || continue
    if [ -L "$plist" ] || ! fields=$(nm_launch_agent_fields "$plist"); then
      echo "teardown: leaving unreadable no-mistakes launch agent $plist as found; its root cannot be proven to be $ID's" >&2
      continue
    fi
    label=${fields%%$'\t'*}
    root=${fields#*$'\t'}
    [ "$plist" = "$dir/$label.plist" ] || continue
    case "$root" in /*) ;; *) continue ;; esac
    canon_root=$(perl -MCwd=abs_path -e '
      my $path = "/";
      for my $part (split m{/+}, $ARGV[0]) {
        next if $part eq "" || $part eq ".";
        if ($part eq "..") {
          $path =~ s{/[^/]+$}{};
          $path = "/" if $path eq "";
          next;
        }
        my $next = ($path eq "/" ? "" : $path) . "/$part";
        if (-d $next) {
          $path = abs_path($next);
          defined $path or exit 1;
        } else {
          exit 1 if -e $next || -l $next;
          $path = $next;
        }
      }
      print "$path\n";
    ' "$root") || continue
    case "$canon_root" in "$canon_wt"|"$canon_wt"/*) ;; *) continue ;; esac
    if ! lane=$(task_nested_lane_for_path "$canon_wt" "$canon_root"); then
      echo "REFUSED: cannot classify the worktree holding no-mistakes launch agent $label's root $canon_root; preserving the launch agent and task $ID." >&2
      return 1
    fi
    [ -z "$lane" ] || continue
    if ! command -v launchctl >/dev/null 2>&1; then
      echo "REFUSED: no-mistakes launch agent $label is rooted in $ID's copy but launchctl is unavailable, so it cannot be unloaded; preserving the worktree and $plist." >&2
      return 1
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      rc=0
      launchctl print "gui/$uid/$label" >/dev/null 2>&1 || rc=$?
      case "$rc" in
        113) break ;;
        0) ;;
        *)
          echo "REFUSED: cannot tell whether no-mistakes launch agent $label (rooted in $ID's copy) is loaded (launchctl print exited $rc); preserving the worktree and $plist." >&2
          return 1
          ;;
      esac
      if [ "$attempt" = 1 ]; then
        launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
      else
        sleep 0.25
      fi
      rc=0
    done
    if [ "$rc" != 113 ]; then
      echo "REFUSED: no-mistakes launch agent $label (rooted in $ID's copy) is still loaded after launchctl bootout; preserving the worktree and $plist." >&2
      return 1
    fi
    dest="$backup/$label.plist"
    [ ! -e "$dest" ] || dest="$dest.$(date +%s)"
    if ! mkdir -p "$backup" || ! mv -- "$plist" "$dest"; then
      echo "REFUSED: could not archive no-mistakes launch agent plist $plist to $dest; preserving the worktree." >&2
      return 1
    fi
    echo "teardown: retired task-private no-mistakes launch agent $label (root $root); plist archived to $dest" >&2
  done
}


# The task's own live slot, canonicalized, or empty when this record has no slot
# to release (a secondmate home, a record with no worktree=, or a path that is
# already gone). Every slot-ownership check below is scoped to that value, so a
# record with nothing live to return skips them rather than refusing.
teardown_live_slot_path() {
  [ "$KIND" != secondmate ] || return 1
  fm_treehouse_pool_slot "$PROJ" "$WT" || return 1
  fm_task_copy_canonical_dir "$WT"
}


require_exclusive_worktree_slot_record() {
  local record_meta=$1 record_id=$2 record_state=$3 worktree=$4 slot
  slot=$(fm_task_copy_canonical_dir "$worktree") || return 0
  # A reassigned slot is untouched: refusing its scan would strand the stale
  # record and block the claimant's own teardown.
  fm_treehouse_slot_owner_state "$slot" "$record_id"
  [ "$FM_TREEHOUSE_SLOT_OWNER" != other ] || return 0
  require_cleanup_copy_clearance "$record_meta" "$record_id" "$record_state" "$slot" 1 slot
}

require_exclusive_task_worktree_slot() {
  local slot
  slot=$(teardown_live_slot_path) || return 0
  require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$slot"
}

require_cleanup_copy_clearance() {
  local record_meta=$1 record_id=$2 record_state=$3 target=$4 allow_current=${5:-0} target_kind=${6:-}
  local canonical state_dir other_meta line field copy copy_real copy_common retiring i owner_home keep_current overlaps own skipped
  canonical=$(fm_task_copy_canonical_dir "$target") || return 0
  # A retiring secondmate's own registered home that is already gone holds
  # nothing to lose, so it alone is not a reason to refuse; every other home
  # the walk cannot prove still refuses.
  fm_local_firstmate_state_dirs "$record_state" tolerant
  for skipped in ${FM_LOCAL_FIRSTMATE_SKIPPED[@]+"${FM_LOCAL_FIRSTMATE_SKIPPED[@]}"}; do
    if [ "$KIND" = secondmate ] && [ -n "${HOME_PATH:-$WT}" ] && [ ! -e "${HOME_PATH:-$WT}" ] \
       && [ ! -L "${HOME_PATH:-$WT}" ] \
       && [ "$skipped" = "registered local Firstmate home is unavailable: ${HOME_PATH:-$WT}" ]; then
      continue
    fi
    echo "REFUSED: $skipped; nothing was changed" >&2
    return 1
  done
  for state_dir in "${DESCENDANT_TASK_STATES[@]+"${DESCENDANT_TASK_STATES[@]}"}"; do
    FM_LOCAL_FIRSTMATE_STATES+=("$state_dir")
  done
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other_meta in "$state_dir"/*.meta; do
      [ -f "$other_meta" ] && [ ! -L "$other_meta" ] || continue
      retiring=0
      own=0
      if [ "${other_meta##*/}" = "${record_meta##*/}" ] && [ "$other_meta" -ef "$record_meta" ]; then
        own=1
      fi
      if [ "$allow_current" != 0 ]; then
        if [ "$own" = 1 ]; then
          retiring=1
        elif [ "$KIND" = secondmate ]; then
          if [ "${other_meta##*/}" = "${META##*/}" ] && [ "$other_meta" -ef "$META" ]; then
            retiring=1
          fi
          for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
            if [ "${other_meta##*/}" = "${DESCENDANT_TASK_IDS[$i]}.meta" ] \
               && [ "$other_meta" -ef "${DESCENDANT_TASK_STATES[$i]}/${DESCENDANT_TASK_IDS[$i]}.meta" ]; then
              if [ "$allow_current" = home ]; then
                retiring=1
              elif [ "$(fm_meta_get "$other_meta" kind)" = secondmate ]; then
                owner_home=$(fm_meta_get "$other_meta" home)
                [ -n "$owner_home" ] || owner_home=$(fm_meta_get "$other_meta" worktree)
                case "$record_state" in "$owner_home"/state|"$owner_home"/*/state) retiring=1 ;; esac
              fi
            fi
          done
        fi
      fi
      keep_current=0
      if [ "$retiring" = 1 ] && [ "$allow_current" = home ] \
         && teardown_preserves_reassociated_copy "$other_meta" \
           "$(fm_meta_get "$other_meta" kind)" "$(fm_backend_of_meta "$other_meta")" \
           "$(fm_meta_get "$other_meta" project)" "$(fm_meta_get "$other_meta" worktree)"; then
        keep_current=1
      fi
      while IFS= read -r line || [ -n "$line" ]; do
        field=${line%% *}
        if [ "$retiring" = 1 ] && [ "$field" != prior_worktree ]; then
          [ "$keep_current" = 1 ] || continue
        fi
        # The task's own prior copies never refuse its own slot cleanup here:
        # teardown_nested_slot proves each one a return would
        # sweep away, and a cleanup that returns nothing touches none of them.
        if [ "$own" = 1 ] && [ "$field" = prior_worktree ] \
           && [ "$target_kind" = slot ] && [ "$record_meta" = "$META" ]; then
          continue
        fi
        copy=${line#* }
        copy_real=$(fm_task_copy_canonical_dir "$copy") || continue
        # Returning a pool slot (target_kind=slot) refuses another ordinary
        # task's current worktree= only on an exact path match, as origin/main
        # does: the return resets that one slot and never removes a copy that
        # merely sits inside it. Every other cleanup target is removed
        # outright; home=, prior_worktree= and a secondmate's worktree= (its
        # home) name custody no teardown may sweep away, so they keep the
        # component-aware overlap.
        overlaps=0
        if [ "$target_kind" = slot ] && [ "$field" = worktree ] && [ "$retiring" = 0 ] \
           && [ "$(fm_meta_get "$other_meta" kind)" != secondmate ] && [ "$own" = 0 ]; then
          [ "$canonical" != "$copy_real" ] || overlaps=1
        elif fm_task_copy_paths_overlap "$canonical" "$copy_real"; then
          overlaps=1
        fi
        # A record reassociated off this slot root into its own copy nested in
        # it no longer owns the root, so naming it as prior_worktree= does not
        # keep this task from removing its own copy (the proof is
        # fm_task_copy_prior_root_released's).
        if [ "$overlaps" = 1 ] && [ "$field" = prior_worktree ] && [ "$own" = 0 ] \
           && [ "$KIND" != secondmate ] && [ "$record_meta" = "$META" ] \
           && [ "$canonical" = "$(fm_task_copy_canonical_dir "$WT" 2>/dev/null)" ] \
           && fm_task_copy_prior_root_released "$other_meta" "$copy_real" "$canonical" "$record_meta" \
             "${FM_LOCAL_FIRSTMATE_STATES[@]}"; then
          overlaps=0
        fi
        if [ "$overlaps" = 1 ] \
           && ! fm_task_copy_ancestor_current "$other_meta" "$record_state" "$field" "$copy_real" "$canonical"; then
          echo "REFUSED: task $record_id's cleanup target $canonical is also task $(basename "$other_meta" .meta)'s recorded $field ($copy_real); preserved $field custody overlaps it, so nothing was changed - not even with --force." >&2
          return 1
        fi
        if ! copy_common=$(git -C "$copy_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
           || ! copy_common=$(fm_task_copy_canonical_dir "$copy_common"); then
          continue
        fi
        fm_task_copy_paths_overlap "$canonical" "$copy_common" || continue
        echo "REFUSED: task $record_id's cleanup target $canonical overlaps Git common-dir storage $copy_common for task $(basename "$other_meta" .meta)'s recorded $field ($copy_real); preserved $field custody overlaps it, so nothing was changed - not even with --force." >&2
        return 1
      done < <(fm_task_copy_record_paths "$other_meta")
    done
  done
  return 0
}

# Positive slot ownership, read from the claim the task that took the slot wrote
# into the slot itself (bin/fm-wake-lib.sh owns the claim and its states).
#
# For a slot this task still claims, or one with no claim, the record scan above
# proves that no OTHER task record names it. It cannot prove that THIS record is
# not the stale one, because the task that took the slot next may leave no record
# this scan can reach: its own worker may have exited and its record been cleaned
# up, or it may belong to a home this machine does not register. The claim closes that gap from the other side - it names the
# task that actually took the slot, and it is written under the same project lock
# that allocates it - so a claim naming another task is proof the slot was
# reassigned after this record was written.
#
# A claim naming another task does not refuse: it means the slot is no longer
# this task's, so the record's own cleanup proceeds and every slot step is
# skipped (see the script header for why refusing would strand the record and
# why skipping discards nothing). Returns TEARDOWN_SLOT_REASSIGNED_RC for that
# state so each caller gates its slot steps on one determination; the claimant
# stays in FM_TREEHOUSE_SLOT_OWNER_ID and FM_TREEHOUSE_SLOT_OWNER_HOME.
#
# An absent claim proceeds as the slot's owner: a slot taken before claims
# existed, or already returned to the pool, carries none, and refusing those
# would strand every task in flight across the change for no evidence at all.
# Those keep exactly the record-scan protection they had before.
TEARDOWN_SLOT_REASSIGNED_RC=3
require_owned_worktree_slot_record() {  # <task-id> <worktree>
  local record_id=$1 worktree=$2 marker
  fm_treehouse_slot_owner_state "$worktree" "$record_id"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent) return 0 ;;
    other)
      echo "warning: task $record_id's recorded worktree $worktree was reassigned to task $FM_TREEHOUSE_SLOT_OWNER_ID${FM_TREEHOUSE_SLOT_OWNER_HOME:+ (home $FM_TREEHOUSE_SLOT_OWNER_HOME)}, which claimed that pool slot after this record was written; that slot is no longer $record_id's, so its processes, copy, and claim are left untouched and only $record_id's own cleanup runs." >&2
      return "$TEARDOWN_SLOT_REASSIGNED_RC"
      ;;
  esac
  marker=$(fm_treehouse_slot_owner_marker "$worktree" 2>/dev/null) || marker="beside $worktree"
  echo "REFUSED: task $record_id's recorded worktree $worktree carries a slot-owner claim that cannot be read, so the slot cannot be proved to still be this task's; nothing was changed - not even with --force." >&2
  echo "Inspect or repair the claim file at $marker (task= and home= lines), then re-run teardown." >&2
  return 1
}

TEARDOWN_SLOT_REASSIGNED=0
TEARDOWN_SLOT_REASSIGNED_TO=
TEARDOWN_SLOT_REASSIGNED_HOME=

# The slot claim answers two questions that must stay separate. This one is
# whether this teardown may still administer the pool slot enclosing a nested
# current copy: when it may not, nothing in that slot is reserved, returned or
# released, and the early proof's derivations are redone from the record as if
# the claim had never named this task. Whether the copy at WT and its runtime
# are this task's own is the other, teardown_owns_worktree.
teardown_release_enclosing_slot() {
  local line
  TEARDOWN_RESERVED_SLOT=
  TEARDOWN_ENCLOSING_SLOT=$TEARDOWN_RECORD_SLOT
  TEARDOWN_RETURN_SLOT=
  TEARDOWN_NESTED_COPIES=()
  TEARDOWN_PROOF_COPIES=()
  TEARDOWN_PRIOR_COPIES=()
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      prior_worktree=?*) TEARDOWN_PRIOR_COPIES+=("${line#prior_worktree=}") ;;
    esac
  done < "$META"
  teardown_nested_slot prove
}

require_owned_task_worktree_slot() {
  local slot=${1:-} rc=0
  if [ -z "$slot" ]; then
    slot=$(teardown_live_slot_path) || return 0
  fi
  require_owned_worktree_slot_record "$ID" "$slot" || rc=$?
  case "$rc" in
    0) return 0 ;;
    "$TEARDOWN_SLOT_REASSIGNED_RC")
      if teardown_live_slot_path >/dev/null; then
        TEARDOWN_SLOT_REASSIGNED=1
        TEARDOWN_SLOT_REASSIGNED_TO=$FM_TREEHOUSE_SLOT_OWNER_ID
        TEARDOWN_SLOT_REASSIGNED_HOME=$FM_TREEHOUSE_SLOT_OWNER_HOME
        TEARDOWN_RESERVED_SLOT=
      else
        teardown_release_enclosing_slot || return 1
      fi
      return 0
      ;;
  esac
  return 1
}

# A non-forcing cleanup sharing a slot with another ordinary root record
# retires only this record, using the reassigned-slot path. This record may
# name the root or a nested copy. Nothing under the slot is inspected for
# disposal or touched; completion is proved independently below. A root record
# whose claim already names another task keeps require_owned_task_worktree_slot's
# determination and never enters this route.
TEARDOWN_SLOT_SHARED=0
TEARDOWN_SHARED_SLOT=
require_shared_task_worktree_slot() {
  local slot state_dir other_meta copy kind marker holder i last
  local -a sharers=() sharer_metas=()
  [ "$FORCE" != --force ] || return 0
  teardown_owns_worktree || return 0
  slot=$(teardown_live_slot_path) || {
    [ "$KIND" != secondmate ] || return 0
    copy=$(fm_task_copy_canonical_dir "$WT") || return 0
    slot=$(fm_task_copy_enclosing_pool_slot "$PROJ" "$copy") || return 0
  }
  fm_local_firstmate_state_dirs "$STATE" || {
    echo "REFUSED: $FM_LOCAL_FIRSTMATE_ERROR; nothing was changed" >&2
    return 1
  }
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other_meta in "$state_dir"/*.meta; do
      [ -f "$other_meta" ] && [ ! -L "$other_meta" ] || continue
      [ "${other_meta##*/}" = "${META##*/}" ] && [ "$other_meta" -ef "$META" ] && continue
      kind=$(fm_meta_get "$other_meta" kind)
      case "$kind" in ''|ship|scout) ;; *) continue ;; esac
      copy=$(fm_task_copy_canonical_dir "$(fm_meta_get "$other_meta" worktree)") || continue
      [ "$copy" = "$slot" ] || continue
      sharers+=("$(basename "$other_meta" .meta)")
      sharer_metas+=("$other_meta")
    done
  done
  [ "${#sharers[@]}" -gt 0 ] || return 0
  fm_treehouse_slot_owner_state "$slot" "$ID"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    mine|absent)
      # Until reassociation, root-only records do not trigger the allocation
      # guard for nested current copies. Keep Treehouse itself from handing
      # out this slot throughout that interval, not just during our lock.
      if ! fm_task_copy_pool_slot_held "$slot"; then
        holder='<remaining-task>'
        [ "${#sharers[@]}" -ne 1 ] || holder="'${sharers[0]}'"
        echo "REFUSED: shared pool slot $slot $FM_TASK_COPY_SLOT_REASON; prove a durable lease before retiring its claimant's record, so another allocation cannot reset the remaining copies before reassociation. Nothing was changed." >&2
        case "$FM_TASK_COPY_SLOT_STATE" in
          unleased)
            echo "Hold it in place without touching its contents: (cd '$PROJ' && treehouse lease '$FM_TASK_COPY_SLOT_NAME' --lease-holder $holder)" >&2
            ;;
          recovered)
            echo "Treehouse 2.3.1-fm has no supported non-forcing route to replace this recovered-state lease: treehouse lease refuses an already-leased slot. Do not return it to change the lease while copies remain." >&2
            echo "Inspect with (cd '$PROJ' && treehouse status); report the slot $slot, state file $FM_TASK_COPY_POOL_STATE_FILE, recovered lease holder, and treehouse --version to firstmate for operator recovery. Keep all task records and copies in place." >&2
            ;;
          *)
            echo "Inspect its lease with: (cd '$PROJ' && treehouse status); report why its durable lease cannot be proved before attempting recovery." >&2
            ;;
        esac
        if [ "${#sharers[@]}" -ne 1 ]; then
          echo "Several other root records name this slot; select the live one whose work stays in it as <remaining-task>. Each candidate's last recorded status:" >&2
          for ((i=0; i < ${#sharers[@]}; i++)); do
            last=
            [ ! -f "${sharer_metas[$i]%.meta}.status" ] || last=$(tail -1 "${sharer_metas[$i]%.meta}.status" 2>/dev/null)
            echo "  ${sharers[$i]}: ${last:-(no status recorded)}" >&2
          done
        fi
        return 1
      fi
      TEARDOWN_SLOT_REASSIGNED_TO=${sharers[*]}
      TEARDOWN_SLOT_REASSIGNED_HOME=
      ;;
    other)
      TEARDOWN_SLOT_REASSIGNED_TO=$FM_TREEHOUSE_SLOT_OWNER_ID
      TEARDOWN_SLOT_REASSIGNED_HOME=$FM_TREEHOUSE_SLOT_OWNER_HOME
      ;;
    *)
      marker=$(fm_treehouse_slot_owner_marker "$slot" 2>/dev/null) || marker="beside $slot"
      echo "REFUSED: shared pool slot $slot carries an unreadable owner claim at $marker; nothing was changed." >&2
      return 1
      ;;
  esac
  TEARDOWN_SHARED_SLOT=$slot
  TEARDOWN_SLOT_SHARED=1
  TEARDOWN_SLOT_REASSIGNED=1
  echo "notice: task $ID shares recorded pool slot $slot with task $TEARDOWN_SLOT_REASSIGNED_TO; only the finished task's endpoint and records will retire, and every copy in the slot will stay untouched." >&2
  return 0
}

# Whether the copy at WT, and the runtime inside it, are this task's own. A
# slot claim decides it only when WT is that pool slot itself, or when another
# record shares the slot; a worktree nested in a slot another task claims stays
# this task's own and loses only its slot steps (teardown_release_enclosing_slot).
teardown_owns_worktree() {
  [ "$TEARDOWN_SLOT_REASSIGNED" != 1 ]
}

# A pool return resets the whole slot, so it sweeps away every copy of this
# task that lies inside the slot. Two reassociated shapes put one there: a
# current copy nested inside the slot the task still claims (the slot is then
# its prior copy), and a prior copy nested inside the slot that is its current
# copy. Neither refuses outright, because the record could then never be
# retired. Instead each own copy the return would sweep, other than the current
# copy the ordinary landed-work test covers, must be a clean worktree root
# whose HEAD is landed or held by this task's preservation anchor
# (refs/fm/anchor/<task>-<sha>, written by bin/fm-control.sh reassociate).
# --force does not waive that proof: no captain words cover a prior copy.
#
# teardown_nested_slot is the one owner of that lifecycle, so a re-run after any
# refusal derives its input from the record's branch= and prior_worktree=, never
# from the nested copy still existing:
#   prove    Phase A, no side effects. The slot and every own copy nested in it
#            are clean and landed or anchored, and the claim is this task's.
#   landed   Phase A for a nested copy an earlier teardown already removed: its
#            branch ref, read from the project, passes teardown_landed.
#   retire   Phase B. Conclude parked runs, retire launch agents and reap
#            processes on every root the return sweeps: the current copy, the
#            slot and each nested copy.
#   reprove  The proof again, for a call site that cannot refuse by itself.
#   return   Phase C. Prove again before anything is removed, then remove the
#            nested copies, detach the slot, return it and drop the claim. An
#            ordinary teardown has no nested copy, so only the return remains.
# Sets TEARDOWN_RETURN_SLOT to the slot this teardown returns, TEARDOWN_NESTED_COPIES
# to the proven copies inside it that are removed first, and TEARDOWN_PROOF_COPIES
# to every copy the proof covers. A nested current copy whose enclosing slot this
# task does not claim keeps the ordinary reassociated treatment: nothing of it
# is touched.
TEARDOWN_RETURN_SLOT=
TEARDOWN_NESTED_COPIES=()
TEARDOWN_PROOF_COPIES=()
TEARDOWN_PROOF_OUTCOME="nothing was changed - not even with --force"

# Peer slots. bin/fm-control.sh reassociate can leave two or more live records
# working in their own copies nested in one pool slot, each naming the slot as
# prior_worktree=. Returning that slot would sweep the other records' copies, so
# this teardown removes only its own proven copy: TEARDOWN_PEER_SLOT names the
# slot it leaves and TEARDOWN_RETURN_SLOT stays empty, so nothing slot-wide is
# reaped, reserved, scanned or returned. The slot claim passes to the first
# peer when this task held it, so the last task out finds it its own and returns
# the slot by the ordinary route. Detection reuses the shared proof that those
# records have left the root (fm_task_copy_prior_root_released).
TEARDOWN_PEER_SLOT=
TEARDOWN_PEER_IDS=()
TEARDOWN_PEER_HOMES=()
teardown_slot_peers_detect() {  # <slot>
  local slot=$1 target state_dir other_meta line names_slot
  TEARDOWN_PEER_IDS=()
  TEARDOWN_PEER_HOMES=()
  target=$(fm_task_copy_canonical_dir "$WT" 2>/dev/null) || {
    # A copy an earlier teardown already removed: judge its place by its parent.
    target=$(fm_task_copy_canonical_dir "$(dirname "$WT")" 2>/dev/null) || return 0
    target=$target/$(basename "$WT")
  }
  fm_local_firstmate_state_dirs "$STATE" || return 0
  for state_dir in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for other_meta in "$state_dir"/*.meta; do
      [ -f "$other_meta" ] && [ ! -L "$other_meta" ] || continue
      [ "${other_meta##*/}" = "${META##*/}" ] && [ "$other_meta" -ef "$META" ] && continue
      names_slot=0
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in prior_worktree=?*) ;; *) continue ;; esac
        [ "$(fm_task_copy_canonical_dir "${line#prior_worktree=}" 2>/dev/null)" != "$slot" ] || names_slot=1
      done < "$other_meta"
      [ "$names_slot" = 1 ] || continue
      fm_task_copy_prior_root_released "$other_meta" "$slot" "$target" "$META" "${FM_LOCAL_FIRSTMATE_STATES[@]}" \
        || continue
      TEARDOWN_PEER_IDS+=("$(basename "$other_meta" .meta)")
      TEARDOWN_PEER_HOMES+=("${state_dir%/*}")
    done
  done
}

# Whether <task-id> is one of the peers teardown_slot_peers_detect found.
teardown_slot_peer_named() {  # <task-id>
  local peer
  for peer in ${TEARDOWN_PEER_IDS[@]+"${TEARDOWN_PEER_IDS[@]}"}; do
    [ "$peer" != "$1" ] || return 0
  done
  return 1
}

# This task held the slot's claim and leaves a peer in the slot: hand the claim
# to the first peer, as reassociation claims a root for the first task whose
# copy is nested in it, so the peer's own teardown finds the slot its own. A
# claim already naming a peer, or none, stays as it is.
teardown_peer_claim_handoff() {
  fm_treehouse_slot_owner_state "$TEARDOWN_PEER_SLOT" "$ID"
  [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] || return 0
  fm_treehouse_slot_owner_claim "$TEARDOWN_PEER_SLOT" "${TEARDOWN_PEER_IDS[0]}" "${TEARDOWN_PEER_HOMES[0]}" || {
    echo "error: could not pass pool slot $TEARDOWN_PEER_SLOT's claim to task ${TEARDOWN_PEER_IDS[0]}; retaining task $ID's record for a retry" >&2
    exit 1
  }
}

# Removes this task's proven own nested copies that Vernant's creation lock does
# not hold (those the closeout driver already removed are skipped).
teardown_remove_own_nested_copies() {  # <slot-label>
  local copy known root
  for copy in ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
    known=0
    for root in ${TEARDOWN_OWN_RELEASED[@]+"${TEARDOWN_OWN_RELEASED[@]}"}; do
      [ "$root" != "$copy" ] || known=1
    done
    [ "$known" = 0 ] || continue
    git -C "$PROJ" worktree remove --force "$copy" >/dev/null 2>&1 || {
      echo "error: could not remove $ID's nested copy $copy $1; teardown aborted" >&2
      exit 1
    }
  done
}
teardown_own_copy_disposable() {  # <canonical-copy>
  local copy=$1 what="recorded prior_worktree" rc=0
  [ "$copy" != "$TEARDOWN_ENCLOSING_SLOT" ] || what="claimed pool slot"
  fm_task_copy_preserve "$PROJ" "$ID" "$copy" 0 \
    ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"} || rc=$?
  case "$rc" in
    0) return 0 ;;
    2)
      ! teardown_landed "$copy" HEAD "" || return 0
      echo "REFUSED: returning pool slot $TEARDOWN_RETURN_SLOT would sweep away task $ID's $what $copy, whose HEAD $FM_TASK_COPY_HEAD is neither landed nor held by a refs/fm/anchor/$ID-<sha> preservation anchor; $TEARDOWN_PROOF_OUTCOME." >&2
      echo "Land that commit, or move the task back to that copy and reassociate again so it is anchored, then re-run teardown." >&2
      return 1
      ;;
  esac
  echo "REFUSED: returning pool slot $TEARDOWN_RETURN_SLOT would sweep away task $ID's $what $copy, which $FM_TASK_COPY_REASON; $TEARDOWN_PROOF_OUTCOME." >&2
  if [ -n "$FM_TASK_COPY_DIRTY" ]; then
    report_worktree_dirt "$FM_TASK_COPY_DIRTY"
    echo "Commit and land them, or carry them over, then re-run teardown; it proves the copy again." >&2
  fi
  return 1
}

# The stale-lock return's post-cleanup check: one word, because
# teardown_treehouse_return runs it with no arguments. The nested copy is
# already removed by then.
teardown_nested_slot_reprove_after_lock() {
  TEARDOWN_PROOF_OUTCOME="the slot was not returned, but earlier cleanup steps already ran, including removing its nested and foreign copies; --force does not waive this proof"
  teardown_nested_slot reprove
}

teardown_nested_slot() {  # prove | landed | retire | reprove | return
  local phase=$1 current prior prior_real copy known root branch teardown_slot post_lock_check
  local -a kept=() proofs=() swept=() still=()
  case "$phase" in
    prove)
      [ "$KIND" != secondmate ] || return 0
      TEARDOWN_PEER_SLOT=
      TEARDOWN_PEER_IDS=()
      TEARDOWN_PEER_HOMES=()
      if [ "$TEARDOWN_SLOT_SHARED" = 1 ]; then
        TEARDOWN_ENCLOSING_SLOT=
        return 0
      fi
      if [ -n "$TEARDOWN_ENCLOSING_SLOT" ]; then
        teardown_slot_peers_detect "$TEARDOWN_ENCLOSING_SLOT"
        fm_treehouse_slot_owner_state "$TEARDOWN_ENCLOSING_SLOT" "$ID"
        # A claim naming a peer that is working in the slot is not a
        # reassignment: the slot is shared, not taken from this task.
        if [ "$FM_TREEHOUSE_SLOT_OWNER" = other ] && teardown_slot_peer_named "$FM_TREEHOUSE_SLOT_OWNER_ID"; then
          :
        elif [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ]; then
          TEARDOWN_PEER_IDS=()
          TEARDOWN_PEER_HOMES=()
          TEARDOWN_ENCLOSING_SLOT=
          case "$FM_TREEHOUSE_SLOT_OWNER" in
            absent|other)
              if [ ! -d "$WT" ]; then
                for prior in ${TEARDOWN_PRIOR_COPIES[@]+"${TEARDOWN_PRIOR_COPIES[@]}"}; do
                  prior_real=$(fm_task_copy_canonical_dir "$prior") || prior_real=$prior
                  case "$prior_real" in
                    "$TEARDOWN_RECORD_SLOT"|"$TEARDOWN_RECORD_SLOT"/*) ;;
                    *) still+=("$prior") ;;
                  esac
                done
                TEARDOWN_PRIOR_COPIES=(${still[@]+"${still[@]}"})
              fi
              ;;
          esac
        fi
      fi
      current=$(fm_task_copy_canonical_dir "$WT") || current=
      if [ -n "$TEARDOWN_ENCLOSING_SLOT" ] && [ "${#TEARDOWN_PEER_IDS[@]}" -gt 0 ]; then
        # Other live records work in this slot: remove only this task's own
        # copy, which the ordinary landed-work test covers, and return nothing.
        TEARDOWN_PEER_SLOT=$TEARDOWN_ENCLOSING_SLOT
        TEARDOWN_RETURN_SLOT=
        TEARDOWN_NESTED_COPIES=(${current:+"$current"})
        TEARDOWN_PROOF_COPIES=()
        teardown_nested_slot reprove || return 1
        return 0
      fi
      if [ -n "$TEARDOWN_ENCLOSING_SLOT" ]; then
        TEARDOWN_RETURN_SLOT=$TEARDOWN_ENCLOSING_SLOT
        require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$TEARDOWN_RETURN_SLOT" || return 1
        TEARDOWN_NESTED_COPIES=(${current:+"$current"})
        proofs=("$TEARDOWN_RETURN_SLOT")
      elif ! teardown_owns_worktree || ! TEARDOWN_RETURN_SLOT=$(teardown_live_slot_path); then
        TEARDOWN_RETURN_SLOT=
        return 0
      fi
      for prior in ${TEARDOWN_PRIOR_COPIES[@]+"${TEARDOWN_PRIOR_COPIES[@]}"}; do
        prior_real=$(fm_task_copy_canonical_dir "$prior") || prior_real=$prior
        case "$prior_real" in
          "$TEARDOWN_RETURN_SLOT"|"$TEARDOWN_RETURN_SLOT"/*) ;;
          *) kept+=("$prior") ;;
        esac
      done
      while IFS= read -r prior_real; do
        known=0
        [ "$prior_real" != "$current" ] || known=1
        for copy in ${proofs[@]+"${proofs[@]}"}; do
          [ "$copy" != "$prior_real" ] || known=1
        done
        [ "$known" = 0 ] || continue
        proofs+=("$prior_real")
        TEARDOWN_NESTED_COPIES+=("$prior_real")
      done < <(fm_task_copy_priors_inside "$META" "$TEARDOWN_RETURN_SLOT")
      TEARDOWN_PROOF_COPIES=(${proofs[@]+"${proofs[@]}"})
      teardown_nested_slot reprove || return 1
      TEARDOWN_PRIOR_COPIES=(${kept[@]+"${kept[@]}"})
      ;;
    landed)
      [ -n "$TEARDOWN_RECORD_SLOT" ] && [ ! -d "$WT" ] || return 1
      branch=$(teardown_record_branch)
      git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$branch^{commit}" >/dev/null || return 1
      teardown_landed "$PROJ" "refs/heads/$branch" "$branch"
      ;;
    reprove)
      # A peer that left the slot, or one that arrived, since the proof changes
      # what this teardown may remove, so the proof is taken again.
      if [ -n "$TEARDOWN_PEER_SLOT" ]; then
        teardown_slot_peers_detect "$TEARDOWN_PEER_SLOT"
        if [ "${#TEARDOWN_PEER_IDS[@]}" -eq 0 ]; then
          echo "REFUSED: no other live task works in pool slot $TEARDOWN_PEER_SLOT any more, so task $ID's cleanup is no longer the peer route; re-run bin/fm-teardown.sh $ID. $TEARDOWN_PROOF_OUTCOME." >&2
          return 1
        fi
      fi
      # Foreign copies the library proves are allowed here; an unprovable one is
      # named by the library and refused by the custody check below.
      [ -z "$TEARDOWN_RETURN_SLOT" ] || teardown_foreign_copies_prove "$TEARDOWN_RETURN_SLOT"
      [ -z "$TEARDOWN_RETURN_SLOT" ] || require_registered_slot_copies "$ID" "$TEARDOWN_RETURN_SLOT" \
        ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"} \
        ${TEARDOWN_FOREIGN_COPIES[@]+"${TEARDOWN_FOREIGN_COPIES[@]}"} || return 1
      for copy in ${TEARDOWN_PROOF_COPIES[@]+"${TEARDOWN_PROOF_COPIES[@]}"}; do
        [ -d "$copy" ] || [ "$copy" = "$TEARDOWN_RETURN_SLOT" ] || continue
        teardown_own_copy_disposable "$copy" || return 1
      done
      # An own copy Vernant's creation lock holds is released by its driver, so it
      # also needs the release proofs a foreign copy gets.
      [ -z "${TEARDOWN_RETURN_SLOT:-$TEARDOWN_PEER_SLOT}" ] || teardown_own_locked_copies_prove || return 1
      ;;
    retire)
      # Fix 1, Fix 3 and Fix 2 of the script header, on every swept root.
      swept=("$WT")
      for root in ${TEARDOWN_RETURN_SLOT:+"$TEARDOWN_RETURN_SLOT"} \
          ${TEARDOWN_NESTED_COPIES[@]+"${TEARDOWN_NESTED_COPIES[@]}"}; do
        [ "$root" -ef "$WT" ] || swept+=("$root")
      done
      for root in "${swept[@]}"; do
        conclude_task_no_mistakes_run "$root" || exit 1
      done
      for root in "${swept[@]}"; do
        retire_task_private_nm_launch_agents "$root" || exit 1
      done
      teardown_foreign_procs_retire || exit 1
      reap_task_worktree_processes worktree "${swept[@]}" "$TASK_TMP" || exit 1
      ;;
    return)
      if [ -n "$TEARDOWN_PEER_SLOT" ]; then
        # Only this task's own copy goes; the slot, its lease and every peer's
        # copy stay, and the claim moves to a peer when it was this task's.
        TEARDOWN_PROOF_OUTCOME="earlier cleanup steps already ran, but nothing was removed and the slot keeps its contents; --force does not waive this proof"
        teardown_nested_slot reprove || exit 1
        [ ! -d "$WT" ] || require_worktree_teardown_safety
        teardown_own_locked_copies_release || exit 1
        teardown_remove_own_nested_copies "from pool slot $TEARDOWN_PEER_SLOT, which other tasks still work in"
        teardown_peer_claim_handoff
        return 0
      fi
      if [ -n "$TEARDOWN_ENCLOSING_SLOT" ] || [ "${#TEARDOWN_NESTED_COPIES[@]}" -gt 0 ]; then
        TEARDOWN_PROOF_OUTCOME="earlier cleanup steps already ran, but nothing was removed and the slot keeps its contents; --force does not waive this proof"
        teardown_nested_slot reprove || exit 1
      fi
      # Foreign copies are released before anything else is removed, each proved
      # again first; a refusal leaves the slot as it is.
      if [ "${#TEARDOWN_FOREIGN_COPIES[@]}" -gt 0 ]; then
        teardown_foreign_copies_release || exit 1
      fi
      if [ -n "$TEARDOWN_ENCLOSING_SLOT" ] || [ "${#TEARDOWN_NESTED_COPIES[@]}" -gt 0 ]; then
        [ ! -d "$WT" ] || require_worktree_teardown_safety
        teardown_own_locked_copies_release || exit 1
        teardown_remove_own_nested_copies "before returning pool slot $TEARDOWN_RETURN_SLOT"
      fi
      teardown_slot=${TEARDOWN_ENCLOSING_SLOT:-$WT}
      branch=$(git -C "$teardown_slot" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
      if [ "$branch" != "HEAD" ]; then
        if git -C "$teardown_slot" checkout --detach -q 2>/dev/null; then
          git -C "$teardown_slot" branch -D "$branch" >/dev/null 2>&1 || true
        fi
      fi
      # Remove our hook file so a reused pool worktree cannot fire signals for a dead task.
      rm -f "$teardown_slot/.claude/settings.local.json" "$teardown_slot/.opencode/plugins/fm-turn-end.js" \
        "$teardown_slot/.fm-grok-turnend" "$teardown_slot/.fm-kimi-turnend"
      # Kills remaining processes in the worktree (including the agent), resets, returns
      # to pool. treehouse resolves the pool from the working directory, so run it from
      # the project. teardown_treehouse_return tolerates transient and stale git locks
      # left by a killed crew process; see the script header for retry and stale-lock proof.
      post_lock_check=
      if [ -n "$TEARDOWN_ENCLOSING_SLOT" ]; then
        post_lock_check=teardown_nested_slot_reprove_after_lock
      elif [ "$FORCE" != "--force" ] && [ "$KIND" != scout ] && [ "$KIND" != secondmate ]; then
        post_lock_check=validate_worktree_teardown_safety
      fi
      if [ "$KIND" = scout ] || [ "$FORCE" = "--force" ]; then
        teardown_scrub_scratch_copy "$teardown_slot" "$ID" || exit 1
      fi
      local returned_pool_slot=0
      fm_treehouse_pool_slot "$PROJ" "$teardown_slot" && returned_pool_slot=1
      teardown_treehouse_return "$teardown_slot" "$PROJ" "worktree" "$ID" "$post_lock_check" || {
        echo "error: treehouse return failed for worktree $teardown_slot; teardown aborted" >&2
        exit 1
      }
      [ "$returned_pool_slot" = 0 ] || teardown_note_dirty_return "$teardown_slot"
      # The slot is back in the pool, so this task's claim on it is spent. Dropping
      # it here - and only after a return that succeeded - keeps a returned slot
      # unclaimed until its next holder claims it, and leaves the claim in place
      # whenever the return did not actually happen.
      fm_treehouse_slot_owner_release "$teardown_slot" "$ID"
      ;;
  esac
}

firstmate_home_has_treehouse_slot() {
  local home=$1
  worktree_registered_for_project "$FM_ROOT" "$home"
}

validate_removal_target() {
  local target=$1 label=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(removal_target_abs_path "$target")
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    :
  else
    abs_home=
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  case "$abs_target" in
    ''|/) echo "REFUSED: unsafe $label removal target $target" >&2; return 1 ;;
  esac
  if [ -n "$abs_home" ] && [ "$abs_target" = "$abs_home" ]; then
    echo "REFUSED: unsafe $label removal target $target is the active firstmate home" >&2
    return 1
  fi
  if [ "$abs_target" = "$abs_root" ]; then
    echo "REFUSED: unsafe $label removal target $target is the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_target" "$abs_home"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_target" "$abs_root"; then
    echo "REFUSED: unsafe $label removal target $target is an ancestor of the firstmate repo" >&2
    return 1
  fi
  if [ -n "$abs_home" ] && path_is_ancestor_of "$abs_home" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the active firstmate home" >&2
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe $label removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

registered_descendant_home_for_removal() {
  local reg=$1 target=$2 line id registered_home registered_abs
  [ -f "$reg" ] || return 1
  if ! secondmate_registry_validate_bindings "$reg" secondmate_registry_path_key; then
    echo "REFUSED: $SECONDMATE_REGISTRY_ERROR" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        secondmate_registry_parse_line "$line" || {
          echo "REFUSED: malformed secondmate registry entry: $line" >&2
          return 2
        }
        id=$SECONDMATE_REGISTRY_ID
        registered_home=$SECONDMATE_REGISTRY_HOME
        registered_abs=$(removal_target_abs_path "$registered_home" 2>/dev/null || true)
        [ -n "$registered_abs" ] || continue
        [ "$registered_abs" = "$target" ] && continue
        if path_is_ancestor_of "$target" "$registered_abs"; then
          printf '%s\t%s\n' "$id" "$registered_abs"
          return 0
        fi
        ;;
    esac
  done < "$reg"
  return 1
}

validate_firstmate_operational_dirs_for_removal() {
  local home=$1 label=$2 name dir abs_home abs_dir
  abs_home=$(removal_target_abs_path "$home")
  for name in data state config projects; do
    dir="$home/$name"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P)
    elif [ -e "$dir" ]; then
      echo "REFUSED: unsafe $label $name path $dir is not a directory" >&2
      return 1
    else
      abs_dir=
    fi
    if [ -z "$abs_dir" ] || ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      echo "REFUSED: unsafe $label $name directory $dir resolves outside the secondmate home" >&2
      return 1
    fi
  done
}

validate_child_worktree_for_removal() {
  local target=$1 project=$2 abs_target abs_home abs_root
  [ -n "$target" ] || return 0
  [ -e "$target" ] || return 0
  abs_target=$(validate_removal_target "$target" "child worktree") || return 1
  if abs_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P); then
    if path_is_ancestor_of "$abs_home" "$abs_target"; then
      echo "REFUSED: unsafe child worktree removal target $target is inside the active firstmate home" >&2
      return 1
    fi
  fi
  abs_root=$(cd "$FM_ROOT" && pwd -P)
  if path_is_ancestor_of "$abs_root" "$abs_target"; then
    echo "REFUSED: unsafe child worktree removal target $target is inside the firstmate repo" >&2
    return 1
  fi
  if ! worktree_registered_for_project "$project" "$target"; then
    echo "REFUSED: unsafe child worktree removal target $target is not a git worktree for ${project:-the recorded project}" >&2
    return 1
  fi
  printf '%s\n' "$abs_target"
}

safe_rm_rf() {
  local target=$1 label=$2
  validate_removal_target "$target" "$label" >/dev/null || return 1
  rm -rf -- "$target"
}

safe_rm_rf_child_worktree() {  # <target> <project> <owner-task>
  local target=$1 project=$2 owner=$3
  validate_child_worktree_for_removal "$target" "$project" >/dev/null || return 1
  if fm_treehouse_pool_slot "$project" "$target"; then
    require_registered_slot_copies "$owner" "$target" || return 1
  fi
  rm -rf -- "$target"
}

validate_firstmate_home_for_removal() {
  local home=$1 label=$2 expected_id=$3 registry=$4 abs_home_path marker_id conflict child_id child_home
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_removal_target "$home" "$label") || return 1
  if [ ! -f "$abs_home_path/$SUB_HOME_MARKER" ]; then
    echo "REFUSED: unsafe $label removal target $home is not a seeded secondmate home" >&2
    return 1
  fi
  if [ -n "$expected_id" ]; then
    marker_id=$(cat "$abs_home_path/$SUB_HOME_MARKER" 2>/dev/null || true)
    if [ "$marker_id" != "$expected_id" ]; then
      echo "REFUSED: unsafe $label removal target $home is marked for secondmate ${marker_id:-unknown}, expected $expected_id" >&2
      return 1
    fi
    if [ -e "$registry" ] || [ -L "$registry" ]; then
      if ! secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key "$expected_id" "$abs_home_path"; then
        case "$SECONDMATE_REGISTRY_ERROR" in
          overlapping\ secondmate\ home\ assignment:*)
            echo "REFUSED: unsafe $label removal target $home contains registered secondmate home; $SECONDMATE_REGISTRY_ERROR" >&2
            ;;
          *) echo "REFUSED: $SECONDMATE_REGISTRY_ERROR" >&2 ;;
        esac
        return 1
      fi
    fi
  fi
  validate_firstmate_operational_dirs_for_removal "$abs_home_path" "$label" || return 1
  conflict=
  if conflict=$(registered_descendant_home_for_removal "$SECONDMATE_REG" "$abs_home_path"); then
    :
  else
    conflict_rc=$?
    [ "$conflict_rc" -eq 1 ] || return 1
  fi
  if [ -z "$conflict" ]; then
    if conflict=$(registered_descendant_home_for_removal "$abs_home_path/data/secondmates.md" "$abs_home_path"); then
      :
    else
      conflict_rc=$?
      [ "$conflict_rc" -eq 1 ] || return 1
    fi
  fi
  if [ -n "$conflict" ]; then
    IFS=$'\t' read -r child_id child_home <<EOF
$conflict
EOF
    echo "REFUSED: unsafe $label removal target $home contains registered secondmate home $child_home for $child_id" >&2
    return 1
  fi
  printf '%s\n' "$abs_home_path"
}

remove_firstmate_home() {
  local home=$1 label=$2 expected_id=$3 registry=$4 abs_home_path process_event_backup
  [ -n "$home" ] || return 0
  [ -e "$home" ] || return 0
  abs_home_path=$(validate_firstmate_home_for_removal "$home" "$label" "$expected_id" "$registry") || return 1
  [ -n "$abs_home_path" ] || return 0
  process_event_backup=$(snapshot_firstmate_home_process_events "$abs_home_path" "$label") || return 1
  if ! cleanup_firstmate_home_process_events "$abs_home_path" "$label"; then
    restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
    return 1
  fi
  # Read-only strip dirs sit at state/<id>.git-hooks, and a remote secondmate's
  # own one under state/parent-route/, so search the whole state tree.
  find "$abs_home_path/state" -type d -name '*.git-hooks' -exec chmod u+w {} + 2>/dev/null || true
  if firstmate_home_has_treehouse_slot "$abs_home_path"; then
    command -v treehouse >/dev/null 2>&1 || {
      echo "error: treehouse command not found; cannot return $label $abs_home_path" >&2
      restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
      return 1
    }
    teardown_treehouse_return "$abs_home_path" "$FM_ROOT" "$label" "$expected_id" || {
      echo "error: treehouse return failed for $label $abs_home_path; lease may still be held" >&2
      restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
      return 1
    }
    [ -z "$process_event_backup" ] || rm -rf -- "$process_event_backup"
    return 0
  fi
  if safe_rm_rf "$abs_home_path" "$label"; then
    [ -z "$process_event_backup" ] || rm -rf -- "$process_event_backup"
    return 0
  fi
  restore_firstmate_home_process_events "$abs_home_path" "$label" "$process_event_backup" || return $?
  return 1
}

firstmate_home_has_process_events() {
  local home=$1 path owner claim_root
  for path in "$home/state/procevent"/*.source "$home/state/procevent"/*.runner; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      return 0
    fi
  done
  claim_root=${FM_PROCEVENT_CLAIM_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/procevent-claims}
  for path in "$claim_root"/*.claim; do
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    IFS= read -r owner < "$path" 2>/dev/null || continue
    [ "$owner" = "$home" ] && return 0
  done
  return 1
}

snapshot_firstmate_home_process_events() {
  local home=$1 label=$2 backup path
  if ! firstmate_home_has_process_events "$home"; then
    printf '\n'
    return 0
  fi
  backup=$(umask 077; mktemp -d "${home%/*}/.fm-procevent-restore.XXXXXX") || {
    echo "REFUSED: cannot stage recoverable process-event state for $label $home" >&2
    return 1
  }
  for path in "$home/state/procevent"/*.source; do
    [ -e "$path" ] || continue
    if [ ! -f "$path" ] || [ -L "$path" ] || ! cp -p -- "$path" "$backup/"; then
      rm -rf -- "$backup"
      echo "REFUSED: cannot preserve process-event registrations for $label $home" >&2
      return 1
    fi
  done
  printf '%s\n' "$backup"
}

restore_firstmate_home_process_events() {
  local home=$1 label=$2 backup=$3 reg source tmp runner
  [ -n "$backup" ] || return 0
  [ -d "$backup" ] && [ ! -L "$backup" ] || {
    echo "error: process-event restoration failed for $label $home; recovery backup is unavailable at $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  reg="$home/state/procevent"
  (umask 077; mkdir -p "$reg") || {
    echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  [ -d "$reg" ] && [ ! -L "$reg" ] || {
    echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  }
  for source in "$backup"/*.source; do
    [ -e "$source" ] || continue
    [ -f "$source" ] && [ ! -L "$source" ] || {
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    }
    tmp=$(umask 077; mktemp "$reg/.restore.XXXXXX") || {
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    }
    if ! cp -- "$source" "$tmp" || ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$reg/${source##*/}"; then
      rm -f -- "$tmp"
      echo "error: process-event restoration failed for $label $home; recover registrations from $backup" >&2
      return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
    fi
  done
  runner="$home/bin/fm-procevent.sh"
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    runner="$SCRIPT_DIR/fm-procevent.sh"
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" "$runner" reconcile >/dev/null; then
    echo "error: process-event restoration could not rearm $label $home; active waits may remain retired; recover registrations from $backup" >&2
    return "$TEARDOWN_PROCEVENT_RESTORE_FAILED"
  fi
  rm -rf -- "$backup"
}

cleanup_firstmate_home_process_events() {
  local home=$1 label=$2 runner="$1/bin/fm-procevent.sh"
  firstmate_home_has_process_events "$home" || return 0
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    echo "REFUSED: $label $home has process-event state but no sweep-capable bin/fm-procevent.sh; restore the home script and rerun teardown" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$runner" sweep-home; then
    echo "REFUSED: process-event cleanup is incomplete for $label $home; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
  if firstmate_home_has_process_events "$home"; then
    echo "REFUSED: process-event state remains for $label $home after its bounded sweep; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
}

preflight_firstmate_home_process_events() {
  local home=$1 label=$2 runner="$1/bin/fm-procevent.sh"
  firstmate_home_has_process_events "$home" || return 0
  if [ ! -f "$runner" ] || [ -L "$runner" ] || [ ! -x "$runner" ]; then
    echo "REFUSED: $label $home has process-event state but no sweep-capable bin/fm-procevent.sh; restore the home script and rerun teardown" >&2
    return 1
  fi
  if ! FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$runner" sweep-home --preflight >/dev/null; then
    echo "REFUSED: process-event cleanup cannot safely proceed for $label $home; preserving the home, lease, and retirement records for retry" >&2
    return 1
  fi
}

preflight_firstmate_home_process_event_tree() {
  local home=$1 label=$2 sub_state child_meta child_kind child_home child_wt child_id
  sub_state="$home/state"
  if [ -d "$sub_state" ]; then
    for child_meta in "$sub_state"/*.meta; do
      [ -e "$child_meta" ] || continue
      child_kind=$(meta_value "$child_meta" kind)
      [ "$child_kind" = secondmate ] || continue
      child_id=$(basename "$child_meta" .meta)
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      preflight_firstmate_home_process_event_tree "$child_home" "child firstmate home for $child_id" || return 1
    done
  fi
  preflight_firstmate_home_process_events "$home" "$label"
}

collect_descendant_task_locks() {
  local home=$1 sub_state child_meta child_id child_kind child_wt child_home task_set_lock registry_lock
  local -a child_ids
  sub_state="$home/state"
  if [ -L "$sub_state" ]; then
    echo "REFUSED: secondmate home $home has a symbolic-link state path at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  if [ -e "$sub_state" ] && [ ! -d "$sub_state" ]; then
    echo "REFUSED: secondmate home $home has a non-directory state path at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  if ! mkdir -p -- "$sub_state"; then
    echo "REFUSED: secondmate home $home state directory could not be established at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  if [ -L "$sub_state" ] || [ ! -d "$sub_state" ]; then
    echo "REFUSED: secondmate home $home state path is not a safe directory at $sub_state; forced teardown changed nothing" >&2
    return 1
  fi
  # Freeze this home's task SET before reading it. Everything below locks the
  # tasks that exist right now, but the later cleanup re-enumerates, so without
  # this a fresh spawn could publish a record into the gap and be mutated
  # without ever having been lifecycle-locked (bin/fm-wake-lib.sh's
  # fm_task_set_lock_path owns why). Taken per home, parent before child, and
  # held until this teardown exits.
  task_set_lock=$(fm_task_set_lock_path "$sub_state") || {
    echo "REFUSED: secondmate home $home has an invalid task-set lock path; forced teardown changed nothing" >&2
    return 1
  }
  if ! fm_lock_try_acquire "$task_set_lock"; then
    echo "REFUSED: secondmate home $home is publishing a task right now (task-set lock is held); forced teardown changed nothing" >&2
    return 1
  fi
  if ! fm_lock_set_role "$task_set_lock" forced-teardown; then
    fm_lock_release "$task_set_lock" || true
    echo "REFUSED: secondmate home $home could not record its task-set lock holder; forced teardown changed nothing" >&2
    return 1
  fi
  DESCENDANT_LOCK_PATHS+=("$task_set_lock")
  registry_lock=$(secondmate_registry_lock_path "$sub_state")
  if ! fm_lock_try_acquire "$registry_lock"; then
    echo "REFUSED: secondmate home $home is updating its registry right now; forced teardown changed nothing" >&2
    return 1
  fi
  DESCENDANT_LOCK_PATHS+=("$registry_lock")
  child_ids=()
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_ids+=("$(basename "$child_meta" .meta)")
  done
  [ "${#child_ids[@]}" -gt 0 ] || return 0
  while IFS= read -r child_id; do
    child_meta="$sub_state/$child_id.meta"
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_home=
    if [ "$child_kind" = secondmate ]; then
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
    fi
    DESCENDANT_TASK_STATES+=("$sub_state")
    DESCENDANT_TASK_IDS+=("$child_id")
    DESCENDANT_TASK_KINDS+=("$child_kind")
    DESCENDANT_TASK_HOMES+=("$child_home")
    [ "$child_kind" != secondmate ] \
      || collect_descendant_task_locks "$child_home" \
      || return 1
  done < <(printf '%s\n' "${child_ids[@]}" | LC_ALL=C sort)
}

preflight_descendant_task_locks() {
  local home=$1 i state task_id meta control_lock meta_lock kind child_wt child_home
  DESCENDANT_TASK_STATES=()
  DESCENDANT_TASK_IDS=()
  DESCENDANT_TASK_KINDS=()
  DESCENDANT_TASK_HOMES=()
  DESCENDANT_TREEHOUSE_LOCK_PATHS=()
  collect_descendant_task_locks "$home" || return 1
  # Acquisition order, which every other holder of these locks must match so
  # they cannot cycle: each home's task-set lock first (parent home before child
  # home, during collection above), then per-task locks in that same
  # parent-before-child preorder, sorted by id within each home, each control
  # lock before its matching metadata lock. No child lock holder ever reaches
  # back for a parent lock. A secondmate spawn in bin/fm-spawn.sh takes the same
  # task-set lock before its own per-task locks when it publishes a fresh
  # record. A worker spawn takes its own control and spawn-task locks first,
  # then the shared project lock, then the task-set lock; the task-set and
  # per-task locks are all single tries, so that order cannot wait in a cycle.
  for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
    state=${DESCENDANT_TASK_STATES[$i]}
    task_id=${DESCENDANT_TASK_IDS[$i]}
    meta="$state/$task_id.meta"
    control_lock="$state/.control-$task_id.lock"
    meta_lock=$(fm_meta_lock_path "$meta") || {
      echo "REFUSED: descendant task $task_id has an invalid metadata lock path; forced teardown changed nothing" >&2
      return 1
    }
    if ! fm_lock_try_acquire "$control_lock"; then
      echo "REFUSED: descendant task $task_id has a lifecycle action in flight (control lock is held); forced teardown changed nothing" >&2
      return 1
    fi
    DESCENDANT_LOCK_PATHS+=("$control_lock")
    if ! fm_lock_try_acquire "$meta_lock"; then
      echo "REFUSED: descendant task $task_id has a metadata update in flight (metadata lock is held); forced teardown changed nothing" >&2
      return 1
    fi
    DESCENDANT_LOCK_PATHS+=("$meta_lock")
    [ -f "$meta" ] || {
      echo "REFUSED: descendant task $task_id changed while forced teardown acquired its locks; forced teardown changed nothing" >&2
      return 1
    }
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = "${DESCENDANT_TASK_KINDS[$i]}" ] || {
      echo "REFUSED: descendant task $task_id changed kind while forced teardown acquired its locks; forced teardown changed nothing" >&2
      return 1
    }
    if [ "$kind" = secondmate ]; then
      child_wt=$(meta_value "$meta" worktree)
      child_home=$(meta_value "$meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      [ "$child_home" = "${DESCENDANT_TASK_HOMES[$i]}" ] || {
        echo "REFUSED: descendant task $task_id changed home while forced teardown acquired its locks; forced teardown changed nothing" >&2
        return 1
      }
    fi
  done
}

preflight_descendant_treehouse_slots() {
  local i j state task_id meta kind backend target worktree project lock_path held owner_rc
  local LC_ALL=C
  local -a project_locks=() project_tasks=()
  local -a reserve_slots=() reserve_projects=() reserve_tasks=()
  for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
    state=${DESCENDANT_TASK_STATES[$i]}
    task_id=${DESCENDANT_TASK_IDS[$i]}
    meta="$state/$task_id.meta"
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    backend=$(fm_backend_of_meta "$meta")
    worktree=$(meta_value "$meta" worktree)
    project=$(meta_value "$meta" project)
    if [ "$kind" = secondmate ] || [ "$backend" = orca ]; then
      continue
    fi
    if ! fm_treehouse_pool_slot "$project" "$worktree"; then
      continue
    fi
    lock_path=$(fm_treehouse_project_lock_path "$project") || {
      echo "REFUSED: cannot resolve the shared Treehouse project lock for child $task_id; forced teardown changed nothing" >&2
      return 1
    }
    held=0
    [ "$TREEHOUSE_PROJECT_LOCK_HELD" != 1 ] || [ "$TREEHOUSE_PROJECT_LOCK" != "$lock_path" ] || held=1
    for target in "${DESCENDANT_TREEHOUSE_LOCK_PATHS[@]+"${DESCENDANT_TREEHOUSE_LOCK_PATHS[@]}"}"; do
      [ "$target" != "$lock_path" ] || held=1
    done
    for target in "${project_locks[@]+"${project_locks[@]}"}"; do
      [ "$target" != "$lock_path" ] || held=1
    done
    if [ "$held" = 0 ]; then
      # Global byte order, not child enumeration order: two unrelated local
      # homes may enumerate the same projects in opposite orders. Each holding
      # the one the other tries next would otherwise refuse both.
      j=${#project_locks[@]}
      while [ "$j" -gt 0 ] && [[ "${project_locks[$((j - 1))]}" > "$lock_path" ]]; do
        project_locks[j]=${project_locks[$((j - 1))]}
        project_tasks[j]=${project_tasks[$((j - 1))]}
        j=$((j - 1))
      done
      project_locks[j]=$lock_path
      project_tasks[j]=$task_id
    fi
  done
  for ((i=0; i < ${#project_locks[@]}; i++)); do
    lock_path=${project_locks[$i]}
    task_id=${project_tasks[$i]}
    fm_project_lock_try "$lock_path" "teardown $ID child $task_id" || {
      echo "REFUSED: another Treehouse slot allocation or return is in progress for child $task_id; forced teardown changed nothing" >&2
      return 1
    }
    DESCENDANT_TREEHOUSE_LOCK_PATHS+=("$lock_path")
  done
  for ((i=0; i < ${#DESCENDANT_TASK_IDS[@]}; i++)); do
    state=${DESCENDANT_TASK_STATES[$i]}
    task_id=${DESCENDANT_TASK_IDS[$i]}
    meta="$state/$task_id.meta"
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    backend=$(fm_backend_of_meta "$meta")
    worktree=$(meta_value "$meta" worktree)
    project=$(meta_value "$meta" project)
    if [ "$kind" = secondmate ] || [ "$backend" = orca ]; then
      continue
    fi
    if ! fm_treehouse_pool_slot "$project" "$worktree"; then
      continue
    fi
    fm_backend_validate_task_endpoint "$meta" "$task_id" || return 1
    require_exclusive_worktree_slot_record "$meta" "$task_id" "$state" "$worktree" || return 1
    owner_rc=0
    require_owned_worktree_slot_record "$task_id" "$worktree" || owner_rc=$?
    case "$owner_rc" in
      0)
        require_registered_slot_copies "$task_id" "$worktree" || return 1
        reserve_slots+=("$worktree")
        reserve_projects+=("$project")
        reserve_tasks+=("$task_id")
        ;;
      "$TEARDOWN_SLOT_REASSIGNED_RC") ;;
      *) return 1 ;;
    esac
  done
  for ((i=0; i < ${#reserve_slots[@]}; i++)); do
    teardown_reserve_pool_slot "${reserve_slots[$i]}" "${reserve_projects[$i]}" "${reserve_tasks[$i]}" || return 1
    teardown_mark_return_pending "${reserve_slots[$i]}" "${reserve_tasks[$i]}" || return 1
    if [ "$TEARDOWN_SLOT_CUSTODY" = project ]; then
      DESCENDANT_LEGACY_CUSTODY=1
    else
      DESCENDANT_LEASED_SLOTS+=("$(cd "${reserve_slots[$i]}" && pwd -P)")
    fi
  done
  [ "$DESCENDANT_LEGACY_CUSTODY" = 1 ] || teardown_release_descendant_project_locks
}

teardown_release_descendant_project_locks() {
  local lock_path
  for lock_path in "${DESCENDANT_TREEHOUSE_LOCK_PATHS[@]+"${DESCENDANT_TREEHOUSE_LOCK_PATHS[@]}"}"; do
    fm_project_lock_release "$lock_path" || return 1
  done
  DESCENDANT_TREEHOUSE_LOCK_PATHS=()
}

validate_firstmate_home_children_removal() {
  local home=$1 removal_root=${2:-$1} sub_state child_meta child_id child_wt child_proj child_kind child_home child_backend child_copy_mode child_keep_copy
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    fm_backend_validate_task_endpoint "$child_meta" "$child_id" || return 1
    validate_pr_poll_cleanup "$sub_state" "$child_id" || return 1
    child_wt=$(meta_value "$child_meta" worktree)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    child_proj=$(meta_value "$child_meta" project)
    child_keep_copy=0
    if teardown_preserves_reassociated_copy "$child_meta" "$child_kind" "$child_backend" "$child_proj" "$child_wt"; then
      child_keep_copy=1
    fi
    child_copy_mode=1
    [ "$child_kind" != secondmate ] || child_copy_mode=home
    if [ "$child_kind" != secondmate ] && [ "$child_backend" != orca ] \
       && fm_treehouse_pool_slot "$child_proj" "$child_wt"; then
      require_exclusive_worktree_slot_record "$child_meta" "$child_id" "$sub_state" "$child_wt" || return 1
    else
      require_cleanup_copy_clearance "$child_meta" "$child_id" "$sub_state" "$child_wt" "$child_copy_mode" || return 1
    fi
    require_cleanup_copy_clearance "$child_meta" "$child_id" "$sub_state" "$removal_root" home || return 1
    teardown_require_backend_prerequisites "$child_backend" "$child_id" || return 1
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      require_cleanup_copy_clearance "$child_meta" "$child_id" "$sub_state" "$child_home" home || return 1
      validate_firstmate_home_for_removal "$child_home" "child firstmate home" "$child_id" "$home/data/secondmates.md" >/dev/null || return 1
      if fm_treehouse_pool_slot "$FM_ROOT" "$child_home"; then
        require_registered_slot_copies "$child_id" "$child_home" || return 1
      fi
      validate_firstmate_home_children_removal "$child_home" "$removal_root" || return 1
    elif [ "$child_backend" = orca ]; then
      require_orca_worktree_id "$child_meta" >/dev/null || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    elif [ "$child_keep_copy" != 1 ] && [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
    fi
  done
}

TEARDOWN_HERDR_LOCK_RECORDS=
TEARDOWN_HERDR_ADMITTED_METAS=()
TEARDOWN_HERDR_ADMITTED_IDENTITIES=()
TEARDOWN_HERDR_ADMITTED_LOCK_PATHS=()
teardown_release_herdr_locks() {
  local lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 0
  while IFS=$'\t' read -r lock_session lock_path; do
    [ -n "$lock_path" ] || continue
    fm_lock_release "$lock_path" || true
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  TEARDOWN_HERDR_LOCK_RECORDS=
}

teardown_herdr_session_lock_held() {  # <session>
  local session=$1 lock_session lock_path
  [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ] || return 1
  while IFS=$'\t' read -r lock_session lock_path; do
    [ "$lock_session" != "$session" ] || return 0
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  return 1
}

teardown_herdr_require_prerequisites() {  # <task-id>
  local task_id=$1 prerequisite
  teardown_require_backend_prerequisites herdr "$task_id" || return 1
  for prerequisite in \
    fm_backend_herdr_parse_target \
    fm_backend_herdr_pane_presence_state \
    fm_backend_herdr_workspace_presence_state \
    fm_backend_herdr_endpoint_confirmed_gone \
    fm_backend_herdr_explicit_close_pane_confirmed \
    fm_backend_herdr_presentation_session_lock_path; do
    if ! declare -F "$prerequisite" >/dev/null 2>&1; then
      echo "error: herdr teardown prerequisites are unavailable for $task_id; retaining its durable records - restore the adapter and rerun teardown" >&2
      return 1
    fi
  done
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
  fi
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1 \
    || ! declare -F fm_lock_release >/dev/null 2>&1; then
    echo "error: herdr teardown lock machinery is unavailable for $task_id; retaining its durable records - restore the lock support and rerun teardown" >&2
    return 1
  fi
}

teardown_herdr_preflight_target() {  # <target> <task-id>
  local target=$1 task_id=$2 expected_lock_path=${3-} session pane lock_path verified_lock_path lock_session held_path attempt
  teardown_herdr_require_prerequisites "$task_id" || return 1
  if ! fm_backend_herdr_parse_target "$target"; then
    echo "error: herdr endpoint $target for $task_id could not be parsed exactly; retaining its durable records - repair the endpoint metadata and rerun teardown" >&2
    return 1
  fi
  session=$FM_BACKEND_HERDR_SESSION
  pane=$FM_BACKEND_HERDR_PANE
  if ! lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session"); then
    echo "error: herdr session presentation lock could not be resolved for $task_id; retaining its durable records - rerun teardown once the session is reachable and unambiguous" >&2
    return 1
  fi
  if [ -n "$expected_lock_path" ] && [ "$lock_path" != "$expected_lock_path" ]; then
    echo "error: herdr session identity changed after admission for $task_id; retaining its durable records" >&2
    return 1
  fi
  if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
    while IFS=$'\t' read -r lock_session held_path; do
      if [ "$lock_session" = "$session" ]; then
        if [ "$held_path" != "$lock_path" ]; then
          echo "error: herdr session presentation lock changed during preflight for $task_id; retaining its durable records - rerun teardown once session identity is stable" >&2
          return 1
        fi
        teardown_herdr_presence_admit "$session" "$pane" "$task_id"
        return $?
      fi
    done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  fi
  attempt=0
  while [ "$attempt" -lt 50 ]; do
    if fm_lock_try_acquire "$lock_path"; then
      if ! verified_lock_path=$(fm_backend_herdr_presentation_session_lock_path "$session") \
        || [ "$verified_lock_path" != "$lock_path" ]; then
        fm_lock_release "$lock_path" || true
        echo "error: herdr session presentation lock changed during preflight for $task_id; retaining its durable records - rerun teardown once session identity is stable" >&2
        return 1
      fi
      if [ -n "$TEARDOWN_HERDR_LOCK_RECORDS" ]; then
        TEARDOWN_HERDR_LOCK_RECORDS="$TEARDOWN_HERDR_LOCK_RECORDS
$session	$lock_path"
      else
        TEARDOWN_HERDR_LOCK_RECORDS="$session	$lock_path"
      fi
      teardown_herdr_presence_admit "$session" "$pane" "$task_id"
      return $?
    fi
    sleep 0.1
    attempt=$((attempt + 1))
  done
  echo "error: herdr session presentation lock is contended for $task_id; retaining its durable records - rerun teardown once the contention clears" >&2
  return 1
}

teardown_herdr_presence_admit() {
  local session=$1 pane=$2 task_id=$3 presence
  presence=$(fm_backend_herdr_pane_presence_state "$session" "$pane")
  case "$presence" in
    dead|present) return 0 ;;
  esac
  echo "error: herdr endpoint $session:$pane for $task_id has ambiguous structured presence; retaining its durable records" >&2
  return 1
}

teardown_herdr_meta_identity() {
  local meta=$1 task_id=$2 state=$3 key value
  fm_backend_validate_task_endpoint "$meta" "$task_id" || return 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || return 1
  for key in backend window worktree project endpoint_task_id \
      herdr_session herdr_workspace_id herdr_tab_id herdr_pane_id; do
    value=$(fm_backend_meta_exact_value "$meta" "$key") || return 1
    printf '%s=%s\n' "$key" "$value"
  done
  fm_backlog_meta_spawn_gen_optional "$meta" "$state" || {
    echo "error: herdr task $task_id has ambiguous spawn generation ($FM_BACKLOG_TRANSITION_ERROR); retaining its durable records" >&2
    return 1
  }
  printf 'spawn_gen=%s\nkind=%s\nhome=%s\n' "$FM_BACKLOG_META_SPAWN_GEN" \
    "$(meta_value "$meta" kind)" "$(meta_value "$meta" home)"
}

teardown_herdr_admit_meta() {
  local meta=$1 task_id=$2 state=$3 identity target session lock_path lock_session held_path i
  fm_backend_validate_task_endpoint "$meta" "$task_id" || return 1
  [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || return 1
  target=$FM_BACKEND_VALIDATED_TARGET
  for ((i=0; i < ${#TEARDOWN_HERDR_ADMITTED_METAS[@]}; i++)); do
    [ "${TEARDOWN_HERDR_ADMITTED_METAS[$i]}" != "$meta" ] \
      || { teardown_herdr_reacquire_meta "$meta" "$task_id" "$state"; return $?; }
  done
  teardown_herdr_preflight_target "$target" "$task_id" || return 1
  identity=$(teardown_herdr_meta_identity "$meta" "$task_id" "$state") || return 1
  fm_backend_herdr_parse_target "$target" || return 1
  session=$FM_BACKEND_HERDR_SESSION
  lock_path=
  while IFS=$'\t' read -r lock_session held_path; do
    [ "$lock_session" != "$session" ] || lock_path=$held_path
  done <<FMEOF
$TEARDOWN_HERDR_LOCK_RECORDS
FMEOF
  [ -n "$lock_path" ] || return 1
  TEARDOWN_HERDR_ADMITTED_METAS+=("$meta")
  TEARDOWN_HERDR_ADMITTED_IDENTITIES+=("$identity")
  TEARDOWN_HERDR_ADMITTED_LOCK_PATHS+=("$lock_path")
}

teardown_herdr_reacquire_meta() {
  local meta=$1 task_id=$2 state=$3 identity target i
  for ((i=0; i < ${#TEARDOWN_HERDR_ADMITTED_METAS[@]}; i++)); do
    [ "${TEARDOWN_HERDR_ADMITTED_METAS[$i]}" = "$meta" ] || continue
    fm_backend_validate_task_endpoint "$meta" "$task_id" || return 1
    [ "$FM_BACKEND_VALIDATED_BACKEND" = herdr ] || return 1
    target=$FM_BACKEND_VALIDATED_TARGET
    teardown_herdr_preflight_target "$target" "$task_id" \
      "${TEARDOWN_HERDR_ADMITTED_LOCK_PATHS[$i]}" || return 1
    identity=$(teardown_herdr_meta_identity "$meta" "$task_id" "$state") || return 1
    if [ "$identity" != "${TEARDOWN_HERDR_ADMITTED_IDENTITIES[$i]}" ]; then
      echo "error: herdr endpoint metadata or spawn generation changed after admission for $task_id; retaining its durable records" >&2
      return 1
    fi
    return 0
  done
  echo "error: herdr task $task_id was not admitted; retaining its durable records" >&2
  return 1
}

preflight_firstmate_home_herdr_children() {  # <home>
  local home=$1 sub_state child_meta child_id child_backend child_kind child_home child_wt
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    fm_backend_validate_task_endpoint "$child_meta" "$child_id" || return 1
    child_backend=$FM_BACKEND_VALIDATED_BACKEND
    if [ "$child_backend" = herdr ]; then
      teardown_herdr_admit_meta "$child_meta" "$child_id" "$sub_state" || return 1
    fi
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    if [ "$child_kind" = secondmate ]; then
      child_wt=$(meta_value "$child_meta" worktree)
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      preflight_firstmate_home_herdr_children "$child_home" || return 1
    fi
  done
}

# endpoint_close_refusal: the one report for an endpoint close that could not
# do its job, wherever a close is attempted, and the one decision about what
# that costs. Reporting such a close as a completed cleanup does not merely
# leave a stray session behind, it STRANDS one: the durable metadata removed
# below is the only record of which endpoint belongs to this task, so nothing
# is left on disk naming what survived. The default is therefore to stop
# without removing the task's records, exactly as the Herdr confirmed-gone
# gates already do for the same hazard. What each backend can actually prove
# about its own close is bin/fm-backend.sh's fm_backend_kill contract.
#
# Returns 0 when the caller must continue anyway and 1 when it must stop.
# <honors-force> is 1 at exactly one site, the generic non-Herdr/non-Orca
# close, where --force is the operator's existing authority to discard this
# task's records deliberately AND continuing is actually reachable: ordinary
# pool return needs Treehouse, not the endpoint backend that could not close.
# Non-pool return may already have completed by then.
# It is 0 everywhere else. The Orca site refuses under --force too, because
# the step immediately after it removes the Orca worktree through the same CLI
# whose absence is the only thing that arm ever reports, so a forced continue
# would die there having removed nothing while this message claimed otherwise.
# The two forced secondmate child sites refuse because that path is only ever
# reached under --force, so honoring force would delete the refusal rather
# than override it, and would contradict the adjacent Herdr child gate that
# stops forced cleanup for this same hazard.
#
# What is retained is this run's records, not a durable guarantee: a task
# carrying a backlog transition already wrote its pending-close marker, and the
# next session start replays that marker and removes the retained record. The
# message says so rather than promising a retention teardown does not own.
endpoint_close_refusal() {  # <subject> <backend> <target> <honors-force>
  local subject=$1 backend=$2 target=$3 honors_force=$4
  echo "error: the $backend endpoint $target for $subject could not be closed, so it may still be live." >&2
  if [ "$honors_force" = 1 ] && [ "$FORCE" = "--force" ]; then
    echo "error: --force authorizes continuing past a close that failed, so this cleanup proceeds toward removing the task's records; reconcile $target yourself, because nothing here can still be relied on to name it." >&2
    return 0
  fi
  echo "error: stopping this cleanup without removing the task's records, so the record naming $target is still here to reconcile from." >&2
  echo "error: that retention is not durable across a session start: if this task carries a backlog transition, the next session replays its pending close and removes the retained record, so reconcile the surviving endpoint yourself rather than trusting the retention." >&2
  if [ "$honors_force" = 1 ]; then
    echo "error: rerun teardown once the close can succeed, or rerun with --force to discard this task's records deliberately." >&2
  fi
  return 1
}

cleanup_firstmate_home_children() {
  local home=$1 sub_state child_meta child_id child_t child_wt child_proj child_kind child_home child_backend child_orca_worktree_id child_return_rc child_busy_gen child_owner_rc child_admission_i child_copy_mode child_keep_copy child_pool_return child_project_lock child_leased child_pool_slot
  sub_state="$home/state"
  [ -d "$sub_state" ] || return 0
  for child_meta in "$sub_state"/*.meta; do
    [ -e "$child_meta" ] || continue
    child_id=$(basename "$child_meta" .meta)
    for ((child_admission_i=0; child_admission_i < ${#TEARDOWN_HERDR_ADMITTED_METAS[@]}; child_admission_i++)); do
      [ "${TEARDOWN_HERDR_ADMITTED_METAS[$child_admission_i]}" = "$child_meta" ] || continue
      teardown_herdr_reacquire_meta "$child_meta" "$child_id" "$sub_state" || return 1
      break
    done
    child_wt=$(meta_value "$child_meta" worktree)
    child_proj=$(meta_value "$child_meta" project)
    child_kind=$(meta_value "$child_meta" kind)
    [ -n "$child_kind" ] || child_kind=ship
    child_backend=$(fm_backend_of_meta "$child_meta")
    child_pool_return=0
    child_keep_copy=0
    if teardown_preserves_reassociated_copy "$child_meta" "$child_kind" "$child_backend" "$child_proj" "$child_wt"; then
      child_keep_copy=1
    fi
    child_copy_mode=1
    [ "$child_kind" != secondmate ] || child_copy_mode=home
    if [ "$child_kind" != secondmate ] && [ "$child_backend" != orca ] \
       && fm_treehouse_pool_slot "$child_proj" "$child_wt"; then
      require_exclusive_worktree_slot_record "$child_meta" "$child_id" "$sub_state" "$child_wt" || return 1
    else
      require_cleanup_copy_clearance "$child_meta" "$child_id" "$sub_state" "$child_wt" "$child_copy_mode" || return 1
    fi
    if [ "$child_backend" = orca ]; then
      child_t=$(meta_value "$child_meta" terminal)
    else
      child_t=$(fm_backend_target_of_meta "$child_meta")
    fi
    if [ "$child_backend" = orca ] && [ "$child_kind" != secondmate ]; then
      child_orca_worktree_id=$(require_orca_worktree_id "$child_meta") || return 1
      if [ -n "$child_wt" ] && [ -e "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      fi
    fi
    child_owner_rc=0
    if [ "$child_kind" != secondmate ] && fm_treehouse_pool_slot "$child_proj" "$child_wt"; then
      require_owned_worktree_slot_record "$child_id" "$child_wt" 2>/dev/null || child_owner_rc=$?
    fi
    if [ "$child_owner_rc" -ne 0 ] && [ "$child_owner_rc" -ne "$TEARDOWN_SLOT_REASSIGNED_RC" ]; then
      require_owned_worktree_slot_record "$child_id" "$child_wt" || return 1
      child_owner_rc=0
    fi
    if [ -n "$child_t" ]; then
      if [ "$child_backend" = herdr ]; then
        fm_backend_herdr_parse_target "$child_t" || return 1
        if ! teardown_herdr_session_lock_held "$FM_BACKEND_HERDR_SESSION"; then
          echo "error: herdr session presentation lock is not held for child $child_id; retaining that child's durable identity records and stopping forced cleanup" >&2
          return 1
        fi
        fm_backend_herdr_kill_serialized "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null || true
        if ! fm_backend_herdr_endpoint_confirmed_gone "$child_t"; then
          echo "error: herdr pane $child_t for child $child_id is not confirmed gone; retaining that child's durable identity records and stopping forced cleanup" >&2
          return 1
        fi
        teardown_release_herdr_locks
      elif [ "$child_backend" = zellij ]; then
        # Zellij titles are scoped by the owning home tag, so forced secondmate
        # cleanup must verify child tabs as that child home, not the parent.
        ( unset FM_ROOT_OVERRIDE; FM_HOME=$home FM_ROOT=$home fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" ) \
          || { endpoint_close_refusal "child $child_id" "$child_backend" "$child_t" 0; return 1; }
      else
        fm_backend_kill "$child_backend" "$child_t" "$(meta_value "$child_meta" zellij_tab_id)" "fm-$child_id" \
          || { endpoint_close_refusal "child $child_id" "$child_backend" "$child_t" 0; return 1; }
      fi
    fi
    if [ "$child_kind" = secondmate ]; then
      child_home=$(meta_value "$child_meta" home)
      [ -n "$child_home" ] || child_home=$child_wt
      require_cleanup_copy_clearance "$child_meta" "$child_id" "$sub_state" "$child_home" home || return 1
    fi
    if [ "$child_owner_rc" -eq "$TEARDOWN_SLOT_REASSIGNED_RC" ]; then
      teardown_docker_stacks "$child_id" "$child_meta" "$sub_state" 1 || return 1
    else
      teardown_docker_stacks "$child_id" "$child_meta" "$sub_state" 0 || return 1
    fi
    if [ "$child_kind" = secondmate ]; then
      if [ -n "$child_home" ] && [ -d "$child_home" ]; then
        cleanup_firstmate_home_children "$child_home" || return $?
        remove_firstmate_home "$child_home" "child firstmate home" "$child_id" "$home/data/secondmates.md" || return $?
      fi
      remove_secondmate_registry_entry "$child_id" "$home/data/secondmates.md" || return 1
    elif [ "$child_backend" = orca ]; then
      if [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
          "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
        fm_backend_remove_worktree "$child_backend" "$child_orca_worktree_id" || return 1
      fi
    elif [ "$child_keep_copy" = 1 ]; then
      :
    elif [ "$child_owner_rc" -eq 0 ] && fm_treehouse_pool_slot "$child_proj" "$child_wt"; then
      child_pool_return=1
      validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
      rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
        "$child_wt/.opencode/plugins/fm-busy-state.js" \
        "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
    elif [ -n "$child_wt" ] && [ -d "$child_wt" ]; then
      # The same ownership determination as the parent's own slot: a child
      # slot reassigned to another task is not this child's to kill, reset,
      # or return, so only its records are cleaned up. The preflight above
      # already named the reassignment under project custody; this records-only
      # route still returns nothing after that custody has been released.
      if [ "$child_owner_rc" -eq "$TEARDOWN_SLOT_REASSIGNED_RC" ]; then
        :
      else
        validate_child_worktree_for_removal "$child_wt" "$child_proj" >/dev/null || return 1
        rm -f "$child_wt/.claude/settings.local.json" "$child_wt/.opencode/plugins/fm-turn-end.js" \
          "$child_wt/.opencode/plugins/fm-busy-state.js" \
          "$child_wt/.fm-grok-turnend" "$child_wt/.fm-kimi-turnend"
        if [ -n "$child_proj" ] && [ -d "$child_proj" ] && command -v treehouse >/dev/null 2>&1; then
          teardown_scrub_scratch_copy "$child_wt" "$child_id" || return $?
          child_pool_slot=0
          fm_treehouse_pool_slot "$child_proj" "$child_wt" && child_pool_slot=1
          if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" "$child_id"; then
            [ "$child_pool_slot" = 0 ] || teardown_note_dirty_return "$child_wt"
            fm_treehouse_slot_owner_release "$child_wt" "$child_id"
          else
            child_return_rc=$?
            if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ] \
               || [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_CUSTODY_REFUSED" ]; then
              return "$child_return_rc"
            fi
            safe_rm_rf_child_worktree "$child_wt" "$child_proj" "$child_id" || return 1
          fi
        else
          safe_rm_rf_child_worktree "$child_wt" "$child_proj" "$child_id" || return 1
        fi
      fi
    fi
    remove_grok_turnend_auth "$sub_state" "$child_id" || return 1
    remove_kimi_turnend_auth "$sub_state" "$child_id" || return 1
    remove_pr_poll_artifacts "$sub_state" "$child_id" || return 1
    child_busy_gen=$(meta_value "$child_meta" busy_gen)
    if [ -z "$child_busy_gen" ]; then
      child_busy_gen=$(cat "$sub_state/$child_id.busy-gen" 2>/dev/null || true)
    fi
    retire_busy_state "$sub_state" "$child_id" "$child_busy_gen" || return 1
    status_retire_presentation_task "$sub_state" "$child_id" || return 1
    fm_wake_queue_prune_task "$sub_state" "$child_id" "$child_t" 2>/dev/null || true
    if [ "$child_pool_return" = 1 ]; then
      teardown_mark_return_pending "$child_wt" "$child_id" || return 1
      if [ "$DESCENDANT_LEGACY_CUSTODY" != 1 ]; then
        child_project_lock=$(fm_treehouse_project_lock_path "$child_proj") || return 1
        # This child's endpoint is already closed, so wait in the FIFO queue
        # rather than strand its reserved slot. Project holders refuse rather
        # than wait for the task-set locks this cleanup holds.
        teardown_project_lock_wait "$child_project_lock" "teardown $ID return child $child_id" || return $?
        DESCENDANT_TREEHOUSE_LOCK_PATHS+=("$child_project_lock")
      fi
      child_owner_rc=0
      require_owned_worktree_slot_record "$child_id" "$child_wt" || child_owner_rc=$?
      case "$child_owner_rc" in
        0|"$TEARDOWN_SLOT_REASSIGNED_RC") ;;
        *) return 1 ;;
      esac
    fi
    if [ "$child_pool_return" = 1 ] && [ "$child_owner_rc" != "$TEARDOWN_SLOT_REASSIGNED_RC" ]; then
      require_exclusive_worktree_slot_record "$child_meta" "$child_id" "$sub_state" "$child_wt" || return 1
      require_registered_slot_copies "$child_id" "$child_wt" || return 1
      child_leased=0
      ! teardown_descendant_slot_leased "$child_wt" || child_leased=1
      if [ "$child_leased" = 1 ]; then
        FM_TASK_COPY_POOL_STATE_FILE=
        FM_TASK_COPY_POOL_STATE_ENTRIES=
        fm_task_copy_pool_slot_held "$child_wt" || {
          echo "REFUSED: child $child_id pool slot is no longer durably reserved; retaining its task record and contents" >&2
          return 1
        }
      fi
      if command -v treehouse >/dev/null 2>&1; then
        # A forced secondmate teardown scrubs every child copy it returns and
        # checks that return for residue, exactly as the parent's own return
        # and the non-pool child return above do; a dirty or unverifiable
        # return is a lost pool slot (exit 4 after cleanup).
        teardown_scrub_scratch_copy "$child_wt" "$child_id" || return $?
        if teardown_treehouse_return "$child_wt" "$child_proj" "child worktree" "$child_id"; then
          teardown_note_dirty_return "$child_wt"
          fm_treehouse_slot_owner_release "$child_wt" "$child_id" || return 1
        else
          child_return_rc=$?
          if [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_LOCK_REFUSED" ] \
             || [ "$child_return_rc" -eq "$TEARDOWN_TREEHOUSE_CUSTODY_REFUSED" ]; then
            return "$child_return_rc"
          fi
          if [ "$child_leased" = 1 ]; then
            echo "REFUSED: child $child_id pool slot is durably leased and its return failed; retaining the slot, its task record and the pending-return record for a retry" >&2
            return 1
          fi
          safe_rm_rf_child_worktree "$child_wt" "$child_proj" "$child_id" || return 1
        fi
      else
        if [ "$child_leased" = 1 ]; then
          echo "REFUSED: child $child_id pool slot is durably leased and treehouse is not installed to return it; retaining the slot, its task record and the pending-return record for a retry" >&2
          return 1
        fi
        safe_rm_rf_child_worktree "$child_wt" "$child_proj" "$child_id" || return 1
      fi
    fi
    fm_backlog_atomic_transition remove "$sub_state/$child_id.meta" "task record" "$sub_state" || return 1
    [ "$DESCENDANT_LEGACY_CUSTODY" = 1 ] || teardown_release_descendant_project_locks || return 1
    rm -f "$sub_state/$child_id.turn-ended" "$sub_state/$child_id.progress" \
      "$(fm_wake_signal_seen_path "$sub_state" "$sub_state/$child_id.turn-ended")" \
      "$sub_state/$child_id.pi-ext.ts" "$sub_state/$child_id.omp-ext.ts" "$sub_state/$child_id.omp-fallback.yml" \
      "$sub_state/$child_id.live-model" \
      "$sub_state/$child_id.omp-session.json" "$sub_state/$child_id.reboot-notice" \
      "$sub_state/$child_id.grok-turnend-token" "$sub_state/$child_id.kimi-turnend-token" \
      "$sub_state/$child_id.muse-session" "$sub_state/$child_id.muse-session-current" \
      "$sub_state/$child_id.cursor-session" "$sub_state/$child_id.reconcile-nudged" \
      "$sub_state/$child_id.claude-settings.json" "$sub_state/$child_id.devin-config.json" \
      "$sub_state/.$child_id.branch-outcome-index"
    chmod u+w "$sub_state/$child_id.git-hooks" 2>/dev/null || true
    rm -rf "$sub_state/$child_id.git-hooks"
  done
}

remove_secondmate_registry_entry() {
  local id=$1 reg=$2 tmp
  [ -f "$reg" ] || return 0
  tmp="$reg.tmp.$$"
  grep -vE "^- $id( |$)" "$reg" > "$tmp" || true
  mv "$tmp" "$reg"
}

teardown_launch_home_token() {
  local home=$1 root hash
  root=$(cd "$home" 2>/dev/null && pwd -P) || root=$home
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  else
    return 1
  fi
  case "$hash" in
    *[!0-9a-fA-F]*|'') return 1 ;;
  esac
  printf '%s' "$hash"
}
LAUNCH_HOME_TOKEN=$(teardown_launch_home_token "$FM_HOME") || LAUNCH_HOME_TOKEN=
# An unresolvable durable parent binding refuses by name before the custody
# walks below, which climb the same parent records and would only report a
# home they cannot resolve.
if [ "$FORCE" != "--force" ] && [ "$PUBLIC_FOLLOWUP_PARENT_UNRESOLVED" = 1 ]; then
  echo "REFUSED: cannot resolve the primary home for marked secondmate $SECOND_MATE_ID; refusing cleanup without its durable parent binding." >&2
  exit 1
fi
require_cleanup_copy_clearance "$META" "$ID" "$STATE" "$TASK_TMP" || exit 1
if [ -n "$LAUNCH_HOME_TOKEN" ]; then
  require_cleanup_copy_clearance "$META" "$ID" "$STATE" "/tmp/fm-$ID+$LAUNCH_HOME_TOKEN" || exit 1
fi

teardown_acquire_project_lock || exit $?
require_owned_task_worktree_slot || exit 1
require_shared_task_worktree_slot || exit 1
if teardown_owns_worktree; then
  require_exclusive_task_worktree_slot || exit 1
fi
teardown_release_project_lock || exit 1
if [ "$KIND" != secondmate ] && teardown_owns_worktree \
   && ! fm_treehouse_pool_slot "$PROJ" "$WT"; then
  require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$WT" || exit 1
fi
# Shared custody permits leaving the root intact, not signalling a nested
# copy another record also owns. Use the same per-copy clearance as the
# ordinary route before any run, launch-agent or process cleanup.
if [ "$KIND" != secondmate ] && [ "$TEARDOWN_SLOT_SHARED" = 1 ] \
    && [ -d "$WT" ] && [ "$(fm_task_copy_canonical_dir "$WT")" != "$TEARDOWN_SHARED_SLOT" ]; then
  require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$WT" || exit 1
fi
teardown_nested_slot prove || exit 1

validate_pr_poll_cleanup "$STATE" "$ID" || exit 1

if [ "$KIND" = secondmate ]; then
  LOCAL_REGISTRY_LOCK=$(secondmate_registry_lock_path "$STATE")
  fm_lock_acquire_wait "$LOCAL_REGISTRY_LOCK" || exit 1
  LOCAL_HANDOFF_LOCK="$STATE/.backlog-handoff-$ID.lock"
  fm_lock_acquire_wait "$LOCAL_HANDOFF_LOCK" || exit 1
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  validate_firstmate_home_for_removal "$HOME_PATH" "secondmate home" "$ID" "$SECONDMATE_REG" >/dev/null || exit 1
  if fm_treehouse_pool_slot "$FM_ROOT" "$HOME_PATH"; then
    require_registered_slot_copies "$ID" "$HOME_PATH" || exit 1
  fi
  if [ "$FORCE" = "--force" ]; then
    preflight_descendant_task_locks "$HOME_PATH" || exit 1
    validate_firstmate_home_children_removal "$HOME_PATH" || exit 1
    require_cleanup_copy_clearance "$META" "$ID" "$STATE" "$HOME_PATH" home || exit 1
    require_cleanup_copy_clearance "$META" "$ID" "$STATE" "$WT" home || exit 1
    if [ "$BACKEND" = herdr ]; then
      teardown_herdr_admit_meta "$META" "$ID" "$STATE" || exit 1
    fi
    preflight_firstmate_home_herdr_children "$HOME_PATH" || exit 1
  fi
  if [ "$FORCE" != "--force" ]; then
    require_cleanup_copy_clearance "$META" "$ID" "$STATE" "$HOME_PATH" 1 || exit 1
    require_cleanup_copy_clearance "$META" "$ID" "$STATE" "$WT" 1 || exit 1
  fi
  handoff_wake_retire_stage_recover "$HOME_PATH" || exit 1
  handoff_wake_retire_validate || exit 1
  pending_replies_recovery_validate initial || exit 1
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" != "--force" ]; then
  SUB_STATE="$HOME_PATH/state"
  if [ -d "$SUB_STATE" ]; then
    for child_meta in "$SUB_STATE"/*.meta; do
      [ -e "$child_meta" ] || continue
      echo "REFUSED: secondmate $ID still has in-flight work in $SUB_STATE." >&2
      echo "Found $(basename "$child_meta"). Let that home finish or explicitly discard with --force." >&2
      exit 1
    done
  fi
  secondmate_unresolved_pending_replies_refuse || exit 1
fi

if [ "$KIND" = secondmate ]; then
  preflight_firstmate_home_process_event_tree "$HOME_PATH" "secondmate home" || exit 1
fi

if [ "$KIND" = secondmate ] && [ "$FORCE" = "--force" ]; then
  preflight_descendant_treehouse_slots || exit 1
  teardown_release_herdr_locks
  cleanup_firstmate_home_children "$HOME_PATH" || exit $?
fi

if [ "$KIND" = scout ] && [ "$FORCE" != "--force" ]; then
  REPORT="$DATA/$ID/report.md"
  if [ ! -f "$REPORT" ] || [ -L "$REPORT" ] || [ ! -s "$REPORT" ]; then
    echo "REFUSED: scout task $ID has no report at $REPORT." >&2
    echo "The report is the work product. Have the crewmate write it, or use --force after explicit discard approval." >&2
    exit 1
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-captain-hold.sh" verify "$ID" >/dev/null; then
    echo "REFUSED: scout task $ID has not passed the captain-call completion gate." >&2
    echo "Inventory its report and any visual review through bin/fm-captain-hold.sh before teardown." >&2
    exit 1
  fi
fi

# A public commitment is not kept until its final reply lands in the ORIGINAL
# thread, and this cleanup removes the task records that make the promise
# reconcilable. Refuse while this home still owes a public reply for exactly this
# work. Both gates live in bin/fm-public-followup-lib.sh, so a home that never
# opted into the myfirstmate relay runs one [ -f ] test and nothing else here.
# The unresolved-parent refusal ran before the custody walks above.
if [ "$FORCE" != "--force" ] \
  && [ -n "$PUBLIC_FOLLOWUP_STATE" ] \
  && [ "$PUBLIC_FOLLOWUP_RELAY_ACTIVE" = 1 ] \
  && fm_pf_has_registrations "$PUBLIC_FOLLOWUP_STATE"; then
  if ! PUBLIC_FOLLOWUP_BLOCKING=$(FM_HOME="$PUBLIC_FOLLOWUP_HOME" FM_STATE_OVERRIDE="$PUBLIC_FOLLOWUP_STATE" \
      "$SCRIPT_DIR/fm-public-followup.sh" guard-work "$PUBLIC_FOLLOWUP_WORK_HOME" "$ID" 2>/dev/null); then
    echo "REFUSED: task $ID still owes a public reply through the myfirstmate relay." >&2
    printf '%s\n' "$PUBLIC_FOLLOWUP_BLOCKING" >&2
    echo "Deliver it with bin/fm-public-followup.sh deliver <obligation-id>, waive it with bin/fm-tasks-axi.sh public-followup waive, or use --force after explicit discard approval." >&2
    exit 1
  fi
fi

# Non-blocking: a delivered public loop is not a teardown refusal (guard-work
# already passed), but tearing down a ship whose PR merged while a loop is still
# open with nothing owed is the moment the drop is detectable.
if [ "$KIND" = ship ] && [ -n "$PR_URL" ] \
    && [ -n "$PUBLIC_FOLLOWUP_STATE" ] \
    && [ "${PUBLIC_FOLLOWUP_RELAY_ACTIVE:-0}" = 1 ] \
    && fm_pf_has_delivered_open_loops "$PUBLIC_FOLLOWUP_STATE"; then
  echo "warning: an open public loop with nothing owed is still recorded in the consent-holding home while cleaning up ship task $ID. Hand it on with bin/fm-public-followup.sh rechain or close it with retire --reason." >&2
fi

# Non-blocking: the legacy Relay link is not guarded as a refusal.
X_REQUEST=$(grep '^x_request=' "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true)
if [ -n "$X_REQUEST" ]; then
  echo "warning: task $ID still carries an unreconciled Relay request link ($X_REQUEST) on its task record." >&2
fi

require_worktree_teardown_safety

TEARDOWN_HERDR_SESSION=
TEARDOWN_HERDR_PANE=
if [ "$BACKEND" = herdr ]; then
  teardown_herdr_admit_meta "$META" "$ID" "$STATE" || exit 1
  fm_backend_herdr_parse_target "$T" || exit 1
  TEARDOWN_HERDR_SESSION=$FM_BACKEND_HERDR_SESSION
  TEARDOWN_HERDR_PANE=$FM_BACKEND_HERDR_PANE
fi
teardown_release_herdr_locks
# Prepare the non-authoritative close record and retire any previous marker
# outside presentation custody. The EXIT trap retires this stage on refusal;
# the legacy stamp and authoritative publication wait for exact reacquisition.
if teardown_is_dropping; then
  TEARDOWN_DROPPING=1
fi
if [ "$FORCE" = "--force" ] && [ -n "$DROP_FILE" ] && [ "$KIND" != secondmate ]; then
  fm_backlog_drop_record "$DATA" "$ID" "$DROP_FILE" || {
    echo "REFUSED: cannot retain the captain's words for $ID; nothing was discarded." >&2
    exit 1
  }
fi

BACKLOG_CLOSED=0
BACKLOG_TRANSITION=$TEARDOWN_BACKLOG_TRANSITION
BACKLOG_TRANSITION_FLAGS=()
[ "$BACKLOG_TRANSITION" = close ] || BACKLOG_TRANSITION_FLAGS=(--retain)
BACKLOG_SKIP_REASON=
if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
  backlog_done_args || {
    echo "error: the pending backlog $BACKLOG_TRANSITION for $ID is not replayable; refusing destructive teardown" >&2
    exit 1
  }
  BACKLOG_CLOSE_MARKER=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
  if ! fm_backlog_record_parent_authorized "$BACKLOG_CLOSE_MARKER" "pending-close record target" "$STATE" \
     || { { [ -e "$BACKLOG_CLOSE_MARKER" ] || [ -L "$BACKLOG_CLOSE_MARKER" ]; } \
          && ! fm_backlog_record_present "$BACKLOG_CLOSE_MARKER" "pending-close record target" "$STATE"; }; then
    echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
    exit 1
  fi
  if ! fm_backlog_close_marker_stage "$STATE/.$ID.backlog-close.${BASHPID:-$$}" \
      "$ID" "$DATA" "$TEARDOWN_META_SPAWN_GEN" "$STATE" 0 \
      "${BACKLOG_TRANSITION_FLAGS[@]+"${BACKLOG_TRANSITION_FLAGS[@]}"}" \
      "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"; then
    echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
    exit 1
  fi
  BACKLOG_CLOSE_STAGE="$STATE/.$ID.backlog-close.${BASHPID:-$$}"
else
  if [ "$CLEANUP_RECOVERY" = orca ]; then
    BACKLOG_SKIP_REASON="Orca cleanup recovery is not a launched backlog worker"
  else
    BACKLOG_SKIP_REASON=$TEARDOWN_BACKLOG_SKIP_REASON
  fi
fi
if ! fm_backlog_close_marker_clear "$STATE" "$ID"; then
  echo "error: the previous pending backlog $BACKLOG_TRANSITION for $ID could not be cleared ($FM_BACKLOG_TRANSITION_ERROR); refusing process cleanup" >&2
  exit 1
fi

# Every landed/discard-work refusal above has now passed (or --force skipped
# them). Fix 1, Fix 3, and Fix 2 (see script header) run here, unconditionally on
# --force, and before ANY destructive step below - a still-parked run, loaded
# private agent, or leaked process can own live work in this exact worktree. Not for
# kind=secondmate: a secondmate home's own runtime lifecycle is owned by the
# dedicated process-event and firstmate-home removal machinery further below,
# not by task-worktree cleanup.
# Every refusal above leaves the slot as it found it. Reserve it under fresh
# project custody only now, immediately before the first destructive step.
if [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ] && teardown_owns_worktree && [ -z "$TEARDOWN_PEER_SLOT" ]; then
  teardown_acquire_project_lock || exit $?
  if ! TEARDOWN_RESERVED_SLOT=$(teardown_live_slot_path); then
    TEARDOWN_RESERVED_SLOT=$(teardown_record_enclosing_slot "$META" "$PROJ" "$WT") || exit 1
    fm_treehouse_slot_owner_state "$TEARDOWN_RESERVED_SLOT" "$ID"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      mine) ;;
      absent) teardown_release_enclosing_slot || exit 1 ;;
      *) require_owned_task_worktree_slot "$TEARDOWN_RESERVED_SLOT" || exit 1 ;;
    esac
  else
    require_owned_task_worktree_slot "$TEARDOWN_RESERVED_SLOT" || exit 1
  fi
  if [ -n "$TEARDOWN_RESERVED_SLOT" ]; then
    require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$TEARDOWN_RESERVED_SLOT" || exit 1
    teardown_reserve_pool_slot "$TEARDOWN_RESERVED_SLOT" || exit 1
    teardown_mark_return_pending "$TEARDOWN_RESERVED_SLOT" || exit 1
  fi
  [ "$TEARDOWN_SLOT_CUSTODY" = project ] || teardown_release_project_lock || exit 1
  teardown_owns_worktree || teardown_reprove_reassigned_slot
fi
if [ "$KIND" != secondmate ] && [ "$TEARDOWN_SLOT_SHARED" = 1 ]; then
  fm_treehouse_slot_owner_state "$TEARDOWN_SHARED_SLOT" "$ID"
  [ "$FM_TREEHOUSE_SLOT_OWNER" != mine ] || teardown_mark_return_pending "$TEARDOWN_SHARED_SLOT" || exit 1
fi
if [ "$KIND" != secondmate ] && teardown_owns_worktree; then
  teardown_nested_slot retire
elif [ "$KIND" != secondmate ] && [ "$TEARDOWN_SLOT_SHARED" = 1 ] \
    && [ -d "$WT" ] && [ "$(fm_task_copy_canonical_dir "$WT")" != "$TEARDOWN_SHARED_SLOT" ]; then
  # Shared custody protects the slot root, not this retiring task's own
  # nested runtime. Keep the ordinary identity proofs on this copy only.
  conclude_task_no_mistakes_run "$WT" || exit 1
  retire_task_private_nm_launch_agents "$WT" || exit 1
  reap_task_worktree_processes worktree "$WT" "$TASK_TMP" || exit 1
  require_worktree_teardown_safety
elif [ "$KIND" != secondmate ]; then
  reap_task_worktree_processes tasktmp "$TASK_TMP"
fi
if [ "$KIND" = ship ] && teardown_owns_worktree && [ -e "$CONFIG/pipeline-spend" ]; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-pipeline-spend.sh" record "$ID" >/dev/null \
    || echo "warning: could not record $ID's no-mistakes pipeline spend; cleanup continues" >&2
fi

# Fix 4 (see script header): keep task identity records and the worktree until
# Docker cleanup succeeds, so a partial removal can be retried.
if [ "$KIND" != secondmate ] && ! teardown_docker_stacks "$ID" "$META" "$STATE" "$TEARDOWN_SLOT_REASSIGNED"; then
  echo "error: stopping this cleanup without removing the task's records, so the Docker objects still named for $ID can be reconciled and a rerun can retry." >&2
  exit 1
fi

if [ "$BACKEND" = herdr ]; then
  teardown_herdr_reacquire_meta "$META" "$ID" "$STATE" || {
    echo "error: teardown stopped before pane mutation; owned task processes may already have stopped, but no pending backlog transition was published" >&2
    exit 1
  }
fi

if [ "$TEARDOWN_BACKLOG_APPLIES" = 1 ]; then
# Roll the accepted legacy incarnation's stamp back to the record's exact
# pre-stamp bytes. Uses perl - already in the teardown lifecycle's curated PATH
# (truncate is not, and is absent on stock macOS) - and verifies the restored
# size before reporting success, so a rollback that cannot be proven complete
# is reported as not rolled back.
teardown_legacy_stamp_rollback() {
  [ "$TEARDOWN_LEGACY_PRESTAMP_SIZE" -gt 0 ] 2>/dev/null || return 1
  perl -e 'truncate($ARGV[0], $ARGV[1]) or exit 1' -- \
    "$META" "$TEARDOWN_LEGACY_PRESTAMP_SIZE" || return 1
  [ "$(wc -c < "$META" | tr -d ' ')" = "$TEARDOWN_LEGACY_PRESTAMP_SIZE" ] || return 1
  teardown_refresh_return_pending
}

  if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
    TEARDOWN_LEGACY_PRESTAMP_SIZE=$(wc -c < "$META" | tr -d ' ')
    TEARDOWN_LEGACY_STAMP_FAILED=
    if [ -s "$META" ] && [ -n "$(tail -c 1 -- "$META" 2>/dev/null)" ]; then
      printf '\n' >> "$META" || TEARDOWN_LEGACY_STAMP_FAILED=newline
    fi
    if [ -z "$TEARDOWN_LEGACY_STAMP_FAILED" ]; then
      printf 'spawn_gen=%s\n' "$TEARDOWN_META_SPAWN_GEN" >> "$META" \
        || TEARDOWN_LEGACY_STAMP_FAILED=append
    fi
    if [ -z "$TEARDOWN_LEGACY_STAMP_FAILED" ] \
       && ! fm_backlog_meta_spawn_gen "$META" "$STATE"; then
      TEARDOWN_LEGACY_STAMP_FAILED=validate
    fi
    if [ -n "$TEARDOWN_LEGACY_STAMP_FAILED" ]; then
      teardown_legacy_stamp_rollback \
        || echo "error: the legacy incarnation stamp on $ID's record could not be rolled back; re-run teardown with --legacy-record after reconciling its endpoint" >&2
      if [ "$TEARDOWN_LEGACY_STAMP_FAILED" = validate ]; then
        echo "error: the stamped legacy incarnation does not validate for $ID ($FM_BACKLOG_TRANSITION_ERROR); refusing destructive teardown" >&2
      else
        echo "error: could not stamp the accepted legacy incarnation into task $ID's record; refusing destructive teardown" >&2
      fi
      exit 1
    fi
    teardown_refresh_return_pending || exit 1
  fi
  if ! fm_backlog_atomic_transition publish "$BACKLOG_CLOSE_STAGE" "$BACKLOG_CLOSE_MARKER" \
      "pending-close record" "$STATE"; then
    if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ] \
       && teardown_legacy_stamp_rollback; then
      echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); the accepted legacy incarnation was rolled back, retaining every durable task record" >&2
    else
      echo "error: the pending backlog $BACKLOG_TRANSITION for $ID could not be recorded ($FM_BACKLOG_TRANSITION_ERROR); retaining every durable task record" >&2
      if [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ] && [ -z "$TEARDOWN_LEGACY_RETAINED_STAMP" ]; then
        echo "error: the legacy incarnation stamp on $ID's record could not be rolled back; re-run teardown with --legacy-record after reconciling its endpoint" >&2
      fi
    fi
    exit 1
  fi
  BACKLOG_CLOSE_STAGE=
  BACKLOG_CLOSED=1
fi

HERDR_PRESENTATION_JOURNAL="$STATE/$ID.herdr-presentation"
# teardown_herdr_journal_orphaned: true when the task's own journal names
# nothing the session-start sweep could still close - a version 1 attempt whose
# token-bearing projected workspace is confirmed gone, or a version 2 binding of
# exactly the recorded pane this teardown proves gone. Unreadable, malformed, or
# otherwise-bound journals, and a version 1 workspace still present or
# unreadable, are not orphans.
teardown_herdr_journal_orphaned() {
  fm_backend_source herdr || return 1
  fm_backend_herdr_projection_journal_snapshot "$HERDR_PRESENTATION_JOURNAL" "$ID" || return 1
  if [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 1 ]; then
    fm_backend_herdr_projection_token_workspace_gone \
      "$TEARDOWN_HERDR_SESSION" "$HERDR_PRESENTATION_JOURNAL" "$ID"
  else
    [ "$FM_BACKEND_HERDR_JOURNAL_SESSION:$FM_BACKEND_HERDR_JOURNAL_PANE_ID" = "$T" ]
  fi
}
HERDR_PRESENTATION_RETIRE_CANDIDATE=0
HERDR_PRESENTATION_SESSION=
HERDR_PRESENTATION_PANE=
if [ "$BACKEND" = herdr ] \
   && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  fm_backend_source herdr || true
  HERDR_PRESENTATION_SESSION=$(meta_value "$META" herdr_session)
  HERDR_PRESENTATION_WORKSPACE=$(meta_value "$META" herdr_workspace_id)
  HERDR_PRESENTATION_PANE=$(meta_value "$META" herdr_pane_id)
  if [ -n "$HERDR_PRESENTATION_SESSION" ] \
     && [ -n "$HERDR_PRESENTATION_WORKSPACE" ] \
     && [ -n "$HERDR_PRESENTATION_PANE" ] \
     && [ "$T" = "$HERDR_PRESENTATION_SESSION:$HERDR_PRESENTATION_PANE" ] \
     && fm_backend_herdr_projection_endpoint_matches_journal \
       "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_WORKSPACE" \
       "$HERDR_PRESENTATION_JOURNAL" "$ID"; then
    HERDR_PRESENTATION_RETIRE_CANDIDATE=1
  fi
fi

if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if teardown_herdr_session_lock_held "$HERDR_PRESENTATION_SESSION"; then
    # stderr is deliberately NOT discarded here. This is the highest-frequency
    # projected-close call site, and the helper's only stderr output is a real
    # warning - unverifiable workspace.move support, a refused focus-unsafe
    # close, an unconfirmed repositioned-workspace removal, or a failed exact
    # restore.
    # Swallowing them left a wrong active workspace with no operator-visible
    # signal at all. The close stays non-fatal exactly as before: the presence
    # gate below is what decides whether any durable record may be removed.
    fm_backend_herdr_projection_close_pane_focus_preserving \
      "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE" || true
  else
    echo "warning: herdr presentation focus lock unavailable; refusing a concurrent focus-unsafe pane close" >&2
  fi
elif [ "$BACKEND" = herdr ]; then
  if teardown_herdr_session_lock_held "$TEARDOWN_HERDR_SESSION"; then
    fm_backend_herdr_kill_serialized "$TEARDOWN_HERDR_SESSION" "$TEARDOWN_HERDR_PANE" 2>/dev/null || true
  else
    echo "warning: herdr session presentation lock path is unavailable; skipping the pane close rather than closing unlocked" >&2
  fi
fi
if [ "$HERDR_PRESENTATION_RETIRE_CANDIDATE" = 1 ]; then
  if [ "$(fm_backend_herdr_pane_agent_state "$HERDR_PRESENTATION_SESSION" "$HERDR_PRESENTATION_PANE")" = dead ]; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: exact herdr task-pane close could not be confirmed for $ID; retaining the presentation journal and attempting no workspace cleanup" >&2
  fi
elif [ "$BACKEND" = herdr ] \
     && { [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; }; then
  echo "warning: herdr presentation journal for $ID was not retired by its close; no workspace cleanup was attempted" >&2
fi
teardown_release_herdr_locks

# Only now, after ordinary landing and runtime cleanup passed, consider this
# task's recovery archives. Forced discard never counts as archive landing.
reap_task_archive_branches

# Best-effort: drop the local task branch so the shared repo does not accumulate refs.
if [ "$BACKEND" = orca ] && [ "$KIND" != secondmate ]; then
  if teardown_owns_worktree && [ -d "$WT" ]; then
    branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$branch" != "HEAD" ]; then
      if git -C "$WT" checkout --detach -q 2>/dev/null; then
        git -C "$WT" branch -D "$branch" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$WT/.claude/settings.local.json" "$WT/.opencode/plugins/fm-turn-end.js" \
      "$WT/.opencode/plugins/fm-busy-state.js" \
      "$WT/.fm-grok-turnend" "$WT/.fm-kimi-turnend"
  fi
  if [ -n "$T_ORCA" ]; then
    fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" \
      || { endpoint_close_refusal "$ID" "$BACKEND" "$T" 0; exit 1; }
  fi
  if teardown_owns_worktree && [ -d "$WT" ]; then
    fm_backend_remove_worktree "$BACKEND" "$ORCA_WORKTREE_ID"
  fi
elif [ "$KIND" != secondmate ] && ! teardown_owns_worktree; then
  if [ "$TEARDOWN_SLOT_SHARED" = 1 ]; then
    TEARDOWN_DEFERRED_POOL_CLEANUP=shared
  fi
elif [ "$KIND" != secondmate ] && [ -n "$TEARDOWN_PEER_SLOT" ]; then
  if [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ]; then
    TEARDOWN_DEFERRED_POOL_CLEANUP=peers
  else
    teardown_nested_slot return
  fi
elif [ "$TEARDOWN_KEEP_COPY" = 1 ] && [ -z "$TEARDOWN_ENCLOSING_SLOT" ]; then
  :
elif { [ -d "$WT" ] || [ -n "$TEARDOWN_ENCLOSING_SLOT" ]; } && [ "$KIND" != secondmate ]; then
  if [ "$TREEHOUSE_SLOT_LOCK_REQUIRED" = 1 ]; then
    TEARDOWN_DEFERRED_POOL_CLEANUP='return'
  else
    teardown_nested_slot return
  fi
fi

if [ "$BACKEND" != herdr ] && [ "$BACKEND" != orca ] && [ "$TEARDOWN_WINDOWLESS" != 1 ]; then
  fm_backend_kill "$BACKEND" "$T" "$(meta_value "$META" zellij_tab_id)" "fm-$ID" \
    || endpoint_close_refusal "$ID" "$BACKEND" "$T" 1 || exit 1
fi
# A refused, skipped, or failed Herdr close must never erase a live task's
# durable endpoint identity: unless the exact pane is confirmed gone, retain
# every record and stop before any removal below so a later rerun can retry
# the locked close. Only a structured not-found proves the pane gone; unknown
# presence, missing or malformed endpoint identity, and missing confirmation
# machinery all refuse.
if [ "$BACKEND" = herdr ]; then
  fm_backend_source herdr || true
  if ! declare -F fm_backend_herdr_endpoint_confirmed_gone >/dev/null 2>&1; then
    echo "error: herdr endpoint confirmation is unavailable for $ID; retaining every durable task record" >&2
    exit 1
  fi
  if ! fm_backend_herdr_endpoint_confirmed_gone "$T"; then
    echo "error: herdr pane $T for $ID is not confirmed gone after its close was refused, skipped, or failed; retaining every durable task record - rerun teardown once the close can run under the session lock" >&2
    exit 1
  fi
fi
if [ "$KIND" != secondmate ]; then
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-inactive-reconcile.sh" report "$ID"; then
    echo "error: $ID's final outcome has not reached the parent channel; retaining every durable task record so a rerun can retry the delivery" >&2
    exit 1
  fi
fi
if [ "$KIND" = secondmate ]; then
  [ -n "$HOME_PATH" ] || HOME_PATH=$WT
  handoff_wake_retire_stage \
    || { echo "error: receiver wake cleanup could not be staged; preserving the secondmate home and route" >&2; exit 1; }
  pending_replies_recovery_validate recheck \
    || { echo "error: local pending-reply recovery paths changed; preserving the secondmate home and route" >&2; exit 1; }
  if remove_firstmate_home "$HOME_PATH" "secondmate home" "$ID" "$SECONDMATE_REG"; then
    :
  else
    rc=$?
    handoff_wake_retire_stage_restore \
      || echo "error: receiver wake restoration failed; recovery state remains at $HANDOFF_WAKE_RETIRE_STAGE" >&2
    exit "$rc"
  fi
  handoff_wake_retire_stage_commit \
    || { echo "error: receiver wake cleanup failed; preserving the secondmate route for retry" >&2; exit 1; }
  if [ "$PENDING_REPLIES_DIR_PRESENT" -eq 1 ]; then
    pending_replies_cleanup_for_task "$STATE/pending-replies" "$PENDING_REPLIES_DIR_REAL" \
      || { echo "error: local pending-reply cleanup failed; preserving the secondmate route for retry" >&2; exit 1; }
  fi
  remove_secondmate_registry_entry "$ID" "$SECONDMATE_REG" || exit 1
fi
remove_grok_turnend_auth "$STATE" "$ID" || exit 1
remove_kimi_turnend_auth "$STATE" "$ID" || exit 1
fm_backend_clear_transition "$BACKEND" "$STATE" "$T" || true
# Remove the per-task temp root (/tmp/fm-<id>/, incl. its gotmp/) recorded by spawn.
# Read before the state-file rm below; empty (pre-fix tasks without tasktmp=) is a no-op.
[ -n "$TASK_TMP" ] && rm -rf "$TASK_TMP"
# Retire only this Firstmate home's launch namespace. Its never-reused per-spawn
# files leave the equal task-id namespace of every other home untouched.
if [ -n "$LAUNCH_HOME_TOKEN" ]; then
  rm -rf "/tmp/fm-$ID+$LAUNCH_HOME_TOKEN"
fi
remove_pr_poll_artifacts "$STATE" "$ID" || exit 1
retire_busy_state "$STATE" "$ID" "$BUSY_GEN" || exit 1
# Opt-in fleet activity ledger (docs/fleet-ledger.md), before the status log is
# retired so its last lines are captured; off costs one file test.
[ ! -e "$CONFIG/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE FM_CONFIG_OVERRIDE=$CONFIG "$SCRIPT_DIR/fm-fleet-ledger.sh" cleaned_up "$ID" || true
status_retire_presentation_task "$STATE" "$ID" || exit 1
fm_wake_queue_prune_task "$STATE" "$ID" "$T" 2>/dev/null || true
rm -f "$STATE/$ID.turn-ended" "$STATE/$ID.progress" \
  "$(fm_wake_signal_seen_path "$STATE" "$STATE/$ID.turn-ended")" \
  "$STATE/$ID.pi-ext.ts" "$STATE/$ID.omp-ext.ts" "$STATE/$ID.omp-fallback.yml" "$STATE/$ID.live-model" \
  "$STATE/$ID.grok-turnend-token" \
  "$STATE/$ID.omp-session.json" "$STATE/$ID.reboot-notice" \
  "$STATE/$ID.kimi-turnend-token" "$STATE/$ID.muse-session" \
  "$STATE/$ID.muse-session-current" "$STATE/$ID.cursor-session" \
  "$STATE/$ID.control-relaunch" "$STATE/$ID.control-relaunch.meta-prior" \
  "$STATE/$ID.control-relaunch.brief-prior" "$STATE/$ID.control-relaunch.note" \
  "$STATE/$ID.reconcile-nudged" "$STATE/$ID.gemini-settings.json" \
  "$STATE/$ID.claude-settings.json" "$STATE/$ID.devin-config.json" \
  "$STATE/.$ID.branch-outcome-index" \
  "$STATE/.secondmate-relaunch-$ID" "$STATE/.secondmate-relaunch-bound-$ID" \
  "$STATE/$ID.control-exit" "$STATE/.session-end-relaunch-$ID" "$STATE/.session-end-handled-$ID" \
  "$STATE/.session-launch-refused-$ID"
# The steering inbox (bin/fm-task-inbox-lib.sh) is runtime state for the
# retired endpoint; teardown only runs after landing is confirmed, so any
# leftover unhandled steer here is moot rather than unlanded work.
# state/<id>.git-hooks is the spawn-owned commit-msg strip directory, left
# read-only by its installer.
chmod u+w "$STATE/$ID.git-hooks" 2>/dev/null || true
rm -rf "$STATE/$ID.inbox" "$STATE/$ID.git-hooks" "$STATE/.nm-read-cache-$ID"
# A presentation journal the close path left behind is orphaned once the
# recorded pane is proven gone (the Herdr gate above) unless it still names a
# live projected workspace - a version 2 binding of some other pane, or a
# version 1 attempt whose token-bearing workspace is still present - which the
# session-start sweep alone may judge (header).
if [ -e "$HERDR_PRESENTATION_JOURNAL" ] || [ -L "$HERDR_PRESENTATION_JOURNAL" ]; then
  if teardown_herdr_journal_orphaned; then
    rm -f "$HERDR_PRESENTATION_JOURNAL"
  else
    echo "warning: retaining herdr presentation journal for $ID; it still names a projected workspace the session-start sweep owns, not the closed endpoint" >&2
  fi
fi
# Slow endpoint, reporting and status work is complete. Return the reserved
# slot and retire its record in one pool critical section: publishing an
# available slot while its old record still names it would let the next holder
# see a false shared-slot collision. Backlog completion and clone sync need
# only task custody and run after project custody is released.
if [ -n "$TEARDOWN_DEFERRED_POOL_CLEANUP" ]; then
  teardown_mark_return_pending "${TEARDOWN_RETURN_SLOT:-${TEARDOWN_PEER_SLOT:-$TEARDOWN_SHARED_SLOT}}" || exit 1
  if [ "$TEARDOWN_DEFERRED_POOL_CLEANUP" = return ] || [ "$TEARDOWN_DEFERRED_POOL_CLEANUP" = peers ]; then
    TEARDOWN_PROOF_OUTCOME="earlier cleanup steps already ran, but nothing was removed and the slot keeps its contents; --force does not waive this proof"
    teardown_nested_slot reprove || exit 1
    teardown_foreign_copies_release || exit 1
    [ ! -d "$WT" ] || require_worktree_teardown_safety
    teardown_own_locked_copies_release || exit 1
  fi
  [ "$TREEHOUSE_PROJECT_LOCK_HELD" = 1 ] || teardown_acquire_project_lock wait || exit $?
  if [ "$TEARDOWN_DEFERRED_POOL_CLEANUP" = shared ]; then
    # Drop only this task's claim, never the remaining task's durable lease.
    fm_treehouse_slot_owner_release "$TEARDOWN_SHARED_SLOT" "$ID"
    fm_treehouse_slot_owner_state "$TEARDOWN_SHARED_SLOT" "$ID"
    if [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] || [ "$FM_TREEHOUSE_SLOT_OWNER" = unsafe ]; then
      echo "error: could not release task $ID's shared-slot claim; retaining its task record for a retry" >&2
      exit 1
    fi
  elif [ "$TEARDOWN_DEFERRED_POOL_CLEANUP" = peers ]; then
    # Dirt or HEAD may change while the final pool admission queues; repeat the
    # local proof under custody, as the return does, before the copy goes.
    [ ! -d "$WT" ] || validate_worktree_teardown_safety || exit 1
    teardown_nested_slot return
  else
    TEARDOWN_DEFERRED_RETURN_SLOT=$TEARDOWN_RETURN_SLOT
    require_owned_task_worktree_slot "$TEARDOWN_RETURN_SLOT" || exit 1
    if ! teardown_owns_worktree; then
      teardown_reprove_reassigned_slot
    elif [ -n "$TEARDOWN_DEFERRED_RETURN_SLOT" ] && [ -z "$TEARDOWN_RETURN_SLOT" ]; then
      :
    else
      require_exclusive_worktree_slot_record "$META" "$ID" "$STATE" "$TEARDOWN_RETURN_SLOT" || exit 1
      if [ "$TEARDOWN_SLOT_CUSTODY" != project ]; then
        FM_TASK_COPY_POOL_STATE_FILE=
        FM_TASK_COPY_POOL_STATE_ENTRIES=
        fm_task_copy_pool_slot_held "$TEARDOWN_RETURN_SLOT" || {
          echo "REFUSED: reserved pool slot $TEARDOWN_RETURN_SLOT lost its durable lease; retaining the task record and contents" >&2
          exit 1
        }
      fi
      # Dirt or HEAD may change while the final pool admission queues. Repeat
      # the local proof under custody; an uncached HEAD refuses without fetching
      # and an index lock refuses without sleeping or retrying here.
      [ ! -d "$WT" ] || validate_worktree_teardown_safety || exit 1
      teardown_nested_slot return
    fi
  fi
  fm_backlog_atomic_transition remove "$META" "task record" "$STATE" || exit 1
  TEARDOWN_META_REMOVED=1
  teardown_release_project_lock || exit 1
fi
# The record is gone, so the backlog must not still show this task in flight
# when teardown reports success. Still under this task's meta lock, so a steer
# racing the same id stays serialized exactly as it was before. A captain-held
# row takes the retain transition here instead of the close: same record, same
# ordering, the row returns to Queued with its deliverable recorded.
TEARDOWN_CLOSE_META=$META
[ "$TEARDOWN_META_REMOVED" != 1 ] || TEARDOWN_CLOSE_META=
if [ "$BACKLOG_CLOSED" = 1 ]; then
  if ! fm_backlog_atomic_transition "$BACKLOG_TRANSITION" "$TEARDOWN_CLOSE_META" "$BACKLOG_CLOSE_MARKER" \
      "$DATA" "$ID" "$STATE" "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    if [ "$BACKLOG_TRANSITION" = retain ]; then
      echo "error: $ID's endpoint and local copy are cleaned up, but its captain-held backlog item could not be returned to Queued atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending retention is recorded and the next session start retries it" >&2
    else
      echo "error: $ID's endpoint and local copy are cleaned up, but its backlog item could not be closed atomically ($FM_BACKLOG_TRANSITION_ERROR); the pending close is recorded and the next session start retries it" >&2
    fi
    exit 1
  fi
elif [ "$KIND" = secondmate ] && [ ! -e "$STATE" ] && [ ! -L "$STATE" ]; then
  # A nested remote retirement can keep its route record inside the home being
  # removed. remove_firstmate_home above already performed that physical
  # deletion; do not turn its confirmed absence into a false cleanup failure.
  :
else
  if ! fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE"; then
    fm_lock_release "$META_LOCK"
    META_LOCK_HELD=0
    echo "error: $ID's endpoint and local copy are cleaned up, but its task record could not be removed ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
fi
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
# Opt-in fleet activity ledger (docs/fleet-ledger.md): the item is now Done, so
# record when it closed and on what evidence. A retained (captain-held) item
# returned to Queued is not a completion and writes nothing. A close the next
# session start replays is recorded there instead (bin/fm-backlog-transition-lib.sh).
if [ "$BACKLOG_CLOSED" = 1 ] && [ "$BACKLOG_TRANSITION" = close ]; then
  fm_backlog_ledger_closed "$STATE" "$CONFIG" "$ID" "${BACKLOG_DONE_ARGS[@]+"${BACKLOG_DONE_ARGS[@]}"}"
fi
rm -f "$STATE/$ID.teardown-return-pending"
[ "$TEARDOWN_POOL_SLOT_LOST" != 0 ] || teardown_friction_outcome completed
if [ "$KIND" != scout ] && [ "$KIND" != secondmate ] && [ "$MODE" != local-only ] \
    && teardown_owns_worktree; then
  "$FM_ROOT/bin/fm-fleet-sync.sh" "$PROJ" || true
fi
# A secondmate retirement may remove the home containing an overridden control
# state directory. Do not let the side-band refresh recreate that retired home.
if [ -d "$STATE" ]; then
  "$SCRIPT_DIR/fm-home-summary-refresh.sh" --detach || true
fi
if [ "$TEARDOWN_POOL_SLOT_LOST" = 1 ]; then
  echo "teardown $ID finished its cleanup and removed its task record, but a returned pool slot did not come back clean (see the warning above); clear those paths so the pool can reuse the slot" >&2
elif [ "$TEARDOWN_LEGACY_ACCEPTED" = 1 ]; then
  echo "teardown $ID complete (window ${T:-none}, worktree $WT, legacy record accepted without spawn_gen: endpoint $TEARDOWN_LEGACY_ENDPOINT, incarnation $TEARDOWN_META_SPAWN_GEN)"
elif [ "$TEARDOWN_SLOT_SHARED" = 1 ]; then
  echo "teardown $ID complete (window ${T:-none}; shared pool slot $TEARDOWN_SHARED_SLOT and every copy inside it left untouched; only this task's own slot claim, if present, released)"
elif [ -n "$TEARDOWN_PEER_SLOT" ] && teardown_owns_worktree; then
  echo "teardown $ID complete (window ${T:-none}; nested reassociated worktree $WT removed; pool slot $TEARDOWN_PEER_SLOT left in place, since task ${TEARDOWN_PEER_IDS[*]} still works in it)"
elif [ -n "$TEARDOWN_ENCLOSING_SLOT" ] && teardown_owns_worktree; then
  echo "teardown $ID complete (window ${T:-none}; nested reassociated worktree $WT removed and its pool slot $TEARDOWN_ENCLOSING_SLOT returned)"
elif [ "$TEARDOWN_KEEP_COPY" = 1 ] && [ -n "$TEARDOWN_RECORD_SLOT" ] && [ ! -d "$WT" ]; then
  echo "teardown $ID complete (window ${T:-none}; nested reassociated worktree $WT was already removed by an earlier teardown, and its pool slot $TEARDOWN_RECORD_SLOT is no longer this task's, so it was left alone)"
elif [ "$TEARDOWN_KEEP_COPY" = 1 ]; then
  echo "teardown $ID complete (window ${T:-none}; reassociated worktree $WT left in place, since it is not a pool slot)"
elif teardown_owns_worktree; then
  echo "teardown $ID complete (window ${T:-none}, worktree $WT)"
else
  echo "teardown $ID complete (window ${T:-none}; pool slot $WT left to task $TEARDOWN_SLOT_REASSIGNED_TO${TEARDOWN_SLOT_REASSIGNED_HOME:+ (home $TEARDOWN_SLOT_REASSIGNED_HOME)}, which it was reassigned to)"
fi
for teardown_prior_copy in ${TEARDOWN_PRIOR_COPIES[@]+"${TEARDOWN_PRIOR_COPIES[@]}"}; do
  echo "notice: $ID's prior copy $teardown_prior_copy (from a reassociation) was left untouched; return or remove it only after confirming its contents are landed or unwanted"
done
backlog_refresh_reminder
[ "$TEARDOWN_POOL_SLOT_LOST" = 0 ] || exit "$TEARDOWN_LOST_SLOT_EXIT"
