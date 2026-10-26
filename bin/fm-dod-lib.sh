#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block and of
# the named-head reachability gate that accepts a ship `done:` claim.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> [branch] [<forge>] [<base>] [<consent>] [<brief>]
# prints the block on stdout with no trailing blank line. The caller validates the
# mode; an unknown mode is refused rather than silently rendered as the pipeline
# contract.
# The optional third argument is the task's full ship-branch name (a project's
# registered prefix may replace the legacy `fm/` one); it defaults to `fm/<task-id>`
# and is the immutable task branch rendered in every delivery contract.
# The optional fifth argument is the task's base branch from bin/fm-brief.sh
# --base-branch; empty means the repository default. A named base is the branch
# the worker starts from, never pushes to, and targets with its pull request, and
# fm_base_branch_valid refuses it where no pull request carries the work.
# The optional sixth argument is the task's recorded upstream consent for a
# firstmate-repository contribution (bin/fm-role-lib.sh owns the boundary): a
# captain-approved <host>/<owner>/<repo> publication scope for this one task,
# rendered as an `upstream-consent=<scope>` suffix token on the Delivery
# contract line so brief, spawn record, and worker instructions agree.
# The seventh argument is the durable task brief used to build the separate
# verification plan; it is required for mode=no-mistakes, which refuses to
# render without it, and unused by the other modes.
# Callers of the gate are bin/fm-crew-state.sh (current-state done),
# bin/fm-pr-check.sh (PR registration), and bin/fm-inactive-reconcile.sh
# (secondmate ledger-first publish of a child done). A ship `done:` is not
# accepted while the named head exists only in the worker's disposable copy.
# The check tests that head, not whether some branch moved. In no-mistakes
# mode the pre-validation `done: {summary}` is the pipeline handoff and is
# not gated; only the later CI-ready `done: PR <url> checks green` is, or on a
# Gerrit project the later `done: PR <change url> published for review`. The
# named head is the worker copy's HEAD, except that a done naming the task's
# recorded pr= passes when the forge holds that head: a forge-reported
# pr_head= in no-mistakes mode, or a recorded merge
# (state/<id>.pr-poll-merge-notified). A push to Gerrit's refs/for/ leaves no
# ref a fetch can see, so a done naming a Gerrit change skips the remote-tracking
# reachability test entirely: it passes when that change is already the task's
# recorded pr=, which bin/fm-pr-check.sh writes only after this gate accepted it
# at arming, and otherwise only when forge reads are enabled and a live read shows
# the change's current patch set carrying the worker copy's HEAD tree.
# FM_CREW_STATE_NO_FORGE=1 preserves recorded local proof but refuses an unrecorded
# Gerrit publication before any live completion query; callers must not treat that
# refusal as working or completed. Ordinary forge-backed proof is unchanged when unset.
# A published-for-review report whose URL is not a canonical Gerrit change is refused outright. A squash is a new commit on the
# server's base, so the tree rather than the commit is what names the published
# content. In no-mistakes mode that live read is preceded by
# fm_dod_nm_custody_returned: a copy that publishes before recovering the
# pipeline's fix commits agrees with its own unfixed patch set, so the copy must
# also hold the result of a passed run. These live reads are the one check at the ready
# decision; a later rebase or patch set on the server does not revoke an armed
# task's done. Teardown's landed-work test remains the complete discard gate.
# At merge time bin/fm-pr-check.sh asks fm_dod_task_owns_several_prs first: a
# task that owns several PRs is judged on the head the forge reports for the PR
# the merge call names, not on the worker copy's HEAD, which rests on another
# PR or a local tip there; a single-PR task and a ready claim are not.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against; a forge=gerrit block
# appends " forge=gerrit shape=squash" to that line and a forge=forgejo block
# appends " forge=forgejo". The "Ship branch: <branch>"
# line under it is machine-readable the same way: bin/fm-spawn.sh refuses a ship
# whose spawn-selected branch disagrees with it.
# forge is none|gerrit|forgejo and defaults to none; bin/fm-project-mode.sh's
# header owns what the registry binding means, and this file owns what each
# forge changes for a WORKER (docs/gerrit-forge-integration.md is the gerrit
# design). In the Definition of done, forgejo changes only the CLI a direct-PR
# worker opens its pull request with: tea instead of gh-axi. A forge composes with
# the two modes that publish and is refused on local-only, which publishes
# nothing. On gerrit the worker publishes one squashed change with
# `gerrit-axi publish --squash` instead of opening a pull request: direct-PR does
# that straight away, and no-mistakes first runs the pipeline with its three
# forge-facing steps skipped and recovers the pipeline's own fix commits into its
# branch, because a passed run whose fixes stayed in the gate looks exactly like
# one whose fixes arrived and publishing it ships the unfixed code. Either mode's
# ready report is `done: PR <change url> published for review`; under
# no-mistakes a `note:` line listing each pipeline finding and its fix comes
# first, because the squash's description never shows the fix commits. A stack of
# changes is refused until it can be watched by its membership pinned when its
# watch is armed, because the merge poll watches one change. No contract here
# lets a worker submit, vote on, or abandon a change.
# The two PR-based blocks require a non-draft pull request before the done
# report, read back from the forge; a lane that deliberately holds a draft
# declares a paused wait instead. bin/fm-pr-check.sh refuses to arm merge
# monitoring on a draft through the same reading bin/fm-pr-merge.sh uses.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs.
# Author the subsection body and later relays as the actual words, without
# adding speaker labels or direct address: the heading supplies provenance and
# is not part of --intent. A legacy mixed Task instead marks each captain line
# with `[captain] `; the selector returns its words, not that metadata prefix.
# That selector skips fenced blocks and indented examples like the heading
# reader, so a quoted `Captain:` sample is never authorized intent.
# Previously stored speaker labels remain readable for compatibility only.
# Never scrub literal examples or other content the captain actually supplied.
# The string passed must be self-sufficient - it plus the codebase reconstructs
# roughly the same specification - so a report, decision, or PR the intent
# refers to is written into it as substance, never left as a pointer.
# bin/fm-brief.sh scaffolds those two `# Task` subsections; bin/fm-spawn.sh and
# bin/fm-promote.sh refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders
# and a `## Captain's intent` line opening with a Captain label or address
# through the helpers below. Other mentions of `--intent` point here rather than
# restating the rule.
# Executable interface: bash bin/fm-dod-lib.sh --verification-plan <brief>
# prints a verification plan for no-mistakes' --verification-plan FILE input.
# It keeps task criteria and scope evidence separate from --intent and renders
# docs/review-rubric.md, the one rubric owner also used by independent readers.
# Task DoD content includes nested headings up to ## How You're Graded; an
# unfenced DoD file directive selects that file's contents instead of the inline
# scaffold, matching the criteria check, and never passes only its path.
# Exclusions are gathered from the unfenced lines of every ### Out of scope
# subsection and every legacy column-0 Out of scope: paragraph in # Task
# (including its following list until a blank line), each printed once in order.
# Other spellings, such as a `- Out of scope:` list item, are not extracted.
# A promoted brief, marked by its # Current ship Firstmate spec heading, labels
# that DoD and those exclusions as scout-time context; the promoted ship intent
# governs where they conflict.
# Absent criteria are explicit; an unrecognized exclusion list never claims none
# exist and sends the reviewer to the Firstmate spec. Unreadable briefs, criteria
# files or the shared rubric refuse construction rather than silently dropping
# evidence.
# CRLF briefs and criteria are accepted; NUL-bearing input is refused by path.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).
# fm_brief_worker_role owns the ship/scout role scope. bin/fm-spawn.sh is its one
# emitter, supplying it first in every ship/scout launch brief and never to a
# secondmate charter. It names the one task-owned steering inbox without
# relaxing isolation from every other home's endpoint namespace. Like
# fm_brief_intent_overlay it is a distinctly titled launch section that states
# its own precedence, so a brief or project instruction that authors a
# conflicting role is superseded rather than duplicated.
# The code root argument is the Firstmate checkout that holds
# .agents/skills/firstmate-coding-guidelines/SKILL.md. A worker in a Firstmate
# worktree loads that skill by name from its own checkout. A worker whose
# session does not register the skill, such as one in another project's
# worktree, cannot, so the role also names the file as the fallback to read;
# the Claude launch grants the skills directory that holds it.
# It renders docs/review-rubric.md for independent review readers rather than
# pointing at it, because that file is outside the Claude and Rovo read grants;
# a missing rubric fails the role render instead of dropping the criteria.
# The task-specific Definition of Done is the second half of a ship or scout
# brief's completion contract: fm_task_dod_block prints the two sections
# bin/fm-brief.sh scaffolds after the delivery contract above ("## Definition Of
# Done (task)" with five placeholders Firstmate fills from the captain's intent,
# and the fixed "## How You're Graded"), and fm_brief_task_dod_problem is the
# check bin/fm-spawn.sh refuses a leftover placeholder with, on a fresh spawn
# only: a relaunch never runs it. The check reads every line from that title to
# the "## How You're Graded" line whatever heading levels sit between, and
# matches a placeholder only where the scaffold puts it (a line holding the
# token alone, or the end of the "Capability in plain words:" line). An
# unfenced "DoD file: <absolute path>" line inside that same span, naming an
# existing file that passes the same placeholder check, is the one narrow escape; the
# line anywhere else in the brief is ignored. A secondmate charter never reaches
# the check because it carries no such sections. A brief with no such section at
# all (scaffolded before it existed) is not refused: a fresh spawn warns once and
# the supervision sweep reports a missing or placeholder section instead of
# inventing criteria.
# fm_brief_dispatch_problems is the single dispatch verdict over the same brief:
# it prints every unfinished Task body and every leftover Definition of Done
# placeholder in one pass, in the order an operator fills them, so a half-filled
# scaffold costs one refusal instead of one round trip per token. bin/fm-spawn.sh
# prints that list as one refusal with the repair, and bin/fm-promote.sh calls it
# with the task-only scope it already enforced; fm_brief_task_dod_problem remains
# the single-problem reading used by bin/fm-live-lab.test.sh and by tests.
# A relaunch re-checks only the Task bodies, because the Definition of Done was
# accepted at the fresh spawn and is never re-litigated.
# fm_ship_rule_one owns the mode-specific first ship safety rule shared by an
# ordinary ship brief and the durable contract written during scout promotion.
# It takes the same optional forge and base arguments as fm_dod_block, because
# both the publication path and its target determine where a worker may push.

# shellcheck source=bin/fm-pr-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-pr-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-brief-heading-lib.sh"

fm_brief_worker_role() {  # <state-dir> <task-id> <code-root>
  local state=$1 task_id=$2 root=$3
  cat <<'EOF'
# Current worker role contract
You are a crewmate: an autonomous worker agent managed by firstmate.
This section establishes your current identity before every project or task instruction below and supersedes any conflicting role identity in those instructions.
Do the assigned work yourself and report only to firstmate; do not adopt a firstmate or secondmate supervisor identity, delegate the task, run fleet supervision, or address the captain.
EOF
  printf "Your steering inbox is \`%s/%s.inbox\`; this exact path belongs to your current task even when it is outside the worktree or under the supervising firstmate home, so read and acknowledge its messages as individually announced by native launch or inbox doorbells and do not reject it as another home's state.\n" "$state" "$task_id"
  cat <<'EOF'
Never inspect or change any other home's endpoint namespace; this authorization is limited to the exact task paths named by this brief.
When this task works on Firstmate itself, the repository root `AGENTS.md` (also imported by `CLAUDE.md`) is project content and the supervisor contract for the firstmate managing you: follow this brief instead of that supervisor contract.
Project instructions still govern the work wherever they do not conflict with this worker identity, including `CONTRIBUTING.md` and `firstmate-coding-guidelines` for Firstmate changes.
EOF
  printf "If the \`firstmate-coding-guidelines\` skill name does not resolve in this session, read \`%s/.agents/skills/firstmate-coding-guidelines/SKILL.md\` instead.\n" "$root"
  printf '%s\n\n' "When assigned an independent review, apply the shared review rubric below, rendered from \`$root/docs/review-rubric.md\`, against the reviewed task's DoD and exclusions; obtain that task's brief or verification plan from firstmate if it was not supplied."
  cat "$root/docs/review-rubric.md"
}

# Launch-only scope override; the original instructions remain recovery context
# rather than execution authority, including their Setup and Definition of done.
fm_brief_reconciliation_role() {
  cat <<'EOF'

# Current reconciliation-only recovery contract
This section supersedes every instruction below that would advance the task, including Setup, progress notes, validation, and Definition of done.
You are recovering an exited instruction owner, not resuming implementation.
The original task instructions below are historical context only until the lock-owning main Firstmate clears recovery with `fm-control <task-id> authorize-continuation` after reconciling the real hold and dependency state.
Read and acknowledge the task-owned instruction inbox's individually announced records in numeric order, wait for unannounced records' own doorbells, reconcile the preserved local files, commits, prior results, and outstanding decisions, then report the factual outcome and wait.
Do not edit project files, create a branch or commit, run implementation or validation, start or respond to no-mistakes, push, open or merge a PR, clear a dependency, or lift a hold.
A relaunch, a restored agent, an older progress note, and a dependency becoming green are not clearance.
If any inbox instruction would advance blocked work or conflicts with a real hold, report that conflict to firstmate without executing it.
Only that explicit metadata clearance followed by a new firstmate continuation instruction can end this recovery-only scope; message text alone is not clearance.

# Preserved task context - not execution authority
EOF
}

# Closed-set gate shared by every forge-aware renderer and bin/fm-brief.sh, so a
# caller cannot reach a half-rendered contract. local-only is refused rather than
# rendered with an inert annotation: it publishes nothing, and its landing
# fast-forwards local main with content the review server has never seen.
fm_forge_valid_for_mode() {  # <forge> <mode> <caller>
  local forge=$1 mode=$2 caller=$3
  case "$forge" in
    none|gerrit|forgejo) ;;
    *)
      echo "error: $caller: unknown forge '$forge' (expected none, gerrit, or forgejo)" >&2
      return 1 ;;
  esac
  if [ "$forge" != none ] && [ "$mode" = local-only ]; then
    echo "error: $caller: forge=$forge cannot ship mode=local-only - that mode publishes nothing, so a forge has no meaning there, and its landing would fast-forward local main with content the review server has never seen; ship no-mistakes or direct-PR, which publish through the forge" >&2
    return 1
  fi
  return 0
}

# A task's optional base branch replaces the repository default as the branch
# its copy starts from and its pull request targets. bin/fm-brief.sh records it
# as a "Base branch: <name>" line under the brief's `# Setup` heading,
# bin/fm-spawn.sh takes it as --base-branch, refuses a brief whose Base branch
# lines (fm_brief_base_branches) disagree, and records base_branch= in the task
# metadata, and every later consumer reads that metadata field. It is
# refused on local-only, whose landing fast-forwards local main, and on a Gerrit
# forge, whose publish path targets the change's own branch.
fm_base_branch_valid() {  # <base> <mode> <forge> <caller>
  local base=$1 mode=$2 forge=$3 caller=$4
  [ -n "$base" ] || return 0
  if [ "${base#-}" != "$base" ] || ! git check-ref-format --branch "$base" >/dev/null 2>&1; then
    echo "error: $caller: base branch '$base' is not a valid git branch name" >&2
    return 1
  fi
  if [ "$mode" = local-only ]; then
    echo "error: $caller: a base branch cannot ship mode=local-only, whose landing fast-forwards local main; ship no-mistakes or direct-PR, which open a pull request against the base" >&2
    return 1
  fi
  if [ "$forge" != none ]; then
    echo "error: $caller: a base branch is not supported on forge=$forge" >&2
    return 1
  fi
  return 0
}

# Print the value of every "Base branch: <name>" line that directly follows the
# base-variant Setup sentence bin/fm-brief.sh writes; return 1 when there is
# none. Any other "Base branch:" line is prose and ignored.
fm_brief_base_branches() {  # <brief>
  awk '
    { sub(/\r$/, "") }
    setup && sub(/^Base branch: /, "") { print; n++ }
    { setup = /^You are in a disposable git worktree of .*, at a detached HEAD on a clean copy of its base branch\.$/ }
    END { exit !n }
  ' "$1"
}

fm_ship_rule_one() {  # <no-mistakes|direct-PR|local-only> <task-id> [branch] [<forge>] [<base>]
  local mode=$1 id=$2 forge=${4:-none} base=${5:-}
  local branch=${3:-fm/$id} target='the default branch'
  fm_forge_valid_for_mode "$forge" "$mode" fm_ship_rule_one || return 1
  fm_base_branch_valid "$base" "$mode" "$forge" fm_ship_rule_one || return 1
  [ -z "$base" ] || target="the base branch \`$base\` or the default branch"
  if [ "$forge" = gerrit ]; then
    printf '%s\n' "1. Never push with git and never create a change except through the one \`gerrit-axi publish --squash\` your Definition of done names. Never run \`gerrit-axi submit\`, never vote or review a change by any path, including \`gerrit review\` or a label option on a push, and never abandon one: a human reviewer approves and submits it on the server."
    return 0
  fi
  case "$mode" in
    direct-PR)
      printf '%s\n' "1. Never push to $target (push only your \`$branch\` branch). Never merge a PR."
      ;;
    local-only)
      printf '%s\n' "1. Never push to any remote and never open a PR. Work only on your \`$branch\` branch; firstmate handles the merge into local \`main\`."
      ;;
    no-mistakes)
      printf '%s\n' "1. Never push to $target. Never merge a PR."
      ;;
    *)
      echo "error: fm_ship_rule_one: unknown delivery mode '$mode'" >&2
      return 1
      ;;
  esac
}

# The task Definition of Done placeholders, in scaffold order, as
# "<token>|<section it sits in>" pairs.
FM_TASK_DOD_SECTION_TITLE='## Definition Of Done (task)'
FM_TASK_DOD_GRADED_TITLE="## How You're Graded"
FM_TASK_DOD_PLACEHOLDERS=(
  "{DOD_CAPABILITY}|$FM_TASK_DOD_SECTION_TITLE"
  "{DOD_MANDATORY_ITEMS}|### Mandatory items"
  "{DOD_SUPPORTING_ITEMS}|### Supporting items"
  "{DOD_HARD_GATES}|### Hard gates"
  "{DOD_HONESTY_RULE}|### Honesty rule"
)

fm_task_dod_block() {
  cat <<'EOF'
## Definition Of Done (task)
These are the criteria this task is graded against.
Firstmate fills each placeholder from the Captain's intent above, as observable outcomes with exact literals copied from their sources.
If the criteria live in a finished file instead, an unfenced line `DoD file: <absolute path>` inside this section points to it; a fresh spawn checks that file once, and you read it before you start.

Capability in plain words: {DOD_CAPABILITY}

### Mandatory items
Each item has Source, Expected, Verify, Edge/negative, Evidence place, and Authority (agent, gate, or grader).
{DOD_MANDATORY_ITEMS}

### Supporting items
{DOD_SUPPORTING_ITEMS}

### Hard gates
{DOD_HARD_GATES}

### Honesty rule
{DOD_HONESTY_RULE}

## How You're Graded
- A session that did not build this work grades it, against the items above and the evidence places they name.
- Mandatory items are pass or fail and release-blocking. One failed mandatory item fails the task.
- Supporting items earn partial credit and never offset a failed mandatory item.
- A crossed hard gate fails the task. Stop and report it.
- Your `done:` status line is a signal to start checking, not a pass. Credit comes from the evidence, never from a claim.
EOF
}

# Print the first leftover placeholder as "<section> still holds <token>" in
# text and return 0 when the text carries one; return 1 when it carries none. A
# token counts only where the scaffold puts it: a line holding it alone, or the
# end of the "Capability in plain words:" line.
fm_dod_text_placeholder() {  # <text>
  local pair token section
  for pair in "${FM_TASK_DOD_PLACEHOLDERS[@]}"; do
    token=${pair%%|*}
    section=${pair#*|}
    if printf '%s\n' "$1" | awk -v token="$token" '
      {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      }
      line == token { found = 1; exit }
      token == "{DOD_CAPABILITY}" && index(line, "Capability in plain words:") == 1 && substr(line, length(line) - length(token) + 1) == token { found = 1; exit }
      END { exit !found }
    '; then
      printf '%s still holds %s\n' "$section" "$token"
      return 0
    fi
  done
  return 1
}

# Print one "<section> still holds <token>" line for every task Definition of
# Done placeholder still standing in <text>, in scaffold order, and return 0
# when at least one remains; return 1 when none does. The match rules are
# fm_dod_text_placeholder's, so a token counts only where the scaffold puts it.
fm_dod_text_problem_list() {  # <text>
  local pair token section remaining=1
  for pair in "${FM_TASK_DOD_PLACEHOLDERS[@]}"; do
    token=${pair%%|*}
    section=${pair#*|}
    if printf '%s\n' "$1" | awk -v token="$token" '
      {
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      }
      line == token { found = 1; exit }
      token == "{DOD_CAPABILITY}" && index(line, "Capability in plain words:") == 1 && substr(line, length(line) - length(token) + 1) == token { found = 1; exit }
      END { exit !found }
    '; then
      printf '%s still holds %s\n' "$section" "$token"
      remaining=0
    fi
  done
  return "$remaining"
}

# Print every reason a ship or scout brief cannot be dispatched, one line per
# problem, and return 0 when at least one exists; return 1 when none does.
# Covers, in the order an operator fills them, unfenced standalone {TASK} and
# {FIRSTMATE_SPEC} lines in their respective Task subsections,
# an empty scaffolded `### Out of scope` exclusion list, which is dispatched
# only as a stated answer (`None` is an answer) so independent review is never
# handed a blank to fill with scope the task never had,
# every DoD token from FM_TASK_DOD_PLACEHOLDERS still standing in its section,
# and an unfenced `DoD file:` line naming a missing, unreadable, or empty file,
# or one that still holds a token. Each file problem names the path to edit.
# A DoD file line replaces the section-body check exactly as it does in
# fm_brief_task_dod_problem. A brief with no Definition Of Done section reports
# nothing here: bin/fm-spawn.sh warns once for a legacy brief and still
# dispatches it.
# The optional second argument `task-only` stops after the two Task bodies,
# which is the scope a relaunch and scout promotion re-check: the Definition of
# Done and its exclusion list were accepted at the fresh spawn, exactly as
# before.
fm_brief_dispatch_problems() {  # <brief> [task-only]
  local brief=$1 scope=${2:-all} intent spec span dod_file more line problems=1
  [ -f "$brief" ] || return 1
  if more=$(fm_brief_file_problem "$brief"); then
    printf '%s\n' "$more"
    return 0
  fi
  intent=$(fm_brief_heading_parse - "## Captain's intent" unfenced-body <<<"## Captain's intent
$(fm_brief_task_heading_body "$brief" "## Captain's intent")")
  spec=$(fm_brief_heading_parse - "## Firstmate spec" unfenced-body <<<"## Firstmate spec
$(fm_brief_task_heading_body "$brief" "## Firstmate spec")")
  if printf '%s\n' "$intent" | grep -Eq '^[[:space:]]*\{TASK\}[[:space:]]*$'; then
    printf '%s\n' "## Captain's intent still holds {TASK}"
    problems=0
  fi
  if printf '%s\n' "$spec" | grep -Eq '^[[:space:]]*\{FIRSTMATE_SPEC\}[[:space:]]*$'; then
    printf '%s\n' "## Firstmate spec still holds {FIRSTMATE_SPEC}"
    problems=0
  fi
  [ "$scope" != task-only ] || return "$problems"
  if fm_brief_task_heading_present "$brief" "### Out of scope" \
    && [ -z "$(fm_brief_out_of_scope "$brief" | tr -d '[:space:]')" ]; then
    printf '%s\n' "### Out of scope is empty: name the work this task does not do, or write None"
    problems=0
  fi
  fm_brief_heading_present "$brief" "$FM_TASK_DOD_SECTION_TITLE" || return "$problems"
  span=$(fm_brief_heading_span "$brief" "$FM_TASK_DOD_SECTION_TITLE" "$FM_TASK_DOD_GRADED_TITLE")
  # Keep examples in span for criteria checks, but never activate a fenced
  # DoD-file directive. The heading reader owns the fence boundaries.
  dod_file=$(fm_brief_task_dod_file "$brief")
  if [ -n "$dod_file" ]; then
    if [ ! -f "$dod_file" ] || [ ! -r "$dod_file" ]; then
      printf 'DoD file %s is not a readable file\n' "$dod_file"
      return 0
    fi
    if more=$(fm_brief_file_problem "$dod_file"); then
      printf '%s\n' "$more"
      return 0
    fi
    if [ -z "$(tr -d '[:space:]' < "$dod_file")" ]; then
      printf 'DoD file %s is empty\n' "$dod_file"
      return 0
    fi
    if more=$(fm_dod_text_problem_list "$(cat "$dod_file")"); then
      while IFS= read -r line; do
        printf 'DoD file %s: %s\n' "$dod_file" "$line"
      done <<EOF
$more
EOF
      return 0
    fi
    return "$problems"
  fi
  if more=$(fm_dod_text_problem_list "$span"); then
    printf '%s\n' "$more"
    problems=0
  fi
  return "$problems"
}

# The directive selector is shared by launch validation and plan construction.
fm_brief_task_dod_file() {  # <brief>
  fm_brief_heading_parse "$1" "$FM_TASK_DOD_SECTION_TITLE" unfenced-body "$FM_TASK_DOD_GRADED_TITLE" \
    | awk '/^DoD file: \// { sub(/^DoD file: /, ""); print; exit }'
}

fm_brief_out_of_scope() {  # <brief>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  # Unfenced mode ignores quoted examples of either exclusion marker.
  fm_brief_heading_parse - "# Task" unfenced-body <<<"# Task
$task" | awk '
      /^(   |  | )?#+([[:space:]]|$)/ {
        scan = $0
        sub(/^ +/, "", scan)
        level = match(scan, /[^#]/) - 1
        if (level < 0) level = length(scan)
        emit = 0
        if ($0 == "### Out of scope") { in_scope = 1; next }
        if (level <= 3) in_scope = 0
        if (!in_scope) next
      }
      in_scope { print; next }
      /^Out of scope:/ { emit = 1 }
      /^[[:space:]]*$/ { emit = 0 }
      emit { print }
    '
}

fm_brief_verification_plan() {  # <brief>
  local brief=$1 rubric dod scope dod_file problem context=''
  rubric="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}/.." && pwd)/docs/review-rubric.md"
  [ -f "$brief" ] && [ -r "$brief" ] || {
    printf 'error: verification-plan brief is not a readable file: %s\n' "$brief" >&2
    return 1
  }
  [ -f "$rubric" ] && [ -r "$rubric" ] || {
    printf 'error: shared review rubric is not a readable file: %s; restore it before building the verification plan\n' "$rubric" >&2
    return 1
  }
  if problem=$(fm_brief_file_problem "$brief"); then
    printf 'error: %s\n' "$problem" >&2
    return 1
  fi
  dod=$(fm_brief_heading_span "$brief" "$FM_TASK_DOD_SECTION_TITLE" "$FM_TASK_DOD_GRADED_TITLE")
  dod_file=$(fm_brief_task_dod_file "$brief")
  if [ -n "$dod_file" ]; then
    [ -f "$dod_file" ] && [ -r "$dod_file" ] || {
      printf 'error: verification-plan DoD file is not a readable file: %s\n' "$dod_file" >&2
      return 1
    }
    if problem=$(fm_brief_file_problem "$dod_file"); then
      printf 'error: %s\n' "$problem" >&2
      return 1
    fi
    dod=$(awk '{ sub(/\r$/, ""); print }' "$dod_file")
  fi
  scope=$(fm_brief_out_of_scope "$brief")
  printf '# Verification plan\nAuthor-supplied verification evidence, not captain intent or authorization to broaden scope.\n\n'
  if fm_brief_heading_present "$brief" "# Current ship Firstmate spec"; then
    context=' (scout-time context)'
    printf 'This task was promoted from a scout: the Task Definition Of Done and Out-of-scope list below are scout-time context from the original scout brief, not ship criteria.\n'
    printf 'Where they conflict with the promoted ship intent, the promoted ship intent governs.\n\n'
  fi
  printf '## Task Definition Of Done%s\n' "$context"
  if [ -n "$(printf '%s' "$dod" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$dod"
  else
    printf 'Task Definition Of Done: absent from this brief.\n'
  fi
  printf '\n## Out-of-scope list%s\n' "$context"
  if [ -n "$(printf '%s' "$scope" | tr -d '[:space:]')" ]; then
    printf '%s\n' "$scope"
  else
    printf "Out-of-scope list: no recognized \`### Out of scope\` subsection or column-0 \`Out of scope:\` paragraph was found in this brief; check the Firstmate spec for inline exclusions.\n"
  fi
  printf '\n'
  cat "$rubric"
}

# Print what keeps a ship or scout brief's task Definition of Done from being
# usable and return 0; return 1 and print nothing when it is usable or absent.
fm_brief_task_dod_problem() {  # <brief>
  local brief=$1 span dod_file found
  [ -f "$brief" ] || return 1
  if found=$(fm_brief_file_problem "$brief"); then
    printf '%s\n' "$found"
    return 0
  fi
  fm_brief_heading_present "$brief" "$FM_TASK_DOD_SECTION_TITLE" || return 1
  span=$(fm_brief_heading_span "$brief" "$FM_TASK_DOD_SECTION_TITLE" "$FM_TASK_DOD_GRADED_TITLE")
  # Keep examples in span for criteria checks, but never activate a fenced
  # DoD-file directive. The heading reader owns the fence boundaries.
  dod_file=$(fm_brief_task_dod_file "$brief")
  if [ -n "$dod_file" ]; then
    if [ ! -f "$dod_file" ] || [ ! -r "$dod_file" ]; then
      printf 'DoD file %s is not a readable file\n' "$dod_file"
      return 0
    fi
    if found=$(fm_brief_file_problem "$dod_file"); then
      printf '%s\n' "$found"
      return 0
    fi
    if [ -z "$(tr -d '[:space:]' < "$dod_file")" ]; then
      printf 'DoD file %s is empty\n' "$dod_file"
      return 0
    fi
    if found=$(fm_dod_text_placeholder "$(cat "$dod_file")"); then
      printf 'DoD file %s: %s\n' "$dod_file" "$found"
      return 0
    fi
    return 1
  fi
  fm_dod_text_placeholder "$span"
}

fm_brief_intent_overlay() {  # <captain-intent> <brief>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.

EOF
  fm_verification_plan_block "$2"
  printf '## Captain intent authorized for --intent\n'
  printf '%s\n' "$1"
}

# Succeed when text has a line other than blank lines and ATX headings, so a
# scaffolded subheading alone never counts as content.
fm_brief_text_has_content() {  # <text>
  printf '%s\n' "$1" | grep -Evq '^ {0,3}#{1,6}([[:space:]]|$)|^[[:space:]]*$'
}

# The `## Firstmate spec` body without its nested `### Out of scope` subsection.
# The exclusion list is specification, but it is never the build instructions,
# so a stated `None.` must not satisfy a spec that holds nothing else.
fm_brief_spec_instructions() {  # <file>
  fm_brief_task_heading_body "$1" "## Firstmate spec" | awk '
    {
      scan = $0
      sub(/^(   |  | )?/, "", scan)
      was_fenced = fenced
      if (scan ~ /^(```|~~~)/) {
        marker = substr(scan, 1, 1)
        rest = scan
        sub(marker == "`" ? "^`+" : "^~+", "", rest)
        len = length(scan) - length(rest)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = len
        } else if (marker == fence_marker && len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }
      if (!was_fenced && !fenced && scan ~ /^#+([[:space:]]|$)/) {
        if ($0 == "### Out of scope") { skip = 1; next }
        if (match(scan, /^#+/) && RLENGTH <= 3) skip = 0
      }
    }
    !skip { print }
  '
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_spec_instructions "$file")
    fm_brief_text_has_content "$intent" || return 1
    fm_brief_text_has_content "$spec" || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  fm_brief_text_has_content "$task"
}

# Print the first `## Captain's intent` body line that opens with an operator
# address spelling; fail when there is none. The body is never rewritten.
fm_brief_intent_address_line() {  # <file>
  fm_brief_task_heading_body "$1" "## Captain's intent" | awk '
    /^[[:space:]]*(Captain('\''s (words|ask|intent))?:|Captain,)/ { print; found = 1; exit }
    END { exit !found }
  '
}

# This is a mechanical minimum, not a natural-language judgment of the ask:
# refuse no substantive lines, or only standalone path/URL/Markdown-link lines
# (optionally introduced by See, Read, or Refer to). Path-shaped tokens contain
# a slash or a filename extension. Ignore blank lines, ATX headings, fence
# delimiters and standalone HTML comments. Other prose remains the author's ask.
fm_brief_intent_ask_problem() {  # <brief>
  local intent
  if fm_brief_task_heading_present "$1" "## Captain's intent"; then
    intent=$(fm_brief_task_heading_body "$1" "## Captain's intent")
  else
    intent=$(fm_brief_marked_captain_words "$(fm_brief_heading_body "$1" '# Task')")
    # Legacy direct-PR/scout briefs may predate provenance markers.
    [ -n "$intent" ] || intent=$(fm_brief_heading_body "$1" '# Task')
  fi
  printf '%s\n' "$intent" | awk '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (comment) {
        if (!match(line, /-->/)) next
        line = substr(line, RSTART + RLENGTH)
        comment = 0
      }
      while (match(line, /<!--/)) {
        before = substr(line, 1, RSTART - 1)
        rest = substr(line, RSTART + RLENGTH)
        if (match(rest, /-->/)) line = before substr(rest, RSTART + RLENGTH)
        else { line = before; comment = 1; break }
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^#+([[:space:]]|$)/) next
      if (line ~ /^(```+|~~~+)/) next
      lines++
      sub(/^[-*+] +/, "", line)
      sub(/[.!]$/, "", line)
      sub(/^([Ss]ee|[Rr]ead|[Rr]efer to)[[:space:]]+/, "", line)
      if (line ~ /^\[[^]]+\]\([^[:space:]]+\)$/) next
      gsub(/`/, "", line)
      if (line ~ /^[^[:space:]]*\/[^[:space:]]*$/ || line ~ /^[^[:space:]]+\.[[:alnum:]_-]+$/) next
      substantive = 1
    }
    END {
      if (substantive) exit 1
      if (!lines) print "no substantive ask after blank lines, headings, fence delimiters and standalone comments"
      else print "only file or report pointers, with no ask written in"
    }
  '
}

# The `nm-<run>-<step>` decision key this block mandates is load-bearing beyond
# the brief itself: the watcher binds an open `needs-decision` to the run a
# crew's current state reports by matching exactly that shape
# (wedge_wait_evidence in bin/fm-watch.sh, through
# status_has_open_needs_decision in bin/fm-classify-lib.sh), which is what buys
# a lane parked at a human-owed gate the long recheck cadence instead of a
# wedge escalation. A gate escalated under any other key still reads as a
# suspected wedge.
fm_ask_user_escalation_block() {  # <data-dir> <task-id>
  local data=$1 id=$2
  cat <<EOF
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to \`$data/$id/nm-<run>-findings.txt\`, then report the gate with
   \`needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=$data/$id/nm-<run>-findings.txt\`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
EOF
}

fm_verification_plan_block() {  # <brief>
  local root brief_q output_q builder_q
  root=$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}/.." && pwd)
  printf -v builder_q '%q' "$root/bin/fm-dod-lib.sh"
  printf -v brief_q '%q' "$1"
  printf -v output_q '%q' "${1%/*}/verification-plan.md"
  cat <<EOF
Before starting a new no-mistakes run, build the separate verification plan from the current durable task brief:
\`bash $builder_q --verification-plan $brief_q > $output_q\`
If plan construction fails, stop and report the error to firstmate; do not start a run with a partial plan.
Pass \`--verification-plan $output_q\` when starting the run, alongside the unchanged \`--intent\` input described below.
The installed no-mistakes input reads a nonempty UTF-8 file as separate run evidence, not user intent; omit that flag when reattaching to an existing run.

EOF
}

# The forge-independent middle of the no-mistakes contract: how a worker drives
# the pipeline, what `--intent` may carry, and the two firstmate-specific rules.
# Written once; only the two sentences about a green PR depend on the forge,
# because on gerrit the ci step is skipped and there is no PR to report.
fm_nm_driving_block() {  # <forge>
  local pr_return_line='' pr_reattach_clause=';' drive_block wait_cfg
  if [ "$1" != gerrit ]; then
    pr_return_line="Only a drive call's return reports the green PR: \`no-mistakes axi status\` shows progress but never reports \`checks-passed\` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
"
    pr_reattach_clause="; once checks are green it returns \`checks-passed\` immediately, and"
  fi
  # config/wait-no-turns selects the foreground drive. Absent, the text matches
  # the backgrounded drive a home had before that flag.
  wait_cfg=${CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}}
  if [ -e "$wait_cfg/wait-no-turns" ]; then
    drive_block="Drive the run with ONE foreground \`no-mistakes axi run\` and let it block.
It bounds its own hold for you: \`--wait\` (default 8m) exists precisely so a harness with a ten-minute command cap gets a structured return instead of being killed mid-hold.
Declare that wait using the brief's status-reporting rule before the foreground drive call.
Never background a wait, and never arm a timer to stand in for one: a backgrounded call returns in milliseconds, so it does not wait at all, and every timer left behind fires later as a paid wake for nothing.
${pr_return_line}Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - that is not a failure: reattach at once by re-running \`no-mistakes axi run\` without flags, and issue the same foreground call again, one at a time, until a gate or outcome comes back${pr_reattach_clause} if it refuses because no run is active, read the finished outcome from \`no-mistakes axi status\`."
  else
    drive_block="One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
${pr_return_line}Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running \`no-mistakes axi run\` without flags, backgrounded the same way${pr_reattach_clause} if it refuses because no run is active, read the finished outcome from \`no-mistakes axi status\`."
  fi
  drive_block="$drive_block
A drive call's own wait ending, or your harness's command bound passing, never kills the run, proves failure, or permits a final timeout blocker: the measured-command instructions above own long-command limits and progress checks, so judge continued work by output growth and cumulative process-tree CPU time.
The helper never stops a wrapped drive call for silence, because the client waits quietly on the shared daemon; only the 6 hour wall clock limit stops one. Its measured p99 x 3 for the wrapped call's own key is only a slower_than_usual report line, not a stop and not a guessed tool wait.
The per-step durations the helper imports from completed pipeline runs are record-only under \`no-mistakes-step.<step>\` and never set a drive call's ceiling."
  cat <<EOF
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass \`--intent\` as only this brief's \`## Captain's intent\` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked \`[captain] \`, excluding that metadata prefix; never copy its mixed \`# Task\` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include \`## Firstmate spec\`, later Firstmate build constraints, or your own decisions and tradeoffs.
The \`--intent\` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into \`--intent\` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich \`--intent\` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

$drive_block
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
}

# How a worker on a forge=gerrit project publishes, shared by both publishing
# modes so the one push, the Change-Id rule, and the ready report are written
# once. gerrit-axi owns the squash mechanics; this names the one call and what
# to read back from it.
fm_gerrit_publish_block() {
  cat <<EOF
Publish from this copy with \`gerrit-axi\`, never with \`git push\`:
1. Run \`git fetch origin\` so the server's branch tip is in this repository; \`gerrit-axi\` reads its base off the server and refuses when that tip is not here.
2. Run \`gerrit-axi publish --squash --json\`, adding \`--branch <b>\` only when the task names a target branch other than the server's default.
   It is one push to \`refs/for/<branch>\` that turns every commit since your branch left the server's branch into ONE change carrying the oldest commit's message, so that message is the review description: make it the one you want reviewed.
   It keeps any \`Change-Id\` a commit already carries and stamps one into the oldest commit when it has none, rewriting your local branch's messages only.
   Never edit, remove, or regenerate a \`Change-Id\`: a different one creates a different change and orphans the first one's review, while the same one adds a patch set to it.
   Never pass \`--stack\`: a stack of changes is not published from this fleet until it can be watched by its membership pinned when its watch is armed, and the watch follows exactly one change.
3. Read the record it prints: \`ok\` must be \`true\`, and the one row of its \`changes\` table is your change. Its \`url\` is the change URL; when \`url\` is null, write \`https://<host>/c/<project>/+/<change>\` from your \`origin\` remote's host and that row's \`project\` and \`change\`.
   A failure prints a typed error record instead; fix what it names and publish again, which updates the same change rather than creating another.
Then append \`done [at=<epoch>]: PR {change url} published for review\` to the status file and stop. You are finished.
That \`done:\` is accepted only when the change's current patch set on the server carries this copy's HEAD tree, so commit nothing after publishing; if you must change the work, commit it and publish again before reporting done.
A \`done:\` whose URL is not the canonical \`https://<host>/c/<project>/+/<number>\` change URL is refused.
There is no pull request, no \`gh-axi\` call, and no forge CI result to report: a human reviewer approves and submits the change on the server, and firstmate relays that outcome.
EOF
}

fm_dod_block() {  # <mode> <task-id> [branch] [<forge>] [<base>] [<consent>] [<brief>]
  local mode=$1 id=$2 forge=${4:-none} base=${5:-} consent=${6:-} brief=${7:-}
  if [ "$mode" = no-mistakes ] && [ -z "$brief" ]; then
    echo "error: fm_dod_block: mode=no-mistakes needs the durable task brief to build its verification plan" >&2
    return 1
  fi
  local branch=${3:-fm/$id} pr_base='' nm_base='' base_q contract_forge='' contract_consent='' forge_cli=gh-axi draft_check
  fm_forge_valid_for_mode "$forge" "$mode" fm_dod_block || return 1
  fm_base_branch_valid "$base" "$mode" "$forge" fm_dod_block || return 1
  if [ -n "$consent" ]; then
    if [ "$mode" = local-only ]; then
      echo "error: fm_dod_block: upstream consent authorizes a publication that local-only never performs; drop it" >&2
      return 1
    fi
    contract_consent=" upstream-consent=$consent"
  fi
  draft_check="(\`gh-axi pr view <number>\` must print \`draft: no\`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with \`gh-axi pr ready <number>\`."
  if [ "$forge" = forgejo ]; then
    contract_forge=' forge=forgejo'
    forge_cli=tea
    draft_check="(\`tea api --repo <owner>/<repo> /repos/{owner}/{repo}/pulls/<number>\` must show \`draft\` as false, where <owner>/<repo> and <number> come from your PR URL); Forgejo marks a draft by a work-in-progress title prefix such as \`WIP:\`, so if it is a draft, remove that prefix with \`tea pulls edit <number> --repo <owner>/<repo> --title '<title without the prefix>'\`."
  fi
  if [ -n "$base" ]; then
    printf -v base_q '%q' "$base"
    pr_base=", against the base branch \`$base\` (\`--base $base_q\`), not the repository default"
    nm_base="This task's base branch is \`$base\`, not the repository default: pass \`--base-branch $base_q\` on every \`no-mistakes axi run\` that starts a run, so the pipeline rebases onto, opens its PR against, and watches CI for that branch.
"
  fi
  case "$mode:$forge" in
    direct-PR:gerrit)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR forge=gerrit shape=squash$contract_consent
Ship branch: $branch
This task ships **direct-PR** to a Gerrit review server: you publish the change yourself, without the no-mistakes pipeline.
Gerrit has no pull requests, so there is nothing to open; publishing creates the change.
The task is complete only when committed on your branch.
When it is implemented and committed, publish it.
EOF
      fm_gerrit_publish_block
      cat <<EOF
Do NOT run /no-mistakes.
EOF
      ;;
    no-mistakes:gerrit)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes forge=gerrit shape=squash$contract_consent
Ship branch: $branch
This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so **no-mistakes runs here as a review pass that ends at a ready branch**, and you then publish that branch as one change.
Pass \`--skip push,pr,ci\` on every \`no-mistakes axi run\` for this task, and skip nothing else: \`review\`, \`test\`, \`document\`, and \`lint\` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.
The task is complete only when committed on your branch.
When you believe it is complete, append \`done [at=<epoch>]: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate.
That first \`done:\` is the handoff that starts the pipeline; it is not a request to publish.

EOF
      fm_verification_plan_block "$brief"
      fm_nm_driving_block "$forge"
      cat <<EOF

Because \`push\` is skipped, the pipeline's fixes DO NOT arrive in your checkout: each fix round commits onto a branch inside no-mistakes' own local gate repository, and with no push nothing carries those commits back to you.
Your tree never goes dirty and nothing interrupts you, so a passed run whose fixes are still in the gate looks exactly like a passed run whose fixes you already have.
You may not publish until you have closed that gap:
1. After the run reaches its outcome, read \`branch_sync.next_action\` from \`no-mistakes axi status\`.
2. When its code is \`recover_custody\`, run the exact command that status prints - \`no-mistakes axi sync --recover\` - and confirm \`branch_sync.state\` comes back \`custody_returned\` on a clean tree. The printed command is authoritative if it differs. The \`run_pipeline\` next action status reports after recovery is not an instruction to run again: the recovered head is the one the passed run validated, so publish it.
   When its code is \`inspect_and_reconcile_manually\` instead, the pipeline head diverged from your submitted head and status offers no recovery yet.
   Append \`blocked [at=<epoch>]: inspect_and_reconcile_manually\` and stop.
   Firstmate returns custody through its bind-archive route (the \`validation-supervision\` skill) and sends you the exact steps; never reset, merge, cherry-pick, or start another run yourself. After a passing outcome, that route adopts the validated pipeline head and returns you to step 3 to publish without another run.
3. Confirm with \`git log\` that \`$branch\` now carries every fix commit the run made, whether or not step 2 was needed.
An unrecovered fix round is an unfinished task, never housekeeping: publishing without it is how the UNFIXED code reaches review.
Your ready report is refused while the run still holds your branch, while its outcome is missing or not passing, or while your HEAD's tree differs from the run's result.

When the run's outcome is passed, passed-with-skips, or passed-with-override and step 3 holds, publish.
The squashed change carries only the oldest commit's message, so the pipeline's own fix commits never reach the reviewer's description; your report is how they reach the captain.
After publishing and immediately before your ready report, append one line \`note [at=<epoch>]: pipeline changes: {finding} - {fix it made}; {finding} - {fix it made}\` to the status file, one short clause per finding the run fixed, taken from the run's \`fixes\` table and the gate findings its drive calls returned (\`no-mistakes axi logs --step <step> --full\` has the detail); write \`note [at=<epoch>]: pipeline changes: none\` when it fixed nothing.
EOF
      fm_gerrit_publish_block
      ;;
    direct-PR:*)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR$contract_forge$contract_consent
Ship branch: $branch
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`$forge_cli\` that is ready for review, not a draft$pr_base.
Before you report done, read the PR back from the forge and confirm it is not a draft $draft_check
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append \`done [at=<epoch>]: PR {url}\` to the status file and stop.
That \`done:\` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append \`paused [at=<epoch>]: {why the draft is held}\` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only:*)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
Ship branch: $branch
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`$branch\`. Do NOT push, do NOT open a PR, do NOT merge.
A \`done:\` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done [at=<epoch>]: ready in branch $branch\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes:*)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes$contract_forge$contract_consent
Ship branch: $branch
The task is complete only when committed on your branch.
When you believe it is complete, append \`done [at=<epoch>]: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.
That first \`done:\` is the handoff that starts the pipeline, which owns the push; it is not a request to push from this copy.
${nm_base}
EOF
      fm_verification_plan_block "$brief"
      fm_nm_driving_block "$forge"
      cat <<EOF

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft $draft_check
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append \`done [at=<epoch>]: PR {url} checks green\` and stop. You are finished.
That CI-ready \`done:\` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append \`paused [at=<epoch>]: {why the draft is held}\` instead of done.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}

# 0 when <sha> is contained in a ref under <namespace> in <repo>.
# --contains tests that exact commit, so a branch that moved to a different
# tip does not count.
fm_dod_ref_contains() {  # <repo> <ref-namespace> <sha>
  local repo=$1 ns=$2 sha=$3 hit
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  [ -n "$sha" ] || return 1
  hit=$(git -C "$repo" for-each-ref --format='%(refname)' --contains="$sha" --count=1 "$ns" 2>/dev/null) || return 1
  [ -n "$hit" ]
}

# 0 when a done: note reports the no-mistakes CI-ready PR (`PR <url> checks
# green`, with any surrounding text). bin/fm-crew-state.sh takes its CI-ready
# path on this same test, so every CI-ready line it acts on is gated.
fm_dod_note_reports_ci_ready() {  # <note>
  # A note is CI-ready only when it names a checks-green result and an actual
  # pull request reference. "PR checks green" and "PROD ... checks green" name
  # no reference, and a substring match made "PROD" read as one.
  local note=$1
  [[ $note == *"checks green"* ]] || return 1
  [[ $note =~ (^|[^[:alnum:]])PR[[:space:]]*#[0-9]+ ]] && return 0
  [[ $note =~ /pull/[0-9]+ ]] && return 0
  [[ $note =~ /merge_requests/[0-9]+ ]] && return 0
  [[ $note =~ /pulls/[0-9]+ ]] && return 0
  [[ $note =~ /c/[^[:space:]]+/\+/[0-9]+ ]] && return 0
  return 1
}

# 0 when a done: note reports a change published to a Gerrit review server
# (`PR <change url> published for review`), which is the ready report of both
# publishing modes on that forge.
fm_dod_note_reports_published_change() {  # <note>
  case "$1" in
    *PR*"published for review"*) return 0 ;;
  esac
  return 1
}

# 0 when this ship done: is one the named-head gate must accept or refuse.
# no-mistakes pre-validation done: is the pipeline handoff and is not gated.
# Empty mode is treated as no-mistakes, the unregistered-project default.
fm_dod_should_gate_ship_done() {  # <kind> <mode> <line>
  local note
  [ "$1" = ship ] || return 1
  [ "$(status_line_verb "$3")" = "done" ] || return 1
  note=$(status_line_note "$3")
  case "$2" in
    direct-PR|local-only) return 0 ;;
    no-mistakes|'')
      fm_dod_note_reports_ci_ready "$note" || fm_dod_note_reports_published_change "$note" ;;
    *) return 1 ;;
  esac
}

# The PR/MR URL from a `done: PR <url>...` note, or empty.
fm_dod_pr_url_from_done_note() {  # <note>
  local note=$1 url
  case "$note" in
    PR\ https://*|PR\ http://*) ;;
    *) return 1 ;;
  esac
  url=${note#PR }
  url=${url%% *}
  printf '%s\n' "$url"
}

# The last recorded <key>= value in <meta>, or empty.
fm_dod_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

# 0 when the forge's head for a PR is the head the done names. In no-mistakes
# mode the pipeline pushes it, possibly with commits the worker clone never
# fetched. A direct-PR worker pushes from its own copy, so its named head stays
# that copy's HEAD and a later unpushed commit is refused.
fm_dod_forge_head_is_named_head() {  # <mode>
  case "$1" in
    no-mistakes|'') return 0 ;;
  esac
  return 1
}

# 0 when <url> is the task's recorded pr= and the forge holds its head:
# bin/fm-pr-check.sh recorded the forge's pr_head= for it in no-mistakes mode,
# or the merge poll recorded it merged (<state>/<id>.pr-poll-merge-notified,
# bin/fm-pr-lib.sh). That head is stored outside the worker copy even when
# this clone never fetched it or fleet sync pruned its branch after a squash
# merge. A recorded Gerrit change needs neither: its pr= is written only after
# the live published-tree check accepted it.
fm_dod_recorded_pr_on_forge() {  # <state> <id> <meta> <mode> <url>
  local state=$1 id=$2 meta=$3 mode=$4 url=$5
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  [ "$(fm_dod_meta_value "$meta" pr)" = "$url" ] || return 1
  if fm_dod_forge_head_is_named_head "$mode" && [ -n "$(fm_dod_meta_value "$meta" pr_head)" ]; then
    return 0
  fi
  ( fm_pr_url_parse "$url" \
    && { [ "$FM_PR_PROVIDER" = gerrit ] \
      || fm_pr_poll_merge_already_notified "$state" "$id" \
        "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; } )
}

# 0 when the task's own durable records name a pull request of <url>'s project
# other than <url> itself, so the task owns several PRs: its recorded pr= is
# another PR, a merge it already landed (state/<id>.pr-poll-merge-notified) is
# another PR, or a `done: PR <url>` ready report in state/<id>.status names
# another PR. The worker copy of such a task rests on one PR's head, on a local
# tip that carries several PRs' content, or on a PR already merged whose branch
# is gone, so its HEAD is not the head of the PR a merge call names;
# bin/fm-pr-check.sh judges that PR's forge head instead at merge time. Only
# positive evidence counts: absent, unreadable, or malformed records answer 1,
# and a single-PR task is judged on its copy's HEAD exactly as before.
fm_dod_task_owns_several_prs() {  # <state> <id> <meta> <url>
  # A subshell, because parsing a URL overwrites the caller's FM_PR_* identity.
  (
    state=$1 id=$2 meta=$3
    fm_pr_url_parse "$4" || exit 1
    provider=$FM_PR_PROVIDER host=$FM_PR_HOST path=$FM_PR_PATH number=$FM_PR_NUMBER
    url=$FM_PR_URL
    if [ -n "$meta" ] && [ -f "$meta" ]; then
      recorded=$(fm_dod_meta_value "$meta" pr)
      [ -z "$recorded" ] || [ "$recorded" = "$url" ] || exit 0
    fi
    fm_pr_poll_merge_marker_names_other "$state" "$id" "$provider" "$host" "$path" "$number" \
      && exit 0
    status="$state/$id.status"
    [ -f "$status" ] && [ ! -L "$status" ] || exit 1
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      if fm_pr_url_parse "$candidate" \
        && [ "$FM_PR_PROVIDER" = "$provider" ] && [ "$FM_PR_HOST" = "$host" ] \
        && [ "$FM_PR_PATH" = "$path" ] && [ "$FM_PR_NUMBER" != "$number" ]; then
        exit 0
      fi
    done <<EOF
$(grep -E '^done([[:space:]]|\[|:)' "$status" 2>/dev/null \
      | grep -oE 'PR[[:space:]]+https?://[^[:space:]]+' \
      | sed -E 's/^PR[[:space:]]+//; s/[.,;:)]+$//')
EOF
    exit 1
  )
}

# 0 when <url> names a Gerrit change whose current patch set carries the tree of
# the worktree's HEAD. The revision is read live and bounded, because the server
# is the only place a refs/for/ push leaves it, and it must already be an object
# in the worktree - the publish that made it ran there - so a patch set pushed
# from elsewhere matches only once this copy holds it.
fm_dod_gerrit_change_carries_head() {  # <worktree> <url>
  local wt=$1 url=$2 revision head_tree revision_tree lib
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = gerrit ] || return 1
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-pr-lib.sh"
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  revision=$(fm_run_timed 10 bash -c '
    . "$1"
    fm_pr_gerrit_read_revision "$2" "$3" || exit 1
    printf "%s\n" "$FM_PR_RECORD_REVISION"
  ' _ "$lib" "$FM_PR_HOST" "$FM_PR_NUMBER" 2>/dev/null) || return 1
  fm_pr_head_valid "$revision" || return 1
  head_tree=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || return 1
  revision_tree=$(git -C "$wt" rev-parse --verify --quiet "$revision^{tree}" 2>/dev/null) || return 1
  [ -n "$head_tree" ] && [ "$head_tree" = "$revision_tree" ]
}

# 0 when the worker copy holds the result of its own passed no-mistakes run:
# the run's outcome is passed, passed-with-skips or passed-with-override (the
# passing set bin/fm-crew-state.sh reads), that pipeline owns no unreturned work (branch_sync.next_action.code is neither
# recover_custody nor continue_active_run) and HEAD's tree equals the tree of the
# pipeline's current head resolved in this copy. On a Gerrit project push is
# skipped, so a fix round's commits stay in the gate until custody is recovered,
# and a copy that publishes before recovering has a server patch set that agrees
# with its own unfixed HEAD - the published-tree check alone accepts it. Trees
# are compared rather than ancestry because the publish stamps a Change-Id and
# rewrites the branch's messages. An unreadable status refuses, as an unreadable
# change does. 1 when refused; stdout then holds a one-line reason.
fm_dod_nm_custody_returned() {  # <worktree>
  local wt=$1 out outcome code pipeline_head head_tree pipeline_tree
  if ! out=$(fm_nm_run_checked "$wt" 15 axi status) || ! printf '%s\n' "$out" | grep -q '^run:'; then
    printf '%s\n' "the no-mistakes run for this copy could not be read, so its fixes cannot be proven recovered"
    return 1
  fi
  outcome=$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")
  case "$outcome" in
    passed|passed-with-skips|passed-with-override) ;;
    *)
      printf '%s\n' "the no-mistakes run for this copy has outcome ${outcome:-(none)}, not a pass, so the published work is not validated"
      return 1 ;;
  esac
  code=$(fm_nm_branch_sync_nested "$out" next_action code)
  case "$code" in
    recover_custody|continue_active_run)
      printf '%s\n' "the no-mistakes run still holds this copy's branch (next action $code), so its fixes are not recovered into the published work"
      return 1 ;;
  esac
  pipeline_head=$(fm_nm_branch_sync_nested "$out" pipeline current_head)
  [ -n "$pipeline_head" ] || pipeline_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)")
  head_tree=$(git -C "$wt" rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null) || head_tree=
  pipeline_tree=
  if fm_pr_head_valid "$pipeline_head"; then
    pipeline_tree=$(git -C "$wt" rev-parse --verify --quiet "$pipeline_head^{tree}" 2>/dev/null) || pipeline_tree=
  fi
  if [ -z "$head_tree" ] || [ -z "$pipeline_tree" ] || [ "$head_tree" != "$pipeline_tree" ]; then
    printf '%s\n' "this copy's HEAD does not carry the no-mistakes run's result ${pipeline_head:-(unknown head)}, so the pipeline's fixes are not in the published work"
    return 1
  fi
  return 0
}

# 0 when <sha> is reachable from a ref that survives the disposable worktree:
# any remote-tracking ref, or - for local-only - heads in the project clone.
fm_dod_named_head_reachable_outside_worktree() {  # <worktree> <project> <mode> <sha>
  local wt=$1 project=$2 mode=$3 sha=$4
  fm_dod_ref_contains "$wt" refs/remotes "$sha" && return 0
  fm_dod_ref_contains "$project" refs/remotes "$sha" && return 0
  [ "$mode" = local-only ] && fm_dod_ref_contains "$project" refs/heads "$sha"
}

# Completion eligibility, including local-only reconciliation, is owned by this file's header.
# There is no free-text SHA scan: a SHA that happens to appear in the note is
# not the named head. Returns 0 for an accepted or ungated claim, or 1 when refused;
# only refusal prints a one-line reason. <state> <id> <meta> supply pr=,
# pr_head=, and the merge-notified marker; <meta> may be a captured copy
# (bin/fm-fleet-snapshot.sh), so the marker is read from <state>.
fm_dod_accept_ship_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  local kind=$1 mode=$2 wt=$3 project=$4 line=$5 state=${6:-} id=${7:-} meta=${8:-} url sha gerrit
  fm_dod_should_gate_ship_done "$kind" "$mode" "$line" || return 0
  if url=$(fm_dod_pr_url_from_done_note "$(status_line_note "$line")") \
    && fm_dod_recorded_pr_on_forge "$state" "$id" "$meta" "$mode" "$url"; then
    return 0
  fi
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf '%s\n' "named head cannot be verified: worktree missing"
    return 1
  fi
  if ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    printf '%s\n' "named head cannot be verified: worktree is not a git copy"
    return 1
  fi
  sha=$(git -C "$wt" rev-parse --verify HEAD 2>/dev/null) || {
    printf '%s\n' "named head could not be resolved"
    return 1
  }
  gerrit=0
  [ -n "$url" ] && fm_pr_url_parse "$url" && [ "$FM_PR_PROVIDER" = gerrit ] && gerrit=1
  if [ "$gerrit" = 0 ] && fm_dod_note_reports_published_change "$(status_line_note "$line")"; then
    printf '%s\n' "the published-for-review report does not name a Gerrit change in the canonical https://<host>/c/<project>/+/<number> form"
    return 1
  fi
  if [ "$gerrit" = 1 ]; then
    if [ "${FM_CREW_STATE_NO_FORGE:-0}" = 1 ]; then
      printf '%s\n' "named head $sha cannot be verified locally: forge read skipped"
      return 1
    fi
    case "$mode" in
      no-mistakes|'')
        fm_dod_nm_custody_returned "$wt" || return 1 ;;
    esac
    if fm_dod_gerrit_change_carries_head "$wt" "$url"; then
      return 0
    fi
    printf '%s\n' "named head $sha is not the published content of $url: the change's current patch set does not carry this copy's HEAD tree, or it could not be read"
    return 1
  fi
  if fm_dod_named_head_reachable_outside_worktree "$wt" "$project" "$mode" "$sha"; then
    return 0
  fi
  printf '%s\n' "named head $sha is unreachable outside the worker copy"
  return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --verification-plan)
      [ "$#" -eq 2 ] || { echo 'error: use bash bin/fm-dod-lib.sh --verification-plan <brief>' >&2; exit 2; }
      fm_brief_verification_plan "$2"
      ;;
    -h|--help)
      printf '%s\n' 'Usage: bash bin/fm-dod-lib.sh --verification-plan <brief>' \
        'Render task DoD, exclusions and the shared review rubric for no-mistakes --verification-plan FILE.' \
        'CRLF input is accepted; unreadable or NUL-bearing input refuses construction; legacy briefs state absent criteria and unrecognized exclusions.'
      ;;
    *) echo 'error: use bash bin/fm-dod-lib.sh --verification-plan <brief> (or --help)' >&2; exit 2 ;;
  esac
fi
