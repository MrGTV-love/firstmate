#!/usr/bin/env python3
"""Read process facts on macOS without the setuid ps that sandbox-exec refuses.

Usage: fm-proc-info.py count-uid UID | ppid PID | pgid PID | comm PID | args PID |
       lstart PID | identity PID | cpu-tree PID | mem-tree PID | rss-tree PID |
       table FIELDS | memory

memory prints a JSON RSS census with PID, PPID, kernel name, start time,
resident bytes (null when unreadable), and fleet attribution only.
Paired task/inbox markers or a kernel cwd within FM_MEMORY_FLEET_ROOT prove
attribution; names alone never do. It prints no arguments, environment or cwd.

count-uid prints how many processes have real user id UID. ppid and pgid print
a process's parent and process group, comm its argv[0] and args its argv joined
by spaces, as macOS `LC_ALL=C ps -o comm=` and `LC_ALL=C ps -o args=` do, each
argv word escaped by vis(3) the way ps escapes it, and lstart its start time as
`LC_ALL=C ps -o lstart=` with runs of spaces collapsed. identity prints the
exact bytes `COLUMNS=10000 LC_ALL=C ps -p PID -o lstart= -o command=` prints
for a process of this user, so such an identity recorded through either source
compares equal. Another user's argv cannot be read without setuid, so for such
a process the command is the kernel's short name in parentheses where ps prints
the full command, and the two identities differ. table prints one
line per process with the comma-separated FIELDS among pid, ppid, pgid, stat,
lstart and command, like `ps -axo <field>=,...`; stat carries the state letters
macOS ps derives from the kernel (Z zombie, T stopped, R with a running thread,
else S) and E for a process that is exiting. cpu-tree prints the
whole centiseconds of CPU used by PID and its live descendants, including their
reaped children, as macOS `ps -S` counts them. mem-tree keeps running and
answers each line read on stdin with one line, `<resident> <footprint>`: the
whole KiB of resident memory and of physical footprint (which also counts
compressed pages) held right now by PID and its live descendants in PID's
process group, reading only that group's processes and summed from libproc's
ri_resident_size and ri_phys_footprint; it prints `-` for a sample that cannot
be read and exits at the end of stdin. rss-tree is the strict streaming reader
for fm-proc-budget.sh: each input line requests a JSON object with rss_kib (the
larger of resident memory and footprint), members (PID, kernel start seconds,
kernel start microseconds) and uncounted (PID, short name). The tree is PID's
process group (while PID or its group still holds that id), except the reader
itself, plus PID's descendants in any process group or session; it keeps each
member it has observed by start identity after that member is orphaned. A
process that leaves the group and is orphaned before any read observed it is
never found. A live member whose
memory cannot be read is left out of the sum and listed in uncounted when its
effective user is not this process's; one of this user makes rss_kib null, as
does a read in which no live member was readable. A failed tree read prints
`-`. An empty tree has rss_kib zero. The supervisor uses these identities for
fail-closed cleanup. A reader started inside PID's group by another parent
ignores HUP, INT and TERM; when its stdin ends or its reply cannot be written
(its supervisor died) it sends that group and every member it has seen TERM,
then KILL after at most TERM_SECONDS, and so ends too.
Facts come from sysctl KERN_PROC
and KERN_PROCARGS2, and CPU and memory from libproc's proc_pid_rusage. A process or fact
that cannot be read prints nothing and exits 1, so a caller never mistakes a
failed read for an answer.
"""
import ctypes
import json
import os
import signal
import struct
import subprocess
import sys
import time

CTL_KERN, KERN_PROC, KERN_PROCARGS2 = 1, 14, 49
KERN_PROC_ALL, KERN_PROC_PID, KERN_PROC_PGRP, KERN_PROC_RUID = 0, 1, 2, 6
# struct kinfo_proc on 64-bit Darwin: kp_proc.p_pid, kp_proc.p_comm,
# kp_proc.p_flag, kp_proc.p_stat, kp_eproc.e_ppid and kp_eproc.e_pgid.
KINFO_SIZE, P_START, P_PID, P_COMM, P_FLAG, P_STAT, E_PPID, E_PGID = 648, 0, 40, 243, 32, 36, 560, 564
# kp_eproc.e_ucred.cr_uid: the effective user id.
E_UID = 420
# sys/proc.h P_WEXIT and the p_stat values SSTOP and SZOMB.
P_WEXIT, SSTOP, SZOMB = 0x2000, 4, 5
# proc_pidinfo PROC_PIDTASKINFO: struct proc_taskinfo and its pti_numrunning.
PROC_PIDTASKINFO, TASKINFO_SIZE, PTI_NUMRUNNING = 4, 96, 88
DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
TABLE_FIELDS = ("pid", "ppid", "pgid", "stat", "lstart", "command")
RUSAGE_INFO_V2 = 2
# Sixty real TERM-to-exit waits (sleep, bash, python3): maximum 0.005238 s.
# measured: value=1 date=2026-10-28 host=Mac-Studio.local margin=190
TERM_SECONDS = 1

libc = ctypes.CDLL(None, use_errno=True)


class RusageInfoV2(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
        "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
        "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
        "ri_diskio_byteswritten")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


# Darwin sys/proc_info.h: PROC_PIDVNODEPATHINFO, not a rendered harness signal.
class VinfoStat(ctypes.Structure):
    _fields_ = [("dev", ctypes.c_uint32), ("mode", ctypes.c_uint16), ("nlink", ctypes.c_uint16),
                ("ino", ctypes.c_uint64), ("uid", ctypes.c_uint32), ("gid", ctypes.c_uint32)] + [
                    (name, ctypes.c_int64) for name in ("atime", "atimensec", "mtime", "mtimensec",
                        "ctime", "ctimensec", "birthtime", "birthtimensec", "size", "blocks")] + [
                ("blksize", ctypes.c_int32), ("flags", ctypes.c_uint32), ("gen", ctypes.c_uint32),
                ("rdev", ctypes.c_uint32), ("qspare", ctypes.c_int64 * 2)]


class VnodeInfo(ctypes.Structure):
    _fields_ = [("stat", VinfoStat), ("type", ctypes.c_int), ("pad", ctypes.c_int),
                ("fsid", ctypes.c_int32 * 2)]


class VnodeInfoPath(ctypes.Structure):
    _fields_ = [("info", VnodeInfo), ("path", ctypes.c_char * 1024)]


class VnodePathInfo(ctypes.Structure):
    _fields_ = [("cdir", VnodeInfoPath), ("rdir", VnodeInfoPath)]


def sysctl(*mib):
    names = (ctypes.c_int * len(mib))(*mib)
    size = ctypes.c_size_t(0)
    if libc.sysctl(names, len(mib), None, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno(), "sysctl")
    # The table can grow between the size probe and the read.
    size.value = size.value * 2 + KINFO_SIZE
    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(names, len(mib), buffer, ctypes.byref(size), None, 0):
        raise OSError(ctypes.get_errno(), "sysctl")
    return buffer.raw[:size.value]


def kinfo(pid):
    data = sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)
    if len(data) < KINFO_SIZE or struct.unpack_from("i", data, P_PID)[0] != pid:
        raise LookupError(pid)
    return data[:KINFO_SIZE]


# macOS ps escapes each argv word with vis(3) and VIS_NOSLASH, VIS_NL and
# VIS_TAB; in the C locale every byte above 0x7f gets its own M- escape.
VIS_FLAGS = 0x08 | 0x10 | 0x40
libc.setlocale(0, b"C")


def shown(word):
    out = ctypes.create_string_buffer(len(word) * 4 + 1)
    libc.strvis(out, word, VIS_FLAGS)
    return out.value.decode("ascii")


def argv(pid):
    data = sysctl(CTL_KERN, KERN_PROCARGS2, pid)
    argc = struct.unpack_from("i", data, 0)[0]
    # The executable path and its padding precede argv.
    rest = data[4:].split(b"\0", 1)[1].lstrip(b"\0")
    words = rest.split(b"\0")[:argc]
    if argc < 1 or len(words) < argc:
        raise LookupError(pid)
    return [shown(word) for word in words]


def kinfos(*selector):
    data = sysctl(CTL_KERN, KERN_PROC, *(selector or (KERN_PROC_ALL,)))
    for offset in range(0, len(data) - KINFO_SIZE + 1, KINFO_SIZE):
        yield data[offset:offset + KINFO_SIZE]


def processes(*selector):
    for record in kinfos(*selector):
        yield struct.unpack_from("i", record, P_PID)[0], struct.unpack_from("i", record, E_PPID)[0]


def lstart(record, padded=False):
    moment = time.localtime(struct.unpack_from("q", record, P_START)[0])
    day = f"{moment.tm_mday:2d}" if padded else str(moment.tm_mday)
    return f"{DAYS[moment.tm_wday]} {MONTHS[moment.tm_mon - 1]} {day} {time.strftime('%H:%M:%S', moment)} {moment.tm_year}"


def command_of(record):
    pid = struct.unpack_from("i", record, P_PID)[0]
    try:
        return " ".join(argv(pid))
    except (OSError, LookupError, struct.error, IndexError):
        return "(" + shown(record[P_COMM:P_COMM + 17].split(b"\0", 1)[0]) + ")"


def state(record):
    if record[P_STAT] == SZOMB:
        return "Z"
    pid = struct.unpack_from("i", record, P_PID)[0]
    info = ctypes.create_string_buffer(TASKINFO_SIZE)
    running = (libc.proc_pidinfo(pid, PROC_PIDTASKINFO, ctypes.c_uint64(0), info, TASKINFO_SIZE) == TASKINFO_SIZE
               and struct.unpack_from("i", info.raw, PTI_NUMRUNNING)[0] > 0)
    letter = "T" if record[P_STAT] == SSTOP else "R" if running else "S"
    return letter + ("E" if struct.unpack_from("i", record, P_FLAG)[0] & P_WEXIT else "")


def table(fields):
    readers = {"pid": lambda r: struct.unpack_from("i", r, P_PID)[0], "ppid": lambda r: struct.unpack_from("i", r, E_PPID)[0],
               "pgid": lambda r: struct.unpack_from("i", r, E_PGID)[0], "stat": state, "lstart": lstart, "command": command_of}
    return "\n".join(" ".join(str(readers[field](record)) for field in fields) for record in kinfos())


def cpu_ticks(pid):
    usage = RusageInfoV2()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V2, ctypes.byref(usage)):
        raise LookupError(pid)
    return usage.ri_user_time + usage.ri_system_time + usage.ri_child_user_time + usage.ri_child_system_time


def cpu_tree(root):
    children = {}
    for pid, ppid in processes():
        children.setdefault(ppid, []).append(pid)
    timebase = Timebase()
    libc.mach_timebase_info(ctypes.byref(timebase))
    total, queue = cpu_ticks(root), list(children.get(root, []))
    while queue:
        pid = queue.pop()
        queue.extend(children.get(pid, []))
        try:
            total += cpu_ticks(pid)
        except LookupError:
            continue
    return round(total * timebase.numer / timebase.denom / 1e7)


def memory(pid):
    usage = RusageInfoV2()
    if libc.proc_pid_rusage(pid, RUSAGE_INFO_V2, ctypes.byref(usage)):
        raise LookupError(pid)
    return usage.ri_resident_size, usage.ri_phys_footprint


def mem_tree(root):
    group = struct.unpack_from("i", kinfo(root), E_PGID)[0]
    children = {}
    for pid, ppid in processes(KERN_PROC_PGRP, group):
        children.setdefault(ppid, []).append(pid)
    (resident, footprint), queue = memory(root), list(children.get(root, []))
    while queue:
        pid = queue.pop()
        queue.extend(children.get(pid, []))
        try:
            more_resident, more_footprint = memory(pid)
        except LookupError:
            continue
        resident, footprint = resident + more_resident, footprint + more_footprint
    return f"{resident // 1024} {footprint // 1024}"


def process_identity(record):
    return struct.unpack_from("qq", record, P_START)


def tree_snapshot(root, known, skip=()):
    """Find descendants across sessions and retain observed orphans by identity.

    The root's own process group also catches children reparented before the
    first snapshot. Start timestamps prevent retaining a recycled PID. The
    calling process and any PID in skip are never members.
    """
    records = {struct.unpack_from("i", record, P_PID)[0]: record for record in kinfos()}
    for pid in (os.getpid(), *skip):
        records.pop(pid, None)
    children = {}
    queue = []
    group_owned = (root not in records or root not in known
                   or process_identity(records[root]) == known[root])
    for pid, record in records.items():
        children.setdefault(struct.unpack_from("i", record, E_PPID)[0], []).append(pid)
        identity = process_identity(record)
        if (known.get(pid) == identity
                or pid == root and (root not in known or known[root] == identity)
                or group_owned and struct.unpack_from("i", record, E_PGID)[0] == root):
            queue.append(pid)
    selected = {}
    while queue:
        pid = queue.pop()
        if pid in selected:
            continue
        selected[pid] = records[pid]
        queue.extend(children.get(pid, []))
    original_root = known.get(root)
    known.clear()
    known.update((pid, process_identity(record)) for pid, record in selected.items())
    if original_root is not None:
        known[root] = original_root
    return selected


def rss_tree(root, known):
    """Strict libproc sample of the full tracked tree, not just its group."""
    records = tree_snapshot(root, known)
    resident, footprint = 0, 0
    readable, counted, uncounted = True, False, []
    for pid, record in records.items():
        if record[P_STAT] == SZOMB or struct.unpack_from("i", record, P_FLAG)[0] & P_WEXIT:
            continue
        try:
            more_resident, more_footprint = memory(pid)
        except LookupError:
            try:
                current = kinfo(pid)
            except LookupError:
                continue
            if (process_identity(current) != process_identity(record)
                    or current[P_STAT] == SZOMB
                    or struct.unpack_from("i", current, P_FLAG)[0] & P_WEXIT):
                continue
            if struct.unpack_from("I", current, E_UID)[0] == os.geteuid():
                readable = False
            else:
                uncounted.append([pid, shown(current[P_COMM:P_COMM + 17].split(b"\0", 1)[0])])
            continue
        counted = True
        resident += more_resident
        footprint += more_footprint
    return json.dumps({
        "rss_kib": max(resident, footprint) // 1024 if readable and (counted or not uncounted) else None,
        "members": [[pid, *process_identity(record)] for pid, record in records.items()],
        "uncounted": uncounted,
    }, separators=(",", ":"))


def end_group(root, known):
    """TERM, then KILL after TERM_SECONDS, the tree of root's group, which this
    process is in; members seen outside the group are matched by identity."""
    def live():
        return [pid for pid, record in tree_snapshot(root, known).items() if record[P_STAT] != SZOMB]

    try:
        for pid in live():
            try:
                os.kill(pid, signal.SIGTERM)
            except OSError:
                pass
        deadline = time.monotonic() + TERM_SECONDS
        while time.monotonic() < deadline and live():
            time.sleep(0.01)
    finally:
        for pid, identity in list(known.items()):
            try:
                if process_identity(kinfo(pid)) == identity:
                    os.kill(pid, signal.SIGKILL)
            except (OSError, LookupError):
                pass
        os.killpg(root, signal.SIGKILL)


def mem_watch(root, reader=mem_tree):
    while sys.stdin.readline():
        try:
            answer = reader(root)
        except (OSError, LookupError, struct.error, IndexError):
            answer = "-"
        print(answer, flush=True)
    return 0


def memory_processes():
    """Kernel RSS census, including other users; never exports argv or environment.

    Fleet attribution needs paired task/inbox markers or a kernel cwd inside
    the declared home, never a name such as node or python. Descendants inherit
    ownership in the consumer even when they clear their own environment.
    Missing RSS is explicit.
    """
    # ps can read other users' RSS where libproc is denied. Sandboxed workers
    # cannot execute its setuid binary; retain explicit nulls there, never zeros.
    resident = {}
    try:
        output = subprocess.run(["/bin/ps", "-axo", "pid=,rss="], capture_output=True,
                                text=True, check=True, env={**os.environ, "LC_ALL": "C"}).stdout
        for line in output.splitlines():
            fields = line.split()
            if len(fields) == 2 and all(value.isdigit() for value in fields):
                resident[int(fields[0])] = int(fields[1]) * 1024
    except (OSError, subprocess.SubprocessError):
        pass
    rows = []
    fleet_root = os.environ.get("FM_MEMORY_FLEET_ROOT", "")
    vnode = VnodePathInfo()
    for record in kinfos():
        pid = struct.unpack_from("i", record, P_PID)[0]
        if pid <= 0:
            continue
        info = ctypes.create_string_buffer(TASKINFO_SIZE)
        readable = libc.proc_pidinfo(pid, PROC_PIDTASKINFO, ctypes.c_uint64(0), info, TASKINFO_SIZE) == TASKINFO_SIZE
        rss = struct.unpack_from("Q", info.raw, 8)[0] if readable else resident.get(pid)
        fleet = False
        try:
            data = sysctl(CTL_KERN, KERN_PROCARGS2, pid)
            argc = struct.unpack_from("i", data, 0)[0]
            words = data[4:].split(b"\0", 1)[1].lstrip(b"\0").split(b"\0")
            environ = dict(word.split(b"=", 1) for word in words[argc:] if b"=" in word)
            task = environ.get(b"FM_TASK_ID", b"")
            inbox = environ.get(b"FM_TASK_INBOX", b"")
            fleet = bool(task and b"/" not in task and inbox.endswith(b"/state/" + task + b".inbox"))
        except (OSError, LookupError, struct.error, IndexError):
            pass
        # Supervisors and workers predating paired markers can still be
        # positively attributed by a kernel cwd inside the declared local home.
        # Never print cwd or inspect another home's endpoint namespace.
        if not fleet and os.path.isabs(fleet_root):
            size = ctypes.sizeof(vnode)
            if libc.proc_pidinfo(pid, 9, ctypes.c_uint64(0), ctypes.byref(vnode), size) == size:
                cwd = os.fsdecode(vnode.cdir.path)
                if os.path.isabs(cwd):
                    fleet = os.path.commonpath((fleet_root, cwd)) == fleet_root
        rows.append({"pid": pid, "ppid": struct.unpack_from("i", record, E_PPID)[0],
                     "comm": os.fsdecode(record[P_COMM:P_COMM + 17].split(b"\0", 1)[0]),
                     "started": lstart(record), "rss_bytes": rss, "fleet": fleet})
    return rows


def main(argv_):
    if argv_[1:] == ["memory"]:
        try:
            print(json.dumps(memory_processes()))
            return 0
        except (OSError, LookupError, struct.error, IndexError):
            return 1
    fields = argv_[2].split(",") if len(argv_) == 3 and argv_[1] == "table" else []
    if len(argv_) != 3 or (fields and not set(fields) <= set(TABLE_FIELDS)) or (not fields and not argv_[2].isdigit()):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    command = argv_[1]
    number = 0 if fields else int(argv_[2])
    if command == "mem-tree":
        return mem_watch(number)
    if command == "rss-tree":
        known = {}
        guard = os.getpgrp() == number != os.getppid()
        if guard:
            for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
                signal.signal(signum, signal.SIG_IGN)
        try:
            return mem_watch(number, lambda root: rss_tree(root, known))
        finally:
            if guard:
                end_group(number, known)
    try:
        if command == "table":
            value = table(fields)
        elif command == "lstart":
            value = lstart(kinfo(number))
        elif command == "identity":
            record = kinfo(number)
            value = f"{lstart(record, padded=True):<28} {command_of(record)}"
        elif command == "count-uid":
            value = len(sysctl(CTL_KERN, KERN_PROC, KERN_PROC_RUID, number)) // KINFO_SIZE
        elif command == "ppid":
            value = struct.unpack_from("i", kinfo(number), E_PPID)[0]
        elif command == "pgid":
            value = struct.unpack_from("i", kinfo(number), E_PGID)[0]
        elif command == "comm":
            kinfo(number)
            try:
                value = argv(number)[0]
            except (OSError, LookupError):
                value = shown(kinfo(number)[P_COMM:P_COMM + 17].split(b"\0", 1)[0])
        elif command == "args":
            value = " ".join(argv(number))
        elif command == "cpu-tree":
            value = cpu_tree(number)
        else:
            return 2
    except (OSError, LookupError, struct.error, IndexError):
        return 1
    if value == "" or (command == "count-uid" and value < 1):
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
