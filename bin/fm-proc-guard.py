#!/usr/bin/env python3
"""
fm-proc-guard.py - Per-user process pile-up detector with a one-shot process census.

The kernel refuses fork() with EAGAIN once the user's process count reaches
kern.maxprocperuid (macOS) or RLIMIT_NPROC (Linux).
A runaway tree can sit just under that cap for minutes while every other tree of
the same user loses forks, and nothing in the fleet records what the tree was.
This guard samples that one count cheaply and writes ONE census when it stays high.

Commands (run --help on each for flags):
  check    One reading: count, limit, percent, and an OK/WARNING/CRITICAL/UNKNOWN verdict.
  census   Write one process census to <state>/proc-census.<epoch>.<pid>.json now.
  watch    Sample once per --interval; when the count stays above --warn-pct of the
           limit for more than --hold seconds, write one census, print a result
           document (see below), and exit.
           An open episode (state/proc-guard.episode) makes the next watch wait,
           silently, until the count has stayed at or below --clear-pct for --hold
           seconds, so one pile-up yields one census however often watch restarts.

Thresholds (named here so a reader can audit every verdict):
  --warn-pct  60   percent of the limit above which the count is a pile-up
  --crit-pct  90   check only: percent at which forks are about to fail for everyone
  --clear-pct 50   percent at or below which an open episode closes
  --hold       5   seconds the count must stay above warn-pct (more than, not equal)

Why a library call and not ps(1): the sampler must keep working at the cap.
A sampler that forks cannot start its probe once the cap is reached, which is the
moment it matters (measured: ps fails with EAGAIN, the library call still reads).
macOS reads proc_listpids(PROC_UID_ONLY) and proc_pidinfo through libproc, and
argv through the kern.procargs2 sysctl; Linux reads /proc.
Neither path forks, execs, or writes to anything it measures.

Count semantics, measured:
  macOS  the count includes zombies, as the kernel's per-user count does, and runs
         about 9 above it (long-lived root-forked processes that later became this
         uid are listed but were charged to root), so the guard warns slightly early.
  Linux  RLIMIT_NPROC bounds threads, so the count is the sum of the user's threads.

Result document printed by watch (the process-event runner stores it verbatim):
  proc-guard: <source-id>
  status: pileup | error | idle
  count/limit/threshold/held_seconds/census/summary/sampler_* lines; a census that
  could not be built or saved is reported as a census_error line instead, because the
  pile-up itself must still be reported
  A pileup result is printed while the user still has headroom (the threshold sits
  well below the cap), so the process that stores it can still fork.

Invariants:
  - Read-only diagnostics: never signals, kills, or changes any process.
    The only writes are the census, its pruning, and the episode record under --state-dir.
  - Fail-open: an unreadable count skips that sample; thirty skipped samples in a row
    make watch report status: error once instead of looping.
  - Census argv text is captured only for each deepest chain's leaf and three members of
    its longest run, and for the oldest and the newest processes, each cut to 160
    characters; the file is mode 0600.
"""

import argparse
import ctypes
import json
import os
import resource
import sys
import tempfile
import time
from collections import Counter, namedtuple
from datetime import datetime, timezone

NAME = "fm-proc-guard"
CENSUS_PREFIX = "proc-census."
EPISODE_FILE = "proc-guard.episode"
ARGV_LIMIT = 160
CENSUS_TOP = 5
CENSUS_KEEP = 20
MAX_SKIPPED_SAMPLES = 30

Proc = namedtuple("Proc", "pid ppid command state start threads")


def utc(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class ReadError(Exception):
    pass


class Darwin:
    """libproc reads; no fork, no exec."""

    name = "darwin"
    PROC_UID_ONLY = 4
    PROC_PIDTBSDINFO = 3
    CTL_KERN = 1
    KERN_PROCARGS2 = 49
    SZOMB = 5

    class BsdInfo(ctypes.Structure):
        _fields_ = [
            ("flags", ctypes.c_uint32), ("status", ctypes.c_uint32),
            ("xstatus", ctypes.c_uint32), ("pid", ctypes.c_uint32),
            ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
            ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32),
            ("rgid", ctypes.c_uint32), ("svuid", ctypes.c_uint32),
            ("svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
            ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
            ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32),
            ("pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
            ("e_tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32),
            ("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64),
        ]

    def __init__(self):
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.proc_pidinfo.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        self.libc.proc_listpids.argtypes = [
            ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
        if ctypes.sizeof(self.BsdInfo) != 136:
            raise ReadError("proc_bsdinfo layout differs from the expected 136 bytes")
        self.uid = os.getuid()
        slots = (self._sysctl_int(b"kern.maxproc") or 16000) + 4096
        self.pid_buffer = (ctypes.c_int * slots)()
        argmax = self._sysctl_int(b"kern.argmax") or 262144
        self.args_buffer = ctypes.create_string_buffer(min(argmax, 1 << 20))

    def _sysctl_int(self, name):
        value = ctypes.c_int(0)
        size = ctypes.c_size_t(ctypes.sizeof(value))
        if self.libc.sysctlbyname(name, ctypes.byref(value), ctypes.byref(size), None, 0) != 0:
            return None
        return value.value

    def limit(self):
        value = self._sysctl_int(b"kern.maxprocperuid")
        if not value:
            return None, "kern.maxprocperuid unreadable"
        return value, "kern.maxprocperuid"

    def pids(self):
        size = self.libc.proc_listpids(
            self.PROC_UID_ONLY, self.uid, self.pid_buffer, ctypes.sizeof(self.pid_buffer))
        if size <= 0:
            raise ReadError("proc_listpids returned %d" % size)
        return list(self.pid_buffer[: size // 4])

    def count(self):
        return len(self.pids())

    def info(self, pid):
        info = self.BsdInfo()
        got = self.libc.proc_pidinfo(
            pid, self.PROC_PIDTBSDINFO, 0, ctypes.byref(info), ctypes.sizeof(info))
        if got != ctypes.sizeof(info):
            return None
        command = (info.name or info.comm).decode("utf-8", "replace")
        state = "Z" if info.status == self.SZOMB else "R"
        return Proc(pid, info.ppid, command, state,
                    info.start_sec + info.start_usec / 1e6, 1)

    def argv(self, pid):
        mib = (ctypes.c_int * 3)(self.CTL_KERN, self.KERN_PROCARGS2, pid)
        size = ctypes.c_size_t(ctypes.sizeof(self.args_buffer))
        if self.libc.sysctl(mib, 3, self.args_buffer, ctypes.byref(size), None, 0) != 0:
            return ""
        raw = self.args_buffer.raw[: size.value]
        if len(raw) < 4:
            return ""
        argc = int.from_bytes(raw[:4], sys.byteorder)
        body = raw[4:]
        end = body.find(b"\0")
        if end < 0:
            return ""
        rest = body[end:].lstrip(b"\0")
        return " ".join(
            part.decode("utf-8", "replace") for part in rest.split(b"\0")[:argc])


class Linux:
    """/proc reads; no fork, no exec."""

    name = "linux"

    def __init__(self):
        self.uid = os.getuid()
        self.ticks = os.sysconf("SC_CLK_TCK")
        self.boot = 0.0
        try:
            with open("/proc/stat") as stat:
                for line in stat:
                    if line.startswith("btime "):
                        self.boot = float(line.split()[1])
        except OSError:
            pass

    def limit(self):
        soft = resource.getrlimit(resource.RLIMIT_NPROC)[0]
        if soft != resource.RLIM_INFINITY:
            return soft, "RLIMIT_NPROC"
        try:
            with open("/proc/sys/kernel/threads-max") as handle:
                return int(handle.read()), "kernel.threads-max (RLIMIT_NPROC is unlimited)"
        except (OSError, ValueError):
            return None, "no per-user process limit readable"

    def pids(self):
        found = []
        try:
            with os.scandir("/proc") as entries:
                for entry in entries:
                    if not entry.name.isdigit():
                        continue
                    try:
                        if entry.stat().st_uid == self.uid:
                            found.append(int(entry.name))
                    except OSError:
                        continue
        except OSError as error:
            raise ReadError("/proc unreadable: %s" % error)
        return found

    def _stat(self, pid):
        try:
            with open("/proc/%d/stat" % pid) as handle:
                data = handle.read()
        except OSError:
            return None
        left, right = data.find("("), data.rfind(")")
        if left < 0 or right < left:
            return None
        rest = data[right + 2:].split()
        if len(rest) < 20:
            return None
        return data[left + 1:right], rest

    def count(self):
        total = 0
        for pid in self.pids():
            parsed = self._stat(pid)
            if parsed:
                total += int(parsed[1][17])
        return total

    def info(self, pid):
        parsed = self._stat(pid)
        if not parsed:
            return None
        command, rest = parsed
        return Proc(pid, int(rest[1]), command, rest[0],
                    self.boot + int(rest[19]) / self.ticks, int(rest[17]))

    def argv(self, pid):
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                raw = handle.read()
        except OSError:
            return ""
        return " ".join(part.decode("utf-8", "replace") for part in raw.split(b"\0") if part)


def open_source():
    if sys.platform == "darwin":
        return Darwin()
    if sys.platform.startswith("linux"):
        return Linux()
    raise ReadError("unsupported platform: %s" % sys.platform)


def cut(text):
    text = " ".join(text.split())
    return text if len(text) <= ARGV_LIMIT else text[: ARGV_LIMIT - 3] + "..."


def segments_text(segments, repeats):
    parts = []
    for command, run, _first in segments:
        if run > 1:
            parts.append("%s(x%d)" % (command, run) if repeats else command + "+")
        else:
            parts.append(command)
    return " > ".join(parts)


def build_census(source, count, limit, limit_source, threshold, trigger):
    """Walks every process of the user once and summarizes the pile."""
    started, cpu_started = time.monotonic(), time.process_time()
    procs, unreadable = {}, 0
    for pid in source.pids():
        proc = source.info(pid)
        if proc is None:
            unreadable += 1
        else:
            procs[pid] = proc
    outside = {}

    def lookup(pid):
        if pid in procs:
            return procs[pid]
        if pid not in outside:
            outside[pid] = source.info(pid)
        return outside[pid]

    memo = {}

    def resolve(pid):
        path, seen, current = [], set(), pid
        while current not in memo and current not in seen:
            seen.add(current)
            proc = lookup(current)
            if proc is None:
                break
            path.append(proc)
            if proc.ppid <= 0 or proc.ppid == current:
                break
            current = proc.ppid
        depth, segments = memo.get(current, (0, ()))
        for proc in reversed(path):
            depth += 1
            if segments and segments[-1][0] == proc.command:
                last = segments[-1]
                segments = segments[:-1] + ((last[0], last[1] + 1, last[2]),)
            else:
                segments = segments + ((proc.command, 1, proc.pid),)
            memo[proc.pid] = (depth, segments)
        return memo[pid]

    by_command = Counter(proc.command for proc in procs.values())
    by_chain = Counter()
    has_child = {proc.ppid for proc in procs.values()}
    leaves = []
    for pid, proc in procs.items():
        depth, segments = resolve(pid)
        by_chain[segments_text(segments, repeats=False)] += 1
        if pid not in has_child:
            leaves.append((depth, pid))
    leaves.sort(key=lambda item: (-item[0], item[1]))

    def who(pid):
        proc = procs.get(pid) or lookup(pid)
        return {"pid": pid, "command": proc.command if proc else "",
                "argv": cut(source.argv(pid)) if proc and proc.state != "Z" else ""}

    def chain_pids(pid):
        """Root-first pids of one process's ancestry."""
        found, seen, current = [], set(), pid
        while current and current not in seen:
            proc = lookup(current)
            if proc is None:
                break
            seen.add(current)
            found.append(current)
            if proc.ppid <= 0 or proc.ppid == current:
                break
            current = proc.ppid
        found.reverse()
        return found

    deepest = []
    for depth, pid in leaves[:CENSUS_TOP]:
        _, segments = memo[pid]
        # The longest run of one command (shallowest on a tie) is the pile itself; its
        # first, middle, and last members show what each level was running, because the
        # first member can be an unrelated shell that merely started the recursion.
        longest = max(range(len(segments)), key=lambda i: (segments[i][1], -i))
        first = sum(segment[1] for segment in segments[:longest])
        members = chain_pids(pid)[first:first + segments[longest][1]]
        samples = []
        for member in (members[:1] + members[len(members) // 2:len(members) // 2 + 1] + members[-1:]):
            if member not in [entry["pid"] for entry in samples]:
                samples.append(who(member))
        deepest.append({
            "depth": depth,
            "chain": segments_text(segments, repeats=True),
            "leaf": who(pid),
            "run_length": segments[longest][1],
            "run_samples": samples,
        })

    now = time.time()
    ordered = sorted(procs.values(), key=lambda proc: (proc.start, proc.pid))

    def aged(proc):
        entry = who(proc.pid)
        entry.update(ppid=proc.ppid, started=utc(proc.start),
                     age_seconds=max(0, int(now - proc.start)))
        return entry

    oldest = [aged(proc) for proc in ordered[:CENSUS_TOP]]
    newest = [aged(proc) for proc in reversed(ordered[-CENSUS_TOP:])]
    top_command, top_count = by_command.most_common(1)[0] if by_command else ("", 0)
    deepest_depth = deepest[0]["depth"] if deepest else 0
    return {
        "name": NAME,
        "schema": 1,
        "captured_at": utc(now),
        "epoch": int(now),
        "platform": source.name,
        "uid": source.uid,
        "user_process_count": count,
        "limit": limit,
        "limit_source": limit_source,
        "threshold": threshold,
        "percent_of_limit": round(100.0 * count / limit, 1) if limit else None,
        "trigger": trigger,
        "census_processes": len(procs),
        "census_unreadable": unreadable,
        "census_zombies": sum(1 for proc in procs.values() if proc.state == "Z"),
        "census_cost_ms": round((time.monotonic() - started) * 1000, 1),
        "census_cpu_ms": round((time.process_time() - cpu_started) * 1000, 1),
        "summary": "%d of %s processes; most common command %s x%d; deepest ancestry %d"
                   % (count, limit if limit else "?", top_command or "?", top_count,
                      deepest_depth),
        "by_command": [{"command": c, "count": n} for c, n in
                       sorted(by_command.items(), key=lambda item: (-item[1], item[0]))],
        "by_parent_chain": [{"chain": c, "count": n} for c, n in
                            sorted(by_chain.items(), key=lambda item: (-item[1], item[0]))],
        "deepest_chains": deepest,
        "oldest": oldest,
        "newest": newest,
    }


def write_census(state_dir, census, keep=CENSUS_KEEP):
    os.makedirs(state_dir, exist_ok=True)
    final = os.path.join(
        state_dir, "%s%d.%d.json" % (CENSUS_PREFIX, census["epoch"], os.getpid()))
    handle, temporary = tempfile.mkstemp(prefix=".proc-census-", dir=state_dir)
    try:
        with os.fdopen(handle, "w") as out:
            json.dump(census, out, indent=1)
            out.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, final)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
    kept = sorted(
        (name for name in os.listdir(state_dir)
         if name.startswith(CENSUS_PREFIX) and name.endswith(".json")),
        key=lambda name: (os.path.getmtime(os.path.join(state_dir, name)), name))
    for stale in kept[: max(0, len(kept) - keep)]:
        try:
            os.unlink(os.path.join(state_dir, stale))
        except OSError:
            pass
    return final


def default_state_dir():
    if os.environ.get("FM_STATE_OVERRIDE"):
        return os.environ["FM_STATE_OVERRIDE"]
    root = os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or \
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(root, "state")


def resolve_limit(source, override):
    if override:
        return override, "--limit"
    return source.limit()


def cmd_check(args):
    report = {"name": NAME, "checked_at": utc(time.time())}
    try:
        source = open_source()
        limit, limit_source = resolve_limit(source, args.limit)
        started = time.process_time()
        count = source.count()
        cost = round((time.process_time() - started) * 1000, 3)
    except (ReadError, OSError) as error:
        report.update(status="UNKNOWN", reason=str(error),
                      recommendation="Count unreadable; the caller should continue unchanged.")
        count = limit = None
    else:
        report.update(count=count, limit=limit, limit_source=limit_source, read_cpu_ms=cost)
        if not limit:
            report.update(status="UNKNOWN", reason=limit_source,
                          recommendation="No limit to compare against; the caller should continue unchanged.")
        else:
            pct = round(100.0 * count / limit, 1)
            report["percent_of_limit"] = pct
            if count > limit * args.crit_pct / 100.0:
                report.update(status="CRITICAL", recommendation=(
                    "The user process count is near the cap; forks fail for every process "
                    "of this user, which can explain worker silence while it holds."))
            elif count > limit * args.warn_pct / 100.0:
                report.update(status="WARNING", recommendation=(
                    "The user process count is high but forks still work; run the census "
                    "to see what is piling up."))
            else:
                report.update(status="OK", recommendation=(
                    "The user process count is within thresholds; the caller should continue unchanged."))
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("%s - %s" % (NAME, report["checked_at"]))
        if count is None or not limit:
            print("  - Count: unavailable (%s)" % report.get("reason", "unknown"))
        else:
            print("  - Count: %d of %d (%.1f%%) from %s" % (
                count, limit, report["percent_of_limit"], limit_source))
        print("  - Status: %s" % report["status"])
        print("  - Recommendation: %s" % report["recommendation"])
    if args.check and report["status"] in ("WARNING", "CRITICAL"):
        sys.exit(1)


def cmd_census(args):
    try:
        source = open_source()
        limit, limit_source = resolve_limit(source, args.limit)
        count = source.count()
    except (ReadError, OSError) as error:
        print("error: %s" % error, file=sys.stderr)
        sys.exit(1)
    threshold = limit * args.warn_pct / 100.0 if limit else None
    census = build_census(source, count, limit, limit_source, threshold, {"reason": "requested"})
    print(write_census(args.state_dir or default_state_dir(), census, args.keep))


def read_episode(path):
    try:
        with open(path) as handle:
            record = json.load(handle)
        return record if isinstance(record, dict) else None
    except (OSError, ValueError):
        return None


def result_document(source_id, status, fields):
    lines = ["proc-guard: %s" % source_id, "status: %s" % status]
    lines += ["%s: %s" % (key, value) for key, value in fields]
    return "\n".join(lines) + "\n"


def cmd_watch(args):
    state_dir = args.state_dir or default_state_dir()
    episode = os.path.join(state_dir, EPISODE_FILE)
    sampling_cpu, samples, skipped = 0.0, 0, 0
    try:
        source = open_source()
        limit, limit_source = resolve_limit(source, args.limit)
        if not limit:
            raise ReadError(limit_source)
    except (ReadError, OSError) as error:
        sys.stdout.write(result_document(args.source_id, "error", [("detail", error)]))
        return

    def cost_fields():
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        rss_kb = rss // 1024 if sys.platform == "darwin" else rss
        return [("sampler_samples", samples),
                ("sampler_cpu_ms_per_sample", "%.3f" % (1000.0 * sampling_cpu / samples) if samples else "0"),
                ("sampler_peak_rss_kb", rss_kb)]

    threshold = limit * args.warn_pct / 100.0
    clear = limit * args.clear_pct / 100.0
    armed = read_episode(episode) is None
    over_since = quiet_since = None
    deadline = time.monotonic() + args.duration if args.duration else None
    next_tick = time.monotonic()
    while True:
        now = time.monotonic()
        if deadline is not None and now >= deadline:
            sys.stdout.write(result_document(args.source_id, "idle", [
                ("armed", "yes" if armed else "no")] + cost_fields()))
            return
        try:
            cpu_before = time.process_time()
            count = source.count()
            sampling_cpu += time.process_time() - cpu_before
            samples, skipped = samples + 1, 0
        except (ReadError, OSError) as error:
            skipped += 1
            if skipped >= MAX_SKIPPED_SAMPLES:
                sys.stdout.write(result_document(args.source_id, "error", [
                    ("detail", "%d unreadable samples in a row: %s" % (skipped, error))]))
                return
            count = None
        if count is not None and not armed:
            if count <= clear:
                quiet_since = quiet_since if quiet_since is not None else now
                if now - quiet_since > args.hold:
                    try:
                        os.unlink(episode)
                    except OSError:
                        pass
                    armed, quiet_since = True, None
            else:
                quiet_since = None
        elif count is not None:
            if count > threshold:
                over_since = over_since if over_since is not None else now
                if now - over_since > args.hold:
                    held = now - over_since
                    trigger = {"reason": "count above threshold",
                               "held_seconds": round(held, 1), "hold_seconds": args.hold}
                    # A census that cannot be built or saved must not hide the pile-up itself.
                    path, summary, problem = None, "census unavailable", None
                    try:
                        census = build_census(source, count, limit, limit_source, threshold, trigger)
                        summary = census["summary"]
                        path = write_census(state_dir, census, args.keep)
                        with open(episode, "w") as handle:
                            json.dump({"opened": census["epoch"], "census": path, "count": count}, handle)
                    except Exception as error:  # noqa: BLE001 - report, never crash the detector
                        problem = "%s: %s" % (type(error).__name__, error)
                    fields = [("count", count), ("limit", limit), ("threshold", int(threshold)),
                              ("held_seconds", "%.2f" % held)]
                    fields += [("census", path)] if path else []
                    fields += [("census_error", problem)] if problem else []
                    sys.stdout.write(result_document(args.source_id, "pileup",
                                                     fields + [("summary", summary)] + cost_fields()))
                    return
            else:
                over_since = None
        next_tick += args.interval
        pause = next_tick - time.monotonic()
        if pause < 0:
            next_tick = time.monotonic()
            pause = 0
        time.sleep(pause)


def positive(text):
    value = float(text)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def percent(text):
    value = float(text)
    if not 0 < value <= 100:
        raise argparse.ArgumentTypeError("must be above 0 and at most 100")
    return value


def main():
    sys.stdout.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    def common(sub):
        sub.add_argument("--limit", type=int, default=0,
                         help="override the per-user process limit (default: read it from the host)")
        sub.add_argument("--warn-pct", type=percent, default=60.0,
                         help="percent of the limit above which the count is a pile-up (default: %(default)s)")

    check = commands.add_parser("check", help="one reading and verdict")
    common(check)
    check.add_argument("--crit-pct", type=percent, default=90.0,
                       help="percent of the limit at which the verdict is CRITICAL (default: %(default)s)")
    check.add_argument("--json", action="store_true", help="print one JSON object")
    check.add_argument("--check", action="store_true",
                       help="exit 1 for WARNING or CRITICAL, 0 otherwise (UNKNOWN fails open)")
    check.set_defaults(run=cmd_check)

    census = commands.add_parser("census", help="write one census now and print its path")
    common(census)
    census.add_argument("--state-dir", help="where the census goes (default: the home's state/)")
    census.add_argument("--keep", type=int, default=CENSUS_KEEP,
                        help="census files to keep, newest first (default: %(default)s)")
    census.set_defaults(run=cmd_census)

    watch = commands.add_parser("watch", help="sample until a pile-up, write one census, exit")
    common(watch)
    watch.add_argument("--state-dir", help="where the census and episode record go (default: the home's state/)")
    watch.add_argument("--interval", type=positive, default=1.0,
                       help="seconds between samples (default: %(default)s)")
    watch.add_argument("--hold", type=positive, default=5.0,
                       help="seconds the count must stay above the threshold, strictly more than (default: %(default)s)")
    watch.add_argument("--clear-pct", type=percent, default=50.0,
                       help="percent at or below which an open episode closes (default: %(default)s)")
    watch.add_argument("--keep", type=int, default=CENSUS_KEEP,
                       help="census files to keep, newest first (default: %(default)s)")
    watch.add_argument("--duration", type=float, default=0.0,
                       help="stop with status: idle after this many seconds; 0 runs until a pile-up (default: %(default)s)")
    watch.add_argument("--source-id", default="proc-guard",
                       help="source id echoed in the result document (default: %(default)s)")
    watch.set_defaults(run=cmd_watch)

    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
