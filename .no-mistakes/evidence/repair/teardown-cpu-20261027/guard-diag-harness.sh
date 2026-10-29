#!/bin/bash
# Synthetic harness for the temporary guard phase diagnostic in bin/fm-guard.sh.
# It extracts ONLY the seven BEGIN/END diagnostic blocks from the real file and
# stitches them, in their original order, around stand-in "(exit N)" lists that
# play the role of the product phases. No product operation is sourced or run.
# fm-duration-lib.sh is replaced by a stub that logs source and batch calls.
# BASH_VERSINFO[0] is textually replaced by FAKE_MAJOR (synthetic version only).
# usage: guard-diag-harness.sh <path to fm-guard.sh> <scratch dir>
set -u
GUARD=$1
WORK=$2
mkdir -p "$WORK"

extract_block() {  # <n>: print the n-th diagnostic block (1-based)
  awk -v want="$1" '
    /BEGIN temporary guard phase diagnostic/ { n++; on = (n == want) }
    on { print }
    /END temporary guard phase diagnostic/ { if (on) on = 0 }
  ' "$GUARD"
}

count=$(grep -c 'BEGIN temporary guard phase diagnostic' "$GUARD")
[ "$count" -eq 7 ] || { echo "expected 7 diagnostic blocks, found $count"; exit 2; }

STUBDIR="$WORK/stubbin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/fm-duration-lib.sh" <<'EOF'
printf 'sourced\n' >> "$HARNESS_LOG"
fm_duration_record_batch() {
  printf 'batch file=%s\n' "$FM_DURATION_FILE" >> "$HARNESS_LOG"
  cat >> "$HARNESS_LOG"
  printf 'endbatch\n' >> "$HARNESS_LOG"
  : > "$FM_DURATION_FILE"
}
EOF

# Build the stitched script once.
SCRIPT="$WORK/stitched.sh"
{
  echo 'set -u'
  echo 'SCRIPT_DIR=$STUBDIR'
  echo 'OSTYPE=$FAKE_OSTYPE'
  echo 'st() { EPOCHREALTIME=$1; }  # sets the next stamp (plain var in Bash 3.2)'
  echo 'st "$S0"'
  extract_block 1 | sed 's/BASH_VERSINFO\[0\]/FAKE_MAJOR/'
  echo 'st "$S1"; (exit "$RC_LOADING")'
  extract_block 2
  echo 'st "$S2"; (exit "$RC_ACTOR")'
  extract_block 3
  echo 'st "$S3"; (exit "$RC_TANGLE")'
  extract_block 4
  echo 'st "$S4"; (exit "$RC_STATUS")'
  extract_block 5
  echo 'echo "product-stdout-before-exit-branch"'
  echo 'if [ "$PATH_KIND" = early ]; then'
  echo '  st "$S5"; (exit "$RC_SUFFIX")'
  extract_block 6
  echo '  echo "early-exit"; exit 0'
  echo 'fi'
  echo 'st "$S5"; (exit "$RC_SUFFIX")'
  extract_block 7
  echo 'echo "final-exit"; exit 0'
} > "$SCRIPT"
/bin/bash -n "$SCRIPT" || { echo "stitched script has a syntax error"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok - %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; }

# run_case <name> <env assignments...>; leaves $OUT, $RC, $LOG, $ART
run_case() {
  local name=$1; shift
  LOG="$WORK/$name.log"; ART="$WORK/$name.jsonl"; OUT="$WORK/$name.out"
  rm -f "$LOG" "$ART" "$OUT"; : > "$LOG"
  env -i PATH=/usr/bin:/bin HOME="$WORK" HARNESS_LOG="$LOG" STUBDIR="$STUBDIR" \
    FAKE_OSTYPE=linux-gnu FAKE_MAJOR=5 PATH_KIND=final \
    S0=1000.000000 S1=1000.012000 S2=1000.020000 S3=1000.021000 S4=1000.264000 S5=1000.300000 \
    RC_LOADING=0 RC_ACTOR=0 RC_TANGLE=0 RC_STATUS=0 RC_SUFFIX=0 \
    FM_GUARD_PHASE_DURATION_FILE="$ART" "$@" \
    /bin/bash --norc --noprofile "$SCRIPT" > "$OUT" 2>&1
  RC=$?
  printf '\n### case %s (exit %s)\n--- stdout\n' "$name" "$RC"; cat "$OUT"
  printf -- '--- writer log\n'; cat "$LOG"
}
nsrc()   { grep -c '^sourced$' "$LOG"; }
nbatch() { grep -c '^batch ' "$LOG"; }
rows()   { grep -c '^diag\.guard\.' "$LOG"; }
row()    { grep "^diag\.guard\.force-override\.$1	" "$LOG"; }
expect_disabled() {  # <label>
  if [ "$RC" -eq 0 ] && [ "$(nsrc)" -eq 0 ] && [ "$(nbatch)" -eq 0 ] && [ ! -e "$ART" ]; then
    ok "$1: exit 0, no source, no batch, no artifact"
  else
    bad "$1: rc=$RC src=$(nsrc) batch=$(nbatch) artifact=$([ -e "$ART" ] && echo yes || echo no)"
  fi
}

# Probe a disabled run for clock reads and helper definitions too.
PROBE="$WORK/probe.sh"
{
  echo 'set -u'
  echo 'OSTYPE=$FAKE_OSTYPE'
  extract_block 1 | sed 's/BASH_VERSINFO\[0\]/FAKE_MAJOR/'
  echo 'declare -F fm_guard_phase_us fm_guard_phase_row fm_guard_phase_finish || echo "no-diag-functions"'
  echo 'echo "enabled=$guard_phase_enabled t0=${guard_phase_t0-UNSET}"'
} > "$PROBE"
probe() {  # <label> <env...>
  local label=$1; shift
  local o
  o=$(env -i PATH=/usr/bin:/bin FAKE_OSTYPE=linux-gnu FAKE_MAJOR=5 "$@" /bin/bash --norc --noprofile "$PROBE" 2>&1)
  printf '\n### probe %s\n%s\n' "$label" "$o"
  case $o in
    *no-diag-functions*"enabled=false t0=UNSET"*) ok "$label: no helper defined, no clock read (t0 unset)";;
    *) bad "$label: probe output unexpected";;
  esac
}

echo "== disabled-path cases"
probe "probe: opt-in file empty" FM_GUARD_PHASE_DURATION_FILE= EPOCHREALTIME=1000.000000
probe "probe: darwin OSTYPE" FM_GUARD_PHASE_DURATION_FILE=/tmp/x FAKE_OSTYPE=darwin26 EPOCHREALTIME=1000.000000
probe "probe: Bash3 with inherited numeric EPOCHREALTIME" FM_GUARD_PHASE_DURATION_FILE=/tmp/x FAKE_MAJOR=3 EPOCHREALTIME=1000.000000

run_case off-empty FM_GUARD_PHASE_DURATION_FILE=
expect_disabled "opt-in unset/empty"
run_case off-darwin FAKE_OSTYPE=darwin26
expect_disabled "darwin OSTYPE with opt-in"
run_case off-bash3 FAKE_MAJOR=3 S0=1000.000000 S1=1000.000000 S2=1000.000000 S3=1000.000000 S4=1000.000000 S5=1000.000000
expect_disabled "Bash3 with ordinary numeric clock (old false-zero producer)"
run_case off-bash4 FAKE_MAJOR=4
expect_disabled "Bash4 with opt-in"
run_case off-bash3-early FAKE_MAJOR=3 PATH_KIND=early RC_SUFFIX=7
expect_disabled "Bash3 early exit path"

echo "== enabled happy paths"
for kind in final early; do
  run_case "on-$kind" PATH_KIND=$kind RC_LOADING=0 RC_ACTOR=2 RC_TANGLE=3 RC_STATUS=4 RC_SUFFIX=5
  want=$(printf 'diag.guard.force-override.loading\t12\t0\t0\t\t\t0\ndiag.guard.force-override.actor-init\t8\t2\t0\t\t\t0\ndiag.guard.force-override.tangle\t1\t3\t0\t\t\t0\ndiag.guard.force-override.status-liveness\t243\t4\t0\t\t\t0\ndiag.guard.force-override.suffix\t36\t5\t0\t\t\t0')
  got=$(grep '^diag\.guard\.' "$LOG")
  last=$(tail -n 1 "$OUT")
  if [ "$RC" -eq 0 ] && [ "$(nsrc)" -eq 1 ] && [ "$(nbatch)" -eq 1 ] && [ "$got" = "$want" ] &&
     [ "$last" = "$kind-exit" ] && grep -q "^batch file=$ART\$" "$LOG" &&
     [ "$(awk -F'\t' '/^diag\./{print NF}' "$LOG" | sort -u)" = 7 ]; then
    ok "$kind exit: 5 ordered 7-field rows, saved statuses 0/2/3/4/5, one source, one batch, exit 0, $kind stdout kept"
  else
    bad "$kind exit: rc=$RC src=$(nsrc) batch=$(nbatch) last=$last"
  fi
done

echo "== malformed / missing / backward pairs"
run_case malformed-t2 S2=abc
if [ "$(rows)" -eq 3 ] && row loading >/dev/null && row status-liveness >/dev/null && row suffix >/dev/null &&
   ! row actor-init >/dev/null && ! row tangle >/dev/null && [ "$(nbatch)" -eq 1 ]; then
  ok "malformed t2 omits only actor-init and tangle"
else bad "malformed t2"; fi

run_case missing-t4 S4=
if [ "$(rows)" -eq 3 ] && ! row status-liveness >/dev/null && ! row suffix >/dev/null && [ "$(nbatch)" -eq 1 ]; then
  ok "missing t4 omits only status-liveness and suffix"
else bad "missing t4"; fi

run_case backward-t3 S3=1000.019000
if [ "$(rows)" -eq 4 ] && ! row tangle >/dev/null && row actor-init >/dev/null && [ "$(nbatch)" -eq 1 ]; then
  ok "backward tangle pair omits only tangle (no clamp, no zero row)"
else bad "backward t3"; fi

run_case missing-t5-final S5=
if [ "$(rows)" -eq 4 ] && ! row suffix >/dev/null && [ "$(nbatch)" -eq 1 ]; then
  ok "missing final stamp omits only suffix"
else bad "missing t5"; fi

run_case comma-leading-zero S0=0001000,000000 S1=0001000,012000
if row loading | grep -q "	12	0	"; then
  ok "comma locale and leading-zero stamps parse as base 10"
else bad "comma/leading zero"; fi

run_case thirteen-digit S0=1234567890123.000000
if ! row loading >/dev/null && [ "$(rows)" -eq 4 ]; then
  ok "13-digit seconds rejected, only loading omitted"
else bad "13-digit"; fi

run_case short-fraction S1=1000.01200
if ! row loading >/dev/null && ! row actor-init >/dev/null && [ "$(rows)" -eq 3 ]; then
  ok "5-digit fraction rejected, its two rows omitted"
else bad "short fraction"; fi

echo "== zero valid rows means zero writer"
for kind in final early; do
  run_case "allbad-$kind" PATH_KIND=$kind S0=x S1=x S2=x S3=x S4=x S5=x RC_SUFFIX=9
  if [ "$RC" -eq 0 ] && [ "$(nsrc)" -eq 0 ] && [ "$(nbatch)" -eq 0 ] && [ ! -e "$ART" ] && [ "$(tail -n1 "$OUT")" = "$kind-exit" ]; then
    ok "$kind exit with no valid rows: no source, no batch, no artifact, exit 0"
  else bad "allbad $kind: src=$(nsrc) batch=$(nbatch)"; fi
done

printf '\nSUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
