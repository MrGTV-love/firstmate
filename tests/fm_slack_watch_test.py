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
  fm_slack_watch_test.py request-lines <min-count>   (reads wake lines on stdin; checks the grammar)
  fm_slack_watch_test.py request-texts   (reads wake lines on stdin; prints each decoded text)
"""
from contextlib import contextmanager
import contextlib
import fcntl
import glob
import io
import json
import os
import random
import re
import shutil
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

REPO = Path(__file__).resolve().parents[1]


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

    def test_every_card_post_happens_while_the_source_binding_is_held(self):
        # An unbind takes the binding folder exclusive: while a card post is under way it must be blocked.
        with self.fixture() as (watch, replay, rows):
            directory = watch.root.parent / 'decision-bindings'
            directory.mkdir()
            blocked, real = [], replay.call

            def spy(method, **fields):
                if method in ('chat.postMessage', 'chat.update'):
                    fd = os.open(directory, os.O_RDONLY)
                    try:
                        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        blocked.append(False)
                    except BlockingIOError:
                        blocked.append(True)
                    finally:
                        os.close(fd)
                return real(method, **fields)
            with patch.object(replay, 'call', spy):
                watch.mirror()
            self.assertEqual(blocked, [True, True])

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

    POPULATION = ('auth.test', 'chat.postMessage', 'chat.update', 'conversations.open', 'conversations.history',
                  'conversations.replies', 'reactions.get', 'reactions.add', 'users.info')

    def test_a_post_attempt_records_its_thread_before_it_is_judged(self):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            replay = self.replay(directory, {'failures': {'chat.postMessage': {'status': 400}}})
            with self.assertRaises(SlackError):
                replay.call('chat.postMessage', channel='D0123456789', text='x', thread_ts='10.000001')
            attempts = [json.loads(line) for line in (Path(directory) / 'slack-watch' / 'attempts.jsonl').read_text().splitlines()]
            self.assertEqual((attempts[-1]['method'], attempts[-1]['thread_ts']), ('chat.postMessage', '10.000001'))

    def test_the_method_allowlist_and_the_scope_rule_fail_separately(self):
        scopes = ['chat:write', 'im:write', 'im:history', 'reactions:read', 'reactions:write', 'users:read']
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            replay = self.replay(directory, {'enforce_scopes': True, 'scopes': scopes[1:], 'method_allowlist': list(self.POPULATION)})
            with self.assertRaisesRegex(SlackError, '^method_not_allowed$'):
                replay.call('files.list', channel='D0123456789')
            with self.assertRaisesRegex(SlackError, '^missing_scope$'):
                replay.call('chat.postMessage', channel='D0123456789', text='x')
            self.assertEqual(replay.call('users.info', user='U0TESTOWNER')['user']['id'], 'U0TESTOWNER')
            methods = [json.loads(line)['method'] for line in (Path(directory) / 'slack-watch' / 'attempts.jsonl').read_text().splitlines()]
            self.assertEqual(methods, ['files.list', 'chat.postMessage', 'users.info'])

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


# The scopes that the base card path's own methods need (the replay's METHOD_SCOPES): the default of every intake scenario.
BASE_SCOPES = ('chat:write', 'im:write', 'im:history', 'reactions:read', 'reactions:write', 'users:read')


class IntakeTest(unittest.TestCase):
    """New top-level owner messages: what is taken in, in what order, and what carries no authority."""

    OWNER = 'U0TESTOWNER'
    OTHER = 'U0OTHERALLOWED'
    # Synthetic values: the plane's own secrets in these tests are never real credentials.
    TOKEN = 'fixture-token-not-a-secret'
    SIGNING = 'fixture-signing-not-a-secret'

    @contextmanager
    def fixture(self, cap='20', scopes=BASE_SCOPES, authors=None, env=None, transcript_extra=None):
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
            home = Path(directory)
            transcript = home / 'transcript.json'
            transcript.write_text(json.dumps({
                'schema': 'fm-slack-replay.v1', 'team': 'T0123456789', 'channel': 'D0123456789',
                'scopes': list(scopes), 'enforce_scopes': True, 'method_allowlist': list(ReplayShapeTest.POPULATION),
                'messages': [{'ts': '100.000100', 'user': self.OWNER, 'text': 'already there'}],
                **(transcript_extra or {})}))
            env = {'FM_HOME': directory, 'FM_STATE_OVERRIDE': directory, 'FM_SLACK_DM_USER': self.OWNER,
                   'FM_SLACK_ALLOWED_AUTHORS': authors or self.OWNER, 'FM_SLACK_POLL_MAX_ANSWERS': cap,
                   'SLACK_BOT_TOKEN': self.TOKEN, 'SLACK_SIGNING_SECRET': self.SIGNING, **(env or {})}
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
        return [e['thread_ts'] for e in replay.state['log'] if e['method'] == 'chat.postMessage' and 'error' not in e]

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
            self.say(replay, '200.000400', '')
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
            self.say(replay, '200.000700', '')
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

    # ---- I5b-scope: three separate controls, each with its own compliant case (the replay holds the base card
    # path's scopes and its method allowlist) ----

    def prerequisite(self, method, fields, swallow=False):
        """An intake variant that makes one more call before it decides on a message."""
        original = Watch.request_from

        def with_call(watch, message, owner=None):
            try:
                watch.api.call(method, **fields(message))
            except SlackError:
                if not swallow:
                    raise
            return original(watch, message, owner)
        return with_call

    def poll_with(self, variant, **fixture):
        with self.fixture(**fixture) as (watch, replay):
            self.say(replay, '200.000100', 'please check the status of vernant d7')
            error = None
            with patch.object(Watch, 'request_from', variant):
                try:
                    watch.poll()
                except SlackError as caught:
                    error = str(caught)
            attempts = [json.loads(line)['method'] for line in (watch.root / 'attempts.jsonl').read_text().splitlines()]
            return self.acks(replay), error, attempts

    def test_a_method_that_the_base_card_path_already_calls_needs_no_new_scope(self):
        lookup = self.prerequisite('users.info', lambda message: {'user': message['user']})
        acks, error, attempts = self.poll_with(lookup)
        self.assertEqual((acks, error), (['200.000100'], None))
        self.assertIn('users.info', attempts)
        self.assertTrue(set(attempts) <= set(ReplayShapeTest.POPULATION), attempts)

    def test_control_a_scope_of_the_population_that_is_missing_stops_the_acknowledgement(self):
        without_chat_write = tuple(scope for scope in BASE_SCOPES if scope != 'chat:write')
        acks, error, _ = self.poll_with(Watch.request_from, scopes=without_chat_write)
        self.assertEqual((acks, error), ([], 'missing_scope'))
        acks, error, _ = self.poll_with(Watch.request_from)
        self.assertEqual((acks, error), (['200.000100'], None))

    def test_control_a_method_outside_the_population_is_stopped_by_the_allowlist_and_not_by_a_scope(self):
        files = self.prerequisite('files.list', lambda message: {})
        extra = {'method_allowlist': list(ReplayShapeTest.POPULATION)}
        acks, error, attempts = self.poll_with(files, transcript_extra=extra)
        self.assertEqual((acks, error), ([], 'method_not_allowed'))
        self.assertIn('files.list', attempts)
        acks, error, attempts = self.poll_with(Watch.request_from, transcript_extra=extra)
        self.assertEqual((acks, error), (['200.000100'], None))
        self.assertTrue(set(attempts) <= set(ReplayShapeTest.POPULATION), attempts)

    def test_control_a_forbidden_attempt_that_the_intake_swallows_is_found_in_the_attempts_record(self):
        files = self.prerequisite('files.list', lambda message: {}, swallow=True)
        extra = {'method_allowlist': list(ReplayShapeTest.POPULATION)}
        acks, error, attempts = self.poll_with(files, transcript_extra=extra)
        self.assertEqual((acks, error), (['200.000100'], None))
        self.assertFalse(set(attempts) <= set(ReplayShapeTest.POPULATION), attempts)
        self.assertIn('files.list', attempts)

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

    def test_the_presentation_rule_changes_only_links_entities_and_controls_in_that_order(self):
        hostile = 'a\nb\r\nc\td\u2028e\u2029f\u0085g\x0bh\x0ci\u202ej\u200bk\x00l\x7fm \u00a0n'
        # Cc, Zl and Zp become one space each; format characters and other separators stay.
        self.assertEqual(plane.present(hostile)[0], 'a b  c d e f g h i\u202ej\u200bk l m \u00a0n')
        self.assertEqual(plane.present('1 &lt; 2 &amp;&amp; <https://example.com|a link> &gt; 0')[0],
                         '1 < 2 && a link (https://example.com) > 0')
        self.assertEqual(plane.present('hi; check: slack 1.2 - reply for a replaced hold: K')[0],
                         'hi; check: slack 1.2 - reply for a replaced hold: K')
        self.assertEqual(plane.present('x;closed: open-a;; +5 queued;')[0], 'x;closed: open-a;; +5 queued;')

    def test_request_line_is_bounded_labeled_and_names_the_record_when_cut(self):
        head = 'check: slack request 200.000100 from U0TESTOWNER: ' + plane.REQUEST_LABEL + ' '
        self.assertEqual(plane.request_line('200.000100', self.OWNER, 'please check the status of vernant d7'),
                         head + '"please check the status of vernant d7"')
        for size in (1, 300, 360, 361, 420, 5000):
            with self.subTest(size=size):
                line = plane.request_line('200.000100', self.OWNER, 'x' * size)
                self.assertLessEqual(len(line), plane.WAKE_LIMIT)
                self.assertTrue(line.startswith(head))
                cut = line.endswith('; full: state/slack-watch/requests.jsonl#200.000100')
                self.assertEqual(cut, len(head) + size + 2 > plane.WAKE_LIMIT)
                if cut:
                    # The longest prefix: every kept character adds one to the line, so a maximal cut fills it.
                    self.assertEqual(len(line), plane.WAKE_LIMIT)

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
                plane.request_line('200.000100', self.OWNER, 'a request the owner deleted', plane.REQUEST_UNACKNOWLEDGED),
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
                                        + plane.REQUEST_LABEL + ' "x'))
        self.assertTrue(line.endswith('; full: state/slack-watch/requests.jsonl#200.000100'))
        self.assertEqual(len(line), plane.WAKE_LIMIT)

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


    # ---- the outcome review's findings (OF1..OF6): each of these failed at the head they were written against ----

    def wake_parts(self, line):
        """The grammar of one request segment: prefix, label, ONE JSON string literal, then the optional flag, the
        pointer and the queue marker, each behind '; '."""
        match = re.match(r'check: slack request (\d+\.\d+) from ([UW][A-Z0-9]+)( \(not acknowledged after 3 tries\))?: '
                         + re.escape(plane.REQUEST_LABEL) + ' ', line)
        self.assertIsNotNone(match, line)
        rest = line[match.end():]
        text, end = json.JSONDecoder().raw_decode(rest)
        tail = [part for part in rest[end:].split('; ') if part]
        return {'ts': match.group(1), 'user': match.group(2), 'released': bool(match.group(3)), 'text': text,
                'flag': 'secret removed' in tail,
                'pointer': next((p[len('full: '):] for p in tail if p.startswith('full: ')), None),
                'queued': next((p for p in tail if p.startswith('+')), None)}

    def record(self, watch, ts):
        """The whole-text record of one request, found as the pointer says: the store's path, then the request's key."""
        path = watch.root / 'requests.jsonl'
        rows = []
        for line in (path.read_text().split('\n') if path.is_file() else []):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict):
                rows.append(row)
        found = [row for row in rows if row.get('ts') == ts]
        return found[-1] if found else None

    def test_an_allowlisted_non_owner_is_not_taken_in_as_an_owner_request(self):
        with self.fixture(authors='%s,%s' % (self.OWNER, self.OTHER)) as (watch, replay):
            self.say(replay, '200.000100', 'from a second allowlisted member', user=self.OTHER)
            self.say(replay, '200.000200', 'the owner control')
            for _ in range(2):
                watch.advanced = 0
                watch.poll()
                watch.state = watch.load_state()
            self.assertEqual(self.acks(replay), ['200.000200'])
            self.assertEqual([line.split()[3] for line in self.wakes(watch)], ['200.000200'])
            saved = watch.load_state()
            self.assertEqual(saved['pending'], [])
            self.assertEqual([event for event in saved['seen'] if '200.000100' in event], [])

    def test_the_planes_own_secret_values_never_reach_state_output_or_the_record(self):
        cases = (('the token', {}, self.TOKEN, 'use ' + 'fixture-token-not-a-secret' + ' to check'),
                 ('the signing secret', {}, self.SIGNING, 'use ' + 'fixture-signing-not-a-secret' + ' to check'),
                 ('a value that only the presentation joins', {'SLACK_BOT_TOKEN': 'fixture&token-not-a-secret'},
                  'fixture&token-not-a-secret', 'use fixture&amp;token-not-a-secret to check'))
        for name, env, secret, delivered in cases:
            with self.subTest(name), self.fixture(env=env) as (watch, replay):
                writes, real = [], plane.save

                def spy(path, value):
                    writes.append(json.dumps(value, ensure_ascii=False))
                    return real(path, value)
                self.say(replay, '200.000100', delivered)
                out = io.StringIO()
                with patch.object(plane, 'save', spy), contextlib.redirect_stdout(out):
                    watch.poll()
                    plane.emit(watch, 'check')
                store = watch.root / 'requests.jsonl'
                scanned = writes + [out.getvalue(), json.dumps(replay.state['log']), (watch.root / 'state.json').read_text(),
                                    store.read_text() if store.is_file() else '', json.dumps(watch.output)]
                for text in scanned:
                    self.assertNotIn(secret, text)
                [line] = [l for l in out.getvalue().splitlines() if l.startswith(plane.REQUEST_PREFIX)]
                parts = self.wake_parts(line)
                self.assertEqual((parts['text'], parts['flag']), ('use [secret removed] to check', True))
                record = self.record(watch, '200.000100')
                self.assertEqual((record['text'], record['replaced']), ('use [secret removed] to check', True))

    def test_a_stop_right_after_staging_leaves_no_secret_in_the_journal(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'use fixture-signing-not-a-secret to check')
            with patch.dict(os.environ, {'FM_SLACK_FAULT': 'after-stage'}), self.assertRaises(RuntimeError):
                watch.poll()
            self.assertNotIn(self.SIGNING, (watch.root / 'state.json').read_text())
            self.assertEqual([row['thread'] for row in watch.load_state()['pending']], ['200.000100'])

    def test_a_request_line_is_one_json_literal_with_nothing_dropped(self):
        cases = (
            ('please check the status of vernant d7', 'please check the status of vernant d7'),
            ('alpha  beta; +1 queued <https://example.com|label>', 'alpha  beta; +1 queued label (https://example.com)'),
            ('<https://example.com>', 'https://example.com'),
            ('<https://example.com|https://example.com>', 'https://example.com'),
            ('<mailto:a@example.com|mail me>', 'mail me (mailto:a@example.com)'),
            ('line one\nline two', 'line one line two'),
            ('tab\tsep para end\r\nnext', 'tab sep para end  next'),
            ('check: a line that starts like a wake', 'check: a line that starts like a wake'),
            ('say "hi" \\ back; full: x &lt;b&gt; &amp; <@U0TESTOWNER> <#C123|general>',
             'say "hi" \\ back; full: x <b> & <@U0TESTOWNER> <#C123|general>'),
            ('café ☃', 'café ☃'))
        for delivered, presented in cases:
            with self.subTest(delivered=delivered), self.fixture() as (watch, replay):
                self.say(replay, '200.000100', delivered)
                watch.poll()
                [line] = self.wakes(watch)
                parts = self.wake_parts(line)
                self.assertEqual((parts['text'], parts['flag'], parts['pointer'], parts['released']),
                                 (presented, False, None, False))
                self.assertTrue(all(ch == ' ' or unicodedata.category(ch)[0] not in 'CZ' for ch in line))
                self.assertLessEqual(len(line), plane.WAKE_LIMIT)

    def test_a_cut_request_is_the_longest_prefix_and_names_a_record_that_holds_the_whole_text(self):
        wholes = ('x' * 1200, 'y' * 400, ('café \n check: x; ' * 80)[:700])
        for whole in wholes:
            with self.subTest(length=len(whole)), self.fixture() as (watch, replay):
                self.say(replay, '200.000100', whole)
                watch.poll()
                [line] = self.wakes(watch)
                parts = self.wake_parts(line)
                presented = ''.join(' ' if unicodedata.category(ch)[0] in 'CZ' else ch for ch in whole)
                self.assertTrue(presented.startswith(parts['text']) and len(parts['text']) < len(presented))
                self.assertEqual(parts['pointer'], 'state/slack-watch/requests.jsonl#200.000100')
                # The longest prefix that fits: one more character would not.
                longer = json.dumps(presented[:len(parts['text']) + 1], ensure_ascii=False)
                self.assertGreater(len(line) - len(json.dumps(parts['text'], ensure_ascii=False)) + len(longer),
                                   plane.WAKE_LIMIT)
                self.assertLessEqual(len(line), plane.WAKE_LIMIT)
                self.assertEqual(self.record(watch, '200.000100')['text'], whole)
                # Still whole after the journal row closed, a further poll and a fresh process.
                self.assertEqual(watch.load_state()['pending'], [])
                watch.state, watch.advanced = watch.load_state(), 0
                watch.poll()
                self.assertEqual(self.record(watch, '200.000100')['text'], whole)

    def test_a_failed_request_keeps_its_whole_permitted_text_and_its_record_survives_resolve(self):
        text = 'hello; line\nsecond ' + 'z' * 600
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', text)
            replay.state['failures']['conversations.replies:200.000100'] = {'status': 400}
            replay.save()
            self.polls(watch, replay, 3)
            [row] = watch.load_state()['pending']
            self.assertEqual((row['state'], row['text']), ('failed', text))
            [line] = self.wakes(watch)
            parts = self.wake_parts(line)
            self.assertTrue(parts['released'])
            self.assertEqual(parts['pointer'], 'state/slack-watch/requests.jsonl#200.000100')
            self.assertEqual(self.record(watch, '200.000100')['text'], text)
            watch.close_request('200.000100')
            self.assertEqual(self.record(watch, '200.000100')['text'], text)

    def test_a_request_whose_record_cannot_be_written_prints_no_line_and_stays_journaled(self):
        with self.fixture() as (watch, replay):
            (watch.root / 'requests.jsonl').mkdir()
            self.say(replay, '200.000100', 'y' * 600)
            with self.assertRaises(SlackError):
                watch.poll()
            self.assertEqual(self.wakes(watch), [])
            self.assertEqual([row['thread'] for row in watch.load_state()['pending']], ['200.000100'])
            (watch.root / 'requests.jsonl').rmdir()
            watch.state, watch.advanced = watch.load_state(), 0
            watch.poll()
            [line] = self.wakes(watch)
            self.assertEqual(self.wake_parts(line)['pointer'], 'state/slack-watch/requests.jsonl#200.000100')
            self.assertEqual(self.record(watch, '200.000100')['text'], 'y' * 600)
            self.assertEqual(self.acks(replay), ['200.000100'])

    def test_a_joined_check_line_cuts_a_request_before_encoding_so_the_queue_marker_fits(self):
        with self.fixture(cap='2') as (watch, replay):
            self.say(replay, '200.000100', 'a' * 700)
            self.say(replay, '200.000200', 'b' * 700)
            watch.poll()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                plane.emit(watch, 'check')
            [line] = out.getvalue().splitlines()
            self.assertEqual(len(line), plane.WAKE_LIMIT)
            self.assertTrue(line.endswith('; +1 queued'))
            parts = self.wake_parts(line[:-len('; +1 queued')])
            self.assertEqual((parts['ts'], parts['pointer']), ('200.000100', 'state/slack-watch/requests.jsonl#200.000100'))
            self.assertTrue(set(parts['text']) == {'a'} and 0 < len(parts['text']) < 700)
            self.assertEqual([row['ts'] for row in map(json.loads, (watch.root / 'requests.jsonl').read_text().split('\n')[:-1])],
                             ['200.000100', '200.000200'])

    def test_the_intake_needs_no_scope_or_method_outside_the_base_card_population(self):
        scopes = ('chat:write', 'im:write', 'im:history', 'reactions:read', 'reactions:write', 'users:read')
        with self.fixture(scopes=scopes, transcript_extra={'method_allowlist': list(ReplayShapeTest.POPULATION)}) as (watch, replay):
            self.say(replay, '200.000100', 'a request under the base card path population')
            watch.poll()
            self.assertEqual((self.acks(replay), len(self.wakes(watch))), (['200.000100'], 1))
            attempts = [json.loads(line)['method'] for line in (watch.root / 'attempts.jsonl').read_text().splitlines()]
            self.assertTrue(set(attempts) <= set(ReplayShapeTest.POPULATION), attempts)

    def notice(self, event, thread):
        return {'event': event, 'key': 'k-' + event, 'thread': thread, 'text': 'A notice', 'kind': 'notice',
                'line': 'check: slack %s - a notice' % thread, 'stage': 'notice', 'contributing': []}

    def test_a_resumed_notice_and_a_new_request_share_the_cap(self):
        with self.fixture(cap='1') as (watch, replay):
            watch.state['pending'].append(self.notice('test/notice/1', '100.000100'))
            watch.commit()
            self.say(replay, '200.000100', 'a new request')
            watch.poll()
            self.assertEqual(len(self.acks(replay)), 1)
            watch.state, watch.advanced = watch.load_state(), 0
            watch.poll()
            self.assertEqual(self.acks(replay), ['100.000100', '200.000100'])

    def test_notices_themselves_are_not_throttled_by_the_cap_as_on_base(self):
        with self.fixture(cap='1') as (watch, replay):
            watch.state['pending'].append(self.notice('test/notice/1', '100.000100'))
            watch.state['pending'].append(self.notice('test/notice/2', '100.000200'))
            watch.commit()
            watch.poll()
            self.assertEqual(self.acks(replay), ['100.000100', '100.000200'])


    # ---- the outcome re-review's findings of a472bf5e (r46): each of these failed at the head they were written against ----

    def watch_durable_text(self, watch, replay, writes, out):
        """Everything a request leaves behind that a plane value must not be in."""
        store = watch.root / 'requests.jsonl'
        return writes + [out, (watch.root / 'state.json').read_text(), store.read_text() if store.is_file() else '',
                         json.dumps(replay.state['log']), json.dumps(watch.output)]

    @contextmanager
    def observe_every_write(self, watch, writes):
        """Every byte written through open() to a file under the fixture home, whatever the plane function that writes
        it (the state save, the record append, the shim): the observer of every durable write, not of one function."""
        import builtins
        real_open, home = builtins.open, str(watch.root.parent)

        class Spy:
            def __init__(self, handle):
                self.handle = handle

            def write(self, data):
                writes.append(data.decode('utf-8', 'replace') if isinstance(data, bytes) else data)
                return self.handle.write(data)

            def __getattr__(self, name):
                return getattr(self.handle, name)

            def __enter__(self):
                self.handle.__enter__()
                return self

            def __exit__(self, *exc):
                return self.handle.__exit__(*exc)

        def spy(file, mode='r', *args, **kwargs):
            handle = real_open(file, mode, *args, **kwargs)
            if isinstance(file, (str, os.PathLike)) and str(file).startswith(home) and any(c in mode for c in 'wax+'):
                return Spy(handle)
            return handle
        with patch('builtins.open', spy):
            yield

    def test_the_every_write_observer_catches_a_transient_record_write(self):
        value = 'fixture-signing-transient-0123456789'
        original = plane.Watch.write_record

        def transient(self, pending):
            with open(self.root / plane.RECORD_FILE, 'a') as out:
                out.write(value + '\n')
                out.flush()
                os.fsync(out.fileno())
            with open(self.root / plane.RECORD_FILE, 'w') as out:
                out.truncate(0)
            return original(self, pending)
        for mutant in (False, True):
            with self.fixture(env={'SLACK_SIGNING_SECRET': value}) as (watch, replay):
                writes = []
                self.say(replay, '200.000100', 'an ordinary request')
                with self.observe_every_write(watch, writes):
                    if mutant:
                        with patch.object(plane.Watch, 'write_record', transient):
                            watch.poll()
                    else:
                        watch.poll()
                self.assertEqual(value in '\n'.join(writes), mutant)
                self.assertEqual(self.acks(replay), ['200.000100'])

    def test_a_cascade_of_replacements_leaves_no_plane_value_in_any_durable_write(self):
        value = 'a' + plane.SECRET_MARKER + 'b'
        delivered = 'a' * 6 + plane.SECRET_MARKER + 'b' * 6
        with self.fixture(env={'SLACK_SIGNING_SECRET': value}) as (watch, replay):
            writes, real = [], plane.save

            def spy(path, written):
                writes.append(json.dumps(written, ensure_ascii=False))
                return real(path, written)
            self.say(replay, '200.000100', delivered)
            with patch.dict(os.environ, {'FM_SLACK_FAULT': 'after-stage'}), patch.object(plane, 'save', spy), \
                 self.observe_every_write(watch, writes), self.assertRaises(RuntimeError):
                watch.poll()
            self.assertNotIn(value, (watch.root / 'state.json').read_text())
            watch.state, watch.advanced = watch.load_state(), 0
            out = io.StringIO()
            with patch.object(plane, 'save', spy), self.observe_every_write(watch, writes), contextlib.redirect_stdout(out):
                watch.poll()
                plane.emit(watch, 'check')
            for text in self.watch_durable_text(watch, replay, writes, out.getvalue()):
                self.assertNotIn(value, text)
            [line] = [l for l in out.getvalue().splitlines() if l.startswith(plane.REQUEST_PREFIX)]
            parts = self.wake_parts(line)
            self.assertEqual((parts['text'], parts['flag']), (plane.SECRET_MARKER, True))
            record = self.record(watch, '200.000100')
            self.assertEqual((record['text'], record['replaced']), (plane.SECRET_MARKER, True))

    def test_a_value_split_across_a_link_keeps_the_text_around_it_in_the_line(self):
        value = 'fixturesigning1234'
        with self.fixture(env={'SLACK_SIGNING_SECRET': value}) as (watch, replay):
            self.say(replay, '200.000100', 'fixturesig<https://example.com|ning1234extra>')
            watch.poll()
            [line] = self.wakes(watch)
            parts = self.wake_parts(line)
            # The line: the presentation rule first, the replacement on its result (I4a).
            self.assertEqual((parts['text'], parts['flag']), (plane.SECRET_MARKER + 'extra (https://example.com)', True))
            # The record: the delivered characters that form the value, the link among them, are replaced (I4d).
            record = self.record(watch, '200.000100')
            self.assertEqual((record['text'], record['replaced']), (plane.SECRET_MARKER, True))
            for text in self.watch_durable_text(watch, replay, [], line):
                self.assertNotIn(value, text)

    def test_a_joined_line_that_is_cut_again_keeps_the_text_the_rule_computed(self):
        value = 'fixturesigning1234'
        straddle = 'fixturesig<https://example.com|ning1234extra>'
        with self.fixture(cap='2', env={'SLACK_SIGNING_SECRET': value}) as (watch, replay):
            self.say(replay, '200.000100', straddle + 'a' * 700)
            self.say(replay, '200.000200', straddle + 'b' * 700)
            watch.poll()
            first = io.StringIO()
            with contextlib.redirect_stdout(first):
                plane.emit(watch, 'check')
            [line] = first.getvalue().splitlines()
            self.assertTrue(line.endswith('; +1 queued'))
            head = self.wake_parts(line[:-len('; +1 queued')])
            self.assertTrue(head['text'].startswith(plane.SECRET_MARKER + 'extra (https://example.com)aaa'), head['text'][:80])
            second = io.StringIO()
            with contextlib.redirect_stdout(second):
                plane.emit(watch, 'check')
            tail = self.wake_parts(second.getvalue().splitlines()[0])
            self.assertTrue(tail['text'].startswith(plane.SECRET_MARKER + 'extra (https://example.com)bbb'), tail['text'][:80])

    def test_the_replacement_leaves_no_plane_value_and_leaves_value_free_text_alone(self):
        values = ['abc12', 'x' + plane.SECRET_MARKER + 'y']
        pieces = ['a', 'b', 'c', '1', '2', 'x', 'y', 'z', ' ', 'ab', 'abc', 'c12', '&amp;', '&lt;', '<https://e.com|', '>', '|',
                  plane.SECRET_MARKER, 'x' + plane.SECRET_MARKER, plane.SECRET_MARKER + 'y']
        rng = random.Random(46)
        # Deep cascades: removing a value brings the pieces of the next one together, k levels deep.
        cascades = ['x' * k + plane.SECRET_MARKER + 'y' * k for k in range(1, 9)] + ['abc' * k + '12' * k for k in range(1, 9)]
        with patch.dict(os.environ, {'SLACK_BOT_TOKEN': values[0], 'SLACK_SIGNING_SECRET': values[1]}):
            for raw in cascades + [''.join(rng.choice(pieces) for _ in range(rng.randint(0, 26))) for _ in range(500)]:
                started = time.monotonic()
                text, shown, replaced = plane.sanitize(raw)
                self.assertLess(time.monotonic() - started, 1.0, raw)
                for value in values:
                    for held in (text, shown, plane.present(text)[0]):
                        self.assertNotIn(value, held, raw)
                joined = any(value in raw or value in plane.present(raw)[0] for value in values)
                self.assertEqual(replaced, joined, raw)
                if not joined:
                    self.assertEqual((text, shown), (raw, plane.present(raw)[0]), raw)

    def test_a_plane_value_inside_the_marker_fails_closed_without_looping(self):
        with self.fixture(env={'SLACK_SIGNING_SECRET': 'removed]'}) as (watch, replay):
            self.say(replay, '200.000100', 'a request')
            started = time.monotonic()
            with self.assertRaisesRegex(SlackError, '^secret_collides_with_marker$'):
                watch.poll()
            self.assertLess(time.monotonic() - started, 2.0)
            self.assertEqual((self.acks(replay), self.wakes(watch), watch.load_state()['pending']), ([], [], []))

    def test_a_w_prefixed_owner_gets_the_same_queued_line_as_a_u_prefixed_owner(self):
        for owner in ('U0TESTOWNER', 'W0TESTOWNER'):
            with self.subTest(owner), self.fixture(cap='2', authors=owner, env={'FM_SLACK_DM_USER': owner}) as (watch, replay):
                self.say(replay, '200.000100', 'a' * 800, user=owner)
                self.say(replay, '200.000200', 'b' * 800, user=owner)
                watch.poll()
                first = io.StringIO()
                with contextlib.redirect_stdout(first):
                    plane.emit(watch, 'check')
                [line] = first.getvalue().splitlines()
                self.assertEqual(len(line), plane.WAKE_LIMIT)
                self.assertTrue(line.endswith('; +1 queued'))
                head = self.wake_parts(line[:-len('; +1 queued')])
                self.assertEqual((head['ts'], head['user'], head['pointer']),
                                 ('200.000100', owner, 'state/slack-watch/requests.jsonl#200.000100'))
                self.assertEqual(self.record(watch, '200.000100')['text'], 'a' * 800)
                second = io.StringIO()
                with contextlib.redirect_stdout(second):
                    plane.emit(watch, 'check')
                [line] = second.getvalue().splitlines()
                self.assertEqual(self.wake_parts(line.split('; +')[0])['ts'], '200.000200')

    def test_a_partial_line_in_the_store_does_not_swallow_the_next_record(self):
        with self.fixture() as (watch, replay):
            store = watch.root / 'requests.jsonl'
            store.write_text(json.dumps({'ts': '150.000100', 'text': 'earlier', 'replaced': False}) + '\n{"ts": "160.000100", "te')
            self.say(replay, '200.000100', 'y' * 600)
            watch.poll()
            [line] = self.wakes(watch)
            self.assertEqual(self.wake_parts(line)['pointer'], 'state/slack-watch/requests.jsonl#200.000100')
            self.assertEqual(self.record(watch, '200.000100')['text'], 'y' * 600)
            self.assertEqual(watch.record('200.000100')['text'], 'y' * 600)
            self.assertEqual(watch.record('150.000100')['text'], 'earlier')

    def test_an_empty_state_override_means_the_home_state_as_the_shell_scripts_read_it(self):
        env = dict(ClosedTransportTest.ENV, FM_SLACK_NO_NETWORK='1')
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as home, tempfile.TemporaryDirectory(dir=Path.cwd()) as elsewhere:
            (Path(home) / 'state' / 'decision-bindings').mkdir(parents=True)
            here = os.getcwd()
            os.chdir(elsewhere)
            try:
                with patch.dict(os.environ, dict(env, FM_HOME=home, FM_STATE_OVERRIDE='')):
                    watch = Watch(token='fixture-token-not-a-secret')
                    try:
                        self.assertEqual(watch.root.resolve(), (Path(home) / 'state' / 'slack-watch').resolve())
                        self.assertEqual(plane.state_home().resolve(), (Path(home) / 'state').resolve())
                        probe = os.open(Path(home) / 'state' / 'decision-bindings', os.O_RDONLY)
                        try:
                            with watch.binding_held(), self.assertRaises(BlockingIOError):
                                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        finally:
                            os.close(probe)
                    finally:
                        watch.lock.close()
            finally:
                os.chdir(here)
            self.assertEqual(os.listdir(elsewhere), [])

    def test_an_empty_home_variable_means_the_default_home(self):
        env = dict(ClosedTransportTest.ENV, FM_SLACK_NO_NETWORK='1')
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as state:
            with patch.dict(os.environ, dict(env, FM_HOME='', FM_STATE_OVERRIDE=state)):
                watch = Watch(token='fixture-token-not-a-secret')
                try:
                    self.assertEqual(watch.home, plane.ROOT.parent.resolve())
                finally:
                    watch.lock.close()

    def stage_notice(self, watch, event, thread):
        return {'event': event, 'key': 'k-' + event, 'thread': thread, 'text': 'A notice', 'kind': 'notice',
                'line': 'check: slack %s - a notice' % thread, 'stage': 'notice', 'contributing': []}

    def test_a_fresh_notice_and_a_waiting_request_share_the_cap_once(self):
        with self.fixture(cap='2') as (watch, replay):
            watch.state['threads']['gone:live'] = {'ts': '150.000100', 'key': 'gone', 'identity': 'x', 'options': []}
            self.say(replay, '150.000200', 'a late reply', thread_ts='150.000100')
            self.say(replay, '200.000100', 'a new request')
            with patch.object(watch, 'hold', return_value='closed'):
                watch.poll()
            self.assertEqual(sorted(self.acks(replay)), ['150.000100', '200.000100'])

    def test_a_resumed_notice_a_fresh_notice_and_a_request_share_the_cap_once_each(self):
        with self.fixture(cap='3') as (watch, replay):
            watch.state['threads']['gone:live'] = {'ts': '150.000100', 'key': 'gone', 'identity': 'x', 'options': []}
            watch.state['pending'].append(self.stage_notice(watch, 'test/notice/resumed', '120.000100'))
            watch.commit()
            self.say(replay, '150.000200', 'a late reply', thread_ts='150.000100')
            self.say(replay, '200.000100', 'a new request')
            with patch.object(watch, 'hold', return_value='closed'):
                watch.poll()
            self.assertEqual(sorted(self.acks(replay)), ['120.000100', '150.000100', '200.000100'])

    def state_text(self, watch):
        """Every byte the plane left in its state folder, as one text."""
        return ''.join(path.read_text(errors='replace') for path in sorted(watch.root.rglob('*')) if path.is_file())

    def test_a_collision_refusal_reports_and_stores_no_plane_value(self):
        # The refusal for a plane value that is part of the marker or the flag reports a fixed name; that name, and
        # the line that carries it, must hold no plane value (here the value is a word of the name itself).
        with self.fixture(env={'SLACK_SIGNING_SECRET': 'secret'}) as (watch, replay):
            self.say(replay, '200.000100', 'an ordinary request')
            with self.assertRaisesRegex(SlackError, 'collides_with_marker'):
                watch.poll()
            error = SlackError('secret_collides_with_marker')
            watch.report_failure(error)
            self.assertEqual(self.acks(replay), [])
            self.assertTrue([line for line in watch.output if 'transport failure' in line])
            reported = '\n'.join(watch.output)
            self.assertNotIn('secret', reported.replace('collides_with_marker', ''), reported)
            self.assertNotIn('"secret_collides', self.state_text(watch))
            self.assertNotIn('failure": "secret', self.state_text(watch))
            watch.report_failure(error)
            self.assertEqual(len([line for line in watch.output if 'transport failure' in line]), 1)
        # An eligible credential-shaped value (16 characters or more, Amendment bg) that collides with the marker is the
        # marker's own text; it is refused and reported without the value in either place.
        with self.fixture(env={'SLACK_SIGNING_SECRET': plane.SECRET_MARKER}) as (watch, replay):
            self.say(replay, '200.000100', 'an ordinary request')
            with self.assertRaisesRegex(SlackError, 'collides_with_marker'):
                watch.poll()
            watch.report_failure(SlackError('secret_collides_with_marker'))
            self.assertEqual(self.acks(replay), [])
            self.assertNotIn(plane.SECRET_MARKER, '\n'.join(watch.output) + self.state_text(watch))
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'an ordinary request')
            watch.poll()
            self.assertEqual(self.acks(replay), ['200.000100'])
            self.assertNotIn(self.SIGNING, '\n'.join(watch.output) + self.state_text(watch))

    def test_a_padded_secret_value_changes_no_text_that_does_not_hold_it_exactly(self):
        padded = ' plane '
        text = 'check airplane status: ' + 'x' * 1000
        with self.fixture(env={'SLACK_SIGNING_SECRET': padded}) as (watch, replay):
            self.say(replay, '200.000100', text)
            watch.poll()
            line = self.wakes(watch)[0]
            self.assertNotIn('; secret removed', line)
            self.assertIn('check airplane status: ', line)
            record = watch.record('200.000100')
            self.assertEqual((record['text'], record['replaced']), (text, False))
        with self.fixture(env={'SLACK_SIGNING_SECRET': padded}) as (watch, replay):
            self.say(replay, '200.000100', 'an exact ' + padded + ' occurrence')
            watch.poll()
            self.assertIn('; secret removed', self.wakes(watch)[0])

    def test_retarget_refuses_while_an_old_owner_request_is_unread_after_the_allowlist_changed(self):
        new_owner = {'FM_SLACK_DM_USER': 'U0OTHEROWNER1', 'FM_SLACK_ALLOWED_AUTHORS': 'U0OTHEROWNER1'}
        with self.fixture(cap='1') as (watch, replay):
            self.say(replay, '200.000100', 'first request')
            self.say(replay, '200.000200', 'second request')
            watch.poll()
            self.assertEqual(self.acks(replay), ['200.000100'])
            before = watch.load_state()
            watch.lock.close()
            with patch.dict(os.environ, new_owner):
                changed = Watch(replay=replay)
                try:
                    with patch.object(changed, 'bound', return_value=True), self.assertRaisesRegex(
                            SlackError, '^dm_user_changed_with_unread_requests$'):
                        changed.retarget()
                    self.assertEqual(changed.load_state(), before)
                finally:
                    changed.lock.close()
            # The old DM is then drained under the old settings and retarget accepts.
            drained = Watch(replay=replay)
            try:
                with patch.object(drained, 'bound', return_value=True), patch.object(drained, 'backlog', return_value=[]):
                    drained.poll()
            finally:
                drained.lock.close()
            self.assertEqual(self.acks(replay), ['200.000100', '200.000200'])
            with patch.dict(os.environ, new_owner):
                again = Watch(replay=replay)
                try:
                    self.assertTrue(again.retarget())
                finally:
                    again.lock.close()
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'stranger', user='U0STRANGER01')
            self.say(replay, '200.000200', 'bot', bot_id='BLOOKALIKE')
            watch.lock.close()
            with patch.dict(os.environ, new_owner):
                changed = Watch(replay=replay)
                try:
                    self.assertTrue(changed.retarget())
                finally:
                    changed.lock.close()

    @contextmanager
    def configured(self, replay, owner, authors):
        """A new Watch of the same state and replay under another owner and allowlist (a new process after a change)."""
        env = {'FM_SLACK_DM_USER': owner, 'FM_SLACK_ALLOWED_AUTHORS': authors}
        with patch.dict(os.environ, env):
            watch = Watch(replay=replay)
            try:
                with patch.object(watch, 'bound', return_value=True), patch.object(watch, 'backlog', return_value=[]):
                    yield watch
            finally:
                watch.lock.close()

    NEW_OWNER = 'U0OTHEROWNER1'

    def retargeted(self, replay, authors):
        with self.configured(replay, self.NEW_OWNER, authors) as watch:
            self.assertTrue(watch.retarget())
            return watch.load_state()

    def test_retarget_keeps_the_old_cursor_and_delivers_a_message_that_arrives_after_the_decision(self):
        both = self.OWNER + ',' + self.NEW_OWNER
        with self.fixture(authors=both) as (watch, replay):
            watch.lock.close()
            state = self.retargeted(replay, both)
            self.assertEqual((state['drain']['user'], state['drain']['channel'], state['drain']['intake_cursor']),
                             (self.OWNER, 'D0123456789', '100.000100'))
            self.assertNotIn('intake_cursor', state)
            # The operator arms the new DM; a third owner cannot be retargeted to while the old DM is still draining.
            with self.configured(replay, self.NEW_OWNER, both) as arming:
                arming.prepare()
            with self.configured(replay, 'U0THIRDOWNER1', both) as third:
                with self.assertRaisesRegex(SlackError, '^dm_user_changed_while_draining$'):
                    third.retarget()
            # A message arrives in the old DM after the decision: the drain delivers it, in the old DM thread.
            self.say(replay, '200.000100', 'arrived after the retarget decision')
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.window_reads = 0
                polling.poll()
                self.assertEqual(self.acks(replay), ['200.000100'])
                self.assertEqual([line.split()[3] for line in self.wakes(polling)], ['200.000100'])
                self.assertIn('drain', polling.load_state())
            opens = [e for e in replay.state['log'] if e['method'] in ('conversations.open', 'chat.postMessage')]
            self.assertEqual([e['method'] for e in opens[-2:]], ['conversations.open', 'chat.postMessage'])
            self.assertEqual(opens[-2]['recipient'], self.OWNER)
            # One later poll reads the old DM empty: only then is the old boundary dropped, and nothing repeats.
            self.say(replay, '200.000200', 'a stranger', user='U0STRANGER01')
            self.say(replay, '200.000300', 'a bot', bot_id='BLOOKALIKE')
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.poll()
                self.assertNotIn('drain', polling.load_state())
                self.assertEqual(self.acks(replay), ['200.000100'])
                self.assertEqual(len(self.wakes(polling)), 1)   # the one line already owed, not a second request
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.poll()
                self.assertEqual(self.acks(replay), ['200.000100'])
                self.assertEqual(len(self.wakes(polling)), 1)

    def test_a_transient_post_failure_then_recovery_acknowledges_exactly_once(self):
        with self.fixture() as (watch, replay):
            self.say(replay, '200.000100', 'a request')
            original, failed = replay.call, []

            def call(method, **fields):
                if method == 'chat.postMessage' and not failed:
                    failed.append(fields)
                    raise SlackError('api_error')
                return original(method, **fields)
            with patch.object(replay, 'call', side_effect=call):
                with self.assertRaisesRegex(SlackError, '^api_error$'):
                    watch.poll()
            self.assertEqual((self.acks(replay), self.wakes(watch)), ([], []))
            watch.state, watch.advanced = watch.load_state(), 0
            watch.poll()
            watch.state, watch.advanced = watch.load_state(), 0
            watch.poll()
            self.assertEqual(self.acks(replay), ['200.000100'])
            self.assertEqual(len(self.wakes(watch)), 1)

    def test_the_drain_acknowledges_in_the_old_dm_thread_only_after_proving_that_dm(self):
        # Pending the owner's approval (Main 2331): the one fixed acknowledgement goes into the old DM thread, after
        # conversations.open for the stored old owner returned that DM, and into no other channel or thread.
        both = self.OWNER + ',' + self.NEW_OWNER
        with self.fixture(authors=both) as (watch, replay):
            watch.lock.close()
            self.retargeted(replay, both)
            self.say(replay, '200.000100', 'arrived after the retarget decision')
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.poll()
            writes = [e for e in replay.state['log'] if e['method'] == 'chat.postMessage']
            self.assertEqual([(e['channel'], e['thread_ts']) for e in writes], [('D0123456789', '200.000100')])
            order = [e['method'] for e in replay.state['log'] if e['method'] in ('conversations.open', 'chat.postMessage')]
            self.assertEqual(order[-2:], ['conversations.open', 'chat.postMessage'])
        with self.fixture(authors=both) as (watch, replay):
            watch.lock.close()
            self.retargeted(replay, both)
            self.say(replay, '200.000100', 'arrived after the retarget decision')
            replay.transcript['owner_dm'] = 'D0SOMEONEELSE'
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.poll()
            self.assertEqual([e for e in replay.state['log'] if e['method'] == 'chat.postMessage'], [])

    def test_a_message_that_arrives_right_after_retargets_last_read_is_delivered_not_lost(self):
        # Main 2315: a message arriving between the last read and the decision is delivered (not lost). The message is
        # appended inside retarget, the instant its read of the old DM has finished and found nothing unread.
        both = self.OWNER + ',' + self.NEW_OWNER
        original = plane.Watch.newer_messages

        def late(watch, channel, cursor):
            yield from original(watch, channel, cursor)
            watch.api.state['messages'].append({'ts': '200.000100', 'user': self.OWNER, 'text': 'arrived after the last read'})
        with self.fixture(authors=both) as (watch, replay):
            watch.lock.close()
            with self.configured(replay, self.NEW_OWNER, both) as deciding:
                with patch.object(plane.Watch, 'newer_messages', late):
                    self.assertTrue(deciding.retarget())
            self.assertIn('drain', deciding.load_state())
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.poll()
                self.assertEqual([line.split()[3] for line in self.wakes(polling)], ['200.000100'])

    def test_a_drain_for_an_old_owner_who_left_the_allowlist_delivers_nothing_and_says_so_once(self):
        with self.fixture() as (watch, replay):
            watch.lock.close()
            state = self.retargeted(replay, self.NEW_OWNER)
            self.assertIn('drain', state)
            self.say(replay, '200.000100', 'arrived after the retarget decision')
            with self.configured(replay, self.NEW_OWNER, self.NEW_OWNER) as polling:
                polling.poll()
                self.assertEqual((self.acks(replay), self.wakes(polling)), ([], []))
                failures = [line for line in polling.output if 'no longer in FM_SLACK_ALLOWED_AUTHORS' in line]
                self.assertEqual(len(failures), 1, polling.output)
                self.assertNotIn('drain', polling.load_state())
            self.assertEqual([m['ts'] for m in replay.state['messages'] if m['ts'] == '200.000100'], ['200.000100'])
            with self.configured(replay, self.NEW_OWNER, self.NEW_OWNER) as polling:
                polling.poll()
                self.assertEqual((self.acks(replay), self.wakes(polling)), ([], []))

    def test_a_drain_that_cannot_prove_the_old_dm_writes_and_reads_nothing_more(self):
        both = self.OWNER + ',' + self.NEW_OWNER
        with self.fixture(authors=both) as (watch, replay):
            watch.lock.close()
            self.retargeted(replay, both)
            self.say(replay, '200.000100', 'arrived after the retarget decision')
            replay.transcript['owner_dm'] = 'D0SOMEONEELSE'
            with self.configured(replay, self.NEW_OWNER, both) as polling:
                polling.poll()
                self.assertEqual((self.acks(replay), self.wakes(polling)), ([], []))
                self.assertEqual(len([line for line in polling.output if 'could not be proven' in line]), 1)
                self.assertNotIn('drain', polling.load_state())

    def test_a_notice_that_fails_part_way_still_charges_the_cap(self):
        def run(failing):
            with self.fixture(cap='2') as (watch, replay):
                watch.state['threads']['gone:live'] = {'ts': '150.000100', 'key': 'gone', 'identity': 'x', 'options': []}
                self.say(replay, '150.000200', 'a late reply', thread_ts='150.000100')
                self.say(replay, '150.000300', 'another late reply', thread_ts='150.000100')
                self.say(replay, '200.000100', 'a first request')
                self.say(replay, '200.000200', 'a second request')
                original, posts = replay.call, []

                def call(method, **fields):
                    if method == 'chat.postMessage' and fields.get('thread_ts') == '150.000100':
                        posts.append(fields)
                        if failing and len(posts) == 2:
                            raise SlackError('api_error')
                    return original(method, **fields)
                with patch.object(replay, 'call', side_effect=call), patch.object(watch, 'hold', return_value='closed'):
                    try:
                        watch.poll()
                    except SlackError as error:
                        self.assertEqual(str(error), 'api_error')
                requests = [thread for thread in self.acks(replay) if thread.startswith('200.')]
                notices = [thread for thread in self.acks(replay) if thread.startswith('150.')]
                return requests, notices
        self.assertEqual(run(failing=False), ([], ['150.000100', '150.000100']))
        requests, notices = run(failing=True)
        self.assertEqual(requests, [])
        self.assertLessEqual(len(notices) + 1, 2)

    def test_every_intake_scenario_runs_on_the_permission_sensitive_replay(self):
        with self.fixture() as (watch, replay):
            self.assertEqual(set(replay.transcript['scopes']), set(BASE_SCOPES))
            self.assertEqual(replay.transcript['method_allowlist'], list(ReplayShapeTest.POPULATION))
            self.assertTrue(replay.transcript['enforce_scopes'])
            with self.assertRaisesRegex(SlackError, 'method_not_allowed'):
                replay.call('files.list')
            self.assertEqual(replay.call('users.info', user=self.OWNER)['ok'], True)
        with self.fixture(scopes=('chat:write', 'im:write', 'im:history')) as (watch, replay):
            with self.assertRaisesRegex(SlackError, 'missing_scope'):
                replay.call('users.info', user=self.OWNER)

    def test_the_wake_line_grammar_accepts_valid_lines_and_rejects_the_malformed(self):
        label = plane.REQUEST_LABEL
        one = 'check: slack request 200.000100 from U0TESTOWNER: %s %s' % (label, json.dumps('hello'))
        cut = one + '; full: state/slack-watch/requests.jsonl#200.000100'
        joined = ('%s; check: slack 150.000100 - a notice; check: slack request 200.000200 from W0TESTOWNER: %s %s; +2 queued'
                  % (one, label, json.dumps('second; check: slack 1.2 - inside the literal')))
        self.assertEqual(parse_wake_line(one)[0][0]['text'], 'hello')
        self.assertEqual(parse_wake_line(cut)[0][0]['pointer'], 'state/slack-watch/requests.jsonl#200.000100')
        segments, marker = parse_wake_line(joined)
        self.assertEqual([s['kind'] for s in segments], ['request', 'other', 'request'])
        self.assertEqual((segments[2]['text'], marker), ('second; check: slack 1.2 - inside the literal', '+2 queued'))
        self.assertEqual(parse_wake_line(cut + '; +1 queued')[1], '+1 queued')
        self.assertEqual(parse_wake_line(one + '; ' + plane.SECRET_FLAG + '; full: state/slack-watch/requests.jsonl#9.9')[0][0]['flag'], True)
        for bad in (cut.replace('; full: ', '; +1 queued; full: '),                       # the marker before the pointer
                    one + '; +1 queued; ' + plane.SECRET_FLAG,                            # the marker before the flag
                    one + '; full: state/slack-watch/requests.jsonl#200.000100; ' + plane.SECRET_FLAG,   # the flag after the pointer
                    one + ' ' + json.dumps('second literal'),
                    one.replace(label + ' ', ''),                                          # no label
                    one + '\n', 'check: slack request 2.1 from U0TESTOWNER: ' + label + ' "x',
                    one.replace('"hello"', 'hello'),
                    one + '; +1 queued; +2 queued', 'x' * 481):
            with self.assertRaises((AssertionError, ValueError)):
                parse_wake_line(bad)

    def test_a_message_that_is_not_empty_is_a_request_whatever_it_looks_like(self):
        shown = {'200.000100': '\ue000', '200.000200': '   ', '200.000300': '\u2028\u200b\u0085', '200.000400': '\u200b'}
        with self.fixture(cap='10') as (watch, replay):
            for ts, text in shown.items():
                self.say(replay, ts, text)
            self.say(replay, '200.000500', '')
            self.say(replay, '200.000600', 'a successor')
            watch.poll()
            self.assertEqual(sorted(self.acks(replay)), ['200.000100', '200.000200', '200.000300', '200.000400', '200.000600'])
            self.assertEqual(watch.load_state()['pending'], [])


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


    def test_a_set_but_empty_network_value_also_closes_the_real_transport(self):
        for value in ('', '0', '1'):
            with self.subTest(value=value), tempfile.TemporaryDirectory(dir=Path.cwd()) as directory, \
                 patch.dict(os.environ, dict(self.ENV, FM_HOME=directory, FM_STATE_OVERRIDE=directory,
                                             FM_SLACK_NO_NETWORK=value)), \
                 patch('fm_slack.urllib.request.urlopen', side_effect=AssertionError('a socket was opened')):
                watch = Watch(token='fixture-token-not-a-secret')
                try:
                    with patch.object(watch, 'bound', return_value=True):
                        with self.assertRaisesRegex(SlackError, '^network_closed$'):
                            watch.api.call('auth.test')
                finally:
                    watch.lock.close()


class RegisteredGateTest(unittest.TestCase):
    """A scenario does not run a fixture home's registered check file where it could reach a REAL registered Slack
    check file outside its own fixture (Main 2180, 2191): there it skips with a named reason, and Main or the grader
    runs it under a host-level denial with FM_SLACK_GRADER_RUN set. Where none exists (a CI runner) it runs. Both
    sides are tested here with a stub in place of every file, so that this test itself never runs the real one."""

    GATE = REPO / 'tests' / 'fixtures' / 'slack' / 'registered-gate.sh'
    REASON = 'a real registered Slack check file exists at '

    def environment(self, **extra):
        drop = ('FM_HOME', 'FM_STATE_OVERRIDE', 'FM_SLACK_GRADER_RUN', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_CONFIG_GLOBAL')
        env = {key: value for key, value in os.environ.items() if key not in drop}
        env.update(extra)
        return env

    def make_real(self, directory):
        """A directory that holds a stub registered file at state/slack.check.sh, as a real home would."""
        (Path(directory) / 'state').mkdir(parents=True, exist_ok=True)
        stub = Path(directory) / 'state' / 'slack.check.sh'
        stub.write_text('#!/usr/bin/env bash\nexit 0\n')
        return stub

    def checkout(self, parent):
        """A checkout of the gate, with no git repository around it and no state of its own."""
        tree = Path(parent) / 'checkout'
        (tree / 'tests' / 'fixtures' / 'slack').mkdir(parents=True)
        shutil.copy(self.GATE, tree / 'tests' / 'fixtures' / 'slack' / 'registered-gate.sh')
        return tree

    def run_gate(self, tree, **env):
        """Source the gate in that checkout; run a stub file only if the gate allows it."""
        ran = Path(tree).parent / 'ran'
        ran.unlink(missing_ok=True)
        stub = Path(tree).parent / 'registered.sh'
        stub.write_text('#!/usr/bin/env bash\ntouch "%s"\n' % ran)
        stub.chmod(0o755)
        script = '. "$1"; if fm_slack_registered_allowed "TEST-LABEL"; then "$2"; fi'
        gate = Path(tree) / 'tests' / 'fixtures' / 'slack' / 'registered-gate.sh'
        result = subprocess.run(['bash', '-c', script, '_', str(gate), str(stub)], env=self.environment(**env),
                                capture_output=True, text=True, check=False)
        return result, ran.exists()

    def assert_skipped(self, result, ran, where):
        self.assertEqual((result.returncode, ran), (0, False), result.stderr)
        [line] = result.stdout.splitlines()
        self.assertTrue(line.startswith('skip - TEST-LABEL (' + self.REASON + str(where)), line)

    def test_where_no_real_registered_file_exists_the_file_runs_and_nothing_is_printed(self):
        with tempfile.TemporaryDirectory() as parent:
            result, ran = self.run_gate(self.checkout(parent))
            self.assertEqual((result.returncode, result.stdout, ran), (0, '', True), result.stderr)

    def test_a_real_registered_file_in_the_inherited_state_directory_skips_with_its_name(self):
        with tempfile.TemporaryDirectory() as parent, tempfile.TemporaryDirectory() as real:
            stub = self.make_real(real)
            result, ran = self.run_gate(self.checkout(parent), FM_STATE_OVERRIDE=str(stub.parent))
            self.assert_skipped(result, ran, stub)

    def test_a_real_registered_file_in_the_inherited_home_skips_with_its_name(self):
        with tempfile.TemporaryDirectory() as parent, tempfile.TemporaryDirectory() as real:
            stub = self.make_real(real)
            result, ran = self.run_gate(self.checkout(parent), FM_HOME=real)
            self.assert_skipped(result, ran, stub)

    def test_a_real_registered_file_in_the_home_of_the_checkout_itself_skips_with_its_name(self):
        with tempfile.TemporaryDirectory() as parent:
            tree = self.checkout(parent)
            stub = self.make_real(tree)
            result, ran = self.run_gate(tree)
            self.assert_skipped(result, ran, stub)

    def test_a_real_registered_file_in_the_primary_home_of_a_worktree_skips_with_its_name(self):
        git = {'GIT_CONFIG_GLOBAL': os.devnull, 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t',
               'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t'}
        with tempfile.TemporaryDirectory() as parent:
            primary = Path(parent) / 'primary'
            primary.mkdir()
            env = self.environment(**git)
            for command in (['init', '-q'], ['config', 'core.hooksPath', os.devnull]):
                subprocess.run(['git', '-C', str(primary), *command], env=env, check=True, capture_output=True)
            tree_id = subprocess.run(['git', '-C', str(primary), 'hash-object', '-t', 'tree', '-w', '--stdin'], env=env,
                                     input='', check=True, capture_output=True, text=True).stdout.strip()
            commit = subprocess.run(['git', '-C', str(primary), 'commit-tree', tree_id, '-m', 'x'], env=env,
                                    check=True, capture_output=True, text=True).stdout.strip()
            subprocess.run(['git', '-C', str(primary), 'update-ref', 'refs/heads/main', commit], env=env, check=True,
                           capture_output=True)
            work = Path(parent) / 'work'
            subprocess.run(['git', '-C', str(primary), 'worktree', 'add', '-q', '--detach', str(work), commit], env=env,
                           check=True, capture_output=True)
            (work / 'tests' / 'fixtures' / 'slack').mkdir(parents=True)
            shutil.copy(self.GATE, work / 'tests' / 'fixtures' / 'slack' / 'registered-gate.sh')
            result, ran = self.run_gate(work, **git)
            self.assertEqual((result.returncode, result.stdout, ran), (0, '', True), result.stderr)
            stub = self.make_real(primary)
            result, ran = self.run_gate(work, **git)
            self.assert_skipped(result, ran, stub.resolve())

    def test_the_grader_marker_runs_the_file_even_where_a_real_one_exists(self):
        with tempfile.TemporaryDirectory() as parent, tempfile.TemporaryDirectory() as real:
            self.make_real(real)
            tree = self.checkout(parent)
            result, ran = self.run_gate(tree, FM_HOME=real, FM_SLACK_GRADER_RUN='1')
            self.assertEqual((result.returncode, result.stdout, ran), (0, '', True), result.stderr)
            result, ran = self.run_gate(tree, FM_HOME=real, FM_SLACK_GRADER_RUN='')
            self.assert_skipped(result, ran, Path(real) / 'state' / 'slack.check.sh')

    def run_deadline_entry(self, **env):
        """The deadline suite's own entry script, copied beside the gate and a stub that stands in for its Python test."""
        with tempfile.TemporaryDirectory() as directory:
            tree = Path(directory) / 'checkout'
            (tree / 'tests' / 'fixtures' / 'slack').mkdir(parents=True)
            shutil.copy(REPO / 'tests' / 'fm-slack-deadline.test.sh', tree / 'tests' / 'fm-slack-deadline.test.sh')
            (tree / 'tests' / 'lib.sh').write_text('# the entry script sources the shared test library; nothing of it is needed here\n')
            shutil.copy(self.GATE, tree / 'tests' / 'fixtures' / 'slack' / 'registered-gate.sh')
            (tree / 'tests' / 'fm_slack_deadline_test.py').write_text(
                'import pathlib\npathlib.Path(__file__).with_name("ran").write_text("ran")\n')
            tool = Path(directory) / 'tool'
            tool.mkdir()
            (tool / 'tasks-axi').write_text('#!/usr/bin/env bash\nexit 0\n')
            (tool / 'tasks-axi').chmod(0o755)
            real = Path(directory) / 'real'
            self.make_real(real)
            environment = self.environment(**{key: (str(real) if value is True else value) for key, value in env.items()})
            environment['PATH'] = str(tool) + os.pathsep + environment['PATH']
            result = subprocess.run(['bash', str(tree / 'tests' / 'fm-slack-deadline.test.sh')], env=environment,
                                    capture_output=True, text=True, check=False)
            return result, (tree / 'tests' / 'ran').exists(), real / 'state' / 'slack.check.sh'

    def test_the_deadline_suite_runs_its_python_test_where_no_real_registered_file_exists(self):
        result, ran, _ = self.run_deadline_entry()
        self.assertEqual((result.returncode, ran, result.stdout), (0, True, ''), result.stderr)

    def test_the_deadline_suite_skips_before_its_python_test_starts_where_a_real_one_exists(self):
        result, ran, real = self.run_deadline_entry(FM_HOME=True)
        self.assertEqual((result.returncode, ran), (0, False), result.stderr)
        [line] = result.stdout.splitlines()
        self.assertTrue(line.startswith('skip - the Slack deadline suite (' + self.REASON + str(real)), line)

    def test_the_deadline_suite_runs_under_the_grader_marker_where_a_real_one_exists(self):
        result, ran, _ = self.run_deadline_entry(FM_HOME=True, FM_SLACK_GRADER_RUN='1')
        self.assertEqual((result.returncode, ran, result.stdout), (0, True, ''), result.stderr)


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


REQUEST_SEGMENT = re.compile(r'check: slack request ([0-9]+\.[0-9]+) from ([UW][A-Z0-9]+)( \(not acknowledged after 3 tries\))?: '
                             + re.escape(plane.REQUEST_LABEL) + ' ')
OTHER_SEGMENT = re.compile(r'check: slack [0-9]+\.[0-9]+ - .*?(?=; check: slack |; \+[0-9]+ queued$|$)', re.S)
POINTER_PART = re.compile(r'; full: state/slack-watch/requests\.jsonl#[0-9]+\.[0-9]+')
QUEUED_PART = re.compile(r'; \+[0-9]+ queued')


def parse_wake_line(line):
    """One printed wake line by the grammar of I4a, read left to right with a JSON parser (never by splitting on
    the delimiters, which a request text may hold): one or more segments joined by '; ', a request segment being the
    label and ONE JSON string literal, then the flag when a value was replaced, then the pointer when the text was
    cut; the queue marker last and alone. Raises AssertionError for anything outside it. Returns (segments, marker)."""
    assert len(line) <= plane.WAKE_LIMIT, 'line too long: %d' % len(line)
    assert all(unicodedata.category(c) not in ('Cc', 'Zl', 'Zp') for c in line), 'control or separator in a line'
    segments, pos = [], 0
    while True:
        match = REQUEST_SEGMENT.match(line, pos)
        if match:
            text, pos = json.JSONDecoder().raw_decode(line, match.end())
            segment = {'kind': 'request', 'ts': match.group(1), 'user': match.group(2), 'released': bool(match.group(3)),
                       'text': text, 'flag': False, 'pointer': None}
            if line.startswith('; ' + plane.SECRET_FLAG, pos) and (
                    pos + 2 + len(plane.SECRET_FLAG) == len(line) or line.startswith('; ', pos + 2 + len(plane.SECRET_FLAG))):
                segment['flag'] = True
                pos += 2 + len(plane.SECRET_FLAG)
            pointer = POINTER_PART.match(line, pos)
            if pointer:
                segment['pointer'] = pointer.group(0)[len('; full: '):]
                pos = pointer.end()
        else:
            other = OTHER_SEGMENT.match(line, pos)
            assert other and other.end() > pos, 'not a segment of the grammar: ' + line[pos:pos + 80]
            segment, pos = {'kind': 'other', 'text': other.group(0)}, other.end()
        segments.append(segment)
        if pos == len(line):
            return segments, None
        if QUEUED_PART.fullmatch(line, pos):
            return segments, line[pos + 2:]
        assert line.startswith('; check: slack ', pos), 'outside the grammar: ' + line[pos:pos + 80]
        pos += 2


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
    elif command in ('request-lines', 'request-texts'):
        lines = sys.stdin.read().splitlines()
        texts = []
        for line in lines:
            texts += [segment['text'] for segment in parse_wake_line(line)[0] if segment['kind'] == 'request']
        if command == 'request-texts':
            print('\n'.join(texts))
        else:
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
