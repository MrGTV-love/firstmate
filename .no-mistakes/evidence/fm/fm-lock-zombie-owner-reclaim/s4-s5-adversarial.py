# S4 (adversarial): a live owner that is STOPPED (ps T, SIGSTOP) is not a
#   zombie; a real fm-fleet-ledger.sh waiter must not reclaim it.
# S5: a ZOMBIE owner of a non-measured lock (.control-task-1.lock) while a live
#   waiter stays blocked (its reclaim held off by a live steal-mutex holder)
#   makes the real watcher raise one trigger=dead-owner alarm.
import os, pathlib, re, signal, subprocess, sys, time
root, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sys.path.insert(0, str(root / "tests")); from importlib import import_module
fixture = import_module("lock-waiter-fixture")
state = home / "state"; lib = root / "bin/fm-wake-lib.sh"
env = dict(os.environ, FM_HOME=str(home), FM_POLL="1", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999")
for k in ("FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_ROOT_OVERRIDE", "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS"): env.pop(k, None)
ps = lambda p: subprocess.run(["ps","-o","stat=","-p",str(p)],capture_output=True,text=True).stdout.strip()
# ---- S4
lock = state / ".fleet-ledger.lock"
h = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(lib), str(lock)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert h.stdout.readline().strip() == "ready"
os.kill(h.pid, signal.SIGSTOP); time.sleep(.3)
print(f"S4: owner pid={h.pid} ps stat={ps(h.pid)} (stopped, alive)")
try:
    r = subprocess.run([str(root/"bin/fm-fleet-ledger.sh"), "dispatched", "task-s4", "ship", "p", "c", "m"], env=env, capture_output=True, text=True, timeout=8)
    print(f"S4: waiter finished exit={r.returncode} -> WRONG, a live stopped owner was displaced")
except subprocess.TimeoutExpired:
    print(f"S4: waiter still blocked after 8s (correct); lock pid file={(lock/'pid').read_text().strip()}")
os.kill(h.pid, signal.SIGCONT); h.stdin.write("go\n"); h.stdin.flush(); h.wait(timeout=10)
r = subprocess.run([str(root/"bin/fm-fleet-ledger.sh"), "dispatched", "task-s4", "ship", "p", "c", "m"], env=env, capture_output=True, text=True, timeout=30)
print(f"S4: after normal release a new waiter exit={r.returncode}")
# ---- S5
clock = state / ".control-task-1.lock"
zpid = os.fork()
if zpid == 0:
    os.execvpe("bash", ["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; : > "$3"; while :; do read -r -t 1 _ || :; done', "_", str(lib), str(clock), str(home / "z-ready")], env)
for _ in range(200):
    if (home / "z-ready").exists(): break
    time.sleep(.05)
os.kill(zpid, signal.SIGKILL)
for _ in range(100):
    if ps(zpid).startswith("Z"): break
    time.sleep(.05)
print(f"S5: control-lock owner pid={zpid} ps stat={ps(zpid)} (zombie, parent {os.getpid()} never reaps)")
fenv = dict(env, FM_STATE_OVERRIDE=str(state))
out = home / "watch-s5.out"
try:
    with fixture.blocked_waiter(clock, lib, fenv) as waiter:
        print(f"S5: live waiter pid={waiter.pid} registered and blocked on {clock}")
        with out.open("w") as so:
            w = subprocess.Popen(["bash", str(root/"bin/fm-watch.sh")], env=env, stdout=so, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(300):
            if w.poll() is not None: break
            time.sleep(.1)
        if w.poll() is None: os.killpg(w.pid, signal.SIGTERM); w.wait()
        print(f"S5: watcher exit={w.returncode} stdout: {out.read_text().strip()}")
        print(f"S5: owner pid file still {(clock/'pid').read_text().strip()} (alarm did not reclaim)")
    q = [l for l in (state/".wake-queue").read_text().splitlines() if "dead-owner" in l] if (state/".wake-queue").exists() else []
    print(f"S5: wake-queue dead-owner rows: {len(q)}")
finally:
    try: os.kill(zpid, signal.SIGKILL)
    except ProcessLookupError: pass
    os.waitpid(zpid, 0)
    # Reaped now (truly gone): the next acquirer reclaims as before.
    r = subprocess.run(["bash", "-c", '. "$1"; fm_lock_try_acquire "$2" && echo "reclaimed recovered_pid=$FM_LOCK_RECOVERED_PID" && fm_lock_release "$2"', "_", str(lib), str(clock)], env=fenv, capture_output=True, text=True)
    print(f"S5 cleanup: {r.stdout.strip()}")
