#!/usr/bin/env bash
# Spawn wall time: flag off vs flag on with a 35 s endpoint (capture must not add wait).
set -u
WTROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5MTT81P8BWYWQFDAMK6GJCT
. "$WTROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-shadow-timing); CASE="$TMP_ROOT/case"; HOME_DIR="$CASE/home"; PROJ="$CASE/project"; DATA="$CASE/data"
mkdir -p "$CASE" "$DATA/projection"
cp "$ROOT"/tests/fixtures/model-picker-shadow/projection/*.json "$DATA/projection/"
printf '%s\n' '{"verdict":"TRUSTED"}' > "$DATA/verdict.json"
fm_test_spawn_home "$HOME_DIR" claude
printf '%s\n' '{"rules":[],"default":[{"harness":"claude","model":"opus","effort":"high"}]}' > "$HOME_DIR/config/crew-dispatch.json"
fm_git_init_commit "$PROJ"; fm_git_add_origin "$PROJ" "$PROJ.origin.git"
printf 'TYPESAFE_API_KEY=synthetic-key\n' > "$HOME_DIR/.env"; unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE
FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake"); fm_fake_exit0 "$FAKEBIN" claude
cat > "$CASE/slow.py" <<'PY'
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        time.sleep(35)
        try: self.send_response(500); self.end_headers()
        except Exception: pass
    def log_message(self, *a): pass
s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H); open(sys.argv[1], 'w').write(str(s.server_port)); s.serve_forever()
PY
python3 "$CASE/slow.py" "$CASE/port" 2>/dev/null & SERVER=$!
trap 'kill $SERVER 2>/dev/null; fm_test_cleanup' EXIT
for _ in {1..100}; do [ -f "$CASE/port" ] && break; sleep .05; done
export FM_MODEL_PICKER_DATA="$DATA" FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$CASE/port")"
now() { python3 -c 'import time;print(time.time())'; }
for run in 1 2 3; do for flag in '' 1; do
  id="t$run-${flag:-off}"; git -C "$PROJ" worktree add --quiet -b "$id" "$CASE/wt-$id"; fm_test_spawn_brief "$HOME_DIR" "$id" "timing"
  t0=$(now); FM_MODEL_PICKER_SHADOW="$flag" fm_test_run_spawn "$HOME_DIR" "$CASE/wt-$id" "$FAKEBIN" "$id" "$PROJ" --mode no-mistakes --yolo off --harness claude --model opus --effort high >/dev/null; rc=$?; t1=$(now)
  printf 'run %s flag=%-3s rc=%s spawn wall time %.2f s\n' "$run" "${flag:-off}" "$rc" "$(python3 -c "print($t1-$t0)")"
done; done
