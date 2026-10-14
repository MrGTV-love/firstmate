. "$(cat /tmp/fm-lint-lab-path.txt)/scen.sh"
# cap=2: stop run A's gate while it owns admission.lock, then start 4 more
# real lints (--jobs 2 each, 3 roots each) and sample peak ShellChecks.
S="$LAB/pool-bypass-control"; rm -rf "$S"; mkdir -p "$S"; unset LAB_CACHE
T0=$(now)
echo "== CONTROL (no stopped owner): cap=2; A's gate stopped inside admission.lock; 4 more lints (8 workers) contend"
rm -f "$S.release"; perl "$LAB/hold.pl" "$S/slot.0" "$S.release" > "$S.held" & H1=$!
perl "$LAB/hold.pl" "$S/slot.1" "$S.release" > "$S.held1" & H2=$!
wait_for "grep -q held $S.held && grep -q held $S.held1" 10
FM_LINT_HOST_SLOTS=2 LAB_SLOTS="$S" "$LAB/lint.sh" --jobs 1 "$LAB/fx/c24.sh" > "$LAB/out-bp-A.log" 2>&1 & PA=$!
wait_for "ls $S/queue.0* >/dev/null 2>&1" 30
GA=$(gate_pid "$S")
log "control run: A is NOT stopped"


pids=()
for r in 0 1 2 3; do
  files=(); for i in 1 2 3; do files+=("$LAB/fx/c$((25 + r*3 + i)).sh"); done
  FM_LINT_HOST_SLOTS=2 LAB_SLOTS="$S" "$LAB/lint.sh" --jobs 2 "${files[@]}" > "$LAB/out-bp-$r.log" 2>&1 & pids+=($!)
done
sleep 3
touch "$S.release"; wait "$H1" "$H2"; log "both holders released; 4 lints contend while A stays stopped"
peak=0; samples=0
while :; do alive=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && alive=1; done; [ $alive = 1 ] || break
  n=$(ps -axww -o command= | grep -E '^\S*/shellcheck .*fx/c(2[5-9]|3[0-7])\.sh' | grep -vc grep); [ "$n" -gt "$peak" ] && peak=$n; samples=$((samples+1)); sleep 0.05; done
rcs=""; for p in "${pids[@]}"; do wait "$p"; rcs="$rcs $?"; done
log "4 contending lints finished with exits:$rcs; peak concurrent ShellChecks=$peak over $samples samples (cap=2)"
kill -CONT "$GA"; wait "$PA"; log "A resumed and finished exit=$?"
