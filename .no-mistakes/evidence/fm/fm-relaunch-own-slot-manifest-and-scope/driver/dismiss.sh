# dismiss_mcp_dialog: wait up to 90s for the worker's graft MCP dialog and accept its default (continue without)
dismiss_mcp_dialog() {
  local i
  for i in $(seq 1 45); do
    if lt capture-pane -p -t firstmate:fm-$WID | grep -q 'Continue without using this MCP server'; then
      lt send-keys -t firstmate:fm-$WID Enter; echo "(lab: dismissed the graft MCP dialog with its default)"; return 0
    fi
    sleep 2
  done
  echo "(lab: no MCP dialog seen)"
}
wait_idle() { sleep "${1:-40}"; }
