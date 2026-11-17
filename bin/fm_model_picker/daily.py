"""Daily-collection helpers for the model picker: stage, promote, freshness.

bin/fm-model-picker-daily.sh owns the run order and the wake contract; this module owns
the three file operations it needs. The collector rewrites aa.sqlite, verdict.json and
projection/ in place, and sets verdict.json to UNTRUSTED before it rebuilds the matrix, so a
run that fails would leave the live data root half rebuilt. A daily run therefore works in a
staged copy and promotes it only when the collector exited 0.

  root                         print the data root (the collector's own resolution)
  stage    ROOT DEST PID       copy the live root to DEST, record PID as its owner (raw/ cloned where the filesystem can)
  discard  DEST PID            remove DEST only when its owner record names PID
  reap     ROOT                remove <ROOT>.daily.<pid> siblings whose recorded owner is gone, and nothing else
  verdict  ROOT                print TRUSTED, UNTRUSTED, ABSENT or UNREADABLE for ROOT's verdict.json
  promote  ROOT DEST           make the staged outputs the live ones (call only after exit 0)
  freshness ROOT [--now EPOCH] print state= hours= observed_at= day= reason= lines

A promotion replaces only the benchmark matrix in aa.sqlite, inside one transaction on the
live file: dispatch_log and outcomes, which the shadow picker writes while a run is under way,
are never touched. promote() is all or nothing: see its docstring.
"""
import calendar
import errno
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

# measured: value=36 date=2026-11-17 host=Mac-Studio margin=1.5 (hours; the owner's limit, Main 2638 D3: a 24 hour schedule plus 12 hours of grace, not a timeout)
STALE_AFTER_HOURS = 36
STALE_AFTER_SECONDS = STALE_AFTER_HOURS * 3600
MATRIX_TABLES = ("models", "metrics", "observations", "reconcile_runs")
LOOSE_FILES = ("snapshot.json", "coverage.md", "reconcile.md")
OWNER_MARK = ".fm-model-picker-daily-owner"
UNTRUSTED_VERDICT = '{"verdict": "UNTRUSTED", "line": "UNTRUSTED (promotion in progress)", "reason": "promotion in progress"}\n'


def _clone_tree(src, dest):
    """Copy a directory keeping modification times (rendered captures are aged by mtime)."""
    if sys.platform == "darwin":
        done = subprocess.run(["cp", "-Rpc", str(src), str(dest)], capture_output=True, check=False)
        if done.returncode == 0:
            return
        shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(src, dest, symlinks=True)


def _owner_pid(dest):
    try:
        text = (Path(dest) / OWNER_MARK).read_text().strip()
    except OSError:
        return None
    return int(text) if text.isdigit() else None


def _pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def stage(root, dest, owner):
    """Copy the live root to DEST and record the owning runner's pid there. DEST must not exist."""
    root, dest = Path(root), Path(dest)
    dest.mkdir(parents=True)
    (dest / OWNER_MARK).write_text(f"{int(owner)}\n")
    live_db = root / "aa.sqlite"
    if live_db.exists():
        source = sqlite3.connect(f"file:{live_db}?mode=ro", uri=True)
        target = sqlite3.connect(str(dest / "aa.sqlite"))
        try:
            source.backup(target)
        finally:
            target.close()
            source.close()
    for name in LOOSE_FILES + ("verdict.json",):
        if (root / name).is_file():
            shutil.copy2(root / name, dest / name)
    for name in ("projection", "raw"):
        if (root / name).is_dir():
            _clone_tree(root / name, dest / name)


def discard(dest, owner):
    """Remove a staging directory, only when its owner record names this pid."""
    dest = Path(dest)
    if dest.is_dir() and not dest.is_symlink() and _owner_pid(dest) == int(owner):
        shutil.rmtree(dest, ignore_errors=True)


def reap(root):
    """Remove staging directories a runner left behind: only a sibling of ROOT named
    <ROOT>.daily.<pid> that is a real directory whose owner record names a pid that is gone.
    A same-prefix directory with no owner record, or whose owner is alive, is never touched."""
    root = Path(root)
    for old in root.parent.glob(root.name + ".daily.*"):
        if old.is_dir() and not old.is_symlink():
            pid = _owner_pid(old)
            if pid is not None and not _pid_alive(pid):
                shutil.rmtree(old, ignore_errors=True)


def _write_atomic(path, text):
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    tmp.write_text(text)
    os.replace(tmp, path)


def _faults():
    """Fault injection for the tests, honored only when FM_TEST_SEAM=1. FM_MODEL_PICKER_DAILY_FAULT
    holds ';'-separated entries: rename:SRC_REGEX>>DST_REGEX fails a matching rename,
    kill:before-commit and kill:after-commit SIGKILL this process at that point,
    hold:before-commit:ANNOUNCE:RELEASE and hold:after-commit:ANNOUNCE:RELEASE create ANNOUNCE
    and wait there until RELEASE exists."""
    if os.environ.get("FM_TEST_SEAM") != "1":
        return []
    return [e for e in os.environ.get("FM_MODEL_PICKER_DAILY_FAULT", "").split(";") if e]


def _point(name):
    for entry in _faults():
        kind, _, rest = entry.partition(":")
        if kind == "kill" and rest == name:
            os.kill(os.getpid(), signal.SIGKILL)
        if kind == "hold" and rest.startswith(name + ":"):
            _, announce, release = rest.split(":", 2)
            Path(announce).write_text("")
            while not os.path.exists(release):
                time.sleep(0.05)


def _rename(src, dst):
    for entry in _faults():
        kind, _, rest = entry.partition(":")
        if kind == "rename":
            src_re, _, dst_re = rest.partition(">>")
            if re.search(src_re, str(src)) and re.search(dst_re, str(dst)):
                raise OSError(errno.ENOSPC, "injected rename fault", str(dst))
    os.rename(src, dst)


def _install(new, cur, undo, asides):
    """Put NEW where CUR is, moving CUR aside first; UNDO gets the step that reverses it."""
    aside = cur.with_name(f"{cur.name}.aside.{os.getpid()}")
    had = os.path.lexists(cur)
    if had:
        _rename(cur, aside)
        asides.append(aside)
    try:
        _rename(new, cur)
    except BaseException:
        if had:
            _rename(aside, cur)
        raise

    def back():
        _rename(cur, new)
        if had:
            _rename(aside, cur)

    undo.append(back)


def _merge_matrix(live_db, staged_db):
    """Replace the benchmark matrix in one transaction and commit it. Returns after the commit."""
    from . import aadb

    conn = aadb.open_db(live_db)
    try:
        conn.isolation_level = None
        conn.execute("ATTACH DATABASE ? AS staged", (str(staged_db),))
        conn.execute("BEGIN IMMEDIATE")
        try:
            for table in ("observations", "reconcile_runs", "metrics", "models"):
                conn.execute(f"DELETE FROM main.{table}")
            for table in MATRIX_TABLES:
                have = [r[1] for r in conn.execute(f"PRAGMA main.table_info({table})")]
                staged = {r[1] for r in conn.execute(f"PRAGMA staged.table_info({table})")}
                cols = ", ".join(c for c in have if c in staged)
                conn.execute(f"INSERT INTO main.{table} ({cols}) SELECT {cols} FROM staged.{table}")
            _point("before-commit")
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()


def _pid_of(name):
    tail = name.rsplit(".", 1)[-1]
    return int(tail) if tail.isdigit() else None


def _reap_leftovers(root):
    """After a good promotion, remove what an earlier killed promotion left in ROOT: only names
    this module makes (<name>.aside.<pid>, .verdict.json.prev.<pid>, <file>.tmp.<pid>) whose pid is gone."""
    for entry in root.iterdir():
        if not re.search(r"\.(aside|prev|tmp)\.\d+$", entry.name):
            continue
        pid = _pid_of(entry.name)
        if pid is None or _pid_alive(pid):
            continue
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry, ignore_errors=True)
        else:
            entry.unlink(missing_ok=True)


def promote(root, dest):
    """Install the staged generation as the live one, or leave a state a reader refuses.
    1. The live verdict.json is replaced by an UNTRUSTED marker; the previous one is kept aside.
    2. The old raw/, projection/ and loose files move aside and the staged ones take their place.
    3. The matrix is replaced and committed in one database transaction.
    4. Only then does the staged verdict replace the marker.
    A failure before the commit undoes every step; the previous verdict returns only when every
    undo succeeded, so a trusted verdict never sits over a mixed generation, and otherwise the
    marker stays. A failure or kill after the commit leaves the complete new generation under the
    marker. Either way the next good run repairs it. The error names the outcome first."""
    root, dest = Path(root), Path(dest)
    if not (dest / "aa.sqlite").is_file() or not (dest / "verdict.json").is_file():
        raise SystemExit(f"promote: {dest} holds no aa.sqlite and verdict.json from a finished run")
    root.mkdir(parents=True, exist_ok=True)
    undo, asides = [], []
    verdict, live_db = root / "verdict.json", root / "aa.sqlite"
    prev = root / f".verdict.json.prev.{os.getpid()}"
    had_verdict, had_db = verdict.exists(), live_db.exists()
    committed = False
    try:
        if had_verdict:
            shutil.copy2(verdict, prev)
        _write_atomic(verdict, UNTRUSTED_VERDICT)
        for name in ("raw", "projection") + LOOSE_FILES:
            if (dest / name).exists():
                _install(dest / name, root / name, undo, asides)
        if not had_db:
            undo.append(lambda: live_db.unlink(missing_ok=True))
        _merge_matrix(live_db, dest / "aa.sqlite")
        committed = True
        _point("after-commit")
        os.replace(dest / "verdict.json", verdict)
    except BaseException as error:
        if isinstance(error, KeyboardInterrupt):
            raise
        if committed:
            raise SystemExit("new snapshot installed, live verdict left UNTRUSTED until the next good run; "
                             f"promotion failed after the database commit: {error}") from error
        problems = []
        for step in reversed(undo):
            try:
                step()
            except BaseException as again:
                problems.append(str(again))
        if not problems:
            try:
                if had_verdict:
                    os.replace(prev, verdict)
                else:
                    verdict.unlink(missing_ok=True)
            except BaseException as again:
                problems.append(str(again))
        if problems:
            raise SystemExit("RESTORE INCOMPLETE, live verdict left UNTRUSTED; "
                             f"promotion failed: {error}; undo problems: {'; '.join(problems)}") from error
        raise SystemExit(f"previous snapshot restored; promotion failed: {error}") from error
    for leftover in asides + ([prev] if had_verdict else []):
        if leftover.is_dir():
            shutil.rmtree(leftover, ignore_errors=True)
        else:
            leftover.unlink(missing_ok=True)
    _reap_leftovers(root)


def verdict_word(root):
    """What a reader of ROOT would see: TRUSTED, UNTRUSTED, ABSENT or UNREADABLE."""
    path = Path(root) / "verdict.json"
    if not path.is_file():
        return "ABSENT"
    try:
        doc = json.loads(path.read_text())
    except (OSError, ValueError):
        return "UNREADABLE"
    word = doc.get("verdict") if isinstance(doc, dict) else None
    return word if word in ("TRUSTED", "UNTRUSTED") else "UNREADABLE"


def freshness(root, now):
    """Newest observed_at in aa.sqlite, read only. A snapshot is stale only when it is older
    than 36 hours; a missing, empty or unreadable one is reported as missing."""
    day = time.strftime("%Y-%m-%d", time.gmtime(now))
    out = {"state": "missing", "hours": "", "observed_at": "", "day": day, "reason": ""}
    db = Path(root) / "aa.sqlite"
    if not db.is_file():
        out["reason"] = f"no aa.sqlite at {db}"
        return out
    try:
        conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
        try:
            newest = conn.execute("SELECT MAX(observed_at) FROM observations").fetchone()[0]
        finally:
            conn.close()
    except sqlite3.Error as error:
        out["reason"] = f"cannot read {db}: {error}"
        return out
    if not newest:
        out["reason"] = f"{db} holds no observations"
        return out
    try:
        seen = calendar.timegm(time.strptime(newest, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        out["reason"] = f"{db} holds an unreadable observed_at: {newest}"
        return out
    age = max(0.0, now - seen)
    out.update(state="stale" if age > STALE_AFTER_SECONDS else "fresh",
               hours=f"{age / 3600:.1f}", observed_at=newest)
    return out


def main(argv):
    if not argv:
        raise SystemExit("usage: daily.py root | stage ROOT DEST PID | discard DEST PID | reap ROOT | promote ROOT DEST | verdict ROOT | freshness ROOT [--now EPOCH]")
    verb, rest = argv[0], argv[1:]
    if verb == "root":
        from . import collect

        print(collect.data_root())
    elif verb == "stage" and len(rest) == 3:
        stage(*rest)
    elif verb == "discard" and len(rest) == 2:
        discard(*rest)
    elif verb == "reap" and len(rest) == 1:
        reap(*rest)
    elif verb == "verdict" and len(rest) == 1:
        print(verdict_word(rest[0]))
    elif verb == "promote" and len(rest) == 2:
        promote(*rest)
    elif verb == "freshness" and len(rest) in (1, 3) and (len(rest) == 1 or rest[1] == "--now"):
        now = int(rest[2]) if len(rest) == 3 else int(time.time())
        for key, value in freshness(rest[0], now).items():
            print(f"{key}={value.replace(chr(10), ' ')}")
    else:
        raise SystemExit("daily.py: invalid arguments")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
