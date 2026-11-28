import os, subprocess, sys
s = int(sys.argv[1])
out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
for l in out.splitlines():
    f = l.split(None, 2)
    try:
        if os.getsid(int(f[0])) == s:
            print(" ".join(f)[:150])
    except (OSError, ValueError, IndexError):
        pass
