#!/usr/bin/env bash
# Round-3 live lab driver: real bin/fm-spawn.sh, real treehouse, real tmux on the
# private fm-lab socket, real claude binary (--version only, no model call),
# real /usr/bin/sandbox-exec. Usage: r2-lab-driver.sh <worktree> <transcript>
set -u
WT_SRC=$1
OUT=$2
cd "$WT_SRC" || exit 1
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
exec > >(tee "$OUT") 2>&1
echo "# Lab home: $LAB (removed at the end of this run)"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset CLAUDE_CONFIG_DIR PI_CODING_AGENT_DIR OMP_PROFILE PI_PROFILE PI_CONFIG_DIR
touch "$LAB/state/.last-watcher-beat"
OTHER=t5r3-other
CT=/private/tmp/claude-$(id -u)

cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null
  rm -rf "$CT/base.$OTHER" "$HOME/tmp/fm-teardown.$OTHER" /private/tmp/fm-$OTHER /tmp/fm-t5r3-* 2>/dev/null
  (cd "$LAB/projects/demo" 2>/dev/null && git worktree prune 2>/dev/null)
  "$WT_SRC/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"
  echo "# teardown done: lab removed=$([ -e "$LAB" ] && echo no || echo yes)"
}
trap cleanup EXIT

# Disposable project with a primary checkout file the probes try to delete.
mkdir -p "$LAB/projects/demo"
git -C "$LAB/projects/demo" init -q -b main
printf 'demo\n' > "$LAB/projects/demo/README.md"
mkdir -p "$LAB/projects/demo/src"; printf 'x\n' > "$LAB/projects/demo/src/a.txt"
git -C "$LAB/projects/demo" add -A
git -C "$LAB/projects/demo" -c user.name=lab -c user.email=lab@lab.invalid commit -q -m init

# Another task's records and temp fixtures (B3, B15, status rewrite).
mkdir -p "$LAB/data/$OTHER"
printf 'worktree=%s\nharness=claude\n' "$LAB/projects/demo-other" > "$LAB/state/$OTHER.meta"
printf 'other-original\n' > "$LAB/state/$OTHER.status"
mkdir -p "$CT/base.$OTHER" && printf 'payload\n' > "$CT/base.$OTHER/payload"
mkdir -p "$HOME/tmp/fm-teardown.$OTHER" && printf 'old\n' > "$HOME/tmp/fm-teardown.$OTHER/old"
touch -t 202001010000 "$HOME/tmp/fm-teardown.$OTHER"
mkdir -p /private/tmp/fm-$OTHER && printf 'fixture\n' > /private/tmp/fm-$OTHER/fixture.txt

brief() {
  mkdir -p "$LAB/data/$1"
  cat > "$LAB/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Exercise OS write confinement for $1 in a disposable lab.

## Firstmate spec
Run only the probe command.
EOF
}

tmux -L fm-lab new-session -d -s primary -c "$WT_SRC" -e FM_HOME="$LAB" bash
export TMUX="$(tmux -L fm-lab display -p '#{socket_path}'),$(tmux -L fm-lab display -p '#{pid}'),0"

spawn() { # id config-root raw
  local id=$1 root=$2 raw=$3
  brief "$id"
  echo; echo "## $id"; echo "CLAUDE_CONFIG_DIR=${root:-<unset>}"; echo "raw launch: $raw"; echo "--- fm-spawn output"
  if [ -n "$root" ]; then
    CLAUDE_CONFIG_DIR=$root bin/fm-spawn.sh "$id" "$LAB/projects/demo" --mode local-only --yolo off --harness "$raw" 2>&1
  else
    bin/fm-spawn.sh "$id" "$LAB/projects/demo" --mode local-only --yolo off --harness "$raw" 2>&1
  fi
  echo "rc=$?"
  echo "--- metadata (selected)"
  grep -E '^(worktree|harness|write_confinement)=' "$LAB/state/$id.meta" 2>&1
}
waitlog() { local f=$1 i; for i in $(seq 1 90); do grep -q DONE "$f" 2>/dev/null && return 0; sleep 1; done; echo "TIMEOUT waiting for $f"; }
modes() { for p in "$@"; do [ -e "$p" ] && echo "$(stat -f %Lp "$p") $p" || echo "missing $p"; done; }

probe() { # log label command
  printf '%s && echo %s=ok >> %s || echo %s=refused >> %s; ' "$3" "$2" "$1" "$2" "$1"
}

# --- A: missing config root + own-root / cross-task probes.
A=t5r3-a; LA="$LAB/data/$A/probes.log"; ROOTA="$LAB/claude-root-missing"
RAW="claude --version; "
RAW+=$(probe "$LA" P1-own-worktree-write "echo w > probe-worktree.txt")
RAW+=$(probe "$LA" P2-own-data-write "echo d > $LAB/data/$A/probe-data.txt")
RAW+=$(probe "$LA" P3-own-status-append "echo appended >> $LAB/state/$A.status")
RAW+=$(probe "$LA" P4e-other-status-whole-rewrite "echo clobber > $LAB/state/$OTHER.status")
RAW+=$(probe "$LA" P5a-B3-rm-other-claude-tmp "rm -rf $CT/base.$OTHER*")
RAW+=$(probe "$LA" P6b-B15-age-sweep-other-home-tmp "find $HOME/tmp -mindepth 1 -maxdepth 1 -name fm-teardown.$OTHER -mtime +1 -exec rm -rf {} +; [ ! -e $HOME/tmp/fm-teardown.$OTHER/old ]")
RAW+=$(probe "$LA" P7c-H3-eval-unlink-primary-checkout "python3 -c 'eval(\"__import__(\\\"pathlib\\\").Path(\\\"$LAB/projects/demo/README.md\\\").unlink()\")'")
RAW+=$(probe "$LA" P8-rm-other-fm-tmp "rm -rf /private/tmp/fm-$OTHER")
RAW+=$(probe "$LA" P9-own-git-commit "git -c user.name=lab -c user.email=lab@lab.invalid commit -q --allow-empty -m probe")
RAW+=$(probe "$LA" P10-own-meta-write "echo x >> $LAB/state/$A.meta")
RAW+=$(probe "$LA" P11-home-config-write "echo x > $LAB/config/probe")
RAW+=$(probe "$LA" P13d-own-nested-claude-worktree-write "mkdir -p .claude/worktrees/fm-nested && echo n > .claude/worktrees/fm-nested/f.txt")
RAW+=$(probe "$LA" P12-own-tmp-write "mkdir -p /tmp/fm-$A/p && echo t > /tmp/fm-$A/p/t")
RAW+="echo DONE >> $LA"
spawn "$A" "$ROOTA" "$RAW"
waitlog "$LA"
echo "--- probes.log (written by the confined worker)"; cat "$LA"
echo "--- missing config root modes after spawn (expect all 700)"
modes "$ROOTA" "$ROOTA/session-env" "$ROOTA/file-history" "$ROOTA/tasks" "$ROOTA/projects"
for d in "$ROOTA"/projects/*; do modes "$d"; done

# --- B: pre-existing 0755 root keeps its mode; created session folders are 700.
B=t5r3-b; ROOTB="$LAB/claude-root-755"
mkdir -p "$ROOTB/unrelated"; chmod 755 "$ROOTB" "$ROOTB/unrelated"
echo; echo "## pre-existing root before $B"; modes "$ROOTB" "$ROOTB/unrelated"
spawn "$B" "$ROOTB" "claude --version"
sleep 3
echo "--- pre-existing 0755 root after spawn (root and unrelated stay 755; created folders 700)"
modes "$ROOTB" "$ROOTB/unrelated" "$ROOTB/session-env" "$ROOTB/file-history" "$ROOTB/tasks" "$ROOTB/projects"
for d in "$ROOTB"/projects/*; do modes "$d"; done

# --- N: missing root whose parents are also missing; an existing ancestor keeps 755.
N=t5r3-n; mkdir -m 755 "$LAB/keep"; ROOTN="$LAB/keep/nest/deeper/claude-root"; LN="$LAB/data/$N/probes.log"
echo; echo "## existing ancestor before $N"; modes "$LAB/keep" "$LAB/keep/nest"
brief "$N"
# The probe runs from a script file because a raw launch refuses shell control structures.
cat > "$LAB/data/$N/probe.sh" <<EOF
for i in \$(seq 1 20); do grep -q ^claude_session_id= $LAB/state/$N.meta 2>/dev/null && break; sleep 1; done
SID=\$(sed -n 's/^claude_session_id=//p' $LAB/state/$N.meta | head -1)
echo sid-present=\${SID:+yes} >> $LN
p() { if sh -c "\$2" 2>/dev/null; then echo \$1=ok >> $LN; else echo \$1=refused >> $LN; fi; }
p S1-own-session-env-write "mkdir -p $ROOTN/session-env/\$SID && echo s > $ROOTN/session-env/\$SID/probe"
p S2-own-file-history-write "mkdir -p $ROOTN/file-history/\$SID && echo s > $ROOTN/file-history/\$SID/probe"
p S3-own-tasks-write "mkdir -p $ROOTN/tasks/\$SID && echo s > $ROOTN/tasks/\$SID/probe"
p S4-foreign-session-env-write "mkdir $ROOTN/session-env/00000000-0000-4000-8000-000000000000"
p S5-root-file-write "echo x > $ROOTN/settings.json"
p S6-chain-parent-file-write "echo x > $LAB/keep/nest/intrude"
echo DONE >> $LN
EOF
RAW="claude --version; sh $LAB/data/$N/probe.sh"
spawn "$N" "$ROOTN" "$RAW"
waitlog "$LN"
echo "--- probes.log (written by the confined worker)"; cat "$LN"
echo "--- nested missing root chain after spawn (expect keep 755; nest, deeper, root and session folders 700)"
modes "$LAB/keep" "$LAB/keep/nest" "$LAB/keep/nest/deeper" "$ROOTN" "$ROOTN/session-env" "$ROOTN/file-history" "$ROOTN/tasks" "$ROOTN/projects"
for d in "$ROOTN"/projects/*; do modes "$d"; done
echo "claude_session_id recorded: $(grep -c '^claude_session_id=' "$LAB/state/$N.meta")"

# --- P: chain where a middle folder already exists at 755; only the missing tail is created 700.
P=t5r3-p; mkdir -p "$LAB/mid"; chmod 755 "$LAB/mid"; ROOTP="$LAB/mid/tail/claude-root"
spawn "$P" "$ROOTP" "claude --version"
sleep 3
echo "--- partial chain after spawn (expect mid 755; tail, root 700)"
modes "$LAB/mid" "$LAB/mid/tail" "$ROOTP" "$ROOTP/session-env"

# --- F: a second confined task attacks task A's roots.
F=t5r3-f; LF="$LAB/data/$F/probes.log"; WTA=$(sed -n 's/^worktree=//p' "$LAB/state/$A.meta" | head -1)
RAW="claude --version; "
RAW+=$(probe "$LF" Q1e-rewrite-task-a-status "echo clobber > $LAB/state/$A.status")
RAW+=$(probe "$LF" Q2-write-task-a-worktree "echo w > $WTA/intrude.txt")
RAW+=$(probe "$LF" Q3-write-task-a-temp "echo w > /tmp/fm-$A/intrude.txt")
RAW+=$(probe "$LF" Q4-write-task-a-data "echo w > $LAB/data/$A/intrude.txt")
RAW+=$(probe "$LF" Q5e-own-status-append "echo probe-f >> $LAB/state/$F.status")
RAW+="echo DONE >> $LF"
spawn "$F" "$ROOTA" "$RAW"
waitlog "$LF"
echo "--- probes.log (written by the confined worker)"; cat "$LF"

# --- Refusals that must stop before launch.
spawn t5r3-r1 "$ROOTA" "[ -d src ] && cd src; claude --version"
spawn t5r3-r2 "$ROOTA" "bash -c 'cd src && claude -p hi'"
spawn t5r3-r3 "$ROOTA" "claude --session-id=11111111-2222-4333-8444-555555555555 --version"
spawn t5r3-r4 "$ROOTA" 'claude $FLAGS --version'
spawn t5r3-r5 "$ROOTA" "[ -d src ] && claude --version"

echo; echo "## after probes"
echo "other status: $(cat "$LAB/state/$OTHER.status")"
echo "task A status: $(cat "$LAB/state/$A.status" 2>&1)"
echo "B3 fixture: $(ls "$CT/base.$OTHER" 2>&1)"
echo "B15 fixture: $(ls "$HOME/tmp/fm-teardown.$OTHER" 2>&1)"
echo "other fm tmp: $(ls /private/tmp/fm-$OTHER 2>&1)"
echo "primary README: $(ls "$LAB/projects/demo/README.md" 2>&1)"
echo "intrusions into A: $(ls "$WTA/intrude.txt" "$LAB/data/$A/intrude.txt" /tmp/fm-$A/intrude.txt 2>&1 | tr '\n' ' ')"
echo "--- spawn-write-confinement guard events"
grep -h '"spawn-write-confinement"' "$LAB"/state/*.jsonl "$LAB"/state/*/*.jsonl 2>/dev/null | sed -E 's/"elapsed_ms":[0-9]+,//'
echo "--- worker panes"
for id in $A $F $B $N $P t5r3-r5; do echo "### pane fm-$id"; tmux -L fm-lab capture-pane -p -t "primary:fm-$id" 2>&1 | grep -v '^$' | tail -25; done
