# Scenario 1: reproduce the incident with the real fm-fleet-ledger.sh CLI.
# A holder takes state/.fleet-ledger.lock with the same helper + EXIT-trap
# pattern fm-fleet-ledger.sh uses, is SIGKILLed, and its parent (this python
# process, standing in for the omp tool runner) never reaps it -> zombie (ps Z).
# Then a real waiter runs `fm-fleet-ledger.sh dispatched ...`.
import os, pathlib, signal, subprocess, sys, time
bindir, home, label = sys.argv[1], sys.argv[2], sys.argv[3]
state = pathlib.Path(home, "state"); lock = state / ".fleet-ledger.lock"
ready = pathlib.Path(home, "holder-ready"); ready.unlink(missing_ok=True)
env = dict(os.environ, FM_HOME=home)
for k in ("FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_DATA_OVERRIDE", "FM_PROJECTS_OVERRIDE"): env.pop(k, None)
pid = os.fork()
if pid == 0:
    os.execvpe("bash", ["bash", "-c", '. "$1/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; : > "$3"; while :; do read -r -t 1 _ || :; done', "_", bindir, str(lock), str(ready)], env)
def ps(p):
    return subprocess.run(["ps", "-o", "pid=,ppid=,stat=,comm=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
try:
    for _ in range(200):
        if ready.exists(): break
        time.sleep(.05)
    else: raise SystemExit("holder did not acquire")
    print(f"[{label}] holder pid={pid} holds {lock} -> {os.readlink(lock) if lock.is_symlink() else lock}")
    print(f"[{label}] lock pid file: {(lock/'pid').read_text().strip()}")
    os.kill(pid, signal.SIGKILL)
    for _ in range(200):
        if ps(pid).split()[2:3] and ps(pid).split()[2].startswith("Z"): break
        time.sleep(.05)
    print(f"[{label}] after SIGKILL, ps: {ps(pid)}  (parent {os.getpid()} has NOT reaped it)")
    print(f"[{label}] kill -0 {pid}: rc={subprocess.run(['bash','-c',f'kill -0 {pid}']).returncode}")
    print(f"[{label}] lock still present: {lock.exists() or lock.is_symlink()}")
    t0 = time.time()
    try:
        r = subprocess.run([f"{bindir}/fm-fleet-ledger.sh", "dispatched", "task-z1", "ship", "proj", "claude", "opus"], env=env, capture_output=True, text=True, timeout=20)
        print(f"[{label}] waiter `fm-fleet-ledger.sh dispatched task-z1 ...` exit={r.returncode} after {time.time()-t0:.2f}s stderr={r.stderr.strip()!r}")
    except subprocess.TimeoutExpired:
        print(f"[{label}] waiter `fm-fleet-ledger.sh dispatched task-z1 ...` STILL BLOCKED after {time.time()-t0:.1f}s (killed by test timeout)")
    led = state / "fleet-ledger.jsonl"
    rows = [l for l in led.read_text().splitlines() if "task-z1" in l] if led.exists() else []
    print(f"[{label}] ledger rows for task-z1: {len(rows)} {rows[:1]}")
    print(f"[{label}] lock present after waiter: {lock.exists() or lock.is_symlink()}")
    print(f"[{label}] holder still a zombie (never reaped): {ps(pid)}")
finally:
    try: os.kill(pid, signal.SIGKILL)
    except ProcessLookupError: pass
    os.waitpid(pid, 0)
    subprocess.run(["rm", "-rf", str(lock)])
