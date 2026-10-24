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
The installed package tree is reproduced inside the launch root, hard-linked
file by file where the filesystem allows and copied otherwise, never linked as
a directory. DSH's own configuration, credentials, preferences, and session
logs belong exclusively to this launch; every other operator-home entry
(FM_DSH_OPERATOR_HOME, else the invoking HOME) is symlinked into the private
HOME so the agent keeps the operator's CLI authentication and tool state.
prepare-primary STATE ID GENERATION SOURCE_HOME MODEL EFFORT CWD CODE_ROOT
stages the same private runtime plus CODE_ROOT/.dsh/fm-primary.mjs, the native
session-open, watcher and passive turn-end adapter. Resume retains that role.
resume STATE ID MODEL EFFORT CWD rewrites the bound launch patch to resume the
newest depth-zero session, or prints nothing when the binding changed.
bound STATE ID prints the binding's model as deepseek/<id> and its effort
(default when none) on two lines.
own-model prints, as deepseek/<id>, the model bound to the Firstmate-prepared
generation that DSH_HOME names, and fails unless that binding still names it.
preferred-model OPERATOR_HOME prints, as deepseek/<id>, the operator's persisted
dsh-tui /model choice in OPERATOR_HOME/.dsh-tui/model.json, and fails unless it
is a concrete deepseek-official model.
session-file STATE ID prints the live depth-zero session log.
position STATE ID prints the live session log and its last durable seq as JSON,
or nothing before the launch has a log.
state STATE ID [--since POSITION] folds only the newest depth-zero session in
that launch's plain JSONL store, from its newest turn/start (or the last MiB,
whichever reaches further back), however large that turn is. Each session
directory's highest-numbered session.v*.jsonl is read whatever its number,
and admitted by behavior: a session header, then events with a type and a
strictly increasing integer seq. Missing data, or data that fails one of
those checks, prints "unknown: <the failed check>". With --since, anything
recorded at or before POSITION is history: a turn must have started beyond
it, or the state is unknown.
route MODEL [PROVIDER] prints the default model-family adapter. DeepSeek is
matched as omp resolves it: provider deepseek, or a deepseek/ model prefix,
trimmed and case-insensitive.
check HARNESS MODEL [PROVIDER] requires dsh for DeepSeek and refuses dsh
unless the model is a concrete DeepSeek id: a DeepSeek route, then a non-empty
id with no slash or whitespace.
canonical MODEL [PROVIDER] applies the dsh check and prints the model's one
identity, deepseek/<id>, which launch metadata and relaunch comparisons use.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys

CHUNK = 1024 * 1024


def deepseek_id(model, provider=""):
    head, slash, tail = model.strip().partition("/")
    if slash and head.strip().lower() == "deepseek":
        return tail.strip()
    if provider.strip().lower() == "deepseek":
        return model.strip()
    return None


def route(model, provider=""):
    if deepseek_id(model, provider) is not None:
        return "dsh"
    if model.startswith("claude"):
        return "claude"
    return "omp"


def check(harness, model, provider=""):
    if harness != "dsh":
        if route(model, provider) == "dsh":
            raise ValueError("DeepSeek runs through dsh-tui, not " + harness + "; select --harness dsh")
        return
    bare = deepseek_id(model, provider)
    if not model.strip() or bare == "":
        raise ValueError("dsh requires an explicit DeepSeek model id")
    if bare is None:
        raise ValueError(f"dsh runs only DeepSeek models, not '{model}'")
    if "/" in bare or any(c.isspace() for c in bare):
        raise ValueError("dsh requires a concrete DeepSeek model id")


def canonical(model, provider=""):
    check("dsh", model, provider)
    return "deepseek/" + deepseek_id(model, provider)


def normalize(value):
    if isinstance(value, list):
        return [normalize(item) for item in value]
    if isinstance(value, dict):
        value = {key: normalize(item) for key, item in value.items()}
        model, provider = value.get("model", ""), value.get("provider", "")
        if "harness" in value and isinstance(model, str) and isinstance(provider, str):
            check(value["harness"], model, provider)
            if value["harness"] == "dsh":
                value["model"] = canonical(model, provider)
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


def launch_patch(model, effort, cwd, dsh, session_id, primary_root=None):
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
        *([{"insert": [{"id": "firstmate-primary", "name": str(Path(primary_root) / ".dsh" / "fm-primary.mjs"),
            "config": {"root": primary_root, "home": str(Path(cwd).resolve())}}]}] if primary_root else []),
    ]


def resume_target(path):
    header = json.loads(path.open().readline())
    session = header["id"]
    import uuid
    if str(uuid.UUID(session)) != session:
        raise ValueError("invalid dsh session id")
    return session


def prepare(args, primary_root=None):
    state, task, generation, source_home, model, effort, cwd = args
    if primary_root is not None:
        primary_root = str(Path(primary_root).resolve())
        if not (Path(primary_root) / ".dsh" / "fm-primary.mjs").is_file():
            raise ValueError("dsh primary plugin is missing")
    check("dsh", model)
    model = deepseek_id(model)
    if effort in ("", "default"):
        effort = ""
    elif effort not in ("low", "medium", "high", "xhigh", "max"):
        raise ValueError(f"unsupported dsh effort: {effort}")
    source = Path(source_home)
    original = source / "profiles" / "dsh-tui"
    root = Path(state).resolve() / f"{task}.dsh" / generation
    root.mkdir(parents=True, exist_ok=False, mode=0o700)
    home = root / "home"
    dsh = root / "dsh"
    prefs = home / ".dsh-tui"
    prefs.mkdir(parents=True, mode=0o700)
    # Every agent needs the operator's CLI authentication and tool state.
    # Link unrelated home entries, not copies of credentials; DSH's own two
    # roots remain exclusively launch-local.
    operator_home = Path(os.environ.get("FM_DSH_OPERATOR_HOME", str(Path.home()))).resolve()
    for entry in operator_home.iterdir():
        if entry.name not in (".dsh", ".dsh-tui"):
            (home / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    (home / ".dsh").symlink_to(dsh, target_is_directory=True)
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
    atomic_json(root / "launch.yml", launch_patch(model, effort, cwd, dsh, "", primary_root))
    binding = Path(state) / f"{task}.dsh-session"
    try:
        previous = Path(json.loads(binding.read_text())["root"])
    except (OSError, ValueError, KeyError, TypeError):
        previous = None
    atomic_json(binding, {"root": str(root), "cwd": str(Path(cwd).resolve()), "generation": generation, "model": model, "effort": effort, "primary_root": primary_root})
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
        path = max(logs)[1]
        with path.open("rb") as stream:
            line = stream.readline(65536)
        try:
            header = json.loads(line)
        except ValueError:
            header = None
        if not isinstance(header, dict) or header.get("type") != "session":
            raise ValueError(f"{path} does not open with a session header")
        if header.get("delegationDepth") != 0 or header.get("cwd") != binding["cwd"]:
            continue
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
            if b"turn/start" not in line:
                continue
            try:
                event = json.loads(line)
            except ValueError:
                raise ValueError(f"dsh session log has an unparseable event at byte {offset}") from None
            if isinstance(event, dict) and event.get("type") == "turn/start":
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
            try:
                event = json.loads(line)
            except ValueError:
                raise ValueError(f"dsh session log has an unparseable event after seq {last_seq}") from None
            if not isinstance(event, dict) or not isinstance(event.get("type"), str):
                raise ValueError(f"dsh session log has an event without a type after seq {last_seq}")
            if event["type"] == "session":
                continue
            seq = event.get("seq")
            if not isinstance(seq, int):
                raise ValueError(f"dsh session log has a {event['type']} event without an integer seq after seq {last_seq}")
            if seq <= last_seq:
                raise ValueError(f"dsh session log has a non-monotonic sequence: seq {seq} after {last_seq}")
            last_seq = seq
            if event.get("type") == "turn/start":
                result = "busy"
                started = seq
            elif event.get("type") == "turn/end":
                result = "idle"
        return result, last_seq, started


def turn_state(state, task, since=None):
    path = live_log(state, task)
    if path is None:
        raise ValueError("no depth-zero dsh session log yet")
    result, _, started = fold(path)
    if result == "unknown":
        raise ValueError("dsh session log has no turn/start or turn/end yet")
    if since is not None and started <= (since[1] if since[0] == str(path) else -1):
        raise ValueError("no turn started beyond the launch position")
    return result


def position(state, task):
    path = live_log(state, task)
    if path is None:
        return None
    return [str(path), fold(path)[1]]


def resume(args, primary_root=None):
    state, task, model, effort, cwd = args
    try:
        binding = json.loads((Path(state) / f"{task}.dsh-session").read_text())
    except (OSError, ValueError):
        # No recorded session: the caller prepares a fresh launch.
        return
    model = deepseek_id(model)
    effort = "" if effort in ("", "default") else effort
    if (binding.get("model"), binding.get("effort"), binding["cwd"]) != (model, effort, str(Path(cwd).resolve())):
        return
    path = session_path(binding)
    if path is None:
        return
    session = resume_target(path)
    root = Path(binding["root"])
    if primary_root is not None:
        primary_root = str(Path(primary_root).resolve())
        if not (Path(primary_root) / ".dsh" / "fm-primary.mjs").is_file():
            raise ValueError("dsh primary plugin is missing")
        binding["primary_root"] = primary_root
        atomic_json(Path(state) / f"{task}.dsh-session", binding)
    atomic_json(root / "launch.yml", launch_patch(model, effort, cwd, root / "dsh", session, binding.get("primary_root")))
    print(root)


def bound(state, task):
    binding = json.loads((Path(state) / f"{task}.dsh-session").read_text())
    print("deepseek/" + binding["model"])
    print(binding.get("effort") or "default")


def own_model():
    dsh = os.environ.get("DSH_HOME", "")
    runtime = Path(dsh).resolve().parent
    store = runtime.parent
    if not dsh or not store.name.endswith(".dsh"):
        raise ValueError("DSH_HOME names no Firstmate-prepared dsh session")
    binding = json.loads(store.with_name(store.name + "-session").read_text())
    if Path(binding["root"]) != runtime:
        raise ValueError(f"{runtime} is no longer the bound dsh generation")
    print("deepseek/" + binding["model"])


def preferred_model(operator_home):
    path = Path(operator_home) / ".dsh-tui" / "model.json"
    try:
        preference = json.loads(path.read_text())
    except FileNotFoundError:
        raise ValueError(f"no DSH model preference at {path}") from None
    if not isinstance(preference, dict) or preference.get("provider") != "deepseek-official" \
            or not isinstance(preference.get("model"), str) or not preference["model"]:
        raise ValueError(f"{path} names no deepseek-official model")
    model = "deepseek/" + preference["model"]
    check("dsh", model)
    print(model)


def session_file(args):
    state, task = args
    path = live_log(state, task)
    if path is not None:
        print(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("values", nargs=7)
    p = sub.add_parser("prepare-primary")
    p.add_argument("values", nargs=7)
    p.add_argument("primary_root")
    p = sub.add_parser("resume")
    p.add_argument("values", nargs=5)
    p.add_argument("--primary-root")
    p = sub.add_parser("bound")
    p.add_argument("state")
    p.add_argument("task")
    sub.add_parser("own-model")
    p = sub.add_parser("preferred-model")
    p.add_argument("operator_home")
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
    p = sub.add_parser("canonical")
    p.add_argument("model")
    p.add_argument("provider", nargs="?", default="")
    p = sub.add_parser("normalize")
    p.add_argument("file")
    p.add_argument("output")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare(args.values)
        elif args.command == "prepare-primary":
            prepare(args.values, args.primary_root)
        elif args.command == "resume":
            resume(args.values, args.primary_root)
        elif args.command == "bound":
            bound(args.state, args.task)
        elif args.command == "own-model":
            own_model()
        elif args.command == "preferred-model":
            preferred_model(args.operator_home)
        elif args.command == "session-file":
            session_file(args.values)
        elif args.command == "route":
            print(route(args.model, args.provider))
        elif args.command == "check":
            check(args.harness, args.model, args.provider)
        elif args.command == "canonical":
            print(canonical(args.model, args.provider))
        elif args.command == "normalize":
            atomic_json(Path(args.output), normalize(json.loads(Path(args.file).read_text())))
        elif args.command == "position":
            where = position(args.state, args.task)
            if where is not None:
                print(json.dumps(where))
        elif args.command == "state":
            try:
                print(turn_state(args.state, args.task, json.loads(args.since) if args.since else None))
            except KeyError as error:
                print(f"unknown: dsh session binding lacks {error}")
            except (OSError, ValueError, TypeError) as error:
                print(f"unknown: {error}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
