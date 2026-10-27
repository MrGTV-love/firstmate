#!/usr/bin/env python3
"""S4-S6: run the real bin/fm-watch.sh in a lab home against a held
state/.fleet-ledger.lock and observe the long-held lock alarm.

mode live   : live owner + one real fm-fleet-ledger.sh waiter. Fresh hold -> no
              alarm across several polls; backdate the hold past 300s -> one
              alarm naming owner/state/parent/age/waiters; owner and waiter
              untouched; a re-armed watcher stays silent for that episode.
mode zombie : SIGKILLed, unreaped owner (no waiter) aged past 300s -> alarm
              reports state=Z and the non-reaping parent; the lock is left for
              the next waiter, which then reclaims it.
mode dead   : reaped (gone) owner aged past 300s -> alarm reports state=dead.
Usage: s4_watcher_alarm.py <bin-dir> <lab-home> <mode>
"""
import os, pathlib, signal, subprocess, sys, time
watchers = []

bindir, home, mode = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
state = home / "state"; lock = state / ".fleet-ledger.lock"; ledger_flag = home / "config/fleet-ledger"
lib = bindir / "fm-wake-lib.sh"
env = {k: v for k, v in os.environ.items() if not k.endswith("_OVERRIDE") and k != "NO_MISTAKES_GATE"}
env.update(FM_HOME=str(home), FM_POLL="1", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999")
def log(m): print(f"[{mode} {time.strftime('%H:%M:%S')}] {m}", flush=True)
def ps(pid, f): return subprocess.run(["ps", "-o", f"{f}=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or "(gone)"

import re
UNRELATED = []
DRAINS = []
def drain_ack():
    r = subprocess.run([str(bindir / "fm-wake-drain.sh")], env=env, capture_output=True, text=True)
    m = re.search(r"--ack-through (\d+) --recovery-generation (\S+)", r.stdout + r.stderr)
    DRAINS.append((r.stdout + r.stderr).strip())
    if m:
        subprocess.run([str(bindir / "fm-wake-drain.sh"), "--ack-through", m.group(1), "--recovery-generation", m.group(2)], env=env, capture_output=True, text=True)

class Watch:
    """Main's loop: arm the watcher; on any wake, drain + ack and re-arm."""
    def __init__(self, tag):
        self.tag, self.n, self.alarms, self.w = tag, 0, [], None
        self.start()
    def start(self):
        self.n += 1
        self.out = home / f"watch-{mode}-{self.tag}-{self.n}.out"
        self.err = home / f"watch-{mode}-{self.tag}-{self.n}.err"
        with self.out.open("w") as o, self.err.open("w") as e:
            self.w = subprocess.Popen(["bash", str(bindir / "fm-watch.sh")], env=env, stdout=o, stderr=e, start_new_session=True)
        watchers.append(self.w)
    def step(self):
        """Return True while a watcher is running; handle exits."""
        if self.w.poll() is None: return True
        text = self.out.read_text()
        hits = [l for l in text.splitlines() if "long-held lock" in l]
        self.alarms += hits
        if not hits: UNRELATED.append(text.strip() or self.err.read_text().strip()[-200:])
        drain_ack()
        if not hits: self.start()
        return not hits

def beats(watch, n):
    seen = set()
    for _ in range(1200):
        b = state / ".last-watcher-beat"
        if b.exists(): seen.add(b.stat().st_mtime_ns)
        if len(seen) >= n: return
        watch.step()
        time.sleep(.1)
    raise AssertionError("watcher polls did not advance")

def until_alarm(watch, secs=90):
    for _ in range(secs * 10):
        if not watch.step(): return watch.alarms
        time.sleep(.1)
    raise AssertionError("no long-held alarm")

def stop(w):
    if w.poll() is None:
        os.killpg(w.pid, signal.SIGTERM)
        try: w.wait(timeout=30)
        except subprocess.TimeoutExpired: os.killpg(w.pid, signal.SIGKILL); w.wait()

ok = True
holder = waiter = child = None
try:
    if mode == "live":
        ledger_flag.touch()
        holder = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(lib), str(lock)],
                                  env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert holder.stdout.readline().strip() == "ready"
        owner_pid = holder.pid
        waiter = subprocess.Popen([str(bindir / "fm-fleet-ledger.sh"), "dispatched", "alarm-t1", "ship", "sample", "claude", "opus"], env=env, stderr=subprocess.DEVNULL)
        for _ in range(100):
            if any(str(lock) in r.read_text() for r in (state / ".lock-monitor").glob("wait.*")): break
            time.sleep(.1)
        log(f"live owner pid={owner_pid} stat={ps(owner_pid,'stat')}; real waiter pid={waiter.pid} registered")
        w = Watch("fresh")
        beats(w, 4)
        fresh_quiet = not w.alarms
        log(f"fresh hold, watcher made 4 polls: alarm present? {not fresh_quiet}")
        ok &= fresh_quiet
    else:
        ledger_flag.unlink(missing_ok=True)  # keep the watcher's own capture from reclaiming
        ready = home / "ready.s4"
        child = os.fork()
        if child == 0:
            os.execvpe("bash", ["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; : > "$3"; while :; do read -r -t 1 _ || :; done', "_", str(lib), str(lock), str(ready)], env)
        for _ in range(200):
            if ready.exists(): break
            time.sleep(.05)
        ready.unlink()
        owner_pid = child
        os.kill(child, signal.SIGKILL)
        for _ in range(200):
            if ps(child, "stat").startswith("Z"): break
            time.sleep(.05)
        if mode == "dead":
            os.waitpid(child, 0); child = None
        log(f"owner pid={owner_pid} ps stat now={ps(owner_pid,'stat')}; this parent pid={os.getpid()}")
        w = None
    old = time.time() - 301
    os.utime(lock / "pid", (old, old))
    log("backdated the owner's pid file 301s (hold age past the fixed 300s limit)")
    if w is None:
        w = Watch("aged")
    alarm = until_alarm(w)
    log(f"watcher exit={w.w.returncode}; alarm line(s): {alarm}")
    ok &= len(alarm) == 1 and f"owner={owner_pid}" in alarm[0] and "age=" in alarm[0] and "parent=" in alarm[0]
    if mode == "live":
        ok &= "state=S" in alarm[0] and f"parent={os.getpid()}" in alarm[0] and "waiters=1" in alarm[0]
        still = (lock / "pid").read_text().strip() == str(owner_pid) and holder.poll() is None and waiter.poll() is None
        log(f"after alarm: owner unchanged and alive, waiter still waiting: {still}")
        ok &= still
        w2 = Watch("rearm")
        beats(w2, 12)
        quiet = not w2.alarms
        log(f"re-armed watcher, 12 beats on the same episode: repeated alarm? {not quiet}")
        ok &= quiet
        stop(w2.w)
        q = (state / ".wake-queue").read_text() if (state / ".wake-queue").exists() else ""
        log(f"durable queue long-held rows: {sum('long-held' in l for l in q.splitlines())}")
    elif mode == "zombie":
        ok &= "state=Z" in alarm[0] and f"parent={os.getpid()}" in alarm[0]
        kept = (lock / "pid").read_text().strip() == str(owner_pid) and ps(owner_pid, "stat").startswith("Z")
        log(f"alarm did not reclaim or reap: lock owner still {owner_pid}, still zombie: {kept}")
        ok &= kept
        ledger_flag.touch()  # ledger on, so the next writer really takes the lock
        r = subprocess.run([str(bindir / "fm-fleet-ledger.sh"), "dispatched", "after-alarm", "ship", "sample", "claude", "opus"], env=env, capture_output=True, text=True, timeout=20)
        log(f"next real waiter fm-fleet-ledger.sh dispatched exit={r.returncode}; lock {'released' if not lock.exists() else 'present'}")
        rows = (state / "fleet-ledger.jsonl").read_text() if (state / "fleet-ledger.jsonl").exists() else ""
        log(f"ledger row written by that waiter: {'after-alarm' in rows}; zombie still unreaped: {ps(owner_pid, 'stat')}")
        ok &= r.returncode == 0 and not lock.exists() and "after-alarm" in rows
    else:
        ok &= "state=dead" in alarm[0]
        kept = (lock / "pid").read_text().strip() == str(owner_pid)
        log(f"alarm left the dead owner's lock for the next acquirer: {kept}")
        ok &= kept
finally:
    for w in watchers: stop(w)
    if holder is not None and holder.poll() is None:
        holder.stdin.write("x\n"); holder.stdin.flush(); holder.wait(timeout=30)
    if waiter is not None:
        log(f"waiter after owner release: exit={waiter.wait(timeout=30)}")
    if child is not None:
        try: os.kill(child, signal.SIGKILL)
        except ProcessLookupError: pass
        os.waitpid(child, 0)
(home / f"drain-{mode}.txt").write_text("\n=====\n".join(DRAINS))
log(f"unrelated wakes drained+acked by the Main loop: {UNRELATED}")
log("RESULT " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
