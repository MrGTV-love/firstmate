#!/usr/bin/env python3
"""Names-only worker environment probe. Never prints or stores any value."""
import json, os, re, subprocess, sys, tempfile
out, task, login = sys.argv[1], sys.argv[2], sys.argv[3] == "login"
SHAPE = r"KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|SENTINEL"
pat = re.compile(SHAPE, re.I)
FAKES = ["FM_TEST_FAKE_API_KEY", "FM_TEST_FAKE-BAD", "GEMINI_API_KEY", "LINEAR_API_KEY", "TAC_HMAC_KEY", "VERCEL_TOKEN",
         "_SECRETS_LOADED", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "DEEPSEEK_API_KEY"]
CHILD = ("import os,json,re,sys;"
         "json.dump(sorted(k for k in os.environ if re.search(%r,k,re.I) or k in %r),open(sys.argv[1],'w'))" % (SHAPE, FAKES))
def shaped(names):
    return sorted(n for n in names if pat.search(n) or n in FAKES)
def child(argv):
    fd, path = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".probe-"); os.close(fd)
    try:
        r = subprocess.run(argv + [sys.executable, path], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=120)
        if r.returncode:
            return {"error": r.returncode}
        return json.load(open(path))
    except Exception as e:
        return {"error": type(e).__name__}
    finally:
        os.unlink(path)
dump = subprocess.run(["/usr/bin/env", "-0"], capture_output=True, check=True).stdout
env_names = [e.split(b"=", 1)[0].decode() for e in dump.split(b"\0") if b"=" in e]
run_py = 'exec "$1" -c "$2" "$3"'
def sh(shell, *flags):
    return lambda: child([shell, *flags, "-c", 'exec "$1" -c "$2" "$3"', "probe"])
def shell_child(shell, *flags):
    fd, path = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".probe-"); os.close(fd)
    try:
        r = subprocess.run([shell, *flags, "-c", run_py, "probe", sys.executable, CHILD, path], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)
        return {"error": r.returncode} if r.returncode else json.load(open(path))
    except Exception as e:
        return {"error": type(e).__name__}
    finally:
        os.unlink(path)
channels = {"env": shaped(env_names), "python_os_environ": shaped(os.environ),
            "child_sh": shell_child("/bin/sh"), "child_bash": shell_child("/bin/bash", "--noprofile", "--norc"),
            "child_zsh_f": shell_child("/bin/zsh", "-f")}
if login:
    channels["login_interactive_bash"] = shell_child("/bin/bash", "--login", "-i")
    channels["login_interactive_zsh"] = shell_child("/bin/zsh", "-l", "-i")
def opened(path):
    # open without read: no file content enters this process.
    try:
        os.close(os.open(path, os.O_RDONLY)); return "opened"
    except FileNotFoundError:
        return "missing"
    except PermissionError:
        return "denied"
    except OSError as e:
        return e.__class__.__name__
home = os.path.expanduser("~")
git = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
result = {
    "task": task,
    "sentinel_value_in_env_dump": b"sentinel-not-a-secret" in dump,
    "credential_shaped_names_by_channel": channels,
    "kept": {n: (n in os.environ) for n in ("TERM", "HOME", "PATH", "USER", "SHELL", "TMPDIR", "FM_TASK_INBOX", "GIT_CONFIG_COUNT", "SSH_AUTH_SOCK")},
    "fm_task_id_matches": os.environ.get("FM_TASK_ID") == task,
    "java_home_kept": os.environ.get("JAVA_HOME") == "/synthetic/jdk",
    "goroot_unset_stays_unset": "GOROOT" not in os.environ,
    "disable_autoupdater_kept": os.environ.get("DISABLE_AUTOUPDATER") == "1",
    "pythonpath_dropped": "PYTHONPATH" not in os.environ,
    "virtual_env_dropped": "VIRTUAL_ENV" not in os.environ,
    "node_options_dropped": "NODE_OPTIONS" not in os.environ,
    "bash_env_dropped": "BASH_ENV" not in os.environ,
    "write_confinement": os.environ.get("FM_WRITE_CONFINEMENT"),
    "git_works": git.returncode == 0 and git.stdout.strip() == "true",
    "git_error_first_line": (git.stderr.strip().splitlines() or [""])[0][:160],
    "open_only_startup_files": {p: opened(p) for p in (home + "/.zshrc", home + "/.zshenv", home + "/.zprofile", home + "/.bash_profile", "/etc/zshrc", "/etc/profile")},
}
tmp = out + ".tmp"
with open(tmp, "w") as f:
    json.dump(result, f, indent=1, sort_keys=True)
os.rename(tmp, out)
print("probe finished; result written")
