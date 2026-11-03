#!/usr/bin/env bash
# Evidence harness: real bin/fm-idle-session-reap.sh, real bin/fm-merge-prune.sh
# and real bin/fm-teardown.sh on a marked lab home and a throwaway pool slot.
# Fixture only: the Vernant closeout driver (closeout_pr.py) and the CLIs on the
# fake PATH (treehouse, tmux, gh-axi, gh, no-mistakes). The driver mimics the
# incident: it writes one more tar on each call, prints one big JSON line, exits 3.
CODE=$1
set -u
. "$CODE/tests/fm-teardown-helpers.sh"
export FM_MERGE_PRUNE=1
unset FM_GATE_REFUSE_BYPASS FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$("$CODE/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
trap 'kill -- 0 2>/dev/null; true' TERM
FAILS=0
check() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf '  PASS %s (got %s)\n' "$1" "$2"; else printf '  FAIL %s: got %s, want %s\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi
}
NOW=$(date +%s); OLD=$((NOW-7200))
ID=task-x1
world() { # <name> : fresh pool slot, nested locked copy, task in the lab home
  local name=$1
  dead_launcher_pid
  make_own_locked_copy_case "$name" reverse "$FOREIGN_DEAD_PID"
  C=$FOREIGN_CASE; SLOT=$FOREIGN_SLOT; COPY=$FOREIGN_COPY
  mkdir -p "$C/fakehome"
  rm -rf "$LAB/state"/* "$LAB/state"/.[a-z]* "$LAB/data"/* 2>/dev/null
  mkdir -p "$LAB/state" "$LAB/data"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
  mv "$C/state/$ID.meta" "$LAB/state/$ID.meta"
  printf 'pr=https://github.com/acme/widget/pull/7\nharness=claude\n' >> "$LAB/state/$ID.meta"
  printf 'done [at=%s]: PR checks green\n' "$OLD" > "$LAB/state/$ID.status"
  printf 'g1.1.1\n' > "$LAB/state/$ID.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$LAB/state/$ID.busy-state"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$LAB/state/$ID.pr-poll-merge-notified"
  chmod 0600 "$LAB/state/$ID.pr-poll-merge-notified"
  touch -t "$(date -r "$OLD" +%Y%m%d%H%M.%S)" "$LAB/state/$ID.pr-poll-merge-notified"
  printf 'task=%s\nhome=%s\n' "$ID" "$LAB" > "$C/pool/1/.fm-slot-owner"
  add_gh_pr_merged_for_head "$C" "$(git -C "$C/project" rev-parse main)"
  exclude=$(git -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' .claude/ ignored.dat >> "$exclude"
  head -c 1048576 /dev/zero > "$COPY/ignored.dat"
  printf 'retained\n' > "$C/driver.mode"
  cat > "$C/teardown-counted" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$C/teardown.calls"
exec "$CODE/bin/fm-teardown.sh" "\$@"
SH
  chmod +x "$C/teardown-counted"
  cat > "$SLOT/scripts/git-stability/closeout_pr.py" <<SH
printf '%s\n' "\$*" >> "$C/driver.calls"
mode=\$(cat "$C/driver.mode")
if [ "\$mode" = ok ]; then git worktree unlock "\$2" && git worktree remove --force "\$2"; exit \$?; fi
d="\$PWD/.claude/bug-evidence/worktree-preservation"; mkdir -p "\$d"
tar -cf "\$d/ignored-\$(date +%s)-\$\$.tar" -C "\$2" ignored.dat
echo "env_loading: no .env found; tried in order: /tmp/a/.env" >&2
top=cleanup_ignored_payload_archived_tree_retained; nested=other_nested_reason
[ "\$mode" != other ] || { top=different_closeout_refusal_class; nested=cleanup_ignored_payload_archived_tree_retained; }
python3 -I -c 'import json,sys; print(json.dumps({"allowed":False,"cleanup_command":["git","worktree","remove",sys.argv[1]],"ignored_payload_disposition":{"reason":sys.argv[3]},"ignored_payload_preservation":{"result":{"reason":sys.argv[3]}},"reason":sys.argv[2],"uncovered_paths":["src/module_%d/file_%d.py"%(i,i) for i in range(6000)]}))' "\$2" "\$top" "\$nested"
exit 3
SH
}
fm_env() { env PATH="$C/fakebin:$PATH" HOME="$C/fakehome" NM_HOME="$C/nm" FM_TEARDOWN_VERNANT_PYTHON="$C/vernant-python" FM_IDLE_REAP_TEARDOWN_BIN="$C/teardown-counted" FM_MERGE_PRUNE_TEARDOWN_BIN="$C/teardown-counted" FM_MERGE_PRUNE_EXIT_WAIT=0 "$@"; }
reap() { fm_env "$CODE/bin/fm-idle-session-reap.sh" "$@"; }
prune() { fm_env "$CODE/bin/fm-merge-prune.sh" "$@"; }
age_memo() { printf 'fm-idle-reap-refused-v1\n%s\n%s\nold reason\n' "$((NOW-100000))" "$(tail -n 1 "$LAB/state/$ID.status" 2>/dev/null)" > "$LAB/state/.idle-reap/$ID.refused"; }
due() {
  [ ! -e "$LAB/state/$ID.merge-prune" ] || { sed 's/^next_at=.*/next_at=0/' "$LAB/state/$ID.merge-prune" > "$LAB/state/$ID.mp.tmp"; cat "$LAB/state/$ID.mp.tmp" > "$LAB/state/$ID.merge-prune"; rm -f "$LAB/state/$ID.mp.tmp"; }
  [ ! -e "$LAB/state/.idle-reap/$ID.refused" ] || age_memo
}
tcalls() { [ -e "$C/teardown.calls" ] && wc -l < "$C/teardown.calls" | tr -d ' ' || echo 0; }
landed_new_head() { # move the nested copy to a new landed commit on origin main
  local t="$C/_land"; rm -rf "$t"; git clone -q "$C/origin.git" "$t" 2>/dev/null; git -C "$t" checkout -q main
  git -C "$t" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "landed $RANDOM"; git -C "$t" push -q origin main
  git -C "$C/project" fetch -q origin; git -C "$COPY" reset -q --hard origin/main
  add_gh_pr_merged_for_head "$C" "$(git -C "$COPY" rev-parse HEAD)"
}
calls() { [ -e "$C/driver.calls" ] && wc -l < "$C/driver.calls" | tr -d ' ' || echo 0; }
tars() { ls "$SLOT/.claude/bug-evidence/worktree-preservation" 2>/dev/null | wc -l | tr -d ' '; }
wakes() { local n; n=$(grep -cF "$SLOT" "$LAB/state/.wake-queue" 2>/dev/null) || n=0; printf '%s' "$n"; }
rec() { printf '%s/state/.closeout-retained/%s' "$LAB" "$ID"; }
snap() { printf '  scan: %s\n' "$(reap scan 2>&1 | grep -F "$ID" | cut -c1-200)"; [ ! -e "$LAB/data/$ID/merge-prune.log" ] || { echo "  merge-prune.log:"; tail -n 3 "$LAB/data/$ID/merge-prune.log" | cut -c1-250 | sed 's/^/    /'; }; printf '[%s] teardown_calls=%s driver_calls=%s tars=%s tar_kib=%s wakes=%s record=%s\n' "$1" "$(tcalls)" "$(calls)" "$(tars)" "$(du -sk "$SLOT/.claude/bug-evidence/worktree-preservation" 2>/dev/null | cut -f1)" "$(wakes)" "$([ -e "$(rec)" ] && echo yes || echo no)"; }

echo "=== A. idle-reap only, real teardown, unchanged copy"
world a
out=$(reap reap 2>&1); printf '%s\n' "$out" | cut -c1-260
snap "sweep 1"; check "sweep 1 asks the driver once" "$(calls)" 1
echo "--- real teardown output kept by the driver:"; ls "$LAB/data/$ID"/ | head; 
due; out=$(reap reap 2>&1); snap "sweep 2 (memo older than 6 h)"; check "sweep 2 asks the driver no more" "$(calls)" 1; check "no new archive" "$(tars)" 1
out=$(reap scan 2>&1); printf '%s\n' "$out" | cut -c1-260
due; out=$(reap reap 2>&1); snap "sweep 3 (a further day)"; check "sweep 3 asks the driver no more" "$(calls)" 1; check "one wake" "$(wakes)" 1
echo "--- record:"; [ -e "$(rec)" ] && { ls -l "$(rec)" | cut -d' ' -f1; cat "$(rec)"; }
echo "--- wake rows:"; cut -c1-400 "$LAB/state/.wake-queue" 2>/dev/null
echo "--- drain the wake, sweep again"
: > "$LAB/state/.wake-queue"; due; out=$(reap reap 2>&1); snap "after drain"; check "drained wake stays gone" "$(wakes)" 0; check "drain does not lift the hold" "$(calls)" 1
echo "--- merge-prune after idle-reap on the same task"
: > "$LAB/state/.wake-queue"
prune arm "$ID" 2>&1 | cut -c1-200; prune run "$ID" --now 2>&1 | cut -c1-200; snap "prune run --now"
check "prune asks the driver no more" "$(calls)" 1; check "prune raises no second wake" "$(wakes)" 0
due; prune sweep 2>&1 | cut -c1-200; snap "prune sweep when due"; check "sweep asks the driver no more" "$(calls)" 1
[ -e "$LAB/state/$ID.merge-prune" ] && grep -E '^(state|attempts|reason)=' "$LAB/state/$ID.merge-prune" | cut -c1-200
check "copy stays" "$([ -d "$COPY" ] && echo yes)" yes
echo "--- change the nested copy (new untracked file): teardown runs again, and real teardown itself refuses a dirty copy before the driver"
t0=$(tcalls); : > "$LAB/state/.wake-queue"
printf 'new\n' > "$COPY/new.txt"; due; out=$(reap reap 2>&1); printf '%s\n' "$out" | cut -c1-220; snap "changed status"; check "a changed copy is offered to teardown again" "$(tcalls)" $((t0+1))
echo "--- the same file is removed: the copy reads as the record again"
rm -f "$COPY/new.txt"; t0=$(tcalls); due; out=$(reap reap 2>&1); snap "restored"; check "restored copy is held again" "$(tcalls)" "$t0"; check "no wake for the held fingerprint" "$(wakes)" 0
echo "--- a new landed commit in the nested copy: same class again"
d0=$(calls); landed_new_head; due; out=$(reap reap 2>&1); printf '%s\n' "$out" | cut -c1-220; snap "changed HEAD"; check "a new HEAD reaches the driver again" "$(calls)" $((d0+1)); check "one new wake for the new fingerprint" "$(wakes)" 1
d0=$(calls); due; out=$(reap reap 2>&1); snap "changed HEAD, swept again"; check "the new fingerprint is held" "$(calls)" "$d0"; check "still one new wake" "$(wakes)" 1
echo "--- change once more, and the driver now releases: teardown completes"
printf 'ok\n' > "$C/driver.mode"; landed_new_head; due; out=$(reap reap 2>&1); printf '%s\n' "$out" | cut -c1-260; printf '[released] teardown_calls=%s driver_calls=%s meta=%s record=%s\n' "$(tcalls)" "$(calls)" "$([ -e "$LAB/state/$ID.meta" ] && echo yes || echo no)" "$([ -e "$(rec)" ] && echo yes || echo no)"; check "record cleared" "$([ -e "$(rec)" ] && echo yes || echo no)" no

echo; echo "=== B. merge-prune first, real teardown, then idle-reap"
world b
prune arm "$ID" 2>&1 | cut -c1-200; prune run "$ID" --now 2>&1 | cut -c1-200; snap "prune run 1"; check "first prune asks the driver once" "$(calls)" 1
grep -E '^(state|attempts|reason)=' "$LAB/state/$ID.merge-prune" | cut -c1-200
check "prune state is retained" "$(sed -n 's/^state=//p' "$LAB/state/$ID.merge-prune")" retained
prune run "$ID" --now 2>&1 | cut -c1-200; snap "prune run 2"; check "second run asks no more" "$(calls)" 1
due; prune sweep 2>&1 | cut -c1-200; snap "prune sweep due"; check "sweep asks no more" "$(calls)" 1; check "tars" "$(tars)" 1
due; out=$(reap reap 2>&1); snap "idle-reap after prune"; check "idle-reap asks no more" "$(calls)" 1; check "one wake across both sweeps" "$(wakes)" 1
: > "$LAB/state/.wake-queue"; due; prune sweep >/dev/null 2>&1; due; reap reap >/dev/null 2>&1; snap "after drain"; check "drained wake not raised by either sweep" "$(wakes)" 0; check "no more calls" "$(calls)" 1

echo; echo "=== C. another top-level reason, retained token only nested: real teardown"
world c
printf 'other\n' > "$C/driver.mode"
out=$(reap reap 2>&1); snap "sweep 1"; check "no record" "$([ -e "$(rec)" ] && echo yes || echo no)" no; check "no wake" "$(wakes)" 0
due; out=$(reap reap 2>&1); snap "sweep 2 due"; check "ordinary retry stays" "$(calls)" 2
echo; echo "=== C2. the same other-class refusal through merge-prune first: real teardown"
world c2
printf 'other\n' > "$C/driver.mode"
prune arm "$ID" >/dev/null 2>&1; prune run "$ID" --now >/dev/null 2>&1; snap "prune run 1"; n=$(calls); grep -E '^(state|reason)=' "$LAB/state/$ID.merge-prune" | cut -c1-200
check "prune makes one try" "$n" 1; check "no record" "$([ -e "$(rec)" ] && echo yes || echo no)" no
due; prune sweep >/dev/null 2>&1; snap "prune retry due"; check "prune retries when due" "$(calls)" $((n+1)); check "still no record" "$([ -e "$(rec)" ] && echo yes || echo no)" no

echo; echo "=== D. a closeout refusal next to another refusal line, through a wrapper around real teardown"
world d
cat > "$C/teardown-counted" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$C/teardown.calls"
"$CODE/bin/fm-teardown.sh" "\$@"; rc=\$?
echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." >&2
exit \$rc
SH
out=$(reap reap 2>&1); snap "sweep 1"; check "a mixed refusal makes no record" "$([ -e "$(rec)" ] && echo yes || echo no)" no; check "no closeout wake" "$(wakes)" 0
due; out=$(reap reap 2>&1); snap "sweep 2 due"; check "a mixed refusal keeps its retry" "$(calls)" 2

echo; echo "FAILS=$FAILS"
"$CODE/bin/fm-lab-home.sh" teardown "$LAB" 2>&1 | tail -1
rm -rf "$LAB"
