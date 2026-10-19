#!/usr/bin/env bash
# H1: the same fallback path on a HERDR pane (named non-default lab session via bin/fm-herdr-lab.sh).
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; mkdir -p "$LAB/home/.config"; ln -sfn /Users/charlesabrooker/.config/herdr "$LAB/home/.config/herdr"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SESS=$(cat /Users/charlesabrooker/tmp/.fm-r3-herdr-session)
export HERDR_LAB_SESSION=$SESS HERDR_ORIGINAL_PATH=$PATH
TMUXVAL=
labh() { env PATH="$HERDR_ORIGINAL_PATH" "$REPO/bin/fm-herdr-lab.sh" run "$SESS" "$@"; }
# herdr shim for the fm scripts: every call goes through the guarded lab helper
cat > "$LAB/bin/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
for a in "$@"; do case "$a" in --session|--session=*) exit 9 ;; esac; done
exec env PATH="$HERDR_ORIGINAL_PATH" "$REPO/bin/fm-herdr-lab.sh" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$LAB/bin/herdr"
# herdr-aware recording wrapper around the REAL teardown
cat > "$LAB/bin/teardown-rec" <<'SH'
#!/usr/bin/env bash
id=$1
copy=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta" 2>/dev/null | tail -1)
win=$(sed -n 's/^window=//p' "$FM_HOME/state/$id.meta" 2>/dev/null | tail -1)
pane=${win#*:}
pp=$("$FM_HOME/bin/herdr" pane process-info --pane "$pane" 2>/dev/null | jq -r '.result.process_info.shell_pid // empty')
tree() { [ -n "$pp" ] || return 0; ps -axo pid=,ppid=,comm= 2>/dev/null | awk -v p="$pp" '{par[$1]=$2; c[$1]=$3} END{for(k in par){q=par[k]; for(n=0;n<32&&q>1;n++){ if(q==p){printf "%s(%s) ", k, c[k]; break} q=par[q]}}}'; }
panes() { "$FM_HOME/bin/herdr" pane list 2>/dev/null | jq -r '[.result.panes[]?.pane_id] | join(",")' 2>/dev/null; }
printf 'teardown call: args=[%s] admission=%s copy_present=%s herdr_panes=[%s] pane_shell=%s descendants=[%s]\n' \
  "$*" "${FM_IDLE_REAP_ADMISSION:-}" "$([ -e "$copy" ] && echo yes || echo no)" "$(panes)" "${pp:-none}" "$(tree)" >> "$TD_LOG"
if [ -s "$REFUSE_FLAG" ] && [ -e "$copy" ]; then
  echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." | tee -a "$TD_LOG.out" >&2
  printf 'teardown exit=1 (SEAM refusal) copy_present_after=yes\n' >> "$TD_LOG"
  exit 1
fi
"$REPO/bin/fm-teardown.sh" "$@" 2>&1 | tee -a "$TD_LOG.out"
rc=${PIPESTATUS[0]}
printf 'teardown exit=%s copy_present_after=%s herdr_panes_after=[%s]\n' "$rc" "$([ -e "$copy" ] && echo yes || echo no)" "$(panes)" >> "$TD_LOG"
exit "$rc"
SH
chmod +x "$LAB/bin/teardown-rec"
out_begin H1-herdr-pane-fallback
say "### H1: the idle-shell handling on a HERDR pane (session $SESS, via bin/fm-herdr-lab.sh). Real herdr, real treehouse, real git. Teardown's first answer is the exact 'not landed' line (SEAM); the fallback finds the pane's shell through 'herdr pane process-info', ends the idle treehouse subshell with SIGHUP, and the real treehouse destroys the slot."
id=hd; n=160; W=$LAB/w-$id; mkdir -p "$W/th"; : > "$W/th.log"; : > "$W/td.log"; : > "$W/td.log.out"; : > "$W/ctl.log"
git init -q --bare "$W/origin.git"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
seed=$W/seed; git clone -q "$W/origin.git" "$seed" 2>/dev/null; git -C "$seed" checkout -q -b main
printf '%s\n' '.venv/' 'node_modules/' '.claude/' '*.local' > "$seed/.gitignore"; printf 'readme\n' > "$seed/README.md"
git -C "$seed" add -A; git -C "$seed" commit -q -m base; git -C "$seed" push -q origin main; rm -rf "$seed"
git clone -q "$W/origin.git" "$W/proj" 2>/dev/null; git -C "$W/proj" remote set-head origin main >/dev/null 2>&1 || true
C=$(labh workspace create --cwd "$W/proj" --label "$id" --no-focus) || { say "FAIL workspace create"; exit 1; }
PANEID=$(printf '%s' "$C" | jq -er '.result.root_pane.pane_id'); WSID=$(printf '%s' "$C" | jq -er '.result.workspace.workspace_id'); TABID=$(printf '%s' "$C" | jq -er '.result.tab.tab_id')
say "herdr pane: $PANEID"
labh pane run "$PANEID" "env TREEHOUSE_ROOT=$W/th TH_LOG=$W/th.log HOME=$LAB/home PATH=$LAB/bin:$HERDR_ORIGINAL_PATH treehouse get -b fm/$id" >/dev/null
for i in $(seq 1 90); do WT=$(ls -d "$W"/th/.treehouse/*/*/proj 2>/dev/null | head -1); [ -n "$WT" ] && [ -e "$WT/.git" ] && break; sleep 1; done
WT=$(cd "$WT" && pwd -P); say "slot: $WT"
sleep 3
labh pane run "$PANEID" "sleep 900" >/dev/null; sleep 2
WORKER=$(find_worker "$WT"); say "agent (sleep) pid: $WORKER"
git -C "$WT" config user.name Lab; git -C "$WT" config user.email lab@example.invalid
printf 'work\n' > "$WT/work-$id.txt"; git -C "$WT" add "work-$id.txt"; git -C "$WT" commit -q -m "task work $id"; git -C "$WT" push -q origin "fm/$id" 2>/dev/null
TIP=$(git -C "$WT" rev-parse HEAD); git -C "$W/origin.git" update-ref "refs/pull/$n/head" "$TIP"
sq=$(git -C "$WT" commit-tree 'HEAD^{tree}' -p "$(git -C "$WT" rev-parse origin/main)" -m "task work $id (#$n)"); git -C "$WT" push -q origin "$sq:refs/heads/main" 2>/dev/null; git -C "$WT" fetch -q origin
printf '%s\n' "$TIP" > "$LAB/ghdata/$n.head"
old=$(( $(date +%s) - 7200 )); ts=$(date -r "$old" +%Y%m%d%H%M.%S)
cat > "$STATE/$id.meta" <<EOM
window=$SESS:$PANEID
endpoint_task_id=$id
worktree=$WT
project=$W/proj
kind=ship
mode=no-mistakes
spawn_gen=lab-$id
harness=claude
backend=herdr
pr=https://github.com/acme/widget/pull/$n
pr_head=$TIP
herdr_session=$SESS
herdr_workspace_id=$WSID
herdr_tab_id=$TABID
herdr_pane_id=$PANEID
EOM
printf 'done [at=%s]: PR https://github.com/acme/widget/pull/%s checks green\n' "$old" "$n" > "$STATE/$id.status"
printf 'g1.1.1\n' > "$STATE/$id.busy-gen"; printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" > "$STATE/$id.busy-state"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n%s\n' "$n" > "$STATE/$id.pr-poll-merge-notified"; chmod 0600 "$STATE/$id.pr-poll-merge-notified"; touch -t "$ts" "$STATE/$id.pr-poll-merge-notified"
printf '%s\n' "$WORKER" > "$LAB/workers/$id.pid"
( . "$REPO/bin/fm-wake-lib.sh" 2>/dev/null && fm_treehouse_slot_owner_claim "$WT" "$id" "$LAB" ) >/dev/null 2>&1 || true
PI=$(labh pane process-info --pane "$PANEID" | jq -c '.result.process_info | {shell_pid, procs: [.foreground_processes[] | {pid,name}]}')
say "herdr pane process-info: $PI"
say "pane tree before:"; ps -axo pid=,ppid=,comm= | awk -v p="$(echo "$PI" | jq -r .shell_pid)" '{par[$1]=$2; c[$1]=$3} END{for(k in par){q=par[k]; for(n=0;n<32&&q>1;n++){ if(q==p){print "  " k " <- " par[k] " " c[k]; break} q=par[q]}}}' | tee -a "$OUT"
echo not-landed > "$W/refuse"
prune "$W" arm "$id" --run
for i in $(seq 1 150); do grep -q 'reaped\|retained' "$DATA/$id/merge-prune.log" 2>/dev/null && break; sleep 1; done
sleep 2
dump_world_h() { say "--- prune log:"; sed "s#$LAB#<LAB>#g" "$DATA/$id/merge-prune.log" | tee -a "$OUT"; say "--- treehouse calls:"; sed "s#$LAB#<LAB>#g" "$W/th.log" | tee -a "$OUT"; say "--- teardown calls:"; sed "s#$LAB#<LAB>#g" "$W/td.log" | tee -a "$OUT"; say "--- teardown output:"; sed "s#$LAB#<LAB>#g" "$W/td.log.out" | tee -a "$OUT"; say "--- control calls:"; cat "$W/ctl.log" | tee -a "$OUT"; say "--- wake queue:"; { grep "merge-prune:$id" "$STATE/.wake-queue" 2>/dev/null || echo "(none)"; } | sed "s#$LAB#<LAB>#g" | tee -a "$OUT"; }
dump_world_h
say "--- herdr panes after: $(labh pane list | jq -r '[.result.panes[]?.pane_id] | join(",")')"
check "H1 the herdr pane shell was found via process-info and the first teardown answered 'not landed'" grep -q 'REFUSED: the ship deliverable is not landed' "$W/td.log.out"
check "H1 the finished agent was stopped through the exit verb once" test "$(wc -l < "$W/ctl.log" | tr -d ' ')" = 1
check "H1 slot destroyed by the real treehouse with the reaper's exact call (one destroy)" bash -c "grep -qx 'destroy $WT --include-leased --yes' '$W/th.log' && [ \"\$(grep -c '^destroy ' '$W/th.log')\" = 1 ]"
check "H1 slot gone from disk" test ! -e "$WT"
check "H1 the herdr pane was still open when the second teardown began (only its idle shell ended)" grep -q "copy_present=no herdr_panes=\[.*$PANEID" "$W/td.log"
check "H1 nothing forced" nothing_forced "$id"
check "H1 task record closed, prune record gone" bash -c "[ ! -e '$STATE/$id.meta' ] && [ ! -e '$STATE/$id.merge-prune' ]"
check "H1 no wake" test "$(wake_count "$id")" = 0
finish
