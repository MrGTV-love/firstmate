function [ {
  local status=0
  builtin test "${@:1:$#-1}" || status=$?
  if builtin [ "$#" -eq 4 ] && builtin [ "$1" = '!' ] &&
    builtin [ "$2" = -r ] &&
    builtin [ "$3" = "${FM_CONFIG_OVERRIDE:-}/crew-exclude-tools" ]; then
    rm -f -- "$3"
  fi
  return "$status"
}
