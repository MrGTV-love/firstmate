# evidence_dump: uses the caller's label, id, get2, REAL_TMUX, FM_HOME (dynamic scope of run_passover_inflight_case).
evidence_dump() {
  local w
  printf '===== [%s] second get pid %s still in the process table right after the spawn exits: ' "$label" "$get2"
  if ps -p "$get2" >/dev/null 2>&1; then echo yes; else echo no; fi
  w=$("$REAL_TMUX" list-windows -a -F '#{window_id} #{window_name}' | awk -v n="fm-$id" '$2 == n { print $1 }')
  printf '===== [%s] acquisition window still open: %s; pane current path: %s\n' "$label" "${w:-NONE}" \
    "$("$REAL_TMUX" display-message -p -t "$w" '#{pane_current_path}' 2>/dev/null)"
  printf '===== [%s] data/%s/acquisition-pane.tsv =====\n' "$label" "$id"
  cat "$FM_HOME/data/$id/acquisition-pane.tsv" 2>&1
  printf '===== [%s] data/%s/skipped-copies.tsv =====\n' "$label" "$id"
  cat "$FM_HOME/data/$id/skipped-copies.tsv" 2>&1
}
