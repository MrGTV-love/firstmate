home=$(make_home live-teardown-written-row)
write_fixture "$home"
fakebin=$(make_fakebin "$home")
# Replace the fixture backlog's Done section with the row real fm-teardown.sh wrote, plus a real local-main delivery.
cp "$LIVE_EVID/s1-backlog-after.md" "$home/data/backlog.md"
"$TASKS_AXI_BIN" add real-local "Land the local change" --kind ship --repo firstmate --start --file "$home/data/backlog.md" >/dev/null || fail "add real-local"
"$TASKS_AXI_BIN" 'done' real-local --note "local main" --file "$home/data/backlog.md" >/dev/null || fail "done real-local"
: > "$home/net.log"
fleet_json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-10-19T18:00:00Z NET_LOG="$home/net.log" "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "snapshot failed"
printf '%s' "$fleet_json" | jq '.backlog.records | map(select(.id=="task-x1" or .id=="real-local") | {id,state,captain_drop,pr_url,report_path})' | tee "$LIVE_EVID/snapshot-records.json"
json=$(run "$home" "$fakebin" --json --all-landed) || fail "bearings failed"
printf '%s' "$json" | jq '{landed: [.landed[] | {id, artifact}]}' | tee "$LIVE_EVID/bearings-landed.json"
printf '%s' "$json" | jq -e '(.landed | any(.id=="task-x1") | not) and (.landed | any(.id=="real-local" and .artifact=="local main"))' >/dev/null && echo "SNAP-OK: bundle-closed row absent from landed; real delivery present" || { echo "SNAP-FAIL"; exit 1; }
