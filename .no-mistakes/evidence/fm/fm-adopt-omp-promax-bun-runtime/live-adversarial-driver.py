import os, pty, subprocess, sys, time, json, tempfile, shutil
W = sys.argv[1]
IDENT = W + "/bin/fm-omp-identity.py"
R = os.path.expanduser("~/.local/share/omp-promax-fix")
BUN = R + "/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun"
CLI = R + "/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
scratch = tempfile.mkdtemp(prefix="fmomp-")
home = scratch + "/home"; wt = scratch + "/wt"; os.makedirs(home); os.makedirs(wt)
env = {"PATH": "/usr/bin:/bin", "HOME": home, "TERM": "xterm-256color", "OMP_SKIP_SETUP": "1"}
BARE = ["--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-title"]
def start(argv, tty=True, exe=None):
    if tty:
        m, s = pty.openpty()
        import fcntl, termios, struct
        fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        p = subprocess.Popen(argv, executable=exe, stdin=s, stdout=s, stderr=s, cwd=wt, env=env, close_fds=True)
        return p, m
    r, w = os.pipe()
    p = subprocess.Popen(argv, executable=exe, stdin=r, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=wt, env=env)
    return p, w
def judge(pid):
    out = {}
    for mode in ("interactive", "writer"):
        r = subprocess.run(["python3", "-I", IDENT, mode, str(pid)], capture_output=True, text=True)
        out[mode] = {"rc": r.returncode, "out": (r.stdout + r.stderr).strip()[:300]}
    return out
fake = scratch + "/fake/pkg"; os.makedirs(fake + "/src")
open(fake + "/src/cli.ts", "w").write("await new Promise(()=>{});\n")
other = scratch + "/other.ts"; open(other, "w").write("await new Promise(()=>{});\n")
cases = [
 ("genuine interactive on tty (expect interactive rc0)", [BUN, CLI] + BARE, True, None),
 ("genuine + one arg value containing '--mode rpc' (expect admitted)", [BUN, CLI] + BARE + ["--system-prompt", "hello --mode rpc"], True, None),
 ("genuine + split --mode rpc, pipe stdin (expect refused)", [BUN, CLI] + BARE + ["--mode", "rpc"], False, None),
 ("genuine + --mode=rpc, pipe stdin (expect refused)", [BUN, CLI] + BARE + ["--mode=rpc"], False, None),
 ("genuine on non-tty stdin, writer open, no prompt (expect refused)", [BUN, CLI] + BARE, False, None),
 ("installed bun running another script (expect refused; writer unrelated)", [BUN, other], True, None),
 ("installed bun running cli.ts outside omp tree (expect refused)", [BUN, fake + "/src/cli.ts"], True, None),
 ("foreign exe (/bin/sleep) presenting installed bun+cli argv words (expect refused)", [BUN, CLI, "--no-session"], True, "/bin/sleep"),
]
res = []
for name, argv, tty, exe in cases:
    if exe == "/bin/sleep":
        # sleep needs a numeric arg; use python to exec with argv0 trick via sh exec -a
        argv2 = ["/usr/bin/perl", "-e", 'exec {"/usr/bin/yes"} @ARGV', BUN, CLI]
        p, fd = start(argv2, tty)
    else:
        p, fd = start(argv, tty)
    time.sleep(4)
    alive = p.poll() is None
    v = judge(p.pid) if alive else {"exited": p.returncode}
    ps = subprocess.run(["ps", "-o", "comm=,args=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
    res.append({"case": name, "pid": p.pid, "alive": alive, "ps": ps[:240], "verdict": v})
    p.kill(); p.wait()
    try: os.close(fd)
    except OSError: pass
print(json.dumps(res, indent=1))
shutil.rmtree(scratch, ignore_errors=True)
