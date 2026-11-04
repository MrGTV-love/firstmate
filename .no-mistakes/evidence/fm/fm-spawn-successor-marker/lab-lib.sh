# Sourced inside the lab tmux pane. Helpers for the live --successor-of scenarios.
# The lab: FM_HOME is a marked fm-lab home; the project is a lab clone of
# Vernant (origin = a lab bare repo holding Vernant main 06a185533); the pool
# is a real treehouse pool under $WORK/treehouse; the terminal is a real tmux
# server on the lab's private socket; Vernant state goes to $WORK/hookstate.
# The worker agent is an inert raw launch command (sleep), because this change
# never touches the agent path.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6HN2SACGPQ0JDT575QV98KC
P=$FM_HOME/projects/vernant
AGENT='sleep 86400'

mkbrief() { # <id>
  (cd "$FM_HOME" && "$WT/bin/fm-brief.sh" "$1" vernant --mode local-only) >/dev/null || return 1
  python3 - "$FM_HOME/data/$1/brief.md" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", "Lab task for live --successor-of validation. Do nothing.", 1)
t = t.replace("{FIRSTMATE_SPEC}", "Inert lab worker; no work is expected.", 1)
t = t.replace("\n### Out of scope\n", "\n### Out of scope\nNone.\n", 1)
for k, v in {
    "{DOD_CAPABILITY}": "Inert lab worker.",
    "{DOD_MANDATORY_ITEMS}": "M1 Source: lab. Expected: nothing. Verify: nothing. Edge/negative: none. Evidence place: none. Authority: agent",
    "{DOD_SUPPORTING_ITEMS}": "None.",
    "{DOD_HARD_GATES}": "None.",
    "{DOD_HONESTY_RULE}": "Report honestly.",
}.items():
    t = t.replace(k, v, 1)
open(p, "w", encoding="utf-8").write(t)
PY
  (cd "$FM_HOME" && "$WT/bin/fm-tasks-axi.sh" add "$1" "lab $1" --kind ship --repo vernant) >/dev/null || return 1
}

# Every state/data path and checksum, minus the two entry-point telemetry files
# every fm-spawn call touches before its own checks (the gate-containment allow
# event in state/guard-events.jsonl and the watcher-down banner stamp); this lab
# runs no watcher, so those change on every call, refused or not.
snap() { (cd "$FM_HOME" && { find state data -print | sort; find state data -type f -exec cksum {} + | sort; } | grep -v -e 'state/guard-events.jsonl' -e 'state/.guard-watcher-stale-banner'); }
windows() { tmux list-windows -a -F '#{window_name}' 2>/dev/null | sort; }
pool() { (cd "$P" && treehouse status 2>&1); }

spawn() { # <id> [args...]: a real fresh ship spawn
  local id=$1; shift
  echo "\$ bin/fm-spawn.sh $id $P --mode local-only --yolo off --owned-path README.md --harness '$AGENT' $*"
  (cd "$FM_HOME" && "$WT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --owned-path README.md --harness "$AGENT" "$@" 2>&1)
  echo "exit=$?"
}

relaunch() { # <id> [args...]
  local id=$1; shift
  echo "\$ bin/fm-spawn.sh $id --relaunch $*"
  (cd "$FM_HOME" && "$WT/bin/fm-spawn.sh" "$id" --relaunch "$@" 2>&1)
  echo "exit=$?"
}

# A refusal row: the spawn must fail and leave state, data, windows and the pool unchanged.
refusal() { # <label> <spawn|relaunch|raw> args...
  local label=$1 kind=$2 b_snap b_win b_pool a_snap a_win a_pool out; shift 2
  b_snap=$(snap); b_win=$(windows); b_pool=$(pool)
  echo "=== $label"
  case "$kind" in
    spawn) out=$(spawn "$@") ;;
    relaunch) out=$(relaunch "$@") ;;
    raw) echo "\$ bin/fm-spawn.sh $*"; out=$(cd "$FM_HOME" && "$WT/bin/fm-spawn.sh" "$@" 2>&1; echo "exit=$?") ;;
  esac
  printf '%s\n' "$out"
  a_snap=$(snap); a_win=$(windows); a_pool=$(pool)
  [ "$a_snap" = "$b_snap" ] && echo "state/data: unchanged" || { echo "state/data: CHANGED"; diff <(printf '%s\n' "$b_snap") <(printf '%s\n' "$a_snap"); }
  [ "$a_win" = "$b_win" ] && echo "tmux windows: unchanged" || echo "tmux windows: CHANGED"
  [ "$a_pool" = "$b_pool" ] && echo "treehouse pool: unchanged" || echo "treehouse pool: CHANGED"
}

markers() { ls -1 "$CODEX_HOOK_STATE_DIR/worktree-supersedence" 2>/dev/null; }
