#!/usr/bin/env bash
# live-driver.sh <scratch-root> <tree-root-with-bin> <tree-label> <scenario>...
# Drives the real bin/fm-idle-session-reap.sh and bin/fm-merge-prune.sh from an
# extracted tree against disposable marked lab homes in <scratch-root>.
# The only seam: the teardown bin is a call counter that execs that same tree's
# real bin/fm-teardown.sh cut off right after its FM_IDLE_REAP_ADMISSION block,
# then replays a recorded driver refusal. The real Vernant driver never runs and
# no real pool copy is touched; treehouse, herdr, tmux and the control bin are
# stand-ins first on PATH.
set -u
SCR=$1; TREE=$2; LABEL=$3; shift 3
BIN="$TREE/bin"
NOW=$(date +%s); OLD=$((NOW - 7200))
PR=https://github.com/acme/widget/pull/7
RETAINED=cleanup_ignored_payload_archived_tree_retained
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export FM_MERGE_PRUNE=1
WN=0; FAILS=0

say() { printf '%s\n' "$*"; }
check() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then say "  ok       $1 (got $2)"; else say "  MISMATCH $1: got '$2', want '$3'"; FAILS=$((FAILS + 1)); fi
}

# Cut the real teardown right after its admission block, in the tree under test.
if [ ! -x "$BIN/fm-teardown-admission.sh" ]; then
  awk '{print} /^if \[ "\$\{FM_IDLE_REAP_ADMISSION:-0\}" = 1 \]; then$/ {a=1} a && /^fi$/ {print "\"$LIVE_TRAILER\" \"$ID\"; exit $?"; exit}' \
    "$BIN/fm-teardown.sh" > "$BIN/fm-teardown-admission.sh"
  chmod +x "$BIN/fm-teardown-admission.sh"
  grep -q LIVE_TRAILER "$BIN/fm-teardown-admission.sh" || { say "could not cut the teardown admission"; exit 3; }
fi

make_world() { # <name>
  local seed
  WN=$((WN + 1))
  W="$SCR/worlds/$LABEL-$1-$WN"
  mkdir -p "$W/bin" "$W/fakehome" "$W/archives"
  HOME_DIR=$("$BIN/fm-lab-home.sh" create "$W/home") || { say "lab home failed"; exit 3; }
  W=${HOME_DIR%/home}
  STATE="$HOME_DIR/state"; DATA="$HOME_DIR/data"; POOL="$W/th"; ORIGIN="$W/origin.git"; COPY="$POOL/pool1/1/repo"
  mkdir -p "$POOL/pool1/1"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  git init -q --bare "$ORIGIN"; git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  seed="$W/seed"; git clone -q "$ORIGIN" "$seed" 2>/dev/null; git -C "$seed" checkout -q -b main
  printf '%s\n' '.venv/' '.claude/' > "$seed/.gitignore"; printf 'readme\n' > "$seed/README.md"
  git -C "$seed" add -A; git -C "$seed" commit -q -m base; git -C "$seed" push -q origin main; rm -rf "$seed"
  git clone -q "$ORIGIN" "$W/project" 2>/dev/null
  git -C "$W/project" worktree add -q -b fm/t1 "$COPY" origin/main
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"t1"}]}\n' "$COPY" > "$POOL/pool1/treehouse-state.json"
  printf 'work\n' > "$COPY/work.txt"; git -C "$COPY" add work.txt; git -C "$COPY" commit -q -m "task work"; git -C "$COPY" push -q origin fm/t1
  git -C "$COPY" push -q origin "$(git -C "$COPY" commit-tree 'HEAD^{tree}' -p "$(git -C "$COPY" rev-parse origin/main)" -m "task work (#7)"):refs/heads/main"
  git -C "$COPY" fetch -q origin
  NESTED="$W/nested-copy"; mkdir -p "$NESTED"; git -C "$NESTED" init -q -b main; printf 'n\n' > "$NESTED/README.md"; git -C "$NESTED" add -A; git -C "$NESTED" commit -q -m n
  for s in treehouse herdr tmux control-stub; do
    printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %s "$*" >> "$W_LOG"\nexit 1\n' "$s" > "$W/bin/$s"; chmod +x "$W/bin/$s"
  done
  # teardown-wrap counts every teardown the sweep starts, then runs the real admission.
  cat > "$W/bin/teardown-wrap" <<'SH'
#!/usr/bin/env bash
memo=0; [ ! -e "$FM_HOME/state/.idle-reap/$1.refused" ] || memo=1
printf 'args=%s|admission=%s|prune=%s|memo_at_call=%s\n' "$*" "${FM_IDLE_REAP_ADMISSION:-}" "${FM_IDLE_REAP_MERGE_PRUNE:-}" "$memo" >> "$W_DIR/stub.log"
out=$("$LIVE_BIN/fm-teardown-admission.sh" "$@" 2>&1); rc=$?
printf '%s\n' "$out" >&2
case "$out" in *"automatic reap ineligible"*) printf 'admission=REFUSED: %s\n' "$(printf '%s' "$out" | grep -m1 'automatic reap ineligible' | cut -c1-200)" >> "$W_DIR/admit.log" ;; *) printf 'admission=admitted\n' >> "$W_DIR/admit.log" ;; esac
exit "$rc"
SH
  # The trailer runs once real admission has passed: what the rest of teardown would print.
  cat > "$W/bin/trailer" <<'SH'
#!/usr/bin/env bash
mode=$(cat "$W_DIR/mode")
case "$mode" in
  replay|slow-replay)
    [ "$mode" != slow-replay ] || sleep 4
    n=$(ls "$W_DIR/archives" | wc -l | tr -d ' ')
    cp "$W_DIR/payload.bin" "$W_DIR/archives/archive-$n.tar"
    cat "$W_DIR/replay.txt" >&2; exit 1 ;;
  not-landed) echo "REFUSED: task $1 has work that has not landed" >&2; exit 1 ;;
  pipeline) echo "REFUSED: no-mistakes run for $1 is still parked after axi abort" >&2; exit 1 ;;
  ok)
    copy=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$1.meta")
    st="${copy%/*/*}/treehouse-state.json"; tmp="$st.tmp"
    jq --arg p "$copy" '.worktrees |= map(if .path == $p then (.leased = false | del(.lease_holder)) else . end)' "$st" > "$tmp" && mv -f "$tmp" "$st"
    rm -f "$FM_HOME/state/$1.status" "$FM_HOME/state/$1.meta"; exit 0 ;;
esac
SH
  chmod +x "$W/bin/teardown-wrap" "$W/bin/trailer"
  dd if=/dev/zero of="$W/payload.bin" bs=1024 count=1024 2>/dev/null
  printf 'window=w:t1\nkind=ship\nharness=claude\nbackend=herdr\nworktree=%s\nproject=%s\npr=%s\n' "$COPY" "$W/project" "$PR" > "$STATE/t1.meta"
  printf 'done [at=%s]: PR %s checks green\n' "$OLD" "$PR" > "$STATE/t1.status"
  printf 'g1.1.1\n' > "$STATE/t1.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$STATE/t1.busy-state"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$STATE/t1.pr-poll-merge-notified"
  chmod 0600 "$STATE/t1.pr-poll-merge-notified"
  stamp=$(TZ=UTC0 date -d "@$OLD" +%Y%m%d%H%M.%S 2>/dev/null || TZ=UTC0 date -r "$OLD" +%Y%m%d%H%M.%S)
  TZ=UTC0 touch -t "$stamp" "$STATE/t1.pr-poll-merge-notified"
  : > "$W/stub.log"; : > "$W/admit.log"; : > "$W/tools.log"
  printf 'replay\n' > "$W/mode"
  replay_make "$NESTED"
}

# replay_make <named-copy> [own|foreign|unsaved] [variant]: the recorded incident
# output, with the real slot path swapped for <named-copy> everywhere.
replay_make() {
  python3 -I - "$SCR/incident.log" "$W/replay.txt" "$1" "${2:-own}" "${3:-}" "$RETAINED" <<'PY'
import json, sys
src, dst, named, form, variant, retained = sys.argv[1:7]
real = "/Users/charlesabrooker/.treehouse/vernant-2ee7ec/126/vernant/.claude/worktrees/fm-vernant-d1-intake-limits-estimate-l2"
text = open(src, encoding="utf-8", errors="surrogateescape").read().replace(real, named)
lines = text.rstrip("\n").split("\n")
ref = next(i for i, l in enumerate(lines) if l.startswith("REFUSED:"))
js = next(i for i, l in enumerate(lines) if l.lstrip().startswith('{"allowed":'))
if form == "foreign":
    lines[ref] = lines[ref].replace("own nested copy", "foreign copy")
elif form == "unsaved":
    lines[ref] = lines[ref].split(": full output: ")[0] + ": full output could not be saved under /tmp/data/t1"
if variant == "nested-token":
    d = json.loads(lines[js]); d["reason"] = "different_closeout_refusal_class"; d["inner"] = {"reason": retained}
    lines[js] = "  " + json.dumps(d)
elif variant == "mixed":
    lines.append("REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion.")
elif variant == "broken-json":
    lines[js] = lines[js][:-1]
elif variant == "no-json":
    del lines[js]
elif variant == "exit1":
    lines[ref] = lines[ref].replace("(exit 3)", "(exit 1)")
open(dst, "w", encoding="utf-8", errors="surrogateescape").write("\n".join(lines) + "\n")
PY
}

envrun() {
  env HOME="$W/fakehome" FM_HOME="$HOME_DIR" TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" W_DIR="$W" W_LOG="$W/tools.log" \
    LIVE_BIN="$BIN" LIVE_TRAILER="$W/bin/trailer" \
    FM_IDLE_REAP_TEARDOWN_BIN="$W/bin/teardown-wrap" FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-wrap" \
    FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" FM_MERGE_PRUNE_EXIT_WAIT=0 "$@"
}
idle()  { envrun "$BIN/fm-idle-session-reap.sh" "$@"; }
prune() { envrun "$BIN/fm-merge-prune.sh" "$@"; }

calls() { wc -l < "$W/stub.log" | tr -d ' '; }
wakes() { local n; n=$(grep -cF -- "$COPY" "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "$n"; }
archives() { ls "$W/archives" | wc -l | tr -d ' '; }
rec() { printf '%s/.closeout-retained/t1' "$STATE"; }
has_rec() { [ -e "$(rec)" ] && echo yes || echo no; }
has_memo() { [ -e "$STATE/.idle-reap/t1.refused" ] && echo yes || echo no; }
prec() { sed -n "s/^$1=//p" "$STATE/t1.merge-prune" 2>/dev/null | sed -n 1p; }
age_memo() { [ -e "$STATE/.idle-reap/t1.refused" ] && printf 'fm-idle-reap-refused-v1\n%s\n%s\nold reason\n' "$((NOW - ${1:-100000}))" "$(tail -n 1 "$STATE/t1.status")" > "$STATE/.idle-reap/t1.refused"; return 0; }
due() { [ ! -e "$STATE/t1.merge-prune" ] || { sed 's/^next_at=.*/next_at=0/' "$STATE/t1.merge-prune" > "$STATE/.r.tmp" && mv -f "$STATE/.r.tmp" "$STATE/t1.merge-prune"; }; age_memo "${1:-100000}"; }
arm_run() { [ -e "$STATE/t1.merge-prune" ] || prune arm t1 >/dev/null 2>&1; prune run t1 --now >/dev/null 2>&1; }
show() {
  say "  --- evidence ---"
  say "  teardown calls:"; sed 's/^/    /' "$W/stub.log"
  say "  admission results:"; sed 's/^/    /' "$W/admit.log"
  if [ -e "$(rec)" ]; then say "  record $(rec | sed "s#$SCR#<scratch>#"):"; sed "s#$SCR#<scratch>#; s/^/    /" "$(rec)"; else say "  record: none"; fi
  say "  wake queue rows naming the copy:"; { grep -F -- "$COPY" "$STATE/.wake-queue" 2>/dev/null || true; } | sed "s#$SCR#<scratch>#g; s/^/    /" | cut -c1-320
  say "  stand-in archives on disk: $(archives) ($(du -sk "$W/archives" | cut -f1) KB)"
  say "  copy still exists: $([ -e "$COPY" ] && echo yes || echo no); destroy calls: $(grep -c '^treehouse destroy' "$W/tools.log" 2>/dev/null || true)"
}
start() { say; say "=== [$LABEL] $1"; FAILS=0; }
finish() { show; say "RESULT [$LABEL] $1: $([ "$FAILS" = 0 ] && echo PASS || echo "FAIL ($FAILS mismatches)")"; }

# --- scenarios ----------------------------------------------------------------
s_idle_three_sweeps() { # <form>
  local n="idle-reap ${1}: three sweeps over six hours on an unchanged copy"; start "$n"
  make_world "idle3-$1"; replay_make "$NESTED" "$1"
  idle reap >/dev/null 2>&1
  check "first sweep runs teardown once" "$(calls)" 1
  check "first sweep wrote the record" "$(has_rec)" yes
  age_memo 100000
  idle reap >/dev/null 2>&1
  check "second sweep, memo past six hours: no new teardown" "$(calls)" 1
  local row; row=$(idle scan 2>&1 | grep "^[a-z-]*	t1	")
  say "  scan row: $(printf '%s' "$row" | cut -c1-260)"
  check "scan class" "${row%%	*}" refused
  case "$row" in *"not retried while the copy is unchanged"*) check "scan detail says unchanged and retained" yes yes ;; *) check "scan detail says unchanged and retained" no yes ;; esac
  age_memo 186400
  idle reap >/dev/null 2>&1
  check "third sweep, one more day: no new teardown" "$(calls)" 1
  check "exactly one wake names the copy" "$(wakes)" 1
  check "stand-in archives written" "$(archives)" 1
  finish "$n"
}
s_prune_repeats() { # <form>
  local n="merge-prune ${1}: run --now, run --now, sweep when due on an unchanged copy"; start "$n"
  make_world "prune3-$1"; replay_make "$NESTED" "$1"
  arm_run
  check "first run calls teardown once" "$(calls)" 1
  check "record state" "$(prec state)" retained
  prune run t1 --now >/dev/null 2>&1
  due; prune sweep >/dev/null 2>&1
  due; prune run t1 >/dev/null 2>&1
  check "later attempts: no new teardown" "$(calls)" 1
  check "record state stays" "$(prec state)" retained
  check "copy stays" "$([ -e "$COPY" ] && echo yes || echo no)" yes
  check "exactly one wake names the copy" "$(wakes)" 1
  check "stand-in archives written" "$(archives)" 1
  finish "$n"
}
s_cross() { # <idle-prune|prune-idle>
  local n="both sweeps ($1), then the wake is consumed and both sweep again"; start "$n"
  make_world "cross-$1"
  if [ "$1" = idle-prune ]; then idle reap >/dev/null 2>&1; due; arm_run; else arm_run; due; idle reap >/dev/null 2>&1; fi
  check "one teardown across both sweeps" "$(calls)" 1
  check "one wake across both sweeps" "$(wakes)" 1
  say "  wake-queue before drain:"; sed "s#$SCR#<scratch>#g; s/^/    /" "$STATE/.wake-queue" | cut -c1-320
  : > "$STATE/.wake-queue"
  due; idle reap >/dev/null 2>&1
  due; prune run t1 --now >/dev/null 2>&1
  due; prune sweep >/dev/null 2>&1
  check "after drain: no new teardown" "$(calls)" 1
  check "after drain: no new wake" "$(wakes)" 0
  check "copy stays" "$([ -e "$COPY" ] && echo yes || echo no)" yes
  finish "$n"
}
change_copy() { # <commit|untracked|modified> <dir>
  case "$1" in
    commit) printf 'more\n' > "$2/more.txt"; git -C "$2" add more.txt; git -C "$2" commit -q -m more ;;
    untracked) printf 'new\n' > "$2/new-file.txt" ;;
    modified) printf 'edit\n' >> "$2/README.md" ;;
  esac
}
s_changed_idle() { # <commit|untracked|modified>
  local n="idle-reap: copy changed by $1, retried at once through real admission (fresh memo, same status line)"; start "$n"
  make_world "changed-$1"
  idle reap >/dev/null 2>&1
  check "first sweep runs teardown once" "$(calls)" 1
  local fp1; fp1=$(sed -n 5p "$(rec)")
  check "memo is fresh and on disk" "$(has_memo)" yes
  change_copy "$1" "$COPY"
  idle reap > "$W/reap2.out" 2>&1
  check "second sweep starts teardown" "$(calls)" 2
  check "memo was gone when teardown was called" "$(sed -n 2p "$W/stub.log" | sed 's/.*memo_at_call=//')" 0
  check "real admission on the second call" "$(sed -n 2p "$W/admit.log" | cut -c1-19)" admission=admitted
  check "a new record exists" "$(has_rec)" yes
  check "record has a new fingerprint" "$([ "$(sed -n 5p "$(rec)" 2>/dev/null)" != "$fp1" ] && echo yes || echo no)" yes
  check "two wakes name the copy in all" "$(wakes)" 2
  idle reap >/dev/null 2>&1
  check "next sweep holds the new fingerprint" "$(calls)" 2
  check "no third wake" "$(wakes)" 2
  say "  second sweep rows:"; grep "t1" "$W/reap2.out" | sed "s#$SCR#<scratch>#g; s/^/    /" | cut -c1-260
  finish "$n"
}
s_changed_nested_and_prune() {
  local n="a copy named by the refusal changes: both sweeps retry; merge-prune also retries a changed task copy"; start "$n"
  make_world changed-nested-idle
  idle reap >/dev/null 2>&1
  printf 'x\n' > "$NESTED/new.txt"
  idle reap >/dev/null 2>&1
  check "idle-reap: changed named copy is retried" "$(calls)" 2
  show
  make_world changed-nested-prune
  arm_run
  printf 'x\n' > "$NESTED/new.txt"
  due; prune run t1 >/dev/null 2>&1
  check "merge-prune: changed named copy is retried" "$(calls)" 2
  show
  make_world changed-task-prune
  arm_run
  change_copy commit "$COPY"
  due; prune run t1 >/dev/null 2>&1
  check "merge-prune: new commit is retried" "$(calls)" 2
  check "merge-prune: new refusal raises a second wake" "$(wakes)" 2
  due; prune run t1 >/dev/null 2>&1
  check "merge-prune: new fingerprint is held" "$(calls)" 2
  finish "$n"
}
s_other_class() {
  local n="another refusal class keeps its six-hour retry and makes no record"; start "$n"
  make_world other-idle; printf 'not-landed\n' > "$W/mode"
  idle reap >/dev/null 2>&1
  check "idle-reap: first call" "$(calls)" 1
  check "idle-reap: no record" "$(has_rec)" no
  check "idle-reap: no closeout wake" "$(wakes)" 0
  idle reap >/dev/null 2>&1
  check "idle-reap: fresh memo still holds" "$(calls)" 1
  age_memo 100000; idle reap >/dev/null 2>&1
  check "idle-reap: aged memo retries" "$(calls)" 2
  show
  make_world other-prune; printf 'pipeline\n' > "$W/mode"
  arm_run
  check "merge-prune: first call" "$(calls)" 1
  check "merge-prune: no record" "$(has_rec)" no
  due; prune run t1 >/dev/null 2>&1
  check "merge-prune: due retry runs" "$(calls)" 2
  finish "$n"
}
s_adversarial() { # <variant> <idle|prune>
  local n="adversarial refusal '$1' through $2: no record, no hold"; start "$n"
  make_world "adv-$1-$2"
  case "$1" in
    not-a-repo) mkdir -p "$W/not-a-repo"; replay_make "$W/not-a-repo" ;;
    missing-named) replay_make "$W/no-such-dir" ;;
    missing-task-copy) sed "s#^worktree=.*#worktree=$W/no-such-copy#" "$STATE/t1.meta" > "$STATE/.m" && mv -f "$STATE/.m" "$STATE/t1.meta" ;;
    *) replay_make "$NESTED" own "$1" ;;
  esac
  if [ "$2" = idle ]; then
    idle reap >/dev/null 2>&1; check "first call" "$(calls)" 1
    check "no record" "$(has_rec)" no
    check "no closeout wake" "$(n=$(grep -c 'closeout driver retained' "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "${n:-0}")" 0
    age_memo 100000; idle reap >/dev/null 2>&1; check "due retry runs" "$(calls)" 2
  else
    arm_run; check "first call" "$(calls)" 1
    check "no record" "$(has_rec)" no
    check "no closeout wake" "$(n=$(grep -c 'closeout driver retained' "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "${n:-0}")" 0
    due; prune run t1 >/dev/null 2>&1; check "due retry runs" "$(calls)" 2
  fi
  finish "$n"
}
s_space_path() {
  local n="a refusal-named copy whose path has a space is still recognised and held"; start "$n"
  make_world space
  local sp="$W/nested copy"; mkdir -p "$sp"; git -C "$sp" init -q -b main; printf 'n\n' > "$sp/README.md"; git -C "$sp" add -A; git -C "$sp" commit -q -m n
  replay_make "$sp"
  idle reap >/dev/null 2>&1; age_memo 100000; idle reap >/dev/null 2>&1
  check "one teardown" "$(calls)" 1
  check "one wake" "$(wakes)" 1
  printf 'x\n' > "$sp/new.txt"; idle reap >/dev/null 2>&1
  check "a change in that copy lifts the hold" "$(calls)" 2
  finish "$n"
}
s_success_clears() {
  local n="a teardown that completes clears the record and memo"; start "$n"
  make_world ok-idle
  idle reap >/dev/null 2>&1; check "record after refusal" "$(has_rec)" yes
  printf 'edit\n' >> "$COPY/README.md"; printf 'ok\n' > "$W/mode"
  idle reap >/dev/null 2>&1
  check "idle-reap: retried" "$(calls)" 2
  check "idle-reap: record gone" "$(has_rec)" no
  check "idle-reap: memo gone" "$(has_memo)" no
  show
  make_world ok-prune
  arm_run; check "record after refusal" "$(has_rec)" yes
  printf 'edit\n' >> "$COPY/README.md"; printf 'ok\n' > "$W/mode"
  due; prune run t1 >/dev/null 2>&1
  check "merge-prune: retried" "$(calls)" 2
  check "merge-prune: record gone" "$(has_rec)" no
  finish "$n"
}
s_stale_record() {
  local n="a record whose task is gone is removed by the next reap; a live task keeps its record"; start "$n"
  make_world stale
  idle reap >/dev/null 2>&1
  cp "$(rec)" "$STATE/.closeout-retained/gone"
  rm -rf "$STATE/.idle-reap"
  idle reap >/dev/null 2>&1
  check "stale record removed" "$([ -e "$STATE/.closeout-retained/gone" ] && echo yes || echo no)" no
  check "live record kept" "$(has_rec)" yes
  finish "$n"
}
s_wake_append_fails() { # <idle|prune>
  local n="the wake queue cannot take the wake ($1): raised again once, no second teardown"; start "$n"
  make_world "wakefail-$1"
  mkdir "$STATE/.wake-queue"
  if [ "$1" = idle ]; then idle reap >/dev/null 2>&1; else arm_run; fi
  check "record says wake not sent" "$(sed -n 4p "$(rec)")" wake_sent=0
  rmdir "$STATE/.wake-queue"
  if [ "$1" = idle ]; then idle reap >/dev/null 2>&1; else due; prune run t1 >/dev/null 2>&1; fi
  check "wake raised after repair" "$(wakes)" 1
  check "record says wake sent" "$(sed -n 4p "$(rec)")" wake_sent=1
  if [ "$1" = idle ]; then idle reap >/dev/null 2>&1; else due; prune run t1 >/dev/null 2>&1; fi
  check "no second wake" "$(wakes)" 1
  check "one teardown" "$(calls)" 1
  finish "$n"
}
s_overlap() { # <idle-first|prune-first>
  local n="two sweeps overlap for real ($1, teardown takes 4 s): one attempt and one wake"; start "$n"
  make_world "overlap-$1"; printf 'slow-replay\n' > "$W/mode"
  prune arm t1 >/dev/null 2>&1
  local pid i
  if [ "$1" = idle-first ]; then idle reap >"$W/first.out" 2>&1 & pid=$!; else prune run t1 --now >"$W/first.out" 2>&1 & pid=$!; fi
  for i in $(seq 1 100); do [ -s "$W/stub.log" ] && break; sleep 0.1; done
  check "first sweep is inside teardown" "$(calls)" 1
  if [ "$1" = idle-first ]; then
    prune run t1 --now >"$W/second.out" 2>&1
    say "  merge-prune log tail:"; tail -n 3 "$DATA/t1/merge-prune.log" 2>/dev/null | sed "s#$SCR#<scratch>#g; s/^/    /" | cut -c1-220
  else
    idle reap >"$W/second.out" 2>&1
    say "  idle-reap rows of the second sweep:"; grep t1 "$W/second.out" | sed "s#$SCR#<scratch>#g; s/^/    /" | cut -c1-220
  fi
  check "second sweep did not start a teardown" "$(calls)" 1
  wait "$pid"
  check "record written by the first sweep" "$(has_rec)" yes
  due; idle reap >/dev/null 2>&1; due; prune run t1 --now >/dev/null 2>&1
  check "later sweeps: one teardown in all" "$(calls)" 1
  check "one wake in all" "$(wakes)" 1
  finish "$n"
}
s_lock_dies() {
  local n="a sweep killed while it holds the closeout lock does not block the task for ever"; start "$n"
  make_world lockdead; printf 'slow-replay\n' > "$W/mode"
  prune arm t1 >/dev/null 2>&1
  ( exec_env=1; exec env HOME="$W/fakehome" FM_HOME="$HOME_DIR" TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" W_DIR="$W" W_LOG="$W/tools.log" LIVE_BIN="$BIN" LIVE_TRAILER="$W/bin/trailer" FM_IDLE_REAP_TEARDOWN_BIN="$W/bin/teardown-wrap" FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-wrap" "$BIN/fm-idle-session-reap.sh" reap ) >"$W/first.out" 2>&1 &
  local pid=$!
  local i; for i in $(seq 1 100); do [ -s "$W/stub.log" ] && break; sleep 0.1; done
  kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  sleep 5
  printf 'replay\n' > "$W/mode"
  prune run t1 --now > "$W/after.out" 2>&1
  check "the next sweep recovered the lock and made its attempt" "$(calls)" 2
  check "record exists" "$(has_rec)" yes
  say "  lock dir: $(ls -A "$STATE/.closeout-lock" 2>/dev/null | tr '\n' ' ')"
  finish "$n"
}

for s in "$@"; do
  # shellcheck disable=SC2086
  s_$s
done
