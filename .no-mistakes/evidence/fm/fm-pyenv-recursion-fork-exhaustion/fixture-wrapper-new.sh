function [ {
  local status=0
  # Bash 3.2 collapses a quoted argument slice when IFS=: (as in pyenv-prefix).
  # Forward the complete argv to the matching builtin, including its closing ].
  builtin [ "$@" || status=$?
  if builtin [ "$#" -eq 4 ] && builtin [ "$1" = '!' ] &&
    builtin [ "$2" = -r ] &&
    builtin [ "$3" = "${FM_CONFIG_OVERRIDE:-}/crew-exclude-tools" ]; then
    rm -f -- "$3"
  fi
  return "$status"
}
