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

  recover  ROOT                settle a promotion that was stopped part way (roll it forward or back)

A promotion replaces only the benchmark matrix in aa.sqlite, inside one transaction on the
live file: dispatch_log and outcomes, which the shadow picker writes while a run is under way,
are never touched. promote() has one commit point and settles to one of two whole generations:
see its docstring. Both verbs print `outcome=<word>` on stdout and the reason on stderr.
"""
import calendar
import contextlib
import errno
import fcntl
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
from pathlib import Path

# measured: value=36 date=2026-11-17 host=Mac-Studio margin=1.5 (hours; the owner's limit, Main 2638 D3: a 24 hour schedule plus 12 hours of grace, not a timeout)
STALE_AFTER_HOURS = 36
STALE_AFTER_SECONDS = STALE_AFTER_HOURS * 3600
MATRIX_TABLES = ("models", "metrics", "observations", "reconcile_runs")
LOOSE_FILES = ("snapshot.json", "coverage.md", "reconcile.md")
OWNER_MARK = ".fm-model-picker-daily-owner"
# Every name a promotion creates in the live root carries this prefix or suffix, and the journal
# lists them, so cleanup removes only what this module made and can prove it made.
JOURNAL = ".fm-model-picker-daily.journal"
SCRATCH = ".fm-model-picker-daily.tmp"
NEXT_VERDICT = ".fm-model-picker-daily.next-verdict"
PREV_VERDICT = ".fm-model-picker-daily.prev-verdict"
ASIDE_SUFFIX = ".fm-model-picker-daily-aside"
INSTALLED = ("raw", "projection") + LOOSE_FILES
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


class _Refused(Exception):
    """The promotion stopped before it changed anything under the live root."""


# measured: value=30 date=2026-11-18 host=Mac-Studio margin=26000x (seconds a promotion waits for a reader of the data root to finish; a guarded read of the verdict and six projections held the lock 1.14 ms at worst over 20 runs)
LOCK_WAIT_SECONDS = 30


@contextlib.contextmanager
def _exclusive(root):
    """Hold the data root's promotion lock exclusively. Readers hold it shared (shadow.py
    generation_hold), so no reader's whole operation overlaps a promotion. The kernel drops the
    lock when this process dies. Refuse, with nothing changed, when a reader keeps it too long."""
    fd = os.open(str(root), os.O_RDONLY)
    try:
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        blocked = False
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if not blocked:
                    blocked = True
                    _point("lock-blocked")
                if time.monotonic() >= deadline:
                    raise _Refused(f"a reader held the lock on {root} for {LOCK_WAIT_SECONDS} seconds; nothing was changed") from None
                time.sleep(0.02)
        yield
    finally:
        os.close(fd)


def _write_atomic(path, text):
    tmp = path.with_name(SCRATCH)
    tmp.write_text(text)
    os.replace(tmp, path)


def _copy_atomic(src, dst):
    """Make DST appear whole or not at all."""
    tmp = dst.with_name(SCRATCH)
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def _faults():
    """Fault injection for the tests, honored only when FM_TEST_SEAM=1. FM_MODEL_PICKER_DAILY_FAULT
    holds ';'-separated entries: rename:SRC_REGEX>>DST_REGEX fails a matching rename,
    remove:PATH_REGEX fails the removal of a matching path with an I/O error,
    kill:POINT SIGKILLs this process and fail:POINT raises there (POINT is before-commit or
    after-commit), hold:POINT:ANNOUNCE:RELEASE creates ANNOUNCE and waits there until RELEASE exists,
    mark:POINT:FILE creates FILE there and goes on (lock-blocked is reached when a reader's shared
    lock refused the promotion's first exclusive attempt)."""
    if os.environ.get("FM_TEST_SEAM") != "1":
        return []
    return [e for e in os.environ.get("FM_MODEL_PICKER_DAILY_FAULT", "").split(";") if e]


def _point(name):
    for entry in _faults():
        kind, _, rest = entry.partition(":")
        if kind == "kill" and rest == name:
            os.kill(os.getpid(), signal.SIGKILL)
        if kind == "fail" and rest == name:
            raise OSError(errno.EIO, f"injected failure at {name}")
        if kind == "mark" and rest.startswith(name + ":"):
            Path(rest.split(":", 1)[1]).write_text("")
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
    os.replace(src, dst)


def _aside(path):
    return path.with_name(path.name + ASIDE_SUFFIX)


def _remove(path):
    for entry in _faults():
        kind, _, rest = entry.partition(":")
        if kind == "remove" and re.search(rest, str(path)):
            raise OSError(errno.EIO, "injected remove fault", str(path))
    if os.path.lexists(path):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()


def _install(new, cur, had):
    """Put NEW where CUR is, moving CUR aside first."""
    if had:
        _rename(cur, _aside(cur))
    _rename(new, cur)


def _undo_install(cur, had):
    """Put CUR back as it was. It reads the state, so it is safe to repeat and to run after a kill."""
    aside = _aside(cur)
    if had:
        if os.path.lexists(aside):
            _remove(cur)
            _rename(aside, cur)
    else:
        _remove(cur)


def _merge_matrix(live_db, staged_db, token, had_db):
    """Replace the benchmark matrix and record TOKEN in one transaction, then commit. The commit
    is the commit point of the promotion. An existing live file is opened without any schema
    write outside the transaction, so a rollback or a kill leaves its bytes as they were."""
    from . import aadb

    conn = aadb.connect(live_db) if had_db else aadb.open_db(live_db)
    try:
        conn.isolation_level = None
        conn.execute("ATTACH DATABASE ? AS staged", (str(staged_db),))
        conn.execute("BEGIN IMMEDIATE")
        try:
            have = conn.execute("PRAGMA user_version").fetchone()[0]
            if have > aadb.SCHEMA_VERSION:
                raise RuntimeError(f"database schema {have} is newer than this code ({aadb.SCHEMA_VERSION})")
            for stmt in aadb.DDL_MATRIX:
                conn.execute(stmt)
            if have < aadb.SCHEMA_VERSION:
                conn.execute(f"PRAGMA user_version={aadb.SCHEMA_VERSION}")
            for table in ("observations", "reconcile_runs", "metrics", "models"):
                conn.execute(f"DELETE FROM main.{table}")
            for table in MATRIX_TABLES:
                columns = [r[1] for r in conn.execute(f"PRAGMA main.table_info({table})")]
                staged = {r[1] for r in conn.execute(f"PRAGMA staged.table_info({table})")}
                cols = ", ".join(c for c in columns if c in staged)
                conn.execute(f"INSERT INTO main.{table} ({cols}) SELECT {cols} FROM staged.{table}")
            conn.execute("CREATE TABLE IF NOT EXISTS daily_promotion (token TEXT NOT NULL)")
            conn.execute("DELETE FROM daily_promotion")
            conn.execute("INSERT INTO daily_promotion (token) VALUES (?)", (token,))
            _point("before-commit")
            conn.execute("COMMIT")
        except BaseException:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
            raise
    finally:
        conn.close()


def _committed(root, token):
    """Did the database commit of this promotion happen? Opening the file also plays back a hot
    journal a killed promotion left, so the answer is the state a rollback or a commit settled."""
    from . import aadb

    db = root / "aa.sqlite"
    if not db.exists():
        return False
    conn = aadb.connect(db)
    try:
        try:
            return conn.execute("SELECT 1 FROM daily_promotion WHERE token = ?", (token,)).fetchone() is not None
        except sqlite3.OperationalError as error:
            if "no such table" in str(error):
                return False
            raise
    finally:
        conn.close()


def _read_journal(root):
    """The journal, or None when there is none; raises ValueError for one this module did not write."""
    try:
        doc = json.loads((root / JOURNAL).read_text())
    except FileNotFoundError:
        return None
    items = doc.get("items") if isinstance(doc, dict) else None
    if (not isinstance(items, list) or not isinstance(doc.get("token"), str)
            or not all(isinstance(i, dict) and i.get("name") in INSTALLED and isinstance(i.get("had"), bool) for i in items)
            or not isinstance(doc.get("had_db"), bool) or not isinstance(doc.get("had_verdict"), bool)):
        raise ValueError("the promotion journal is not one this module wrote")
    return doc


def _attempt(problems, what, step):
    try:
        step()
    except BaseException as error:
        if isinstance(error, KeyboardInterrupt):
            raise
        problems.append(f"{what}: {error}")


def _settle(root):
    """Finish or undo a promotion from its journal. Returns (word, detail). Every step reads the
    state and is safe to repeat, so the in-process failure path, a killed promotion and the start
    of the next run all use it. The database token decides: present means the commit happened and
    the new generation is rolled forward, absent means the old one is put back."""
    try:
        journal = _read_journal(root)
    except (OSError, ValueError) as error:
        return "restore-incomplete", f"cannot read the promotion journal ({error}); live verdict left as it is"
    if journal is None:
        _attempt([], "remove the scratch file", lambda: _remove(root / SCRATCH))
        return "unchanged", "no promotion to settle"
    try:
        committed = _committed(root, journal["token"])
    except (OSError, sqlite3.Error) as error:
        return "restore-incomplete", f"cannot tell whether the database commit happened ({error}); live verdict left UNTRUSTED"
    verdict = root / "verdict.json"
    problems = []
    if committed:
        if os.path.lexists(root / NEXT_VERDICT):
            _attempt(problems, "publish the new verdict", lambda: _rename(root / NEXT_VERDICT, verdict))
        if problems:
            return "completion-incomplete", ("new snapshot committed but its verdict could not be published, live verdict left UNTRUSTED until the next run; "
                                             + "; ".join(problems))
        for item in journal["items"]:
            _attempt(problems, f"remove the old {item['name']}", lambda i=item: _remove(_aside(root / i["name"])))
        _attempt(problems, "remove the kept verdict", lambda: _remove(root / PREV_VERDICT))
        _attempt(problems, "remove the scratch file", lambda: _remove(root / SCRATCH))
        if not problems:
            _attempt(problems, "remove the journal", lambda: _remove(root / JOURNAL))
        if problems:
            return "cleanup-incomplete", ("new snapshot is live and trusted; cleanup left files behind that the next run removes before it collects: "
                                          + "; ".join(problems))
        return "completed", "new snapshot installed"
    for item in reversed(journal["items"]):
        _attempt(problems, f"put back {item['name']}", lambda i=item: _undo_install(root / i["name"], i["had"]))
    if not journal["had_db"]:
        for suffix in ("", "-journal", "-wal", "-shm"):
            _attempt(problems, "remove the new aa.sqlite", lambda s=suffix: _remove(root / f"aa.sqlite{s}"))
    marker_in_place = verdict.is_file() and verdict.read_bytes() == UNTRUSTED_VERDICT.encode()
    if not problems and marker_in_place:
        if journal["had_verdict"]:
            _attempt(problems, "restore the previous verdict", lambda: _rename(root / PREV_VERDICT, verdict))
        else:
            _attempt(problems, "remove the marker", lambda: _remove(verdict))
    if problems:
        return "restore-incomplete", "RESTORE INCOMPLETE, live verdict left UNTRUSTED; " + "; ".join(problems)
    for name in (NEXT_VERDICT, PREV_VERDICT, SCRATCH, JOURNAL):
        _attempt(problems, f"remove {name}", lambda n=name: _remove(root / n))
    return "restored", "previous snapshot restored"


def _promote_locked(root, dest):
    verdict, live_db = root / "verdict.json", root / "aa.sqlite"
    names = [n for n in INSTALLED if (dest / n).exists()]
    owned = [root / JOURNAL, root / SCRATCH, root / NEXT_VERDICT, root / PREV_VERDICT] + [_aside(root / n) for n in names]
    busy = [p.name for p in owned if os.path.lexists(p)]
    if busy:
        raise _Refused("files this module names are already in the data root, so nothing was changed: " + ", ".join(busy))
    token = uuid.uuid4().hex
    journal = {"token": token, "had_db": live_db.exists(), "had_verdict": verdict.exists(),
               "items": [{"name": n, "had": os.path.lexists(root / n)} for n in names]}
    try:
        _write_atomic(root / JOURNAL, json.dumps(journal))
    except OSError as failed:
        _attempt([], "remove the scratch file", lambda: _remove(root / SCRATCH))
        raise _Refused(f"could not write the promotion journal ({failed}); nothing was changed") from failed
    error = None
    try:
        _copy_atomic(dest / "verdict.json", root / NEXT_VERDICT)
        if journal["had_verdict"]:
            _copy_atomic(verdict, root / PREV_VERDICT)
        _write_atomic(verdict, UNTRUSTED_VERDICT)
        for item in journal["items"]:
            _install(dest / item["name"], root / item["name"], item["had"])
        _merge_matrix(live_db, dest / "aa.sqlite", token, journal["had_db"])
        _point("after-commit")
    except BaseException as caught:
        error = caught
    word, detail = _settle(root)
    if error is not None and word != "completed":
        detail = f"{detail}; promotion failed: {error}"
    if isinstance(error, KeyboardInterrupt):
        raise error
    return word, detail


def promote(root, dest):
    """Install the staged generation as the live one. The commit point is one database
    transaction that replaces the matrix and records this promotion's token; a journal in the
    root, written first, names everything the promotion touches. Order: journal, the staged
    verdict kept as NEXT_VERDICT, the previous verdict kept as PREV_VERDICT, the UNTRUSTED marker,
    each install (the old path moves aside, the staged one takes its place), the commit. After
    the commit one rename publishes the new verdict and the old copies and the journal go.
    Whatever stops it, _settle finishes it from the journal: before the commit the old
    generation returns byte for byte and the old verdict returns only when every step worked,
    after it the new generation is completed. A reader sees the old generation, then UNTRUSTED,
    then the new one, and holds the lock shared for its whole read, so none spans the window.
    Returns (word, detail): completed, cleanup-incomplete (committed and published, files left behind),
    completion-incomplete (committed, verdict not published), restored, restore-incomplete, refused."""
    root, dest = Path(root), Path(dest)
    if not (dest / "aa.sqlite").is_file() or not (dest / "verdict.json").is_file():
        return "refused", f"{dest} holds no aa.sqlite and verdict.json from a finished run; nothing was changed"
    root.mkdir(parents=True, exist_ok=True)
    try:
        with _exclusive(root):
            return _promote_locked(root, dest)
    except _Refused as refused:
        return "refused", str(refused)


def recover(root):
    """Settle a promotion a stopped runner left in ROOT. Returns (word, detail); `unchanged` means there was none."""
    root = Path(root)
    if not root.is_dir():
        return "unchanged", "no data root"
    if not os.path.lexists(root / JOURNAL) and not os.path.lexists(root / SCRATCH):
        return "unchanged", "no promotion to settle"
    try:
        with _exclusive(root):
            return _settle(root)
    except _Refused as refused:
        return "refused", str(refused)


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
        raise SystemExit("usage: daily.py root | stage ROOT DEST PID | discard DEST PID | reap ROOT | promote ROOT DEST | recover ROOT | verdict ROOT | freshness ROOT [--now EPOCH]")
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
    elif verb in ("promote", "recover") and len(rest) == (2 if verb == "promote" else 1):
        word, detail = (promote if verb == "promote" else recover)(*rest)
        print(f"outcome={word}")
        if word not in ("completed", "unchanged"):
            print(detail, file=sys.stderr)
        return 0 if word in ("completed", "unchanged") else 1
    elif verb == "freshness" and len(rest) in (1, 3) and (len(rest) == 1 or rest[1] == "--now"):
        now = int(rest[2]) if len(rest) == 3 else int(time.time())
        for key, value in freshness(rest[0], now).items():
            print(f"{key}={value.replace(chr(10), ' ')}")
    else:
        raise SystemExit("daily.py: invalid arguments")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
