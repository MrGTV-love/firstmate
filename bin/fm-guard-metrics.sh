#!/usr/bin/env bash
# fm-guard-metrics.sh - read-only guard/rule metrics and retirement nominations.
# Usage: fm-guard-metrics.sh [--log <jsonl>] [--registry <json>]
#   [--min-opportunities <n>] [--guards <id,id,...>] [--json] [--undecided]
#   [--workarounds <jsonl>] [--days <n>]
# --workarounds accepts fm-guard-workarounds.py --json output, without modifying
# the event log. Distinct signatures count once per task, head, rule and kind.
# Opportunities exclude bypasses; refusal_to_bypass_ratio is
# (override/bypass events + workaround signatures) / denies, null if no denies.
# Repeat denies count additional denies per task across sessions, per rule.
# Session-only legacy events cannot establish task attribution.
# Retirement remains the guard-level rule in docs/guard-spec.md; rule rows are
# diagnostic only. No metric disables or changes a guard.
# --undecided prints the cut nominations no registry retirement_decision judges.
# A decision starting `keep|redesign|cut YYYY-MM-DD` judges the events through
# that day and stands until the evidence changes: later events nominate the guard
# again only when they hold a deny, warn, override or other non-allow decision,
# or meet the threshold on their own as a quiet window after a judged window (the
# last --min-opportunities events through that day) that held a fire.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
exec python3 - "$ROOT" "${FM_GUARD_EVENT_LOG:-${FM_HOME:-${FM_ROOT:-$ROOT}}/state/guard-events.jsonl}" "$@" <<'PY'
import argparse
import collections
import datetime
import json
import re
import statistics
import sys
from pathlib import Path

root, default_log, *args = sys.argv[1:]
p = argparse.ArgumentParser(description='Read-only guard and rule metrics')
p.add_argument('--log', default=default_log)
p.add_argument('--registry', default=str(Path(root) / 'docs/guards/registry.json'))
p.add_argument('--min-opportunities', type=int, default=30)
p.add_argument('--guards', default='')
p.add_argument('--json', action='store_true')
p.add_argument('--undecided', action='store_true')
p.add_argument('--workarounds')
p.add_argument('--days', type=int, default=30)
a = p.parse_args(args)
if a.min_opportunities < 1 or a.days < 1:
    p.error('opportunities and days must be positive')


def json_lines(path):
    try:
        with open(path, encoding='utf-8') as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except (ValueError, UnicodeError):
                    continue  # A torn final event must not hide earlier evidence.
                if isinstance(row, dict) and row.get('guard'):
                    yield row
    except FileNotFoundError:
        return
    except OSError as error:
        p.error(f'cannot read {path}: {error.strerror}')


try:
    registry = json.loads(Path(a.registry).read_text())
except (OSError, ValueError):
    registry = {}
entries = {row['id']: row for row in registry.get('guards', [])}
only = set(filter(None, a.guards.split(',')))
rows = [row for row in json_lines(a.log) if not only or row['guard'] in only]
signatures = list(json_lines(a.workarounds)) if a.workarounds else []
cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=a.days)).strftime('%Y-%m-%dT%H:%M:%SZ')


def metric(guard, events, rule=None):
    denies = sum(e.get('decision') == 'deny' for e in events)
    warns = sum(e.get('decision') == 'warn' for e in events)
    allows = sum(e.get('decision') == 'allow' for e in events)
    bypasses = sum(e.get('decision') == 'bypass' for e in events)
    overrides = sum(e.get('override') is True for e in events)
    escapes = sum(e.get('override') is True or e.get('decision') == 'bypass' for e in events)
    workarounds = len({(e.get('task'), e.get('head'), e.get('rule'), e.get('kind'))
                       for e in signatures if e['guard'] == guard
                       and (rule is None or e.get('rule', guard) == rule)})
    opportunities = sum(e.get('decision') in ('deny', 'warn', 'allow', 'error') for e in events)
    rate = round(overrides / (denies + warns), 3) if denies + warns else 0
    attempts, recurrences = [], 0
    sessions = collections.defaultdict(list)
    tasks = collections.Counter()
    for event in events:
        # Keep rules separate even in the aggregate: one rule's allow does not
        # clear another rule's refusal. Task identity survives harness restarts.
        identity = event.get('task') or event.get('session', '')
        sessions[(event.get('rule') or guard, identity)].append(event)
        if event.get('task') and event.get('decision') == 'deny':
            tasks[(event.get('rule') or guard, event['task'])] += 1
    for session in sessions.values():
        current, cleared = 0, False
        # Log order resolves equal-second timestamps deterministically.
        for event in sorted(session, key=lambda e: e.get('ts', '')):
            if event.get('decision') == 'deny':
                current += 1
                if cleared and current == 1:
                    recurrences += 1
            elif event.get('decision') == 'allow':
                if current:
                    attempts.append(current)
                    cleared = True
                current = 0
    median = statistics.median(attempts) if attempts else 0
    harm = entries.get(guard, {}).get('harm', 'unknown')
    verdict = 'unmeasured'
    if opportunities >= a.min_opportunities:
        verdict = 'keep'
        if ((harm in ('reversible', 'style') and (denies + warns == 0 or rate > .2))
                or median > 3 or recurrences):
            verdict = 'cut'
    result = dict(id=guard, opportunities=opportunities, denies=denies, warns=warns,
                  override_rate=rate, median_clear_attempts=median,
                  recurrences=recurrences, verdict=verdict, harm=harm,
                  allows=allows, overrides=overrides, bypasses=bypasses, workarounds=workarounds,
                  refusal_to_bypass_ratio=round((escapes + workarounds) / denies, 3) if denies else None,
                  repeat_denies=sum(max(0, count - 1) for count in tasks.values()),
                  repeat_denies_per_task=[dict(task=task, denies=count, repeat_denies=count - 1,
                                              **({'rule': task_rule} if rule is None else {}))
                                          for (task_rule, task), count in sorted(tasks.items()) if count > 1],
                  deny_only=denies > 0 and allows == 0,
                  zero_events_days=a.days if not any(e.get('ts', '') >= cutoff for e in events) else 0)
    if rule is not None:
        result['rule'] = rule
    return result


def judged(guard, events):
    decision = entries.get(guard, {}).get('retirement_decision')
    dated = re.match(r'(?:keep|redesign|cut) ([0-9]{4}-[0-9]{2}-[0-9]{2})', decision) if isinstance(decision, str) else None
    if not dated:
        return False
    after = dated[1] + 'T23:59:59Z'
    fresh = [e for e in events if e.get('ts', '') > after]
    if any(e.get('decision') != 'allow' or e.get('override') is True for e in fresh):
        return False
    if metric(guard, fresh)['verdict'] != 'cut':
        return True
    window = sorted((e for e in events if e.get('ts', '') <= after), key=lambda e: e.get('ts', ''))
    return not any(e.get('decision') in ('deny', 'warn') for e in window[-a.min_opportunities:])


grouped = collections.defaultdict(list)
by_rule = collections.defaultdict(list)
for row in rows:
    grouped[row['guard']].append(row)
    by_rule[(row['guard'], row.get('rule') or row['guard'])].append(row)
guards = [metric(guard, events) for guard, events in sorted(grouped.items())]
rules = [metric(guard, events, rule) for (guard, rule), events in sorted(by_rule.items())]
present = Path(a.log).is_file()
# Absent registered guards are visible without inventing an opportunity count.
quiet = sorted(guard for guard in entries if guard not in grouped and (not only or guard in only)) if present else []
summary = dict(guards=len(guards), measured=sum(g['verdict'] != 'unmeasured' for g in guards),
               cut=sum(g['verdict'] == 'cut' for g in guards),
               unmeasured=sum(g['verdict'] == 'unmeasured' for g in guards))
if a.undecided:
    for g in guards:
        if g['verdict'] == 'cut' and not judged(g['id'], grouped[g['id']]):
            print(g['id'])
elif a.json:
    print(json.dumps(dict(log=a.log, present=present, guards=guards, rules=rules,
                          zero_event_guards=quiet, window_days=a.days, summary=summary)))
else:
    for label, metrics in (('METRIC', guards), ('RULE', rules)):
        for g in metrics:
            fields = ['opportunities', 'denies', 'warns', 'override_rate', 'median_clear_attempts',
                      'recurrences', 'verdict', 'allows', 'overrides', 'bypasses', 'workarounds',
                      'refusal_to_bypass_ratio', 'repeat_denies', 'deny_only', 'zero_events_days']
            prefix = f"{label} {g['id']}" + (f" rule={g['rule']}" if label == 'RULE' else '')
            print(prefix + ' ' + ' '.join(f'{key}={json.dumps(g[key]) if not isinstance(g[key], str) else g[key]}' for key in fields))
            if label == 'RULE':
                for task in g['repeat_denies_per_task']:
                    print(f"REPEAT {g['id']} rule={g['rule']} task={task['task']} denies={task['denies']} repeat_denies={task['repeat_denies']}")
    for guard in quiet:
        print(f'QUIET {guard} zero_events_days={a.days}')
    print('METRICS_SUMMARY ' + ' '.join(f'{key}={value}' for key, value in summary.items())
          + (' log_absent=true' if not present else ''))
PY
