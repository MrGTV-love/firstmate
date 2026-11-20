#!/bin/bash
# Driver: runs the real fm-task-inbox-lib.sh (base or head copy) against scratch inboxes.
# usage: drv.sh <S> <head|base> <mode> [args]
#   count <N>            launch counts of awk/cat/cmp/grep for one idempotent write behind N handled records
#   time <N>             wall time (ms) for one idempotent write behind N handled records (best of 3)
#   cases                DD2 paired dedup outcomes; prints one block per case
#   signal <TERM|INT|KILL> DD3 kill during the compare, then the next call
set -u
S=$1; SIDE=$2; MODE=$3; ARG=${4:-}
LIB="$S/$SIDE/bin/fm-task-inbox-lib.sh"
RUN="$S/run-$SIDE-$MODE-$ARG"
SHIM="$S/shim-$SIDE"
mkdir -p "$SHIM"
for c in awk cat cmp grep; do
  real=$(command -v "$c")
  cat > "$SHIM/$c" <<EOF
#!/bin/bash
echo $c >> "\${FM_SHIM_LOG:-/dev/null}"
if [ -n "\${FM_SHIM_HANG:-}" ] && [ "\${FM_SHIM_HANG_CMD:-}" = "$c" ] && [ ! -e "\${FM_SHIM_HANG}.hit" ]; then
  : > "\${FM_SHIM_HANG}.hit"; echo \$\$ > "\${FM_SHIM_HANG}.pid"; exec sleep 120
fi
exec "$real" "\$@"
EOF
  chmod +x "$SHIM/$c"
done
export PATH="$SHIM:$PATH"
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

# seed_handled <dir> <N>: N acknowledged records in the lib's own record format, none equal to the probe text
seed_handled() {
  local dir=$1 n=$2 i f
  mkdir -p "$dir/handled"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    printf -v f '%s/handled/%04d.msg' "$dir" "$i"
    printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nacknowledged steer %s\nsecond line\n' "$i" > "$f"
  done
}

call_idem() {  # <state> <text> [mode]   -> prints "rc=<n> out=<path-or-empty>"
  local state=$1 text=$2 mode=${3:-}
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" "$3" "$4" "$5"' _ "$LIB" "$state" probe-task "$text" "$mode" 2>"$state.err" >"$state.out"
  local rc=$?
  printf 'rc=%s out=%s\n' "$rc" "$(cat "$state.out" | sed "s|$state|<STATE>|g")"
}

case "$MODE" in
count)
  N=$ARG; rm -rf "$RUN"; mkdir -p "$RUN"
  seed_handled "$RUN/probe-task.inbox" "$N"
  : > "$RUN/shim.log"
  FM_SHIM_LOG="$RUN/shim.log" FM_STATE_OVERRIDE="$RUN" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" probe-task "$3"' _ "$LIB" "$RUN" "brand new steer text" > "$RUN/out" 2>"$RUN/err"
  echo "side=$SIDE records=$N rc=$? out=$(sed "s|$RUN|<STATE>|" "$RUN/out")"
  for c in awk cat cmp grep; do printf '%s=%s ' "$c" "$(grep -c "^$c\$" "$RUN/shim.log" || true)"; done; echo
  printf 'total_shim_launches=%s\n' "$(wc -l < "$RUN/shim.log" | tr -d ' ')"
  ;;
time)
  N=$ARG; best=
  for rep in 1 2 3; do
    rm -rf "$RUN"; mkdir -p "$RUN"; seed_handled "$RUN/probe-task.inbox" "$N"
    t0=$(now_ms)
    FM_STATE_OVERRIDE="$RUN" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" probe-task "$3"' _ "$LIB" "$RUN" "brand new steer text" >/dev/null 2>&1
    rc=$?
    t1=$(now_ms); d=$((t1 - t0))
    [ "$rc" -eq 0 ] || echo "WARN rc=$rc"
    if [ -z "$best" ] || [ "$d" -lt "$best" ]; then best=$d; fi
  done
  echo "side=$SIDE records=$N best_ms=$best load=$(uptime | sed 's/.*load averages*: //')"
  ;;
cases)
  BASE=$S/cases-$SIDE; rm -rf "$BASE"; mkdir -p "$BASE"
  # Each case: fresh state dir at a fixed path; seeding through the lib's own writers.
  run_case() {  # <name> <seed-action-fn> <text> [mode] [second-text]
    local name=$1 seedfn=$2 text=$3 mode=${4:-} second=${5:-$3}
    local st="$BASE/$name/state"
    rm -rf "$BASE/$name"; mkdir -p "$st"
    "$seedfn" "$st"
    echo "== $name (mode='${mode}')"
    echo "first : $(call_idem "$st" "$text" "$mode")"
    echo "second: $(call_idem "$st" "$second" "$mode")"
    echo "records:"
    ( cd "$st/probe-task.inbox" 2>/dev/null && find . -type f \( -name '*.msg' -o -name '.dedup.*' -o -name '.staging.*' \) | LC_ALL=C sort | while read -r r; do printf '  %s %s\n' "$r" "$(cksum < "$r" | cut -d' ' -f1)"; done )
    [ -f "$st/probe-task.inbox/handled" ] || true
  }
  plain() { FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_task_inbox_write "$2" probe-task "$3" "$4"' _ "$LIB" "$1" probe-task "$2" "$3"; }
  seed_unhandled() {  # <st> <text> [mode]
    local st=$1; FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_task_inbox_write "$2" probe-task "$3" "$4"' _ "$LIB" "$st" "$SEEDTEXT" "$SEEDMODE" >/dev/null
  }
  seed_text() {  # <st>  seeds SEEDTEXT (plain) unhandled
    local st=$1; FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_task_inbox_write "$2" probe-task "$3" "$4"' _ "$LIB" "$st" "$SEEDTEXT" "$SEEDMODE" >/dev/null
  }
  seed_text_handled() {
    local st=$1; seed_text "$st"; mv "$st/probe-task.inbox/"*.msg "$st/probe-task.inbox/handled/"
  }
  seed_none() { :; }
  SEEDTEXT='hello world'; SEEDMODE=; run_case C1-unhandled-exact seed_text 'hello world'
  SEEDTEXT='ack me'; SEEDMODE=; run_case C2-handled-exact seed_text_handled 'ack me'
  SEEDTEXT='ff body'; SEEDMODE=; run_case C3-ff-text-vs-ordinary-record seed_text 'ff body' fire-and-forget
  SEEDTEXT='ff2'; SEEDMODE=fire-and-forget; run_case C4-ordinary-text-vs-ff-record seed_text 'ff2' ''
  SEEDTEXT='ff3'; SEEDMODE=fire-and-forget; run_case C5-ff-exact-vs-ff-record seed_text 'ff3' fire-and-forget
  SEEDTEXT=$'shared first line\nold tail'; SEEDMODE=; run_case C6-near-miss-same-first-line seed_text $'shared first line\nnew tail'
  SEEDTEXT=$'line1\nline2\nline3'; SEEDMODE=; run_case C7-multiline-exact seed_text $'line1\nline2\nline3'
  SEEDTEXT=$'\n\nlead text'; SEEDMODE=; run_case C8-leading-blank-lines seed_text $'\n\nlead text'
  SEEDTEXT='a.*[b]^$\(x+?|y'; SEEDMODE=; run_case C9-regex-first-line seed_text 'a.*[b]^$\(x+?|y'
  SEEDTEXT='-rf --all: now'; SEEDMODE=; run_case C10-leading-dash-colon seed_text '-rf --all: now'
  LONG=$(printf 'x%.0s' $(seq 1 6000)); SEEDTEXT="$LONG"$'\ntail'; SEEDMODE=; run_case C11-6000-char-first-line seed_text "$LONG"$'\ntail'
  SEEDTEXT='ab'; SEEDMODE=; run_case C12-prefix-of-record seed_text 'abc'
  SEEDTEXT='abc'; SEEDMODE=; run_case C12b-record-prefix-of-text seed_text 'ab'
  SEEDTEXT=''; SEEDMODE=; run_case C13-empty-text seed_text ''
  SEEDTEXT='trail'; SEEDMODE=; run_case C14-trailing-newline seed_text $'trail\n'
  SEEDTEXT='multi'$'\n'; SEEDMODE=; run_case C15-record-with-trailing-newline seed_text 'multi'
  ;;
signal)
  SIG=$ARG; ST="$S/sig-$SIDE-$SIG"; rm -rf "$ST"; mkdir -p "$ST/state"
  seed_handled "$ST/state/probe-task.inbox" 5
  mkdir -p "$ST/state/probe-task.inbox"
  FM_SHIM_HANG="$ST/hang" FM_SHIM_HANG_CMD=$([ "$SIDE" = head ] && echo grep || echo cat) \
    FM_STATE_OVERRIDE="$ST/state" perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" probe-task "$3"' _ "$LIB" "$ST/state" "signal probe text" > "$ST/hung.out" 2> "$ST/hung.err" &
  bg=$!
  i=0; while [ ! -e "$ST/hang.hit" ] && [ "$i" -lt 150 ]; do i=$((i+1)); sleep 0.2; done
  echo "hang reached: $([ -e "$ST/hang.hit" ] && echo yes || echo no)"
  echo "inbox while hung: $(ls -A "$ST/state/probe-task.inbox" | tr '\n' ' ')"
  if [ "$SIG" = KILL ]; then kill -9 "$bg" 2>/dev/null; else kill -"$SIG" "$bg" 2>/dev/null; fi
  wait "$bg" 2>/dev/null; echo "writer exit after $SIG: $?"
  hp=$(cat "$ST/hang.pid" 2>/dev/null || true)
  if [ -n "$hp" ] && kill -0 "$hp" 2>/dev/null; then echo "hung child $hp still alive after writer exit (killing our own child)"; kill "$hp" 2>/dev/null; fi
  echo "inbox after $SIG: $(ls -A "$ST/state/probe-task.inbox" | tr '\n' ' ')"
  echo "dedup temp files after $SIG: $(ls -A "$ST/state/probe-task.inbox" | grep -c '^\.dedup\.' || true)"
  echo "lock present after $SIG: $([ -e "$ST/state/probe-task.inbox/.seq.lock" ] && echo yes || echo no)"
  echo "next call: $(FM_STATE_OVERRIDE="$ST/state" bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" probe-task "$3"' _ "$LIB" "$ST/state" "after the kill" 2>"$ST/next.err"; echo rc=$?)"
  echo "inbox at end: $(ls -A "$ST/state/probe-task.inbox" | tr '\n' ' ')"
  ;;
esac
