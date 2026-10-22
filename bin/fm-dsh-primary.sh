#!/usr/bin/env bash
# Start a pane-hosted dsh-tui primary with the tracked native Cordis plugin.
# Usage: fm-dsh-primary.sh [--model deepseek/<id>] [--effort <level>] [--resume] [-- <opening-prompt>]
#        fm-dsh-primary.sh inspect <home>   internal read-only ownership/need query
# FM_HOME selects the operational home; no global DSH profile is modified.
# --resume continues the bound primary conversation, or starts fresh if absent.
# The plugin owns session-open delivery, one tracked watcher and passive
# turn-end follow-up; docs/supervision-protocols/dsh.md owns agent instructions.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
if [ "${1:-}" = inspect ]; then
  [ "$#" = 2 ] || { echo 'error: inspect requires exactly one home' >&2; exit 2; }
  home=$2
  fm_primary_scope_matches "$home" "$home/state" || exit 3
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  fm_session_lock_owned_by_self "$home/state" || exit 4
  # shellcheck source=bin/fm-supervision-lib.sh
  . "$SCRIPT_DIR/fm-supervision-lib.sh"
  if fm_supervision_needed "$home/state"; then
    # shellcheck source=bin/fm-supervision-engine-lib.sh
    . "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
    if fm_supervision_host_enabled "$home/config" dsh; then echo host; else echo watch; fi
  else
    echo idle
  fi
  exit 0
fi
MODEL=deepseek/deepseek-v4-flash
EFFORT=high
RESUME=0
PROMPT='Follow the Firstmate session-start digest supplied by the native primary plugin. Reconcile existing work; do not invent work.'
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--effort)
      [ "$#" -gt 1 ] && [ -n "$2" ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in --model) MODEL=$2 ;; --effort) EFFORT=$2 ;; esac
      shift 2 ;;
    --resume) RESUME=1; shift ;;
    --)
      shift
      [ "$#" = 1 ] && [ -n "$1" ] || { echo 'error: -- requires exactly one non-empty opening prompt' >&2; exit 2; }
      PROMPT=$1
      shift ;;
    --help|-h)
      echo 'Usage: fm-dsh-primary.sh [--model deepseek/<id>] [--effort low|medium|high|xhigh|max] [--resume] [-- <opening-prompt>]'
      echo 'Launch from the Firstmate home. FM_HOME selects an alternate primary home.'
      exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done
FM_HOME=${FM_HOME:-$ROOT}
FM_HOME=$(cd "$FM_HOME" && pwd -P)
fm_primary_root_matches "$FM_HOME" || { echo "error: $FM_HOME is not a primary Firstmate home" >&2; exit 1; }
# shellcheck source=bin/fm-dsh-lib.sh
. "$SCRIPT_DIR/fm-dsh-lib.sh"
DSH_BIN=$(fm_dsh_executable)
fm_dsh_launch_check "$DSH_BIN" primary
python3 "$SCRIPT_DIR/fm-dsh.py" check dsh "$MODEL"
mkdir -p "$FM_HOME/state"
RUNTIME=
if [ "$RESUME" = 1 ]; then
  RUNTIME=$(python3 "$SCRIPT_DIR/fm-dsh.py" resume "$FM_HOME/state" dsh-primary "$MODEL" "$EFFORT" "$FM_HOME" --primary-root "$ROOT")
fi
if [ -z "$RUNTIME" ]; then
  RUNTIME=$(python3 "$SCRIPT_DIR/fm-dsh.py" prepare-primary "$FM_HOME/state" dsh-primary "$(date +%s).$$" "${DSH_HOME:-$HOME/.dsh}" "$MODEL" "$EFFORT" "$FM_HOME" "$ROOT")
fi
cd "$FM_HOME"
exec env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS -u FM_OMP_HARNESS -u GEMINI_CLI -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u HERDR_ENV \
  FM_DSH_HARNESS=dsh FM_DSH_OPERATOR_HOME="${FM_DSH_OPERATOR_HOME:-$HOME}" FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_HOME" \
  GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$HOME/.gitconfig}" NM_HOME="${NM_HOME:-$HOME/.no-mistakes}" \
  HOME="$RUNTIME/home" DSH_HOME="$RUNTIME/dsh" DSH_TUI_LANG=en DSH_TUI_NO_LAUNCHPAD=1 \
  DSH_PERMISSION_MODE=danger-full-access PATH="$PATH" "$DSH_BIN" --patch "$RUNTIME/launch.yml" -- \
  "$PROMPT"
