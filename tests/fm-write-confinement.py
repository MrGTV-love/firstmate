"""Synthetic cross-task operations through the production profile builder."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
# The confined Claude worker's own session, and another session in the same home.
OWN_SESSION, OTHER_SESSION = "11111111-2222-4333-8444-555555555555", "99999999-8888-4777-8666-555555555555"
# The gate hooks no-mistakes installs, verbatim except NM_BIN, which names a
# model-free stand-in for the daemon client so no real daemon is contacted.
PRE_RECEIVE = r'''#!/bin/sh
# no-mistakes pre-receive hook
# Authorize the pushing process before any managed gate ref changes.
NM_BIN='@NM_BIN@'
if [ ! -f "$NM_BIN" ]; then
  NM_BIN="$(command -v no-mistakes 2>/dev/null || echo no-mistakes)"
fi
GATE_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null || :)
case "$GATE_DIR" in
  /*) ;;
  *)
    HOOK_PATH=$0
    case "$HOOK_PATH" in
      */*) HOOK_DIR=${HOOK_PATH%/*} ;;
      *) HOOK_DIR=. ;;
    esac
    GATE_DIR=$(cd "$HOOK_DIR/.." 2>/dev/null && (/bin/pwd -P 2>/dev/null || pwd -P) || :)
    ;;
esac
out=$(NM_HOOK_HELPER=1 "$NM_BIN" daemon admit-push --gate "$GATE_DIR" 2>&1)
status=$?
if [ $status -ne 0 ]; then
  printf 'no-mistakes: gate push refused before ref mutation:\n%s\n' "$out" >&2
  exit $status
fi
USER_HOOK="$GATE_DIR/hooks/pre-receive.no-mistakes-user"
if [ -x "$USER_HOOK" ]; then
  exec "$USER_HOOK"
fi
exit 0
'''
POST_RECEIVE = r'''#!/bin/sh
# no-mistakes post-receive hook
# Notifies the daemon of the push. Non-blocking: post-receive exit code is
# ignored by git, so we never reject the push here. Instead, failures are
# surfaced on stderr (so the pushing client sees them) and appended to
# notify-push.log inside the bare repo for later inspection.
NM_BIN='@NM_BIN@'
if [ ! -f "$NM_BIN" ]; then
  NM_BIN="$(command -v no-mistakes 2>/dev/null || echo no-mistakes)"
fi
# Resolve the bare repo dir explicitly. Git can invoke this hook from a cwd
# whose pwd collapses to "." (issue #269), which would pass "--gate ." and be
# rejected by the daemon ("invalid gate path: ."), so the pipeline never
# starts. Prefer git's own absolute dir query (Git 2.13+, May 2017), then fall
# back to the hook file's location so a poisoned PWD still cannot produce ".".
GATE_DIR=$(git rev-parse --absolute-git-dir 2>/dev/null || :)
case "$GATE_DIR" in
  /*) ;;
  *)
    HOOK_PATH=$0
    case "$HOOK_PATH" in
      */*) HOOK_DIR=${HOOK_PATH%/*} ;;
      *) HOOK_DIR=. ;;
    esac
    GATE_DIR=$(cd "$HOOK_DIR/.." 2>/dev/null && (/bin/pwd -P 2>/dev/null || pwd -P) || :)
    ;;
esac
case "$GATE_DIR" in
  /*) ;;
  *) GATE_DIR=$(/bin/pwd -P 2>/dev/null || pwd -P 2>/dev/null || pwd) ;;
esac
LOG="$GATE_DIR/notify-push.log"
nm_ts() { date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo unknown; }
notify_failed=0
while read oldrev newrev refname; do
	  set -- --gate "$GATE_DIR" \
	    --ref "$refname" \
	    --old "$oldrev" \
	    --new "$newrev"
	  i=0
	  while [ "$i" -lt "${GIT_PUSH_OPTION_COUNT:-0}" ]; do
	    opt=$(printenv "GIT_PUSH_OPTION_$i" 2>/dev/null || :)
	    set -- "$@" --push-option "$opt"
	    i=$((i + 1))
	  done
	  out=$(NM_HOOK_HELPER=1 "$NM_BIN" daemon notify-push "$@" 2>&1)
  status=$?
  if [ $status -ne 0 ]; then
    notify_failed=1
    {
      printf '[%s] notify-push failed for %s (exit %d)\n' "$(nm_ts)" "$refname" "$status"
      printf '%s\n\n' "$out"
    } >> "$LOG"
    {
      printf 'no-mistakes: notify-push failed for %s (exit %d):\n' "$refname" "$status"
      printf '%s\n' "$out"
      printf 'See %s for full history.\n' "$LOG"
    } >&2
  fi
done

if [ "$notify_failed" -eq 0 ]; then
  cat >&2 <<'BANNER'
_  _ ____    _  _ _ ____ ___ ____ _  _ ____ ____
|\ | |  |    |\/| | [__   |  |__| |_/  |___ [__
| \| |__|    |  | | ___]  |  |  | | \_ |___ ___]

  * Pipeline started

  Run no-mistakes to review.

BANNER
fi
exit 0
'''
FAKE_DAEMON_CLIENT = '''#!/bin/sh
[ "$1" = daemon ] || exit 2
command=$2
while [ $# -gt 0 ]; do
  [ "$1" != --gate ] || gate=$2
  shift
done
printf '%s\\n' "$command" >> "$gate/fixture-daemon.log"
'''
# Results that must be false in the unconfined control: each proves the
# fixture write is possible without the profile.
CONTROL_KEYS = ("a", "b", "c", "e-other.status", "e-task.other.status", "foreign-audit-denied", "symlink")


def git(*args, **kwargs):
    return subprocess.run(["git", *args], capture_output=True, text=True, env=dict(os.environ, **GIT_ENV), **kwargs)


def refused(path):
    path = Path(path)
    before = path.read_bytes() if path.exists() else None
    try:
        with path.open("a") as stream:
            stream.write("replaced")
    except PermissionError:
        return (path.read_bytes() if path.exists() else None) == before
    return False


def writable(path):
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            stream.write("written\n")
    except PermissionError:
        return False
    return True


def rename_refused(path):
    path = Path(path)
    moved = path.with_name(path.name + ".moved")
    try:
        path.rename(moved)
    except PermissionError:
        return path.exists()
    except FileNotFoundError:
        return False
    moved.rename(path)
    return False


def child(manifest):
    # A worker records into its home's ledger; the suite's fixture-wide off
    # switch would hide exactly the write under test.
    os.environ.pop("FM_DURATION_FILE", None)
    os.environ.update(GIT_ENV, NM_HOME=manifest["nm"], FM_DURATION_HOME=manifest["home"])
    os.environ.pop("FM_WRITE_CONFINEMENT", None)
    home = Path(manifest["home"])
    state = home / "state"
    data = home / "data"
    worktree = Path(manifest["worktree"])
    pool = Path(manifest["pool"])
    nested = Path(manifest["nested"])
    own_gate, other_gate = Path(manifest["own_gate"]), Path(manifest["other_gate"])
    other = manifest["other"]
    results = {}
    # B3 and B15 in the shared temp roots, narrowed to this run's other task so
    # the unconfined control can never touch a real session's directory.
    claude_tmp, user_tmp = Path(manifest["claude_tmp"]), Path(manifest["user_tmp"])
    subprocess.run(["/bin/sh", "-c", 'rm -rf "$1"/base."$2"*', "sh", str(claude_tmp), other], capture_output=True)
    results["a"] = (claude_tmp / f"base.{other}/payload").exists()
    subprocess.run(["find", str(user_tmp), "-mindepth", "1", "-maxdepth", "1", "-name", "fm-teardown.*", "-mtime", "+1",
                    "-exec", "rm", "-rf", "{}", "+"], capture_output=True)
    results["b"] = (user_tmp / f"fm-teardown.{other}/old").exists()
    try:
        eval('Path(manifest["home"]).joinpath("data/other/eval-target").unlink()')
        results["c"] = False
    except PermissionError:
        results["c"] = (data / "other/eval-target").read_text() == "original"
    (worktree / "new-file").write_text("nested root writable")
    results["d"] = (worktree / "new-file").read_text() == "nested root writable"
    # A real task must be able to create and commit its own branch without
    # receiving write access to other tasks' branches.
    for args in (["checkout", "-B", "fm/task"], ["add", "new-file"],
                 ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null",
                  "commit", "--allow-empty", "-m", "task fixture"]):
        result = git("-C", str(worktree), *args)
        if result.returncode:
            raise AssertionError(f"task Git operation {args[-3:]} failed: {result.stderr}")
    results["own-git-commit"] = True
    # The gate push runs receive-pack and the gate hooks inside this process tree.
    head = git("-C", str(worktree), "rev-parse", "HEAD").stdout.strip()
    push = git("-C", str(worktree), "push", "-u", "no-mistakes", "fm/task")
    daemon_log = own_gate / "fixture-daemon.log"
    results["gate-push"] = (push.returncode == 0
                            and git("--git-dir", str(own_gate), "rev-parse", "refs/heads/fm/task").stdout.strip() == head
                            and daemon_log.exists() and daemon_log.read_text().split() == ["admit-push", "notify-push"])
    results["push-upstream"] = git("-C", str(worktree), "config", "branch.fm/task.remote").stdout.strip() == "no-mistakes"
    fetch = git("-C", str(worktree), "fetch", "no-mistakes")
    results["fetch"] = fetch.returncode == 0 and git("-C", str(worktree), "rev-parse", "refs/remotes/no-mistakes/fm/task").returncode == 0
    (worktree / "new-file").write_text("stashed change")
    stash = git("-C", str(worktree), "stash", "push", "-m", "probe")
    results["stash"] = stash.returncode == 0 and git("-C", str(worktree), "stash", "drop").returncode == 0
    foreign_push = git("-C", str(worktree), "push", str(other_gate), "fm/task")
    results["refused-other-gate-push"] = (foreign_push.returncode != 0
                                          and git("--git-dir", str(other_gate), "rev-parse", "--verify", "-q", "refs/heads/fm/task").returncode != 0)
    other_branch = git("-C", str(worktree), "rev-parse", "fm/other").stdout
    git("-C", str(worktree), "update-ref", "refs/heads/fm/other", "HEAD")
    results["refused-other-branch"] = git("-C", str(worktree), "rev-parse", "fm/other").stdout == other_branch
    record = subprocess.run([sys.executable, str(Path(manifest["repo"]) / "bin/fm-duration.py"), "record", "fixture.write-confinement", "1234", "0"],
                            capture_output=True, text=True)
    ledger = data / "command-durations.jsonl"
    results["duration"] = (record.returncode == 0 and ledger.exists()
                           and any(json.loads(line).get("key") == "fixture.write-confinement" for line in ledger.read_text().splitlines()))
    # Process reads need no confinement variable: the sandbox refuses setuid ps
    # outright, and every tool then asks bin/fm-proc-info.py instead.
    spec = importlib.util.spec_from_file_location("fm_duration", Path(manifest["repo"]) / "bin/fm-duration.py")
    duration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(duration)
    try:
        subprocess.run(["ps", "-p", str(os.getpid())], capture_output=True)
        results["refused-setuid-ps"] = False
    except PermissionError:
        results["refused-setuid-ps"] = True
    table = duration.ps_table() or {}
    results["duration-ps-table"] = table.get(os.getpid(), (None,))[0] == os.getppid()
    try:
        idle = subprocess.run([sys.executable, str(Path(manifest["repo"]) / "bin/fm-duration.py"), "keep-going", "1", "--", "sleep", "20"],
                              capture_output=True, text=True, timeout=15)
        results["duration-keep-going"] = idle.returncode == 124 and "cpu_telemetry_unavailable" not in idle.stderr
    except subprocess.TimeoutExpired:
        results["duration-keep-going"] = False  # nothing stopped the inactive child
    gone = subprocess.Popen(["true"])
    gone.wait()
    since = int(time.time())
    results["duration-stale-holder"] = duration.holder_is_stale(gone.pid, since) and not duration.holder_is_stale(os.getpid(), since)
    # A group whose only member is a zombie answers a group signal with
    # EPERM on Darwin; the inventory must prove it complete, not re-raise.
    zombie = subprocess.Popen(["true"], start_new_session=True)
    for _ in range(100):
        states = subprocess.run([sys.executable, str(Path(manifest["repo"]) / "bin/fm-proc-info.py"), "table", "pid,stat"],
                                capture_output=True, text=True).stdout.splitlines()
        if f"{zombie.pid} Z" in states:
            break
        time.sleep(0.05)
    try:
        os.killpg(zombie.pid, 0)
        eperm = False
    except PermissionError:
        eperm = True
    reaped = type("Reaped", (), {"pid": zombie.pid, "poll": lambda self: 0})()
    try:
        duration.signal_group(reaped, signal.SIGKILL)
        results["duration-group-complete"] = eperm
    except (OSError, ValueError):
        results["duration-group-complete"] = False
    zombie.wait()
    # The orphan reaper and the lint CPU sample read process facts through the
    # helper or report the sample as unavailable, never a false 0.00.
    repo_bin = Path(manifest["repo"]) / "bin"
    reap_dir = Path(os.environ["TMPDIR"]).resolve() / "reap"
    reap_root = reap_dir / "fm-reap-probe"
    reap_root.mkdir(parents=True)
    gone = subprocess.Popen(["true"])
    gone.wait()
    (reap_root / ".fm-test-fixture").write_text(f"{gone.pid}\ngone owner\n")
    spawner = subprocess.run(["/bin/sh", "-c", 'python3 -c "import time; time.sleep(60)" "$1" >/dev/null 2>&1 & echo $!', "sh",
                              str(reap_root / "stub")], capture_output=True, text=True)
    orphan = int(spawner.stdout.strip())
    reap = subprocess.run(["bash", str(repo_bin / "fm-test-reap-orphans.sh"), "--tmpdir", str(reap_dir)],
                          capture_output=True, text=True)
    for _ in range(50):
        try:
            os.kill(orphan, 0)
        except ProcessLookupError:
            break
        time.sleep(0.1)
    else:
        os.kill(orphan, signal.SIGKILL)
        orphan = None
    results["reap-orphan"] = reap.returncode == 0 and orphan is not None
    telemetry = Path(os.environ["TMPDIR"]) / "lint-telemetry.tsv"
    subprocess.run(["bash", str(repo_bin / "fm-lint.sh"), "--telemetry", str(telemetry), str(repo_bin / "fm-proc-budget.sh")],
                   capture_output=True, text=True, env=dict(os.environ, FM_DURATION_FILE="off"))
    rows = dict(line.split("\t", 1) for line in telemetry.read_text().splitlines() if "\t" in line) if telemetry.exists() else {}
    cpu = (rows.get("aggregate_cpu_percent_start"), rows.get("aggregate_cpu_percent_end"))
    results["lint-cpu-sample"] = None not in cpu and all(value != "0.00" for value in cpu)
    with (state / "task.status").open("a") as stream:
        stream.write("working\n")
    results["e-append"] = (state / "task.status").read_text() == "working\n"
    for name, record in (("other.status", f"{other}.status"), ("task.other.status", "task.other.status")):
        try:
            (state / record).write_text("replaced")
            results["e-" + name] = False
        except PermissionError:
            results["e-" + name] = (state / record).read_text() == "original"
    # Shared home state the worker's own procedures write stays writable.
    # Process inspection runs through bin/fm-proc-info.py: the sandbox refuses
    # setuid ps, and a confined worker has no ps fallback.
    lavish_bin, lavish_state = data / "task/fake-bin", data / "task/lavish-state"
    lavish_bin.mkdir()
    lavish_state.mkdir()
    (lavish_bin / "lavish-axi").write_text(
        '#!/usr/bin/env bash\n[ "${1-}" = poll ] || exit 2\nprintf "polled\\n" >> "$2.polled"\n'
        'printf "session:\\n  status: ended\\n  ended_by: user\\n"\n')
    (lavish_bin / "lavish-axi").chmod(0o755)
    procedure_env = dict(os.environ, FM_ROOT_OVERRIDE=manifest["repo"], FM_HOME=str(home), FM_STATE_OVERRIDE=str(state),
                         FM_DATA_OVERRIDE=str(data), FM_CONFIG_OVERRIDE=str(home / "config"),
                         LAVISH_AXI_STATE_DIR=str(lavish_state), PATH=str(lavish_bin) + os.pathsep + os.environ["PATH"])
    board = data / "task/board.html"
    board.write_text("<h1>board</h1>\n")
    key = hashlib.sha256(str(board.resolve()).encode()).hexdigest()[:16]
    (lavish_state / "state.json").write_text(json.dumps({"sessions": {key: {"key": key, "file": str(board.resolve()), "status": "open",
                                                                            "url": "http://127.0.0.1:14387/session/0123456789abcdef"}}}))
    lavish = str(Path(manifest["repo"]) / "bin/fm-procevent-lavish.sh")
    procevent = str(Path(manifest["repo"]) / "bin/fm-procevent.sh")
    source = subprocess.run([lavish, "source-id", str(board)], env=procedure_env, capture_output=True, text=True).stdout.strip()
    register = subprocess.run([procevent, "register-task", "lavish", source, "task", "--", lavish, "poll", str(board)],
                              env=procedure_env, capture_output=True, text=True)
    listed = subprocess.run([procevent, "list"], env=procedure_env, capture_output=True, text=True).stdout
    poll = subprocess.run([procevent, "start", source], env=procedure_env, capture_output=True, text=True, timeout=120)
    polled = Path(str(board) + ".polled")
    results["procevent-poll"] = (poll.returncode == 0 and polled.exists() and polled.read_text() == "polled\n"
                                 and (state / f"procevent-inbox/{source}.1.result").exists())
    handled = subprocess.run([procevent, "handled", source, "1"], env=procedure_env, capture_output=True, text=True)
    retire = subprocess.run([procevent, "retire", source], env=procedure_env, capture_output=True, text=True)
    results["procevent-board"] = (bool(source) and register.returncode == 0 and source in listed and handled.returncode == 0 and retire.returncode == 0
                                  and source not in subprocess.run([procevent, "list"], env=procedure_env, capture_output=True, text=True).stdout)
    budget = subprocess.run(["bash", str(Path(manifest["repo"]) / "bin/fm-proc-budget.sh"), "--", "true"],
                            env=procedure_env, capture_output=True, text=True)
    results["proc-budget"] = budget.returncode == 0
    ancestry = subprocess.run(["bash", "-c", 'exec -a claude bash -c \'. "$0"; fm_harness_ancestry_pids; echo "self=$$"\' "$1"', "probe",
                               str(Path(manifest["repo"]) / "bin/fm-session-lock-lib.sh")], env=procedure_env, capture_output=True, text=True)
    lines = ancestry.stdout.split()
    results["session-lock-ancestry"] = len(lines) >= 2 and lines[-1] == "self=" + lines[0]
    ledger = subprocess.run([str(Path(manifest["repo"]) / "bin/fm-fleet-ledger.sh"), "appended", str(home / "config"), str(state / "task.status")],
                            env=procedure_env, capture_output=True, text=True)
    results["fleet-ledger"] = (ledger.returncode == 0 and (state / "fleet-ledger.jsonl").exists()
                               and any(json.loads(line).get("task") == "task" for line in (state / "fleet-ledger.jsonl").read_text().splitlines()))
    (state / "task.inbox/001.msg").rename(state / "task.inbox/handled/001.msg")
    results["inbox-handled"] = (state / "task.inbox/handled/001.msg").exists()
    busy = subprocess.run(["bash", str(Path(manifest["repo"]) / "bin/fm-busy-event.sh"),
                           "apply", str(state), "task", "idle", "--current-gen", "--source", "omp-ext", "--event", "agent_end"],
                          text=True, capture_output=True)
    results["busy-transition"] = busy.returncode == 0 and "state=idle" in (state / "task.busy-state").read_text()
    session = data / "task/proof-session.jsonl"
    session.touch()
    proof_script = data / "task/proof-writer.ts"
    proof_script.write_text('''
import { readFileSync } from "node:fs";
const { createTaskSessionProof } = await import(process.argv[2]);
const { createGuardService } = await import(process.argv[5]);
const { readGuardAudit } = await import(process.argv[6]);
const state = process.argv[3], session = process.argv[4], other = process.argv[7];
const record = { hook: 'tool_result', tool: 'read', decision: 'clear', enforcement: 'result_pass', branch: 'trusted_read', error_type: null, request_started: false };
const context = { home: state + '/..', config: state + '/../config', state, task: 'task', noHelpers: true };
const legacy = readFileSync(state + '/jev-guard.jsonl', 'utf8');
createGuardService(context).record(record);
const history = readGuardAudit(state).trim().split('\\n').map(JSON.parse);
if (!history.some(row => row.task === 'legacy') || !history.some(row => row.task === 'task' && row.decision === 'clear' && row.request_started === false)) throw Error('audit history lost');
if (readFileSync(state + '/jev-guard.jsonl', 'utf8') !== legacy) throw Error('legacy audit changed');
let foreignDenied = false;
try { createGuardService({ ...context, task: other }).record(record); }
catch (error) { if (error.errorType !== 'AuditUnavailableError') throw error; foreignDenied = true; }
const manager = { getSessionFile: () => session };
const owner = { sessionManager: manager, waitForSessionTransition: async () => {} };
const ctx = { sessionManager: manager };
const proof = createTaskSessionProof(state, "task", { list: () => [{ kind: "main", session: owner }] });
proof.start(ctx);
const current = JSON.parse(readFileSync(state + "/task.omp-session.json", "utf8"));
if (current.current_session_file !== session || current.task_session_file !== session || current.pid !== process.pid) throw Error("wrong session binding");
proof.shutdown(ctx);
if (JSON.parse(readFileSync(state + "/task.omp-session.json", "utf8")).current_session_file !== "") throw Error("session proof not invalidated");
console.log(JSON.stringify({ foreignDenied }));
''')
    proof_run = subprocess.run(["bun", str(proof_script), str(Path(manifest["repo"]) / ".omp/extensions/lib/fm-task-session.ts"), str(state), str(session),
                                str(Path(manifest["repo"]) / "bin/ten-levels/extensions/report.ts"), str(Path(manifest["repo"]) / "bin/fm-jev-audit-read.mjs"), other],
                               env=dict(os.environ, FM_SPAWN_GEN="proof-probe", FM_WRITE_CONFINEMENT="seatbelt-v1"), capture_output=True, text=True)
    results["native-session-proof"] = proof_run.returncode == 0
    results["task-audit-written"] = proof_run.returncode == 0
    results["foreign-audit-denied"] = json.loads(proof_run.stdout)["foreignDenied"] if proof_run.returncode == 0 else False
    # A symlink in the allowed root must not turn a foreign target writable.
    try:
        (worktree / "escape" / "eval-target").write_text("replaced")
        results["symlink"] = False
    except PermissionError:
        results["symlink"] = True
    # One refused write per protected asset class, plus Main-owned records of
    # this task (its metadata, relaunch control and installed Git hooks).
    for name, path in manifest["protected"].items():
        results["refused-" + name] = refused(path)
    for name, path in manifest["writable"].items():
        results[name] = writable(path)
    # The transcript container holds other sessions' transcripts: moving it to
    # a writable place must fail while this session's own transcript writes.
    container = manifest.get("transcript_container")
    if container:
        moved = Path(os.environ["TMPDIR"]) / "moved-transcripts"
        try:
            Path(container).rename(moved)
        except PermissionError:
            results["refused-transcript-container-rename"] = Path(container).is_dir()
        else:
            moved.rename(container)
            results["refused-transcript-container-rename"] = False
    # Renaming a protected folder, or a folder above one, would move it away.
    for name, path in manifest["renamed"].items():
        results["refused-rename-" + name] = rename_refused(path)
    print(json.dumps(results, sort_keys=True))
    return results


def write(path, text="original"):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def scope_key(worktree):
    return subprocess.check_output(["bun", "-e", "console.log(Bun.hash.wyhash(require('path').resolve(process.argv[1])).toString(16).padStart(16,'0'))",
                                    str(worktree)], text=True).strip()


def fixture(repo, base, harness, user_home, other):
    """Lay out one fresh home, project, gates and foreign assets under base."""
    base.mkdir(parents=True)
    base = base.resolve()
    home, nm = base / "home", base / "nm"
    state, data = home / "state", home / "data"
    project = home / "projects/project"
    worktree, nested, pool = project / ".claude/worktrees/fm-task", project / ".claude/worktrees/fm-other", base / "pool/5/other"
    write(project / "README")
    for args in (["init", "-q", "-b", "main", str(project)], ["-C", str(project), "add", "README"],
                 ["-C", str(project), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "-m", "init"],
                 ["-C", str(project), "worktree", "add", "-q", "-b", "fm/task", str(worktree)],
                 ["-C", str(project), "worktree", "add", "-q", "-b", "fm/other", str(nested)],
                 ["-C", str(project), "worktree", "add", "-q", "-b", "fm/pool", str(pool)]):
        result = git(*args)
        assert result.returncode == 0, (args, result.stderr)
    own_gate = nm / "repos" / (hashlib.sha256(str(project).encode()).hexdigest()[:12] + ".git")
    other_gate = nm / "repos/000000000000.git"
    fake_client = base / "bin/no-mistakes"
    write(fake_client, FAKE_DAEMON_CLIENT)
    fake_client.chmod(0o755)
    for gate in (own_gate, other_gate):
        assert git("init", "-q", "--bare", str(gate)).returncode == 0
    for name, text in (("pre-receive", PRE_RECEIVE), ("post-receive", POST_RECEIVE)):
        write(own_gate / "hooks" / name, text.replace("@NM_BIN@", str(fake_client)))
        (own_gate / "hooks" / name).chmod(0o755)
    assert git("-C", str(worktree), "remote", "add", "no-mistakes", str(own_gate)).returncode == 0
    # Another task's directories in the shared Claude temp root, its own temp
    # root and an aged test directory under ~/tmp that carries its id.
    claude_tmp = Path(f"/private/tmp/claude-{os.getuid()}")
    write(claude_tmp / f"base.{other}/payload")
    write(Path(f"/private/tmp/fm-{other}/payload"))
    user_tmp = user_home / "tmp"
    write(user_tmp / f"fm-teardown.{other}/old")
    os.utime(user_tmp / f"fm-teardown.{other}/old", (1, 1))
    os.utime(user_tmp / f"fm-teardown.{other}", (1, 1))
    write(data / "other/eval-target")
    write(data / "other/file")
    (data / "task").mkdir(parents=True)
    (worktree / "escape").symlink_to(data / "other", target_is_directory=True)
    write(state / f"{other}.meta", f"window=fmtest:fm-{other}\nworktree={nested}\nproject=fmtest\n")
    # Tasks whose ids extend this task's id, and are part of it, own ~/tmp
    # entries that carry both ids.
    for related in ("task-2", "ask"):
        write(state / f"{related}.meta", "project=fmtest\n")
    write(user_tmp / "fm-teardown.task-2/old")
    for name in (f"{other}.status", "task.other.status"):
        write(state / name)
    write(state / f"{other}.jev-guard.jsonl", json.dumps({"at": 2, "task": other, "decision": "clear"}) + "\n")
    write(state / "jev-guard.jsonl", json.dumps({"at": 1, "task": "legacy", "decision": "clear"}) + "\n")
    write(state / "task.status", "")
    write(state / "task.meta", f"spawn_gen=proof-probe\nwindow=fmtest:fm-task\nworktree={worktree}\nproject=fmtest\n")
    write(state / "task.inbox/001.msg", "message")
    (state / "task.inbox/handled").mkdir()
    (state / "task.git-hooks").mkdir()
    subprocess.run(["bash", str(repo / "bin/fm-busy-event.sh"), "arm", str(state), "task"], check=True, capture_output=True)
    write(home / "README")
    write(home / "config/crew-harness")
    write(home / "config/fleet-ledger", "")
    write(home / ".env")
    for name in ("secondmates.md", "captain.md", "backlog.md"):
        write(data / name)
    write(base / "other-home/state/x.status")
    protected = {
        "project-primary": project / "README", "primary-index": project / ".git/index", "home-primary": home / "README",
        "config": home / "config/crew-harness", "env": home / ".env",
        "other-worktree-nested": nested / "README", "other-worktree-pool": pool / "README",
        "other-data": data / "other/file", "other-home": base / "other-home/state/x.status", "other-gate": other_gate / "config",
        "other-task-temp": Path(f"/private/tmp/fm-{other}/payload"),
        "extending-task-home-tmp": user_tmp / "fm-teardown.task-2/old",
        "shared-legacy-audit": state / "jev-guard.jsonl",
        "main-meta": state / "task.meta", "main-control-relaunch": state / "task.control-relaunch",
        "main-git-hooks": state / "task.git-hooks/pre-commit",
        "data-secondmates": data / "secondmates.md", "data-captain": data / "captain.md", "data-backlog": data / "backlog.md",
    }
    # A task created after the profile was built: its records are written
    # only after the build, so no launch-time task list can name it.
    late = {"late-task-meta": state / "late.meta", "late-task-control-relaunch": state / "late.control-relaunch"}
    protected.update(late)
    renamed = {"other-data": data / "other", "worktree-parent": pool.parent, "gates": nm / "repos",
               "state": state, "claude-temp-session": claude_tmp / f"base.{other}",
               "git-refs": project / ".git/refs", "git-worktrees": project / ".git/worktrees"}
    slug = re.sub(r"[^A-Za-z0-9]", "-", str(worktree))
    claude_code = (".claude/CLAUDE.md", ".claude/rules/rule.md", ".claude/agents/agent.md", ".claude/commands/command.md",
                   ".claude/skills/skill/SKILL.md", ".claude/plugins/plugin.json", ".claude/hooks/hook.sh", ".claude/settings.json",
                   ".claude/settings.local.json", ".claude/.credentials.json", ".claude/projects/p/memory/MEMORY.md", ".claude/statusline.sh",
                   ".claude/shell-snapshots/snapshot-zsh.sh", ".claude/session-env/session/hook.sh",
                   f".claude/session-env/{OTHER_SESSION}/hook.sh", f".claude/file-history/{OTHER_SESSION}/backup",
                   f".claude/tasks/{OTHER_SESSION}/1.json", ".claude/sessions/1234.json",
                   f".claude/todos/{OWN_SESSION}-agent-{OWN_SESSION}.json", f".claude/projects/{slug}/{OTHER_SESSION}.jsonl",
                   ".claude/projects/p/session.jsonl")
    omp_code = (".omp/agent/config.yml", ".omp/agent/models.yml", ".omp/agent/auth.json", ".omp/agent/.env",
                ".omp/agent/extensions/extension.ts", ".omp/agent/settings.json", ".omp/agent/managed-skills/skill.md",
                ".omp/agent/memories/memory.md", ".omp/plugins/plugin.ts", ".omp/run/daemons/0000000000000000/broker.pid")
    for name in claude_code + omp_code + (".codex/config.toml", ".dsh/config"):
        write(user_home / name)
    protected.update({"codex-home": user_home / ".codex/config.toml", "dsh-home": user_home / ".dsh/config"})
    protected.update({"harness" + name.replace(slug, "own-project").replace("/", "-"): user_home / name for name in claude_code + omp_code})
    writable_paths = {"tool-cache": user_home / ".cache/fm-test-slots/probe", "own-home-tmp": user_tmp / "fm-task-probe/file",
                      "own-data": data / "task/probe"}
    if harness == "claude":
        writable_paths.update({"claude-transcript": user_home / f".claude/projects/{slug}/{OWN_SESSION}.jsonl",
                               "claude-transcript-sidecar": user_home / f".claude/projects/{slug}/{OWN_SESSION}/subagents/agent.jsonl",
                               "claude-session-env": user_home / f".claude/session-env/{OWN_SESSION}/hook.sh",
                               "claude-json-backup": user_home / ".claude/backups/.claude.json.backup.1",
                               "claude-file-history": user_home / f".claude/file-history/{OWN_SESSION}/backup",
                               "claude-tasks": user_home / f".claude/tasks/{OWN_SESSION}/1.json",
                               "claude-history": user_home / ".claude/history.jsonl",
                               "claude-history-lock": user_home / ".claude/history.jsonl.lock/lock",
                               "claude-statsig": user_home / ".claude/statsig/cache", "claude-debug": user_home / ".claude/debug/session.txt"})
        # Claude's config carries MCP server commands later sessions run.
        protected.update({"claude-json": user_home / ".claude.json", "claude-json-config-dir": user_home / ".claude/.claude.json",
                          "claude-json-config-dir-atomic": user_home / ".claude/.claude.json.tmp.1"})
    else:
        writable_paths.update({"omp-agent-db": user_home / ".omp/agent/agent.db", "omp-agent-db-wal": user_home / ".omp/agent/agent.db-wal",
                               "omp-models-db-shm": user_home / ".omp/agent/models.db-shm",
                               "omp-session": user_home / ".omp/agent/sessions/session.jsonl",
                               "omp-daemon-scope": user_home / ".omp/run/daemons" / scope_key(worktree) / "broker.pid"})
    return {"repo": str(repo), "home": str(home), "nm": str(nm), "worktree": str(worktree), "nested": str(nested), "pool": str(pool),
            "own_gate": str(own_gate), "other_gate": str(other_gate), "other_home": str(base / "other-home"), "other": other,
            "claude_tmp": str(claude_tmp), "user_tmp": str(user_tmp), "late": [str(path) for path in late.values()],
            "transcript_container": str(user_home / f".claude/projects/{slug}") if harness == "claude" else "",
            "protected": {name: str(path) for name, path in protected.items()},
            "writable": {name: str(path) for name, path in writable_paths.items()},
            "renamed": {name: str(path) for name, path in renamed.items()}}


def build_profile(repo, manifest, harness, profile, env):
    home = Path(manifest["home"])
    command = [sys.executable, str(repo / "bin/fm-write-confinement.py"), "--worktree", manifest["worktree"],
               "--home", str(home), "--config", str(home / "config"), "--projects", str(home / "projects"),
               "--data", str(home / "data/task"), "--state", str(home / "state"), "--task", "task", "--branch", "fm/task",
               "--harness", harness, "--protect", manifest["other_home"], "--profile", str(profile)]
    if harness == "claude":
        command += ["--claude-session", OWN_SESSION]
    subprocess.run(command, env=dict(env, NM_HOME=manifest["nm"]), check=True)


if sys.argv[1] == "--child":
    results = child(json.loads(sys.argv[2]))
    sys.exit(0 if all(results.values()) else 1)

repo = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
for harness in ("claude", "omp"):
    for mode in ("baseline", "confined"):
        base = root / f"{harness}-{mode}"
        user_home = base / "user-home"
        user_home.mkdir(parents=True)
        other = f"wc-other-{os.getpid()}-{harness}-{mode}"
        shared = [Path(f"/private/tmp/claude-{os.getuid()}/base.{other}"), Path(f"/private/tmp/fm-{other}")]
        try:
            manifest = fixture(repo, base / "fixture", harness, user_home.resolve(), other)
            env = {name: value for name, value in os.environ.items() if name not in ("CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR")}
            env.update(HOME=str(user_home.resolve()), TMPDIR=str(base / "temp"), TMP=str(base / "temp"), TEMP=str(base / "temp"))
            (base / "temp").mkdir()
            profile = base / "profile.sb"
            build_profile(repo, manifest, harness, profile, env)
            for path in manifest["late"]:
                write(path, "window=fmtest:fm-late\nkind=ship\n")
            command = [sys.executable, __file__, "--child", json.dumps(manifest)]
            invocation = command if mode == "baseline" else ["/usr/bin/sandbox-exec", "-f", str(profile)] + command
            result = subprocess.run(invocation, capture_output=True, text=True, env=env)
        finally:
            for path in shared:
                shutil.rmtree(path, ignore_errors=True)
        if not result.stdout.strip():
            raise AssertionError(f"{harness} {mode}: exit={result.returncode} stderr={result.stderr}")
        actual = json.loads(result.stdout)
        print(f"{harness} {mode}: " + json.dumps(actual, sort_keys=True))
        if mode == "baseline":
            for name in actual:
                if name in CONTROL_KEYS or name.startswith("refused-"):
                    assert actual[name] is False, (harness, mode, name, actual)
        else:
            assert result.returncode == 0 and all(actual.values()), (harness, mode, result.stderr, actual)
