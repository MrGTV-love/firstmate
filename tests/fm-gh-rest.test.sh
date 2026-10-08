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
rate = ('X-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: ' + open(site + '/remaining').read().strip()
        + '\r\nX-Ratelimit-Reset: ' + open(site + '/reset').read().strip() + '\r\nX-Ratelimit-Resource: core\r\n')
link = ''
if index + 1 < len(pages):
    link = 'Link: <https://api.github.com/repositories/1/items?per_page=2&page=%d>; rel="next"\r\n' % (index + 2)
if conditional == etag:
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

test_query_fields_are_encoded_and_distinct_cache_keys() {
  local site
  site=$(new_site query)
  get "$site" repos/o/r/commits -f sha=abc -f path='dir/a b.ts' -f per_page=100 >/dev/null || fail 'query read failed'
  assert_contains "$(cat "$site/calls")" 'repos/o/r/commits?sha=abc&path=dir%2Fa%20b.ts&per_page=100' 'query fields were not encoded'
  get "$site" repos/o/r/commits -f sha=abc -f path='other.ts' -f per_page=100 >/dev/null || fail 'second query failed'
  assert_equals 2 "$(counted "$site")" 'different queries must not share a cache entry'
  pass 'query fields are URL-encoded and keyed separately'
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
  guard "$site" || fail '16% remaining is above the default 15% floor'
  printf '700\n' > "$site/remaining"
  printf '[[{"id":9}]]\n' > "$site/pages.json"
  get "$site" repos/o/r/items >/dev/null || fail 'read failed'
  out=$(guard "$site") || status=$?
  assert_equals 75 "$status" 'below the floor the guard must exit 75'
  reset=$(cat "$site/reset")
  assert_contains "$out" "700 of 5000" 'the reason must state the remaining quota'
  assert_contains "$out" "$(jq -rn --argjson r "$reset" '$r | todate')" 'the reason must state the reset time'
  FM_GH_RATE_FLOOR_PERCENT=10 guard "$site" || fail 'the floor is not overridable by environment'
  FM_GH_RATE_FLOOR_PERCENT=nonsense guard "$site" >/dev/null && fail 'an unparsable floor must fall back to 15%'
  printf '%s\n' "$(( $(date +%s) - 5 ))" > "$site/reset"
  get "$site" repos/o/r/items >/dev/null || fail 'read failed'
  guard "$site" || fail 'a window that has reset must not refuse'
  pass 'the floor comes from response headers, is overridable, and ends at the reset'
}

test_parallel_responses_keep_the_lowest_remaining() {
  local site out status=0
  site=$(new_site lowest)
  printf '300\n' > "$site/remaining"
  get "$site" repos/o/r/items >/dev/null || fail 'read failed'
  printf '900\n' > "$site/remaining" # a slower response from earlier in the same window
  printf '[[{"id":7}]]\n' > "$site/pages.json"
  get "$site" repos/o/r/other >/dev/null || fail 'read failed'
  out=$(guard "$site") || status=$?
  assert_equals 75 "$status" 'an out-of-order response raised the recorded remaining quota'
  assert_contains "$out" '300 of 5000' 'the lowest remaining in a window is the one to keep'
  pass 'out-of-order responses never raise the recorded remaining quota'
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

test_get_with_floor_refuses_before_any_network_call() {
  local site status=0 err before
  site=$(new_site floor_get)
  printf '100\n' > "$site/remaining"
  get "$site" repos/o/r/items >/dev/null || fail 'seed read failed'
  before=$(wc -l < "$site/calls")
  err=$(get "$site" repos/o/r/items --floor 2>&1 >/dev/null) || status=$?
  assert_equals 75 "$status" 'get --floor below the floor must exit 75'
  assert_contains "$err" 'quota low (100 of 5000' 'the refusal must state the remaining quota'
  assert_equals "$before" "$(wc -l < "$site/calls")" 'get --floor made a network call below the floor'
  get "$site" repos/o/r/items >/dev/null || fail 'a read without --floor must still be allowed'
  pass 'get --floor refuses below the floor before any network call, and a plain get still reads'
}

test_304_serves_cached_body_without_a_counted_call
test_changed_data_replaces_the_cache
test_missing_or_corrupt_cache_falls_back_to_a_normal_get
test_pagination_follows_link_and_caches_every_page
test_query_fields_are_encoded_and_distinct_cache_keys
test_a_failed_read_exits_nonzero_and_caches_nothing
test_the_quota_floor_reads_headers_from_calls_already_made
test_parallel_responses_keep_the_lowest_remaining
test_304_responses_also_record_headers
test_get_with_floor_refuses_before_any_network_call
