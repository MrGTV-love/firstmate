#!/usr/bin/env python3
"""Slack decision mirror and keyed-answer poll.

Decisions, authority, replay detection, and record creation stay in
bin/fm-captain-hold.sh. This file is transport plus the rule that turns one
authorized Slack signal into one keyed row for that intake.

State is a write-ahead journal: a staged publication is saved before it reaches
the intake, and a resumed poll continues the exact same stage. A crash may
repeat a notification but cannot discard a read reply.
"""
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import uuid

from fm_slack import Slack, SlackError
from fm_slack_replay import Replay

ROOT = Path(__file__).resolve().parent
SOURCE = 'slack-dm'
CHECK_ID = 'slack'
STATE_KEY = 'slack-watch'
REACTIONS = ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine']
USER_ID = re.compile(r'[UW][A-Z0-9]{8,}')
OPTION_LINE = re.compile(r'^\s*Option\s*([1-9][0-9]*)\s*[.):]\s*(.*)$')
WAKE_LIMIT = 480
QUEUE_RESERVE = 16
SLACK_LINK = re.compile(r'<((?:https?://|mailto:)[^<>|\s]+)(?:\|([^<>]*))?>')
CARD_TAIL = ('\nFull decision remains in the local backlog.'
             '\nReply in this thread with your answer.'
             '\nMessages typed in the main DM window are not read.')


def run(script, *args, text=None):
    env = dict(os.environ)
    env.pop('SLACK_BOT_TOKEN', None)
    env['PYTHONDONTWRITEBYTECODE'] = '1'
    return subprocess.run(['bash', str(ROOT / script), *args], input=text,
                          text=True, capture_output=True, check=False, env=env)


def save(path, value):
    if path.is_symlink():
        raise SlackError('unsafe_state_path')
    fd, name = tempfile.mkstemp(prefix='.slack-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(value, out, ensure_ascii=False)
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def env_value(key):
    return os.environ.get(key, '')


def flat(value):
    """Keep the intake's one-line framing: newlines, tabs, and controls become spaces."""
    value = str(value).replace('\r', ' ').replace('\n', ' ').replace('\t', ' ')
    return ''.join(ch for ch in value if ord(ch) >= 32 and ord(ch) != 127)


def typed_text(value):
    """Undo Slack's escaping of a typed message so the record holds what the owner typed."""
    value = SLACK_LINK.sub(lambda match: match.group(2) or match.group(1), value)
    return value.replace('&lt;', '<').replace('&gt;', '>').replace('&amp;', '&')


def stamp(value):
    for form in ('%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%MZ'):
        try:
            return datetime.strptime(value, form).replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            pass
    return None


def fresh(generated, identity):
    """A board card is current only when the board was regenerated after the hold was set."""
    board, hold = stamp(generated), stamp(identity.partition('#')[0])
    return bool(board and hold and board > hold)


def wake_line(lines, queued=0):
    line = '; '.join(lines)
    tail = '; +%d queued' % queued if queued else ''
    room = WAKE_LIMIT - len(tail)
    return (line if len(line) <= room else line[:room - 3] + '...') + tail


def settings():
    token = env_value('SLACK_BOT_TOKEN').strip()
    authors_raw = env_value('FM_SLACK_ALLOWED_AUTHORS').strip()
    authors = [a for a in re.split(r'[\s,]+', authors_raw) if a]
    dm_user = env_value('FM_SLACK_DM_USER').strip()
    valid_authors = bool(authors) and all(USER_ID.fullmatch(a) for a in authors)
    return token, authors, dm_user, valid_authors


def answer_cap():
    raw = env_value('FM_SLACK_POLL_MAX_ANSWERS').strip() or '20'
    return int(raw) if raw.isdecimal() and 1 <= int(raw) <= 200 else None


def mode():
    token, authors, dm_user, valid = settings()
    if not token or not authors:
        return 'off', 'unconfigured'
    if not valid:
        return 'refused', 'allowlist_unparseable'
    if not USER_ID.fullmatch(dm_user):
        return 'refused', 'missing_or_invalid_FM_SLACK_DM_USER'
    if answer_cap() is None:
        return 'refused', 'invalid_FM_SLACK_POLL_MAX_ANSWERS_1_to_200'
    return 'on', ''


def parse_options(lines):
    options = []
    for line in lines:
        match = OPTION_LINE.match(line)
        if not match:
            continue
        rest, hint = match.group(2).strip(), ''
        if ' - ' in rest:
            rest, hint = rest.split(' - ', 1)
        meta = re.search(r'^(.*?)\s*\(([^()]+)\)\s*$', rest)
        label, value = (meta.group(1).strip(), meta.group(2).strip()) if meta else (rest.strip(), rest.strip())
        if value == 'reconcile' or not value:
            continue
        options.append({'value': value, 'label': label, 'hint': hint.strip()})
    return options


def parse_fields(lines):
    recommendation = ''
    evidence = ''
    for line in lines:
        match = re.match(r'^\s*Recommendation:\s*(.*)$', line)
        if match:
            recommendation = match.group(1).strip()
        match = re.match(r'^\s*Evidence:\s*(.*)$', line)
        if match:
            evidence = match.group(1).strip()
    if not (evidence.startswith('/') or re.match(r'^https?://[^\s]+$', evidence)):
        evidence = ''
    return recommendation, evidence


def option_from_board(card):
    result = []
    for item in card.get('options', []) if isinstance(card, dict) else []:
        if not isinstance(item, dict):
            continue
        value, label = item.get('value'), item.get('label')
        if not isinstance(value, str) or not isinstance(label, str) or value == 'reconcile':
            continue
        result.append({'value': value, 'label': label, 'hint': item.get('hint', '')})
    return result


class Watch:
    def __init__(self, replay=None, token=None):
        self.home = Path(os.environ.get('FM_HOME', ROOT.parent)).resolve()
        self.root = Path(os.environ.get('FM_STATE_OVERRIDE', self.home / 'state')) / STATE_KEY
        if self.root.is_symlink():
            raise SlackError('unsafe_state_path')
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / 'state.json'
        self.lock_path = self.root / 'lock'
        if self.path.is_symlink() or self.lock_path.is_symlink():
            raise SlackError('unsafe_state_path')
        self.lock = open(self.lock_path, 'a')
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        self.replay = replay
        self.state = self.load_state()
        if replay and isinstance(replay.transcript.get('seed_state'), dict):
            seed = replay.transcript['seed_state']
            for occurrence, record in seed.get('threads', {}).items():
                self.state['threads'].setdefault(occurrence, record)
            seeded_seen = seed.get('seen', {})
            if isinstance(seeded_seen, list):
                seeded_seen = {event: {} for event in seeded_seen}
            for event, seen in seeded_seen.items():
                self.state['seen'].setdefault(event, seen)
        self.token = token or ''
        self.api = replay or Slack(self.token)
        if not replay and self.state.get('scopes'):
            self.api.scopes = set(self.state['scopes'])
        self.authors = set(a for a in re.split(r'[\s,]+', env_value('FM_SLACK_ALLOWED_AUTHORS').strip()) if a)
        self.cap = answer_cap()
        self.changed = False
        self.output = []
        self.detail = ''
        self.noticed_threads = set()
        self.notices_held = False

    def dm_user(self):
        return env_value('FM_SLACK_DM_USER').strip()

    def verify_target(self):
        if self.state.get('user') and self.state['user'] != self.dm_user():
            raise SlackError('dm_user_changed')

    def load_state(self):
        if self.path.exists():
            state = json.loads(self.path.read_text())
            if state.get('schema') != 'fm-slack-watch.v1':
                raise SlackError('invalid_state_schema')
            return state
        state = {'schema': 'fm-slack-watch.v1', 'threads': {}, 'seen': {},
                 'pending': [], 'failure': ''}
        if self.replay and isinstance(self.replay.transcript.get('seed_state'), dict):
            seed = self.replay.transcript['seed_state']
            state['threads'] = seed.get('threads', {})
            state['seen'] = seed.get('seen', {})
            state['pending'] = seed.get('pending', [])
            if isinstance(state['seen'], list):
                state['seen'] = {event: {} for event in state['seen']}
        return state

    def commit(self):
        save(self.path, self.state)
        self.changed = True

    def say(self, line):
        line = flat(line)
        if line and (not self.output or self.output[-1] != line):
            self.output.append(line)

    def has_room(self, line):
        if not self.output:
            return True
        return len('; '.join(self.output + [flat(line)])) <= WAKE_LIMIT - QUEUE_RESERVE

    def queued(self):
        return sum(1 for pending in self.state['pending'] if pending.get('kind') == 'notice')

    def bound(self):
        result = run('fm-captain-hold.sh', 'binding', SOURCE)
        if result.returncode:
            return None
        return result.stdout.strip()

    def probe(self, key):
        result = run('fm-captain-hold.sh', 'open', key, '--identity')
        if result.returncode not in (0, 1, 2):
            raise SlackError('open_probe_failed')
        return result.returncode, result.stdout.strip() or 'unknown'

    def hold(self, record):
        """live, replaced, closed, or unknown for the call a thread mirrors."""
        rc, identity = self.probe(record['key'])
        if rc == 1:
            return 'closed'
        if rc == 0:
            return 'live' if identity == record['identity'] else 'replaced'
        return 'live' if record['identity'] == 'uncertain' else 'unknown'

    def backlog(self):
        result = run('fm-fleet-snapshot.sh', '--contribution-input')
        if result.returncode:
            raise SlackError('backlog_unavailable')
        snapshot = json.loads(result.stdout)
        if not snapshot.get('backlog', {}).get('present'):
            return []
        return snapshot['backlog'].get('records', [])

    def board(self):
        path = self.home / '.lavish/bearings-board.html'
        if not path.is_file() or path.is_symlink():
            return None, {}
        match = re.search(r'<script id="bearings-data" type="application/json">\s*(.*?)\s*</script>',
                          path.read_text(), re.S)
        if not match:
            return None, {}
        try:
            data = json.loads(match.group(1))
        except ValueError:
            return None, {}
        if not isinstance(data, dict):
            return None, {}
        return data.get('generated'), {card.get('key'): card for card in data.get('captains_call', [])
                                       if isinstance(card, dict) and card.get('key')}

    def scope_state(self):
        scopes = set(getattr(self.api, 'scopes', set()))
        missing = {'reactions:read', 'users:read'} - scopes
        return not missing, missing

    def scope_notice(self):
        usable, missing = self.scope_state()
        flag = '' if usable else ', '.join(sorted(missing))
        if flag != self.state.get('scope_notice', ''):
            if flag:
                self.say('slack: missing reaction scope: ' + flag)
            self.state['scope_notice'] = flag
            self.commit()

    def card_payload(self, row, card, text_only=False):
        lines = row.get('body_lines', []) if isinstance(row.get('body_lines'), list) else []
        options = [] if text_only else (option_from_board(card) or parse_options(lines))
        recommendation, evidence = parse_fields(lines)
        if isinstance(card, dict):
            recommendation = card.get('recommend_value') or recommendation
            evidence = card.get('pr_url') or card.get('report_path') or evidence
        if not (isinstance(evidence, str) and (evidence.startswith('/')
                or re.match(r'^https?://[^\s]+$', evidence))):
            evidence = ''
        detail = [line for line in lines
                  if not re.match(r'^\s*(Recommendation:|Evidence:)', line) and not OPTION_LINE.match(line)]
        usable, missing = self.scope_state()
        text = ['Task: ' + row['id'], 'Decision: ' + (row.get('title') or row['id'])]
        if row.get('hold_reason'):
            text.append(row['hold_reason'])
        text.extend(detail)
        text.append('')
        text.append('Recommendation: ' + (recommendation or 'none recorded'))
        text.append('Evidence: ' + (evidence or 'none recorded'))
        if options:
            text.append('Options:')
            for i, option in enumerate(options, 1):
                hint = ' - ' + option['hint'] if option.get('hint') else ''
                text.append(f"{i}. {option['label']} ({option['value']}){hint}")
        text.append('Affordance: ' + ('text' if not options else 'reaction' if usable else 'single-character'))
        if usable and options:
            text.append('React with ' + '/'.join(REACTIONS[:len(options)])
                        + ' or reply in this thread with the option number.')
        elif options:
            text.append('Reply in this thread with the option number.')
        else:
            text.append('Reply in this thread with your answer.')
        text.append('Messages typed in the main DM window are not read.')
        text.append('If you both tap and type: a disagreement surfaces to the captain and neither signal is recorded as the answer.')
        if not usable:
            text.append('Missing reaction scope: ' + ', '.join(sorted(missing)) + '.')
        return '\n'.join(text), options, usable

    def messages(self, thread):
        channel = self.state.get('channel')
        if not channel:
            raise SlackError('dm_not_prepared')
        return list(self.api.pages('conversations.replies', 'messages', channel=channel, ts=thread,
                                   include_all_metadata=True))

    def recent(self, thread):
        if thread:
            return self.messages(thread)
        channel = self.state.get('channel')
        if not channel:
            raise SlackError('dm_not_prepared')
        return self.api.call('conversations.history', channel=channel, limit=100,
                             include_all_metadata=True).get('messages', [])

    def post(self, event, text, thread=None, tail='\nFull text remains in the local backlog.'):
        channel = self.state.get('channel')
        if not channel:
            raise SlackError('dm_not_prepared')
        marker = hashlib.sha256(event.encode()).hexdigest()
        for message in self.recent(thread):
            if message.get('metadata', {}).get('event_payload', {}).get('id') == marker:
                return message['ts']
        if len(text.encode()) > 39000:
            text = text[:38000] + tail
        args = {'channel': channel, 'text': text,
                'client_msg_id': str(uuid.uuid5(uuid.NAMESPACE_URL, event)),
                'metadata': {'event_type': STATE_KEY, 'event_payload': {'id': marker}},
                'unfurl_links': False, 'unfurl_media': False}
        if thread:
            args['thread_ts'] = thread
        return self.api.call('chat.postMessage', **args)['ts']

    def prepare(self):
        if not self.bound():
            raise SlackError('source_not_bound')
        result = self.api.call('auth.test')
        channel = self.api.call('conversations.open', users=self.dm_user(), return_im=True).get('channel', {})
        if not channel.get('id') or not channel.get('is_im'):
            raise SlackError('target_is_not_a_DM')
        self.api.call('conversations.history', channel=channel['id'], limit=1)
        self.state.update(team=result.get('team_id'), user=self.dm_user(),
                          channel=channel['id'], scopes=sorted(getattr(self.api, 'scopes', set())))
        self.commit()

    def allowed(self, message):
        return (message.get('user') in self.authors
                and not any(message.get(k) for k in ('bot_id', 'app_id', 'bot_profile')))

    def stage(self, pending):
        for item in self.state['pending']:
            if item['event'] == pending['event']:
                return item
        self.state['pending'].append(pending)
        self.commit()
        return pending

    def mark_seen(self, event, key):
        self.state['seen'][event] = {'key': key}

    def publish(self, pending):
        if pending.get('kind') == 'answer' and pending.get('author') not in self.authors:
            self.state['pending'] = [p for p in self.state['pending'] if p is not pending]
            self.commit()
            return
        if pending.get('kind') == 'notice':
            if self.notices_held or not self.has_room(pending['line']):
                self.notices_held = True
                return
            self.post('ack:' + pending['event'], pending['text'], pending['thread'])
            self.say(pending['line'])
            self.mark_seen(pending['event'], pending['key'])
            self.consume(pending.get('contributing', []), pending['key'])
            self.state['pending'] = [p for p in self.state['pending'] if p is not pending]
            self.commit()
            return
        if pending['stage'] == 'intake':
            standing = self.hold(pending)
            if standing == 'unknown':
                return
            if standing == 'replaced':
                self.say('check: slack %s - reply for a replaced hold: %s' % (pending['thread'], pending['key']))
                pending['accepted'] = False
            else:
                row = '\t'.join([pending['key'], flat(pending['answer']), flat(pending['label']),
                                 pending.get('mode', 'done')]) + '\n'
                result = run('fm-captain-hold.sh', 'answers', '--any-origin', '--source', SOURCE, text=row)
                lines = result.stdout.splitlines()
                if not any(line.startswith('answers: ') for line in lines):
                    self.detail = flat(result.stderr).strip()[:200]
                    raise SlackError('answer_intake_failed')
                for line in lines:
                    if not line.startswith('answers: '):
                        self.say(line)
                if result.stderr.strip():
                    self.say('check: slack %s - intake note: %s' % (pending['thread'], flat(result.stderr).strip()[:200]))
                pending['accepted'] = any(line.startswith('closed: ') for line in lines)
                if not pending['accepted'] and not any(line.startswith(('skipped: ', 'refused: ')) for line in lines):
                    self.say('check: slack %s - answer not applied: %s' % (pending['thread'], pending['key']))
            if env_value('FM_SLACK_FAULT') == 'after-delivery':
                raise RuntimeError('FM_SLACK_FAULT=after-delivery')
            pending['stage'] = 'ack'
            self.commit()
            if env_value('FM_SLACK_FAULT') == 'after-answer':
                raise RuntimeError('FM_SLACK_FAULT=after-answer')
        if pending['stage'] == 'ack':
            text = ('Answer recorded.' if pending['accepted'] else
                    'Answer not applied: no matching open held decision, changed call, or reserved value. Firstmate has been notified.')
            self.post('ack:' + pending['event'], text, pending['thread'])
            pending['stage'] = 'cursor'
            self.commit()
        if pending['stage'] == 'cursor':
            self.mark_seen(pending['event'], pending['key'])
            self.state['pending'] = [p for p in self.state['pending'] if p is not pending]
            self.commit()

    def resume(self):
        remaining = self.cap
        for pending in list(self.state['pending']):
            if remaining <= 0:
                return
            self.publish(pending)
            if pending.get('kind') != 'notice':
                remaining -= 1
        return remaining

    def mirror(self):
        if not self.bound():
            return
        rows = self.backlog()
        candidates = [r for r in rows if r.get('id') and r.get('hold_kind') == 'captain'
                      and r.get('state') != 'done']
        generated, cards = self.board()
        for row in candidates:
            key = row['id']
            rc, identity = self.probe(key)
            if rc == 1:
                continue
            if rc == 2:
                identity = 'uncertain'
            occurrence = key + ':' + identity
            if occurrence in self.state['threads']:
                continue
            # Uncertain open-state is deliberately shown rather than hidden.
            if not self.state.get('channel'):
                self.prepare()
            card = cards.get(key, {})
            text_only = bool(card) and not fresh(generated, identity)
            if text_only:
                card = {}
            text, options, usable = self.card_payload(row, card, text_only)
            self.scope_notice()
            # Re-check immediately before the network post.
            again, current = self.probe(key)
            if again == 1 or (current if again == 0 else 'uncertain') != identity:
                continue
            ts = self.post('card:' + occurrence, text, tail=CARD_TAIL)
            record = {'key': key, 'identity': identity, 'ts': ts, 'options': options,
                      'mode': card.get('close') if card.get('close') in ('done', 'release') else 'done',
                      'reactions': usable, 'retired': False}
            self.state['threads'][occurrence] = record
            self.commit()
            if usable and 'reactions:write' in getattr(self.api, 'scopes', set()) and options:
                for name in REACTIONS[:len(options)]:
                    try:
                        self.api.call('reactions.add', channel=self.state['channel'], timestamp=ts, name=name)
                    except SlackError:
                        # A missing or rejected seed reaction must not hide the card;
                        # the captain can still add the reaction or type the number.
                        break

    def tracked(self):
        return [(occurrence, record) for occurrence, record in self.state['threads'].items()
                if not record.get('retired')]

    def resolve(self):
        rows = None
        for occurrence, record in self.tracked():
            if record['ts'] in self.noticed_threads:
                continue
            standing = self.hold(record)
            if standing in ('live', 'unknown'):
                continue
            if standing == 'replaced':
                self.post('superseded:' + occurrence,
                          'Superseded: ' + record['key'] + ' was held again. Answer in its newer thread.',
                          record['ts'])
            else:
                if rows is None:
                    rows = self.backlog()
                row = next((r for r in rows if r.get('id') == record['key']), {})
                body = row.get('body_lines', []) if isinstance(row.get('body_lines'), list) else []
                self.post('resolved:' + occurrence,
                          'Resolved: ' + record['key'] + '\n' + '\n'.join(body), record['ts'])
            record['retired'] = True
            self.commit()

    def reactions_for(self, ts):
        data = self.api.call('reactions.get', channel=self.state['channel'], timestamp=ts)
        return data.get('message', {}).get('reactions', [])

    def reaction_choices(self, record):
        """One signal per option reaction tapped by an allowlisted human."""
        choices = []
        reactions = self.reactions_for(record['ts'])
        for i, option in enumerate(record.get('options', [])):
            if i >= len(REACTIONS):
                break
            name = REACTIONS[i]
            users = sorted({u for r in reactions if r.get('name') == name
                            for u in r.get('users', []) if u in self.authors})
            if not users:
                continue
            # A bot/app reactor is not the captain even with an allowlisted id.
            # An unreadable author is never guessed to be the captain.
            try:
                user = self.api.call('users.info', user=users[0]).get('user', {})
            except SlackError:
                continue
            if user.get('is_bot') or user.get('is_app_user'):
                continue
            event = '/'.join([self.state.get('team', ''), self.state.get('channel', ''),
                              record['ts'], name, 'reaction'])
            choices.append({'event': event, 'name': name, 'answer': option['value'],
                            'label': option['label'], 'user': users[0]})
        return choices

    def typed_candidates(self, record):
        candidates = []
        for message in self.messages(record['ts']):
            if message.get('ts') == record['ts'] or not self.allowed(message):
                continue
            if message.get('thread_ts') not in (None, record['ts']):
                continue
            event = '/'.join([self.state.get('team', ''), self.state.get('channel', ''),
                              record['ts'], message.get('ts', '')])
            text = message.get('text', '')
            if not isinstance(text, str) or not text.strip():
                continue
            text = typed_text(text)
            answer = label = text
            if text.isdecimal() and 1 <= int(text) <= len(record.get('options', [])):
                option = record['options'][int(text) - 1]
                answer, label = option['value'], option['label']
            candidates.append({'event': event, 'answer': answer, 'label': label,
                               'user': message.get('user'), 'ts': message.get('ts', '')})
        return candidates

    def consume(self, events, key):
        for event in events:
            self.mark_seen(event, key)

    def notice(self, event, key, thread, text, line, contributing=()):
        self.noticed_threads.add(thread)
        pending = self.stage({'event': event, 'key': key, 'thread': thread, 'text': text,
                              'line': line, 'kind': 'notice', 'stage': 'notice',
                              'contributing': list(contributing)})
        self.publish(pending)

    def poll(self):
        if not self.bound():
            return
        remaining = self.resume()
        if remaining is None:
            remaining = 0
        if remaining <= 0:
            self.resolve()
            return
        if self.state['threads'] and not self.state.get('channel'):
            self.prepare()
        if not (self.replay and self.replay.transcript.get('skip_mirror')):
            self.mirror()
        if self.state['threads']:
            self.scope_notice()
        for occurrence, record in self.tracked():
            if remaining <= 0:
                break
            key = record['key']
            new_replies = [r for r in self.typed_candidates(record) if r['event'] not in self.state['seen']]
            taps = self.reaction_choices(record) if record.get('reactions') and record.get('options') else []
            signature = ','.join(tap['name'] for tap in taps)
            if record.get('blocked') is not None:
                if new_replies or signature != record['blocked']:
                    record['blocked'] = None
                    self.commit()
                else:
                    taps = []
            taps = [tap for tap in taps if tap['event'] not in self.state['seen']]
            if not new_replies and not taps:
                continue
            standing = self.hold(record)
            if standing == 'unknown':
                continue
            if standing != 'live':
                for reply in new_replies:
                    if remaining <= 0:
                        break
                    self.notice(reply['event'], key, record['ts'],
                                'No open decision matches this reply. Firstmate has been notified.',
                                'check: slack %s - unmatched reply %s' % (record['ts'], reply['ts']))
                    remaining -= 1
                continue
            typed = {r['answer']: r['label'] for r in new_replies}
            tapped = {tap['answer']: tap['label'] for tap in taps}
            if len(typed) > 1 or len(tapped) > 1 or (typed and tapped and typed.keys() != tapped.keys()):
                record['conflicts'] = record.get('conflicts', 0) + 1
                record['blocked'] = signature
                labels = ' vs '.join(sorted(set(typed.values()) | set(tapped.values())))
                event = new_replies[0]['event'] if new_replies else self.event(
                    record, 'conflict', str(record['conflicts']))
                if len(tapped) > 1:
                    remedy = 'Remove all but one reaction.'
                elif tapped:
                    remedy = 'Remove the :%s: reaction, or type %d.' % (
                        taps[0]['name'], REACTIONS.index(taps[0]['name']) + 1)
                else:
                    remedy = 'Please reply once.'
                self.notice(event, key, record['ts'],
                            'Conflicting signals: ' + labels + '. No answer was recorded. ' + remedy,
                            'check: slack %s - conflicting signals: %s' % (record['ts'], labels),
                            [r['event'] for r in new_replies])
                remaining -= 1
                continue
            if new_replies:
                chosen = new_replies[0]
            else:
                chosen = taps[0]
            answer, label, author = chosen['answer'], chosen['label'], chosen['user']
            self.consume([c['event'] for c in new_replies + taps if c is not chosen], key)
            pending = self.stage({'event': chosen['event'], 'occurrence': occurrence,
                                  'identity': record['identity'], 'thread': record['ts'],
                                  'key': key, 'mode': record.get('mode', 'done'),
                                  'answer': answer, 'label': label, 'author': author,
                                  'kind': 'answer', 'stage': 'intake'})
            self.publish(pending)
            remaining -= 1
        self.resolve()

    def event(self, record, *parts):
        return '/'.join([self.state.get('team', ''), self.state.get('channel', ''), record['ts'], *parts])

    def report_failure(self, error):
        name = str(error) if isinstance(error, SlackError) else 'local_state_or_response_error'
        if self.state.get('failure') != name:
            self.state['failure'] = name
            self.commit()
            self.say('slack: transport failure: ' + name + (': ' + self.detail if self.detail else ''))
        return 1

    def clear_failure(self):
        if self.state.get('failure'):
            self.state['failure'] = ''
            self.commit()


def parse_command(argv):
    if not argv:
        return None, None
    command = argv[0]
    replay = None
    rest = []
    index = 1
    while index < len(argv):
        if argv[index] == '--replay':
            if index + 1 >= len(argv):
                raise SlackError('missing_replay_path')
            replay = argv[index + 1]
            index += 2
            continue
        if argv[index] in ('-h', '--help'):
            print(help_text(command))
            raise SystemExit(0)
        rest.append(argv[index])
        index += 1
    if rest:
        raise SlackError('unexpected_arguments')
    return command, replay


def help_text(command):
    return {
        'mirror': 'Usage: fm-slack-mirror.sh [--replay transcript.json]\nMirror open captain calls into owner DM threads.',
        'poll': 'Usage: fm-slack-poll.sh [--replay transcript.json]\nDeliver authorized Slack signals through the keyed-answer intake.',
        'check': 'Usage: fm-slack-check.sh [arm|check|disarm] [--replay transcript.json]',
    }.get(command, 'Usage: fm-slack-{mirror,poll,check}.sh [--replay transcript.json]')


def state_home():
    return Path(os.environ.get('FM_STATE_OVERRIDE', Path(os.environ['FM_HOME']) / 'state'))


def emit(watch, command):
    queued = watch.queued() if command in ('poll', 'check') else 0
    if command == 'check':
        if watch.output:
            print(wake_line(watch.output, queued))
        return
    lines = list(watch.output)
    if lines and queued:
        lines[-1] += '; +%d queued' % queued
    for line in lines:
        print(line)


def main(argv):
    os.umask(0o077)
    action = env_value('FM_SLACK_CHECK_ACTION') if argv and argv[0] == 'check' else ''
    refusals = sys.stderr if action == 'arm' else sys.stdout
    if not argv:
        print('error: missing command')
        return 2
    try:
        command, replay_path = parse_command(argv)
    except SlackError as error:
        print('error: slack ' + str(error), file=refusals)
        return 2
    if command not in ('mirror', 'poll', 'check'):
        print('error: unknown command; use --help')
        return 2
    if action == 'disarm':
        return disarm()
    state, reason = mode()
    if state != 'on':
        if action == 'arm':
            print('slack: refused: ' + reason, file=sys.stderr)
            return 1
        if state == 'refused' and command != 'check':
            print('slack: refused: ' + reason)
        return 0
    watch = None
    code = 0
    try:
        replay = Replay(replay_path, state_home() / STATE_KEY,
                        token_present=bool(env_value('SLACK_BOT_TOKEN'))) if replay_path else None
        watch = Watch(replay=replay, token=env_value('SLACK_BOT_TOKEN').strip())
        watch.verify_target()
        if command == 'mirror':
            if not watch.bound():
                return 0
            watch.mirror()
            watch.clear_failure()
        elif command == 'poll':
            watch.poll()
            watch.clear_failure()
        else:
            code = check(watch, action)
        emit(watch, command)
        return code
    except (SlackError, OSError, ValueError, KeyError, TypeError) as error:
        # Report once per failure episode. Pending rows and state remain durable;
        # lines said before the failure belong to state already committed.
        name = str(error) if isinstance(error, SlackError) else 'local_state_or_response_error'
        if action == 'arm':
            print('slack: refused: ' + name, file=sys.stderr)
        elif watch is not None:
            watch.report_failure(error)
            emit(watch, command)
        else:
            print('slack: transport failure: ' + name)
        return 1
    except RuntimeError as error:
        if str(error).startswith('FM_SLACK_FAULT='):
            return 75
        print('slack: refused: local_runtime_error' if action == 'arm' else 'slack: local_runtime_error',
              file=refusals)
        return 1
    finally:
        if watch is not None:
            try:
                watch.lock.close()
            except OSError:
                pass


def check(watch, action):
    state_dir = state_home()
    if action == 'arm':
        try:
            watch.prepare()
        except SlackError as error:
            print('slack: refused: ' + str(error), file=sys.stderr)
            return 1
        return arm(state_dir)
    if not (state_dir / (CHECK_ID + '.check.sh')).is_file() or not (state_dir / (CHECK_ID + '.check-trust')).is_file():
        return 0
    try:
        watch.poll()
        watch.clear_failure()
    except SlackError as error:
        watch.report_failure(error)
    return 0


def shim_content(home, state_dir, script_dir):
    return ('#!/usr/bin/env bash\n'
            'export FM_HOME=%s\n'
            'export FM_STATE_OVERRIDE=%s\n'
            'exec bash %s check\n') % (
                shlex.quote(str(home)), shlex.quote(str(state_dir)),
                shlex.quote(str(Path(script_dir) / 'fm-slack-check.sh')))


def arm(state_dir):
    state_dir.mkdir(parents=True, exist_ok=True)
    if state_dir.is_symlink():
        print('slack: refused: unsafe_state_path', file=sys.stderr)
        return 1
    shim = state_dir / (CHECK_ID + '.check.sh')
    trust = state_dir / (CHECK_ID + '.check-trust')
    if shim.is_symlink() or trust.is_symlink():
        print('slack: refused: unsafe_state_path', file=sys.stderr)
        return 1
    # Validate the shim path before touching either artifact.
    if shim.exists() and not shim.is_file():
        print('slack: refused: unsafe_check_shim', file=sys.stderr)
        return 1
    shim.write_text(shim_content(os.environ['FM_HOME'], state_dir, ROOT))
    shim.chmod(0o700)
    result = run('fm-check-register.sh', CHECK_ID)
    if result.returncode:
        shim.unlink(missing_ok=True)
        trust.unlink(missing_ok=True)
        print('slack: refused: check_registration_failed', file=sys.stderr)
        return 1
    print('armed: state/%s.check.sh' % CHECK_ID)
    return 0


def disarm():
    result = run('fm-check-unregister.sh', CHECK_ID)
    if result.returncode:
        print('slack: refused: check_unregistration_failed')
        return 1
    print('disarmed: state/%s.check.sh' % CHECK_ID)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main(sys.argv[1:]))
    except SlackError as error:
        print('error: slack ' + str(error))
        raise SystemExit(1)
