. "$(cat /tmp/fm-lint-lab-path.txt)/scen.sh"
S="$LAB/pool-cache"; export LAB_CACHE="$LAB/cache"; rm -rf "$S" "$LAB_CACHE"; mkdir -p "$S"
T0=$(now)
echo "== Scenario: cached success bypasses a full host pool; a cold check still waits (cap=1, private cache)"
lint "$S" "$LAB/out-c1.log" "$LAB/fx/c20.sh"; log "warm-up cold lint of c20 exit=$?"
start_hold "$S"; log "test holder now owns the only slot (slot.0)"
s=$(now); lint "$S" "$LAB/out-c2.log" "$LAB/fx/c20.sh"; rc=$?
log "re-lint of unchanged c20 with the pool full: exit=$rc wall=$(perl -e 'printf "%.2f", $ARGV[1]-$ARGV[0]' "$s" "$(now)")s"
lint "$S" "$LAB/out-c3.log" "$LAB/fx/c21.sh" & P=$!
sleep 5
if kill -0 "$P" 2>/dev/null; then log "cold lint of c21 still waiting after 5 s (running shellcheck for c21: $(running_sc c21.sh))"; else log "UNEXPECTED: cold lint of c21 finished while the pool was full"; fi
release_hold "$S"; log "holder released the slot"
wait "$P"; log "cold lint of c21 exit=$?"
