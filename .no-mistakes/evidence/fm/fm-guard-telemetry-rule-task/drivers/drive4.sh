#!/usr/bin/env bash
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6FJ8XSS0AWB1CFHTT675C3M
cd "$WT"
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID
. /tmp/fmtest-01M6/lab.path
export FM_HOME=$LAB
LOG=$FM_HOME/state/guard-events.jsonl
# Add a repeat-deny pattern: the same task refused in two different harness sessions, then cleared.
FM_SESSION_ID=s1 bin/fm-guard-event.sh upstream-publish-role deny --rule publication-authority --task rep-t
FM_SESSION_ID=s2 bin/fm-guard-event.sh upstream-publish-role deny --rule publication-authority --task rep-t
echo "### S-metrics text (lab log: $(wc -l <"$LOG") rows from the real emitters above)"
bin/fm-guard-metrics.sh --log "$LOG" --guards claude-api-billing,upstream-publish-role,gate-agent-containment,compact-adviser,guard-watcher-down-warning,secondmate-sync; echo "rc=$?"
echo; echo "### S-metrics json (selected fields)"
bin/fm-guard-metrics.sh --log "$LOG" --guards claude-api-billing,upstream-publish-role,gate-agent-containment,compact-adviser --json | jq '{window_days, malformed_rows, zero_event_guards, guards: [.guards[]? | {guard, denies, overrides: (.overrides // .override_events), bypasses, refusal_to_bypass_ratio, repeat_denies, deny_only, zero_events_days}]}' 2>&1 | head -80
echo; echo "### S-metrics read-only: log hash before/after"
h1=$(shasum "$LOG"); bin/fm-guard-metrics.sh --log "$LOG" >/dev/null; h2=$(shasum "$LOG"); [ "$h1" = "$h2" ] && echo "log unchanged by metrics"
echo; echo "### S-detector: real instance 5ad471a2b"
h1=$(git for-each-ref | shasum); python3 bin/fm-guard-workarounds.py --repo "$WT" --head 5ad471a2b --task train-5; echo "rc=$?"
python3 bin/fm-guard-workarounds.py --repo "$WT" --head 5ad471a2b --task train-5 --json | head -3
h2=$(git for-each-ref | shasum); [ "$h1" = "$h2" ] && echo "refs unchanged by detector"
echo "5ad471a2b tree = $(git rev-parse 5ad471a2b^{tree}); first parent tree = $(git rev-parse 5ad471a2b^1^{tree})"
echo; echo "### S-detector negative: an ordinary merge head is not reported"
python3 bin/fm-guard-workarounds.py --repo "$WT" --head 9ed98a152 --task main-merge; echo "rc=$?"
echo; echo "### S-detector + metrics: signature feed counts in the ratio"
python3 bin/fm-guard-workarounds.py --repo "$WT" --head 5ad471a2b --task train-5 --json > /tmp/fmtest-01M6/wa.jsonl
bin/fm-guard-metrics.sh --log "$LOG" --workarounds /tmp/fmtest-01M6/wa.jsonl --guards upstream-publish-role | head -5
