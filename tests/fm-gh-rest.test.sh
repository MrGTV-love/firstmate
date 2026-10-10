#!/usr/bin/env bash
# Behavioral tests for bin/fm-gh-rest.sh: conditional REST GETs through a per-URL ETag cache and the
# shared quota floor. The fake gh speaks `gh api -i` (status line, headers, body), keeps a call log that
# separates counted requests from 304s, and pages with Link headers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-gh-rest.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-rest-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/gh" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, re, sys, time
args = sys.argv[1:]
assert args[:2] == ['api', '-i'], args
site = os.environ['FAKE_GH_SITE']
endpoint = args[-1]
conditional = next((args[i + 1].split(':', 1)[1].strip() for i, a in enumerate(args) if a == '-H'), None)
def log(kind):
    with open(site + '/calls', 'a') as stream:
        stream.write(kind + ' ' + endpoint + (' [conditional]' if conditional else '') + '\n')
if os.path.exists(site + '/fail'):
    log('counted')
    sys.stderr.write('gh: HTTP 502\n')
    sys.stdout.write('HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"bad gateway"}')
    sys.exit(1)
pages = json.load(open(site + '/pages.json'))
index = 0
match = re.search(r'[?&]page=(\d+)', endpoint)
if match:
    index = int(match[1]) - 1
body = json.dumps(pages[index])
etag = '"' + hashlib.sha1(body.encode()).hexdigest()[:16] + '"'
rate = ('X-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: ' + os.environ.get('FAKE_GH_REMAINING', open(site + '/remaining').read().strip())
        + '\r\nX-Ratelimit-Reset: ' + os.environ.get('FAKE_GH_RESET', open(site + '/reset').read().strip()) + '\r\nX-Ratelimit-Resource: core\r\n')
link = ''
per_page = re.search(r'[?&]per_page=(\d+)', endpoint)
per_page = per_page[1] if per_page else '2'
if index + 1 < len(pages):
    link = 'Link: <https://api.github.com/repositories/1/items?per_page=%s&page=%d>; rel="next"\r\n' % (per_page, index + 2)
elif os.path.exists(site + '/terminal-link'):
    link = 'Link: <https://api.github.com/repositories/1/items?per_page=%s&page=1>; rel="prev"\r\n' % per_page
delay = os.environ.get('FAKE_GH_DELAY') if index == 0 else None
if delay:
    open(site + '/' + delay + '.ready', 'w').close()
    deadline = time.monotonic() + 10
    while not os.path.exists(site + '/' + delay + '.release'):
        if time.monotonic() >= deadline:
            sys.exit('response barrier timed out')
        time.sleep(0.01)
if conditional == etag:
    if os.path.exists(site + '/omit-304-link'):
        link = ''
    log('not-modified')
    sys.stdout.write('HTTP/2.0 304 Not Modified\r\nEtag: ' + etag + '\r\n' + rate + link + '\r\n')
    sys.stderr.write('gh: HTTP 304\n')
    sys.exit(1)
log('counted')
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: ' + etag + '\r\n' + rate + link + '\r\n' + body)
PY
chmod +x "$FAKEBIN/gh"

new_site() { # name -> a fresh forge/state pair with one page of data
  local site="$TMP_ROOT/$1"
  mkdir -p "$site/state"
  printf '[[{"id":1},{"id":2}]]\n' > "$site/pages.json"
  printf '4000\n' > "$site/remaining"
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$site/reset"
  printf '%s\n' "$site"
}

get() { # site args... : run the helper against the fake forge
  local site=$1
  shift
  PATH="$FAKEBIN:$PATH" FAKE_GH_SITE="$site" FM_STATE_OVERRIDE="$site/state" "$HELPER" get "$@"
}

counted() { grep -c '^counted ' "$1/calls" 2>/dev/null || true; }
unmodified() { grep -c '^not-modified ' "$1/calls" 2>/dev/null || true; }

test_304_serves_cached_body_without_a_counted_call() {
  local site first second
  site=$(new_site conditional)
  first=$(get "$site" repos/o/r/items) || fail 'first read failed'
  second=$(get "$site" repos/o/r/items) || fail 'second read failed'
  [ "$first" = "$second" ] || fail "a 304 changed the served body: $first vs $second"
  assert_equals 1 "$(counted "$site")" 'the repeated read of unchanged data was counted against the limit'
  assert_equals 1 "$(unmodified "$site")" 'the repeated read was not sent as a conditional request'
  assert_contains "$(cat "$site/calls")" '[conditional]' 'no If-None-Match was sent'
  pass 'a 304 serves the cached body without a new counted call'
}

test_changed_data_replaces_the_cache() {
  local site out
  site=$(new_site changed)
  get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
  printf '[[{"id":1},{"id":2},{"id":3}]]\n' > "$site/pages.json"
  out=$(get "$site" repos/o/r/items) || fail 'read after change failed'
  assert_contains "$out" '"id":3' 'a changed resource was served from the stale cache'
  get "$site" repos/o/r/items >/dev/null || fail 'read after replace failed'
  assert_equals 2 "$(counted "$site")" 'only the changed read should have been counted'
  assert_equals 1 "$(unmodified "$site")" 'the refreshed entry was not reused'
  pass 'changed data is fetched once and the refreshed entry is reused'
}

test_missing_or_corrupt_cache_falls_back_to_a_normal_get() {
  local site entry out
  site=$(new_site fallback)
  get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
  rm -rf "$site/state/gh-rest-cache"
  out=$(get "$site" repos/o/r/items) || fail 'read without a cache failed'
  assert_contains "$out" '"id":1' 'a missing cache did not fall back to a normal read'
  entry=$(find "$site/state/gh-rest-cache" -name '*.json' | head -1)
  [ -n "$entry" ] || fail 'the normal read did not repopulate the cache'
  printf 'not json\n' > "$entry"
  out=$(get "$site" repos/o/r/items) || fail 'read with a corrupt cache failed'
  assert_contains "$out" '"id":1' 'a corrupt cache entry was served or broke the read'
  printf '{"etag":"\\"stale\\"","body":"{broken"}\n' > "$entry"
  out=$(get "$site" repos/o/r/items) || fail 'read with an unparsable cached body failed'
  assert_contains "$out" '"id":1' 'an unparsable cached body was served'
  assert_equals 4 "$(counted "$site")" 'each fallback should be one ordinary counted GET'
  assert_equals 0 "$(grep -c '\[conditional\]' "$site/calls")" 'a missing or unusable cache must not send If-None-Match'
  pass 'a missing, corrupt, or unparsable cache falls back to a normal GET'
}

test_pagination_follows_link_and_caches_every_page() {
  local site out
  site=$(new_site paged)
  printf '[[{"id":1},{"id":2}],[{"id":3}]]\n' > "$site/pages.json"
  out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'paged read failed'
  assert_equals '[[{"id":1},{"id":2}],[{"id":3}]]' "$(printf '%s' "$out" | jq -c .)" 'pages were not slurped in order'
  out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'repeated paged read failed'
  assert_equals '[[{"id":1},{"id":2}],[{"id":3}]]' "$(printf '%s' "$out" | jq -c .)" 'cached pages were not stitched back together'
  assert_equals 2 "$(counted "$site")" 'the repeated paged read was counted'
  assert_equals 2 "$(unmodified "$site")" 'every page of the repeated read should be a 304'
  pass 'pagination follows Link and every page rides the cache'
}

test_304_updates_pagination_and_retains_omitted_metadata() {
  local site out
  site=$(new_site changed_links)
  get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp >/dev/null || fail 'seed read failed'
  printf '[[{"id":1},{"id":2}],[{"id":3}]]\n' > "$site/pages.json"
  out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'expanded read failed'
  assert_equals '[[{"id":1},{"id":2}],[{"id":3}]]' "$out" 'a new page behind an unchanged first page was omitted'
  : > "$site/omit-304-link"
  out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'read with omitted links failed'
  assert_equals '[[{"id":1},{"id":2}],[{"id":3}]]' "$out" 'current pagination metadata was not cached'
  rm "$site/omit-304-link"
  : > "$site/terminal-link"
  printf '[[{"id":1},{"id":2}]]\n' > "$site/pages.json"
  out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'contracted read failed'
  assert_equals '[[{"id":1},{"id":2}]]' "$out" 'a supplied Link without next retained a removed page'
  : > "$site/omit-304-link"
  out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'repeated contracted read failed'
  assert_equals '[[{"id":1},{"id":2}]]' "$out" 'cleared pagination metadata was not cached'
  pass '304 pagination metadata adds and removes pages, and survives omitted headers'
}

test_full_last_page_without_304_link_finds_the_next_page() {
  local site out endpoint='repos/o/r/issues/1/comments?per_page=100'
  site=$(new_site full_last_page)
  : > "$site/omit-304-link"
  jq -nc '[[range(1; 100) | {id: .}]]' > "$site/pages.json"
  get "$site" "$endpoint" --paginate --slurp >/dev/null || fail 'seed read of 99 comments failed'
  get "$site" "$endpoint" --paginate --slurp >/dev/null || fail 'repeated read of 99 comments failed'
  assert_equals 1 "$(counted "$site")" 'a partial last page was re-read unconditionally'
  jq -nc '[[range(1; 101) | {id: .}]]' > "$site/pages.json"
  get "$site" "$endpoint" --paginate --slurp >/dev/null || fail 'seed read of 100 comments failed'
  out=$(get "$site" "$endpoint" --paginate --slurp) || fail 'repeated read of 100 comments failed'
  assert_equals 100 "$(printf '%s' "$out" | jq 'add | length')" 'the full page of 100 comments was not served'
  get "$site" "$endpoint" >/dev/null || fail 'single-page read of 100 comments failed'
  assert_equals 3 "$(counted "$site")" 'a full last page costs one unconditional GET per paginated read only'
  jq -nc '[[range(1; 101) | {id: .}], [{id: 101}]]' > "$site/pages.json"
  out=$(get "$site" "$endpoint" --paginate --slurp) || fail 'read of 101 comments failed'
  assert_equals 101 "$(printf '%s' "$out" | jq 'add | length')" 'comment 101 behind an unchanged full page was missed'
  assert_equals 101 "$(printf '%s' "$out" | jq '.[1][0].id')" 'the new page did not carry comment 101'
  pass 'a full cached last page whose 304 omits Link is re-read, so comment 101 is found'
}

test_304_uses_its_generation_during_concurrent_replacement() {
  local site mode older_pid conditional_pid n out
  for mode in supplied omitted; do
    site=$(new_site "generation-$mode")
    get "$site" 'repos/o/r/items?per_page=2' >/dev/null || fail 'seed generation failed'
    printf '[[{"id":2}]]\n' > "$site/pages.json"
    FAKE_GH_DELAY=older get "$site" 'repos/o/r/items?per_page=2' > "$site/older.out" &
    older_pid=$!
    for ((n=0; n<500; n++)); do
      [ ! -e "$site/older.ready" ] || break
      sleep 0.01
    done
    [ "$n" -lt 500 ] || fail 'older response did not reach its barrier'
    if [ "$mode" = omitted ]; then
      printf '[[{"id":3}],[{"id":4}]]\n' > "$site/pages.json"
    else
      printf '[[{"id":3}]]\n' > "$site/pages.json"
    fi
    get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp >/dev/null || fail 'newer generation failed'
    printf '[[{"id":3}],[{"id":4}]]\n' > "$site/pages.json"
    [ "$mode" != omitted ] || : > "$site/omit-304-link"
    FAKE_GH_DELAY=conditional get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp > "$site/conditional.out" &
    conditional_pid=$!
    for ((n=0; n<500; n++)); do
      [ ! -e "$site/conditional.ready" ] || break
      sleep 0.01
    done
    [ "$n" -lt 500 ] || fail 'conditional response did not reach its barrier'
    : > "$site/older.release"
    wait "$older_pid" || fail 'older response failed'
    : > "$site/conditional.release"
    wait "$conditional_pid" || fail 'conditional response failed'
    assert_equals '[[{"id":3}],[{"id":4}]]' "$(cat "$site/conditional.out")" "a 304 with $mode links used another generation"
    printf '[[{"id":2}]]\n' > "$site/pages.json"
    : > "$site/omit-304-link"
    out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp) || fail 'replacement generation read failed'
    assert_equals '[[{"id":2}]]' "$out" 'a 304 rewrote another generation or its links'
    assert_equals 4 "$(counted "$site")" 'the replaced generation was not retained for a conditional read'
  done
  pass 'a concurrent 304 serves its ETag generation without rewriting the replacement body or links'
}

test_a_failed_read_exits_nonzero_and_caches_nothing() {
  local site status=0 err
  site=$(new_site failing)
  : > "$site/fail"
  err=$(get "$site" repos/o/r/items 2>&1 >/dev/null) || status=$?
  [ "$status" -ne 0 ] || fail 'a forge error exited zero'
  assert_contains "$err" 'HTTP 502' 'the forge error was swallowed'
  [ ! -d "$site/state/gh-rest-cache" ] || [ -z "$(find "$site/state/gh-rest-cache" -name '*.json')" ] \
    || fail 'an error response was cached'
  pass 'a failed read exits nonzero, names the error, and caches nothing'
}

test_recording_failures_do_not_block_reads() {
  local mode response site out status previous
  for mode in readonly contended; do
    for response in fresh cached error; do
      site=$(new_site "recording-$mode-$response")
      previous=''
      if [ "$response" = cached ]; then
        get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
        previous=$(cat "$site/state/gh-ratelimit.core.json")
      elif [ "$response" = error ]; then
        : > "$site/fail"
      fi
      printf '3000\n' > "$site/remaining"
      if [ "$mode" = readonly ]; then
        chmod 0500 "$site/state"
      else
        mkdir "$site/state/gh-ratelimit.core.json.lock"
        printf '%s\n' "$$" > "$site/state/gh-ratelimit.core.json.lock/pid"
      fi
      status=0
      out=$(PATH="$FAKEBIN:$PATH" FAKE_GH_SITE="$site" FM_STATE_OVERRIDE="$site/state" \
        python3 - "$HELPER" 2>"$site/error" <<'PY'
import os, signal, subprocess, sys
process = subprocess.Popen(
    [sys.argv[1], 'get', 'repos/o/r/items'],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
)
try:
    stdout, stderr = process.communicate(timeout=5)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.communicate()
    sys.stderr.write('REST read exceeded five seconds\n')
    sys.exit(124)
sys.stdout.buffer.write(stdout)
sys.stderr.buffer.write(stderr)
sys.exit(process.returncode)
PY
      ) || status=$?
      chmod 0700 "$site/state"
      if [ "$response" = error ]; then
        assert_equals 1 "$status" "a $mode recording failure hid or delayed the forge error"
        assert_equals '' "$out" 'a forge error published a response body'
        assert_equals 'gh: HTTP 502' "$(cat "$site/error")" 'recording changed the forge error'
      else
        assert_equals 0 "$status" "a $mode recording failure blocked the $response read"
        assert_equals '[{"id":1},{"id":2}]' "$out" 'recording failure changed the response body'
        assert_equals '' "$(cat "$site/error")" 'best-effort recording was not silent'
      fi
      assert_equals "$previous" "$(cat "$site/state/gh-ratelimit.core.json" 2>/dev/null || true)" \
        'a refused recording changed the quota record'
      if [ "$response" = cached ]; then
        assert_equals 1 "$(unmodified "$site")" 'the cached read did not exercise a 304'
      fi
      if [ "$mode" = contended ]; then
        assert_equals "$$" "$(cat "$site/state/gh-ratelimit.core.json.lock/pid")" \
          'a refused recording disturbed the live lock holder'
      fi
    done
  done
  pass 'unwritable state and contended recording locks preserve prompt reads and forge errors'
}

test_prune_removes_abandoned_staged_files() {
  local site name
  site=$(new_site prune_staged)
  mkdir -p "$site/state/gh-rest-cache"
  for name in gh-rest-cache/.entry.old gh-rest-cache/.entry.live .gh-ratelimit.old .gh-ratelimit.live; do
    printf 'staged\n' > "$site/state/$name"
  done
  touch -t 202001010000 "$site/state/gh-rest-cache/.entry.old" "$site/state/.gh-ratelimit.old"
  get "$site" repos/o/r/items >/dev/null || fail 'read with abandoned staged files failed'
  [ ! -e "$site/state/gh-rest-cache/.entry.old" ] || fail 'an abandoned staged cache entry was never removed'
  [ ! -e "$site/state/.gh-ratelimit.old" ] || fail 'an abandoned staged quota record was never removed'
  [ -e "$site/state/gh-rest-cache/.entry.live" ] || fail 'a staged cache entry still in flight was removed'
  [ -e "$site/state/.gh-ratelimit.live" ] || fail 'a staged quota record still in flight was removed'
  get "$site" repos/o/r/items >/dev/null || fail 'read after the prune failed'
  assert_equals 1 "$(counted "$site")" 'the prune removed a live cache entry'
  pass 'the prune pass removes staged files a killed helper left behind and keeps fresh ones'
}

guard() { # site args... : run guard against the recorded buckets
  local site=$1
  shift
  PATH="$FAKEBIN:$PATH" FAKE_GH_SITE="$site" FM_STATE_OVERRIDE="$site/state" "$HELPER" guard "$@"
}

test_the_quota_floor_reads_headers_from_calls_already_made() {
  local site out status=0 reset
  site=$(new_site quota)
  guard "$site" || fail 'with nothing recorded the guard must not refuse'
  printf '800\n' > "$site/remaining"
  get "$site" repos/o/r/items >/dev/null || fail 'read failed'
  guard "$site" || fail '16% remaining is above the 15% floor'
  printf '700\n' > "$site/remaining"
  printf '[[{"id":9}]]\n' > "$site/pages.json"
  get "$site" repos/o/r/items >/dev/null || fail 'read failed'
  out=$(guard "$site") || status=$?
  assert_equals 75 "$status" 'below the floor the guard must exit 75'
  reset=$(cat "$site/reset")
  assert_contains "$out" "700 of 5000" 'the reason must state the remaining quota'
  assert_contains "$out" "$(jq -rn --argjson r "$reset" '$r | todate')" 'the reason must state the reset time'
  jq --argjson past "$(( $(date +%s) - 5 ))" '.reset = $past' "$site/state/gh-ratelimit.core.json" > "$site/past.json"
  mv "$site/past.json" "$site/state/gh-ratelimit.core.json"
  guard "$site" || fail 'a window that has reset must not refuse'
  pass 'the floor comes from response headers and ends at the reset'
}

test_parallel_responses_keep_the_lowest_remaining() {
  local site out status=0 low_pid high_pid n
  site=$(new_site lowest)
  printf '800\n' > "$site/remaining"
  get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
  mkdir "$site/bin"
  cat > "$site/bin/jq" <<'SH'
#!/usr/bin/env bash
set -eu
case "${FAKE_GH_REMAINING:-}:$*" in
  749:-r\ *gh-ratelimit.core.json|750:-r\ *gh-ratelimit.core.json)
    out=$("$REAL_JQ" "$@")
    : > "$FAKE_GH_SITE/read.$FAKE_GH_REMAINING"
    peer=749
    [ "$FAKE_GH_REMAINING" = 749 ] && peer=750
    for ((n=0; n<20; n++)); do
      [ ! -e "$FAKE_GH_SITE/read.$peer" ] || break
      sleep 0.1
    done
    if [ "$FAKE_GH_REMAINING" = 750 ]; then
      for ((n=0; n<20; n++)); do
        [ ! -e "$FAKE_GH_SITE/low-finished" ] || break
        sleep 0.1
      done
    fi
    printf '%s\n' "$out"
    ;;
  *) exec "$REAL_JQ" "$@" ;;
esac
SH
  chmod +x "$site/bin/jq"
  (
    FAKE_GH_REMAINING=749 REAL_JQ="$(command -v jq)" PATH="$site/bin:$PATH" get "$site" repos/o/r/low >/dev/null \
      || exit 1
    : > "$site/low-finished"
  ) &
  low_pid=$!
  for ((n=0; n<500; n++)); do
    [ ! -e "$site/read.749" ] || break
    sleep 0.01
  done
  [ "$n" -lt 500 ] || fail 'low response did not reach quota recording'
  FAKE_GH_REMAINING=750 REAL_JQ="$(command -v jq)" PATH="$site/bin:$PATH" get "$site" repos/o/r/high >/dev/null &
  high_pid=$!
  wait "$low_pid" || fail 'low response failed'
  wait "$high_pid" || fail 'high response failed'
  out=$(guard "$site") || status=$?
  assert_equals 75 "$status" 'a concurrent response raised the quota above the floor'
  assert_contains "$out" '749 of 5000' 'the lowest concurrent remaining value was lost'
  pass 'concurrent responses retain the lowest remaining quota'
}

test_older_windows_cannot_replace_newer_quota() {
  local site reset out status=0
  site=$(new_site older_window)
  reset=$(cat "$site/reset")
  FAKE_GH_REMAINING=4000 get "$site" repos/o/r/new >/dev/null || fail 'new window read failed'
  FAKE_GH_REMAINING=100 FAKE_GH_RESET="$((reset - 3600))" get "$site" repos/o/r/old >/dev/null || fail 'old response failed'
  guard "$site" || fail 'an older window replaced the newer quota'
  assert_equals 4000 "$(jq -r .remaining "$site/state/gh-ratelimit.core.json")" 'an older response changed the newer remaining value'
  assert_equals "$reset" "$(jq -r .reset "$site/state/gh-ratelimit.core.json")" 'the newest reset was lost'
  FAKE_GH_REMAINING=700 FAKE_GH_RESET="$((reset + 3600))" get "$site" repos/o/r/next >/dev/null || fail 'next window read failed'
  out=$(guard "$site") || status=$?
  assert_equals 75 "$status" 'a newer window did not replace the recorded quota'
  assert_contains "$out" '700 of 5000' 'the newer window remaining value was not recorded'
  pass 'older windows cannot replace newer quota, and newer windows replace it'
}

test_304_responses_also_record_headers() {
  local site status=0
  site=$(new_site headers304)
  get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
  printf '100\n' > "$site/remaining"
  get "$site" repos/o/r/items >/dev/null || fail 'repeat read failed'
  assert_equals 1 "$(unmodified "$site")" 'the repeat should have been a 304'
  guard "$site" >/dev/null || status=$?
  assert_equals 75 "$status" 'a 304 carries the rate-limit headers and must update the record'
  pass 'a 304 response still updates the recorded quota'
}

test_get_refuses_below_the_floor_before_any_network_call() {
  local site status=0 err before
  site=$(new_site floor_get)
  printf '100\n' > "$site/remaining"
  get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
  before=$(wc -l < "$site/calls")
  err=$(get "$site" repos/o/r/items 2>&1 >/dev/null) || status=$?
  assert_equals 75 "$status" 'get below the floor must exit 75'
  assert_contains "$err" 'quota low (100 of 5000' 'the refusal must state the remaining quota'
  assert_equals "$before" "$(wc -l < "$site/calls")" 'get made a network call below the floor'
  pass 'get refuses below the floor before any network call'
}

test_get_stops_between_pages_at_the_floor() {
  local site mode status out
  for mode in fresh cached; do
    site=$(new_site "floor-pages-$mode")
    printf '[[{"id":1},{"id":2}],[{"id":3}]]\n' > "$site/pages.json"
    if [ "$mode" = cached ]; then
      get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp >/dev/null || fail 'seed pages failed'
    fi
    : > "$site/calls"
    printf '500\n' > "$site/remaining"
    status=0
    out=$(get "$site" 'repos/o/r/items?per_page=2' --paginate --slurp 2>"$site/error") || status=$?
    assert_equals 75 "$status" "a $mode response did not stop the next page at the floor"
    assert_equals '' "$out" 'a refused paginated read published incomplete data'
    assert_equals 1 "$(wc -l < "$site/calls" | tr -d ' ')" 'a page was fetched after quota fell below the floor'
    assert_contains "$(cat "$site/error")" 'quota low (500 of 5000' 'pagination lost the quota refusal reason'
  done
  pass 'fresh and cached pages stop pagination at the quota floor without partial output'
}

test_full_last_page_reread_stops_at_the_floor() {
  local site status=0 out endpoint='repos/o/r/issues/1/comments?per_page=100'
  site=$(new_site floor_full_last_page)
  : > "$site/omit-304-link"
  jq -nc '[[range(1; 101) | {id: .}]]' > "$site/pages.json"
  get "$site" "$endpoint" --paginate --slurp >/dev/null || fail 'seed read of 100 comments failed'
  : > "$site/calls"
  printf '500\n' > "$site/remaining"
  out=$(get "$site" "$endpoint" --paginate --slurp 2>"$site/error") || status=$?
  assert_equals 75 "$status" 'a 304 reporting low quota did not stop the full-page re-read'
  assert_equals '' "$out" 'a refused full-page re-read published data'
  assert_equals 0 "$(counted "$site")" 'the full-page re-read spent a counted call below the floor'
  assert_equals 1 "$(unmodified "$site")" 'the conditional read that reported the quota was not made'
  assert_contains "$(cat "$site/error")" 'quota low (500 of 5000' 'the full-page refusal lost the quota reason'
  pass 'a full cached last page is not re-read once its 304 reports quota below the floor'
}

test_304_serves_cached_body_without_a_counted_call
test_changed_data_replaces_the_cache
test_missing_or_corrupt_cache_falls_back_to_a_normal_get
test_pagination_follows_link_and_caches_every_page
test_304_updates_pagination_and_retains_omitted_metadata
test_full_last_page_without_304_link_finds_the_next_page
test_304_uses_its_generation_during_concurrent_replacement
test_a_failed_read_exits_nonzero_and_caches_nothing
test_recording_failures_do_not_block_reads
test_the_quota_floor_reads_headers_from_calls_already_made
test_parallel_responses_keep_the_lowest_remaining
test_older_windows_cannot_replace_newer_quota
test_304_responses_also_record_headers
test_get_refuses_below_the_floor_before_any_network_call
test_get_stops_between_pages_at_the_floor
test_full_last_page_reread_stops_at_the_floor
test_prune_removes_abandoned_staged_files
