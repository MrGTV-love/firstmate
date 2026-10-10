#!/usr/bin/env python3
"""Live driver for the Claude Stop auto-arm wait (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS).

It starts a real Claude Code session (`claude -p`) in a plain checkout of one
commit, with the real tracked .claude/settings.json Stop hooks, against a marked
disposable lab home. It can hold the real wake-queue lock (through the product's
own lock helpers) so the Stop-owned auto-arm publishes its claim late, the way a
busy home does. It only observes the product: process list, lab state files,
and Claude's own stream-json transcript.

usage: live-driver.py <label> <commit> <hold-mode> [seconds]
  none              no contention
  until-guard-exit  hold until the first guard process exits (+0.5 s), cap <seconds>
  fixed             hold <seconds> after the first guard process is seen
  past-claim-bound  hold until the first guard process exits, however long
  forever           hold until teardown: the auto-arm can never claim
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

WT = "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4KZJZJHZ8YSRTJH3TTFFVA8"
EV = "/Users/charlesabrooker/.no-mistakes/evidence/01M4KZJZJHZ8YSRTJH3TTFFVA8"

label, commit, mode = sys.argv[1], sys.argv[2], sys.argv[3]
secs = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
keep = os.environ.get("DRIVER_KEEP") == "1"

run = tempfile.mkdtemp(prefix="fm-wait-live.", dir=os.environ.get("TMPDIR", "/tmp"))
project, lab = f"{run}/project", f"{run}/lab"
state = f"{lab}/state"
transcript = f"{run}/claude.jsonl"
events = []
T0 = time.time()


def log(kind, **kw):
    rec = {"t": round(time.time() - T0, 3), "event": kind}
    rec.update(kw)
    events.append(rec)
    print(json.dumps(rec), flush=True)


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def pgrep(pattern):
    out = sh("pgrep", "-f", pattern).stdout.split()
    return [int(p) for p in out]


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


# --- disposable project (plain checkout of <commit>) and marked lab home -----
subprocess.check_call(["git", "clone", "-q", WT, project])
subprocess.check_call(["git", "-C", project, "checkout", "-q", "--detach", commit])
head = sh("git", "-C", project, "rev-parse", "HEAD").stdout.strip()
default_line = sh("grep", "-n", "^SYNC_WAIT_MS=", f"{project}/bin/fm-turnend-guard.sh").stdout.strip()
subprocess.check_call([f"{WT}/bin/fm-lab-home.sh", "create", lab], stdout=subprocess.DEVNULL)
open(f"{lab}/config/supervision-host-off", "w").close()
with open(f"{state}/task1.meta", "w") as f:
    f.write("project=fixture\nwindow=fixture\nbackend=tmux\n")
with open(f"{state}/.lock", "w") as f:
    f.write("9999999\n")
os.makedirs(f"{run}/tmux", exist_ok=True)
log("setup", label=label, commit=head, guard_default=default_line, hold_mode=mode, hold_seconds=secs,
    loadavg=os.getloadavg(), cores=os.cpu_count())

env = dict(os.environ)
for k in list(env):
    if k in ("NO_MISTAKES_GATE", "FM_GATE_REFUSE_BYPASS", "TMUX", "TMUX_PANE", "CLAUDECODE", "CLAUDE_PID",
             "CLAUDE_EFFORT", "FM_CLAUDE_AUTOARM_SYNC_WAIT_MS", "FM_CLAUDE_AUTOARM_EPOCH_FRESH",
             "FM_CLAUDE_TURNEND_BLOCK_BUDGET") or k.endswith("_OVERRIDE") and k.startswith("FM_") \
            or k.startswith("CLAUDE_CODE_"):
        del env[k]
if os.environ.get("DRIVER_SYNC_WAIT_MS") is not None:
    # Operator override under test: the hooks inherit it from the Claude process.
    env["FM_CLAUDE_AUTOARM_SYNC_WAIT_MS"] = os.environ["DRIVER_SYNC_WAIT_MS"]
    log("operator_override", FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=os.environ["DRIVER_SYNC_WAIT_MS"])
env.update(FM_HOME=lab, TMUX_TMPDIR=f"{run}/tmux", CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION="false",
           CLAUDE_CODE_SEND_FEEDBACK="0")

PROMPT = ("After reading the complete session-start digest, reply with exactly CYCLE0 and stop. "
          "Whenever a Stop hook feedback message wakes you or blocks you, reply with exactly ACK and stop. "
          "Never use any tool and never run any command.")
tf = open(transcript, "w")
claude = subprocess.Popen(
    ["claude", "-p", PROMPT, "--settings", '{"feedbackDrafts":"off"}', "--effort", "low",
     "--output-format", "stream-json", "--verbose"],
    cwd=project, env=env, stdout=tf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
    start_new_session=True)
log("claude_started", pid=claude.pid)

holder = None


def start_holder():
    global holder
    script = ('. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait_max "$2/state/.wake-queue.lock" 30 || exit 1; '
              ': > "$3/holder.acquired"; while [ ! -e "$3/holder.release" ]; do sleep 0.05; done; '
              'fm_lock_release "$2/state/.wake-queue.lock"; : > "$3/holder.released"')
    henv = dict(env)
    holder = subprocess.Popen(["bash", "-c", script, "_", project, lab, run], env=henv,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def release_holder(why):
    if holder is None or os.path.exists(f"{run}/holder.release"):
        return
    open(f"{run}/holder.release", "w").close()
    log("queue_lock_release_requested", why=why)


# --- observe ----------------------------------------------------------------
guard_pat = f"{project}/bin/fm-turnend-guard.sh"
arm_pat = f"{project}/bin/fm-claude-stop-autoarm.sh"
guards, arms = {}, {}          # pid -> record
first_guard = None
current_guard = None
ledger_seen = None
budget_seen = None
beacon_seen = False
session_started = False
acquired_logged = released_logged = False
deadline = time.time() + 900
done_at = None
while time.time() < deadline:
    now = time.time()
    if not session_started:
        txt = read(transcript) or ""
        if "SESSION START - " in txt or '"type":"assistant"' in txt:
            session_started = True
            log("session_start_digest_seen")
            if mode != "none":
                start_holder()
    if holder is not None:
        if not acquired_logged and os.path.exists(f"{run}/holder.acquired"):
            acquired_logged = True
            log("queue_lock_held_by_driver")
        if not released_logged and os.path.exists(f"{run}/holder.released"):
            released_logged = True
            log("queue_lock_released")
    # One guard run per Stop: the run starts when any guard process (the hook
    # shell or its command-substitution forks) appears and ends when none is left.
    live = set(pgrep(guard_pat))
    if live and (current_guard is None):
        n = len(guards) + 1
        current_guard = n
        guards[n] = {"n": n, "seen": now, "gone": None, "pids": sorted(live)}
        log("guard_run_started", stop=n, pids=sorted(live))
        if first_guard is None:
            first_guard = n
    elif not live and current_guard is not None:
        rec = guards[current_guard]
        rec["gone"] = now
        log("guard_run_ended", stop=rec["n"], wall_seconds=round(now - rec["seen"], 3))
        current_guard = None
    for pid in pgrep(arm_pat):
        if pid not in arms:
            arms[pid] = now
            ppid = sh("ps", "-o", "ppid=", "-p", str(pid)).stdout.strip()
            if not ppid or int(ppid) not in arms:
                log("autoarm_process_seen", pid=pid)
    led = read(f"{state}/.claude-autoarm-epoch")
    if led is not None:
        first = led.split("\n")[0]
        if first != ledger_seen:
            ledger_seen = first
            try:
                mt = os.stat(f"{state}/.claude-autoarm-epoch").st_mtime
            except OSError:
                mt = now
            rel = None
            if first_guard is not None:
                rel = round(mt - guards[first_guard]["seen"], 3)
            log("ledger", line=first, mtime_after_first_guard_seen=rel)
    bud = read(f"{state}/.turnend-claude-blocks")
    if bud != budget_seen:
        budget_seen = bud
        log("block_budget_file", content=bud)
    if not beacon_seen and os.path.exists(f"{state}/.last-watcher-beat"):
        beacon_seen = True
        log("watcher_beacon_seen")
    if first_guard is not None:
        g = guards[first_guard]
        if mode == "fixed" and now - g["seen"] >= secs:
            release_holder(f"fixed {secs}s after first guard seen")
        elif mode == "until-guard-exit":
            if g["gone"] is not None and now - g["gone"] >= 0.5:
                release_holder("first guard exited 0.5s ago")
            elif now - g["seen"] >= secs:
                release_holder(f"cap {secs}s reached, guard still running")
        elif mode == "past-claim-bound" and g["gone"] is not None:
            release_holder("first guard exited")
        if g["gone"] is not None and done_at is None:
            # settle: let the claim, the arm, and any forced continuation play out
            done_at = now + float(os.environ.get("DRIVER_SETTLE", "75"))
    if done_at is not None and now >= done_at and all(r["gone"] is not None for r in guards.values()):
        break
    if claude.poll() is not None:
        log("claude_exited_by_itself", rc=claude.returncode)
        break
    time.sleep(0.03)

# --- snapshot product state ---------------------------------------------------
health = sh("bash", "-c",
            '. "$1/bin/fm-wake-lib.sh"; if fm_watcher_healthy "$2/state" "$1/bin/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$2"; '
            'then echo healthy; else echo not-healthy; fi', "_", project, lab, env=env)
log("watcher_health", verdict=health.stdout.strip(), stderr=health.stderr.strip()[-300:])
log("watch_processes", pids=pgrep(f"{project}/bin/fm-watch"))
log("state_listing", files=sorted(os.listdir(state)))
log("ledger_final", content=read(f"{state}/.claude-autoarm-epoch"))
log("block_budget_final", content=read(f"{state}/.turnend-claude-blocks"))

# --- end the session: remove the need, then stop the process group -----------
release_holder("teardown")
try:
    os.remove(f"{state}/task1.meta")
except OSError:
    pass
try:
    claude.wait(timeout=25)
    log("claude_exit", rc=claude.returncode)
except subprocess.TimeoutExpired:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(claude.pid, sig)
        except OSError:
            pass
        try:
            claude.wait(timeout=15)
            break
        except subprocess.TimeoutExpired:
            continue
    log("claude_stopped_by_driver", rc=claude.returncode)
if holder is not None:
    try:
        holder.wait(timeout=10)
    except subprocess.TimeoutExpired:
        holder.kill()
time.sleep(2)
left = [p for p in pgrep(run) if p != os.getpid()]
for p in left:
    try:
        os.kill(p, signal.SIGTERM)
    except OSError:
        pass
time.sleep(1)
left2 = [p for p in pgrep(run) if p != os.getpid()]
for p in left2:
    try:
        os.kill(p, signal.SIGKILL)
    except OSError:
        pass
log("leftover_processes", after_session=left, after_term=left2)
tf.close()

# --- extract what Claude itself reported about the Stop hooks -----------------
extract = []
for raw in (read(transcript) or "").splitlines():
    try:
        o = json.loads(raw)
    except ValueError:
        if raw.strip():
            extract.append({"non_json": raw[:400]})
        continue
    t = o.get("type")
    if t == "system" and o.get("subtype") == "init":
        extract.append({"type": "init", "claude_code_version": o.get("claude_code_version"), "model": o.get("model"),
                        "cwd_is_lab_project": o.get("cwd") == os.path.realpath(project) or o.get("cwd") == project})
    elif t == "system" and str(o.get("subtype", "")).startswith("hook"):
        if o.get("hook_event") == "SessionStart":
            out = o.get("stdout") or o.get("output") or ""
            extract.append({"type": "hook", "subtype": o.get("subtype"), "hook_event": "SessionStart",
                            "hook_name": o.get("hook_name"), "exit_code": o.get("exit_code"),
                            "carries_fm_digest": "SESSION START - " in out})
        else:
            keep_keys = ("subtype", "hook_event", "hook_name", "exit_code", "outcome", "stdout", "stderr", "output")
            extract.append({"type": "hook", **{k: o[k] for k in keep_keys if k in o}})
    elif t == "system":
        extract.append({"type": "system", "subtype": o.get("subtype"),
                        "text": json.dumps({k: v for k, v in o.items() if k not in ("type", "subtype", "uuid", "session_id")})[:1500]})
    elif t in ("assistant", "user"):
        for c in (o.get("message") or {}).get("content") or []:
            if isinstance(c, dict) and c.get("type") == "text":
                extract.append({"type": t, "text": c["text"][:3000]})
            elif isinstance(c, dict) and c.get("type") == "tool_use":
                extract.append({"type": "assistant_tool_use", "name": c.get("name"), "input": json.dumps(c.get("input"))[:400]})
    elif t == "result":
        extract.append({"type": "result", "subtype": o.get("subtype"), "is_error": o.get("is_error"),
                        "num_turns": o.get("num_turns"), "result": str(o.get("result"))[:400]})
whole = read(transcript) or ""
summary = {
    "label": label, "commit": head, "guard_default": default_line, "hold_mode": mode,
    "turn_would_end_blind_blocks_in_transcript": whole.count("TURN WOULD END BLIND"),
    "did_not_claim_lines_in_transcript": whole.count("did not claim this home either"),
    "guard_runs": [{"stop": r["n"], "wall_seconds": None if r["gone"] is None else round(r["gone"] - r["seen"], 3)}
                   for r in guards.values()],
}
log("summary", **summary)
with open(f"{EV}/{label}.timeline.jsonl", "w") as f:
    for e in events:
        f.write(json.dumps(e) + "\n")
with open(f"{EV}/{label}.claude-extract.jsonl", "w") as f:
    for e in extract:
        f.write(json.dumps(e) + "\n")
if keep:
    print("KEPT", run)
else:
    shutil.rmtree(run, ignore_errors=True)
    print("REMOVED", run)
