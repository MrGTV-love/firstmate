"""Run the real fm-duration.py CLI, failing ONLY the Darwin native CPU read of
the tree root (as proc_pid_rusage does for a process we may not inspect)."""
import importlib.util, os, sys
path = sys.argv[1]
spec = importlib.util.spec_from_file_location('fm_duration', path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
real_reader = m.darwin_cpu_reader()
real_tree = m.tree_cpu
root = {}
def tree_cpu(pid, observed):
    root['pid'] = pid
    return real_tree(pid, observed)
def reader(pid):
    return None if pid == root.get('pid') else real_reader(pid)
m.tree_cpu = tree_cpu
m.darwin_cpu_reader = lambda: reader
sys.argv = [path] + sys.argv[2:]
sys.exit(m.main())
