"""Launch gate through an isolated launcher copy (scratch only; never ~/.no-mistakes). argv: REPO PARENT PYTHON."""
import fcntl, json, os, re, signal, subprocess, sys, time
sys.path.insert(0, os.environ['FIXTURE_DIR'])
import fm_cpu_pass_fixture as fx
from fm_cpu_pass_fixture import *  # noqa
GIB = fx.GIB
import atexit; atexit.register(fx.cleanup)
lab = fx.root / 'launcher'; lab.mkdir()
standin = lab / 'claude'
standin.write_text('#!%s\n# stand-in for tc run -> teamclaude: a dispatcher that FORKS the agent as its child and waits (no exec,\n# no signal handlers), then returns its exit status. No network, no proxy.\nimport os, subprocess, sys\nc = subprocess.Popen([%r, %r, os.environ["STANDIN_RUN"]] + sys.argv[1:])\nopen(os.path.join(os.environ["CASE_FOLDER"], "dispatcher.pid"), "w").write(str(os.getpid()))\nrc = c.wait()\nsys.exit(rc if rc >= 0 else 128 - rc)\n' % (fx.python, fx.python, str(fx.agent)))
standin.chmod(0o755)
gate_cmd = '%s/bin/fm-cpu-pass.sh' % fx.repo
def launcher(name, target):
    p = lab / name
    p.write_text('#!/bin/bash\n# isolated copy of the agent launcher: only the final exec line matters here\nexec %s launch-gate -- %s "$@"\n' % (gate_cmd, target))
    p.chmod(0o755); return p
copy = launcher('claude-teamclaude', str(standin))
missing = launcher('claude-teamclaude-missing', str(lab / 'no-such-claude'))
print('synthesized launcher final line:', copy.read_text().splitlines()[-1])
print('stand-in agent wrapper (forks, waits):'); print(standin.read_text())
def call(folder, env, run, cwd=None, mode='wait', stdin=b'prompt on stdin', lp=copy, tag=None):
    tag = tag or run
    log = folder / ('l-' + tag)
    e = dict(env, CASE_AGENT=mode, STANDIN_RUN=run)
    if e.get('CASE_DAEMON_ROWS'):
        e.update(CASE_SESSION_ID='session-%s-%d' % (tag, len(fx.records)), CASE_DAEMON_ROW='1')
    out, err = open(str(log) + '.stdout', 'w'), open(str(log) + '.stderr', 'w')
    # as the daemon: argv shape, prompt on stdin, run worktree as cwd, own process group
    child = subprocess.Popen([str(lp), '-p', '--output-format', 'stream-json'], env=e, stdin=subprocess.PIPE, stdout=out, stderr=err,
                             cwd=str(cwd or folder / ('wt-' + run)), start_new_session=True)
    out.close(); err.close(); child.stdin.write(stdin); child.stdin.close()
    fx.children.append(child); fx.records.append(dict(command=['launcher', run], stdout=str(log) + '.stdout', stderr=str(log) + '.stderr'))
    return child, log
def text(log): return log.with_suffix('.stderr').read_text() if log.with_suffix('.stderr').exists() else (str(log) + '.stderr' and open(str(log) + '.stderr').read())
def err(log): return open(str(log) + '.stderr').read()
def lock_free(folder):
    p = folder / 'pool' / 'pipeline-start.lock'
    if not p.exists(): return True
    fd = os.open(str(p), os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); return True
    except OSError: return False
    finally: os.close(fd)
def wait_exit(child, secs):
    t = time.monotonic()
    while child.poll() is None and time.monotonic() - t < secs: time.sleep(0.05)
    return child.poll()
def show(title, lines):
    print('=== ' + title); [print('  ' + l) for l in lines]; print()
def gl(s): return [l[:300] for l in s.splitlines() if 'launch-gate' in l]

# L1 admitted ci fix launch: streams, argv, cwd and exit status pass through; timestamps of the admit sequence
folder, db, env = gate_case('l1')
c, log = call(folder, env, 'x', mode='exit-3')
rc = wait_exit(c, 120); info = json.loads((folder / 'x.agent').read_text())
m = re.search(r'admitted_ns=(\d+) published_ns=(\d+) agent_started_ns=(\d+) unlocked_ns=(\d+)', err(log))
seq = 'published<=unlocked: %s; agent_started<=unlocked: %s' % (int(m.group(2)) <= int(m.group(4)), int(m.group(3)) <= int(m.group(4))) if m else 'no timestamps'
show('L1 ci fix launch fits -> admitted (expect exit 3 = agent exit)', ['exit=%s' % rc, 'agent saw stdin=%r argv=%r cwd=%s' % (info['stdin'], info['argv'], info['cwd']), seq] + gl(err(log)) + ['start lock free after: %s' % lock_free(folder)])

# L2 non-ci step of a counted run passes through
folder, db, env = gate_case('l2', runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
c, log = call(folder, env, 'y', mode='exit-0'); rc = wait_exit(c, 120)
show('L2 review-step launch of counted run y -> passes through at once (expect exit 0, no hold)', ['exit=%s agent ran=%s' % (rc, (folder / 'y.agent').exists())] + gl(err(log)))

# L3 unmapped worktree refuses visibly
(folder / 'elsewhere').mkdir()
c, log = call(folder, env, 'nowhere', cwd=folder / 'elsewhere', mode='exit-0', tag='unmapped'); rc = wait_exit(c, 120)
show('L3 unmapped worktree -> refused (expect exit 75, agent never starts, durable wake)', ['exit=%s agent ran=%s' % (rc, (folder / 'nowhere.agent').exists())] + gl(err(log)) + ['wake: ' + l[:300] for l in wakes(folder).splitlines() if 'unmapped' in l][:1])

# L4 hold then admitted by itself when capacity returns
folder, db, env = gate_case('l4', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)])
c, log = call(folder, env, 'x', mode='exit-0')
t = time.monotonic()
while 'waiting' not in err(log) and time.monotonic() - t < 120: time.sleep(0.1)
held = c.poll() is None and not (folder / 'x.agent').exists()
facts(folder, available=40 * GIB)
rc = wait_exit(c, 120)
show('L4 no room -> holds; capacity returns -> admitted by itself (expect exit 0)', ['held with agent not started: %s' % held, 'exit=%s agent ran=%s' % (rc, (folder / 'x.agent').exists())] + gl(err(log))[:3] + ['wake: ' + l[:300] for l in wakes(folder).splitlines() if 'launch-gate' in l])

# L5 hold bound reached -> refused, agent never starts
folder, db, env = gate_case('l5', available=GIB, runs=[('x', 'ci', 'running', None), ('y', 'review', 'running', None)], timeout='4s', ci_ms=(1000,))
c, log = call(folder, env, 'x', mode='exit-0'); rc = wait_exit(c, 120)
show('L5 budget 4s, CI-fix p99 1s, no room -> refused at bound (expect exit 75, no agent)', ['exit=%s agent ran=%s lock free=%s' % (rc, (folder / 'x.agent').exists(), lock_free(folder))] + gl(err(log)) + ['wake: ' + l[:300] for l in wakes(folder).splitlines() if 'launch-gate' in l])

# L6 the daemon's cancel: group kill mid-run
folder, db, env = gate_case('l6')
c, log = call(folder, env, 'x', mode='wait')
t = time.monotonic()
while not (folder / 'x.agent').exists() and time.monotonic() - t < 120: time.sleep(0.05)
time.sleep(0.3); apid = json.loads((folder / 'x.agent').read_text())['pid']
os.killpg(c.pid, signal.SIGKILL); c.wait()
t = time.monotonic()
while alive(apid) and time.monotonic() - t < 10: time.sleep(0.05)
show('L6 group kill while agent runs (expect no agent left, lock free)', ['agent pid %d alive after: %s' % (apid, alive(apid)), 'lock free=%s' % lock_free(folder)])

# L7 gate alone SIGKILLed mid-run
folder, db, env = gate_case('l7')
c, log = call(folder, env, 'x', mode='wait')
t = time.monotonic()
while not (folder / 'x.agent').exists() and time.monotonic() - t < 120: time.sleep(0.05)
time.sleep(0.3); apid = json.loads((folder / 'x.agent').read_text())['pid']
os.kill(c.pid, signal.SIGKILL); c.wait()
t = time.monotonic()
while alive(apid) and time.monotonic() - t < 10: time.sleep(0.05)
gone = time.monotonic() - t
show('L7 SIGKILL to the gate process alone (expect agent ends, lock free)', ['gate pid %d (the launcher exec\'d into it); agent pid %d alive after: %s (%.2fs)' % (c.pid, apid, alive(apid), gone), 'lock free=%s' % lock_free(folder)])

# L8 agent cannot be launched
folder, db, env = gate_case('l8')
c, log = call(folder, env, 'x', lp=missing); rc = wait_exit(c, 120)
show('L8 missing claude binary (expect 127, lock free)', ['exit=%s lock free=%s' % (rc, lock_free(folder))] + gl(err(log)))

# L9 signal forwarding: SIGTERM to gate reaches agent
folder, db, env = gate_case('l9')
c, log = call(folder, env, 'x', mode='trap')
t = time.monotonic()
while not (folder / 'x.agent').exists() and time.monotonic() - t < 120: time.sleep(0.05)
time.sleep(0.3)
for _ in range(50):
    if (folder / 'x.got-term').exists() or c.poll() is not None: break
    os.kill(c.pid, signal.SIGTERM); time.sleep(0.2)
rc = wait_exit(c, 30)
show('L9 SIGTERM to gate reaches agent (agent traps it, exits 0)', ['agent got TERM=%s exit=%s' % ((folder / 'x.got-term').exists(), rc)])
fx.cleanup()
