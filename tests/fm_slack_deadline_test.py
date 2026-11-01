#!/usr/bin/env python3
"""Exercise the shell Slack check with fake HTTP bodies and a real socket timeout."""
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse


ROOT = Path(__file__).resolve().parent.parent


def install():
    """Installed only in the Slack entry process, never its local intake children."""
    if Path(sys.argv[0]).name != 'fm_slack_watch.py':
        return
    sys.path.insert(0, str(ROOT / 'bin'))
    from fm_slack_replay import Replay
    import urllib.request
    replay = Replay(ROOT / 'tests/fixtures/slack/mirror/transcript.json',
                    Path(os.environ['FM_STATE_OVERRIDE']) / 'slack-watch')
    scenario = os.environ.get('FM_TEST_SLACK_SCENARIO', '')
    requests = 0

    class Response(io.BytesIO):
        headers = {'x-oauth-scopes': ','.join(replay.scopes)}

        def __exit__(self, *args):
            super().__exit__(*args)
            # Simulate lost scheduling time outside the request, after its body
            # has returned. One gap alone exceeds the removed 20-second budget.
            if scenario == 'slow' and requests == 1:
                time.sleep(21)

    def urlopen(request, timeout):
        nonlocal requests
        requests += 1
        method = request.full_url.rsplit('/', 1)[-1]
        fields = dict(urllib.parse.parse_qsl(request.data.decode()))
        for key, value in fields.items():
            with contextlib.suppress(ValueError):
                fields[key] = json.loads(value)
        started = time.monotonic()
        try:
            if scenario == 'hang':
                # No listener or external address: leave the peer silent and
                # let the production timeout terminate the blocked read.
                with contextlib.ExitStack() as stack:
                    reader, peer = socket.socketpair()
                    stack.enter_context(reader)
                    stack.enter_context(peer)
                    reader.settimeout(timeout)
                    reader.recv(1)
                raise AssertionError('silent peer returned')
            body = replay.call(method, **fields)
            return Response(json.dumps(body).encode())
        finally:
            with open(os.environ['FM_TEST_SLACK_TIMINGS'], 'a') as out:
                out.write(json.dumps({'method': method, 'timeout': timeout,
                                      'seconds': time.monotonic() - started}) + '\n')

    urllib.request.urlopen = urlopen


def main():
    with tempfile.TemporaryDirectory(prefix='fm-slack-deadline-') as tmp:
        home = Path(tmp)
        env = dict(os.environ, FM_HOME=tmp, FM_STATE_OVERRIDE=str(home / 'state'),
                   FM_DATA_OVERRIDE=str(home / 'data'), FM_CONFIG_OVERRIDE=str(home / 'config'),
                   SLACK_BOT_TOKEN='fixture-token-not-a-secret', FM_SLACK_DM_USER='U0TESTOWNER',
                   FM_SLACK_ALLOWED_AUTHORS='U0TESTOWNER', FM_SLACK_POLL_MAX_ANSWERS='20',
                   PYTHONDONTWRITEBYTECODE='1')
        subprocess.run(['bash', str(ROOT / 'tests/fixtures/slack/make-home.sh'), 'mirror', tmp],
                       check=True, env=env, capture_output=True, text=True)
        subprocess.run(['bash', str(ROOT / 'bin/fm-captain-hold.sh'), 'bind', 'slack-dm'],
                       check=True, env=env, capture_output=True, text=True)
        hook = home / 'hook'
        hook.mkdir()
        (hook / 'sitecustomize.py').write_text('import fm_slack_deadline_test; fm_slack_deadline_test.install()\n')
        env['PYTHONPATH'] = os.pathsep.join([str(hook), str(ROOT / 'tests')])
        timings = home / 'timings.jsonl'
        env['FM_TEST_SLACK_TIMINGS'] = str(timings)

        def command(*args, scenario=''):
            entry = (['bash', str(home / 'state/slack.check.sh')]
                     if args == ('check',) else ['bash', str(ROOT / 'bin/fm-slack-check.sh'), *args])
            result = subprocess.run(entry, env=dict(env, FM_TEST_SLACK_SCENARIO=scenario),
                                    capture_output=True, text=True, check=True)
            assert not result.stderr, result.stderr
            return result.stdout

        assert 'armed:' in command('arm')
        timings.write_text('')
        started = time.monotonic()
        output = command('check', scenario='slow')
        elapsed = time.monotonic() - started
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        print('slow check elapsed: %.3fs; request timings: %s' % (elapsed, json.dumps(rows)), flush=True)
        assert 'transport failure' not in output, output
        assert elapsed >= 21, elapsed
        assert all(row['seconds'] < row['timeout'] for row in rows), rows
        state_path = home / 'state/slack-watch/state.json'
        assert len(json.loads(state_path.read_text())['threads']) == 4
        outbound = home / 'state/slack-watch/outbound.jsonl'

        def cards():
            return [json.loads(line) for line in outbound.read_text().splitlines()
                    if json.loads(line)['method'] == 'chat.postMessage']

        assert len(cards()) == 4, cards()
        assert command('check') == ''
        assert len(cards()) == 4, cards()
        print('ok - slow standing check completes after %.3fs; four cards remain four on repeat' % elapsed)

        timings.write_text('')
        started = time.monotonic()
        first = command('check', scenario='hang')
        elapsed = time.monotonic() - started
        assert first.count('slack: transport failure: unreachable') == 1, first
        # Default owner policy is 30s of no progress (fm-watch.sh), not a
        # cumulative allowance. The retained socket timeout must finish first.
        assert elapsed < 30, elapsed
        assert command('check', scenario='hang') == ''
        assert len(cards()) == 4, cards()
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert all(row['seconds'] >= row['timeout'] for row in rows), rows
        assert all(row['timeout'] == 10 for row in rows), rows
        assert command('check') == ''  # recovery clears the failure episode
        assert command('check', scenario='hang').count('transport failure: unreachable') == 1
        assert len(cards()) == 4, cards()
        print('ok - hung request ends after %.3fs, before owner no-progress bound 30s; one report per episode' % elapsed)
        print('hanging request timings: ' + json.dumps(rows))


if __name__ == '__main__':
    main()
