#!/usr/bin/env python3
"""Live role and identity shapes against the INSTALLED omp-promax Bun runtime.

Each case starts a real process (the installed launcher or runtime, or a scratch
foreign program), lets it settle, and asks the delivered bin/fm-omp-identity.py
for its `interactive` and `writer` verdicts on the live PID. No prompt is sent,
HOME is a scratch directory with no key, and every process is one this script
started and stops itself. Usage: live-role-shapes.py <worktree-root>
"""
import fcntl, os, pty, shutil, struct, subprocess, sys, tempfile, termios, time

root = sys.argv[1]
ident = os.path.join(root, "bin", "fm-omp-identity.py")
R = os.path.expanduser("~/.local/share/omp-promax-fix")
LAUNCHER = R + "/omp-promax"
RT = R + "/runtime/node_modules/@oven/bun-darwin-aarch64/bin/bun"
SCRIPT = R + "/src/node_modules/@oh-my-pi/pi-coding-agent/src/cli.ts"
BUN = os.path.expanduser("~/.bun/bin/bun")
tmp = os.path.realpath(tempfile.mkdtemp(prefix="fm-role-shapes."))
home = os.path.join(tmp, "home"); os.makedirs(home)
env = {"PATH": os.environ["PATH"], "HOME": home, "TERM": "xterm-256color", "OMP_SKIP_SETUP": "1",
       "OPENAI_API_KEY": "fm-non-submitting-fixture"}
os.makedirs(tmp + "/proj/src")
open(tmp + "/proj/server.ts", "w").write("setInterval(() => {}, 1 << 30);\n")
open(tmp + "/proj/src/cli.ts", "w").write("setInterval(() => {}, 1 << 30);\n")
open(tmp + "/proj/package.json", "w").write('{"scripts":{"dev":"bun server.ts"}}\n')
open(tmp + "/sleeper.c", "w").write("#include <unistd.h>\nint main(void){for(;;)pause();}\n")
have_cc = subprocess.run(["cc", "-o", tmp + "/sleeper", tmp + "/sleeper.c"]).returncode == 0

def tty():
    m, s = pty.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    return m, s

def verdicts(pid):
    out = []
    for verb in ("interactive", "writer"):
        p = subprocess.run([sys.executable, "-I", ident, verb, str(pid)], capture_output=True, text=True)
        out.append(f"{verb}: exit={p.returncode} {(p.stdout + p.stderr).strip()[:160]}")
    return out

def case(name, argv, stdin_kind, cwd=None, executable=None, settle=6.0):
    masters = []
    if stdin_kind == "tty":
        m, s = tty(); masters.append(m); stdin = stdout = s
    else:
        r, w = os.pipe(); stdin = r; m, s = tty(); masters.append(m); stdout = s
        masters.append(w)  # writer kept open and silent: a long-lived noninteractive process
    p = subprocess.Popen(argv, executable=executable, stdin=stdin, stdout=stdout, stderr=stdout, cwd=cwd or tmp,
                         env=env, close_fds=True, start_new_session=True)
    deadline = time.time() + settle
    while time.time() < deadline:
        for fd in masters[:1]:
            try:
                os.set_blocking(fd, False); os.read(fd, 65536)
            except OSError:
                pass
        time.sleep(0.1)
    alive = p.poll() is None
    print(f"\n=== {name}")
    print(f"argv: {argv}" + (f"  (kernel executable: {executable})" if executable else ""))
    print(f"stdin: {stdin_kind}; alive after {settle:.0f}s: {alive}")
    if alive:
        for line in verdicts(p.pid):
            print("  " + line)
    try:
        os.killpg(p.pid, 9)  # the process group this script created for the case (start_new_session)
    except ProcessLookupError:
        pass
    # Close the pty master and the pipe writer first: a killed process with unread pty output
    # otherwise blocks in its exit waiting for the terminal to drain.
    for fd in masters + [s]:
        try: os.close(fd)
        except OSError: pass
    p.wait()

case("installed launcher, interactive, terminal stdin (expect interactive)", [LAUNCHER, "--no-session"], "tty")
case("installed launcher, --mode rpc (expect refused: protocol role)", [LAUNCHER, "--no-session", "--mode", "rpc"], "tty")
case("installed launcher, --mode=rpc (expect refused: protocol role)", [LAUNCHER, "--no-session", "--mode=rpc"], "tty")
case("installed launcher, one argument value containing '--mode rpc' (expect interactive)",
     [LAUNCHER, "--no-session", "--system-prompt", "hello --mode rpc"], "tty")
case("installed launcher, piped stdin held open, no prompt (expect refused: stdin not a terminal)",
     [LAUNCHER, "--no-session"], "pipe")
if have_cc:
    case("foreign executable presenting the installed runtime and script as argv (expect refused)",
         [RT, SCRIPT, "--no-session"], "tty", executable=tmp + "/sleeper", settle=2)
else:
    print("\n=== foreign executable case skipped: no C compiler")
case("bun run dev (relative non-cli.ts argv[1]: expect writer unrelated)", [BUN, "run", "dev"], "tty", cwd=tmp + "/proj", settle=4)
case("bun src/cli.ts relative (expect writer may-own, unresolved; interactive refused)", [BUN, "src/cli.ts"], "tty", cwd=tmp + "/proj", settle=4)
case("installed runtime on a scratch .../src/cli.ts (expect interactive refused)", [RT, tmp + "/proj/src/cli.ts"], "tty", settle=4)
shutil.rmtree(tmp)
print("\nscratch removed:", not os.path.exists(tmp))
