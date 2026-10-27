# Scenario 3: the real watcher (bin/fm-watch.sh) in a lab home reports a
# fleet-ledger lock held past 300s exactly once per ownership episode, naming
# lock, owner, state, parent, parent_command, age and waiters; Main sees it via
# the real bin/fm-wake-drain.sh. The alarm never kills or reclaims. A fresh
# hold raises nothing. Between arms this script acts as Main: it drains and
# acknowledges the queue with the real drain, exactly as a Main turn would.
import os, pathlib, re, signal, subprocess, sys, time
root, home = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
state = home / "state"; lock = state / ".fleet-ledger.lock"; lib = root / "bin/fm-wake-lib.sh"
env = dict(os.environ, FM_HOME=str(home), FM_POLL="1", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999")
for k in ("FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "FM_ROOT_OVERRIDE", "NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS"): env.pop(k, None)
def drain_ack(tag, show=False):
    out = subprocess.run([str(root/"bin/fm-wake-drain.sh")], env=env, capture_output=True, text=True, timeout=120).stdout
    if show: print(f"  [{tag}] Main's real drain shows:\n" + "\n".join("    " + l for l in out.splitlines() if "long-held" in l or "WAKE_ACK" in l))
    m = re.search(r"--ack-through (\d+) --recovery-generation (\S+)", out)
    if m:
        r = subprocess.run([str(root/"bin/fm-wake-drain.sh"), "--ack-through", m[1], "--recovery-generation", m[2]], env=env, capture_output=True, text=True, timeout=120)
        if "refused" in r.stdout + r.stderr: print(f"  [{tag}] ack refused: {(r.stdout+r.stderr)[:300]}")
    return out
def watch(tag):
    o, e = home / f"watch-{tag}.out", home / f"watch-{tag}.err"
    with o.open("w") as so, e.open("w") as se:
        p = subprocess.Popen(["bash", str(root/"bin/fm-watch.sh")], env=env, stdout=so, stderr=se, start_new_session=True)
    return p, o
def stop(p):
    if p.poll() is None:
        os.killpg(p.pid, signal.SIGTERM)
        try: p.wait(timeout=30)
        except subprocess.TimeoutExpired: os.killpg(p.pid, signal.SIGKILL); p.wait()
def arm_until_quiet(tag, secs):
    """Arm watchers; each wake is drained+acked like Main. Return all stdout lines until one arm stays quiet for secs."""
    lines = []
    for i in range(6):
        p, o = watch(f"{tag}{i}")
        t = time.time()
        while time.time() - t < secs and p.poll() is None: time.sleep(.2)
        quiet = p.poll() is None
        stop(p)
        got = o.read_text().strip()
        if got: lines.append(got)
        drain_ack(f"{tag}{i}", show="long-held" in got)
        if quiet and not got: return lines, True
    return lines, False
lines, quiet = arm_until_quiet("settle", 6)
print(f"settle (before any lock): unrelated first-arm wakes {lines}; quiet={quiet}")
holder = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(lib), str(lock)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
assert holder.stdout.readline().strip() == "ready"
print(f"live holder pid={holder.pid} (its parent = this python pid {os.getpid()}) holds {lock}")
waiters = [subprocess.Popen([str(root/"bin/fm-fleet-ledger.sh"), "dispatched", f"task-w{i}", "ship", "proj", "claude", "opus"], env=env, stderr=subprocess.DEVNULL) for i in range(2)]
for _ in range(200):
    if len(list(state.glob(".lock-monitor.wait.*"))) == 2: break
    time.sleep(.05)
print(f"2 real `fm-fleet-ledger.sh dispatched` waiters blocked: {[p.pid for p in waiters]}")
try:
    lines, quiet = arm_until_quiet("fresh", 8)
    print(f"(a) FRESH hold: watcher output {lines}; a quiet 8s arm reached={quiet}; long-held alarms={sum('long-held' in l for l in lines)}")
    old = time.time() - 301; os.utime(lock / "pid", (old, old))
    print("    -> backdated the hold start (pid file mtime) to 301s ago")
    lines, quiet = arm_until_quiet("aged", 10)
    print(f"(b)+(c) AGED hold, watcher re-armed until quiet for 10s: outputs={lines}")
    print(f"    long-held alarms for this one episode={sum('long-held' in l for l in lines)}; final arm quiet={quiet}")
    print(f"(d) after alarm: lock pid file={(lock/'pid').read_text().strip()} holder alive={holder.poll() is None} waiters still waiting={[p.poll() is None for p in waiters]}")
    holder.stdin.write("go\n"); holder.stdin.flush(); holder.wait(timeout=10)
    rcs = [p.wait(timeout=30) for p in waiters]
    rows = [l for l in (state/"fleet-ledger.jsonl").read_text().splitlines() if "task-w" in l]
    print(f"    after the owner released normally: waiter exits={rcs}; ledger rows for task-w*={len(rows)}")
    h2 = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(lib), str(lock)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert h2.stdout.readline().strip() == "ready"
    os.utime(lock / "pid", (old, old))
    lines, quiet = arm_until_quiet("episode2", 10)
    print(f"(e) NEW episode (owner pid={h2.pid}, aged): outputs={lines}; long-held alarms={sum('long-held' in l for l in lines)}")
    h2.stdin.write("go\n"); h2.stdin.flush(); h2.wait(timeout=10)
    errs = {p.name: p.read_text().strip()[:300] for p in home.glob("watch-*.err") if p.read_text().strip()}
    print(f"watcher stderr (non-empty only): {errs}")
finally:
    for p in waiters:
        if p.poll() is None: p.terminate()
    if holder.poll() is None: holder.kill()
