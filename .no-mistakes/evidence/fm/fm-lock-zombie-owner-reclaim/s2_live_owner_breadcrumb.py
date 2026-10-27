#!/usr/bin/env python3
"""S2: a LIVE owner holds state/.fleet-ledger.lock; the real fm-fleet-ledger.sh
waits behind it. Expect: no reclaim, no stderr before 60s, exactly one
breadcrumb line after about 60s naming the owner, the waiter keeps waiting,
then acquires and writes its row once the owner releases.
Usage: s2_live_owner_breadcrumb.py <bin-dir> <lab-home>
"""
import os, pathlib, subprocess, sys, time

bindir, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
state = home / "state"; lock = state / ".fleet-ledger.lock"; ledger = state / "fleet-ledger.jsonl"
lib = bindir / "fm-wake-lib.sh"
env = {k: v for k, v in os.environ.items() if not k.endswith("_OVERRIDE") and k != "NO_MISTAKES_GATE"}
env["FM_HOME"] = str(home)
err = home / "s2-waiter.err"
def log(m): print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)

holder = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(lib), str(lock)],
                          env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert holder.stdout.readline().strip() == "ready"
log(f"live holder pid={holder.pid} stat={subprocess.run(['ps','-o','stat=','-p',str(holder.pid)],capture_output=True,text=True).stdout.strip()} owns lock")
before = len(ledger.read_text().splitlines()) if ledger.exists() else 0
t0 = time.time()
with err.open("w") as e:
    waiter = subprocess.Popen([str(bindir / "fm-fleet-ledger.sh"), "dispatched", "breadcrumb-t1", "ship", "sample", "claude", "opus"], env=env, stderr=e)
log(f"real waiter pid={waiter.pid} started: fm-fleet-ledger.sh dispatched breadcrumb-t1 ...")
first_line_at = None
for _ in range(100):
    time.sleep(1)
    lines = err.read_text().splitlines()
    el = time.time() - t0
    if lines and first_line_at is None:
        first_line_at = el
        log(f"t={el:.1f}s first stderr line: {lines[0]}")
    assert waiter.poll() is None, f"waiter exited early rc={waiter.returncode}"
    assert (lock / "pid").read_text().strip() == str(holder.pid), "live owner was displaced"
    if int(el) in (30, 59, 75, 99):
        log(f"t={el:.1f}s waiter running, owner unchanged, stderr lines={len(lines)}")
lines = err.read_text().splitlines()
log(f"at t={time.time()-t0:.1f}s stderr line count={len(lines)} (expect 1); first at {first_line_at and round(first_line_at,1)}s (expect >=60)")
holder.stdin.write("release\n"); holder.stdin.flush(); holder.wait(timeout=30)
log("holder released the lock")
rc = waiter.wait(timeout=30)
log(f"waiter exit={rc} at t={time.time()-t0:.1f}s; new rows={ledger.read_text().splitlines()[before:]}")
log(f"final stderr: {err.read_text().splitlines()}")
ok = rc == 0 and len(lines) == 1 and first_line_at is not None and first_line_at >= 60 and f"owner={holder.pid}" in lines[0]
log("RESULT " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
