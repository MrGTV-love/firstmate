#!/usr/bin/env python3
"""S1: reproduce the 2026-10-25 incident shape in a lab home and drive the real
fm-fleet-ledger.sh as the waiter.

A non-reaping parent (this python process, standing in for the omp tool runner)
forks a bash holder that takes state/.fleet-ledger.lock through the shared lock
helper, then SIGKILLs it. The EXIT trap never runs, so the lock stays and the
holder becomes a zombie (ps stat Z). The real fleet-ledger CLI then tries to
record a dispatch. Usage: s1_zombie_reclaim.py <bin-dir> <lab-home> <label>
"""
import os, pathlib, signal, subprocess, sys, time

bindir, home, label = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
state = home / "state"
lock = state / ".fleet-ledger.lock"
ledger = state / "fleet-ledger.jsonl"
ready = home / f"ready.{label}"
lib = bindir / "fm-wake-lib.sh"
env = {k: v for k, v in os.environ.items() if not k.endswith("_OVERRIDE") and k != "NO_MISTAKES_GATE"}
env["FM_HOME"] = str(home)

def ps(pid, field):
    r = subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True)
    return r.stdout.strip() or "(gone)"

def log(msg):
    print(f"[{label} {time.strftime('%H:%M:%S')}] {msg}", flush=True)

before = len(ledger.read_text().splitlines()) if ledger.exists() else 0
pid = os.fork()
if pid == 0:
    os.execvpe("bash", ["bash", "-c",
        '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; : > "$3"; while :; do read -r -t 1 _ || :; done',
        "_", str(lib), str(lock), str(ready)], env)
try:
    for _ in range(200):
        if ready.exists(): break
        time.sleep(.05)
    else: raise SystemExit("holder did not acquire")
    log(f"holder pid={pid} owns {lock} -> {os.readlink(lock) if lock.is_symlink() else lock}")
    os.kill(pid, signal.SIGKILL)
    for _ in range(200):
        if ps(pid, "stat").startswith("Z"): break
        time.sleep(.05)
    log(f"after SIGKILL: holder stat={ps(pid, 'stat')} ppid={ps(pid, 'ppid')} (parent {os.getpid()} has not reaped it)")
    os.kill(pid, 0)
    log(f"kill -0 {pid} still succeeds; lock pid file says {(lock / 'pid').read_text().strip()}")
    t0 = time.time()
    try:
        r = subprocess.run([str(bindir / "fm-fleet-ledger.sh"), "dispatched", f"incident-{label}", "ship", "sample", "claude", "opus"],
                           env=env, capture_output=True, text=True, timeout=20)
        log(f"real waiter `fm-fleet-ledger.sh dispatched` exit={r.returncode} after {time.time() - t0:.2f}s stderr={r.stderr.strip()!r}")
    except subprocess.TimeoutExpired:
        log(f"real waiter `fm-fleet-ledger.sh dispatched` STILL BLOCKED after {time.time() - t0:.1f}s (observer bound 20s, killed by this probe)")
    rows = ledger.read_text().splitlines() if ledger.exists() else []
    new = rows[before:]
    log(f"new ledger rows: {new}")
    log(f"lock now: {'present pid=' + (lock / 'pid').read_text().strip() if (lock / 'pid').exists() else 'released'}")
    log(f"zombie still unreaped: stat={ps(pid, 'stat')}; parent {os.getpid()} alive, never signalled")
finally:
    try: os.kill(pid, signal.SIGKILL)
    except ProcessLookupError: pass
    os.waitpid(pid, 0)
    ready.unlink(missing_ok=True)
