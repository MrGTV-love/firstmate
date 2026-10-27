#!/usr/bin/env python3
"""S7 (adversarial): FM_LOCK_ALARM_SECS=1 must not shorten the fixed 300s
limit. A live owner whose hold is 120s old must not alarm on a real watcher."""
import os, pathlib, signal, subprocess, sys, time
bindir, home = map(pathlib.Path, sys.argv[1:3])
state = home / "state"; lock = state / ".fleet-ledger.lock"
env = {k: v for k, v in os.environ.items() if not k.endswith("_OVERRIDE") and k != "NO_MISTAKES_GATE"}
env.update(FM_HOME=str(home), FM_POLL="1", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999", FM_LOCK_ALARM_SECS="1")
h = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(bindir / "fm-wake-lib.sh"), str(lock)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert h.stdout.readline().strip() == "ready"
old = time.time() - 120; os.utime(lock / "pid", (old, old))
outs = []; seen = set(); n = 0; w = None
try:
    t0 = time.time()
    while time.time() - t0 < 25 and len(seen) < 16:
        if w is None or w.poll() is not None:
            if w is not None: outs.append((home / f"k{n}.out").read_text().strip())
            n += 1
            w = subprocess.Popen(["bash", str(bindir / "fm-watch.sh")], env=env, stdout=(home / f"k{n}.out").open("w"), stderr=subprocess.DEVNULL, start_new_session=True)
        b = state / ".last-watcher-beat"
        if b.exists(): seen.add(b.stat().st_mtime_ns)
        time.sleep(.1)
    outs.append((home / f"k{n}.out").read_text().strip())
finally:
    if w.poll() is None: os.killpg(w.pid, signal.SIGTERM); w.wait(timeout=30)
    h.stdin.write("x\n"); h.stdin.flush(); h.wait(timeout=30)
alarm = [o for o in outs if "long-held" in o]
print(f"FM_LOCK_ALARM_SECS=1, live owner pid={h.pid} hold age 120s, watcher beats observed={len(seen)}, watcher outputs={outs}")
print("long-held alarm raised:", bool(alarm))
print("RESULT", "PASS" if not alarm and len(seen) >= 8 else "FAIL")
sys.exit(0 if not alarm and len(seen) >= 8 else 1)
