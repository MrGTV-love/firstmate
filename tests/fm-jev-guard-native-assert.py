#!/usr/bin/env python3
import json
import pathlib
import sys

lab = pathlib.Path(sys.argv[1])
backend = sys.argv[2]
phase = sys.argv[3]
kind = sys.argv[4]
rows = [json.loads(line) for line in (lab / 'model.jsonl').read_text().splitlines()]
assert len(rows) == 2, f'expected native read plus next model request, got {len(rows)}'
if backend == 'omp':
    results = [item for item in rows[-1].get('input', []) if item.get('type') == 'function_call_output']
    assert len(results) == 1, 'no unique native function-call result reached next model context'
    text = results[0]['output']
else:
    results = [part for message in rows[-1].get('messages', []) if message.get('role') == 'user'
               for part in message.get('content', []) if isinstance(part, dict) and part.get('type') == 'tool_result']
    assert len(results) == 1, 'no unique native Read result reached next model context'
    text = json.dumps(rows[-1]['messages'], ensure_ascii=False)
if not isinstance(text, str):
    text = json.dumps(text, ensure_ascii=False)
if backend == 'omp':
    try:
        structured = json.loads(text)
    except (ValueError, TypeError):
        structured = None
    if isinstance(structured, list):
        text = '\n'.join(part.get('text', '') for part in structured if isinstance(part, dict))
source = (lab / 'original.txt').read_text()
if backend == 'claude':
    payload = json.loads((lab / 'native-hook.json').read_text())
    assert payload['hook_event_name'] == 'PostToolUse' and payload['tool_name'] == 'Read', 'native Read hook did not execute'
    assert payload['tool_response']['file']['content'] == source, 'native Claude hook did not receive exact source bytes'
positive = kind in ('launch', 'inbox')
requests = (lab / 'jev.jsonl').read_text().splitlines()
assert len(requests) == (0 if positive or phase in ('privacy', 'credentials') else 1), 'unexpected Jev egress count'
if positive:
    if backend == 'omp':
        assert source in text, 'original exact instruction bytes absent from next model context'
    else:
        assert 'synthetic-native-authority-canary' in text and 'Trailing native line.' in text, 'original Claude instruction absent from context'
    if phase == 'audit':
        assert 'not producer authentication' in text, 'same-user consistency trust limit absent from notice'
        assert 'AuditUnavailableError' in text, 'audit-unavailable notice absent from next model context'
    else:
        assert '[jev-guard]' not in text, 'consistent native instruction was screened'
else:
    assert '[jev-guard]' in text, 'native review notice absent from next model context'
    if backend == 'omp':
        assert 'synthetic-native-authority-canary' not in text, 'untrusted original leaked into OMP model context'
        assert 'Untrusted output was withheld' in text, 'native replacement did not reach model context'
    else:
        assert 'synthetic-native-authority-canary' in text, 'Claude advisory unexpectedly quarantined original'
        assert 'Advisory only' in text and 'no protection' in text, 'Claude advisory status absent from model context'
    if phase == 'privacy':
        assert 'PrivacyWithheldError' in text, 'privacy outage missing'
    elif phase == 'credentials':
        assert 'CredentialUnavailableError' in text, 'credential outage missing'
    elif phase == 'audit':
        assert 'AuditUnavailableError' in text, 'audit outage missing'
    elif phase == 'provider':
        assert 'review' in text.lower(), 'provider outage did not require review'
if phase != 'audit':
    ledger = [json.loads(line) for line in (lab / 'home/state/jev-guard.jsonl').read_text().splitlines()]
    result = [row for row in ledger if row['hook'] == 'tool_result']
    assert len(result) == 1, 'native tool-result audit absent or duplicated'
    assert (result[0]['branch'] == 'supervisor_consistency') == positive, 'source-consistency branch mismatch'
    assert result[0]['policy_version'] == 'FIRSTMATE_JEV_GUARD_V1'
print(f'{backend}: {phase}/{kind}: native read and next model context consumed')
