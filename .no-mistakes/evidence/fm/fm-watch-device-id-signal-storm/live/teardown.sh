# Teardown: stop lab watchers, tear down both lab homes' tmux dirs, detach every scratch image, delete scratch.
E=/Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW
S=$(cat "$E/live/scratch.path"); W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M60Q9NTSDEB99J8Q1NC7JYGW
for c in head base; do p=$(cat "$S/watch-$c.pid" 2>/dev/null); [ -n "$p" ] && kill -TERM "$p" 2>/dev/null; done; sleep 1
for c in head base; do [ -d "$S/mnt/lab-$c" ] && "$W/bin/fm-lab-home.sh" teardown "$S/mnt/lab-$c"; done
hdiutil detach -force "$S/mnt" 2>&1 | tail -1
for d in "$S"/dmnt*; do [ -d "$d" ] && hdiutil detach -force "$d" 2>&1 | tail -1; done
rm -rf "$S"; echo "scratch removed: $S exists=$([ -e "$S" ] && echo yes || echo no)"
hdiutil info | grep -c fmdevT || true
