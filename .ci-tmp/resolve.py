import sys
p = 'bin/fm-status-decision-lib.sh'
L = open(p, encoding='utf-8', errors='surrogateescape').read().split('\n')
def block(a, b):  # 1-indexed inclusive
    return L[a-1:b]
assert L[176].startswith('<<<<<<< ') and L[198].startswith('>>>>>>> ')
assert L[211].startswith('<<<<<<< ') and L[351].startswith('>>>>>>> ')
assert L[412].startswith('<<<<<<< ') and L[514].startswith('>>>>>>> ')

note_head = block(178, 184)            # branch regex reader
status_line_note = block(213, 236)     # branch reader with the unstamped pass-through

key_and_drop = r'''_fm_decision_key_into() {  # <status-line> <keyless> <out-var> [<unstamped-line>] -> sets <out-var> to the key slug, or <keyless> when no token
  local __fm_dk_k __fm_dk_unstamped __fm_dk_head_re='^([^:]*)'
  if [ "$#" -gt 3 ]; then
    __fm_dk_unstamped=$4
  else
    _fm_status_unstamped "$1" __fm_dk_unstamped
  fi
  if _fm_key_before_colon "$__fm_dk_unstamped"; then
    _fm_status_bytes_match "$__fm_dk_unstamped" "$__fm_dk_head_re" && __fm_dk_k=${BASH_REMATCH[1]}
    __fm_dk_k=${__fm_dk_k#*\[key=}
    __fm_dk_k=${__fm_dk_k%%\]*}
  elif ! _fm_key_at_note_head "$__fm_dk_unstamped" __fm_dk_k; then
    printf -v "$3" '%s' "$2"
    return 0
  fi
  _fm_decision_slug_ok "$__fm_dk_k" || return 1
  printf -v "$3" '%s' "$__fm_dk_k"
}
_fm_decision_key() {  # <status-line> [<keyless>] -> key slug, or <keyless> (default "default") when no token
  local __fm_dk_out
  _fm_decision_key_into "$1" "${2-default}" __fm_dk_out || return 1
  printf '%s' "$__fm_dk_out"
}
# Drop the record for <key> from a newline-separated "<key>\t<verb>\t<note>" set.
# Stdout terminates a nonempty result with a newline; <out-var> strips trailing
# newlines to match command substitution. Portable on bash 3.2 (no associative arrays).
_fm_decision_drop() {  # <open-set> <key> [<out-var>]
  local __fm_drop_key=${2//./\\.} __fm_drop_re __fm_drop_prefix __fm_drop_suffix __fm_drop_out=$1
  # Keys contain only slug characters (or the internal keyless marker). Escape
  # their dots, and capture the neighboring records in one regex match: bash
  # 3.2's glob substitutions and bytewise read loops are costly on wide sets.
  # Every expansion below runs on the whole set and looks only for a newline
  # byte, so the function reads the set as bytes throughout.
  local LC_ALL=C
  while [[ "$__fm_drop_out" == *$'\n' ]]; do __fm_drop_out=${__fm_drop_out%$'\n'}; done
  __fm_drop_re='^((.*)'$'\n'')?'"$__fm_drop_key"$'\t''[^'$'\n'']*('$'\n''(.*))?$'
  # Most routine resolutions name no open key; leave the set alone in that case.
  if _fm_status_bytes_match "$__fm_drop_out" "$__fm_drop_re"; then
    __fm_drop_prefix=${BASH_REMATCH[2]}
    __fm_drop_suffix=${BASH_REMATCH[4]}
    [ -z "$__fm_drop_prefix" ] || [ -z "$__fm_drop_suffix" ] || __fm_drop_prefix="$__fm_drop_prefix"$'\n'
    __fm_drop_out=$__fm_drop_prefix$__fm_drop_suffix
  fi
  if [ "$#" -gt 2 ]; then
    printf -v "$3" '%s' "$__fm_drop_out"
  elif [ -n "$__fm_drop_out" ]; then
    printf '%s\n' "$__fm_drop_out"
  fi
}
# Fold one status line into a newline-separated "<key>\t<verb>\t<note>" open set.
# status_open_decisions below owns the transition contract; the folds call the
# out-var form and the stdout wrapper serves command-substitution callers.
# Both return the same set with no trailing newlines, preserving the bytes the
# original command-substitution callers stored in checkpoints. No file I/O.'''.split('\n')

fold = r'''_fm_decision_fold_line_into() {  # <open-set> <status-line> <resolve-verb> <held-verb> <kind> <out-var> [<note-id> <note-var>]
  local __fm_fl_open=$1 __fm_fl_verb __fm_fl_key __fm_fl_note __fm_fl_unstamped
  # Match the old command substitution, including on non-transition returns.
  while [[ "$__fm_fl_open" == *$'\n' ]]; do __fm_fl_open=${__fm_fl_open%$'\n'}; done
  printf -v "$6" '%s' "$__fm_fl_open"
  # The dated reader stores summaries separately: retain its small record ID
  # instead of rereading every open summary on each later transition. Guards
  # still inspect the real note, and accepted openings return that note to it.
  [ "$#" -lt 8 ] || printf -v "$8" '%s' ''
  status_line_verb "$2" __fm_fl_verb
  # Only an opener can change an empty set; routine closes need no key/note parse.
  case "$__fm_fl_verb" in
    needs-decision|blocked) ;;
    *) [ -n "$__fm_fl_open" ] || return 0 ;;
  esac
  # Normalize once for the colon guards and both key/note readers; repeating
  # timestamp stripping for each reader dominates wide-log parsing on bash 3.2.'''.split('\n')

fold_mid = block(442, 446) + ['  _fm_status_unstamped "$2" __fm_fl_unstamped'] + block(452, 458)

fold_tail = r'''  case "$__fm_fl_unstamped" in
    *:*|*\[key=*\]*) ;;
    *) return 0 ;;
  esac
  case "$__fm_fl_unstamped" in
    *:*) case "$__fm_fl_verb:$5" in
      done:ship|done:scout|failed:ship|failed:scout) printf -v "$6" '%s' ''; return 0 ;;
    esac ;;
  esac
  case "$__fm_fl_verb" in
    needs-decision|blocked|"$3"|"$4") ;;
    *) return 0 ;;
  esac
  _fm_decision_key_into "$2" default __fm_fl_key "$__fm_fl_unstamped" || return 0
  status_line_note "$2" __fm_fl_note "$__fm_fl_unstamped"
  while [[ "$__fm_fl_note" == *$'\n' ]]; do __fm_fl_note=${__fm_fl_note%$'\n'}; done
  _fm_decision_key_transition_allowed "$__fm_fl_key" "$__fm_fl_note" || return 0
  _fm_decision_drop "$__fm_fl_open" "$__fm_fl_key" __fm_fl_open
  case "$__fm_fl_verb" in
    needs-decision|blocked)
      [ -n "$__fm_fl_open" ] && __fm_fl_open+=$'\n'
      __fm_fl_open+="${__fm_fl_key}"$'\t'"${__fm_fl_verb}"$'\t'"${7-$__fm_fl_note}"
      [ "$#" -lt 8 ] || printf -v "$8" '%s' "$__fm_fl_note"
      ;;
  esac
  printf -v "$6" '%s' "$__fm_fl_open"
}
_fm_decision_fold_line() {  # <open-set> <status-line> <resolve-verb> <held-verb> <kind>
  local __fm_fl_out
  _fm_decision_fold_line_into "$1" "$2" "$3" "$4" "$5" __fm_fl_out
  printf '%s' "$__fm_fl_out"'''.split('\n')

out = L[:176] + note_head + L[199:211] + status_line_note + key_and_drop + L[352:412] + fold + fold_mid + fold_tail + L[515:]
text = '\n'.join(out)
assert '<<<<<<<' not in text and '>>>>>>>' not in text
for old in ('_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind" open',):
    assert text.count(old) == 3, text.count(old)
    text = text.replace(old, '_fm_decision_fold_line_into "$open" "$line" "$resolve" "$held" "$kind" open')
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(text)
