# Appended to the header of tests/fm-teardown-pool-real-treehouse.test.sh by the evidence run.
# REAL fm-teardown.sh, REAL treehouse on a scratch TREEHOUSE_ROOT. Two real slots:
#   other - leased by another holder, its row names acquisition pane @42 (a passed-over copy)
#   own   - leased by this task's firstmate-skipped:task-x1, its row names pane @41, and a process
#           this driver started itself runs inside it (cwd = the slot), so the copy is busy.
# Prints the real `treehouse status --json` process list, teardown's stderr and the record.
evidence_teardown_busy() {
  local case_dir real th_root log other own state rc=0 bg
  real=$(command -v treehouse 2>/dev/null || true)
  case_dir=$(make_case evidence-busy)
  write_meta "$case_dir" no-mistakes ship
  mkdir -p "$case_dir/data/task-x1"
  th_root="$case_dir/th-root"
  log="$case_dir/treehouse.log"; : > "$log"
  other=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$th_root" "$real" get --lease --lease-holder other-holder 2>/dev/null) || fail "no real slot"
  own=$(cd "$case_dir/project" && TREEHOUSE_ROOT="$th_root" "$real" get --lease --lease-holder firstmate-skipped:task-x1 2>/dev/null) || fail "no second real slot"
  other=$(cd "$other" && pwd -P); own=$(cd "$own" && pwd -P)
  state="$(dirname "$(dirname "$other")")/treehouse-state.json"
  (cd "$own" && exec /bin/sleep 300) &
  bg=$!
  /bin/sleep 1
  printf '%s\tpassed over\tother-holder\t1\t@42\n%s\tdirty_tree\tfirstmate-skipped:task-x1\t1\t@41\n' "$other" "$own" > "$case_dir/data/task-x1/skipped-copies.tsv"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
[ "\${1:-} \${2:-}" != 'return --force' ] || exit 0
TREEHOUSE_ROOT='$th_root' exec '$real' "\$@"
SH
  chmod +x "$case_dir/fakebin/treehouse"
  printf '\n===== real `treehouse status --json` rows (path, lease_holder, processes) with a process of this driver (pid %s) in the own slot =====\n' "$bg"
  (cd "$case_dir/project" && TREEHOUSE_ROOT="$th_root" "$real" status --json 2>&1) | jq -c '.[]? // .worktrees[]? | {path, lease_holder, processes}' 2>&1
  printf '\n===== skipped-copies.tsv BEFORE teardown =====\n'; cat "$case_dir/data/task-x1/skipped-copies.tsv"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  printf '\n===== bin/fm-teardown.sh task-x1 exit %s; stderr lines about skipped copies =====\n' "$rc"
  grep -E 'skipped|record row|leaving|acquisition pane' "$case_dir/stderr"
  printf '\n===== skipped-copies.tsv AFTER teardown =====\n'; cat "$case_dir/data/task-x1/skipped-copies.tsv"
  printf '\n===== returns run by teardown =====\n'; grep '^return' "$log" || echo '(none)'
  printf '\n===== pool leases AFTER =====\n'
  jq -r '.worktrees[] | [.path, (.lease_holder // "-")] | @tsv' "$state"
  kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
  return 0
}
evidence_teardown_busy
