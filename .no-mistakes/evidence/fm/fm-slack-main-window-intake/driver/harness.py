#!/usr/bin/env python3
"""Drive the real bin/fm-slack-*.sh commands in marked lab homes against fake_slack over HTTP."""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import fake_slack  # noqa: E402

TOKEN = 'fixture-token-not-a-secret'


class Lab:
    def __init__(self, root, scenario='intake'):
        self.root = Path(root)
        self.server, self.world = fake_slack.serve(TOKEN)
        self.base = 'http://127.0.0.1:%d' % self.server.server_address[1]
        self.dir = tempfile.mkdtemp(prefix='fm-lab.', dir='/tmp')
        out = subprocess.run([str(self.root / 'bin/fm-lab-home.sh'), 'create', self.dir], capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        self.home = out.stdout.strip()
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(('FM_', 'SLACK_', 'NO_MISTAKES')) and k not in ('TMUX', 'TMUX_PANE')}
        self.base_env = dict(env, FM_HOME=self.home, PYTHONPATH=str(Path(__file__).parent / 'pyshim'),
                             FAKE_SLACK_BASE=self.base + '/api/', https_proxy='http://127.0.0.1:9',
                             HTTPS_PROXY='http://127.0.0.1:9', no_proxy='127.0.0.1', NO_PROXY='127.0.0.1')
        r = subprocess.run(['bash', str(self.root / 'tests/fixtures/slack/make-home.sh'), scenario, self.home],
                           capture_output=True, text=True, env=self.base_env, cwd='/tmp')
        assert r.returncode == 0, r.stdout + r.stderr

    def run(self, cmd, *args, env=None):
        e = dict(self.base_env, **(env or {}))
        for k, v in (env or {}).items():
            if v is None:
                e.pop(k, None)
        r = subprocess.run([str(self.root / 'bin' / cmd), *args], capture_output=True, text=True, env=e, cwd=self.home)
        return r

    def poll(self, env=None):
        return self.run('fm-slack-poll.sh', env=env)

    def arm(self):
        r = self.run('fm-slack-check.sh', 'arm')
        assert r.returncode == 0, r.stdout + r.stderr
        return r

    def ctl(self, op, **a):
        req = urllib.request.Request(self.base + '/ctl/' + op, data=json.dumps(a).encode())
        return json.load(urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req))

    def say(self, ts, text='hello', user='U0TESTOWNER', **extra):
        channel = extra.pop('channel', None)
        a = dict(ts=ts, text=text, user=user, extra=extra)
        if channel:
            a['channel'] = channel
        self.ctl('say', **a)

    def calls(self, method=None):
        c = self.world.calls
        return [x for x in c if not method or x['method'] == method]

    def posts(self):
        return self.calls('chat.postMessage')

    def state(self):
        p = Path(self.home) / 'state/slack-watch/state.json'
        return json.loads(p.read_text()) if p.exists() else None

    def tree_digest(self):
        digest = hashlib.sha256()
        h = Path(self.home)
        for top in ('data', 'config', 'state', 'projects'):
            for p in sorted((h / top).rglob('*')):
                rel = p.relative_to(h)
                if str(rel).startswith('state/slack-watch') or not p.is_file():
                    continue
                digest.update(str(rel).encode() + b'\0' + p.read_bytes() + b'\0')
        return digest.hexdigest()

    def close(self):
        self.server.shutdown()
        shutil.rmtree(self.dir, ignore_errors=True)


def req_lines(out):
    return [l for l in out.splitlines() if l.startswith('check: slack request ')]
