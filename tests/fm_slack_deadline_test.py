#!/usr/bin/env python3
"""Exercise the shell Slack check with fake HTTP bodies: slow replies, and a peer that stays silent far past the alarm interval."""
import contextlib
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse


ROOT = Path(__file__).resolve().parent.parent
# Two replies fit inside one no-progress bound, as 9 s replies fit inside the
# watcher's default 30 s; the check still outlasts the bound with no CPU to show.
LATENCY_SECONDS = 3
NO_PROGRESS_SECONDS = 6
# No deadline ends a request: one that waits ALARM_SECONDS raises an alarm line and keeps waiting (Main 2694). A silent peer answers after
# HANG_SECONDS (one alarm), and after LONG_HANG_SECONDS under a no-progress bound shorter than that wait (two alarms; the alarm line is progress).
ALARM_SECONDS = 10
HANG_SECONDS = 12
LONG_HANG_SECONDS = 25
LONG_NO_PROGRESS_SECONDS = 15


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

    def urlopen(request, timeout=None):
        nonlocal requests
        requests += 1
        method = request.full_url.rsplit('/', 1)[-1]
        fields = dict(urllib.parse.parse_qsl(request.data.decode()))
        for key, value in fields.items():
            with contextlib.suppress(ValueError):
                fields[key] = json.loads(value)
        started = time.monotonic()
        try:
            if scenario in ('hang', 'longhang') and requests == 1:
                # No listener or external address: the peer stays silent for a long while and then answers. Nothing ends the blocked
                # read before that: the request raises its alarm lines and keeps waiting.
                with contextlib.ExitStack() as stack:
                    reader, peer = socket.socketpair()
                    stack.enter_context(reader)
                    stack.enter_context(peer)
                    timer = threading.Timer(HANG_SECONDS if scenario == 'hang' else LONG_HANG_SECONDS, peer.send, (b'x',))
                    timer.start()
                    stack.callback(timer.cancel)
                    reader.recv(1)
            if scenario == 'latency':
                # Slack itself is slow: the wait is idle, inside the request.
                time.sleep(LATENCY_SECONDS)
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

        def invoke(*args, scenario=''):
            entry = (['bash', str(home / 'state/slack.check.sh')]
                     if args == ('check',) else ['bash', str(ROOT / 'bin/fm-slack-check.sh'), *args])
            return subprocess.run(entry, env=dict(env, FM_TEST_SLACK_SCENARIO=scenario),
                                  capture_output=True, text=True, check=True)

        def command(*args, scenario=''):
            result = invoke(*args, scenario=scenario)
            finished = len(result.stderr.splitlines())
            assert result.stderr == 'slack: request finished\n' * finished, result.stderr
            return result.stdout

        assert 'armed:' in command('arm')
        timings.write_text('')
        started = time.monotonic()
        result = invoke('check', scenario='slow')
        output = result.stdout
        elapsed = time.monotonic() - started
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert result.stderr == 'slack: request finished\n' * len(rows), result.stderr
        print('slow check elapsed: %.3fs; request timings: %s' % (elapsed, json.dumps(rows)), flush=True)
        assert 'transport failure' not in output, output
        assert elapsed >= 21, elapsed
        assert all(row['timeout'] is None for row in rows), rows  # no fixed deadline reaches the connection
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
        watched = subprocess.run(
            ['bash', '-c', '''
                . "$1"
                WATCHER_PID=$$
                trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
                watcher_beat force
                CHECK_TIMEOUT=$3
                run_check_capture slack "$2" || exit 21
                printf 'status=%s stopped=%s notice=%s result=%s\\n' \
                  "$FM_CHECK_STATUS" "$FM_CHECK_STOPPED" "$FM_CHECK_STOP_NOTICE" "$FM_CHECK_RESULT"
             ''', '_', str(ROOT / 'bin/fm-watch.sh'), str(home / 'state/slack.check.sh'), str(NO_PROGRESS_SECONDS)],
            env=dict(env, FM_TEST_SLACK_SCENARIO='latency'), capture_output=True, text=True)
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert watched.returncode == 0, watched
        assert watched.stdout == 'status=0 stopped= notice= result=\n', watched
        assert sum(row['seconds'] for row in rows) > NO_PROGRESS_SECONDS, rows
        assert all(row['timeout'] is None for row in rows), rows  # no fixed deadline reaches the connection
        assert len(cards()) == 4, cards()
        print('ok - watcher lets %d requests of %ds each finish under a %ds no-progress bound'
              % (len(rows), LATENCY_SECONDS, NO_PROGRESS_SECONDS), flush=True)

        timings.write_text('')
        started = time.monotonic()
        waited = invoke('check', scenario='hang')
        elapsed = time.monotonic() - started
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert rows and rows[0]['seconds'] >= HANG_SECONDS, rows
        assert all(row['timeout'] is None for row in rows), rows  # no fixed deadline reaches the connection
        lines = waited.stderr.splitlines()
        alarms = [line for line in lines if 'still waiting' in line]
        assert len(alarms) == 1 and alarms[0].startswith('slack: request '), waited.stderr
        assert alarms[0].endswith(' still waiting after %ds; it keeps waiting' % ALARM_SECONDS), alarms
        assert lines.count('slack: request finished') == len(rows), waited.stderr
        assert 'transport failure' not in waited.stdout, waited.stdout  # a slow peer is never unreachable
        assert len(cards()) == 4, cards()
        assert command('check') == ''  # nothing is lost or repeated after the wait
        assert len(cards()) == 4, cards()
        print('ok - a peer silent for %.1fs is waited for: one alarm line after %ds, no failure, four cards stay four'
              % (rows[0]['seconds'], ALARM_SECONDS))
        print('silent peer request timings: ' + json.dumps(rows))

        timings.write_text('')
        longwatched = subprocess.run(
            ['bash', '-c', '''
                . "$1"
                WATCHER_PID=$$
                trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
                watcher_beat force
                CHECK_TIMEOUT=$3
                run_check_capture slack "$2" || exit 21
                printf 'status=%s stopped=%s notice=%s result=%s\\n' \
                  "$FM_CHECK_STATUS" "$FM_CHECK_STOPPED" "$FM_CHECK_STOP_NOTICE" "$FM_CHECK_RESULT"
             ''', '_', str(ROOT / 'bin/fm-watch.sh'), str(home / 'state/slack.check.sh'), str(LONG_NO_PROGRESS_SECONDS)],
            env=dict(env, FM_TEST_SLACK_SCENARIO='longhang'), capture_output=True, text=True)
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert longwatched.returncode == 0, longwatched
        assert longwatched.stdout == 'status=0 stopped= notice= result=\n', longwatched
        assert rows and rows[0]['seconds'] >= LONG_HANG_SECONDS > LONG_NO_PROGRESS_SECONDS, rows
        print('ok - watcher does not stop a request that waits %.1fs under a %ds no-progress bound: its alarm lines are progress'
              % (rows[0]['seconds'], LONG_NO_PROGRESS_SECONDS), flush=True)


if __name__ == '__main__':
    main()
