# Shared by tests/fm-watcher-lock.test.sh: a real lock waiter kept blocked
# behind a live steal-mutex holder, so a dead owner cannot be reclaimed.
import contextlib, pathlib, subprocess, time
@contextlib.contextmanager
def blocked_waiter(lock, lib, env):
    # Reclaim stays blocked only while another live process holds the steal
    # mutex; the waiter must register and still be waiting after the check.
    steal = pathlib.Path(str(lock) + ".steal")
    holder = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_try_acquire "$2" || exit 1; echo ready; IFS= read -r _; fm_lock_release "$2"', "_", str(lib), str(steal)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    waiter = None
    try:
        assert holder.stdout.readline().strip() == "ready", "steal mutex holder did not acquire"
        waiter = subprocess.Popen(["bash", "-c", '. "$1"; fm_lock_acquire_wait "$2"', "_", str(lib), str(lock)], env=env)
        target = str(lock.parent.resolve() / lock.name)
        monitor = pathlib.Path(env["FM_STATE_OVERRIDE"], ".lock-monitor")
        for _ in range(400):
            found = False
            for receipt in monitor.glob("wait.*"):
                try: fields = receipt.read_text().splitlines()
                except FileNotFoundError: continue
                found |= len(fields) >= 2 and fields[0] == str(waiter.pid) and fields[1] == target
            if found: break
            assert waiter.poll() is None, "waiter reclaimed instead of blocking"
            time.sleep(.05)
        else: raise AssertionError("waiter never registered")
        yield waiter
        assert waiter.poll() is None, "waiter stopped blocking during the check"
    finally:
        if waiter is not None and waiter.poll() is None:
            waiter.terminate(); waiter.wait(timeout=30)
        if holder.poll() is None:
            holder.stdin.write("release\n"); holder.stdin.flush(); holder.wait(timeout=30)
