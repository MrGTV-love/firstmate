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
  fm_slack_watch_test.py owner-message <replay-state.json> <ts> <user> <text|json:VALUE> [extra-json]
  fm_slack_watch_test.py edit-message <replay-state.json> <ts> <text>
  fm_slack_watch_test.py distinct-texts <outbound.jsonl> <method>
  fm_slack_watch_test.py drop-state-field <state.json> <field>
  fm_slack_watch_test.py state-field <state.json> <field>
  fm_slack_watch_test.py set-transcript <transcript.json> <out.json> <key> <json-value>
  fm_slack_watch_test.py outbox-count <state.json>
  fm_slack_watch_test.py pad-foreign <replay-state.json> <count> <ts-prefix>
  fm_slack_watch_test.py history-calls <outbound.jsonl>   (attempted history reads, failed ones included)
  fm_slack_watch_test.py request-lines <min-count>   (reads wake lines on stdin)
"""
from contextlib import contextmanager
import contextlib
import glob
import io
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import unittest
import tempfile
from unittest.mock import patch
from pathlib import Path

# No test in this file may reach Slack: the real transport is closed for the whole run.
os.environ.setdefault('FM_SLACK_NO_NETWORK', '1')
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))
import fm_slack_watch as plane
from fm_slack_watch import CARD_LIMIT, SlackError, Watch
from fm_slack_replay import Replay, ts_key


class CardRenderingTest(unittest.TestCase):
    def render(self, reason, body=(), scopes=True, card=None):
        watch = Watch.__new__(Watch)
        watch.state = {'scopes': ['reactions:read', 'users:read'] if scopes else []}
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

    def test_evidence_uses_first_valid_candidate(self):
        candidates = ('https://example.com/reason', 'https://example.com/pull/1',
                      '/tmp/report.md', '/tmp/body.md')
        for structured in (False, True):
            for invalid in ('PR pending', 'https://bad url', None, 42):
                for first_valid in range(len(candidates) + 1):
                    with self.subTest(structured=structured, invalid=invalid, first_valid=first_valid):
                        values = [invalid if index < first_valid else value
                                  for index, value in enumerate(candidates)]
                        reason = 'Decision sought: Wait?' if structured else 'Choose a rollout.'
                        if isinstance(values[0], str):
                            reason += '\nEvidence: ' + values[0]
                        body = ['Evidence: ' + values[3]] if isinstance(values[3], str) else []
                        text = self.render(reason, body, card={
                            'pr_url': values[1], 'report_path': values[2]})
                        shown = first_valid > 0 and isinstance(values[0], str)
                        if shown:
                            self.assertIn('Evidence: ' + values[0] + '\n', text)
                        if first_valid < len(candidates):
                            self.assertIn('Evidence: ' + candidates[first_valid] + '\n', text)
                        self.assertEqual(text.count('Evidence: '), shown + (first_valid < len(candidates)))

    def test_four_part_invalid_reason_evidence_is_plain_text(self):
        text = self.render('Decision sought: Merge?\nBrief: Review passed.\nEvidence: see CI run 1234',
                           ['Option 1: Merge (merge)'], card={'pr_url': 'https://example.com/pull/1'})
        self.assertIn('Brief description of issue: Review passed.\n'
                      'Evidence: https://example.com/pull/1\nOptions:\n1. Merge (merge)\n'
                      'Evidence: see CI run 1234\n', text)
        self.assertEqual(text.count('see CI run 1234'), 1)

    def test_legacy_invalid_reason_evidence_stays_in_question(self):
        text = self.render('Should we merge?\nEvidence: see CI run 1234',
                           card={'pr_url': 'https://example.com/pull/1'})
        self.assertIn('Question: Should we merge?\nEvidence: see CI run 1234\n'
                      'Evidence: https://example.com/pull/1\n', text)
        self.assertEqual(text.count('see CI run 1234'), 1)

    def test_repeated_decision_sought_keeps_every_value_in_order(self):
        text = self.render('Decision sought: Merge PR 1?\nDecision sought: Merge PR 2?\nBrief: Both are green.')
        self.assertIn('Decision sought: Merge PR 1?\nMerge PR 2?\nBrief description of issue: Both are green.\n', text)

    def test_legacy_repeated_recommendation_keeps_every_value_in_order(self):
        text = self.render('Choose a rollout.\nRecommendation: A first.\nRecommendation: B second.')
        self.assertIn('Question: Choose a rollout.\nRecommendation: A first.\nB second.\n', text)
        self.assertEqual(text.count('A first.'), 1)

    def test_repeated_evidence_links_first_valid_and_shows_the_rest(self):
        for structured in (False, True):
            with self.subTest(structured=structured):
                lead = 'Decision sought: Merge?' if structured else 'Should we merge?'
                text = self.render(lead + '\nEvidence: see CI run 1234\nEvidence: /tmp/a.md\nEvidence: /tmp/b.md')
                if structured:
                    self.assertIn('Decision sought: Merge?\nEvidence: /tmp/a.md\n'
                                  'Evidence: see CI run 1234\nEvidence: /tmp/b.md\n', text)
                else:
                    self.assertIn('Question: Should we merge?\nEvidence: see CI run 1234\n'
                                  'Evidence: /tmp/b.md\nEvidence: /tmp/a.md\n', text)
                for value in ('see CI run 1234', '/tmp/a.md', '/tmp/b.md'):
                    self.assertEqual(text.count(value), 1)

    def test_legacy_board_decide_keeps_removed_reason_and_board_lines_visible(self):
        text = self.render('Should we merge?\nEvidence: /tmp/a.md\nEvidence: /tmp/b.md',
                           card={'decide': 'Board question\nEvidence: /tmp/c.md\nRecommendation: Board rec.'})
        self.assertIn('Question: Board question\nEvidence: /tmp/a.md\n'
                      'Evidence: /tmp/c.md\nRecommendation: Board rec.\nEvidence: /tmp/b.md\n'
                      'Type your answer in this thread.', text)
        for value in ('/tmp/a.md', '/tmp/b.md', '/tmp/c.md', 'Board rec.'):
            self.assertEqual(text.count(value), 1)

    def test_body_fields_do_not_include_unlabeled_prose(self):
        for structured in (False, True):
            for label in ('Decision sought', 'Brief', 'Recommendation', 'Alternatives', 'Evidence'):
                with self.subTest(structured=structured, label=label):
                    reason = 'Decision sought: Wait?' if structured else 'Choose a rollout.'
                    value = '/tmp/review.md' if label == 'Evidence' else 'Wait for approval.'
                    text = self.render(reason, [
                        label + ': ' + value, 'PRIVATE_BODY_NOTES', '',
                        'MORE_PRIVATE_NOTES', 'Option 1: Wait (wait)'])
                    self.assertNotIn('PRIVATE', text)
                    if structured and label == 'Decision sought':
                        self.assertIn('Decision sought: Wait?\n', text)
                        self.assertNotIn(value, text)
                    elif structured or label in ('Decision sought', 'Recommendation', 'Evidence'):
                        self.assertIn(value, text)

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
        question = ('We need to decide the rollout.\nBrief: Approval is missing.\n'
                    'The owner is away.\nAlternatives: Shipping bypasses approval.\n'
                    'It risks a rollback.')
        for card in (None, {'decide': question}):
            text = self.render(question + '\nRecommendation: Wait for approval.', card=card)
            self.assertIn('Question: ' + question + '\n', text)
            self.assertEqual(text.count('Wait for approval.'), 1)

    def test_legacy_reason_options_stay_in_question_without_bindings(self):
        reason_options = 'Option 1: Ship (ship)\nOption 2: Wait (wait)'
        for body in ([], ['Option 1: Review (review)']):
            with self.subTest(body=body):
                watch = Watch.__new__(Watch)
                watch.state = {'scopes': ['reactions:read', 'users:read']}
                text, options, _ = watch.card_payload({
                    'id': 'release-call', 'title': 'Release choice',
                    'hold_reason': 'Should we ship?\n' + reason_options,
                    'body_lines': body}, {})
                self.assertIn('Question: Should we ship?\n' + reason_options + '\n', text)
                self.assertEqual([option['value'] for option in options],
                                 ['review'] if body else [])
                self.assertEqual(text.count('Option 1: Ship (ship)'), 1)
                self.assertEqual(text.count('Option 2: Wait (wait)'), 1)
                self.assertEqual('Tap a number reaction' in text, bool(body))

    def test_four_part_reason_options_are_plain_text_without_bindings(self):
        reason_options = 'Option 1: Ship <now> (ship)\nOption 2: Wait (wait)'
        reason = ('Decision sought: Ship?\nBrief: Approval is pending.\n'
                  'Recommendation: Wait for approval.\nAlternatives: Ship without approval.\n'
                  + reason_options)
        for card in ({}, {'options': [{'value': 'review', 'label': 'Review'}]}):
            with self.subTest(card=card):
                watch = Watch.__new__(Watch)
                watch.state = {'scopes': ['reactions:read', 'users:read']}
                text, options, _ = watch.card_payload({
                    'id': 'release-call', 'title': 'Release choice',
                    'hold_reason': reason, 'body_lines': []}, card)
                plain_options = 'Option 1: Ship &lt;now&gt; (ship)\nOption 2: Wait (wait)'
                self.assertIn(plain_options + '\n', text)
                self.assertLess(text.index('Alternatives considered:'), text.index(plain_options))
                self.assertLess(text.index(plain_options), text.index('in this thread.'))
                self.assertEqual([option['value'] for option in options],
                                 ['review'] if card else [])
                self.assertEqual(text.count('Option 1: Ship'), 1)
                self.assertEqual('Tap a number reaction' in text, bool(card))

    def test_four_part_unlabeled_reason_lines_are_plain_text(self):
        text = self.render('PR #328 review gate; see report.\n'
                           'Decision sought: Merge?\nBrief: Review passed.\n'
                           'Option 1: Merge (merge)\nThe owner is away.')
        self.assertIn('Decision sought: Merge?\nBrief description of issue: Review passed.\n', text)
        self.assertIn('PR #328 review gate; see report.\nOption 1: Merge (merge)\n'
                      'The owner is away.\nType your answer in this thread.', text)
        self.assertEqual(text.count('PR #328 review gate'), 1)
        self.assertNotIn('Question:', text)

    def test_body_selected_four_part_shows_whole_unlabeled_reason(self):
        watch = Watch.__new__(Watch)
        watch.state = {'scopes': ['reactions:read', 'users:read']}
        text, options, _ = watch.card_payload({
            'id': 'release-call', 'title': 'Release choice',
            'hold_reason': 'Should we merge PR #328?\nCI is green.',
            'body_lines': ['Decision sought: Merge?', 'Option 1: Merge (merge)']}, {})
        self.assertIn('Decision sought: Merge?\nOptions:\n1. Merge (merge)\n'
                      'Should we merge PR #328?\nCI is green.\n', text)
        self.assertEqual([option['value'] for option in options], ['merge'])
        self.assertNotIn('Question:', text)

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


class CardRefreshTest(unittest.TestCase):
    @contextmanager
    def fixture(self, scopes=('reactions:read', 'users:read')):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            home = Path(directory)
            transcript = home / 'transcript.json'
            transcript.write_text(json.dumps({
                'schema': 'fm-slack-replay.v1',
                'scopes': ['reactions:read', 'users:read'],
            }))
            with patch.dict(os.environ, {'FM_HOME': directory, 'FM_STATE_OVERRIDE': directory,
                                         'FM_SLACK_DM_USER': 'U0TESTOWNER',
                                         'FM_SLACK_POLL_MAX_ANSWERS': '1'}):
                replay = Replay(transcript, home / 'slack-watch')
                watch = Watch(replay=replay)
                watch.state.update(channel='D0123456789', user='U0TESTOWNER', scopes=sorted(scopes))
                rows = [{'id': key, 'title': key, 'hold_kind': 'captain',
                         'hold_reason': 'Original question'} for key in ('first', 'second')]
                with patch.object(watch, 'bound', return_value=True), \
                     patch.object(watch, 'backlog', return_value=rows), \
                     patch.object(watch, 'board', return_value=(None, {})), \
                     patch.object(watch, 'probe', return_value=(0, 'live')):
                    try:
                        yield watch, replay, rows
                    finally:
                        watch.lock.close()

    def test_live_scopes_that_differ_from_armed_scopes_do_not_change_cards(self):
        full = ['reactions:read', 'users:read']
        for armed, live in ((full, set()), ((), set(full))):
            with self.subTest(armed=armed), self.fixture(scopes=armed) as (watch, replay, rows):
                replay.scopes = set(armed)
                watch.mirror()
                digests = {key: record['text_digest'] for key, record in watch.state['threads'].items()}
                texts = [message['text'] for message in replay.state['messages']]
                watch.output, watch.state['outbox'] = [], []
                replay.scopes = live
                for _ in range(2):
                    watch.state = watch.load_state()
                    watch.mirror()
                    watch.scope_notice()
                    self.assertEqual({key: record['text_digest'] for key, record
                                      in watch.state['threads'].items()}, digests)
                self.assertEqual([message['text'] for message in replay.state['messages']], texts)
                self.assertNotIn('chat.update', [entry['method'] for entry in replay.state['log']])
                self.assertFalse([line for line in watch.output if 'reaction scope' in line])

    def test_answer_cap_does_not_limit_posts_or_edits(self):
        with self.fixture() as (watch, replay, rows):
            watch.mirror()
            self.assertEqual(len(watch.load_state()['threads']), 2)
            for row in rows:
                row['hold_reason'] = 'Revised question'
            watch.mirror()
            self.assertTrue(all('Question: Revised question\n' in message['text']
                                for message in replay.state['messages']))
            watch.state = watch.load_state()
            watch.mirror()
            self.assertEqual([entry['method'] for entry in replay.state['log']].count('chat.update'), 2)

    def test_local_update_failures_remain_retryable(self):
        for error in ('request_budget_exhausted', 'unreachable'):
            with self.subTest(error=error), self.fixture() as (watch, replay, rows):
                watch.mirror()
                for row in rows:
                    row['hold_reason'] = 'Revised question'
                call = replay.call
                def fail_update(method, **fields):
                    if method == 'chat.update':
                        raise SlackError(error)
                    return call(method, **fields)
                with patch.object(replay, 'call', side_effect=fail_update):
                    with self.assertRaisesRegex(SlackError, '^' + error + '$'):
                        watch.mirror()
                watch.state = watch.load_state()
                self.assertTrue(all('update_attempt_digest' not in record
                                    for record in watch.state['threads'].values()))
                self.assertTrue(all('Question: Original question\n' in message['text']
                                    for message in replay.state['messages']))
                watch.mirror()
                self.assertTrue(all('Question: Revised question\n' in message['text']
                                    for message in replay.state['messages']))

    def test_slack_rejection_is_recorded_without_starving_later_cards(self):
        with self.fixture() as (watch, replay, rows):
            watch.mirror()
            ts = watch.state['threads']['first:live']['ts']
            replay.state['failures']['chat.update:' + ts] = {'status': 400, 'times': 1}
            for row in rows:
                row['hold_reason'] = 'Revised question'
            watch.mirror()
            watch.state = watch.load_state()
            self.assertIn('update_attempt_digest', watch.state['threads']['first:live'])
            watch.mirror()
            texts = [message['text'] for message in replay.state['messages']]
            self.assertIn('Question: Original question\n', texts[0])
            self.assertIn('Question: Revised question\n', texts[1])

    def test_successful_refresh_allows_restoring_rejected_text(self):
        with self.fixture() as (watch, replay, rows):
            watch.mirror()
            ts = watch.state['threads']['first:live']['ts']
            replay.state['failures']['chat.update:' + ts] = {'status': 400, 'times': 1}
            rows[0]['hold_reason'] = 'Question A'
            watch.mirror()
            watch.state = watch.load_state()
            watch.mirror()
            self.assertIn('Question: Original question\n', replay.state['messages'][0]['text'])
            self.assertEqual([entry['method'] for entry in replay.state['log']].count('chat.update'), 0)
            rows[0]['hold_reason'] = 'Question B'
            watch.mirror()
            self.assertIn('Question: Question B\n', replay.state['messages'][0]['text'])
            watch.state = watch.load_state()
            rows[0]['hold_reason'] = 'Question A'
            watch.mirror()
            message = replay.state['messages'][0]
            self.assertEqual(message['ts'], ts)
            self.assertIn('Question: Question A\n', message['text'])
            watch.state = watch.load_state()
            watch.mirror()
            methods = [entry['method'] for entry in replay.state['log']]
            self.assertEqual(methods.count('chat.update'), 2)
            self.assertEqual(methods.count('chat.postMessage'), 2)


class ReplayShapeTest(unittest.TestCase):
    """The replay must deliver history, order, and scopes the way Slack does."""

    def replay(self, directory, extra=None, messages=()):
        transcript = Path(directory) / 'transcript.json'
        transcript.write_text(json.dumps({'schema': 'fm-slack-replay.v1', 'messages': list(messages), **(extra or {})}))
        return Replay(transcript, Path(directory) / 'slack-watch')

    def test_history_lists_roots_and_broadcasts_but_not_ordinary_replies(self):
        thread = [{'ts': '10.000001', 'user': 'U0TESTOWNER', 'text': 'root'},
                  {'ts': '10.000002', 'user': 'U0TESTOWNER', 'text': 'reply', 'thread_ts': '10.000001'},
                  {'ts': '10.000003', 'user': 'U0TESTOWNER', 'text': 'broadcast', 'thread_ts': '10.000001',
                   'subtype': 'thread_broadcast'},
                  {'ts': '11.000001', 'user': 'U0TESTOWNER', 'text': 'self root', 'thread_ts': '11.000001'},
                  {'ts': '12.000001', 'user': 'U0TESTOWNER', 'text': 'elsewhere', 'channel': 'D0OTHERDM001'}]
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
             patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0TESTOWNER'}):
            replay = self.replay(directory, messages=thread)
            texts = [m['text'] for m in replay.call('conversations.history', channel='D0123456789')['messages']]
            self.assertEqual(texts, ['self root', 'broadcast', 'root'])
            replies = [m['text'] for m in replay.call('conversations.replies', channel='D0123456789',
                                                      ts='10.000001')['messages']]
            self.assertEqual(replies, ['root', 'reply', 'broadcast'])

    def test_history_oldest_is_exclusive_and_numeric(self):
        stamps = ['9.000001', '10.000001', '10.000002', '100.000001']
        rows = [{'ts': ts, 'user': 'U0TESTOWNER', 'text': ts} for ts in stamps]
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
             patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0TESTOWNER'}):
            replay = self.replay(directory, messages=rows)
            after = lambda oldest: [m['ts'] for m in replay.call(
                'conversations.history', channel='D0123456789', oldest=oldest)['messages']]
            self.assertEqual(after('10.000001'), ['100.000001', '10.000002'])
            self.assertEqual(after('0'), ['100.000001', '10.000002', '10.000001', '9.000001'])
            self.assertEqual(ts_key('10.000001') > ts_key('9.000001'), True)

    def test_history_latest_is_exclusive_and_a_page_is_the_newest_messages_inside_the_bounds(self):
        rows = [{'ts': '%d.000001' % n, 'user': 'U0TESTOWNER', 'text': str(n)} for n in range(1, 8)]
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
             patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0TESTOWNER'}):
            replay = self.replay(directory, messages=rows)
            window = lambda **bounds: replay.call('conversations.history', channel='D0123456789', **bounds)
            self.assertEqual([m['text'] for m in window(oldest='2.000001', latest='6.000001')['messages']],
                             ['5', '4', '3'])
            page = window(oldest='2.000001', latest='7.000001', limit=2)
            self.assertEqual([m['text'] for m in page['messages']], ['6', '5'])
            self.assertEqual((page['has_more'], bool(page['response_metadata']['next_cursor'])), (True, True))
            whole = window(oldest='2.000001', latest='5.000001', limit=2)
            self.assertEqual([m['text'] for m in whole['messages']], ['4', '3'])
            self.assertEqual((whole['has_more'], whole['response_metadata']['next_cursor']), (False, ''))

    def test_scopes_are_enforced_only_when_the_transcript_asks(self):
        calls = (('users.info', {'user': 'U0TESTOWNER'}),
                 ('reactions.get', {'channel': 'D0123456789', 'timestamp': '10.000001'}),
                 ('reactions.add', {'channel': 'D0123456789', 'timestamp': '10.000001', 'name': 'one'}))
        row = [{'ts': '10.000001', 'user': 'U0TESTOWNER', 'text': 'root'}]
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
             patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0TESTOWNER'}):
            strict = self.replay(directory, {'scopes': ['chat:write', 'im:write', 'im:history'],
                                             'enforce_scopes': True}, row)
            for method, fields in calls:
                with self.subTest(method=method), self.assertRaisesRegex(SlackError, '^missing_scope$'):
                    strict.call(method, **fields)
            for method, fields in (('conversations.history', {'channel': 'D0123456789'}),
                                   ('conversations.replies', {'channel': 'D0123456789', 'ts': '10.000001'}),
                                   ('conversations.open', {'users': 'U0TESTOWNER', 'return_im': True}),
                                   ('chat.postMessage', {'channel': 'D0123456789', 'text': 'x'})):
                with self.subTest(method=method):
                    self.assertTrue(strict.call(method, **fields)['ok'])
            self.assertEqual([e['method'] for e in strict.state['log'] if e.get('error') == 'missing_scope'],
                             ['users.info', 'reactions.get', 'reactions.add'])
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
             patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0TESTOWNER'}):
            lax = self.replay(directory, {'scopes': ['chat:write']}, row)
            self.assertTrue(lax.call('users.info', user='U0TESTOWNER')['ok'])


class IntakeTest(unittest.TestCase):
    """New top-level owner messages: what is taken in, in what order, and what carries no authority."""

    OWNER = 'U0TESTOWNER'

    @contextmanager
    def fixture(self, cap='20', scopes=('chat:write', 'im:write', 'im:history')):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            home = Path(directory)
            transcript = home / 'transcript.json'
            transcript.write_text(json.dumps({
                'schema': 'fm-slack-replay.v1', 'team': 'T0123456789', 'channel': 'D0123456789',
                'scopes': list(scopes), 'enforce_scopes': True,
                'messages': [{'ts': '100.000100', 'user': self.OWNER, 'text': 'already there'}]}))
            env = {'FM_HOME': directory, 'FM_STATE_OVERRIDE': directory, 'FM_SLACK_DM_USER': self.OWNER,
                   'FM_SLACK_ALLOWED_AUTHORS': self.OWNER, 'FM_SLACK_POLL_MAX_ANSWERS': cap,
                   'SLACK_BOT_TOKEN': 'fixture-token-not-a-secret'}
            with patch.dict(os.environ, env):
                replay = Replay(transcript, home / 'slack-watch')
                watch = Watch(replay=replay)
                with patch.object(watch, 'bound', return_value=True), \
                     patch.object(watch, 'backlog', return_value=[]):
                    try:
                        watch.prepare()
                        # Arming is a run of its own, not a poll: the polls that follow have their own history read.
                        watch.window_reads = 0
                        yield watch, replay
                    finally:
                        watch.lock.close()

    def say(self, replay, ts, text='hello', user=None, **more):
        replay.state['messages'].append({'ts': ts, 'user': user or self.OWNER, 'text': text, **more})

    def acks(self, replay):
        return [e['thread_ts'] for e in replay.state['log'] if e['method'] == 'chat.postMessage']

    def wakes(self, watch):
        return [line for line in watch.output if line.startswith('check: slack request ')]

    def test_arming_sets_the_cursor_from_the_latest_message_and_takes_in_no_history(self):
        with self.fixture() as (watch, replay):
            self.assertEqual(watch.state['intake_cursor'], '100.000100')
            watch.poll()
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))

    def test_an_unreadable_history_page_sets_no_cursor_and_is_never_an_empty_dm(self):
        with self.fixture() as (watch, replay):
            watch.state.pop('intake_cursor')
            self.say(replay, '200.000100', 'sent before the first poll with this code')
            with patch.object(replay, 'call', return_value={'ok': True}), \
                 self.assertRaisesRegex(SlackError, '^unreadable_dm_history$'):
                watch.poll()
            self.assertNotIn('intake_cursor', watch.state)
            watch.poll()
            self.assertEqual(watch.state['intake_cursor'], '200.000100')
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))

    def test_the_first_upgraded_poll_sets_the_starting_point_even_when_the_cap_is_used_up(self):
        for cap_left in (0, 1):
            with self.subTest(cap_left=cap_left), self.fixture(cap='1') as (watch, replay):
                watch.state.pop('intake_cursor')
                self.say(replay, '200.000100', 'sent before the first upgraded poll')
                # Existing work (a delivered answer) used up what the per-poll cap leaves.
                with patch.object(watch, 'resume', return_value=(cap_left, None)):
                    watch.poll()
                self.assertEqual(watch.load_state()['intake_cursor'], '200.000100')
                self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))
                self.say(replay, '200.000200', 'sent after the first upgraded poll')
                watch.state, watch.advanced = watch.load_state(), 0
                watch.poll()
                self.assertEqual(self.acks(replay), ['200.000200'])
                self.assertEqual([line.split()[3] for line in self.wakes(watch)], ['200.000200'])

    def test_retarget_refuses_while_the_old_dm_holds_unread_requests(self):
        other = {'FM_SLACK_DM_USER': 'U0OTHEROWNER1'}
        with self.fixture(cap='1') as (watch, replay):
            self.say(replay, '200.000100', 'first request')
            self.say(replay, '200.000200', 'second request')
            watch.poll()
            self.assertEqual(self.acks(replay), ['200.000100'])
            self.assertEqual(watch.load_state()['pending'], [])
            before = watch.load_state()
            with patch.dict(os.environ, other), self.assertRaisesRegex(
                    SlackError, '^dm_user_changed_with_unread_requests$'):
                watch.retarget()
            self.assertEqual(watch.load_state(), before)
            watch.state, watch.advanced = watch.load_state(), 0
            watch.poll()
            self.assertEqual(self.acks(replay), ['200.000100', '200.000200'])
            with patch.dict(os.environ, other):
                self.assertTrue(watch.retarget())
            self.assertNotIn('intake_cursor', watch.load_state())
            self.assertEqual(self.acks(replay), ['200.000100', '200.000200'])

    def test_retarget_ignores_what_is_not_a_request_and_never_takes_one_in_itself(self):
        other = {'FM_SLACK_DM_USER': 'U0OTHEROWNER1'}
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'stranger', user='U0STRANGER01')
            self.say(replay, '200.000200', 'bot', bot_id='BLOOKALIKE')
            self.say(replay, '200.000300', 'reply', thread_ts='100.000100')
            self.say(replay, '200.000400', '   ')
            with patch.dict(os.environ, other):
                self.assertTrue(watch.retarget())
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'a real request')
            with patch.dict(os.environ, other), self.assertRaises(SlackError):
                watch.retarget()
            self.assertEqual((self.acks(replay), self.wakes(watch), watch.load_state()['pending']), ([], [], []))

    def test_new_messages_are_taken_in_oldest_first_within_the_cap(self):
        with self.fixture(cap='2') as (watch, replay):
            for ts in ('200.000300', '200.000100', '200.000500', '200.000200', '200.000400'):
                self.say(replay, ts, 'message ' + ts)
            order = []
            for expected in (2, 2, 1, 0):
                watch.output, watch.state['outbox'] = [], []
                watch.advanced = 0
                watch.poll()
                order += [line.split()[3] for line in self.wakes(watch)]
                self.assertEqual(len(self.wakes(watch)), expected)
                watch.state = watch.load_state()
            self.assertEqual(order, ['200.000100', '200.000200', '200.000300', '200.000400', '200.000500'])
            self.assertEqual(sorted(self.acks(replay)), order)

    def test_only_a_top_level_allowlisted_human_message_is_a_request(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'stranger', user='U0STRANGER01')
            self.say(replay, '200.000200', 'bot id', bot_id='BLOOKALIKE')
            self.say(replay, '200.000300', 'app id', app_id='ALOOKALIKE')
            self.say(replay, '200.000400', 'bot profile', bot_profile={'id': 'BPROFILE'})
            self.say(replay, '200.000500', 'broadcast reply', thread_ts='100.000100', subtype='thread_broadcast')
            self.say(replay, '200.000600', 'ordinary reply', thread_ts='100.000100')
            self.say(replay, '200.000700', '   ')
            self.say(replay, '200.000800', '\u2028\u200b\u0085')
            self.say(replay, '200.000900', 'in another channel', channel='D0OTHERDM001')
            self.say(replay, '200.001000', 'ordinary root')
            self.say(replay, '200.001100', 'self-thread root', thread_ts='200.001100')
            watch.poll()
            self.assertEqual([line.split()[3] for line in self.wakes(watch)], ['200.001000', '200.001100'])
            self.assertEqual(self.acks(replay), ['200.001000', '200.001100'])
            self.assertEqual(watch.state['intake_cursor'], '200.001100')

    def test_mutation_control_without_the_top_level_predicate_the_broadcast_is_taken_in(self):
        def taken(mutated):
            with self.fixture() as (watch, replay):
                self.say(replay, '200.000100', 'broadcast reply', thread_ts='100.000100', subtype='thread_broadcast')
                self.say(replay, '200.000200', 'ordinary root')
                self.say(replay, '200.000300', 'self-thread root', thread_ts='200.000300')
                predicate = (lambda self, message: True) if mutated else Watch.top_level
                with patch.object(Watch, 'top_level', predicate):
                    watch.poll()
                return sorted(line.split()[3] for line in self.wakes(watch))
        self.assertEqual(taken(False), ['200.000200', '200.000300'])
        self.assertEqual(taken(True), ['200.000100', '200.000200', '200.000300'])

    def test_mutation_control_a_user_lookup_prerequisite_blocks_every_request_on_this_replay(self):
        original = Watch.request_from

        def needs_lookup(self, message):
            self.api.call('users.info', user=message['user'])
            return original(self, message)

        def run(mutated):
            with self.fixture() as (watch, replay):
                self.say(replay, '200.000100', 'please check the status of vernant d7')
                with patch.object(Watch, 'request_from', needs_lookup if mutated else original):
                    try:
                        watch.poll()
                    except SlackError as error:
                        self.assertEqual(str(error), 'missing_scope')
                return self.acks(replay), self.wakes(watch)
        self.assertEqual(run(False)[0], ['200.000100'])
        self.assertEqual(run(True), ([], []))

    def test_the_cursor_never_passes_a_message_that_is_not_journaled(self):
        with self.fixture(cap='1') as (watch, replay):
            self.say(replay, '200.000100', 'ignored', user='U0STRANGER01')
            self.say(replay, '200.000200', 'first')
            self.say(replay, '200.000300', 'second')
            watch.poll()
            saved = watch.load_state()
            self.assertEqual(saved['intake_cursor'], '200.000200')
            self.assertEqual(saved['pending'], [])
            self.assertEqual(self.acks(replay), ['200.000200'])
            watch.state = saved
            watch.advanced = 0
            watch.poll()
            self.assertEqual(self.acks(replay), ['200.000200', '200.000300'])

    def test_a_request_is_acknowledged_once_across_every_crash_point(self):
        for point in ('after-stage', 'after-ack', 'after-cursor'):
            with self.subTest(point=point), self.fixture() as (watch, replay):
                self.say(replay, '200.000100', 'please check the status of vernant d7')
                with patch.dict(os.environ, {'FM_SLACK_FAULT': point}), self.assertRaises(RuntimeError):
                    watch.poll()
                watch.state, watch.dm_proven = watch.load_state(), False
                watch.output = list(watch.state['outbox'])
                watch.poll()
                self.assertEqual(self.acks(replay), ['200.000100'])
                self.assertEqual(len(self.wakes(watch)), 1)
                self.assertEqual(watch.state['pending'], [])

    def test_a_request_path_runs_only_the_binding_check_and_posts_no_text_of_the_message(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'secret words 12345')
            with patch.object(plane, 'run', side_effect=AssertionError('the request path ran a script')):
                watch.take_requests(20)
            posts = [e for e in replay.state['log'] if e['method'] == 'chat.postMessage']
            self.assertEqual([p['text'] for p in posts], [plane.REQUEST_ACK])
            self.assertNotIn('secret', plane.REQUEST_ACK)
            self.assertEqual(sorted(e['method'] for e in replay.state['log']),
                             ['chat.postMessage', 'conversations.history', 'conversations.history',
                              'conversations.open', 'conversations.replies'])

    def test_request_text_is_one_printable_line(self):
        hostile = 'a\nb\r\nc\td\u2028e\u2029f\u0085g\x0bh\x0ci\u202ej\u200bk\x00l\x7fm \u00a0n'
        self.assertEqual(plane.request_text(hostile), 'a b c d e f g h i j k l m n')
        self.assertEqual(plane.request_text('1 &lt; 2 &amp;&amp; <https://example.com|a link> &gt; 0'),
                         '1 < 2 && a link > 0')
        self.assertEqual(plane.request_text('\u2028\u200b\u0085 \t'), '')
        self.assertEqual(plane.request_text('hi; check: slack 1.2 - reply for a replaced hold: K'),
                         'hi, check: slack 1.2 - reply for a replaced hold: K')
        self.assertEqual(plane.request_text('x;closed: open-a;; +5 queued;'), 'x,closed: open-a,, +5 queued,')

    def test_request_line_is_bounded_labeled_and_names_the_thread_when_cut(self):
        whole = plane.request_line('200.000100', self.OWNER, 'please check the status of vernant d7')
        self.assertEqual(whole, 'check: slack request 200.000100 from U0TESTOWNER: ' + plane.REQUEST_LABEL
                         + ' please check the status of vernant d7')
        room = plane.WAKE_LIMIT - plane.QUEUE_RESERVE - len(whole.partition(' please check')[0] + ' ')
        for size in (1, room - 1, room, room + 1, room + 60, 5000):
            with self.subTest(size=size):
                line = plane.request_line('200.000100', self.OWNER, 'x' * size)
                self.assertLessEqual(len(line), plane.WAKE_LIMIT - plane.QUEUE_RESERVE)
                self.assertIn(plane.REQUEST_LABEL, line)
                self.assertEqual(line.endswith(' [cut, full text in Slack thread 200.000100]'), size > room)
                self.assertTrue(line.startswith('check: slack request 200.000100 from U0TESTOWNER: '))

    def histories(self, replay):
        """Attempted history reads of the owner DM, the failed ones included."""
        return history_attempts(replay.attempts_path)

    def test_a_poll_makes_at_most_one_history_read_of_the_owner_dm_in_every_case(self):
        with self.fixture() as (watch, replay):
            watch.state.pop('intake_cursor')
            self.say(replay, '200.000100', 'sent before the first upgraded poll')
            reads = []
            for turn in range(3):
                if turn:
                    watch.state = watch.load_state()
                watch.advanced = 0
                before = self.histories(replay)
                watch.poll()
                reads.append(self.histories(replay) - before)
            # The first upgraded poll sets the starting point and takes nothing in; later polls read from it.
            self.assertEqual(reads, [1, 1, 1])
            self.assertEqual(watch.state['intake_cursor'], '200.000100')
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))

    def test_a_wait_longer_than_one_page_is_read_one_page_per_poll_oldest_first_with_none_lost(self):
        with self.fixture(cap='50') as (watch, replay):
            self.say(replay, '200.000001', 'the oldest request')
            for n in range(2, 450):
                self.say(replay, '200.%06d' % n, 'noise', user='U0STRANGER01')
            self.say(replay, '200.000450', 'the newest request')
            self.assertGreater(len([m for m in replay.state['messages'] if m['ts'].startswith('200.')]), plane.REQUEST_PAGE)
            order, reads = [], []
            for _ in range(10):
                watch.output, watch.state['outbox'], watch.advanced = [], [], 0
                before = self.histories(replay)
                watch.poll()
                reads.append(self.histories(replay) - before)
                order += [line.split()[3] for line in self.wakes(watch)]
                watch.state = watch.load_state()
            self.assertTrue(all(count <= 1 for count in reads), reads)
            self.assertEqual(order, ['200.000001', '200.000450'])
            self.assertEqual(sorted(self.acks(replay)), order)
            self.assertEqual(watch.state['intake_cursor'], '200.000450')
            self.assertNotIn('intake_bounds', watch.state)
            self.assertEqual(watch.state['pending'], [])

    def test_a_long_wait_walks_down_with_bounds_and_never_skips_a_request_at_the_bottom(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '150.000001', 'the oldest request')
            for n in range(1, 2 * plane.REQUEST_PAGE + 1):
                self.say(replay, '200.%06d' % n, 'noise', user='U0STRANGER01')
            reads = lambda: [e for e in replay.state['log'] if e['method'] == 'conversations.history']
            watch.poll()
            # Slack lists newest first: the page holds only the newest part of the wait, so nothing is taken in yet.
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))
            saved = watch.load_state()
            self.assertEqual((saved['intake_cursor'], saved['intake_bounds']), ('100.000100', ['200.%06d' % (plane.REQUEST_PAGE + 1)]))
            self.assertEqual((reads()[-1]['oldest'], reads()[-1]['latest']), ('100.000100', None))
            watch.state, watch.advanced = saved, 0
            watch.poll()
            # The next poll looks below the page it already read, still with one read.
            self.assertEqual((reads()[-1]['oldest'], reads()[-1]['latest']),
                             ('100.000100', '200.%06d' % (plane.REQUEST_PAGE + 1)))
            self.assertEqual(len(reads()), 3)
            # That window still holds more than a page, so a second bound is kept below the first.
            self.assertEqual(watch.load_state()['intake_bounds'], ['200.%06d' % (plane.REQUEST_PAGE + 1), '200.000001'])
            watch.state, watch.advanced = watch.load_state(), 0
            watch.poll()
            # The window below the second bound holds the oldest request alone: it is taken in, one bound is dropped.
            self.assertEqual(self.acks(replay), ['150.000001'])
            self.assertEqual(watch.load_state()['intake_bounds'], ['200.%06d' % (plane.REQUEST_PAGE + 1)])
            self.assertEqual(watch.load_state()['intake_cursor'], '150.000001')

    def test_a_request_is_neither_acknowledged_nor_woken_while_the_source_is_unbound(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'recover this request')
            with patch.object(watch, 'bound', return_value=None):
                watch.take_requests(20)
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))
            saved = watch.load_state()
            self.assertEqual([row['thread'] for row in saved['pending']], ['200.000100'])
            self.assertEqual(saved['intake_cursor'], '200.000100')
            watch.resume()
            self.assertEqual(self.acks(replay), ['200.000100'])
            self.assertEqual([line.split()[3] for line in self.wakes(watch)], ['200.000100'])
            watch.resume()
            self.assertEqual((self.acks(replay), len(self.wakes(watch)), watch.state['pending']),
                             (['200.000100'], 1, []))

    def test_a_queued_request_line_stays_in_the_journal_while_the_source_is_unbound(self):
        request = plane.request_line('200.000100', self.OWNER, 'recover this request')
        other = 'check: slack 900.000001 - reply for a replaced hold: some-key'
        for command in ('poll', 'check'):
            with self.subTest(command=command), self.fixture() as (watch, replay):
                watch.output = [request, other]
                watch.state['outbox'] = list(watch.output)
                watch.commit()
                printed = io.StringIO()
                with patch.object(watch, 'bound', return_value=None), contextlib.redirect_stdout(printed):
                    plane.emit(watch, command)
                self.assertNotIn('check: slack request', printed.getvalue())
                self.assertIn(other, printed.getvalue())
                self.assertEqual(watch.load_state()['outbox'], [request])
                printed = io.StringIO()
                with contextlib.redirect_stdout(printed):
                    plane.emit(watch, command)
                self.assertEqual(printed.getvalue().count('check: slack request 200.000100'), 1)
                self.assertEqual(watch.load_state()['outbox'], [])

    def test_the_binding_check_a_request_makes_gets_fixed_arguments_and_nothing_from_the_message(self):
        needle = 'ZEBRA-9172-secret-words'
        calls = []

        def record(argv, **kwargs):
            calls.append((argv, kwargs))
            return plane.subprocess.CompletedProcess(argv, 0, stdout='slack-dm\n', stderr='')

        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', needle)
            printed = io.StringIO()
            with patch.object(watch, 'bound', Watch.bound.__get__(watch)), \
                 patch.object(plane.subprocess, 'run', side_effect=record), contextlib.redirect_stdout(printed):
                watch.take_requests(20)
                plane.emit(watch, 'poll')
            self.assertEqual(self.acks(replay), ['200.000100'])
            self.assertIn(needle, printed.getvalue())
        # One check when the request is delivered and one when its wake line is printed, nothing else.
        self.assertEqual(len(calls), 2)
        for argv, kwargs in calls:
            self.assertEqual(argv, ['bash', str(plane.ROOT / 'fm-captain-hold.sh'), 'binding', plane.SOURCE])
            self.assertIsNone(kwargs.get('input'))
            self.assertFalse([key for key in kwargs['env'] if key.startswith('SLACK_')])
            self.assertFalse([value for value in kwargs['env'].values() if needle in value])
            self.assertNotIn(needle, repr((argv, kwargs.get('input'))))

    def test_retarget_drops_the_old_dms_walk_bounds_with_its_cursor(self):
        with self.fixture() as (watch, replay):
            watch.state['intake_bounds'] = ['200.000100']
            watch.commit()
            with patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0OTHEROWNER1'}):
                self.assertTrue(watch.retarget())
            saved = watch.load_state()
            self.assertEqual(('intake_cursor' in saved, 'intake_bounds' in saved), (False, False))

    # The binding check and the delivery it allows are one step against an unbind (the real unbind, the real check).
    CAPTAIN = str(plane.ROOT / 'fm-captain-hold.sh')

    def captain(self, *args):
        return subprocess.run(['bash', self.CAPTAIN, *args], check=True, capture_output=True, text=True)

    @contextmanager
    def raced(self, watch, replay, number, hold=True):
        """The real binding check; right after its number-th answer the real unbind starts in the background and is
        given time to reach its wait. Records whether the binding record still stood at each post and each print."""
        record = watch.root.parent / 'decision-bindings' / 'slack-dm.origin'
        real, call = Watch.bound.__get__(watch), replay.call
        seen = {'checks': 0, 'unbind': None, 'at': [], 'record': record}

        def bound():
            answer = real()
            seen['checks'] += 1
            if seen['checks'] == number:
                seen['unbind'] = subprocess.Popen(['bash', self.CAPTAIN, 'unbind', 'slack-dm'],
                                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                time.sleep(1.0)
                if not hold:
                    # Nothing holds the unbind back in the control, so it has completed before the check answers.
                    seen['unbind'].wait(timeout=60)
            return answer

        def watched(method, **fields):
            if method == 'chat.postMessage':
                seen['at'].append(('post', record.exists()))
            return call(method, **fields)

        @contextmanager
        def no_hold():
            yield

        patches = [patch.object(watch, 'bound', bound), patch.object(replay, 'call', watched)]
        if not hold:
            patches.append(patch.object(watch, 'binding_held', no_hold))
        with contextlib.ExitStack() as stack:
            for item in patches:
                stack.enter_context(item)
            try:
                yield seen
            finally:
                if seen['unbind']:
                    seen['unbind'].communicate(timeout=60)

    def printing(self, seen):
        class Recorder(io.StringIO):
            def write(inner, text):
                if text.strip():
                    seen['at'].append(('print', seen['record'].exists()))
                return super().write(text)
        return Recorder()

    def test_an_unbind_cannot_complete_between_the_publication_check_and_the_acknowledgement(self):
        for command in ('poll', 'check'):
            with self.subTest(command=command), self.fixture() as (watch, replay):
                self.captain('bind', 'slack-dm')
                self.say(replay, '200.000100', 'recover this request')
                with self.raced(watch, replay, 1) as seen:
                    watch.take_requests(20)
                # The acknowledgement was posted while the binding record still stood: the unbind was waiting for it.
                self.assertEqual(seen['at'], [('post', True)])
                self.assertEqual(seen['unbind'].returncode, 0)
                self.assertFalse(seen['record'].exists())
                self.assertEqual(self.acks(replay), ['200.000100'])
                # Unbound now: the wake is held in the journal, neither printed nor removed.
                printed = io.StringIO()
                with patch.object(watch, 'bound', Watch.bound.__get__(watch)), contextlib.redirect_stdout(printed):
                    plane.emit(watch, command)
                self.assertEqual(printed.getvalue(), '')
                self.assertEqual(len(watch.load_state()['outbox']), 1)
                self.captain('bind', 'slack-dm')
                with patch.object(watch, 'bound', Watch.bound.__get__(watch)), contextlib.redirect_stdout(printed):
                    plane.emit(watch, command)
                self.assertEqual(printed.getvalue().count('check: slack request 200.000100'), 1)
                self.assertEqual((self.acks(replay), watch.load_state()['outbox']), (['200.000100'], []))

    def test_an_unbind_cannot_complete_between_the_emission_check_and_the_wake_print(self):
        for command in ('poll', 'check'):
            with self.subTest(command=command), self.fixture() as (watch, replay):
                self.captain('bind', 'slack-dm')
                self.say(replay, '200.000100', 'print this request once')
                with patch.object(watch, 'bound', Watch.bound.__get__(watch)):
                    watch.take_requests(20)
                self.assertEqual(self.acks(replay), ['200.000100'])
                with self.raced(watch, replay, 1) as seen:
                    printed = self.printing(seen)
                    with contextlib.redirect_stdout(printed):
                        plane.emit(watch, command)
                # The wake was printed and removed while the binding record still stood; the unbind then completed.
                self.assertEqual(seen['at'], [('print', True)])
                self.assertEqual(seen['unbind'].returncode, 0)
                self.assertFalse(seen['record'].exists())
                self.assertEqual(printed.getvalue().count('check: slack request 200.000100'), 1)
                self.assertEqual(watch.load_state()['outbox'], [])
                # Nothing more is acknowledged or woken once the unbind has returned.
                again = io.StringIO()
                with patch.object(watch, 'bound', Watch.bound.__get__(watch)), contextlib.redirect_stdout(again):
                    watch.poll()
                    plane.emit(watch, command)
                self.assertEqual((again.getvalue(), self.acks(replay)), ('', ['200.000100']))

    def test_a_request_is_delivered_once_while_the_source_stays_bound(self):
        for command in ('poll', 'check'):
            with self.subTest(command=command), self.fixture() as (watch, replay):
                self.captain('bind', 'slack-dm')
                self.say(replay, '200.000100', 'a bound control')
                with self.raced(watch, replay, 99) as seen:
                    printed = self.printing(seen)
                    with contextlib.redirect_stdout(printed):
                        watch.take_requests(20)
                        plane.emit(watch, command)
                self.assertEqual(seen['at'], [('post', True), ('print', True)])
                self.assertEqual((self.acks(replay), printed.getvalue().count('check: slack request 200.000100'),
                                  watch.load_state()['outbox']), (['200.000100'], 1, []))

    def test_mutation_control_without_the_hold_an_unbind_completes_before_the_acknowledgement(self):
        with self.fixture() as (watch, replay):
            self.captain('bind', 'slack-dm')
            self.say(replay, '200.000100', 'recover this request')
            with self.raced(watch, replay, 1, hold=False) as seen:
                watch.take_requests(20)
            # The race this harness exists to catch: the post happens after the unbind removed the record.
            self.assertEqual(seen['at'], [('post', False)])

    def test_a_stored_channel_that_is_not_the_owner_dm_is_never_read_for_requests(self):
        for first_poll in (False, True):
            with self.subTest(first_poll=first_poll), self.fixture() as (watch, replay):
                if first_poll:
                    watch.state.pop('intake_cursor')
                self.say(replay, '200.000100', 'a request in a channel that is not the owner DM')
                # Slack now opens a different DM for the owner than the stored one.
                replay.transcript['owner_dm'] = 'D0SOMEONEELSE'
                watch.dm_proven = False
                before = self.histories(replay)
                with self.assertRaisesRegex(SlackError, '^stored_channel_not_owner_dm$'):
                    watch.poll()
                self.assertEqual(self.histories(replay) - before, 0)
                saved = watch.load_state()
                self.assertEqual((saved['pending'], saved['seen'], saved['outbox']), ([], {}, []))
                self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))
                # The control: the proven owner DM is read and the request is taken in.
                replay.transcript.pop('owner_dm')
                watch.state, watch.advanced = watch.load_state(), 0
                if first_poll:
                    # The proven owner DM gives the starting point, then a later request is taken in.
                    watch.state.pop('intake_cursor')
                    watch.poll()
                    self.assertEqual(self.acks(replay), [])
                    self.say(replay, '200.000200', 'a request after the starting point')
                    watch.advanced = 0
                watch.poll()
                self.assertEqual(self.acks(replay), ['200.000200' if first_poll else '200.000100'])

    def test_a_later_request_never_publishes_before_an_older_one_that_failed(self):
        for failures in (0, 2):
            with self.subTest(failures=failures), self.fixture() as (watch, replay):
                self.say(replay, '200.000100', 'the older request')
                self.say(replay, '200.000200', 'the newer request')
                if failures:
                    replay.state['failures']['conversations.replies:200.000100'] = {'status': 400, 'times': failures}
                    replay.save()
                per_poll = []
                for turn in range(failures + 1):
                    watch.state, watch.advanced = watch.load_state(), 0
                    before = len(self.acks(replay))
                    try:
                        watch.poll()
                    except SlackError as error:
                        self.assertEqual(str(error), 'api_error')
                    per_poll.append(self.acks(replay)[before:])
                # With failures the older request is retried alone until it is delivered, then the newer follows.
                self.assertEqual(per_poll, [[]] * failures + [['200.000100', '200.000200']])
                self.assertEqual([line.split()[3] for line in self.wakes(watch)], ['200.000100', '200.000200'])

    def polls(self, watch, replay, count):
        """Run count polls, each as a run of its own; returns the acknowledgements and errors of each."""
        acks, errors = [], []
        for _ in range(count):
            watch.state, watch.advanced = watch.load_state(), 0
            before = len(self.acks(replay))
            try:
                watch.poll()
                errors.append(None)
            except SlackError as error:
                errors.append(str(error))
            acks.append(self.acks(replay)[before:])
        return acks, errors

    def release(self, watch, replay):
        """A head request whose acknowledgement always fails, with a newer one behind it, run to its release."""
        self.say(replay, '200.000100', 'a request the owner deleted')
        self.say(replay, '200.000200', 'the newer request')
        replay.state['failures']['conversations.replies:200.000100'] = {'status': 400}
        replay.save()
        return self.polls(watch, replay, 3)

    def test_a_head_request_that_can_never_be_acknowledged_is_woken_once_after_three_polls_and_stays_open(self):
        with self.fixture() as (watch, replay):
            acks, errors = self.release(watch, replay)
            self.assertEqual(errors, ['api_error', 'api_error', None])
            # Released at the third failed poll, never acknowledged; the newer request follows in that same poll.
            self.assertEqual(acks, [[], [], ['200.000200']])
            self.assertEqual(self.wakes(watch), [
                'check: slack request 200.000100 from U0TESTOWNER (not acknowledged after 3 tries): '
                + plane.REQUEST_LABEL + ' a request the owner deleted',
                plane.request_line('200.000200', self.OWNER, 'the newer request')])
            saved = watch.load_state()
            [row] = saved['pending']
            self.assertEqual((row['thread'], row['state'], row['owner'], row['tries'], row['text'], row['author']),
                             ('200.000100', 'failed', 'Main', 3, 'a request the owner deleted', self.OWNER))
            self.assertNotIn(row['event'], saved['seen'])
            self.assertEqual(watch.failed_requests(), ['200.000100'])
            # Later requests still go on in order; the open row is never retried, acknowledged or woken again.
            self.say(replay, '200.000300', 'a later request')
            acks, errors = self.polls(watch, replay, 3)
            self.assertEqual((acks, errors), ([['200.000300'], [], []], [None, None, None]))
            self.assertEqual([line.split()[3] for line in self.wakes(watch)], ['200.000100', '200.000200', '200.000300'])
            self.assertEqual(self.acks(replay), ['200.000200', '200.000300'])
            self.assertEqual(watch.load_state()['pending'], [row])

    def test_resolve_closes_only_a_failed_request_and_makes_no_slack_call(self):
        with self.fixture() as (watch, replay):
            self.release(watch, replay)
            self.say(replay, '200.000300', 'a request whose acknowledgement fails once')
            replay.state['failures']['conversations.replies:200.000300'] = {'status': 400}
            replay.save()
            self.polls(watch, replay, 1)
            calls = len(replay.state['log'])
            before = watch.load_state()
            for ts, error in (('200.000999', 'no_pending_request'), ('200.000300', 'request_not_failed'),
                              ('200.000200', 'no_pending_request')):
                with self.subTest(ts=ts), self.assertRaisesRegex(SlackError, '^%s$' % error):
                    watch.close_request(ts)
                self.assertEqual(watch.load_state(), before)
            watch.close_request('200.000100')
            saved = watch.load_state()
            self.assertEqual([row['thread'] for row in saved['pending']], ['200.000300'])
            event = next(e for e in saved['seen'] if e.endswith('/200.000100/request'))
            self.assertEqual(saved['seen'][event], {'key': '', 'resolved': True})
            self.assertEqual(watch.failed_requests(), [])
            self.assertEqual(len(replay.state['log']), calls)

    def test_only_resolve_takes_a_request_ts_and_only_a_slack_timestamp(self):
        self.assertEqual(plane.parse_command(['check', '200.000100'], positional=True), ('check', None, '200.000100'))
        for argv in (['check'], ['check', 'x200'], ['check', '200.000100', '200.000200'], ['check', '200.000100;x']):
            with self.subTest(argv=argv), self.assertRaisesRegex(SlackError, '^resolve_needs_one_request_ts$'):
                plane.parse_command(argv, positional=True)
        with self.assertRaisesRegex(SlackError, '^unexpected_arguments$'):
            plane.parse_command(['check', '200.000100'])

    def test_retarget_refuses_while_a_failed_request_is_open(self):
        with self.fixture() as (watch, replay):
            self.release(watch, replay)
            before = watch.load_state()
            with patch.dict(os.environ, {'FM_SLACK_DM_USER': 'U0OTHEROWNER1'}), self.assertRaisesRegex(
                    SlackError, '^dm_user_changed_with_pending_work$'):
                watch.retarget()
            self.assertEqual(watch.load_state(), before)

    def test_a_released_request_line_keeps_its_label_and_its_bound(self):
        line = plane.request_line('200.000100', self.OWNER, 'x' * 1000, plane.REQUEST_UNACKNOWLEDGED)
        self.assertTrue(line.startswith('check: slack request 200.000100 from U0TESTOWNER (not acknowledged after 3 tries): '
                                        + plane.REQUEST_LABEL + ' x'))
        self.assertTrue(line.endswith(' [cut, full text in Slack thread 200.000100]'))
        self.assertLessEqual(len(line), plane.WAKE_LIMIT - plane.QUEUE_RESERVE)

    def test_a_request_that_recovers_within_three_tries_is_acknowledged_and_woken_plainly(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'the older request')
            self.say(replay, '200.000200', 'the newer request')
            replay.state['failures']['conversations.replies:200.000100'] = {'status': 400, 'times': 2}
            replay.save()
            acks, errors = self.polls(watch, replay, 4)
            self.assertEqual(errors, ['api_error', 'api_error', None, None])
            self.assertEqual(acks, [[], [], ['200.000100', '200.000200'], []])
            self.assertEqual(self.wakes(watch), [plane.request_line('200.000100', self.OWNER, 'the older request'),
                                                 plane.request_line('200.000200', self.OWNER, 'the newer request')])

    def test_an_outage_or_an_unbound_source_never_counts_toward_the_three_tries(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'the older request')
            replay.state['failures']['conversations.replies:200.000100'] = {'status': 400, 'times': 2}
            replay.save()
            self.assertEqual(self.polls(watch, replay, 2)[1], ['api_error', 'api_error'])
            replay.state['failures']['conversations.replies:200.000100'] = {'status': 503, 'times': 3}
            replay.save()
            self.assertEqual(self.polls(watch, replay, 3)[1], ['unreachable'] * 3)
            with patch.object(watch, 'bound', return_value=None):
                self.assertEqual(self.polls(watch, replay, 3), ([[], [], []], [None, None, None]))
            self.assertEqual(watch.load_state()['pending'][0]['tries'], 2)
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))
            self.assertEqual(self.polls(watch, replay, 1), ([['200.000100']], [None]))
            self.assertEqual(self.wakes(watch), [plane.request_line('200.000100', self.OWNER, 'the older request')])

    def test_the_history_counter_counts_a_failed_attempt(self):
        with self.fixture() as (watch, replay):
            replay.state['failures']['conversations.history'] = {'status': 503, 'times': 1}
            replay.save()
            before = self.histories(replay)
            logged = sum(1 for e in replay.state['log'] if e['method'] == 'conversations.history')
            with self.assertRaises(SlackError):
                watch.read_window('D0123456789', limit=1)
            watch.read_window('D0123456789', limit=1)
            self.assertEqual(self.histories(replay) - before, 2)
            # The outbound log alone saw only the one that succeeded: the gap the attempt log closes.
            self.assertEqual(sum(1 for e in replay.state['log'] if e['method'] == 'conversations.history') - logged, 1)

    def test_a_poll_whose_history_read_fails_makes_one_attempt_and_the_next_poll_recovers_with_one(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'a request behind a failed read')
            replay.state['failures']['conversations.history'] = {'status': 503, 'times': 1}
            replay.save()
            reads = []
            for turn in range(2):
                watch.state, watch.advanced = watch.load_state(), 0
                before = self.histories(replay)
                try:
                    watch.poll()
                except SlackError as error:
                    self.assertEqual((turn, str(error)), (0, 'unreachable'))
                reads.append(self.histories(replay) - before)
            self.assertEqual((reads, self.acks(replay)), ([1, 1], ['200.000100']))


    def test_a_removed_allowlist_member_loses_the_pending_request(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'hello')
            with patch.dict(os.environ, {'FM_SLACK_FAULT': 'after-stage'}), self.assertRaises(RuntimeError):
                watch.poll()
            watch.state, watch.authors = watch.load_state(), {'U0SOMEONEELSE'}
            watch.poll()
            self.assertEqual((self.acks(replay), self.wakes(watch), watch.state['pending']), ([], [], []))


class ClosedTransportTest(unittest.TestCase):
    """A test or verification run cannot reach Slack: it runs on a transcript, or its transport is closed."""

    ENV = {'FM_SLACK_DM_USER': 'U0TESTOWNER', 'FM_SLACK_ALLOWED_AUTHORS': 'U0TESTOWNER',
           'SLACK_BOT_TOKEN': 'fixture-token-not-a-secret'}

    def test_no_network_closes_the_real_transport_before_any_socket_exists(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
             patch.dict(os.environ, dict(self.ENV, FM_HOME=directory, FM_STATE_OVERRIDE=directory,
                                         FM_SLACK_NO_NETWORK='1')), \
             patch('fm_slack.urllib.request.urlopen', side_effect=AssertionError('a socket was opened')):
            watch = Watch(token='fixture-token-not-a-secret')
            try:
                with patch.object(watch, 'bound', return_value=True):
                    for call in (watch.prepare, lambda: watch.api.call('auth.test'),
                                 lambda: list(watch.api.pages('conversations.history', 'messages', channel='D0123456789'))):
                        with self.assertRaisesRegex(SlackError, '^network_closed$'):
                            call()
            finally:
                watch.lock.close()


def history_attempts(path):
    """Every conversations.history call that reached the replay, whether it succeeded or failed."""
    if not Path(path).is_file():
        return 0
    with open(path) as lines:
        return sum(1 for line in lines if json.loads(line)['method'] == 'conversations.history')


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
    elif command == 'owner-message':
        text = json.loads(argv[4][5:]) if argv[4].startswith('json:') else argv[4]
        extra = json.loads(argv[5]) if len(argv) > 5 else {}
        edit(argv[1], lambda data: data['messages'].append(
            {'ts': argv[2], 'user': argv[3], 'text': text, **extra}))
    elif command == 'edit-message':
        def reword(data):
            message = next(m for m in data['messages'] if m['ts'] == argv[2])
            message.update(text=argv[3], edited={'user': message['user'], 'ts': message['ts'] + '1'})
        edit(argv[1], reword)
    elif command == 'distinct-texts':
        rows = [json.loads(line) for line in open(argv[1])]
        print(len({row.get('text') for row in rows if row.get('method') == argv[2]}))
    elif command == 'outbox-count':
        print(len(json.load(open(argv[1])).get('outbox', [])))
    elif command == 'pad-foreign':
        edit(argv[1], lambda data: data['messages'].extend(
            {'ts': '%s.%06d' % (argv[3], n), 'user': 'U0STRANGER01', 'text': 'noise %d' % n}
            for n in range(1, int(argv[2]) + 1)))
    elif command == 'history-calls':
        # Attempts, failed ones included: the file beside the outbound log that records every call before it is judged.
        print(history_attempts(Path(argv[1]).with_name('attempts.jsonl')))
    elif command == 'drop-state-field':
        edit(argv[1], lambda data: data.pop(argv[2], None))
    elif command == 'state-field':
        print(json.load(open(argv[1])).get(argv[2], ''))
    elif command == 'set-transcript':
        data = json.load(open(argv[1]))
        data[argv[3]] = json.loads(argv[4])
        json.dump(data, open(argv[2], 'w'))
    elif command == 'request-lines':
        lines = sys.stdin.read().splitlines()
        shape = re.compile(r'check: slack request [0-9]+\.[0-9]+ from U[A-Z0-9]+: ' + re.escape(plane.REQUEST_LABEL) + ' ')
        for line in lines:
            assert shape.match(line), 'not a request line: ' + line
            assert len(line) <= plane.WAKE_LIMIT - plane.QUEUE_RESERVE, 'line too long: %d' % len(line)
            assert all(c == ' ' or unicodedata.category(c)[0] not in 'CZ' for c in line), 'control or separator in a line'
        assert len(lines) >= int(argv[1]), 'expected at least %s request lines, got %d' % (argv[1], len(lines))
        print(len(lines))
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
