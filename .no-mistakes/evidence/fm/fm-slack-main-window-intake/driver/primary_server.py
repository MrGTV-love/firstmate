#!/usr/bin/env python3
"""Hold one armed lab home and the fake Slack open for a real lab primary. Stop by removing the run file."""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from harness import Lab  # noqa: E402

ROOT, out = sys.argv[1], Path(sys.argv[2])
l = Lab(ROOT, 'intake')
l.arm()
sock = subprocess.run([ROOT + '/bin/fm-lab-home.sh', 'tmux-dir', l.home], capture_output=True, text=True, env=l.base_env).stdout.strip()
out.write_text('export FM_HOME=%s\nexport TMUX_TMPDIR=%s\nexport FAKE=%s\nexport PY=%s\n' % (l.home, sock, l.base, l.base_env['PYTHONPATH']))
print(out.read_text(), flush=True)
try:
    while out.exists():
        time.sleep(2)
finally:
    subprocess.run([ROOT + '/bin/fm-lab-home.sh', 'teardown', l.home], env=l.base_env)
    l.close()
