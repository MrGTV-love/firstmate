#!/usr/bin/env bash
# Drive fm-gh-rest.sh (base vs target): KILL a read mid-call, then run one normal read.
# Count what is left in a private, empty TMPDIR.
set -u
WT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/nm-drive-ghrest.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/base" "$W/fake"
git -C "$WT" archive e27bbad9baa221fce4a159677c4f1046848b8d44 bin | tar -x -C "$W/base"
cat > "$W/fake/gh" <<'G'
#!/usr/bin/env bash
case "${FAKE_GH_MODE:-ok}" in
  ok) printf 'HTTP/2.0 200 OK\r\nETag: "abc"\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Reset: 4102444800\r\nX-Ratelimit-Resource: core\r\n\r\n[1]' ;;
  stall) printf '%s\n' "$$" > "$FAKE_STALL_PIDFILE"; exec sleep 120 ;;
esac
G
chmod +x "$W/fake/gh"
for side in base target; do
  if [ $side = base ]; then BIN=$W/base/bin; else BIN=$WT/bin; fi
  T=$W/tmp-$side; mkdir -p "$T" "$W/state-$side"
  rm -f "$W/pid"
  env TMPDIR="$T" FAKE_GH_MODE=stall FAKE_STALL_PIDFILE="$W/pid" FM_STATE_OVERRIDE="$W/state-$side" PATH="$W/fake:$PATH" \
    bash "$BIN/fm-gh-rest.sh" get repos/o/r/items >/dev/null 2>&1 &
  cmd=$!
  for _ in $(seq 100); do [ -s "$W/pid" ] && break; sleep 0.1; done
  echo "== $side: entries while a read is in flight:"; (cd "$T" && find . -mindepth 1 | sort | sed 's/^/   /')
  kill -KILL $cmd; wait $cmd 2>/dev/null; kill "$(cat "$W/pid")" 2>/dev/null
  echo "== $side: entries after KILL of the read:"; (cd "$T" && find . -mindepth 1 | sort | sed 's/^/   /')
  env TMPDIR="$T" FAKE_GH_MODE=ok FM_STATE_OVERRIDE="$W/state-$side" PATH="$W/fake:$PATH" \
    bash "$BIN/fm-gh-rest.sh" get repos/o/r/items >/dev/null 2>&1; echo "   next normal read exit=$?"
  n=$(find "$T" -mindepth 1 | wc -l | tr -d ' ')
  echo "== $side: entries after the next normal read: $n"; (cd "$T" && find . -mindepth 1 | sort | sed 's/^/   /')
done
