#!/usr/bin/env bash
# Shared helpers for tests/fm-control-successor.test.sh and
# tests/fm-control-successor-scott.test.sh. Source after
# tests/fm-control-relaunch-helpers.sh.

# A tree fingerprint: every file's path, mode, size and content hash, every
# link's target, and every directory's mode, so a changed byte, a new file or a
# changed mode in a work tree, the refs or the run-owned folders shows.
fp() {  # <dir>
  python3 -I -c '
import hashlib, os, sys
root = sys.argv[1]
for base, dirs, files in os.walk(root):
    dirs.sort()
    print("dir", os.path.relpath(base, root), oct(os.lstat(base).st_mode & 0o7777))
    for name in sorted(files + [d for d in dirs if os.path.islink(os.path.join(base, d))]):
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root)
        if os.path.islink(path):
            print(rel, "link", os.readlink(path))
            continue
        info = os.lstat(path)
        with open(path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        print(rel, oct(info.st_mode & 0o7777), info.st_size, digest)
' "$1"
}

# A worker that is already inside a seatbelt profile (a Firstmate worker) is
# refused /bin/ps, which the lock-ownership ancestry walk reads. Only then does
# the case's ps fall back to an lsof-based reader of the same fields; a host
# that allows ps keeps the real one.
successor_ps_fallback() {  # <case-dir>
  local dir=$1
  /bin/ps -o ppid= -p "$$" >/dev/null 2>&1 && return 0
  cat > "$dir/fakebin/ps-runtime" <<'SH'
#!/usr/bin/env bash
field=
pid=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift; field=${1%=} ;;
    -p) shift; pid=$1 ;;
  esac
  shift
done
[ -n "$pid" ] || exit 1
out=$(/usr/sbin/lsof -p "$pid" -a -d cwd -F pRc 2>/dev/null) || exit 1
[ -n "$out" ] || exit 1
case "$field" in
  ppid) printf '%s\n' "$out" | sed -n 's/^R//p' | head -1 ;;
  comm | args) printf '%s\n' "$out" | sed -n 's/^c//p' | head -1 ;;
  stat) printf 'S\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/ps-runtime"
}

# A live process standing in for the worker. Its descriptors are detached so the
# command substitution that builds the case does not wait for it; its pid is in
# <case-dir>/sentinel-pid, and the suite's cleanup stops exactly that pid.
successor_start_sentinel() {  # <case-dir>
  /bin/sleep 3000 >/dev/null 2>&1 </dev/null &
  printf '%s\n' "$!" > "$1/sentinel-pid"
}

successor_stop_sentinels() {
  local file pid
  for file in "$TMP_ROOT"/*/sentinel-pid; do
    [ -f "$file" ] || continue
    pid=$(cat "$file")
    [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  done
}

# A relaunch rewrites a small, known set of paths in the project's shared Git
# directory: the worker-wiring exclude lines in info/exclude, and the two empty
# archive folders the profile builder creates so the task may name its own
# archive branches. Any other difference (a ref, a reflog, an object, the index,
# HEAD, packed-refs, the config) fails, and the observed differences are printed.
successor_relaunch_git_changes() {  # <fingerprint-before> <fingerprint-after> <what>
  local before=$1 after=$2 what=$3 changed path
  changed=$(diff "$before" "$after" | sed -n 's/^[<>] \(dir \)\{0,1\}\([^ ]*\) .*/\2/p' | LC_ALL=C sort -u)
  for path in $changed; do
    case "$path" in
      info/exclude | refs/heads/archive | logs/refs/heads/archive) ;;
      *) fail "$what changed the project's Git directory at $path" ;;
    esac
  done
  printf 'note: %s changed the project Git directory only at: %s\n' "$what" "$(printf '%s' "$changed" | tr '\n' ' ')"
}

# A relaunch stages its launch command in /tmp/fm-<id> and /tmp/fm-<id>+<token>.
# Remove only the ones that belong to the ids these suites made up (the prefixes
# named), never a live task's.
successor_remove_task_tmp() {  # <id-prefix>...
  local prefix dir
  for prefix in "$@"; do
    for dir in /tmp/fm-"$prefix"*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] && rm -rf "$dir"
    done
  done
  return 0
}

# The no-mistakes shim stands for the custody path and every run verb. A relaunch
# may read run status; any other call (run, rerun, respond, abort, daemon, sync,
# eject, init, reset) fails, and the observed calls are printed.
successor_assert_read_only_run_calls() {  # <case-dir> <what>
  local log=$1/fake/nm-calls unexpected
  unexpected=$(grep -v -x -e 'axi status' -e '--version' "$log" || true)
  [ -z "$unexpected" ] || fail "$2 made a no-mistakes call that is not a read-only status read: $unexpected"
  printf 'note: %s made these no-mistakes calls: %s\n' "$2" "$(LC_ALL=C sort "$log" | uniq -c | tr '\n' ';' | sed 's/  */ /g')"
}
