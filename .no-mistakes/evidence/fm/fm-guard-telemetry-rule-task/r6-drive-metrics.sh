#!/usr/bin/env bash
# Real bin/fm-guard-metrics.sh on a fixture log built by the real writer (plus
# two hand-aged rows and two malformed rows). Read-only: the log must not change.
set -u
WT=$PWD; E=$WT/bin/fm-guard-event.sh; M=$WT/bin/fm-guard-metrics.sh
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-r6m.XXXXXX"); trap 'rm -rf "$S"' EXIT
unset FM_TASK_ID FM_GUARD_EVENT_LOG; L=$S/g.jsonl
hr() { printf '\n=== %s ===\n' "$1"; }
# per rule + repeat denies across sessions + bypass ratio
FM_SESSION_ID=s1 $E merge-checks-green deny --rule checks-green --task t-red --log "$L"
FM_SESSION_ID=s2 $E merge-checks-green deny --rule checks-green --task t-red --log "$L"
FM_SESSION_ID=s3 $E merge-checks-green deny --rule checks-green --task t-red --log "$L"
$E merge-checks-green bypass --rule checks-green --task t-red --override --log "$L"
$E merge-checks-green allow --rule checks-green --task t-ok --log "$L"
$E merge-landing-tree-tested deny --rule base-tip-changed --task t-tip --log "$L"
$E merge-landing-tree-tested allow --rule base-read --task t-tip --log "$L"
# recurrence: deny, allow, deny for one task/rule/actor
$E teardown-unlanded deny --rule landed-work --task t-rec --log "$L"
$E teardown-unlanded allow --rule landed-work --task t-rec --log "$L"
$E teardown-unlanded deny --rule landed-work --task t-rec --log "$L"
$E teardown-unlanded bypass --rule landed-work --task t-f --override --log "$L"
# deny-only guard, aged past the fixed 30-day window
old=$(python3 -c 'import datetime as d;print((d.datetime.now(d.timezone.utc)-d.timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%SZ"))')
for t in a b; do printf '{"ts":"%s","guard":"gold","rule":"r1","task":"%s","decision":"deny","session":"%s","actor":"main","override":false,"opportunity":true}\n' "$old" "$t" "$t" >>"$L"; done
# same shape but fresh, with one allow
$E gfresh deny --rule r1 --task a --log "$L"; $E gfresh allow --rule r1 --task a --log "$L"
printf '{"ts":"x","guard":"gbad","rule":5,"decision":"deny"}\n{"ts":"2026-11-02T00:00:00Z","guard":"gtorn' >>"$L"; echo >>"$L"
jq -n '{guards:[{id:"gold",harm:"irreversible"},{id:"gfresh",harm:"irreversible"},{id:"gnone",harm:"irreversible"}]}' > "$S/reg.json"
SUM0=$(shasum "$L")
hr "M-A text, all guards"; $M --log "$L" --registry "$S/reg.json" | sed -E 's/ (warns|median_clear_attempts|verdict)=[^ ]*//g'
hr "M-B json: zero_event_guards, window, flags per guard"
$M --log "$L" --registry "$S/reg.json" --json | jq -c '{window_days,zero_event_guards,summary,guards:[.guards[]|{id,denies,recurrences,refusal_to_bypass_ratio,repeat_denies,deny_only,zero_events_days}]}'
hr "M-C json: per-task repeat denies, rule level"
$M --log "$L" --registry "$S/reg.json" --json | jq -c '.rules[]|select(.repeat_denies>0)|{id,rule,repeat_denies_per_task}'
hr "M-D --days is no longer accepted"; rc=0; $M --log "$L" --days 7 >/dev/null 2>"$S/err" || rc=$?; echo "rc=$rc $(tail -1 "$S/err")"
hr "M-E absent log: no QUIET lines"; $M --log "$S/none.jsonl" --registry "$S/reg.json"
hr "M-F log unchanged by metrics: $([ "$SUM0" = "$(shasum "$L")" ] && echo yes || echo no)"
