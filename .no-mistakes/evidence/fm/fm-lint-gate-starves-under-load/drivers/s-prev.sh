# Same coordinator drive against the previous commit e2f337f5, but B gets 20 s
# after release before the stopped owner is resumed.
. "$(cat /tmp/fm-lint-lab-path.txt)/scen.sh"
export LINT_BIN="$LAB/prev/bin/fm-lint.sh"
S="$LAB/pool-prev"; rm -rf "$S"; mkdir -p "$S"; T0=$(now)
echo "== (PREVIOUS commit e2f337f5, for contrast) coordinator stop; cap=1"
start_hold "$S"
lint "$S" "$LAB/out-prev-A.log" "$LAB/fx/c22.sh" & PA=$!
wait_for "ls $S/queue.0* >/dev/null 2>&1" 30; GA=$(gate_pid "$S")
log "catcher: $(perl "$LAB/catch.pl" "$GA" "$S" 240)"
lint "$S" "$LAB/out-prev-B.log" "$LAB/fx/c23.sh" & PB=$!
sleep 2; release_hold "$S"; log "holder released the slot"
for i in $(seq 1 200); do kill -0 "$PB" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$PB" 2>/dev/null; then log "run B still blocked 20 s after release (shellcheck running: $(running_sc c23.sh))"; else wait "$PB"; log "run B finished exit=$?"; fi
kill -CONT "$GA"; log "A resumed"; wait "$PB"; log "B exit=$?"; wait "$PA"; log "A exit=$?"
