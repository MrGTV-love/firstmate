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
        self.token_present = token_present
        if self.state_path.is_symlink() or self.log_path.is_symlink():
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

    def fail(self, method):
        rule = self.state['failures'].get(method)
        if not rule:
            return None
        if rule.get('times') is not None:
            if rule['times'] <= 0:
                return None
            rule['times'] -= 1
        self.save()
        return rule

    def call(self, method, **fields):
        if not self.token_present:
            raise SlackError('missing_token')
        rule = self.fail(method)
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
            if target != os.environ.get('FM_SLACK_DM_USER'):
                raise SlackError('target_mismatch')
            channel = self.transcript.get('channel', 'D0123456789')
            self.log({'method': method, 'recipient': target, 'channel': channel})
            data = {'ok': True, 'channel': {'id': channel, 'is_im': True} if fields.get('return_im') else {'id': channel}}
        elif method in ('conversations.history', 'conversations.replies'):
            channel = fields.get('channel')
            if channel != self.transcript.get('channel', 'D0123456789'):
                raise SlackError('channel_not_found')
            if method.endswith('history'):
                messages = [m for m in reversed(self.state['messages']) if not m.get('thread_ts')]
            else:
                root = fields.get('ts')
                messages = [m for m in self.state['messages']
                            if m.get('ts') == root or m.get('thread_ts') == root]
            if not fields.get('include_all_metadata'):
                messages = [{k: v for k, v in m.items() if k != 'metadata'} for m in messages]
            start = int(fields.get('cursor') or 0)
            size = int(fields.get('limit') or 100)
            page = messages[start:start + size]
            self.log({'method': method, 'recipient': os.environ.get('FM_SLACK_DM_USER'),
                      'channel': channel, 'thread_ts': fields.get('ts'), 'cursor': start})
            data = {'ok': True, 'messages': page,
                    'response_metadata': {'next_cursor': str(start + size)
                                          if len(messages) > start + size else ''}}
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
