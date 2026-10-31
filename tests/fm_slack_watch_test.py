#!/usr/bin/env python3
"""Fixture inspectors for tests/fm-slack-watch.test.sh.

Usage:
  fm_slack_watch_test.py  # run renderer unit tests
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
  fm_slack_watch_test.py legacy-card <state.json> <replay-state.json> <task-id>
  fm_slack_watch_test.py retire-thread <state.json> <task-id>
  fm_slack_watch_test.py reaction-state <replay-state.json> <ts>
  fm_slack_watch_test.py root-count <replay-state.json> <task-id>
  fm_slack_watch_test.py reply <replay-state.json> <thread-ts> <ts> <user> <text> [extra-json]
  fm_slack_watch_test.py seen-count <state.json> <thread-ts>
  fm_slack_watch_test.py stage-notice <state.json> <thread-ts> <task-id> <length> [fill]
  fm_slack_watch_test.py react <replay-state.json> <ts> <name> <user>
  fm_slack_watch_test.py unreact <replay-state.json> <ts> <name> <user>
  fm_slack_watch_test.py set-state <state.json> <field> <value>
  fm_slack_watch_test.py set-scopes <transcript.json> <comma-separated-scopes>
  fm_slack_watch_test.py journal-line <state.json> <line>
  fm_slack_watch_test.py fail-call <replay-state.json> <method[:ts]> <status> [times]
  fm_slack_watch_test.py clear-fail <replay-state.json> <method[:ts]>
  fm_slack_watch_test.py move-transcript <transcript.json> <out.json> <channel>
  fm_slack_watch_test.py split-transcript <transcript.json> <out.json> <post-channel> <owner-dm>
  fm_slack_watch_test.py add-failure <transcript.json> <out.json> <method[:ts]> <status>
  fm_slack_watch_test.py outbound-targets <outbound.jsonl> <method>
"""
import glob
import json
import os
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))
from fm_slack_watch import CARD_LIMIT, Watch


class CardRenderingTest(unittest.TestCase):
    def render(self, reason, body=(), scopes=True, card=None):
        watch = Watch.__new__(Watch)
        watch.api = SimpleNamespace(scopes={'reactions:read', 'users:read'} if scopes else set())
        row = {'id': 'release-call', 'title': 'Release choice',
               'hold_reason': reason, 'body_lines': list(body)}
        return watch.card_payload(row, card or {})[0]

    def test_four_parts_are_ordered_and_multiline(self):
        text = self.render('Alternatives: Ship now skips approval.\n'
                           'Brief: CI is green.\nRollout approval is pending.\n'
                           'Recommendation: Wait for approval.\nIt avoids an unapproved rollout.\n'
                           'Decision sought: Approve waiting?',
                           ['Option 1: Wait (wait)', 'Option 2: Ship (ship)',
                            'Recommendation: ship', 'Evidence: /tmp/review.md'])
        expected = ('Task: release-call\n'
                    'Decision sought: Approve waiting?\n'
                    'Brief description of issue: CI is green.\nRollout approval is pending.\n'
                    'Recommendation and key reasons: Wait for approval.\nIt avoids an unapproved rollout.\n'
                    'Alternatives considered: Ship now skips approval.\n'
                    'Evidence: /tmp/review.md\nOptions:\n1. Wait (wait)\n2. Ship (ship)\n')
        self.assertTrue(text.startswith(expected), text)
        self.assertEqual(text.count('release-call'), 1)
        self.assertNotIn('Question:', text)

    def test_labeled_body_and_long_brief_label(self):
        text = self.render('Choose a rollout.', [
            'Brief description of issue: Rollout is pending.',
            'Alternatives: Immediate rollout skips approval.',
            'Decision sought: Wait?',
            'Recommendation: Wait because approval is missing.',
            'Option 1: Wait (wait)',
        ])
        self.assertIn('Brief description of issue: Rollout is pending.\n', text)
        self.assertIn('Recommendation and key reasons: Wait because approval is missing.\nAlternatives considered:', text)
        self.assertLess(text.index('Decision sought:'), text.index('Brief description of issue:'))
        self.assertLess(text.index('Alternatives considered:'), text.index('Options:'))

    def test_legacy_without_placeholders(self):
        text = self.render('Choose a rollout.', ['Recommendation: none recorded', 'Evidence: not-a-path'])
        self.assertIn('Task: release-call\nDecision: Release choice\nQuestion: Choose a rollout.\n', text)
        self.assertNotIn('none recorded', text)
        self.assertNotIn('Recommendation:', text)
        self.assertNotIn('Evidence:', text)
        self.assertIn('in this thread', text.splitlines()[-1])
        text = self.render('Choose a rollout.', ['Evidence: /tmp/review.md', 'PRIVATE_BODY_NOTES'])
        self.assertIn('Evidence: /tmp/review.md\n', text)
        self.assertNotIn('PRIVATE_BODY_NOTES', text)

    def test_partial_labels_preserve_legacy_question_and_title(self):
        text = self.render('We need to decide the rollout.\nRecommendation: Wait for approval.',
                           ['Brief: Approval is missing.', 'Alternatives: Shipping bypasses approval.'])
        self.assertIn('Decision: Release choice\n', text)
        self.assertIn('Question: We need to decide the rollout.\n', text)
        self.assertIn('Recommendation: Wait for approval.\n', text)
        self.assertEqual(text.count('Wait for approval.'), 1)
        self.assertNotIn('Recommendation and key reasons:', text)
        text = self.render('We need to decide the rollout.\nRecommendation: none recorded')
        self.assertIn('Decision: Release choice\nQuestion: We need to decide the rollout.\n', text)
        self.assertNotIn('none recorded', text)

    def test_footer_is_concise_and_scope_fault_stays_visible(self):
        for options in ([], ['Option 1: Wait (wait)']):
            for scopes in (False, True):
                with self.subTest(options=options, scopes=scopes):
                    text = self.render('Choose a rollout.', options, scopes)
                    footer = text.splitlines()[5 if options else 3:]
                    self.assertEqual(len(footer), 1 + bool(options) + (not scopes))
                    self.assertIn('in this thread', footer[0])
                    self.assertEqual('number' in footer[0], bool(options))
                    self.assertEqual('reaction' in footer[0], bool(options) and scopes)
                    self.assertEqual('Missing reaction scope:' in text, not scopes)
                    self.assertNotIn('none recorded', text)

    def test_oversized_four_parts_keep_all_headings_options_and_footer(self):
        reason = '\n'.join(label + ': ' + '<&>' * 15000 for label in
                           ('Decision sought', 'Brief', 'Recommendation', 'Alternatives'))
        text = self.render(reason, ['Option 1: Wait (wait)', 'Evidence: https://example.com/review'])
        self.assertLessEqual(len(text), CARD_LIMIT)
        for heading in ('Task:', 'Decision sought:', 'Brief description of issue:',
                        'Recommendation and key reasons:', 'Alternatives considered:',
                        'Evidence: https://example.com/review', 'Options:', '1. Wait (wait)'):
            self.assertIn(heading, text)
        self.assertIn('in this thread', text.splitlines()[-2])
        self.assertNotRegex(text, r'&(?!amp;|lt;|gt;)')


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
        for part in ('Task: ', 'Decision: ', 'Question: ', 'in this thread'):
            assert part in text, (key, part)
        assert 'none recorded' not in text, key
    assert 'Recommendation: ship' in cards['with-options']
    assert 'Evidence: /tmp/evidence-with-options.md' in cards['with-options']
    assert 'Options:' in cards['with-options'] and '1. Ship it (ship)' in cards['with-options']
    assert 'Options:' not in cards['no-options']
    assert 'Recommendation:' not in cards['no-recommendation']
    assert 'Evidence:' not in cards['no-recommendation']
    assert 'Options:' in cards['no-recommendation']


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
                if row.get('method') == method and (not thread or row.get('thread_ts') == thread
                                                     or (method == 'chat.update' and row.get('ts') == thread)):
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
    elif command == 'legacy-card':
        def forget_digest(data):
            next(row for row in data['threads'].values() if row['key'] == argv[3]).pop('text_digest', None)
        edit(argv[1], forget_digest)
        def old_layout(data):
            next(m for m in data['messages'] if ('Task: ' + argv[3] + '\n') in m.get('text', ''))['text'] = (
                'Task: ' + argv[3] + '\nDecision: Old layout\nQuestion: Original reason')
        edit(argv[2], old_layout)
    elif command == 'retire-thread':
        def retire_thread(data):
            next(row for row in data['threads'].values() if row['key'] == argv[2])['retired'] = True
        edit(argv[1], retire_thread)
    elif command == 'reaction-state':
        print(json.dumps(json.load(open(argv[1]))['reactions'].get(argv[2], []), sort_keys=True))
    elif command == 'reply':
        extra = json.loads(argv[6]) if len(argv) > 6 else {}
        edit(argv[1], lambda data: data['messages'].append(
            {'ts': argv[3], 'thread_ts': argv[2], 'user': argv[4], 'text': argv[5], **extra}))
    elif command == 'stage-notice':
        edit(argv[1], lambda data: data['pending'].append(
            {'event': 'test/oversized-notice/' + argv[2], 'key': argv[3], 'thread': argv[2],
             'text': 'Oversized notice ' + (argv[5] if len(argv) > 5 else 'n') * int(argv[4]), 'line': 'check: slack %s - oversized notice' % argv[2],
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
    elif command == 'journal-line':
        edit(argv[1], lambda data: data.setdefault('outbox', []).append(argv[2]))
    elif command == 'set-state':
        edit(argv[1], lambda data: data.__setitem__(argv[2], argv[3]))
    elif command == 'set-scopes':
        edit(argv[1], lambda data: data.__setitem__('scopes', argv[2].split(',')))
    elif command == 'fail-call':
        rule = {'status': int(argv[3])}
        if len(argv) > 4:
            rule['times'] = int(argv[4])
        edit(argv[1], lambda data: data['failures'].__setitem__(argv[2], rule))
    elif command == 'clear-fail':
        edit(argv[1], lambda data: data['failures'].pop(argv[2], None))
    elif command == 'move-transcript':
        def move(data):
            data['channel'] = argv[3]
            data['messages'] = []
        data = json.load(open(argv[1]))
        move(data)
        json.dump(data, open(argv[2], 'w'))
    elif command == 'split-transcript':
        data = json.load(open(argv[1]))
        data['channel'], data['owner_dm'], data['messages'] = argv[3], argv[4], []
        json.dump(data, open(argv[2], 'w'))
    elif command == 'add-failure':
        data = json.load(open(argv[1]))
        data.setdefault('failures', {})[argv[3]] = {'status': int(argv[4])}
        json.dump(data, open(argv[2], 'w'))
    elif command == 'outbound-targets':
        rows = [json.loads(line) for line in open(argv[1])]
        print(' '.join(sorted({'%s@%s' % (r.get('recipient'), r.get('channel'))
                               for r in rows if r.get('method') == argv[2]})))
    elif command == 'replay-file':
        paths = glob.glob(os.path.join(argv[1], 'replay-state-*.json'))
        print(paths[0] if paths else '')
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    if len(sys.argv) == 1:
        unittest.main()
    else:
        raise SystemExit(main(sys.argv[1:]))
