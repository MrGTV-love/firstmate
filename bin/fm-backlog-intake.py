#!/usr/bin/env python3
"""fm-backlog-intake.py - the one owner of backlog intake and closing-proof judgments.

bin/fm-tasks-axi.sh calls this helper for every judgment it cannot make in shell.
It reads `tasks-axi list` and `tasks-axi show` output on stdin and never writes.

  neighbours <title> [<archive> [<own-id>]]
                            stdin: `tasks-axi list` output. Prints one
                            "<id>\\t<state>\\t<score>\\t<source>\\t<title>" line for every
                            open item and every one of the newest RECENT_DONE Done
                            items whose title words overlap <title> at THRESHOLD or
                            more, highest score first (source is "active" or
                            "archive"). The list holds only the Done rows tasks-axi
                            keeps (done_keep); the rest of the newest RECENT_DONE come
                            from the markdown done archive <archive> when given. Exit
                            0 when at least one is printed, 1 when none is, 3 (with a
                            reason on stderr) when the list or the archive cannot be
                            read or interpreted. The row <own-id> (the add's
                            own id) is never its own neighbour.
  archived <archive> <id>   Exit 0 when <id> is a row of the markdown done archive.
  exists <id>               stdin: the same list output. Exit 0 when <id> is a row.
  dependents <id>           stdin: `tasks-axi list --fields blocked_by` output. Prints
                            one line per item that is not Done and is blocked by
                            <id>. Exit 0 when at least one is printed, 1 when none
                            is, 3 when the list cannot be read or has no blocked_by
                            column.
  field <name>              stdin: `tasks-axi show --full` output. Prints that field
                            decoded (the body keeps its line breaks); exit 1 if absent.
  owner-filed               stdin: an item's title and body. Exit 0 when the text
                            quotes the owner or captain (OWNER_PATTERN), else 1.
  objectives <file>         Prints the objective ids a docs/objectives.md lists.

Single owners, defined only here:
  THRESHOLD     the title-word overlap that makes two items neighbours.
  RECENT_DONE   how many of the newest Done rows an add is compared with.
  OWNER_PATTERN the heuristic for an item the owner filed.
Title overlap is the Jaccard similarity of two title word sets: the number of
words both titles share divided by the number of distinct words in either. A word
is a run of lower-case letters or digits at least three characters long, and a
small stop-word list is removed. A title with no word left has no neighbours.
`tasks-axi list` cuts a title at TITLE_LIST_LIMIT characters, so both sides are
compared on that many characters.
"""
import json
import re
import sys

THRESHOLD = 0.25
RECENT_DONE = 50
TITLE_LIST_LIMIT = 80
TRUNCATION_SENTINEL = re.compile(r"\n\.\.\. \(truncated, .*$", re.S)

STOP_WORDS = frozenset(
    "the and for with from into onto that this these those when then than are was were not "
    "its but after before over under per via also any all can has have had will would should "
    "does did use uses used using new one two out off too only more less each own same".split()
)

# An item "filed by the owner" quotes the owner or captain in its text. This is the
# triage report's heuristic (data/fm-backlog-triage-and-hygiene/report.md): the text
# contains "Captain" or "Owner" followed by a space and one of ask, words, question,
# call, decision, ruling, rule or answer, or "Captain 2026", "Owner:" or "Captain:",
# or "Owner" or "Captain" followed by an ISO date and a colon ("Owner 2026-11-01:"),
# or "Captain's words", "Captain's ask", "Captain chose" or "Captain direction"
# followed by a colon, with an optional ISO date before it.
# Only the capitalised forms count, so a bare "Owner 2026", a lower-case
# "lock owner:" or "owner decision", and "Owner's idea" do not match.
OWNER_PATTERN = re.compile(
    r"(?:Captain|Owner) (?:ask|words|question|call|decision|ruling|rule|answer)"
    r"|Captain 2026"
    r"|Owner:"
    r"|Captain:"
    r"|(?:Captain|Owner) \d{4}-\d{2}-\d{2}:"
    r"|Captain(?:'s words|'s ask| chose| direction)(?: \d{4}-\d{2}-\d{2})?:"
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


class IntakeError(Exception):
    """The backlog or its archive cannot be read or interpreted."""


def list_rows(text):
    """Rows of `tasks-axi list` output as dicts, in the order printed.

    The rows must agree with the declared count, so a cut or garbled list is an
    error instead of a shorter neighbour set."""
    columns = None
    declared = None
    count = None
    rows = []
    for line in text.splitlines():
        counted = re.match(r"^count: (\d+)$", line)
        if counted:
            count = int(counted.group(1))
            continue
        header = re.match(r"^tasks\[(\d+)\]\{(.*)\}:$", line)
        if header:
            declared = int(header.group(1))
            columns = header.group(2).split(",")
            continue
        if columns is None:
            continue
        if not line.startswith("  "):
            columns = None
            continue
        cells = split_row(line[2:])
        if len(cells) != len(columns):
            raise IntakeError("a backlog row has an unexpected shape: " + line[:80])
        row = {name: unquote(cell) for name, cell in zip(columns, cells)}
        if "title" in row:
            row["title"] = TRUNCATION_SENTINEL.sub("", row["title"])
        rows.append(row)
    if count is None or count != len(rows) or (declared is not None and declared != len(rows)):
        raise IntakeError("the backlog list is incomplete or not in the expected format")
    return rows


ARCHIVE_ROW = re.compile(r"^- \[x\] (\S+) - (.*)$")
ARCHIVE_TAIL = re.compile(
    r"\s*(?:\((?:repo|kind|done|reported|since|pr|blocked-by|merged |priority: |hold: |hold-kind: |hold-until:? )[^)]*\)"
    r"|blocked-by: \S+|https?://\S+|data/\S+)\s*$"
)


def archive_text(path):
    """The markdown done archive as text; an archive not yet written is empty."""
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except FileNotFoundError:
        return ""
    except (OSError, UnicodeDecodeError) as error:
        raise IntakeError("the done archive %s cannot be read: %s" % (path, error))


def archive_blocks(path):
    """Archive rows grouped by the `## Archived <date>` block that holds them.

    tasks-axi appends one block per prune, so later blocks are newer; inside a
    block the rows keep the order they had in the Done section, newest first."""
    blocks, current = [], []
    for line in archive_text(path).splitlines():
        if line.startswith("## "):
            blocks.append(current)
            current = []
            continue
        if not line.startswith("- [x]"):
            continue
        match = ARCHIVE_ROW.match(line)
        if not match:
            raise IntakeError("a done archive row cannot be interpreted: " + line[:80])
        title = match.group(2)
        while True:
            trimmed = ARCHIVE_TAIL.sub("", title)
            if trimmed == title:
                break
            title = trimmed
        current.append({"id": match.group(1), "state": "done", "source": "archive", "title": title[:TITLE_LIST_LIMIT]})
    blocks.append(current)
    return blocks


def archive_rows(path, count):
    """The newest `count` rows of the markdown done archive, newest first."""
    if count <= 0 or not path:
        return []
    rows = []
    for block in reversed(archive_blocks(path)):
        rows.extend(block)
    return rows[:count]


def neighbours(title, text, archive=None, own=""):
    """Every open item and newest-Done item whose title overlaps `title`, best first."""
    mine = words(title[:TITLE_LIST_LIMIT])
    if not mine:
        return []
    rows = list_rows(text)
    for row in rows:
        row["source"] = "active"
    kept_done = sum(1 for r in rows if r.get("state") == "done")
    rows = rows + archive_rows(archive, RECENT_DONE - kept_done)
    found = []
    done_seen = 0
    for row in rows:
        state = row.get("state", "")
        if state == "done":
            done_seen += 1
            if done_seen > RECENT_DONE:
                continue
        elif state not in ("queued", "in_flight"):
            continue
        if own and row.get("id") == own:
            continue
        score = overlap(mine, words(row.get("title", "")[:TITLE_LIST_LIMIT]))
        if score >= THRESHOLD:
            found.append((score, row))
    found.sort(key=lambda pair: -pair[0])
    return found


def show_field(name, text):
    for line in text.splitlines():
        match = re.match(r"^  %s: ?(.*)$" % re.escape(name), line)
        if match:
            value = unquote(match.group(1))
            return "" if value == "-" else value
    return None


def dependents(item, text):
    found = []
    for row in list_rows(text):
        if "blocked_by" not in row:
            raise IntakeError("the backlog list has no blocked_by column")
        if row.get("state") != "done" and item in row["blocked_by"].split(","):
            found.append(row.get("id", ""))
    return found


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    command, args = argv[1], argv[2:]
    try:
        return run(command, args)
    except IntakeError as error:
        sys.stderr.write("fm-backlog-intake: %s\n" % error)
        return 3


def run(command, args):
    if command == "neighbours" and len(args) in (1, 2, 3):
        found = neighbours(args[0], sys.stdin.read(), args[1] if len(args) >= 2 else None, args[2] if len(args) == 3 else "")
        for score, row in found:
            title = row.get("title", "").replace("\t", " ").replace("\n", " ")
            print("%s\t%s\t%.2f\t%s\t%s" % (row.get("id", ""), row.get("state", ""), score, row.get("source", ""), title))
        return 0 if found else 1
    if command == "archived" and len(args) == 2:
        return 0 if any(r["id"] == args[1] for block in archive_blocks(args[0]) for r in block) else 1
    if command == "exists" and len(args) == 1:
        return 0 if any(r.get("id") == args[0] for r in list_rows(sys.stdin.read())) else 1
    if command == "dependents" and len(args) == 1:
        found = dependents(args[0], sys.stdin.read())
        if found:
            print("\n".join(found))
        return 0 if found else 1
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
