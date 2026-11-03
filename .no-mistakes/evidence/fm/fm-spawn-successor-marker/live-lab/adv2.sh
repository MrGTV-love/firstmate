. $SB/drv/lib.sh
LIVE=(--mode local-only --yolo off --owned-path README.md --harness "$LAUNCH")
say "NOT ADVERTISED: project proj2 runs Vernant main 1cf0e36bbb provisioner (no --supersedes). Predecessor pred2 spawned with no flag"
brief pred2
TAILN=6 run spawn pred2 "$SB/proj2" "${LIVE[@]}"
note "pred2 branch in record: $(meta pred2 branch); copy HEAD: $(git -C "$(meta pred2 worktree)" symbolic-ref HEAD)"
brief adv2
before=$(snap; ls "$SB/treehouse/.treehouse/"*/ 2>/dev/null)
TAILN=6 run spawn adv2 "$SB/proj2" "${LIVE[@]}" --successor-of pred2
after=$(snap; ls "$SB/treehouse/.treehouse/"*/ 2>/dev/null)
[ "$before" = "$after" ] || diff <(echo "$before") <(echo "$after") | tee -a "$LOG"
note "row=not advertised nonzero=$([ $RC -ne 0 ] && echo yes || echo no) names_project_and_verb=$(grep -q 'project proj2 to advertise --supersedes.*Vernant verb' "$SB/.out" && echo yes || echo no) state+windows+pool_unchanged=$([ "$before" = "$after" ] && echo yes || echo no) adv2_meta_absent=$([ ! -e "$FM_HOME/state/adv2.meta" ] && echo yes || echo no)"
