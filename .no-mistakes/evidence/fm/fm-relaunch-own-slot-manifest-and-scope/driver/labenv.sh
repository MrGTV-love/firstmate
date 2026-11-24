# Source me: ROOT must be set. Mirrors bin/fm-live-lab.sh lab_run (clean env).
LAB=$ROOT/home
TMUX_DIR=$(sed -n 's/^tmux_dir=//p' "$ROOT/.fm-live-lab")
WID=$(sed -n 's/^worker_id=//p' "$ROOT/.fm-live-lab")
PROJ=$LAB/projects/vern
EVD=/Users/charlesabrooker/.no-mistakes/evidence/01M85Z2DHW1E5DRKCR3JA3RPEP
SENT=$ROOT/prov/runs.log
lt() { env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux "$@"; }
lr() {
  "$LAB/bin/fm-proc-budget.sh" -- env -i HOME="$HOME" USER="$USER" LOGNAME="$USER" PATH="$PATH" SHELL=/bin/zsh \
    TERM=xterm-256color LANG=en_US.UTF-8 TMUX_TMPDIR="$TMUX_DIR" TREEHOUSE_ROOT="$ROOT/treehouse" FM_BACKEND=tmux \
    DISABLE_AUTOUPDATER=1 FM_HOME="$LAB" "$@"
}
meta() { cat "$LAB/state/$WID.meta"; }
wt() { sed -n 's/^worktree=//p' "$LAB/state/$WID.meta" | head -1; }
mpath() { sed -n 's/^slot_manifest=//p' "$LAB/state/$WID.meta" | head -1; }
inv() { # manifest directory inventory (inode, mode, size, sha, mtime, ctime ns)
  python3 - "$(dirname "$1")" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
def row(path):
    i = os.lstat(path); d = "-"
    if os.path.isfile(path): d = hashlib.sha256(open(path, "rb").read()).hexdigest()
    return "%s ino=%d mode=%o size=%d sha=%s mtime=%d ctime=%d" % (path, i.st_ino, i.st_mode, i.st_size, d, i.st_mtime_ns, i.st_ctime_ns)
print(row(root))
for dp, dn, fn in os.walk(root):
    for n in sorted(dn + fn): print(row(os.path.join(dp, n)))
PY
}
wpane() { lt capture-pane -p -t "$(sed -n 's/^tmux_target=//p;s/^target=//p' "$LAB/state/$WID.meta" | head -1)" -S -40 2>/dev/null; }
