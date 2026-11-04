#!/usr/bin/env bash
# F3 live chain: real bin/fm-crew-state.sh -> real bin/fm-fleet-snapshot.sh ->
# real bin/fm-open-loops.sh, in a disposable lab home (bin/fm-lab-home.sh env),
# with real tmux on the lab's private socket. Only `no-mistakes` is a fake
# (the shared daemon is out of bounds). One done ship task per refusal mode.
# Run from the gate worktree: bash <this> <worktree>
set -u
WT_ROOT=$1
cd "$WT_ROOT" || exit 1
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
LAB=$FM_HOME
unset TMUX TMUX_PANE
echo "lab FM_HOME=$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
FB=$LAB/fakebin
mkdir -p "$FB" "$LAB/copies"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
# Fake no-mistakes. The mode is read from the copy's own git dir (untracked).
mode=$(cat "$(git rev-parse --git-dir 2>/dev/null)/nm-mode" 2>/dev/null || echo none)
printf '%s %s\n' "$mode" "$*" >> "${FM_HOME:?}/nm-calls.log"
case "${1:-} ${2:-} $mode" in
  "axi status norun") exit 0 ;;   # answers, names no run
  "axi status uninit") printf '%s\n' "error: repo not initialized (run 'no-mistakes init' first)"; exit 1 ;;
  "axi status down"|"axi status unreadable") printf '%s\n' 'error: status read failed' >&2; exit 1 ;;
  "daemon status down") echo 'daemon not running' >&2; exit 1 ;;
  "daemon status "*) printf 'daemon running (pid 4242)\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FB/no-mistakes"
cat > "$FB/gh" <<'PYGH'
#!/usr/bin/env python3
# Forge double for `gh api -i <path>` (bin/fm-gh-rest.sh). Every other call fails.
import hashlib, json, os, sys, time
args = sys.argv[1:]
open(os.environ['FM_HOME'] + '/gh-calls.log', 'a').write(' '.join(args) + '\n')
if args[:2] != ['api', '-i']:
    sys.exit(1)
double = json.load(open(os.environ['FM_HOME'] + '/gh.json'))
path = '/' + args[-1].lstrip('/')
value = [] if '/pulls?' in path else double.get(path.split('?')[0].rsplit('/', 1)[1])
if value is None:
    sys.stdout.write('HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}'); sys.exit(1)
body = json.dumps(value)
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: "%s"\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4000\r\n'
                 'X-Ratelimit-Reset: %d\r\nX-Ratelimit-Resource: core\r\n\r\n%s' % (hashlib.sha1(body.encode()).hexdigest()[:8], int(time.time()) + 3600, body))
PYGH
chmod +x "$FB/gh"
echo '{}' > "$LAB/gh.json"
export PATH="$FB:$PATH" NM_HOME="$LAB/nm-unused"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
MODES="down norun uninit unreadable"
n=20
first=1
for mode in $MODES; do
  id=f3-$mode; n=$((n + 1)); copy=$LAB/copies/$id
  git init -q -b main "$copy"
  echo base > "$copy/base.txt"; git -C "$copy" add base.txt; git -C "$copy" commit -q -m base
  git -C "$copy" checkout -q -b "fm/$id"
  echo "$mode" > "$copy/file.txt"; git -C "$copy" add file.txt; git -C "$copy" commit -q -m "work for $id"
  # The branch is pushed (on a remote, so not unlanded) but not on main and no PR merged (so not landed).
  git init -q --bare "$LAB/copies/$id-origin.git"; git -C "$copy" remote add origin "$LAB/copies/$id-origin.git"
  git -C "$copy" push -q origin main "fm/$id"; git -C "$copy" fetch -q origin
  echo "$mode" > "$(git -C "$copy" rev-parse --absolute-git-dir)/nm-mode"
  printf 'window=fm:fm-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\nharness=claude\nbackend=tmux\npr=https://github.com/test/project/pull/%s\n' \
    "$id" "$copy" "$copy" "$n" > "$LAB/state/$id.meta"
  # Another lane merged this PR at the forge; its head is exactly this copy's HEAD.
  python3 - "$LAB/gh.json" "$n" "$(git -C "$copy" rev-parse HEAD)" <<'PYJ'
import json, sys, time
p, n, head = sys.argv[1:]
d = json.load(open(p))
d[n] = dict(number=int(n), html_url='https://github.com/test/project/pull/' + n, state='closed',
            merged_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() - 3600)), head=dict(sha=head))
json.dump(d, open(p, 'w'))
PYJ
  printf 'done: PR https://github.com/o/r/pull/%s checks green\n' "$n" > "$LAB/state/$id.status"
  gen=$(bin/fm-busy-event.sh arm "$LAB/state" "$id")
  bin/fm-busy-event.sh apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop
  if [ "$first" = 1 ]; then tmux new-session -d -s fm -n "fm-$id" 'sleep 3600'; first=0
  else tmux new-window -d -t fm: -n "fm-$id" 'sleep 3600'; fi
done
echo "real tmux on lab socket (TMUX_TMPDIR=$TMUX_TMPDIR):"; tmux list-windows -t fm -F '  #{window_name}'
echo
echo "== real bin/fm-crew-state.sh per task"
for mode in $MODES; do
  printf '%-14s ' "f3-$mode"; bin/fm-crew-state.sh "f3-$mode" 2>&1 | head -3
done
echo
echo "== real bin/fm-open-loops.sh --json (rows for the f3-* tasks)"
bin/fm-open-loops.sh --json > "$LAB/ledger.json" 2> "$LAB/ledger.err"; echo "open-loops rc=$?"
python3 - "$LAB/ledger.json" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1]))
rows = [r for r in rep['rows'] if r['subject'].startswith('f3-')]
for mode in ('down', 'norun', 'uninit', 'unreadable'):
    mine = [r for r in rows if r['subject'] == 'f3-' + mode]
    if not mine:
        print(f'  f3-{mode:11s} NO ROW')
    for r in mine:
        print(f"  f3-{mode:11s} category={r['category']} owner={r['owner']} informational={r.get('informational')} | {r['next_action'][:200]}")
pend = {r['subject'] for r in rows if r['category'] in ('pending_cleanup', 'pending_acceptance')}
ok = 'f3-down' not in pend and {'f3-norun', 'f3-uninit', 'f3-unreadable'} <= pend
for r in rows:
    if r['category'] == 'pending_acceptance' and r['subject'] != 'f3-down':
        ok = ok and r['owner'] == 'firstmate' and 'resolve the refused done claim' in r['next_action']
print('degraded sources:', [r['subject'] for r in rep['rows'] if r['category'] == 'degraded_source'] or 'none')
print('F3 CHAIN RESULT:', 'PASS' if ok else 'FAIL')
PY
echo
echo "== fake no-mistakes calls (mode, args)"; sort "$LAB/nm-calls.log" | uniq -c
echo "== forge double calls"; sort "$LAB/gh-calls.log" 2>/dev/null | uniq -c
echo "== teardown"
tmux kill-server
"$WT_ROOT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $LAB"
