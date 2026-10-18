#!/usr/bin/env bash
# Live guard drivers against the target commit (real fm-jev-guard.ts + real fm-jev-guard-hook.sh, local fake judge on 127.0.0.1)
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30
D=/Users/charlesabrooker/.no-mistakes/evidence/01M56FRCDWDJ3656WKSNB7AN30/round3
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-r3-live.XXXXXX"); echo "$T" > /tmp/fm-nm-live-dir.txt
cp $D/fake.mjs "$T/fake.mjs"
echo "HEAD=$(git -C $ROOT rev-parse HEAD) load=$(uptime | sed 's/.*load averages*: //')"
: > "$T/req.log"; rm -f "$T/port"
node "$T/fake.mjs" "$T/req.log" "$T/port" 2>/dev/null & fpid=$!
for _ in $(seq 1 100); do [ -s "$T/port" ] && break; sleep 0.05; done
export FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$T/port")/v1/systemone" KEY=lab-key T GUARD_ROOT=$ROOT REQLOG="$T/req.log" LABEL=HEAD
echo "== driver.mjs (trusted reads, deadlines, outage)"; node $D/driver.mjs 2>&1 | grep -v _nvm_lazy
echo "== adv-driver.mjs (adversarial trust)"; node $D/adv-driver.mjs 2>&1 | grep -v _nvm_lazy
echo "== band-driver.mjs (score bands)"; node $D/band-driver.mjs 2>&1 | grep -v _nvm_lazy
kill $fpid 2>/dev/null
echo "== claude-driver.sh (real hook script, Claude path)"
bash $D/claude-driver.sh HEAD $ROOT 2>&1 | grep -v _nvm_lazy
rm -rf "$T"; rm -f /tmp/fm-nm-live-dir.txt
