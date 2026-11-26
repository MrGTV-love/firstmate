#!/usr/bin/env bash
# tests/git-config-env-helpers.sh - the one shared check of the numbered GIT_CONFIG environment a launch hands a worker.
#
# Source it after tests/lib.sh (it uses fail and nothing else):
#   # shellcheck source=tests/git-config-env-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/git-config-env-helpers.sh"
#
# Consumers: tests/fm-spawn-git-hook-carrier.test.sh (every launch route) and tests/fm-dsh-spawn.test.sh (the dsh routes,
# after dsh's own credential scrub). The helper's own mutation controls live in the carrier suite.

# git_config_env_problems <env0-file> <repo>: the one shared check of the numbered
# GIT_CONFIG environment a launch hands a worker. <env0-file> is `env -0` output
# captured in (or, for a harness that scrubs names, after the scrub of) the launched
# environment. Prints one line per violation and returns 1 when there is any:
#   - GIT_CONFIG_COUNT is present but not a non-negative number;
#   - for any n below GIT_CONFIG_COUNT, GIT_CONFIG_KEY_n or GIT_CONFIG_VALUE_n is missing
#     (a missing or empty key makes every git call fail);
#   - any GIT_CONFIG_KEY_n or GIT_CONFIG_VALUE_n sits at or above GIT_CONFIG_COUNT;
#   - a plain `git status` in <repo> under exactly that environment exits non-zero.
# An absent GIT_CONFIG_COUNT counts as 0. The check reads every one of the four
# conditions separately, so a helper that looked only at COUNT would not pass the
# mutation controls in tests/fm-spawn-git-hook-carrier.test.sh.
git_config_env_problems() {
  python3 -I - "$1" "$2" <<'PY'
import os, re, subprocess, sys
env_file, repo = sys.argv[1], sys.argv[2]
raw = open(env_file, "rb").read().split(b"\0")
env = {}
for item in raw:
    if not item:
        continue
    name, _, value = item.decode("utf-8", "surrogateescape").partition("=")
    env[name] = value
problems = []
count_text = env.get("GIT_CONFIG_COUNT")
count = 0
if count_text is not None:
    if re.fullmatch(r"[0-9]+", count_text):
        count = int(count_text)
    else:
        problems.append("GIT_CONFIG_COUNT=%r is not a non-negative number" % count_text)
for n in range(count):
    if not env.get("GIT_CONFIG_KEY_%d" % n):
        problems.append("GIT_CONFIG_KEY_%d is missing below GIT_CONFIG_COUNT=%d" % (n, count))
    if "GIT_CONFIG_VALUE_%d" % n not in env:
        problems.append("GIT_CONFIG_VALUE_%d is missing below GIT_CONFIG_COUNT=%d" % (n, count))
for name in sorted(env):
    match = re.fullmatch(r"GIT_CONFIG_(KEY|VALUE)_([0-9]+)", name)
    if match and int(match.group(2)) >= count:
        problems.append("%s sits at or above GIT_CONFIG_COUNT=%d" % (name, count))
result = subprocess.run(["git", "-C", repo, "status"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
if result.returncode != 0:
    problems.append("git status exited %d: %s" % (result.returncode, result.stderr.decode("utf-8", "replace").strip().splitlines()[0] if result.stderr.strip() else "no message"))
for line in problems:
    print(line)
sys.exit(1 if problems else 0)
PY
}

# assert_git_config_env <env0-file> <repo> <label>: fail with every violation named.
assert_git_config_env() {
  local problems
  problems=$(git_config_env_problems "$1" "$2") || fail "$3: the launched GIT_CONFIG environment is inconsistent: $problems"
}

# git_config_entries <env0-file> <key>: every value the environment carries for a
# git config key, one per line, from numbered entries and from GIT_CONFIG_PARAMETERS
# rows ('key'='value' and the older 'key=value' form), numbered ones first.
git_config_entries() {
  python3 -I - "$1" "$2" <<'PY'
import shlex, sys
env = {}
for item in open(sys.argv[1], "rb").read().split(b"\0"):
    if item:
        name, _, value = item.decode("utf-8", "surrogateescape").partition("=")
        env[name] = value
key = sys.argv[2]
count_text = env.get("GIT_CONFIG_COUNT", "0")
count = int(count_text) if count_text.isdigit() else 0
for n in range(count):
    if env.get("GIT_CONFIG_KEY_%d" % n) == key:
        print(env.get("GIT_CONFIG_VALUE_%d" % n, ""))
# 'key'='value' and 'key=value' both reach shlex as one word key=value.
for word in shlex.split(env.get("GIT_CONFIG_PARAMETERS", "")):
    name, sep, value = word.partition("=")
    if sep and name == key:
        print(value)
PY
}

# git_config_value_in_env <env0-file> <repo> <key>: what `git config --get <key>` answers in exactly that environment,
# printed as a Python repr so a value's quotes, spaces and newlines are visible and comparable.
git_config_value_in_env() {
  python3 -I - "$1" "$2" "$3" <<'PY'
import subprocess, sys
env = {}
for item in open(sys.argv[1], "rb").read().split(b"\0"):
    if item:
        name, _, value = item.decode("utf-8", "surrogateescape").partition("=")
        env[name] = value
done = subprocess.run(["git", "-C", sys.argv[2], "config", "--get", sys.argv[3]], env=env, capture_output=True, text=True)
print(repr(done.stdout[:-1] if done.stdout.endswith("\n") else done.stdout))
PY
}
