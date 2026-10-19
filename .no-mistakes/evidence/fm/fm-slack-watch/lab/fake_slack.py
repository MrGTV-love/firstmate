#!/usr/bin/env python3
"""Loopback stand-in for the Slack Web API, for live-driving the real client.

Only the server is fake. bin/fm_slack.py (real urllib client, real headers,
real error mapping) and bin/fm_slack_watch.py run unmodified; sitecustomize.py
redirects https://slack.com/api/ to this server. Nothing here talks to Slack.

POST /api/<method>          form-encoded, Bearer token required
GET  /_admin/...            test controls (reply, main, react, unreact, scopes,
                            fail, state, log)
"""
import json
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = sys.argv[2] if len(sys.argv) > 2 else 'xoxb-lab-fake-token-0001'
TEAM, CHAN, BOT_USER, BOT_ID = 'T0LABTEAM01', 'D0LABDM0001', 'UBOTLAB0001', 'BBOTLAB0001'
LOCK = threading.Lock()
S = {'messages': [], 'reactions': {}, 'scopes': ['chat:write', 'im:write', 'im:history',
     'reactions:read', 'reactions:write', 'users:read'],
     'fail': {}, 'log': [], 'seq': 1760000000, 'bots': {BOT_USER, 'UOTHERBOT01'}}


def next_ts():
    S['seq'] += 1
    return '%d.%06d' % (S['seq'], 1)


def api(method, f, token_ok):
    if not token_ok:
        return {'ok': False, 'error': 'invalid_auth'}, 200
    rule = S['fail'].get(method)
    if rule and rule['times'] != 0:
        if rule['times'] > 0:
            rule['times'] -= 1
        return {'ok': False, 'error': 'x'}, rule['status']
    if method == 'auth.test':
        return {'ok': True, 'team_id': TEAM, 'user_id': BOT_USER}, 200
    if method == 'conversations.open':
        return {'ok': True, 'channel': {'id': CHAN, 'is_im': True}}, 200
    if method in ('conversations.history', 'conversations.replies'):
        if f.get('channel') != CHAN:
            return {'ok': False, 'error': 'channel_not_found'}, 200
        if method.endswith('history'):
            msgs = [m for m in reversed(S['messages']) if not m.get('thread_ts')]
        else:
            root = f.get('ts')
            msgs = [m for m in S['messages'] if m['ts'] == root or m.get('thread_ts') == root]
            if not msgs:
                return {'ok': False, 'error': 'thread_not_found'}, 200
        if f.get('include_all_metadata') not in ('true', 'True', '1'):
            msgs = [{k: v for k, v in m.items() if k != 'metadata'} for m in msgs]
        start, size = int(f.get('cursor') or 0), int(f.get('limit') or 100)
        page = msgs[start:start + size]
        nxt = str(start + size) if len(msgs) > start + size else ''
        return {'ok': True, 'messages': page, 'response_metadata': {'next_cursor': nxt}}, 200
    if method == 'chat.postMessage':
        if f.get('channel') != CHAN:
            return {'ok': False, 'error': 'channel_not_found'}, 200
        text = f.get('text', '')
        if len(text) > 40000:
            return {'ok': False, 'error': 'msg_too_long'}, 200
        ts = next_ts()
        m = {'ts': ts, 'user': BOT_USER, 'bot_id': BOT_ID, 'text': text,
             'client_msg_id': f.get('client_msg_id')}
        if f.get('metadata'):
            m['metadata'] = json.loads(f['metadata'])
        if f.get('thread_ts'):
            m['thread_ts'] = f['thread_ts']
        S['messages'].append(m)
        return {'ok': True, 'ts': ts, 'channel': CHAN}, 200
    if method == 'reactions.get':
        m = next((x for x in S['messages'] if x['ts'] == f.get('timestamp')), None)
        if m is None:
            return {'ok': False, 'error': 'message_not_found'}, 200
        return {'ok': True, 'message': dict(m, reactions=S['reactions'].get(m['ts'], []))}, 200
    if method == 'reactions.add':
        react(f.get('timestamp'), f.get('name'), BOT_USER)
        return {'ok': True}, 200
    if method == 'users.info':
        u = f.get('user', '')
        return {'ok': True, 'user': {'id': u, 'is_bot': u in S['bots'], 'is_app_user': False}}, 200
    return {'ok': False, 'error': 'unknown_method'}, 200


def react(ts, name, user):
    rs = S['reactions'].setdefault(ts, [])
    for r in rs:
        if r['name'] == name:
            if user not in r['users']:
                r['users'].append(user)
                r['count'] = len(r['users'])
            return
    rs.append({'name': name, 'users': [user], 'count': 1})


def unreact(ts, name, user):
    rs = S['reactions'].get(ts, [])
    for r in list(rs):
        if r['name'] == name and user in r['users']:
            r['users'].remove(user)
            r['count'] = len(r['users'])
            if not r['users']:
                rs.remove(r)


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, status=200, headers=None):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        f = {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode(), keep_blank_values=True).items()}
        method = self.path.rsplit('/', 1)[-1]
        auth = self.headers.get('Authorization', '')
        with LOCK:
            body, status = api(method, f, auth == 'Bearer ' + TOKEN)
            S['log'].append({'method': method, 'auth_ok': auth == 'Bearer ' + TOKEN,
                             'status': status, 'thread_ts': f.get('thread_ts') or f.get('ts'),
                             'has_text': bool(f.get('text'))})
            self.send(body, status, {'x-oauth-scopes': ','.join(S['scopes'])})

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query, keep_blank_values=True).items()}
        with LOCK:
            p = u.path
            if p == '/_admin/reply':
                ts = next_ts()
                m = {'ts': ts, 'user': q.get('user', 'U0LABOWNER1'), 'text': q['text'],
                     'thread_ts': q['thread']}
                for k in ('bot_id', 'subtype'):
                    if q.get(k):
                        m[k] = q[k]
                S['messages'].append(m)
                return self.send({'ok': True, 'ts': ts})
            if p == '/_admin/main':
                ts = next_ts()
                S['messages'].append({'ts': ts, 'user': q.get('user', 'U0LABOWNER1'), 'text': q['text']})
                return self.send({'ok': True, 'ts': ts})
            if p == '/_admin/react':
                react(q['ts'], q['name'], q.get('user', 'U0LABOWNER1'))
                return self.send({'ok': True})
            if p == '/_admin/unreact':
                unreact(q['ts'], q['name'], q.get('user', 'U0LABOWNER1'))
                return self.send({'ok': True})
            if p == '/_admin/scopes':
                S['scopes'] = [s for s in q.get('list', '').split(',') if s]
                return self.send({'ok': True})
            if p == '/_admin/fail':
                S['fail'][q['method']] = {'status': int(q.get('status', 503)), 'times': int(q.get('times', -1))}
                return self.send({'ok': True})
            if p == '/_admin/clearfail':
                S['fail'] = {}
                return self.send({'ok': True})
            if p == '/_admin/state':
                return self.send({'messages': S['messages'], 'reactions': S['reactions']})
            if p == '/_admin/log':
                return self.send(S['log'])
        self.send({'ok': False}, 404)


if __name__ == '__main__':
    srv = ThreadingHTTPServer(('127.0.0.1', 0), H)
    with open(sys.argv[1], 'w') as out:
        out.write(str(srv.server_address[1]))
    srv.serve_forever()
