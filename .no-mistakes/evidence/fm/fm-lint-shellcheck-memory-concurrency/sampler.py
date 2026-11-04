# Fast sampler: every 0.1 s, read resident size and physical footprint of each
# registered ShellCheck PID straight from libproc. Writes TSV:
# t, count, sum_rss_kib, sum_max(rss,footprint)_kib, per-pid detail.
import ctypes, os, sys, time, signal
pid_dir, out = sys.argv[1], sys.argv[2]
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
class TaskInfo(ctypes.Structure):
    _fields_ = [('virt', ctypes.c_uint64), ('rss', ctypes.c_uint64)] + [('f%d' % i, ctypes.c_uint64) for i in range(4)] + [('i%d' % i, ctypes.c_int32) for i in range(12)]
class RU(ctypes.Structure):  # rusage_info_v2 prefix
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in ('user','system','pkg_idle','interrupt','pageins','wired','resident','phys_footprint')]
buf = (ctypes.c_uint64 * 64)()
name = ctypes.create_string_buffer(256)
stop = False
def h(*a):
    global stop; stop = True
signal.signal(signal.SIGTERM, h)
t0 = time.time()
with open(out, 'w', buffering=1) as o:
    o.write('t\tcount\tsum_rss_kib\tsum_max_rss_footprint_kib\tdetail\n')
    while not stop:
        cnt = srss = smax = 0; det = []
        for p in os.listdir(pid_dir):
            pid = int(p)
            if lib.proc_name(pid, name, 256) <= 0 or name.value != b'shellcheck':
                continue
            ti = TaskInfo()
            if lib.proc_pidinfo(pid, 4, ctypes.c_uint64(0), ctypes.byref(ti), ctypes.sizeof(ti)) != ctypes.sizeof(ti):
                continue
            ru = (ctypes.c_uint64 * 40)()
            fp = 0
            if lib.proc_pid_rusage(pid, 2, ctypes.byref(ru)) == 0:
                fp = RU.from_buffer(ru).phys_footprint
            rss_k, max_k = ti.rss // 1024, max(ti.rss, fp) // 1024
            cnt += 1; srss += rss_k; smax += max_k; det.append('%d:%d/%d' % (pid, rss_k, fp // 1024))
        o.write('%.2f\t%d\t%d\t%d\t%s\n' % (time.time() - t0, cnt, srss, smax, ','.join(det)))
        time.sleep(0.1)
