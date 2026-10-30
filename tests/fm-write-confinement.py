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
PACKED_HEADER = "# pack-refs with: peeled fully-peeled sorted \n"
# This task's own archive branch, packed as Main's gc leaves it.
OWN_PACKED_ARCHIVE = "archive/task-submitted-fedcba98"
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
    # The gate deleted fm/gone, whose remote-tracking ref is packed, and the
    # repository asks fetch to prune. Pruning it needs a packed-refs rewrite.
    packed_refs = Path(manifest["packed_refs"])
    packed_before = packed_refs.read_bytes()
    refusal = f"unable to create file {packed_refs}.new: Operation not permitted"
    gone = "refs/remotes/no-mistakes/fm/gone"

    def resolves(ref, sha):
        return git("-C", str(worktree), "rev-parse", "--verify", "-q", ref).stdout.strip() == sha

    fetch = git("-C", str(worktree), "fetch", "no-mistakes")
    results["fetch"] = (fetch.returncode == 0 and git("-C", str(worktree), "rev-parse", "refs/remotes/no-mistakes/fm/task").returncode == 0
                        and resolves(gone, manifest["forged_sha"]))
    pruned = git("-C", str(worktree), "fetch", "--prune", "no-mistakes")
    results["refused-fetch-prune-packed"] = (pruned.returncode == 1 and f"could not delete reference {gone}: {refusal}" in pruned.stderr
                                             and resolves(gone, manifest["forged_sha"]) and packed_refs.read_bytes() == packed_before)
    # The shared stash holds one packed entry. Popping that last entry applies
    # it and exits 0 with the stash list empty, but Git is refused the
    # packed-refs rewrite, so refs/stash still resolves to the popped commit.
    (worktree / "new-file").write_text("stashed change")
    stash = git("-C", str(worktree), "stash", "push", "-m", "probe")
    dropped = git("-C", str(worktree), "stash", "drop")
    popped = git("-C", str(worktree), "stash", "pop")
    results["stash"] = (stash.returncode == 0 and dropped.returncode == 0 and popped.returncode == 0
                        and (worktree / "README").read_text() == "stashed in fixture"
                        and git("-C", str(worktree), "stash", "list").stdout == "")
    results["refused-packed-stash-removal-ref-kept"] = (f"error: {refusal}" in popped.stderr and resolves("refs/stash", manifest["stash_sha"])
                                                        and packed_refs.read_bytes() == packed_before)
    git("-C", str(worktree), "checkout", "--", "README")
    foreign_push = git("-C", str(worktree), "push", str(other_gate), "fm/task")
    results["refused-other-gate-push"] = (foreign_push.returncode != 0
                                          and git("--git-dir", str(other_gate), "rev-parse", "--verify", "-q", "refs/heads/fm/task").returncode != 0)
    other_branch = git("-C", str(worktree), "rev-parse", "fm/other").stdout
    git("-C", str(worktree), "update-ref", "refs/heads/fm/other", "HEAD")
    results["refused-other-branch"] = git("-C", str(worktree), "rev-parse", "fm/other").stdout == other_branch
    # The custody-return route creates this task's own archive branches. They
    # must work with the route's own git commands, while no other ref name
    # does: another task's archive, ids that contain or extend this task's id,
    # and names outside the two documented shapes. No case-only variant of an
    # own name is tried: the default macOS volume is case-insensitive, so that
    # path is the very same file and the kernel treats it as one.
    def ref_exists(name):
        return git("-C", str(worktree), "rev-parse", "--verify", "-q", "refs/heads/" + name).returncode == 0

    def ref_refused(name):
        failed = git("-C", str(worktree), "update-ref", "refs/heads/" + name, "HEAD").returncode != 0 and not ref_exists(name)
        git("-C", str(worktree), "update-ref", "-d", "refs/heads/" + name)  # leave the unconfined control clean
        return failed

    head, base = (git("-C", str(worktree), "rev-parse", ref).stdout.strip() for ref in ("HEAD", "HEAD~1"))
    for kind, hex8 in (("submitted", "0123abcd"), ("pipeline", "89abcdef")):
        name = f"archive/task-{kind}-{hex8}"
        created = git("-C", str(worktree), "branch", name, head)
        again = git("-C", str(worktree), "branch", name, head)
        moved = git("-C", str(worktree), "update-ref", "refs/heads/" + name, base, head)
        reflog = git("-C", str(worktree), "reflog", "show", "--format=%H", "refs/heads/" + name).stdout.split()
        results[f"archive-own-{kind}-create"] = (created.returncode == 0 and again.returncode != 0
                                                  and git("-C", str(worktree), "rev-parse", "refs/heads/" + name).stdout.strip() == base)
        results[f"archive-own-{kind}-update"] = moved.returncode == 0 and bool(reflog)
        deleted = git("-C", str(worktree), "branch", "-D", name)
        results[f"archive-own-{kind}-delete"] = deleted.returncode == 0 and not ref_exists(name)
    for label, name in (("other-task", "archive/other-submitted-0123abcd"),
                        ("extending-id", "archive/task-2-submitted-0123abcd"),
                        ("contained-id", "archive/tas-submitted-0123abcd"),
                        ("containing-id", "archive/xtask-submitted-0123abcd"),
                        ("own-id-other-shape", "archive/task-other-0123abcd"),
                        ("own-id-short-hex", "archive/task-submitted-0123abc"),
                        ("own-id-long-hex", "archive/task-submitted-0123abcde"),
                        ("own-id-non-hex", "archive/task-submitted-0123abcg"),
                        ("own-id-suffix", "archive/task-submitted-0123abcd-extra"),
                        ("outside-archive", "task-submitted-0123abcd")):
        results[f"refused-archive-{label}"] = ref_refused(name)
    deleted = git("-C", str(worktree), "branch", "-d", OWN_PACKED_ARCHIVE)
    results["refused-packed-own-archive-delete"] = (
        deleted.returncode == 1 and f"error: could not delete reference refs/heads/{OWN_PACKED_ARCHIVE}: {refusal}" in deleted.stderr
        and resolves("refs/heads/" + OWN_PACKED_ARCHIVE, manifest["forged_sha"]) and packed_refs.read_bytes() == packed_before)
    # The primary checkout's HEAD stays refused; a failed attempt changes nothing.
    primary = str(Path(manifest["home"]) / "projects/project")
    results.update(packed_refs_results(manifest, primary, worktree))
    before = git("-C", primary, "symbolic-ref", "HEAD").stdout.strip()
    git("-C", primary, "symbolic-ref", "HEAD", "refs/heads/fm/pool")
    after = git("-C", primary, "symbolic-ref", "HEAD").stdout.strip()
    git("-C", primary, "symbolic-ref", "HEAD", before)
    results["refused-primary-head"] = after == before
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
    results["identity"] = pid_identity(manifest["repo"], manifest["identity_pid"], Path(os.environ["TMPDIR"]) / "identity-state")
    print(json.dumps(results, sort_keys=True))
    return results


def packed_refs_results(manifest, primary, worktree):
    """Rewrite another task's packed branch every way a plain file write can."""
    packed = Path(manifest["packed_refs"])
    original = packed.read_text()
    forged = PACKED_HEADER + f"{manifest['forged_sha']} refs/heads/fm/packed\n"
    stray = [packed.with_name(name) for name in ("packed-refs.lock", "packed-refs.new")]

    def resolved():
        return git("-C", primary, "rev-parse", "fm/packed").stdout.strip()

    def unchanged(attempt, restore=True):
        # True only when the attempt was refused and the branch still resolves
        # to its real commit. The unconfined control leaves the file as found
        # (a pack that rewrote every other ref is the one thing not undone).
        try:
            attempt()
        except PermissionError:
            held = packed.read_text() == original and resolved() == manifest["packed_sha"]
        else:
            held = False
        for path in stray:
            path.unlink(missing_ok=True)
        if restore and packed.read_text() != original:
            packed.write_text(original)
        return held

    def in_place():
        with packed.open("w") as stream:
            stream.write(forged)

    def by_rename():
        stray[0].write_text(forged)
        os.replace(stray[0], packed)

    def by_new_file():
        stray[1].write_text(forged)

    def by_git(*args):
        def run():
            if git("-C", primary, *args).returncode:
                raise PermissionError
        return run

    results = {"packed-branch-resolves": resolved() == manifest["packed_sha"],
               "refused-packed-refs-write": unchanged(in_place),
               "refused-packed-refs-rename-over": unchanged(by_rename),
               "refused-packed-refs-new-file": unchanged(by_new_file),
               # Refused at the loose refs/heads lock before Git reaches packed-refs.
               "refused-packed-branch-delete": unchanged(by_git("update-ref", "-d", "refs/heads/fm/packed")),
               "refused-pack-refs": unchanged(by_git("pack-refs", "--all"), restore=False)}
    # A packed ref outside refs/heads has no loose lock deny, so deleting it
    # reaches the packed-refs rewrite itself.
    gone = "refs/remotes/no-mistakes/fm/gone"
    deleted = git("-C", str(worktree), "update-ref", "-d", gone)
    results["refused-packed-remote-ref-delete"] = (
        deleted.returncode != 0 and f"unable to create file {packed}.new: Operation not permitted" in deleted.stderr
        and packed.read_text() == original
        and git("-C", primary, "rev-parse", "--verify", "-q", gone).stdout.strip() == manifest["forged_sha"])
    # A commondir file in the shared Git directory makes the primary checkout
    # read its refs from the folder it names, here one with a forged branch.
    scratch = Path(os.environ["TMPDIR"])
    forged_common = scratch / "forged-common"
    (forged_common / "refs/heads/fm").mkdir(parents=True)
    (forged_common / "objects").symlink_to(Path(primary) / ".git/objects")
    (forged_common / "HEAD").write_text("ref: refs/heads/main\n")
    (forged_common / "refs/heads/fm/packed").write_text(manifest["forged_sha"] + "\n")
    commondir = packed.with_name("commondir")
    results["refused-commondir"] = unchanged(lambda: commondir.write_text(str(forged_common) + "\n"), restore=False)
    commondir.unlink(missing_ok=True)
    # The shared config is writable, so it can select reftable storage; a
    # reftable folder built elsewhere would then hold every ref Git reads.
    # This covers only the payload-less value; a reftable:///<path> or
    # files://<path> value is not refused.
    forged_reftable = scratch / "forged-reftable.git"
    assert git("init", "-q", "--bare", "--ref-format=reftable", str(forged_reftable)).returncode == 0
    (forged_reftable / "objects/info/alternates").write_text(str(Path(primary) / ".git/objects") + "\n")
    assert git("--git-dir", str(forged_reftable), "update-ref", "refs/heads/fm/packed", manifest["forged_sha"]).returncode == 0
    config, reftable = packed.with_name("config"), packed.with_name("reftable")
    saved = config.read_bytes()
    switched = all(git("-C", primary, "config", key, value).returncode == 0
                   for key, value in (("core.repositoryformatversion", "1"), ("extensions.refStorage", "reftable")))
    try:
        shutil.copytree(forged_reftable / "reftable", reftable)
        planted = True
    except PermissionError:
        planted = False
    switched_sha = resolved()
    config.write_bytes(saved)
    shutil.rmtree(reftable, ignore_errors=True)
    results["refused-reftable-switch"] = (switched and not planted and switched_sha != manifest["forged_sha"]
                                          and resolved() == manifest["packed_sha"])
    # A new hard link to packed-refs would be a second name for the file. The
    # worktree and a task-owned ~/tmp entry are both places the worker writes.
    for key, link in (("refused-packed-refs-link-create", Path(manifest["worktree"]) / "packed-refs-alias"),
                      ("refused-packed-refs-link-create-outside", Path(manifest["user_tmp"]) / "fm-task-packed-refs-alias")):
        try:
            os.link(packed, link)
            results[key] = False
        except PermissionError:
            results[key] = not link.exists()
        link.unlink(missing_ok=True)  # leave the unconfined control without an alias
    # A replace ref makes every Git command in the primary checkout show other
    # objects for a commit, so it changes what a branch holds.
    head = git("-C", str(worktree), "rev-parse", "HEAD").stdout.strip()
    replaced = git("-C", str(worktree), "replace", "-f", head, manifest["forged_sha"])
    results["refused-replace-ref"] = (replaced.returncode != 0
                                      and git("-C", primary, "rev-parse", "--verify", "-q", "refs/replace/" + head).returncode != 0)
    git("-C", str(worktree), "replace", "-d", head)  # leave the unconfined control clean
    return results


def pid_identity(repo, pid, state):
    """The shared process identity, read through bin/fm-wake-lib.sh."""
    return subprocess.run(["bash", "-c", '. "$0/bin/fm-wake-lib.sh"; fm_pid_identity "$1"', repo, str(pid)],
                          env=dict(os.environ, FM_STATE_OVERRIDE=str(state)), capture_output=True, text=True).stdout


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
    # Refs as Git leaves them once packed: no loose file, one line in
    # packed-refs. Another task's branch sits on a commit that differs from the
    # one a forged line would name; this task's own archive, a remote-tracking
    # ref of a branch the gate no longer has and the shared stash's one entry
    # are packed beside it.
    init_sha = git("-C", str(project), "rev-parse", "HEAD").stdout.strip()
    packed = git("-C", str(project), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                 "commit-tree", init_sha + "^{tree}", "-p", init_sha, "-m", "packed").stdout.strip()
    assert git("-C", str(project), "update-ref", "refs/heads/fm/packed", packed).returncode == 0
    (project / ".git/refs/heads/fm/packed").unlink()
    write(worktree / "README", "stashed in fixture")
    assert git("-C", str(worktree), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
               "stash", "push", "-q", "-m", "fixture").returncode == 0
    stash_sha = git("-C", str(project), "rev-parse", "refs/stash").stdout.strip()
    (project / ".git/refs/stash").unlink()
    lines = {"refs/heads/fm/packed": packed, "refs/heads/" + OWN_PACKED_ARCHIVE: init_sha,
             "refs/remotes/no-mistakes/fm/gone": init_sha, "refs/stash": stash_sha}
    write(project / ".git/packed-refs", PACKED_HEADER + "".join(f"{sha} {name}\n" for name, sha in sorted(lines.items())))
    for name, sha in lines.items():
        assert git("-C", str(project), "rev-parse", name).stdout.strip() == sha
    # Stands in for a host's global fetch.prune=true, which GIT_CONFIG_GLOBAL
    # hides here; the launch's own GIT_CONFIG entry outranks both.
    assert git("-C", str(project), "config", "fetch.prune", "true").returncode == 0
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
               "git-refs": project / ".git/refs", "git-worktrees": project / ".git/worktrees",
               "git-packed-refs": project / ".git/packed-refs"}
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
            "packed_refs": str(project / ".git/packed-refs"), "packed_sha": packed, "forged_sha": init_sha, "stash_sha": stash_sha,
            "own_gate": str(own_gate), "other_gate": str(other_gate), "other_home": str(base / "other-home"), "other": other,
            "claude_tmp": str(claude_tmp), "user_tmp": str(user_tmp), "late": [str(path) for path in late.values()],
            "transcript_container": str(user_home / f".claude/projects/{slug}") if harness == "claude" else "",
            "protected": {name: str(path) for name, path in protected.items()},
            "writable": {name: str(path) for name, path in writable_paths.items()},
            "renamed": {name: str(path) for name, path in renamed.items()}}


def launch_git_env(env):
    """The child's environment with the GIT_CONFIG entry fm-spawn.sh appends to a confined launch."""
    count = int(env.get("GIT_CONFIG_COUNT") or 0)
    return dict(env, GIT_CONFIG_COUNT=str(count + 1), **{f"GIT_CONFIG_KEY_{count}": "fetch.prune", f"GIT_CONFIG_VALUE_{count}": "false"})


def build_profile(repo, manifest, harness, profile, env, agent_dir=None, worktree=None):
    home = Path(manifest["home"])
    command = [sys.executable, str(repo / "bin/fm-write-confinement.py"), "--worktree", worktree or manifest["worktree"],
               "--home", str(home), "--config", str(home / "config"), "--projects", str(home / "projects"),
               "--data", str(home / "data/task"), "--state", str(home / "state"), "--task", "task", "--branch", "fm/task",
               "--harness", harness, "--protect", manifest["other_home"], "--profile", str(profile)]
    if harness == "claude":
        command += ["--claude-session", OWN_SESSION]
    if agent_dir:
        command += ["--agent-dir", str(agent_dir)]
    subprocess.run(command, env=dict(env, NM_HOME=manifest["nm"]), check=True, capture_output=True, text=True)


def invalid_project_source(repo, manifest, base, env):
    project = Path(manifest["home"]) / "projects/invalid-source"
    assert git("init", "-q", str(project)).returncode == 0
    (project / ".git/config").write_text("[invalid configuration\n")
    profile = base / "invalid-source.sb"
    try:
        build_profile(repo, manifest, "claude", profile, env)
    except subprocess.CalledProcessError as error:
        assert str(project) in error.stderr and "git rev-parse --git-dir failed" in error.stderr, error.stderr
        assert not profile.exists(), "invalid source published a partial confinement profile"
    else:
        raise AssertionError("invalid project Git configuration was treated as repository absence")
    finally:
        shutil.rmtree(project)
    print("invalid project source: refused with project and failed command; no profile published")


def hardlink_alias(repo, manifest, base, harness, env):
    # The lane review's E4: an alias to a protected shared ref file made before
    # the profile is built lets a confined write through the alias bypass the
    # path rules. The build must refuse, say which file and how many links,
    # and publish no profile, whatever path the alias sits at.
    common = Path(manifest["home"]) / "projects/project/.git"
    aliases = {"worktree": (common / "packed-refs", Path(manifest["worktree"]) / "packed-refs-alias"),
               "outside-worktree": (common / "packed-refs", Path(manifest["user_tmp"]) / "fm-task-packed-refs-alias"),
               "task-data": (common / "packed-refs", Path(manifest["home"]) / "data/task/packed-refs-alias"),
               "loose-ref": (common / "refs/heads/fm/other", Path(manifest["worktree"]) / "loose-ref-alias"),
               "head": (common / "HEAD", Path(manifest["user_tmp"]) / "fm-task-head-alias")}
    aliases.update({f"other-worktree-{name}": (common / "worktrees/fm-other" / name, Path(manifest["worktree"]) / f"other-worktree-{name}-alias")
                    for name in ("HEAD", "index", "commondir")})
    for name, (target, alias) in aliases.items():
        profile = base / f"alias-{name}-{harness}.sb"
        alias.parent.mkdir(parents=True, exist_ok=True)
        os.link(target, alias)
        try:
            build_profile(repo, manifest, harness, profile, env)
        except subprocess.CalledProcessError as error:
            assert error.returncode == 1 and "another hard link" in error.stderr, (name, error.stderr)
            assert str(target) in error.stderr and "(2 links)" in error.stderr, (name, error.stderr)
            assert not profile.exists(), f"{name}: a refused build published a profile"
        else:
            raise AssertionError(f"{harness}: a profile was built while {target} had a second link at {alias}")
        finally:
            alias.unlink()
    # A symbolic link at a protected path, or at a folder above one, sends a
    # confined write and Git's read of the ref to wherever it points.
    ref, forged_ref = common / "refs/heads/fm/other", Path(manifest["worktree"]) / "forged-ref"
    folder, forged_folder = common / "refs/heads/aliased", Path(manifest["user_tmp"]) / "fm-task-ref-folder"
    real_ref = ref.read_bytes()
    forged_ref.write_text(manifest["forged_sha"] + "\n")
    forged_folder.mkdir(parents=True)
    (forged_folder / "other").write_text(manifest["forged_sha"] + "\n")
    symlinks = {"symlinked-ref": (ref, forged_ref), "symlinked-folder": (folder, forged_folder)}
    for name, (path, target) in symlinks.items():
        profile = base / f"alias-{name}-{harness}.sb"
        path.unlink(missing_ok=True)
        path.symlink_to(target)
        try:
            build_profile(repo, manifest, harness, profile, env)
        except subprocess.CalledProcessError as error:
            assert error.returncode == 1 and f"{path} (symbolic link to {target})" in error.stderr, (name, error.stderr)
            assert not profile.exists(), f"{name}: a refused build published a profile"
        else:
            raise AssertionError(f"{harness}: a profile was built while {path} was a symbolic link to {target}")
        finally:
            path.unlink()
    ref.write_bytes(real_ref)
    forged_ref.unlink()
    shutil.rmtree(forged_folder)
    # Git's core.preferSymlinkRefs HEAD names a branch and is never followed.
    real_head = (common / "HEAD").read_bytes()
    (common / "HEAD").unlink()
    (common / "HEAD").symlink_to("refs/heads/main")
    try:
        build_profile(repo, manifest, harness, base / f"alias-symlink-head-{harness}.sb", env)
    finally:
        (common / "HEAD").unlink()
        (common / "HEAD").write_bytes(real_head)
    clean = base / f"alias-clean-{harness}.sb"
    build_profile(repo, manifest, harness, clean, env)
    assert clean.exists(), "the build still refuses after every alias was removed"
    print(f"{harness} aliases: " + ", ".join([*aliases, *symlinks]) + " refused naming path and link count or target;"
          " symbolic-link HEAD and clean builds still work")


def reftable_source(repo, manifest, base, env):
    # Reftable keeps every ref, the task's own and every other task's, in files
    # no packed-refs or refs/heads rule names, so the builder must refuse it.
    source, linked = base / "rs", base / "rw"
    for args in (["init", "-q", "--ref-format=reftable", "-b", "main", str(source)],
                 ["-C", str(source), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-q", "--allow-empty", "-m", "init"],
                 ["-C", str(source), "worktree", "add", "-q", "-b", "fm/task", str(linked)]):
        result = git(*args)
        assert result.returncode == 0, (args, result.stderr)
    profile = base / "rs.sb"
    try:
        build_profile(repo, manifest, "claude", profile, env, worktree=str(linked))
    except subprocess.CalledProcessError as error:
        assert error.returncode == 1 and "reftable ref storage cannot be confined" in error.stderr, error.stderr
        assert not profile.exists(), "reftable repository published a confinement profile"
    else:
        raise AssertionError("a reftable repository was confined as if its refs were files")
    print("reftable source: refused; no profile published")


# A new config root holds none of Claude's session folders; fm-spawn.sh creates
# them outside the profile, which grants none of them.
FOLDERS_PROBE = r'''
import json, os, sys
root = sys.argv[1]
made = []
for name in ("projects", "session-env", "file-history", "tasks"):
    try:
        os.mkdir(os.path.join(root, name))
        made.append(name)
    except OSError:
        pass
print(json.dumps(made))
'''

# A new task's worktree has a new slug, so its first Claude launch may create
# the transcript container. Run under a profile for a fresh config root that
# holds no container yet: try to plant it as a symlink to a writable place and
# as a plain file, create it as a folder, append this session's transcript,
# then try to move it to a writable place and to delete it.
CONTAINER_PROBE = r'''
import json, os, shutil, sys
container, own, moved, target = sys.argv[1:5]
result = {}
for key, plant in (("symlink", lambda: os.symlink(target, container)), ("file", lambda: open(container, "x").close())):
    try:
        plant()
    except OSError:
        result[key] = False
        continue
    result[key] = True
    try:
        os.unlink(container)
    except OSError:
        pass
try:
    os.mkdir(container)
    with open(own, "a") as stream:
        stream.write("transcript\n")
    result["create-and-append"] = True
except OSError:
    result["create-and-append"] = False
try:
    os.rename(container, moved)
    os.rename(moved, container)
    result["renamed"] = True
except OSError:
    result["renamed"] = False
try:
    shutil.rmtree(container)
except OSError:
    pass
result["deleted"] = not os.path.isdir(container)
print(json.dumps(result))
'''


def fresh_container(repo, manifest, base, mode, env):
    root = base / "fresh-claude"
    root.mkdir()
    profile = base / "fresh-profile.sb"
    build_profile(repo, manifest, "claude", profile, env, agent_dir=root)
    sandbox = [] if mode == "baseline" else ["/usr/bin/sandbox-exec", "-f", str(profile)]
    folders = subprocess.run(sandbox + [sys.executable, "-c", FOLDERS_PROBE, str(root)], capture_output=True, text=True, env=env)
    (root / "projects").mkdir(exist_ok=True)
    container = root / "projects" / re.sub(r"[^A-Za-z0-9]", "-", manifest["worktree"])
    command = [sys.executable, "-c", CONTAINER_PROBE, str(container), str(container / f"{OWN_SESSION}.jsonl"),
               str(base / "temp/moved"), str(base / "temp")]
    result = subprocess.run(sandbox + command, capture_output=True, text=True, env=env)
    return {"session-folders-created": json.loads(folders.stdout), **json.loads(result.stdout)}


def remove_archive_folders(manifest):
    git_dir = Path(manifest["home"]) / "projects/project/.git"
    for folder in (git_dir / "refs/heads/archive", git_dir / "logs/refs/heads/archive"):
        if folder.is_dir():
            folder.rmdir()


# A project branch named archive fills the archive parent names with files.
# The builder must still succeed and grant no archive name: once that branch
# is gone, the confined create of this task's own archive stays refused.
def archive_branch_file(repo, manifest, base, harness, mode, env):
    worktree = manifest["worktree"]
    remove_archive_folders(manifest)
    assert git("-C", worktree, "branch", "archive").returncode == 0
    profile = base / "archive-file-profile.sb"
    build_profile(repo, manifest, harness, profile, env)
    kept = git("-C", worktree, "rev-parse", "--verify", "-q", "refs/heads/archive").returncode == 0
    assert git("-C", worktree, "branch", "-D", "archive").returncode == 0
    sandbox = [] if mode == "baseline" else ["/usr/bin/sandbox-exec", "-f", str(profile)]
    name = "archive/task-submitted-0123abcd"
    created = subprocess.run(sandbox + ["git", "-C", worktree, "branch", name], capture_output=True, text=True, env=dict(env, **GIT_ENV))
    exists = git("-C", worktree, "rev-parse", "--verify", "-q", "refs/heads/" + name).returncode == 0
    git("-C", worktree, "update-ref", "-d", "refs/heads/" + name)
    return {"archive-branch-kept": kept, "own-archive-created": created.returncode == 0 and exists}


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
            if harness == "claude" and mode == "baseline":
                invalid_project_source(repo, manifest, base, env)
            # A process of this user whose arguments ps must escape: non-ASCII
            # bytes, a newline, a tab and an empty word.
            unusual = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)", "jos\u00e9", "a\nb", "t\tb", ""])
            manifest["identity_pid"] = unusual.pid
            for path in manifest["late"]:
                write(path, "window=fmtest:fm-late\nkind=ship\n")
            # Git removes an empty archive folder with its last ref while the
            # worker runs; the child must still create its own archives.
            remove_archive_folders(manifest)
            command = [sys.executable, __file__, "--child", json.dumps(manifest)]
            invocation = command if mode == "baseline" else ["/usr/bin/sandbox-exec", "-f", str(profile)] + command
            result = subprocess.run(invocation, capture_output=True, text=True, env=launch_git_env(env))
            git("-C", manifest["worktree"], "update-ref", "-d", "refs/heads/" + OWN_PACKED_ARCHIVE)
            expected_identity = pid_identity(str(repo), unusual.pid, base / "identity-state")
            unusual.kill()
            unusual.wait()
        finally:
            for path in shared:
                shutil.rmtree(path, ignore_errors=True)
        if not result.stdout.strip():
            raise AssertionError(f"{harness} {mode}: exit={result.returncode} stderr={result.stderr}")
        actual = json.loads(result.stdout)
        print(f"{harness} {mode}: " + json.dumps(actual, sort_keys=True))
        assert expected_identity and actual.pop("identity") == expected_identity, (harness, mode, expected_identity)
        if harness == "claude":
            fresh = fresh_container(repo, manifest, base, mode, env)
            print(f"{harness} {mode} fresh container: " + json.dumps(fresh, sort_keys=True))
            confined = mode == "confined"
            assert fresh == {"session-folders-created": [] if confined else ["projects", "session-env", "file-history", "tasks"],
                             "symlink": not confined, "file": not confined, "create-and-append": True,
                             "renamed": not confined, "deleted": not confined}, (harness, mode, fresh)
        archive_file = archive_branch_file(repo, manifest, base, harness, mode, env)
        print(f"{harness} {mode} archive branch file: " + json.dumps(archive_file, sort_keys=True))
        assert archive_file == {"archive-branch-kept": True, "own-archive-created": mode == "baseline"}, (harness, mode, archive_file)
        if mode == "baseline":
            for name in actual:
                if name in CONTROL_KEYS or name.startswith("refused-"):
                    assert actual[name] is False, (harness, mode, name, actual)
        else:
            assert result.returncode == 0 and all(actual.values()), (harness, mode, result.stderr, actual)
            hardlink_alias(repo, manifest, base, harness, env)
            if harness == "claude":
                reftable_source(repo, manifest, base, env)
