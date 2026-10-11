#!/usr/bin/env bash
# Live drift guard for the Antigravity CLI (agy) composer shape: a real agy in an
# isolated Herdr lab, read through the production composer path and driven
# through `fm-control.sh exit`, the step `relaunch` runs before it replaces a
# worker.
#
# The shared classifier (bin/fm-composer-lib.sh) proves agy's two-rule `>` row
# only under a live agy identity, from the shape agy 1.3.3 draws. A release that
# redraws the composer would leave `fm-control.sh relaunch` refusing every agy
# worker at its composer-empty proof (the 2026-10-10 vernant-pr3228 review
# worker), which a stub screen cannot notice; tests/fm-composer-lib.test.sh pins
# the logic against captured screens, and this guard pins the screens.
# `exit` stands in for the whole relaunch because relaunch's own launch step
# registers workspace trust in the REAL ~/.gemini store, which a throwaway-HOME
# lab must not touch, and fm-control cannot run under another HOME (the Herdr
# client would not find the lab server, so launch attribution reads unknown).
#
# Opt-in because it submits one real prompt (no echo provider exists for agy).
# Always runs on a private, named, throwaway lab session, never the default one
# (tests/herdr-test-safety.sh), and under a throwaway HOME holding a copy of
# ~/.gemini so agy's trust answer and every other agy write land in the lab.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH=
SESSION=

cleanup() {
  local session=$SESSION scratch=$SCRATCH
  SESSION=; SCRATCH=
  [ -z "$session" ] || herdr_safe_stop_and_delete "$session"
  [ -z "$scratch" ] || { chmod -R u+w "$scratch" 2>/dev/null; rm -rf -- "$scratch"; }
}
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_AGY_COMPOSER_LIVE agy herdr jq git
AGY_BIN=$(command -v agy 2>/dev/null || true)
[ -n "$AGY_BIN" ] || fail "agy is not installed"
AGY_VERSION=$("$AGY_BIN" --version 2>&1 | head -1)
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
[ -d "$HOME/.gemini" ] || fail "no ~/.gemini to stage for the throwaway agy HOME"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
SESSION="fm-lab-agy-composer-$$"
export HERDR_SESSION="$SESSION"
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-composer.XXXXXX") || fail "could not create the lab scratch directory"
SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOME_DIR="$SCRATCH/firstmate-home"
AGY_HOME="$SCRATCH/home"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/agyc" "$AGY_HOME" "$PROJ"
cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not stage the throwaway agy credential copy"
cat > "$HOME_DIR/data/agyc/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise agy composer classification safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b agyc "$WT"
WT=$(cd "$WT" && pwd -P)

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
read -r TAB_ID PANE_ID <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" "fm-agyc" "$WT" "$SEEDED_TAB_ID")
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
TARGET="$SESSION:$PANE_ID"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=agyc"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=agy"
  echo "kind=scout"
  echo "model=gemini-3.8-flash-low"
  echo "effort=low"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
  echo "spawn_gen=agy-composer-$$"
  echo "launch_proof=env-v1"
} > "$HOME_DIR/state/agyc.meta"

# Every wait below is a poll that ends the moment its condition holds, so a
# limit only bounds a hang. Limits come from the `timing:` lines this guard
# prints, measured 2026-10-10 on agy 1.3.3 / herdr 0.9.1 on the 18-core Mac
# Studio: three runs on the running fleet (load average 47-73, never idle) and
# three more with 36 extra busy loops on top (load average 58-96, about five
# runs of work per core). Samples are whole seconds, so each is 0-1s low.
#   phase    slowest sample   limit  margin
#   boot     12s              60s    5x   launch line -> idle composer, trust answered
#   render   1s               10s    10x  keystrokes -> the frame that shows them
#   turn     5s               60s    12x  prompt submitted -> idle composer again
#   exit     7s               35s    5x   fm-control exit, proof + command + stopped
# The turn waits on a remote model whose latency host load does not move, so it
# carries the widest margin; the render wait is the one a loaded host could
# plausibly stretch, so it carries the second widest.
WAIT_BOOT=60
WAIT_RENDER=10
WAIT_TURN=60
WAIT_EXIT=35
POLL=0.25
LOAD=$(uptime | sed 's/.*load averages*: //')

timing() {  # <phase> <start-seconds>
  printf 'timing: %s=%ss load=%s\n' "$1" "$((SECONDS - $2))" "$LOAD"
}

state_now() {  # -> composer verdict via the production herdr path
  : > "$SCRATCH/dialog.sink"
  FM_COMPOSER_DIALOG_SINK="$SCRATCH/dialog.sink" fm_backend_herdr_composer_state "$TARGET"
}
identity_now() { fm_backend_herdr_composer_identity "$TARGET" 2>/dev/null | tr '\t' '/'; }

wait_state() {  # <want> <limit-seconds> <phase>
  local want=$1 limit=$2 phase=$3 started=$SECONDS got=
  while [ $((SECONDS - started)) -lt "$limit" ]; do
    got=$(state_now)
    if [ "$got" = "$want" ]; then timing "$phase" "$started"; return 0; fi
    sleep "$POLL"
  done
  fail "$phase: composer never read '$want' within ${limit}s (last '$got', identity $(identity_now), agy $AGY_VERSION, herdr $HERDR_VERSION)"
}

# --- boot: a real agy, idle ---------------------------------------------------

AGY_LINE="FM_SPAWN_GEN=agy-composer-$$ HOME=\"$AGY_HOME\" $AGY_BIN --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions"
fm_backend_herdr_send_text_line "$TARGET" "$AGY_LINE" || fail "could not type the agy launch line"
started=$SECONDS
screen=
while [ $((SECONDS - started)) -lt "$WAIT_BOOT" ]; do
  screen=$(fm_backend_herdr_visible_capture "$TARGET" 2>/dev/null) || screen=
  case "$screen" in
    *"Do you trust the contents of this project?"*)
      # The unanswered dialog must never read as an empty composer.
      [ "$(state_now)" != empty ] || fail "the agy folder-trust dialog read as an empty composer"
      fm_backend_herdr_send_key "$TARGET" Enter
      sleep 1
      continue
      ;;
    *"for shortcuts"*) break ;;
  esac
  sleep "$POLL"
done
case "$screen" in *"for shortcuts"*) timing boot "$started" ;; *) fail "agy never reached its idle composer within ${WAIT_BOOT}s" ;; esac
fm_backend_herdr_send_key "$TARGET" Escape
sleep 1

wait_state empty "$WAIT_RENDER" idle-empty
case "$(identity_now)" in
  agy/idle) pass "an idle real agy pane reads empty (native identity agy/idle) [agy $AGY_VERSION, herdr $HERDR_VERSION]" ;;
  *) fail "an idle agy pane reported identity '$(identity_now)' rather than agy/idle" ;;
esac

# --- pending text and the slash popup never read empty -----------------------

fm_backend_herdr_send_literal "$TARGET" "hello pending text" || fail "could not type the agy draft"
wait_state pending "$WAIT_RENDER" draft-pending
pass "agy composer text reads pending"
fm_backend_herdr_send_key "$TARGET" C-u
wait_state empty "$WAIT_RENDER" draft-cleared

fm_backend_herdr_send_literal "$TARGET" "/" || fail "could not type the agy slash"
started=$SECONDS
while [ $((SECONDS - started)) -lt "$WAIT_RENDER" ]; do
  screen=$(fm_backend_herdr_visible_capture "$TARGET" 2>/dev/null) || screen=
  case "$screen" in *"Navigate"*) break ;; esac
  sleep "$POLL"
done
case "$screen" in *"Navigate"*) timing popup "$started" ;; *) fail "the agy slash popup never rendered within ${WAIT_RENDER}s" ;; esac
[ "$(state_now)" != empty ] || fail "the agy slash popup read as an empty composer"
pass "the agy slash popup never reads empty"
fm_backend_herdr_send_key "$TARGET" Escape
sleep 0.5
fm_backend_herdr_send_key "$TARGET" C-u
wait_state empty "$WAIT_RENDER" popup-cleared

# --- a turn in flight never reads empty --------------------------------------

fm_backend_herdr_send_literal "$TARGET" "Add 12345 and 67890. Reply with only the sum." || fail "could not type the agy prompt"
fm_backend_herdr_send_key "$TARGET" Enter
started=$SECONDS
saw_working=0
settled=0
while [ $((SECONDS - started)) -lt "$WAIT_TURN" ]; do
  before=$(identity_now)
  verdict=$(state_now)
  after=$(identity_now)
  if [ "$before" = agy/working ] && [ "$after" = agy/working ]; then
    saw_working=1
    [ "$verdict" != empty ] || fail "a real agy turn in flight read as an empty composer (identity agy/working before and after the read)"
  fi
  if [ "$saw_working" = 1 ] && [ "$before" = agy/idle ] && [ "$verdict" = empty ]; then settled=1; break; fi
  sleep "$POLL"
done
[ "$saw_working" = 1 ] || fail "the agy turn never reported native status working, so the in-flight check proved nothing"
[ "$settled" = 1 ] || fail "the agy turn never settled to an empty idle composer within ${WAIT_TURN}s"
timing turn "$started"
pass "a real agy turn in flight never reads empty, and the settled pane reads empty again"

# --- the reproduction: fm-control exit of an idle agy ------------------------
#
# The relaunch the lane attempted stops the old worker with exactly this verb,
# and it was refused at the composer-empty proof before typing the exit command.

started=$SECONDS
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.5 FM_CONTROL_EXIT_WAIT="$WAIT_EXIT" \
  "$ROOT/bin/fm-control.sh" agyc exit 2>&1) \
  || fail "fm-control exit refused an idle agy worker: $OUT"
case "$OUT" in
  "stopped agyc harness=agy"*) ;;
  *) fail "fm-control exit did not report the agy worker stopped: $OUT" ;;
esac
timing exit "$started"
pass "fm-control exit stops an idle real agy worker past its composer-empty proof"
