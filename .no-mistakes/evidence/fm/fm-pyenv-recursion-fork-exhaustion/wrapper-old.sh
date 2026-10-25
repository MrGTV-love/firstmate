function [ {
  local status=0
  builtin test "${@:1:$#-1}" || status=$?
  return "$status"
}
