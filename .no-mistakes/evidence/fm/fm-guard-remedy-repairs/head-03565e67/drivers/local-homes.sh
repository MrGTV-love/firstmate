#!/usr/bin/env bash
# Live drive: real bin/fm-teardown.sh in marked lab home with one unreadable registered home.
set -u
cd "$1"; EV=$2; WT=$PWD
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
BASE=$(mktemp -d /tmp/nm-lh.XXXXXX); BASE=$(cd "$BASE"; pwd -P); LAB=$(cd "$FM_HOME"; pwd -P)
san() { sed -e "s#$LAB#\$LAB#g" -e "s#$BASE#\$BASE#g" -e "s#$WT#\$WT#g" | grep -vE '^●'; }
id=lab-unreadable-home
mate=$BASE/mate; hidden=$BASE/hidden; proj=$BASE/project
for h in "$mate" "$hidden"; do mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"; done
mkdir -p "$proj" "$BASE/pool/1"
git init -q "$proj"; git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm base
git -C "$proj" worktree add -q --detach "$BASE/pool/1/project"
printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"fixture"}]}\n' "$BASE/pool/1/project" > "$BASE/pool/treehouse-state.json"
copy=$BASE/pool/1/project; : > "$copy/sentinel"
printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$mate" > "$LAB/data/secondmates.md"
reg=$mate/data/secondmates.md
printf -- '- hidden - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$hidden" > "$reg"
printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\n' "$id" "$id" "$copy" "$proj" > "$LAB/state/$id.meta"
# stub only for the pool allocator and session runtime: real ones are never touched
mkdir -p "$BASE/fakebin"
for s in treehouse tmux; do printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >> %q/runtime.log\nexit 0\n' "$s" "$BASE" > "$BASE/fakebin/$s"; chmod +x "$BASE/fakebin/$s"; done
: > "$BASE/runtime.log"
export PATH="$BASE/fakebin:$PATH"
{
echo "# lab home \$LAB, child home \$BASE/mate registers \$BASE/hidden; \$BASE/mate/data/secondmates.md is chmod 000"
chmod 000 "$reg"
echo "## 1. teardown while one registered home is unreadable"
echo "\$ FM_HOME=\$LAB bin/fm-teardown.sh $id"
bin/fm-teardown.sh "$id" 2>&1 | san; echo "exit=${PIPESTATUS[0]}"
[ -f "$LAB/state/$id.meta" ] && echo "task record preserved: yes"; [ -f "$copy/sentinel" ] && echo "worktree preserved: yes"
echo "runtime calls: $(wc -l < "$BASE/runtime.log" | tr -d ' ')"
echo; echo "## 2. adversarial: --force does not skip the unreadable home"
printf 'captain words: discard for the lab probe\n' > "$BASE/drop.txt"
bin/fm-teardown.sh "$id" --force --drop-file "$BASE/drop.txt" 2>&1 | san | cut -c1-260; echo "exit=${PIPESTATUS[0]}"
[ -f "$LAB/state/$id.meta" ] && echo "task record preserved: yes"; [ -f "$copy/sentinel" ] && echo "worktree preserved: yes"
echo "runtime calls: $(wc -l < "$BASE/runtime.log" | tr -d ' ')"
echo; echo "## 3. owner restores read access; the walk now enumerates every descendant, none skipped"
chmod 600 "$reg"
bash -c '. bin/fm-secondmate-registry-lib.sh; . bin/fm-wake-lib.sh; fm_local_firstmate_state_dirs "$FM_HOME/state" && printf "state dir: %s\n" "${FM_LOCAL_FIRSTMATE_STATES[@]}"; echo "exit=$?"' 2>&1 | san
echo; echo "## 4. the printed retry no longer hits the home refusal (next gate is the scout's own work product)"
bin/fm-teardown.sh "$id" 2>&1 | san | cut -c1-220; echo "exit=${PIPESTATUS[0]}"
mkdir -p "$LAB/data/$id"; printf 'report\n' > "$LAB/data/$id/report.md"
echo "\$ bin/fm-captain-hold.sh complete $id --none (the next gate teardown names)"
bin/fm-captain-hold.sh complete "$id" --none 2>&1 | san | cut -c1-200; echo "exit=${PIPESTATUS[0]}"
bin/fm-teardown.sh "$id" 2>&1 | san | cut -c1-260; echo "exit=${PIPESTATUS[0]}"
[ -f "$LAB/state/$id.meta" ] && echo "task record still present" || echo "task record removed by completed teardown"
echo "runtime calls:"; san < "$BASE/runtime.log" | cut -c1-200

echo; echo "## 5. malformed entry in the registered home"
id2=lab-malformed-home; printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\n' "$id2" "$id2" "$copy" "$proj" > "$LAB/state/$id2.meta"
printf -- '- hidden - malformed row without home\n' > "$reg"
bin/fm-teardown.sh "$id2" 2>&1 | san | cut -c1-420; echo "exit=${PIPESTATUS[0]}"
printf -- '- hidden - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' "$hidden" > "$reg"

echo; echo "## 6a. root home unresolvable, non-pool task copy: corrupt parent binding; remedy names the binding"
id3=lab-root-unresolved; plain=$BASE/plain-copy; git -C "$proj" worktree add -q --detach "$plain"
printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=scout\n' "$id3" "$id3" "$plain" "$proj" > "$LAB/state/$id3.meta"
mkdir -p "$LAB/data/$id3"; printf 'report\n' > "$LAB/data/$id3/report.md"; bin/fm-captain-hold.sh complete "$id3" --none >/dev/null 2>&1
printf 'route=nowhere\n' > "$LAB/.fm-secondmate-parent"
bin/fm-teardown.sh "$id3" 2>&1 | san ; echo "exit=${PIPESTATUS[0]}"
[ -f "$LAB/state/$id3.meta" ] && echo "task record preserved: yes"
echo; echo "## 6b. same corrupt binding, pool-slot task: project-lock gate fires first (unchanged legacy text)"
bin/fm-teardown.sh "$id2" 2>&1 | san | cut -c1-300; echo "exit=${PIPESTATUS[0]}"
echo; echo "## 7. owner restores the binding (this lab home has none originally); retry passes the home gate"
rm -f "$LAB/.fm-secondmate-parent"
bin/fm-teardown.sh "$id3" 2>&1 | san | cut -c1-260; echo "exit=${PIPESTATUS[0]}"
[ -f "$LAB/state/$id3.meta" ] && echo "task record still present" || echo "task record removed by completed teardown"
echo "runtime calls:"; san < "$BASE/runtime.log" | cut -c1-200
} > "$EV/local-homes-unproved-teardown.txt" 2>&1
chmod -R u+rwX "$BASE" 2>/dev/null
bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB" "$BASE"
