#!/usr/bin/env bash
set -u
cd "$1"; EV=$2; WT=$PWD; ONLY=${3:-all}
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
lab() { eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$(cd "$FM_HOME"; pwd -P); BASE=$(mktemp -d /tmp/nm-fam.XXXXXX); BASE=$(cd "$BASE"; pwd -P); }
endlab() { chmod -R u+rwX "$BASE" "$LAB" 2>/dev/null; [ -n "${TMUX_TMPDIR:-}" ] && tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$BASE"; }
san() { sed -e "s#$LAB#\$LAB#g" -e "s#$BASE#\$BASE#g" -e "s#$WT#\$WT#g" | grep -vE '^●|^fm-gate-refuse|^WARNING: watcher'; }
mkstub() { mkdir -p "$BASE/bin"
cat > "$BASE/stub.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
int main(int argc,char**argv){
  if(argc>1&&(!strcmp(argv[1],"--version")||!strcmp(argv[1],"-v"))){puts("2.1.0 (Claude Code)");return 0;}
  const char*d=getenv("FM_STUB_DIR");char p[1024];snprintf(p,sizeof p,"%s/worker.log",d);
  FILE*f=fopen(p,"a");if(f){fputs("launch",f);for(int i=1;i<argc&&i<4;i++){fputc(' ',f);fputs(argv[i],f);}fputc('\n',f);fclose(f);}
  snprintf(p,sizeof p,"%s/worker.input",d);
  char l[8192];const char*r="\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80";
#define PROMPT printf("\033[2J\033[H%s\n\xe2\x9d\xaf \n%s\n\033[2;3H",r,r);fflush(stdout)
PROMPT;
  while(fgets(l,sizeof l,stdin)){f=fopen(p,"a");if(f){fputs(l,f);fclose(f);}if(!strncmp(l,"/exit",5))return 0;PROMPT;}
  return 0;}
C
cc -O1 -o "$BASE/bin/claude" "$BASE/stub.c" || exit 9
}
want() { [ "$ONLY" = all ] || [ "$ONLY" = "$1" ]; }

if want billing; then
lab
proj=$LAB/projects/alpha; mkdir -p "$proj"; git init -q -b main "$proj"; git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm base
printf -- '- alpha - fixture project (mode: local-only)\n' > "$LAB/data/projects.md"
{
echo "## registry entry as consumed: id, sites, invariant, source, trigger, remedy"
jq '.guards[]|select(.id=="api-billing-preflight")|{id,owner,sites,invariant,source,trigger,remedy,test}' docs/guards/registry.json
echo; echo "## site scan maps the refusal to that entry"
python3 bin/fm-guard-sites.py --root . 2>/dev/null | jq -c '.sites[]? | select(.entry=="api-billing-preflight") | {file,line,entry,remedy}'
echo; echo "## 1. real spawn refuses each billed omp route; no window, no task record"
for m in openai/gpt-6.1-sol ' OpenAI / gpt-6.1-sol ' openrouter/vendor/model; do
  echo "\$ bin/fm-spawn.sh bill-probe alpha --mode local-only --yolo off --harness omp --model '$m'"
  bin/fm-spawn.sh bill-probe alpha --mode local-only --yolo off --harness omp --model "$m" 2>&1 | san | cut -c1-320 | tail -3; echo "exit=${PIPESTATUS[0]}"
done
echo "tmux sessions on lab socket: $(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')"; [ -e "$LAB/state/bill-probe.meta" ] && echo "task record: PRESENT" || echo "task record: none"
echo; echo "## 2. adversarial: an API-key opt-in does not license the billed route"
ANTHROPIC_API_KEY=x OPENAI_API_KEY=x bin/fm-spawn.sh bill-probe alpha --mode local-only --yolo off --harness omp --model openai/gpt-6.1-sol --allow-api-key 2>&1 | san | cut -c1-320 | tail -3; echo "exit=${PIPESTATUS[0]}"
[ -e "$LAB/state/bill-probe.meta" ] && echo "task record: PRESENT" || echo "task record: none"
echo; echo "## 3. the route the remedy names passes the route check"
bash -c '. bin/fm-api-key-guard-lib.sh; fm_omp_api_billing_route_check openai-codex/gpt-6.1-sol; echo "exit=$?"' 2>&1 | san
} > "$EV/api-billing-preflight.txt" 2>&1
endlab
fi

if want endpoint; then
lab
T=$LAB/state; C="worktree=$BASE\nproject=$BASE\n"
V='. bin/fm-backend.sh; fm_backend_validate_task_endpoint "$1" "$2" && echo "accepted: backend=$FM_BACKEND_VALIDATED_BACKEND target=$FM_BACKEND_VALIDATED_TARGET"; echo "exit=$?"'
{
echo "## 1. missing meta"; bash -c "$V" _ "$T/absent.meta" t1 2>&1 | san
echo "## 2. ambiguous window"; printf "window=s:a\nwindow=s:b\nendpoint_task_id=t1\n$C" > "$T/t1.meta"; bash -c "$V" _ "$T/t1.meta" t1 2>&1 | san
echo "## 3. adversarial: another task's binding"; printf "window=s:fm-t2\nendpoint_task_id=t2\n$C" > "$T/t1.meta"; bash -c "$V" _ "$T/t1.meta" t1 2>&1 | san
echo "## 4. invalid task id"; bash -c "$V" _ "$T/t1.meta" 'bad id' 2>&1 | san
echo; echo "## 5. real caller: bin/fm-control.sh on the task with another task's binding"
b=$(shasum "$T/t1.meta")
bin/fm-control.sh t1 interrupt 2>&1 | san | cut -c1-520; echo "exit=${PIPESTATUS[0]}"
[ "$b" = "$(shasum "$T/t1.meta")" ] && echo "meta unchanged: yes"
echo; echo "## 6. owner restores the unique fields from launch evidence; same check accepts"
printf "window=s:fm-t1\nendpoint_task_id=t1\n$C" > "$T/t1.meta"; bash -c "$V" _ "$T/t1.meta" t1 2>&1 | san
} > "$EV/task-endpoint-identity-binding.txt" 2>&1
endlab
fi

if want remote; then
lab
mkdir -p "$BASE/bin" "$LAB/bin" "$LAB/state/parent-route"; : > "$BASE/herdr.log"
printf '#!/usr/bin/env bash\nprintf "herdr %%s\\n" "$*" >> %q\nprintf "{}\\n"\nexit 0\n' "$BASE/herdr.log" > "$BASE/bin/herdr"; chmod +x "$BASE/bin/herdr"
printf rsm > "$LAB/.fm-secondmate-home"; : > "$LAB/AGENTS.md"
M=$LAB/state/parent-route/rsm.meta; C="worktree=$LAB\nproject=$LAB\nendpoint_task_id=rsm\n"
R="backend=herdr\nherdr_workspace_id=w1\nherdr_tab_id=w1:1\nherdr_pane_id=w1:1:1\n"
drive() { PATH="$BASE/bin:$PATH" bin/fm-remote-secondmate-control.sh "$1" rsm 2>&1 | san; echo "exit=${PIPESTATUS[0]}"; }
{
echo "## 1. endpoint on a foreign backend"
printf "window=s:fm-rsm\nbackend=tmux\n$C" > "$M"; b=$(shasum "$M"); drive state
[ "$b" = "$(shasum "$M")" ] && echo "endpoint metadata unchanged: yes"
echo; echo "## 2. adversarial: endpoint truly launched in the foreign Herdr session 'default'"
printf "window=default:w1:1:1\nherdr_session=default\n$R$C" > "$M"; b=$(shasum "$M"); drive state
[ "$b" = "$(shasum "$M")" ] && echo "endpoint metadata unchanged: yes"
echo "herdr client calls so far: $(wc -l < "$BASE/herdr.log" | tr -d ' ')"
echo; echo "## 3. missing metadata"; rm -f "$M"; drive capture
echo; echo "## 4. owner restores the exact binding in session fm-remote; retry passes the identity gate and reaches the client"
printf "window=fm-remote:w1:1:1\nherdr_session=fm-remote\n$R$C" > "$M"; drive state
echo "herdr client calls after restore: $(wc -l < "$BASE/herdr.log" | tr -d ' ')"; head -3 "$BASE/herdr.log" | san
} > "$EV/remote-endpoint-identity.txt" 2>&1
endlab
fi

if want pending; then
lab
sub=$BASE/lsm; mkdir -p "$sub/state" "$sub/data"; printf 'lsm\n' > "$sub/.fm-secondmate-home"
printf 'window=firstmate:fm-lsm\nendpoint_task_id=lsm\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' "$sub" "$sub" "$sub" > "$LAB/state/lsm.meta"
mkstub; export FM_STUB_DIR=$BASE PATH="$BASE/bin:$PATH"
tmux new-session -d -s firstmate -n fm-lsm -c "$sub" -x 120 -y 40 -e PATH="$PATH" -e FM_STUB_DIR="$BASE" bash --noprofile --norc
tmux send-keys -t firstmate:fm-lsm "claude" Enter; sleep 1
corr=$(bash -c '. bin/fm-pending-reply-lib.sh; c=$(fm_pending_reply_create "$1" "$1/state" lsm "/audit the ledger"); fm_pending_reply_prepare_delivery "$1/state" "$c" >/dev/null; printf %s "$c"' _ "$LAB")
{
echo "# local secondmate lsm has a pending-reply whose delivery attempt never resolved (corr=$corr)"
echo "## 1. resend that correlation"
echo "\$ FM_PENDING_REPLY_EXISTING_CORR=$corr bin/fm-send.sh lsm '/audit the ledger'"
FM_PENDING_REPLY_EXISTING_CORR=$corr bin/fm-send.sh lsm "/audit the ledger" 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
echo "inbox records written: $(ls "$LAB/state/lsm.inbox" 2>/dev/null | wc -l | tr -d ' ')"
echo "pane text: [$(tmux capture-pane -p -t firstmate:fm-lsm | grep -c 'audit')] lines with the request"
echo; echo "## 2. printed inspect step"
echo "\$ bin/fm-crew-state.sh lsm"; bin/fm-crew-state.sh lsm 2>&1 | san | cut -c1-200 | head -6; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 3. adversarial: second resend, still unresolved"
FM_PENDING_REPLY_EXISTING_CORR=$corr bin/fm-send.sh lsm "/audit the ledger" 2>&1 | san | cut -c1-140; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 4. the actual correlated report lands in the parent status channel; reconciliation resolves the original"
printf 'done [corr=%s]: audit complete\n' "$corr" >> "$LAB/state/lsm.status"
bash -c '. bin/fm-pending-reply-lib.sh; fm_pending_reply_try_resolve "$1/state" "$2"; echo "try_resolve exit=$?"; rec=$(fm_pending_reply_path "$1/state" "$2"); echo "phase=$(fm_pending_reply_get "$rec" phase)"' _ "$LAB" "$corr" 2>&1 | san
echo; echo "## 5. new work now passes the guard with a fresh correlation (worker is a stand-in pane)"
bin/fm-send.sh lsm "next piece of work" 2>&1 | san | cut -c1-240; echo "exit=${PIPESTATUS[0]}"
ls "$LAB/state/lsm.inbox" 2>/dev/null | sed 's/^/inbox: /'; ls "$LAB/state/pending-replies" | sed 's/^/pending record: /'
} > "$EV/pending-reply-no-duplicate-send.txt" 2>&1
endlab
fi

if want relaunch; then
lab
id=rl-billing-live; proj=$BASE/proj; wt=$BASE/wt
mkdir -p "$proj" "$BASE/bin" "$BASE/real"; git init -q -b main "$proj"; git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm base
git -C "$proj" worktree add -q -b "task-$id" "$wt"
mkstub
export FM_STUB_DIR=$BASE
chmod +x "$BASE/bin/claude"
export PATH="$BASE/bin:$PATH"
mkdir -p "$LAB/data/$id"
printf "# Task\n## Captain's intent\nExercise relaunch for %s.\n\n## Firstmate spec\nPreserve the task.\n" "$id" > "$LAB/data/$id/brief.md"
printf 'window=fmses:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\ntasktmp=/tmp/fm-%s\nmodel=default\neffort=default\n' "$id" "$id" "$wt" "$proj" "$id" > "$LAB/state/$id.meta"
tmux new-session -d -s fmses -n "fm-$id" -c "$wt" -x 120 -y 40 -e PATH="$PATH" -e FM_STUB_DIR="$BASE" bash --noprofile --norc
tmux send-keys -t "fmses:fm-$id" "export PATH=$BASE/bin:\$PATH; claude" Enter; sleep 2
{
echo "# real bin/fm-control.sh, real private-socket tmux pane; the worker process is a stand-in named claude (no model call)"
echo "pane command: $(tmux display-message -p -t "fmses:fm-$id" '#{pane_current_command}')"
echo "## 1. relaunch with ANTHROPIC_API_KEY in the inherited environment"
echo "\$ ANTHROPIC_API_KEY=<set> bin/fm-control.sh $id relaunch --note guarded"
ANTHROPIC_API_KEY=sk-ant-lab-fixture bin/fm-control.sh "$id" relaunch --note guarded 2>&1 | san | sed 's/sk-ant-lab-fixture/<set>/g'; echo "exit=${PIPESTATUS[0]}"
echo "worker command still: $(tmux display-message -p -t "fmses:fm-$id" '#{pane_current_command}')"
echo "lifecycle input sent to worker: $( [ -s "$BASE/worker.input" ] && echo yes || echo no )"
echo; echo "## 2. adversarial: ANTHROPIC_AUTH_TOKEN alone is refused the same way"
ANTHROPIC_AUTH_TOKEN=sk-ant-lab-fixture bin/fm-control.sh "$id" relaunch --note guarded 2>&1 | san | sed 's/sk-ant-lab-fixture/<set>/g' | cut -c1-240; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 3. follow the remedy: remove the credential, retry the printed relaunch"
echo "\$ env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bin/fm-control.sh $id relaunch --note guarded"
env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN bin/fm-control.sh "$id" relaunch --note guarded 2>&1 | san | cut -c1-320; echo "exit=${PIPESTATUS[0]}"
sleep 1; echo "worker launches recorded: $(wc -l < "$BASE/worker.log" | tr -d ' ')"; echo "worker received /exit: $(grep -c '^/exit' "$BASE/worker.input" 2>/dev/null)"
} > "$EV/fm-control-relaunch-billing.txt" 2>&1
endlab
fi
