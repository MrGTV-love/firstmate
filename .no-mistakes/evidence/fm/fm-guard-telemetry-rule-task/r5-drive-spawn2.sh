#!/usr/bin/env bash
# Real bin/fm-spawn.sh in a marked lab home. Only tmux is a no-op shim, so no real agent launches.
set -u
WT=$PWD; unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID FM_GATE_REFUSE_BYPASS
ERR=$(mktemp); eval "$(bin/fm-lab-home.sh env 2>"$ERR")"
TD=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$ERR" | head -1); rm -f "$ERR"
trap 'eval "$TD" >/dev/null 2>&1' EXIT
LOG=$FM_HOME/state/guard-events.jsonl
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
FB=$(mktemp -d "${TMPDIR:-/tmp}/fm-fb.XXXXXX"); printf '#!/usr/bin/env bash\nexit 0\n' >"$FB/tmux"; chmod +x "$FB/tmux"
P=$FM_HOME/projects/demo; git init -q -b main "$P"; echo x >"$P/x"; git -C "$P" add x; git -C "$P" commit -qm init
SM=$FM_HOME/smhome; git worktree add -q --detach "$SM" HEAD 2>/dev/null || { git init -q -b main "$SM"; git -C "$SM" commit -q --allow-empty -m i; }
printf 'sm\n' >"$SM/.fm-secondmate-home"; mkdir -p "$SM/data"; printf 'charter\n' >"$SM/data/charter.md"
trap 'git worktree remove --force "$SM" 2>/dev/null; git worktree prune; rm -rf "$FB"; eval "$TD" >/dev/null 2>&1' EXIT
run() { local label=$1; shift; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : >"$LOG"; local rc=0
  env -u FM_TASK_ID PATH="$FB:$PATH" TMUX= "${e[@]}" "$WT/bin/fm-spawn.sh" "$@" >"$FM_HOME/out" 2>&1 </dev/null || rc=$?
  echo "== $label: rc=$rc | $(grep -m1 -E '^error' "$FM_HOME/out" | sed "s#$FM_HOME#<lab>#g" | cut -c1-150)"
  jq -c 'select(.decision=="bypass" or .guard=="claude-api-billing")|{guard,decision,rule,task,override,cleared_by}' "$LOG" 2>/dev/null
  echo "   bypass rows: $(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null)"
}
run "secondmate: SYNC=1 INHERIT=1" FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=internal -- sm "$SM" codex --secondmate
run "secondmate: SYNC=internal INHERIT=internal" FM_SKIP_SECONDMATE_SYNC=internal FM_SKIP_SECONDMATE_INHERIT=internal FM_SPAWN_NO_GUARD=internal -- sm "$SM" codex --secondmate
run "api key, --allow-api-key (fake value)" ANTHROPIC_API_KEY=fake-placeholder FM_SPAWN_NO_GUARD=internal -- key1 "$P" claude --allow-api-key --mode no-mistakes --yolo off
mkdir -p "$FM_HOME/config"; echo manual >"$FM_HOME/config/backlog-backend"
run "manual backlog backend" FM_SPAWN_NO_GUARD=internal -- bl1 "$P" codex --mode no-mistakes --yolo off
rm -f "$FM_HOME/config/backlog-backend"
run "default backlog backend" FM_SPAWN_NO_GUARD=internal -- bl2 "$P" codex --mode no-mistakes --yolo off
