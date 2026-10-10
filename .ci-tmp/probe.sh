LC_ALL=C.utf8
printf 'needs-decision [key=c] [at=10:30]: trunc \xe2\x80\nresolved [key=c]: done\nx: y\n' > /tmp/f
echo "--- read loop"; while IFS= read -r l || [ -n "$l" ]; do printf '[%q]\n' "$l"; done < /tmp/f
echo "--- heredoc read"; s=$(cat /tmp/f); while IFS= read -r l; do printf '[%q]\n' "$l"; done <<E
$s
E
echo "--- local C regex"; m() { local LC_ALL=C; [[ "$1" =~ $2 ]]; }
line=$'needs-decision [key=c] [at=10:30]: trunc \xe2\x80'
m "$line" '^[^:]*:(.*)$' && printf 'note=[%q]\n' "${BASH_REMATCH[1]}"
v=${BASH_REMATCH[1]}; v=${v#"${v%%[![:space:]]*}"}; printf 'trim=[%q]\n' "$v"
set1=$'c\tneeds-decision\ttrunc \xe2\x80'
d() { local LC_ALL=C; local re='^((.*)'$'\n'')?c'$'\t''[^'$'\n'']*('$'\n''(.*))?$'; [[ "$1" =~ $re ]] && echo dropmatch || echo dropnomatch; }
d "$set1"
