#!/usr/bin/env python3
"""S3 (adversarial): with a live owner, make `ps` unreadable for the waiter
(fails while printing Z, or prints nothing). The real fm-fleet-ledger.sh waiter
must keep the kill -0 verdict and never reclaim the live owner's lock.
Usage: s3_unreadable_ps.py <bin-dir> <lab-home> <fake-ps-dir>
"""
import os, pathlib, subprocess, sys, time

bindir, home, fb = map(pathlib.Path, sys.argv[1:4])
state = home / "state"; lock = state / ".fleet-ledger.lock"; ledger = state / "fleet-ledger.jsonl"
env = {k: v for k, v in os.environ.items() if not k.endswith("_OVERRIDE") and k != "NO_MISTAKES_GATE"}
env["FM_HOME"] = str(home)
ok = True
for mode, body in [("fail-prints-Z", "#!/bin/sh\necho Z\nexit 1\n"), ("empty-exit-0", "#!/bin/sh\nexit 0\n")]:
    (fb / "ps").write_text(body); (fb / "ps").chmod(0o755)
    holder = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2" || exit 1; trap \'fm_lock_release "$2"\' EXIT; echo ready; IFS= read -r _', "_", str(bindir / "fm-wake-lib.sh"), str(lock)],
                              env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    assert holder.stdout.readline().strip() == "ready"
    wenv = dict(env, PATH=f"{fb}{os.pathsep}{env['PATH']}")
    shown = subprocess.run(["ps", "-o", "stat=", "-p", str(holder.pid)], env=wenv, capture_output=True, text=True)
    print(f"[{mode}] live holder pid={holder.pid}; waiter's ps prints {shown.stdout.strip()!r} rc={shown.returncode}", flush=True)
    t0 = time.time()
    w = subprocess.Popen([str(bindir / "fm-fleet-ledger.sh"), "dispatched", f"psfail-{mode}", "ship", "sample", "claude", "opus"], env=wenv)
    try:
        w.wait(timeout=8); waited = f"exited rc={w.returncode}"
    except subprocess.TimeoutExpired:
        waited = "still waiting at the 8s observer bound"
    owner = (lock / "pid").read_text().strip()
    rows = sum(f"psfail-{mode}" in l for l in ledger.read_text().splitlines()) if ledger.exists() else 0
    good = owner == str(holder.pid) and w.poll() is None and rows == 0
    ok &= good
    print(f"[{mode}] real waiter {waited} after {time.time()-t0:.1f}s; lock owner now {owner} -> {'NOT reclaimed' if owner == str(holder.pid) else 'RECLAIMED'}; rows written while held={rows}", flush=True)
    holder.stdin.write("x\n"); holder.stdin.flush(); holder.wait(timeout=30)
    rc = w.wait(timeout=30)
    print(f"[{mode}] after release: waiter rc={rc}, rows={sum(f'psfail-{mode}' in l for l in ledger.read_text().splitlines())}", flush=True)
print("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
