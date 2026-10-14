. "$(cat /tmp/fm-lint-lab-path.txt)/scen.sh"
# s-stop.sh <mode: head|coordinator|kill>
mode=$1
S="$LAB/pool-$mode"; rm -rf "$S"; mkdir -p "$S"; unset LAB_CACHE
T0=$(now)
echo "== Scenario ($mode): cap=1; run A queues first and its gate is $( [ "$mode" = kill ] && echo SIGKILLed || echo SIGSTOPped ); run B queues behind it"
start_hold "$S"; log "test holder owns the only slot"
lint "$S" "$LAB/out-$mode-A.log" "$LAB/fx/c22.sh" & PA=$!
wait_for "ls $S/queue.0* >/dev/null 2>&1" 30 || { log "A never queued"; exit 1; }
GA=$(gate_pid "$S" c22); log "run A gate pid=$GA ($(ps -o command= -p "$GA" | cut -c1-60)...) queued: $(cd "$S" && ls queue.0* | tr '\n' ' ')"
case $mode in
  head)
    for i in $(seq 1 500); do kill -STOP "$GA"; admission_free "$S" && break; kill -CONT "$GA"; sleep 0.013; done
    log "A gate stopped OUTSIDE admission.lock: ps stat=$(ps -o stat= -p "$GA")" ;;
  coordinator)
    log "catcher: $(perl "$LAB/catch.pl" "$GA" "$S" 240)"
    admission_free "$S" && { log "could not catch A inside admission.lock"; exit 1; }
    log "A gate stopped WHILE OWNING admission.lock: ps stat=$(ps -o stat= -p "$GA"); admission.lock free? no" ;;
  kill)
    kill -KILL "$GA"; log "A gate SIGKILLed" ;;
esac
lint "$S" "$LAB/out-$mode-B.log" "$LAB/fx/c23.sh" & PB=$!
sleep 4
log "pool still full after 4 s: shellcheck running for B=$(running_sc c23.sh) A=$(running_sc c22.sh) (bound: must be 0 while holder owns the only slot)"
release_hold "$S"; R=$(now); log "holder released the slot"
peak=0
while kill -0 "$PB" 2>/dev/null; do n=$(( $(running_sc c22.sh) + $(running_sc c23.sh) )); [ "$n" -gt "$peak" ] && peak=$n; sleep 0.05; done
wait "$PB"; rb=$?
log "run B exit=$rb, finished $(perl -e 'printf "%.2f", $ARGV[1]-$ARGV[0]' "$R" "$(now)") s after release; A still $( [ "$mode" = kill ] && echo dead || ps -o stat= -p "$GA")"
if [ "$mode" != kill ]; then
  kill -CONT "$GA"; log "A resumed (SIGCONT)"
  while kill -0 "$PA" 2>/dev/null; do n=$(( $(running_sc c22.sh) + $(running_sc c23.sh) )); [ "$n" -gt "$peak" ] && peak=$n; sleep 0.05; done
fi
wait "$PA"; log "run A exit=$?"
log "peak concurrent ShellChecks after release (cap=1): $peak"
log "leftover tickets: $(cd "$S" && ls queue.0* 2>/dev/null | wc -l | tr -d ' ')"
