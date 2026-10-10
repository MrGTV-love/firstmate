export LC_ALL=C.utf8
mkdir -p /tmp/s; f=/tmp/s/lane.status; printf 'kind=secondmate\n' > /tmp/s/lane.meta
{
  printf 'needs-decision [key=c] [at=10:30]: trunc \xe2\x80\n'
  printf 'resolved [key=c]: done\n'
  printf 'needs-decision [key=p]: caf\xe9\n'
  printf 'resolved [key=p]: done\n'
} > "$f"
for lib in /p/base/bin /src/bin; do
  echo "== $lib"; ( . "$lib/fm-classify-lib.sh"; status_open_decisions "$f" | od -c | head -8 )
done
{
  printf 'needs-decision [key=c] [at=10:30]: trunc \xe2\x80.\n'
  printf 'resolved [key=c]: done\n'
  printf 'needs-decision [key=p]: caf\xe9.\n'
  printf 'needs-decision [key=q]: \xff bad\n'
  printf 'resolved [key=q]: done\n'
} > "$f"; rm -f /tmp/s/.[!.]* 2>/dev/null
for lib in /p/base/bin /src/bin; do
  echo "== midline $lib"; ( . "$lib/fm-classify-lib.sh"; status_open_decisions "$f" | od -c | head -8 )
done
