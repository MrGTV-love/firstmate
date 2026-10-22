#!/usr/bin/env python3
"""Fixture inspectors for tests/fm-slack-watch.test.sh.

Usage:
  fm_slack_watch_test.py card-payload <replay-state.json>
  fm_slack_watch_test.py cards <replay-state.json>
  fm_slack_watch_test.py thread-count <state.json> [key]
  fm_slack_watch_test.py outbound-count <outbound.jsonl> <method> [thread_ts]
  fm_slack_watch_test.py replay-file <state-dir>
  fm_slack_watch_test.py thread-texts <replay-state.json> <thread-ts>
  fm_slack_watch_test.py thread-posts <outbound.jsonl> <thread-ts>
  fm_slack_watch_test.py pending-count <state.json>
  fm_slack_watch_test.py pending-field <state.json> <field>
  fm_slack_watch_test.py add-retired <state.json> <count>
  fm_slack_watch_test.py pad-history <replay-state.json> <count>
  fm_slack_watch_test.py reaction-count <outbound.jsonl> <ts>
  fm_slack_watch_test.py card-text <replay-state.json> <task-id>
  fm_slack_watch_test.py thread-field <state.json> <task-id> <field>
  fm_slack_watch_test.py drop-threads <state.json>
  fm_slack_watch_test.py root-count <replay-state.json> <task-id>
  fm_slack_watch_test.py reply <replay-state.json> <thread-ts> <ts> <user> <text> [extra-json]
  fm_slack_watch_test.py seen-count <state.json> <thread-ts>
  fm_slack_watch_test.py stage-notice <state.json> <thread-ts> <task-id> <length>
  fm_slack_watch_test.py react <replay-state.json> <ts> <name> <user>
  fm_slack_watch_test.py unreact <replay-state.json> <ts> <name> <user>
"""
import glob
import json
import os
import sys


def messages(path):
    return json.load(open(path))['messages']


def card_payload(path):
    cards = {}
    for message in messages(path):
        text = message.get('text', '')
        for key in ('with-options', 'no-options', 'no-recommendation'):
            if 'Task: ' + key in text:
                cards[key] = text
    assert set(cards) == {'with-options', 'no-options', 'no-recommendation'}, cards.keys()
    for key, text in cards.items():
        for part in ('Task: ', 'Decision: ', 'Recommendation: ', 'Evidence: ',
                     'If you both tap and type:', 'in this thread',
                     'Messages typed in the main DM window are not read.'):
            assert part in text, (key, part)
    assert 'Recommendation: ship' in cards['with-options']
    assert 'Evidence: /tmp/evidence-with-options.md' in cards['with-options']
    assert 'Options:' in cards['with-options'] and '1. Ship it (ship)' in cards['with-options']
    assert 'or reply in this thread with the option number.' in cards['with-options']
    assert 'Reply in this thread with your answer.' in cards['no-options']
    assert 'Options:' not in cards['no-options']
    assert 'Recommendation: none recorded' in cards['no-recommendation']
    assert 'Evidence: none recorded' in cards['no-recommendation']
    assert 'Options:' in cards['no-recommendation']
    assert 'none recorded' not in cards['with-options']
    assert 'none recorded' not in cards['no-options']
    assert sum(text.count('none recorded') for text in cards.values()) == 2


def edit(path, change):
    data = json.load(open(path))
    change(data)
    json.dump(data, open(path, 'w'), ensure_ascii=False)


def card_text(path, task):
    for message in messages(path):
        if not message.get('thread_ts') and ('Task: ' + task + '\n') in message.get('text', ''):
            return message['text']
    raise SystemExit('no card for ' + task)


def main(argv):
    command = argv[0]
    if command == 'card-payload':
        card_payload(argv[1])
    elif command == 'cards':
        print('\n'.join(message.get('text', '') for message in messages(argv[1])))
    elif command == 'thread-count':
        path = argv[1]
        key = argv[2] if len(argv) > 2 else ''
        data = json.load(open(path)) if os.path.exists(path) else {'threads': {}}
        print(len([row for row in data.get('threads', {}).values()
                   if not key or row.get('key') == key]))
    elif command == 'outbound-count':
        path, method = argv[1], argv[2]
        thread = argv[3] if len(argv) > 3 else ''
        count = 0
        if os.path.exists(path):
            for line in open(path):
                row = json.loads(line)
                if row.get('method') == method and (not thread or row.get('thread_ts') == thread):
                    count += 1
        print(count)
    elif command == 'thread-texts':
        print('\n'.join(m.get('text', '') for m in messages(argv[1]) if m.get('thread_ts') == argv[2]))
    elif command == 'thread-posts':
        rows = (json.loads(line) for line in open(argv[1]))
        print('\n'.join(row.get('text', '') for row in rows
                        if row.get('method') == 'chat.postMessage' and row.get('thread_ts') == argv[2]))
    elif command == 'pending-count':
        print(len(json.load(open(argv[1])).get('pending', [])))
    elif command == 'pending-field':
        print(json.load(open(argv[1]))['pending'][0][argv[2]])
    elif command == 'add-retired':
        def retire(data):
            template = next(iter(data['threads'].values()))
            for n in range(int(argv[2])):
                row = dict(template, key='retired-%d' % n, ts='700.%06d' % n, retired=True)
                data['threads']['retired-%d:old#0' % n] = row
        edit(argv[1], retire)
    elif command == 'pad-history':
        edit(argv[1], lambda data: data['messages'].extend(
            {'ts': '800.%06d' % n, 'user': 'U0TESTOWNER', 'text': 'padding %d' % n}
            for n in range(int(argv[2]))))
    elif command == 'reaction-count':
        path = argv[1]
        rows = [json.loads(line) for line in open(path)] if os.path.exists(path) else []
        print(len([r for r in rows if r.get('method') == 'reactions.add' and r.get('ts') == argv[2]]))
    elif command == 'card-text':
        print(card_text(argv[1], argv[2]))
    elif command == 'root-count':
        print(len([m for m in messages(argv[1]) if not m.get('thread_ts')
                   and ('Task: ' + argv[2] + '\n') in m.get('text', '')]))
    elif command == 'thread-field':
        data = json.load(open(argv[1]))
        print(next(row[argv[3]] for row in data['threads'].values() if row['key'] == argv[2]))
    elif command == 'drop-threads':
        edit(argv[1], lambda data: data['threads'].clear())
    elif command == 'reply':
        extra = json.loads(argv[6]) if len(argv) > 6 else {}
        edit(argv[1], lambda data: data['messages'].append(
            {'ts': argv[3], 'thread_ts': argv[2], 'user': argv[4], 'text': argv[5], **extra}))
    elif command == 'stage-notice':
        edit(argv[1], lambda data: data['pending'].append(
            {'event': 'test/oversized-notice/' + argv[2], 'key': argv[3], 'thread': argv[2],
             'text': 'Oversized notice ' + 'n' * int(argv[4]), 'line': 'check: slack %s - oversized notice' % argv[2],
             'kind': 'notice', 'stage': 'notice', 'contributing': []}))
    elif command == 'seen-count':
        seen = json.load(open(argv[1])).get('seen', {})
        print(len([event for event in seen if '/' + argv[2] + '/' in event]))
    elif command in ('react', 'unreact'):
        def toggle(data):
            entries = data['reactions'].setdefault(argv[2], [])
            entry = next((r for r in entries if r['name'] == argv[3]), None)
            if entry is None:
                entry = {'name': argv[3], 'users': []}
                entries.append(entry)
            if command == 'react' and argv[4] not in entry['users']:
                entry['users'].append(argv[4])
            if command == 'unreact':
                entry['users'] = [u for u in entry['users'] if u != argv[4]]
        edit(argv[1], toggle)
    elif command == 'replay-file':
        paths = glob.glob(os.path.join(argv[1], 'replay-state-*.json'))
        print(paths[0] if paths else '')
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
