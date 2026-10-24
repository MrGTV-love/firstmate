#!/bin/bash
# Non-root member is setuid-root top: our native read of it really fails (EPERM),
# so only its ps CPU can show progress. The root shell itself only waits.
top -l 8 -s 1 >/dev/null 2>&1 &
TOP=$!
sleep 1
python3 -I - "$TOP" "$PPID_FM" 1>&2 <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('d', os.environ['FM_DUR']); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.darwin_cpu_reader(); pid = int(sys.argv[1])
print(f'probe: top pid={pid} native_read={r(pid)} root(shell) pid={os.getppid()} native_read={r(os.getppid())}')
PY
wait $TOP
echo top-done
sleep 30
echo NOT-REACHED
