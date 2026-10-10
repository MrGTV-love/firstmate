bash --version | head -1; grep --version | head -1
export LC_ALL=C.utf8
printf 'needs-decision [key=c]: trunc \xe2\x80\nresolved [key=c]: done\n' > /tmp/f
while IFS= read -r l || [ -n "$l" ]; do printf '[%q]\n' "$l"; done < /tmp/f
echo "-- grep plain:"; grep -E '^(needs|resolved)' /tmp/f; echo "rc=$?"
echo "-- grep -a:"; grep -a -E '^(needs|resolved)' /tmp/f | od -c | head -3
