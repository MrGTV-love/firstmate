#!/usr/bin/env bash
# fm-open-loops.sh - reconcile assigned work against live delivery evidence.
# Usage: fm-open-loops.sh [--json] [--heartbeat] [--check-in <task-id>]
#        fm-open-loops.sh --present-overdue | --check-actions | --report
#        fm-open-loops.sh action ROW_ID steered|merged|escalated|deferred --evidence TEXT [--recheck UTC_TIME]
#        fm-open-loops.sh action ROW_ID escalated --evidence TEXT [--hold TASK_ID]
#        fm-open-loops.sh action --batch JSONL_FILE   # - reads stdin
# Batch input has one JSON object per line: row_id, kind, evidence, and optional
# recheck, hold, prerequisite or prerequisite_task (same validation as the single-row form).
# Example: {"row_id":"ROW_ID","kind":"escalated","evidence":"decision requested"}
# A batch shares one cached fleet snapshot, including failed reads, across all actions.
# The whole input is read before the ledger lock is taken, so a slow producer never blocks a drain.
# Each input line produces one result row (line,id,kind,result,message); valid actions
# persist even when siblings refuse. Any refusal exits 1; malformed CLI arguments exit 2.
#        fm-open-loops.sh action ROW_ID waiting --prerequisite QUESTION_ROW_ID --evidence REASON --recheck UTC_TIME
#        fm-open-loops.sh action ROW_ID waiting --prerequisite-task TASK_ID --evidence NNN.msg --recheck UTC_TIME
# --check-in freshly reconciles and sends one standard progress/blocker/dependency
# request through fm-send's non-interrupting inbox path for an overdue silent_report.
# A pending request suppresses repeats under the same ledger lock. Secondmate sends
# use fm-send's existing pending-reply correlation, recovery and escalation; ordinary
# workers report before moving the inbox record into handled/, whose absence is
# escalated by the existing inbox ladder. Fresh or excluded reports are not sent.
# Requires explicit FM_HOME for sends; unresolved targets are refused by fm-send.
# Default: reconcile this home, TOON output. --json prints fm-open-loops.v1 for
# reconciliation or the check-in result object for --check-in.
# --present-overdue presents every overdue row that still needs an action first and records this actor's action
# requirements; rows under a standing receipt or already answered this turn are listed after them and print
# nothing when only they remain.
# An unreadable ledger prints one repair line on stderr and never blocks a drain or acknowledgement.
# Reads (--present-overdue, --check-actions, drain) and refused acknowledgements do not
# invalidate evidence for an unchanged obligation. Successful acknowledgement alone closes
# the handling turn via --complete-actions (internal wake-drain integration).
# Unbound firstmate escalations and steers stand for a fixed four hours, never
# longer than the row stays unchanged; reviewed-green PRs never stand.
# --check-actions exits 1 when an overdue action requirement is unmet under the receipt contract below.
# --report reads all overdue rows with current ages from the published ledger, without a forge scan.
# action records follow-up evidence with --evidence: a new inbox record (NNN.msg) for steered,
# the row's PR URL for merged, or free text for escalated/deferred.
# --hold TASK_ID, valid only with escalated, names the one task held for the captain that a firstmate-owned
# open_pr, unanswered_question or unlanded_commit row waits on; omitted, the documentation below owns which task binds.
# deferred and waiting require an ISO UTC --recheck time within 24 hours.
# waiting selects either --prerequisite QUESTION_ROW_ID (a distinct same-task question) or
# --prerequisite-task TASK_ID (a distinct assigned ship/scout). For the task form, --evidence names its new
# inbox delivery (NNN.msg), whose body must include a line `open-loop-row: ROW_ID`.
# docs/configuration.md#open-work-ledger-configopen-loopsjson owns receipt eligibility, source
# verification, standing waits, captain-hold bindings, acknowledgement, and invalidation; a receipt never
# resolves the obligation.
# Examples: fm-open-loops.sh action ROW_ID steered --evidence 001.msg
#           fm-open-loops.sh action ROW_ID deferred --evidence 'lint still producing output' --recheck '<future-UTC-time>'
# --heartbeat also atomically publishes state/open-loops.json. The watcher runs it as a
# detached helper and surfaces overdue rows as a durable check wake; there is no daemon.
# Sources: the fleet snapshot (backlog and direct reports), status logs, task worktrees,
# unhandled captured Lavish board answers, interrupted teardown records, the no-mistakes run store, and
# discovered GitHub pull requests.
# docs/configuration.md owns config/open-loops.json, row fields, age limits, quota
# refusal, coverage degradation, and supported proof limits. Use --json for each row's limit_seconds.
# Examples: fm-open-loops.sh; fm-open-loops.sh --json; fm-open-loops.sh --heartbeat
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) [ "$#" -eq 1 ] && { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0; } ;;
esac
command -v python3 >/dev/null 2>&1 || { printf 'error: Python 3 is required to reconcile open work\n'; exit 1; }
exec python3 "$SCRIPT_DIR/fm_open_loops.py" "$@"
