# SessionStart hook for the disposable lab primary: runs the real locked
# session start (bin/fm-session-start.sh --source startup) from the run worktree
# and records timing, load, lock/completion ownership, and digest integrity.
import json, os, pathlib, subprocess, sys, time
EV = pathlib.Path(os.environ["FM_LIVE_EVIDENCE"])
label = os.environ["FM_LIVE_LABEL"]
root = os.environ["FM_LIVE_ROOT"]
state = pathlib.Path(os.environ["FM_HOME"]) / "state"
before = {"status_logs": len(list(state.glob("*.status"))),
          "decision_checkpoints": len(list(state.glob(".*.open-decisions-cursor"))),
          "presentation_manifest_exists": (state / ".status-presentation-cursor").exists()}
load_start = os.getloadavg()
t0 = time.monotonic()
r = subprocess.run([root + "/bin/fm-session-start.sh", "--source", "startup"], cwd=root,
                   input=sys.stdin.read(), capture_output=True, text=True, timeout=170)
elapsed = time.monotonic() - t0
load_end = os.getloadavg()
def rec(n):
    p = state / n
    return p.read_text().strip() if p.exists() else None
lock, done = rec(".lock"), rec(".session-start-complete")
proc = subprocess.run(["ps", "-p", lock or "0", "-o", "pid=,ppid=,comm="], capture_output=True, text=True).stdout.strip()
res = {"elapsed_seconds": round(elapsed, 3), "limit_seconds": 20, "under_limit": elapsed < 20,
       "load_start": load_start, "load_end": load_end, "exit_code": r.returncode,
       "lock_pid": lock, "completion_pid": done, "lock_owner_process": proc,
       "initial_state": before,
       "decision_checkpoints_after": len(list(state.glob(".*.open-decisions-cursor"))),
       "digest_complete": "The digest above is complete for this session start." in r.stdout,
       "truncated": any(l.startswith("●  STARTUP TRUNCATED") for l in r.stdout.splitlines())}
(EV / f"{label}-digest.txt").write_text(r.stdout + "\nSTDERR:\n" + r.stderr)
(EV / f"{label}-measurement.json").write_text(json.dumps(res, indent=2) + "\n")
print(r.stdout, end="", flush=True)
subprocess.run(["tmux", "-L", "fm-lab", "wait-for", "-S", "lab-startup-finished"])
