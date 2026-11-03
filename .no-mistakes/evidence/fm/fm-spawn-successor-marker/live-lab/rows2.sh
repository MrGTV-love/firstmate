. $SB/drv/lib.sh
brief adv
row() {
  local label=$1 expect=$2 before after ok=yes; shift 2
  say "REFUSAL ROW: $label"
  before=$(snap); TAILN=6 run spawn "$@"; after=$(snap)
  [ "$RC" -ne 0 ] || ok=no
  grep -q -- "$expect" "$SB/.out" || ok=no
  [ "$before" = "$after" ] || { ok=no; diff <(echo "$before") <(echo "$after") | tee -a "$LOG"; }
  note "row=$label nonzero=$([ $RC -ne 0 ] && echo yes || echo no) message_ok=$(grep -q -- "$expect" "$SB/.out" && echo yes || echo no) state+windows+pool_unchanged=$([ "$before" = "$after" ] && echo yes || echo no) RESULT=$ok"
}
LIVE=(--mode local-only --yolo off --owned-path README.md --harness "$LAUNCH")
row 'no predecessor record' 'has no task record' adv "$SB/proj" "${LIVE[@]}" --successor-of nosuchtask
row 'with --scout' 'not a scout' adv "$SB/proj" --scout --owned-path README.md --harness "$LAUNCH" --successor-of pred
row 'with --relaunch on admitted succ' 'only to a fresh ship spawn; a retained refusal keeps its declaration' succ --relaunch --successor-of pred
row 'with --secondmate' 'not a secondmate' mate2 --secondmate --successor-of pred
