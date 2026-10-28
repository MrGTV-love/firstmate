#!/usr/bin/env bash
# Differential behavior driver: real bin/fm-teardown.sh CLI from one tree (A or B),
# fed metadata edge cases for busy_gen / orca_worktree_id. Prints normalized results.
# Usage (run by ab-meta.sh): bash meta-diff-driver.sh <tree>
set -u
TREE=$1
# The helpers resolve ROOT from their own location, so every command is the tree's real bin.
. "$TREE/tests/fm-teardown-helpers.sh"
set +e
norm() { sed -e "s#$TMP_ROOT#<ROOT>#g" -e "s#$TREE#<TREE>#g" -e 's/g[0-9][0-9.a-z-]*[0-9a-f]\{6,\}/<GEN>/g'; }
variant() {  # <name> <meta-tail-writer-fn> <keep-sidecar 0|1>
  local name=$1 fn=$2 keep=$3 case_dir gen rc
  case_dir=$(make_case "v-$name")
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  "$fn" "$case_dir/state/task-x1.meta" "$gen"
  [ "$keep" = 1 ] || rm -f "$case_dir/state/task-x1.busy-gen"
  printf '== variant %s (sidecar kept=%s)\n' "$name" "$keep"
  printf -- '-- meta tail (od -c, gen redacted):\n'
  tail -c 120 "$case_dir/state/task-x1.meta" | sed "s/$gen/<GEN>/g" | od -c | sed -n '1,8p'
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  printf 'exit=%s\n' "$rc"
  printf 'meta_present=%s busy_state_present=%s busy_gen_sidecar_present=%s\n' \
    "$([ -e "$case_dir/state/task-x1.meta" ] && echo 1 || echo 0)" \
    "$([ -e "$case_dir/state/task-x1.busy-state" ] && echo 1 || echo 0)" \
    "$([ -e "$case_dir/state/task-x1.busy-gen" ] && echo 1 || echo 0)"
  printf -- '-- stderr:\n'; sed "s/$gen/<GEN>/g" "$case_dir/stderr" | norm
  printf -- '-- stdout:\n'; sed "s/$gen/<GEN>/g" "$case_dir/stdout" | norm
}
w_exact()        { printf 'busy_gen=%s\n' "$2" >> "$1"; }
w_last_match()   { printf 'busy_gen=stale-gen\nbusy_gen=%s\n' "$2" >> "$1"; }
w_last_bogus()   { printf 'busy_gen=%s\nbusy_gen=stale-gen\n' "$2" >> "$1"; }
w_empty()        { printf 'busy_gen=\n' >> "$1"; }
w_absent()       { :; }
w_cr()           { printf 'busy_gen=%s\r\n' "$2" >> "$1"; }
w_eq_bslash()    { printf 'busy_gen=%s=x\\y\n' "$2" >> "$1"; }
w_unterminated() { printf 'busy_gen=%s' "$2" >> "$1"; }
w_orca_id()      { printf 'busy_gen=%s\norca_worktree_id=a=b\\c\r\norca_worktree_id=last::/x\n' "$2" >> "$1"; }
variant exact w_exact 0
variant exact-with-sidecar w_exact 1
variant last-match-wins w_last_match 1
variant last-bogus-wins w_last_bogus 1
variant empty-falls-back-to-sidecar w_empty 1
variant empty-no-sidecar w_empty 0
variant absent-falls-back-to-sidecar w_absent 1
variant absent-no-sidecar w_absent 0
variant carriage-return w_cr 1
variant equals-backslash w_eq_bslash 1
variant unterminated-final-line w_unterminated 1
variant orca-id-non-orca-backend w_orca_id 1
