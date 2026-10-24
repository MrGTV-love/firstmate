"""Synthetic cross-task operations through the production profile builder."""
import json
import os
from pathlib import Path
import subprocess
import sys


def child(manifest):
    state = Path(manifest["state"])
    foreign = Path(manifest["foreign"])
    results = {}
    subprocess.run(["/bin/sh", "-c", 'rm -rf "$1"/claude-501/base.*', "sh", str(foreign)], capture_output=True)
    results["a"] = (foreign / "claude-501/base.other/payload").exists()
    subprocess.run(["find", str(foreign / "home/tmp"), "-type", "f", "-mtime", "+1", "-delete"], capture_output=True)
    results["b"] = (foreign / "home/tmp/old").exists()
    try:
        eval('Path(manifest["foreign"]).joinpath("eval-target").unlink()')
        results["c"] = False
    except PermissionError:
        results["c"] = (foreign / "eval-target").read_text() == "original"
    worktree = Path(manifest["worktree"])
    (worktree / "new-file").write_text("nested root writable")
    results["d"] = (worktree / "new-file").read_text() == "nested root writable"
    # A real task must be able to create and commit its own branch without
    # receiving write access to the common refs/logs directory.
    for args in (["checkout", "-B", "fm/task"], ["add", "new-file"],
                 ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "task fixture"]):
        git = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", str(worktree)] + args, capture_output=True, text=True)
        if git.returncode:
            raise AssertionError(f"task Git operation {args[0]} failed: {git.stderr}")
    results["own-git-commit"] = True
    with (state / "task.status").open("a") as stream:
        stream.write("working\n")
    results["e-append"] = (state / "task.status").read_text() == "working\n"
    for name in ("other.status", "task.other.status"):
        try:
            (state / name).write_text("replaced")
            results["e-" + name] = False
        except PermissionError:
            results["e-" + name] = (state / name).read_text() == "original"
    busy = subprocess.run(["bash", str(Path(manifest["repo"]) / "bin/fm-busy-event.sh"),
                           "apply", str(state), "task", "idle", "--current-gen", "--source", "omp-ext", "--event", "agent_end"],
                          text=True, capture_output=True)
    results["busy-transition"] = busy.returncode == 0 and "state=idle" in (state / "task.busy-state").read_text()
    data = state.parent / "data/task"
    session = data / "proof-session.jsonl"
    session.touch()
    (state / "task.meta").write_text("spawn_gen=proof-probe\n")
    proof_script = data / "proof-writer.ts"
    proof_script.write_text('''
import { readFileSync } from "node:fs";
const { createTaskSessionProof } = await import(process.argv[2]);
const { createGuardService } = await import(process.argv[5]);
const { readGuardAudit } = await import(process.argv[6]);
const state = process.argv[3], session = process.argv[4];
const record = { hook: 'tool_result', tool: 'read', decision: 'clear', enforcement: 'result_pass', branch: 'trusted_read', error_type: null, request_started: false };
const context = { home: state + '/..', config: state + '/../config', state, task: 'task', noHelpers: true };
const legacy = readFileSync(state + '/jev-guard.jsonl', 'utf8');
createGuardService(context).record(record);
const history = readGuardAudit(state).trim().split('\\n').map(JSON.parse);
if (!history.some(row => row.task === 'legacy') || !history.some(row => row.task === 'task' && row.decision === 'clear' && row.request_started === false)) throw Error('audit history lost');
if (readFileSync(state + '/jev-guard.jsonl', 'utf8') !== legacy) throw Error('legacy audit changed');
let foreignDenied = false;
try { createGuardService({ ...context, task: 'other' }).record(record); }
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
                                str(Path(manifest["repo"]) / "bin/ten-levels/extensions/report.ts"), str(Path(manifest["repo"]) / "bin/fm-jev-audit-read.mjs")],
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
    if manifest.get("result"):
        Path(manifest["result"]).write_text(json.dumps(results, sort_keys=True))
    print(json.dumps(results, sort_keys=True))
    return results


def seed_audits(state):
    (state / "jev-guard.jsonl").write_text(json.dumps({"at": 1, "task": "legacy", "decision": "clear"}) + "\n")
    (state / "other.jev-guard.jsonl").write_text(json.dumps({"at": 2, "task": "other", "decision": "clear"}) + "\n")
    (state / "task.jev-guard.jsonl").unlink(missing_ok=True)


if sys.argv[1] == "--child":
    results = child(json.loads(sys.argv[2]))
    sys.exit(0 if all(results.values()) else 1)

repo = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
worktree = root / "project/.claude/worktrees/fm-task"
foreign = root / "foreign"
(foreign / "claude-501/base.other").mkdir(parents=True)
(foreign / "home/tmp").mkdir(parents=True)
(worktree / "escape").symlink_to(foreign, target_is_directory=True)
manifest = {"repo": str(repo), "worktree": str(worktree), "state": str(root / "state"), "foreign": str(foreign)}
command = [sys.executable, __file__, "--child", json.dumps(manifest)]
for mode in ("baseline", "confined"):
    seed_audits(root / "state")
    (foreign / "claude-501/base.other").mkdir(parents=True, exist_ok=True)
    (foreign / "claude-501/base.other/payload").write_text("original")
    (foreign / "home/tmp/old").write_text("original")
    os.utime(foreign / "home/tmp/old", (1, 1))
    (foreign / "eval-target").write_text("original")
    for name in ("other.status", "task.other.status"):
        (root / "state" / name).write_text("original")
    (root / "state/task.status").write_text("")
    subprocess.run(["bash", str(repo / "bin/fm-busy-event.sh"), "arm", str(root / "state"), "task"], check=True, capture_output=True)
    profile = root / "profile.sb"
    subprocess.run([sys.executable, str(repo / "bin/fm-write-confinement.py"),
                    "--worktree", str(worktree), "--data", str(root / "data/task"),
                    "--state", str(root / "state"), "--task", "task", "--branch", "fm/task", "--temp", str(root / "temp"),
                    "--harness", "claude", "--agent-dir", str(root / "agent"), "--profile", str(profile)], check=True)
    invocation = command if mode == "baseline" else ["/usr/bin/sandbox-exec", "-f", str(profile)] + command
    result = subprocess.run(invocation, capture_output=True, text=True,
                            env=dict(os.environ, TMPDIR=str(root / "temp"), TMP=str(root / "temp"), TEMP=str(root / "temp")))
    if not result.stdout.strip():
        raise AssertionError(f"{mode}: exit={result.returncode} stderr={result.stderr}")
    actual = json.loads(result.stdout)
    print(mode + ": " + json.dumps(actual, sort_keys=True))
    if mode == "baseline":
        for name in ("a", "b", "c", "e-other.status", "e-task.other.status", "foreign-audit-denied", "symlink"):
            assert actual[name] is False, (mode, name, actual)
    else:
        assert result.returncode == 0 and all(actual.values()), (mode, result.stderr, actual)

if os.environ.get("FM_WRITE_CONFINEMENT_LIVE_RUN") == "1":
    import shlex
    import shutil
    import signal
    import time
    checked = 0
    for harness in ("omp", "claude"):
        executable = shutil.which(harness)
        if executable is None:
            print(f"skip: live: {harness} absent")
            continue
        checked += 1
        seed_audits(root / "state")
        home = Path.home()
        # Keep the installed runtime's HOME, as production does. Authentication
        # is neither copied nor used: EOF submits no prompt and the agent store
        # is synthetic. The daemon scope is unique to this fixture project.
        scope = subprocess.check_output(["bun", "-e", "console.log(Bun.hash.wyhash(require('path').resolve(process.argv[1])).toString(16).padStart(16,'0'))", str(worktree)], text=True).strip()
        daemon_dir = home / ".omp/run/daemons" / scope
        agent = root / "agent" / harness
        agent.mkdir()
        data = root / "data/task"
        output = data / (harness + "-result.json")
        live_manifest = dict(manifest, result=str(output))
        # Reset every foreign target after the destructive baseline control.
        (foreign / "claude-501/base.other").mkdir(parents=True, exist_ok=True)
        (foreign / "claude-501/base.other/payload").write_text("original")
        (foreign / "home/tmp/old").write_text("original")
        os.utime(foreign / "home/tmp/old", (1, 1))
        (foreign / "eval-target").write_text("original")
        for name in ("other.status", "task.other.status"):
            (root / "state" / name).write_text("original")
        (root / "state/task.status").write_text("")
        subprocess.run(["bash", str(repo / "bin/fm-busy-event.sh"), "arm", str(root / "state"), "task"], check=True, capture_output=True)
        env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(root / "temp"),
               "OMP_SKIP_SETUP": "1", "DISABLE_AUTOUPDATER": "1", "PI_CODING_AGENT_DIR": str(agent),
               "CLAUDE_CONFIG_DIR": str(agent), "PI_CONFIG_DIR": ".omp"}
        profile = data / (harness + ".sb")
        subprocess.run([sys.executable, str(repo / "bin/fm-write-confinement.py"),
                        "--worktree", str(worktree), "--data", str(data), "--state", str(root / "state"),
                        "--task", "task", "--branch", "fm/task", "--temp", str(root / "temp"), "--harness", harness,
                        "--agent-dir", str(agent), "--profile", str(profile)], env=env, check=True)
        child_command = [sys.executable, str(Path(__file__).resolve()), "--child", json.dumps(live_manifest)]
        if harness == "omp":
            extension = data / "probe.ts"
            extension.write_text('export default function(pi) { pi.on("session_start", async () => { const p = Bun.spawn(' + json.dumps(child_command) + ', {stdout:"ignore",stderr:"ignore"}); await p.exited; }); }')
            command = [executable, "--mode", "rpc", "--no-ui", "--no-extensions", "-e", str(extension),
                       "--no-skills", "--no-rules", "--no-title", "--no-lsp", "--no-tools", "--session-dir", str(data / "sessions"), "--cwd", str(worktree)]
        else:
            settings = data / "settings.json"
            settings.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": shlex.join(child_command)}]}]}}))
            command = [executable, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--no-session-persistence", "--setting-sources", "", "--settings", str(settings)]
        version = subprocess.check_output([executable, "--version"], text=True).strip().splitlines()[0]
        process = subprocess.Popen(["/usr/bin/sandbox-exec", "-f", str(profile)] + command,
                                   env=env, cwd=worktree, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True, text=True)
        try:
            stdout, stderr = process.communicate("", timeout=30)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.communicate()
            # Only inspect the exact synthetic project's daemon scope, never
            # enumerate the shared daemon namespace. Normal idle is 3 seconds.
            for pidfile in [daemon_dir / "broker.pid"] if (daemon_dir / "broker.pid").exists() else []:
                record = json.loads(pidfile.read_text())
                pid = int(record["pid"])
                for _ in range(100):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.1)
                else:
                    # A stale pidfile alone is not ownership: Darwin may reuse
                    # the PID. Require this process to hold the native lease on
                    # this exact private scope before any signal.
                    def holds_lease():
                        holder = subprocess.run(["/usr/sbin/lsof", "-t", "-a", "-p", str(pid), "--", str(pidfile)],
                                                capture_output=True, text=True)
                        return holder.returncode == 0 and holder.stdout.split() == [str(pid)]
                    if holds_lease():
                        os.kill(pid, signal.SIGTERM)
                        for _ in range(50):
                            if not holds_lease():
                                break
                            time.sleep(0.1)
                        else:
                            if holds_lease():
                                os.kill(pid, signal.SIGKILL)
                            assert not holds_lease(), "private broker lease survived cleanup"
                    raise AssertionError(f"private {harness} broker did not idle-exit: {pid}; cleanup checked only its native lease")
        if not output.exists():
            import re
            diagnostics = re.findall(r"EPERM|EACCES|EROFS|unable to open database file|Operation not permitted|permission denied", stdout + stderr)
            fields = re.findall(r"^\s*(?:path|syscall):\s*[\"']([^\"']+)[\"']", stdout + stderr, re.MULTILINE)
            raise AssertionError(f"{harness} {version}: startup acceptance hook not reached (exit {process.returncode}); codes={diagnostics}; paths/syscalls={fields}")
        actual = json.loads(output.read_text())
        assert process.returncode == 0 and all(actual.values()), (harness, version, actual)
        print(f"live {harness} {version}: " + json.dumps(actual, sort_keys=True))
    assert checked, "no installed harness checked"
