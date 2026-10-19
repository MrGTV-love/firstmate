#!/usr/bin/env python3
"""PATH touch/grep shim: force the real in-flight-touch interleaving, no source edits.

Install as both <shim-dir>/touch and <shim-dir>/grep.
Only the stopped-watcher case is affected; all commands still call the system tool.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

name = Path(sys.argv[0]).name
args = sys.argv[1:]
real = "/usr/bin/" + name
if name == "touch":
    beacon_arg = next((arg for arg in args if arg.endswith("/stopped-watcher/state/.last-watcher-beat")), None)
    if beacon_arg is not None:
        state = Path(beacon_arg).parent
        first = state / "stress-first-touch"
        pending = state / "stress-pending-touch"
        completed = state / "stress-touch-completed"
        if args == [beacon_arg]:
            if first.exists():
                pending.write_text(str(os.getpid()))
                os.kill(os.getpid(), signal.SIGSTOP)
                rc = subprocess.run([real, *args]).returncode
                completed.write_text(str(rc))
                print(f"SCHEDULE child={os.getpid()} resumed actual touch after stale write", file=sys.stderr, flush=True)
                sys.exit(rc)
            first.write_text("first")
        elif "-t" in args:
            rc = subprocess.run([real, *args]).returncode
            if pending.exists():
                child = int(pending.read_text())
                os.kill(child, signal.SIGCONT)
                for _ in range(800):
                    if completed.exists():
                        print(f"SCHEDULE stale write precedes pending touch child={child}", file=sys.stderr, flush=True)
                        sys.exit(rc)
                    time.sleep(0.01)
                raise RuntimeError("scheduled touch never completed")
            sys.exit(rc)
elif name == "grep":
    rc = subprocess.run([real, *args]).returncode
    if rc == 0 and "watcher: started pid=" in args and args[-1].endswith("/stopped-watcher/arm.out"):
        state = Path(args[-1]).parent / "state"
        watcher = int((state / ".watch.lock/pid").read_text())
        for _ in range(800):
            if (state / "stress-pending-touch").exists():
                print("SCHEDULE readiness reader yields until a real touch is pending", file=sys.stderr, flush=True)
                break
            status = subprocess.check_output(["/bin/ps", "-p", str(watcher), "-o", "stat="], text=True)
            if "T" in status:
                print("SCHEDULE watcher already stopped after completed touch; no pending writer", file=sys.stderr, flush=True)
                break
            time.sleep(0.01)
        else:
            raise RuntimeError("no in-flight touch or synchronized stopped watcher")
    sys.exit(rc)
os.execv(real, [real, *args])
