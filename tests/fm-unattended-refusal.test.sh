#!/usr/bin/env bash
# A refusal handed to Firstmate is an event, not a worker decision.
# Exercise the three consumers that must still hold on worker-written decisions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-unattended-refusal)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json, os, shutil, subprocess, sys, time
from pathlib import Path

root, world = map(Path, sys.argv[1:])
failures = []
now = int(time.time())

def script(path, text):
    path.write_text('#!/usr/bin/env bash\n' + text)
    path.chmod(0o755)

for consumer in ('pending', 'retry', 'checkin'):
    for origin in ('worker', 'refusal'):
        label = consumer + '-' + origin
        home = world / label
        fake = home / 'fakebin'
        for name in ('state', 'config', 'data', 'projects', 'fakebin'):
            (home / name).mkdir(parents=True, exist_ok=True)
        (home / 'config/wait-no-turns').touch()
        status = home / 'state/worker.status'
        (home / 'state/worker.meta').write_text('kind=ship\nbackend=tmux\nwindow=sess:fm-worker\nharness=claude\n')
        (home / 'state/other.meta').write_text('kind=ship\nbackend=tmux\nwindow=sess:fm-other\nharness=claude\n')
        (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        script(fake / 'tmux', '''case "$1" in
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  display-message) printf '1\n' ;;
  list-windows) printf 'fm-worker\nfm-other\n' ;;
  send-keys) printf '%s\n' "$*" >> "$FM_TEST_RING_LOG" ;;
esac
''')
        env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
                   FM_STATE_OVERRIDE=str(home / 'state'), FM_CONFIG_OVERRIDE=str(home / 'config'),
                   FM_PENDING_REPLY_NOW=str(now), FM_PENDING_REPLY_GRACE_SECS='0',
                   FM_TASK_INBOX_GRACE_SECS='1', FM_SEND_SETTLE='0',
                   FM_OPEN_LOOPS_NOW=str(now + 1000), NM_HOME=str(home / 'nm'),
                   FM_TEST_RING_LOG=str(home / 'rings'), FM_TEST_RECOVERY_LOG=str(home / 'recovery'),
                   FM_GUARD_EVENT_LOG=str(home / 'guard-events'), PATH=f'{fake}:{os.environ["PATH"]}')
        def call(*args, check=True):
            result = subprocess.run([str(x) for x in args], env=env, text=True, capture_output=True)
            if check and result.returncode:
                raise AssertionError((args, result.returncode, result.stdout, result.stderr))
            return result
        def bash(text, *args, check=True):
            return call('bash', '-c', text, '_', root, home, *args, check=check)
        try:
            if consumer == 'pending':
                bash('''. "$1/bin/fm-pending-reply-lib.sh"
                    corr=$(fm_pending_reply_create "$2" "$2/state" worker 'report the result')
                    fm_pending_reply_mark_delivered "$2/state" "$corr"
                    fm_pending_reply_observe_busy "$2/state" "$corr" busy
                    fm_pending_reply_observe_busy "$2/state" "$corr" idle
                    printf '%s' "$corr" > "$2/corr"''')
            elif consumer == 'retry':
                bash('''. "$1/bin/fm-task-inbox-lib.sh"
                    rec=$(fm_task_inbox_write "$2/state" worker 'owed steer' fire-and-forget)
                    fm_task_inbox_mark_retry "$2/state" worker "$rec"
                    touch -t 202001010000 "$rec" "$2/state/worker.inbox/.retry-ring"''')
            if origin == 'worker':
                status.write_text(f'needs-decision [at={now - 1000}] [key=unattended-steer]: choose the scope\n')
            else:
                result = call('bash', root / 'bin/fm-send-unattended.sh', 'worker', 'Continue other', check=False)
                assert result.returncode not in (0, 3), result
                assert "Send to 'other'" in result.stderr, result.stderr
                assert 'Instruction argv:' in status.read_text(), status.read_text()
                assert not (home / 'rings').exists(), 'refusal delivered a doorbell'
            if consumer == 'pending':
                bash('''. "$1/bin/fm-pending-reply-lib.sh"
                    corr=$(cat "$2/corr")
                    export FM_PENDING_REPLY_SEND_HOOK='printf recovery >> "$FM_TEST_RECOVERY_LOG"'
                    fm_pending_reply_send_recovery "$2/state" "$corr" || :''')
                fired = (home / 'recovery').exists()
                phase = bash('''. "$1/bin/fm-pending-reply-lib.sh"
                    fm_pending_reply_get "$2/state/pending-replies/$(cat "$2/corr")" phase''').stdout.strip()
                assert fired == (origin == 'refusal'), (label, fired, phase)
                assert phase == ('recovery_sent' if fired else 'awaiting_report'), (label, phase)
            elif consumer == 'retry':
                bash('''. "$1/bin/fm-watch.sh"
                    fm_backend_agent_state() { printf alive; }
                    inbox_steer_check sess:fm-worker worker''')
                fired = (home / 'rings').exists()
                assert fired == (origin == 'refusal'), (label, fired)
                assert (home / 'state/worker.inbox/.retry-ring').exists() == (origin == 'worker'), label
            else:
                code = home / 'code'
                shutil.copytree(root / 'bin', code / 'bin')
                snapshot = dict(schema='fm-fleet-home-input.v1', backlog=dict(present=True, records=[]), tasks=[
                    dict(id='worker', kind='ship', project=None, branch=None, backend='tmux',
                         current_state=dict(state='working', source='pane'), endpoint=dict(exists=True, agent_alive='alive'),
                         pr=dict(url=None), paths=dict(worktree=dict(path=None)), hints={})])
                (home / 'snapshot.json').write_text(json.dumps(snapshot))
                script(code / 'bin/fm-fleet-snapshot.sh', 'cat "$FM_HOME/snapshot.json"\n')
                script(code / 'bin/fm-crew-state.sh', "printf 'state: working · source: pane · building\\n'\n")
                report = json.loads(call('bash', code / 'bin/fm-open-loops.sh', '--json').stdout)
                assert report['complete'], report
                row = next(r for r in report['rows'] if r['category'] == 'silent_report')
                assert row['overdue'] == (origin == 'refusal'), (label, row)
                assert bool(row.get('informational')) == (origin == 'worker'), (label, row)
            if origin == 'refusal':
                opened = bash('''. "$1/bin/fm-classify-lib.sh"
                    printf 'all=%s\nown=%s\n' "$(status_open_decisions "$2/state/worker.status")" "$(status_own_open_decisions "$2/state/worker.status")"''').stdout
                assert opened == 'all=\nown=\n', (label, opened)
                before = status.read_bytes()
                # A healthy command would send, but the prior refusal must hold it without an open decision.
                result = call('bash', root / 'bin/fm-send-unattended.sh', 'worker', 'Continue work', check=False)
                assert result.returncode == 1 and 'no send attempted' in result.stderr, result
                assert status.read_bytes() == before, 'held attempt duplicated its refusal event'
                with status.open('a') as out:
                    out.write('resolved [key=unattended-steer]: Firstmate handled the refusal\n')
                result = call('bash', root / 'bin/fm-send-unattended.sh', 'worker', 'Continue work')
                inbox = home / 'state/worker.inbox'
                records = list(inbox.glob('*.msg'))
                assert any('Continue work' in record.read_text() for record in records), 'answer did not release the send'
            print('PASS:', label, flush=True)
        except (AssertionError, StopIteration) as error:
            failures.append(label)
            print('FAIL:', label, repr(error), flush=True)
assert not failures, failures
PY
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import os, subprocess, sys
from pathlib import Path

root, world = map(Path, sys.argv[1:])
home = world / 'hold-scan'
fake = home / 'fakebin'
for name in ('state', 'config', 'data', 'projects', 'fakebin'):
    (home / name).mkdir(parents=True, exist_ok=True)
(home / 'state/worker.meta').write_text('kind=ship\nbackend=tmux\nwindow=sess:fm-worker\nharness=claude\n')
(fake / 'tmux').write_text('#!/usr/bin/env bash\n'
                           'case "$1" in\n'
                           "  capture-pane) printf '╭────╮\\n│    │\\n╰────╯\\n' ;;\n"
                           "  display-message) printf '1\\n' ;;\n"
                           "  list-windows) printf 'fm-worker\\n' ;;\n"
                           'esac\n')
(fake / 'tmux').chmod(0o755)
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(home),
           FM_STATE_OVERRIDE=str(home / 'state'), FM_CONFIG_OVERRIDE=str(home / 'config'),
           FM_SEND_SETTLE='0', NM_HOME=str(home / 'nm'),
           FM_GUARD_EVENT_LOG=str(home / 'guard-events'), PATH=f'{fake}:{os.environ["PATH"]}')
status = home / 'state/worker.status'
noise = ''.join(f'note [key=other-{i}]: unattended-refusal: annotate notes {i}\nresolved [key=other-{i}]: resolved notes\n'
                for i in range(1500))
noise += 'working: prose names unattended-steer without a key\n'
refusal = "note [key=unattended-steer]: unattended-refusal: error: refused task 'other'\n"
handled = 'resolved [key=unattended-steer]: handled\n'
cases = [
    ('noise only', noise, False),
    ('refusal after noise', noise + refusal, True),
    ('other key resolved', noise + refusal + 'resolved [key=other]: answered\n', True),
    ('own key resolved', noise + refusal + handled, False),
    ('note-head key', noise + "note: [key=unattended-steer] unattended-refusal: error: refused task 'other'\n", True),
    ('unrelated own-key note', noise + 'note [key=unattended-steer]: a plain remark\n', False),
    ('refusal after resolution', noise + refusal + handled + refusal, True),
]
failures = []
for label, text, held in cases:
    status.write_text(text)
    result = subprocess.run(['bash', str(root / 'bin/fm-send-unattended.sh'), 'worker', 'Continue work'],
                            env=env, text=True, capture_output=True)
    got_hold = result.returncode == 1 and 'no send attempted' in result.stderr
    got_send = result.returncode == 0
    if got_hold != held or got_send == held or status.read_text() != text:
        failures.append(label)
        print('FAIL: hold-scan', label, result.returncode, result.stderr, flush=True)
    else:
        print('PASS: hold-scan', label, flush=True)
assert not failures, failures
PY
