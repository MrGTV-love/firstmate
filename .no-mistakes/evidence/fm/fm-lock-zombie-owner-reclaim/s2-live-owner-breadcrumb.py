# Scenario 2: a LIVE owner holds state/.fleet-ledger.lock. A real
# `fm-fleet-ledger.sh dispatched` waiter must not reclaim it, must print exactly
# one breadcrumb after ~60s naming the owner, keep waiting, and finish once the
# owner releases normally.
import os, pathlib, subprocess, sys, threading, time
bindir, home, hold_secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
state = pathlib.Path(home, "state"); lock = state / ".fleet-ledger.lock"
env = dict(os.environ, FM_HOME=home)
for k in ("FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_ROOT_OVERRIDE"): env.pop(k, None)
holder = subprocess.Popen(["bash", "-c", '. "$1/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", bindir, str(lock)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert holder.stdout.readline().strip() == "ready"
ps = lambda p: subprocess.run(["ps","-o","stat=","-p",str(p)],capture_output=True,text=True).stdout.strip()
print(f"live holder pid={holder.pid} stat={ps(holder.pid)} holds {lock}")
t0 = time.time()
w = subprocess.Popen([f"{bindir}/fm-fleet-ledger.sh", "dispatched", "task-l2", "ship", "proj", "claude", "opus"], env=env, stderr=subprocess.PIPE, text=True)
lines = []
def rd():
    for l in w.stderr: lines.append((time.time()-t0, l.rstrip()))
threading.Thread(target=rd, daemon=True).start()
while time.time() - t0 < hold_secs:
    time.sleep(1)
    assert w.poll() is None, f"waiter exited early rc={w.returncode}"
pid_now = (lock/"pid").read_text().strip()
print(f"t={time.time()-t0:.0f}s waiter still running={w.poll() is None}; lock pid file still {pid_now} (holder {holder.pid}) -> not reclaimed: {pid_now == str(holder.pid)}")
for t, l in lines: print(f"  waiter stderr at t={t:5.1f}s: {l}")
print(f"breadcrumb count while one owner held: {sum('fm-lock: waiting' in l for _, l in lines)}")
holder.stdin.write("go\n"); holder.stdin.flush(); holder.wait(timeout=10)
rc = w.wait(timeout=30)
print(f"holder released at t={hold_secs:.0f}s; waiter exit={rc} at t={time.time()-t0:.1f}s")
rows = [l for l in (state/"fleet-ledger.jsonl").read_text().splitlines() if "task-l2" in l]
print(f"ledger rows for task-l2: {len(rows)} {rows[:1]}")
print(f"wait receipts left in state: {[p.name for p in state.glob('.lock-monitor.wait.*')]}")
