function [ {
  local status=0
  builtin [ "$@" || status=$?
  return "$status"
}
