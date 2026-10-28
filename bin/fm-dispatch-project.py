#!/usr/bin/env python3
"""Dispatch project identity, without interpreting task prose or caller ids.

scaffold <home> <projects> <repo>: emit one FIRSTMATE_DISPATCH JSON record
containing only the clone's absolute project_path. Unregistered scaffold inputs
can still be written for manual intake; resolution never accepts them.
snapshot <home> <projects> <projects.md>: freeze registry ids and their clone
locations. <projects> is the home's projects directory.
resolve <brief> <snapshot.json>: derive the id by strict realpath equality with
exactly one registered clone. No text normalization or negative selectors.
"""
import json
from pathlib import Path
import sys


PREFIX = "FIRSTMATE_DISPATCH: "


def registry(home, projects, source):
    try:
        lines = Path(source).read_text(encoding="utf-8").splitlines()
    except OSError:
        raise ValueError("project registry data/projects.md is missing or unreadable") from None
    entries = {}
    for line in lines:
        if not line.startswith("- "):
            continue
        name = line[2:].split(" [", 1)[0].split(" - ", 1)[0]
        if not name or name in (".", "..") or "/" in name or name in entries:
            raise ValueError("project registry has an invalid or duplicate project id")
        entries[name] = str(home if name == "firstmate" else projects / name)
    if not entries:
        raise ValueError("project registry has no project ids")
    return entries


def resolve(brief, entries):
    lines = Path(brief).read_text(encoding="utf-8").splitlines()
    # The scaffold's first line is metadata, not a search target in task prose.
    # A fenced example elsewhere can neither supply nor override this record.
    if not lines or not lines[0].startswith(PREFIX):
        raise ValueError("brief is missing FIRSTMATE_DISPATCH project_path")
    try:
        record = json.loads(lines[0][len(PREFIX):])
    except ValueError:
        raise ValueError("brief FIRSTMATE_DISPATCH must be a typed project_path record") from None
    if (not isinstance(record, dict) or set(record) != {"project_path"}
            or not isinstance(record["project_path"], str)
            or not Path(record["project_path"]).is_absolute()):
        raise ValueError("brief FIRSTMATE_DISPATCH must be a typed absolute project_path record")
    try:
        clone = Path(record["project_path"]).resolve(strict=True)
    except (OSError, RuntimeError):
        raise ValueError("brief project_path has no existing project clone") from None
    matches = []
    for name, location in entries.items():
        try:
            registered = Path(location).resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if registered == clone and registered.is_dir():
            matches.append(name)
    if len(matches) != 1:
        raise ValueError("brief project_path must resolve to exactly one registered project clone")
    return matches[0]


def main():
    action, *args = sys.argv[1:]
    if action == "scaffold":
        home = Path(args[0]).absolute()
        location = home if args[2] == "firstmate" else Path(args[1]).absolute() / args[2]
        print(PREFIX + json.dumps({"project_path": str(location)}, ensure_ascii=False))
    elif action == "snapshot":
        print(json.dumps(registry(Path(args[0]).absolute(), Path(args[1]).absolute(), args[2]), ensure_ascii=False))
    elif action == "resolve":
        project = resolve(args[0], json.loads(Path(args[1]).read_text(encoding="utf-8")))
        if len(args) == 3:
            task = Path(args[2])
            text = task.read_text(encoding="utf-8")
            # Section extraction omits the header already. Whole-brief fallback
            # removes only that first line, preserving examples in task prose.
            if text.startswith(PREFIX):
                task.write_text(text.partition("\n")[2], encoding="utf-8")
        print(project)
    else:
        raise ValueError("unknown project binding action")


if __name__ == "__main__":
    try:
        main()
    except UnicodeError:
        print("project binding could not read UTF-8 local inputs", file=sys.stderr)
        sys.exit(1)
    except (ValueError, OSError, RuntimeError) as error:
        # Never print brief content or a filesystem exception containing it.
        print(str(error) if isinstance(error, ValueError) else "project binding could not read its local inputs", file=sys.stderr)
        sys.exit(1)
