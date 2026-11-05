#!/usr/bin/env python3
"""Deterministic replay of the Slack Web API methods this plane uses.

Transcripts never contain a token. Replay state and the outbound log live under
the fixture home's state directory, so a mirror leg followed by a poll leg sees
the same conversation. No socket is opened.
"""
import json
import os
from pathlib import Path

from fm_slack import SlackError

# The scope Slack requires for each method the plane calls. A transcript that sets
# "enforce_scopes" fails a call whose scope its "scopes" list lacks, as Slack does.
METHOD_SCOPES = {
    'chat.postMessage': 'chat:write',
    'chat.update': 'chat:write',
    'conversations.open': 'im:write',
    'conversations.history': 'im:history',
    'conversations.replies': 'im:history',
    'reactions.get': 'reactions:read',
    'reactions.add': 'reactions:write',
    'users.info': 'users:read',
}


def ts_key(ts):
    """Order Slack timestamps as numbers, never as floats."""
    seconds, _, fraction = str(ts or 0).partition('.')
    return int(seconds or 0), int((fraction + '000000000')[:9])


class Replay:
    def __init__(self, transcript_path, state_dir, token_present=True):
        self.path = Path(transcript_path)
        if not self.path.is_file() or self.path.is_symlink():
            raise SlackError('replay_transcript_unreadable')
        self.transcript = json.loads(self.path.read_text())
        if self.transcript.get('schema') != 'fm-slack-replay.v1':
            raise SlackError('invalid_replay_transcript_schema')
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        digest = __import__('hashlib').sha256(str(self.path.resolve()).encode()).hexdigest()[:16]
        self.state_path = self.state_dir / ('replay-state-' + digest + '.json')
        self.log_path = self.state_dir / 'outbound.jsonl'
        # Every call that reaches the replay, including one that fails, is recorded here before it is judged.
        self.attempts_path = self.state_dir / 'attempts.jsonl'
        self.token_present = token_present
        if self.state_path.is_symlink() or self.log_path.is_symlink() or self.attempts_path.is_symlink():
            raise SlackError('unsafe_replay_state_path')
        if self.state_path.exists():
            self.state = json.loads(self.state_path.read_text())
        else:
            self.state = {
                'schema': 'fm-slack-replay-state.v1',
                'messages': self.transcript.get('messages', []),
                'reactions': self.transcript.get('reactions', {}),
                'failures': {k: dict(v) for k, v in self.transcript.get('failures', {}).items()},
                'next_ts': self.transcript.get('next_ts', 900),
                'log': [],
            }
            self.save()
        self.scopes = set(self.transcript.get('scopes', []))

    def save(self):
        self.state_path.write_text(json.dumps(self.state, ensure_ascii=False))

    def log(self, entry):
        self.state['log'].append(entry)
        with self.log_path.open('a') as out:
            out.write(json.dumps(entry, ensure_ascii=False) + '\n')
        self.save()

    def fail(self, method, target=None):
        # A rule keyed "<method>:<ts>" fails only the call about that one message.
        rule = (self.state['failures'].get('%s:%s' % (method, target)) if target else None) \
            or self.state['failures'].get(method)
        if not rule:
            return None
        if rule.get('times') is not None:
            if rule['times'] <= 0:
                return None
            rule['times'] -= 1
        self.save()
        return rule

    def attempt(self, method, fields):
        entry = {'method': method, 'channel': fields.get('channel'),
                 'oldest': fields.get('oldest'), 'latest': fields.get('latest')}
        with self.attempts_path.open('a') as out:
            out.write(json.dumps(entry, ensure_ascii=False) + '\n')

    def call(self, method, **fields):
        self.attempt(method, fields)
        if not self.token_present:
            raise SlackError('missing_token')
        needed = METHOD_SCOPES.get(method)
        if self.transcript.get('enforce_scopes') and needed and needed not in self.scopes:
            self.log({'method': method, 'error': 'missing_scope', 'scope': needed})
            raise SlackError('missing_scope')
        rule = self.fail(method, fields.get('ts') or fields.get('timestamp'))
        if rule:
            status = int(rule.get('status', 503))
            if status == 429:
                raise SlackError('rate_limited')
            raise SlackError('unreachable' if status >= 500 else 'api_error')
        if method == 'auth.test':
            data = {'ok': True, 'team_id': self.transcript.get('team', 'T0123456789'),
                    'user_id': self.transcript.get('bot_user', 'UBOT0123456')}
        elif method == 'conversations.open':
            target = fields.get('users')
            # The configured owner, or one whose DM this conversation already opened (a retarget reads the DM it leaves).
            opened = self.state.setdefault('opened', [])
            if target != os.environ.get('FM_SLACK_DM_USER') and target not in opened:
                raise SlackError('target_mismatch')
            if target not in opened:
                opened.append(target)
            # owner_dm names the DM that really belongs to the opened user when it is not the channel that accepts posts.
            channel = self.transcript.get('owner_dm', self.transcript.get('channel', 'D0123456789'))
            self.log({'method': method, 'recipient': target, 'channel': channel})
            data = {'ok': True, 'channel': {'id': channel, 'is_im': True} if fields.get('return_im') else {'id': channel}}
        elif method in ('conversations.history', 'conversations.replies'):
            channel = fields.get('channel')
            if channel != self.transcript.get('channel', 'D0123456789'):
                raise SlackError('channel_not_found')
            # A message may name its own channel; the default is the transcript's DM.
            here = [m for m in self.state['messages']
                    if m.get('channel', self.transcript.get('channel', 'D0123456789')) == channel]
            if method.endswith('history'):
                # Slack's history lists the channel's top-level messages, newest first: a thread
                # root (thread_ts equal to its own ts, once it has replies) and a reply that was
                # also sent to the channel (subtype thread_broadcast, thread_ts different from ts).
                # An ordinary thread reply is read through conversations.replies only.
                messages = [m for m in reversed(here)
                            if not m.get('thread_ts') or m['thread_ts'] == m.get('ts')
                            or m.get('subtype') == 'thread_broadcast']
                oldest = fields.get('oldest')
                if oldest:
                    messages = [m for m in messages if ts_key(m.get('ts')) > ts_key(oldest)]
                # Like Slack, both bounds are exclusive, and a page is the newest messages inside them.
                latest = fields.get('latest')
                if latest:
                    messages = [m for m in messages if ts_key(m.get('ts')) < ts_key(latest)]
            else:
                root = fields.get('ts')
                messages = [m for m in here
                            if m.get('ts') == root or m.get('thread_ts') == root]
            if not fields.get('include_all_metadata'):
                messages = [{k: v for k, v in m.items() if k != 'metadata'} for m in messages]
            start = int(fields.get('cursor') or 0)
            size = int(fields.get('limit') or 100)
            page = messages[start:start + size]
            self.log({'method': method, 'recipient': os.environ.get('FM_SLACK_DM_USER'),
                      'channel': channel, 'thread_ts': fields.get('ts'), 'cursor': start,
                      'oldest': fields.get('oldest'), 'latest': fields.get('latest'), 'limit': size})
            more = len(messages) > start + size
            data = {'ok': True, 'messages': page, 'has_more': more,
                    'response_metadata': {'next_cursor': str(start + size) if more else ''}}
        elif method == 'chat.postMessage':
            channel = fields.get('channel')
            if channel != self.transcript.get('channel', 'D0123456789'):
                raise SlackError('channel_not_found')
            if len(fields.get('text', '')) > 40000:
                raise SlackError('api_error')
            next_ts = int(self.state['next_ts']) + 1
            self.state['next_ts'] = next_ts
            ts = f'{next_ts}.000001'
            message = {'ts': ts, 'user': self.transcript.get('bot_user', 'UBOT0123456'),
                       'bot_id': self.transcript.get('bot_id', 'BBOT0123456'),
                       'text': fields.get('text', ''),
                       'client_msg_id': fields.get('client_msg_id'),
                       'metadata': fields.get('metadata')}
            if fields.get('thread_ts'):
                message['thread_ts'] = fields['thread_ts']
            self.state['messages'].append(message)
            self.state['reactions'].setdefault(ts, [])
            self.save()
            self.log({'method': method, 'recipient': os.environ.get('FM_SLACK_DM_USER'),
                      'channel': channel, 'thread_ts': fields.get('thread_ts'),
                      'ts': ts, 'text': fields.get('text', '')})
            data = {'ok': True, 'ts': ts, 'channel': channel}
        elif method == 'chat.update':
            channel, ts = fields.get('channel'), fields.get('ts')
            if channel != self.transcript.get('channel', 'D0123456789'):
                raise SlackError('channel_not_found')
            message = next((m for m in self.state['messages'] if m.get('ts') == ts), None)
            if message is None or len(fields.get('text', '')) > 40000:
                raise SlackError('api_error')
            message['text'] = fields['text']
            self.log({'method': method, 'recipient': os.environ.get('FM_SLACK_DM_USER'),
                      'channel': channel, 'ts': ts, 'text': fields['text']})
            data = {'ok': True, 'ts': ts, 'channel': channel, 'text': fields['text']}
        elif method == 'reactions.get':
            timestamp = fields.get('timestamp')
            message = next((m for m in self.state['messages'] if m.get('ts') == timestamp), None)
            if message is None:
                raise SlackError('channel_not_found')
            data = {'ok': True, 'message': dict(message,
                    reactions=self.state['reactions'].get(timestamp, []))}
            self.log({'method': method, 'recipient': os.environ.get('FM_SLACK_DM_USER'),
                      'channel': fields.get('channel'), 'ts': timestamp})
        elif method == 'reactions.add':
            timestamp = fields.get('timestamp')
            if not any(m.get('ts') == timestamp for m in self.state['messages']):
                raise SlackError('channel_not_found')
            reactions = self.state['reactions'].setdefault(timestamp, [])
            name = fields.get('name')
            entry = next((r for r in reactions if r.get('name') == name), None)
            if entry is None:
                reactions.append({'name': name, 'users': []})
                entry = reactions[-1]
            self.log({'method': method, 'recipient': os.environ.get('FM_SLACK_DM_USER'),
                      'channel': fields.get('channel'), 'ts': timestamp, 'name': name})
            data = {'ok': True}
        elif method == 'users.info':
            user = fields.get('user')
            record = self.transcript.get('users', {}).get(user, {})
            if record.get('missing'):
                raise SlackError('user_not_found')
            data = {'ok': True, 'user': {
                'id': user,
                'is_bot': record.get('is_bot', False),
                'is_app_user': record.get('is_app_user', False)}}
        else:
            raise SlackError('unsupported_replay_method')
        self.save()
        return data

    def pages(self, method, field, **fields):
        cursor = ''
        seen = set()
        while True:
            args = dict(fields)
            if cursor:
                args['cursor'] = cursor
            data = self.call(method, **args)
            yield from data.get(field, [])
            cursor = data.get('response_metadata', {}).get('next_cursor', '')
            if not cursor:
                break
            if cursor in seen:
                raise SlackError('repeated_page_cursor')
            seen.add(cursor)
