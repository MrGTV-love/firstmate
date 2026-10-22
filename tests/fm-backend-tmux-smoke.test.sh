#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out='' pane_state status signal i=0
  while [ "$i" -lt "$samples" ]; do
    # Unlike display-message, list-panes refuses an unresolved window target.
    pane_state=$(tmux list-panes -t "$target" -F '#{pane_dead}:#{pane_dead_status}:#{pane_dead_signal}' 2>/dev/null || true)
    case "$pane_state" in
      0:*|1:*) : ;;
      *)
        printf 'tmux pane disappeared: target=%s pane_dead_status=unavailable\nlast captured output:\n%s\n' "$target" "$out" >&2
        return 1 ;;
    esac
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || printf '%s' "$out")
    case "$pane_state" in
      1:*)
        status=${pane_state#*:}
        signal=${status#*:}
        status=${status%%:*}
        printf 'tmux pane exited: target=%s pane_dead_status=%s pane_dead_signal=%s\ncaptured output:\n%s\n' "$target" "${status:-unavailable}" "${signal:-unavailable}" "$out" >&2
        return 1 ;;
    esac
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  printf 'tmux capture timed out: target=%s expected=%s\nlast captured output:\n%s\n' "$target" "$text" "$out" >&2
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
TEST_BASH=$(command -v bash)
# Ignore host tmux and shell startup files. Keep exited panes so a failed
# startup retains its exit status and output instead of erasing the evidence.
cat > "$SHIM_DIR/tmux.conf" <<'CONF'
set -g default-shell /bin/sh
set -g remain-on-exit on
CONF
cat > "$SHIM_DIR/bashrc" <<'RC'
PS1='smoke$ '
PROMPT_COMMAND=
printf 'shell-%s\n' ready
RC
cat > "$SHIM_DIR/start-shell" <<SH
#!/bin/sh
unset ENV BASH_ENV
# Hold startup until the test has observed this phase, even on a loaded runner.
# The old Ctrl-C probe kills this noninteractive process before it is released.
printf 'startup-%s\\n' waiting
while [ ! -e "$SHIM_DIR/startup-release" ]; do sleep 0.1; done
exec "$TEST_BASH" --noprofile --rcfile "$SHIM_DIR/bashrc" -i
SH
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" -f "$SHIM_DIR/tmux.conf" "\$@"
SH
chmod +x "$SHIM_DIR/tmux" "$SHIM_DIR/start-shell"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 'exec /bin/sh' \
  || fail "real tmux: new-session failed"
printf -v START_COMMAND 'exec %q' "$SHIM_DIR/start-shell"
tmux set-option -t "$SESSION" default-command "$START_COMMAND" \
  || fail "real tmux: could not configure the isolated startup shell"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# Observe the slow pre-interactive phase before awaiting the rc-file handshake.
# No keys, especially Ctrl-C, may reach that unverified startup process.
wait_for_capture_text "$TARGET" "startup-waiting" \
  || fail "the slow pre-interactive startup did not begin"
touch "$SHIM_DIR/startup-release"
wait_for_capture_text "$TARGET" "shell-ready" \
  || fail "the tmux task shell did not become ready"
pass "real tmux: passive readiness survives slow pre-interactive startup"

# Control: Ctrl-C is safe once the interactive rc file has acknowledged startup.
tmux send-keys -t "$TARGET" C-c
fm_backend_tmux_send_text_line "$TARGET" "printf 'after-interactive-%s\\n' interrupt" \
  || fail "the interactive shell did not accept input after Ctrl-C"
wait_for_capture_text "$TARGET" "after-interactive-interrupt" \
  || fail "Ctrl-C after the interactive rc file killed the shell"
pass "real tmux: Ctrl-C after the interactive rc file preserves command execution"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- readiness failures retain the cause instead of polling a dead pane ------
DIAGNOSTIC_TARGET="$SESSION:startup-exit"
tmux new-window -d -t "$SESSION:" -n startup-exit "printf 'startup-exit-evidence\\n'; exit 23" \
  || fail "real tmux: could not create the failed-startup diagnostic case"
if diagnostics=$(wait_for_capture_text "$DIAGNOSTIC_TARGET" "never-ready" 100 2>&1); then
  fail "an exited startup pane must not become ready"
fi
case "$diagnostics" in
  *'pane_dead_status=23'*'startup-exit-evidence'*) : ;;
  *) fail "startup failure lost its exit status or captured output"$'\n'"$diagnostics" ;;
esac
tmux kill-window -t "$DIAGNOSTIC_TARGET"
if diagnostics=$(wait_for_capture_text "$DIAGNOSTIC_TARGET" "never-ready" 100 2>&1); then
  fail "a removed startup window must not become ready"
fi
case "$diagnostics" in
  *'pane disappeared:'*'pane_dead_status=unavailable'*'last captured output:'*) : ;;
  *) fail "a removed startup window did not report the missing pane evidence"$'\n'"$diagnostics" ;;
esac
pass "real tmux: readiness stops on exited or removed panes and reports exit/output evidence"

cleanup_all
trap - EXIT
