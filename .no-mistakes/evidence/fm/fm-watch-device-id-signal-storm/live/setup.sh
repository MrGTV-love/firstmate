# Setup: scratch APFS image, two marked lab homes (HEAD, base), 14 status logs each.
# head lab: task01 ~1.05 MB (8000 lines), task02 ~1.6 MB (12000 lines) so a first full read outlasts the lab stall bound. base lab: all small logs (comparison only, keeps base passes short).
set -eu
E=/Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW
S=$(cat "$E/live/scratch.path"); W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M60Q9NTSDEB99J8Q1NC7JYGW
mkdir -p "$S/base" "$S/mnt"
git -C "$W" archive 1f843933b5af38820f2e54adad855f28f1c594d9 | tar -x -C "$S/base"
echo "head tree: $(git -C "$W" rev-parse --short HEAD) (run worktree); base tree: 1f843933b -> $S/base"
hdiutil create -size 200m -fs APFS -volname fmvolT -quiet "$S/vol.dmg"
hdiutil attach -nobrowse -owners on -mountpoint "$S/mnt" "$S/vol.dmg" | tail -1
echo "volume device: $(stat -f %d "$S/mnt")"
for c in head base; do
  lab=$("$W/bin/fm-lab-home.sh" create "$S/mnt/lab-$c")
  "$W/bin/fm-lab-home.sh" tmux-dir "$lab" > "$S/tmux-$c.path"
  echo "lab-$c: $lab"
  for n in $(seq -w 1 14); do
    f="$lab/state/task$n.status"
    case "$c:$n" in head:01) lines=8000 ;; head:02) lines=12000 ;; *) lines=0 ;; esac
    if [ "$lines" -gt 0 ]; then
      awk -v t="$n" -v L="$lines" 'BEGIN { for (i = 1; i <= L; i++) printf "working: task%s step %05d %s\n", t, i, "progress note padded to a realistic crew status line length ............................................" }' > "$f"
    else
      for i in $(seq 1 12); do printf 'working: task%s step %02d progress note\n' "$n" "$i"; done > "$f"
    fi
    case "$n" in 07) printf 'blocked: task%s waits on a captain answer\n' "$n" ;; 08) printf 'needs-decision: task%s choose option A or B\n' "$n" ;; *) printf 'done: task%s finished\n' "$n" ;; esac >> "$f"
  done
  ls -l "$lab/state"/task0[12].status | awk '{print "  " $5, $NF}'
done
