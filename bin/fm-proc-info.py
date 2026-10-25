#!/usr/bin/env python3
"""Read process facts on macOS without the setuid ps that sandbox-exec refuses.

Usage: fm-proc-info.py count-uid UID | ppid PID | pgid PID | comm PID | args PID |
       lstart PID | identity PID | cpu-tree PID | table FIELDS

count-uid prints how many processes have real user id UID. ppid and pgid print
a process's parent and process group, comm its argv[0] and args its argv joined
by spaces, as macOS `ps -o comm=` and `ps -o args=` do, and lstart its start
time as `LC_ALL=C ps -o lstart=` with runs of spaces collapsed. identity prints
the exact bytes `COLUMNS=10000 LC_ALL=C ps -p PID -o lstart= -o command=` prints,
so an identity recorded through either source compares equal. table prints one
line per process with the comma-separated FIELDS among pid, ppid, pgid, stat,
lstart and command, like `ps -axo <field>=,...`; stat carries the state letters
macOS ps derives from the kernel (Z zombie, T stopped, R with a running thread,
else S) and E for a process that is exiting. cpu-tree prints the
whole centiseconds of CPU used by PID and its live descendants, including their
reaped children, as macOS `ps -S` counts them. Facts come from sysctl KERN_PROC
and KERN_PROCARGS2, and CPU from libproc's proc_pid_rusage. A process or fact
that cannot be read prints nothing and exits 1, so a caller never mistakes a
failed read for an answer.
"""
import ctypes
import struct
import sys
import time

CTL_KERN, KERN_PROC, KERN_PROCARGS2 = 1, 14, 49
KERN_PROC_ALL, KERN_PROC_PID, KERN_PROC_RUID = 0, 1, 6
# struct kinfo_proc on 64-bit Darwin: kp_proc.p_pid, kp_proc.p_comm,
# kp_proc.p_flag, kp_proc.p_stat, kp_eproc.e_ppid and kp_eproc.e_pgid.
KINFO_SIZE, P_START, P_PID, P_COMM, P_FLAG, P_STAT, E_PPID, E_PGID = 648, 0, 40, 243, 32, 36, 560, 564
# sys/proc.h P_WEXIT and the p_stat values SSTOP and SZOMB.
P_WEXIT, SSTOP, SZOMB = 0x2000, 4, 5
# proc_pidinfo PROC_PIDTASKINFO: struct proc_taskinfo and its pti_numrunning.
PROC_PIDTASKINFO, TASKINFO_SIZE, PTI_NUMRUNNING = 4, 96, 88
DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
TABLE_FIELDS = ("pid", "ppid", "pgid", "stat", "lstart", "command")
RUSAGE_INFO_V2 = 2

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


def argv(pid):
    data = sysctl(CTL_KERN, KERN_PROCARGS2, pid)
    argc = struct.unpack_from("i", data, 0)[0]
    # The executable path and its padding precede argv.
    rest = data[4:].split(b"\0", 1)[1].lstrip(b"\0")
    words = rest.split(b"\0")[:argc]
    if argc < 1 or len(words) < argc:
        raise LookupError(pid)
    return [word.decode("utf-8", "replace") for word in words]


def kinfos():
    data = sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)
    for offset in range(0, len(data) - KINFO_SIZE + 1, KINFO_SIZE):
        yield data[offset:offset + KINFO_SIZE]


def processes():
    for record in kinfos():
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
        return "(" + record[P_COMM:P_COMM + 17].split(b"\0", 1)[0].decode("utf-8", "replace") + ")"


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


def main(argv_):
    fields = argv_[2].split(",") if len(argv_) == 3 and argv_[1] == "table" else []
    if len(argv_) != 3 or (fields and not set(fields) <= set(TABLE_FIELDS)) or (not fields and not argv_[2].isdigit()):
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    command = argv_[1]
    number = 0 if fields else int(argv_[2])
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
                value = kinfo(number)[P_COMM:P_COMM + 17].split(b"\0", 1)[0].decode("utf-8", "replace")
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
