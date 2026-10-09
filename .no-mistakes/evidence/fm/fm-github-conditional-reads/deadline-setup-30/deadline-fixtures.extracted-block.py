# Overall deadlines escape every reader's normal error recovery and stop later work.
for reader in ('origins', 'pr-checks', 'pr-state', 'questions'):
    deadline_root = world / ('deadline-' + reader)
    deadline_home, deadline_code, deadline_bin = (deadline_root / n for n in ('home', 'code', 'fakebin'))
    for name in ('state', 'data', 'config', 'projects'):
        (deadline_home / name).mkdir(parents=True)
    deadline_bin.mkdir()
    shutil.copytree(code / 'bin', deadline_code / 'bin')
    (deadline_home / 'config/open-loops.json').write_text(json.dumps(dict(command_timeout_seconds=1)))
    deadline_tasks = []
    if reader == 'pr-state':
        deadline_tasks = [task('failed-' + str(i), deadline_root / 'absent', state='failed', pr=PR_URL + str(i))
                          for i in range(24)]
        for deadline_task in deadline_tasks:
            deadline_task['project'] = None
    if reader in ('origins', 'pr-checks'):
        for i in range(24 if reader == 'origins' else 1):
            (deadline_home / 'projects' / str(i) / '.git').mkdir(parents=True)
    if reader == 'questions':
        for i in range(24):
            (deadline_home / 'state' / (str(i) + '.status')).write_text('needs-decision [key=q]: question\n')
    (deadline_home / 'attempts').write_text('')
    (deadline_home / 'snapshot.json').write_text(json.dumps(dict(schema='fm-fleet-home-input.v1',
        tasks=deadline_tasks, backlog=dict(present=True, records=(
            [dict(id='owns-prs', structured=True, state='done', links=[PR_URL + str(i) for i in range(24)])]
            if reader == 'pr-checks' else [])))))  # owned PRs are the ones whose checks are fetched
    script(deadline_code / 'bin/fm-fleet-snapshot.sh', '#!/usr/bin/env python3\n'
           'import os\nfrom pathlib import Path\nhome = Path(os.environ["FM_HOME"])\n'
           '(home / "collector-pid").write_text(str(os.getppid()))\nprint((home / "snapshot.json").read_text())\n')
    driver = r'''#!/usr/bin/env python3
import base64, json, os, signal, sys, time
from pathlib import Path
reader, command = os.environ['DEADLINE_READER'], Path(sys.argv[0]).name
if command == 'git' and reader != 'origins':
    print('https://github.com/test/project.git' if '--get' in sys.argv else '.git')
    sys.exit(0)
if command == 'git' and '--get' not in sys.argv:
    print('.git')
    sys.exit(0)
if command == 'gh' and '/pulls?' in sys.argv[-1]:
    pulls = [] if reader == 'pr-state' else [dict(number=i, html_url='https://github.com/test/project/pull/' + str(i),
                  head=dict(sha='a' * 40), state='open') for i in range(24)]
    sys.stdout.write('HTTP/2.0 200 OK\r\n\r\n' + json.dumps(pulls))
    sys.exit(0)
attempts = Path(os.environ['FM_HOME']) / 'attempts'
with attempts.open('a') as stream:
    stream.write(json.dumps([command, *sys.argv[1:]]) + '\n')
if len(attempts.read_text().splitlines()) == 2:
    (attempts.parent / 'deadline-trigger').write_text(json.dumps([command, *sys.argv[1:]]))
    os.kill(int((attempts.parent / 'collector-pid').read_text()), signal.SIGALRM)
time.sleep(0.7)
print('source command failure', file=sys.stderr)
sys.exit(1)
'''
    for command in (('git', 'gh', 'cat') if reader == 'questions' else ('git', 'gh')):
        script(deadline_bin / command, driver)
    deadline_env = dict(env, FM_HOME=str(deadline_home), DEADLINE_READER=reader,
                        PATH=f'{deadline_bin}:{env["PATH"]}')
    deadline_report = json.loads(out([deadline_code / 'bin/fm-open-loops.sh', '--heartbeat', '--json'],
                                    env=deadline_env, timeout=60))
    assert not deadline_report['complete'] and len(rows(deadline_report, 'coverage')) == 1, deadline_report
    assert 'collection exceeded its deadline' in rows(deadline_report, 'coverage')['ledger degraded']['evidence']
    attempts = [json.loads(line) for line in (deadline_home / 'attempts').read_text().splitlines()]
    expected_requests = {
        'origins': [['git', '-C', str(deadline_home / 'projects' / str(i)),
                     'config', '--get', 'remote.origin.url'] for i in range(24)],
        'pr-checks': [['gh', 'api', '-i',
                       'repos/test/project/commits/' + 'a' * 40 + '/check-runs?per_page=100']],
        'pr-state': [['gh', 'api', '-i', 'repos/test/project/pulls/' + str(i)] for i in range(24)],
        'questions': [['cat', str(deadline_home / 'state' / (str(i) + '.status'))] for i in range(24)],
    }
    assert len(attempts) == 2 and all(request in expected_requests[reader] for request in attempts), (reader, attempts)
    assert json.loads((deadline_home / 'deadline-trigger').read_text()) == attempts[-1], (reader, attempts)
    assert json.loads((deadline_home / 'state/open-loops.json').read_text()) == deadline_report
    print('PASS: deadline escapes ' + reader + ' source recovery', flush=True)
