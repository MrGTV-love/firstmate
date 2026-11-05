#!/usr/bin/env bash
# mk.sh <source-test-file> <out-file> <variant>
# Builds a trimmed driver: header setup + UPSRC setup + the rival trust case.
set -eu
src=$1 out=$2 variant=$3
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6PS1067FR01RCW4S4F76FN1
{
  awk '/^# ---- Claude lab: every check passes/{exit} {print}' "$src"
  # Earlier suite cases leave a Claude store behind; seed one so the rival's
  # first JSON read does not throw (the full suite never starts without it).
  echo '[ -f "$HOME/.claude.json" ] || printf "%s\n" "{\"projects\":{}}" > "$HOME/.claude.json"'
  awk '/^UPSRC=/{on=1} on{print} on&&/-qm source/{exit}' "$src"
  awk '/^FAKEBIN=/{on=1} /^# ---- fm-claude-trust.sh --lab-home/{exit} on{print}' "$src"
  echo 'echo "driver finished cleanly"'
} > "$out.tmp"
sed -i '' "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/fixtures.sh#$WT/tests/fixtures.sh#" "$out.tmp"
case "$variant" in
  plain) ;;
  slow) sed -i '' 's/^  sleep 0\.5$/  sleep 2.5/' "$out.tmp" ;;
  persist)
    # Rival keeps deleting the entry for 8s after the first drop: a pre-launch refusal.
    perl -0pi -e 's/(  echo dropped > "\$TMP_ROOT\/rival-dropped"\n)/$1  stop=\$(( \$(date +%s) + 8 ))\n  while [ "\$(date +%s)" -lt "\$stop" ]; do node -e '"'"'const fs=require("node:fs");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));if(j.projects?.[k]){delete j.projects[k];fs.writeFileSync(s,JSON.stringify(j))}'"'"' "\$HOME\/.claude.json" "\$U\/home"; sleep 0.05; done\n/' "$out.tmp" ;;
  postlaunch)
    # Stand-in primary marks its start; the rival deletes trust again after launch: a trust failure.
    perl -0pi -e 's/\nsleep 1\.5\n/\n: > "\$FM_HOME\/..\/claude-started"\nsleep 1.5\n/' "$out.tmp"
    perl -0pi -e 's/(  echo dropped > "\$TMP_ROOT\/rival-dropped"\n)/$1  until [ -f "\$U\/claude-started" ]; do sleep 0.02; done\n  node -e '"'"'const fs=require("node:fs");const [s,k]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));delete j.projects[k];fs.writeFileSync(s,JSON.stringify(j))'"'"' "\$HOME\/.claude.json" "\$U\/home"\n/' "$out.tmp" ;;
esac
mv "$out.tmp" "$out"
