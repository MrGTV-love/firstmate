# usage: argmax.py <tree> <N> <pad-dir-chars or 0>
# Seeds N handled records (record 0900 holds the TARGET), then times a resend of TARGET and a new text.
import os, subprocess, sys, tempfile, time, shutil
TREE, N, PAD = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
TARGET = 'TARGET steer corr=RESEND-9\nsecond line of the target'
base = tempfile.mkdtemp(prefix='fm-val-arg.', dir='/tmp')
st = base
if PAD:
    seg = 'd' * 60
    st = base
    while len(st) < PAD: st = os.path.join(st, seg)
    os.makedirs(st, exist_ok=True)
inbox = os.path.join(st, 't1.inbox'); os.makedirs(os.path.join(inbox, 'handled'))
HDR = 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\n'
for i in range(1, N + 1):
    body = TARGET if i == 900 else 'handled steer %d\nsecond line' % i
    open(os.path.join(inbox, 'handled', '%04d.msg' % i), 'w').write(HDR + body)
avg = sum(len(os.path.join(inbox, 'handled', '%04d.msg' % i)) for i in range(1, N + 1)) // N
print('N=%d path-bytes-avg=%d total-arg-bytes~%d tree=%s' % (N, avg, avg * N, TREE))
env = dict(os.environ, FM_STATE_OVERRIDE=st)
for label, text in (('resend-of-handled', TARGET), ('new-text', 'NEW steer corr=Z\nnew tail')):
    t = time.time()
    q = subprocess.run(['bash', '-c', '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"', '_', os.path.join(TREE, 'bin/fm-task-inbox-lib.sh'), st, text], env=env, capture_output=True)
    dt = time.time() - t
    print('%s: rc=%d seconds=%.1f printed=%r stderr=%r' % (label, q.returncode, dt, q.stdout.decode().replace(st + '/', ''), q.stderr.decode()[:160]))
    print('  unhandled=%d handled=%d' % (len([f for f in os.listdir(inbox) if f.endswith('.msg')]), len(os.listdir(os.path.join(inbox, 'handled')))))
shutil.rmtree(base, ignore_errors=True)
