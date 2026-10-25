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
if backend == 'omp':
    assert text == source, 'complete original read bytes changed in the receiving model context'
assert '[jev-guard]' not in text, 'retired result screen appended or replaced native output'
assert (lab / 'jev.jsonl').read_text() == '', 'a native read result reached TypeSafe'
ledger = lab / 'home/state/jev-guard.jsonl'
if phase != 'audit' and ledger.exists():
    terminal = [json.loads(line) for line in ledger.read_text().splitlines()]
    assert not any(row['hook'] == 'tool_result' for row in terminal), 'retired result audit row was written'
print(f'{backend}: {phase}/{kind}: unchanged native read in next model context; no result request or audit row')
