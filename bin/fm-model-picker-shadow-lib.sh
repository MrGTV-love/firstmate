#!/usr/bin/env bash
# fm-model-picker-shadow-lib.sh - the one owner of the FM_MODEL_PICKER_SHADOW allowlist.
#
# Sourced, never executed, by bin/fm-dispatch-resolve.sh and bin/fm-model-picker-shadow.sh.
#
#   fm_model_picker_shadow_enabled
#       Returns 0 only when FM_MODEL_PICKER_SHADOW is 1/true/on/yes/shadow. Empty, 0,
#       false, off and no return 1 silently; any other value returns 1 with one stderr
#       warning. No value enables live mode. It reads no model-picker data.
#
# docs/configuration.md "Shadow model picker (FM_MODEL_PICKER_SHADOW)" owns the flag contract.

fm_model_picker_shadow_enabled() {
  case "${FM_MODEL_PICKER_SHADOW:-}" in
    1|true|True|TRUE|on|On|ON|yes|Yes|YES|shadow|Shadow|SHADOW) return 0 ;;
    ''|0|false|False|FALSE|off|Off|OFF|no|No|NO) return 1 ;;
    *live*|*Live*|*LIVE*)
      printf 'model-picker-shadow: FM_MODEL_PICKER_SHADOW cannot enable live mode; shadow stays off\n' >&2
      return 1 ;;
    *)
      printf 'model-picker-shadow: unrecognized FM_MODEL_PICKER_SHADOW value; shadow stays off\n' >&2
      return 1 ;;
  esac
}
