#!/usr/bin/env bash
# fm-model-picker-shadow.sh - benchmark-informed model picker in SHADOW MODE ONLY.
# Usage:
#   fm-model-picker-shadow.sh --observe [--brief PATH] [--task-text PATH] [--rules PATH]
#        [--result PATH] [--quota PATH] [--status STATUS] [--reason TEXT]
#        [--never-send PATH] [--project NAME] [--data-root PATH] [--hook spawn]
#   fm-model-picker-shadow.sh --report
#   fm-model-picker-shadow.sh --check-routes [--rules PATH]
#
# --observe records what the picker WOULD have chosen beside the route the current dispatch
#   rules chose, or with --hook spawn the route that actually launched. It never prints,
#   returns or writes a dispatch route, and never changes what dispatches: every failure
#   exits 0 with one stderr warning. It is off unless
#   FM_MODEL_PICKER_SHADOW is an on value; bin/fm-model-picker-shadow-lib.sh owns that
#   allowlist for this tool and the resolver. The resolver calls it after its own result is produced,
#   bounded by bin/fm-timeout-lib.sh; this tool never becomes a dispatch dependency. A resolver
#   row leaves a one-shot <data root>/resolver-rows/<task id> marker holding its row id;
#   bin/fm-model-picker-shadow-spawn.sh passes --hook spawn, which consumes that marker and sets
#   that row's rule route to the route that actually launched, so one dispatch is one row.
# --report prints the per-work-type shadow disagreement report from aa.sqlite. It is routing
#   evidence, never outcome labels, and prints "0 shadow dispatches logged" for an empty log.
# --check-routes is read-only: it resolves every concrete route in config/crew-dispatch.json
#   through the fleet model index, then asserts each mapped projection's identity against
#   bin/fm_model_picker/routes.json. Exit 1 when a mapped route's projection is missing or its
#   asserted name or creator does not match; an unmapped route is listed as UNKNOWN and is not
#   dropped.
#
# Data root: FM_MODEL_PICKER_DATA, else <FM_DATA_OVERRIDE>/model-picker, else
#   <FM_HOME>/data/model-picker. The calibration store is <data root>/aa.sqlite; this tool
#   only inserts dispatch_log rows (and, with --hook spawn, sets a resolver row's rule route and
#   gates) and never touches the benchmark matrix or verdict.json.
#
# Key handling: the TypeSafe key reaches bin/fm_model_picker/shadow.py on file descriptor 3,
#   never on argv, never exported, never written. When no caller supplies fd 3, the shared
#   accessor fm_typesafe_key resolves it exactly as the resolver does. Every request passes
#   bin/fm-typesafe-lib.sh's never-send filter before it leaves the machine: --never-send, else
#   <FM_CONFIG_OVERRIDE or FM_HOME/config>/dispatch-never-send; a policy that cannot be checked
#   withholds the request.
#
# Exit codes: --observe always 0 (a picker failure never changes a dispatch);
#   --report 2 only when the log cannot be read; --check-routes 1 on a missing or
#   identity-refused mapping, 2 when the rules cannot be resolved.
#
# The picker core is bin/fm_model_picker/shadow.py; the route table is
# bin/fm_model_picker/routes.json; one policy-checked POST per bounded Jev judgment goes
# through bin/fm-model-picker-jev.sh. docs/configuration.md "Shadow model picker
# (FM_MODEL_PICKER_SHADOW)" is the operator contract and owns the flag, the shadow-only
# guarantee, the integration point, every logged column, the seed-policy label and the
# captain-owned later phases left out.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help)
    [ "$#" -eq 1 ] || { printf 'error: --help takes no arguments\n' >&2; exit 2; }
    awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
    exit 0
    ;;
esac
command -v python3 >/dev/null 2>&1 || { printf 'error: Python 3 is required for the shadow picker\n' >&2; exit 2; }

ACTION=''
for arg in "$@"; do
  case "$arg" in --observe|--report|--check-routes) ACTION=${arg#--}; break ;; esac
done
[ -n "$ACTION" ] || { printf 'error: one of --observe, --report or --check-routes is required (see --help)\n' >&2; exit 2; }

FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$SCRIPT_DIR/..}}"
if [ -n "${FM_MODEL_PICKER_DATA:-}" ]; then
  DATA_ROOT=$FM_MODEL_PICKER_DATA
elif [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  DATA_ROOT="$FM_DATA_OVERRIDE/model-picker"
else
  DATA_ROOT="$FM_HOME/data/model-picker"
fi

if [ "$ACTION" = observe ]; then
  # shellcheck source=bin/fm-model-picker-shadow-lib.sh
  . "$SCRIPT_DIR/fm-model-picker-shadow-lib.sh"
  fm_model_picker_shadow_enabled || exit 0
  if [ ! -e /dev/fd/3 ]; then
    # shellcheck source=bin/fm-typesafe-lib.sh
    . "$SCRIPT_DIR/fm-typesafe-lib.sh"
    if ! fm_typesafe_key "$FM_HOME"; then
      printf 'model-picker-shadow: off (no TypeSafe key; dispatch unchanged)\n' >&2
      exit 0
    fi
    exec 3< <(printf '%s\n' "$TYPESAFE_API_KEY_PRIVATE")
  fi
fi

FM_HOME="$FM_HOME" PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1 \
  exec python3 -m fm_model_picker.shadow --data-root "$DATA_ROOT" "$@"
