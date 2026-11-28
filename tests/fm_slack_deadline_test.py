#!/usr/bin/env python3
"""Exercise the shell Slack check with fake HTTP bodies and a real socket timeout."""
import contextlib
import io
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse


ROOT = Path(__file__).resolve().parent.parent
# Two replies fit inside one no-progress bound, as 9 s replies fit inside the
# watcher's default 30 s; the check still outlasts the bound with no CPU to show.
LATENCY_SECONDS = 3
NO_PROGRESS_SECONDS = 6
# The one added person of the second-person cases, and their DM in tests/fixtures/slack/second-person.
SECOND, SECOND_DM, OWNER_DM = 'U0SYNTHSEC1', 'D0SECONDDM1', 'D0123456789'


def no_network_guard():
    """Any real network step of a Slack entry process (a name lookup or a connect over IP) is refused and recorded in FM_TEST_SLACK_NETWORK; every case
    asserts that file stays empty (network_attempts), so a call that slips past the fake transport fails the test instead of leaving this host."""
    log = os.environ['FM_TEST_SLACK_NETWORK']

    def refuse(what, target):
        with open(log, 'a') as out:
            out.write(json.dumps({'what': what, 'target': repr(target)}) + '\n')
        raise OSError('network attempt refused by the deadline test: ' + what)
    real_connect, real_connect_ex = socket.socket.connect, socket.socket.connect_ex

    def connect(sock, address):
        if sock.family in (socket.AF_INET, socket.AF_INET6):
            refuse('connect', address)
        return real_connect(sock, address)

    def connect_ex(sock, address):
        if sock.family in (socket.AF_INET, socket.AF_INET6):
            refuse('connect_ex', address)
        return real_connect_ex(sock, address)
    socket.socket.connect, socket.socket.connect_ex = connect, connect_ex
    socket.create_connection = lambda address, *args, **kwargs: refuse('create_connection', address)
    socket.getaddrinfo = lambda host, *args, **kwargs: refuse('getaddrinfo', host)


def network_attempts(path):
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def install():
    """Installed only in the Slack entry process, never its local intake children. The fake answers both transports of bin/fm_slack.py: the plain
    exchange (urllib.request.urlopen) and the bounded exchange of a caller with a total deadline (the second person's pass), which runs through a
    dedicated opener's .open (Slack._bounded, Slack._exchange). For the bounded one it models the fence as the real handlers do: nothing begins once the
    fence is closed or its time is spent, a begun exchange counts as connected (so a cut-off may have sent it), and closing the fence ends a held reply
    at once, as shutting down its socket does."""
    if Path(sys.argv[0]).name != 'fm_slack_watch.py':
        return
    sys.path.insert(0, str(ROOT / 'bin'))
    no_network_guard()
    from fm_slack_replay import Replay
    import urllib.request
    replay = Replay(Path(os.environ.get('FM_TEST_SLACK_TRANSCRIPT') or ROOT / 'tests/fixtures/slack/mirror/transcript.json'),
                    Path(os.environ['FM_STATE_OVERRIDE']) / 'slack-watch')
    scenario = os.environ.get('FM_TEST_SLACK_SCENARIO', '')
    requests = 0
    import _thread
    calls_open, guard = [0, 0.0, 0.0], _thread.allocate_lock()   # [calls of theirs open now, time they were open before, when the open span began]
    held_log = os.environ.get('FM_TEST_SLACK_TIMINGS', '') + '.held'
    if os.environ.get('FM_TEST_SLACK_CALL_CLOCK'):
        # Case A only (the watcher's no-progress stop of their check during a held call; Main 2813 (e)). Two things on a loaded host kept that stop from
        # ever coming, and neither is what the case is about:
        # - The clock of their time budget ran during the work before the held call (the entry shell, start-up, the binding checks, each 3 s on a loaded
        #   host): the held call got 3.9 s and 7.5 s of its budget, or none (119 s, no call begun). Here that clock (fm_slack_watch.monotonic, the plane's
        #   own name for it) moves only while a call of theirs is open, at the host clock's rate, and stands still between calls; every other reader of
        #   time.monotonic gets the host clock.
        # - Their call bound (10 s) ends a held call before the watcher can see it: the watcher marks progress at the sample that saw it, so it needs
        #   about 6 s plus two sampling intervals of silence, and one sample took 5.5 to 7.2 s on that host. Here, at the plane's first read of this
        #   clock, their call bound and their budget are set to the stall of the case (FM_TEST_SLACK_STALL, 60 s), and the transport's own 10 s wait on
        #   a silent socket (Slack._bounded) is the call's time left, so the held call is silent for the whole stall: the 6 s stop then comes for any
        #   sampling interval under 27 s.
        host_monotonic, origin = time.monotonic, []
        import fm_slack
        bounded_exchange = fm_slack.Slack._exchange

        def exchange(slack, request, timeout, opener=None, **more):
            return bounded_exchange(slack, request, max(timeout, slack.time_left()) if opener is not None else timeout, opener, **more)
        fm_slack.Slack._exchange = exchange

        def budget_clock():
            now = host_monotonic()
            caller = sys._getframe(1)
            if caller.f_code.co_name != 'monotonic' or caller.f_globals.get('__name__') != '__main__':
                return now
            with guard:
                if not origin:
                    origin.append(now)
                    caller.f_globals['SECOND_CALL_BOUND'] = caller.f_globals['SECOND_BUDGET'] = float(os.environ['FM_TEST_SLACK_STALL'])
                return origin[0] + calls_open[1] + (now - calls_open[2] if calls_open[0] else 0.0)
        time.monotonic = budget_clock

    def their_call(opening):
        # Counts the open calls of theirs for the budget clock above (and nothing else).
        now = time.monotonic()
        with guard:
            if opening:
                calls_open[0] += 1
                if calls_open[0] == 1:
                    calls_open[2] = now
            else:
                calls_open[0] -= 1
                if calls_open[0] == 0:
                    calls_open[1] += now - calls_open[2]

    class Response(io.BytesIO):
        headers = {'x-oauth-scopes': ','.join(replay.scopes)}

        def __exit__(self, *args):
            super().__exit__(*args)
            # Simulate lost scheduling time outside the request, after its body
            # has returned. One gap alone exceeds the removed 20-second budget.
            if scenario == 'slow' and requests == 1:
                time.sleep(21)

    def held(seconds, timeout, fence):
        """A reply Slack holds for `seconds`: a CPU-idle wait on a silent local socket (no listener, no external address). The socket timeout ends a
        wait as long as it (socket.timeout, as the real one). For a bounded exchange the socket is registered in the fence as the real handler registers
        its own, so closing the fence shuts it down and the wait ends at once."""
        with contextlib.ExitStack() as stack:
            reader, peer = socket.socketpair()
            stack.enter_context(reader)
            stack.enter_context(peer)
            reader.settimeout(min(seconds, timeout))
            if fence is not None:
                with fence.lock:
                    if fence.closed:
                        raise OSError('the exchange socket was shut down')
                    fence.duplicates.append(reader.dup())
            # Each held reply notes when it began and how it ended (ran its length, or cut by its fence); a stopped process notes no end.
            with open(held_log, 'a') as out:
                out.write('begun\n')
            try:
                if reader.recv(1) == b'':
                    with open(held_log, 'a') as out:
                        out.write('cut\n')
                    raise OSError('the exchange socket was shut down')
            except socket.timeout:
                with open(held_log, 'a') as out:
                    out.write('ran\n')
                if seconds >= timeout:
                    raise

    def priced(seconds, fence):
        """A reply that takes `seconds` of Slack time (Main 3345 (a): every call costs a stated time on the host clock): CPU-idle in 1 ms slices, since this
        host wakes a sleep of 20 ms or more about 0.145 s late (feasibility-overlap/margin-study/raw/sleep-overshoot.txt), and ended at once when its fence
        is closed at the caller's deadline, as a held reply is."""
        end = time.monotonic() + seconds
        while True:
            if fence is not None and fence.closed:
                raise OSError('the exchange socket was shut down')
            left = end - time.monotonic()
            if left <= 0:
                return
            if left > 0.025:
                time.sleep(0.001)

    def urlopen(request, timeout, fence=None):
        nonlocal requests
        if fence is not None:
            fence.check()                                     # closed, or no time left: never begun (DeadlineSpent, nothing sent)
            fence.connected = True                            # from here on the request may have reached Slack
        requests += 1
        method = request.full_url.rsplit('/', 1)[-1]
        fields = dict(urllib.parse.parse_qsl(request.data.decode()))
        for key, value in fields.items():
            # The transport (wire_body) sends an object, a list or a bool as JSON and every other value as its own string: a whole number goes back to an
            # int, and a Slack ts such as 2000.000100 stays the string it is.
            if value[:1] in ('{', '[') or value in ('true', 'false') or value.isdigit():
                with contextlib.suppress(ValueError):
                    fields[key] = json.loads(value)
        started = time.monotonic()
        second = fields.get('channel') == SECOND_DM or fields.get('users') == SECOND
        if second:
            their_call(True)
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
            if scenario == 'latency':
                # Slack itself is slow: the wait is idle, inside the request.
                time.sleep(LATENCY_SECONDS)
            if scenario == 'second-stall' and second:
                # A call of the second person's that Slack holds: idle, inside the request, for the stall the case sets.
                held(float(os.environ['FM_TEST_SLACK_STALL']), timeout, fence)
            if scenario == 'priced':
                # The replay's own work (a file-backed fake) comes first, then the reply waits what is left of its cost: a call takes its stated cost on the
                # host clock whatever the fake itself costs.
                body = replay.call(method, **fields)
                priced(float(os.environ['FM_TEST_SLACK_COST']) - (time.monotonic() - started), fence)
                return Response(json.dumps(body).encode())
            body = replay.call(method, **fields)
            return Response(json.dumps(body).encode())
        finally:
            if second:
                their_call(False)
            with open(os.environ['FM_TEST_SLACK_TIMINGS'], 'a') as out:
                out.write(json.dumps({'method': method, 'timeout': timeout, 'second': second, 'ts': fields.get('ts'), 'thread_ts': fields.get('thread_ts'),
                                      'started': started, 'seconds': time.monotonic() - started}) + '\n')

    def opener_open(opener, request, data=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):
        fence = next((handler.fence for handler in opener.handlers if hasattr(handler, 'fence')), None)
        return urlopen(request, timeout, fence)

    urllib.request.urlopen = urlopen
    urllib.request.OpenerDirector.open = opener_open


def main():
    with tempfile.TemporaryDirectory(prefix='fm-slack-deadline-') as tmp:
        home = Path(tmp)
        env = dict(os.environ, FM_HOME=tmp, FM_STATE_OVERRIDE=str(home / 'state'),
                   FM_DATA_OVERRIDE=str(home / 'data'), FM_CONFIG_OVERRIDE=str(home / 'config'),
                   SLACK_BOT_TOKEN='fixture-token-not-a-secret', FM_SLACK_DM_USER='U0TESTOWNER',
                   FM_SLACK_ALLOWED_AUTHORS='U0TESTOWNER', FM_SLACK_POLL_MAX_ANSWERS='20',
                   PYTHONDONTWRITEBYTECODE='1', FM_TEST_SLACK_NETWORK=str(home / 'network.jsonl'))
        # The children use the real transport class over the fake above; the guard, not FM_SLACK_NO_NETWORK, keeps them off the network.
        env.pop('FM_SLACK_NO_NETWORK', None)
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
        watched = subprocess.run(
            ['bash', '-c', '''
                . "$1"
                WATCHER_PID=$$
                trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
                watcher_beat force
                CHECK_TIMEOUT=$3
                FM_CHECK_SWEEP=$4; export FM_CHECK_SWEEP              # the watcher's token of this sweep (bin/fm-watch.sh)
                run_check_capture slack "$2" || exit 21
                printf 'status=%s stopped=%s notice=%s result=%s\\n' \
                  "$FM_CHECK_STATUS" "$FM_CHECK_STOPPED" "$FM_CHECK_STOP_NOTICE" "$FM_CHECK_RESULT"
             ''', '_', str(ROOT / 'bin/fm-watch.sh'), str(home / 'state/slack.check.sh'), str(NO_PROGRESS_SECONDS), 'latency.1'],
            env=dict(env, FM_TEST_SLACK_SCENARIO='latency'), capture_output=True, text=True)
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert watched.returncode == 0, watched
        assert watched.stdout == 'status=0 stopped= notice= result=\n', watched
        assert sum(row['seconds'] for row in rows) > NO_PROGRESS_SECONDS, rows
        assert all(row['seconds'] < row['timeout'] for row in rows), rows
        assert len(cards()) == 4, cards()
        print('ok - watcher lets %d requests of %ds each finish under a %ds no-progress bound'
              % (len(rows), LATENCY_SECONDS, NO_PROGRESS_SECONDS), flush=True)

        timings.write_text('')
        hung = invoke('check', scenario='hang')
        assert hung.stderr == '', hung.stderr  # a hung request is not progress
        first = hung.stdout
        assert first.count('slack: transport failure: unreachable') == 1, first
        assert command('check', scenario='hang') == ''
        assert len(cards()) == 4, cards()
        rows = [json.loads(line) for line in timings.read_text().splitlines()]
        assert rows, rows
        assert all(row['seconds'] >= row['timeout'] for row in rows), rows
        assert all(row['timeout'] == 10 for row in rows), rows
        # Default owner policy is 30s of no progress (fm-watch.sh). Each silent
        # read is CPU-idle, so the retained socket timeout must end it first.
        assert all(row['seconds'] < 30 for row in rows), rows
        assert command('check') == ''  # recovery clears the failure episode
        assert command('check', scenario='hang').count('transport failure: unreachable') == 1
        assert len(cards()) == 4, cards()
        print('ok - longest silent read ends after %.3fs, before owner no-progress bound 30s; one report per episode'
              % max(row['seconds'] for row in rows))
        print('hanging request timings: ' + json.dumps(rows))
        assert network_attempts(home / 'network.jsonl') == [], network_attempts(home / 'network.jsonl')


WATCH = '''
    . "$1"
    WATCHER_PID=$$
    trap "fm_active_check_stop; fm_check_output_cleanup" EXIT
    watcher_beat force
    [ -z "$3" ] || CHECK_TIMEOUT=$3
    # The watcher's token of this sweep, the same for the owner's check and the second person's check of one sweep and new for the next (bin/fm-watch.sh).
    FM_CHECK_SWEEP=$6
    export FM_CHECK_SWEEP
    run_check_capture "$5" "$2" || exit 21
    printf '%s' "$FM_CHECK_RESULT" > "$4"
    printf 'status=%s stopped=%s notice=%s\\n' "$FM_CHECK_STATUS" "$FM_CHECK_STOPPED" "$FM_CHECK_STOP_NOTICE"
'''


def home_for(tmp, second):
    home = Path(tmp)
    env = dict(os.environ, FM_HOME=tmp, FM_STATE_OVERRIDE=str(home / 'state'), FM_DATA_OVERRIDE=str(home / 'data'),
               FM_CONFIG_OVERRIDE=str(home / 'config'), SLACK_BOT_TOKEN='fixture-token-not-a-secret', FM_SLACK_DM_USER='U0TESTOWNER',
               FM_SLACK_ALLOWED_AUTHORS='U0TESTOWNER', FM_SLACK_POLL_MAX_ANSWERS='20', PYTHONDONTWRITEBYTECODE='1',
               FM_TEST_SLACK_TRANSCRIPT=str(ROOT / 'tests/fixtures/slack/second-person/transcript.json'),
               FM_TEST_SLACK_TIMINGS=str(home / 'timings.jsonl'), FM_TEST_SLACK_STALL='0', FM_TEST_SLACK_NETWORK=str(home / 'network.jsonl'))
    env.pop('FM_SLACK_NO_NETWORK', None)                 # the real transport class over the fake; the guard keeps it off the network
    env['FM_SLACK_SECOND_USER'] = SECOND if second else ''
    subprocess.run(['bash', str(ROOT / 'tests/fixtures/slack/make-home.sh'), 'intake', tmp], check=True, env=env, capture_output=True, text=True)
    hook = home / 'hook'
    hook.mkdir()
    (hook / 'sitecustomize.py').write_text('import fm_slack_deadline_test; fm_slack_deadline_test.install()\n')
    env['PYTHONPATH'] = os.pathsep.join([str(hook), str(ROOT / 'tests')])
    armed = subprocess.run(['bash', str(ROOT / 'bin/fm-slack-check.sh'), 'arm'], env=env, capture_output=True, text=True)
    assert armed.returncode == 0 and 'armed:' in armed.stdout, armed
    return home, env

def say(home, ts, user, text, channel=None):
    state = sorted((home / 'state/slack-watch').glob('replay-state-*.json'))
    assert len(state) == 1, state
    data = json.loads(state[0].read_text())
    message = {'ts': ts, 'user': user, 'text': text}
    if channel:
        message['channel'] = channel
    data['messages'].append(message)
    state[0].write_text(json.dumps(data))

def watch(home, env, scenario, sweep, stall=0, timeout='', check='slack', call_clock=False):
    # One watcher sweep runs the owner's check (slack) and then the second person's (slacksecond) with one token; a new sweep has a new token.
    (home / 'timings.jsonl').write_text('')
    (home / 'timings.jsonl.held').write_text('')
    result = home / 'result.txt'
    result.unlink(missing_ok=True)
    started = time.monotonic()
    run = subprocess.run(['bash', '-c', WATCH, '_', str(ROOT / 'bin/fm-watch.sh'), str(home / ('state/%s.check.sh' % check)), str(timeout), str(result), check, sweep],
                         env=dict(env, FM_TEST_SLACK_SCENARIO=scenario, FM_TEST_SLACK_STALL=str(stall), FM_TEST_SLACK_CALL_CLOCK='1' if call_clock else ''),
                         capture_output=True, text=True)
    elapsed = time.monotonic() - started
    assert run.returncode == 0, run
    line = run.stdout.strip().splitlines()[-1]
    rows = [json.loads(l) for l in (home / 'timings.jsonl').read_text().splitlines()]
    assert network_attempts(home / 'network.jsonl') == [], network_attempts(home / 'network.jsonl')
    return line, result.read_text() if result.exists() else '', rows, elapsed

def wakes(text, ts, user):
    return [l for l in text.splitlines() if l.startswith('check: slack request %s from %s: ' % (ts, user))]

def acks(home, channel, ts):
    rows = [json.loads(l) for l in (home / 'state/slack-watch/outbound.jsonl').read_text().splitlines()]
    return [r for r in rows if r.get('method') == 'chat.postMessage' and r.get('channel') == channel and r.get('thread_ts') == ts and 'error' not in r]


def second_person_watcher():
    """The receiving watcher's real capture and stop (bin/fm-watch.sh run_check_capture and fm_active_check_stop) around the standing Slack check, with the
    second person's Slack calls held by the fake transport. CI-only (the fixture home holds a synthetic .env; Ruling D). Each case uses a fresh home; the
    watcher stops only the check process group it starts itself.
    A: the owner's check delivers its wake with no call of theirs; a no-progress stop of their check during their held call discards only its output, and the
       next pass takes their request in, with the owner's wake never repeated.
    B: under the default no-progress bound their held calls get no check stopped: the owner's check delivers its wake, their calls begin only inside their
       time budget, and the next pass takes their request in.
    C: with the second person off, the owner's check wakes the owner and their check makes no call of theirs."""
    # Each watcher pass runs the owner's check (slack) and then the second person's (slacksecond), as the watcher runs registered checks one after another,
    # delivering each one's output when it exits (Main 1553): the owner's wake is delivered before any call of theirs begins.

    # A: their check is stopped during their held call; the owner's wake was already delivered by the owner's check, and the next pass takes their request in.
    with tempfile.TemporaryDirectory(prefix='fm-slack-second-stop-') as tmp:
        home, env = home_for(tmp, True)
        say(home, '2000.000100', 'U0TESTOWNER', 'an owner request')
        say(home, '2000.000200', SECOND, 'a second person request', SECOND_DM)
        line, result, rows, elapsed = watch(home, env, 'second-stall', 'a.1', stall=60, timeout=NO_PROGRESS_SECONDS)
        assert line == 'status=0 stopped= notice=', line                 # the owner's check ends without any call of theirs
        assert len(wakes(result, '2000.000100', 'U0TESTOWNER')) == 1, result
        assert not any(r['second'] for r in rows), rows
        # Their budget runs on the call clock (install): the held call begins with its whole call bound left, however long the work before it took.
        line, result, rows, elapsed = watch(home, env, 'second-stall', 'a.1', stall=60, timeout=NO_PROGRESS_SECONDS, check='slacksecond', call_clock=True)
        assert line.startswith('status=124 stopped=no progress notice=check slacksecond stopped after '), line
        assert result == '', result                                   # the watcher discards a stopped check's output
        # Stopped during their held call: a held reply of theirs began, and none ran its length or was cut by its fence before the stop.
        held = (home / 'timings.jsonl.held').read_text().split()
        assert held[:1] == ['begun'] and 'ran' not in held and 'cut' not in held, held
        line, result, rows, elapsed = watch(home, env, '', 'a.2')
        assert wakes(result, '2000.000100', 'U0TESTOWNER') == [], result  # delivered once, never again
        line, result, rows, elapsed = watch(home, env, '', 'a.2', check='slacksecond')
        assert line == 'status=0 stopped= notice=', line
        assert len(wakes(result, '2000.000200', SECOND)) == 1, result
        assert len(acks(home, OWNER_DM, '2000.000100')) == 1
        assert len(acks(home, SECOND_DM, '2000.000200')) == 1
    print('ok - the owner check delivers its wake before any call of theirs, and a stopped second-person check is recovered by the next pass', flush=True)

    # B: under the default bound their held calls get no check stopped: the owner's check delivers its wake, and their check's calls begin only inside their
    # time budget; the next pass takes their request in.
    with tempfile.TemporaryDirectory(prefix='fm-slack-second-budget-') as tmp:
        home, env = home_for(tmp, True)
        say(home, '2000.000100', 'U0TESTOWNER', 'an owner request')
        say(home, '2000.000200', SECOND, 'a second person request', SECOND_DM)
        line, result, rows, elapsed = watch(home, env, 'second-stall', 'b.1', stall=9)
        assert line == 'status=0 stopped= notice=', line
        assert len(wakes(result, '2000.000100', 'U0TESTOWNER')) == 1, result
        line, result, rows, elapsed = watch(home, env, 'second-stall', 'b.1', stall=9, check='slacksecond')
        assert line == 'status=0 stopped= notice=', line
        theirs = [r for r in rows if r['second']]
        # A call of theirs begins only inside the 27 s budget of their pass, and not when the slowest call of theirs so far would end after it: two held
        # 9 s calls fit, and a third, which would begin at about 18 s and end at about 27 s, is not begun.
        assert 1 <= len(theirs) <= 2, rows
        line, result, rows, elapsed = watch(home, env, '', 'b.2')
        assert wakes(result, '2000.000100', 'U0TESTOWNER') == [], result  # delivered once, never again
        line, result, rows, elapsed = watch(home, env, '', 'b.2', check='slacksecond')
        assert len(wakes(result, '2000.000200', SECOND)) == 1, result
        assert len(acks(home, OWNER_DM, '2000.000100')) == 1
        assert len(acks(home, SECOND_DM, '2000.000200')) == 1
    print('ok - under the default bound the real watcher is never made to stop a check by held calls of the second person', flush=True)

    # C: control, the second person off: the owner's check wakes the owner and their check makes no call of theirs.
    with tempfile.TemporaryDirectory(prefix='fm-slack-second-off-') as tmp:
        home, env = home_for(tmp, False)
        say(home, '2000.000100', 'U0TESTOWNER', 'an owner request')
        say(home, '2000.000200', SECOND, 'a second person request', SECOND_DM)
        line, result, rows, elapsed = watch(home, env, 'second-stall', 'c.1', stall=60)
        assert line == 'status=0 stopped= notice=', line
        assert len(wakes(result, '2000.000100', 'U0TESTOWNER')) == 1, result
        line, result, rows, elapsed = watch(home, env, 'second-stall', 'c.1', stall=60, check='slacksecond')
        assert wakes(result, '2000.000200', SECOND) == [] and not any(r['second'] for r in rows), (result, rows)
    print('ok - with the second person off the owner check wakes the owner and no call of theirs is made', flush=True)



def second_person_liveness():
    """D (Main 3345 (a), Main 3350): SC8 (6) LIVENESS at the default C on the real watcher path, every Slack call 1.0 s on the host clock."""
    # D: SC8 (6) LIVENESS on the real watcher path (Main 3345 (a), Main 3350): at the default C = 20, every Slack call 1.0 s on the host clock, the plane's
    # constants as shipped, 3C = 60 new requests of theirs and 60 request threads of theirs (journaled before), no owner load: within 3 sweeps every new
    # request is acknowledged once in its own thread and its wake line journaled for delivery, and every thread is read. Their posts begin at least 1.0 s
    # apart (the strict documented rate), so this holds only when the 20 acknowledgements of a pass overlap their bookkeeping and the thread reads run beside them.
    with tempfile.TemporaryDirectory(prefix='fm-slack-second-liveness-') as tmp:
        home, env = home_for(tmp, True)
        threads = ['2100.%06d' % (n + 1) for n in range(60)]
        for n, ts in enumerate(threads):
            say(home, ts, SECOND, 'their earlier request %d' % n, SECOND_DM)
        build = dict(env, FM_SLACK_POLL_MAX_ANSWERS='200')
        for n in range(8):
            watch(home, build, '', 'd.build.%d' % n)
            watch(home, build, '', 'd.build.%d' % n, check='slacksecond')
            if all(len(acks(home, SECOND_DM, ts)) == 1 for ts in threads):
                break
        assert all(len(acks(home, SECOND_DM, ts)) == 1 for ts in threads), 'the 60 threads were not taken in before the case'
        requests = ['2200.%06d' % (n + 1) for n in range(60)]
        for n, ts in enumerate(requests):
            say(home, ts, SECOND, 'their new request %d' % n, SECOND_DM)
        priced_env = dict(env, FM_TEST_SLACK_COST='1.0')
        read, printed, per_sweep = set(), [], []
        for n in range(1, 4):
            watch(home, priced_env, 'priced', 'd.%d' % n)
            line, result, rows, elapsed = watch(home, priced_env, 'priced', 'd.%d' % n, check='slacksecond')
            assert line == 'status=0 stopped= notice=', line
            theirs = [r for r in rows if r['second']]
            reads = {r['ts'] for r in theirs if r['method'] == 'conversations.replies' and r['ts'] in threads}
            posts = sorted(r['started'] for r in theirs if r['method'] == 'chat.postMessage')
            read |= reads
            printed += [ts for ts in requests if wakes(result, ts, SECOND)]
            if os.environ.get('FM_TEST_SLACK_DUMP'):
                Path(os.environ['FM_TEST_SLACK_DUMP'], 'sweep-%d.jsonl' % n).write_text(''.join(json.dumps(r) + '\n' for r in rows))
                Path(os.environ['FM_TEST_SLACK_DUMP'], 'sweep-%d.result.txt' % n).write_text(result)
            per_sweep.append({'sweep': n, 'posts': len(posts), 'reads': len(reads), 'check_seconds': round(elapsed, 2),
                              'shortest_post_gap': round(min((b - a for a, b in zip(posts, posts[1:])), default=0.0), 3)})
            assert all(b - a >= 1.0 - 0.002 for a, b in zip(posts, posts[1:])), ('their posts began less than 1.0 s apart', posts)
        journal = json.loads((home / 'state/slack-watch/second.json').read_text())
        journaled = [ts for ts in requests if any(wakes(l, ts, SECOND) for l in journal.get('outbox', []))]
        print('case D per sweep: %s; wake lines printed %d, journaled for delivery %d' % (per_sweep, len(printed), len(journaled)), flush=True)
        assert all(len(acks(home, SECOND_DM, ts)) == 1 for ts in requests), [ts for ts in requests if len(acks(home, SECOND_DM, ts)) != 1]
        assert sorted(set(printed) | set(journaled)) == requests and not set(printed) & set(journaled), (printed, journaled)
        assert read == set(threads), sorted(set(threads) - read)
    print('ok - at C = 20 and 1.0 s a call, 60 new requests of theirs are acknowledged and woken for delivery and 60 threads read within 3 sweeps', flush=True)


def second_person_owner_release():
    """E (Main 3345 (1), Main 3350): the real watcher loop (bin/fm-watch-checkpoint.sh around bin/fm-watch.sh) over the armed home, every Slack call 1.0 s on
    the host clock, the plane's constants as shipped: the owner's wake, queued by the owner's check, is released before the second person's check runs,
    within OWNER_WAKE_WAIT_BOUND of the sweep's start; the next watcher run resumes that sweep at their check (their request is taken in once), and the
    owner's wake is never released twice."""
    sys.path.insert(0, str(ROOT / 'bin'))
    import fm_slack_watch as plane
    with tempfile.TemporaryDirectory(prefix='fm-slack-second-release-') as tmp:
        home, env = home_for(tmp, True)
        # The running Firstmate session is this test's process (its pid in state/.lock): the released sweep is resumed only in that session.
        (home / 'state/.lock').write_text('%d\n' % os.getpid())
        say(home, '2000.000100', 'U0TESTOWNER', 'an owner request')
        say(home, '2000.000200', SECOND, 'a second person request', SECOND_DM)
        run_env = dict(env, FM_TEST_SLACK_SCENARIO='priced', FM_TEST_SLACK_COST='1.0', FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='300')
        (home / 'timings.jsonl').write_text('')
        started = time.monotonic()
        first = subprocess.run(['bash', str(ROOT / 'bin/fm-watch-checkpoint.sh'), '--seconds', '120'], env=run_env, capture_output=True, text=True)
        waited = time.monotonic() - started
        assert first.returncode == 0, first
        assert 'from U0TESTOWNER' in first.stdout and 'from %s' % SECOND not in first.stdout, first.stdout
        rows = [json.loads(l) for l in (home / 'timings.jsonl').read_text().splitlines()]
        assert not any(r['second'] for r in rows), rows                   # their check had not begun when the owner's wake was released
        assert waited <= plane.OWNER_WAKE_WAIT_BOUND, waited
        assert (home / 'state/.check-sweep-resume').is_file()
        drain = subprocess.run(['bash', str(ROOT / 'bin/fm-wake-drain.sh')], env=run_env, capture_output=True, text=True)
        ack = re.search(r'--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)', drain.stderr)
        assert drain.returncode == 0 and ack, drain
        acked = subprocess.run(['bash', str(ROOT / 'bin/fm-wake-drain.sh'), '--ack-through', ack.group(1), '--recovery-generation', ack.group(2)],
                               env=run_env, capture_output=True, text=True)
        assert acked.returncode == 0, acked
        second = subprocess.run(['bash', str(ROOT / 'bin/fm-watch-checkpoint.sh'), '--seconds', '120'], env=run_env, capture_output=True, text=True)
        assert second.returncode == 0, second
        assert 'from %s' % SECOND in second.stdout and 'from U0TESTOWNER' not in second.stdout, second.stdout
        assert not (home / 'state/.check-sweep-resume').exists()
        assert len(acks(home, OWNER_DM, '2000.000100')) == 1 and len(acks(home, SECOND_DM, '2000.000200')) == 1
        assert network_attempts(home / 'network.jsonl') == [], network_attempts(home / 'network.jsonl')
    print('ok - the owner wake is released after %.1fs without waiting for the second person check, and the next watcher run takes their request in once' % waited, flush=True)


if __name__ == '__main__':
    cases = os.environ.get('FM_TEST_SLACK_DEADLINE_CASES', 'main,second,liveness,release').split(',')
    if 'main' in cases:
        main()
    if 'second' in cases:
        second_person_watcher()
    if 'liveness' in cases:
        second_person_liveness()
    if 'release' in cases:
        second_person_owner_release()
