#!/usr/bin/env python3
"""Observe real watcher output while forcing a post-resume beacon before TERM."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

name = Path(sys.argv[0]).name
args = sys.argv[1:]
log = Path(os.environ['FM_PROBE_LOG'])
def emit(event, **fields):
    with log.open('a') as stream:
        stream.write(json.dumps(dict(event=event, **fields)) + '\n')

if name == 'wait-resumed':
    state = Path(args[0])
    pid = args[1]
    deadline = time.monotonic() + 8
    while not (state / 'probe-resumed-touch').exists():
        if time.monotonic() >= deadline:
            emit('resume-write-timeout', watcher_pid=pid)
            sys.exit(1)
        time.sleep(0.01)
    stat = subprocess.check_output(['/bin/ps', '-p', pid, '-o', 'stat='], text=True).strip()
    emit('resumed-watcher-after-next-beacon', watcher_pid=pid, process_state=stat,
         arm_output=(state.parent / 'arm.out').read_text())
    sys.exit(1 if 'T' in stat else 0)

rc = subprocess.run(['/usr/bin/' + name, *args]).returncode
if name == 'touch':
    beacon = next((Path(arg) for arg in args if arg.endswith('/stopped-watcher/state/.last-watcher-beat')), None)
    if beacon is not None and rc == 0:
        state = beacon.parent
        if args == [str(beacon)]:
            resumed = (state / 'beacon-writer-stopped').exists()
            emit('real-beacon-write', mtime=beacon.stat().st_mtime, after_one_shot_marker=resumed)
            if resumed:
                (state / 'probe-resumed-touch').write_text('actual system touch completed\n')
        elif '-t' in args:
            emit('backdated-beacon', mtime=beacon.stat().st_mtime,
                 stopped_writer=(state / 'beacon-writer-stopped').read_text().strip())
elif name == 'grep':
    for arg in args:
        if arg.endswith('/stopped-watcher/state/.watch-cycle-exits.log') and Path(arg).exists():
            emit('production-cycle-exit-ledger', grep_exit=rc, content=Path(arg).read_text())
sys.exit(rc)
