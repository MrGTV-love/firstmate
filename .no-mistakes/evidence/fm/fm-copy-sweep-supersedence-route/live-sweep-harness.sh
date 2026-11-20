#!/usr/bin/env bash
# Live harness: runs the real bin/fm-copy-sweep.sh --apply in throwaway worlds
# (temp FM_HOME, temp Treehouse pool slot with a local bare origin, nested locked
# copies). Vernant's closeout driver and the gh forge are scripted stand-ins
# (hard gate: the real driver may not run against any clone). Usage:
#   EV=<evidence dir> bash live-sweep-harness.sh <worktree>
WT=$1
EV=${EV:?}
TRANSCRIPT=$EV/live-sweep-transcript${ONLY:+-$ONLY}.txt
SUMMARY=$EV/live-sweep-summary${ONLY:+-$ONLY}.txt
: > "$TRANSCRIPT"; : > "$SUMMARY"

check() {  # <scenario> <label> <command...>
  local sc=$1 label=$2; shift 2
  if "$@"; then printf 'PASS | %s | %s\n' "$sc" "$label" >> "$SUMMARY"
  else printf 'FAIL | %s | %s\n' "$sc" "$label" >> "$SUMMARY"; fi
}
gone() { [ ! -e "$(copy_path "$1")" ] && ! registered "$1"; }
kept() { [ -e "$(copy_path "$1")" ] && registered "$1"; }
ncalls() { route_call_count "$1"; }
zero_calls() { [ "$(ncalls "$1")" = 0 ]; }
route_pair() {  # <name> <pr>: one plan + one execute with exact route bindings
  local lines plan execute
  lines=$(route_calls_for "$1")
  [ "$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ')" = 2 ] || return 1
  plan=$(printf '%s\n' "$lines" | sed -n 1p); execute=$(printf '%s\n' "$lines" | sed -n 2p)
  # shellcheck disable=SC2086
  route_argv_check plan "$2" "$W/profiles/$1.json" "$(copy_path "$1")" $plan || return 1
  # shellcheck disable=SC2086
  route_argv_check execute "$2" "$W/profiles/$1.json" "$(copy_path "$1")" $execute
}
out_has() { case "$OUT" in *"$1"*) return 0 ;; esac; return 1; }
line_has() { case "$(route_line_of "$1")" in *"$2"*) return 0 ;; esac; return 1; }

dump() {  # <scenario>
  local m f
  {
    printf '\n======================== %s ========================\n' "$1"
    printf -- '--- $DATA/supersedence-records.tsv (copy, tip, PR, profile)\n'
    sed "s#$W#<world>#g" "$HOMED/data/supersedence-records.tsv" 2>/dev/null || echo '(none)'
    printf -- '--- task records ($FM_HOME/state/*.meta and lane state)\n'
    for m in "$HOMED"/state/*.meta "$W"/lane-*/state/*.meta; do
      [ -f "$m" ] || continue
      printf '%s: %s\n' "${m#"$W"/}" "$(tr '\n' ' ' < "$m" | sed "s#$W#<world>#g")"
    done
    printf -- '--- fake forge answers (state TAB merge commit TAB head branch)\n'
    for f in "$W"/forge/pr-*; do [ -f "$f" ] && printf '%s: %s\n' "${f##*/}" "$(tr '\t' ' ' < "$f")"; done
    printf -- '--- bin/fm-copy-sweep.sh --apply  (exit %s)\n' "$RC"
    printf '%s\n' "$OUT" | sed "s#$W#<world>#g"
    printf -- '--- closeout driver argv log (cwd|argv); one line per driver call\n'
    sed "s#$W#<world>#g" "$W/closeout.log" 2>/dev/null || echo '(empty: the driver was never called)'
    printf -- '--- gh forge reads\n'
    sed "s#$W#<world>#g" "$W/forge/gh.log" 2>/dev/null || echo '(none)'
    printf -- '--- git worktree list of the slot after the run\n'
    git -C "$SLOT" worktree list | sed "s#$W#<world>#g"
  } >> "$TRANSCRIPT"
}

test_live_harness() {
  local sc c before sums
  # S1: valid record, merged PR landed on origin/main -> --pr route plan + execute, released.
  #     Same run: a copy with no record -> plain argv, byte-for-byte the base call.
  if [ "${ONLY:-}" != S6 ]; then
  sc=S1-route-release-and-no-record-plain
  route_world live-s1
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy twin 7
  add_copy plain
  route_lock_dead plain
  route_sweep --apply
  dump "$sc"
  check "$sc" "sweep exit 0" [ "$RC" = 0 ]
  check "$sc" "twin removed and unregistered" gone twin
  check "$sc" "twin reported REMOVED" out_has "REMOVED"$'\t'"$(copy_path twin)"$'\t'
  check "$sc" "twin: exactly one plan and one execute with --pr 7 --supersedence-profile --cleanup-worktree --no-evidence-files (+--execute-cleanup)" route_pair twin 7
  check "$sc" "no-record copy asked exactly '--cleanup-worktree <copy>' (base argv)" [ "$(route_calls_for plain)" = "--cleanup-worktree $(copy_path plain)" ]

  # S2: closed and open PRs with an allowing scripted driver -> kept, no driver call. Control merged -> released.
  sc=S2-closed-and-open-pr-kept
  route_world live-s2
  route_set_pr "$W/forge" 8 CLOSED ""
  route_copy closed 8
  route_set_pr "$W/forge" 9 OPEN ""
  route_copy open 9
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy ctl 7
  route_sweep --apply
  dump "$sc"
  check "$sc" "closed-PR copy kept" kept closed
  check "$sc" "closed-PR copy: driver never called" zero_calls closed
  check "$sc" "open-PR copy kept" kept open
  check "$sc" "open-PR copy: driver never called" zero_calls open
  check "$sc" "merged control released through the route" gone ctl
  check "$sc" "merged control: route argv" route_pair ctl 7

  # S3: merged PR whose merge commit lacks the copy's added line -> kept, no driver call. Twin control routes.
  sc=S3-merge-commit-lacks-copy-lines-kept
  route_world live-s3
  route_content_copy policy 7 policy.txt 'POLICY=base\n' 'POLICY=required\n' 'POLICY=other\n'
  route_content_copy twin 8 twin.txt 'POLICY=base\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n' 'POLICY=required\na\nb\nc\nd\nx=1\n'
  route_sweep --apply
  dump "$sc"
  check "$sc" "copy whose line the merge commit lacks is kept" kept policy
  check "$sc" "that copy: driver never called" zero_calls policy
  check "$sc" "twin whose content landed is released" gone twin
  check "$sc" "twin: route argv" route_pair twin 8

  # S4: the slot's primary checkout is on the PR head branch -> refused before any driver call.
  sc=S4-slot-on-pr-head-branch-refused
  route_world live-s4
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE" "$(git -C "$SLOT" symbolic-ref --short HEAD)"
  route_copy onhead 7
  route_sweep --apply
  dump "$sc"
  check "$sc" "copy kept while slot sits on the PR head branch" kept onhead
  check "$sc" "driver never called" zero_calls onhead
  check "$sc" "report names the head branch" line_has onhead "head"

  # S5: route execute answers 'ignored payload archived, tree retained' -> copy and unique ignored files kept byte for byte.
  sc=S5-retained-ignored-payload-kept
  route_world live-s5
  printf 'unique.dat\nunique-dir/\nunique-link\n' >> "$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)"
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  route_copy pay 7 allowed retained-both
  c=$(copy_path pay)
  route_plant_unique_ignored "$c"
  before=$(route_ignored_digest "$c"); sums=$(route_unique_sums "$c")
  route_sweep --apply
  dump "$sc"
  { printf -- '--- unique ignored files before:\n%s\n--- after:\n' "$sums"; route_unique_sums "$c"; } | sed "s#$W#<world>#g" >> "$TRANSCRIPT"
  check "$sc" "payload copy kept and registered" kept pay
  check "$sc" "unique ignored files byte for byte" route_retained_bytes_ok "$c" "$before" "$sums"
  check "$sc" "route plan+execute were called with route argv" route_pair pay 7

  fi
  # S6: target commit 268a85ec5 - which task records give a copy its landing base. Remote default is main.
  sc=S6-recorded-base-only-released_worktree-at-or-inside-copy
  route_world live-s6
  route_set_pr "$W/forge" 7 MERGED "$ROUTE_MERGE"
  for c in eqrel inside sibling prior split slotroot agree; do route_copy "$c" 7; done
  mkdir -p "$(copy_path inside)/sub" "$(copy_path split)/sub" "$(copy_path sibling)-x"
  fm_write_meta "$HOMED/state/t-eqrel.meta" kind=ship "released_worktree=$(copy_path eqrel)" base_branch=release
  fm_write_meta "$HOMED/state/t-inside.meta" kind=ship "released_worktree=$(copy_path inside)/sub" base_branch=release
  fm_write_meta "$HOMED/state/t-sibling.meta" kind=ship "released_worktree=$(copy_path sibling)-x" base_branch=release
  fm_write_meta "$HOMED/state/t-prior.meta" kind=ship "prior_worktree=$(copy_path prior)" base_branch=release
  fm_write_meta "$HOMED/state/t-split-a.meta" kind=ship "released_worktree=$(copy_path split)" base_branch=main
  fm_write_meta "$HOMED/state/t-split-b.meta" kind=ship "released_worktree=$(copy_path split)/sub" base_branch=release
  fm_write_meta "$HOMED/state/t-slotroot.meta" kind=ship "released_worktree=$SLOT" base_branch=release
  fm_write_meta "$HOMED/state/t-agree.meta" kind=ship "released_worktree=$(copy_path agree)" base_branch=main
  route_sweep --apply
  dump "$sc"
  check "$sc" "released_worktree == copy, base release != remote default main: kept" kept eqrel
  check "$sc" "  ... and no driver call" zero_calls eqrel
  check "$sc" "  ... reason names the disagreement" line_has eqrel "recorded base release disagrees"
  check "$sc" "released_worktree inside copy (copy/sub), base release: counts, kept" kept inside
  check "$sc" "  ... and no driver call" zero_calls inside
  check "$sc" "released_worktree = <copy>-x (string-prefix sibling): does not count, released" gone sibling
  check "$sc" "prior_worktree == copy: held earlier by the classifier as HELD-LIVE-TASK (pre-driver hold), kept" kept prior
  check "$sc" "  ... and no driver call" zero_calls prior
  check "$sc" "  ... class HELD-LIVE-TASK" [ "$(class_of prior)" = HELD-LIVE-TASK ]
  check "$sc" "two counting records disagree (main vs release): kept" kept split
  check "$sc" "  ... and no driver call" zero_calls split
  check "$sc" "  ... reason names the disagreement" line_has split "disagree on the base branch"
  check "$sc" "copy inside a slot root released with base release (no own record): released" gone slotroot
  check "$sc" "released_worktree == copy, base main == remote default (slot-root record base release also present): released via route" route_pair agree 7

  return 0
}

export FM_TEST_ONLY=test_live_harness
cd "$WT" || exit 1
# shellcheck disable=SC1091
. "$WT/tests/fm-copy-sweep.test.sh"
