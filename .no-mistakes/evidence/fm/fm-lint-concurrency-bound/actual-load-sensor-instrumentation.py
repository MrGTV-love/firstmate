#!/Users/charlesabrooker/.pyenv/versions/3.13.6/bin/python3
import os,sys,time,json,fcntl
with open(os.environ["FM_LIVE_PROBE_LOG"],"a") as log:
    fcntl.flock(log,fcntl.LOCK_EX)
    log.write(json.dumps(dict(pid=os.getpid(),time=time.time(),args=sys.argv[1:]))+"\n")
os.execv("/usr/sbin/sysctl",["/usr/sbin/sysctl",*sys.argv[1:]])
