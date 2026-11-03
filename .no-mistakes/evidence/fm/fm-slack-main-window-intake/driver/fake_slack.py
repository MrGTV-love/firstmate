#!/usr/bin/env python3
"""A disposable local stand-in for the Slack Web API, as the plane sees it.
History lists top-level messages, newest first, and pages. Thread replies come only
through conversations.replies. A thread root gains thread_ts when a reply lands.
A method whose scope is not granted fails with missing_scope."""
import json
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCOPES = {'chat.postMessage': 'chat:write', 'chat.update': 'chat:write', 'conversations.open': 'im:write',
          'conversations.history': 'im:history', 'conversations.replies': 'im:history',
          'reactions.get': 'reactions:read', 'reactions.add': 'reactions:write', 'users.info': 'users:read'}


def key(ts):
    s, _, f = ts.partition('.')
    return int(s), int((f + '000000000')[:9])


class World:
    def __init__(self, token):
        self.token = token
        self.lock = threading.RLock()
        self.reset()

    def reset(self):
        self.channels = {'D0OWNERDM01': []}
        self.owner_dm = 'D0OWNERDM01'
        self.scopes = {'chat:write', 'im:write', 'im:history'}
        self.calls = []
        self.fail = {}
        self.page = 100
        self.next_ts = 1780000000  # plane posts sort before the owner messages the scenarios type later
        self.history_override = None

    def stamp(self):
        self.next_ts += 1
        return '%d.000100' % self.next_ts


class Handler(BaseHTTPRequestHandler):
    world = None

    def log_message(self, *args):
        pass

    def reply(self, data, status=200):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('x-oauth-scopes', ','.join(sorted(self.world.scopes)))
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        w = self.world
        body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        path = urllib.parse.urlparse(self.path).path
        with w.lock:
            if path.startswith('/ctl/'):
                return self.ctl(path[5:], json.loads(body or b'{}'))
            method = path.rsplit('/', 1)[-1]
            f = {k: v[0] for k, v in urllib.parse.parse_qs(body.decode(), keep_blank_values=True).items()}
            entry = {'method': method, 'fields': {k: v for k, v in f.items() if k != 'metadata'},
                     'auth_ok': self.headers.get('Authorization') == 'Bearer ' + w.token}
            w.calls.append(entry)
            if not entry['auth_ok']:
                return self.reply({'ok': False, 'error': 'invalid_auth'})
            need = SCOPES.get(method)
            if need and need not in w.scopes:
                entry['error'] = 'missing_scope'
                return self.reply({'ok': False, 'error': 'missing_scope'})
            rule = w.fail.get(method)
            if rule and rule.get('times', 0) > 0:
                rule['times'] -= 1
                entry['error'] = rule.get('error') or str(rule.get('status'))
                if rule.get('status'):
                    return self.reply({'ok': False}, rule['status'])
                return self.reply({'ok': False, 'error': rule['error']})
            return self.api(method, f, entry)

    def api(self, method, f, entry):
        w = self.world
        if method == 'auth.test':
            return self.reply({'ok': True, 'team_id': 'T0FAKETEAM1', 'user_id': 'UBOTFAKE001', 'bot_id': 'BBOTFAKE001'})
        if method == 'conversations.open':
            return self.reply({'ok': True, 'channel': {'id': w.owner_dm, 'is_im': True}})
        if method in ('conversations.history', 'conversations.replies'):
            msgs = w.channels.get(f.get('channel'))
            if msgs is None:
                return self.reply({'ok': False, 'error': 'channel_not_found'})
            meta = f.get('include_all_metadata') == 'true'
            if method.endswith('history'):
                out = [m for m in sorted(msgs, key=lambda m: key(m['ts']), reverse=True)
                       if not m.get('thread_ts') or m['thread_ts'] == m['ts'] or m.get('subtype') == 'thread_broadcast']
                if f.get('oldest'):
                    out = [m for m in out if key(m['ts']) > key(f['oldest'])]
            else:
                out = [m for m in sorted(msgs, key=lambda m: key(m['ts']))
                       if m['ts'] == f.get('ts') or m.get('thread_ts') == f.get('ts')]
                if not out:
                    return self.reply({'ok': False, 'error': 'thread_not_found'})
            start = int(f.get('cursor') or 0)
            size = min(int(f.get('limit') or 100), w.page)
            page = out[start:start + size]
            data = {'ok': True, 'messages': [{k: v for k, v in m.items() if meta or k != 'metadata'} for m in page]}
            if start + size < len(out):
                data['response_metadata'] = {'next_cursor': str(start + size)}
                data['has_more'] = True
            return self.reply(data)
        if method == 'chat.postMessage':
            channel = f.get('channel')
            msgs = w.channels.get(channel)
            if msgs is None:
                return self.reply({'ok': False, 'error': 'channel_not_found'})
            ts = w.stamp()
            m = {'ts': ts, 'user': 'UBOTFAKE001', 'bot_id': 'BBOTFAKE001', 'app_id': 'AFAKEAPP001',
                 'bot_profile': {'id': 'BBOTFAKE001'}, 'text': f.get('text', ''), 'type': 'message'}
            if f.get('metadata'):
                m['metadata'] = json.loads(f['metadata'])
            if f.get('thread_ts'):
                m['thread_ts'] = f['thread_ts']
                for root in msgs:
                    if root['ts'] == f['thread_ts']:
                        root['thread_ts'] = root['ts']
                        root['reply_count'] = root.get('reply_count', 0) + 1
            msgs.append(m)
            entry['ts'] = ts
            return self.reply({'ok': True, 'ts': ts, 'channel': channel, 'message': m})
        if method == 'chat.update':
            return self.reply({'ok': True, 'ts': f.get('ts'), 'channel': f.get('channel')})
        return self.reply({'ok': False, 'error': 'unknown_method'})

    def ctl(self, op, a):
        w = self.world
        if op == 'reset':
            w.reset()
        elif op == 'say':
            m = dict({'type': 'message'}, ts=a['ts'], user=a.get('user', 'U0TESTOWNER'), text=a.get('text', ''), **a.get('extra', {}))
            w.channels.setdefault(a.get('channel', w.owner_dm), []).append(m)
        elif op == 'edit':
            for m in w.channels[a.get('channel', w.owner_dm)]:
                if m['ts'] == a['ts']:
                    m['text'] = a['text']
                    m['edited'] = {'user': m.get('user'), 'ts': a.get('edit_ts', '9999999999.000000')}
        elif op == 'set':
            for k, v in a.items():
                setattr(w, k, set(v) if k == 'scopes' else v)
                if k == 'owner_dm':
                    w.channels.setdefault(v, [])
        elif op == 'fail':
            w.fail[a['method']] = a
        return self.reply({'ok': True, 'calls': w.calls, 'channels': w.channels})


def serve(token):
    world = World(token)
    handler = type('H', (Handler,), {'world': world})
    server = ThreadingHTTPServer(('127.0.0.1', 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, world
