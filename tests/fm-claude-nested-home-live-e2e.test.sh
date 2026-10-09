#!/usr/bin/env bash
# Live guard for the nested-home memory exclusion (live-harness-optin family).
# Per .agents/skills/firstmate-coding-guidelines "Harness-dependent checks", a
# fix that relies on how the INSTALLED Claude Code treats a settings key must be
# proven against the real binary; a stub can only confirm the assumption written
# into it.
#
# The incident: a Claude worker whose task copy sat inside a firstmate home
# (<home>/projects/<project>/.claude/worktrees/<task>) read the home's CLAUDE.md
# (@AGENTS.md) as a parent file and parked for hours on "Allow external
# CLAUDE.md file imports?". bin/fm-claude-memory-lib.sh excludes that home's
# memory files through the documented claudeMdExcludes setting. This guard
# drives the real binary in isolated configs:
#   1. a copy outside the fixture's homes reaches the composer (control);
#   2. a nested copy WITHOUT the exclusion parks on the imports dialog
#      (reproduction, so a pass of 3 cannot be vacuous);
#   3. the same nested copy launched with the production fragment reaches the
#      composer with no dialog.
#   4. a nested home containing shell and glob metacharacters must also reach
#      the composer through the production fragment and raw settings merger.
# No prompt is submitted and no dialog is answered, so no model tokens are spent
# and no operator credential store is touched: the config directory is a scratch
# one carrying a throwaway API-key approval. An absent claude is reported and
# skipped; a run that checked nothing fails.
#
# Refresh docs/verification/runtime-backends.md ("Nested firstmate home memory
# exclusion") from this guard's output after any Claude Code upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
SOCKET="fm-nested-home-$$"
LAB=''

note() { printf '# %s\n' "$1"; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

cleanup_all() {
  [ -z "${REAL_TMUX:-}" ] || "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}
trap cleanup_all EXIT

fm_live_gate default-on FM_CLAUDE_NESTED_HOME_LIVE tmux claude

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-claude-memory-lib.sh
. "$ROOT/bin/fm-claude-memory-lib.sh"

CLAUDE_BIN=$(command -v claude)
VERSION_OUT=$("$CLAUDE_BIN" --version 2>&1) || fail "claude --version failed: $VERSION_OUT"
note "live claude version: $VERSION_OUT"

LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-nested-home.XXXXXX")" && pwd -P) || fail "could not create the isolated lab"
CFG="$LAB/cfg"
KEY=sk-ant-fm-nested-home-throwaway
mkdir -p "$CFG" "$LAB/home/bin" "$LAB/home/projects/proj" "$LAB/plain"
printf '@AGENTS.md\n' > "$LAB/home/CLAUDE.md"
printf '# Firstmate supervisor contract\n' > "$LAB/home/AGENTS.md"
: > "$LAB/home/bin/fm-spawn.sh"
git -C "$LAB/home/projects/proj" init -q || fail "could not initialize the project"
git -C "$LAB/home/projects/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init || fail "could not commit"
mkdir -p "$LAB/home/projects/proj/.claude/worktrees"
git -C "$LAB/home/projects/proj" worktree add -q "$LAB/home/projects/proj/.claude/worktrees/task" -b task || fail "could not add the nested copy"
git -C "$LAB/plain" init -q || fail "could not initialize the control copy"
NESTED="$LAB/home/projects/proj/.claude/worktrees/task"
PLAIN="$LAB/plain"
ODD_HOME="$LAB/R&D [home] it's {x}"
mkdir -p "$ODD_HOME/bin" "$ODD_HOME/projects/proj"
printf '@AGENTS.md\n' > "$ODD_HOME/CLAUDE.md"
printf '# Firstmate supervisor contract\n' > "$ODD_HOME/AGENTS.md"
: > "$ODD_HOME/bin/fm-spawn.sh"
git -C "$ODD_HOME/projects/proj" init -q || fail "could not initialize the special-path project"
git -C "$ODD_HOME/projects/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init || fail "could not commit the special-path project"
mkdir -p "$ODD_HOME/projects/proj/.claude/worktrees"
ODD_NESTED="$ODD_HOME/projects/proj/.claude/worktrees/task"
git -C "$ODD_HOME/projects/proj" worktree add -q "$ODD_NESTED" -b task || fail "could not add the special-path nested copy"

# A workspace-local TMPDIR may put the whole fixture under another firstmate
# checkout. Exclude only those surrounding homes from the control and
# reproduction, leaving the fixture's own supervisor memory in play.
BASE_FRAGMENT=$(fm_claude_md_excludes_json "$LAB")
BASE_SETTINGS="{${BASE_FRAGMENT#,}}"

# Past onboarding with all copies trusted and the throwaway key pre-approved,
# so the only dialog left in play is the one under test.
jq -n --arg nested "$NESTED" --arg plain "$PLAIN" --arg odd "$ODD_NESTED" \
  --arg project "$LAB/home/projects/proj" --arg oddproject "$ODD_HOME/projects/proj" --arg key "${KEY: -20}" \
  '{hasCompletedOnboarding:true,theme:"dark",numStartups:5,
    customApiKeyResponses:{approved:[$key],rejected:[]},
    projects:{($nested):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
              ($plain):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
              ($odd):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
              ($project):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true},
              ($oddproject):{hasTrustDialogAccepted:true,hasCompletedProjectOnboarding:true}}}' \
  > "$CFG/.claude.json" || fail "could not write the scratch config"

# launch_and_wait <name> <dir> <settings-json> [raw-settings-source]
# -> captured pane in $PANE
launch_and_wait() {
  local name=$1 dir=$2 settings=$3 raw_source=${4:-} flags='' target="$1:w"
  local program="'$CLAUDE_BIN'"
  local config="$LAB/cfg-$name"
  mkdir -p "$config" || fail "$name: could not create the scratch config"
  cp "$CFG/.claude.json" "$config/.claude.json" || fail "$name: could not seed the scratch config"
  [ -z "$settings" ] || flags="--settings '$settings'"
  if [ -n "$raw_source" ]; then
    program="bash '$ROOT/bin/fm-claude-memory-lib.sh' '$settings' '$CLAUDE_BIN'"
    case "$raw_source" in
      none) flags='' ;;
      inline) flags="--settings='{\"feedbackDrafts\":\"off\",\"claudeMdExcludes\":[\"project/**\"]}'" ;;
      file)
        printf '%s\n' '{"feedbackDrafts":"off","claudeMdExcludes":["project/**"]}' > "$config/settings.json"
        flags="--settings '$config/settings.json'"
        ;;
    esac
  fi
  "$REAL_TMUX" -L "$SOCKET" new-session -d -s "$name" -n w -x 160 -y 48 -c "$dir" -- bash -c \
    "CLAUDE_CONFIG_DIR='$config' ANTHROPIC_API_KEY='$KEY' exec $program --setting-sources project,local $flags" \
    || fail "$name: could not launch the real binary"
  PANE=''
  for _ in $(seq 1 100); do
    PANE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null) || true
    printf '%s' "$PANE" | grep -qE 'Claude Code v[0-9]|Allow external CLAUDE\.md file imports' && break
    sleep 0.2
  done
  # Give a late dialog a chance to cover a composer that painted first.
  sleep 1
  PANE=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$target" -S -40 2>/dev/null) || true
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$name" >/dev/null 2>&1 || true
}

launch_and_wait control "$PLAIN" "$BASE_SETTINGS"
printf '%s' "$PANE" | fm_busy_claude_launch_prompt_tail \
  && fail "control: a copy outside any firstmate home parked on a dialog:
$PANE"
printf '%s' "$PANE" | grep -qE 'Claude Code v[0-9]' \
  || fail "control: the real binary never reached its banner:
$PANE"
pass "control: a copy that is not nested under a firstmate home reaches the composer"

launch_and_wait reproduction "$NESTED" "$BASE_SETTINGS"
printf '%s' "$PANE" | fm_busy_claude_launch_prompt_tail \
  || fail "reproduction: the nested copy did not park on the imports dialog, so the guard proves nothing:
$PANE"
[ "$(printf '%s' "$PANE" | fm_busy_claude_launch_prompt_name)" = 'Allow external CLAUDE.md file imports?' ] \
  || fail "reproduction: the parked dialog is not the external-imports dialog:
$PANE"
pass "reproduction: a nested copy without the exclusion parks on 'Allow external CLAUDE.md file imports?'"

FRAGMENT=$(fm_claude_md_excludes_json "$NESTED")
[ -n "$FRAGMENT" ] || fail "the production helper produced no exclusion for a copy nested under a firstmate home"
launch_and_wait fixed "$NESTED" "{\"feedbackDrafts\":\"off\"$FRAGMENT}"
printf '%s' "$PANE" | fm_busy_claude_launch_prompt_tail \
  && fail "fixed: the nested copy still parked on a startup dialog with the production exclusion:
$PANE"
printf '%s' "$PANE" | grep -qE 'Claude Code v[0-9]' \
  || fail "fixed: the real binary never reached its banner with the production exclusion:
$PANE"
pass "fixed: the same nested copy launched with the production exclusion reaches the composer with no dialog"

# The real settings consumer, not an argv snapshot, must honor literal home
# paths containing glob metacharacters and shell-quote characters.
FRAGMENT=$(fm_claude_md_excludes_json "$ODD_NESTED")
launch_and_wait special_path "$ODD_NESTED" "{\"feedbackDrafts\":\"off\"$FRAGMENT}"
printf '%s' "$PANE" | fm_busy_claude_launch_prompt_tail \
  && fail "special-path: the nested copy still parked on a startup dialog with the production exclusion:
$PANE"
printf '%s' "$PANE" | grep -qE 'Claude Code v[0-9]' \
  || fail "special-path: the real binary never reached its banner:
$PANE"
pass "a nested home with ampersands, quotes, and glob metacharacters reaches the composer"

for source in none inline file; do
  launch_and_wait "raw_$source" "$ODD_NESTED" "{\"feedbackDrafts\":\"off\"$FRAGMENT}" "$source"
  printf '%s' "$PANE" | fm_busy_claude_launch_prompt_tail \
    && fail "raw-$source: the special-path nested copy still parked on a startup dialog:
$PANE"
  printf '%s' "$PANE" | grep -qE 'Claude Code v[0-9]' \
    || fail "raw-$source: the real binary never reached its banner:
$PANE"
  pass "raw launch with $source settings excludes special-character ancestor memory"
done

note "checked the nested-home memory exclusion against $VERSION_OUT"
cleanup_all
trap - EXIT
