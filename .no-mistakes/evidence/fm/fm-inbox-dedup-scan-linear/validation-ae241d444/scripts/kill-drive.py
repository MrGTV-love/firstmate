# usage: kill-drive.py <tree-root> <TERM|INT|KILL> [N]
# Drives the real fm_task_inbox_write_idempotent in a bash child. A blocking grep shim
# on PATH holds the writer inside the candidate scan (the dedup grep, marked by --null).
import os, signal, subprocess, sys, tempfile, time, shutil

TREE, SIG = sys.argv[1], sys.argv[2]
N = int(sys.argv[3]) if len(sys.argv) > 3 else 1600
LIB = os.path.join(TREE, 'bin/fm-task-inbox-lib.sh')
TEXT = 'KILLED-STEER corr=K1\nsecond line'
AFTER = 'AFTER-KILL-STEER corr=K2\nsecond line'
state = tempfile.mkdtemp(prefix='fm-val-kill.', dir='/tmp')
inbox = os.path.join(state, 't1.inbox')
os.makedirs(os.path.join(inbox, 'handled'))
for i in range(1, N + 1):
    with open(os.path.join(inbox, 'handled', '%04d.msg' % i), 'w') as f:
        f.write('schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nhandled steer %d\nsecond line\n' % i)
shim = os.path.join(state, 'shim'); os.makedirs(shim)
marker = os.path.join(state, 'blocked.pid')
with open(os.path.join(shim, 'grep'), 'w') as f:
    f.write('#!/bin/sh\n'
            'case " $* " in *" --null "*) printf "%%s\\n" "$$" > "%s"; exec /bin/sleep 300 ;; esac\n'
            'exec /usr/bin/grep "$@"\n' % marker)
os.chmod(os.path.join(shim, 'grep'), 0o755)
BASH = ['bash', '-c', '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"', '_', LIB, state]

def restore_default():
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, signal.SIG_DFL)

def entries():
    return sorted(e for e in os.listdir(inbox) if e.startswith(('.dedup', '.work', '.staging', '.seq')))

def alive(pid):
    try:
        os.kill(pid, 0); return True
    except ProcessLookupError:
        return False

print('tree=%s signal=%s N=%d state-dir=%s' % (TREE, SIG, N, state))
env = dict(os.environ, FM_STATE_OVERRIDE=state, PATH=shim + os.pathsep + os.environ['PATH'])
p = subprocess.Popen(BASH + [TEXT], env=env, preexec_fn=restore_default,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
t0 = time.time()
while not os.path.exists(marker) and time.time() - t0 < 30:
    time.sleep(0.02)
time.sleep(0.3)
shim_pid = int(open(marker).read().strip()) if os.path.exists(marker) else -1
print('pre-signal: scan-blocked=%s writer-alive=%s blocking-grep-alive=%s lock-held=%s work-or-temp=%s' % (
    os.path.exists(marker), alive(p.pid), alive(shim_pid),
    os.path.islink(os.path.join(inbox, '.seq.lock')) or os.path.isdir(os.path.join(inbox, '.seq.lock')),
    entries()))
if not (alive(p.pid) and alive(shim_pid)):
    print('INVALID RUN: writer was not held inside the scan'); sys.exit(3)
sig = {'TERM': signal.SIGTERM, 'INT': signal.SIGINT, 'KILL': signal.SIGKILL}[SIG]
os.kill(p.pid, sig)
try:
    out, err = p.communicate(timeout=60)
except subprocess.TimeoutExpired:
    p.kill(); out, err = p.communicate(); print('writer did not exit in 60 s')
print('writer returncode=%s (negative means killed by that signal)' % p.returncode)
print('writer stderr=%r' % err[:200])
time.sleep(0.3)
print('after signal: blocking-grep-alive=%s' % alive(shim_pid))
print('after signal: entries=%s' % entries())
print('after signal: lock-present=%s' % os.path.lexists(os.path.join(inbox, '.seq.lock')))
print('after signal: unhandled .msg=%s' % sorted(f for f in os.listdir(inbox) if f.endswith('.msg')))
if SIG == 'KILL':
    print('after SIGKILL: stale lock recovery is timed by the second call (expect a wait).')
# second call: no shim, must succeed
env2 = dict(os.environ, FM_STATE_OVERRIDE=state)
t1 = time.time()
q = subprocess.run(BASH[:-0 or None] + [AFTER], env=env2, capture_output=True, text=True, timeout=600)
print('second call rc=%d seconds=%.1f printed=%r stderr=%r' % (q.returncode, time.time() - t1, q.stdout.replace(state, 'STATE'), q.stderr[:200]))
print('after second call: entries=%s' % entries())
print('after second call: unhandled .msg=%s' % sorted(f for f in os.listdir(inbox) if f.endswith('.msg')))
body = open(os.path.join(inbox, '1601.msg')).read() if os.path.exists(os.path.join(inbox, '1601.msg')) else ''
print('1601.msg body tail=%r' % body.split('--\n', 1)[-1])
shutil.rmtree(state, ignore_errors=True)
