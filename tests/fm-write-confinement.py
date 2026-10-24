"""Synthetic cross-task operations through the production profile builder."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

GIT_ENV = {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
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


def child(manifest):
    # A worker records into its home's ledger; the suite's fixture-wide off
    # switch would hide exactly the write under test.
    os.environ.pop("FM_DURATION_FILE", None)
    os.environ.update(GIT_ENV, NM_HOME=manifest["nm"], FM_DURATION_HOME=manifest["home"])
    home = Path(manifest["home"])
    state = home / "state"
    data = home / "data"
    worktree = Path(manifest["worktree"])
    pool = Path(manifest["pool"])
    nested = Path(manifest["nested"])
    own_gate, other_gate = Path(manifest["own_gate"]), Path(manifest["other_gate"])
    results = {}
    subprocess.run(["/bin/sh", "-c", 'rm -rf "$1"/claude-501/base.*', "sh", str(pool)], capture_output=True)
    results["a"] = (pool / "claude-501/base.other/payload").exists()
    subprocess.run(["find", str(nested / "tmp"), "-type", "f", "-mtime", "+1", "-delete"], capture_output=True)
    results["b"] = (nested / "tmp/old").exists()
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
    with (state / "task.status").open("a") as stream:
        stream.write("working\n")
    results["e-append"] = (state / "task.status").read_text() == "working\n"
    for name in ("other.status", "task.other.status"):
        try:
            (state / name).write_text("replaced")
            results["e-" + name] = False
        except PermissionError:
            results["e-" + name] = (state / name).read_text() == "original"
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
    # One refused write per protected asset class, plus Main-owned records of
    # this task (its metadata, relaunch control and installed Git hooks).
    for name, path in manifest["protected"].items():
        results["refused-" + name] = refused(path)
    for name, path in manifest["writable"].items():
        results[name] = writable(path)
    if manifest.get("result"):
        Path(manifest["result"]).write_text(json.dumps(results, sort_keys=True))
    print(json.dumps(results, sort_keys=True))
    return results


def write(path, text="original"):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def scope_key(worktree):
    return subprocess.check_output(["bun", "-e", "console.log(Bun.hash.wyhash(require('path').resolve(process.argv[1])).toString(16).padStart(16,'0'))",
                                    str(worktree)], text=True).strip()


def fixture(repo, base, harness, user_home):
    """Lay out one fresh home, project, gates and foreign assets under base."""
    base.mkdir(parents=True)
    base = base.resolve()
    home, nm = base / "home", base / "nm"
    state, data = home / "state", home / "data"
    project = home / "projects/project"
    worktree, nested, pool = project / ".claude/worktrees/fm-task", project / ".claude/worktrees/fm-other", base / "pool/other"
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
    write(pool / "claude-501/base.other/payload")
    write(nested / "tmp/old")
    os.utime(nested / "tmp/old", (1, 1))
    write(data / "other/eval-target")
    write(data / "other/file")
    (data / "task").mkdir(parents=True)
    (worktree / "escape").symlink_to(data / "other", target_is_directory=True)
    for name in ("other.status", "task.other.status"):
        write(state / name)
    write(state / "other.jev-guard.jsonl", json.dumps({"at": 2, "task": "other", "decision": "clear"}) + "\n")
    write(state / "jev-guard.jsonl", json.dumps({"at": 1, "task": "legacy", "decision": "clear"}) + "\n")
    write(state / "task.status", "")
    write(state / "task.meta", "spawn_gen=proof-probe\n")
    write(state / "task.inbox/001.msg", "message")
    (state / "task.inbox/handled").mkdir()
    (state / "task.git-hooks").mkdir()
    subprocess.run(["bash", str(repo / "bin/fm-busy-event.sh"), "arm", str(state), "task"], check=True, capture_output=True)
    write(home / "README")
    write(home / "config/crew-harness")
    write(home / ".env")
    write(base / "other-home/state/x.status")
    protected = {
        "project-primary": project / "README", "primary-index": project / ".git/index", "home-primary": home / "README",
        "config": home / "config/crew-harness", "env": home / ".env",
        "other-worktree-nested": nested / "README", "other-worktree-pool": pool / "README",
        "other-data": data / "other/file", "other-home": base / "other-home/state/x.status", "other-gate": other_gate / "config",
        "main-meta": state / "task.meta", "main-control-relaunch": state / "task.control-relaunch",
        "main-git-hooks": state / "task.git-hooks/pre-commit",
    }
    writable_paths = {}
    if user_home:
        write(user_home / ".claude/settings.json")
        write(user_home / ".claude/.credentials.json")
        write(user_home / ".claude/projects/p/memory/MEMORY.md")
        write(user_home / ".omp/agent/config.yml")
        write(user_home / ".omp/plugins/plugin.ts")
        write(user_home / ".omp/run/daemons/0000000000000000/broker.pid")
        write(user_home / ".codex/config.toml")
        write(user_home / ".dsh/config")
        protected.update({"codex-home": user_home / ".codex/config.toml", "dsh-home": user_home / ".dsh/config",
                          "claude-settings": user_home / ".claude/settings.json", "omp-config": user_home / ".omp/agent/config.yml"})
        writable_paths["tool-cache"] = user_home / ".cache/fm-test-slots/probe"
        if harness == "claude":
            protected.update({"claude-credentials": user_home / ".claude/.credentials.json",
                              "claude-memory": user_home / ".claude/projects/p/memory/MEMORY.md"})
            writable_paths.update({"claude-transcript": user_home / ".claude/projects/p/session.jsonl",
                                   "claude-json": user_home / ".claude.json"})
        else:
            protected.update({"omp-plugins": user_home / ".omp/plugins/plugin.ts",
                              "omp-foreign-daemon": user_home / ".omp/run/daemons/0000000000000000/broker.pid"})
            writable_paths.update({"omp-agent-db": user_home / ".omp/agent/agent.db",
                                   "omp-daemon-scope": user_home / ".omp/run/daemons" / scope_key(worktree) / "broker.pid"})
    return {"repo": str(repo), "home": str(home), "nm": str(nm), "worktree": str(worktree), "nested": str(nested), "pool": str(pool),
            "own_gate": str(own_gate), "other_gate": str(other_gate), "other_home": str(base / "other-home"),
            "protected": {name: str(path) for name, path in protected.items()},
            "writable": {name: str(path) for name, path in writable_paths.items()}}


def build_profile(repo, manifest, harness, profile, env, agent=None):
    home = Path(manifest["home"])
    command = [sys.executable, str(repo / "bin/fm-write-confinement.py"), "--worktree", manifest["worktree"],
               "--home", str(home), "--config", str(home / "config"), "--projects", str(home / "projects"),
               "--data", str(home / "data/task"), "--state", str(home / "state"), "--task", "task", "--branch", "fm/task",
               "--harness", harness, "--protect", manifest["other_home"], "--profile", str(profile)]
    if agent:
        command += ["--agent-dir", str(agent)]
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
        manifest = fixture(repo, base / "fixture", harness, user_home.resolve())
        env = {name: value for name, value in os.environ.items() if name not in ("CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR")}
        env.update(HOME=str(user_home.resolve()), TMPDIR=str(base / "temp"), TMP=str(base / "temp"), TEMP=str(base / "temp"))
        (base / "temp").mkdir()
        profile = base / "profile.sb"
        build_profile(repo, manifest, harness, profile, env)
        command = [sys.executable, __file__, "--child", json.dumps(manifest)]
        invocation = command if mode == "baseline" else ["/usr/bin/sandbox-exec", "-f", str(profile)] + command
        result = subprocess.run(invocation, capture_output=True, text=True, env=env)
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
        home = Path.home()
        # Keep the installed runtime's HOME, as production does. Authentication
        # is neither copied nor used: EOF submits no prompt and the agent store
        # is synthetic. The daemon scope is unique to this fixture project.
        # Real harness homes are never written: their refusals run only against
        # the synthetic home above.
        manifest = fixture(repo, root / f"live-{harness}", harness, None)
        worktree = Path(manifest["worktree"])
        daemon_dir = home / ".omp/run/daemons" / scope_key(worktree)
        agent = root / f"live-{harness}/agent"
        agent.mkdir()
        data = Path(manifest["home"]) / "data/task"
        output = data / (harness + "-result.json")
        live_manifest = dict(manifest, result=str(output))
        env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(root / f"live-{harness}"),
               "OMP_SKIP_SETUP": "1", "DISABLE_AUTOUPDATER": "1", "PI_CODING_AGENT_DIR": str(agent),
               "CLAUDE_CONFIG_DIR": str(agent), "PI_CONFIG_DIR": ".omp"}
        profile = data / (harness + ".sb")
        build_profile(repo, manifest, harness, profile, env, agent)
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
            stdout, stderr = process.communicate("", timeout=60)
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
