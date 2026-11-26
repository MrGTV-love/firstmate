. /Users/charlesabrooker/tmp/fm-lab-drv/env.sh
OUT=$E/live-08-kernel-confinement.txt; : > $OUT
CP=$FX/slots/22/project; G="git -C $CP"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid GIT_CONFIG_GLOBAL=/dev/null
P=$($G rev-parse refs/heads/$SUCC)
C=$($G commit-tree "$P^{tree}" -p "$P" -m "worker commit on the successor")
S=$($G rev-parse refs/heads/$OLD)
C2=$($G commit-tree "$S^{tree}" -p "$S" -m "worker commit on the task branch")
echo "P=$P C=$C (child of P)  S=$S C2=$C2 (child of S)" >> $OUT
run() { # profile label ref new old
  local prof=$1 label=$2 ref=$3 new=$4 old=${5:-}
  local before after rc out
  before=$($G rev-parse -q --verify "$ref" || echo absent)
  out=$(/usr/bin/sandbox-exec -f "$prof" /usr/bin/git -C "$CP" update-ref "$ref" "$new" ${old:+"$old"} 2>&1); rc=$?
  after=$($G rev-parse -q --verify "$ref" || echo absent)
  if [ $rc = 0 ] && [ "$after" = "$new" ]; then v=ALLOWED; elif [ "$before" = "$after" ]; then v=REFUSED; else v=UNCLEAR; fi
  printf '%-9s %-28s %-48s rc=%s %s\n' "$v" "$label" "$ref" "$rc" "$(printf '%s' "$out" | head -1)" >> $OUT
}
echo >> $OUT; echo "## Launch 1 profile (no successor recorded)" >> $OUT
run $E/live-profile-1-no-successor.sb "successor (must refuse)" "refs/heads/$SUCC" "$C" "$P"
run $E/live-profile-1-no-successor.sb "task branch (control)" "refs/heads/$OLD" "$C2" "$S"
$G update-ref "refs/heads/$OLD" "$S" "$C2"
echo >> $OUT; echo "## Launch 2 profile (successor recorded)" >> $OUT
run $E/live-profile-2-with-successor.sb "successor (must allow)" "refs/heads/$SUCC" "$C" "$P"
run $E/live-profile-2-with-successor.sb "task branch (control)" "refs/heads/$OLD" "$C2" "$S"
run $E/live-profile-2-with-successor.sb "unrelated name" "refs/heads/lab-unrelated" "$C"
run $E/live-profile-2-with-successor.sb "default branch" "refs/heads/main" "$C"
run $E/live-profile-2-with-successor.sb "prefix-sharing (v2x)" "refs/heads/$SUCC"x "$C"
run $E/live-profile-2-with-successor.sb "prefix of successor (-v)" "refs/heads/fm/$TASK-v" "$C"
run $E/live-profile-2-with-successor.sb "suffix-sharing (x-...-v2)" "refs/heads/x-$SUCC" "$C"
run $E/live-profile-2-with-successor.sb "sibling in family (-v3)" "refs/heads/fm/$TASK-v3" "$C"
run $E/live-profile-2-with-successor.sb "another task's branch" "refs/heads/fm/labother" "$C"
run $E/live-profile-2-with-successor.sb "archive (own, wrong hex len)" "refs/heads/archive/$TASK-pipeline-6db2" "$C"
echo >> $OUT; echo "## Refs after (successor moved to C by the allowed write; nothing else created)" >> $OUT
$G for-each-ref --format='%(refname) %(objectname)' refs/heads >> $OUT
echo DONE >> $OUT
