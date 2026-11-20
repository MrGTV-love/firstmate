# dd3.py <lib-root> <tool-to-block> <signal: TERM|INT|KILL> : run the real writer, block one tool inside
# the compare, send the signal to the writer's own pid, then inspect the inbox and run a second call.
import os, signal, subprocess, sys, tempfile, time, json
lib, tool, signame = sys.argv[1], sys.argv[2], sys.argv[3]
S = '/tmp/fmlive'
st = tempfile.mkdtemp(prefix='dd3.', dir=S)
inbox = os.path.join(st, 't.inbox')
subprocess.run([f'{S}/seed.sh', inbox, '2'], check=True)
pidfile = os.path.join(st, 'block.pid')
env = dict(os.environ, PATH=f'{S}/shim:' + os.environ['PATH'], FM_BLOCK_TOOL=tool,
           FM_BLOCK_PIDFILE=pidfile, FM_LAUNCH_LOG=os.path.join(st, 'launch.log'))
text = 'steer for signal test'
p = subprocess.Popen(['bash', f'{S}/call.sh', lib, st, 't', text], env=env,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
t0 = time.time()
while not os.path.exists(pidfile):
    if p.poll() is not None or time.time() - t0 > 60:
        break
    time.sleep(0.05)
blocked = os.path.exists(pidfile)
blockpid = int(open(pidfile).read().strip()) if blocked else None
pre = sorted(os.listdir(inbox))
sigmap = {'TERM': signal.SIGTERM, 'INT': signal.SIGINT, 'KILL': signal.SIGKILL}
if blocked:
    os.kill(p.pid, sigmap[signame])
try:
    out, err = p.communicate(timeout=60)
except subprocess.TimeoutExpired:
    p.kill(); out, err = p.communicate()
    print('WRITER DID NOT EXIT')
def alive(pid):
    try:
        os.kill(pid, 0); return True
    except OSError:
        return False
after = sorted(os.listdir(inbox))
bp_alive = alive(blockpid) if blockpid else None
print(f'lib={lib} blocked_tool={tool} signal={signame}')
print(f'blocked_inside_compare={blocked} writer_rc={p.returncode} writer_stdout={out.decode()!r}')
print(f'entries_before_signal={pre}')
print(f'entries_after_signal={after}')
print(f'temp_dedup_left={[x for x in after if x.startswith(".dedup")]} lock_left={".seq.lock" in after} work_dir_left={[x for x in after if x.startswith(".work")]}')
print(f'blocked_child_still_alive={bp_alive}')
if bp_alive:
    os.kill(blockpid, signal.SIGKILL)  # cleanup of our own blocked helper only
# second call, no block
env2 = dict(os.environ, PATH=f'{S}/shim:' + os.environ['PATH'])
t1 = time.time()
r = subprocess.run(['bash', f'{S}/call.sh', lib, st, 't', text], env=env2, capture_output=True, timeout=120)
print(f'second_call_rc={r.returncode} printed={r.stdout.decode()!r} wall={time.time()-t1:.1f}s stderr={r.stderr.decode()[:200]!r}')
print(f'entries_final={sorted(os.listdir(inbox))}')
print(f'record_final_body={open(os.path.join(inbox, r.stdout.decode().strip())).read().splitlines()[-1]!r}' if r.returncode == 0 else 'no record')
