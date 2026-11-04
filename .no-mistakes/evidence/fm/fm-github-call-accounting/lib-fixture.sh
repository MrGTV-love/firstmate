#!/usr/bin/env bash
# Disposable fixture helpers for live accounting scenarios. Every process and file
# made here lives under $FIX. Callers are #!/bin/sh scripts running sleep WITHOUT exec.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6HY67SMDHG0CZE4NE696MQG
OWNER="$WT/bin/fm-github-accounting.py"
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG

mkfix() {  # sets FIX
  FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-acct-fix.XXXXXX")
  mkdir -p "$FIX/callers"
  cat > "$FIX/callers/gh" <<'SH'
#!/bin/sh
sleep 3000
SH
  cat > "$FIX/callers/wrapper-b.sh" <<SH
#!/bin/sh
"$FIX/callers/gh" "\$@"
SH
  cat > "$FIX/callers/wrapper-a.sh" <<SH
#!/bin/sh
"$FIX/callers/wrapper-b.sh" "\$@"
SH
  chmod +x "$FIX/callers/"*
}

# Start a caller chain: wrapper-a.sh -> wrapper-b.sh -> gh <args>. Prints wrapper-a pid.
start_caller() {
  "$FIX/callers/wrapper-a.sh" "$@" </dev/null >/dev/null 2>&1 &
  echo $!
}
# Print the pid of the gh script below a wrapper-a pid.
gh_pid_of() {
  local b
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    b=$(pgrep -P "$1" | head -1)
    if [ -n "$b" ]; then
      g=$(pgrep -P "$b" | head -1)
      [ -n "$g" ] && { echo "$g"; return 0; }
    fi
    sleep 0.1
  done
  return 1
}
kill_gh() {  # <gh pid> : end the fixture gh script and its sleep child
  pkill -P "$1" 2>/dev/null
  kill "$1" 2>/dev/null
}
kill_tree() {  # <wrapper-a pid> : end the whole fixture chain
  local p kids
  kids=$(pgrep -P "$1")
  for p in $kids; do kill_tree "$p"; done
  kill "$1" 2>/dev/null
}
cleanup_fixture_procs() {
  # Only processes whose command line names this run's private fixture dir, and
  # their direct sleep children.
  local p
  for p in $(pgrep -f "$FIX/callers/"); do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  true
}

# Lab home for one scenario shell: sets FM_HOME, TMUX_TMPDIR and LAB_TEARDOWN.
mklab() {
  local err; err=$(mktemp)
  eval "$(cd "$WT" && bin/fm-lab-home.sh env 2>"$err")"
  export FM_HOME
  LAB_TEARDOWN="$WT/bin/fm-lab-home.sh teardown $FM_HOME && rm -rf $FM_HOME"
  rm -f "$err"
}
