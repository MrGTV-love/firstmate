#!/usr/bin/env python3
"""Private dsh-tui launch preparation and durable activity reader.

`resume` rewrites the bound launch patch with the newest session id in the
row config's sessionId field: the launch overlay replaces the stock profile
patch field that reads DSH_TUI_RESUME_SESSION, so the env alone cannot resume.
A resumed session appends to its own log. The durable fold follows the newest
depth-zero log.

prepare STATE ID GENERATION SOURCE_HOME MODEL EFFORT CWD stages a per-launch
HOME and DSH_HOME at STATE/ID.dsh/GENERATION, then atomically publishes
STATE/ID.dsh-session and retires the generation that binding replaced.
Installed packages are read-only links; configuration, credentials,
preferences, and session logs belong exclusively to this launch.
resume STATE ID MODEL EFFORT CWD rewrites the bound launch patch to resume the
newest depth-zero session, or prints nothing when the binding changed.
session-file STATE ID prints the live depth-zero session log.
position STATE ID prints the live session log and its last durable seq as JSON,
or nothing before the launch has a log.
state STATE ID [--since POSITION] folds only the newest depth-zero session in
that launch's plain JSONL store, from its newest turn/start (or the last MiB,
whichever reaches further back), however large that turn is. Missing, corrupt,
or unsupported data is unknown. With --since, anything recorded at or before
POSITION is history: a turn must have started beyond it, or the state is
unknown.
route MODEL [PROVIDER] prints the default model-family adapter.
check HARNESS MODEL [PROVIDER] refuses a dsh launch unless the model is a
concrete DeepSeek id: the optional deepseek/ prefix, then a non-empty id with no
slash or whitespace, which is exactly what prepare accepts. An explicit non-dsh
harness may name a DeepSeek stand-in, because DeepSeek work routes to dsh only
by default.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys

CHUNK = 1024 * 1024


def route(model, provider=""):
    if provider == "deepseek" or model.startswith("deepseek/"):
        return "dsh"
    if model.startswith("claude"):
        return "claude"
    return "omp"


def check(harness, model, provider=""):
    if harness != "dsh":
        return
    bare = model.removeprefix("deepseek/")
    if not bare:
        raise ValueError("dsh requires an explicit DeepSeek model id")
    if route(model, provider) != "dsh":
        raise ValueError(f"dsh runs only DeepSeek models, not '{model}'")
    if "/" in bare or any(c.isspace() for c in bare):
        raise ValueError("dsh requires a concrete DeepSeek model id")


def normalize(value):
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        value = {key: normalize(item) for key, item in value.items()}
        model, provider = value.get("model", ""), value.get("provider", "")
        if "harness" in value and isinstance(model, str) and isinstance(provider, str):
            check(value["harness"], model, provider)
            if provider == "deepseek" and model and not model.startswith("deepseek/"):
                value["model"] = "deepseek/" + model
        return value
    return value


def atomic_json(path, value):
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            json.dump(value, stream)
            stream.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def launch_patch(model, effort, cwd, dsh, session_id):
    # JSON is valid YAML. A complete row config is required: overlays replace
    # config, not individual fields, and they also replace the profile patch
    # fields this row carries (preset, workspace, sessionId, backend). The
    # selected model is advertised exactly, and sessionId is what the launcher's
    # --resume env cannot supply once this row replaces the stock patch.
    return [
        {"id": "dsh-tui", "config": {"provider": "deepseek-official", "model": model,
            "cwd": str(Path(cwd).resolve()), "fullscreen": False, "launchpad": False,
            **({"effort": effort} if effort not in ("", "default") else {}),
            **({"sessionId": session_id} if session_id else {})}},
        {"id": "llm-deepseek", "config": {"apiKeyEnv": "DEEPSEEK_API_KEY", "models": [{"id": model}]}},
        {"id": "session-persistence-jsonl", "config": {"root": str(dsh / "sessions"), "compression": "none"}},
    ]


def resume_target(path):
    header = json.loads(path.open().readline())
    session = header["id"]
    import uuid
    if str(uuid.UUID(session)) != session:
        raise ValueError("invalid dsh session id")
    return session


def prepare(args):
    state, task, generation, source_home, model, effort, cwd = args
    check("dsh", model)
    model = model.removeprefix("deepseek/")
    if effort in ("", "default"):
        effort = ""
    elif effort not in ("low", "medium", "high", "xhigh", "max"):
        raise ValueError(f"unsupported dsh effort: {effort}")
    source = Path(source_home)
    original = source / "profiles" / "dsh-tui"
    package = original / "node_modules" / "@deepseek-harness-tui" / "dsh-tui" / "package.json"
    version = json.loads(package.read_text())["version"]
    if version != "0.16.1":
        raise ValueError(f"dsh-tui profile {version} is not live-verified; expected 0.16.1")
    root = Path(state).resolve() / f"{task}.dsh" / generation
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    home = root / "home"
    dsh = root / "dsh"
    prefs = home / ".dsh-tui"
    prefs.mkdir(parents=True, mode=0o700)
    profile = dsh / "profiles" / "dsh-tui"
    profile.mkdir(parents=True, mode=0o700)
    # Do not link the profile itself: DSH rewrites cordis.yml at boot.
    # No plugin installation or owner's settings/profile mutation is permitted.
    shutil.copyfile(original / "package.json", profile / "package.json")
    (profile / "cordis.yml").write_text("[]\n")
    (profile / "cordis.patch.yml").write_text("[]\n")
    # Node resolves realpaths before DSH's profile interception. Linking this
    # directory escapes the isolated profile and selects incompatible runtime
    # packages; retain the installed package tree inside the launch root.
    try:
        shutil.copytree(original / "node_modules", profile / "node_modules", symlinks=True, copy_function=os.link)
    except OSError:
        shutil.rmtree(profile / "node_modules", ignore_errors=True)
        shutil.copytree(original / "node_modules", profile / "node_modules", symlinks=True)
    credentials = source / ".credentials.yaml"
    if credentials.is_file():
        shutil.copyfile(credentials, dsh / ".credentials.yaml")
        (dsh / ".credentials.yaml").chmod(0o600)
    atomic_json(prefs / "model.json", {"provider": "deepseek-official", "model": model})
    if effort not in ("", "default"):
        atomic_json(prefs / "effort.json", {"effort": effort})
    atomic_json(root / "launch.yml", launch_patch(model, effort, cwd, dsh, ""))
    binding = Path(state) / f"{task}.dsh-session"
    try:
        previous = Path(json.loads(binding.read_text())["root"])
    except (OSError, ValueError, KeyError, TypeError):
        previous = None
    atomic_json(binding, {"root": str(root), "cwd": str(Path(cwd).resolve()), "generation": generation, "model": model, "effort": effort})
    if previous is not None and previous != root and previous.parent == root.parent:
        shutil.rmtree(previous, ignore_errors=True)
    print(root)


def session_path(binding):
    root = Path(binding["root"])
    candidates = []
    for directory in (root / "dsh" / "sessions").glob("*/*"):
        logs = []
        for path in directory.glob("session.v*.jsonl"):
            version = path.name.removeprefix("session.v").removesuffix(".jsonl")
            if version.isdecimal():
                logs.append((int(version), path))
        if not logs:
            continue
        version, path = max(logs)
        with path.open("rb") as stream:
            header = json.loads(stream.readline(65536))
        if header.get("delegationDepth") != 0 or header.get("cwd") != binding["cwd"]:
            continue
        if version != 4 or header.get("version") != 4 or header.get("type") != "session":
            return "unknown"
        candidates.append(path)
    if not candidates:
        return None
    # A launch store can hold more than one depth-zero log. The newest is the
    # live one; older logs are history.
    candidates.sort(key=lambda path: (path.stat().st_mtime_ns, path.parent.name))
    return candidates[-1]


def live_log(state, task):
    return session_path(json.loads((Path(state) / f"{task}.dsh-session").read_text()))


def committed_size(stream, size):
    end = size
    while end > 0:
        begin = max(0, end - CHUNK)
        stream.seek(begin)
        found = stream.read(end - begin).rfind(b"\n")
        if found >= 0:
            return begin + found + 1
        end = begin
    return 0


def last_turn_start(stream, committed):
    # Scan committed lines newest first in bounded chunks, so a turn larger than
    # one chunk still reaches its opening turn/start. 0 when the log has none.
    end = committed
    carry = b""
    while end > 0:
        begin = max(0, end - CHUNK)
        stream.seek(begin)
        lines = []
        offset = begin
        for line in (stream.read(end - begin) + carry).split(b"\n")[:-1]:
            lines.append((offset, line))
            offset += len(line) + 1
        carry = b""
        if begin:
            carry = lines.pop(0)[1] + b"\n"
        for offset, line in reversed(lines):
            if b"turn/start" in line and json.loads(line).get("type") == "turn/start":
                return offset
        end = begin
    return 0


def fold(path):
    with path.open("rb") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        turn = last_turn_start(stream, committed_size(stream, size))
        start = min(turn, max(0, size - CHUNK))
        stream.seek(start)
        if start and start != turn:
            stream.readline()
        result = "unknown"
        last_seq = started = -1
        for line in stream:
            if not line.endswith(b"\n"):
                break  # An incomplete append is not a committed event.
            event = json.loads(line)
            if event.get("type") == "session":
                continue
            seq = event.get("seq")
            if not isinstance(seq, int) or seq <= last_seq:
                raise ValueError("dsh session log has a non-monotonic sequence")
            last_seq = seq
            if event.get("type") == "turn/start":
                result = "busy"
                started = seq
            elif event.get("type") == "turn/end":
                result = "idle"
        return result, last_seq, started


def turn_state(state, task, since=None):
    path = live_log(state, task)
    if not isinstance(path, Path):
        return "unknown"
    result, _, started = fold(path)
    if since is not None and started <= (since[1] if since[0] == str(path) else -1):
        return "unknown"
    return result


def position(state, task):
    path = live_log(state, task)
    if path is None:
        return None
    if not isinstance(path, Path):
        raise ValueError("dsh session log is unreadable")
    return [str(path), fold(path)[1]]


def resume(args):
    state, task, model, effort, cwd = args
    try:
        binding = json.loads((Path(state) / f"{task}.dsh-session").read_text())
    except (OSError, ValueError):
        # No recorded session: the caller prepares a fresh launch.
        return
    model = model.removeprefix("deepseek/")
    effort = "" if effort in ("", "default") else effort
    if (binding.get("model"), binding.get("effort"), binding["cwd"]) != (model, effort, str(Path(cwd).resolve())):
        return
    path = session_path(binding)
    if not isinstance(path, Path):
        return
    session = resume_target(path)
    root = Path(binding["root"])
    atomic_json(root / "launch.yml", launch_patch(model, effort, cwd, root / "dsh", session))
    print(root)


def session_file(args):
    state, task = args
    path = live_log(state, task)
    if isinstance(path, Path):
        print(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("values", nargs=7)
    p = sub.add_parser("resume")
    p.add_argument("values", nargs=5)
    p = sub.add_parser("session-file")
    p.add_argument("values", nargs=2)
    p = sub.add_parser("position")
    p.add_argument("state")
    p.add_argument("task")
    p = sub.add_parser("state")
    p.add_argument("state")
    p.add_argument("task")
    p.add_argument("--since", default="")
    p = sub.add_parser("route")
    p.add_argument("model")
    p.add_argument("provider", nargs="?", default="")
    p = sub.add_parser("check")
    p.add_argument("harness")
    p.add_argument("model")
    p.add_argument("provider", nargs="?", default="")
    p = sub.add_parser("normalize")
    p.add_argument("file")
    p.add_argument("output")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.values)
        elif args.command == "resume":
            resume(args.values)
        elif args.command == "session-file":
            session_file(args.values)
        elif args.command == "route":
            print(route(args.model, args.provider))
        elif args.command == "check":
            check(args.harness, args.model, args.provider)
        elif args.command == "normalize":
            atomic_json(Path(args.output), normalize(json.loads(Path(args.file).read_text())))
        elif args.command == "position":
            where = position(args.state, args.task)
            if where is not None:
                print(json.dumps(where))
        elif args.command == "state":
            try:
                print(turn_state(args.state, args.task, json.loads(args.since) if args.since else None))
            except (OSError, ValueError, KeyError, TypeError):
                print("unknown")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
