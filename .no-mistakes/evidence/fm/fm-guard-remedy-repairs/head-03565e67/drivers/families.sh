#!/usr/bin/env bash
# Live drive of each remedy-only refusal family through its real script, in disposable lab homes.
set -u
cd "$1"; EV=$2; WT=$PWD
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
lab() { eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$(cd "$FM_HOME"; pwd -P); BASE=$(mktemp -d /tmp/nm-fam.XXXXXX); BASE=$(cd "$BASE"; pwd -P); }
endlab() { chmod -R u+rwX "$BASE" 2>/dev/null; tmux -L fm-lab kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$BASE"; }
san() { sed -e "s#$LAB#\$LAB#g" -e "s#$BASE#\$BASE#g" -e "s#$WT#\$WT#g" | grep -vE '^●|^fm-gate-refuse|^WARNING: watcher'; }

### merge-local-clean-primary
lab
id=local-merge-dirty; proj=$BASE/proj; mkdir -p "$proj"
git init -q -b main "$proj"; git -C "$proj" config user.email t@e.invalid; git -C "$proj" config user.name t
printf 'base\n' > "$proj/base"; git -C "$proj" add base; git -C "$proj" commit -qm base; base=$(git -C "$proj" rev-parse HEAD)
git -C "$proj" checkout -qb "fm/$id"; printf 'change\n' > "$proj/change"; git -C "$proj" add change; git -C "$proj" commit -qm change; fix=$(git -C "$proj" rev-parse HEAD)
git -C "$proj" checkout -q main
printf 'project=%s\nmode=local-only\n' "$proj" > "$LAB/state/$id.meta"
printf 'owner edit\n' > "$proj/base"; printf 'owner note\n' > "$proj/untracked"
{
echo "## 1. land a local-only task into a primary checkout with the owner's uncommitted work"
echo "\$ FM_HOME=\$LAB bin/fm-merge-local.sh $id"; bin/fm-merge-local.sh "$id" 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$(git -C "$proj" rev-parse HEAD)" = "$base" ] && echo "default branch unmoved: yes"
echo "owner tracked edit: $(cat "$proj/base"); owner untracked file: $(cat "$proj/untracked")"
echo; echo "## 2. completing step: inspect status as printed, owner moves changes to own branch, checkout returns clean, retry"
git -C "$proj" status --short
git -C "$proj" checkout -qb owner/wip; git -C "$proj" add -A; git -C "$proj" commit -qm wip; git -C "$proj" checkout -q main
echo "\$ FM_HOME=\$LAB bin/fm-merge-local.sh $id"; bin/fm-merge-local.sh "$id" 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$(git -C "$proj" rev-parse HEAD)" = "$fix" ] && echo "ship branch landed on main: yes"
echo "owner/wip keeps: base=$(git -C "$proj" show owner/wip:base) untracked=$(git -C "$proj" show owner/wip:untracked)"
} > "$EV/merge-local-clean-primary.txt" 2>&1
endlab

### kimi-hook-install-refusal
lab
H=$BASE/h; mkdir -p "$H/.kimi-code"
{
echo "## 1. malformed config.toml (throwaway HOME)"
printf 'model = "x"\n[broken\n' > "$H/.kimi-code/config.toml"; before=$(shasum "$H/.kimi-code/config.toml")
HOME=$H bin/fm-kimi-turnend-hook.sh install 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$before" = "$(shasum "$H/.kimi-code/config.toml")" ] && echo "config.toml unchanged: yes"; ls -A "$H/.kimi-code"
echo; echo "## 2. partial marker: only BEGIN, no END"
printf 'model = "x"\n# BEGIN FIRSTMATE KIMI TURN-END HOOK\n' > "$H/.kimi-code/config.toml"; before=$(shasum "$H/.kimi-code/config.toml")
HOME=$H bin/fm-kimi-turnend-hook.sh install 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$before" = "$(shasum "$H/.kimi-code/config.toml")" ] && echo "config.toml unchanged: yes"
echo; echo "## 3. owner repairs per the remedy; printed retry succeeds"
printf 'model = "x"\n' > "$H/.kimi-code/config.toml"
HOME=$H bin/fm-kimi-turnend-hook.sh install 2>&1 | san; echo "exit=${PIPESTATUS[0]}"; sed -n 1,9p "$H/.kimi-code/config.toml"
echo; echo "## 4. adversarial: symlinked config.toml"
mv "$H/.kimi-code/config.toml" "$BASE/real.toml"; ln -s "$BASE/real.toml" "$H/.kimi-code/config.toml"
HOME=$H bin/fm-kimi-turnend-hook.sh remove 2>&1 | san; echo "exit=${PIPESTATUS[0]}"; [ -L "$H/.kimi-code/config.toml" ] && echo "symlink preserved: yes"
echo; echo "## 5. HOME unset"
env -u HOME bin/fm-kimi-turnend-hook.sh install 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
} > "$EV/kimi-hook-refusal.txt" 2>&1
endlab

### api-billing-preflight (route) through real fm-spawn + registry
lab
proj=$LAB/projects/alpha; mkdir -p "$proj"; git init -q -b main "$proj"; git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm base
{
echo "## registry entry as consumed: id, sites, invariant, source, trigger, remedy"
jq '.guards[]|select(.id=="api-billing-preflight")|{id,owner,sites,invariant,source,trigger,remedy,test}' docs/guards/registry.json
echo; echo "## site scan maps the refusal to that entry"
python3 bin/fm-guard-sites.py --root . 2>/dev/null | jq -c '.sites[]? | select(.entry=="api-billing-preflight") | {file,line,entry,remedy}' 
echo; echo "## 1. real spawn preflight refuses each billed route with no window opened"
for m in openai/gpt-6.1-sol ' OpenAI / gpt-6.1-sol ' openrouter/vendor/model; do
  echo "\$ bin/fm-spawn.sh bill-probe alpha --harness omp --model '$m'"
  FM_SPAWN_NO_GUARD= bin/fm-spawn.sh bill-probe alpha --harness omp --model "$m" 2>&1 | san | cut -c1-300 | tail -4; echo "exit=${PIPESTATUS[0]}"
done
echo "tmux sessions on lab socket: $(tmux -L fm-lab list-sessions 2>/dev/null | wc -l | tr -d ' ')"; [ -e "$LAB/state/bill-probe.meta" ] && echo "task record: PRESENT" || echo "task record: none"
echo; echo "## 2. adversarial: explicit API-key opt-in does not license the billed omp route"
ANTHROPIC_API_KEY=x OPENAI_API_KEY=x bin/fm-spawn.sh bill-probe alpha --harness omp --model openai/gpt-6.1-sol --allow-api-key 2>&1 | san | cut -c1-300 | tail -3; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 3. the route the remedy names passes the route check"
bash -c '. bin/fm-api-key-guard-lib.sh; fm_omp_api_billing_route_check openai-codex/gpt-6.1-sol; echo "exit=$?"' 2>&1 | san
} > "$EV/api-billing-preflight.txt" 2>&1
endlab

### task-endpoint-identity-binding
lab
T=$LAB/state
V='. bin/fm-backend.sh; fm_backend_validate_task_endpoint "$1" "$2" && echo "accepted: backend=$FM_BACKEND_VALIDATED_BACKEND target=$FM_BACKEND_VALIDATED_TARGET"; echo "exit=$?"'
{
echo "## 1. missing meta"; bash -c "$V" _ "$T/absent.meta" t1 2>&1 | san
echo "## 2. ambiguous window"; printf 'window=s:a\nwindow=s:b\nendpoint_task_id=t1\n' > "$T/t1.meta"; bash -c "$V" _ "$T/t1.meta" t1 2>&1 | san
echo "## 3. adversarial: another task's binding"; printf 'window=s:fm-t2\nendpoint_task_id=t2\n' > "$T/t1.meta"; bash -c "$V" _ "$T/t1.meta" t1 2>&1 | san
echo "## 4. invalid task id"; bash -c "$V" _ "$T/t1.meta" 'bad id' 2>&1 | san
echo "## 5. owner restores the unique fields from launch evidence"; printf 'window=s:fm-t1\nendpoint_task_id=t1\n' > "$T/t1.meta"; bash -c "$V" _ "$T/t1.meta" t1 2>&1 | san
echo; echo "## 6. real caller: fm-control on the task with a foreign binding, then with the restored one"
printf 'window=s:fm-t2\nendpoint_task_id=t2\nkind=ship\nworktree=%s\nproject=%s\nharness=claude\n' "$BASE" "$BASE" > "$T/t1.meta"
bin/fm-control.sh t1 state 2>&1 | san | cut -c1-500; echo "exit=${PIPESTATUS[0]}"
} > "$EV/task-endpoint-identity-binding.txt" 2>&1
endlab

### remote-endpoint-identity (real script; herdr stub logs any call so the proof is 'no endpoint access')
lab
mkdir -p "$BASE/bin" "$LAB/bin" "$LAB/state/parent-route"; : > "$BASE/herdr.log"
printf '#!/usr/bin/env bash\nprintf "herdr %%s\\n" "$*" >> %q\nexit 0\n' "$BASE/herdr.log" > "$BASE/bin/herdr"; chmod +x "$BASE/bin/herdr"
printf rsm > "$LAB/.fm-secondmate-home"; : > "$LAB/AGENTS.md"
M=$LAB/state/parent-route/rsm.meta
{
echo "## 1. foreign backend"
printf 'window=s:fm-rsm\nendpoint_task_id=rsm\nbackend=tmux\n' > "$M"; b=$(shasum "$M")
PATH="$BASE/bin:$PATH" bin/fm-remote-secondmate-control.sh state rsm 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$b" = "$(shasum "$M")" ] && echo "endpoint metadata unchanged: yes"
echo; echo "## 2. adversarial: endpoint truly launched in foreign Herdr session 'default'"
printf 'backend=herdr\nherdr_pane_id=p1\nherdr_workspace_id=w1\nherdr_session=default\nendpoint_task_id=rsm\nwindow=default:p1\n' > "$M"; b=$(shasum "$M")
PATH="$BASE/bin:$PATH" bin/fm-remote-secondmate-control.sh state rsm 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$b" = "$(shasum "$M")" ] && echo "endpoint metadata unchanged: yes"
echo; echo "## 3. missing metadata"; rm -f "$M"
PATH="$BASE/bin:$PATH" bin/fm-remote-secondmate-control.sh capture rsm 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
echo; echo "herdr client calls made while refused: $(wc -l < "$BASE/herdr.log" | tr -d ' ')"; cat "$BASE/herdr.log" | san
} > "$EV/remote-endpoint-identity.txt" 2>&1
endlab

### handoff-queued-only (real bin/fm-backlog-handoff.sh + real tasks-axi)
lab
sub=$BASE/sub; mkdir -p "$sub/state" "$sub/data" "$sub/config" "$sub/projects"; printf design > "$sub/.fm-secondmate-home"; : > "$sub/AGENTS.md"; mkdir -p "$sub/bin"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$sub/data/backlog.md"
printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' "$sub" > "$LAB/data/secondmates.md"
printf 'window=firstmate:fm-design\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\nworktree=%s\n' "$sub" "$sub" > "$LAB/state/design.meta"
cat > "$LAB/data/backlog.md" <<'B'
## In flight
- [ ] busy-item - running elsewhere (repo: alpha)
## Queued
- [ ] ready-item - genuinely queued (repo: alpha)
## Blocked
- [ ] held-item - waiting on a prerequisite (repo: alpha)
## Done
- [x] old-item - finished long ago (repo: alpha)
B
{
echo "## 1. hand off a mix of in-flight, Done, non-queued and queued keys"
b=$(shasum "$LAB/data/backlog.md")
echo "\$ bin/fm-backlog-handoff.sh design busy-item old-item held-item ready-item"
bin/fm-backlog-handoff.sh design busy-item old-item held-item ready-item 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ "$b" = "$(shasum "$LAB/data/backlog.md")" ] && echo "main backlog unchanged: yes"; echo "--- secondmate queued items: $(grep -c '^- \[' "$sub/data/backlog.md")"
echo; echo "## 2. follow the remedy: retry with only the queued key"
bin/fm-backlog-handoff.sh design ready-item 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
echo "--- secondmate backlog:"; cat "$sub/data/backlog.md"; echo "--- main backlog:"; cat "$LAB/data/backlog.md"
} > "$EV/handoff-queued-only.txt" 2>&1
endlab
