#!/usr/bin/env bash
# Disposable live-lab helpers for bin/fm-copy-sweep.sh.
# Real sweep, real git, real lsof, real du, real uptime. Only Vernant's
# closeout driver is a stand-in (a real python3 script at the slot's own
# scripts/git-stability/closeout_pr.py, run by the slot's .venv/bin/python).
set -u
REPO=${REPO:?}
SWEEP="$REPO/bin/fm-copy-sweep.sh"

# new_world <name>: sets W HOMED TH SLOT CTL
new_world() {
  W=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  W=$(cd "$W" && pwd -P)
  HOMED="$W/home"
  "$REPO/bin/fm-lab-home.sh" create "$HOMED" >/dev/null
  TH="$W/th"; SLOT="$TH/pool1/1/repo"; CTL="$W/ctl"
  mkdir -p "$TH/pool1/1" "$CTL"
  git init -q -b main "$SLOT"
  git -C "$SLOT" config user.email lab@example.invalid
  git -C "$SLOT" config user.name lab
  printf 'base\n' > "$SLOT/README"
  git -C "$SLOT" add README && git -C "$SLOT" commit -qm base
  git init -q --bare "$W/origin.git"
  git -C "$SLOT" remote add origin "$W/origin.git"
  git -C "$SLOT" push -q origin main
  git -C "$SLOT" fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
  printf '%s\n' scripts/ .venv/ '.claude/' >> "$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/scripts/git-stability" "$SLOT/.venv/bin"
  ln -s "$(command -v python3)" "$SLOT/.venv/bin/python"
  cat > "$SLOT/scripts/git-stability/closeout_pr.py" <<PY
import json, os, subprocess, sys
CTL = "$CTL"
args = sys.argv[1:]
copy = args[1]
name = os.path.basename(copy)
execute = "--execute-cleanup" in args
with open(os.path.join(CTL, "closeout.log"), "a") as f:
    f.write("%s|%s\n" % (os.getcwd(), " ".join(args)))
def has(marker):
    return os.path.exists(os.path.join(CTL, marker + "-" + name))
def git(*a):
    return subprocess.run(["git"] + list(a), env=dict(os.environ, LAB_DRIVER="1")).returncode
if not execute:
    if has("refuse-plan"):
        print(json.dumps({"allowed": False, "reason": "pull_request_not_merged"}))
        sys.exit(3)
    if has("mutate-lock"):
        admin = subprocess.run(["git", "-C", copy, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True).stdout.strip()
        lk = os.path.join(admin, "locked")
        cur = open(lk).read()
        pid = cur.split("launcher=")[-1].strip()
        new = ("vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=%s\n" % pid) if "owner=launcher:" in cur else ("vernant-session-active owner=launcher:%s launcher=%s\n" % (pid, pid))
        open(lk, "w").write(new)
    print(json.dumps({"allowed": True, "execute": False}))
    sys.exit(0)
if has("mutate-then-live"):
    with open(os.path.join(copy, "unique.dat"), "w") as f:
        f.write("v1 written by an owner during execute\n")
    print(json.dumps({"allowed": False, "reason": "cleanup_skipped_live_or_unknown"}))
    sys.exit(3)
if has("live"):
    print(json.dumps({"allowed": False, "reason": "cleanup_skipped_live_or_unknown"}))
    sys.exit(3)
if has("lease"):
    print(json.dumps({"allowed": False, "reason": "cleanup_lease_conflict"}))
    sys.exit(3)
if has("partial-fail"):
    git("worktree", "unlock", copy)
    print("injected removal failure after the lock was released")
    sys.exit(4)
if has("partial"):
    git("worktree", "unlock", copy)
    print(json.dumps({"allowed": True, "cleanup_exit_code": 0}))
    sys.exit(0)
if git("worktree", "unlock", copy) != 0:
    sys.exit(4)
rc = git("worktree", "remove", copy)
print(json.dumps({"allowed": rc == 0, "cleanup_exit_code": rc}))
sys.exit(0 if rc == 0 else 3)
PY
}

# add_copy <name>: clean nested copy on branch fm/<name>, one commit, pushed.
add_copy() {
  local c="$SLOT/.claude/worktrees/$1"
  git -C "$SLOT" worktree add -q -b "fm/$1" "$c"
  printf '%s\n' "$1" > "$c/$1.txt"
  git -C "$c" add "$1.txt" && git -C "$c" commit -qm "$1"
  git -C "$c" push -q origin "fm/$1"
}
cp_() { printf '%s\n' "$SLOT/.claude/worktrees/$1"; }

dead_pid() { local p; sleep 0.05 & p=$!; wait "$p" 2>/dev/null; printf '%s\n' "$p"; }

# lock_dead <name>: Vernant creation lock naming a finished launcher.
lock_dead() {
  local p; p=$(dead_pid)
  git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$p launcher=$p" "$(cp_ "$1")"
}

registered() { git -C "$SLOT" worktree list --porcelain | grep -qxF "worktree $(cp_ "$1")"; }

# git_logger: pass-through git that logs the sweep's own calls (not the driver's).
git_logger() {
  mkdir -p "$W/bin"
  cat > "$W/bin/git" <<SH
#!/usr/bin/env bash
[ -n "\${LAB_DRIVER:-}" ] || printf '%s\n' "\$*" >> "$W/sweep-git.log"
exec $(command -v git) "\$@"
SH
  chmod +x "$W/bin/git"
  LAB_PATH="$W/bin:$PATH"
}

sweep() {  # args...; runs the real sweep with a clean env pointing at the lab
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_TEARDOWN_VERNANT_PYTHON \
      PATH="${LAB_PATH:-$PATH}" FM_HOME="$HOMED" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" \
      nice -n 20 bash "$SWEEP" "$@"
}
