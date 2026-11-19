#!/usr/bin/env bash
# Live driver for IA1: runs the real bin/ scripts from a git-archive copy of the
# BASE commit and of the HEAD commit, each against scratch FM_HOME directories.
# Never touches the operator's firstmate home, the live queue, or the worktree.
set -u
unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE \
  FM_WAKE_ACK_AWAY_DAEMON FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS

EV=/Users/charlesabrooker/.no-mistakes/evidence/01M7S3SYGPEMG2WC4GM7A6RMB4
OUT=$EV/IA1
SCR=${SCR:?set SCR to the scratch dir holding base/ and head/ archives}
mkdir -p "$OUT" "$SCR/homes" "$SCR/root"
CASE_FILE=
CASE=

mkhome() { # <name> -> path
  local h="$SCR/homes/$1"
  rm -rf "$h"
  mkdir -p "$h/state" "$h/data" "$h/config"
  : > "$h/config/supervision-host-off"
  printf '%s\n' "$h"
}
rd() { # <code> <home> <args...>  (fm-wake-drain.sh)
  local code=$1 h=$2
  shift 2
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    FM_CONFIG_OVERRIDE="$h/config" FM_ROOT_OVERRIDE="$SCR/root" \
    "$SCR/$code/bin/fm-wake-drain.sh" "$@"
}
ri() { # <code> <home> <args...>  (fm-inbox.sh)
  local code=$1 h=$2
  shift 2
  FM_HOME="$h" FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" \
    FM_CONFIG_OVERRIDE="$h/config" "$SCR/$code/bin/fm-inbox.sh" "$@"
}
present() { # <code> <home> -> the ack arguments printed in WAKE_ACK_REQUIRED
  local code=$1 h=$2 err
  err=$(rd "$code" "$h" 2>&1 >/dev/null)
  printf '%s\n' "$err" | sed -n 's|^WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh ||p'
}
note() { # <code> <home> <text> -> note id
  local out
  out=$(ri "$1" "$2" note "$3")
  printf '%s\n' "$out" | sed -n 's/^queued //p' | head -1
}
signal_row() { # <code> <home> <key>
  FM_STATE_OVERRIDE="$2/state" bash -c '. "$1"; fm_wake_append signal "$2" "signal: $2 done"' _ \
    "$SCR/$1/bin/fm-wake-lib.sh" "$3"
}
qrows() { # <home>
  if [ -s "$1/state/.wake-queue" ]; then awk 'NF { n++ } END { print n + 0 }' "$1/state/.wake-queue"; else echo 0; fi
}
qseqs() { # <home>
  awk -F '\t' 'NF >= 5 { printf "%s%s", (n++ ? " " : ""), $2 } END { print "" }' "$1/state/.wake-queue" 2>/dev/null
}
log() { printf '%s\n' "$*" >> "$CASE_FILE"; }
ack() { # <code> <home> <args...> -> sets ACK_OUT, ACK_RC; logs the exact command
  local code=$1 h=$2
  shift 2
  ACK_OUT=$(rd "$code" "$h" "$@" 2>&1)
  ACK_RC=$?
  log "\$ bin/fm-wake-drain.sh $*"
  log "$ACK_OUT"
  log "[exit=$ACK_RC  queue_rows=$(qrows "$h")  queue_seqs=$(qseqs "$h")]"
}
start_case() { # <name> <code>
  CASE=$1
  CASE_FILE=$OUT/$1-$2.txt
  : > "$CASE_FILE"
  log "# IA1 case $1 on code=$2 (base=7f3a198, head=d1246b9)"
}

# A. One unacked captain inbox note in range.
case_A() {
  local code=$1 h id args
  start_case A-one-unacked-note "$code"
  h=$(mkhome "$code-A")
  id=$(note "$code" "$h" "advisor note A")
  log "# queued captain inbox note $id"
  args=$(present "$code" "$h")
  log "# presented ack args: $args"
  ack "$code" "$h" $args
  ri "$code" "$h" drain --ack "$id" >/dev/null 2>&1
  log "# ran: bin/fm-inbox.sh drain --ack $id (exit=$?)"
  ack "$code" "$h" $args
}

# B. Two unacked notes in range: both ids must be named.
case_B() {
  local code=$1 h id1 id2 args
  start_case B-two-unacked-notes "$code"
  h=$(mkhome "$code-B")
  id1=$(note "$code" "$h" "advisor note B1")
  id2=$(note "$code" "$h" "advisor note B2")
  log "# queued notes $id1 and $id2"
  args=$(present "$code" "$h")
  log "# presented ack args: $args"
  ack "$code" "$h" $args
  ri "$code" "$h" drain --ack "$id1" >/dev/null 2>&1
  log "# ran: drain --ack $id1"
  ack "$code" "$h" $args
  ri "$code" "$h" drain --ack "$id2" >/dev/null 2>&1
  log "# ran: drain --ack $id2"
  ack "$code" "$h" $args
}

# C. Unacked note whose wake row is ABOVE the acknowledged range does not block.
case_C() {
  local code=$1 h id1 args
  start_case C-unacked-note-outside-range "$code"
  h=$(mkhome "$code-C")
  id1=$(note "$code" "$h" "advisor note C1 (acked before presentation)")
  ri "$code" "$h" drain --ack "$id1" >/dev/null 2>&1
  args=$(present "$code" "$h")
  log "# presented ack args: $args"
  id2=$(note "$code" "$h" "advisor note C2 (queued after presentation, unacked)")
  log "# queued unacked note $id2 AFTER presentation (row is above the cutoff)"
  ack "$code" "$h" $args
}

# D. A range with no inbox-note rows acks exactly as before.
case_D() {
  local code=$1 h args
  start_case D-no-note-rows "$code"
  h=$(mkhome "$code-D")
  signal_row "$code" "$h" taska
  args=$(present "$code" "$h")
  log "# presented ack args: $args (signal row only)"
  ack "$code" "$h" $args
}

# E. An already-acked note does not block.
case_E() {
  local code=$1 h id args
  start_case E-already-acked-note "$code"
  h=$(mkhome "$code-E")
  id=$(note "$code" "$h" "advisor note E")
  ri "$code" "$h" drain --ack "$id" >/dev/null 2>&1
  log "# acked $id before presentation"
  args=$(present "$code" "$h")
  log "# presented ack args: $args"
  ack "$code" "$h" $args
}

# F. Repeated ack of an already processed sequence keeps its current behavior.
case_F() {
  local code=$1 h args
  start_case F-repeated-ack "$code"
  h=$(mkhome "$code-F")
  signal_row "$code" "$h" taska
  args=$(present "$code" "$h")
  log "# presented ack args: $args"
  ack "$code" "$h" $args
  ack "$code" "$h" $args
}

# G1. Adversarial: an ordinary actor passing --keep-unacked-notes must still be refused.
case_G1() {
  local code=$1 h id args
  start_case G1-keep-flag-ordinary-actor "$code"
  h=$(mkhome "$code-G1")
  id=$(note "$code" "$h" "advisor note G1")
  args=$(present "$code" "$h")
  log "# queued note $id; presented ack args: $args"
  ack "$code" "$h" $args --keep-unacked-notes
}

# G2. Adversarial: away-daemon env set but state/.afk absent is not the exemption.
case_G2() {
  local code=$1 h id args
  start_case G2-away-env-without-afk "$code"
  h=$(mkhome "$code-G2")
  id=$(note "$code" "$h" "advisor note G2")
  args=$(present "$code" "$h")
  log "# queued note $id; presented ack args: $args"
  export FM_WAKE_ACK_AWAY_DAEMON=1
  ack "$code" "$h" $args --keep-unacked-notes
  unset FM_WAKE_ACK_AWAY_DAEMON
}

# G3. Recorded exemption (away daemon: env + state/.afk + flag): observed, not an IA1 criterion.
case_G3() {
  local code=$1 h id args
  start_case G3-away-daemon-keep-mode "$code"
  h=$(mkhome "$code-G3")
  id=$(note "$code" "$h" "advisor note G3")
  args=$(present "$code" "$h")
  touch "$h/state/.afk"
  log "# queued note $id; presented ack args: $args; created state/.afk"
  export FM_WAKE_ACK_AWAY_DAEMON=1
  ack "$code" "$h" $args --keep-unacked-notes
  unset FM_WAKE_ACK_AWAY_DAEMON
}

# H. Adversarial: a row names a note with no record at all. Must refuse, then clear after drain --ack.
case_H() {
  local code=$1 h id args
  start_case H-row-without-note-record "$code"
  h=$(mkhome "$code-H")
  id=$(note "$code" "$h" "advisor note H")
  rm -f "$h/state/inbox/$id.note"
  log "# queued note $id, then deleted its note file (no record left)"
  args=$(present "$code" "$h")
  log "# presented ack args: $args"
  ack "$code" "$h" $args
  ri "$code" "$h" drain --ack "$id" >/dev/null 2>&1
  log "# ran: drain --ack $id (exit=$?)"
  ack "$code" "$h" $args
}

for code in base head; do
  case_A "$code"
  case_B "$code"
  case_C "$code"
  case_D "$code"
  case_E "$code"
  case_F "$code"
  case_G1 "$code"
  case_G2 "$code"
  case_G3 "$code"
  case_H "$code"
done
echo "done: outputs in $OUT"
