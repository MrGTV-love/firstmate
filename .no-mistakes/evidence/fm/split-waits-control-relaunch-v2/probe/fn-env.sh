# BASH_ENV probe for one group-script process (BASH_ENV is unset at once, so
# children never load it). Record each case the script's top level would invoke
# and skip it (extdebug: a DEBUG trap returning 1 skips the command). Bash 3.2
# re-fires the trap at exit with a stale command and a line past the last
# statement; a hit is recorded only when its script line starts with it.
unset BASH_ENV
shopt -s extdebug
__fm_inv_trap() {
  local word="${BASH_COMMAND%% *}" line
  case "$word" in
    test_*|control_relaunch_run) ;;
    *) return 0 ;;
  esac
  line=$(sed -n "${BASH_LINENO[0]}p" "$0")
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in
    "$word"|"$word "*) ;;
    *) return 0 ;;
  esac
  declare -f >"$FM_FN_OUT"
  if [ "$word" = control_relaunch_run ]; then
    printf '%s\n' "${control_relaunch_test_cases[@]}" >>"$FM_INV_OUT"
  else
    printf '%s\n' "$word" >>"$FM_INV_OUT"
  fi
  return 1
}
trap __fm_inv_trap DEBUG
