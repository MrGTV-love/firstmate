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
    content = results[0]['content']
    text = content if isinstance(content, str) else '\n'.join(part['text'] for part in content if part['type'] == 'text')
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
    framed_source = '\n'.join(f'{number}\t{line}' for number, line in enumerate(source.split('\n'), 1))
    if source.endswith('\n'):
        framed_source = framed_source[:-1]
    frame, separator, notice = text.partition('\n\n<system-reminder>')
    assert frame == framed_source, 'complete Claude source text absent or changed in next model context'
    text = separator + notice
positive = kind in ('launch', 'inbox')
requests = (lab / 'jev.jsonl').read_text().splitlines()
trusted = kind == 'changed'
error_type = {
    'normal': None, 'privacy': 'PrivacyWithheldError', 'credentials': 'CredentialUnavailableError',
    'provider': 'Error', 'audit': 'AuditUnavailableError',
}[phase]
expected_requests = 0 if positive or phase in ('privacy', 'credentials') else (3 if backend == 'claude' else 2) if phase == 'provider' else 1
assert len(requests) == expected_requests, f'unexpected Jev egress count: expected {expected_requests}, got {len(requests)}'
if positive:
    if backend == 'omp':
        assert source in text, 'original exact instruction bytes absent from next model context'
    if phase == 'audit':
        assert 'not producer authentication' in text, 'same-user consistency trust limit absent from notice'
        assert 'AuditUnavailableError' in text, 'audit-unavailable notice absent from next model context'
    else:
        assert '[jev-guard]' not in text, 'consistent native instruction was screened'
elif trusted:
    if backend == 'omp':
        assert source in text, 'trusted state read disappeared from next model context'
    if phase == 'audit':
        assert 'AuditUnavailableError' in text, 'trusted read lost the audit failure notice'
    else:
        assert '[jev-guard]' not in text, 'trusted state unnecessarily replaced or annotated'
else:
    assert '[jev-guard]' in text, 'native review notice absent from next model context'
    if backend == 'omp':
        assert 'synthetic-native-authority-canary' not in text, 'untrusted original leaked into OMP model context'
        assert 'Untrusted output was withheld' in text, 'native replacement did not reach model context'
    else:
        assert 'Advisory only' in text and 'no protection' in text, 'Claude advisory status absent from model context'
    assert f'Tool output requires review ({error_type or "flag"}).' in text, 'wrong terminal outcome consumed by native model context'
    assert 'REVIEW_ON_UNAVAILABLE_V1' in text, 'named outage policy absent from native notice'
if phase != 'audit':
    ledger = [json.loads(line) for line in (lab / 'home/state/jev-guard.jsonl').read_text().splitlines()]
    result = [row for row in ledger if row['hook'] == 'tool_result']
    assert len(result) == 1, 'native tool-result audit absent or duplicated'
    terminal = result[0]
    if positive:
        expected = ('clear', 'supervisor_consistency', None, False, 'result_pass')
    elif trusted:
        expected = ('clear', 'trusted_read', error_type, phase in ('normal', 'provider'), 'result_pass')
    elif phase == 'normal':
        expected = ('flag', 'policy', None, True, 'claude_advisory_only' if backend == 'claude' else 'omp_replace')
    else:
        expected = ('review', 'outage', error_type, phase == 'provider',
                    'claude_advisory_only' if backend == 'claude' else 'omp_replace')
    observed = tuple(terminal[key] for key in ('decision', 'branch', 'error_type', 'request_started', 'enforcement'))
    assert observed == expected, f'native terminal mismatch: expected {expected}, got {observed}'
    assert terminal['policy_version'] == 'FIRSTMATE_JEV_GUARD_V1'
    assert terminal['outage_policy'] == 'REVIEW_ON_UNAVAILABLE_V1'
print(f'{backend}: {phase}/{kind}: native read and next model context consumed')
