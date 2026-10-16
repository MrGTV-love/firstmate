# Stand-in agent body: one long-lived non-shell process (run under the name
# "omp") that keeps a few very short-lived children alive in its own process
# group, like omp helper workers that start and exit within milliseconds.
import subprocess, time
kids = []
while True:
    kids = [k for k in kids if k.poll() is None]
    while len(kids) < 3:
        kids.append(subprocess.Popen(["/bin/sleep", "0.02"], stdin=subprocess.DEVNULL))
    time.sleep(0.003)
