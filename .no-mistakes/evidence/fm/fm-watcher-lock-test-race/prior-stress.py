#!/usr/bin/env python3
"""Run the unchanged stopped-watcher case serially under owned CPU load."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

p = argparse.ArgumentParser()
p.add_argument("repo", type=Path)
p.add_argument("output", type=Path)
p.add_argument("--iterations", type=int, default=40)
p.add_argument("--load", type=int, default=40)
p.add_argument("--schedule", action="store_true", help="force the demonstrated touch-child interleaving using PATH wrappers, without changing repository files")
a = p.parse_args()
a.output.parent.mkdir(parents=True, exist_ok=True)
loads = []
failed = []
command = ["nice", "-n", "20", "bash", "bin/fm-test-run.sh", "tests/fm-watcher-lock.test.sh"]
child_env = dict(os.environ, FM_TEST_ONLY="test_stopped_watcher_is_live_but_stale_then_exit_is_classified")
schedule_dir = tempfile.TemporaryDirectory(prefix="fm-touch-scheduler-") if a.schedule else None
if schedule_dir is not None:
    for name in ("grep", "touch"):
        Path(schedule_dir.name, name).symlink_to(Path(__file__).resolve().with_name("schedule.py"))
    child_env["PATH"] = schedule_dir.name + os.pathsep + child_env["PATH"]
with a.output.open("w", buffering=1) as log:
    def report(text):
        print(text, flush=True)
        print(text, file=log, flush=True)
    report("COMMAND: " + " ".join(command))
    report("FM_TEST_ONLY=" + child_env["FM_TEST_ONLY"])
    report(f"ITERATIONS={a.iterations} LOAD_JOBS={a.load} LOAD_COMMAND=nice -n 20 yes (stdout=/dev/null)")
    report(f"SCHEDULE_CONTROLLED_INTERLEAVING={a.schedule}")
    report("CAUSE: watcher forks touch; test stops only watcher parent and backdates beacon; in-flight child may then overwrite the stale mtime before health reads it.")
    report("TOUCH_CHILD_THEORY=TRUE (see touch-theory.txt for isolated kernel-state and mtime proof)")
    report("HEAD=" + subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=a.repo, text=True).strip())
    report("DIFF_STAT=" + subprocess.check_output(["git", "diff", "--stat"], cwd=a.repo, text=True).strip())
    try:
        for _ in range(a.load):
            loads.append(subprocess.Popen(["nice", "-n", "20", "yes"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        report("OWNED_LOAD_PIDS=" + ",".join(str(proc.pid) for proc in loads))
        for n in range(1, a.iterations + 1):
            report(f"ITERATION {n}/{a.iterations}")
            result = subprocess.run(command, cwd=a.repo, env=child_env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            print(result.stdout, file=log, end="", flush=True)
            detail = a.output.with_name(f"{a.output.stem}-{n:03d}.txt")
            detail.write_text(result.stdout)
            report(f"RESULT iteration={n} exit={result.returncode}")
            if result.returncode:
                failed.append(n)
                report(result.stdout)
    finally:
        for proc in loads:
            if proc.poll() is None:
                proc.terminate()
        for proc in loads:
            proc.wait()
        report("LOAD_CLEANUP: all owned nice yes jobs stopped and reaped")
        if schedule_dir is not None:
            schedule_dir.cleanup()
            report("SCHEDULE_CLEANUP: task-local PATH wrappers removed")
    report(f"SUMMARY iterations={a.iterations} failures={len(failed)} failure_rate={len(failed) / a.iterations:.6f} failed_iterations={failed}")
sys.exit(bool(failed))
