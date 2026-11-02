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
DM_CHANNEL = re.compile(r'D[A-Z0-9]{8,}')
# A failure of one thread's own read, journaled-row post, or resolution post must not stop the other
# threads' replies from being read.
THREAD_ERRORS = ('api_error', 'channel_not_found')
OPTION_LINE = re.compile(r'^\s*Option\s*([1-9][0-9]*)\s*[.):]\s*(.*)$')
FIELD_LINE = re.compile(r'^\s*(Decision sought|Brief description of issue|Brief|Recommendation|Alternatives|Evidence):\s*(.*)$')
WAKE_LIMIT = 480
QUEUE_RESERVE = 16
LABEL_LIMIT = 168  # Leave room for two candidates, a long thread ts, the longest remedy, and the queue marker.
CARD_LIMIT = 38000
SLACK_LINK = re.compile(r'<((?:https?://|mailto:)[^<>|\s]+)(?:\|([^<>]*))?>')
PARTIAL_ENTITY = re.compile(r'&[a-z]*$')


def fault(point):
    """Test-only crash injection, read from the process environment and never from .env."""
    if env_value('FM_SLACK_FAULT') == point:
        raise RuntimeError('FM_SLACK_FAULT=' + point)


def run(script, *args, text=None):
    # No local child needs a Slack credential: drop the token and the signing secret.
    env = {key: value for key, value in os.environ.items() if not key.startswith('SLACK_')}
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


def short(value, limit=LABEL_LIMIT):
    return value if len(value) <= limit else value[:limit - 3] + '...'


def slack_escape(value):
    """Slack reads &, <, and > as markup; escape them so a posted value shows literally."""
    return str(value).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def clip(value, limit):
    """Cut Slack-escaped text to limit characters without splitting an entity."""
    return PARTIAL_ENTITY.sub('', value[:limit])


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


def queue_tail(queued):
    return '; +%d queued' % queued if queued else ''


def wake_line(lines, queued=0):
    line = '; '.join(lines)
    tail = queue_tail(queued)
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


def evidence_pointer(value):
    return isinstance(value, str) and bool(value.startswith('/') or re.match(r'^https?://[^\s]+$', value))


def parse_fields(lines, remainder=None, multiline=False, loose=None, removed=None):
    fields, current = {}, None
    for line in lines:
        match = FIELD_LINE.match(line)
        if match and match.group(1) == 'Evidence':
            value = match.group(2).strip()
            if (value and value.lower() != 'none recorded'
                    and (not evidence_pointer(value) or (multiline and fields.get('Evidence')))):
                match = None
                current = None
        if match:
            current = match.group(1)
            if current == 'Brief description of issue':
                current = 'Brief'
            value = match.group(2).strip()
            if multiline:
                value = '\n'.join(part for part in (fields.get(current), value)
                                  if part and part.lower() != 'none recorded')
            fields[current] = value
            if remainder is not None and current not in ('Recommendation', 'Evidence'):
                remainder.append(line)
            elif removed is not None and current in ('Recommendation', 'Evidence'):
                removed.append((current, line))
            if current == 'Evidence':
                current = None
        elif current and multiline and not OPTION_LINE.match(line):
            fields[current] += '\n' + line.strip()
            if remainder is not None and current not in ('Recommendation', 'Evidence'):
                remainder.append(line)
            elif removed is not None and current in ('Recommendation', 'Evidence'):
                removed.append((current, line))
        else:
            current = None
            for kept in (remainder, loose):
                if kept is not None:
                    kept.append(line)
    return {key: value.strip() for key, value in fields.items()
            if value.strip() and value.strip().lower() != 'none recorded'}


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
        # Wake lines are journaled with the state change that earned them and cleared only
        # after they are printed, so a run that dies in between prints them next time.
        self.output = list(self.state['outbox'])
        self.detail = ''
        self.noticed_threads = set()
        self.read_threads = set()
        self.advanced = 0
        self.notices_held = False
        self.staging_only = False
        self.dm_proven = False

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
            state.setdefault('outbox', [])
            return state
        state = {'schema': 'fm-slack-watch.v1', 'threads': {}, 'seen': {},
                 'pending': [], 'failure': '', 'outbox': []}
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
            self.state['outbox'] = list(self.output)

    def printed(self, count):
        """Drop the first count wake lines from the journal once they have been printed."""
        self.output = self.output[count:]
        if self.state['outbox'] != self.output:
            self.state['outbox'] = list(self.output)
            self.commit()

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
        # An unreadable state proves nothing, even for a thread mirrored while it was unreadable.
        return 'unknown'

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
        missing = {'reactions:read', 'users:read'} - set(self.state.get('scopes') or [])
        return not missing, missing

    def scope_notice(self):
        usable, missing = self.scope_state()
        flag = '' if usable else ', '.join(sorted(missing))
        if flag != self.state.get('scope_notice', ''):
            if flag:
                self.say('slack: missing reaction scope: ' + flag)
            self.state['scope_notice'] = flag
            self.commit()

    def card_payload(self, row, card, text_only=False, reactions=True):
        lines = row.get('body_lines', []) if isinstance(row.get('body_lines'), list) else []
        options = [] if text_only else (option_from_board(card) or parse_options(lines))
        body = parse_fields(lines)
        reason_lines = (row.get('hold_reason') or '').splitlines()
        loose = []
        reason = parse_fields(reason_lines, multiline=True, loose=loose)
        parts = dict(body)
        if card.get('recommend_value'):
            parts['Recommendation'] = card['recommend_value']
        parts.update(reason)
        evidence = next((value for value in (reason.get('Evidence'), card.get('pr_url'),
                                            card.get('report_path'), body.get('Evidence'))
                         if evidence_pointer(value)), '')
        usable, missing = self.scope_state()
        usable = usable and reactions
        fields = [('Task: ', row['id'])]
        structured = bool(parts.get('Decision sought'))
        plain = loose if structured else []
        if structured:
            for key, label in (('Decision sought', 'Decision sought: '),
                               ('Brief', 'Brief description of issue: '),
                               ('Recommendation', 'Recommendation and key reasons: '),
                               ('Alternatives', 'Alternatives considered: ')):
                if parts.get(key):
                    fields.append((label, parts[key]))
        else:
            fields.append(('Decision: ', card.get('title') or row.get('title') or row['id']))
            if card.get('about'):
                fields.append(('About: ', card['about']))
            question = card.get('decide') or row.get('hold_reason') or ''
            remainder, removed = [], []
            asked = parse_fields(question.splitlines(), remainder, multiline=True, removed=removed)
            question = '\n'.join(remainder).strip()
            shown = {'Recommendation': parts.get('Recommendation'), 'Evidence': evidence}
            plain = [line for label, line in removed if asked.get(label) and asked[label] != shown[label]]
            if card.get('decide'):
                plain += [line for line in loose if FIELD_LINE.match(line)]
            if question:
                fields.append(('Question: ', question))
            if parts.get('Recommendation'):
                fields.append(('Recommendation: ', parts['Recommendation']))
        if evidence:
            fields.append(('Evidence: ', evidence))
        if options:
            fields.append(('Options:', ''))
            for i, option in enumerate(options, 1):
                hint = ' - ' + option['hint'] if option.get('hint') else ''
                fields.append((f'{i}. ', f"{option['label']} ({option['value']}){hint}"))
        fields.extend(('', line) for line in plain if line.strip())
        fields = [(prefix, slack_escape(value)) for prefix, value in fields
                  if str(value).strip().lower() != 'none recorded']
        if usable and options:
            footer = ['Tap a number reaction or type the option number in this thread.']
        elif options:
            footer = ['Type the option number in this thread.']
        else:
            footer = ['Type your answer in this thread.']
        if options:
            footer.append('If you both tap and type: disagreement records neither answer.')
        if missing:
            footer.append('Missing reaction scope: ' + ', '.join(sorted(missing)) + '.')
        text = '\n'.join([prefix + value for prefix, value in fields] + footer)
        if len(text) <= CARD_LIMIT:
            return text, options, usable
        # Only an oversized card is budgeted: short values stay whole and the long
        # ones share what is left, so every field and the precedence rule survive.
        budget = CARD_LIMIT - len('\n'.join([prefix for prefix, _ in fields] + footer))
        lengths = sorted(len(value) for _, value in fields)
        limit = budget
        for n, length in enumerate(lengths):
            share = budget // (len(lengths) - n)
            if length > share:
                limit = share
                break
            budget -= length
        text = [prefix + (value if len(value) <= limit else clip(value, limit - 3) + '...')
                for prefix, value in fields]
        return '\n'.join(text + footer), options, usable

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

    def owner_channel(self):
        """The one conversation this plane may write to: the owner's DM, and nothing else."""
        channel = self.state.get('channel')
        if not channel:
            raise SlackError('dm_not_prepared')
        if not DM_CHANNEL.fullmatch(channel) or self.state.get('user') != self.dm_user():
            raise SlackError('target_is_not_a_DM')
        if not self.dm_proven:
            # The stored id must be the DM Slack itself opens for the configured owner;
            # a different DM-shaped id, or an answer that cannot be read, writes nothing.
            opened = self.api.call('conversations.open', users=self.dm_user(), return_im=True).get('channel', {})
            if opened.get('id') != channel:
                raise SlackError('stored_channel_not_owner_dm')
            self.dm_proven = True
        return channel

    def post(self, event, text, thread=None):
        channel = self.owner_channel()
        marker = hashlib.sha256(event.encode()).hexdigest()
        for message in self.recent(thread):
            if message.get('metadata', {}).get('event_payload', {}).get('id') == marker:
                return message['ts']
        if len(text) > 39000:
            text = clip(text, 38000) + '\nFull text remains in the local backlog.'
        args = {'channel': channel, 'text': text,
                'client_msg_id': str(uuid.uuid5(uuid.NAMESPACE_URL, event)),
                'metadata': {'event_type': STATE_KEY, 'event_payload': {'id': marker}},
                'unfurl_links': False, 'unfurl_media': False}
        if thread:
            args['thread_ts'] = thread
        return self.api.call('chat.postMessage', **args)['ts']

    def retarget(self):
        """Re-point the plane at a changed owner DM; only an explicit retarget may do this."""
        if not self.state.get('user') or self.state['user'] == self.dm_user():
            return False
        if self.state['pending']:
            # Pending rows belong to threads in the old DM; they must finish there first.
            raise SlackError('dm_user_changed_with_pending_work')
        # An empty journal does not prove the old threads were read: read each tracked one
        # now and stage what it holds by the normal rules, without publishing into the old DM.
        # A failed or cut-off read propagates, so nothing is cleared on an incomplete read.
        self.staging_only = True
        try:
            for occurrence, record in self.tracked():
                self.read_thread(occurrence, record, 10 ** 6)
        finally:
            self.staging_only = False
        if self.state['pending']:
            raise SlackError('dm_user_changed_with_pending_work')
        # The old DM's threads stop being tracked and nothing more is posted there.
        self.state.update(user='', channel='', team='', scopes=[], threads={})
        self.commit()
        return True

    def prepare(self):
        if not self.bound():
            raise SlackError('source_not_bound')
        result = self.api.call('auth.test')
        channel = self.api.call('conversations.open', users=self.dm_user(), return_im=True).get('channel', {})
        if not DM_CHANNEL.fullmatch(channel.get('id') or '') or not channel.get('is_im'):
            raise SlackError('target_is_not_a_DM')
        self.api.call('conversations.history', channel=channel['id'], limit=1)
        self.state.update(team=result.get('team_id'), user=self.dm_user(),
                          channel=channel['id'], scopes=sorted(getattr(self.api, 'scopes', set())))
        self.commit()
        self.dm_proven = True

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
        if self.staging_only:
            return
        if pending.get('kind') == 'answer' and pending.get('author') not in self.authors:
            self.state['pending'] = [p for p in self.state['pending'] if p is not pending]
            self.commit()
            return
        if pending.get('kind') == 'notice':
            if self.notices_held or not self.has_room(pending['line']):
                self.notices_held = True
                return
            self.post('ack:' + pending['event'], pending['text'], pending['thread'])
            fault('after-notice-post')
            self.say(pending['line'])
            self.mark_seen(pending['event'], pending['key'])
            self.consume(pending.get('contributing', []), pending['key'])
            self.state['pending'] = [p for p in self.state['pending'] if p is not pending]
            self.commit()
            return
        if pending['stage'] == 'intake':
            fault('after-stage')
            # The source must still be bound at the moment of delivery, not only when the poll began.
            if not self.bound():
                return
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
            fault('after-delivery')
            pending['stage'] = 'ack'
            self.advanced += 1
            self.commit()
            fault('after-answer')
        if pending['stage'] == 'ack':
            text = ('Answer recorded.' if pending['accepted'] else
                    'Answer not applied: no matching open held decision, changed call, or reserved value. Firstmate has been notified.')
            self.post('ack:' + pending['event'], text, pending['thread'])
            fault('after-ack')
            pending['stage'] = 'cursor'
            self.commit()
        if pending['stage'] == 'cursor':
            self.mark_seen(pending['event'], pending['key'])
            self.state['pending'] = [p for p in self.state['pending'] if p is not pending]
            self.commit()
            fault('after-cursor')

    def resume(self):
        remaining, deferred = self.cap, None
        for pending in list(self.state['pending']):
            if remaining <= 0:
                break
            advanced = self.advanced
            try:
                self.publish(pending)
            except SlackError as error:
                if str(error) not in THREAD_ERRORS:
                    raise
                deferred = deferred or error
            remaining -= self.advanced - advanced
        return remaining, deferred

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
            record = self.state['threads'].get(occurrence)
            if record and (record.get('retired') or rc != 0):
                continue
            # Uncertain open-state is deliberately shown rather than hidden.
            if not self.state.get('channel'):
                self.prepare()
            card = cards.get(key, {})
            text_only = bool(card) and not fresh(generated, identity)
            if text_only:
                card = {}
            text, options, usable = self.card_payload(
                row, card, text_only, reactions=record.get('reactions', False) if record else True)
            self.scope_notice()
            digest = hashlib.sha256(text.encode()).hexdigest()
            if record and (record.get('options') != options or digest in
                           (record.get('text_digest'), record.get('update_attempt_digest'))):
                continue
            # Re-check immediately before the network write.
            again, current = self.probe(key)
            if again == 1 or (current if again == 0 else 'uncertain') != identity:
                continue
            if record:
                channel = self.owner_channel()
                try:
                    self.api.call('chat.update', channel=channel, ts=record['ts'],
                                  text=text, unfurl_links=False, unfurl_media=False)
                except SlackError as error:
                    if str(error) in ('request_budget_exhausted', 'unreachable'):
                        raise
                    record['update_attempt_digest'] = digest
                    self.commit()
                    self.say('check: slack %s - card update failed: %s' % (record['ts'], error))
                    continue
                record['text_digest'] = digest
                record.pop('update_attempt_digest', None)
                self.commit()
                continue
            ts = self.post('card:' + occurrence, text)
            record = {'key': key, 'identity': identity, 'ts': ts, 'options': options,
                      'mode': card.get('close') if card.get('close') in ('done', 'release') else 'done',
                      'reactions': usable, 'retired': False, 'text_digest': digest}
            self.state['threads'][occurrence] = record
            self.commit()
            if usable and 'reactions:write' in getattr(self.api, 'scopes', set()) and options:
                for name in REACTIONS[:len(options)]:
                    try:
                        self.api.call('reactions.add', channel=self.owner_channel(), timestamp=ts, name=name)
                    except SlackError:
                        # A missing or rejected seed reaction must not hide the card;
                        # the captain can still add the reaction or type the number.
                        break

    def tracked(self):
        return [(occurrence, record) for occurrence, record in self.state['threads'].items()
                if not record.get('retired')]

    def resolve(self):
        deferred = None
        for occurrence, record in self.tracked():
            if record['ts'] in self.noticed_threads or record['ts'] not in self.read_threads:
                continue
            standing = self.hold(record)
            if standing in ('live', 'unknown'):
                continue
            try:
                if standing == 'replaced':
                    self.post('superseded:' + occurrence,
                              'Superseded: ' + slack_escape(record['key']) + ' was held again. Answer in its newer thread.',
                              record['ts'])
                else:
                    self.post('resolved:' + occurrence,
                              'Resolved: ' + slack_escape(record['key'])
                              + '\nThe decision is no longer open. Full resolution remains in the local backlog.',
                              record['ts'])
            except SlackError as error:
                if str(error) not in THREAD_ERRORS:
                    raise
                deferred = deferred or error
                continue
            record['retired'] = True
            self.commit()
        return deferred

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
                if self.staging_only:
                    raise
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
        """Stage and publish one notice; returns whether this call made progress for the per-poll cap."""
        self.noticed_threads.add(thread)
        row = {'event': event, 'key': key, 'thread': thread, 'text': text,
               'line': line, 'kind': 'notice', 'stage': 'notice',
               'contributing': list(contributing)}
        advanced = self.advanced
        pending = self.stage(row)
        self.publish(pending)
        return pending is row or self.advanced > advanced

    def poll(self):
        if not self.bound():
            return
        remaining, deferred = self.resume()
        if remaining <= 0:
            if deferred:
                raise deferred
            return
        if self.state['threads'] and not self.state.get('channel'):
            self.prepare()
        # Mirroring new cards must never keep the replies on existing threads unread:
        # a mirror failure is held back and reported after the replies are handled.
        if not (self.replay and self.replay.transcript.get('skip_mirror')):
            try:
                self.mirror()
            except SlackError as error:
                deferred = deferred or error
        if self.state['threads']:
            self.scope_notice()
        for occurrence, record in self.tracked():
            if remaining <= 0:
                break
            advanced = self.advanced
            try:
                remaining = self.read_thread(occurrence, record, remaining)
            except SlackError as error:
                # One thread's own failure (for example a card the owner deleted) is held
                # back and reported once; every other thread is still read.
                if str(error) not in THREAD_ERRORS:
                    raise
                self.read_threads.discard(record['ts'])
                remaining -= self.advanced - advanced
                deferred = deferred or error
        deferred = self.resolve() or deferred
        if deferred:
            raise deferred

    def read_thread(self, occurrence, record, remaining):
        """Read one tracked thread and stage at most the answers the cap allows; returns the cap left."""
        key = record['key']
        new_replies = [r for r in self.typed_candidates(record) if r['event'] not in self.state['seen']]
        self.read_threads.add(record['ts'])
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
            return remaining
        standing = self.hold(record)
        if standing == 'unknown':
            if self.staging_only:
                raise SlackError('hold_state_unreadable')
            return remaining
        if standing != 'live':
            for reply in new_replies:
                if remaining <= 0:
                    break
                if self.notice(reply['event'], key, record['ts'],
                               'No open decision matches this reply. Firstmate has been notified.',
                               'check: slack %s - unmatched reply %s' % (record['ts'], reply['ts'])):
                    remaining -= 1
            return remaining
        typed = {r['answer']: r['label'] for r in new_replies}
        tapped = {tap['answer']: tap['label'] for tap in taps}
        if len(typed) > 1 or len(tapped) > 1 or (typed and tapped and typed.keys() != tapped.keys()):
            record['conflicts'] = record.get('conflicts', 0) + 1
            record['blocked'] = signature
            candidates = sorted(set(typed.values()) | set(tapped.values()))
            labels = ' vs '.join(short(flat(label)) for label in candidates[:2])
            if len(candidates) > 2:
                labels += ' (+%d more)' % (len(candidates) - 2)
            event = new_replies[0]['event'] if new_replies else self.event(
                record, 'conflict', str(record['conflicts']))
            if len(tapped) > 1:
                remedy = 'Remove all but one reaction.'
            elif tapped:
                remedy = 'Remove the :%s: reaction and reply again, or type %d.' % (
                    taps[0]['name'], REACTIONS.index(taps[0]['name']) + 1)
            else:
                remedy = 'Please reply once.'
            if self.notice(event, key, record['ts'],
                           'Conflicting signals: ' + slack_escape(labels) + '. No answer was recorded. ' + remedy,
                           'check: slack %s - conflicting signals: %s. %s' % (record['ts'], labels, remedy),
                           [r['event'] for r in new_replies]):
                remaining -= 1
            return remaining
        if new_replies:
            chosen = new_replies[0]
        else:
            chosen = taps[0]
        answer, label, author = chosen['answer'], chosen['label'], chosen['user']
        self.consume([c['event'] for c in new_replies + taps if c is not chosen], key)
        row = {'event': chosen['event'], 'occurrence': occurrence,
               'identity': record['identity'], 'thread': record['ts'],
               'key': key, 'mode': record.get('mode', 'done'),
               'answer': answer, 'label': label, 'author': author,
               'kind': 'answer', 'stage': 'intake'}
        advanced = self.advanced
        pending = self.stage(row)
        self.publish(pending)
        if pending is row or self.advanced > advanced:
            remaining -= 1
        return remaining

    def event(self, record, *parts):
        return '/'.join([self.state.get('team', ''), self.state.get('channel', ''), record['ts'], *parts])

    def report_failure(self, error):
        name = str(error) if isinstance(error, SlackError) else 'local_state_or_response_error'
        if self.state.get('failure') != name:
            # The wake line and the failure class are journaled by the same commit.
            self.say('slack: transport failure: ' + name + (': ' + self.detail if self.detail else ''))
            self.state['failure'] = name
            self.commit()
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
        'check': 'Usage: fm-slack-check.sh [arm|check|disarm|retarget] [--replay transcript.json]',
    }.get(command, 'Usage: fm-slack-{mirror,poll,check}.sh [--replay transcript.json]')


def state_home():
    return Path(os.environ.get('FM_STATE_OVERRIDE', Path(os.environ['FM_HOME']) / 'state'))


def emit(watch, command):
    fault('before-emit')
    lines = list(watch.output)
    queued = watch.queued() if command in ('poll', 'check') else 0
    if command == 'check':
        # Only the lines the wake line holds are printed (and cleared from the journal);
        # the rest wait for the next run behind the queue marker.
        shown = len(lines)
        while shown > 1 and len('; '.join(lines[:shown]) + queue_tail(queued + len(lines) - shown)) > WAKE_LIMIT:
            shown -= 1
        if lines:
            print(wake_line(lines[:shown], queued + len(lines) - shown), flush=True)
            watch.printed(shown)
        return
    if lines:
        lines[-1] += queue_tail(queued)
    for line in lines:
        print(line, flush=True)
    watch.printed(len(watch.output))


def main(argv):
    os.umask(0o077)
    action = env_value('FM_SLACK_CHECK_ACTION') if argv and argv[0] == 'check' else ''
    refusals = sys.stderr if action in ('arm', 'retarget') else sys.stdout
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
        if action in ('arm', 'retarget'):
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
        if action != 'retarget':
            # Only an explicit retarget may move the plane to a changed owner DM.
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
        if action not in ('arm', 'retarget'):
            emit(watch, command)
        return code
    except (SlackError, OSError, ValueError, KeyError, TypeError) as error:
        # Report once per failure episode. Pending rows and state remain durable;
        # lines said before the failure belong to state already committed.
        name = str(error) if isinstance(error, SlackError) else 'local_state_or_response_error'
        if action in ('arm', 'retarget'):
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
    if action == 'retarget':
        if watch.retarget():
            print('retargeted: the old DM is no longer tracked; the next arm, mirror, or poll opens the DM of FM_SLACK_DM_USER')
        else:
            print('unchanged: FM_SLACK_DM_USER matches the DM already in use; nothing to retarget')
        return 0
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
