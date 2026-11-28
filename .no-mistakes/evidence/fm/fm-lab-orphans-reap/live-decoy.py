import os, sys, time, signal
if os.fork(): sys.exit(0)
os.setsid(); os.chdir(sys.argv[1])
for s in (1, 2, 15, 18):
    signal.signal(s, lambda n, f: open(sys.argv[2], "a").write("%d\n" % n))
open(sys.argv[3], "w").write("%d\n" % os.getpid())
t = time.time() + 90
while time.time() < t: time.sleep(0.2)
