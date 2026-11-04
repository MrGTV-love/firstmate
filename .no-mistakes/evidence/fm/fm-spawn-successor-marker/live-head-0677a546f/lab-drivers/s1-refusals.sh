. "$(dirname "$0")/common.sh"
PC=$(sed -n 's/^worktree=//p' "$L/state/nmt-pred-a.meta")
row() { # <label> <setup> <check-setup> <restore> <expect> [extra spawn args]
  local label=$1 setup=$2 chk=$3 restore=$4 expect=$5 before after out rc verdict=PASS
  echo; echo "=== ROW: $label"
  eval "$setup"; eval "$chk" || { echo "  SETUP FAILED"; eval "$restore"; return; }
  brief nmt-succ-x
  before=$(snap)
  out=$(spawn nmt-succ-x --successor-of nmt-pred-a 2>&1); rc=$?
  after=$(snap)
  printf '%s\n' "$out" | grep -v '^fm-gate-refuse' | sed 's/^/  | /'
  echo "  exit=$rc"
  [ "$rc" -ne 0 ] || verdict=FAIL
  printf '%s' "$out" | grep -qF -- "$expect" || { verdict=FAIL; echo "  missing expected text: $expect"; }
  [ "$before" = "$after" ] || { verdict=FAIL; diff <(echo "$before") <(echo "$after") | sed 's/^/  diff /'; }
  [ "$(printf '%s\n' "$out" | grep -c '^error:')" = 1 ] || { verdict=FAIL; echo "  not exactly one error line"; }
  echo "  RESULT: $verdict (nonzero exit, one error line naming the reason; state/, data/, tmux windows, treehouse leases and markers unchanged)"
  eval "$restore"
  rm -rf "$L/data/nmt-succ-x"
}
row 'predecessor copy on another branch' "git -C '$PC' checkout -q -b nmt-elsewhere" "[ \"\$(git -C '$PC' branch --show-current)\" = nmt-elsewhere ]" "git -C '$PC' checkout -q fm/nmt-pred-a && git -C '$PC' branch -q -D nmt-elsewhere" 'is on nmt-elsewhere, not its recorded branch fm/nmt-pred-a'
row 'predecessor copy has a detached HEAD' "git -C '$PC' checkout -q --detach" "! git -C '$PC' symbolic-ref -q HEAD >/dev/null" "git -C '$PC' checkout -q fm/nmt-pred-a" 'has a detached HEAD, not its recorded branch fm/nmt-pred-a'
row 'predecessor copy is gone' "mv '$PC' '$PC.aside'" "[ ! -e '$PC' ]" "mv '$PC.aside' '$PC'" 'is gone; a successor record needs the live predecessor'
row 'predecessor has no task record' "mv '$L/state/nmt-pred-a.meta' '$W/pred.meta.aside'" "[ ! -e '$L/state/nmt-pred-a.meta' ]" "mv '$W/pred.meta.aside' '$L/state/nmt-pred-a.meta'" 'has no task record'
row 'primary checkout runs the pre-verb Vernant provisioner (no --supersedes in --help)' \
  "git -C '$P' checkout -q 79cffb12f2b2fa1e979c8526a47d4e77f9a35c36 -- scripts/git-stability/provision_existing_slot.py" \
  "! grep -q supersedes '$P/scripts/git-stability/provision_existing_slot.py'" \
  "git -C '$P' checkout -q HEAD -- scripts/git-stability/provision_existing_slot.py" \
  "needs the project's primary checkout $P to advertise --supersedes"
echo; echo '=== ROW: flag where it means nothing (--scout, --relaunch, twice, self, id=repo batch)'
brief nmt-succ-x; before=$(snap); verdict=PASS
for args in "$P --scout --successor-of nmt-pred-a" "--relaunch --successor-of nmt-pred-a" "$P --mode local-only --yolo off --successor-of nmt-pred-a --successor-of nmt-pred-a" "$P --mode local-only --yolo off --owned-path README.md --successor-of nmt-succ-x"; do
  echo "+ bin/fm-spawn.sh nmt-succ-x ${args/$P/projects/vernant}"
  out=$("$WT/bin/fm-spawn.sh" nmt-succ-x $args 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^fm-gate-refuse' | sed 's/^/  | /'; echo "  exit=$rc"; [ "$rc" -ne 0 ] || verdict=FAIL
done
brief nmt-succ-y
echo "+ bin/fm-spawn.sh nmt-succ-x=projects/vernant nmt-succ-y=projects/vernant --harness codex --mode local-only --yolo off --successor-of nmt-pred-a"
out=$("$WT/bin/fm-spawn.sh" "nmt-succ-x=$P" "nmt-succ-y=$P" --harness codex --mode local-only --yolo off --successor-of nmt-pred-a 2>&1); rc=$?
printf '%s\n' "$out" | grep -v '^fm-gate-refuse' | sed 's/^/  | /'; echo "  exit=$rc"; [ "$rc" -ne 0 ] || verdict=FAIL
rm -rf "$L/data/nmt-succ-y"
[ "$before" = "$(snap)" ] || verdict=FAIL
echo "  RESULT: $verdict (every call refused; nothing changed)"
rm -rf "$L/data/nmt-succ-x"
