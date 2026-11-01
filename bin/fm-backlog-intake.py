#!/usr/bin/env python3
"""fm-backlog-intake.py - the one owner of backlog intake and closing-proof judgments.

bin/fm-tasks-axi.sh calls this helper for every judgment it cannot make in shell.
It reads `tasks-axi list` and `tasks-axi show` output on stdin and never writes.

  neighbours <title> [<archive>]
                            stdin: `tasks-axi list` output. Prints up to three
                            "<id>\\t<state>\\t<score>\\t<title>" lines for open items and
                            the newest Done items whose title words overlap <title>
                            at THRESHOLD or more. The list holds only the Done rows
                            tasks-axi keeps (done_keep); the rest of the newest
                            RECENT_DONE come from the markdown done archive <archive>
                            when given. Exit 0 when at least one is printed, 1 when
                            none is.
  exists <id>               stdin: the same list output. Exit 0 when <id> is a row.
  field <name>              stdin: `tasks-axi show --full` output. Prints that field
                            decoded (the body keeps its line breaks); exit 1 if absent.
  owner-filed               stdin: an item's title and body. Exit 0 when the text
                            quotes the owner or captain (OWNER_PATTERN), else 1.
  objectives <file>         Prints the objective ids a docs/objectives.md lists.

Single owners, defined only here:
  THRESHOLD     the title-word overlap that makes two items neighbours.
  RECENT_DONE   how many of the newest Done rows an add is compared with.
  OWNER_PATTERN the heuristic for an item the owner filed.
Title overlap is Jaccard similarity of the lower-case words of three or more
letters or digits with a small stop-word list removed. A title with fewer than
MIN_WORDS such words is too short to judge and has no neighbours. `tasks-axi
list` cuts a title at TITLE_LIST_LIMIT characters, so both sides are compared on
that many characters.
"""
import json
import re
import sys

THRESHOLD = 0.25
RECENT_DONE = 50
MIN_WORDS = 3
SHOWN = 3
TITLE_LIST_LIMIT = 80
TRUNCATION_SENTINEL = re.compile(r"\n\.\.\. \(truncated, .*$", re.S)

STOP_WORDS = frozenset(
    "the and for with from into onto that this these those when then than are was were not "
    "its but after before over under per via also any all can has have had will would should "
    "does did use uses used using new one two out off too only more less each own same".split()
)

# An item "filed by the owner" quotes the captain or owner in its text. This is
# the triage report's heuristic (data/fm-backlog-triage-and-hygiene/report.md,
# "items filed by the owner"): "Captain" or "Owner" followed by ask, words,
# question, call, decision, ruling, rule or answer, "Captain 2026", "Owner:" and
# "Captain:". The capitalised bare forms keep a lower-case "lock owner:" from
# matching.
OWNER_PATTERN = re.compile(
    r"\b(?:[Cc]aptain|[Oo]wner)(?:'s|’s)?\s+(?:ask|words|question|call|decision|ruling|rule|answer)\b"
    r"|\bCaptain\s+2026\b"
    r"|\bOwner:"
    r"|\bCaptain:"
)

OBJECTIVE_LINE = re.compile(r"^- (O[0-9]+) - ")


def words(text):
    found = {w for w in re.findall(r"[a-z0-9]+", text.lower()) if len(w) >= 3}
    return found - STOP_WORDS


def overlap(left, right):
    union = left | right
    return len(left & right) / len(union) if union else 0.0


def split_row(line):
    """Split one tasks-axi list row on commas outside double quotes."""
    out, cur, quoted, escaped = [], [], False, False
    for ch in line:
        if quoted:
            cur.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
            cur.append(ch)
        elif ch == ",":
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    out.append("".join(cur))
    return out


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except ValueError:
            return value[1:-1]
    return value


def list_rows(text):
    """Rows of `tasks-axi list` output as dicts, in the order printed."""
    columns = None
    rows = []
    for line in text.splitlines():
        header = re.match(r"^tasks\[\d+\]\{(.*)\}:$", line)
        if header:
            columns = header.group(1).split(",")
            continue
        if columns is None:
            continue
        if not line.startswith("  "):
            columns = None
            continue
        cells = split_row(line[2:])
        if len(cells) != len(columns):
            continue
        row = {name: unquote(cell) for name, cell in zip(columns, cells)}
        if "title" in row:
            row["title"] = TRUNCATION_SENTINEL.sub("", row["title"])
        rows.append(row)
    return rows


ARCHIVE_ROW = re.compile(r"^- \[x\] (\S+) - (.*)$")
ARCHIVE_TAIL = re.compile(r"\s*(?:\((?:repo|kind|done|reported|since|pr|blocked-by)[^)]*\)|https?://\S+|data/\S+)\s*$")


def archive_rows(path, count):
    """The newest `count` rows of a markdown done archive, newest first."""
    if count <= 0 or not path:
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in reversed(lines):
        match = ARCHIVE_ROW.match(line)
        if not match:
            continue
        title = match.group(2)
        while True:
            trimmed = ARCHIVE_TAIL.sub("", title)
            if trimmed == title:
                break
            title = trimmed
        rows.append({"id": match.group(1), "state": "done", "title": title[:TITLE_LIST_LIMIT]})
        if len(rows) >= count:
            break
    return rows


def neighbours(title, text, archive=None):
    mine = words(title[:TITLE_LIST_LIMIT])
    if len(mine) < MIN_WORDS:
        return []
    found = []
    done_seen = 0
    rows = list_rows(text)
    kept_done = sum(1 for r in rows if r.get("state") == "done")
    rows = rows + archive_rows(archive, RECENT_DONE - kept_done)
    for row in rows:
        state = row.get("state", "")
        if state == "done":
            done_seen += 1
            if done_seen > RECENT_DONE:
                continue
        elif state not in ("queued", "in_flight"):
            continue
        theirs = words(row.get("title", ""))
        if len(theirs) < MIN_WORDS:
            continue
        score = overlap(mine, theirs)
        if score >= THRESHOLD:
            found.append((score, row))
    found.sort(key=lambda pair: -pair[0])
    return found[:SHOWN]


def show_field(name, text):
    for line in text.splitlines():
        match = re.match(r"^  %s: ?(.*)$" % re.escape(name), line)
        if match:
            value = unquote(match.group(1))
            return "" if value == "-" else value
    return None


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    command, args = argv[1], argv[2:]
    if command == "neighbours" and len(args) in (1, 2):
        found = neighbours(args[0], sys.stdin.read(), args[1] if len(args) == 2 else None)
        for score, row in found:
            title = row.get("title", "").replace("\t", " ").replace("\n", " ")
            print("%s\t%s\t%.2f\t%s" % (row.get("id", ""), row.get("state", ""), score, title))
        return 0 if found else 1
    if command == "exists" and len(args) == 1:
        return 0 if any(r.get("id") == args[0] for r in list_rows(sys.stdin.read())) else 1
    if command == "field" and len(args) == 1:
        value = show_field(args[0], sys.stdin.read())
        if value is None:
            return 1
        sys.stdout.write(value)
        return 0
    if command == "owner-filed" and not args:
        return 0 if OWNER_PATTERN.search(sys.stdin.read()) else 1
    if command == "objectives" and len(args) == 1:
        try:
            with open(args[0], encoding="utf-8") as handle:
                ids = [m.group(1) for m in map(OBJECTIVE_LINE.match, handle.read().splitlines()) if m]
        except OSError:
            return 1
        if not ids:
            return 1
        print("\n".join(ids))
        return 0
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
