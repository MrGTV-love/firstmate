#!/usr/bin/env bash
# Live drive of the real bin/fm-copy-sweep.sh against a disposable Treehouse
# pool and a marked lab FM_HOME. Usage: live-copy-sweep.sh <bin-dir> <label>
set -u
BIN=$1 LABEL=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-graft-live.XXXXXX")
eval "$("$BIN/../bin/fm-lab-home.sh" env 2>/dev/null)" 2>/dev/null || eval "$(/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M60QKMFQ7BPM1PE7Y0HAECS8/bin/fm-lab-home.sh env)"
TH=$W/th; SLOT=$TH/pool1/1/repo
mkdir -p "$TH/pool1/1"
git init -q --bare -b main "$W/origin.git"
git init -q -b main "$SLOT"
git -C "$SLOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$SLOT" remote add origin "$W/origin.git"; git -C "$SLOT" push -q origin main; git -C "$SLOT" fetch -q origin
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
# graft's global-ignore effect on a worker host: root .ignore and graft/ ignored.
printf '/.ignore\n/graft/\n**/graft/\n' >> "$SLOT/.git/info/exclude"
add() { local c=$SLOT/.claude/worktrees/$1
  git -C "$SLOT" worktree add -q -b "fm/$1" "$c"; printf '%s\n' "$1" > "$c/$1.txt"
  git -C "$c" add "$1.txt"; git -C "$c" -c user.email=t@t -c user.name=t commit -qm "$1"; git -C "$c" push -q origin "fm/$1"; }
graft_out() { local c=$1
  # The exact .ignore bytes quoted in the captain's report.
  printf '%s\n' "# graft's cards are gitignored but should stay greppable: ripgrep reads" "# .ignore before .gitignore, so this re-admits the tree to search only." '!graft/' 'graft/.cache/' 'graft/.graph/' > "$c/.ignore"
  mkdir -p "$c/graft/.graph" "$c/graft/.cache/session"
  printf '{"graftReads":0,"sourceReads":3,"savedTokens":0,"injectedPointers":[],"nudges":0,"inputCostMicros":0,"inputTokensBilled":0,"lastBillingUuid":"x"}\n' > "$c/graft/.cache/session/a.json"
  printf '{"syncedAt":null}\n' > "$c/graft/.cache/stats.json"
  printf '{"lastSync":"2026-10-28T05:51:39.057Z"}\n' > "$c/graft/.cache/vernant-stop-sync.json"
  printf '# x.txt\n\n- old · function · L1-L2 — old()\n' > "$c/graft/x.md"
  printf '{"nodes":[],"edges":[{"relation":"implements"}]}\n' > "$c/graft/.graph/wiring.json"; }
add graftonly;     graft_out "$SLOT/.claude/worktrees/graftonly"
add cacheonly;     graft_out "$SLOT/.claude/worktrees/cacheonly"; rm -rf "$SLOT/.claude/worktrees/cacheonly/graft/.graph" "$SLOT/.claude/worktrees/cacheonly/graft/x.md"
add appendignore;  graft_out "$SLOT/.claude/worktrees/appendignore"; printf 'project-private/\n' >> "$SLOT/.claude/worktrees/appendignore/.ignore"
add truncignore;   graft_out "$SLOT/.claude/worktrees/truncignore"; head -3 "$SLOT/.claude/worktrees/truncignore/.ignore" > "$W/t" && mv "$W/t" "$SLOT/.claude/worktrees/truncignore/.ignore"
add graftclone;    graft_out "$SLOT/.claude/worktrees/graftclone"; git init -q "$SLOT/.claude/worktrees/graftclone/graft/.cache/n1"
add subgraft;      mkdir -p "$SLOT/.claude/worktrees/subgraft/sub/graft"; printf 'mine\n' > "$SLOT/.claude/worktrees/subgraft/sub/graft/notes.md"
add precious;      printf 'only here\n' > "$SLOT/.claude/worktrees/precious/precious.local"; printf '/precious.local\n' >> "$SLOT/.git/info/exclude"
echo "== $LABEL: bin/fm-copy-sweep.sh (report) =="
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u NO_MISTAKES_GATE \
  FM_HOME="$FM_HOME" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" "$BIN/fm-copy-sweep.sh" 2>&1 | sed "s#$W#<W>#g"
echo "report exit=${PIPESTATUS[0]}"
echo "== $LABEL: bin/fm-copy-sweep.sh --apply =="
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u NO_MISTAKES_GATE \
  FM_HOME="$FM_HOME" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" "$BIN/fm-copy-sweep.sh" --apply 2>&1 | sed "s#$W#<W>#g"
echo "apply exit=${PIPESTATUS[0]}"
echo "== $LABEL: copies left on disk =="
for n in graftonly cacheonly appendignore truncignore graftclone subgraft precious; do
  if [ -e "$SLOT/.claude/worktrees/$n" ]; then echo "$n: PRESENT"; else echo "$n: removed"; fi
done
[ -e "$SLOT/.claude/worktrees/graftclone/graft/.cache/n1/.git" ] && echo "graftclone nested .git intact"
cmp -s <(printf 'project-private/\n') <(tail -1 "$SLOT/.claude/worktrees/appendignore/.ignore") && echo "appendignore .ignore intact"
"$(dirname "$BIN")/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 && rm -rf "$FM_HOME"
rm -rf "$W"
